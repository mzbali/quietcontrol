import SwiftUI

struct ControlCheckView: View {
    @ObservedObject var session: QuietComfortSession
    @ObservedObject var probe: BluetoothProbe
    @Environment(\.dismiss) private var dismiss
    @State private var showingInspection = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Bose QuietComfort", systemImage: "headphones").font(.title2.bold())
                    Text(session.message)
                    if session.isWorking { ProgressView() }
                    if let error = session.failure { Text(error).foregroundStyle(.red) }
                } header: { Text("Direct control check") }
                if session.isConnected {
                    Section("Read directly from your QC") {
                        LabeledContent("Model", value: session.model)
                        LabeledContent("Firmware", value: session.firmware)
                        LabeledContent("Battery", value: session.battery.map { "\($0)%" } ?? "Unavailable")
                        LabeledContent("Current mode", value: session.modes.first { $0.index == session.mode }?.name ?? "Unknown")
                        LabeledContent("Bass / Mid / Treble", value: session.eq.map { String($0.value) }.joined(separator: " / "))
                    }
                    Section {
                        Button("Run control check") { Task { await session.verifyDirectControl() } }
                            .disabled(session.isWorking)
                        Text("This switches Quiet/Aware and changes bass by one step. Your starting mode and EQ will be restored and checked. An interrupted check is restored on the next connection.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Button("Connect to my QC") { Task { try? await session.connectRemembered() } }
                            .disabled(session.isWorking)
                    }
                }
                if session.proof.directControlProven {
                    Section {
                        Label("Direct control verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Quiet/Aware and EQ changes were read back. Your original settings were restored.")
                    }
                }
                Section {
                    Text("The detailed result is saved locally in Files → On My iPhone → QuietControl → ControlProof.json.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Connection inspection") {
                        session.beginInspection(); showingInspection = true
                    }.disabled(session.isWorking)
                }
            }
            .navigationTitle("QuietControl")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(session.isVerifying) } }
            .sheet(isPresented: $showingInspection, onDismiss: { session.endInspection() }) { ConnectionCheckView(probe: probe) }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--verify-direct-control") {
                    do { try await session.connectRemembered(); await session.verifyDirectControl() }
                    catch { /* The session presents and records its specific failure. */ }
                }
            }
        }.tint(Color(red: 0.09, green: 0.42, blue: 0.36))
    }
}
