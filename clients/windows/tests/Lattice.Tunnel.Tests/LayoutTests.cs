using System.Net;
using System.Runtime.CompilerServices;
using Lattice.Net;
using Xunit;

namespace Lattice.Tunnel.Tests;

/// <summary>
/// The structures handed to the Windows IP Helper API must match the Windows
/// SDK byte for byte. Sizes are from netioapi.h and ws2ipdef.h on x64 and arm64.
/// </summary>
public class LayoutTests
{
    [Fact]
    public void WindowsStructuresHaveTheSdkSizes()
    {
        Assert.Equal(28, Unsafe.SizeOf<SOCKADDR_INET>());
        Assert.Equal(32, Unsafe.SizeOf<IP_ADDRESS_PREFIX>());
        Assert.Equal(80, Unsafe.SizeOf<MIB_UNICASTIPADDRESS_ROW>());
        Assert.Equal(104, Unsafe.SizeOf<MIB_IPFORWARD_ROW2>());
        Assert.Equal(168, Unsafe.SizeOf<MIB_IPINTERFACE_ROW>());
        Assert.Equal(64, Unsafe.SizeOf<DNS_INTERFACE_SETTINGS>());
    }

    [Fact]
    public void SocketAddressRoundTrip()
    {
        foreach (string text in new[] { "10.88.0.2", "255.255.255.255", "fd42:88::1000", "::1" })
        {
            IPAddress a = IPAddress.Parse(text);
            Assert.Equal(a, SOCKADDR_INET.From(a).ToAddress());
        }
    }

    [Theory]
    [InlineData("255.255.255.0", 24)]
    [InlineData("255.255.240.0", 20)]
    [InlineData("255.255.255.255", 32)]
    [InlineData("0.0.0.0", 0)]
    [InlineData("255.255.255.252", 30)]
    public void NetmaskToPrefixLength(string mask, int expected)
    {
        Assert.Equal(expected, TunnelNetwork.PrefixLength(IPAddress.Parse(mask)));
    }

    [Fact]
    public void BrokenNetmaskIsRefused()
    {
        Assert.Throws<System.ArgumentException>(() => TunnelNetwork.PrefixLength(IPAddress.Parse("255.0.255.0")));
    }
}
