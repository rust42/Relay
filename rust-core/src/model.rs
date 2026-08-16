use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct CapturedRequest {
    pub id: String,
    /// Owning process, resolved from the loopback connection's ephemeral
    /// port via `lsof` at accept time. `None` when resolution fails (lsof
    /// missing, permission denied, or the connection closed before we could
    /// look it up) — the UI groups these under "Unknown".
    pub process_name: Option<String>,
    /// Present only when `process_name` came from a GUI app, so the UI can
    /// fetch a real app icon via `NSRunningApplication`. CLI tools resolve a
    /// name but not a GUI-owning pid.
    pub process_id: Option<u32>,
    pub method: String,
    pub url: String,
    pub request_headers: Vec<HeaderPair>,
    /// Base64 of the raw request body, capped at `BODY_CAPTURE_LIMIT` so a
    /// large upload doesn't bloat the FFI payload — full body is still
    /// forwarded upstream regardless of this cap.
    pub request_body_base64: Option<String>,
    pub request_body_truncated: bool,
    pub status_code: Option<u16>,
    pub response_headers: Vec<HeaderPair>,
    pub response_body_base64: Option<String>,
    pub response_body_truncated: bool,
    pub started_at_ms: i64,
    pub duration_ms: Option<i64>,
    /// Coarse timing breakdown — three phases, not the full DNS/connect/TLS
    /// waterfall Charles/Proxyman show, since that needs per-phase hooks
    /// into the HTTP client's connector that this proxy doesn't have.
    /// `None` for exchanges that never touched the network (Map Local,
    /// Block). Time spent reading/forwarding the request body.
    pub request_send_ms: Option<i64>,
    /// Time from finishing the request to receiving response headers —
    /// bundles DNS + connect + TLS + server processing + TTFB together.
    pub wait_ms: Option<i64>,
    /// Time spent reading the response body.
    pub response_receive_ms: Option<i64>,
    pub bytes_sent: u64,
    pub bytes_received: u64,
    /// Describes whichever interception mechanism(s) modified this exchange
    /// (mock script, Map Local, ...), joined if more than one applied, so
    /// the UI can badge it. `None` means the response is exactly what
    /// upstream sent.
    pub intercepted_by: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct HeaderPair {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyState {
    Stopped,
    Starting,
    Running,
    Error,
}

/// A JS interceptor rule: requests matching `method`/`url_contains` get their
/// response run through `script`, which must define
/// `function onResponse(req, res) { ... }`. `req`/`res` are plain JS objects
/// (`{method, url, headers}` / `{status, headers, body}`); mutating `res` and
/// returning it changes what the real client receives.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct MockRule {
    pub id: String,
    pub display_name: String,
    /// `None` matches any method.
    pub method: Option<String>,
    /// Substring match against the request URL.
    pub url_contains: String,
    pub enabled: bool,
    pub script: String,
    /// Set when the script last threw/failed to parse, so the UI can surface
    /// it instead of silently passing traffic through unmodified.
    pub last_error: Option<String>,
}

/// A rule that serves a local file's bytes as the response instead of ever
/// contacting upstream — Charles's "Map Local" tool. Useful for working
/// against a fixture without a real backend, or offline. Matching follows
/// `MockRule`'s substring style for consistency.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct MapLocalRule {
    pub id: String,
    pub display_name: String,
    /// `None` matches any method.
    pub method: Option<String>,
    /// Substring match against the request URL.
    pub url_contains: String,
    pub enabled: bool,
    pub local_path: String,
    /// Overrides the content type guessed from `local_path`'s extension.
    pub content_type: Option<String>,
    /// Set when the file couldn't be read at request time (missing,
    /// permission denied) — the request falls through to the real network
    /// rather than failing, and the UI surfaces this like a mock script error.
    pub last_error: Option<String>,
}

/// Redirects matching requests to a different host/port before they're
/// dialed upstream — Charles's "Map Remote" tool. The client still sees the
/// original hostname (our MITM cert is minted for that host); only where
/// the proxy actually connects changes.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct MapRemoteRule {
    pub id: String,
    pub display_name: String,
    pub enabled: bool,
    /// Substring match against the original request's host.
    pub match_host: String,
    /// Substring match against the original request's path; "" matches any.
    pub match_path_contains: String,
    /// "http" or "https".
    pub target_scheme: String,
    pub target_host: String,
    /// `None` uses the scheme's default (80/443).
    pub target_port: Option<u16>,
}

/// A single request/response edit applied by a `RewriteRule`. Kept as one
/// enum per concrete operation — rather than a generic key/value shape — so
/// the Swift UI can present a fixed action picker instead of a free-form
/// form that could describe something the engine can't actually do.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Enum)]
pub enum RewriteAction {
    AddRequestHeader { name: String, value: String },
    RemoveRequestHeader { name: String },
    ReplaceRequestHeader { name: String, value: String },
    AddResponseHeader { name: String, value: String },
    RemoveResponseHeader { name: String },
    ReplaceResponseHeader { name: String, value: String },
    ReplaceStatusCode { status: u16 },
    /// Plain substring find/replace against the (UTF-8-decoded) response
    /// body — not regex, matching the substring-match style the rest of
    /// this app's rule engines use.
    ReplaceResponseBodyText { find: String, replace: String },
}

/// An ordered list of `RewriteAction`s applied to matching requests —
/// Charles's "Rewrite" tool. Unlike `MockRule`'s JS scripting, this is a
/// no-code list of structured edits; unlike `MapLocalRule`/`MapRemoteRule`,
/// it never changes where a request goes, only what's in it.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct RewriteRule {
    pub id: String,
    pub display_name: String,
    pub enabled: bool,
    /// Substring match against the request host; "" matches any.
    pub host_contains: String,
    /// Substring match against the request path; "" matches any.
    pub path_contains: String,
    pub actions: Vec<RewriteAction>,
}

/// A compact, cross-session record of one exchange — everything Analytics
/// needs (timing, status, size, host) and nothing it doesn't (no headers,
/// no bodies). Kept deliberately separate from `CapturedRequest`: that one
/// lives in memory only and is wiped on stop/quit, while this is appended
/// to disk on every request so historical trends survive restarts without
/// paying the storage cost of persisting every captured body forever.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct AnalyticsEvent {
    pub timestamp_ms: i64,
    pub method: String,
    pub host: String,
    pub status_code: Option<u16>,
    pub duration_ms: Option<i64>,
    pub bytes_sent: u64,
    pub bytes_received: u64,
}

/// One step in a `PipelineRule`. Filter steps gate whether later steps in
/// the same pipeline run; the rest are actions. Request-side steps
/// (filters on host/path/method, request header injection) must run before
/// any response-side step (status filter, response header/body edits,
/// status override) in a pipeline's step list — see the doc comment on
/// pipeline execution in `proxy.rs` for exactly why and what that means in
/// practice.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Enum)]
pub enum PipelineStep {
    FilterHostContains { value: String },
    FilterPathContains { value: String },
    FilterMethod { method: String },
    AddRequestHeader { name: String, value: String },
    FilterResponseStatus { status: u16 },
    AddResponseHeader { name: String, value: String },
    ReplaceResponseBodyText { find: String, replace: String },
    SetResponseStatus { status: u16 },
}

/// Charles/Proxyman-style "visual scripting": an ordered, no-code chain of
/// filters and actions that runs against live traffic. Delivered as a
/// linear step sequence (see `PipelineStep`) rather than a free-form
/// drag-and-drop 2D node graph with wires — that interaction model is a
/// much larger, gesture-heavy UI undertaking; this keeps the actual
/// "chain filters + header injection + body modifiers" capability the
/// description promises without it.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct PipelineRule {
    pub id: String,
    pub display_name: String,
    pub enabled: bool,
    pub steps: Vec<PipelineStep>,
}

/// Refuses matching requests outright instead of forwarding them —
/// Charles/Proxyman's "Block List". A match never touches the network; the
/// client gets `status_code` immediately.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct BlockRule {
    pub id: String,
    pub display_name: String,
    pub enabled: bool,
    /// "" matches any host.
    pub host_contains: String,
    /// "" matches any path.
    pub path_contains: String,
    pub status_code: u16,
}

/// When `enabled` and `hosts` is non-empty, only requests whose host
/// matches one of `hosts` get recorded — Charles's "Focus". Traffic that
/// doesn't match still passes through completely untouched; this only
/// narrows what shows up in the inspector, so it never breaks anything the
/// way a Block rule could. Global, engine-wide, like `ThrottleProfile` —
/// not a per-rule list, since it describes "what am I looking at right
/// now", not a traffic-modification rule.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct FocusSettings {
    pub enabled: bool,
    pub hosts: Vec<String>,
}

impl Default for FocusSettings {
    fn default() -> Self {
        Self { enabled: false, hosts: Vec::new() }
    }
}

/// Redials a matching request against a specific IP instead of letting it
/// resolve normally — Charles's "DNS Spoofing". Unlike `MapRemoteRule`, the
/// Host header (and everything else about the logical request) stays
/// exactly as the client sent it; only which address gets dialed changes.
///
/// Caveat worth knowing: for HTTPS targets, TLS SNI during the upstream
/// handshake still follows the dial address (the spoofed IP), not the
/// original hostname — this proxy doesn't hook DNS resolution itself, it
/// swaps the dial target. That means this works reliably for HTTP and for
/// HTTPS servers that don't do strict SNI-based virtual hosting; a server
/// that requires SNI to match the real hostname needs resolver-level
/// spoofing instead, which is a much bigger change (a custom connector).
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct DnsSpoofRule {
    pub id: String,
    pub display_name: String,
    pub enabled: bool,
    /// Substring match against the request host.
    pub host: String,
    pub spoof_ip: String,
}

/// Simulated network conditions applied to every response relayed through
/// the proxy: an artificial delay approximating "it took this long to
/// transfer at X kbps", plus optional simulated total request failure.
/// Applied engine-wide (not per-rule) — this models link conditions, not
/// per-endpoint mocking, which `MockRule` already covers.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct ThrottleProfile {
    pub enabled: bool,
    /// Simulated download rate in kbps; 0 = unlimited.
    pub down_kbps: u32,
    /// Simulated upload rate in kbps; 0 = unlimited.
    pub up_kbps: u32,
    /// Fixed extra latency injected per request, in milliseconds.
    pub latency_ms: u32,
    /// Probability (0.0–1.0) that a given request is simulated as a total
    /// network failure instead of being relayed at all.
    pub loss_probability: f32,
}

impl Default for ThrottleProfile {
    fn default() -> Self {
        Self {
            enabled: false,
            down_kbps: 0,
            up_kbps: 0,
            latency_ms: 0,
            loss_probability: 0.0,
        }
    }
}
