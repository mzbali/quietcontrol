import XCTest
@testable import QuietComfortCore

final class BLEFramingTests: XCTestCase {
    func testGoldenSingleSegmentIncludesExactlyOneFramingByte() throws {
        let request = try PrinceProtocol.batteryRequest().encoded
        XCTAssertEqual(try BoseBLEFraming.segments(for: request), [Data([0, 2, 2, 1, 0])])
        var receiver = BoseBLEReassembler()
        let response = try receiver.receive(Data([0, 2, 2, 3, 1, 80]))
        var decoder = BMAPStreamDecoder()
        let frames = try decoder.append(XCTUnwrap(response))
        XCTAssertEqual(try PrinceProtocol.battery(from: XCTUnwrap(frames.first)), 80)
    }

    func testAllBMAPLengthsRoundTripWithoutExtraFraming() throws {
        for length in 4...259 {
            let original = Data((0..<length).map { UInt8($0 % 256) })
            let segments = try BoseBLEFraming.segments(for: original)
            XCTAssertTrue(segments.allSatisfy { $0.count <= 20 })
            var receiver = BoseBLEReassembler()
            var result: Data?
            for (index, segment) in segments.enumerated() {
                result = try receiver.receive(segment)
                if index < segments.count - 1 { XCTAssertNil(result) }
            }
            XCTAssertEqual(result, original)
        }
    }

    func testModeConfigUsesThreeSegmentsAndDetectsMissingPackets() throws {
        let data = Data(repeating: 1, count: 51)
        let segments = try BoseBLEFraming.segments(for: data)
        XCTAssertEqual(segments.compactMap(\.first), [0x20, 0x21, 0x22])
        var receiver = BoseBLEReassembler()
        XCTAssertNil(try receiver.receive(segments[0]))
        XCTAssertThrowsError(try receiver.receive(segments[2]))
        XCTAssertThrowsError(try receiver.receive(segments[1]))
        XCTAssertEqual(try receiver.receive(Data([0, 7])), Data([7]))
    }

    func testMalformedAndOversizeEnvelopes() throws {
        XCTAssertThrowsError(try BoseBLEFraming.segments(for: Data()))
        XCTAssertThrowsError(try BoseBLEFraming.segments(for: Data(repeating: 1, count: 305)))
        var receiver = BoseBLEReassembler()
        XCTAssertThrowsError(try receiver.receive(Data()))
        XCTAssertThrowsError(try receiver.receive(Data([0x12, 1])))
        XCTAssertNil(try receiver.receive(Data([0x10, 1])))
        XCTAssertThrowsError(try receiver.receive(Data([0x21, 2])))
        XCTAssertThrowsError(try receiver.receive(Data([0]) + Data(repeating: 1, count: 4097)))
    }
}
