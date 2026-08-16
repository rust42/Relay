import SwiftUI

enum DiffLineKind {
    case same, added, removed
}

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: DiffLineKind
    let text: String
}

/// A basic line-level diff — not a semantic (JSON-aware) diff, just LCS over
/// text lines, same idea as `diff -u`. Bounded so a huge body can't hang the
/// UI: the O(n·m) table below costs a few MB at the cap and is instant;
/// past it, this falls back to a coarse "everything on the left removed,
/// everything on the right added" view rather than compute (or hang) a
/// proper alignment.
enum LineDiff {
    static let maxLines = 1200

    static func diff(_ oldText: String, _ newText: String) -> [DiffLine] {
        let oldLines = oldText.components(separatedBy: "\n")
        let newLines = newText.components(separatedBy: "\n")

        guard oldLines.count <= maxLines, newLines.count <= maxLines else {
            return oldLines.map { DiffLine(kind: .removed, text: $0) }
                + newLines.map { DiffLine(kind: .added, text: $0) }
        }

        let n = oldLines.count
        let m = newLines.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = oldLines[i] == newLines[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < n, j < m {
            if oldLines[i] == newLines[j] {
                result.append(DiffLine(kind: .same, text: oldLines[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(DiffLine(kind: .removed, text: oldLines[i]))
                i += 1
            } else {
                result.append(DiffLine(kind: .added, text: newLines[j]))
                j += 1
            }
        }
        while i < n { result.append(DiffLine(kind: .removed, text: oldLines[i])); i += 1 }
        while j < m { result.append(DiffLine(kind: .added, text: newLines[j])); j += 1 }
        return result
    }
}

/// Side-by-side comparison of two captured requests: status/method/URL at a
/// glance, which response headers differ, and a line diff of the response
/// bodies. Not JSON-aware — reordering equivalent keys shows as a change —
/// good enough for "did this endpoint's response actually change" without
/// building a structural diff engine.
struct DiffView: View {
    @Environment(\.dismiss) private var dismiss
    let requestA: CapturedRequestDisplay
    let requestB: CapturedRequestDisplay

    private var lines: [DiffLine] {
        LineDiff.diff(decodedBody(requestA.responseBodyBase64), decodedBody(requestB.responseBodyBase64))
    }

    private var headerDiffs: [(name: String, a: String?, b: String?)] {
        let dictA = Dictionary(requestA.responseHeaders, uniquingKeysWith: { a, _ in a })
        let dictB = Dictionary(requestB.responseHeaders, uniquingKeysWith: { a, _ in a })
        let names = Set(dictA.keys).union(dictB.keys).sorted()
        return names.compactMap { name in
            let a = dictA[name]
            let b = dictB[name]
            return a == b ? nil : (name, a, b)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            summaryRow
            if !headerDiffs.isEmpty {
                Divider().overlay(Theme.hairline)
                headerDiffSection
            }
            Divider().overlay(Theme.hairline)
            bodyDiffSection
        }
        .frame(width: 780, height: 640)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(Theme.accentGradient)
            Text("Compare Responses")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(GlassIconButtonStyle())
                .frame(width: 60, height: 28)
        }
        .padding(14)
    }

    private var summaryRow: some View {
        HStack(spacing: 0) {
            requestSummary(requestA, label: "A")
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(Theme.hairline).frame(height: 40)
            requestSummary(requestB, label: "B")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func requestSummary(_ request: CapturedRequestDisplay, label: String) -> some View {
        HStack(spacing: 8) {
            Chip(text: label, color: Theme.accent2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Chip(text: request.method, color: Theme.methodColor(request.method))
                    if let status = request.statusCode {
                        Text("\(status)").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(Theme.statusColor(status))
                    }
                }
                Text(request.url)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var headerDiffSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RESPONSE HEADERS THAT DIFFER")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            ForEach(headerDiffs, id: \.name) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.name)
                        .foregroundStyle(Theme.accent3)
                        .frame(width: 160, alignment: .leading)
                    Text(entry.a ?? "—")
                        .foregroundStyle(Theme.statusColor(500))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.b ?? "—")
                        .foregroundStyle(Theme.methodColor("POST"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 10.5, design: .monospaced))
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 8)
        }
    }

    private var bodyDiffSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker(line.kind))
                            .frame(width: 12)
                        Text(line.text.isEmpty ? " " : line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(textColor(line.kind))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                    .background(background(line.kind))
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
    }

    private func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .same: return " "
        case .added: return "+"
        case .removed: return "−"
        }
    }

    private func textColor(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .same: return Theme.textSecondary
        case .added: return Color(red: 0.55, green: 0.85, blue: 0.6)
        case .removed: return Theme.statusColor(500)
        }
    }

    private func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .same: return .clear
        case .added: return Color(red: 0.45, green: 0.85, blue: 0.55).opacity(0.10)
        case .removed: return Theme.statusColor(500).opacity(0.10)
        }
    }

    private func decodedBody(_ base64: String?) -> String {
        guard let base64, let data = Data(base64Encoded: base64) else { return "" }
        return String(data: data, encoding: .utf8) ?? "(binary body, not diffable)"
    }
}
