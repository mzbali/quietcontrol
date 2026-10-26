// BLE framing adapted from NerdySouth/bozo (MIT). See THIRD_PARTY_NOTICES.md.
import Foundation

public enum BLEFramingError: Error, Equatable {
    case emptyMessage
    case messageTooLarge
    case emptySegment
    case invalidSegmentIndex
    case missingOrOutOfOrderSegment
    case inconsistentSegmentCount
}

/// Bose's documented BLE envelope, separate from the BMAP packet codec.
/// A matching service AND characteristic must be established before using this.
public enum BoseBLEFraming {
    public static let serviceUUID = "0000FEBE-0000-1000-8000-00805F9B34FB"
    public static let secureCharacteristicUUID = "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8"
    public static let plainCharacteristicUUID = "D417C028-9818-4354-99D1-2AC09D074591"

    /// Nineteen data bytes plus one header fits the baseline BLE MTU of 23.
    public static func segments(for data: Data) throws -> [Data] {
        guard !data.isEmpty else { throw BLEFramingError.emptyMessage }
        let count = (data.count + 18) / 19
        guard count <= 16 else { throw BLEFramingError.messageTooLarge }
        return (0..<count).map { index in
            Data([UInt8(((count - 1) << 4) | index)]) + data.dropFirst(index * 19).prefix(19)
        }
    }
}

public struct BoseBLEReassembler {
    private var lastIndex: Int?
    private var nextIndex = 0
    private var buffer = Data()
    public init() {}

    public mutating func receive(_ segment: Data) throws -> Data? {
        guard let header = segment.first else { reset(); throw BLEFramingError.emptySegment }
        let maximum = Int(header >> 4)
        let index = Int(header & 0x0f)
        guard index <= maximum else { reset(); throw BLEFramingError.invalidSegmentIndex }
        // A fresh index-zero packet resets any stale incomplete notification.
        if index == 0 { reset(); lastIndex = maximum }
        guard let expected = lastIndex, index == nextIndex else {
            reset(); throw BLEFramingError.missingOrOutOfOrderSegment
        }
        guard maximum == expected else { reset(); throw BLEFramingError.inconsistentSegmentCount }
        // Incoming notifications can use a negotiated MTU larger than outgoing
        // 20-byte writes. Bound the total without assuming a 20-byte notification.
        guard buffer.count + segment.count - 1 <= 4096 else { reset(); throw BLEFramingError.messageTooLarge }
        buffer.append(contentsOf: segment.dropFirst())
        nextIndex += 1
        if index == maximum {
            let result = buffer
            reset()
            return result
        }
        return nil
    }

    public mutating func reset() { lastIndex = nil; nextIndex = 0; buffer.removeAll() }
}

