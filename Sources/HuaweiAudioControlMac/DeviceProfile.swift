// SPDX-License-Identifier: GPL-3.0-only
// Protocol data and algorithms derived from OpenFreebuds (GPL-3.0).

import Foundation

/// Per-model capabilities and protocol quirks.
///
/// The command framing is shared by every Huawei SPP audio device, but the
/// feature set is not. OpenFreebuds models this with a handler list per model;
/// this app keeps the equivalent information in one table so reads, writes and
/// the UI can all ask the same question: "does this pair support that?"
struct DeviceProfile: Identifiable, Equatable {
    struct ANCCapability: Equatable {
        let levels: [CancellingLevel]
        let voiceBoost: Bool
    }

    struct EQCapability: Equatable {
        let builtIns: [EQPreset]
        let custom: Bool
        /// Studio answers EQ writes but does not report the active preset, so
        /// selecting a preset must not perform a read-back confirmation.
        let readsState: Bool
        /// Some models (FreeLace Pro 2) have no predefined table in
        /// OpenFreebuds and report their built-ins in parameter 3 instead.
        let usesReportedBuiltIns: Bool

        init(builtIns: [EQPreset], custom: Bool, readsState: Bool,
             usesReportedBuiltIns: Bool = false) {
            self.builtIns = builtIns
            self.custom = custom
            self.readsState = readsState
            self.usesReportedBuiltIns = usesReportedBuiltIns
        }
    }

    struct TapCapability: Equatable {
        let options: [GestureAction]
        let codes: [GestureAction: Int]
        let left: Bool
        let right: Bool
        let inCall: Bool
    }

    struct LongTapCapability: Equatable {
        enum Kind: Equatable {
            /// Left/right (and maybe in-call) each store their own action.
            case split
            /// One shared action that selects a noise-control cycle directly.
            case combined
        }

        let kind: Kind
        let left: Bool
        let right: Bool
        let inCall: Bool
        /// FreeBuds 6i/Pro-style split hold only offers off/switch; models with
        /// an extra config also offer assistant and volume actions.
        let extraOptions: Bool
    }

    let id: String
    let title: String
    /// RFCOMM port used only when SDP does not expose a usable SPP record.
    let fallbackPort: UInt8
    let hasTWSBattery: Bool
    let hasInEar: Bool
    let anc: ANCCapability?
    let autoPause: Bool
    let lowLatency: Bool
    let soundPreference: Bool
    let eq: EQCapability?
    let doubleTap: TapCapability?
    let tripleTap: TapCapability?
    let longTap: LongTapCapability?
    let swipe: Bool
    let powerButton: Bool
    let noiseCycle: Bool

    static let automaticID = "auto"

    /// FreeLace Pro reports on-device ANC changes through the wear-state
    /// command; OpenFreebuds' legacy handler reacts by re-reading ANC state.
    var refreshesANCOnWearPush: Bool { id == "freelace-pro" }

    /// The FreeBuds 6i answers a direct read of `0x2B25` with parameters 1 and
    /// 2, so its in-ear badges can be filled as soon as the session opens.
    /// Other models only push `0x2B03` (parameters 8/9) on a wear change.
    var readsInEar: Bool { id == "freebuds-6i" }

    // MARK: - Option tables

    private static let standardTapCodes: [GestureAction: Int] = [
        .none: -1,
        .assistant: 0,
        .playPause: 1,
        .nextTrack: 2,
        .previousTrack: 7,
    ]

    private static let freeBuds3TapCodes: [GestureAction: Int] = [
        .none: -1,
        .assistant: 0,
        .playPause: 1,
        .noiseControl: 3,
        .nextTrack: 4,
    ]

    private static let inCallCodes: [GestureAction: Int] = [
        .none: -1,
        .answer: 0,
    ]

    private static let noiseCycleCodes: [GestureAction: Int] = [
        .cycleOffOn: 1,
        .cycleAll: 2,
        .cycleOnAwareness: 3,
        .cycleOffAwareness: 4,
    ]

    private static let combinedLongTapCodes: [GestureAction: Int] = [
        .none: -1,
        .cycleOffOn: 3,
        .cycleAll: 5,
        .cycleOnAwareness: 6,
        .cycleOffAwareness: 9,
    ]

    private static let swipeCodes: [GestureAction: Int] = [
        .changeVolume: 0,
        .none: -1,
    ]

    private static let powerCodes: [GestureAction: Int] = [
        .switchDevice: 12,
        .none: -1,
    ]

    // MARK: - Profile lookup

    static let all: [DeviceProfile] = [
        .freeBuds3,
        .freeBuds4i,
        .freeBuds5i,
        .freeBuds6i,
        .freeBudsPro,
        .freeBudsPro2,
        .freeBudsPro3,
        .freeBudsPro5,
        .freeBudsSE,
        .freeBudsSE2,
        .freeBudsSE4,
        .freeBudsStudio,
        .freeClip2,
        .freeLacePro,
        .freeLacePro2,
    ]

    /// Resolves a profile from the Bluetooth name, falling back to the hardware
    /// model code and finally to the legacy 6i profile. A custom Bluetooth name
    /// cannot be identified, so Settings also offers an explicit model choice.
    static func resolve(name: String?, modelCode: String?, override: String) -> DeviceProfile {
        if override != automaticID,
           let selected = all.first(where: { $0.id == override }) {
            return selected
        }

        let n = (name ?? "").lowercased()
        if n.contains("freebuds pro 5") { return .freeBudsPro5 }
        if n.contains("freebuds pro 4") || n.contains("freebuds pro 3") { return .freeBudsPro3 }
        if n.contains("freebuds pro 2") { return .freeBudsPro2 }
        if n.contains("freebuds pro") { return .freeBudsPro }
        if n.contains("freeclip 2") { return .freeClip2 }
        if n.contains("freeclip") { return .freeBudsPro3 }
        if n.contains("freelace pro 2") { return .freeLacePro2 }
        if n.contains("freelace pro") { return .freeLacePro }
        if n.contains("freebuds studio") { return .freeBudsStudio }
        if n.contains("freebuds se 4") { return .freeBudsSE4 }
        if n.contains("freebuds se 2") { return .freeBudsSE2 }
        if n.contains("freebuds se") { return .freeBudsSE }
        if n.contains("freebuds 6i") { return .freeBuds6i }
        if n.contains("freebuds 5i") { return .freeBuds5i }
        if n.contains("freebuds 4i") { return .freeBuds4i }
        if n.contains("honor earbuds 2") { return .freeBuds4i }
        // Avoid matching a hypothetical FreeBuds 3i.
        if n.contains("freebuds 3"), !n.contains("freebuds 3i") { return .freeBuds3 }

        // Model codes seen in OpenFreebuds device reports. 0014 is shared by
        // the 5i and SE 2, so the 5i is the safer feature-complete guess.
        let code = (modelCode ?? "").uppercased()
        if code.contains("BTFT0027") { return .freeClip2 }
        if code.contains("BTFT0019") { return .freeBuds6i }
        if code.contains("BTFT0014") { return .freeBuds5i }

        // Preserve this app's original behaviour for a renamed 6i with an
        // unknown model code. Users with other renamed models can pick their
        // model in Settings.
        return .freeBuds6i
    }

    static func resolve(name: String?, modelCode: String?, defaults: UserDefaults = .standard) -> DeviceProfile {
        resolve(name: name, modelCode: modelCode,
                override: defaults.string(forKey: "deviceProfile") ?? automaticID)
    }

    // MARK: - Gesture questions

    func options(for control: GestureControl) -> [GestureAction] {
        switch control {
        case .doubleTap:
            return doubleTap?.options ?? []
        case .tripleTap:
            return tripleTap?.options ?? []
        case .doubleTapInCall:
            return doubleTap?.inCall == true ? [.none, .answer] : []
        case .longTap:
            guard let longTap, longTap.kind == .split else { return [] }
            var result: [GestureAction] = [.none, .noiseControl]
            if longTap.extraOptions {
                result += [.assistant, .volumeUp, .volumeDown]
            }
            return result
        case .longTapInCall:
            return longTap?.inCall == true ? [.none, .answer] : []
        case .noiseCycle:
            return noiseCycle ? [.cycleOffOn, .cycleAll, .cycleOnAwareness, .cycleOffAwareness] : []
        case .combinedLongTap:
            guard longTap?.kind == .combined else { return [] }
            return [.none, .cycleOffOn, .cycleAll, .cycleOnAwareness, .cycleOffAwareness]
        case .swipe:
            return swipe ? [.changeVolume, .none] : []
        case .powerButton:
            return powerButton ? [.none, .switchDevice] : []
        }
    }

    func options(for control: GestureControl, including current: GestureAction?) -> [GestureAction] {
        var result = options(for: control)
        if let current, current.isWritable, !result.contains(current) { result.append(current) }
        return result
    }

    func codes(for control: GestureControl) -> [GestureAction: Int] {
        switch control {
        case .doubleTap:
            return doubleTap?.codes ?? [:]
        case .tripleTap:
            return tripleTap?.codes ?? [:]
        case .doubleTapInCall, .longTapInCall:
            return Self.inCallCodes
        case .longTap:
            var result: [GestureAction: Int] = [.none: -1, .noiseControl: 10]
            if longTap?.extraOptions == true {
                result[.assistant] = 0
                result[.volumeUp] = 18
                result[.volumeDown] = 19
            }
            return result
        case .noiseCycle:
            return noiseCycle ? Self.noiseCycleCodes : [:]
        case .combinedLongTap:
            return longTap?.kind == .combined ? Self.combinedLongTapCodes : [:]
        case .swipe:
            return swipe ? Self.swipeCodes : [:]
        case .powerButton:
            return powerButton ? Self.powerCodes : [:]
        }
    }

    func code(for action: GestureAction, control: GestureControl) -> Int? {
        codes(for: control)[action]
    }

    /// Parses a device code. Unknown values are kept visible rather than being
    /// silently converted to "do nothing".
    func action(for code: Int, control: GestureControl) -> GestureAction {
        let table = codes(for: control)
        return table.first(where: { $0.value == code })?.key ?? .unsupported
    }
}

/// The context a gesture code belongs to. The same numeric value can mean
/// different things in different contexts.
enum GestureControl {
    case doubleTap
    case tripleTap
    case doubleTapInCall
    case longTap
    case longTapInCall
    case noiseCycle
    case combinedLongTap
    case swipe
    case powerButton
}

// MARK: - Profiles
//
// These mirror OpenFreebuds' `per_model` handler lists. A capability is only
// enabled when the corresponding handler exists there; we do not assume that
// an unlisted feature will answer.

extension DeviceProfile {
    private static func tap(_ options: [GestureAction],
                            codes: [GestureAction: Int] = standardTapCodes,
                            left: Bool = true,
                            right: Bool = true,
                            inCall: Bool = false) -> TapCapability {
        TapCapability(options: options, codes: codes,
                      left: left, right: right, inCall: inCall)
    }

    private static func splitHold(left: Bool = true, right: Bool = true,
                                  inCall: Bool = false,
                                  extraOptions: Bool = false) -> LongTapCapability {
        LongTapCapability(kind: .split, left: left, right: right,
                          inCall: inCall, extraOptions: extraOptions)
    }

    private static func presets(_ ids: [Int]) -> [EQPreset] {
        ids.map { EQPreset(id: $0, title: title(forPreset: $0)) }
    }

    /// Display name for a built-in preset id. Only ids used by a predefined
    /// table need a special name; reported-only models get a readable fallback.
    static func title(forPreset id: Int) -> String {
        switch id {
        case 1: return "Default"
        case 2: return "Hard Bass"
        case 3: return "Treble"
        case 9: return "Voices"
        default: return "Preset \(id)"
        }
    }

    /// Pro 3/4/FreeClip and Pro 5 put the default preset at id 5 and use the
    /// other ids for Hard Bass, Treble and Voices.
    private static let renumberedPresets = [
        EQPreset(id: 5, title: "Default"),
        EQPreset(id: 1, title: "Hard Bass"),
        EQPreset(id: 2, title: "Treble"),
        EQPreset(id: 9, title: "Voices"),
    ]

    static let freeBuds3 = DeviceProfile(
        id: "freebuds-3",
        title: "FreeBuds 3",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: true,
        anc: nil,
        autoPause: false,
        lowLatency: false,
        soundPreference: false,
        eq: nil,
        doubleTap: tap([.none, .assistant, .playPause, .noiseControl, .nextTrack],
                       codes: freeBuds3TapCodes),
        tripleTap: nil,
        longTap: nil,
        swipe: false,
        powerButton: false,
        noiseCycle: false
    )

    static let freeBuds4i = DeviceProfile(
        id: "freebuds-4i",
        title: "FreeBuds 4i / HONOR Earbuds 2 (SE/Lite)",
        fallbackPort: 16,
        hasTWSBattery: true,
        hasInEar: true,
        anc: ANCCapability(levels: [], voiceBoost: false),
        autoPause: true,
        lowLatency: false,
        soundPreference: false,
        eq: nil,
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack]),
        tripleTap: nil,
        longTap: splitHold(left: true, right: false),
        swipe: false,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBuds5i = DeviceProfile(
        id: "freebuds-5i",
        title: "FreeBuds 5i",
        fallbackPort: 16,
        hasTWSBattery: true,
        hasInEar: true,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: false),
        autoPause: true,
        lowLatency: true,
        soundPreference: true,
        eq: EQCapability(builtIns: presets([1, 2, 3, 9]), custom: false, readsState: true),
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack], inCall: true),
        tripleTap: tap([.none, .nextTrack, .previousTrack]),
        longTap: splitHold(left: true, right: true),
        swipe: true,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBuds6i = DeviceProfile(
        id: "freebuds-6i",
        title: "FreeBuds 6i",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: true,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: false),
        autoPause: true,
        lowLatency: true,
        soundPreference: true,
        eq: EQCapability(builtIns: presets([1, 2, 3, 9]), custom: true, readsState: true),
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack], inCall: true),
        tripleTap: tap([.none, .nextTrack, .previousTrack]),
        longTap: splitHold(left: true, right: true),
        swipe: true,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBudsPro = DeviceProfile(
        id: "freebuds-pro",
        title: "FreeBuds Pro",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: true,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: true),
        autoPause: false,
        lowLatency: false,
        soundPreference: false,
        eq: nil,
        doubleTap: nil,
        tripleTap: nil,
        longTap: splitHold(left: true, right: true),
        swipe: true,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBudsPro2 = DeviceProfile(
        id: "freebuds-pro-2",
        title: "FreeBuds Pro 2",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: true,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra], voiceBoost: false),
        autoPause: true,
        lowLatency: false,
        soundPreference: true,
        eq: EQCapability(builtIns: presets([1, 2, 3]), custom: false, readsState: true),
        doubleTap: nil,
        tripleTap: nil,
        longTap: splitHold(left: true, right: true),
        swipe: true,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBudsPro3 = DeviceProfile(
        id: "freebuds-pro-3",
        title: "FreeBuds Pro 3 / Pro 4 / FreeClip",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: true,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: true),
        autoPause: true,
        lowLatency: true,
        soundPreference: true,
        eq: EQCapability(builtIns: renumberedPresets, custom: true, readsState: true),
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack]),
        tripleTap: nil,
        longTap: splitHold(left: true, right: true),
        swipe: true,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBudsPro5 = DeviceProfile(
        id: "freebuds-pro-5",
        title: "FreeBuds Pro 5",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: true,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: true),
        autoPause: true,
        lowLatency: true,
        soundPreference: true,
        eq: EQCapability(builtIns: renumberedPresets, custom: true, readsState: true),
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack]),
        tripleTap: nil,
        longTap: splitHold(left: true, right: true),
        swipe: true,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBudsSE = DeviceProfile(
        id: "freebuds-se",
        title: "FreeBuds SE",
        fallbackPort: 16,
        hasTWSBattery: true,
        hasInEar: false,
        anc: nil,
        autoPause: false,
        lowLatency: false,
        soundPreference: false,
        eq: nil,
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack]),
        tripleTap: nil,
        longTap: nil,
        swipe: false,
        powerButton: false,
        noiseCycle: false
    )

    static let freeBudsSE2 = DeviceProfile(
        id: "freebuds-se-2",
        title: "FreeBuds SE 2",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: false,
        anc: nil,
        autoPause: false,
        lowLatency: true,
        soundPreference: false,
        eq: EQCapability(builtIns: presets([1, 2, 3, 9]), custom: false, readsState: true),
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack], inCall: true),
        tripleTap: tap([.none, .nextTrack, .previousTrack]),
        // SE 2 exposes only the in-call long-press action.
        longTap: splitHold(left: false, right: false, inCall: true),
        swipe: false,
        powerButton: false,
        noiseCycle: false
    )

    static let freeBudsSE4 = DeviceProfile(
        id: "freebuds-se-4",
        title: "FreeBuds SE 4 ANC",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: false,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: false),
        autoPause: false,
        lowLatency: true,
        soundPreference: false,
        eq: EQCapability(builtIns: presets([1, 2, 3, 9]), custom: false, readsState: true),
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack], inCall: true),
        tripleTap: tap([.none, .nextTrack, .previousTrack]),
        longTap: splitHold(left: true, right: true, extraOptions: true),
        swipe: false,
        powerButton: false,
        noiseCycle: true
    )

    static let freeBudsStudio = DeviceProfile(
        id: "freebuds-studio",
        title: "FreeBuds Studio",
        fallbackPort: 1,
        hasTWSBattery: false,
        hasInEar: false,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: true),
        autoPause: true,
        lowLatency: false,
        soundPreference: false,
        eq: EQCapability(builtIns: presets([1, 2, 3]), custom: false, readsState: false),
        doubleTap: nil,
        tripleTap: nil,
        longTap: nil,
        swipe: false,
        powerButton: false,
        noiseCycle: false
    )

    static let freeClip2 = DeviceProfile(
        id: "freeclip-2",
        title: "FreeClip 2",
        fallbackPort: 1,
        hasTWSBattery: true,
        hasInEar: true,
        anc: nil,
        autoPause: true,
        lowLatency: true,
        soundPreference: true,
        eq: EQCapability(builtIns: presets([1, 2, 3, 9]), custom: false, readsState: true),
        doubleTap: tap([.none, .assistant, .playPause, .nextTrack, .previousTrack]),
        tripleTap: tap([.none, .nextTrack, .previousTrack]),
        longTap: splitHold(left: true, right: true, extraOptions: true),
        swipe: true,
        powerButton: false,
        noiseCycle: true
    )

    static let freeLacePro = DeviceProfile(
        id: "freelace-pro",
        title: "FreeLace Pro",
        fallbackPort: 16,
        hasTWSBattery: false,
        hasInEar: false,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra], voiceBoost: false),
        autoPause: false,
        lowLatency: false,
        soundPreference: false,
        eq: nil,
        doubleTap: nil,
        tripleTap: nil,
        longTap: LongTapCapability(kind: .combined, left: false, right: false,
                                   inCall: false, extraOptions: false),
        swipe: false,
        powerButton: true,
        noiseCycle: false
    )

    static let freeLacePro2 = DeviceProfile(
        id: "freelace-pro-2",
        title: "FreeLace Pro 2",
        fallbackPort: 16,
        hasTWSBattery: false,
        hasInEar: false,
        anc: ANCCapability(levels: [.normal, .comfort, .ultra, .dynamic], voiceBoost: true),
        autoPause: false,
        lowLatency: true,
        soundPreference: true,
        eq: EQCapability(builtIns: presets([1, 2, 3, 9]), custom: true, readsState: true,
                         usesReportedBuiltIns: true),
        doubleTap: nil,
        tripleTap: nil,
        longTap: splitHold(left: true, right: false),
        swipe: false,
        powerButton: false,
        noiseCycle: true
    )
}
