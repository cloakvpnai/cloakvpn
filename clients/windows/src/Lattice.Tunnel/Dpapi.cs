using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Lattice.Identity;

/// <summary>
/// Windows Data Protection (DPAPI) for secrets at rest: the device key and the
/// account number. Data is bound to the Windows account that protected it. In
/// the installed app that account is LocalSystem, so only the service (and
/// administrators) can read it back; ordinary users and their programs cannot.
/// This is software protection by the operating system, not a hardware key:
/// the TPM cannot hold ML-DSA keys. Same class of protection as the keychain
/// item on Apple platforms.
/// </summary>
public static partial class Dpapi
{
    private const uint CRYPTPROTECT_UI_FORBIDDEN = 0x1;

    // Domain separation: a blob protected for another purpose will not open here.
    private static readonly byte[] Entropy = Encoding.ASCII.GetBytes("ai.latticevpn.windows.identity.v1");

    [StructLayout(LayoutKind.Sequential)]
    private struct DATA_BLOB
    {
        public uint cbData;
        public IntPtr pbData;
    }

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptProtectData(in DATA_BLOB dataIn, IntPtr description, in DATA_BLOB entropy,
                                                 IntPtr reserved, IntPtr prompt, uint flags, out DATA_BLOB dataOut);

    [LibraryImport("crypt32.dll", SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CryptUnprotectData(in DATA_BLOB dataIn, IntPtr description, in DATA_BLOB entropy,
                                                   IntPtr reserved, IntPtr prompt, uint flags, out DATA_BLOB dataOut);

    [LibraryImport("kernel32.dll")]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static partial IntPtr LocalFree(IntPtr handle);

    public static byte[] Protect(ReadOnlySpan<byte> secret) => Transform(secret, protect: true);

    public static byte[] Unprotect(ReadOnlySpan<byte> blob) => Transform(blob, protect: false);

    private static unsafe byte[] Transform(ReadOnlySpan<byte> input, bool protect)
    {
        if (input.Length == 0) throw new ArgumentException("nothing to protect", nameof(input));
        fixed (byte* pIn = input)
        fixed (byte* pEntropy = Entropy)
        {
            var dataIn = new DATA_BLOB { cbData = (uint)input.Length, pbData = (IntPtr)pIn };
            var entropy = new DATA_BLOB { cbData = (uint)Entropy.Length, pbData = (IntPtr)pEntropy };
            DATA_BLOB dataOut;
            bool ok = protect
                ? CryptProtectData(in dataIn, IntPtr.Zero, in entropy, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out dataOut)
                : CryptUnprotectData(in dataIn, IntPtr.Zero, in entropy, IntPtr.Zero, IntPtr.Zero, CRYPTPROTECT_UI_FORBIDDEN, out dataOut);
            if (!ok) throw new Win32Exception(Marshal.GetLastPInvokeError(), protect ? "could not protect data" : "could not read protected data");
            try
            {
                var result = new byte[dataOut.cbData];
                Marshal.Copy(dataOut.pbData, result, 0, result.Length);
                return result;
            }
            finally
            {
                if (dataOut.pbData != IntPtr.Zero)
                {
                    new Span<byte>((void*)dataOut.pbData, (int)dataOut.cbData).Clear();
                    LocalFree(dataOut.pbData);
                }
            }
        }
    }
}
