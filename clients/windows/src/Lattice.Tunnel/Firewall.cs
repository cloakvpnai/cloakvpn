using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace Lattice.Net;

// The traffic hold. While it is on, Windows lets a connection leave this PC
// only if it goes through the tunnel adapter, comes from the Lattice service
// itself (the tunnel's own packets and the account API), stays on this PC, or
// stays on the local network. Everything else is blocked, and name lookups
// (port 53) are blocked everywhere except through the tunnel, because Windows
// otherwise asks every network's DNS server at once.
//
// Built on the Windows Filtering Platform with a dynamic session: Windows
// removes every rule by itself the moment the service's process ends, however
// it ends. A crash can therefore never leave the PC cut off. The cost is that a
// crash also ends the hold; the service restarts and puts it back.
//
// Layer and field identifiers are from fwpmu.h in the Windows SDK (10.0.26100).

[StructLayout(LayoutKind.Sequential)]
internal struct FWPM_DISPLAY_DATA0 { public IntPtr Name; public IntPtr Description; }

[StructLayout(LayoutKind.Sequential)]
internal struct FWP_BYTE_BLOB { public uint Size; public IntPtr Data; }

[StructLayout(LayoutKind.Sequential)]
internal struct FWPM_SESSION0
{
    public Guid SessionKey;
    public FWPM_DISPLAY_DATA0 DisplayData;
    public uint Flags;
    public uint TxnWaitTimeoutInMSec;
    public uint ProcessId;
    public IntPtr Sid;
    public IntPtr Username;
    public int KernelMode;
}

[StructLayout(LayoutKind.Sequential)]
internal struct FWPM_SUBLAYER0
{
    public Guid SubLayerKey;
    public FWPM_DISPLAY_DATA0 DisplayData;
    public uint Flags;
    public IntPtr ProviderKey;
    public FWP_BYTE_BLOB ProviderData;
    public ushort Weight;
}

[StructLayout(LayoutKind.Explicit, Size = 16)]
internal struct FWP_VALUE0
{
    [FieldOffset(0)] public uint Type;
    [FieldOffset(8)] public byte UInt8;
    [FieldOffset(8)] public ushort UInt16;
    [FieldOffset(8)] public uint UInt32;
    [FieldOffset(8)] public IntPtr Pointer;
}

[StructLayout(LayoutKind.Sequential)]
internal struct FWPM_FILTER_CONDITION0
{
    public Guid FieldKey;
    public uint MatchType;
    public FWP_VALUE0 ConditionValue;
}

[StructLayout(LayoutKind.Sequential)]
internal struct FWPM_ACTION0 { public uint Type; public Guid FilterType; }

[StructLayout(LayoutKind.Explicit, Size = 16)]
internal struct FWPM_FILTER_CONTEXT { [FieldOffset(0)] public ulong RawContext; [FieldOffset(0)] public Guid ProviderContextKey; }

[StructLayout(LayoutKind.Sequential)]
internal struct FWPM_FILTER0
{
    public Guid FilterKey;
    public FWPM_DISPLAY_DATA0 DisplayData;
    public uint Flags;
    public IntPtr ProviderKey;
    public FWP_BYTE_BLOB ProviderData;
    public Guid LayerKey;
    public Guid SubLayerKey;
    public FWP_VALUE0 Weight;
    public uint NumFilterConditions;
    public IntPtr FilterCondition;
    public FWPM_ACTION0 Action;
    public FWPM_FILTER_CONTEXT Context;
    public IntPtr Reserved;
    public ulong FilterId;
    public FWP_VALUE0 EffectiveWeight;
}

internal static unsafe partial class Fwpm
{
    private const string Lib = "fwpuclnt.dll";

    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmEngineOpen0(IntPtr serverName, uint authnService, IntPtr authIdentity, FWPM_SESSION0* session, IntPtr* engine);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmEngineClose0(IntPtr engine);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmTransactionBegin0(IntPtr engine, uint flags);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmTransactionCommit0(IntPtr engine);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmTransactionAbort0(IntPtr engine);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmSubLayerAdd0(IntPtr engine, FWPM_SUBLAYER0* subLayer, IntPtr sd);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmFilterAdd0(IntPtr engine, FWPM_FILTER0* filter, IntPtr sd, ulong* id);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf16)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint FwpmGetAppIdFromFileName0(string fileName, FWP_BYTE_BLOB** appId);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial void FwpmFreeMemory0(void** p);
}

public sealed unsafe class TrafficHold : IDisposable
{
    private static readonly Guid LayerConnectV4 = new("c38d57d1-05a7-4c33-904f-7fbceee60e82");
    private static readonly Guid LayerConnectV6 = new("4a72393b-319f-44bc-84c3-ba54dcb3b6b4");
    private static readonly Guid FieldLocalInterface = new("4cd62a49-59c3-4969-b7f3-bda5d32890a4");
    private static readonly Guid FieldAppId = new("d78e1e87-8644-4ea5-9437-d809ecefc971");
    private static readonly Guid FieldFlags = new("632ce23b-5167-435c-86d7-e903684aa80c");
    private static readonly Guid FieldRemoteAddress = new("b235ae9a-1d64-49b8-a44c-5ff3d9095045");
    private static readonly Guid FieldRemotePort = new("c35a604d-d22b-4e1a-91b4-68f674ee674b");
    private static readonly Guid FieldProtocol = new("3971ef2b-623e-4f9a-8cb1-6e79b806b9a7");

    private const uint FWP_UINT8 = 1, FWP_UINT16 = 2, FWP_UINT32 = 3, FWP_UINT64 = 4, FWP_BYTE_BLOB_TYPE = 12;
    private const uint FWP_V4_ADDR_MASK = 0x100, FWP_V6_ADDR_MASK = 0x101;
    private const uint FWP_MATCH_EQUAL = 0, FWP_MATCH_FLAGS_ALL_SET = 6;
    private const uint FWP_ACTION_BLOCK = 0x1001, FWP_ACTION_PERMIT = 0x1002;
    private const uint FWP_CONDITION_FLAG_IS_LOOPBACK = 1;
    private const uint FWPM_SESSION_FLAG_DYNAMIC = 1;
    private const uint RPC_C_AUTHN_WINNT = 10;

    private static readonly string[] LocalV4 = { "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32" };
    private static readonly string[] LocalV6 = { "fe80::/10", "fc00::/7", "ff00::/8" };

    private IntPtr _engine;
    private readonly List<IntPtr> _allocations = new();
    private Guid _subLayer;

    public bool IsOn => _engine != IntPtr.Zero;

    private static void Check(uint error, string what)
    {
        if (error != 0) throw new Win32Exception(unchecked((int)error), $"Traffic hold failed ({what}, 0x{error:x8}).");
    }

    private IntPtr Alloc(int size)
    {
        IntPtr p = Marshal.AllocHGlobal(size);
        new Span<byte>((void*)p, size).Clear();
        _allocations.Add(p);
        return p;
    }

    private FWPM_FILTER_CONDITION0 Cond(Guid field, uint match, uint type, Action<IntPtr>? fillPointer = null, int size = 0, uint inline = 0)
    {
        var c = new FWPM_FILTER_CONDITION0 { FieldKey = field, MatchType = match };
        c.ConditionValue.Type = type;
        if (fillPointer is not null)
        {
            IntPtr p = Alloc(size);
            fillPointer(p);
            c.ConditionValue.Pointer = p;
        }
        else c.ConditionValue.UInt32 = inline;
        return c;
    }

    private FWPM_FILTER_CONDITION0 Address(string cidr)
    {
        string[] parts = cidr.Split('/');
        IPAddress ip = IPAddress.Parse(parts[0]);
        int bits = int.Parse(parts[1]);
        byte[] b = ip.GetAddressBytes();
        if (ip.AddressFamily == AddressFamily.InterNetwork)
        {
            uint addr = (uint)b[0] << 24 | (uint)b[1] << 16 | (uint)b[2] << 8 | b[3];
            uint mask = bits == 0 ? 0 : uint.MaxValue << (32 - bits);
            return Cond(FieldRemoteAddress, FWP_MATCH_EQUAL, FWP_V4_ADDR_MASK, p => { ((uint*)p)[0] = addr; ((uint*)p)[1] = mask; }, 8);
        }
        return Cond(FieldRemoteAddress, FWP_MATCH_EQUAL, FWP_V6_ADDR_MASK, p => { Marshal.Copy(b, 0, p, 16); ((byte*)p)[16] = (byte)bits; }, 17);
    }

    private void Add(Guid layer, string name, byte weight, uint action, params FWPM_FILTER_CONDITION0[] conditions)
    {
        IntPtr namePtr = Marshal.StringToHGlobalUni("Lattice VPN: " + name);
        _allocations.Add(namePtr);
        IntPtr array = IntPtr.Zero;
        if (conditions.Length > 0)
        {
            array = Alloc(sizeof(FWPM_FILTER_CONDITION0) * conditions.Length);
            for (int i = 0; i < conditions.Length; i++) ((FWPM_FILTER_CONDITION0*)array)[i] = conditions[i];
        }
        var filter = new FWPM_FILTER0
        {
            DisplayData = { Name = namePtr },
            LayerKey = layer,
            SubLayerKey = _subLayer,
            NumFilterConditions = (uint)conditions.Length,
            FilterCondition = array,
        };
        filter.Weight.Type = FWP_UINT8;
        filter.Weight.UInt8 = weight;
        filter.Action.Type = action;
        ulong id;
        Check(Fwpm.FwpmFilterAdd0(_engine, &filter, IntPtr.Zero, &id), name);
    }

    /// <summary>Turns the hold on. Replaces any hold already in place.</summary>
    /// <param name="tunnelLuid">The Lattice VPN adapter.</param>
    /// <param name="serviceExecutable">Full path of the service's own program, the only one allowed out around the tunnel.</param>
    public void Enable(ulong tunnelLuid, string serviceExecutable)
    {
        Disable();
        var session = new FWPM_SESSION0 { Flags = FWPM_SESSION_FLAG_DYNAMIC, TxnWaitTimeoutInMSec = 5000 };
        IntPtr engine;
        Check(Fwpm.FwpmEngineOpen0(IntPtr.Zero, RPC_C_AUTHN_WINNT, IntPtr.Zero, &session, &engine), "open");
        _engine = engine;
        FWP_BYTE_BLOB* appId = null;
        try
        {
            Check(Fwpm.FwpmTransactionBegin0(_engine, 0), "begin");
            _subLayer = Guid.NewGuid();
            IntPtr subName = Marshal.StringToHGlobalUni("Lattice VPN traffic hold");
            _allocations.Add(subName);
            var sub = new FWPM_SUBLAYER0 { SubLayerKey = _subLayer, DisplayData = { Name = subName }, Weight = 0xFFFF };
            Check(Fwpm.FwpmSubLayerAdd0(_engine, &sub, IntPtr.Zero), "sublayer");

            Check(Fwpm.FwpmGetAppIdFromFileName0(serviceExecutable, &appId), "service identity");
            FWP_BYTE_BLOB* app = appId;

            foreach (bool v6 in new[] { false, true })
            {
                Guid layer = v6 ? LayerConnectV6 : LayerConnectV4;
                string tag = v6 ? " (IPv6)" : "";
                Add(layer, "this PC to itself" + tag, 15, FWP_ACTION_PERMIT,
                    Cond(FieldFlags, FWP_MATCH_FLAGS_ALL_SET, FWP_UINT32, inline: FWP_CONDITION_FLAG_IS_LOOPBACK));
                Add(layer, "through the tunnel" + tag, 15, FWP_ACTION_PERMIT,
                    Cond(FieldLocalInterface, FWP_MATCH_EQUAL, FWP_UINT64, p => *(ulong*)p = tunnelLuid, 8));
                Add(layer, "no name lookups outside the tunnel" + tag, 14, FWP_ACTION_BLOCK,
                    Cond(FieldRemotePort, FWP_MATCH_EQUAL, FWP_UINT16, inline: 53));
                Add(layer, "the Lattice service" + tag, 13, FWP_ACTION_PERMIT,
                    Cond(FieldAppId, FWP_MATCH_EQUAL, FWP_BYTE_BLOB_TYPE, p => *(FWP_BYTE_BLOB*)p = *app, sizeof(FWP_BYTE_BLOB)));

                var local = new List<FWPM_FILTER_CONDITION0>();
                foreach (string cidr in v6 ? LocalV6 : LocalV4) local.Add(Address(cidr));
                Add(layer, "the local network" + tag, 10, FWP_ACTION_PERMIT, local.ToArray());
                Add(layer, "address assignment" + tag, 10, FWP_ACTION_PERMIT,
                    Cond(FieldProtocol, FWP_MATCH_EQUAL, FWP_UINT8, inline: 17),
                    Cond(FieldRemotePort, FWP_MATCH_EQUAL, FWP_UINT16, inline: v6 ? 547u : 67u));
                Add(layer, "everything else is held" + tag, 0, FWP_ACTION_BLOCK);
            }
            Check(Fwpm.FwpmTransactionCommit0(_engine), "commit");
        }
        catch
        {
            Fwpm.FwpmTransactionAbort0(_engine);
            Disable();
            throw;
        }
        finally
        {
            if (appId != null) Fwpm.FwpmFreeMemory0((void**)&appId);
            foreach (IntPtr p in _allocations) Marshal.FreeHGlobal(p);
            _allocations.Clear();
        }
    }

    /// <summary>Turns the hold off. Closing the session removes every rule.</summary>
    public void Disable()
    {
        IntPtr e = _engine;
        _engine = IntPtr.Zero;
        if (e != IntPtr.Zero) Fwpm.FwpmEngineClose0(e);
    }

    public void Dispose() => Disable();
}
