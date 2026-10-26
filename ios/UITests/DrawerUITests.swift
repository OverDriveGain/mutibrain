import XCTest

/// Screenshot walk through the voice <-> chat drawer (2026-10-24). Not a pass/
/// fail suite so much as the QA camera: it accepts the system alerts, drives
/// the real gestures (tap the peek, drag the grabber, focus the composer) and
/// writes a PNG per state to ~/myagent/shots on the Mac, which the berlin side
/// stitches into a contact sheet. Runs against the live servers with the baked
/// subscriber token — it never starts the voice session (that would open a
/// real Gemini Live session on prod).
///
///   xcodebuild test -scheme AIAssistant -destination 'platform=iOS Simulator,id=…' \
///     -only-testing:AIAssistantUITests/DrawerUITests
final class DrawerUITests: XCTestCase {
    private let outDir = "/Users/manar/myagent/shots"

    override func setUp() { continueAfterFailure = true }

    func testDrawerWalk() {
        let app = XCUIApplication()
        app.launchEnvironment["MYAGENT_QA"] = "1"
        app.launch()
        allowSystemAlert()
        sleep(9)                                   // embed + MyMu roster + transcript
        save("01-closed")

        // closed -> half: tap the brain's peek line
        let peek = app.otherElements["brain-peek"].firstMatch
        if peek.waitForExistence(timeout: 5) { peek.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap() }
        sleep(4)
        save("02-half")
        XCTAssertTrue(app.buttons["talk-button"].exists, "seam mic missing at half")

        // half -> full: drag the grabber to the top
        let grabber = app.otherElements["drawer-grabber"].firstMatch
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
        if grabber.waitForExistence(timeout: 3) {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15, thenDragTo: top)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.15, thenDragTo: top)
        }
        sleep(3)
        save("03-full")
        XCTAssertTrue(app.buttons["Back to voice"].waitForExistence(timeout: 4), "waveform button missing at full")

        // full -> half: drag the grabber back down to the middle
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
        if grabber.exists { grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15, thenDragTo: middle) }
        sleep(3)
        save("04-half-again")

        // typing lifts half -> full: focus MyMu's composer
        let field = app.textFields["composer-input"].firstMatch   // MyMu's composer
        if field.waitForExistence(timeout: 4) { field.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93)).tap() }
        sleep(3)
        save("05-keyboard")

        // and back to voice: drag the grabber all the way down
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97))
        if grabber.waitForExistence(timeout: 3) { grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.15, thenDragTo: bottom) }
        sleep(3)
        save("06-closed-again")
    }

    /// The notification permission alert (and any other system alert) on top
    /// of the app — accept it so the screenshots are of the app, not the alert.
    private func allowSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Allow", "OK"] {
            let b = springboard.buttons[title]
            if b.waitForExistence(timeout: 4) { b.tap(); sleep(1) }
        }
    }

    /// The home's massam controls + the Screen panel's new home in Settings.
    func testHomeScreenButton() {
        let app = XCUIApplication()
        app.launchEnvironment["MYAGENT_QA"] = "1"
        app.launch()
        allowSystemAlert()
        sleep(9)
        save("11-home")
        // the ▦ dock toggle (right edge, above the peek)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.915, dy: 0.632)).tap()
        sleep(2)
        save("12-dock-open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.915, dy: 0.632)).tap()
        sleep(1)
        // the Screen button: straight to iOS's broadcast sheet
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.79, dy: 0.632)).tap()
        sleep(3)
        save("15-broadcast-sheet")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        sleep(2)
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'gear' OR label CONTAINS[c] 'settings'")).firstMatch.tap()
        sleep(2)
        let sp = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Screenpipe'")).firstMatch
        if !sp.exists { app.swipeUp() }
        sp.tap()
        sleep(2)
        save("13-screenpipe")
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Live capture'")).firstMatch.tap()
        sleep(8)
        save("14-screen-memory")
    }

    private func save(_ name: String) {
        // a stray system prompt (e.g. the microphone one if a gesture ever
        // lands on the mic) must not hide the state being photographed
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deny = springboard.buttons["Don’t Allow"]
        if deny.exists { deny.tap(); sleep(1) }
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name; att.lifetime = .keepAlways
        add(att)
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}
