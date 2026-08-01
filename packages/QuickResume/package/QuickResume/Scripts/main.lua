local MOD_NAME = "QuickResume"
local MOD_VERSION = "0.1.0-dev.2"

local CONFIG = {
    mod_caution_confirm_delay_ms = 80,
    title_safety_delay_ms = 250,
    world_list_delay_ms = 50,
    -- Keep diagnostics in source. Disable them through configuration for release.
    debug_enabled = true,
    debug_notifications = true,
    debug_console = true,
}

local PATHS = {
    title_asset =
        "/Game/Pal/Blueprint/UI/Title/WBP_TItle",
    local_world_select_asset =
        "/Game/Pal/Blueprint/UI/Title/WBP_TitleLocalWorldSelect",
    mod_caution_asset =
        "/Game/Pal/Blueprint/UI/Title/WBP_ModCautionDialog",
    title_check_mod_error =
        "/Game/Pal/Blueprint/UI/Title/WBP_TItle.WBP_TItle_C:CheckModError",
    mod_caution_confirmed =
        "/Game/Pal/Blueprint/UI/Title/WBP_ModCautionDialog." ..
        "WBP_ModCautionDialog_C:" ..
        "BndEvt__WBP_ModDisclaimerDialog_WBP_CommonButton_" ..
        "K2Node_ComponentBoundEvent_1_OnClicked__DelegateSignature",
    setup_world_list =
        "/Game/Pal/Blueprint/UI/Title/WBP_TitleLocalWorldSelect." ..
        "WBP_TitleLocalWorldSelect_C:SetupWorldList",
    mod_loader_default =
        "/Script/PalModLoader.Default__PalModLoaderLibrary",
}

local MODAL_CLASSES = {
    "WBP_PalDialog_C",
    "WBP_TitleWindow_Health_Warnings_C",
    "WBP_TitleWindow_EULA_C",
    "WBP_Title_TermsWindow_C",
}

local title_hook_registered = false
local world_hook_registered = false
local mod_caution_hook_registered = false
local overlay_notification_registered = false
local title_flow_started = false
local world_start_requested = false
local blocked_for_crash = false
local mod_caution_active = false
local cached_title = nil
local cached_log_manager = nil
local counters = {
    title_checks = 0,
    crash_blocks = 0,
    mod_caution_seen = 0,
    mod_caution_confirmed = 0,
    modal_blocks = 0,
    overlay_notifications = 0,
    world_lists = 0,
    starts = 0,
    failures = 0,
}

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
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or tostring(object)
end

local function value_string(value)
    value = unwrap(value)
    if value == nil then
        return ""
    end
    local ok, text = pcall(function()
        return value:ToString()
    end)
    return ok and tostring(text) or tostring(value)
end

local function get_property(object, name)
    object = unwrap(object)
    if not is_valid(object) then
        return nil
    end
    local ok, value = pcall(function()
        return object:GetPropertyValue(name)
    end)
    return ok and unwrap(value) or nil
end

local function notify(message)
    if not CONFIG.debug_enabled or not CONFIG.debug_notifications then
        return
    end
    pcall(function()
        if not is_valid(cached_log_manager) then
            cached_log_manager = FindFirstOf("PalLogManager")
        end
        if is_valid(cached_log_manager) then
            cached_log_manager:AddLog(
                1,
                FText("[" .. MOD_NAME .. "] " .. tostring(message)),
                {}
            )
        end
    end)
end

local function log(event, fields)
    if not CONFIG.debug_enabled then
        return
    end
    local parts = {
        "[" .. MOD_NAME .. "]",
        "version=" .. MOD_VERSION,
        "event=" .. tostring(event),
    }
    if fields ~= nil then
        local keys = {}
        for key, _ in pairs(fields) do
            table.insert(keys, key)
        end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value = string.gsub(tostring(fields[key]), "[\r\n|]", " ")
            table.insert(parts, tostring(key) .. "=" .. value)
        end
    end
    local message = table.concat(parts, " | ")
    if CONFIG.debug_console then
        print(message .. "\n")
    end
end

local function fail(event, reason)
    counters.failures = counters.failures + 1
    log(event, {
        reason = reason,
        failures = counters.failures,
    })
    notify(event .. ": " .. tostring(reason))
end

local function crash_warning_required()
    local library = StaticFindObject(PATHS.mod_loader_default)
    if not is_valid(library) then
        return nil, "mod-loader-library-unavailable"
    end
    local ok, required = pcall(function()
        return unwrap(library:IsNeedShowErrorOnNextStart())
    end)
    if not ok then
        return nil, "crash-state-query-failed:" .. tostring(required)
    end
    return required == true or tonumber(required) == 1, nil
end

local function mark_crash_warning(stage)
    if blocked_for_crash then
        return true
    end
    local required, query_error = crash_warning_required()
    if required == nil then
        fail("crash_state_query_failed", query_error)
        return nil
    end
    if not required then
        return false
    end
    blocked_for_crash = true
    counters.crash_blocks = counters.crash_blocks + 1
    log("crash_warning_detected", {
        stage = stage,
        crash_blocks = counters.crash_blocks,
    })
    return true
end

local function confirm_mod_caution(widget)
    if blocked_for_crash or not mod_caution_active or not is_valid(widget) then
        return
    end
    local crash_state = mark_crash_warning("mod-caution")
    if crash_state ~= false then
        return
    end
    local ok, error_value = pcall(function()
        widget:
            BndEvt__WBP_ModDisclaimerDialog_WBP_CommonButton_K2Node_ComponentBoundEvent_1_OnClicked__DelegateSignature()
    end)
    if not ok then
        fail("mod_caution_auto_confirm_failed", error_value)
        return
    end
    log("mod_caution_auto_confirm_requested", {
        object = full_name(widget),
    })
end

local function on_new_overlay_widget(widget)
    widget = unwrap(widget)
    if not is_valid(widget) then
        return
    end
    counters.overlay_notifications = counters.overlay_notifications + 1
    local widget_name = ""
    pcall(function()
        widget_name = value_string(widget:GetFName())
    end)

    if string.find(widget_name, "WBP_PalDialog", 1, true) ~= nil then
        mark_crash_warning("dialog-created")
        return
    end

    local is_mod_caution =
        string.find(widget_name, "WBP_ModCautionDialog", 1, true) ~= nil or
        string.find(widget_name, "WBP_ModDisclaimerDialog", 1, true) ~= nil
    if not is_mod_caution then
        return
    end

    mod_caution_active = true
    counters.mod_caution_seen = counters.mod_caution_seen + 1
    log("mod_caution_created", {
        object = full_name(widget),
        seen = counters.mod_caution_seen,
    })
    local caution_widget = widget
    ExecuteWithDelay(CONFIG.mod_caution_confirm_delay_ms, function()
        ExecuteInGameThread(function()
            confirm_mod_caution(caution_widget)
        end)
    end)
end

local function active_startup_modal()
    for _, class_name in ipairs(MODAL_CLASSES) do
        local ok, object = pcall(FindFirstOf, class_name)
        if ok and is_valid(object) then
            return object, class_name
        end
    end
    return nil, nil
end

local function safety_gate(stage)
    if blocked_for_crash then
        return false, "crash-warning-blocked-session"
    end

    local crash_state = mark_crash_warning(stage)
    if crash_state == nil then
        return false, "crash-state-query-failed"
    end
    if crash_state then
        return false, "crash-warning-required"
    end
    if mod_caution_active then
        return false, "mod-caution-active"
    end

    local modal, class_name = active_startup_modal()
    if is_valid(modal) then
        counters.modal_blocks = counters.modal_blocks + 1
        log("startup_modal_detected", {
            stage = stage,
            class = class_name,
            object = full_name(modal),
            modal_blocks = counters.modal_blocks,
        })
        return false, "startup-modal-active"
    end
    return true, nil
end

local function open_local_world_list(title)
    if title_flow_started or blocked_for_crash then
        return
    end
    counters.title_checks = counters.title_checks + 1

    local safe, reason = safety_gate("title")
    if not safe then
        if reason ~= "crash-warning-required" and
            reason ~= "startup-modal-active" and
            reason ~= "mod-caution-active" then
            fail("title_safety_gate_failed", reason)
        end
        return
    end

    title = unwrap(title)
    local title_menu = get_property(title, "WBP_TitleMenu")
    local local_game_button =
        get_property(title_menu, "WBP_Title_MenuButton_StartLocalGame")
    if not is_valid(local_game_button) then
        fail("open_local_world_list_failed", "local-game-button-unavailable")
        return
    end

    local ok, error_value = pcall(function()
        title:OnClickedMenu_Internal(local_game_button)
    end)
    if not ok then
        fail("open_local_world_list_failed", error_value)
        return
    end

    title_flow_started = true
    log("local_world_list_requested", {
        title_checks = counters.title_checks,
        button = full_name(local_game_button),
    })
end

local function first_local_world_button(local_world_select)
    local world_select =
        get_property(local_world_select, "WBP_Title_WorldSelect")
    if not is_valid(world_select) then
        return nil, nil, "world-select-widget-unavailable"
    end

    local scroll_list =
        get_property(world_select, "WBP_PalCommonScrollList")
    if not is_valid(scroll_list) then
        return nil, world_select, "world-scroll-list-unavailable"
    end

    local scroll_box = nil
    local ok, error_value = pcall(function()
        scroll_box = unwrap(scroll_list:GetScrollBox())
    end)
    if not ok or not is_valid(scroll_box) then
        return nil, world_select,
            "world-scroll-box-unavailable:" .. tostring(error_value or "")
    end

    local child = nil
    ok, error_value = pcall(function()
        child = unwrap(scroll_box:GetChildAt(0))
    end)
    if not ok or not is_valid(child) then
        return nil, world_select,
            "no-local-world:" .. tostring(error_value or "")
    end

    if string.find(
        full_name(child),
        "WBP_Title_WorldSelect_ListContent_C",
        1,
        true
    ) == nil then
        return nil, world_select, "first-entry-is-not-a-local-world"
    end

    local directory_name =
        value_string(get_property(child, "BindedSaveDirectoryName"))
    if directory_name == "" then
        return nil, world_select, "first-entry-has-no-save-directory"
    end
    return child, world_select, nil
end

local function start_first_local_world(local_world_select)
    if world_start_requested or blocked_for_crash then
        return
    end

    local safe, reason = safety_gate("world-list")
    if not safe then
        if reason ~= "crash-warning-required" and
            reason ~= "startup-modal-active" and
            reason ~= "mod-caution-active" then
            fail("world_list_safety_gate_failed", reason)
        end
        return
    end

    local_world_select = unwrap(local_world_select)
    local button, world_select, selection_error =
        first_local_world_button(local_world_select)
    if not is_valid(button) then
        fail("resume_selection_failed", selection_error)
        return
    end

    local directory_name =
        value_string(get_property(button, "BindedSaveDirectoryName"))
    local world_name = value_string(get_property(button, "World Name"))
    local ok, error_value = pcall(function()
        world_select:OnClickedWorldButton_Internal(button)
        local_world_select:OnClickedStartWorldButtonEventInternal()
    end)
    if not ok then
        fail("resume_start_failed", error_value)
        return
    end

    world_start_requested = true
    counters.starts = counters.starts + 1
    log("resume_start_requested", {
        starts = counters.starts,
        save_directory = directory_name,
        world_name = world_name,
        selected_button = full_name(button),
    })
    notify("Resuming " .. (world_name ~= "" and world_name or directory_name))
end

local function on_title_check_mod_error(title)
    local title_object = unwrap(title)
    cached_title = title_object
    ExecuteWithDelay(CONFIG.title_safety_delay_ms, function()
        ExecuteInGameThread(function()
            open_local_world_list(title_object)
        end)
    end)
end

local function on_mod_caution_confirmed()
    mod_caution_active = false
    counters.mod_caution_confirmed = counters.mod_caution_confirmed + 1
    log("mod_caution_confirmed", {
        confirmed = counters.mod_caution_confirmed,
    })
    local title_object = cached_title
    if is_valid(title_object) and not blocked_for_crash then
        ExecuteWithDelay(CONFIG.title_safety_delay_ms, function()
            ExecuteInGameThread(function()
                open_local_world_list(title_object)
            end)
        end)
    end
end

local function on_setup_world_list(local_world_select)
    counters.world_lists = counters.world_lists + 1
    local select_object = unwrap(local_world_select)
    ExecuteWithDelay(CONFIG.world_list_delay_ms, function()
        ExecuteInGameThread(function()
            start_first_local_world(select_object)
        end)
    end)
end

local function load_assets_and_register_hooks()
    for _, asset_path in ipairs({
        PATHS.title_asset,
        PATHS.local_world_select_asset,
        PATHS.mod_caution_asset,
    }) do
        pcall(LoadAsset, asset_path)
    end

    if not overlay_notification_registered then
        local ok, error_value = pcall(
            NotifyOnNewObject,
            "/Script/Pal.PalUserWidgetOverlayUI",
            on_new_overlay_widget
        )
        overlay_notification_registered = ok
        log(ok and "overlay_notification_registered" or
            "overlay_notification_registration_failed", {
            error = ok and "" or error_value,
        })
    end

    if not title_hook_registered then
        local ok, hook_id = pcall(
            RegisterHook,
            PATHS.title_check_mod_error,
            on_title_check_mod_error
        )
        title_hook_registered = ok
        log(ok and "title_hook_registered" or
            "title_hook_registration_failed", {
            hook_id = hook_id or "",
        })
    end

    if not world_hook_registered then
        local ok, hook_id = pcall(
            RegisterHook,
            PATHS.setup_world_list,
            on_setup_world_list
        )
        world_hook_registered = ok
        log(ok and "world_hook_registered" or
            "world_hook_registration_failed", {
            hook_id = hook_id or "",
        })
    end

    if not mod_caution_hook_registered then
        local ok, hook_id = pcall(
            RegisterHook,
            PATHS.mod_caution_confirmed,
            on_mod_caution_confirmed
        )
        mod_caution_hook_registered = ok
        log(ok and "mod_caution_hook_registered" or
            "mod_caution_hook_registration_failed", {
            hook_id = hook_id or "",
        })
    end
end

local immediate_ok, immediate_error =
    pcall(load_assets_and_register_hooks)
if not immediate_ok then
    fail("immediate_initialization_failed", immediate_error)
end

ExecuteInGameThread(load_assets_and_register_hooks)

log("loaded", {
    diagnostics = CONFIG.debug_enabled,
    performance = "event-driven-no-tick",
})
