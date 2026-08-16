//! MITM HTTP(S) proxy engine.
//!
//! Listens on localhost as an ordinary HTTP proxy. Plain HTTP arrives as
//! absolute-form requests and is forwarded straight upstream. HTTPS arrives
//! as CONNECT: we answer 200, hijack the upgraded stream, complete a TLS
//! handshake using a leaf cert minted by our `CertAuthority`, then run a
//! second HTTP server over the decrypted bytes. Both directions are
//! buffered so we can record request/response bodies for the inspector.
//!
//! Process attribution: since this is a system-wide loopback proxy, the
//! "client" connecting to us on 127.0.0.1 *is* the local process that
//! issued the request. We resolve which process owns that ephemeral port
//! via `lsof` once per accepted TCP connection (not per request — HTTP
//! keep-alive can carry many requests over one connection).

use crate::cert::CertAuthority;
use crate::interceptor;
use crate::model::{
    BlockRule, CapturedRequest, DnsSpoofRule, FocusSettings, HeaderPair, MapLocalRule, MapRemoteRule, MockRule,
    RewriteAction, RewriteRule, ThrottleProfile,
};
use base64::Engine;
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::header::{HeaderMap, HeaderName};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, Uri};
use hyper_rustls::HttpsConnectorBuilder;
use hyper_util::client::legacy::Client;
use hyper_util::rt::{TokioExecutor, TokioIo};
use parking_lot::Mutex;
use rustls::pki_types::ServerName;
use rustls::{ClientConfig, RootCertStore, ServerConfig};
use std::collections::HashMap;
use std::convert::Infallible;
use std::io::Read as _;
use std::sync::{Arc, OnceLock};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::watch;
use tokio_rustls::{TlsAcceptor, TlsConnector};

/// Cap on retained requests, so a long capture session can't grow forever.
const MAX_STORED_REQUESTS: usize = 5000;
/// How much of a body we retain (base64-encoded) for the inspector. The
/// full body is still forwarded upstream/downstream regardless of this cap
/// — it only limits what we hold onto for display.
const BODY_CAPTURE_LIMIT: usize = 3 * 1024 * 1024;

/// Headers that are connection-scoped and must not be relayed to the
/// upstream server (or back to the client) verbatim.
const HOP_BY_HOP: &[&str] = &[
    "connection",
    "proxy-connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
];

type Shared = Arc<Mutex<Vec<CapturedRequest>>>;
type SharedRules = Arc<Mutex<Vec<MockRule>>>;
type SharedMapLocal = Arc<Mutex<Vec<MapLocalRule>>>;
type SharedMapRemote = Arc<Mutex<Vec<MapRemoteRule>>>;
type SharedRewrite = Arc<Mutex<Vec<RewriteRule>>>;
type SharedBlock = Arc<Mutex<Vec<BlockRule>>>;
type SharedDnsSpoof = Arc<Mutex<Vec<DnsSpoofRule>>>;
type SharedFocus = Arc<Mutex<FocusSettings>>;
type SharedThrottle = Arc<Mutex<ThrottleProfile>>;
type HttpsClient = Client<hyper_rustls::HttpsConnector<hyper_util::client::legacy::connect::HttpConnector>, Full<Bytes>>;

/// Which local process owns a captured request/connection.
#[derive(Clone, Default)]
struct ProcessInfo {
    name: Option<String>,
    pid: Option<u32>,
}

pub struct ProxyEngine {
    ca: Arc<CertAuthority>,
    store: Shared,
    mock_rules: SharedRules,
    map_local_rules: SharedMapLocal,
    map_remote_rules: SharedMapRemote,
    rewrite_rules: SharedRewrite,
    block_rules: SharedBlock,
    dns_spoof_rules: SharedDnsSpoof,
    focus: SharedFocus,
    throttle: SharedThrottle,
    client: HttpsClient,
    /// Per-host rustls configs, so we only build the acceptor once per host.
    tls_configs: Mutex<HashMap<String, Arc<ServerConfig>>>,
}

impl ProxyEngine {
    pub fn new(
        ca: Arc<CertAuthority>,
        store: Shared,
        mock_rules: SharedRules,
        map_local_rules: SharedMapLocal,
        map_remote_rules: SharedMapRemote,
        rewrite_rules: SharedRewrite,
        block_rules: SharedBlock,
        dns_spoof_rules: SharedDnsSpoof,
        focus: SharedFocus,
        throttle: SharedThrottle,
    ) -> Self {
        // rustls 0.23 requires a process-wide crypto provider. Installing
        // twice is not an error for us — another component may have won
        // the race, and either provider is equivalent here.
        let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

        let https = HttpsConnectorBuilder::new()
            .with_webpki_roots()
            .https_or_http()
            .enable_http1()
            .build();
        let client = Client::builder(TokioExecutor::new()).build(https);

        Self {
            ca,
            store,
            mock_rules,
            map_local_rules,
            map_remote_rules,
            rewrite_rules,
            block_rules,
            dns_spoof_rules,
            focus,
            throttle,
            client,
            tls_configs: Mutex::new(HashMap::new()),
        }
    }

    /// Computes the artificial delay for `bytes` under the current throttle
    /// profile (fixed latency + simulated transfer time at `down_kbps`),
    /// capped so a misconfigured profile can't hang a request forever.
    fn throttle_delay(&self, bytes_len: usize) -> Option<std::time::Duration> {
        let profile = *self.throttle.lock();
        if !profile.enabled {
            return None;
        }
        let mut delay_ms = profile.latency_ms as u64;
        if profile.down_kbps > 0 {
            let transfer_ms = (bytes_len as f64 * 8.0 / (profile.down_kbps as f64 * 1000.0)) * 1000.0;
            delay_ms += transfer_ms as u64;
        }
        (delay_ms > 0).then(|| std::time::Duration::from_millis(delay_ms.min(15_000)))
    }

    /// Rolls the dice against the current loss probability. Simulated loss
    /// is reported as a gateway timeout rather than actually severing the
    /// connection — enough to exercise a client's error handling without
    /// requiring a lower-level socket trick.
    fn throttle_should_drop(&self) -> bool {
        let probability = self.throttle.lock().loss_probability;
        probability > 0.0 && rand::random::<f32>() < probability
    }

    /// First enabled rule whose method/URL pattern matches, if any.
    fn matching_rule(&self, method: &str, url: &str) -> Option<MockRule> {
        self.mock_rules.lock().iter().find(|r| {
            r.enabled
                && r.method.as_deref().map(|m| m.eq_ignore_ascii_case(method)).unwrap_or(true)
                && url.contains(&r.url_contains)
        }).cloned()
    }

    /// Persists a script failure back into the shared rule list so
    /// `mock_rules()` (and therefore the UI) can show it, without needing a
    /// separate error-reporting channel.
    fn record_rule_error(&self, rule_id: &str, message: String) {
        let mut rules = self.mock_rules.lock();
        if let Some(r) = rules.iter_mut().find(|r| r.id == rule_id) {
            r.last_error = Some(message);
        }
    }

    /// First enabled Map Local rule whose method/URL pattern matches, if any.
    fn matching_map_local(&self, method: &str, url: &str) -> Option<MapLocalRule> {
        self.map_local_rules.lock().iter().find(|r| {
            r.enabled
                && r.method.as_deref().map(|m| m.eq_ignore_ascii_case(method)).unwrap_or(true)
                && url.contains(&r.url_contains)
        }).cloned()
    }

    /// Same idea as `record_rule_error`, for Map Local read failures.
    fn record_map_local_error(&self, rule_id: &str, message: String) {
        let mut rules = self.map_local_rules.lock();
        if let Some(r) = rules.iter_mut().find(|r| r.id == rule_id) {
            r.last_error = Some(message);
        }
    }

    /// First enabled Map Remote rule whose host/path pattern matches, if any.
    fn matching_map_remote(&self, host: &str, path: &str) -> Option<MapRemoteRule> {
        self.map_remote_rules.lock().iter().find(|r| {
            r.enabled
                && host.contains(&r.match_host)
                && (r.match_path_contains.is_empty() || path.contains(&r.match_path_contains))
        }).cloned()
    }

    /// All enabled Rewrite rules whose host/path pattern matches, in list
    /// order — unlike the other rule types this returns every match (not
    /// just the first), since applying several small rewrites in sequence
    /// is the whole point of the tool.
    fn matching_rewrite_rules(&self, host: &str, path: &str) -> Vec<RewriteRule> {
        self.rewrite_rules.lock().iter().filter(|r| {
            r.enabled
                && (r.host_contains.is_empty() || host.contains(&r.host_contains))
                && (r.path_contains.is_empty() || path.contains(&r.path_contains))
        }).cloned().collect()
    }

    /// First enabled Block rule whose host/path pattern matches, if any.
    fn matching_block_rule(&self, host: &str, path: &str) -> Option<BlockRule> {
        self.block_rules.lock().iter().find(|r| {
            r.enabled
                && (r.host_contains.is_empty() || host.contains(&r.host_contains))
                && (r.path_contains.is_empty() || path.contains(&r.path_contains))
        }).cloned()
    }

    /// First enabled DNS Spoof rule whose host pattern matches, if any.
    fn matching_dns_spoof(&self, host: &str) -> Option<DnsSpoofRule> {
        self.dns_spoof_rules.lock().iter().find(|r| r.enabled && host.contains(&r.host)).cloned()
    }

    /// Whether a request to `host` should be recorded under the current
    /// Focus settings. Traffic itself is never affected by this — it only
    /// gates what gets written into the capture log.
    fn should_record(&self, host: &str) -> bool {
        let focus = self.focus.lock();
        !focus.enabled || focus.hosts.is_empty() || focus.hosts.iter().any(|h| host.contains(h.as_str()))
    }

    /// Bind and serve until `shutdown` flips. Binding happens in the caller's
    /// context so a port conflict surfaces as an error rather than a silently
    /// dead background task.
    pub async fn serve(
        self: Arc<Self>,
        listener: TcpListener,
        mut shutdown: watch::Receiver<bool>,
    ) -> anyhow::Result<()> {
        loop {
            let (stream, peer) = tokio::select! {
                _ = shutdown.changed() => break,
                accepted = listener.accept() => match accepted {
                    Ok(pair) => pair,
                    // Transient accept errors (fd limits, resets) shouldn't
                    // tear down the whole proxy.
                    Err(_) => continue,
                },
            };

            let engine = self.clone();
            tokio::spawn(async move {
                let process = resolve_process(peer.port()).await;
                let service = service_fn(move |req| {
                    let engine = engine.clone();
                    let process = process.clone();
                    async move { engine.dispatch(req, process).await }
                });
                if let Err(err) = http1::Builder::new()
                    .preserve_header_case(true)
                    .serve_connection(TokioIo::new(stream), service)
                    .with_upgrades()
                    .await
                {
                    eprintln!("client connection error: {err}");
                }
            });
        }
        Ok(())
    }

    /// Entry point for a request arriving on the *outer* (plaintext) proxy
    /// port: either a CONNECT to tunnel, or an absolute-form plain request.
    async fn dispatch(
        self: Arc<Self>,
        req: Request<hyper::body::Incoming>,
        process: ProcessInfo,
    ) -> Result<Response<Full<Bytes>>, Infallible> {
        if req.method() == Method::CONNECT {
            return Ok(self.handle_connect(req, process));
        }
        self.forward(req, None, process).await
    }

    /// Answer CONNECT immediately, then MITM the tunnel once hyper hands us
    /// the upgraded stream. The 200 must be sent before the client will
    /// start its TLS handshake, so the interception happens in a task.
    fn handle_connect(
        self: Arc<Self>,
        req: Request<hyper::body::Incoming>,
        process: ProcessInfo,
    ) -> Response<Full<Bytes>> {
        let Some(authority) = req.uri().authority().map(|a| a.to_string()) else {
            return status_response(StatusCode::BAD_REQUEST, "CONNECT requires an authority");
        };
        // Strip the port: certs are issued for the hostname only.
        let host = authority
            .rsplit_once(':')
            .map(|(h, _)| h.to_string())
            .unwrap_or_else(|| authority.clone());

        tokio::spawn(async move {
            let upgraded = match hyper::upgrade::on(req).await {
                Ok(u) => u,
                Err(e) => {
                    eprintln!("CONNECT upgrade failed for {authority}: {e}");
                    return;
                }
            };
            if let Err(e) = self
                .mitm_tunnel(TokioIo::new(upgraded), host, authority.clone(), process)
                .await
            {
                eprintln!("MITM tunnel for {authority} ended: {e}");
            }
        });

        Response::new(Full::new(Bytes::new()))
    }

    /// Terminate TLS with our own leaf cert, then serve HTTP over the
    /// decrypted stream, forwarding each request upstream over real TLS.
    async fn mitm_tunnel<S>(
        self: Arc<Self>,
        stream: S,
        host: String,
        authority: String,
        process: ProcessInfo,
    ) -> anyhow::Result<()>
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    {
        let config = self.tls_config_for(&host)?;
        let tls_stream = TlsAcceptor::from(config).accept(stream).await?;

        let engine = self.clone();
        let service = service_fn(move |req| {
            let engine = engine.clone();
            let authority = authority.clone();
            let process = process.clone();
            async move { engine.forward(req, Some(authority), process).await }
        });

        http1::Builder::new()
            .preserve_header_case(true)
            .serve_connection(TokioIo::new(tls_stream), service)
            .with_upgrades()
            .await?;
        Ok(())
    }

    fn tls_config_for(&self, host: &str) -> anyhow::Result<Arc<ServerConfig>> {
        if let Some(existing) = self.tls_configs.lock().get(host) {
            return Ok(existing.clone());
        }

        let (cert_pem, key_pem) = self.ca.leaf_for_host(host)?;
        let certs = rustls_pemfile::certs(&mut cert_pem.as_bytes()).collect::<Result<Vec<_>, _>>()?;
        let key = rustls_pemfile::private_key(&mut key_pem.as_bytes())?
            .ok_or_else(|| anyhow::anyhow!("no private key in generated leaf for {host}"))?;

        let mut config = ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certs, key)?;
        // We only speak HTTP/1.1 on the inner server; advertising h2 here
        // would make clients frame requests we can't parse.
        config.alpn_protocols = vec![b"http/1.1".to_vec()];

        let config = Arc::new(config);
        self.tls_configs
            .lock()
            .insert(host.to_string(), config.clone());
        Ok(config)
    }

    /// Relay one request upstream and record both halves.
    ///
    /// `tls_authority` is set when the request came off a MITM'd tunnel — in
    /// that case the request line is origin-form (`/path`) and we have to
    /// rebuild the absolute URL ourselves.
    async fn forward(
        self: Arc<Self>,
        req: Request<hyper::body::Incoming>,
        tls_authority: Option<String>,
        process: ProcessInfo,
    ) -> Result<Response<Full<Bytes>>, Infallible> {
        // WebSocket (and any other) Upgrade requests can't go through the
        // buffer-then-forward path below — there's no response to buffer,
        // just a raw duplex stream once the handshake completes. Splice
        // instead, before we consume `req`'s body.
        if is_upgrade_request(req.headers()) {
            let target = match absolute_uri(req.uri(), req.headers(), tls_authority.as_deref()) {
                Ok(uri) => uri,
                Err(e) => {
                    return Ok(status_response(
                        StatusCode::BAD_REQUEST,
                        &format!("cannot resolve target URL: {e}"),
                    ))
                }
            };
            return self
                .handle_upgrade(req, target, tls_authority.is_some(), process)
                .await;
        }

        let started = now_ms();
        let started_instant = std::time::Instant::now();

        let (parts, body) = req.into_parts();
        let method = parts.method.to_string();

        let target = match absolute_uri(&parts.uri, &parts.headers, tls_authority.as_deref()) {
            Ok(uri) => uri,
            Err(e) => {
                return Ok(status_response(
                    StatusCode::BAD_REQUEST,
                    &format!("cannot resolve target URL: {e}"),
                ))
            }
        };
        let target_host = target.host().unwrap_or("").to_string();

        // --- Block List ---
        // Checked before we even read the request body — a blocked request
        // never needs it. The client gets `status_code` immediately.
        if let Some(rule) = self.matching_block_rule(&target_host, target.path()) {
            let message = format!("Blocked by rule \"{}\"", rule.display_name);
            let status = StatusCode::from_u16(rule.status_code).unwrap_or(StatusCode::FORBIDDEN);
            if self.should_record(&target_host) {
                self.record(CapturedRequest {
                    id: uuid::Uuid::new_v4().to_string(),
                    process_name: process.name,
                    process_id: process.pid,
                    method,
                    url: target.to_string(),
                    request_headers: header_pairs(&parts.headers),
                    request_body_base64: None,
                    request_body_truncated: false,
                    status_code: Some(status.as_u16()),
                    response_headers: vec![],
                    response_body_base64: encode_body(&Bytes::from(message.clone())).0,
                    response_body_truncated: false,
                    started_at_ms: started,
                    duration_ms: Some(started_instant.elapsed().as_millis() as i64),
                    request_send_ms: None,
                    wait_ms: None,
                    response_receive_ms: None,
                    bytes_sent: 0,
                    bytes_received: 0,
                    intercepted_by: Some(format!("Block: {}", rule.display_name)),
                });
            }
            return Ok(status_response(status, &message));
        }

        let body_read_start = std::time::Instant::now();
        let req_body = match body.collect().await {
            Ok(c) => c.to_bytes(),
            Err(e) => {
                return Ok(status_response(
                    StatusCode::BAD_GATEWAY,
                    &format!("reading request body failed: {e}"),
                ))
            }
        };
        let request_send_ms = body_read_start.elapsed().as_millis() as i64;

        // --- Rewrite (request side) ---
        // Applied before dialing upstream, so header edits are part of what
        // actually goes out — not a display-only illusion. Everything below
        // that would otherwise read `parts.headers` uses this (possibly
        // edited) copy instead, so the capture matches what was really sent.
        let rewrite_rules = self.matching_rewrite_rules(&target_host, target.path());
        let mut request_headers = parts.headers.clone();
        for rule in &rewrite_rules {
            for action in &rule.actions {
                apply_request_rewrite(&mut request_headers, action);
            }
        }

        let (req_body_b64, req_body_truncated) =
            encode_body(&decompressed_for_display(&request_headers, &req_body));

        let record_failure = |engine: &ProxyEngine, message: String| {
            if !engine.should_record(&target_host) {
                return;
            }
            engine.record(CapturedRequest {
                id: uuid::Uuid::new_v4().to_string(),
                process_name: process.name.clone(),
                process_id: process.pid,
                method: method.clone(),
                url: target.to_string(),
                request_headers: header_pairs(&request_headers),
                request_body_base64: req_body_b64.clone(),
                request_body_truncated: req_body_truncated,
                status_code: None,
                response_headers: vec![],
                response_body_base64: encode_body(&Bytes::from(message)).0,
                response_body_truncated: false,
                started_at_ms: started,
                duration_ms: Some(started_instant.elapsed().as_millis() as i64),
                request_send_ms: Some(request_send_ms),
                wait_ms: None,
                response_receive_ms: None,
                bytes_sent: req_body.len() as u64,
                bytes_received: 0,
                intercepted_by: None,
            });
        };

        // --- Map Remote / DNS Spoofing ---
        // Both redial the request somewhere other than where it'd
        // otherwise go, before that dial happens. Map Remote wins if both
        // match — it fully decides the target (host, port, scheme), so a
        // DNS Spoof rule underneath it would be moot. Moot entirely if Map
        // Local below ends up serving the response, since then nothing
        // gets dialed at all.
        let map_remote = self.matching_map_remote(&target_host, target.path());
        let (dial_target, host_override, network_label) = match &map_remote {
            Some(rule) => match apply_map_remote(&target, rule) {
                Ok(new_target) => {
                    let host = new_target.authority().map(|a| a.to_string()).unwrap_or_else(|| rule.target_host.clone());
                    (new_target, Some(host), Some(format!("Map Remote: {}", rule.display_name)))
                }
                Err(_) => (target.clone(), None, None),
            },
            None => match self.matching_dns_spoof(&target_host) {
                Some(rule) => match apply_dns_spoof(&target, &rule) {
                    Ok(new_target) => (new_target, None, Some(format!("DNS Spoof: {}", rule.display_name))),
                    Err(_) => (target.clone(), None, None),
                },
                None => (target.clone(), None, None),
            },
        };

        // --- Map Local ---
        // Checked before we'd otherwise dial upstream: a match serves a
        // local file's bytes and skips the network entirely. A read failure
        // (missing file, permission denied) fails open — falls through to
        // the real network — rather than breaking the request.
        let map_local = self.matching_map_local(&method, &target.to_string());
        let mut intercepted_by: Option<String> = network_label;

        let (resp_status, resp_headers, resp_bytes, decompressed, wait_ms, receive_ms) = if let Some(rule) = &map_local {
            match tokio::fs::read(&rule.local_path).await {
                Ok(bytes) => {
                    // Map Local is terminal — nothing got dialed, so any
                    // Map Remote/DNS Spoof label computed above never
                    // actually applied and gets replaced rather than merged.
                    intercepted_by = Some(format!("Map Local: {}", rule.display_name));
                    let content_type = rule
                        .content_type
                        .clone()
                        .unwrap_or_else(|| guess_content_type(&rule.local_path).to_string());
                    let mut headers = HeaderMap::new();
                    if let Ok(v) = content_type.parse() {
                        headers.insert(hyper::header::CONTENT_TYPE, v);
                    }
                    let bytes = Bytes::from(bytes);
                    (StatusCode::OK, headers, bytes.clone(), bytes, None, None)
                }
                Err(e) => {
                    self.record_map_local_error(&rule.id, format!("couldn't read {}: {e}", rule.local_path));
                    match self.fetch_upstream(&dial_target, host_override.as_deref(), &parts.method, &request_headers, &req_body).await {
                        Ok((s, h, b, d, w, r)) => (s, h, b, d, Some(w), Some(r)),
                        Err(message) => {
                            record_failure(&self, message.clone());
                            return Ok(status_response(StatusCode::BAD_GATEWAY, &message));
                        }
                    }
                }
            }
        } else {
            match self.fetch_upstream(&dial_target, host_override.as_deref(), &parts.method, &request_headers, &req_body).await {
                Ok((s, h, b, d, w, r)) => (s, h, b, d, Some(w), Some(r)),
                Err(message) => {
                    record_failure(&self, message.clone());
                    return Ok(status_response(StatusCode::BAD_GATEWAY, &message));
                }
            }
        };

        // Defaults for the no-matching-rule case: the client gets exactly
        // what upstream sent (still compressed, if it was, or the raw Map
        // Local file bytes); the inspector stores the decompressed copy.
        // Only further interception (Mock, Rewrite) makes these two diverge
        // from their respective originals.
        let mut effective_status = resp_status;
        let mut effective_headers = resp_headers;
        let mut client_bytes = resp_bytes.clone();
        let mut display_bytes = decompressed.clone();

        if let Some(rule) = self.matching_rule(&method, &target.to_string()) {
            match String::from_utf8(decompressed.to_vec()) {
                Ok(body_text) => {
                    let js_req = interceptor::JsRequest {
                        method: method.clone(),
                        url: target.to_string(),
                        headers: header_pairs(&request_headers).into_iter().map(|h| (h.name, h.value)).collect(),
                        body: String::from_utf8(req_body.to_vec()).ok(),
                    };
                    let js_res = interceptor::JsResponse {
                        status: effective_status.as_u16(),
                        headers: header_pairs(&effective_headers).into_iter().map(|h| (h.name, h.value)).collect(),
                        body: body_text,
                    };
                    match interceptor::run_on_response(&rule.script, &js_req, &js_res) {
                        Ok(mutated) => {
                            effective_status = StatusCode::from_u16(mutated.status).unwrap_or(effective_status);
                            let mut headers = HeaderMap::new();
                            for (name, value) in &mutated.headers {
                                if let (Ok(hn), Ok(hv)) = (HeaderName::from_bytes(name.as_bytes()), value.parse()) {
                                    headers.append(hn, hv);
                                }
                            }
                            // The script handed back plain text; whatever
                            // compression the original body had no longer
                            // applies to it.
                            headers.remove(hyper::header::CONTENT_ENCODING);
                            effective_headers = headers;
                            let mutated_bytes = Bytes::from(mutated.body);
                            client_bytes = mutated_bytes.clone();
                            display_bytes = mutated_bytes;
                            intercepted_by = Some(match intercepted_by.take() {
                                Some(existing) => format!("{existing}, Mock: {}", rule.display_name),
                                None => format!("Mock: {}", rule.display_name),
                            });
                        }
                        Err(e) => self.record_rule_error(&rule.id, e),
                    }
                }
                Err(_) => self.record_rule_error(
                    &rule.id,
                    "response body isn't valid UTF-8 text — interceptor scripts can only run against text bodies".to_string(),
                ),
            }
        }

        // --- Rewrite (response side) ---
        // Applied after Mock, on top of whatever body is currently in play
        // (real upstream, Map Local, or Mock's mutation). Header/status
        // edits always apply; body text replace only fires if the body
        // decodes as UTF-8 — a binary body just quietly skips that one
        // action rather than corrupting it.
        if !rewrite_rules.is_empty() {
            let wants_body_edit = rewrite_rules
                .iter()
                .any(|r| r.actions.iter().any(|a| matches!(a, RewriteAction::ReplaceResponseBodyText { .. })));
            let mut body_text = if wants_body_edit { String::from_utf8(display_bytes.to_vec()).ok() } else { None };
            let mut body_touched = false;

            for rule in &rewrite_rules {
                let mut rule_applied = false;
                for action in &rule.actions {
                    if apply_response_rewrite(&mut effective_status, &mut effective_headers, &mut body_text, action) {
                        rule_applied = true;
                        if matches!(action, RewriteAction::ReplaceResponseBodyText { .. }) {
                            body_touched = true;
                        }
                    }
                }
                if rule_applied {
                    intercepted_by = Some(match intercepted_by.take() {
                        Some(existing) => format!("{existing}, Rewrite: {}", rule.display_name),
                        None => format!("Rewrite: {}", rule.display_name),
                    });
                }
            }

            if body_touched {
                if let Some(text) = body_text {
                    let bytes = Bytes::from(text);
                    client_bytes = bytes.clone();
                    display_bytes = bytes;
                }
            }
        }

        // --- Network Link Conditioner (Tools tab) ---
        // Applied last, against the final response we're about to send, so
        // both the client and the inspector see the same simulated outcome
        // — a developer testing "what does my app do on a bad connection"
        // needs the capture log to match what their app actually observed.
        if self.throttle_should_drop() {
            tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
            let message = "Simulated network loss (Tools \u{2192} Network Conditioner)";
            if self.should_record(&target_host) {
                self.record(CapturedRequest {
                    id: uuid::Uuid::new_v4().to_string(),
                    process_name: process.name,
                    process_id: process.pid,
                    method,
                    url: target.to_string(),
                    request_headers: header_pairs(&request_headers),
                    request_body_base64: req_body_b64,
                    request_body_truncated: req_body_truncated,
                    status_code: Some(StatusCode::GATEWAY_TIMEOUT.as_u16()),
                    response_headers: vec![],
                    response_body_base64: encode_body(&Bytes::from(message)).0,
                    response_body_truncated: false,
                    started_at_ms: started,
                    duration_ms: Some(started_instant.elapsed().as_millis() as i64),
                    request_send_ms: Some(request_send_ms),
                    wait_ms,
                    response_receive_ms: receive_ms,
                    bytes_sent: req_body.len() as u64,
                    bytes_received: 0,
                    intercepted_by: None,
                });
            }
            return Ok(status_response(StatusCode::GATEWAY_TIMEOUT, message));
        }
        if let Some(delay) = self.throttle_delay(client_bytes.len()) {
            tokio::time::sleep(delay).await;
        }

        let (resp_body_b64, resp_body_truncated) = encode_body(&display_bytes);

        if self.should_record(&target_host) {
            self.record(CapturedRequest {
                id: uuid::Uuid::new_v4().to_string(),
                process_name: process.name,
                process_id: process.pid,
                method,
                url: target.to_string(),
                request_headers: header_pairs(&request_headers),
                request_body_base64: req_body_b64,
                request_body_truncated: req_body_truncated,
                status_code: Some(effective_status.as_u16()),
                response_headers: header_pairs(&effective_headers),
                response_body_base64: resp_body_b64,
                response_body_truncated: resp_body_truncated,
                started_at_ms: started,
                duration_ms: Some(started_instant.elapsed().as_millis() as i64),
                request_send_ms: Some(request_send_ms),
                wait_ms,
                response_receive_ms: receive_ms,
                bytes_sent: req_body.len() as u64,
                bytes_received: client_bytes.len() as u64,
                intercepted_by,
            });
        }

        let mut out = Response::builder().status(effective_status);
        {
            let headers = out.headers_mut().expect("builder has no error yet");
            copy_headers(&effective_headers, headers);
            // We buffered the body, so any upstream chunked framing no
            // longer applies; hyper sets Content-Length from the payload.
            headers.remove(hyper::header::CONTENT_LENGTH);
        }
        Ok(out
            .body(Full::new(client_bytes))
            .unwrap_or_else(|_| Response::new(Full::new(Bytes::new()))))
    }

    /// Builds and sends the actual upstream request, returning the buffered
    /// `(status, headers, bytes-for-client, bytes-for-display, wait_ms,
    /// receive_ms)` on success — the shared tail in `forward` treats this
    /// identically to a Map Local hit. `wait_ms` bundles DNS + connect +
    /// TLS + server processing + TTFB (hyper's client doesn't expose those
    /// as separate hooks without a custom connector); `receive_ms` is just
    /// the response body read. Errors come back as a plain message so the
    /// caller can both record a failure entry and answer the client
    /// without duplicating that bookkeeping here.
    async fn fetch_upstream(
        &self,
        target: &Uri,
        host_override: Option<&str>,
        method: &Method,
        headers: &HeaderMap,
        body: &Bytes,
    ) -> Result<(StatusCode, HeaderMap, Bytes, Bytes, i64, i64), String> {
        let mut upstream = Request::builder().method(method).uri(target);
        {
            let out_headers = upstream.headers_mut().expect("builder has no error yet");
            copy_headers(headers, out_headers);
            // Set only when Map Remote redirected the dial elsewhere — the
            // Host header should match wherever we're actually connecting,
            // not the hostname the client originally asked for.
            if let Some(host) = host_override {
                if let Ok(v) = host.parse() {
                    out_headers.insert(hyper::header::HOST, v);
                }
            }
        }
        let upstream_req = upstream
            .body(Full::new(body.clone()))
            .map_err(|e| format!("malformed upstream request: {e}"))?;

        let wait_start = std::time::Instant::now();
        let response = self
            .client
            .request(upstream_req)
            .await
            .map_err(|e| format!("upstream request failed: {e}"))?;
        let wait_ms = wait_start.elapsed().as_millis() as i64;

        let (resp_parts, resp_body) = response.into_parts();
        let receive_start = std::time::Instant::now();
        let resp_bytes = resp_body
            .collect()
            .await
            .map_err(|e| format!("reading response body failed: {e}"))?
            .to_bytes();
        let receive_ms = receive_start.elapsed().as_millis() as i64;

        let decompressed = decompressed_for_display(&resp_parts.headers, &resp_bytes);
        Ok((resp_parts.status, resp_parts.headers, resp_bytes, decompressed, wait_ms, receive_ms))
    }

    /// Relay a WebSocket (or other `Upgrade:`) handshake: connect upstream
    /// ourselves, replay the client's handshake verbatim, and if upstream
    /// answers 101, splice the two raw duplex streams together. There's no
    /// buffered "response" here — once upgraded this is opaque bytes in
    /// both directions for the life of the connection, so no body capture.
    async fn handle_upgrade(
        self: Arc<Self>,
        req: Request<hyper::body::Incoming>,
        target: Uri,
        use_tls: bool,
        process: ProcessInfo,
    ) -> Result<Response<Full<Bytes>>, Infallible> {
        let host = target.host().unwrap_or_default().to_string();
        let port = target.port_u16().unwrap_or(if use_tls { 443 } else { 80 });
        let path = target
            .path_and_query()
            .map(|p| p.as_str().to_string())
            .unwrap_or_else(|| "/".to_string());
        let method = req.method().clone();
        let url = target.to_string();
        let request_headers = header_pairs(req.headers());

        let mut handshake = format!("{method} {path} HTTP/1.1\r\n");
        for (name, value) in req.headers() {
            // Hop-by-hop headers get dropped as usual, except the very ones
            // that make this an upgrade — those must reach upstream intact.
            let keep = !is_hop_by_hop(name)
                || *name == hyper::header::UPGRADE
                || *name == hyper::header::CONNECTION;
            if !keep {
                continue;
            }
            handshake.push_str(name.as_str());
            handshake.push_str(": ");
            handshake.push_str(value.to_str().unwrap_or(""));
            handshake.push_str("\r\n");
        }
        if !req.headers().contains_key(hyper::header::HOST) {
            handshake.push_str(&format!("Host: {host}\r\n"));
        }
        handshake.push_str("\r\n");

        let tcp = match TcpStream::connect((host.as_str(), port)).await {
            Ok(s) => s,
            Err(e) => {
                return Ok(status_response(
                    StatusCode::BAD_GATEWAY,
                    &format!("upstream connect failed: {e}"),
                ))
            }
        };

        let mut upstream: Box<dyn AsyncReadWrite> = if use_tls {
            let server_name = match ServerName::try_from(host.clone()) {
                Ok(sn) => sn,
                Err(_) => {
                    return Ok(status_response(StatusCode::BAD_GATEWAY, "invalid upstream hostname"))
                }
            };
            match TlsConnector::from(client_tls_config()).connect(server_name, tcp).await {
                Ok(tls) => Box::new(tls),
                Err(e) => {
                    return Ok(status_response(
                        StatusCode::BAD_GATEWAY,
                        &format!("upstream TLS handshake failed: {e}"),
                    ))
                }
            }
        } else {
            Box::new(tcp)
        };

        if let Err(e) = upstream.write_all(handshake.as_bytes()).await {
            return Ok(status_response(
                StatusCode::BAD_GATEWAY,
                &format!("writing upstream handshake failed: {e}"),
            ));
        }

        // Read the upstream status line + headers byte-by-byte — we can't
        // use a buffered reader here without risking consuming bytes that
        // belong to the post-handshake stream we're about to splice raw.
        let mut header_buf = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            match upstream.read(&mut byte).await {
                Ok(0) => break,
                Ok(_) => {
                    header_buf.push(byte[0]);
                    if header_buf.len() >= 4 && &header_buf[header_buf.len() - 4..] == b"\r\n\r\n" {
                        break;
                    }
                    if header_buf.len() > 16 * 1024 {
                        break;
                    }
                }
                Err(_) => break,
            }
        }

        let header_text = String::from_utf8_lossy(&header_buf);
        let mut lines = header_text.split("\r\n");
        let status_code = lines
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|code| code.parse::<u16>().ok())
            .unwrap_or(502);

        if status_code != 101 {
            let status = StatusCode::from_u16(status_code).unwrap_or(StatusCode::BAD_GATEWAY);
            return Ok(status_response(status, "upstream declined the upgrade"));
        }

        let mut resp = Response::builder().status(StatusCode::SWITCHING_PROTOCOLS);
        {
            let headers = resp.headers_mut().expect("builder has no error yet");
            for line in lines {
                if line.is_empty() {
                    continue;
                }
                let Some((name, value)) = line.split_once(':') else { continue };
                let name = name.trim();
                if HOP_BY_HOP.contains(&name.to_ascii_lowercase().as_str())
                    && !name.eq_ignore_ascii_case("connection")
                    && !name.eq_ignore_ascii_case("upgrade")
                {
                    continue;
                }
                if let (Ok(hname), Ok(hvalue)) = (
                    HeaderName::from_bytes(name.as_bytes()),
                    value.trim().parse(),
                ) {
                    headers.append(hname, hvalue);
                }
            }
        }
        let response = resp
            .body(Full::new(Bytes::new()))
            .unwrap_or_else(|_| Response::new(Full::new(Bytes::new())));

        if self.should_record(&host) {
            self.record(CapturedRequest {
                id: uuid::Uuid::new_v4().to_string(),
                process_name: process.name,
                process_id: process.pid,
                method: method.to_string(),
                url,
                request_headers,
                request_body_base64: None,
                request_body_truncated: false,
                status_code: Some(101),
                response_headers: vec![],
                response_body_base64: None,
                response_body_truncated: false,
                started_at_ms: now_ms(),
                duration_ms: None,
                request_send_ms: None,
                wait_ms: None,
                response_receive_ms: None,
                bytes_sent: 0,
                bytes_received: 0,
                intercepted_by: None,
            });
        }

        // The client side only becomes a raw stream once hyper has flushed
        // our 101 response, which happens after this handler returns — so
        // the splice runs in its own task rather than inline here.
        tokio::spawn(async move {
            match hyper::upgrade::on(req).await {
                Ok(upgraded) => {
                    let mut client_io = TokioIo::new(upgraded);
                    if let Err(e) = tokio::io::copy_bidirectional(&mut client_io, &mut upstream).await {
                        // Peer hangup mid-stream is routine for long-lived
                        // sockets, not worth alarming logs over.
                        let _ = e;
                    }
                }
                Err(e) => eprintln!("client-side upgrade failed: {e}"),
            }
        });

        Ok(response)
    }

    fn record(&self, req: CapturedRequest) {
        let mut store = self.store.lock();
        if store.len() >= MAX_STORED_REQUESTS {
            let overflow = store.len() - MAX_STORED_REQUESTS + 1;
            store.drain(0..overflow);
        }
        store.push(req);
    }
}

/// Resolve which local process owns the loopback connection using
/// `peer_port` (the client's ephemeral source port from our side). Runs
/// `lsof` once per accepted TCP connection. Best-effort: returns an empty
/// `ProcessInfo` if `lsof` is missing, denied, or the connection already
/// closed before we could look it up.
async fn resolve_process(peer_port: u16) -> ProcessInfo {
    let own_pid = std::process::id();

    let output = match tokio::process::Command::new("lsof")
        .args([
            "-n",
            "-P",
            "-i",
            &format!("tcp:{peer_port}"),
            "-sTCP:ESTABLISHED",
            "-Fpc",
        ])
        .output()
        .await
    {
        Ok(o) if o.status.success() => o,
        _ => return ProcessInfo::default(),
    };

    let text = String::from_utf8_lossy(&output.stdout);
    let mut current_pid: Option<u32> = None;
    for line in text.lines() {
        let Some(tag) = line.as_bytes().first() else { continue };
        let rest = &line[1..];
        match tag {
            b'p' => current_pid = rest.parse().ok(),
            b'c' => {
                if let Some(pid) = current_pid {
                    if pid != own_pid {
                        return ProcessInfo {
                            name: Some(rest.to_string()),
                            pid: Some(pid),
                        };
                    }
                }
            }
            _ => {}
        }
    }
    ProcessInfo::default()
}

/// Decompress a body for display purposes only, based on `Content-Encoding`.
/// The wire bytes we relay to the real client and count in
/// `bytes_sent`/`bytes_received` are untouched — this only affects what gets
/// stored for the inspector, same as Charles/Proxyman showing decoded JSON
/// even though the header still (accurately) says `gzip`. Falls back to the
/// original bytes on a corrupt/partial stream rather than losing the capture.
fn decompressed_for_display(headers: &HeaderMap, bytes: &Bytes) -> Bytes {
    let encoding = headers
        .get(hyper::header::CONTENT_ENCODING)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.to_ascii_lowercase());

    match encoding.as_deref() {
        Some("gzip") | Some("x-gzip") => {
            let mut out = Vec::new();
            match flate2::read::GzDecoder::new(&bytes[..]).read_to_end(&mut out) {
                Ok(_) => Bytes::from(out),
                Err(_) => bytes.clone(),
            }
        }
        Some("deflate") => {
            let mut out = Vec::new();
            match flate2::read::DeflateDecoder::new(&bytes[..]).read_to_end(&mut out) {
                Ok(_) => Bytes::from(out),
                Err(_) => bytes.clone(),
            }
        }
        _ => bytes.clone(),
    }
}

/// Base64-encode a body for FFI transport, capping how much we actually
/// retain. Returns `(None, false)` for an empty body.
fn encode_body(bytes: &Bytes) -> (Option<String>, bool) {
    if bytes.is_empty() {
        return (None, false);
    }
    let truncated = bytes.len() > BODY_CAPTURE_LIMIT;
    let slice = &bytes[..bytes.len().min(BODY_CAPTURE_LIMIT)];
    (Some(base64::engine::general_purpose::STANDARD.encode(slice)), truncated)
}

/// Rebuild the absolute request URL. Proxy clients send absolute-form for
/// plain HTTP; inside a MITM'd tunnel we get origin-form and supply the
/// scheme/authority from the CONNECT, falling back to the Host header.
fn absolute_uri(
    uri: &Uri,
    headers: &HeaderMap,
    tls_authority: Option<&str>,
) -> anyhow::Result<Uri> {
    if uri.scheme().is_some() && uri.authority().is_some() {
        return Ok(uri.clone());
    }

    let path = uri
        .path_and_query()
        .map(|p| p.as_str())
        .unwrap_or("/")
        .to_string();

    let (scheme, authority) = match tls_authority {
        Some(a) => ("https", a.to_string()),
        None => {
            let host = headers
                .get(hyper::header::HOST)
                .and_then(|h| h.to_str().ok())
                .ok_or_else(|| anyhow::anyhow!("origin-form request with no Host header"))?;
            ("http", host.to_string())
        }
    };

    Ok(Uri::builder()
        .scheme(scheme)
        .authority(authority)
        .path_and_query(path)
        .build()?)
}

fn copy_headers(from: &HeaderMap, to: &mut HeaderMap) {
    for (name, value) in from.iter() {
        if is_hop_by_hop(name) {
            continue;
        }
        to.append(name.clone(), value.clone());
    }
}

fn is_hop_by_hop(name: &HeaderName) -> bool {
    HOP_BY_HOP.contains(&name.as_str())
}

/// True for WebSocket (and any other) `Upgrade:` requests — these need the
/// raw-splice path in `handle_upgrade` instead of buffer-then-forward.
fn is_upgrade_request(headers: &HeaderMap) -> bool {
    let has_upgrade_token = headers
        .get(hyper::header::CONNECTION)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.to_ascii_lowercase().contains("upgrade"))
        .unwrap_or(false);
    has_upgrade_token && headers.contains_key(hyper::header::UPGRADE)
}

/// Trait object bound so `handle_upgrade` can hold either a raw `TcpStream`
/// or a `TlsStream<TcpStream>` behind one type.
trait AsyncReadWrite: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> AsyncReadWrite for T {}

/// Client-side TLS config for the raw upstream connections `handle_upgrade`
/// makes itself (outside hyper's own client, since we need a bare duplex
/// stream to splice, not a request/response client).
fn client_tls_config() -> Arc<ClientConfig> {
    static CONFIG: OnceLock<Arc<ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut roots = RootCertStore::empty();
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
            Arc::new(
                ClientConfig::builder()
                    .with_root_certificates(roots)
                    .with_no_client_auth(),
            )
        })
        .clone()
}

/// Rebuilds `target`'s scheme/host/port per `rule`, keeping the original
/// path and query intact — only where the request is dialed changes.
fn apply_map_remote(target: &Uri, rule: &MapRemoteRule) -> anyhow::Result<Uri> {
    let port = rule.target_port.unwrap_or(if rule.target_scheme.eq_ignore_ascii_case("https") { 443 } else { 80 });
    let default_port = if rule.target_scheme.eq_ignore_ascii_case("https") { 443 } else { 80 };
    let authority = if port == default_port {
        rule.target_host.clone()
    } else {
        format!("{}:{}", rule.target_host, port)
    };
    let path_and_query = target.path_and_query().map(|p| p.as_str()).unwrap_or("/").to_string();
    Ok(Uri::builder()
        .scheme(rule.target_scheme.as_str())
        .authority(authority)
        .path_and_query(path_and_query)
        .build()?)
}

/// Rebuilds `target`'s authority with `rule.spoof_ip` in place of the
/// hostname, keeping the original port/scheme/path/query — the request
/// dials a different address but otherwise looks untouched (no Host header
/// override, unlike `apply_map_remote`).
fn apply_dns_spoof(target: &Uri, rule: &DnsSpoofRule) -> anyhow::Result<Uri> {
    let port = target.port_u16().unwrap_or(if target.scheme_str() == Some("https") { 443 } else { 80 });
    let authority = format!("{}:{}", rule.spoof_ip, port);
    let path_and_query = target.path_and_query().map(|p| p.as_str()).unwrap_or("/").to_string();
    Ok(Uri::builder()
        .scheme(target.scheme_str().unwrap_or("http"))
        .authority(authority)
        .path_and_query(path_and_query)
        .build()?)
}

/// Applies the request-side subset of a `RewriteAction` to `headers` in
/// place. Response-side variants are no-ops here — `apply_response_rewrite`
/// handles those against the response instead.
fn apply_request_rewrite(headers: &mut HeaderMap, action: &RewriteAction) {
    match action {
        RewriteAction::AddRequestHeader { name, value } => {
            if let (Ok(n), Ok(v)) = (HeaderName::from_bytes(name.as_bytes()), value.parse()) {
                headers.append(n, v);
            }
        }
        RewriteAction::RemoveRequestHeader { name } => {
            if let Ok(n) = HeaderName::from_bytes(name.as_bytes()) {
                headers.remove(n);
            }
        }
        RewriteAction::ReplaceRequestHeader { name, value } => {
            if let (Ok(n), Ok(v)) = (HeaderName::from_bytes(name.as_bytes()), value.parse()) {
                headers.remove(&n);
                headers.append(n, v);
            }
        }
        _ => {}
    }
}

/// Applies the response-side subset of a `RewriteAction`. Returns whether
/// it actually did something, so the caller can decide whether this rule
/// counts as having applied (and skip re-encoding the body when nothing
/// touched it).
fn apply_response_rewrite(
    status: &mut StatusCode,
    headers: &mut HeaderMap,
    body_text: &mut Option<String>,
    action: &RewriteAction,
) -> bool {
    match action {
        RewriteAction::AddResponseHeader { name, value } => {
            match (HeaderName::from_bytes(name.as_bytes()), value.parse()) {
                (Ok(n), Ok(v)) => {
                    headers.append(n, v);
                    true
                }
                _ => false,
            }
        }
        RewriteAction::RemoveResponseHeader { name } => match HeaderName::from_bytes(name.as_bytes()) {
            Ok(n) => {
                headers.remove(n);
                true
            }
            Err(_) => false,
        },
        RewriteAction::ReplaceResponseHeader { name, value } => {
            match (HeaderName::from_bytes(name.as_bytes()), value.parse()) {
                (Ok(n), Ok(v)) => {
                    headers.remove(&n);
                    headers.append(n, v);
                    true
                }
                _ => false,
            }
        }
        RewriteAction::ReplaceStatusCode { status: s } => match StatusCode::from_u16(*s) {
            Ok(code) => {
                *status = code;
                true
            }
            Err(_) => false,
        },
        RewriteAction::ReplaceResponseBodyText { find, replace } => match body_text {
            Some(text) if text.contains(find.as_str()) => {
                *text = text.replace(find.as_str(), replace.as_str());
                true
            }
            _ => false,
        },
        RewriteAction::AddRequestHeader { .. }
        | RewriteAction::RemoveRequestHeader { .. }
        | RewriteAction::ReplaceRequestHeader { .. } => false,
    }
}

/// Content-Type for a Map Local response when the rule doesn't override
/// one, guessed from the file extension. Falls back to a generic binary
/// type rather than guessing wrong for something we don't recognize.
fn guess_content_type(path: &str) -> &'static str {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        "json" => "application/json",
        "html" | "htm" => "text/html",
        "xml" => "application/xml",
        "css" => "text/css",
        "js" => "application/javascript",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "svg" => "image/svg+xml",
        "txt" => "text/plain",
        "pdf" => "application/pdf",
        _ => "application/octet-stream",
    }
}

fn header_pairs(headers: &HeaderMap) -> Vec<HeaderPair> {
    headers
        .iter()
        .map(|(k, v)| HeaderPair {
            name: k.to_string(),
            value: v.to_str().unwrap_or("<binary>").to_string(),
        })
        .collect()
}

fn status_response(status: StatusCode, message: &str) -> Response<Full<Bytes>> {
    Response::builder()
        .status(status)
        .body(Full::new(Bytes::from(message.to_string())))
        .unwrap_or_else(|_| Response::new(Full::new(Bytes::new())))
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
