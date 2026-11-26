using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace Lattice.Net;

// Wintun: the layer 3 TUN adapter (by WireGuard LLC), used only through its
// published wintun.h interface and shipped as the unmodified signed DLL. It is
// a generic adapter driver; no WireGuard protocol code is involved.
//
// Loaded from the application directory only (the service runs as LocalSystem).

internal static unsafe partial class WintunNative
{
    private const string Lib = "wintun";

    [LibraryImport(Lib, SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial IntPtr WintunCreateAdapter(string name, string tunnelType, Guid* requestedGuid);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial void WintunCloseAdapter(IntPtr adapter);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial void WintunGetAdapterLUID(IntPtr adapter, ulong* luid);

    [LibraryImport(Lib, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial uint WintunGetRunningDriverVersion();

    [LibraryImport(Lib, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial IntPtr WintunStartSession(IntPtr adapter, uint capacity);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial void WintunEndSession(IntPtr session);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial IntPtr WintunGetReadWaitEvent(IntPtr session);

    [LibraryImport(Lib, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial byte* WintunReceivePacket(IntPtr session, uint* packetSize);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial void WintunReleaseReceivePacket(IntPtr session, byte* packet);

    [LibraryImport(Lib, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial byte* WintunAllocateSendPacket(IntPtr session, uint packetSize);

    [LibraryImport(Lib)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory)]
    internal static partial void WintunSendPacket(IntPtr session, byte* packet);
}

/// <summary>The "Lattice VPN" network adapter. Creating it needs administrator rights.</summary>
public sealed unsafe class WintunAdapter : IDisposable
{
    public const string AdapterName = "Lattice VPN";
    public const string TunnelType = "Lattice";

    // A fixed identifier, so Windows sees the same adapter every time and keeps
    // its network profile instead of inventing "Network 2", "Network 3", ...
    private static readonly Guid AdapterGuid = new("e8b5c3a1-9d2f-4b7e-a6c4-3f1d8e5b2a90");

    private IntPtr _handle;

    /// <summary>The adapter's locally unique identifier, used for all address and route calls.</summary>
    public ulong Luid { get; }

    private WintunAdapter(IntPtr handle)
    {
        _handle = handle;
        ulong luid = 0;
        WintunNative.WintunGetAdapterLUID(handle, &luid);
        Luid = luid;
    }

    public static WintunAdapter Create()
    {
        Guid guid = AdapterGuid;
        IntPtr h = WintunNative.WintunCreateAdapter(AdapterName, TunnelType, &guid);
        if (h == IntPtr.Zero)
        {
            int error = Marshal.GetLastPInvokeError();
            throw new Win32Exception(error, error == 5
                ? "Creating the Lattice VPN adapter needs administrator rights."
                : "Could not create the Lattice VPN adapter.");
        }
        return new WintunAdapter(h);
    }

    /// <summary>Version of the loaded Wintun driver, for example "0.14".</summary>
    public static string DriverVersion
    {
        get
        {
            uint v = WintunNative.WintunGetRunningDriverVersion();
            return v == 0 ? "not loaded" : $"{(v >> 16) & 0xff}.{v & 0xff}";
        }
    }

    /// <param name="capacity">Ring size in bytes: a power of two from 128 KiB to 64 MiB.</param>
    public WintunSession StartSession(uint capacity = 0x400000)
    {
        if (_handle == IntPtr.Zero) throw new ObjectDisposedException(nameof(WintunAdapter));
        IntPtr s = WintunNative.WintunStartSession(_handle, capacity);
        if (s == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastPInvokeError(), "Could not start the adapter session.");
        return new WintunSession(s);
    }

    /// <summary>Closes the adapter. Windows removes it, with its addresses and routes.</summary>
    public void Dispose()
    {
        IntPtr h = Interlocked.Exchange(ref _handle, IntPtr.Zero);
        if (h != IntPtr.Zero) WintunNative.WintunCloseAdapter(h);
    }
}

/// <summary>
/// Packet flow to and from the adapter. One thread may receive while another
/// sends; calls in the same direction must not overlap.
/// </summary>
public sealed unsafe class WintunSession : IDisposable
{
    private const int ERROR_HANDLE_EOF = 38;
    private const int ERROR_BUFFER_OVERFLOW = 111;
    private const int ERROR_NO_MORE_ITEMS = 259;
    public const int MaxPacketSize = 0xFFFF;

    private IntPtr _handle;
    private readonly AutoResetEvent _readEvent;

    internal WintunSession(IntPtr handle)
    {
        _handle = handle;
        // Wintun owns the event; this wrapper must not close it.
        _readEvent = new AutoResetEvent(false);
        _readEvent.SafeWaitHandle.Dispose();
        _readEvent.SafeWaitHandle = new SafeWaitHandle(WintunNative.WintunGetReadWaitEvent(handle), ownsHandle: false);
    }

    /// <summary>Signalled when packets from Windows are waiting.</summary>
    public WaitHandle ReadWaitHandle => _readEvent;

    /// <summary>One IP packet that Windows wants sent through the tunnel. False when none is waiting.</summary>
    public bool TryReceive(out byte[] packet)
    {
        packet = Array.Empty<byte>();
        IntPtr h = _handle;
        if (h == IntPtr.Zero) return false;
        uint size = 0;
        byte* p = WintunNative.WintunReceivePacket(h, &size);
        if (p == null)
        {
            int error = Marshal.GetLastPInvokeError();
            if (error == ERROR_NO_MORE_ITEMS) return false;
            if (error == ERROR_HANDLE_EOF) throw new ObjectDisposedException(nameof(WintunSession), "the adapter was closed");
            throw new Win32Exception(error, "Reading from the adapter failed.");
        }
        try
        {
            packet = new byte[size];
            new ReadOnlySpan<byte>(p, (int)size).CopyTo(packet);
            return true;
        }
        finally { WintunNative.WintunReleaseReceivePacket(h, p); }
    }

    /// <summary>Hands one IP packet to Windows. False if it was dropped because the ring is full.</summary>
    public bool Send(ReadOnlySpan<byte> packet)
    {
        IntPtr h = _handle;
        if (h == IntPtr.Zero || packet.Length == 0 || packet.Length > MaxPacketSize) return false;
        byte* p = WintunNative.WintunAllocateSendPacket(h, (uint)packet.Length);
        if (p == null)
        {
            int error = Marshal.GetLastPInvokeError();
            if (error == ERROR_BUFFER_OVERFLOW) return false;
            if (error == ERROR_HANDLE_EOF) return false;
            throw new Win32Exception(error, "Writing to the adapter failed.");
        }
        packet.CopyTo(new Span<byte>(p, packet.Length));
        WintunNative.WintunSendPacket(h, p);
        return true;
    }

    public void Dispose()
    {
        IntPtr h = Interlocked.Exchange(ref _handle, IntPtr.Zero);
        if (h != IntPtr.Zero) WintunNative.WintunEndSession(h);
    }
}
