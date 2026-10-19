// SPDX-License-Identifier: GPL-3.0-only
// Protocol data and algorithms derived from OpenFreebuds (GPL-3.0).

import Foundation

// MARK: - Wire frame
//
// The earbuds expose a serial control channel over Bluetooth Classic (SPP, RFCOMM).
// A frame looks like:
//
//     5A | length (2, BE) | 00 | command (2, BE) | TLV… | CRC16 (2, BE)
//
// `length` counts the command plus the TLV payload plus one. Every parameter is
// `key (1) | size (1) | value (size)`. The CRC is CRC-16/XMODEM over every byte
// before it, and frames may arrive fragmented, concatenated, or interleaved with
// unsolicited pushes, so parsing is incremental and resynchronises on the header.
//
// Command semantics below follow OpenFreebuds' Huawei drivers. The framing and
// most command ids are shared, but payload details, gesture codes and feature
// availability vary by model; `DeviceProfile` owns those differences.

struct ControlPacket: Equatable, Sendable {
    let command: UInt16
    var fields: [UInt8: [UInt8]]

    init(_ command: UInt16, _ fields: [UInt8: [UInt8]] = [:]) {
        self.command = command
        self.fields = fields
    }

    /// A read request lists the wanted keys with empty values.
    static func read(_ command: UInt16, keys: [UInt8]) -> ControlPacket {
        // Built by hand rather than `Dictionary(uniqueKeysWithValues:)` so a
        // repeated key cannot trap; the last occurrence simply wins.
        var fields: [UInt8: [UInt8]] = [:]
        for key in keys { fields[key] = [] }
        return ControlPacket(command, fields)
    }

    var encoded: [UInt8] {
        var body: [UInt8] = [UInt8(command >> 8), UInt8(command & 0xFF)]
        for key in fields.keys.sorted() {
            let value = fields[key] ?? []
            body.append(key)
            body.append(UInt8(value.count))
            body.append(contentsOf: value)
        }
        var frame: [UInt8] = [0x5A, UInt8((body.count + 1) >> 8), UInt8((body.count + 1) & 0xFF), 0x00]
        frame.append(contentsOf: body)
        let checksum = crc16XModem(frame)
        frame.append(UInt8(checksum >> 8))
        frame.append(UInt8(checksum & 0xFF))
        return frame
    }

    // MARK: Field accessors

    func raw(_ key: UInt8) -> [UInt8]? {
        guard let value = fields[key], !value.isEmpty else { return nil }
        return value
    }

    func byte(_ key: UInt8) -> Int? {
        guard let value = raw(key), value.count == 1 else { return nil }
        return Int(value[0])
    }

    /// Reads a one-byte value as a signed integer (gesture actions use -1).
    func signedByte(_ key: UInt8) -> Int? {
        guard let value = byte(key) else { return nil }
        return Int(Int8(bitPattern: UInt8(truncatingIfNeeded: value)))
    }

    func bool(_ key: UInt8) -> Bool? {
        byte(key).map { $0 != 0 }
    }

    func text(_ key: UInt8) -> String? {
        guard let value = raw(key) else { return nil }
        let trimmed = value.drop(while: { $0 == 0 })
        guard let string = String(bytes: trimmed, encoding: .utf8)?
            .trimmingCharacters(in: .controlCharacters), !string.isEmpty else {
            return nil
        }
        return string
    }
}

func crc16XModem(_ bytes: some Sequence<UInt8>) -> UInt16 {
    var crc: UInt16 = 0
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

/// Reassembles frames out of an arbitrary byte stream.
struct FrameDecoder {
    private var buffer: [UInt8] = []

    private static let maxFrame = 8192

    mutating func feed(_ bytes: [UInt8]) -> [ControlPacket] {
        buffer.append(contentsOf: bytes)
        var packets: [ControlPacket] = []

        while buffer.count >= 6 {
            // Drop garbage until the next plausible header.
            guard let header = buffer.firstIndex(of: 0x5A) else {
                buffer.removeAll(keepingCapacity: true)
                break
            }
            if header > 0 { buffer.removeFirst(header) }
            guard buffer.count >= 6 else { break }

            let length = Int(buffer[1]) << 8 | Int(buffer[2])
            let total = length + 5
            // A frame is at least header(4) + command(2) + crc(2).
            guard (8...Self.maxFrame).contains(total) else {
                buffer.removeFirst()
                continue
            }
            // Byte 3 is a constant zero we can use to reject noise.
            guard buffer[3] == 0 else {
                buffer.removeFirst()
                continue
            }
            guard buffer.count >= total else { break }

            let frame = Array(buffer[0..<total])
            let expected = crc16XModem(frame.dropLast(2))
            let actual = UInt16(frame[total - 2]) << 8 | UInt16(frame[total - 1])
            guard expected == actual else {
                // Bad CRC: this 0x5A was noise, step past it and resynchronise.
                buffer.removeFirst()
                continue
            }
            buffer.removeFirst(total)

            if let packet = Self.decode(frame) {
                packets.append(packet)
            }
        }

        if buffer.count > Self.maxFrame {
            buffer.removeAll(keepingCapacity: true)
        }
        return packets
    }

    private static func decode(_ frame: [UInt8]) -> ControlPacket? {
        let command = UInt16(frame[4]) << 8 | UInt16(frame[5])
        var fields: [UInt8: [UInt8]] = [:]
        var index = 6
        let end = frame.count - 2
        while index < end {
            guard index + 2 <= end else { return nil }
            let size = Int(frame[index + 1])
            let valueEnd = index + 2 + size
            guard valueEnd <= end, fields[frame[index]] == nil else { return nil }
            fields[frame[index]] = Array(frame[(index + 2)..<valueEnd])
            index = valueEnd
        }
        return ControlPacket(command, fields)
    }
}

// MARK: - Command ids

/// Command identifiers captured from the official Huawei app and cross-checked
/// against OpenFreebuds' Huawei drivers.
///
/// Most writes are acknowledged with the same command id; some are confirmed by
/// reading the matching state command back. Unsolicited pushes (battery change,
/// in-ear state) arrive without a request.
enum Cmd {
    // Readings
    static let battery: UInt16 = 0x0108
    static let batteryPush: UInt16 = 0x0127
    static let info: UInt16 = 0x0107

    // Noise control
    /// State: parameter 1 is `[level, mode]`.
    static let noiseState: UInt16 = 0x2B2A
    /// Write: parameter 1 is `[mode, level]`; acknowledged with parameter 2.
    static let noiseControl: UInt16 = 0x2B04

    // Equalizer
    static let eqState: UInt16 = 0x2B4A
    static let eqSelect: UInt16 = 0x2B49

    // In-ear state.
    // 0x2B03 is a push-only notification on some models; parameters 8 and 9
    // carry the left and right state.
    static let wearState: UInt16 = 0x2B03
    // 0x2B25 answers a direct read on the FreeBuds 6i and also arrives as a
    // wear transition push. Parameters 1 and 2 carry the left and right state.
    static let inEarState: UInt16 = 0x2B25

    // Gestures
    static let doubleTapRead: UInt16 = 0x0120
    static let doubleTapWrite: UInt16 = 0x011F
    static let tripleTapRead: UInt16 = 0x0126
    static let tripleTapWrite: UInt16 = 0x0125
    static let holdRead: UInt16 = 0x2B17
    static let holdWrite: UInt16 = 0x2B16
    static let swipeRead: UInt16 = 0x2B1F
    static let swipeWrite: UInt16 = 0x2B1E
    static let cycleRead: UInt16 = 0x2B19
    static let cycleWrite: UInt16 = 0x2B18

    // Toggles
    static let autoPauseRead: UInt16 = 0x2B11
    static let autoPauseWrite: UInt16 = 0x2B10
    static let latencyReadWrite: UInt16 = 0x2B6C
    static let soundPrefRead: UInt16 = 0x2BA3
    static let soundPrefWrite: UInt16 = 0x2BA2

    /// Parameter keys each read asks for.
    static let batteryKeys: [UInt8] = [1, 2, 3]
    static let infoKeys: [UInt8] = [3, 7, 9, 10, 15]
    static let noiseKeys: [UInt8] = [1, 2]
    static let eqKeys: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
}

// MARK: - Gesture tables

/// A logical gesture action.
///
/// Models do not share a single set of device codes: FreeBuds 3 uses `4` for
/// "next track" while newer models use `2`, and some long-press actions use a
/// different value from a double-tap action with the same meaning. The profile
/// layer (`DeviceProfile`) owns the code tables; this enum is only the stable
/// value the UI and snapshot work with.
enum GestureAction: String, CaseIterable, Identifiable, Hashable {
    case none
    case assistant
    case playPause
    case nextTrack
    case previousTrack
    case noiseControl
    case answer
    case changeVolume
    case volumeUp
    case volumeDown
    case switchDevice
    case cycleOffOn
    case cycleAll
    case cycleOnAwareness
    case cycleOffAwareness
    /// A value the connected model reports that is not in its profile table.
    /// It is displayed but never offered as a new choice.
    case unsupported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Do nothing"
        case .assistant: return "Voice assistant"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .noiseControl: return "Switch noise control"
        case .answer: return "Answer call"
        case .changeVolume: return "Change volume"
        case .volumeUp: return "Increase volume"
        case .volumeDown: return "Decrease volume"
        case .switchDevice: return "Switch device"
        case .cycleOffOn: return "Off ↔ Cancelling"
        case .cycleAll: return "All three modes"
        case .cycleOnAwareness: return "Cancelling ↔ Awareness"
        case .cycleOffAwareness: return "Off ↔ Awareness"
        case .unsupported: return "Unsupported"
        }
    }

    /// Values that can be written to a device. `unsupported` is read-only.
    var isWritable: Bool { self != .unsupported }
}

// MARK: - Sound modes

enum NoiseMode: Int, CaseIterable, Identifiable {
    case off = 0x00
    case cancelling = 0x01
    case awareness = 0x02

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .cancelling: return "Noise cancelling"
        case .awareness: return "Awareness"
        }
    }

    var shortTitle: String {
        switch self {
        case .off: return "Off"
        case .cancelling: return "Cancelling"
        case .awareness: return "Awareness"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "speaker.slash"
        case .cancelling: return "waveform.slash"
        case .awareness: return "waveform"
        }
    }
}

/// Cancelling strength, only meaningful while the mode is `cancelling`.
///
/// The 6i reports `0` normal, `1` comfort, `2` ultra and `3` dynamic.
enum CancellingLevel: Int, CaseIterable, Identifiable {
    case normal = 0x00
    case comfort = 0x01
    case ultra = 0x02
    case dynamic = 0x03

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .comfort: return "Comfort"
        case .ultra: return "Ultra"
        case .dynamic: return "Dynamic"
        }
    }
}

/// Awareness flavour, only meaningful while the mode is `awareness`.
enum AwarenessMode: Int, CaseIterable, Identifiable {
    case voiceBoost = 0x01
    case standard = 0x02

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .voiceBoost: return "Voice boost"
        case .standard: return "Standard"
        }
    }
}

/// A sound profile offered by the earbuds.
///
/// The 6i has four built-in presets and can store custom ones in device memory.
/// Custom presets are shown read-only; selecting one applies its stored curve.
struct EQPreset: Equatable, Hashable, Identifiable {
    let id: Int
    let title: String
    /// Raw 10-band curve for a custom preset, in device byte order.
    var customData: [UInt8]?

    /// Presets the 6i always offers, even when parameter 3 is omitted.
    static let builtIn: [EQPreset] = [
        EQPreset(id: 1, title: "Default"),
        EQPreset(id: 2, title: "Hard Bass"),
        EQPreset(id: 3, title: "Treble"),
        EQPreset(id: 9, title: "Voices"),
    ]

    static func title(for id: Int) -> String {
        switch id {
        case 1: return "Default"
        case 2: return "Hard Bass"
        case 3: return "Treble"
        case 9: return "Voices"
        default: return "Preset \(id)"
        }
    }

    init(id: Int, title: String? = nil, customData: [UInt8]? = nil) {
        self.id = id
        self.title = title ?? EQPreset.title(for: id)
        self.customData = customData
    }

    /// Parameters for the `2B49` write. Built-ins only need their id; custom
    /// presets use the extended payload that carries the curve and label.
    var writeFields: [UInt8: [UInt8]] {
        guard let customData else { return [1: [UInt8(truncatingIfNeeded: id)]] }
        return [
            1: [UInt8(truncatingIfNeeded: id)],
            2: [UInt8(customData.count)],
            3: customData,
            4: Array(title.utf8),
            5: [1],
        ]
    }
}

/// Whether a "sound quality" or "connection stability" preference is active.
enum SoundPreference: Int, CaseIterable, Identifiable {
    case stability = 0x00
    case quality = 0x01

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .stability: return "Connection stability"
        case .quality: return "Sound quality"
        }
    }

    var symbol: String {
        switch self {
        case .stability: return "wifi"
        case .quality: return "hifispeaker"
        }
    }
}
