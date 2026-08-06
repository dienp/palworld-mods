namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class PalComBootstrapTests
{
    [TestMethod]
    public void LauncherSetsExplicitConfigAndStartsBrokerMode()
    {
        var launcher = LiveBridgeClient.BuildPalComLauncher(
            @"C:\Tools\palworld-mcp-server.exe",
            @"C:\Config\palworld-mcp.local.json"
        );

        StringAssert.Contains(
            launcher,
            "set \"PALWORLD_MCP_CONFIG=C:\\Config\\palworld-mcp.local.json\""
        );
        StringAssert.Contains(
            launcher,
            "start \"\" /b \"C:\\Tools\\palworld-mcp-server.exe\" --palcom-agent"
        );
    }

    [TestMethod]
    public void LauncherEscapesBatchPercentExpansion()
    {
        var launcher = LiveBridgeClient.BuildPalComLauncher(
            @"C:\Users\%USERNAME%\palworld-mcp-server.exe",
            @"C:\Users\%USERNAME%\palworld-mcp.local.json"
        );

        StringAssert.Contains(launcher, @"C:\Users\%%USERNAME%%");
    }
}
