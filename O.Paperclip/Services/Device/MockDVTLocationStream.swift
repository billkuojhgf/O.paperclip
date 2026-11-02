import Foundation

final class MockDVTLocationStream: DVTStreaming {
    private let lock = NSLock()
    private var running = false
    var isRunning: Bool {
        get { lock.lock(); defer { lock.unlock() }; return running }
        set { lock.lock(); defer { lock.unlock() }; running = newValue }
    }
    var sentCoordinates: [(latitude: Double, longitude: Double)] = []
    var shouldThrowOnSend = false
    var startCallCount = 0
    private var stops = 0
    var stopCallCount: Int {
        lock.lock(); defer { lock.unlock() }; return stops
    }
    var clearCallCount = 0
    var lastHost: String?
    var lastPort: String?

    func start(
        host: String,
        port: String,
        onOutput: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        startCallCount += 1
        lastHost = host
        lastPort = port
        isRunning = true
    }

    func send(latitude: Double, longitude: Double) throws {
        if shouldThrowOnSend {
            throw NSError(domain: "MockDVTLocationStream", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "mock send error"
            ])
        }
        sentCoordinates.append((latitude: latitude, longitude: longitude))
    }

    func clear() {
        clearCallCount += 1
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stops += 1
        running = false
    }
}
