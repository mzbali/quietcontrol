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

    private func makeSession(scenario: QCTestScenario, runID: String, reset: Bool = true) throws -> QuietComfortSession {
        let environment = try QCSessionEnvironment.testEnvironment(scenario: scenario, runID: runID, reset: reset)
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
