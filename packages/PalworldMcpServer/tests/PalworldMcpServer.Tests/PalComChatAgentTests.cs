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
}
