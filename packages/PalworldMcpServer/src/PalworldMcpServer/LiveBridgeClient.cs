using System.Text.Json;
using System.Text.RegularExpressions;

namespace PalworldMcpServer;

public sealed record LiveBridgeCommandResult(
    bool Success,
    bool DryRun,
    string Action,
    string IdempotencyKey,
    string? Message,
    IReadOnlyDictionary<string, string> Data
);

public sealed partial class LiveBridgeClient
{
    private static readonly TimeSpan HeartbeatFreshness = TimeSpan.FromSeconds(7);
    private readonly SemaphoreSlim commandGate = new(1, 1);
    private readonly PalworldConfig config;
    private readonly string bridgeDirectory;
    private readonly string commandPath;
    private readonly string responsePath;
    private readonly string heartbeatPath;
    private readonly string completedDirectory;
    private readonly string auditPath;
    private readonly string palComBootstrapPath;
    private readonly string palComLauncherPath;

    public LiveBridgeClient() : this(PalworldConfig.Load())
    {
    }

    internal LiveBridgeClient(PalworldConfig config)
    {
        this.config = config;
        bridgeDirectory = ResolveBridgeDirectory(config.LiveBridgeDirectory);
        commandPath = Path.Combine(bridgeDirectory, "command.pcb");
        responsePath = Path.Combine(bridgeDirectory, "response.pcb");
        heartbeatPath = Path.Combine(bridgeDirectory, "status.pcb");
        completedDirectory = Path.Combine(bridgeDirectory, "completed");
        auditPath = Path.Combine(bridgeDirectory, "mcp-audit.jsonl");
        palComBootstrapPath = Path.Combine(bridgeDirectory, "palcom-bootstrap.pcb");
        palComLauncherPath = Path.Combine(bridgeDirectory, "palcom-launch.cmd");

        if (config.LiveBridgeEnabled)
        {
            Directory.CreateDirectory(bridgeDirectory);
            Directory.CreateDirectory(completedDirectory);
            EnsureSettingsExample();
            EnsurePalComBootstrap();
        }
    }

    public object GetStatus()
    {
        IReadOnlyDictionary<string, string>? heartbeat = null;
        string? error = null;
        DateTime? heartbeatAtUtc = null;
        if (File.Exists(heartbeatPath))
        {
            try
            {
                heartbeat = LiveBridgeProtocol.Decode(File.ReadAllText(heartbeatPath));
                heartbeatAtUtc = File.GetLastWriteTimeUtc(heartbeatPath);
            }
            catch (Exception exception)
            {
                error = exception.Message;
            }
        }

        var online = heartbeatAtUtc.HasValue &&
            DateTime.UtcNow - heartbeatAtUtc.Value <= HeartbeatFreshness;
        return new
        {
            configured = config.LiveBridgeEnabled,
            serverWriteOptIn = config.LiveBridgeWriteEnabled,
            online,
            heartbeatAtUtc,
            heartbeat,
            error,
            bridgeDirectory,
            policy = new
            {
                editMode = "Allowlisted writes are enabled by default. Set liveBridgeWriteEnabled=false or write_actions_enabled=false to opt out.",
                dryRunDefault = false,
                idempotency = "Non-dry-run actions require a caller-supplied key of 8-64 letters, digits, dots, underscores, or hyphens.",
                notifications = "Station and roster edit actions attempt an in-game success or failure notification.",
                allowlist = new[]
                {
                    "assign_pal_to_station",
                    "move_pal_roster",
                    "show_notification"
                }
            }
        };
    }

    public Task<LiveBridgeCommandResult> GetPlayerContextAsync(
        CancellationToken cancellationToken
    ) => SendAsync(
        "get_player_context",
        new Dictionary<string, string?>(),
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> GetInventorySnapshotAsync(
        CancellationToken cancellationToken
    ) => SendAsync(
        "get_inventory_snapshot",
        new Dictionary<string, string?>(),
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> ListBasesAsync(
        CancellationToken cancellationToken
    ) => SendAsync(
        "list_bases",
        new Dictionary<string, string?>(),
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> GetBaseInventorySnapshotAsync(
        string baseId,
        CancellationToken cancellationToken
    )
    {
        if (string.IsNullOrWhiteSpace(baseId))
        {
            throw new ArgumentException("A live base ID is required.");
        }
        return SendAsync(
            "get_base_inventory_snapshot",
            new Dictionary<string, string?>
            {
                ["base_id"] = baseId.Trim()
            },
            dryRun: true,
            idempotencyKey: $"read-{Guid.NewGuid():N}",
            cancellationToken
        );
    }

    public Task<LiveBridgeCommandResult> ListBaseWorkersAsync(
        string? baseId,
        CancellationToken cancellationToken
    ) => SendAsync(
        "list_base_workers",
        new Dictionary<string, string?>
        {
            ["base_id"] = baseId?.Trim()
        },
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> ListWorkstationsAsync(
        string? baseId,
        CancellationToken cancellationToken
    ) => SendAsync(
        "list_workstations",
        new Dictionary<string, string?>
        {
            ["base_id"] = baseId?.Trim()
        },
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> AssignPalToStationAsync(
        string baseId,
        string palId,
        string stationId,
        bool dryRun,
        string? idempotencyKey,
        CancellationToken cancellationToken
    )
    {
        if (string.IsNullOrWhiteSpace(baseId))
        {
            throw new ArgumentException("A live base ID is required.");
        }
        if (string.IsNullOrWhiteSpace(palId))
        {
            throw new ArgumentException("A live Pal individual ID is required.");
        }
        if (string.IsNullOrWhiteSpace(stationId))
        {
            throw new ArgumentException("A live station ID is required.");
        }
        return SendAsync(
            "assign_pal_to_station",
            new Dictionary<string, string?>
            {
                ["base_id"] = baseId.Trim(),
                ["pal_id"] = palId.Trim(),
                ["station_id"] = stationId.Trim()
            },
            dryRun,
            idempotencyKey,
            cancellationToken
        );
    }

    public Task<LiveBridgeCommandResult> ListPalboxPageAsync(
        int pageIndex,
        CancellationToken cancellationToken
    ) => SendAsync(
        "list_palbox_page",
        new Dictionary<string, string?>
        {
            ["page_index"] = Math.Max(0, pageIndex).ToString()
        },
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> GetBaseRosterAsync(
        string baseId,
        CancellationToken cancellationToken
    )
    {
        if (string.IsNullOrWhiteSpace(baseId))
        {
            throw new ArgumentException("A live base ID is required.");
        }
        return SendAsync(
            "get_base_roster",
            new Dictionary<string, string?>
            {
                ["base_id"] = baseId.Trim()
            },
            dryRun: true,
            idempotencyKey: $"read-{Guid.NewGuid():N}",
            cancellationToken
        );
    }

    public Task<LiveBridgeCommandResult> GetRaidStateAsync(
        bool includeProbe,
        bool includeReserves,
        CancellationToken cancellationToken
    ) => SendAsync(
        "get_raid_state",
        new Dictionary<string, string?>
        {
            ["include_probe"] = includeProbe ? "true" : "false",
            ["include_reserves"] = includeReserves ? "true" : "false"
        },
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> DiscoverPalcomFunctionsAsync(
        CancellationToken cancellationToken
    ) => SendAsync(
        "discover_palcom_functions",
        new Dictionary<string, string?>(),
        dryRun: true,
        idempotencyKey: $"read-{Guid.NewGuid():N}",
        cancellationToken
    );

    public Task<LiveBridgeCommandResult> SetRaidManagerAsync(
        string mode,
        IReadOnlyList<RaidReserveCandidate> reserves,
        bool dryRun,
        string? idempotencyKey,
        CancellationToken cancellationToken
    )
    {
        var normalized = mode.Trim().ToLowerInvariant();
        if (normalized is not ("off" or "observe" or "auto"))
        {
            throw new ArgumentException(
                "Raid Manager mode must be 'off', 'observe', or 'auto'."
            );
        }
        return SendAsync(
            "set_raid_manager",
            new Dictionary<string, string?>
            {
                ["mode"] = normalized,
                ["reserve_pals"] = string.Join(
                    "|",
                    reserves.Select(reserve =>
                        $"{reserve.InstanceId}~{reserve.Level}"
                    )
                )
            },
            dryRun,
            idempotencyKey,
            cancellationToken
        );
    }

    public Task<LiveBridgeCommandResult> SwapRaidPalAsync(
        string baseId,
        string downedPalId,
        string reservePalId,
        bool dryRun,
        string? idempotencyKey,
        CancellationToken cancellationToken
    )
    {
        if (string.IsNullOrWhiteSpace(baseId))
        {
            throw new ArgumentException("A loaded base ID is required.");
        }
        if (string.IsNullOrWhiteSpace(downedPalId))
        {
            throw new ArgumentException("A downed base Pal ID is required.");
        }
        if (string.IsNullOrWhiteSpace(reservePalId))
        {
            throw new ArgumentException("A Palbox reserve Pal ID is required.");
        }
        if (string.Equals(
            downedPalId.Trim(),
            reservePalId.Trim(),
            StringComparison.OrdinalIgnoreCase
        ))
        {
            throw new ArgumentException(
                "The downed fighter and reserve must be different Pals."
            );
        }
        return SendAsync(
            "swap_raid_pal",
            new Dictionary<string, string?>
            {
                ["base_id"] = baseId.Trim(),
                ["downed_pal_id"] = downedPalId.Trim(),
                ["reserve_pal_id"] = reservePalId.Trim()
            },
            dryRun,
            idempotencyKey,
            cancellationToken
        );
    }

    public Task<LiveBridgeCommandResult> MovePalRosterAsync(
        string direction,
        string baseId,
        string palId,
        bool dryRun,
        string? idempotencyKey,
        CancellationToken cancellationToken
    )
    {
        if (string.IsNullOrWhiteSpace(direction))
        {
            throw new ArgumentException(
                "Direction must be 'to_base' or 'to_palbox'."
            );
        }
        var normalizedDirection = direction.Trim().ToLowerInvariant();
        if (normalizedDirection is not ("to_base" or "to_palbox"))
        {
            throw new ArgumentException(
                "Direction must be 'to_base' or 'to_palbox'."
            );
        }
        if (string.IsNullOrWhiteSpace(baseId))
        {
            throw new ArgumentException("A live base ID is required.");
        }
        if (string.IsNullOrWhiteSpace(palId))
        {
            throw new ArgumentException("A live Pal individual ID is required.");
        }
        return SendAsync(
            "move_pal_roster",
            new Dictionary<string, string?>
            {
                ["base_id"] = baseId.Trim(),
                ["direction"] = normalizedDirection,
                ["pal_id"] = palId.Trim()
            },
            dryRun,
            idempotencyKey,
            cancellationToken
        );
    }

    public Task<LiveBridgeCommandResult> ShowNotificationAsync(
        string message,
        int priority,
        bool dryRun,
        string? idempotencyKey,
        CancellationToken cancellationToken
    )
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            throw new ArgumentException("Notification message is required.");
        }
        if (message.Length > 240)
        {
            throw new ArgumentException("Notification message cannot exceed 240 characters.");
        }

        return SendAsync(
            "show_notification",
            new Dictionary<string, string?>
            {
                ["message"] = message,
                ["priority"] = Math.Clamp(priority, 1, 3).ToString()
            },
            dryRun,
            idempotencyKey,
            cancellationToken
        );
    }

    private async Task<LiveBridgeCommandResult> SendAsync(
        string action,
        IReadOnlyDictionary<string, string?> arguments,
        bool dryRun,
        string? idempotencyKey,
        CancellationToken cancellationToken
    )
    {
        if (!config.LiveBridgeEnabled)
        {
            throw new InvalidOperationException(
                "The live bridge is disabled. Set liveBridgeEnabled=true in palworld-mcp.local.json."
            );
        }
        if (!dryRun && !config.LiveBridgeWriteEnabled)
        {
            throw new InvalidOperationException(
                "Live writes are disabled in the MCP configuration."
            );
        }

        var stableKey = idempotencyKey?.Trim();
        if (stableKey != null && !IdempotencyKeyPattern().IsMatch(stableKey))
        {
            throw new ArgumentException(
                "The idempotency key must contain 8-64 letters, digits, dots, underscores, or hyphens."
            );
        }
        if (!dryRun && stableKey == null)
        {
            throw new ArgumentException(
                "A non-dry-run action requires an idempotency key of 8-64 letters, digits, dots, underscores, or hyphens."
            );
        }
        stableKey ??= $"dryrun-{Guid.NewGuid():N}";

        await commandGate.WaitAsync(cancellationToken);
        try
        {
            Directory.CreateDirectory(bridgeDirectory);
            Directory.CreateDirectory(completedDirectory);
            var completedPath = Path.Combine(completedDirectory, $"{stableKey}.pcb");
            if (File.Exists(completedPath))
            {
                return ParseResult(File.ReadAllText(completedPath));
            }
            if (File.Exists(commandPath))
            {
                throw new InvalidOperationException(
                    "The live bridge already has a pending command."
                );
            }

            var commandId = Guid.NewGuid().ToString("N");
            var fields = new Dictionary<string, string?>(arguments, StringComparer.Ordinal)
            {
                ["action"] = action,
                ["command_id"] = commandId,
                ["created_utc"] = DateTime.UtcNow.ToString("O"),
                ["dry_run"] = dryRun ? "true" : "false",
                ["idempotency_key"] = stableKey
            };
            var temporaryPath = $"{commandPath}.{commandId}.tmp";
            File.WriteAllText(temporaryPath, LiveBridgeProtocol.Encode(fields));
            File.Move(temporaryPath, commandPath);
            AppendAudit("submitted", action, stableKey, dryRun, null);

            var timeout = TimeSpan.FromMilliseconds(
                Math.Clamp(config.LiveBridgeTimeoutMilliseconds, 1000, 60000)
            );
            var deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (File.Exists(responsePath))
                {
                    var responsePayload = File.ReadAllText(responsePath);
                    var responseFields = LiveBridgeProtocol.Decode(responsePayload);
                    if (
                        responseFields.TryGetValue("command_id", out var responseId) &&
                        string.Equals(responseId, commandId, StringComparison.Ordinal)
                    )
                    {
                        File.Delete(responsePath);
                        if (File.Exists(commandPath))
                        {
                            File.Delete(commandPath);
                        }
                        File.WriteAllText(completedPath, responsePayload);
                        PruneCompletedResults();
                        var result = ParseResult(responsePayload);
                        AppendAudit(
                            result.Success ? "completed" : "failed",
                            action,
                            stableKey,
                            dryRun,
                            result.Message
                        );
                        return result;
                    }
                }
                await Task.Delay(100, cancellationToken);
            }

            AppendAudit("timeout", action, stableKey, dryRun, "Bridge response timed out.");
            DeletePendingCommand(commandId);
            throw new TimeoutException(
                $"The live bridge did not respond within {timeout.TotalSeconds:0.#} seconds."
            );
        }
        finally
        {
            commandGate.Release();
        }
    }

    private void DeletePendingCommand(string commandId)
    {
        if (!File.Exists(commandPath))
        {
            return;
        }
        try
        {
            var fields = LiveBridgeProtocol.Decode(File.ReadAllText(commandPath));
            if (fields.GetValueOrDefault("command_id") == commandId)
            {
                File.Delete(commandPath);
            }
        }
        catch
        {
            // Preserve an unrecognized mailbox for manual inspection.
        }
    }

    private void PruneCompletedResults()
    {
        const int capacity = 256;
        var files = new DirectoryInfo(completedDirectory)
            .GetFiles("*.pcb")
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .ToList();
        foreach (var stale in files.Skip(capacity))
        {
            stale.Delete();
        }
    }

    private static LiveBridgeCommandResult ParseResult(string payload)
    {
        var fields = LiveBridgeProtocol.Decode(payload);
        var success = fields.GetValueOrDefault("success") == "true";
        var dryRun = fields.GetValueOrDefault("dry_run") == "true";
        return new(
            Success: success,
            DryRun: dryRun,
            Action: fields.GetValueOrDefault("action") ?? "unknown",
            IdempotencyKey: fields.GetValueOrDefault("idempotency_key") ?? "unknown",
            Message: fields.GetValueOrDefault("message"),
            Data: fields
                .Where(field => field.Key.StartsWith("data_", StringComparison.Ordinal))
                .ToDictionary(
                    field => field.Key["data_".Length..],
                    field => field.Value,
                    StringComparer.OrdinalIgnoreCase
                )
        );
    }

    private void AppendAudit(
        string state,
        string action,
        string idempotencyKey,
        bool dryRun,
        string? message
    )
    {
        var record = JsonSerializer.Serialize(new
        {
            timestampUtc = DateTime.UtcNow,
            state,
            action,
            idempotencyKey,
            dryRun,
            message
        });
        File.AppendAllText(auditPath, $"{record}{Environment.NewLine}");
    }

    private void EnsureSettingsExample()
    {
        var path = Path.Combine(bridgeDirectory, "bridge-settings.example.pcb");
        if (File.Exists(path))
        {
            return;
        }
        File.WriteAllText(path, LiveBridgeProtocol.Encode(new Dictionary<string, string?>
        {
            ["enabled"] = "true",
            ["palcom_lazy_start_enabled"] = "true",
            ["write_actions_enabled"] = "true"
        }));
    }

    private void EnsurePalComBootstrap()
    {
        var executable = config.PalComMcpServerExecutable;
        if (string.IsNullOrWhiteSpace(executable))
        {
            executable = Environment.ProcessPath;
        }
        var enabled = config.PalComChatEnabled &&
            !string.IsNullOrWhiteSpace(executable) &&
            File.Exists(executable);
        if (enabled)
        {
            var configPath = PalworldConfig.ResolveConfigPath();
            File.WriteAllText(
                palComLauncherPath,
                BuildPalComLauncher(executable!, configPath)
            );
        }
        File.WriteAllText(
            palComBootstrapPath,
            LiveBridgeProtocol.Encode(new Dictionary<string, string?>
            {
                ["enabled"] = enabled ? "true" : "false",
                ["launcher"] = enabled ? palComLauncherPath : "",
                ["prefix"] = config.PalComChatPrefix
            })
        );
    }

    internal static string BuildPalComLauncher(
        string executable,
        string configPath
    )
    {
        static string BatchValue(string value) => value.Replace("%", "%%");
        return string.Join(
            "\r\n",
            "@echo off",
            "setlocal DisableDelayedExpansion",
            $"set \"PALWORLD_MCP_CONFIG={BatchValue(configPath)}\"",
            $"start \"\" /b \"{BatchValue(executable)}\" --palcom-agent",
            "exit /b %errorlevel%",
            ""
        );
    }

    internal static string ResolveBridgeDirectory(string? configuredPath)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(configuredPath));
        }
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalworldCompanionBridge"
        );
    }

    [GeneratedRegex("^[A-Za-z0-9._-]{8,64}$", RegexOptions.CultureInvariant)]
    private static partial Regex IdempotencyKeyPattern();
}
