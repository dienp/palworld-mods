using System.Text.Json;

namespace PalworldMcpServer;

public sealed record PalworldConfig
{
    public string? SavePath { get; init; }
    public string[] AllowedPlayerIds { get; init; } = [];
    public int DefaultPageSize { get; init; } = 50;
    public int MaximumPageSize { get; init; } = 200;
    public bool PersistentPlanCacheEnabled { get; init; } = true;
    public string? PersistentPlanCachePath { get; init; }
    public int PersistentPlanCacheCapacity { get; init; } = 256;
    public bool LiveBridgeEnabled { get; init; }
    public bool LiveBridgeWriteEnabled { get; init; } = true;
    public string? LiveBridgeDirectory { get; init; }
    public int LiveBridgeTimeoutMilliseconds { get; init; } = 5000;
    public bool PalComChatEnabled { get; init; }
    public string PalComChatPrefix { get; init; } = "Hey PalCom,";
    public string[] PalComChatAliases { get; init; } = ["PalCom,", "Pal,", "PC,"];
    public string PalComCodexExecutable { get; init; } = "codex.exe";
    public string? PalComWorkspace { get; init; }
    public string PalComPrimaryModel { get; init; } = "gpt-5.6-sol";
    public string[] PalComFallbackModels { get; init; } = ["gpt-5.5"];
    public string PalComModelReasoningEffort { get; init; } = "low";
    public bool PalComMcpEnabled { get; init; }
    public string? PalComMcpServerExecutable { get; init; }
    public string? PalComMcpConfigPath { get; init; }
    public int PalComTimeoutMilliseconds { get; init; } = 60000;
    public int PalComMaximumPromptLength { get; init; } = 500;
    public int PalComMaximumResponseLength { get; init; } = 1200;

    public static PalworldConfig Load()
    {
        var configPath = ResolveConfigPath();

        if (!File.Exists(configPath))
        {
            return new PalworldConfig();
        }

        var json = File.ReadAllText(configPath);
        return JsonSerializer.Deserialize<PalworldConfig>(
            json,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true }
        ) ?? new PalworldConfig();
    }

    internal static string ResolveConfigPath()
    {
        var explicitPath = Environment.GetEnvironmentVariable("PALWORLD_MCP_CONFIG");
        return string.IsNullOrWhiteSpace(explicitPath)
            ? Path.Combine(AppContext.BaseDirectory, "palworld-mcp.local.json")
            : Path.GetFullPath(explicitPath);
    }
}
