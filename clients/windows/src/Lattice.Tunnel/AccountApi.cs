using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Authentication;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Lattice.Api;

// The central Lattice account API. Same contract as
// clients/android/.../data/AccountClient.kt and server/api/internal/http/cnsa2.go.

public enum AccountErrorKind
{
    /// <summary>The account number was not recognized (HTTP 401).</summary>
    Unauthorized,
    /// <summary>Recognized, but the subscription is not active (HTTP 402).</summary>
    NoSubscription,
    /// <summary>Every device slot for this subscription is in use (HTTP 403).</summary>
    DeviceLimit,
    /// <summary>The server could not be reached at all.</summary>
    Network,
    Other,
}

public sealed class AccountException : Exception
{
    public AccountErrorKind Kind { get; }
    public AccountException(string message, AccountErrorKind kind = AccountErrorKind.Other) : base(message) { Kind = kind; }
}

public static class AccountNumber
{
    /// <summary>Symbol count of a complete account number.</summary>
    public const int Length = 25;

    // Crockford base-32: no I, L, O or U. Must match server/api/internal/account/account.go.
    private const string Crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    /// <summary>Bare symbols: uppercase, with hyphens, spaces and anything outside the alphabet removed.</summary>
    public static string Normalize(string input)
    {
        var sb = new StringBuilder(Length);
        foreach (char c in (input ?? "").ToUpperInvariant())
            if (Crockford.Contains(c)) sb.Append(c);
        return sb.ToString();
    }

    /// <summary>Display form, five groups of five: "36ASS-06QHX-877TR-8T1D0-6DV38".</summary>
    public static string Format(string input)
    {
        string n = Normalize(input);
        var sb = new StringBuilder(n.Length + n.Length / 5);
        for (int i = 0; i < n.Length; i++)
        {
            if (i > 0 && i % 5 == 0) sb.Append('-');
            sb.Append(n[i]);
        }
        return sb.ToString();
    }

    public static bool IsComplete(string input) => Normalize(input).Length == Length;
}

public sealed record AccountDevice(long Id, string Ip, string CreatedAt);

public sealed record AccountStatus(string Tier, int DeviceLimit, int DeviceCount, string ActiveUntil, IReadOnlyList<AccountDevice> Devices)
{
    public bool IsActive => Tier.Length > 0;
}

/// <summary>One CNSA 2.0 gateway. Name is the name in its certificate, which the tunnel checks.</summary>
/// <param name="TcpHost">IPv4 address where the gateway also accepts the tunnel over TCP, or "" when it has none.</param>
/// <param name="TcpPort">The port for <paramref name="TcpHost"/>, normally 443. 0 when there is none.</param>
public sealed record Cnsa2Gateway(string Id, string Host, int Port, string Name, string TcpHost = "", int TcpPort = 0);

/// <summary>Result of POST /v1/device/cnsa2/enroll. Certificates are DER.</summary>
public sealed record Cnsa2Enrollment(byte[] Certificate, byte[] Issuing, byte[] Root, string NotAfter,
                                     long DeviceId, string DeviceUid, IReadOnlyList<Cnsa2Gateway> Gateways);

public sealed class AccountApi : IDisposable
{
    public const string BaseUrl = "https://api.latticevpn.ai";

    private readonly HttpClient _http;

    /// <param name="handler">Optional transport, for tests or to pin requests to the physical network.</param>
    public AccountApi(HttpMessageHandler? handler = null)
    {
        handler ??= new SocketsHttpHandler
        {
            ConnectTimeout = TimeSpan.FromSeconds(15),
            // The account number travels as a bearer token: never follow a redirect with it.
            AllowAutoRedirect = false,
            UseCookies = false,
            SslOptions = { EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13 },
        };
        _http = new HttpClient(handler) { BaseAddress = new Uri(BaseUrl), Timeout = TimeSpan.FromSeconds(45) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("LatticeVPN-Windows/2.0");
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    public void Dispose() => _http.Dispose();

    /// <summary>GET /v1/account: validates an account number and returns the subscription state.</summary>
    public async Task<AccountStatus> FetchAccountAsync(string accountNumber, CancellationToken ct = default)
    {
        using JsonDocument j = Json(await ExecuteAsync(HttpMethod.Get, "/v1/account", accountNumber, null, ct).ConfigureAwait(false));
        var root = j.RootElement;
        var devices = new List<AccountDevice>();
        if (root.TryGetProperty("devices", out var arr) && arr.ValueKind == JsonValueKind.Array)
            foreach (var d in arr.EnumerateArray())
                devices.Add(new AccountDevice(Int64(d, "id"), Str(d, "ip"), Str(d, "created_at")));
        return new AccountStatus(Str(root, "tier"), (int)Int64(root, "device_limit"), (int)Int64(root, "device_count"),
                                 Str(root, "active_until"), devices);
    }

    /// <summary>
    /// POST /v1/device/cnsa2/enroll: enroll this device, or renew its certificate.
    /// Only the certificate request (public key) is sent.
    /// </summary>
    public async Task<Cnsa2Enrollment> EnrollCnsa2Async(string accountNumber, byte[] requestDer, CancellationToken ct = default)
    {
        string payload = JsonSerializer.Serialize(new Dictionary<string, string> { ["request"] = Convert.ToBase64String(requestDer) });
        using JsonDocument j = Json(await ExecuteAsync(HttpMethod.Post, "/v1/device/cnsa2/enroll", accountNumber, payload, ct).ConfigureAwait(false));
        var root = j.RootElement;
        try
        {
            long id = 0; string uid = "";
            if (root.TryGetProperty("device", out var device) && device.ValueKind == JsonValueKind.Object)
            {
                id = Int64(device, "id");
                uid = Str(device, "uid");
            }
            return new Cnsa2Enrollment(
                Convert.FromBase64String(root.GetProperty("certificate").GetString() ?? ""),
                Convert.FromBase64String(Str(root, "issuing")),
                Convert.FromBase64String(root.GetProperty("root").GetString() ?? ""),
                root.GetProperty("not_after").GetString() ?? "",
                id, uid, ParseGateways(root));
        }
        catch (Exception e) when (e is FormatException or KeyNotFoundException or InvalidOperationException)
        {
            throw new AccountException("The server sent an enrollment reply we couldn't read.");
        }
    }

    /// <summary>GET /v1/cnsa2/gateways: the gateways a signed-in app may use.</summary>
    public async Task<IReadOnlyList<Cnsa2Gateway>> FetchGatewaysAsync(string accountNumber, CancellationToken ct = default)
    {
        using JsonDocument j = Json(await ExecuteAsync(HttpMethod.Get, "/v1/cnsa2/gateways", accountNumber, null, ct).ConfigureAwait(false));
        return ParseGateways(j.RootElement);
    }

    /// <summary>DELETE /v1/device/cnsa2?id=: remove this device. The server revokes its certificates.</summary>
    public async Task RemoveDeviceAsync(string accountNumber, long deviceId, CancellationToken ct = default)
    {
        await ExecuteAsync(HttpMethod.Delete, "/v1/device/cnsa2?id=" + deviceId.ToString(System.Globalization.CultureInfo.InvariantCulture),
                           accountNumber, null, ct).ConfigureAwait(false);
    }

    // ---- internals ----

    private static IReadOnlyList<Cnsa2Gateway> ParseGateways(JsonElement root)
    {
        var list = new List<Cnsa2Gateway>();
        if (root.TryGetProperty("gateways", out var arr) && arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var g in arr.EnumerateArray())
            {
                string host = Str(g, "host"), name = Str(g, "name");
                if (host.Length == 0 || name.Length == 0) continue;
                long port = Int64(g, "port");
                // The TCP way in is optional. Anything odd about it is dropped, never guessed at.
                string tcpHost = Str(g, "tcp_host");
                long tcpPort = Int64(g, "tcp_port");
                bool tcp = tcpPort is > 0 and <= 65535
                    && System.Net.IPAddress.TryParse(tcpHost, out System.Net.IPAddress? parsed)
                    && parsed.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork;
                list.Add(new Cnsa2Gateway(Str(g, "id"), host, port is > 0 and <= 65535 ? (int)port : 1194, name,
                                          tcp ? tcpHost : "", tcp ? (int)tcpPort : 0));
            }
        }
        return list;
    }

    private static string Str(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    private static long Int64(JsonElement e, string name) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out long n) ? n : 0;

    private static JsonDocument Json(string body)
    {
        try { return JsonDocument.Parse(body); }
        catch (JsonException) { throw new AccountException("The server sent a response we couldn't read."); }
    }

    private async Task<string> ExecuteAsync(HttpMethod method, string path, string accountNumber, string? jsonBody, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(method, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", AccountNumber.Format(accountNumber));
        if (jsonBody is not null) request.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, HttpCompletionOption.ResponseContentRead, ct).ConfigureAwait(false);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException && !ct.IsCancellationRequested)
        {
            throw new AccountException("Couldn't reach Lattice. Check your connection and try again.", AccountErrorKind.Network);
        }
        using (response)
        {
            string text = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            if (response.IsSuccessStatusCode) return text;
            throw (int)response.StatusCode switch
            {
                401 => new AccountException("That account number wasn't recognized. Check it and try again.", AccountErrorKind.Unauthorized),
                402 => new AccountException("This subscription isn't active. Renew it at latticevpn.ai to continue.", AccountErrorKind.NoSubscription),
                403 => new AccountException("You've reached your device limit. Remove a device to add this one.", AccountErrorKind.DeviceLimit),
                409 => new AccountException("This device is already registered to a different account."),
                429 => new AccountException("Too many requests. Please try again in a little while."),
                _ => new AccountException($"Lattice server error ({(int)response.StatusCode}). Please try again in a moment."),
            };
        }
    }
}
