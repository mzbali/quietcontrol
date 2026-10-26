// Protocol behavior adapted from aaronsb/bosectl (MIT); see THIRD_PARTY_NOTICES.md.
import Foundation

public enum BMAPError: LocalizedError, Equatable {
    case payloadTooLong
    case invalidOperator(UInt8)
    case truncatedFrame
    case bufferLimitExceeded
    case unexpectedResponse
    case malformedPayload
    case deviceError(UInt8)
    case invalidEQValue

    public var errorDescription: String? {
        switch self {
        case .payloadTooLong: return "The BMAP command exceeds the protocol payload limit."
        case .invalidOperator(let code): return "The QC returned an unknown BMAP operator (\(code))."
        case .truncatedFrame: return "The QC returned an incomplete BMAP response."
        case .bufferLimitExceeded: return "The Bluetooth response exceeded the allowed buffer size."
        case .unexpectedResponse: return "The QC response did not match the requested setting."
        case .malformedPayload: return "The QC response did not match the expected QuietComfort format."
        case .deviceError(let code): return "The QC rejected the command with BMAP error \(code)."
        case .invalidEQValue: return "EQ values must be between -10 and +10."
        }
    }
}

public enum BMAPOperator: UInt8, Sendable {
    case set = 0, get = 1, setGet = 2, status = 3, error = 4
    case start = 5, result = 6, processing = 7
}

public struct BMAPFrame: Equatable, Sendable {
    public let block: UInt8
    public let function: UInt8
    public let flags: UInt8
    public let payload: Data
    public var operation: BMAPOperator { BMAPOperator(rawValue: flags & 0x0f)! }

    public init(block: UInt8, function: UInt8, operation: BMAPOperator, payload: Data = Data()) throws {
        try self.init(block: block, function: function, flags: operation.rawValue, payload: payload)
    }

    public init(block: UInt8, function: UInt8, flags: UInt8, payload: Data) throws {
        guard payload.count <= 255 else { throw BMAPError.payloadTooLong }
        guard BMAPOperator(rawValue: flags & 0x0f) != nil else {
            throw BMAPError.invalidOperator(flags & 0x0f)
        }
        self.block = block
        self.function = function
        self.flags = flags
        self.payload = Data(payload)
    }

    public var encoded: Data { Data([block, function, flags, UInt8(payload.count)]) + payload }

    public func statusPayload(block: UInt8, function: UInt8) throws -> Data {
        guard self.block == block, self.function == function else { throw BMAPError.unexpectedResponse }
        if operation == .error {
            guard let code = payload.first else { throw BMAPError.malformedPayload }
            throw BMAPError.deviceError(code)
        }
        guard operation == .status else { throw BMAPError.unexpectedResponse }
        return payload
    }
}

/// Reassembles a byte stream, including notifications containing partial or multiple frames.
/// This codec is transport-independent. It does not establish that BMAP is accessible on iOS.
public struct BMAPStreamDecoder {
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [BMAPFrame] {
        guard buffer.count + data.count <= 8192 else {
            buffer.removeAll()
            throw BMAPError.bufferLimitExceeded
        }
        buffer.append(data)
        var frames: [BMAPFrame] = []
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            guard BMAPOperator(rawValue: bytes[2] & 0x0f) != nil else {
                buffer.removeAll()
                throw BMAPError.invalidOperator(bytes[2] & 0x0f)
            }
            let length = Int(bytes[3])
            guard buffer.count >= length + 4 else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            frames.append(try BMAPFrame(block: bytes[0], function: bytes[1], flags: bytes[2], payload: payload))
            buffer = Data(buffer.dropFirst(length + 4))
        }
        return frames
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw BMAPError.truncatedFrame }
    }
}

public enum EQBand: UInt8, CaseIterable, Codable, Sendable {
    case bass = 0, mid = 1, treble = 2
}

public struct EQSetting: Equatable, Codable, Sendable {
    public let band: EQBand
    public let minimum: Int
    public let maximum: Int
    public let value: Int
}

public struct ListeningMode: Equatable, Identifiable, Codable, Sendable {
    public var id: UInt8 { index }
    public let index: UInt8
    public let promptID: UInt8
    public let name: String
    public let editable: Bool
    public let configured: Bool
    public let rawCNC: UInt8
    public let windBlock: Bool
    /// Full 47-byte STATUS, retained so edits preserve fields we do not own.
    public var rawConfiguration: Data? = nil
    public var ancStrength: Int { 10 - Int(rawCNC) }
    public var displayName: String {
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        // Bose uses a prompt ID instead of a UTF-8 name for some configured modes.
        let names = ["", "Quiet", "Aware", "Transparent", "Transparency", "Masking", "Comfort", "Commute", "Outdoor", "Workout", "Home", "Work", "Music", "Focus", "Relax", "Flight", "Airport", "Driving", "Training", "Gym", "Run", "Walk", "Hike", "Talk", "Call", "Whisper", "Hearing", "Learn", "Podcast", "Audiobook", "Calm", "Sleep", "Meditate", "Yoga", "Immersion", "Stereo", "Cinema"]
        return promptID > 0 && Int(promptID) < names.count ? names[Int(promptID)] : "Mode \(index)"
    }
}

/// Exact QuietComfort Headphones profile (prince, 0x4075), not QC45 or Ultra.
public enum PrinceProtocol {
    public static let productID: UInt16 = 0x4075

    public static func batteryRequest() throws -> BMAPFrame { try .init(block: 2, function: 2, operation: .get) }
    public static func firmwareRequest() throws -> BMAPFrame { try .init(block: 0, function: 5, operation: .get) }
    public static func modeRequest() throws -> BMAPFrame { try .init(block: 31, function: 3, operation: .get) }
    public static func modesRequest() throws -> BMAPFrame { try .init(block: 31, function: 1, operation: .start) }
    public static func eqRequest() throws -> BMAPFrame { try .init(block: 1, function: 7, operation: .get) }

    public static func selectMode(_ index: UInt8, announce: Bool = false) throws -> BMAPFrame {
        try .init(block: 31, function: 3, operation: .start, payload: Data([index, announce ? 1 : 0]))
    }

    public static func setEQ(_ band: EQBand, value: Int) throws -> BMAPFrame {
        guard (-10...10).contains(value) else { throw BMAPError.invalidEQValue }
        return try .init(block: 1, function: 7, operation: .setGet,
                         payload: Data([UInt8(bitPattern: Int8(value)), band.rawValue]))
    }

    public static func editMode(_ mode: ListeningMode, strength: Int, windBlock: Bool) throws -> BMAPFrame {
        guard mode.editable, mode.configured, (2...3).contains(mode.index), (0...10).contains(strength),
              let raw = mode.rawConfiguration, raw.count == 47, raw[0] == mode.index else { throw BMAPError.malformedPayload }
        // prince SETGET differs from STATUS: omit flags/unknown fields, retain
        // both prompt bytes, exact name bytes, auto-CNC and spatial fields.
        var payload = Data(raw[0...2]) + raw[6...37]
        payload.append(UInt8(10 - strength))
        payload.append(raw[43]); payload.append(raw[44]); payload.append(windBlock ? 1 : 0)
        return try .init(block: 31, function: 6, operation: .setGet, payload: payload)
    }

    public static func battery(from frame: BMAPFrame) throws -> Int? {
        let payload = try frame.statusPayload(block: 2, function: 2)
        guard let value = payload.first else { throw BMAPError.malformedPayload }
        if value == 0xff { return nil }
        guard value <= 100 else { throw BMAPError.malformedPayload }
        return Int(value)
    }

    public static func currentMode(from frame: BMAPFrame) throws -> UInt8 {
        let payload = try frame.statusPayload(block: 31, function: 3)
        guard payload.count == 1, let index = payload.first else { throw BMAPError.malformedPayload }
        return index
    }

    /// PROCESSING acknowledges an asynchronous action, not a confirmed state change.
    public static func isModeAcknowledgement(_ frame: BMAPFrame) -> Bool {
        frame.block == 31 && frame.function == 3 && [.result, .processing].contains(frame.operation)
    }

    public static func eq(from frame: BMAPFrame) throws -> [EQSetting] {
        let payload = [UInt8](try frame.statusPayload(block: 1, function: 7))
        guard payload.count == 12 else { throw BMAPError.malformedPayload }
        var settings: [EQSetting] = []
        for offset in stride(from: 0, to: payload.count, by: 4) {
            guard let band = EQBand(rawValue: payload[offset + 3]),
                  !settings.contains(where: { $0.band == band }) else { throw BMAPError.malformedPayload }
            let minimum = Int(Int8(bitPattern: payload[offset]))
            let maximum = Int(Int8(bitPattern: payload[offset + 1]))
            let value = Int(Int8(bitPattern: payload[offset + 2]))
            guard minimum <= maximum, (minimum...maximum).contains(value) else { throw BMAPError.malformedPayload }
            settings.append(.init(band: band, minimum: minimum, maximum: maximum, value: value))
        }
        return settings.sorted { $0.band.rawValue < $1.band.rawValue }
    }

    public static func modeConfiguration(from frame: BMAPFrame) throws -> ListeningMode {
        let bytes = [UInt8](try frame.statusPayload(block: 31, function: 6))
        guard bytes.count == 47, bytes[42] <= 10, bytes[3] <= 1,
              bytes[4] <= 1, bytes[46] <= 1 else { throw BMAPError.malformedPayload }
        let nameBytes = bytes[6..<38].prefix { $0 != 0 }
        guard let name = String(bytes: nameBytes, encoding: .utf8) else { throw BMAPError.malformedPayload }
        return .init(index: bytes[0], promptID: bytes[2], name: name, editable: bytes[3] == 1,
                     configured: bytes[4] == 1, rawCNC: bytes[42], windBlock: bytes[46] == 1, rawConfiguration: Data(bytes))
    }
}

