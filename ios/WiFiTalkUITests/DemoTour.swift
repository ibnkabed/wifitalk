import XCTest

/// The footage for the demo video (run by `.github/workflows/demo-video.yml`, skipped by the simulator test):
/// one unhurried pass over every control of the app, in one launch, against `tests/mock_companion.py`.
/// Before each part it posts a mark to the mock (`POST /mark/<name>`), so the video can be cut into scenes and
/// the actions the computer received can be shown beside the phone at the right moments.
final class DemoTour: XCTestCase {
    let app = XCUIApplication()
    static let mock = "http://127.0.0.1:47822"

    private func post(_ path: String) {
        var request = URLRequest(url: URL(string: Self.mock + path)!)
        request.httpMethod = "POST"
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    private func mark(_ name: String) {
        post("/mark/" + name)
        print("DEMO MARK: \(name)")
    }

    private func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    private func allowSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for owner in [springboard, app] {
            for title in ["Allow", "OK", "Allow Paste", "Allow While Using App"] {
                let button = owner.alerts.buttons[title].firstMatch
                if button.exists { button.tap(); return }
            }
        }
    }

    private func button(_ id: String) -> XCUIElement {
        let b = app.buttons[id].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 10), "missing button \(id)")
        return b
    }

    private func tap(_ id: String, then s: Double = 1.2) {
        button(id).tap()
        pause(s)
    }

    /// Waits up to `timeout` seconds, tapping away permission prompts, while something happens on screen.
    private func settle(_ timeout: Double) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { allowSystemAlerts(); pause(0.5) }
    }

    func testDemoTour() {
        continueAfterFailure = true
        app.launchArguments += [
            "-uitestCommandAudio", Self.mock + "/audio/command.wav",
            "-uitestDictationAudio", Self.mock + "/audio/dictation.wav",
            "-demoSnippets", "YES",
        ]
        app.launch()
        post("/reset")

        // 1. pairing with the computer's address and its six-digit PIN
        mark("pair")
        pause(2)
        let fields = app.textFields
        if fields.element(boundBy: 0).waitForExistence(timeout: 10) {
            fields.element(boundBy: 0).tap()
            fields.element(boundBy: 0).typeText("192.168.1.20")
            pause(0.6)
            // the simulator's computer is the Mac itself
            fields.element(boundBy: 0).press(forDuration: 1.0)
            if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
            fields.element(boundBy: 0).typeText("127.0.0.1")
            fields.element(boundBy: 1).tap()
            fields.element(boundBy: 1).typeText("123456")
            pause(0.8)
            app.buttons["Connect"].tap()
        }
        XCTAssertTrue(app.buttons["connection"].waitForExistence(timeout: 15))
        pause(2.5)

        // 2. the header: connection check
        mark("header")
        tap("connection", then: 2.5)

        // 3. the arrows and the modifier keys
        mark("keys")
        for id in ["up", "right", "down", "left"] { tap(id, then: 0.7) }
        tap("key-esc", then: 0.9)
        tap("key-tab", then: 0.9)
        tap("key-alt", then: 0.6)
        tap("key-tab", then: 1.0)
        tap("key-shift", then: 0.6)
        tap("right", then: 1.2)

        // 4. the trackpad: move, then tap to click
        mark("trackpad")
        let pad = app.descendants(matching: .any)["trackpad"].firstMatch
        if pad.waitForExistence(timeout: 5) {
            pad.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.6))
                .press(forDuration: 0.1, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3)))
            pause(0.8)
            pad.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4))
                .press(forDuration: 0.1, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.65)))
            pause(0.8)
            pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            pause(1.5)
        }

        // 5. the clipboard, both ways
        mark("clipboard")
        tap("getFromPC", then: 2.5)
        button("copyToPC").tap()
        settle(3)

        // 6. saved texts behind the header's clipboard button
        mark("snippets")
        app.buttons["Paste snippets"].firstMatch.tap()
        pause(1.5)
        let snippet = app.buttons["Email signature"].firstMatch
        if snippet.waitForExistence(timeout: 5) { snippet.tap() }
        pause(2)

        // 7. files from the computer's shared folder
        mark("files")
        tap("files", then: 2)
        let file = app.staticTexts["hello.txt"].firstMatch
        if file.waitForExistence(timeout: 8) { file.tap() }
        pause(3)
        app.swipeDown(velocity: .fast)
        pause(1.5)

        // 8. the computer's sound on the iPhone
        mark("speaker")
        tap("speaker", then: 4)
        tap("speaker", then: 1)

        // 9. the iPhone as the computer's microphone
        mark("mic")
        button("mic").tap()
        settle(4)
        tap("mic", then: 1)

        // 10. dictation, proofread by the hybrid AI
        mark("dictation")
        tap("dictationMode", then: 1.2)
        tap("dictationMode", then: 1.2)
        tap("dictate", then: 2)
        tap("dictate")
        settle(14)

        // 11. a spoken command, planned by the hybrid AI
        mark("command")
        tap("command", then: 2)
        tap("command")
        settle(16)

        // 12. a typed command (long press)
        mark("typed")
        button("command").press(forDuration: 1.0)
        let field = app.alerts.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.typeText("Lock the computer")
            pause(1)
            app.alerts.buttons["Do it"].tap()
        }
        settle(12)

        // 13. typing straight into the computer
        mark("typing")
        let box = app.textViews["textBox"].firstMatch
        box.tap()
        pause(1)
        for word in ["Hello ", "from ", "my ", "iPhone"] { box.typeText(word); pause(0.4) }
        pause(1.5)
        tap("clear", then: 1.5)

        // 14. restart and shut down, each asking first
        mark("power")
        tap("restart", then: 1.5)
        app.alerts.buttons["Restart"].firstMatch.tap()
        pause(2)
        tap("shutdown", then: 1.5)
        app.alerts.buttons["Shut down"].firstMatch.tap()
        pause(2)

        // 15. the settings: the built-in hybrid AI
        mark("settings")
        tap("settings", then: 2)
        let ai = app.staticTexts["Built-in AI"].firstMatch
        for _ in 0..<4 where !ai.isHittable { app.swipeUp(velocity: .slow); pause(0.8) }
        pause(4)
        mark("end")
    }
}
