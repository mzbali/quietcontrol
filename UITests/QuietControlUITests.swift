import XCTest

final class QuietControlUITests: XCTestCase {
    private let quietValue = "Selected"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(runID: String, scenario: String, reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--quietcontrol-ui-testing"]
        app.launchEnvironment["QUIETCONTROL_TEST_SCENARIO"] = scenario
        app.launchEnvironment["QUIETCONTROL_TEST_RUN_ID"] = runID
        if reset { app.launchEnvironment["QUIETCONTROL_TEST_RESET"] = "1" }
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitForValue(_ element: XCUIElement, _ value: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func openDiagnostics(_ app: XCUIApplication) {
        app.buttons["Headphone settings"].tap()
        app.buttons["More"].tap()
        app.buttons["Diagnostics"].tap()
    }

    private func modeEvidence(_ app: XCUIApplication) -> String {
        let evidence = element("test-mode-evidence", in: app)
        XCTAssertTrue(evidence.waitForExistence(timeout: 8), "The app must export its test transcript.")
        return (evidence.value as? String) ?? evidence.label
    }

    func testTappingAwareUsesRealControlAndConfirmsWithIndependentGet() {
        let runID = "aware-\(UUID().uuidString.prefix(8))"
        let app = launch(runID: runID, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        XCTAssertTrue(app.buttons["mode-1"].exists)

        app.buttons["mode-1"].tap()
        XCTAssertTrue(waitForValue(app.buttons["mode-1"], quietValue), "Aware must be selected after the confirmed write.")
        XCTAssertNotEqual(app.buttons["mode-0"].value as? String, quietValue)

        openDiagnostics(app)
        let evidence = modeEvidence(app)
        XCTAssertTrue(evidence.contains("tx=1f0305020100"), "Literal select-mode packet: \(evidence)")
        XCTAssertTrue(evidence.contains("get=1f030100"), "Independent GET packet: \(evidence)")
        XCTAssertTrue(evidence.contains("reply=1f03030101"), "Write reply must confirm Aware: \(evidence)")
        XCTAssertTrue(evidence.contains("getReply=1f03030101"), "Independent GET reply must confirm Aware: \(evidence)")
    }

    func testRejectedModeShowsFailureAndKeepsQuietSelected() {
        let runID = "reject-\(UUID().uuidString.prefix(8))"
        let app = launch(runID: runID, scenario: "mode-rejected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))

        app.buttons["mode-1"].tap()
        let failureText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "rejected")).firstMatch
        XCTAssertTrue(failureText.waitForExistence(timeout: 10), "A rejection must be shown to the user.")
        XCTAssertEqual(app.buttons["mode-0"].value as? String, quietValue)
        XCTAssertNotEqual(app.buttons["mode-1"].value as? String, quietValue)

        openDiagnostics(app)
        let evidence = modeEvidence(app)
        XCTAssertTrue(evidence.contains("tx=1f0305020100"))
        XCTAssertTrue(evidence.contains("reply=1f03040104"), "The rejection reply must be visible evidence: \(evidence)")
    }

    func testUnconfirmedModeShowsFailureAndKeepsQuietSelected() {
        let runID = "unconf-\(UUID().uuidString.prefix(8))"
        let app = launch(runID: runID, scenario: "mode-unconfirmed", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))

        app.buttons["mode-1"].tap()
        let failureText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "did not confirm")).firstMatch
        XCTAssertTrue(failureText.waitForExistence(timeout: 15), "An unconfirmed write must be shown as a failure.")
        XCTAssertEqual(app.buttons["mode-0"].value as? String, quietValue)
        XCTAssertNotEqual(app.buttons["mode-1"].value as? String, quietValue)

        openDiagnostics(app)
        let evidence = modeEvidence(app)
        XCTAssertTrue(evidence.contains("get=1f030100"))
        XCTAssertTrue(evidence.contains("getReply=1f03030100"), "The independent GET still reports Quiet: \(evidence)")
    }

    func testConfirmedModePersistsAndOfflineRelaunchIsReadOnly() {
        let runID = "persist-\(UUID().uuidString.prefix(8))"
        let app = launch(runID: runID, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        app.buttons["mode-1"].tap()
        XCTAssertTrue(waitForValue(app.buttons["mode-1"], quietValue))
        app.terminate()

        let relaunched = launch(runID: runID, scenario: "offline-cached", reset: false)
        let hero = element("current-mode", in: relaunched)
        XCTAssertTrue(hero.waitForExistence(timeout: 15))
        XCTAssertTrue(hero.label.contains("Last used"), "Offline mode must be labelled as cached: \(hero.label)")
        XCTAssertTrue(hero.label.contains("Aware"), "The confirmed Aware mode should survive relaunch: \(hero.label)")
        XCTAssertFalse(element("battery-level", in: relaunched).exists, "Offline state must not show a live battery.")
        XCTAssertEqual(relaunched.buttons["mode-1"].value as? String, "Unavailable")
        XCTAssertEqual(relaunched.buttons["mode-0"].value as? String, "Unavailable")

        relaunched.buttons["mode-0"].tap()
        XCTAssertTrue(hero.label.contains("Aware"), "An offline tap must not change the cached mode.")
    }
}
