import Foundation

final class MockDVTLocationStream: DVTStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    private var running = false
    private var cancelled = false
    private var coordinates: [(latitude: Double, longitude: Double)] = []
    private var starts = 0
    private var stops = 0
    private var clears = 0
    private var connections = 0
    private var disconnections = 0
    private var connectFailure = false
    private var sendFailure = false
    private var clearFailure = false
    private var configuration: DeviceWorkerConfiguration?

    var isConnected: Bool {
        get { lock.lock(); defer { lock.unlock() }; return connected }
        set { lock.lock(); defer { lock.unlock() }; connected = newValue }
    }
    var isRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return running }
        set { lock.lock(); defer { lock.unlock() }; running = newValue }
    }
    var sentCoordinates: [(latitude: Double, longitude: Double)] {
        lock.lock(); defer { lock.unlock() }; return coordinates
    }
    var shouldThrowOnConnect: Bool {
        get { lock.lock(); defer { lock.unlock() }; return connectFailure }
        set { lock.lock(); defer { lock.unlock() }; connectFailure = newValue }
    }
    var shouldThrowOnSend: Bool {
        get { lock.lock(); defer { lock.unlock() }; return sendFailure }
        set { lock.lock(); defer { lock.unlock() }; sendFailure = newValue }
    }
    var shouldThrowOnClear: Bool {
        get { lock.lock(); defer { lock.unlock() }; return clearFailure }
        set { lock.lock(); defer { lock.unlock() }; clearFailure = newValue }
    }
    var startCallCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var stopCallCount: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var clearCallCount: Int { lock.lock(); defer { lock.unlock() }; return clears }
    var connectCallCount: Int { lock.lock(); defer { lock.unlock() }; return connections }
    var disconnectCallCount: Int { lock.lock(); defer { lock.unlock() }; return disconnections }
    var lastConfiguration: DeviceWorkerConfiguration? { lock.lock(); defer { lock.unlock() }; return configuration }

    func connect(configuration: DeviceWorkerConfiguration,
                 onStage: @escaping @Sendable (String) -> Void,
                 onOutput: @escaping @Sendable (String) -> Void,
                 onError: @escaping @Sendable (String) -> Void,
                 onExit: @escaping @Sendable (Int32, NSError?) -> Void) throws -> DeviceWorkerInfo {
        lock.lock()
        connections += 1
        self.configuration = configuration
        cancelled = false
        connected = false
        running = false
        let failure = connectFailure
        lock.unlock()
        onStage("建立裝置連線")
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if failure { throw Self.error("mock connect error") }
        connected = true
        let transport = configuration.rsdHost != nil ? "manual-rsd" : (configuration.connectionType == "wifi" ? "userspace-wifi" : "userspace-usb")
        return DeviceWorkerInfo(udid: configuration.udid ?? "mock-device", deviceName: "Mock Device", transport: transport, mode: "dvt", effectiveUID: 501)
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellation()
        if running { return }
        guard connected else { throw Self.error("mock disconnected") }
        starts += 1
        running = true
    }

    func send(latitude: Double, longitude: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellation()
        guard connected else { throw Self.error("mock disconnected") }
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw Self.error("座標無效", code: "invalid_coordinate")
        }
        if sendFailure { throw Self.error("mock send error") }
        coordinates.append((latitude: latitude, longitude: longitude))
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellation()
        clears += 1
        guard connected else { throw Self.error("mock disconnected") }
        if clearFailure { throw Self.error("mock clear error") }
    }

    func stop() throws {
        lock.lock()
        defer { lock.unlock() }
        try checkCancellation()
        stops += 1
        running = false
    }

    func cancelPendingOperations() {
        lock.lock()
        cancelled = true
        connected = false
        running = false
        lock.unlock()
    }

    func disconnect() {
        lock.lock()
        disconnections += 1
        cancelled = true
        connected = false
        running = false
        lock.unlock()
    }

    private func checkCancellation() throws {
        if cancelled { throw CancellationError() }
    }

    private static func error(_ message: String, code: String = "operation_failed") -> NSError {
        NSError(domain: "DeviceWorker", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message, "workerCode": code, "fatal": false, "requestID": NSNull()
        ])
    }
}
