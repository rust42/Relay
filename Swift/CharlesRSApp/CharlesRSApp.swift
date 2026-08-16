import SwiftUI
import AppKit

@main
struct CharlesRSApp: App {
    // Owns the single Rust-side controller for the app's lifetime.
    // `CharlesController` comes from the UniFFI-generated bindings
    // (rust-core/generated/swift), built by scripts/build-rust.sh.
    @StateObject private var proxyModel = ProxyModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(proxyModel)
                .frame(minWidth: 1040, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear { AppDelegate.model = proxyModel }
        }
        // Keeps the traffic lights but drops the native title bar chrome, so
        // our own glass toolbar can run edge-to-edge under it — the same
        // pattern GitKraken/Arc/Raycast use for a "custom app" feel.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}

/// Exists purely to restore the system proxy on quit. Without this, quitting
/// while capturing would leave every app on the Mac pointed at a dead
/// 127.0.0.1:8899 and break networking machine-wide.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: ProxyModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.model?.shutdownForTermination()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
