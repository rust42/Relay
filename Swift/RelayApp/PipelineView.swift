import SwiftUI

/// Scripting section: pipelines on the left, a connected step-flow editor
/// on the right. Each pipeline is an ordered chain of filter/action steps
/// that runs against live traffic, no code required — see `PipelineRule`'s
/// doc comment on the Rust side for why this is a linear chain rather than
/// a free-form 2D node canvas with draggable wires.
struct PipelineToolView: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    private var selectedRule: PipelineRuleDisplay? {
        selectedRuleID.flatMap { id in proxyModel.pipelineRules.first { $0.id == id } }
    }

    var body: some View {
        HStack(spacing: 12) {
            PipelineRuleListPanel(selectedRuleID: $selectedRuleID)
                .frame(width: 320)
            Group {
                if let rule = selectedRule {
                    PipelineRuleEditor(rule: rule).id(rule.id)
                } else {
                    EmptyPipelineEditor()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PipelineRuleListPanel: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @Binding var selectedRuleID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PIPELINES")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    selectedRuleID = proxyModel.addPipelineRule()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .help("New pipeline")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if proxyModel.pipelineRules.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No pipelines yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(proxyModel.pipelineRules) { rule in
                            PipelineRuleRow(rule: rule, isSelected: selectedRuleID == rule.id)
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

private struct PipelineRuleRow: View {
    @EnvironmentObject var proxyModel: ProxyModel
    let rule: PipelineRuleDisplay
    let isSelected: Bool
    @State private var hovering = false

    private var summary: String {
        let filters = rule.steps.filter { $0.kind.isFilter }.count
        let actions = rule.steps.count - filters
        return "\(filters) filter\(filters == 1 ? "" : "s") · \(actions) action\(actions == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Chip(text: "\(rule.steps.count)", color: Theme.accent2)
                }
                Text(rule.steps.isEmpty ? "no steps yet" : summary)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in proxyModel.togglePipelineRule(id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient.opacity(0.28)) : AnyShapeStyle(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct EmptyPipelineEditor: View {
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
                Text("No pipeline selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("Pick a pipeline on the left, or create a new one.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 10)
    }
}

private struct PipelineRuleEditor: View {
    @EnvironmentObject var proxyModel: ProxyModel
    @State private var draft: PipelineRuleDisplay
    let originalID: String

    init(rule: PipelineRuleDisplay) {
        _draft = State(initialValue: rule)
        originalID = rule.id
    }

    private var isDirty: Bool {
        guard let live = proxyModel.pipelineRules.first(where: { $0.id == originalID }) else { return false }
        return live != draft
    }

    /// Index of the first response-phase step, if any — everything from
    /// here on runs after the fetch. `nil` means the whole pipeline is
    /// request-phase only.
    private var responsePhaseStart: Int? {
        draft.steps.firstIndex { $0.kind.isResponsePhase }
    }

    /// A request-phase step sitting after the response-phase boundary
    /// would silently no-op on the Rust side (it never gets there in time)
    /// — flagged here so it's caught in the editor, not discovered later
    /// wondering why a step "isn't working".
    private var misorderedStepIDs: Set<UUID> {
        guard let boundary = responsePhaseStart else { return [] }
        return Set(draft.steps[boundary...].filter { !$0.kind.isResponsePhase }.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline).padding(.horizontal, 16)

            if !misorderedStepIDs.isEmpty {
                warningBanner
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepsFlow
                    addStepButton
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
            TextField("Pipeline name", text: $draft.displayName)
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
                proxyModel.updatePipelineRule(draft)
            }
            .buttonStyle(GlassButtonStyle(prominent: isDirty, tint: Theme.accent))
            .disabled(!isDirty)

            Button {
                proxyModel.deletePipelineRule(id: originalID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(GlassIconButtonStyle())
        }
        .padding(16)
    }

    private var warningBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.statusColor(400))
            Text("A request step (filter or header) sits after a response step — it won't run. Move it above the \"→ response\" divider using the up arrow.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.statusColor(400).opacity(0.12))
    }

    private var stepsFlow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STEPS — runs top to bottom against live traffic")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
                .padding(.bottom, 4)

            if draft.steps.isEmpty {
                Text("No steps yet — add one below.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                    if index == responsePhaseStart {
                        phaseDivider
                    }
                    PipelineStepRow(
                        index: index,
                        step: binding(for: step.id),
                        isMisordered: misorderedStepIDs.contains(step.id),
                        isFirst: index == 0,
                        isLast: index == draft.steps.count - 1,
                        onMoveUp: { moveStep(step.id, by: -1) },
                        onMoveDown: { moveStep(step.id, by: 1) },
                        onDelete: { draft.steps.removeAll { $0.id == step.id } }
                    )
                    if index < draft.steps.count - 1 {
                        connector
                    }
                }
            }
        }
    }

    private var connector: some View {
        Rectangle()
            .fill(Theme.hairlineBright)
            .frame(width: 2, height: 14)
            .padding(.leading, 15)
    }

    private var phaseDivider: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.hairlineBright).frame(height: 1)
            Text("→ RESPONSE")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.accent3)
                .fixedSize()
            Rectangle().fill(Theme.hairlineBright).frame(height: 1)
        }
        .padding(.vertical, 2)
    }

    private var addStepButton: some View {
        Button {
            draft.steps.append(PipelineStepDraft())
        } label: {
            Label("Add Step", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassButtonStyle())
    }

    private func binding(for id: UUID) -> Binding<PipelineStepDraft> {
        Binding(
            get: { draft.steps.first { $0.id == id } ?? PipelineStepDraft() },
            set: { newValue in
                guard let index = draft.steps.firstIndex(where: { $0.id == id }) else { return }
                draft.steps[index] = newValue
            }
        )
    }

    private func moveStep(_ id: UUID, by offset: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = index + offset
        guard draft.steps.indices.contains(newIndex) else { return }
        draft.steps.swapAt(index, newIndex)
    }
}

/// One card in the step flow — a numbered node, filter/action styling, and
/// the fields relevant to whichever `PipelineStepKind` it currently is.
private struct PipelineStepRow: View {
    let index: Int
    @Binding var step: PipelineStepDraft
    let isMisordered: Bool
    let isFirst: Bool
    let isLast: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    private var nodeColor: Color { step.kind.isFilter ? Theme.accent3 : Theme.accent2 }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(nodeColor.opacity(0.18)).frame(width: 30, height: 30)
                Circle().strokeBorder(nodeColor.opacity(0.6), lineWidth: 1.5).frame(width: 30, height: 30)
                Image(systemName: step.kind.isFilter ? "line.3.horizontal.decrease" : "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(nodeColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: $step.kind) {
                        ForEach(PipelineStepKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 240)

                    Spacer()

                    Button(action: onMoveUp) {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isFirst ? Theme.textTertiary : Theme.textSecondary)
                    .disabled(isFirst)

                    Button(action: onMoveDown) {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isLast ? Theme.textTertiary : Theme.textSecondary)
                    .disabled(isLast)

                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                }

                HStack(spacing: 8) {
                    if step.kind.hasName {
                        fieldEditor(label: step.kind.nameLabel, text: $step.name)
                    }
                    fieldEditor(label: step.kind.valueLabel, text: $step.value)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isMisordered ? Theme.statusColor(400).opacity(0.7) : Theme.hairline, lineWidth: isMisordered ? 1.5 : 1)
        )
    }

    private func fieldEditor(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 8, weight: .bold)).tracking(0.3).foregroundStyle(Theme.textTertiary)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .frame(maxWidth: .infinity)
    }
}
