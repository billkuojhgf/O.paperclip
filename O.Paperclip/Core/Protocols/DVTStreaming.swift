import Foundation

struct DeviceWorkerConfiguration: Sendable {
    let udid: String?
    let connectionType: String
    let rsdHost: String?
    let rsdPort: Int?
}

struct DeviceWorkerInfo: Sendable {
    let udid: String
    let deviceName: String
    let transport: String
    let mode: String
    let effectiveUID: UInt32
}

protocol DVTStreaming: AnyObject, Sendable {
    var isConnected: Bool { get }
    var isRunning: Bool { get }
    func connect(
        configuration: DeviceWorkerConfiguration,
        onStage: @escaping @Sendable (String) -> Void,
        onOutput: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32, NSError?) -> Void
    ) throws -> DeviceWorkerInfo
    func start() throws
    func send(latitude: Double, longitude: Double) throws
    func clear() throws
    func stop() throws
    func cancelPendingOperations()
    func disconnect()
}
