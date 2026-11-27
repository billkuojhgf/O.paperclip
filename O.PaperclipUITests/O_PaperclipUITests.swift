//
//  O_PaperclipUITests.swift
//  O.PaperclipUITests
//
//  Created by Mason Yen on 3/2/26.
//

import AppKit
import Carbon
import XCTest

@MainActor
final class O_PaperclipUITests: XCTestCase {
    private var app: XCUIApplication!
    private var importedTestTitles: [String] = []
    private var importedGPXTitles: [String] = []
    private var savedTestTitles: [String] = []
    private var temporaryDirectories: [URL] = []
    private var originalInputSource: TISInputSource?

    private func selectASCIIKeyboard() {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(source), noErr, "無法選取 ASCII 鍵盤配置")
    }

    override func setUp() async throws {
        continueAfterFailure = false
        originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        selectASCIIKeyboard()
        // Resolve the sibling build product, not Launch Services' same-ID installed copy.
        let applicationURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("O.Paperclip.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: applicationURL.appendingPathComponent("Contents/Info.plist").path) else {
            throw NSError(domain: "PaperclipUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Built application missing at \(applicationURL.path)"
            ])
        }
        app = XCUIApplication(url: applicationURL)
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
    }

    override func tearDown() async throws {
        defer { if let originalInputSource { TISSelectInputSource(originalInputSource) } }
        guard app != nil else { return }
        // Relaunch also dismisses an unfinished native panel after a failed assertion.
        if !importedTestTitles.isEmpty {
            app.terminate()
            launchAppWindow()
            for title in importedTestTitles {
                if app.staticTexts[title].exists { removeOverlay(named: title) }
            }
        }
        for title in importedGPXTitles where app.staticTexts[title].exists {
            rightPanelButton("移除", below: title).click()
        }
        for title in savedTestTitles where app.staticTexts[title].exists {
            rightPanelButton("刪除", below: title).click()
        }
        app.terminate()
        for directory in temporaryDirectories {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func launchAppWindow() {
        app.launch()
        let window = app.windows.firstMatch
        if !window.waitForExistence(timeout: 5) {
            // macOS may restore a previously closed scene with only its menu bar.
            app.activate()
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Application must present a real window")
        if app.buttons["顯示右側欄"].exists { app.buttons["顯示右側欄"].click() }
    }

    func testWiFiConnectionOpensDeviceSelectionBeforeConnecting() throws {
        launchAppWindow()
        let wifi = app.radioButtons["Wi‑Fi"]
        reveal(wifi)
        wifi.click()
        let connect = app.buttons["開始連線"]
        reveal(connect)
        connect.click()
        XCTAssertTrue(app.sheets.staticTexts["選擇 Wi‑Fi 裝置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sheets.buttons["取消"].exists)
        XCTAssertTrue(app.sheets.buttons["確定連線"].exists)
        app.sheets.buttons["取消"].click()
    }

    func testPhysicalWiFiSelectionModifiers() throws {
        launchAppWindow()
        let wifi = app.radioButtons["Wi‑Fi"]
        reveal(wifi)
        wifi.click()
        let connect = app.buttons["開始連線"]
        reveal(connect)
        connect.click()
        let rows = app.sheets.firstMatch.outlineRows
        XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 20), "需要至少兩台可探索的實體裝置")
        XCTAssertTrue(app.sheets.staticTexts["已選取 0 台"].waitForExistence(timeout: 5))
        let first = rows.element(boundBy: 0).staticTexts.firstMatch
        let second = rows.element(boundBy: 1).staticTexts.firstMatch
        first.click()
        XCTAssertTrue(app.sheets.staticTexts["已選取 1 台"].waitForExistence(timeout: 5))
        XCUIElement.perform(withKeyModifiers: .command) { second.click() }
        XCTAssertTrue(app.sheets.staticTexts["已選取 2 台"].waitForExistence(timeout: 5))
        second.click()
        XCTAssertTrue(app.sheets.staticTexts["已選取 1 台"].waitForExistence(timeout: 5))
        XCUIElement.perform(withKeyModifiers: .shift) { first.click() }
        XCTAssertTrue(app.sheets.staticTexts["已選取 2 台"].waitForExistence(timeout: 5))
        app.sheets.buttons["取消"].click()
    }

    func testRightPanelGPXImportSaveRelaunchAndApplyPreservesRoute() throws {
        let token = UUID().uuidString
        let routeTitle = "XCUI-GPX-\(token)"
        let savedTitle = "XCUI-saved-\(token)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(token)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let file = directory.appendingPathComponent("route.gpx")
        try """
        <gpx version="1.1"><trk><name>\(routeTitle)</name><trkseg>
        <trkpt lat="25.033" lon="121.5654"/><trkpt lat="25.034" lon="121.5664"/>
        <trkpt lat="25.035" lon="121.5674"/></trkseg></trk></gpx>
        """.write(to: file, atomically: true, encoding: .utf8)
        importedGPXTitles = [routeTitle]
        savedTestTitles = [savedTitle]
        launchAppWindow()
        openImport(file, buttonLabel: "匯入 GPX", namingTitle: "設定固定路線名稱")
        app.sheets.buttons["匯入"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        rightPanelButton("使用", below: routeTitle).click()
        assertText("多點數量：3")
        assertText("P3: 25.0350, 121.5674")
        let closedLoop = app.checkBoxes["閉圈（最後連回 P1）"]
        reveal(closedLoop)
        closedLoop.click()
        XCTAssertEqual((closedLoop.value as? NSNumber)?.boolValue, true)
        assertText("準備就緒")
        reveal(app.buttons["儲存這個迴路"])
        XCTAssertTrue(app.buttons["儲存這個迴路"].isEnabled)
        reveal(closedLoop)
        closedLoop.click()
        XCTAssertEqual((closedLoop.value as? NSNumber)?.boolValue, false)
        assertText("準備就緒")
        let save = app.buttons["儲存這條線路"]
        reveal(save)
        save.click()
        let name = app.sheets.textFields["名稱"]
        replaceText(in: name, with: savedTitle)
        app.sheets.buttons["儲存這條線路"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        app.terminate()
        launchAppWindow()
        rightPanelButton("移除", below: routeTitle).click()
        XCTAssertTrue(app.staticTexts[routeTitle].waitForNonExistence(timeout: 5))
        rightPanelButton("套用", below: savedTitle).click()
        assertText("多點數量：3")
        assertText("P1: 25.0330, 121.5654")
        assertText("P3: 25.0350, 121.5674")
        XCTAssertEqual(app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "裝置 UDID")).count, 3)
        rightPanelButton("刪除", below: savedTitle).click()
        XCTAssertTrue(app.staticTexts[savedTitle].waitForNonExistence(timeout: 5))
    }

    private func rightPanelButton(_ label: String, below title: String) -> XCUIElement {
        let heading = app.staticTexts[title]
        reveal(heading)
        let button = app.buttons.matching(identifier: label).allElementsBoundByIndex
            .filter { $0.frame.minY > heading.frame.minY && $0.frame.minX >= heading.frame.minX - 15 }
            .min { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(button, "\(title) 的 \(label) 按鈕必須存在")
        let result = button ?? app.buttons[label]
        reveal(result)
        return result
    }

    func testRightPanelRemainsAccessibleWithThreeDeviceSlotsAcrossModes() throws {
        launchAppWindow()
        if app.buttons["顯示右側欄"].exists { app.buttons["顯示右側欄"].click() }
        let title = app.staticTexts["匯入與收藏"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "多裝置版本仍須呈現右側匯入與收藏欄")
        for mode in ["A-B", "定點", "多點"] {
            selectMode(mode)
            let map = app.maps.firstMatch
            XCTAssertTrue(map.waitForExistence(timeout: 5))
            XCTAssertEqual(app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "裝置 UDID")).count, 3)
            XCTAssertGreaterThan(map.frame.width, 200, "地圖不能被兩側欄擠掉")
            XCTAssertGreaterThanOrEqual(title.frame.minX, map.frame.maxX - 1, "收藏欄必須在地圖右側，而非埋在左側捲動區")
            for label in ["匯入 KML", "匯入 GPX"] {
                let button = app.buttons[label]
                XCTAssertTrue(button.isHittable, "\(label) 必須直接可操作")
                XCTAssertGreaterThanOrEqual(button.frame.minX, map.frame.maxX - 1)
                XCTAssertLessThanOrEqual(button.frame.maxX, app.windows.firstMatch.frame.maxX)
            }
        }
        for label in ["匯入 KML", "匯入 GPX"] {
            app.buttons[label].click()
            let panel = app.sheets["open-panel"]
            XCTAssertTrue(panel.waitForExistence(timeout: 5))
            panel.buttons["CancelButton"].click()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5))
        }
        app.buttons["隱藏右側欄"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["顯示右側欄"].isHittable)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["顯示右側欄"].waitForExistence(timeout: 5))
        XCTAssertFalse(title.exists, "使用者收合狀態須保留，並提供重新展開入口")
        app.buttons["顯示右側欄"].click()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Three-device layout with right import and favorites panel"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // LOC-05 / LOC-07: compare the actual Return and button event paths.
    func testCoordinateReturnAndButtonAppendIdenticalWaypoints() throws {
        launchAppWindow()
        selectMode("多點")
        enterCoordinate(" 25.0330，121.5654 ", usingReturn: true)
        assertText("多點數量：1")
        assertText("P1: 25.0330, 121.5654")
        enterCoordinate(" 25.0330，121.5654 ", usingReturn: false)
        assertText("多點數量：2")
        assertText("P2: 25.0330, 121.5654")
    }

    // LOC-06: rejected inputs must not add a waypoint; valid input clears the error.
    func testInvalidCoordinateErrorsPreserveWaypoints() throws {
        launchAppWindow()
        selectMode("多點")
        enterCoordinate("25,121", usingReturn: true)
        let invalidInputs = [
            ("25;121", "格式錯誤，請輸入「緯度,經度」"),
            ("abc,121", "請輸入有效數字座標"),
            ("91,121", "座標格式錯誤"),
            ("25,181", "座標格式錯誤"),
            ("nan,121", "座標格式錯誤"),
            ("25,inf", "座標格式錯誤")
        ]
        for (input, error) in invalidInputs {
            enterCoordinate(input, usingReturn: true)
            assertText(error)
            assertText("多點數量：1")
            assertText("P1: 25.0000, 121.0000")
        }
        enterCoordinate("26,122", usingReturn: false)
        assertText("多點數量：2")
        for error in Set(invalidInputs.map { $0.1 }) {
            XCTAssertFalse(app.staticTexts[error].exists)
        }
    }

    // SET-01 / GPS-13: edit the real bound field, not the view model.
    func testSpeedFieldClampsAndRejectsMalformedValues() throws {
        launchAppWindow()
        let field = app.textFields["速度"]
        for (input, expected) in [("999", "300.0"), ("-5", "0.1"), ("18.5", "18.5"),
                                  ("invalid", "18.5"), ("nan", "18.5"), ("inf", "18.5")] {
            replaceText(in: field, with: input)
            field.typeKey(.return, modifierFlags: [])
            let normalized = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: field)
            wait(for: [normalized], timeout: 5)
            assertText("當前速度: \(expected) km/h")
        }
    }

    // GPS-08 / GPS-10 / SET-02 / SET-03; no online directions service is needed.
    func testModeSwitchWaypointReorderRemovalAndClosedLoop() throws {
        launchAppWindow()
        selectMode("多點")
        assertText("多點數量：0")
        reveal(app.buttons["移除最後點"])
        XCTAssertFalse(app.buttons["移除最後點"].isEnabled)
        enterCoordinate("25,121", usingReturn: true)
        enterCoordinate("26,122", usingReturn: false)
        enterCoordinate("27,123", usingReturn: true)
        reveal(app.buttons["將 P3 上移"])
        app.buttons["將 P3 上移"].click()
        assertText("P2: 27.0000, 123.0000")
        assertText("P3: 26.0000, 122.0000")
        reveal(app.buttons["將 P1 下移"])
        app.buttons["將 P1 下移"].click()
        assertText("P1: 27.0000, 123.0000")
        assertText("P2: 25.0000, 121.0000")
        reveal(app.buttons["移除最後點"])
        app.buttons["移除最後點"].click()
        assertText("多點數量：2")
        XCTAssertFalse(app.staticTexts["P3: 26.0000, 122.0000"].exists)
        let patrol = app.checkBoxes["來回巡邏"]
        let closedLoop = app.checkBoxes["閉圈（最後連回 P1）"]
        reveal(patrol)
        // Native macOS checkboxes expose numeric AXValue, not text-field strings.
        if (patrol.value as? NSNumber)?.boolValue != true { patrol.click() }
        XCTAssertEqual((patrol.value as? NSNumber)?.boolValue, true)
        reveal(closedLoop)
        closedLoop.click()
        XCTAssertEqual((closedLoop.value as? NSNumber)?.boolValue, true)
        XCTAssertEqual((patrol.value as? NSNumber)?.boolValue, false)
        XCTAssertFalse(patrol.isEnabled)
        closedLoop.click()
        XCTAssertEqual((closedLoop.value as? NSNumber)?.boolValue, false)
        XCTAssertEqual((patrol.value as? NSNumber)?.boolValue, false)
        XCTAssertTrue(patrol.isEnabled)
        selectMode("定點")
        XCTAssertFalse(app.staticTexts["多點數量：2"].exists)
        enterCoordinate("24,120", usingReturn: true)
        selectMode("A-B")
        selectMode("多點")
        assertText("多點數量：0")
        XCTAssertFalse(app.staticTexts["P1: 27.0000, 123.0000"].exists)
    }

    // PP-01 / PP-03 / PP-04 / PP-11: native NSOpenPanel and real persisted snapshots.
    func testKMLNamingCancelImportUpdateDeleteAndRelaunch() throws {
        let token = UUID().uuidString
        let originalTitle = "XCUI-\(token)"
        let updatedTitle = "XCUI-updated-\(token)"
        let cancelledTitle = "XCUI-cancelled-\(token)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Paperclip-XCUI-\(token)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        let file = directory.appendingPathComponent("\(originalTitle).kml")
        try writeKML(to: file, title: originalTitle, pointCount: 1)
        importedTestTitles = [originalTitle, updatedTitle, cancelledTitle]
        launchAppWindow()

        openKML(file)
        replaceText(in: app.sheets.textFields["圖層名稱"], with: cancelledTitle)
        app.sheets.buttons["取消"].click()
        XCTAssertFalse(app.staticTexts[cancelledTitle].exists)
        app.terminate()
        launchAppWindow()
        XCTAssertFalse(app.staticTexts[cancelledTitle].exists)

        openKML(file)
        XCTAssertEqual(app.sheets.textFields["圖層名稱"].value as? String, originalTitle)
        app.sheets.buttons["匯入"].click()
        assertText(originalTitle)
        XCTAssertEqual(app.staticTexts.matching(identifier: originalTitle).count, 1)
        assertOverlayPointCount(1, named: originalTitle)
        app.terminate()
        launchAppWindow()
        assertText(originalTitle)

        try writeKML(to: file, title: originalTitle, pointCount: 2)
        openKML(file)
        replaceText(in: app.sheets.textFields["圖層名稱"], with: updatedTitle)
        app.sheets.buttons["匯入"].click()
        assertText(updatedTitle)
        XCTAssertFalse(app.staticTexts[originalTitle].exists)
        app.terminate()
        launchAppWindow()
        assertText(updatedTitle)
        XCTAssertEqual(app.staticTexts.matching(identifier: updatedTitle).count, 1)
        assertOverlayPointCount(2, named: updatedTitle)
        XCTAssertFalse(app.staticTexts[originalTitle].exists)
        removeOverlay(named: updatedTitle)
        app.terminate()
        launchAppWindow()
        XCTAssertFalse(app.staticTexts[updatedTitle].exists)
        XCTAssertFalse(app.staticTexts[cancelledTitle].exists)
    }

    private func selectMode(_ title: String) {
        let mode = app.radioButtons[title]
        reveal(mode)
        mode.click()
    }

    private func enterCoordinate(_ text: String, usingReturn: Bool) {
        let field = app.textFields.matching(NSPredicate(
            format: "placeholderValue == %@", "請輸入：35.6621161,139.6986385"
        )).firstMatch
        replaceText(in: field, with: text)
        if usingReturn {
            field.typeKey(.return, modifierFlags: [])
        } else {
            app.buttons["確認"].click()
        }
    }

    private func replaceText(in field: XCUIElement, with text: String, expectedValue: String? = nil) {
        reveal(field)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        // Paste atomically: per-keystroke edits would clamp incomplete speed values.
        let pasteboard = NSPasteboard.general
        let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let restored = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        selectASCIIKeyboard()
        field.typeKey("v", modifierFlags: .command)
        // Keep the paste payload alive until the target app has consumed the event.
        let received = expectation(
            for: NSPredicate(format: "value == %@", expectedValue ?? text), evaluatedWith: field
        )
        wait(for: [received], timeout: 5)
    }

    private func assertText(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 5), text, file: file, line: line)
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let rightPanel = app.scrollViews["rightPanelScrollView"]
        let scrollView = rightPanel.exists && element.frame.midX >= rightPanel.frame.minX
            ? rightPanel : app.scrollViews.firstMatch
        func isVisible() -> Bool {
            guard element.isHittable else { return false }
            // XCUI reports clipped SwiftUI children as hittable; their coordinates can
            // otherwise hit the fixed footer instead of the intended sidebar control.
            if app.sheets.firstMatch.exists { return true }
            return scrollView.frame.contains(element.frame)
        }
        if isVisible() { return }
        for _ in 0..<20 {
            scrollView.scroll(byDeltaX: 0, deltaY: 450)
            if isVisible() { return }
        }
        for _ in 0..<40 {
            scrollView.scroll(byDeltaX: 0, deltaY: -450)
            if isVisible() { return }
        }
        XCTFail("Control is not reachable: \(element)")
    }

    private func openKML(_ file: URL) {
        openImport(file, buttonLabel: "匯入 KML", namingTitle: "設定純點圖層名稱")
    }

    private func openImport(_ file: URL, buttonLabel: String, namingTitle: String) {
        let importButton = app.buttons[buttonLabel]
        reveal(importButton)
        importButton.click()
        let openPanel = app.sheets["open-panel"]
        XCTAssertTrue(openPanel.waitForExistence(timeout: 5))
        // 原生面板可記住圖像、列表或欄位檢視；不依賴其中一種檢視的子元素。
        selectASCIIKeyboard()
        openPanel.typeKey("g", modifierFlags: [.command, .shift])
        let pathSheet = openPanel.sheets.firstMatch
        let pathField = pathSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5), "Native Go to Folder sheet must be accessible")
        replaceText(in: pathField, with: file.path)
        pathField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(pathSheet.waitForNonExistence(timeout: 5))
        let openButton = openPanel.buttons["OKButton"]
        let readyToOpen = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: openButton)
        XCTAssertEqual(XCTWaiter.wait(for: [readyToOpen], timeout: 5), .completed)
        openButton.click()
        XCTAssertTrue(app.sheets.staticTexts[namingTitle].waitForExistence(timeout: 5))
    }

    private func assertOverlayPointCount(_ count: Int, named title: String) {
        let toggle = app.checkBoxes["開啟\(title)"]
        reveal(toggle)
        // Native macOS checkboxes expose NSNumber, not String, accessibility values.
        guard let isEnabled = (toggle.value as? NSNumber)?.boolValue else {
            XCTFail("Expected a numeric enabled value for \(title)")
            return
        }
        if !isEnabled { toggle.click() }
        XCTAssertEqual((toggle.value as? NSNumber)?.boolValue, true)
        let label = app.staticTexts[title]
        let matchingCounts = app.staticTexts.matching(identifier: "顯示 \(count) / \(count) 個點位")
            .allElementsBoundByIndex.filter {
                $0.frame.minY > label.frame.minY && $0.frame.minY < label.frame.minY + 130
                    && abs($0.frame.minX - label.frame.minX) < 30
            }
        XCTAssertEqual(matchingCounts.count, 1, "Imported point count must belong to \(title)")
    }

    private func removeOverlay(named title: String) {
        let label = app.staticTexts[title]
        reveal(label)
        // Choose only the menu on this unique test title's header row, never a global Remove.
        let menus = app.descendants(matching: .menuButton).allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minX >= label.frame.maxX
                && abs($0.frame.midY - label.frame.midY) < 20
        }
        XCTAssertEqual(menus.count, 1, "Expected this test overlay's own removal menu")
        guard let menu = menus.first, menus.count == 1 else { return }
        menu.click()
        app.menuItems["移除"].click()
        XCTAssertTrue(label.waitForNonExistence(timeout: 5))
    }

    private func writeKML(to file: URL, title: String, pointCount: Int) throws {
        let points = (0..<pointCount).map {
            "<Placemark><name>XCUI point \($0)</name><Point><coordinates>\(121 + $0),25,0</coordinates></Point></Placemark>"
        }.joined()
        try "<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>\(title)</name>\(points)</Document></kml>"
            .write(to: file, atomically: true, encoding: .utf8)
    }
    @MainActor
    func testThreeDeviceSlots() throws {
        launchAppWindow()
        for number in 1...3 {
            XCTAssertTrue(app.staticTexts["裝置 \(number)"].exists)
        }
        XCTAssertEqual(app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "裝置 UDID")).count, 3)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            launchAppWindow()
        }
    }
}
