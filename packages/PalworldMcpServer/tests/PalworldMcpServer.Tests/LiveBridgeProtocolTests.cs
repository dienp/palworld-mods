namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class LiveBridgeProtocolTests
{
    [TestMethod]
    public void ProtocolRoundTripsUnicodeAndControlCharacters()
    {
        var encoded = LiveBridgeProtocol.Encode(new Dictionary<string, string?>
        {
            ["action"] = "show_notification",
            ["message"] = "Sekhmet ready\n100% ✓"
        });

        var decoded = LiveBridgeProtocol.Decode(encoded);

        Assert.AreEqual("show_notification", decoded["action"]);
        Assert.AreEqual("Sekhmet ready\n100% ✓", decoded["message"]);
    }

    [TestMethod]
    public void ProtocolRejectsUnknownHeader()
    {
        Assert.Throws<InvalidDataException>(() =>
            LiveBridgeProtocol.Decode("UNKNOWN/1\naction=ping\n")
        );
    }

    [TestMethod]
    public async Task ClientCompletesOfflineSimulatedBridgeRoundTrip()
    {
        var directory = TemporaryDirectory();
        try
        {
            var config = new PalworldConfig
            {
                LiveBridgeEnabled = true,
                LiveBridgeDirectory = directory,
                LiveBridgeTimeoutMilliseconds = 3000
            };
            var bridge = new LiveBridgeClient(config);
            var simulator = SimulateOneResponse(
                directory,
                new Dictionary<string, string?>
                {
                    ["success"] = "true",
                    ["message"] = "Live player context read.",
                    ["data_player_id"] = "42",
                    ["data_current_base_id"] = "BASE-001",
                    ["data_current_base_name"] = "Main"
                }
            );

            var result = await bridge.GetPlayerContextAsync(CancellationToken.None);
            await simulator;

            Assert.IsTrue(result.Success);
            Assert.AreEqual("42", result.Data["player_id"]);
            Assert.AreEqual("BASE-001", result.Data["current_base_id"]);
            Assert.AreEqual("Main", result.Data["current_base_name"]);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task ClientRejectsWriteWhenServerOptInIsDisabled()
    {
        var directory = TemporaryDirectory();
        try
        {
            var bridge = new LiveBridgeClient(new PalworldConfig
            {
                LiveBridgeEnabled = true,
                LiveBridgeWriteEnabled = false,
                LiveBridgeDirectory = directory
            });

            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                bridge.ShowNotificationAsync(
                    "Worker ready.",
                    1,
                    dryRun: false,
                    idempotencyKey: "worker-ready-001",
                    CancellationToken.None
                )
            );
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task ClientReplaysCompletedWriteByIdempotencyKey()
    {
        var directory = TemporaryDirectory();
        try
        {
            var bridge = new LiveBridgeClient(new PalworldConfig
            {
                LiveBridgeEnabled = true,
                LiveBridgeWriteEnabled = true,
                LiveBridgeDirectory = directory,
                LiveBridgeTimeoutMilliseconds = 3000
            });
            var simulator = SimulateOneResponse(
                directory,
                new Dictionary<string, string?>
                {
                    ["success"] = "true",
                    ["message"] = "Notification displayed.",
                    ["data_displayed"] = "true"
                }
            );

            var first = await bridge.ShowNotificationAsync(
                "Worker ready.",
                1,
                dryRun: false,
                idempotencyKey: "worker-ready-002",
                CancellationToken.None
            );
            await simulator;
            var replay = await bridge.ShowNotificationAsync(
                "Worker ready.",
                1,
                dryRun: false,
                idempotencyKey: "worker-ready-002",
                CancellationToken.None
            );

            Assert.IsTrue(first.Success);
            Assert.IsTrue(replay.Success);
            Assert.AreEqual(first.Message, replay.Message);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task ClientRejectsUnsafeDryRunIdempotencyKey()
    {
        var directory = TemporaryDirectory();
        try
        {
            var bridge = new LiveBridgeClient(new PalworldConfig
            {
                LiveBridgeEnabled = true,
                LiveBridgeDirectory = directory
            });

            await Assert.ThrowsAsync<ArgumentException>(() =>
                bridge.ShowNotificationAsync(
                    "Worker ready.",
                    1,
                    dryRun: true,
                    idempotencyKey: "..\\outside",
                    CancellationToken.None
                )
            );
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task ClientReadsLiveBaseCatalogAndInventory()
    {
        var directory = TemporaryDirectory();
        try
        {
            var bridge = new LiveBridgeClient(new PalworldConfig
            {
                LiveBridgeEnabled = true,
                LiveBridgeDirectory = directory,
                LiveBridgeTimeoutMilliseconds = 3000
            });
            var listSimulator = SimulateOneResponse(
                directory,
                new Dictionary<string, string?>
                {
                    ["success"] = "true",
                    ["data_base_count"] = "1",
                    ["data_bases"] = "BASE-001~Main~3~DISPENSER-001~true",
                    ["data_inventory_capable_base_count"] = "1"
                }
            );

            var bases = await bridge.ListBasesAsync(CancellationToken.None);
            await listSimulator;

            var inventorySimulator = SimulateOneResponse(
                directory,
                new Dictionary<string, string?>
                {
                    ["success"] = "true",
                    ["data_base_id"] = "BASE-001",
                    ["data_items"] = "Wood~120"
                }
            );
            var inventory = await bridge.GetBaseInventorySnapshotAsync(
                "BASE-001",
                CancellationToken.None
            );
            await inventorySimulator;

            Assert.AreEqual("1", bases.Data["base_count"]);
            Assert.AreEqual(
                "BASE-001~Main~3~DISPENSER-001~true",
                bases.Data["bases"]
            );
            Assert.AreEqual(
                "1",
                bases.Data["inventory_capable_base_count"]
            );
            Assert.AreEqual("BASE-001", inventory.Data["base_id"]);
            Assert.AreEqual("Wood~120", inventory.Data["items"]);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestMethod]
    public async Task ClientReadsRaidStateAndStartsObserveMode()
    {
        var directory = TemporaryDirectory();
        try
        {
            var bridge = new LiveBridgeClient(new PalworldConfig
            {
                LiveBridgeEnabled = true,
                LiveBridgeWriteEnabled = true,
                LiveBridgeDirectory = directory,
                LiveBridgeTimeoutMilliseconds = 3000
            });
            var readSimulator = SimulateOneResponse(
                directory,
                new Dictionary<string, string?>
                {
                    ["success"] = "true",
                    ["data_gate_ready"] = "true",
                    ["data_raid_active"] = "true",
                    ["data_palbox_count"] = "1",
                    ["data_palbox_occupied_count"] = "810",
                    ["data_palbox_healthy_count"] = "809",
                    ["data_deployment_capacity"] = "50",
                    ["data_deployed_count"] = "12",
                    ["data_automatic_deployable_count"] = "38",
                    ["data_expected_fighter_queue_count"] = "797",
                    ["data_expected_fighter_queue_rebuild_interval_ms"] = "60000",
                    ["data_expected_fighter_queue_invalidated_count"] = "3",
                    ["data_manager_timeout_ms"] = "900000",
                    ["data_manager_remaining_ms"] = "812000"
                }
            );

            var state = await bridge.GetRaidStateAsync(
                includeProbe: false,
                includeReserves: true,
                CancellationToken.None
            );
            await readSimulator;

            var observeSimulator = SimulateOneResponse(
                directory,
                new Dictionary<string, string?>
                {
                    ["success"] = "true",
                    ["data_mode"] = "observe",
                    ["data_reserve_count"] = "24"
                }
            );
            var observe = await bridge.SetRaidManagerAsync(
                "observe",
                [
                    new RaidReserveCandidate(
                        "PAL-001",
                        60,
                        "Jetragon",
                        ""
                    )
                ],
                dryRun: false,
                idempotencyKey: "raid-observe-001",
                CancellationToken.None
            );
            await observeSimulator;

            Assert.AreEqual("true", state.Data["raid_active"]);
            Assert.AreEqual("1", state.Data["palbox_count"]);
            Assert.AreEqual("809", state.Data["palbox_healthy_count"]);
            Assert.AreEqual("50", state.Data["deployment_capacity"]);
            Assert.AreEqual("38", state.Data["automatic_deployable_count"]);
            Assert.AreEqual(
                "60000",
                state.Data["expected_fighter_queue_rebuild_interval_ms"]
            );
            Assert.AreEqual(
                "3",
                state.Data["expected_fighter_queue_invalidated_count"]
            );
            Assert.AreEqual("900000", state.Data["manager_timeout_ms"]);
            Assert.AreEqual("observe", observe.Data["mode"]);
            Assert.AreEqual("24", observe.Data["reserve_count"]);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static async Task SimulateOneResponse(
        string directory,
        IReadOnlyDictionary<string, string?> responseData
    )
    {
        var commandPath = Path.Combine(directory, "command.pcb");
        var responsePath = Path.Combine(directory, "response.pcb");
        var deadline = DateTime.UtcNow.AddSeconds(2);
        while (!File.Exists(commandPath) && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20);
        }
        Assert.IsTrue(File.Exists(commandPath), "The MCP client did not submit a command.");

        var command = LiveBridgeProtocol.Decode(await File.ReadAllTextAsync(commandPath));
        File.Delete(commandPath);
        var response = new Dictionary<string, string?>(responseData, StringComparer.Ordinal)
        {
            ["action"] = command["action"],
            ["command_id"] = command["command_id"],
            ["dry_run"] = command["dry_run"],
            ["idempotency_key"] = command["idempotency_key"]
        };
        await File.WriteAllTextAsync(responsePath, LiveBridgeProtocol.Encode(response));
    }

    private static string TemporaryDirectory()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            $"palworld-companion-bridge-test-{Guid.NewGuid():N}"
        );
        Directory.CreateDirectory(directory);
        return directory;
    }
}
