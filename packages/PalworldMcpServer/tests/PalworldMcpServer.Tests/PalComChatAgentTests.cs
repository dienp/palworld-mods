namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class PalComChatAgentTests
{
    [TestMethod]
    public void PromptIncludesContextAndRecentConversation()
    {
        var prompt = PalComChatAgentService.BuildPrompt(
            "What should I build next?",
            new Dictionary<string, string>
            {
                ["current_base_name"] = "Research Outpost"
            },
            [("How are the generators?", "They look stable.")]
        );

        StringAssert.Contains(prompt, "Current base: Research Outpost");
        StringAssert.Contains(prompt, "Player: How are the generators?");
        StringAssert.Contains(prompt, "PalCom: They look stable.");
        StringAssert.Contains(prompt, "Player: What should I build next?");
        StringAssert.Contains(prompt, "All Palworld MCP tools are available");
        StringAssert.Contains(prompt, "already authorization");
        StringAssert.Contains(prompt, "without asking for confirmation");
    }

    [TestMethod]
    public void ResponseIsSingleLineAndLengthBounded()
    {
        var response = PalComChatAgentService.ClipResponse(
            "First line.\r\nSecond line.",
            18
        );

        Assert.IsLessThanOrEqualTo(18, response.Length);
        Assert.DoesNotContain('\n', response);
        Assert.EndsWith("...", response);
    }

    [TestMethod]
    public void DefaultCodexNameResolvesNewestDesktopCli()
    {
        var localRoot = Path.Combine(
            Path.GetTempPath(),
            $"palcom-codex-resolution-{Guid.NewGuid():N}"
        );
        var older = Path.Combine(localRoot, "OpenAI", "Codex", "bin", "older", "codex.exe");
        var newer = Path.Combine(localRoot, "OpenAI", "Codex", "bin", "newer", "codex.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(older)!);
        Directory.CreateDirectory(Path.GetDirectoryName(newer)!);
        File.WriteAllBytes(older, []);
        File.WriteAllBytes(newer, []);
        File.SetLastWriteTimeUtc(older, DateTime.UtcNow.AddMinutes(-1));
        File.SetLastWriteTimeUtc(newer, DateTime.UtcNow);
        try
        {
            Assert.AreEqual(
                newer,
                PalComChatAgentService.ResolveCodexExecutable(
                    "codex.exe",
                    localRoot
                )
            );
        }
        finally
        {
            Directory.Delete(localRoot, recursive: true);
        }
    }

    [TestMethod]
    public void ExplicitCodexPathIsPreserved()
    {
        var configured = Path.GetFullPath(@"C:\Tools\codex.exe");

        Assert.AreEqual(
            configured,
            PalComChatAgentService.ResolveCodexExecutable(configured)
        );
    }
}
