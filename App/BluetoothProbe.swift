import Combine
import CoreBluetooth
import ExternalAccessory
import Foundation

struct NearbyDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int?
    var advertisedServices: [String]
    var source: String
    var looksLikeBose: Bool {
        name.localizedCaseInsensitiveContains("bose") || name.localizedCaseInsensitiveContains("quietcomfort")
    }
}

enum ProbePhase: String {
    case idle, scanning, connecting, discovering, reading, complete, failed, unavailable
    var isBusy: Bool { [.scanning, .connecting, .discovering, .reading].contains(self) }
}

/// Read-only feasibility probe. No BMAP, arbitrary characteristic writes, or EASession
/// are enabled until an iOS-accessible control transport is independently verified.
final class BluetoothProbe: NSObject, ObservableObject {
    @Published private(set) var phase: ProbePhase = .idle
    @Published private(set) var message = "Turn on your QuietComfort, connect it in iPhone Bluetooth settings, then check the connection."
    @Published private(set) var nearby: [NearbyDevice] = []
    @Published private(set) var report = ProbeReport()
    @Published private(set) var persistenceError: String?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var scanRequested = false
    private var operationTimer: DispatchWorkItem?
    private var readTimer: DispatchWorkItem?
    private var pendingServices = Set<ObjectIdentifier>()
    private var serviceIndices: [ObjectIdentifier: Int] = [:]
    private var characteristicLocations: [ObjectIdentifier: (Int, Int)] = [:]
    private var reads: [CBCharacteristic] = []
    private var currentRead: CBCharacteristic?
    private let defaults: UserDefaults
    private let rememberedKey = "quietcontrol.lastPeripheral"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        refreshAccessories(save: false)
    }

    func startScan() {
        stopConnection()
        report = ProbeReport()
        persistenceError = nil
        nearby.removeAll()
        peripherals.removeAll()
        scanRequested = true
        phase = .scanning
        message = "Checking Bluetooth…"
        refreshAccessories()
        log("User started a connection inspection.")
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn {
            beginScan()
        } else {
            updateAvailability()
        }
    }

    private func beginScan() {
        guard scanRequested, let central, central.state == .poweredOn else { return }
        phase = .scanning
        message = "Looking for your QC. Choose it below when it appears."
        // Classic GATT events require explicit matching services or remembered
        // peripheral IDs. nil clears registration; it is not an unfiltered scan.
        var eventOptions: [CBConnectionEventMatchingOption: Any] = [
            .serviceUUIDs: [CBUUID(string: "180A"), CBUUID(string: "180F")]
        ]
        if let text = defaults.string(forKey: rememberedKey), let id = UUID(uuidString: text) {
            eventOptions[.peripheralUUIDs] = [id]
            for peripheral in central.retrievePeripherals(withIdentifiers: [id]) {
                record(peripheral, source: "Remembered selection")
            }
        }
        central.registerForConnectionEvents(options: eventOptions)
        for peripheral in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: "180A"), CBUUID(string: "180F")]) {
            record(peripheral, source: "Connected standard GATT service")
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        log("Started a 12-second scan; listening for Classic GATT connection events too.")
        armTimer(seconds: 12) { [weak self] in
            guard let self, self.phase == .scanning else { return }
            self.central?.stopScan()
            self.central?.registerForConnectionEvents(options: nil)
            self.scanRequested = false
            self.phase = .idle
            self.message = self.nearby.isEmpty
                ? "No devices appeared. Connect your QC in iPhone Bluetooth settings and try again."
                : "Scan finished. Choose your QC below. If it was renamed, enable Show all devices."
            self.log("Scan finished with \(self.nearby.count) visible candidates. No control connection has been proven.")
        }
    }

    func connect(to device: NearbyDevice) {
        guard let central, central.state == .poweredOn, let peripheral = peripherals[device.id] else { return }
        stopConnection()
        scanRequested = false
        report.selectedPeripheral = .init(identifier: device.id, name: device.name,
                                          advertisedServices: device.advertisedServices, discoverySource: device.source)
        // Clear evidence from an earlier selected peripheral in this inspection.
        report.proof = ControlProof()
        activePeripheral = peripheral
        peripheral.delegate = self
        phase = .connecting
        message = "Connecting to \(device.name)…"
        log("Connecting to selected candidate \(device.name). Its display name is not verified identity.")
        armTimer(seconds: 10) { [weak self] in self?.fail("The connection timed out. Check that the QC is on and connected in iPhone Bluetooth settings.") }
        central.connect(peripheral, options: nil)
    }

    func cancel() {
        guard phase.isBusy else { return }
        stopConnection()
        scanRequested = false
        phase = .idle
        message = "Inspection stopped. You can check the connection again."
        log("Inspection cancelled; Bluetooth scan and connection closed.")
    }

    func pauseForBackground() {
        guard phase.isBusy else { return }
        cancel()
        message = "Inspection paused while the app was in the background. Tap Check connection to restart."
    }

    func refreshAccessories(save: Bool = true) {
        report.accessories = EAAccessoryManager.shared().connectedAccessories.map {
            .init(id: $0.connectionID, name: $0.name, manufacturer: $0.manufacturer,
                  model: $0.modelNumber, firmware: $0.firmwareRevision, exposedProtocols: $0.protocolStrings)
        }
        if save { log("Refreshed accessory information visible to this app (\(report.accessories.count) accessories).") }
    }

    func exportDocument() throws -> ProbeReportDocument { .init(data: try report.json()) }

    private func record(_ peripheral: CBPeripheral, name: String? = nil, rssi: Int? = nil,
                        services: [String] = [], source: String) {
        peripherals[peripheral.identifier] = peripheral
        if let index = nearby.firstIndex(where: { $0.id == peripheral.identifier }) {
            if let name, !name.isEmpty { nearby[index].name = name }
            if let rssi { nearby[index].rssi = rssi }
            if !services.isEmpty { nearby[index].advertisedServices = services }
        } else {
            nearby.append(.init(id: peripheral.identifier, name: name ?? peripheral.name ?? "Unnamed device",
                                rssi: rssi, advertisedServices: services, source: source))
        }
    }

    private func updateAvailability() {
        guard let central else { return }
        switch central.state {
        case .poweredOn:
            if scanRequested { beginScan() }
        case .unknown:
            message = "Allow Bluetooth access when iOS asks, or tap Stop check to cancel."
        case .resetting:
            message = "Waiting for Bluetooth to become ready…"
            armTimer(seconds: 10) { [weak self] in
                self?.fail("Bluetooth did not become ready. Check Bluetooth settings and try again.")
            }
        case .poweredOff:
            unavailable("Bluetooth is off. Turn it on in iPhone Settings and retry.")
        case .unauthorized:
            unavailable("Bluetooth permission is off. Open QuietControl settings, allow Bluetooth, then retry.")
        case .unsupported:
            unavailable("Bluetooth discovery is unavailable on this device. Use your physical iPhone for this check.")
        @unknown default:
            unavailable("Bluetooth is unavailable. Check iPhone Settings and retry.")
        }
    }

    private func unavailable(_ text: String) {
        stopConnection()
        scanRequested = false
        phase = .unavailable
        message = text
        log(text)
    }

    private func fail(_ text: String) {
        stopConnection()
        scanRequested = false
        phase = .failed
        message = text
        log(text)
    }

    private func armTimer(seconds: TimeInterval, action: @escaping () -> Void) {
        operationTimer?.cancel()
        let timer = DispatchWorkItem(block: action)
        operationTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    private func stopConnection() {
        operationTimer?.cancel(); operationTimer = nil
        readTimer?.cancel(); readTimer = nil
        if central?.state == .poweredOn {
            central?.stopScan()
            central?.registerForConnectionEvents(options: nil)
        }
        if let peripheral = activePeripheral {
            peripheral.delegate = nil
            activePeripheral = nil
            if central?.state == .poweredOn { central?.cancelPeripheralConnection(peripheral) }
        }
        pendingServices.removeAll()
        serviceIndices.removeAll()
        characteristicLocations.removeAll()
        reads.removeAll()
        currentRead = nil
    }

    private func log(_ text: String) {
        report.updatedAt = Date()
        report.inspectionStatus = phase.rawValue
        report.events.append(.init(date: Date(), message: text))
        if report.events.count > 200 { report.events.removeFirst(report.events.count - 200) }
        persistReport()
    }

    private func persistReport() {
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            var destination = directory.appendingPathComponent("LatestProbe.json")
            try report.json().write(to: destination, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try destination.setResourceValues(values)
            persistenceError = nil
        } catch {
            persistenceError = "The report could not be saved: \(error.localizedDescription)"
        }
    }

    private func finishInspection() {
        let serviceCount = report.selectedPeripheral?.services.count ?? 0
        phase = .complete
        message = serviceCount == 0
            ? "The QC connection exposed no GATT services to this app. Export the report to investigate the connection route."
            : "Inspection complete. Tap Done to connect to your selected QC."
        log("Inspection complete: \(serviceCount) GATT services. Direct mode and EQ control remain unproven. Disconnecting the inspection session.")
        stopConnection()
    }

    private func readNext() {
        guard let peripheral = activePeripheral, currentRead == nil else { return }
        guard !reads.isEmpty else { finishInspection(); return }
        phase = .reading
        let characteristic = reads.removeFirst()
        currentRead = characteristic
        peripheral.readValue(for: characteristic)
        let timer = DispatchWorkItem { [weak self, weak characteristic] in
            guard let self, let characteristic, self.currentRead === characteristic else { return }
            self.log("Standard metadata read \(characteristic.uuid.uuidString) timed out; continuing inventory.")
            self.currentRead = nil
            self.readNext()
        }
        readTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
    }

    private func permittedMetadataRead(_ characteristic: CBCharacteristic, service: CBService) -> Bool {
        guard characteristic.properties.contains(.read) else { return false }
        if service.uuid == CBUUID(string: "180F") { return characteristic.uuid == CBUUID(string: "2A19") }
        guard service.uuid == CBUUID(string: "180A") else { return false }
        // Deliberately omit serial numbers and all manufacturer-specific reads.
        return ["2A24", "2A26", "2A28", "2A29", "2A50"].map(CBUUID.init(string:)).contains(characteristic.uuid)
    }

    private func properties(_ value: CBCharacteristicProperties) -> [String] {
        let choices: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"), (.indicate, "indicate"), (.broadcast, "broadcast"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"), (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"), (.indicateEncryptionRequired, "indicateEncryptionRequired")
        ]
        return choices.compactMap { value.contains($0.0) ? $0.1 : nil }
    }

    private func interpret(_ data: Data, characteristic: CBCharacteristic) -> String {
        let bytes = [UInt8](data)
        switch characteristic.uuid.uuidString.uppercased() {
        case "2A19":
            if bytes.count == 1, bytes[0] <= 100 {
                report.proof.standardBatteryRead = true
                return "\(bytes[0])%"
            }
        case "2A50":
            if bytes.count == 4, bytes[0] == 1, bytes[1] == 0x9e, bytes[2] == 0 {
                if report.selectedPeripheral?.standardReadings["2A29"] == "Bose Corporation",
                   report.selectedPeripheral?.standardReadings["2A24"]?.hasPrefix("884367-") == true {
                    report.selectedPeripheral?.identityEvidence = "Bose QuietComfort model family confirmed by manufacturer and model number. This firmware reports an abbreviated Bluetooth product identity."
                }
                return String(format: "Bose vendor 0x009E, abbreviated product byte 0x%02X", bytes[3])
            }
            if bytes.count == 7 {
                let vendor = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
                let product = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
                let detail = String(format: "Source %d, vendor 0x%04X, product 0x%04X", bytes[0], vendor, product)
                report.selectedPeripheral?.identityEvidence = product == PrinceProtocol.productID
                    ? "PnP product ID matches prince (0x4075). Verify the manufacturer and firmware too."
                    : "PnP product ID does not match the expected prince product ID (0x4075). \(detail)"
                return detail
            }
        case "2A24", "2A26", "2A28", "2A29":
            if let value = String(data: data, encoding: .utf8) {
                return String(value.trimmingCharacters(in: .controlCharacters).prefix(256))
            }
        default: break
        }
        return "Unexpected metadata format (\(data.count) bytes)"
    }
}

extension BluetoothProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateAvailability() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning else { return }
        let primary = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let serviceDataKeys = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]).map { Array($0.keys) } ?? []
        let services = Array(Set((primary + overflow + serviceDataKeys).map(\.uuidString))).sorted()
        record(peripheral, name: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
               rssi: RSSI.intValue == 127 ? nil : RSSI.intValue, services: services, source: "Bluetooth advertisement")
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent,
                        for peripheral: CBPeripheral) {
        guard phase == .scanning, event == .peerConnected else { return }
        record(peripheral, source: "CoreBluetooth connection event (may be GATT over Classic)")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard activePeripheral === peripheral, phase == .connecting else { return }
        defaults.set(peripheral.identifier.uuidString, forKey: rememberedKey)
        phase = .discovering
        message = "Inspecting the services exposed by \(peripheral.name ?? "your QC")…"
        log("Connected through CoreBluetooth. Enumerating GATT services; RFCOMM access has not been established.")
        armTimer(seconds: 25) { [weak self] in self?.fail("Service inspection timed out. Export the partial report and try again.") }
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard activePeripheral === peripheral else { return }
        fail("Could not connect: \(error?.localizedDescription ?? "The headphones did not accept the connection.")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard activePeripheral === peripheral else { return }
        fail("The headphones disconnected during inspection. \(error?.localizedDescription ?? "Turn them on and retry.")")
    }
}

extension BluetoothProbe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard activePeripheral === peripheral else { return }
        if let error { fail("Service discovery failed: \(error.localizedDescription)"); return }
        let services = peripheral.services ?? []
        report.selectedPeripheral?.services = services.enumerated().map {
            .init(id: "\($0.offset)-\($0.element.uuid.uuidString)", uuid: $0.element.uuid.uuidString, primary: $0.element.isPrimary)
        }
        for (index, service) in services.enumerated() {
            serviceIndices[ObjectIdentifier(service)] = index
            pendingServices.insert(ObjectIdentifier(service))
        }
        log("Discovered \(services.count) GATT services.")
        if services.isEmpty { finishInspection(); return }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard activePeripheral === peripheral, let serviceIndex = serviceIndices[ObjectIdentifier(service)] else { return }
        pendingServices.remove(ObjectIdentifier(service))
        if let error {
            report.selectedPeripheral?.services[serviceIndex].discoveryError = error.localizedDescription
            log("Characteristics unavailable for \(service.uuid.uuidString): \(error.localizedDescription)")
        } else {
            let characteristics = service.characteristics ?? []
            report.selectedPeripheral?.services[serviceIndex].characteristics = characteristics.enumerated().map {
                .init(id: "\(serviceIndex)-\($0.offset)-\($0.element.uuid.uuidString)",
                      uuid: $0.element.uuid.uuidString, properties: properties($0.element.properties))
            }
            for (index, characteristic) in characteristics.enumerated() {
                characteristicLocations[ObjectIdentifier(characteristic)] = (serviceIndex, index)
                if permittedMetadataRead(characteristic, service: service) { reads.append(characteristic) }
            }
            log("Inventoried \(characteristics.count) characteristics in \(service.uuid.uuidString).")
        }
        if pendingServices.isEmpty { readNext() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard activePeripheral === peripheral, currentRead === characteristic,
              let location = characteristicLocations[ObjectIdentifier(characteristic)] else { return }
        readTimer?.cancel(); readTimer = nil
        if let error {
            log("Standard metadata \(characteristic.uuid.uuidString) could not be read: \(error.localizedDescription)")
        } else if let value = characteristic.value {
            let text = interpret(value, characteristic: characteristic)
            report.selectedPeripheral?.services[location.0].characteristics[location.1].valueHex = value.hexString
            report.selectedPeripheral?.services[location.0].characteristics[location.1].reading = text
            report.selectedPeripheral?.standardReadings[characteristic.uuid.uuidString] = text
            log("Read standard metadata \(characteristic.uuid.uuidString): \(text)")
        }
        currentRead = nil
        readNext()
    }
}
