import Foundation
import MapKit
import Testing
@testable import O_Paperclip

private final class CrossFeatureRoute: MKRoute {
    private let geometry: MKPolyline
    init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
        var points = [from, to]
        geometry = MKPolyline(coordinates: &points, count: points.count)
        super.init()
    }
    override var polyline: MKPolyline { geometry }
    override var distance: CLLocationDistance { 100 }
}

private final class CrossFeatureRouteResponse: MKDirections.Response {
    private let fixture: MKRoute
    init(_ route: MKRoute) { fixture = route; super.init() }
    override var routes: [MKRoute] { [fixture] }
}

private final class CrossFeatureRouteCalculator: RouteCalculating {
    func calculate(request: MKDirections.Request, completion: @escaping (MKDirections.Response?, (any Error)?) -> Void) {
        guard let from = request.source?.placemark.coordinate,
              let to = request.destination?.placemark.coordinate else {
            completion(nil, CocoaError(.fileReadUnknown))
            return
        }
        completion(CrossFeatureRouteResponse(CrossFeatureRoute(from: from, to: to)), nil)
    }
}

@MainActor
struct CrossFeatureQATests {
    @Test("QA-03: overlay import/filter/focus, fixed/route edits/reset and group disconnect preserve unrelated state")
    func overlayRouteAndDeviceStateRemainIndependent() async throws {
        let namespace = "CrossFeatureQA-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(namespace, isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: namespace))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settingsKeys = (0..<3).map { "\(namespace)-\($0)" }
        defer {
            defaults.removePersistentDomain(forName: namespace)
            for key in settingsKeys {
                UserDefaults.standard.removeObject(forKey: "paperclip.connection.\(key).wirelessMode")
            }
            try? FileManager.default.removeItem(at: root)
        }
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        let group = DeviceGroup(devices: settingsKeys.map {
            DeviceManager(settingsKey: $0, cliCommand: ["/usr/bin/python3", script.path, root.path])
        })
        // Reuse the process transport fixture; no physical device or privileged USB tunnel.
        group.isWirelessMode = true
        let vm = AppViewModel(deviceManager: group, locationSearchService: LocationSearchService(), routeCalculator: CrossFeatureRouteCalculator())
        defer { vm.stopSimulation(keepPinned: false); group.disconnect() }
        try await group.connectDeviceAsync()
        #expect(group.devices.allSatisfy { $0.isConnected })

        let source = root.appendingPathComponent("places.kml")
        try Data("""
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Places</name>
        <Folder><name>Cafe</name><Placemark><name>Morning coffee</name><Point><coordinates>121.5,25,0</coordinates></Point></Placemark></Folder>
        <Folder><name>Park</name><Placemark><name>Riverside</name><Point><coordinates>121.6,25.1,0</coordinates></Point></Placemark></Folder>
        </Document></kml>
        """.utf8).write(to: source)
        let preview = try ImportedPurePointOverlayStore.previewOverlays(from: [source])
        #expect(ImportedPurePointOverlayStore.loadOverlays(defaults: defaults).isEmpty)
        let imported = try ImportedPurePointOverlayStore.persistImportedOverlays(preview.map { $0.renamed(to: "Weekend") }, directoryURL: root.appendingPathComponent("snapshots"))
        ImportedPurePointOverlayStore.savePaths(imported.compactMap(\.sourceFilePath), defaults: defaults)
        ImportedPurePointOverlayStore.saveTitleOverrides(Dictionary(uniqueKeysWithValues: imported.map { ($0.sourceFilePath!, $0.title) }), defaults: defaults)
        try FileManager.default.removeItem(at: source)
        let overlay = try #require(ImportedPurePointOverlayStore.loadOverlays(defaults: defaults).first)
        #expect(overlay.title == "Weekend")
        #expect(overlay.points.count == 2)
        var filter = try #require(ContentView.makeOverlayStates(for: [overlay])[overlay.id])
        let coffee = try #require(overlay.points.first { $0.name == "Morning coffee" })
        filter.selectedCategoryIDs = [coffee.categoryID]
        #expect(filter.visiblePoints(in: overlay).map(\.name) == ["Morning coffee"])
        let focused = vm.mapRegion(fitting: filter.visiblePoints(in: overlay).map(\.coordinate))
        #expect(abs(focused.center.latitude - 25) < 1e-9)
        #expect(abs(focused.center.longitude - 121.5) < 1e-9)
        // Simulate the persisted camera after the user pans away from the overlay focus.
        defaults.set(24.5, forKey: "map.center.lat")
        defaults.set(121.2, forKey: "map.center.lon")
        defaults.set(0.2, forKey: "map.span.lat")
        defaults.set(0.3, forKey: "map.span.lon")

        func expectOverlayAndCameraPreserved() throws {
            let reloaded = try #require(ImportedPurePointOverlayStore.loadOverlays(defaults: defaults).first)
            #expect(reloaded.id == overlay.id)
            #expect(reloaded.title == "Weekend")
            #expect(reloaded.points.count == 2)
            filter.reconcile(with: reloaded)
            #expect(filter.isEnabled)
            #expect(filter.visiblePoints(in: reloaded).map(\.name) == ["Morning coffee"])
            let camera = PersistedMapRegionStore.load(defaults: defaults)
            #expect(camera.center.latitude == 24.5)
            #expect(camera.center.longitude == 121.2)
            #expect(camera.span.latitudeDelta == 0.2)
            #expect(camera.span.longitudeDelta == 0.3)
        }

        vm.operationMode = .fixedPoint
        vm.insertPoint(coffee.coordinate)
        vm.handleMainAction()
        #expect(vm.activeOperationMode == .fixedPoint)
        #expect(vm.isActiveSimulationRunning)
        #expect(vm.currentPosition?.latitude == coffee.latitude)
        #expect(group.devices.allSatisfy { $0.isConnected })
        try expectOverlayAndCameraPreserved()

        vm.operationMode = .routeAB
        vm.switchModePreservingPinnedLocation()
        vm.insertPoint(CLLocationCoordinate2D(latitude: 25.01, longitude: 121.5))
        vm.insertPoint(CLLocationCoordinate2D(latitude: 25.02, longitude: 121.5))
        #expect(vm.appState == .routeSelection)
        vm.handleMainAction()
        #expect(vm.appState == .readyToMove)
        #expect(vm.activeOperationMode == .fixedPoint)
        #expect(vm.currentPosition?.latitude == coffee.latitude)
        vm.handleMainAction()
        #expect(vm.isShowingRouteReplacementConfirmation)
        vm.confirmRouteReplacement()
        #expect(vm.activeOperationMode == .routeAB)
        #expect(vm.isActiveSimulationRunning)
        vm.speed = 36
        vm.advanceSimulation(by: 1)
        #expect(vm.traveledDistance == 10)
        #expect((vm.currentPosition?.latitude ?? 0) > 25.01)
        try expectOverlayAndCameraPreserved()

        vm.resetAll()
        #expect(vm.pointA == nil && vm.pointB == nil)
        #expect(vm.isActiveSimulationRunning)
        #expect(vm.traveledDistance == 10)
        vm.resetActiveSession()
        #expect(!vm.hasActiveRouteSnapshot)
        #expect(!vm.isActiveSimulationRunning)
        #expect(vm.currentPosition == nil)
        #expect(group.devices.allSatisfy { $0.isConnected })
        try expectOverlayAndCameraPreserved()

        // Filter edits do not disconnect any device or rebuild a cleared route.
        filter.selectedCategoryIDs.removeAll()
        #expect(filter.visiblePoints(in: overlay).isEmpty)
        filter.selectedCategoryIDs = [coffee.categoryID]
        #expect(group.devices.allSatisfy { $0.isConnected })
        #expect(!vm.hasActiveRouteSnapshot)
        vm.operationMode = .fixedPoint
        vm.switchModePreservingPinnedLocation()
        vm.insertPoint(coffee.coordinate)
        vm.handleMainAction()
        #expect(vm.isActiveSimulationRunning)
        await group.disconnectAsync()
        vm.handleDeviceDisconnected()
        #expect(!group.isConnected && !group.isConnecting)
        #expect(group.devices.allSatisfy { $0.tunnelUDID.isEmpty })
        #expect(!vm.isActiveSimulationRunning)
        #expect(vm.shouldResumeActiveAfterReconnect)
        try expectOverlayAndCameraPreserved()
    }

    @Test("Route motion boundaries: single endpoint, ping-pong reversal and circular wrap")
    func motionBoundaries() throws {
        let points = [CLLocationCoordinate2D(latitude: 0, longitude: 0), CLLocationCoordinate2D(latitude: 0, longitude: 1), CLLocationCoordinate2D(latitude: 1, longitude: 1)]
        let distances = [0.0, 100, 200]
        for mode in [RouteMotionEngine.LoopMode.singlePass, .pingPong, .circular] {
            #expect(RouteMotionEngine.targetDistance(traveledDistance: 1, routeDistance: 0, loopMode: mode) == nil)
            #expect(RouteMotionEngine.targetDistance(traveledDistance: 0, routeDistance: 200, loopMode: mode) == 0)
        }
        let singleEnd = try #require(RouteMotionEngine.targetDistance(traveledDistance: 200, routeDistance: 200, loopMode: .singlePass))
        #expect(RouteMotionEngine.coordinate(at: singleEnd, in: points, distances: distances)?.latitude == 1)
        #expect(RouteMotionEngine.targetDistance(traveledDistance: 200.nextUp, routeDistance: 200, loopMode: .singlePass) == nil)
        for (traveled, expected) in [(200.0, 200.0), (250, 150), (400, 0), (450, 50)] {
            let target = try #require(RouteMotionEngine.targetDistance(traveledDistance: traveled, routeDistance: 200, loopMode: .pingPong))
            #expect(target == expected)
            let position = try #require(RouteMotionEngine.coordinate(at: target, in: points, distances: distances))
            #expect(position.latitude == max(0, (expected - 100) / 100))
            #expect(position.longitude == min(1, expected / 100))
        }
        for (traveled, expected) in [(200.0, 0.0), (250, 50), (600, 0), (650, 50)] {
            let target = try #require(RouteMotionEngine.targetDistance(traveledDistance: traveled, routeDistance: 200, loopMode: .circular))
            #expect(target == expected)
            let position = try #require(RouteMotionEngine.coordinate(at: target, in: points, distances: distances))
            #expect(position.latitude == 0)
            #expect(position.longitude == expected / 100)
        }
    }
}
