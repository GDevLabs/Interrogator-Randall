-- Medicae use reports go through the same real mission-chat queue as ammo.
-- Waste is a *potential healing-capacity* estimate relative to full max HP,
-- not a fixed amount granted by the station. Corruption is shown separately.
local mod = get_mod("interrogator_randall")
local InteractionSettings = require("scripts/settings/interaction/interaction_settings")
local success = InteractionSettings.results.success

local M = {}
local started, waiting = {}, {}
local elapsed = 0
local REPLICATION_DELAY = 0.75
local function tracking_enabled()
    return mod:get("report_medicae") ~= false or
        mod:get("report_end_medicae_summary") ~= false or
        mod:get("report_end_medicae_team_total") ~= false
end

local function call(object, key, ...)
    local f = object and object[key]
    if type(f) ~= "function" then return nil end
    local ok, value = pcall(f, object, ...)
    if ok then return value end
end
local function field(object, key)
    local ok, value = pcall(function() return object and object[key] end)
    if ok then return value end
end
local function owner(unit)
    local managers = rawget(_G, "Managers")
    local spawn = managers and managers.state and managers.state.player_unit_spawn
    local player = call(spawn, "owner", unit)
    if not player then player = call(managers and managers.player, "player_by_unit", unit) end
    return player
end
local function safe_name(player)
    local name = call(player, "name")
    if type(name) ~= "string" then return nil end
    return name:gsub("{#.-}", ""):gsub("[\r\n]", " "):gsub("%[", "("):gsub("%]", ")")
end
local function health_snapshot(unit)
    if not unit then return nil end
    local ext = ScriptUnit.has_extension(unit, "health_system")
    if not ext then return nil end
    local hp = call(ext, "current_health")
    local max = call(ext, "max_health")
    if type(hp) ~= "number" or type(max) ~= "number" or max <= 0 then return nil end
    local corrupt = call(ext, "permanent_damage_taken")
    -- Try the replicated field if the health extension method is unavailable.
    if type(corrupt) ~= "number" then corrupt = field(ext, "_permanent_damage") end
    return { hp = hp, max = max,
        corrupt = type(corrupt) == "number" and corrupt or nil }
end
-- A Medicae station doesn't dispense a fixed amount of HP like an ammo pickup.
-- Compare observed HP restored against the player's maximum HP to estimate
-- UNUSED HEALING CAPACITY. A successful interaction with no observable
-- healing/corruption change is NOT proof that a charge was consumed.
local function observed_medicae_waste(before, after)
    if not before or not after or type(before.hp) ~= "number"
        or type(after.hp) ~= "number" or type(before.max) ~= "number"
        or before.max <= 0 then
        return nil
    end
    local restored = math.max(0, after.hp - before.hp)
    local cleared = 0
    if type(before.corrupt) == "number" and type(after.corrupt) == "number" then
        cleared = math.max(0, before.corrupt - after.corrupt)
    end
    return math.min(100, math.max(0,
        math.floor(100 * (before.max - restored) / before.max + 0.5)))
end

function M.waste_percent(before, after)
    return observed_medicae_waste(before, after)
end

local function effective_waste(entry, after)
    local measured = observed_medicae_waste(entry.before, after)
    local before = entry.before
    if before and before.max and before.max > 0 and
        type(entry.observed_heal) == "number" and entry.observed_heal > 0 then
        local delta = after and math.max(0, after.hp - before.hp) or 0
        local restored = math.min(before.max, math.max(delta, entry.observed_heal))
        return math.max(0, math.min(100,
            math.floor(100 * (before.max - restored) / before.max + 0.5)))
    end
    return measured
end

local function print_uses(entry, after)
    local before = entry.before
    local name = entry.name
    local prefix = name .. " used Medicae"
    if not before then
        return prefix .. " (health data unavailable)"
    end
    if not after then
        return string.format("%s at %d%% HP (heal amount unconfirmed)",
            prefix, math.floor(100 * before.hp / before.max + 0.5))
    end
    local restored = math.max(0, after.hp - before.hp)
    if entry.observed_heal then restored = math.max(restored, entry.observed_heal) end
    local full = math.max(1, before.max)
    local prior_pct = math.floor(math.min(100, 100 * before.hp / full) + 0.5)
    -- Report an estimated unused fraction of a full-health charge, not a game
    -- mechanic / literal amount of medical supply wasted.
    local unused_pct = effective_waste(entry, after)
    if unused_pct == nil then
        return string.format("%s at %d%% HP (healing not confirmed)", prefix, prior_pct)
    end
    local msg
    if restored < 0.5 then
        msg = string.format("%s at %d%% HP • no HP recovery observed • ~%d%% unused heal capacity",
            prefix, prior_pct, unused_pct)
    else
        msg = string.format("%s at %d%% HP • healed %d HP • ~%d%% unused heal capacity",
            prefix, prior_pct, math.floor(restored + 0.5), unused_pct)
    end
    if before.corrupt and after.corrupt then
        local cleared = math.max(0, before.corrupt - after.corrupt)
        if cleared >= 0.5 then msg = msg .. string.format(" • cleared %d corruption", math.floor(cleared + 0.5)) end
    end
    return msg
end
function M.format(entry, after) return print_uses(entry, after) end

local function on_started(self, interactor)
    if not tracking_enabled() then return end
    if call(self, "interaction_type") ~= "health_station" then return end
    local station = field(self, "_unit")
    if not station then return end
    local player = owner(interactor)
    -- When owner type is accessible, omit bot events; otherwise don't guess name.
    if not player or call(player, "is_human_controlled") ~= true then return end
    local name = safe_name(player)
    if not name then return end
    local records = started[station]
    if not records then records = {}; started[station] = records end
    -- Multiple started notifications (or multiple players beginning to use a
    -- station) must not overwrite each other. Deduplicate same-player starts.
    local record
    for _, old in ipairs(records) do
        if old.unit == interactor and elapsed - old.t < 1.5 then
            record = old
            break
        end
    end
    if not record then
        record = { unit = interactor, name = name,
            before = health_snapshot(interactor), t = elapsed }
        records[#records + 1] = record
    end
    if mod:get("diagnostic_logging") then
        mod:info("IR Medicae start: player=%s snapshot=%s pending=%d", name,
            tostring(record.before ~= nil), #records)
    end
end
local function on_stopped(self, result, interactor)
    local station = field(self, "_unit")
    local records = station and started[station]
    -- The game may deactivate interaction_type during stopped(), so a saved
    -- started list is authoritative, even when stopped has no interactor.
    if not records and call(self, "interaction_type") ~= "health_station" then return end
    if result ~= success or not tracking_enabled() then return end
    local record
    if records then
        local matching
        -- Prefer the observed recipient when the stopped callback lacks a unit.
        -- If no health update is visible yet, preserve interaction order.
        for i, candidate in ipairs(records) do
            if interactor and candidate.unit == interactor then
                matching = i; break
            end
            local after = health_snapshot(candidate.unit)
            local before = candidate.before
            if before and after and (after.hp > before.hp + 0.1 or
                (before.corrupt and after.corrupt and after.corrupt < before.corrupt - 0.1)) then
                matching = i
            end
        end
        record = table.remove(records, matching or 1)
        if #records == 0 then started[station] = nil end
    end
    if mod:get("diagnostic_logging") then
        mod:info("IR Medicae success: prior_start=%s interactor=%s", tostring(record ~= nil), tostring(interactor ~= nil))
    end
    -- started() isn't guaranteed to arrive on remote clients. Resolve the
    -- interactor passed by stopped() or the interactee's cached interactor.
    if not record then
        local unit = interactor or field(self, "_interactor_unit")
        local player = owner(unit)
        local name = safe_name(player)
        if name then
            record = { unit = unit, name = name, before = nil, t = elapsed }
        end
    end
    if not record then return end
    record.t = elapsed
    record.after = health_snapshot(record.unit)
    waiting[#waiting + 1] = record
end

-- Called by the shared InteracteeExtension hooks in interrogator_randall.lua.
-- Avoid duplicate DMF hook registration: duplicate hooks prevented our callbacks
-- from being reliably reached in the October 24 gameplay log.
M.on_started = on_started
M.on_stopped = on_stopped

-- Useful if another client never receives the InteracteeExtension.started()
-- event.  Called by a confirmed healing-station add_heal() hook below.
local function note_heal(extension, amount, heal_type)
    if not tracking_enabled() then return end
    local damage = require("scripts/settings/damage/damage_settings")
    local kinds = damage.heal_types
    if heal_type ~= kinds.healing_station and heal_type ~= kinds.blessing_health_station then return end
    if type(amount) ~= "number" or amount <= 0 then return end
    local unit = field(extension, "_unit")
    local player = owner(unit)
    local name = safe_name(player)
    if not name then return end
    local entry = nil
    for _, records in pairs(started) do
        for _, active in ipairs(records) do
            if active.unit == unit then entry = active; break end
        end
        if entry then break end
    end
    if not entry then
        for _, active in ipairs(waiting) do
            if active.unit == unit then entry = active; break end
        end
    end
    if entry then
        entry.observed_heal = (entry.observed_heal or 0) + amount
    end
end
mod:hook_require("scripts/extension_systems/health/player_unit_health_extension", function(instance)
    if type(instance.add_heal) ~= "function" then return end
    mod:hook(instance, "add_heal", function(func, self, amount, heal_type, ...)
        local actual = func(self, amount, heal_type, ...)
        local ok, err = pcall(note_heal, self, actual, heal_type)
        if not ok and type(mod.error) == "function" then
            pcall(mod.error, mod, "Medicae healing hook: %s", tostring(err))
        end
        return actual
    end)
end)

function M.update(dt)
    if not tracking_enabled() then
        M.reset()
        return
    end
    elapsed = elapsed + (dt or 0)
    for i = #waiting, 1, -1 do
        local record = waiting[i]
        local after = health_snapshot(record.unit) or record.after
        local improved = (record.observed_heal and record.observed_heal > 0) or
            (record.before and after and
            (after.hp > record.before.hp + 0.1 or
                (record.before.corrupt and after.corrupt and after.corrupt < record.before.corrupt - 0.1)))
        if (improved and elapsed - record.t >= 0.08)
            or elapsed - record.t >= REPLICATION_DELAY then
            -- Report measured HP/corruption usage against the waste slider.
            -- If snapshot data was unavailable, 0% is a diagnostic 'all uses'
            -- mode and still prints a truthful, non-numeric message.
            local unused_pct = effective_waste(record, after)
            local threshold = tonumber(mod:get("minimum_medicae_waste_to_report")) or 50
            threshold = math.min(100, math.max(0, threshold))
            -- Accumulate independently of the live waste threshold. A
            -- missing baseline cannot be assumed to have wasted 100% HP.
            if (mod:get("report_end_medicae_summary") ~= false or
                mod:get("report_end_medicae_team_total") ~= false) and unused_pct ~= nil
                and record.before and after and record.before.max > 0 then
                local used_hp = math.max(0, after.hp - record.before.hp)
                if record.observed_heal then
                    used_hp = math.max(used_hp, record.observed_heal)
                end
                local cleared = 0
                if type(record.before.corrupt)=="number" and
                    type(after.corrupt)=="number" then
                    cleared = math.max(0,record.before.corrupt-after.corrupt)
                end
                local summary = mod._healing_summary and mod._healing_summary()
                if summary then
                    summary:record_medicae(record.name,record.before.max,
                        used_hp,cleared)
                end
            end
            local chat = mod._chat_reports()
            if chat and mod:get("report_medicae")
                and (unused_pct and unused_pct >= threshold
                    or threshold == 0) then
                chat:queue_incident(print_uses(record, after), "report_medicae")
                if mod:get("diagnostic_logging") then
                    mod:info("IR Medicae queued: player=%s waste=%s threshold=%s", record.name, tostring(unused_pct), tostring(threshold))
                end
            end
            if mod:get("diagnostic_logging") and not (unused_pct and unused_pct >= threshold or threshold == 0) then
                mod:info("IR Medicae below threshold or missing HP snapshot: player=%s waste=%s threshold=%s", record.name, tostring(unused_pct), tostring(threshold))
            end
            table.remove(waiting, i)
        end
    end
    for station, records in pairs(started) do
        for i = #records, 1, -1 do
            if elapsed - records[i].t > 8 then table.remove(records, i) end
        end
        if #records == 0 then started[station] = nil end
    end
end
function M.reset()
    started, waiting = {}, {}
    elapsed = 0
end
return M
