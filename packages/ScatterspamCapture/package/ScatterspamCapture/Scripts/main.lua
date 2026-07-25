local MOD_NAME = "ScatterspamCapture"
local ASSET_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/InGame/GetReticle/" ..
    "WBP_PalGetReticle"
local HOOK_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/InGame/GetReticle/" ..
    "WBP_PalGetReticle.WBP_PalGetReticle_C:Set Display Capture Rate Force"
local TEXT_BLOCK_CLASS_PATH =
    "/Game/Pal/Blueprint/UI/PalTextBlock/" ..
    "BP_PalTextBlock.BP_PalTextBlock_C"
local ADD_LOG_HOOK_PATH = "/Script/Pal.PalLogManager:AddLog"
local SPHERE_WARNING_PREFIX = "This Sphere isn't working on"

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
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
        return
    end

    local absolute_rate = math.abs(rate)
    local reticle_key = reticle_key_for(reticle)
    local widgets = reticle_key ~= nil and
        widgets_by_reticle[reticle_key] or nil
    if widgets == nil then
        return
    end

    if absolute_rate >= 1.0 then
        -- Undo the persistent visibility change used by the sub-1% layout,
        -- then leave all numeric formatting to vanilla.
        local vanilla_percent = widgets["BP_PalTextBlock_C_2"]
        if is_valid(vanilla_percent) then
            pcall(function()
                vanilla_percent:SetText(FText("%"))
                vanilla_percent:SetVisibility(0)
            end)
        end
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

    local separate_percent = widgets["BP_PalTextBlock_C_2"]
    if is_valid(separate_percent) then
        pcall(function()
            separate_percent:SetText(FText(""))
            separate_percent:SetVisibility(1)
        end)
    end
end

local aiming_hook_registered = false
local sphere_warning_hook_registered = false

local function on_capture_rate_formatted(self, rate)
    local reticle = unwrap(self)
    local numeric_rate = unwrap(rate)
    ExecuteInGameThread(function()
        set_third_decimal(reticle, numeric_rate)
    end)
end

local function suppress_ineffective_sphere_warning(
    self,
    log_priority,
    log_text,
    additional_data
)
    local text_value = unwrap(log_text)
    if text_value == nil then
        return
    end

    local ok, message = pcall(function()
        return text_value:ToString()
    end)
    if not ok or type(message) ~= "string" then
        return
    end

    if string.sub(message, 1, #SPHERE_WARNING_PREFIX) ==
        SPHERE_WARNING_PREFIX then
        -- Priority None is Palworld's non-dispatch path. This prevents the
        -- warning from creating an invisible normal-log record for every
        -- projectile in a scatter burst.
        log_priority:set(0)
        log_text:set(FText(""))
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
            log("Aiming capture-rate hook registered")
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

-- Try immediately for hot reloads in an active world.
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
