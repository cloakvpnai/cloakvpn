using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Lattice.Core;

/// <summary>
/// Remembers the addresses of the few hosts the service talks to (the account
/// API and the gateways). While traffic is held and the tunnel is down, name
/// lookups are blocked on purpose, so the service must already know where to go.
/// The cache is saved to disk; it holds public addresses only.
/// </summary>
public sealed class NameCache
{
    private readonly string _path;
    private readonly object _gate = new();
    private Dictionary<string, string[]> _known = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Set while lookups are known to be blocked: use what is remembered without asking.</summary>
    public volatile bool PreferCache;

    public NameCache(string path)
    {
        _path = path;
        try
        {
            if (File.Exists(path))
                _known = new Dictionary<string, string[]>(
                    JsonSerializer.Deserialize<Dictionary<string, string[]>>(File.ReadAllText(path)) ?? new(), StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception e) when (e is JsonException or IOException) { }
    }

    private IPAddress[] Cached(string host)
    {
        lock (_gate)
            return _known.TryGetValue(host, out string[]? list)
                ? list.Select(s => IPAddress.TryParse(s, out IPAddress? a) ? a : null).Where(a => a is not null).Select(a => a!).ToArray()
                : Array.Empty<IPAddress>();
    }

    /// <summary>Addresses for a host, IPv4 first. Throws if it has never been resolved and cannot be now.</summary>
    public IPAddress[] Resolve(string host)
    {
        if (IPAddress.TryParse(host, out IPAddress? literal)) return new[] { literal };
        IPAddress[] cached = Cached(host);
        if (PreferCache && cached.Length > 0) return cached;
        try
        {
            Task<IPAddress[]> lookup = Dns.GetHostAddressesAsync(host);
            if (lookup.Wait(2500) && lookup.Result.Length > 0)
            {
                IPAddress[] fresh = lookup.Result.OrderBy(a => a.AddressFamily == AddressFamily.InterNetwork ? 0 : 1).ToArray();
                lock (_gate)
                {
                    _known[host] = fresh.Select(a => a.ToString()).ToArray();
                    try
                    {
                        string tmp = _path + ".tmp";
                        File.WriteAllText(tmp, JsonSerializer.Serialize(_known));
                        File.Move(tmp, _path, overwrite: true);
                    }
                    catch (IOException) { }
                }
                return fresh;
            }
        }
        catch (Exception e) when (e is AggregateException or SocketException) { }
        if (cached.Length > 0) return cached;
        throw new IOException($"Could not find {host}. Check the network connection.");
    }

    public void Prime(IEnumerable<string> hosts)
    {
        foreach (string h in hosts)
        {
            try { Resolve(h); } catch (IOException) { }
        }
    }

    /// <summary>An HTTP transport that connects using this cache. Certificates are still checked against the host name.</summary>
    public SocketsHttpHandler CreateHandler() => new()
    {
        ConnectTimeout = TimeSpan.FromSeconds(15),
        AllowAutoRedirect = false,
        UseCookies = false,
        UseProxy = false,
        SslOptions = { EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13 },
        ConnectCallback = async (context, ct) =>
        {
            Exception? last = null;
            foreach (IPAddress address in Resolve(context.DnsEndPoint.Host))
            {
                var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try
                {
                    await socket.ConnectAsync(new IPEndPoint(address, context.DnsEndPoint.Port), ct).ConfigureAwait(false);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch (Exception e) when (e is SocketException or OperationCanceledException)
                {
                    socket.Dispose();
                    last = e;
                    if (ct.IsCancellationRequested) throw;
                }
            }
            throw new HttpRequestException("could not connect", last);
        },
    };
}
