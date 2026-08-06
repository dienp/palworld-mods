namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class PalComBootstrapTests
{
    [TestMethod]
    public void EnabledClientProvisionsLazyStartBootstrap()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            $"palcom-bootstrap-test-{Guid.NewGuid():N}"
        );
        Directory.CreateDirectory(directory);
        var executable = Path.Combine(directory, "palworld-mcp-server.exe");
        File.WriteAllBytes(executable, []);
        try
        {
            _ = new LiveBridgeClient(new PalworldConfig
            {
                LiveBridgeEnabled = true,
                LiveBridgeDirectory = directory,
                PalComChatEnabled = true,
                PalComChatPrefix = "Hey TestCom,",
                PalComMcpServerExecutable = executable
            });

            var bootstrap = LiveBridgeProtocol.Decode(
                File.ReadAllText(Path.Combine(directory, "palcom-bootstrap.pcb"))
            );
            Assert.AreEqual("true", bootstrap["enabled"]);
            Assert.AreEqual("Hey TestCom,", bootstrap["prefix"]);
            Assert.IsTrue(File.Exists(bootstrap["launcher"]));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

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
