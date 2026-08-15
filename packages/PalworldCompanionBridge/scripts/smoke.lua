-- Offline smoke test for the Companion Bridge UE4SS entry point.
--
-- UE4SS is not required. Every engine global the mod touches is guarded, so a
-- plain Lua interpreter can load the chunk, run its initialization path, and
-- drive real commands through the scheduler's command mailbox. No game objects
-- exist here, which is the point: each reflection read must fail safely and
-- report a normal protocol response instead of raising.
--
-- Usage: lua5.4 scripts/smoke.lua <mailbox-directory> <main.lua path>

local mailbox_root = assert(arg[1], "mailbox directory is required")
local entry_point = assert(arg[2], "main.lua path is required")

local real_getenv = os.getenv
os.getenv = function(name)
    if name == "LOCALAPPDATA" then
        return mailbox_root
    end
    return real_getenv(name)
end

-- The mod builds Windows mailbox paths, so on other platforms these become
-- ordinary files whose names contain backslashes. That is fine for the test.
local separator = package.config:sub(1, 1) == "\\" and "\\" or "\\"
local mailbox = mailbox_root .. separator .. "PalworldCompanionBridge"

local scheduled_tick = nil
LoopAsync = function(_, callback)
    scheduled_tick = callback
end
ExecuteInGameThread = function(callback)
    callback()
end
FindObjects = function()
    return {}
end
FindFirstOf = function()
    return nil
end
FindAllOf = function()
    return {}
end
StaticFindObject = function()
    return nil
end
RegisterHook = function()
    return 0, 0
end
UnregisterHook = function() end
NotifyOnNewObject = function() end
RegisterKeyBind = function() end

local muted_print = print
print = function() end

local failures = {}
local function check(condition, description)
    if not condition then
        table.insert(failures, description)
    end
end

local loaded, load_error = pcall(dofile, entry_point)
if not loaded then
    muted_print("smoke: load failed: " .. tostring(load_error))
    os.exit(1)
end

local source_file = io.open(entry_point, "rb")
check(source_file ~= nil, "could not inspect the bridge guidance text")
if source_file ~= nil then
    local source = source_file:read("a")
    source_file:close()
    for _, guidance in ipairs({
        "liveBridgeEnabled=true",
        "palComChatEnabled=true",
        "palcom_prefixes",
        "%LOCALAPPDATA%\\\\PalworldCompanionBridge\\\\palcom-launch.cmd",
        "palworld-mcp-server.exe --palcom-agent",
    }) do
        check(
            string.find(source, guidance, 1, true) ~= nil,
            "bridge guidance is missing " .. guidance
        )
    end
end
check(type(scheduled_tick) == "function", "the mod registered no scheduler")
if type(scheduled_tick) ~= "function" then
    muted_print("smoke: " .. failures[1])
    os.exit(1)
end

local function send(fields)
    local keys = {}
    for key in pairs(fields) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local lines = {"PALWORLD_COMPANION_BRIDGE/1"}
    for _, key in ipairs(keys) do
        table.insert(lines, key .. "=" .. fields[key])
    end
    local command = assert(io.open(mailbox .. separator .. "command.pcb", "wb"))
    command:write(table.concat(lines, "\n") .. "\n")
    command:close()

    local response_path = mailbox .. separator .. "response.pcb"
    os.remove(response_path)
    local ticked, tick_error = pcall(scheduled_tick)
    if not ticked then
        return nil, tostring(tick_error)
    end
    local response = io.open(response_path, "rb")
    if response == nil then
        return nil, "no response was written"
    end
    local payload = response:read("a")
    response:close()
    local fields_out = {}
    for line in string.gmatch(payload, "([^\n]+)") do
        local key, value = string.match(line, "^([^=]+)=(.*)$")
        if key ~= nil then
            fields_out[key] = value
        end
    end
    return fields_out, nil
end

local function expect(name, request, assertions)
    local response, send_error = send(request)
    if response == nil then
        table.insert(failures, name .. ": " .. send_error)
        return
    end
    assertions(response, name)
end

local MANAGER_STATES = {
    ["off"] = true,
    ["deploying"] = true,
    ["active"] = true,
    ["waiting_for_reserves"] = true,
}

expect(
    "get_raid_state default",
    {
        action = "get_raid_state",
        command_id = "1",
        dry_run = "true",
        idempotency_key = "smoke-1",
        include_probe = "false",
        include_reserves = "false",
    },
    function(response, name)
        check(response.success == "true", name .. " did not succeed")
        check(
            response.data_surface_probe == nil,
            name .. " emitted probe fields without include_probe"
        )
        check(
            response.data_reserves_live ~= nil,
            name .. " did not report its reserve source"
        )
        check(
            MANAGER_STATES[response.data_manager_status or ""] == true,
            name .. " reported an unknown manager state: " ..
                tostring(response.data_manager_status)
        )
    end
)

expect(
    "get_raid_state with probe and reserves",
    {
        action = "get_raid_state",
        command_id = "2",
        dry_run = "true",
        idempotency_key = "smoke-2",
        include_probe = "true",
        include_reserves = "true",
    },
    function(response, name)
        check(response.success == "true", name .. " did not succeed")
        check(
            response.data_surface_probe ~= nil,
            name .. " dropped the requested probe fields"
        )
        check(
            response.data_reserves_live == "true",
            name .. " did not scan the Palbox when asked"
        )
    end
)

expect(
    "set_raid_manager without a live base",
    {
        action = "set_raid_manager",
        command_id = "3",
        dry_run = "true",
        idempotency_key = "smoke-3",
        mode = "observe",
    },
    function(response, name)
        check(
            response.success == "false",
            name .. " armed without a loaded worker roster"
        )
    end
)

expect(
    "set_raid_manager off",
    {
        action = "set_raid_manager",
        command_id = "4",
        dry_run = "false",
        idempotency_key = "smoke-4",
        mode = "off",
    },
    function(response, name)
        check(response.success == "true", name .. " did not succeed")
        check(
            response.data_mode == "off",
            name .. " did not report the stopped mode"
        )
    end
)

expect(
    "unknown action",
    {
        action = "definitely_not_allowlisted",
        command_id = "5",
        dry_run = "true",
        idempotency_key = "smoke-5",
    },
    function(response, name)
        check(response.success == "false", name .. " was not rejected")
    end
)

for _ = 1, 5 do
    local ticked, tick_error = pcall(scheduled_tick)
    check(ticked, "bare scheduler wake raised " .. tostring(tick_error))
end

local heartbeat_file = io.open(mailbox .. separator .. "status.pcb", "rb")
check(heartbeat_file ~= nil, "no heartbeat was written")
if heartbeat_file ~= nil then
    local heartbeat = heartbeat_file:read("a")
    heartbeat_file:close()
    for _, field in ipairs({
        "bridge_version=",
        "raid_manager_mode=",
        "readiness_controller_available=",
        "scheduler_wakeups=",
        "scheduler_last_queue_build_ms=",
        "scheduler_reinforcement_integrity_effective=",
    }) do
        check(
            string.find(heartbeat, field, 1, true) ~= nil,
            "heartbeat is missing " .. field
        )
    end
end

if #failures > 0 then
    for _, failure in ipairs(failures) do
        muted_print("smoke: " .. failure)
    end
    os.exit(1)
end
muted_print("Smoke tested PalworldCompanionBridge command and scheduler paths")
