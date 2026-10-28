import Combine
@preconcurrency import CoreBluetooth
import Foundation
import UIKit

struct QCFeedback: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let symbol: String
    var isError = false
    /// A swap that can be reversed from the toast: reconnect `restore` in place of `replacing`.
    var undo: (restore: Data, replacing: Data)? = nil
    static func == (lhs: QCFeedback, rhs: QCFeedback) -> Bool { lhs.id == rhs.id }
}

enum QCSessionError: LocalizedError {
    case unavailable(String), timedOut(String), unexpected(String), disconnected
    var errorDescription: String? {
        switch self {
        case .unavailable(let text), .timedOut(let text), .unexpected(let text): return text
        case .disconnected: return "The headphones disconnected. Reconnect to continue."
        }
    }
}

struct ControlVerificationReport: Encodable {
    var date = Date()
    var appVersion = "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))"
    var model = ""
    var manufacturer = ""
    var firmware = ""
    var characteristic = ""
    var battery: Int?
    var initialMode: UInt8?
    var initialEQ: [Int] = []
    var finalMode: UInt8?
    var finalEQ: [Int] = []
    var modesRead = false
    var quietConfirmed = false
    var awareConfirmed = false
    var eqChangeConfirmed = false
    var restorationConfirmed = false
    var directControlProven = false
    var failure: String?
    var events: [ProbeEvent] = []
}

private struct RecoveryCheckpoint: Codable {
    let peripheral: UUID
    let mode: UInt8
    let bass: Int
}

private struct PreferenceRecovery: Codable {
    let peripheral: UUID
    let firmware: String
    let name: String
    let payload: Data
}

private struct ModeEditRecovery: Codable {
    let peripheral: UUID
    let firmware: String
    let original: ListeningMode
}

private struct DeviceRecoveryCheckpoint: Codable {
    let peripheral: UUID
    let firmware: String
    let connected: [Data]
    let source: Data?
    let multipoint: Bool
}

struct DeviceVerificationReport: Encodable {
    var date = Date()
    var model = ""
    var firmware = ""
    var connectDisconnect = false
    var disconnectAll = false
    var routing = false
    var multipoint = false
    var restorationConfirmed = false
    var failure: String?
    var limitations: [String] = []
}

/// Public CoreBluetooth transport for the exact FEBE endpoints observed on the
/// user's QC. Wire framing: NerdySouth/bozo; prince commands: aaronsb/bosectl.
@MainActor
final class QuietComfortSession: NSObject, ObservableObject {
    private(set) var environment: QCSessionEnvironment
    @Published private(set) var isConnected = false
    @Published private(set) var isWorking = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isUserCommandPending = false
    var controlsBusy: Bool { isUserCommandPending || (isWorking && !isRefreshing) }
    @Published private(set) var isVerifying = false
    @Published private(set) var message = "Ready to check direct control on your QuietComfort."
    @Published private(set) var failure: String?
    @Published private(set) var model = ""
    @Published private(set) var firmware = ""
    @Published private(set) var battery: Int?
    @Published private(set) var mode: UInt8?
    @Published private(set) var modes: [ListeningMode] = []
    @Published private(set) var eq: [EQSetting] = []
    @Published private(set) var proof = ControlVerificationReport()
    @Published private(set) var hasVerifiedDirectControl = false
    @Published private(set) var manufacturer = ""
    @Published private(set) var connectionTime: TimeInterval?

    @Published private(set) var devices: [PairedAudioDevice] = []
    @Published private(set) var activeAudioAddress: Data?
    @Published private(set) var multipoint: Bool?
    @Published private(set) var deviceListFailure: String?
    @Published private(set) var deviceControlsVerified = false
    @Published private(set) var routingVerified = false
    @Published private(set) var multipointVerified = false
    @Published private(set) var disconnectAllVerified = false
    @Published private(set) var pendingDevice: Data?
    @Published private(set) var controllerAddress: Data?
    @Published private(set) var deviceVerification = DeviceVerificationReport()
    @Published private(set) var connectionState: QCConnectionState = .setupRequired
    @Published private(set) var lastConfirmedAt: Date?
    @Published private(set) var hasSavedProfile = false
    @Published private(set) var toast: QCFeedback?
    @Published private(set) var hasLiveDeviceList = false
    @Published private(set) var preferencePackets: [String: Data] = [:]
    @Published private(set) var preferencesFailure: String?
    @Published private(set) var modeEditingVerified = false
    @Published private(set) var verifiedPreferences: Set<String> = []
    var hasKnownProfile: Bool { hasSavedProfile || isConnected }
    var autoConnectEnabled: Bool { lifecycle.wantsConnection }
    var hasRememberedDevice: Bool { (isPreview && hasSavedProfile) || environment.defaults.string(forKey: "quietcontrol.lastPeripheral") != nil }
    /// Narrow export for simulator UI tests: the fixture transcript is nil in Release.
    var testTranscript: String? {
        #if DEBUG && targetEnvironment(simulator)
        return environment.harness?.evidence.transcriptText
        #else
        return nil
        #endif
    }
    /// Literal select-mode write, independent GET and reply for UI assertions.
    var testModeEvidence: String? {
        #if DEBUG && targetEnvironment(simulator)
        return environment.harness?.evidence.modeSwitchEvidence
        #else
        return nil
        #endif
    }
    private var lastContactAt: Date?
    private var isEstablishing = false
    private var isInspecting = false
    private var presentationTimer: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var isVerifyingModeEQ = false
    private var editingEQ = false
    private var isPreview = false
    private var launchChecksStarted = SessionActionGate()
    private var restorationGate = SessionActionGate()
    private var deviceRefreshTask: Task<Void, Never>?
    private var devicesNeedRefresh = false

    private var lifecycle = ConnectionPolicy()
    private var reconnectTask: Task<Void, Never>?
    private var isRestoring = false
    private var transport: QCByteTransport?
    private var controlEndpoint: QCTransportEndpoint?
    private var peripheralIdentity: UUID?
    private var reassembler = BoseBLEReassembler()
    private var outgoing: [Data] = []
    private var writeInProgress = false
    private var lastSent = Date.distantPast
    private var operationID = UUID()
    private var commandWaiter: CheckedContinuation<[BMAPFrame], Error>?
    private var commandTimer: Task<Void, Never>?
    private var drainTimer: Task<Void, Never>?
    private var expectedBlock: UInt8 = 0
    private var expectedFunction: UInt8 = 0
    private var expectedOperations: [BMAPOperator] = []
    private var collectingModes = false
    private var replies: [BMAPFrame] = []
    private var commandStarted = Date()
    private var optionalActionReply = false
    private var needsResynchronization = false

    override init() {
        environment = .production
        super.init()
        finishInitialization()
    }

    init(environment: QCSessionEnvironment) {
        self.environment = environment
        super.init()
        finishInitialization()
    }

    private func finishInitialization() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--preview-controls") {
            loadPreview(); return
        }
        #endif
        let enabled = environment.defaults.object(forKey: "quietcontrol.autoConnect") as? Bool ?? true
        lifecycle = ConnectionPolicy(wantsConnection: enabled, hasRememberedDevice: hasRememberedDevice)
        connectionState = lifecycle.state
        restoreCachedProfile()
        log("App launched; auto-connect \(enabled ? "enabled" : "paused").")
        if hasRememberedDevice {
            let transport = environment.makeTransport()
            transport.delegate = self
            self.transport = transport
            transport.prepareRadio()
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    private func loadPreview() {
        isPreview = true
        lifecycle = ConnectionPolicy(hasRememberedDevice: true)
        connectionState = .connected; hasSavedProfile = true; hasLiveDeviceList = true
        lastConfirmedAt = Date(timeIntervalSince1970: 1_792_752_000)
        isConnected = true; hasVerifiedDirectControl = true; deviceControlsVerified = true
        routingVerified = false; multipointVerified = true; disconnectAllVerified = true
        battery = 90; mode = 0; multipoint = true; manufacturer = "Bose Corporation"; model = "884367-0100"
        firmware = "Preview"; message = "Preview"; modeEditingVerified = true
        preferencePackets = ["selfVoice": Data([1, 2, 15]), "voicePrompts": Data([0x81]), "shortcut": Data([0x80, 9, 3]),
                             "autoOff": Data([0]), "rememberMode": Data([1])]
        verifiedPreferences = ["selfVoice", "voicePrompts", "shortcut", "autoOff", "rememberMode"]
        eq = try! PrinceProtocol.eq(from: .init(block: 1, function: 7, operation: .status,
            payload: Data([0xf6, 10, 0xff, 0, 0xf6, 10, 4, 1, 0xf6, 10, 2, 2])))
        modes = [(UInt8(0), UInt8(1), "Quiet"), (1, 2, "Aware"), (2, 13, "Focus")].map { index, prompt, name in
            var bytes = [UInt8](repeating: 0, count: 47)
            bytes[0] = index; bytes[2] = prompt; bytes[4] = 1; bytes[3] = index > 1 ? 1 : 0; bytes[42] = index == 1 ? 10 : 0
            bytes.replaceSubrange(6..<6 + name.utf8.count, with: name.utf8)
            return try! PrinceProtocol.modeConfiguration(from: .init(block: 31, function: 6, operation: .status, payload: Data(bytes)))
        }
        devices = [("iPhone", UInt8(3)), ("MacBook Pro", 1), ("Work laptop", 0), ("Desktop", 0)].enumerated().map { offset, item in
            let address = Data([0, 1, 2, 3, 4, UInt8(offset)])
            return try! DeviceManagementProtocol.device(from: .init(block: 4, function: 5, operation: .status,
                payload: address + Data([item.1, 0, 0]) + Data(item.0.utf8)))
        }
        controllerAddress = devices[0].address; activeAudioAddress = devices[0].address
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--preview-toast") { toast = QCFeedback(text: "Quiet selected", symbol: "moon") }
        if args.contains("--preview-offline") { isConnected = false; hasLiveDeviceList = false; connectionState = .waitingForQC }
        if args.contains("--preview-connecting") { isConnected = false; hasLiveDeviceList = false; connectionState = .connecting }
        if args.contains("--preview-paused") { isConnected = false; hasLiveDeviceList = false; lifecycle.pause(); connectionState = .paused }
        if args.contains("--preview-permission") { isConnected = false; hasLiveDeviceList = false; connectionState = .permissionNeeded }
        if args.contains("--preview-first-run") { isConnected = false; hasLiveDeviceList = false; hasSavedProfile = false; modes = []; devices = []; eq = []; mode = nil; connectionState = .setupRequired }
    }
    #endif

    func setForeground(_ value: Bool) {
        guard !isPreview else { return }
        lifecycle.setForeground(value)
        if value {
            log("Foreground: control link \(isConnected ? "retained" : "unavailable"); pending \(lifecycle.hasPendingConnection).")
            if isConnected { Task { await self.refresh() } }
            else { startIfNeeded() }
        } else { log("Background: preserving control link and pending availability request.") }
    }

    func startIfNeeded() {
        guard !isPreview, !isInspecting, lifecycle.wantsConnection, hasRememberedDevice,
              !isConnected, !isEstablishing, !isWorking, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            self.reconnectTask = nil
            try? await self.establishRemembered()
        }
    }

    private func scheduleReconnect(immediate: Bool = false) {
        guard !isInspecting, lifecycle.wantsConnection, !isConnected, !isEstablishing, !isWorking,
              reconnectTask == nil, transport?.radioState == .poweredOn,
              connectionState != .unavailable, hasRememberedDevice,
              let delay = lifecycle.nextRetryDelay() else { return }
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((immediate ? 0 : delay) * 1_000_000_000)) }
            catch { return }
            guard let self else { return }
            self.reconnectTask = nil
            guard self.lifecycle.wantsConnection, !self.isInspecting else { return }
            try? await self.establishRemembered()
        }
    }

    func resumeAutoConnect() {
        lifecycle.resume()
        if !hasRememberedDevice { lifecycle.beginAttempt(hasRememberedDevice: false) }
        connectionState = lifecycle.state
        environment.defaults.set(true, forKey: "quietcontrol.autoConnect")
        log("Auto-connect resumed by user.")
        startIfNeeded()
    }

    func connectRemembered() async throws {
        lifecycle.resume(); connectionState = lifecycle.state
        environment.defaults.set(true, forKey: "quietcontrol.autoConnect")
        try await establishRemembered()
    }

    private func beginConnectingPresentation() {
        presentationTimer?.cancel()
        connectionState = .connecting
        let delay = environment.timing.connectingPresentationDelay
        presentationTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, !self.isConnected, self.lifecycle.wantsConnection else { return }
            self.lifecycle.settleWaiting(); self.connectionState = self.lifecycle.state
            if self.transport?.isWaitingForConnection == true { self.isWorking = false }
            self.log("Waiting quietly; the existing CoreBluetooth connection request remains pending.")
        }
    }

    private func establishRemembered() async throws {
        guard !isEstablishing, !isWorking, !isConnected, !isInspecting else { return }
        guard lifecycle.beginAttempt(hasRememberedDevice: hasRememberedDevice) else { connectionState = lifecycle.state; return }
        isEstablishing = true
        connectionState = lifecycle.state
        reconnectTask?.cancel(); reconnectTask = nil
        // Never cancel an existing pending or restored peripheral to refresh the UI.
        isRestoring = false
        let run = UUID(); operationID = run
        let started = Date()
        isWorking = true; failure = nil; message = "Connecting directly to your QC…"
        proof = ControlVerificationReport()
        beginConnectingPresentation()
        defer {
            if operationID == run {
                presentationTimer?.cancel(); presentationTimer = nil
                isEstablishing = false; isWorking = false
                if !isConnected { scheduleReconnect() }
            }
        }
        do {
            guard let id = environment.defaults.string(forKey: "quietcontrol.lastPeripheral").flatMap(UUID.init(uuidString:)) else {
                throw QCSessionError.unavailable("Run Connection inspection first and select your QC.")
            }
            guard let transport else { throw QCSessionError.unavailable("Bluetooth is not available.") }
            isWorking = true
            beginConnectingPresentation()
            let link = try await transport.connect(rememberedID: id)
            try requireRun(run)
            isWorking = true
            peripheralIdentity = link.identifier
            manufacturer = link.manufacturer
            model = link.model
            guard manufacturer == "Bose Corporation", model.hasPrefix("884367-") else {
                throw QCSessionError.unavailable("This build supports the verified QuietComfort 884367 model family. Reported: \(manufacturer), \(model).")
            }
            proof.model = model; proof.manufacturer = manufacturer
            guard !link.endpoints.isEmpty else { throw QCSessionError.unavailable("No documented Bose command characteristic is exposed.") }
            var transportFailure: Error = QCSessionError.unavailable("No control endpoint responded.")
            var established = false
            for candidate in link.endpoints {
                try requireRun(run)
                controlEndpoint = candidate; reassembler.reset(); outgoing.removeAll(); needsResynchronization = false
                do {
                    try await transport.enableNotifications(for: candidate)
                    try requireRun(run)
                    let response = try await request(PrinceProtocol.firmwareRequest())
                    let payload = try response[0].statusPayload(block: 0, function: 5)
                    guard let version = String(data: payload, encoding: .ascii), !version.isEmpty else { throw BMAPError.malformedPayload }
                    firmware = version.trimmingCharacters(in: .controlCharacters)
                    proof.firmware = firmware; proof.characteristic = candidate.id
                    log("BMAP firmware reply received on \(candidate.id): \(firmware)")
                    established = true; break
                } catch {
                    try requireRun(run)
                    transportFailure = error
                    log("Endpoint \(candidate.id) did not establish BMAP: \(error.localizedDescription)")
                    transport.disableNotifications(for: candidate)
                }
            }
            guard established else { throw transportFailure }
            try await readSnapshot(includeModes: true)
            guard modes.contains(where: { $0.index == 0 }), modes.contains(where: { $0.index == 1 }) else {
                throw QCSessionError.unexpected("The QC did not return both Quiet and Aware modes in the prince layout.")
            }
            if let checkpoint = try recoveryCheckpoint(), checkpoint.peripheral == id {
                message = "Restoring the settings from an interrupted connection check…"
                try await restore(checkpoint)
                try clearRecovery()
                log("Recovered original mode and bass from an interrupted proof check.")
            }
            if let url = try? documents("ModeEditRecovery.json"), let data = try? Data(contentsOf: url) {
                guard restorationGate.claim("mode") else { throw QCSessionError.unavailable("Automatic mode restoration stopped after one attempt. Reopen QuietControl to retry.") }
                let checkpoint = try JSONDecoder().decode(ModeEditRecovery.self, from: data)
                guard checkpoint.peripheral == id, checkpoint.firmware == firmware else { throw QCSessionError.unavailable("Mode restoration belongs to a different QC or firmware.") }
                try await writeModeConfirmed(checkpoint.original, strength: checkpoint.original.ancStrength, windBlock: checkpoint.original.windBlock)
                try clearModeEditRecovery()
            }
            if let url = try? documents("PreferenceRecovery.json"), let data = try? Data(contentsOf: url) {
                guard restorationGate.claim("preference") else { throw QCSessionError.unavailable("Automatic setting restoration stopped after one attempt. Reopen QuietControl to retry.") }
                let checkpoint = try JSONDecoder().decode(PreferenceRecovery.self, from: data)
                guard checkpoint.peripheral == id, checkpoint.firmware == firmware else { throw QCSessionError.unavailable("Preference restoration belongs to a different QC or firmware.") }
                try await writePreferenceConfirmed(checkpoint.name, payload: checkpoint.payload)
                environment.defaults.set(true, forKey: capabilityKey(checkpoint.name))
                try clearPreferenceRecovery()
            }
            verifiedPreferences = Set(["voicePrompts", "selfVoice", "shortcut"].filter { environment.defaults.bool(forKey: capabilityKey($0)) })
            if powerSettingsProven { verifiedPreferences.formUnion(["autoOff", "rememberMode"]) }
            isConnected = true
            lifecycle.connected(); connectionState = lifecycle.state
            presentationTimer?.cancel(); presentationTimer = nil
            connectionTime = Date().timeIntervalSince(started)
            hasVerifiedDirectControl = environment.defaults.bool(forKey: proofKey)
            message = "Connected directly. Battery, modes and EQ were read from your QC."
            log("\(message) Connection setup: \(Int((connectionTime ?? 0) * 1000)) ms.")
            do { try await readDevices() }
            catch {
                deviceListFailure = error.localizedDescription; log("Device list unavailable: \(error.localizedDescription)")
                if needsResynchronization { throw error }
            }
            if let checkpoint = try deviceRecoveryCheckpoint(), checkpoint.peripheral == link.identifier {
                guard checkpoint.firmware == firmware else { throw QCSessionError.unavailable("A device-connection recovery belongs to older firmware. Inspect DeviceRecovery.json before changing connections.") }
                try await restoreDeviceConnections(checkpoint)
                try clearDeviceRecovery()
                log("Recovered the audio connections from an interrupted device-control check.")
            }
            modeEditingVerified = environment.defaults.bool(forKey: capabilityKey("modeEditing"))
            loadDeviceCapabilities()
            persistSnapshot()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-mode-eq") {
                Task { while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }; await self.verifyDirectControl() }
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-device-management") {
                Task { while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }; await self.verifyDeviceControls() }
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-refresh-interaction") {
                Task {
                    while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }
                    await self.verifyRefreshInteraction()
                }
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--verify-preferences"), launchChecksStarted.claim("verify-preferences") {
                Task { while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }; await self.verifyPreferences() }
            }
            if ProcessInfo.processInfo.arguments.contains("--inspect-settings"), launchChecksStarted.claim("inspect-settings") {
                Task { while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }; await self.refreshPreferences() }
            }
            if ProcessInfo.processInfo.arguments.contains("--verify-mode-editing"), launchChecksStarted.claim("verify-mode-editing") {
                Task { while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }; await self.verifyModeEditing() }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-power-preferences"), launchChecksStarted.claim("verify-power-preferences") {
                Task { while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }; await self.verifyPowerPreferences() }
            }
            if ProcessInfo.processInfo.arguments.contains("--inspect-power-preferences"), launchChecksStarted.claim("inspect-power-preferences") {
                Task { while self.isWorking { try? await Task.sleep(nanoseconds: 100_000_000) }; await self.inspectPowerPreferences() }
            }
            #endif
            if ProcessInfo.processInfo.arguments.contains("--inspect-devices") { await inspectDeviceManagement() }
        } catch {
            guard operationID == run else { throw CancellationError() }
            failure = error.localizedDescription; message = "Could not establish direct control."
            proof.failure = failure; log("Connection failed: \(error.localizedDescription)")
            closeLink()
            if transport?.radioState == .poweredOff { lifecycle.radioUnavailable(.bluetoothOff) }
            else if transport?.radioState == .unauthorized { lifecycle.radioUnavailable(.permissionNeeded) }
            else if case QCSessionError.unavailable = error { lifecycle.radioUnavailable(.unavailable) }
            connectionState = lifecycle.state
            restoreCachedProfile()
            throw error
        }
    }

    private func readDevices() async throws {
        let addresses = try await DeviceManagementProtocol.addresses(from: request(DeviceManagementProtocol.listRequest())[0])
        var reported: [PairedAudioDevice] = []
        for address in addresses {
            reported.append(try await DeviceManagementProtocol.device(from: request(DeviceManagementProtocol.infoRequest(address))[0], expected: address))
        }
        let source = try await DeviceManagementProtocol.activeAddress(from: request(DeviceManagementProtocol.sourceRequest())[0])
        let multi = try await DeviceManagementProtocol.multipoint(from: request(DeviceManagementProtocol.multipointRequest())[0])
        devices = reported; activeAudioAddress = source; multipoint = multi; deviceListFailure = nil
        hasLiveDeviceList = true
        if let own = reported.first(where: \.isController) { controllerAddress = own.address }
        devicesNeedRefresh = false
        persistSnapshot()
        log("Device list: \(reported.count) paired, \(reported.filter(\.isConnected).count) connected; multipoint \(multi ? "on" : "off").")
    }

    private func capabilityKey(_ feature: String) -> String { "\(proofKey).devices.\(feature)" }
    private func loadDeviceCapabilities() {
        deviceControlsVerified = environment.defaults.bool(forKey: capabilityKey("connect"))
        disconnectAllVerified = environment.defaults.bool(forKey: capabilityKey("all"))
        routingVerified = environment.defaults.bool(forKey: capabilityKey("routing"))
        multipointVerified = environment.defaults.bool(forKey: capabilityKey("multipoint"))
    }

    private func scheduleDeviceRefresh() {
        guard deviceRefreshTask == nil, isConnected, !isWorking, !editingEQ else { return }
        let delay = environment.timing.deviceRefreshDelay
        deviceRefreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self else { return }
            self.deviceRefreshTask = nil
            guard self.isConnected, !self.isWorking else { return }
            await self.performUserCommand { try await self.readDevices() }
        }
    }

    private func setAudioConnectedConfirmed(_ address: Data, connected: Bool) async throws {
        _ = try await request(connected ? DeviceManagementProtocol.connect(address) : DeviceManagementProtocol.disconnect(address), optionalActionReply: true)
        for _ in 0..<12 {
            let device = try await DeviceManagementProtocol.device(from: request(DeviceManagementProtocol.infoRequest(address))[0], expected: address)
            if let index = devices.firstIndex(where: { $0.address == address }) { devices[index] = device }
            if device.isConnected == connected { log("Audio \(connected ? "connection" : "disconnection") confirmed for \(device.name). Control link retained."); return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw QCSessionError.timedOut("The QC did not confirm the requested audio connection. Make sure the other device is nearby and Bluetooth is on.")
    }

    private func routeConfirmed(_ address: Data) async throws {
        _ = try await request(DeviceManagementProtocol.route(address))
        for _ in 0..<6 {
            activeAudioAddress = try await DeviceManagementProtocol.activeAddress(from: request(DeviceManagementProtocol.sourceRequest())[0])
            if activeAudioAddress == address { log("Requested audio source confirmed."); return }
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw QCSessionError.timedOut("The QC did not confirm that audio switched. The target device may need to start playback.")
    }

    private func setMultipointConfirmed(_ enabled: Bool) async throws {
        _ = try await request(DeviceManagementProtocol.setMultipoint(enabled))
        multipoint = try await DeviceManagementProtocol.multipoint(from: request(DeviceManagementProtocol.multipointRequest())[0])
        guard multipoint == enabled else { throw QCSessionError.unexpected("The QC did not confirm the multipoint change.") }
        log("Multipoint \(enabled ? "on" : "off") confirmed.")
    }

    /// One-tap replacement: the outgoing device is confirmed disconnected before the new one connects,
    /// and a failed connection restores it (see connectAudioDevice). The toast offers Undo.
    func swapAudioDevice(to address: Data, replacing old: Data, undoable: Bool = true) async {
        let name = devices.first { $0.address == address }?.name ?? "device"
        await connectAudioDevice(address, replacing: old, feedback: QCFeedback(
            text: "Switched to \(name)", symbol: "arrow.left.arrow.right", undo: undoable ? (restore: old, replacing: address) : nil))
    }
    func undoSwap(_ feedback: QCFeedback) async {
        guard let undo = feedback.undo else { return }
        toastTask?.cancel(); toast = nil
        await swapAudioDevice(to: undo.restore, replacing: undo.replacing, undoable: false)
    }
    func connectAudioDevice(_ address: Data, replacing replacement: Data? = nil, feedback: QCFeedback? = nil) async {
        guard isConnected, hasVerifiedDirectControl, deviceControlsVerified, !controlsBusy else { return }
        pendingDevice = address; defer { pendingDevice = nil }
        await performUserCommand(notify: true, feedback: feedback ?? QCFeedback(text: "Device connected", symbol: "link")) {
            try await self.readDevices()
            let connected = self.devices.filter(\.isConnected)
            switch try DeviceConnectionPlanner.plan(target: address, devices: self.devices, multipoint: self.multipoint == true, replacement: replacement) {
            case .alreadyConnected: return
            case .connect: break
            case .chooseReplacement: throw QCSessionError.unavailable("All connection slots are occupied. Choose a connected device to disconnect and try again.")
            case .replace(let old): try await self.setAudioConnectedConfirmed(old, connected: false)
            }
            do { try await self.setAudioConnectedConfirmed(address, connected: true) }
            catch {
                guard let replacement, let old = connected.first(where: { $0.address == replacement }) else {
                    try? await self.readDevices(); throw error
                }
                let target = self.devices.first { $0.address == address }?.name ?? "The device"
                // The QC keeps paging an unreachable device and rejects other connections
                // meanwhile (BMAP error 8 observed for 7+ s). Ask it to stop, then retry, bounded.
                self.pendingDevice = replacement
                do {
                    _ = try await self.request(DeviceManagementProtocol.disconnect(address), optionalActionReply: true)
                    self.log("Asked the QC to stop connecting \(target).")
                } catch { self.log("Stop request for \(target): \(error.localizedDescription)") }
                var restored = false
                for attempt in 1...8 where !restored && !self.needsResynchronization {
                    do { try await self.setAudioConnectedConfirmed(replacement, connected: true); restored = true }
                    catch {
                        self.log("Restoring \(old.name), attempt \(attempt): \(error.localizedDescription)")
                        if attempt < 8 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                    }
                }
                try? await self.readDevices()
                throw QCSessionError.unavailable(restored
                    ? "\(target) didn’t connect, so \(old.name) was reconnected. Check it’s on and nearby."
                    : "\(target) didn’t connect and \(old.name) couldn’t be reconnected. Tap it to try again.")
            }
            try await self.readDevices()
        }
    }

    func disconnectAudioDevice(_ address: Data) async {
        guard isConnected, hasVerifiedDirectControl, deviceControlsVerified, !controlsBusy else { return }
        pendingDevice = address; defer { pendingDevice = nil }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "Device disconnected", symbol: "link.slash")) {
            guard self.devices.contains(where: { $0.address == address }) else { throw BMAPError.unexpectedResponse }
            try await self.setAudioConnectedConfirmed(address, connected: false)
            try await self.readDevices()
        }
    }

    func useAudioDevice(_ address: Data) async {
        guard isConnected, hasVerifiedDirectControl, routingVerified, !controlsBusy else { return }
        pendingDevice = address; defer { pendingDevice = nil }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "Audio device selected", symbol: "speaker.wave.2")) {
            try await self.readDevices()
            guard self.devices.contains(where: { $0.address == address && $0.isConnected }) else { throw QCSessionError.unavailable("Connect this device before choosing it for audio.") }
            try await self.routeConfirmed(address)
            try await self.readDevices()
        }
    }

    func setMultipointEnabled(_ value: Bool) async {
        guard isConnected, hasVerifiedDirectControl, multipointVerified, !controlsBusy else { return }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "Multipoint updated", symbol: "personalhotspot")) { try await self.setMultipointConfirmed(value); try await self.readDevices() }
    }

    func disconnectAllAudioDevices() async {
        guard isConnected, hasVerifiedDirectControl, disconnectAllVerified, !controlsBusy else { return }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "Audio devices disconnected", symbol: "link")) {
            try await self.readDevices()
            let connected = self.devices.filter(\.isConnected).sorted { !$0.isController && $1.isController }
            for device in connected { try await self.setAudioConnectedConfirmed(device.address, connected: false) }
            try await self.readDevices()
            guard !self.devices.contains(where: \.isConnected) else { throw QCSessionError.unexpected("Some audio devices are still connected. Refresh and try again.") }
            _ = try await self.request(PrinceProtocol.batteryRequest())
        }
    }

    func verifyDeviceControls() async {
        guard isConnected, !isWorking, hasVerifiedDirectControl, peripheralIdentity != nil else { return }
        isWorking = true; isVerifying = true; failure = nil
        let run = operationID
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "QuietControl device recovery") { [weak self] in self?.closeLink() }
        defer {
            if operationID == run {
                isWorking = false
                persistSnapshot()
                if needsResynchronization { closeLink() }
                if !isConnected { scheduleReconnect() }
                else if devicesNeedRefresh { scheduleDeviceRefresh() }
            }
            isVerifying = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        var report = DeviceVerificationReport(); report.model = model; report.firmware = firmware
        var checkpoint: DeviceRecoveryCheckpoint?
        do {
            try await readDevices()
            guard let multipoint, !devices.filter(\.isConnected).isEmpty else { throw QCSessionError.unavailable("Connect iPhone audio to your QC before verifying device controls.") }
            let baseline = DeviceRecoveryCheckpoint(peripheral: try requirePeripheralIdentity(), firmware: firmware, connected: devices.filter(\.isConnected).map(\.address), source: activeAudioAddress, multipoint: multipoint)
            checkpoint = baseline
            try save(baseline, named: "DeviceRecovery.json")
            message = "Checking audio disconnection while keeping the control link…"
            for device in devices.filter(\.isConnected).sorted(by: { !$0.isController && $1.isController }) {
                try await setAudioConnectedConfirmed(device.address, connected: false)
            }
            try await readDevices()
            guard !devices.contains(where: \.isConnected) else { throw QCSessionError.unexpected("Audio devices were not all disconnected.") }
            _ = try await request(PrinceProtocol.batteryRequest())
            report.disconnectAll = true
            message = "Restoring your starting audio connections…"
            try await restoreDeviceConnections(baseline)
            report.connectDisconnect = true
            // Test the multipoint parser by changing and independently reading both states.
            do {
                message = "Checking multipoint, then restoring it…"
                try await setMultipointConfirmed(!multipoint)
                try await setMultipointConfirmed(multipoint)
                report.multipoint = true
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await restoreDeviceConnections(baseline)
            } catch {
                report.limitations.append("Multipoint: \(error.localizedDescription)")
                try await restoreDeviceConnections(baseline)
            }
            var routingExists = true
            do { _ = try await request(BMAPFrame(block: 4, function: 12, operation: .get)) }
            catch BMAPError.deviceError(4) {
                routingExists = false
                report.limitations.append("Direct audio-source routing is not supported by this firmware (function 4.12). Start playback on a connected device instead.")
                environment.defaults.set(true, forKey: capabilityKey("routingUnsupported"))
            } catch {
                if needsResynchronization { throw error }
            }
            if routingExists, let mac = devices.first(where: { $0.name.localizedCaseInsensitiveContains("MacBook") && !baseline.connected.contains($0.address) }), multipoint {
                do {
                    message = "Checking the MacBook connection and audio routing…"
                    try await setAudioConnectedConfirmed(mac.address, connected: true)
                    try await routeConfirmed(mac.address)
                    report.routing = true
                } catch { report.limitations.append("Audio routing: \(error.localizedDescription)") }
            }
            try await restoreDeviceConnections(baseline)
            report.restorationConfirmed = true
            try clearDeviceRecovery()
            for (key, value) in [("connect", report.connectDisconnect), ("all", report.disconnectAll), ("routing", report.routing), ("multipoint", report.multipoint)] {
                environment.defaults.set(value, forKey: capabilityKey(key))
            }
            modeEditingVerified = environment.defaults.bool(forKey: capabilityKey("modeEditing"))
            loadDeviceCapabilities()
            message = "Device control check complete. Starting connections restored."
            log(message)
        } catch {
            report.failure = error.localizedDescription
            if let checkpoint, operationID == run {
                do { try await restoreDeviceConnections(checkpoint); report.restorationConfirmed = true; try clearDeviceRecovery() }
                catch { log("Device restoration pending: \(error.localizedDescription)") }
            }
            failure = report.failure
            message = report.restorationConfirmed ? "Device check failed; starting connections restored." : "Reconnect to restore the interrupted device check."
            log(message)
        }
        deviceVerification = report
        try? save(report, named: "DeviceControlProof.json")
    }

    private func deviceRecoveryCheckpoint() throws -> DeviceRecoveryCheckpoint? {
        let url = try documents("DeviceRecovery.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(DeviceRecoveryCheckpoint.self, from: Data(contentsOf: url))
    }
    private func clearDeviceRecovery() throws {
        let url = try documents("DeviceRecovery.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func restoreDeviceConnections(_ checkpoint: DeviceRecoveryCheckpoint) async throws {
        try await readDevices()
        if multipoint != checkpoint.multipoint { try await setMultipointConfirmed(checkpoint.multipoint) }
        // Multipoint can start a remembered host connection asynchronously. Require
        // two matching snapshots and remove any late connection before finishing.
        var matches = 0
        for _ in 0..<6 {
            try await readDevices()
            for device in devices where device.isConnected && !checkpoint.connected.contains(device.address) {
                try await setAudioConnectedConfirmed(device.address, connected: false)
            }
            for address in checkpoint.connected {
                if !devices.contains(where: { $0.address == address && $0.isConnected }) { try await setAudioConnectedConfirmed(address, connected: true) }
            }
            try await readDevices()
            if Set(devices.filter(\.isConnected).map(\.address)) == Set(checkpoint.connected), multipoint == checkpoint.multipoint {
                matches += 1
                if matches >= 2 {
                    if let source = checkpoint.source, activeAudioAddress != source {
                        if routingVerified { try await routeConfirmed(source) }
                        else { log("Starting audio connections restored. Resume playback on your preferred connected device if needed.") }
                    }
                    return
                }
            } else { matches = 0 }
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        throw QCSessionError.unexpected("Starting audio connections have not all been restored.")
    }

    func inspectDeviceManagement() async {
        guard isConnected else { return }
        await performUserCommand { try await self.readDevices() }
    }

    func verifyDirectControl() async {
        guard isConnected, !isWorking, let identity = peripheralIdentity, let baselineMode = mode,
              let bass = eq.first(where: { $0.band == .bass })?.value, battery != nil else { return }
        isWorking = true; isVerifying = true; isVerifyingModeEQ = true; failure = nil
        hasVerifiedDirectControl = false
        environment.defaults.set(false, forKey: proofKey)
        let run = operationID
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "QuietControl restoration") { [weak self] in self?.closeLink() }
        defer {
            if operationID == run {
                isWorking = false
                persistSnapshot()
                if needsResynchronization { closeLink() }
                if !isConnected { scheduleReconnect() }
                else if devicesNeedRefresh { scheduleDeviceRefresh() }
            }
            isVerifying = false; isVerifyingModeEQ = false
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }

        }
        proof.initialMode = baselineMode; proof.initialEQ = eq.map(\.value)
        proof.battery = battery; proof.modesRead = true
        let checkpoint = RecoveryCheckpoint(peripheral: identity, mode: baselineMode, bass: bass)
        do {
            try save(checkpoint, named: "PendingRestoration.json")
            message = "Checking Quiet and Aware, then restoring your mode…"
            try await setModeConfirmed(0); proof.quietConfirmed = true
            try await setModeConfirmed(1); proof.awareConfirmed = true
            try await setModeConfirmed(baselineMode)
            message = "Checking one EQ step, then restoring your EQ…"
            try await setEQConfirmed(.bass, value: bass == 10 ? 9 : bass + 1)
            proof.eqChangeConfirmed = true
            try await restore(checkpoint)
            proof.finalMode = mode; proof.finalEQ = eq.map(\.value)
            proof.restorationConfirmed = proof.finalMode == proof.initialMode && proof.finalEQ == proof.initialEQ
            guard proof.restorationConfirmed else { throw QCSessionError.unexpected("Read-back differs from the starting settings. Inspect the report before continuing.") }
            try clearRecovery()
            proof.directControlProven = true
            hasVerifiedDirectControl = true
            environment.defaults.set(true, forKey: proofKey)
            message = "Direct control check passed. Your original mode and EQ are restored."
            log(message)
        } catch {
            guard operationID == run else { return }
            proof.failure = error.localizedDescription
            log("Control check failed: \(error.localizedDescription)")
            do {
                guard operationID == run else { throw QCSessionError.disconnected }
                try await restore(checkpoint)
                try clearRecovery()
                proof.finalMode = mode; proof.finalEQ = eq.map(\.value)
                proof.restorationConfirmed = proof.finalMode == proof.initialMode && proof.finalEQ == proof.initialEQ
                log("Restored the original mode and bass after the failed check.")
            } catch {
                log("Restoration pending: \(error.localizedDescription). It will be retried on the next connection to the same QC.")
                closeLink()
            }
            failure = proof.failure
            message = proof.restorationConfirmed ? "The check failed; starting settings were restored." : "Reconnect to restore the settings from the interrupted check."
            persistProof()
        }
    }

    #if DEBUG
    /// Physical regression check: an idempotent mode action queued behind a read.
    private func verifyRefreshInteraction() async {
        guard isConnected, hasVerifiedDirectControl, let original = mode else { return }
        let read = Task { await self.refresh() }
        await Task.yield()
        let readStarted = isWorking && isRefreshing
        let buttonsAvailableDuringRead = !controlsBusy
        let action = Task { await self.selectMode(original) }
        try? await Task.sleep(nanoseconds: 40_000_000)
        let actionQueued = isUserCommandPending
        await read.value; await action.value
        let passed = readStarted && buttonsAvailableDuringRead && actionQueued && isConnected && mode == original && !controlsBusy
        log("Refresh interaction check: \(passed ? "passed" : "failed"); background reads keep controls available; queued mode action confirmed.")
        let result: [String: Any] = ["passed": passed, "readStarted": readStarted,
            "buttonsAvailableDuringRead": buttonsAvailableDuringRead, "actionQueued": actionQueued,
            "modeRestored": mode == original, "connected": isConnected,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"]
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("RefreshInteractionProof.json"),
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
    #endif

    func setEditingEQ(_ value: Bool) { editingEQ = value }

    func refresh() async {
        guard isConnected, !isWorking, !editingEQ, !isPreview else { return }
        await performUserCommand {
            try await self.readSnapshot(includeModes: false)
            do { try await self.readDevices() }
            catch { self.deviceListFailure = error.localizedDescription }
        }
    }

    func selectMode(_ index: UInt8) async {
        guard isConnected, hasVerifiedDirectControl, !controlsBusy else { return }
        let name = modes.first { $0.index == index }?.displayName ?? "Mode"
        let symbol = index == 0 ? "moon" : index == 1 ? "ear" : "lightbulb"
        await performUserCommand(notify: true, feedback: QCFeedback(text: "\(name) selected", symbol: symbol)) { try await self.setModeConfirmed(index) }
    }

    func setEQ(_ band: EQBand, value: Int) async {
        guard isConnected, hasVerifiedDirectControl, !controlsBusy else { return }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "EQ saved", symbol: "eq.curve")) { try await self.setEQConfirmed(band, value: value) }
    }

    func refreshModes() async {
        guard isConnected, !isPreview else { return }
        await performUserCommand { try await self.readSnapshot(includeModes: true) }
    }

    func saveMode(_ index: UInt8, strength: Int, windBlock: Bool) async -> Bool {
        guard isConnected, hasVerifiedDirectControl, modeEditingVerified, !controlsBusy else { return false }
        var saved = false
        await performUserCommand(notify: true, feedback: QCFeedback(text: "Mode saved", symbol: "lightbulb")) {
            try await self.readSnapshot(includeModes: true)
            guard let current = self.modes.first(where: { $0.index == index }) else { throw BMAPError.unexpectedResponse }
            try await self.writeModeConfirmed(current, strength: strength, windBlock: windBlock)
            saved = true
        }
        return saved
    }

    private func writeModeConfirmed(_ original: ListeningMode, strength: Int, windBlock: Bool) async throws {
        _ = try await request(PrinceProtocol.editMode(original, strength: strength, windBlock: windBlock))
        try await readSnapshot(includeModes: true)
        guard let updated = modes.first(where: { $0.index == original.index }),
              updated.ancStrength == (windBlock ? 10 : strength), updated.windBlock == windBlock,
              updated.name == original.name, updated.promptID == original.promptID else {
            throw QCSessionError.unexpected("The QC did not confirm the mode settings. Reopen the editor to read its current values.")
        }
    }

    func verifyModeEditing() async {
        guard isConnected, hasVerifiedDirectControl, !controlsBusy else { return }
        await performUserCommand(notify: true) {
            try await self.readSnapshot(includeModes: true)
            guard let original = self.modes.first(where: { $0.editable && $0.index > 1 }) else { throw BMAPError.unexpectedResponse }
            let checkpoint = ModeEditRecovery(peripheral: try self.requirePeripheralIdentity(), firmware: self.firmware, original: original)
            try self.save(checkpoint, named: "ModeEditRecovery.json")
            var testError: Error?
            do {
                let strength = original.ancStrength == 10 ? 9 : original.ancStrength + 1
                try await self.writeModeConfirmed(original, strength: strength, windBlock: original.windBlock)
                try await self.writeModeConfirmed(original, strength: original.ancStrength, windBlock: !original.windBlock)
            } catch { testError = error }
            try await self.writeModeConfirmed(original, strength: original.ancStrength, windBlock: original.windBlock)
            try self.clearModeEditRecovery()
            if let testError { throw testError }
            self.modeEditingVerified = true
            environment.defaults.set(true, forKey: self.capabilityKey("modeEditing"))
            try self.save(["passed": true, "restored": true], named: "ModeEditingProof.json")
        }
    }

    private func clearModeEditRecovery() throws {
        let url = try documents("ModeEditRecovery.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    #if DEBUG
    /// Deliberate bounded test: separate reads confirm each write and restoration.
    /// A pending journal prevents a new test after interruption; reconnect cannot rerun it.
    private func verifyPowerPreferences() async {
        guard isConnected, !isPreview, model == "884367-0100", firmware == "1.0.6-80+f5f219b" else { return }
        await performUserCommand {
            let journalURL = try self.documents("PowerPreferenceRecovery.json")
            guard !FileManager.default.fileExists(atPath: journalURL.path) else {
                throw QCSessionError.unavailable("A power-setting test needs restoration before another test can run.")
            }
            var report = ["date": ISO8601DateFormatter().string(from: Date()), "model": self.model, "firmware": self.firmware]
            let initialMode = try await self.readPowerRegister(block: 31, function: 3)
            for (name, block, function) in [("rememberMode", UInt8(31), UInt8(5))] {
                let original = try await self.readPowerRegister(block: block, function: function)
                guard original.count == 1,
                      (name == "autoOff" ? [0, 5, 20, 40, 60, 180].contains(original[0]) : original[0] <= 1) else {
                    throw BMAPError.malformedPayload
                }
                let candidate = Data([name == "autoOff" ? (original[0] == 20 ? 40 : 20) : (original[0] == 1 ? 0 : 1)])
                report[name + "Original"] = original.hexString
                try self.save(["model": self.model, "firmware": self.firmware,
                               "peripheral": try self.requirePeripheralIdentity().uuidString,
                               "block": String(block), "function": String(function), "original": original.hexString], named: "PowerPreferenceRecovery.json")
                try self.save(report, named: "PowerPreferenceProof.json")
                var writeError: Error?
                do {
                    try await self.writePowerRegister(block: block, function: function, value: candidate)
                    report["cncPersistenceAfterWrite"] = try await self.readPowerRegister(block: 1, function: 14).hexString
                    report[name + "CandidateConfirmed"] = candidate.hexString
                } catch { writeError = error; report[name + "Failure"] = error.localizedDescription }
                // Always attempt the exact original once, even if the candidate failed.
                try await self.writePowerRegister(block: block, function: function, value: original)
                report[name + "Restored"] = original.hexString
                try FileManager.default.removeItem(at: journalURL)
                try self.save(report, named: "PowerPreferenceProof.json")
                if let writeError { throw writeError }
            }
            guard try await self.readPowerRegister(block: 31, function: 3) == initialMode else { throw BMAPError.unexpectedResponse }
            report["modeUnchanged"] = initialMode.hexString
            report["passed"] = "true"
            try self.save(report, named: "PowerPreferenceProof.json")
        }
    }

    private func readPowerRegister(block: UInt8, function: UInt8) async throws -> Data {
        let frame = try await request(BMAPFrame(block: block, function: function, operation: .get))[0]
        return try frame.statusPayload(block: block, function: function)
    }

    private func writePowerRegister(block: UInt8, function: UInt8, value: Data) async throws {
        guard (block == 1 && function == 4 || block == 31 && function == 5), value.count == 1,
              (block == 1 ? [0, 5, 20, 40, 60, 180].contains(value[0]) : value[0] <= 1) else { throw BMAPError.malformedPayload }
        _ = try await request(BMAPFrame(block: block, function: function, operation: .setGet, payload: value), optionalActionReply: true)
        guard try await readPowerRegister(block: block, function: function) == value else { throw BMAPError.unexpectedResponse }
    }

    /// Explicit, once-per-session investigation. GET only; no restoration or writes.
    private func inspectPowerPreferences() async {
        guard isConnected, !isPreview else { return }
        await performUserCommand {
            var report = ["date": ISO8601DateFormatter().string(from: Date()),
                          "model": self.model, "firmware": self.firmware]
            for (name, block, function) in [("autoOff", 1, 4), ("cncPersistence", 1, 14),
                                           ("currentMode", 31, 3), ("defaultMode", 31, 4),
                                           ("modeFunction5", 31, 5)] {
                do {
                    let frame = try await self.request(BMAPFrame(block: UInt8(block), function: UInt8(function), operation: .get))[0]
                    report[name] = try frame.statusPayload(block: UInt8(block), function: UInt8(function)).hexString
                } catch {
                    report[name] = "ERROR: \(error.localizedDescription)"
                    if self.needsResynchronization { throw error }
                }
            }
            try self.save(report, named: "PowerPreferencesInspection.json")
        }
    }
    #endif

    func refreshPreferences() async {
        guard isConnected, !isPreview else { return }
        preferencesFailure = nil
        await performUserCommand {
            self.preferencePackets = [:]
            for (name, block, function) in [("voicePrompts", 1, 3), ("selfVoice", 1, 11), ("shortcut", 1, 9),
                                           ("autoOff", 1, 4), ("rememberMode", 31, 5)] {
                do {
                    let frame = try await self.request(BMAPFrame(block: UInt8(block), function: UInt8(function), operation: .get))[0]
                    self.preferencePackets[name] = try frame.statusPayload(block: UInt8(block), function: UInt8(function))
                } catch {
                    self.log("Preference \(name): \(error.localizedDescription)")
                    if self.needsResynchronization { throw error }
                }
            }
            try self.save(self.preferencePackets.mapValues { $0.hexString }, named: "HeadphonePreferences.json")
        }
        preferencesFailure = failure
    }

    func applyEQ(_ values: [Int]) async {
        guard values.count == 3, values.allSatisfy({ (-10...10).contains($0) }),
              isConnected, hasVerifiedDirectControl, !controlsBusy else { return }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "EQ saved", symbol: "eq.curve")) {
            let before = self.eq.map(\.value)
            do {
                for band in EQBand.allCases { try await self.setEQConfirmed(band, value: values[Int(band.rawValue)]) }
            } catch {
                if before.count == 3 && !self.needsResynchronization {
                    for band in EQBand.allCases { try? await self.setEQConfirmed(band, value: before[Int(band.rawValue)]) }
                }
                throw error
            }
        }
    }

    /// Auto-Off [1.4] and Remember My Mode [31.5] write/read-back passed on this model and firmware only.
    /// [1.14] mirrors Remember My Mode but writing it alone leaves [31.5] unchanged, so it is never written.
    private var powerSettingsProven: Bool { model == "884367-0100" && firmware == "1.0.6-80+f5f219b" }
    static let autoOffMinutes: [UInt8] = [5, 20, 40, 60, 180, 0]
    private func preferenceLocation(_ name: String) -> (UInt8, UInt8) {
        name == "rememberMode" ? (31, 5) : (1, ["voicePrompts": 3, "selfVoice": 11, "autoOff": 4, "shortcut": 9][name] ?? 0)
    }
    private func preferenceWritePayload(_ name: String, from packet: Data) throws -> Data {
        switch name {
        case "voicePrompts": guard let first = packet.first else { throw BMAPError.malformedPayload }; return Data([first & 0x3f])
        case "selfVoice": guard packet.count >= 2, packet[1] < 4 else { throw BMAPError.malformedPayload }; return Data([1, packet[1]])
        case "shortcut": guard packet.count >= 3, packet[0] == 0x80, packet[1] == 9 else { throw BMAPError.malformedPayload }; return Data(packet.prefix(3))
        case "autoOff": guard packet.count == 1, Self.autoOffMinutes.contains(packet[0]) else { throw BMAPError.malformedPayload }; return packet
        case "rememberMode": guard packet.count == 1, packet[0] <= 1 else { throw BMAPError.malformedPayload }; return packet
        default: throw BMAPError.unexpectedResponse
        }
    }
    private func writePreferenceConfirmed(_ name: String, payload: Data) async throws {
        let (block, function) = preferenceLocation(name)
        _ = try await request(BMAPFrame(block: block, function: function, operation: .setGet, payload: payload), optionalActionReply: true)
        let reply = try await request(BMAPFrame(block: block, function: function, operation: .get))[0]
        let current = try reply.statusPayload(block: block, function: function)
        guard try preferenceWritePayload(name, from: current) == payload else { throw QCSessionError.unexpected("The QC did not confirm this setting.") }
        preferencePackets[name] = current
    }
    func setPreference(_ name: String, value: UInt8) async {
        guard isConnected, verifiedPreferences.contains(name), !controlsBusy,
              preferencePackets[name] != nil else { return }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "Setting saved", symbol: "slider.horizontal.3")) {
            let (block, function) = self.preferenceLocation(name)
            let frame = try await self.request(BMAPFrame(block: block, function: function, operation: .get))[0]
            let current = try frame.statusPayload(block: block, function: function)
            var payload = try self.preferenceWritePayload(name, from: current)
            switch name {
            case "voicePrompts": payload[0] = (payload[0] & 0x1f) | (value == 1 ? 0x20 : 0)
            case "selfVoice": guard value < 4 else { throw BMAPError.malformedPayload }; payload[1] = value
            case "shortcut": guard [3, 14, 16].contains(value) else { throw BMAPError.malformedPayload }; payload[2] = value
            case "autoOff": guard Self.autoOffMinutes.contains(value) else { throw BMAPError.malformedPayload }; payload[0] = value
            case "rememberMode": guard value <= 1 else { throw BMAPError.malformedPayload }; payload[0] = value
            default: throw BMAPError.unexpectedResponse
            }
            try await self.writePreferenceConfirmed(name, payload: payload)
        }
    }
    func verifyPreferences() async {
        guard isConnected, !controlsBusy else { return }
        await refreshPreferences()
        await performUserCommand(notify: true) {
            var results: [String: Bool] = [:]
            for name in ["selfVoice", "shortcut"] {
                guard let packet = self.preferencePackets[name] else { continue }
                let original = try self.preferenceWritePayload(name, from: packet)
                var candidate = original
                switch name {
                case "voicePrompts": candidate[0] ^= 0x20
                case "selfVoice": candidate[1] = original[1] == 2 ? 3 : 2
                default: candidate[2] = original[2] == 14 ? 3 : 14
                }
                let recovery = PreferenceRecovery(peripheral: try self.requirePeripheralIdentity(), firmware: self.firmware, name: name, payload: original)
                try self.save(recovery, named: "PreferenceRecovery.json")
                var testError: Error?
                do { try await self.writePreferenceConfirmed(name, payload: candidate) } catch { testError = error }
                try await self.writePreferenceConfirmed(name, payload: original)
                try self.clearPreferenceRecovery()
                results[name] = testError == nil
                if testError == nil { self.verifiedPreferences.insert(name); environment.defaults.set(true, forKey: self.capabilityKey(name)) }
            }
            try self.save(results, named: "PreferenceProof.json")
        }
    }
    private func clearPreferenceRecovery() throws {
        let url = try documents("PreferenceRecovery.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func resetEQ() async {
        guard isConnected, hasVerifiedDirectControl, !controlsBusy else { return }
        await performUserCommand(notify: true, feedback: QCFeedback(text: "EQ reset", symbol: "eq.curve")) {
            for band in EQBand.allCases { try await self.setEQConfirmed(band, value: 0) }
        }
    }

    private func performUserCommand(notify: Bool = false, feedback: QCFeedback? = nil, _ body: () async throws -> Void) async {
        let run = operationID
        if notify {
            guard !isUserCommandPending else { return }
            isUserCommandPending = true
        } else {
            guard !isWorking, !isUserCommandPending else { return }
        }
        defer { if notify { isUserCommandPending = false } }
        // Reads share the wire with actions, but do not disable the dashboard.
        // A tap during a read waits for its reply; never overlap BMAP requests.
        while isWorking {
            do { try await Task.sleep(nanoseconds: UInt64(environment.timing.refreshPollInterval * 1_000_000_000)); try requireRun(run) }
            catch { return }
            guard isConnected else { return }
        }
        guard isConnected, operationID == run, !Task.isCancelled else { return }
        isRefreshing = !notify
        isWorking = true; failure = nil
        defer {
            if operationID == run {
                isRefreshing = false
                isWorking = false
                persistSnapshot()
                if needsResynchronization { closeLink() }
                if !isConnected { scheduleReconnect() }
                else if devicesNeedRefresh { scheduleDeviceRefresh() }
            }
        }
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "QuietControl command")
        defer { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) } }
        do {
            try await body(); try requireRun(run); message = "Settings confirmed by your QC."
            if notify { showToast(feedback ?? QCFeedback(text: "Change confirmed", symbol: "checkmark")) }
        }
        catch {
            guard operationID == run else { return }
            failure = error.localizedDescription; message = "The change could not be confirmed."
            log("Command failed: \(error.localizedDescription)")
            if notify { showToast(QCFeedback(text: error.localizedDescription, symbol: "exclamationmark.triangle", isError: true)) }
            try? await readSnapshot(includeModes: false)
            if needsResynchronization { closeLink() }
        }
    }

    func disconnect() {
        lifecycle.pause(); connectionState = lifecycle.state
        environment.defaults.set(false, forKey: "quietcontrol.autoConnect")
        log("Auto-connect paused by user; pairing is unchanged.")
        cancelSetupAndLink()
        message = "Auto-connect paused."
    }

    func beginInspection() {
        isInspecting = true
        cancelSetupAndLink()
    }
    func endInspection() {
        isInspecting = false
        restoreCachedProfile()
        startIfNeeded()
    }
    private func cancelSetupAndLink() {
        reconnectTask?.cancel(); reconnectTask = nil
        presentationTimer?.cancel(); presentationTimer = nil
        operationID = UUID()
        closeLink()
        isEstablishing = false; isWorking = false; isRefreshing = false
    }
    private func closeLink() {
        completeCommand(.failure(QCSessionError.disconnected))
        transport?.close()
        controlEndpoint = nil; peripheralIdentity = nil
        isConnected = false; hasLiveDeviceList = false; preferencePackets = [:]; modeEditingVerified = false
        lifecycle.linkLost(); connectionState = lifecycle.state
        deviceRefreshTask?.cancel(); deviceRefreshTask = nil
        outgoing.removeAll(); writeInProgress = false; reassembler.reset()
    }

    private var snapshotStore: ConfirmedSnapshotStore? {
        ConfirmedSnapshotStore(fileURL: environment.snapshotURL)
    }
    private func restoreCachedProfile() {
        guard let id = environment.defaults.string(forKey: "quietcontrol.lastPeripheral").flatMap(UUID.init(uuidString:)) else { return }
        guard let saved = snapshotStore?.load(for: id) else {
            if !isConnected { hasSavedProfile = false; modes = []; eq = []; devices = []; mode = nil; lastConfirmedAt = nil; battery = nil; manufacturer = ""; model = ""; firmware = ""; controllerAddress = nil; multipoint = nil }
            return
        }
        manufacturer = saved.manufacturer; model = saved.model; firmware = saved.firmware
        modes = saved.modes; devices = saved.devices; eq = saved.eq; mode = saved.lastMode
        battery = saved.battery; controllerAddress = saved.controllerAddress; multipoint = saved.multipoint
        lastConfirmedAt = saved.lastSeen; hasSavedProfile = true
    }
    private func persistSnapshot() {
        guard !isPreview, isConnected, hasLiveDeviceList, let identity = peripheralIdentity, let mode else { return }
        let snapshot = ConfirmedSnapshot(peripheralID: identity, manufacturer: manufacturer, model: model,
            firmware: firmware, modes: modes, devices: devices, eq: eq, lastMode: mode,
            lastSeen: lastContactAt ?? Date(), battery: battery, controllerAddress: controllerAddress, multipoint: multipoint)
        do {
            guard let store = snapshotStore else { throw SnapshotError.invalid }
            try store.save(snapshot)
            hasSavedProfile = true; lastConfirmedAt = snapshot.lastSeen
        } catch { log("Could not save the last-confirmed profile: \(error.localizedDescription)") }
    }
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(environment.timing.snapshotDebounce * 1_000_000_000)) } catch { return }
            guard !self.isWorking else { return }
            self.persistSnapshot()
        }
    }
    private func showToast(_ feedback: QCFeedback) {
        toastTask?.cancel(); toast = feedback
        if UIAccessibility.isVoiceOverRunning { UIAccessibility.post(notification: .announcement, argument: feedback.text) }
        toastTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UIAccessibility.isVoiceOverRunning ? 8_000_000_000 : feedback.isError || feedback.undo != nil ? 5_000_000_000 : 2_600_000_000) } catch { return }
            self?.toast = nil
        }
    }

    private var proofKey: String { "quietcontrol.verified.\(peripheralIdentity?.uuidString ?? "").\(model).\(firmware)" }

    private func readSnapshot(includeModes: Bool) async throws {
        battery = try await PrinceProtocol.battery(from: request(PrinceProtocol.batteryRequest())[0])
        proof.battery = battery
        mode = try await PrinceProtocol.currentMode(from: request(PrinceProtocol.modeRequest())[0])
        eq = try await PrinceProtocol.eq(from: request(PrinceProtocol.eqRequest())[0])
        guard eq.allSatisfy({ $0.minimum == -10 && $0.maximum == 10 && (-10...10).contains($0.value) }) else {
            throw QCSessionError.unexpected("The EQ range differs from the verified QuietComfort profile.")
        }
        if includeModes {
            let frames = try await request(PrinceProtocol.modesRequest(), modes: true)
            let parsed = try frames.map(PrinceProtocol.modeConfiguration)
            var byIndex: [UInt8: ListeningMode] = [:]
            for mode in parsed { byIndex[mode.index] = mode }
            modes = byIndex.values.filter { $0.index < 2 || ($0.configured && ($0.promptID > 0 || !$0.name.isEmpty)) }.sorted { $0.index < $1.index }
        }
        guard let mode, modes.contains(where: { $0.index == mode }) else { throw QCSessionError.unexpected("The current mode was not found in the returned prince modes.") }
        log("Snapshot: battery \(battery.map(String.init) ?? "unavailable")%, mode \(mode), EQ \(eq.map(\.value)).")
    }

    private func setModeConfirmed(_ index: UInt8) async throws {
        guard modes.contains(where: { $0.index == index }) else { throw QCSessionError.unexpected("That listening mode is not present on this QC.") }
        _ = try await request(PrinceProtocol.selectMode(index))
        for _ in 0..<environment.timing.modeConfirmationAttempts {
            let reported = try await PrinceProtocol.currentMode(from: request(PrinceProtocol.modeRequest())[0])
            mode = reported
            if reported == index { log("Mode \(index) confirmed."); return }
            try await Task.sleep(nanoseconds: UInt64(environment.timing.modeConfirmationDelay * 1_000_000_000))
        }
        throw QCSessionError.timedOut("The QC did not confirm the requested mode.")
    }

    private func setEQConfirmed(_ band: EQBand, value: Int) async throws {
        _ = try await request(PrinceProtocol.setEQ(band, value: value))
        eq = try await PrinceProtocol.eq(from: request(PrinceProtocol.eqRequest())[0])
        guard eq.first(where: { $0.band == band })?.value == value else { throw QCSessionError.unexpected("The QC did not confirm the requested EQ value.") }
        log("EQ band \(band.rawValue) = \(value) confirmed.")
    }

    private func restore(_ checkpoint: RecoveryCheckpoint) async throws {
        try await setEQConfirmed(.bass, value: checkpoint.bass)
        try await setModeConfirmed(checkpoint.mode)
    }

    private func requirePeripheralIdentity() throws -> UUID {
        guard let peripheralIdentity else { throw QCSessionError.disconnected }
        return peripheralIdentity
    }

    private func request(_ frame: BMAPFrame, modes: Bool = false, optionalActionReply: Bool = false) async throws -> [BMAPFrame] {
        guard !needsResynchronization, commandWaiter == nil, let transport, transport.isConnected,
              controlEndpoint != nil else { throw QCSessionError.disconnected }
        let run = operationID
        let pause = environment.timing.requestSpacing - Date().timeIntervalSince(lastSent)
        if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        try Task.checkCancellation()
        try requireRun(run)
        guard commandWaiter == nil, self.transport === transport else { throw QCSessionError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            expectedBlock = frame.block; expectedFunction = frame.function; collectingModes = modes
            self.optionalActionReply = optionalActionReply
            expectedOperations = (frame.operation == .start || optionalActionReply) ? [.status, .result, .processing] : [.status]
            replies.removeAll(); commandWaiter = continuation; commandStarted = Date()
            do { outgoing = try BoseBLEFraming.segments(for: frame.encoded) }
            catch { completeCommand(.failure(error)); return }
            log("TX \(frame.encoded.hexString)")
            commandTimer = Task { [weak self] in
                guard let self else { return }
                let timeout = optionalActionReply ? self.environment.timing.optionalActionTimeout : self.environment.timing.commandTimeout
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if self.optionalActionReply { self.completeCommand(.success([])) }
                else { self.completeCommand(.failure(QCSessionError.timedOut("The QC did not answer BMAP [\(frame.block).\(frame.function)]."))) }
            }
            flushWrites()
        }
    }

    private func flushWrites() {
        guard let transport, let endpoint = controlEndpoint, !writeInProgress else { return }
        let withoutResponse = endpoint.writeWithoutResponse
        while let segment = outgoing.first {
            if withoutResponse && !transport.canSendWriteWithoutResponse { return }
            guard segment.count <= transport.maximumWriteLength(for: endpoint, withoutResponse: withoutResponse) else {
                completeCommand(.failure(QCSessionError.unexpected("The negotiated BLE write size is too small.")))
                return
            }
            outgoing.removeFirst(); lastSent = Date()
            if !withoutResponse { writeInProgress = true }
            do { try transport.write(segment, to: endpoint, withoutResponse: withoutResponse) }
            catch { completeCommand(.failure(error)); return }
            if !withoutResponse { return }
        }
    }

    private func receive(_ data: Data) {
        do {
            guard let complete = try reassembler.receive(data) else { return }
            var decoder = BMAPStreamDecoder()
            let frames = try decoder.append(complete); try decoder.finish()
            for frame in frames {
                log("RX \(frame.encoded.hexString)")
                if frame.flags & 0xf0 == 0, [.status, .result, .processing].contains(frame.operation) { lastContactAt = Date() }
                applyReportedState(frame)
                if isConnected { scheduleSnapshot() }
                guard commandWaiter != nil, frame.flags & 0xf0 == 0 else { continue }
                if frame.block == expectedBlock && frame.function == expectedFunction && frame.operation == .error {
                    completeCommand(.failure(BMAPError.deviceError(frame.payload.first ?? 0))); return
                }
                if collectingModes {
                    guard frame.block == 31, frame.function == 6, frame.operation == .status else { continue }
                    replies.append(frame)
                    drainTimer?.cancel()
                    drainTimer = Task { [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(nanoseconds: UInt64(self.environment.timing.modeDrainDelay * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self.completeCommand(.success(self.replies))
                    }
                } else if frame.block == expectedBlock && frame.function == expectedFunction
                            && expectedOperations.contains(frame.operation) {
                    completeCommand(.success([frame]))
                }
            }
        } catch { completeCommand(.failure(error)) }
    }

    private func completeCommand(_ result: Result<[BMAPFrame], Error>) {
        commandTimer?.cancel(); commandTimer = nil
        drainTimer?.cancel(); drainTimer = nil
        outgoing.removeAll(); writeInProgress = false
        let continuation = commandWaiter; commandWaiter = nil
        if case .failure(let error) = result {
            if case QCSessionError.timedOut = error { needsResynchronization = true }
            if error is BLEFramingError { needsResynchronization = true }
            if let error = error as? BMAPError {
                if case .deviceError = error { /* An explicit rejection is a synchronized reply. */ }
                else { needsResynchronization = true }
            }
        }
        if continuation != nil { log("Command finished in \(Int(Date().timeIntervalSince(commandStarted) * 1000)) ms.") }
        continuation?.resume(with: result)
    }

    private func requireRun(_ run: UUID) throws {
        guard operationID == run else { throw CancellationError() }
    }

    private func applyReportedState(_ frame: BMAPFrame) {
        guard frame.flags & 0xf0 == 0 else { return }
        if frame.block == 4, [1, 2, 4, 5, 12].contains(frame.function),
           [.status, .result, .processing].contains(frame.operation) {
            if frame.function == 5, let update = try? DeviceManagementProtocol.device(from: frame),
               let index = devices.firstIndex(where: { $0.address == update.address }) { devices[index] = update }
            if commandWaiter == nil || [1, 2, 12].contains(frame.function) {
                devicesNeedRefresh = true
                scheduleDeviceRefresh()
            }
        }
        guard frame.operation == .status else { return }
        if frame.block == 2, frame.function == 2, let value = try? PrinceProtocol.battery(from: frame) { battery = value }
        if frame.block == 5, frame.function == 1 {
            if let value = try? DeviceManagementProtocol.activeAddress(from: frame) { activeAudioAddress = value }
            else if frame.payload.count >= 3 && frame.payload[2] != 1 { activeAudioAddress = nil }
        }
        if frame.block == 1, frame.function == 10, let value = try? DeviceManagementProtocol.multipoint(from: frame) { multipoint = value }
        if frame.block == 31, frame.function == 3, let value = try? PrinceProtocol.currentMode(from: frame) { mode = value }
        if frame.block == 1, frame.function == 7, let settings = try? PrinceProtocol.eq(from: frame),
           settings.allSatisfy({ $0.minimum == -10 && $0.maximum == 10 }) { eq = settings }
        if frame.block == 31, frame.function == 6, let updated = try? PrinceProtocol.modeConfiguration(from: frame) {
            modes.removeAll { $0.index == updated.index }
            if updated.index < 2 || (updated.configured && (updated.promptID > 0 || !updated.name.isEmpty)) { modes.append(updated); modes.sort { $0.index < $1.index } }
        }
    }

    private func documents(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: environment.reportsDirectory, withIntermediateDirectories: true)
        return environment.reportsDirectory.appendingPathComponent(name)
    }
    private func save<T: Encodable>(_ value: T, named name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var url = try documents(name)
        try encoder.encode(value).write(to: url, options: .atomic)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true; try url.setResourceValues(flags)
    }
    private func recoveryCheckpoint() throws -> RecoveryCheckpoint? {
        let url = try documents("PendingRestoration.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(RecoveryCheckpoint.self, from: Data(contentsOf: url))
    }
    private func clearRecovery() throws {
        let url = try documents("PendingRestoration.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func persistProof() {
        do {
            try save(proof, named: "SessionDiagnostics.json")
            if isVerifyingModeEQ || proof.directControlProven { try save(proof, named: "ControlProof.json") }
        } catch {
            if failure == nil { failure = "Could not save the local connection report: \(error.localizedDescription)" }
        }
    }
    private func appendLifecycle(_ event: ProbeEvent) {
        guard !isPreview else { return }
        do {
            let url = try documents("LifecycleDiagnostics.jsonl")
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue > 1_048_576 {
                let previous = try documents("LifecycleDiagnostics.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event); data.append(0x0a)
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                var flags = URLResourceValues(); flags.isExcludedFromBackup = true
                var target = url; try target.setResourceValues(flags)
            } else {
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd(); try file.write(contentsOf: data)
            }
        } catch { /* A diagnostic write cannot break headphone control. */ }
    }

    private func log(_ text: String) {
        let event = ProbeEvent(date: Date(), message: text)
        appendLifecycle(event)
        proof.events.append(event)
        if proof.events.count > 300 { proof.events.removeFirst(proof.events.count - 300) }
        persistProof()
    }
}

extension QuietComfortSession: QCByteTransportDelegate {
    func transport(_ transport: QCByteTransport, didReceive segment: Data) {
        receive(segment)
    }

    func transport(_ transport: QCByteTransport, didFailReceive error: Error) {
        completeCommand(.failure(error))
    }

    func transport(_ transport: QCByteTransport, didFinishWrite error: Error?) {
        writeInProgress = false
        if let error { completeCommand(.failure(error)) } else { flushWrites() }
    }

    func transportIsReadyForMoreWrites(_ transport: QCByteTransport) {
        flushWrites()
    }

    func transport(_ transport: QCByteTransport, didDisconnect error: Error?) {
        failure = error?.localizedDescription ?? QCSessionError.disconnected.localizedDescription
        log("Disconnected: \(failure ?? ""); domain \((error as NSError?)?.domain ?? "none"), code \((error as NSError?)?.code ?? 0).")
        closeLink()
        scheduleReconnect()
    }

    func transport(_ transport: QCByteTransport, radioStateChanged state: QCTransportRadioState) {
        log("Bluetooth radio state: \(state).")
        switch state {
        case .poweredOff: lifecycle.radioUnavailable(.bluetoothOff)
        case .unauthorized: lifecycle.radioUnavailable(.permissionNeeded)
        case .unsupported: lifecycle.radioUnavailable(.unavailable)
        case .poweredOn: lifecycle.radioReady()
        case .unknown, .resetting: break
        }
        connectionState = lifecycle.state
        if state == .poweredOn { startIfNeeded() }
        else if isConnected || transport.identifier != nil { closeLink() }
    }

    func transportDidRestoreLink(_ transport: QCByteTransport) {
        guard lifecycle.wantsConnection else {
            transport.close()
            log("Ignored restored connection because auto-connect is paused.")
            return
        }
        isRestoring = true
        log("Restored CoreBluetooth peripheral; rebuilding and validating the BMAP session.")
    }
}
