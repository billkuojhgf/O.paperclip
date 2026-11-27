import AppKit
import Combine
import Darwin
import Foundation
import MapKit




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


struct DiscoveredWiFiDevice: Identifiable, Sendable {
    let id: String
    let name: String
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
            dictionary["udid"] as? String ??
            dictionary["identifier"] as? String ??
            dictionary["Identifier"] as? String
        guard let rawIdentifier else { return nil }
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

final class DeviceManager: ObservableObject, DeviceControlling, @unchecked Sendable {
    @Published private(set) var connectionState: DeviceConnectionState = .disconnected
    @Published private(set) var deviceName = "未連接"
    @Published private(set) var lastError: String?
    @Published private(set) var activeConnectionLabel = "未連接"
    @Published var manualRsdHost = ""
    @Published var manualRsdPort = ""
    @Published var tunnelUDID = ""
    @Published var isWirelessMode = false {
        didSet { UserDefaults.standard.set(isWirelessMode, forKey: wirelessModeKey) }
    }
    @Published private(set) var debugLog: [String] = []

    var isConnected: Bool { connectionState.isConnected }
    var isConnecting: Bool { connectionState.isBusy }
    var connectionStage: String { connectionState.statusText }

    private struct USBMuxDevice: Decodable {
        let connectionType: String?
        let identifier: String?
        let uniqueDeviceID: String?
        enum CodingKeys: String, CodingKey {
            case connectionType = "ConnectionType"
            case identifier = "Identifier"
            case uniqueDeviceID = "UniqueDeviceID"
        }
    }

    private struct NativeWiFiDevice: Decodable {
        let udid: String
        let name: String?
        let networkAdvertActive: Bool?
    }


    private let sendQueue = DispatchQueue(label: "paperclip.gps.sender", qos: .utility)
    private let connectionQueue = DispatchQueue(label: "paperclip.connection", qos: .utility)
    private let stateLock = NSLock()
    private var generation = 0
    private var sendGeneration = 0
    private var pendingCoordinate: (CLLocationCoordinate2D, Int)?
    private var drainScheduled = false
    private var userInitiatedDisconnect = false
    private var connected = false
    private var isConnectionInFlight = false
    private var connectionWaiters: [@Sendable (Result<Void, Error>) -> Void] = []
    private var autoReconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var sessionUDID: String?
    private var workerGeneration = 0
    private let dvtStream: any DVTStreaming
    private let runtimeLogStore: RotatingRuntimeLogStore
    private let runtimeLogQueue = DispatchQueue(label: "paperclip.runtime.log", qos: .utility)
    private let wirelessModeKey: String
    private let cliCommand: [String]?

    init(settingsKey: String = "default", cliCommand: [String]? = nil, dvtStream: any DVTStreaming = DVTLocationStream()) {
        self.dvtStream = dvtStream
        precondition(!settingsKey.isEmpty && settingsKey.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 })
        self.cliCommand = cliCommand
        let prefix = settingsKey == "default" ? "paperclip.connection" : "paperclip.connection.\(settingsKey)"
        wirelessModeKey = "\(prefix).wirelessMode"
        runtimeLogStore = RotatingRuntimeLogStore(logURL: DiagnosticsPaths.logFileURL(named: settingsKey == "default" ? "device-runtime.log" : "device-runtime-\(settingsKey).log"))
        isWirelessMode = UserDefaults.standard.bool(forKey: wirelessModeKey)
    }

    deinit {
        autoReconnectWorkItem?.cancel()
        dvtStream.cancelPendingOperations()
        let stream = dvtStream
        connectionQueue.async { stream.disconnect() }
    }

    func discoverDeviceIdentifiers(completion: @escaping @Sendable (Result<[String], Error>) -> Void) {
        let wireless = isWirelessMode
        connectionQueue.async {
            do {
                let cmd = try self.resolveCLI()
                var ids = try self.listConnectedDevices(using: cmd).compactMap { $0.identifier ?? $0.uniqueDeviceID }
                if wireless {
                    let raw = try self.runWithTimeout(cmd + ["remote", "browse", "--native"], timeout: 8)
                    ids += RemoteBrowseOutputParser.identifiers(in: raw)
                }
                var seen = Set<String>()
                completion(.success(ids.filter { !$0.isEmpty && seen.insert($0).inserted }))
            } catch { completion(.failure(error)) }
        }
    }

    func discoverWiFiDevices(completion: @escaping @Sendable (Result<[DiscoveredWiFiDevice], Error>) -> Void) {
        connectionQueue.async {
            do {
                let cmd = try self.resolveCLI()
                let raw = try self.runWithTimeout(cmd + ["remote", "browse", "--native"], timeout: 8)
                let devices = try JSONDecoder().decode([NativeWiFiDevice].self, from: Data(raw.utf8))
                var seen = Set<String>()
                completion(.success(devices.compactMap { device in
                    guard device.networkAdvertActive != false, !device.udid.isEmpty, seen.insert(device.udid).inserted else { return nil }
                    return DiscoveredWiFiDevice(id: device.udid, name: device.name ?? device.udid)
                }))
            } catch { completion(.failure(error)) }
        }
    }

    func connectDevice() { beginConnection() }

    func connectDeviceAsync() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                beginConnection { continuation.resume(with: $0) }
                if Task.isCancelled { disconnect() }
            }
        } onCancel: { self.disconnect() }
    }

    private func beginConnection(autoTriggered: Bool = false, completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        let host = manualRsdHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = manualRsdPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = tunnelUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        let wireless = isWirelessMode
        stateLock.lock()
        if connected {
            stateLock.unlock()
            completion?(.success(()))
            return
        }
        if let completion { connectionWaiters.append(completion) }
        if isConnectionInFlight { stateLock.unlock(); return }
        autoReconnectWorkItem?.cancel()
        autoReconnectWorkItem = nil
        generation += 1
        let current = generation
        isConnectionInFlight = true
        userInitiatedDisconnect = false
        let reconnectIdentity = autoTriggered ? sessionUDID : nil
        stateLock.unlock()
        publish(.connecting(step: autoTriggered ? "自動重連中" : "初始化"), name: "連線中…", error: nil, generation: current)
        connectionQueue.async {
            do {
                try self.checkConnection(current)
                self.sendQueue.sync { }
                try self.checkConnection(current)
                let cmd = try self.resolveCLI()
                _ = try self.runWithTimeoutLogged(cmd + ["version"], timeout: AppConstants.Timeouts.pymobiledeviceCheck, step: "檢查 pymobiledevice3")
                try self.checkConnection(current)
                let manual = !host.isEmpty || !port.isEmpty
                var identity = reconnectIdentity ?? (requested.isEmpty ? nil : requested)
                var parsedPort: Int?
                if manual {
                    guard !host.isEmpty, let number = Int(port), (1...65535).contains(number) else {
                        throw self.failure("手動 RSD 需要完整的主機及 1–65535 連接埠。")
                    }
                    parsedPort = number
                } else if identity == nil {
                    var ids = try self.listConnectedDevices(using: cmd).compactMap { $0.identifier ?? $0.uniqueDeviceID }
                    if ids.isEmpty && wireless {
                        let raw = try self.runWithTimeout(cmd + ["remote", "browse", "--native"], timeout: 8)
                        ids = RemoteBrowseOutputParser.identifiers(in: raw)
                    }
                    guard let first = ids.first else { throw self.failure("未找到可連線的裝置。請接上 USB、解鎖並信任這台 Mac，或確認 Wi‑Fi 配對。") }
                    identity = first
                }
                try self.checkConnection(current)
                let configuration = DeviceWorkerConfiguration(udid: identity, connectionType: wireless ? "wifi" : "usb", rsdHost: manual ? host : nil, rsdPort: parsedPort)
                let info: DeviceWorkerInfo
                do {
                    info = try self.connectWorker(configuration, generation: current)
                } catch {
                    let code = (error as NSError).userInfo["workerCode"] as? String
                    guard !manual, wireless, ["wifi_unavailable", "wifi_unsupported"].contains(code ?? ""), let identity else { throw error }
                    try self.checkConnection(current)
                    let usb = try self.listConnectedDevices(using: cmd).contains {
                        ($0.identifier == identity || $0.uniqueDeviceID == identity) && $0.connectionType?.uppercased() == "USB"
                    }
                    guard usb else { throw error }
                    self.dvtStream.disconnect()
                    try self.checkConnection(current)
                    self.appendLog("Wi‑Fi 無法使用，已切換 USB")
                    info = try self.connectWorker(DeviceWorkerConfiguration(udid: identity, connectionType: "usb", rsdHost: nil, rsdPort: nil), generation: current)
                }
                try self.checkConnection(current)
                guard info.effectiveUID != 0, identity == nil || info.udid == identity else { throw self.failure("裝置身分或使用者權限驗證失敗。") }
                self.stateLock.lock()
                guard self.generation == current, !self.userInitiatedDisconnect else { self.stateLock.unlock(); throw CancellationError() }
                self.connected = true
                self.sessionUDID = info.udid
                self.reconnectAttempt = 0
                self.stateLock.unlock()
                let label = Self.transportLabel(info.transport)
                DispatchQueue.main.async {
                    guard self.isCurrent(current), self.stateLock.withLock({ self.connected }), self.dvtStream.isConnected else { return }
                    self.tunnelUDID = info.udid
                    self.activeConnectionLabel = label
                    self.connectionState = .connected
                    self.deviceName = "\(info.deviceName)（\(label)）"
                    self.lastError = nil
                    self.finishConnection(current, result: .success(()))
                }
                self.appendLog("連線完成：\(label)，定位模式：\(info.mode)")
            } catch {
                if self.isCurrent(current) {
                    self.dvtStream.cancelPendingOperations()
                    self.dvtStream.disconnect()
                    self.stateLock.withLock { self.connected = false }
                    self.publish(.failed, name: "連線失敗", error: error.localizedDescription, generation: current)
                    self.finishConnection(current, result: .failure(error))
                    if autoTriggered && Self.canReconnect(error) { self.scheduleAutoReconnect(generation: current, reason: error.localizedDescription) }
                }
            }
        }
    }

    private func connectWorker(_ configuration: DeviceWorkerConfiguration, generation current: Int) throws -> DeviceWorkerInfo {
        let worker = stateLock.withLock { workerGeneration += 1; return workerGeneration }
        return try dvtStream.connect(configuration: configuration, onStage: { [weak self] stage in
            guard let self else { return }
            guard self.isCurrent(current) else { self.dvtStream.cancelPendingOperations(); return }
            self.publish(.connecting(step: stage), error: nil, generation: current)
        }, onOutput: { [weak self] text in
            guard let self, self.isCurrent(current) else { return }
            self.appendLog("worker: \(self.summarizeOutput(text))")
        }, onError: { [weak self] text in
            guard let self, self.isCurrent(current) else { return }
            self.appendLog("worker: \(self.summarizeOutput(text))")
        }, onExit: { [weak self] status, error in
            guard let self else { return }
            self.connectionQueue.async {
                guard self.isCurrent(current), self.stateLock.withLock({ self.workerGeneration == worker && self.connected }) else { return }
                self.stateLock.withLock { self.connected = false }
                self.invalidateSends()
                let failure = error ?? self.failure("裝置連線已中斷（\(status)）。")
                self.publish(.failed, name: "連線已中斷", error: failure.localizedDescription, generation: current)
                self.finishConnection(current, result: .failure(failure))
                if Self.canReconnect(failure) { self.scheduleAutoReconnect(generation: current, reason: failure.localizedDescription) }
            }
        })
    }

    private func finishConnection(_ current: Int, result: Result<Void, Error>) {
        let callbacks = stateLock.withLock { () -> [@Sendable (Result<Void, Error>) -> Void] in
            guard generation == current else { return [] }
            isConnectionInFlight = false
            let callbacks = connectionWaiters
            connectionWaiters.removeAll()
            return callbacks
        }
        callbacks.forEach { $0(result) }
    }

    private func isCurrent(_ current: Int) -> Bool {
        stateLock.withLock { generation == current && !userInitiatedDisconnect }
    }
    private func checkConnection(_ current: Int) throws {
        guard isCurrent(current) else { throw CancellationError() }
    }

    func disconnect() {
        stateLock.lock()
        generation += 1
        let current = generation
        userInitiatedDisconnect = true
        connected = false
        isConnectionInFlight = false
        sessionUDID = nil
        autoReconnectWorkItem?.cancel()
        autoReconnectWorkItem = nil
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        dvtStream.cancelPendingOperations()
        connectionQueue.async { self.dvtStream.disconnect() }
        stateLock.unlock()
        invalidateSends()
        waiters.forEach { $0(.failure(CancellationError())) }
        publish(.disconnected, name: "未連接", error: nil, generation: current)
    }

    func disconnectAsync() async {
        disconnect()
        await withCheckedContinuation { continuation in
            connectionQueue.async { continuation.resume() }
        }
        await MainActor.run { }
    }

    func sendLocationToDevice(latitude: Double, longitude: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        stateLock.lock()
        guard connected else { stateLock.unlock(); return }
        pendingCoordinate = (coordinate, sendGeneration)
        let schedule = !drainScheduled
        drainScheduled = true
        let current = sendGeneration
        stateLock.unlock()
        if schedule { sendQueue.async { self.flushLatestCoordinate(generation: current) } }
    }

    private func flushLatestCoordinate(generation current: Int) {
        let next = stateLock.withLock { () -> CLLocationCoordinate2D? in
            guard sendGeneration == current else { return nil }
            guard let value = pendingCoordinate else { drainScheduled = false; return nil }
            pendingCoordinate = nil
            return value.0
        }
        guard let next, validSend(current) else { return }
        do { try dvtStream.send(latitude: next.latitude, longitude: next.longitude) }
        catch { recordSendFailure(error, generation: current) }
        let again = stateLock.withLock { () -> Bool in
            guard sendGeneration == current else { return false }
            guard pendingCoordinate != nil else { drainScheduled = false; return false }
            return true
        }
        if again { sendQueue.async { self.flushLatestCoordinate(generation: current) } }
    }

    func sendLocationToDeviceAsync(latitude: Double, longitude: Double) async throws {
        guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else { throw failure("座標無效。") }
        let current = stateLock.withLock { sendGeneration }
        try await performSend(current) { try self.dvtStream.send(latitude: latitude, longitude: longitude) }
    }

    func startContinuousLocationStream() {
        let current = stateLock.withLock { sendGeneration }
        sendQueue.async {
            guard self.validSend(current) else { return }
            do { try self.dvtStream.start() } catch { self.recordSendFailure(error, generation: current) }
        }
    }

    func stopContinuousLocationStream() {
        let current = invalidateSends()
        sendQueue.async {
            guard self.stateLock.withLock({ self.sendGeneration == current }) else { return }
            do { try self.dvtStream.stop() } catch { self.recordSendFailure(error, generation: current) }
        }
    }

    func clearSimulatedLocation() {
        let current = invalidateSends()
        sendQueue.async {
            guard self.validSend(current) else { return }
            do { try self.dvtStream.clear() } catch { self.recordSendFailure(error, generation: current) }
        }
    }

    func clearSimulatedLocationAsync() async throws {
        let current = invalidateSends()
        guard stateLock.withLock({ connected }) else { return }
        try await performSend(current) { try self.dvtStream.clear() }
    }

    private func performSend(_ current: Int, operation: @escaping @Sendable () throws -> Void) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async {
                do {
                    guard self.validSend(current) else { throw CancellationError() }
                    try operation()
                    guard self.validSend(current) else { throw CancellationError() }
                    continuation.resume()
                } catch {
                    self.recordSendFailure(error, generation: current)
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
    }

    @discardableResult private func invalidateSends() -> Int {
        stateLock.withLock {
            sendGeneration += 1
            pendingCoordinate = nil
            drainScheduled = false
            return sendGeneration
        }
    }
    private func validSend(_ current: Int) -> Bool {
        stateLock.withLock { connected && sendGeneration == current && !userInitiatedDisconnect }
    }
    private func recordSendFailure(_ error: Error, generation current: Int) {
        guard !(error is CancellationError), validSend(current) else { return }
        appendLog("定位操作失敗：\(error.localizedDescription)")
        DispatchQueue.main.async {
            guard self.validSend(current) else { return }
            self.lastError = DeviceLogRedactor.sanitizedMessage(error.localizedDescription)
        }
    }

    private static func canReconnect(_ error: Error) -> Bool {
        guard let code = (error as NSError).userInfo["workerCode"] as? String else { return true }
        return ["transport_lost", "transport_unavailable", "timeout"].contains(code)
    }
    private func scheduleAutoReconnect(generation current: Int, reason: String) {
        stateLock.lock()
        guard generation == current, !userInitiatedDisconnect, autoReconnectWorkItem == nil else { stateLock.unlock(); return }
        reconnectAttempt += 1
        let delay = min(AppConstants.DeviceStream.reconnectBackoffCap, pow(2.0, Double(reconnectAttempt - 1)))
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(current) else { return }
            self.stateLock.withLock { self.autoReconnectWorkItem = nil }
            self.beginConnection(autoTriggered: true)
        }
        autoReconnectWorkItem = item
        stateLock.unlock()
        appendLog("等待 \(Int(delay)) 秒後重連：\(reason)")
        publish(.connecting(step: "等待重連"), name: "等待重新連線…", error: reason, generation: current)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func publish(_ state: DeviceConnectionState, name: String? = nil, error: String?, generation current: Int) {
        let update: @Sendable () -> Void = {
            guard self.stateLock.withLock({ self.generation == current && !(state.isBusy && self.connected) }) else { return }
            self.connectionState = state
            if let name { self.deviceName = name }
            if state == .disconnected { self.activeConnectionLabel = "未連接" }
            self.lastError = error.map(DeviceLogRedactor.sanitizedMessage)
        }
        if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
    private static func transportLabel(_ transport: String) -> String {
        switch transport {
        case "userspace-usb", "lockdown-usb": return "USB"
        case "userspace-wifi", "lockdown-wifi": return "Wi‑Fi"
        case "native": return "系統通道"
        case "manual-rsd": return "手動 RSD"
        default: return "未知通道"
        }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "DeviceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func listConnectedDevices(using cmd: [String]) throws -> [USBMuxDevice] {
        let raw = try runWithTimeout(cmd + ["usbmux", "list"], timeout: AppConstants.Timeouts.tunnelReady)
        return try JSONDecoder().decode([USBMuxDevice].self, from: Data(raw.utf8))
    }

    private func resolveCLI() throws -> [String] {
        if let cliCommand { return cliCommand }
        if let resourcesURL = Bundle.main.resourceURL {
            let url = resourcesURL.appendingPathComponent("pymobiledevice3-bundle/pymobiledevice3")
            if FileManager.default.isExecutableFile(atPath: url.path) { return [url.path] }
        }
        throw failure("找不到 bundled pymobiledevice3 CLI。請重新安裝 App。")
    }

    private func appendLog(_ text: String) {
        let line = DeviceLogRedactor.sanitizedMessage(text)
        DispatchQueue.main.async {
            self.debugLog.append(line)
            if self.debugLog.count > 120 { self.debugLog.removeFirst(self.debugLog.count - 120) }
        }
        runtimeLogQueue.async { [runtimeLogStore] in runtimeLogStore.appendLine(line) }
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
