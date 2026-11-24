import Foundation
import Darwin

/// Round-trip time to an address, measured with one ICMP echo. Used for the latency
/// figure on the globe panel: the target is the gateway's own address inside the
/// tunnel, so the number is the trip from this device to the exit and back.
enum LatticePing {
    /// The gateway's address inside every CNSA 2.0 tunnel.
    static let gatewayInTunnel = "10.88.0.1"

    static func roundTrip(to host: String, timeout: TimeInterval = 2) async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: blocking(host, timeout))
            }
        }
    }

    private static func blocking(_ host: String, _ timeout: TimeInterval) -> TimeInterval? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        // Echo request: type 8, code 0, checksum, identifier, sequence, then 8 random bytes
        // that the reply must carry back.
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[6] = 0
        packet[7] = 1
        let token = (0..<8).map { _ in UInt8.random(in: 0...255) }
        packet.replaceSubrange(8..<16, with: token)
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count, by: 2) {
            sum += UInt32(packet[i]) << 8 | UInt32(packet[i + 1])
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        let checksum = ~UInt16(truncatingIfNeeded: sum)
        packet[2] = UInt8(checksum >> 8)
        packet[3] = UInt8(checksum & 0xff)

        let started = DispatchTime.now().uptimeNanoseconds
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 512)
        let deadline = started + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { return nil }
            // The reply may arrive with its IP header in front.
            let header = (n >= 20 && buffer[0] >> 4 == 4) ? Int(buffer[0] & 0x0f) * 4 : 0
            guard n >= header + 16, buffer[header] == 0 else { continue }
            if Array(buffer[(header + 8)..<(header + 16)]) == token {
                return TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            }
        }
        return nil
    }
}
