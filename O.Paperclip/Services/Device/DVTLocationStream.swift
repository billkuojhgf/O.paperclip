import CoreFoundation
import Darwin
import Foundation

final class DVTLocationStream: DVTStreaming, @unchecked Sendable {
    private final class Pending {
        let id: Int
        let operation: String
        let deadline: Date
        var completed = false
        var error: NSError?

        init(id: Int, operation: String, timeout: TimeInterval) {
            self.id = id
            self.operation = operation
            deadline = Date().addingTimeInterval(timeout)
        }
    }

    // All mutable session state is protected by the adapter's condition.
    private final class Session: @unchecked Sendable {
        let generation: UInt64
        let configuration: DeviceWorkerConfiguration
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let diagnostics = Pipe()
        let outputReadLock = NSLock()
        let diagnosticsReadLock = NSLock()
        let onStage: @Sendable (String) -> Void
        let onOutput: @Sendable (String) -> Void
        let onError: @Sendable (String) -> Void
        let onExit: @Sendable (Int32, NSError?) -> Void
        var buffer = Data()
        var info: DeviceWorkerInfo?
        var pending: Pending?
        var nextID = 1
        var launched = false
        var exited = false
        var retired = false
        var closing = false
        var cancelled = false
        var running = false
        var terminalError: NSError?

        init(generation: UInt64, configuration: DeviceWorkerConfiguration,
             onStage: @escaping @Sendable (String) -> Void,
             onOutput: @escaping @Sendable (String) -> Void,
             onError: @escaping @Sendable (String) -> Void,
             onExit: @escaping @Sendable (Int32, NSError?) -> Void) {
            self.generation = generation
            self.configuration = configuration
            self.onStage = onStage
            self.onOutput = onOutput
            self.onError = onError
            self.onExit = onExit
        }
    }

    private let condition = NSCondition()
    private let commandLock = NSLock()
    private let lifecycleLock = NSLock()
    private let cleanupQueue = DispatchQueue(label: "paperclip.device-worker.cleanup", qos: .utility)
    private let command: [String]?
    private let readyTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private var generation: UInt64 = 0
    private var session: Session?
    private static let maximumLineLength = 64 * 1024
    private static let workerCodes: Set<String> = [
        "invalid_request", "invalid_coordinate", "identity_mismatch", "pairing_required",
        "device_locked", "developer_mode_disabled", "wifi_unavailable", "wifi_unsupported",
        "transport_unavailable", "transport_lost", "timeout", "operation_failed"
    ]
    private static let stageMessages: Set<String> = [
        "建立裝置連線", "檢查開發者模式", "掛載開發者映像", "驗證定位服務"
    ]

    convenience init(command: [String]? = nil) {
        self.init(command: command,
                  readyTimeout: AppConstants.Timeouts.tunnelReady + AppConstants.Timeouts.mountTimeout + AppConstants.Timeouts.rsdInfo,
                  requestTimeout: AppConstants.Timeouts.coordinateSend)
    }

    // Internal timeout seam for real-process tests; production uses the initializer above.
    init(command: [String]?, readyTimeout: TimeInterval, requestTimeout: TimeInterval) {
        precondition(readyTimeout.isFinite && readyTimeout > 0 && requestTimeout.isFinite && requestTimeout > 0)
        self.command = command
        self.readyTimeout = readyTimeout
        self.requestTimeout = requestTimeout
    }

    deinit {
        condition.lock()
        let owned = session
        if let owned {
            owned.closing = true
            owned.cancelled = true
            owned.running = false
        }
        condition.broadcast()
        condition.unlock()
        if let owned {
            let condition = condition
            let lifecycleLock = lifecycleLock
            let requestTimeout = requestTimeout
            cleanupQueue.async {
                lifecycleLock.lock()
                Self.retire(owned, condition: condition, requestTimeout: requestTimeout)
                lifecycleLock.unlock()
            }
        }
    }

    var isConnected: Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let session else { return false }
        return session.info != nil && !session.closing && !session.exited && !session.retired
    }

    var isRunning: Bool {
        condition.lock()
        defer { condition.unlock() }
        return session?.running == true && session?.closing == false && session?.exited == false
    }

    func connect(configuration: DeviceWorkerConfiguration,
                 onStage: @escaping @Sendable (String) -> Void,
                 onOutput: @escaping @Sendable (String) -> Void,
                 onError: @escaping @Sendable (String) -> Void,
                 onExit: @escaping @Sendable (Int32, NSError?) -> Void) throws -> DeviceWorkerInfo {
        let arguments = try Self.arguments(for: configuration)
        let prefix: [String]
        if let command {
            guard let executable = command.first, !executable.isEmpty else {
                throw Self.workerError("invalid_request", "裝置 worker 執行指令不可為空", fatal: true)
            }
            prefix = command
        } else {
            guard let path = Bundle.main.path(forResource: "dvt-location-stream", ofType: nil) else {
                throw Self.workerError("transport_unavailable", "找不到 dvt-location-stream 執行檔", fatal: true)
            }
            prefix = [path]
        }

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        condition.lock()
        let previous = session
        if let previous {
            previous.closing = true
            previous.cancelled = true
            previous.running = false
            condition.broadcast()
        }
        condition.unlock()
        if let previous { Self.retire(previous, condition: condition, requestTimeout: requestTimeout) }

        condition.lock()
        generation &+= 1
        let current = Session(generation: generation, configuration: configuration,
                              onStage: onStage, onOutput: onOutput, onError: onError, onExit: onExit)
        session = current
        condition.unlock()
        Self.installHandlers(current, condition: condition) { [weak self, weak current] in
            guard let current else { return }
            self?.scheduleRetirement(current)
        }
        current.process.executableURL = URL(fileURLWithPath: prefix[0])
        current.process.arguments = Array(prefix.dropFirst()) + arguments
        current.process.standardInput = current.input
        current.process.standardOutput = current.output
        current.process.standardError = current.diagnostics

        // Registration precedes this callback so a cancelled manager attempt can cancel us here.
        onStage("建立裝置連線")
        do {
            condition.lock()
            let cancelled = current.cancelled
            condition.unlock()
            if cancelled { throw CancellationError() }
            do {
                try current.process.run()
            } catch {
                throw Self.workerError("transport_unavailable", "無法啟動裝置 worker：\(error.localizedDescription)", fatal: true)
            }
            try? current.input.fileHandleForReading.close()
            try? current.output.fileHandleForWriting.close()
            try? current.diagnostics.fileHandleForWriting.close()
            condition.lock()
            current.launched = true
            let deadline = Date().addingTimeInterval(readyTimeout)
            while current.info == nil && current.terminalError == nil && !current.cancelled && !current.exited {
                if !condition.wait(until: deadline) && current.info == nil && current.terminalError == nil && !current.cancelled {
                    Self.failLocked(current, Self.workerError("timeout", "裝置連線準備逾時", fatal: true), condition: condition)
                }
            }
            let info = current.info
            let failure = Self.failureLocked(current)
            condition.unlock()
            if let failure { throw failure }
            guard let info else {
                throw Self.workerError("transport_lost", "裝置 worker 在連線完成前結束", fatal: true)
            }
            return info
        } catch {
            scheduleRetirement(current)
            throw error
        }
    }

    func start() throws {
        try request("start-stream", idempotentStart: true)
    }

    func send(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw Self.workerError("invalid_coordinate", "座標無效", fatal: false)
        }
        try request("set", fields: ["latitude": latitude, "longitude": longitude])
    }

    func clear() throws { try request("clear") }
    func stop() throws { try request("stop-stream") }

    func cancelPendingOperations() {
        condition.lock()
        if let session, !session.retired {
            session.closing = true
            session.cancelled = true
            session.running = false
        }
        condition.broadcast()
        condition.unlock()
    }

    func disconnect() {
        cancelPendingOperations()
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        condition.lock()
        let current = session
        condition.unlock()
        if let current { Self.retire(current, condition: condition, requestTimeout: requestTimeout) }
    }

    private func request(_ operation: String, fields: [String: Double] = [:], idempotentStart: Bool = false) throws {
        condition.lock()
        let requestedGeneration = session?.generation
        condition.unlock()
        commandLock.lock()
        defer { commandLock.unlock() }
        condition.lock()
        guard requestedGeneration == session?.generation else {
            condition.unlock()
            throw CancellationError()
        }
        guard let current = session else {
            condition.unlock()
            throw Self.workerError("transport_lost", "裝置尚未連線", fatal: true)
        }
        if let error = Self.failureLocked(current) {
            condition.unlock()
            throw error
        }
        guard current.info != nil, !current.retired, current.pending == nil else {
            condition.unlock()
            throw Self.workerError("transport_lost", "裝置尚未完成連線", fatal: true)
        }
        if idempotentStart && current.running {
            condition.unlock()
            return
        }
        let pending = Pending(id: current.nextID, operation: operation, timeout: requestTimeout)
        current.nextID += 1
        current.pending = pending
        condition.unlock()
        do {
            try Self.write(operation, id: pending.id, fields: fields, to: current)
        } catch {
            condition.lock()
            Self.failLocked(current, Self.workerError("transport_lost", "無法傳送裝置指令", fatal: true, id: pending.id), condition: condition)
            condition.unlock()
        }

        condition.lock()
        while !pending.completed && current.terminalError == nil && !current.cancelled && !current.exited {
            if !condition.wait(until: pending.deadline) && !pending.completed && current.terminalError == nil && !current.cancelled {
                Self.failLocked(current, Self.workerError("timeout", "裝置指令執行逾時", fatal: true, id: pending.id), condition: condition)
            }
        }
        // Cancellation wins even when an ACK races the cancellation broadcast.
        let failure = Self.failureLocked(current) ?? pending.error
        if !current.cancelled && pending.completed { current.pending = nil }
        if failure == nil && pending.completed {
            if operation == "start-stream" { current.running = true }
            if operation == "stop-stream" { current.running = false }
        }
        let needsRetirement = current.closing || current.exited
        condition.unlock()
        if needsRetirement { scheduleRetirement(current) }
        if let failure { throw failure }
    }

    private func scheduleRetirement(_ current: Session) {
        let condition = condition
        let lifecycleLock = lifecycleLock
        let requestTimeout = requestTimeout
        cleanupQueue.async {
            lifecycleLock.lock()
            Self.retire(current, condition: condition, requestTimeout: requestTimeout)
            lifecycleLock.unlock()
        }
    }

    private static func arguments(for configuration: DeviceWorkerConfiguration) throws -> [String] {
        guard configuration.connectionType == "usb" || configuration.connectionType == "wifi" else {
            throw workerError("invalid_request", "連線方式必須為 USB 或 Wi-Fi", fatal: true)
        }
        let udid = configuration.udid
        if let udid, udid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw workerError("invalid_request", "裝置識別碼不可為空", fatal: true)
        }
        if configuration.rsdHost != nil || configuration.rsdPort != nil {
            guard let host = configuration.rsdHost, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let port = configuration.rsdPort, (1...65535).contains(port) else {
                throw workerError("invalid_request", "手動 RSD 必須提供完整有效的主機與連接埠", fatal: true)
            }
            return (udid.map { ["--udid", $0] } ?? []) + ["--rsd", host, String(port)]
        }
        guard let udid else {
            throw workerError("invalid_request", "自動連線必須指定裝置識別碼", fatal: true)
        }
        return ["--udid", udid, "--connection-type", configuration.connectionType]
    }

    private static func installHandlers(_ current: Session, condition: NSCondition, onFailure: @escaping @Sendable () -> Void) {
        current.output.fileHandleForReading.readabilityHandler = { handle in
            current.outputReadLock.lock()
            condition.lock()
            let active = !current.retired
            condition.unlock()
            if active {
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                consume(data, from: current, condition: condition)
            }
            current.outputReadLock.unlock()
            condition.lock()
            let failed = current.terminalError != nil && !current.retired
            condition.unlock()
            if failed { onFailure() }
        }
        current.diagnostics.fileHandleForReading.readabilityHandler = { handle in
            current.diagnosticsReadLock.lock()
            condition.lock()
            let active = !current.retired
            condition.unlock()
            if active {
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                else { current.onError(String(decoding: data, as: UTF8.self)) }
            }
            current.diagnosticsReadLock.unlock()
        }
        current.process.terminationHandler = { process in
            // A process may exit before its last readability callback; drain before reporting the error.
            current.outputReadLock.lock()
            condition.lock()
            let active = !current.retired
            condition.unlock()
            if !active { current.outputReadLock.unlock(); return }
            consume(current.output.fileHandleForReading.readDataToEndOfFile(), from: current, condition: condition)
            current.outputReadLock.unlock()
            current.diagnosticsReadLock.lock()
            let diagnostics = current.diagnostics.fileHandleForReading.readDataToEndOfFile()
            if !diagnostics.isEmpty { current.onError(String(decoding: diagnostics, as: UTF8.self)) }
            current.diagnosticsReadLock.unlock()
            condition.lock()
            if !current.closing && current.terminalError == nil {
                failLocked(current, workerError("transport_lost", "裝置 worker 非預期結束", fatal: true), condition: condition)
            }
            current.running = false
            let terminalError = current.terminalError
            let shouldNotify = !current.retired
            condition.broadcast()
            condition.unlock()
            if shouldNotify { current.onExit(process.terminationStatus, terminalError) }
            condition.lock()
            current.exited = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private static func consume(_ data: Data, from current: Session, condition: NSCondition) {
        condition.lock()
        guard !current.retired else { condition.unlock(); return }
        if data.isEmpty {
            if !current.buffer.isEmpty {
                failLocked(current, workerError("invalid_request", "裝置 worker 回覆不是完整的 JSON 行", fatal: true), condition: condition)
            } else if !current.closing {
                failLocked(current, workerError("transport_lost", "裝置 worker 輸出已中斷", fatal: true), condition: condition)
            }
            let terminate = current.terminalError != nil
            condition.broadcast()
            condition.unlock()
            if terminate && current.process.isRunning { current.process.terminate() }
            return
        }
        current.buffer.append(data)
        var callbacks: [(String, String?)] = []
        while let newline = current.buffer.firstIndex(of: 10) {
            let line = Data(current.buffer[..<newline])
            current.buffer.removeSubrange(...newline)
            do {
                guard line.count <= maximumLineLength, let text = String(data: line, encoding: .utf8),
                      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw workerError("invalid_request", "裝置 worker 回覆格式錯誤", fatal: true)
                }
                let stage = try receiveLocked(object, from: current, condition: condition)
                callbacks.append((text + "\n", stage))
            } catch {
                failLocked(current, error as NSError, condition: condition)
                break
            }
        }
        if current.buffer.count > maximumLineLength {
            failLocked(current, workerError("invalid_request", "裝置 worker 回覆超過長度限制", fatal: true), condition: condition)
        }
        let terminate = current.terminalError != nil
        condition.broadcast()
        condition.unlock()
        for (text, stage) in callbacks {
            current.onOutput(text)
            if let stage { current.onStage(stage) }
        }
        if terminate && current.process.isRunning { current.process.terminate() }
    }

    private static func receiveLocked(_ object: [String: Any], from current: Session, condition: NSCondition) throws -> String? {
        func require(_ valid: Bool) throws {
            if !valid { throw workerError("invalid_request", "裝置 worker 通訊協定錯誤", fatal: true) }
        }
        guard let event = object["event"] as? String else {
            throw workerError("invalid_request", "裝置 worker 缺少事件類型", fatal: true)
        }
        switch event {
        case "stage":
            try require(Set(object.keys) == ["event", "message"] && current.info == nil)
            guard let message = object["message"] as? String, stageMessages.contains(message) else {
                throw workerError("invalid_request", "裝置 worker 準備狀態無效", fatal: true)
            }
            return message
        case "ready":
            try require(Set(object.keys) == ["event", "version", "udid", "deviceName", "transport", "mode", "euid"] && current.info == nil)
            try require(integer(object["version"]) == 1)
            guard let udid = object["udid"] as? String, !udid.isEmpty,
                  let name = object["deviceName"] as? String, !name.isEmpty,
                  let transport = object["transport"] as? String,
                  let mode = object["mode"] as? String, ["dvt", "legacy"].contains(mode),
                  let uid = integer(object["euid"]), uid > 0, UInt64(uid) <= UInt64(UInt32.max) else {
                throw workerError("invalid_request", "裝置 worker 身分或執行權限無效", fatal: true)
            }
            if let requested = current.configuration.udid, udid != requested {
                throw workerError("identity_mismatch", "連線裝置與指定的裝置識別碼不符", fatal: true)
            }
            let transports: Set<String>
            if current.configuration.rsdHost != nil {
                transports = ["manual-rsd"]
            } else if current.configuration.connectionType == "wifi" {
                transports = ["userspace-wifi", "lockdown-wifi"]
            } else {
                transports = ["userspace-usb", "lockdown-usb", "native"]
            }
            try require(transports.contains(transport))
            current.info = DeviceWorkerInfo(udid: udid, deviceName: name, transport: transport, mode: mode, effectiveUID: UInt32(uid))
        case "ack":
            try require(Set(object.keys) == ["event", "id"])
            guard let id = integer(object["id"]), id > 0, current.info != nil,
                  let pending = current.pending, pending.id == id, !pending.completed else {
                throw workerError("invalid_request", "裝置 worker 回覆了非預期的 ACK 識別碼", fatal: true)
            }
            pending.completed = true
        case "error":
            try require(Set(object.keys) == ["event", "id", "code", "message", "fatal"])
            guard let code = object["code"] as? String, workerCodes.contains(code),
                  let message = object["message"] as? String, !message.isEmpty,
                  let fatal = boolean(object["fatal"]) else {
                throw workerError("invalid_request", "裝置 worker 錯誤回覆格式無效", fatal: true)
            }
            let id: Int?
            if object["id"] is NSNull { id = nil }
            else {
                guard let parsed = integer(object["id"]), parsed > 0 else {
                    throw workerError("invalid_request", "裝置 worker 錯誤識別碼無效", fatal: true)
                }
                id = parsed
            }
            let error = workerError(code, message, fatal: fatal, id: id)
            if let id {
                guard let pending = current.pending, pending.id == id, !pending.completed else {
                    throw workerError("invalid_request", "裝置 worker 回覆了非預期的錯誤識別碼", fatal: true)
                }
                pending.error = error
                pending.completed = true
                if pending.operation == "quit" { current.terminalError = error }
            } else {
                try require(fatal)
            }
            if fatal { failLocked(current, error, condition: condition) }
        default:
            throw workerError("invalid_request", "裝置 worker 回覆了未知事件", fatal: true)
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
              let integer = Int(number.stringValue) else { return nil }
        return integer
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func workerError(_ code: String, _ message: String, fatal: Bool, id: Int? = nil) -> NSError {
        NSError(domain: "DeviceWorker", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message, "workerCode": code, "fatal": fatal,
            "requestID": id.map { $0 as Any } ?? NSNull()
        ])
    }

    private static func failLocked(_ current: Session, _ error: NSError, condition: NSCondition) {
        if current.terminalError == nil {
            current.terminalError = error.domain == "DeviceWorker" ? error : workerError("invalid_request", "裝置 worker 回覆格式錯誤", fatal: true)
        }
        current.closing = true
        current.running = false
        condition.broadcast()
    }

    private static func failureLocked(_ current: Session) -> (any Error)? {
        if current.cancelled { return CancellationError() }
        if let terminalError = current.terminalError { return terminalError }
        if current.exited || current.retired { return workerError("transport_lost", "裝置連線已中斷", fatal: true) }
        return nil
    }

    private static func write(_ operation: String, id: Int, fields: [String: Double] = [:], to current: Session) throws {
        var object: [String: Any] = ["id": id, "op": operation]
        for (key, value) in fields { object[key] = value }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(10)
        try current.input.fileHandleForWriting.write(contentsOf: data)
    }

    private static func retire(_ current: Session, condition: NSCondition, requestTimeout: TimeInterval) {
        condition.lock()
        if current.retired { condition.unlock(); return }
        current.closing = true
        current.running = false
        condition.broadcast()
        // A cancelled caller leaves its outstanding ID here. Never interleave quit with that command.
        if let pending = current.pending {
            while !pending.completed && !current.exited && current.terminalError == nil && Date() < pending.deadline {
                _ = condition.wait(until: pending.deadline)
            }
            if !pending.completed && current.terminalError == nil {
                let code = current.exited ? "transport_lost" : "timeout"
                failLocked(current, workerError(code, "取消中的裝置指令未完成", fatal: true, id: pending.id), condition: condition)
            }
            current.pending = nil
        }
        let shouldQuit = current.launched && !current.exited && current.info != nil && current.terminalError == nil
        if shouldQuit {
            let pending = Pending(id: current.nextID, operation: "quit", timeout: requestTimeout)
            current.nextID += 1
            current.pending = pending
            condition.unlock()
            do { try write("quit", id: pending.id, to: current) }
            catch {
                condition.lock()
                failLocked(current, workerError("transport_lost", "無法傳送裝置結束指令", fatal: true, id: pending.id), condition: condition)
                condition.unlock()
            }
            condition.lock()
            while !pending.completed && !current.exited && current.terminalError == nil && Date() < pending.deadline {
                _ = condition.wait(until: pending.deadline)
            }
            if !pending.completed && current.terminalError == nil {
                let code = current.exited ? "transport_lost" : "timeout"
                failLocked(current, workerError(code, "裝置結束指令未完成", fatal: true, id: pending.id), condition: condition)
            }
            current.pending = nil
        }
        let terminate = current.launched && !current.exited && (!shouldQuit || current.terminalError != nil)
        condition.unlock()
        try? current.input.fileHandleForWriting.close()
        if terminate && current.process.isRunning { current.process.terminate() }

        condition.lock()
        let deadline = Date().addingTimeInterval(3)
        while current.launched && !current.exited && Date() < deadline { _ = condition.wait(until: deadline) }
        let needsKill = current.launched && !current.exited
        condition.unlock()
        if needsKill && current.process.isRunning {
            // Only this adapter's owned process is ever signalled.
            Darwin.kill(current.process.processIdentifier, SIGKILL)
            current.process.waitUntilExit()
        }
        current.outputReadLock.lock()
        current.diagnosticsReadLock.lock()
        current.output.fileHandleForReading.readabilityHandler = nil
        current.diagnostics.fileHandleForReading.readabilityHandler = nil
        current.process.terminationHandler = nil
        condition.lock()
        current.retired = true
        current.buffer.removeAll()
        current.pending = nil
        condition.broadcast()
        condition.unlock()
        for handle in [current.input.fileHandleForReading, current.input.fileHandleForWriting,
                       current.output.fileHandleForReading, current.output.fileHandleForWriting,
                       current.diagnostics.fileHandleForReading, current.diagnostics.fileHandleForWriting] {
            try? handle.close()
        }
        current.diagnosticsReadLock.unlock()
        current.outputReadLock.unlock()
    }
}
