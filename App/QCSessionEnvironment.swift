import Foundation

/// Timing seams for the session. Production values are unchanged; tests may tighten
/// retry/pacing values without disabling the real confirmation logic.
struct QCSessionTiming {
    var requestSpacing: TimeInterval = 0.2
    var commandTimeout: TimeInterval = 3
    var optionalActionTimeout: TimeInterval = 0.35
    var modeConfirmationAttempts = 5
    var modeConfirmationDelay: TimeInterval = 0.2
    var snapshotDebounce: TimeInterval = 0.5
    var modeDrainDelay: TimeInterval = 0.5
    var connectingPresentationDelay: TimeInterval = 8
    var deviceRefreshDelay: TimeInterval = 0.3
    var refreshPollInterval: TimeInterval = 0.02

    static let production = QCSessionTiming()
}

enum QCEnvironmentLoad {
    case ready(QCSessionEnvironment)
    case invalidConfiguration(String)
}

/// Owns UserDefaults, snapshot/document/report roots and the transport factory.
/// Production uses the standard suite and the existing paths; the simulator test
/// harness swaps in an isolated suite and synthetic peripheral before any session
/// or probe is constructed.
@MainActor
final class QCSessionEnvironment {
    let defaults: UserDefaults
    let documentsDirectory: URL
    let reportsDirectory: URL
    let snapshotURL: URL
    let timing: QCSessionTiming
    #if DEBUG && targetEnvironment(simulator)
    let harness: QCTestHarness?
    #endif
    private let transportFactory: () -> QCByteTransport

    var isTestMode: Bool {
        #if DEBUG && targetEnvironment(simulator)
        return harness != nil
        #else
        return false
        #endif
    }

    init(defaults: UserDefaults, documentsDirectory: URL, reportsDirectory: URL,
         snapshotURL: URL, timing: QCSessionTiming = .production,
         transportFactory: @escaping () -> QCByteTransport) {
        self.defaults = defaults
        self.documentsDirectory = documentsDirectory
        self.reportsDirectory = reportsDirectory
        self.snapshotURL = snapshotURL
        self.timing = timing
        self.transportFactory = transportFactory
        #if DEBUG && targetEnvironment(simulator)
        harness = nil
        #endif
    }

    func makeTransport() -> QCByteTransport { transportFactory() }

    static var production: QCSessionEnvironment {
        let fileManager = FileManager.default
        let documents = (try? fileManager.url(for: .documentDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true))
            ?? fileManager.temporaryDirectory
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: false))
            ?? documents
        return QCSessionEnvironment(
            defaults: .standard,
            documentsDirectory: documents,
            reportsDirectory: documents,
            snapshotURL: support.appendingPathComponent("QuietControl/LastConfirmedState.json"),
            transportFactory: { QCLiveByteTransport() })
    }

    /// Reads the stable test-configuration contract. Invalid configuration never
    /// falls back to production behaviour.
    static func load(arguments: [String] = ProcessInfo.processInfo.arguments,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> QCEnvironmentLoad {
        #if DEBUG && targetEnvironment(simulator)
        if arguments.contains("--quietcontrol-ui-testing") {
            do {
                let harness = try QCTestHarness(arguments: arguments, environment: environment)
                return .ready(QCSessionEnvironment(harness: harness))
            } catch {
                return .invalidConfiguration(error.localizedDescription)
            }
        }
        #endif
        return .ready(.production)
    }

    #if DEBUG && targetEnvironment(simulator)
    static func testEnvironment(scenario: QCTestScenario, runID: String, reset: Bool) throws -> QCSessionEnvironment {
        let harness = try QCTestHarness(arguments: ["--quietcontrol-ui-testing"], environment: [
            "QUIETCONTROL_TEST_RUN_ID": runID,
            "QUIETCONTROL_TEST_SCENARIO": scenario.rawValue,
            "QUIETCONTROL_TEST_RESET": reset ? "1" : "0"
        ])
        return QCSessionEnvironment(harness: harness)
    }

    private init(harness: QCTestHarness) {
        self.defaults = harness.defaults
        documentsDirectory = harness.filesDirectory
        reportsDirectory = harness.filesDirectory
        snapshotURL = harness.snapshotURL
        timing = harness.timing
        transportFactory = { harness.makeTransport() }
        self.harness = harness
    }
    #endif
}

#if DEBUG && targetEnvironment(simulator)
enum QCTestScenario: String, CaseIterable {
    case connected
    case modeRejected = "mode-rejected"
    case modeUnconfirmed = "mode-unconfirmed"
    case offlineCached = "offline-cached"
}

enum QCTestConfigurationError: LocalizedError {
    case missingRunID, invalidRunID, missingScenario, unknownScenario(String)
    var errorDescription: String? {
        switch self {
        case .missingRunID: return "QUIETCONTROL_TEST_RUN_ID is required for UI testing."
        case .invalidRunID: return "QUIETCONTROL_TEST_RUN_ID must be 1-64 ASCII letters, digits or hyphens."
        case .missingScenario: return "QUIETCONTROL_TEST_SCENARIO is required for UI testing."
        case .unknownScenario(let value): return "Unsupported QUIETCONTROL_TEST_SCENARIO: \(value)."
        }
    }
}

struct QCTestConfiguration {
    let scenario: QCTestScenario
    let runID: String
    let reset: Bool
    let defaultsSuite: String
    let filesDirectory: URL

    init(arguments: [String], environment: [String: String]) throws {
        guard let runID = environment["QUIETCONTROL_TEST_RUN_ID"], !runID.isEmpty else {
            throw QCTestConfigurationError.missingRunID
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        guard runID.count <= 64, runID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw QCTestConfigurationError.invalidRunID
        }
        guard let scenarioText = environment["QUIETCONTROL_TEST_SCENARIO"], !scenarioText.isEmpty else {
            throw QCTestConfigurationError.missingScenario
        }
        guard let scenario = QCTestScenario(rawValue: scenarioText) else {
            throw QCTestConfigurationError.unknownScenario(scenarioText)
        }
        self.scenario = scenario
        self.runID = runID
        reset = environment["QUIETCONTROL_TEST_RESET"] == "1"
        defaultsSuite = "uk.co.mzbali.quietcontrol.ui-tests.\(runID)"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        filesDirectory = support.appendingPathComponent("QuietControlUITests/\(runID)", isDirectory: true)
    }
}

struct QCSimulatedPeripheralState: Encodable {
    let scenario: String
    let runID: String
    let connected: Bool
    let mode: UInt8
    let eq: [Int]
    let multipoint: Bool
    let devices: [Device]
    let updatedAt: Date

    struct Device: Encodable {
        let address: String
        let name: String
        let connected: Bool
    }
}

@MainActor
final class QCTestEvidence {
    private struct Record: Encodable {
        let sequence: Int
        let timestamp: Date
        let direction: String
        let kind: String
        let bytes: String
        let message: String?
        let scenario: String
        let peripheral: String
        let connection: String
    }

    let transcriptionURL: URL
    let stateURL: URL
    private let scenario: String
    private let peripheral: String
    private var records: [Record] = []
    private var sequence = 0

    init(filesDirectory: URL, scenario: String, peripheral: String) throws {
        self.scenario = scenario
        self.peripheral = peripheral
        transcriptionURL = filesDirectory.appendingPathComponent("transport.jsonl")
        stateURL = filesDirectory.appendingPathComponent("peripheral-state.json")
        if !FileManager.default.fileExists(atPath: transcriptionURL.path) {
            FileManager.default.createFile(atPath: transcriptionURL.path, contents: nil)
        } else if let existing = try? String(contentsOf: transcriptionURL, encoding: .utf8) {
            // Relaunches sharing a run ID continue the monotonic transcript sequence.
            sequence = existing.split(separator: "\n").count
        }
    }

    func record(direction: String, kind: String, bytes: Data, message: String? = nil) {
        sequence += 1
        let record = Record(sequence: sequence, timestamp: Date(), direction: direction, kind: kind,
                            bytes: bytes.hexString, message: message, scenario: scenario,
                            peripheral: peripheral, connection: "simulated")
        records.append(record)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0a)
        guard let handle = try? FileHandle(forWritingTo: transcriptionURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    }

    func event(_ message: String) {
        record(direction: "event", kind: "event", bytes: Data(), message: message)
    }

    func writePeripheralState(_ state: QCSimulatedPeripheralState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    /// Compact human-readable mirror for the in-app diagnostics export. The file
    /// above remains the authoritative transcript.
    var transcriptText: String {
        records.map { record in
            let byteText = record.bytes.isEmpty ? "" : record.bytes.replacingOccurrences(of: " ", with: "")
            let suffix = record.message.map { " \($0)" } ?? ""
            return "#\(record.sequence) \(record.direction) \(record.kind) \(byteText)\(suffix)"
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    /// Short evidence string for the mode journey: the literal select-mode write,
    /// its immediate reply, the following independent GET and the GET's reply.
    /// UI tests assert these exact packets rather than trusting fixture state alone.
    var modeSwitchEvidence: String? {
        let lines = transcriptText.components(separatedBy: "\n")
        guard let write = lines.lastIndex(where: { $0.contains(" outbound bmap 1f0305020100") }) else { return nil }
        var parts = ["tx=\(packetToken(lines[write]))"]
        if let reply = lines[write...].firstIndex(where: { $0.contains(" inbound bmap ") }) {
            parts.append("reply=\(packetToken(lines[reply]))")
        }
        guard let get = lines[write...].firstIndex(where: { $0.contains(" outbound bmap 1f030100") }) else {
            return parts.joined(separator: ";")
        }
        parts.append("get=\(packetToken(lines[get]))")
        if let reply = lines[get...].firstIndex(where: { $0.contains(" inbound bmap ") }) {
            parts.append("getReply=\(packetToken(lines[reply]))")
        }
        return parts.joined(separator: ";")
    }

    private func packetToken(_ line: String) -> String {
        line.split(separator: " ").last.map(String.init) ?? ""
    }
}

@MainActor
final class QCTestHarness {
    static let peripheralID = UUID(uuidString: "8A1B2C3D-4E5F-4061-8273-849506172839")!
    static let rememberedKey = "quietcontrol.lastPeripheral"

    let configuration: QCTestConfiguration
    let defaults: UserDefaults
    let filesDirectory: URL
    let snapshotURL: URL
    let evidence: QCTestEvidence
    let timing = QCSessionTiming(requestSpacing: 0.005, commandTimeout: 3,
                                 optionalActionTimeout: 0.35, modeConfirmationAttempts: 5,
                                 modeConfirmationDelay: 0.05, snapshotDebounce: 0.05,
                                 modeDrainDelay: 0.1, connectingPresentationDelay: 8,
                                 deviceRefreshDelay: 0.05, refreshPollInterval: 0.01)

    init(arguments: [String], environment: [String: String]) throws {
        configuration = try QCTestConfiguration(arguments: arguments, environment: environment)
        filesDirectory = configuration.filesDirectory
        guard let defaults = UserDefaults(suiteName: configuration.defaultsSuite) else {
            throw QCTestConfigurationError.invalidRunID
        }
        self.defaults = defaults
        snapshotURL = filesDirectory.appendingPathComponent("LastConfirmedState.json")
        if configuration.reset {
            if FileManager.default.fileExists(atPath: filesDirectory.path) {
                try FileManager.default.removeItem(at: filesDirectory)
            }
            defaults.removePersistentDomain(forName: configuration.defaultsSuite)
        }
        try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        if defaults.string(forKey: Self.rememberedKey) == nil {
            defaults.set(Self.peripheralID.uuidString, forKey: Self.rememberedKey)
            defaults.set(true, forKey: "quietcontrol.autoConnect")
        }
        // Synthetic starting capability: this fixture represents a QC already
        // verified by an earlier session. The firmware/capability gates remain.
        let proofKey = "quietcontrol.verified.\(Self.peripheralID.uuidString).884367-0100.1.0.6-80+f5f219b"
        defaults.set(true, forKey: proofKey)
        defaults.set(true, forKey: "\(proofKey).devices.connect")
        defaults.set(true, forKey: "\(proofKey).devices.all")
        defaults.set(true, forKey: "\(proofKey).devices.multipoint")
        evidence = try QCTestEvidence(filesDirectory: filesDirectory,
                                      scenario: configuration.scenario.rawValue,
                                      peripheral: Self.peripheralID.uuidString)
        let config: [String: Any] = ["scenario": configuration.scenario.rawValue,
                                     "runID": configuration.runID,
                                     "reset": configuration.reset,
                                     "peripheral": Self.peripheralID.uuidString,
                                     "defaultsSuite": configuration.defaultsSuite]
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            _ = try? data.write(to: filesDirectory.appendingPathComponent("test-config.json"), options: .atomic)
        }
        evidence.event("Configured \(configuration.scenario.rawValue) for run \(configuration.runID).")
    }

    func makeTransport() -> QCByteTransport {
        QCSimulatorPeripheral(scenario: configuration.scenario,
                              runID: configuration.runID,
                              defaults: defaults,
                              evidence: evidence,
                              peripheralID: Self.peripheralID)
    }
}
#endif
