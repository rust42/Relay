import SwiftUI
import AppKit

enum StatusClass: String, CaseIterable, Identifiable {
    case all = "All"
    case s2 = "2xx"
    case s3 = "3xx"
    case s4 = "4xx"
    case s5 = "5xx"
    var id: String { rawValue }

    func matches(_ status: Int?) -> Bool {
        guard self != .all else { return true }
        guard let status else { return false }
        switch self {
        case .all: return true
        case .s2: return (200..<300).contains(status)
        case .s3: return (300..<400).contains(status)
        case .s4: return (400..<500).contains(status)
        case .s5: return (500..<600).contains(status)
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case traffic = "Traffic"
    case localMocks = "Local Mocks"
    case mapLocal = "Map Local"
    case mapRemote = "Map Remote"
    case rewrite = "Rewrite"
    case blockList = "Block List"
    case dnsSpoofing = "DNS Spoofing"
    case focus = "Focus"
    case tools = "Tools"
    case scripting = "Scripting"
    case analytics = "Analytics"
    var id: String { rawValue }

    /// Everything except Scripting/Analytics has landed. Traffic and the
    /// six rule engines (formerly grouped under one "Mocks" item) are flat,
    /// first-class sidebar entries now — each one click away.
    var isAvailable: Bool { self != .scripting && self != .analytics }

    var icon: String {
        switch self {
        case .traffic: return "chart.bar.doc.horizontal"
        case .localMocks: return "point.3.connected.trianglepath.dotted"
        case .mapLocal: return "doc.badge.arrow.up"
        case .mapRemote: return "arrow.triangle.swap"
        case .rewrite: return "pencil.line"
        case .blockList: return "nosign"
        case .dnsSpoofing: return "globe.badge.chevron.backward"
        case .focus: return "scope"
        case .tools: return "wrench.and.screwdriver"
        case .scripting: return "chevron.left.forwardslash.chevron.right"
        case .analytics: return "chart.xyaxis.line"
        }
    }

    var comingSoonDescription: String {
        switch self {
        case .scripting: return "A visual node canvas — chain filters, header injection, and body modifiers into a rule pipeline that runs against live traffic, no code required."
        case .analytics: return "Historical latency, error rate, and throughput trends once requests are persisted across sessions rather than just the current capture."
        default: return ""
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var selectedSection: AppSection = .traffic
    @State private var selectedRequestID: String?
    @State private var filterText = ""
    @State private var statusClass: StatusClass = .all
    @State private var methodFilter: Set<String> = []
    @State private var sortColumn: SortColumn?
    @State private var sortAscending = true
    @State private var groupByApp = false
    @FocusState private var searchFocused: Bool

    private var visibleRequests: [CapturedRequestDisplay] {
        proxyModel.requests.filter { req in
            let matchesText = filterText.isEmpty
                || req.url.localizedCaseInsensitiveContains(filterText)
                || req.method.localizedCaseInsensitiveContains(filterText)
            let matchesStatus = statusClass.matches(req.statusCode)
            let matchesMethod = methodFilter.isEmpty || methodFilter.contains(req.method.uppercased())
            return matchesText && matchesStatus && matchesMethod
        }
    }

    private var selectedRequest: CapturedRequestDisplay? {
        selectedRequestID.flatMap { id in proxyModel.requests.first { $0.id == id } }
    }

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 12) {
                TopBar(
                    filterText: $filterText,
                    searchFocused: $searchFocused,
                    statusClass: $statusClass,
                    methodFilter: $methodFilter,
                    selectedRequest: selectedRequest
                )

                HStack(spacing: 12) {
                    SidebarNav(selectedSection: $selectedSection)

                    Group {
                        switch selectedSection {
                        case .traffic:
                            trafficContent
                        case .localMocks:
                            LocalMocksView()
                        case .mapLocal:
                            MapLocalToolView()
                        case .mapRemote:
                            MapRemoteToolView()
                        case .rewrite:
                            RewriteToolView()
                        case .blockList:
                            BlockListToolView()
                        case .dnsSpoofing:
                            DnsSpoofingToolView()
                        case .focus:
                            FocusToolView()
                        case .tools:
                            ToolsView()
                        default:
                            ComingSoonView(section: selectedSection)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(14)
        }
        .toolbar(.hidden, for: .windowToolbar)
        .alert("CharlesRS", isPresented: Binding(
            get: { proxyModel.errorMessage != nil },
            set: { if !$0 { proxyModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { proxyModel.errorMessage = nil }
        } message: {
            Text(proxyModel.errorMessage ?? "")
        }
    }

    private var trafficContent: some View {
        VStack(spacing: 12) {
            ThroughputBar(requests: proxyModel.requests)

            HStack(spacing: 12) {
                RequestListPanel(
                    requests: visibleRequests,
                    selectedRequestID: $selectedRequestID,
                    sortColumn: $sortColumn,
                    sortAscending: $sortAscending,
                    groupByApp: $groupByApp
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Group {
                    if let request = selectedRequest {
                        InspectorPanel(request: request)
                            .id(request.id)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .trailing)).animation(.spring(response: 0.35, dampingFraction: 0.85)),
                                removal: .opacity.animation(.easeOut(duration: 0.12))
                            ))
                    } else {
                        EmptyInspector(isRunning: proxyModel.isRunning)
                    }
                }
                .frame(width: 440)
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Sidebar nav

struct SidebarNav: View {
    @Binding var selectedSection: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("CharlesRS")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Traffic Inspector")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.bottom, 16)

            ForEach(AppSection.allCases) { section in
                NavRow(section: section, isSelected: selectedSection == section) {
                    guard section.isAvailable else { return }
                    selectedSection = section
                }
            }

            Spacer(minLength: 0)
            Divider().overlay(Theme.hairline)
            Spacer().frame(height: 6)

            HStack(spacing: 10) {
                Image(systemName: "gearshape").font(.system(size: 13))
                Text("Settings").font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .padding(14)
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

struct NavRow: View {
    let section: AppSection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13.5))
                    .frame(width: 16)
                Text(section.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !section.isAvailable {
                    Text("SOON")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.16) : (hovering ? Color.white.opacity(0.05) : Color.clear))
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Theme.textPrimary : (section.isAvailable ? Theme.textSecondary : Theme.textTertiary))
        .onHover { hovering = section.isAvailable && $0 }
    }
}

struct ComingSoonView: View {
    let section: AppSection

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: section.icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text(section.rawValue)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Chip(text: "COMING SOON", color: Theme.accent3)
                }
                Text(section.comingSoonDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var filterText: String
    var searchFocused: FocusState<Bool>.Binding
    @Binding var statusClass: StatusClass
    @Binding var methodFilter: Set<String>
    let selectedRequest: CapturedRequestDisplay?

    @State private var showRouting = false
    @State private var showFilters = false
    @State private var curlCopied = false
    @State private var showCompose = false

    var body: some View {
        HStack(spacing: 10) {
            // Traffic-light gutter — hidden-title-bar windows still reserve
            // this space for the native red/yellow/green controls.
            Color.clear.frame(width: 62, height: 1)

            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.accentGradient)
                Text("CharlesRS")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }

            Divider().frame(height: 16).overlay(Theme.hairlineBright)

            Button {
                proxyModel.isRunning ? proxyModel.stop() : proxyModel.start()
            } label: {
                Text(proxyModel.isRunning ? "Stop" : "Record")
            }
            .buttonStyle(PlainTextButtonStyle(tint: proxyModel.isRunning ? Color(red: 1.0, green: 0.42, blue: 0.5) : Theme.textPrimary))

            Button {
                proxyModel.togglePause()
            } label: {
                Text(proxyModel.isPaused ? "Resume" : "Pause")
            }
            .buttonStyle(PlainTextButtonStyle(tint: proxyModel.isRunning ? Theme.textPrimary : Theme.textTertiary))
            .disabled(!proxyModel.isRunning)
            .help(proxyModel.isPaused ? "Resume updating the list" : "Freeze the list (capture keeps running)")

            Button {
                proxyModel.clear()
            } label: {
                Text("Clear")
            }
            .buttonStyle(PlainTextButtonStyle(tint: proxyModel.requests.isEmpty ? Theme.textTertiary : Theme.textPrimary))
            .disabled(proxyModel.requests.isEmpty)

            Spacer()

            HStack(spacing: 7) {
                PulseDot(color: proxyModel.isRunning ? Color(red: 1.0, green: 0.42, blue: 0.5) : Theme.textTertiary, active: proxyModel.isRunning && !proxyModel.isPaused)
                Text(proxyModel.isPaused ? "Paused" : proxyModel.status)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(Theme.textTertiary)
                Text("\(proxyModel.requests.count)")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("requests")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .frame(maxWidth: 320)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                TextField("Filter traffic…", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .focused(searchFocused)
                if !filterText.isEmpty {
                    Button { filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: 200)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairlineBright, lineWidth: 1))

            Button {
                showFilters = true
            } label: {
                Image(systemName: (statusClass != .all || !methodFilter.isEmpty) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(GlassIconButtonStyle())
            .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                FilterPanel(statusClass: $statusClass, methodFilter: $methodFilter)
            }

            Button {
                guard let selectedRequest else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CurlExporter.command(for: selectedRequest), forType: .string)
                curlCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { curlCopied = false }
            } label: {
                Image(systemName: curlCopied ? "checkmark" : "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(GlassIconButtonStyle())
            .disabled(selectedRequest == nil)
            .opacity(selectedRequest == nil ? 0.4 : 1)
            .help("Copy as cURL")

            Button {
                proxyModel.exportSession()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(GlassIconButtonStyle())
            .disabled(proxyModel.requests.isEmpty)
            .opacity(proxyModel.requests.isEmpty ? 0.4 : 1)
            .help("Save session")

            Button {
                proxyModel.importSession()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Open a saved session")

            Button {
                showCompose = true
            } label: {
                Image(systemName: "plus.forwardslash.minus")
            }
            .buttonStyle(GlassIconButtonStyle())
            .help("Compose a new request")
            .sheet(isPresented: $showCompose) {
                ComposeView(draft: ComposeDraft())
            }

            Button {
                showRouting = true
            } label: {
                Label(proxyModel.routingMode == .selectedApps
                      ? "\(proxyModel.proxiedBundleIDs.count) App\(proxyModel.proxiedBundleIDs.count == 1 ? "" : "s")"
                      : "System-wide",
                      systemImage: proxyModel.routingMode == .selectedApps ? "app.badge.checkmark" : "globe")
            }
            .buttonStyle(GlassButtonStyle())
            .popover(isPresented: $showRouting, arrowEdge: .bottom) {
                RoutingPanel()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 52)
        .glassPanel(cornerRadius: 10)
    }
}

// MARK: - Filter panel

struct FilterPanel: View {
    @Binding var statusClass: StatusClass
    @Binding var methodFilter: Set<String>
    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("STATUS").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            Picker("", selection: $statusClass) {
                ForEach(StatusClass.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("METHOD").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(methods, id: \.self) { method in
                    Toggle(method, isOn: Binding(
                        get: { methodFilter.contains(method) },
                        set: { on in
                            if on { methodFilter.insert(method) } else { methodFilter.remove(method) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, design: .monospaced))
                }
            }

            if statusClass != .all || !methodFilter.isEmpty {
                Button("Clear filters") {
                    statusClass = .all
                    methodFilter.removeAll()
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}

// MARK: - Throughput

struct ThroughputBar: View {
    let requests: [CapturedRequestDisplay]
    private let windowSeconds = 24

    private var buckets: [Double] {
        let nowMs = Date().timeIntervalSince1970 * 1000
        var buckets = [Double](repeating: 0, count: windowSeconds)
        for r in requests {
            let endMs = Double(r.startedAtMs) + Double(r.durationMs ?? 0)
            let ageSeconds = (nowMs - endMs) / 1000
            guard ageSeconds >= 0, ageSeconds < Double(windowSeconds) else { continue }
            let index = windowSeconds - 1 - Int(ageSeconds)
            guard buckets.indices.contains(index) else { continue }
            buckets[index] += Double(r.bytesSent + r.bytesReceived)
        }
        return buckets
    }

    private var currentRate: String {
        let recent = buckets.suffix(3).reduce(0, +) / 3
        return ByteCountFormatter.string(fromByteCount: Int64(recent), countStyle: .binary) + "/s"
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("LIVE THROUGHPUT")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)

            sparkline

            Spacer()

            Text(currentRate)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 10)
    }

    private var sparkline: some View {
        let maxVal = max(buckets.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.accent3.opacity(value > 0 ? 0.9 : 0.18))
                    .frame(width: 4, height: max(2, CGFloat(value / maxVal) * 24))
            }
        }
        .frame(height: 24)
    }
}

// MARK: - Routing panel (selected-apps vs system-wide)

struct RoutingPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ROUTING")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)

            Picker("", selection: Binding(
                get: { proxyModel.routingMode },
                set: { proxyModel.setRoutingMode($0) }
            )) {
                Text("Selected Apps").tag(RoutingMode.selectedApps)
                Text("System-wide").tag(RoutingMode.systemWide)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if proxyModel.isRunning {
                Text("Switches live — no need to stop first.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
            }

            if proxyModel.routingMode == .systemWide {
                Label("Routes every app on this Mac. Anything with certificate pinning will simply fail — that's expected.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else {
                Divider()

                Text("PROXIED BROWSERS")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)

                if proxyModel.availableBrowsers.isEmpty {
                    Text("No supported browsers found on this Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(proxyModel.availableBrowsers) { browser in
                            HStack {
                                Text(browser.displayName)
                                    .font(.system(size: 12))
                                Spacer()
                                if proxyModel.relaunchInFlight.contains(browser.bundleID) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Toggle("", isOn: Binding(
                                        get: { proxyModel.proxiedBundleIDs.contains(browser.bundleID) },
                                        set: { _ in proxyModel.toggleBrowser(browser.bundleID) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Text("Toggling quits and relaunches that browser — it'll offer to restore your tabs. Everything else on your Mac is untouched.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Request list

struct RequestListPanel: View {
    let requests: [CapturedRequestDisplay]
    @Binding var selectedRequestID: String?
    @Binding var sortColumn: SortColumn?
    @Binding var sortAscending: Bool
    @Binding var groupByApp: Bool

    private var sortedRequests: [CapturedRequestDisplay] {
        requests.sorted(by: sortColumn, ascending: sortAscending)
    }

    private var groups: [AppTrafficGroup] {
        AppGrouping.grouped(sortedRequests)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("TRAFFIC")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { groupByApp.toggle() }
                } label: {
                    Image(systemName: groupByApp ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help(groupByApp ? "Ungroup traffic" : "Group traffic by application")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if !requests.isEmpty {
                columnHeader
                Divider().overlay(Theme.hairline).padding(.horizontal, 8)
            }

            if requests.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No requests yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if groupByApp {
                            ForEach(groups) { group in
                                AppGroupHeader(group: group)
                                ForEach(group.requests) { req in requestRow(req) }
                            }
                        } else {
                            ForEach(sortedRequests) { req in requestRow(req) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }

    private func requestRow(_ req: CapturedRequestDisplay) -> some View {
        RequestRow(request: req, isSelected: selectedRequestID == req.id)
            .onTapGesture {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    selectedRequestID = req.id
                }
            }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            sortButton("STATUS", .status, width: 54)
            sortButton("METHOD", .method, width: 54)
            sortButton("HOST", .host, width: 140)
            sortButton("PATH", .path, maxWidth: true)
            sortButton("TYPE", .type, width: 44)
            sortButton("TIME", .time, width: 56, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold))
        .tracking(0.5)
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func sortButton(
        _ title: String, _ column: SortColumn, width: CGFloat? = nil, maxWidth: Bool = false, alignment: Alignment = .leading
    ) -> some View {
        let button = Button {
            if sortColumn == column {
                sortAscending.toggle()
            } else {
                sortColumn = column
                sortAscending = true
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .heavy))
                }
            }
            .foregroundStyle(sortColumn == column ? Theme.textSecondary : Theme.textTertiary)
        }
        .buttonStyle(.plain)

        return Group {
            if maxWidth {
                button.frame(maxWidth: .infinity, alignment: alignment)
            } else {
                button.frame(width: width, alignment: alignment)
            }
        }
    }
}

/// Section header shown above each app's requests when grouping is on —
/// real app icon when we could resolve one (GUI apps still running or that
/// were running when captured), a generic glyph otherwise (CLI tools,
/// processes that have since quit).
private struct AppGroupHeader: View {
    let group: AppTrafficGroup

    var body: some View {
        HStack(spacing: 8) {
            if let icon = group.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: "square.dashed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 15, height: 15)
            }
            Text(group.displayName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            Text("\(group.requests.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

struct RequestRow: View {
    let request: CapturedRequestDisplay
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let hp = request.hostAndPath
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(request.statusCode.map(Theme.statusColor) ?? Theme.textTertiary)
                    .frame(width: 6, height: 6)
                if let status = request.statusCode {
                    Text("\(status)").foregroundStyle(Theme.statusColor(status))
                } else {
                    Text("···").foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 54, alignment: .leading)

            Chip(text: request.method, color: Theme.methodColor(request.method))
                .frame(width: 54, alignment: .leading)

            Text(hp.host)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 140, alignment: .leading)

            HStack(spacing: 4) {
                if let rule = request.interceptedBy {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.accent2)
                        .help("Modified — \(rule)")
                }
                Text(hp.path)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ContentTypeLabel.short(for: request.responseHeaders))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .leading)

            Text(request.durationMs.map { "\($0)ms" } ?? "—")
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Compact icon+text label used in the inspector header's stat line —
/// smaller and tighter than the system default `.titleAndIcon` spacing.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5))
            configuration.title
        }
    }
}
extension LabelStyle where Self == CompactLabelStyle {
    static var compact: CompactLabelStyle { CompactLabelStyle() }
}

// MARK: - Empty inspector

struct EmptyInspector: View {
    let isRunning: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: "network")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 4) {
                Text(isRunning ? "Waiting for traffic" : "Not capturing")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text(isRunning
                     ? "Browse in a proxied app and requests will appear on the left."
                     : "Press Record, then pick which apps to proxy.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

// MARK: - Inspector

/// DevTools-style detail view: Headers / Preview / Response / Cookies.
/// "Preview" is the rendered/pretty form (JSON tree, image, formatted XML);
/// "Response" is the exact raw text. Headers shows both sides together
/// rather than splitting Request/Response into separate tabs.
struct InspectorPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let request: CapturedRequestDisplay
    @State private var tab = DetailTab.preview
    @State private var showCompose = false
    @State private var showComparePicker = false
    @State private var diffTarget: CapturedRequestDisplay?
    @State private var noteText: String = ""

    enum DetailTab: String, CaseIterable, Identifiable {
        case headers = "Headers"
        case preview = "Preview"
        case response = "Response"
        case cookies = "Cookies"
        case timing = "Timing"
        var id: String { rawValue }
    }

    private var cookies: [ParsedCookie] {
        CookieParser.parse(requestHeaders: request.requestHeaders, responseHeaders: request.responseHeaders)
    }

    private var isBookmarked: Bool { proxyModel.bookmarkedIDs.contains(request.id) }

    private var otherRequests: [CapturedRequestDisplay] {
        proxyModel.requests.filter { $0.id != request.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            HStack(spacing: 6) {
                ForEach(DetailTab.allCases) { tabButton($0) }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                content
                    .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .headers:
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel("Response Headers")
                HeaderTable(headers: request.responseHeaders)
                sectionLabel("Request Headers")
                HeaderTable(headers: request.requestHeaders)
            }
        case .preview:
            BodyView(
                base64: request.responseBodyBase64,
                truncated: request.responseBodyTruncated,
                contentType: BodyKindDetector.contentType(from: request.responseHeaders)
            )
        case .response:
            RawBodyView(base64: request.responseBodyBase64)
        case .cookies:
            if cookies.isEmpty {
                Text("No cookies").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            } else {
                CookieTable(cookies: cookies)
            }
        case .timing:
            TimingBreakdownView(request: request)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
    }

    private func tabButton(_ t: DetailTab) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { tab = t }
        } label: {
            Text(t.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tab == t ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(tab == t ? AnyShapeStyle(Theme.accentGradient.opacity(0.3)) : AnyShapeStyle(Color.white.opacity(0.04)))
                }
                .overlay(Capsule().strokeBorder(tab == t ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Chip(text: request.method, color: Theme.methodColor(request.method), filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.url)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    HStack(spacing: 4) {
                        if let status = request.statusCode {
                            Text("\(status)")
                                .foregroundStyle(Theme.statusColor(status))
                        }
                        if let process = request.processName {
                            Text("· \(process)")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    proxyModel.toggleBookmark(id: request.id)
                } label: {
                    Image(systemName: isBookmarked ? "star.fill" : "star")
                }
                .buttonStyle(GlassIconButtonStyle())
                .foregroundStyle(isBookmarked ? Theme.statusColor(400) : Theme.textPrimary)
                .help(isBookmarked ? "Remove bookmark" : "Bookmark this request")

                Button {
                    showComparePicker = true
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(GlassIconButtonStyle())
                .disabled(otherRequests.isEmpty)
                .opacity(otherRequests.isEmpty ? 0.4 : 1)
                .help("Compare with another request")
                .popover(isPresented: $showComparePicker, arrowEdge: .bottom) {
                    ComparePickerList(candidates: otherRequests) { picked in
                        diffTarget = picked
                        showComparePicker = false
                    }
                }

                Button {
                    showCompose = true
                } label: {
                    Image(systemName: "arrow.uturn.up")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("Resend (edit and refire)")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(request.url, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(GlassIconButtonStyle())
            }

            HStack(spacing: 14) {
                statBadge(icon: "clock", value: request.durationMs.map { "\($0) ms" } ?? "—")
                statBadge(icon: "arrow.up", value: ByteCountFormatter.string(fromByteCount: Int64(request.bytesSent), countStyle: .binary))
                statBadge(icon: "arrow.down", value: ByteCountFormatter.string(fromByteCount: Int64(request.bytesReceived), countStyle: .binary))
            }

            TextField("Add a note…", text: $noteText)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onAppear { noteText = proxyModel.notes[request.id] ?? "" }
                .onChange(of: noteText) { _, newValue in proxyModel.setNote(id: request.id, text: newValue) }
        }
        .padding(16)
        .sheet(isPresented: $showCompose) {
            ComposeView(draft: ComposeDraft(resending: request))
        }
        .sheet(item: $diffTarget) { target in
            DiffView(requestA: request, requestB: target)
        }
    }

    private func statBadge(icon: String, value: String) -> some View {
        Label(value, systemImage: icon)
            .labelStyle(.compact)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.textTertiary)
    }
}

/// Popover content for picking the second request in a Diff comparison.
private struct ComparePickerList: View {
    let candidates: [CapturedRequestDisplay]
    let onPick: (CapturedRequestDisplay) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(candidates) { candidate in
                    Button {
                        onPick(candidate)
                    } label: {
                        HStack(spacing: 6) {
                            Chip(text: candidate.method, color: Theme.methodColor(candidate.method))
                            Text(candidate.url)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(width: 340, height: min(CGFloat(candidates.count) * 30 + 16, 320))
    }
}

/// Coarse timing breakdown — see `CapturedRequestDisplay.waitMs`'s doc
/// comment for why this is three phases (request send / wait / receive)
/// rather than Charles/Proxyman's full DNS/connect/TLS waterfall.
private struct TimingBreakdownView: View {
    let request: CapturedRequestDisplay

    private var phases: [(label: String, ms: Int64?, color: Color)] {
        [
            ("Request Send", request.requestSendMs, Theme.accent3),
            ("Waiting (TTFB)", request.waitMs, Theme.accent2),
            ("Response Receive", request.responseReceiveMs, Theme.accent),
        ]
    }

    private var total: Int64 {
        phases.compactMap(\.ms).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if total == 0 {
                Text("No timing data — this exchange never touched the network (served from Map Local, or blocked).")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                if total > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 1) {
                            ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                                if let ms = phase.ms, ms > 0 {
                                    phase.color.opacity(0.75)
                                        .frame(width: geo.size.width * CGFloat(ms) / CGFloat(max(total, 1)))
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .frame(height: 10)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        HStack(spacing: 8) {
                            Circle().fill(phase.color).frame(width: 8, height: 8)
                            Text(phase.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text(phase.ms.map { "\($0) ms" } ?? "—")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    Divider().overlay(Theme.hairline)
                    HStack {
                        Text("Total").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(request.durationMs.map { "\($0) ms" } ?? "—")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
            }
        }
    }
}

struct HeaderTable: View {
    let headers: [(String, String)]

    var body: some View {
        if headers.isEmpty {
            Text("No headers")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        } else {
            VStack(spacing: 1) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, pair in
                    HStack(alignment: .top, spacing: 10) {
                        Text(pair.0)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent3)
                            .frame(width: 160, alignment: .leading)
                        Text(pair.1)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(index % 2 == 0 ? Color.white.opacity(0.03) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}

struct CookieTable: View {
    let cookies: [ParsedCookie]

    var body: some View {
        VStack(spacing: 1) {
            ForEach(cookies) { cookie in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cookie.name)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.accent3)
                        Chip(text: cookie.source, color: cookie.source == "Response" ? Theme.methodColor("POST") : Theme.methodColor("GET"))
                        Spacer()
                    }
                    Text(cookie.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !cookie.attributes.isEmpty {
                        Text(cookie.attributes)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
