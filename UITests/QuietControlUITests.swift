import XCTest

final class QuietControlUITests: XCTestCase {
    private let quietValue = "Selected"
    private var auditFailures: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        auditFailures = []
    }

    private func launch(runID: String, scenario: String, reset: Bool,
                        appearance: String? = nil, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--quietcontrol-ui-testing"]
        app.launchEnvironment["QUIETCONTROL_TEST_SCENARIO"] = scenario
        app.launchEnvironment["QUIETCONTROL_TEST_RUN_ID"] = runID
        if reset { app.launchEnvironment["QUIETCONTROL_TEST_RESET"] = "1" }
        if let appearance { app.launchEnvironment["QUIETCONTROL_TEST_APPEARANCE"] = appearance }
        if largeText {
            app.launchEnvironment["QUIETCONTROL_TEST_LARGE_TEXT"] = "1"
            // SwiftUI reads the process-wide content size category for layout
            // decisions in the root view; the environment override alone only
            // reaches descendants. accessibility3 == AccessibilityXL.
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
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

    // MARK: - Wave 2 helpers

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForLabelContains(_ element: XCUIElement, _ text: String, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func transcript(_ app: XCUIApplication) -> String {
        let element = element("test-transcript", in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "The app must export its simulator transcript.")
        return (element.value as? String) ?? element.label
    }

    /// Opens Settings → Diagnostics and attaches the full run ID plus transcript.
    @discardableResult
    private func attachTranscript(_ app: XCUIApplication, runID: String, note: String) -> String {
        openDiagnostics(app)
        let text = transcript(app)
        let attachment = XCTAttachment(string: "runID: \(runID)\n\(note)\n\n\(text)")
        attachment.name = "journey-\(runID)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return text
    }

    private func openSettings(_ app: XCUIApplication) {
        app.buttons["Headphone settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    private func swipeBack(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
    }

    private func closeDiagnostics(_ app: XCUIApplication) {
        let back = app.navigationBars["Diagnostics"].buttons.firstMatch
        if back.exists { back.tap() }
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: app.navigationBars["Settings"])
        _ = XCTWaiter().wait(for: [gone], timeout: 10)
    }

    private func openEqualizer(_ app: XCUIApplication) {
        let row = element("equalizer-row", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.navigationBars["Equalizer"].waitForExistence(timeout: 10))
    }

    private func leaveEqualizer(_ app: XCUIApplication) {
        let bar = app.navigationBars["Equalizer"]
        if bar.exists, bar.buttons.firstMatch.exists {
            bar.buttons.firstMatch.tap()
            return
        }
        for label in ["Home", "Back"] {
            let button = app.buttons[label]
            if button.exists { button.tap(); return }
        }
        // Home hides its navigation bar, so a pushed Equalizer is left with the
        // system edge-swipe pop gesture.
        swipeBack(app)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue, timeout: 10), "Edge swipe returns Home")
    }
    private func openEditor(_ app: XCUIApplication, mode: String, title: String) {
        let segment = app.buttons[mode]
        XCTAssertTrue(segment.waitForExistence(timeout: 10))
        segment.press(forDuration: 0.9)
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "The \(title) editor should open")
    }

    private func dragStrength(_ app: XCUIApplication, to fraction: CGFloat) {
        let meter = element("mode-strength", in: app)
        XCTAssertTrue(meter.waitForExistence(timeout: 10))
        let start = meter.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
        let end = meter.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Drag the real Mid curve point upward by roughly three semitones (+4 → +7).
    private func dragMidToSeven(_ app: XCUIApplication) {
        let point = element("eq-point-1", in: app)
        XCTAssertTrue(point.waitForExistence(timeout: 10))
        let start = point.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: -31))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return element.exists && element.isEnabled
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.exists && attempts < 4 {
            app.swipeUp()
            attempts += 1
        }
        _ = element.waitForExistence(timeout: 3)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private func assertTranscriptOrder(_ tokens: [String], in transcript: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        var remaining = transcript[...]
        for token in tokens {
            guard let range = remaining.range(of: token) else {
                XCTFail("Missing ordered transcript token: \(token)", file: file, line: line)
                return
            }
            remaining = remaining[range.upperBound...]
        }
    }

    private struct AuditRecord {
        let context: String
        let type: String
        let details: String
        let identifier: String
        let label: String
        let enabled: Bool?
        let frame: CGRect?
        let ignored: Bool

        var summary: String {
            "\(context) [\(type)] \(details) | enabled=\(enabled.map { String($0) } ?? "unknown") identifier=\(identifier) label=\(label)"
        }

        var json: [String: Any] {
            var value: [String: Any] = [
                "auditType": type,
                "description": details,
                "identifier": identifier,
                "label": label,
                "enabled": enabled.map { $0 as Any } ?? NSNull(),
                "ignored": ignored,
                "exemption": ignored ? "WCAG inactive control: contrast issue on a disabled element" : NSNull()
            ]
            if let frame {
                value["frame"] = ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            }
            return value
        }
    }

    private func auditTypeName(_ type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: return "contrast"
        case .hitRegion: return "hitRegion"
        case .sufficientElementDescription: return "sufficientElementDescription"
        case .textClipped: return "textClipped"
        default: return "raw-\(type.rawValue)"
        }
    }

    /// Audits one screen with a single inspectable policy: a contrast issue is
    /// ignored only when its actual element is disabled (the WCAG inactive-control
    /// exemption). There is no text-substring or screen-coordinate exemption. Every
    /// reported issue is retained as an attachment and in a machine-readable
    /// per-screen summary; any other issue is recorded as a failure.
    @discardableResult
    private func performAudit(_ app: XCUIApplication, context: String) -> [AuditRecord] {
        var records: [AuditRecord] = []
        do {
            try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .textClipped, .contrast]) { issue in
                let element = issue.element
                let ignored = issue.auditType == .contrast && element != nil && element?.isEnabled == false
                let record = AuditRecord(
                    context: context,
                    type: self.auditTypeName(issue.auditType),
                    details: issue.compactDescription,
                    identifier: element?.identifier ?? "",
                    label: element?.label ?? "",
                    enabled: element?.isEnabled,
                    frame: element?.frame,
                    ignored: ignored
                )
                records.append(record)
                return true
            }
        } catch {
            records.append(AuditRecord(context: context, type: "auditError", details: "\(error)",
                                       identifier: "", label: "", enabled: nil, frame: nil, ignored: false))
        }

        for record in records {
            let attachment = XCTAttachment(string: record.summary)
            attachment.name = "audit-\(context)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let ignored = records.filter(\.ignored).count
        let failed = records.filter { !$0.ignored }
        let summary: [String: Any] = [
            "screen": context,
            "auditTypes": ["hitRegion", "sufficientElementDescription", "textClipped", "contrast"],
            "counts": [
                "reported": records.count,
                "ignored": ignored,
                "failed": failed.count
            ],
            "countsNote": "reported = ignored + failed; ignored = disabled-element contrast exemptions; failed = every other reported issue (must be 0).",
            "policy": [
                "substringExemptions": false,
                "coordinateExemptions": false,
                "enabledIssueSuppression": 0,
                "onlyExemption": "contrast issue whose actual element is disabled",
                "measuredRatio": "not exposed by XCUIAccessibilityAuditType; resolved colours are not available from the public audit API"
            ],
            "issues": records.map(\.json)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: text)
            attachment.name = "audit-summary-\(context)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        auditFailures.append(contentsOf: failed.map { "\($0.context): \($0.type) \($0.label) \($0.identifier)" })
        return records
    }

    private func assertAuditsClean() {
        XCTAssertTrue(auditFailures.isEmpty,
                      "Enabled accessibility issues must fail the audit: \(auditFailures.joined(separator: "; "))")
    }

    private func prepareDirtyEditorAudit(_ app: XCUIApplication, largeText: Bool = false) {
        let strength = element("mode-strength", in: app)
        strength.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue(strength, "7 of 10"), "Audit a dirty editor so Save is enabled")
        let topSave = app.buttons["mode-save-toolbar"]
        let bottomSave = element("mode-save-bottom", in: app)
        XCTAssertTrue(topSave.isEnabled && topSave.isHittable, "Enabled top Save must be included in the audit")
        XCTAssertTrue(bottomSave.isEnabled)
        guard largeText else { return }

        let title = app.staticTexts["Wind Block"]
        let detail = app.staticTexts["For outdoors. Locks cancelling to max."]
        let cancel = app.buttons["mode-cancel"]
        func isClear() -> Bool {
            title.exists && detail.exists
                && title.frame.minY >= cancel.frame.maxY + 8
                && detail.frame.maxY <= bottomSave.frame.minY - 16
                && detail.isHittable
        }
        for _ in 0..<5 {
            if isClear() { break }
            let scroll = app.scrollViews.firstMatch
            // Drag the empty left gutter, away from the adjustable strength meter.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.25)))
        }
        XCTAssertTrue(isClear(), "Wind Block labels must be fully visible between dismiss and pinned Save before auditing: title=\(title.frame), detail=\(detail.frame), save=\(bottomSave.frame)")
        XCTAssertTrue(topSave.isEnabled && topSave.isHittable, "Pinned top Save stays available after scrolling")
        XCTAssertEqual(strength.value as? String, "7 of 10", "Scrolling must not adjust the meter")
        attachScreenshot(app, name: "editor-large-text-wind-clear")
    }

    /// Audit from an explicit, settled hero viewport. The Wind Block reachability
    /// check above uses a different scroll position; never carry that offset into
    /// an audit which may visit the hero. Fail if the viewport changes during it.
    private func auditLargeEditor(_ app: XCUIApplication) {
        let summary = element("mode-summary", in: app)
        let strength = element("mode-strength", in: app)
        let cancel = app.buttons["mode-cancel"]
        let topSave = app.buttons["mode-save-toolbar"]
        let bottomSave = element("mode-save-bottom", in: app)
        func heroIsClear() -> Bool {
            summary.exists && summary.isHittable && strength.isHittable
                && summary.frame.minY >= cancel.frame.maxY + 8
                && strength.frame.maxY <= bottomSave.frame.minY - 16
                && topSave.isEnabled && topSave.isHittable && bottomSave.isEnabled
                && strength.value as? String == "7 of 10"
        }
        for _ in 0..<5 {
            if heroIsClear() { break }
            let scroll = app.scrollViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.25))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.85)))
        }
        func frames() -> [CGRect] { [summary.frame, strength.frame, cancel.frame, topSave.frame, bottomSave.frame] }
        var previous: [CGRect] = []
        var stableSince = Date()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let current = frames()
            guard heroIsClear() else { previous = []; stableSince = Date(); return false }
            if current != previous { previous = current; stableSince = Date(); return false }
            return Date().timeIntervalSince(stableSince) >= 0.5
        }, object: nil)
        let stable = XCTWaiter.wait(for: [settled], timeout: 8) == .completed
        XCTAssertTrue(stable, "The hero and both Save controls must settle before the audit: \(frames())")
        guard stable else { return }
        let before = frames()
        attachScreenshot(app, name: "editor-large-text-before-audit")
        performAudit(app, context: "editor-large-text")
        let after = frames()
        XCTAssertTrue(heroIsClear(), "The audited hero must remain clear of pinned actions")
        XCTAssertEqual(after, before, "The audit must not silently reset the editor scroll offset")
        func json(_ values: [CGRect]) -> [[String: CGFloat]] {
            values.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] }
        }
        let geometry: [String: Any] = [
            "screen": "editor-large-text", "elements": ["mode-summary", "mode-strength", "mode-cancel", "mode-save-toolbar", "mode-save-bottom"],
            "stableSeconds": 0.5, "before": json(before), "after": json(after),
            "heroClearAfter": heroIsClear(), "strength": strength.value as? String ?? "missing"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: text)
            attachment.name = "audit-geometry-editor-large-text"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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

    // MARK: - Wave 2 journeys

    func testEQDragCommitsOnReleaseAndResetIsConfirmed() {
        let runID = "eq-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        openEqualizer(app)
        XCTAssertEqual(element("eq-value-0", in: app).label, "-1")
        XCTAssertEqual(element("eq-value-1", in: app).label, "+4")
        XCTAssertEqual(element("eq-value-2", in: app).label, "+2")

        dragMidToSeven(app)
        XCTAssertTrue(waitForLabel(element("eq-value-1", in: app), "+7"), "Releasing the Mid point commits +7")
        XCTAssertEqual(element("eq-value-0", in: app).label, "-1")
        XCTAssertEqual(element("eq-value-2", in: app).label, "+2")

        let flat = element("preset-Flat", in: app)
        reveal(flat, in: app)
        XCTAssertTrue(flat.waitForExistence(timeout: 10))
        flat.tap()
        XCTAssertTrue(waitForLabel(element("eq-value-0", in: app), "0"))
        XCTAssertTrue(waitForLabel(element("eq-value-1", in: app), "0"))
        XCTAssertTrue(waitForLabel(element("eq-value-2", in: app), "0"))

        leaveEqualizer(app)
        let log = attachTranscript(app, runID: runID, note: "EQ drag release, confirmed values, Flat reset")
        let begin = log.range(of: "eq gesture begin band 1")
        let end = log.range(of: "eq gesture end band 1")
        XCTAssertNotNil(begin, "The real gesture start must be traced")
        XCTAssertNotNil(end, "The real gesture end must be traced")
        if let begin, let end {
            XCTAssertTrue(begin.upperBound < end.lowerBound, "Preview precedes release")
            let during = log[begin.upperBound..<end.lowerBound]
            XCTAssertFalse(during.contains("outbound bmap 010702"), "No EQ device write may happen before release")
        }
        if let end {
            let afterRelease = log[end.upperBound...]
            XCTAssertTrue(afterRelease.contains("outbound bmap 010702020701"), "The release writes +7")
            XCTAssertTrue(afterRelease.contains("inbound bmap 0107030cf60aff00f60a0701f60a0202"),
                          "The independent read confirms [-1, +7, +2]")
            XCTAssertTrue(afterRelease.contains("outbound bmap 010702020000"))
            XCTAssertTrue(afterRelease.contains("outbound bmap 010702020001"))
            XCTAssertTrue(afterRelease.contains("outbound bmap 010702020002"))
            XCTAssertTrue(afterRelease.contains("inbound bmap 0107030cf60a0000f60a0001f60a0002"),
                          "Flat is confirmed as [0, 0, 0]")
        }
    }

    func testRejectedEQRestoresConfirmedValues() {
        let runID = "eqfail-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "eq-rejected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        openEqualizer(app)
        XCTAssertEqual(element("eq-value-1", in: app).label, "+4")

        dragMidToSeven(app)
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "rejected")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 15), "A rejected EQ write is reported")
        XCTAssertFalse(app.staticTexts["EQ saved"].exists, "No success toast for a rejected write")
        XCTAssertEqual(element("eq-value-0", in: app).label, "-1")
        XCTAssertEqual(element("eq-value-1", in: app).label, "+4", "Confirmed Mid stays +4")
        XCTAssertEqual(element("eq-value-2", in: app).label, "+2")
        attachScreenshot(app, name: "eq-failure-rejected")

        leaveEqualizer(app)
        let log = attachTranscript(app, runID: runID, note: "Rejected EQ write keeps confirmed values")
        XCTAssertTrue(log.contains("outbound bmap 010702020701"))
        XCTAssertTrue(log.contains("inbound bmap 0107040104"))
        XCTAssertTrue(log.contains("inbound bmap 0107030cf60aff00f60a0401f60a0202"))
        XCTAssertFalse(log.contains("inbound bmap 0107030cf60aff00f60a0701f60a0202"))
    }

    func testSavedEQPresetSurvivesRelaunch() {
        let runID = "presets-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        openEqualizer(app)
        dragMidToSeven(app)
        XCTAssertTrue(waitForLabel(element("eq-value-1", in: app), "+7"))

        let saveCurrent = element("save-preset", in: app)
        reveal(saveCurrent, in: app)
        XCTAssertTrue(waitForEnabled(saveCurrent, timeout: 15))
        saveCurrent.tap()
        let named = app.textFields["preset-name"]
        let byPlaceholder = app.alerts.textFields["Preset name"]
        let name: XCUIElement
        if named.waitForExistence(timeout: 10) {
            name = named
        } else {
            XCTAssertTrue(byPlaceholder.waitForExistence(timeout: 10), "The preset name field is reachable")
            name = byPlaceholder
        }
        name.tap()
        name.typeText("Mine")
        XCTAssertTrue(app.alerts.buttons["Save"].waitForExistence(timeout: 5))
        app.alerts.buttons["Save"].tap()
        let savedCard = element("preset-Mine", in: app)
        reveal(savedCard, in: app)
        XCTAssertTrue(savedCard.waitForExistence(timeout: 10), "Mine is saved")

        let flat = element("preset-Flat", in: app)
        reveal(flat, in: app)
        flat.tap()
        XCTAssertTrue(waitForLabel(element("eq-value-1", in: app), "0"))
        app.terminate()

        let relaunched = launch(runID: runID, scenario: "connected", reset: false)
        XCTAssertTrue(waitForValue(relaunched.buttons["mode-0"], quietValue))
        openEqualizer(relaunched)
        let mine = element("preset-Mine", in: relaunched)
        reveal(mine, in: relaunched)
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "The saved preset survives relaunch without reset")
        mine.tap()
        XCTAssertTrue(waitForLabel(element("eq-value-0", in: relaunched), "-1"))
        XCTAssertTrue(waitForLabel(element("eq-value-1", in: relaunched), "+7"))
        XCTAssertTrue(waitForLabel(element("eq-value-2", in: relaunched), "+2"))

        leaveEqualizer(relaunched)
        let log = attachTranscript(relaunched, runID: runID, note: "Saved preset applied after relaunch")
        XCTAssertTrue(log.contains("outbound bmap 01070202ff00"))
        XCTAssertTrue(log.contains("outbound bmap 010702020701"))
        XCTAssertTrue(log.contains("outbound bmap 010702020202"))
        XCTAssertTrue(log.contains("inbound bmap 0107030cf60aff00f60a0701f60a0202"),
                      "Applying Mine is independently confirmed as [-1, +7, +2]")
    }

    func testModeEditorCancelSaveAndFixedModeLocks() {
        let runID = "editor-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))

        // Long-press opens Focus without switching Home away from Quiet.
        openEditor(app, mode: "mode-2", title: "Focus")
        XCTAssertEqual(element("mode-strength", in: app).value as? String, "5 of 10")
        XCTAssertFalse(app.buttons["mode-save-toolbar"].isEnabled, "Nothing is dirty yet")

        dragStrength(app, to: 0.65)
        XCTAssertTrue(element("mode-dirty", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabelContains(element("mode-summary", in: app), "Noise cancelling · 7 of 10"))
        XCTAssertTrue(app.buttons["mode-save-toolbar"].isEnabled, "Save becomes available for a dirty edit")

        // A dirty editor must refuse an interactive dismissal.
        app.navigationBars["Focus"].swipeDown()
        XCTAssertTrue(app.navigationBars["Focus"].exists, "A dirty editor cannot be dismissed")
        app.buttons["mode-cancel"].tap()
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue), "Cancel keeps Quiet as the Home mode")

        // Cancel discarded the 7; reopen shows the confirmed 5 and no edit write.
        openEditor(app, mode: "mode-2", title: "Focus")
        XCTAssertEqual(element("mode-strength", in: app).value as? String, "5 of 10")
        dragStrength(app, to: 0.65)
        XCTAssertTrue(waitForLabelContains(element("mode-summary", in: app), "7 of 10"))
        app.buttons["mode-save-toolbar"].tap()
        let savedToast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Mode saved")).firstMatch
        XCTAssertTrue(savedToast.waitForExistence(timeout: 15), "A confirmed save reports success")
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue), "Saving the mode edit does not switch modes")

        // The saved 7 survives reopening.
        openEditor(app, mode: "mode-2", title: "Focus")
        XCTAssertEqual(element("mode-strength", in: app).value as? String, "7 of 10")
        let wind = app.switches["wind-block"]
        XCTAssertTrue(wind.waitForExistence(timeout: 10))
        wind.tap()
        XCTAssertEqual(element("mode-strength", in: app).value as? String, "10 of 10, fixed", "Wind Block forces maximum")
        XCTAssertTrue(waitForLabelContains(element("mode-summary", in: app), "Wind Block · Max cancelling"))
        app.buttons["mode-cancel"].tap()

        openEditor(app, mode: "mode-2", title: "Focus")
        XCTAssertEqual(element("mode-strength", in: app).value as? String, "7 of 10", "Cancelled Wind Block is not saved")
        app.buttons["mode-cancel"].tap()

        // Quiet and Aware remain fixed.
        for (mode, title) in [("mode-0", "Quiet"), ("mode-1", "Aware")] {
            openEditor(app, mode: mode, title: title)
            XCTAssertTrue(element("mode-locked-note", in: app).waitForExistence(timeout: 10), "\(title) is fixed")
            XCTAssertFalse(app.buttons["mode-save-toolbar"].exists, "A fixed mode has no Save action")
            app.buttons["mode-cancel"].tap()
        }

        let log = attachTranscript(app, runID: runID, note: "Editor cancel, save, Wind Block and fixed modes")
        XCTAssertFalse(log.contains("outbound bmap 1f0305020200"), "Long-press and editor use never selected Focus")
        XCTAssertEqual(occurrences(of: "outbound bmap 1f0602", in: log), 1,
                       "Only the saved edit wrote mode configuration; Cancel and Wind Block did not")
        XCTAssertTrue(log.contains("outbound bmap 1f030100"), "Saved strength is read back independently")
    }

    func testAudioDeviceSwapAndUndoRestoreConnections() {
        let runID = "swap-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        let work = element("device-Work-laptop", in: app)
        let mac = element("device-MacBook-Pro", in: app)
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForValue(mac, "Connected"))
        XCTAssertTrue(waitForValue(work, "Tap to switch"))

        work.tap()
        XCTAssertTrue(waitForValue(work, "Connected"), "Work laptop replaces the MacBook")
        XCTAssertEqual(mac.value as? String, "Tap to switch", "The replaced MacBook is disconnected")
        let swapToast = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Switched to Work laptop")).firstMatch
        XCTAssertTrue(swapToast.waitForExistence(timeout: 5), "The swap is reported")

        let undo = app.buttons["undo-swap"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "The swap toast offers Undo")
        undo.tap()
        XCTAssertTrue(waitForValue(work, "Tap to switch"), "Undo disconnects the Work laptop")
        XCTAssertTrue(waitForValue(mac, "Connected"), "Undo restores the MacBook")
        XCTAssertTrue(waitForLabel(element("connection-status", in: app), "Connected"), "Control BLE stays available")

        let log = attachTranscript(app, runID: runID, note: "Device swap then Undo")
        XCTAssertTrue(log.contains("outbound bmap 04020506a1b2c3d4e502"), "MacBook disconnect")
        XCTAssertTrue(log.contains("outbound bmap 0401050700a1b2c3d4e503"), "Work laptop connect")
        XCTAssertTrue(log.contains("inbound bmap 04050314a1b2c3d4e5030100"), "Independent read: Work laptop connected")
        let undoRange = try? XCTUnwrap(log.range(of: "outbound bmap 04020506a1b2c3d4e503"))
        if let undoRange {
            let after = log[undoRange.upperBound...]
            XCTAssertTrue(after.contains("outbound bmap 0401050700a1b2c3d4e502"), "Undo reconnects the MacBook")
            assertTranscriptOrder([
                "outbound bmap 0401050700a1b2c3d4e502",
                "outbound bmap 04050106a1b2c3d4e502",
                "inbound bmap 04050314a1b2c3d4e5020100"
            ], in: String(after))
            XCTAssertTrue(after.contains("inbound bmap 04050314a1b2c3d4e5030000"), "Work laptop reads back disconnected")
        } else {
            XCTFail("Undo must disconnect the Work laptop")
        }
        XCTAssertFalse(log.contains("outbound bmap 040c05"), "No unsupported direct source-routing control is used")
    }

    func testUnreachableAudioDeviceRestoresOriginalConnections() {
        let runID = "unreachable-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "audio-unreachable", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        let work = element("device-Work-laptop", in: app)
        let mac = element("device-MacBook-Pro", in: app)
        XCTAssertTrue(work.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForValue(mac, "Connected"))

        work.tap()
        let failure = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "didn’t connect")).firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 20), "The unreachable device is reported honestly")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Switched to Work laptop")).firstMatch.exists,
                       "No success toast for the failed swap")
        XCTAssertTrue(waitForValue(work, "Tap to switch"), "No phantom Work laptop connection")
        XCTAssertTrue(waitForValue(mac, "Connected"), "The starting MacBook connection is restored")
        XCTAssertTrue(waitForLabel(element("connection-status", in: app), "Connected"))

        let log = attachTranscript(app, runID: runID, note: "Unreachable device paging stopped and connections restored")
        XCTAssertTrue(log.contains("inbound bmap 0401040108"), "The fixture refuses with paging error 8")
        XCTAssertTrue(log.contains("Simulated Work laptop is unreachable"))
        XCTAssertTrue(log.contains("Stopped paging the unreachable Work laptop"))
        XCTAssertTrue(log.contains("outbound bmap 0401050700a1b2c3d4e502"), "The MacBook is reconnected")
        XCTAssertTrue(log.contains("inbound bmap 04050314a1b2c3d4e5030000"), "Work laptop reads back disconnected")
        XCTAssertFalse(log.contains("inbound bmap 04050314a1b2c3d4e5030100"), "No phantom Work laptop connection")
    }

    func testSettingsWritesAreIndependentlyConfirmed() {
        let runID = "settings-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        openSettings(app)

        let autoOff = element("auto-off-value", in: app)
        XCTAssertTrue(waitForLabel(autoOff, "Never", timeout: 15), "The fixture starts with Auto-Off Never")
        XCTAssertTrue(waitForEnabled(element("auto-off-20", in: app)))
        element("auto-off-20", in: app).tap()
        XCTAssertTrue(waitForLabel(autoOff, "20 minutes"))
        XCTAssertTrue(waitForEnabled(element("auto-off-0", in: app)))
        element("auto-off-0", in: app).tap()
        XCTAssertTrue(waitForLabel(autoOff, "Never"))

        let remember = app.switches["remember-mode"]
        XCTAssertTrue(remember.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilEnabled(remember), "Power controls settle after the Auto-Off writes")
        XCTAssertEqual(remember.value as? String, "1")
        remember.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue(remember, "0"), "Remember My Mode turns off")
        XCTAssertTrue(waitUntilEnabled(remember))
        remember.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitForValue(remember, "1"), "Remember My Mode turns back on")

        let more = app.buttons["More"]
        more.tap()
        XCTAssertTrue(app.buttons["Diagnostics"].waitForExistence(timeout: 5), "Diagnostic menu is reachable")
        XCTAssertTrue(app.buttons["Connection details"].exists)
        app.buttons["Diagnostics"].tap()
        let log = transcript(app)
        let attachment = XCTAttachment(string: "runID: \(runID)\nSettings power writes\n\n\(log)")
        attachment.name = "journey-\(runID)"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(log.contains("outbound bmap 0104020114"), "Auto-Off writes [1.4] = 20")
        XCTAssertTrue(log.contains("outbound bmap 0104020100"), "Auto-Off writes [1.4] = Never")
        XCTAssertTrue(log.contains("outbound bmap 1f05020100"), "Remember My Mode writes [31.5] = off")
        XCTAssertTrue(log.contains("outbound bmap 1f05020101"), "Remember My Mode writes [31.5] = on")
        assertTranscriptOrder([
            "outbound bmap 0104020114", "inbound bmap 0104030114",
            "outbound bmap 01040100", "inbound bmap 0104030114",
            "outbound bmap 0104020100", "inbound bmap 0104030100",
            "outbound bmap 01040100", "inbound bmap 0104030100",
            "outbound bmap 1f05020100", "inbound bmap 1f05030100",
            "outbound bmap 1f050100", "inbound bmap 1f05030100",
            "outbound bmap 1f05020101", "inbound bmap 1f05030101",
            "outbound bmap 1f050100", "inbound bmap 1f05030101"
        ], in: log)
        XCTAssertFalse(log.contains("outbound bmap 010e"), "[1.14] must never be written")
    }

    func testUnsupportedFirmwareDisablesPowerSettings() {
        let runID = "firmware-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "firmware-unsupported", reset: true)
        XCTAssertTrue(waitForValue(app.buttons["mode-0"], quietValue))
        openSettings(app)
        let identity = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "firmware 1.1.9")).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10), "The different synthetic firmware is visible")

        let autoOff = element("auto-off-value", in: app)
        XCTAssertTrue(waitForLabel(autoOff, "Never", timeout: 15))
        XCTAssertFalse(element("auto-off-20", in: app).isEnabled, "Auto-Off is disabled on unsupported firmware")
        XCTAssertFalse(app.switches["remember-mode"].isEnabled, "Remember My Mode is disabled on unsupported firmware")

        element("auto-off-20", in: app).tap()
        app.switches["remember-mode"].tap()
        XCTAssertEqual(autoOff.label, "Never", "Disabled power controls do not change state")

        app.buttons["More"].tap()
        app.buttons["Diagnostics"].tap()
        let log = transcript(app)
        let attachment = XCTAttachment(string: "runID: \(runID)\nUnsupported firmware power gates\n\n\(log)")
        attachment.name = "journey-\(runID)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(log.contains("outbound bmap 01040100"), "Auto-Off may still be read")
        XCTAssertTrue(log.contains("outbound bmap 1f050100"))
        XCTAssertFalse(log.contains("outbound bmap 010402"), "No Auto-Off write")
        XCTAssertFalse(log.contains("outbound bmap 1f0502"), "No Remember My Mode write")
    }

    func testPauseAndQuietWaitingSurviveRelaunch() {
        let runID = "waiting-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "pending-connection", reset: true)
        let status = element("connection-status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(status, "Connecting…", timeout: 5))
        XCTAssertTrue(element("connecting-spinner", in: app).waitForExistence(timeout: 5),
                      "A genuinely pending connect shows progress while it starts")

        // The configured production presentation delay is 8 seconds; after it the
        // pending request is presented quietly without a spinner or duplicate connect.
        XCTAssertTrue(waitForLabel(status, "Waiting for QC", timeout: 20))
        XCTAssertFalse(element("connecting-spinner", in: app).exists, "Waiting is not a busy spinner")

        element("connection-details", in: app).tap()
        let pause = app.buttons["pause-auto-connect"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(waitForLabel(status, "Auto-connect paused"))
        app.terminate()

        let relaunched = launch(runID: runID, scenario: "pending-connection", reset: false)
        let pausedStatus = element("connection-status", in: relaunched)
        XCTAssertTrue(waitForLabel(pausedStatus, "Auto-connect paused", timeout: 15), "Paused survives relaunch")

        let details = element("connection-details", in: relaunched)
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.tap()
        var resume = relaunched.buttons["resume-auto-connect"]
        if !resume.waitForExistence(timeout: 10) {
            resume = relaunched.buttons["Resume auto-connect"]
            XCTAssertTrue(resume.waitForExistence(timeout: 5), "The paused session offers Resume")
        }
        resume.tap()
        relaunched.buttons["Done"].tap()
        XCTAssertTrue(waitForLabel(pausedStatus, "Waiting for QC", timeout: 20),
                      "Resume keeps exactly one pending connection waiting")

        let afterResume = attachTranscript(relaunched, runID: runID, note: "Resume sends one pending connection")
        XCTAssertEqual(occurrences(of: "Connect request", in: afterResume), 1,
                       "Resume sends exactly one pending connection")
    }

    func testFirstRunAndUnavailableRadioStatesAreHonest() {
        // First run: no remembered QC, so no live values and no writes at all.
        let firstRun = "firstrun-a-\(UUID().uuidString)"
        let app = launch(runID: firstRun, scenario: "first-run", reset: true)
        let status = element("connection-status", in: app)
        XCTAssertTrue(waitForLabel(status, "Ready to connect", timeout: 15))
        XCTAssertFalse(element("battery-level", in: app).exists, "No live battery without a QC")
        XCTAssertFalse(app.buttons["mode-0"].exists, "No live modes without a QC")
        XCTAssertTrue(element("find-headphones", in: app).waitForExistence(timeout: 10))
        let log = attachTranscript(app, runID: firstRun, note: "First run has no live values or writes")
        XCTAssertFalse(log.contains("outbound bmap"), "First run must not write to a radio")
        XCTAssertFalse(log.contains("inbound bmap"))
        XCTAssertFalse(log.lowercased().contains("connect request"), "First run must not try a connection")
        closeDiagnostics(app)
        app.terminate()

        // Bluetooth off is the phone radio, never a claim about the headphones.
        let radioOff = "firstrun-off-\(UUID().uuidString)"
        let off = launch(runID: radioOff, scenario: "radio-off", reset: true)
        let offStatus = element("connection-status", in: off)
        XCTAssertTrue(waitForLabel(offStatus, "Bluetooth off", timeout: 15))
        XCTAssertFalse(off.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "headphones are off")).firstMatch.exists,
                       "A phone radio state is not reported as powered-off headphones")
        XCTAssertFalse(element("battery-level", in: off).exists)
        let offLog = attachTranscript(off, runID: radioOff, note: "Bluetooth off radio state")
        XCTAssertFalse(offLog.contains("outbound bmap"), "No radio writes while Bluetooth is off")
        XCTAssertFalse(offLog.lowercased().contains("connect request"), "Do not attempt a connection while Bluetooth is off")
        off.terminate()

        let denied = "firstrun-denied-\(UUID().uuidString)"
        let deniedApp = launch(runID: denied, scenario: "permission-denied", reset: true)
        let deniedStatus = element("connection-status", in: deniedApp)
        XCTAssertTrue(waitForLabel(deniedStatus, "Bluetooth permission needed", timeout: 15))
        XCTAssertFalse(element("battery-level", in: deniedApp).exists)
        let deniedLog = attachTranscript(deniedApp, runID: denied, note: "Bluetooth permission denied")
        XCTAssertFalse(deniedLog.contains("outbound bmap"), "No radio writes without permission")
        XCTAssertFalse(deniedLog.lowercased().contains("connect request"), "Do not attempt a connection without permission")
    }

    func testInvalidTestConfigurationFailsWithoutRadioFallback() {
        let invalidRun = "invalid-\(UUID().uuidString) run!"
        let app = launch(runID: invalidRun, scenario: "connected", reset: true)
        let error = element("configuration-error", in: app)
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        let runIDMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "QUIETCONTROL_TEST_RUN_ID")).firstMatch
        XCTAssertTrue(runIDMessage.waitForExistence(timeout: 5), "Invalid run IDs are named: \(error.label)")
        XCTAssertFalse(element("connection-status", in: app).exists, "No app session is constructed")
        let attachment = XCTAttachment(string: "runID: \(invalidRun)\ninvalid runID case\n\(error.label)")
        attachment.name = "journey-invalid-run"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()

        let unknown = "invalid-\(UUID().uuidString)"
        let unknownApp = launch(runID: unknown, scenario: "not-a-scenario", reset: true)
        let unknownError = element("configuration-error", in: unknownApp)
        XCTAssertTrue(unknownError.waitForExistence(timeout: 10))
        let scenarioMessage = unknownApp.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unsupported QUIETCONTROL_TEST_SCENARIO")).firstMatch
        XCTAssertTrue(scenarioMessage.waitForExistence(timeout: 5),
                      "Unknown scenarios fail explicitly: \(unknownError.label)")
        XCTAssertFalse(element("connection-status", in: unknownApp).exists)
        let unknownAttachment = XCTAttachment(string: "runID: \(unknown)\nunknown scenario case\n\(unknownError.label)")
        unknownAttachment.name = "journey-invalid-scenario"
        unknownAttachment.lifetime = .keepAlways
        add(unknownAttachment)
    }

    func testConnectionInspectionIsExplicitlyUnavailableInSimulatorTests() {
        let runID = "probe-\(UUID().uuidString)"
        let app = launch(runID: runID, scenario: "first-run", reset: true)
        XCTAssertTrue(element("find-headphones", in: app).waitForExistence(timeout: 15))
        element("find-headphones", in: app).tap()
        XCTAssertTrue(app.navigationBars["QuietControl"].waitForExistence(timeout: 10), "The real inspection screen opens")

        let message = element("connectionMessage", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        app.buttons["startConnectionCheck"].tap()
        XCTAssertTrue(waitForLabelContains(message, "not available in the simulator test environment", timeout: 10))
        XCTAssertTrue(message.label.contains("never accesses a real Bluetooth radio"),
                      "The fixture-unavailable result is explicit: \(message.label)")
        XCTAssertTrue(app.buttons["startConnectionCheck"].exists, "No real scan replaced the unavailable state")
        let attachment = XCTAttachment(string: "runID: \(runID)\n\(message.label)")
        attachment.name = "journey-\(runID)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAccessibilityAndLargeTextNavigation() {
        // Every configuration audits and screenshots the same four screens:
        // Home, Equalizer, Focus editor and Headphone Settings.
        let lightRun = "access-light-\(UUID().uuidString)"
        let light = launch(runID: lightRun, scenario: "connected", reset: true)
        XCTAssertTrue(waitForValue(light.buttons["mode-0"], quietValue))
        performAudit(light, context: "home-light")
        attachScreenshot(light, name: "home-light")

        openEqualizer(light)
        XCTAssertEqual(element("eq-point-0", in: light).value as? String, "-1")
        XCTAssertEqual(element("eq-point-1", in: light).value as? String, "4")
        XCTAssertEqual(element("eq-point-2", in: light).value as? String, "2")
        performAudit(light, context: "equalizer-light")
        attachScreenshot(light, name: "equalizer-light")
        leaveEqualizer(light)

        openEditor(light, mode: "mode-2", title: "Focus")
        XCTAssertEqual(element("mode-strength", in: light).value as? String, "5 of 10",
                       "The adjustable strength exposes its value")
        XCTAssertTrue(element("mode-save-bottom", in: light).exists, "The bottom Save control is reachable")
        prepareDirtyEditorAudit(light)
        performAudit(light, context: "editor-light")
        attachScreenshot(light, name: "editor-light")
        light.buttons["mode-cancel"].tap()

        openSettings(light)
        XCTAssertTrue(waitForLabel(element("auto-off-value", in: light), "Never", timeout: 15))
        XCTAssertTrue(appSwitch("remember-mode", in: light).exists)
        performAudit(light, context: "settings-light")
        attachScreenshot(light, name: "settings-light")
        light.buttons["More"].tap()
        XCTAssertTrue(light.buttons["Diagnostics"].waitForExistence(timeout: 5), "The diagnostics menu is reachable")
        XCTAssertTrue(light.buttons["Connection details"].exists)
        light.buttons["Connection details"].tap()
        XCTAssertTrue(light.navigationBars["Connection"].waitForExistence(timeout: 10))
        light.navigationBars["Connection"].buttons["Done"].tap()
        XCTAssertTrue(light.navigationBars["Settings"].waitForExistence(timeout: 10))
        light.buttons["settings-done"].tap()
        light.terminate()

        // Dark appearance: the same four screens.
        let darkRun = "access-dark-\(UUID().uuidString)"
        let dark = launch(runID: darkRun, scenario: "connected", reset: true, appearance: "dark")
        XCTAssertTrue(waitForValue(dark.buttons["mode-0"], quietValue))
        performAudit(dark, context: "home-dark")
        attachScreenshot(dark, name: "home-dark")

        openEqualizer(dark)
        XCTAssertEqual(element("eq-point-1", in: dark).value as? String, "4")
        performAudit(dark, context: "equalizer-dark")
        attachScreenshot(dark, name: "equalizer-dark")
        leaveEqualizer(dark)

        openEditor(dark, mode: "mode-2", title: "Focus")
        XCTAssertEqual(element("mode-strength", in: dark).value as? String, "5 of 10")
        prepareDirtyEditorAudit(dark)
        performAudit(dark, context: "editor-dark")
        attachScreenshot(dark, name: "editor-dark")
        dark.buttons["mode-cancel"].tap()

        openSettings(dark)
        XCTAssertTrue(waitForLabel(element("auto-off-value", in: dark), "Never", timeout: 15))
        performAudit(dark, context: "settings-dark")
        attachScreenshot(dark, name: "settings-dark")
        dark.buttons["settings-done"].tap()
        dark.terminate()

        // Large text: stacked modes, navigable power settings and bottom editor controls.
        let largeRun = "access-large-\(UUID().uuidString)"
        let large = launch(runID: largeRun, scenario: "connected", reset: true, largeText: true)
        XCTAssertTrue(waitForValue(large.buttons["mode-0"], quietValue))
        performAudit(large, context: "home-large-text")
        attachScreenshot(large, name: "home-large-text")
        let largeTitle = element("headphone-title", in: large)
        XCTAssertTrue(largeTitle.waitForExistence(timeout: 10), "The header title is exposed")
        XCTAssertEqual(largeTitle.label, "Bose QuietComfort")
        XCTAssertGreaterThanOrEqual(largeTitle.frame.width, 220,
                                    "QuietComfort keeps its whole word instead of hyphenating at large text")
        XCTAssertLessThan(largeTitle.frame.height, 104,
                          "The title stays within two clean word-wrapped lines")
        let largeStatus = element("connection-status", in: large)
        XCTAssertTrue(largeStatus.waitForExistence(timeout: 10))
        XCTAssertEqual(largeStatus.label, "Connected")
        XCTAssertGreaterThanOrEqual(largeStatus.frame.width, 100,
                                    "Connection status keeps usable width at accessibility sizes")
        XCTAssertLessThan(largeStatus.frame.height, 52,
                          "Connection status stays on one line at accessibility sizes")
        XCTAssertTrue(large.buttons["Headphone settings"].exists, "The gear stays reachable at large text")

        openEditor(large, mode: "mode-2", title: "Focus")
        XCTAssertEqual(element("mode-strength", in: large).value as? String, "5 of 10")
        XCTAssertTrue(element("mode-save-bottom", in: large).exists)
        // Assert actual clear geometry rather than assuming one swipe was enough.
        prepareDirtyEditorAudit(large, largeText: true)
        auditLargeEditor(large)
        attachScreenshot(large, name: "editor-large-text")
        large.buttons["mode-cancel"].tap()

        openEqualizer(large)
        XCTAssertEqual(element("eq-point-0", in: large).value as? String, "-1")
        performAudit(large, context: "equalizer-large-text")
        attachScreenshot(large, name: "equalizer-large-text")
        leaveEqualizer(large)

        openSettings(large)
        performAudit(large, context: "settings-large-text")
        attachScreenshot(large, name: "settings-large-text")
        let autoOffRow = large.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Auto-Off")).firstMatch
        reveal(autoOffRow, in: large)
        XCTAssertTrue(autoOffRow.waitForExistence(timeout: 10), "Large text exposes Auto-Off as a navigable row")
        autoOffRow.tap()
        XCTAssertTrue(element("auto-off-20", in: large).waitForExistence(timeout: 10))
        large.terminate()

        let summary = """
        light runID: \(lightRun)
        dark runID: \(darkRun)
        large-text runID: \(largeRun)
        Audited and screenshotted Home, Equalizer, Focus editor and Settings in each of light, dark and accessibility text sizes.
        Audit policy: contrast issues are ignored only when the actual element is disabled; no substring or coordinate exemptions.
        Enabled issues: \(auditFailures.isEmpty ? "none" : auditFailures.joined(separator: "; "))
        """
        let attachment = XCTAttachment(string: summary)
        attachment.name = "journey-access-\(largeRun)"
        attachment.lifetime = .keepAlways
        add(attachment)
        assertAuditsClean()
    }

    private func appSwitch(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.switches[identifier]
    }
}
