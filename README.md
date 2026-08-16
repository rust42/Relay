# CharlesRS

A Charles-Proxy-style MITM traffic inspector for macOS, built as:

- **Rust core** (`rust-core/`) — MITM proxy engine (hyper/tokio), TLS cert
  generation (rcgen), request/response model. Exposed to Swift via UniFFI.
- **SwiftUI app** (`Swift/CharlesRSApp/`) — request list/inspector, capture
  controls, root-CA trust, system-proxy switching.
- **NetworkExtension filter** (`Swift/CharlesRSFilter/`) — parked, see below.

## Status

v1 (system-wide capture) is implemented and working.

| Component | Status |
|---|---|
| `rust-core/src/cert.rs` | Working. Root CA is generated once and **persisted** to `~/Library/Application Support/CharlesRS/`, so the cert you trust keeps working across launches. Leaf certs minted and cached per hostname. |
| `rust-core/src/proxy.rs` | Working. Full CONNECT → TLS-MITM → inner HTTP server → upstream forward, both directions buffered and captured. Verified against real HTTPS endpoints. |
| `rust-core/src/lib.rs` | Working. `start()` binds synchronously and returns a real error on port conflict; `stop()` shuts the accept loop down via a watch channel. |
| `Swift/CharlesRSApp/` | Working. Live request list + inspector (headers/body tabs), wired to the Rust controller. |
| `KeychainTrust.swift` | Installs + trusts the root CA (`SecTrustSettingsSetTrustSettings`). Prompts for your password on first run only. |
| `SystemProxyConfig.swift` | Points the system HTTP/HTTPS proxy at `127.0.0.1:8899` via `SCPreferences` + Authorization Services, backing up and restoring your original settings. |
| `Swift/CharlesRSFilter/` | **Not built.** Parked pending an Apple entitlement — see below. |

### Verifying without touching system settings

`examples/smoke.rs` runs the engine standalone, so you can confirm the MITM
works before pointing your whole Mac at it:

```sh
cd rust-core
cargo run --release --example smoke -- /tmp/charlesrs-smoke 8899
# in another shell:
curl -x http://127.0.0.1:8899 --cacert /tmp/charlesrs-smoke/charlesrs-ca.pem https://example.com
```

The smoke runner prints one line per captured request.

## Build

Local development uses **Tuist** to generate the Xcode project; CI uses **Bazel**
for hermetic, cacheable builds. Both read the same sources — there's no
XcodeGen/project.yml anymore.

### Local (Tuist + Xcode)

1. `brew install tuist` (once)
2. `tuist generate --no-open`
3. `xcodebuild -workspace CharlesRS.xcworkspace -scheme CharlesRS -configuration Debug build`
   (or open `CharlesRS.xcworkspace` in Xcode and hit Run)
   (`scripts/build-rust.sh` runs automatically as a pre-build step: cross-compiles
   arm64 + x86_64, lipos a universal static lib, regenerates the UniFFI bindings)

Manifests: [`Tuist.swift`](Tuist.swift) (project config), [`Project.swift`](Project.swift)
(targets). `CharlesRS.xcodeproj`/`.xcworkspace` are generated artifacts — not
committed, regenerate any time with `tuist generate`.

### CI (Bazel)

1. `brew install bazelisk` (once)
2. `bazel build //Swift/CharlesRSApp:CharlesRS` (add `--macos_cpus=arm64,x86_64 -c opt`
   for a release-shaped universal binary, matching what `.github/workflows/release.yml` does)
3. `unzip -o bazel-bin/Swift/CharlesRSApp/CharlesRS.zip -d /tmp/CharlesRS && open /tmp/CharlesRS/CharlesRS.app`

Bazel builds the Swift app + `.app` bundle hermetically via `rules_apple`/`rules_swift`
(see [`Swift/CharlesRSApp/BUILD.bazel`](Swift/CharlesRSApp/BUILD.bazel)). The Rust
side is not hermetic — it shells out to `cargo` (same cross-compile + lipo + uniffi-bindgen
steps as `scripts/build-rust.sh`) via a `genrule` in [`rust-core/BUILD.bazel`](rust-core/BUILD.bazel),
since fully modeling rust-core's dependency graph (hyper, rustls, boa_engine, etc.) as
Bazel targets would be its own large, brittle undertaking. That genrule needs network
access and the host's rustup toolchain (`HOME`/`PATH`/`CARGO_HOME` are forwarded in
via `.bazelrc`'s `--action_env`).

### CI / CD pipeline

- **`.github/workflows/pr.yml`** — on every PR: `tuist generate` (catches manifest
  drift) and `bazel build //Swift/CharlesRSApp:CharlesRS` (catches everything else).
- **`.github/workflows/release.yml`** — on `v*.*.*` tags (or manual dispatch):
  builds the universal ad-hoc-signed app via Bazel and publishes it as a GitHub
  Release artifact.

The app is **ad-hoc signed** in both paths — no Apple Developer team required for v1.
Because it's ad-hoc (not notarized), Gatekeeper will warn on first launch; the
release notes point people at "right-click > Open" / `xattr -d com.apple.quarantine`.

## Running

Press **Start**. Three things happen, in order:

1. The root CA is added to your login Keychain and marked trusted (password
   prompt, first run only).
2. The proxy binds `127.0.0.1:8899`.
3. Your system HTTP/HTTPS proxy is pointed at it (admin prompt, once per launch).

Press **Stop**, or quit, to restore your original network settings. The quit
path is handled in `AppDelegate.applicationWillTerminate` — without it, quitting
mid-capture would leave the machine pointed at a dead port and break all
networking, so don't remove it.

The authorization is cached for the process lifetime specifically so the
restore-on-quit doesn't need a second prompt.

### Caveats

- **Certificate-pinned apps will fail, by design.** Anything doing pinning
  (many native apps, some Apple services) rejects our leaf cert. That's the
  pinning working correctly, not a bug here.
- Traffic is fully buffered per request/response to populate the inspector, so
  this is not suitable for very large downloads or streaming endpoints.
- HTTP/1.1 only — the inner TLS server advertises only `http/1.1` via ALPN.
  h2 support would mean an h2 server + client path on both sides.

## v2 — per-process capture

Deliberately not built yet, and worth knowing why before you spend time on it:

**`NEFilterDataProvider` cannot redirect flows.** It is allow/drop/inspect only
— there is no "send this flow to my local proxy" verdict, despite what the
original scaffold's comments claimed. Per-app capture requires
**`NETransparentProxyProvider`**, which means:

- the `com.apple.developer.networking.networkextension` entitlement with the
  **`transparent-proxy`** value (Apple approval, request via the Developer Portal),
- a real Developer team + provisioning profile (ad-hoc signing won't do),
- `OSSystemExtensionRequest` activation code in the app (does not exist yet),
- an `NSExtension` / `NSExtensionPointIdentifier` dict in the extension's
  Info.plist (`GENERATE_INFOPLIST_FILE` alone won't produce one).

The extension target is commented out in `Project.swift` — its entitlement can't
be satisfied by ad-hoc signing, so leaving it in fails the whole build. Source
is preserved at `Swift/CharlesRSFilter/` for when the entitlement lands. (It's
also simply absent from the Bazel build for the same reason.)

## Repo layout

```
CharlesRS/
├── Tuist.swift                  # Tuist project config (local dev)
├── Project.swift                # Tuist target manifest (local dev)
├── MODULE.bazel                 # Bazel module deps (CI)
├── .bazelrc / .bazelversion
├── bazel/
│   ├── build_rust_core.sh       # genrule entrypoint: cargo + lipo + uniffi-bindgen
│   └── Info.plist               # supplemental Info.plist for the Bazel build
├── scripts/build-rust.sh        # same steps, wired into the Tuist/Xcode pre-build
├── .github/workflows/
│   ├── pr.yml                   # tuist generate + bazel build, on every PR
│   └── release.yml              # tag push -> universal build -> GitHub Release
├── rust-core/
│   ├── BUILD.bazel
│   ├── src/{lib,cert,proxy,model}.rs
│   └── examples/smoke.rs        # standalone engine check
└── Swift/
    ├── CharlesRSApp/            # main app
    │   ├── BUILD.bazel
    │   ├── ProxyModel.swift         # Rust controller bridge + polling
    │   ├── KeychainTrust.swift      # root CA install/trust
    │   ├── SystemProxyConfig.swift  # SCPreferences proxy switching
    │   └── ContentView.swift        # list + inspector UI
    └── CharlesRSFilter/         # parked (see v2)
```
