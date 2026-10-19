import SwiftUI

// MARK: - Tabs

enum Panel: String, CaseIterable, Identifiable {
    case sound
    case gestures
    case device

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sound: return "Sound"
        case .gestures: return "Gestures"
        case .device: return "Device"
        }
    }

    /// Kept for callers that still describe the tab as a string.
    var description: String { title }

    var symbol: String {
        switch self {
        case .sound: return "waveform"
        case .gestures: return "hand.tap"
        case .device: return "earbuds"
        }
    }
}

// MARK: - Sound panel

struct SoundPanel: View {
    @ObservedObject var state: DeviceState

    @State private var mode: NoiseMode = .off
    @State private var cancelling: CancellingLevel = .normal
    @State private var awareness: AwarenessMode = .standard
    @State private var preset: EQPreset?
    @State private var autoPause = false
    @State private var lowLatency = false
    @State private var preference: SoundPreference = .quality

    private var connected: Bool { state.isConnected }

    private var cancellingOptions: [CancellingLevel] {
        state.profile.anc?.levels ?? []
    }

    private var presets: [EQPreset] {
        let offered = state.snapshot.offeredPresets
        return offered.isEmpty ? (state.profile.eq?.builtIns ?? []) : offered
    }

    private var hasBehaviourControls: Bool {
        state.profile.autoPause || state.profile.lowLatency || state.profile.soundPreference
    }

    // Bindings are the only place a user edit starts a device write. The
    // snapshot observers below merely copy device state into the local @State
    // values, so a poll can never bounce back into the earbuds as a write.
    private var cancellingSelection: Binding<CancellingLevel> {
        Binding(get: { cancelling }, set: { value in
            cancelling = value
            Task { await state.setNoise(mode: .cancelling, cancelling: value, awareness: awareness) }
        })
    }

    private var awarenessSelection: Binding<AwarenessMode> {
        Binding(get: { awareness }, set: { value in
            awareness = value
            Task { await state.setNoise(mode: .awareness, cancelling: cancelling, awareness: value) }
        })
    }

    private var autoPauseToggle: Binding<Bool> {
        Binding(get: { autoPause }, set: { value in
            autoPause = value
            Task { await state.setAutoPause(value) }
        })
    }

    private var lowLatencyToggle: Binding<Bool> {
        Binding(get: { lowLatency }, set: { value in
            lowLatency = value
            Task { await state.setLowLatency(value) }
        })
    }

    private var preferenceSelection: Binding<SoundPreference> {
        Binding(get: { preference }, set: { value in
            preference = value
            Task { await state.setSoundPreference(value) }
        })
    }

    var body: some View {
        VStack(spacing: Theme.spacing) {
            batteryCard
            if state.profile.anc != nil { noiseCard }
            if state.profile.eq != nil { eqCard }
            if hasBehaviourControls { behaviourCard }
        }
        .disabled(!connected)
        .opacity(connected ? 1 : 0.55)
        .onAppear(perform: syncFromDevice)
        .onChange(of: state.profile) { _, profile in
            if let first = profile.anc?.levels.first, !(profile.anc?.levels.contains(cancelling) ?? false) {
                cancelling = first
            }
            syncFromDevice()
        }
        .onChange(of: state.snapshot.noiseMode) { _, _ in syncNoise() }
        .onChange(of: state.snapshot.cancellingLevel) { _, _ in syncNoise() }
        .onChange(of: state.snapshot.awarenessMode) { _, _ in syncNoise() }
        .onChange(of: state.snapshot.activePreset) { _, _ in syncFromDevice() }
        .onChange(of: state.snapshot.autoPause) { _, _ in syncFromDevice() }
        .onChange(of: state.snapshot.lowLatency) { _, _ in syncFromDevice() }
        .onChange(of: state.snapshot.soundPreference) { _, _ in syncFromDevice() }
        // A write that fails or is ignored leaves the snapshot unchanged, so
        // the value observers above never fire. Re-sync after every attempt to
        // put the control back on what the earbuds actually report.
        .onChange(of: state.writeGeneration) { _, _ in syncFromDevice() }
    }

    private func syncNoise() {
        if let value = state.snapshot.noiseMode { mode = value }
        if let value = state.snapshot.cancellingLevel { cancelling = value }
        if let value = state.snapshot.awarenessMode { awareness = value }
    }

    private func syncFromDevice() {
        syncNoise()
        preset = state.snapshot.activePreset
        if let value = state.snapshot.autoPause { autoPause = value }
        if let value = state.snapshot.lowLatency { lowLatency = value }
        if let value = state.snapshot.soundPreference { preference = value }
    }

    // MARK: Battery

    private var batteryCard: some View {
        PanelSectionCard(title: "Battery",
                         caption: state.snapshot.isCharging ? "Charging now" : "Live from the earbuds",
                         systemImage: "battery.75percent") {
            if state.profile.hasTWSBattery {
                HStack(spacing: 8) {
                    BatteryTile(title: "Left",
                                level: state.snapshot.left,
                                charging: state.snapshot.leftCharging) {
                        BudIcon()
                    }
                    BatteryTile(title: "Case",
                                level: state.snapshot.caseLevel,
                                charging: state.snapshot.caseCharging) {
                        Image(systemName: "earbuds.case")
                            .font(.system(size: 21, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    BatteryTile(title: "Right",
                                level: state.snapshot.right,
                                charging: state.snapshot.rightCharging) {
                        BudIcon(mirrored: true)
                    }
                }
            } else {
                wideBatteryRow
            }
        }
    }

    private var wideBatteryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 7) {
                Text("Battery")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                BatteryMeter(level: state.snapshot.overall,
                             charging: state.snapshot.overallCharging,
                             showText: false, width: 220)
            }

            Spacer(minLength: 8)

            Text(state.snapshot.overall.map { "\($0)%" } ?? "--")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(state.snapshot.overall.map { _ in Color.primary } ?? Color.secondary)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.fill)
        }
    }

    // MARK: Noise control

    private var noiseCard: some View {
        PanelSectionCard(title: "Noise control",
                         caption: "Choose how the earbuds handle the world around you",
                         systemImage: "waveform") {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(NoiseMode.allCases) { option in
                        noiseModeButton(option)
                    }
                }

                if mode == .cancelling, !cancellingOptions.isEmpty {
                    ChoiceRow(title: "Cancelling strength",
                              options: cancellingOptions,
                              selection: cancellingSelection) { $0.title }
                }

                if mode == .awareness {
                    if state.profile.anc?.voiceBoost == true {
                        ChoiceRow(title: "Awareness mode",
                                  options: [AwarenessMode.voiceBoost, .standard],
                                  selection: awarenessSelection) { $0.title }
                    } else {
                        Text("Awareness uses the earbuds' standard transparency mode.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func noiseModeButton(_ option: NoiseMode) -> some View {
        let isSelected = option == mode
        return Button {
            mode = option
            Task { await state.setNoise(mode: option, cancelling: cancelling, awareness: awareness) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: option.symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(option.shortTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? tint(for: option) : Theme.fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: isSelected ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .animation(Theme.spring, value: mode)
    }

    private func tint(for mode: NoiseMode) -> Color {
        switch mode {
        case .off: return .secondary
        case .cancelling: return Theme.cancelling
        case .awareness: return Theme.awareness
        }
    }

    // MARK: Equalizer

    private var eqCard: some View {
        PanelSectionCard(title: "Equalizer",
                         caption: state.profile.eq?.custom == true
                            ? "Built-in and saved presets" : "Presets reported by the earbuds",
                         systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                if presets.isEmpty {
                    Text("No equalizer presets are reported by this device.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                } else {
                    presetGrid
                }

                if state.profile.eq?.readsState == false {
                    Text("FreeBuds Studio accepts preset changes but does not report the active preset.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A plain three-column grid. `LazyVGrid` could position its first row over
    /// the section header when the card was partially below a scroll viewport.
    private var presetGrid: some View {
        let rowCount = (presets.count + 2) / 3
        return VStack(spacing: 8) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        if index < presets.count {
                            presetButton(presets[index])
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 38)
                        }
                    }
                }
            }
        }
    }

    private func presetButton(_ option: EQPreset) -> some View {
        let isSelected = option == preset
        return Button {
            preset = option
            Task { await state.selectPreset(option) }
        } label: {
            HStack(spacing: 5) {
                if option.customData != nil {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(option.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accent : Theme.fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: isSelected ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Behaviour

    private var behaviourCard: some View {
        PanelSectionCard(title: "Device behaviour",
                         caption: "Comfort and connection preferences",
                         systemImage: "sparkles") {
            VStack(spacing: 13) {
                if state.profile.autoPause {
                    ToggleRow(title: "Auto-pause",
                              caption: "Pauses audio when an earbud comes out",
                              isOn: autoPauseToggle)
                    if state.profile.lowLatency || state.profile.soundPreference {
                        Divider().overlay(Theme.hairline)
                    }
                }

                if state.profile.lowLatency {
                    ToggleRow(title: "Low latency",
                              caption: "Prioritises delay over range",
                              isOn: lowLatencyToggle)
                    if state.profile.soundPreference {
                        Divider().overlay(Theme.hairline)
                    }
                }

                if state.profile.soundPreference {
                    ChoiceRow(title: "Sound preference",
                              options: SoundPreference.allCases,
                              selection: preferenceSelection) { $0.title }
                }
            }
        }
    }
}

// MARK: - Gestures panel

struct GesturesPanel: View {
    @ObservedObject var state: DeviceState

    @State private var doubleLeft: GestureAction = .playPause
    @State private var doubleRight: GestureAction = .playPause
    @State private var doubleInCall: GestureAction = .none
    @State private var tripleLeft: GestureAction = .nextTrack
    @State private var tripleRight: GestureAction = .nextTrack
    @State private var holdLeft: GestureAction = .noiseControl
    @State private var holdRight: GestureAction = .noiseControl
    @State private var holdInCall: GestureAction = .none
    @State private var combinedHold: GestureAction = .cycleAll
    @State private var cycleLeft: GestureAction = .cycleAll
    @State private var cycleRight: GestureAction = .cycleAll
    @State private var swipe: GestureAction = .changeVolume
    @State private var power: GestureAction = .none

    private var profile: DeviceProfile { state.profile }

    // As in the Sound panel, only a user edit goes through these bindings and
    // starts a write; syncing from a device snapshot just updates @State.
    private var doubleLeftChoice: Binding<GestureAction> {
        Binding(get: { doubleLeft }, set: { value in
            doubleLeft = value
            Task { await state.setDoubleTap(value, left: true) }
        })
    }

    private var doubleRightChoice: Binding<GestureAction> {
        Binding(get: { doubleRight }, set: { value in
            doubleRight = value
            Task { await state.setDoubleTap(value, left: false) }
        })
    }

    private var doubleInCallChoice: Binding<GestureAction> {
        Binding(get: { doubleInCall }, set: { value in
            doubleInCall = value
            Task { await state.setDoubleTap(value, left: true, inCall: true) }
        })
    }

    private var tripleLeftChoice: Binding<GestureAction> {
        Binding(get: { tripleLeft }, set: { value in
            tripleLeft = value
            Task { await state.setTripleTap(value, left: true) }
        })
    }

    private var tripleRightChoice: Binding<GestureAction> {
        Binding(get: { tripleRight }, set: { value in
            tripleRight = value
            Task { await state.setTripleTap(value, left: false) }
        })
    }

    private var holdLeftChoice: Binding<GestureAction> {
        Binding(get: { holdLeft }, set: { value in
            holdLeft = value
            Task { await state.setHold(value, left: true) }
        })
    }

    private var holdRightChoice: Binding<GestureAction> {
        Binding(get: { holdRight }, set: { value in
            holdRight = value
            Task { await state.setHold(value, left: false) }
        })
    }

    private var holdInCallChoice: Binding<GestureAction> {
        Binding(get: { holdInCall }, set: { value in
            holdInCall = value
            Task { await state.setHoldInCall(value) }
        })
    }

    private var combinedHoldChoice: Binding<GestureAction> {
        Binding(get: { combinedHold }, set: { value in
            combinedHold = value
            Task { await state.setCombinedHold(value) }
        })
    }

    private var cycleLeftChoice: Binding<GestureAction> {
        Binding(get: { cycleLeft }, set: { value in
            cycleLeft = value
            Task { await state.setNoiseCycle(value, left: true) }
        })
    }

    private var cycleRightChoice: Binding<GestureAction> {
        Binding(get: { cycleRight }, set: { value in
            cycleRight = value
            Task { await state.setNoiseCycle(value, left: false) }
        })
    }

    private var swipeChoice: Binding<GestureAction> {
        Binding(get: { swipe }, set: { value in
            swipe = value
            Task { await state.setSwipe(value) }
        })
    }

    private var powerChoice: Binding<GestureAction> {
        Binding(get: { power }, set: { value in
            power = value
            Task { await state.setPowerButton(value) }
        })
    }

    private var hasGestures: Bool {
        profile.doubleTap != nil || profile.tripleTap != nil || profile.longTap != nil
            || profile.noiseCycle || profile.swipe || profile.powerButton
    }

    private func tapOptions(_ fallback: [GestureAction],
                            current: GestureAction) -> [GestureAction] {
        var options = fallback
        if current.isWritable, !options.contains(current) { options.append(current) }
        return options
    }

    private func doubleOptions(for current: GestureAction) -> [GestureAction] {
        let profileOptions = profile.options(for: .doubleTap)
        let readOptions = state.snapshot.doubleTapOptions
        return tapOptions(readOptions.isEmpty ? profileOptions : readOptions,
                          current: current)
    }

    private func tripleOptions(for current: GestureAction) -> [GestureAction] {
        let profileOptions = profile.options(for: .tripleTap)
        let readOptions = state.snapshot.tripleTapOptions
        return tapOptions(readOptions.isEmpty ? profileOptions : readOptions,
                          current: current)
    }

    var body: some View {
        VStack(spacing: Theme.spacing) {
            if let double = profile.doubleTap {
                PanelSectionCard(title: "Double tap",
                                 caption: "Two quick taps on an earbud",
                                 systemImage: "hand.tap") {
                    VStack(spacing: 11) {
                        if double.left {
                            MenuPicker(label: "Left",
                                       options: doubleOptions(for: doubleLeft),
                                       selection: doubleLeftChoice) { $0.title }
                        }
                        if double.right {
                            MenuPicker(label: "Right",
                                       options: doubleOptions(for: doubleRight),
                                       selection: doubleRightChoice) { $0.title }
                        }
                        if double.inCall {
                            MenuPicker(label: "In call",
                                       options: tapOptions(profile.options(for: .doubleTapInCall),
                                                           current: doubleInCall),
                                       selection: doubleInCallChoice) { $0.title }
                        }
                    }
                }
            }

            if let triple = profile.tripleTap {
                PanelSectionCard(title: "Triple tap",
                                 caption: "Three quick taps on an earbud",
                                 systemImage: "hand.tap.fill") {
                    VStack(spacing: 11) {
                        if triple.left {
                            MenuPicker(label: "Left",
                                       options: tripleOptions(for: tripleLeft),
                                       selection: tripleLeftChoice) { $0.title }
                        }
                        if triple.right {
                            MenuPicker(label: "Right",
                                       options: tripleOptions(for: tripleRight),
                                       selection: tripleRightChoice) { $0.title }
                        }
                    }
                }
            }

            if let long = profile.longTap {
                if long.kind == .combined {
                    PanelSectionCard(title: "Press and hold",
                                     caption: "Hold to cycle noise control",
                                     systemImage: "hand.point.up.left") {
                        MenuPicker(label: "Action",
                                   options: profile.options(for: .combinedLongTap,
                                                            including: combinedHold),
                                   selection: combinedHoldChoice) { $0.title }
                    }
                } else if long.left || long.right || long.inCall {
                    PanelSectionCard(title: "Press and hold",
                                     caption: "Hold an earbud to trigger an action",
                                     systemImage: "hand.point.up.left") {
                        VStack(spacing: 11) {
                            if long.left {
                                MenuPicker(label: "Left",
                                           options: profile.options(for: .longTap,
                                                                    including: holdLeft),
                                           selection: holdLeftChoice) { $0.title }
                            }
                            if long.right {
                                MenuPicker(label: "Right",
                                           options: profile.options(for: .longTap,
                                                                    including: holdRight),
                                           selection: holdRightChoice) { $0.title }
                            }
                            if long.inCall {
                                MenuPicker(label: "In call",
                                           options: profile.options(for: .longTapInCall,
                                                                    including: holdInCall),
                                           selection: holdInCallChoice) { $0.title }
                            }
                        }
                    }
                }
            }

            if profile.noiseCycle, let long = profile.longTap {
                PanelSectionCard(title: "Noise control cycle",
                                 caption: "Modes included when cycling by touch",
                                 systemImage: "arrow.triangle.2.circlepath") {
                    VStack(spacing: 11) {
                        if long.left {
                            MenuPicker(label: "Left",
                                       options: profile.options(for: .noiseCycle,
                                                                including: cycleLeft),
                                       selection: cycleLeftChoice) { $0.title }
                        }
                        if long.right {
                            MenuPicker(label: "Right",
                                       options: profile.options(for: .noiseCycle,
                                                                including: cycleRight),
                                       selection: cycleRightChoice) { $0.title }
                        }
                    }
                }
            }

            if profile.swipe {
                PanelSectionCard(title: "Swipe",
                                 caption: "Slide along the earbud stem",
                                 systemImage: "hand.draw") {
                    MenuPicker(label: "Action",
                               options: profile.options(for: .swipe, including: swipe),
                               selection: swipeChoice) { $0.title }
                }
            }

            if profile.powerButton {
                PanelSectionCard(title: "Power button",
                                 caption: "The button on the neckband",
                                 systemImage: "power") {
                    MenuPicker(label: "Action",
                               options: profile.options(for: .powerButton, including: power),
                               selection: powerChoice) { $0.title }
                }
            }

            if !hasGestures {
                PanelSectionCard(title: "Gestures",
                                 caption: "This model does not expose gesture settings",
                                 systemImage: "hand.tap") {
                    Text("Use the earbuds' own controls or the Huawei AI Life app for gesture configuration.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(!state.isConnected)
        .opacity(state.isConnected ? 1 : 0.55)
        .onAppear(perform: sync)
        .onChange(of: state.profile) { _, _ in sync() }
        .onChange(of: state.snapshot.doubleTapLeft) { _, _ in sync() }
        .onChange(of: state.snapshot.doubleTapRight) { _, _ in sync() }
        .onChange(of: state.snapshot.doubleTapInCall) { _, _ in sync() }
        .onChange(of: state.snapshot.tripleTapLeft) { _, _ in sync() }
        .onChange(of: state.snapshot.tripleTapRight) { _, _ in sync() }
        .onChange(of: state.snapshot.holdLeft) { _, _ in sync() }
        .onChange(of: state.snapshot.holdRight) { _, _ in sync() }
        .onChange(of: state.snapshot.holdInCall) { _, _ in sync() }
        .onChange(of: state.snapshot.combinedHold) { _, _ in sync() }
        .onChange(of: state.snapshot.noiseCycleLeft) { _, _ in sync() }
        .onChange(of: state.snapshot.noiseCycleRight) { _, _ in sync() }
        .onChange(of: state.snapshot.swipe) { _, _ in sync() }
        .onChange(of: state.snapshot.powerButton) { _, _ in sync() }
        .onChange(of: state.writeGeneration) { _, _ in sync() }
    }

    private func sync() {
        if let value = state.snapshot.doubleTapLeft { doubleLeft = value }
        if let value = state.snapshot.doubleTapRight { doubleRight = value }
        if let value = state.snapshot.doubleTapInCall { doubleInCall = value }
        if let value = state.snapshot.tripleTapLeft { tripleLeft = value }
        if let value = state.snapshot.tripleTapRight { tripleRight = value }
        if let value = state.snapshot.holdLeft { holdLeft = value }
        if let value = state.snapshot.holdRight { holdRight = value }
        if let value = state.snapshot.holdInCall { holdInCall = value }
        if let value = state.snapshot.combinedHold { combinedHold = value }
        if let value = state.snapshot.noiseCycleLeft { cycleLeft = value }
        if let value = state.snapshot.noiseCycleRight { cycleRight = value }
        if let value = state.snapshot.swipe { swipe = value }
        if let value = state.snapshot.powerButton { power = value }
    }
}

// MARK: - Device panel

struct DevicePanel: View {
    @ObservedObject var state: DeviceState

    var body: some View {
        VStack(spacing: Theme.spacing) {
            heroCard
            informationCard
            sessionCard
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 16) {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    HeaderMark(connected: state.isConnected, size: 54)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.snapshot.modelName ?? "Huawei Audio Device")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(state.profile.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        StatusPill(text: state.phase == .connected
                                        ? "Connected"
                                        : (state.phase == .connecting ? "Connecting…" : "Not connected"),
                                   color: state.isConnected ? Theme.connected : .secondary,
                                   pulsing: state.phase == .connecting)
                    }

                    Spacer(minLength: 6)

                    if state.isConnected, let level = state.snapshot.weakestBud {
                        BatteryRing(level: level, charging: state.snapshot.isCharging, size: 46)
                    }
                }

                if state.isConnected, state.profile.hasInEar {
                    HStack(spacing: 8) {
                        inEarBadge("L", state.snapshot.leftInEar)
                        inEarBadge("R", state.snapshot.rightInEar)
                        Spacer()
                    }
                }
            }
        }
    }

    private var informationCard: some View {
        PanelSectionCard(title: "Device information",
                         caption: "Reported by the earbuds over the control channel",
                         systemImage: "info.circle") {
            VStack(spacing: 9) {
                DetailRow(title: "Name", value: state.snapshot.modelName ?? "—")
                DetailRow(title: "Profile", value: state.profile.title)
                DetailRow(title: "Model", value: state.snapshot.modelCode ?? "—")
                DetailRow(title: "Firmware", value: state.snapshot.firmware ?? "—")
                DetailRow(title: "Hardware", value: state.snapshot.hardware ?? "—")
                DetailRow(title: "Serial", value: state.snapshot.serial ?? "—")
            }
        }
    }

    private var sessionCard: some View {
        PanelSectionCard(title: "Connection",
                         caption: "One control session at a time",
                         systemImage: "link") {
            VStack(spacing: 8) {
                GlassButton(title: state.isConnected
                                ? "Refresh readings"
                                : (state.phase == .connecting ? "Connecting…" : "Connect"),
                            systemImage: "arrow.clockwise",
                            prominent: !state.isConnected,
                            disabled: state.phase == .connecting) {
                    Task {
                        if state.isConnected {
                            await state.refreshAll()
                        } else {
                            await state.connect()
                        }
                    }
                }

                GlassButton(title: "Open Bluetooth settings", systemImage: "gearshape") {
                    openBluetoothSettings()
                }

                if state.isConnected {
                    GlassButton(title: "Disconnect", systemImage: "xmark.circle") {
                        state.disconnect()
                    }
                }
            }
        }
    }

    private func inEarBadge(_ side: String, _ worn: Bool?) -> some View {
        let text = "\(side) \(worn.map { $0 ? "in ear" : "out" } ?? "unknown")"
        return Badge(text: text,
                     systemImage: worn == true ? "ear.fill" : "ear",
                     color: worn == true ? Theme.awareness : .secondary)
    }

    private func openBluetoothSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
        NSWorkspace.shared.open(url)
    }
}
