//! Runs a user-authored JS interceptor script against a captured
//! request/response pair. Backed by `boa_engine` — a pure-Rust JS
//! interpreter, so this needs no C toolchain or bundled V8/JSC binary.
//!
//! Script contract: define `function onResponse(req, res) { ... return res; }`.
//! `req` is `{ method, url, headers, body }` (read-only by convention, not
//! enforced). `res` is `{ status, headers, body }` — whatever the function
//! returns (or the mutated `res` object, if nothing is returned) becomes the
//! response actually sent to the client and shown in the inspector.

use boa_engine::property::PropertyKey;
use boa_engine::{js_string, Context, JsObject, JsResult, JsValue, Source};

pub struct JsRequest {
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Option<String>,
}

pub struct JsResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

/// Runs `onResponse(req, res)` and returns the (possibly mutated) response.
/// Any failure — parse error, missing function, thrown exception — comes
/// back as `Err(message)` so the caller can fail open (keep the original
/// response) rather than break the request.
pub fn run_on_response(script: &str, req: &JsRequest, res: &JsResponse) -> Result<JsResponse, String> {
    let mut context = Context::default();

    let script = script.trim();
    // Accept the `export default function onResponse(...) {}` shape shown in
    // our own UI's template — plain script evaluation doesn't understand ES
    // module syntax, but the rest of that shape is just a function
    // declaration, so stripping the export turns it into valid script code.
    let script = script.strip_prefix("export default").unwrap_or(script);

    context
        .eval(Source::from_bytes(script))
        .map_err(|e| format!("script error: {e}"))?;

    let on_response = context
        .global_object()
        .get(js_string!("onResponse"), &mut context)
        .map_err(|e| format!("script error: {e}"))?;

    let Some(func) = on_response.as_callable() else {
        return Err("script must define function onResponse(req, res)".to_string());
    };

    let req_val = build_request_object(&mut context, req).map_err(|e| format!("script error: {e}"))?;
    let res_val = build_response_object(&mut context, res).map_err(|e| format!("script error: {e}"))?;

    let result = func
        .call(&JsValue::undefined(), &[req_val, res_val.clone()], &mut context)
        .map_err(|e| format!("script threw: {e}"))?;

    // Scripts may either mutate `res` in place or return a new object —
    // support both since the mockup's own template does the former ("return
    // res;") but a from-scratch mock naturally does the latter.
    let effective = if result.is_object() { result } else { res_val };
    read_response_object(&mut context, &effective).map_err(|e| format!("script error: {e}"))
}

fn build_request_object(context: &mut Context, req: &JsRequest) -> JsResult<JsValue> {
    let obj = JsObject::with_object_proto(context.intrinsics());
    obj.set(js_string!("method"), js_string!(req.method.clone()), false, context)?;
    obj.set(js_string!("url"), js_string!(req.url.clone()), false, context)?;
    obj.set(
        js_string!("body"),
        req.body.clone().map(|b| JsValue::from(js_string!(b))).unwrap_or(JsValue::null()),
        false,
        context,
    )?;
    obj.set(js_string!("headers"), headers_to_js(context, &req.headers)?, false, context)?;
    Ok(JsValue::from(obj))
}

fn build_response_object(context: &mut Context, res: &JsResponse) -> JsResult<JsValue> {
    let obj = JsObject::with_object_proto(context.intrinsics());
    obj.set(js_string!("status"), JsValue::from(res.status as i32), false, context)?;
    obj.set(js_string!("body"), js_string!(res.body.clone()), false, context)?;
    obj.set(js_string!("headers"), headers_to_js(context, &res.headers)?, false, context)?;
    Ok(JsValue::from(obj))
}

fn headers_to_js(context: &mut Context, headers: &[(String, String)]) -> JsResult<JsValue> {
    let obj = JsObject::with_object_proto(context.intrinsics());
    for (name, value) in headers {
        obj.set(js_string!(name.clone()), js_string!(value.clone()), false, context)?;
    }
    Ok(JsValue::from(obj))
}

fn read_response_object(context: &mut Context, value: &JsValue) -> JsResult<JsResponse> {
    let obj = value.as_object().ok_or_else(|| {
        boa_engine::JsNativeError::typ().with_message("onResponse must return/mutate an object")
    })?;

    let status = obj
        .get(js_string!("status"), context)?
        .to_i32(context)
        .unwrap_or(200)
        .clamp(100, 599) as u16;

    let body = obj
        .get(js_string!("body"), context)?
        .to_string(context)
        .map(|s| s.to_std_string_escaped())
        .unwrap_or_default();

    let mut headers = Vec::new();
    let headers_val = obj.get(js_string!("headers"), context)?;
    if let Some(headers_obj) = headers_val.as_object() {
        // JsArray-style iteration isn't needed here — we only ever wrote
        // plain string-keyed properties, so own enumerable keys suffice.
        let keys = headers_obj.own_property_keys(context)?;
        for key in keys {
            if let PropertyKey::String(name) = key {
                let name = name.to_std_string_escaped();
                if let Ok(v) = headers_obj.get(js_string!(name.clone()), context) {
                    if let Ok(s) = v.to_string(context) {
                        headers.push((name, s.to_std_string_escaped()));
                    }
                }
            }
        }
    }

    Ok(JsResponse { status, headers, body })
}
