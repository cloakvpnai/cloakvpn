using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Lattice.App;

/// <summary>What the service reports. Mirrors VpnStatus in the service.</summary>
public sealed class Status
{
    [JsonPropertyName("state")] public string State { get; set; } = "off";
    [JsonPropertyName("message")] public string Message { get; set; } = "";
    [JsonPropertyName("region")] public string Region { get; set; } = "";
    [JsonPropertyName("suite")] public string Suite { get; set; } = "";
    [JsonPropertyName("address")] public string Address { get; set; } = "";
    [JsonPropertyName("address6")] public string Address6 { get; set; } = "";
    [JsonPropertyName("exit")] public string Exit { get; set; } = "";
    [JsonPropertyName("since")] public long Since { get; set; }
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
    [JsonPropertyName("cert_until")] public long CertificateUntil { get; set; }
    [JsonPropertyName("regions")] public List<string> Regions { get; set; } = new();
    [JsonPropertyName("version")] public string Version { get; set; } = "";
    [JsonPropertyName("library")] public string Library { get; set; } = "";

    public bool Connected => State == "connected";
    public bool Busy => State is "connecting" or "reconnecting";
}

public sealed record Reply(bool Ok, string Error, Status? Status, bool ServiceReachable);

/// <summary>Talks to the Lattice service over its local pipe: one line of JSON out, one line back.</summary>
public sealed class ServiceClient : IDisposable
{
    private const string PipeName = "LatticeVPN";
    private readonly SemaphoreSlim _one = new(1, 1);
    private NamedPipeClientStream? _pipe;
    private StreamReader? _reader;
    private StreamWriter? _writer;

    private sealed class Wire
    {
        [JsonPropertyName("ok")] public bool Ok { get; set; }
        [JsonPropertyName("error")] public string? Error { get; set; }
        [JsonPropertyName("status")] public Status? Status { get; set; }
    }

    private void Drop()
    {
        _reader?.Dispose(); _writer?.Dispose(); _pipe?.Dispose();
        _reader = null; _writer = null; _pipe = null;
    }

    public async Task<Reply> SendAsync(string command, string? region = null, string? account = null, int timeoutMs = 4000)
    {
        var request = new Dictionary<string, string> { ["cmd"] = command };
        if (region is not null) request["region"] = region;
        if (account is not null) request["account"] = account;
        string line = JsonSerializer.Serialize(request);

        await _one.WaitAsync().ConfigureAwait(false);
        try
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    using var cts = new CancellationTokenSource(timeoutMs);
                    if (_pipe is null || !_pipe.IsConnected)
                    {
                        Drop();
                        _pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
                        await _pipe.ConnectAsync(800, cts.Token).ConfigureAwait(false);
                        _reader = new StreamReader(_pipe, new UTF8Encoding(false), false, 65536, leaveOpen: true);
                        _writer = new StreamWriter(_pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
                    }
                    await _writer!.WriteLineAsync(line.AsMemory(), cts.Token).ConfigureAwait(false);
                    string? answer = await _reader!.ReadLineAsync(cts.Token).ConfigureAwait(false);
                    if (answer is null) { Drop(); continue; }
                    Wire? wire = JsonSerializer.Deserialize<Wire>(answer);
                    if (wire is null) return new Reply(false, "The service sent a reply the app could not read.", null, true);
                    return new Reply(wire.Ok, wire.Error ?? "", wire.Status, true);
                }
                catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException or JsonException or UnauthorizedAccessException)
                {
                    Drop();
                }
            }
            return new Reply(false, "The Lattice VPN service is not running.", null, false);
        }
        finally { _one.Release(); }
    }

    public void Dispose() { Drop(); _one.Dispose(); }
}
