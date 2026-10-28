-- Interrogator Randall: ordinary Daemonhost phases + Gormaggoth (v0.15).
-- 1) AWAKENED: first detected non-hostile alert, including direct damage.
-- 2) HOSTILE: the player who pushed it into combat and its first target/attack.
-- At most two shared mission-chat messages per Daemonhost.
-- The source for some anger changes is server-side; inferred attribution may
-- be wrong even though the chat renders a player name without qualifier.
local mod = get_mod("interrogator_randall")
local AttackingUnitResolver = require("scripts/utilities/attack/attacking_unit_resolver")
local ok_perception, MinionPerceptionUtility = pcall(require, "scripts/utilities/minion_perception")
if not ok_perception then MinionPerceptionUtility = nil end

local M = {}
local hosts = {}
local clock, scan_clock, fallback_clock = 0, 0, 0
-- Avoid a broad global-unit scan every 0.15 seconds for an entire mission
-- that contains no Daemonhost. Maintain the previous fast scan near a host.
local SCAN_INTERVAL_ACTIVE = 0.15
local SCAN_INTERVAL_IDLE = 0.5
local HIT_WINDOW = 3.0
local FIRST_TARGET_DELAY = 1.5
local TRIGGER_DELAY = 0.25
local HOST_EXPIRATION = 45
local diag_scan_logged = false
local TORMENT_BREED = "chaos_daemonhost_torment"
-- A target lock-on is not proof of a landed hit. Wait briefly for an
-- observed attack before using the initial target as the attack recipient.
local TORMENT_TARGET_DELAY = 1.2

local HOST_BREEDS = {
    chaos_daemonhost = true,
    chaos_mutator_daemonhost = true,
    chaos_daemonhost_torment = true,
}
local ALERT_STATES = {
    agitated = true, disturbed = true, about_to_wake_up = true,
    alerted = true, alert = true,
}
local HOSTILE_STATES = {
    waking_up = true, aggroed = true, aggressive = true,
    attacking = true, combat = true, hostile = true,
}
local REASONS = {
    distance = "proximity", proximity = "proximity", closest = "proximity",
    flashlight = "flashlight", light = "flashlight", flashed = "flashlight",
    suppression = "suppression", suppress = "suppression",
    sound = "noise / gunfire", noise = "noise / gunfire",
    damage = "damage", hit = "damage", attack = "damage",
    stagger = "stagger / ability", taunt = "taunt / ability",
}

local function read(object, key)
    local ok, value = pcall(function() return object and object[key] end)
    if ok then return value end
end
local function call(object, name, ...)
    local fn = read(object, name)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, object, ...)
    if ok then return result end
end
local function pick(object, keys)
    for i = 1, #keys do
        local result = read(object, keys[i])
        if result ~= nil then return result end
    end
end
local function player_from_unit(unit)
    if not unit then return nil end
    local managers = rawget(_G, "Managers")
    local spawn = managers and managers.state and managers.state.player_unit_spawn
    return call(spawn, "owner", unit)
        or call(managers and managers.player, "player_by_unit", unit)
end
local function human_name(unit)
    local player = player_from_unit(unit)
    if not player or call(player, "is_human_controlled") ~= true then return nil end
    local name = call(player, "name")
    if type(name) ~= "string" then return nil end
    return name:gsub("{#.-}", ""):gsub("[\r\n]", " "):gsub("%[", "("):gsub("%]", ")")
end
local function resolved_player(unit)
    if not unit then return nil end
    if human_name(unit) then return unit end
    local ok, resolved = pcall(AttackingUnitResolver.resolve, unit)
    if ok and resolved and human_name(resolved) then return resolved end
end
local function breed_name(unit, extension)
    local data = extension or (unit and ScriptUnit.has_extension(unit, "unit_data_system"))
    local breed = call(data, "breed") or read(data, "_breed")
    local boards = rawget(_G, "BLACKBOARDS")
    local board = boards and boards[unit]
    return read(breed, "name") or call(data, "breed_name")
        or read(read(board, "breed"), "name")
end
local function is_host(unit)
    return unit ~= nil and HOST_BREEDS[breed_name(unit)] == true
end
local function is_torment(unit)
    return unit ~= nil and breed_name(unit) == TORMENT_BREED
end
local function report(message)
    -- Gate directly as well as at the shared chat sender. This prevents
    -- a stale Gormaggoth observation from reporting after mod disable.
    if type(mod._reporting_enabled) ~= "function" or
        not mod._reporting_enabled("report_daemonhost") then return end
    local chat = mod._chat_reports and mod._chat_reports()
    if chat then chat:queue_incident(message, "report_daemonhost") end
end
local function pos_of(unit)
    if not unit then return nil end
    local lookup = rawget(_G, "POSITION_LOOKUP")
    if lookup and lookup[unit] then return lookup[unit] end
    if not rawget(_G, "Unit") or not Unit.world_position then return nil end
    local alive = rawget(_G, "ALIVE")
    if alive and not alive[unit] then return nil end
    local ok, position = pcall(Unit.world_position, unit, 1)
    if ok then return position end
end
local function distance(a, b)
    if not a or not b then return nil end
    local vector = rawget(_G, "Vector3")
    if not vector or type(vector.distance_squared) ~= "function" then return nil end
    local ok, squared = pcall(vector.distance_squared, a, b)
    if ok and type(squared) == "number" and squared >= 0 then return math.sqrt(squared) end
end
local function closest_player(host_unit)
    local managers = rawget(_G, "Managers")
    local players = call(managers and managers.player, "players")
    local position = pos_of(host_unit)
    if not players or not position then return nil end
    local best_unit, best_distance
    for _, player in pairs(players) do
        if call(player, "is_human_controlled") then
            local unit = call(player, "player_unit") or read(player, "player_unit")
            if type(unit) == "function" then unit = call(player, "player_unit") end
            local d = distance(pos_of(unit), position)
            if d and (not best_distance or d < best_distance) then
                best_unit, best_distance = unit, d
            end
        end
    end
    return best_unit
end

local function host_state(unit)
    local boards = rawget(_G, "BLACKBOARDS")
    local board = boards and boards[unit]
    local behavior = read(board, "behavior") or read(board, "behaviour") or {}
    local anger = read(board, "anger") or read(board, "daemonhost") or {}
    local perception = read(board, "perception") or {}
    local aggro = pick(perception, {"aggro_state", "anger_state", "state"})
        or pick(behavior, {"aggro_state", "anger_state", "state"})
        or pick(anger, {"aggro_state", "anger_state", "state", "current_state"})
        or pick(board, {"aggro_state", "anger_state", "state"})
    local stage = pick(perception, {"stage", "anger_stage", "witch_stage"})
        or pick(behavior, {"stage", "anger_stage"})
        or pick(anger, {"stage", "anger_stage"})
        or pick(board, {"stage", "anger_stage"})
    -- Daemonhost stage is a replicated game-object field on clients (1=passive,
    -- 2-5=alert/waking, 6=aggroed); it isn't necessarily in BLACKBOARDS.
    -- This is the actual client-side contract used by BetterBots shared_rules.
    local managers = rawget(_G, "Managers")
    local state = managers and managers.state
    local game = call(state and state.game_session, "game_session")
    local id = call(state and state.unit_spawner, "game_object_id", unit)
    local session_api = rawget(_G, "GameSession")
    if game and id ~= nil and session_api and type(session_api.game_object_field) == "function" then
        local ok, replicated = pcall(session_api.game_object_field, game, id, "stage")
        if ok and type(replicated) == "number" then stage = replicated end
    end
    local target = pick(perception, {"target_unit", "target_enemy", "aggro_target_unit"})
        or pick(behavior, {"target_unit", "target_enemy", "aggro_target_unit"})
        or pick(board, {"target_unit", "target_enemy"})
    local status
    if type(stage) == "number" then
        if stage >= 6 then status = "hostile"
        elseif stage >= 2 then status = "alerted"
        elseif stage == 1 then status = "dormant" end
    elseif type(aggro) == "string" and HOSTILE_STATES[aggro] then
        status = "hostile"
    elseif type(aggro) == "string" and ALERT_STATES[aggro] then
        status = "alerted"
    elseif aggro == "passive" or aggro == "dormant" then
        status = "dormant"
    end
    -- These are opportunistic fields; not every Darktide build exposes them.
    local reason = pick(perception, {"trigger_reason", "aggro_reason", "last_anger_reason"})
        or pick(anger, {"trigger_reason", "aggro_reason", "last_anger_reason", "last_anger_source_type"})
        or pick(behavior, {"trigger_reason", "aggro_reason", "last_anger_reason"})
        or pick(board, {"trigger_reason", "aggro_reason"})
    local source = pick(perception, {"trigger_unit", "aggro_source_unit", "last_anger_source_unit"})
        or pick(anger, {"trigger_unit", "aggro_source_unit", "last_anger_source_unit"})
        or pick(behavior, {"trigger_unit", "aggro_source_unit", "last_anger_source_unit"})
        or pick(board, {"trigger_unit", "aggro_source_unit"})
    if not source and (reason == "damage" or reason == "hit") then
        source = pick(anger, {"last_damage_source_unit", "last_damaging_unit"})
            or pick(behavior, {"last_damage_source_unit"})
    elseif not source and (reason == "suppression" or reason == "suppress") then
        source = pick(anger, {"last_suppressing_unit", "last_suppression_source_unit"})
            or pick(behavior, {"last_suppressing_unit"})
    elseif not source and (reason == "flashlight" or reason == "light") then
        source = pick(anger, {"closest_flashing_player_unit", "flashlight_source_unit"})
            or pick(behavior, {"closest_flashing_player_unit"})
    elseif not source and (reason == "distance" or reason == "proximity") then
        source = pick(anger, {"closest_player_unit", "distance_source_unit"})
    end
    -- A Daemonhost may expose a target through replicated MinionPerception
    -- even if the client blackboard does not contain its perception component.
    if not target then
        local managers = rawget(_G, "Managers")
        local game_session = managers and managers.state and managers.state.game_session
        local spawner = managers and managers.state and managers.state.unit_spawner
        local game = call(game_session, "game_session")
        local object_id = call(spawner, "game_object_id", unit)
        local perception_util = MinionPerceptionUtility or rawget(_G, "MinionPerception")
        if game and object_id and perception_util and type(perception_util.target_unit) == "function" then
            local ok, result = pcall(perception_util.target_unit, game, object_id)
            if ok then target = result end
        end
    end
    return status, target, reason, source
end

local function get_host(unit)
    local h = hosts[unit]
    if not h then
        h = {
            last_seen = clock, phase = nil,
            alerted_hit_seq = 0, hit_seq = 0, hit_t = -100,
            sent_awaken = false, sent_hostile = false,
        }
        hosts[unit] = h
    end
    h.last_seen = clock
    return h
end

-- Select a source for the initial harmless awakening. If an explicit source
-- is unavailable, a recent observed player hit is stronger than proximity.
-- Closest-player selection is a last-resort estimate, not authoritative.
local function awakening_trigger(unit, h, fallback_reason, fallback_source)
    local reason = h.alert_reason or fallback_reason
    local source = h.alert_source or fallback_source
    local resolved = resolved_player(source)
    local label = type(reason) == "string" and REASONS[reason] or nil
    if resolved and label then
        return human_name(resolved), label
    end
    if h.hit_unit and clock - h.hit_t <= HIT_WINDOW then
        return human_name(h.hit_unit), "damage"
    end
    local nearest = closest_player(unit)
    if nearest then return human_name(nearest), "proximity" end
    return nil, nil
end

local function send_awaken(unit, h, reason, source)
    if h.sent_awaken then return true end
    local who, cause = awakening_trigger(unit, h, reason, source)
    if not who then return false end
    report(string.format("Daemonhost AWAKENED: %s awakened Daemonhost (%s)", who, cause))
    h.sent_awaken = true
    return true
end

-- Combat attribution is separate from harmless-awakening attribution. An old
-- hit/source used for stage 2 cannot automatically be reused at stage 3.
local function combat_trigger(unit, h, target)
    local reason, source = h.combat_reason, h.combat_source
    local named_source = resolved_player(source)
    local reason_label = type(reason) == "string" and REASONS[reason] or nil
    local stale = h.alert_reason == reason and h.alert_source == source
        and (h.hit_seq or 0) <= (h.alerted_hit_seq or 0)
    if named_source and reason_label and not stale then
        return human_name(named_source), reason_label
    end
    if h.hit_unit and clock - h.hit_t <= HIT_WINDOW
        and (h.hit_seq or 0) > (h.alerted_hit_seq or 0) then
        return human_name(h.hit_unit), "damage"
    end
    local nearest = h.combat_nearest or closest_player(unit)
    if nearest and human_name(nearest) then
        return human_name(nearest), "proximity"
    end
    if target and human_name(target) then
        return human_name(target), "proximity"
    end
    return nil, nil
end

local function send_hostile(unit, h, target, confirmed_attack)
    if h.sent_hostile or not target then return end
    local name = human_name(target)
    if not name then return end
    if not h.sent_awaken and not send_awaken(unit, h, h.combat_reason, h.combat_source) then
        return
    end
    local who, cause = combat_trigger(unit, h, target)
    -- Always use an actual in-game character name from player:name().
    -- Never substitute an invented name such as "Player" or "PlayerB".
    if not who or not cause then return end
    local opening = string.format("Daemonhost HOSTILE: %s triggered Daemonhost (%s)", who, cause)
    if confirmed_attack then
        report(opening .. " • Warped toward and attacking " .. name)
    else
        -- A target alone does not prove that a warp or hit has happened.
        report(opening .. " • Targeting " .. name)
    end
    h.sent_hostile = true
end

-- Gormaggoth spawns hostile; its only chat line names the first observed
-- player it attacks, or the first human target if an attack is not observable.
-- Never send a separate spawn line. Never print a placeholder player name.
local function report_torment_target(h, target)
    if h.torment_report_sent then return end
    local name = human_name(target)
    if not name then return end
    report("Daemonhost Gormaggoth HOSTILE SPAWNED attacking " .. name)
    h.torment_report_sent = true
end

local function observe_torment(unit, target, confirmed_attack)
    local h = get_host(unit)
    if h.torment_report_sent then return end
    -- A confirmed attack overrides any target previously selected in AI state.
    if confirmed_attack and human_name(target) then
        report_torment_target(h, target)
        return
    end
    if not h.torment_target_unit and human_name(target) then
        h.torment_target_unit = target
        h.torment_target_t = clock
    end
    -- Some clients expose target selection but not the attack event itself.
    if h.torment_target_unit
        and clock - (h.torment_target_t or clock) >= TORMENT_TARGET_DELAY then
        report_torment_target(h, h.torment_target_unit)
    end
end

local function mark_combat(unit, h, reason, source, target)
    if h.phase ~= "hostile" then
        h.phase = "hostile"
        h.combat_t = clock
        h.combat_reason, h.combat_source = reason, source
        h.combat_nearest = closest_player(unit)
    elseif not h.sent_hostile and reason and source then
        h.combat_reason, h.combat_source = reason, source
    elseif not h.sent_hostile and reason and not h.combat_reason then
        h.combat_reason = reason
    end
    if target and human_name(target) and not h.target_unit then
        h.target_unit = target
    end
    -- Preserve chronological messages even when we first observe the host
    -- in combat rather than seeing the intermediate alert stage.
    if not h.sent_awaken and clock - h.combat_t >= TRIGGER_DELAY then
        send_awaken(unit, h, h.combat_reason, h.combat_source)
    end
    if clock - h.combat_t < TRIGGER_DELAY then return end
    if h.first_attacked_unit then
        send_hostile(unit, h, h.first_attacked_unit, true)
    elseif h.target_unit and clock - h.combat_t >= FIRST_TARGET_DELAY then
        -- Target assignment alone does not confirm a landed attack or warp.
        send_hostile(unit, h, h.target_unit, false)
    end
end

local function update_host(unit, h, status, target, reason, source)
    if not status then
        if mod:get("diagnostic_logging") and not h.logged_no_status then
            mod:info("IR Daemonhost discovered but client provides no recognized anger state")
            h.logged_no_status = true
        end
        return
    end
    if mod:get("diagnostic_logging") and status ~= h.last_logged_status then
        mod:info("IR Daemonhost stage: %s => %s, target=%s, cause=%s", tostring(h.last_logged_status), tostring(status), tostring(human_name(target)), tostring(reason))
        h.last_logged_status = status
    end
    if status == "dormant" then
        if not h.phase then h.phase = "dormant" end
        return
    end
    if status == "alerted" then
        if h.phase ~= "hostile" then
            if h.phase ~= "alerted" then
                h.alerted_hit_seq = h.hit_seq or 0
                h.alert_reason, h.alert_source = reason, source
            end
            h.phase = "alerted"
            send_awaken(unit, h, reason, source)
        end
        return
    end
    if status == "hostile" then
        mark_combat(unit, h, reason, source, target)
    end
end

local function on_attack_result(_, data)
    if not mod:get("report_daemonhost") or not data then return end
    local victim = data.attacked_unit
    local attacker = data.attacking_unit_owner_unit or data.attacking_unit
    -- Gormaggoth must never go through the ordinary awakening/anger hooks.
    if is_torment(victim) then
        -- Being hit by a player is not evidence of who Gormaggoth targets.
        observe_torment(victim)
        return
    end
    local torment_attacker = is_torment(data.attacking_unit) and data.attacking_unit
        or (is_torment(attacker) and attacker)
    if torment_attacker then
        local target = resolved_player(victim)
        -- A processed attack result proves an attack, not a teleport.
        observe_torment(torment_attacker, target, target ~= nil)
        return
    end
    if is_host(victim) then
        local h = get_host(victim)
        if h.phase ~= "hostile" then
            local unit = resolved_player(attacker)
            if unit then
                h.hit_unit = unit
                h.hit_t = clock
                h.hit_seq = (h.hit_seq or 0) + 1
            end
        end
    elseif is_host(data.attacking_unit) or is_host(attacker) then
        local host = is_host(data.attacking_unit) and data.attacking_unit or attacker
        local target = resolved_player(victim)
        if target then
            local h = get_host(host)
            if not h.first_attacked_unit then h.first_attacked_unit = target end
            -- A real attack establishes combat and the first attack target.
            mark_combat(host, h, h.combat_reason, h.combat_source, target)
        end
    end
end
-- Registered by the single dispatcher in interrogator_randall.lua.
M.on_attack_result = on_attack_result

local function scan()
    local managers = rawget(_G, "Managers")
    local extension = managers and managers.state and managers.state.extension
    local system = call(extension, "system", "unit_data_system")
    -- This method is not available in every client build.
    local unit_map = call(system, "unit_to_extension_map")
    local visited = {}
    if mod:get("diagnostic_logging") and not diag_scan_logged then
        mod:info("IR Daemonhost scanner: unit_map=%s BLACKBOARDS=%s HEALTH_ALIVE=%s", type(unit_map), type(rawget(_G,"BLACKBOARDS")), type(rawget(_G,"HEALTH_ALIVE")))
        diag_scan_logged = true
    end
    local function inspect(unit, data)
        if not unit or visited[unit] then return end
        visited[unit] = true
        local breed = breed_name(unit, data)
        if HOST_BREEDS[breed] and mod:get("diagnostic_logging") and not hosts[unit] then
            mod:info("IR Daemonhost discovered: breed=%s", tostring(breed))
        end
        if breed == TORMENT_BREED then
            local alive = rawget(_G, "ALIVE")
            if not alive or alive[unit] then
                local _, target = host_state(unit)
                observe_torment(unit, target)
            end
        elseif HOST_BREEDS[breed] then
            local h = get_host(unit)
            local status, target, reason, source = host_state(unit)
            update_host(unit, h, status, target, reason, source)
        end
    end
    if type(unit_map) == "table" then
        for unit, data in pairs(unit_map) do inspect(unit, data) end
    end
    local boards = rawget(_G, "BLACKBOARDS")
    if type(boards) == "table" then
        for unit in pairs(boards) do inspect(unit) end
    end
    -- Fallback discovery when an AI does not expose BLACKBOARDS on clients.
    -- Throttled to one pass per second to avoid scanning every alive unit at 6fps.
    if fallback_clock >= 1 then
        fallback_clock = 0
        local health_alive = rawget(_G, "HEALTH_ALIVE")
        if type(health_alive) == "table" then
            for unit, alive in pairs(health_alive) do
                if alive and not visited[unit] then inspect(unit) end
            end
        end
    end
    for unit, h in pairs(hosts) do
        if clock - h.last_seen > HOST_EXPIRATION then hosts[unit] = nil end
    end
end
function M.update(dt)
    if type(mod._reporting_enabled) ~= "function" or
        not mod._reporting_enabled("report_daemonhost") then
        M.reset()
        return
    end
    clock = clock + (dt or 0)
    scan_clock = scan_clock + (dt or 0)
    fallback_clock = fallback_clock + (dt or 0)
    local scan_interval = next(hosts) and SCAN_INTERVAL_ACTIVE or SCAN_INTERVAL_IDLE
    if scan_clock >= scan_interval then
        scan_clock = scan_clock % scan_interval
        scan()
    end
    -- Flush attack events even if a scanner doesn't see the host's unit map.
    for unit, h in pairs(hosts) do
        if h.phase == "hostile" and not h.sent_hostile then
            mark_combat(unit, h, h.combat_reason, h.combat_source, h.target_unit)
        end
    end
end
function M.reset()
    hosts = {}
    clock, scan_clock, fallback_clock = 0, 0, 0
    diag_scan_logged = false
end
M._host_state = host_state
M._update_host = update_host
M._get_host = get_host
M._combat_trigger = combat_trigger
M._awakening_trigger = awakening_trigger
M._observe_torment = observe_torment
return M
