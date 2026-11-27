using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Lattice.Api;
using Lattice.Identity;
using Lattice.Net;
using Lattice.Tunnel;

namespace Lattice.Probe;

internal static class Program
{
    private static readonly string DataDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Lattice VPN Probe");
    private static string _logPath = "";

    // Everything printed is also appended to the log. Neither ever contains the
    // account number or any key material.
    private static void Say(string message)
    {
        string line = $"{DateTime.Now:HH:mm:ss.fff}  {message}";
        Console.WriteLine(line);
        if (_logPath.Length > 0)
        {
            try { File.AppendAllText(_logPath, line + Environment.NewLine); } catch (IOException) { }
        }
    }

    private static bool IsElevated()
    {
        using var id = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static string? Option(string[] args, string name)
    {
        int i = Array.IndexOf(args, name);
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    private static async Task<int> Main(string[] args)
    {
        _logPath = Option(args, "--log") ?? "";
        string command = args.Length > 0 ? args[0] : "help";
        try
        {
            switch (command)
            {
                case "holdtest": return HoldTest();
                case "run": return RunController(args);
                case "firstrun": return await FirstRun();
                case "selftest": return SelfTest();
                case "signin": return await SignIn();
                case "status": return await Status();
                case "enroll": return await Enroll();
                case "gateways": return Gateways();
                case "handshake": return Handshake(args);
                case "connect": return Connect(args);
                case "signout": return await SignOut();
                default:
                    Console.WriteLine("latticeprobe: exercises the Lattice VPN Windows tunnel");
                    Console.WriteLine("  selftest                     library, device key, adapter (adapter part needs administrator)");
                    Console.WriteLine("  signin                       type the account number; it is checked and saved protected");
                    Console.WriteLine("  status                       subscription and devices on the account");
                    Console.WriteLine("  enroll                       make this PC's key and get its certificate");
                    Console.WriteLine("  gateways                     gateways offered at enrollment");
                    Console.WriteLine("  handshake [--region id] [--seconds n] [--rekey s]");
                    Console.WriteLine("                               connect and report the suite; no adapter, no routing change");
                    Console.WriteLine("  connect [--region id] [--seconds n] [--rekey s] [--full]");
                    Console.WriteLine("                               bring up the adapter and ping through it (administrator)");
                    Console.WriteLine("  signout                      remove this PC from the account and erase its key");
                    Console.WriteLine("  any command: --log <file>    also write the output to a file");
                    return 2;
            }
        }
        catch (Exception e) when (e is AccountException or EnrollmentException or LatticeTunnelException)
        {
            Say($"FAILED: {e.Message}");
            return 1;
        }
        catch (Exception e)
        {
            Say($"FAILED ({e.GetType().Name}): {e.Message}");
            return 1;
        }
    }

    // ---- traffic hold and controller tests ----

    /// <summary>Runs another program (never this one, which the hold lets through) and returns its exit code and output.</summary>
    private static (int Code, string Output) Outside(string file, string arguments, int timeoutMs = 8000)
    {
        var psi = new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory, file), arguments)
        { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        using var p = System.Diagnostics.Process.Start(psi)!;
        Task<string> stdout = p.StandardOutput.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch (InvalidOperationException) { } return (-1, "timed out"); }
        return (p.ExitCode, stdout.Result.Trim());
    }

    private static string SeenAddress()
    {
        var (code, text) = Outside("curl.exe", "-s -m 5 https://1.1.1.1/cdn-cgi/trace", 7000);
        if (code != 0) return "blocked";
        string? line = text.Split('\n').FirstOrDefault(l => l.StartsWith("ip=", StringComparison.Ordinal));
        return line is null ? "no answer" : line[3..].Trim();
    }

    private static bool LookupVia(string server) =>
        Outside("nslookup.exe", $"-timeout=2 -retry=1 example.com {server}", 6000).Output.Contains("Addresses", StringComparison.OrdinalIgnoreCase)
        || Outside("nslookup.exe", $"-timeout=2 -retry=1 example.com {server}", 6000).Output.Contains("93.", StringComparison.Ordinal);

    /// <summary>The hold by itself, with no tunnel: nothing but the local network may leave.</summary>
    private static int HoldTest()
    {
        if (!IsElevated()) { Say("holdtest needs an administrator window"); return 1; }
        string router = NetworkInterface.GetAllNetworkInterfaces()
            .SelectMany(n => n.GetIPProperties().GatewayAddresses).Select(g => g.Address)
            .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork)?.ToString() ?? "192.168.0.1";
        string before = SeenAddress();
        Say($"before: the internet sees {(before is "blocked" or "no answer" ? before : "this PC's ordinary address")}; lookup through the router {(LookupVia(router) ? "works" : "fails")}");
        bool ok;
        using (var adapter = WintunAdapter.Create())
        using (var hold = new TrafficHold())
        {
            hold.Enable(adapter.Luid, Environment.ProcessPath!);
            Say("hold on (no tunnel)");
            string during = SeenAddress();
            bool dns = LookupVia(router);
            bool lan = PingAll(IPAddress.Parse(router), 2).Received > 0;
            Say($"during: internet from another program: {during}; lookup through the router: {(dns ? "ANSWERED (leak)" : "blocked")}; ping the router: {(lan ? "answers" : "no answer")}");
            ok = during == "blocked" && !dns && lan;
            hold.Disable();
        }
        string after = SeenAddress();
        Say($"after: internet {(after == before ? "back as before" : after)}");
        ok = ok && after == before && before != "blocked";
        Say(ok ? "HOLDTEST OK" : "HOLDTEST FAILED");
        return ok ? 0 : 1;
    }

    /// <summary>The service's controller, run from here: connect, check for leaks, change region in place, disconnect.</summary>
    private static int RunController(string[] args)
    {
        if (!IsElevated()) { Say("run needs an administrator window"); return 1; }
        string first = Option(args, "--region") ?? "us-west-1";
        string second = Option(args, "--then") ?? "jp1";
        string router = "192.168.0.1";
        string home = SeenAddress();
        using var controller = new Lattice.Core.VpnController(DataDir, Environment.ProcessPath!, m => Say("  " + m));

        bool WaitFor(string state, int seconds)
        {
            var until = DateTime.UtcNow.AddSeconds(seconds);
            while (DateTime.UtcNow < until)
            {
                var st = controller.Status();
                if (st.State == state) return true;
                if (st.State == "error") return false;
                Thread.Sleep(100);
            }
            return false;
        }

        var t0 = DateTime.UtcNow;
        controller.Connect(first);
        if (!WaitFor("connected", 45)) { Say($"RUN FAILED: {controller.Status().State} {controller.Status().Message}"); return 1; }
        Say($"connected to {first} in {(DateTime.UtcNow - t0).TotalSeconds:F1} s");
        Thread.Sleep(1500);
        string seen1 = SeenAddress();
        bool leak1 = LookupVia(router);
        bool viaTunnel = LookupVia("9.9.9.9");
        var st1 = controller.Status();
        Say($"{first}: the internet sees {(seen1 == st1.Exit ? "the gateway's address" : seen1 == home ? "THIS PC'S OWN ADDRESS (leak)" : seen1)}; lookup through the router: {(leak1 ? "ANSWERED (leak)" : "blocked")}; lookup through the tunnel: {(viaTunnel ? "works" : "FAILS")}");
        try
        {
            var v6 = Outside("curl.exe", "-s -m 5 -6 https://[2606:4700:4700::1111]/cdn-cgi/trace", 7000);
            string? ip6 = v6.Output.Split('\n').FirstOrDefault(l => l.StartsWith("ip=", StringComparison.Ordinal));
            Say($"{first}: IPv6 through the tunnel: {(v6.Code == 0 && ip6 is not null ? "works" : "no answer")}");
        }
        catch (Exception e) { Say($"IPv6 check failed: {e.Message}"); }

        // change region in place, sampling what the outside world sees the whole time
        var samples = new List<string>();
        using var stop = new CancellationTokenSource();
        var sampler = Task.Run(() => { while (!stop.IsCancellationRequested) { samples.Add(SeenAddress()); } });
        Thread.Sleep(1000);
        controller.Connect(second);
        Thread.Sleep(300);
        bool moved = WaitFor("connected", 45);
        Thread.Sleep(2500);
        stop.Cancel(); sampler.Wait(10000);
        var st2 = controller.Status();
        string Name(string a) => a == st1.Exit ? first : a == st2.Exit ? second : a == home ? "HOME" : a;
        var sequence = new List<string>();
        foreach (string a in samples.Select(Name)) if (sequence.Count == 0 || sequence[^1] != a) sequence.Add(a);
        Say($"region change {first} -> {second}: {(moved ? "connected" : "FAILED")}; the outside world saw: {string.Join(", ", sequence)}");
        bool leak2 = sequence.Contains("HOME");

        Thread.Sleep(4000);
        var st3 = controller.Status();
        Say($"status: {st3.State}, region {st3.Region}, suite {st3.Suite}, latency {st3.LatencyMs} ms, down {st3.BytesIn} up {st3.BytesOut}, held {st3.TrafficHeld}");
        controller.Disconnect();
        bool off = WaitFor("off", 15);
        Thread.Sleep(500);
        string after = SeenAddress();
        bool adapterGone = NetworkInterface.GetAllNetworkInterfaces().All(n => n.Name != WintunAdapter.AdapterName);
        Say($"disconnected: {(off ? "yes" : "NO")}; adapter removed: {adapterGone}; the internet sees {(after == home ? "this PC's ordinary address again" : after)}");
        bool ok = seen1 == st1.Exit && !leak1 && viaTunnel && moved && !leak2 && off && adapterGone && after == home;
        Say(ok ? "RUN OK" : "RUN FAILED");
        return ok ? 0 : 1;
    }

    // ---- first live test, run by the account holder in a visible window ----

    private static async Task<int> FirstRun()
    {
        try { Console.Title = "Lattice VPN for Windows: first live test"; } catch (IOException) { }
        Console.WriteLine();
        Console.WriteLine("  Lattice VPN for Windows: first live test");
        Console.WriteLine("  ----------------------------------------");
        Console.WriteLine("  Opened by Claude as part of the Windows build you asked for.");
        Console.WriteLine();
        Console.WriteLine("  1. Sign in     You type or paste your Lattice account number here. It is hidden");
        Console.WriteLine("                 as you type, checked with api.latticevpn.ai, and saved on this PC");
        Console.WriteLine("                 protected by Windows. It is not shown to Claude or written to a log.");
        Console.WriteLine("  2. Enroll      This PC gets its own key and certificate. You are asked first.");
        Console.WriteLine("  3. Test        A 45 second connection to a gateway, with two key changes.");
        Console.WriteLine("                 Nothing about this PC's network or routing is changed.");
        Console.WriteLine();
        Console.WriteLine("  To stop at any point, close this window.");
        Console.WriteLine();

        int result = 1;
        try
        {
            var store = new IdentityStore(DataDir);
            using var api = new AccountApi();
            var enroller = new Cnsa2Enroller(store, api);

            // 1. sign in (skipped if an account is already saved and still valid)
            AccountStatus? status = null;
            if (store.AccountNumber() is { } saved)
            {
                try { status = await api.FetchAccountAsync(saved); Say("already signed in on this PC"); }
                catch (AccountException e) when (e.Kind == AccountErrorKind.Unauthorized) { store.ClearAccountNumber(); }
            }
            for (int attempt = 0; status is null && attempt < 3; attempt++)
            {
                string number = ReadMasked("  Account number: ");
                if (!AccountNumber.IsComplete(number))
                {
                    Console.WriteLine($"  That has {AccountNumber.Normalize(number).Length} of the {AccountNumber.Length} characters. Try again.");
                    continue;
                }
                try
                {
                    status = await api.FetchAccountAsync(number);
                    store.SaveAccountNumber(number);
                    Say("account number accepted and saved, protected by Windows");
                }
                catch (AccountException e) when (e.Kind == AccountErrorKind.Unauthorized) { Console.WriteLine("  " + e.Message); }
            }
            if (status is null) { Say("FIRSTRUN STOPPED: no valid account number"); return Finish(1); }
            Describe(status);
            if (!status.IsActive) { Say("FIRSTRUN STOPPED: the subscription is not active"); return Finish(1); }

            // 2. enroll (asks first, unless this PC already holds a valid certificate)
            if (enroller.NeedsEnrollment(DateTimeOffset.UtcNow))
            {
                Console.WriteLine();
                Console.WriteLine($"  Your plan allows {status.DeviceLimit} device(s). Enrolling adds this PC as one of them.");
                Console.WriteLine("  If that many are already enrolled, the one that has gone longest without");
                Console.WriteLine("  connecting is removed to make room. It enrolls itself again the next time it");
                Console.WriteLine("  connects, which then removes another, so do not go over the limit for long.");
                Console.WriteLine("  You can take this PC off the account again afterwards.");
                Console.WriteLine();
                Console.Write("  Type YES to enroll this PC, or anything else to stop: ");
                string answer = (Console.ReadLine() ?? "").Trim();
                if (!string.Equals(answer, "YES", StringComparison.OrdinalIgnoreCase))
                {
                    Say("FIRSTRUN STOPPED: enrollment declined; nothing was changed on the account");
                    return Finish(1);
                }
                EnrollmentState state = await enroller.EnrollAsync(store.AccountNumber()!);
                Say($"enrolled: device {state.Uid}, certificate valid until {DateTimeOffset.FromUnixTimeSeconds(state.NotAfterUnix):u}");
                Say("checked: root is the pinned Lattice root; certificate carries this PC's own key");
                Say($"gateways offered: {string.Join(", ", state.Gateways.Select(g => g.Id))}");
            }
            else Say("this PC is already enrolled with a valid certificate");

            // 3. test
            Console.WriteLine();
            result = Handshake(new[] { "handshake", "--seconds", "45", "--rekey", "20" });
            Say(result == 0 ? "FIRSTRUN OK" : "FIRSTRUN FAILED at the connection test");
        }
        catch (Exception e) when (e is AccountException or EnrollmentException or LatticeTunnelException)
        {
            Say($"FIRSTRUN FAILED: {e.Message}");
        }
        catch (Exception e)
        {
            Say($"FIRSTRUN FAILED ({e.GetType().Name}): {e.Message}");
        }
        return Finish(result);
    }

    private static int Finish(int code)
    {
        Console.WriteLine();
        Console.WriteLine("  Done. Claude reads the result from the log. Press Enter to close this window.");
        try { Console.ReadLine(); } catch (IOException) { }
        return code;
    }

    // ---- selftest ----

    private static int SelfTest()
    {
        Say($"library: {DeviceKey.OpenSslVersion}");
        byte[] key = DeviceKey.Generate();
        byte[] request = DeviceKey.CertificateRequest(key, "lattice-device");
        Say($"device key: ML-DSA-87 made ({key.Length} bytes as PKCS#8); certificate request {request.Length} bytes");
        Say($"root pinned: SHA-384 {LatticeRoot.Sha384[..16]}...");

        if (!IsElevated())
        {
            Say("adapter: skipped (not running as administrator)");
            Say("SELFTEST OK (without adapter)");
            return 0;
        }
        using (var adapter = WintunAdapter.Create())
        using (var network = new TunnelNetwork(adapter.Luid))
        {
            Say($"adapter: created \"{WintunAdapter.AdapterName}\", driver {WintunAdapter.DriverVersion}, interface index {network.InterfaceIndex}");
            // 198.18.0.0/15 is reserved for testing (RFC 2544) and routes nowhere.
            network.AddAddress(IPAddress.Parse("198.18.77.2"), 24);
            network.ConfigureInterface(AddressFamily.InterNetwork, 1400, 5);
            network.AddRoute(IPAddress.Parse("198.19.77.0"), 24);
            network.SetDns(new[] { IPAddress.Parse("198.18.77.1") });
            using WintunSession session = adapter.StartSession();
            Thread.Sleep(1500);

            NetworkInterface? nic = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.Name == WintunAdapter.AdapterName);
            if (nic is null) { Say("adapter: NOT visible to Windows"); return 1; }
            IPInterfaceProperties props = nic.GetIPProperties();
            string addresses = string.Join(", ", props.UnicastAddresses.Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork).Select(a => $"{a.Address}/{a.PrefixLength}"));
            string dns = string.Join(", ", props.DnsAddresses.Select(a => a.ToString()));
            // The IP-layer MTU, read back through the API that set it. (.NET's own
            // property reports the link-layer size, which for Wintun is always 65535.)
            var (mtu, metric) = network.ReadInterface(AddressFamily.InterNetwork);
            Say($"adapter: status {nic.OperationalStatus}, address {addresses}, MTU {mtu}, metric {metric}, DNS {dns}");
            PhysicalRoute testRoute = TunnelNetwork.FindRoute(IPAddress.Parse("198.19.77.9"));
            Say($"adapter: test route {(testRoute.InterfaceLuid == adapter.Luid ? "goes into the adapter" : "DOES NOT go into the adapter")}");

            // Windows sends its own traffic into a new adapter; reading one packet proves the ring works.
            int seen = 0;
            for (int i = 0; i < 20 && seen == 0; i++)
            {
                while (session.TryReceive(out byte[] packet)) seen++;
                if (seen == 0) session.ReadWaitHandle.WaitOne(200);
            }
            Say($"adapter: read {seen} packet(s) from Windows");
            bool ok = addresses.Contains("198.18.77.2/24") && mtu == 1400 && dns.Contains("198.18.77.1") && testRoute.InterfaceLuid == adapter.Luid;
            if (!ok) { Say("SELFTEST FAILED: adapter settings did not take"); return 1; }
        }
        Thread.Sleep(500);
        bool gone = NetworkInterface.GetAllNetworkInterfaces().All(n => n.Name != WintunAdapter.AdapterName);
        Say($"adapter: {(gone ? "removed cleanly" : "STILL PRESENT after close")}");
        Say(gone ? "SELFTEST OK" : "SELFTEST FAILED");
        return gone ? 0 : 1;
    }

    // ---- account ----

    private static string ReadMasked(string prompt)
    {
        Console.Write(prompt);
        var sb = new StringBuilder();
        while (true)
        {
            ConsoleKeyInfo k = Console.ReadKey(intercept: true);
            if (k.Key == ConsoleKey.Enter) break;
            if (k.Key == ConsoleKey.Backspace) { if (sb.Length > 0) { sb.Length--; Console.Write("\b \b"); } continue; }
            if (!char.IsControl(k.KeyChar)) { sb.Append(k.KeyChar); Console.Write('*'); }
        }
        Console.WriteLine();
        return sb.ToString();
    }

    private static string SavedAccount(IdentityStore store) =>
        store.AccountNumber() ?? throw new AccountException("No account saved yet. Run: latticeprobe signin");

    private static void Describe(AccountStatus a)
    {
        Say(a.IsActive
            ? $"account: active, plan \"{a.Tier}\", paid through {a.ActiveUntil}, {a.DeviceCount} of {a.DeviceLimit} device slots in use"
            : "account: recognized, but no active subscription");
    }

    private static async Task<int> SignIn()
    {
        var store = new IdentityStore(DataDir);
        string number = ReadMasked("Lattice account number (hidden as you type, paste works): ");
        if (!AccountNumber.IsComplete(number))
        {
            Say($"That is not a complete account number ({AccountNumber.Normalize(number).Length} of {AccountNumber.Length} characters).");
            return 1;
        }
        using var api = new AccountApi();
        AccountStatus status = await api.FetchAccountAsync(number);
        store.SaveAccountNumber(number);
        Say("account number accepted and saved (protected by Windows for this user)");
        Describe(status);
        return 0;
    }

    private static async Task<int> Status()
    {
        var store = new IdentityStore(DataDir);
        using var api = new AccountApi();
        Describe(await api.FetchAccountAsync(SavedAccount(store)));
        return 0;
    }

    private static async Task<int> Enroll()
    {
        var store = new IdentityStore(DataDir);
        using var api = new AccountApi();
        var enroller = new Cnsa2Enroller(store, api);
        string account = SavedAccount(store);
        bool renewing = store.Certificate() is not null;
        EnrollmentState state = await enroller.EnrollAsync(account);
        Say($"{(renewing ? "certificate renewed" : "enrolled")}: device {state.Uid}, certificate valid until {DateTimeOffset.FromUnixTimeSeconds(state.NotAfterUnix):u}");
        Say("checked: root is the pinned Lattice root; certificate carries this PC's own key");
        Say($"gateways offered: {string.Join(", ", state.Gateways.Select(g => g.Id))}");
        return 0;
    }

    private static int Gateways()
    {
        var enroller = new Cnsa2Enroller(new IdentityStore(DataDir), new AccountApi());
        foreach (Cnsa2Gateway g in enroller.Gateways()) Say($"{g.Id,-14} {g.Host}:{g.Port}  certificate name {g.Name}");
        return 0;
    }

    private static async Task<int> SignOut()
    {
        var store = new IdentityStore(DataDir);
        using var api = new AccountApi();
        var enroller = new Cnsa2Enroller(store, api);
        await enroller.ForgetAsync(SavedAccount(store));
        Say("this PC was removed from the account; its key, certificate and saved account number are erased");
        return 0;
    }

    // ---- tunnel ----

    private sealed record Target(Cnsa2Gateway Gateway, IPEndPoint EndPoint, Cnsa2Enroller Enroller);

    private static Target Resolve(string[] args)
    {
        var enroller = new Cnsa2Enroller(new IdentityStore(DataDir), new AccountApi());
        if (enroller.NeedsEnrollment(DateTimeOffset.UtcNow)) throw new EnrollmentException("This PC is not enrolled. Run: latticeprobe enroll");
        string? region = Option(args, "--region");
        Cnsa2Gateway gateway = enroller.Choose(region) ?? throw new EnrollmentException($"No gateway for region \"{region}\". Run: latticeprobe gateways");
        IPAddress address = Dns.GetHostAddresses(gateway.Host).FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork)
            ?? throw new LatticeTunnelException($"{gateway.Host} has no IPv4 address");
        return new Target(gateway, new IPEndPoint(address, gateway.Port), enroller);
    }

    private static bool WaitForConnection(TunnelEngine engine, int seconds)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < deadline)
        {
            TunnelState s = engine.State;
            if (s.Kind == TunnelStateKind.Connected) return true;
            if (s.Kind is TunnelStateKind.Failed or TunnelStateKind.Closed) return false;
            Thread.Sleep(50);
        }
        return false;
    }

    private static void Report(TunnelEngine engine)
    {
        TunnelSettings s = engine.Settings;
        Say($"suite: {engine.Suite}");
        Say($"assigned: {s.Address} mask {s.Netmask}{(s.Address6.Length > 0 ? $", {s.Address6}/{s.Prefix6}" : "")}, gateway {s.Gateway}, MTU {s.Mtu}");
        Say($"pushed: DNS [{string.Join(", ", s.Dns)}], all traffic {(s.RedirectGateway ? "yes" : "no")}, routes [{string.Join("; ", s.Routes)}], keepalive {s.PingInterval}s, give up after {s.PingRestart}s");
    }

    private static int Handshake(string[] args)
    {
        Target t = Resolve(args);
        int seconds = int.TryParse(Option(args, "--seconds"), out int n) ? n : 5;
        double rekey = double.TryParse(Option(args, "--rekey"), out double r) ? r : Cnsa2Enroller.RekeySeconds;

        using TunnelIdentity identity = t.Enroller.IdentityFor(t.Gateway);
        // --tcp: reach the gateway's TCP 443 listener, the path for networks that block UDP.
        // --tcp-host <address>: the gateway's second address, where its TCP listener answers.
        string? tcpHost = Option(args, "--tcp-host");
        bool tcp = args.Contains("--tcp") || tcpHost is not null;
        var tcpTo = new System.Net.IPEndPoint(tcpHost is null ? t.EndPoint.Address : System.Net.IPAddress.Parse(tcpHost), 443);
        using var engine = new TunnelEngine(identity, tcp ? tcpTo : t.EndPoint, rekey, null, tcp);
        if (tcp) Say($"using TCP, {tcpTo}");
        engine.Log += m => Say($"  session: {m}");
        engine.StateChanged += s => Say($"  state: {s}");

        Say($"connecting to {t.Gateway.Id} ({t.EndPoint}), expecting certificate name {t.Gateway.Name}");
        var started = DateTime.UtcNow;
        engine.Start();
        if (!WaitForConnection(engine, 35))
        {
            Say($"HANDSHAKE FAILED: {engine.State}");
            return 1;
        }
        Say($"connected in {(DateTime.UtcNow - started).TotalMilliseconds:F0} ms");
        Report(engine);

        Say($"holding the session for {seconds} s (re-key every {rekey} s)");
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until && engine.State.Kind == TunnelStateKind.Connected) Thread.Sleep(200);
        bool alive = engine.State.Kind == TunnelStateKind.Connected;
        Say($"after {seconds} s: {engine.State}, {engine.RekeyCount} re-key(s)");
        engine.Stop();
        Say(alive ? "HANDSHAKE OK" : "HANDSHAKE FAILED: session did not stay up");
        return alive ? 0 : 1;
    }

    private static (int Sent, int Received, long AverageMs) PingAll(IPAddress target, int count)
    {
        using var ping = new Ping();
        int received = 0; long total = 0;
        for (int i = 0; i < count; i++)
        {
            try
            {
                PingReply reply = ping.Send(target, 2000);
                if (reply.Status == IPStatus.Success) { received++; total += reply.RoundtripTime; }
            }
            catch (PingException) { }
            Thread.Sleep(250);
        }
        return (count, received, received > 0 ? total / received : 0);
    }

    private static int Connect(string[] args)
    {
        if (!IsElevated()) { Say("connect needs an administrator window (it creates a network adapter)"); return 1; }
        Target t = Resolve(args);
        int seconds = int.TryParse(Option(args, "--seconds"), out int n) ? n : 30;
        double rekey = double.TryParse(Option(args, "--rekey"), out double r) ? r : Cnsa2Enroller.RekeySeconds;
        bool full = args.Contains("--full");

        using TunnelIdentity identity = t.Enroller.IdentityFor(t.Gateway);
        PhysicalRoute physical = TunnelNetwork.FindRoute(t.EndPoint.Address);
        // --tcp: reach the gateway's TCP 443 listener, the path for networks that block UDP.
        // --tcp-host <address>: the gateway's second address, where its TCP listener answers.
        // Do not combine with --full yet: only the first address is kept out of the tunnel.
        string? tcpHost = Option(args, "--tcp-host");
        bool tcp = args.Contains("--tcp") || tcpHost is not null;
        var tcpTo = new System.Net.IPEndPoint(tcpHost is null ? t.EndPoint.Address : System.Net.IPAddress.Parse(tcpHost), 443);
        if (tcp && full && tcpHost is not null) { Say("--tcp-host cannot be used with --full yet"); return 1; }
        using var engine = new TunnelEngine(identity, tcp ? tcpTo : t.EndPoint, rekey, physical.SourceAddress, tcp);
        if (tcp) Say($"using TCP, {tcpTo}");
        engine.Log += m => Say($"  session: {m}");
        engine.StateChanged += s => Say($"  state: {s}");

        Say($"connecting to {t.Gateway.Id} ({t.EndPoint}) from {physical.SourceAddress}");
        engine.Start();
        if (!WaitForConnection(engine, 35)) { Say($"CONNECT FAILED: {engine.State}"); return 1; }
        Report(engine);
        TunnelSettings s = engine.Settings;

        int result = 1;
        using (var adapter = WintunAdapter.Create())
        using (var network = new TunnelNetwork(adapter.Luid))
        using (WintunSession tun = adapter.StartSession())
        {
            try
            {
                network.AddAddress(IPAddress.Parse(s.Address), TunnelNetwork.PrefixLength(IPAddress.Parse(s.Netmask)));
                network.ConfigureInterface(AddressFamily.InterNetwork, s.Mtu, 5);
                if (s.Address6.Length > 0)
                {
                    network.AddAddress(IPAddress.Parse(s.Address6), s.Prefix6);
                    network.ConfigureInterface(AddressFamily.InterNetworkV6, s.Mtu, 5);
                }
                if (full)
                {
                    network.AddGatewayBypass(t.EndPoint.Address);
                    network.AddDefaultRoutes(ipv4: true, ipv6: s.Address6.Length > 0);
                    network.SetDns(s.Dns.Select(IPAddress.Parse).ToList());
                    Say("all traffic now goes through the tunnel; DNS set to the gateway's servers");
                }
                else
                {
                    Say("test mode: only the tunnel's own subnet is routed into it; the rest of this PC's traffic is untouched");
                }
                engine.AttachTun(tun);
                Thread.Sleep(1000);

                IPAddress inside = IPAddress.Parse(s.Gateway.Length > 0 ? s.Gateway : s.Address);
                var until = DateTime.UtcNow.AddSeconds(seconds);
                int sent = 0, received = 0; long worst = 0;
                while (DateTime.UtcNow < until && engine.State.Kind == TunnelStateKind.Connected)
                {
                    var (c, ok, avg) = PingAll(inside, 4);
                    sent += c; received += ok; worst = Math.Max(worst, avg);
                }
                Say($"ping {inside} through the tunnel: {received} of {sent} answered, slowest average {worst} ms, {engine.RekeyCount} re-key(s)");
                if (full)
                {
                    var (c, ok, avg) = PingAll(IPAddress.Parse("1.1.1.1"), 4);
                    Say($"ping 1.1.1.1 through the tunnel: {ok} of {c} answered, average {avg} ms");
                    try { Say($"name lookup through the tunnel: latticevpn.ai -> {Dns.GetHostAddresses("latticevpn.ai").FirstOrDefault()}"); }
                    catch (SocketException e) { Say($"name lookup through the tunnel FAILED: {e.Message}"); }
                }
                Say($"traffic: {engine.PacketsOut} packets / {engine.BytesOut} bytes out, {engine.PacketsIn} packets / {engine.BytesIn} bytes in");
                result = received > 0 && received >= sent * 9 / 10 && engine.State.Kind == TunnelStateKind.Connected ? 0 : 1;
            }
            finally
            {
                engine.Stop(); // stops the adapter reader before the adapter session ends
            }
        }
        Say(result == 0 ? "CONNECT OK" : "CONNECT FAILED");
        return result;
    }
}
