#pragma warning disable SYSLIB5006 // post-quantum APIs
using System;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Lattice.Identity;
using Xunit;

namespace Lattice.Tunnel.Tests;

/// <summary>
/// Checks the OpenSSL-made device key and certificate request against a second,
/// unrelated ML-DSA implementation: the one in Windows (CNG), reached through
/// .NET. Skipped on Windows releases that do not have it; the app itself never
/// uses it.
/// </summary>
public class CrossCheckTests
{
    private sealed class WindowsMlDsaFactAttribute : FactAttribute
    {
        public WindowsMlDsaFactAttribute()
        {
            string dll = System.IO.Path.Combine(AppContext.BaseDirectory, "lattice_tls.dll");
            if (!System.IO.File.Exists(dll)) Skip = "lattice_tls.dll not built";
            else if (!MLDsa.IsSupported) Skip = "this Windows release has no ML-DSA";
        }
    }

    [WindowsMlDsaFact]
    public void RequestSignatureVerifiesUnderWindowsMlDsa()
    {
        byte[] key = DeviceKey.Generate();
        var r = IdentityTests.Parse(DeviceKey.CertificateRequest(key, "lattice-device"));

        using MLDsa publicKey = MLDsa.ImportSubjectPublicKeyInfo(r.SubjectPublicKeyInfo);
        Assert.Equal(MLDsaAlgorithm.MLDsa87, publicKey.Algorithm);
        Assert.True(publicKey.VerifyData(r.SignedBytes, r.Signature), "proof of possession does not verify");

        byte[] tampered = (byte[])r.SignedBytes.Clone();
        tampered[tampered.Length - 1] ^= 1;
        Assert.False(publicKey.VerifyData(tampered, r.Signature));
    }

    [WindowsMlDsaFact]
    public void CertificateIsMatchedToItsKeyOnly()
    {
        byte[] key = DeviceKey.Generate();
        byte[] other = DeviceKey.Generate();

        // A certificate for the device key, made by Windows rather than by OpenSSL.
        using MLDsa windowsKey = MLDsa.ImportPkcs8PrivateKey(key);
        var request = new CertificateRequest("CN=cross-check", windowsKey);
        DateTimeOffset notAfter = new DateTimeOffset(2027, 1, 2, 3, 4, 5, TimeSpan.Zero);
        // Create (not CreateSelfSigned): the latter also tries to attach the private
        // key to the result through CNG, which this test has no use for.
        using X509Certificate2 cert = request.Create(request.SubjectName, X509SignatureGenerator.CreateForMLDsa(windowsKey),
                                                     notAfter.AddDays(-30), notAfter, new byte[] { 0x01, 0x23, 0x45 });
        byte[] der = cert.RawData;

        Assert.True(DeviceKey.CertificateMatchesKey(der, key));
        Assert.False(DeviceKey.CertificateMatchesKey(der, other));
        Assert.Equal(notAfter, DeviceKey.CertificateNotAfter(der));

        // trailing bytes after the certificate are not accepted
        byte[] padded = new byte[der.Length + 1];
        der.CopyTo(padded, 0);
        Assert.False(DeviceKey.CertificateMatchesKey(padded, key));
    }
}
