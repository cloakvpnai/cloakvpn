import CryptoKit
import XCTest
@testable import LatticeIKE

/// The tunnel extension parses bytes from the network. A crash there takes the VPN down, so
/// every parser must reject bad input by throwing, never by trapping.
final class RobustnessTests: XCTestCase {
    private func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }

    func testParsersNeverTrapOnRandomInput() {
        for _ in 0..<20_000 {
            let d = random(Int.random(in: 0...200))
            _ = try? Payload.decode(first: UInt8.random(in: 0...60), d)
            _ = try? Proposal.decode(d)
            _ = try? MLDSACertificate(der: d)
            _ = try? mldsa87Seed(fromPKCS8: d)
            var o = 0
            _ = try? DER.read(d, &o)
        }
    }

    func testParsersNeverTrapOnMutatedValidInput() throws {
        // A well-formed payload chain and proposal, then flipped bytes and truncations.
        let proposal = Proposal.encode(protocolID: 1, spi: Data(), IKESession.ikeTransforms)
        let chain = Payload.encode([Payload(type: Wire.pSA, body: proposal), Payload(type: Wire.pNonce, body: random(32)), Payload.notify(Wire.nIntermediate)])
        XCTAssertEqual(try Proposal.decode(proposal).transforms, Set(IKESession.ikeTransforms))
        XCTAssertEqual(try Payload.decode(first: Wire.pSA, chain).count, 3)
        for _ in 0..<20_000 {
            var c = chain, p = proposal
            c[Int.random(in: 0..<c.count)] = UInt8.random(in: 0...255)
            p[Int.random(in: 0..<p.count)] = UInt8.random(in: 0...255)
            _ = try? Payload.decode(first: Wire.pSA, c.prefix(Int.random(in: 0...c.count)))
            _ = try? Proposal.decode(p.prefix(Int.random(in: 0...p.count)))
        }
    }

    func testESPRejectsForgedAndReplayedPackets() throws {
        let keymat = random(72)
        // Two ends of one SA pair: a's outbound keys are b's inbound keys.
        let a = ESPTunnel(outSPI: Data([1, 2, 3, 4]), inSPI: Data([5, 6, 7, 8]), keymat: keymat)
        let b = ESPTunnel(outSPI: Data([5, 6, 7, 8]), inSPI: Data([1, 2, 3, 4]), keymat: Data(keymat.suffix(36) + keymat.prefix(36)))
        let packet = random(84)
        let sealed = try a.seal(packet)
        XCTAssertEqual(try b.open(sealed), packet)
        XCTAssertNil(try b.open(sealed), "a replayed packet must be dropped")
        var forged = try a.seal(packet)
        forged[forged.count - 1] ^= 0x01
        XCTAssertThrowsError(try b.open(forged), "a modified packet must fail authentication")
        for _ in 0..<5_000 { _ = try? b.open(random(Int.random(in: 0...120))) }
    }

    func testKeyDerivationMatchesRFC7296Shape() {
        // prf+ output is a prefix-stable stream: asking for more bytes never changes earlier ones.
        let k = random(48), s = random(80)
        let short = PRF.plus(key: k, seed: s, length: 50), long = PRF.plus(key: k, seed: s, length: 216)
        XCTAssertEqual(short, long.prefix(50))
        XCTAssertEqual(long.count, 216)
    }
}
