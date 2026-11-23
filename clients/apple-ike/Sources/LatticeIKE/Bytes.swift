import Foundation

extension Data {
    mutating func u8(_ v: UInt8) { append(v) }
    mutating func u16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func u32(_ v: UInt32) { for s in [24, 16, 8, 0] { append(UInt8((v >> UInt32(s)) & 0xff)) } }
    mutating func u64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { append(UInt8((v >> UInt64(s)) & 0xff)) } }

    /// Bounds-checked big-endian reads. Offsets are relative to the start of the data.
    func rU8(_ o: Int) throws -> UInt8 {
        guard o >= 0, o < count else { throw IKEError.malformed("read past end") }
        return self[startIndex + o]
    }
    func rU16(_ o: Int) throws -> UInt16 { (UInt16(try rU8(o)) << 8) | UInt16(try rU8(o + 1)) }
    func rU32(_ o: Int) throws -> UInt32 { (UInt32(try rU16(o)) << 16) | UInt32(try rU16(o + 2)) }
    func slice(_ o: Int, _ n: Int) throws -> Data {
        guard o >= 0, n >= 0, o + n <= count else { throw IKEError.malformed("slice past end") }
        return Data(self[(startIndex + o)..<(startIndex + o + n)])
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

public enum IKEError: Error, CustomStringConvertible {
    case malformed(String)
    case timeout(String)
    case notify(UInt16, String)
    case policy(String)
    case authentication(String)
    case transport(String)

    public var description: String {
        switch self {
        case .malformed(let s): return "malformed message: \(s)"
        case .timeout(let s): return "timed out: \(s)"
        case .notify(let t, let s): return "gateway refused (\(t)): \(s)"
        case .policy(let s): return "outside the CNSA 2.0 profile: \(s)"
        case .authentication(let s): return "authentication failed: \(s)"
        case .transport(let s): return "network error: \(s)"
        }
    }
}
