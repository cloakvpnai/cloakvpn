using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace Lattice.Tunnel;

// Port of clients/apple-tls/Sources/LatticeTLS/Session.swift. Keep the two in step.

/// <summary>What the gateway assigned to this device.</summary>
public sealed class TunnelSettings
{
    public string Address { get; set; } = "";
    public string Netmask { get; set; } = "";
    /// <summary>IPv6 address inside the tunnel, when the gateway carries IPv6. Empty when it does not.</summary>
    public string Address6 { get; set; } = "";
    public int Prefix6 { get; set; } = 64;
    public string Gateway { get; set; } = "";
    public List<string> Dns { get; } = new();
    public List<string> Routes { get; } = new();
    public bool RedirectGateway { get; set; }
    public int Mtu { get; set; } = 1500;
    public double PingInterval { get; set; } = 10;
    public double PingRestart { get; set; } = 60;
    internal uint PeerID { get; set; }
}

public enum TunnelStateKind { Idle, Connecting, Connected, Failed, Closed }

public readonly record struct TunnelState(TunnelStateKind Kind, string Reason = "")
{
    public static readonly TunnelState Idle = new(TunnelStateKind.Idle);
    public static readonly TunnelState Connecting = new(TunnelStateKind.Connecting);
    public static readonly TunnelState Connected = new(TunnelStateKind.Connected);
    public static readonly TunnelState Closed = new(TunnelStateKind.Closed);
    public static TunnelState Failed(string reason) => new(TunnelStateKind.Failed, reason);
    public override string ToString() => Kind == TunnelStateKind.Failed ? $"failed: {Reason}" : Kind.ToString().ToLowerInvariant();
}

/// <summary>One negotiation: its own reliable control channel, TLS handshake and data keys.</summary>
internal sealed class KeyState : IDisposable
{
    internal readonly record struct Inflight(Opcode Opcode, byte[] Payload, double SentAt, double Wait);

    public byte KeyID { get; }
    public Opcode ResetOpcode { get; }
    public TlsSession Tls { get; }
    public double StartedAt { get; }

    // reliable control channel
    public uint NextSendID;
    public readonly Queue<(Opcode Opcode, byte[] Payload)> Queue = new();
    public readonly Dictionary<uint, Inflight> InflightPackets = new();
    public uint NextReceiveID;
    public readonly Dictionary<uint, (Opcode Opcode, byte[] Payload)> ReceiveBuffer = new();

    // progress
    public bool PeerResetSeen;
    public bool TlsDone;
    public bool KeyExchangeReceived;
    public DataKeys? Keys;
    public double EstablishedAt;

    // data channel counters
    public uint SendPacketID;
    public ReplayWindow Replay;

    public KeyState(byte keyID, Opcode resetOpcode, TunnelIdentity identity, double now)
    {
        KeyID = keyID;
        ResetOpcode = resetOpcode;
        Tls = new TlsSession(identity);
        StartedAt = now;
        Queue.Enqueue((resetOpcode, Array.Empty<byte>()));
    }

    public void Dispose() => Tls.Dispose();
}

/// <summary>
/// The CNSA 2.0 tunnel client. A plain state machine: the owner feeds it
/// datagrams and clock ticks and sends what it hands back. Not thread safe;
/// call everything from one thread. Times are seconds on a monotonic clock.
/// </summary>
public sealed class TunnelSession : IDisposable
{
    public TunnelState State { get; private set; } = TunnelState.Idle;
    public TunnelSettings Settings { get; private set; } = new();
    /// <summary>"TLSv1.3 TLS_AES_256_GCM_SHA384 MLKEM1024 mldsa87" for the keys now in use.</summary>
    public string Suite { get; private set; } = "";
    public int RekeyCount { get; private set; }
    public double LastKeyTime { get; private set; }

    /// <summary>Datagram to send to the gateway.</summary>
    public Action<byte[]> Send { get; set; } = _ => { };
    /// <summary>IP packet received through the tunnel.</summary>
    public Action<byte[]> OnPacket { get; set; } = _ => { };
    public Action<TunnelState> OnStateChange { get; set; } = _ => { };
    public Action<string> Log { get; set; } = _ => { };

    private readonly TunnelIdentity _identity;
    private readonly double _rekeyInterval;
    private readonly byte[] _sessionID = Rng.Bytes(8);
    private byte[]? _remoteSessionID;

    private KeyState? _pending;
    private KeyState? _current;
    private KeyState? _previous;

    private bool _pushReplySeen;
    // Far in the past, so the first request for settings goes out at once. This
    // clock starts near zero; a plain 0 here would hold that request back 2 seconds.
    private double _lastPushRequest = double.NegativeInfinity;
    private double _lastSent;
    private double _lastReceived;
    private bool _exitNotify;

    private const int SendWindow = 4;
    private const int ControlChunk = 1100;
    private const double HandshakeTimeout = 30;
    private const uint ReceiveAhead = 32;

    /// <param name="rekeyInterval">Seconds between full new handshakes started by this device;
    /// 0 leaves the timing to the gateway.</param>
    public TunnelSession(TunnelIdentity identity, double rekeyInterval = 300)
    {
        _identity = identity;
        _rekeyInterval = rekeyInterval;
    }

    // ---- lifecycle ----

    public void Start(double now)
    {
        if (State.Kind != TunnelStateKind.Idle) return;
        try
        {
            _pending = new KeyState(0, Opcode.HardResetClient, _identity, now);
            _lastReceived = now;
            SetState(TunnelState.Connecting);
            Flush(_pending, now);
        }
        catch (Exception e)
        {
            Fail(e.Message);
        }
    }

    /// <summary>Tell the gateway we are leaving, then stop.</summary>
    public void Close(double now)
    {
        if (State.Kind == TunnelStateKind.Connected && _exitNotify && _current is { } ks)
        {
            try
            {
                ks.Tls.Write(NulTerminated("EXIT"));
                EnqueueTlsOutput(ks);
                Flush(ks, now);
            }
            catch (Exception) { /* leaving anyway */ }
        }
        DropAll();
        if (State.Kind == TunnelStateKind.Failed) return;
        SetState(TunnelState.Closed);
    }

    public void Dispose() => DropAll();

    private void Fail(string reason)
    {
        DropAll();
        SetState(TunnelState.Failed(reason));
    }

    private void DropAll()
    {
        _pending?.Dispose(); _current?.Dispose(); _previous?.Dispose();
        _pending = null; _current = null; _previous = null;
    }

    private void SetState(TunnelState next)
    {
        if (next == State) return;
        State = next;
        OnStateChange(next);
    }

    private bool IsLive => State.Kind is TunnelStateKind.Connecting or TunnelStateKind.Connected;

    // ---- input ----

    public void Receive(byte[] datagram, double now)
    {
        if (!IsLive || datagram is null || datagram.Length == 0) return;
        byte first = datagram[0];
        byte opcode = (byte)(first >> 3);
        if (opcode == (byte)Opcode.DataV2 || opcode == (byte)Opcode.DataV1)
        {
            ReceiveData(datagram, (byte)(first & 7), now);
            return;
        }
        try
        {
            ReceiveControl(ControlPacket.Parse(datagram), now);
        }
        catch (Exception e)
        {
            // a malformed or unexpected control packet is dropped, never trusted
            Log($"dropped control packet: {e.Message}");
        }
    }

    private void ReceiveData(byte[] datagram, byte keyID, double now)
    {
        KeyState? ks = _current is { } c && c.KeyID == keyID ? c
                     : _previous is { } p && p.KeyID == keyID ? p
                     : null;
        if (ks?.Keys is not { } keys) return;
        if (!DataChannel.Open(datagram, keys, out uint packetID, out byte[] plaintext)) return;
        if (!ks.Replay.Accept(packetID)) return;
        _lastReceived = now;
        if (DataChannel.IsPing(plaintext)) return;
        OnPacket(plaintext);
    }

    private KeyState? FindKeyState(byte keyID)
    {
        if (_pending is { } a && a.KeyID == keyID) return a;
        if (_current is { } b && b.KeyID == keyID) return b;
        if (_previous is { } c && c.KeyID == keyID) return c;
        return null;
    }

    private void ReceiveControl(ControlPacket packet, double now)
    {
        if (_remoteSessionID is { } known)
        {
            if (!packet.SessionID.AsSpan().SequenceEqual(known)) throw new LatticeTunnelException("wrong session");
        }
        else
        {
            if (packet.Opcode != Opcode.HardResetServer) throw new LatticeTunnelException("unexpected first packet");
            _remoteSessionID = packet.SessionID;
        }
        if (packet.Acks.Count > 0)
        {
            if (packet.RemoteSessionID is null || !packet.RemoteSessionID.AsSpan().SequenceEqual(_sessionID))
                throw new LatticeTunnelException("acknowledgement for another session");
        }
        _lastReceived = now;

        KeyState? ks = FindKeyState(packet.KeyID);
        if (ks is null)
        {
            // the gateway is asking for new keys
            if (packet.Opcode != Opcode.SoftReset || State.Kind != TunnelStateKind.Connected || _pending is not null
                || packet.KeyID == 0 || packet.PacketID != 0)
                throw new LatticeTunnelException("no such negotiation");
            ks = new KeyState(packet.KeyID, Opcode.SoftReset, _identity, now);
            _pending = ks;
            Log($"gateway requested new keys (key {packet.KeyID})");
        }

        foreach (uint id in packet.Acks) ks.InflightPackets.Remove(id);

        if (packet.PacketID is { } pid)
        {
            Acknowledge(pid, ks.KeyID);
            if (pid >= ks.NextReceiveID && pid - ks.NextReceiveID < ReceiveAhead)
                ks.ReceiveBuffer[pid] = (packet.Opcode, packet.Payload);
            while (ks.ReceiveBuffer.Remove(ks.NextReceiveID, out var item))
            {
                ks.NextReceiveID += 1;
                Deliver(item.Opcode, item.Payload, ks);
            }
        }
        try
        {
            Advance(ks, now);
        }
        catch (Exception e)
        {
            NegotiationFailed(ks, e.Message);
            return;
        }
        if (!IsLive) return;
        Flush(ks, now);
    }

    private void Acknowledge(uint id, byte keyID)
    {
        if (_remoteSessionID is not { } remote) return;
        var ack = new ControlPacket { Opcode = Opcode.Ack, KeyID = keyID, SessionID = _sessionID, RemoteSessionID = remote };
        ack.Acks.Add(id);
        Send(ack.Encoded());
    }

    private static void Deliver(Opcode opcode, byte[] payload, KeyState ks)
    {
        switch (opcode)
        {
            case Opcode.HardResetServer:
            case Opcode.SoftReset:
                ks.PeerResetSeen = true;
                break;
            case Opcode.Control:
                if (!ks.PeerResetSeen) throw new LatticeTunnelException("data before reset");
                ks.Tls.Feed(payload);
                break;
            default:
                throw new LatticeTunnelException("unexpected control packet");
        }
    }

    // ---- negotiation ----

    private void Advance(KeyState ks, double now)
    {
        if (!ks.PeerResetSeen) return;
        if (!ks.TlsDone)
        {
            bool done = ks.Tls.Handshake();
            EnqueueTlsOutput(ks);
            if (!done) return;
            ks.TlsDone = true;
            Log($"handshake complete: {ks.Tls.Summary}");
            ks.Tls.Write(KeyExchangeMessage());
            EnqueueTlsOutput(ks);
        }
        foreach (byte[] record in ks.Tls.ReadRecords())
        {
            if (!ks.KeyExchangeReceived)
            {
                ParseKeyExchange(record);
                ks.KeyExchangeReceived = true;
            }
            else
            {
                HandleControlMessage(record);
                // The gateway may have ended the session (RESTART, HALT, EXIT). The Swift
                // client keeps going here and can re-activate a failed session; this port stops.
                if (!IsLive) return;
            }
        }
        EnqueueTlsOutput(ks);
        if (!ks.KeyExchangeReceived || ks.Keys is not null) return;
        if (ks.KeyID == 0 && !_pushReplySeen)
        {
            if (now - _lastPushRequest >= 2)
            {
                _lastPushRequest = now;
                ks.Tls.Write(NulTerminated("PUSH_REQUEST"));
                EnqueueTlsOutput(ks);
            }
            return;
        }
        Activate(ks, now);
    }

    private void Activate(KeyState ks, double now)
    {
        ks.Keys = new DataKeys(ks.Tls.Export(DataKeys.ExporterLabel, DataKeys.ExporterLength));
        ks.EstablishedAt = now;
        bool first = _current is null;
        _previous?.Dispose();
        _previous = _current;
        _current = ks;
        if (ReferenceEquals(_pending, ks)) _pending = null;
        Suite = ks.Tls.Summary;
        LastKeyTime = now;
        if (first)
        {
            SetState(TunnelState.Connected);
        }
        else
        {
            RekeyCount += 1;
            Log($"new keys in use (key {ks.KeyID}, rekey {RekeyCount})");
        }
    }

    private void NegotiationFailed(KeyState ks, string reason)
    {
        if (_current is null)
        {
            Fail(reason);
        }
        else
        {
            // keep the current keys; the gateway enforces their lifetime
            Log($"rekey failed: {reason}");
            if (ReferenceEquals(_pending, ks))
            {
                _pending = null;
                ks.Dispose();
            }
        }
    }

    private static byte[] NulTerminated(string s)
    {
        var bytes = new byte[Encoding.UTF8.GetByteCount(s) + 1];
        Encoding.UTF8.GetBytes(s, 0, s.Length, bytes, 0);
        return bytes;
    }

    private static void AppendString(ref ByteWriter w, string s)
    {
        byte[] bytes = NulTerminated(s);
        w.UInt16BE((ushort)bytes.Length);
        w.Bytes(bytes);
    }

    /// <summary>
    /// The client half of OpenVPN's key method 2 message. With exported keys
    /// the random fields are not used for key derivation but are still sent.
    /// </summary>
    private static byte[] KeyExchangeMessage()
    {
        var m = new ByteWriter(512);
        m.Bytes(stackalloc byte[] { 0, 0, 0, 0, 2 });
        m.Bytes(Rng.Bytes(48 + 32 + 32));
        AppendString(ref m, "V4,dev-type tun,link-mtu 1549,tun-mtu 1500,proto UDPv4,cipher AES-256-GCM,auth [null-digest],keysize 256,key-method 2,tls-client");
        m.UInt16BE(0); // no username
        m.UInt16BE(0); // no password
        // IV_PROTO: data v2 (2) + exported keys (8) + exit notification (128)
        AppendString(ref m, "IV_VER=2.6.14\nIV_PLAT=lattice\nIV_PROTO=138\nIV_NCP=2\nIV_CIPHERS=AES-256-GCM\n");
        return m.ToArray();
    }

    private static void ParseKeyExchange(byte[] record)
    {
        var r = new Reader(record);
        if (r.UInt32BE() != 0 || r.Byte() != 2) throw new LatticeTunnelException("unexpected key exchange message");
        _ = r.Take(64);
        int length = r.UInt16BE();
        _ = r.Take(length);
    }

    private void HandleControlMessage(byte[] record)
    {
        int end = Array.IndexOf(record, (byte)0);
        if (end < 0) end = record.Length;
        string text;
        try { text = new UTF8Encoding(false, true).GetString(record, 0, end); }
        catch (ArgumentException) { return; }

        if (text.StartsWith("PUSH_REPLY", StringComparison.Ordinal))
        {
            if (_pushReplySeen) return;
            ApplyPushReply(text);
            _pushReplySeen = true;
        }
        else if (text.StartsWith("AUTH_FAILED", StringComparison.Ordinal))
        {
            throw new LatticeTunnelException("gateway refused this device");
        }
        else if (text.StartsWith("RESTART", StringComparison.Ordinal)
              || text.StartsWith("HALT", StringComparison.Ordinal)
              || text.StartsWith("EXIT", StringComparison.Ordinal))
        {
            Fail("gateway ended the session");
        }
    }

    private static double Seconds(string s, double fallback) =>
        double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double v) ? v : fallback;

    private static int Integer(string s, int fallback) =>
        int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out int v) ? v : fallback;

    private void ApplyPushReply(string text)
    {
        var s = new TunnelSettings();
        bool exportedKeys = false;
        bool exitNotify = false;
        foreach (string option in text.Split(',', StringSplitOptions.RemoveEmptyEntries).Skip(1))
        {
            string[] parts = option.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 0) continue;
            switch (parts[0])
            {
                case "ifconfig" when parts.Length >= 3:
                    s.Address = parts[1]; s.Netmask = parts[2];
                    break;
                case "ifconfig-ipv6" when parts.Length >= 2:
                {
                    // "fd42:88::1000/64 fd42:88::1"
                    string[] pieces = parts[1].Split('/', StringSplitOptions.RemoveEmptyEntries);
                    s.Address6 = pieces.Length > 0 ? pieces[0] : "";
                    s.Prefix6 = pieces.Length > 1 ? Integer(pieces[1], 64) : 64;
                    break;
                }
                case "route-gateway" when parts.Length >= 2:
                    s.Gateway = parts[1];
                    break;
                case "route" when parts.Length >= 2:
                    s.Routes.Add(string.Join(' ', parts.Skip(1)));
                    break;
                case "redirect-gateway":
                    s.RedirectGateway = true;
                    break;
                case "dhcp-option" when parts.Length >= 3 && parts[1] == "DNS":
                    s.Dns.Add(parts[2]);
                    break;
                case "tun-mtu" when parts.Length >= 2:
                    s.Mtu = Integer(parts[1], 1500);
                    break;
                case "ping" when parts.Length >= 2:
                    s.PingInterval = Seconds(parts[1], 10);
                    break;
                case "ping-restart" when parts.Length >= 2:
                    s.PingRestart = Seconds(parts[1], 60);
                    break;
                case "peer-id" when parts.Length >= 2:
                    s.PeerID = uint.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out uint pid) ? pid : 0;
                    break;
                case "cipher" when parts.Length >= 2:
                    if (parts[1] != "AES-256-GCM") throw new LatticeTunnelException($"gateway chose cipher {parts[1]}");
                    break;
                case "key-derivation" when parts.Length >= 2:
                    exportedKeys = exportedKeys || parts[1] == "tls-ekm";
                    break;
                case "protocol-flags":
                    exportedKeys = exportedKeys || parts.Contains("tls-ekm");
                    exitNotify = parts.Contains("cc-exit");
                    break;
                case "comp-lzo":
                case "compress":
                    throw new LatticeTunnelException("gateway asked for compression");
            }
        }
        if (!exportedKeys) throw new LatticeTunnelException("gateway did not agree to TLS-exported keys");
        if (s.Address.Length == 0) throw new LatticeTunnelException("gateway assigned no address");
        _exitNotify = exitNotify;
        Settings = s;
    }

    // ---- output ----

    private static void EnqueueTlsOutput(KeyState ks)
    {
        byte[] output = ks.Tls.Drain();
        int offset = 0;
        while (offset < output.Length)
        {
            int size = Math.Min(ControlChunk, output.Length - offset);
            var chunk = new byte[size];
            Array.Copy(output, offset, chunk, 0, size);
            ks.Queue.Enqueue((Opcode.Control, chunk));
            offset += size;
        }
    }

    private void Flush(KeyState ks, double now)
    {
        while (ks.InflightPackets.Count < SendWindow && ks.Queue.Count > 0)
        {
            var (opcode, payload) = ks.Queue.Dequeue();
            uint id = ks.NextSendID;
            ks.NextSendID += 1;
            ks.InflightPackets[id] = new KeyState.Inflight(opcode, payload, now, 1);
            Transmit(ks, id, opcode, payload);
        }
    }

    private void Transmit(KeyState ks, uint id, Opcode opcode, byte[] payload)
    {
        var packet = new ControlPacket { Opcode = opcode, KeyID = ks.KeyID, SessionID = _sessionID, PacketID = id, Payload = payload };
        Send(packet.Encoded());
    }

    /// <summary>Send one IP packet through the tunnel.</summary>
    public void SendPacket(ReadOnlySpan<byte> packet, double now)
    {
        if (State.Kind != TunnelStateKind.Connected) return;
        Seal(packet, now);
    }

    private void Seal(ReadOnlySpan<byte> plaintext, double now)
    {
        if (_current is not { } ks || ks.Keys is not { } keys || ks.SendPacketID >= uint.MaxValue - 1) return;
        ks.SendPacketID += 1;
        byte[] datagram;
        try { datagram = DataChannel.Seal(plaintext, keys, ks.KeyID, Settings.PeerID, ks.SendPacketID); }
        catch (LatticeTunnelException) { return; }
        _lastSent = now;
        Send(datagram);
    }

    // ---- clock ----

    /// <summary>Call a few times a second.</summary>
    public void Tick(double now)
    {
        if (!IsLive) return;
        foreach (KeyState? candidate in new[] { _pending, _current })
        {
            if (candidate is not { } ks) continue;
            if (!IsLive) return;
            foreach (uint id in ks.InflightPackets.Keys.ToArray())
            {
                var entry = ks.InflightPackets[id];
                if (now - entry.SentAt < entry.Wait) continue;
                ks.InflightPackets[id] = entry with { SentAt = now, Wait = Math.Min(entry.Wait * 2, 8) };
                Transmit(ks, id, entry.Opcode, entry.Payload);
            }
            try
            {
                Advance(ks, now);
            }
            catch (Exception e)
            {
                NegotiationFailed(ks, e.Message);
                continue;
            }
            if (!IsLive) return;
            Flush(ks, now);
        }
        if (!IsLive) return;
        if (_pending is { } waiting && now - waiting.StartedAt > HandshakeTimeout)
        {
            NegotiationFailed(waiting, "handshake timed out");
            if (!IsLive) return;
        }
        if (State.Kind != TunnelStateKind.Connected || _current is not { } live) return;
        if (now - _lastReceived > Settings.PingRestart)
        {
            Fail("gateway stopped answering");
            return;
        }
        if (now - _lastSent >= Settings.PingInterval)
        {
            Seal(DataChannel.Ping, now);
        }
        if (_rekeyInterval > 0 && _pending is null && now - live.EstablishedAt >= _rekeyInterval)
        {
            byte next = (byte)(live.KeyID >= 7 ? 1 : live.KeyID + 1);
            try
            {
                var fresh = new KeyState(next, Opcode.SoftReset, _identity, now);
                _pending = fresh;
                Flush(fresh, now);
            }
            catch (Exception e)
            {
                Log($"rekey could not start: {e.Message}");
            }
        }
    }
}
