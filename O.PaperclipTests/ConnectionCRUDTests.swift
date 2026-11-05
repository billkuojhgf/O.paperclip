import Foundation
import Testing
@testable import O_Paperclip

struct ConnectionCRUDTests {
    @Test func restartDoesNotRestoreSessionIdentity() {
        let key = "restart-\(UUID().uuidString)"
        let first = DeviceManager(settingsKey: key)
        first.tunnelUDID = "old-phone"
        first.manualRsdHost = "old-host"
        first.manualRsdPort = "1234"
        let restarted = DeviceManager(settingsKey: key)
        #expect(restarted.tunnelUDID.isEmpty)
        #expect(restarted.manualRsdHost.isEmpty)
        #expect(restarted.manualRsdPort.isEmpty)
        #expect(restarted.connectionState == .disconnected)
        for suffix in ["tunnelUDID", "manualRsdHost", "manualRsdPort", "wirelessMode"] {
            UserDefaults.standard.removeObject(forKey: "paperclip.connection.\(key).\(suffix)")
        }
    }

    @MainActor
    @Test func oneDeviceThenAddWithoutRebuildingAndDeleteIndividually() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("crud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func available(_ ids: [String]) throws { try JSONEncoder().encode(ids).write(to: root.appendingPathComponent("devices.json")) }
        try available(["phone-0"])
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        let devices = (0..<3).map { _ in DeviceManager(settingsKey: "crud-\(UUID().uuidString)", cliCommand: ["/usr/bin/python3", script.path, root.path], dvtStream: DVTLocationStream(command: ["/usr/bin/python3", script.path, root.path, "worker"])) }
        let group = DeviceGroup(devices: devices)
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await group.connectDeviceAsync()
        #expect(group.isConnected && !group.isConnecting)
        #expect(devices.filter { $0.isConnected }.count == 1)
        #expect(devices[1].tunnelUDID.isEmpty && devices[2].tunnelUDID.isEmpty)
        try await group.sendLocationToDeviceAsync(latitude: 25.033, longitude: 121.5654)
        try available(["phone-0", "phone-1"])
        try await group.connectDeviceAsync()
        #expect(devices.filter { $0.isConnected }.count == 2)
        #expect(try lifecycle(at: root).filter { $0["event"] as? String == "ready" && $0["udid"] as? String == "phone-0" }.count == 1)
        let second = try JSONDecoder().decode([Double].self, from: Data(contentsOf: root.appendingPathComponent("phone-1.json")))
        #expect(second == [25.033, 121.5654])
        group.disconnectDevice(at: 0)
        await devices[0].disconnectAsync()
        #expect(devices[0].tunnelUDID.isEmpty)
        #expect(group.isConnected && devices[1].isConnected)
        await group.disconnectAsync()
        #expect(!group.isConnected && !group.isConnecting)
        #expect(devices.allSatisfy { $0.tunnelUDID.isEmpty })
    }

    @MainActor
    @Test func noDevicesEndsWithActionableFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("devices.json"))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        let devices = (0..<3).map { _ in DeviceManager(settingsKey: "empty-\(UUID().uuidString)", cliCommand: ["/usr/bin/python3", script.path, root.path], dvtStream: DVTLocationStream(command: ["/usr/bin/python3", script.path, root.path, "worker"])) }
        let group = DeviceGroup(devices: devices)
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await group.connectDeviceAsync() }
        #expect(!group.isConnecting && !group.isConnected)
        #expect(group.lastError == "未找到可連線的裝置。")
    }

    @MainActor
    @Test func discoversOnceAndConnectsThreeDevicesSequentially() async throws {
        let (root, group) = try processGroup(identifiers: ["phone-0", "phone-1", "phone-2"])
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        try await group.connectDeviceAsync()
        #expect(group.devices.allSatisfy { $0.isConnected })
        #expect(!group.isConnecting && group.lastError == nil)
        let commands = try recordedCommands(at: root)
        #expect(commands.filter { $0 == ["usbmux", "list"] }.count == 1)
        #expect(commands.filter { $0.starts(with: ["remote", "browse"]) }.count == 1)
        let events = try lifecycle(at: root)
        let starts = events.enumerated().filter { $0.element["event"] as? String == "setup" }
        #expect(starts.map { $0.element["udid"] as? String } == ["phone-0", "phone-1", "phone-2"])
        for (previous, next) in zip(starts, starts.dropFirst()) {
            #expect(events[(previous.offset + 1)..<next.offset].contains {
                $0["event"] as? String == "ready" && $0["udid"] as? String == previous.element["udid"] as? String
            })
        }
        await group.disconnectAsync()
    }

    @MainActor
    @Test func absentStaleIdentifiersAreReplacedByCurrentDiscovery() async throws {
        let (root, group) = try processGroup(identifiers: ["current-phone"])
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        for (index, device) in group.devices.enumerated() { device.tunnelUDID = "absent-\(index)" }
        try await group.connectDeviceAsync()
        #expect(group.devices.filter { $0.isConnected }.map { $0.tunnelUDID } == ["current-phone"])
        #expect(!group.isConnecting && group.lastError == nil)
        let starts = try lifecycle(at: root).filter { $0["event"] as? String == "setup" }
        #expect(starts.count == 1)
        #expect(starts.first?["udid"] as? String == "current-phone")
        await group.disconnectAsync()
    }

    @MainActor
    @Test func fourthDeviceIsReportedWithoutReplacingConnectedDevices() async throws {
        let ids = ["phone-0", "phone-1", "phone-2", "phone-3"]
        let (root, group) = try processGroup(identifiers: ids)
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        await #expect(throws: (any Error).self) { try await group.connectDeviceAsync() }
        #expect(group.devices.allSatisfy { $0.isConnected })
        #expect(group.devices.map { $0.tunnelUDID } == Array(ids.prefix(3)))
        #expect(!group.isConnecting)
        #expect(group.lastError == "最多只能連線三台裝置，其餘裝置未加入。")
        await #expect(throws: (any Error).self) { try await group.connectDeviceAsync() }
        #expect(group.lastError == "最多只能連線三台裝置。")
        let starts = try lifecycle(at: root).filter { $0["event"] as? String == "setup" }
        #expect(starts.map { $0["udid"] as? String } == Array(ids.prefix(3)))
        #expect(group.devices.allSatisfy { $0.isConnected })
        await group.disconnectAsync()
    }

    @MainActor
    @Test func disconnectDuringDelayedTunnelCancelsRemainingDevicesAndAllowsRetry() async throws {
        let (root, group) = try processGroup(identifiers: ["phone-0", "phone-1"])
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        let delay = root.appendingPathComponent("tunnel-delay-seconds")
        try Data("3".utf8).write(to: delay)
        let operation = Task { try await group.connectDeviceAsync() }
        let deadline = Date().addingTimeInterval(5)
        var tunnelStarted = false
        while Date() < deadline {
            if let events = try? lifecycle(at: root), events.contains(where: { $0["event"] as? String == "setup" }) {
                tunnelStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(tunnelStarted)
        group.disconnect()
        #expect(!group.isConnecting && !group.isConnected)
        await group.disconnectAsync()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(group.devices.allSatisfy { $0.connectionState == .disconnected && $0.tunnelUDID.isEmpty && $0.lastError == nil })
        #expect(group.lastError == nil)
        let cancelledStarts = try lifecycle(at: root).filter { $0["event"] as? String == "setup" }
        #expect(cancelledStarts.count == 1)
        #expect(cancelledStarts.first?["udid"] as? String == "phone-0")
        try FileManager.default.removeItem(at: delay)
        try await group.connectDeviceAsync()
        #expect(group.devices.filter { $0.isConnected }.count == 2)
        #expect(!group.isConnecting && group.lastError == nil)
        await group.disconnectAsync()
    }

    @MainActor
    @Test func clearDiscardsQueuedRoutePointsAndRetainsConnection() async throws {
        let (root, group) = try processGroup(identifiers: ["phone-0"])
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        try Data(#"{"setDelay":0.3}"#.utf8).write(to: root.appendingPathComponent("worker-behavior.json"))
        try await group.connectDeviceAsync()
        let device = group.devices[0]
        device.sendLocationToDevice(latitude: 25.033, longitude: 121.5654)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if try lifecycle(at: root).contains(where: { $0["event"] as? String == "set-start" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try lifecycle(at: root).contains { $0["event"] as? String == "set-start" })
        for index in 1...20 { device.sendLocationToDevice(latitude: 25.033 + Double(index) / 1000, longitude: 121.5654) }
        try await device.clearSimulatedLocationAsync()
        let events = try lifecycle(at: root)
        #expect(events.filter { $0["event"] as? String == "set" }.compactMap { $0["latitude"] as? Double } == [25.033])
        #expect(device.isConnected)
        try await device.sendLocationToDeviceAsync(latitude: 25.043, longitude: 121.5654)
        #expect(try JSONDecoder().decode([Double].self, from: Data(contentsOf: root.appendingPathComponent("phone-0.json"))) == [25.043, 121.5654])
        await group.disconnectAsync()
    }

    @MainActor
    @Test func wifiUnavailableFallsBackToSameUSBDeviceButPairingFailureDoesNot() async throws {
        for code in ["wifi_unavailable", "pairing_required"] {
            let (root, group) = try processGroup(identifiers: ["phone-0"])
            defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
            let config = ["setupError": ["userspace-wifi": code]]
            try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("worker-behavior.json"))
            if code == "wifi_unavailable" {
                try await group.connectDeviceAsync()
                #expect(group.devices[0].tunnelUDID == "phone-0")
                #expect(group.devices[0].activeConnectionLabel == "USB")
            } else {
                await #expect(throws: (any Error).self) { try await group.connectDeviceAsync() }
                #expect(!group.isConnected)
            }
            let transports = try lifecycle(at: root).filter { $0["event"] as? String == "setup" }.compactMap { $0["transport"] as? String }
            #expect(transports == (code == "wifi_unavailable" ? ["userspace-wifi", "userspace-usb"] : ["userspace-wifi"]))
            await group.disconnectAsync()
        }
    }

    @MainActor
    @Test func manualFirstSlotWorksWithoutDiscoveryAndRejectsPartialEndpoint() async throws {
        let (root, group) = try processGroup(identifiers: [])
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        group.manualRsdHost = "phone-0"
        await #expect(throws: (any Error).self) { try await group.connectDeviceAsync() }
        #expect(!group.isConnected)
        group.manualRsdPort = "12345"
        try await group.connectDeviceAsync()
        #expect(group.devices[0].activeConnectionLabel == "手動 RSD")
        #expect(group.devices[0].tunnelUDID == "phone-0")
        #expect(group.devices.filter { $0.isConnected }.count == 1)
        try await group.sendLocationToDeviceAsync(latitude: 25.033, longitude: 121.5654)
        await group.disconnectAsync()
    }

    @MainActor
    @Test func automaticReconnectStopsOnPairingFailure() async throws {
        let (root, group) = try processGroup(identifiers: ["phone-0"])
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        let behavior = root.appendingPathComponent("worker-behavior.json")
        try Data(#"{"exitAfterReady":0.3}"#.utf8).write(to: behavior)
        try await group.connectDeviceAsync()
        try Data(#"{"setupError":"pairing_required"}"#.utf8).write(to: behavior)
        let deadline = Date().addingTimeInterval(5)
        while group.devices[0].connectionState != .failed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .seconds(2.5))
        #expect(group.devices[0].connectionState == .failed)
        #expect(try lifecycle(at: root).filter { $0["event"] as? String == "setup" }.count == 2)
        await group.disconnectAsync()
    }

    @MainActor
    @Test func clearFailureThrowsWithoutDisconnecting() async throws {
        let (root, group) = try processGroup(identifiers: ["phone-0"])
        defer { group.disconnect(); try? FileManager.default.removeItem(at: root) }
        try Data(#"{"clearError":true}"#.utf8).write(to: root.appendingPathComponent("worker-behavior.json"))
        try await group.connectDeviceAsync()
        await #expect(throws: (any Error).self) { try await group.clearSimulatedLocationAsync() }
        #expect(group.isConnected)
        try await group.sendLocationToDeviceAsync(latitude: 25.043, longitude: 121.5654)
        #expect(try JSONDecoder().decode([Double].self, from: Data(contentsOf: root.appendingPathComponent("phone-0.json"))) == [25.043, 121.5654])
        await group.disconnectAsync()
    }

    @MainActor
    @Test func workerReadyDeadlineStartsAfterPreflight() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        try Data(#"{"versionDelay":0.3,"setupDelay":0.2}"#.utf8).write(to: root.appendingPathComponent("worker-behavior.json"))
        let stream = DVTLocationStream(command: ["/usr/bin/python3", script.path, root.path, "worker"], readyTimeout: 0.4, requestTimeout: 1)
        let device = DeviceManager(settingsKey: "preflight-\(UUID().uuidString)", cliCommand: ["/usr/bin/python3", script.path, root.path], dvtStream: stream)
        defer { device.disconnect(); try? FileManager.default.removeItem(at: root) }
        device.tunnelUDID = "phone-0"
        try await device.connectDeviceAsync()
        #expect(device.isConnected)
        try await device.sendLocationToDeviceAsync(latitude: 25.033, longitude: 121.5654)
        #expect(try JSONDecoder().decode([Double].self, from: Data(contentsOf: root.appendingPathComponent("phone-0.json"))) == [25.033, 121.5654])
        await device.disconnectAsync()
    }

    @MainActor
    private func processGroup(identifiers: [String]) throws -> (URL, DeviceGroup) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("connection-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(identifiers).write(to: root.appendingPathComponent("devices.json"))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        let devices = (0..<3).map { _ in DeviceManager(settingsKey: "regression-\(UUID().uuidString)", cliCommand: ["/usr/bin/python3", script.path, root.path], dvtStream: DVTLocationStream(command: ["/usr/bin/python3", script.path, root.path, "worker"])) }
        let group = DeviceGroup(devices: devices)
        group.isWirelessMode = true
        return (root, group)
    }

    private func recordedCommands(at root: URL) throws -> [[String]] {
        try String(contentsOf: root.appendingPathComponent("commands.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
    }

    private func lifecycle(at root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("lifecycle.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
}
