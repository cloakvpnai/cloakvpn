using System;
using System.Formats.Asn1;
using System.IO;
using System.Linq;
using System.Text;
using Lattice.Api;
using Lattice.Identity;
using Lattice.Tunnel;
using Xunit;

namespace Lattice.Tunnel.Tests;

public class IdentityTests
{
    private const string MlDsa87Oid = "2.16.840.1.101.3.4.3.19";

    /// <summary>The pieces of a PKCS#10 request, read the way server/api/internal/cnsa2 reads it.</summary>
    internal sealed record ParsedRequest(int Version, string KeyOid, bool KeyHasParameters, byte[] PublicKey,
                                         byte[] SubjectPublicKeyInfo, byte[] SignedBytes, string SignatureOid, byte[] Signature);

    internal static ParsedRequest Parse(byte[] der)
    {
        var top = new AsnReader(der, AsnEncodingRules.DER);
        var request = top.ReadSequence();
        top.ThrowIfNotEmpty();

        byte[] signedBytes = request.PeekEncodedValue().ToArray();
        var info = request.ReadSequence();
        Assert.True(info.TryReadInt32(out int version));
        info.ReadEncodedValue(); // subject

        byte[] spki = info.PeekEncodedValue().ToArray();
        var keyInfo = info.ReadSequence();
        var keyAlg = keyInfo.ReadSequence();
        string keyOid = keyAlg.ReadObjectIdentifier();
        bool hasParameters = keyAlg.HasData;
        byte[] publicKey = keyInfo.ReadBitString(out int unused);
        Assert.Equal(0, unused);

        var sigAlg = request.ReadSequence();
        string sigOid = sigAlg.ReadObjectIdentifier();
        byte[] signature = request.ReadBitString(out unused);
        Assert.Equal(0, unused);
        request.ThrowIfNotEmpty();
        return new ParsedRequest(version, keyOid, hasParameters, publicKey, spki, signedBytes, sigOid, signature);
    }

    [NativeFact]
    public void LibraryIsThePinnedOpenSsl()
    {
        Assert.StartsWith("OpenSSL 3.5.9", DeviceKey.OpenSslVersion);
    }

    [NativeFact]
    public void CertificateRequestIsWhatTheAccountApiAccepts()
    {
        byte[] key = DeviceKey.Generate();
        byte[] der = DeviceKey.CertificateRequest(key, "lattice-device");

        // server/api/internal/cnsa2: at most 12000 bytes, version 0, ML-DSA-87
        // with no parameters, and a 2592 byte public key.
        Assert.InRange(der.Length, 7000, 12000);
        var r = Parse(der);
        Assert.Equal(0, r.Version);
        Assert.Equal(MlDsa87Oid, r.KeyOid);
        Assert.False(r.KeyHasParameters);
        Assert.Equal(2592, r.PublicKey.Length);
        Assert.Equal(MlDsa87Oid, r.SignatureOid);
        Assert.Equal(4627, r.Signature.Length);
    }

    [NativeFact]
    public void EachDeviceKeyIsDifferentAndRequestsFollowTheKey()
    {
        byte[] a = DeviceKey.Generate(), b = DeviceKey.Generate();
        Assert.NotEqual(a, b);
        byte[] pubA1 = Parse(DeviceKey.CertificateRequest(a, "x")).PublicKey;
        byte[] pubA2 = Parse(DeviceKey.CertificateRequest(a, "x")).PublicKey;
        byte[] pubB = Parse(DeviceKey.CertificateRequest(b, "x")).PublicKey;
        Assert.Equal(pubA1, pubA2);
        Assert.NotEqual(pubA1, pubB);
    }

    [NativeFact]
    public void GarbageKeysAndCertificatesAreRefused()
    {
        Assert.Throws<LatticeTunnelException>(() => DeviceKey.CertificateRequest(new byte[] { 1, 2, 3 }, "x"));
        byte[] key = DeviceKey.Generate();
        Assert.False(DeviceKey.CertificateMatchesKey(new byte[] { 0x30, 0x03, 1, 2, 3 }, key));
        Assert.Null(DeviceKey.CertificateNotAfter(new byte[] { 0x30, 0x03, 1, 2, 3 }));
        Assert.False(LatticeRoot.IsLatticeRoot(new byte[] { 1, 2, 3 }));
        Assert.False(LatticeRoot.IsLatticeRoot(Array.Empty<byte>()));
    }

    [NativeFact]
    public void Sha384KnownAnswer()
    {
        // FIPS 180-4 example: SHA-384("abc")
        Assert.Equal("cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7",
                     DeviceKey.Sha384Hex(Encoding.ASCII.GetBytes("abc")));
        // and of nothing
        Assert.Equal("38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b",
                     DeviceKey.Sha384Hex(ReadOnlySpan<byte>.Empty));
    }

    [Fact]
    public void DpapiRoundTrip()
    {
        byte[] secret = Encoding.UTF8.GetBytes("the device key stays on the device");
        byte[] blob = Dpapi.Protect(secret);
        Assert.NotEqual(secret, blob);
        Assert.DoesNotContain("device key", Encoding.Latin1.GetString(blob));
        Assert.Equal(secret, Dpapi.Unprotect(blob));

        blob[blob.Length / 2] ^= 1;
        Assert.ThrowsAny<Exception>(() => Dpapi.Unprotect(blob));
    }

    [Fact]
    public void AccountNumberFormatting()
    {
        Assert.Equal("36ASS06QHX877TR8T1D06DV38", AccountNumber.Normalize(" 36ass-06qhx-877tr-8t1d0-6dv38 "));
        Assert.Equal("36ASS-06QHX-877TR-8T1D0-6DV38", AccountNumber.Format("36ass06qhx877tr8t1d06dv38"));
        Assert.True(AccountNumber.IsComplete("36ASS-06QHX-877TR-8T1D0-6DV38"));
        Assert.False(AccountNumber.IsComplete("36ASS-06QHX-877TR-8T1D0"));
        // I, L, O and U are not in the alphabet and are dropped, as on the server
        Assert.Equal("", AccountNumber.Normalize("ILOU ilou -_!"));
    }

    [NativeFact]
    public void IdentityStoreKeepsOneKeyAndRefusesForeignCertificates()
    {
        string dir = Path.Combine(Path.GetTempPath(), "lattice-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new IdentityStore(dir);
            Assert.False(store.HasKey);
            byte[] first = store.LoadOrCreateKey();
            byte[] again = store.LoadOrCreateKey();
            Assert.Equal(first, again);
            Assert.True(store.HasKey);

            // the key on disk is not the key in the clear
            byte[] onDisk = File.ReadAllBytes(Path.Combine(dir, "device.key"));
            Assert.NotEqual(first, onDisk);

            Assert.Throws<EnrollmentException>(() => store.StoreCertificate(new byte[] { 0x30, 0x03, 1, 2, 3 }));
            Assert.Null(store.Certificate());

            store.SaveAccountNumber("36ass06qhx877tr8t1d06dv38");
            Assert.Equal("36ASS-06QHX-877TR-8T1D0-6DV38", store.AccountNumber());
            Assert.DoesNotContain("36ASS", Encoding.Latin1.GetString(File.ReadAllBytes(Path.Combine(dir, "account.dat"))));

            store.Reset();
            Assert.False(store.HasKey);
            Assert.NotEqual(first, store.LoadOrCreateKey());
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }
}
