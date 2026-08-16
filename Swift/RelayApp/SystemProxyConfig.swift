import Foundation
import SystemConfiguration

/// Points the Mac's system-wide HTTP/HTTPS proxy settings at our local
/// engine, and puts them back afterwards.
///
/// Mutating network preferences needs admin rights, so we drive
/// `SCPreferences` through an `AuthorizationRef`; macOS shows one password
/// prompt when the change is committed.
///
/// The original per-service proxy dictionaries are backed up to UserDefaults
/// before we touch them, so a machine that already had a proxy configured
/// gets its exact settings back rather than just being switched off.
/// Only ever called from the @MainActor `ProxyModel`; isolating the whole
/// namespace here (rather than just `cachedAuth`) is what satisfies Swift's
/// strict-concurrency checker for the static `AuthorizationRef` cache below.
@MainActor
enum SystemProxyConfig {

    private static let backupKey = "Relay.proxyBackup"

    enum ProxyError: LocalizedError {
        case authorizationFailed(OSStatus)
        case preferencesUnavailable
        case noNetworkServices
        case commitFailed
        case applyFailed

        var errorDescription: String? {
            switch self {
            case .authorizationFailed(let status):
                if status == errAuthorizationCanceled {
                    return "Administrator approval is required to change the system proxy."
                }
                return "Could not obtain authorization to change network settings (status \(status))."
            case .preferencesUnavailable:
                return "Could not open the system network preferences."
            case .noNetworkServices:
                return "No network services were found to configure."
            case .commitFailed:
                let err = String(cString: SCErrorString(SCError()))
                return "Saving the proxy settings failed: \(err)"
            case .applyFailed:
                let err = String(cString: SCErrorString(SCError()))
                return "Applying the proxy settings failed: \(err)"
            }
        }
    }

    /// Route HTTP and HTTPS through `host:port` on every network service.
    static func enable(host: String, port: Int) throws {
        try withAuthorizedPreferences { prefs, services in
            var backup: [String: [String: Any]] = [:]

            for serviceID in services {
                let path = proxiesPath(for: serviceID)
                var proxies = (SCPreferencesPathGetValue(prefs, path) as? [String: Any]) ?? [:]
                backup[serviceID] = proxies

                proxies[kSCPropNetProxiesHTTPEnable as String] = 1
                proxies[kSCPropNetProxiesHTTPProxy as String] = host
                proxies[kSCPropNetProxiesHTTPPort as String] = port
                proxies[kSCPropNetProxiesHTTPSEnable as String] = 1
                proxies[kSCPropNetProxiesHTTPSProxy as String] = host
                proxies[kSCPropNetProxiesHTTPSPort as String] = port

                SCPreferencesPathSetValue(prefs, path, proxies as CFDictionary)
            }

            // Only overwrite the backup if we don't already hold one, so a
            // double-start can't record our own settings as "the original".
            if UserDefaults.standard.dictionary(forKey: backupKey) == nil {
                UserDefaults.standard.set(backup, forKey: backupKey)
            }
        }
    }

    /// Restore whatever was configured before `enable` ran. If no backup
    /// exists (e.g. the app was force-quit mid-run) fall back to simply
    /// disabling the HTTP/HTTPS proxies.
    static func disable() throws {
        let backup = UserDefaults.standard.dictionary(forKey: backupKey) as? [String: [String: Any]]

        try withAuthorizedPreferences { prefs, services in
            for serviceID in services {
                let path = proxiesPath(for: serviceID)

                if let original = backup?[serviceID] {
                    SCPreferencesPathSetValue(prefs, path, original as CFDictionary)
                } else {
                    var proxies = (SCPreferencesPathGetValue(prefs, path) as? [String: Any]) ?? [:]
                    proxies[kSCPropNetProxiesHTTPEnable as String] = 0
                    proxies[kSCPropNetProxiesHTTPSEnable as String] = 0
                    SCPreferencesPathSetValue(prefs, path, proxies as CFDictionary)
                }
            }
        }

        UserDefaults.standard.removeObject(forKey: backupKey)
    }

    /// True if we currently have settings backed up, i.e. we believe we've
    /// modified the system proxy and still owe the user a restore.
    static var hasPendingRestore: Bool {
        UserDefaults.standard.dictionary(forKey: backupKey) != nil
    }

    // MARK: - Plumbing

    private static func proxiesPath(for serviceID: String) -> CFString {
        "/\(kSCPrefNetworkServices as String)/\(serviceID)/\(kSCEntNetProxies as String)" as CFString
    }

    /// Held for the process lifetime and reused by both `enable` and
    /// `disable`, so the user is prompted once per launch rather than again
    /// on stop/quit — which matters because the restore on quit would
    /// otherwise raise a modal prompt during termination.
    private static var cachedAuth: AuthorizationRef?

    private static func authorization() throws -> AuthorizationRef {
        if let cachedAuth { return cachedAuth }
        var authRef: AuthorizationRef?
        // An empty rights set is intentional: SCPreferences requests the
        // specific system.preferences right itself at commit time, which is
        // what surfaces the password prompt.
        let status = AuthorizationCreate(nil, nil, [], &authRef)
        guard status == errAuthorizationSuccess, let authRef else {
            throw ProxyError.authorizationFailed(status)
        }
        cachedAuth = authRef
        return authRef
    }

    private static func withAuthorizedPreferences(
        _ body: (SCPreferences, [String]) throws -> Void
    ) throws {
        let authRef = try authorization()

        guard let prefs = SCPreferencesCreateWithAuthorization(
            nil, "Relay" as CFString, nil, authRef
        ) else {
            throw ProxyError.preferencesUnavailable
        }

        guard let services = SCPreferencesGetValue(prefs, kSCPrefNetworkServices) as? [String: Any],
              !services.isEmpty else {
            throw ProxyError.noNetworkServices
        }

        try body(prefs, Array(services.keys))

        guard SCPreferencesCommitChanges(prefs) else { throw ProxyError.commitFailed }
        guard SCPreferencesApplyChanges(prefs) else { throw ProxyError.applyFailed }
    }
}
