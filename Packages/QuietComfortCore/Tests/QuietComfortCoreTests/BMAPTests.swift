import XCTest
@testable import QuietComfortCore

final class BMAPTests: XCTestCase {
    // Golden commands published in the pinned prince protocol notes.
    func testGoldenCommandsAndSignedEQ() throws {
        XCTAssertEqual(try PrinceProtocol.modeRequest().encoded, Data([0x1f, 3, 1, 0]))
        XCTAssertEqual(try PrinceProtocol.selectMode(1).encoded, Data([0x1f, 3, 5, 2, 1, 0]))
        XCTAssertEqual(try PrinceProtocol.setEQ(.bass, value: -10).encoded, Data([1, 7, 2, 2, 0xf6, 0]))
        XCTAssertThrowsError(try PrinceProtocol.setEQ(.mid, value: 11))
        XCTAssertThrowsError(try BMAPFrame(block: 1, function: 1, operation: .get, payload: Data(repeating: 0, count: 256)))
    }

    func testEveryFragmentBoundaryAndCoalescedResponses() throws {
        let battery = Data([2, 2, 3, 4, 80, 0xff, 0xff, 0])
        let mode = Data([31, 3, 3, 1, 1])
        let stream = battery + mode
        for split in 0...stream.count {
            var decoder = BMAPStreamDecoder()
            let frames = try decoder.append(Data(stream.prefix(split))) + decoder.append(Data(stream.dropFirst(split)))
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(try PrinceProtocol.battery(from: frames[0]), 80)
            XCTAssertEqual(try PrinceProtocol.currentMode(from: frames[1]), 1)
            try decoder.finish()
        }
    }

    func testFlagsTruncationAndMalformedStream() throws {
        var decoder = BMAPStreamDecoder()
        let frames = try decoder.append(Data([31, 3, 0xc3, 1, 0]))
        XCTAssertEqual(frames.first?.flags, 0xc3)
        XCTAssertEqual(frames.first?.operation, .status)
        XCTAssertEqual(try decoder.append(Data([2, 2, 3, 4, 80])), [])
        XCTAssertThrowsError(try decoder.finish())
        var invalid = BMAPStreamDecoder()
        XCTAssertThrowsError(try invalid.append(Data([1, 1, 15, 0])))
        XCTAssertThrowsError(try invalid.append(Data(repeating: 0, count: 8193)))
    }

    func testDeviceErrorAndAsynchronousModeChangeAreNotConfirmedState() throws {
        let error = try BMAPFrame(block: 1, function: 7, operation: .error, payload: Data([5]))
        XCTAssertThrowsError(try PrinceProtocol.eq(from: error)) { XCTAssertEqual($0 as? BMAPError, .deviceError(5)) }
        let processing = try BMAPFrame(block: 31, function: 3, operation: .processing)
        XCTAssertTrue(PrinceProtocol.isModeAcknowledgement(processing))
        XCTAssertThrowsError(try PrinceProtocol.currentMode(from: processing))
        let unrelated = try BMAPFrame(block: 1, function: 3, operation: .processing)
        XCTAssertFalse(PrinceProtocol.isModeAcknowledgement(unrelated))
    }

    func testEQResponseBandOrderingAndMalformedPayloads() throws {
        let payload = Data([0xf6, 10, 0xfe, 2, 0xf6, 10, 6, 0, 0xf6, 10, 5, 1])
        let frame = try BMAPFrame(block: 1, function: 7, operation: .status, payload: payload)
        XCTAssertEqual(try PrinceProtocol.eq(from: frame).map(\.value), [6, 5, -2])
        var duplicate = [UInt8](payload)
        duplicate[11] = 0
        XCTAssertThrowsError(try PrinceProtocol.eq(from: .init(block: 1, function: 7, operation: .status, payload: Data(duplicate))))
        XCTAssertThrowsError(try PrinceProtocol.eq(from: .init(block: 1, function: 7, operation: .status, payload: payload.prefix(11))))
        let noBattery = try BMAPFrame(block: 2, function: 2, operation: .status, payload: Data([0xff]))
        XCTAssertNil(try PrinceProtocol.battery(from: noBattery))
    }

    func testPrinceModeLayoutAndInvertedNoiseScale() throws {
        // Constructed from the published 47-byte layout; not a new hardware capture.
        var payload = [UInt8](repeating: 0, count: 47)
        payload[0] = 3; payload[3] = 1; payload[4] = 1
        payload.replaceSubrange(6..<11, with: Array("Music".utf8))
        payload[42] = 5; payload[46] = 1
        let frame = try BMAPFrame(block: 31, function: 6, operation: .status, payload: Data(payload))
        let mode = try PrinceProtocol.modeConfiguration(from: frame)
        XCTAssertEqual(mode.name, "Music")
        XCTAssertEqual(mode.ancStrength, 5)
        XCTAssertTrue(mode.windBlock)
        payload.append(0) // Ultra's 48-byte layout must not be accepted as prince.
        XCTAssertThrowsError(try PrinceProtocol.modeConfiguration(from: .init(block: 31, function: 6, operation: .status, payload: Data(payload))))
    }

    func testObservedUnnamedFocusModeUsesItsDevicePromptID() throws {
        // Observed on the QC's BLE reply: configured slot 2, prompt 13, empty name.
        var payload = [UInt8](repeating: 0, count: 47)
        payload[0] = 2; payload[2] = 13; payload[3] = 1; payload[4] = 1
        payload[41] = 9; payload[42] = 5
        let frame = try BMAPFrame(block: 31, function: 6, operation: .status, payload: Data(payload))
        let mode = try PrinceProtocol.modeConfiguration(from: frame)
        XCTAssertEqual(mode.displayName, "Focus")
        XCTAssertEqual(mode.id, 2)
    }
    func testModeEditPreservesUnrelatedFieldsAndUsesPrinceLength() throws {
        var raw = [UInt8](repeating: 0, count: 47)
        raw[0] = 2; raw[1] = 7; raw[2] = 13; raw[3] = 1; raw[4] = 1
        raw[6] = 70; raw[7] = 0; raw[8] = 88 // Preserve the exact name field, including padding.
        raw[42] = 5; raw[43] = 0; raw[44] = 0
        let mode = try PrinceProtocol.modeConfiguration(from: .init(block: 31, function: 6, operation: .status, payload: Data(raw)))
        let command = try PrinceProtocol.editMode(mode, strength: 8, windBlock: true)
        XCTAssertEqual(command.payload.count, 39)
        XCTAssertEqual(command.encoded.prefix(4), Data([31, 6, 2, 39]))
        XCTAssertEqual(command.payload.prefix(3), Data([2, 7, 13]))
        XCTAssertEqual(command.payload[3..<35], Data(raw[6...37]))
        XCTAssertEqual(command.payload.suffix(4), Data([2, 0, 0, 1]))
        XCTAssertThrowsError(try PrinceProtocol.editMode(mode, strength: 11, windBlock: false))
        raw[0] = 0; raw[3] = 0
        let fixed = try PrinceProtocol.modeConfiguration(from: .init(block: 31, function: 6, operation: .status, payload: Data(raw)))
        XCTAssertThrowsError(try PrinceProtocol.editMode(fixed, strength: 5, windBlock: false))
    }

}
