import SwiftUI
import AppKit

/// What a captured body actually is, decided from its Content-Type header
/// (falling back to sniffing the first non-whitespace byte for JSON when the
/// header is missing/generic, which happens more often than you'd expect).
enum BodyKind {
    case json
    case xml
    case html
    case javascript
    case css
    case image
    case text
    case binary
    case empty
}

enum BodyKindDetector {
    static func contentType(from headers: [(String, String)]) -> String? {
        headers.first { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }?.1
            .split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func kind(contentType: String?, base64: String?) -> BodyKind {
        guard let base64, !base64.isEmpty else { return .empty }
        let ct = contentType?.lowercased() ?? ""

        if ct.hasPrefix("image/") { return .image }
        if ct.contains("json") { return .json }
        if ct.contains("xml") { return .xml }
        if ct.contains("html") { return .html }
        if ct.contains("javascript") || ct.contains("ecmascript") { return .javascript }
        if ct.contains("css") { return .css }
        if ct.hasPrefix("text/") { return .text }

        // No/generic content-type: sniff. A lot of APIs forget the header.
        if let data = Data(base64Encoded: base64) {
            if looksBinary(data) { return .binary }
            if let text = String(data: data.prefix(256), encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
                if trimmed.hasPrefix("<") { return .xml }
            }
            return .text
        }
        return .binary
    }

    /// A cheap binary sniff: NUL bytes or a high proportion of non-printable
    /// bytes in the first chunk means this isn't meant to be read as text.
    private static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(512)
        guard !sample.isEmpty else { return false }
        var nonPrintable = 0
        for byte in sample {
            if byte == 0 { return true }
            if byte < 0x09 || (byte > 0x0D && byte < 0x20) { nonPrintable += 1 }
        }
        return Double(nonPrintable) / Double(sample.count) > 0.15
    }
}

/// Result of the (potentially expensive) decode+parse work, computed off the
/// main actor — see `BodyView.render(base64:contentType:)`. Everything here
/// is a value type over Sendable pieces, so it can cross the actor boundary
/// without a copy of any reference type.
enum RenderedBody: Sendable {
    case empty
    case unreadable
    case imageData(Data)
    case jsonTree(JSONNode)
    case highlighted(AttributedString)
    case binary(Data)
}

/// Top-level body view: decodes the base64 payload and parses/formats it
/// off the main actor, then renders. Large payloads (we cap capture at 3MB)
/// would otherwise run a recursive parse directly inside `body`, which
/// SwiftUI always evaluates on @MainActor — that's a real stutter risk this
/// sidesteps via `.task(id:)` + a background `Task.detached`.
struct BodyView: View {
    let base64: String?
    let truncated: Bool
    let contentType: String?

    @State private var rendered: RenderedBody?

    // Cheap enough to stay synchronous: used for the header row (byte count,
    // copy button) regardless of which branch below is showing.
    private var data: Data? { base64.flatMap { Data(base64Encoded: $0) } }
    private var kind: BodyKind { BodyKindDetector.kind(contentType: contentType, base64: base64) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if kind != .empty {
                HStack(spacing: 6) {
                    Chip(text: kindLabel, color: kindColor)
                    if let data {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if truncated {
                        Chip(text: "TRUNCATED", color: Theme.statusColor(400))
                    }
                    Spacer()
                    if let data {
                        CopyButton(data: data, kind: kind)
                    }
                }
            }

            content
        }
        .task(id: base64) {
            rendered = nil
            let result = await Self.render(base64: base64, contentType: contentType)
            if !Task.isCancelled { rendered = result }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch rendered {
        case nil:
            if kind == .empty {
                EmptyView()
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        case .empty:
            Text("Empty body")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        case .unreadable:
            unreadable
        case .imageData(let data):
            if let image = NSImage(data: data) {
                ImageBodyView(image: image)
            } else {
                unreadable
            }
        case .jsonTree(let node):
            ScrollView(.horizontal, showsIndicators: false) {
                JSONTreeView(node: node)
                    .font(.system(size: 11.5, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(12)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        case .highlighted(let attributed):
            FormattedCodeView(attributed: attributed)
        case .binary(let data):
            binaryPlaceholder(data)
        }
    }

    /// All the actual decode/parse work, off @MainActor. Free function
    /// (rather than an instance method) so the `@Sendable` closure required
    /// by `Task.detached` can't accidentally capture the view itself.
    private static func render(base64: String?, contentType: String?) async -> RenderedBody {
        await Task.detached(priority: .userInitiated) {
            guard let base64, !base64.isEmpty else { return .empty }
            let kind = BodyKindDetector.kind(contentType: contentType, base64: base64)
            guard let data = Data(base64Encoded: base64) else { return .unreadable }

            switch kind {
            case .empty:
                return .empty
            case .image:
                return .imageData(data)
            case .json:
                guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
                if let tree = JSONTreeParser.parse(text) {
                    return .jsonTree(tree)
                }
                return .highlighted(JSONFormatter.highlight(text))
            case .xml, .html:
                guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
                return .highlighted(XMLFormatter.highlight(text))
            case .javascript, .css, .text:
                guard let text = String(data: data, encoding: .utf8) else { return .unreadable }
                return .highlighted(AttributedString(text))
            case .binary:
                return .binary(data)
            }
        }.value
    }

    private var unreadable: some View {
        Text("Could not decode body")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textTertiary)
    }

    private func binaryPlaceholder(_ data: Data) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 20))
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Binary data")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(data.count) bytes · not previewable")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private var kindLabel: String {
        switch kind {
        case .json: return "JSON"
        case .xml: return "XML"
        case .html: return "HTML"
        case .javascript: return "JS"
        case .css: return "CSS"
        case .image: return "IMAGE"
        case .text: return "TEXT"
        case .binary: return "BINARY"
        case .empty: return ""
        }
    }

    private var kindColor: Color {
        switch kind {
        case .json: return Theme.methodColor("POST")
        case .xml, .html: return Theme.methodColor("PUT")
        case .javascript, .css: return Theme.accent2
        case .image: return Theme.accent3
        case .binary: return Theme.textTertiary
        default: return Theme.accent
        }
    }
}

private struct CopyButton: View {
    let data: Data
    let kind: BodyKind
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            if kind == .image, let image = NSImage(data: data) {
                NSPasteboard.general.writeObjects([image])
            } else if let text = String(data: data, encoding: .utf8) {
                NSPasteboard.general.setString(text, forType: .string)
            }
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(GlassIconButtonStyle())
    }
}

/// Monospace code surface shared by JSON/XML/plain-text bodies.
private struct FormattedCodeView: View {
    let attributed: AttributedString

    var body: some View {
        Text(attributed)
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

private struct ImageBodyView: View {
    let image: NSImage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 360)
                .background(checkerboard)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
            Text("\(Int(image.size.width)) × \(Int(image.size.height)) px")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var checkerboard: some View {
        GeometryReader { geo in
            let tile: CGFloat = 10
            Canvas { ctx, size in
                var y: CGFloat = 0
                var row = 0
                while y < size.height {
                    var x: CGFloat = 0
                    var col = 0
                    while x < size.width {
                        let dark = (row + col) % 2 == 0
                        ctx.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)),
                                 with: .color(dark ? .black.opacity(0.18) : .black.opacity(0.08)))
                        x += tile
                        col += 1
                    }
                    y += tile
                    row += 1
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// MARK: - JSON formatter

/// Hand-rolled JSON pretty-printer + syntax highlighter. Deliberately
/// text-based (tokenize the original string, re-emit with indentation)
/// rather than round-tripping through `JSONSerialization`, so key order is
/// preserved exactly as the server sent it.
enum JSONFormatter {
    static func highlight(_ raw: String) -> AttributedString {
        var tokenizer = JSONTokenizer(raw)
        guard let tokens = tokenizer.tokenizeAll() else {
            var fallback = AttributedString(raw)
            fallback.foregroundColor = Theme.textPrimary
            return fallback
        }

        var out = AttributedString()
        var indent = 0
        let indentUnit = "  "

        func appendIndent() {
            if indent > 0 {
                out += AttributedString(String(repeating: indentUnit, count: indent))
            }
        }

        var i = 0
        var needsIndentOnNext = false
        while i < tokens.count {
            let tok = tokens[i]
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil

            if needsIndentOnNext, tok.kind != .arrayClose, tok.kind != .objectClose {
                appendIndent()
            }
            needsIndentOnNext = false

            var piece = AttributedString(tok.text)
            piece.foregroundColor = color(for: tok.kind)
            if tok.kind == .key { piece.font = .system(size: 11.5, weight: .semibold, design: .monospaced) }

            switch tok.kind {
            case .objectOpen, .arrayOpen:
                out += piece
                if let next, next.kind == .objectClose || next.kind == .arrayClose {
                    // Empty container: keep on one line.
                } else {
                    indent += 1
                    out += AttributedString("\n")
                    needsIndentOnNext = true
                }
            case .objectClose, .arrayClose:
                if let prevKind = i > 0 ? tokens[i - 1].kind : nil,
                   prevKind == .objectOpen || prevKind == .arrayOpen {
                    out += piece
                } else {
                    indent = max(0, indent - 1)
                    appendIndent()
                    out += piece
                }
            case .comma:
                out += piece
                out += AttributedString("\n")
                needsIndentOnNext = true
            case .colon:
                out += piece
                out += AttributedString(" ")
            default:
                out += piece
            }
            i += 1
        }
        return out
    }

    private static func color(for kind: JSONTokenKind) -> Color {
        switch kind {
        case .key: return Theme.accent3
        case .string: return Color(red: 0.55, green: 0.85, blue: 0.6)
        case .number: return Color(red: 0.98, green: 0.72, blue: 0.45)
        case .bool, .null: return Theme.accent2
        case .objectOpen, .objectClose, .arrayOpen, .arrayClose, .colon, .comma: return Theme.textTertiary
        }
    }
}

private enum JSONTokenKind {
    case objectOpen, objectClose, arrayOpen, arrayClose, colon, comma, key, string, number, bool, null
}

private struct JSONToken { let kind: JSONTokenKind; let text: String }

/// Minimal JSON lexer — just enough to re-indent and colorize; not a
/// validator. Falls back gracefully (`nil`) on anything it can't make
/// sense of, so malformed input degrades to plain monospace instead of
/// crashing or looping.
private struct JSONTokenizer {
    private let chars: [Character]
    private var pos = 0

    init(_ s: String) { chars = Array(s) }

    mutating func tokenizeAll() -> [JSONToken]? {
        var tokens: [JSONToken] = []
        var guardCounter = 0
        let maxIterations = chars.count * 2 + 16
        while let tok = next() {
            tokens.append(tok)
            guardCounter += 1
            if guardCounter > maxIterations { return nil }
        }
        return pos >= chars.count ? tokens : nil
    }

    private mutating func skipWhitespace() {
        while pos < chars.count, chars[pos].isWhitespace { pos += 1 }
    }

    private mutating func next() -> JSONToken? {
        skipWhitespace()
        guard pos < chars.count else { return nil }
        let c = chars[pos]

        switch c {
        case "{": pos += 1; return JSONToken(kind: .objectOpen, text: "{")
        case "}": pos += 1; return JSONToken(kind: .objectClose, text: "}")
        case "[": pos += 1; return JSONToken(kind: .arrayOpen, text: "[")
        case "]": pos += 1; return JSONToken(kind: .arrayClose, text: "]")
        case ":": pos += 1; return JSONToken(kind: .colon, text: ":")
        case ",": pos += 1; return JSONToken(kind: .comma, text: ",")
        case "\"":
            guard let str = readString() else { return nil }
            let isKey = followsIntoKeyPosition()
            return JSONToken(kind: isKey ? .key : .string, text: str)
        case "t":
            return readLiteral("true", .bool)
        case "f":
            return readLiteral("false", .bool)
        case "n":
            return readLiteral("null", .null)
        default:
            if c == "-" || c.isNumber {
                return readNumber()
            }
            return nil
        }
    }

    /// A string token is a "key" if the next non-whitespace character is a
    /// colon. Cheap one-token lookahead without consuming.
    private func followsIntoKeyPosition() -> Bool {
        var p = pos
        while p < chars.count, chars[p].isWhitespace { p += 1 }
        return p < chars.count && chars[p] == ":"
    }

    private mutating func readString() -> String? {
        var out = "\""
        pos += 1 // opening quote
        while pos < chars.count {
            let c = chars[pos]
            out.append(c)
            pos += 1
            if c == "\\" {
                guard pos < chars.count else { return nil }
                out.append(chars[pos])
                pos += 1
                continue
            }
            if c == "\"" { return out }
        }
        return nil
    }

    private mutating func readLiteral(_ literal: String, _ kind: JSONTokenKind) -> JSONToken? {
        let end = pos + literal.count
        guard end <= chars.count, String(chars[pos..<end]) == literal else { return nil }
        pos = end
        return JSONToken(kind: kind, text: literal)
    }

    private mutating func readNumber() -> JSONToken? {
        let start = pos
        if chars[pos] == "-" { pos += 1 }
        while pos < chars.count, chars[pos].isNumber { pos += 1 }
        if pos < chars.count, chars[pos] == "." {
            pos += 1
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
        }
        if pos < chars.count, chars[pos] == "e" || chars[pos] == "E" {
            pos += 1
            if pos < chars.count, chars[pos] == "+" || chars[pos] == "-" { pos += 1 }
            while pos < chars.count, chars[pos].isNumber { pos += 1 }
        }
        guard pos > start else { return nil }
        return JSONToken(kind: .number, text: String(chars[start..<pos]))
    }
}

// MARK: - XML/HTML formatter

/// Lightweight XML/HTML indenter + colorizer. Line-oriented rather than a
/// full parser: splits on `<`/`>` boundaries, indents by nesting depth, and
/// colors tag names/attributes. Good enough for API responses and REST
/// error bodies; not a substitute for a real XML parser.
enum XMLFormatter {
    static func highlight(_ raw: String) -> AttributedString {
        let collapsed = raw
            .replacingOccurrences(of: ">\\s*<", with: "><", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var out = AttributedString()
        var depth = 0
        var i = collapsed.startIndex

        while i < collapsed.endIndex {
            guard collapsed[i] == "<" else {
                // Stray text before the first tag — emit verbatim.
                let rest = collapsed[i...]
                var piece = AttributedString(String(rest))
                piece.foregroundColor = Theme.textPrimary
                out += piece
                break
            }
            guard let close = collapsed[i...].firstIndex(of: ">") else {
                var piece = AttributedString(String(collapsed[i...]))
                piece.foregroundColor = Theme.textPrimary
                out += piece
                break
            }
            let tag = String(collapsed[i...close])
            let isClosing = tag.hasPrefix("</")
            let isSelfClosing = tag.hasSuffix("/>") || tag.hasPrefix("<?") || tag.hasPrefix("<!")

            if isClosing { depth = max(0, depth - 1) }
            out += AttributedString(String(repeating: "  ", count: depth))
            out += colorizeTag(tag)
            out += AttributedString("\n")
            if !isClosing && !isSelfClosing { depth += 1 }

            i = collapsed.index(after: close)
        }
        return out
    }

    private static func colorizeTag(_ tag: String) -> AttributedString {
        var result = AttributedString()
        var chars = Substring(tag)

        func take(while predicate: (Character) -> Bool) -> String {
            var s = ""
            while let f = chars.first, predicate(f) { s.append(f); chars.removeFirst() }
            return s
        }

        while let first = chars.first {
            if first == "<" || first == ">" || first == "/" {
                var p = AttributedString(String(first))
                p.foregroundColor = Theme.textTertiary
                result += p
                chars.removeFirst()
            } else if first == "\"" {
                var s = "\""
                chars.removeFirst()
                while let c = chars.first, c != "\"" { s.append(c); chars.removeFirst() }
                if chars.first == "\"" { s.append("\""); chars.removeFirst() }
                var p = AttributedString(s)
                p.foregroundColor = Color(red: 0.55, green: 0.85, blue: 0.6)
                result += p
            } else if first == "=" {
                var p = AttributedString("=")
                p.foregroundColor = Theme.textTertiary
                result += p
                chars.removeFirst()
            } else if first.isWhitespace {
                result += AttributedString(take { $0.isWhitespace })
            } else {
                let word = take { !$0.isWhitespace && $0 != "=" && $0 != ">" && $0 != "/" }
                var p = AttributedString(word)
                p.foregroundColor = Theme.accent3
                p.font = .system(size: 11.5, weight: .semibold, design: .monospaced)
                result += p
            }
        }
        return result
    }
}

/// Raw, unformatted body text — the "Response" tab's job is to show exactly
/// what came over the wire (after gzip/deflate decompression, still applied
/// on the Rust side), as opposed to "Preview"'s pretty-printed rendering.
/// Decoding is cheap (no parsing) so this stays synchronous.
struct RawBodyView: View {
    let base64: String?

    var body: some View {
        Group {
            if let base64, let data = Data(base64Encoded: base64), !data.isEmpty {
                if let text = String(data: data, encoding: .utf8) {
                    Text(text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                } else {
                    Text("\(data.count) bytes of binary data")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            } else {
                Text("Empty body")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
