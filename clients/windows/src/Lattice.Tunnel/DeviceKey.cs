using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Lattice.Tunnel;

namespace Lattice.Identity;

/// <summary>
/// The device's ML-DSA-87 key and its certificate request, made with the same
/// OpenSSL that runs the tunnel (lattice_tls_win.c). The key is created on this
/// PC and never leaves it; only the certificate request is sent out.
/// </summary>
public static unsafe class DeviceKey
{
    private const int MaxKeyBytes = 8192;       // PKCS#8 with seed and expanded key is under 5 KB
    private const int MaxRequestBytes = 12000;  // same bound the account API applies

    /// <summary>"OpenSSL 3.5.9 ..." as reported by the library in use.</summary>
    public static string OpenSslVersion =>
        Marshal.PtrToStringUTF8(Native.ltls_win_openssl_version()) ?? "";

    /// <summary>A new ML-DSA-87 private key as PKCS#8 DER.</summary>
    public static byte[] Generate()
    {
        var buffer = new byte[MaxKeyBytes];
        int n;
        fixed (byte* p = buffer) n = Native.ltls_win_keygen(p, (nuint)buffer.Length);
        if (n <= 0)
        {
            CryptographicOperations.ZeroMemory(buffer);
            throw new LatticeTunnelException("could not create the device key");
        }
        var key = new byte[n];
        Array.Copy(buffer, key, n);
        CryptographicOperations.ZeroMemory(buffer);
        return key;
    }

    /// <summary>A signed PKCS#10 certificate request (DER) for the key.</summary>
    public static byte[] CertificateRequest(byte[] privateKeyPKCS8, string commonName)
    {
        var buffer = new byte[MaxRequestBytes];
        int n;
        fixed (byte* k = privateKeyPKCS8)
        fixed (byte* p = buffer)
            n = Native.ltls_win_csr(k, (nuint)privateKeyPKCS8.Length, commonName, p, (nuint)buffer.Length);
        if (n <= 0) throw new LatticeTunnelException("could not build the certificate request");
        var request = new byte[n];
        Array.Copy(buffer, request, n);
        return request;
    }

    /// <summary>True only if the certificate carries the public key of this private key.</summary>
    public static bool CertificateMatchesKey(byte[] certificateDER, byte[] privateKeyPKCS8)
    {
        if (certificateDER.Length == 0 || privateKeyPKCS8.Length == 0) return false;
        int r;
        fixed (byte* c = certificateDER)
        fixed (byte* k = privateKeyPKCS8)
            r = Native.ltls_win_cert_matches_key(c, (nuint)certificateDER.Length, k, (nuint)privateKeyPKCS8.Length);
        return r == 1;
    }

    /// <summary>The certificate's own expiry, or null if it cannot be read.</summary>
    public static DateTimeOffset? CertificateNotAfter(byte[] certificateDER)
    {
        if (certificateDER.Length == 0) return null;
        long seconds;
        fixed (byte* c = certificateDER) seconds = Native.ltls_win_cert_not_after(c, (nuint)certificateDER.Length);
        return seconds > 0 ? DateTimeOffset.FromUnixTimeSeconds(seconds) : null;
    }

    public static byte[] Sha384(ReadOnlySpan<byte> data)
    {
        var digest = new byte[48];
        byte dummy = 0;
        int r;
        fixed (byte* d = data)
        fixed (byte* o = digest)
            r = Native.ltls_win_sha384(d != null ? d : &dummy, (nuint)data.Length, o);
        if (r != 0) throw new LatticeTunnelException("hash failed");
        return digest;
    }

    public static string Sha384Hex(ReadOnlySpan<byte> data) => Convert.ToHexString(Sha384(data)).ToLowerInvariant();
}

/// <summary>The certificate authority this build trusts.</summary>
public static class LatticeRoot
{
    /// <summary>SHA-384 of the Lattice VPN CNSA2 Root CA G1 certificate (signed Nov 23, 2026).
    /// Must match ROOT_SHA384 in the Android, iPhone and Mac apps.</summary>
    public const string Sha384 = "38b0bad58ca0da515a9cf6b6c0974d3f4a58375eda398fd78d2539b1a67945f670708d7b8693ffb5725e94d806ae07e2";

    public static bool IsLatticeRoot(byte[] rootDER)
    {
        if (rootDER is null || rootDER.Length == 0) return false;
        byte[] actual = Encoding.ASCII.GetBytes(DeviceKey.Sha384Hex(rootDER));
        byte[] expected = Encoding.ASCII.GetBytes(Sha384);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }
}
