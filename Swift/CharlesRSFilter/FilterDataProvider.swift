import Foundation
import NetworkExtension
import os.log

/// Per-process traffic filter. This is what makes "capture only the
/// Simulator, or switch to another app" possible — NEFilterDataProvider
/// gets each new flow *before* it's connected, with the owning process's
/// audit token available via `flow.sourceAppSigningIdentifier` /
/// `flow.sourceAppAuditToken` (macOS 11+), which we resolve to a bundle ID.
///
/// Matched flows are redirected (NEFilterNewFlowVerdict.newFlow +
/// updated remote endpoint, or via the newer proxy-flow rewrite APIs) to
/// 127.0.0.1:<proxyPort>, where rust-core's ProxyEngine is listening.
final class FilterDataProvider: NEFilterDataProvider {
    private let log = Logger(subsystem: "com.sandeep.charlesrs.filter", category: "filter")

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        // TODO: load the currently-enabled bundle ID list from shared
        // UserDefaults (App Group), populated by CharlesRSApp via the
        // filter picker UI.
        completionHandler(nil)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socketFlow = flow as? NEFilterSocketFlow else {
            return .allow()
        }

        let bundleId = resolveBundleId(for: socketFlow)
        log.debug("new flow from \(bundleId ?? "unknown", privacy: .public)")

        guard let bundleId, isCaptureEnabled(for: bundleId) else {
            return .allow()
        }

        // TODO: redirect into the local MITM proxy rather than allowing
        // directly. The exact API depends on which NetworkExtension
        // entitlement level is granted (content filter vs. app proxy);
        // sketch this out once the entitlement/provisioning profile is
        // in hand, since it changes the redirect mechanism.
        return .allow()
    }

    private func resolveBundleId(for flow: NEFilterSocketFlow) -> String? {
        // Use Objective-C runtime lookup to avoid compile-time failures
        // when building against SDKs that don't declare the newer
        // `sourceAppSigningIdentifier` property.
        let sel = NSSelectorFromString("sourceAppSigningIdentifier")
        if flow.responds(to: sel), let unmanaged = flow.perform(sel) {
            return unmanaged.takeUnretainedValue() as? String
        }

        // Fallback: try `sourceAppAuditToken` if present (not converting
        // token to a bundle ID here). Return nil if unavailable.
        let tokenSel = NSSelectorFromString("sourceAppAuditToken")
        if flow.responds(to: tokenSel), let unmanaged = flow.perform(tokenSel) {
            _ = unmanaged.takeUnretainedValue() as? Data
            return nil
        }

        return nil
    }

    private func isCaptureEnabled(for bundleId: String) -> Bool {
        // TODO: read from the App Group shared defaults set by the main app.
        return false
    }
}
