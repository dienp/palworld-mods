local MOD_NAME = "ScatterspamCapture"
local ASSET_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/InGame/GetReticle/" ..
    "WBP_PalGetReticle"
local HOOK_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/InGame/GetReticle/" ..
    "WBP_PalGetReticle.WBP_PalGetReticle_C:SetCaptureRateForce"
local TEXT_BLOCK_CLASS_PATH =
    "/Game/Pal/Blueprint/UI/PalTextBlock/" ..
    "BP_PalTextBlock.BP_PalTextBlock_C"
local ADD_LOG_HOOK_PATH = "/Script/Pal.PalLogManager:AddLog"
local SPHERE_WARNING_PREFIX = "this sphere isn't working on"
local debug_enabled = false
local debug_notifications = false
local debug_console = false
local formatter_debug_count = 0
local FORMATTER_DEBUG_LIMIT = 20

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function debug_log(message)
    if debug_enabled and debug_console and
        formatter_debug_count < FORMATTER_DEBUG_LIMIT then
        formatter_debug_count = formatter_debug_count + 1
        log("DEBUG formatter: " .. message)
    end
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    local ok, unwrapped = pcall(function()
        return value:get()
    end)
    if ok then
        return unwrapped
    end

    return value
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

local aiming_digit_widget = nil
local digit_widgets_by_reticle = {}
local widgets_by_reticle = {}
local cached_text_widgets = {}
local widget_notification_registered = false
local existing_widgets_seeded = false

local function full_name_of(object)
    if not is_valid(object) then
        return nil
    end

    local ok, full_name = pcall(function()
        return object:GetFullName()
    end)
    return ok and full_name or nil
end

local function reticle_key_for(object)
    local full_name = full_name_of(object)
    if full_name == nil then
        return nil
    end

    local object_path = string.match(full_name, "^%S+%s(.+)$")
    if object_path == nil then
        return nil
    end

    local marker = ".WBP_PalGetReticle"
    local marker_start = string.find(object_path, marker, 1, true)
    if marker_start == nil then
        return nil
    end

    local reticle_path = string.sub(
        object_path,
        1,
        marker_start + #marker - 1
    )
    return "WBP_PalGetReticle_C " .. reticle_path
end

local function remember_digit_widget(object)
    local widget = unwrap(object)
    if not is_valid(widget) then
        return
    end

    cached_text_widgets[full_name_of(widget) or tostring(widget)] = widget

    local reticle_key = reticle_key_for(widget)
    local widget_name = full_name_of(widget)
    if reticle_key ~= nil and widget_name ~= nil then
        local short_name = string.match(widget_name, "%.([^%.]+)$")
        if short_name ~= nil then
            widgets_by_reticle[reticle_key] =
                widgets_by_reticle[reticle_key] or {}
            widgets_by_reticle[reticle_key][short_name] = widget
        end
    end

    local ok, full_name = pcall(function()
        return widget:GetFullName()
    end)
    if ok and string.find(
        full_name,
        "BP_PalTextBlock_C_6",
        1,
        true
    ) ~= nil then
        aiming_digit_widget = widget
        if reticle_key ~= nil then
            digit_widgets_by_reticle[reticle_key] = widget
        end
    end
end

local function digit_widget_for(reticle)
    local reticle_key = reticle_key_for(reticle)
    local digit_widget = reticle_key ~= nil and
        digit_widgets_by_reticle[reticle_key] or nil
    if not is_valid(digit_widget) then
        digit_widget = aiming_digit_widget
    end
    return digit_widget
end

local function set_third_decimal(reticle, rate)
    if not is_valid(reticle) or type(rate) ~= "number" then
        debug_log(string.format(
            "invalid input; reticle_valid=%s rate=%s rate_type=%s",
            tostring(is_valid(reticle)),
            tostring(rate),
            type(rate)
        ))
        return
    end

    local absolute_rate = math.abs(rate)
    local reticle_key = reticle_key_for(reticle)
    local widgets = reticle_key ~= nil and
        widgets_by_reticle[reticle_key] or nil
    if widgets == nil then
        debug_log(string.format(
            "no widget map; rate=%.9f reticle_key=%s",
            absolute_rate,
            tostring(reticle_key)
        ))
        return
    end

    local widget_names = {}
    for name, widget in pairs(widgets) do
        if is_valid(widget) then
            table.insert(widget_names, name)
        end
    end
    table.sort(widget_names)
    debug_log(string.format(
        "called; rate=%.9f reticle_key=%s widgets=%s",
        absolute_rate,
        tostring(reticle_key),
        table.concat(widget_names, ",")
    ))

    if absolute_rate >= 0.01 then
        -- The Blueprint hook runs after SetCaptureRateForce, which has already
        -- restored every vanilla field, including its percent suffix.
        return
    end

    -- Set Display Capture Rate Force already supplies percentage units.
    local percent_rate = absolute_rate
    local truncated_thousandths =
        math.floor(percent_rate * 1000.0)
    local tenths = math.floor(truncated_thousandths / 100) % 10
    local hundredths = math.floor(truncated_thousandths / 10) % 10
    local thousandths = truncated_thousandths % 10

    local values = {
        BP_PalTextBlock_C_3 = ".",
        BP_PalTextBlock_C_4 = tostring(tenths),
        BP_PalTextBlock_C_5 = tostring(hundredths),
        BP_PalTextBlock_C_6 = tostring(thousandths) .. "%",
    }

    for name, value in pairs(values) do
        local widget = widgets[name]
        if is_valid(widget) then
            pcall(function()
                widget:SetText(FText(value))
                widget:SetVisibility(0)
            end)
        end
    end

end

local aiming_hook_registered = false
local sphere_warning_hook_registered = false

local function on_capture_rate_formatted(self, rate)
    local reticle = unwrap(self)
    local numeric_rate = unwrap(rate)
    set_third_decimal(reticle, numeric_rate)
end

local function text_to_string(parameter)
    local text_value = unwrap(parameter)
    if text_value == nil then
        return nil
    end

    if type(text_value) == "string" then
        return text_value
    end

    local ok, message = pcall(function()
        return text_value:ToString()
    end)
    if not ok or type(message) ~= "string" then
        return nil
    end

    return message
end

local function suppress_ineffective_sphere_warning(...)
    local parameters = { ... }

    -- Palworld has changed AddLog's native parameter layout across revisions.
    -- Locate the FText argument by value instead of assuming a fixed position.
    for index = 2, #parameters do
        local parameter = parameters[index]
        local message = text_to_string(parameter)
        if message ~= nil then
            local normalized_message = string.lower(message)
            if string.sub(normalized_message, 1, #SPHERE_WARNING_PREFIX) ==
                SPHERE_WARNING_PREFIX then
                -- AddLog places EPalLogPriority immediately before its FText
                -- argument. None (0) takes Palworld's non-dispatch path, so no
                -- empty notification record is added to the queue.
                local priority_parameter = parameters[index - 1]
                if priority_parameter ~= nil then
                    pcall(function()
                        priority_parameter:set(0)
                    end)
                end
                parameter:set(FText(""))
                return
            end
        end
    end
end

local function load_asset_and_register_hook()
    -- The widget Blueprint is not loaded when UE4SS starts. Loading it here
    -- makes its generated class and functions available to RegisterHook.
    pcall(function()
        LoadAsset(ASSET_PATH)
    end)

    if not widget_notification_registered then
        local ok = pcall(
            NotifyOnNewObject,
            TEXT_BLOCK_CLASS_PATH,
            remember_digit_widget
        )
        if ok then
            widget_notification_registered = true
            log("Third-digit construction cache registered")
        end
    end

    -- Seed the currently active reticle once after startup or hot reload.
    if not is_valid(aiming_digit_widget) then
        local ok, widget = pcall(function()
            return FindObject(nil, "BP_PalTextBlock_C_6", nil, nil)
        end)
        if ok and is_valid(widget) then
            remember_digit_widget(widget)
        end
    end

    -- Hot reload occurs after the active reticle's children were constructed,
    -- so seed all existing Pal text blocks once. This is never called from the
    -- formatter path.
    if not existing_widgets_seeded then
        existing_widgets_seeded = true
        local ok, widgets = pcall(function()
            return FindObjects(
                0,
                "BP_PalTextBlock_C",
                nil,
                nil,
                nil,
                false
            )
        end)
        if ok and type(widgets) == "table" then
            log("Seeded Pal text widgets: " .. tostring(#widgets))
            for _, widget in ipairs(widgets) do
                remember_digit_widget(widget)
            end
        else
            log("Unable to seed existing Pal text widgets")
        end
    end

    if not aiming_hook_registered then
        local ok = pcall(
            RegisterHook,
            HOOK_PATH,
            on_capture_rate_formatted
        )
        if ok then
            aiming_hook_registered = true
            log("SetCaptureRateForce formatter hook registered")
        end
    end

    if not sphere_warning_hook_registered then
        local ok = pcall(
            RegisterHook,
            ADD_LOG_HOOK_PATH,
            suppress_ineffective_sphere_warning
        )
        if ok then
            sphere_warning_hook_registered = true
            log("Ineffective-sphere warning filter registered")
        end
    end
end

-- A hot reload happens in an already initialized world. Register synchronously
-- first because UE4SS's deferred EngineTick dispatcher may have been removed
-- while unloading the previous Lua instance.
local immediate_ok, immediate_error = pcall(load_asset_and_register_hook)
if not immediate_ok then
    log("Immediate initialization failed: " .. tostring(immediate_error))
end

-- Retain a game-thread attempt for cold startup and unusual load sequences.
ExecuteInGameThread(load_asset_and_register_hook)

-- Try again after future world initialization.
RegisterInitGameStatePostHook(function()
    load_asset_and_register_hook()
end)

-- Cover slow asset loading and unusual world-start sequences.
LoopAsync(1000, function()
    if aiming_hook_registered and sphere_warning_hook_registered then
        return true
    end

    ExecuteInGameThread(load_asset_and_register_hook)
    return false
end)

log("Loaded; waiting for the capture-reticle asset")
