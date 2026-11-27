using System.Net;
using Lattice.Api;
using Lattice.Core;
using Xunit;

namespace Lattice.Tunnel.Tests;

/// <summary>A gateway's TCP way in is used only when the list gave a usable IPv4 address and port.</summary>
public class TcpPathsTests
{
    private static Cnsa2Gateway Gateway(string tcpHost, int tcpPort) =>
        new("lab", "198.51.100.7", 1194, "lab.gw.example", tcpHost, tcpPort);

    [Fact]
    public void AnAddressAndPortGiveAPath()
    {
        IPEndPoint? path = TcpPaths.For(Gateway("198.51.100.8", 443));
        Assert.NotNull(path);
        Assert.Equal(IPAddress.Parse("198.51.100.8"), path!.Address);
        Assert.Equal(443, path.Port);
    }

    [Fact]
    public void AGatewayWithoutOneHasNoPath() =>
        Assert.Null(TcpPaths.For(new Cnsa2Gateway("lab", "198.51.100.7", 1194, "lab.gw.example")));

    [Theory]
    [InlineData("", 443)]                 // no address
    [InlineData("198.51.100.8", 0)]       // no port
    [InlineData("198.51.100.8", 70000)]   // not a port
    [InlineData("gateway.example", 443)]  // a name: cannot be looked up while traffic is held
    [InlineData("2001:db8::8", 443)]      // IPv6 is not carried outside the tunnel yet
    public void AnythingOddIsIgnored(string host, int port) => Assert.Null(TcpPaths.For(Gateway(host, port)));
}
