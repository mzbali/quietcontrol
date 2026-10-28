import SwiftUI

private enum QCTheme {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.34, green: 0.81, blue: 0.70, alpha: 1)
            : UIColor(red: 0.08, green: 0.39, blue: 0.33, alpha: 1)
    })
    static func battery(_ level: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            if level >= 50 { return dark ? UIColor(red: 0.40, green: 0.82, blue: 0.55, alpha: 1) : UIColor(red: 0.09, green: 0.44, blue: 0.24, alpha: 1) }
            if level >= 20 { return dark ? UIColor(red: 0.92, green: 0.77, blue: 0.36, alpha: 1) : UIColor(red: 0.55, green: 0.39, blue: 0.04, alpha: 1) }
            return dark ? UIColor(red: 0.94, green: 0.47, blue: 0.47, alpha: 1) : UIColor(red: 0.72, green: 0.18, blue: 0.21, alpha: 1)
        })
    }
    static let onAccent = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    /// Opaque secondary text. The hierarchical `.secondary` style composites to
    /// roughly a 2.6–3.4:1 ratio on grouped cards, below the 4.5:1 text minimum.
    /// These explicit greys keep secondary labels above 6:1 on the app's real
    /// surfaces in both appearances without turning decorative strokes into text.
    static let secondaryText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.76, alpha: 1)
            : UIColor(white: 0.32, alpha: 1)
    })
    /// Labels and enabled toolbar actions that must read as primary chrome.
    static let toolbarText = Color(uiColor: .label)
}

struct QuietControlView: View {
    @ObservedObject var session: QuietComfortSession
    @ObservedObject var probe: BluetoothProbe
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// In UI-test mode the launch configuration supplies the accessibility size
    /// for descendants via `.environment`, but this root view's own environment
    /// still reports the system default. Mirror the same size here so the root
    /// layout (header and mode list) genuinely reflows, as it does for a user who
    /// selects an accessibility text size in Settings.
    private var layoutTypeSize: DynamicTypeSize {
        #if DEBUG && targetEnvironment(simulator)
        if session.environment.isTestMode,
           ProcessInfo.processInfo.environment["QUIETCONTROL_TEST_LARGE_TEXT"] == "1" {
            return .accessibility3
        }
        #endif
        return dynamicTypeSize
    }
    @State private var showingInfo = false
    @State private var showingSettings = false
    @State private var editingMode: ListeningMode?
    @State private var showingEQ = false
    @State private var showingInspection = false
    @State private var showingControlCheck = false
    @State private var showingDeviceCheck = false
    @State private var showingConnection = false
    @State private var showingAllDevices = false
    @State private var confirmingDisconnectAll = false
    @State private var confirmingMultipointOff = false
    @State private var pendingMode: UInt8?
    @State private var replacementTarget: PairedAudioDevice?

    private var canControl: Bool { session.isConnected && session.hasVerifiedDirectControl && !session.controlsBusy && pendingMode == nil }
    private var canManage: Bool { canControl && session.deviceControlsVerified && session.hasLiveDeviceList }
    private var featuredMode: ListeningMode? {
        session.modes.first { $0.index > 1 && $0.promptID == 13 } ?? session.modes.first { $0.index > 1 }
    }
    private var homeDevices: [PairedAudioDevice] {
        guard session.devices.count > 4 else { return session.devices }
        let ordered = session.devices.filter(\.isConnected) + session.devices.filter { !$0.isConnected }
        return Array(ordered.prefix(4))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                dashboard
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Home").toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingEQ) { EqualizerView(session: session) }
            .refreshable { await session.refresh() }
            .sheet(isPresented: $showingSettings) { HeadphoneSettingsView(session: session, probe: probe, inspect: {
                showingSettings = false
                Task { try? await Task.sleep(nanoseconds: 400_000_000); openInspection() }
            }) }
            .sheet(item: $editingMode) { selected in ModeEditorView(session: session, selected: selected) }
            .sheet(isPresented: $showingInfo) { DeviceInfoView(session: session) }
            .sheet(isPresented: $showingConnection) { ConnectionDetailsView(session: session) }
            .sheet(isPresented: $showingInspection, onDismiss: { probe.cancel(); session.endInspection() }) { ConnectionCheckView(probe: probe) }
            .sheet(isPresented: $showingControlCheck) { ControlCheckView(session: session, probe: probe).interactiveDismissDisabled(session.isVerifying) }
            .sheet(isPresented: $showingDeviceCheck) { DeviceCheckView(session: session) }
            .sheet(isPresented: $showingAllDevices) {
                NavigationStack {
                    List { ForEach(session.devices) { device in deviceRow(device) } }
                        .navigationTitle("All devices").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAllDevices = false } } }
                }
            }
            .confirmationDialog("Turn off multipoint?", isPresented: $confirmingMultipointOff, titleVisibility: .visible) {
                Button("Turn off multipoint") { Task { await session.setMultipointEnabled(false) } }
            } message: { Text("Your QC will disconnect its second audio device and keep one connected.") }
            .confirmationDialog("Disconnect all audio devices?", isPresented: $confirmingDisconnectAll, titleVisibility: .visible) {
                Button("Disconnect all audio devices", role: .destructive) { Task { await session.disconnectAllAudioDevices() } }
            } message: { Text("Audio devices will disconnect. QuietControl’s control connection stays available.") }
            .sheet(item: $replacementTarget) { target in
                NavigationStack {
                    List {
                        Section {
                            ForEach(session.devices.filter(\.isConnected)) { device in
                                Button {
                                    replacementTarget = nil
                                    Task { await session.connectAudioDevice(target.address, replacing: device.address) }
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(device.name).foregroundStyle(.primary)
                                        Text(device.address == session.activeAudioAddress ? "Active audio" : "Connected").font(.caption).foregroundStyle(QCTheme.secondaryText)
                                    }.padding(.vertical, 4)
                                }.disabled(!canManage)
                            }
                        } header: { Text("Disconnect one to connect \(target.name)") }
                    }.navigationTitle("Choose a device").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { replacementTarget = nil } } }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: session.isConnected) { _, connected in if !connected { replacementTarget = nil } }
            .task {
                session.startIfNeeded()
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--preview-eq") { showingEQ = true }
                if ProcessInfo.processInfo.arguments.contains("--preview-editor") { editingMode = session.modes.first { $0.editable } }
                if ProcessInfo.processInfo.arguments.contains("--preview-settings") { showingSettings = true }
                if ProcessInfo.processInfo.arguments.contains("--render-dashboard") { renderDashboard() }
                if ProcessInfo.processInfo.arguments.contains("--render-feedback-components") { renderFeedbackComponents() }
                #endif
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                    if scenePhase == .active && !showingInspection && !showingControlCheck && !showingDeviceCheck { await session.refresh() }
                }
            }
        }.tint(QCTheme.accent).modifier(QCFeedbackOverlay(session: session))
            .modifier(QCUITestPresentation(testMode: session.environment.isTestMode))
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if session.hasKnownProfile {
                if session.isConnected && !session.hasVerifiedDirectControl {
                    Button("Finish setup", systemImage: "checkmark.shield") { showingControlCheck = true }.font(.subheadline)
                }
                listeningModes
                devicesPanel
                equalizerRow
            } else { setupPrompt }
        }.padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: 620).frame(maxWidth: .infinity)
    }

    private var header: some View {
        Group {
            if layoutTypeSize.isAccessibilitySize {
                // At accessibility sizes the badge and gear keep their row, and the
                // title/status get the full card width so words are never hyphenated
                // into fragments by a narrow side column.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        headphoneBadge
                        Spacer(minLength: 0)
                        settingsButton
                    }
                    connectionDetailsButton {
                        VStack(alignment: .leading, spacing: 6) {
                            headphoneTitle
                            connectionLabel
                            batteryBadge
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    connectionDetailsButton {
                        HStack(spacing: 12) {
                            headphoneBadge
                            VStack(alignment: .leading, spacing: 4) {
                                headphoneTitle
                                HStack(spacing: 10) { connectionLabel; batteryBadge }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    settingsButton
                }
            }
        }.frame(minHeight: 56)
    }
    private var headphoneTitle: some View {
        Text("Bose QuietComfort").font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("headphone-title")
    }
    private func connectionDetailsButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button { showingConnection = true } label: { content() }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .accessibilityHint("Show connection details and last-seen information")
            .accessibilityIdentifier("connection-details")
    }
    private var settingsButton: some View {
        Button { showingSettings = true } label: {
            Image(systemName: "gearshape").font(.body).foregroundStyle(QCTheme.accent)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
        }.accessibilityLabel("Headphone settings")
    }
    private var headphoneBadge: some View {
        Image(systemName: "headphones").font(.system(size: 23, weight: .light))
            .foregroundStyle(QCTheme.accent).frame(width: 42, height: 42)
            .background(QCTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
    private var connectionLabel: some View {
        HStack(spacing: 6) {
            Circle().fill(session.isConnected ? Color.green : Color.secondary.opacity(0.6)).frame(width: 5, height: 5)
            Text(session.connectionState.title).font(.caption).foregroundStyle(QCTheme.secondaryText)
            if session.connectionState == .connecting { ProgressView().controlSize(.mini).accessibilityIdentifier("connecting-spinner") }
        }.frame(minHeight: 20, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("connection-status")
            .accessibilityLabel(session.connectionState.title)
            .accessibilityValue(session.isConnected ? "Live" : "Offline")
    }
    @ViewBuilder private var batteryBadge: some View {
        if session.isConnected, let battery = session.battery {
            HStack(spacing: 4) {
                BatteryLevelIcon(level: battery).frame(width: 24, height: 13)
                Text("\(battery)%").font(.caption.monospacedDigit())
            }.foregroundStyle(QCTheme.battery(battery))
                .fixedSize().accessibilityElement(children: .ignore)
                .accessibilityIdentifier("battery-level")
                .accessibilityLabel("Battery \(battery) percent")
        }
    }
    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.hasRememberedDevice ? "Turn on your QC to load its controls." : "Your QC, simply controlled.").font(.headline)
            Text(session.hasRememberedDevice ? "Your modes and devices will stay here after the first successful connection." : "Connect your QuietComfort once to remember its modes, devices and equalizer.")
                .font(.subheadline).foregroundStyle(QCTheme.secondaryText)
            Button(session.hasRememberedDevice ? "Connection details" : "Find my QuietComfort") {
                if session.hasRememberedDevice { showingConnection = true } else { openInspection() }
            }.buttonStyle(.bordered).accessibilityIdentifier("find-headphones")
        }.zenPanel()
    }
    private func openInspection() { session.beginInspection(); showingInspection = true }

    /// Quiet first, custom modes next, Aware last: ordered by how much of the world they let in.
    private var orderedModes: [ListeningMode] {
        let custom = session.modes.filter { $0.index > 1 }
        let featured = featuredMode.map { [$0] } ?? []
        return session.modes.filter { $0.index == 0 } + featured + custom.filter { $0.index != featuredMode?.index }
            + session.modes.filter { $0.index == 1 }
    }
    private func modeIcon(_ mode: ListeningMode) -> String {
        mode.index == 0 ? "moon.fill" : mode.index == 1 ? "ear" : mode.index == featuredMode?.index ? "lightbulb" : "slider.horizontal.3"
    }
    private func modeDescription(_ mode: ListeningMode) -> String {
        if mode.index == 0 { return "Noise cancelling · Max" }
        if mode.index == 1 { return "Lets your surroundings in" }
        if mode.windBlock { return "Wind Block · Max cancelling" }
        let strength = max(0, min(10, mode.ancStrength))
        return strength == 10 ? "Noise cancelling · Max" : strength == 0 ? "No noise cancelling" : "Noise cancelling · \(strength) of 10"
    }

    private var listeningModes: some View {
        VStack(spacing: 8) {
            if let current = session.modes.first(where: { $0.index == session.mode }) { modeHero(current) }
            if layoutTypeSize.isAccessibilitySize {
                VStack(spacing: 8) { ForEach(orderedModes) { modeSegment($0) } }
            } else {
                HStack(spacing: 4) { ForEach(orderedModes) { modeSegment($0) } }
                    .padding(4).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Listening modes")
    }
    private func modeHero(_ mode: ListeningMode) -> some View {
        let live = session.isConnected
        let strength = mode.windBlock ? 10 : max(0, min(10, mode.ancStrength))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(mode.displayName).font(.title.weight(.bold)).foregroundStyle(live ? .primary : QCTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(live ? "Hold to edit" : "Last used").font(.caption2).foregroundStyle(Color.primary)
            }
            Text(modeDescription(mode)).font(.caption).foregroundStyle(Color.primary)
            HStack(spacing: 3) {
                ForEach(0..<10, id: \.self) { step in
                    Capsule().fill(step < strength ? (live ? QCTheme.accent : Color.secondary.opacity(0.55)) : Color.primary.opacity(0.10))
                        .frame(height: 6)
                }
            }.animation(.easeInOut(duration: 0.3), value: strength)
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [QCTheme.accent.opacity(live ? 0.13 : 0.04), Color(uiColor: .secondarySystemGroupedBackground)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onLongPressGesture(minimumDuration: 0.5) { openModeEditor(mode.index) }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("current-mode")
        .accessibilityLabel(live ? "Current mode, \(mode.displayName)" : "Last used mode, \(mode.displayName)")
        .accessibilityValue(modeDescription(mode))
        .accessibilityAction(named: "Edit mode") { openModeEditor(mode.index) }
    }
    private func modeSegment(_ mode: ListeningMode) -> some View {
        let index = mode.index, title = mode.displayName
        let selected = session.isConnected && session.mode == index
        let lastUsed = !session.isConnected && session.mode == index
        let stacked = layoutTypeSize.isAccessibilitySize
        let icon = Group {
            if pendingMode == index { ProgressView().tint(selected ? QCTheme.onAccent : QCTheme.accent) }
            else { Image(systemName: modeIcon(mode)).font(.body) }
        }.frame(height: 22)
        return Group {
            if stacked {
                HStack(spacing: 10) {
                    icon
                    Text(title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill") }
                }.padding(14)
            } else {
                VStack(spacing: 4) {
                    icon
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }.padding(.vertical, 9).padding(.horizontal, 4)
            }
        }
        .foregroundStyle(selected ? QCTheme.onAccent : session.isConnected ? QCTheme.secondaryText : Color.secondary.opacity(0.7))
        .frame(maxWidth: .infinity, minHeight: stacked ? 58 : 54)
        .background(selected ? QCTheme.accent : lastUsed ? Color.primary.opacity(0.10) : stacked ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                    in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .gesture(LongPressGesture(minimumDuration: 0.5).exclusively(before: TapGesture()).onEnded { gesture in
            switch gesture {
            case .first: openModeEditor(index)
            case .second: switchMode(index)
            }
        })
        .animation(.easeOut(duration: 0.18), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("mode-\(index)")
        .accessibilityLabel(lastUsed ? "\(title), last used" : title)
        .accessibilityValue(selected ? "Selected" : session.isConnected ? "" : "Unavailable")
        .accessibilityAddTraits([.isButton])
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Tap to switch. Hold to view or edit this mode.")
        .accessibilityAction { switchMode(index) }
        .accessibilityAction(named: "Edit mode") { openModeEditor(index) }
    }
    private func switchMode(_ index: UInt8) {
        guard canControl else { return }
        pendingMode = index
        Task {
            await session.selectMode(index)
            if session.mode == index && session.failure == nil { UISelectionFeedbackGenerator().selectionChanged() }
            pendingMode = nil
        }
    }
    private func openModeEditor(_ index: UInt8) {
        guard let selected = session.modes.first(where: { $0.index == index }) else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        editingMode = selected
    }

    private var phoneDevice: PairedAudioDevice? {
        homeDevices.first { $0.isController } ?? homeDevices.first { $0.address == session.controllerAddress }
    }
    private var otherDevices: [PairedAudioDevice] { homeDevices.filter { $0.address != phoneDevice?.address } }
    private func isHighlighted(_ device: PairedAudioDevice) -> Bool { session.isConnected && session.hasLiveDeviceList && device.isConnected }

    private var devicesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.isConnected ? "Devices" : "Saved devices").font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if session.devices.count > 4 { Button("View all") { showingAllDevices = true }.font(.caption).frame(minHeight: 44) }
                else if session.isConnected, let multi = session.multipoint, !layoutTypeSize.isAccessibilitySize {
                    Text(multi ? "Multipoint" : "Single device").font(.caption2.weight(.semibold))
                        .foregroundStyle(multi ? QCTheme.accent : QCTheme.secondaryText)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((multi ? QCTheme.accent : Color.secondary).opacity(0.14), in: Capsule())
                }
                devicesMenu
            }.frame(minHeight: 44).padding(.horizontal, 2)
            if session.devices.isEmpty {
                Text(session.isConnected ? "No paired devices were reported." : "No saved devices yet.")
                    .font(.subheadline).foregroundStyle(QCTheme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).zenCard()
            } else {
                if let phone = phoneDevice { deviceRow(phone).padding(.horizontal, 12).zenCard() }
                if !otherDevices.isEmpty {
                    if phoneDevice != nil {
                        Text("OTHER DEVICES").font(.caption2.weight(.semibold)).foregroundStyle(QCTheme.secondaryText)
                            .padding(.horizontal, 6).padding(.top, 6)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(otherDevices.enumerated()), id: \.element.id) { offset, device in
                            pickRow(device)
                            // Highlighted rows carry their own outline; only plain neighbours need a divider.
                            if offset + 1 < otherDevices.count, !isHighlighted(device), !isHighlighted(otherDevices[offset + 1]) {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }.padding(3).zenCard()
                }
            }
            if session.isConnected && !session.deviceControlsVerified {
                Button("Check device controls") { showingDeviceCheck = true }.font(.caption).frame(minHeight: 44)
            }
        }
    }
    /// Tap a device to hear it. When the slots are full and exactly one other device can make room,
    /// swap in one tap (with Undo); otherwise ask which device should disconnect.
    private func selectDevice(_ device: PairedAudioDevice) {
        guard canManage, !device.isConnected else { return }
        switch try? DeviceConnectionPlanner.plan(target: device.address, devices: session.devices, multipoint: session.multipoint == true) {
        case .connect: Task { await session.connectAudioDevice(device.address) }
        case .chooseReplacement(let connected):
            let candidates = connected.filter { $0 != phoneDevice?.address }
            if candidates.count == 1, let old = session.devices.first(where: { $0.address == candidates[0] }) {
                UISelectionFeedbackGenerator().selectionChanged()
                Task { await session.swapAudioDevice(to: device.address, replacing: old.address) }
            } else { replacementTarget = device }
        default: break
        }
    }
    private func pickRow(_ device: PairedAudioDevice) -> some View {
        let current = session.isConnected && session.hasLiveDeviceList
        let connected = isHighlighted(device)
        let active = connected && device.address == session.activeAudioAddress
        let swaps: Bool = {
            guard current, !device.isConnected, case .chooseReplacement(let occupied)? = try? DeviceConnectionPlanner.plan(
                target: device.address, devices: session.devices, multipoint: session.multipoint == true) else { return false }
            return occupied.filter { $0 != phoneDevice?.address }.count == 1
        }()
        let status = !current ? "Unavailable" : active ? "Active audio" : connected ? "Connected" : swaps ? "Tap to switch" : "Tap to connect"
        return Button { selectDevice(device) } label: {
            HStack(spacing: 12) {
                Image(systemName: deviceIcon(device)).font(.system(size: 21))
                    .foregroundStyle(connected ? QCTheme.accent : .secondary).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.subheadline).foregroundStyle(current ? .primary : QCTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(status).font(.caption2).foregroundStyle(active ? QCTheme.accent : QCTheme.secondaryText)
                }
                Spacer(minLength: 4)
                Group {
                    if session.pendingDevice == device.address { ProgressView().controlSize(.small) }
                    else if active { Image(systemName: "waveform").foregroundStyle(QCTheme.accent) }
                    else if connected { Image(systemName: "checkmark.circle.fill").foregroundStyle(QCTheme.accent) }
                    else if current { Image(systemName: "circle").foregroundStyle(.tertiary) }
                }.font(.body).frame(width: 28)
            }
            .padding(.horizontal, 10).frame(minHeight: 54)
            .background(connected ? QCTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay { if connected { RoundedRectangle(cornerRadius: 14).strokeBorder(QCTheme.accent.opacity(0.45), lineWidth: 1.2) } }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(!current)
        .contextMenu {
            if connected {
                Button("Disconnect", systemImage: "link", role: .destructive) { Task { await session.disconnectAudioDevice(device.address) } }
                    .disabled(!canManage)
            } else if current {
                Button("Connect", systemImage: "link") { selectDevice(device) }.disabled(!canManage)
            }
        }
        .animation(.easeOut(duration: 0.2), value: connected)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("device-\(device.name.replacingOccurrences(of: " ", with: "-"))")
        .accessibilityLabel(device.name)
        .accessibilityValue(status)
        .accessibilityAddTraits(connected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(connected ? "Connected. Use actions to disconnect." : swaps ? "Switches audio to this device." : "Connects this device.")
        .accessibilityActions {
            if connected { Button("Disconnect") { Task { await session.disconnectAudioDevice(device.address) } } }
        }
    }
    private var devicesMenu: some View {
        Menu {
            Button("Refresh devices", systemImage: "arrow.clockwise") { Task { await session.refresh() } }.disabled(!canControl)
            if session.multipointVerified, let multi = session.multipoint {
                Button(multi ? "Turn multipoint off" : "Turn multipoint on", systemImage: "personalhotspot") {
                    if multi && session.devices.filter(\.isConnected).count > 1 { confirmingMultipointOff = true }
                    else { Task { await session.setMultipointEnabled(!multi) } }
                }.disabled(!canManage)
            }
            Button("Disconnect all audio devices", systemImage: "link", role: .destructive) { confirmingDisconnectAll = true }
                .disabled(!canManage || !session.disconnectAllVerified || !session.devices.contains(where: \.isConnected))
        } label: { Image(systemName: "ellipsis").font(.body).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel("Device actions").accessibilityIdentifier("device-actions")
    }
    private func deviceRow(_ device: PairedAudioDevice) -> some View {
        let current = session.isConnected && session.hasLiveDeviceList
        return HStack(spacing: 12) {
            Image(systemName: deviceIcon(device))
                .font(.system(size: 22, weight: .regular)).foregroundStyle(current && device.isConnected ? QCTheme.accent : .secondary).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                Text(deviceStatus(device, current: current))
                    .font(.caption2).foregroundStyle(QCTheme.secondaryText)
                if current && device.isConnected && device.address != session.activeAudioAddress && session.routingVerified {
                    Button("Use audio") { Task { await session.useAudioDevice(device.address) } }.font(.caption).disabled(!canManage)
                }
            }
            Spacer(minLength: 4)
            if session.pendingDevice == device.address { ProgressView().controlSize(.mini) }
            if current {
                Toggle("Connect \(device.name)", isOn: Binding(get: { device.isConnected }, set: { value in
                    if value {
                        let plan = try? DeviceConnectionPlanner.plan(target: device.address, devices: session.devices, multipoint: session.multipoint == true)
                        if case .chooseReplacement = plan { replacementTarget = device }
                        else { Task { await session.connectAudioDevice(device.address) } }
                    } else { Task { await session.disconnectAudioDevice(device.address) } }
                })).labelsHidden().fixedSize().disabled(!canManage)
            } else {
                Image(systemName: "minus").foregroundStyle(.tertiary).frame(width: 51, height: 31)
                    .accessibilityLabel("Connection unavailable")
            }
        }.frame(minHeight: 54).padding(.vertical, 2)
    }
    private func deviceStatus(_ device: PairedAudioDevice, current: Bool) -> String {
        let state = !current ? "Unavailable" : device.isConnected && device.address == session.activeAudioAddress ? "Active audio"
            : device.isConnected ? "Connected" : device.isController ? "Controls only" : "Disconnected"
        return device.address == phoneDevice?.address ? "This iPhone · \(state)" : state
    }
    private func deviceIcon(_ device: PairedAudioDevice) -> String {
        let name = device.name.lowercased()
        if device.address == session.controllerAddress || name.contains("iphone") || name.contains("phone") { return "iphone" }
        if name.contains("ipad") || name.contains("tablet") { return "ipad" }
        if name.contains("desktop") || name.contains("imac") || name.contains("mac mini") { return "desktopcomputer" }
        if name.contains("laptop") || name.contains("macbook") || name.contains("notebook") { return "laptopcomputer" }
        return "rectangle.connected.to.line.below" // Unknown names are not assumed to be a laptop.
    }

    private var equalizerRow: some View {
        Button { showingEQ = true } label: {
            Group {
                if layoutTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Equalizer").font(.subheadline)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
                        }
                        EQMiniature(values: session.eq.map(\.value)).frame(width: 154, height: 44)
                    }
                } else {
                    HStack(spacing: 10) {
                        Text("Equalizer").font(.subheadline)
                        Spacer(minLength: 8)
                        if session.eq.count == 3 { EQMiniature(values: session.eq.map(\.value)).frame(width: 176, height: 48) }
                        Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(.tertiary)
                    }
                }
            }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 64)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(.plain).accessibilityElement(children: .ignore)
            .accessibilityIdentifier("equalizer-row")
            .accessibilityLabel("Equalizer, \(eqSummary)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(session.isConnected ? "Adjust your equalizer" : "View last-known equalizer, read only")
    }
    private var eqSummary: String { session.eq.map { $0.value > 0 ? "+\($0.value)" : "\($0.value)" }.joined(separator: " / ") }

    #if DEBUG && targetEnvironment(simulator)
    @MainActor private func renderFeedbackComponents() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for scheme in [ColorScheme.dark, .light] {
            let view = VStack(alignment: .leading, spacing: 20) {
                ForEach([100, 50, 49, 20, 19, 0], id: \.self) { level in
                    HStack {
                        BatteryLevelIcon(level: level).frame(width: 24, height: 13)
                        Text("\(level)%").font(.caption.monospacedDigit())
                    }.foregroundStyle(QCTheme.battery(level))
                }
                ForEach([[-1, 4, 2], [-10, 10, -10], [10, -10, 10]], id: \.self) { values in
                    HStack { Text("Equalizer").font(.subheadline); Spacer(); EQMiniature(values: values).frame(width: 154, height: 42) }
                        .padding(12).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                }
                ForEach([QCFeedback(text: "Quiet selected", symbol: "moon"), QCFeedback(text: "EQ saved", symbol: "eq.curve"), QCFeedback(text: "Device connected", symbol: "link")]) { item in
                    HStack { Image(systemName: item.symbol == "eq.curve" ? "waveform.path" : item.symbol); Text(item.text) }.font(.caption)
                }
            }.padding(20).frame(width: 360).environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
            UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light).performAsCurrent {
                let renderer = ImageRenderer(content: view); renderer.scale = 2
                if let image = renderer.uiImage { try? image.pngData()?.write(to: documents.appendingPathComponent("FeedbackComponents-\(scheme == .dark ? "dark" : "light").png")) }
            }
        }
    }

    @MainActor private func renderDashboard() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for scheme in [ColorScheme.light, .dark] {
            let largeText = ProcessInfo.processInfo.arguments.contains("--preview-large")
            let content = dashboard.environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
                .background(scheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: 430, height: nil); renderer.scale = 2
            let eqRenderer = ImageRenderer(content: EqualizerView(session: session).content.frame(width: 430)
                .environment(\.colorScheme, scheme).background(scheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground)))
            eqRenderer.scale = 2
            let editors = VStack(spacing: 16) { ForEach(session.modes) { ModeEditorView(session: session, selected: $0).hero } }
                .padding(20).frame(width: 430).environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color.black : Color(uiColor: .systemGroupedBackground))
            let editorRenderer = ImageRenderer(content: editors); editorRenderer.scale = 2
            if let image = editorRenderer.uiImage { try? image.pngData()?.write(to: documents.appendingPathComponent("Editor430-\(scheme == .dark ? "dark" : "light").png")) }
            if let image = eqRenderer.uiImage { try? image.pngData()?.write(to: documents.appendingPathComponent("EQ430-\(scheme == .dark ? "dark" : "light").png")) }
            if let image = renderer.uiImage {
                let name = "Home430-\(session.connectionState.rawValue)-\(scheme == .dark ? "dark" : "light")\(largeText ? "-accessibility" : "")"
                try? image.pngData()?.write(to: documents.appendingPathComponent(name + ".png"))
                let report: [String: Any] = ["width": image.size.width, "height": image.size.height, "availableHeight": 795, "fits": image.size.height <= 795, "state": session.connectionState.rawValue, "modeCount": session.modes.count, "deviceCount": session.devices.count]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: documents.appendingPathComponent(name + ".json"))
                }
            }
        }
    }
    #endif
}

private struct ConnectionDetailsView: View {
    @ObservedObject var session: QuietComfortSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(session.connectionState.title, systemImage: session.isConnected ? "checkmark.circle" : "headphones")
                    if let date = session.lastConfirmedAt { LabeledContent("Last seen", value: date.formatted(date: .abbreviated, time: .shortened)) }
                    if !session.isConnected, let battery = session.battery { LabeledContent("Last-known battery", value: "\(battery)%") }
                    if session.connectionState == .waitingForQC || session.connectionState == .connecting {
                        Text("Turn on your QC and keep it nearby. QuietControl will connect automatically. The physical power switch and moving out of range can both make the headphones unavailable.")
                    }
                    if session.connectionState == .bluetoothOff { Text("Turn Bluetooth on in iPhone Settings or Control Center. Auto-connect will resume if enabled.") }
                    if session.connectionState == .permissionNeeded {
                        Button("Open QuietControl settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                    if session.connectionState == .unavailable { Button("Try connection again") { Task { try? await session.connectRemembered() } } }
                    Button(session.autoConnectEnabled ? "Pause auto-connect" : "Resume auto-connect") {
                        if session.autoConnectEnabled { session.disconnect() } else { session.resumeAutoConnect() }
                    }.accessibilityIdentifier(session.autoConnectEnabled ? "pause-auto-connect" : "resume-auto-connect")
                }
                if let error = session.failure { Section("Details") { Text(error).font(.footnote).foregroundStyle(QCTheme.secondaryText) } }
                if let error = session.deviceListFailure { Section("Device list") { Text(error).font(.footnote).foregroundStyle(QCTheme.secondaryText) } }
            }.navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct SavedEQPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var values: [Int]
}

private struct EqualizerView: View {
    @ObservedObject var session: QuietComfortSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editing = false
    @State private var activeBand: Int?
    @State private var pendingBand: Int?
    @State private var previewValues: [Int]?
    @State private var presets: [SavedEQPreset] = []
    @State private var namingPreset = false
    @State private var presetName = ""
    private var displayed: [Int] { previewValues ?? session.eq.map(\.value) }
    private var enabled: Bool { session.isConnected && session.hasVerifiedDirectControl && !session.controlsBusy }
    var content: some View {
            VStack(spacing: 24) {
                if session.hasKnownProfile && session.eq.count == 3 {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 14) {
                            ForEach(0..<3) { index in
                                HStack {
                                    Text(["Bass", "Mid", "Treble"][index]).foregroundStyle(QCTheme.secondaryText)
                                    Spacer()
                                    Text(signed(displayed[index])).fontWeight(.semibold).monospacedDigit()
                                        .foregroundStyle(activeBand == index ? QCTheme.accent : .primary)
                                        .accessibilityIdentifier("eq-value-\(index)")
                                        .overlay(alignment: .trailing) { if pendingBand == index { ProgressView().controlSize(.mini).offset(x: 20) } }
                                }.font(.title3)
                            }
                        }.padding(.top, 16)
                    } else {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(0..<3) { index in
                            VStack(spacing: 8) {
                                Text(["Bass", "Mid", "Treble"][index]).font(.subheadline)
                                    .foregroundStyle(activeBand == index ? QCTheme.accent : QCTheme.secondaryText)
                                Text(signed(displayed[index])).font(.title2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(activeBand == index ? QCTheme.accent : .primary)
                                    .accessibilityIdentifier("eq-value-\(index)")
                                    .overlay(alignment: .bottom) { if pendingBand == index { ProgressView().controlSize(.mini).offset(y: 25) } }

                            }.frame(maxWidth: .infinity)
                        }
                    }.padding(.top, 24)
                    }
                    InteractiveEQCurve(values: displayed, activeBand: activeBand, enabled: enabled && pendingBand == nil,
                        preview: { index, value in
                            if !editing {
                                editing = true; session.setEditingEQ(true); previewValues = session.eq.map(\.value)
                                #if DEBUG && targetEnvironment(simulator)
                                session.recordTestEvent("eq gesture begin band \(index) confirmed \(session.eq.map(\.value))")
                                #endif
                            }
                            guard activeBand == nil || activeBand == index else { return }
                            activeBand = index
                            if previewValues?[index] != value { UISelectionFeedbackGenerator().selectionChanged() }
                            previewValues?[index] = value
                            #if DEBUG && targetEnvironment(simulator)
                            session.recordTestEvent("eq preview band \(index) = \(value)")
                            #endif
                        }, commit: { index in
                            #if DEBUG && targetEnvironment(simulator)
                            session.recordTestEvent("eq gesture end band \(index) preview \(previewValues.map { String($0[index]) } ?? "none")")
                            #endif
                            commitBand(index)
                        })
                        .frame(height: dynamicTypeSize.isAccessibilitySize ? 300 : 270)
                    Text(session.isConnected ? "Drag a point · saves when you let go" : "Saved EQ · Reconnect to adjust.")
                        .font(.footnote).foregroundStyle(QCTheme.secondaryText)
                    presetsGrid
                    if !session.isConnected, let date = session.lastConfirmedAt {
                        Text("Last confirmed \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(QCTheme.secondaryText)
                    }
                } else { ContentUnavailableView("Connect your QC", systemImage: "headphones", description: Text("Reconnect to read and adjust your equalizer.")) }
                if session.isConnected, let error = session.failure { Text(error).font(.footnote).foregroundStyle(.red) }
            }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
    }
    var body: some View {
        ScrollView { content }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Equalizer").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let data = session.environment.defaults.data(forKey: "quietcontrol.eqPresets"),
               let saved = try? JSONDecoder().decode([SavedEQPreset].self, from: data) {
                presets = saved.filter { $0.values.count == 3 && $0.values.allSatisfy { (-10...10).contains($0) } }
            }
            #if DEBUG && targetEnvironment(simulator)
            session.recordTestEvent("eq presets loaded \(presets.count): \(presets.map(\.name).joined(separator: ","))")
            #endif
        }
        .onChange(of: session.isConnected) { _, connected in if !connected { endEditing() } }
        .onDisappear { endEditing() }
        .alert("Save current EQ", isPresented: $namingPreset) {
            TextField("Preset name", text: $presetName).accessibilityIdentifier("preset-name")
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = String(presetName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))
                guard !name.isEmpty, session.eq.count == 3 else { return }
                presets.append(SavedEQPreset(name: name, values: session.eq.map(\.value))); savePresets()
            }
        }
    }

    /// Flat plus the user's own presets, each with a miniature curve. The live EQ is
    /// highlighted when it matches a card; otherwise a "Custom" card shows it.
    private var presetsGrid: some View {
        let current = session.eq.map(\.value)
        let cards: [(id: String, name: String, values: [Int], saved: SavedEQPreset?)] =
            [("flat", "Flat", [0, 0, 0], nil)] + presets.map { ($0.id.uuidString, $0.name, $0.values, $0) }
        let matches = cards.contains { $0.values == current }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Presets").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Save current", systemImage: "plus") { presetName = ""; namingPreset = true }
                    .font(.subheadline).disabled(!enabled || editing || current.count != 3)
                    .padding(.vertical, 13).contentShape(Rectangle())
                    .accessibilityIdentifier("save-preset")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                if !matches && current.count == 3 { presetCard(name: "Custom", values: current, selected: true, subtitle: "Current") }
                ForEach(cards, id: \.id) { card in
                    let selected = card.values == current
                    Button {
                        guard !selected else { return }
                        Task { if card.id == "flat" { await session.resetEQ() } else { await session.applyEQ(card.values) } }
                    } label: { presetCard(name: card.name, values: card.values, selected: selected, subtitle: selected ? "Current" : nil) }
                    .buttonStyle(.plain).disabled(!enabled || editing)
                    .accessibilityIdentifier("preset-\(card.name)")
                    .contextMenu {
                        if let saved = card.saved {
                            Button("Delete preset", systemImage: "trash", role: .destructive) {
                                presets.removeAll { $0.id == saved.id }; savePresets()
                            }
                        }
                    }
                    .accessibilityHint(card.saved != nil ? "Applies this preset. Use actions to delete it." : "Applies this preset.")
                    .accessibilityActions {
                        if let saved = card.saved { Button("Delete preset") { presets.removeAll { $0.id == saved.id }; savePresets() } }
                    }
                }
            }
            if presets.isEmpty {
                Text("Save a sound you like, then return to it in one tap.").font(.caption).foregroundStyle(QCTheme.secondaryText)
            }
        }.padding(.top, 8)
    }
    private func presetCard(name: String, values: [Int], selected: Bool, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PresetCurve(values: values).stroke(selected ? QCTheme.accent : Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(height: 24)
            Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(subtitle ?? values.map(signed).joined(separator: " · ")).font(.caption)
                .foregroundStyle(selected ? QCTheme.accent : QCTheme.secondaryText)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? QCTheme.accent.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay { if selected { RoundedRectangle(cornerRadius: 14).strokeBorder(QCTheme.accent.opacity(0.5), lineWidth: 1.3) } }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(values.map(signed).joined(separator: ", "))\(selected ? ", current" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
    private func savePresets() { if let data = try? JSONEncoder().encode(presets) { session.environment.defaults.set(data, forKey: "quietcontrol.eqPresets") } }
    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    private func endEditing() { editing = false; activeBand = nil; previewValues = nil; session.setEditingEQ(false) }
    private func commitBand(_ index: Int) {
        guard let values = previewValues, pendingBand == nil, session.eq.count == 3 else { endEditing(); return }
        guard values[index] != session.eq[index].value else { endEditing(); return }
        pendingBand = index
        Task {
            await session.setEQ(EQBand(rawValue: UInt8(index))!, value: values[index])
            pendingBand = nil; endEditing()
        }
    }
}

private struct InteractiveEQCurve: View {
    let values: [Int]
    let activeBand: Int?
    let enabled: Bool
    let preview: (Int, Int) -> Void
    let commit: (Int) -> Void
    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 28
            let width = max(1, proxy.size.width - inset * 2)
            let center = proxy.size.height / 2
            let scale = max(1, center - 28) / 10
            let points = values.enumerated().map { index, value in CGPoint(x: inset + CGFloat(index) * width / 2, y: center - CGFloat(value) * scale) }
            ZStack {
                ForEach([-10, 0, 10], id: \.self) { value in
                    Path { p in
                        let y = center - CGFloat(value) * scale
                        p.move(to: CGPoint(x: inset, y: y)); p.addLine(to: CGPoint(x: inset + width, y: y))
                    }.stroke(Color.secondary.opacity(value == 0 ? 0.25 : 0.10), lineWidth: 1)
                    Text(value > 0 ? "+\(value)" : "\(value)").font(.system(size: 11).monospacedDigit()).foregroundStyle(QCTheme.secondaryText)
                        .position(x: 8, y: center - CGFloat(value) * scale)
                }
                curve(points).addingLine(to: CGPoint(x: points.last?.x ?? 0, y: proxy.size.height), from: CGPoint(x: points.first?.x ?? 0, y: proxy.size.height))
                    .fill(LinearGradient(colors: [QCTheme.accent.opacity(0.22), QCTheme.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                curve(points).stroke(QCTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                if let active = activeBand, points.indices.contains(active) {
                    let point = points[active]
                    Path { p in p.move(to: CGPoint(x: point.x, y: 8)); p.addLine(to: CGPoint(x: point.x, y: proxy.size.height - 8)) }
                        .stroke(QCTheme.accent.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Text(values[active] > 0 ? "+\(values[active])" : "\(values[active])")
                        .font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(QCTheme.onAccent)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(QCTheme.accent, in: Capsule())
                        .position(x: min(max(point.x, 24), proxy.size.width - 24), y: max(14, point.y - 30))
                        .accessibilityHidden(true)
                }
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle().fill(activeBand == index ? QCTheme.accent : Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(Circle().stroke(QCTheme.accent, lineWidth: 2.5))
                        .background(Circle().fill(QCTheme.accent.opacity(activeBand == index ? 0.25 : 0)).padding(-7))
                        .frame(width: activeBand == index ? 22 : 19, height: activeBand == index ? 22 : 19)
                        .frame(width: 48, height: 48).contentShape(Rectangle()).position(point)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("eqCurve"))
                            .onChanged { value in
                                guard enabled, activeBand == nil || activeBand == index else { return }
                                preview(index, max(-10, min(10, Int(((center - value.location.y) / scale).rounded()))))
                            }.onEnded { _ in if activeBand == index { commit(index) } })
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("eq-point-\(index)")
                        .accessibilityLabel(["Bass", "Mid", "Treble"][index])
                        .accessibilityValue("\(values[index])")
                        .accessibilityAdjustableAction { direction in
                            guard enabled else { return }
                            let next = max(-10, min(10, values[index] + (direction == .increment ? 1 : -1)))
                            preview(index, next); commit(index)
                        }
                }
            }.coordinateSpace(name: "eqCurve")
        }
    }
    private func curve(_ points: [CGPoint]) -> Path {
        Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            for index in 1..<points.count {
                let previous = points[index - 1], next = points[index], middle = (previous.x + next.x) / 2
                p.addCurve(to: next, control1: CGPoint(x: middle, y: previous.y), control2: CGPoint(x: middle, y: next.y))
            }
        }
    }
}

private struct DeviceCheckView: View {
    @ObservedObject var session: QuietComfortSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Check that your QC can connect and disconnect audio devices while keeping this app connected. Audio will briefly stop. Starting connections and multipoint will be restored.")
                    Button("Verify device controls") { Task { await session.verifyDeviceControls() } }
                        .disabled(session.isWorking || !session.isConnected)
                    if session.isWorking { ProgressView(session.message) }
                    if session.deviceControlsVerified { Label("Connect and disconnect verified", systemImage: "checkmark.circle.fill").foregroundStyle(QCTheme.accent) }
                    Text(session.message)
                    if let failure = session.failure { Text(failure).foregroundStyle(.red) }
                }
            }.navigationTitle("Device controls").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(session.isWorking) } }
        }.interactiveDismissDisabled(session.isWorking)
    }
}

private struct DeviceInfoView: View {
    @ObservedObject var session: QuietComfortSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Your QuietComfort") {
                    LabeledContent("Manufacturer", value: session.manufacturer.isEmpty ? "Not read yet" : session.manufacturer)
                    LabeledContent("Model", value: session.model.isEmpty ? "Not read yet" : session.model)
                    LabeledContent("Firmware", value: session.firmware.isEmpty ? "Not read yet" : session.firmware)
                    if let time = session.connectionTime { LabeledContent("Last connection", value: String(format: "%.1f seconds", time)) }
                }
                Section("QuietControl") {
                    Text("An independent, open-source remote for Bose QuietComfort Headphones. Settings are stored on the headphones.")
                    LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    Link("Source protocol: bosectl", destination: URL(string: "https://github.com/aaronsb/bosectl")!)
                    Link("BLE transport reference: bozo", destination: URL(string: "https://github.com/NerdySouth/bozo")!)
                    DisclosureGroup("Open-source licenses") { Text(notices).font(.caption).textSelection(.enabled) }
                }
            }
            .navigationTitle("Device & about")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private var notices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return "See THIRD_PARTY_NOTICES.md in the source repository." }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "See THIRD_PARTY_NOTICES.md in the source repository."
    }
}

private extension View {
    func qcCard() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

private extension View {
    func zenCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
    func zenPanel() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct ModeEditorView: View {
    @ObservedObject var session: QuietComfortSession
    let selected: ListeningMode
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var strength: Double
    @State private var wind: Bool
    @State private var dirty = false
    @State private var saving = false
    @State private var error: String?
    init(session: QuietComfortSession, selected: ListeningMode) {
        self.session = session; self.selected = selected
        _strength = State(initialValue: Double(selected.ancStrength)); _wind = State(initialValue: selected.windBlock)
    }
    private var live: ListeningMode { session.modes.first { $0.index == selected.index } ?? selected }
    private var enabled: Bool { live.editable && session.isConnected && session.hasVerifiedDirectControl && session.modeEditingVerified && !session.controlsBusy && !saving }
    private var level: Int { wind ? 10 : Int(strength) }
    private var summary: String {
        if !live.editable { return selected.index == 0 ? "Full noise cancelling · fixed" : "Lets your surroundings in · fixed" }
        if wind { return "Wind Block · Max cancelling" }
        return level == 10 ? "Noise cancelling · Max" : level == 0 ? "No noise cancelling" : "Noise cancelling · \(level) of 10"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    if live.editable {
                        Text("EXTRAS").font(.caption2.weight(.semibold)).foregroundStyle(QCTheme.secondaryText).padding(.horizontal, 4)
                        Toggle(isOn: Binding(get: { wind }, set: { value in
                            wind = value; dirty = true
                            if value { strength = 10 }
                            UISelectionFeedbackGenerator().selectionChanged()
                        })) {
                            HStack(spacing: 12) {
                                Image(systemName: "wind").font(.system(size: 13, weight: .semibold)).foregroundStyle(.blue)
                                    .frame(width: 28, height: 28).background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wind Block")
                                    Text("For outdoors. Locks cancelling to max.").font(.caption).foregroundStyle(QCTheme.secondaryText)
                                }
                            }
                        }
                        .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .disabled(!enabled).accessibilityIdentifier("wind-block")
                        if !session.isConnected { Text("Saved settings · Reconnect to edit.").font(.footnote).foregroundStyle(QCTheme.secondaryText) }
                        else if !session.modeEditingVerified {
                            Button("Verify mode editing") { Task { await session.verifyModeEditing() } }
                                .disabled(session.controlsBusy)
                            Text("Checks strength and Wind Block, then restores this mode’s settings.").font(.footnote).foregroundStyle(QCTheme.secondaryText)
                        }
                        Text("Nothing changes on your QC until you save.").font(.caption).foregroundStyle(QCTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Bose fixes Quiet and Aware. Tune a custom mode such as Focus instead.", systemImage: "lock")
                            .font(.footnote).foregroundStyle(QCTheme.secondaryText).padding(.horizontal, 4)
                            .accessibilityIdentifier("mode-locked-note")
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }.padding(20)
                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 32 : 0)
                    .frame(maxWidth: 620).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                if live.editable {
                    // Opaque chrome behind the pinned action: at accessibility
                    // sizes tall content would otherwise remain visible through
                    // the translucent disabled button.
                    VStack(spacing: 0) {
                        Button(action: save) {
                            HStack { Spacer(); if saving { ProgressView().tint(QCTheme.onAccent) }; Text("Save \(live.displayName)").fontWeight(.semibold); Spacer() }
                                .padding(15)
                        }.foregroundStyle(QCTheme.onAccent)
                            .background(QCTheme.accent.opacity(enabled && dirty ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 15))
                            .disabled(!enabled || !dirty)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .accessibilityIdentifier("mode-save-bottom")
                    }.background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(live.displayName).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                // Keep both top actions on an opaque, pinned surface. Unlike the
                // sheet navigation bar, this row remains available while scrolling.
                HStack {
                    Button { if !saving { dismiss() } } label: {
                        Text(live.editable ? "Cancel" : "Done")
                            .font(.body)
                            .foregroundStyle(QCTheme.accent)
                            .padding(.horizontal, 4).padding(.vertical, 10)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    .accessibilityIdentifier("mode-cancel")
                    Spacer(minLength: 0)
                    if live.editable {
                        Button(action: save) {
                            Text("Save").font(.body.weight(.semibold))
                                .foregroundStyle(QCTheme.toolbarText)
                                .padding(.horizontal, 4).padding(.vertical, 10)
                                .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled || !dirty)
                        .opacity(enabled && dirty ? 1 : 0.45)
                        // Retain the existing identifier for the top Save action.
                        .accessibilityIdentifier("mode-save-toolbar")
                    }
                }.padding(.horizontal, 20)
                    .background(Color(uiColor: .systemGroupedBackground))
            }
            .task { await session.refreshModes(); if !dirty { strength = Double(live.ancStrength); wind = live.windBlock } }
        }.tint(QCTheme.accent).presentationDetents([.large]).interactiveDismissDisabled(saving || dirty)
    }
    var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(live.displayName).font(.title.weight(.bold))
                Spacer()
                if dirty { Text("Edited · not saved").font(.caption.weight(.semibold)).foregroundStyle(QCTheme.accent)
                    .accessibilityIdentifier("mode-dirty") }
            }
            Text(summary).font(.subheadline).foregroundStyle(Color.primary).accessibilityIdentifier("mode-summary")
            StrengthMeter(value: Binding(get: { Double(level) }, set: { strength = $0; dirty = true }),
                          saved: live.editable && dirty ? (live.windBlock ? 10 : live.ancStrength) : nil,
                          enabled: enabled && !wind, locked: !live.editable || wind)
                .padding(.top, 6)
            HStack {
                Label("Hear the world", systemImage: "ear")
                Spacer()
                Label("Block it out", systemImage: "moon.fill").labelStyle(TrailingIconLabelStyle())
            }.font(.caption2).foregroundStyle(Color.primary)
            if live.editable && dirty { Text("┆ marks the saved level").font(.caption2).foregroundStyle(Color.primary) }
        }
        .padding(16)
        .background(LinearGradient(colors: [QCTheme.accent.opacity(0.13), Color(uiColor: .secondarySystemGroupedBackground)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }
    private func save() {
        saving = true; error = nil
        Task {
            let success = await session.saveMode(selected.index, strength: Int(strength), windBlock: wind)
            saving = false
            if success { UINotificationFeedbackGenerator().notificationOccurred(.success); dismiss() }
            else { error = session.failure ?? "The change was not confirmed. Reconnect and try again." }
        }
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 4) { configuration.title; configuration.icon } }
}

/// Ten tappable/draggable steps: the same meter as the Home hero, made editable.
private struct StrengthMeter: View {
    @Binding var value: Double
    let saved: Int?
    let enabled: Bool
    let locked: Bool
    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 4
            let step = (proxy.size.width - spacing * 9) / 10
            ZStack(alignment: .leading) {
                HStack(spacing: spacing) {
                    ForEach(0..<10, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 7)
                            .fill(index < Int(value) ? (locked ? Color.secondary.opacity(0.5) : QCTheme.accent) : Color.primary.opacity(0.10))
                    }
                }
                if let saved, saved > 0, saved < 10 {
                    Capsule().fill(Color.primary.opacity(0.45)).frame(width: 2, height: proxy.size.height + 8)
                        .offset(x: CGFloat(saved) * (step + spacing) - spacing / 2 - 1)
                }
            }
            .animation(.easeOut(duration: 0.15), value: value)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard enabled else { return }
                let next = Double(max(0, min(10, Int((gesture.location.x / max(1, proxy.size.width) * 10).rounded(.up)))))
                if next != value { UISelectionFeedbackGenerator().selectionChanged(); value = next }
            })
        }
        .frame(height: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("mode-strength")
        .accessibilityLabel("Noise cancellation")
        .accessibilityValue("\(Int(value)) of 10\(locked ? ", fixed" : "")")
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            value = max(0, min(10, value + (direction == .increment ? 1 : -1)))
        }
    }
}

private struct HeadphoneSettingsView: View {
    @ObservedObject var session: QuietComfortSession
    @ObservedObject var probe: BluetoothProbe
    let inspect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingInfo = false
    @State private var showingModeCheck = false
    @State private var showingDeviceCheck = false
    @State private var showingConnection = false
    @State private var confirmingMultipointOff = false
    @State private var showingDiagnostics = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var selfVoice: String {
        guard let data = session.preferencePackets["selfVoice"], data.count >= 2 else { return "Not read" }
        return [0: "Off", 1: "High", 2: "Medium", 3: "Low"][Int(data[1])] ?? "Unavailable"
    }
    private var voicePrompts: Bool { (session.preferencePackets["voicePrompts"]?.first ?? 0) & 0x20 != 0 }
    private var shortcut: String {
        guard let data = session.preferencePackets["shortcut"], data.count >= 3 else { return "Not read" }
        return [3: "Battery level", 14: "Off", 16: "Spotify"][Int(data[2])] ?? "Unavailable"
    }
    private static let autoOffChoices: [(UInt8, String)] = [(5, "5 minutes"), (20, "20 minutes"), (40, "40 minutes"), (60, "1 hour"), (180, "3 hours"), (0, "Never")]
    private var autoOff: String {
        guard let data = session.preferencePackets["autoOff"], data.count == 1 else { return "Not read" }
        return Self.autoOffChoices.first { $0.0 == data[0] }?.1 ?? "Unavailable"
    }
    private var rememberMode: Bool { session.preferencePackets["rememberMode"] == Data([1]) }
    private func enabled(_ name: String) -> Bool { session.isConnected && (session.verifiedPreferences.contains(name) || name == "voicePrompts") && !session.controlsBusy && session.preferencePackets[name] != nil }
    private static let autoOffShort: [UInt8: String] = [5: "5m", 20: "20m", 40: "40m", 60: "1h", 180: "3h", 0: "Never"]
    private var autoOffValue: UInt8? { session.preferencePackets["autoOff"].flatMap { $0.count == 1 ? $0[0] : nil } }
    private var identity: String {
        let model = session.model.isEmpty ? nil : session.model.split(separator: "-").first.map(String.init)
        let firmware = session.firmware.isEmpty ? nil : "firmware " + (session.firmware.split(separator: "-").first.map(String.init) ?? session.firmware)
        return [model, firmware].compactMap { $0 }.joined(separator: " · ").ifEmpty("Details appear after connecting")
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingInfo = true } label: {
                        let layout = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                            : AnyLayout(HStackLayout(spacing: 14))
                        layout {
                            Image(systemName: "headphones").font(.system(size: 24, weight: .light)).foregroundStyle(QCTheme.accent)
                                .frame(width: 48, height: 48).background(QCTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Bose QuietComfort").font(.headline).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("settings-headphone-title")
                                Text(identity).font(.caption).foregroundStyle(QCTheme.secondaryText)
                            }
                            if !dynamicTypeSize.isAccessibilitySize {
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                            }
                        }.padding(.vertical, 4)
                    }.tint(.primary).accessibilityHint("Shows model, firmware and open-source licenses")
                }
                Section {
                    NavigationLink {
                        List {
                            ForEach([(0, "Off"), (1, "High"), (2, "Medium"), (3, "Low")], id: \.0) { choice in
                                Button { Task { await session.setPreference("selfVoice", value: UInt8(choice.0)) } } label: {
                                    HStack { Text(choice.1).foregroundStyle(.primary); Spacer(); if choice.1 == selfVoice { Image(systemName: "checkmark") } }
                                }.disabled(!enabled("selfVoice"))
                                    .accessibilityIdentifier("self-voice-\(choice.0)")
                            }
                            Section { Text("Adjust how much of your own voice you hear while on a call.").foregroundStyle(QCTheme.secondaryText) }
                        }.navigationTitle("Self Voice")
                    } label: { settingLabel("Self Voice", symbol: "mic.fill", tint: .purple, value: selfVoice) }
                    NavigationLink {
                        List {
                            ForEach([(3, "Hear battery level"), (16, "Spotify"), (14, "Off")], id: \.0) { choice in
                                Button { Task { await session.setPreference("shortcut", value: UInt8(choice.0)) } } label: {
                                    HStack { Text(choice.1).foregroundStyle(.primary); Spacer(); if shortcut == [3: "Battery level", 16: "Spotify", 14: "Off"][choice.0] { Image(systemName: "checkmark") } }
                                }.disabled(!enabled("shortcut"))
                                    .accessibilityIdentifier("shortcut-\(choice.0)")
                            }
                            Section { Text("Press and hold the Action button on the left earcup. Spotify requires the Spotify app.").foregroundStyle(QCTheme.secondaryText) }
                        }.navigationTitle("Button Shortcut")
                    } label: { settingLabel("Button Shortcut", symbol: "hand.tap.fill", tint: .orange, value: shortcut == "Battery level" ? "Battery" : shortcut) }
                    Toggle(isOn: Binding(get: { voicePrompts }, set: { value in Task { await session.setPreference("voicePrompts", value: value ? 1 : 0) } })) {
                        settingLabel("Voice Prompts", symbol: "speaker.wave.2.fill", tint: .blue)
                    }.disabled(!enabled("voicePrompts")).accessibilityIdentifier("voice-prompts")
                }
                Section {
                    if dynamicTypeSize.isAccessibilitySize {
                        NavigationLink {
                            List {
                                ForEach(Self.autoOffChoices, id: \.0) { choice in
                                    Button { Task { await session.setPreference("autoOff", value: choice.0) } } label: {
                                        HStack { Text(choice.1).foregroundStyle(.primary); Spacer(); if choice.1 == autoOff { Image(systemName: "checkmark") } }
                                    }.disabled(!enabled("autoOff"))
                                        .accessibilityIdentifier("auto-off-\(choice.0)")
                                }
                            }.navigationTitle("Auto-Off")
                        } label: { settingLabel("Auto-Off", symbol: "power", tint: QCTheme.accent, value: autoOff) }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                settingLabel("Auto-Off", symbol: "power", tint: QCTheme.accent)
                                Spacer()
                                Text(autoOff).font(.subheadline).foregroundStyle(autoOffValue == nil ? QCTheme.secondaryText : QCTheme.accent)
                                    .accessibilityIdentifier("auto-off-value")
                            }
                            HStack(spacing: 5) {
                                ForEach(Self.autoOffChoices, id: \.0) { choice in
                                    let selected = autoOffValue == choice.0
                                    Button { if !selected { Task { await session.setPreference("autoOff", value: choice.0) } } } label: {
                                        Text(Self.autoOffShort[choice.0] ?? choice.1).font(.caption.weight(.semibold))
                                            .frame(maxWidth: .infinity, minHeight: 32)
                                            .foregroundStyle(selected ? QCTheme.onAccent : QCTheme.secondaryText)
                                            .background(selected ? QCTheme.accent : Color.primary.opacity(0.08), in: Capsule())
                                    }
                                    .buttonStyle(.plain).disabled(!enabled("autoOff"))
                                    .accessibilityLabel(choice.1).accessibilityAddTraits(selected ? .isSelected : [])
                                    .accessibilityIdentifier("auto-off-\(choice.0)")
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                    Toggle(isOn: Binding(get: { rememberMode }, set: { value in Task { await session.setPreference("rememberMode", value: value ? 1 : 0) } })) {
                        settingLabel("Remember My Mode", symbol: "arrow.counterclockwise", tint: QCTheme.accent, detail: "Starts in the last mode you used")
                    }.disabled(!enabled("rememberMode")).accessibilityIdentifier("remember-mode")
                } header: { Text("Power").foregroundStyle(QCTheme.secondaryText) }
                if session.isConnected && !Set(["selfVoice", "shortcut"]).isSubset(of: session.verifiedPreferences) {
                    Section {
                        Button("Verify headphone settings") { Task { await session.verifyPreferences() } }.disabled(session.controlsBusy)
                        Text("Checks Self Voice and the button shortcut, then restores their original values.").font(.footnote).foregroundStyle(QCTheme.secondaryText)
                    }
                }
                Section("Connection") {
                    if let multi = session.multipoint {
                        Toggle(isOn: Binding(get: { session.multipoint ?? multi }, set: { value in
                            if !value && session.devices.filter(\.isConnected).count > 1 { confirmingMultipointOff = true }
                            else { Task { await session.setMultipointEnabled(value) } }
                        })) { settingLabel("Multipoint", symbol: "rectangle.on.rectangle", tint: .gray, detail: "Two devices connected at once") }
                            .disabled(!session.isConnected || !session.multipointVerified || session.controlsBusy)
                    }
                    Toggle(isOn: Binding(get: { session.autoConnectEnabled }, set: { value in
                        if value { session.resumeAutoConnect() } else { session.disconnect() }
                    })) { settingLabel("Auto-connect", symbol: "antenna.radiowaves.left.and.right", tint: .gray) }
                }
                if !session.isConnected { Section { } footer: { Text("Connect your QC to read headphone preferences.").frame(maxWidth: .infinity) } }
                if let error = session.preferencesFailure ?? session.failure { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Menu {
                            Button("Connection details", systemImage: "antenna.radiowaves.left.and.right") { showingConnection = true }
                            Button("Diagnostics", systemImage: "stethoscope") { showingDiagnostics = true }
                        } label: { Label("More", systemImage: "ellipsis") }
                            .tint(QCTheme.toolbarText)
                    }
                    if session.isWorking { ToolbarItem(placement: .status) { ProgressView().controlSize(.mini) } }
                }
                .safeAreaInset(edge: .top) {
                    // Kept out of the sheet navigation bar for the same reason as
                    // the mode editor's dismiss action: the audit cannot resolve
                    // glass toolbar labels. Same identifier and behaviour, with
                    // explicit accent text on the sheet's grouped background.
                    HStack {
                        Spacer(minLength: 0)
                        Button { dismiss() } label: {
                            Text("Done")
                                .font(.body)
                                .foregroundStyle(QCTheme.accent)
                                .padding(.horizontal, 4).padding(.vertical, 10)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-done")
                    }.padding(.horizontal, 20)
                        .background(Color(uiColor: .systemGroupedBackground))
                }
                .navigationDestination(isPresented: $showingDiagnostics) {
                    List {
                        Button("Refresh headphone settings") { Task { await session.refreshPreferences() } }.disabled(!session.isConnected || session.controlsBusy)
                        Button("Verify mode editing") { Task { await session.verifyModeEditing() } }.disabled(!session.isConnected || session.controlsBusy)
                        Button("Verify headphone settings") { Task { await session.verifyPreferences() } }.disabled(!session.isConnected || session.controlsBusy)
                        Button("Verify mode & EQ controls") { showingModeCheck = true }.disabled(!session.isConnected || session.isWorking)
                        Button("Verify device controls") { showingDeviceCheck = true }.disabled(!session.isConnected || session.isWorking)
                        Button("Connection inspection", action: inspect).disabled(session.isWorking)
                        if let evidence = session.testModeEvidence {
                            Section("Test mode evidence") {
                                Text(evidence)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("test-mode-evidence")
                                    .accessibilityLabel("Test mode evidence")
                                    .accessibilityValue(evidence)
                            }
                        }
                        if let transcript = session.testTranscript {
                            Section("Test transcript") {
                                Text(transcript)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("test-transcript")
                                    .accessibilityLabel("Test transcript")
                                    .accessibilityValue(transcript)
                            }
                        }
                    }.navigationTitle("Diagnostics")
                }
                .confirmationDialog("Turn off multipoint?", isPresented: $confirmingMultipointOff, titleVisibility: .visible) {
                    Button("Turn off multipoint") { Task { await session.setMultipointEnabled(false) } }
                } message: { Text("Your QC will disconnect its second audio device and keep one connected.") }
                .task { await session.refreshPreferences() }
                .sheet(isPresented: $showingInfo) { DeviceInfoView(session: session) }
                .sheet(isPresented: $showingModeCheck) { ControlCheckView(session: session, probe: probe) }
                .sheet(isPresented: $showingDeviceCheck) { DeviceCheckView(session: session) }
                .sheet(isPresented: $showingConnection) { ConnectionDetailsView(session: session) }
        }.tint(QCTheme.accent).modifier(QCFeedbackOverlay(session: session))
    }
}


private extension HeadphoneSettingsView {
    /// iOS Settings-style row label: a small tinted symbol tile, title, optional detail and value.
    func settingLabel(_ title: String, symbol: String, tint: Color, value: String? = nil, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 28, height: 28).background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(QCTheme.secondaryText) }
                if dynamicTypeSize.isAccessibilitySize, let value {
                    Text(value).foregroundStyle(QCTheme.secondaryText).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !dynamicTypeSize.isAccessibilitySize, let value { Spacer(minLength: 8); Text(value).foregroundStyle(QCTheme.secondaryText) }
        }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private struct BatteryLevelIcon: View {
    let level: Int
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .path(in: CGRect(x: 0.75, y: 1.5, width: 20.5, height: 10))
                .stroke(lineWidth: 1).opacity(0.65)
            RoundedRectangle(cornerRadius: 0.8)
                .path(in: CGRect(x: 22.2, y: 4.7, width: 1.7, height: 3.6)).opacity(0.65)
            RoundedRectangle(cornerRadius: 1)
                .path(in: CGRect(x: 3, y: 3.7, width: 16 * CGFloat(max(0, min(100, level))) / 100, height: 5.6))
        }.accessibilityHidden(true)
    }
}

private struct PresetCurve: Shape {
    let values: [Int]
    func path(in rect: CGRect) -> Path {
        let points = values.prefix(3).enumerated().map { index, value in
            CGPoint(x: rect.minX + CGFloat(index) * rect.width / 2, y: rect.midY - CGFloat(max(-10, min(10, value))) * (rect.height / 2 - 1) / 10)
        }
        return Path { p in
            guard let first = points.first else { return }
            p.move(to: first)
            for index in 1..<points.count {
                let previous = points[index - 1], next = points[index], middle = (previous.x + next.x) / 2
                p.addCurve(to: next, control1: CGPoint(x: middle, y: previous.y), control2: CGPoint(x: middle, y: next.y))
            }
        }
    }
}

private extension Path {
    /// Closes an open curve down to a baseline so it can be filled.
    func addingLine(to end: CGPoint, from start: CGPoint) -> Path {
        var path = self; path.addLine(to: end); path.addLine(to: start); path.closeSubpath(); return path
    }
}

private struct EQMiniature: View {
    let values: [Int]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        GeometryReader { proxy in
            let textSize: CGFloat = dynamicTypeSize.isAccessibilitySize ? 13 : 9
            let minY = textSize + 5
            let maxY = max(minY, proxy.size.height - 3)
            let midpoint = (minY + maxY) / 2
            let step = (maxY - minY) / 20
            let points = values.prefix(3).enumerated().map { index, value in
                CGPoint(x: 8 + CGFloat(index) * max(0, proxy.size.width - 16) / 2,
                        y: midpoint - CGFloat(max(-10, min(10, value))) * step)
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for index in 1..<points.count {
                        let previous = points[index - 1], next = points[index], middle = (previous.x + next.x) / 2
                        path.addCurve(to: next, control1: CGPoint(x: middle, y: previous.y), control2: CGPoint(x: middle, y: next.y))
                    }
                }.stroke(QCTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Circle().fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(Circle().stroke(QCTheme.accent, lineWidth: 1))
                        .frame(width: 3.5, height: 3.5).position(point)
                    Text(values[index] > 0 ? "+\(values[index])" : "\(values[index])")
                        .font(.system(size: textSize).monospacedDigit()).foregroundStyle(Color.primary)
                        .position(x: point.x, y: point.y - textSize / 2 - 5)
                }
            }
        }.accessibilityHidden(true)
    }
}

private struct QCUITestPresentation: ViewModifier {
    let testMode: Bool
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG && targetEnvironment(simulator)
        if testMode {
            let environment = ProcessInfo.processInfo.environment
            let scheme: ColorScheme? = environment["QUIETCONTROL_TEST_APPEARANCE"] == "dark" ? .dark
                : environment["QUIETCONTROL_TEST_APPEARANCE"] == "light" ? .light : nil
            content
                .preferredColorScheme(scheme)
                .environment(\.dynamicTypeSize,
                             environment["QUIETCONTROL_TEST_LARGE_TEXT"] == "1" ? .accessibility3 : .large)
                .accessibilityIdentifier("appearance-\(scheme == .dark ? "dark" : scheme == .light ? "light" : "system")")
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct QCFeedbackOverlay: ViewModifier {
    @ObservedObject var session: QuietComfortSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let feedback = session.toast {
                HStack(spacing: 7) {
                    Group {
                        if feedback.symbol == "link.slash" {
                            BrokenLinkSymbol().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        } else if feedback.symbol == "eq.curve" {
                            FeedbackEQSymbol().stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        } else { Image(systemName: feedback.symbol).font(.caption) }
                    }.foregroundStyle(feedback.isError ? Color.red : QCTheme.accent).frame(width: 14, height: 14)
                    Text(feedback.text).font(.caption).multilineTextAlignment(.center)
                        .accessibilityIdentifier("feedback-toast")
                    if feedback.undo != nil {
                        Button("Undo") { Task { await session.undoSwap(feedback) } }
                            .font(.caption.weight(.semibold)).foregroundStyle(QCTheme.accent)
                            .padding(.leading, 6).frame(minHeight: 32).disabled(session.controlsBusy)
                            .accessibilityIdentifier("undo-swap")
                    }
                }
                .foregroundStyle(.primary).padding(.horizontal, 14).padding(.vertical, 10)
                .background(scheme == .dark ? Color(red: 0.18, green: 0.21, blue: 0.19) : Color(red: 0.89, green: 0.93, blue: 0.90), in: RoundedRectangle(cornerRadius: 13))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.horizontal, 24).padding(.bottom, 18)
                .allowsHitTesting(feedback.undo != nil).accessibilityElement(children: feedback.undo != nil ? .contain : .combine)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 7)))
                .id(feedback.id)
            }
        }.animation(.easeOut(duration: reduceMotion ? 0.15 : 0.22), value: session.toast?.id)
    }
}

private struct BrokenLinkSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 8, y: 4))
        path.addCurve(to: CGPoint(x: 16, y: 10), control1: CGPoint(x: 16, y: -2), control2: CGPoint(x: 23, y: 6))
        path.move(to: CGPoint(x: 12, y: 16))
        path.addCurve(to: CGPoint(x: 4, y: 10), control1: CGPoint(x: 4, y: 22), control2: CGPoint(x: -3, y: 14))
        path.move(to: CGPoint(x: 3, y: 2)); path.addLine(to: CGPoint(x: 17, y: 18))
        return path.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20))
    }
}

private struct FeedbackEQSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2, y: 14))
        path.addCurve(to: CGPoint(x: 10, y: 6), control1: CGPoint(x: 6, y: 14), control2: CGPoint(x: 6, y: 6))
        path.addCurve(to: CGPoint(x: 18, y: 9), control1: CGPoint(x: 14, y: 6), control2: CGPoint(x: 14, y: 9))
        for point in [CGPoint(x: 2, y: 14), CGPoint(x: 10, y: 6), CGPoint(x: 18, y: 9)] {
            path.addEllipse(in: CGRect(x: point.x - 1.1, y: point.y - 1.1, width: 2.2, height: 2.2))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 20, y: rect.height / 20))
    }
}
