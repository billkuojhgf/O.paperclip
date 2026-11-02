import AppKit
import Carbon
import Darwin
import Network
import XCTest

// A real loopback HTTP endpoint: the production Data(contentsOf:) fetch must reach it.
// Invalid XML makes the approved-fetch error deterministic without an external service.
private final class InvalidKMLServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Paperclip.XCUI.KMLServer")
    private let lock = NSLock()
    private var requests = 0
    private var isReady = false
    private var heldConnections: [NWConnection] = []
    private let holdsResponses: Bool

    var requestCount: Int { lock.withLock { requests } }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/invalid.kml")! }

    init(holdsResponses: Bool = false) throws {
        self.holdsResponses = holdsResponses
        // Reserve an OS-selected port instead of NWEndpoint.Port.any: the latter
        // can remain zero in listener.port even after Network reports .ready.
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard socketFD >= 0 else { throw Self.socketError("socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.socketError("bind")
            Darwin.close(socketFD)
            throw error
        }
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(socketFD, $0, &addressLength)
            }
        }
        let portNumber = UInt16(bigEndian: address.sin_port)
        let error = Self.socketError("getsockname")
        Darwin.close(socketFD)
        guard nameResult == 0, portNumber != 0, let port = NWEndpoint.Port(rawValue: portNumber) else {
            throw error
        }
        // A competing bind between reservation and start is a hard fixture failure.
        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: port)
    }

    private static func socketError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Loopback HTTP fixture \(operation) failed (errno \(errno))"
        ])
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.lock.withLock { self?.isReady = true }
                ready.signal()
            case .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
                guard let self, let data, !data.isEmpty else { connection.cancel(); return }
                self.lock.withLock { self.requests += 1 }
                if self.holdsResponses {
                    self.lock.withLock { self.heldConnections.append(connection) }
                    return
                }
                let body = "not an XML document"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.google-earth.kml+xml\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, lock.withLock({ isReady }),
              let port = listener.port, port.rawValue != 0 else {
            listener.cancel()
            throw NSError(domain: "PaperclipUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP listener did not become ready"])
        }
    }

    func stop() {
        let held = lock.withLock { let held = heldConnections; heldConnections = []; return held }
        held.forEach { $0.cancel() }
        listener.cancel()
    }
}

@MainActor
final class QAIntegrationUITests: XCTestCase {
    private var app: XCUIApplication!
    private var applicationURL: URL!
    private var temporaryDirectory: URL!
    private var importedTitles: [String] = []
    private var originalInputSource: TISInputSource?

    override func setUp() async throws {
        continueAfterFailure = false
        originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        selectASCIIKeyboard()
        applicationURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("O.Paperclip.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: applicationURL.appendingPathComponent("Contents/Info.plist").path) else {
            throw NSError(domain: "PaperclipUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built application missing at \(applicationURL.path)"])
        }
        app = XCUIApplication(url: applicationURL)
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Paperclip-Integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defer { if let originalInputSource { TISSelectInputSource(originalInputSource) } }
        if let app {
            if !importedTitles.isEmpty {
                app.terminate()
                launchAppWindow()
                for title in importedTitles where app.staticTexts[title].exists { removeOverlay(named: title) }
            }
            app.terminate()
        }
        if let temporaryDirectory { try FileManager.default.removeItem(at: temporaryDirectory) }
    }

    // PP-05 / PP-07: approval gates a real HTTP request; neither cancel nor failure
    // commits the local point from that file. A subsequent ordinary import succeeds.
    func testNetworkLinkCancelApprovedFailureAndImportRecovery() throws {
        let server = try InvalidKMLServer()
        try server.start()
        defer { server.stop() }
        let token = UUID().uuidString
        let baselineTitle = "XCUI-baseline-\(token)"
        let remoteTitle = "XCUI-remote-\(token)"
        let recoveredTitle = "XCUI-recovered-\(token)"
        importedTitles = [baselineTitle, remoteTitle, recoveredTitle]
        let baseline = try writeKML(title: baselineTitle)
        let remote = try writeKML(title: remoteTitle, remoteURL: server.url)
        let recovered = try writeKML(title: recoveredTitle)
        launchAppWindow()
        importLocalKML(baseline, title: baselineTitle)

        chooseKML(remote)
        assertText("需要確認遠端 KML", in: app.sheets)
        assertText(server.url.absoluteString, in: app.sheets)
        XCTAssertEqual(server.requestCount, 0, "Preview must not fetch an unapproved NetworkLink")
        app.sheets.buttons["取消"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertFalse(app.staticTexts[remoteTitle].exists)
        assertText(baselineTitle)

        chooseKML(remote)
        assertText("需要確認遠端 KML", in: app.sheets)
        XCTAssertEqual(server.requestCount, 0)
        app.sheets.buttons["確認下載"].click()
        assertText("KML 內容無法解析。")
        XCTAssertEqual(server.requestCount, 1, "Approval must exercise the production HTTP fetch")
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[remoteTitle].exists, "An import with a failed remote child must be atomic")
        assertText(baselineTitle)

        importLocalKML(recovered, title: recoveredTitle)
        XCTAssertFalse(app.staticTexts["KML 內容無法解析。"].exists)
        assertText(baselineTitle)
        chooseKML(remote)
        assertText("需要確認遠端 KML", in: app.sheets)
        XCTAssertEqual(server.requestCount, 1, "Approval must not leak into a later import session")
        app.sheets.buttons["取消"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
        app.terminate()
        launchAppWindow()
        assertText(baselineTitle)
        assertText(recoveredTitle)
        XCTAssertFalse(app.staticTexts[remoteTitle].exists)
    }

    func testPendingRemoteImportRemainsResponsiveAndCancellationDiscardsResult() throws {
        let server = try InvalidKMLServer(holdsResponses: true)
        try server.start()
        defer { server.stop() }
        let title = "XCUI-pending-\(UUID().uuidString)"
        let file = try writeKML(title: title, remoteURL: server.url)
        launchAppWindow()
        chooseKML(file)
        assertText("需要確認遠端 KML", in: app.sheets)
        app.sheets.buttons["確認下載"].click()
        let requested = expectation(for: NSPredicate { _, _ in server.requestCount == 1 }, evaluatedWith: nil)
        wait(for: [requested], timeout: 5)
        let cancel = app.buttons["取消匯入"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable, "Pending import cancellation must remain responsive")
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        let fixedMode = app.radioButtons["定點"]
        reveal(fixedMode)
        fixedMode.click()
        XCTAssertEqual((fixedMode.value as? NSNumber)?.boolValue, true)
        server.stop()
        XCTAssertFalse(app.sheets.staticTexts["設定純點圖層名稱"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts[title].exists)
    }

    // QA-01 / QA-02: kill the actual built app, not a fabricated marker. This leaves
    // a genuine incident/lifecycle history in its normal diagnostics directory.
    func testUnexpectedTerminationNoticeOpensFinderAndCleanRelaunchClearsNotice() throws {
        launchAppWindow()
        let bundle = try XCTUnwrap(Bundle(url: applicationURL))
        let bundleID = try XCTUnwrap(bundle.bundleIdentifier)
        // The UI test runner is sandboxed, while this application is not
        // (O_Paperclip.entitlements is empty). Resolve the account's real home.
        let account = try XCTUnwrap(getpwuid(getuid()))
        let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let logs = support.appendingPathComponent(bundleID.replacingOccurrences(of: ".", with: "-"))
            .appendingPathComponent("Logs", isDirectory: true)
        let marker = logs.appendingPathComponent("active-session.json")
        let markerData = try Data(contentsOf: marker)
        let session = try XCTUnwrap(JSONSerialization.jsonObject(with: markerData) as? [String: Any])
        let previousSessionID = try XCTUnwrap(session["sessionID"] as? String)
        let running = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL
        })
        XCTAssertTrue(running.forceTerminate(), "Must force-stop only this test's built application")
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        launchAppWindow()
        assertText("上次啟動疑似非正常結束")
        assertText("偵測到上一個 session 沒有正常結束，可能是閒置時 crash 或被系統強制終止。")
        assertText(logs.path)
        let incidentData = try Data(contentsOf: logs.appendingPathComponent("incidents.jsonl"))
        let incidents = try String(decoding: incidentData, as: UTF8.self).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        XCTAssertTrue(incidents.contains { $0?["previousSessionID"] as? String == previousSessionID })

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let hadLogsWindow = finder.windows["Logs"].exists
        let openFolder = app.buttons["開啟診斷資料夾"]
        reveal(openFolder)
        openFolder.click()
        XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5), "NSWorkspace must activate Finder")
        let folderWindow = finder.windows["Logs"]
        XCTAssertTrue(folderWindow.waitForExistence(timeout: 5), "Finder must show the diagnostics Logs folder")
        // Close only a newly opened window, never a pre-existing user Finder window.
        if !hadLogsWindow {
            folderWindow.typeKey("w", modifierFlags: .command)
        }
        app.activate()
        selectASCIIKeyboard()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Command-Q must exercise willTerminate")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Normal quit must remove the active marker")
        launchAppWindow()
        XCTAssertFalse(app.staticTexts["上次啟動疑似非正常結束"].exists)
        XCTAssertFalse(app.buttons["開啟診斷資料夾"].exists)
    }

    private func launchAppWindow() {
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 5) {
            app.activate()
            app.menuBars.menuBarItems["File"].click()
            app.menuItems["New Window"].click()
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        // NSOpenPanel's XPC process can outlive a failed test's app termination.
        // Cancel restored sheets before touching the otherwise disabled sidebar.
        for _ in 0..<3 {
            let sheet = app.sheets.firstMatch
            if !sheet.exists { break }
            let nested = sheet.sheets.firstMatch
            if nested.exists {
                nested.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(nested.waitForNonExistence(timeout: 5))
            } else {
                let nativeCancel = sheet.buttons["CancelButton"]
                let importCancel = sheet.buttons["取消"]
                if nativeCancel.exists {
                    nativeCancel.click()
                } else if importCancel.exists {
                    importCancel.click()
                } else {
                    XCTFail("Unexpected restored modal: \(sheet.debugDescription)")
                    break
                }
                XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
            }
        }
        XCTAssertFalse(app.sheets.firstMatch.exists, "Launch must leave no restored modal sheets")
    }

    private func selectASCIIKeyboard() {
        let target = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        func sourceID(_ source: TISInputSource) -> String? {
            guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
            return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        }
        guard let targetID = sourceID(target) else {
            XCTFail("ASCII keyboard layout must expose an input-source ID")
            return
        }
        XCTAssertEqual(TISSelectInputSource(target), noErr)
        let selected = expectation(for: NSPredicate { _, _ in
            sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue()) == targetID
        }, evaluatedWith: nil)
        wait(for: [selected], timeout: 5)
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        reveal(field)
        field.click()
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
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        selectASCIIKeyboard()
        field.typeKey("v", modifierFlags: .command)
        let received = expectation(for: NSPredicate(format: "value == %@", text), evaluatedWith: field)
        wait(for: [received], timeout: 5)
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let scroll = app.scrollViews.firstMatch
        func visible() -> Bool {
            element.isHittable && (app.sheets.firstMatch.exists || scroll.frame.contains(element.frame))
        }
        if visible() { return }
        for _ in 0..<20 {
            scroll.scroll(byDeltaX: 0, deltaY: 450)
            if visible() { return }
        }
        for _ in 0..<40 {
            scroll.scroll(byDeltaX: 0, deltaY: -450)
            if visible() { return }
        }
        XCTFail("Control is not reachable: \(element)")
    }

    private func assertText(_ text: String, in query: XCUIElementQuery? = nil) {
        XCTAssertTrue((query?.staticTexts ?? app.staticTexts).matching(identifier: text).firstMatch.waitForExistence(timeout: 5), text)
    }

    private func chooseKML(_ file: URL) {
        let importButton = app.buttons["匯入 KML"]
        reveal(importButton)
        importButton.click()
        let panel = app.sheets["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        let browser = panel.descendants(matching: .browser)["ColumnView"]
        XCTAssertTrue(browser.waitForExistence(timeout: 5))
        browser.click()
        selectASCIIKeyboard()
        browser.typeKey("g", modifierFlags: [.command, .shift])
        let pathSheet = panel.sheets.firstMatch
        let pathField = pathSheet.textFields.firstMatch
        XCTAssertTrue(pathField.waitForExistence(timeout: 5))
        replaceText(in: pathField, with: file.path)
        pathField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(pathSheet.waitForNonExistence(timeout: 5))
        let openButton = panel.buttons["OKButton"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: openButton)
        wait(for: [ready], timeout: 5)
        openButton.click()
    }

    private func importLocalKML(_ file: URL, title: String) {
        chooseKML(file)
        assertText("設定純點圖層名稱", in: app.sheets)
        replaceText(in: app.sheets.textFields["圖層名稱"], with: title)
        app.sheets.buttons["匯入"].click()
        assertText(title)
    }

    private func writeKML(title: String, remoteURL: URL? = nil) throws -> URL {
        let link = remoteURL.map { "<NetworkLink><Link><href>\($0.absoluteString)</href></Link></NetworkLink>" } ?? ""
        let file = temporaryDirectory.appendingPathComponent("\(title).kml")
        try "<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document><name>\(title)</name><Placemark><name>XCUI point</name><Point><coordinates>121,25,0</coordinates></Point></Placemark>\(link)</Document></kml>"
            .write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func removeOverlay(named title: String) {
        let label = app.staticTexts[title]
        reveal(label)
        let menus = app.descendants(matching: .menuButton).allElementsBoundByIndex.filter {
            $0.isHittable && $0.frame.minX >= label.frame.maxX && abs($0.frame.midY - label.frame.midY) < 20
        }
        XCTAssertEqual(menus.count, 1, "Only this unique test overlay's removal menu may be used")
        guard let menu = menus.first, menus.count == 1 else { return }
        menu.click()
        app.menuItems["移除"].click()
        XCTAssertTrue(label.waitForNonExistence(timeout: 5))
    }
}
