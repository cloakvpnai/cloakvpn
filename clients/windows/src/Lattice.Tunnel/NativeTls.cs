using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Lattice.Tunnel;

// Managed surface over lattice_tls.dll, which is the shared C layer from
// clients/apple-tls/Sources/CLatticeTLS compiled with MSVC and statically
// linked against OpenSSL 3.5.9. All cryptography in the tunnel (handshake,
// data channel and randomness) goes through this one module.
//
// The DLL is loaded from the application directory only. The service runs as
// LocalSystem, so a search-path lookup would be a privilege escalation path.

internal static unsafe partial class Native
{
    private const string Lib = "lattice_tls";

    // Runs before the first call into the library from any thread: switches
    // off OpenSSL's automatic openssl.cnf loading (see lattice_tls_win.c).
    static Native()
    {
        if (ltls_win_init() != 0)
            throw new LatticeTunnelException("cryptographic library failed to start");
    }

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    private static partial int ltls_win_init();

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial IntPtr ltls_win_openssl_version();

    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial IntPtr ltls_new(byte* ca, nuint caLen, byte* cert, nuint certLen,
                                            byte* key, nuint keyLen, string serverName,
                                            byte* err, nuint errLen);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial void ltls_free(IntPtr t);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_feed(IntPtr t, byte* data, nuint len);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_handshake(IntPtr t);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_drain(IntPtr t, byte* output, nuint cap);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_write(IntPtr t, byte* data, nuint len);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_read(IntPtr t, byte* output, nuint cap);

    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_export(IntPtr t, string label, byte* output, nuint len);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial IntPtr ltls_describe(IntPtr t);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial IntPtr ltls_error(IntPtr t);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_gcm_seal(byte* key, byte* nonce, byte* ad, nuint adLen,
                                              byte* input, nuint inputLen, byte* output, byte* tag);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_gcm_open(byte* key, byte* nonce, byte* ad, nuint adLen,
                                              byte* input, nuint inputLen, byte* tag, byte* output);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_random(byte* output, nuint len);
}

/// <summary>
/// The device's CNSA 2.0 identity and the gateway it trusts. All DER.
/// The private key is read again at every re-key, so this object must live for
/// the whole connection. Dispose it when the connection is dropped.
/// </summary>
public sealed class TunnelIdentity : IDisposable
{
    public byte[] CaDER { get; }
    public byte[] CertificateDER { get; }
    public byte[] PrivateKeyPKCS8 { get; }
    public string GatewayName { get; }

    public TunnelIdentity(byte[] caDER, byte[] certificateDER, byte[] privateKeyPKCS8, string gatewayName)
    {
        CaDER = caDER ?? throw new ArgumentNullException(nameof(caDER));
        CertificateDER = certificateDER ?? throw new ArgumentNullException(nameof(certificateDER));
        PrivateKeyPKCS8 = privateKeyPKCS8 ?? throw new ArgumentNullException(nameof(privateKeyPKCS8));
        GatewayName = gatewayName ?? throw new ArgumentNullException(nameof(gatewayName));
    }

    public void Dispose() => CryptographicOperations.ZeroMemory(PrivateKeyPKCS8);
}

/// <summary>One TLS 1.3 handshake and session, restricted to the CNSA 2.0 suite by OpenSSL.</summary>
public sealed unsafe class TlsSession : IDisposable
{
    private IntPtr _handle;

    public TlsSession(TunnelIdentity identity)
    {
        if (identity.CaDER.Length == 0 || identity.CertificateDER.Length == 0 || identity.PrivateKeyPKCS8.Length == 0)
            throw new LatticeTunnelException("identity is incomplete");

        const int errCap = 256;
        byte* err = stackalloc byte[errCap];
        new Span<byte>(err, errCap).Clear();

        IntPtr made;
        fixed (byte* ca = identity.CaDER)
        fixed (byte* cert = identity.CertificateDER)
        fixed (byte* key = identity.PrivateKeyPKCS8)
        {
            made = Native.ltls_new(ca, (nuint)identity.CaDER.Length,
                                   cert, (nuint)identity.CertificateDER.Length,
                                   key, (nuint)identity.PrivateKeyPKCS8.Length,
                                   identity.GatewayName, err, errCap);
        }
        if (made == IntPtr.Zero)
            throw new LatticeTunnelException(Marshal.PtrToStringUTF8((IntPtr)err) ?? "TLS setup failed");
        _handle = made;
    }

    private IntPtr Handle => _handle != IntPtr.Zero ? _handle : throw new ObjectDisposedException(nameof(TlsSession));

    /// <summary>"TLSv1.3 TLS_AES_256_GCM_SHA384 MLKEM1024 mldsa87" once the handshake is complete.</summary>
    public string Summary => Marshal.PtrToStringUTF8(Native.ltls_describe(Handle)) ?? "";

    private LatticeTunnelException LastError =>
        new(Marshal.PtrToStringUTF8(Native.ltls_error(Handle)) ?? "TLS error");

    public void Feed(ReadOnlySpan<byte> data)
    {
        if (data.Length == 0) return;
        int r;
        fixed (byte* p = data) r = Native.ltls_feed(Handle, p, (nuint)data.Length);
        if (r != 0) throw new LatticeTunnelException("TLS input failed");
    }

    /// <summary>True once the handshake is complete and the negotiated suite has been checked.</summary>
    public bool Handshake()
    {
        return Native.ltls_handshake(Handle) switch
        {
            1 => true,
            0 => false,
            _ => throw LastError,
        };
    }

    public byte[] Drain()
    {
        var w = new ByteWriter(4096);
        const int cap = 4096;
        byte* buffer = stackalloc byte[cap];
        while (true)
        {
            int n = Native.ltls_drain(Handle, buffer, cap);
            if (n <= 0) break;
            w.Bytes(new ReadOnlySpan<byte>(buffer, n));
        }
        return w.ToArray();
    }

    public void Write(ReadOnlySpan<byte> data)
    {
        int r;
        fixed (byte* p = data) r = Native.ltls_write(Handle, p, (nuint)data.Length);
        if (r != 0) throw new LatticeTunnelException("TLS write failed");
    }

    /// <summary>Application data, one element per TLS record (the gateway sends one message per record).</summary>
    public List<byte[]> ReadRecords()
    {
        var records = new List<byte[]>();
        byte[] buffer = new byte[17408];
        fixed (byte* p = buffer)
        {
            while (true)
            {
                int n = Native.ltls_read(Handle, p, (nuint)buffer.Length);
                if (n < 0) throw LastError;
                if (n == 0) break;
                var record = new byte[n];
                Array.Copy(buffer, record, n);
                records.Add(record);
            }
        }
        CryptographicOperations.ZeroMemory(buffer);
        return records;
    }

    public byte[] Export(string label, int length)
    {
        var output = new byte[length];
        int r;
        fixed (byte* p = output) r = Native.ltls_export(Handle, label, p, (nuint)length);
        if (r != 0) throw new LatticeTunnelException("key export failed");
        return output;
    }

    public void Dispose()
    {
        var h = _handle;
        _handle = IntPtr.Zero;
        if (h != IntPtr.Zero) Native.ltls_free(h);
        GC.SuppressFinalize(this);
    }

    ~TlsSession()
    {
        if (_handle != IntPtr.Zero) Native.ltls_free(_handle);
    }
}

/// <summary>AES-256-GCM for the data channel, from the same OpenSSL as the handshake.</summary>
public static unsafe class Gcm
{
    public const int KeyLength = 32;
    public const int NonceLength = 12;
    public const int TagLength = 16;

    public static (byte[] Ciphertext, byte[] Tag) Seal(ReadOnlySpan<byte> key, ReadOnlySpan<byte> nonce,
                                                      ReadOnlySpan<byte> ad, ReadOnlySpan<byte> plaintext)
    {
        if (key.Length != KeyLength || nonce.Length != NonceLength)
            throw new LatticeTunnelException("encryption failed");

        var output = new byte[Math.Max(plaintext.Length, 1)];
        var tag = new byte[TagLength];
        byte dummy = 0;
        int r;
        fixed (byte* k = key)
        fixed (byte* n = nonce)
        fixed (byte* a = ad)
        fixed (byte* p = plaintext)
        fixed (byte* o = output)
        fixed (byte* t = tag)
        {
            // OpenSSL treats a null input pointer as "finish", so never pass one.
            r = Native.ltls_gcm_seal(k, n, a != null ? a : &dummy, (nuint)ad.Length,
                                     p != null ? p : &dummy, (nuint)plaintext.Length, o, t);
        }
        if (r != 0) throw new LatticeTunnelException("encryption failed");
        if (output.Length != plaintext.Length) Array.Resize(ref output, plaintext.Length);
        return (output, tag);
    }

    /// <summary>Returns null if the data does not authenticate.</summary>
    public static byte[]? Open(ReadOnlySpan<byte> key, ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> ad,
                               ReadOnlySpan<byte> ciphertext, ReadOnlySpan<byte> tag)
    {
        if (key.Length != KeyLength || nonce.Length != NonceLength || tag.Length != TagLength) return null;

        var output = new byte[Math.Max(ciphertext.Length, 1)];
        byte dummy = 0;
        int r;
        fixed (byte* k = key)
        fixed (byte* n = nonce)
        fixed (byte* a = ad)
        fixed (byte* c = ciphertext)
        fixed (byte* t = tag)
        fixed (byte* o = output)
        {
            r = Native.ltls_gcm_open(k, n, a != null ? a : &dummy, (nuint)ad.Length,
                                     c != null ? c : &dummy, (nuint)ciphertext.Length, t, o);
        }
        if (r != 0)
        {
            CryptographicOperations.ZeroMemory(output);
            return null;
        }
        if (output.Length != ciphertext.Length) Array.Resize(ref output, ciphertext.Length);
        return output;
    }
}

public static unsafe class Rng
{
    /// <summary>Random bytes from OpenSSL's DRBG, the same source the handshake uses.</summary>
    public static byte[] Bytes(int count)
    {
        var output = new byte[count];
        if (count == 0) return output;
        int r;
        fixed (byte* p = output) r = Native.ltls_random(p, (nuint)count);
        if (r != 0) throw new LatticeTunnelException("no randomness");
        return output;
    }
}
