import Foundation
import Testing
import CoreLocation
@testable import O_Paperclip

struct DeviceGroupTests {
    @Test func assignmentPreservesRequestedIdentityAndDeduplicatesDiscovery() throws {
        let result = try DeviceGroup.assignIdentifiers(requested: ["phone-b", "", ""], discovered: ["phone-a", "phone-b", "phone-a", "phone-c", "phone-d"])
        #expect(result == ["phone-b", "phone-a", "phone-c"])
    }

    @Test func duplicateRequestedDevicesAreRejected() {
        #expect(throws: (any Error).self) {
            try DeviceGroup.assignIdentifiers(requested: ["phone-a", "phone-a", ""], discovered: ["phone-b"])
        }
    }

    @MainActor
    @Test func stoppingGroupStopsAllRunningStreams() async throws {
        let streams = (0..<3).map { _ in MockDVTLocationStream() }
        for stream in streams { stream.isConnected = true; stream.isRunning = true }
        let devices = streams.map { DeviceManager(settingsKey: "stop-\(UUID().uuidString)", dvtStream: $0) }
        let group = DeviceGroup(devices: devices)
        group.stopContinuousLocationStream()
        let deadline = Date().addingTimeInterval(3)
        while streams.contains(where: { $0.isRunning }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(streams.allSatisfy { !$0.isRunning && $0.stopCallCount == 1 })
        #expect(streams.allSatisfy { $0.isConnected })
    }

    @MainActor
    @Test func threeProcessEndpointsReceiveSamePositionOverBothModes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paperclip-endpoints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        let devices = (0..<3).map { index in
            let device = DeviceManager(settingsKey: "test-\(UUID().uuidString)", cliCommand: ["/usr/bin/python3", script.path, root.path], dvtStream: DVTLocationStream(command: ["/usr/bin/python3", script.path, root.path, "worker"]))
            device.tunnelUDID = "phone-\(index)"
            return device
        }
        let group = DeviceGroup(devices: devices)
        defer { group.disconnect() }
        for wireless in [false, true] {
            group.isWirelessMode = wireless
            try await group.connectDeviceAsync()
            #expect(group.isConnected)
            try await group.sendLocationToDeviceAsync(latitude: 25.033, longitude: 121.5654)
            for index in 0..<3 {
                let data = try Data(contentsOf: root.appendingPathComponent("phone-\(index).json"))
                let position = try JSONDecoder().decode([Double].self, from: data)
                #expect(position == [25.033, 121.5654])
            }
            group.stopContinuousLocationStream()
            try await group.clearSimulatedLocationAsync()
            let events = try String(contentsOf: root.appendingPathComponent("lifecycle.jsonl"), encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            for index in 0..<3 {
                #expect(events.contains { $0["event"] as? String == "ready" && $0["udid"] as? String == "phone-\(index)" && $0["transport"] as? String == (wireless ? "userspace-wifi" : "userspace-usb") })
                #expect(events.contains { $0["event"] as? String == "clear" && $0["udid"] as? String == "phone-\(index)" })
            }
            await devices[1].disconnectAsync()
            #expect(group.isConnected)
            #expect(devices[0].isConnected && devices[2].isConnected)
            await group.disconnectAsync()
            #expect(devices.allSatisfy { !$0.isConnected })
        }
    }

    @MainActor
    @Test func simulatorCoreLocationFollowsAppRouteAndStops() async throws {
        let config = try String(contentsOfFile: "/tmp/paperclip-simulator-evidence-path", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = URL(fileURLWithPath: config)
        let observers = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("observers.json")))
        try #require(observers.count == 3, "驗收必須包含三個 Simulator。")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        let devices = (0..<3).map { index in
            let device = DeviceManager(settingsKey: "sim-\(UUID().uuidString)", cliCommand: ["/usr/bin/python3", script.path, root.path], dvtStream: DVTLocationStream(command: ["/usr/bin/python3", script.path, root.path, "worker"]))
            device.tunnelUDID = "phone-\(index)"
            return device
        }
        let group = DeviceGroup(devices: devices)
        let vm = AppViewModel(deviceManager: group, locationSearchService: LocationSearchService())
        defer { vm.stopSimulation(keepPinned: false); group.disconnect() }
        try await group.connectDeviceAsync()
        let started = Date().timeIntervalSince1970
        try await group.sendLocationToDeviceAsync(latitude: 25.033, longitude: 121.5654)
        func rows(_ path: String) throws -> [[String: Double]] {
            guard FileManager.default.fileExists(atPath: path) else { return [] }
            return try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map {
                try JSONDecoder().decode([String: Double].self, from: Data($0.utf8))
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if try observers.values.allSatisfy({ path in
                try rows(path).contains { ($0["received"] ?? 0) >= started && abs(($0["latitude"] ?? 0) - 25.033) < 0.00001 && abs(($0["longitude"] ?? 0) - 121.5654) < 0.00001 }
            }) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        for path in observers.values {
            #expect(try rows(path).contains { ($0["received"] ?? 0) >= started && abs(($0["latitude"] ?? 0) - 25.033) < 0.00001 })
        }
        vm.activeOperationMode = .routeAB
        vm.currentRoutePoints = [CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654), CLLocationCoordinate2D(latitude: 25.043, longitude: 121.5654)]
        vm.cumulativeRouteDistances = [0, 1110]
        vm.totalRouteDistance = 1110
        vm.speed = 36
        vm.currentPosition = vm.currentRoutePoints[0]
        vm.startSimulation()
        try await Task.sleep(for: .seconds(7))
        vm.stopSimulation(keepPinned: true)
        try await Task.sleep(for: .seconds(4))
        let stopped = Date().timeIntervalSince1970
        let latitude = try #require(vm.currentPosition?.latitude)
        try await Task.sleep(for: .seconds(5))
        for path in observers.values {
            let values = try rows(path)
            #expect(values.contains { ($0["received"] ?? 0) >= started && ($0["latitude"] ?? 0) > 25.0331 })
            let afterStop = values.filter { ($0["received"] ?? 0) >= stopped }
            #expect(!afterStop.isEmpty)
            #expect(afterStop.allSatisfy { abs(($0["latitude"] ?? 0) - latitude) < 0.00002 })
        }
    }
}
