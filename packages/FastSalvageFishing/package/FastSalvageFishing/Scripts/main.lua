local MOD_NAME = "InstantFishingSalvage"
local MOD_VERSION = "0.1.0-dev.18"

local CONFIG = {
    -- Keep diagnostics in source. Disable all three for production.
    debug_enabled = true,
    debug_notifications = true,
    debug_console = true,
}

local PATHS = {
    salvage_range =
        "/Script/Pal.PalUIMapObjectTreasureBoxSalvageGameModel:" ..
        "CalcGaugeRandomRange",
    interact_terminate =
        "/Script/Pal.PalInteractComponent:TerminateInteract",
    salvage_ui_setup =
        "/Game/Pal/Blueprint/UI/Salvage/WBP_SalvageGame." ..
        "WBP_SalvageGame_C:OnSetup",
    salvage_widget =
        "/Game/Pal/Blueprint/UI/Salvage/WBP_SalvageGame." ..
        "WBP_SalvageGame_C",
}

local ENUM = {
    fishing_salvage_action = 98,
}

local completed_models = setmetatable({}, {__mode = "k"})
local counters = {
    range_events = 0,
    duplicate_models = 0,
    success_signals = 0,
    ui_setup_events = 0,
    ui_hidden = 0,
    ui_hide_failures = 0,
    interact_terminate_events = 0,
    orphaned_actions_cancelled = 0,
    orphaned_action_cancel_failures = 0,
    failures = 0,
}

local cached_log_manager = nil
local ui_hook_registered = false
local ensure_ui_setup_hook = nil

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid
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

local function console_log(level, event, detail)
    if not CONFIG.debug_enabled or not CONFIG.debug_console then
        return
    end
    print(string.format(
        "[%s] level=%s event=%s detail=%s\n",
        MOD_NAME,
        tostring(level),
        tostring(event),
        tostring(detail or "")
    ))
end

local function notify(message, priority)
    if not CONFIG.debug_enabled or not CONFIG.debug_notifications then
        return
    end
    pcall(function()
        if not is_valid(cached_log_manager) then
            cached_log_manager = FindFirstOf("PalLogManager")
        end
        if is_valid(cached_log_manager) then
            cached_log_manager:AddLog(
                priority or 1,
                FText("[Instant Fishing Salvage] " .. tostring(message)),
                {}
            )
        end
    end)
end

local function on_salvage_range_calculated(model)
    counters.range_events = counters.range_events + 1
    model = unwrap(model)

    if not is_valid(model) then
        counters.failures = counters.failures + 1
        console_log("ERROR", "automatic_success_failed", "invalid-ui-model")
        notify("Automatic success failed; vanilla minigame remains active", 3)
        return
    end

    if completed_models[model] then
        counters.duplicate_models = counters.duplicate_models + 1
        console_log("DEBUG", "duplicate_result_ignored", model)
        return
    end
    completed_models[model] = true

    -- CalcGaugeRandomRange runs after Palworld has created and bound the
    -- salvage result model. SendResult(true) is the same success signal used
    -- by the vanilla minigame, so reward authority and inventory mutation stay
    -- in Palworld's existing result path.
    local ok, error_value = pcall(function()
        model:SendResult(true)
    end)
    if not ok then
        completed_models[model] = nil
        counters.failures = counters.failures + 1
        console_log("ERROR", "automatic_success_failed", error_value)
        notify("Automatic success failed; vanilla minigame remains active", 3)
        return
    end

    counters.success_signals = counters.success_signals + 1
    console_log(
        "INFO",
        "automatic_success_sent",
        string.format(
            "range_events=%d duplicates=%d successes=%d failures=%d",
            counters.range_events,
            counters.duplicate_models,
            counters.success_signals,
            counters.failures
        )
    )
end

local function on_interact_terminated(interact_component)
    counters.interact_terminate_events =
        counters.interact_terminate_events + 1
    interact_component = unwrap(interact_component)
    if not is_valid(interact_component) then
        return
    end

    -- TerminateInteract is Palworld's forced interaction-end boundary, used
    -- when a moving player loses the target. Vanilla normally ends the
    -- associated action itself. Repair only the broken case where the exact
    -- FishingSalvage action is still active after that boundary.
    local ok, active_before, active_after, owner_name = pcall(function()
        local owner = interact_component:GetOwner()
        if not is_valid(owner) then
            return false, false, "<invalid-owner>"
        end

        local action_component = owner:GetActionComponent()
        if not is_valid(action_component) then
            return false, false, full_name(owner)
        end

        local is_active = action_component:IsActiveActionType(
            ENUM.fishing_salvage_action,
            false
        )
        if is_active then
            action_component:CancelActionByType(
                ENUM.fishing_salvage_action
            )
        end
        local remains_active = action_component:IsActiveActionType(
            ENUM.fishing_salvage_action,
            false
        )
        return is_active, remains_active, full_name(owner)
    end)

    if not ok then
        counters.orphaned_action_cancel_failures =
            counters.orphaned_action_cancel_failures + 1
        console_log(
            "ERROR",
            "orphaned_salvage_recovery_failed",
            string.format(
                "terminations=%d recover_failures=%d error=%s",
                counters.interact_terminate_events,
                counters.orphaned_action_cancel_failures,
                tostring(active_before)
            )
        )
        return
    end

    if not active_before then
        return
    end

    if active_after then
        counters.orphaned_action_cancel_failures =
            counters.orphaned_action_cancel_failures + 1
    else
        counters.orphaned_actions_cancelled =
            counters.orphaned_actions_cancelled + 1
    end
    console_log(
        active_after and "ERROR" or "INFO",
        active_after and "orphaned_salvage_recovery_failed" or
            "orphaned_salvage_action_cancelled",
        string.format(
            "owner=%s terminations=%d cancelled=%d recover_failures=%d",
            tostring(owner_name),
            counters.interact_terminate_events,
            counters.orphaned_actions_cancelled,
            counters.orphaned_action_cancel_failures
        )
    )
end

local function on_salvage_ui_setup(widget)
    counters.ui_setup_events = counters.ui_setup_events + 1
    widget = unwrap(widget)
    if not is_valid(widget) then
        counters.ui_hide_failures = counters.ui_hide_failures + 1
        console_log("ERROR", "salvage_ui_hide_failed", "invalid-widget")
        return
    end

    local hidden_target = "Overlay_0"
    local visual_root = nil
    local visual_root_ok = pcall(function()
        visual_root = widget.Overlay_0
    end)
    visual_root = unwrap(visual_root)

    -- Never collapse or close this widget. The embedded minigame must keep
    -- ticking so its success animation can release the fishing action. Make
    -- only its visual root transparent; render opacity does not suspend the
    -- widget lifecycle.
    local target = visual_root_ok and is_valid(visual_root) and
        visual_root or widget
    if target == widget then
        hidden_target = "WBP_SalvageGame_fallback"
    end
    local ok, error_value = pcall(function()
        target:SetRenderOpacity(0.0)
    end)
    if ok then
        counters.ui_hidden = counters.ui_hidden + 1
    else
        counters.ui_hide_failures = counters.ui_hide_failures + 1
    end

    -- Do not call Close() here. WBP_SalvageGame.OnClose requests salvage
    -- cancellation, which races the success result. Keep the widget hidden
    -- and let Palworld's successful result lifecycle close it normally.
    console_log(
        ok and "INFO" or "ERROR",
        ok and "salvage_ui_render_suppressed" or "salvage_ui_hide_failed",
        string.format(
            "widget=%s target=%s setups=%d hidden=%d hide_failures=%d " ..
            "error=%s forced_close=false",
            full_name(widget),
            hidden_target,
            counters.ui_setup_events,
            counters.ui_hidden,
            counters.ui_hide_failures,
            ok and "" or tostring(error_value)
        )
    )
end

local function register_post_hook(name, path, callback)
    local ok, pre_id, post_id = pcall(
        RegisterHook,
        path,
        function()
        end,
        callback
    )
    console_log(
        ok and "INFO" or "ERROR",
        "hook_registration",
        string.format(
            "name=%s path=%s pre=%s post=%s error=%s",
            name,
            path,
            tostring(pre_id or ""),
            tostring(post_id or ""),
            ok and "" or tostring(pre_id)
        )
    )
    return ok
end

local function register_object_notification(name, path, callback)
    local ok, error_value = pcall(NotifyOnNewObject, path, callback)
    console_log(
        ok and "INFO" or "ERROR",
        "object_notification_registration",
        string.format(
            "name=%s path=%s ok=%s error=%s",
            name,
            path,
            tostring(ok),
            ok and "" or tostring(error_value)
        )
    )
    return ok
end

ensure_ui_setup_hook = function()
    if ui_hook_registered then
        return true
    end
    -- UE4SS executes the sole callback after Blueprint functions. Hide in
    -- that callback; a third callback is ignored for Blueprint code.
    local ok, hook_id = pcall(
        RegisterHook,
        PATHS.salvage_ui_setup,
        on_salvage_ui_setup
    )
    if ok then
        ui_hook_registered = true
    end
    console_log(
        ok and "INFO" or "DEBUG",
        "ui_hook_registration",
        string.format(
            "path=%s ok=%s hook=%s error=%s",
            PATHS.salvage_ui_setup,
            tostring(ok),
            tostring(hook_id or ""),
            ok and "" or tostring(hook_id)
        )
    )
    return ok
end

local range_ok = register_post_hook(
    "salvage_range",
    PATHS.salvage_range,
    on_salvage_range_calculated
)
local interact_terminate_ok = register_post_hook(
    "interact_terminate",
    PATHS.interact_terminate,
    on_interact_terminated
)
local ui_hook_ok = ensure_ui_setup_hook()
local widget_notify_ok = register_object_notification(
    "salvage_widget",
    PATHS.salvage_widget,
    function()
        ensure_ui_setup_hook()
    end
)
if range_ok and interact_terminate_ok and
        (ui_hook_ok or widget_notify_ok) then
    notify("Development build loaded", 1)
else
    notify("One or more salvage hooks failed to register", 3)
end

console_log(
    "INFO",
    "mod_loaded",
    string.format(
        "version=%s range_hook=%s interact_terminate_hook=%s " ..
        "ui_hook=%s widget_notify=%s " ..
        "no_tick=true no_timer=true no_scan=true",
        MOD_VERSION,
        tostring(range_ok),
        tostring(interact_terminate_ok),
        tostring(ui_hook_ok),
        tostring(widget_notify_ok)
    )
)
