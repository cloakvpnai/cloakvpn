using System;
using System.IO;
using System.Linq;
using System.Text;
using Lattice.Tunnel;
using Xunit;

namespace Lattice.Tunnel.Tests;

/// <summary>A test that needs lattice_tls.dll. Skipped when the native layer has not been built.</summary>
public sealed class NativeFactAttribute : FactAttribute
{
    public NativeFactAttribute()
    {
        string dll = Path.Combine(AppContext.BaseDirectory, "lattice_tls.dll");
        if (!File.Exists(dll)) Skip = "lattice_tls.dll not built (run native\\lattice_tls\\build-native.ps1)";
    }
}

// Mirrors clients/apple-tls/Tests/LatticeTLSTests/WireTests.swift, plus fixed
// byte layouts so the three clients cannot drift apart unnoticed.
public class WireTests
{
    private static byte[] Repeat(byte value, int count) => Enumerable.Repeat(value, count).ToArray();
    private static string Hex(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();

    [Fact]
    public void ControlPacketRoundTrip()
    {
        var p = new ControlPacket { Opcode = Opcode.Control, KeyID = 3, SessionID = Repeat(7, 8), PacketID = 42, Payload = new byte[] { 1, 2, 3 } };
        var q = ControlPacket.Parse(p.Encoded());
        Assert.Equal(Opcode.Control, q.Opcode);
        Assert.Equal(3, q.KeyID);
        Assert.Equal(42u, q.PacketID);
        Assert.Equal(new byte[] { 1, 2, 3 }, q.Payload);

        var ack = new ControlPacket { Opcode = Opcode.Ack, KeyID = 0, SessionID = Repeat(1, 8), RemoteSessionID = Repeat(2, 8) };
        ack.Acks.Add(5); ack.Acks.Add(6);
        var back = ControlPacket.Parse(ack.Encoded());
        Assert.Equal(new uint[] { 5, 6 }, back.Acks);
        Assert.Equal(Repeat(2, 8), back.RemoteSessionID);
        Assert.Null(back.PacketID);
    }

    [Fact]
    public void ControlPacketByteLayoutIsFixed()
    {
        var p = new ControlPacket { Opcode = Opcode.Control, KeyID = 3, SessionID = Repeat(7, 8), PacketID = 42, Payload = new byte[] { 1, 2, 3 } };
        // opcode 4 << 3 | key 3, session, no acks, packet id, payload
        Assert.Equal("23" + "0707070707070707" + "00" + "0000002a" + "010203", Hex(p.Encoded()));

        var ack = new ControlPacket { Opcode = Opcode.Ack, KeyID = 0, SessionID = Repeat(1, 8), RemoteSessionID = Repeat(2, 8) };
        ack.Acks.Add(5); ack.Acks.Add(6);
        // opcode 5 << 3, session, two acks, remote session, no packet id
        Assert.Equal("28" + "0101010101010101" + "02" + "00000005" + "00000006" + "0202020202020202", Hex(ack.Encoded()));

        var reset = new ControlPacket { Opcode = Opcode.HardResetClient, KeyID = 0, SessionID = Repeat(9, 8), PacketID = 0 };
        Assert.Equal("38" + "0909090909090909" + "00" + "00000000", Hex(reset.Encoded()));
    }

    [Fact]
    public void TruncatedAndHostilePacketsAreRejected()
    {
        var full = new ControlPacket { Opcode = Opcode.Control, KeyID = 0, SessionID = Repeat(7, 8), RemoteSessionID = Repeat(9, 8), PacketID = 1, Payload = new byte[] { 9 } };
        full.Acks.Add(1);
        byte[] good = full.Encoded();
        for (int cut = 0; cut < good.Length - 1; cut++)
        {
            byte[] prefix = good.Take(cut).ToArray();
            Assert.Throws<LatticeTunnelException>(() => ControlPacket.Parse(prefix));
        }

        byte[] manyAcks = new byte[] { (byte)((byte)Opcode.Control << 3) }.Concat(Repeat(0, 8)).Concat(new byte[] { 255 }).ToArray();
        Assert.Throws<LatticeTunnelException>(() => ControlPacket.Parse(manyAcks));
        Assert.Throws<LatticeTunnelException>(() => ControlPacket.Parse(new byte[] { 31 << 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 }));

        // data opcodes are never control packets
        Assert.Throws<LatticeTunnelException>(() => ControlPacket.Parse(new byte[] { (byte)((byte)Opcode.DataV2 << 3), 0, 0, 0, 0, 0, 0, 0, 0, 0 }));

        // random input may be rejected but must never throw anything else
        var random = new Random(20261125);
        for (int i = 0; i < 20000; i++)
        {
            var junk = new byte[random.Next(0, 81)];
            random.NextBytes(junk);
            try { ControlPacket.Parse(junk); }
            catch (LatticeTunnelException) { }
        }
    }

    [Fact]
    public void ReplayWindowBehaves()
    {
        var w = new ReplayWindow();
        Assert.False(w.Accept(0));
        Assert.True(w.Accept(1)); Assert.False(w.Accept(1));
        Assert.True(w.Accept(5)); Assert.True(w.Accept(3)); Assert.False(w.Accept(3));
        Assert.True(w.Accept(200)); Assert.False(w.Accept(100)); Assert.True(w.Accept(150)); Assert.False(w.Accept(150));
    }

    [Fact]
    public void ReplayWindowEdges()
    {
        var w = new ReplayWindow();
        Assert.True(w.Accept(100));
        Assert.True(w.Accept(37));    // 63 behind: still inside the window
        Assert.False(w.Accept(36));   // 64 behind: outside
        Assert.False(w.Accept(37));   // repeat
        Assert.True(w.Accept(100 + 64)); // jump of exactly the window size clears it
        Assert.True(w.Accept(101));   // 63 behind the new top, never seen
        Assert.False(w.Accept(100));  // 64 behind
        Assert.True(w.Accept(uint.MaxValue));
        Assert.False(w.Accept(uint.MaxValue));
        Assert.True(w.Accept(uint.MaxValue - 1));
    }

    [Fact]
    public void DataKeysLayout()
    {
        byte[] material = Enumerable.Range(0, 256).Select(i => (byte)i).ToArray();
        var k = new DataKeys(material);
        Assert.Equal(Enumerable.Range(0, 32).Select(i => (byte)i).ToArray(), k.SealKey);
        Assert.Equal(Enumerable.Range(64, 8).Select(i => (byte)i).ToArray(), k.SealIV);
        Assert.Equal(Enumerable.Range(128, 32).Select(i => (byte)i).ToArray(), k.OpenKey);
        Assert.Equal(Enumerable.Range(192, 8).Select(i => (byte)i).ToArray(), k.OpenIV);
        Assert.Throws<LatticeTunnelException>(() => new DataKeys(new byte[255]));
        Assert.Throws<LatticeTunnelException>(() => new DataKeys(new byte[257]));
    }

    [NativeFact]
    public void DataChannelRoundTripAndTamper()
    {
        byte[] material = Enumerable.Range(0, 256).Select(i => (byte)i).ToArray();
        var a = new DataKeys(material);
        // the other end uses the mirror image
        byte[] swapped = material.Skip(128).Concat(material.Take(128)).ToArray();
        var b = new DataKeys(swapped);

        byte[] hello = Encoding.UTF8.GetBytes("hello");
        byte[] packet = DataChannel.Seal(hello, a, keyID: 2, peerID: 77, packetID: 9);

        // P_DATA_V2 << 3 | key 2, peer id 77 in three bytes, packet id 9
        Assert.Equal("4a" + "00004d" + "00000009", Hex(packet.Take(8).ToArray()));
        Assert.Equal(8 + 16 + hello.Length, packet.Length);

        Assert.True(DataChannel.Open(packet, b, out uint id, out byte[] plain));
        Assert.Equal(9u, id);
        Assert.Equal(hello, plain);

        for (int i = 0; i < packet.Length; i++)
        {
            byte[] bad = (byte[])packet.Clone();
            bad[i] ^= 1;
            Assert.False(DataChannel.Open(bad, b, out _, out _), $"byte {i} not protected");
        }
        Assert.False(DataChannel.Open(packet.Take(20).ToArray(), b, out _, out _));
        Assert.False(DataChannel.Open(packet, a, out _, out _));
    }

    [NativeFact]
    public void GcmMatchesNistKnownAnswer()
    {
        // NIST GCM test case 16 (AES-256, 96 bit IV, with AAD), from the
        // McGrew and Viega GCM specification. Proves the data channel cipher
        // is standard AES-256-GCM, independent of this code base.
        byte[] key = Convert.FromHexString("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308");
        byte[] iv = Convert.FromHexString("cafebabefacedbaddecaf888");
        byte[] aad = Convert.FromHexString("feedfacedeadbeeffeedfacedeadbeefabaddad2");
        byte[] pt = Convert.FromHexString(
            "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72" +
            "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
        string expectedCt =
            "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa" +
            "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662";
        string expectedTag = "76fc6ece0f4e1768cddf8853bb2d551b";

        var (ct, tag) = Gcm.Seal(key, iv, aad, pt);
        Assert.Equal(expectedCt, Hex(ct));
        Assert.Equal(expectedTag, Hex(tag));
        Assert.Equal(pt, Gcm.Open(key, iv, aad, ct, tag));
    }

    [NativeFact]
    public void GcmHandlesEmptyInput()
    {
        byte[] key = new byte[32];
        byte[] nonce = new byte[12];
        var (ct, tag) = Gcm.Seal(key, nonce, ReadOnlySpan<byte>.Empty, ReadOnlySpan<byte>.Empty);
        Assert.Empty(ct);
        // NIST GCM test case 13: AES-256, zero key and IV, no data
        Assert.Equal("530f8afbc74536b9a963b4f1c4cb738b", Hex(tag));
        Assert.NotNull(Gcm.Open(key, nonce, ReadOnlySpan<byte>.Empty, ct, tag));
    }

    [NativeFact]
    public void RandomBytesAreNotConstant()
    {
        byte[] a = Rng.Bytes(32), b = Rng.Bytes(32);
        Assert.Equal(32, a.Length);
        Assert.NotEqual(a, b);
        Assert.Empty(Rng.Bytes(0));
    }

    [NativeFact]
    public void TlsSessionRejectsGarbageIdentity()
    {
        using var identity = new TunnelIdentity(new byte[] { 1, 2, 3 }, new byte[] { 4, 5, 6 }, new byte[] { 7, 8, 9 }, "gw.example");
        var e = Assert.Throws<LatticeTunnelException>(() => new TlsSession(identity));
        Assert.StartsWith("CA certificate", e.Message);
    }
}
