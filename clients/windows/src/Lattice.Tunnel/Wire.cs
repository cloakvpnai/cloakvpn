using System;
using System.Collections.Generic;

namespace Lattice.Tunnel;

// The tunnel framing is the OpenVPN wire protocol (control channel carrying
// TLS, AEAD data channel), so the gateway can be a stock OpenVPN 2.6 server.
// Port of clients/apple-tls/Sources/LatticeTLS/Wire.swift. Keep the two in step.

public enum Opcode : byte
{
    SoftReset = 3,        // P_CONTROL_SOFT_RESET_V1
    Control = 4,          // P_CONTROL_V1
    Ack = 5,              // P_ACK_V1
    DataV1 = 6,           // P_DATA_V1
    HardResetClient = 7,  // P_CONTROL_HARD_RESET_CLIENT_V2
    HardResetServer = 8,  // P_CONTROL_HARD_RESET_SERVER_V2
    DataV2 = 9,           // P_DATA_V2
}

public sealed class LatticeTunnelException : Exception
{
    public LatticeTunnelException(string message) : base(message) { }
}

/// <summary>Growable big-endian byte writer.</summary>
public struct ByteWriter
{
    private byte[] _buffer;
    private int _length;

    public ByteWriter(int capacity = 256)
    {
        _buffer = new byte[Math.Max(capacity, 16)];
        _length = 0;
    }

    public int Length => _length;

    private void Need(int extra)
    {
        if (_buffer is null) { _buffer = new byte[Math.Max(extra, 16)]; _length = 0; }
        if (_length + extra <= _buffer.Length) return;
        int size = _buffer.Length;
        while (size < _length + extra) size *= 2;
        Array.Resize(ref _buffer, size);
    }

    public void Byte(byte v) { Need(1); _buffer[_length++] = v; }

    public void UInt16BE(ushort v)
    {
        Need(2);
        _buffer[_length++] = (byte)(v >> 8);
        _buffer[_length++] = (byte)(v & 0xff);
    }

    public void UInt32BE(uint v)
    {
        Need(4);
        _buffer[_length++] = (byte)(v >> 24);
        _buffer[_length++] = (byte)((v >> 16) & 0xff);
        _buffer[_length++] = (byte)((v >> 8) & 0xff);
        _buffer[_length++] = (byte)(v & 0xff);
    }

    public void Bytes(ReadOnlySpan<byte> v)
    {
        if (v.Length == 0) return;
        Need(v.Length);
        v.CopyTo(_buffer.AsSpan(_length));
        _length += v.Length;
    }

    public byte[] ToArray()
    {
        var out_ = new byte[_length];
        if (_length > 0) Array.Copy(_buffer, out_, _length);
        return out_;
    }
}

/// <summary>Bounds-checked reader. Every parse of gateway input goes through this.</summary>
public struct Reader
{
    private readonly byte[] _bytes;
    private int _offset;

    public Reader(byte[] data) { _bytes = data ?? Array.Empty<byte>(); _offset = 0; }

    public int Offset => _offset;
    public int Remaining => _bytes.Length - _offset;

    public byte Byte()
    {
        if (Remaining < 1) throw new LatticeTunnelException("truncated packet");
        return _bytes[_offset++];
    }

    public ushort UInt16BE()
    {
        var b = Take(2);
        return (ushort)(b[0] << 8 | b[1]);
    }

    public uint UInt32BE()
    {
        var b = Take(4);
        return (uint)b[0] << 24 | (uint)b[1] << 16 | (uint)b[2] << 8 | b[3];
    }

    public byte[] Take(int count)
    {
        if (count < 0 || Remaining < count) throw new LatticeTunnelException("truncated packet");
        var slice = new byte[count];
        Array.Copy(_bytes, _offset, slice, 0, count);
        _offset += count;
        return slice;
    }

    public byte[] Rest()
    {
        var slice = new byte[Remaining];
        Array.Copy(_bytes, _offset, slice, 0, slice.Length);
        _offset = _bytes.Length;
        return slice;
    }
}

public sealed class ControlPacket
{
    public const int MaxAcks = 8;

    public Opcode Opcode { get; set; }
    public byte KeyID { get; set; }
    public byte[] SessionID { get; set; } = Array.Empty<byte>();
    public List<uint> Acks { get; } = new();
    public byte[]? RemoteSessionID { get; set; }
    public uint? PacketID { get; set; }
    public byte[] Payload { get; set; } = Array.Empty<byte>();

    public byte[] Encoded()
    {
        var w = new ByteWriter(SessionID.Length + Payload.Length + 64);
        w.Byte((byte)((byte)Opcode << 3 | (KeyID & 7)));
        w.Bytes(SessionID);
        w.Byte((byte)Acks.Count);
        foreach (var a in Acks) w.UInt32BE(a);
        if (Acks.Count > 0 && RemoteSessionID is not null) w.Bytes(RemoteSessionID);
        if (PacketID.HasValue) w.UInt32BE(PacketID.Value);
        w.Bytes(Payload);
        return w.ToArray();
    }

    public static ControlPacket Parse(byte[] datagram)
    {
        var r = new Reader(datagram);
        byte first = r.Byte();
        byte raw = (byte)(first >> 3);
        if (!Enum.IsDefined(typeof(Opcode), raw) || raw == (byte)Opcode.DataV1 || raw == (byte)Opcode.DataV2)
            throw new LatticeTunnelException("unknown packet type");

        var op = (Opcode)raw;
        var p = new ControlPacket { Opcode = op, KeyID = (byte)(first & 7), SessionID = r.Take(8) };

        int count = r.Byte();
        if (count > MaxAcks) throw new LatticeTunnelException("too many acknowledgements");
        for (int i = 0; i < count; i++) p.Acks.Add(r.UInt32BE());
        if (count > 0) p.RemoteSessionID = r.Take(8);
        if (op != Opcode.Ack)
        {
            p.PacketID = r.UInt32BE();
            p.Payload = r.Rest();
        }
        return p;
    }
}

/// <summary>Keys for one direction pair, taken from the TLS exporter.</summary>
public sealed class DataKeys
{
    public const string ExporterLabel = "EXPORTER-OpenVPN-datakeys";
    public const int ExporterLength = 256;

    public byte[] SealKey { get; }  // device -> gateway
    public byte[] SealIV { get; }
    public byte[] OpenKey { get; }  // gateway -> device
    public byte[] OpenIV { get; }

    /// <summary>
    /// Layout: two keys, each 64 bytes of cipher key then 64 bytes of HMAC key.
    /// AES-256-GCM uses the first 32 cipher bytes, and the first 8 HMAC bytes
    /// as the fixed part of the nonce. The client sends with the first key.
    /// </summary>
    public DataKeys(byte[] exported)
    {
        if (exported is null || exported.Length != ExporterLength)
            throw new LatticeTunnelException("bad key material");
        SealKey = Slice(exported, 0, 32);
        SealIV = Slice(exported, 64, 8);
        OpenKey = Slice(exported, 128, 32);
        OpenIV = Slice(exported, 192, 8);
    }

    private static byte[] Slice(byte[] src, int start, int length)
    {
        var dst = new byte[length];
        Array.Copy(src, start, dst, 0, length);
        return dst;
    }
}

/// <summary>Sliding window against replayed data packets.</summary>
public struct ReplayWindow
{
    private uint _highest;
    private ulong _seen;

    public bool Accept(uint id)
    {
        if (id == 0) return false;
        if (id > _highest)
        {
            uint shift = id - _highest;
            _seen = shift >= 64 ? 0UL : _seen << (int)shift;
            _seen |= 1UL;
            _highest = id;
            return true;
        }
        uint behind = _highest - id;
        if (behind >= 64) return false;
        ulong bit = 1UL << (int)behind;
        if ((_seen & bit) != 0) return false;
        _seen |= bit;
        return true;
    }
}

public static class DataChannel
{
    /// <summary>OpenVPN's keepalive payload.</summary>
    public static readonly byte[] Ping =
    {
        0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb,
        0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48
    };

    public static bool IsPing(ReadOnlySpan<byte> payload)
    {
        if (payload.Length != Ping.Length) return false;
        return payload.SequenceEqual(Ping);
    }

    public static byte[] Seal(ReadOnlySpan<byte> plaintext, DataKeys keys, byte keyID, uint peerID, uint packetID)
    {
        var h = new ByteWriter(8);
        h.Byte((byte)((byte)Opcode.DataV2 << 3 | (keyID & 7)));
        h.Byte((byte)((peerID >> 16) & 0xff));
        h.Byte((byte)((peerID >> 8) & 0xff));
        h.Byte((byte)(peerID & 0xff));
        h.UInt32BE(packetID);
        byte[] header = h.ToArray();

        var n = new ByteWriter(12);
        n.UInt32BE(packetID);
        n.Bytes(keys.SealIV);
        byte[] nonce = n.ToArray();

        var (ciphertext, tag) = Gcm.Seal(keys.SealKey, nonce, header, plaintext);

        var w = new ByteWriter(header.Length + 16 + ciphertext.Length);
        w.Bytes(header);
        w.Bytes(tag);
        w.Bytes(ciphertext);
        return w.ToArray();
    }

    /// <summary>Returns false if the packet does not authenticate.</summary>
    public static bool Open(byte[] datagram, DataKeys keys, out uint packetID, out byte[] plaintext)
    {
        packetID = 0;
        plaintext = Array.Empty<byte>();
        if (datagram is null || datagram.Length == 0) return false;

        byte first = datagram[0];
        int headerLength = (first >> 3) == (byte)Opcode.DataV2 ? 4 : 1;
        if (datagram.Length < headerLength + 4 + 16) return false;

        packetID = (uint)datagram[headerLength] << 24
                 | (uint)datagram[headerLength + 1] << 16
                 | (uint)datagram[headerLength + 2] << 8
                 | datagram[headerLength + 3];

        var ad = datagram.AsSpan(0, headerLength + 4);
        var tag = datagram.AsSpan(headerLength + 4, 16);
        var ciphertext = datagram.AsSpan(headerLength + 20);

        var n = new ByteWriter(12);
        n.Bytes(datagram.AsSpan(headerLength, 4));
        n.Bytes(keys.OpenIV);
        byte[] nonce = n.ToArray();

        var opened = Gcm.Open(keys.OpenKey, nonce, ad, ciphertext, tag);
        if (opened is null) return false;
        plaintext = opened;
        return true;
    }
}
