using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Lattice.Api;
using Lattice.Tunnel;

namespace Lattice.Identity;

/// <summary>
/// Where the device's identity lives on disk. The private key and the account
/// number are DPAPI-protected; the certificate and gateway list are public.
/// In the installed app this directory belongs to the service and is readable
/// by LocalSystem and administrators only.
/// </summary>
public sealed class IdentityStore
{
    private readonly string _dir;

    public IdentityStore(string directory)
    {
        _dir = directory ?? throw new ArgumentNullException(nameof(directory));
        Directory.CreateDirectory(_dir);
    }

    public string Location => _dir;
    private string KeyPath => Path.Combine(_dir, "device.key");
    private string CertificatePath => Path.Combine(_dir, "device.crt");
    private string AccountPath => Path.Combine(_dir, "account.dat");
    internal string StatePath => Path.Combine(_dir, "enrollment.json");

    private static void WriteAtomic(string path, byte[] data)
    {
        string tmp = path + ".tmp";
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, path, overwrite: true);
    }

    public bool HasKey => File.Exists(KeyPath);

    /// <summary>The device key as PKCS#8, created on first use. The caller wipes the returned array.</summary>
    public byte[] LoadOrCreateKey()
    {
        if (File.Exists(KeyPath))
        {
            try { return Dpapi.Unprotect(File.ReadAllBytes(KeyPath)); }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or ArgumentException)
            {
                // Protected under another Windows account, or damaged. It cannot be
                // recovered, so the device gets a new identity and enrolls again.
                Reset();
            }
        }
        byte[] key = DeviceKey.Generate();
        WriteAtomic(KeyPath, Dpapi.Protect(key));
        return key;
    }

    public byte[]? Certificate() => File.Exists(CertificatePath) ? File.ReadAllBytes(CertificatePath) : null;

    /// <summary>Stores a certificate only if it carries this device's own public key.</summary>
    public void StoreCertificate(byte[] certificateDER)
    {
        byte[] key = LoadOrCreateKey();
        try
        {
            if (!DeviceKey.CertificateMatchesKey(certificateDER, key))
                throw new EnrollmentException("The server sent a certificate for a different device.");
        }
        finally { CryptographicOperations.ZeroMemory(key); }
        WriteAtomic(CertificatePath, certificateDER);
    }

    public string? AccountNumber()
    {
        if (!File.Exists(AccountPath)) return null;
        try
        {
            byte[] plain = Dpapi.Unprotect(File.ReadAllBytes(AccountPath));
            try { return Encoding.UTF8.GetString(plain); }
            finally { CryptographicOperations.ZeroMemory(plain); }
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or ArgumentException) { return null; }
    }

    public void SaveAccountNumber(string accountNumber)
    {
        byte[] plain = Encoding.UTF8.GetBytes(Api.AccountNumber.Format(accountNumber));
        try { WriteAtomic(AccountPath, Dpapi.Protect(plain)); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    public void ClearAccountNumber() { if (File.Exists(AccountPath)) File.Delete(AccountPath); }

    /// <summary>Erases the key, the certificate and the enrollment record.</summary>
    public void Reset()
    {
        foreach (string p in new[] { KeyPath, CertificatePath, StatePath })
            if (File.Exists(p)) File.Delete(p);
    }
}

public sealed class EnrollmentException : Exception
{
    public EnrollmentException(string message) : base(message) { }
}

/// <summary>What is remembered about the current enrollment. Nothing here is secret.</summary>
public sealed class EnrollmentState
{
    [JsonPropertyName("not_after")] public string NotAfter { get; set; } = "";
    [JsonPropertyName("not_after_unix")] public long NotAfterUnix { get; set; }
    [JsonPropertyName("device_id")] public long DeviceId { get; set; }
    [JsonPropertyName("uid")] public string Uid { get; set; } = "";
    [JsonPropertyName("gateway")] public string Gateway { get; set; } = "";
    [JsonPropertyName("root")] public string RootBase64 { get; set; } = "";
    [JsonPropertyName("gateways")] public List<GatewayRecord> Gateways { get; set; } = new();
}

public sealed class GatewayRecord
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("host")] public string Host { get; set; } = "";
    [JsonPropertyName("port")] public int Port { get; set; } = 1194;
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("tcp_host")] public string TcpHost { get; set; } = "";
    [JsonPropertyName("tcp_port")] public int TcpPort { get; set; }

    public Cnsa2Gateway ToGateway() => new(Id, Host, Port, Name, TcpHost, TcpPort);
    public static GatewayRecord From(Cnsa2Gateway g) =>
        new() { Id = g.Id, Host = g.Host, Port = g.Port, Name = g.Name, TcpHost = g.TcpHost, TcpPort = g.TcpPort };
}

/// <summary>
/// Enrolls this PC for CNSA 2.0 through the account API. Port of
/// clients/android/.../vpn/cnsa2/Cnsa2Enroller.kt.
///
/// The device's ML-DSA-87 key is made here and never leaves the PC. Only a
/// certificate request goes out. What comes back is accepted only if:
///  - the root certificate is the Lattice root this build was compiled with, and
///  - the device certificate carries this device's own public key.
///
/// The certificate lasts 30 days and is renewed from day 20 with the same key.
/// </summary>
public sealed class Cnsa2Enroller
{
    public const int RekeySeconds = 600;
    public static readonly TimeSpan RenewBefore = TimeSpan.FromDays(10);

    private readonly IdentityStore _store;
    private readonly AccountApi _api;
    private readonly SemaphoreSlim _lock = new(1, 1);

    public Cnsa2Enroller(IdentityStore store, AccountApi api)
    {
        _store = store;
        _api = api;
    }

    public EnrollmentState? State()
    {
        try
        {
            if (!File.Exists(_store.StatePath)) return null;
            return JsonSerializer.Deserialize<EnrollmentState>(File.ReadAllText(_store.StatePath));
        }
        catch (Exception e) when (e is JsonException or IOException) { return null; }
    }

    private void SaveState(EnrollmentState state)
    {
        string tmp = _store.StatePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(state));
        File.Move(tmp, _store.StatePath, overwrite: true);
    }

    private DateTimeOffset? Expiry()
    {
        // The certificate's own date wins over anything recorded beside it.
        if (_store.Certificate() is { } cert && DeviceKey.CertificateNotAfter(cert) is { } fromCert) return fromCert;
        long unix = State()?.NotAfterUnix ?? 0;
        return unix > 0 ? DateTimeOffset.FromUnixTimeSeconds(unix) : null;
    }

    /// <summary>True when the device cannot connect without enrolling first.</summary>
    public bool NeedsEnrollment(DateTimeOffset now)
    {
        if (_store.Certificate() is null || State() is not { } s || s.RootBase64.Length == 0) return true;
        return Expiry() is not { } expiry || now >= expiry;
    }

    /// <summary>True when a certificate exists and is inside the renewal window or past its expiry.</summary>
    public bool RenewalDue(DateTimeOffset now)
    {
        if (_store.Certificate() is null) return false;
        return Expiry() is { } expiry && now >= expiry - RenewBefore;
    }

    /// <summary>Enrolls, or renews with the existing key, and records the gateways on offer.</summary>
    public async Task<EnrollmentState> EnrollAsync(string accountNumber, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try { return await EnrollLockedAsync(accountNumber, ct).ConfigureAwait(false); }
        finally { _lock.Release(); }
    }

    /// <summary>Renews if still due once it holds the lock. True if a new certificate was stored.</summary>
    public async Task<bool> RenewIfDueAsync(string accountNumber, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!RenewalDue(DateTimeOffset.UtcNow)) return false;
            await EnrollLockedAsync(accountNumber, ct).ConfigureAwait(false);
            return true;
        }
        finally { _lock.Release(); }
    }

    private async Task<EnrollmentState> EnrollLockedAsync(string accountNumber, CancellationToken ct)
    {
        byte[] request;
        byte[] key = _store.LoadOrCreateKey();
        try
        {
            // The name in the request is ignored by the server, which names the device itself.
            request = DeviceKey.CertificateRequest(key, "lattice-device");
        }
        finally { CryptographicOperations.ZeroMemory(key); }

        Cnsa2Enrollment reply = await _api.EnrollCnsa2Async(accountNumber, request, ct).ConfigureAwait(false);
        if (!LatticeRoot.IsLatticeRoot(reply.Root))
            throw new EnrollmentException("The server's certificate authority is not the one this app trusts.");
        if (reply.Gateways.Count == 0)
            throw new EnrollmentException("No CNSA 2.0 gateway is available yet.");
        DateTimeOffset expiry = DeviceKey.CertificateNotAfter(reply.Certificate)
            ?? throw new EnrollmentException("The server sent a certificate without a usable expiry.");

        _store.StoreCertificate(reply.Certificate); // refuses a certificate for any other key

        var state = new EnrollmentState
        {
            NotAfter = reply.NotAfter,
            NotAfterUnix = expiry.ToUnixTimeSeconds(),
            DeviceId = reply.DeviceId,
            Uid = reply.DeviceUid,
            Gateway = State()?.Gateway is { Length: > 0 } chosen && reply.Gateways.Any(g => g.Id == chosen) ? chosen : reply.Gateways[0].Id,
            RootBase64 = Convert.ToBase64String(reply.Root),
            Gateways = reply.Gateways.Select(GatewayRecord.From).ToList(),
        };
        SaveState(state);
        return state;
    }

    /// <summary>
    /// Sign-out: removes this device from the account (which revokes its certificate on
    /// every gateway), then erases the key, the certificate and everything saved here.
    /// The local erase happens even if the server cannot be reached; the certificate then
    /// simply runs out, and its key no longer exists anywhere.
    /// </summary>
    public async Task ForgetAsync(string accountNumber, CancellationToken ct = default)
    {
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            long id = State()?.DeviceId ?? 0;
            if (id > 0)
            {
                try { await _api.RemoveDeviceAsync(accountNumber, id, ct).ConfigureAwait(false); }
                catch (AccountException) { /* erase locally regardless */ }
            }
            _store.Reset();
            _store.ClearAccountNumber();
        }
        finally { _lock.Release(); }
    }

    /// <summary>The gateways the server offered last time it was asked.</summary>
    public IReadOnlyList<Cnsa2Gateway> Gateways() =>
        State()?.Gateways.Where(g => g.Host.Length > 0 && g.Name.Length > 0).Select(g => g.ToGateway()).ToList()
        ?? (IReadOnlyList<Cnsa2Gateway>)Array.Empty<Cnsa2Gateway>();

    /// <summary>Asks the server for the current gateway list. Nothing else about the enrollment changes.</summary>
    public async Task RefreshGatewaysAsync(string accountNumber, CancellationToken ct = default)
    {
        IReadOnlyList<Cnsa2Gateway> fresh = await _api.FetchGatewaysAsync(accountNumber, ct).ConfigureAwait(false);
        if (fresh.Count == 0) return;
        await _lock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (State() is not { } current) return;
            current.Gateways = fresh.Select(GatewayRecord.From).ToList();
            SaveState(current);
        }
        finally { _lock.Release(); }
    }

    /// <summary>The gateway for a region. With no region chosen, the one saved at enrollment.
    /// There is no silent substitute for a region that is not offered.</summary>
    public Cnsa2Gateway? Choose(string? regionId)
    {
        var offered = Gateways();
        if (offered.Count == 0) return null;
        string wanted = regionId ?? State()?.Gateway ?? "";
        if (wanted.Length == 0) return offered[0];
        return offered.FirstOrDefault(g => g.Id == wanted) ?? (regionId is null ? offered[0] : null);
    }

    /// <summary>
    /// Everything the tunnel needs to reach a gateway as this device. The caller
    /// disposes it when the connection is dropped, which wipes the private key.
    /// </summary>
    public TunnelIdentity IdentityFor(Cnsa2Gateway gateway)
    {
        EnrollmentState state = State() ?? throw new EnrollmentException("This device is not enrolled.");
        byte[] root = Convert.FromBase64String(state.RootBase64);
        if (!LatticeRoot.IsLatticeRoot(root))
            throw new EnrollmentException("The saved certificate authority is not the one this app trusts.");
        byte[] cert = _store.Certificate() ?? throw new EnrollmentException("This device is not enrolled.");
        return new TunnelIdentity(root, cert, _store.LoadOrCreateKey(), gateway.Name);
    }
}
