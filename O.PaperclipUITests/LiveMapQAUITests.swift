import AppKit
import Carbon
import Darwin
import XCTest

/// Live Apple Maps coverage: requires an online, unlocked macOS desktop and Accessibility permission.
/// No search stub or application launch hook is used. Service failures are test failures, not skips.
@MainActor
final class LiveMapQAUITests: XCTestCase {
    private var app: XCUIApplication!
    private var applicationURL: URL!
    private var preferencesURL: URL!
    private var bundleID: String!
    private var originalInputSource: TISInputSource?
    private var originalCamera: [String: Any] = [:]
    private var temporaryDirectory: URL!
    private var overlayTitle: String?
    private let cameraKeys = ["map.center.lat", "map.center.lon", "map.span.lat", "map.span.lon"]
    private var persistedCameraKeys: [String] { cameraKeys + ["map.camera"] }

    override func setUp() async throws {
        continueAfterFailure = false
        originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        selectASCIIKeyboard()
        applicationURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("O.Paperclip.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: applicationURL.appendingPathComponent("Contents/Info.plist").path) else {
            throw NSError(domain: "LiveMapQA", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built application missing at \(applicationURL.path)"])
        }
        bundleID = try XCTUnwrap(Bundle(url: applicationURL)?.bundleIdentifier)
        let account = try XCTUnwrap(getpwuid(getuid()))
        preferencesURL = URL(fileURLWithPath: String(cString: account.pointee.pw_dir))
            .appendingPathComponent("Library/Preferences/\(bundleID!).plist")
        app = XCUIApplication(url: applicationURL)
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.terminate()
        let preferences = readPreferences()
        for key in persistedCameraKeys { originalCamera[key] = preferences[key] }
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMapQA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defer { if let originalInputSource { TISSelectInputSource(originalInputSource) } }
        if let app {
            if let overlayTitle {
                if app.state != .runningForeground { launchAppWindow() }
                let label = app.staticTexts[overlayTitle]
                if label.exists {
                    reveal(label)
                    let menus = app.descendants(matching: .menuButton).allElementsBoundByIndex.filter {
                        $0.isHittable && $0.frame.minX >= label.frame.maxX && abs($0.frame.midY - label.frame.midY) < 20
                    }
                    XCTAssertEqual(menus.count, 1, "Remove only this test's uniquely named overlay")
                    if menus.count == 1 {
                        menus[0].click()
                        app.menuItems["移除"].click()
                        XCTAssertTrue(label.waitForNonExistence(timeout: 5))
                    }
                }
            }
            app.terminate()
        }
        if let bundleID {
            for key in persistedCameraKeys {
                CFPreferencesSetAppValue(key as CFString, originalCamera[key] as CFPropertyList?, bundleID as CFString)
            }
            XCTAssertTrue(CFPreferencesAppSynchronize(bundleID as CFString))
        }
        if let temporaryDirectory { try FileManager.default.removeItem(at: temporaryDirectory) }
    }

    // LOC-01, LOC-02 (live success), LOC-07 (fixed), MAP-01 (native gestures + disk persistence).
    func testLiveTaipei101CompletionResultFixedPointAndCameraGestures() throws {
        // Clear only camera preferences, preserving all unrelated user settings.
        for key in persistedCameraKeys { CFPreferencesSetAppValue(key as CFString, nil, bundleID as CFString) }
        XCTAssertTrue(CFPreferencesAppSynchronize(bundleID as CFString))
        launchAppWindow()
        click(app.radioButtons["定點"])
        let search = app.textFields["搜尋地點（例如 Taipei 101）"]
        XCTAssertFalse(app.sheets.firstMatch.exists, "A leftover native sheet must not be mistaken for a network failure")
        XCTAssertTrue(search.isEnabled, "Live search must start from an enabled native text field")
        replaceText(in: search, with: "Taipei 101")
        let completion = app.scrollViews.firstMatch.buttons.matching(NSPredicate(format: "label CONTAINS[c] '101' AND NOT label CONTAINS 'km'")).firstMatch
        guard completion.waitForExistence(timeout: 30) else {
            attachScreen("Live MapKit completion unavailable")
            XCTFail("No live MapKit Taipei 101 suggestion within 30s. An online Apple Maps response is required, but this timeout alone does not diagnose a network outage. No skip or fake response is used. \(app.debugDescription)")
            return
        }
        replaceText(in: search, with: "")
        XCTAssertTrue(completion.waitForNonExistence(timeout: 5), "Clearing the query must clear suggestions")
        replaceText(in: search, with: "Taipei 101")
        XCTAssertTrue(completion.waitForExistence(timeout: 30), "Live MapKit suggestions must recover after clearing")
        completion.click()
        let result = app.scrollViews["placeSearchResults"].buttons.matching(NSPredicate(format: "label CONTAINS[c] '101'")).firstMatch
        guard result.waitForExistence(timeout: 30) else {
            attachScreen("Live MapKit result unavailable")
            XCTFail("Live MapKit completion did not resolve to a Taipei 101 result within 30s; network/service/empty-result failures are explicit failures. \(app.debugDescription)")
            return
        }
        click(result)
        XCTAssertTrue(app.staticTexts["準備就緒"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.maps.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '草稿定點'")).firstMatch.waitForExistence(timeout: 5))
        // insertPoint centers the real camera on the selected result. Observe its normal persisted
        // region, rather than adding a product-only AX coordinate or injecting a search response.
        waitUntil("Selected live result must center the camera near Taipei 101") {
            guard let camera = self.camera() else { return false }
            return abs(camera[0] - 25.0339) < 0.025 && abs(camera[1] - 121.5645) < 0.025
        }
        let selected = try XCTUnwrap(camera())
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        pan(map)
        waitUntil("Native pan must persist a changed center") {
            guard let value = self.camera() else { return false }
            return abs(value[1] - selected[1]) > 0.0001
        }
        let panned = try XCTUnwrap(camera())
        map.scroll(byDeltaX: 0, deltaY: 180)
        waitUntil("Native zoom must persist a changed span") {
            guard let value = self.camera() else { return false }
            return abs(value[2] - panned[2]) > 0.00001 || abs(value[3] - panned[3]) > 0.00001
        }
        let saved = try XCTUnwrap(camera())
        attachScreen("Live Taipei selection after native pan and zoom")
        app.terminate()
        launchAppWindow()
        let restored = try XCTUnwrap(camera())
        for index in saved.indices { XCTAssertEqual(restored[index], saved[index], accuracy: 0.00001) }
        attachScreen("Relaunched native map")
    }

    // PP-08/09/10 and PP-13's small finite viewport journey (density cap is model coverage).
    // Persistent annotation screen positions additionally check MAP-01's actual restored camera.
    func testImportedOverlayToggleCategoryFocusAndRestoredAnnotationPositions() throws {
        let token = UUID().uuidString
        let title = "LiveMap-\(token)"
        overlayTitle = title
        let firstName = "美術館-\(token)"
        let secondName = "電影院-\(token)"
        let file = temporaryDirectory.appendingPathComponent("points.kml")
        try "<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>\(title)</name><Placemark><name>\(firstName)</name><Point><coordinates>121.5645,25.0339,0</coordinates></Point></Placemark><Placemark><name>\(secondName)</name><Point><coordinates>121.5745,25.0439,0</coordinates></Point></Placemark></Document></kml>"
            .write(to: file, atomically: true, encoding: .utf8)
        launchAppWindow()
        importKML(file, title: title)
        let toggle = app.checkBoxes["開啟\(title)"]
        reveal(toggle)
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true, "New imports default enabled")
        let focus = app.buttons["purePointFocus-\(title)"]
        click(focus)
        waitUntil("Focus must fit the imported coordinates") {
            guard let value = self.camera() else { return false }
            return abs(value[0] - 25.0389) < 0.002 && abs(value[1] - 121.5695) < 0.002
        }
        let map = app.maps.firstMatch
        let first = map.descendants(matching: .any).matching(identifier: "pure-point-\(firstName)").firstMatch
        let second = map.descendants(matching: .any).matching(identifier: "pure-point-\(secondName)").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        click(toggle)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        click(toggle)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let clearCategories = overlayControl("清空", title: title)
        reveal(clearCategories)
        XCTAssertTrue(clearCategories.isHittable, "Imported filters start expanded; use their actual visible controls")
        clearCategories.click()
        XCTAssertFalse(focus.isEnabled, "Empty visible set must disable focus")
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        click(overlayControl("美術館", title: title, contains: true))
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertFalse(second.exists)
        XCTAssertTrue(focus.isEnabled)
        click(overlayControl("全選", title: title))
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        click(focus)
        waitUntil("Overlay focus must finish before testing a user pan") {
            guard let value = self.camera() else { return false }
            return abs(value[0] - 25.0389) < 0.002 && abs(value[1] - 121.5695) < 0.002
        }
        let cameraBeforePan = try XCTUnwrap(camera())
        pan(map)
        waitUntil("Panning must change the persisted map center") {
            guard let value = self.camera() else { return false }
            return abs(value[0] - cameraBeforePan[0]) > 0.00001 || abs(value[1] - cameraBeforePan[1]) > 0.00001
        }
        let cameraBeforeZoom = try XCTUnwrap(camera())
        map.scroll(byDeltaX: 0, deltaY: 60)
        waitUntil("Zooming must change the persisted map span") {
            guard let value = self.camera() else { return false }
            return abs(value[2] - cameraBeforeZoom[2]) > 0.00001 || abs(value[3] - cameraBeforeZoom[3]) > 0.00001
        }
        var lastFrames: [CGRect] = []
        var lastCamera: [Double]?
        var stableSince = Date()
        waitUntil("Camera and annotation positions must settle after zoom") {
            let frames = [first.frame, second.frame]
            let camera = self.camera()
            defer { lastFrames = frames; lastCamera = camera }
            guard camera != nil, frames == lastFrames, camera == lastCamera else {
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 2
        }
        let before = [first.frame, second.frame]
        attachScreen("Imported overlay after focus filter pan zoom")
        app.terminate()
        launchAppWindow()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        waitUntil("Relaunch must restore both annotation screen positions") {
            zip(before, [first.frame, second.frame]).allSatisfy {
                abs($0.0.midX - $0.1.midX) < 8 && abs($0.0.midY - $0.1.midY) < 8
            }
        }
        attachScreen("Imported annotations restored after relaunch")
    }

    private func pan(_ map: XCUIElement) {
        let start = map.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        start.click(forDuration: 0.1, thenDragTo: map.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.55)))
    }

    private func selectASCIIKeyboard() {
        XCTAssertEqual(TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()), noErr)
    }

    private func launchAppWindow() {
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.activate()
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let rightPanel = app.scrollViews["rightPanelScrollView"]
        let scroll = rightPanel.exists && element.frame.midX >= rightPanel.frame.minX
            ? rightPanel : app.scrollViews.firstMatch
        func visible() -> Bool { element.isHittable && (app.sheets.firstMatch.exists || scroll.frame.contains(element.frame)) }
        if visible() { return }
        for delta in [450.0, -450.0] {
            for _ in 0..<40 {
                scroll.scroll(byDeltaX: 0, deltaY: delta)
                if visible() { return }
            }
        }
        XCTFail("Control is not reachable: \(element)")
    }

    private func click(_ element: XCUIElement) { reveal(element); element.click() }

    private func replaceText(in field: XCUIElement, with text: String) {
        click(field)
        field.typeKey("a", modifierFlags: .command)
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        selectASCIIKeyboard()
        if text.isEmpty {
            field.typeKey(.delete, modifierFlags: [])
        } else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            field.typeKey("v", modifierFlags: .command)
        }
        let received = expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: field)
        wait(for: [received], timeout: 5)
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 15, _ condition: @escaping () -> Bool) {
        let check = expectation(for: NSPredicate { _, _ in condition() }, evaluatedWith: app)
        let result = XCTWaiter.wait(for: [check], timeout: timeout)
        if result != .completed { attachScreen(message) }
        XCTAssertEqual(result, .completed, message)
    }

    private func readPreferences() -> [String: Any] {
        guard let preferencesURL, let data = try? Data(contentsOf: preferencesURL),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return values
    }

    private func camera() -> [Double]? {
        let values = readPreferences()
        let camera = cameraKeys.compactMap { (values[$0] as? NSNumber)?.doubleValue }
        return camera.count == cameraKeys.count ? camera : nil
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func importKML(_ file: URL, title: String) {
        click(app.buttons["匯入 KML"])
        let panel = app.sheets["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        selectASCIIKeyboard()
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let pathSheet = panel.sheets.firstMatch
        replaceText(in: pathSheet.textFields.firstMatch, with: file.path)
        pathSheet.textFields.firstMatch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(pathSheet.waitForNonExistence(timeout: 5))
        let open = panel.buttons["OKButton"]
        waitUntil("Native open panel must enable Open", timeout: 5) { open.isEnabled }
        open.click()
        XCTAssertTrue(app.sheets.staticTexts["設定純點圖層名稱"].waitForExistence(timeout: 5))
        replaceText(in: app.sheets.textFields["圖層名稱"], with: title)
        app.sheets.buttons["匯入"].click()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    private func overlayControl(_ label: String, title: String, type: XCUIElement.ElementType = .button, contains: Bool = false) -> XCUIElement {
        let titleElement = app.staticTexts[title]
        reveal(titleElement)
        let matches = app.descendants(matching: type).allElementsBoundByIndex.filter {
            (contains ? $0.label.contains(label) : $0.label == label) && $0.frame.minY > titleElement.frame.maxY
        }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertFalse(matches.isEmpty, "Expected \(label) control for overlay \(title)")
        return matches[0]
    }
}
