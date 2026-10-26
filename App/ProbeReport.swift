import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProbeEvent: Encodable, Identifiable {
    var id = UUID()
    let date: Date
    let message: String
}

struct CharacteristicReport: Encodable, Identifiable {
    let id: String
    let uuid: String
    let properties: [String]
    var valueHex: String?
    var reading: String?
}

struct ServiceReport: Encodable, Identifiable {
    let id: String
    let uuid: String
    let primary: Bool
    var characteristics: [CharacteristicReport] = []
    var discoveryError: String?
}

struct PeripheralReport: Encodable {
    let identifier: UUID
    let name: String
    let advertisedServices: [String]
    let discoverySource: String
    var identityEvidence = "Model has not been verified by the device. Its display name is not proof of model."
    var services: [ServiceReport] = []
    var standardReadings: [String: String] = [:]
}

struct AccessoryReport: Encodable, Identifiable {
    let id: Int
    let name: String
    let manufacturer: String
    let model: String
    let firmware: String
    let exposedProtocols: [String]
}

struct ControlProof: Encodable {
    var standardBatteryRead = false
    let currentModeRead = false
    let eqRead = false
    let quietAwareSwitchConfirmed = false
    let eqChangeAndRestoreConfirmed = false
    let directControlProven = false
    let status = "This discovery report inventories services only. See ControlProof.json and DeviceControlProof.json for explicit hardware checks."
}

struct ProbeReport: Encodable {
    var schemaVersion = 1
    var startedAt = Date()
    var updatedAt = Date()
    var appVersion = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))"
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var inspectionStatus = "Not started"
    let upstreamCommit = "70570b29c1d3c9ba775b08a29eaea72385de27b5"
    let targetModel = "Bose QuietComfort Headphones / prince / 0x4075"
    let accessScope = "Public CoreBluetooth discovery and standard metadata reads only. Unknown characteristics are inventoried, not read or written. No command endpoint is assumed."
    let transportCaveat = "CoreBluetooth can expose BLE and GATT over BR/EDR. Discovery alone does not prove RFCOMM or BMAP access. External Accessory results include only accessories/protocols visible to this signed app; an empty list is inconclusive."
    let classicEventFilters = "GATT services 180A and 180F, plus the previously selected peripheral ID when available. Unknown proprietary-only Classic GATT services may require a filter identified from an official-app capture."
    var selectedPeripheral: PeripheralReport?
    var accessories: [AccessoryReport] = []
    var proof = ControlProof()
    var events: [ProbeEvent] = []

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

struct ProbeReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

