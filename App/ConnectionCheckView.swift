import SwiftUI
import UniformTypeIdentifiers

struct ConnectionCheckView: View {
    @ObservedObject var probe: BluetoothProbe
    @Environment(\.dismiss) private var dismiss
    @State private var showAllDevices = false
    @State private var exporting = false
    @State private var document = ProbeReportDocument(data: Data())
    @State private var exportError: String?
    @State private var showingAbout = false
    private let accent = Color(red: 0.09, green: 0.42, blue: 0.36)

    private var devices: [NearbyDevice] {
        probe.nearby.filter { showAllDevices || $0.looksLikeBose || $0.source == "Remembered selection" }
            .sorted { lhs, rhs in
                if lhs.looksLikeBose != rhs.looksLikeBose { return lhs.looksLikeBose }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    connectionCard
                    nearbyCard
                    if let selected = probe.report.selectedPeripheral { inspectionCard(selected) }
                    reportCard
                    accessoryCard
                    Text("QuietControl is an independent open-source project. Inspect the local Bluetooth services and identity of your QuietComfort headphones.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("QuietControl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { probe.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                        .labelStyle(.iconOnly)
                }
            }
            .tint(accent)
            .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                          defaultFilename: "QuietControl-connection-report") { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
            .alert("Could not export report", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "") }
            .sheet(isPresented: $showingAbout) { aboutView }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "headphones")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(accent)
                    .frame(width: 66, height: 66)
                    .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your QuietComfort.\nA simpler remote.")
                        .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                    Text("Connection inspection").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text("Before adding modes and EQ, we need to check the connection your headphones expose to an iPhone app. This check leaves your headphone settings as they are.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Check your connection", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
            Text(probe.message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("connectionMessage")
            if probe.phase.isBusy {
                HStack { ProgressView(); Text(probe.phase == .scanning ? "Scanning…" : "Inspecting…").font(.subheadline) }
                Button("Stop check", role: .cancel) { probe.cancel() }.buttonStyle(.bordered)
            } else {
                Button { probe.startScan() } label: {
                    Label(probe.phase == .idle && probe.report.events.isEmpty ? "Check connection" : "Check connection again", systemImage: "wave.3.right")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("startConnectionCheck")
            }
            if probe.phase == .unavailable {
                Link("Open QuietControl settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .font(.subheadline.weight(.medium))
            }
            Text("Turn on your QC and connect it in iPhone Settings → Bluetooth. Keep the headphones nearby during the check.")
                .font(.footnote).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private var nearbyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose your headphones").font(.headline)
            if devices.isEmpty {
                Text(probe.phase == .scanning ? "Your QC will appear here when iOS makes it available." : "No matching headphones listed yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                Button { probe.connect(to: device) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.looksLikeBose ? "headphones" : "wave.3.right")
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).fontWeight(.medium).foregroundStyle(.primary)
                            Text(device.source == "Remembered selection" ? "Previously selected" : "Tap to inspect")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }.contentShape(Rectangle()).padding(.vertical, 8)
                }
                .disabled([.connecting, .discovering, .reading].contains(probe.phase))
            }
            Toggle("Show all nearby devices", isOn: $showAllDevices).font(.subheadline)
            Text("Use Show all if your QC has a custom name. Device names alone do not confirm the headphone model.")
                .font(.footnote).foregroundStyle(.secondary)
        }.cardStyle()
    }

    private func inspectionCard(_ selected: PeripheralReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(selected.name, systemImage: "headphones").font(.headline)
            Text(selected.identityEvidence).font(.footnote).foregroundStyle(.secondary)
            ForEach(selected.standardReadings.sorted(by: { $0.key < $1.key }), id: \.key) { reading in
                LabeledContent(metadataName(reading.key), value: reading.value).font(.subheadline)
            }
            DisclosureGroup("Bluetooth service details (\(selected.services.count))") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(selected.services) { service in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(service.uuid).font(.caption.monospaced().bold()).textSelection(.enabled)
                            if let error = service.discoveryError { Text(error).font(.caption).foregroundStyle(.secondary) }
                            ForEach(service.characteristics) { characteristic in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(characteristic.uuid).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(characteristic.properties.joined(separator: ", "))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.padding(.top, 8)
            }.font(.subheadline)
        }.cardStyle()
    }

    private var reportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection report", systemImage: "doc.text.magnifyingglass").font(.headline)
            Text("Finding services is the first step. Mode switching and EQ control still need to be proven on your headphones.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                do { document = try probe.exportDocument(); exporting = true }
                catch { exportError = error.localizedDescription }
            } label: { Label("Export report", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered).disabled(probe.report.events.isEmpty)
            Text("A local copy is also saved as LatestProbe.json in Files → On My iPhone → QuietControl. No report is uploaded automatically.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error = probe.persistenceError { Text(error).font(.footnote).foregroundStyle(.red) }
            DisclosureGroup("Inspection log") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(probe.report.events) { event in
                        Text("\(event.date.formatted(date: .omitted, time: .standard))  \(event.message)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.subheadline)
        }.cardStyle()
    }

    private var accessoryCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if probe.report.accessories.isEmpty {
                    Text("No accessories were exposed to this app through External Accessory. This result alone cannot rule out a manufacturer-authorized connection.")
                }
                ForEach(probe.report.accessories) { accessory in
                    Text("\(accessory.name) · \(accessory.model)").fontWeight(.medium)
                    Text(accessory.exposedProtocols.joined(separator: "\n")).font(.caption.monospaced())
                }
                Button("Refresh accessory information") { probe.refreshAccessories() }
            }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
        } label: { Label("Other connection information", systemImage: "cable.connector").font(.subheadline) }
            .cardStyle()
    }

    private var aboutView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("QuietControl 0.1.0").font(.title2.bold())
                    Text("Built for Bose QuietComfort Headphones. Direct mode and EQ controls have been verified on standard QuietComfort hardware.")
                    Link("bosectl protocol reference", destination: URL(string: "https://github.com/aaronsb/bosectl")!)
                    Text(attribution).font(.footnote).textSelection(.enabled)
                }.padding()
            }
            .navigationTitle("About")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAbout = false } } }
        }
    }

    private var attribution: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Protocol reference: bosectl. Copyright (c) 2026 Aaron Bockelie. MIT License. See the repository's THIRD_PARTY_NOTICES.md."
        }
        return text
    }

    private func metadataName(_ uuid: String) -> String {
        ["2A19": "Battery", "2A24": "Model", "2A26": "Firmware", "2A28": "Software", "2A29": "Manufacturer", "2A50": "Product identity"][uuid.uppercased()] ?? uuid
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

