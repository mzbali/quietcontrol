import SwiftUI

@main
struct QuietControlApp: App {
    @StateObject private var model = QCRootModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let session = model.session, let probe = model.probe {
                QuietControlView(session: session, probe: probe)
                    #if DEBUG && targetEnvironment(simulator)
                    .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--preview-large") ? .accessibility3 : .large)
                    #endif
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .background { probe.pauseForBackground(); session.setForeground(false) }
                        if phase == .active { session.setForeground(true) }
                    }
            } else {
                QCConfigurationErrorView(message: model.configurationError ?? "Unknown configuration error.")
            }
        }
    }
}

/// Builds the test or production environment before any session, probe or storage
/// consumer exists. An invalid explicit test configuration stops here instead of
/// silently falling back to production behaviour.
@MainActor
final class QCRootModel: ObservableObject {
    let session: QuietComfortSession?
    let probe: BluetoothProbe?
    let configurationError: String?

    init() {
        switch QCSessionEnvironment.load() {
        case .ready(let environment):
            session = QuietComfortSession(environment: environment)
            probe = BluetoothProbe(defaults: environment.defaults, testMode: environment.isTestMode)
            configurationError = nil
        case .invalidConfiguration(let message):
            session = nil
            probe = nil
            configurationError = message
        }
    }
}

private struct QCConfigurationErrorView: View {
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("QuietControl could not start", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Text("UI test configuration is invalid. No Bluetooth radio or production data is used.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("configuration-error")
    }
}
