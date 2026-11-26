using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Lattice.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace Lattice.Service;

public static class Program
{
    public const string ServiceName = "LatticeVPN";
    public const string PipeName = "LatticeVPN";

    public static void Main(string[] args)
    {
        // Run by the installer, as the system, when Lattice VPN is removed for good
        // (not when it is upgraded): see LatticeVPN.wxs.
        if (args.Length == 1 && args[0] == "--forget") { Worker.Forget(); return; }

        HostApplicationBuilder builder = Host.CreateApplicationBuilder(args);
        builder.Services.AddWindowsService(o => o.ServiceName = ServiceName);
        builder.Services.AddHostedService<Worker>();
        builder.Build().Run();
    }
}

/// <summary>A small log file. Never holds the account number or key material.</summary>
internal sealed class FileLog
{
    private readonly string _path;
    private readonly object _gate = new();

    public FileLog(string directory)
    {
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, "service.log");
    }

    public void Write(string message)
    {
        lock (_gate)
        {
            try
            {
                var info = new FileInfo(_path);
                if (info.Exists && info.Length > 1_000_000) File.Move(_path, _path + ".old", overwrite: true);
                File.AppendAllText(_path, $"{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss}Z  {message}{Environment.NewLine}");
            }
            catch (IOException) { }
        }
    }
}

public sealed class Worker : BackgroundService
{
    private static readonly string DataDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Lattice VPN");

    /// <summary>Only the system and administrators may read the device key, the certificate and the logs.</summary>
    private static void LockDown(string directory)
    {
        var info = Directory.CreateDirectory(directory);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        const InheritanceFlags inherit = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        foreach (WellKnownSidType who in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(who, null), FileSystemRights.FullControl, inherit, PropagationFlags.None, AccessControlType.Allow));
        info.SetAccessControl(security);
    }

    /// <summary>People signed in at this PC may use the pipe. Nothing from the network may.</summary>
    private static PipeSecurity PipeAccess()
    {
        var s = new PipeSecurity();
        s.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
        s.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        s.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        s.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.InteractiveSid, null), PipeAccessRights.ReadWrite, AccessControlType.Allow));
        return s;
    }

    /// <summary>
    /// Uninstall: frees this PC's place on the account, so it does not go on counting
    /// against the device limit, then erases the device key, the certificate, the stored
    /// account number and the logs. The server is given 15 seconds; if it cannot be
    /// reached the local data is erased all the same, and the device can be removed
    /// from the account in any other Lattice app.
    /// </summary>
    public static void Forget()
    {
        if (!Directory.Exists(DataDir)) return;
        try
        {
            var log = new FileLog(Path.Combine(DataDir, "logs"));
            log.Write("uninstall: removing this PC from the account");
            using (var controller = new VpnController(DataDir, Environment.ProcessPath!, log.Write))
            {
                try { controller.SignOutAsync().Wait(TimeSpan.FromSeconds(15)); }
                catch (AggregateException) { /* no network, or the server said no: carry on and erase */ }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException) { }
        try { Directory.Delete(DataDir, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        LockDown(DataDir);
        var log = new FileLog(Path.Combine(DataDir, "logs"));
        log.Write("service starting");
        using var controller = new VpnController(DataDir, Environment.ProcessPath!, log.Write);
        _ = controller.RefreshAccountAsync();

        var clients = new List<Task>();
        try
        {
            while (!stop.IsCancellationRequested)
            {
                NamedPipeServerStream pipe = NamedPipeServerStreamAcl.Create(
                    Program.PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 4096, 65536, PipeAccess());
                try { await pipe.WaitForConnectionAsync(stop).ConfigureAwait(false); }
                catch (OperationCanceledException) { pipe.Dispose(); break; }
                clients.Add(Task.Run(() => ServeAsync(pipe, controller, log, stop), CancellationToken.None));
                clients.RemoveAll(t => t.IsCompleted);
            }
        }
        finally
        {
            log.Write("service stopping");
            controller.Disconnect();
        }
    }

    private static async Task ServeAsync(NamedPipeServerStream pipe, VpnController controller, FileLog log, CancellationToken stop)
    {
        using (pipe)
        {
            try
            {
                using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 4096, leaveOpen: true);
                using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
                while (!stop.IsCancellationRequested && pipe.IsConnected)
                {
                    string? line = await reader.ReadLineAsync(stop).ConfigureAwait(false);
                    if (line is null) break;
                    if (line.Length > 4096) break; // nothing legitimate is this long
                    string reply = await HandleAsync(line, controller).ConfigureAwait(false);
                    await writer.WriteLineAsync(reply).ConfigureAwait(false);
                }
            }
            catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
            catch (Exception e) { log.Write($"pipe client error: {e.GetType().Name}"); }
        }
    }

    private static string Error(string message) => JsonSerializer.Serialize(new Dictionary<string, object> { ["ok"] = false, ["error"] = message });

    private static string Ok(VpnController controller) =>
        JsonSerializer.Serialize(new Dictionary<string, object> { ["ok"] = true, ["status"] = controller.Status() });

    /// <summary>One request, one reply, both a single line of JSON.</summary>
    private static async Task<string> HandleAsync(string line, VpnController controller)
    {
        string command, region = "", account = "";
        try
        {
            using JsonDocument doc = JsonDocument.Parse(line);
            JsonElement root = doc.RootElement;
            command = root.GetProperty("cmd").GetString() ?? "";
            if (root.TryGetProperty("region", out JsonElement r) && r.ValueKind == JsonValueKind.String) region = r.GetString() ?? "";
            if (root.TryGetProperty("account", out JsonElement a) && a.ValueKind == JsonValueKind.String) account = a.GetString() ?? "";
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException) { return Error("bad request"); }

        // Region names are short identifiers such as "us-west-1".
        if (region.Length > 32 || region.AsSpan().IndexOfAnyExcept("abcdefghijklmnopqrstuvwxyz0123456789-") >= 0) return Error("bad region");

        switch (command)
        {
            case "status":
                return Ok(controller);
            case "connect":
                controller.Connect(region.Length > 0 ? region : null);
                return Ok(controller);
            case "disconnect":
                controller.Disconnect();
                return Ok(controller);
            case "signin":
            {
                string error = await controller.SignInAsync(account).ConfigureAwait(false);
                return error.Length > 0 ? Error(error) : Ok(controller);
            }
            case "signout":
                await controller.SignOutAsync().ConfigureAwait(false);
                return Ok(controller);
            case "account":
            {
                string error = await controller.RefreshAccountAsync().ConfigureAwait(false);
                return error.Length > 0 ? Error(error) : Ok(controller);
            }
            default:
                return Error("unknown command");
        }
    }
}
