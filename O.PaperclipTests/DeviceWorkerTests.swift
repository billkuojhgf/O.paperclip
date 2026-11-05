import Darwin
import Foundation
import Testing
@testable import O_Paperclip

struct DeviceWorkerTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        let worker: DVTLocationStream

        init(behavior: [String: Any] = [:], readyTimeout: TimeInterval = 3, requestTimeout: TimeInterval = 2) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("paperclip-worker-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: behavior).write(to: root.appendingPathComponent("worker-behavior.json"))
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
            worker = DVTLocationStream(command: ["/usr/bin/python3", script.path, root.path, "worker"], readyTimeout: readyTimeout, requestTimeout: requestTimeout)
        }

        deinit {
            worker.disconnect()
            try? FileManager.default.removeItem(at: root)
        }

        func connect(onExit: @escaping @Sendable (Int32, NSError?) -> Void = { _, _ in }) throws -> DeviceWorkerInfo {
            try worker.connect(configuration: DeviceWorkerConfiguration(udid: "phone-0", connectionType: "usb", rsdHost: nil, rsdPort: nil), onStage: { _ in }, onOutput: { _ in }, onError: { _ in }, onExit: onExit)
        }

        func events() throws -> [[String: Any]] {
            let path = root.appendingPathComponent("lifecycle.jsonl")
            guard FileManager.default.fileExists(atPath: path.path) else { return [] }
            return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }

        func waitForEvent(_ event: String, count: Int = 1) async throws {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if try events().filter({ $0["event"] as? String == event }).count >= count { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Worker 未發出預期事件：\(event)")
            throw NSError(domain: "DeviceWorkerTests", code: 1)
        }

        func position() throws -> [Double] {
            try JSONDecoder().decode([Double].self, from: Data(contentsOf: root.appendingPathComponent("phone-0.json")))
        }
    }

    private final class ExitRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Int32, NSError?)] = []

        func append(_ status: Int32, _ error: NSError?) {
            lock.lock(); defer { lock.unlock() }
            values.append((status, error))
        }

        var errors: [NSError] {
            lock.lock(); defer { lock.unlock() }
            return values.compactMap { $0.1 }
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }; return values.count
        }
    }

    private func expectWorkerError(_ code: String, fatal: Bool, operation: () throws -> Void) -> NSError? {
        do {
            try operation()
            Issue.record("預期 worker 錯誤：\(code)")
            return nil
        } catch {
            let error = error as NSError
            #expect(error.domain == "DeviceWorker")
            #expect(error.userInfo["workerCode"] as? String == code)
            #expect(error.userInfo["fatal"] as? Bool == fatal)
            #expect(!error.localizedDescription.isEmpty)
            return error
        }
    }

    @Test func chunkedJSONConnectsAndStopPreservesTheWorker() throws {
        let fixture = try Fixture(behavior: ["splitOutput": true])
        let info = try fixture.connect()
        #expect(info.udid == "phone-0")
        #expect(info.transport == "userspace-usb")
        #expect(info.effectiveUID != 0)
        #expect(fixture.worker.isConnected)
        #expect(!fixture.worker.isRunning)
        try fixture.worker.start()
        try fixture.worker.start()
        #expect(fixture.worker.isRunning)
        try fixture.worker.send(latitude: 25.033, longitude: 121.5654)
        try fixture.worker.stop()
        #expect(!fixture.worker.isRunning)
        #expect(fixture.worker.isConnected)
        try fixture.worker.clear()
        let events = try fixture.events()
        #expect(events.filter { $0["event"] as? String == "setup" }.count == 1)
        #expect(events.filter { $0["event"] as? String == "start-stream" }.count == 1)
        #expect(events.contains { $0["event"] as? String == "set" })
        #expect(events.contains { $0["event"] as? String == "clear" })
        fixture.worker.disconnect()
        #expect(!fixture.worker.isConnected)
        #expect(try fixture.events().contains { $0["event"] as? String == "disconnect" })
    }

    @Test func setWaitsForTheActualEffectBeforeAcknowledging() throws {
        let fixture = try Fixture(behavior: ["setDelay": 0.3])
        _ = try fixture.connect()
        let began = Date()
        try fixture.worker.send(latitude: 25.033, longitude: 121.5654)
        #expect(Date().timeIntervalSince(began) >= 0.25)
        #expect(try fixture.position() == [25.033, 121.5654])
    }

    @Test func wrongAcknowledgementNeverCompletesTheRequestSuccessfully() throws {
        let fixture = try Fixture(behavior: ["wrongAck": true])
        let exits = ExitRecord()
        _ = try fixture.connect(onExit: { status, error in exits.append(status, error) })
        _ = expectWorkerError("invalid_request", fatal: true) { try fixture.worker.start() }
        #expect(!fixture.worker.isConnected)
        fixture.worker.disconnect()
        #expect(exits.errors.first?.userInfo["workerCode"] as? String == "invalid_request")
    }

    @Test func setupAndRequestExitWakeTheirWaiters() throws {
        let setup = try Fixture(behavior: ["exitDuringSetup": true])
        let setupBegan = Date()
        _ = expectWorkerError("transport_lost", fatal: true) { _ = try setup.connect() }
        #expect(Date().timeIntervalSince(setupBegan) < 1.5)

        let command = try Fixture(behavior: ["exitDuringSet": true])
        _ = try command.connect()
        let requestBegan = Date()
        _ = expectWorkerError("transport_lost", fatal: true) { try command.worker.send(latitude: 25, longitude: 121) }
        #expect(Date().timeIntervalSince(requestBegan) < 1.5)
        #expect(!command.worker.isConnected)
    }

    @Test func setupAndCommandDeadlinesTerminateTheWorker() throws {
        let setup = try Fixture(behavior: ["setupDelay": 1], readyTimeout: 0.15)
        _ = expectWorkerError("timeout", fatal: true) { _ = try setup.connect() }
        #expect(!setup.worker.isConnected)
        setup.worker.disconnect()

        let command = try Fixture(behavior: ["setDelay": 1], requestTimeout: 0.15)
        _ = try command.connect()
        let began = Date()
        let error = expectWorkerError("timeout", fatal: true) { try command.worker.send(latitude: 25, longitude: 121) }
        #expect(error?.userInfo["requestID"] as? Int == 1)
        #expect(Date().timeIntervalSince(began) < 0.75)
        #expect(!command.worker.isConnected)
        command.worker.disconnect()
        #expect(!FileManager.default.fileExists(atPath: command.root.appendingPathComponent("phone-0.json").path))
    }

    @Test func setupCancellationImmediatelyReleasesConnect() async throws {
        let fixture = try Fixture(behavior: ["setupDelay": 10], readyTimeout: 20)
        let operation = Task.detached {
            do { _ = try fixture.connect(); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        try await fixture.waitForEvent("setup")
        let began = Date()
        fixture.worker.cancelPendingOperations()
        #expect(Date().timeIntervalSince(began) < 0.1)
        #expect(await operation.value)
        #expect(Date().timeIntervalSince(began) < 0.75)
        #expect(!fixture.worker.isConnected)
        fixture.worker.disconnect()
        #expect(Date().timeIntervalSince(began) < 1.5)
        #expect(try !fixture.events().contains { $0["event"] as? String == "ready" })
    }

    @Test func cancellationAtFirstRegisteredStageCannotBeLost() throws {
        let fixture = try Fixture()
        let worker = fixture.worker
        #expect(throws: CancellationError.self) {
            _ = try worker.connect(configuration: DeviceWorkerConfiguration(udid: "phone-0", connectionType: "usb", rsdHost: nil, rsdPort: nil), onStage: { _ in worker.cancelPendingOperations() }, onOutput: { _ in }, onError: { _ in }, onExit: { _, _ in })
        }
        worker.disconnect()
        #expect(try fixture.events().isEmpty)
    }

    @Test func cancelledSetRetiresItsLateACKBeforeReplacementConnects() async throws {
        let fixture = try Fixture(behavior: ["setDelay": 0.4])
        _ = try fixture.connect()
        let operation = Task.detached {
            do { try fixture.worker.send(latitude: 25.033, longitude: 121.5654); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        try await fixture.waitForEvent("set-start")
        let began = Date()
        fixture.worker.cancelPendingOperations()
        #expect(await operation.value)
        #expect(Date().timeIntervalSince(began) < 0.2)
        let replacement = try await Task.detached { try fixture.connect() }.value
        #expect(replacement.udid == "phone-0")
        let events = try fixture.events()
        let setups = events.indices.filter { events[$0]["event"] as? String == "setup" }
        let firstDisconnect = try #require(events.firstIndex { $0["event"] as? String == "disconnect" })
        #expect(setups.count == 2)
        #expect(firstDisconnect < (setups.last ?? 0))
        try fixture.worker.start()
        try fixture.worker.send(latitude: 25.043, longitude: 121.5754)
        #expect(try fixture.position() == [25.043, 121.5754])
        #expect(fixture.worker.isConnected)
        #expect(fixture.worker.isRunning)
    }

    @Test func nonfatalClearFailurePreservesTheConnectionAndStructuredError() throws {
        let fixture = try Fixture(behavior: ["clearError": true])
        _ = try fixture.connect()
        let error = expectWorkerError("operation_failed", fatal: false) { try fixture.worker.clear() }
        #expect(error?.userInfo["requestID"] as? Int == 1)
        #expect(fixture.worker.isConnected)
        try fixture.worker.send(latitude: 25, longitude: 121)
        #expect(try fixture.position() == [25, 121])
    }

    @Test func setupErrorIsPreservedForConnectAndExitWithoutStderrParsing() throws {
        let fixture = try Fixture(behavior: ["setupError": "pairing_required"])
        let exits = ExitRecord()
        let error = expectWorkerError("pairing_required", fatal: true) {
            _ = try fixture.connect(onExit: { status, error in exits.append(status, error) })
        }
        #expect(error?.userInfo["requestID"] is NSNull)
        fixture.worker.disconnect()
        #expect(exits.count == 1)
        #expect(exits.errors.first?.userInfo["workerCode"] as? String == "pairing_required")
    }

    @Test func transportLossPreservesTheFatalExitReason() async throws {
        let fixture = try Fixture(behavior: ["exitAfterReady": 0.15])
        let exits = ExitRecord()
        _ = try fixture.connect(onExit: { status, error in exits.append(status, error) })
        let deadline = Date().addingTimeInterval(2)
        while exits.count == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!fixture.worker.isConnected)
        #expect(exits.errors.first?.userInfo["workerCode"] as? String == "transport_lost")
        #expect(exits.errors.first?.userInfo["fatal"] as? Bool == true)
    }

    @Test func invalidReadyIdentityPrivilegeVersionAndEventAreRejected() throws {
        for behavior in [["readyUDID": "phone-1"] as [String: Any], ["readyEUID": 0], ["protocolVersion": 2], ["unknownEvent": true]] {
            let fixture = try Fixture(behavior: behavior)
            let code = behavior["readyUDID"] != nil ? "identity_mismatch" : "invalid_request"
            _ = expectWorkerError(code, fatal: true) { _ = try fixture.connect() }
            #expect(!fixture.worker.isConnected)
        }
    }

    @Test func invalidCoordinatesNeverReachTheWorker() throws {
        let fixture = try Fixture()
        _ = try fixture.connect()
        for (latitude, longitude) in [(Double.nan, 121.0), (25.0, Double.infinity), (90.1, 121.0), (25.0, -180.1)] {
            _ = expectWorkerError("invalid_coordinate", fatal: false) { try fixture.worker.send(latitude: latitude, longitude: longitude) }
        }
        #expect(try !fixture.events().contains { $0["event"] as? String == "set-start" })
        #expect(fixture.worker.isConnected)
    }

    @Test func incompleteManualConfigurationNeverFallsBackToAutomatic() throws {
        let fixture = try Fixture()
        for configuration in [
            DeviceWorkerConfiguration(udid: "phone-0", connectionType: "usb", rsdHost: "localhost", rsdPort: nil),
            DeviceWorkerConfiguration(udid: "phone-0", connectionType: "usb", rsdHost: nil, rsdPort: 1234),
            DeviceWorkerConfiguration(udid: "phone-0", connectionType: "usb", rsdHost: "", rsdPort: 1234),
            DeviceWorkerConfiguration(udid: "phone-0", connectionType: "usb", rsdHost: "localhost", rsdPort: 65536)
        ] {
            _ = expectWorkerError("invalid_request", fatal: true) {
                _ = try fixture.worker.connect(configuration: configuration, onStage: { _ in }, onOutput: { _ in }, onError: { _ in }, onExit: { _, _ in })
            }
        }
        #expect(try fixture.events().isEmpty)
    }

    @Test func disconnectReapsTheOwnedWorkerProcess() throws {
        let fixture = try Fixture()
        let exits = ExitRecord()
        _ = try fixture.connect(onExit: { status, error in exits.append(status, error) })
        let setup = try #require(fixture.events().first { $0["event"] as? String == "setup" })
        let pid = try #require(setup["pid"] as? Int)
        fixture.worker.disconnect()
        #expect(exits.count == 1)
        #expect(exits.errors.isEmpty)
        #expect(kill(pid_t(pid), 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func cancelledOutstandingCommandUsesItsOriginalDeadlineBeforeReaping() async throws {
        let fixture = try Fixture(behavior: ["setDelay": 5], requestTimeout: 0.25)
        _ = try fixture.connect()
        let operation = Task.detached {
            do { try fixture.worker.send(latitude: 25, longitude: 121); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        try await fixture.waitForEvent("set-start")
        let began = Date()
        fixture.worker.cancelPendingOperations()
        #expect(await operation.value)
        #expect(Date().timeIntervalSince(began) < 0.2)
        await Task.detached { fixture.worker.disconnect() }.value
        #expect(Date().timeIntervalSince(began) < 1.5)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("phone-0.json").path))
    }

    @Test func quitClearFailureStillReapsTheWorkerAndReportsItsError() throws {
        let fixture = try Fixture(behavior: ["clearError": true])
        let exits = ExitRecord()
        _ = try fixture.connect(onExit: { status, error in exits.append(status, error) })
        fixture.worker.disconnect()
        #expect(!fixture.worker.isConnected)
        #expect(exits.count == 1)
        #expect(exits.errors.first?.userInfo["workerCode"] as? String == "operation_failed")
        #expect(exits.errors.first?.userInfo["fatal"] as? Bool == false)
        #expect(exits.errors.first?.userInfo["requestID"] as? Int == 1)
    }

    @Test func mockFailuresAreObservableAndStopDoesNotDisconnect() throws {
        let worker = MockDVTLocationStream()
        let configuration = DeviceWorkerConfiguration(udid: "phone-0", connectionType: "usb", rsdHost: nil, rsdPort: nil)
        worker.shouldThrowOnConnect = true
        _ = expectWorkerError("operation_failed", fatal: false) {
            _ = try worker.connect(configuration: configuration, onStage: { _ in }, onOutput: { _ in }, onError: { _ in }, onExit: { _, _ in })
        }
        #expect(!worker.isConnected)
        worker.shouldThrowOnConnect = false
        _ = try worker.connect(configuration: configuration, onStage: { _ in }, onOutput: { _ in }, onError: { _ in }, onExit: { _, _ in })
        try worker.start()
        worker.shouldThrowOnSend = true
        _ = expectWorkerError("operation_failed", fatal: false) { try worker.send(latitude: 25, longitude: 121) }
        #expect(worker.sentCoordinates.isEmpty)
        worker.shouldThrowOnClear = true
        _ = expectWorkerError("operation_failed", fatal: false) { try worker.clear() }
        try worker.stop()
        #expect(worker.isConnected)
        #expect(!worker.isRunning)
        worker.disconnect()
        #expect(!worker.isConnected)
    }
}
