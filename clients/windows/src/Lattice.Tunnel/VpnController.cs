using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Lattice.Api;
using Lattice.Identity;
using Lattice.Net;
using Lattice.Tunnel;

namespace Lattice.Core;

/// <summary>What the app window is told. Never contains the account number or any key.</summary>
public sealed class VpnStatus
{
    /// <summary>off, connecting, connected, reconnecting or error.</summary>
    [JsonPropertyName("state")] public string State { get; set; } = "off";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("region")] public string Region { get; set; } = "";
    [JsonPropertyName("suite")] public string Suite { get; set; } = "";
    /// <summary>"udp", or "tcp" when the network blocked UDP and the tunnel runs over TCP 443. Empty when not connected.</summary>
    [JsonPropertyName("transport")] public string Transport { get; set; } = "";
    [JsonPropertyName("address")] public string Address { get; set; } = "";
    [JsonPropertyName("address6")] public string Address6 { get; set; } = "";
    [JsonPropertyName("exit")] public string Exit { get; set; } = "";
    [JsonPropertyName("since")] public long ConnectedSinceUnix { get; set; }
    [JsonPropertyName("rx")] public long BytesIn { get; set; }
    [JsonPropertyName("tx")] public long BytesOut { get; set; }
    [JsonPropertyName("rekeys")] public int KeyChanges { get; set; }
    [JsonPropertyName("latency")] public int LatencyMs { get; set; }
    [JsonPropertyName("latency_best")] public int LatencyBestMs { get; set; }
    [JsonPropertyName("latency_avg")] public int LatencyAverageMs { get; set; }
    [JsonPropertyName("hold")] public bool TrafficHeld { get; set; }
    [JsonPropertyName("signed_in")] public bool SignedIn { get; set; }
    [JsonPropertyName("tier")] public string Tier { get; set; } = "";
    [JsonPropertyName("active_until")] public string ActiveUntil { get; set; } = "";
    [JsonPropertyName("device_limit")] public int DeviceLimit { get; set; }
    [JsonPropertyName("device_count")] public int DeviceCount { get; set; }
    [JsonPropertyName("cert_until")] public long CertificateUntilUnix { get; set; }
    [JsonPropertyName("regions")] public List<string> Regions { get; set; } = new();
    [JsonPropertyName("version")] public string Version { get; set; } = "";
    [JsonPropertyName("library")] public string Library { get; set; } = "";
}

/// <summary>
/// The whole life of the VPN on this PC: sign-in, enrollment, the adapter, the
/// traffic hold, connecting, reconnecting and changing region. One worker
/// thread runs for as long as the VPN is switched on. Port of the behaviour of
/// the Apple tunnel extension and the Android tunnel service.
/// </summary>
public sealed class VpnController : IDisposable
{
    private static readonly TimeSpan RenewalAfterRefusalEvery = TimeSpan.FromMinutes(10);

    // Connecting tries UDP and, where the gateway has one, its TCP way in, side by side.
    /// <summary>TCP starts this long after UDP. A fast UDP answer usually arrives first anyway.</summary>
    private const double TcpStartsAfterSeconds = 0.5;
    /// <summary>UDP is preferred until this long after the start, even if TCP is ready sooner.</summary>
    private const double UdpFirstSeconds = 2.0;

    private readonly object _gate = new();
    private readonly string _dataDir;
    private readonly string _serviceExecutable;
    private readonly Action<string> _log;
    private readonly IdentityStore _store;
    private readonly NameCache _names;
    private readonly AccountApi _api;
    private readonly Cnsa2Enroller _enroller;
    private readonly AutoResetEvent _wake = new(false);
    private readonly Timer _renewalTimer;

    private Thread? _worker;
    private bool _wanted;
    private string _region = "";
    private bool _regionChanged;
    private volatile bool _networkChanged;
    private string _state = "off";
    private string _message = "";
    private TunnelEngine? _engine;
    private TunnelSettings? _settings;
    private string _exit = "";
    private DateTimeOffset? _since;
    private bool _held;
    private AccountStatus? _account;
    private readonly List<int> _latency = new();
    private DateTimeOffset _lastRefusalRenewal = DateTimeOffset.MinValue;

    public VpnController(string dataDirectory, string serviceExecutable, Action<string> log)
    {
        _dataDir = dataDirectory;
        _serviceExecutable = serviceExecutable;
        _log = log;
        _store = new IdentityStore(dataDirectory);
        _names = new NameCache(Path.Combine(dataDirectory, "names.json"));
        _api = new AccountApi(_names.CreateHandler());
        _enroller = new Cnsa2Enroller(_store, _api);
        _region = LoadRegion();
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        _names.Prime(new[] { new Uri(AccountApi.BaseUrl).Host }.Concat(_enroller.Gateways().Select(g => g.Host)));
        _renewalTimer = new Timer(_ => RenewInBackground(), null, TimeSpan.FromMinutes(2), TimeSpan.FromHours(6));
    }

    private void OnNetworkChanged(object? sender, EventArgs e) { _networkChanged = true; _wake.Set(); }

    // ---- settings ----

    private string SettingsPath => Path.Combine(_dataDir, "settings.json");

    private string LoadRegion()
    {
        try
        {
            if (File.Exists(SettingsPath))
                return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(SettingsPath))?.GetValueOrDefault("region") ?? "";
        }
        catch (Exception e) when (e is JsonException or IOException) { }
        return "";
    }

    private void SaveRegion(string region)
    {
        try { File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new Dictionary<string, string> { ["region"] = region })); }
        catch (IOException) { }
    }

    // ---- status ----

    public VpnStatus Status()
    {
        lock (_gate)
        {
            var s = new VpnStatus
            {
                State = _state, Message = _message, Region = _region, TrafficHeld = _held, Exit = _exit,
                SignedIn = _store.AccountNumber() is not null,
                Regions = _enroller.Gateways().Select(g => g.Id).ToList(),
                Version = typeof(VpnController).Assembly.GetName().Version?.ToString(3) ?? "",
                Library = DeviceKey.OpenSslVersion,
                CertificateUntilUnix = _enroller.State()?.NotAfterUnix ?? 0,
            };
            if (_account is { } a)
            {
                s.Tier = a.Tier; s.ActiveUntil = a.ActiveUntil; s.DeviceLimit = a.DeviceLimit; s.DeviceCount = a.DeviceCount;
            }
            if (_state == "connected" && _engine is { } engine)
            {
                s.Suite = engine.Suite;
                s.Transport = engine.Tcp ? "tcp" : "udp";
                s.BytesIn = engine.BytesIn; s.BytesOut = engine.BytesOut; s.KeyChanges = engine.RekeyCount;
                s.Address = _settings?.Address ?? ""; s.Address6 = _settings?.Address6 ?? "";
                s.ConnectedSinceUnix = _since?.ToUnixTimeSeconds() ?? 0;
                if (_latency.Count > 0)
                {
                    s.LatencyMs = _latency[^1]; s.LatencyBestMs = _latency.Min(); s.LatencyAverageMs = (int)Math.Round(_latency.Average());
                }
            }
            return s;
        }
    }

    private void Set(string state, string message = "")
    {
        lock (_gate) { _state = state; _message = message; }
        _log($"state: {state}{(message.Length > 0 ? " (" + message + ")" : "")}");
    }

    // ---- account ----

    /// <summary>Checks the account number with the server and saves it. Returns an error message, or "" on success.</summary>
    public async Task<string> SignInAsync(string accountNumber)
    {
        if (!AccountNumber.IsComplete(accountNumber)) return "That is not a complete account number.";
        try
        {
            AccountStatus status = await _api.FetchAccountAsync(accountNumber).ConfigureAwait(false);
            _store.SaveAccountNumber(accountNumber);
            lock (_gate) _account = status;
            _log("signed in");
            return "";
        }
        catch (AccountException e) { return e.Message; }
    }

    public async Task<string> RefreshAccountAsync()
    {
        if (_store.AccountNumber() is not { } account) return "Not signed in.";
        try
        {
            AccountStatus status = await _api.FetchAccountAsync(account).ConfigureAwait(false);
            lock (_gate) _account = status;
            return "";
        }
        catch (AccountException e) { return e.Message; }
    }

    /// <summary>Disconnects, removes this PC from the account and erases its key.</summary>
    public async Task SignOutAsync()
    {
        Disconnect();
        _worker?.Join(8000);
        if (_store.AccountNumber() is { } account) await _enroller.ForgetAsync(account).ConfigureAwait(false);
        else { _store.Reset(); _store.ClearAccountNumber(); }
        lock (_gate) _account = null;
        _log("signed out");
    }

    private void RenewInBackground()
    {
        try
        {
            if (_store.AccountNumber() is { } account && _enroller.RenewalDue(DateTimeOffset.UtcNow))
            {
                bool renewed = _enroller.RenewIfDueAsync(account).GetAwaiter().GetResult();
                if (renewed) _log("certificate renewed in the background");
            }
        }
        catch (Exception e) when (e is AccountException or EnrollmentException or LatticeTunnelException or IOException)
        {
            _log($"background renewal did not succeed: {e.Message}");
        }
    }

    // ---- commands ----

    /// <summary>
    /// Checks that a gateway's TCP listener completes a full CNSA 2.0 handshake with this
    /// device's own certificate. Handshake only: no adapter, no routes, no traffic held, and
    /// nothing about the normal connection changes. Refused while the tunnel is in use.
    /// </summary>
    /// <param name="host">An IPv4 address to use in place of the gateway's own, for a gateway
    /// whose TCP listener answers on a second address. The gateway's certificate must still match.</param>
    public string TestTcp(string? region, int port, string? host)
    {
        if (port is not (443 or 8443)) return "failed: the port must be 443 or 8443";
        if (Wanted) return "failed: disconnect first";
        if (_enroller.NeedsEnrollment(DateTimeOffset.UtcNow)) return "failed: not signed in";
        Cnsa2Gateway? gateway = _enroller.Choose(string.IsNullOrEmpty(region) ? null : region);
        if (gateway is null) return "failed: no such region";
        IPAddress? address;
        if (string.IsNullOrEmpty(host)) address = _names.Resolve(gateway.Host).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork);
        else if (!IPAddress.TryParse(host, out address) || address.AddressFamily != AddressFamily.InterNetwork) return "failed: the address must be IPv4";
        if (address is null) return "failed: the gateway has no IPv4 address";

        var notes = new List<string>();
        var clock = System.Diagnostics.Stopwatch.StartNew();
        using TunnelIdentity identity = _enroller.IdentityFor(gateway);
        using var engine = new TunnelEngine(identity, new IPEndPoint(address, port), Cnsa2Enroller.RekeySeconds, null, tcp: true);
        engine.Log += m => { lock (notes) notes.Add(m); };
        engine.Start();
        while (engine.State.Kind is TunnelStateKind.Idle or TunnelStateKind.Connecting && !engine.TransportFailed && clock.Elapsed.TotalSeconds < 20) Thread.Sleep(50);
        bool connected = engine.State.Kind == TunnelStateKind.Connected;
        string suite = engine.Suite;
        TunnelSettings settings = engine.Settings;
        engine.Stop();
        string said; lock (notes) said = string.Join(" | ", notes.TakeLast(4));
        _log($"tcp test {gateway.Id} port {port}: {(connected ? "connected" : "failed")}");
        return connected
            ? $"ok: {gateway.Id} over TCP {port} in {clock.ElapsedMilliseconds} ms, {suite}, tunnel address {settings.Address}"
            : $"failed: {engine.State.Kind} after {clock.ElapsedMilliseconds} ms. {said}";
    }

    /// <summary>Switches the VPN on, or moves a running tunnel to another region in place.</summary>
    public void Connect(string? region)
    {
        lock (_gate)
        {
            if (!string.IsNullOrEmpty(region) && region != _region)
            {
                _region = region;
                SaveRegion(region);
                if (_wanted) _regionChanged = true;
            }
            if (!_wanted)
            {
                _wanted = true;
                _regionChanged = false;
                _worker = new Thread(Run) { IsBackground = true, Name = "lattice-vpn" };
                _worker.Start();
            }
        }
        _wake.Set();
    }

    public void Disconnect()
    {
        lock (_gate) _wanted = false;
        _wake.Set();
    }

    private bool Wanted { get { lock (_gate) return _wanted; } }

    // ---- the worker ----

    private static bool CertificateCannotFix(string reason) =>
        reason.Contains("CNSA 2.0 suite", StringComparison.Ordinal) || reason.Contains("compression", StringComparison.Ordinal)
        || reason.Contains("cipher", StringComparison.Ordinal);

    private void Run()
    {
        WintunAdapter? adapter = null; WintunSession? tun = null; TunnelNetwork? network = null;
        var hold = new TrafficHold();
        string final = "";
        try
        {
            Set("connecting");
            string account = _store.AccountNumber() ?? throw new EnrollmentException("Sign in with your account number first.");

            // Everything that needs the ordinary network happens before traffic is held.
            _names.PreferCache = false;
            if (_enroller.NeedsEnrollment(DateTimeOffset.UtcNow))
            {
                _log("enrolling this PC");
                _enroller.EnrollAsync(account).GetAwaiter().GetResult();
            }
            _names.Prime(_enroller.Gateways().Select(g => g.Host).Append(new Uri(AccountApi.BaseUrl).Host));

            adapter = WintunAdapter.Create();
            network = new TunnelNetwork(adapter.Luid);
            tun = adapter.StartSession();
            hold.Enable(adapter.Luid, _serviceExecutable);
            lock (_gate) _held = true;
            _names.PreferCache = true;
            _log("traffic is held until the tunnel is up");

            double backoff = 1;
            bool everConnected = false, routed = false;
            // Set after UDP gets no answer from a gateway that also listens on TCP 443. Cleared
            // when the network or the region changes, so UDP is always tried first there.
            bool preferTcp = false;
            string appliedAddress = "";

            while (Wanted)
            {
                string region; lock (_gate) { region = _region; _regionChanged = false; }
                _networkChanged = false;
                Cnsa2Gateway gateway = _enroller.Choose(region.Length > 0 ? region : null)
                    ?? throw new EnrollmentException($"Region \"{region}\" is not available.");
                lock (_gate) { if (_region.Length == 0) _region = gateway.Id; }

                IPEndPoint? tcpPath = TcpPaths.For(gateway);
                // UDP already got no answer on this network: do not spend time on it again.
                bool tcpOnly = preferTcp && tcpPath is not null;
                bool useTcp = false; // which way in won, once one has

                IPAddress address;   // the gateway's own address: where UDP goes, and where traffic leaves from
                IPAddress target;    // the address the winning connection uses
                PhysicalRoute physical;
                PhysicalRoute? physicalTcp = null;
                try
                {
                    address = _names.Resolve(gateway.Host).First(a => a.AddressFamily == AddressFamily.InterNetwork);
                    target = address;
                    network.ClearGatewayBypasses();
                    physical = network.AddGatewayBypass(address);
                    if (tcpPath is not null) physicalTcp = network.AddGatewayBypass(tcpPath.Address);
                }
                catch (Exception e) when (e is IOException or InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    Set(everConnected ? "reconnecting" : "connecting", "Waiting for a network connection");
                    _wake.WaitOne(TimeSpan.FromSeconds(Math.Min(backoff, 5)));
                    backoff = Math.Min(backoff * 2, 30);
                    _log($"no path to the gateway: {e.Message}");
                    continue;
                }

                string failure = "";
                TunnelEngine? udpEngine = null, tcpEngine = null;
                using (TunnelIdentity identity = _enroller.IdentityFor(gateway))
                using (TunnelIdentity? identityTcp = tcpPath is null ? null : _enroller.IdentityFor(gateway))
                try
                {
                    // Both ways in are tried side by side, so a network that blocks UDP costs the
                    // person about two seconds, not a long wait. UDP is the better carrier, so it
                    // starts first and is given until UdpFirstSeconds to win even if TCP is ready.
                    var race = System.Diagnostics.Stopwatch.StartNew();
                    _log($"connecting to {gateway.Id}");
                    if (!tcpOnly)
                    {
                        udpEngine = new TunnelEngine(identity, new IPEndPoint(address, gateway.Port), Cnsa2Enroller.RekeySeconds, physical.SourceAddress);
                        udpEngine.Log += m => _log("session: " + m);
                        udpEngine.Start();
                    }
                    TunnelEngine? engine = null;
                    double limit = tcpPath is null ? 35 : 25;
                    while (Wanted && engine is null && race.Elapsed.TotalSeconds < limit)
                    {
                        lock (_gate) if (_regionChanged) break;
                        double t = race.Elapsed.TotalSeconds;
                        if (tcpEngine is null && tcpPath is not null && (tcpOnly || t >= TcpStartsAfterSeconds))
                        {
                            tcpEngine = new TunnelEngine(identityTcp!, tcpPath, Cnsa2Enroller.RekeySeconds, physicalTcp!.SourceAddress, tcp: true);
                            tcpEngine.Log += m => _log("session (tcp): " + m);
                            tcpEngine.Start();
                        }
                        bool udpDead = udpEngine is null || udpEngine.State.Kind is TunnelStateKind.Failed or TunnelStateKind.Closed;
                        bool tcpDead = tcpPath is null || (tcpEngine is not null && (tcpEngine.TransportFailed || tcpEngine.State.Kind is TunnelStateKind.Failed or TunnelStateKind.Closed));
                        if (udpEngine?.State.Kind == TunnelStateKind.Connected) engine = udpEngine;
                        else if (tcpEngine?.State.Kind == TunnelStateKind.Connected && (udpDead || t >= UdpFirstSeconds)) engine = tcpEngine;
                        else if (udpDead && tcpDead) break;
                        else Thread.Sleep(25);
                    }

                    if (engine is not null)
                    {
                        // The other attempt is not needed: tell its gateway and drop it.
                        if (ReferenceEquals(engine, tcpEngine))
                        {
                            useTcp = true; preferTcp = true;
                            target = tcpPath!.Address; physical = physicalTcp!;
                            udpEngine?.Stop();
                            if (!tcpOnly) _log($"UDP gave no answer in {race.Elapsed.TotalSeconds:0.0} s; using TCP 443");
                        }
                        else tcpEngine?.Stop();

                        TunnelSettings s = engine.Settings;
                        string wantAddress = s.Address + "/" + s.Netmask + "/" + s.Address6;
                        if (wantAddress != appliedAddress)
                        {
                            network.RemoveAddresses();
                            network.AddAddress(IPAddress.Parse(s.Address), TunnelNetwork.PrefixLength(IPAddress.Parse(s.Netmask)));
                            network.ConfigureInterface(AddressFamily.InterNetwork, s.Mtu, 5);
                            if (s.Address6.Length > 0)
                            {
                                network.AddAddress(IPAddress.Parse(s.Address6), s.Prefix6);
                                network.ConfigureInterface(AddressFamily.InterNetworkV6, s.Mtu, 5);
                            }
                            appliedAddress = wantAddress;
                        }
                        if (!routed)
                        {
                            network.AddDefaultRoutes(ipv4: true, ipv6: s.Address6.Length > 0);
                            routed = true;
                        }
                        network.SetDns(s.Dns.Select(IPAddress.Parse).ToList());
                        engine.AttachTun(tun);

                        lock (_gate)
                        {
                            _engine = engine; _settings = s; _exit = address.ToString();
                            _since = DateTimeOffset.UtcNow; _latency.Clear();
                        }
                        _names.PreferCache = false; // lookups now go through the tunnel
                        Set("connected");
                        _log($"connected{(useTcp ? " over TCP 443" : "")}: {engine.Suite}");
                        everConnected = true; backoff = 1;

                        IPAddress? inside = IPAddress.TryParse(s.Gateway, out IPAddress? g) ? g : null;
                        using var ping = new Ping();
                        DateTime nextPing = DateTime.UtcNow.AddSeconds(1), lastLoop = DateTime.UtcNow;
                        while (Wanted && engine.State.Kind == TunnelStateKind.Connected)
                        {
                            lock (_gate) if (_regionChanged) break;
                            // Over TCP a dropped connection is known at once; do not wait for the keepalive.
                            if (engine.TransportFailed) { failure = "the TCP connection ended"; break; }
                            DateTime now = DateTime.UtcNow;
                            // The PC slept: the gateway has long since dropped this session.
                            if ((now - lastLoop).TotalSeconds > 20) { failure = "woke from sleep"; break; }
                            lastLoop = now;
                            if (_networkChanged)
                            {
                                _networkChanged = false;
                                PhysicalRoute? current = PhysicalRoutes.Find(target, adapter.Luid);
                                if (current is null || !Equals(current.SourceAddress, physical.SourceAddress) || current.InterfaceLuid != physical.InterfaceLuid)
                                {
                                    failure = "network changed";
                                    break;
                                }
                            }
                            if (inside is not null && now >= nextPing)
                            {
                                nextPing = now.AddSeconds(3);
                                try
                                {
                                    PingReply reply = ping.Send(inside, 1500);
                                    if (reply.Status == IPStatus.Success)
                                        lock (_gate)
                                        {
                                            _latency.Add((int)Math.Max(1, reply.RoundtripTime));
                                            if (_latency.Count > 20) _latency.RemoveAt(0);
                                        }
                                }
                                catch (PingException) { }
                            }
                            _wake.WaitOne(250);
                        }
                        if (failure.Length == 0 && engine.State.Kind == TunnelStateKind.Failed) failure = engine.State.Reason;
                        lock (_gate) { _engine = null; _since = null; }
                        _names.PreferCache = true;
                    }
                    else
                    {
                        // A reason one of them gave (a refused certificate, say) beats plain silence.
                        failure = udpEngine?.State.Kind == TunnelStateKind.Failed ? udpEngine.State.Reason
                            : tcpEngine?.State.Kind == TunnelStateKind.Failed ? tcpEngine.State.Reason
                            : "the gateway did not answer";
                    }
                }
                finally
                {
                    udpEngine?.Dispose();
                    tcpEngine?.Dispose();
                }

                if (!Wanted) break;
                bool moving; lock (_gate) moving = _regionChanged;
                if (moving) { preferTcp = false; Set("connecting"); _log("changing region inside the hold"); continue; }

                _log($"connection ended: {failure}");
                // A different network may well allow UDP: start from UDP again there.
                if (failure is "network changed" or "woke from sleep") preferTcp = false;
                // Nothing answered, by either way in: next time try both again from the start.
                else if (failure == "the gateway did not answer") preferTcp = false;
                if (CertificateCannotFix(failure))
                    throw new LatticeTunnelException("This version of the app cannot connect to the gateway. Please update Lattice VPN.");

                // A device removed by the plan's device limit is refused silently. Ask for a
                // fresh certificate once, at most every 10 minutes, then try again.
                if (!everConnected && DateTimeOffset.UtcNow - _lastRefusalRenewal > RenewalAfterRefusalEvery)
                {
                    _lastRefusalRenewal = DateTimeOffset.UtcNow;
                    try
                    {
                        _log("first connection did not come up; asking for a fresh certificate");
                        _enroller.EnrollAsync(account).GetAwaiter().GetResult();
                        continue;
                    }
                    catch (AccountException e) when (e.Kind is AccountErrorKind.NoSubscription or AccountErrorKind.Unauthorized)
                    {
                        throw;
                    }
                    catch (Exception e) when (e is AccountException or EnrollmentException)
                    {
                        _log($"certificate request did not succeed: {e.Message}");
                    }
                }

                Set(everConnected ? "reconnecting" : "connecting", everConnected ? "Reconnecting" : "");
                if (failure is "network changed" or "woke from sleep") backoff = 1;
                else
                {
                    _wake.WaitOne(TimeSpan.FromSeconds(backoff));
                    backoff = Math.Min(backoff * 2, 30);
                }
            }
        }
        catch (Exception e) when (e is AccountException or EnrollmentException or LatticeTunnelException or IOException
                                      or System.ComponentModel.Win32Exception or InvalidOperationException or SocketException)
        {
            final = e.Message;
            _log($"stopped: {e.GetType().Name}: {e.Message}");
        }
        finally
        {
            lock (_gate) { _engine = null; _since = null; _wanted = false; }
            // Order matters: routes and adapter go first, the hold is lifted last.
            try { network?.SetDns(Array.Empty<IPAddress>()); } catch (Exception) { }
            network?.Dispose();
            tun?.Dispose();
            adapter?.Dispose();
            hold.Dispose();
            lock (_gate) _held = false;
            _names.PreferCache = false;
            Set(final.Length > 0 ? "error" : "off", final);
        }
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        _renewalTimer.Dispose();
        Disconnect();
        _worker?.Join(8000);
        _api.Dispose();
    }
}

/// <summary>
/// Where each gateway also accepts the tunnel over TCP 443, for networks that block UDP.
///
/// TEMPORARY, FOR TESTING: the one gateway that has a TCP listener is written in here. Before
/// this ships, the addresses must come from the gateway list the account service sends, so
/// that no address is built into the app. Do not release with this table.
/// </summary>
public static class TcpPaths
{
    private static readonly Dictionary<string, IPEndPoint> Known = new()
    {
        ["mx1"] = new IPEndPoint(IPAddress.Parse("216.238.75.153"), 443),
    };

    /// <summary>The gateway's TCP address, or null when it has none.</summary>
    public static IPEndPoint? For(Cnsa2Gateway gateway) => Known.TryGetValue(gateway.Id, out IPEndPoint? path) ? path : null;
}
