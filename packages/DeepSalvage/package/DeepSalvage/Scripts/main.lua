local MOD_NAME = "DeepSalvage"
local MOD_VERSION = "0.1.0-dev.9"

local CONFIG = {
    magnet_item_id = "Salvage_TreasureBoxKey01",
    deep_gauge_range_percent = 5.0,
    deep_cursor_percent_speed = 90.0,
    deep_reward_bonus = 1.0,
    selection_timeout_ms = 10000,
    attempt_timeout_ms = 120000,
    -- Keep diagnostics in source. Set this to false for production releases.
    debug_enabled = true,
    debug_notifications = true,
    debug_console = true,
    notification_cooldown_ms = 2000,
    performance_report_interval_ms = 10000,
}

local MESSAGE_PREFIX = "__DEEP_SALVAGE__"
local START_PREFIX = MESSAGE_PREFIX .. "START|"

local PATHS = {
    trigger_interact = "/Script/Pal.PalInteractComponent:StartTriggerInteract",
    chat_receive = "/Script/Pal.PalPlayerController:EnterChat_Receive",
    request_open =
        "/Script/Pal.PalMapObjectTreasureBoxModel:RequestOpen_ServerInternal",
    salvage_result =
        "/Script/Pal.PalMapObjectTreasureBoxModel:OnReceiveSalvageResult",
    create_items =
        "/Script/Pal.PalMapObjectTreasureBoxModel:CreateItemInfo",
    cancel_salvage =
        "/Script/Pal.PalNetworkPlayerComponent:" ..
        "RequestCancelSalvageAction_ToServer",
}

local ENUM = {
    interact2 = 2,
    indicator_deep_salvage = 110, -- CommonInteract04
    action_fishing_salvage = 98,
    passive_fishing_salvage_drop = 119,
}

local hook_status = {}
local local_selection = nil
local server_selections_by_player = {}
local server_attempts_by_model = {}
local local_deep_model_budget = 0
local salvage_object_cache = setmetatable({}, {__mode = "k"})
local cached_log_manager = nil
local last_notification_by_event = {}
local performance = {
    selection_checks = 0,
    salvage_cache_hits = 0,
    salvage_cache_misses = 0,
    last_report_ms = os.time() * 1000,
}

local function timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function notification_priority(level)
    if level == "ERROR" then
        return 3 -- EPalLogPriority::VeryImportant
    end
    if level == "WARN" then
        return 2 -- EPalLogPriority::Important
    end
    return 1 -- EPalLogPriority::Normal
end

local function notify_debug(level, event, fields)
    if not CONFIG.debug_enabled or not CONFIG.debug_notifications then
        return
    end

    local notification_key = tostring(level) .. ":" .. tostring(event)
    local current_ms = os.time() * 1000
    local last_ms = last_notification_by_event[notification_key]
    if last_ms ~= nil and
        current_ms - last_ms < CONFIG.notification_cooldown_ms then
        return
    end

    local summary = {"[Deep Salvage]", tostring(event)}
    if fields ~= nil then
        for _, key in ipairs({
            "reason",
            "formula_match",
            "expected_final",
            "actual_final",
            "magnet_before",
            "magnet_after",
        }) do
            if fields[key] ~= nil then
                table.insert(summary, key .. "=" .. tostring(fields[key]))
            end
        end
    end

    local message = table.concat(summary, " | ")
    local ok = pcall(function()
        local manager_valid = false
        if cached_log_manager ~= nil then
            local valid_ok, valid = pcall(function()
                return cached_log_manager:IsValid()
            end)
            manager_valid = valid_ok and valid
        end
        if not manager_valid then
            cached_log_manager = FindFirstOf("PalLogManager")
        end
        if cached_log_manager == nil then
            return
        end
        cached_log_manager:AddLog(
            notification_priority(level),
            FText(message),
            {}
        )
        last_notification_by_event[notification_key] = current_ms
    end)

    if not ok and CONFIG.debug_console then
        print(string.format(
            "[%s] notification_failed | event=%s\n",
            MOD_NAME,
            tostring(event)
        ))
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
                local value = tostring(fields[key])
                value = string.gsub(value, "[\r\n|]", " ")
                table.insert(parts, tostring(key) .. "=" .. value)
            end
        end
        print(table.concat(parts, " | ") .. "\n")
    end
    notify_debug(level, event, fields)
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

local function now_ms()
    return os.time() * 1000
end

local function enum_number(value)
    value = unwrap(value)
    if type(value) == "number" then
        return value
    end
    local text = tostring(value)
    local ok, converted = pcall(function()
        return value:ToString()
    end)
    if ok and converted ~= nil then
        text = tostring(converted)
    end
    local known = {
        Interact2 = ENUM.interact2,
        CommonInteract04 = ENUM.indicator_deep_salvage,
        FishingSalvage = ENUM.action_fishing_salvage,
    }
    if known[text] ~= nil then
        return known[text]
    end
    local numeric = tonumber(value)
    if numeric ~= nil then
        return numeric
    end
    return nil
end

local function name_string(value)
    value = unwrap(value)
    if value == nil then
        return ""
    end
    if type(value) == "string" then
        return value
    end
    local ok, text = pcall(function()
        return value:ToString()
    end)
    return ok and tostring(text) or tostring(value)
end

local function split_pipe(value)
    local values = {}
    local start_index = 1
    while true do
        local separator_index = string.find(value, "|", start_index, true)
        if separator_index == nil then
            table.insert(values, string.sub(value, start_index))
            break
        end

        table.insert(values, string.sub(value, start_index, separator_index - 1))
        if #values > 16 then
            break
        end
        start_index = separator_index + 1
    end
    return values
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

local function is_salvage_object(object)
    local target = unwrap(object)
    if not is_valid(target) then
        return false
    end
    performance.selection_checks = performance.selection_checks + 1
    local cached = salvage_object_cache[target]
    if cached ~= nil then
        performance.salvage_cache_hits =
            performance.salvage_cache_hits + 1
        return cached
    end

    performance.salvage_cache_misses =
        performance.salvage_cache_misses + 1
    local owner = get_owner(target)
    local target_name = full_name(target)
    local owner_name = full_name(owner)
    local is_salvage =
        string.find(target_name, "FishingJunkSpot", 1, true) ~= nil or
        string.find(owner_name, "FishingJunkSpot", 1, true) ~= nil
    salvage_object_cache[target] = is_salvage
    return is_salvage
end

local function get_player_state(controller)
    controller = unwrap(controller)
    if not is_valid(controller) then
        return nil
    end
    local ok, state = pcall(function()
        return controller:GetPalPlayerState()
    end)
    return ok and unwrap(state) or nil
end

local function get_player_id(controller)
    local state = get_player_state(controller)
    if not is_valid(state) then
        return nil
    end
    local ok, id = pcall(function()
        return state:GetPlayerId()
    end)
    if ok then
        return tonumber(unwrap(id))
    end
    return nil
end

local function get_inventory(controller)
    local state = get_player_state(controller)
    if not is_valid(state) then
        return nil
    end
    local ok, inventory = pcall(function()
        return state:GetInventoryData()
    end)
    return ok and unwrap(inventory) or nil
end

local function get_magnet_count(controller)
    local inventory = get_inventory(controller)
    if not is_valid(inventory) then
        return nil
    end
    local ok, count = pcall(function()
        return inventory:CountItemNum(FName(CONFIG.magnet_item_id))
    end)
    return ok and tonumber(unwrap(count)) or nil
end

local function find_controller_by_player_id(player_id)
    local ok, controllers = pcall(function()
        return FindObjects(0, "PalPlayerController", nil, nil, nil, false)
    end)
    if not ok or type(controllers) ~= "table" then
        return nil
    end
    for _, controller in ipairs(controllers) do
        if is_valid(controller) and get_player_id(controller) == player_id then
            return controller
        end
    end
    return nil
end

local function send_control_message(controller, payload)
    controller = unwrap(controller)
    if not is_valid(controller) then
        log("ERROR", "control_send_failed", {reason = "invalid-controller"})
        return false
    end
    local ok, error_value = pcall(function()
        controller:EnterChat_Receive(payload, 0)
    end)
    log(ok and "DEBUG" or "ERROR", "control_send", {
        payload = payload,
        controller = full_name(controller),
        error = error_value or "",
    })
    return ok
end

local function suppress_control_parameter(parameter)
    local suppressed = set_param(parameter, "")
    if not suppressed then
        suppressed = set_param(parameter, FName("None"))
    end
    return suppressed
end

local function on_chat_receive(controller, message, category)
    local text = name_string(message)
    if string.sub(text, 1, #MESSAGE_PREFIX) ~= MESSAGE_PREFIX then
        return
    end
    local suppressed = suppress_control_parameter(message)
    set_param(category, 255)
    if string.sub(text, 1, #START_PREFIX) == START_PREFIX then
        local fields = split_pipe(string.sub(text, #START_PREFIX + 1))
        local target_name = fields[1] or "<unknown>"
        local player_id = get_player_id(controller)
        local magnet_before = get_magnet_count(controller)
        if player_id ~= nil and magnet_before ~= nil and magnet_before >= 1 then
            server_selections_by_player[player_id] = {
                expires = now_ms() + CONFIG.selection_timeout_ms,
                target_name = target_name,
                controller = controller,
                magnet_before = magnet_before,
            }
            log("INFO", "deep_selection_accepted", {
                player_id = player_id,
                target = target_name,
                magnet_count = magnet_before,
                expires = server_selections_by_player[player_id].expires,
                suppressed = suppressed,
            })
        else
            log("WARN", "deep_selection_rejected", {
                player_id = player_id or "unknown",
                target = target_name,
                magnet_count = magnet_before or "unavailable",
                suppressed = suppressed,
            })
        end
    end
end

local function on_start_trigger_interact(interact_component, action_type)
    local action = enum_number(action_type)
    if action ~= ENUM.interact2 then
        return
    end
    local component = unwrap(interact_component)
    local target = nil
    pcall(function()
        target = unwrap(component.TargetInteractiveObject)
    end)
    if not is_salvage_object(target) then
        return
    end
    local controller = FindFirstOf("PalPlayerController")
    local magnet_count = get_magnet_count(controller)
    if magnet_count == nil or magnet_count < 1 then
        log("WARN", "deep_input_blocked", {
            reason = "missing-magnet",
            magnet_count = magnet_count or "unavailable",
            target = full_name(target),
        })
        return
    end
    local_selection = {
        target = full_name(target),
        expires = now_ms() + CONFIG.selection_timeout_ms,
        magnet_before = magnet_count,
    }
    local_deep_model_budget = local_deep_model_budget + 1
    send_control_message(controller, START_PREFIX .. local_selection.target)
    log("INFO", "deep_input_selected", {
        target = local_selection.target,
        magnet_count = magnet_count,
        model_budget = local_deep_model_budget,
    })
end

local function configure_salvage_model(model)
    model = unwrap(model)
    if not is_valid(model) or local_deep_model_budget <= 0 or
        local_selection == nil then
        return
    end
    if local_selection.expires < now_ms() then
        log("WARN", "deep_model_not_configured", {reason = "selection-expired"})
        local_selection = nil
        local_deep_model_budget = 0
        return
    end
    local before_range = model.GaugeRange
    local before_speed = model.CursorSpeed
    local ok, error_value = pcall(function()
        model.GaugeRange = CONFIG.deep_gauge_range_percent
        model.CursorSpeed = CONFIG.deep_cursor_percent_speed
    end)
    if ok then
        local_deep_model_budget = local_deep_model_budget - 1
    end
    log(ok and "INFO" or "ERROR", "deep_model_configured", {
        model = full_name(model),
        range_before = before_range,
        range_after = ok and model.GaugeRange or "unchanged",
        speed_before = before_speed,
        speed_after = ok and model.CursorSpeed or "unchanged",
        error = error_value or "",
    })
end

local function on_request_open(model, request_player_id)
    local player_id = tonumber(unwrap(request_player_id))
    local state = player_id and server_selections_by_player[player_id] or nil
    if state == nil or state.expires < now_ms() then
        return
    end
    local model_key = full_name(model)
    server_attempts_by_model[model_key] = {
        player_id = player_id,
        controller = state.controller or find_controller_by_player_id(player_id),
        started = now_ms(),
        expires = now_ms() + CONFIG.attempt_timeout_ms,
        reward_applied = false,
        result_processed = false,
        magnet_before = state.magnet_before,
    }
    state.expires = 0
    log("INFO", "deep_attempt_bound", {
        model = model_key,
        player_id = player_id,
        controller = full_name(server_attempts_by_model[model_key].controller),
        magnet_before = server_attempts_by_model[model_key].magnet_before,
    })
end

local function get_jellroy_multiplier(controller)
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
        return name_string(item.ItemId.StaticId)
    end)
    return ok and value or "<unknown-item>"
end

local function round_quantity(value)
    return math.floor(value + 0.5)
end

local function apply_deep_reward(model, return_value)
    local model_key = full_name(model)
    local attempt = server_attempts_by_model[model_key]
    if attempt == nil or attempt.reward_applied or
        attempt.expires < now_ms() then
        return
    end
    local items = unwrap(return_value)
    if items == nil then
        log("ERROR", "reward_array_missing", {model = model_key})
        return
    end
    local jellroy_multiplier, passive_status =
        get_jellroy_multiplier(attempt.controller)
    local jellroy_bonus = math.max(0.0, jellroy_multiplier - 1.0)
    local changed = 0
    local formula_matches = true
    local ok, error_value = pcall(function()
        for index = 1, #items do
            local item = items[index]
            local vanilla_after_jellroy = tonumber(item.Num) or 0
            local estimated_base =
                round_quantity(vanilla_after_jellroy / jellroy_multiplier)
            local expected = round_quantity(
                estimated_base *
                (1.0 + jellroy_bonus + CONFIG.deep_reward_bonus)
            )
            local final = expected
            item.Num = final
            local actual = tonumber(item.Num) or -1
            local match = actual == expected
            formula_matches = formula_matches and match
            changed = changed + 1
            log(match and "INFO" or "ERROR", "reward_formula_item", {
                model = model_key,
                player_id = attempt.player_id,
                index = index,
                item = item_static_id(item),
                vanilla_after_jellroy = vanilla_after_jellroy,
                estimated_base = estimated_base,
                jellroy_multiplier =
                    string.format("%.4f", jellroy_multiplier),
                jellroy_bonus = string.format("%.4f", jellroy_bonus),
                deep_bonus =
                    string.format("%.4f", CONFIG.deep_reward_bonus),
                expected_final = expected,
                actual_final = actual,
                formula_match = match,
                passive_status = passive_status,
            })
        end
    end)
    attempt.reward_applied = ok and changed > 0 and formula_matches
    log(attempt.reward_applied and "INFO" or "ERROR", "reward_formula_summary", {
        model = model_key,
        player_id = attempt.player_id,
        items_changed = changed,
        formula_match = formula_matches,
        reward_applied = attempt.reward_applied,
        error = error_value or "",
    })
    if ok then
        return items
    end
end

local function consume_failure_magnet(attempt, reason)
    local controller = attempt.controller
    local inventory = get_inventory(controller)
    if not is_valid(inventory) then
        log("ERROR", "magnet_consume_failed", {
            player_id = attempt.player_id,
            reason = "missing-inventory",
            outcome = reason,
        })
        return false
    end
    local before = get_magnet_count(controller)
    if before == nil or before < 1 then
        log("ERROR", "magnet_consume_failed", {
            player_id = attempt.player_id,
            reason = "insufficient-before-consume",
            count_before = before or "unavailable",
            outcome = reason,
        })
        return false
    end
    local ok, operation = pcall(function()
        return inventory:AddItem_ServerInternal(
            FName(CONFIG.magnet_item_id),
            -1,
            false,
            0,
            false
        )
    end)
    local after = get_magnet_count(controller)
    local observed_delta =
        before ~= nil and after ~= nil and (after - before) or nil
    local verified = ok and observed_delta == -1
    log(verified and "INFO" or "ERROR", "magnet_consume_audit", {
        player_id = attempt.player_id,
        item = CONFIG.magnet_item_id,
        outcome = reason,
        count_before = before,
        count_after = after or "unavailable",
        expected_delta = -1,
        observed_delta = observed_delta or "unavailable",
        verified = verified,
        operation = operation or "",
    })
    return verified
end

local function on_salvage_result(model, result)
    local model_key = full_name(model)
    local attempt = server_attempts_by_model[model_key]
    if attempt == nil or attempt.result_processed then
        return
    end
    local success = unwrap(result) == true
    attempt.result_processed = true
    local magnet_verified = true
    if not success then
        magnet_verified = consume_failure_magnet(attempt, "failure")
    end
    log("INFO", "deep_attempt_result", {
        model = model_key,
        player_id = attempt.player_id,
        success = success,
        reward_applied = attempt.reward_applied,
        failure_magnet_verified = magnet_verified,
        duration_ms = now_ms() - attempt.started,
    })
    server_attempts_by_model[model_key] = nil
    local_selection = nil
end

local function on_cancel_salvage(network_component)
    local controller = get_owner(network_component)
    local player_id = get_player_id(controller)
    log("WARN", "salvage_cancel_requested", {
        controller = full_name(controller),
        player_id = player_id or "unknown",
        note = "awaiting authoritative false result before charging",
    })
end

local function register_hook(name, path, callback)
    local ok, first, second = pcall(RegisterHook, path, callback)
    hook_status[name] = ok
    log(ok and "INFO" or "ERROR", "hook_registration", {
        hook = name,
        path = path,
        ok = ok,
        pre_id = first or "",
        post_id = second or "",
    })
    return ok
end

local function register_hooks()
    register_hook(
        "trigger_interact",
        PATHS.trigger_interact,
        on_start_trigger_interact
    )
    register_hook("chat_receive", PATHS.chat_receive, on_chat_receive)
    register_hook("request_open", PATHS.request_open, on_request_open)
    register_hook("salvage_result", PATHS.salvage_result, on_salvage_result)
    register_hook("create_items", PATHS.create_items, apply_deep_reward)
    register_hook("cancel_salvage", PATHS.cancel_salvage, on_cancel_salvage)

    local ok, error_value = pcall(
        NotifyOnNewObject,
        "/Script/Pal.PalUIMapObjectTreasureBoxSalvageGameModel",
        configure_salvage_model
    )
    hook_status.salvage_model_notify = ok
    log(ok and "INFO" or "ERROR", "object_notification_registration", {
        class =
            "/Script/Pal.PalUIMapObjectTreasureBoxSalvageGameModel",
        ok = ok,
        error = error_value or "",
    })
end

local function cleanup_expired_state()
    local now = now_ms()
    for player_id, state in pairs(server_selections_by_player) do
        if state.expires ~= 0 and state.expires < now then
            log("WARN", "deep_selection_expired", {player_id = player_id})
            state.expires = 0
        end
    end
    for model_key, attempt in pairs(server_attempts_by_model) do
        if attempt.expires < now then
            log("ERROR", "deep_attempt_expired", {
                model = model_key,
                player_id = attempt.player_id,
                reward_applied = attempt.reward_applied,
                result_processed = attempt.result_processed,
            })
            server_attempts_by_model[model_key] = nil
        end
    end
    if local_selection ~= nil and local_selection.expires < now then
        log("WARN", "local_selection_expired", {
            target = local_selection.target,
        })
        local_selection = nil
        local_deep_model_budget = 0
    end

    if performance.selection_checks > 0 and
        now - performance.last_report_ms >=
            CONFIG.performance_report_interval_ms then
        local hit_rate = performance.selection_checks > 0 and
            performance.salvage_cache_hits /
                performance.selection_checks or 0
        log("DEBUG", "performance_counters", {
            interval_ms = now - performance.last_report_ms,
            selection_checks = performance.selection_checks,
            salvage_cache_hits = performance.salvage_cache_hits,
            salvage_cache_misses = performance.salvage_cache_misses,
            salvage_cache_hit_rate = string.format("%.4f", hit_rate),
        })
        performance.selection_checks = 0
        performance.salvage_cache_hits = 0
        performance.salvage_cache_misses = 0
        performance.last_report_ms = now
    end
end

local function has_active_runtime_work()
    if local_selection ~= nil or
        next(server_attempts_by_model) ~= nil or
        performance.selection_checks > 0 then
        return true
    end
    for _, state in pairs(server_selections_by_player) do
        if state.expires ~= 0 then
            return true
        end
    end
    return false
end

register_hooks()

LoopAsync(1000, function()
    ExecuteInGameThread(function()
        if has_active_runtime_work() then
            cleanup_expired_state()
        end
    end)
    return false
end)

log("INFO", "mod_loaded", {
    version = MOD_VERSION,
    magnet_item = CONFIG.magnet_item_id,
    deep_range = CONFIG.deep_gauge_range_percent,
    deep_speed = CONFIG.deep_cursor_percent_speed,
    deep_bonus = CONFIG.deep_reward_bonus,
    debug_enabled = CONFIG.debug_enabled,
    debug_notifications = CONFIG.debug_notifications,
    debug_console = CONFIG.debug_console,
})
