import Foundation
import Combine
import AppKit

/// Named presets for the Tools tab's Network Link Conditioner — the same
/// idea as macOS's own Network Link Conditioner, applied inside our proxy
/// instead of at the OS level so it only affects traffic actually routed
/// through us. Bandwidth figures for 3G/Edge/Very Bad are standard rough
/// real-world approximations, not measured from anything.
enum ThrottlePreset: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case threeG = "3G"
    case edge = "Edge"
    case veryBad = "Very Bad"
    case totalLoss = "100% Loss"
    var id: String { rawValue }

    var profile: ThrottleProfile {
        switch self {
        case .off:
            return ThrottleProfile(enabled: false, downKbps: 0, upKbps: 0, latencyMs: 0, lossProbability: 0)
        case .threeG:
            return ThrottleProfile(enabled: true, downKbps: 780, upKbps: 330, latencyMs: 100, lossProbability: 0)
        case .edge:
            return ThrottleProfile(enabled: true, downKbps: 240, upKbps: 200, latencyMs: 400, lossProbability: 0)
        case .veryBad:
            return ThrottleProfile(enabled: true, downKbps: 50, upKbps: 20, latencyMs: 1000, lossProbability: 0)
        case .totalLoss:
            return ThrottleProfile(enabled: true, downKbps: 0, upKbps: 0, latencyMs: 0, lossProbability: 1.0)
        }
    }
}

enum RoutingMode: String {
    /// Only the browsers the user explicitly picked get relaunched with
    /// `--proxy-server` pointed at us. Nothing else on the Mac is touched —
    /// this is the default specifically because system-wide mode routes
    /// *everything*, including apps with certificate pinning or bugs that
    /// have nothing to do with what you're trying to inspect.
    case selectedApps
    /// The old behavior: every app on the Mac routes through us via
    /// SCPreferences. Useful for full-machine capture, but "Chrome stopped
    /// working" is exactly the failure mode this mode invites.
    case systemWide
}

/// Thin ObservableObject wrapper around the Rust `CharlesController`.
/// Bridges Rust's pull-based `recentRequests(limit:)` into something
/// SwiftUI can observe, and owns install/trust of the root CA plus routing
/// (either selected-apps-only via browser relaunch, or system-wide).
@MainActor
final class ProxyModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var requests: [CapturedRequestDisplay] = []
    @Published private(set) var status = "Idle"
    @Published var errorMessage: String?

    @Published private(set) var routingMode: RoutingMode
    @Published private(set) var proxiedBundleIDs: Set<String>
    @Published private(set) var availableBrowsers: [ProxiedBrowser] = ProxiedBrowserCatalog.installed()
    @Published private(set) var relaunchInFlight: Set<String> = []

    @Published private(set) var mockRules: [MockRuleDisplay] = []
    @Published private(set) var mapLocalRules: [MapLocalRuleDisplay] = []
    @Published private(set) var mapRemoteRules: [MapRemoteRuleDisplay] = []
    @Published private(set) var rewriteRules: [RewriteRuleDisplay] = []
    @Published private(set) var blockRules: [BlockRuleDisplay] = []
    @Published private(set) var dnsSpoofRules: [DnsSpoofRuleDisplay] = []
    @Published private(set) var focusEnabled = false
    @Published private(set) var focusHosts: [String] = []
    @Published private(set) var throttlePreset: ThrottlePreset = .off

    let port: UInt16 = 8899

    private let controller: CharlesController
    private var pollTask: Task<Void, Never>?

    private static let routingModeKey = "CharlesRS.routingMode"
    private static let proxiedBundleIDsKey = "CharlesRS.proxiedBundleIDs"

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CharlesRS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        controller = CharlesController(dataDir: support.path)

        let defaults = UserDefaults.standard
        routingMode = defaults.string(forKey: Self.routingModeKey).flatMap(RoutingMode.init) ?? .selectedApps
        proxiedBundleIDs = Set(defaults.stringArray(forKey: Self.proxiedBundleIDsKey) ?? [])

        mockRules = controller.mockRules().map(MockRuleDisplay.init)
        mapLocalRules = controller.mapLocalRules().map(MapLocalRuleDisplay.init)
        mapRemoteRules = controller.mapRemoteRules().map(MapRemoteRuleDisplay.init)
        rewriteRules = controller.rewriteRules().map(RewriteRuleDisplay.init)
        blockRules = controller.blockRules().map(BlockRuleDisplay.init)
        dnsSpoofRules = controller.dnsSpoofRules().map(DnsSpoofRuleDisplay.init)
        let focus = controller.focus()
        focusEnabled = focus.enabled
        focusHosts = focus.hosts
    }

    /// Path of the root CA on disk, handy for `curl --cacert` and for the
    /// "Reveal in Finder" affordance.
    var rootCAPath: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CharlesRS/charlesrs-ca.pem")
            .path
    }

    var isRootCATrusted: Bool {
        KeychainTrust.isTrusted(pem: controller.rootCa().certPem)
    }

    func start() {
        errorMessage = nil
        do {
            // Trust first: if the CA isn't trusted, every HTTPS interception
            // fails the handshake and the app looks broken for non-obvious
            // reasons.
            status = "Installing root certificate…"
            try KeychainTrust.installIfNeeded(pem: controller.rootCa().certPem)

            status = "Starting proxy on 127.0.0.1:\(port)…"
            try controller.start(port: port)

            isRunning = true
            startPolling()

            switch routingMode {
            case .systemWide:
                status = "Routing all system traffic…"
                try SystemProxyConfig.enable(host: "127.0.0.1", port: Int(port))
                status = "Capturing system-wide on 127.0.0.1:\(port)"
            case .selectedApps:
                status = proxiedBundleIDs.isEmpty
                    ? "Running — pick an app to proxy"
                    : "Relaunching \(proxiedBundleIDs.count) app(s)…"
                Task { await self.relaunchSelected(proxied: true) }
            }
        } catch {
            // Roll back anything that did succeed, so a partial start can't
            // leave the machine pointed at a proxy that isn't running.
            controller.stop()
            try? SystemProxyConfig.disable()
            isRunning = false
            status = "Idle"
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil

        switch routingMode {
        case .systemWide:
            do {
                try SystemProxyConfig.disable()
            } catch {
                errorMessage = "Proxy stopped, but restoring system network settings failed: "
                    + error.localizedDescription
            }
        case .selectedApps:
            Task { await self.relaunchSelected(proxied: false) }
        }

        controller.stop()
        isRunning = false
        status = "Idle"
    }

    func clear() {
        controller.clearRequests()
        requests = []
        bookmarkedIDs = []
        notes = [:]
    }

    /// Bookmarks and notes are pure client-side annotations, keyed by
    /// request id — the Rust engine has no concept of them. Session-scoped
    /// (cleared alongside `clear()`) unless saved out via `exportSession()`,
    /// which round-trips them.
    @Published private(set) var bookmarkedIDs: Set<String> = []
    @Published private(set) var notes: [String: String] = [:]

    func toggleBookmark(id: String) {
        if bookmarkedIDs.contains(id) {
            bookmarkedIDs.remove(id)
        } else {
            bookmarkedIDs.insert(id)
        }
    }

    func setNote(id: String, text: String) {
        if text.isEmpty {
            notes.removeValue(forKey: id)
        } else {
            notes[id] = text
        }
    }

    /// Freezes the visible list without touching the underlying capture —
    /// the Rust engine keeps recording regardless, so unpausing immediately
    /// shows everything that happened in between. Distinct from Stop, which
    /// tears down routing entirely.
    func togglePause() {
        isPaused.toggle()
    }

    /// Writes the current session (as displayed — respects whatever's been
    /// captured so far) to a JSON file the user picks via a save panel. The
    /// panel itself must run on @MainActor (it's UI), but encoding + writing
    /// a potentially large session is real work that doesn't need to be.
    /// Saves the full session — every request field, plus bookmarks/notes —
    /// so `importSession()` can reopen it exactly as it looked when saved.
    func exportSession() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "charlesrs-session.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Strong capture is deliberate: this is a short, bounded one-shot
        // task (not a repeating loop like polling), so there's no
        // meaningful lifetime/leak concern — and a weak self here would
        // just reintroduce the "captured var in concurrent code" hazard
        // Swift 6 mode flags, for no benefit.
        let snapshot = SessionFile(
            requests: requests.map(SessionRequest.init),
            bookmarkedIDs: Array(bookmarkedIDs),
            notes: notes
        )
        Task.detached(priority: .utility) {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(snapshot)
                try data.write(to: url)
            } catch {
                let message = "Export failed: \(error.localizedDescription)"
                await MainActor.run { self.errorMessage = message }
            }
        }
    }

    /// Loads a session saved by `exportSession()` and shows it in the
    /// traffic list, restoring bookmarks/notes alongside it. Implicitly
    /// pauses (if running) so the live poll loop doesn't overwrite the
    /// loaded requests on its next tick.
    func importSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let session = try JSONDecoder().decode(SessionFile.self, from: data)
            requests = session.requests.map { $0.toDisplay() }
            bookmarkedIDs = Set(session.bookmarkedIDs)
            notes = session.notes
            if isRunning, !isPaused {
                togglePause()
            }
            status = "Viewing saved session (\(session.requests.count) requests)"
        } catch {
            errorMessage = "Couldn't open session: \(error.localizedDescription)"
        }
    }

    /// Creates a new disabled rule with a starter script and returns its id
    /// so the caller can select it immediately.
    @discardableResult
    func addMockRule() -> String {
        let rule = MockRuleDisplay(
            id: UUID().uuidString,
            displayName: "New Rule",
            method: nil,
            urlContains: "",
            enabled: false,
            script: MockRuleDisplay.defaultScript,
            lastError: nil
        )
        mockRules.append(rule)
        persistMockRules()
        return rule.id
    }

    func updateMockRule(_ rule: MockRuleDisplay) {
        guard let index = mockRules.firstIndex(where: { $0.id == rule.id }) else { return }
        mockRules[index] = rule
        persistMockRules()
    }

    func deleteMockRule(id: String) {
        mockRules.removeAll { $0.id == id }
        persistMockRules()
    }

    func toggleMockRule(id: String) {
        guard let index = mockRules.firstIndex(where: { $0.id == id }) else { return }
        mockRules[index].enabled.toggle()
        persistMockRules()
    }

    /// Pushes the full rule set to the Rust engine, which persists it to
    /// disk and (if running) picks it up immediately — no restart needed.
    /// The FFI call includes a disk write on the Rust side, so it's kicked
    /// off the main actor here too.
    private func persistMockRules() {
        let rules = mockRules.map { $0.toFFI() }
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setMockRules(rules: rules)
        }
    }

    /// Creates a new disabled Map Local rule and returns its id so the
    /// caller can select it immediately.
    @discardableResult
    func addMapLocalRule() -> String {
        let rule = MapLocalRuleDisplay(
            id: UUID().uuidString,
            displayName: "New Rule",
            method: nil,
            urlContains: "",
            enabled: false,
            localPath: "",
            contentType: nil,
            lastError: nil
        )
        mapLocalRules.append(rule)
        persistMapLocalRules()
        return rule.id
    }

    func updateMapLocalRule(_ rule: MapLocalRuleDisplay) {
        guard let index = mapLocalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        mapLocalRules[index] = rule
        persistMapLocalRules()
    }

    func deleteMapLocalRule(id: String) {
        mapLocalRules.removeAll { $0.id == id }
        persistMapLocalRules()
    }

    func toggleMapLocalRule(id: String) {
        guard let index = mapLocalRules.firstIndex(where: { $0.id == id }) else { return }
        mapLocalRules[index].enabled.toggle()
        persistMapLocalRules()
    }

    /// Same live-update mechanism as `persistMockRules`.
    private func persistMapLocalRules() {
        let rules = mapLocalRules.map { $0.toFFI() }
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setMapLocalRules(rules: rules)
        }
    }

    /// Creates a new disabled Map Remote rule and returns its id so the
    /// caller can select it immediately.
    @discardableResult
    func addMapRemoteRule() -> String {
        let rule = MapRemoteRuleDisplay(
            id: UUID().uuidString,
            displayName: "New Rule",
            enabled: false,
            matchHost: "",
            matchPathContains: "",
            targetScheme: "http",
            targetHost: "localhost",
            targetPort: nil
        )
        mapRemoteRules.append(rule)
        persistMapRemoteRules()
        return rule.id
    }

    func updateMapRemoteRule(_ rule: MapRemoteRuleDisplay) {
        guard let index = mapRemoteRules.firstIndex(where: { $0.id == rule.id }) else { return }
        mapRemoteRules[index] = rule
        persistMapRemoteRules()
    }

    func deleteMapRemoteRule(id: String) {
        mapRemoteRules.removeAll { $0.id == id }
        persistMapRemoteRules()
    }

    func toggleMapRemoteRule(id: String) {
        guard let index = mapRemoteRules.firstIndex(where: { $0.id == id }) else { return }
        mapRemoteRules[index].enabled.toggle()
        persistMapRemoteRules()
    }

    /// Same live-update mechanism as `persistMockRules`.
    private func persistMapRemoteRules() {
        let rules = mapRemoteRules.map { $0.toFFI() }
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setMapRemoteRules(rules: rules)
        }
    }

    /// Creates a new disabled Rewrite rule with one starter action and
    /// returns its id so the caller can select it immediately.
    @discardableResult
    func addRewriteRule() -> String {
        let rule = RewriteRuleDisplay(
            id: UUID().uuidString,
            displayName: "New Rule",
            enabled: false,
            hostContains: "",
            pathContains: "",
            actions: [RewriteActionDraft()]
        )
        rewriteRules.append(rule)
        persistRewriteRules()
        return rule.id
    }

    func updateRewriteRule(_ rule: RewriteRuleDisplay) {
        guard let index = rewriteRules.firstIndex(where: { $0.id == rule.id }) else { return }
        rewriteRules[index] = rule
        persistRewriteRules()
    }

    func deleteRewriteRule(id: String) {
        rewriteRules.removeAll { $0.id == id }
        persistRewriteRules()
    }

    func toggleRewriteRule(id: String) {
        guard let index = rewriteRules.firstIndex(where: { $0.id == id }) else { return }
        rewriteRules[index].enabled.toggle()
        persistRewriteRules()
    }

    /// Same live-update mechanism as `persistMockRules`.
    private func persistRewriteRules() {
        let rules = rewriteRules.map { $0.toFFI() }
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setRewriteRules(rules: rules)
        }
    }

    /// Creates a new disabled Block rule and returns its id so the caller
    /// can select it immediately.
    @discardableResult
    func addBlockRule() -> String {
        let rule = BlockRuleDisplay(id: UUID().uuidString, displayName: "New Rule", enabled: false, hostContains: "", pathContains: "", statusCode: 403)
        blockRules.append(rule)
        persistBlockRules()
        return rule.id
    }

    func updateBlockRule(_ rule: BlockRuleDisplay) {
        guard let index = blockRules.firstIndex(where: { $0.id == rule.id }) else { return }
        blockRules[index] = rule
        persistBlockRules()
    }

    func deleteBlockRule(id: String) {
        blockRules.removeAll { $0.id == id }
        persistBlockRules()
    }

    func toggleBlockRule(id: String) {
        guard let index = blockRules.firstIndex(where: { $0.id == id }) else { return }
        blockRules[index].enabled.toggle()
        persistBlockRules()
    }

    /// Same live-update mechanism as `persistMockRules`.
    private func persistBlockRules() {
        let rules = blockRules.map { $0.toFFI() }
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setBlockRules(rules: rules)
        }
    }

    /// Creates a new disabled DNS Spoof rule and returns its id so the
    /// caller can select it immediately.
    @discardableResult
    func addDnsSpoofRule() -> String {
        let rule = DnsSpoofRuleDisplay(id: UUID().uuidString, displayName: "New Rule", enabled: false, host: "", spoofIp: "127.0.0.1")
        dnsSpoofRules.append(rule)
        persistDnsSpoofRules()
        return rule.id
    }

    func updateDnsSpoofRule(_ rule: DnsSpoofRuleDisplay) {
        guard let index = dnsSpoofRules.firstIndex(where: { $0.id == rule.id }) else { return }
        dnsSpoofRules[index] = rule
        persistDnsSpoofRules()
    }

    func deleteDnsSpoofRule(id: String) {
        dnsSpoofRules.removeAll { $0.id == id }
        persistDnsSpoofRules()
    }

    func toggleDnsSpoofRule(id: String) {
        guard let index = dnsSpoofRules.firstIndex(where: { $0.id == id }) else { return }
        dnsSpoofRules[index].enabled.toggle()
        persistDnsSpoofRules()
    }

    /// Same live-update mechanism as `persistMockRules`.
    private func persistDnsSpoofRules() {
        let rules = dnsSpoofRules.map { $0.toFFI() }
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setDnsSpoofRules(rules: rules)
        }
    }

    /// Focus narrows what gets *recorded* — traffic that doesn't match
    /// still passes through untouched. Live-applies immediately, same
    /// mechanism as the Network Link Conditioner; not persisted across
    /// launches (same reasoning as throttle: starting fresh is the safer
    /// default so you don't wonder why traffic isn't showing up next time).
    func setFocusEnabled(_ enabled: Bool) {
        focusEnabled = enabled
        persistFocus()
    }

    func addFocusHost(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !focusHosts.contains(trimmed) else { return }
        focusHosts.append(trimmed)
        persistFocus()
    }

    func removeFocusHost(_ host: String) {
        focusHosts.removeAll { $0 == host }
        persistFocus()
    }

    private func persistFocus() {
        let settings = FocusSettings(enabled: focusEnabled, hosts: focusHosts)
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setFocus(settings: settings)
        }
    }

    /// Applies a Network Link Conditioner preset. Takes effect immediately
    /// on the running engine — no restart needed, same live-update
    /// mechanism as mock rules.
    func setThrottlePreset(_ preset: ThrottlePreset) {
        throttlePreset = preset
        let profile = preset.profile
        let controller = self.controller
        Task.detached(priority: .utility) {
            controller.setThrottleProfile(profile: profile)
        }
    }

    /// Switches routing mode, live if the proxy is already running — tears
    /// down whichever mechanism was active (restore system prefs, or
    /// unproxy the selected browsers) before standing up the new one, so
    /// there's no window where both or neither are applied.
    func setRoutingMode(_ mode: RoutingMode) {
        guard mode != routingMode else { return }
        let wasRunning = isRunning

        if wasRunning {
            switch routingMode {
            case .systemWide:
                try? SystemProxyConfig.disable()
            case .selectedApps:
                Task { await self.relaunchSelected(proxied: false) }
            }
        }

        routingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.routingModeKey)

        guard wasRunning else { return }
        switch mode {
        case .systemWide:
            do {
                status = "Routing all system traffic…"
                try SystemProxyConfig.enable(host: "127.0.0.1", port: Int(port))
                status = "Capturing system-wide on 127.0.0.1:\(port)"
            } catch {
                errorMessage = error.localizedDescription
                status = "Running — system-wide routing failed"
            }
        case .selectedApps:
            status = proxiedBundleIDs.isEmpty
                ? "Running — pick an app to proxy"
                : "Relaunching \(proxiedBundleIDs.count) app(s)…"
            Task { await self.relaunchSelected(proxied: true) }
        }
    }

    /// Toggle whether `bundleID` routes through us. If we're currently
    /// running in selected-apps mode, this relaunches that browser
    /// immediately; otherwise it just records the preference for next Start.
    func toggleBrowser(_ bundleID: String) {
        let proxied = !proxiedBundleIDs.contains(bundleID)
        Task { await self.setBrowserProxied(bundleID: bundleID, proxied: proxied) }
    }

    private func setBrowserProxied(bundleID: String, proxied: Bool) async {
        relaunchInFlight.insert(bundleID)
        defer { relaunchInFlight.remove(bundleID) }

        if isRunning, routingMode == .selectedApps {
            do {
                try await BrowserRelauncher.setProxied(proxied, bundleID: bundleID, port: port)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        if proxied {
            proxiedBundleIDs.insert(bundleID)
        } else {
            proxiedBundleIDs.remove(bundleID)
        }
        UserDefaults.standard.set(Array(proxiedBundleIDs), forKey: Self.proxiedBundleIDsKey)
    }

    private func relaunchSelected(proxied: Bool) async {
        var failures: [String] = []
        for bundleID in proxiedBundleIDs {
            relaunchInFlight.insert(bundleID)
            do {
                try await BrowserRelauncher.setProxied(proxied, bundleID: bundleID, port: port)
            } catch {
                let name = ProxiedBrowserCatalog.known.first { $0.bundleID == bundleID }?.displayName ?? bundleID
                failures.append("\(name): \(error.localizedDescription)")
            }
            relaunchInFlight.remove(bundleID)
        }

        guard proxied else { return }
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
            status = "Running — some apps didn't relaunch"
        } else {
            status = proxiedBundleIDs.isEmpty
                ? "Running — pick an app to proxy"
                : "Capturing \(proxiedBundleIDs.count) app(s) on 127.0.0.1:\(port)"
        }
    }

    /// Called on quit. In system-wide mode this restores network settings
    /// even if the UI never got a stop(), because leaving the system proxy
    /// pointed at a dead port breaks all networking on the machine. In
    /// selected-apps mode this is best-effort — the relaunch is async and
    /// termination doesn't wait around for it.
    func shutdownForTermination() {
        pollTask?.cancel()
        controller.stop()
        switch routingMode {
        case .systemWide:
            if SystemProxyConfig.hasPendingRestore {
                try? SystemProxyConfig.disable()
            }
        case .selectedApps:
            let ids = proxiedBundleIDs
            let port = port
            Task.detached {
                for bundleID in ids {
                    try? await BrowserRelauncher.setProxied(false, bundleID: bundleID, port: port)
                }
            }
        }
    }

    /// Identifies the head of the capture log. Records are only appended
    /// once a response has completed, so they never mutate after insertion —
    /// which means an unchanged (count, newest id) pair guarantees there is
    /// nothing new to re-map.
    private var lastSeen: (count: Int, newestID: String?) = (0, nil)

    /// Runs every 400ms while capturing. The Rust FFI call and the mapping
    /// into display structs happen inside `Task.detached`, off @MainActor —
    /// for 500 requests with full headers/bodies that's real work, and
    /// doing it inline here would block the main thread on every tick.
    /// Only our own `Sendable` display types (never the raw UniFFI structs)
    /// cross back over.
    private func startPolling() {
        pollTask?.cancel()
        lastSeen = (0, nil)
        let controller = self.controller

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused {
                    let (mapped, fingerprint, ruleErrors, mapLocalErrors) = await Task.detached(priority: .utility) {
                        () -> ([CapturedRequestDisplay], (Int, String?), [String: String?], [String: String?]) in
                        let recent = controller.recentRequests(limit: 500)
                        let fingerprint = (recent.count, recent.first?.id)
                        let mapped = recent.map(CapturedRequestDisplay.init)
                        let errors = Dictionary(uniqueKeysWithValues: controller.mockRules().map { ($0.id, $0.lastError) })
                        let mapLocalErrors = Dictionary(uniqueKeysWithValues: controller.mapLocalRules().map { ($0.id, $0.lastError) })
                        return (mapped, fingerprint, errors, mapLocalErrors)
                    }.value

                    if fingerprint != self.lastSeen {
                        self.lastSeen = fingerprint
                        self.requests = mapped
                    }
                    for index in self.mockRules.indices {
                        if let error = ruleErrors[self.mockRules[index].id] {
                            self.mockRules[index].lastError = error
                        }
                    }
                    for index in self.mapLocalRules.indices {
                        if let error = mapLocalErrors[self.mapLocalRules[index].id] {
                            self.mapLocalRules[index].lastError = error
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }
}

/// Local display model kept separate from the UniFFI-generated
/// `CapturedRequest` so SwiftUI views don't depend directly on FFI types.
struct CapturedRequestDisplay: Identifiable, Sendable {
    let id: String
    let method: String
    let url: String
    let statusCode: Int?
    let startedAtMs: Int64
    let durationMs: Int64?
    /// Coarse timing breakdown — see `CapturedRequest.waitMs`'s doc comment
    /// on the Rust side for why this is three phases, not a full
    /// DNS/connect/TLS waterfall. `nil` for exchanges that never touched
    /// the network (Map Local, Block).
    let requestSendMs: Int64?
    let waitMs: Int64?
    let responseReceiveMs: Int64?
    let processName: String?
    let processID: UInt32?
    let requestHeaders: [(String, String)]
    let responseHeaders: [(String, String)]
    let requestBodyBase64: String?
    let requestBodyTruncated: Bool
    let responseBodyBase64: String?
    let responseBodyTruncated: Bool
    let bytesSent: UInt64
    let bytesReceived: UInt64
    let interceptedBy: String?

    init(_ captured: CapturedRequest) {
        id = captured.id
        method = captured.method
        url = captured.url
        statusCode = captured.statusCode.map(Int.init)
        startedAtMs = captured.startedAtMs
        durationMs = captured.durationMs
        requestSendMs = captured.requestSendMs
        waitMs = captured.waitMs
        responseReceiveMs = captured.responseReceiveMs
        processName = captured.processName
        processID = captured.processId
        requestHeaders = captured.requestHeaders.map { ($0.name, $0.value) }
        responseHeaders = captured.responseHeaders.map { ($0.name, $0.value) }
        requestBodyBase64 = captured.requestBodyBase64
        requestBodyTruncated = captured.requestBodyTruncated
        responseBodyBase64 = captured.responseBodyBase64
        responseBodyTruncated = captured.responseBodyTruncated
        bytesSent = captured.bytesSent
        bytesReceived = captured.bytesReceived
        interceptedBy = captured.interceptedBy
    }

    /// Direct memberwise construction — used when rebuilding a request from
    /// a saved session file rather than a live FFI `CapturedRequest`.
    init(
        id: String, method: String, url: String, statusCode: Int?, startedAtMs: Int64, durationMs: Int64?,
        requestSendMs: Int64?, waitMs: Int64?, responseReceiveMs: Int64?, processName: String?, processID: UInt32?,
        requestHeaders: [(String, String)], responseHeaders: [(String, String)], requestBodyBase64: String?,
        requestBodyTruncated: Bool, responseBodyBase64: String?, responseBodyTruncated: Bool, bytesSent: UInt64,
        bytesReceived: UInt64, interceptedBy: String?
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.startedAtMs = startedAtMs
        self.durationMs = durationMs
        self.requestSendMs = requestSendMs
        self.waitMs = waitMs
        self.responseReceiveMs = responseReceiveMs
        self.processName = processName
        self.processID = processID
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBodyBase64 = requestBodyBase64
        self.requestBodyTruncated = requestBodyTruncated
        self.responseBodyBase64 = responseBodyBase64
        self.responseBodyTruncated = responseBodyTruncated
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.interceptedBy = interceptedBy
    }
}

/// Flat, Codable projection used only for session export — kept separate
/// from `CapturedRequestDisplay` so that view-layer type doesn't need to
/// carry `Codable` just for this one path.
/// Codable mirror of a header pair — `[(String, String)]` tuples aren't
/// `Codable` themselves, and a `[String: String]` dictionary would silently
/// drop order and duplicate header names (`Set-Cookie` routinely repeats).
private struct SessionHeaderPair: Codable {
    let name: String
    let value: String
}

/// Full round-trip mirror of `CapturedRequestDisplay` — every field, so a
/// saved session reopens exactly as it looked when saved (bodies,
/// intercepted-by badges, timing, all of it). Distinct from the display
/// type only so this file's on-disk shape doesn't silently change if that
/// type's internals ever do.
private struct SessionRequest: Codable {
    let id: String
    let method: String
    let url: String
    let statusCode: Int?
    let startedAtMs: Int64
    let durationMs: Int64?
    let requestSendMs: Int64?
    let waitMs: Int64?
    let responseReceiveMs: Int64?
    let processName: String?
    let processID: UInt32?
    let requestHeaders: [SessionHeaderPair]
    let responseHeaders: [SessionHeaderPair]
    let requestBodyBase64: String?
    let requestBodyTruncated: Bool
    let responseBodyBase64: String?
    let responseBodyTruncated: Bool
    let bytesSent: UInt64
    let bytesReceived: UInt64
    let interceptedBy: String?

    init(_ r: CapturedRequestDisplay) {
        id = r.id
        method = r.method
        url = r.url
        statusCode = r.statusCode
        startedAtMs = r.startedAtMs
        durationMs = r.durationMs
        requestSendMs = r.requestSendMs
        waitMs = r.waitMs
        responseReceiveMs = r.responseReceiveMs
        processName = r.processName
        processID = r.processID
        requestHeaders = r.requestHeaders.map { SessionHeaderPair(name: $0.0, value: $0.1) }
        responseHeaders = r.responseHeaders.map { SessionHeaderPair(name: $0.0, value: $0.1) }
        requestBodyBase64 = r.requestBodyBase64
        requestBodyTruncated = r.requestBodyTruncated
        responseBodyBase64 = r.responseBodyBase64
        responseBodyTruncated = r.responseBodyTruncated
        bytesSent = r.bytesSent
        bytesReceived = r.bytesReceived
        interceptedBy = r.interceptedBy
    }

    func toDisplay() -> CapturedRequestDisplay {
        CapturedRequestDisplay(
            id: id, method: method, url: url, statusCode: statusCode, startedAtMs: startedAtMs,
            durationMs: durationMs, requestSendMs: requestSendMs, waitMs: waitMs,
            responseReceiveMs: responseReceiveMs, processName: processName, processID: processID,
            requestHeaders: requestHeaders.map { ($0.name, $0.value) },
            responseHeaders: responseHeaders.map { ($0.name, $0.value) },
            requestBodyBase64: requestBodyBase64, requestBodyTruncated: requestBodyTruncated,
            responseBodyBase64: responseBodyBase64, responseBodyTruncated: responseBodyTruncated,
            bytesSent: bytesSent, bytesReceived: bytesReceived, interceptedBy: interceptedBy
        )
    }
}

/// On-disk session format — the traffic list plus the client-side
/// annotations (bookmarks/notes) laid on top of it, so reopening a session
/// restores exactly what you left behind.
private struct SessionFile: Codable {
    var formatVersion = 1
    var requests: [SessionRequest]
    var bookmarkedIDs: [String]
    var notes: [String: String]
}

/// Local display/edit model for a `MockRule`, kept separate from the
/// UniFFI-generated type for the same reason as `CapturedRequestDisplay`.
struct MockRuleDisplay: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    /// `nil` matches any method — represented as "" in the UI's method field.
    var method: String?
    var urlContains: String
    var enabled: Bool
    var script: String
    var lastError: String?

    init(id: String, displayName: String, method: String?, urlContains: String, enabled: Bool, script: String, lastError: String?) {
        self.id = id
        self.displayName = displayName
        self.method = method
        self.urlContains = urlContains
        self.enabled = enabled
        self.script = script
        self.lastError = lastError
    }

    init(_ rule: MockRule) {
        id = rule.id
        displayName = rule.displayName
        method = rule.method
        urlContains = rule.urlContains
        enabled = rule.enabled
        script = rule.script
        lastError = rule.lastError
    }

    func toFFI() -> MockRule {
        MockRule(id: id, displayName: displayName, method: method, urlContains: urlContains, enabled: enabled, script: script, lastError: lastError)
    }

    static let defaultScript = """
    function onResponse(req, res) {
        // Mutate res.status / res.headers[...] / res.body, then return it.
        // res.headers is a plain object; res.body is a string.
        var data = JSON.parse(res.body);

        data.mocked = true;

        res.body = JSON.stringify(data);
        res.headers["X-Mocked-By"] = "CharlesRS";
        return res;
    }
    """
}

/// Local display/edit model for a `MapLocalRule`, kept separate from the
/// UniFFI-generated type for the same reason as `CapturedRequestDisplay`.
struct MapLocalRuleDisplay: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    /// `nil` matches any method — represented as "" in the UI's method field.
    var method: String?
    var urlContains: String
    var enabled: Bool
    var localPath: String
    /// `nil` guesses the Content-Type from `localPath`'s extension.
    var contentType: String?
    var lastError: String?

    init(id: String, displayName: String, method: String?, urlContains: String, enabled: Bool, localPath: String, contentType: String?, lastError: String?) {
        self.id = id
        self.displayName = displayName
        self.method = method
        self.urlContains = urlContains
        self.enabled = enabled
        self.localPath = localPath
        self.contentType = contentType
        self.lastError = lastError
    }

    init(_ rule: MapLocalRule) {
        id = rule.id
        displayName = rule.displayName
        method = rule.method
        urlContains = rule.urlContains
        enabled = rule.enabled
        localPath = rule.localPath
        contentType = rule.contentType
        lastError = rule.lastError
    }

    func toFFI() -> MapLocalRule {
        MapLocalRule(id: id, displayName: displayName, method: method, urlContains: urlContains, enabled: enabled, localPath: localPath, contentType: contentType, lastError: lastError)
    }
}

/// Local display/edit model for a `MapRemoteRule`, kept separate from the
/// UniFFI-generated type for the same reason as `CapturedRequestDisplay`.
struct MapRemoteRuleDisplay: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var enabled: Bool
    var matchHost: String
    /// "" matches any path.
    var matchPathContains: String
    /// "http" or "https".
    var targetScheme: String
    var targetHost: String
    /// `nil` uses the scheme's default (80/443).
    var targetPort: UInt16?

    init(id: String, displayName: String, enabled: Bool, matchHost: String, matchPathContains: String, targetScheme: String, targetHost: String, targetPort: UInt16?) {
        self.id = id
        self.displayName = displayName
        self.enabled = enabled
        self.matchHost = matchHost
        self.matchPathContains = matchPathContains
        self.targetScheme = targetScheme
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    init(_ rule: MapRemoteRule) {
        id = rule.id
        displayName = rule.displayName
        enabled = rule.enabled
        matchHost = rule.matchHost
        matchPathContains = rule.matchPathContains
        targetScheme = rule.targetScheme
        targetHost = rule.targetHost
        targetPort = rule.targetPort
    }

    func toFFI() -> MapRemoteRule {
        MapRemoteRule(id: id, displayName: displayName, enabled: enabled, matchHost: matchHost, matchPathContains: matchPathContains, targetScheme: targetScheme, targetHost: targetHost, targetPort: targetPort)
    }
}

/// Which of `RewriteAction`'s eight shapes a `RewriteActionDraft` currently
/// represents — drives which fields the editor shows for it.
enum RewriteActionKind: String, CaseIterable, Identifiable {
    case addRequestHeader = "Add Request Header"
    case removeRequestHeader = "Remove Request Header"
    case replaceRequestHeader = "Replace Request Header"
    case addResponseHeader = "Add Response Header"
    case removeResponseHeader = "Remove Response Header"
    case replaceResponseHeader = "Replace Response Header"
    case replaceStatusCode = "Replace Status Code"
    case replaceResponseBodyText = "Replace Response Body Text"
    var id: String { rawValue }

    /// Whether this variant needs a header/find name field.
    var hasName: Bool {
        self != .replaceStatusCode
    }
    var nameLabel: String {
        self == .replaceResponseBodyText ? "FIND" : "HEADER NAME"
    }
    /// Whether this variant needs a second (value/replacement/status) field.
    var hasValue: Bool { true }
    var valueLabel: String {
        switch self {
        case .replaceStatusCode: return "STATUS CODE"
        case .replaceResponseBodyText: return "REPLACE WITH"
        case .removeRequestHeader, .removeResponseHeader: return ""
        default: return "VALUE"
        }
    }
}

/// Editable draft of one `RewriteAction`. Never crosses the FFI boundary
/// directly — `toFFI()`/`init(_:)` are the only points of contact with the
/// UniFFI-generated enum, so the editor UI (and this type's `Equatable`,
/// which the generated enum doesn't have) stay independent of it.
struct RewriteActionDraft: Identifiable, Equatable {
    let id: UUID
    var kind: RewriteActionKind
    var name: String
    /// Doubles as: header value, body replacement text, or (as a string)
    /// the new status code.
    var value: String

    init(kind: RewriteActionKind = .addRequestHeader, name: String = "", value: String = "") {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.value = value
    }

    init?(_ action: RewriteAction) {
        id = UUID()
        switch action {
        case .addRequestHeader(let name, let value):
            kind = .addRequestHeader; self.name = name; self.value = value
        case .removeRequestHeader(let name):
            kind = .removeRequestHeader; self.name = name; self.value = ""
        case .replaceRequestHeader(let name, let value):
            kind = .replaceRequestHeader; self.name = name; self.value = value
        case .addResponseHeader(let name, let value):
            kind = .addResponseHeader; self.name = name; self.value = value
        case .removeResponseHeader(let name):
            kind = .removeResponseHeader; self.name = name; self.value = ""
        case .replaceResponseHeader(let name, let value):
            kind = .replaceResponseHeader; self.name = name; self.value = value
        case .replaceStatusCode(let status):
            kind = .replaceStatusCode; self.name = ""; self.value = String(status)
        case .replaceResponseBodyText(let find, let replace):
            kind = .replaceResponseBodyText; self.name = find; self.value = replace
        }
    }

    /// `nil` when the draft doesn't have enough to make a valid action yet
    /// (e.g. an empty header name) — callers filter these out rather than
    /// persisting a no-op.
    func toFFI() -> RewriteAction? {
        switch kind {
        case .addRequestHeader:
            return name.isEmpty ? nil : .addRequestHeader(name: name, value: value)
        case .removeRequestHeader:
            return name.isEmpty ? nil : .removeRequestHeader(name: name)
        case .replaceRequestHeader:
            return name.isEmpty ? nil : .replaceRequestHeader(name: name, value: value)
        case .addResponseHeader:
            return name.isEmpty ? nil : .addResponseHeader(name: name, value: value)
        case .removeResponseHeader:
            return name.isEmpty ? nil : .removeResponseHeader(name: name)
        case .replaceResponseHeader:
            return name.isEmpty ? nil : .replaceResponseHeader(name: name, value: value)
        case .replaceStatusCode:
            return UInt16(value).map { .replaceStatusCode(status: $0) }
        case .replaceResponseBodyText:
            return name.isEmpty ? nil : .replaceResponseBodyText(find: name, replace: value)
        }
    }
}

/// Local display/edit model for a `RewriteRule`, kept separate from the
/// UniFFI-generated type for the same reason as `CapturedRequestDisplay`.
struct RewriteRuleDisplay: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var enabled: Bool
    /// "" matches any host.
    var hostContains: String
    /// "" matches any path.
    var pathContains: String
    var actions: [RewriteActionDraft]

    init(id: String, displayName: String, enabled: Bool, hostContains: String, pathContains: String, actions: [RewriteActionDraft]) {
        self.id = id
        self.displayName = displayName
        self.enabled = enabled
        self.hostContains = hostContains
        self.pathContains = pathContains
        self.actions = actions
    }

    init(_ rule: RewriteRule) {
        id = rule.id
        displayName = rule.displayName
        enabled = rule.enabled
        hostContains = rule.hostContains
        pathContains = rule.pathContains
        actions = rule.actions.compactMap(RewriteActionDraft.init)
    }

    func toFFI() -> RewriteRule {
        RewriteRule(id: id, displayName: displayName, enabled: enabled, hostContains: hostContains, pathContains: pathContains, actions: actions.compactMap { $0.toFFI() })
    }
}

/// Local display/edit model for a `BlockRule`, kept separate from the
/// UniFFI-generated type for the same reason as `CapturedRequestDisplay`.
struct BlockRuleDisplay: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var enabled: Bool
    /// "" matches any host.
    var hostContains: String
    /// "" matches any path.
    var pathContains: String
    var statusCode: UInt16

    init(id: String, displayName: String, enabled: Bool, hostContains: String, pathContains: String, statusCode: UInt16) {
        self.id = id
        self.displayName = displayName
        self.enabled = enabled
        self.hostContains = hostContains
        self.pathContains = pathContains
        self.statusCode = statusCode
    }

    init(_ rule: BlockRule) {
        id = rule.id
        displayName = rule.displayName
        enabled = rule.enabled
        hostContains = rule.hostContains
        pathContains = rule.pathContains
        statusCode = rule.statusCode
    }

    func toFFI() -> BlockRule {
        BlockRule(id: id, displayName: displayName, enabled: enabled, hostContains: hostContains, pathContains: pathContains, statusCode: statusCode)
    }
}

/// Local display/edit model for a `DnsSpoofRule`, kept separate from the
/// UniFFI-generated type for the same reason as `CapturedRequestDisplay`.
struct DnsSpoofRuleDisplay: Identifiable, Equatable, Sendable {
    var id: String
    var displayName: String
    var enabled: Bool
    var host: String
    var spoofIp: String

    init(id: String, displayName: String, enabled: Bool, host: String, spoofIp: String) {
        self.id = id
        self.displayName = displayName
        self.enabled = enabled
        self.host = host
        self.spoofIp = spoofIp
    }

    init(_ rule: DnsSpoofRule) {
        id = rule.id
        displayName = rule.displayName
        enabled = rule.enabled
        host = rule.host
        spoofIp = rule.spoofIp
    }

    func toFFI() -> DnsSpoofRule {
        DnsSpoofRule(id: id, displayName: displayName, enabled: enabled, host: host, spoofIp: spoofIp)
    }
}
