using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using PalworldMcpServer;

// PalCalc still writes a few parser diagnostics through Console.WriteLine.
// MCP reserves stdout exclusively for JSON-RPC, so route all ordinary console
// output to stderr before any PalCalc type can initialize.
Console.SetOut(Console.Error);

var builder = Host.CreateApplicationBuilder(args);
builder.Logging.AddConsole(options =>
{
    options.LogToStandardErrorThreshold = LogLevel.Trace;
});

var palComOnly = args.Any(argument =>
    string.Equals(argument, "--palcom-agent", StringComparison.OrdinalIgnoreCase)
);
if (palComOnly)
{
    builder.Services.AddHostedService<PalComChatAgentService>();
}
else
{
    builder.Services.AddSingleton<PalworldService>();
    builder.Services.AddSingleton<LiveBridgeClient>();
    builder.Services
        .AddMcpServer(options =>
        {
            options.ServerInfo = new()
            {
                Name = "palworld-breeding-advisor",
                Version = typeof(PalworldTools).Assembly
                    .GetName()
                    .Version?
                    .ToString(3) ?? "0.9.7"
            };
            options.ServerInstructions =
                "Palworld save advisor and live companion. Call get_status first. " +
                "Use plan_breeding for role resolution and breeding advice. " +
                "For base staffing, call list_bases and get_base_state, rank candidates with search_pals/get_pal, then use move_pal and assign_pal. " +
                "For raids, call get_raid_state before manage_raid; Raid Manager binds the current owned base, reports every worker slot and live level-ranked healthy Palbox reserve, fills empty slots immediately, reacts to coalesced roster and downed events, shares queue refresh and integrity reconciliation in one 60-second pass, invalidates blocked candidates without retry, warns at zero healthy reserves, and stops after 15 minutes. " +
                "Edit mode is enabled by default and can be opted out in either local configuration. " +
                "Live writes are allowlisted, idempotent, verified, and require a caller-stable idempotency key.";
        })
        .WithStdioServerTransport()
        .WithTools<PalworldTools>();
}

await builder.Build().RunAsync();
