using ModelContextProtocol.Server;

namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class ToolSurfaceTests
{
    [TestMethod]
    public void PublicToolSurfaceIsTheApprovedConciseSet()
    {
        var names = typeof(PalworldTools)
            .GetMethods()
            .Select(method => method
                .GetCustomAttributes(typeof(McpServerToolAttribute), false)
                .Cast<McpServerToolAttribute>()
                .SingleOrDefault())
            .Where(attribute => attribute is not null)
            .Select(attribute => attribute!.Name)
            .OrderBy(name => name)
            .ToArray();

        CollectionAssert.AreEqual(
            new[]
            {
                "assign_pal",
                "discover_palcom_functions",
                "estimate_breeding",
                "get_base_state",
                "get_pal",
                "get_player_state",
                "get_raid_state",
                "get_status",
                "list_bases",
                "manage_raid",
                "move_pal",
                "notify_player",
                "plan_breeding",
                "search_pal_data",
                "search_pals",
                "swap_raid_pal"
            },
            names
        );
    }
}
