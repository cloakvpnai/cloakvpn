import Foundation

/// What the gateway assigned to this device.
public struct TunnelSettings: Equatable {
    public var address = ""
    public var netmask = ""
    public var gateway = ""
    public var dns: [String] = []
    public var routes: [String] = []
    public var redirectGateway = false
    public var mtu = 1500
    public var pingInterval: TimeInterval = 10
    public var pingRestart: TimeInterval = 60
    var peerID: UInt32 = 0
}

/// One negotiation: its own reliable control channel, TLS handshake and data keys.
final class KeyState {
    let keyID: UInt8
    let resetOpcode: Opcode
    let tls: TLSSession
    let startedAt: TimeInterval

    // reliable control channel
    var nextSendID: UInt32 = 0
    var queue: [(Opcode, Data)] = []
    var inflight: [UInt32: (opcode: Opcode, payload: Data, sentAt: TimeInterval, wait: TimeInterval)] = [:]
    var nextReceiveID: UInt32 = 0
    var receiveBuffer: [UInt32: (Opcode, Data)] = [:]

    // progress
    var peerResetSeen = false
    var tlsDone = false
    var keyExchangeReceived = false
    var keys: DataKeys?
    var establishedAt: TimeInterval = 0

    // data channel counters
    var sendPacketID: UInt32 = 0
    var replay = ReplayWindow()

    init(keyID: UInt8, resetOpcode: Opcode, identity: TunnelIdentity, now: TimeInterval) throws {
        self.keyID = keyID
        self.resetOpcode = resetOpcode
        self.tls = try TLSSession(identity: identity)
        self.startedAt = now
        queue.append((resetOpcode, Data()))
    }
}

/// The CNSA 2.0 tunnel client. A plain state machine: the owner feeds it
/// datagrams and clock ticks and sends what it hands back. Not thread safe;
/// call everything from one queue.
public final class TunnelSession {
    public enum State: Equatable { case idle, connecting, connected, failed(String), closed }

    public private(set) var state: State = .idle
    public private(set) var settings = TunnelSettings()
    /// "TLSv1.3 TLS_AES_256_GCM_SHA384 MLKEM1024 mldsa87" for the keys now in use.
    public private(set) var suite = ""
    public private(set) var rekeyCount = 0
    public private(set) var lastKeyTime: TimeInterval = 0

    /// Datagram to send to the gateway.
    public var send: (Data) -> Void = { _ in }
    /// IP packet received through the tunnel.
    public var onPacket: (Data) -> Void = { _ in }
    public var onStateChange: (State) -> Void = { _ in }
    public var log: (String) -> Void = { _ in }

    private let identity: TunnelIdentity
    private let rekeyInterval: TimeInterval
    private let sessionID = randomBytes(8)
    private var remoteSessionID: Data?

    private var pending: KeyState?
    private var current: KeyState?
    private var previous: KeyState?

    private var pushReplySeen = false
    private var lastPushRequest: TimeInterval = 0
    private var lastSent: TimeInterval = 0
    private var lastReceived: TimeInterval = 0
    private var exitNotify = false

    private static let sendWindow = 4
    private static let controlChunk = 1100
    private static let handshakeTimeout: TimeInterval = 30
    private static let receiveAhead: UInt32 = 32

    /// rekeyInterval: seconds between full new handshakes started by this device;
    /// 0 leaves the timing to the gateway.
    public init(identity: TunnelIdentity, rekeyInterval: TimeInterval = 300) {
        self.identity = identity
        self.rekeyInterval = rekeyInterval
    }

    // MARK: lifecycle

    public func start(now: TimeInterval) {
        guard state == .idle else { return }
        do {
            pending = try KeyState(keyID: 0, resetOpcode: .hardResetClient, identity: identity, now: now)
            lastReceived = now
            setState(.connecting)
            flush(pending!, now: now)
        } catch {
            fail("\(error)")
        }
    }

    /// Tell the gateway we are leaving, then stop.
    public func close(now: TimeInterval) {
        if state == .connected, exitNotify, let ks = current {
            try? ks.tls.write(Data("EXIT".utf8) + [0])
            enqueueTLSOutput(ks)
            flush(ks, now: now)
        }
        pending = nil; current = nil; previous = nil
        if case .failed = state { return }
        setState(.closed)
    }

    private func fail(_ reason: String) {
        pending = nil; current = nil; previous = nil
        setState(.failed(reason))
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onStateChange(new)
    }

    private var isLive: Bool { state == .connecting || state == .connected }

    // MARK: input

    public func receive(_ datagram: Data, now: TimeInterval) {
        guard isLive, let first = datagram.first else { return }
        let opcode = first >> 3
        if opcode == Opcode.dataV2.rawValue || opcode == Opcode.dataV1.rawValue {
            receiveData(datagram, keyID: first & 7, now: now)
            return
        }
        do {
            try receiveControl(try ControlPacket.parse(datagram), now: now)
        } catch {
            // a malformed or unexpected control packet is dropped, never trusted
            log("dropped control packet: \(error)")
        }
    }

    private func receiveData(_ datagram: Data, keyID: UInt8, now: TimeInterval) {
        guard let ks = [current, previous].compactMap({ $0 }).first(where: { $0.keyID == keyID }),
              let keys = ks.keys,
              let opened = DataChannel.open(datagram, keys: keys),
              ks.replay.accept(opened.packetID) else { return }
        lastReceived = now
        if opened.plaintext == DataChannel.ping { return }
        onPacket(opened.plaintext)
    }

    private func keyState(_ keyID: UInt8) -> KeyState? {
        [pending, current, previous].compactMap { $0 }.first { $0.keyID == keyID }
    }

    private func receiveControl(_ packet: ControlPacket, now: TimeInterval) throws {
        if let known = remoteSessionID {
            guard packet.sessionID == known else { throw TunnelError("wrong session") }
        } else {
            guard packet.opcode == .hardResetServer else { throw TunnelError("unexpected first packet") }
            remoteSessionID = packet.sessionID
        }
        if !packet.acks.isEmpty {
            guard packet.remoteSessionID == sessionID else { throw TunnelError("acknowledgement for another session") }
        }
        lastReceived = now

        var ks = keyState(packet.keyID)
        if ks == nil {
            // the gateway is asking for new keys
            guard packet.opcode == .softReset, state == .connected, pending == nil,
                  packet.keyID != 0, packet.packetID == 0 else { throw TunnelError("no such negotiation") }
            ks = try KeyState(keyID: packet.keyID, resetOpcode: .softReset, identity: identity, now: now)
            pending = ks
            log("gateway requested new keys (key \(packet.keyID))")
        }
        guard let ks else { return }

        for id in packet.acks { ks.inflight[id] = nil }

        if let id = packet.packetID {
            acknowledge(id, keyID: ks.keyID)
            if id >= ks.nextReceiveID, id - ks.nextReceiveID < TunnelSession.receiveAhead {
                ks.receiveBuffer[id] = (packet.opcode, packet.payload)
            }
            while let (opcode, payload) = ks.receiveBuffer.removeValue(forKey: ks.nextReceiveID) {
                ks.nextReceiveID += 1
                try deliver(opcode, payload, to: ks)
            }
        }
        do {
            try advance(ks, now: now)
        } catch {
            negotiationFailed(ks, "\(error)")
            return
        }
        flush(ks, now: now)
    }

    private func acknowledge(_ id: UInt32, keyID: UInt8) {
        guard let remote = remoteSessionID else { return }
        let ack = ControlPacket(opcode: .ack, keyID: keyID, sessionID: sessionID, acks: [id], remoteSessionID: remote)
        send(ack.encoded())
    }

    private func deliver(_ opcode: Opcode, _ payload: Data, to ks: KeyState) throws {
        switch opcode {
        case .hardResetServer, .softReset:
            ks.peerResetSeen = true
        case .control:
            guard ks.peerResetSeen else { throw TunnelError("data before reset") }
            try ks.tls.feed(payload)
        default:
            throw TunnelError("unexpected control packet")
        }
    }

    // MARK: negotiation

    private func advance(_ ks: KeyState, now: TimeInterval) throws {
        guard ks.peerResetSeen else { return }
        if !ks.tlsDone {
            let done = try ks.tls.handshake()
            enqueueTLSOutput(ks)
            guard done else { return }
            ks.tlsDone = true
            log("handshake complete: \(ks.tls.summary)")
            try ks.tls.write(keyExchangeMessage())
            enqueueTLSOutput(ks)
        }
        for record in try ks.tls.readRecords() {
            if !ks.keyExchangeReceived {
                try parseKeyExchange(record)
                ks.keyExchangeReceived = true
            } else {
                try handleControlMessage(record, from: ks)
            }
        }
        enqueueTLSOutput(ks)
        guard ks.keyExchangeReceived, ks.keys == nil else { return }
        if ks.keyID == 0 && !pushReplySeen {
            if now - lastPushRequest >= 2 {
                lastPushRequest = now
                try ks.tls.write(Data("PUSH_REQUEST".utf8) + [0])
                enqueueTLSOutput(ks)
            }
            return
        }
        try activate(ks, now: now)
    }

    private func activate(_ ks: KeyState, now: TimeInterval) throws {
        ks.keys = try DataKeys(exported: try ks.tls.export(label: DataKeys.exporterLabel, length: DataKeys.exporterLength))
        ks.establishedAt = now
        let first = current == nil
        previous = current
        current = ks
        if pending === ks { pending = nil }
        suite = ks.tls.summary
        lastKeyTime = now
        if first {
            setState(.connected)
        } else {
            rekeyCount += 1
            log("new keys in use (key \(ks.keyID), rekey \(rekeyCount))")
        }
    }

    private func negotiationFailed(_ ks: KeyState, _ reason: String) {
        if current == nil {
            fail(reason)
        } else {
            // keep the current keys; the gateway enforces their lifetime
            log("rekey failed: \(reason)")
            if pending === ks { pending = nil }
        }
    }

    /// The client half of OpenVPN's key method 2 message. With exported keys
    /// the random fields are not used for key derivation but are still sent.
    private func keyExchangeMessage() -> Data {
        var m = Data([0, 0, 0, 0, 2])
        m.append(randomBytes(48 + 32 + 32))
        appendString(&m, "V4,dev-type tun,link-mtu 1549,tun-mtu 1500,proto UDPv4,cipher AES-256-GCM,auth [null-digest],keysize 256,key-method 2,tls-client")
        m.appendUInt16(0) // no username
        m.appendUInt16(0) // no password
        // IV_PROTO: data v2 (2) + exported keys (8) + exit notification (128)
        appendString(&m, "IV_VER=2.6.14\nIV_PLAT=lattice\nIV_PROTO=138\nIV_NCP=2\nIV_CIPHERS=AES-256-GCM\n")
        return m
    }

    private func appendString(_ m: inout Data, _ s: String) {
        let bytes = Data(s.utf8) + [0]
        m.appendUInt16(UInt16(bytes.count))
        m.append(bytes)
    }

    private func parseKeyExchange(_ record: Data) throws {
        var r = Reader(record)
        guard try r.uint32() == 0, try r.byte() == 2 else { throw TunnelError("unexpected key exchange message") }
        _ = try r.take(64)
        let length = Int(try r.uint16())
        _ = try r.take(length)
    }

    private func handleControlMessage(_ record: Data, from ks: KeyState) throws {
        guard let text = String(data: record.prefix { $0 != 0 }, encoding: .utf8) else { return }
        if text.hasPrefix("PUSH_REPLY") {
            guard !pushReplySeen else { return }
            try applyPushReply(text)
            pushReplySeen = true
        } else if text.hasPrefix("AUTH_FAILED") {
            throw TunnelError("gateway refused this device")
        } else if text.hasPrefix("RESTART") || text.hasPrefix("HALT") || text.hasPrefix("EXIT") {
            fail("gateway ended the session")
        }
    }

    private func applyPushReply(_ text: String) throws {
        var s = TunnelSettings()
        var exportedKeys = false
        for option in text.split(separator: ",").dropFirst() {
            let parts = option.split(separator: " ").map(String.init)
            guard let name = parts.first else { continue }
            switch name {
            case "ifconfig" where parts.count >= 3: s.address = parts[1]; s.netmask = parts[2]
            case "route-gateway" where parts.count >= 2: s.gateway = parts[1]
            case "route" where parts.count >= 2: s.routes.append(parts.dropFirst().joined(separator: " "))
            case "redirect-gateway": s.redirectGateway = true
            case "dhcp-option" where parts.count >= 3 && parts[1] == "DNS": s.dns.append(parts[2])
            case "tun-mtu" where parts.count >= 2: s.mtu = Int(parts[1]) ?? 1500
            case "ping" where parts.count >= 2: s.pingInterval = TimeInterval(parts[1]) ?? 10
            case "ping-restart" where parts.count >= 2: s.pingRestart = TimeInterval(parts[1]) ?? 60
            case "peer-id" where parts.count >= 2: s.peerID = UInt32(parts[1]) ?? 0
            case "cipher" where parts.count >= 2:
                guard parts[1] == "AES-256-GCM" else { throw TunnelError("gateway chose cipher \(parts[1])") }
            case "key-derivation" where parts.count >= 2: exportedKeys = exportedKeys || parts[1] == "tls-ekm"
            case "protocol-flags":
                exportedKeys = exportedKeys || parts.contains("tls-ekm")
                exitNotify = parts.contains("cc-exit")
            case "comp-lzo", "compress":
                throw TunnelError("gateway asked for compression")
            default: break
            }
        }
        guard exportedKeys else { throw TunnelError("gateway did not agree to TLS-exported keys") }
        guard !s.address.isEmpty else { throw TunnelError("gateway assigned no address") }
        settings = s
    }

    // MARK: output

    private func enqueueTLSOutput(_ ks: KeyState) {
        let out = ks.tls.drain()
        var offset = 0
        while offset < out.count {
            let end = min(offset + TunnelSession.controlChunk, out.count)
            ks.queue.append((.control, out.subdata(in: offset..<end)))
            offset = end
        }
    }

    private func flush(_ ks: KeyState, now: TimeInterval) {
        while ks.inflight.count < TunnelSession.sendWindow, !ks.queue.isEmpty {
            let (opcode, payload) = ks.queue.removeFirst()
            let id = ks.nextSendID
            ks.nextSendID += 1
            ks.inflight[id] = (opcode, payload, now, 1)
            transmit(ks, id: id, opcode: opcode, payload: payload)
        }
    }

    private func transmit(_ ks: KeyState, id: UInt32, opcode: Opcode, payload: Data) {
        let packet = ControlPacket(opcode: opcode, keyID: ks.keyID, sessionID: sessionID, packetID: id, payload: payload)
        send(packet.encoded())
    }

    /// Send one IP packet through the tunnel.
    public func sendPacket(_ packet: Data, now: TimeInterval) {
        guard state == .connected else { return }
        seal(packet, now: now)
    }

    private func seal(_ plaintext: Data, now: TimeInterval) {
        guard let ks = current, let keys = ks.keys, ks.sendPacketID < UInt32.max - 1 else { return }
        ks.sendPacketID += 1
        guard let datagram = try? DataChannel.seal(plaintext, keys: keys, keyID: ks.keyID,
                                                   peerID: settings.peerID, packetID: ks.sendPacketID) else { return }
        lastSent = now
        send(datagram)
    }

    // MARK: clock

    /// Call a few times a second.
    public func tick(now: TimeInterval) {
        guard isLive else { return }
        for ks in [pending, current].compactMap({ $0 }) {
            for (id, entry) in ks.inflight where now - entry.sentAt >= entry.wait {
                ks.inflight[id] = (entry.opcode, entry.payload, now, min(entry.wait * 2, 8))
                transmit(ks, id: id, opcode: entry.opcode, payload: entry.payload)
            }
            do {
                try advance(ks, now: now)
            } catch {
                negotiationFailed(ks, "\(error)")
                continue
            }
            flush(ks, now: now)
        }
        guard isLive else { return }
        if let ks = pending, now - ks.startedAt > TunnelSession.handshakeTimeout {
            negotiationFailed(ks, "handshake timed out")
            guard isLive else { return }
        }
        guard state == .connected, let ks = current else { return }
        if now - lastReceived > settings.pingRestart {
            fail("gateway stopped answering")
            return
        }
        if now - lastSent >= settings.pingInterval {
            seal(DataChannel.ping, now: now)
        }
        if rekeyInterval > 0, pending == nil, now - ks.establishedAt >= rekeyInterval {
            let next: UInt8 = ks.keyID >= 7 ? 1 : ks.keyID + 1
            do {
                let fresh = try KeyState(keyID: next, resetOpcode: .softReset, identity: identity, now: now)
                pending = fresh
                flush(fresh, now: now)
            } catch {
                log("rekey could not start: \(error)")
            }
        }
    }
}
