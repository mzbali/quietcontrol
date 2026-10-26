import SwiftUI

@main
struct QuietControlApp: App {
    @StateObject private var probe = BluetoothProbe()
    @StateObject private var session = QuietComfortSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            QuietControlView(session: session, probe: probe)
                #if DEBUG && targetEnvironment(simulator)
                .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--preview-large") ? .accessibility3 : .large)
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { probe.pauseForBackground(); session.setForeground(false) }
                    if phase == .active { session.setForeground(true) }
                }
        }
    }
}

