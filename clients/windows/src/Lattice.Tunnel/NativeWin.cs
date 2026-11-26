using System.Runtime.InteropServices;

namespace Lattice.Tunnel;

// The Windows-only exports of lattice_tls.dll (native\lattice_tls\lattice_tls_win.c).
internal static unsafe partial class Native
{
    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_win_keygen(byte* output, nuint cap);

    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_win_csr(byte* key, nuint keyLen, string commonName, byte* output, nuint cap);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_win_cert_matches_key(byte* cert, nuint certLen, byte* key, nuint keyLen);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial long ltls_win_cert_not_after(byte* cert, nuint certLen);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial int ltls_win_sha384(byte* data, nuint len, byte* output);
}
