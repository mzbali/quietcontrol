import XCTest
@testable import QuietComfortCore

final class ConfirmedSnapshotTests: XCTestCase {
    func testReconnectCannotRestartAudibleChecksOrRecovery() {
        var gate = SessionActionGate()
        var connection = ConnectionPolicy(hasRememberedDevice: true)
        XCTAssertTrue(gate.claim("verify-preferences"))
        XCTAssertTrue(gate.claim("preference-restoration"))
        for _ in 0..<10 {
            connection.linkLost()
            _ = connection.beginAttempt(hasRememberedDevice: true)
            connection.connected()
            XCTAssertFalse(gate.claim("verify-preferences"))
            XCTAssertFalse(gate.claim("preference-restoration"))
        }
        XCTAssertTrue(gate.claim("another-explicit-check"))
    }

    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func snapshot(includeFocus: Bool = true, firmware: String = "1.0.6") throws -> ConfirmedSnapshot {
        let entries: [(UInt8, UInt8, String)] = includeFocus ? [(0, 1, "Quiet"), (1, 2, "Aware"), (2, 13, "Focus")] : [(0, 1, "Quiet"), (1, 2, "Aware")]
        let modes = try entries.map { index, prompt, name -> ListeningMode in
            var p = [UInt8](repeating: 0, count: 47); p[0] = index; p[2] = prompt; p[4] = 1
            p.replaceSubrange(6..<6 + name.utf8.count, with: name.utf8)
            return try PrinceProtocol.modeConfiguration(from: .init(block: 31, function: 6, operation: .status, payload: Data(p)))
        }
        let eq = try PrinceProtocol.eq(from: .init(block: 1, function: 7, operation: .status,
            payload: Data([0xf6, 10, 0xff, 0, 0xf6, 10, 4, 1, 0xf6, 10, 2, 2])))
        let devices = try (0..<4).map { n in
            try DeviceManagementProtocol.device(from: .init(block: 4, function: 5, operation: .status,
                payload: Data([1, 2, 3, 4, 5, UInt8(n), n == 0 ? 3 : 0, 0, 0]) + Data("Device \(n)".utf8)))
        }
        return ConfirmedSnapshot(peripheralID: id, manufacturer: "Bose Corporation", model: "884367-0100", firmware: firmware,
            modes: modes, devices: devices, eq: eq, lastMode: includeFocus ? 2 : 0,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000), battery: 90, controllerAddress: devices[0].address, multipoint: true)
    }
    private func withStore(_ body: (ConfirmedSnapshotStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ConfirmedSnapshotStore(fileURL: directory.appendingPathComponent("State.json")))
    }
    func testFocusDevicesAndEQSurviveOfflineReload() throws {
        try withStore { store in
            let original = try snapshot(); try store.save(original)
            let loaded = try XCTUnwrap(store.load(for: id))
            XCTAssertEqual(loaded, original)
            XCTAssertEqual(loaded.modes.map(\.displayName), ["Quiet", "Aware", "Focus"])
            XCTAssertEqual(loaded.devices.count, 4); XCTAssertEqual(loaded.eq.map(\.value), [-1, 4, 2])
            XCTAssertEqual(loaded.lastMode, 2)
            XCTAssertTrue(try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }
    func testMissingCorruptAndOversizeCachesAreIgnored() throws {
        try withStore { store in
            XCTAssertNil(store.load(for: id))
            try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{not JSON".utf8).write(to: store.fileURL)
            XCTAssertNil(store.load(for: id))
            try Data(repeating: 0, count: 262_145).write(to: store.fileURL)
            XCTAssertNil(store.load(for: id))
        }
    }
    func testForeignDeviceAndFutureSchemaAreRejected() throws {
        try withStore { store in
            let original = try snapshot(); try store.save(original)
            XCTAssertNil(store.load(for: UUID()))
            var incompatible = original; incompatible.version = 2
            XCTAssertThrowsError(try store.save(incompatible))
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            object["version"] = 99
            try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
            XCTAssertNil(store.load(for: id))
        }
    }
    func testCacheDoesNotCarryConnectionOrVerificationAuthority() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["isConnected"])
        XCTAssertNil(object["hasVerifiedDirectControl"])
        XCTAssertNil(object["deviceControlsVerified"])
    }
    func testNewConfirmedProfileReplacesRemovedFocus() throws {
        try withStore { store in
            try store.save(snapshot()); try store.save(snapshot(includeFocus: false))
            let loaded = try XCTUnwrap(store.load(for: id))
            XCTAssertEqual(loaded.modes.map(\.displayName), ["Quiet", "Aware"])
            XCTAssertEqual(loaded.lastMode, 0)
        }
    }
    func testInvalidEQAndUnconfiguredModesAreRejected() throws {
        try withStore { store in
            try store.save(snapshot())
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            var eq = try XCTUnwrap(object["eq"] as? [[String: Any]])
            eq[0]["value"] = 99; object["eq"] = eq
            try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
            XCTAssertNil(store.load(for: id))
            try store.save(snapshot())
            object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            var modes = try XCTUnwrap(object["modes"] as? [[String: Any]])
            modes[2]["configured"] = false; object["modes"] = modes
            try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
            XCTAssertNil(store.load(for: id))
        }
    }
    func testFreshFirmwareReplacesOldPresentationWithoutGrantingAuthority() throws {
        try withStore { store in
            try store.save(snapshot()); try store.save(snapshot(firmware: "1.0.7"))
            XCTAssertEqual(store.load(for: id)?.firmware, "1.0.7")
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
            XCTAssertNil(object["hasVerifiedDirectControl"])
        }
    }
}

final class QuietWaitingTests: XCTestCase {
    func testEightSecondTransitionKeepsOnlyOnePendingConnection() {
        var p = ConnectionPolicy(hasRememberedDevice: true)
        XCTAssertTrue(p.beginAttempt(hasRememberedDevice: true))
        XCTAssertEqual(p.state, .connecting)
        p.settleWaiting()
        XCTAssertEqual(p.state, .waitingForQC)
        for _ in 0..<100 { XCTAssertFalse(p.beginAttempt(hasRememberedDevice: true)) }
        XCTAssertTrue(p.hasPendingConnection); XCTAssertNil(p.nextRetryDelay())
        p.setForeground(false); p.setForeground(true)
        XCTAssertTrue(p.hasPendingConnection); XCTAssertEqual(p.state, .waitingForQC)
        p.connected(); XCTAssertEqual(p.state, .connected)
    }
    func testPowerLossIsNotClaimedToBePowerOff() {
        var p = ConnectionPolicy(hasRememberedDevice: true)
        p.connected(); p.linkLost()
        XCTAssertEqual(p.state, .waitingForQC)
        XCTAssertTrue(p.beginAttempt(hasRememberedDevice: true))
        p.connected(); XCTAssertEqual(p.state, .connected)
    }
    func testPersistedPauseSurvivesStartupAndForeground() {
        var p = ConnectionPolicy(wantsConnection: false, hasRememberedDevice: true)
        p.setForeground(false); p.setForeground(true); p.radioReady()
        XCTAssertFalse(p.beginAttempt(hasRememberedDevice: true))
        XCTAssertEqual(p.state, .paused)
        p.resume(); XCTAssertTrue(p.beginAttempt(hasRememberedDevice: true))
    }
    func testRadioAndPermissionStatesArePreservedAcrossLinkCleanup() {
        var p = ConnectionPolicy(hasRememberedDevice: true)
        p.radioUnavailable(.bluetoothOff); p.linkLost()
        XCTAssertEqual(p.state, .bluetoothOff)
        p.radioReady(); XCTAssertEqual(p.state, .waitingForQC)
        p.radioUnavailable(.permissionNeeded); p.linkLost()
        XCTAssertEqual(p.state, .permissionNeeded)
    }
    func testFirstLaunchDoesNotInventAHeadphoneProfile() {
        var p = ConnectionPolicy()
        XCTAssertFalse(p.beginAttempt(hasRememberedDevice: false))
        XCTAssertEqual(p.state, .setupRequired)
    }
}
