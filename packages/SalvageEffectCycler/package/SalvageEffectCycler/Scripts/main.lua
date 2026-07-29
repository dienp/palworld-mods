local MOD_NAME = "SalvageEffectCycler"

local CONFIG = {
    -- Keep diagnostics in source. Disable these for a production build.
    debug_enabled = true,
    debug_notifications = true,
    debug_console = true,
}

-- Long-range systems with camera-scale modules, camera queries, or Palworld
-- far-range Niagara effect types. Every path below was verified and inspected
-- in Pal-Windows.pak on 2026-07-29.
local CANDIDATES = {
    {
        name = "Single Star (vanilla salvage)",
        path = "/Game/Pal/Effect/Common/Glow/NS_SingleStar",
    },
    {
        name = "Tower Panel",
        path = "/Game/Pal/Effect/Common/Glow/NS_TowerPanelGlow",
    },
    {
        name = "Fast Travel Point",
        path = "/Game/Pal/Effect/Common/Glow/NS_FastTravelPoint",
    },
    {
        name = "Fast Travel Unlocked",
        path = "/Game/Pal/Effect/Common/Glow/NS_FastTravelPoint_Unlocked",
    },
    {
        name = "Observation Point",
        path = "/Game/Pal/Effect/Common/Glow/NS_ObservationPoint",
    },
    {
        name = "Observation Point Unlocked",
        path = "/Game/Pal/Effect/Common/Glow/NS_ObservationPoint_Unlocked",
    },
    {
        name = "Item Pickup Tower",
        path = "/Game/Pal/Effect/Common/Glow/NS_ItemPickupTower_Glow",
    },
    {
        name = "Tower Panel Unlock",
        path = "/Game/Pal/Effect/Common/Glow/NS_TowerPanelGlow_Unlock",
    },
    {
        name = "Area Barrier Lock",
        path = "/Game/Pal/Effect/Environment/Gimmick/NS_AreaBarrier_Lock",
    },
    {
        name = "Area Barrier Unlock",
        path = "/Game/Pal/Effect/Environment/Gimmick/NS_AreaBarrier_Unlock",
    },
    {
        name = "World Tree Gate",
        path = "/Game/Pal/Effect/Common/Dungeon_Gate/NS_WorldTree_Gate",
    },
    {
        name = "Dungeon Gate in World Tree",
        path =
            "/Game/Pal/Effect/Common/Dungeon_Gate/" ..
            "NS_Dungeon_Gate_In_WorldTree",
    },
    {
        name = "Fast Travel Unlock Burst",
        path = "/Game/Pal/Effect/Common/Glow/NS_FastTravelUnlock",
    },
}

local SALVAGE_MARKERS = {
    "BP_MapObject_TreasureBox_FishingJunkSpot_Junk_Rank1",
    "BP_MapObject_TreasureBox_FishingJunkSpot_Junk_Rank2",
}

local current_index = 3
local scale_override = 0.12
local rate_override = 0.35
local counters = {
    commands = 0,
    scans = 0,
    components_examined = 0,
    components_matched = 0,
    successful_assignments = 0,
    failed_assignments = 0,
    parameter_failures = 0,
}

local function is_valid(object)
    if object == nil then
        return false
    end

    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid
end

local function full_name_of(object)
    if not is_valid(object) then
        return ""
    end

    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(name) or ""
end

local function console_log(message)
    if CONFIG.debug_enabled and CONFIG.debug_console then
        print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
    end
end

local function output(ar, message)
    local text = tostring(message)
    console_log(text)

    if ar ~= nil then
        pcall(function()
            ar:Log(text)
        end)
    end
end

local function notify(message)
    if not CONFIG.debug_enabled or not CONFIG.debug_notifications then
        return
    end

    pcall(function()
        local manager = FindFirstOf("PalLogManager")
        if is_valid(manager) then
            manager:AddLog(
                1,
                FText("[" .. MOD_NAME .. "] " .. tostring(message)),
                {}
            )
        end
    end)
end

local function is_salvage_component(component)
    local identity = full_name_of(component)

    local owner_ok, owner = pcall(function()
        return component:GetOwner()
    end)
    if owner_ok and is_valid(owner) then
        identity = identity .. " " .. full_name_of(owner)
    end

    for _, marker in ipairs(SALVAGE_MARKERS) do
        if string.find(identity, marker, 1, true) ~= nil then
            return true
        end
    end
    return false
end

local function find_salvage_components()
    counters.scans = counters.scans + 1

    local ok, components = pcall(function()
        return FindAllOf("NiagaraComponent")
    end)
    if not ok or type(components) ~= "table" then
        return {}, "FindAllOf(NiagaraComponent) failed: " ..
            tostring(components)
    end

    local matches = {}
    for _, component in ipairs(components) do
        counters.components_examined = counters.components_examined + 1
        if is_valid(component) and is_salvage_component(component) then
            table.insert(matches, component)
        end
    end

    counters.components_matched =
        counters.components_matched + #matches
    return matches, nil
end

local function asset_object_path(candidate)
    local short_name = string.match(candidate.path, "([^/]+)$")
    return candidate.path .. "." .. tostring(short_name)
end

local function find_resident_candidate(candidate)
    local target_path = asset_object_path(candidate)
    console_log("Enumerating resident Niagara systems for " .. candidate.name)

    local find_ok, systems = pcall(function()
        return FindAllOf("NiagaraSystem")
    end)
    if not find_ok or type(systems) ~= "table" then
        return nil, "FindAllOf(NiagaraSystem) failed: " .. tostring(systems)
    end

    for _, system in ipairs(systems) do
        if is_valid(system) then
            local full_name = full_name_of(system)
            if string.find(full_name, target_path, 1, true) ~= nil then
                console_log("Resident candidate found: " .. full_name)
                return system, nil
            end
        end
    end

    return nil, "Not resident; skipped safely: " .. target_path
end

local function assign_system(component, system)
    -- UE4SS's reflected Niagara function calls currently crash Palworld with
    -- a native access violation that Lua pcall cannot catch. Restrict this
    -- probe to the raw inherited Asset property.
    local assigned, assignment_error = pcall(function()
        component.Asset = system
    end)
    if not assigned then
        return false, "Asset property assignment failed: " ..
            tostring(assignment_error)
    end

    console_log("ReinitializeSystem begin")
    local reinitialized, reinitialize_error = pcall(function()
        component:ReinitializeSystem()
    end)
    if not reinitialized then
        return false, "ReinitializeSystem failed: " ..
            tostring(reinitialize_error)
    end
    console_log("ReinitializeSystem complete")
    return true, nil
end

local function apply_current(ar, resident_system)
    local candidate = CANDIDATES[current_index]
    local system = resident_system
    local load_error = nil
    if not is_valid(system) then
        system, load_error = find_resident_candidate(candidate)
    end
    if not is_valid(system) then
        output(ar, load_error)
        notify("Not resident: " .. candidate.name)
        return false
    end

    local components, scan_error = find_salvage_components()
    if scan_error ~= nil then
        output(ar, scan_error)
        notify("Niagara component scan failed")
        return false
    end

    if #components == 0 then
        local message = "No loaded salvage Niagara components found; " ..
            "stand near a salvage spot and run 'salvagefx apply'"
        output(ar, message)
        notify(message)
        return false
    end

    local changed = 0
    console_log(
        "Assigning " .. candidate.name .. " to " ..
            tostring(#components) .. " component(s)"
    )
    for index, component in ipairs(components) do
        console_log(
            "Property assignment " .. tostring(index) .. "/" ..
                tostring(#components) .. " begin"
        )
        local ok, error_message = assign_system(component, system)
        if ok then
            console_log(
                "Property assignment " .. tostring(index) .. "/" ..
                    tostring(#components) .. " complete"
            )
            changed = changed + 1
            counters.successful_assignments =
                counters.successful_assignments + 1
        else
            counters.failed_assignments =
                counters.failed_assignments + 1
            output(
                ar,
                "Assignment failed for " .. full_name_of(component) ..
                    ": " .. tostring(error_message)
            )
        end
    end

    local summary = string.format(
        "%d/%d: %s; applied to %d/%d component(s)",
        current_index,
        #CANDIDATES,
        candidate.name,
        changed,
        #components
    )
    output(ar, summary .. " [" .. candidate.path .. "]")
    notify(summary)
    return changed > 0
end

local function normalize_index(index)
    return ((index - 1) % #CANDIDATES) + 1
end

local function cycle(delta, ar)
    for _ = 1, #CANDIDATES do
        current_index = normalize_index(current_index + delta)
        local candidate = CANDIDATES[current_index]
        local system, resident_error = find_resident_candidate(candidate)
        if is_valid(system) then
            console_log("Cycle selected resident candidate " .. candidate.name)
            return apply_current(ar, system)
        end
        output(ar, resident_error)
    end

    output(ar, "No candidate Niagara systems are currently resident")
    notify("No candidate effects are currently resident")
    return false
end

local function find_candidate(query)
    local numeric = tonumber(query)
    if numeric ~= nil then
        local index = math.floor(numeric)
        if index >= 1 and index <= #CANDIDATES then
            return index
        end
        return nil
    end

    local normalized = string.lower(tostring(query or ""))
    for index, candidate in ipairs(CANDIDATES) do
        if string.find(
            string.lower(candidate.name),
            normalized,
            1,
            true
        ) ~= nil or string.find(
            string.lower(candidate.path),
            normalized,
            1,
            true
        ) ~= nil then
            return index
        end
    end
    return nil
end

local function print_list(ar)
    for index, candidate in ipairs(CANDIDATES) do
        local marker = index == current_index and "*" or " "
        output(
            ar,
            string.format(
                "%s %2d  %-26s %s",
                marker,
                index,
                candidate.name,
                candidate.path
            )
        )
    end
end

local function print_status(ar)
    local components, scan_error = find_salvage_components()
    local candidate = CANDIDATES[current_index]
    output(
        ar,
        string.format(
            "%d/%d: %s [%s]",
            current_index,
            #CANDIDATES,
            candidate.name,
            candidate.path
        )
    )
    output(
        ar,
        "Loaded salvage components: " ..
            tostring(scan_error or #components)
    )
    output(
        ar,
        string.format(
            "Counters commands=%d scans=%d examined=%d matched=%d " ..
                "assigned=%d failed=%d parameter_failures=%d",
            counters.commands,
            counters.scans,
            counters.components_examined,
            counters.components_matched,
            counters.successful_assignments,
            counters.failed_assignments,
            counters.parameter_failures
        )
    )
    output(
        ar,
        string.format(
            "Tuning scale=%.3f rate=%.3f",
            scale_override,
            rate_override
        )
    )
end

local function print_help(ar)
    output(
        ar,
        "salvagefx next|prev|apply|list|status|set <index-or-name>"
    )
    output(ar, "salvagefx scale <number>|rate <number>|tune <scale> <rate>")
    output(
        ar,
        "Hotkeys: F7 previous, F8 next, F9 reapply"
    )
end

RegisterConsoleCommandHandler(
    "salvagefx",
    function(_, parameters, ar)
        counters.commands = counters.commands + 1
        local action = string.lower(tostring(parameters[1] or "help"))

        if action == "next" then
            cycle(1, ar)
        elseif action == "prev" or action == "previous" then
            cycle(-1, ar)
        elseif action == "apply" or action == "refresh" then
            apply_current(ar)
        elseif action == "list" then
            print_list(ar)
        elseif action == "status" then
            print_status(ar)
        elseif action == "scale" then
            local value = tonumber(parameters[2])
            if value == nil or value <= 0.0 or value > 4.0 then
                output(ar, "Scale must be greater than 0 and at most 4")
            else
                scale_override = value
                apply_current(ar)
            end
        elseif action == "rate" then
            local value = tonumber(parameters[2])
            if value == nil or value < 0.0 or value > 10.0 then
                output(ar, "Rate must be between 0 and 10")
            else
                rate_override = value
                apply_current(ar)
            end
        elseif action == "tune" then
            local scale = tonumber(parameters[2])
            local rate = tonumber(parameters[3])
            if scale == nil or scale <= 0.0 or scale > 4.0 or
                rate == nil or rate < 0.0 or rate > 10.0 then
                output(ar, "Usage: salvagefx tune <scale 0..4> <rate 0..10>")
            else
                scale_override = scale
                rate_override = rate
                apply_current(ar)
            end
        elseif action == "set" then
            local query = table.concat(parameters, " ", 2)
            local index = find_candidate(query)
            if index == nil then
                output(ar, "Unknown candidate: " .. tostring(query))
                print_list(ar)
            else
                current_index = index
                apply_current(ar)
            end
        else
            print_help(ar)
        end
        return true
    end
)

RegisterKeyBind(
    Key.F7,
    function()
        console_log("F7 received")
        ExecuteInGameThread(function()
            cycle(-1, nil)
        end)
    end
)

RegisterKeyBind(
    Key.F8,
    function()
        console_log("F8 received")
        ExecuteInGameThread(function()
            cycle(1, nil)
        end)
    end
)

RegisterKeyBind(
    Key.F9,
    function()
        console_log("F9 received")
        ExecuteInGameThread(function()
            apply_current(nil)
        end)
    end
)

console_log(
    "Loaded " .. tostring(#CANDIDATES) ..
        " enumerate-only candidates; use F7/F8/F9 or 'salvagefx help'"
)
