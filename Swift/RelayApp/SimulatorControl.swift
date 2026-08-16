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

// MARK: - Device lifecycle

extension SimulatorControl {
    static func boot(udid: String) async throws { _ = try await run(["boot", udid]) }
    static func shutdown(udid: String) async throws { _ = try await run(["shutdown", udid]) }
    static func erase(udid: String) async throws { _ = try await run(["erase", udid]) }
    static func deleteDevice(udid: String) async throws { _ = try await run(["delete", udid]) }

    @discardableResult
    static func cloneDevice(udid: String, newName: String) async throws -> String {
        try await run(["clone", udid, newName]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func createDevice(name: String, deviceTypeID: String, runtimeID: String) async throws -> String {
        try await run(["create", name, deviceTypeID, runtimeID]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct SimDeviceType: Identifiable, Sendable, Hashable {
        let id: String
        let name: String
    }

    struct SimRuntime: Identifiable, Sendable, Hashable {
        let id: String
        let name: String
        let platform: String
    }

    static func listDeviceTypes() async -> [SimDeviceType] {
        guard let output = try? await run(["list", "devicetypes", "--json"]),
              let data = output.data(using: .utf8) else { return [] }
        struct Out: Decodable {
            struct DT: Decodable { let identifier: String; let name: String }
            let devicetypes: [DT]
        }
        guard let parsed = try? JSONDecoder().decode(Out.self, from: data) else { return [] }
        return parsed.devicetypes.map { SimDeviceType(id: $0.identifier, name: $0.name) }
    }

    static func listRuntimes() async -> [SimRuntime] {
        guard let output = try? await run(["list", "runtimes", "--json"]),
              let data = output.data(using: .utf8) else { return [] }
        struct Out: Decodable {
            struct RT: Decodable { let identifier: String; let name: String; let platform: String; let isAvailable: Bool? }
            let runtimes: [RT]
        }
        guard let parsed = try? JSONDecoder().decode(Out.self, from: data) else { return [] }
        return parsed.runtimes.filter { $0.isAvailable != false }.map { SimRuntime(id: $0.identifier, name: $0.name, platform: $0.platform) }
    }
}

// MARK: - App management

extension SimulatorControl {
    struct SimApp: Identifiable, Sendable, Hashable {
        let bundleID: String
        let displayName: String
        let isSystem: Bool
        var id: String { bundleID }
    }

    static func installApp(path: String, udid: String) async throws { _ = try await run(["install", udid, path]) }
    static func uninstallApp(bundleID: String, udid: String) async throws { _ = try await run(["uninstall", udid, bundleID]) }
    static func launchApp(bundleID: String, udid: String) async throws { _ = try await run(["launch", udid, bundleID]) }
    static func terminateApp(bundleID: String, udid: String) async throws { _ = try await run(["terminate", udid, bundleID]) }

    /// `simctl listapps` prints old-style (OpenStep) plist text, not JSON —
    /// `PropertyListSerialization` reads that format natively.
    static func listApps(udid: String) async -> [SimApp] {
        guard let output = try? await run(["listapps", udid]),
              let data = output.data(using: .utf8) else { return [] }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: [String: Any]] else { return [] }
        return plist.compactMap { bundleID, info in
            let displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? bundleID
            let type = (info["ApplicationType"] as? String) ?? "User"
            return SimApp(bundleID: bundleID, displayName: displayName, isSystem: type != "User")
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    enum ContainerKind: String { case app, data, groups }

    static func appContainerPath(bundleID: String, kind: ContainerKind, udid: String) async throws -> String {
        try await run(["get_app_container", udid, bundleID, kind.rawValue]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Granular privacy

extension SimulatorControl {
    enum PrivacyAction: String, CaseIterable, Identifiable {
        case grant, revoke, reset
        var id: String { rawValue }
    }

    enum PrivacyService: String, CaseIterable, Identifiable {
        case all
        case calendar, contacts, contactsLimited = "contacts-limited"
        case location, locationAlways = "location-always"
        case photos, photosAdd = "photos-add", mediaLibrary = "media-library"
        case microphone, camera, motion, reminders
        case bluetooth = "bluetooth-peripheral"
        case speechRecognition = "speech-recognition"
        case faceID = "face-id"
        case homeKit = "home-kit"
        case siri

        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All Services"
            case .contactsLimited: return "Contacts (Limited)"
            case .locationAlways: return "Location (Always)"
            case .photosAdd: return "Photos (Add Only)"
            case .mediaLibrary: return "Media Library"
            case .speechRecognition: return "Speech Recognition"
            case .faceID: return "Face ID"
            case .homeKit: return "HomeKit"
            case .bluetooth: return "Bluetooth"
            default: return rawValue.capitalized
            }
        }
    }

    /// `grant`/`revoke` require a bundle id; `reset` accepts an optional one
    /// (omit to reset for every installed app).
    static func setPrivacy(_ action: PrivacyAction, service: PrivacyService, bundleID: String?, udid: String) async throws {
        var args = ["privacy", udid, action.rawValue, service.rawValue]
        if let bundleID, !bundleID.isEmpty { args.append(bundleID) }
        _ = try await run(args)
    }
}

// MARK: - Status bar overrides

extension SimulatorControl {
    static func overrideStatusBar(
        udid: String,
        time: String? = nil,
        batteryLevel: Int? = nil,
        batteryState: String? = nil,
        cellularBars: Int? = nil,
        wifiBars: Int? = nil
    ) async throws {
        var args = ["status_bar", udid, "override"]
        if let time, !time.isEmpty { args += ["--time", time] }
        if let batteryLevel { args += ["--batteryLevel", "\(batteryLevel)"] }
        if let batteryState { args += ["--batteryState", batteryState] }
        if let cellularBars { args += ["--cellularMode", "active", "--cellularBars", "\(cellularBars)"] }
        if let wifiBars { args += ["--wifiMode", "active", "--wifiBars", "\(wifiBars)"] }
        guard args.count > 3 else { return }
        _ = try await run(args)
    }

    static func clearStatusBarOverride(udid: String) async throws {
        _ = try await run(["status_bar", udid, "clear"])
    }
}

// MARK: - Location simulation

extension SimulatorControl {
    struct LocationPreset: Identifiable, Hashable {
        let name: String
        let lat: Double
        let lon: Double
        var id: String { name }
    }

    static let locationPresets: [LocationPreset] = [
        LocationPreset(name: "San Francisco", lat: 37.7749, lon: -122.4194),
        LocationPreset(name: "New York", lat: 40.7128, lon: -74.0060),
        LocationPreset(name: "London", lat: 51.5072, lon: -0.1276),
        LocationPreset(name: "Tokyo", lat: 35.6762, lon: 139.6503),
        LocationPreset(name: "Sydney", lat: -33.8688, lon: 151.2093),
        LocationPreset(name: "Null Island", lat: 0, lon: 0),
    ]

    static func setLocation(lat: Double, lon: Double, udid: String) async throws {
        _ = try await run(["location", udid, "set", "\(lat),\(lon)"])
    }

    static func clearLocation(udid: String) async throws {
        _ = try await run(["location", udid, "clear"])
    }
}

// MARK: - Push notifications

extension SimulatorControl {
    /// Writes the payload to a temp `.apns` file since `simctl push` reads
    /// from a file (or stdin) rather than taking the JSON inline.
    static func sendPushNotification(payload: String, bundleID: String, udid: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("relay-push-\(UUID().uuidString).apns")
        try payload.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await run(["push", udid, bundleID, tmp.path])
    }
}

// MARK: - Media library

extension SimulatorControl {
    static func addMedia(paths: [String], udid: String) async throws {
        _ = try await run(["addmedia", udid] + paths)
    }
}

// MARK: - Clipboard sync

extension SimulatorControl {
    static func setClipboard(text: String, udid: String) async throws {
        try await runWithStdin(["pbcopy", udid], stdin: text)
    }

    static func getClipboard(udid: String) async throws -> String {
        try await run(["pbpaste", udid])
    }
}

// MARK: - Screenshot & screen recording

extension SimulatorControl {
    static func screenshot(udid: String, savePath: String) async throws {
        _ = try await run(["io", udid, "screenshot", savePath])
    }

    /// `recordVideo` runs until interrupted — caller owns the `Process` and
    /// stops it (via `stopRecording`) when the user ends the recording.
    static func startRecording(udid: String, savePath: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "recordVideo", savePath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        return process
    }

    static func stopRecording(_ process: Process) {
        process.interrupt()
    }
}

// MARK: - Process helpers

extension SimulatorControl {
    /// Same shape as `run(_:)` but feeds `stdin` text to the child process
    /// instead of capturing stdout — needed for `pbcopy`, which reads the
    /// clipboard contents from standard input.
    fileprivate static func runWithStdin(_ arguments: [String], stdin: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["simctl"] + arguments

            let inPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = inPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: SimulatorControlError.commandFailed(
                        message.isEmpty ? "simctl \(arguments.joined(separator: " ")) failed" : message
                    ))
                }
            }

            do {
                try process.run()
                inPipe.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data())
                try? inPipe.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
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
