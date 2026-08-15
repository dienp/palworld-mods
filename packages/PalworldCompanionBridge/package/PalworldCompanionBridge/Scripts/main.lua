local MOD_NAME = "PalworldCompanionBridge"
local MOD_VERSION = "0.1.0-dev.116"
local PROTOCOL_HEADER = "PALWORLD_COMPANION_BRIDGE/1"

local CONFIG = {
    poll_interval_ms = 500,
    heartbeat_interval_ms = 2000,
    readiness_refresh_interval_ms = 10000,
    maximum_message_length = 240,
    maximum_inventory_items = 512,
    maximum_inventory_slots_per_container = 512,
    base_membership_ttl_ms = 15000,
    base_summary_ttl_ms = 5000,
    palcom_response_timeout_ms = 90000,
    palcom_response_initial_interval_ms = 500,
    palcom_response_working_interval_ms = 1000,
    palcom_response_slow_interval_ms = 2000,
    palcom_response_working_after_ms = 3000,
    palcom_response_slow_after_ms = 30000,
    palcom_broker_start_timeout_ms = 15000,
    palcom_broker_start_retry_ms = 15000,
    raid_manager_integrity_interval_ms = 60000,
    raid_queue_rebuild_interval_ms = 60000,
    raid_manager_timeout_ms = 15 * 60 * 1000,
    raid_bulk_deploy_batch_size = 1,
    raid_bulk_deploy_interval_ms = 1000,
    raid_reserve_queue_capacity = 96,
    -- Keep diagnostics in source. Disable them through configuration for release.
    debug_enabled = true,
    debug_notifications = true,
    debug_console = true,
}

local local_app_data = os.getenv("LOCALAPPDATA")
local bridge_directory = local_app_data and
    (local_app_data .. "\\PalworldCompanionBridge") or nil
local paths = bridge_directory and {
    command = bridge_directory .. "\\command.pcb",
    response = bridge_directory .. "\\response.pcb",
    heartbeat = bridge_directory .. "\\status.pcb",
    settings = bridge_directory .. "\\bridge-settings.pcb",
    base_names = bridge_directory .. "\\base-names.pcb",
    palcom_request = bridge_directory .. "\\palcom-request.pcb",
    palcom_response = bridge_directory .. "\\palcom-response.pcb",
    palcom_status = bridge_directory .. "\\palcom-status.pcb",
    palcom_bootstrap = bridge_directory .. "\\palcom-bootstrap.pcb",
    palcom_functions = bridge_directory .. "\\palcom-functions.txt",
    audit = bridge_directory .. "\\lua-audit.log",
} or {}

local cached_log_manager = nil
local cached_player_group_id = ""
local base_name_registry = nil
local processed_actions = {}
local palcom_request_counter = 0
local palcom_pending = nil
local palcom_last_start_attempt_ms = 0
local discover_palcom_functions = nil
local bridge_readiness = {
    controller_available = false,
    game_ready = false,
    inventory_available = false,
    player_state_available = false,
    refreshed_at_ms = 0,
    world_key = "",
}
local raid_detection_state = {
    base_id = "",
    instance = "",
    phase = "",
    phase_state = "",
    sampled_at_ms = 0,
    state_machine = "",
}
local scheduler = {
    next_heartbeat_at_ms = 0,
    next_readiness_at_ms = 0,
}
local scheduler_metrics = {
    wakeups = 0,
    command_file_probes = 0,
    commands_received = 0,
    palcom_response_probes = 0,
    palcom_responses_received = 0,
    palcom_response_timeouts = 0,
    last_palcom_response_latency_ms = 0,
    heartbeat_writes = 0,
    readiness_refreshes = 0,
    readiness_failures = 0,
    reinforcement_event_requests = 0,
    reinforcement_event_coalesced = 0,
    reinforcement_event_passes = 0,
    reinforcement_integrity_passes = 0,
    -- Integrity passes that actually had work to do. Every one of these is
    -- reinforcement the event hooks failed to request, so this is the
    -- measurement that gates removing the periodic fallback.
    reinforcement_integrity_effective = 0,
    reinforcement_hooks_installed = 0,
    roster_scans = 0,
    palbox_scans = 0,
    last_reinforcement_pass_ms = 0,
    last_queue_build_ms = 0,
    worker_trace_network_moves = 0,
    worker_trace_network_swaps = 0,
    worker_trace_slot_updates = 0,
    worker_trace_spawn_requests = 0,
    worker_trace_spawn_callbacks = 0,
    worker_trace_despawn_requests = 0,
    worker_trace_director_added = 0,
    worker_trace_director_removed = 0,
    worker_trace_director_reflected = 0,
    worker_trace_model_added = 0,
    worker_trace_observer_container = 0,
    worker_trace_observer_container_slots = 0,
    worker_trace_observer_container_size = 0,
}
-- Raid Manager has exactly four states. `mode` is what the player asked for
-- (off, observe, or auto); `manager_state` is what the manager is doing now.
local MANAGER_STATE_OFF = "off"
local MANAGER_STATE_DEPLOYING = "deploying"
local MANAGER_STATE_ACTIVE = "active"
local MANAGER_STATE_WAITING = "waiting_for_reserves"

local raid_manager = {
    mode = "off",
    base_id = "",
    stopped_reason = "",
    healthy_palbox_count = 0,
    palbox_occupied_count = 0,
    deployment_capacity = 0,
    deployed_count = 0,
    queue_built_at_ms = 0,
    queue_rebuild_count = 0,
    queue_rebuild_reason = "",
    invalidated_reserves = {},
    invalidated_reserve_count = 0,
    started_at_ms = 0,
    last_check_at_ms = 0,
    replacement_count = 0,
    deployment_count = 0,
    sequence = 0,
    manager_state = MANAGER_STATE_OFF,
    reinforcement_pass_requested = false,
    reinforcement_request_reason = "",
    reinforcement_pass_running = false,
    raid_phase_missing_samples = 0,
    raid_phase_seen_battle = false,
    raid_phase_state = "",
    next_bulk_deploy_at_ms = 0,
    zero_healthy_warned = false,
    reserves = {},
    roster_model = nil,
    roster_director = nil,
    roster_container = nil,
    worker_move_identity = nil,
}
local base_membership_cache = {
    bases = {},
    built_at_ms = 0,
    generation = 0,
    world_key = "",
}
local base_summary_cache = {}
local base_cache_stats = {
    membership_hits = 0,
    membership_misses = 0,
    membership_rebuilds = 0,
    summary_hits = 0,
    summary_misses = 0,
    invalidations = 0,
    last_invalidation_reason = "",
    last_invalidated_at = "",
}

local function now_ms()
    return os.time() * 1000
end

local function timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function unwrap(value)
    if value == nil then
        return nil
    end
    local ok, unwrapped = pcall(function()
        return value:get()
    end)
    return ok and unwrapped or value
end

local function is_valid(object)
    object = unwrap(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid
end

local function full_name(object)
    object = unwrap(object)
    if not is_valid(object) then
        return "<unavailable>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or tostring(object)
end

local function percent_encode(value)
    return string.gsub(tostring(value or ""), "([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

local function percent_decode(value)
    return string.gsub(value or "", "%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end)
end

local function encode_message(fields)
    local keys = {}
    for key, _ in pairs(fields) do
        table.insert(keys, key)
    end
    table.sort(keys)

    local lines = {PROTOCOL_HEADER}
    for _, key in ipairs(keys) do
        table.insert(lines, key .. "=" .. percent_encode(fields[key]))
    end
    return table.concat(lines, "\n") .. "\n"
end

local function decode_message(payload)
    local fields = {}
    local first = true
    for line in string.gmatch(payload or "", "([^\r\n]+)") do
        if first then
            if line ~= PROTOCOL_HEADER then
                return nil, "unsupported protocol header"
            end
            first = false
        else
            local separator = string.find(line, "=", 1, true)
            if separator == nil or separator <= 1 then
                return nil, "malformed protocol field"
            end
            local key = string.sub(line, 1, separator - 1)
            fields[key] = percent_decode(string.sub(line, separator + 1))
        end
    end
    if first then
        return nil, "empty protocol payload"
    end
    return fields, nil
end

local function read_file(path)
    if path == nil then
        return nil
    end
    local file = io.open(path, "rb")
    if file == nil then
        return nil
    end
    local payload = file:read("*a")
    file:close()
    return payload
end

local function atomic_write(path, payload)
    if path == nil then
        return false, "bridge directory unavailable"
    end
    local temporary = path .. ".tmp"
    local file, open_error = io.open(temporary, "wb")
    if file == nil then
        return false, tostring(open_error)
    end
    file:write(payload)
    file:flush()
    file:close()
    os.remove(path)
    local renamed, rename_error = os.rename(temporary, path)
    return renamed ~= nil, rename_error and tostring(rename_error) or nil
end

local function append_audit(state, action, idempotency_key, message)
    if paths.audit == nil then
        return
    end
    local file = io.open(paths.audit, "ab")
    if file == nil then
        return
    end
    local clean_message = string.gsub(tostring(message or ""), "[\r\n|]", " ")
    file:write(table.concat({
        timestamp(),
        tostring(state),
        tostring(action),
        tostring(idempotency_key),
        clean_message,
    }, "|") .. "\n")
    file:close()
end

local function get_settings()
    local settings = {
        enabled = true,
        palcom_lazy_start_enabled = true,
        write_actions_enabled = true,
    }
    local payload = read_file(paths.settings)
    if payload == nil then
        return settings
    end
    local decoded = decode_message(payload)
    if decoded == nil then
        return settings
    end
    settings.enabled = decoded.enabled ~= "false"
    settings.palcom_lazy_start_enabled =
        decoded.palcom_lazy_start_enabled ~= "false"
    settings.write_actions_enabled =
        decoded.write_actions_enabled ~= "false"
    return settings
end

local function debug_log(message)
    if not CONFIG.debug_enabled then
        return
    end
    local text = "[" .. MOD_NAME .. "] " .. tostring(message)
    if CONFIG.debug_console then
        print(text .. "\n")
    end
    if CONFIG.debug_notifications then
        pcall(function()
            if not is_valid(cached_log_manager) then
                cached_log_manager = FindFirstOf("PalLogManager")
            end
            if is_valid(cached_log_manager) then
                cached_log_manager:AddLog(1, FText(text), {})
            end
        end)
    end
end

local function find_local_controller()
    local fallback = nil
    local seen = {}
    for _, class_name in ipairs({
        "BP_PalPlayerController_C",
        "PalPlayerController",
    }) do
        local ok, controllers = pcall(function()
            return FindObjects(0, class_name, nil, nil, nil, false)
        end)
        if ok and type(controllers) == "table" then
            for _, controller in ipairs(controllers) do
                controller = unwrap(controller)
                local object_name = full_name(controller)
                if is_valid(controller) and
                    not seen[object_name] and
                    not string.find(object_name, "Default__", 1, true) then
                    seen[object_name] = true
                    fallback = fallback or controller
                    local is_local = false
                    pcall(function()
                        is_local = controller:IsLocalController() == true
                    end)
                    if not is_local then
                        pcall(function()
                            is_local =
                                controller:IsLocalPlayerController() == true
                        end)
                    end
                    if is_local then
                        return controller
                    end
                end
            end
        end
    end
    return fallback
end

local function find_local_player_state()
    local controller = find_local_controller()
    local state = nil
    if is_valid(controller) then
        pcall(function()
            state = unwrap(controller:GetPalPlayerState())
        end)
    end
    return state
end

local function name_string(value)
    value = unwrap(value)
    if value == nil then
        return ""
    end
    local ok, text = pcall(function()
        return value:ToString()
    end)
    return ok and tostring(text) or tostring(value)
end

local function guid_string(value)
    value = unwrap(value)
    if value == nil then
        return ""
    end
    for _, nested_name in ipairs({
        "ID",
        "InstanceId",
        "IndividualId",
        "Guid",
    }) do
        local nested = nil
        pcall(function()
            nested = unwrap(value[nested_name])
        end)
        if nested ~= nil and nested ~= value then
            local nested_guid = guid_string(nested)
            if nested_guid ~= "" then
                return nested_guid
            end
        end
    end
    local ok, result = pcall(function()
        local function part(name, index)
            local candidate = nil
            pcall(function()
                candidate = unwrap(value[name])
            end)
            if candidate == nil and type(value) == "table" then
                candidate = unwrap(value[index])
            end
            return tonumber(candidate)
        end
        local a = part("A", 1)
        local b = part("B", 2)
        local c = part("C", 3)
        local d = part("D", 4)
        if a ~= nil and b ~= nil and c ~= nil and d ~= nil then
            local function unsigned32(number)
                return number < 0 and
                    (number + 4294967296) or number
            end
            return string.format(
                "%08X-%08X-%08X-%08X",
                unsigned32(a),
                unsigned32(b),
                unsigned32(c),
                unsigned32(d)
            )
        end
        if type(value) == "table" then
            local entries = {}
            for key, entry in pairs(value) do
                table.insert(
                    entries,
                    tostring(key) .. "=" .. tostring(unwrap(entry))
                )
            end
            table.sort(entries)
            return "table{" .. table.concat(entries, ",") .. "}"
        end
        return value:ToString()
    end)
    return ok and tostring(result) or tostring(value)
end

local function find_first_valid(class_names)
    for _, class_name in ipairs(class_names) do
        local candidate = nil
        pcall(function()
            candidate = FindFirstOf(class_name)
        end)
        if is_valid(candidate) then
            return unwrap(candidate)
        end
    end
    return nil
end

local function find_valid_objects(class_names, maximum_count)
    local found = {}
    local seen = {}
    for _, class_name in ipairs(class_names) do
        local ok, objects = pcall(function()
            return FindObjects(0, class_name, nil, nil, nil, false)
        end)
        if ok and type(objects) == "table" then
            for _, object in ipairs(objects) do
                object = unwrap(object)
                if is_valid(object) then
                    local key = full_name(object)
                    if not seen[key] then
                        seen[key] = true
                        table.insert(found, object)
                        if #found >= maximum_count then
                            return found
                        end
                    end
                end
            end
        end
    end
    return found
end

local function declared_function_surface(object)
    local functions = {}
    if not is_valid(object) then
        return functions
    end
    pcall(function()
        object:GetClass():ForEachFunction(function(func)
            if #functions >= 96 then
                return true
            end
            local parameters = {}
            func:ForEachProperty(function(property)
                if #parameters >= 16 then
                    return true
                end
                table.insert(
                    parameters,
                    tostring(property:GetFName():ToString()) .. ":" ..
                    tostring(property:GetClass():GetFName():ToString())
                )
                return nil
            end)
            table.insert(
                functions,
                tostring(func:GetFName():ToString()) ..
                "(" .. table.concat(parameters, ",") .. ")"
            )
            return nil
        end)
    end)
    return functions
end

local function is_zero_guid(value)
    return value == "" or value == "00000000-00000000-00000000-00000000"
end

local function is_guid(value)
    return type(value) == "string" and
        string.match(
            value,
            "^[0-9A-Fa-f]+%-[0-9A-Fa-f]+%-[0-9A-Fa-f]+%-[0-9A-Fa-f]+$"
        ) ~= nil and
        not is_zero_guid(value)
end

local object_base_id

local function current_base_surface(label, object)
    local records = {}
    if not is_valid(object) then
        table.insert(records, label .. "~object~<unavailable>~")
        return records
    end
    pcall(function()
        local struct = object:GetClass()
        local depth = 0
        while is_valid(struct) and depth < 10 and #records < 128 do
            local class_name = tostring(struct:GetFName():ToString())
            struct:ForEachFunction(function(func)
                local name = tostring(func:GetFName():ToString())
                if string.find(name, "BaseCamp", 1, true) or
                    string.find(name, "Inside", 1, true) or
                    string.find(name, "Area", 1, true) or
                    string.find(name, "Radius", 1, true) or
                    string.find(name, "Id", 1, true) or
                    string.find(name, "ID", 1, true) then
                    local parameters = {}
                    func:ForEachProperty(function(property)
                        table.insert(
                            parameters,
                            tostring(property:GetFName():ToString()) .. ":" ..
                            tostring(property:GetClass():GetFName():ToString())
                        )
                        return nil
                    end)
                    table.insert(records, table.concat({
                        label,
                        "function",
                        class_name .. "." .. name,
                        table.concat(parameters, ","),
                    }, "~"))
                end
                return nil
            end)
            struct:ForEachProperty(function(property)
                local name = tostring(property:GetFName():ToString())
                if string.find(name, "BaseCamp", 1, true) or
                    string.find(name, "Inside", 1, true) or
                    string.find(name, "Area", 1, true) or
                    string.find(name, "Radius", 1, true) or
                    string.find(name, "Id", 1, true) or
                    string.find(name, "ID", 1, true) then
                    local value = nil
                    pcall(function()
                        value = unwrap(object[name])
                    end)
                    if value == nil then
                        pcall(function()
                            value = unwrap(object:GetPropertyValue(name))
                        end)
                    end
                    local identifier = guid_string(value)
                    table.insert(records, table.concat({
                        label,
                        "property",
                        class_name .. "." .. name,
                        is_guid(identifier) and identifier or name_string(value),
                    }, "~"))
                end
                return nil
            end)
            struct = struct:GetSuperStruct()
            depth = depth + 1
        end
    end)
    return records
end

local function resolve_current_base_id(controller, state)
    local inside_base_id = ""
    if not is_valid(controller) then
        return inside_base_id
    end
    pcall(function()
        inside_base_id = guid_string(controller:GetInsideBaseCampID())
    end)
    if not is_guid(inside_base_id) then
        inside_base_id = ""
    end
    if inside_base_id == "" then
        pcall(function()
            inside_base_id =
                guid_string(controller.NowInsideBaseCampID)
        end)
    end
    if not is_guid(inside_base_id) and
        is_valid(state) then
        pcall(function()
            inside_base_id =
                guid_string(state:GetInsideBaseCampID())
        end)
        if not is_guid(inside_base_id) then
            pcall(function()
                inside_base_id =
                    guid_string(state.NowInsideBaseCampID)
            end)
        end
    end
    if not is_guid(inside_base_id) then
        inside_base_id = ""
    end
    return inside_base_id
end

local function current_world_key()
    local controller = find_local_controller()
    if not is_valid(controller) then
        return ""
    end
    local state = nil
    pcall(function()
        state = unwrap(controller:GetPalPlayerState())
    end)
    local inside_base_id = resolve_current_base_id(controller, state)
    return full_name(controller) .. "|inside_base=" .. inside_base_id
end

local function record_base_cache_invalidation(reason)
    base_cache_stats.invalidations = base_cache_stats.invalidations + 1
    base_cache_stats.last_invalidation_reason = tostring(reason or "unknown")
    base_cache_stats.last_invalidated_at = timestamp()
end

local function invalidate_base_summaries(reason, base_id)
    if base_id ~= nil and base_id ~= "" then
        base_summary_cache[base_id] = nil
    else
        base_summary_cache = {}
    end
    record_base_cache_invalidation(reason)
end

local function invalidate_base_membership(reason)
    base_membership_cache = {
        bases = {},
        built_at_ms = 0,
        generation = base_membership_cache.generation + 1,
        world_key = "",
    }
    base_summary_cache = {}
    record_base_cache_invalidation(reason)
end

local function base_raw_name(base)
    local name = ""
    if is_valid(base) then
        pcall(function()
            name = name_string(unwrap(base:GetBaseCampName()))
        end)
    end
    return name
end

local function default_base_template_index(raw_name)
    return string.match(
        tostring(raw_name or ""),
        "新規生成拠点テンプレート名(%d+)%(仮%)"
    )
end

local function has_assigned_base_name(raw_name)
    return raw_name ~= nil and raw_name ~= "" and
        default_base_template_index(raw_name) == nil
end

local function load_base_name_registry()
    if base_name_registry ~= nil then
        return base_name_registry
    end
    base_name_registry = {names = {}}
    local decoded = decode_message(read_file(paths.base_names))
    if decoded == nil then
        return base_name_registry
    end
    for key, value in pairs(decoded) do
        local base_id = string.match(key, "^base_(.+)$")
        if is_guid(base_id) and value ~= "" then
            base_name_registry.names[base_id] = value
        end
    end
    return base_name_registry
end

local function save_base_name_registry(registry)
    local fields = {}
    for base_id, value in pairs(registry.names) do
        fields["base_" .. base_id] = value
    end
    atomic_write(paths.base_names, encode_message(fields))
end

local function apply_friendly_base_names(bases)
    local registry = load_base_name_registry()
    local used_numbers = {}
    for _, value in pairs(registry.names) do
        local number = tonumber(string.match(value, "^Base (%d+)$"))
        if number ~= nil then
            used_numbers[number] = true
        end
    end
    for _, entry in pairs(bases) do
        if has_assigned_base_name(entry.base_raw_name) then
            local number = tonumber(
                string.match(entry.base_raw_name, "^Base (%d+)$")
            )
            if number ~= nil then
                used_numbers[number] = true
            end
        end
    end

    local unassigned_ids = {}
    for base_id, entry in pairs(bases) do
        if not has_assigned_base_name(entry.base_raw_name) and
            registry.names[base_id] == nil then
            table.insert(unassigned_ids, base_id)
        end
    end
    table.sort(unassigned_ids)

    local changed = false
    local next_number = 1
    for _, base_id in ipairs(unassigned_ids) do
        while used_numbers[next_number] do
            next_number = next_number + 1
        end
        registry.names[base_id] = "Base " .. tostring(next_number)
        used_numbers[next_number] = true
        changed = true
    end
    if changed then
        save_base_name_registry(registry)
    end

    for base_id, entry in pairs(bases) do
        if has_assigned_base_name(entry.base_raw_name) then
            entry.base_name = entry.base_raw_name
        else
            entry.base_name = registry.names[base_id] or "Base"
        end
    end
end

local function friendly_base_name(raw_name, base_id)
    if has_assigned_base_name(raw_name) then
        return raw_name
    end
    local registry = load_base_name_registry()
    if is_guid(base_id) and registry.names[base_id] ~= nil then
        return registry.names[base_id]
    end
    local template_index = default_base_template_index(raw_name)
    if template_index ~= nil then
        return "Base " .. tostring(tonumber(template_index) + 1)
    end
    if is_guid(base_id) then
        return "Base " .. string.sub(base_id, 1, 8)
    end
    return "Base"
end

local function base_name(base, base_id)
    return friendly_base_name(base_raw_name(base), base_id)
end

local function model_base_id(model)
    local identifier = ""
    if is_valid(model) then
        pcall(function()
            identifier = guid_string(model:GetBaseCampIdBelongTo())
        end)
    end
    return identifier
end

local function module_container_id(module)
    local identifier = ""
    if is_valid(module) then
        pcall(function()
            identifier = guid_string(module:GetContainerId())
        end)
    end
    return identifier
end

local function model_container(model)
    local module = nil
    local container = nil
    if is_valid(model) then
        pcall(function()
            module = unwrap(model:GetItemContainerModule())
        end)
    end
    if is_valid(module) then
        pcall(function()
            container = unwrap(module:GetContainer())
        end)
        if not is_valid(container) then
            pcall(function()
                container = unwrap(module.TargetContainer)
            end)
        end
    end
    return module, container
end

local function base_model_native_id(model)
    local identifier = ""
    if is_valid(model) then
        pcall(function()
            identifier = guid_string(model:GetId())
        end)
        if not is_guid(identifier) then
            pcall(function()
                identifier = guid_string(model.ID)
            end)
        end
    end
    return is_guid(identifier) and identifier or ""
end

local function base_model_group_id(model)
    local identifier = ""
    if is_valid(model) then
        pcall(function()
            identifier = guid_string(model:GetGroupIdBelongTo())
        end)
        if not is_guid(identifier) then
            pcall(function()
                identifier = guid_string(model.GroupIdBelongTo)
            end)
        end
    end
    return is_guid(identifier) and identifier or ""
end

local function player_group()
    local controller = find_local_controller()
    local state = nil
    local guild = nil
    local identifier = ""
    if is_valid(controller) then
        pcall(function()
            state = unwrap(controller:GetPalPlayerState())
        end)
    end
    if is_valid(state) then
        pcall(function()
            guild = unwrap(state.GuildBelongTo)
        end)
    end
    if is_valid(guild) then
        pcall(function()
            identifier = guid_string(guild:GetId())
        end)
        if not is_guid(identifier) then
            pcall(function()
                identifier = guid_string(guild.ID)
            end)
        end
    end
    return is_guid(identifier) and identifier or "", guild
end

local function group_name(group_id, known_group)
    local candidates = {}
    if is_valid(known_group) then
        table.insert(candidates, known_group)
    end
    for _, group in ipairs(find_valid_objects({
        "PalGroupGuildBase",
        "PalGroupGuild",
    }, 64)) do
        table.insert(candidates, group)
    end
    for _, group in ipairs(candidates) do
        local identifier = ""
        pcall(function()
            identifier = guid_string(group:GetId())
        end)
        if not is_guid(identifier) then
            pcall(function()
                identifier = guid_string(group.ID)
            end)
        end
        if identifier == group_id then
            local value = ""
            pcall(function()
                value = name_string(group:GetGuildName())
            end)
            if value == "" then
                pcall(function()
                    value = name_string(group.GuildName)
                end)
            end
            return value
        end
    end
    return ""
end

local function base_members_include_player(model, player_uid)
    local members = nil
    local count = 0
    pcall(function()
        members = unwrap(model.PlayerUIdsExistsInsideInServer)
    end)
    if members == nil then
        return false, count
    end
    pcall(function()
        count = #members
    end)
    return false, count
end

local function resolve_player_group_id(base_models)
    local direct_group_id = player_group()
    if is_guid(direct_group_id) then
        cached_player_group_id = direct_group_id
        return direct_group_id
    end
    local occupied_models = {}
    for _, model in ipairs(base_models) do
        if not string.find(full_name(model), "Default__", 1, true) then
            local _, count = base_members_include_player(model, "")
            if count > 0 then
                table.insert(occupied_models, model)
            end
        end
    end
    if #occupied_models == 1 then
        local group_id = base_model_group_id(occupied_models[1])
        if is_guid(group_id) then
            cached_player_group_id = group_id
            return group_id
        end
    end
    return cached_player_group_id
end

local function rebuild_base_membership(world_key)
    local bases = {}
    local base_models = find_valid_objects({
        "PalBaseCampModel",
    }, 128)
    local player_group_id = resolve_player_group_id(base_models)
    for _, base in ipairs(base_models) do
        if not string.find(full_name(base), "Default__", 1, true) then
            local base_id = base_model_native_id(base)
            local group_id = base_model_group_id(base)
            if is_guid(base_id) and is_guid(player_group_id) and
                group_id == player_group_id then
                bases[base_id] = {
                    base = base,
                    base_id = base_id,
                    base_raw_name = base_raw_name(base),
                    base_name = "",
                    containers = {},
                    containers_by_id = {},
                    dispenser = nil,
                }
            end
        end
    end

    local dispensers = find_valid_objects({
        "PalMapObjectBaseCampItemDispenserModel",
    }, 64)
    for _, dispenser in ipairs(dispensers) do
        local base = nil
        pcall(function()
            base = unwrap(dispenser:GetBaseCampModelBelongTo())
        end)
        local base_id = model_base_id(dispenser)
        if is_valid(base) and not is_zero_guid(base_id) then
            if not is_guid(player_group_id) or bases[base_id] ~= nil then
                bases[base_id] = bases[base_id] or {
                    base = base,
                    base_id = base_id,
                    base_raw_name = base_raw_name(base),
                    base_name = "",
                    containers = {},
                    containers_by_id = {},
                    dispenser = nil,
                }
                bases[base_id].dispenser = dispenser
            end
        end
    end

    apply_friendly_base_names(bases)

    local storage_models = find_valid_objects({
        "PalMapObjectItemChestModel",
    }, 1024)
    for _, model in ipairs(storage_models) do
        local base_id = model_base_id(model)
        local base_entry = bases[base_id]
        if base_entry ~= nil then
            local module, container = model_container(model)
            local container_id = module_container_id(module)
            local is_guild_chest = false
            if is_valid(container) then
                pcall(function()
                    is_guild_chest =
                        container.bIsGuildChestContainer == true
                end)
            end
            if is_valid(module) and is_valid(container) and
                not is_zero_guid(container_id) and
                not is_guild_chest and
                base_entry.containers_by_id[container_id] == nil then
                local member = {
                    container = container,
                    container_id = container_id,
                    model = model,
                    module = module,
                }
                base_entry.containers_by_id[container_id] = member
                table.insert(base_entry.containers, member)
            end
        end
    end

    base_membership_cache = {
        bases = bases,
        built_at_ms = now_ms(),
        generation = base_membership_cache.generation + 1,
        world_key = world_key,
    }
    base_summary_cache = {}
    base_cache_stats.membership_rebuilds =
        base_cache_stats.membership_rebuilds + 1
    return base_membership_cache
end

local function base_membership_is_valid(cache, world_key)
    if cache.world_key ~= world_key or world_key == "" then
        return false, "player-world-changed"
    end
    if now_ms() - cache.built_at_ms >= CONFIG.base_membership_ttl_ms then
        return false, "membership-ttl-expired"
    end
    for base_id, base_entry in pairs(cache.bases) do
        if not is_valid(base_entry.base) then
            return false, "base-ownership-or-stream-state-changed"
        end
        if base_entry.dispenser ~= nil and
            (not is_valid(base_entry.dispenser) or
                model_base_id(base_entry.dispenser) ~= base_id) then
            return false, "base-ownership-or-stream-state-changed"
        end
        for _, member in ipairs(base_entry.containers) do
            if not is_valid(member.model) or
                not is_valid(member.module) or
                not is_valid(member.container) or
                model_base_id(member.model) ~= base_id or
                module_container_id(member.module) ~= member.container_id then
                return false, "container-destroyed-or-streamed"
            end
        end
    end
    return true, nil
end

local function ensure_base_membership()
    local world_key = current_world_key()
    local valid, reason =
        base_membership_is_valid(base_membership_cache, world_key)
    if valid then
        base_cache_stats.membership_hits =
            base_cache_stats.membership_hits + 1
        return base_membership_cache, true
    end
    base_cache_stats.membership_misses =
        base_cache_stats.membership_misses + 1
    if base_membership_cache.built_at_ms > 0 then
        record_base_cache_invalidation(reason)
    end
    return rebuild_base_membership(world_key), false
end

local function cache_metadata(membership_hit, summary_hit)
    return {
        data_cache_membership_hit =
            membership_hit and "true" or "false",
        data_cache_summary_hit =
            summary_hit and "true" or "false",
        data_cache_membership_ttl_ms =
            tostring(CONFIG.base_membership_ttl_ms),
        data_cache_summary_ttl_ms =
            tostring(CONFIG.base_summary_ttl_ms),
        data_cache_membership_generation =
            tostring(base_membership_cache.generation),
        data_cache_context_key = base_membership_cache.world_key,
        data_cache_membership_hits =
            tostring(base_cache_stats.membership_hits),
        data_cache_membership_misses =
            tostring(base_cache_stats.membership_misses),
        data_cache_membership_rebuilds =
            tostring(base_cache_stats.membership_rebuilds),
        data_cache_summary_hits =
            tostring(base_cache_stats.summary_hits),
        data_cache_summary_misses =
            tostring(base_cache_stats.summary_misses),
        data_cache_invalidations =
            tostring(base_cache_stats.invalidations),
        data_cache_last_invalidation_reason =
            base_cache_stats.last_invalidation_reason,
        data_cache_last_invalidated_at =
            base_cache_stats.last_invalidated_at,
    }
end

local function add_fields(target, source)
    for key, value in pairs(source) do
        target[key] = value
    end
    return target
end

local function list_base_inventories()
    local cache, membership_hit = ensure_base_membership()
    local base_ids = {}
    for base_id, _ in pairs(cache.bases) do
        table.insert(base_ids, base_id)
    end
    table.sort(base_ids)

    local bases = {}
    local raw_names = {}
    local inventory_capable_count = 0
    for _, base_id in ipairs(base_ids) do
        local entry = cache.bases[base_id]
        local inventory_capable = #entry.containers > 0
        if inventory_capable then
            inventory_capable_count = inventory_capable_count + 1
        end
        table.insert(bases, table.concat({
            base_id,
            entry.base_name,
            tostring(#entry.containers),
            full_name(entry.dispenser),
            inventory_capable and "true" or "false",
        }, "~"))
        table.insert(raw_names, table.concat({
            base_id,
            entry.base_raw_name,
        }, "~"))
    end
    return add_fields({
        data_base_count = tostring(#base_ids),
        data_bases = table.concat(bases, "|"),
        data_base_names_raw = table.concat(raw_names, "|"),
        data_inventory_capable_base_count =
            tostring(inventory_capable_count),
    }, cache_metadata(membership_hit, false))
end

local function copy_fields(fields)
    local result = {}
    for key, value in pairs(fields) do
        result[key] = value
    end
    return result
end

local function build_base_summary(base_entry)
    local totals = {}
    local container_items = {}
    local slot_count = 0
    local populated_slot_count = 0
    local truncated = false

    for _, member in ipairs(base_entry.containers) do
        local slots_ok, slots = pcall(function()
            return member.container.ItemSlotArray
        end)
        if slots_ok and slots ~= nil then
            local count_ok, count = pcall(function()
                return #slots
            end)
            count = count_ok and (tonumber(count) or 0) or 0
            slot_count = slot_count + count
            local maximum = math.min(
                count,
                CONFIG.maximum_inventory_slots_per_container
            )
            for index = 1, maximum do
                local slot = unwrap(slots[index])
                if is_valid(slot) then
                    local item_id = ""
                    local count_value = 0
                    pcall(function()
                        item_id =
                            name_string(unwrap(slot.ItemId.StaticId))
                    end)
                    pcall(function()
                        count_value = tonumber(slot.StackCount) or 0
                    end)
                    if item_id ~= "" and count_value > 0 then
                        populated_slot_count = populated_slot_count + 1
                        totals[item_id] =
                            (totals[item_id] or 0) + count_value
                        if #container_items <
                            CONFIG.maximum_inventory_items then
                            table.insert(container_items, table.concat({
                                member.container_id,
                                tostring(index),
                                item_id,
                                tostring(count_value),
                            }, "~"))
                        else
                            truncated = true
                        end
                    end
                end
            end
            if count > maximum then
                truncated = true
            end
        end
    end

    local item_ids = {}
    for item_id, _ in pairs(totals) do
        table.insert(item_ids, item_id)
    end
    table.sort(item_ids)
    local items = {}
    for _, item_id in ipairs(item_ids) do
        table.insert(
            items,
            item_id .. "~" .. tostring(totals[item_id])
        )
    end

    return {
        data_base_id = base_entry.base_id,
        data_base_name = base_entry.base_name,
        data_base_name_raw = base_entry.base_raw_name,
        data_container_count = tostring(#base_entry.containers),
        data_slot_count = tostring(slot_count),
        data_populated_slot_count = tostring(populated_slot_count),
        data_distinct_item_count = tostring(#item_ids),
        data_items = table.concat(items, "|"),
        data_container_items = table.concat(container_items, "|"),
        data_truncated = truncated and "true" or "false",
    }
end

local function base_inventory_snapshot(command)
    local cache, membership_hit = ensure_base_membership()
    local base_id = tostring(command.base_id or "")
    local base_entry = cache.bases[base_id]
    if base_entry == nil then
        local listing = list_base_inventories()
        listing.data_requested_base_id = base_id
        return false, "base_id is unavailable; call list_live_bases", listing
    end

    local cached = base_summary_cache[base_id]
    if cached ~= nil and
        cached.membership_generation == cache.generation and
        now_ms() - cached.built_at_ms < CONFIG.base_summary_ttl_ms then
        base_cache_stats.summary_hits =
            base_cache_stats.summary_hits + 1
        return true, "Live base inventory summary read from cache.",
            add_fields(
                copy_fields(cached.fields),
                cache_metadata(membership_hit, true)
            )
    end

    base_cache_stats.summary_misses =
        base_cache_stats.summary_misses + 1
    local fields = build_base_summary(base_entry)
    base_summary_cache[base_id] = {
        built_at_ms = now_ms(),
        fields = copy_fields(fields),
        membership_generation = cache.generation,
    }
    return true, "Live base inventory summary read.",
        add_fields(fields, cache_metadata(membership_hit, false))
end

local function inventory_snapshot()
    local controller = find_local_controller()
    local state = nil
    local inventory = nil
    local helper = nil
    if is_valid(controller) then
        pcall(function()
            state = unwrap(controller:GetPalPlayerState())
        end)
    end
    if is_valid(state) then
        pcall(function()
            inventory = unwrap(state:GetInventoryData())
        end)
    end
    if is_valid(inventory) then
        pcall(function()
            helper = unwrap(inventory.InventoryMultiHelper)
        end)
    end

    local containers = {}
    local items = {}
    local slot_count = 0
    local truncated = false
    if is_valid(helper) then
        pcall(function()
            local collection = helper.Containers
            for container_index = 1, math.min(#collection, 64) do
                local container = unwrap(collection[container_index])
                if is_valid(container) then
                    local slots = container.ItemSlotArray
                    local count = #slots
                    slot_count = slot_count + count
                    table.insert(containers, table.concat({
                        tostring(container_index),
                        full_name(container),
                        tostring(count),
                    }, "~"))
                    for slot_index = 1, math.min(
                        count,
                        CONFIG.maximum_inventory_slots_per_container
                    ) do
                        local slot = unwrap(slots[slot_index])
                        if is_valid(slot) then
                            local item_id = ""
                            local count_value = 0
                            pcall(function()
                                item_id = name_string(
                                    unwrap(slot.ItemId.StaticId)
                                )
                            end)
                            pcall(function()
                                count_value =
                                    tonumber(slot.StackCount) or 0
                            end)
                            if item_id ~= "" and count_value > 0 then
                                if #items <
                                    CONFIG.maximum_inventory_items then
                                    table.insert(items, table.concat({
                                        tostring(container_index),
                                        tostring(slot_index),
                                        item_id,
                                        tostring(count_value),
                                    }, "~"))
                                else
                                    truncated = true
                                end
                            end
                        end
                    end
                    if count >
                        CONFIG.maximum_inventory_slots_per_container then
                        truncated = true
                    end
                end
            end
        end)
    end

    return {
        data_inventory = full_name(inventory),
        data_multi_helper = full_name(helper),
        data_container_count = tostring(#containers),
        data_containers = table.concat(containers, "|"),
        data_slot_count = tostring(slot_count),
        data_items = table.concat(items, "|"),
        data_truncated = truncated and "true" or "false",
    }
end

local function display_notification(message, priority)
    local displayed = false
    local error_message = nil
    local ok, call_error = pcall(function()
        if not is_valid(cached_log_manager) then
            cached_log_manager = FindFirstOf("PalLogManager")
        end
        if not is_valid(cached_log_manager) then
            error("PalLogManager is unavailable")
        end
        cached_log_manager:AddLog(
            math.max(1, math.min(3, tonumber(priority) or 1)),
            FText(tostring(message)),
            {}
        )
        displayed = true
    end)
    if not ok then
        error_message = tostring(call_error)
    end
    return displayed, error_message
end

local function show_notification(command, dry_run)
    local message = tostring(command.message or "")
    if message == "" then
        return false, "message is required", {}
    end
    if string.len(message) > CONFIG.maximum_message_length then
        return false, "message exceeds maximum length", {}
    end

    local priority = tonumber(command.priority) or 1
    priority = math.max(1, math.min(3, priority))
    if dry_run then
        return true, "Notification preview accepted.", {
            data_would_display = "true",
            data_message = message,
            data_priority = tostring(priority),
        }
    end

    local displayed, error_message =
        display_notification(message, priority)
    return displayed,
        displayed and "Notification displayed." or error_message,
        {data_displayed = displayed and "true" or "false"}
end

local function controller_pawn(controller)
    local pawn = nil
    if is_valid(controller) then
        pcall(function()
            pawn = unwrap(controller:K2_GetPawn())
        end)
        if not is_valid(pawn) then
            pcall(function()
                pawn = unwrap(controller:GetPawn())
            end)
        end
        if not is_valid(pawn) then
            pcall(function()
                pawn = unwrap(controller:K2_GetPawn())
            end)
        end
    end
    return pawn
end

local function pawn_parameter(pawn)
    local parameter = nil
    if is_valid(pawn) then
        pcall(function()
            parameter = unwrap(pawn:GetCharacterParameterComponent())
        end)
    end
    return parameter
end

object_base_id = function(object)
    local identifier = ""
    if not is_valid(object) then
        return identifier
    end
    pcall(function()
        identifier = guid_string(object:GetBaseCampIdBelongTo())
    end)
    if not is_guid(identifier) then
        pcall(function()
            identifier = guid_string(object:GetBaseCampId())
        end)
    end
    if not is_guid(identifier) then
        pcall(function()
            identifier = guid_string(object.BaseCampIdBelongTo)
        end)
    end
    if not is_guid(identifier) then
        pcall(function()
            identifier = guid_string(object.BaseCampId)
        end)
    end
    return is_guid(identifier) and identifier or ""
end

local function individual_parameter(parameter)
    local individual = nil
    if is_valid(parameter) then
        pcall(function()
            individual = unwrap(parameter:GetIndividualParameter())
        end)
    end
    return individual
end

local function worker_identity(parameter)
    local individual = individual_parameter(parameter)
    local identifier = ""
    local character_id = ""
    local nickname = ""
    if is_valid(individual) then
        pcall(function()
            identifier = guid_string(individual:GetIndividualID())
        end)
        if not is_guid(identifier) then
            pcall(function()
                identifier = guid_string(individual.IndividualId)
            end)
        end
        pcall(function()
            character_id = name_string(individual:GetCharacterID())
        end)
        pcall(function()
            nickname = name_string(individual:GetNickname())
        end)
    end
    if not is_guid(identifier) and is_valid(parameter) then
        pcall(function()
            identifier = guid_string(parameter:GetIndividualID())
        end)
    end
    return identifier, character_id, nickname, individual
end

local function work_location(work)
    local transform = nil
    local location = nil
    if is_valid(work) then
        pcall(function()
            location = work:GetWorkLocation()
        end)
        pcall(function()
            transform = unwrap(work.Transform)
        end)
    end
    if location == nil and is_valid(transform) then
        pcall(function()
            location = transform:K2_GetComponentLocation()
        end)
    end
    return location
end

local function vector_string(vector)
    if vector == nil then
        return ""
    end
    local x, y, z = nil, nil, nil
    pcall(function()
        x = tonumber(unwrap(vector.X))
        y = tonumber(unwrap(vector.Y))
        z = tonumber(unwrap(vector.Z))
    end)
    if x == nil or y == nil or z == nil then
        return ""
    end
    return string.format("%.1f,%.1f,%.1f", x, y, z)
end

local function object_location(object)
    local location = nil
    if not is_valid(object) then
        return nil
    end
    pcall(function()
        location = unwrap(object:K2_GetActorLocation())
    end)
    if vector_string(location) == "" then
        pcall(function()
            location = unwrap(object:GetActorLocation())
        end)
    end
    if vector_string(location) == "" then
        pcall(function()
            location = unwrap(object:GetFocalLocation())
        end)
    end
    if vector_string(location) == "" then
        pcall(function()
            location = unwrap(object.Location)
        end)
    end
    return vector_string(location) ~= "" and location or nil
end

local function relevant_geometry_surface(label, object)
    local records = {}
    if not is_valid(object) then
        return records
    end
    pcall(function()
        local struct = object:GetClass()
        local depth = 0
        while is_valid(struct) and depth < 10 and #records < 160 do
            local class_name = tostring(struct:GetFName():ToString())
            struct:ForEachFunction(function(func)
                local name = tostring(func:GetFName():ToString())
                if string.find(name, "Location", 1, true) or
                    string.find(name, "Transform", 1, true) or
                    string.find(name, "ViewTarget", 1, true) or
                    string.find(name, "Camera", 1, true) or
                    string.find(name, "Nearest", 1, true) or
                    string.find(name, "Range", 1, true) then
                    local parameters = {}
                    func:ForEachProperty(function(property)
                        table.insert(parameters, table.concat({
                            tostring(property:GetFName():ToString()),
                            tostring(property:GetClass():GetFName():ToString()),
                        }, ":"))
                        return nil
                    end)
                    table.insert(records, table.concat({
                        label,
                        "function",
                        class_name .. "." .. name,
                        table.concat(parameters, ","),
                    }, "~"))
                end
                return nil
            end)
            struct:ForEachProperty(function(property)
                local name = tostring(property:GetFName():ToString())
                if string.find(name, "Location", 1, true) or
                    string.find(name, "Transform", 1, true) or
                    string.find(name, "Camera", 1, true) or
                    string.find(name, "Range", 1, true) then
                    local value = nil
                    pcall(function()
                        value = unwrap(object[name])
                    end)
                    table.insert(records, table.concat({
                        label,
                        "property",
                        class_name .. "." .. name,
                        vector_string(value) ~= "" and
                            vector_string(value) or name_string(value),
                    }, "~"))
                end
                return nil
            end)
            struct = struct:GetSuperStruct()
            depth = depth + 1
        end
    end)
    return records
end

local function geometric_current_base_probe(controller)
    local positions = {}
    local surfaces = {}
    local function add_position(label, object)
        local location = object_location(object)
        if location ~= nil then
            table.insert(positions, table.concat({
                label,
                full_name(object),
                vector_string(location),
            }, "~"))
        end
    end
    add_position("controller", controller)

    local view_target = nil
    local camera_manager = nil
    if is_valid(controller) then
        pcall(function()
            view_target = unwrap(controller:GetViewTarget())
        end)
        pcall(function()
            camera_manager = unwrap(controller.PlayerCameraManager)
        end)
    end
    add_position("view_target", view_target)
    add_position("camera_manager", camera_manager)

    local characters = find_valid_objects({
        "BP_PalPlayerCharacter_C",
        "PalPlayerCharacter",
    }, 32)
    for index, character in ipairs(characters) do
        add_position("player_character_" .. tostring(index), character)
    end

    local manager = find_first_valid({
        "PalBaseCampManager",
        "BP_PalBaseCampManager_C",
    })
    for _, record in ipairs(
        relevant_geometry_surface("base_manager", manager)
    ) do
        table.insert(surfaces, record)
    end

    local models = find_valid_objects({"PalBaseCampModel"}, 128)
    local bases = {}
    for _, model in ipairs(models) do
        if not string.find(full_name(model), "Default__", 1, true) then
            local location = object_location(model)
            local area_range = ""
            local owner_map_object_id = ""
            local location_id = ""
            pcall(function()
                area_range = tostring(tonumber(model.AreaRange) or "")
            end)
            pcall(function()
                owner_map_object_id =
                    guid_string(model.OwnerMapObjectInstanceId)
            end)
            pcall(function()
                location_id = guid_string(model.LocationId)
            end)
            table.insert(bases, table.concat({
                base_model_native_id(model),
                base_model_group_id(model),
                owner_map_object_id,
                location_id,
                area_range,
                vector_string(location),
            }, "~"))
        end
    end
    table.sort(bases)

    for _, record in ipairs(
        relevant_geometry_surface("controller", controller)
    ) do
        table.insert(surfaces, record)
    end
    for _, record in ipairs(
        relevant_geometry_surface("view_target", view_target)
    ) do
        table.insert(surfaces, record)
    end
    return table.concat(positions, "|"),
        table.concat(bases, "|"),
        table.concat(surfaces, "|")
end

local function loaded_base_names()
    local names = {}
    local raw_names = {}
    local cache = ensure_base_membership()
    for base_id, entry in pairs(cache.bases) do
        names[base_id] = entry.base_name
        raw_names[base_id] = entry.base_raw_name
    end
    return names, raw_names
end

local function current_base_from_geometry(controller)
    local view_target = nil
    if is_valid(controller) then
        pcall(function()
            view_target = unwrap(controller:GetViewTarget())
        end)
    end
    local location = object_location(view_target)
    if location == nil then
        return "", "", ""
    end

    local manager = find_first_valid({
        "PalBaseCampManager",
        "BP_PalBaseCampManager_C",
    })
    if not is_valid(manager) then
        return "", "", ""
    end

    local model = nil
    pcall(function()
        model = unwrap(manager:GetInRangedBaseCamp(location, 0.0))
    end)
    if not is_valid(model) then
        return "", "", ""
    end
    local identifier = base_model_native_id(model)
    if not is_guid(identifier) then
        return "", "", ""
    end
    return identifier,
        base_name(model, identifier),
        base_model_group_id(model)
end

local function base_model_live_id(model)
    local identifier = base_model_native_id(model)
    if is_guid(identifier) then
        return identifier
    end
    local model_name = full_name(model)
    local dispensers = find_valid_objects({
        "PalMapObjectBaseCampItemDispenserModel",
    }, 64)
    for _, dispenser in ipairs(dispensers) do
        local owner_base = nil
        pcall(function()
            owner_base = unwrap(dispenser:GetBaseCampModelBelongTo())
        end)
        if is_valid(owner_base) and full_name(owner_base) == model_name then
            identifier = model_base_id(dispenser)
            if is_guid(identifier) then
                return identifier
            end
        end
    end
    return ""
end

local function current_base_from_live_membership()
    local matches = {}
    local base_models = find_valid_objects({"PalBaseCampModel"}, 128)
    for _, model in ipairs(base_models) do
        if not string.find(full_name(model), "Default__", 1, true) then
            local members = nil
            local member_count = 0
            pcall(function()
                members = unwrap(model.PlayerUIdsExistsInsideInServer)
            end)
            if members ~= nil then
                pcall(function()
                    member_count = #members
                end)
            end
            if member_count > 0 then
                table.insert(matches, model)
            end
        end
    end
    if #matches ~= 1 then
        return "", ""
    end
    local model = matches[1]
    local identifier = base_model_live_id(model)
    return identifier, base_name(model, identifier)
end

local function player_context(resolve_current_base, include_current_base_probe)
    local controller = find_local_controller()
    local state = nil
    local pawn = nil
    local inventory = nil
    local player_id = ""
    local level = ""

    if is_valid(controller) then
        pcall(function()
            state = unwrap(controller:GetPalPlayerState())
        end)
        pcall(function()
            pawn = unwrap(controller:GetPalPlayerCharacter())
        end)
        if not is_valid(pawn) then
            pcall(function()
                pawn = unwrap(controller:GetControlledPawn())
            end)
        end
        if not is_valid(pawn) then
            pcall(function()
                pawn = unwrap(controller:GetPawn())
            end)
        end
    end
    if is_valid(state) then
        pcall(function()
            inventory = unwrap(state:GetInventoryData())
        end)
        pcall(function()
            player_id = tostring(unwrap(state:GetPlayerId()))
        end)
        pcall(function()
            local player_level = tonumber(unwrap(state:GetPlayerLevel()))
            if player_level ~= nil then
                level = tostring(player_level)
            end
        end)
    end

    local current_base_id = resolve_current_base_id(controller, state)
    if current_base_id == "" and is_valid(pawn) then
        local parameter = nil
        pcall(function()
            parameter = unwrap(pawn:GetCharacterParameterComponent())
        end)
        current_base_id = object_base_id(parameter)
    end
    local current_base_name = ""
    local current_base_group_id = ""
    local current_base_group_name = ""
    local current_base_detection = ""
    local base_names = {}
    if current_base_id ~= "" or resolve_current_base then
        base_names = loaded_base_names()
    end
    if current_base_id ~= "" then
        current_base_name = base_names[current_base_id] or
            friendly_base_name("", current_base_id)
        current_base_detection = "controller"
    elseif resolve_current_base then
        current_base_id, current_base_name, current_base_group_id =
            current_base_from_geometry(controller)
        if current_base_id ~= "" then
            current_base_detection = "geometry"
        else
            current_base_id, current_base_name =
                current_base_from_live_membership()
            if current_base_id ~= "" then
                current_base_detection = "membership"
            end
        end
        current_base_name = base_names[current_base_id] or current_base_name
    end
    if current_base_group_id == "" and current_base_id ~= "" then
        local models = find_valid_objects({"PalBaseCampModel"}, 128)
        for _, model in ipairs(models) do
            if base_model_native_id(model) == current_base_id then
                current_base_group_id = base_model_group_id(model)
                break
            end
        end
    end
    local player_group_id, player_group_model = player_group()
    if is_guid(player_group_id) then
        cached_player_group_id = player_group_id
    end
    if current_base_group_id ~= "" then
        current_base_group_name = group_name(
            current_base_group_id,
            current_base_group_id == player_group_id and
                player_group_model or nil
        )
    end
    local current_base_is_owned =
        current_base_group_id ~= "" and
        current_base_group_id == player_group_id
    if current_base_id ~= "" and not current_base_is_owned and
        current_base_group_name ~= "" and
        string.sub(current_base_name, 1, 5) == "Base " then
        current_base_name =
            current_base_group_name .. " - " .. current_base_name
    end

    local result = {
        data_controller_available = is_valid(controller) and "true" or "false",
        data_controller = full_name(controller),
        data_player_state = full_name(state),
        data_pawn = full_name(pawn),
        data_inventory = full_name(inventory),
        data_player_id = player_id,
        data_level = level,
        data_current_base_id = current_base_id,
        data_current_base_name = current_base_name,
        data_current_base_group_id = current_base_group_id,
        data_current_base_group_name = current_base_group_name,
        data_current_base_is_owned =
            current_base_is_owned and "true" or "false",
        data_current_base_detection = current_base_detection,
    }
    if include_current_base_probe then
        local probe = {}
        for _, entry in ipairs(current_base_surface("controller", controller)) do
            table.insert(probe, entry)
        end
        for _, entry in ipairs(current_base_surface("state", state)) do
            table.insert(probe, entry)
        end
        for _, entry in ipairs(current_base_surface("pawn", pawn)) do
            table.insert(probe, entry)
        end
        local base_models = find_valid_objects({"PalBaseCampModel"}, 128)
        for _, base_model in ipairs(base_models) do
            if not string.find(full_name(base_model), "Default__", 1, true) then
                local base_id = object_base_id(base_model)
                for _, entry in ipairs(current_base_surface(
                    "base:" .. tostring(base_id),
                    base_model
                )) do
                    table.insert(probe, entry)
                end
            end
        end
        result.data_current_base_probe = table.concat(probe, "|")
        local position_candidates, base_geometry, geometry_surface =
            geometric_current_base_probe(controller)
        result.data_position_candidates = position_candidates
        result.data_base_geometry = base_geometry
        result.data_geometry_surface = geometry_surface
    end
    return result
end

local function collect_base_workers(requested_base_id)
    local workers = {}
    local controllers = find_valid_objects({
        "BP_MonsterAIController_BaseCamp_C",
    }, 512)
    local seen = {}
    for _, controller in ipairs(controllers) do
        if not string.find(full_name(controller), "Default__", 1, true) then
            local pawn = controller_pawn(controller)
            local parameter = pawn_parameter(pawn)
            local base_id = object_base_id(parameter)
            local pal_id, character_id, nickname, individual =
                worker_identity(parameter)
            if is_valid(pawn) and is_valid(parameter) and
                is_guid(base_id) and is_guid(pal_id) and
                (requested_base_id == "" or
                    base_id == requested_base_id) and
                not seen[pal_id] then
                local current_work = nil
                local fixed = false
                pcall(function()
                    current_work = unwrap(parameter:GetWork())
                end)
                pcall(function()
                    fixed = parameter:IsAssignedFixed() == true
                end)
                seen[pal_id] = true
                table.insert(workers, {
                    base_id = base_id,
                    character_id = character_id,
                    controller = controller,
                    current_work = current_work,
                    current_station_id =
                        is_valid(current_work) and
                        full_name(current_work) or "",
                    fixed = fixed,
                    individual = individual,
                    nickname = nickname,
                    pal_id = pal_id,
                    parameter = parameter,
                    pawn = pawn,
                })
            end
        end
    end
    table.sort(workers, function(left, right)
        return left.pal_id < right.pal_id
    end)
    return workers
end

local function collect_workstations(requested_base_id)
    local stations = {}
    local works = find_valid_objects({"PalWorkBase"}, 2048)
    local seen = {}
    for _, work in ipairs(works) do
        if not string.find(full_name(work), "Default__", 1, true) then
            local base_id = object_base_id(work)
            local station_id = full_name(work)
            local location = work_location(work)
            if is_guid(base_id) and
                (requested_base_id == "" or
                    base_id == requested_base_id) and
                not seen[station_id] then
                local work_id = ""
                local work_name = ""
                local assigned_count = 0
                pcall(function()
                    work_id = guid_string(work:GetWorkId())
                end)
                pcall(function()
                    work_name = name_string(work:GetWorkName())
                end)
                pcall(function()
                    assigned_count = #work:GetAssignedCharacters()
                end)
                seen[station_id] = true
                table.insert(stations, {
                    assigned_count = assigned_count,
                    base_id = base_id,
                    location = location,
                    station_id = station_id,
                    work = work,
                    work_id = work_id,
                    work_name = work_name,
                })
            end
        end
    end
    table.sort(stations, function(left, right)
        return left.station_id < right.station_id
    end)
    return stations
end

local function list_base_workers(command)
    local base_id = tostring(command.base_id or "")
    if base_id ~= "" and not is_guid(base_id) then
        return false, "base_id is not a valid live base ID", {}
    end
    local base_names = loaded_base_names()
    local records = {}
    local diagnostics = {}
    local _, base_director = pcb_base_roster(base_id)
    local slot_observer = nil
    local director_state = ""
    local waiting_worker_count = 0
    if is_valid(base_director) then
        pcall(function()
            slot_observer = unwrap(base_director.SlotObserverForServer)
        end)
        pcall(function()
            director_state = tostring(base_director.State)
        end)
        pcall(function()
            waiting_worker_count =
                #base_director.WaitingWorkerIndividualIds
        end)
    end
    local workers = collect_base_workers(base_id)
    for _, worker in ipairs(workers) do
        if base_names[worker.base_id] == nil then
            base_names[worker.base_id] = ""
        end
        table.insert(records, table.concat({
            worker.base_id,
            worker.pal_id,
            worker.character_id,
            worker.nickname,
            worker.current_station_id,
            worker.fixed and "true" or "false",
        }, "~"))
        local hidden = ""
        local tick_enabled = ""
        pcall(function()
            hidden = worker.pawn:IsHidden() and "true" or "false"
        end)
        pcall(function()
            tick_enabled =
                worker.pawn:IsActorTickEnabled() and "true" or "false"
        end)
        table.insert(diagnostics, table.concat({
            worker.pal_id,
            full_name(worker.controller),
            full_name(worker.pawn),
            vector_string(object_location(worker.pawn)),
            hidden,
            tick_enabled,
        }, "~"))
    end
    local bases = {}
    for identifier, name in pairs(base_names) do
        table.insert(bases, identifier .. "~" .. name)
    end
    table.sort(bases)
    return true, "Loaded base workers listed.", {
        data_base_count = tostring(#bases),
        data_bases = table.concat(bases, "|"),
        data_requested_base_id = base_id,
        data_worker_director = full_name(base_director),
        data_worker_director_state = director_state,
        data_worker_director_functions =
            table.concat(declared_function_surface(base_director), "|"),
        data_worker_slot_observer = full_name(slot_observer),
        data_worker_waiting_spawn_count =
            tostring(waiting_worker_count),
        data_worker_count = tostring(#workers),
        data_worker_diagnostics = table.concat(diagnostics, "|"),
        data_workers = table.concat(records, "|"),
    }
end

local function list_workstations(command)
    local base_id = tostring(command.base_id or "")
    if base_id ~= "" and not is_guid(base_id) then
        return false, "base_id is not a valid live base ID", {}
    end
    local records = {}
    local stations = collect_workstations(base_id)
    local base_names = loaded_base_names()
    for _, station in ipairs(stations) do
        if base_names[station.base_id] == nil then
            base_names[station.base_id] = ""
        end
        table.insert(records, table.concat({
            station.base_id,
            station.station_id,
            station.work_id,
            station.work_name,
            vector_string(station.location),
            tostring(station.assigned_count),
        }, "~"))
    end
    local bases = {}
    for identifier, name in pairs(base_names) do
        table.insert(bases, identifier .. "~" .. name)
    end
    table.sort(bases)
    return true, "Loaded base workstations listed.", {
        data_base_count = tostring(#bases),
        data_bases = table.concat(bases, "|"),
        data_requested_base_id = base_id,
        data_station_count = tostring(#stations),
        data_stations = table.concat(records, "|"),
    }
end

local function current_work_matches(parameter, target_work, target_work_id)
    local current = nil
    pcall(function()
        current = unwrap(parameter:GetWork())
    end)
    if not is_valid(current) then
        return false, current
    end
    if full_name(current) == full_name(target_work) then
        return true, current
    end
    local current_id = ""
    pcall(function()
        current_id = guid_string(current:GetWorkId())
    end)
    return current_id ~= "" and current_id == target_work_id, current
end

-- Notification severity is named rather than a boolean. Palworld's Pal log
-- takes a 1-3 priority; these are the only three this mod uses.
local NOTIFICATION_PRIORITY = {
    normal = 1,
    warning = 2,
    persistent = 3,
}

local function notify(severity, text)
    local clipped = string.sub(
        tostring(text),
        1,
        CONFIG.maximum_message_length
    )
    local displayed, notification_error = display_notification(
        clipped,
        NOTIFICATION_PRIORITY[severity] or NOTIFICATION_PRIORITY.normal
    )
    return displayed, notification_error, clipped
end

local function assign_pal_to_station(command, dry_run)
    local base_id = tostring(command.base_id or "")
    local pal_id = tostring(command.pal_id or "")
    local station_id = tostring(command.station_id or "")
    if not is_guid(base_id) then
        return false, "base_id is required and must be a live base ID", {}
    end
    if not is_guid(pal_id) then
        return false, "pal_id is required and must be a live Pal individual ID", {}
    end
    if station_id == "" then
        return false, "station_id is required", {}
    end

    local selected_worker = nil
    for _, worker in ipairs(collect_base_workers(base_id)) do
        if worker.pal_id == pal_id then
            selected_worker = worker
            break
        end
    end
    local selected_station = nil
    for _, station in ipairs(collect_workstations(base_id)) do
        if station.station_id == station_id then
            selected_station = station
            break
        end
    end
    if selected_worker == nil or selected_station == nil then
        local failure =
            selected_worker == nil and
            "Pal is not an active worker at the requested loaded base." or
            "Station is not a loaded work target at the requested base."
        if not dry_run then
            notify("warning", "Companion: " .. failure)
        end
        return false, failure, {}
    end
    if selected_station.work_id == "" then
        local failure = "Target station has no readable work ID."
        if not dry_run then
            notify("warning", "Companion: " .. failure)
        end
        return false, failure, {}
    end

    local base_names = loaded_base_names()
    local base_label = base_names[base_id] or base_id
    local pal_label = selected_worker.nickname ~= "" and
        selected_worker.nickname or selected_worker.character_id
    local station_label = selected_station.work_name ~= "" and
        selected_station.work_name or "selected station"
    local prior_work = selected_worker.current_work
    local prior_station_id = selected_worker.current_station_id
    local prior_work_id = ""
    if is_valid(prior_work) then
        pcall(function()
            prior_work_id = guid_string(prior_work:GetWorkId())
        end)
    end

    local already_assigned = false
    if is_valid(prior_work) then
        already_assigned =
            full_name(prior_work) == selected_station.station_id or
            (prior_work_id ~= "" and
                prior_work_id == selected_station.work_id)
    end
    if dry_run then
        return true, "Assignment validated; no live state changed.", {
            data_already_assigned =
                already_assigned and "true" or "false",
            data_base_id = base_id,
            data_base_name = base_label,
            data_notification =
                "Companion: would assign " .. pal_label ..
                " to " .. station_label .. " at " .. base_label .. ".",
            data_pal_id = pal_id,
            data_pal_name = pal_label,
            data_previous_station_id = prior_station_id,
            data_station_id = station_id,
            data_station_name = station_label,
            data_validated = "true",
        }
    end

    if already_assigned and selected_worker.fixed then
        local text = "Companion: " .. pal_label ..
            " is already assigned to " .. station_label ..
            " at " .. base_label .. "."
        local displayed, notification_error =
            notify("normal", text)
        return true, "Pal was already fixed to the requested station.", {
            data_already_assigned = "true",
            data_base_id = base_id,
            data_notification_displayed =
                displayed and "true" or "false",
            data_notification_error = notification_error or "",
            data_pal_id = pal_id,
            data_station_id = station_id,
            data_verified = "true",
        }
    end

    local call_ok = false
    local call_error = nil
    local ok, error_value = pcall(function()
        selected_worker.controller:SetBaseCampActionWithFixAssign(
            selected_station.work:GetWorkId(),
            250.0
        )
    end)
    call_ok = ok
    if not ok then
        call_error = tostring(error_value)
    end

    local verified = false
    local observed_work = nil
    if call_ok then
        verified, observed_work = current_work_matches(
            selected_worker.parameter,
            selected_station.work,
            selected_station.work_id
        )
    end
    if verified then
        local text = "Companion: assigned " .. pal_label ..
            " to " .. station_label .. " at " .. base_label .. "."
        local displayed, notification_error =
            notify("normal", text)
        return true, "Pal assignment applied and verified.", {
            data_base_id = base_id,
            data_notification_displayed =
                displayed and "true" or "false",
            data_notification_error = notification_error or "",
            data_pal_id = pal_id,
            data_previous_station_id = prior_station_id,
            data_station_id = station_id,
            data_verified = "true",
        }
    end

    local rollback_attempted = false
    local rollback_verified = false
    local rollback_error = ""
    if selected_worker.fixed and is_valid(prior_work) and
        prior_work_id ~= "" then
        rollback_attempted = true
        local rollback_ok, rollback_call_error = pcall(function()
            selected_worker.controller:SetBaseCampActionWithFixAssign(
                prior_work:GetWorkId(),
                250.0
            )
        end)
        if rollback_ok then
            rollback_verified = select(1, current_work_matches(
                selected_worker.parameter,
                prior_work,
                prior_work_id
            ))
        else
            rollback_error = tostring(rollback_call_error)
        end
    elseif is_valid(observed_work) then
        rollback_attempted = true
        local ok, error_value = pcall(function()
            selected_worker.controller:SetBaseCampAction()
        end)
        rollback_verified = ok
        if not ok then
            rollback_error = tostring(error_value)
        end
    end

    local failure = call_error or
        "native assignment did not report the target as current work"
    local rollback_text = rollback_attempted and
        (rollback_verified and " Previous assignment restored." or
            " Rollback could not be verified.") or ""
    local displayed, notification_error = notify(
        "warning",
        "Companion: assignment failed for " .. pal_label ..
            "." .. rollback_text
    )
    return false, failure, {
        data_base_id = base_id,
        data_notification_displayed =
            displayed and "true" or "false",
        data_notification_error = notification_error or "",
        data_pal_id = pal_id,
        data_previous_station_id = prior_station_id,
        data_rollback_attempted =
            rollback_attempted and "true" or "false",
        data_rollback_error = rollback_error,
        data_rollback_verified =
            rollback_verified and "true" or "false",
        data_station_id = station_id,
        data_verified = "false",
    }
end

function pcb_slot_identity(slot)
    local handle = nil
    local individual = nil
    local pal_id = ""
    local character_id = ""
    local nickname = ""
    if not is_valid(slot) then
        return pal_id, character_id, nickname, handle, individual
    end
    local empty = true
    pcall(function()
        empty = slot:IsEmpty() == true
    end)
    if empty then
        return pal_id, character_id, nickname, handle, individual
    end
    pcall(function()
        handle = unwrap(slot:GetHandle())
    end)
    if is_valid(handle) then
        pcall(function()
            pal_id = guid_string(handle:GetIndividualID())
        end)
        pcall(function()
            individual = unwrap(handle:TryGetIndividualParameter())
        end)
        if not is_valid(individual) then
            pcall(function()
                individual = unwrap(handle:GetIndividualParameter())
            end)
        end
    end
    if is_valid(individual) then
        if not is_guid(pal_id) then
            pcall(function()
                pal_id = guid_string(individual.IndividualId)
            end)
        end
        pcall(function()
            character_id = name_string(individual:GetCharacterID())
        end)
        pcall(function()
            nickname = name_string(individual:GetNickname())
        end)
    end
    return pal_id, character_id, nickname, handle, individual
end

function pcb_player_pal_storage()
    local controller = find_local_controller()
    local state = nil
    local storage = nil
    if is_valid(controller) then
        pcall(function()
            state = unwrap(controller:GetPalPlayerState())
        end)
    end
    if is_valid(state) then
        pcall(function()
            storage = unwrap(state:GetPalStorage())
        end)
    end
    return storage
end

function pcb_live_network_container()
    -- Use the same player-owned transmitter as the Palbox UI. Selecting the
    -- first loaded component can return the GameState/dedicated transmitter;
    -- that component replicates roster data but does not execute the local
    -- player's base-worker spawn/despawn lifecycle.
    local controller = find_local_controller()
    local transmitter = nil
    local player_component = nil
    if is_valid(controller) then
        pcall(function()
            transmitter = unwrap(controller.Transmitter)
        end)
        if not is_valid(transmitter) then
            pcall(function()
                transmitter = unwrap(
                    controller:GetPropertyValue("Transmitter")
                )
            end)
        end
    end
    if is_valid(transmitter) then
        pcall(function()
            player_component =
                unwrap(transmitter:GetCharacterContainer())
        end)
        if not is_valid(player_component) then
            pcall(function()
                player_component =
                    unwrap(transmitter.CharacterContainer)
            end)
        end
    end
    if is_valid(player_component) then
        return player_component
    end

    local components = find_valid_objects({
        "PalNetworkCharacterContainerComponent",
    }, 16)
    for _, component in ipairs(components) do
        local name = full_name(component)
        if not string.find(name, "Default__", 1, true) and
            string.find(name, ":PersistentLevel.", 1, true) then
            return component
        end
    end
    return nil
end

local function pcb_live_network_base_camp()
    local controller = find_local_controller()
    local transmitter = nil
    local component = nil
    if is_valid(controller) then
        pcall(function()
            transmitter = unwrap(controller.Transmitter)
        end)
        if not is_valid(transmitter) then
            pcall(function()
                transmitter = unwrap(
                    controller:GetPropertyValue("Transmitter")
                )
            end)
        end
    end
    if is_valid(transmitter) then
        pcall(function()
            component = unwrap(transmitter:GetBaseCamp())
        end)
        if not is_valid(component) then
            pcall(function()
                component = unwrap(transmitter.BaseCamp)
            end)
        end
    end
    return component
end

local function pcb_base_palbox_map_object_id(base_id, base_model)
    -- Worker roster RPCs authorize against the concrete Palbox terminal that
    -- initiated the operation. Raid-area Palboxes are BaseCampPoint models;
    -- their instance ID can differ from the base model's owner ID.
    local terminal_types = {
        "PalMapObjectBaseCampPoint",
        "PalMapObjectBaseCampWorkerExtraStationModel",
        "PalMapObjectBaseCampItemDispenserModel",
    }
    local terminals = find_valid_objects(terminal_types, 128)
    for _, terminal in ipairs(terminals) do
        local terminal_base_id = model_base_id(terminal)
        if not is_guid(terminal_base_id) then
            pcall(function()
                terminal_base_id = guid_string(terminal.BaseCampId)
            end)
        end
        if not string.find(full_name(terminal), "Default__", 1, true) and
            terminal_base_id == base_id then
            local instance_id = nil
            pcall(function()
                instance_id = terminal:GetInstanceId()
            end)
            if instance_id ~= nil then
                return instance_id, full_name(terminal)
            end
        end
    end

    local owner_id = nil
    if is_valid(base_model) then
        pcall(function()
            owner_id = base_model:GetOwnerMapObjectInstanceId()
        end)
    end
    return owner_id, full_name(base_model)
end

local function pcb_base_model_matches(model, base_id)
    if not is_valid(model) or not is_guid(base_id) then
        return false
    end
    return base_model_native_id(model) == base_id or
        object_base_id(model) == base_id
end

local function pcb_director_container(director)
    local container = nil
    if is_valid(director) then
        pcall(function()
            container = unwrap(director.CharacterContainer)
        end)
    end
    return container
end

local function pcb_model_roster(model, directors)
    local director = nil
    pcall(function()
        director = unwrap(model.WorkerDirector)
    end)
    if not is_valid(director) then
        pcall(function()
            director = unwrap(model:GetPropertyValue("WorkerDirector"))
        end)
    end
    local container = pcb_director_container(director)
    if is_valid(container) then
        return director, container
    end

    local model_path = string.match(full_name(model), "^[^ ]+ (.+)$")
    if model_path ~= nil then
        for _, nested_director in ipairs(directors) do
            if string.find(
                full_name(nested_director),
                model_path .. ".",
                1,
                true
            ) then
                local nested_container =
                    pcb_director_container(nested_director)
                if is_valid(nested_container) then
                    return nested_director, nested_container
                end
            end
        end
    end
    return nil, nil
end

function pcb_base_roster(base_id)
    local directors = find_valid_objects({
        "PalBaseCampWorkerDirector",
    }, 128)

    -- A loaded base model is authoritative for roster ownership. Palbox item
    -- dispenser models are optional and may be absent for valid loaded bases.
    local models = find_valid_objects({"PalBaseCampModel"}, 128)
    for _, model in ipairs(models) do
        if not string.find(full_name(model), "Default__", 1, true) and
            pcb_base_model_matches(model, base_id) then
            local director, container =
                pcb_model_roster(model, directors)
            if is_valid(container) then
                return model, director, container
            end
        end
    end

    -- Retain the dispenser relationship as a compatibility fallback.
    local dispensers = find_valid_objects({
        "PalMapObjectBaseCampItemDispenserModel",
    }, 64)
    for _, dispenser in ipairs(dispensers) do
        if model_base_id(dispenser) == base_id then
            local model = nil
            pcall(function()
                model = unwrap(dispenser:GetBaseCampModelBelongTo())
            end)
            if is_valid(model) then
                local director, container =
                    pcb_model_roster(model, directors)
                if is_valid(container) then
                    return model, director, container
                end
            end
        end
    end

    for _, director in ipairs(directors) do
        if not string.find(full_name(director), "Default__", 1, true) then
            local owner_base = nil
            pcall(function()
                owner_base = unwrap(director:GetOuter())
            end)
            if not is_valid(owner_base) then
                pcall(function()
                    owner_base = unwrap(director.OwnerBaseCamp)
                end)
            end
            local container = pcb_director_container(director)
            if is_valid(container) then
                if is_valid(owner_base) and
                    pcb_base_model_matches(owner_base, base_id) then
                    return owner_base, director, container
                end
                local count = 0
                pcall(function()
                    count = tonumber(container:Num()) or 0
                end)
                for index = 0, math.max(0, count - 1) do
                    local slot = nil
                    local individual = nil
                    pcall(function()
                        slot = unwrap(container:Get(index))
                    end)
                    local _, _, _, _, candidate_individual =
                        pcb_slot_identity(slot)
                    individual = candidate_individual
                    if is_valid(individual) and
                        object_base_id(individual) == base_id then
                        return nil, director, container
                    end
                end
            end
        end
    end
    return nil, nil, nil
end

local function pcb_refresh_base_worker_world(base_id)
    local model, director = pcb_base_roster(base_id)
    if not is_valid(director) then
        return false, "Base worker director is unavailable."
    end

    -- Roster swaps are authoritative server writes. OnRep_CharacterContainer
    -- is only the replicated-client callback and does not start the server's
    -- worker spawn/despawn lifecycle. Refresh the owning base status first so
    -- the director's slot observer and waiting-spawn queue process the change.
    if is_valid(model) then
        local updated, update_error = pcall(function()
            director:OnUpdateOwnerBaseCampStatus_ServerInternal(model)
        end)
        if updated then
            return true, "owner-base-status"
        end
        log_line(
            "worker lifecycle owner-base update failed base=" ..
            tostring(base_id) .. " error=" .. tostring(update_error)
        )
    end

    -- Compatibility fallback for game revisions that do not expose the
    -- server-internal update function to Lua.
    local replicated, replication_error = pcall(function()
        director:OnRep_CharacterContainer()
    end)
    if not replicated then
        return false, tostring(replication_error)
    end
    return true, "replication-fallback"
end

function pcb_container_slots(container)
    local slots = {}
    if not is_valid(container) then
        return slots
    end
    local count = 0
    pcall(function()
        count = tonumber(container:Num()) or 0
    end)
    for index = 0, math.max(0, count - 1) do
        local slot = nil
        pcall(function()
            slot = unwrap(container:Get(index))
        end)
        if is_valid(slot) then
            table.insert(slots, {
                index = index,
                slot = slot,
            })
        end
    end
    return slots
end

function pcb_find_palbox_slot(storage, target_pal_id)
    if not is_valid(storage) then
        return nil
    end
    local page_count = 0
    pcall(function()
        page_count = tonumber(storage:GetPageNum()) or 0
    end)
    for page = 0, math.max(0, page_count - 1) do
        for index = 0, 29 do
            local slot = nil
            pcall(function()
                slot = unwrap(storage:GetSlot(page, index))
            end)
            local pal_id = pcb_slot_identity(slot)
            if pal_id == target_pal_id then
                return {
                    index = index,
                    page = page,
                    slot = slot,
                }
            end
        end
    end
    return nil
end

-- Palbox lookups always know where a Pal was last seen. Check that slot first
-- and only fall back to the full page scan, which reads up to 30 slots per
-- page across every page.
function pcb_resolve_palbox_slot(storage, target_pal_id, page, index)
    if page ~= nil and index ~= nil then
        local slot = nil
        pcall(function()
            slot = unwrap(storage:GetSlot(page, index))
        end)
        if pcb_slot_identity(slot) == target_pal_id then
            return {index = index, page = page, slot = slot}
        end
    end
    return pcb_find_palbox_slot(storage, target_pal_id)
end

function pcb_find_empty_palbox_slot(storage)
    if not is_valid(storage) then
        return nil
    end
    local page_count = 0
    pcall(function()
        page_count = tonumber(storage:GetPageNum()) or 0
    end)
    for page = 0, math.max(0, page_count - 1) do
        for index = 0, 29 do
            local slot = nil
            local empty = false
            pcall(function()
                slot = unwrap(storage:GetSlot(page, index))
                empty = is_valid(slot) and slot:IsEmpty() == true
            end)
            if empty then
                return {
                    index = index,
                    page = page,
                    slot = slot,
                }
            end
        end
    end
    return nil
end

function pcb_find_base_slot(container, target_pal_id)
    local empty_slot = nil
    for _, entry in ipairs(pcb_container_slots(container)) do
        local pal_id = pcb_slot_identity(entry.slot)
        if pal_id == target_pal_id then
            return entry, empty_slot
        end
        local empty = false
        pcall(function()
            empty = entry.slot:IsEmpty() == true
        end)
        if empty and empty_slot == nil then
            empty_slot = entry
        end
    end
    return nil, empty_slot
end

function pcb_list_palbox_page(command)
    local storage = pcb_player_pal_storage()
    if not is_valid(storage) then
        return false, "Live Palbox storage is unavailable.", {}
    end
    local page_count = 0
    pcall(function()
        page_count = tonumber(storage:GetPageNum()) or 0
    end)
    local page = math.floor(tonumber(command.page_index) or 0)
    if page < 0 or page >= page_count then
        return false, "page_index is outside the live Palbox.", {
            data_page_count = tostring(page_count),
        }
    end

    local records = {}
    local occupied = 0
    for index = 0, 29 do
        local slot = nil
        pcall(function()
            slot = unwrap(storage:GetSlot(page, index))
        end)
        if is_valid(slot) then
            local pal_id, character_id, nickname =
                pcb_slot_identity(slot)
            if is_guid(pal_id) then
                occupied = occupied + 1
                table.insert(records, table.concat({
                    tostring(index),
                    pal_id,
                    character_id,
                    nickname,
                }, "~"))
            end
        end
    end
    return true, "Live Palbox page listed.", {
        data_occupied_count = tostring(occupied),
        data_page_count = tostring(page_count),
        data_page_index = tostring(page),
        data_pals = table.concat(records, "|"),
        data_slot_capacity = "30",
    }
end

function pcb_get_base_roster(command)
    local base_id = tostring(command.base_id or "")
    if not is_guid(base_id) then
        return false, "base_id is required and must be a live base ID.", {}
    end
    local model, director, container = pcb_base_roster(base_id)
    if not is_valid(director) or not is_valid(container) then
        return false, "The requested loaded base roster is unavailable.", {}
    end
    local base_label = is_valid(model) and base_name(model, base_id) or
        friendly_base_name("", base_id)
    local base_raw_label = is_valid(model) and base_raw_name(model) or ""
    local records = {}
    local occupied = 0
    local slots = pcb_container_slots(container)
    for _, entry in ipairs(slots) do
        local pal_id, character_id, nickname =
            pcb_slot_identity(entry.slot)
        if is_guid(pal_id) then
            occupied = occupied + 1
        end
        table.insert(records, table.concat({
            tostring(entry.index),
            pal_id,
            character_id,
            nickname,
            is_guid(pal_id) and "false" or "true",
        }, "~"))
    end
    return true, "Live base roster listed.", {
        data_base_id = base_id,
        data_base_name = base_label,
        data_base_name_raw = base_raw_label,
        data_empty_count = tostring(#slots - occupied),
        data_occupied_count = tostring(occupied),
        data_slot_count = tostring(#slots),
        data_slots = table.concat(records, "|"),
    }
end

local function pcb_numeric_value(value)
    value = unwrap(value)
    local direct = tonumber(value)
    if direct ~= nil then
        return direct
    end
    if value == nil then
        return nil
    end
    for _, method_name in ipairs({
        "ToFloat",
        "ToDouble",
        "GetFloatValue",
        "GetValue",
    }) do
        local converted = nil
        pcall(function()
            converted = tonumber(value[method_name](value))
        end)
        if converted ~= nil then
            return converted
        end
    end
    for _, property_name in ipairs({
        "Value",
        "value",
        "RawValue",
        "CurrentValue",
    }) do
        local converted = nil
        pcall(function()
            converted = tonumber(unwrap(value[property_name]))
        end)
        if converted ~= nil then
            return converted
        end
    end
    return nil
end

local function pcb_read_number(objects, methods, properties)
    for _, object in ipairs(objects) do
        if is_valid(object) then
            for _, method_name in ipairs(methods) do
                local value = nil
                pcall(function()
                    value = object[method_name](object)
                end)
                value = pcb_numeric_value(value)
                if value ~= nil then
                    return value,
                        full_name(object) .. "." .. method_name .. "()"
                end
            end
            for _, property_name in ipairs(properties) do
                local value = nil
                pcall(function()
                    value = object[property_name]
                end)
                if value == nil then
                    pcall(function()
                        value = object:GetPropertyValue(property_name)
                    end)
                end
                value = pcb_numeric_value(value)
                if value ~= nil then
                    return value, full_name(object) .. "." .. property_name
                end
            end
        end
    end
    return nil, ""
end

local function pcb_read_boolean(objects, methods, properties)
    for _, object in ipairs(objects) do
        if is_valid(object) then
            for _, method_name in ipairs(methods) do
                local value = nil
                local ok = pcall(function()
                    value = unwrap(object[method_name](object))
                end)
                if ok and type(value) == "boolean" then
                    return value, full_name(object) .. "." .. method_name .. "()"
                end
            end
            for _, property_name in ipairs(properties) do
                local value = nil
                pcall(function()
                    value = unwrap(object[property_name])
                end)
                if type(value) == "boolean" then
                    return value, full_name(object) .. "." .. property_name
                end
            end
        end
    end
    return nil, ""
end

local function pcb_pal_combat_state(pawn, parameter, individual)
    local objects = {}
    if pawn ~= nil then
        table.insert(objects, pawn)
    end
    if parameter ~= nil then
        table.insert(objects, parameter)
    end
    if individual ~= nil then
        table.insert(objects, individual)
    end
    local level, level_source = pcb_read_number(
        objects,
        {"GetLevel", "GetCharacterLevel"},
        {"Level", "CharacterLevel"}
    )
    local hp, hp_source = pcb_read_number(
        objects,
        {"GetHP", "GetHp", "GetCurrentHP", "GetCurrentHp", "GetHealth"},
        {"HP", "Hp", "CurrentHP", "CurrentHp", "Health"}
    )
    local max_hp, max_hp_source = pcb_read_number(
        objects,
        {"GetMaxHP", "GetMaxHp", "GetMaxHealth"},
        {"MaxHP", "MaxHp", "MaxHealth"}
    )
    local explicitly_downed, downed_source = pcb_read_boolean(
        objects,
        {"IsDead", "IsDown", "IsFainted", "IsIncapacitated"},
        {"bIsDead", "bIsDown", "bIsFainted", "bIsIncapacitated"}
    )
    local downed = explicitly_downed == true or
        (hp ~= nil and hp <= 0)
    return {
        downed = downed,
        downed_known = explicitly_downed ~= nil or hp ~= nil,
        downed_source = downed_source ~= "" and downed_source or hp_source,
        hp = hp,
        hp_source = hp_source,
        level = level,
        level_source = level_source,
        max_hp = max_hp,
        max_hp_source = max_hp_source,
    }
end

local function pcb_pal_downed_state(individual)
    if not is_valid(individual) then
        return false, false, nil
    end
    local dead = nil
    local dead_ok = pcall(function()
        dead = unwrap(individual:IsDead())
    end)
    if dead_ok and type(dead) == "boolean" then
        return dead, true, nil
    end
    local hp = nil
    pcall(function()
        hp = tonumber(unwrap(individual:GetHP()))
    end)
    if hp ~= nil then
        return hp <= 0, true, hp
    end
    return false, false, nil
end

local function pcb_base_palboxes(base_id)
    local matches = {}
    local seen = {}
    for _, dispenser in ipairs(find_valid_objects({
        "PalMapObjectBaseCampItemDispenserModel",
        "BP_BuildObject_PalBox_RaidBossArea_C",
    }, 64)) do
        local candidate_base_id = object_base_id(dispenser)
        if candidate_base_id == "" then
            candidate_base_id = model_base_id(dispenser)
        end
        local key = full_name(dispenser)
        if candidate_base_id == base_id and not seen[key] then
            seen[key] = true
            table.insert(matches, dispenser)
        end
    end
    return matches
end

local function pcb_raid_area_object_probe()
    local records = {}
    local seen_classes = {}
    local ok, classes = pcall(function()
        return FindObjects(0, "Class", nil, nil, nil, false)
    end)
    if not ok or type(classes) ~= "table" then
        return records
    end
    for _, class_object in ipairs(classes) do
        if #records >= 160 then
            break
        end
        class_object = unwrap(class_object)
        if is_valid(class_object) then
            local class_name = ""
            pcall(function()
                class_name =
                    tostring(class_object:GetFName():ToString())
            end)
            local lowered = string.lower(class_name)
            local relevant =
                string.find(lowered, "raidbossarea", 1, true) or
                string.find(lowered, "raid_area", 1, true) or
                string.find(lowered, "palbox", 1, true) or
                string.find(
                    lowered,
                    "basecampitemdispenser",
                    1,
                    true
                )
            if relevant and not seen_classes[class_name] then
                seen_classes[class_name] = true
                local objects =
                    find_valid_objects({class_name}, 32)
                for _, object in ipairs(objects) do
                    if #records >= 160 then
                        break
                    end
                    local object_name = full_name(object)
                    if not string.find(
                        object_name,
                        "Default__",
                        1,
                        true
                    ) then
                        table.insert(records, table.concat({
                            class_name,
                            object_name,
                            object_base_id(object),
                        }, "~"))
                    end
                end
            end
        end
    end
    return records
end

local function pcb_raid_metadata_surface()
    local records = {}
    local class_names = {
        "PalRaidBossAreaWorldSubsystem",
        "PalRaidBossAreaInstanceModel",
        "PalRaidBossAreaInstanceModelStateMachine",
        "PalMapObjectRaidBossAreaSummon",
        "BP_BuildObject_PalBox_RaidBossArea_C",
    }
    for _, object in ipairs(find_valid_objects(class_names, 32)) do
        if #records >= 256 then
            break
        end
        local object_name = full_name(object)
        if not string.find(object_name, "Default__", 1, true) then
            pcall(function()
                local struct = object:GetClass()
                local depth = 0
                while is_valid(struct) and depth < 8 and
                    #records < 256 do
                    local owner =
                        tostring(struct:GetFName():ToString())
                    struct:ForEachFunction(function(func)
                        local name =
                            tostring(func:GetFName():ToString())
                        local lowered = string.lower(name)
                        if string.find(lowered, "state", 1, true) or
                            string.find(lowered, "phase", 1, true) or
                            string.find(lowered, "battle", 1, true) or
                            string.find(lowered, "basecamp", 1, true) or
                            string.find(lowered, "container", 1, true) or
                            string.find(lowered, "character", 1, true) or
                            string.find(lowered, "worker", 1, true) then
                            local parameters = {}
                            func:ForEachProperty(function(property)
                                if #parameters < 16 then
                                    table.insert(
                                        parameters,
                                        tostring(
                                            property:GetFName():ToString()
                                        ) .. ":" ..
                                        tostring(
                                            property:GetClass():
                                                GetFName():ToString()
                                        )
                                    )
                                end
                                return nil
                            end)
                            table.insert(records, table.concat({
                                object_name,
                                "function",
                                owner .. "." .. name,
                                table.concat(parameters, ","),
                            }, "~"))
                        end
                        return #records >= 256 and true or nil
                    end)
                    struct:ForEachProperty(function(property)
                        local name =
                            tostring(property:GetFName():ToString())
                        local lowered = string.lower(name)
                        if string.find(lowered, "state", 1, true) or
                            string.find(lowered, "phase", 1, true) or
                            string.find(lowered, "battle", 1, true) or
                            string.find(lowered, "basecamp", 1, true) or
                            string.find(lowered, "container", 1, true) or
                            string.find(lowered, "character", 1, true) or
                            string.find(lowered, "worker", 1, true) then
                            table.insert(records, table.concat({
                                object_name,
                                "property",
                                owner .. "." .. name,
                                tostring(
                                    property:GetClass():
                                        GetFName():ToString()
                                ),
                            }, "~"))
                        end
                        return #records >= 256 and true or nil
                    end)
                    struct = struct:GetSuperStruct()
                    depth = depth + 1
                end
            end)
        end
    end
    return records
end

local function pcb_character_container_from_module(module)
    if not is_valid(module) then
        return nil
    end
    local container = nil
    for _, getter in ipairs({
        "GetContainer",
        "GetCharacterContainer",
        "GetTargetContainer",
    }) do
        if not is_valid(container) then
            pcall(function()
                container = unwrap(module[getter](module))
            end)
        end
    end
    for _, property_name in ipairs({
        "TargetContainer",
        "CharacterContainer",
        "Container",
    }) do
        if not is_valid(container) then
            pcall(function()
                container = unwrap(module[property_name])
            end)
        end
    end
    return is_valid(container) and container or nil
end

local function pcb_is_bounded_base_roster(container)
    if not is_valid(container) then
        return false
    end
    local count = 0
    local ok = pcall(function()
        count = tonumber(container:Num()) or 0
    end)
    return ok and count >= 1 and count <= 128
end

local function pcb_worker_roster_from_base_model(model, base_id)
    if not is_valid(model) then
        return nil, nil
    end
    local candidate_id = object_base_id(model)
    if not is_guid(candidate_id) then
        candidate_id = base_model_native_id(model)
    end
    if candidate_id ~= base_id then
        return nil, nil
    end

    local director = nil
    for _, getter in ipairs({
        "GetWorkerDirector",
        "GetBaseCampWorkerDirector",
    }) do
        if not is_valid(director) then
            pcall(function()
                director = unwrap(model[getter](model))
            end)
        end
    end
    for _, property_name in ipairs({
        "WorkerDirector",
        "BaseCampWorkerDirector",
    }) do
        if not is_valid(director) then
            pcall(function()
                director = unwrap(model[property_name])
            end)
        end
    end
    local container = nil
    if is_valid(director) then
        pcall(function()
            container = unwrap(director.CharacterContainer)
        end)
        if not is_valid(container) then
            pcall(function()
                container = unwrap(director:GetCharacterContainer())
            end)
        end
    end
    if is_valid(director) and is_valid(container) then
        return director, container
    end

    local model_path = string.match(full_name(model), "^[^ ]+ (.+)$")
    if model_path ~= nil then
        for _, nested_director in ipairs(find_valid_objects({
            "PalBaseCampWorkerDirector",
        }, 128)) do
            if string.find(
                full_name(nested_director),
                model_path .. ".",
                1,
                true
            ) then
                local nested_container = nil
                pcall(function()
                    nested_container =
                        unwrap(nested_director.CharacterContainer)
                end)
                if is_valid(nested_container) then
                    return nested_director, nested_container
                end
            end
        end
    end
    return nil, nil
end

local function pcb_raid_palbox_roster(base_id)
    local palboxes = pcb_base_palboxes(base_id)
    if #palboxes ~= 1 then
        return nil, nil, nil, ""
    end
    local palbox = palboxes[1]

    -- Some game revisions expose the character-container module directly on
    -- the Raid Area Palbox actor. This is still the ordinary Palbox roster
    -- path because the actor has already been verified against the Raid Area
    -- base ID.
    local direct_module = nil
    pcall(function()
        direct_module = unwrap(palbox:GetCharacterContainerModule())
    end)
    local direct_container =
        pcb_character_container_from_module(direct_module)
    if pcb_is_bounded_base_roster(direct_container) then
        return palbox, direct_module, direct_container,
            "raid_palbox_character_module"
    end

    local related = {}
    local seen = {}
    local function add_related(candidate)
        candidate = unwrap(candidate)
        local key = full_name(candidate)
        if is_valid(candidate) and not seen[key] then
            seen[key] = true
            table.insert(related, candidate)
        end
    end
    add_related(palbox)
    for _, getter in ipairs({
        "GetMapObjectModel",
        "GetMapObjectConcreteModel",
        "GetConcreteModel",
        "GetModel",
        "GetBaseCampModelBelongTo",
    }) do
        pcall(function()
            add_related(palbox[getter](palbox))
        end)
    end
    for _, property_name in ipairs({
        "MapObjectModel",
        "MapObjectConcreteModel",
        "ConcreteModel",
        "Model",
        "BaseCampModelBelongTo",
    }) do
        pcall(function()
            add_related(palbox[property_name])
        end)
    end

    local index = 1
    while index <= #related and index <= 16 do
        local object = related[index]
        local object_base = object_base_id(object)
        if not is_guid(object_base) then
            object_base = model_base_id(object)
        end
        if object_base == base_id then
            local module = nil
            pcall(function()
                module = unwrap(object:GetCharacterContainerModule())
            end)
            local container =
                pcb_character_container_from_module(module)
            if pcb_is_bounded_base_roster(container) then
                return object, module, container,
                    "raid_palbox_model_character_module"
            end
        end

        local base_model = nil
        pcall(function()
            base_model =
                unwrap(object:GetBaseCampModelBelongTo())
        end)
        if is_valid(base_model) then
            add_related(base_model)
            local director, container =
                pcb_worker_roster_from_base_model(base_model, base_id)
            if is_valid(director) and
                pcb_is_bounded_base_roster(container) then
                return base_model, director, container,
                    "raid_palbox_base_worker_roster"
            end
        end
        local director, container =
            pcb_worker_roster_from_base_model(object, base_id)
        if is_valid(director) and
            pcb_is_bounded_base_roster(container) then
            return object, director, container,
                "raid_palbox_base_worker_roster"
        end
        index = index + 1
    end
    return palbox, nil, nil, ""
end

function pcb_raid_area_roster(base_id)
    local selected_instance = nil
    local raid_area_base_id = ""
    local owner_base_id = ""
    for _, instance in ipairs(find_valid_objects({
        "PalRaidBossAreaInstanceModel",
    }, 16)) do
        local candidate_raid_id = ""
        pcall(function()
            candidate_raid_id =
                guid_string(instance.RaidAreaBaseCampId)
        end)
        if candidate_raid_id == base_id then
            selected_instance = instance
            raid_area_base_id = candidate_raid_id
            pcall(function()
                owner_base_id =
                    guid_string(instance.OwnerBaseCampId)
            end)
            break
        end
    end
    if not is_valid(selected_instance) then
        return nil, nil, nil, {}
    end

    local roster_model, roster_owner, roster_container, roster_source =
        pcb_raid_palbox_roster(base_id)
    if is_valid(roster_container) then
        local phase = ""
        local phase_state = nil
        local state_machine = nil
        pcall(function()
            phase = name_string(selected_instance:GetCurrentPhase())
        end)
        pcall(function()
            state_machine =
                unwrap(selected_instance.PhaseStateMachine)
        end)
        if is_valid(state_machine) then
            pcall(function()
                phase_state = unwrap(state_machine:GetCurrentState())
            end)
        end
        return selected_instance, roster_owner, roster_container, {
            module = roster_owner,
            owner_base_id = owner_base_id,
            phase = phase,
            phase_state = phase_state,
            raid_area_base_id = raid_area_base_id,
            roster_model = roster_model,
            roster_source = roster_source,
            state_machine = state_machine,
        }
    end

    local selected_summon = nil
    local module = nil
    local container = nil
    for _, summon in ipairs(find_valid_objects({
        "PalMapObjectRaidBossAreaSummon",
    }, 16)) do
        if object_base_id(summon) == raid_area_base_id then
            selected_summon = summon
            pcall(function()
                module =
                    unwrap(summon:GetCharacterContainerModule())
            end)
            break
        end
    end
    container = pcb_character_container_from_module(module)
    if not pcb_is_bounded_base_roster(container) then
        container = nil
    end

    local phase = ""
    local phase_state = nil
    local state_machine = nil
    pcall(function()
        phase = name_string(selected_instance:GetCurrentPhase())
    end)
    pcall(function()
        state_machine = unwrap(selected_instance.PhaseStateMachine)
    end)
    if is_valid(state_machine) then
        pcall(function()
            phase_state = unwrap(state_machine:GetCurrentState())
        end)
    end
    return selected_instance, selected_summon, container, {
        module = module,
        owner_base_id = owner_base_id,
        phase = phase,
        phase_state = phase_state,
        raid_area_base_id = raid_area_base_id,
        roster_model = roster_model,
        roster_source = is_valid(container) and
            "raid_summon_character_module" or "",
        state_machine = state_machine,
    }
end

local function pcb_collect_raid_reserves(diagnostics, excluded_ids)
    scheduler_metrics.palbox_scans =
        scheduler_metrics.palbox_scans + 1
    local reserves = {}
    local ranked = {}
    diagnostics = diagnostics or {}
    excluded_ids = excluded_ids or {}
    diagnostics.occupied = 0
    diagnostics.individual_valid = 0
    diagnostics.level_known = 0
    diagnostics.health_known = 0
    diagnostics.healthy = 0
    diagnostics.excluded = 0
    diagnostics.samples = {}
    local storage = pcb_player_pal_storage()
    if not is_valid(storage) then
        return reserves
    end
    local page_count = 0
    pcall(function()
        page_count = tonumber(storage:GetPageNum()) or 0
    end)
    for page = 0, math.max(0, page_count - 1) do
        for index = 0, 29 do
            local slot = nil
            pcall(function()
                slot = unwrap(storage:GetSlot(page, index))
            end)
            local pal_id, character_id, nickname, _, individual =
                pcb_slot_identity(slot)
            if is_guid(pal_id) then
                diagnostics.occupied = diagnostics.occupied + 1
                if is_valid(individual) then
                    diagnostics.individual_valid =
                        diagnostics.individual_valid + 1
                end
                local level = nil
                if is_valid(individual) then
                    pcall(function()
                        level = tonumber(
                            unwrap(individual:GetLevel())
                        )
                    end)
                end
                if level ~= nil then
                    diagnostics.level_known =
                        diagnostics.level_known + 1
                end
                if excluded_ids[pal_id] then
                    diagnostics.excluded = diagnostics.excluded + 1
                elseif level ~= nil and is_valid(individual) then
                    table.insert(ranked, {
                        character_id = character_id,
                        index = index,
                        individual = individual,
                        level = level,
                        nickname = nickname,
                        page = page,
                        pal_id = pal_id,
                    })
                end
            end
        end
    end
    table.sort(ranked, function(left, right)
        if left.level ~= right.level then
            return left.level > right.level
        end
        return left.pal_id < right.pal_id
    end)
    for _, candidate in ipairs(ranked) do
        if #reserves >= CONFIG.raid_reserve_queue_capacity then
            break
        end
        local downed, downed_known, hp =
            pcb_pal_downed_state(candidate.individual)
        if downed_known then
            diagnostics.health_known =
                diagnostics.health_known + 1
        end
        if #diagnostics.samples < 8 then
            table.insert(diagnostics.samples, table.concat({
                tostring(candidate.page),
                tostring(candidate.index),
                candidate.pal_id,
                "true",
                tostring(candidate.level),
                hp == nil and "" or tostring(hp),
                downed and "true" or "false",
                downed_known and "true" or "false",
                "GetLevel",
                hp == nil and "" or "GetHP",
                "IsDead/GetHP",
            }, "~"))
        end
        if downed_known and not downed then
            candidate.individual = nil
            candidate.hp = hp
            table.insert(reserves, candidate)
            diagnostics.healthy = diagnostics.healthy + 1
        end
    end
    diagnostics.health_scan_truncated =
        #reserves >= CONFIG.raid_reserve_queue_capacity
    return reserves
end

local function pcb_reserve_records(reserves, maximum_count)
    local records = {}
    for index, reserve in ipairs(reserves) do
        if index > maximum_count then
            break
        end
        table.insert(records, table.concat({
            tostring(reserve.page),
            tostring(reserve.index),
            reserve.pal_id,
            reserve.character_id,
            reserve.nickname,
            tostring(reserve.level),
            reserve.hp == nil and "" or tostring(reserve.hp),
        }, "~"))
    end
    return records
end

local function pcb_raid_deployment_state(base_id)
    local model, director, container = pcb_base_roster(base_id)
    local state = {
        automatic_available = false,
        capacity = 0,
        container = container,
        deployed = 0,
        director = director,
        empty_slots = {},
        model = model,
        owner_base_id = base_id,
        roster_source = "base_worker_roster",
    }
    if not is_valid(container) then
        return state
    end
    for _, entry in ipairs(pcb_container_slots(container)) do
        state.capacity = state.capacity + 1
        local pal_id = pcb_slot_identity(entry.slot)
        if is_guid(pal_id) then
            state.deployed = state.deployed + 1
        else
            table.insert(state.empty_slots, entry)
        end
    end
    state.automatic_available =
        is_valid(pcb_player_pal_storage()) and
        is_valid(pcb_live_network_base_camp())
    return state
end

local function pcb_raid_reserve_signature(reserve, include_health)
    local values = {
        tostring(reserve.page),
        tostring(reserve.index),
        tostring(reserve.level),
    }
    if include_health then
        table.insert(
            values,
            reserve.hp == nil and "" or tostring(reserve.hp)
        )
    end
    return table.concat(values, ":")
end

local function pcb_recount_invalidated_reserves()
    local count = 0
    for _ in pairs(raid_manager.invalidated_reserves) do
        count = count + 1
    end
    raid_manager.invalidated_reserve_count = count
    return count
end

-- A reserve is usable only when its level and downed state are both
-- authoritative and it is not downed. Anything else is a reason to skip it.
local function pcb_reserve_rejection(combat)
    if not combat.downed_known then
        return "reserve health became unavailable"
    end
    if combat.downed then
        return "reserve became unhealthy"
    end
    if combat.level == nil then
        return "reserve level became unavailable"
    end
    return nil
end

local function pcb_invalidate_raid_reserve(
    reserve,
    reason,
    unlock_on_health_change
)
    if reserve == nil or not is_guid(reserve.pal_id) then
        return
    end
    raid_manager.invalidated_reserves[reserve.pal_id] = {
        reason = tostring(reason or "deployment rejected"),
        signature = pcb_raid_reserve_signature(
            reserve,
            unlock_on_health_change == true
        ),
        unlock_on_health_change = unlock_on_health_change == true,
    }
    pcb_recount_invalidated_reserves()
end

local function pcb_rebuild_raid_queue(reason)
    local build_started_at = os.clock()
    local diagnostics = {}
    local candidates = pcb_collect_raid_reserves(diagnostics)
    local reserves = {}
    for _, candidate in ipairs(candidates) do
        local invalidated =
            raid_manager.invalidated_reserves[candidate.pal_id]
        local signature = pcb_raid_reserve_signature(
            candidate,
            invalidated ~= nil and
                invalidated.unlock_on_health_change == true
        )
        if invalidated == nil then
            table.insert(reserves, candidate)
        elseif invalidated.signature ~= signature then
            raid_manager.invalidated_reserves[candidate.pal_id] = nil
            table.insert(reserves, candidate)
        end
    end
    pcb_recount_invalidated_reserves()
    local deployment = pcb_raid_deployment_state(raid_manager.base_id)
    raid_manager.reserves = reserves
    raid_manager.healthy_palbox_count =
        tonumber(diagnostics.healthy) or #reserves
    raid_manager.palbox_occupied_count =
        tonumber(diagnostics.occupied) or 0
    raid_manager.deployment_capacity = deployment.capacity
    raid_manager.deployed_count = deployment.deployed
    raid_manager.queue_built_at_ms = now_ms()
    raid_manager.queue_rebuild_count =
        raid_manager.queue_rebuild_count + 1
    raid_manager.queue_rebuild_reason = tostring(reason or "periodic")
    scheduler_metrics.last_queue_build_ms =
        math.floor((os.clock() - build_started_at) * 1000)
    return deployment, diagnostics
end

local function pcb_take_healthy_raid_reserve()
    local storage = pcb_player_pal_storage()
    while #raid_manager.reserves > 0 do
        local candidate = table.remove(raid_manager.reserves, 1)
        local live_slot = pcb_resolve_palbox_slot(
            storage,
            candidate.pal_id,
            candidate.page,
            candidate.index
        )
        if live_slot ~= nil then
            local _, _, _, _, individual =
                pcb_slot_identity(live_slot.slot)
            local combat = pcb_pal_combat_state(nil, nil, individual)
            candidate.page = live_slot.page
            candidate.index = live_slot.index
            candidate.level = combat.level or candidate.level
            candidate.hp = combat.hp
            local rejection = pcb_reserve_rejection(combat)
            if rejection == nil then
                return candidate
            end
            pcb_invalidate_raid_reserve(
                candidate,
                rejection,
                combat.downed_known and combat.downed
            )
        else
            pcb_invalidate_raid_reserve(
                candidate,
                "reserve left its expected Palbox slot"
            )
        end
    end
    return nil
end

-- One authoritative Raid Manager reset. Every stop path and activation goes
-- through this, so no field is ever left behind. The cumulative counters are
-- deliberately not cleared here: they describe the session that just ended and
-- activation zeroes them when a new one begins.
local function pcb_reset_raid_manager_state()
    raid_manager.base_id = ""
    raid_manager.healthy_palbox_count = 0
    raid_manager.palbox_occupied_count = 0
    raid_manager.deployment_capacity = 0
    raid_manager.deployed_count = 0
    raid_manager.queue_built_at_ms = 0
    raid_manager.queue_rebuild_count = 0
    raid_manager.queue_rebuild_reason = ""
    raid_manager.invalidated_reserves = {}
    raid_manager.invalidated_reserve_count = 0
    raid_manager.started_at_ms = 0
    raid_manager.last_check_at_ms = 0
    raid_manager.manager_state = MANAGER_STATE_OFF
    raid_manager.reinforcement_pass_requested = false
    raid_manager.reinforcement_request_reason = ""
    raid_manager.reinforcement_pass_running = false
    raid_manager.raid_phase_missing_samples = 0
    raid_manager.raid_phase_seen_battle = false
    raid_manager.raid_phase_state = ""
    raid_manager.next_bulk_deploy_at_ms = 0
    raid_manager.zero_healthy_warned = false
    raid_manager.reserves = {}
    raid_manager.roster_model = nil
    raid_manager.roster_director = nil
    raid_manager.roster_container = nil
    raid_manager.worker_move_identity = nil
end

local function pcb_stop_raid_manager(reason, notify_player)
    pcb_reset_raid_manager_state()
    raid_manager.mode = "off"
    raid_manager.stopped_reason = tostring(reason or "stopped")
    if notify_player then
        notify(
            "normal",
            "PalCom: Raid Manager stopped - " ..
                raid_manager.stopped_reason .. "."
        )
    end
end

-- Every roster write needs the same four identities, and a missing one is
-- always fatal. Resolve them once here instead of in each caller.
local function pcb_worker_move_identity(base_id, model, container)
    local base_network = pcb_live_network_base_camp()
    local container_id = nil
    local native_base_id = nil
    pcall(function()
        container_id = container:GetId()
        native_base_id = model:GetId()
    end)
    local palbox_map_object_id, palbox_map_object =
        pcb_base_palbox_map_object_id(base_id, model)
    if not is_valid(base_network) or container_id == nil or
        native_base_id == nil or palbox_map_object_id == nil then
        return nil
    end
    return {
        base_network = base_network,
        container_id = container_id,
        native_base_id = native_base_id,
        palbox_map_object = palbox_map_object,
        palbox_map_object_id = palbox_map_object_id,
    }
end

-- A running manager is bound to one already-loaded base. Retain that roster
-- surface for the session instead of walking every loaded base model and
-- worker director before and after each individual deployment. UObject
-- validity is checked on every use; stream-out falls back to one fresh lookup.
local function pcb_raid_manager_deployment_state()
    local cached_roster =
        is_valid(raid_manager.roster_container) and
        is_valid(raid_manager.roster_director)
    local deployment
    if cached_roster then
        if raid_manager.worker_move_identity == nil or
            not is_valid(raid_manager.worker_move_identity.base_network) then
            raid_manager.worker_move_identity = pcb_worker_move_identity(
                raid_manager.base_id,
                raid_manager.roster_model,
                raid_manager.roster_container
            )
        end
        deployment = {
            automatic_available =
                is_valid(pcb_player_pal_storage()) and
                raid_manager.worker_move_identity ~= nil and
                is_valid(raid_manager.worker_move_identity.base_network),
            capacity = 0,
            container = raid_manager.roster_container,
            deployed = 0,
            director = raid_manager.roster_director,
            empty_slots = {},
            model = raid_manager.roster_model,
            owner_base_id = raid_manager.base_id,
            roster_source = "base_worker_roster_cached",
        }
        for _, entry in ipairs(
            pcb_container_slots(raid_manager.roster_container)
        ) do
            deployment.capacity = deployment.capacity + 1
            if is_guid(pcb_slot_identity(entry.slot)) then
                deployment.deployed = deployment.deployed + 1
            else
                table.insert(deployment.empty_slots, entry)
            end
        end
        return deployment
    end

    deployment = pcb_raid_deployment_state(raid_manager.base_id)
    raid_manager.roster_model = deployment.model
    raid_manager.roster_director = deployment.director
    raid_manager.roster_container = deployment.container
    raid_manager.worker_move_identity = pcb_worker_move_identity(
        raid_manager.base_id,
        deployment.model,
        deployment.container
    )
    deployment.automatic_available =
        is_valid(pcb_player_pal_storage()) and
        raid_manager.worker_move_identity ~= nil and
        is_valid(raid_manager.worker_move_identity.base_network)
    return deployment
end

-- The two authoritative worker RPCs. A generic container swap moves the
-- roster entry without running the worker spawn lifecycle, so anything that
-- must be visible in the world goes through these.
local function pcb_request_worker_deploy(identity, palbox_slot_id)
    return pcall(function()
        identity.base_network:RequestMoveCharacterToWorker_ToServer(
            identity.native_base_id,
            palbox_slot_id,
            identity.container_id,
            identity.palbox_map_object_id
        )
    end)
end

local function pcb_request_worker_withdraw(
    identity,
    base_slot_id,
    palbox_page
)
    return pcall(function()
        identity.base_network:RequestMoveWorkerToPalBox_ToServer(
            identity.native_base_id,
            base_slot_id,
            palbox_page,
            identity.palbox_map_object_id
        )
    end)
end

-- A move counts as verified only when the Pal reached the target slot and
-- left the source slot.
local function pcb_move_verified(source_slot, target_slot, pal_id)
    return pcb_slot_identity(target_slot) == pal_id and
        pcb_slot_identity(source_slot) ~= pal_id
end

local function pcb_deploy_raid_pal(
    base_id,
    reserve,
    dry_run,
    requested_target,
    use_visible_lifecycle,
    known_deployment,
    known_identity
)
    local deployment = known_deployment or pcb_raid_deployment_state(base_id)
    local storage = pcb_player_pal_storage()
    local visible_lifecycle = use_visible_lifecycle ~= false
    local network = visible_lifecycle and nil or pcb_live_network_container()
    local base_network = known_identity ~= nil and
        known_identity.base_network or pcb_live_network_base_camp()
    if not deployment.automatic_available or
        not is_valid(deployment.container) then
        return false,
            "The live base deployment surface is unavailable.",
            {}
    end
    if (visible_lifecycle and not is_valid(base_network)) or
        (not visible_lifecycle and not is_valid(network)) then
        return false,
            "The live base worker network surface is unavailable.",
            {}
    end
    local target = requested_target or deployment.empty_slots[1]
    local source = pcb_resolve_palbox_slot(
        storage,
        reserve.pal_id,
        reserve.page,
        reserve.index
    )
    if target == nil then
        return false, "The base has no empty Pal slots.", {}
    end
    if source == nil then
        return false,
            "The expected reserve is no longer in the live Palbox.",
            {}
    end
    local _, _, _, _, individual = pcb_slot_identity(source.slot)
    local combat = pcb_pal_combat_state(nil, nil, individual)
    if not combat.downed_known or combat.downed then
        return false,
            combat.downed_known and
                "The selected Palbox reserve is not healthy." or
                "The selected Palbox reserve health is not authoritative.",
            {}
    end
    local source_location = "palbox:" .. tostring(source.page) ..
        ":" .. tostring(source.index)
    local target_location = "base:" .. tostring(target.index)
    if dry_run then
        return true,
            "Base Pal deployment validated; no live state changed.",
            {
                data_base_id = base_id,
                data_reserve_pal_id = reserve.pal_id,
                data_source = source_location,
                data_target = target_location,
                data_validated = "true",
            }
    end

    local source_slot_id = nil
    local target_slot_id = nil
    pcall(function()
        source_slot_id = source.slot:GetSlotId()
        target_slot_id = target.slot:GetSlotId()
    end)
    local identity = known_identity or pcb_worker_move_identity(
        base_id,
        deployment.model,
        deployment.container
    )
    if source_slot_id == nil or target_slot_id == nil or
        identity == nil then
        return false, "Base deployment identity is unavailable.", {}
    end
    local request_method = visible_lifecycle and
        "RequestMoveCharacterToWorker_ToServer" or
        "RequestSwap_ToServer_Rep"
    local request_ok, request_error
    if visible_lifecycle then
        request_ok, request_error =
            pcb_request_worker_deploy(identity, source_slot_id)
    else
        request_ok, request_error = pcall(function()
            network:RequestSwap_ToServer_Rep(
                source_slot_id,
                target_slot_id
            )
        end)
    end
    local target_pal_id = pcb_slot_identity(target.slot)
    local source_pal_id = pcb_slot_identity(source.slot)
    if request_ok and
        pcb_move_verified(source.slot, target.slot, reserve.pal_id) then
        return true, "Base Pal deployed and verified.", {
            data_base_id = base_id,
            data_reserve_pal_id = reserve.pal_id,
            data_palbox_map_object = identity.palbox_map_object,
            data_request_method = request_method,
            data_source = source_location,
            data_target = target_location,
            data_verified = "true",
        }
    end
    local state_unchanged = not is_guid(target_pal_id) and
        source_pal_id == reserve.pal_id
    if state_unchanged then
        return false,
            "Base deployment was rejected; reserve removed from this queue.",
            {
                data_candidate_invalid = "true",
                data_state_unchanged = "true",
                data_verified = "false",
            }
    end

    local rollback_ok = false
    local rollback_error = ""
    if target_pal_id == reserve.pal_id then
        local ok, error_value
        if visible_lifecycle then
            ok, error_value = pcb_request_worker_withdraw(
                identity,
                target_slot_id,
                source.page
            )
        else
            ok, error_value = pcall(function()
                network:RequestSwap_ToServer_Rep(
                    target_slot_id,
                    source_slot_id
                )
            end)
        end
        rollback_ok = ok and
            pcb_slot_identity(source.slot) == reserve.pal_id
        if not ok then
            rollback_error = tostring(error_value)
        end
    end
    return false,
        request_ok and "Base deployment did not verify." or
            tostring(request_error), {
            data_rollback_error = rollback_error,
            data_rollback_verified = rollback_ok and "true" or "false",
            data_verified = "false",
        }
end

local function pcb_palbox_metadata_surface()
    local records = {}
    local storage = pcb_player_pal_storage()
    if not is_valid(storage) then
        return records
    end
    table.insert(records, "storage~" .. full_name(storage))
    table.insert(records, "storage_functions~" ..
        table.concat(declared_function_surface(storage), ","))
    local page_count = 0
    pcall(function()
        page_count = tonumber(storage:GetPageNum()) or 0
    end)
    for page = 0, math.max(0, page_count - 1) do
        for index = 0, 29 do
            local slot = nil
            local handle = nil
            pcall(function()
                slot = unwrap(storage:GetSlot(page, index))
            end)
            local pal_id, _, _, candidate_handle, individual =
                pcb_slot_identity(slot)
            handle = candidate_handle
            if is_guid(pal_id) then
                table.insert(records, "slot~" .. full_name(slot))
                table.insert(records, "slot_functions~" ..
                    table.concat(declared_function_surface(slot), ","))
                table.insert(records, "handle~" .. full_name(handle))
                table.insert(records, "handle_functions~" ..
                    table.concat(declared_function_surface(handle), ","))
                table.insert(records, "individual~" ..
                    full_name(individual))
                table.insert(records, "individual_functions~" ..
                    table.concat(
                        declared_function_surface(individual),
                        ","
                    ))
                return records
            end
        end
    end
    return records
end

local function pcb_combat_surface(label, object)
    local records = {}
    if not is_valid(object) then
        return records
    end
    pcall(function()
        local struct = object:GetClass()
        local depth = 0
        while is_valid(struct) and depth < 8 and #records < 128 do
            local class_name = tostring(struct:GetFName():ToString())
            struct:ForEachFunction(function(func)
                local name = tostring(func:GetFName():ToString())
                local lowered = string.lower(name)
                if string.find(lowered, "health", 1, true) or
                    string.find(lowered, "hp", 1, true) or
                    string.find(lowered, "dead", 1, true) or
                    string.find(lowered, "down", 1, true) or
                    string.find(lowered, "level", 1, true) then
                    table.insert(records, table.concat({
                        label,
                        "function",
                        class_name .. "." .. name,
                    }, "~"))
                end
                return #records >= 128 and true or nil
            end)
            struct:ForEachProperty(function(property)
                local name = tostring(property:GetFName():ToString())
                local lowered = string.lower(name)
                if string.find(lowered, "health", 1, true) or
                    string.find(lowered, "hp", 1, true) or
                    string.find(lowered, "dead", 1, true) or
                    string.find(lowered, "down", 1, true) or
                    string.find(lowered, "level", 1, true) then
                    local value = nil
                    pcall(function()
                        value = unwrap(object[name])
                    end)
                    table.insert(records, table.concat({
                        label,
                        "property",
                        class_name .. "." .. name,
                        name_string(value),
                    }, "~"))
                end
                return #records >= 128 and true or nil
            end)
            struct = struct:GetSuperStruct()
            depth = depth + 1
        end
    end)
    return records
end

function pcb_swap_raid_pal(command, dry_run)
    local base_id = tostring(command.base_id or "")
    local downed_pal_id = tostring(command.downed_pal_id or "")
    local reserve_pal_id = tostring(command.reserve_pal_id or "")
    local reserve_page = tonumber(command.reserve_page)
    local reserve_index = tonumber(command.reserve_index)
    if not is_guid(base_id) or not is_guid(downed_pal_id) or
        not is_guid(reserve_pal_id) or downed_pal_id == reserve_pal_id then
        return false,
            "base_id, downed_pal_id, and reserve_pal_id must be distinct valid live IDs.",
            {}
    end

    local model, _, container = pcb_base_roster(base_id)
    local storage = pcb_player_pal_storage()
    local base_network = pcb_live_network_base_camp()
    if not is_valid(container) or not is_valid(storage) or
        not is_valid(model) or not is_valid(base_network) then
        return false, "The live base roster swap surface is unavailable.", {}
    end

    local downed_slot = pcb_find_base_slot(container, downed_pal_id)
    local reserve_slot = pcb_resolve_palbox_slot(
        storage,
        reserve_pal_id,
        reserve_page,
        reserve_index
    )
    if downed_slot == nil or reserve_slot == nil then
        return false,
            "The expected fighter or reserve was not found in its live roster.",
            {}
    end
    local _, _, _, _, slot_individual =
        pcb_slot_identity(downed_slot.slot)
    local combat =
        pcb_pal_combat_state(nil, nil, slot_individual)
    if not combat.downed_known or not combat.downed then
        return false,
            combat.downed_known and
                "The selected base fighter is not downed." or
                "The selected base fighter's downed state is not authoritative.",
            {}
    end

    local source_location = "palbox:" .. tostring(reserve_slot.page) ..
        ":" .. tostring(reserve_slot.index)
    local target_location = "base:" .. tostring(downed_slot.index)
    if dry_run then
        return true, "Base replacement validated; no live state changed.", {
            data_base_id = base_id,
            data_downed_pal_id = downed_pal_id,
            data_reserve_pal_id = reserve_pal_id,
            data_source = source_location,
            data_target = target_location,
            data_validated = "true",
        }
    end

    local source_slot_id = nil
    local target_slot_id = nil
    pcall(function()
        source_slot_id = reserve_slot.slot:GetSlotId()
        target_slot_id = downed_slot.slot:GetSlotId()
    end)
    if source_slot_id == nil or target_slot_id == nil then
        return false, "Base replacement slot IDs are unavailable.", {}
    end

    local empty_palbox_slot = pcb_find_empty_palbox_slot(storage)
    local identity = pcb_worker_move_identity(base_id, model, container)
    if empty_palbox_slot == nil or identity == nil then
        return false, "Base replacement identity is unavailable.", {}
    end

    -- Mirror the Palbox UI: withdraw the downed worker, then deploy the
    -- healthy reserve through the dedicated base-worker RPC.
    local withdraw_ok, withdraw_error = pcb_request_worker_withdraw(
        identity,
        target_slot_id,
        empty_palbox_slot.page
    )
    local withdrawn_slot =
        withdraw_ok and pcb_find_palbox_slot(storage, downed_pal_id) or nil
    local base_slot_pal_id = pcb_slot_identity(downed_slot.slot)
    if not withdraw_ok or withdrawn_slot == nil or
        is_guid(base_slot_pal_id) then
        return false,
            withdraw_ok and
                "Downed base Pal withdrawal did not verify." or
                tostring(withdraw_error), {
                data_candidate_invalid = "false",
                data_palbox_map_object = identity.palbox_map_object,
                data_request_method =
                    "RequestMoveWorkerToPalBox_ToServer",
                data_verified = "false",
            }
    end

    local deployed, deploy_message, deploy_details =
        pcb_deploy_raid_pal(base_id, {
            index = reserve_slot.index,
            level = 0,
            page = reserve_slot.page,
            pal_id = reserve_pal_id,
        }, false, downed_slot)
    if deployed then
        raid_manager.replacement_count =
            raid_manager.replacement_count + 1
        return true, "Downed base Pal replaced and verified.", {
            data_base_id = base_id,
            data_downed_pal_id = downed_pal_id,
            data_palbox_map_object = identity.palbox_map_object,
            data_request_method =
                "RequestMoveWorkerToPalBox_ToServer+" ..
                "RequestMoveCharacterToWorker_ToServer",
            data_reserve_pal_id = reserve_pal_id,
            data_source = source_location,
            data_target = target_location,
            data_verified = "true",
        }
    end

    local rollback_ok = false
    local rollback_error = ""
    if withdrawn_slot ~= nil then
        local withdrawn_slot_id = nil
        pcall(function()
            withdrawn_slot_id = withdrawn_slot.slot:GetSlotId()
        end)
        local ok, error_value =
            pcb_request_worker_deploy(identity, withdrawn_slot_id)
        rollback_ok = ok and
            pcb_slot_identity(downed_slot.slot) == downed_pal_id and
            pcb_find_palbox_slot(storage, downed_pal_id) == nil
        if not ok then
            rollback_error = tostring(error_value)
        end
    end
    -- A half-applied replacement must stop the manager through the single
    -- authoritative reset, not by clearing two fields here.
    pcb_stop_raid_manager("replacement verification failed", true)
    return false, deploy_message, {
            data_deploy_details = tostring(deploy_details),
            data_rollback_error = rollback_error,
            data_rollback_verified = rollback_ok and "true" or "false",
            data_verified = "false",
        }
end

-- The single raid-phase sampler. Battle completion stays transition-based: a
-- positively observed Battle phase arms the latch, a later valid non-Battle
-- phase stops the manager, and two consecutive missing instance samples after
-- Battle are the guarded fallback. The 15-minute watchdog remains the last
-- resort. Called from the readiness refresh, which is the only place that
-- already reads the raid area.
local function pcb_observe_raid_phase(instance, raid_context)
    if raid_manager.mode == "off" then
        return
    end
    local phase_state = full_name(raid_context.phase_state)
    raid_manager.raid_phase_state = phase_state
    local phase_is_battle = string.find(
        phase_state,
        "PalRaidBossAreaPhaseBattleState",
        1,
        true
    ) ~= nil
    if phase_is_battle then
        raid_manager.raid_phase_seen_battle = true
        raid_manager.raid_phase_missing_samples = 0
        return
    end
    if is_valid(instance) and is_valid(raid_context.phase_state) then
        raid_manager.raid_phase_missing_samples = 0
        if raid_manager.raid_phase_seen_battle then
            pcb_stop_raid_manager("raid battle phase ended", true)
        end
        return
    end
    if not raid_manager.raid_phase_seen_battle then
        return
    end
    raid_manager.raid_phase_missing_samples =
        raid_manager.raid_phase_missing_samples + 1
    if raid_manager.raid_phase_missing_samples >= 2 then
        pcb_stop_raid_manager(
            "raid instance disappeared after battle",
            true
        )
    end
end

local function pcb_warn_no_healthy_reserves()
    if raid_manager.zero_healthy_warned then
        return
    end
    raid_manager.zero_healthy_warned = true
    raid_manager.manager_state = MANAGER_STATE_WAITING
    notify(
        "warning",
        "PalCom: Raid Manager has no healthy Palbox Pals left."
    )
end

local function pcb_run_base_reinforcement_pass(reason)
    local pass_started_at = os.clock()
    scheduler_metrics.roster_scans =
        scheduler_metrics.roster_scans + 1
    raid_manager.reinforcement_pass_running = true
    raid_manager.reinforcement_pass_requested = false
    raid_manager.reinforcement_request_reason = ""
    local reserve_count_at_start = #raid_manager.reserves
    local deployment = pcb_raid_manager_deployment_state()
    raid_manager.deployment_capacity = deployment.capacity
    raid_manager.deployed_count = deployment.deployed
    if not is_valid(deployment.container) then
        raid_manager.reinforcement_pass_running = false
        pcb_stop_raid_manager(
            "bound base worker roster is unavailable",
            true
        )
        return 0, 0
    end

    local downed = {}
    -- Empty-slot filling is intentionally isolated from health checks. During
    -- activation, scanning every fighter after each spawn caused pass time to
    -- grow with the roster. Death events and the integrity pass handle
    -- replacement once the roster is full.
    if #deployment.empty_slots == 0 then
        for _, entry in ipairs(pcb_container_slots(deployment.container)) do
            local pal_id, _, _, _, individual =
                pcb_slot_identity(entry.slot)
            if is_guid(pal_id) then
                local is_downed, downed_known =
                    pcb_pal_downed_state(individual)
                if downed_known and is_downed then
                    table.insert(downed, {
                        pal_id = pal_id,
                        slot = entry,
                    })
                end
            end
        end
    end
    if raid_manager.mode ~= "auto" then
        raid_manager.reinforcement_pass_running = false
        scheduler_metrics.last_reinforcement_pass_ms =
            math.floor((os.clock() - pass_started_at) * 1000)
        raid_manager.manager_state = MANAGER_STATE_ACTIVE
        return 0, 0
    end
    if not get_settings().write_actions_enabled then
        raid_manager.reinforcement_pass_running = false
        pcb_stop_raid_manager("live writes were disabled", true)
        return 0, 0
    end

    local replacements = 0
    local deployments = 0
    local function use_reserve(action, target, use_visible_lifecycle)
        local maximum_attempts = #raid_manager.reserves
        local attempt = 0
        while attempt < maximum_attempts do
            attempt = attempt + 1
            local reserve = pcb_take_healthy_raid_reserve()
            if reserve == nil then
                return false
            end
            raid_manager.sequence = raid_manager.sequence + 1
            local success = false
            local message = ""
            local details = {}
            if action == "replace" then
                success, message, details = pcb_swap_raid_pal({
                    base_id = raid_manager.base_id,
                    downed_pal_id = target.pal_id,
                    reserve_pal_id = reserve.pal_id,
                    reserve_page = reserve.page,
                    reserve_index = reserve.index,
                }, false)
            else
                success, message, details = pcb_deploy_raid_pal(
                    raid_manager.base_id,
                    reserve,
                    false,
                    target,
                    use_visible_lifecycle,
                    deployment,
                    raid_manager.worker_move_identity
                )
            end
            append_audit(
                success and "completed" or "failed",
                action == "replace" and
                    "raid_manager_replace" or
                    "raid_manager_deploy",
                "raid-auto-" .. tostring(raid_manager.sequence),
                success and reserve.pal_id or message
            )
            if success then
                raid_manager.zero_healthy_warned = false
                return true
            end
            if details == nil or
                details.data_candidate_invalid ~= "true" then
                pcb_stop_raid_manager(message, true)
                return false
            end
            pcb_invalidate_raid_reserve(reserve, message)
        end
        return false
    end

    -- One roster-write budget for the whole pass. A wipe can leave every slot
    -- downed at once, and replacing them all in a single dispatcher pass would
    -- make the game reconcile that many actors in one frame. Whatever is left
    -- over continues on the next wake through the existing coalesced request.
    local write_budget = math.max(1, CONFIG.raid_bulk_deploy_batch_size)
    for _, fighter in ipairs(downed) do
        if write_budget <= 0 or raid_manager.mode == "off" or
            not use_reserve("replace", fighter) then
            break
        end
        replacements = replacements + 1
        write_budget = write_budget - 1
    end
    if raid_manager.mode ~= "off" then
        local bulk_deployment_count = math.min(
            #deployment.empty_slots,
            #raid_manager.reserves,
            write_budget
        )
        for index = 1, bulk_deployment_count do
            local empty_slot = deployment.empty_slots[index]
            -- Generic swaps cheaply stage the roster. The final authoritative
            -- worker move triggers one game lifecycle reconciliation for the
            -- complete batch.
            local use_visible_lifecycle =
                index == bulk_deployment_count
            if not use_reserve(
                "deploy",
                empty_slot,
                use_visible_lifecycle
            ) then
                break
            end
            deployments = deployments + 1
        end
    end
    raid_manager.deployment_count =
        raid_manager.deployment_count + deployments
    if reserve_count_at_start > 0 and
        #raid_manager.reserves == 0 then
        pcb_rebuild_raid_queue("exhausted")
    end
    local refreshed = pcb_raid_manager_deployment_state()
    raid_manager.deployment_capacity = refreshed.capacity
    raid_manager.deployed_count = refreshed.deployed
    -- Either kind of leftover work continues the same way: downed fighters the
    -- write budget did not reach, or empty slots still waiting on a reserve.
    local replacements_pending = replacements < #downed
    local bulk_deployment_pending =
        raid_manager.mode ~= "off" and
        #raid_manager.reserves > 0 and
        (#refreshed.empty_slots > 0 or replacements_pending)
    if bulk_deployment_pending then
        -- Continue on the next existing 500 ms dispatcher wakeup. Each batch
        -- performs one authoritative worker move, limiting how many actors the
        -- game reconciles in a single frame.
        raid_manager.reinforcement_pass_requested = true
        raid_manager.reinforcement_request_reason =
            "bulk-deployment-continuation"
        raid_manager.next_bulk_deploy_at_ms =
            now_ms() + CONFIG.raid_bulk_deploy_interval_ms
    else
        raid_manager.next_bulk_deploy_at_ms = 0
    end
    if #raid_manager.reserves == 0 then
        pcb_warn_no_healthy_reserves()
    elseif raid_manager.mode ~= "off" then
        raid_manager.zero_healthy_warned = false
        raid_manager.manager_state = bulk_deployment_pending and
            MANAGER_STATE_DEPLOYING or MANAGER_STATE_ACTIVE
    end
    if replacements > 0 and
        not bulk_deployment_pending and
        not raid_manager.zero_healthy_warned then
        notify(
            "normal",
            "PalCom: Raid Manager " ..
                tostring(reason or "check") .. " deployed " ..
                tostring(deployments) .. " and replaced " ..
                tostring(replacements) .. " base Pals."
        )
    end
    raid_manager.reinforcement_pass_running = false
    scheduler_metrics.last_reinforcement_pass_ms =
        math.floor((os.clock() - pass_started_at) * 1000)
    return deployments, replacements
end

-- Raid Manager is intentionally a generic, base-bound reinforcement manager.
-- Activation is the only current-base lookup. Events request immediate,
-- coalesced passes; the periodic path is a one-minute integrity fallback.
local function pcb_set_raid_manager(command, dry_run)
    local mode = string.lower(tostring(command.mode or ""))
    if mode ~= "off" and mode ~= "observe" and mode ~= "auto" then
        return false, "mode must be off, observe, or auto.", {}
    end
    if mode == "off" then
        if not dry_run then
            pcb_stop_raid_manager("stopped by player", false)
            notify("normal", "PalCom: Raid Manager stopped.")
        end
        return true,
            dry_run and
                "Raid Manager stop validated; no state changed." or
                "Raid Manager stopped.",
            {data_mode = dry_run and raid_manager.mode or "off"}
    end

    local context = player_context(true, false)
    local base_id = tostring(context.data_current_base_id or "")
    local base_name = tostring(context.data_current_base_name or "")
    local owned = context.data_current_base_is_owned == "true"
    local deployment = pcb_raid_deployment_state(base_id)
    local reserve_diagnostics = {}
    local reserves =
        pcb_collect_raid_reserves(reserve_diagnostics)
    local automatic_ready = mode ~= "auto" or
        deployment.automatic_available
    if not is_guid(base_id) or not owned or
        not is_valid(deployment.container) or
        deployment.capacity < 1 or not automatic_ready then
        return false,
            "Raid Manager requires the current owned base, its loaded worker roster, and the live Palbox swap surface.",
            {
                data_base_id = base_id,
                data_current_base_is_owned =
                    owned and "true" or "false",
                data_automatic_deployment_available =
                    deployment.automatic_available and "true" or "false",
                data_deployment_capacity =
                    tostring(deployment.capacity),
                data_deployed_count =
                    tostring(deployment.deployed),
                data_empty_deployment_slot_count =
                    tostring(#deployment.empty_slots),
            }
    end
    local details = {
        data_base_id = base_id,
        data_base_name = base_name,
        data_mode = mode,
        data_reserve_count = tostring(#reserves),
        data_palbox_healthy_count =
            tostring(reserve_diagnostics.healthy or #reserves),
        data_palbox_occupied_count =
            tostring(reserve_diagnostics.occupied or 0),
        data_automatic_deployment_available =
            deployment.automatic_available and "true" or "false",
        data_automatic_deployable_count =
            tostring(math.min(#reserves, #deployment.empty_slots)),
        data_deployment_capacity = tostring(deployment.capacity),
        data_deployed_count = tostring(deployment.deployed),
        data_empty_deployment_slot_count =
            tostring(#deployment.empty_slots),
        data_manager_integrity_interval_ms =
            tostring(CONFIG.raid_manager_integrity_interval_ms),
        data_bulk_deploy_batch_size =
            tostring(CONFIG.raid_bulk_deploy_batch_size),
        data_bulk_deploy_interval_ms =
            tostring(CONFIG.raid_bulk_deploy_interval_ms),
        data_reserve_queue_capacity =
            tostring(CONFIG.raid_reserve_queue_capacity),
        data_manager_timeout_ms =
            tostring(CONFIG.raid_manager_timeout_ms),
    }
    if dry_run then
        details.data_validated = "true"
        return true,
            "Raid Manager activation validated; no state changed.",
            details
    end

    -- Start from the same baseline every stop leaves behind, then apply the
    -- live activation values. A new session also zeroes the cumulative
    -- counters that a stop deliberately preserves.
    pcb_reset_raid_manager_state()
    raid_manager.mode = mode
    raid_manager.base_id = base_id
    raid_manager.stopped_reason = ""
    raid_manager.replacement_count = 0
    raid_manager.deployment_count = 0
    raid_manager.sequence = 0
    raid_manager.manager_state = MANAGER_STATE_ACTIVE
    raid_manager.reserves = reserves
    raid_manager.healthy_palbox_count =
        tonumber(reserve_diagnostics.healthy) or #reserves
    raid_manager.palbox_occupied_count =
        tonumber(reserve_diagnostics.occupied) or 0
    raid_manager.deployment_capacity = deployment.capacity
    raid_manager.deployed_count = deployment.deployed
    raid_manager.queue_built_at_ms = now_ms()
    raid_manager.queue_rebuild_count = 1
    raid_manager.queue_rebuild_reason = "activation"
    raid_manager.started_at_ms = now_ms()
    raid_manager.last_check_at_ms = raid_manager.started_at_ms
    raid_manager.roster_model = deployment.model
    raid_manager.roster_director = deployment.director
    raid_manager.roster_container = deployment.container
    raid_manager.worker_move_identity = pcb_worker_move_identity(
        base_id,
        deployment.model,
        deployment.container
    )

    local deployed_now = 0
    local replaced_now = 0
    if mode == "auto" then
        deployed_now, replaced_now =
            pcb_run_base_reinforcement_pass("activation")
    end
    local world_refresh_ok = true
    local world_refresh_error = ""
    if deployed_now == 0 and replaced_now == 0 then
        world_refresh_ok, world_refresh_error =
            pcb_refresh_base_worker_world(base_id)
    else
        world_refresh_ok = raid_manager.mode ~= "off"
        if not world_refresh_ok then
            world_refresh_error = raid_manager.stopped_reason
        end
    end
    details.data_worker_world_refresh =
        world_refresh_ok and "true" or "false"
    details.data_worker_world_refresh_error = world_refresh_error
    details.data_manager_status = raid_manager.manager_state
    details.data_deployed_immediately = tostring(deployed_now)
    details.data_replaced_immediately = tostring(replaced_now)
    details.data_deployment_capacity =
        tostring(raid_manager.deployment_capacity)
    details.data_deployed_count =
        tostring(raid_manager.deployed_count)
    details.data_empty_deployment_slot_count =
        tostring(
            math.max(
                0,
                raid_manager.deployment_capacity -
                    raid_manager.deployed_count
            )
        )
    details.data_expected_fighter_queue_count =
        tostring(#raid_manager.reserves)
    if not raid_manager.zero_healthy_warned then
        notify(
            "normal",
            mode == "auto" and
                "PalCom: Raid Manager active for " ..
                    base_name .. "." or
                "PalCom: Raid Manager observing " ..
                    base_name .. "."
        )
    end
    return true, "Raid Manager activated for the current base.", details
end

-- Reflection dumps for the reserve, raid, and combat surfaces. These are
-- diagnostic only: every caller pays a full class walk, so they are emitted
-- exclusively for an explicit include_probe request.
local function pcb_raid_probe_fields(raid_context, first_individual)
    return {
        data_raid_area_objects =
            table.concat(pcb_raid_area_object_probe(), "|"),
        data_raid_metadata_surface =
            table.concat(pcb_raid_metadata_surface(), "|"),
        data_raid_module_declared = table.concat(
            declared_function_surface(raid_context.module),
            "|"
        ),
        data_palbox_metadata_surface =
            table.concat(pcb_palbox_metadata_surface(), "|"),
        data_surface_probe = table.concat(
            pcb_combat_surface("fighter.individual", first_individual),
            "|"
        ),
    }
end

local function pcb_get_raid_state(command)
    local include_probe =
        tostring(command.include_probe or "false") == "true"
    local include_reserves =
        tostring(command.include_reserves or "false") == "true"
    local context = player_context(true, false)
    local base_id = tostring(context.data_current_base_id or "")
    local owned = context.data_current_base_is_owned == "true"
    local deployment = pcb_raid_deployment_state(base_id)
    -- Scanning the Palbox is the most expensive read this command can make.
    -- A running manager already maintains an authoritative queue, so rescan
    -- only when asked or when no queue exists to report.
    local scan_reserves =
        include_reserves or raid_manager.mode == "off"
    local diagnostics = {}
    local reserves = raid_manager.reserves
    local healthy_count = raid_manager.healthy_palbox_count
    local occupied_count = raid_manager.palbox_occupied_count
    if scan_reserves then
        reserves = pcb_collect_raid_reserves(diagnostics)
        healthy_count = tonumber(diagnostics.healthy) or #reserves
        occupied_count = tonumber(diagnostics.occupied) or 0
    end
    local first_individual = nil
    local fighters = {}
    local downed_count = 0
    if is_valid(deployment.container) then
        for _, entry in ipairs(
            pcb_container_slots(deployment.container)
        ) do
            local pal_id, character_id, nickname, _, individual =
                pcb_slot_identity(entry.slot)
            if is_guid(pal_id) then
                local combat =
                    pcb_pal_combat_state(nil, nil, individual)
                if combat.downed_known and combat.downed then
                    downed_count = downed_count + 1
                end
                first_individual = first_individual or individual
                table.insert(fighters, {
                    character_id = character_id,
                    downed = combat.downed,
                    downed_known = combat.downed_known,
                    hp = combat.hp,
                    index = entry.index,
                    level = combat.level,
                    nickname = nickname,
                    pal_id = pal_id,
                })
            end
        end
    end
    table.sort(fighters, function(left, right)
        local left_level = left.level or -1
        local right_level = right.level or -1
        if left_level ~= right_level then
            return left_level > right_level
        end
        return left.pal_id < right.pal_id
    end)
    local fighter_records = {}
    for _, fighter in ipairs(fighters) do
        table.insert(fighter_records, table.concat({
            tostring(fighter.index),
            fighter.pal_id,
            fighter.character_id,
            fighter.nickname,
            fighter.level == nil and "" or
                tostring(fighter.level),
            fighter.hp == nil and "" or tostring(fighter.hp),
            fighter.downed and "true" or "false",
            fighter.downed_known and "true" or "false",
        }, "~"))
    end
    local reserve_records = pcb_reserve_records(reserves, 64)
    local queue_age_ms = raid_manager.queue_built_at_ms > 0 and
        math.max(0, now_ms() - raid_manager.queue_built_at_ms) or 0
    local elapsed_ms = raid_manager.started_at_ms > 0 and
        math.max(0, now_ms() - raid_manager.started_at_ms) or 0
    local raid_instance, _, _, raid_context =
        pcb_raid_area_roster(base_id)
    local fields = {
        data_base_id = base_id,
        data_base_name =
            tostring(context.data_current_base_name or ""),
        data_current_base_is_owned = owned and "true" or "false",
        data_fighter_count = tostring(#fighters),
        data_fighters = table.concat(fighter_records, "|"),
        data_downed_count = tostring(downed_count),
        data_deployment_capacity = tostring(deployment.capacity),
        data_deployed_count = tostring(deployment.deployed),
        data_empty_deployment_slot_count =
            tostring(#deployment.empty_slots),
        data_automatic_deployment_available =
            deployment.automatic_available and "true" or "false",
        data_automatic_deployable_count =
            tostring(
                deployment.automatic_available and
                    math.min(#reserves, #deployment.empty_slots) or 0
            ),
        data_palbox_healthy_count = tostring(healthy_count),
        data_palbox_occupied_count = tostring(occupied_count),
        data_reserves = table.concat(reserve_records, "|"),
        data_reserves_live = scan_reserves and "true" or "false",
        data_reserves_truncated =
            #reserves > #reserve_records and "true" or "false",
        data_deployment_count =
            tostring(raid_manager.deployment_count),
        data_replacement_count =
            tostring(raid_manager.replacement_count),
        data_manager_mode = raid_manager.mode,
        data_manager_status = raid_manager.manager_state,
        data_manager_stopped_reason = raid_manager.stopped_reason,
        data_manager_integrity_interval_ms =
            tostring(CONFIG.raid_manager_integrity_interval_ms),
        data_manager_timeout_ms =
            tostring(CONFIG.raid_manager_timeout_ms),
        data_manager_elapsed_ms = tostring(elapsed_ms),
        data_raid_area_instance = full_name(raid_instance),
        data_raid_area_phase =
            tostring(raid_context.phase or ""),
        data_raid_area_phase_state =
            full_name(raid_context.phase_state),
        data_raid_area_state_machine =
            full_name(raid_context.state_machine),
        data_expected_fighter_queue_count =
            tostring(#raid_manager.reserves),
        data_expected_fighter_queue_age_ms =
            tostring(queue_age_ms),
        data_expected_fighter_queue_rebuild_count =
            tostring(raid_manager.queue_rebuild_count),
        data_expected_fighter_queue_rebuild_interval_ms =
            tostring(CONFIG.raid_queue_rebuild_interval_ms),
        data_expected_fighter_queue_last_reason =
            raid_manager.queue_rebuild_reason,
        data_expected_fighter_queue_invalidated_count =
            tostring(raid_manager.invalidated_reserve_count),
    }
    if include_probe then
        add_fields(
            fields,
            pcb_raid_probe_fields(raid_context, first_individual)
        )
        fields.data_reserve_probe =
            table.concat(diagnostics.samples or {}, "|")
    end
    return true, "Current base reinforcement state inspected.", fields
end

local function request_reinforcement_pass(reason)
    if raid_manager.mode == "off" then
        return
    end
    scheduler_metrics.reinforcement_event_requests =
        scheduler_metrics.reinforcement_event_requests + 1
    if raid_manager.reinforcement_pass_running or
        raid_manager.reinforcement_pass_requested then
        scheduler_metrics.reinforcement_event_coalesced =
            scheduler_metrics.reinforcement_event_coalesced + 1
        return
    end
    raid_manager.reinforcement_pass_requested = true
    raid_manager.reinforcement_request_reason =
        tostring(reason or "event")
end

local function pcb_raid_manager_tick()
    if raid_manager.mode == "off" then
        return
    end
    local current_ms = now_ms()
    local event_requested =
        raid_manager.reinforcement_pass_requested == true
    if raid_manager.started_at_ms > 0 and
        current_ms - raid_manager.started_at_ms >=
            CONFIG.raid_manager_timeout_ms then
        pcb_stop_raid_manager(
            "15-minute safety timeout reached",
            true
        )
        return
    end
    if event_requested and
        raid_manager.reinforcement_request_reason ==
            "bulk-deployment-continuation" and
        raid_manager.next_bulk_deploy_at_ms > current_ms then
        return
    end
    local integrity_due = raid_manager.last_check_at_ms == 0 or
        current_ms - raid_manager.last_check_at_ms >=
            CONFIG.raid_manager_integrity_interval_ms
    local queue_due = raid_manager.queue_built_at_ms == 0 or
        current_ms - raid_manager.queue_built_at_ms >=
            CONFIG.raid_queue_rebuild_interval_ms
    if not event_requested and not integrity_due and not queue_due then
        return
    end
    raid_manager.last_check_at_ms = current_ms
    if queue_due then
        pcb_rebuild_raid_queue("periodic")
        if #raid_manager.reserves > 0 then
            raid_manager.zero_healthy_warned = false
        end
    end
    if event_requested then
        scheduler_metrics.reinforcement_event_passes =
            scheduler_metrics.reinforcement_event_passes + 1
    else
        scheduler_metrics.reinforcement_integrity_passes =
            scheduler_metrics.reinforcement_integrity_passes + 1
    end
    local reason = event_requested and
        raid_manager.reinforcement_request_reason or
        (queue_due and "queue-refresh" or "integrity")
    local deployments, replacements =
        pcb_run_base_reinforcement_pass(reason)
    -- Work found by a periodic pass is work the event hooks did not request.
    -- Counting it is what tells us whether the fallback can eventually go.
    if not event_requested and (deployments > 0 or replacements > 0) then
        scheduler_metrics.reinforcement_integrity_effective =
            scheduler_metrics.reinforcement_integrity_effective + 1
    end
end

function pcb_move_pal_roster(command, dry_run)
    local direction = tostring(command.direction or "")
    local base_id = tostring(command.base_id or "")
    local pal_id = tostring(command.pal_id or "")
    if direction ~= "to_base" and direction ~= "to_palbox" then
        return false, "direction must be to_base or to_palbox.", {}
    end
    if not is_guid(base_id) or not is_guid(pal_id) then
        return false, "base_id and pal_id must be valid live IDs.", {}
    end

    local model, director, container = pcb_base_roster(base_id)
    local storage = pcb_player_pal_storage()
    local network = pcb_live_network_container()
    local base_network = pcb_live_network_base_camp()
    if not is_valid(director) or not is_valid(container) then
        return false, "The requested loaded base roster is unavailable.", {}
    end
    if not is_valid(storage) or not is_valid(network) or
        not is_valid(base_network) then
        return false, "The live Palbox network surface is unavailable.", {}
    end

    local base_pal_slot, empty_base_slot =
        pcb_find_base_slot(container, pal_id)
    local palbox_pal_slot = pcb_find_palbox_slot(storage, pal_id)
    local source = nil
    local target = nil
    local source_location = ""
    local target_location = ""
    local already_there = false
    if direction == "to_base" then
        already_there = base_pal_slot ~= nil
        source = palbox_pal_slot
        target = empty_base_slot
        if source ~= nil then
            source_location =
                "palbox:" .. tostring(source.page) .. ":" ..
                tostring(source.index)
        end
        if target ~= nil then
            target_location = "base:" .. tostring(target.index)
        end
    else
        already_there = palbox_pal_slot ~= nil
        source = base_pal_slot
        target = pcb_find_empty_palbox_slot(storage)
        if source ~= nil then
            source_location = "base:" .. tostring(source.index)
        end
        if target ~= nil then
            target_location =
                "palbox:" .. tostring(target.page) .. ":" ..
                tostring(target.index)
        end
    end

    local base_label = is_valid(model) and base_name(model, base_id) or
        friendly_base_name("", base_id)
    if already_there then
        local text = direction == "to_base" and
            "Companion: Pal is already assigned to " .. base_label .. "." or
            "Companion: Pal is already in the Palbox."
        if not dry_run then
            notify("normal", text)
        end
        return true, "Pal is already in the requested roster.", {
            data_already_there = "true",
            data_base_id = base_id,
            data_direction = direction,
            data_pal_id = pal_id,
            data_verified = "true",
        }
    end
    if source == nil then
        return false, "Pal was not found in the expected source roster.", {}
    end
    if target == nil then
        return false, direction == "to_base" and
            "The base roster has no empty slot." or
            "The Palbox has no empty slot.", {}
    end
    if dry_run then
        return true, "Roster move validated; no live state changed.", {
            data_base_id = base_id,
            data_direction = direction,
            data_pal_id = pal_id,
            data_source = source_location,
            data_target = target_location,
            data_validated = "true",
        }
    end

    local source_slot_id = nil
    local target_slot_id = nil
    pcall(function()
        source_slot_id = source.slot:GetSlotId()
        target_slot_id = target.slot:GetSlotId()
    end)
    if source_slot_id == nil or target_slot_id == nil then
        notify("warning", "Companion: roster move failed; slot IDs unavailable.")
        return false, "Source or target slot ID is unavailable.", {}
    end

    local identity = pcb_worker_move_identity(base_id, model, container)
    if identity == nil then
        notify(
            "warning",
            "Companion: roster move failed; base identity unavailable."
        )
        return false, "Base, Palbox, or map-object identity is unavailable.", {}
    end

    -- Match the Palbox UI's authoritative move operation. Swapping with an
    -- empty slot updates storage but bypasses the worker spawn lifecycle.
    local to_base = direction == "to_base"
    local request_method = to_base and
        "RequestMoveCharacterToWorker_ToServer" or
        "RequestMoveWorkerToPalBox_ToServer"
    local request_ok, request_error
    if to_base then
        request_ok, request_error =
            pcb_request_worker_deploy(identity, source_slot_id)
    else
        request_ok, request_error = pcb_request_worker_withdraw(
            identity,
            source_slot_id,
            target.page
        )
    end
    local target_pal_id = pcb_slot_identity(target.slot)
    if request_ok and
        pcb_move_verified(source.slot, target.slot, pal_id) then
        local text = to_base and
            "Companion: moved Pal into " .. base_label .. "'s roster." or
            "Companion: moved Pal from " .. base_label .. " to the Palbox."
        local displayed, notification_error =
            notify("normal", text)
        return true, "Roster move applied and verified.", {
            data_base_id = base_id,
            data_direction = direction,
            data_notification_displayed =
                displayed and "true" or "false",
            data_notification_error = notification_error or "",
            data_pal_id = pal_id,
            data_palbox_map_object = identity.palbox_map_object,
            data_request_method = request_method,
            data_source = source_location,
            data_target = target_location,
            data_verified = "true",
        }
    end

    local rollback_ok = false
    local rollback_error = ""
    if target_pal_id == pal_id then
        local ok, error_value
        if to_base then
            ok, error_value = pcb_request_worker_withdraw(
                identity,
                target_slot_id,
                source.page
            )
        else
            ok, error_value =
                pcb_request_worker_deploy(identity, target_slot_id)
        end
        rollback_ok = ok and
            pcb_slot_identity(source.slot) == pal_id
        if not ok then
            rollback_error = tostring(error_value)
        end
    end
    notify(
        "warning",
        rollback_ok and
            "Companion: roster move failed; previous roster restored." or
            "Companion: roster move failed; rollback could not be verified."
    )
    return false, request_ok and
        "Roster move did not verify." or tostring(request_error), {
        data_base_id = base_id,
        data_direction = direction,
        data_pal_id = pal_id,
        data_rollback_error = rollback_error,
        data_rollback_verified = rollback_ok and "true" or "false",
        data_verified = "false",
    }
end

local function execute_command(command)
    local action = command.action or ""
    local dry_run = command.dry_run ~= "false"
    local settings = get_settings()
    if not settings.enabled then
        return false, "bridge disabled by bridge-settings.pcb", {}
    end
    if not dry_run and not settings.write_actions_enabled then
        return false, "write actions disabled by bridge-settings.pcb", {}
    end

    if action == "get_player_context" then
        return true, "Live player context read.", player_context(true, false)
    end
    if action == "get_inventory_snapshot" then
        return true, "Live inventory snapshot attempted.", inventory_snapshot()
    end
    if action == "list_bases" then
        return true, "Loaded live bases and inventory capability listed.",
            list_base_inventories()
    end
    if action == "get_base_inventory_snapshot" then
        return base_inventory_snapshot(command)
    end
    if action == "list_base_workers" then
        return list_base_workers(command)
    end
    if action == "list_workstations" then
        return list_workstations(command)
    end
    if action == "assign_pal_to_station" then
        return assign_pal_to_station(command, dry_run)
    end
    if action == "list_palbox_page" then
        return pcb_list_palbox_page(command)
    end
    if action == "get_base_roster" then
        return pcb_get_base_roster(command)
    end
    if action == "get_raid_state" then
        return pcb_get_raid_state(command)
    end
    if action == "set_raid_manager" then
        return pcb_set_raid_manager(command, dry_run)
    end
    if action == "swap_raid_pal" then
        return pcb_swap_raid_pal(command, dry_run)
    end
    if action == "move_pal_roster" then
        return pcb_move_pal_roster(command, dry_run)
    end
    if action == "show_notification" then
        return show_notification(command, dry_run)
    end
    if action == "discover_palcom_functions" then
        return discover_palcom_functions()
    end
    return false, "action is not allowlisted", {}
end

local function write_response(command, success, message, data)
    local response = {
        action = command.action or "unknown",
        command_id = command.command_id or "unknown",
        dry_run = command.dry_run or "true",
        idempotency_key = command.idempotency_key or "unknown",
        message = message or "",
        success = success and "true" or "false",
    }
    for key, value in pairs(data or {}) do
        response[key] = value
    end
    local payload = encode_message(response)
    local written, write_error = atomic_write(paths.response, payload)
    if written then
        processed_actions[response.idempotency_key] = payload
    else
        debug_log("response write failed: " .. tostring(write_error))
    end
end

local function palcom_trim(value)
    return string.gsub(
        string.gsub(tostring(value or ""), "^%s+", ""),
        "%s+$",
        ""
    )
end

local function palcom_status(require_fresh)
    local payload = read_file(paths.palcom_status)
    if payload == nil then
        return nil
    end
    local status = decode_message(payload)
    if status == nil then
        return nil
    end
    if require_fresh == false then
        return status
    end
    if status.ready ~= "true" then
        return nil
    end
    local lease_until = tonumber(status.lease_until_epoch_ms) or 0
    if lease_until <= now_ms() then
        return nil
    end
    local prefix = palcom_trim(status.prefix)
    if prefix == "" then
        return nil
    end
    return status
end

local function palcom_bootstrap()
    local payload = read_file(paths.palcom_bootstrap)
    if payload == nil then
        return nil
    end
    local bootstrap = decode_message(payload)
    if bootstrap == nil or bootstrap.enabled ~= "true" then
        return nil
    end
    return bootstrap
end

local function palcom_prefixes()
    local status = palcom_status(false)
    local prefix = status and palcom_trim(status.prefix) or ""
    local aliases = status and tostring(status.aliases or "") or ""
    if prefix == "" or aliases == "" then
        local bootstrap = palcom_bootstrap()
        if prefix == "" then
            prefix = bootstrap and palcom_trim(bootstrap.prefix) or ""
        end
        if aliases == "" then
            aliases = bootstrap and tostring(bootstrap.aliases or "") or ""
        end
    end
    prefix = prefix ~= "" and prefix or "Hey PalCom,"

    local prefixes = {}
    local seen = {}
    local function add_prefix(value)
        value = palcom_trim(value)
        local key = string.lower(value)
        if value ~= "" and not seen[key] then
            seen[key] = true
            table.insert(prefixes, value)
        end
    end
    add_prefix(prefix)
    for alias in string.gmatch(aliases, "[^\r\n]+") do
        add_prefix(alias)
    end
    table.sort(prefixes, function(left, right)
        return string.len(left) > string.len(right)
    end)
    return prefixes
end

local function palcom_private_message(speaker, message, priority)
    local maximum = math.max(
        40,
        CONFIG.maximum_message_length - string.len(speaker) - 3
    )
    local remaining = palcom_trim(message)
    while remaining ~= "" do
        local chunk = string.sub(remaining, 1, maximum)
        if string.len(remaining) > maximum then
            local boundary = nil
            for index = string.len(chunk), 1, -1 do
                if string.sub(chunk, index, index) == " " then
                    boundary = index
                    break
                end
            end
            if boundary ~= nil and boundary > math.floor(maximum / 2) then
                chunk = string.sub(chunk, 1, boundary - 1)
            end
        end
        local notification =
            speaker .. ": " .. palcom_trim(chunk)
        local notification_priority = priority or 1
        display_notification(notification, notification_priority)
        remaining = palcom_trim(
            string.sub(remaining, string.len(chunk) + 1)
        )
    end
end

local function palcom_context()
    local ok, context = pcall(function()
        return player_context(true, false)
    end)
    return ok and context or {}
end

local function start_palcom_broker()
    local settings = get_settings()
    if not settings.palcom_lazy_start_enabled then
        return false, "automatic startup is disabled in bridge-settings.pcb"
    end
    local bootstrap = palcom_bootstrap()
    local launcher = bootstrap and palcom_trim(bootstrap.launcher) or ""
    if launcher == "" then
        return false, "the PalCom launcher has not been provisioned"
    end
    if string.find(launcher, "[\r\n\"]") or
        string.sub(string.lower(launcher), -4) ~= ".cmd" then
        return false, "the provisioned PalCom launcher is invalid"
    end

    local current_ms = now_ms()
    if current_ms - palcom_last_start_attempt_ms <
        CONFIG.palcom_broker_start_retry_ms then
        return true, "a startup attempt is already in progress"
    end
    palcom_last_start_attempt_ms = current_ms

    local command = 'start "" /b "' .. launcher .. '"'
    local ok, result, mode, code = pcall(os.execute, command)
    local launched = ok and (
        result == true or result == 0 or
        (mode == "exit" and tonumber(code) == 0)
    )
    if not launched then
        return false, "the launcher command failed"
    end
    return true, "startup requested"
end

local function palcom_start_failure_message(start_message)
    if start_message == "the PalCom launcher has not been provisioned" then
        return
            "PalCom setup is incomplete: no broker launcher was provisioned. " ..
            "In palworld-mcp.local.json, set liveBridgeEnabled=true and " ..
            "palComChatEnabled=true, then start the normal " ..
            "palworld-mcp-server once. This creates " ..
            "%LOCALAPPDATA%\\PalworldCompanionBridge\\palcom-launch.cmd. " ..
            "See 'Private in-game PalCom chat' in the server README."
    end
    if start_message ==
        "automatic startup is disabled in bridge-settings.pcb" then
        return
            "The PalCom broker is offline because automatic startup is " ..
            "disabled in bridge-settings.pcb. Start " ..
            "palworld-mcp-server.exe --palcom-agent manually, or set " ..
            "palcom_lazy_start_enabled=true and try again."
    end
    if start_message == "the provisioned PalCom launcher is invalid" then
        return
            "PalCom setup is invalid: the provisioned broker launcher is " ..
            "unsafe or malformed. Start the normal palworld-mcp-server once " ..
            "to recreate palcom-launch.cmd, then try again."
    end
    if start_message == "the launcher command failed" then
        return
            "PalCom could not run its broker launcher. Start " ..
            "palworld-mcp-server.exe --palcom-agent manually and check its " ..
            "console output for the startup error."
    end
    return
        "The PalCom broker is offline and could not be started: " ..
        tostring(start_message) .. "."
end

local function submit_palcom_request(message, broker_start_deadline_at_ms)
    if read_file(paths.palcom_request) ~= nil or palcom_pending ~= nil then
        palcom_private_message(
            "PalCom",
            "I'm still working on your previous message.",
            2
        )
        return true
    end

    palcom_request_counter = palcom_request_counter + 1
    local request_id = table.concat({
        tostring(os.time()),
        tostring(palcom_request_counter),
        tostring(math.random(100000, 999999)),
    }, "-")
    local context = palcom_context()
    local request = {
        action = "palcom_chat",
        current_base_id = context.data_current_base_id or "",
        current_base_name = context.data_current_base_name or "",
        message = message,
        player_id = context.data_player_id or "",
        request_id = request_id,
        timestamp_utc = timestamp(),
    }
    local written, write_error = atomic_write(
        paths.palcom_request,
        encode_message(request)
    )
    if not written then
        palcom_private_message(
            "PalCom",
            "I couldn't queue that message: " .. tostring(write_error),
            3
        )
        return false
    end

    local submitted_at_ms = now_ms()
    palcom_pending = {
        broker_start_deadline_at_ms = broker_start_deadline_at_ms,
        request_id = request_id,
        submitted_at_ms = submitted_at_ms,
        next_response_probe_at_ms =
            submitted_at_ms +
                CONFIG.palcom_response_initial_interval_ms,
        response_probe_interval_ms =
            CONFIG.palcom_response_initial_interval_ms,
    }
    palcom_private_message("You -> PalCom", message, 1)
    palcom_private_message("PalCom", "Thinking...", 1)
    return true
end

local function poll_palcom_response()
    if palcom_pending == nil then
        return
    end
    local current_ms = now_ms()
    local pending_age_ms =
        math.max(0, current_ms - palcom_pending.submitted_at_ms)
    local start_deadline = tonumber(
        palcom_pending.broker_start_deadline_at_ms
    ) or 0
    if start_deadline > 0 and current_ms >= start_deadline and
        palcom_status() == nil then
        os.remove(paths.palcom_request)
        palcom_pending = nil
        palcom_private_message(
            "PalCom",
            "The broker did not start. Start palworld-mcp-server.exe " ..
                "--palcom-agent manually and try again.",
            3
        )
        append_audit(
            "palcom_broker_start_timeout",
            "palcom_chat",
            "none",
            ""
        )
        return
    end
    if pending_age_ms >= CONFIG.palcom_response_timeout_ms then
        scheduler_metrics.palcom_response_timeouts =
            scheduler_metrics.palcom_response_timeouts + 1
        palcom_pending = nil
        palcom_private_message(
            "PalCom",
            "That took too long. Please try again.",
            3
        )
        return
    end
    if current_ms <
        (palcom_pending.next_response_probe_at_ms or 0) then
        return
    end

    local interval_ms =
        CONFIG.palcom_response_initial_interval_ms
    if pending_age_ms >= CONFIG.palcom_response_slow_after_ms then
        interval_ms = CONFIG.palcom_response_slow_interval_ms
    elseif pending_age_ms >=
        CONFIG.palcom_response_working_after_ms then
        interval_ms = CONFIG.palcom_response_working_interval_ms
    end
    palcom_pending.response_probe_interval_ms = interval_ms
    palcom_pending.next_response_probe_at_ms =
        current_ms + interval_ms
    scheduler_metrics.palcom_response_probes =
        scheduler_metrics.palcom_response_probes + 1
    local payload = read_file(paths.palcom_response)
    if payload ~= nil then
        local response = decode_message(payload)
        if response ~= nil and
            response.request_id == palcom_pending.request_id then
            os.remove(paths.palcom_response)
            palcom_pending = nil
            scheduler_metrics.palcom_responses_received =
                scheduler_metrics.palcom_responses_received + 1
            scheduler_metrics.last_palcom_response_latency_ms =
                pending_age_ms
            palcom_private_message(
                "PalCom",
                response.message or "I didn't receive an answer.",
                response.success == "true" and 1 or 3
            )
            return
        end
    end
end

discover_palcom_functions = function()
    local matches = {}
    local ok, functions = pcall(function()
        return FindObjects(0, "Function", nil, nil, nil, false)
    end)
    if ok and type(functions) == "table" then
        for _, unreal_function in ipairs(functions) do
            local name = full_name(unreal_function)
            local lower = string.lower(name)
            if string.find(lower, "chat", 1, true) or
                string.find(lower, "sendmessage", 1, true) or
                string.find(lower, "submit", 1, true) then
                table.insert(matches, name)
                if string.find(
                    lower,
                    "palplayerstate:enterchat",
                    1,
                    true
                ) or string.find(
                    lower,
                    "wbp_palchatuicontroloverlay_c:sendchat",
                    1,
                    true
                ) then
                    pcall(function()
                        unreal_function:ForEachProperty(function(property)
                            local property_name = tostring(property)
                            pcall(function()
                                property_name = property:GetFullName()
                            end)
                            table.insert(
                                matches,
                                "    PARAM " .. property_name
                            )
                            return false
                        end)
                    end)
                end
            end
        end
    end
    table.sort(matches)
    atomic_write(
        paths.palcom_functions,
        table.concat(matches, "\n") .. "\n"
    )
    debug_log(
        "PalCom function discovery found " .. tostring(#matches) ..
        " loaded candidates"
    )
    return true, "PalCom function discovery completed.", {
        data_candidate_count = tostring(#matches),
        data_output_available = "true",
    }
end

local function install_palcom_chat_hook()
    local hook_key = "__palworld_companion_palcom_chat_hook"
    local old_hook = _G[hook_key]
    if type(old_hook) == "table" and
        type(UnregisterHook) == "function" then
        pcall(function()
            UnregisterHook(
                old_hook.path,
                old_hook.pre_id,
                old_hook.post_id
            )
        end)
    end

    if type(RegisterHook) ~= "function" then
        return
    end
    -- EnterChat is the local outbound path. EnterChat_Receive receives an
    -- already-broadcast FPalChatMessage and is therefore too late to suppress.
    local path = "/Script/Pal.PalPlayerState:EnterChat"
    local generation_token = MOD_VERSION .. ":" .. tostring({})
    local ok, pre_id, post_id = pcall(function()
        return RegisterHook(path, function(context, message)
            local current = _G[hook_key]
            if type(current) ~= "table" or
                current.token ~= generation_token then
                return
            end

            local player_state = unwrap(context)
            local local_player_state = find_local_player_state()
            if not is_valid(player_state) or
                not is_valid(local_player_state) or
                full_name(player_state) ~= full_name(local_player_state) then
                return
            end

            local raw_message = palcom_trim(name_string(message))
            local matched_prefix = nil
            local lower_message = string.lower(raw_message)
            for _, prefix in ipairs(palcom_prefixes()) do
                if string.sub(lower_message, 1, string.len(prefix)) ==
                    string.lower(prefix) then
                    matched_prefix = prefix
                    break
                end
            end
            if matched_prefix == nil then
                return
            end
            local prompt = palcom_trim(
                string.sub(raw_message, string.len(matched_prefix) + 1)
            )
            if prompt == "" then
                return
            end

            local suppressed = pcall(function()
                message:set(FText(""))
            end)
            if not suppressed then
                suppressed = pcall(function()
                    message:set("")
                end)
            end
            if not suppressed then
                append_audit(
                    "palcom_suppression_failed",
                    "palcom_chat",
                    "none",
                    ""
                )
                debug_log(
                    "PalCom matched, but chat suppression was unavailable"
                )
                return
            end
            local status = palcom_status()
            local broker_start_deadline_at_ms = nil
            if status == nil then
                local started, start_message = start_palcom_broker()
                if not started then
                    palcom_private_message(
                        "PalCom",
                        palcom_start_failure_message(start_message),
                        3
                    )
                    append_audit(
                        "palcom_broker_start_failed",
                        "palcom_chat",
                        "none",
                        start_message
                    )
                    return
                end
                broker_start_deadline_at_ms =
                    now_ms() + CONFIG.palcom_broker_start_timeout_ms
                palcom_private_message(
                    "PalCom",
                    "The broker was offline; starting it now.",
                    2
                )
                append_audit(
                    "palcom_broker_start_requested",
                    "palcom_chat",
                    "none",
                    start_message
                )
            end
            local submitted = submit_palcom_request(
                prompt,
                broker_start_deadline_at_ms
            )
            append_audit(
                submitted and "palcom_captured" or "palcom_queue_failed",
                "palcom_chat",
                palcom_pending and palcom_pending.request_id or "none",
                ""
            )
        end)
    end)
    if ok then
        os.remove(paths.palcom_response)
        _G[hook_key] = {
            path = path,
            post_id = post_id,
            pre_id = pre_id,
            token = generation_token,
        }
    else
        debug_log("PalCom hook registration failed: " .. tostring(pre_id))
    end
end

local function poll_command()
    scheduler_metrics.command_file_probes =
        scheduler_metrics.command_file_probes + 1
    local payload = read_file(paths.command)
    if payload == nil then
        return
    end
    scheduler_metrics.commands_received =
        scheduler_metrics.commands_received + 1
    local command, decode_error = decode_message(payload)
    if command == nil then
        os.remove(paths.command)
        append_audit("rejected", "unknown", "unknown", decode_error)
        return
    end

    os.remove(paths.command)
    local idempotency_key = command.idempotency_key or "unknown"
    if processed_actions[idempotency_key] ~= nil then
        atomic_write(paths.response, processed_actions[idempotency_key])
        append_audit("replayed", command.action, idempotency_key, "")
        return
    end

    local ok, success, message, data = pcall(execute_command, command)
    if not ok then
        local call_error = success
        success = false
        message = tostring(call_error)
        data = {}
    end
    if command.action ~= "discover_palcom_functions" and
        command.action ~= "show_notification" then
        scheduler.next_readiness_at_ms = 0
    end
    write_response(command, success == true, tostring(message or ""), data or {})
    append_audit(
        success == true and "completed" or "failed",
        command.action,
        idempotency_key,
        message
    )
end

local function refresh_bridge_readiness()
    scheduler_metrics.readiness_refreshes =
        scheduler_metrics.readiness_refreshes + 1
    local controller = find_local_controller()
    local state = nil
    local inventory = nil
    if is_valid(controller) then
        pcall(function()
            state = unwrap(controller:GetPalPlayerState())
        end)
    end
    if is_valid(state) then
        pcall(function()
            inventory = unwrap(state:GetInventoryData())
        end)
    end
    bridge_readiness.controller_available = is_valid(controller)
    bridge_readiness.player_state_available = is_valid(state)
    bridge_readiness.inventory_available = is_valid(inventory)
    bridge_readiness.game_ready =
        bridge_readiness.player_state_available and
        bridge_readiness.inventory_available
    bridge_readiness.refreshed_at_ms = now_ms()
    bridge_readiness.world_key = full_name(controller)
    local detected_base_id = raid_manager.base_id
    if detected_base_id == "" and is_valid(controller) then
        detected_base_id =
            resolve_current_base_id(controller, state)
        if detected_base_id == "" then
            detected_base_id =
                current_base_from_geometry(controller)
        end
        if detected_base_id == "" then
            detected_base_id =
                current_base_from_live_membership()
        end
    end
    raid_detection_state.base_id =
        tostring(detected_base_id or "")
    raid_detection_state.instance = ""
    raid_detection_state.phase = ""
    raid_detection_state.phase_state = ""
    raid_detection_state.state_machine = ""
    raid_detection_state.sampled_at_ms =
        bridge_readiness.refreshed_at_ms
    if is_guid(raid_detection_state.base_id) then
        local instance, _, _, raid_context =
            pcb_raid_area_roster(raid_detection_state.base_id)
        raid_detection_state.instance = full_name(instance)
        raid_detection_state.phase =
            tostring(raid_context.phase or "")
        raid_detection_state.phase_state =
            full_name(raid_context.phase_state)
        raid_detection_state.state_machine =
            full_name(raid_context.state_machine)
        pcb_observe_raid_phase(instance, raid_context)
    end
    if not bridge_readiness.game_ready then
        scheduler_metrics.readiness_failures =
            scheduler_metrics.readiness_failures + 1
    end
end

local function write_heartbeat()
    local settings = get_settings()
    local palcom_pending_age_ms = palcom_pending ~= nil and
        math.max(
            0,
            now_ms() - palcom_pending.submitted_at_ms
        ) or 0
    local palcom_probe_interval_ms = palcom_pending ~= nil and
        tonumber(palcom_pending.response_probe_interval_ms) or 0
    local readiness_age_ms =
        bridge_readiness.refreshed_at_ms > 0 and
            math.max(
                0,
                now_ms() - bridge_readiness.refreshed_at_ms
            ) or -1
    local heartbeat = {
        bridge_version = MOD_VERSION,
        capabilities =
            "get_player_context,get_inventory_snapshot,list_bases," ..
            "get_base_inventory_snapshot,list_base_workers," ..
            "list_workstations,assign_pal_to_station," ..
            "list_palbox_page,get_base_roster,move_pal_roster," ..
            "get_raid_state,swap_raid_pal," ..
            "set_raid_manager," ..
            "discover_palcom_functions," ..
            "show_notification",
        enabled = settings.enabled and "true" or "false",
        game_ready =
            bridge_readiness.game_ready and "true" or "false",
        readiness_controller_available =
            bridge_readiness.controller_available and "true" or "false",
        readiness_world_key = bridge_readiness.world_key,
        readiness_age_ms = tostring(readiness_age_ms),
        readiness_refresh_interval_ms =
            tostring(CONFIG.readiness_refresh_interval_ms),
        raid_detection_base_id = raid_detection_state.base_id,
        raid_detection_instance = raid_detection_state.instance,
        raid_detection_phase = raid_detection_state.phase,
        raid_detection_phase_state =
            raid_detection_state.phase_state,
        raid_detection_sample_age_ms =
            raid_detection_state.sampled_at_ms > 0 and
                tostring(
                    math.max(
                        0,
                        now_ms() -
                            raid_detection_state.sampled_at_ms
                    )
                ) or "-1",
        raid_detection_state_machine =
            raid_detection_state.state_machine,
        raid_manager_mode = raid_manager.mode,
        raid_manager_status = raid_manager.manager_state,
        raid_manager_stopped_reason =
            raid_manager.stopped_reason,
        raid_manager_phase_missing_samples =
            tostring(raid_manager.raid_phase_missing_samples),
        raid_manager_phase_seen_battle =
            raid_manager.raid_phase_seen_battle and
                "true" or "false",
        raid_manager_phase_state =
            raid_manager.raid_phase_state,
        raid_manager_bulk_deploy_batch_size =
            tostring(CONFIG.raid_bulk_deploy_batch_size),
        raid_manager_bulk_deploy_interval_ms =
            tostring(CONFIG.raid_bulk_deploy_interval_ms),
        raid_manager_bulk_deploy_pending =
            raid_manager.reinforcement_request_reason ==
                "bulk-deployment-continuation" and
                "true" or "false",
        raid_manager_reserve_queue_capacity =
            tostring(CONFIG.raid_reserve_queue_capacity),
        scheduler_command_file_probes =
            tostring(scheduler_metrics.command_file_probes),
        scheduler_commands_received =
            tostring(scheduler_metrics.commands_received),
        scheduler_heartbeat_writes =
            tostring(scheduler_metrics.heartbeat_writes + 1),
        scheduler_last_reinforcement_pass_ms =
            tostring(scheduler_metrics.last_reinforcement_pass_ms),
        scheduler_palbox_scans =
            tostring(scheduler_metrics.palbox_scans),
        scheduler_palcom_response_probes =
            tostring(scheduler_metrics.palcom_response_probes),
        scheduler_palcom_responses_received =
            tostring(scheduler_metrics.palcom_responses_received),
        scheduler_palcom_response_timeouts =
            tostring(scheduler_metrics.palcom_response_timeouts),
        scheduler_palcom_pending =
            palcom_pending ~= nil and "true" or "false",
        scheduler_palcom_pending_age_ms =
            tostring(palcom_pending_age_ms),
        scheduler_palcom_response_probe_interval_ms =
            tostring(palcom_probe_interval_ms),
        scheduler_last_palcom_response_latency_ms =
            tostring(
                scheduler_metrics.last_palcom_response_latency_ms
            ),
        scheduler_readiness_refreshes =
            tostring(scheduler_metrics.readiness_refreshes),
        scheduler_reinforcement_event_coalesced =
            tostring(
                scheduler_metrics.reinforcement_event_coalesced
            ),
        scheduler_reinforcement_event_passes =
            tostring(scheduler_metrics.reinforcement_event_passes),
        scheduler_reinforcement_event_requests =
            tostring(scheduler_metrics.reinforcement_event_requests),
        scheduler_reinforcement_integrity_passes =
            tostring(scheduler_metrics.reinforcement_integrity_passes),
        scheduler_reinforcement_integrity_effective =
            tostring(scheduler_metrics.reinforcement_integrity_effective),
        scheduler_last_queue_build_ms =
            tostring(scheduler_metrics.last_queue_build_ms),
        scheduler_reinforcement_hooks_installed =
            tostring(scheduler_metrics.reinforcement_hooks_installed),
        scheduler_roster_scans =
            tostring(scheduler_metrics.roster_scans),
        worker_trace_despawn_requests =
            tostring(scheduler_metrics.worker_trace_despawn_requests),
        worker_trace_director_added =
            tostring(scheduler_metrics.worker_trace_director_added),
        worker_trace_director_removed =
            tostring(scheduler_metrics.worker_trace_director_removed),
        worker_trace_director_reflected =
            tostring(scheduler_metrics.worker_trace_director_reflected),
        worker_trace_model_added =
            tostring(scheduler_metrics.worker_trace_model_added),
        worker_trace_network_moves =
            tostring(scheduler_metrics.worker_trace_network_moves),
        worker_trace_network_swaps =
            tostring(scheduler_metrics.worker_trace_network_swaps),
        worker_trace_slot_updates =
            tostring(scheduler_metrics.worker_trace_slot_updates),
        worker_trace_spawn_callbacks =
            tostring(scheduler_metrics.worker_trace_spawn_callbacks),
        worker_trace_spawn_requests =
            tostring(scheduler_metrics.worker_trace_spawn_requests),
        worker_trace_observer_container =
            tostring(scheduler_metrics.worker_trace_observer_container),
        worker_trace_observer_container_slots =
            tostring(scheduler_metrics.worker_trace_observer_container_slots),
        worker_trace_observer_container_size =
            tostring(scheduler_metrics.worker_trace_observer_container_size),
        scheduler_wakeups =
            tostring(scheduler_metrics.wakeups),
        timestamp_utc = timestamp(),
        write_actions_enabled =
            settings.write_actions_enabled and "true" or "false",
    }
    atomic_write(paths.heartbeat, encode_message(heartbeat))
    scheduler_metrics.heartbeat_writes =
        scheduler_metrics.heartbeat_writes + 1
end

local BRIDGE_LOOP_GENERATION_KEY =
    "__palworld_companion_bridge_loop_generation"
local bridge_loop_generation =
    MOD_VERSION .. ":" .. tostring({})
_G[BRIDGE_LOOP_GENERATION_KEY] = bridge_loop_generation

local function bridge_loop_is_current()
    return _G[BRIDGE_LOOP_GENERATION_KEY] ==
        bridge_loop_generation
end

local function bridge_tick()
    if not bridge_loop_is_current() then
        return
    end
    if bridge_directory == nil then
        return
    end
    local current_ms = now_ms()
    scheduler_metrics.wakeups = scheduler_metrics.wakeups + 1

    -- File-backed IPC uses the documented safe fallback: one probe per
    -- 500 ms scheduler wakeup. PalCom probes only while a reply is pending.
    poll_command()
    if palcom_pending ~= nil then
        poll_palcom_response()
    end

    if scheduler.next_readiness_at_ms == 0 or
        current_ms >= scheduler.next_readiness_at_ms then
        refresh_bridge_readiness()
        scheduler.next_readiness_at_ms =
            current_ms + CONFIG.readiness_refresh_interval_ms
    end
    pcb_raid_manager_tick()
    if scheduler.next_heartbeat_at_ms == 0 or
        current_ms >= scheduler.next_heartbeat_at_ms then
        write_heartbeat()
        scheduler.next_heartbeat_at_ms =
            current_ms + CONFIG.heartbeat_interval_ms
    end
end

local function scheduled_bridge_tick()
    if not bridge_loop_is_current() then
        -- LoopAsync treats true as complete. Some
        -- LoopInGameThreadWithDelay builds ignore the return value, so the
        -- generation check in bridge_tick remains the no-work fallback.
        return true
    end
    bridge_tick()
    return false
end

if type(LoopInGameThreadWithDelay) == "function" then
    LoopInGameThreadWithDelay(
        CONFIG.poll_interval_ms,
        scheduled_bridge_tick
    )
else
    LoopAsync(CONFIG.poll_interval_ms, scheduled_bridge_tick)
end

local function install_reinforcement_event_hooks()
    local hook_key =
        "__palworld_companion_reinforcement_event_hooks"
    local old_hooks = _G[hook_key]
    if type(old_hooks) == "table" and
        type(UnregisterHook) == "function" then
        for _, hook in ipairs(old_hooks.registrations or {}) do
            pcall(function()
                UnregisterHook(
                    hook.path,
                    hook.pre_id,
                    hook.post_id
                )
            end)
        end
    end

    local generation_token = MOD_VERSION .. ":" .. tostring({})
    local state = {
        registrations = {},
        token = generation_token,
    }
    _G[hook_key] = state
    scheduler_metrics.reinforcement_hooks_installed = 0

    local function is_current()
        local current = _G[hook_key]
        return type(current) == "table" and
            current.token == generation_token
    end
    local function register_event(path, reason)
        if type(RegisterHook) ~= "function" then
            return
        end
        local ok, pre_id, post_id = pcall(function()
            return RegisterHook(path, function()
                if not is_current() then
                    return
                end
                request_reinforcement_pass(reason)
            end)
        end)
        if ok then
            table.insert(state.registrations, {
                path = path,
                post_id = post_id,
                pre_id = pre_id,
            })
            scheduler_metrics.reinforcement_hooks_installed =
                scheduler_metrics.reinforcement_hooks_installed + 1
        end
    end

    -- This is the same authoritative container-swap RPC used by roster
    -- writes. UI-driven swaps therefore request an immediate coalesced pass.
    register_event(
        "/Script/Pal.PalNetworkCharacterContainerComponent:" ..
            "RequestSwap_ToServer_Rep",
        "character-container-swap"
    )

    -- Game revisions differ in the name of the authoritative death
    -- transition. Failed registrations are harmless; the one-minute
    -- integrity reconciliation remains the correctness fallback.
    register_event(
        "/Script/Pal.PalCharacterParameterComponent:OnDead",
        "pal-downed"
    )
    register_event(
        "/Script/Pal.PalCharacterParameterComponent:NotifyDead",
        "pal-downed"
    )
    register_event(
        "/Script/Pal.PalBaseCampWorkerDirector:OnDeadWorkerInServer",
        "base-worker-downed"
    )
    register_event(
        "/Script/Pal.PalBaseCampWorkerDirector:" ..
            "OnDeadWorkerInServer_Internal",
        "base-worker-downed"
    )

    if type(NotifyOnNewObject) == "function" then
        pcall(function()
            NotifyOnNewObject(
                "/Script/Pal.PalBaseCampWorkerDirector",
                function()
                    if not is_current() then
                        return true
                    end
                    scheduler.next_readiness_at_ms = 0
                    request_reinforcement_pass(
                        "base-worker-roster-loaded"
                    )
                    return false
                end
            )
        end)
    end
end

local function install_worker_lifecycle_trace_hooks()
    local hook_key = "__palworld_companion_worker_trace_hooks"
    local old_state = _G[hook_key]
    if type(old_state) == "table" and
        type(UnregisterHook) == "function" then
        for _, registration in ipairs(old_state.registrations or {}) do
            pcall(function()
                UnregisterHook(
                    registration.path,
                    registration.pre_id,
                    registration.post_id
                )
            end)
        end
    end

    local generation_token = MOD_VERSION .. ":" .. tostring({})
    local state = {
        registrations = {},
        token = generation_token,
    }
    _G[hook_key] = state
    local function register_trace(path, metric)
        if type(RegisterHook) ~= "function" then
            return
        end
        local ok, pre_id, post_id = pcall(function()
            return RegisterHook(path, function()
                local current = _G[hook_key]
                if type(current) == "table" and
                    current.token == generation_token then
                    scheduler_metrics[metric] =
                        (scheduler_metrics[metric] or 0) + 1
                end
            end)
        end)
        if ok then
            table.insert(state.registrations, {
                path = path,
                post_id = post_id,
                pre_id = pre_id,
            })
        end
    end

    register_trace(
        "/Script/Pal.PalNetworkCharacterContainerComponent:" ..
            "RequestSwap_ToServer_Rep",
        "worker_trace_network_swaps"
    )
    register_trace(
        "/Script/Pal.PalNetworkCharacterContainerComponent:" ..
            "RequestMove_ToServer_Rep",
        "worker_trace_network_moves"
    )
    register_trace(
        "/Script/Pal.PalNetworkCharacterContainerComponent:" ..
            "RequestMoveToPalBox_ToServer_Rep",
        "worker_trace_network_moves"
    )
    register_trace(
        "/Script/Pal.PalIndividualCharacterSlotsObserver:OnUpdateSlot",
        "worker_trace_slot_updates"
    )
    register_trace(
        "/Script/Pal.PalCharacterManager:SpawnCharacterByHandle",
        "worker_trace_spawn_requests"
    )
    register_trace(
        "/Script/Pal.PalBaseCampWorkerDirector:" ..
            "OnSpawnedCharacterInServer",
        "worker_trace_spawn_callbacks"
    )
    register_trace(
        "/Script/Pal.PalCharacterManager:DespawnCharacterByHandle",
        "worker_trace_despawn_requests"
    )
    register_trace(
        "/Script/Pal.PalBaseCampWorkerDirector:" ..
            "OnAddedNewCharacterInServer",
        "worker_trace_director_added"
    )
    register_trace(
        "/Script/Pal.PalBaseCampWorkerDirector:" ..
            "OnRemovedNewCharacterInServer",
        "worker_trace_director_removed"
    )
    register_trace(
        "/Script/Pal.PalBaseCampWorkerDirector:" ..
            "OnReflectSlotCompleteInServer",
        "worker_trace_director_reflected"
    )
    register_trace(
        "/Script/Pal.PalBaseCampModel:OnAddNewWorker",
        "worker_trace_model_added"
    )
    register_trace(
        "/Script/Pal.PalIndividualCharacterSlotsObserver:" ..
            "OnUpdateContainer",
        "worker_trace_observer_container"
    )
    register_trace(
        "/Script/Pal.PalIndividualCharacterSlotsObserver:" ..
            "OnUpdateContainerSlots",
        "worker_trace_observer_container_slots"
    )
    register_trace(
        "/Script/Pal.PalIndividualCharacterSlotsObserver:" ..
            "OnUpdateContainerSize",
        "worker_trace_observer_container_size"
    )
end

local function install_base_cache_invalidation_hooks()
    local hook_key = "__palworld_companion_base_cache_hook"
    local old_hook = _G[hook_key]
    if type(old_hook) == "table" and
        type(UnregisterHook) == "function" then
        pcall(function()
            UnregisterHook(
                old_hook.path,
                old_hook.pre_id,
                old_hook.post_id
            )
        end)
    end

    local generation_token = MOD_VERSION .. ":" .. tostring({})
    _G[hook_key] = {token = generation_token}

    if type(NotifyOnNewObject) == "function" then
        pcall(function()
            NotifyOnNewObject(
                "/Script/Pal.PalMapObjectItemChestModel",
                function()
                    local current = _G[hook_key]
                    if type(current) ~= "table" or
                        current.token ~= generation_token then
                        return true
                    end
                    invalidate_base_membership("container-created")
                    scheduler.next_readiness_at_ms = 0
                    return false
                end
            )
        end)
    end

    if type(RegisterHook) == "function" then
        local path =
            "/Script/Pal.PalMapObjectItemChestModel:" ..
            "OnUpdateContainerContentInServer"
        local ok, pre_id, post_id = pcall(function()
            return RegisterHook(path, function(context)
                local model = unwrap(context)
                local base_id = model_base_id(model)
                invalidate_base_summaries(
                    "container-content-updated",
                    is_zero_guid(base_id) and nil or base_id
                )
            end)
        end)
        if ok then
            _G[hook_key] = {
                path = path,
                post_id = post_id,
                pre_id = pre_id,
                token = generation_token,
            }
        end
    end
end

install_base_cache_invalidation_hooks()
install_reinforcement_event_hooks()
install_worker_lifecycle_trace_hooks()
install_palcom_chat_hook()

debug_log(
    "loaded version=" .. MOD_VERSION ..
    " bridge_directory=" .. tostring(bridge_directory) ..
    " edit mode enabled; set write_actions_enabled=false to opt out"
)
