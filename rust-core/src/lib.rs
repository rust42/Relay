pub mod cert;
pub mod interceptor;
pub mod model;
pub mod proxy;

use cert::{CertAuthority, GeneratedCa};
use model::{
    AnalyticsEvent, BlockRule, CapturedRequest, DnsSpoofRule, FocusSettings, MapLocalRule, MapRemoteRule, MockRule,
    PipelineRule, ProxyState, RewriteRule, ThrottleProfile,
};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::watch;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ProxyError {
    #[error("{message}")]
    Startup { message: String },
}

/// Top-level object Swift instantiates once. Owns the tokio runtime, the
/// CA, the proxy engine task handle, and the list of captured requests
/// that the SwiftUI layer polls.
#[derive(uniffi::Object)]
pub struct RelayController {
    runtime: tokio::runtime::Runtime,
    ca: Arc<CertAuthority>,
    state: Mutex<ProxyState>,
    /// Shared with the running `ProxyEngine`, which appends to it directly.
    captured: Arc<Mutex<Vec<CapturedRequest>>>,
    /// Shared with the running `ProxyEngine` so rule edits take effect on
    /// in-flight traffic immediately, without a restart. Persisted to disk —
    /// unlike captured traffic, these are user-authored assets meant to
    /// outlive a single session.
    mock_rules: Arc<Mutex<Vec<MockRule>>>,
    mock_rules_path: PathBuf,
    /// Shared with the running `ProxyEngine` and persisted the same way
    /// `mock_rules` is.
    map_local_rules: Arc<Mutex<Vec<MapLocalRule>>>,
    map_local_rules_path: PathBuf,
    /// Shared with the running `ProxyEngine` and persisted the same way
    /// `mock_rules` is.
    map_remote_rules: Arc<Mutex<Vec<MapRemoteRule>>>,
    map_remote_rules_path: PathBuf,
    /// Shared with the running `ProxyEngine` and persisted the same way
    /// `mock_rules` is.
    rewrite_rules: Arc<Mutex<Vec<RewriteRule>>>,
    rewrite_rules_path: PathBuf,
    /// Shared with the running `ProxyEngine` and persisted the same way
    /// `mock_rules` is.
    block_rules: Arc<Mutex<Vec<BlockRule>>>,
    block_rules_path: PathBuf,
    /// Shared with the running `ProxyEngine` and persisted the same way
    /// `mock_rules` is.
    dns_spoof_rules: Arc<Mutex<Vec<DnsSpoofRule>>>,
    dns_spoof_rules_path: PathBuf,
    /// Shared with the running `ProxyEngine`. Not persisted — like
    /// `throttle`, this is a live "what am I looking at" toggle, not a
    /// user-authored asset meant to outlive a session.
    focus: Arc<Mutex<FocusSettings>>,
    /// Shared with the running `ProxyEngine` and persisted the same way
    /// `mock_rules` is.
    pipeline_rules: Arc<Mutex<Vec<PipelineRule>>>,
    pipeline_rules_path: PathBuf,
    /// Shared with the running `ProxyEngine` the same way `mock_rules` is.
    /// Intentionally *not* persisted to disk — unlike mock rules, this is a
    /// live "current conditions" toggle, not a user-authored asset, and
    /// starting each launch with throttling off is the safer default.
    throttle: Arc<Mutex<ThrottleProfile>>,
    /// Where `ProxyEngine` appends one compact JSON line per request, and
    /// where `analytics_events` reads them back from. Append-only, capped
    /// (see `proxy.rs`'s truncation logic) — not loaded into memory here,
    /// unlike the rule lists, since it's queried far less often than it's
    /// written and there's no in-flight state to keep in sync.
    analytics_path: PathBuf,
    /// `Some` while the proxy is running; dropping/sending stops the accept loop.
    shutdown: Mutex<Option<watch::Sender<bool>>>,
}

#[uniffi::export]
impl RelayController {
    /// `data_dir` is where the root CA PEMs and mock rules are persisted, so
    /// both survive across launches.
    #[uniffi::constructor]
    pub fn new(data_dir: String) -> Arc<Self> {
        let dir = std::path::Path::new(&data_dir);
        let ca = Arc::new(CertAuthority::load_or_generate(dir).expect("CA load/generation failed"));
        let runtime = tokio::runtime::Runtime::new().expect("failed to start tokio runtime");

        let mock_rules_path = dir.join("mock-rules.json");
        let mock_rules = std::fs::read_to_string(&mock_rules_path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<MockRule>>(&s).ok())
            .unwrap_or_default();

        let map_local_rules_path = dir.join("map-local-rules.json");
        let map_local_rules = std::fs::read_to_string(&map_local_rules_path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<MapLocalRule>>(&s).ok())
            .unwrap_or_default();

        let map_remote_rules_path = dir.join("map-remote-rules.json");
        let map_remote_rules = std::fs::read_to_string(&map_remote_rules_path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<MapRemoteRule>>(&s).ok())
            .unwrap_or_default();

        let rewrite_rules_path = dir.join("rewrite-rules.json");
        let rewrite_rules = std::fs::read_to_string(&rewrite_rules_path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<RewriteRule>>(&s).ok())
            .unwrap_or_default();

        let block_rules_path = dir.join("block-rules.json");
        let block_rules = std::fs::read_to_string(&block_rules_path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<BlockRule>>(&s).ok())
            .unwrap_or_default();

        let dns_spoof_rules_path = dir.join("dns-spoof-rules.json");
        let dns_spoof_rules = std::fs::read_to_string(&dns_spoof_rules_path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<DnsSpoofRule>>(&s).ok())
            .unwrap_or_default();

        let pipeline_rules_path = dir.join("pipeline-rules.json");
        let pipeline_rules = std::fs::read_to_string(&pipeline_rules_path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<PipelineRule>>(&s).ok())
            .unwrap_or_default();

        let analytics_path = dir.join("analytics.jsonl");

        Arc::new(Self {
            runtime,
            ca,
            state: Mutex::new(ProxyState::Stopped),
            captured: Arc::new(Mutex::new(Vec::new())),
            mock_rules: Arc::new(Mutex::new(mock_rules)),
            mock_rules_path,
            map_local_rules: Arc::new(Mutex::new(map_local_rules)),
            map_local_rules_path,
            map_remote_rules: Arc::new(Mutex::new(map_remote_rules)),
            map_remote_rules_path,
            rewrite_rules: Arc::new(Mutex::new(rewrite_rules)),
            rewrite_rules_path,
            block_rules: Arc::new(Mutex::new(block_rules)),
            block_rules_path,
            dns_spoof_rules: Arc::new(Mutex::new(dns_spoof_rules)),
            dns_spoof_rules_path,
            focus: Arc::new(Mutex::new(FocusSettings::default())),
            pipeline_rules: Arc::new(Mutex::new(pipeline_rules)),
            pipeline_rules_path,
            throttle: Arc::new(Mutex::new(ThrottleProfile::default())),
            analytics_path,
            shutdown: Mutex::new(None),
        })
    }

    /// PEM pair for the root CA. Swift installs this into the login
    /// Keychain via SecTrustSettingsSetTrustSettings on first run.
    pub fn root_ca(&self) -> GeneratedCa {
        self.ca.exported()
    }

    pub fn state(&self) -> ProxyState {
        *self.state.lock()
    }

    /// Start the proxy listening on 127.0.0.1:port. Binds synchronously so
    /// that a port conflict is reported to the caller rather than
    /// disappearing into a background task.
    pub fn start(&self, port: u16) -> Result<(), ProxyError> {
        if *self.state.lock() == ProxyState::Running {
            return Ok(());
        }
        *self.state.lock() = ProxyState::Starting;

        let addr: std::net::SocketAddr = ([127, 0, 0, 1], port).into();
        let listener = match self.runtime.block_on(tokio::net::TcpListener::bind(addr)) {
            Ok(l) => l,
            Err(e) => {
                *self.state.lock() = ProxyState::Error;
                return Err(ProxyError::Startup {
                    message: format!("could not bind 127.0.0.1:{port}: {e}"),
                });
            }
        };

        let engine = Arc::new(proxy::ProxyEngine::new(
            self.ca.clone(),
            self.captured.clone(),
            self.mock_rules.clone(),
            self.map_local_rules.clone(),
            self.map_remote_rules.clone(),
            self.rewrite_rules.clone(),
            self.block_rules.clone(),
            self.dns_spoof_rules.clone(),
            self.focus.clone(),
            self.pipeline_rules.clone(),
            self.throttle.clone(),
            self.analytics_path.clone(),
        ));
        let (tx, rx) = watch::channel(false);
        *self.shutdown.lock() = Some(tx);

        self.runtime.spawn(async move {
            if let Err(e) = engine.serve(listener, rx).await {
                eprintln!("proxy engine exited: {e}");
            }
        });

        *self.state.lock() = ProxyState::Running;
        Ok(())
    }

    pub fn stop(&self) {
        if let Some(tx) = self.shutdown.lock().take() {
            let _ = tx.send(true);
        }
        *self.state.lock() = ProxyState::Stopped;
    }

    /// Most recent requests, newest first.
    pub fn recent_requests(&self, limit: u32) -> Vec<CapturedRequest> {
        let store = self.captured.lock();
        store.iter().rev().take(limit as usize).cloned().collect()
    }

    pub fn clear_requests(&self) {
        self.captured.lock().clear();
    }

    /// Replaces the full rule set and persists it to disk. Takes effect on
    /// the next request — the running `ProxyEngine` reads through the same
    /// `Arc<Mutex<..>>`, no restart needed.
    pub fn set_mock_rules(&self, rules: Vec<MockRule>) {
        *self.mock_rules.lock() = rules.clone();
        if let Ok(json) = serde_json::to_string_pretty(&rules) {
            let _ = std::fs::write(&self.mock_rules_path, json);
        }
    }

    pub fn mock_rules(&self) -> Vec<MockRule> {
        self.mock_rules.lock().clone()
    }

    /// Replaces the full Map Local rule set and persists it to disk. Same
    /// live-update mechanism as `set_mock_rules`.
    pub fn set_map_local_rules(&self, rules: Vec<MapLocalRule>) {
        *self.map_local_rules.lock() = rules.clone();
        if let Ok(json) = serde_json::to_string_pretty(&rules) {
            let _ = std::fs::write(&self.map_local_rules_path, json);
        }
    }

    pub fn map_local_rules(&self) -> Vec<MapLocalRule> {
        self.map_local_rules.lock().clone()
    }

    /// Replaces the full Map Remote rule set and persists it to disk. Same
    /// live-update mechanism as `set_mock_rules`.
    pub fn set_map_remote_rules(&self, rules: Vec<MapRemoteRule>) {
        *self.map_remote_rules.lock() = rules.clone();
        if let Ok(json) = serde_json::to_string_pretty(&rules) {
            let _ = std::fs::write(&self.map_remote_rules_path, json);
        }
    }

    pub fn map_remote_rules(&self) -> Vec<MapRemoteRule> {
        self.map_remote_rules.lock().clone()
    }

    /// Replaces the full Rewrite rule set and persists it to disk. Same
    /// live-update mechanism as `set_mock_rules`.
    pub fn set_rewrite_rules(&self, rules: Vec<RewriteRule>) {
        *self.rewrite_rules.lock() = rules.clone();
        if let Ok(json) = serde_json::to_string_pretty(&rules) {
            let _ = std::fs::write(&self.rewrite_rules_path, json);
        }
    }

    pub fn rewrite_rules(&self) -> Vec<RewriteRule> {
        self.rewrite_rules.lock().clone()
    }

    /// Replaces the full Block List and persists it to disk. Same
    /// live-update mechanism as `set_mock_rules`.
    pub fn set_block_rules(&self, rules: Vec<BlockRule>) {
        *self.block_rules.lock() = rules.clone();
        if let Ok(json) = serde_json::to_string_pretty(&rules) {
            let _ = std::fs::write(&self.block_rules_path, json);
        }
    }

    pub fn block_rules(&self) -> Vec<BlockRule> {
        self.block_rules.lock().clone()
    }

    /// Replaces the full DNS Spoofing rule set and persists it to disk.
    /// Same live-update mechanism as `set_mock_rules`.
    pub fn set_dns_spoof_rules(&self, rules: Vec<DnsSpoofRule>) {
        *self.dns_spoof_rules.lock() = rules.clone();
        if let Ok(json) = serde_json::to_string_pretty(&rules) {
            let _ = std::fs::write(&self.dns_spoof_rules_path, json);
        }
    }

    pub fn dns_spoof_rules(&self) -> Vec<DnsSpoofRule> {
        self.dns_spoof_rules.lock().clone()
    }

    /// Takes effect on the next request — same live-update mechanism as
    /// mock rules, via the shared `Arc<Mutex<..>>`. Not persisted, same
    /// reasoning as `throttle`.
    pub fn set_focus(&self, settings: FocusSettings) {
        *self.focus.lock() = settings;
    }

    pub fn focus(&self) -> FocusSettings {
        self.focus.lock().clone()
    }

    /// Replaces the full pipeline set and persists it to disk. Same
    /// live-update mechanism as `set_mock_rules`.
    pub fn set_pipeline_rules(&self, rules: Vec<PipelineRule>) {
        *self.pipeline_rules.lock() = rules.clone();
        if let Ok(json) = serde_json::to_string_pretty(&rules) {
            let _ = std::fs::write(&self.pipeline_rules_path, json);
        }
    }

    pub fn pipeline_rules(&self) -> Vec<PipelineRule> {
        self.pipeline_rules.lock().clone()
    }

    /// Most recent Analytics events, newest first, capped at `limit`. Reads
    /// and parses the whole (size-capped, see `proxy.rs`) log file fresh
    /// each call rather than keeping an in-memory mirror — simpler, and
    /// this is queried far less often than it's written.
    pub fn analytics_events(&self, limit: u32) -> Vec<AnalyticsEvent> {
        let Ok(content) = std::fs::read_to_string(&self.analytics_path) else {
            return Vec::new();
        };
        let mut events: Vec<AnalyticsEvent> = content
            .lines()
            .filter_map(|line| serde_json::from_str(line).ok())
            .collect();
        events.reverse();
        events.truncate(limit as usize);
        events
    }

    /// Takes effect on the next request — same live-update mechanism as
    /// mock rules, via the shared `Arc<Mutex<..>>`.
    pub fn set_throttle_profile(&self, profile: ThrottleProfile) {
        *self.throttle.lock() = profile;
    }

    pub fn throttle_profile(&self) -> ThrottleProfile {
        *self.throttle.lock()
    }
}
