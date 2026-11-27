using System;

namespace Lattice.Tunnel;

/// <summary>
/// How tunnel packets are carried over TCP: each packet is preceded by its length
/// as two bytes, high byte first. TCP is a stream with no packet boundaries of its
/// own, so this is how the two ends find them again.
/// </summary>
public static class TcpFraming
{
    public const int MaxPacket = 65535;

    /// <summary>The packet with its two length bytes in front, ready to send in one call.</summary>
    public static byte[] Frame(ReadOnlySpan<byte> packet)
    {
        if (packet.Length is 0 or > MaxPacket) throw new ArgumentException("a packet must be 1 to 65535 bytes", nameof(packet));
        var framed = new byte[packet.Length + 2];
        framed[0] = (byte)(packet.Length >> 8);
        framed[1] = (byte)packet.Length;
        packet.CopyTo(framed.AsSpan(2));
        return framed;
    }

    /// <summary>
    /// Collects bytes as they arrive, in pieces of any size, and hands back whole packets.
    /// </summary>
    public sealed class Reader
    {
        private byte[] _held = new byte[4096];
        private int _count;

        /// <summary>Adds received bytes and calls <paramref name="packet"/> once for each packet now complete.</summary>
        /// <returns>False when the stream cannot be a Lattice tunnel (a packet of length zero).</returns>
        public bool Add(ReadOnlySpan<byte> received, Action<byte[]> packet)
        {
            if (_count + received.Length > _held.Length) Array.Resize(ref _held, Math.Max(_held.Length * 2, _count + received.Length));
            received.CopyTo(_held.AsSpan(_count));
            _count += received.Length;

            int at = 0;
            while (_count - at >= 2)
            {
                int length = (_held[at] << 8) | _held[at + 1];
                if (length == 0) return false;
                if (_count - at - 2 < length) break;
                packet(_held.AsSpan(at + 2, length).ToArray());
                at += 2 + length;
            }
            if (at > 0)
            {
                Buffer.BlockCopy(_held, at, _held, 0, _count - at);
                _count -= at;
            }
            return true;
        }
    }
}
