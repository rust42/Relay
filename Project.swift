import ProjectDescription

// Ad-hoc signing so the app builds and runs locally without an Apple
// Developer team. Keychain trust and Authorization Services both work
// under ad-hoc; only the NetworkExtension path (see RelayFilter below)
// needs a real team.
let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": "5.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "CODE_SIGN_IDENTITY": "-",
    "CODE_SIGN_STYLE": "Manual",
]

let appSettings: SettingsDictionary = baseSettings.merging([
    "INFOPLIST_KEY_LSApplicationCategoryType": "public.app-category.developer-tools",
    "INFOPLIST_KEY_NSHumanReadableCopyright": "",
    // Lets `import relay_coreFFI` inside the generated bindings resolve
    // against module.modulemap in that directory.
    "HEADER_SEARCH_PATHS": "$(SRCROOT)/rust-core/generated/swift",
    "SWIFT_INCLUDE_PATHS": "$(SRCROOT)/rust-core/generated/swift",
    "FRAMEWORK_SEARCH_PATHS": "$(SRCROOT)/rust-core/target/universal $(inherited)",
    "LIBRARY_SEARCH_PATHS": "$(SRCROOT)/rust-core/target/universal $(inherited)",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
]) { _, new in new }

let project = Project(
    name: "Relay",
    organizationName: "com.sandeep.relay",
    targets: [
        .target(
            name: "Relay",
            destinations: .macOS,
            product: .app,
            bundleId: "com.sandeep.relay.app",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: [
                "Swift/RelayApp/**",
                "rust-core/generated/swift/**",
            ],
            resources: [
                "Swift/RelayApp/Assets.xcassets",
            ],
            entitlements: .file(path: "Swift/RelayApp/Relay.entitlements"),
            scripts: [
                .pre(
                    path: "scripts/build-rust.sh",
                    arguments: [],
                    name: "Build Rust core + generate Swift bindings",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .library(
                    path: "rust-core/target/universal/librelay_core.a",
                    publicHeaders: "rust-core/generated/swift",
                    swiftModuleMap: "rust-core/generated/swift/module.modulemap"
                ),
                .sdk(name: "SystemConfiguration", type: .framework, status: .required),
                .sdk(name: "Security", type: .framework, status: .required),
                .sdk(name: "c++", type: .library, status: .required),
            ],
            settings: .settings(base: appSettings)
        ),

        // The per-process NetworkExtension filter is parked until the transparent-proxy
        // entitlement is in hand. It is intentionally NOT built: its
        // `com.apple.developer.networking.networkextension` entitlement cannot be
        // satisfied by ad-hoc signing, which would fail the whole build. Source is
        // kept at Swift/RelayFilter/ for the v2 per-app capture work.
        //
        // .target(
        //     name: "RelayFilter",
        //     destinations: .macOS,
        //     product: .appExtension,
        //     bundleId: "com.sandeep.relay.app.filter",
        //     deploymentTargets: .macOS("14.0"),
        //     infoPlist: .default,
        //     sources: ["Swift/RelayFilter/**"],
        //     entitlements: .file(path: "Swift/RelayFilter/RelayFilter.entitlements"),
        //     settings: .settings(base: baseSettings)
        // ),
    ]
)
