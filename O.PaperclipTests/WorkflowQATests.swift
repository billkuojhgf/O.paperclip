import Combine
import Foundation
import MapKit
import Testing
@testable import O_Paperclip

private final class WorkflowDevice: DeviceControlling {
    let objectWillChange = ObservableObjectPublisher()
    var connectionState: DeviceConnectionState = .connected
    var logEntries: [String] = []
    var lastSentCoordinate: CLLocationCoordinate2D?
    var debugLog: [String] = []
    var isConnected = true
    var isConnecting = false
    var connectionStage = ""
    var deviceName = "QA"
    var lastError: String?
    var manualRsdHost = ""
    var manualRsdPort = ""
    var tunnelUDID = ""
    var isWirelessMode = false
    var sent: [CLLocationCoordinate2D] = []
    var starts = 0
    var stops = 0
    var clears = 0
    var didClear: (() -> Void)?
    func connect() {}
    func connectDevice() {}
    func disconnect() { isConnected = false }
    func sendCoordinate(latitude: Double, longitude: Double) { sendLocationToDevice(latitude: latitude, longitude: longitude) }
    func sendLocationToDevice(latitude: Double, longitude: Double) {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        sent.append(coordinate)
        lastSentCoordinate = coordinate
    }
    func startContinuousLocationStream() { starts += 1 }
    func stopContinuousLocationStream() { stops += 1 }
    func clearSimulatedLocation() { clears += 1; didClear?() }
    func connectDeviceAsync() async throws { isConnected = true }
    func disconnectAsync() async { disconnect() }
    func sendLocationToDeviceAsync(latitude: Double, longitude: Double) async throws { sendLocationToDevice(latitude: latitude, longitude: longitude) }
    func clearSimulatedLocationAsync() async throws { clearSimulatedLocation() }
}

@MainActor
private final class WorkflowSearch: LocationSearching {
    let objectWillChange = ObservableObjectPublisher()
    var completions: [MKLocalSearchCompletion] = []
    var completerError: String?
    var results: [MKMapItem] = []
    var failure = false
    var handler: ((String) async throws -> [MKMapItem])?
    var clears = 0
    func updateQuery(_ query: String, region: MKCoordinateRegion?) {}
    func clearSuggestions() { completions = []; clears += 1 }
    func search(for query: String, region: MKCoordinateRegion?) async throws -> [MKMapItem] {
        if let handler { return try await handler(query) }
        if failure { throw NSError(domain: "QA", code: 1) }
        return results
    }
    func search(for completion: MKLocalSearchCompletion, region: MKCoordinateRegion?) async throws -> [MKMapItem] {
        try await search(for: completion.title, region: region)
    }
}

private final class WorkflowRoute: MKRoute {
    private let geometry: MKPolyline
    init(_ coordinates: [CLLocationCoordinate2D]) {
        var coordinates = coordinates
        geometry = MKPolyline(coordinates: &coordinates, count: coordinates.count)
        super.init()
    }
    override var polyline: MKPolyline { geometry }
    override var distance: CLLocationDistance { 100 }
}

private final class WorkflowResponse: MKDirections.Response {
    private let fixtures: [MKRoute]
    init(_ routes: [MKRoute]) { fixtures = routes; super.init() }
    override var routes: [MKRoute] { fixtures }
}

private final class WorkflowCalculator: RouteCalculating {
    var requests: [MKDirections.Request] = []
    var pending: [(MKDirections.Response?, (any Error)?) -> Void] = []
    var automatic = true
    var malformed = false
    var fails = false
    func calculate(request: MKDirections.Request, completion: @escaping (MKDirections.Response?, (any Error)?) -> Void) {
        requests.append(request)
        guard automatic else { pending.append(completion); return }
        if fails { completion(nil, NSError(domain: "QA", code: 2)); return }
        let a = request.source!.placemark.coordinate
        let b = request.destination!.placemark.coordinate
        completion(WorkflowResponse([WorkflowRoute(malformed ? [a] : [a, b])]), nil)
    }
}

@MainActor
struct WorkflowQATests {
    private let a = CLLocationCoordinate2D(latitude: 25, longitude: 121)
    private let b = CLLocationCoordinate2D(latitude: 25.001, longitude: 121)
    private let c = CLLocationCoordinate2D(latitude: 25.002, longitude: 121)

    private func make() -> (AppViewModel, WorkflowDevice, WorkflowSearch, WorkflowCalculator) {
        let device = WorkflowDevice(), search = WorkflowSearch(), calculator = WorkflowCalculator()
        return (AppViewModel(deviceManager: device, locationSearchService: search, routeCalculator: calculator), device, search, calculator)
    }

    private func route(_ vm: AppViewModel) {
        vm.insertPoint(a)
        vm.insertPoint(b)
        vm.handleMainAction()
        #expect(vm.appState == .readyToMove)
    }

    @Test("GPS-01,02,17,21; LOC-05,06,07: fixed input, validation, explicit stop")
    func fixedPointAndCoordinateInput() async {
        let (vm, device, _, _) = make()
        vm.operationMode = .fixedPoint
        vm.handleMainAction()
        #expect(device.sent.isEmpty)
        for invalid in ["25;121", "abc,121", "91,121", "25,181", "nan,121", "inf,121", ",121"] {
            vm.coordinateInputText = invalid
            vm.insertCoordinateFromInput()
            #expect(vm.locationInputError != nil)
            #expect(vm.pointA == nil)
        }
        vm.coordinateInputText = " 25 ， 121 "
        vm.insertCoordinateFromInput()
        #expect(vm.locationInputError == nil)
        #expect(vm.pointA?.latitude == 25)
        vm.handleMainAction()
        defer { vm.stopSimulation(keepPinned: false) }
        #expect(device.sent.last?.latitude == 25)
        #expect(vm.isActiveSimulationRunning)
        vm.operationMode = .routeAB
        vm.switchModePreservingPinnedLocation()
        #expect(vm.activeOperationMode == .fixedPoint)
        #expect(vm.currentPosition?.latitude == 25)
        vm.operationMode = .fixedPoint
        vm.switchModePreservingPinnedLocation()
        vm.handleMainAction()
        #expect(!vm.hasActiveRouteSnapshot)
        #expect(vm.currentPosition == nil)
        #expect(device.stops > 0)
    }

    @Test("GPS-03,12..16,20,23,24,27,28; SET-04,05: route lifecycle and endpoint")
    func routeLifecycle() {
        let (vm, device, _, _) = make()
        route(vm)
        vm.handleMainAction()
        defer { vm.stopSimulation(keepPinned: false) }
        vm.speed = 36
        vm.advanceSimulation(by: 1)
        #expect(vm.traveledDistance == 10)
        let position = vm.currentPosition?.latitude
        vm.handleMainAction()
        #expect(!vm.isActiveSimulationRunning)
        #expect(device.sent.last?.latitude == position)
        vm.handleMainAction()
        vm.advanceSimulation(by: 1)
        #expect(vm.traveledDistance == 20)
        vm.operationMode = .multiPoint
        vm.switchModePreservingPinnedLocation()
        vm.insertPoint(c)
        vm.resetAll()
        #expect(vm.waypoints.isEmpty)
        #expect(vm.isActiveSimulationRunning)
        #expect(vm.activeOperationMode == .routeAB)
        vm.handleDeviceDisconnected()
        #expect(vm.isActiveSimulationRunning)
        #expect(vm.traveledDistance == 20)
        device.isConnected = false
        vm.handleDeviceDisconnected()
        #expect(!vm.isActiveSimulationRunning)
        #expect(vm.shouldResumeActiveAfterReconnect)
        device.isConnected = true
        vm.startIfReadyAndConnected()
        #expect(vm.traveledDistance == 20)
        vm.advanceSimulation(by: 20)
        #expect(!vm.isActiveSimulationRunning)
        // MKPolyline projects coordinates; 1e-9 degrees permits sub-millimeter round-trip error.
        #expect(abs((vm.currentPosition?.latitude ?? .infinity) - b.latitude) < 1e-9)
        #expect(abs((device.sent.last?.latitude ?? .infinity) - b.latitude) < 1e-9)
        #expect(abs((vm.lastSentPosition?.latitude ?? .infinity) - b.latitude) < 1e-9)
        vm.resetActiveSession()
        #expect(!vm.hasActiveRouteSnapshot)
        #expect(vm.currentPosition == nil)
        #expect(device.stops > 0)
    }

    @Test("GPS-18,19,22; SET-06: replacement cancel/confirm and draft reset")
    func replacement() {
        let (vm, device, _, _) = make()
        route(vm)
        vm.handleMainAction()
        defer { vm.stopSimulation(keepPinned: false) }
        let old = vm.currentPosition?.latitude
        vm.operationMode = .fixedPoint
        vm.switchModePreservingPinnedLocation()
        vm.insertPoint(c)
        vm.handleMainAction()
        #expect(vm.isShowingRouteReplacementConfirmation)
        vm.cancelRouteReplacement()
        #expect(vm.currentPosition?.latitude == old)
        #expect(vm.isActiveSimulationRunning)
        vm.handleMainAction()
        vm.confirmRouteReplacement()
        #expect(vm.activeOperationMode == .fixedPoint)
        #expect(vm.currentPosition?.latitude == c.latitude)
        #expect(device.isConnected)
        vm.resetActiveSession()
        vm.resetAll()
        #expect(!vm.hasDraftEdits)
        #expect(!vm.hasActiveRouteSnapshot)
    }

    @Test("GPS-05..11,26; SET-02,03: waypoint order, closure, malformed route")
    func multiPoint() {
        let (vm, _, _, calculator) = make()
        vm.operationMode = .multiPoint
        vm.insertPoint(a)
        vm.calculateMultiPointRoute()
        #expect(calculator.requests.isEmpty)
        vm.insertPoint(c)
        vm.removeLastWaypoint()
        #expect(vm.waypoints.count == 1)
        vm.insertPoint(b)
        vm.insertPoint(c)
        vm.moveWaypoint(from: 2, to: 1)
        #expect(vm.waypoints[1].latitude == c.latitude)
        vm.moveWaypoint(from: 1, to: 2)
        vm.isEndlessLoop = true
        vm.isClosedLoop = true
        #expect(!vm.isEndlessLoop)
        vm.isEndlessLoop = true
        #expect(!vm.isEndlessLoop)
        vm.calculateMultiPointRoute()
        #expect(calculator.requests.count == 3)
        #expect(vm.draftRoutePoints.count == 4)
        #expect(abs((vm.draftRoutePoints.last?.latitude ?? .infinity) - a.latitude) < 1e-9)
        #expect(calculator.requests[1].source?.placemark.coordinate.latitude == b.latitude)
        vm.handleMainAction()
        defer { vm.stopSimulation(keepPinned: false) }
        #expect(vm.activeIsClosedLoop)
        vm.speed = 36
        vm.advanceSimulation(by: 31)
        #expect(vm.isActiveSimulationRunning)
        vm.resetActiveSession()
        vm.isClosedLoop = false
        vm.isEndlessLoop = true
        vm.insertPoint(a)
        vm.insertPoint(b)
        vm.calculateMultiPointRoute()
        vm.handleMainAction()
        vm.advanceSimulation(by: 11)
        #expect(vm.isActiveSimulationRunning)
        #expect(vm.currentPosition!.latitude < b.latitude)
        vm.resetActiveSession()
        vm.insertPoint(a)
        vm.insertPoint(b)
        calculator.malformed = true
        vm.calculateMultiPointRoute()
        #expect(vm.appState == .selectingA)
        #expect(!vm.hasDraftPreview)
        #expect(vm.locationInputError != nil)
        calculator.malformed = false
        calculator.fails = true
        vm.calculateMultiPointRoute()
        #expect(vm.locationInputError?.contains("第 1 段") == true)
    }

    @Test("GPS-04,25: failed and stale A-B/multi-point callbacks")
    func staleRoutes() {
        let (vm, _, _, calculator) = make()
        calculator.automatic = false
        vm.insertPoint(a)
        vm.insertPoint(b)
        let first = calculator.pending.removeFirst()
        vm.calculateRoutes()
        let second = calculator.pending.removeFirst()
        second(nil, NSError(domain: "QA", code: 1))
        #expect(vm.appState == .selectingB)
        first(WorkflowResponse([WorkflowRoute([a, b])]), nil)
        #expect(vm.appState == .selectingB)
        vm.operationMode = .multiPoint
        vm.switchModePreservingPinnedLocation()
        vm.insertPoint(a)
        vm.insertPoint(b)
        vm.calculateMultiPointRoute()
        let multi = calculator.pending.removeFirst()
        vm.resetAll()
        multi(WorkflowResponse([WorkflowRoute([a, b])]), nil)
        #expect(vm.appState == .selectingA)
        #expect(!vm.hasDraftPreview)
        #expect(vm.waypoints.isEmpty)
    }

    @Test("GPS-13; SET-01: speed bounds and malformed text")
    func speedSettings() {
        let (vm, _, _, _) = make()
        vm.setSpeedText(" 36.5 ")
        #expect(vm.speed == 36.5)
        for text in ["oops", "nan", "inf", ""] { vm.setSpeedText(text); #expect(vm.speed == 36.5) }
        vm.setSpeedText("999")
        #expect(vm.speed == vm.maximumSpeed)
        vm.speed = -10
        #expect(vm.speed == AppConstants.Simulation.speedStep)
        vm.speed = .infinity
        #expect(vm.speed == AppConstants.Simulation.speedStep)
    }

    @Test("LOC-01,02,04,07: search responses and result selection")
    func searchesAndSelection() async {
        let (vm, _, search, _) = make()
        let completion = MKLocalSearchCompletion()
        await vm.searchPlaces(using: completion, currentRegion: nil).value
        #expect(vm.locationInputError == "找不到符合的地點")
        search.failure = true
        await vm.searchPlaces(using: completion, currentRegion: nil).value
        #expect(vm.locationInputError == "搜尋失敗，請重試")
        search.failure = false
        search.results = [MKMapItem(placemark: MKPlacemark(coordinate: a))]
        await vm.searchPlaces(using: completion, currentRegion: nil).value
        #expect(vm.placeResults.count == 1)
        #expect(vm.locationInputError == nil)
        var cameraUpdates = 0
        vm.requestCameraPosition = { _ in cameraUpdates += 1 }
        vm.insertPoint(a)
        #expect(vm.appState == .selectingB)
        vm.insertPoint(b)
        #expect(vm.appState == .routeSelection)
        #expect(cameraUpdates == 2)
        vm.operationMode = .multiPoint
        vm.switchModePreservingPinnedLocation()
        vm.insertPoint(a)
        vm.insertPoint(b)
        vm.calculateMultiPointRoute()
        vm.insertPoint(c)
        #expect(vm.waypoints.count == 2)
        vm.placeKeyword = ""
        #expect(vm.placeResults.isEmpty)
        #expect(search.clears > 0)
    }

    @Test("LOC-03: ranking, deduplication, region, eight-result cap")
    func rankedSearch() async throws {
        let center = a
        let service = LocationSearchService { request in
            #expect(request.naturalLanguageQuery == "Cafe")
            #expect(request.region.center.latitude == center.latitude)
            var items = (0..<12).map { index in
                let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: 25 + Double(index) / 1000, longitude: 121)))
                item.name = "Cafe \(index)"
                return item
            }
            items.append(items[0])
            return items.reversed()
        }
        let region = MKCoordinateRegion(center: a, span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1))
        let items = try await service.search(for: " Cafe ", region: region)
        #expect(items.count == 8)
        #expect(items.first?.name == "Cafe 0")
        #expect(Set(items.compactMap(\.name)).count == 8)
        service.updateQuery("query", region: region)
        service.clearSuggestions()
        let stale = MKLocalSearchCompleter()
        service.completer(stale, didFailWithError: NSError(domain: "stale", code: 1))
        #expect(service.completions.isEmpty)
        #expect(service.completerError == nil)
    }

    @Test("LOC-03: old asynchronous search cannot replace newer results or cleared input")
    func staleSearch() async {
        let (vm, _, search, _) = make()
        var pending: CheckedContinuation<[MKMapItem], any Error>?
        var started: CheckedContinuation<Void, Never>?
        search.handler = { _ in
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started?.resume()
            }
        }
        vm.placeKeyword = "old"
        let old = vm.searchPlaces(currentRegion: nil)!
        await withCheckedContinuation { continuation in
            if pending != nil { continuation.resume() } else { started = continuation }
        }
        search.handler = nil
        let newItem = MKMapItem(placemark: MKPlacemark(coordinate: b))
        search.results = [newItem]
        vm.placeKeyword = "new"
        await vm.searchPlaces(currentRegion: nil)!.value
        pending?.resume(returning: [MKMapItem(placemark: MKPlacemark(coordinate: a))])
        await old.value
        #expect(vm.placeResults.first === newItem)
        vm.placeKeyword = ""
        #expect(vm.placeResults.isEmpty)
    }
    @Test("MAP-03; PP-10: map selection state and fitting coordinates")
    func mapSelectionAndFitting() {
        let (vm, _, _, _) = make()
        vm.handleMapTap(at: a)
        #expect(vm.appState == .confirmingA)
        vm.handleMainAction()
        vm.handleMapTap(at: b)
        #expect(vm.appState == .confirmingB)
        vm.handleMainAction()
        #expect(vm.appState == .routeSelection)
        vm.handleMapTap(at: c)
        #expect(vm.tempCoordinate == nil)
        let invalid = CLLocationCoordinate2D(latitude: .nan, longitude: 181)
        let empty = vm.mapRegion(fitting: [])
        let rejected = vm.mapRegion(fitting: [invalid])
        #expect(empty.center.latitude == rejected.center.latitude)
        let fitted = vm.mapRegion(fitting: [a, c, invalid])
        #expect(abs(fitted.center.latitude - (a.latitude + c.latitude) / 2) < 0.000001)
        #expect(fitted.span.latitudeDelta >= AppConstants.Map.defaultSpanDelta)
    }

    @Test("GPS-16,22; SET-04: reset clears device location")
    func resetClearsLocation() async {
        let (vm, device, _, _) = make()
        vm.insertPoint(a)
        await withCheckedContinuation { continuation in
            device.didClear = { continuation.resume() }
            vm.resetAll()
        }
        #expect(!vm.hasDraftEdits)
        #expect(vm.currentPosition == nil)
        #expect(device.clears == 1)
        vm.operationMode = .fixedPoint
        vm.insertPoint(a)
        vm.handleMainAction()
        await withCheckedContinuation { continuation in
            device.didClear = { continuation.resume() }
            vm.resetActiveSession()
        }
        #expect(device.clears == 2)
        #expect(!vm.hasActiveRouteSnapshot)
    }
}
