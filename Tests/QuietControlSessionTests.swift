import XCTest
@testable import QuietControl

@MainActor
final class QuietControlSessionTests: XCTestCase {
    private func makePendingSession(transport: PendingConnectionTransport) throws -> QuietComfortSession {
        let runID = "pending-\(UUID().uuidString)"
        let suiteName = "uk.co.mzbali.quietcontrol.ui-tests.\(runID)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(UUID().uuidString, forKey: "quietcontrol.lastPeripheral")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(runID)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        var timing = QCSessionTiming.production
        timing.connectingPresentationDelay = 0.05
        let environment = QCSessionEnvironment(defaults: defaults, documentsDirectory: directory,
            reportsDirectory: directory, snapshotURL: directory.appendingPathComponent("snapshot.json"),
            timing: timing, transportFactory: { transport })
        let session = QuietComfortSession(environment: environment)
        session.startIfNeeded()
        return session
    }

    func testRadioLossCancelsPendingSetupAndAllowsAnotherConnectionAttempt() async throws {
        for radioState in [QCTransportRadioState.poweredOff, .unauthorized, .unsupported] {
            let transport = PendingConnectionTransport()
            let session = try makePendingSession(transport: transport)
            defer { session.disconnect() }
            let pending = await waitUntil { transport.isWaitingForConnection }
            XCTAssertTrue(pending)
            XCTAssertEqual(transport.connectionAttempts, 1)

            transport.setRadioState(radioState)
            let stopped = await waitUntil { !session.isWorking && !transport.isWaitingForConnection }
            XCTAssertTrue(stopped, "Radio loss must finish pending setup, not leave its continuation suspended.")
            XCTAssertGreaterThan(transport.closeCount, 0)
            XCTAssertFalse(session.isConnected)
            let expected: QCConnectionState = radioState == .poweredOff ? .bluetoothOff
                : radioState == .unauthorized ? .permissionNeeded : .unavailable
            XCTAssertEqual(session.connectionState, expected)

            // Powered-on resumes supported radios; unsupported hardware remains unavailable.
            if radioState != .unsupported {
                transport.setRadioState(.poweredOn)
                let retried = await waitUntil { transport.connectionAttempts == 2 && transport.isWaitingForConnection }
                XCTAssertTrue(retried, "The previous setup must no longer block a fresh attempt.")
            }
        }
    }

    func testQuietWaitingClearsBusyWithoutReplacingPendingConnection() async throws {
        let transport = PendingConnectionTransport()
        let session = try makePendingSession(transport: transport)
        defer { session.disconnect() }
        let waiting = await waitUntil {
            transport.isWaitingForConnection && session.connectionState == .waitingForQC
        }
        XCTAssertTrue(waiting)
        XCTAssertFalse(session.isWorking)
        XCTAssertTrue(transport.isWaitingForConnection)
        XCTAssertEqual(transport.connectionAttempts, 1)
        XCTAssertEqual(transport.closeCount, 0)
        session.setForeground(false)
        session.setForeground(true)
        session.startIfNeeded()
        await Task.yield()
        XCTAssertEqual(transport.connectionAttempts, 1, "Quiet waiting must retain one pending connect.")
        XCTAssertEqual(transport.closeCount, 0)
    }

    private func makeSession(scenario: QCTestScenario, runID: String, reset: Bool = true,
                             prepare: (QCSessionEnvironment) throws -> Void = { _ in }) throws -> QuietComfortSession {
        let environment = try QCSessionEnvironment.testEnvironment(scenario: scenario, runID: runID, reset: reset)
        try prepare(environment)
        return QuietComfortSession(environment: environment)
    }

    private func waitUntil(timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testConnectedModeSwitchWritesLiteralPacketAndConfirmsWithIndependentGet() async throws {
        let runID = "unit-\(UUID().uuidString.prefix(8))"
        let session = try makeSession(scenario: .connected, runID: runID)
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected, "The simulated QC should connect.")
        XCTAssertEqual(session.mode, 0)
        XCTAssertTrue(session.hasVerifiedDirectControl)

        await session.selectMode(1)
        let confirmed = await waitUntil { session.mode == 1 }
        XCTAssertTrue(confirmed, "Aware should be confirmed by a read-back.")
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.toast?.text, "Aware selected")
        XCTAssertEqual(session.toast?.isError, false)

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("outbound bmap 1f0305020100"), "Literal select-mode packet")
        let modeGet = "outbound bmap 1f030100"
        let writeRange = try XCTUnwrap(transcript.range(of: "outbound bmap 1f0305020100"))
        let afterWrite = transcript[writeRange.upperBound...]
        XCTAssertTrue(afterWrite.contains(modeGet), "An independent GET must follow the select-mode write.")
        XCTAssertTrue(afterWrite.contains("inbound bmap 1f03030101"), "The GET reply must report Aware.")

        await session.setEQ(.bass, value: -2)
        XCTAssertEqual(session.eq.first { $0.band == .bass }?.value, -2)
        let eqTranscript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(eqTranscript.contains("outbound bmap 01070202fe00"), "Literal EQ packet")

        let store = ConfirmedSnapshotStore(fileURL: session.environment.snapshotURL)
        let saved = try XCTUnwrap(store.load(for: QCTestHarness.peripheralID))
        XCTAssertEqual(saved.lastMode, 1)
        XCTAssertEqual(saved.eq.first { $0.band == .bass }?.value, -2)
    }

    func testRejectedModeKeepsQuietAndReportsExplicitFailure() async throws {
        let session = try makeSession(scenario: .modeRejected, runID: "reject-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.mode, 0)

        await session.selectMode(1)
        XCTAssertEqual(session.mode, 0)
        let failure = try XCTUnwrap(session.failure)
        XCTAssertTrue(failure.contains("rejected"), "Failure should name the device rejection: \(failure)")
        XCTAssertEqual(session.toast?.isError, true)
        XCTAssertFalse(session.toast?.text.contains("Aware selected") ?? false)
        XCTAssertEqual(session.toast?.text, failure)

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("outbound bmap 1f0305020100"))
        XCTAssertTrue(transcript.contains("inbound bmap 1f03040104"), "The fixture must reject with BMAP error 4.")
        XCTAssertEqual(session.testModeEvidence?.contains("reply=1f03040104"), true)
    }

    func testAcceptedButUnconfirmedModeDoesNotReportSuccess() async throws {
        let session = try makeSession(scenario: .modeUnconfirmed, runID: "unconf-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.mode, 0)

        await session.selectMode(1)
        XCTAssertEqual(session.mode, 0)
        XCTAssertEqual(session.failure, "The QC did not confirm the requested mode.")
        XCTAssertEqual(session.toast?.isError, true)
        XCTAssertEqual(session.toast?.text, "The QC did not confirm the requested mode.")

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("outbound bmap 1f0305020100"))
        XCTAssertTrue(transcript.contains("inbound bmap 1f03030100"), "The independent GET still reports Quiet.")
        XCTAssertFalse(transcript.contains("inbound bmap 1f03030101"))
    }

    func testOfflineCachedProfileHasNoLiveAuthority() async throws {
        let runID = "offline-\(UUID().uuidString.prefix(8))"
        let live = try makeSession(scenario: .connected, runID: runID)
        let liveConnected = await waitUntil { live.isConnected && !live.isWorking }
        XCTAssertTrue(liveConnected)
        await live.selectMode(1)
        let confirmed = await waitUntil { live.mode == 1 }
        XCTAssertTrue(confirmed)
        let store = ConfirmedSnapshotStore(fileURL: live.environment.snapshotURL)
        XCTAssertEqual(try XCTUnwrap(store.load(for: QCTestHarness.peripheralID)).lastMode, 1)
        live.disconnect()
        let disconnected = await waitUntil { !live.isConnected }
        XCTAssertTrue(disconnected)

        let offline = try makeSession(scenario: .offlineCached, runID: runID, reset: false)
        let cached = await waitUntil { offline.hasSavedProfile }
        XCTAssertTrue(cached, "The cached profile should load before any live link.")
        XCTAssertFalse(offline.isConnected)
        XCTAssertFalse(offline.hasLiveDeviceList)
        XCTAssertEqual(offline.mode, 1, "Cached Aware should be displayed.")
        XCTAssertEqual(offline.battery, 90)

        await offline.selectMode(0)
        XCTAssertEqual(offline.mode, 1, "An offline session must not claim a mode change.")
        XCTAssertFalse(offline.isConnected)
        let transcript = try XCTUnwrap(offline.testTranscript)
        XCTAssertFalse(transcript.contains("outbound bmap 1f0305020100"), "No select-mode write may leave an offline app.")
        XCTAssertFalse(transcript.contains("outbound bmap 1f0305020000"))
    }

    func testRefreshAndModeActionAreSerialized() async throws {
        let session = try makeSession(scenario: .connected, runID: "serial-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)

        let refresh = Task { await session.refresh() }
        await Task.yield()
        let action = Task { await session.selectMode(1) }
        await refresh.value
        await action.value

        let serialized = await waitUntil { session.mode == 1 }
        XCTAssertTrue(serialized)
        XCTAssertNil(session.failure)
        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertFalse(transcript.contains("Protocol overlap"), "Requests must never overlap on the wire.")
        let writeRange = try XCTUnwrap(transcript.range(of: "outbound bmap 1f0305020100"))
        XCTAssertTrue(transcript[writeRange.upperBound...].contains("outbound bmap 1f030100"))
    }

    // MARK: - Wave 2: EQ, settings, devices and connection state

    func testUnavailableRadioNeverStartsAutomaticConnection() async throws {
        for (scenario, expected) in [(QCTestScenario.radioOff, QCConnectionState.bluetoothOff),
                                     (.permissionDenied, .permissionNeeded)] {
            let session = try makeSession(scenario: scenario, runID: "radio-unit-\(scenario.rawValue)-\(UUID().uuidString.prefix(8))")
            defer { session.disconnect() }
            let unavailable = await waitUntil { session.connectionState == expected }
            XCTAssertTrue(unavailable)
            session.startIfNeeded()
            session.setForeground(false)
            session.setForeground(true)
            await Task.yield()
            XCTAssertFalse(session.isConnected)
            XCTAssertFalse(session.isWorking)
            let transcript = try XCTUnwrap(session.testTranscript)
            XCTAssertFalse(transcript.lowercased().contains("connect request"))
            XCTAssertFalse(transcript.contains("outbound bmap"))
        }
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testNoEQDeviceWriteExistsBeforeExplicitCommit() async throws {
        let session = try makeSession(scenario: .connected, runID: "unit-eq-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        // Connection setup only reads EQ. Nothing has been dragged or committed, so
        // no EQ SETGET may exist on the wire yet.
        let before = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(before.contains("outbound bmap 01070100"), "EQ reads use GET")
        XCTAssertFalse(before.contains("outbound bmap 010702"), "No EQ write before an explicit commit")

        await session.setEQ(.mid, value: 7)
        XCTAssertEqual(session.eq.first { $0.band == .mid }?.value, 7)
        let after = try XCTUnwrap(session.testTranscript)
        XCTAssertEqual(occurrences(of: "outbound bmap 010702020701", in: after), 1, "One commit, one write")
        let write = try XCTUnwrap(after.range(of: "outbound bmap 010702020701"))
        XCTAssertTrue(after[write.upperBound...].contains("outbound bmap 01070100"),
                      "A commit is followed by an independent GET")
    }

    func testRejectedEQWriteKeepsConfirmedValuesWithIndependentRead() async throws {
        let session = try makeSession(scenario: .eqRejected, runID: "eqfail-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.eq.map(\.value), [-1, 4, 2])

        await session.setEQ(.mid, value: 7)
        XCTAssertEqual(session.eq.map(\.value), [-1, 4, 2], "A rejected write must not be displayed as confirmed")
        let failure = try XCTUnwrap(session.failure)
        XCTAssertTrue(failure.contains("rejected"), "Failure must name the device rejection: \(failure)")
        XCTAssertEqual(session.toast?.isError, true)
        XCTAssertNotEqual(session.toast?.text, "EQ saved")

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("outbound bmap 010702020701"))
        XCTAssertTrue(transcript.contains("inbound bmap 0107040104"), "The fixture rejects with BMAP error 4")
        XCTAssertTrue(transcript.contains("inbound bmap 0107030cf60aff00f60a0401f60a0202"),
                      "The independent read still reports [-1, 4, 2]")
    }

    func testApplyEQRollbackRestoresConfirmedValuesAfterRejection() async throws {
        let session = try makeSession(scenario: .eqRejected, runID: "eqfail-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)

        await session.applyEQ([-1, 7, 2])
        XCTAssertEqual(session.eq.map(\.value), [-1, 4, 2], "The confirmed EQ survives a partially failed preset apply")
        XCTAssertNotNil(session.failure)
        let transcript = try XCTUnwrap(session.testTranscript)
        let rejected = try XCTUnwrap(transcript.range(of: "inbound bmap 0107040104"))
        let after = transcript[rejected.upperBound...]
        XCTAssertTrue(after.contains("outbound bmap 010702020401"), "Rollback rewrites the confirmed Mid value")
        XCTAssertTrue(after.contains("inbound bmap 0107030cf60aff00f60a0401f60a0202"))
        XCTAssertFalse(after.contains("inbound bmap 0107030cf60aff00f60a0701f60a0202"),
                       "No false success for the rejected preset")
    }

    func testPowerSettingsUseCorrectBlocksAndPreservePayloadBits() async throws {
        let session = try makeSession(scenario: .connected, runID: "settings-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        await session.refreshPreferences()
        XCTAssertEqual(session.preferencePackets["autoOff"], Data([0]))
        XCTAssertEqual(session.preferencePackets["rememberMode"], Data([1]))

        await session.setPreference("autoOff", value: 20)
        XCTAssertEqual(session.preferencePackets["autoOff"], Data([20]))
        await session.setPreference("autoOff", value: 0)
        XCTAssertEqual(session.preferencePackets["autoOff"], Data([0]))
        await session.setPreference("rememberMode", value: 0)
        XCTAssertEqual(session.preferencePackets["rememberMode"], Data([0]))
        await session.setPreference("rememberMode", value: 1)
        XCTAssertEqual(session.preferencePackets["rememberMode"], Data([1]))

        await session.verifyPreferences()
        XCTAssertTrue(session.verifiedPreferences.contains("selfVoice"))
        XCTAssertTrue(session.verifiedPreferences.contains("shortcut"))
        await session.setPreference("selfVoice", value: 3)
        XCTAssertEqual(session.preferencePackets["selfVoice"], Data([1, 3]), "Self Voice keeps its leading type byte")
        await session.setPreference("shortcut", value: 14)
        XCTAssertEqual(session.preferencePackets["shortcut"], Data([0x80, 9, 14]), "The shortcut header is preserved")
        await session.setPreference("voicePrompts", value: 1)
        XCTAssertEqual(session.preferencePackets["voicePrompts"], Data([0x21]))
        await session.setPreference("voicePrompts", value: 0)
        XCTAssertEqual(session.preferencePackets["voicePrompts"], Data([0x01]), "Only the prompt bit changes")

        let transcript = try XCTUnwrap(session.testTranscript)
        for packet in ["outbound bmap 0104020114", "outbound bmap 0104020100",
                       "outbound bmap 1f05020100", "outbound bmap 1f05020101",
                       "outbound bmap 010b02020103", "outbound bmap 0109020380090e",
                       "outbound bmap 0103020121", "outbound bmap 0103020101"] {
            XCTAssertTrue(transcript.contains(packet), "Expected literal packet \(packet)")
        }
        XCTAssertFalse(transcript.contains("outbound bmap 010e"), "[1.14] must never be written")
    }

    func testUnsupportedFirmwareDisablesPowerWrites() async throws {
        let session = try makeSession(scenario: .unsupportedFirmware, runID: "firmware-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.firmware, "1.1.9-99+deadbeef")
        XCTAssertTrue(session.hasVerifiedDirectControl, "Mode/EQ control is still proven for this fixture")
        await session.refreshPreferences()
        XCTAssertFalse(session.verifiedPreferences.contains("autoOff"))
        XCTAssertFalse(session.verifiedPreferences.contains("rememberMode"))

        await session.setPreference("autoOff", value: 20)
        await session.setPreference("rememberMode", value: 0)
        XCTAssertEqual(session.preferencePackets["autoOff"], Data([0]), "Power settings must stay unchanged")
        XCTAssertEqual(session.preferencePackets["rememberMode"], Data([1]))

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("outbound bmap 01040100"), "Values may be read")
        XCTAssertTrue(transcript.contains("outbound bmap 1f050100"))
        XCTAssertFalse(transcript.contains("outbound bmap 010402"), "No Auto-Off write on unsupported firmware")
        XCTAssertFalse(transcript.contains("outbound bmap 1f0502"), "No Remember My Mode write on unsupported firmware")
    }

    func testUnreachableAudioDeviceRestoresOriginalConnections() async throws {
        let session = try makeSession(scenario: .audioUnreachable, runID: "unreachable-\(UUID().uuidString.prefix(8))")
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        let work = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x03])
        let mac = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x02])

        await session.connectAudioDevice(work, replacing: mac)
        let failure = try XCTUnwrap(session.failure)
        XCTAssertTrue(failure.contains("didn’t connect"), "Failure names the unreachable device: \(failure)")
        XCTAssertTrue(failure.contains("MacBook"), "Failure names the restored device: \(failure)")
        XCTAssertEqual(Set(session.devices.filter(\.isConnected).map(\.address)), Set([session.devices[0].address, mac]))
        XCTAssertFalse(session.devices.first { $0.address == work }?.isConnected ?? true,
                       "No phantom Work laptop connection")

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("outbound bmap 0401050700a1b2c3d4e503"), "The failed connection was attempted")
        XCTAssertTrue(transcript.contains("inbound bmap 0401040108"), "The fixture refuses with paging error 8")
        XCTAssertTrue(transcript.contains("Simulated Work laptop is unreachable"))
        XCTAssertTrue(transcript.contains("Stopped paging the unreachable Work laptop"))
        XCTAssertTrue(transcript.contains("outbound bmap 0401050700a1b2c3d4e502"), "The MacBook is reconnected")
        XCTAssertTrue(transcript.contains("inbound bmap 04050314a1b2c3d4e5030000"), "Work laptop reads back disconnected")
    }

    func testPendingConnectionPauseRelaunchAndSingleResume() async throws {
        let runID = "waiting-\(UUID().uuidString.prefix(8))"
        let session = try makeSession(scenario: .pendingConnection, runID: runID)
        let pending = await waitUntil { session.testTranscript?.contains("Connect request 1 is pending") == true }
        XCTAssertTrue(pending)
        XCTAssertEqual(occurrences(of: "Connect request", in: session.testTranscript ?? ""), 1)

        session.disconnect()
        XCTAssertEqual(session.connectionState, .paused)
        XCTAssertFalse(session.isWorking)
        XCTAssertTrue(session.testTranscript?.contains("Closed the pending simulated connection") == true)

        let relaunched = try makeSession(scenario: .pendingConnection, runID: runID, reset: false)
        XCTAssertEqual(relaunched.connectionState, .paused, "A paused relaunch stays paused")
        XCTAssertFalse(relaunched.isWorking)
        let waitingTranscript = relaunched.testTranscript ?? ""
        XCTAssertEqual(occurrences(of: "Connect request", in: waitingTranscript), 0,
                       "A paused relaunch must not start a connection")

        relaunched.resumeAutoConnect()
        let resumed = await waitUntil { relaunched.testTranscript?.contains("Connect request 1 is pending") == true }
        XCTAssertTrue(resumed, "Resume sends one new pending connection")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(occurrences(of: "Connect request", in: relaunched.testTranscript ?? ""), 1,
                       "Resume must not duplicate the pending connection")
        XCTAssertTrue(relaunched.isWorking)
        relaunched.disconnect()
    }

    // MARK: - Wave 3: bounded byte-path faults and recovery

    private func seedPreferenceJournal(_ environment: QCSessionEnvironment,
                                      peripheral: UUID = QCTestHarness.peripheralID,
                                      firmware: String = "1.0.6-80+f5f219b",
                                      name: String = "rememberMode",
                                      payload: String = "AQ==") throws -> URL {
        let url = environment.reportsDirectory.appendingPathComponent("PreferenceRecovery.json")
        let json = "{\"peripheral\":\"\(peripheral.uuidString)\",\"firmware\":\"\(firmware)\",\"name\":\"\(name)\",\"payload\":\"\(payload)\"}"
        try Data(json.utf8).write(to: url, options: .atomic)
        return url
    }

    private func savedSnapshot(_ environment: QCSessionEnvironment) -> ConfirmedSnapshot? {
        ConfirmedSnapshotStore(fileURL: environment.snapshotURL).load(for: QCTestHarness.peripheralID)
    }

    private func fakePeripheralState(_ environment: QCSessionEnvironment) throws -> [String: Any] {
        let url = environment.reportsDirectory.appendingPathComponent("peripheral-state.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func occurrencesIn(_ text: String, _ needle: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func testTimeoutInvalidatesCommandWithoutPersistingUnconfirmedMode() async throws {
        let runID = "fault-timeout-\(UUID().uuidString)"
        let session = try makeSession(scenario: .connected, runID: runID)
        let simulator = try XCTUnwrap(session.testSimulator)
        defer { session.disconnect() }
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.mode, 0)
        let baseline = try XCTUnwrap(savedSnapshot(session.environment))
        XCTAssertEqual(baseline.lastMode, 0)
        XCTAssertEqual(baseline.eq.map(\.value), [-1, 4, 2])

        // The SET is acknowledged asynchronously; its independent GET never answers.
        simulator.faults.arm(.processingAcknowledgement, block: 31, function: 3, operation: .start)
        simulator.faults.arm(.withholdReply, block: 31, function: 3, operation: .get)
        let started = Date()
        await session.selectMode(1)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 2.9, "The real 3 s production timeout must finish the operation")

        XCTAssertFalse(session.isConnected, "A timed-out operation must invalidate the link, not keep it usable")
        XCTAssertEqual(session.mode, 0, "An acknowledgement alone must not advance the confirmed mode")
        let failure = try XCTUnwrap(session.failure)
        XCTAssertTrue(failure.contains("did not answer BMAP [31.3]"), "Timeout failure: \(failure)")
        XCTAssertEqual(session.toast?.isError, true)
        XCTAssertNotEqual(session.toast?.text, "Aware selected")
        XCTAssertFalse(session.isWorking)
        XCTAssertFalse(session.isUserCommandPending)
        session.recordTestEvent("Timeout inspected before any fresh handshake: connected=\(session.isConnected) mode=\(String(describing: session.mode)) eq=\(session.eq.map(\.value)) toast=\(session.toast?.text ?? "none")")

        // Keep the radio unavailable so no reconnect can hide the failed/offline state.
        simulator.setRadioStateForTesting(.poweredOff)
        let offline = await waitUntil { session.connectionState == .bluetoothOff }
        XCTAssertTrue(offline, "The failed link must settle in an explicit offline state")
        XCTAssertFalse(session.isConnected)

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("outbound bmap 1f0305020100"))
        XCTAssertTrue(transcript.contains("inbound bmap 1f030700"), "Only PROCESSING acknowledged the SET")
        XCTAssertFalse(transcript.contains("inbound bmap 1f03030101"), "No confirmation without the matching GET reply")
        XCTAssertTrue(transcript.contains("Withheld simulated reply"))
        XCTAssertFalse(transcript.contains("Protocol overlap"))
        let set = try XCTUnwrap(transcript.range(of: "outbound bmap 1f0305020100"))
        let actionTranscript = String(transcript[set.lowerBound...])
        XCTAssertEqual(occurrencesIn(actionTranscript, "outbound bmap 1f0305020100"), 1)
        XCTAssertEqual(occurrencesIn(actionTranscript, "outbound bmap 1f030100"), 1,
                       "Exactly one independent GET; no retry while its reply is withheld")
        let withheld = try XCTUnwrap(actionTranscript.range(of: "Withheld simulated reply"))
        let closed = try XCTUnwrap(actionTranscript.range(of: "Closed simulated transport generation",
            range: withheld.upperBound..<actionTranscript.endIndex))
        XCTAssertFalse(actionTranscript[withheld.upperBound..<closed.lowerBound].contains("outbound bmap"),
                       "No command may overlap the withheld request before timeout closes the link")

        let retained = try XCTUnwrap(savedSnapshot(session.environment))
        XCTAssertEqual(retained.lastMode, 0, "The last confirmed snapshot must not advance")
        XCTAssertEqual(retained.eq.map(\.value), [-1, 4, 2])
    }

    func testUnrelatedNotificationsCannotCompletePendingModeRead() async throws {
        let runID = "fault-unrelated-\(UUID().uuidString)"
        let session = try makeSession(scenario: .connected, runID: runID)
        let simulator = try XCTUnwrap(session.testSimulator)
        defer { session.disconnect() }
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.mode, 0)

        simulator.faults.arm(.processingAcknowledgement, block: 31, function: 3, operation: .start)
        simulator.faults.arm(.holdReply, block: 31, function: 3, operation: .get)
        let action = Task { await session.selectMode(1) }
        let held = await waitUntil { simulator.heldReplyCount == 1 }
        XCTAssertTrue(held, "The independent mode GET reply must be held")
        XCTAssertTrue(session.isWorking)
        XCTAssertTrue(session.isUserCommandPending)
        XCTAssertEqual(session.mode, 0)
        XCTAssertNil(session.toast)
        XCTAssertNil(session.failure)

        simulator.injectNotification(try BMAPFrame(block: 2, function: 2, operation: .status, payload: Data([77])))
        simulator.injectNotification(try BMAPFrame(block: 1, function: 7, operation: .status,
            payload: Data([0xf6, 10, 0xff, 0, 0xf6, 10, 4, 1, 0xf6, 10, 2, 2])))
        simulator.injectNotification(try BMAPFrame(block: 1, function: 10, operation: .status, payload: Data([1])))
        _ = await waitUntil { session.battery == 77 }
        XCTAssertEqual(session.mode, 0, "Unrelated notifications must not complete the pending mode action")
        XCTAssertTrue(session.isWorking)
        XCTAssertTrue(session.isUserCommandPending)
        XCTAssertNil(session.toast)
        XCTAssertEqual(session.battery, 77, "A legitimate unrelated battery update may still apply")

        simulator.releaseHeldReply()
        await action.value
        XCTAssertEqual(session.mode, 1)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.toast?.text, "Aware selected")
        XCTAssertFalse(session.toast?.isError ?? true)

        let transcript = try XCTUnwrap(session.testTranscript)
        let setRange = try XCTUnwrap(transcript.range(of: "outbound bmap 1f0305020100"))
        let ackRange = try XCTUnwrap(transcript.range(of: "inbound bmap 1f030700", range: setRange.upperBound..<transcript.endIndex))
        let getRange = try XCTUnwrap(transcript.range(of: "outbound bmap 1f030100", range: ackRange.upperBound..<transcript.endIndex))
        let injectedRange = try XCTUnwrap(transcript.range(of: "inbound bmap 010a030101", range: getRange.upperBound..<transcript.endIndex))
        let replyRange = try XCTUnwrap(transcript.range(of: "inbound bmap 1f03030101", range: injectedRange.upperBound..<transcript.endIndex))
        XCTAssertLessThan(getRange.lowerBound, injectedRange.lowerBound)
        XCTAssertLessThan(injectedRange.lowerBound, replyRange.lowerBound,
                          "Confirmation must arrive only after the matching reply, following unrelated traffic")
        XCTAssertEqual(occurrencesIn(transcript, "outbound bmap 1f0305020100"), 1)
        XCTAssertEqual(occurrencesIn(transcript, "outbound bmap 1f030100"), 2,
                       "One setup mode GET and exactly one independent GET for this action")
        XCTAssertFalse(transcript.contains("Protocol overlap"))
    }

    func testMalformedEnvelopeClosesLinkAndPreservesConfirmedSnapshot() async throws {
        let runID = "fault-malformed-\(UUID().uuidString)"
        let session = try makeSession(scenario: .connected, runID: runID)
        let simulator = try XCTUnwrap(session.testSimulator)
        defer { session.disconnect() }
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.mode, 0)
        let baseline = try XCTUnwrap(savedSnapshot(session.environment))

        simulator.faults.arm(.malformedEnvelope, block: 2, function: 2, operation: .get)
        let started = Date()
        await session.refresh()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(session.isConnected, "A framing error must invalidate the link")
        XCTAssertEqual(session.failure, BLEFramingError.invalidSegmentIndex.localizedDescription)
        XCTAssertLessThan(elapsed, session.environment.timing.commandTimeout - 0.1,
                          "A literal framing error must fail before the request timeout")
        XCTAssertEqual(session.mode, 0)
        XCTAssertEqual(session.eq.map(\.value), [-1, 4, 2])
        XCTAssertFalse(session.hasLiveDeviceList)
        XCTAssertNil(session.toast, "A background read must not claim success")

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("121f030000"), "Literal malformed envelope delivered to the real receive path")
        XCTAssertTrue(transcript.contains("Injecting a malformed Bose envelope"))
        XCTAssertFalse(transcript.contains("inbound bmap 1f03030101"))

        let retained = try XCTUnwrap(savedSnapshot(session.environment))
        XCTAssertEqual(retained.lastMode, baseline.lastMode)
        XCTAssertEqual(retained.eq.map(\.value), baseline.eq.map(\.value))
        XCTAssertEqual(retained.modes.map(\.index), baseline.modes.map(\.index))
    }

    func testFragmentedAndCoalescedModeRepliesUseRealReceivePipeline() async throws {
        let runID = "fault-fragmented-\(UUID().uuidString)"
        let session = try makeSession(scenario: .connected, runID: runID)
        let simulator = try XCTUnwrap(session.testSimulator)
        defer { session.disconnect() }
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.modes.map(\.index), [0, 1, 2])
        let baseline = try XCTUnwrap(savedSnapshot(session.environment))

        let decodedModesBefore = session.proof.events.filter { $0.message.hasPrefix("RX 1f 06 03 2f ") }.count
        simulator.faults.arm(.fragmentModeReply, block: 31, function: 1, operation: .start)
        let refresh = Task { await session.refreshModes() }
        let partial = await waitUntil { simulator.heldReplyCount == 1 }
        XCTAssertTrue(partial, "The first segment must arrive while the remainder is held")
        XCTAssertTrue(session.isWorking)
        XCTAssertEqual(session.modes.map(\.index), [0, 1, 2], "Partial bytes cannot complete a profile")
        XCTAssertEqual(try XCTUnwrap(savedSnapshot(session.environment)).modes.map(\.index),
                       baseline.modes.map(\.index), "No partial profile may be persisted")
        XCTAssertEqual(session.proof.events.filter { $0.message.hasPrefix("RX 1f 06 03 2f ") }.count,
                       decodedModesBefore, "The partial segment must not decode a mode frame")

        simulator.releaseHeldReply()
        await refresh.value
        XCTAssertFalse(session.isWorking)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.modes.map(\.index), [0, 1, 2])
        XCTAssertEqual(Set(session.modes.map(\.index)).count, 3, "Coalesced frames must not duplicate modes")
        let focus = try XCTUnwrap(session.modes.first { $0.index == 2 })
        XCTAssertEqual(focus.displayName, "Focus")
        XCTAssertEqual(focus.ancStrength, 5)
        XCTAssertFalse(focus.windBlock)
        XCTAssertEqual(session.modes.map(\.displayName), ["Quiet", "Aware", "Focus"])
        XCTAssertEqual(session.mode, 0)

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertTrue(transcript.contains("Fragmenting coalesced mode reply into 9 segments"), "A single multi-segment reply was held")
        XCTAssertTrue(transcript.contains("Released held reply"))
        XCTAssertEqual(session.proof.events.filter { $0.message.hasPrefix("RX 1f 06 03 2f ") }.count,
                       decodedModesBefore + 3, "All three faulted coalesced mode frames must cross the real decoder")
        session.recordTestEvent("Fragmented mode decoder observed exactly 3 new RX 1f06032f frames after release; none while partial.")
        XCTAssertEqual(try XCTUnwrap(savedSnapshot(session.environment)).modes.map(\.index), [0, 1, 2])
    }

    func testDisconnectDuringEQWriteDoesNotReportSuccess() async throws {
        let runID = "fault-eq-disconnect-\(UUID().uuidString)"
        let session = try makeSession(scenario: .connected, runID: runID)
        let simulator = try XCTUnwrap(session.testSimulator)
        defer { session.disconnect() }
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        XCTAssertEqual(session.eq.map(\.value), [-1, 4, 2])
        let baseline = try XCTUnwrap(savedSnapshot(session.environment))
        XCTAssertEqual(baseline.eq.map(\.value), [-1, 4, 2])

        // The device accepts the SET and its echo, then the link dies before the
        // independent GET can confirm the write.
        simulator.faults.arm(.disconnectAfterReply, block: 1, function: 7, operation: .setGet)
        await session.setEQ(.mid, value: 7)

        XCTAssertFalse(session.isConnected)
        XCTAssertNotNil(session.failure)
        XCTAssertEqual(session.toast?.isError, true)
        XCTAssertNotEqual(session.toast?.text, "EQ saved")
        session.recordTestEvent("EQ disconnect inspected: transient eq=\(session.eq.map(\.value)) toast=\(session.toast?.text ?? "none")")
        simulator.setRadioStateForTesting(.poweredOff)
        let offline = await waitUntil { session.connectionState == .bluetoothOff }
        XCTAssertTrue(offline)

        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertEqual(occurrencesIn(transcript, "outbound bmap 010702020701"), 1)
        let writeRange = try XCTUnwrap(transcript.range(of: "outbound bmap 010702020701"))
        let afterWrite = transcript[writeRange.upperBound...]
        XCTAssertFalse(afterWrite.contains("outbound bmap 01070100"),
                       "No independent EQ GET may run on the dead link")
        XCTAssertTrue(transcript.contains("Closed simulated transport generation"))
        XCTAssertFalse(transcript.contains("Protocol overlap"))

        let retained = try XCTUnwrap(savedSnapshot(session.environment))
        XCTAssertEqual(retained.eq.map(\.value), [-1, 4, 2], "The last confirmed snapshot is retained")
        XCTAssertEqual(retained.lastMode, 0)
        let fake = try fakePeripheralState(session.environment)
        let fakeEQ = try XCTUnwrap(fake["eq"] as? [Int])
        XCTAssertEqual(fakeEQ, [-1, 7, 2], "The fake device accepted the write; no rollback after physical link loss is claimed")
    }

    func testLateNotificationFromClosedGenerationCannotSatisfyNewCommand() async throws {
        let runID = "fault-generation-\(UUID().uuidString)"
        let session = try makeSession(scenario: .connected, runID: runID)
        let simulator = try XCTUnwrap(session.testSimulator)
        defer { session.disconnect() }
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected)
        let firstGeneration = simulator.generation

        simulator.faults.arm(.holdReply, block: 31, function: 3, operation: .get)
        let oldRead = Task { await session.refresh() }
        let queued = await waitUntil { simulator.heldReplyCount == 1 }
        XCTAssertTrue(queued, "The old-generation reply is queued, not delivered")

        session.disconnect()
        await oldRead.value
        let closed = await waitUntil { !session.isConnected }
        XCTAssertTrue(closed)

        session.resumeAutoConnect()
        let reconnected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(reconnected, "A fresh connection must establish after the old generation closed")
        XCTAssertGreaterThan(simulator.generation, firstGeneration)
        XCTAssertEqual(session.mode, 0)

        simulator.faults.arm(.processingAcknowledgement, block: 31, function: 3, operation: .start)
        simulator.faults.arm(.holdReply, block: 31, function: 3, operation: .get)
        let fresh = Task { await session.selectMode(1) }
        let bothQueued = await waitUntil { simulator.heldReplyCount == 2 }
        XCTAssertTrue(bothQueued)
        XCTAssertTrue(session.isWorking)
        XCTAssertNil(session.toast)
        XCTAssertEqual(session.mode, 0)

        simulator.releaseHeldReply()
        let dropped = await waitUntil {
            session.testTranscript?.contains("Dropped old-generation simulated reply") == true
        }
        XCTAssertTrue(dropped, "The transport boundary must drop the closed generation")
        XCTAssertTrue(session.isWorking, "The old reply must not finish the new command")
        XCTAssertEqual(session.mode, 0, "The old reply must not overwrite the new state")
        XCTAssertNil(session.toast)

        simulator.releaseHeldReply()
        await fresh.value
        XCTAssertEqual(session.mode, 1)
        XCTAssertNil(session.failure)
        XCTAssertEqual(session.toast?.text, "Aware selected")

        let transcript = try XCTUnwrap(session.testTranscript)
        let dropRange = try XCTUnwrap(transcript.range(of: "Dropped old-generation simulated reply"))
        let matchingReply = try XCTUnwrap(transcript.range(of: "inbound bmap 1f03030101",
            range: dropRange.upperBound..<transcript.endIndex))
        XCTAssertLessThan(dropRange.lowerBound, matchingReply.lowerBound)
        XCTAssertTrue(transcript.contains("Opened simulated transport generation \(firstGeneration)"))
        XCTAssertTrue(transcript.contains("Opened simulated transport generation \(simulator.generation)"))
    }

    func testInterruptedPreferenceRestoresOriginalValueAndClearsJournal() async throws {
        let runID = "fault-pref-restore-\(UUID().uuidString)"
        var journalURL: URL?
        let session = try makeSession(scenario: .preferenceRecovery, runID: runID) { environment in
            journalURL = try seedPreferenceJournal(environment)
        }
        defer { session.disconnect() }
        let connected = await waitUntil { session.isConnected && !session.isWorking }
        XCTAssertTrue(connected, "Setup must finish restoration before reporting a live link")
        let journal = try XCTUnwrap(journalURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path), "The journal is removed only after confirmation")
        XCTAssertEqual(session.preferencePackets["rememberMode"], Data([1]))
        XCTAssertEqual(session.firmware, "1.0.6-80+f5f219b")

        let transcript = try XCTUnwrap(session.testTranscript)
        let setRange = try XCTUnwrap(transcript.range(of: "outbound bmap 1f05020101"))
        let setReply = try XCTUnwrap(transcript.range(of: "inbound bmap 1f05030101", range: setRange.upperBound..<transcript.endIndex))
        let getRange = try XCTUnwrap(transcript.range(of: "outbound bmap 1f050100", range: setReply.upperBound..<transcript.endIndex))
        let getReply = try XCTUnwrap(transcript.range(of: "inbound bmap 1f05030101", range: getRange.upperBound..<transcript.endIndex))
        XCTAssertLessThan(setRange.lowerBound, getRange.lowerBound)
        XCTAssertLessThan(getRange.lowerBound, getReply.lowerBound, "The independent GET confirms after the SETGET")
        XCTAssertFalse(transcript.contains("outbound bmap 010302"), "No voice-prompt write during recovery")
        XCTAssertFalse(transcript.contains("outbound bmap 010b02"))

        let fake = try fakePeripheralState(session.environment)
        let preferences = try XCTUnwrap(fake["preferences"] as? [String: String])
        XCTAssertEqual(preferences["rememberMode"], "01")
        let snapshot = try XCTUnwrap(savedSnapshot(session.environment))
        XCTAssertEqual(snapshot.lastMode, 0)
        XCTAssertEqual(snapshot.eq.map(\.value), [-1, 4, 2])
    }

    func testFailedOrMismatchedRestorationKeepsJournalAndStopsReplay() async throws {
        // Wrong firmware: the checkpoint belongs to another build, so nothing is written.
        let mismatchRun = "fault-pref-fw-\(UUID().uuidString)"
        var mismatchJournal: URL?
        var mismatchJournalBytes: Data?
        let mismatch = try makeSession(scenario: .preferenceRecovery, runID: mismatchRun) { environment in
            mismatchJournal = try seedPreferenceJournal(environment, firmware: "9.9.9-1+wrong")
            mismatchJournalBytes = try Data(contentsOf: XCTUnwrap(mismatchJournal))
        }
        defer { mismatch.disconnect() }
        let mismatchFailed = await waitUntil { mismatch.failure != nil && !mismatch.isWorking }
        XCTAssertTrue(mismatchFailed)
        XCTAssertFalse(mismatch.isConnected)
        XCTAssertFalse(mismatch.hasVerifiedDirectControl)
        XCTAssertTrue(try XCTUnwrap(mismatch.failure).contains("different QC or firmware"))
        let mismatchURL = try XCTUnwrap(mismatchJournal)
        XCTAssertEqual(try Data(contentsOf: mismatchURL), try XCTUnwrap(mismatchJournalBytes),
                       "A firmware mismatch retains the exact checkpoint bytes")
        let mismatchTranscript = try XCTUnwrap(mismatch.testTranscript)
        XCTAssertFalse(mismatchTranscript.contains("outbound bmap 1f0502"), "No restoration write on mismatch")
        XCTAssertFalse(mismatchTranscript.contains("outbound bmap 010302"), "No voice-prompt write on mismatch")

        // Wrong device: same firmware, different synthetic peripheral identity.
        let deviceRun = "fault-pref-dev-\(UUID().uuidString)"
        var deviceJournal: URL?
        var deviceJournalBytes: Data?
        let wrongDevice = try makeSession(scenario: .preferenceRecovery, runID: deviceRun) { environment in
            deviceJournal = try seedPreferenceJournal(environment, peripheral: UUID())
            deviceJournalBytes = try Data(contentsOf: XCTUnwrap(deviceJournal))
        }
        defer { wrongDevice.disconnect() }
        let deviceFailed = await waitUntil { wrongDevice.failure != nil && !wrongDevice.isWorking }
        XCTAssertTrue(deviceFailed)
        XCTAssertFalse(wrongDevice.isConnected)
        XCTAssertFalse(wrongDevice.hasVerifiedDirectControl)
        XCTAssertTrue(try XCTUnwrap(wrongDevice.failure).contains("different QC or firmware"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(deviceJournal)), try XCTUnwrap(deviceJournalBytes),
                       "A device mismatch retains the exact checkpoint bytes")
        let deviceTranscript = try XCTUnwrap(wrongDevice.testTranscript)
        XCTAssertFalse(deviceTranscript.contains("outbound bmap 1f0502"))

        // Same firmware, device rejects the restoration: one attempt per app session.
        let rejectedRun = "fault-pref-rejected-\(UUID().uuidString)"
        var rejectedJournal: URL?
        var rejectedJournalBytes: Data?
        let rejected = try makeSession(scenario: .preferenceRecoveryRejected, runID: rejectedRun) { environment in
            rejectedJournal = try seedPreferenceJournal(environment)
            rejectedJournalBytes = try Data(contentsOf: XCTUnwrap(rejectedJournal))
        }
        defer { rejected.disconnect() }
        let rejectedFailed = await waitUntil { rejected.failure != nil && !rejected.isWorking }
        XCTAssertTrue(rejectedFailed)
        XCTAssertFalse(rejected.isConnected)
        XCTAssertFalse(rejected.hasVerifiedDirectControl, "No control authority from the capability seed")
        let firstFailure = try XCTUnwrap(rejected.failure)
        XCTAssertTrue(firstFailure.contains("rejected"), "Clear device rejection: \(firstFailure)")
        let rejectedURL = try XCTUnwrap(rejectedJournal)
        XCTAssertEqual(try Data(contentsOf: rejectedURL), try XCTUnwrap(rejectedJournalBytes),
                       "A failed restoration retains its exact journal bytes")
        let firstTranscript = try XCTUnwrap(rejected.testTranscript)
        XCTAssertEqual(occurrencesIn(firstTranscript, "outbound bmap 1f05020101"), 1)
        XCTAssertFalse(firstTranscript.contains("outbound bmap 1f050100"), "No GET after the rejected SET")
        XCTAssertFalse(firstTranscript.contains("outbound bmap 010302"), "No accidental voice-prompt write")

        var secondError: Error?
        do { try await rejected.connectRemembered() } catch { secondError = error }
        let replay = try XCTUnwrap(secondError)
        XCTAssertTrue(replay.localizedDescription.contains("one attempt"),
                      "A reconnect must refuse replay: \(replay.localizedDescription)")
        XCTAssertFalse(rejected.isConnected)
        let secondTranscript = try XCTUnwrap(rejected.testTranscript)
        XCTAssertEqual(occurrencesIn(secondTranscript, "outbound bmap 1f05020101"), 1,
                       "The rejected restoration is not attempted twice in one app session")
        XCTAssertEqual(try Data(contentsOf: rejectedURL), try XCTUnwrap(rejectedJournalBytes),
                       "Replay refusal must not alter the checkpoint")
        XCTAssertFalse(secondTranscript.contains("outbound bmap 010302"))
    }

    func testCorruptOfflineSnapshotNeverGrantsControlAuthority() async throws {
        let runID = "fault-corrupt-snapshot-\(UUID().uuidString)"
        let corrupt = Data("{\"version\":1,\"lastMode\":0,\"modes\":[{\"index\":0".utf8)
        let session = try makeSession(scenario: .offlineCached, runID: runID) { environment in
            try corrupt.write(to: environment.snapshotURL, options: .atomic)
        }
        defer { session.disconnect() }
        let failed = await waitUntil { session.failure != nil && !session.isWorking }
        XCTAssertTrue(failed)

        XCTAssertFalse(session.isConnected)
        XCTAssertFalse(session.hasSavedProfile)
        XCTAssertNil(session.mode)
        XCTAssertTrue(session.eq.isEmpty)
        XCTAssertTrue(session.modes.isEmpty)
        XCTAssertNil(session.battery)
        XCTAssertEqual(session.model, "")
        XCTAssertEqual(session.manufacturer, "")
        XCTAssertEqual(session.connectionState, .unavailable)

        await session.selectMode(0)
        XCTAssertNil(session.mode, "No invented mode")
        XCTAssertNil(session.toast)
        let transcript = try XCTUnwrap(session.testTranscript)
        XCTAssertFalse(transcript.contains("outbound bmap 1f030502"), "A mutating action cannot emit a SET offline")
        XCTAssertFalse(transcript.contains("inbound bmap 1f030301"), "No fabricated confirmed mode")
        session.recordTestEvent("Corrupt snapshot outcome: connected=\(session.isConnected) mode=\(String(describing: session.mode)) battery=\(String(describing: session.battery)) model=\(session.model)")

        let preserved = try Data(contentsOf: session.environment.snapshotURL)
        XCTAssertEqual(preserved, corrupt, "The corrupt file is preserved as evidence, not replaced")
        let fake = try fakePeripheralState(session.environment)
        XCTAssertEqual(fake["connected"] as? Bool, false)
        XCTAssertEqual(fake["firmware"] as? String, "1.0.6-80+f5f219b")
    }
}

/// Models a radio connection that has not completed, without constructing Apple CB objects.
@MainActor
private final class PendingConnectionTransport: QCByteTransport {
    weak var delegate: QCByteTransportDelegate?
    private(set) var identifier: UUID?
    let isConnected = false
    private(set) var radioState: QCTransportRadioState = .poweredOn
    let canSendWriteWithoutResponse = false
    private(set) var connectionAttempts = 0
    private(set) var closeCount = 0
    private var pending: CheckedContinuation<QCTransportLink, Error>?
    var isWaitingForConnection: Bool { pending != nil }

    func prepareRadio() {}
    func connect(rememberedID: UUID) async throws -> QCTransportLink {
        identifier = rememberedID
        connectionAttempts += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func setRadioState(_ state: QCTransportRadioState) {
        radioState = state
        delegate?.transport(self, radioStateChanged: state)
    }
    func close() {
        closeCount += 1
        identifier = nil
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: QCSessionError.disconnected)
    }
    func enableNotifications(for endpoint: QCTransportEndpoint) async throws { throw QCSessionError.disconnected }
    func disableNotifications(for endpoint: QCTransportEndpoint) {}
    func maximumWriteLength(for endpoint: QCTransportEndpoint, withoutResponse: Bool) -> Int { 20 }
    func write(_ segment: Data, to endpoint: QCTransportEndpoint, withoutResponse: Bool) throws {
        XCTFail("Pending setup must not write bytes.")
        throw QCSessionError.disconnected
    }
}
