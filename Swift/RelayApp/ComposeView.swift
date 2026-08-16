import SwiftUI

/// Editable request state for the Compose/Resend tool. Distinct from
/// `CapturedRequestDisplay` since this one's meant to be mutated in a form,
/// not just displayed.
struct ComposeDraft {
    var method: String = "GET"
    var urlString: String = ""
    var headers: [ComposeHeader] = []
    var body: String = ""

    init() {}

    /// Pre-fills from a captured request — the "Resend" path.
    init(resending request: CapturedRequestDisplay) {
        method = request.method
        urlString = request.url
        headers = request.requestHeaders.map { ComposeHeader(name: $0.0, value: $0.1) }
        if let base64 = request.requestBodyBase64,
           let data = Data(base64Encoded: base64),
           let text = String(data: data, encoding: .utf8) {
            body = text
        }
    }
}

struct ComposeHeader: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

private enum ComposeResult {
    case idle
    case sending
    case success(status: Int, headers: [(String, String)], body: String, seconds: Double)
    case failure(String)
}

/// A Postman-lite: build a request from scratch, or open pre-filled from a
/// captured one ("Resend"), edit it, and fire it. Sent directly via
/// `URLSession` — not routed back through our own proxy — so this exercises
/// the real network exactly as any other client would, and works whether or
/// not capture is currently running. Doesn't appear in the traffic list,
/// since it deliberately bypasses the proxy engine entirely.
///
/// Only HTTPS (and local/loopback HTTP, which macOS's default App
/// Transport Security exceptions generally allow) will succeed — arbitrary
/// plain-HTTP targets need an ATS exception this project doesn't carry.
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var result: ComposeResult = .idle

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            HStack(spacing: 0) {
                requestEditor
                    .frame(width: 380)

                Divider().overlay(Theme.hairline)

                responseView
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 780, height: 620)
        .background(Theme.bg)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(Theme.accentGradient)
            Text("Compose")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(GlassIconButtonStyle())
                .frame(width: 60, height: 28)
        }
        .padding(14)
    }

    private var requestEditor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Picker("", selection: $draft.method) {
                        ForEach(methods, id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    TextField("https://example.com/path", text: $draft.urlString)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                headersEditor

                VStack(alignment: .leading, spacing: 4) {
                    Text("BODY").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                    TextEditor(text: $draft.body)
                        .font(.system(size: 11.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 160)
                        .padding(8)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
                }

                Button {
                    send()
                } label: {
                    Label(isSending ? "Sending…" : "Send", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassButtonStyle(prominent: true, tint: Theme.accent))
                .disabled(draft.urlString.isEmpty || isSending)
            }
            .padding(14)
        }
        .scrollIndicators(.hidden)
    }

    private var isSending: Bool {
        if case .sending = result { return true }
        return false
    }

    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("HEADERS").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    draft.headers.append(ComposeHeader(name: "", value: ""))
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(GlassIconButtonStyle())
                .frame(width: 22, height: 22)
            }

            ForEach($draft.headers) { $header in
                HStack(spacing: 6) {
                    TextField("Name", text: $header.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    TextField("Value", text: $header.value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    Button {
                        draft.headers.removeAll { $0.id == header.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var responseView: some View {
        switch result {
        case .idle:
            emptyState(icon: "paperplane", text: "Send a request to see the response here.")
        case .sending:
            emptyState(icon: "hourglass", text: "Waiting…")
        case .failure(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label("Request failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.statusColor(500))
                Text(message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .success(let status, let headers, let body, let seconds):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Chip(text: "\(status)", color: Theme.statusColor(status))
                        Text("\(Int(seconds * 1000))ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    if !headers.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(headers.enumerated()), id: \.offset) { _, pair in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(pair.0).foregroundStyle(Theme.accent3)
                                    Text(pair.1).foregroundStyle(Theme.textSecondary)
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                            }
                        }
                    }

                    Text(body)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Theme.textTertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func send() {
        guard let url = URL(string: draft.urlString) else {
            result = .failure("Not a valid URL.")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = draft.method
        for header in draft.headers where !header.name.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        if !draft.body.isEmpty, draft.method != "GET", draft.method != "HEAD" {
            request.httpBody = draft.body.data(using: .utf8)
        }

        result = .sending
        let started = Date()
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let seconds = Date().timeIntervalSince(started)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { result = .failure("Response wasn't HTTP.") }
                    return
                }
                let headerPairs: [(String, String)] = http.allHeaderFields.compactMap { key, value in
                    guard let name = key as? String else { return nil }
                    return (name, "\(value)")
                }.sorted { $0.0 < $1.0 }
                let bodyText = String(data: data, encoding: .utf8) ?? "\(data.count) bytes of binary data"
                await MainActor.run {
                    result = .success(status: http.statusCode, headers: headerPairs, body: bodyText, seconds: seconds)
                }
            } catch {
                await MainActor.run { result = .failure(error.localizedDescription) }
            }
        }
    }
}
