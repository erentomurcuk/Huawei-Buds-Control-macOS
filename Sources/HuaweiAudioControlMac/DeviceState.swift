// SPDX-License-Identifier: GPL-3.0-only
// Protocol data and algorithms derived from OpenFreebuds (GPL-3.0).

import Foundation
import IOBluetooth

/// Everything known about the connected earbuds, updated from reads and pushes.
struct DeviceSnapshot: Equatable {
    var modelName: String?
    /// The hardware model code reported by the protocol (e.g. "BTFT0019").
    /// Shown as a detail, never as the display name.
    var modelCode: String?
    var firmware: String?
    var hardware: String?
    var serial: String?

    var overall: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var overallCharging = false
    var leftCharging = false
    var rightCharging = false
    var caseCharging = false

    var noiseMode: NoiseMode?
    var cancellingLevel: CancellingLevel?
    var awarenessMode: AwarenessMode?

    var activePreset: EQPreset?
    var offeredPresets: [EQPreset] = []

    var doubleTapLeft: GestureAction?
    var doubleTapRight: GestureAction?
    var doubleTapInCall: GestureAction?
    var doubleTapOptions: [GestureAction] = []

    var tripleTapLeft: GestureAction?
    var tripleTapRight: GestureAction?
    var tripleTapOptions: [GestureAction] = []

    var holdLeft: GestureAction?
    var holdRight: GestureAction?
    var holdInCall: GestureAction?
    var combinedHold: GestureAction?

    var noiseCycleLeft: GestureAction?
    var noiseCycleRight: GestureAction?

    var swipe: GestureAction?
    var powerButton: GestureAction?

    /// Auto-pause ("wear detection") configuration.
    var autoPause: Bool?
    var leftInEar: Bool?
    var rightInEar: Bool?
    var lowLatency: Bool?
    var soundPreference: SoundPreference?

    static let empty = DeviceSnapshot()

    /// True when at least one earbud reports it is being worn.
    var isWorn: Bool { leftInEar == true || rightInEar == true }

    var isCharging: Bool {
        overallCharging || leftCharging || rightCharging || caseCharging
    }

    /// The lower of the two buds, which is what the mobile app shows.
    var weakestBud: Int? {
        switch (left, right) {
        case let (l?, r?): return min(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return overall
        }
    }
}

/// Owns the session, polls readings, and applies user changes in order.
///
/// Every write is read back from the earbuds before the UI reports success, so
/// the panel only ever shows what the device actually says. Studio EQ is the
/// one exception: its firmware acknowledges a preset write but does not report
/// the active preset, so that write is applied optimistically.
@MainActor
final class DeviceState: ObservableObject {
    @Published private(set) var snapshot = DeviceSnapshot.empty
    @Published private(set) var profile = DeviceProfile.freeBuds6i
    @Published private(set) var phase: Phase = .idle
    @Published var lastError: String?

    /// Bumped after every write attempt. The panels observe it so they can
    /// re-sync their optimistic local state from the snapshot: on success that
    /// confirms the new value, and on failure it reverts the control instead of
    /// leaving the rejected value on screen.
    @Published private(set) var writeGeneration = 0

    /// Set when the user explicitly disconnects. Opening the panel again should
    /// not reconnect until they press Connect, while an unexpected drop still
    /// reconnects on the next open.
    @Published private(set) var manuallyDisconnected = false

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
    }

    private let link = BluetoothLink()
    private var pollTask: Task<Void, Never>?
    private var pollObserver: NSObjectProtocol?
    private var profileObserver: NSObjectProtocol?
    private var isClosing = false

    init() {
        link.onPacket = { [weak self] packet in
            self?.apply(packet)
        }
        link.onChannelClosed = { [weak self] in
            self?.handleChannelClosed()
        }
        pollObserver = NotificationCenter.default.addObserver(
            forName: .pollIntervalDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartPolling() }
        }
        profileObserver = NotificationCenter.default.addObserver(
            forName: .deviceProfileDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.profileSettingChanged() }
        }
    }

    deinit {
        pollTask?.cancel()
        if let pollObserver {
            NotificationCenter.default.removeObserver(pollObserver)
        }
        if let profileObserver {
            NotificationCenter.default.removeObserver(profileObserver)
        }
    }

#if DEBUG
    /// Fills the observable model for SwiftUI previews and the UI render
    /// harness. Debug builds only; release builds have no mock path.
    func loadPreview(snapshot: DeviceSnapshot, profile: DeviceProfile) {
        self.snapshot = snapshot
        self.profile = profile
        self.phase = .connected
        self.manuallyDisconnected = false
    }
#endif

    var isConnected: Bool { phase == .connected }

    // MARK: - Session lifecycle

    func connect() async {
        guard phase == .idle else { return }
        manuallyDisconnected = false
        phase = .connecting
        lastError = nil
        isClosing = false

        do {
            try await link.open()
            adoptProfile(DeviceProfile.resolve(name: link.deviceName, modelCode: link.model))
            phase = .connected
            // Show the friendly Bluetooth name (e.g. "iBuds"); the protocol's
            // hardware code is kept separately as a detail.
            if let name = link.deviceName, !name.isEmpty {
                snapshot.modelName = name
            } else if snapshot.modelName == nil {
                snapshot.modelName = link.model
            }
            startPolling()
            await refreshAll()
        } catch is CancellationError {
            // Closing the menu panel cancels the task that started the
            // connection. That is not a failure; the next open tries again.
            link.disconnect()
            phase = .idle
        } catch {
            phase = .idle
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        isClosing = true
        manuallyDisconnected = true
        stopPolling()
        link.disconnect()
        snapshot = .empty
        phase = .idle
        lastError = nil
    }

    /// Called on quit: the earbuds keep a stale session if the channel is
    /// abandoned, so it is always released explicitly.
    func shutdown() {
        isClosing = true
        stopPolling()
        link.shutdown()
    }

    private func handleChannelClosed() {
        guard !isClosing else { return }
        stopPolling()
        snapshot = .empty
        phase = .idle
        lastError = LinkError.closed.localizedDescription
    }

    /// Applies a profile and seeds the choices the UI can show before the first
    /// read comes back. The snapshot itself is left alone so info fields read
    /// during `link.open()` survive.
    private func adoptProfile(_ newProfile: DeviceProfile) {
        profile = newProfile
        snapshot.doubleTapOptions = newProfile.doubleTap?.options ?? []
        snapshot.tripleTapOptions = newProfile.tripleTap?.options ?? []
        if let eq = newProfile.eq {
            snapshot.offeredPresets = eq.builtIns
        } else {
            snapshot.offeredPresets = []
        }
    }

    /// Changing the model in Settings takes effect immediately when connected.
    private func profileSettingChanged() {
        guard phase == .connected else { return }
        let resolved = DeviceProfile.resolve(name: link.deviceName, modelCode: link.model)
        guard resolved != profile else { return }
        let name = link.deviceName ?? snapshot.modelName
        let code = link.model ?? snapshot.modelCode
        snapshot = .empty
        snapshot.modelName = name
        snapshot.modelCode = code
        adoptProfile(resolved)
        lastError = nil
        Task { await refreshAll() }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        let interval = UserDefaults.standard.object(forKey: "pollInterval") as? Int ?? 25
        guard interval > 0 else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.refreshReadings()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Restarts the timer after the interval changed in Settings.
    func restartPolling() {
        guard phase == .connected else { return }
        startPolling()
    }

    /// Reads every feature in turn; the link only allows one request at a time,
    /// so they are deliberately sequential rather than concurrent.
    func refreshAll() async {
        guard phase == .connected else { return }
        await refreshReadings()
        _ = try? await link.read(.info)
    }

    /// The frequently changing values, used both for polling and for the
    /// explicit "Refresh readings" button. Only features the detected profile
    /// actually exposes are polled.
    private func refreshReadings() async {
        for feature in pollFeatures {
            guard phase == .connected, !Task.isCancelled else { return }
            _ = try? await link.read(feature)
        }
    }

    private var pollFeatures: [BluetoothLink.Feature] {
        var features: [BluetoothLink.Feature] = [.battery]
        if profile.readsInEar { features.append(.inEar) }
        if profile.anc != nil { features.append(.noiseControl) }
        if profile.eq?.readsState == true { features.append(.eq) }
        if profile.powerButton { features.append(.powerButton) }
        if profile.doubleTap != nil { features.append(.doubleTap) }
        if profile.tripleTap != nil { features.append(.tripleTap) }
        if let long = profile.longTap {
            switch long.kind {
            case .combined:
                features.append(.hold)
            case .split where long.left || long.right || long.inCall:
                features.append(.hold)
            case .split:
                break
            }
        }
        if profile.noiseCycle { features.append(.noiseCycle) }
        if profile.swipe { features.append(.swipe) }
        if profile.autoPause { features.append(.autoPause) }
        if profile.lowLatency { features.append(.latency) }
        if profile.soundPreference { features.append(.soundPreference) }
        return features
    }

    // MARK: - Pushes

    private func apply(_ packet: ControlPacket) {
        switch packet.command {
        case Cmd.info:
            if let code = packet.text(10) ?? packet.text(15) { snapshot.modelCode = code }
            if let version = packet.text(7) { snapshot.firmware = version }
            if let version = packet.text(3) { snapshot.hardware = version }
            if let number = packet.text(9) { snapshot.serial = number }
        case Cmd.battery, Cmd.batteryPush:
            applyBattery(packet)
        case Cmd.noiseState:
            if profile.anc != nil { applyNoise(packet) }
        case Cmd.eqState:
            if profile.eq != nil { applyEQ(packet) }
        case Cmd.doubleTapRead:
            if profile.powerButton {
                applyPowerButton(packet)
            } else if let capability = profile.doubleTap {
                let taps = tapActions(packet, control: .doubleTap)
                snapshot.doubleTapLeft = taps.left
                snapshot.doubleTapRight = taps.right
                if capability.inCall, let value = packet.signedByte(4) {
                    snapshot.doubleTapInCall = profile.action(for: value, control: .doubleTapInCall)
                }
                snapshot.doubleTapOptions = options(from: packet.raw(3),
                                                    control: .doubleTap,
                                                    fallback: capability.options)
            }
        case Cmd.tripleTapRead:
            if let capability = profile.tripleTap {
                let taps = tapActions(packet, control: .tripleTap)
                snapshot.tripleTapLeft = taps.left
                snapshot.tripleTapRight = taps.right
                snapshot.tripleTapOptions = options(from: packet.raw(3),
                                                    control: .tripleTap,
                                                    fallback: capability.options)
            }
        case Cmd.holdRead:
            applyHold(packet)
        case Cmd.swipeRead:
            if profile.swipe, let value = packet.signedByte(1) {
                snapshot.swipe = profile.action(for: value, control: .swipe)
            }
        case Cmd.cycleRead:
            applyNoiseCycle(packet)
        case Cmd.autoPauseRead:
            if profile.autoPause, let value = packet.bool(1) { snapshot.autoPause = value }
        case Cmd.latencyReadWrite:
            if profile.lowLatency, let value = packet.bool(2) { snapshot.lowLatency = value }
        case Cmd.soundPrefRead:
            if profile.soundPreference,
               let value = packet.byte(2) ?? packet.byte(1),
               let pref = SoundPreference(rawValue: value) {
                snapshot.soundPreference = pref
            }
        case Cmd.inEarState:
            if profile.readsInEar {
                if let value = packet.bool(1) { snapshot.leftInEar = value }
                if let value = packet.bool(2) { snapshot.rightInEar = value }
            }
        case Cmd.wearState:
            if profile.hasInEar {
                if let value = packet.bool(8) { snapshot.leftInEar = value }
                if let value = packet.bool(9) { snapshot.rightInEar = value }
            }
            if profile.refreshesANCOnWearPush {
                // FreeLace Pro reuses this push for on-device ANC changes. Poll
                // the ANC state so the panel does not wait for the next tick.
                Task { [weak self] in
                    guard let self else { return }
                    _ = try? await self.link.read(.noiseControl)
                }
            }
        default:
            break
        }
    }

    private func tapActions(_ packet: ControlPacket,
                            control: GestureControl) -> (left: GestureAction?, right: GestureAction?) {
        let left = packet.signedByte(1).map { profile.action(for: $0, control: control) }
        let right = packet.signedByte(2).map { profile.action(for: $0, control: control) }
        return (left, right)
    }

    /// Device parameter 3 lists the codes this particular firmware accepts.
    /// Fall back to the profile table when a model omits it.
    private func options(from raw: [UInt8]?, control: GestureControl,
                         fallback: [GestureAction]) -> [GestureAction] {
        guard let raw, !raw.isEmpty else { return fallback }
        var result: [GestureAction] = []
        for byte in raw {
            let action = profile.action(for: Int(Int8(bitPattern: byte)), control: control)
            guard action != .unsupported, action.isWritable, !result.contains(action) else { continue }
            result.append(action)
        }
        return result.isEmpty ? fallback : result
    }

    private func applyHold(_ packet: ControlPacket) {
        guard let long = profile.longTap else { return }
        switch long.kind {
        case .combined:
            if let value = packet.signedByte(1) {
                snapshot.combinedHold = profile.action(for: value, control: .combinedLongTap)
            }
        case .split:
            if long.left, let value = packet.signedByte(1) {
                snapshot.holdLeft = profile.action(for: value, control: .longTap)
            }
            if long.right, let value = packet.signedByte(2) {
                snapshot.holdRight = profile.action(for: value, control: .longTap)
            }
            if long.inCall, let value = packet.signedByte(4) {
                snapshot.holdInCall = profile.action(for: value, control: .longTapInCall)
            }
        }
    }

    private func applyNoiseCycle(_ packet: ControlPacket) {
        guard profile.noiseCycle, let long = profile.longTap else { return }
        if long.left, let value = packet.signedByte(1) {
            snapshot.noiseCycleLeft = profile.action(for: value, control: .noiseCycle)
        }
        if long.right, let value = packet.signedByte(2) {
            snapshot.noiseCycleRight = profile.action(for: value, control: .noiseCycle)
        }
    }

    private func applyPowerButton(_ packet: ControlPacket) {
        guard profile.powerButton, let value = packet.signedByte(1) else { return }
        snapshot.powerButton = profile.action(for: value, control: .powerButton)
    }

    private func applyBattery(_ packet: ControlPacket) {
        if let overall = packet.byte(1) { snapshot.overall = overall }

        let flags = packet.raw(3)
        guard profile.hasTWSBattery else {
            snapshot.left = nil
            snapshot.right = nil
            snapshot.caseLevel = nil
            if let flags, !flags.isEmpty {
                snapshot.overallCharging = flags.contains(where: { $0 != 0 })
            }
            return
        }

        if let bud = packet.raw(2), bud.count >= 2 {
            snapshot.left = Int(bud[0])
            snapshot.right = Int(bud[1])
            if bud.count > 2 { snapshot.caseLevel = Int(bud[2]) }
        }
        if let flags {
            if flags.count >= 2 {
                snapshot.leftCharging = flags[0] != 0
                snapshot.rightCharging = flags[1] != 0
                if flags.count > 2 { snapshot.caseCharging = flags[2] != 0 }
            } else if !flags.isEmpty {
                snapshot.overallCharging = flags[0] != 0
            }
        }
    }

    private func applyNoise(_ packet: ControlPacket) {
        // Parameter 1 is `[level, mode]` on every model with the ANC handler.
        guard let value = packet.raw(1), value.count == 2 else { return }
        let level = Int(value[0])
        guard let mode = NoiseMode(rawValue: Int(value[1])) else { return }
        snapshot.noiseMode = mode
        switch mode {
        case .cancelling:
            snapshot.cancellingLevel = profile.anc?.levels.first(where: { $0.rawValue == level })
            snapshot.awarenessMode = nil
        case .awareness:
            if profile.anc?.voiceBoost == true {
                snapshot.awarenessMode = AwarenessMode(rawValue: level)
            } else {
                snapshot.awarenessMode = .standard
            }
            snapshot.cancellingLevel = nil
        case .off:
            snapshot.cancellingLevel = nil
            snapshot.awarenessMode = nil
        }
    }

    private func applyEQ(_ packet: ControlPacket) {
        guard let capability = profile.eq else { return }
        var offered = capability.builtIns

        // FreeLace Pro 2 has no predefined table in OpenFreebuds; its firmware
        // reports the available built-in ids in parameter 3. Other models use a
        // fixed table because the raw ids are renumbered (Pro 3/4/5).
        if capability.usesReportedBuiltIns, let raw = packet.raw(3), !raw.isEmpty {
            offered = raw.map { EQPreset(id: Int($0),
                                         title: DeviceProfile.title(forPreset: Int($0))) }
        }

        // Custom presets are fixed 36-byte records: id, band count, bands,
        // then a NUL-padded label. Keep the label inside its own record: if a
        // record is not NUL-terminated, scanning to the end of the whole blob
        // would pick up the next record's id and curve as label bytes.
        //
        // Built-in ids come from the profile rather than parameter 3. Pro 3/4/
        // FreeClip and Pro 5 renumber the default preset to 5, so treating the
        // raw ids as globally meaningful would lose that mapping.
        if capability.custom, let custom = packet.raw(8), !custom.isEmpty {
            let recordSize = 36
            var offset = 0
            while offset + 2 <= custom.count {
                let recordEnd = min(offset + recordSize, custom.count)
                let id = Int(custom[offset])
                let bands = Int(custom[offset + 1])
                let dataEnd = offset + 2 + bands
                guard dataEnd <= recordEnd else { break }
                let curve = Array(custom[(offset + 2)..<dataEnd])
                let labelBytes = custom[dataEnd..<recordEnd].prefix { $0 != 0 }
                let label = String(bytes: labelBytes, encoding: .utf8)
                if let label, !label.isEmpty {
                    // The built-in table may already contain this id. Replace
                    // it so the custom preset keeps its full payload.
                    let preset = EQPreset(id: id, title: label, customData: curve)
                    if let index = offered.firstIndex(where: { $0.id == id }) {
                        offered[index] = preset
                    } else {
                        offered.append(preset)
                    }
                }
                offset += recordSize
            }
        }

        snapshot.offeredPresets = offered

        if let id = packet.byte(2) {
            snapshot.activePreset = offered.first(where: { $0.id == id }) ?? EQPreset(id: id)
        }
    }

    // MARK: - Changes

    /// Sets the noise mode, including the level when cancelling or aware.
    ///
    /// Switching modes sends `0xFF` for the second byte, which asks the device
    /// to keep its stored level (the same thing OpenFreebuds does). Changing a
    /// level while the mode is already active sends the new level instead.
    func setNoise(mode: NoiseMode, cancelling: CancellingLevel, awareness: AwarenessMode) async {
        guard profile.anc != nil else { rejectUnsupported("Noise control is not available on this model.") ; return }
        let changingMode = snapshot.noiseMode != mode
        let supportsCancellingLevels = !(profile.anc?.levels.isEmpty ?? true)
        let supportsAwarenessLevels = profile.anc?.voiceBoost == true
        let value: [UInt8]
        let expectedLevel: UInt8?

        switch mode {
        case .off:
            value = [0x00, 0x00]
            expectedLevel = nil
        case .cancelling:
            let level = UInt8(cancelling.rawValue)
            let keepsStoredLevel = changingMode || !supportsCancellingLevels
            value = [0x01, keepsStoredLevel ? 0xFF : level]
            expectedLevel = keepsStoredLevel ? nil : level
        case .awareness:
            let level = supportsAwarenessLevels ? UInt8(awareness.rawValue) : 0x02
            let keepsStoredLevel = changingMode || !supportsAwarenessLevels
            value = [0x02, keepsStoredLevel ? 0xFF : level]
            expectedLevel = keepsStoredLevel ? nil : level
        }

        await perform(.noiseControl, fields: [1: value]) { packet in
            guard let state = packet.raw(1), state.count == 2 else { return false }
            guard state[1] == Int(mode.rawValue) else { return false }
            if let expectedLevel { return state[0] == Int(expectedLevel) }
            return true
        }
    }

    func selectPreset(_ preset: EQPreset) async {
        guard let capability = profile.eq else {
            rejectUnsupported("The equalizer is not available on this model.")
            return
        }
        if preset.customData != nil, !capability.custom {
            rejectUnsupported("Custom equalizer presets are not supported on this model.")
            return
        }

        if !capability.readsState {
            defer { writeGeneration &+= 1 }
            guard phase == .connected else {
                lastError = LinkError.notConnected.localizedDescription
                return
            }
            do {
                try await link.writeNowait(.eq, fields: preset.writeFields)
                snapshot.activePreset = preset
                lastError = nil
            } catch is CancellationError {
            } catch {
                if phase == .connected { lastError = error.localizedDescription }
            }
            return
        }

        await perform(.eq, fields: preset.writeFields) { packet in
            packet.byte(2) == preset.id
        }
    }

    /// The split long-tap store accepts only one side per write. Key 1 is the
    /// left earbud and key 2 is the right earbud.
    func setDoubleTap(_ action: GestureAction, left: Bool, inCall: Bool = false) async {
        if inCall {
            guard profile.doubleTap?.inCall == true else {
                rejectUnsupported("In-call double tap is not available on this model.")
                return
            }
        }
        await writeAction(action,
                          control: inCall ? .doubleTapInCall : .doubleTap,
                          feature: .doubleTap,
                          key: inCall ? 4 : (left ? 1 : 2))
    }

    func setTripleTap(_ action: GestureAction, left: Bool) async {
        await writeAction(action, control: .tripleTap, feature: .tripleTap,
                          key: left ? 1 : 2)
    }

    func setHold(_ action: GestureAction, left: Bool) async {
        await writeAction(action, control: .longTap, feature: .hold,
                          key: left ? 1 : 2)
    }

    func setHoldInCall(_ action: GestureAction) async {
        guard profile.longTap?.inCall == true else {
            rejectUnsupported("In-call press and hold is not available on this model.")
            return
        }
        await writeAction(action, control: .longTapInCall, feature: .hold, key: 4)
    }

    func setCombinedHold(_ action: GestureAction) async {
        guard let code = profile.code(for: action, control: .combinedLongTap) else {
            rejectUnsupported("That action is not supported by this model.")
            return
        }
        // The non-split long-tap handler writes the same value to keys 1 and 2.
        let value = UInt8(bitPattern: Int8(truncatingIfNeeded: code))
        await perform(.hold, fields: [1: [value], 2: [value]]) { packet in
            packet.signedByte(1) == code
        }
    }

    private func writeAction(_ action: GestureAction, control: GestureControl,
                             feature: BluetoothLink.Feature, key: UInt8,
                             extraFields: [UInt8: [UInt8]] = [:]) async {
        guard let code = profile.code(for: action, control: control) else {
            rejectUnsupported("That action is not supported by this model.")
            return
        }
        var fields = extraFields
        fields[key] = [UInt8(bitPattern: Int8(truncatingIfNeeded: code))]
        await perform(feature, fields: fields) { packet in
            packet.signedByte(key) == code
        }
    }

    func setSwipe(_ action: GestureAction) async {
        guard let code = profile.code(for: action, control: .swipe) else {
            rejectUnsupported("The swipe gesture is not available on this model.")
            return
        }
        let value = UInt8(bitPattern: Int8(truncatingIfNeeded: code))
        await perform(.swipe, fields: [1: [value], 2: [value]]) { packet in
            packet.signedByte(1) == code
        }
    }

    func setNoiseCycle(_ action: GestureAction, left: Bool) async {
        guard let code = profile.code(for: action, control: .noiseCycle) else {
            rejectUnsupported("The noise-control cycle is not available on this model.")
            return
        }
        let key: UInt8 = left ? 1 : 2
        let value = UInt8(bitPattern: Int8(truncatingIfNeeded: code))
        await perform(.noiseCycle, fields: [key: [value]]) { packet in
            packet.signedByte(key) == code
        }
    }

    func setPowerButton(_ action: GestureAction) async {
        guard let code = profile.code(for: action, control: .powerButton) else {
            rejectUnsupported("That action is not available on this model.")
            return
        }
        let value = UInt8(bitPattern: Int8(truncatingIfNeeded: code))
        await perform(.powerButton, fields: [1: [value], 2: [value]]) { packet in
            packet.signedByte(1) == code
        }
    }

    func setAutoPause(_ enabled: Bool) async {
        guard profile.autoPause else {
            rejectUnsupported("Auto-pause is not available on this model.")
            return
        }
        await perform(.autoPause, fields: [1: [enabled ? 0x01 : 0x00]]) { packet in
            packet.bool(1) == enabled
        }
    }

    func setLowLatency(_ enabled: Bool) async {
        guard profile.lowLatency else {
            rejectUnsupported("Low-latency mode is not available on this model.")
            return
        }
        await perform(.latency, fields: [1: [enabled ? 0x01 : 0x00]]) { packet in
            packet.bool(2) == enabled
        }
    }

    func setSoundPreference(_ preference: SoundPreference) async {
        guard profile.soundPreference else {
            rejectUnsupported("Sound preference is not available on this model.")
            return
        }
        await perform(.soundPreference, fields: [1: [UInt8(preference.rawValue)]]) { packet in
            (packet.byte(2) ?? packet.byte(1)) == preference.rawValue
        }
    }

    private func rejectUnsupported(_ message: String) {
        lastError = message
        writeGeneration &+= 1
    }

    /// Writes a setting and refreshes its state; failures surface as an error
    /// banner while the UI keeps showing what the earbuds last reported.
    private func perform(_ feature: BluetoothLink.Feature,
                         fields: [UInt8: [UInt8]],
                         matches: @escaping (ControlPacket) -> Bool) async {
        defer { writeGeneration &+= 1 }
        guard phase == .connected else {
            lastError = LinkError.notConnected.localizedDescription
            return
        }
        do {
            let packet = try await link.write(feature, fields: fields, matches: matches)
            apply(packet)
            lastError = nil
        } catch is CancellationError {
            // Cancelled work has nothing to report.
        } catch {
            // A manual Disconnect closes the channel while a write may still be
            // awaiting its read-back. That rejection belongs to the teardown,
            // not to the user, so only report failures from a live session.
            if phase == .connected {
                lastError = error.localizedDescription
            }
        }
    }
}
