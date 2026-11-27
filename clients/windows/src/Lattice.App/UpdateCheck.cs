using System;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Lattice.App;

/// <summary>
/// Tells the person when a newer Lattice VPN for Windows exists. That is all it does.
///
/// It reads one small public file that holds a version number. It sends no account
/// number, no device name and no identifier. It never downloads or runs anything, so
/// the worst a tampered reply can do is show the notice when no update exists.
/// "Get the update" hands over to <see cref="Updater"/>, which trusts only files signed
/// with the Lattice release key, and falls back to the download page below.
/// </summary>
public static class UpdateCheck
{
    public const string VersionUrl = "https://latticevpn.ai/windows/version.json";
    public const string DownloadPage = "https://latticevpn.ai/download/windows";

    /// <param name="Latest">Newest released version.</param>
    /// <param name="Required">True when this copy is older than the oldest version still supported.</param>
    public sealed record Result(Version Latest, bool Required);

    /// <summary>Parses the file. Returns null when it is not understood or this copy is current.</summary>
    public static Result? Read(string json, Version current)
    {
        try
        {
            using JsonDocument doc = JsonDocument.Parse(json);
            JsonElement root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!TryVersion(root, "version", out Version? latest) || latest is null) return null;
            TryVersion(root, "minimum", out Version? minimum);
            if (latest <= current) return null;
            return new Result(latest, minimum is not null && current < minimum);
        }
        catch (JsonException) { return null; }
    }

    private static bool TryVersion(JsonElement root, string name, out Version? version)
    {
        version = null;
        if (!root.TryGetProperty(name, out JsonElement e) || e.ValueKind != JsonValueKind.String) return false;
        string text = e.GetString() ?? "";
        // Three numbers and nothing else, such as 2.0.1.
        if (text.Length is 0 or > 20 || !Version.TryParse(text, out Version? parsed) || parsed.Build < 0 || parsed.Revision >= 0) return false;
        version = parsed;
        return true;
    }

    /// <summary>One request, no redirects, at most 4 KB read. Any failure is "no update".</summary>
    public static async Task<Result?> CheckAsync(Version current, CancellationToken ct = default)
    {
        try
        {
            using var handler = new SocketsHttpHandler { AllowAutoRedirect = false, UseCookies = false, ConnectTimeout = TimeSpan.FromSeconds(10) };
            using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 4096 };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("LatticeVPN-Windows");
            using HttpResponseMessage response = await http.GetAsync(VersionUrl, ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode) return null;
            return Read(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false), current);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or OperationCanceledException) { return null; }
    }
}
