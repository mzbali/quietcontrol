import XCTest
@testable import QuietComfortCore

final class DeviceManagementTests: XCTestCase {
    private let phone = Data([1, 2, 3, 4, 5, 6])
    private let mac = Data([7, 8, 9, 10, 11, 12])
    private let work = Data([13, 14, 15, 16, 17, 18])
    private func frame(_ block: UInt8, _ function: UInt8, _ payload: Data) throws -> BMAPFrame {
        try .init(block: block, function: function, operation: .status, payload: payload)
    }
    private func device(_ address: Data, _ status: UInt8, _ name: String) throws -> PairedAudioDevice {
        try DeviceManagementProtocol.device(from: frame(4, 5, address + Data([status, 0, 0]) + Data(name.utf8)), expected: address)
    }
    func testObservedListAndNamesWithRedactedAddresses() throws {
        // Shapes captured from standard QC build 6; personal names/addresses replaced.
        let list = try frame(4, 4, Data([1]) + phone + mac + work)
        XCTAssertEqual(try DeviceManagementProtocol.addresses(from: list), [phone, mac, work])
        let own = try device(phone, 3, "Phone 🦍")
        XCTAssertTrue(own.isController); XCTAssertTrue(own.isConnected)
        XCTAssertEqual(own.name, "Phone 🦍")
        let controlOnly = try device(phone, 2, "Phone")
        XCTAssertTrue(controlOnly.isController); XCTAssertFalse(controlOnly.isConnected)
        XCTAssertFalse(try device(mac, 0, "MacBook Pro").isConnected)
        XCTAssertTrue(try device(work, 1, "Work laptop").isConnected)
    }
    func testSourceAndMultipointFlagsAreNotCountsOrBooleans() throws {
        XCTAssertEqual(try DeviceManagementProtocol.activeAddress(from: frame(5, 1, Data([0, 2, 1]) + phone)), phone)
        XCTAssertNil(try DeviceManagementProtocol.activeAddress(from: frame(5, 1, Data([0, 2, 0]))))
        XCTAssertTrue(try DeviceManagementProtocol.multipoint(from: frame(1, 10, Data([7]))))
        XCTAssertFalse(try DeviceManagementProtocol.multipoint(from: frame(1, 10, Data([6]))))
    }
    func testMalformedUnknownAndMismatchedRepliesAreRejected() throws {
        XCTAssertThrowsError(try DeviceManagementProtocol.addresses(from: frame(4, 4, Data())))
        XCTAssertThrowsError(try DeviceManagementProtocol.addresses(from: frame(4, 4, Data([1, 2]))))
        XCTAssertThrowsError(try DeviceManagementProtocol.addresses(from: frame(4, 4, Data([1]) + phone + phone)))
        XCTAssertThrowsError(try DeviceManagementProtocol.device(from: frame(4, 5, phone + Data([4, 0, 0]))))
        XCTAssertThrowsError(try DeviceManagementProtocol.device(from: frame(4, 5, phone + Data([3, 0, 0])), expected: mac))
        XCTAssertThrowsError(try DeviceManagementProtocol.activeAddress(from: frame(5, 1, Data([0, 2, 1]))))
        XCTAssertThrowsError(try DeviceManagementProtocol.connect(Data([1])))
        let rejected = try BMAPFrame(block: 4, function: 4, operation: .error, payload: Data([5]))
        XCTAssertThrowsError(try DeviceManagementProtocol.addresses(from: rejected))
    }
    func testConnectionCommandsPreserveWireOrderAndAudioRoutingIsSeparate() throws {
        XCTAssertEqual(try DeviceManagementProtocol.connect(phone).encoded, Data([4, 1, 5, 7, 0]) + phone)
        XCTAssertEqual(try DeviceManagementProtocol.disconnect(phone).encoded, Data([4, 2, 5, 6]) + phone)
        XCTAssertEqual(try DeviceManagementProtocol.route(phone).encoded, Data([4, 12, 5, 7, 0x82]) + phone)
        XCTAssertEqual(try DeviceManagementProtocol.setMultipoint(false).encoded, Data([1, 10, 2, 1, 0]))
    }
    func testFullSlotsRequireAnExplicitValidReplacement() throws {
        let devices = try [device(phone, 3, "Phone"), device(mac, 1, "Mac"), device(work, 0, "Work")]
        XCTAssertEqual(try DeviceConnectionPlanner.plan(target: work, devices: devices, multipoint: true), .chooseReplacement([phone, mac]))
        XCTAssertEqual(try DeviceConnectionPlanner.plan(target: work, devices: devices, multipoint: true, replacement: mac), .replace(mac))
        XCTAssertEqual(try DeviceConnectionPlanner.plan(target: phone, devices: devices, multipoint: true), .alreadyConnected)
        XCTAssertThrowsError(try DeviceConnectionPlanner.plan(target: work, devices: devices, multipoint: true, replacement: work))
        let one = try [device(phone, 3, "Phone"), device(mac, 0, "Mac")]
        XCTAssertEqual(try DeviceConnectionPlanner.plan(target: mac, devices: one, multipoint: true), .connect)
        XCTAssertEqual(try DeviceConnectionPlanner.plan(target: mac, devices: one, multipoint: false), .chooseReplacement([phone]))
    }
}

final class ConnectionPolicyTests: XCTestCase {
    func testBackgroundingPreservesConnectionIntent() {
        var policy = ConnectionPolicy()
        policy.setForeground(false)
        XCTAssertTrue(policy.wantsConnection)
        XCTAssertFalse(policy.isForeground)
        XCTAssertEqual(policy.nextRetryDelay(), 0)
        policy.setForeground(true)
        XCTAssertTrue(policy.wantsConnection)
    }
    func testExplicitPauseCancelsReconnectAcrossForegroundChanges() {
        var policy = ConnectionPolicy()
        policy.pause(); policy.setForeground(false); policy.setForeground(true)
        XCTAssertNil(policy.nextRetryDelay())
        policy.resume(); XCTAssertEqual(policy.nextRetryDelay(), 1)
    }
    func testRetryBackoffCapsAndResetsAfterConnection() {
        var policy = ConnectionPolicy()
        XCTAssertEqual((0..<7).compactMap { _ in policy.nextRetryDelay() }, [1, 2, 4, 8, 15, 15, 15])
        policy.connected(); XCTAssertNil(policy.nextRetryDelay())
        policy.linkLost(); XCTAssertEqual(policy.nextRetryDelay(), 1)
    }
}
