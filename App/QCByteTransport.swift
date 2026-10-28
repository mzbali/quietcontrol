@preconcurrency import CoreBluetooth
import Foundation

/// Radio availability as reported by the byte transport. The live transport maps
/// CBCentralManager state here; the simulated transport reports a synthetic radio.
enum QCTransportRadioState: Equatable {
    case unknown, poweredOn, poweredOff, unauthorized, unsupported, resetting
}

/// One command endpoint exposed by the headset. The verified secure endpoint is
/// listed before the plain fallback; the same firmware handshake validates either.
struct QCTransportEndpoint: Equatable, Hashable {
    /// Stable endpoint identity. For live transport this is the characteristic UUID.
    let id: String
    let writeWithoutResponse: Bool
}

/// Identity and command-endpoint metadata read during connection setup.
struct QCTransportLink: Equatable {
    let identifier: UUID
    let name: String?
    let manufacturer: String
    let model: String
    let endpoints: [QCTransportEndpoint]
}

/// Receives bytes and link events from a transport. All calls are on the main actor.
@MainActor
protocol QCByteTransportDelegate: AnyObject {
    func transport(_ transport: QCByteTransport, didReceive segment: Data)
    func transport(_ transport: QCByteTransport, didFailReceive error: Error)
    func transport(_ transport: QCByteTransport, didFinishWrite error: Error?)
    func transportIsReadyForMoreWrites(_ transport: QCByteTransport)
    func transport(_ transport: QCByteTransport, didDisconnect error: Error?)
    func transport(_ transport: QCByteTransport, radioStateChanged state: QCTransportRadioState)
    func transportDidRestoreLink(_ transport: QCByteTransport)
}

/// The radio boundary. The transport owns connection, identity metadata, endpoint
/// discovery, write readiness and link teardown. It never encodes or decodes BMAP;
/// the session keeps that state machine and the independent GET confirmations.
@MainActor
protocol QCByteTransport: AnyObject {
    var delegate: QCByteTransportDelegate? { get set }
    var identifier: UUID? { get }
    var isConnected: Bool { get }
    var isWaitingForConnection: Bool { get }
    var radioState: QCTransportRadioState { get }
    var canSendWriteWithoutResponse: Bool { get }
    /// Begin observing the radio. Live transport creates its CBCentralManager here.
    func prepareRadio()
    /// Radio, connection, services, characteristics and identity metadata.
    func connect(rememberedID: UUID) async throws -> QCTransportLink
    func enableNotifications(for endpoint: QCTransportEndpoint) async throws
    func disableNotifications(for endpoint: QCTransportEndpoint)
    func maximumWriteLength(for endpoint: QCTransportEndpoint, withoutResponse: Bool) -> Int
    /// Writes one already-segmented Bose envelope packet.
    func write(_ segment: Data, to endpoint: QCTransportEndpoint, withoutResponse: Bool) throws
    func close()
}

extension QCByteTransport {
    var isWaitingForConnection: Bool { false }
}

/// CoreBluetooth implementation of the byte boundary. It adapts the existing live
/// IO: the BMAP request engine, the secure/plain endpoint fallback and OS state
/// restoration stay in the session, while connection mechanics live here.
@MainActor
final class QCLiveByteTransport: NSObject, QCByteTransport {
    weak var delegate: QCByteTransportDelegate?
    private(set) var identifier: UUID?
    private(set) var isConnected = false
    private(set) var radioState: QCTransportRadioState = .unknown

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var activeCharacteristic: CBCharacteristic?
    private var candidates: [CBCharacteristic] = []
    private var isClosing = false

    private enum Stage: Equatable {
        case radio, connection, services, characteristics(CBUUID), metadata(CBUUID), notify
    }
    private var stage: Stage?
    private var stageWaiter: CheckedContinuation<Void, Error>?
    private var stageTimer: Task<Void, Never>?

    var isWaitingForConnection: Bool { stage == .connection }

    func prepareRadio() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "uk.co.mzbali.quietcontrol.central"
        ])
    }

    func connect(rememberedID: UUID) async throws -> QCTransportLink {
        prepareRadio()
        if central?.state != .poweredOn {
            try await wait(for: .radio) {
                if self.central == nil { self.prepareRadio() }
                else { self.radioChanged() }
            }
        }
        guard let central, let found = central.retrievePeripherals(withIdentifiers: [rememberedID]).first else {
            throw QCSessionError.unavailable("iOS could not retrieve the remembered QC. Run Connection inspection again.")
        }
        peripheral = found
        identifier = found.identifier
        found.delegate = self
        if found.state != .connected {
            try await wait(for: .connection) {
                if found.state != .connecting { central.connect(found, options: nil) }
            }
        }
        try await wait(for: .services) {
            found.discoverServices([CBUUID(string: "180A"), CBUUID(string: BoseBLEFraming.serviceUUID)])
        }
        for service in found.services ?? [] {
            try await wait(for: .characteristics(service.uuid)) {
                found.discoverCharacteristics(nil, for: service)
            }
        }
        guard let information = found.services?.first(where: { $0.uuid == CBUUID(string: "180A") }) else {
            throw QCSessionError.unavailable("The QC did not expose its Device Information service.")
        }
        let manufacturer = try await readText("2A29", in: information)
        let model = try await readText("2A24", in: information)
        guard let service = found.services?.first(where: { $0.uuid == CBUUID(string: BoseBLEFraming.serviceUUID) }) else {
            throw QCSessionError.unavailable("The documented Bose FEBE control service is unavailable.")
        }
        candidates = [BoseBLEFraming.secureCharacteristicUUID, BoseBLEFraming.plainCharacteristicUUID].compactMap { uuid in
            service.characteristics?.first {
                $0.uuid == CBUUID(string: uuid) && $0.properties.contains(.notify)
                && ($0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write))
            }
        }
        guard !candidates.isEmpty else {
            throw QCSessionError.unavailable("No documented Bose command characteristic is exposed.")
        }
        isConnected = true
        return QCTransportLink(
            identifier: found.identifier,
            name: found.name,
            manufacturer: manufacturer,
            model: model,
            endpoints: candidates.map {
                QCTransportEndpoint(id: $0.uuid.uuidString,
                                    writeWithoutResponse: $0.properties.contains(.writeWithoutResponse))
            })
    }

    func enableNotifications(for endpoint: QCTransportEndpoint) async throws {
        guard let peripheral, let characteristic = candidates.first(where: { $0.uuid.uuidString == endpoint.id }) else {
            throw QCSessionError.disconnected
        }
        activeCharacteristic = characteristic
        guard !characteristic.isNotifying else { return }
        try await wait(for: .notify) { peripheral.setNotifyValue(true, for: characteristic) }
    }

    func disableNotifications(for endpoint: QCTransportEndpoint) {
        guard let peripheral, let characteristic = candidates.first(where: { $0.uuid.uuidString == endpoint.id }) else { return }
        peripheral.setNotifyValue(false, for: characteristic)
    }

    func maximumWriteLength(for endpoint: QCTransportEndpoint, withoutResponse: Bool) -> Int {
        guard let peripheral else { return 0 }
        return peripheral.maximumWriteValueLength(for: withoutResponse ? .withoutResponse : .withResponse)
    }

    var canSendWriteWithoutResponse: Bool {
        peripheral?.canSendWriteWithoutResponse ?? false
    }

    func write(_ segment: Data, to endpoint: QCTransportEndpoint, withoutResponse: Bool) throws {
        guard let peripheral, let characteristic = candidates.first(where: { $0.uuid.uuidString == endpoint.id }),
              peripheral.state == .connected else { throw QCSessionError.disconnected }
        peripheral.writeValue(segment, for: characteristic, type: withoutResponse ? .withoutResponse : .withResponse)
    }

    func close() {
        isClosing = true
        defer { isClosing = false }
        stageTimer?.cancel(); stageTimer = nil
        completeStage(.failure(QCSessionError.disconnected))
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil; activeCharacteristic = nil; candidates = []
        identifier = nil; isConnected = false
    }

    private func readText(_ uuid: String, in service: CBService) async throws -> String {
        guard let peripheral, let characteristic = service.characteristics?.first(where: {
            $0.uuid == CBUUID(string: uuid) && $0.properties.contains(.read)
        }) else {
            throw QCSessionError.unavailable("Required device identity field \(uuid) is missing.")
        }
        try await wait(for: .metadata(characteristic.uuid)) { peripheral.readValue(for: characteristic) }
        guard let value = characteristic.value, let text = String(data: value, encoding: .utf8) else {
            throw BMAPError.malformedPayload
        }
        return text.trimmingCharacters(in: .controlCharacters)
    }

    private func wait(for stage: Stage, action: () -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.stage = stage
            stageWaiter = continuation
            if stage != .connection { armSetupTimeout(stage) }
            action()
        }
    }

    private func armSetupTimeout(_ stage: Stage) {
        stageTimer?.cancel()
        stageTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.stage == stage else { return }
            self.completeStage(.failure(QCSessionError.timedOut("Bluetooth setup timed out at \(stage).")))
        }
    }

    private func completeStage(_ result: Result<Void, Error>) {
        stageTimer?.cancel(); stageTimer = nil
        stage = nil
        let continuation = stageWaiter
        stageWaiter = nil
        continuation?.resume(with: result)
    }

    private func radioChanged() {
        guard stage == .radio else { return }
        switch radioState {
        case .poweredOn: completeStage(.success(()))
        case .poweredOff: completeStage(.failure(QCSessionError.unavailable("Turn on Bluetooth in iPhone Settings.")))
        case .unauthorized: completeStage(.failure(QCSessionError.unavailable("Allow Bluetooth access in QuietControl settings.")))
        case .unsupported: completeStage(.failure(QCSessionError.unavailable("Use a physical iPhone for Bluetooth control.")))
        case .unknown, .resetting: break
        }
    }
}

extension QCLiveByteTransport: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: radioState = .poweredOn
        case .poweredOff: radioState = .poweredOff
        case .unauthorized: radioState = .unauthorized
        case .unsupported: radioState = .unsupported
        case .resetting: radioState = .resetting
        default: radioState = .unknown
        }
        delegate?.transport(self, radioStateChanged: radioState)
        radioChanged()
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let id = UserDefaults.standard.string(forKey: "quietcontrol.lastPeripheral").flatMap(UUID.init(uuidString:)),
              let found = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first(where: { $0.identifier == id })
        else { return }
        peripheral = found
        found.delegate = self
        identifier = found.identifier
        isConnected = found.state == .connected
        delegate?.transportDidRestoreLink(self)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        completeStage(.success(()))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        completeStage(.failure(error ?? QCSessionError.disconnected))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        completeStage(.failure(QCSessionError.disconnected))
        isConnected = false
        if !isClosing { delegate?.transport(self, didDisconnect: error) }
    }
}

extension QCLiveByteTransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, stage == .services else { return }
        completeStage(error.map { .failure($0) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, stage == .characteristics(service.uuid) else { return }
        completeStage(error.map { .failure($0) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, activeCharacteristic === characteristic, stage == .notify else { return }
        if let error {
            completeStage(.failure(error))
        } else if characteristic.isNotifying {
            completeStage(.success(()))
        } else {
            completeStage(.failure(QCSessionError.unexpected("The QC did not enable command responses.")))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if stage == .metadata(characteristic.uuid) {
            completeStage(error.map { .failure($0) } ?? .success(()))
            return
        }
        guard activeCharacteristic === characteristic else { return }
        if let error { delegate?.transport(self, didFailReceive: error) }
        else if let value = characteristic.value { delegate?.transport(self, didReceive: value) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, activeCharacteristic === characteristic else { return }
        delegate?.transport(self, didFinishWrite: error)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        delegate?.transportIsReadyForMoreWrites(self)
    }
}
