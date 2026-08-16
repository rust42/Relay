import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Toolbox state

enum SimToolboxTab: String, CaseIterable, Identifiable {
    case general = "General"
    case apps = "Apps"
    case privacy = "Privacy"
    case location = "Location"
    case statusBar = "Status Bar"
    case push = "Push"
    case media = "Media"
    var id: String { rawValue }
}

/// Owns every piece of ephemeral input/state for the simulator toolbox tabs
/// (text fields, sliders, the installed-apps list, the in-flight recording
/// process) so `ToolsView` and `SimulatorManagementCard` don't have to carry
/// two dozen `@State` vars for a panel that's mostly idle.
@MainActor
final class SimToolboxModel: ObservableObject {
    // Location
    @Published var latText = "37.7749"
    @Published var lonText = "-122.4194"

    // Status bar
    @Published var statusBarTime = "9:41"
    @Published var batteryLevel: Double = 100
    @Published var batteryState = "charged"
    @Published var cellularBars: Double = 4
    @Published var wifiBars: Double = 3

    // Privacy
    @Published var privacyAction: SimulatorControl.PrivacyAction = .grant
    @Published var privacyService: SimulatorControl.PrivacyService = .location
    @Published var privacyBundleID = ""

    // Push
    @Published var pushBundleID = ""
    @Published var pushPayload = SimToolboxModel.defaultPushPayload

    // Media / clipboard
    @Published var clipboardText = ""

    // Apps
    @Published var apps: [SimulatorControl.SimApp] = []
    @Published var appsLoading = false
    @Published var showSystemApps = false

    // Device creation
    @Published var deviceTypes: [SimulatorControl.SimDeviceType] = []
    @Published var runtimes: [SimulatorControl.SimRuntime] = []

    // Recording
    @Published var isRecording = false
    private var recordingProcess: Process?

    @Published var toast: String?
    @Published var error: String?
    @Published var busy = false

    static let defaultPushPayload = """
    {
      "aps": {
        "alert": {
          "title": "Relay",
          "body": "Test push notification"
        },
        "sound": "default"
      }
    }
    """

    func run(_ action: @escaping () async throws -> Void, toast successMessage: String? = nil) {
        busy = true
        Task {
            do {
                try await action()
                if let successMessage {
                    toast = successMessage
                    try? await Task.sleep(for: .seconds(2))
                    toast = nil
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    func loadApps(udid: String) {
        appsLoading = true
        Task {
            apps = await SimulatorControl.listApps(udid: udid)
            appsLoading = false
        }
    }

    func loadDeviceCreationLists() {
        Task {
            deviceTypes = await SimulatorControl.listDeviceTypes()
            runtimes = await SimulatorControl.listRuntimes()
        }
    }

    func takeScreenshot(udid: String) {
        let path = desktopPath(prefix: "Relay-Screenshot", ext: "png")
        run({
            try await SimulatorControl.screenshot(udid: udid, savePath: path)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }, toast: "Screenshot saved to Desktop")
    }

    func toggleRecording(udid: String) {
        if isRecording {
            if let recordingProcess { SimulatorControl.stopRecording(recordingProcess) }
            recordingProcess = nil
            isRecording = false
            toast = "Recording saved to Desktop"
            Task {
                try? await Task.sleep(for: .seconds(2))
                toast = nil
            }
        } else {
            let path = desktopPath(prefix: "Relay-Recording", ext: "mov")
            recordingProcess = SimulatorControl.startRecording(udid: udid, savePath: path)
            isRecording = true
        }
    }

    func copyMacClipboardToSimulator(udid: String) {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        run({ try await SimulatorControl.setClipboard(text: text, udid: udid) }, toast: "Copied to simulator")
    }

    func copySimulatorClipboardToMac(udid: String) {
        run({
            let text = try await SimulatorControl.getClipboard(udid: udid)
            self.clipboardText = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }, toast: "Copied to Mac")
    }

    private func desktopPath(prefix: String, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return desktop.appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).\(ext)").path
    }
}

// MARK: - Tab bar

struct SimToolboxTabBar: View {
    @Binding var selected: SimToolboxTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(SimToolboxTab.allCases) { tab in
                    Button(tab.rawValue) { selected = tab }
                        .buttonStyle(ToolboxTabButtonStyle(isSelected: selected == tab))
                }
            }
        }
    }
}

private struct ToolboxTabButtonStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.05)))
            }
            .overlay(Capsule().strokeBorder(isSelected ? Color.white.opacity(0.25) : Theme.hairline, lineWidth: 1))
            .foregroundStyle(isSelected ? .white : Theme.textSecondary)
    }
}

// MARK: - Shared bits

private struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

private struct ToolboxTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    var monospaced: Bool = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - General tab (lifecycle + capture)

struct GeneralToolsPanel: View {
    let device: SimDevice
    let actionInFlight: Bool
    let routingMode: RoutingMode
    let caJustInstalled: Bool
    @ObservedObject var toolbox: SimToolboxModel
    let onInstallRootCA: () async -> Void
    let onClearSafariCache: () async -> Void
    let onResetPermissions: () async -> Void
    let onToggleAppearance: (Bool) async -> Void
    @State private var confirmErase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task { await onInstallRootCA() }
            } label: {
                Label(caJustInstalled ? "Certificate Installed" : "Install Root Certificate",
                      systemImage: caJustInstalled ? "checkmark.circle.fill" : "checkmark.seal")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle(prominent: caJustInstalled, tint: Theme.methodColor("POST")))

            if routingMode != .systemWide {
                Label("Simulator traffic needs System-wide routing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            actionButton("Clear Safari Cache", icon: "trash") { await onClearSafariCache() }
            actionButton("Reset All Permissions", icon: "arrow.counterclockwise") { await onResetPermissions() }

            HStack(spacing: 6) {
                Button { Task { await onToggleAppearance(false) } } label: {
                    Label("Light", systemImage: "sun.max.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
                Button { Task { await onToggleAppearance(true) } } label: {
                    Label("Dark", systemImage: "moon.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
            }

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            FieldLabel(text: "Lifecycle")
            HStack(spacing: 6) {
                Button { toolbox.run({ try await SimulatorControl.boot(udid: device.udid) }) } label: {
                    Label("Boot", systemImage: "power").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(device.isBooted)
                Button { toolbox.run({ try await SimulatorControl.shutdown(udid: device.udid) }) } label: {
                    Label("Shutdown", systemImage: "power.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(!device.isBooted)
            }

            Button {
                confirmErase = true
            } label: {
                Label("Erase Content & Settings…", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle(tint: Theme.statusColor(500)))
            .confirmationDialog("Erase \"\(device.name)\"?", isPresented: $confirmErase) {
                Button("Erase Content & Settings", role: .destructive) {
                    toolbox.run({ try await SimulatorControl.erase(udid: device.udid) }, toast: "Erased")
                }
            } message: {
                Text("This wipes the simulator back to factory state — all installed apps and data are removed. This can't be undone.")
            }

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            FieldLabel(text: "Capture")
            actionButton("Take Screenshot", icon: "camera.fill") {
                toolbox.takeScreenshot(udid: device.udid)
            }
            Button {
                toolbox.toggleRecording(udid: device.udid)
            } label: {
                Label(toolbox.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: toolbox.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle(prominent: toolbox.isRecording, tint: Theme.statusColor(500)))
        }
        .disabled(actionInFlight || !device.isBooted)
        .opacity(device.isBooted ? 1 : 0.5)
    }

    private func actionButton(_ title: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(GlassButtonStyle())
    }
}

// MARK: - Apps tab

struct AppsToolsPanel: View {
    let device: SimDevice
    @ObservedObject var toolbox: SimToolboxModel

    private var visibleApps: [SimulatorControl.SimApp] {
        toolbox.showSystemApps ? toolbox.apps : toolbox.apps.filter { !$0.isSystem }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    installApp()
                } label: {
                    Label("Install App…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle())
                Button {
                    toolbox.loadApps(udid: device.udid)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(GlassIconButtonStyle())
            }

            Toggle("Show system apps", isOn: $toolbox.showSystemApps)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textSecondary)

            if toolbox.appsLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if visibleApps.isEmpty {
                Text("No apps found.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(visibleApps) { app in
                            AppRow(app: app, toolbox: toolbox, udid: device.udid)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 320)
            }
        }
        .disabled(!device.isBooted)
        .opacity(device.isBooted ? 1 : 0.5)
        .task { if toolbox.apps.isEmpty { toolbox.loadApps(udid: device.udid) } }
    }

    private func installApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        toolbox.run({
            try await SimulatorControl.installApp(path: url.path, udid: device.udid)
            self.toolbox.loadApps(udid: device.udid)
        }, toast: "Installed")
    }
}

private struct AppRow: View {
    let app: SimulatorControl.SimApp
    @ObservedObject var toolbox: SimToolboxModel
    let udid: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(app.bundleID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: 4) {
                miniButton("Launch", icon: "play.fill") {
                    toolbox.run({ try await SimulatorControl.launchApp(bundleID: app.bundleID, udid: udid) })
                }
                miniButton("Stop", icon: "stop.fill") {
                    toolbox.run({ try await SimulatorControl.terminateApp(bundleID: app.bundleID, udid: udid) })
                }
                miniButton("Container", icon: "folder") {
                    toolbox.run({
                        let path = try await SimulatorControl.appContainerPath(bundleID: app.bundleID, kind: .data, udid: udid)
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    })
                }
                if !app.isSystem {
                    miniButton("Uninstall", icon: "trash", destructive: true) {
                        toolbox.run({
                            try await SimulatorControl.uninstallApp(bundleID: app.bundleID, udid: udid)
                            self.toolbox.loadApps(udid: udid)
                        })
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.05) : Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
    }

    private func miniButton(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 9, weight: .semibold))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.06), in: Capsule())
        .foregroundStyle(destructive ? Theme.statusColor(500) : Theme.textSecondary)
    }
}

// MARK: - Privacy tab

struct PrivacyToolsPanel: View {
    let device: SimDevice
    @ObservedObject var toolbox: SimToolboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Service")
            Picker("", selection: $toolbox.privacyService) {
                ForEach(SimulatorControl.PrivacyService.allCases) { service in
                    Text(service.label).tag(service)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            FieldLabel(text: "Bundle ID (optional for reset-all)")
            ToolboxTextField(text: $toolbox.privacyBundleID, placeholder: "com.example.app", monospaced: true)

            HStack(spacing: 6) {
                privacyButton(.grant, label: "Grant", tint: Theme.methodColor("POST"))
                privacyButton(.revoke, label: "Revoke", tint: Theme.statusColor(500))
                privacyButton(.reset, label: "Reset", tint: Theme.accent3)
            }

            Text("Grant/Revoke require a bundle ID; Reset without one applies to every installed app.")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .disabled(!device.isBooted)
        .opacity(device.isBooted ? 1 : 0.5)
    }

    private func privacyButton(_ action: SimulatorControl.PrivacyAction, label: String, tint: Color) -> some View {
        Button(label) {
            toolbox.run({
                try await SimulatorControl.setPrivacy(action, service: toolbox.privacyService, bundleID: toolbox.privacyBundleID, udid: device.udid)
            }, toast: "\(label)ed")
        }
        .buttonStyle(GlassButtonStyle(tint: tint))
        .disabled(action != .reset && toolbox.privacyBundleID.isEmpty)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Location tab

struct LocationToolsPanel: View {
    let device: SimDevice
    @ObservedObject var toolbox: SimToolboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Latitude")
                    ToolboxTextField(text: $toolbox.latText, monospaced: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Longitude")
                    ToolboxTextField(text: $toolbox.lonText, monospaced: true)
                }
            }

            FieldLabel(text: "Presets")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                ForEach(SimulatorControl.locationPresets) { preset in
                    Button(preset.name) {
                        toolbox.latText = "\(preset.lat)"
                        toolbox.lonText = "\(preset.lon)"
                    }
                    .buttonStyle(ToolboxTabButtonStyle(isSelected: false))
                }
            }

            HStack(spacing: 6) {
                Button {
                    guard let lat = Double(toolbox.latText), let lon = Double(toolbox.lonText) else { return }
                    toolbox.run({ try await SimulatorControl.setLocation(lat: lat, lon: lon, udid: device.udid) }, toast: "Location set")
                } label: {
                    Label("Set Location", systemImage: "location.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: true, tint: Theme.accent3))
                .disabled(Double(toolbox.latText) == nil || Double(toolbox.lonText) == nil)

                Button {
                    toolbox.run({ try await SimulatorControl.clearLocation(udid: device.udid) }, toast: "Cleared")
                } label: {
                    Image(systemName: "location.slash")
                }
                .buttonStyle(GlassIconButtonStyle())
            }
        }
        .disabled(!device.isBooted)
        .opacity(device.isBooted ? 1 : 0.5)
    }
}

// MARK: - Status bar tab

struct StatusBarToolsPanel: View {
    let device: SimDevice
    @ObservedObject var toolbox: SimToolboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Time")
            ToolboxTextField(text: $toolbox.statusBarTime, placeholder: "9:41", monospaced: true)

            FieldLabel(text: "Battery Level — \(Int(toolbox.batteryLevel))%")
            Slider(value: $toolbox.batteryLevel, in: 0...100, step: 1)

            Picker("", selection: $toolbox.batteryState) {
                Text("Charging").tag("charging")
                Text("Charged").tag("charged")
                Text("Discharging").tag("discharging")
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            FieldLabel(text: "Cellular Bars — \(Int(toolbox.cellularBars))")
            Slider(value: $toolbox.cellularBars, in: 0...4, step: 1)

            FieldLabel(text: "WiFi Bars — \(Int(toolbox.wifiBars))")
            Slider(value: $toolbox.wifiBars, in: 0...3, step: 1)

            HStack(spacing: 6) {
                Button {
                    toolbox.run({
                        try await SimulatorControl.overrideStatusBar(
                            udid: device.udid,
                            time: toolbox.statusBarTime,
                            batteryLevel: Int(toolbox.batteryLevel),
                            batteryState: toolbox.batteryState,
                            cellularBars: Int(toolbox.cellularBars),
                            wifiBars: Int(toolbox.wifiBars)
                        )
                    }, toast: "Override applied")
                } label: {
                    Label("Apply", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: true, tint: Theme.accent3))

                Button {
                    toolbox.run({ try await SimulatorControl.clearStatusBarOverride(udid: device.udid) }, toast: "Cleared")
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(GlassIconButtonStyle())
            }

            Button {
                toolbox.statusBarTime = "9:41"
                toolbox.batteryLevel = 100
                toolbox.batteryState = "charged"
                toolbox.cellularBars = 4
                toolbox.wifiBars = 3
                toolbox.run({
                    try await SimulatorControl.overrideStatusBar(
                        udid: device.udid, time: "9:41", batteryLevel: 100, batteryState: "charged", cellularBars: 4, wifiBars: 3
                    )
                }, toast: "Clean status bar applied")
            } label: {
                Label("Clean for Screenshot", systemImage: "camera.viewfinder").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle())
        }
        .disabled(!device.isBooted)
        .opacity(device.isBooted ? 1 : 0.5)
    }
}

// MARK: - Push tab

struct PushToolsPanel: View {
    let device: SimDevice
    @ObservedObject var toolbox: SimToolboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Bundle ID")
            ToolboxTextField(text: $toolbox.pushBundleID, placeholder: "com.example.app", monospaced: true)

            FieldLabel(text: "APNs Payload")
            TextEditor(text: $toolbox.pushPayload)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                .frame(height: 160)

            Button {
                toolbox.run({
                    try await SimulatorControl.sendPushNotification(payload: toolbox.pushPayload, bundleID: toolbox.pushBundleID, udid: device.udid)
                }, toast: "Push sent")
            } label: {
                Label("Send Push", systemImage: "bell.badge.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(prominent: true, tint: Theme.accent3))
            .disabled(toolbox.pushBundleID.isEmpty || toolbox.pushPayload.isEmpty)
        }
        .disabled(!device.isBooted)
        .opacity(device.isBooted ? 1 : 0.5)
    }
}

// MARK: - Media tab

struct MediaToolsPanel: View {
    let device: SimDevice
    @ObservedObject var toolbox: SimToolboxModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldLabel(text: "Photo Library")
            Button {
                addMedia()
            } label: {
                Label("Add Photo / Video…", systemImage: "photo.badge.plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle())

            Divider().overlay(Theme.hairline).padding(.vertical, 2)

            FieldLabel(text: "Clipboard Sync")
            Button {
                toolbox.copyMacClipboardToSimulator(udid: device.udid)
            } label: {
                Label("Mac → Simulator", systemImage: "arrow.right.doc.on.clipboard").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle())

            Button {
                toolbox.copySimulatorClipboardToMac(udid: device.udid)
            } label: {
                Label("Simulator → Mac", systemImage: "arrow.left.doc.on.clipboard").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(GlassButtonStyle())

            if !toolbox.clipboardText.isEmpty {
                Text(toolbox.clipboardText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .textSelection(.enabled)
            }
        }
        .disabled(!device.isBooted)
        .opacity(device.isBooted ? 1 : 0.5)
    }

    private func addMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .video]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let paths = panel.urls.map(\.path)
        toolbox.run({ try await SimulatorControl.addMedia(paths: paths, udid: device.udid) }, toast: "Added to library")
    }
}

// MARK: - Create device sheet

struct CreateDeviceSheet: View {
    @ObservedObject var toolbox: SimToolboxModel
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var name = ""
    @State private var deviceTypeID: String?
    @State private var runtimeID: String?
    @State private var creating = false
    @State private var errorMessage: String?

    private var compatibleRuntimes: [SimulatorControl.SimRuntime] {
        guard let deviceTypeID, let family = deviceTypeID.components(separatedBy: ".SimDeviceType.").last else { return toolbox.runtimes }
        let platformHint = family.hasPrefix("Watch") ? "watchOS" : family.hasPrefix("Apple-TV") ? "tvOS" : family.hasPrefix("iPad") ? "iOS" : nil
        guard let platformHint else { return toolbox.runtimes }
        return toolbox.runtimes.filter { $0.platform == platformHint }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Simulator")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Name")
                ToolboxTextField(text: $name, placeholder: "My iPhone")
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Device Type")
                Picker("", selection: $deviceTypeID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(toolbox.deviceTypes) { type in
                        Text(type.name).tag(String?.some(type.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                FieldLabel(text: "Runtime")
                Picker("", selection: $runtimeID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(compatibleRuntimes) { runtime in
                        Text(runtime.name).tag(String?.some(runtime.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.statusColor(500))
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                Spacer()
                Button {
                    create()
                } label: {
                    if creating { ProgressView().controlSize(.small) } else { Text("Create") }
                }
                .buttonStyle(GlassButtonStyle(prominent: true, tint: Theme.methodColor("POST")))
                .disabled(name.isEmpty || deviceTypeID == nil || runtimeID == nil || creating)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Theme.bg)
        .task { toolbox.loadDeviceCreationLists() }
    }

    private func create() {
        guard let deviceTypeID, let runtimeID else { return }
        creating = true
        Task {
            do {
                let udid = try await SimulatorControl.createDevice(name: name, deviceTypeID: deviceTypeID, runtimeID: runtimeID)
                creating = false
                onCreated(udid)
                dismiss()
            } catch {
                creating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
