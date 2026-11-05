import CoreLocation
import Foundation
import MapKit
import Testing
@testable import O_Paperclip

@MainActor
struct ImportedAndSavedLocationTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ImportedAndSavedLocationTests-\(UUID().uuidString)")!
    }

    private func parse(_ xml: String) throws -> [ImportedGPXRoute] {
        try GPXRouteParser.parse(data: Data(xml.utf8), fallbackTitle: "備用名稱", sourceName: "route.gpx", stableIDPrefix: "test", sourceFilePath: nil)
    }

    @Test func gpxTracksAndRoutesKeepTheirGeometryAndNames() throws {
        let routes = try parse("""
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>測試文件</name></metadata>
          <trk><name>山路</name><trkseg>
            <trkpt lat="25" lon="121"/><trkpt lat="25" lon="121"/>
            <trkpt lat="91" lon="121"/><trkpt lat="nan" lon="121"/>
            <trkpt lat="25.001" lon="121"/>
          </trkseg></trk>
          <rte><rtept lat="-90" lon="-180"/><rtept lat="90" lon="180"/></rte>
        </gpx>
        """)
        #expect(routes.count == 2)
        #expect(routes[0].title == "山路")
        #expect(routes[0].points.map(\.latitude) == [25, 25.001])
        #expect(routes[0].totalDistance > 110 && routes[0].totalDistance < 112)
        #expect(routes[1].title == "測試文件 路線 2")
        #expect(routes[1].points.map(\.longitude) == [-180, 180])
    }

    @Test func invalidOrInsufficientGPXCannotBecomeARoute() {
        for xml in ["<gpx><trk>", "<gpx/>", "<gpx><wpt lat=\"25\" lon=\"121\"/></gpx>", "<gpx><rte><rtept lat=\"25\" lon=\"121\"/><rtept lat=\"25\" lon=\"121\"/><rtept lat=\"25\" lon=\"181\"/></rte></gpx>"] {
            #expect(throws: (any Error).self) { try parse(xml) }
        }
    }

    @Test func importedRouteIsReadyWithoutDirectionsAndPendingCalculationCannotOverwriteIt() throws {
        let calculator = PendingDirections()
        let vm = AppViewModel(deviceManager: DeviceGroup(), locationSearchService: LocationSearchService(), routeCalculator: calculator, defaults: defaults())
        vm.insertPoint(CLLocationCoordinate2D(latitude: 24, longitude: 120))
        vm.insertPoint(CLLocationCoordinate2D(latitude: 24.1, longitude: 120))
        #expect(vm.appState == .calculatingRoute)
        let imported = try #require(parse("<gpx><rte><rtept lat=\"25\" lon=\"121\"/><rtept lat=\"25.001\" lon=\"121\"/></rte></gpx>").first)
        vm.useImportedGPXRoute(imported)
        #expect(vm.consumeProgrammaticModeResetSuppression())
        calculator.completion?(nil, NSError(domain: "OldDirections", code: 1))
        #expect(vm.operationMode == .multiPoint)
        #expect(vm.hasReadyDraft)
        #expect(vm.draftRoutePoints.map(\.latitude) == [25, 25.001])
        #expect(vm.hasDraftEdits)
        #expect(vm.waypoints.map(\.latitude) == [25, 25.001])
        #expect(vm.customRoutePolyline?.pointCount == 2)
        #expect(vm.draftTotalRouteDistance > 110)
        #expect(vm.locationInputError == nil)
        #expect(calculator.requests == 1)
    }

    @Test func gpxNamingAndPersistenceSurviveSourceRemoval() throws {
        let preferences = defaults()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).gpx")
        let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("gpx-snapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: snapshots) }
        try Data("<gpx><trk><trkseg><trkpt lat=\"25\" lon=\"121\"/><trkpt lat=\"25.001\" lon=\"121\"/></trkseg></trk></gpx>".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = AppViewModel(deviceManager: DeviceGroup(), locationSearchService: LocationSearchService(), defaults: preferences, savedItemsDirectory: snapshots)
        vm.prepareImportedGPXRoutes(from: [url, url])
        #expect(vm.pendingImportedGPXRoutes.count == 1)
        let pending = try #require(vm.pendingImportedGPXRoutes.first)
        vm.pendingImportedGPXRouteTitles[pending.id] = "  每日散步  "
        vm.finalizeImportedGPXRoutes()
        let saved = try #require(vm.importedGPXRoutes.first)
        defer { vm.removeImportedGPXRoute(saved) }
        try FileManager.default.removeItem(at: url)
        #expect(!vm.isShowingImportedGPXRouteNamingSheet)
        let reloaded = try #require(ImportedGPXRouteStore.loadRoutes(defaults: preferences).first)
        #expect(reloaded.title == "每日散步")
        #expect(reloaded.points.map(\.latitude) == [25, 25.001])
        vm.useImportedGPXRoute(reloaded)
        vm.removeImportedGPXRoute(reloaded)
        #expect(!vm.hasReadyDraft)
        #expect(ImportedGPXRouteStore.loadRoutes(defaults: preferences).isEmpty)
        vm.prepareImportedGPXRoutes(from: [url])
        #expect(vm.gpxImportError != nil)
        #expect(!vm.isShowingImportedGPXRouteNamingSheet)
        #expect(vm.pendingImportedGPXRoutes.isEmpty)
    }

    @Test func favoritesSaveRenameReloadAndApplyWithoutDisconnectingDeviceGroup() async throws {
        let preferences = defaults()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("saved-location-devices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let endpoint = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SimulatorEvidence/device_endpoint.py")
        let devices = (0..<3).map { index in
            let device = DeviceManager(settingsKey: "saved-\(UUID().uuidString)", cliCommand: ["/usr/bin/python3", endpoint.path, root.path], dvtStream: DVTLocationStream(command: ["/usr/bin/python3", endpoint.path, root.path, "worker"]))
            device.tunnelUDID = "phone-\(index)"
            return device
        }
        let group = DeviceGroup(devices: devices)
        let vm = AppViewModel(deviceManager: group, locationSearchService: LocationSearchService(), defaults: preferences, savedItemsDirectory: root.appendingPathComponent("favorites"))
        defer {
            vm.cleanup()
            group.disconnect()
            for item in vm.savedLocations { vm.removeSavedLocation(item) }
            try? FileManager.default.removeItem(at: root)
        }
        try await group.connectDeviceAsync()
        #expect(devices.allSatisfy { $0.isConnected })
        vm.operationMode = .fixedPoint
        vm.insertPoint(CLLocationCoordinate2D(latitude: 25.033, longitude: 121.5654))
        #expect(vm.currentSavableItemPreview.kind == .point)
        vm.prepareSaveCurrentSelection()
        // The sheet saves its captured preview, not subsequent map edits.
        vm.insertPoint(CLLocationCoordinate2D(latitude: 24, longitude: 120))
        vm.pendingSavedLocationTitle = "台北定點"
        vm.confirmSaveCurrentSelection()
        let point = try #require(vm.savedLocations.first)
        #expect(point.coordinates.first?.latitude == 25.033)
        vm.beginRenamingSavedLocation(point)
        vm.pendingSavedLocationTitle = "  收藏定點  "
        vm.confirmRenameSavedLocation()
        let renamed = try #require(SavedLocationStore.loadItems(defaults: preferences).first)
        #expect(renamed.title == "收藏定點")
        #expect(renamed.regionGroup == .taiwan)
        vm.applySavedLocation(renamed)
        #expect(vm.hasReadyDraft)
        #expect(vm.pointA?.latitude == 25.033)
        vm.handleMainAction()
        #expect(vm.hasActiveRouteSnapshot)
        let route = try #require(parse("<gpx><rte><rtept lat=\"25\" lon=\"121\"/><rtept lat=\"25.001\" lon=\"121\"/><rtept lat=\"25\" lon=\"121\"/></rte></gpx>").first)
        vm.useImportedGPXRoute(route)
        #expect(vm.currentSavableItemPreview.kind == .point)
        vm.resetActiveSession()
        #expect(vm.currentSavableItemPreview.kind == .loop)
        vm.prepareSaveCurrentSelection()
        vm.pendingSavedLocationTitle = "散步迴路"
        vm.confirmSaveCurrentSelection()
        let loop = try #require(SavedLocationStore.loadItems(defaults: preferences).first { $0.kind == .loop })
        vm.applySavedLocation(loop)
        #expect(vm.hasReadyDraft)
        #expect(vm.isClosedLoop)
        #expect(vm.draftRoutePoints.map(\.latitude) == [25, 25.001, 25])
        #expect(vm.hasDraftEdits)
        #expect(vm.waypoints.map(\.latitude) == [25, 25.001, 25])
        #expect(vm.customRoutePolyline?.pointCount == 3)
        vm.resetAll()
        vm.applySavedLocation(renamed)
        vm.handleMainAction()
        vm.applySavedLocation(loop)
        #expect(vm.hasActiveRouteSnapshot)
        #expect(vm.activeOperationMode == .fixedPoint)
        #expect(vm.currentPosition?.latitude == 25.033)
        #expect(vm.hasReadyDraft)
        #expect(vm.isClosedLoop)
        vm.removeSavedLocation(loop)
        #expect(SavedLocationStore.loadItems(defaults: preferences).allSatisfy { $0.id != loop.id })
        #expect(devices.allSatisfy { $0.isConnected })
        await group.disconnectAsync()
    }

    @Test func installedV121SnapshotsRemainReadable() throws {
        let preferences = defaults()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v121-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("""
        {"id":"installed-favorite","title":"原有收藏","kind":"route","coordinates":[{"latitude":25,"longitude":121},{"latitude":25.001,"longitude":121}],"totalDistance":111,"createdAt":700000000,"regionGroup":"taiwan","sourceMode":"固定路線"}
        """.utf8).write(to: url)
        preferences.set([url.path], forKey: "saved-location-paths")
        let item = try #require(SavedLocationStore.loadItems(defaults: preferences).first)
        let vm = AppViewModel(deviceManager: DeviceGroup(), locationSearchService: LocationSearchService(), defaults: preferences)
        vm.applySavedLocation(item)
        #expect(vm.hasReadyDraft)
        #expect(vm.operationMode == .multiPoint)
        #expect(vm.draftTotalRouteDistance == 111)
        #expect(vm.draftRoutePoints.map(\.latitude) == [25, 25.001])
        try Data("""
        {"id":"installed-gpx","title":"原有 GPX","sourceName":"original.gpx","points":[{"latitude":25,"longitude":121},{"latitude":25.001,"longitude":121}],"totalDistance":111,"sourceRouteID":"trk-0"}
        """.utf8).write(to: url)
        preferences.set([url.path], forKey: "imported-gpx-route-paths")
        preferences.set([url.path: "自訂 GPX 名稱"], forKey: "imported-gpx-route-titles")
        let imported = try #require(ImportedGPXRouteStore.loadRoutes(defaults: preferences).first)
        #expect(imported.title == "自訂 GPX 名稱")
        vm.useImportedGPXRoute(imported)
        #expect(vm.hasReadyDraft)
        #expect(vm.selectedImportedGPXRouteID == "installed-gpx")
    }
}

private final class PendingDirections: RouteCalculating {
    var requests = 0
    var completion: ((MKDirections.Response?, (any Error)?) -> Void)?
    func calculate(request: MKDirections.Request, completion: @escaping (MKDirections.Response?, (any Error)?) -> Void) {
        requests += 1
        self.completion = completion
    }
}
