#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Stateful synthetic QuietComfort. It receives the same segmented Bose envelopes
/// and BMAP frames as the live transport and answers through the same encoder and
/// reassembler. Unknown or unsupported functions return an explicit device error;
/// nothing here fabricates a command success that the state did not confirm.
@MainActor
final class QCSimulatorPeripheral: QCByteTransport {
    weak var delegate: QCByteTransportDelegate?
    private(set) var identifier: UUID?
    private(set) var isConnected = false
    private(set) var radioState: QCTransportRadioState = .unknown
    var canSendWriteWithoutResponse: Bool { isConnected }

    private let scenario: QCTestScenario
    private let runID: String
    private let defaults: UserDefaults
    private let evidence: QCTestEvidence
    private let peripheralID: UUID
    private let firmware: String
    private let endpoint = QCTransportEndpoint(id: "SIMULATED-FEBE-SECURE", writeWithoutResponse: true)

    private var reassembler = BoseBLEReassembler()
    private var mode: UInt8 = 0
    private var battery = 90
    private var eq = [-1, 4, 2]
    private var multipoint = true
    private var devices: [SimulatedDevice] = [
        SimulatedDevice(address: Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x01]), name: "iPhone", connection: 3),
        SimulatedDevice(address: Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x02]), name: "MacBook Pro", connection: 1),
        SimulatedDevice(address: Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x03]), name: "Work laptop", connection: 0)
    ]
    private var activeAddress = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x01])
    private var modeConfigurations = QCSimulatorPeripheral.baselineModes()
    private var preferences: [String: Data] = [
        "voicePrompts": Data([0x21]),
        "selfVoice": Data([1, 2]),
        "shortcut": Data([0x80, 9, 3]),
        "autoOff": Data([0]),
        "rememberMode": Data([1])
    ]
    private var repliesInFlight = 0
    private var rejectedEQWrite = false
    private var pendingConnect: CheckedContinuation<QCTransportLink, Error>?
    private var connectRequests = 0

    static let workLaptopAddress = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x03])
    static let macBookAddress = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0x02])

    private struct SimulatedDevice {
        var address: Data
        var name: String
        var connection: UInt8
    }

    init(scenario: QCTestScenario, runID: String, defaults: UserDefaults,
         evidence: QCTestEvidence, peripheralID: UUID) {
        self.scenario = scenario
        self.runID = runID
        self.defaults = defaults
        self.evidence = evidence
        self.peripheralID = peripheralID
        firmware = scenario.firmware
        publishState(connected: false)
    }

    var isWaitingForConnection: Bool { pendingConnect != nil }

    func prepareRadio() {
        switch scenario {
        case .radioOff:
            radioState = .poweredOff
        case .permissionDenied:
            radioState = .unauthorized
        default:
            radioState = .poweredOn
        }
        let state = radioState
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard let self else { return }
            self.delegate?.transport(self, radioStateChanged: state)
        }
    }

    func connect(rememberedID: UUID) async throws -> QCTransportLink {
        connectRequests += 1
        guard scenario != .radioOff, scenario != .permissionDenied else {
            evidence.event("Simulated radio is unavailable; connect request \(connectRequests) refused.")
            throw QCSessionError.unavailable("Bluetooth is not available for this scenario.")
        }
        guard scenario != .offlineCached else {
            evidence.event("Simulated QC is offline for scenario \(scenario.rawValue).")
            throw QCSessionError.unavailable("The simulated QC is offline for this scenario.")
        }
        defaults.set(peripheralID.uuidString, forKey: QCTestHarness.rememberedKey)
        if scenario == .pendingConnection {
            evidence.event("Connect request \(connectRequests) is pending for run \(runID).")
            return try await withCheckedThrowingContinuation { continuation in
                pendingConnect = continuation
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        evidence.event("Connect request \(connectRequests) completed for run \(runID).")
        isConnected = true
        identifier = peripheralID
        publishState(connected: true)
        return QCTransportLink(identifier: peripheralID, name: "QC Simulator",
                               manufacturer: "Bose Corporation", model: "884367-0100",
                               endpoints: [endpoint])
    }

    func enableNotifications(for endpoint: QCTransportEndpoint) async throws {
        guard isConnected else { throw QCSessionError.disconnected }
        reassembler.reset()
    }

    func disableNotifications(for endpoint: QCTransportEndpoint) {
        reassembler.reset()
    }

    func maximumWriteLength(for endpoint: QCTransportEndpoint, withoutResponse: Bool) -> Int { 20 }

    func write(_ segment: Data, to endpoint: QCTransportEndpoint, withoutResponse: Bool) throws {
        guard isConnected else { throw QCSessionError.disconnected }
        evidence.record(direction: "outbound", kind: "segment", bytes: segment)
        guard let complete = try reassembler.receive(segment) else { return }
        var decoder = BMAPStreamDecoder()
        let frames = try decoder.append(complete)
        try decoder.finish()
        for frame in frames {
            evidence.record(direction: "outbound", kind: "bmap", bytes: frame.encoded)
            respond(to: frame)
        }
    }

    func close() {
        let pending = pendingConnect
        pendingConnect = nil
        if pending != nil { evidence.event("Closed the pending simulated connection for run \(runID).") }
        isConnected = false
        identifier = nil
        reassembler.reset()
        publishState(connected: false)
        pending?.resume(throwing: QCSessionError.disconnected)
    }

    // MARK: - Request handling

    private func respond(to frame: BMAPFrame) {
        if repliesInFlight > 0 {
            evidence.event("Protocol overlap: a request arrived while \(repliesInFlight) replies were pending.")
            deliver([errorFrame(for: frame, code: 4)])
            return
        }
        let responseFrames: [BMAPFrame]
        do {
            responseFrames = try replies(for: frame)
        } catch {
            evidence.event("Simulated command failed: \(error.localizedDescription)")
            deliver([errorFrame(for: frame, code: 4)])
            return
        }
        guard !responseFrames.isEmpty else {
            evidence.event("No simulated reply for [\(frame.block).\(frame.function)].")
            deliver([errorFrame(for: frame, code: 4)])
            return
        }
        deliver(responseFrames)
    }

    private func replies(for frame: BMAPFrame) throws -> [BMAPFrame] {
        switch (frame.block, frame.function, frame.operation) {
        case (0, 5, .get):
            return [try reply(frame, .status, Data(firmware.utf8))]
        case (2, 2, .get):
            return [try reply(frame, .status, Data([UInt8(battery)]))]
        case (31, 3, .get):
            return [try reply(frame, .status, Data([mode]))]
        case (31, 3, .start):
            guard frame.payload.count >= 1 else { throw BMAPError.malformedPayload }
            let requested = frame.payload[frame.payload.startIndex]
            guard modeConfigurations.keys.contains(requested) else { throw BMAPError.malformedPayload }
            switch scenario {
            case .modeRejected:
                evidence.event("Rejected simulated mode write \(requested).")
                return [try reply(frame, .error, Data([4]))]
            case .modeUnconfirmed:
                evidence.event("Accepted simulated mode write \(requested) without changing state.")
                return [try reply(frame, .status, Data([mode]))]
            default:
                mode = requested
                publishState(connected: true)
                return [try reply(frame, .status, Data([mode]))]
            }
        case (31, 1, .start):
            return try modeConfigurations.keys.sorted().compactMap { index in
                guard let payload = modeConfigurations[index] else { return nil }
                return try BMAPFrame(block: 31, function: 6, operation: .status, payload: payload)
            }
        case (1, 7, .get):
            return [try reply(frame, .status, eqPayload())]
        case (1, 7, .setGet):
            guard frame.payload.count == 2 else { throw BMAPError.malformedPayload }
            let value = Int(Int8(bitPattern: frame.payload[frame.payload.startIndex]))
            let band = Int(frame.payload[frame.payload.startIndex + 1])
            guard (0...2).contains(band), (-10...10).contains(value) else { throw BMAPError.malformedPayload }
            if scenario == .eqRejected && !rejectedEQWrite {
                rejectedEQWrite = true
                evidence.event("Rejected one simulated EQ write (band \(band) = \(value)); confirmed EQ is unchanged.")
                return [try reply(frame, .error, Data([4]))]
            }
            eq[band] = value
            publishState(connected: true)
            return [try reply(frame, .status, eqPayload())]
        case (4, 4, .get):
            return [try reply(frame, .status, Data([0]) + devices.map(\.address).reduce(Data(), +))]
        case (4, 5, .get):
            guard let device = devices.first(where: { $0.address == frame.payload }) else { throw BMAPError.malformedPayload }
            return [try reply(frame, .status, device.address + Data([device.connection, 0, 0]) + Data(device.name.utf8))]
        case (5, 1, .get):
            if activeAddress.isEmpty { return [try reply(frame, .status, Data([0, 0, 0]))] }
            return [try reply(frame, .status, Data([0, 0, 1]) + activeAddress)]
        case (1, 10, .get):
            return [try reply(frame, .status, Data([multipoint ? 1 : 0]))]
        case (1, 10, .setGet):
            guard frame.payload.count == 1 else { throw BMAPError.malformedPayload }
            multipoint = frame.payload[frame.payload.startIndex] & 1 != 0
            publishState(connected: true)
            return [try reply(frame, .status, Data([multipoint ? 1 : 0]))]
        case (4, 1, .start):
            guard frame.payload.count == 7 else { throw BMAPError.malformedPayload }
            let address = Data(frame.payload.dropFirst())
            guard let index = devices.firstIndex(where: { $0.address == address }) else { throw BMAPError.malformedPayload }
            if scenario == .audioUnreachable && address == Self.workLaptopAddress {
                evidence.event("Simulated Work laptop is unreachable; the QC keeps paging it (BMAP error 8).")
                return [try reply(frame, .error, Data([8]))]
            }
            devices[index].connection = 1
            publishState(connected: true)
            return [try reply(frame, .status, Data([0]))]
        case (4, 2, .start):
            guard let index = devices.firstIndex(where: { $0.address == frame.payload }) else { throw BMAPError.malformedPayload }
            if scenario == .audioUnreachable && frame.payload == Self.workLaptopAddress {
                evidence.event("Stopped paging the unreachable Work laptop; no phantom connection exists.")
            }
            devices[index].connection = 0
            if activeAddress == devices[index].address { activeAddress = Data() }
            publishState(connected: true)
            return [try reply(frame, .status, Data([0]))]
        case (4, 12, .start):
            guard frame.payload.count == 7 else { throw BMAPError.malformedPayload }
            let address = Data(frame.payload.dropFirst())
            guard devices.contains(where: { $0.address == address && $0.connection & 1 != 0 }) else { throw BMAPError.malformedPayload }
            activeAddress = address
            publishState(connected: true)
            return [try reply(frame, .status, Data([0]))]
        case (1, 3, .get), (1, 11, .get), (1, 9, .get), (1, 4, .get), (31, 5, .get):
            return [try reply(frame, .status, try preference(for: frame))]
        case (1, 3, .setGet), (1, 11, .setGet), (1, 9, .setGet), (1, 4, .setGet), (31, 5, .setGet):
            let name = preferenceName(block: frame.block, function: frame.function)
            preferences[name] = frame.payload
            evidence.event("Simulated \(name) write stored \(frame.payload.hexString).")
            publishState(connected: true)
            return [try reply(frame, .status, frame.payload)]
        case (31, 6, .setGet):
            guard frame.payload.count == 39 else { throw BMAPError.malformedPayload }
            let payload = [UInt8](frame.payload)
            var bytes = [UInt8](modeConfigurations[payload[0]] ?? Data(repeating: 0, count: 47))
            guard bytes.count == 47 else { throw BMAPError.malformedPayload }
            bytes.replaceSubrange(0...2, with: payload[0...2])
            bytes.replaceSubrange(6..<38, with: payload[3..<35])
            bytes[42] = payload[35]
            bytes[43] = payload[36]
            bytes[44] = payload[37]
            bytes[46] = payload[38]
            let updated = Data(bytes)
            modeConfigurations[payload[0]] = updated
            publishState(connected: true)
            return [try BMAPFrame(block: 31, function: 6, operation: .status, payload: updated)]
        default:
            evidence.event("Unsupported simulated command [\(frame.block).\(frame.function)] op \(frame.operation.rawValue).")
            throw BMAPError.unexpectedResponse
        }
    }

    private func reply(_ request: BMAPFrame, _ operation: BMAPOperator, _ payload: Data) throws -> BMAPFrame {
        try BMAPFrame(block: request.block, function: request.function, operation: operation, payload: payload)
    }

    private func errorFrame(for request: BMAPFrame, code: UInt8) -> BMAPFrame {
        (try? BMAPFrame(block: request.block, function: request.function, operation: .error, payload: Data([code])))
            ?? (try! BMAPFrame(block: request.block, function: request.function, operation: .error))
    }

    private func eqPayload() -> Data {
        var data = Data()
        for band in 0..<3 {
            data.append(UInt8(bitPattern: Int8(-10)))
            data.append(UInt8(bitPattern: Int8(10)))
            data.append(UInt8(bitPattern: Int8(eq[band])))
            data.append(UInt8(band))
        }
        return data
    }

    private func preference(for frame: BMAPFrame) throws -> Data {
        let name = preferenceName(block: frame.block, function: frame.function)
        guard let value = preferences[name] else { throw BMAPError.malformedPayload }
        return value
    }

    private func preferenceName(block: UInt8, function: UInt8) -> String {
        if block == 31 && function == 5 { return "rememberMode" }
        return ["voicePrompts": 3, "selfVoice": 11, "autoOff": 4, "shortcut": 9]
            .first { $0.value == Int(function) }?.key ?? "unknown"
    }

    private func deliver(_ frames: [BMAPFrame]) {
        guard !frames.isEmpty else { return }
        repliesInFlight += frames.count
        Task { @MainActor [weak self] in
            guard let self else { return }
            for frame in frames {
                try? await Task.sleep(nanoseconds: 8_000_000)
                guard self.isConnected else { return }
                let encoded = frame.encoded
                self.evidence.record(direction: "inbound", kind: "bmap", bytes: encoded)
                guard let segments = try? BoseBLEFraming.segments(for: encoded) else { continue }
                for segment in segments {
                    self.evidence.record(direction: "inbound", kind: "segment", bytes: segment)
                    self.delegate?.transport(self, didReceive: segment)
                }
            }
            self.repliesInFlight = 0
        }
    }

    private func publishState(connected: Bool) {
        evidence.writePeripheralState(QCSimulatedPeripheralState(
            scenario: scenario.rawValue, runID: runID, connected: connected, mode: mode, eq: eq,
            multipoint: multipoint,
            devices: devices.map { .init(address: $0.address.hexString, name: $0.name, connected: $0.connection & 1 != 0) },
            firmware: firmware,
            activeAudio: activeAddress.isEmpty ? nil : activeAddress.hexString,
            preferences: preferences.mapValues { $0.hexString },
            updatedAt: Date()))
    }

    private static func baselineModes() -> [UInt8: Data] {
        [
            0: modeBytes(index: 0, prompt: 1, name: "Quiet", editable: false, configured: true, cnc: 0, wind: false),
            1: modeBytes(index: 1, prompt: 2, name: "Aware", editable: false, configured: true, cnc: 0, wind: false),
            2: modeBytes(index: 2, prompt: 13, name: "Focus", editable: true, configured: true, cnc: 5, wind: false)
        ]
    }

    private static func modeBytes(index: UInt8, prompt: UInt8, name: String,
                                  editable: Bool, configured: Bool, cnc: UInt8, wind: Bool) -> Data {
        var bytes = [UInt8](repeating: 0, count: 47)
        bytes[0] = index
        bytes[2] = prompt
        bytes[3] = editable ? 1 : 0
        bytes[4] = configured ? 1 : 0
        for (offset, byte) in name.utf8.prefix(31).enumerated() { bytes[6 + offset] = byte }
        bytes[42] = cnc
        bytes[46] = wind ? 1 : 0
        return Data(bytes)
    }
}
#endif
