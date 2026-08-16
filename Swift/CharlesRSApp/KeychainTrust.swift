import Foundation
import Security

/// Installs the Rust-generated root CA into the login Keychain and marks it
/// trusted for SSL, which is what makes our MITM leaf certs validate in
/// Safari/curl/URLSession. `SecTrustSettingsSetTrustSettings` triggers the
/// standard macOS password prompt — expected on first run only, since the CA
/// is persisted on the Rust side and reused across launches.
enum KeychainTrust {

    enum TrustError: LocalizedError {
        case malformedPEM
        case addFailed(OSStatus)
        case trustFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .malformedPEM:
                return "The generated root CA could not be parsed as a certificate."
            case .addFailed(let status):
                return "Adding the root CA to the Keychain failed (OSStatus \(status))."
            case .trustFailed(let status):
                // -128 is userCanceledErr: the user dismissed the password prompt.
                if status == -128 {
                    return "Trusting the root CA was cancelled. HTTPS interception will fail until it is trusted."
                }
                return "Marking the root CA as trusted failed (OSStatus \(status))."
            }
        }
    }

    /// Add + trust the CA if it isn't already trusted. Safe to call on every launch.
    @discardableResult
    static func installIfNeeded(pem: String) throws -> Bool {
        guard let certificate = certificate(fromPEM: pem) else {
            throw TrustError.malformedPEM
        }

        if isTrusted(certificate) {
            return false
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        // Already present from a previous run is fine — we only need the
        // trust setting below.
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw TrustError.addFailed(addStatus)
        }

        // Passing nil for the settings means "use the default", i.e.
        // kSecTrustSettingsResultTrustRoot for a self-signed root.
        let trustStatus = SecTrustSettingsSetTrustSettings(certificate, .user, nil)
        guard trustStatus == errSecSuccess else {
            throw TrustError.trustFailed(trustStatus)
        }
        return true
    }

    static func isTrusted(_ certificate: SecCertificate) -> Bool {
        var settings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(certificate, .user, &settings)
        return status == errSecSuccess
    }

    /// True if the CA described by `pem` is already trusted for this user.
    static func isTrusted(pem: String) -> Bool {
        guard let certificate = certificate(fromPEM: pem) else { return false }
        return isTrusted(certificate)
    }

    /// Strip the PEM armour and DER-decode. SecCertificate wants raw DER.
    private static func certificate(fromPEM pem: String) -> SecCertificate? {
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}
