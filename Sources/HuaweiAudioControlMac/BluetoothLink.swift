// SPDX-License-Identifier: GPL-3.0-only
// Protocol data and algorithms derived from OpenFreebuds (GPL-3.0).

import Foundation
import IOBluetooth

enum LinkError: LocalizedError {
    case noPairedDevice
    case notConnected
    case controlServiceMissing
    case connectFailed(IOReturn)
    case channelFailed(IOReturn)
    case openTimedOut
    case readTimedOut
    case busy
    case closed
    case writeNotApplied
    case writeFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .noPairedDevice:
            return "Pair your earbuds in System Settings › Bluetooth first."
        case .notConnected:
            return "The earbuds are not connected to this Mac."
        case .controlServiceMissing:
            return "The earbuds did not expose their control channel. Reconnect them."
        case .connectFailed(let status):
            return "The Mac could not connect to the earbuds (\(status)). If they are connected to your phone, disconnect them there first."
        case .channelFailed(let status):
            return "The control channel could not be opened (\(status))."
        case .openTimedOut:
            return "The earbuds did not answer the control channel. They may still be busy with another device — disconnect them there and try again."
        case .readTimedOut:
            return "The earbuds did not answer. Try again in a moment."
        case .busy:
            return "Another earbud request is still running."
        case .closed:
            return "The connection to the earbuds was lost."
        case .writeNotApplied:
            return "The earbuds did not apply that change."
        case .writeFailed(let status):
            return "The earbuds could not be reached (\(status))."
        }
    }
}

/// Owns the Bluetooth serial (RFCOMM) session with one pair of earbuds.
///
/// The earbuds answer a single request at a time and keep the session until the
/// channel is closed properly, so the channel is closed on quit and every
/// request carries its own deadline. All work happens on the main actor, which
/// is where IOBluetooth delivers its callbacks.
@MainActor
final class BluetoothLink: NSObject {
    private let addressKey = "pairedDeviceAddress"

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var decoder = FrameDecoder()

    private var openContinuation: CheckedContinuation<Void, Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var sdpContinuation: CheckedContinuation<Void, Never>?
    private var pending: (token: UUID, wants: (ControlPacket) -> Bool,
                          continuation: CheckedContinuation<ControlPacket, Error>)?

    private var openToken = UUID()
    private var connectToken = UUID()
    private var sdpToken = UUID()

    /// Serialises access so only one request is ever outstanding.
    private let gate = AsyncGate()

    var model: String?
    /// The friendly Bluetooth name (e.g. "iBuds"), used for display.
    var deviceName: String?
    var onPacket: ((ControlPacket) -> Void)?
    var onChannelClosed: (() -> Void)?

    var isChannelOpen: Bool {
        channel?.isOpen() == true
    }

    override init() {
        super.init()
        delegate.owner = self
    }

    private let delegate = LinkDelegate()

    // MARK: - Device discovery

    /// Names we recognise as Huawei/Honor earbuds. The earbuds can be renamed
    /// freely by the user (e.g. "iBuds"), so this is only a heuristic for the
    /// very first run before an address has been remembered.
    private static let knownNameFragments = [
        "FreeBuds", "iBuds", "Earbuds", "FreeClip", "FreeLace", "Studio",
    ]

    /// The paired device to talk to: the saved address if it is still paired,
    /// otherwise the first paired device that looks like earbuds.
    private func pairedDevice() throws -> IOBluetoothDevice {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []

        // A remembered address always wins, so a renamed pair keeps working.
        if let saved = UserDefaults.standard.string(forKey: addressKey),
           let match = paired.first(where: { $0.addressString.caseInsensitiveCompare(saved) == .orderedSame }) {
            return match
        }

        let candidates = paired.filter { device in
            guard let name = device.name else { return false }
            return Self.knownNameFragments.contains {
                name.localizedCaseInsensitiveContains($0)
            }
        }

        // Fall back to a single paired device if nothing matched by name.
        if let match = candidates.first { return match }
        if paired.count == 1, let only = paired.first { return only }

        throw LinkError.noPairedDevice
    }

    // MARK: - Connection

    /// Brings the audio link up, then opens the control channel and reads the
    /// model name to confirm the earbuds are actually answering.
    func open() async throws {
        await gate.acquire()
        defer { gate.release() }
        // A cancelled connect belongs to a panel that is already gone; do not
        // open a session on its behalf.
        try Task.checkCancellation()

        if isChannelOpen { return }

        let found = try pairedDevice()
        device = found

        if !found.isConnected() {
            try await connect(found)
        }

        // The name is usually enough to pick the right SDP fallback port (most
        // models use 1, several use 16). SDP remains authoritative.
        let hint = DeviceProfile.resolve(name: found.name, modelCode: nil).fallbackPort
        try await openChannel(found, preferredPort: hint)

        // The Bluetooth name is what we show in the header. The info read
        // supplements it with firmware/serial and a hardware model code, which
        // is shown as a detail rather than used as the display name.
        deviceName = found.name

        do {
            // `performRead` rather than `read`: the gate is already held here and
            // taking it twice would deadlock.
            let info = try await performRead(.info)
            model = info.text(10) ?? info.text(15)
            UserDefaults.standard.set(found.addressString, forKey: addressKey)
        } catch {
            closeChannel()
            throw error
        }
    }

    private func connect(_ device: IOBluetoothDevice) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            let token = UUID()
            connectToken = token

            let status = device.openConnection(delegate)
            if status != kIOReturnSuccess {
                finishConnect(.failure(LinkError.connectFailed(status)))
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if self.connectContinuation != nil, self.connectToken == token {
                    self.finishConnect(.failure(LinkError.connectFailed(kIOReturnTimeout)))
                }
            }
        }
    }

    private func finishConnect(_ result: Result<Void, Error>) {
        let continuation = connectContinuation
        connectContinuation = nil
        continuation?.resume(with: result)
    }

    /// Refreshes the SDP cache. The earbuds only advertise the SPP service once
    /// the ACL link is up, so this runs after connecting.
    private func refreshServices(_ device: IOBluetoothDevice) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sdpContinuation = continuation
            let token = UUID()
            sdpToken = token

            let status = device.performSDPQuery(delegate)
            if status != kIOReturnSuccess {
                finishSDP()
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self.sdpContinuation != nil, self.sdpToken == token {
                    self.finishSDP()
                }
            }
        }
    }

    private func finishSDP() {
        let continuation = sdpContinuation
        sdpContinuation = nil
        continuation?.resume()
    }

    /// Resolves the RFCOMM channel that carries the control protocol.
    ///
    /// The earbuds advertise a standard Serial Port Profile service (`0x1101`)
    /// on port 1 next to a "Private COM" decoy on port 2. The SPP service is
    /// authoritative; the name and the known port are only fallbacks for
    /// firmware that reports its SDP records incompletely.
    private func controlPort(for device: IOBluetoothDevice,
                             preferredPort: BluetoothRFCOMMChannelID) -> BluetoothRFCOMMChannelID? {
        let services = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []

        func port(of service: IOBluetoothSDPServiceRecord) -> BluetoothRFCOMMChannelID? {
            var port: BluetoothRFCOMMChannelID = 0
            guard service.getRFCOMMChannelID(&port) == kIOReturnSuccess, port != 0 else { return nil }
            return port
        }

        if let service = services.first(where: { $0.matchesUUID16(0x1101) }),
           let port = port(of: service) {
            return port
        }
        if let service = services.first(where: {
            ($0.getServiceName() ?? "").localizedCaseInsensitiveContains("serial")
        }), let port = port(of: service) {
            return port
        }
        // Port 1 is a safe fallback only for models that actually use it. A
        // port-1-only record can be the "Private COM" decoy on models whose
        // control channel lives on port 16.
        if preferredPort == 1,
           let service = services.first(where: { port(of: $0) == 1 }),
           let port = port(of: service) {
            return port
        }
        return nil
    }

    private func openChannel(_ device: IOBluetoothDevice, preferredPort: UInt8) async throws {
        guard device.isConnected() else { throw LinkError.notConnected }

        var servicePort = controlPort(for: device, preferredPort: preferredPort)
        if servicePort == nil {
            // Services may not have been queried yet; refresh and try again.
            await refreshServices(device)
            servicePort = controlPort(for: device, preferredPort: preferredPort)
        }

        // Prefer the SDP answer, then the model's known port, then both common
        // Huawei ports. Some firmware omits or mislabels its SPP record.
        var ports: [BluetoothRFCOMMChannelID] = []
        if let servicePort { ports.append(servicePort) }
        for port in [preferredPort, BluetoothRFCOMMChannelID(16), BluetoothRFCOMMChannelID(1)]
        where !ports.contains(port) {
            ports.append(port)
        }

        var lastError: Error = LinkError.controlServiceMissing
        for (index, port) in ports.enumerated() {
            // The earbuds keep the previous RFCOMM session for a moment after
            // an ungraceful close, so an open is retried a couple of times.
            let attempts = (servicePort != nil && index == 0) ? 3 : 2
            for attempt in 0..<attempts {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                }
                do {
                    try await openChannel(device, port: port)
                    return
                } catch {
                    lastError = error
                    closeChannel()
                }
            }
        }
        throw lastError
    }

    private func openChannel(_ device: IOBluetoothDevice, port: BluetoothRFCOMMChannelID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            openContinuation = continuation
            let token = UUID()
            openToken = token

            var opened: IOBluetoothRFCOMMChannel?
            let status = device.openRFCOMMChannelAsync(&opened, withChannelID: port, delegate: delegate)
            if status == kIOReturnSuccess {
                channel = opened
            } else {
                finishOpen(.failure(LinkError.channelFailed(status)))
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if self.openContinuation != nil, self.openToken == token {
                    self.finishOpen(.failure(LinkError.openTimedOut))
                }
            }
        }
    }

    private func finishOpen(_ result: Result<Void, Error>) {
        let continuation = openContinuation
        openContinuation = nil
        continuation?.resume(with: result)
    }

    /// Closes only the control channel, leaving the audio link alone.
    ///
    /// The earbuds keep a stale session if the channel is abandoned, so this is
    /// always called explicitly — on disconnect, on quit, and before a retry.
    private func closeChannel() {
        model = nil
        let current = channel
        channel = nil
        current?.setDelegate(nil)
        current?.close()
        decoder = FrameDecoder()

        if let request = pending {
            pending = nil
            request.continuation.resume(throwing: LinkError.closed)
        }
        if openContinuation != nil { finishOpen(.failure(LinkError.closed)) }
    }

    /// Releases the control channel but keeps the earbuds connected to the Mac,
    /// so audio keeps playing.
    func disconnect() {
        closeChannel()
        device = nil
    }

    /// Called on quit. The earbuds keep a stale session if the channel is
    /// abandoned, so it must always be released explicitly.
    func shutdown() {
        closeChannel()
        device = nil
    }

    // MARK: - Requests

    /// Reads the state of one feature.
    func read(_ feature: Feature) async throws -> ControlPacket {
        await gate.acquire()
        defer { gate.release() }
        // Waiting for the gate can outlive the polling task that asked for the
        // read. Don't spend the device's single request slot on it.
        try Task.checkCancellation()
        return try await performRead(feature)
    }

    /// Writes a setting and confirms it by reading the feature back.
    func write(_ feature: Feature, fields: [UInt8: [UInt8]], matches: @escaping (ControlPacket) -> Bool) async throws -> ControlPacket {
        await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()

        guard isChannelOpen else { throw LinkError.closed }
        guard let command = feature.writeCommand else { throw LinkError.notConnected }

        try send(ControlPacket(command, fields))

        // Give the earbuds a moment to apply the change, then read it back.
        // The 6i acknowledges most writes with the same command id; that
        // acknowledgement does not necessarily carry the new state, so the
        // read-back is what the UI is allowed to trust. Low-latency mode takes
        // about a second on the devices OpenFreebuds supports.
        let initialDelay: UInt64 = feature == .latency ? 1_000_000_000 : 250_000_000
        for attempt in 0..<3 {
            try await Task.sleep(nanoseconds: initialDelay + UInt64(attempt) * 250_000_000)
            let packet = try await performRead(feature)
            if matches(packet) { return packet }
        }
        // The last read already reached `onPacket`, so the UI is showing the
        // earbuds' real state. Tell the user the change did not stick.
        throw LinkError.writeNotApplied
    }

    /// Sends a write without waiting for a read-back.
    ///
    /// FreeBuds Studio accepts the equalizer command but never reports its
    /// active preset. This is used only for that kind of write-only setting.
    func writeNowait(_ feature: Feature, fields: [UInt8: [UInt8]]) async throws {
        await gate.acquire()
        defer { gate.release() }
        try Task.checkCancellation()

        guard isChannelOpen else { throw LinkError.closed }
        guard let command = feature.writeCommand else { throw LinkError.notConnected }
        try send(ControlPacket(command, fields))
    }

    /// Low-level read: sends a request naming the wanted keys, and resolves on
    /// the first acceptable answer.
    private func performRead(_ feature: Feature) async throws -> ControlPacket {
        guard isChannelOpen else { throw LinkError.closed }
        return try await request(ControlPacket.read(feature.readCommand, keys: feature.keys),
                                 wants: feature.accepts,
                                 timeout: 3_000_000_000)
    }

    /// One outstanding request at a time, resolved by its acceptance test.
    private func request(_ packet: ControlPacket, wants: @escaping (ControlPacket) -> Bool, timeout: UInt64) async throws -> ControlPacket {
        guard pending == nil else { throw LinkError.busy }
        guard isChannelOpen else { throw LinkError.closed }
        return try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            pending = (token, wants, continuation)
            do {
                try send(packet)
            } catch {
                pending = nil
                continuation.resume(throwing: error)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeout)
                if let request = self.pending, request.token == token {
                    self.pending = nil
                    request.continuation.resume(throwing: LinkError.readTimedOut)
                }
            }
        }
    }

    private func send(_ packet: ControlPacket) throws {
        guard let channel, channel.isOpen() else { throw LinkError.closed }
        var bytes = packet.encoded
        let count = UInt16(bytes.count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            channel.writeSync(buffer.baseAddress, length: count)
        }
        if status != kIOReturnSuccess { throw LinkError.writeFailed(status) }
    }

    // MARK: - Callbacks from the delegate

    fileprivate func handleConnection(status: IOReturn) {
        if status == kIOReturnSuccess {
            finishConnect(.success(()))
        } else {
            finishConnect(.failure(LinkError.connectFailed(status)))
        }
    }

    fileprivate func handleSDPComplete() {
        finishSDP()
    }

    fileprivate func handleChannelOpen(status: IOReturn) {
        if status == kIOReturnSuccess {
            finishOpen(.success(()))
        } else {
            finishOpen(.failure(LinkError.channelFailed(status)))
        }
    }

    fileprivate func handleChannelClosed(identifier: ObjectIdentifier) {
        guard let channel, ObjectIdentifier(channel) == identifier else { return }
        self.channel = nil
        // Drop any half-received frame so the next session starts clean.
        decoder = FrameDecoder()
        if openContinuation != nil { finishOpen(.failure(LinkError.closed)) }
        if let request = pending {
            pending = nil
            request.continuation.resume(throwing: LinkError.closed)
        }
        onChannelClosed?()
    }

    fileprivate func handleData(_ bytes: [UInt8], identifier: ObjectIdentifier) {
        guard let channel, ObjectIdentifier(channel) == identifier else { return }

        for packet in decoder.feed(bytes) {
            // 0x0106 arrives unsolicited right after the channel opens on the
            // 6i. It is a status notification, not a rejection: reads that
            // follow it work normally. It (and other unsolicited pushes) are
            // delivered to the UI and ignored unless they answer a request.
            onPacket?(packet)
            if let request = pending, request.wants(packet) {
                pending = nil
                request.continuation.resume(returning: packet)
            }
        }
    }

    /// Feature read/write pairing plus the acceptance test for a reply.
    enum Feature: Hashable {
        case battery, info, noiseControl, eq
        case doubleTap, tripleTap, hold, swipe, noiseCycle, powerButton
        case autoPause, latency, soundPreference, inEar

        var readCommand: UInt16 {
            switch self {
            case .battery: return Cmd.battery
            case .info: return Cmd.info
            case .noiseControl: return Cmd.noiseState
            case .eq: return Cmd.eqState
            case .doubleTap: return Cmd.doubleTapRead
            case .tripleTap: return Cmd.tripleTapRead
            case .hold: return Cmd.holdRead
            case .swipe: return Cmd.swipeRead
            case .noiseCycle: return Cmd.cycleRead
            case .powerButton: return Cmd.doubleTapRead
            case .autoPause: return Cmd.autoPauseRead
            case .latency: return Cmd.latencyReadWrite
            case .soundPreference: return Cmd.soundPrefRead
            case .inEar: return Cmd.inEarState
            }
        }

        /// Parameter keys to ask for on a read.
        var keys: [UInt8] {
            switch self {
            case .battery: return Cmd.batteryKeys
            case .info: return Cmd.infoKeys
            case .noiseControl: return Cmd.noiseKeys
            case .eq: return Cmd.eqKeys
            // OpenFreebuds asks for keys 1 and 2 even though the response also
            // carries the option list (3) and in-call action (4); mirrors that
            // request rather than sending keys some firmware may not expect.
            case .doubleTap, .tripleTap: return [1, 2]
            case .hold: return [1, 2]
            case .swipe, .noiseCycle: return [1, 2]
            case .powerButton: return [1]
            case .autoPause: return [1]
            case .latency: return [2]
            case .soundPreference: return [1]
            case .inEar: return [1, 2]
            }
        }

        var writeCommand: UInt16? {
            switch self {
            case .noiseControl: return Cmd.noiseControl
            case .eq: return Cmd.eqSelect
            case .doubleTap, .powerButton: return Cmd.doubleTapWrite
            case .tripleTap: return Cmd.tripleTapWrite
            case .hold: return Cmd.holdWrite
            case .swipe: return Cmd.swipeWrite
            case .noiseCycle: return Cmd.cycleWrite
            case .autoPause: return Cmd.autoPauseWrite
            case .latency: return Cmd.latencyReadWrite
            case .soundPreference: return Cmd.soundPrefWrite
            case .battery, .info, .inEar: return nil
            }
        }

        /// True when this packet answers the feature's read.
        func accepts(_ packet: ControlPacket) -> Bool {
            guard packet.command == readCommand else { return false }
            switch self {
            case .info:
                // Any populated info response means the device is answering.
                // Some firmware omits the model-name keys, so don't gate on a
                // specific field or a valid device would fail to connect.
                return !packet.fields.isEmpty
            case .battery:
                return packet.byte(1) != nil || (packet.raw(2)?.count ?? 0) >= 2
            case .noiseControl:
                return packet.raw(1)?.count == 2
            case .eq:
                return packet.byte(2) != nil || packet.raw(3) != nil
            case .autoPause:
                return packet.byte(1) != nil
            case .latency:
                return packet.byte(2) != nil
            case .soundPreference:
                return packet.byte(1) != nil || packet.byte(2) != nil
            case .doubleTap, .tripleTap, .powerButton:
                return packet.raw(1) != nil || packet.raw(2) != nil
                    || packet.raw(3) != nil || packet.raw(4) != nil
            case .hold:
                return packet.raw(1) != nil || packet.raw(2) != nil || packet.raw(4) != nil
            case .inEar:
                return packet.raw(1) != nil || packet.raw(2) != nil
            default:
                return packet.raw(1) != nil || packet.raw(2) != nil
            }
        }
    }
}

/// IOBluetooth delivers its callbacks on the run loop of the thread that opened
/// the connection — always the main thread here. The proxy forwards them to the
/// main actor while keeping the Objective-C protocol conformance nonisolated,
/// which is what Swift 6 requires.
private final class LinkDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate, IOBluetoothDeviceAsyncCallbacks {
    weak var owner: BluetoothLink?

    nonisolated func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated {
            owner?.handleConnection(status: status)
        }
    }

    nonisolated func remoteNameRequestComplete(_ device: IOBluetoothDevice!, status: IOReturn) {}

    nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated {
            owner?.handleSDPComplete()
        }
    }

    nonisolated func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        MainActor.assumeIsolated {
            owner?.handleChannelOpen(status: status)
        }
    }

    nonisolated func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        let identifier = ObjectIdentifier(channel)
        MainActor.assumeIsolated {
            owner?.handleChannelClosed(identifier: identifier)
        }
    }

    nonisolated func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard let pointer, (1...8192).contains(length) else { return }
        let bytes = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: length))
        let identifier = ObjectIdentifier(channel)
        MainActor.assumeIsolated {
            owner?.handleData(bytes, identifier: identifier)
        }
    }
}

/// A tiny async mutex used to keep earbud traffic strictly serial.
///
/// `release` is nonisolated and hops onto the actor, so it may complete a beat
/// later than the `defer` that called it. A waiting acquirer therefore always
/// sees `isHeld == true` until the hand-off actually happens, which keeps the
/// gate held across the gap rather than letting a second holder in.
private actor AsyncGate {
    private var isHeld = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var order: [UUID] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        let id = UUID()
        order.append(id)
        await withCheckedContinuation { waiters[id] = $0 }
    }

    nonisolated func release() {
        Task { await self.unlock() }
    }

    private func unlock() {
        // Hand the lock to the oldest waiter without ever dropping it, so the
        // lock stays held between consecutive holders.
        while !order.isEmpty {
            let id = order.removeFirst()
            if let continuation = waiters.removeValue(forKey: id) {
                continuation.resume()
                return
            }
        }
        isHeld = false
    }
}
