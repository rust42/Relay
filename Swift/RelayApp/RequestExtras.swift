import Foundation
import AppKit

/// Host/path split out of a captured request's URL, shared by the traffic
/// row display and by column sorting so both agree on exactly what "Host"
/// and "Path" mean.
extension CapturedRequestDisplay {
    var hostAndPath: (host: String, path: String) {
        guard let parsed = URL(string: url) else { return ("", url) }
        let host = parsed.host ?? ""
        var path = parsed.path.isEmpty ? "/" : parsed.path
        if let query = parsed.query { path += "?\(query)" }
        return (host, path)
    }
}

/// A sortable column in the traffic table.
enum SortColumn: String, CaseIterable {
    case status, method, host, path, type, time
}

extension Array where Element == CapturedRequestDisplay {
    /// Sorts by `column` (nil leaves capture order — newest first — alone).
    /// `nil` field values (in-flight status/duration) always sort last,
    /// regardless of direction, rather than jumping around depending on
    /// ascending/descending.
    func sorted(by column: SortColumn?, ascending: Bool) -> [CapturedRequestDisplay] {
        guard let column else { return self }

        func compare<T: Comparable>(_ a: T?, _ b: T?) -> Bool {
            switch (a, b) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (a?, b?): return ascending ? a < b : a > b
            }
        }

        return sorted { lhs, rhs in
            switch column {
            case .status:
                return compare(lhs.statusCode, rhs.statusCode)
            case .method:
                return ascending ? lhs.method < rhs.method : lhs.method > rhs.method
            case .host:
                let (lh, rh) = (lhs.hostAndPath.host.lowercased(), rhs.hostAndPath.host.lowercased())
                return ascending ? lh < rh : lh > rh
            case .path:
                let (lp, rp) = (lhs.hostAndPath.path.lowercased(), rhs.hostAndPath.path.lowercased())
                return ascending ? lp < rp : lp > rp
            case .type:
                let (lt, rt) = (ContentTypeLabel.short(for: lhs.responseHeaders), ContentTypeLabel.short(for: rhs.responseHeaders))
                return ascending ? lt < rt : lt > rt
            case .time:
                return compare(lhs.durationMs, rhs.durationMs)
            }
        }
    }
}

/// One application's slice of the traffic list, keyed by the process name
/// `lsof` resolved at capture time.
struct AppTrafficGroup: Identifiable {
    let id: String
    var displayName: String { id }
    let icon: NSImage?
    let requests: [CapturedRequestDisplay]
}

enum AppGrouping {
    static let unknownKey = "Unknown"

    /// Buckets already-sorted `requests` by `processName`, preserving each
    /// bucket's internal order. Groups are alphabetical by app name, with
    /// "Unknown" always last — stable ordering so groups don't reshuffle
    /// as new traffic streams in, only their contents grow.
    static func grouped(_ requests: [CapturedRequestDisplay]) -> [AppTrafficGroup] {
        var order: [String] = []
        var buckets: [String: [CapturedRequestDisplay]] = [:]
        var pids: [String: UInt32] = [:]

        for request in requests {
            let key = request.processName ?? unknownKey
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(request)
            if pids[key] == nil, let pid = request.processID {
                pids[key] = pid
            }
        }

        let known = order.filter { $0 != unknownKey }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let finalOrder = order.contains(unknownKey) ? known + [unknownKey] : known

        return finalOrder.map { key in
            let icon = pids[key].flatMap { NSRunningApplication(processIdentifier: pid_t($0))?.icon }
            return AppTrafficGroup(id: key, icon: icon, requests: buckets[key] ?? [])
        }
    }
}

/// One `Set-Cookie` (response) or `Cookie` (request) entry, flattened for
/// display in the Cookies tab.
struct ParsedCookie: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    /// Remaining `Set-Cookie` attributes (`Path=/; HttpOnly; Secure`), empty
    /// for request-side cookies since the `Cookie` header carries none.
    let attributes: String
    let source: String
}

/// Short type tag for the traffic table's TYPE column ("json", "png", …).
enum ContentTypeLabel {
    static func short(for headers: [(String, String)]) -> String {
        guard let ct = BodyKindDetector.contentType(from: headers)?.lowercased() else { return "—" }
        if ct.contains("json") { return "json" }
        if ct.contains("html") { return "html" }
        if ct.contains("xml") { return "xml" }
        if ct.contains("javascript") || ct.contains("ecmascript") { return "js" }
        if ct.contains("css") { return "css" }
        if ct.hasPrefix("image/") { return String(ct.dropFirst("image/".count)) }
        if ct.hasPrefix("text/") { return "text" }
        return "—"
    }
}

enum CookieParser {
    // Note: `borrowing` doesn't work here — `for...in` over an Array
    // desugars to a consuming `makeIterator()` call under Swift's current
    // ownership model, so a borrowed array parameter can't be iterated this
    // way. Plain by-value (still just a retain, not a deep copy — Array is
    // copy-on-write) is the correct call for this specific case.
    static func parse(requestHeaders: [(String, String)], responseHeaders: [(String, String)]) -> [ParsedCookie] {
        var out: [ParsedCookie] = []
        for (name, value) in responseHeaders where name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            if let cookie = parseSetCookie(value) { out.append(cookie) }
        }
        for (name, value) in requestHeaders where name.caseInsensitiveCompare("Cookie") == .orderedSame {
            out.append(contentsOf: parseCookieHeader(value))
        }
        return out
    }

    private static func parseSetCookie(_ raw: String) -> ParsedCookie? {
        let parts = raw.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, let eq = first.firstIndex(of: "=") else { return nil }
        let name = String(first[..<eq])
        let value = String(first[first.index(after: eq)...])
        let attributes = parts.dropFirst().joined(separator: "; ")
        return ParsedCookie(name: name, value: value, attributes: attributes, source: "Response")
    }

    private static func parseCookieHeader(_ raw: String) -> [ParsedCookie] {
        raw.split(separator: ";").compactMap { pair in
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { return nil }
            let name = String(trimmed[..<eq])
            let value = String(trimmed[trimmed.index(after: eq)...])
            return ParsedCookie(name: name, value: value, attributes: "", source: "Request")
        }
    }
}

/// Builds a runnable `curl` command reproducing a captured request — the
/// "code" toolbar action. Skips headers that only make sense from inside our
/// own proxy loop (Content-Length is recomputed by curl itself).
enum CurlExporter {
    private static let skippedHeaders: Set<String> = ["content-length", "connection"]

    static func command(for request: borrowing CapturedRequestDisplay) -> String {
        var parts = ["curl", "-X", request.method]

        for (name, value) in request.requestHeaders {
            if skippedHeaders.contains(name.lowercased()) { continue }
            parts.append("-H")
            parts.append(shellQuote("\(name): \(value)"))
        }

        if let base64 = request.requestBodyBase64,
           let data = Data(base64Encoded: base64),
           let text = String(data: data, encoding: .utf8) {
            parts.append("--data-raw")
            parts.append(shellQuote(text))
        }

        parts.append(shellQuote(request.url))
        return parts.joined(separator: " ")
    }

    private static func shellQuote(_ s: borrowing String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
