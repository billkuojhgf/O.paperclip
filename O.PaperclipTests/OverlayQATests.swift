import Foundation
import MapKit
import SwiftUI
import Testing
@testable import O_Paperclip

@MainActor
struct OverlayQATests {
    private func withStore(_ body: (URL, UserDefaults) throws -> Void) throws {
        let id = "OverlayQA-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        let defaults = try #require(UserDefaults(suiteName: id))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory, defaults)
    }

    private func kml(_ name: String, longitude: Double = 121.5) -> Data {
        Data("<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>\(name)</name><Folder><name>咖啡杯</name><Placemark><name>\(name)</name><Point><coordinates>\(longitude),25,0</coordinates></Point></Placemark></Folder></Document></kml>".utf8)
    }

    private func register(_ overlays: [PurePointOverlay], defaults: UserDefaults) {
        ImportedPurePointOverlayStore.savePaths(overlays.compactMap(\.sourceFilePath), defaults: defaults)
        ImportedPurePointOverlayStore.saveTitleOverrides(Dictionary(uniqueKeysWithValues: overlays.map { ($0.sourceFilePath!, $0.title) }), defaults: defaults)
    }

    @Test func importRenameUpdateReloadAndDelete_PP01_PP02_PP03_PP11() throws {
        try withStore { directory, defaults in
            let source = directory.appendingPathComponent("source.kml")
            let second = directory.appendingPathComponent("second.kml")
            let snapshots = directory.appendingPathComponent("snapshots")
            try kml("original").write(to: source)
            try kml("second").write(to: second)
            let preview = try ImportedPurePointOverlayStore.previewOverlays(from: [source, second, source])
            #expect(preview.count == 2)
            let imported = try ImportedPurePointOverlayStore.persistImportedOverlays([preview[0].renamed(to: "  自訂標題  "), preview[1]], directoryURL: snapshots)
            register(imported, defaults: defaults)
            #expect(imported.count == 2)
            #expect(imported[0].title == "自訂標題")
            let loaded = ImportedPurePointOverlayStore.loadOverlays(defaults: defaults)
            #expect(loaded.map(\.id) == imported.map(\.id))
            #expect(loaded[0].title == "自訂標題")
            try kml("changed", longitude: 122).write(to: source)
            let replacementPreview = try ImportedPurePointOverlayStore.previewOverlays(from: [source])
            let replacement = try ImportedPurePointOverlayStore.persistImportedOverlays([replacementPreview[0].renamed(to: "更新")], directoryURL: snapshots)
            #expect(replacement[0].sourceFilePath == imported[0].sourceFilePath)
            #expect(replacement[0].id == imported[0].id)
            register([replacement[0], imported[1]], defaults: defaults)
            let reloaded = ImportedPurePointOverlayStore.loadOverlays(defaults: defaults)
            #expect(reloaded.count == 2)
            #expect(reloaded[0].title == "更新")
            #expect(reloaded[0].points.first?.longitude == 122)
            ImportedPurePointOverlayStore.deleteStoredOverlay(reloaded[0])
            register([reloaded[1]], defaults: defaults)
            #expect(ImportedPurePointOverlayStore.loadOverlays(defaults: defaults).map(\.id) == [imported[1].id])
            #expect(ImportedPurePointOverlayStore.loadTitleOverrides(defaults: defaults).count == 1)
        }
    }

    @Test func previewCancellationAndFailedBatchLeaveStoreUntouched_PP04_PP07() throws {
        try withStore { directory, defaults in
            let good = directory.appendingPathComponent("good.kml")
            let bad = directory.appendingPathComponent("bad.kml")
            let snapshots = directory.appendingPathComponent("snapshots")
            try kml("good").write(to: good)
            try Data("<kml>broken".utf8).write(to: bad)
            let pending = try ImportedPurePointOverlayStore.previewOverlays(from: [good])
            #expect(pending.count == 1)
            #expect(ImportedPurePointOverlayStore.loadPaths(defaults: defaults).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: snapshots.path))
            let badOverlay = PurePointOverlay(id: "bad", title: "bad", sourceName: "bad", categories: [], points: [], isBuiltIn: false, sourceFilePath: bad.path)
            #expect(throws: (any Error).self) {
                try ImportedPurePointOverlayStore.persistImportedOverlays(pending + [badOverlay], directoryURL: snapshots)
            }
            #expect(!FileManager.default.fileExists(atPath: snapshots.path))
            let recovered = try ImportedPurePointOverlayStore.persistImportedOverlays(pending, directoryURL: snapshots)
            #expect(recovered.count == 1)
        }
    }

    @Test func remoteApprovalIsNormalizedDeduplicatedAndSessionScoped_PP05_PP06_PP07() throws {
        try withStore { directory, defaults in
            let source = directory.appendingPathComponent("links.kml")
            let target = URL(string: "https://example.com/points.kml")!
            let links = "<NetworkLink><Link><href>\(target.absoluteString)#one</href></Link></NetworkLink><NetworkLink><Link><href>\(target.absoluteString)#two</href></Link></NetworkLink>"
            try Data("<kml><Document>\(links)</Document></kml>".utf8).write(to: source)
            var fetched: [URL] = []
            let fetcher: PurePointRemoteDataFetcher = { url in fetched.append(url); return kml("linked") }
            do {
                _ = try ImportedPurePointOverlayStore.previewOverlays(from: [source], remoteFetcher: fetcher)
                Issue.record("Unapproved remote data was accepted")
            } catch PurePointImportError.remoteLinkRequiresApproval(let urls) {
                #expect(urls == [target])
            }
            #expect(fetched.isEmpty)
            #expect(ImportedPurePointOverlayStore.loadPaths(defaults: defaults).isEmpty)
            let result = try ImportedPurePointOverlayStore.previewOverlays(from: [source], approvedRemoteURLs: [URL(string: target.absoluteString + "#approved")!], remoteFetcher: fetcher)
            #expect(result[0].points.count == 1)
            #expect(fetched == [target])
            #expect(throws: PurePointImportError.self) {
                try ImportedPurePointOverlayStore.previewOverlays(from: [source], remoteFetcher: fetcher)
            }
            #expect(fetched == [target])
            #expect(throws: CocoaError.self) {
                try ImportedPurePointOverlayStore.previewOverlays(from: [source], approvedRemoteURLs: [target], remoteFetcher: { _ in throw CocoaError(.fileReadUnknown) })
            }
        }
    }

    @Test func mixedLocalAndLinkedPointsAreBothImported_PP06() throws {
        let target = URL(string: "https://example.com/linked.kml")!
        let source = String(decoding: kml("local"), as: UTF8.self).replacingOccurrences(of: "</Document>", with: "<NetworkLink><Link><href>\(target)</href></Link></NetworkLink></Document>")
        let data = try PurePointKMLResolver.resolveKMLData(from: Data(source.utf8), baseURL: nil, approvedRemoteURLs: [target], remoteFetcher: { _ in kml("remote", longitude: 122) })
        let overlay = try PurePointKMLParser.parse(data: data, fallbackTitle: "fallback", sourceName: "mixed", stableID: "mixed", sourceFilePath: nil)
        #expect(overlay.points.count == 2)
    }

    @Test func repairsDuplicateMissingAndCorruptRegistrations_PP12() throws {
        try withStore { directory, defaults in
            let good = directory.appendingPathComponent("good.kml")
            let corrupt = directory.appendingPathComponent("corrupt.kml")
            let missing = directory.appendingPathComponent("missing.kml")
            try kml("good").write(to: good)
            try Data("broken".utf8).write(to: corrupt)
            defaults.set([good.path, good.path, missing.path, corrupt.path], forKey: "pure-point-imported-kml-paths")
            ImportedPurePointOverlayStore.saveTitleOverrides([good.path: "保留", missing.path: "移除"], defaults: defaults)
            let overlays = ImportedPurePointOverlayStore.loadOverlays(defaults: defaults)
            #expect(overlays.count == 1)
            #expect(overlays[0].title == "保留")
            #expect(defaults.stringArray(forKey: "pure-point-imported-kml-paths") == [good.path])
            #expect(ImportedPurePointOverlayStore.loadTitleOverrides(defaults: defaults) == [good.path: "保留"])
        }
    }

    @Test func enabledCategoriesAndEmptySelectionSurviveReconciliation_PP08_PP09() throws {
        let overlay = try PurePointKMLParser.parse(data: kml("point"), fallbackTitle: "fallback", sourceName: "source", stableID: "id", sourceFilePath: nil)
        let builtIn = PurePointOverlay(id: "built-in", title: "built-in", sourceName: "built-in", categories: overlay.categories, points: overlay.points, isBuiltIn: true, sourceFilePath: nil)
        let initialStates = ContentView.makeOverlayStates(for: [overlay, builtIn])
        #expect(initialStates[overlay.id]?.isEnabled == true)
        #expect(initialStates[builtIn.id]?.isEnabled == false)
        var state = PurePointOverlayUIState(overlay: overlay, isEnabled: true)
        #expect(state.visiblePoints(in: overlay).count == 1)
        state.selectedCategoryIDs.removeAll()
        state.reconcile(with: overlay)
        #expect(state.visiblePoints(in: overlay).isEmpty)
        state.selectedCategoryIDs = Set(overlay.categories.map(\.id))
        #expect(state.visiblePoints(in: overlay).count == 1)
        state.isEnabled = false
        #expect(state.visiblePoints(in: overlay).isEmpty)
        state.isEnabled = true
        #expect(state.visiblePoints(in: overlay).count == 1)
    }

    @Test func viewportCountsInvalidPointsAndCaps_PP13() {
        let points = (0..<100).map { index in
            ShuangbeiPurePoint(id: "\(index)", name: "point", latitude: index == 99 ? .nan : Double(index) / 10, longitude: 0, categoryID: "a", groupName: "a", note: nil)
        }
        let overlay = PurePointOverlay(id: "test", title: "test", sourceName: "test", categories: [], points: points, isBuiltIn: false, sourceFilePath: nil)
        let entries = points.map { VisiblePurePoint(overlay: overlay, point: $0, category: nil) }
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        let rendered = PurePointRenderEngine.renderState(for: entries, region: region, padding: 0, limit: 5, activationCount: 10, wideSpanThreshold: 20)
        #expect(rendered.totalMatchingCount == 99)
        #expect(rendered.viewportMatchingCount == 11)
        #expect(rendered.points.count == 5)
        #expect(rendered.isDensityLimited)
        #expect(rendered.isViewportFiltered)
        #expect(PurePointRenderEngine.cappedEntries(entries, limit: 0, region: region).isEmpty)
        let dateLine = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 179), span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10))
        #expect(PurePointRenderEngine.contains(CLLocationCoordinate2D(latitude: 0, longitude: -179), in: dateLine))
        #expect(!PurePointRenderEngine.contains(CLLocationCoordinate2D(latitude: 0, longitude: 0), in: dateLine))
    }

    @Test func mapPreferencesDefaultRestoreAndRepair_MAP01_MAP02() throws {
        try withStore { _, defaults in
            let initial = PersistedMapRegionStore.load(defaults: defaults)
            #expect(initial.center.latitude == AppConstants.Map.defaultLatitude)
            #expect(initial.span.latitudeDelta == AppConstants.Map.defaultSpanDelta)
            defaults.set(24.5, forKey: "map.center.lat")
            defaults.set(121.2, forKey: "map.center.lon")
            defaults.set(0.2, forKey: "map.span.lat")
            defaults.set(0.3, forKey: "map.span.lon")
            let restored = PersistedMapRegionStore.load(defaults: defaults)
            #expect(restored.center.latitude == 24.5)
            #expect(restored.center.longitude == 121.2)
            #expect(restored.span.latitudeDelta == 0.2)
            defaults.set(200, forKey: "map.center.lat")
            defaults.set(-1, forKey: "map.span.lat")
            defaults.set(1000, forKey: "map.span.lon")
            let repaired = PersistedMapRegionStore.load(defaults: defaults)
            #expect(repaired.center.latitude == AppConstants.Map.defaultLatitude)
            #expect(repaired.span.latitudeDelta == AppConstants.Map.minimumSpanDelta)
            #expect(repaired.span.longitudeDelta == AppConstants.Map.maximumSpanDelta)
            defaults.set(Double.nan, forKey: "map.span.lat")
            defaults.set(Double.infinity, forKey: "map.span.lon")
            let finite = PersistedMapRegionStore.load(defaults: defaults)
            #expect(finite.span.latitudeDelta.isFinite)
            #expect(finite.span.longitudeDelta.isFinite)
        }
    }

    @Test func overlayEditsPreserveCameraAndUnrelatedPreferences_QA03() throws {
        try withStore { directory, defaults in
            defaults.set(24.5, forKey: "map.center.lat")
            defaults.set(121.2, forKey: "map.center.lon")
            defaults.set(0.2, forKey: "map.span.lat")
            defaults.set("device-preference", forKey: "qa.unrelated")
            let source = directory.appendingPathComponent("source.kml")
            try kml("point").write(to: source)
            let preview = try ImportedPurePointOverlayStore.previewOverlays(from: [source])
            let imported = try ImportedPurePointOverlayStore.persistImportedOverlays(preview, directoryURL: directory.appendingPathComponent("snapshots"))
            register(imported, defaults: defaults)
            _ = ImportedPurePointOverlayStore.loadOverlays(defaults: defaults)
            ImportedPurePointOverlayStore.deleteStoredOverlay(imported[0])
            register([], defaults: defaults)
            #expect(PersistedMapRegionStore.load(defaults: defaults).center.latitude == 24.5)
            #expect(PersistedMapRegionStore.load(defaults: defaults).span.latitudeDelta == 0.2)
            #expect(defaults.string(forKey: "qa.unrelated") == "device-preference")
        }
    }

    @Test func lifecyclePersistsIncidentsAndCleanShutdown_QA01_QA02() throws {
        try withStore { directory, _ in
            let first = AppDiagnostics(logsDirectoryURL: directory, installsProcessHandlers: false)
            first.setupIfNeeded()
            first.setupIfNeeded()
            first.noteScenePhase(.active)
            #expect(first.lastUnexpectedTermination == nil)
            let marker = directory.appendingPathComponent("active-session.json")
            #expect(FileManager.default.fileExists(atPath: marker.path))
            let second = AppDiagnostics(logsDirectoryURL: directory, installsProcessHandlers: false)
            second.setupIfNeeded()
            let incident = try #require(second.lastUnexpectedTermination)
            #expect(!incident.reason.isEmpty)
            #expect(second.logsDirectoryURL == directory)
            let incidents = try String(contentsOf: directory.appendingPathComponent("incidents.jsonl"), encoding: .utf8)
            #expect(incidents.split(separator: "\n").count == 1)
            second.noteScenePhase(.background)
            second.markCleanShutdown(reason: "test")
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            let third = AppDiagnostics(logsDirectoryURL: directory, installsProcessHandlers: false)
            third.setupIfNeeded()
            #expect(third.lastUnexpectedTermination == nil)
            let log = try String(contentsOf: directory.appendingPathComponent("app-lifecycle.jsonl"), encoding: .utf8)
            let events = try log.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            #expect(events.filter { $0["kind"] as? String == "launch" }.count == 3)
            #expect(events.filter { $0["kind"] as? String == "scenePhase" }.count == 2)
            #expect(events.filter { $0["kind"] as? String == "shutdown" }.count == 1)
            third.markCleanShutdown(reason: "test cleanup")
        }
    }
}
