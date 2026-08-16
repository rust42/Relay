import Foundation

struct SimDevice: Identifiable, Sendable, Equatable, Hashable {
    let udid: String
    let name: String
    let runtime: String
    let state: String
    var id: String { udid }
    var isBooted: Bool { state == "Booted" }
}

enum SimulatorControlError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        }
    }
}

/// Thin wrapper around `xcrun simctl` — there's no simulator-control
/// framework for third-party apps, so this is the same interface Xcode's
/// own device management uses under the hood.
enum SimulatorControl {
    /// All available devices with a real runtime (skips watchOS-only rows
    /// simctl reports with no devices, and unavailable runtimes).
    static func listDevices() async -> [SimDevice] {
        guard let output = try? await run(["list", "devices", "available", "--json"]),
              let data = output.data(using: .utf8) else { return [] }

        struct ListOutput: Decodable {
            struct Device: Decodable {
                let udid: String
                let name: String
                let state: String
                let isAvailable: Bool?
            }
            let devices: [String: [Device]]
        }

        guard let parsed = try? JSONDecoder().decode(ListOutput.self, from: data) else { return [] }

        var result: [SimDevice] = []
        for (runtimeID, devices) in parsed.devices {
            // Runtime IDs look like "com.apple.CoreSimulator.SimRuntime.iOS-17-2".
            let runtimeName = runtimeID
                .components(separatedBy: ".SimRuntime.").last?
                .replacingOccurrences(of: "-", with: ".")
                .replacingFirstDotWithSpace() ?? runtimeID

            for device in devices where device.isAvailable != false {
                result.append(SimDevice(udid: device.udid, name: device.name, runtime: runtimeName, state: device.state))
            }
        }
        return result.sorted { ($0.isBooted ? 0 : 1, $0.name) < ($1.isBooted ? 0 : 1, $1.name) }
    }

    static func openURL(_ urlString: String, on udid: String) async throws {
        _ = try await run(["openurl", udid, urlString])
    }

    static func resetPrivacy(on udid: String) async throws {
        _ = try await run(["privacy", udid, "reset", "all"])
    }

    static func setAppearance(dark: Bool, on udid: String) async throws {
        _ = try await run(["ui", udid, "appearance", dark ? "dark" : "light"])
    }

    /// Deletes the contents of Safari's WebKit cache directories inside its
    /// data container. There's no dedicated `simctl` subcommand for this —
    /// this is the same trick real device wipe scripts use — so it's a
    /// container lookup plus a couple of directory clears rather than one
    /// clean command.
    static func clearSafariCache(on udid: String) async throws {
        let container = try await run(["get_app_container", udid, "com.apple.mobilesafari", "data"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !container.isEmpty else {
            throw SimulatorControlError.commandFailed("Could not locate Safari's data container — is the simulator booted?")
        }

        let fm = FileManager.default
        for subpath in ["Library/Caches", "Library/WebKit"] {
            let dir = URL(fileURLWithPath: container).appendingPathComponent(subpath)
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Installs and trusts our root CA in this simulator's own trust
    /// store — separate from the host Mac's keychain, so this is required
    /// even if the CA is already trusted system-wide. `simctl keychain
    /// add-root-cert` handles both the install and the trust step in one
    /// call (no manual Settings-app profile dance needed since Xcode 11).
    static func installRootCA(pemPath: String, on udid: String) async throws {
        _ = try await run(["keychain", udid, "add-root-cert", pemPath])
    }

    @discardableResult
    fileprivate static func run(_ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl"] + arguments

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    let message = err.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: SimulatorControlError.commandFailed(
                        message.isEmpty ? "simctl \(arguments.joined(separator: " ")) failed" : message
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private extension String {
    /// "17.2" -> "17.2" is fine, but the raw runtime id gives us
    /// "iOS.17.2" after the dash->dot pass above; turn the first dot after
    /// the platform name into a space so it reads "iOS 17.2".
    func replacingFirstDotWithSpace() -> String {
        guard let range = self.range(of: ".") else { return self }
        return self.replacingCharacters(in: range, with: " ")
    }
}

// MARK: - Live log streaming

struct SimLogLine: Identifiable, Sendable {
    let id = UUID()
    let timestamp: String
    let level: SimLogLevel
    let process: String
    let message: String
}

enum SimLogLevel: String, Sendable {
    case error = "ERROR"
    case warn = "WARN"
    case info = "INFO"
    case debug = "DEBUG"

    /// `simctl log stream --style compact` prefixes each line with a
    /// single letter: D/I/E/F for Debug/Info/Error/Fault, plus A for
    /// "Activity" trace events interleaved into the same stream.
    init(compactLetter: Substring) {
        switch compactLetter {
        case "E", "F": self = .error
        case "D": self = .debug
        case "A", "I": self = .info
        default: self = .info
        }
    }
}

/// Streams `simctl spawn <device> log stream` line-by-line. This is a
/// genuinely long-running child process (not a one-shot `run()` call above),
/// so it gets its own lifecycle: start/stop tied to which device the Tools
/// view has selected.
@MainActor
final class SimulatorLogStreamer: ObservableObject {
    @Published private(set) var lines: [SimLogLine] = []
    @Published private(set) var isStreaming = false

    private var process: Process?
    private var readTask: Task<Void, Never>?
    private let maxLines = 500

    func start(udid: String) {
        stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", udid, "log", "stream", "--style", "compact", "--level", "info"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // discard simctl's own stderr chatter (e.g. getpwuid_r warnings)

        self.process = process
        lines = []

        do {
            try process.run()
        } catch {
            self.process = nil
            return
        }
        isStreaming = true

        let handle = pipe.fileHandleForReading
        readTask = Task.detached { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    guard let self else { return }
                    guard let parsed = Self.parseLine(line) else { continue }
                    await MainActor.run {
                        self.lines.append(parsed)
                        if self.lines.count > self.maxLines {
                            self.lines.removeFirst(self.lines.count - self.maxLines)
                        }
                    }
                }
            } catch {
                // Stream ended (process terminated, pipe closed) — nothing
                // to recover from, just stop reading.
            }
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
        isStreaming = false
    }

    /// Best-effort parse of one `--style compact` line:
    /// `2026-08-13 22:41:54.038 I  process[pid:tid] [subsystem] message`.
    /// Lines that don't match this shape (simctl's own banner, truncated
    /// output) are dropped rather than shown malformed.
    private nonisolated static func parseLine(_ raw: String) -> SimLogLine? {
        let parts = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4 else { return nil }
        let timestamp = "\(parts[0]) \(parts[1])"
        let level = SimLogLevel(compactLetter: parts[2])

        let rest = parts[3]
        guard let bracket = rest.firstIndex(of: "[") else {
            return SimLogLine(timestamp: timestamp, level: level, process: "", message: String(rest))
        }
        let process = rest[rest.startIndex..<bracket].trimmingCharacters(in: .whitespaces)
        let afterProcess = rest[bracket...]
        guard let closeBracket = afterProcess.firstIndex(of: "]") else {
            return SimLogLine(timestamp: timestamp, level: level, process: process, message: String(rest))
        }
        let message = afterProcess[afterProcess.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)
        return SimLogLine(timestamp: timestamp, level: level, process: process, message: message.isEmpty ? String(rest) : message)
    }
}
