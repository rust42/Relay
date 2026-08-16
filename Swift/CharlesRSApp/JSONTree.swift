import SwiftUI

/// Parsed JSON, order-preserving. `JSONSerialization` doesn't guarantee
/// source key order, and the whole point of this tree is to look like what
/// the server actually sent — so this is a small hand-rolled parser rather
/// than a round-trip through Foundation's.
indirect enum JSONNode: Sendable {
    case object([(key: String, value: JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

enum JSONTreeParser {
    static func parse(_ text: String) -> JSONNode? {
        var chars = Array(text)[...]
        skipWhitespace(&chars)
        guard let node = parseValue(&chars) else { return nil }
        skipWhitespace(&chars)
        return chars.isEmpty ? node : node // trailing garbage still yields a usable tree
    }

    private static func skipWhitespace(_ s: inout ArraySlice<Character>) {
        while let f = s.first, f.isWhitespace { s.removeFirst() }
    }

    private static func parseValue(_ s: inout ArraySlice<Character>) -> JSONNode? {
        skipWhitespace(&s)
        guard let first = s.first else { return nil }
        switch first {
        case "{": return parseObject(&s)
        case "[": return parseArray(&s)
        case "\"": return parseString(&s).map(JSONNode.string)
        case "t": return consumeLiteral(&s, "true") ? .bool(true) : nil
        case "f": return consumeLiteral(&s, "false") ? .bool(false) : nil
        case "n": return consumeLiteral(&s, "null") ? .null : nil
        default: return parseNumber(&s)
        }
    }

    private static func parseObject(_ s: inout ArraySlice<Character>) -> JSONNode? {
        s.removeFirst() // {
        var pairs: [(String, JSONNode)] = []
        skipWhitespace(&s)
        if s.first == "}" { s.removeFirst(); return .object(pairs) }
        while true {
            skipWhitespace(&s)
            guard let key = parseString(&s) else { return nil }
            skipWhitespace(&s)
            guard s.first == ":" else { return nil }
            s.removeFirst()
            guard let value = parseValue(&s) else { return nil }
            pairs.append((key, value))
            skipWhitespace(&s)
            if s.first == "," { s.removeFirst(); continue }
            if s.first == "}" { s.removeFirst(); break }
            return nil
        }
        return .object(pairs)
    }

    private static func parseArray(_ s: inout ArraySlice<Character>) -> JSONNode? {
        s.removeFirst() // [
        var items: [JSONNode] = []
        skipWhitespace(&s)
        if s.first == "]" { s.removeFirst(); return .array(items) }
        while true {
            guard let value = parseValue(&s) else { return nil }
            items.append(value)
            skipWhitespace(&s)
            if s.first == "," { s.removeFirst(); continue }
            if s.first == "]" { s.removeFirst(); break }
            return nil
        }
        return .array(items)
    }

    private static func parseString(_ s: inout ArraySlice<Character>) -> String? {
        guard s.first == "\"" else { return nil }
        s.removeFirst()
        var out = ""
        while let c = s.first {
            s.removeFirst()
            if c == "\"" { return out }
            if c == "\\" {
                guard let esc = s.first else { return nil }
                s.removeFirst()
                switch esc {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"", "\\", "/": out.append(esc)
                case "u":
                    guard s.count >= 4 else { return nil }
                    let hex = String(s.prefix(4))
                    s.removeFirst(4)
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                        out.append(Character(scalar))
                    }
                default: out.append(esc)
                }
                continue
            }
            out.append(c)
        }
        return nil
    }

    private static func parseNumber(_ s: inout ArraySlice<Character>) -> JSONNode? {
        var out = ""
        if s.first == "-" { out.append(s.removeFirst()) }
        while let c = s.first, c.isNumber { out.append(c); s.removeFirst() }
        if s.first == "." {
            out.append(s.removeFirst())
            while let c = s.first, c.isNumber { out.append(c); s.removeFirst() }
        }
        if s.first == "e" || s.first == "E" {
            out.append(s.removeFirst())
            if s.first == "+" || s.first == "-" { out.append(s.removeFirst()) }
            while let c = s.first, c.isNumber { out.append(c); s.removeFirst() }
        }
        return out.isEmpty ? nil : .number(out)
    }

    private static func consumeLiteral(_ s: inout ArraySlice<Character>, _ literal: String) -> Bool {
        let chars = Array(literal)
        guard s.count >= chars.count, Array(s.prefix(chars.count)) == chars else { return false }
        s.removeFirst(chars.count)
        return true
    }
}

/// Interactive collapsible tree, matching Chrome/Charles-style JSON preview:
/// chevrons, inline "N items" summaries when collapsed, colored leaf values.
/// Top two levels start expanded; deeper nesting starts collapsed so a large
/// payload doesn't open as a wall of text.
struct JSONTreeView: View {
    let node: JSONNode

    var body: some View {
        JSONNodeRow(key: nil, node: node, depth: 0, isLast: true)
    }
}

private struct JSONNodeRow: View {
    let key: String?
    let node: JSONNode
    let depth: Int
    let isLast: Bool
    @State private var expanded: Bool

    init(key: String?, node: JSONNode, depth: Int, isLast: Bool) {
        self.key = key
        self.node = node
        self.depth = depth
        self.isLast = isLast
        _expanded = State(initialValue: depth < 2)
    }

    var body: some View {
        switch node {
        case .object(let pairs):
            container(open: "{", close: "}", summary: "\(pairs.count) key\(pairs.count == 1 ? "" : "s")") {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    JSONNodeRow(key: pair.key, node: pair.value, depth: depth + 1, isLast: index == pairs.count - 1)
                }
            }
        case .array(let items):
            container(open: "[", close: "]", summary: "\(items.count) item\(items.count == 1 ? "" : "s")") {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    JSONNodeRow(key: nil, node: item, depth: depth + 1, isLast: index == items.count - 1)
                }
            }
        default:
            leaf
        }
    }

    @ViewBuilder
    private func container<Children: View>(
        open: String, close: String, summary: String, @ViewBuilder children: () -> Children
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 10)
                    keyLabel
                    Text(open)
                        .foregroundStyle(Theme.textTertiary)
                    if !expanded {
                        Text(summary)
                            .foregroundStyle(Theme.textTertiary)
                            .italic()
                        Text(close)
                            .foregroundStyle(Theme.textTertiary)
                        if !isLast { Text(",").foregroundStyle(Theme.textTertiary) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    children()
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.hairline).frame(width: 1).padding(.leading, 4)
                }

                HStack(spacing: 0) {
                    Text(close).foregroundStyle(Theme.textTertiary)
                    if !isLast { Text(",").foregroundStyle(Theme.textTertiary) }
                }
                .padding(.leading, 14)
            }
        }
    }

    @ViewBuilder
    private var keyLabel: some View {
        if let key {
            Text("\"\(key)\"")
                .foregroundStyle(Theme.accent3)
            Text(": ")
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var leaf: some View {
        HStack(spacing: 0) {
            keyLabel
            leafValue
            if !isLast { Text(",").foregroundStyle(Theme.textTertiary) }
        }
        .padding(.leading, 14)
    }

    @ViewBuilder
    private var leafValue: some View {
        switch node {
        case .string(let s):
            Text("\"\(s)\"").foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.6))
        case .number(let n):
            Text(n).foregroundStyle(Theme.accent2)
        case .bool(let b):
            Text(b ? "true" : "false").foregroundStyle(Theme.accent2)
        case .null:
            Text("null").foregroundStyle(Theme.textTertiary)
        case .object, .array:
            EmptyView()
        }
    }
}
