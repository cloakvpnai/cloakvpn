import XCTest
@testable import LatticeTLS

final class WireTests: XCTestCase {
    func testControlPacketRoundTrip() throws {
        let p = ControlPacket(opcode: .control, keyID: 3, sessionID: Data(repeating: 7, count: 8), packetID: 42, payload: Data([1, 2, 3]))
        let q = try ControlPacket.parse(p.encoded())
        XCTAssertEqual(q.opcode, .control); XCTAssertEqual(q.keyID, 3)
        XCTAssertEqual(q.packetID, 42); XCTAssertEqual(q.payload, Data([1, 2, 3]))

        let ack = ControlPacket(opcode: .ack, keyID: 0, sessionID: Data(repeating: 1, count: 8), acks: [5, 6], remoteSessionID: Data(repeating: 2, count: 8))
        let back = try ControlPacket.parse(ack.encoded())
        XCTAssertEqual(back.acks, [5, 6]); XCTAssertEqual(back.remoteSessionID, Data(repeating: 2, count: 8)); XCTAssertNil(back.packetID)
    }

    func testTruncatedAndHostilePacketsAreRejected() {
        let good = ControlPacket(opcode: .control, keyID: 0, sessionID: Data(repeating: 7, count: 8), acks: [1], remoteSessionID: Data(repeating: 9, count: 8), packetID: 1, payload: Data([9])).encoded()
        for cut in 0..<(good.count - 1) { XCTAssertThrowsError(try ControlPacket.parse(good.prefix(cut))) }
        var manyAcks = Data([Opcode.control.rawValue << 3]); manyAcks.append(Data(repeating: 0, count: 8)); manyAcks.append(255)
        XCTAssertThrowsError(try ControlPacket.parse(manyAcks))
        XCTAssertThrowsError(try ControlPacket.parse(Data([31 << 3, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
        for _ in 0..<2000 {
            let junk = Data((0..<Int.random(in: 0...80)).map { _ in UInt8.random(in: 0...255) })
            _ = try? ControlPacket.parse(junk)
        }
    }

    func testDataChannelRoundTripAndTamper() throws {
        let material = Data((0..<256).map { UInt8($0) })
        let a = try DataKeys(exported: material)
        // the other end uses the mirror image
        let swapped = Data(material[128...]) + Data(material[..<128])
        let b = try DataKeys(exported: swapped)
        let packet = try DataChannel.seal(Data("hello".utf8), keys: a, keyID: 2, peerID: 77, packetID: 9)
        let opened = DataChannel.open(packet, keys: b)
        XCTAssertEqual(opened?.packetID, 9); XCTAssertEqual(opened?.plaintext, Data("hello".utf8))
        for i in 0..<packet.count {
            var bad = packet; bad[i] ^= 1
            XCTAssertNil(DataChannel.open(bad, keys: b), "byte \(i) not protected")
        }
        XCTAssertNil(DataChannel.open(packet.prefix(20), keys: b))
        XCTAssertNil(DataChannel.open(packet, keys: a))
    }

    func testReplayWindow() {
        var w = ReplayWindow()
        XCTAssertFalse(w.accept(0))
        XCTAssertTrue(w.accept(1)); XCTAssertFalse(w.accept(1))
        XCTAssertTrue(w.accept(5)); XCTAssertTrue(w.accept(3)); XCTAssertFalse(w.accept(3))
        XCTAssertTrue(w.accept(200)); XCTAssertFalse(w.accept(100)); XCTAssertTrue(w.accept(150)); XCTAssertFalse(w.accept(150))
    }
}
