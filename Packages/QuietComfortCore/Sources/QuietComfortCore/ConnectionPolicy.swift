import Foundation

public enum QCConnectionState: String, Codable, Sendable {
    case setupRequired, connecting, waitingForQC, connected, paused, bluetoothOff, permissionNeeded, unavailable
    public var title: String {
        switch self {
        case .setupRequired: return "Ready to connect"
        case .connecting: return "Connecting…"
        case .waitingForQC: return "Waiting for QC"
        case .connected: return "Connected"
        case .paused: return "Auto-connect paused"
        case .bluetoothOff: return "Bluetooth off"
        case .permissionNeeded: return "Bluetooth permission needed"
        case .unavailable: return "Connection needs attention"
        }
    }
}

/// Presence waiting is a single pending request, independent of scene visibility
/// and command progress. Backoff is only for a failed setup, not absent headphones.
public struct ConnectionPolicy {
    public private(set) var wantsConnection: Bool
    public private(set) var isForeground = true
    public private(set) var hasPendingConnection = false
    public private(set) var state: QCConnectionState
    private var retry = 0
    public init(wantsConnection: Bool = true, hasRememberedDevice: Bool = false) {
        self.wantsConnection = wantsConnection
        state = !wantsConnection ? .paused : hasRememberedDevice ? .waitingForQC : .setupRequired
    }
    public mutating func setForeground(_ value: Bool) { isForeground = value }
    public mutating func pause() {
        wantsConnection = false; hasPendingConnection = false; retry = 0; state = .paused
    }
    public mutating func resume() {
        wantsConnection = true
        if state == .paused { state = .waitingForQC }
    }
    @discardableResult public mutating func beginAttempt(hasRememberedDevice: Bool) -> Bool {
        guard wantsConnection, !hasPendingConnection, state != .connected else { return false }
        guard hasRememberedDevice else { state = .setupRequired; return false }
        hasPendingConnection = true; state = .connecting
        return true
    }
    public mutating func settleWaiting() {
        if wantsConnection && hasPendingConnection { state = .waitingForQC }
    }
    public mutating func connected() { hasPendingConnection = false; retry = 0; state = .connected }
    public mutating func linkLost() {
        hasPendingConnection = false
        if !wantsConnection { state = .paused }
        else if ![.bluetoothOff, .permissionNeeded, .unavailable, .setupRequired].contains(state) { state = .waitingForQC }
    }
    public mutating func radioUnavailable(_ state: QCConnectionState) {
        hasPendingConnection = false
        self.state = state
    }
    public mutating func radioReady() {
        if !wantsConnection { state = .paused }
        else if [.bluetoothOff, .permissionNeeded].contains(state) { state = .waitingForQC }
    }
    public mutating func nextRetryDelay() -> TimeInterval? {
        guard wantsConnection, !hasPendingConnection, state != .connected else { return nil }
        guard isForeground else { return 0 }
        let delays: [TimeInterval] = [1, 2, 4, 8, 15]
        let value = delays[min(retry, delays.count - 1)]
        retry += 1
        return value
    }
}

/// Lives for the app session, independent of Bluetooth connection attempts.
/// Automatic checks and recovery must never be re-armed by a reconnect.
public struct SessionActionGate {
    private var attempted: Set<String> = []
    public init() {}
    public mutating func claim(_ action: String) -> Bool { attempted.insert(action).inserted }
}
