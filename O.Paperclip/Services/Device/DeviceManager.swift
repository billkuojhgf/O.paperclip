import AppKit
import Combine
import Darwin
import Foundation
import MapKit



private enum SimulateLocationMode: String {
    case dvt = "developer dvt"
    case legacy = "developer"

    func clearArgs(host: String, port: String) -> [String] {
        switch self {
        case .dvt:
            ["developer", "dvt", "simulate-location", "clear", "--rsd", host, port]
        case .legacy:
            ["developer", "simulate-location", "clear", "--rsd", host, port]
        }
    }

    func setArgs(host: String, port: String, latitude: Double, longitude: Double) -> [String] {
        let lat = String(format: AppConstants.Formatting.coordinatePrecision, latitude)
        let lon = String(format: AppConstants.Formatting.coordinatePrecision, longitude)
        switch self {
        case .dvt:
            return ["developer", "dvt", "simulate-location", "set", "--rsd", host, port, "--", lat, lon]
        case .legacy:
            return ["developer", "simulate-location", "set", "--rsd", host, port, "--", lat, lon]
        }
    }
}

private enum TunnelTransport: String, CaseIterable {
    case tcp
    case quic
}

private enum TunnelConnectionType: String {
    case usb
    case wifi
}

private final class LockedStringBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text += chunk
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

private final class LockedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, toStdErr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if toStdErr {
            stderr.append(data)
        } else {
            stdout.append(data)
        }
        lock.unlock()
    }

    func strings() -> (stdout: String, stderr: String) {
        lock.lock()
        defer { lock.unlock() }
        return (
            String(data: stdout, encoding: .utf8) ?? "",
            String(data: stderr, encoding: .utf8) ?? ""
        )
    }
}

enum PrivilegedTunnelPIDParser {
    static func parse(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int(trimmed), pid > 0 else { return nil }
        return pid
    }
}

enum USBMuxConnectionTypePolicy {
    static func isUSB(_ connectionType: String?) -> Bool {
        connectionType?.caseInsensitiveCompare("USB") == .orderedSame
    }
}

enum TunnelCommandPolicy {
    static func arguments(connectionType: String, transport: String, udid: String?) -> [String] {
        if connectionType.caseInsensitiveCompare("usb") == .orderedSame {
            return ["lockdown", "start-tunnel", "--script-mode"]
                + (udid.map { ["--udid", $0] } ?? [])
        }
        return [
            "remote", "start-tunnel",
            "--connection-type", connectionType,
            "--script-mode",
            "-p", transport
        ] + (udid.map { ["--udid", $0] } ?? [])
    }
}

enum PrivilegedTunnelAttemptIdentity {
    static let directoryPrefix = "attempt-"

    static func directoryName(identifier: UUID = UUID()) -> String {
        directoryPrefix + identifier.uuidString.lowercased()
    }
}

struct ConnectionAttemptState {
    private(set) var generation: UInt64 = 0
    private(set) var isInFlight = false

    mutating func begin() -> UInt64? {
        guard !isInFlight else { return nil }
        generation &+= 1
        isInFlight = true
        return generation
    }

    mutating func invalidate() -> UInt64 {
        generation &+= 1
        isInFlight = false
        return generation
    }

    mutating func finish(_ finishedGeneration: UInt64) {
        guard generation == finishedGeneration else { return }
        isInFlight = false
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        generation == candidate
    }
}

enum DeviceLogRedactor {
    private static let redactedEndpoint = "[RSD 已遮罩]"
    private static let redactedHost = "[RSD_HOST]"
    private static let redactedPort = "[RSD_PORT]"

    static func maskedIdentifier(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed.isEmpty ? "[未提供]" : trimmed }
        return "\(trimmed.prefix(4))...\(trimmed.suffix(4))"
    }

    static func maskedEndpoint(host: String, port: String) -> String {
        guard !host.isEmpty, !port.isEmpty else { return redactedEndpoint }
        return redactedEndpoint
    }

    static func sanitizedCommandString(_ args: [String]) -> String {
        var result: [String] = []
        var index = 0

        while index < args.count {
            let arg = args[index]

            if arg == "--udid", index + 1 < args.count {
                result.append(arg)
                result.append(maskedIdentifier(args[index + 1]))
                index += 2
                continue
            }

            if arg == "--rsd", index + 2 < args.count {
                result.append(arg)
                result.append(redactedHost)
                result.append(redactedPort)
                index += 3
                continue
            }

            if arg == "--", index + 2 < args.count,
               let latitude = Double(args[index + 1]),
               let longitude = Double(args[index + 2]),
               looksLikeCoordinatePair(latitude: latitude, longitude: longitude) {
                result.append(arg)
                result.append(String(format: "%.4f", latitude))
                result.append(String(format: "%.4f", longitude))
                index += 3
                continue
            }

            result.append(arg)
            index += 1
        }

        return sanitizedMessage(result.joined(separator: " "))
    }

    static func sanitizedMessage(_ text: String) -> String {
        var value = text
        value = replaceMatches(
            in: value,
            pattern: #"(UDID\s*)([A-Fa-f0-9-]{8,})"#,
            options: [.caseInsensitive]
        ) { match, source in
            let prefix = source.substring(with: match.range(at: 1))
            let identifier = source.substring(with: match.range(at: 2))
            return prefix + maskedIdentifier(identifier)
        }
        value = replaceMatches(
            in: value,
            pattern: #"--udid\s+([^\s]+)"#
        ) { match, source in
            "--udid \(maskedIdentifier(source.substring(with: match.range(at: 1))))"
        }
        value = replaceMatches(
            in: value,
            pattern: #"--rsd\s+([^\s]+)\s+(\d+)"#
        ) { _, _ in
            "--rsd \(redactedHost) \(redactedPort)"
        }
        value = replaceMatches(
            in: value,
            pattern: #"((?:RSD|rsd)[^\n:：]*[:：]\s*)([^\s]+):(\d+)"#
        ) { match, source in
            let prefix = source.substring(with: match.range(at: 1))
            return prefix + redactedEndpoint
        }
        value = replaceMatches(
            in: value,
            pattern: #"(Wi[‑-]?Fi:\s*)([^\)\s]+)"#
        ) { match, source in
            let prefix = source.substring(with: match.range(at: 1))
            let identifier = source.substring(with: match.range(at: 2))
            return prefix + maskedIdentifier(identifier)
        }
        value = replaceMatches(
            in: value,
            pattern: #"((?:localhost|(?:\d{1,3}\.){3}\d{1,3}|[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)):(\d{2,5})"#
        ) { _, _ in
            redactedEndpoint
        }
        value = replaceMatches(
            in: value,
            pattern: #"(-?\d{1,3}\.\d{4,})\s*,\s*(-?\d{1,3}\.\d{4,})"#
        ) { match, source in
            let latitude = Double(source.substring(with: match.range(at: 1)))
            let longitude = Double(source.substring(with: match.range(at: 2)))
            guard let latitude, let longitude,
                  looksLikeCoordinatePair(latitude: latitude, longitude: longitude) else {
                return source.substring(with: match.range)
            }
            return String(format: "%.4f, %.4f", latitude, longitude)
        }
        value = replaceMatches(
            in: value,
            pattern: #"--\s+(-?\d{1,3}\.\d{4,})\s+(-?\d{1,3}\.\d{4,})"#
        ) { match, source in
            let latitude = Double(source.substring(with: match.range(at: 1)))
            let longitude = Double(source.substring(with: match.range(at: 2)))
            guard let latitude, let longitude,
                  looksLikeCoordinatePair(latitude: latitude, longitude: longitude) else {
                return source.substring(with: match.range)
            }
            return String(format: "-- %.4f %.4f", latitude, longitude)
        }
        value = replaceMatches(
            in: value,
            pattern: #"(lat(?:itude)?=)(-?\d{1,3}\.\d{4,})"#,
            options: [.caseInsensitive]
        ) { match, source in
            let prefix = source.substring(with: match.range(at: 1))
            let value = Double(source.substring(with: match.range(at: 2))) ?? 0
            return prefix + String(format: "%.4f", value)
        }
        value = replaceMatches(
            in: value,
            pattern: #"(lon(?:gitude)?=)(-?\d{1,3}\.\d{4,})"#,
            options: [.caseInsensitive]
        ) { match, source in
            let prefix = source.substring(with: match.range(at: 1))
            let value = Double(source.substring(with: match.range(at: 2))) ?? 0
            return prefix + String(format: "%.4f", value)
        }
        return value
    }

    private static func looksLikeCoordinatePair(latitude: Double, longitude: Double) -> Bool {
        abs(latitude) <= 90 && abs(longitude) <= 180
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        replacement: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: replacement(match, source))
        }
        return mutable as String
    }
}

final class RotatingRuntimeLogStore: @unchecked Sendable {
    let logURL: URL
    let backupURL: URL
    let maxBytes: UInt64
    private let fileManager: FileManager

    init(logURL: URL, maxBytes: UInt64 = 256 * 1024, fileManager: FileManager = .default) {
        self.logURL = logURL
        self.backupURL = logURL.deletingLastPathComponent().appendingPathComponent(logURL.lastPathComponent + ".1")
        self.maxBytes = maxBytes
        self.fileManager = fileManager
    }

    func appendLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        rotateIfNeeded(incomingBytes: UInt64(data.count))

        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: data)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? (line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    private func rotateIfNeeded(incomingBytes: UInt64) {
        let currentSize = (try? fileManager.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard currentSize + incomingBytes > maxBytes else { return }

        try? fileManager.removeItem(at: backupURL)
        if fileManager.fileExists(atPath: logURL.path) {
            try? fileManager.moveItem(at: logURL, to: backupURL)
        }
    }
}

private struct PrivilegedTunnelFiles {
    let directoryURL: URL
    let logURL: URL
    let pidURL: URL
    let wrapperPIDURL: URL
    let stopURL: URL
    let scriptURL: URL

    static var rootDirectoryURL: URL {
        DiagnosticsPaths.directoryURL(named: "PrivilegedTunnel")
    }

    static func makeUnique() -> Self {
        files(in: rootDirectoryURL.appendingPathComponent(
            PrivilegedTunnelAttemptIdentity.directoryName(),
            isDirectory: true
        ))
    }

    static func files(in directoryURL: URL) -> Self {
        return PrivilegedTunnelFiles(
            directoryURL: directoryURL,
            logURL: directoryURL.appendingPathComponent("tunnel.log"),
            pidURL: directoryURL.appendingPathComponent("child.pid"),
            wrapperPIDURL: directoryURL.appendingPathComponent("wrapper.pid"),
            stopURL: directoryURL.appendingPathComponent("stop"),
            scriptURL: directoryURL.appendingPathComponent("wrapper.sh")
        )
    }

    static func legacy() -> Self {
        let directoryURL = rootDirectoryURL
        return PrivilegedTunnelFiles(
            directoryURL: directoryURL,
            logURL: directoryURL.appendingPathComponent("opaperclip_tunnel.log"),
            pidURL: directoryURL.appendingPathComponent("opaperclip_tunnel.pid"),
            wrapperPIDURL: directoryURL.appendingPathComponent("opaperclip_tunnel_wrapper.pid"),
            stopURL: directoryURL.appendingPathComponent("opaperclip_tunnel.stop"),
            scriptURL: directoryURL.appendingPathComponent("opaperclip_tunnel_wrapper.sh")
        )
    }
}

private enum PrivilegedTunnelArtifactPreparer {
    static func prepareReadableArtifacts(
        files: PrivilegedTunnelFiles,
        fileManager: FileManager = .default
    ) {
        for url in [files.logURL, files.pidURL, files.wrapperPIDURL] {
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: Data())
            } else {
                try? Data().write(to: url, options: .atomic)
            }
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }
}

struct TunnelOutputParser {
    nonisolated static func endpoint(in text: String) -> (host: String, port: String)? {
        if let host = firstMatch(text, pattern: "RSD\\s+Address:\\s*([^\\s\\n\\r]+)"),
           let port = firstMatch(text, pattern: "RSD\\s+Port:\\s*(\\d+)") {
            return (host.trimmingCharacters(in: .whitespacesAndNewlines), port)
        }

        if let host = firstMatch(text, pattern: "\"host\"\\s*:\\s*\"([^\"]+)\""),
           let port = firstMatch(text, pattern: "\"port\"\\s*:\\s*(\\d+)") {
            return (host.trimmingCharacters(in: .whitespacesAndNewlines), port)
        }

        let lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let pair = lines.compactMap(scriptModeEndpoint(from:)).last {
            return pair
        }

        if let host = firstMatch(text, pattern: "--rsd\\s+([^\\s]+)\\s+(\\d+)") {
            let all = matches(text, pattern: "--rsd\\s+([^\\s]+)\\s+(\\d+)")
            if let last = all.last, last.count == 2 {
                return (last[0].trimmingCharacters(in: .whitespacesAndNewlines), last[1])
            }
            if let port = firstMatch(text, pattern: "--rsd\\s+[^\\s]+\\s+(\\d+)") {
                return (host.trimmingCharacters(in: .whitespacesAndNewlines), port)
            }
        }

        return nil
    }

    nonisolated static func immediateFailure(in text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fatalMarkers = [
            " error ",
            "error:",
            "exception",
            "traceback",
            "device is not connected",
            "no device connected",
            "requires root privileges",
            "connection refused",
            "timed out",
            "timeout"
        ]
        return lines.last(where: { line in
            let lowered = " " + line.lowercased() + " "
            return fatalMarkers.contains(where: { lowered.contains($0) })
        })
    }

    nonisolated private static func scriptModeEndpoint(from line: String) -> (host: String, port: String)? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let port = Int(parts[1]), port > 0 else { return nil }
        let host = String(parts[0])
        guard host == "localhost" || host.contains(".") || host.contains(":") else { return nil }
        return (host, String(port))
    }

    nonisolated private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let m = r.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        guard m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    nonisolated private static func matches(_ text: String, pattern: String) -> [[String]] {
        guard let r = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        let result = r.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        return result.map { m in
            (1..<m.numberOfRanges).compactMap { idx in
                let rg = m.range(at: idx)
                guard rg.location != NSNotFound else { return nil }
                return ns.substring(with: rg)
            }
        }
    }
}

enum RemoteBrowseOutputParser {
    nonisolated static func identifiers(in raw: String) -> [String] {
        let jsonIdentifiers = identifiersFromJSON(raw)
        if !jsonIdentifiers.isEmpty {
            return jsonIdentifiers
        }

        guard let regex = try? NSRegularExpression(pattern: #"IDENTIFIER:([0-9A-Fa-f\-]+)"#) else {
            return []
        }
        let ns = raw as NSString
        return regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            .compactMap { match -> String? in
                guard match.numberOfRanges > 1 else { return nil }
                let identifier = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return identifier.isEmpty ? nil : identifier
            }
    }

    nonisolated private static func identifiersFromJSON(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }

        if let array = object as? [[String: Any]] {
            return array.compactMap(identifier(from:))
        }

        if let dictionary = object as? [String: Any],
           let array = dictionary["devices"] as? [[String: Any]] {
            return array.compactMap(identifier(from:))
        }

        return []
    }

    nonisolated private static func identifier(from dictionary: [String: Any]) -> String? {
        let rawIdentifier =
            dictionary["identifier"] as? String ??
            dictionary["Identifier"] as? String
        guard let rawIdentifier else { return nil }
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class DeviceManager: ObservableObject, DeviceControlling, @unchecked Sendable {
    @Published private(set) var connectionState: DeviceConnectionState = .disconnected
    @Published private(set) var deviceName: String = "未連接"
    @Published private(set) var lastError: String?
    @Published var manualRsdHost: String = "" {
        didSet { UserDefaults.standard.set(manualRsdHost, forKey: Self.manualRsdHostKey) }
    }
    @Published var manualRsdPort: String = "" {
        didSet { UserDefaults.standard.set(manualRsdPort, forKey: Self.manualRsdPortKey) }
    }
    @Published var tunnelUDID: String = "" {
        didSet { UserDefaults.standard.set(tunnelUDID, forKey: Self.tunnelUDIDKey) }
    }

    @Published var isWirelessMode: Bool = false {
        didSet { UserDefaults.standard.set(isWirelessMode, forKey: Self.wirelessModeKey) }
    }
    @Published private(set) var debugLog: [String] = []

    var isConnected: Bool { connectionState.isConnected }
    var isConnecting: Bool { connectionState.isBusy }
    var connectionStage: String { connectionState.statusText }

    private struct Endpoint {
        let host: String
        let port: String
    }

    private struct USBMuxDevice: Decodable {
        let connectionType: String?
        let deviceClass: String?
        let deviceName: String?
        let identifier: String?
        let uniqueDeviceID: String?
        let productType: String?

        enum CodingKeys: String, CodingKey {
            case connectionType = "ConnectionType"
            case deviceClass = "DeviceClass"
            case deviceName = "DeviceName"
            case identifier = "Identifier"
            case uniqueDeviceID = "UniqueDeviceID"
            case productType = "ProductType"
        }
    }

    private let sendQueue = DispatchQueue(label: "paperclip.gps.sender", qos: .utility)
    private let connectionQueue = DispatchQueue(label: "paperclip.connection", qos: .utility)
    private let connectionLifecycleLock = NSLock()
    private var connectionAttemptState = ConnectionAttemptState()
    private let sendQueueSpecificKey = DispatchSpecificKey<String>()
    private let sendQueueSpecificValue = "paperclip.gps.sender"
    private var inFlight = false
    private var pendingCoordinate: CLLocationCoordinate2D?
    private let dvtStream = DVTLocationStream()

    private var tunnelProcess: Process?
    private var tunnelOutPipe: Pipe?
    private var tunnelErrPipe: Pipe?
    private var rsdEndpoint: Endpoint?
    private var simulateLocationMode: SimulateLocationMode?
    private var autoReconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt: Int = 0
    private var userInitiatedDisconnect = false
    private var expectedDvtStreamExit = false
    private var sentLocationCount: Int = 0
    private var activeTunnelConnectionType: TunnelConnectionType?
    private var activePrivilegedTunnelFiles: PrivilegedTunnelFiles?
    private let runtimeLogStore = RotatingRuntimeLogStore(logURL: DiagnosticsPaths.logFileURL(named: "device-runtime.log"))
    private let runtimeLogQueue = DispatchQueue(label: "paperclip.runtime.log", qos: .utility)
    private static let manualRsdHostKey = "paperclip.connection.manualRsdHost"
    private static let manualRsdPortKey = "paperclip.connection.manualRsdPort"
    private static let tunnelUDIDKey = "paperclip.connection.tunnelUDID"
    private static let wirelessModeKey = "paperclip.connection.wirelessMode"
    private static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        sendQueue.setSpecific(key: sendQueueSpecificKey, value: sendQueueSpecificValue)
        let defaults = UserDefaults.standard
        manualRsdHost = defaults.string(forKey: Self.manualRsdHostKey) ?? ""
        manualRsdPort = defaults.string(forKey: Self.manualRsdPortKey) ?? ""
        tunnelUDID = defaults.string(forKey: Self.tunnelUDIDKey) ?? ""
        isWirelessMode = defaults.bool(forKey: Self.wirelessModeKey)
        connectionQueue.async { [weak self] in
            self?.recoverOrphanedPrivilegedTunnels()
        }
    }

    deinit {
        cancelAutoReconnect()
        stopTunnel()
    }

    private func beginConnectionAttempt() -> UInt64? {
        connectionLifecycleLock.lock()
        defer { connectionLifecycleLock.unlock() }
        return connectionAttemptState.begin()
    }

    @discardableResult
    private func invalidateConnectionAttempt() -> UInt64 {
        connectionLifecycleLock.lock()
        defer { connectionLifecycleLock.unlock() }
        return connectionAttemptState.invalidate()
    }

    private func finishConnectionAttempt(_ generation: UInt64) {
        connectionLifecycleLock.lock()
        defer { connectionLifecycleLock.unlock() }
        connectionAttemptState.finish(generation)
    }

    private func isCurrentConnectionAttempt(_ generation: UInt64) -> Bool {
        connectionLifecycleLock.lock()
        defer { connectionLifecycleLock.unlock() }
        return connectionAttemptState.isCurrent(generation)
    }

    private func currentConnectionGeneration() -> UInt64 {
        connectionLifecycleLock.lock()
        defer { connectionLifecycleLock.unlock() }
        return connectionAttemptState.generation
    }

    private func ensureCurrentConnectionAttempt(_ generation: UInt64) throws {
        guard isCurrentConnectionAttempt(generation) else {
            throw NSError(domain: "DeviceManager.ConnectionAttempt", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "連線流程已取消"
            ])
        }
    }

    private func registerPrivilegedTunnelFiles(
        _ files: PrivilegedTunnelFiles,
        generation: UInt64
    ) -> Bool {
        connectionLifecycleLock.lock()
        defer { connectionLifecycleLock.unlock() }
        guard connectionAttemptState.isCurrent(generation) else { return false }
        activePrivilegedTunnelFiles = files
        return true
    }

    private func takeActivePrivilegedTunnelFiles() -> PrivilegedTunnelFiles? {
        connectionLifecycleLock.lock()
        defer { connectionLifecycleLock.unlock() }
        let files = activePrivilegedTunnelFiles
        activePrivilegedTunnelFiles = nil
        return files
    }

    func connectDevice() {
        userInitiatedDisconnect = false
        connectDeviceInternal(autoTriggered: false, force: true)
    }

    func connectDeviceAsync() async throws {
        connectDevice()
        let timeout = Date().addingTimeInterval(AppConstants.Timeouts.tunnelReady + AppConstants.Timeouts.mountTimeout)
        while Date() < timeout {
            if isConnected { return }
            if connectionState == .failed {
                throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: lastError ?? "裝置連線失敗"
                ])
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw NSError(domain: "DeviceManager", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "裝置連線逾時"
        ])
    }

    private func connectDeviceInternal(autoTriggered: Bool, force: Bool) {
        guard force || !isConnected else { return }
        guard let generation = beginConnectionAttempt() else {
            appendLog("已有連線流程進行中，略過重複請求")
            return
        }
        if !autoTriggered {
            cancelAutoReconnect()
            appendLog("開始連線 Apple 裝置")
            setConnectionState(.connecting(step: "初始化"), deviceName: "連線中…", lastError: nil, generation: generation)
        } else {
            setConnectionState(.connecting(step: "自動重連中"), deviceName: "重新連線中…", lastError: nil, generation: generation)
            appendLog("執行自動重連（第 \(reconnectAttempt) 次）")
        }

        connectionQueue.async {
            defer { self.finishConnectionAttempt(generation) }

            do {
                try self.ensureCurrentConnectionAttempt(generation)
                self.activeTunnelConnectionType = self.isWirelessMode ? .wifi : .usb
                let cmd = try self.resolveCLI()
                self.appendLog("CLI: \(cmd.joined(separator: " "))")
                _ = try self.runWithTimeoutLogged(
                    cmd + ["version"],
                    timeout: AppConstants.Timeouts.pymobiledeviceCheck,
                    step: "檢查 pymobiledevice3"
                )
                try self.ensureCurrentConnectionAttempt(generation)

                if let manual = self.manualEndpointIfValid() {
                    self.setStage("使用手動 RSD", generation: generation)
                    self.rsdEndpoint = manual
                    try self.verifyRsdEndpoint(using: cmd, ep: manual, generation: generation)
                } else {
                    let tunnelUDID = try self.preferredConnectionUDID(using: cmd, generation: generation)
                    try self.ensureCurrentConnectionAttempt(generation)
                    self.setStage("準備建立連線", generation: generation)
                    do {
                        try self.startTunnelAndResolveEndpoint(using: cmd, udid: tunnelUDID, generation: generation)
                    } catch {
                        let err = error.localizedDescription
                        if err.localizedCaseInsensitiveContains("requires root privileges") {
                            self.appendLog("start-tunnel 需要管理員權限，改用提示模式重試")
                            try self.startTunnelWithAdminPrompt(using: cmd, udid: tunnelUDID, generation: generation)
                        }
                        else if self.shouldFallbackToAnyDevice(for: err) {
                            self.appendLog("指定 UDID 連線失敗，改為自動選擇目前已連線裝置重試")
                            try self.startTunnelAndResolveEndpoint(using: cmd, udid: nil, generation: generation)
                        } else if try self.shouldFallbackToUSBTunnel(using: cmd, errorMessage: err) {
                            self.appendLog("Wi‑Fi tunnel 不支援，改用 USB tunnel 重試")
                            self.activeTunnelConnectionType = .usb
                            let usbUDID = try self.preferredTunnelUDID(using: cmd)
                            self.setStage("切換連線方式", generation: generation)
                            try self.startTunnelAndResolveEndpoint(using: cmd, udid: usbUDID, generation: generation)
                        } else {
                            throw error
                        }
                    }

                    guard let ep = self.rsdEndpoint else {
                        throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                            NSLocalizedDescriptionKey: "無法取得 RSD host/port"
                        ])
                    }
                    try self.verifyRsdEndpoint(using: cmd, ep: ep, generation: generation)
                }
                try self.ensureCurrentConnectionAttempt(generation)
                guard let ep = self.rsdEndpoint else {
                    throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "RSD endpoint 在連線完成前遺失，請重試"
                    ])
                }
                let deviceLabel = self.connectedDeviceLabel(using: cmd)

                self.setConnectionState(.connected, deviceName: "\(deviceLabel) (RSD: \(ep.host):\(ep.port))", lastError: nil, generation: generation)
#if DEBUG
                print("✅ Tunnel OK: \(DeviceLogRedactor.maskedEndpoint(host: ep.host, port: ep.port))")
#endif
                self.appendLog("連線完成，模式：\(self.simulateLocationMode?.rawValue ?? "unknown")")
                self.cancelAutoReconnect()
                self.reconnectAttempt = 0
            } catch {
                self.stopTunnel()
                guard self.isCurrentConnectionAttempt(generation) else {
                    self.appendLog("已取消過期的連線流程")
                    return
                }
                let lowered = error.localizedDescription.lowercased()
                self.setConnectionState(.failed, deviceName: "連線失敗", lastError: error.localizedDescription, generation: generation)
#if DEBUG
                print("❌ connectDevice error: \(DeviceLogRedactor.sanitizedMessage(error.localizedDescription))")
#endif
                self.appendLog("連線失敗：\(error.localizedDescription)")
                if autoTriggered || lowered.contains("bad file descriptor") {
                    self.scheduleAutoReconnect(reason: error.localizedDescription)
                }
            }
        }
    }

    private func manualEndpointIfValid() -> Endpoint? {
        let h = manualRsdHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = manualRsdPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !p.isEmpty else { return nil }
        guard Int(p) != nil else { return nil }
        return Endpoint(host: h, port: p)
    }

    private func preferredConnectionUDID(using cmd: [String], generation: UInt64) throws -> String? {
        if isWirelessMode {
            setStage("搜尋可用裝置", generation: generation)
            appendLog("Wi‑Fi 模式：開始搜尋裝置 UDID")
            let requested = effectiveTunnelUDID
            if let requested, !requested.isEmpty {
                appendLog("Wi‑Fi 模式：使用者已指定 UDID \(DeviceLogRedactor.maskedIdentifier(requested))")
                return requested
            }
            appendLog("Wi‑Fi 模式：嘗試從 USB 已連線裝置取得 UDID")
            if let connectedUDID = try preferredActiveDeviceUDID(using: cmd) {
                appendLog("Wi‑Fi 模式：從 USB 裝置取得 UDID \(DeviceLogRedactor.maskedIdentifier(connectedUDID))")
                return connectedUDID
            }
            appendLog("Wi‑Fi 模式：USB 無裝置，改用 Bonjour 探索")
            if let browsedUDID = try browseRemoteDeviceUDID(using: cmd) {
                appendLog("Wi‑Fi 模式：Bonjour 探索成功，UDID \(DeviceLogRedactor.maskedIdentifier(browsedUDID))")
                return browsedUDID
            }
            appendLog("Wi‑Fi 模式：所有探查方式皆無結果，將不帶 UDID 嘗試連線")
            return nil
        }
        return try preferredTunnelUDID(using: cmd)
    }

    private func browseRemoteDeviceUDID(using cmd: [String]) throws -> String? {
        let browseCommand = cmd + ["remote", "browse"]
        appendLog("▶ Bonjour 探索 Wi‑Fi 裝置")
        appendLog("cmd: \(DeviceLogRedactor.sanitizedCommandString(browseCommand))")

        let raw: String
        do {
            raw = try runWithTimeout(browseCommand, timeout: 8)
            appendLog("✓ Bonjour 探索 Wi‑Fi 裝置")
        } catch {
            appendLog("✗ Bonjour 探索 Wi‑Fi 裝置：\(error.localizedDescription)")
            return nil
        }

        let identifiers = RemoteBrowseOutputParser.identifiers(in: raw)
        guard !identifiers.isEmpty else {
            appendLog("Bonjour 探索未找到任何裝置")
            return nil
        }

        appendLog("Bonjour 探索到 \(identifiers.count) 台裝置")
        appendLog("選擇第一台裝置：\(DeviceLogRedactor.maskedIdentifier(identifiers[0]))")
        return identifiers[0]
    }

    private func preferredActiveDeviceUDID(using cmd: [String]) throws -> String? {
        let devices = try listConnectedDevices(using: cmd).filter(isUSBDevice)
        guard !devices.isEmpty else { return nil }

        if let requested = effectiveTunnelUDID,
           let matched = devices.first(where: { matchesDevice($0, requestedUDID: requested) }) {
            return matched.identifier ?? matched.uniqueDeviceID
        }

        return devices.first?.identifier ?? devices.first?.uniqueDeviceID
    }

    private func preferredTunnelUDID(using cmd: [String]) throws -> String? {
        let allDevices = try listConnectedDevices(using: cmd)
        let devices = allDevices.filter(isUSBDevice)
        guard !devices.isEmpty else {
            throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "未偵測到已連線的 iPhone/iPad。請確認裝置已用 USB 接上、已解鎖並信任這台 Mac，且 Finder 或 Xcode 能看到裝置；若你已知 RSD，也可在進階連線直接輸入 host/port。"
            ])
        }

        appendLog("偵測到裝置：" + allDevices.map(deviceDebugLabel(for:)).joined(separator: "、"))

        guard let requested = effectiveTunnelUDID else { return nil }
        if devices.contains(where: { matchesDevice($0, requestedUDID: requested) }) {
            return requested
        }

        appendLog("指定 UDID \(requested) 不在目前裝置列表中，改用自動選擇")
        return nil
    }

    private func verifyRsdEndpoint(using cmd: [String], ep: Endpoint, generation: UInt64) throws {
        try ensureCurrentConnectionAttempt(generation)
        setStage("驗證裝置服務", generation: generation)
        appendLog("RSD endpoint: \(ep.host):\(ep.port)")

        try ensureDeveloperModeEnabledIfSupported(using: cmd, ep: ep)

        _ = try runWithTimeoutLogged(cmd + [
            "mounter", "auto-mount",
            "--rsd", ep.host, ep.port
        ], timeout: AppConstants.Timeouts.mountTimeout, step: "掛載 Developer Disk Image")

        _ = try runWithTimeoutLogged(cmd + [
            "remote", "rsd-info",
            "--rsd", ep.host, ep.port
        ], timeout: AppConstants.Timeouts.rsdInfo, step: "讀取 RSD 資訊")

        try ensureCurrentConnectionAttempt(generation)
        simulateLocationMode = try detectSimulateLocationMode(using: cmd, ep: ep, generation: generation)
        appendLog("simulate-location 使用：\(simulateLocationMode?.rawValue ?? "unknown")")
    }

    private func detectSimulateLocationMode(using cmd: [String], ep: Endpoint, generation: UInt64) throws -> SimulateLocationMode {
        try ensureCurrentConnectionAttempt(generation)
        setStage("偵測 simulate-location 模式", generation: generation)
        do {
            _ = try runWithTimeoutLogged(
                cmd + SimulateLocationMode.dvt.clearArgs(host: ep.host, port: ep.port),
                timeout: AppConstants.Timeouts.rsdInfo,
                step: "嘗試 dvt clear"
            )
            return .dvt
        } catch {
            appendLog("dvt simulate-location 不可用：\(error.localizedDescription)")
        }
        _ = try runWithTimeoutLogged(
            cmd + SimulateLocationMode.legacy.clearArgs(host: ep.host, port: ep.port),
            timeout: AppConstants.Timeouts.rsdInfo,
            step: "嘗試 legacy clear"
        )
        return .legacy
    }

    private func ensureDeveloperModeEnabledIfSupported(using cmd: [String], ep: Endpoint) throws {
        let output: String
        do {
            output = try runWithTimeoutLogged(
                cmd + [
                    "mounter", "query-developer-mode-status",
                    "--rsd", ep.host, ep.port
                ],
                timeout: AppConstants.Timeouts.rsdInfo,
                step: "檢查開發者模式"
            )
        } catch {
            let lowered = error.localizedDescription.lowercased()
            if lowered.contains("message not supported")
                || lowered.contains("unknown command")
                || lowered.contains("unknowncommand") {
                appendLog("開發者模式狀態查詢不支援，略過檢查")
                return
            }
            throw error
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "true" {
            return
        }
        if trimmed == "false" {
            throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "裝置尚未開啟開發者模式。請先到 iPhone/iPad 的「設定 > 隱私權與安全性 > 開發者模式」開啟，並依提示重新啟動裝置後再重試。"
            ])
        }

        appendLog("無法判斷開發者模式狀態，略過強制檢查")
    }

    private var effectiveTunnelUDID: String? {
        let trimmed = tunnelUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var effectiveTunnelConnectionType: TunnelConnectionType {
        activeTunnelConnectionType ?? (isWirelessMode ? .wifi : .usb)
    }

    private var preferredConnectionType: String {
        effectiveTunnelConnectionType.rawValue
    }

    private func shouldFallbackToUSBTunnel(using cmd: [String], errorMessage: String) throws -> Bool {
        guard effectiveTunnelConnectionType == .wifi else { return false }
        let lower = errorMessage.lowercased()
        guard lower.contains("operation not supported by device")
            || lower.contains("no route to host")
            || lower.contains("network is unreachable") else {
            return false
        }
        let devices = try listConnectedDevices(using: cmd)
        return devices.contains(where: isUSBDevice)
    }

    private func shouldFallbackToAnyDevice(for errorMessage: String) -> Bool {
        guard effectiveTunnelUDID != nil else { return false }
        let lower = errorMessage.lowercased()
        return lower.contains("device is not connected")
            || lower.contains("no device connected")
            || lower.contains("usbmux")
    }

    private func listConnectedDevices(using cmd: [String]) throws -> [USBMuxDevice] {
        let args = cmd + ["usbmux", "list"]

        do {
            let raw = try runWithTimeoutLogged(
                args,
                timeout: AppConstants.Timeouts.tunnelReady,
                step: "偵測連線裝置"
            )
            return decodeUSBMuxDevices(from: raw)
        } catch {
            let lowered = error.localizedDescription.lowercased()
            let isTimeout = lowered.contains("command timed out") && lowered.contains("usbmux list")
            guard isTimeout else { throw error }

            appendLog("usbmux list 逾時，1 秒後重試一次")
            Thread.sleep(forTimeInterval: 1.0)

            do {
                let raw = try runWithTimeoutLogged(
                    args,
                    timeout: AppConstants.Timeouts.tunnelReady,
                    step: "重新偵測連線裝置"
                )
                return decodeUSBMuxDevices(from: raw)
            } catch {
                throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "偵測 iPhone/iPad 逾時，無法從 usbmuxd 取得裝置列表。請先確認裝置已解鎖並信任這台 Mac，重新插拔 USB 後再試；若仍失敗，請關閉可能占用裝置的 Finder、Xcode、Apple Configurator，再重新啟動 Mac 與 iPhone。"
                ])
            }
        }
    }

    private func decodeUSBMuxDevices(from raw: String) -> [USBMuxDevice] {
        guard let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([USBMuxDevice].self, from: data)) ?? []
    }

    private func matchesDevice(_ device: USBMuxDevice, requestedUDID: String) -> Bool {
        device.identifier == requestedUDID || device.uniqueDeviceID == requestedUDID
    }

    private func isUSBDevice(_ device: USBMuxDevice) -> Bool {
        USBMuxConnectionTypePolicy.isUSB(device.connectionType)
    }

    private func deviceDebugLabel(for device: USBMuxDevice) -> String {
        let name = device.deviceName ?? device.productType ?? device.deviceClass ?? "Apple Device"
        let transport = device.connectionType?.uppercased() ?? "UNKNOWN"
        let identifier = device.identifier ?? device.uniqueDeviceID ?? "no-id"
        return "\(name) [\(transport)] \(DeviceLogRedactor.maskedIdentifier(identifier))"
    }

    private func resolveConnectedDeviceLabel(using cmd: [String], preferredUDID: String?) throws -> String {
        let devices = try listConnectedDevices(using: cmd)
        guard !devices.isEmpty else {
            return "Apple Device"
        }

        let preferred = preferredUDID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let picked =
            devices.first(where: {
                guard let preferred else { return false }
                return $0.identifier == preferred || $0.uniqueDeviceID == preferred
            }) ??
            devices.first(where: { ($0.connectionType ?? "").uppercased() == "USB" }) ??
            devices.first

        guard let picked else { return "Apple Device" }
        let type = picked.productType ?? picked.deviceClass ?? "Apple Device"
        if let name = picked.deviceName, !name.isEmpty {
            return "\(name) \(type)"
        }
        return type
    }

    private func connectedDeviceLabel(using cmd: [String]) -> String {
        if effectiveTunnelConnectionType == .wifi {
            if let requested = effectiveTunnelUDID {
                return "Apple Device (Wi‑Fi: \(DeviceLogRedactor.maskedIdentifier(requested)))"
            }
            return "Apple Device (Wi‑Fi)"
        }
        return (try? resolveConnectedDeviceLabel(using: cmd, preferredUDID: effectiveTunnelUDID)) ?? "Apple Device"
    }

    private func startTunnelWithAdminPrompt(using cmd: [String], udid: String?, generation: UInt64) throws {
        var failures: [String] = []
        let candidates: [String?] = udid == nil ? [nil] : [udid, nil]

        for candidateUDID in candidates {
            if udid != nil && candidateUDID == nil {
                appendLog("改用目前已連線裝置重試管理員 tunnel")
            }
            var shouldMoveToNextCandidate = false
            for transport in tunnelTransports {
                do {
                    try startTunnelWithAdminPrompt(
                        using: cmd,
                        udid: candidateUDID,
                        transport: transport,
                        generation: generation
                    )
                    return
                } catch {
                    let failure = "\(transport.rawValue): \(error.localizedDescription)"
                    failures.append(failure)
                    appendLog("管理員 tunnel 失敗（\(failure)）")
                    stopPrivilegedTunnelProcessIfNeeded()
                    if candidateUDID != nil && shouldFallbackToAnyDevice(for: error.localizedDescription) {
                        shouldMoveToNextCandidate = true
                        break
                    }
                }
            }
            if shouldMoveToNextCandidate {
                continue
            }
        }
        throw NSError(domain: "DeviceManager", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "已要求管理員權限，但所有 tunnel 協定都失敗。\n" + failures.joined(separator: "\n")
        ])
    }

    private func startTunnelWithAdminPrompt(
        using cmd: [String],
        udid: String?,
        transport: TunnelTransport,
        generation: UInt64
    ) throws {
        try ensureCurrentConnectionAttempt(generation)
        setStage("請求系統授權", generation: generation)
        let full = cmd + startTunnelArguments(transport: transport, udid: udid)
        let files = PrivilegedTunnelFiles.makeUnique()
        let scriptURL = try preparePrivilegedTunnelWrapperScript(for: full, files: files)
        guard registerPrivilegedTunnelFiles(files, generation: generation) else {
            cleanupPrivilegedTunnelArtifacts(files: files)
            try ensureCurrentConnectionAttempt(generation)
            return
        }
        let shellCmd = privilegedTunnelLaunchCommand(for: scriptURL)

        if runWithNonInteractiveSudo(shellCmd) {
            appendLog("以 sudo -n 啟動管理員 tunnel")
        } else {
            try runPrivilegedTunnelWithAuthorization(scriptURL: scriptURL)
            appendLog("以系統授權視窗啟動管理員 tunnel (\(transport.rawValue))")
        }
        appendLog("管理員 tunnel 已啟動，等待 RSD 位址 (\(transport.rawValue))")

        let deadline = Date().addingTimeInterval(AppConstants.Timeouts.tunnelReady)
        while Date() < deadline {
            try ensureCurrentConnectionAttempt(generation)
            if let text = try? String(contentsOf: files.logURL, encoding: .utf8) {
                if let pair = TunnelOutputParser.endpoint(in: text) {
                    rsdEndpoint = Endpoint(host: pair.host, port: pair.port)
                    let ep = rsdEndpoint!
                    appendLog("管理員 tunnel RSD：\(ep.host):\(ep.port)")
                    return
                }
                if let failure = TunnelOutputParser.immediateFailure(in: text) {
                    throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: DeviceLogRedactor.sanitizedMessage(failure)
                    ])
                }
            }
            Thread.sleep(forTimeInterval: AppConstants.Timeouts.pollInterval)
        }

        let logText = (try? String(contentsOf: files.logURL, encoding: .utf8))
            .map(DeviceLogRedactor.sanitizedMessage) ?? ""
        throw NSError(domain: "DeviceManager", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "已要求管理員權限，但仍未拿到 RSD 位址。\n\(logText)"
        ])
    }

    private func startTunnelArguments(transport: TunnelTransport, udid: String?) -> [String] {
        TunnelCommandPolicy.arguments(
            connectionType: preferredConnectionType,
            transport: transport.rawValue,
            udid: udid
        )
    }

    private var tunnelTransports: [TunnelTransport] {
        effectiveTunnelConnectionType == .usb ? [.tcp] : TunnelTransport.allCases
    }

    private func shellEscape(_ s: String) -> String {
        if s.isEmpty { return "''" }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func ensurePrivilegedTunnelDirectory(for files: PrivilegedTunnelFiles) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: files.directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: files.directoryURL.path
        )
    }

    private func cleanupPrivilegedTunnelArtifacts(files: PrivilegedTunnelFiles) {
        try? FileManager.default.removeItem(at: files.directoryURL)
    }

    private func preparePrivilegedTunnelWrapperScript(
        for command: [String],
        files: PrivilegedTunnelFiles
    ) throws -> URL {
        try ensurePrivilegedTunnelDirectory(for: files)
        PrivilegedTunnelArtifactPreparer.prepareReadableArtifacts(files: files)

        let commandLine = command.map(shellEscape).joined(separator: " ")
        let script = """
        #!/bin/sh
        umask 077
        LOG=\(shellEscape(files.logURL.path))
        PIDFILE=\(shellEscape(files.pidURL.path))
        WRAPPERPIDFILE=\(shellEscape(files.wrapperPIDURL.path))
        STOPFILE=\(shellEscape(files.stopURL.path))
        echo "$$" > "$WRAPPERPIDFILE"
        : > "$LOG"
        if [ -f "$STOPFILE" ]; then
          rm -f "$PIDFILE" "$WRAPPERPIDFILE"
          exit 0
        fi
        \(commandLine) >> "$LOG" 2>&1 &
        CHILD=$!
        echo "$CHILD" > "$PIDFILE"
        (
          while kill -0 "$CHILD" >/dev/null 2>&1; do
            if [ -f "$STOPFILE" ]; then
              kill "$CHILD" >/dev/null 2>&1 || true
              sleep 1
              if kill -0 "$CHILD" >/dev/null 2>&1; then
                kill -9 "$CHILD" >/dev/null 2>&1 || true
              fi
              exit 0
            fi
            sleep 0.2
          done
        ) &
        WATCHER=$!
        wait "$CHILD" >/dev/null 2>&1 || true
        kill "$WATCHER" >/dev/null 2>&1 || true
        wait "$WATCHER" >/dev/null 2>&1 || true
        if [ -f "$STOPFILE" ]; then
          rm -f "$STOPFILE"
        fi
        rm -f "$PIDFILE" "$WRAPPERPIDFILE"
        """

        try script.write(to: files.scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: files.scriptURL.path
        )
        return files.scriptURL
    }

    private func privilegedTunnelLaunchCommand(for scriptURL: URL) -> String {
        "/bin/sh " + shellEscape(scriptURL.path) + " >/dev/null 2>&1 &"
    }

    private func runPrivilegedTunnelWithAuthorization(scriptURL: URL) throws {
        let source = """
        on run argv
            do shell script "/bin/sh " & quoted form of item 1 of argv & " >/dev/null 2>&1 &" with administrator privileges
        end run
        """
        _ = try run(["/usr/bin/osascript", "-e", source, scriptURL.path])
    }

    private func loadPrivilegedTunnelPID(from url: URL) -> Int? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let pid = PrivilegedTunnelPIDParser.parse(raw) else {
            appendLog("管理員 tunnel PID 檔內容無效，將僅使用 stop file 結束")
            return nil
        }
        return pid
    }

    private func requestPrivilegedTunnelStop(files: PrivilegedTunnelFiles) throws {
        try ensurePrivilegedTunnelDirectory(for: files)
        try Data().write(to: files.stopURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: files.stopURL.path
        )
    }

    private func isProcessRunning(pid: Int) -> Bool {
        if kill(pid_t(pid), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func stopPrivilegedTunnelProcessIfNeeded() {
        guard let files = takeActivePrivilegedTunnelFiles() else { return }
        stopPrivilegedTunnelProcess(files: files)
    }

    private func stopPrivilegedTunnelProcess(files: PrivilegedTunnelFiles) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: files.directoryURL.path) else {
            return
        }

        var childPID = loadPrivilegedTunnelPID(from: files.pidURL)
        var wrapperPID = loadPrivilegedTunnelPID(from: files.wrapperPIDURL)
        var observedWrapper = wrapperPID != nil
        do {
            try requestPrivilegedTunnelStop(files: files)
            let wrapperStartupDeadline = Date().addingTimeInterval(1.0)
            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline {
                childPID = childPID ?? loadPrivilegedTunnelPID(from: files.pidURL)
                wrapperPID = wrapperPID ?? loadPrivilegedTunnelPID(from: files.wrapperPIDURL)
                observedWrapper = observedWrapper || wrapperPID != nil
                let childRunning = childPID.map(isProcessRunning(pid:)) ?? false
                let wrapperRunning = wrapperPID.map(isProcessRunning(pid:)) ?? false
                if observedWrapper && !childRunning && !wrapperRunning {
                    break
                }
                if !observedWrapper && Date() >= wrapperStartupDeadline {
                    break
                }
                Thread.sleep(forTimeInterval: AppConstants.Timeouts.pollInterval)
            }
        } catch {
            appendLog("寫入 stop file 失敗：\(error.localizedDescription)")
        }

        let childRunning = childPID.map(isProcessRunning(pid:)) ?? false
        let wrapperRunning = wrapperPID.map(isProcessRunning(pid:)) ?? false
        if childRunning || wrapperRunning {
            appendLog("管理員 tunnel 尚未完全結束，保留 stop file 等待回收")
            return
        }
        cleanupPrivilegedTunnelArtifacts(files: files)
    }

    private func recoverOrphanedPrivilegedTunnels() {
        let fileManager = FileManager.default
        let rootURL = PrivilegedTunnelFiles.rootDirectoryURL
        let urls = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in urls where url.lastPathComponent.hasPrefix(PrivilegedTunnelAttemptIdentity.directoryPrefix) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            appendLog("回收前次未結束的管理員 tunnel")
            stopPrivilegedTunnelProcess(files: PrivilegedTunnelFiles.files(in: url))
        }

        let legacy = PrivilegedTunnelFiles.legacy()
        guard fileManager.fileExists(atPath: legacy.pidURL.path)
                || fileManager.fileExists(atPath: legacy.scriptURL.path)
                || fileManager.fileExists(atPath: legacy.logURL.path) else {
            return
        }

        appendLog("回收舊版共用檔案的管理員 tunnel")
        for _ in 0..<12 {
            try? requestPrivilegedTunnelStop(files: legacy)
            Thread.sleep(forTimeInterval: 0.25)
        }
        try? requestPrivilegedTunnelStop(files: legacy)
        for url in [legacy.logURL, legacy.pidURL, legacy.wrapperPIDURL, legacy.scriptURL] {
            try? fileManager.removeItem(at: url)
        }
    }

    func disconnect() {
        userInitiatedDisconnect = true
        let generation = invalidateConnectionAttempt()
        cancelAutoReconnect()
        clearSimulatedLocation()
        stopTunnel()
        setConnectionState(.disconnected, deviceName: "未連接", lastError: nil, generation: generation)
        appendLog("裝置已中斷")
    }

    func disconnectAsync() async {
        disconnect()
        while isConnected || isConnecting {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func sendLocationToDevice(latitude: Double, longitude: Double) {
        guard isConnected else { return }
        let c = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(c) else { return }

        sendQueue.async { [weak self] in
            guard let self else { return }
            self.pendingCoordinate = c
            self.flushLatestCoordinate()
        }
    }

    func sendLocationToDeviceAsync(latitude: Double, longitude: Double) async throws {
        guard isConnected else {
            throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "裝置尚未連線"
            ])
        }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else {
            throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "座標無效"
            ])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "DeviceManager 已釋放"
                    ]))
                    return
                }

                let wasIdle = !self.inFlight && self.pendingCoordinate == nil
                self.pendingCoordinate = coordinate

                guard wasIdle else {
                    continuation.resume()
                    return
                }

                self.flushLatestCoordinate()
                if self.lastError?.contains("發送定位失敗") == true {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: self.lastError ?? "發送定位失敗"
                    ]))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func startContinuousLocationStream() {
        guard isConnected else { return }
        sendQueue.async { [weak self] in
            guard let self, let ep = self.rsdEndpoint else { return }
            guard self.simulateLocationMode == .dvt else { return }
            do {
                try self.startDvtStreamIfNeeded(host: ep.host, port: ep.port)
            } catch {
                self.appendLog("啟動 DVT 即時定位流失敗：\(error.localizedDescription)")
            }
        }
    }

    func stopContinuousLocationStream() {
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.expectedDvtStreamExit = true
            self.dvtStream.stop()
        }
    }

    func clearSimulatedLocation() {
        guard isConnected else { return }
        sendQueue.async { [weak self] in
            guard let self, let ep = self.rsdEndpoint else { return }
            do {
                let cmd = try self.resolveCLI()
                let mode = self.simulateLocationMode ?? .legacy
                self.dvtStream.clear()
                _ = try self.runWithTimeoutLogged(
                    cmd + mode.clearArgs(host: ep.host, port: ep.port),
                    timeout: AppConstants.Timeouts.rsdInfo,
                    step: "清除模擬定位"
                )
#if DEBUG
                print("🧹 已清除模擬定位")
#endif
            } catch {
#if DEBUG
                print("⚠️ 清除失敗: \(DeviceLogRedactor.sanitizedMessage(error.localizedDescription))")
#endif
                self.appendLog("清除模擬定位失敗：\(error.localizedDescription)")
            }
        }
    }

    func clearSimulatedLocationAsync() async throws {
        guard isConnected else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "DeviceManager 已釋放"
                    ]))
                    return
                }
                guard let ep = self.rsdEndpoint else {
                    continuation.resume(throwing: NSError(domain: "DeviceManager", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "RSD 未就緒"
                    ]))
                    return
                }
                do {
                    let cmd = try self.resolveCLI()
                    let mode = self.simulateLocationMode ?? .legacy
                    self.dvtStream.clear()
                    _ = try self.runWithTimeoutLogged(
                        cmd + mode.clearArgs(host: ep.host, port: ep.port),
                        timeout: AppConstants.Timeouts.rsdInfo,
                        step: "清除模擬定位"
                    )
                    continuation.resume()
                } catch {
                    self.appendLog("清除模擬定位失敗：\(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func flushLatestCoordinate() {
        guard !inFlight, let next = pendingCoordinate else { return }
        pendingCoordinate = nil
        inFlight = true
        defer {
            inFlight = false
            if pendingCoordinate != nil { flushLatestCoordinate() }
        }

        guard rsdEndpoint != nil else {
            setConnectionState(.failed, deviceName: "RSD 未就緒，請重連", lastError: "RSD 未就緒")
            return
        }

        do {
            let lat = String(format: AppConstants.Formatting.coordinatePrecision, next.latitude)
            let lon = String(format: AppConstants.Formatting.coordinatePrecision, next.longitude)
            try sendCoordinate(latitude: next.latitude, longitude: next.longitude)
            sentLocationCount += 1
            if sentLocationCount % 100 == 0 {
                appendLog("定位已送出：\(lat), \(lon)")
            }
        } catch {
            let msg = error.localizedDescription
#if DEBUG
            print("❌ 發送失敗: \(DeviceLogRedactor.sanitizedMessage(msg))")
#endif
            appendLog("送出定位失敗：\(msg)")
            DispatchQueue.main.async {
                self.lastError = DeviceLogRedactor.sanitizedMessage("發送定位失敗：\(msg)")
            }
            if msg.lowercased().contains("timeout") || msg.lowercased().contains("broken pipe") || msg.lowercased().contains("connection") {
                setConnectionState(.failed, deviceName: "Tunnel 中斷，請重連", lastError: msg)
                scheduleAutoReconnect(reason: msg)
            }
        }
    }

    private func resolveCLI() throws -> [String] {
        if let resourcesURL = Bundle.main.resourceURL {
            let bundledURL = resourcesURL
                .appendingPathComponent("pymobiledevice3-bundle", isDirectory: true)
                .appendingPathComponent("pymobiledevice3", isDirectory: false)
            let bundledPath = bundledURL.path
            if FileManager.default.isExecutableFile(atPath: bundledPath) {
            appendLog("CLI source: bundled (\(bundledPath))")
            return [bundledPath]
            }
        }
        appendLog("CLI source: bundled missing")
        throw NSError(domain: "DeviceManager", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "找不到 bundled pymobiledevice3 CLI。請重新安裝 App。"
        ])
    }

    private func startTunnelAndResolveEndpoint(using cmd: [String], udid: String?, generation: UInt64) throws {
        var failures: [String] = []
        for transport in tunnelTransports {
            do {
                try startTunnelAndResolveEndpoint(
                    using: cmd,
                    udid: udid,
                    transport: transport,
                    generation: generation
                )
                return
            } catch {
                let failure = "\(transport.rawValue): \(error.localizedDescription)"
                failures.append(failure)
                appendLog("tunnel 失敗（\(failure)）")
                stopTunnel()
            }
        }
        throw NSError(domain: "DeviceManager", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "所有 tunnel 協定都失敗。\n" + failures.joined(separator: "\n")
        ])
    }

    private func startTunnelAndResolveEndpoint(
        using cmd: [String],
        udid: String?,
        transport: TunnelTransport,
        generation: UInt64
    ) throws {
        try ensureCurrentConnectionAttempt(generation)
        stopTunnel()
        setStage("等待連線就緒", generation: generation)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = cmd + startTunnelArguments(transport: transport, udid: udid)

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let textBuffer = LockedStringBuffer()
        let appendText: @Sendable (String) -> Void = { chunk in
            textBuffer.append(chunk)
        }
        let snapshotText: () -> String = {
            textBuffer.snapshot()
        }

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let t = String(data: data, encoding: .utf8) else { return }
            appendText(t)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let t = String(data: data, encoding: .utf8) else { return }
            appendText("\n" + t)
        }

        try p.run()
        tunnelProcess = p
        tunnelOutPipe = out
        tunnelErrPipe = err

        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            self.connectionQueue.async {
                guard self.isCurrentConnectionAttempt(generation), self.tunnelProcess === proc else { return }
                if self.rsdEndpoint != nil && !self.userInitiatedDisconnect {
                    self.handleUnexpectedConnectionLoss(
                        reason: "tunnel 行程已結束（code: \(proc.terminationStatus)）",
                        generation: generation
                    )
                }
            }
        }

        let deadline = Date().addingTimeInterval(AppConstants.Timeouts.tunnelReady)
        appendLog("等待 tunnel 輸出 RSD 位址 (\(transport.rawValue))")

        while Date() < deadline {
            try ensureCurrentConnectionAttempt(generation)
            let currentText = snapshotText()
            if let pair = TunnelOutputParser.endpoint(in: currentText) {
                let ep = Endpoint(host: pair.host, port: pair.port)
                rsdEndpoint = ep
                appendLog("抓到 RSD 位址：\(ep.host):\(ep.port)")
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                return
            }

            if let failure = TunnelOutputParser.immediateFailure(in: currentText) {
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: DeviceLogRedactor.sanitizedMessage(failure)
                ])
            }

            if !p.isRunning {
                break
            }

            Thread.sleep(forTimeInterval: 0.15)
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let finalText = snapshotText()
        appendLog("tunnel 未返回 RSD 位址 (\(transport.rawValue))")

        throw NSError(domain: "DeviceManager", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "start-tunnel 逾時或未輸出 RSD 位址。\n\(DeviceLogRedactor.sanitizedMessage(finalText))"
        ])
    }

    private func isOnSendQueue() -> Bool {
        DispatchQueue.getSpecific(key: sendQueueSpecificKey) == sendQueueSpecificValue
    }

    private func resetSendState() {
        expectedDvtStreamExit = true
        dvtStream.stop()
        pendingCoordinate = nil
        inFlight = false
    }

    private func stopSendPipelineSynchronously() {
        if isOnSendQueue() {
            resetSendState()
            return
        }
        let group = DispatchGroup()
        group.enter()
        sendQueue.async { [weak self] in
            defer { group.leave() }
            self?.resetSendState()
        }
        _ = group.wait(timeout: .now() + 2.0)
    }

    private func stopTunnel() {
        rsdEndpoint = nil
        simulateLocationMode = nil
        activeTunnelConnectionType = nil
        stopSendPipelineSynchronously()

        tunnelOutPipe?.fileHandleForReading.readabilityHandler = nil
        tunnelErrPipe?.fileHandleForReading.readabilityHandler = nil

        let process = tunnelProcess
        tunnelProcess = nil
        tunnelOutPipe = nil
        tunnelErrPipe = nil

        if let p = process {
            p.terminationHandler = nil
        }

        if let process {
            stopDirectTunnelProcess(process)
        }

        stopPrivilegedTunnelProcessIfNeeded()

    }

    private func stopDirectTunnelProcess(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        process.terminate()
        var deadline = Date().addingTimeInterval(0.8)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.interrupt()
            deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func handleUnexpectedConnectionLoss(reason: String, generation: UInt64) {
        guard isCurrentConnectionAttempt(generation) else { return }
        guard !userInitiatedDisconnect else { return }
        guard rsdEndpoint != nil || connectionState.isConnected else { return }
        appendLog("連線中斷：\(reason)")
        stopTunnel()
        setConnectionState(.failed, deviceName: "連線已中斷", lastError: reason, generation: generation)
        scheduleAutoReconnect(reason: reason)
    }

    private func handleUnexpectedConnectionLoss(reason: String) {
        handleUnexpectedConnectionLoss(reason: reason, generation: currentConnectionGeneration())
    }

    @discardableResult
    private func runWithNonInteractiveSudo(_ shellCmd: String) -> Bool {
        do {
            _ = try run(["/usr/bin/sudo", "-n", "/bin/sh", "-c", shellCmd])
            return true
        } catch {
            appendLog("sudo -n 不可用：\(error.localizedDescription)")
            return false
        }
    }

    private func scheduleAutoReconnect(reason: String) {
        guard !userInitiatedDisconnect else { return }
        guard autoReconnectWorkItem == nil else { return }

        reconnectAttempt += 1
        let delay = min(AppConstants.DeviceStream.reconnectBackoffCap, pow(2.0, Double(max(0, reconnectAttempt - 1))))
        setConnectionState(.connecting(step: "等待重連"), deviceName: "等待重新連線…", lastError: lastError)
        appendLog("排程自動重連（\(String(format: "%.0f", delay))s）原因：\(reason)")

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoReconnectWorkItem = nil
            guard !self.userInitiatedDisconnect else { return }
            self.connectDeviceInternal(autoTriggered: true, force: true)
        }
        autoReconnectWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelAutoReconnect() {
        autoReconnectWorkItem?.cancel()
        autoReconnectWorkItem = nil
    }

    private func setStage(_ stage: String, generation: UInt64) {
        setConnectionState(.connecting(step: stage), lastError: nil, generation: generation)
    }

    private func setConnectionState(
        _ state: DeviceConnectionState,
        deviceName: String? = nil,
        lastError: String? = nil,
        generation: UInt64? = nil
    ) {
        DispatchQueue.main.async {
            if let generation, !self.isCurrentConnectionAttempt(generation) {
                return
            }
            self.connectionState = state
            if let deviceName {
                self.deviceName = deviceName
            }
            self.lastError = lastError.map(DeviceLogRedactor.sanitizedMessage)
        }
    }

    private func appendLog(_ text: String) {
        let stamp = Self.logFormatter.string(from: Date())
        let line = "[\(stamp)] \(DeviceLogRedactor.sanitizedMessage(text))"
        DispatchQueue.main.async {
            self.debugLog.append(line)
            if self.debugLog.count > 120 {
                self.debugLog.removeFirst(self.debugLog.count - 120)
            }
        }
        runtimeLogQueue.async { [runtimeLogStore] in
            runtimeLogStore.appendLine(line)
        }
    }

    private func runWithTimeoutLogged(_ args: [String], timeout: TimeInterval, step: String) throws -> String {
        appendLog("▶ \(step)")
        appendLog("cmd: \(DeviceLogRedactor.sanitizedCommandString(args))")
        do {
            let out = try runWithTimeout(args, timeout: timeout)
            let trimmed = summarizeOutput(out)
            if !trimmed.isEmpty {
                appendLog("out: \(trimmed)")
            }
            appendLog("✓ \(step)")
            return out
        } catch {
            appendLog("✗ \(step): \(error.localizedDescription)")
            throw error
        }
    }

    private func summarizeOutput(_ text: String, maxChars: Int = 260) -> String {
        let cleaned = DeviceLogRedactor.sanitizedMessage(
            text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
            .joined(separator: " | ")
        )
        if cleaned.count <= maxChars { return cleaned }
        return String(cleaned.prefix(maxChars)) + "..."
    }

    private func sendCoordinateByLegacyCommand(latitude: Double, longitude: Double) throws {
        guard let ep = rsdEndpoint else {
            throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "RSD 未就緒"
            ])
        }
        let cmd = try resolveCLI()
        let mode = simulateLocationMode ?? .legacy
        _ = try runWithTimeout(
            cmd + mode.setArgs(host: ep.host, port: ep.port, latitude: latitude, longitude: longitude),
            timeout: AppConstants.Timeouts.coordinateSend
        )
    }

    private func sendCoordinate(latitude: Double, longitude: Double) throws {
        guard let ep = rsdEndpoint else {
            throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "RSD 未就緒"
            ])
        }

        if simulateLocationMode == .dvt {
            try startDvtStreamIfNeeded(host: ep.host, port: ep.port)
            try dvtStream.send(latitude: latitude, longitude: longitude)
            return
        }

        try sendCoordinateByLegacyCommand(latitude: latitude, longitude: longitude)
    }

    private func startDvtStreamIfNeeded(host: String, port: String) throws {
        if dvtStream.isRunning {
            return
        }

        expectedDvtStreamExit = false

        try dvtStream.start(
            host: host,
            port: port,
            onOutput: { [weak self] text in
                self?.appendLog("dvt-stream: \(self?.summarizeOutput(text, maxChars: 180) ?? text)")
            },
            onError: { [weak self] text in
                self?.appendLog("dvt-stream err: \(self?.summarizeOutput(text, maxChars: 180) ?? text)")
            },
            onExit: { [weak self] status in
                guard let self else { return }
                self.appendLog("dvt-stream exited: \(status)")
                if self.expectedDvtStreamExit {
                    self.expectedDvtStreamExit = false
                    return
                }
                self.handleUnexpectedConnectionLoss(reason: "定位串流已中斷（code: \(status)）")
            }
        )
    }

    private func run(_ args: [String]) throws -> String {
        try runProcess(args, timeout: nil)
    }

    private func runWithTimeout(_ args: [String], timeout: TimeInterval) throws -> String {
        try runProcess(args, timeout: timeout)
    }

    private func runProcess(_ args: [String], timeout: TimeInterval?) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        let output = LockedProcessOutput()

        @Sendable func append(_ data: Data, toStdErr: Bool) {
            output.append(data, toStdErr: toStdErr)
        }

        out.fileHandleForReading.readabilityHandler = { handle in
            append(handle.availableData, toStdErr: false)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            append(handle.availableData, toStdErr: true)
        }

        try p.run()

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if p.isRunning {
                p.terminate()
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                append(out.fileHandleForReading.readDataToEndOfFile(), toStdErr: false)
                append(err.fileHandleForReading.readDataToEndOfFile(), toStdErr: true)
                let strings = output.strings()
                let details = [strings.stderr, strings.stdout]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? "無額外輸出"
                throw NSError(domain: "DeviceManager", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "command timed out: \(DeviceLogRedactor.sanitizedCommandString(args)) | \(DeviceLogRedactor.sanitizedMessage(details))"
                ])
            }
        } else {
            p.waitUntilExit()
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        append(out.fileHandleForReading.readDataToEndOfFile(), toStdErr: false)
        append(err.fileHandleForReading.readDataToEndOfFile(), toStdErr: true)

        let strings = output.strings()
        let stdoutString = strings.stdout
        let stderrString = strings.stderr

        if p.terminationStatus != 0 {
            let details = [stderrString, stdoutString]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "Command failed"
            throw NSError(domain: "DeviceManager", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: DeviceLogRedactor.sanitizedMessage(details)
            ])
        }

        return stdoutString
    }
}
