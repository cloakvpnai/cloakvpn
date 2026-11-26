using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace Lattice.Net;

// Addresses, routes, MTU and DNS for the tunnel adapter, set through the
// Windows IP Helper API by interface LUID. No netsh, no child processes.

[StructLayout(LayoutKind.Explicit, Size = 28)]
internal unsafe struct SOCKADDR_INET
{
    [FieldOffset(0)] public ushort Family;
    [FieldOffset(2)] public ushort Port;
    [FieldOffset(4)] public uint V4Address;     // sockaddr_in.sin_addr; also sin6_flowinfo
    [FieldOffset(8)] public fixed byte V6Address[16];
    [FieldOffset(24)] public uint V6ScopeId;

    public static SOCKADDR_INET From(IPAddress address)
    {
        var s = default(SOCKADDR_INET);
        byte[] bytes = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            s.Family = 2; // AF_INET
            s.V4Address = BitConverter.ToUInt32(bytes, 0);
        }
        else if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            s.Family = 23; // AF_INET6
            for (int i = 0; i < 16; i++) s.V6Address[i] = bytes[i];
        }
        else throw new ArgumentException("not an IP address", nameof(address));
        return s;
    }

    public IPAddress? ToAddress()
    {
        if (Family == 2) return new IPAddress(BitConverter.GetBytes(V4Address));
        if (Family == 23)
        {
            var b = new byte[16];
            for (int i = 0; i < 16; i++) b[i] = V6Address[i];
            return new IPAddress(b);
        }
        return null;
    }
}

[StructLayout(LayoutKind.Sequential)]
internal struct IP_ADDRESS_PREFIX
{
    public SOCKADDR_INET Prefix;
    public byte PrefixLength;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MIB_UNICASTIPADDRESS_ROW
{
    public SOCKADDR_INET Address;
    public ulong InterfaceLuid;
    public uint InterfaceIndex;
    public int PrefixOrigin;
    public int SuffixOrigin;
    public uint ValidLifetime;
    public uint PreferredLifetime;
    public byte OnLinkPrefixLength;
    public byte SkipAsSource;
    public int DadState;
    public uint ScopeId;
    public long CreationTimeStamp;
}

[StructLayout(LayoutKind.Sequential)]
internal struct MIB_IPFORWARD_ROW2
{
    public ulong InterfaceLuid;
    public uint InterfaceIndex;
    public IP_ADDRESS_PREFIX DestinationPrefix;
    public SOCKADDR_INET NextHop;
    public byte SitePrefixLength;
    public uint ValidLifetime;
    public uint PreferredLifetime;
    public uint Metric;
    public int Protocol;
    public byte Loopback;
    public byte AutoconfigureAddress;
    public byte Publish;
    public byte Immortal;
    public uint Age;
    public int Origin;
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct MIB_IPINTERFACE_ROW
{
    public ushort Family;
    public ulong InterfaceLuid;
    public uint InterfaceIndex;
    public uint MaxReassemblySize;
    public ulong InterfaceIdentifier;
    public uint MinRouterAdvertisementInterval;
    public uint MaxRouterAdvertisementInterval;
    public byte AdvertisingEnabled;
    public byte ForwardingEnabled;
    public byte WeakHostSend;
    public byte WeakHostReceive;
    public byte UseAutomaticMetric;
    public byte UseNeighborUnreachabilityDetection;
    public byte ManagedAddressConfigurationSupported;
    public byte OtherStatefulConfigurationSupported;
    public byte AdvertiseDefaultRoute;
    public int RouterDiscoveryBehavior;
    public uint DadTransmits;
    public uint BaseReachableTime;
    public uint RetransmitTime;
    public uint PathMtuDiscoveryTimeout;
    public int LinkLocalAddressBehavior;
    public uint LinkLocalAddressTimeout;
    public fixed uint ZoneIndices[16];
    public uint SitePrefixLength;
    public uint Metric;
    public uint NlMtu;
    public byte Connected;
    public byte SupportsWakeUpPatterns;
    public byte SupportsNeighborDiscovery;
    public byte SupportsRouterDiscovery;
    public uint ReachableTime;
    public byte TransmitOffload;
    public byte ReceiveOffload;
    public byte DisableDefaultRoutes;
}

[StructLayout(LayoutKind.Sequential)]
internal struct DNS_INTERFACE_SETTINGS
{
    public uint Version;
    public ulong Flags;
    public IntPtr Domain;
    public IntPtr NameServer;
    public IntPtr SearchList;
    public uint RegistrationEnabled;
    public uint RegisterAdapterName;
    public uint EnableLLMNR;
    public uint QueryAdapterName;
    public IntPtr ProfileNameServer;
}

internal static unsafe partial class IpHelper
{
    private const string Lib = "iphlpapi.dll";

    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial void InitializeUnicastIpAddressEntry(MIB_UNICASTIPADDRESS_ROW* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint CreateUnicastIpAddressEntry(MIB_UNICASTIPADDRESS_ROW* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial void InitializeIpForwardEntry(MIB_IPFORWARD_ROW2* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint CreateIpForwardEntry2(MIB_IPFORWARD_ROW2* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint DeleteIpForwardEntry2(MIB_IPFORWARD_ROW2* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial void InitializeIpInterfaceEntry(MIB_IPINTERFACE_ROW* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint GetIpInterfaceEntry(MIB_IPINTERFACE_ROW* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint SetIpInterfaceEntry(MIB_IPINTERFACE_ROW* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint ConvertInterfaceLuidToGuid(ulong* luid, Guid* guid);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint ConvertInterfaceLuidToIndex(ulong* luid, uint* index);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint GetBestRoute2(ulong* luid, uint index, SOCKADDR_INET* source, SOCKADDR_INET* destination,
                                               uint options, MIB_IPFORWARD_ROW2* bestRoute, SOCKADDR_INET* bestSource);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint SetInterfaceDnsSettings(Guid interfaceGuid, DNS_INTERFACE_SETTINGS* settings);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint DeleteUnicastIpAddressEntry(MIB_UNICASTIPADDRESS_ROW* row);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial uint GetIpForwardTable2(ushort family, byte** table);
    [LibraryImport(Lib)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    internal static partial void FreeMibTable(void* memory);
}

/// <summary>
/// Finds the way out of this PC that does not use the tunnel, by reading the
/// routing table directly. Unlike asking Windows for its best route, this still
/// gives the physical answer while the tunnel's catch-all routes are in place.
/// </summary>
public static unsafe class PhysicalRoutes
{
    private static bool Matches(in SOCKADDR_INET prefix, int prefixLength, byte[] destination)
    {
        byte[]? p = prefix.ToAddress()?.GetAddressBytes();
        if (p is null || p.Length != destination.Length) return false;
        for (int bit = 0; bit < prefixLength; bit++)
        {
            int mask = 0x80 >> (bit % 8);
            if ((p[bit / 8] & mask) != (destination[bit / 8] & mask)) return false;
        }
        return true;
    }

    /// <summary>The best route to a destination over any interface except the excluded one, or null.</summary>
    public static PhysicalRoute? Find(IPAddress destination, ulong excludeLuid)
    {
        bool v6 = destination.AddressFamily == AddressFamily.InterNetworkV6;
        byte[] dest = destination.GetAddressBytes();
        byte* table = null;
        if (IpHelper.GetIpForwardTable2(v6 ? (ushort)23 : (ushort)2, &table) != 0 || table == null) return null;
        try
        {
            uint count = *(uint*)table;
            var rows = (MIB_IPFORWARD_ROW2*)(table + 8);
            MIB_IPFORWARD_ROW2? best = null;
            int bestLength = -1; ulong bestCost = ulong.MaxValue;
            for (uint i = 0; i < count; i++)
            {
                MIB_IPFORWARD_ROW2 row = rows[i];
                if (row.InterfaceLuid == excludeLuid || row.Loopback != 0) continue;
                int length = row.DestinationPrefix.PrefixLength;
                if (!Matches(row.DestinationPrefix.Prefix, length, dest)) continue;

                MIB_IPINTERFACE_ROW nic;
                IpHelper.InitializeIpInterfaceEntry(&nic);
                nic.Family = v6 ? (ushort)23 : (ushort)2;
                nic.InterfaceLuid = row.InterfaceLuid;
                if (IpHelper.GetIpInterfaceEntry(&nic) != 0 || nic.Connected == 0) continue;

                ulong cost = (ulong)row.Metric + nic.Metric;
                if (length > bestLength || (length == bestLength && cost < bestCost))
                {
                    best = row; bestLength = length; bestCost = cost;
                }
            }
            if (best is not { } chosen) return null;

            IPAddress? hop = chosen.NextHop.ToAddress();
            if (hop is not null && (hop.Equals(IPAddress.Any) || hop.Equals(IPAddress.IPv6Any))) hop = null;
            return new PhysicalRoute(chosen.InterfaceLuid, chosen.InterfaceIndex, hop, SourceAddress(chosen.InterfaceIndex, v6));
        }
        finally { IpHelper.FreeMibTable(table); }
    }

    private static IPAddress? SourceAddress(uint interfaceIndex, bool v6)
    {
        foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
        {
            var props = nic.GetIPProperties();
            try
            {
                int index = v6 ? props.GetIPv6Properties().Index : props.GetIPv4Properties().Index;
                if (index != interfaceIndex) continue;
            }
            catch (System.Net.NetworkInformation.NetworkInformationException) { continue; }
            foreach (var a in props.UnicastAddresses)
            {
                if (a.Address.AddressFamily != (v6 ? AddressFamily.InterNetworkV6 : AddressFamily.InterNetwork)) continue;
                if (a.Address.IsIPv6LinkLocal) continue;
                byte[] b = a.Address.GetAddressBytes();
                if (!v6 && b[0] == 169 && b[1] == 254) continue; // no DHCP lease
                return a.Address;
            }
        }
        return null;
    }
}

/// <summary>The physical path to a destination, found before the tunnel takes over routing.</summary>
public sealed record PhysicalRoute(ulong InterfaceLuid, uint InterfaceIndex, IPAddress? NextHop, IPAddress? SourceAddress);

/// <summary>
/// Network settings of the tunnel adapter. Addresses and routes on the adapter
/// disappear with it; routes placed on other interfaces (the path to the
/// gateway itself) are removed by Dispose.
/// </summary>
public sealed unsafe class TunnelNetwork : IDisposable
{
    private const uint ERROR_OBJECT_ALREADY_EXISTS = 5010;
    private const uint ERROR_NOT_FOUND = 1168;
    private const ulong DNS_SETTING_IPV6 = 0x0001;
    private const ulong DNS_SETTING_NAMESERVER = 0x0002;

    private readonly ulong _luid;
    private readonly List<MIB_IPFORWARD_ROW2> _outsideRoutes = new();

    public TunnelNetwork(ulong adapterLuid) { _luid = adapterLuid; }

    public uint InterfaceIndex
    {
        get
        {
            ulong luid = _luid; uint index = 0;
            Check(IpHelper.ConvertInterfaceLuidToIndex(&luid, &index), "interface index");
            return index;
        }
    }

    private static void Check(uint error, string what)
    {
        if (error != 0) throw new Win32Exception((int)error, $"Network setup failed ({what}).");
    }

    /// <summary>"255.255.240.0" to 20. Throws if the mask is not contiguous.</summary>
    public static int PrefixLength(IPAddress netmask)
    {
        byte[] b = netmask.GetAddressBytes();
        int bits = 0; bool ended = false;
        foreach (byte octet in b)
        {
            for (int i = 7; i >= 0; i--)
            {
                bool one = (octet & (1 << i)) != 0;
                if (one && ended) throw new ArgumentException("netmask is not contiguous", nameof(netmask));
                if (one) bits++; else ended = true;
            }
        }
        return bits;
    }

    private readonly List<MIB_UNICASTIPADDRESS_ROW> _addresses = new();

    public void AddAddress(IPAddress address, int prefixLength)
    {
        MIB_UNICASTIPADDRESS_ROW row;
        IpHelper.InitializeUnicastIpAddressEntry(&row);
        row.InterfaceLuid = _luid;
        row.Address = SOCKADDR_INET.From(address);
        row.OnLinkPrefixLength = (byte)prefixLength;
        row.DadState = 4; // IpDadStatePreferred: usable at once, no duplicate detection on a point-to-point tunnel
        uint r = IpHelper.CreateUnicastIpAddressEntry(&row);
        if (r != ERROR_OBJECT_ALREADY_EXISTS) Check(r, "address");
        _addresses.Add(row);
    }

    /// <summary>Removes every address this object gave the adapter. Routes stay.</summary>
    public void RemoveAddresses()
    {
        foreach (MIB_UNICASTIPADDRESS_ROW saved in _addresses)
        {
            MIB_UNICASTIPADDRESS_ROW row = saved;
            IpHelper.DeleteUnicastIpAddressEntry(&row);
        }
        _addresses.Clear();
    }

    /// <summary>Sets the MTU, and a fixed low metric so the tunnel is preferred for DNS and ties.</summary>
    public void ConfigureInterface(AddressFamily family, int mtu, uint metric)
    {
        MIB_IPINTERFACE_ROW row;
        IpHelper.InitializeIpInterfaceEntry(&row);
        row.Family = family == AddressFamily.InterNetworkV6 ? (ushort)23 : (ushort)2;
        row.InterfaceLuid = _luid;
        uint r = IpHelper.GetIpInterfaceEntry(&row);
        if (r == ERROR_NOT_FOUND && family == AddressFamily.InterNetworkV6) return; // IPv6 is off on this PC
        Check(r, "read interface");
        if (family == AddressFamily.InterNetwork) row.SitePrefixLength = 0; // Windows rejects the value it hands back for IPv4
        row.NlMtu = (uint)mtu;
        row.UseAutomaticMetric = 0;
        row.Metric = metric;
        if (family == AddressFamily.InterNetworkV6)
        {
            row.DadTransmits = 0;
            row.RouterDiscoveryBehavior = 0; // disabled: the gateway assigns everything
        }
        Check(IpHelper.SetIpInterfaceEntry(&row), "interface settings");
    }

    /// <summary>The IP-layer MTU and metric Windows is using for the adapter.</summary>
    public (int Mtu, uint Metric) ReadInterface(AddressFamily family)
    {
        MIB_IPINTERFACE_ROW row;
        IpHelper.InitializeIpInterfaceEntry(&row);
        row.Family = family == AddressFamily.InterNetworkV6 ? (ushort)23 : (ushort)2;
        row.InterfaceLuid = _luid;
        Check(IpHelper.GetIpInterfaceEntry(&row), "read interface");
        return ((int)row.NlMtu, row.Metric);
    }

    private static MIB_IPFORWARD_ROW2 Route(ulong luid, IPAddress destination, int prefixLength, IPAddress? nextHop, uint metric)
    {
        MIB_IPFORWARD_ROW2 row;
        IpHelper.InitializeIpForwardEntry(&row);
        row.InterfaceLuid = luid;
        row.DestinationPrefix.Prefix = SOCKADDR_INET.From(destination);
        row.DestinationPrefix.PrefixLength = (byte)prefixLength;
        IPAddress hop = nextHop ?? (destination.AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Any : IPAddress.Any);
        row.NextHop = SOCKADDR_INET.From(hop);
        row.Metric = metric;
        row.Protocol = 3; // MIB_IPPROTO_NETMGMT: a static route
        return row;
    }

    /// <summary>A route into the tunnel. With no next hop the destination is reached directly.</summary>
    public void AddRoute(IPAddress destination, int prefixLength, IPAddress? nextHop = null, uint metric = 0)
    {
        MIB_IPFORWARD_ROW2 row = Route(_luid, destination, prefixLength, nextHop, metric);
        uint r = IpHelper.CreateIpForwardEntry2(&row);
        if (r != ERROR_OBJECT_ALREADY_EXISTS) Check(r, $"route {destination}/{prefixLength}");
    }

    /// <summary>
    /// Sends everything through the tunnel using two half-size routes per
    /// family, which are more specific than any default route and so win
    /// without touching the PC's own default route.
    /// </summary>
    public void AddDefaultRoutes(bool ipv4, bool ipv6)
    {
        if (ipv4)
        {
            AddRoute(IPAddress.Parse("0.0.0.0"), 1);
            AddRoute(IPAddress.Parse("128.0.0.0"), 1);
        }
        if (ipv6)
        {
            AddRoute(IPAddress.Parse("::"), 1);
            AddRoute(IPAddress.Parse("8000::"), 1);
        }
    }

    /// <summary>How Windows would reach a destination right now.</summary>
    public static PhysicalRoute FindRoute(IPAddress destination)
    {
        SOCKADDR_INET dest = SOCKADDR_INET.From(destination);
        MIB_IPFORWARD_ROW2 best;
        SOCKADDR_INET source;
        uint r = IpHelper.GetBestRoute2(null, 0, null, &dest, 0, &best, &source);
        if (r != 0) throw new Win32Exception((int)r, $"No route to {destination}.");
        IPAddress? hop = best.NextHop.ToAddress();
        if (hop is not null && (hop.Equals(IPAddress.Any) || hop.Equals(IPAddress.IPv6Any))) hop = null;
        return new PhysicalRoute(best.InterfaceLuid, best.InterfaceIndex, hop, source.ToAddress());
    }

    /// <summary>
    /// Pins the path to the gateway itself onto the physical network, so the
    /// tunnel's own packets are never routed into the tunnel. Call before
    /// AddDefaultRoutes. Returns the physical route used.
    /// </summary>
    public PhysicalRoute AddGatewayBypass(IPAddress gatewayEndpoint)
    {
        // Read from the routing table with the tunnel left out, so this also
        // works while the tunnel's catch-all routes are already in place.
        PhysicalRoute physical = PhysicalRoutes.Find(gatewayEndpoint, _luid)
            ?? throw new InvalidOperationException("No network connection.");
        int bits = gatewayEndpoint.AddressFamily == AddressFamily.InterNetworkV6 ? 128 : 32;
        MIB_IPFORWARD_ROW2 row = Route(physical.InterfaceLuid, gatewayEndpoint, bits, physical.NextHop, 0);
        uint r = IpHelper.CreateIpForwardEntry2(&row);
        if (r == 0) _outsideRoutes.Add(row);
        else if (r != ERROR_OBJECT_ALREADY_EXISTS) Check(r, "gateway route");
        return physical;
    }

    /// <summary>DNS servers for the adapter. An empty list clears them.</summary>
    public void SetDns(IReadOnlyCollection<IPAddress> servers)
    {
        ulong luid = _luid; Guid guid;
        Check(IpHelper.ConvertInterfaceLuidToGuid(&luid, &guid), "interface id");
        foreach (bool v6 in new[] { false, true })
        {
            string list = string.Join(",", servers.Where(s => (s.AddressFamily == AddressFamily.InterNetworkV6) == v6).Select(s => s.ToString()));
            IntPtr text = Marshal.StringToHGlobalUni(list);
            try
            {
                var settings = new DNS_INTERFACE_SETTINGS
                {
                    Version = 1,
                    Flags = DNS_SETTING_NAMESERVER | (v6 ? DNS_SETTING_IPV6 : 0),
                    NameServer = text,
                };
                uint r = IpHelper.SetInterfaceDnsSettings(guid, &settings);
                if (r != 0 && !(v6 && list.Length == 0)) Check(r, v6 ? "IPv6 DNS" : "DNS");
            }
            finally { Marshal.FreeHGlobal(text); }
        }
    }

    /// <summary>Removes the gateway routes placed on other interfaces, for example after the network changed.</summary>
    public void ClearGatewayBypasses()
    {
        foreach (MIB_IPFORWARD_ROW2 saved in _outsideRoutes)
        {
            MIB_IPFORWARD_ROW2 row = saved;
            IpHelper.DeleteIpForwardEntry2(&row);
        }
        _outsideRoutes.Clear();
    }

    /// <summary>Removes the routes this object placed on other interfaces.</summary>
    public void Dispose() => ClearGatewayBypasses();
}
