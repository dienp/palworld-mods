import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const executableArgument = process.argv[2];
if (!executableArgument) {
  console.error("Usage: node scripts/smoke-test-release.mjs <server.exe>");
  process.exit(2);
}

const executable = path.resolve(executableArgument);
const bridgeEntryPoint = path.join(
  path.dirname(executable),
  "ue4ss-mod",
  "PalworldCompanionBridge",
  "Scripts",
  "main.lua",
);
if (!existsSync(bridgeEntryPoint)) {
  console.error(`Packaged UE4SS bridge is missing: ${bridgeEntryPoint}`);
  process.exit(1);
}
const child = spawn(executable, [], {
  env: { ...process.env, PALWORLD_MCP_CONFIG: "" },
  stdio: ["pipe", "pipe", "pipe"],
});

let stdout = "";
let stderr = "";
let finished = false;

const timeout = setTimeout(() => {
  finish(1, `Timed out waiting for the packaged MCP server.\n${stderr}`);
}, 30_000);

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

child.on("error", (error) => {
  finish(1, error.stack ?? error.message);
});

child.on("exit", (code) => {
  if (!finished) {
    finish(1, `Packaged MCP server exited early with code ${code}.\n${stderr}`);
  }
});

child.stdout.on("data", (chunk) => {
  stdout += chunk.toString();

  for (;;) {
    const newline = stdout.indexOf("\n");
    if (newline < 0) {
      break;
    }

    const line = stdout.slice(0, newline).trim();
    stdout = stdout.slice(newline + 1);
    if (!line) {
      continue;
    }

    let message;
    try {
      message = JSON.parse(line);
    } catch {
      finish(1, `Packaged server wrote non-JSON data to stdout: ${line}`);
      return;
    }

    if (message.id === 1) {
      send({ jsonrpc: "2.0", method: "notifications/initialized" });
      send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
    } else if (message.id === 2) {
      const tools = message.result?.tools ?? [];
      if (tools.length !== 16) {
        finish(1, `Expected 16 MCP tools, received ${tools.length}.`);
        return;
      }

      const expectedTools = [
        "get_status",
        "search_pals",
        "get_pal",
        "search_pal_data",
        "plan_breeding",
        "estimate_breeding",
        "get_player_state",
        "list_bases",
        "get_base_state",
        "get_raid_state",
        "discover_palcom_functions",
        "manage_raid",
        "swap_raid_pal",
        "move_pal",
        "assign_pal",
        "notify_player",
      ];
      for (const toolName of expectedTools) {
        if (!tools.some((tool) => tool.name === toolName)) {
          finish(1, `Missing packaged tool ${toolName}.`);
          return;
        }
      }

      const planTool = tools.find((tool) => tool.name === "plan_breeding");
      const planProperties = planTool?.inputSchema?.properties ?? {};
      if (
        !planProperties.searchMode ||
        planProperties.cancellationToken ||
        planProperties.maxBreedingSteps?.default !== 2 ||
        planProperties.searchMode?.default !== "fast" ||
        planProperties.role?.default !== "custom"
      ) {
        finish(1, "The packaged breeding-plan schema has invalid search defaults.");
        return;
      }

      const assignmentTool = tools.find(
        (tool) => tool.name === "assign_pal",
      );
      const assignmentProperties =
        assignmentTool?.inputSchema?.properties ?? {};
      if (
        assignmentProperties.dryRun?.default !== false ||
        !assignmentProperties.baseId ||
        !assignmentProperties.palId ||
        !assignmentProperties.stationId
      ) {
        finish(1, "The packaged assignment schema is invalid.");
        return;
      }

      const rosterTool = tools.find(
        (tool) => tool.name === "move_pal",
      );
      const rosterProperties = rosterTool?.inputSchema?.properties ?? {};
      if (
        rosterProperties.dryRun?.default !== false ||
        !rosterProperties.destination ||
        !rosterProperties.baseId ||
        !rosterProperties.palId
      ) {
        finish(1, "The packaged roster schema is invalid.");
        return;
      }

      const raidManagerTool = tools.find(
        (tool) => tool.name === "manage_raid",
      );
      const raidManagerProperties =
        raidManagerTool?.inputSchema?.properties ?? {};
      if (
        raidManagerProperties.dryRun?.default !== true ||
        !raidManagerProperties.mode
      ) {
        finish(1, "The packaged Raid Manager schema is invalid.");
        return;
      }

      const raidSwapTool = tools.find(
        (tool) => tool.name === "swap_raid_pal",
      );
      const raidSwapProperties =
        raidSwapTool?.inputSchema?.properties ?? {};
      if (
        raidSwapProperties.dryRun?.default !== true ||
        !raidSwapProperties.baseId ||
        !raidSwapProperties.downedPalId ||
        !raidSwapProperties.reservePalId
      ) {
        finish(1, "The packaged raid-swap schema is invalid.");
        return;
      }

      send({
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: {
          name: "get_status",
          arguments: {},
        },
      });
    } else if (message.id === 3) {
      const text = message.result?.content?.find(
        (item) => item.type === "text",
      )?.text;
      const status = text ? JSON.parse(text) : null;
      if (
        message.result?.isError ||
        typeof status?.save?.ready !== "boolean" ||
        typeof status?.live?.configured !== "boolean"
      ) {
        finish(1, "The packaged status tool returned an invalid response.");
        return;
      }

      finish(
        0,
        "Packaged MCP smoke test passed: concise 16-tool surface, consolidated status/base/raid schemas, and atomic action schemas.",
      );
    }
  }
});

function send(message) {
  child.stdin.write(`${JSON.stringify(message)}\n`);
}

function finish(exitCode, message) {
  if (finished) {
    return;
  }

  finished = true;
  clearTimeout(timeout);
  child.kill();
  const output = exitCode === 0 ? console.log : console.error;
  output(message);
  process.exitCode = exitCode;
}

send({
  jsonrpc: "2.0",
  id: 1,
  method: "initialize",
  params: {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "release-smoke-test", version: "1.0" },
  },
});
