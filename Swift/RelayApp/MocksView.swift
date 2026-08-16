import SwiftUI
import AppKit

/// Each of these six rule engines is a first-class sidebar entry (formerly
/// grouped under one "Mocks" tab behind a segmented picker — moved out so
/// each is one click away instead of two). All share the same
/// list-on-the-left, editor-on-the-right shape, backed by the private
/// panel/editor types below. "Local Mocks" is method+URL-pattern matched
/// against live traffic with a JS `onResponse(req, res)` running in the
/// Rust engine (via `boa_engine`); "Map Local" serves a local file's bytes
/// for matching requests and never touches the network; "Map Remote"
/// redials a match against a different host/port before it goes out;
/// "Rewrite" is a no-code list of header/status/body edits; "Block List"
/// refuses matching requests outright; "DNS Spoofing" redials a matched
/// host at a specific IP with the Host header untouched.

struct LocalMocksView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    private var selectedRule: MockRuleDisplay? {
        selectedRuleID.flatMap { id in proxyModel.mockRules.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 12) {
            MockRuleListPanel(selectedRuleID: $selectedRuleID)
                .frame(width: 320)
            Group {
                if let rule = selectedRule {
                    MockRuleEditor(rule: rule).id(rule.id)
                } else {
                    EmptyMockEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MapLocalToolView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    private var selectedRule: MapLocalRuleDisplay? {
        selectedRuleID.flatMap { id in proxyModel.mapLocalRules.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 12) {
            MapLocalRuleListPanel(selectedRuleID: $selectedRuleID)
                .frame(width: 320)
            Group {
                if let rule = selectedRule {
                    MapLocalRuleEditor(rule: rule).id(rule.id)
                } else {
                    EmptyMapLocalEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MapRemoteToolView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    private var selectedRule: MapRemoteRuleDisplay? {
        selectedRuleID.flatMap { id in proxyModel.mapRemoteRules.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 12) {
            MapRemoteRuleListPanel(selectedRuleID: $selectedRuleID)
                .frame(width: 320)
            Group {
                if let rule = selectedRule {
                    MapRemoteRuleEditor(rule: rule).id(rule.id)
                } else {
                    EmptyMapRemoteEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RewriteToolView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    private var selectedRule: RewriteRuleDisplay? {
        selectedRuleID.flatMap { id in proxyModel.rewriteRules.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 12) {
            RewriteRuleListPanel(selectedRuleID: $selectedRuleID)
                .frame(width: 320)
            Group {
                if let rule = selectedRule {
                    RewriteRuleEditor(rule: rule).id(rule.id)
                } else {
                    EmptyRewriteEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct BlockListToolView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    private var selectedRule: BlockRuleDisplay? {
        selectedRuleID.flatMap { id in proxyModel.blockRules.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 12) {
            BlockRuleListPanel(selectedRuleID: $selectedRuleID)
                .frame(width: 320)
            Group {
                if let rule = selectedRule {
                    BlockRuleEditor(rule: rule).id(rule.id)
                } else {
                    EmptyBlockEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DnsSpoofingToolView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    private var selectedRule: DnsSpoofRuleDisplay? {
        selectedRuleID.flatMap { id in proxyModel.dnsSpoofRules.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 12) {
            DnsSpoofRuleListPanel(selectedRuleID: $selectedRuleID)
                .frame(width: 320)
            Group {
                if let rule = selectedRule {
                    DnsSpoofRuleEditor(rule: rule).id(rule.id)
                } else {
                    EmptyDnsSpoofEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct FocusToolView: View {
    var body: some View {
        FocusPanel()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MockRuleListPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("LOCAL MOCKS")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    selectedRuleID = proxyModel.addMockRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New mock")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if proxyModel.mockRules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No mocks yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(proxyModel.mockRules) { rule in
                            MockRuleRow(rule: rule, isSelected: selectedRuleID == rule.id)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedRuleID = rule.id
                                    }
                                }
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
}

private struct MockRuleRow: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let rule: MockRuleDisplay
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Chip(text: rule.method?.uppercased() ?? "ANY", color: rule.method.map(Theme.methodColor) ?? Theme.textTertiary)
                    Text(rule.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if rule.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.statusColor(400))
                    }
                }
                Text(rule.urlContains.isEmpty ? "matches any URL" : rule.urlContains)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in proxyModel.toggleMockRule(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyMockEditor: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 4) {
                Text("No mock selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a mock on the left, or create a new one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct MockRuleEditor: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var draft: MockRuleDisplay
    let originalID: String

    init(rule: MockRuleDisplay) {
        _draft = State(initialValue: rule)
        originalID = rule.id
    }

    private var isDirty: Bool {
        guard let live = proxyModel.mockRules.first(where: { $0.id == originalID }) else { return false }
        return live != draft
    }

    private let methods = ["Any", "GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            if let error = draft.lastError {
                errorBanner(error)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fieldsRow
                    scriptEditor
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Mock name", text: $draft.displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if isDirty {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.statusColor(400))
            }

            Button("Save Script") {
                proxyModel.updateMockRule(draft)
            }
            .buttonStyle(GlassButtonStyle(prominent: isDirty, tint: Theme.accent))
            .disabled(!isDirty)

            Button {
                proxyModel.deleteMockRule(id: originalID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.statusColor(400))
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.statusColor(400).opacity(0.12))
    }

    private var fieldsRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("METHOD").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Picker("", selection: Binding(
                    get: { draft.method ?? "Any" },
                    set: { draft.method = $0 == "Any" ? nil : $0 }
                )) {
                    ForEach(methods, id: \.self) { Text($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("URL CONTAINS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("e.g. api.example.com/users", text: $draft.urlContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("ENABLED").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Toggle("", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INTERCEPTOR SCRIPT — onResponse(req, res)")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)

            TextEditor(text: $draft.script)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .foregroundStyle(Theme.textPrimary)
                .frame(minHeight: 320)
                .padding(10)
                .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Map Local

private struct MapLocalRuleListPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MAP LOCAL")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    selectedRuleID = proxyModel.addMapLocalRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New Map Local rule")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if proxyModel.mapLocalRules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.arrow.up")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No Map Local rules yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(proxyModel.mapLocalRules) { rule in
                            MapLocalRuleRow(rule: rule, isSelected: selectedRuleID == rule.id)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedRuleID = rule.id
                                    }
                                }
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
}

private struct MapLocalRuleRow: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let rule: MapLocalRuleDisplay
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Chip(text: rule.method?.uppercased() ?? "ANY", color: rule.method.map(Theme.methodColor) ?? Theme.textTertiary)
                    Text(rule.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if rule.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.statusColor(400))
                    }
                }
                Text(rule.localPath.isEmpty ? "no file chosen" : (rule.localPath as NSString).lastPathComponent)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in proxyModel.toggleMapLocalRule(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyMapLocalEditor: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: "doc.badge.arrow.up")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 4) {
                Text("No rule selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a Map Local rule on the left, or create a new one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct MapLocalRuleEditor: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var draft: MapLocalRuleDisplay
    let originalID: String

    init(rule: MapLocalRuleDisplay) {
        _draft = State(initialValue: rule)
        originalID = rule.id
    }

    private var isDirty: Bool {
        guard let live = proxyModel.mapLocalRules.first(where: { $0.id == originalID }) else { return false }
        return live != draft
    }

    private let methods = ["Any", "GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            if let error = draft.lastError {
                errorBanner(error)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fieldsRow
                    filePicker
                    contentTypeField
                    Text("Requests matching this rule never reach the network — the file's bytes are returned as-is, with a 200 status.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Rule name", text: $draft.displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if isDirty {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.statusColor(400))
            }

            Button("Save") {
                proxyModel.updateMapLocalRule(draft)
            }
            .buttonStyle(GlassButtonStyle(prominent: isDirty, tint: Theme.accent))
            .disabled(!isDirty)

            Button {
                proxyModel.deleteMapLocalRule(id: originalID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(16)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.statusColor(400))
            Text(message)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.statusColor(400).opacity(0.12))
    }

    private var fieldsRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("METHOD").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Picker("", selection: Binding(
                    get: { draft.method ?? "Any" },
                    set: { draft.method = $0 == "Any" ? nil : $0 }
                )) {
                    ForEach(methods, id: \.self) { Text($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("URL CONTAINS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("e.g. api.example.com/users", text: $draft.urlContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("ENABLED").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Toggle("", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var filePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LOCAL FILE").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 8) {
                TextField("/path/to/fixture.json", text: $draft.localPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("Choose…") { chooseFile() }
                    .buttonStyle(GlassButtonStyle())
            }
        }
    }

    private var contentTypeField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CONTENT TYPE").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
            TextField("auto-detect from file extension", text: Binding(
                get: { draft.contentType ?? "" },
                set: { draft.contentType = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.localPath = url.path
    }
}

// MARK: - Map Remote

private struct MapRemoteRuleListPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MAP REMOTE")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    selectedRuleID = proxyModel.addMapRemoteRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New Map Remote rule")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if proxyModel.mapRemoteRules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No Map Remote rules yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(proxyModel.mapRemoteRules) { rule in
                            MapRemoteRuleRow(rule: rule, isSelected: selectedRuleID == rule.id)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedRuleID = rule.id
                                    }
                                }
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
}

private struct MapRemoteRuleRow: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let rule: MapRemoteRuleDisplay
    let isSelected: Bool
    @State private var hovering = false

    private var targetSummary: String {
        let port = rule.targetPort.map { ":\($0)" } ?? ""
        return "\(rule.targetScheme)://\(rule.targetHost)\(port)"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(rule.matchHost.isEmpty ? "any host" : rule.matchHost)
                        .foregroundStyle(Theme.textTertiary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.textTertiary)
                    Text(targetSummary)
                        .foregroundStyle(Theme.accent3)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in proxyModel.toggleMapRemoteRule(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyMapRemoteEditor: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 4) {
                Text("No rule selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a Map Remote rule on the left, or create a new one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct MapRemoteRuleEditor: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var draft: MapRemoteRuleDisplay
    let originalID: String

    init(rule: MapRemoteRuleDisplay) {
        _draft = State(initialValue: rule)
        originalID = rule.id
    }

    private var isDirty: Bool {
        guard let live = proxyModel.mapRemoteRules.first(where: { $0.id == originalID }) else { return false }
        return live != draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    matchFields
                    targetFields
                    Text("The client still sees the original hostname — our certificate is minted for it. Only where the proxy actually connects changes, so this works for HTTPS traffic same as HTTP.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Rule name", text: $draft.displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if isDirty {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.statusColor(400))
            }

            Button("Save") {
                proxyModel.updateMapRemoteRule(draft)
            }
            .buttonStyle(GlassButtonStyle(prominent: isDirty, tint: Theme.accent))
            .disabled(!isDirty)

            Button {
                proxyModel.deleteMapRemoteRule(id: originalID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(16)
    }

    private var matchFields: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MATCH HOST").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("e.g. api.staging.example.com", text: $draft.matchHost)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("MATCH PATH CONTAINS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("optional — any path if empty", text: $draft.matchPathContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("ENABLED").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Toggle("", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var targetFields: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SCHEME").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Picker("", selection: $draft.targetScheme) {
                    Text("http").tag("http")
                    Text("https").tag("https")
                }
                .labelsHidden()
                .frame(width: 90)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("TARGET HOST").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("e.g. localhost", text: $draft.targetHost)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("PORT").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("default", text: Binding(
                    get: { draft.targetPort.map(String.init) ?? "" },
                    set: { draft.targetPort = UInt16($0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 80)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

// MARK: - Rewrite

private struct RewriteRuleListPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("REWRITE")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    selectedRuleID = proxyModel.addRewriteRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New Rewrite rule")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if proxyModel.rewriteRules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "pencil.line")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No Rewrite rules yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(proxyModel.rewriteRules) { rule in
                            RewriteRuleRow(rule: rule, isSelected: selectedRuleID == rule.id)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedRuleID = rule.id
                                    }
                                }
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
}

private struct RewriteRuleRow: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let rule: RewriteRuleDisplay
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Chip(text: "\(rule.actions.count)", color: Theme.accent2)
                }
                Text(rule.hostContains.isEmpty && rule.pathContains.isEmpty ? "matches any request" : [rule.hostContains, rule.pathContains].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in proxyModel.toggleRewriteRule(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyRewriteEditor: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: "pencil.line")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 4) {
                Text("No rule selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a Rewrite rule on the left, or create a new one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct RewriteRuleEditor: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var draft: RewriteRuleDisplay
    let originalID: String

    init(rule: RewriteRuleDisplay) {
        _draft = State(initialValue: rule)
        originalID = rule.id
    }

    private var isDirty: Bool {
        guard let live = proxyModel.rewriteRules.first(where: { $0.id == originalID }) else { return false }
        return live != draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    matchFields
                    actionsList
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Rule name", text: $draft.displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if isDirty {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.statusColor(400))
            }

            Button("Save") {
                proxyModel.updateRewriteRule(draft)
            }
            .buttonStyle(GlassButtonStyle(prominent: isDirty, tint: Theme.accent))
            .disabled(!isDirty)

            Button {
                proxyModel.deleteRewriteRule(id: originalID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(16)
    }

    private var matchFields: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HOST CONTAINS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("optional — any host if empty", text: $draft.hostContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("PATH CONTAINS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("optional — any path if empty", text: $draft.pathContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("ENABLED").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Toggle("", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var actionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACTIONS — applied in order")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    draft.actions.append(RewriteActionDraft())
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
            }

            if draft.actions.isEmpty {
                Text("No actions yet — add one above.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(draft.actions) { action in
                    RewriteActionRow(action: binding(for: action.id))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                draft.actions.removeAll { $0.id == action.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                        }
                }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<RewriteActionDraft> {
        Binding(
            get: { draft.actions.first { $0.id == id } ?? RewriteActionDraft() },
            set: { newValue in
                guard let index = draft.actions.firstIndex(where: { $0.id == id }) else { return }
                draft.actions[index] = newValue
            }
        )
    }
}

private struct RewriteActionRow: View {
    @Binding var action: RewriteActionDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $action.kind) {
                ForEach(RewriteActionKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 260)

            HStack(spacing: 8) {
                if action.kind.hasName {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.kind.nameLabel).font(.system(size: 8.5, weight: .bold)).tracking(0.4).foregroundStyle(Theme.textTertiary)
                        TextField("", text: $action.name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .frame(maxWidth: .infinity)
                }
                if !action.kind.valueLabel.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.kind.valueLabel).font(.system(size: 8.5, weight: .bold)).tracking(0.4).foregroundStyle(Theme.textTertiary)
                        TextField("", text: $action.value)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .padding(.trailing, 20)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Block List

private struct BlockRuleListPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BLOCK LIST")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    selectedRuleID = proxyModel.addBlockRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New Block rule")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if proxyModel.blockRules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "nosign")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No Block rules yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(proxyModel.blockRules) { rule in
                            BlockRuleRow(rule: rule, isSelected: selectedRuleID == rule.id)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedRuleID = rule.id
                                    }
                                }
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
}

private struct BlockRuleRow: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let rule: BlockRuleDisplay
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Chip(text: "\(rule.statusCode)", color: Theme.statusColor(Int(rule.statusCode)))
                }
                Text(rule.hostContains.isEmpty && rule.pathContains.isEmpty ? "matches any request" : [rule.hostContains, rule.pathContains].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in proxyModel.toggleBlockRule(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyBlockEditor: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: "nosign")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 4) {
                Text("No rule selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a Block rule on the left, or create a new one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct BlockRuleEditor: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var draft: BlockRuleDisplay
    let originalID: String

    init(rule: BlockRuleDisplay) {
        _draft = State(initialValue: rule)
        originalID = rule.id
    }

    private var isDirty: Bool {
        guard let live = proxyModel.blockRules.first(where: { $0.id == originalID }) else { return false }
        return live != draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fieldsRow
                    Text("A match never reaches the network — the client gets the status code below immediately.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Rule name", text: $draft.displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if isDirty {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.statusColor(400))
            }

            Button("Save") {
                proxyModel.updateBlockRule(draft)
            }
            .buttonStyle(GlassButtonStyle(prominent: isDirty, tint: Theme.accent))
            .disabled(!isDirty)

            Button {
                proxyModel.deleteBlockRule(id: originalID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(16)
    }

    private var fieldsRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HOST CONTAINS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("optional — any host if empty", text: $draft.hostContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("PATH CONTAINS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("optional — any path if empty", text: $draft.pathContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("STATUS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("403", text: Binding(
                    get: { String(draft.statusCode) },
                    set: { if let v = UInt16($0) { draft.statusCode = v } }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 70)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ENABLED").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Toggle("", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

// MARK: - DNS Spoofing

private struct DnsSpoofRuleListPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("DNS SPOOFING")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    selectedRuleID = proxyModel.addDnsSpoofRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New DNS Spoof rule")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if proxyModel.dnsSpoofRules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No DNS Spoof rules yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(proxyModel.dnsSpoofRules) { rule in
                            DnsSpoofRuleRow(rule: rule, isSelected: selectedRuleID == rule.id)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        selectedRuleID = rule.id
                                    }
                                }
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
}

private struct DnsSpoofRuleRow: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let rule: DnsSpoofRuleDisplay
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(rule.host.isEmpty ? "any host" : rule.host).foregroundStyle(Theme.textTertiary)
                    Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(Theme.textTertiary)
                    Text(rule.spoofIp).foregroundStyle(Theme.accent3)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in proxyModel.toggleDnsSpoofRule(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyDnsSpoofEditor: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient.opacity(0.18))
                    .frame(width: 76, height: 76)
                    .blur(radius: 8)
                Image(systemName: "globe.badge.chevron.backward")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accentGradient)
            }
            VStack(spacing: 4) {
                Text("No rule selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a DNS Spoof rule on the left, or create a new one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct DnsSpoofRuleEditor: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var draft: DnsSpoofRuleDisplay
    let originalID: String

    init(rule: DnsSpoofRuleDisplay) {
        _draft = State(initialValue: rule)
        originalID = rule.id
    }

    private var isDirty: Bool {
        guard let live = proxyModel.dnsSpoofRules.first(where: { $0.id == originalID }) else { return false }
        return live != draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fields
                    Text("The Host header (and everything else about the request) stays exactly as sent — only which address gets dialed changes. For HTTPS targets, this works reliably against servers that don't do strict SNI-based virtual hosting; a server that requires SNI to match the real hostname needs resolver-level spoofing instead, which this simple rule doesn't do.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Rule name", text: $draft.displayName)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if isDirty {
                Text("Unsaved")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.statusColor(400))
            }

            Button("Save") {
                proxyModel.updateDnsSpoofRule(draft)
            }
            .buttonStyle(GlassButtonStyle(prominent: isDirty, tint: Theme.accent))
            .disabled(!isDirty)

            Button {
                proxyModel.deleteDnsSpoofRule(id: originalID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(16)
    }

    private var fields: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HOST").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("e.g. api.example.com", text: $draft.host)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("SPOOF TO IP").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                TextField("e.g. 127.0.0.1", text: $draft.spoofIp)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                Text("ENABLED").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Toggle("", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

// MARK: - Focus

private struct FocusPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var newHost = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FOCUS")
                        .font(.system(size: 10.5, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.textTertiary)
                    Text("Narrow what gets recorded to specific hosts. Traffic that doesn't match still passes through untouched — this only declutters the inspector.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { proxyModel.focusEnabled },
                    set: { proxyModel.setFocusEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                TextField("e.g. api.example.com", text: $newHost)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("Add") {
                    proxyModel.addFocusHost(newHost)
                    newHost = ""
                }
                .buttonStyle(GlassButtonStyle())
                .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if proxyModel.focusHosts.isEmpty {
                Text(proxyModel.focusEnabled ? "No hosts added — Focus is on but has nothing to narrow, so everything is still recorded." : "No hosts added yet.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                VStack(spacing: 4) {
                    ForEach(proxyModel.focusHosts, id: \.self) { host in
                        HStack {
                            Text(host)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button {
                                proxyModel.removeFocusHost(host)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassPanel(cornerRadius: 10)
    }
}
