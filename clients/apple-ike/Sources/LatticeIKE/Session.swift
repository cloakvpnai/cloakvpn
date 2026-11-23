import CryptoKit
import Foundation

/// Sends and receives UDP datagrams to the gateway's port 4500.
public protocol DatagramTransport {
    func send(_ datagram: Data) throws
    /// Returns nil when nothing arrived within `timeout`.
    func receive(timeout: TimeInterval) throws -> Data?
}

/// IKEv2 initiator restricted to the CNSA 2.0 IPsec profile:
///   IKE: AES-256-GCM, PRF-HMAC-SHA-384, ECP-384 in IKE_SA_INIT,
///        ML-KEM-1024 in IKE_INTERMEDIATE, ML-DSA-87 certificate authentication.
///   ESP: AES-256-GCM in UDP encapsulation.
/// Any other algorithm selected by the peer ends the connection.
public final class IKESession {
    public struct Config {
        public var gatewayID: String
        public var clientID: String
        public var ca: MLDSACertificate
        public var clientCertificateDER: Data
        public var clientKey: MLDSA87.PrivateKey
        public init(gatewayID: String, clientID: String, ca: MLDSACertificate, clientCertificateDER: Data, clientKey: MLDSA87.PrivateKey) {
            self.gatewayID = gatewayID; self.clientID = clientID; self.ca = ca
            self.clientCertificateDER = clientCertificateDER; self.clientKey = clientKey
        }
    }
    public struct Established {
        public let virtualIP: [UInt8]?
        public let dnsServers: [[UInt8]]
        public let ikeSuite: String
        public let espSuite: String
        public let authentication: String
    }

    private struct Keys {
        let d: Data, ei: GCMKey, er: GCMKey, pi: Data, pr: Data
        init(skeyseed: Data, ni: Data, nr: Data, spiI: Data, spiR: Data) {
            let m = PRF.plus(key: skeyseed, seed: ni + nr + spiI + spiR, length: 48 + 36 + 36 + 48 + 48)
            d = Data(m.prefix(48))
            ei = GCMKey(material: Data(m.dropFirst(48).prefix(36)))
            er = GCMKey(material: Data(m.dropFirst(84).prefix(36)))
            pi = Data(m.dropFirst(120).prefix(48))
            pr = Data(m.dropFirst(168).prefix(48))
        }
    }

    static let ikeTransforms: [Transform] = [
        Transform(type: Wire.tENCR, id: Wire.encrAESGCM16, keyLength: 256),
        Transform(type: Wire.tPRF, id: Wire.prfHMACSHA384, keyLength: nil),
        Transform(type: Wire.tKE, id: Wire.groupECP384, keyLength: nil),
        Transform(type: Wire.tADDKE1, id: Wire.groupMLKEM1024, keyLength: nil),
    ]
    static let espTransforms: [Transform] = [
        Transform(type: Wire.tENCR, id: Wire.encrAESGCM16, keyLength: 256),
        Transform(type: Wire.tESN, id: 0, keyLength: nil),
    ]
    static let fragmentPayload = 1100
    static let marker = Data(count: 4)   // non-ESP marker on port 4500

    private let transport: DatagramTransport
    private let config: Config
    private var spiI = randomBytes(8), spiR = Data(count: 8)
    private var ni = Data(), nr = Data()
    private var keys: Keys!
    private var ivCounter: UInt64 = 0
    private var nextMessageID: UInt32 = 0
    public private(set) var esp: ESPTunnel?
    /// Guards `esp` and `retiringESP`: packets are sent from a different thread than the one that
    /// reads the socket and performs re-keys.
    private let lock = NSLock()
    /// ESP packets that arrived while an IKE exchange was waiting for its response.
    private var inbound: [Data] = []
    /// The Child SA being replaced; still accepted inbound until the gateway confirms its deletion.
    private var retiringESP: ESPTunnel?
    /// False once either side has deleted the IKE SA.
    public private(set) var isOpen = false
    /// How many times the data keys have been replaced on this connection.
    public private(set) var childRekeys = 0

    static let espRekeyTransforms: [Transform] = [
        Transform(type: Wire.tENCR, id: Wire.encrAESGCM16, keyLength: 256),
        Transform(type: Wire.tKE, id: Wire.groupMLKEM1024, keyLength: nil),
        Transform(type: Wire.tESN, id: 0, keyLength: nil),
    ]

    public init(transport: DatagramTransport, config: Config) {
        self.transport = transport; self.config = config
    }

    // MARK: - Message framing

    private func header(next: UInt8, exchange: UInt8, flags: UInt8, messageID: UInt32, length: Int) -> Data {
        var d = Data(); d.append(spiI); d.append(spiR); d.u8(next); d.u8(0x20); d.u8(exchange); d.u8(flags); d.u32(messageID); d.u32(UInt32(length))
        return d
    }

    /// Encrypts `inner` (an encoded payload chain) into one or more datagrams, fragmenting per RFC 7383.
    private func protect(exchange: UInt8, flags: UInt8, messageID: UInt32, first: UInt8, inner: Data, key: GCMKey) throws -> [Data] {
        func iv() -> Data { ivCounter += 1; var d = Data(); d.u64(ivCounter); return d }
        if inner.count <= Self.fragmentPayload {
            let total = 28 + 4 + 8 + inner.count + 1 + 16
            var aad = header(next: Wire.pSK, exchange: exchange, flags: flags, messageID: messageID, length: total)
            aad.u8(first); aad.u8(0); aad.u16(UInt16(total - 28))
            let v = iv()
            return [Self.marker + aad + v + (try key.seal(inner + Data([0]), iv: v, aad: aad))]
        }
        var chunks: [Data] = [], o = 0
        while o < inner.count { let n = min(Self.fragmentPayload, inner.count - o); chunks.append(try inner.slice(o, n)); o += n }
        var out: [Data] = []
        for (i, c) in chunks.enumerated() {
            let total = 28 + 8 + 8 + c.count + 1 + 16
            var aad = header(next: Wire.pSKF, exchange: exchange, flags: flags, messageID: messageID, length: total)
            aad.u8(i == 0 ? first : 0); aad.u8(0); aad.u16(UInt16(total - 28)); aad.u16(UInt16(i + 1)); aad.u16(UInt16(chunks.count))
            let v = iv()
            out.append(Self.marker + aad + v + (try key.seal(c + Data([0]), iv: v, aad: aad)))
        }
        return out
    }

    /// Decrypts one SK or SKF message. Returns (first inner payload type, fragment number, total, plaintext).
    private func unprotect(_ msg: Data, key: GCMKey) throws -> (first: UInt8, number: Int, total: Int, plain: Data) {
        let next = try msg.rU8(16)
        let headLen: Int
        var number = 1, total = 1
        switch next {
        case Wire.pSK: headLen = 32
        case Wire.pSKF: headLen = 36; number = Int(try msg.rU16(32)); total = Int(try msg.rU16(34))
        default: throw IKEError.malformed("expected an encrypted payload")
        }
        let first = try msg.rU8(28)
        let plain = try key.open(try msg.slice(headLen + 8, msg.count - headLen - 8), iv: try msg.slice(headLen, 8), aad: try msg.slice(0, headLen))
        guard let padLen = plain.last, plain.count >= Int(padLen) + 1 else { throw IKEError.malformed("padding") }
        return (first, number, total, Data(plain.prefix(plain.count - Int(padLen) - 1)))
    }

    /// Sends a request and waits for the matching response, retransmitting on loss.
    /// `handle` is called for each response datagram and returns true when the response is complete.
    private func roundTrip(_ datagrams: [Data], messageID: UInt32, what: String, handle: (Data) throws -> Bool) throws {
        for attempt in 0..<5 {
            for d in datagrams { try transport.send(d) }
            let deadline = Date().addingTimeInterval(attempt == 0 ? 2 : 4)
            while Date() < deadline {
                guard let d = try transport.receive(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { break }
                guard d.count >= 32, d.prefix(4) == Self.marker else {
                    // Data keeps flowing during a re-key: hold the packet for the next receivePacket call.
                    if let p = try? openESP(d) { inbound.append(p) }
                    continue
                }
                let msg = Data(d.dropFirst(4))
                guard try msg.slice(0, 8) == spiI, Int(try msg.rU32(24)) == msg.count else { continue }
                if try msg.rU8(19) & Wire.flagResponse == 0 {
                    if keys != nil { try? answer(request: msg) }
                    continue
                }
                guard try msg.rU32(20) == messageID else { continue }
                if try handle(msg) { return }
            }
        }
        throw IKEError.timeout(what)
    }

    private func encryptedExchange(exchange: UInt8, first: UInt8, inner: Data) throws -> (flags: UInt8, first: UInt8, inner: Data) {
        let id = nextMessageID
        let datagrams = try protect(exchange: exchange, flags: Wire.flagInitiator, messageID: id, first: first, inner: inner, key: keys.ei)
        var parts: [Int: Data] = [:], firstType: UInt8 = 0, flags: UInt8 = 0, complete = Data()
        try roundTrip(datagrams, messageID: id, what: "exchange \(exchange)") { msg in
            let r = try unprotect(msg, key: keys.er)
            flags = try msg.rU8(19)
            if r.number == 1 { firstType = r.first }
            parts[r.number] = r.plain
            guard parts.count == r.total else { return false }
            for i in 1...r.total { guard let p = parts[i] else { return false }; complete.append(p) }
            return true
        }
        nextMessageID += 1
        return (flags, firstType, complete)
    }

    private func failOnErrorNotify(_ payloads: [Payload]) throws {
        for p in payloads where p.type == Wire.pNotify {
            let type = try p.body.rU16(2)
            if type < 16384 { throw IKEError.notify(type, Wire.errorNames[type] ?? "error notify") }
        }
    }
    private func notifies(_ payloads: [Payload]) throws -> Set<UInt16> {
        Set(try payloads.filter { $0.type == Wire.pNotify }.map { try $0.body.rU16(2) })
    }

    // MARK: - Handshake

    public func connect() throws -> Established {
        // IKE_SA_INIT: ECP-384, and the offer of exactly one proposal.
        let ecdh = P384.KeyAgreement.PrivateKey()
        ni = randomBytes(32)
        var ke = Data(); ke.u16(Wire.groupECP384); ke.u16(0); ke.append(ecdh.publicKey.rawRepresentation)
        var hashes = Data(); hashes.u16(5); hashes.u16(3); hashes.u16(4)   // Identity, SHA2-384, SHA2-512
        let initBody = Payload.encode([
            Payload(type: Wire.pSA, body: Proposal.encode(protocolID: 1, spi: Data(), Self.ikeTransforms)),
            Payload(type: Wire.pKE, body: ke),
            Payload(type: Wire.pNonce, body: ni),
            // Placeholder NAT-detection hashes: they never match, so both sides use UDP encapsulation.
            Payload.notify(Wire.nNATSrc, randomBytes(20)),
            Payload.notify(Wire.nNATDst, randomBytes(20)),
            Payload.notify(Wire.nFragmentation),
            Payload.notify(Wire.nSignatureHashAlgorithms, hashes),
            Payload.notify(Wire.nIntermediate),
        ])
        let initMsg = header(next: Wire.pSA, exchange: Wire.saInit, flags: Wire.flagInitiator, messageID: 0, length: 28 + initBody.count) + initBody
        var initResp = Data()
        try roundTrip([Self.marker + initMsg], messageID: 0, what: "IKE_SA_INIT") { msg in initResp = msg; return true }
        let p0 = try Payload.decode(first: try initResp.rU8(16), Data(initResp.dropFirst(28)))
        try failOnErrorNotify(p0)
        spiR = try initResp.slice(8, 8)
        guard let sa0 = p0.first(where: { $0.type == Wire.pSA }), let ke0 = p0.first(where: { $0.type == Wire.pKE }),
              let n0 = p0.first(where: { $0.type == Wire.pNonce }) else { throw IKEError.malformed("IKE_SA_INIT response") }
        let chosen = try Proposal.decode(sa0.body)
        guard chosen.protocolID == 1, chosen.transforms == Set(Self.ikeTransforms) else { throw IKEError.policy("gateway selected a different IKE proposal") }
        guard try ke0.body.rU16(0) == Wire.groupECP384, ke0.body.count == 4 + 96 else { throw IKEError.policy("gateway key exchange is not ECP-384") }
        let seen = try notifies(p0)
        guard seen.contains(Wire.nIntermediate), seen.contains(Wire.nFragmentation) else { throw IKEError.policy("gateway lacks intermediate exchange or fragmentation") }
        nr = n0.body
        guard nr.count >= 32 else { throw IKEError.policy("gateway nonce shorter than 256 bits") }
        let peer = try P384.KeyAgreement.PublicKey(rawRepresentation: Data(ke0.body.dropFirst(4)))
        let g = try ecdh.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
        let keys0 = Keys(skeyseed: PRF.mac(key: ni + nr, g), ni: ni, nr: nr, spiI: spiI, spiR: spiR)
        keys = keys0
        nextMessageID = 1

        // IKE_INTERMEDIATE: ML-KEM-1024 (RFC 9370). The new shared secret is mixed into every IKE key.
        let kem = try MLKEM1024.PrivateKey()
        var ke1 = Data(); ke1.u16(Wire.groupMLKEM1024); ke1.u16(0); ke1.append(kem.publicKey.rawRepresentation)
        let interInner = Payload.encode([Payload(type: Wire.pKE, body: ke1)])
        let inter = try encryptedExchange(exchange: Wire.intermediate, first: Wire.pKE, inner: interInner)
        let p1 = try Payload.decode(first: inter.first, inter.inner)
        try failOnErrorNotify(p1)
        guard let rke = p1.first(where: { $0.type == Wire.pKE }), try rke.body.rU16(0) == Wire.groupMLKEM1024, rke.body.count == 4 + 1568 else {
            throw IKEError.policy("gateway did not answer with ML-KEM-1024")
        }
        let ss = try kem.decapsulate(Data(rke.body.dropFirst(4))).withUnsafeBytes { Data($0) }
        // RFC 9242 section 3.3.2: both intermediate messages are bound into the AUTH payloads.
        func intAuthInput(flags: UInt8, first: UInt8, inner: Data) -> Data {
            var d = header(next: Wire.pSK, exchange: Wire.intermediate, flags: flags, messageID: 1, length: 32 + inner.count)
            d.u8(first); d.u8(0); d.u16(UInt16(4 + inner.count)); d.append(inner)
            return d
        }
        var intAuth = PRF.mac(key: keys0.pi, intAuthInput(flags: Wire.flagInitiator, first: Wire.pKE, inner: interInner))
        intAuth.append(PRF.mac(key: keys0.pr, intAuthInput(flags: inter.flags, first: inter.first, inner: inter.inner)))
        intAuth.u32(2)   // message ID of IKE_AUTH
        keys = Keys(skeyseed: PRF.mac(key: keys0.d, ss + ni + nr), ni: ni, nr: nr, spiI: spiI, spiR: spiR)

        // IKE_AUTH: ML-DSA-87 signature over the transcript, plus the first Child SA.
        let idi = Data([2, 0, 0, 0]) + Data(config.clientID.utf8)   // ID_FQDN
        let signedI = initMsg + nr + PRF.mac(key: keys.pi, idi) + intAuth
        let auth = Data([14, 0, 0, 0, UInt8(Wire.mldsa87AlgorithmID.count)]) + Wire.mldsa87AlgorithmID + (try config.clientKey.signature(for: signedI))
        var cp = Data([1, 0, 0, 0]); cp.u16(1); cp.u16(0); cp.u16(3); cp.u16(0)   // request an address and DNS
        var inSPI = randomBytes(4); inSPI[0] |= 0x80
        var ts = Data([1, 0, 0, 0, 7, 0]); ts.u16(16); ts.u16(0); ts.u16(0xffff); ts.u32(0); ts.u32(0xffff_ffff)
        let authInner = Payload.encode([
            Payload(type: Wire.pIDi, body: idi),
            Payload(type: Wire.pCERT, body: Data([4]) + config.clientCertificateDER),
            // Ask the gateway to send its certificate. The list of acceptable CAs is left
            // empty; the certificate is checked against the pinned Lattice CA on receipt.
            Payload(type: Wire.pCERTREQ, body: Data([4])),
            Payload(type: Wire.pAUTH, body: auth),
            Payload(type: Wire.pCP, body: cp),
            Payload(type: Wire.pSA, body: Proposal.encode(protocolID: 3, spi: inSPI, Self.espTransforms)),
            Payload(type: Wire.pTSi, body: ts),
            Payload(type: Wire.pTSr, body: ts),
        ])
        let ar = try encryptedExchange(exchange: Wire.auth, first: Wire.pIDi, inner: authInner)
        let p2 = try Payload.decode(first: ar.first, ar.inner)
        try failOnErrorNotify(p2)
        guard let idr = p2.first(where: { $0.type == Wire.pIDr }), let certP = p2.first(where: { $0.type == Wire.pCERT && $0.body.first == 4 }),
              let authR = p2.first(where: { $0.type == Wire.pAUTH }), let sa2 = p2.first(where: { $0.type == Wire.pSA }) else {
            throw IKEError.malformed("IKE_AUTH response")
        }
        guard try idr.body.rU8(0) == 2, String(decoding: idr.body.dropFirst(4), as: UTF8.self) == config.gatewayID else {
            throw IKEError.authentication("gateway identified itself with an unexpected name")
        }
        let gwCert = try MLDSACertificate(der: Data(certP.body.dropFirst()))
        try gwCert.verify(issuedBy: config.ca, expectedDNSName: config.gatewayID)
        guard try authR.body.rU8(0) == 14 else { throw IKEError.policy("gateway did not use signature authentication") }
        let algLen = Int(try authR.body.rU8(4))
        guard try authR.body.slice(5, algLen) == Wire.mldsa87AlgorithmID else { throw IKEError.policy("gateway signature is not ML-DSA-87") }
        let signedR = initResp + ni + PRF.mac(key: keys.pr, idr.body) + intAuth
        guard gwCert.publicKey.isValidSignature(Data(authR.body.dropFirst(5 + algLen)), for: signedR) else {
            throw IKEError.authentication("gateway signature over the handshake is invalid")
        }

        let child = try Proposal.decode(sa2.body)
        guard child.protocolID == 3, child.transforms == Set(Self.espTransforms), child.spi.count == 4 else {
            throw IKEError.policy("gateway selected a different ESP proposal")
        }
        esp = ESPTunnel(outSPI: child.spi, inSPI: inSPI, keymat: PRF.plus(key: keys.d, seed: ni + nr, length: 72))
        isOpen = true

        var vip: [UInt8]?, dns: [[UInt8]] = []
        if let cpR = p2.first(where: { $0.type == Wire.pCP }) {
            var o = 4
            while o + 4 <= cpR.body.count {
                let type = try cpR.body.rU16(o) & 0x7fff, len = Int(try cpR.body.rU16(o + 2))
                let v = [UInt8](try cpR.body.slice(o + 4, len))
                if type == 1, len >= 4 { vip = Array(v.prefix(4)) }
                if type == 3, len == 4 { dns.append(v) }
                o += 4 + len
            }
        }
        return Established(virtualIP: vip, dnsServers: dns,
                           ikeSuite: "AES-256-GCM / PRF-HMAC-SHA-384 / ECP-384 + ML-KEM-1024",
                           espSuite: "AES-256-GCM", authentication: "ML-DSA-87 certificates, both directions")
    }

    // MARK: - Key rotation

    /// Replaces the data keys while connected (RFC 7296 section 1.3.3 with an RFC 9370 key exchange).
    /// A fresh ML-KEM-1024 exchange feeds the new keys, so they do not depend on any earlier secret
    /// except the IKE SA that authenticates the exchange.
    public func rekeyChild() throws {
        guard isOpen, let old = esp else { throw IKEError.transport("tunnel is not established") }
        let kem = try MLKEM1024.PrivateKey()
        let nonce = randomBytes(32)
        var newIn = randomBytes(4); newIn[0] |= 0x80
        var rekey = Data([3, 4]); rekey.u16(16393); rekey.append(old.inSPI)   // N(REKEY_SA) naming the SA being replaced
        var ke = Data(); ke.u16(Wire.groupMLKEM1024); ke.u16(0); ke.append(kem.publicKey.rawRepresentation)
        var ts = Data([1, 0, 0, 0, 7, 0]); ts.u16(16); ts.u16(0); ts.u16(0xffff); ts.u32(0); ts.u32(0xffff_ffff)
        let inner = Payload.encode([
            Payload(type: Wire.pNotify, body: rekey),
            Payload(type: Wire.pSA, body: Proposal.encode(protocolID: 3, spi: newIn, Self.espRekeyTransforms)),
            Payload(type: Wire.pNonce, body: nonce),
            Payload(type: Wire.pKE, body: ke),
            Payload(type: Wire.pTSi, body: ts),
            Payload(type: Wire.pTSr, body: ts),
        ])
        let r = try encryptedExchange(exchange: Wire.createChild, first: Wire.pNotify, inner: inner)
        let p = try Payload.decode(first: r.first, r.inner)
        try failOnErrorNotify(p)
        guard let sa = p.first(where: { $0.type == Wire.pSA }), let n = p.first(where: { $0.type == Wire.pNonce }),
              let rke = p.first(where: { $0.type == Wire.pKE }) else { throw IKEError.malformed("CREATE_CHILD_SA response") }
        let chosen = try Proposal.decode(sa.body)
        guard chosen.protocolID == 3, chosen.transforms == Set(Self.espRekeyTransforms), chosen.spi.count == 4 else {
            throw IKEError.policy("gateway selected a different ESP proposal for the re-key")
        }
        guard try rke.body.rU16(0) == Wire.groupMLKEM1024, rke.body.count == 4 + 1568 else {
            throw IKEError.policy("gateway did not answer the re-key with ML-KEM-1024")
        }
        let ss = try kem.decapsulate(Data(rke.body.dropFirst(4))).withUnsafeBytes { Data($0) }
        let fresh = ESPTunnel(outSPI: chosen.spi, inSPI: newIn, keymat: PRF.plus(key: keys.d, seed: ss + nonce + n.body, length: 72))
        lock.lock(); retiringESP = old; esp = fresh; lock.unlock()
        childRekeys += 1
        // Retire the old SA pair.
        var del = Data([3, 4]); del.u16(1); del.append(old.inSPI)
        _ = try encryptedExchange(exchange: Wire.informational, first: Wire.pDelete, inner: Payload.encode([Payload(type: Wire.pDelete, body: del)]))
        lock.lock(); retiringESP = nil; lock.unlock()
    }

    private func openESP(_ datagram: Data) throws -> Data? {
        lock.lock(); let current = esp, retiring = retiringESP; lock.unlock()
        if let current, let p = try current.open(datagram) { return p }
        if let retiring, let p = try retiring.open(datagram) { return p }
        return nil
    }

    /// Answers a request the gateway started (liveness checks and deletes). Anything that would add or
    /// change an SA is declined: this client drives all key rotation itself.
    private func answer(request msg: Data) throws {
        let r = try unprotect(msg, key: keys.er)
        guard r.total == 1 else { return }
        let exchange = try msg.rU8(18), id = try msg.rU32(20)
        var reply: [Payload] = []
        if exchange == Wire.informational {
            for p in try Payload.decode(first: r.first, r.plain) where p.type == Wire.pDelete {
                if try p.body.rU8(0) == 1 { isOpen = false; lock.lock(); esp = nil; lock.unlock() }
            }
        } else {
            reply = [Payload.notify(35)]   // NO_ADDITIONAL_SAS
        }
        let inner = Payload.encode(reply)
        for d in try protect(exchange: exchange, flags: Wire.flagInitiator | Wire.flagResponse, messageID: id,
                             first: reply.first?.type ?? 0, inner: inner, key: keys.ei) {
            try transport.send(d)
        }
    }

    // MARK: - Data and teardown

    public func sendPacket(_ ipPacket: Data) throws {
        lock.lock()
        guard let esp else { lock.unlock(); throw IKEError.transport("tunnel is not established") }
        let sealed: Data
        do { sealed = try esp.seal(ipPacket) } catch { lock.unlock(); throw error }
        lock.unlock()
        try transport.send(sealed)
    }

    /// One-byte NAT keepalive (RFC 3948) so idle connections keep their NAT mapping.
    public func sendKeepalive() throws {
        try transport.send(Data([0xff]))
    }

    /// Returns the next decrypted IP packet from the gateway, or nil on timeout.
    public func receivePacket(timeout: TimeInterval) throws -> Data? {
        if !inbound.isEmpty { return inbound.removeFirst() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let d = try transport.receive(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { return nil }
            if d.count >= 32, d.prefix(4) == Self.marker {
                let msg = Data(d.dropFirst(4))
                if try msg.slice(0, 8) == spiI, try msg.rU8(19) & Wire.flagResponse == 0 { try answer(request: msg) }
                continue
            }
            if let packet = try openESP(d) { return packet }
        }
        return nil
    }

    /// Tells the gateway to delete the IKE SA (and with it the Child SA).
    public func close() throws {
        let inner = Payload.encode([Payload(type: Wire.pDelete, body: Data([1, 0, 0, 0]))])
        _ = try encryptedExchange(exchange: Wire.informational, first: Wire.pDelete, inner: inner)
        lock.lock(); esp = nil; lock.unlock()
        isOpen = false
    }

    /// The SPI the gateway is currently sending to, for display and tests.
    public var inboundSPI: String { esp?.inSPI.hex ?? "none" }
}
