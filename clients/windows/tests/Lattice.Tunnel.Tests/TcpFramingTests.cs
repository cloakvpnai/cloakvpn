using System;
using System.Collections.Generic;
using Xunit;

namespace Lattice.Tunnel.Tests;

/// <summary>Packets over TCP: two length bytes in front, and whole packets back out however the bytes arrive.</summary>
public class TcpFramingTests
{
    [Fact]
    public void FrameCarriesTheLengthHighByteFirst()
    {
        byte[] framed = TcpFraming.Frame(new byte[300]);
        Assert.Equal(302, framed.Length);
        Assert.Equal(0x01, framed[0]);
        Assert.Equal(0x2C, framed[1]);
    }

    [Fact]
    public void EmptyAndOversizedPacketsAreRefused()
    {
        Assert.Throws<ArgumentException>(() => TcpFraming.Frame(Array.Empty<byte>()));
        Assert.Throws<ArgumentException>(() => TcpFraming.Frame(new byte[65536]));
    }

    [Theory]
    [InlineData(1)]      // one byte at a time
    [InlineData(3)]      // splits inside the length bytes and inside packets
    [InlineData(700)]
    [InlineData(100000)] // everything in one piece
    public void PacketsComeBackWholeHoweverTheBytesArrive(int piece)
    {
        var sent = new List<byte[]>();
        var stream = new List<byte>();
        var random = new Random(7);
        foreach (int size in new[] { 1, 2, 40, 1400, 1, 65535, 513 })
        {
            var packet = new byte[size];
            random.NextBytes(packet);
            sent.Add(packet);
            stream.AddRange(TcpFraming.Frame(packet));
        }

        var got = new List<byte[]>();
        var reader = new TcpFraming.Reader();
        byte[] all = stream.ToArray();
        for (int at = 0; at < all.Length; at += piece)
            Assert.True(reader.Add(all.AsSpan(at, Math.Min(piece, all.Length - at)), got.Add));

        Assert.Equal(sent.Count, got.Count);
        for (int i = 0; i < sent.Count; i++) Assert.Equal(sent[i], got[i]);
    }

    [Fact]
    public void AZeroLengthMeansThisIsNotATunnel()
    {
        var reader = new TcpFraming.Reader();
        Assert.False(reader.Add(new byte[] { 0, 0, 1, 2 }, _ => { }));
    }
}
