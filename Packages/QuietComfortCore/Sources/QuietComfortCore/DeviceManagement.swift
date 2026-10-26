import Foundation

public enum PairedConnection: UInt8, Codable, Sendable {
    case disconnected = 0, connected = 1, controllerDisconnected = 2, controller = 3
    public var isConnected: Bool { rawValue & 1 != 0 }
}

public struct PairedAudioDevice: Identifiable, Equatable, Codable, Sendable {
    /// Six bytes in Bose wire order; never reverse them for a command.
    public let address: Data
    public let name: String
    public let connection: PairedConnection
    public var id: Data { address }
    public var isConnected: Bool { connection.isConnected }
    public var isController: Bool { connection.rawValue & 2 != 0 }
}

/// DeviceManagement wire fields independently implemented from published protocol
/// descriptions and validated against this standard QC's actual BLE replies.
public enum DeviceManagementProtocol {
    public static func listRequest() throws -> BMAPFrame { try .init(block: 4, function: 4, operation: .get) }
    public static func sourceRequest() throws -> BMAPFrame { try .init(block: 5, function: 1, operation: .get) }
    public static func multipointRequest() throws -> BMAPFrame { try .init(block: 1, function: 10, operation: .get) }
    public static func addresses(from frame: BMAPFrame) throws -> [Data] {
        let p = try frame.statusPayload(block: 4, function: 4)
        guard !p.isEmpty, (p.count - 1) % 6 == 0 else { throw BMAPError.malformedPayload }
        var result: [Data] = []
        for offset in stride(from: 1, to: p.count, by: 6) {
            let address = p.subdata(in: offset..<offset + 6)
            guard !result.contains(address) else { throw BMAPError.malformedPayload }
            result.append(address)
        }
        return result
    }
    public static func infoRequest(_ address: Data) throws -> BMAPFrame {
        try check(address)
        return try .init(block: 4, function: 5, operation: .get, payload: address)
    }
    public static func device(from frame: BMAPFrame, expected: Data? = nil) throws -> PairedAudioDevice {
        let p = try frame.statusPayload(block: 4, function: 5)
        guard p.count >= 9, let connection = PairedConnection(rawValue: p[p.startIndex + 6]),
              let name = String(data: p.dropFirst(9), encoding: .utf8) else { throw BMAPError.malformedPayload }
        let address = Data(p.prefix(6))
        if let expected, address != expected { throw BMAPError.unexpectedResponse }
        let clean = name.trimmingCharacters(in: .controlCharacters)
        return PairedAudioDevice(address: address, name: clean.isEmpty ? "Paired device" : clean, connection: connection)
    }
    public static func activeAddress(from frame: BMAPFrame) throws -> Data? {
        let p = try frame.statusPayload(block: 5, function: 1)
        guard p.count >= 3 else { throw BMAPError.malformedPayload }
        switch p[p.startIndex + 2] {
        case 0, 2: return nil
        case 1:
            guard p.count >= 9 else { throw BMAPError.malformedPayload }
            return Data(p.dropFirst(3).prefix(6))
        default: throw BMAPError.malformedPayload
        }
    }
    public static func multipoint(from frame: BMAPFrame) throws -> Bool {
        let p = try frame.statusPayload(block: 1, function: 10)
        guard p.count == 1 else { throw BMAPError.malformedPayload }
        return p[p.startIndex] & 1 != 0
    }
    public static func connect(_ address: Data) throws -> BMAPFrame {
        try check(address)
        return try .init(block: 4, function: 1, operation: .start, payload: Data([0]) + address)
    }
    public static func disconnect(_ address: Data) throws -> BMAPFrame {
        try check(address)
        return try .init(block: 4, function: 2, operation: .start, payload: address)
    }
    public static func route(_ address: Data) throws -> BMAPFrame {
        try check(address)
        return try .init(block: 4, function: 12, operation: .start, payload: Data([0x82]) + address)
    }
    public static func setMultipoint(_ value: Bool) throws -> BMAPFrame {
        try .init(block: 1, function: 10, operation: .setGet, payload: Data([value ? 1 : 0]))
    }
    private static func check(_ address: Data) throws {
        guard address.count == 6 else { throw BMAPError.malformedPayload }
    }
}

public enum DeviceConnectionPlan: Equatable {
    case alreadyConnected, connect, chooseReplacement([Data]), replace(Data)
}

public enum DeviceConnectionPlanner {
    public static func plan(target: Data, devices: [PairedAudioDevice], multipoint: Bool, replacement: Data? = nil) throws -> DeviceConnectionPlan {
        guard let device = devices.first(where: { $0.address == target }) else { throw BMAPError.unexpectedResponse }
        if device.isConnected { return .alreadyConnected }
        let connected = devices.filter(\.isConnected).map(\.address)
        if connected.count < (multipoint ? 2 : 1) { return .connect }
        guard let replacement else { return .chooseReplacement(connected) }
        guard connected.contains(replacement) else { throw BMAPError.unexpectedResponse }
        return .replace(replacement)
    }
}
