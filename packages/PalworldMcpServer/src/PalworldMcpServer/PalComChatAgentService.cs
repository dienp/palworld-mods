using System.Diagnostics;
using System.Text;
using System.Threading.Channels;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace PalworldMcpServer;

public sealed class PalComChatAgentService(
    ILogger<PalComChatAgentService> logger
) : BackgroundService
{
    private static readonly TimeSpan LeaseRenewalInterval = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan LeaseDuration = TimeSpan.FromSeconds(15);
    private static readonly string[] PalComTools =
    [
        "get_status",
        "search_pals",
        "get_pal",
        "search_pal_data",
        "plan_breeding",
        "estimate_breeding",
        "get_player_state",
        "get_raid_state",
        "list_bases",
        "get_base_state",
        "manage_raid",
        "swap_raid_pal",
        "move_pal",
        "assign_pal",
        "notify_player"
    ];
    private readonly PalworldConfig config = PalworldConfig.Load();
    private readonly List<(string User, string Assistant)> history = [];
    private long watcherEvents;
    private long watcherEventsCoalesced;
    private long watcherRecoveries;
    private long requestsClaimed;
    private long requestsProcessed;
    private long requestFailures;
    private long leaseWrites;
    private long lastClaimLatencyMilliseconds;
    private long lastResponseLatencyMilliseconds;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var directory = LiveBridgeClient.ResolveBridgeDirectory(
            config.LiveBridgeDirectory
        );
        Directory.CreateDirectory(directory);
        var requestPath = Path.Combine(directory, "palcom-request.pcb");
        var responsePath = Path.Combine(directory, "palcom-response.pcb");
        var statusPath = Path.Combine(directory, "palcom-status.pcb");

        logger.LogInformation(
            "PalCom chat agent {State}; mailbox {Directory}",
            config.PalComChatEnabled ? "enabled" : "disabled",
            directory
        );

        if (!config.PalComChatEnabled)
        {
            WriteStatus(statusPath, ready: false);
            await Task.Delay(Timeout.InfiniteTimeSpan, stoppingToken);
            return;
        }

        var signals = Channel.CreateBounded<bool>(
            new BoundedChannelOptions(1)
            {
                FullMode = BoundedChannelFullMode.DropWrite,
                SingleReader = true,
                SingleWriter = false
            }
        );
        var requestPending = 0;
        var watcherFailed = 0;

        void WakeBroker()
        {
            if (!signals.Writer.TryWrite(true))
            {
                Interlocked.Increment(ref watcherEventsCoalesced);
            }
        }

        void SignalRequest()
        {
            Interlocked.Increment(ref watcherEvents);
            Interlocked.Exchange(ref requestPending, 1);
            WakeBroker();
        }

        FileSystemWatcher CreateWatcher()
        {
            var watcher = new FileSystemWatcher(directory, Path.GetFileName(requestPath))
            {
                EnableRaisingEvents = false,
                IncludeSubdirectories = false,
                NotifyFilter = NotifyFilters.FileName |
                    NotifyFilters.CreationTime |
                    NotifyFilters.LastWrite
            };
            watcher.Created += (_, _) => SignalRequest();
            watcher.Changed += (_, _) => SignalRequest();
            watcher.Renamed += (_, _) => SignalRequest();
            watcher.Error += (_, eventArgs) =>
            {
                logger.LogWarning(
                    eventArgs.GetException(),
                    "PalCom request watcher failed; scheduling recovery"
                );
                Interlocked.Exchange(ref watcherFailed, 1);
                WakeBroker();
            };
            watcher.EnableRaisingEvents = true;
            return watcher;
        }

        FileSystemWatcher? requestWatcher = null;
        Task? leaseTask = null;
        try
        {
            requestWatcher = CreateWatcher();
            WriteStatus(statusPath, ready: true);
            leaseTask = RunLeaseRenewalAsync(statusPath, stoppingToken);
            if (File.Exists(requestPath))
            {
                Interlocked.Exchange(ref requestPending, 1);
                WakeBroker();
            }

            await foreach (
                var signal in signals.Reader.ReadAllAsync(stoppingToken)
            )
            {
                _ = signal;
                while (signals.Reader.TryRead(out var ignoredSignal))
                {
                    _ = ignoredSignal;
                }

                if (Interlocked.Exchange(ref watcherFailed, 0) == 1)
                {
                    requestWatcher.Dispose();
                    requestWatcher = CreateWatcher();
                    Interlocked.Increment(ref watcherRecoveries);
                    if (File.Exists(requestPath))
                    {
                        Interlocked.Exchange(ref requestPending, 1);
                    }
                }

                if (Interlocked.Exchange(ref requestPending, 0) != 1 ||
                    !File.Exists(requestPath))
                {
                    continue;
                }

                var claimPath = Path.Combine(
                    directory,
                    $"palcom-request.{Guid.NewGuid():N}.processing"
                );
                try
                {
                    File.Move(requestPath, claimPath);
                }
                catch (IOException exception)
                {
                    logger.LogDebug(
                        exception,
                        "PalCom request was no longer claimable"
                    );
                    continue;
                }

                Interlocked.Increment(ref requestsClaimed);
                await ProcessRequestAsync(
                    claimPath,
                    responsePath,
                    stoppingToken
                );
                Interlocked.Increment(ref requestsProcessed);

                if (File.Exists(requestPath))
                {
                    Interlocked.Exchange(ref requestPending, 1);
                    WakeBroker();
                }
            }
        }
        finally
        {
            requestWatcher?.Dispose();
            if (leaseTask is not null)
            {
                try
                {
                    await leaseTask;
                }
                catch (OperationCanceledException) when (
                    stoppingToken.IsCancellationRequested
                )
                {
                }
            }
            WriteStatus(statusPath, ready: false);
        }
    }

    private async Task RunLeaseRenewalAsync(
        string statusPath,
        CancellationToken stoppingToken
    )
    {
        using var timer = new PeriodicTimer(LeaseRenewalInterval);
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            WriteStatus(statusPath, ready: true);
        }
    }

    private async Task ProcessRequestAsync(
        string claimPath,
        string responsePath,
        CancellationToken stoppingToken
    )
    {
        IReadOnlyDictionary<string, string>? request = null;
        DateTimeOffset? submittedAt = null;
        try
        {
            request = LiveBridgeProtocol.Decode(
                await File.ReadAllTextAsync(claimPath, stoppingToken)
            );
            if (DateTimeOffset.TryParse(
                request.GetValueOrDefault("timestamp_utc"),
                out var parsedSubmittedAt
            ))
            {
                submittedAt = parsedSubmittedAt;
                Interlocked.Exchange(
                    ref lastClaimLatencyMilliseconds,
                    Math.Max(
                        0,
                        (long)(DateTimeOffset.UtcNow - parsedSubmittedAt)
                            .TotalMilliseconds
                    )
                );
            }
            var requestId = request.GetValueOrDefault("request_id") ?? "";
            var message = request.GetValueOrDefault("message")?.Trim() ?? "";
            if (requestId.Length == 0)
            {
                throw new InvalidDataException("PalCom request_id is required.");
            }
            if (message.Length == 0)
            {
                throw new InvalidDataException("PalCom message is required.");
            }
            if (message.Length > Math.Max(1, config.PalComMaximumPromptLength))
            {
                throw new InvalidDataException(
                    $"PalCom messages are limited to {config.PalComMaximumPromptLength} characters."
                );
            }

            var answer = await RunCodexAsync(
                BuildPrompt(message, request, history),
                stoppingToken
            );
            answer = ClipResponse(answer, config.PalComMaximumResponseLength);
            history.Add((message, answer));
            if (history.Count > 6)
            {
                history.RemoveAt(0);
            }
            WriteResponse(responsePath, requestId, success: true, answer);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            Interlocked.Increment(ref requestFailures);
            logger.LogWarning(exception, "PalCom request failed");
            WriteResponse(
                responsePath,
                request?.GetValueOrDefault("request_id") ?? "unknown",
                success: false,
                "I couldn't reach Codex just now. Your normal chat is still available."
            );
        }
        finally
        {
            if (submittedAt.HasValue)
            {
                Interlocked.Exchange(
                    ref lastResponseLatencyMilliseconds,
                    Math.Max(
                        0,
                        (long)(DateTimeOffset.UtcNow - submittedAt.Value)
                            .TotalMilliseconds
                    )
                );
            }
            try
            {
                File.Delete(claimPath);
            }
            catch (IOException exception)
            {
                logger.LogDebug(exception, "Could not remove PalCom claim file");
            }
        }
    }

    private async Task<string> RunCodexAsync(
        string prompt,
        CancellationToken stoppingToken
    )
    {
        var models = new[] { config.PalComPrimaryModel }
            .Concat(config.PalComFallbackModels ?? [])
            .Where(model => !string.IsNullOrWhiteSpace(model))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        Exception? lastError = null;
        foreach (var model in models)
        {
            try
            {
                var answer = await RunCodexOnceAsync(
                    prompt,
                    model.Trim(),
                    stoppingToken
                );
                logger.LogInformation(
                    "PalCom request completed with model {Model}",
                    model
                );
                return answer;
            }
            catch (OperationCanceledException) when (
                stoppingToken.IsCancellationRequested
            )
            {
                throw;
            }
            catch (Exception exception)
            {
                lastError = exception;
                logger.LogWarning(
                    exception,
                    "PalCom model {Model} failed; trying the next configured model",
                    model
                );
            }
        }
        throw new InvalidOperationException(
            "No configured PalCom model was available.",
            lastError
        );
    }

    private async Task<string> RunCodexOnceAsync(
        string prompt,
        string model,
        CancellationToken stoppingToken
    )
    {
        var workspace = string.IsNullOrWhiteSpace(config.PalComWorkspace)
            ? LiveBridgeClient.ResolveBridgeDirectory(config.LiveBridgeDirectory)
            : Path.GetFullPath(
                Environment.ExpandEnvironmentVariables(config.PalComWorkspace)
            );
        Directory.CreateDirectory(workspace);

        var startInfo = new ProcessStartInfo
        {
            FileName = config.PalComCodexExecutable,
            WorkingDirectory = workspace,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };
        RemoveSensitiveEnvironmentVariables(startInfo);
        foreach (var argument in new[]
        {
            "exec",
            "--ephemeral",
            "--sandbox",
            "read-only",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--model",
            model,
            "--config",
            $"model_reasoning_effort={TomlString(config.PalComModelReasoningEffort)}",
            "--config",
            "approval_policy=\"never\"",
            "--config",
            "web_search=\"disabled\"",
            "--config",
            "features.shell_tool=false",
            "--config",
            "features.apps=false",
            "--config",
            "features.plugins=false",
            "--config",
            "features.remote_plugin=false",
            "--config",
            "features.multi_agent=false",
            "--config",
            "features.hooks=false",
            "--config",
            "features.memories=false",
            "--config",
            "features.skill_mcp_dependency_install=false",
            "--config",
            "features.shell_snapshot=false"
        })
        {
            startInfo.ArgumentList.Add(argument);
        }
        AddPalworldMcpArguments(startInfo);
        startInfo.ArgumentList.Add(prompt);

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("Codex did not start.");
        }
        var stdoutTask = process.StandardOutput.ReadToEndAsync(stoppingToken);
        var stderrTask = process.StandardError.ReadToEndAsync(stoppingToken);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
            stoppingToken
        );
        timeout.CancelAfter(Math.Max(1000, config.PalComTimeoutMilliseconds));
        try
        {
            await process.WaitForExitAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("Codex response timed out.");
        }

        var stdout = (await stdoutTask).Trim();
        var stderr = (await stderrTask).Trim();
        if (process.ExitCode != 0 || stdout.Length == 0)
        {
            throw new InvalidOperationException(
                $"Codex exited with code {process.ExitCode}: {ClipResponse(stderr, 300)}"
            );
        }
        return stdout;
    }

    private void AddPalworldMcpArguments(ProcessStartInfo startInfo)
    {
        if (!config.PalComMcpEnabled)
        {
            return;
        }
        if (string.IsNullOrWhiteSpace(config.PalComMcpServerExecutable) ||
            string.IsNullOrWhiteSpace(config.PalComMcpConfigPath))
        {
            throw new InvalidOperationException(
                "PalCom MCP is enabled but its executable or local config path is missing."
            );
        }

        var executable = Path.GetFullPath(
            Environment.ExpandEnvironmentVariables(
                config.PalComMcpServerExecutable
            )
        );
        var mcpConfig = Path.GetFullPath(
            Environment.ExpandEnvironmentVariables(config.PalComMcpConfigPath)
        );
        if (!File.Exists(executable) || !File.Exists(mcpConfig))
        {
            throw new FileNotFoundException(
                "The configured PalCom MCP executable or local config was not found."
            );
        }

        AddConfig(
            startInfo,
            $"mcp_servers.palworld.command={TomlString(executable)}"
        );
        AddConfig(
            startInfo,
            "mcp_servers.palworld.required=true"
        );
        AddConfig(
            startInfo,
            "mcp_servers.palworld.default_tools_approval_mode=\"approve\""
        );
        AddConfig(
            startInfo,
            "mcp_servers.palworld.enabled_tools=[" +
                string.Join(",", PalComTools.Select(TomlString)) +
                "]"
        );
        AddConfig(
            startInfo,
            "mcp_servers.palworld.env.PALWORLD_MCP_CONFIG=" +
                TomlString(mcpConfig)
        );
    }

    private static void AddConfig(ProcessStartInfo startInfo, string value)
    {
        startInfo.ArgumentList.Add("--config");
        startInfo.ArgumentList.Add(value);
    }

    private static string TomlString(string value) =>
        System.Text.Json.JsonSerializer.Serialize(value);

    private static void RemoveSensitiveEnvironmentVariables(
        ProcessStartInfo startInfo
    )
    {
        string[] markers =
        [
            "KEY",
            "TOKEN",
            "SECRET",
            "PASSWORD",
            "CREDENTIAL",
            "COOKIE"
        ];
        foreach (var name in startInfo.Environment.Keys.ToArray())
        {
            if (markers.Any(marker =>
                name.Contains(marker, StringComparison.OrdinalIgnoreCase)
            ))
            {
                startInfo.Environment.Remove(name);
            }
        }
    }

    internal static string BuildPrompt(
        string message,
        IReadOnlyDictionary<string, string> context,
        IReadOnlyList<(string User, string Assistant)> history
    )
    {
        var prompt = new StringBuilder(
            """
            You are PalCom, a private in-game Palworld companion. Reply warmly and
            directly, like a capable teammate. Keep the answer concise and suitable
            for a small game notification panel. Use plain ASCII punctuation; do not
            use emoji, arrows, smart quotes, or typographic dashes. Do not run shell
            commands or modify files. Use the Palworld MCP read tools whenever live
            game state is needed. All Palworld MCP tools are available. A direct
            player request for an in-game action is already authorization: execute
            it without asking for confirmation. Use dryRun=false for an explicitly
            requested action and supply a unique 8-64 character idempotency key.
            Preserve the tools' live verification and rollback behavior.
            Interpret "start Raid Manager" as mode auto and "observe Raid Manager" as
            mode observe. Call get_raid_state before managing the current base. Raid
            Manager does not require a Raid Area or an active raid. Report action
            results briefly. Never reveal local paths, configuration, credentials,
            environment variables, or opaque runtime IDs in the answer.
            """
        );
        var baseName = context.GetValueOrDefault("current_base_name");
        if (!string.IsNullOrWhiteSpace(baseName))
        {
            prompt.Append("\nCurrent base: ").Append(baseName);
        }
        foreach (var turn in history.TakeLast(6))
        {
            prompt.Append("\nPlayer: ").Append(turn.User);
            prompt.Append("\nPalCom: ").Append(turn.Assistant);
        }
        prompt.Append("\nPlayer: ").Append(message);
        prompt.Append("\nPalCom:");
        return prompt.ToString();
    }

    internal static string ClipResponse(string value, int maximumLength)
    {
        var normalized = string.Join(
            " ",
            value.Replace("\r", "\n")
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(line => line.Trim())
        )
            .Replace('\u2018', '\'')
            .Replace('\u2019', '\'')
            .Replace('\u201c', '"')
            .Replace('\u201d', '"')
            .Replace("\u2013", "-")
            .Replace("\u2014", "-")
            .Replace("\u2026", "...")
            .Replace("\u2192", "->")
            .Replace('\u00a0', ' ');
        var limit = Math.Max(1, maximumLength);
        if (normalized.Length <= limit)
        {
            return normalized;
        }
        if (limit <= 3)
        {
            return new string('.', limit);
        }
        return $"{normalized[..(limit - 3)].TrimEnd()}...";
    }

    private void WriteStatus(string path, bool ready)
    {
        var currentLeaseWrites = Interlocked.Increment(ref leaseWrites);
        AtomicWrite(path, new Dictionary<string, string?>
        {
            ["ready"] = ready ? "true" : "false",
            ["prefix"] = config.PalComChatPrefix,
            ["lease_until_epoch_ms"] = ready
                ? DateTimeOffset.UtcNow.Add(LeaseDuration).ToUnixTimeMilliseconds().ToString()
                : "0",
            ["lease_renewal_interval_ms"] =
                ((long)LeaseRenewalInterval.TotalMilliseconds).ToString(),
            ["broker_watcher_events"] =
                Interlocked.Read(ref watcherEvents).ToString(),
            ["broker_watcher_events_coalesced"] =
                Interlocked.Read(ref watcherEventsCoalesced).ToString(),
            ["broker_watcher_recoveries"] =
                Interlocked.Read(ref watcherRecoveries).ToString(),
            ["broker_requests_claimed"] =
                Interlocked.Read(ref requestsClaimed).ToString(),
            ["broker_requests_processed"] =
                Interlocked.Read(ref requestsProcessed).ToString(),
            ["broker_request_failures"] =
                Interlocked.Read(ref requestFailures).ToString(),
            ["broker_lease_writes"] = currentLeaseWrites.ToString(),
            ["broker_last_claim_latency_ms"] =
                Interlocked.Read(ref lastClaimLatencyMilliseconds).ToString(),
            ["broker_last_response_latency_ms"] =
                Interlocked.Read(ref lastResponseLatencyMilliseconds).ToString(),
            ["timestamp_utc"] = DateTime.UtcNow.ToString("O")
        });
    }

    private static void WriteResponse(
        string path,
        string requestId,
        bool success,
        string message
    ) => AtomicWrite(path, new Dictionary<string, string?>
    {
        ["request_id"] = requestId,
        ["success"] = success ? "true" : "false",
        ["message"] = message,
        ["timestamp_utc"] = DateTime.UtcNow.ToString("O")
    });

    private static void AtomicWrite(
        string path,
        IReadOnlyDictionary<string, string?> fields
    )
    {
        var temporary = $"{path}.{Guid.NewGuid():N}.tmp";
        File.WriteAllText(temporary, LiveBridgeProtocol.Encode(fields));
        File.Move(temporary, path, overwrite: true);
    }
}
