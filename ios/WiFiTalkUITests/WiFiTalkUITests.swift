import XCTest

/// Presses every control of the app in the simulator against `tests/mock_companion.py`, which stands in for the
/// Windows companion and records each action it receives, then checks the record.
///
/// The mock listens on 127.0.0.1:47821 (PIN 123456) and answers questions on 127.0.0.1:47822. The tests run in
/// name order; the first one pairs, and the pairing is kept for the rest.
final class WiFiTalkUITests: XCTestCase {
    let app = XCUIApplication()
    static let mock = "http://127.0.0.1:47822"

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments += [
            "-uitestCommandAudio", Self.mock + "/audio/command.wav",
            "-uitestDictationAudio", Self.mock + "/audio/dictation.wav",
        ]
        app.launch()
        resetMock()
    }

    // MARK: the mock computer

    private func get(_ path: String) -> Data {
        let done = expectation(description: path)
        var result = Data()
        URLSession.shared.dataTask(with: URL(string: Self.mock + path)!) { data, _, _ in
            result = data ?? Data()
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }

    private func resetMock() {
        var request = URLRequest(url: URL(string: Self.mock + "/reset")!)
        request.httpMethod = "POST"
        let done = expectation(description: "reset")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    private func actions() -> [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: get("/log"))) as? [[String: Any]] ?? []
    }

    private func stats() -> [String: Int] {
        (try? JSONSerialization.jsonObject(with: get("/stats"))) as? [String: Int] ?? [:]
    }

    /// Waits until the mock has received an action that matches, and returns it.
    @discardableResult
    private func waitForAction(_ what: String, timeout: TimeInterval = 10,
                               _ match: @escaping ([String: Any]) -> Bool) -> [String: Any]? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let hit = actions().first(where: match) { return hit }
            allowSystemAlerts()
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("The computer never received: \(what). It received: \(actions())")
        return nil
    }

    private func keys() -> [String] {
        actions().filter { $0["t"] as? String == "keys" }.compactMap { $0["k"] as? String }
    }

    private func typed() -> String {
        actions().filter { $0["t"] as? String == "text" }.compactMap { $0["s"] as? String }.joined()
    }

    /// Taps "Allow" on any permission or paste prompt the system shows.
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
        let b = app.buttons[id]
        XCTAssertTrue(b.waitForExistence(timeout: 10), "missing button \(id)")
        return b
    }

    private func step(_ name: String) {
        // a pause and a line in the log, so the recorded video can be followed
        print("UITEST STEP: \(name)")
        Thread.sleep(forTimeInterval: 0.8)
    }

    // MARK: the tests

    func test01_PairsWithTheComputer() {
        step("pairing")
        if !app.buttons["connection"].waitForExistence(timeout: 3) {
            let fields = app.textFields
            XCTAssertTrue(fields.element(boundBy: 0).waitForExistence(timeout: 10))
            fields.element(boundBy: 0).tap()
            fields.element(boundBy: 0).typeText("127.0.0.1")
            fields.element(boundBy: 1).tap()
            fields.element(boundBy: 1).typeText("123456")
            app.buttons["Connect"].tap()
        }
        XCTAssertTrue(app.buttons["connection"].waitForExistence(timeout: 15), "the main screen did not open after pairing")
        waitForAction("a hello") { $0["t"] as? String == "hello" || $0["t"] as? String == "ping" }
    }

    func test02_ArrowKeys() {
        step("arrow keys")
        for id in ["up", "down", "left", "right"] { button(id).tap(); Thread.sleep(forTimeInterval: 0.3) }
        waitForAction("the right arrow") { $0["k"] as? String == "right" }
        XCTAssertEqual(keys(), ["up", "down", "left", "right"])
    }

    func test03_EscTabAndCtrl() {
        step("Esc, Tab, Ctrl+C, Shift")
        button("key-esc").tap()
        button("key-tab").tap()
        button("key-ctrl").tap()
        app.textViews["textBox"].tap()
        app.textViews["textBox"].typeText("c")
        waitForAction("Ctrl+C") { $0["k"] as? String == "ctrl+c" }
        XCTAssertTrue(keys().contains("escape"), "Esc not received: \(keys())")
        XCTAssertTrue(keys().contains("tab"), "Tab not received: \(keys())")
        button("key-alt").tap()
        button("key-tab").tap()
        waitForAction("Alt+Tab") { $0["k"] as? String == "alt+tab" }
        button("key-shift").tap()
        button("left").tap()
        waitForAction("Shift+Left") { $0["k"] as? String == "shift+left" }
    }

    func test04_TypingGoesStraightToTheComputer() {
        step("typing")
        let box = app.textViews["textBox"]
        box.tap()
        box.typeText("Hello")
        waitForAction("the typed text") { _ in self.typed().contains("Hello") }
        box.typeText(XCUIKeyboardKey.delete.rawValue)
        waitForAction("a backspace") { $0["k"] as? String == "backspace" }
    }

    func test05_Clipboard() {
        step("clipboard both ways")
        // the computer's clipboard comes to the iPhone, then goes back: both directions, with no paste prompt
        button("getFromPC").tap()
        waitForAction("a clipboard request") { $0["t"] as? String == "getclip" }
        let copied = NSPredicate(format: "label CONTAINS 'Copied the computer clipboard'")
        XCTAssertTrue(app.staticTexts.matching(copied).firstMatch.waitForExistence(timeout: 10), "no confirmation on screen")
        button("copyToPC").tap()
        allowSystemAlerts()
        waitForAction("the iPhone's clipboard") { $0["t"] as? String == "clip" && $0["s"] as? String == "Text from the computer" }
    }

    func test06_TrackpadMovesAndClicks() {
        step("trackpad")
        let pad = app.otherElements["trackpad"].exists ? app.otherElements["trackpad"] : app.descendants(matching: .any)["trackpad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 10))
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        let end = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        waitForAction("a mouse move") { $0["t"] as? String == "move" }
        let moved = actions().filter { $0["t"] as? String == "move" }
        let dx = moved.compactMap { ($0["dx"] as? NSNumber)?.doubleValue }.reduce(0, +)
        XCTAssertGreaterThan(dx, 0, "the pointer should move right")
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForAction("a click") { $0["t"] as? String == "click" }
    }

    func test07_RestartAsksThenRestarts() {
        step("restart")
        button("restart").tap()
        let alert = app.alerts["Restart the computer?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Restart"].tap()
        waitForAction("restart") { $0["t"] as? String == "power" && $0["s"] as? String == "restart" }
    }

    func test08_ShutDownAsksThenShutsDown() {
        step("shut down")
        button("shutdown").tap()
        let alert = app.alerts["Shut down the computer?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Shut down"].tap()
        waitForAction("shut down") { $0["t"] as? String == "power" && $0["s"] as? String == "shutdown" }
    }

    func test09_ComputerSoundPlaysOnTheIPhone() {
        step("computer sound on the iPhone")
        let speaker = button("speaker")
        speaker.tap()
        waitForAction("speaker on") { $0["t"] as? String == "speaker" && $0["on"] as? Bool == true }
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(speaker.value as? String, "on", "the headphones key should be on")
        XCTAssertGreaterThan(stats()["speaker_bytes"] ?? 0, 100_000, "the computer's sound should be streaming")
        speaker.tap()
        waitForAction("speaker off") { $0["t"] as? String == "speaker" && $0["on"] as? Bool == false }
    }

    func test10_IPhoneAsTheComputersMicrophone() {
        step("the iPhone as the computer's microphone")
        let mic = button("mic")
        mic.tap()
        allowSystemAlerts()
        waitForAction("microphone on") { $0["t"] as? String == "mic" && $0["on"] as? Bool == true }
        Thread.sleep(forTimeInterval: 4)
        let bytes = stats()["mic_bytes"] ?? 0
        print("UITEST MIC BYTES: \(bytes)")
        XCTAssertEqual(mic.value as? String, "on", "the microphone key should be on")
        XCTAssertGreaterThan(bytes, 50_000, "the iPhone's microphone should be streaming to the computer")
        mic.tap()
        waitForAction("microphone off") { $0["t"] as? String == "mic" && $0["on"] as? Bool == false }
    }

    func test11_VoiceCommand() {
        step("voice command: open Notepad and write hello world")
        let command = button("command")
        command.tap()
        Thread.sleep(forTimeInterval: 1.5)
        command.tap()
        allowSystemAlerts()
        waitForAction("open Notepad", timeout: 120) { ($0["t"] as? String == "open") && ((($0["s"] as? String) ?? "").lowercased().contains("notepad")) }
        waitForAction("typing hello", timeout: 60) { _ in self.typed().lowercased().contains("hello") }
        Thread.sleep(forTimeInterval: 2)
        print("UITEST COMMAND ACTIONS: \(actions())")
    }

    func test12_TypedCommand() {
        step("typed command: lock the computer")
        let command = button("command")
        command.press(forDuration: 1.0)
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "a long press should ask for a typed command")
        field.typeText("Lock the computer")
        app.alerts.buttons["Do it"].tap()
        waitForAction("lock", timeout: 120) { $0["t"] as? String == "power" && $0["s"] as? String == "lock" }
    }

    func test13_DictationWithAIProofreading() {
        step("dictation, proofread by the hybrid AI")
        let dictate = button("dictate")
        dictate.tap()
        Thread.sleep(forTimeInterval: 1.5)
        dictate.tap()
        allowSystemAlerts()
        waitForAction("the dictated text", timeout: 120) { _ in self.typed().lowercased().contains("dictation") }
        print("UITEST DICTATION: \(typed())")
    }

    func test14_FilesFromTheComputer() {
        step("files")
        button("files").tap()
        let file = app.staticTexts["hello.txt"]
        XCTAssertTrue(file.waitForExistence(timeout: 10), "the shared folder should list hello.txt")
        file.tap()
        waitForAction("a file request") { $0["t"] as? String == "get" && $0["s"] as? String == "hello.txt" }
        Thread.sleep(forTimeInterval: 3)
    }

    func test15_SettingsShowTheBuiltInAI() {
        step("settings")
        button("settings").tap()
        XCTAssertTrue(app.staticTexts["Built-in AI"].waitForExistence(timeout: 5) || app.otherElements["Built-in AI"].exists)
        let ready = NSPredicate(format: "label CONTAINS 'Ready with no key'")
        XCTAssertTrue(app.staticTexts.matching(ready).firstMatch.waitForExistence(timeout: 5), "the built-in AI should be ready")
        Thread.sleep(forTimeInterval: 2)
    }
}
