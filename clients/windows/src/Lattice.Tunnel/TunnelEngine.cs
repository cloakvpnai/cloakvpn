using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using Lattice.Net;

namespace Lattice.Tunnel;

/// <summary>
/// Runs one TunnelSession against one gateway: owns the UDP socket and the
/// threads that move packets, and keeps every call into the session on one
/// lock, because the session itself is not thread safe.
///
/// One engine is one connection attempt. Reconnecting, backoff and reacting to
/// network changes belong to whoever owns the engine.
/// </summary>
public sealed class TunnelEngine : IDisposable
{
    private const int SIO_UDP_CONNRESET = unchecked((int)0x9800000C);

    private readonly object _gate = new();
    private readonly TunnelSession _session;
    private readonly Socket _socket;
    private readonly Stopwatch _clock = Stopwatch.StartNew();
    private volatile bool _running;
    private Thread? _socketThread, _timerThread, _tunThread;
    private volatile WintunSession? _tun;
    private long _bytesIn, _bytesOut, _packetsIn, _packetsOut;

    public event Action<TunnelState>? StateChanged;
    public event Action<string>? Log;

    public IPEndPoint Gateway { get; }
    public long BytesIn => Interlocked.Read(ref _bytesIn);
    public long BytesOut => Interlocked.Read(ref _bytesOut);
    public long PacketsIn => Interlocked.Read(ref _packetsIn);
    public long PacketsOut => Interlocked.Read(ref _packetsOut);

    /// <summary>True when this engine reaches the gateway over TCP, for networks that block UDP.</summary>
    public bool Tcp { get; }

    private readonly System.Threading.Tasks.Task? _connect;
    private volatile bool _transportFailed;
    /// <summary>TCP only: the connection could not be made, or ended. This engine will never connect.</summary>
    public bool TransportFailed => _transportFailed;

    /// <param name="bindTo">Local address of the physical interface to send from, or null to let Windows choose.</param>
    /// <param name="tcp">Carry the tunnel over TCP. The gateway must be listening for it on this port.</param>
    public TunnelEngine(TunnelIdentity identity, IPEndPoint gateway, double rekeySeconds, IPAddress? bindTo = null, bool tcp = false)
    {
        Gateway = gateway;
        Tcp = tcp;
        _session = new TunnelSession(identity, rekeySeconds) { Tcp = tcp };
        if (tcp)
        {
            _socket = new Socket(gateway.AddressFamily, SocketType.Stream, ProtocolType.Tcp)
            {
                NoDelay = true,          // packets are already whole; waiting to batch them only adds delay
                ReceiveTimeout = 500,
                SendTimeout = 3000,      // a stalled connection must not hold the session lock for long
            };
            if (bindTo is not null) _socket.Bind(new IPEndPoint(bindTo, 0));
            // Unlike UDP, TCP has to reach the gateway before anything can be sent. The attempt
            // starts now and is waited for on the reader thread, so making an engine never blocks.
            try { _connect = _socket.ConnectAsync(gateway); }
            catch (SocketException e) { _connect = System.Threading.Tasks.Task.FromException(e); }
        }
        else
        {
            _socket = new Socket(gateway.AddressFamily, SocketType.Dgram, ProtocolType.Udp)
            {
                ReceiveBufferSize = 1 << 20,
                SendBufferSize = 1 << 20,
                ReceiveTimeout = 500,
            };
            // Without this an ICMP "port unreachable" makes the next receive fail on Windows.
            try { _socket.IOControl(SIO_UDP_CONNRESET, new byte[] { 0, 0, 0, 0 }, null); } catch (SocketException) { }
            if (bindTo is not null) _socket.Bind(new IPEndPoint(bindTo, 0));
            _socket.Connect(gateway);
        }

        _session.Send = datagram =>
        {
            try { _socket.Send(tcp ? TcpFraming.Frame(datagram) : datagram); }
            catch (SocketException) { /* the network is down; the session's timers handle it */ }
            catch (ObjectDisposedException) { }
        };
        _session.OnPacket = packet =>
        {
            Interlocked.Add(ref _bytesIn, packet.Length);
            Interlocked.Increment(ref _packetsIn);
            _tun?.Send(packet);
        };
        _session.OnStateChange = state => StateChanged?.Invoke(state);
        _session.Log = message => Log?.Invoke(message);
    }

    private double Now => _clock.Elapsed.TotalSeconds;

    // Snapshots of the session, taken under the lock.
    public TunnelState State { get { lock (_gate) return _session.State; } }
    public string Suite { get { lock (_gate) return _session.Suite; } }
    public int RekeyCount { get { lock (_gate) return _session.RekeyCount; } }
    public TunnelSettings Settings { get { lock (_gate) return _session.Settings; } }

    public void Start()
    {
        if (_running) return;
        _running = true;
        _socketThread = new Thread(SocketLoop) { IsBackground = true, Name = "lattice-udp" };
        _timerThread = new Thread(TimerLoop) { IsBackground = true, Name = "lattice-timer" };
        _socketThread.Start();
        if (Tcp) return; // the reader thread starts the session once the connection is made
        lock (_gate) _session.Start(Now);
        _timerThread.Start();
    }

    /// <summary>Starts carrying the adapter's traffic. Call once the session is connected.</summary>
    public void AttachTun(WintunSession tun)
    {
        if (_tun is not null) throw new InvalidOperationException("an adapter is already attached");
        _tun = tun;
        _tunThread = new Thread(TunLoop) { IsBackground = true, Name = "lattice-tun" };
        _tunThread.Start();
    }

    private void SocketLoop()
    {
        if (Tcp) { StreamLoop(); return; }
        var buffer = new byte[65535];
        while (_running)
        {
            int n;
            try { n = _socket.Receive(buffer); }
            catch (SocketException e) when (e.SocketErrorCode is SocketError.TimedOut or SocketError.ConnectionReset
                                                or SocketError.NetworkUnreachable or SocketError.HostUnreachable)
            { continue; }
            catch (SocketException) { if (_running) Thread.Sleep(100); continue; }
            catch (ObjectDisposedException) { break; }
            if (n <= 0) continue;
            var datagram = new byte[n];
            Buffer.BlockCopy(buffer, 0, datagram, 0, n);
            lock (_gate) _session.Receive(datagram, Now);
        }
    }

    /// <summary>The TCP reader: bytes arrive in pieces of any size and are cut back into packets.</summary>
    private void StreamLoop()
    {
        // First the connection itself. A few seconds is plenty; a network that drops it never answers.
        bool connected = false;
        try { connected = _connect is not null && _connect.Wait(6000); }
        catch (AggregateException) { }
        if (!connected || !_running)
        {
            _transportFailed = true;
            if (_running) Log?.Invoke("no TCP connection to the gateway");
            return;
        }
        lock (_gate) _session.Start(Now);
        _timerThread?.Start();

        var buffer = new byte[65535];
        var reader = new TcpFraming.Reader();
        while (_running)
        {
            int n;
            try { n = _socket.Receive(buffer); }
            catch (SocketException e) when (e.SocketErrorCode == SocketError.TimedOut) { continue; }
            catch (SocketException) { break; }          // the connection is gone
            catch (ObjectDisposedException) { break; }
            if (n == 0) break;                           // the gateway closed it
            bool sane;
            lock (_gate) sane = reader.Add(buffer.AsSpan(0, n), packet => _session.Receive(packet, Now));
            if (!sane) break;
        }
        // Nothing more can arrive on this connection. The owner makes a new engine.
        _transportFailed = true;
        if (_running) Log?.Invoke("the TCP connection to the gateway ended");
    }

    private void TimerLoop()
    {
        while (_running)
        {
            Thread.Sleep(200);
            if (!_running) break;
            lock (_gate) _session.Tick(Now);
        }
    }

    private void TunLoop()
    {
        WintunSession? tun = _tun;
        if (tun is null) return;
        try
        {
            while (_running)
            {
                bool any = false;
                while (_running && tun.TryReceive(out byte[] packet))
                {
                    any = true;
                    // The adapter also emits IPv6 housekeeping; carry it only if the gateway assigned IPv6.
                    if (packet.Length == 0) continue;
                    int version = packet[0] >> 4;
                    if (version != 4 && version != 6) continue;
                    lock (_gate)
                    {
                        if (version == 6 && _session.Settings.Address6.Length == 0) continue;
                        _session.SendPacket(packet, Now);
                    }
                    Interlocked.Add(ref _bytesOut, packet.Length);
                    Interlocked.Increment(ref _packetsOut);
                }
                if (!any) tun.ReadWaitHandle.WaitOne(250);
            }
        }
        catch (ObjectDisposedException) { /* adapter closed under us */ }
        catch (Exception e) { Log?.Invoke($"adapter reader stopped: {e.Message}"); }
    }

    /// <summary>Tells the gateway we are leaving and stops. Safe to call more than once.</summary>
    public void Stop()
    {
        if (!_running) return;
        lock (_gate) _session.Close(Now);
        _running = false;
        // The adapter reader must have stopped before its session can be ended by the owner.
        _tunThread?.Join(2000);
        _tun = null;
        try { _socket.Close(); } catch (SocketException) { }
        if (_socketThread is { IsAlive: true }) _socketThread.Join(2000);
        // Over TCP the timer thread only starts once the connection is made.
        if (_timerThread is { IsAlive: true }) _timerThread.Join(2000);
    }

    public void Dispose()
    {
        Stop();
        lock (_gate) _session.Dispose();
        _socket.Dispose();
    }
}
