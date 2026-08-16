//! Root CA generation + on-the-fly leaf certificate signing.
//!
//! Same trick Charles/Proxyman use: generate one root CA, have the user
//! trust it once in Keychain, then mint a short-lived leaf cert per
//! intercepted hostname signed by that CA so the OS/browser sees a valid
//! chain.
//!
//! Implementation note: we keep the CA cert/key as PEM strings and
//! reconstruct an `Issuer` from them on each leaf-signing call (cheap,
//! and leaf certs are cached per-hostname so this only runs once per new
//! host). This sidesteps `Issuer<'a, S>`'s borrow lifetime rather than
//! trying to store a borrowed Issuer alongside its own source data.

use parking_lot::Mutex;
use rcgen::{CertificateParams, DistinguishedName, DnType, Issuer, KeyPair};
use std::collections::HashMap;
use std::sync::Arc;
use time::{Duration, OffsetDateTime};

#[derive(Debug, Clone, uniffi::Record)]
pub struct GeneratedCa {
    /// PEM-encoded certificate, to be installed into the login Keychain
    /// and trusted for SSL via SecTrustSettingsSetTrustSettings.
    pub cert_pem: String,
    /// PEM-encoded private key. Kept in Keychain, never written to disk
    /// unencrypted in the real app.
    pub key_pem: String,
}

pub struct CertAuthority {
    ca_cert_pem: String,
    ca_key_pem: String,
    leaf_cache: Mutex<HashMap<String, (String, String)>>,
}

impl CertAuthority {
    /// Generate a brand-new root CA. Call once, persist the PEMs (e.g. into
    /// Keychain), and reload with `from_pem` on subsequent launches.
    pub fn generate() -> anyhow::Result<Self> {
        let mut params = CertificateParams::new(Vec::<String>::new())?;
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, "Relay Root CA");
        dn.push(DnType::OrganizationName, "Relay (local dev)");
        params.distinguished_name = dn;
        params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        params.key_usages = vec![
            rcgen::KeyUsagePurpose::KeyCertSign,
            rcgen::KeyUsagePurpose::CrlSign,
        ];
        let not_before = OffsetDateTime::now_utc() - Duration::days(1);
        params.not_before = not_before;
        params.not_after = not_before + Duration::days(3650);

        let key_pair = KeyPair::generate()?;
        let cert = params.self_signed(&key_pair)?;

        Ok(Self {
            ca_cert_pem: cert.pem(),
            ca_key_pem: key_pair.serialize_pem(),
            leaf_cache: Mutex::new(HashMap::new()),
        })
    }

    /// Load the CA from `dir`, generating and persisting a new one on first
    /// run. Persistence matters: the user trusts this cert once in Keychain,
    /// so regenerating it per launch would break every launch after the first.
    pub fn load_or_generate(dir: &std::path::Path) -> anyhow::Result<Self> {
        let cert_path = dir.join("relay-ca.pem");
        let key_path = dir.join("relay-ca.key.pem");

        if cert_path.exists() && key_path.exists() {
            let cert_pem = std::fs::read_to_string(&cert_path)?;
            let key_pem = std::fs::read_to_string(&key_path)?;
            // Reject an unusable pair rather than failing later at handshake
            // time, where the error surfaces as an opaque TLS failure.
            if KeyPair::from_pem(&key_pem)
                .and_then(|k| Issuer::from_ca_cert_pem(&cert_pem, k))
                .is_ok()
            {
                return Ok(Self::from_pem(cert_pem, key_pem));
            }
        }

        let ca = Self::generate()?;
        std::fs::create_dir_all(dir)?;
        std::fs::write(&cert_path, &ca.ca_cert_pem)?;
        std::fs::write(&key_path, &ca.ca_key_pem)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o600))?;
        }
        Ok(ca)
    }

    /// Reload a previously-generated CA (e.g. pulled back out of Keychain).
    pub fn from_pem(cert_pem: String, key_pem: String) -> Self {
        Self {
            ca_cert_pem: cert_pem,
            ca_key_pem: key_pem,
            leaf_cache: Mutex::new(HashMap::new()),
        }
    }

    pub fn exported(&self) -> GeneratedCa {
        GeneratedCa {
            cert_pem: self.ca_cert_pem.clone(),
            key_pem: self.ca_key_pem.clone(),
        }
    }

    /// Mint (or fetch cached) a leaf certificate for `hostname`, signed by
    /// this CA. Returns (cert_pem, key_pem) ready to hand to rustls.
    pub fn leaf_for_host(&self, hostname: &str) -> anyhow::Result<(String, String)> {
        if let Some(existing) = self.leaf_cache.lock().get(hostname) {
            return Ok(existing.clone());
        }

        let ca_key = KeyPair::from_pem(&self.ca_key_pem)?;
        let issuer = Issuer::from_ca_cert_pem(&self.ca_cert_pem, ca_key)?;

        // `CertificateParams::new` parses each string as a SAN entry,
        // correctly handling both DNS names and IP literals.
        let mut params = CertificateParams::new(vec![hostname.to_string()])?;
        let mut dn = DistinguishedName::new();
        dn.push(DnType::CommonName, hostname);
        params.distinguished_name = dn;

        // Required since macOS 10.15 / iOS 13: Apple's local trust evaluation
        // rejects TLS server certs that lack the serverAuth EKU outright, even
        // when the issuing CA is trusted. Without this every MITM'd host
        // fails the handshake identically (TLS alert 46/certificate_unknown),
        // which is indistinguishable from "CA not trusted" unless you know to
        // look for it — see https://support.apple.com/en-us/103769.
        params.key_usages = vec![
            rcgen::KeyUsagePurpose::DigitalSignature,
            rcgen::KeyUsagePurpose::KeyEncipherment,
        ];
        params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];

        let not_before = OffsetDateTime::now_utc() - Duration::days(1);
        params.not_before = not_before;
        params.not_after = not_before + Duration::days(397); // Apple's max leaf lifetime

        let leaf_key = KeyPair::generate()?;
        let leaf_cert = params.signed_by(&leaf_key, &issuer)?;

        let pair = (leaf_cert.pem(), leaf_key.serialize_pem());
        self.leaf_cache
            .lock()
            .insert(hostname.to_string(), pair.clone());
        Ok(pair)
    }
}

pub type SharedCertAuthority = Arc<CertAuthority>;
