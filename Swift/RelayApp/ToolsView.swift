import SwiftUI

struct ToolsView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @StateObject private var logStreamer = SimulatorLogStreamer()
    @StateObject private var toolbox = SimToolboxModel()
    @State private var devices: [SimDevice] = []
    @State private var selectedDeviceID: String?
    @State private var deepLinkURL = ""
    @State private var levelFilter: SimLogLevel?
    @State private var actionInFlight = false
    @State private var toolsError: String?
    @State private var caJustInstalled = false
    @State private var toolboxTab: SimToolboxTab = .general
    @State private var showCreateDevice = false

    private var selectedDevice: SimDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    private var filteredLines: [SimLogLine] {
        guard let levelFilter else { return logStreamer.lines }
        return logStreamer.lines.filter { $0.level == levelFilter }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    NetworkConditionerCard()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    DeepLinkTesterCard(
                        urlString: $deepLinkURL,
                        canTrigger: selectedDevice != nil,
                        onTrigger: triggerDeepLink
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 190)

                DeviceConsoleCard(
                    device: selectedDevice,
                    lines: filteredLines,
                    isStreaming: logStreamer.isStreaming,
                    levelFilter: $levelFilter
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            SimulatorManagementCard(
                devices: devices,
                selectedDeviceID: $selectedDeviceID,
                actionInFlight: actionInFlight,
                routingMode: proxyModel.routingMode,
                caJustInstalled: caJustInstalled,
                toolbox: toolbox,
                tab: $toolboxTab,
                showCreateDevice: $showCreateDevice,
                onInstallRootCA: {
                    await runAction { udid in
                        try await SimulatorControl.installRootCA(pemPath: proxyModel.rootCAPath, on: udid)
                    }
                    guard toolsError == nil else { return }
                    caJustInstalled = true
                    try? await Task.sleep(for: .seconds(2))
                    caJustInstalled = false
                },
                onClearSafariCache: { await runAction { try await SimulatorControl.clearSafariCache(on: $0) } },
                onResetPermissions: { await runAction { try await SimulatorControl.resetPrivacy(on: $0) } },
                onToggleAppearance: { dark in await runAction { try await SimulatorControl.setAppearance(dark: dark, on: $0) } },
                onRefreshDevices: { devices = await SimulatorControl.listDevices() }
            )
            .frame(width: 320)
            .frame(maxHeight: .infinity)
        }
        .task {
            devices = await SimulatorControl.listDevices()
            if selectedDeviceID == nil {
                selectedDeviceID = devices.first(where: \.isBooted)?.id ?? devices.first?.id
            }
        }
        .onChange(of: selectedDeviceID) { _, newValue in
            guard let newValue else { logStreamer.stop(); return }
            logStreamer.start(udid: newValue)
            toolbox.apps = []
        }
        .onDisappear { logStreamer.stop() }
        .sheet(isPresented: $showCreateDevice) {
            CreateDeviceSheet(toolbox: toolbox) { newUDID in
                Task {
                    devices = await SimulatorControl.listDevices()
                    selectedDeviceID = newUDID
                }
            }
        }
        .alert("Relay", isPresented: Binding(
            get: { toolsError != nil },
            set: { if !$0 { toolsError = nil } }
        )) {
            Button("OK", role: .cancel) { toolsError = nil }
        } message: {
            Text(toolsError ?? "")
        }
        .alert("Relay", isPresented: Binding(
            get: { toolbox.error != nil },
            set: { if !$0 { toolbox.error = nil } }
        )) {
            Button("OK", role: .cancel) { toolbox.error = nil }
        } message: {
            Text(toolbox.error ?? "")
        }
        .overlay(alignment: .bottom) {
            if let toast = toolbox.toast {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.85), in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toolbox.toast)
    }

    private func triggerDeepLink() {
        guard let udid = selectedDevice?.udid else { return }
        Task {
            do {
                try await SimulatorControl.openURL(deepLinkURL, on: udid)
            } catch {
                toolsError = error.localizedDescription
            }
        }
    }

    private func runAction(_ action: @escaping (String) async throws -> Void) async {
        guard let udid = selectedDevice?.udid else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            try await action(udid)
        } catch {
            toolsError = error.localizedDescription
        }
    }
}

// MARK: - Network Link Conditioner

struct NetworkConditionerCard: View {
    @EnvironmentObject var proxyModel: ProxyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent3)
                Text("NETWORK LINK CONDITIONER")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if proxyModel.throttlePreset != .off {
                    Chip(text: "ACTIVE", color: Theme.statusColor(400))
                }
            }

            HStack(spacing: 6) {
                ForEach(ThrottlePreset.allCases) { preset in
                    Button(preset.rawValue) {
                        proxyModel.setThrottlePreset(preset)
                    }
                    .buttonStyle(PresetButtonStyle(isSelected: proxyModel.throttlePreset == preset))
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 20) {
                bandwidthStat(label: "IN BANDWIDTH", kbps: proxyModel.throttlePreset.profile.downKbps)
                bandwidthStat(label: "OUT BANDWIDTH", kbps: proxyModel.throttlePreset.profile.upKbps)
                if proxyModel.throttlePreset.profile.latencyMs > 0 {
                    bandwidthStat(label: "LATENCY", text: "\(proxyModel.throttlePreset.profile.latencyMs) ms")
                }
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 10)
    }

    private func bandwidthStat(label: String, kbps: UInt32) -> some View {
        bandwidthStat(label: label, text: kbps == 0 ? "Unlimited" : "\(kbps) Kbps")
    }

    private func bandwidthStat(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct PresetButtonStyle: ButtonStyle {
    let isSelected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.05)))
            }
            .overlay(Capsule().strokeBorder(isSelected ? Color.white.opacity(0.25) : Theme.hairline, lineWidth: 1))
            .foregroundStyle(isSelected ? .white : Theme.textSecondary)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Deep & Universal Link Tester

struct DeepLinkTesterCard: View {
    @Binding var urlString: String
    let canTrigger: Bool
    let onTrigger: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent3)
                Text("DEEP LINK TESTER")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
            }

            Text("TARGET URL / SCHEME")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Theme.textTertiary)

            TextField("myapp://path or https://example.com/...", text: $urlString)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))

            Spacer(minLength: 0)

            Button {
                onTrigger()
            } label: {
                Label("Trigger", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle(prominent: true, tint: Theme.accent3))
            .disabled(!canTrigger || urlString.isEmpty)
            .opacity((!canTrigger || urlString.isEmpty) ? 0.5 : 1)
        }
        .padding(14)
        .glassPanel(cornerRadius: 10)
    }
}

// MARK: - iOS Device Console

struct DeviceConsoleCard: View {
    let device: SimDevice?
    let lines: [SimLogLine]
    let isStreaming: Bool
    @Binding var levelFilter: SimLogLevel?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PulseDot(color: Theme.methodColor("POST"), active: isStreaming)
                Text("iOS DEVICE CONSOLE")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                if let device {
                    Text("· \(device.name) (\(device.runtime))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                levelButton(nil, label: "All")
                levelButton(.error, label: "Error")
                levelButton(.warn, label: "Warn")
                levelButton(.info, label: "Info")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Theme.hairline)

            if lines.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textTertiary)
                    Text(device == nil ? "No simulator selected" : "Waiting for log output…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in
                                LogLineRow(line: line).id(line.id)
                            }
                        }
                        .padding(10)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: lines.last?.id) { _, newValue in
                        guard let newValue else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }

    private func levelButton(_ level: SimLogLevel?, label: String) -> some View {
        Button {
            levelFilter = level
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background {
                    Capsule().fill(levelFilter == level ? AnyShapeStyle(Theme.accentGradient.opacity(0.3)) : AnyShapeStyle(Color.clear))
                }
                .foregroundStyle(levelFilter == level ? Theme.textPrimary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

private struct LogLineRow: View {
    let line: SimLogLine

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.timestamp)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 130, alignment: .leading)
            Text(line.level.rawValue)
                .foregroundStyle(levelColor)
                .frame(width: 44, alignment: .leading)
            Text(line.process)
                .foregroundStyle(Theme.accent3)
                .frame(width: 130, alignment: .leading)
                .lineLimit(1)
            Text(line.message)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch line.level {
        case .error: return Theme.statusColor(500)
        case .warn: return Theme.statusColor(400)
        case .info: return Theme.accent3
        case .debug: return Theme.textTertiary
        }
    }
}

// MARK: - Simulator Management

struct SimulatorManagementCard: View {
    let devices: [SimDevice]
    @Binding var selectedDeviceID: String?
    let actionInFlight: Bool
    let routingMode: RoutingMode
    let caJustInstalled: Bool
    @ObservedObject var toolbox: SimToolboxModel
    @Binding var tab: SimToolboxTab
    @Binding var showCreateDevice: Bool
    let onInstallRootCA: () async -> Void
    let onClearSafariCache: () async -> Void
    let onResetPermissions: () async -> Void
    let onToggleAppearance: (Bool) async -> Void
    let onRefreshDevices: () async -> Void

    private var selectedDevice: SimDevice? { devices.first { $0.id == selectedDeviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SIMULATOR MANAGEMENT")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)

            if let device = selectedDevice {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ACTIVE TARGET")
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textTertiary)
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.accentGradient)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("\(device.runtime) · \(device.isBooted ? "Booted" : "Shutdown")")
                                .font(.system(size: 10.5))
                                .foregroundStyle(device.isBooted ? Theme.methodColor("POST") : Theme.textTertiary)
                        }
                    }
                    Text(device.udid)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                SimToolboxTabBar(selected: $tab)

                ScrollView {
                    Group {
                        switch tab {
                        case .general:
                            GeneralToolsPanel(
                                device: device, actionInFlight: actionInFlight, routingMode: routingMode,
                                caJustInstalled: caJustInstalled, toolbox: toolbox,
                                onInstallRootCA: onInstallRootCA, onClearSafariCache: onClearSafariCache,
                                onResetPermissions: onResetPermissions, onToggleAppearance: onToggleAppearance
                            )
                        case .apps:
                            AppsToolsPanel(device: device, toolbox: toolbox)
                        case .privacy:
                            PrivacyToolsPanel(device: device, toolbox: toolbox)
                        case .location:
                            LocationToolsPanel(device: device, toolbox: toolbox)
                        case .statusBar:
                            StatusBarToolsPanel(device: device, toolbox: toolbox)
                        case .push:
                            PushToolsPanel(device: device, toolbox: toolbox)
                        case .media:
                            MediaToolsPanel(device: device, toolbox: toolbox)
                        }
                    }
                    .disabled(actionInFlight || toolbox.busy)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)

                if !device.isBooted {
                    Label("Boot this simulator to run actions on it.", systemImage: "info.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Divider().overlay(Theme.hairline)

            HStack {
                Text("AVAILABLE DEVICES")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button { showCreateDevice = true } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(GlassIconButtonStyle())
            }

            if devices.isEmpty {
                Text("No simulators found.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(devices) { device in
                            DeviceRow(device: device, isSelected: device.id == selectedDeviceID) {
                                selectedDeviceID = device.id
                            }
                            .contextMenu {
                                Button(device.isBooted ? "Shutdown" : "Boot") {
                                    Task {
                                        try? await (device.isBooted ? SimulatorControl.shutdown(udid: device.udid) : SimulatorControl.boot(udid: device.udid))
                                        await onRefreshDevices()
                                    }
                                }
                                Button("Clone…") {
                                    Task {
                                        try? await SimulatorControl.cloneDevice(udid: device.udid, newName: "\(device.name) copy")
                                        await onRefreshDevices()
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    Task {
                                        try? await SimulatorControl.deleteDevice(udid: device.udid)
                                        if selectedDeviceID == device.id { selectedDeviceID = nil }
                                        await onRefreshDevices()
                                    }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 150)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct DeviceRow: View {
    let device: SimDevice
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(device.isBooted ? Theme.methodColor("POST") : Theme.textTertiary)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(device.runtime)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
