import AppKit

/// A Chromium-family browser we know how to point at our proxy via its
/// `--proxy-server` launch flag — the mechanism that makes genuine
/// "only these apps" routing possible without Apple's NetworkExtension
/// entitlement (see README's "v2" section for why arbitrary native apps
/// can't be selectively routed this way; only apps that accept a proxy
/// flag at launch can).
struct ProxiedBrowser: Identifiable, Equatable {
    let bundleID: String
    let displayName: String
    var id: String { bundleID }
}

enum ProxiedBrowserCatalog {
    static let known: [ProxiedBrowser] = [
        .init(bundleID: "com.google.Chrome", displayName: "Google Chrome"),
        .init(bundleID: "com.google.Chrome.canary", displayName: "Google Chrome Canary"),
        .init(bundleID: "com.brave.Browser", displayName: "Brave Browser"),
        .init(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge"),
        .init(bundleID: "company.thebrowser.Browser", displayName: "Arc"),
        .init(bundleID: "com.vivaldi.Vivaldi", displayName: "Vivaldi"),
        .init(bundleID: "org.chromium.Chromium", displayName: "Chromium"),
    ]

    /// Subset actually installed on this Mac, so the picker doesn't list
    /// browsers the user doesn't have.
    static func installed() -> [ProxiedBrowser] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

enum BrowserRelaunchError: LocalizedError {
    case notInstalled
    case quitTimedOut
    case launchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "That browser isn't installed."
        case .quitTimedOut:
            return "It didn't quit in time — it's likely waiting on a \"close all tabs?\" prompt. Answer that prompt (or quit it yourself), then try again."
        case .launchFailed(let error):
            return "Relaunch failed: \(error.localizedDescription)"
        }
    }
}

/// Quits (if running) and relaunches a Chromium-based browser with or
/// without `--proxy-server` pointed at our local engine. These browsers
/// only read the flag at process start — there's no live-reconfigure API —
/// so toggling proxied state always means a full relaunch, and the browser
/// will show its usual "restore tabs?" prompt.
enum BrowserRelauncher {
    @MainActor
    static func setProxied(_ proxied: Bool, bundleID: String, port: UInt16) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw BrowserRelaunchError.notInstalled
        }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !running.isEmpty {
            for app in running { app.terminate() }
            // Let the quit (including any "save changes?"/"close all tabs?"
            // prompt the browser itself shows) settle before launching a
            // fresh instance with new flags — launching too early just
            // attaches to the still-dying old process.
            for _ in 0..<50 {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            // If it's still alive, something (almost always a confirmation
            // dialog) blocked the quit. Proceeding anyway would just
            // reactivate the still-running, still-unproxied instance and
            // report success — worse than surfacing the real state.
            guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                throw BrowserRelaunchError.quitTimedOut
            }
        }

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = proxied ? ["--proxy-server=127.0.0.1:\(port)"] : []
        config.createsNewApplicationInstance = true

        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } catch {
            throw BrowserRelaunchError.launchFailed(error)
        }
    }
}
