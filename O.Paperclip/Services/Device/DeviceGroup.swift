import Foundation
import Combine
import CoreLocation

@MainActor
final class DeviceGroup: ObservableObject, DeviceControlling {
    let objectWillChange = ObservableObjectPublisher()
    let devices: [DeviceManager]
    private var subscriptions: [AnyCancellable] = []
    @Published private var operationError: String?
    @Published private var connecting = false
    private var connectionTask: Task<Void, Never>?
    private var generation = 0
    private var lastCoordinate: CLLocationCoordinate2D?
    private var streaming = false

    nonisolated static func assignIdentifiers(requested: [String], discovered: [String]) throws -> [String] {
        let requested = requested.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let selected = requested.filter { !$0.isEmpty }
        guard Set(selected).count == selected.count else {
            throw NSError(domain: "DeviceGroup", code: 1, userInfo: [NSLocalizedDescriptionKey: "同一台裝置不能重複選取。"])
        }
        var seen = Set(selected)
        var available = discovered.filter { !$0.isEmpty && seen.insert($0).inserted }.makeIterator()
        return requested.map { $0.isEmpty ? (available.next() ?? "") : $0 }
    }

    init(devices: [DeviceManager]? = nil) {
        self.devices = devices ?? (0..<3).map { DeviceManager(settingsKey: "device\($0)") }
        precondition(self.devices.count == 3)
        for device in self.devices {
            subscriptions.append(device.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            })
        }
    }

    var connectionState: DeviceConnectionState {
        if connecting { return .connecting(step: "逐台連線中") }
        if isConnected { return .connected }
        return lastError == nil ? .disconnected : .failed
    }
    var isConnected: Bool { devices.contains { $0.isConnected } }
    var isConnecting: Bool { connecting }
    var connectionStage: String { connectionState.statusText }
    var deviceName: String { "已連線 \(devices.filter { $0.isConnected }.count)/3 台" }
    var lastError: String? { operationError ?? devices.compactMap { $0.lastError }.first }
    var debugLog: [String] {
        devices.enumerated().flatMap { index, device in device.debugLog.suffix(8).map { "[\(index + 1)] \($0)" } }
    }
    var manualRsdHost: String {
        get { devices[0].manualRsdHost }
        set { devices[0].manualRsdHost = newValue }
    }
    var manualRsdPort: String {
        get { devices[0].manualRsdPort }
        set { devices[0].manualRsdPort = newValue }
    }
    var tunnelUDID: String {
        get { devices[0].tunnelUDID }
        set { devices[0].tunnelUDID = newValue }
    }
    var isWirelessMode: Bool {
        get { devices[0].isWirelessMode }
        set { devices.forEach { $0.isWirelessMode = newValue } }
    }

    func connectDevice() { connectDevice(selected: nil) }

    func connectDevice(selected: [String]?) {
        guard !connecting else { return }
        generation += 1
        let current = generation
        connecting = true
        operationError = nil
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == current { self.connecting = false; self.connectionTask = nil }
            }
            do {
                if selected == nil && !self.devices[0].isConnected && (!self.manualRsdHost.isEmpty || !self.manualRsdPort.isEmpty) {
                    try await self.devices[0].connectDeviceAsync()
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    if self.streaming { self.devices[0].startContinuousLocationStream() }
                    if let coordinate = self.lastCoordinate {
                        try await self.devices[0].sendLocationToDeviceAsync(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    }
                }
                let identifiers: [String]
                if let selected {
                    identifiers = selected
                } else {
                    identifiers = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                        self.devices[0].discoverDeviceIdentifiers { continuation.resume(with: $0) }
                    }
                }
                try Task.checkCancellation()
                guard self.generation == current else { return }
                let occupied = Set(self.devices.filter { $0.isConnected || $0.isConnecting }.map { $0.tunnelUDID })
                var seen = occupied
                let candidates = identifiers.filter { !$0.isEmpty && seen.insert($0).inserted }
                let slots = self.devices.filter { !$0.isConnected && !$0.isConnecting }
                guard !slots.isEmpty else { self.operationError = "最多只能連線三台裝置。"; return }
                if selected != nil && candidates.count > slots.count {
                    self.operationError = "最多只能連線三台裝置。"
                    return
                }
                guard !candidates.isEmpty else {
                    if self.devices[0].activeConnectionLabel == "手動 RSD" { return }
                    self.operationError = self.isConnected ? "沒有新的可連線裝置。" : "未找到可連線的裝置。"
                    return
                }
                for (device, identifier) in zip(slots, candidates) {
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    device.tunnelUDID = identifier
                    do {
                        try await device.connectDeviceAsync()
                        try Task.checkCancellation()
                        if self.streaming { device.startContinuousLocationStream() }
                        if let coordinate = self.lastCoordinate {
                            try await device.sendLocationToDeviceAsync(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard self.generation == current else { return }
                        self.operationError = "裝置 \(identifier) 連線失敗：\(error.localizedDescription)"
                    }
                }
                guard self.generation == current else { return }
                if candidates.count > slots.count { self.operationError = "最多只能連線三台裝置，其餘裝置未加入。" }
            } catch is CancellationError { }
            catch { if self.generation == current { self.operationError = error.localizedDescription } }
        }
    }

    func disconnectDevice(at index: Int) {
        guard devices.indices.contains(index) else { return }
        devices[index].disconnect()
        devices[index].tunnelUDID = ""
        devices[index].manualRsdHost = ""
        devices[index].manualRsdPort = ""
    }
    func disconnect() {
        generation += 1
        connectionTask?.cancel()
        connectionTask = nil
        connecting = false
        operationError = nil
        for index in devices.indices { disconnectDevice(at: index) }
        lastCoordinate = nil
        streaming = false
    }
    func sendLocationToDevice(latitude: Double, longitude: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        lastCoordinate = coordinate
        devices.forEach { $0.sendLocationToDevice(latitude: latitude, longitude: longitude) }
    }
    func startContinuousLocationStream() { streaming = true; devices.forEach { $0.startContinuousLocationStream() } }
    func stopContinuousLocationStream() { streaming = false; devices.forEach { $0.stopContinuousLocationStream() } }
    func clearSimulatedLocation() { lastCoordinate = nil; streaming = false; devices.forEach { $0.clearSimulatedLocation() } }
    func connectDeviceAsync() async throws {
        let (operation, current) = await MainActor.run { connectDevice(); return (connectionTask, generation) }
        await operation?.value
        try Task.checkCancellation()
        let (cancelled, failure) = await MainActor.run { (generation != current, operationError) }
        if cancelled { throw CancellationError() }
        if let failure { throw NSError(domain: "DeviceGroup", code: 3, userInfo: [NSLocalizedDescriptionKey: failure]) }
    }
    func disconnectAsync() async {
        await MainActor.run { disconnect() }
        for device in devices { await device.disconnectAsync() }
    }
    func sendLocationToDeviceAsync(latitude: Double, longitude: Double) async throws {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { throw NSError(domain: "DeviceGroup", code: 4, userInfo: [NSLocalizedDescriptionKey: "座標無效。寬度或經度超出範圍。正常座標才可發送。" ]) }
        let selected = await MainActor.run { lastCoordinate = coordinate; return devices.filter { $0.isConnected } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for device in selected { group.addTask { try await device.sendLocationToDeviceAsync(latitude: latitude, longitude: longitude) } }
            try await group.waitForAll()
        }
    }
    func clearSimulatedLocationAsync() async throws {
        await MainActor.run { lastCoordinate = nil; streaming = false }
        var failure: Error?
        for device in devices where device.isConnected {
            do { try await device.clearSimulatedLocationAsync() } catch { failure = error }
        }
        if let failure { throw failure }
    }
}
