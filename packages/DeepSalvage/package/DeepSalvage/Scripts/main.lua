local MOD_NAME = "More Fishing Salvage Reward"
local MOD_VERSION = "1.0.5"

local CONFIG = {
    modifier_chance = 1.0,
    risk_failure_chance = 0.0,
    extra_magnet_cost = 1,
    reward_bonus = 1.0,
    attempt_timeout_ms = 120000,
    -- Keep diagnostics in source. Disable them through configuration for release.
    debug_enabled = false,
    debug_notifications = false,
    debug_console = false,
    deep_salvage_notification = true,
    -- A server-only mod can only draw on the machine it runs on. The Deep
    -- Salvage notification therefore goes to the local log manager only when
    -- the salvaging player is the listen-server host. Remote clients are
    -- reachable exclusively through a replicated chat message, which is
    -- opt-in because it must be validated against the live chat enum.
    remote_notification_via_chat = false,
    remote_notification_chat_category = 4,
    remote_notification_sender = "More Fishing Salvage Reward",
    notification_cooldown_ms = 2000,
    notification_display_seconds = 3.0,
}

local PATHS = {
    request_open =
        "/Script/Pal.PalMapObjectTreasureBoxModel:RequestOpen_ServerInternal",
    salvage_result =
        "/Script/Pal.PalMapObjectTreasureBoxModel:OnReceiveSalvageResult",
    create_items =
        "/Script/Pal.PalMapObjectTreasureBoxModel:CreateItemInfo",
    add_item =
        "/Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal",
    obtain_info =
        "/Script/Pal.PalMapObjectTreasureBoxModel:Debug_ReceiveObtainInfo_ClientInternal",
}

local ENUM = {
    passive_fishing_salvage_drop = 119,
}

local attempts_by_model = {}
local magnet_slot_cache = {}
local cached_log_manager = nil
local last_notification_by_event = {}
local callback_seen = {
    request_open = false,
    salvage_result = false,
    create_items = false,
}
local active_reward_attempt = nil
local traced_object_classes = {}
local get_jellroy_multiplier
local round_quantity

math.randomseed(os.time())
math.random()
math.random()
math.random()

local function timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function now_ms()
    return os.time() * 1000
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

local function set_param(parameter, value)
    if parameter == nil then
        return false
    end
    local ok = pcall(function()
        parameter:set(value)
    end)
    return ok
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

local function is_valid(object)
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
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or tostring(object)
end

local function get_owner(object)
    object = unwrap(object)
    if not is_valid(object) then
        return nil
    end
    local ok, owner = pcall(function()
        return object:GetOwner()
    end)
    return ok and unwrap(owner) or nil
end

local function is_fishing_salvage(object)
    object = unwrap(object)
    if not is_valid(object) then
        return false
    end
    local object_name = full_name(object)
    local owner_name = full_name(get_owner(object))
    local special_ok, special_type = pcall(function()
        return tonumber(unwrap(
            object:GetPropertyValue("TreasureSpecialType")
        ))
    end)
    return special_ok and special_type == 1 or
        string.find(object_name, "FishingJunkSpot", 1, true) ~= nil or
        string.find(owner_name, "FishingJunkSpot", 1, true) ~= nil
end

local function notification_priority(level)
    if level == "ERROR" then
        return 3
    end
    if level == "WARN" then
        return 2
    end
    return 1
end

-- Writes to the log manager owned by the machine running this script. On a
-- listen server that is the host's own HUD, never a remote client's.
local function display_local_notification(priority, message, duration_seconds)
    local displayed = false
    pcall(function()
        if not is_valid(cached_log_manager) then
            cached_log_manager = FindFirstOf("PalLogManager")
        end
        if is_valid(cached_log_manager) then
            local duration = math.min(
                3.0,
                math.max(0.1, tonumber(duration_seconds) or 3.0)
            )
            local original_duration = nil
            if duration_seconds ~= nil then
                if priority == 1 then
                    original_duration =
                        tonumber(cached_log_manager.normalLogDisplayTime)
                    cached_log_manager.normalLogDisplayTime = duration
                elseif priority == 2 then
                    original_duration =
                        tonumber(cached_log_manager.importantLogDisplayTime)
                    cached_log_manager.importantLogDisplayTime = duration
                elseif priority == 3 then
                    original_duration =
                        tonumber(cached_log_manager.veryImportantLogDisplayTime)
                    cached_log_manager.veryImportantLogDisplayTime = duration
                end
            end

            local added = pcall(function()
                cached_log_manager:AddLog(priority, FText(message), {})
            end)

            if original_duration ~= nil then
                if priority == 1 then
                    cached_log_manager.normalLogDisplayTime = original_duration
                elseif priority == 2 then
                    cached_log_manager.importantLogDisplayTime = original_duration
                elseif priority == 3 then
                    cached_log_manager.veryImportantLogDisplayTime =
                        original_duration
                end
            end
            displayed = added
        end
    end)
    return displayed
end

local function notify_debug(level, event, fields)
    if not CONFIG.debug_enabled or not CONFIG.debug_notifications then
        return
    end
    local key = tostring(level) .. ":" .. tostring(event)
    local current_ms = now_ms()
    local previous_ms = last_notification_by_event[key]
    if previous_ms ~= nil and
        current_ms - previous_ms < CONFIG.notification_cooldown_ms then
        return
    end

    local summary = {"[More Fishing Salvage Reward]", tostring(event)}
    if fields ~= nil then
        for _, field in ipairs({
            "selected",
            "success",
            "formula_match",
            "reason",
            "reward_comparison",
            "difficulty",
            "risk",
        }) do
            if fields[field] ~= nil then
                table.insert(summary, field .. "=" .. tostring(fields[field]))
            end
        end
    end

    -- Diagnostics stay on the machine running the server by design.
    if display_local_notification(
        notification_priority(level),
        table.concat(summary, " | ")
    ) then
        last_notification_by_event[key] = current_ms
    end
end

local function log(level, event, fields)
    if not CONFIG.debug_enabled then
        return
    end
    if CONFIG.debug_console then
        local parts = {
            string.format("[%s]", MOD_NAME),
            timestamp(),
            "level=" .. tostring(level),
            "event=" .. tostring(event),
        }
        if fields ~= nil then
            local keys = {}
            for key, _ in pairs(fields) do
                table.insert(keys, key)
            end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local value = string.gsub(
                    tostring(fields[key]),
                    "[\r\n|]",
                    " "
                )
                table.insert(parts, tostring(key) .. "=" .. value)
            end
        end
        print(table.concat(parts, " | ") .. "\n")
    end
    notify_debug(level, event, fields)
end

local function roll(chance)
    return math.random() < chance
end

local function find_controller_by_player_id(player_id)
    local ok, controllers = pcall(function()
        return FindObjects(0, "PalPlayerController", nil, nil, nil, false)
    end)
    if not ok or type(controllers) ~= "table" then
        return nil
    end
    for _, controller in ipairs(controllers) do
        if is_valid(controller) then
            local id_ok, state = pcall(function()
                return unwrap(controller:GetPalPlayerState())
            end)
            local value_ok, value = pcall(function()
                return unwrap(state:GetPlayerId())
            end)
            if id_ok and value_ok and tonumber(value) == player_id then
                return controller
            end
        end
    end
    return nil
end

local TOTAL_REWARD_PERCENT =
    math.floor((1.0 + CONFIG.reward_bonus) * 100.0 + 0.5)
local REWARD_ACTIVATION_MESSAGE = string.format(
    "[More Fishing Salvage Reward] Extra Fishing Magnet used; " ..
    "successful salvage grants %d%% total reward.",
    TOTAL_REWARD_PERCENT
)

-- True only for the player sharing the process with this script, which is the
-- listen-server host. Every other salvaging player is a remote client.
local function is_local_controller(controller)
    controller = unwrap(controller)
    if not is_valid(controller) then
        return false
    end
    for _, accessor in ipairs({
        "IsLocalController",
        "IsLocalPlayerController",
    }) do
        local ok, value = pcall(function()
            return unwrap(controller[accessor](controller))
        end)
        if ok and value == true then
            return true
        end
    end
    return false
end

local function attempt_controller(attempt)
    if attempt == nil then
        return nil
    end
    local controller = unwrap(attempt.controller)
    if is_valid(controller) then
        return controller
    end
    local player_id = tonumber(attempt.player_id)
    if player_id == nil then
        return nil
    end
    controller = find_controller_by_player_id(player_id)
    if is_valid(controller) then
        attempt.controller = controller
        return controller
    end
    return nil
end

local function player_unique_id(controller)
    local state = nil
    pcall(function()
        state = unwrap(controller:GetPalPlayerState())
    end)
    if not is_valid(state) then
        return nil
    end
    local raw = nil
    pcall(function()
        raw = unwrap(state:GetPlayerUId())
    end)
    if raw == nil then
        pcall(function()
            raw = unwrap(state.PlayerUId)
        end)
    end
    if raw == nil then
        return nil
    end
    local unique_id = {}
    for _, part in ipairs({"A", "B", "C", "D"}) do
        local value = nil
        pcall(function()
            value = tonumber(unwrap(raw[part]))
        end)
        if value == nil then
            return nil
        end
        unique_id[part] = value
    end
    return unique_id
end

-- Optional replicated delivery for players who are not the host. It fails
-- closed: without a resolved receiver the message is dropped instead of being
-- broadcast to everyone.
local function send_remote_chat_notification(controller, message)
    local receiver = player_unique_id(controller)
    if receiver == nil then
        return false, "receiver-uid-unresolved"
    end
    local game_state = nil
    pcall(function()
        game_state = FindFirstOf("PalGameStateInGame")
    end)
    if not is_valid(game_state) then
        return false, "game-state-unavailable"
    end
    local ok, call_error = pcall(function()
        game_state:BroadcastChatMessage({
            Category = CONFIG.remote_notification_chat_category,
            Sender = CONFIG.remote_notification_sender,
            SenderPlayerUId = {A = 0, B = 0, C = 0, D = 0},
            Message = message,
            ReceiverPlayerUId = receiver,
        })
    end)
    if not ok then
        return false, "chat-call-failed:" .. tostring(call_error)
    end
    return true, ""
end

local function notify_deep_salvage(attempt)
    if not CONFIG.deep_salvage_notification then
        return
    end
    local player_id = attempt ~= nil and attempt.player_id or "unknown"
    local controller = attempt_controller(attempt)
    if not is_valid(controller) then
        log("WARN", "deep_salvage_notification", {
            player_id = player_id,
            delivered = false,
            reason = "controller-unresolved",
        })
        return
    end
    if is_local_controller(controller) then
        local displayed = display_local_notification(
            2,
            REWARD_ACTIVATION_MESSAGE,
            CONFIG.notification_display_seconds
        )
        log(displayed and "INFO" or "WARN", "deep_salvage_notification", {
            player_id = player_id,
            target = "host",
            delivered = displayed,
            reason = displayed and "" or "log-manager-unavailable",
        })
        return
    end
    if not CONFIG.remote_notification_via_chat then
        log("INFO", "deep_salvage_notification", {
            player_id = player_id,
            target = "remote",
            delivered = false,
            reason = "remote-chat-disabled",
        })
        return
    end
    local sent, reason =
        send_remote_chat_notification(controller, REWARD_ACTIVATION_MESSAGE)
    log(sent and "INFO" or "WARN", "deep_salvage_notification", {
        player_id = player_id,
        target = "remote",
        delivered = sent,
        reason = reason,
    })
end

local function get_inventory(controller)
    controller = unwrap(controller)
    if not is_valid(controller) then
        return nil
    end
    local state = nil
    pcall(function()
        state = unwrap(controller:GetPalPlayerState())
    end)
    if not is_valid(state) then
        return nil
    end
    local inventory = nil
    pcall(function()
        inventory = unwrap(state:GetInventoryData())
    end)
    return is_valid(inventory) and inventory or nil
end

local salvage_slot_item_id

local function salvage_magnet_id(model)
    local grade = 1
    pcall(function()
        grade = tonumber(unwrap(model.TreasureGradeType)) or 1
    end)
    if grade >= 1 then
        return "Salvage_TreasureBoxKey02", grade
    end
    return "Salvage_TreasureBoxKey01", grade
end

local function refresh_magnet_slot_cache(item_id)
    local cached_slots = {}
    local scan_ok, scan_error = pcall(function()
        local slots = FindObjects(0, "PalItemSlot", nil, nil, nil, false)
        for _, candidate in ipairs(slots) do
            local slot = unwrap(candidate)
            if is_valid(slot) and salvage_slot_item_id(slot) == item_id then
                table.insert(cached_slots, slot)
            end
        end
    end)
    if not scan_ok then
        return nil, "magnet-cache-failed:" .. tostring(scan_error)
    end
    magnet_slot_cache[item_id] = cached_slots
    return cached_slots, nil
end

local function capture_magnet_slots(model)
    local item_id, grade = salvage_magnet_id(model)
    local matching_slots = {}
    local cached_slots = magnet_slot_cache[item_id]
    if cached_slots == nil then
        local cache_error
        cached_slots, cache_error = refresh_magnet_slot_cache(item_id)
        if cached_slots == nil then
            return nil, cache_error
        end
    end
    for _, slot in ipairs(cached_slots) do
        if is_valid(slot) then
            local stack = tonumber(slot.StackCount) or 0
            if stack > 0 then
                table.insert(matching_slots, {
                    container = unwrap(slot:GetOuter()),
                    slot = slot,
                    before_vanilla = stack,
                })
            end
        end
    end
    if #matching_slots == 0 then
        magnet_slot_cache[item_id] = nil
        return nil, "no-" .. item_id .. "-slots"
    end
    return {
        item_id = item_id,
        grade = grade,
        slots = matching_slots,
    }, nil
end

local function consume_from_vanilla_source(attempt)
    local snapshot = attempt.magnet_snapshot
    if snapshot == nil then
        return false, "missing-magnet-snapshot"
    end
    local source = nil
    for _, entry in ipairs(snapshot.slots) do
        if is_valid(entry.slot) then
            local current = tonumber(entry.slot.StackCount) or 0
            if current < entry.before_vanilla then
                if source ~= nil then
                    return false, "multiple-magnet-sources-changed"
                end
                source = entry
                source.after_vanilla = current
            end
        end
    end
    if source == nil then
        magnet_slot_cache[snapshot.item_id] = nil
        return false, "vanilla-magnet-source-not-observed"
    end
    if source.after_vanilla < CONFIG.extra_magnet_cost then
        return false, "insufficient-magnets-after-vanilla"
    end
    local mutation_ok, mutation_error = pcall(function()
        source.slot.StackCount =
            source.after_vanilla - CONFIG.extra_magnet_cost
        if tonumber(source.slot.StackCount) ~=
            source.after_vanilla - CONFIG.extra_magnet_cost then
            error("magnet-stack-write-verification-failed")
        end
    end)
    if not mutation_ok then
        return false, mutation_error
    end
    attempt.extra_magnet_slot = source.slot
    log("INFO", "extra_magnet_consumed", {
        item = snapshot.item_id,
        grade = snapshot.grade,
        count_before_vanilla = source.before_vanilla,
        count_after_vanilla = source.after_vanilla,
        count_after_extra_cost =
            source.after_vanilla - CONFIG.extra_magnet_cost,
        extra_cost = CONFIG.extra_magnet_cost,
        container = full_name(source.container),
    })
    return true, nil
end

local function dump_inventory_functions()
    local controller = FindFirstOf("PalPlayerController")
    local inventory = get_inventory(controller)
    if not is_valid(inventory) then
        log("WARN", "inventory_function_dump", {
            reason = "inventory-unavailable",
        })
        return
    end
    local count = 0
    local ok, error_value = pcall(function()
        local struct = inventory:GetClass()
        local depth = 0
        while is_valid(struct) and depth < 5 and count < 160 do
            struct:ForEachFunction(function(func)
                local name = tostring(func:GetFName():ToString())
                if string.find(name, "Item", 1, true) ~= nil or
                    string.find(name, "Add", 1, true) ~= nil then
                    count = count + 1
                    log("DEBUG", "inventory_function", {
                        depth = depth,
                        name = name,
                        full_name = tostring(func:GetFullName()),
                    })
                end
                return nil
            end)
            struct = struct:GetSuperStruct()
            depth = depth + 1
        end
    end)
    log(ok and "INFO" or "ERROR", "inventory_function_dump", {
        count = count,
        class = full_name(inventory:GetClass()),
        error = error_value or "",
    })
end

local function dump_spawn_surfaces()
    local candidates = {
        "PalGameMode",
        "PalGameState",
        "PalCharacterManager",
        "PalNPCManager",
        "PalSpawnerManager",
        "PalWildCharacterManager",
        "PalNetworkCharacterComponent",
        "PalWorldSecuritySystem",
        "PalNetworkWorldSecurityComponent",
    }
    for _, class_name in ipairs(candidates) do
        local object = FindFirstOf(class_name)
        local count = 0
        local ok, error_value = pcall(function()
            if not is_valid(object) then
                error("object-not-found")
            end
            local struct = object:GetClass()
            local depth = 0
            while is_valid(struct) and depth < 6 and count < 120 do
                struct:ForEachFunction(function(func)
                    local name = tostring(func:GetFName():ToString())
                    if string.find(name, "Spawn", 1, true) or
                        string.find(name, "Summon", 1, true) or
                        string.find(name, "Character", 1, true) or
                        string.find(name, "NPC", 1, true) or
                        string.find(name, "Wanted", 1, true) or
                        string.find(name, "Crime", 1, true) or
                        string.find(name, "Police", 1, true) then
                        count = count + 1
                        log("DEBUG", "spawn_function", {
                            candidate = class_name,
                            object = full_name(object),
                            name = name,
                            full_name = tostring(func:GetFullName()),
                        })
                    end
                    return nil
                end)
                struct = struct:GetSuperStruct()
                depth = depth + 1
            end
        end)
        log(ok and "INFO" or "WARN", "spawn_surface", {
            candidate = class_name,
            object = full_name(object),
            count = count,
            error = error_value or "",
        })
    end
end

local function trace_object_surface(label, object)
    object = unwrap(object)
    if not is_valid(object) then
        log("WARN", "object_surface", {
            label = label,
            reason = "invalid-object",
        })
        return
    end
    local class = object:GetClass()
    local class_name = full_name(class)
    if traced_object_classes[class_name] then
        return
    end
    traced_object_classes[class_name] = true
    local properties = 0
    local functions = 0
    local ok, error_value = pcall(function()
        local struct = class
        local depth = 0
        while is_valid(struct) and depth < 4 and
            properties + functions < 180 do
            struct:ForEachFunction(function(func)
                if properties + functions >= 180 then
                    return true
                end
                local name = tostring(func:GetFName():ToString())
                if string.find(name, "Add", 1, true) or
                    string.find(name, "Item", 1, true) or
                    string.find(name, "Container", 1, true) or
                    string.find(name, "Obtain", 1, true) or
                    string.find(name, "Slot", 1, true) or
                    string.find(name, "Spawn", 1, true) or
                    string.find(name, "Wanted", 1, true) or
                    string.find(name, "Police", 1, true) or
                    string.find(name, "Crime", 1, true) then
                    functions = functions + 1
                    log("DEBUG", "object_function", {
                        label = label,
                        class = class_name,
                        depth = depth,
                        name = name,
                        full_name = tostring(func:GetFullName()),
                    })
                end
                return nil
            end)
            struct:ForEachProperty(function(property)
                if properties + functions >= 180 then
                    return true
                end
                properties = properties + 1
                local name = tostring(property:GetFName():ToString())
                local value_ok, value = pcall(function()
                    return unwrap(object:GetPropertyValue(name))
                end)
                log("DEBUG", "object_property", {
                    label = label,
                    class = class_name,
                    depth = depth,
                    name = name,
                    value = value_ok and
                        (is_valid(value) and full_name(value) or tostring(value)) or
                        "<unreadable>",
                })
                return nil
            end)
            struct = struct:GetSuperStruct()
            depth = depth + 1
        end
    end)
    log(ok and "INFO" or "ERROR", "object_surface", {
        label = label,
        class = class_name,
        properties = properties,
        functions = functions,
        error = error_value or "",
    })
end

local function trace_reward_surfaces(attempt, model)
    trace_object_surface("inventory", get_inventory(attempt.controller))
    pcall(function()
        trace_object_surface(
            "inventory.multi_helper",
            get_inventory(attempt.controller).InventoryMultiHelper
        )
    end)
    pcall(function()
        trace_object_surface(
            "inventory.container_module",
            get_inventory(attempt.controller):GetItemContainerModule()
        )
    end)
    pcall(function()
        trace_object_surface(
            "model.container_module",
            model:GetItemContainerModule()
        )
    end)
    pcall(function()
        trace_object_surface(
            "model.container_access",
            model:GetItemContainerAccess()
        )
    end)
end

local function dump_model_properties(model)
    local count = 0
    local ok, error_value = pcall(function()
        local struct = model:GetClass()
        local depth = 0
        while is_valid(struct) and depth < 8 and count < 64 do
            struct:ForEachProperty(function(property)
                if count >= 64 then
                    return true
                end
                count = count + 1
                local property_name =
                    tostring(property:GetFName():ToString())
                local value_ok, value = pcall(function()
                    return unwrap(model:GetPropertyValue(property_name))
                end)
                local display = "<unreadable>"
                if value_ok then
                    if is_valid(value) then
                        display = full_name(value)
                    else
                        display = tostring(value)
                    end
                end
                log("DEBUG", "model_property", {
                    depth = depth,
                    name = property_name,
                    value = display,
                })
                return nil
            end)
            struct = struct:GetSuperStruct()
            depth = depth + 1
        end
    end)
    log(ok and "INFO" or "ERROR", "model_property_dump", {
        count = count,
        error = error_value or "",
    })
end

local function dump_model_functions(model)
    local count = 0
    local ok, error_value = pcall(function()
        local struct = model:GetClass()
        local depth = 0
        while is_valid(struct) and depth < 4 and count < 96 do
            struct:ForEachFunction(function(func)
                if count >= 96 then
                    return true
                end
                count = count + 1
                log("DEBUG", "model_function", {
                    depth = depth,
                    name = tostring(func:GetFName():ToString()),
                })
                return nil
            end)
            struct = struct:GetSuperStruct()
            depth = depth + 1
        end
    end)
    log(ok and "INFO" or "ERROR", "model_function_dump", {
        count = count,
        error = error_value or "",
    })
end

local function dump_function_signature(path)
    local count = 0
    local ok, error_value = pcall(function()
        local func = StaticFindObject(path)
        if not is_valid(func) then
            error("function-not-found")
        end
        func:ForEachProperty(function(property)
            count = count + 1
            log("DEBUG", "function_parameter", {
                function_path = path,
                index = count,
                property = tostring(property:GetFullName()),
            })
            pcall(function()
                local nested_struct = property:GetStruct()
                nested_struct:ForEachProperty(function(nested_property)
                    log("DEBUG", "function_struct_field", {
                        function_path = path,
                        parameter = tostring(
                            property:GetFName():ToString()
                        ),
                        property = tostring(nested_property:GetFullName()),
                    })
                    return nil
                end)
            end)
            return nil
        end)
    end)
    log(ok and "INFO" or "ERROR", "function_signature", {
        function_path = path,
        count = count,
        error = error_value or "",
    })
end

local function find_salvage_parameter_component(model)
    local actor = nil
    pcall(function()
        actor = unwrap(model:GetActor())
    end)
    if not is_valid(actor) then
        return nil
    end
    local actor_name = full_name(actor)
    local ok, components = pcall(function()
        return FindObjects(
            0,
            "PalMapObjectTreasureBoxSalvageParameterComponent",
            nil,
            nil,
            nil,
            false
        )
    end)
    if not ok or type(components) ~= "table" then
        return nil
    end
    for _, component in ipairs(components) do
        if is_valid(component) then
            local component_owner = get_owner(component)
            if is_valid(component_owner) and
                full_name(component_owner) == actor_name then
                return component
            end
        end
    end
    return nil
end

local function get_salvage_item_container(model)
    local container = nil
    pcall(function()
        local module = unwrap(model:GetItemContainerModule())
        if is_valid(module) then
            container = unwrap(module.TargetContainer)
        end
    end)
    return is_valid(container) and container or nil
end

local function trace_salvage_slots(model, phase)
    local container = get_salvage_item_container(model)
    if not is_valid(container) then
        log("WARN", "salvage_slot_snapshot", {
            phase = phase,
            reason = "container-unavailable",
        })
        return
    end
    local count = 0
    local ok, error_value = pcall(function()
        local slots = container.ItemSlotArray
        count = #slots
        for index = 1, math.min(count, 32) do
            local slot = unwrap(slots[index])
            local fields = {
                phase = phase,
                container = full_name(container),
                index = index,
                slot = full_name(slot),
            }
            if is_valid(slot) then
                local property_count = 0
                slot:GetClass():ForEachProperty(function(property)
                    if property_count >= 24 then
                        return true
                    end
                    property_count = property_count + 1
                    local name = tostring(property:GetFName():ToString())
                    local value_ok, value = pcall(function()
                        return unwrap(slot:GetPropertyValue(name))
                    end)
                    if value_ok then
                        fields[name] = is_valid(value) and
                            full_name(value) or tostring(value)
                    end
                    return nil
                end)
            end
            log("DEBUG", "salvage_slot", fields)
        end
    end)
    log(ok and "INFO" or "ERROR", "salvage_slot_snapshot", {
        phase = phase,
        container = full_name(container),
        count = count,
        error = error_value or "",
    })
end

salvage_slot_item_id = function(slot)
    local ok, value = pcall(function()
        return name_string(unwrap(slot.ItemId.StaticId))
    end)
    return ok and value or "<unknown-item>"
end

local function apply_container_reward(attempt, model)
    local container = get_salvage_item_container(model)
    if not is_valid(container) then
        return false, "container-unavailable"
    end
    local jellroy_multiplier, passive_status =
        get_jellroy_multiplier(attempt.controller)
    local comparisons = {}
    local originals = {}
    local changed = 0
    local ok, error_value = pcall(function()
        local slots = container.ItemSlotArray
        for index = 1, math.min(#slots, 32) do
            local slot = unwrap(slots[index])
            if is_valid(slot) then
                local vanilla_after_jellroy =
                    tonumber(slot.StackCount) or 0
                if vanilla_after_jellroy > 0 then
                    local estimated_base = round_quantity(
                        vanilla_after_jellroy / jellroy_multiplier
                    )
                    local deep_before_jellroy =
                        estimated_base * (1.0 + CONFIG.reward_bonus)
                    local expected = round_quantity(
                        deep_before_jellroy * jellroy_multiplier
                    )
                    table.insert(originals, {
                        slot = slot,
                        count = vanilla_after_jellroy,
                    })
                    slot.StackCount = expected
                    local actual = tonumber(slot.StackCount) or -1
                    if actual ~= expected then
                        error("stack-write-verification-failed")
                    end
                    local item = salvage_slot_item_id(slot)
                    local comparison = string.format(
                        "%s: base %d -> Deep %.2f -> Jellroy x%.2f -> final %d",
                        item,
                        estimated_base,
                        deep_before_jellroy,
                        jellroy_multiplier,
                        actual
                    )
                    table.insert(comparisons, comparison)
                    changed = changed + 1
                    log("INFO", "container_reward_item", {
                        model = attempt.model,
                        index = index,
                        item = item,
                        original_base = estimated_base,
                        vanilla_after_jellroy = vanilla_after_jellroy,
                        deep_before_jellroy = deep_before_jellroy,
                        jellroy_multiplier =
                            string.format("%.4f", jellroy_multiplier),
                        passive_status = passive_status,
                        final_after_modifiers = actual,
                        formula_match = true,
                    })
                end
            end
        end
    end)
    if not ok or changed == 0 then
        for _, original in ipairs(originals) do
            pcall(function()
                original.slot.StackCount = original.count
            end)
        end
        return false, error_value or "no-populated-reward-slots"
    end
    attempt.reward_originals = originals
    attempt.reward_comparisons = comparisons
    attempt.reward_applied = true
    return true, nil
end

local function restore_container_reward(attempt)
    for _, original in ipairs(attempt.reward_originals or {}) do
        pcall(function()
            if is_valid(original.slot) then
                original.slot.StackCount = original.count
            end
        end)
    end
    attempt.reward_applied = false
end

local function apply_server_difficulty(model)
    local component = find_salvage_parameter_component(model)
    if not is_valid(component) then
        return nil, "missing-salvage-parameter-component"
    end
    local state = {
        component = component,
        range_before = component.GaugeRangePercent,
        speed_before = component.CursorPercentSpeed,
    }
    local ok, error_value = pcall(function()
        component.GaugeRangePercent =
            CONFIG.difficult_gauge_range_percent
        component.CursorPercentSpeed =
            CONFIG.difficult_cursor_percent_speed
    end)
    if not ok then
        return nil, tostring(error_value)
    end
    state.range_after = component.GaugeRangePercent
    state.speed_after = component.CursorPercentSpeed
    return state, nil
end

local function restore_server_difficulty(attempt)
    local state = attempt and attempt.difficulty_state or nil
    if state == nil or not is_valid(state.component) then
        return
    end
    local ok, error_value = pcall(function()
        state.component.GaugeRangePercent = state.range_before
        state.component.CursorPercentSpeed = state.speed_before
    end)
    log(ok and "INFO" or "ERROR", "difficulty_restored", {
        model = attempt.model,
        range = state.range_before,
        speed = state.speed_before,
        error = error_value or "",
    })
end

local function cleanup_expired_attempts()
    local now = now_ms()
    for model_key, attempt in pairs(attempts_by_model) do
        if attempt.expires < now then
            log("WARN", "salvage_attempt_expired", {
                model = model_key,
                player_id = attempt.player_id or "unknown",
                reward_selected = attempt.reward_selected,
                reward_applied = attempt.reward_applied,
            })
            if attempt.reward_applied then
                restore_container_reward(attempt)
            end
            attempts_by_model[model_key] = nil
        end
    end
end

local function on_request_open(model, request_player_id)
    cleanup_expired_attempts()
    model = unwrap(model)
    if CONFIG.debug_enabled and not callback_seen.request_open then
        callback_seen.request_open = true
        log("INFO", "request_open_seen", {
            model = full_name(model),
            owner = full_name(get_owner(model)),
            fishing_salvage = is_fishing_salvage(model),
        })
        dump_model_properties(model)
        dump_model_functions(model)
    end
    if not is_fishing_salvage(model) then
        return
    end

    local player_id = tonumber(unwrap(request_player_id))
    local model_key = full_name(model)
    local salvage_location = nil
    pcall(function()
        local actor = unwrap(model:GetActor())
        salvage_location = unwrap(actor:K2_GetActorLocation())
    end)
    if salvage_location == nil then
        pcall(function()
            local controller = find_controller_by_player_id(player_id)
            local character = unwrap(
                controller:GetDefaultPlayerCharacter()
            )
            salvage_location = unwrap(character:K2_GetActorLocation())
        end)
    end
    local controller = player_id and
        find_controller_by_player_id(player_id) or nil
    local selected = roll(CONFIG.modifier_chance)
    local magnet_snapshot = nil
    local snapshot_error = nil
    if selected then
        magnet_snapshot, snapshot_error = capture_magnet_slots(model)
    end
    local modifier_active = selected and magnet_snapshot ~= nil
    attempts_by_model[model_key] = {
        model = model_key,
        player_id = player_id,
        controller = controller,
        salvage_location = salvage_location,
        started = now_ms(),
        expires = now_ms() + CONFIG.attempt_timeout_ms,
        modifier_selected = modifier_active,
        reward_selected = modifier_active,
        reward_applied = false,
        risk_failure_chance = CONFIG.risk_failure_chance,
        risk_collapsed = false,
        magnet_snapshot = magnet_snapshot,
        extra_magnet_consumed = false,
        result_processed = false,
    }
    if selected and magnet_snapshot == nil then
        attempts_by_model[model_key].failure_reason =
            "snapshot-fail-closed:" .. tostring(snapshot_error)
    end
    if modifier_active then
        local attempt = attempts_by_model[model_key]
        if CONFIG.debug_enabled then
            trace_reward_surfaces(attempt, model)
            trace_salvage_slots(model, "request_open_pre")
        end
        local reward_ok, reward_error =
            apply_container_reward(attempt, model)
        if not reward_ok then
            modifier_active = false
            attempt.modifier_selected = false
            attempt.reward_selected = false
            attempt.failure_reason =
                "reward-fail-closed:" .. tostring(reward_error)
        end
    end
end

local function on_request_open_post(model, request_player_id)
    model = unwrap(model)
    if not is_fishing_salvage(model) then
        return
    end
    local model_key = full_name(model)
    local attempt = attempts_by_model[model_key]
    if attempt == nil then
        return
    end
    local selected = attempt.modifier_selected
    local modifier_active = selected
    if selected then
        local risk_ok, risk_error =
            consume_from_vanilla_source(attempt)
        attempt.extra_magnet_consumed = risk_ok
        if not risk_ok then
            modifier_active = false
            attempt.failure_reason =
                "risk-fail-closed:" .. tostring(risk_error)
            if attempt.reward_applied then
                restore_container_reward(attempt)
            end
        end
    end
    attempt.modifier_selected = modifier_active
    attempt.reward_selected = modifier_active
    log(
        selected and not modifier_active and "WARN" or "INFO",
        "modifier_roll",
        {
        model = model_key,
        player_id = attempt.player_id or
            tonumber(unwrap(request_player_id)) or "unknown",
        selected = modifier_active,
        rolled = selected,
        chance = CONFIG.modifier_chance,
        risk_failure_chance = CONFIG.risk_failure_chance,
        reason = attempt.failure_reason or "",
    })
    if modifier_active then
        notify_deep_salvage(attempt)
    end
end

get_jellroy_multiplier = function(controller)
    controller = unwrap(controller)
    if not is_valid(controller) then
        return 1.0, "invalid-controller"
    end
    local character = nil
    pcall(function()
        character = unwrap(controller:GetDefaultPlayerCharacter())
    end)
    if not is_valid(character) then
        return 1.0, "missing-player-character"
    end
    local passive = nil
    pcall(function()
        passive = unwrap(character.PassiveSkillComponent)
    end)
    if not is_valid(passive) then
        return 1.0, "missing-passive-component"
    end
    local ok, multiplier = pcall(function()
        return passive:GetParameterWithPassiveSkillEffect(
            1.0,
            ENUM.passive_fishing_salvage_drop,
            true
        )
    end)
    multiplier = tonumber(unwrap(multiplier))
    if not ok or multiplier == nil or multiplier < 1.0 then
        return 1.0, "passive-query-failed"
    end
    return multiplier, "passive-query-ok"
end

local function item_static_id(item)
    local ok, value = pcall(function()
        local static_id = unwrap(item.ItemId.StaticId)
        local text_ok, text = pcall(function()
            return static_id:ToString()
        end)
        return text_ok and tostring(text) or tostring(static_id)
    end)
    return ok and value or "<unknown-item>"
end

round_quantity = function(value)
    return math.floor(value + 0.5)
end

local function apply_random_reward(model, return_value)
    if not callback_seen.create_items then
        callback_seen.create_items = true
        log("INFO", "create_items_seen", {
            model = full_name(model),
            owner = full_name(get_owner(model)),
            fishing_salvage = is_fishing_salvage(model),
        })
    end
    local model_key = full_name(model)
    local attempt = attempts_by_model[model_key]
    if attempt == nil or not attempt.reward_selected or
        attempt.reward_applied or attempt.expires < now_ms() then
        return
    end

    local items = unwrap(return_value)
    if items == nil then
        log("ERROR", "reward_array_missing", {model = model_key})
        return
    end

    local jellroy_multiplier, passive_status =
        get_jellroy_multiplier(attempt.controller)
    local changed = 0
    local formula_matches = true
    local comparisons = {}
    local ok, error_value = pcall(function()
        for index = 1, #items do
            local item = items[index]
            local vanilla_after_jellroy = tonumber(item.Num) or 0
            local estimated_base =
                round_quantity(vanilla_after_jellroy / jellroy_multiplier)
            local deep_before_jellroy =
                estimated_base * (1.0 + CONFIG.reward_bonus)
            local expected = round_quantity(
                deep_before_jellroy * jellroy_multiplier
            )
            item.Num = expected
            local actual = tonumber(item.Num) or -1
            local formula_match = actual == expected
            formula_matches = formula_matches and formula_match
            changed = changed + 1
            table.insert(comparisons, string.format(
                "%s: base %d -> Deep %.2f -> Jellroy x%.2f -> final %d",
                item_static_id(item),
                estimated_base,
                deep_before_jellroy,
                jellroy_multiplier,
                actual
            ))
            log(
                formula_match and "INFO" or "ERROR",
                "reward_formula_item",
                {
                    model = model_key,
                    player_id = attempt.player_id or "unknown",
                    index = index,
                    item = item_static_id(item),
                    vanilla_after_jellroy = vanilla_after_jellroy,
                    estimated_base = estimated_base,
                    deep_before_jellroy = deep_before_jellroy,
                    jellroy_multiplier =
                        string.format("%.4f", jellroy_multiplier),
                    random_bonus =
                        string.format("%.4f", CONFIG.reward_bonus),
                    expected_final = expected,
                    actual_final = actual,
                    formula_match = formula_match,
                    passive_status = passive_status,
                }
            )
        end
    end)
    attempt.reward_applied = ok and changed > 0 and formula_matches
    log(
        attempt.reward_applied and "INFO" or "ERROR",
        "reward_formula_summary",
        {
            model = model_key,
            player_id = attempt.player_id or "unknown",
            items_changed = changed,
            formula_match = formula_matches,
            reward_applied = attempt.reward_applied,
            reward_comparison = table.concat(comparisons, "; "),
            error = error_value or "",
        }
    )
    if ok then
        return items
    end
end

local function begin_salvage_result(model, result)
    local model_key = full_name(model)
    local attempt = attempts_by_model[model_key]
    if attempt == nil or not attempt.reward_selected then
        active_reward_attempt = nil
        return
    end
    local reported_success = unwrap(result)
    if reported_success and roll(attempt.risk_failure_chance) then
        local changed = set_param(result, false)
        attempt.risk_collapsed = changed
        log(changed and "WARN" or "ERROR", "salvage_risk_roll", {
            model = model_key,
            player_id = attempt.player_id or "unknown",
            reported_success = reported_success,
            collapsed = changed,
            chance = attempt.risk_failure_chance,
        })
        if changed then
            notify_debug("WARN", "salvage_collapsed", {
                risk = "server rejected recovery; no reward awarded",
            })
            active_reward_attempt = nil
            return
        end
    end
    if not reported_success then
        active_reward_attempt = nil
        return
    end
    active_reward_attempt = attempt
    if CONFIG.debug_enabled then
        trace_salvage_slots(unwrap(model), "result_pre")
    end
    log("DEBUG", "reward_window_open", {
        model = model_key,
        player_id = attempt.player_id or "unknown",
        inventory = full_name(get_inventory(attempt.controller)),
    })
end

local function on_inventory_add(inventory, static_item_id, count)
    local attempt = active_reward_attempt
    if attempt == nil or not attempt.reward_selected then
        return
    end
    local expected_inventory = get_inventory(attempt.controller)
    inventory = unwrap(inventory)
    if not is_valid(inventory) or not is_valid(expected_inventory) or
        full_name(inventory) ~= full_name(expected_inventory) then
        return
    end

    local vanilla_after_jellroy = tonumber(unwrap(count))
    if vanilla_after_jellroy == nil or vanilla_after_jellroy <= 0 then
        return
    end
    local jellroy_multiplier, passive_status =
        get_jellroy_multiplier(attempt.controller)
    local estimated_base =
        round_quantity(vanilla_after_jellroy / jellroy_multiplier)
    local deep_before_jellroy =
        estimated_base * (1.0 + CONFIG.reward_bonus)
    local expected = round_quantity(
        deep_before_jellroy * jellroy_multiplier
    )
    local changed = set_param(count, expected)
    local comparison = string.format(
        "%s: base %d -> Deep %.2f -> Jellroy x%.2f -> final %d",
        name_string(static_item_id),
        estimated_base,
        deep_before_jellroy,
        jellroy_multiplier,
        expected
    )
    if changed then
        attempt.reward_applied = true
        table.insert(attempt.reward_comparisons, comparison)
    end
    log(changed and "INFO" or "ERROR", "inventory_reward_item", {
        model = attempt.model,
        player_id = attempt.player_id or "unknown",
        item = name_string(static_item_id),
        original_base = estimated_base,
        vanilla_after_jellroy = vanilla_after_jellroy,
        deep_before_jellroy = deep_before_jellroy,
        jellroy_multiplier = string.format("%.4f", jellroy_multiplier),
        passive_status = passive_status,
        final_after_modifiers = expected,
        changed = changed,
    })
end

local function on_obtain_info(model, ...)
    local values = {...}
    local fields = {
        model = full_name(model),
        argument_count = #values,
    }
    for index = 1, math.min(#values, 8) do
        local value = unwrap(values[index])
        fields["arg" .. index] = is_valid(value) and
            full_name(value) or tostring(value)
    end
    log("INFO", "obtain_info_seen", fields)
end

local function on_salvage_result(model, result)
    cleanup_expired_attempts()
    if not callback_seen.salvage_result then
        callback_seen.salvage_result = true
        log("INFO", "salvage_result_seen", {
            model = full_name(model),
            owner = full_name(get_owner(model)),
            fishing_salvage = is_fishing_salvage(model),
        })
    end
    local model_key = full_name(model)
    local attempt = attempts_by_model[model_key]
    if attempt == nil or attempt.result_processed then
        return
    end
    local success = unwrap(result) == true
    attempt.result_processed = true
    active_reward_attempt = nil
    if not success and attempt.reward_applied then
        restore_container_reward(attempt)
    end
    local comparisons = attempt.reward_comparisons or {}
    log(
        success and attempt.reward_selected and
            not attempt.reward_applied and "ERROR" or "INFO",
        "reward_formula_summary",
        {
            model = model_key,
            player_id = attempt.player_id or "unknown",
            formula_match = attempt.reward_applied or
                not attempt.reward_selected or not success,
            reward_applied = attempt.reward_applied,
            reward_comparison = table.concat(comparisons, "; "),
            reason = success and attempt.reward_selected and
                not attempt.reward_applied and
                "no-matching-inventory-add" or "",
        }
    )
    log("INFO", "salvage_attempt_result", {
        model = model_key,
        player_id = attempt.player_id or "unknown",
        success = success,
        reward_selected = attempt.reward_selected,
        reward_applied = attempt.reward_applied,
        risk_collapsed = attempt.risk_collapsed,
        extra_magnet_consumed = attempt.extra_magnet_consumed or false,
        duration_ms = now_ms() - attempt.started,
    })
    attempts_by_model[model_key] = nil
end

local function register_hook(name, path, callback, post)
    local ok, first, second
    if post then
        ok, first, second = pcall(RegisterHook, path, function()
        end, callback)
    else
        ok, first, second = pcall(RegisterHook, path, callback)
    end
    log(ok and "INFO" or "ERROR", "hook_registration", {
        hook = name,
        path = path,
        ok = ok,
        pre_id = first or "",
        post_id = second or "",
        phase = post and "post" or "pre",
    })
    return ok
end

register_hook("request_open", PATHS.request_open, on_request_open, false)
register_hook(
    "request_open_post",
    PATHS.request_open,
    on_request_open_post,
    true
)
register_hook(
    "salvage_result_begin",
    PATHS.salvage_result,
    begin_salvage_result,
    false
)
register_hook("salvage_result", PATHS.salvage_result, on_salvage_result, true)
register_hook("create_items", PATHS.create_items, apply_random_reward, true)
register_hook("add_item", PATHS.add_item, on_inventory_add, false)

if CONFIG.debug_enabled then
    register_hook("obtain_info", PATHS.obtain_info, on_obtain_info, false)
    dump_function_signature(
        "/Script/Pal.PalMapObjectTreasureBoxModel:OpenPickingGame_ClientInternal"
    )
    dump_function_signature(
        "/Script/Pal.PalMapObjectTreasureBoxModel:ReceiveOpenSuccess_ClientInternal"
    )
    dump_function_signature(
        "/Script/Pal.PalPlayerInventoryData:AddItem_ServerInternal"
    )
    dump_function_signature(PATHS.obtain_info)
    dump_inventory_functions()
    trace_object_surface(
        "live_item_container",
        FindFirstOf("PalItemContainer")
    )
end
capture_magnet_slots({
    TreasureGradeType = 1,
})

log("INFO", "mod_loaded", {
    version = MOD_VERSION,
    modifier_chance = CONFIG.modifier_chance,
    risk_failure_chance = CONFIG.risk_failure_chance,
    extra_magnet_cost = CONFIG.extra_magnet_cost,
    reward_bonus = CONFIG.reward_bonus,
    deployment = "server-only",
    debug_enabled = CONFIG.debug_enabled,
    remote_notification_via_chat = CONFIG.remote_notification_via_chat,
})
