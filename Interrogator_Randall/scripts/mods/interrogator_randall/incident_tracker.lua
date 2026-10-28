-- Interrogator Randall: explosion tracking adapted from uploaded barrels.lua
local mod = get_mod("interrogator_randall")
local reports = mod._chat_reports() -- Provided by main before this file is loaded.
local AttackSettings = require("scripts/settings/damage/attack_settings")
local AttackingUnitResolver = require("scripts/utilities/attack/attacking_unit_resolver")
local Damage = require("scripts/utilities/attack/damage")
local PlayerUnitStatus = require("scripts/utilities/attack/player_unit_status")
local attack_results = AttackSettings.attack_results

local QUIET_DELAY = 0.85
local FIRE_QUIET_DELAY = 1.6
local BLAST_MAX_AGE = 4
local FIRE_MAX_AGE = 12
local CATAPULT_WINDOW = 12
local CATAPULT_REPORT_DELAY = 1.65
local POX_DEATH_MATCH_WINDOW = 2.5
local POX_DEATH_MATCH_RADIUS_SQ = 100
local MATCH_RADIUS_SQ = 64
local INCIDENT_MATCH_RADIUS_SQ = 400
local INCIDENT_MERGE_WINDOW = 6

local BARREL_EXPLOSION_PROFILES = {
barrel_explosion = true,
barrel_explosion_close = true,
fire_barrel_explosion = true,
fire_barrel_explosion_close = true,
promethium_barrel_explosion = true,
promethium_barrel_explosion_close = true,
}

local function is_pox_explosion(name)
    return type(name) == "string" and name:find("^poxwalker_explosion") ~= nil
end

local BARREL_FIRE_PROFILES = {
liquid_area_fire_burning_barrel = true,
}

local OFF_NAVMESH_PROFILES = {
kill_volume_and_off_navmesh = true,
falling_light = true,
falling_heavy = true,
}

local barrel_owner_by_unit = {}
local barrel_state_seen = {}
local active_incidents = {}
local source_incident_ids = {}
local recent_player_barrel_impacts = {}
local incident_id = 0
local pox_owner_by_unit = {}
local recent_pox_deaths = {}
-- Accumulate per-incident damage only once, after duplicate incidents are merged.
-- Source names are best-effort from the existing owner tracking; unknown stays
-- unattributed. The end summary is independent of the live chat toggles.
-- Keep previous category states to clear disabled caches only once, not
-- every update frame while the other explosion category stays enabled.
local barrel_was_tracking = false
local pox_was_tracking = false
local mission_totals = {}
local function barrel_summary_on()
    return mod:get("report_end_barrel_summary") ~= false or
        mod:get("report_end_barrel_team_total") ~= false
end
local function poxburster_summary_on()
    return mod:get("report_end_poxburster_summary") ~= false or
        mod:get("report_end_poxburster_team_total") ~= false
end
local function summary_on(kind)
    if kind == "poxburster" then return poxburster_summary_on() end
    return barrel_summary_on()
end
local function track_barrels()
    return mod:get("report_barrels") ~= false or barrel_summary_on()
end
local function track_poxbursters()
    return mod:get("report_poxbursters") ~= false or poxburster_summary_on()
end
local function empty_totals()
    return { hp = 0, toughness = 0, sources = {} }
end
local function reset_mission_totals()
    mission_totals = { barrel = empty_totals(), poxburster = empty_totals() }
end
reset_mission_totals()

local function main_time()
if Managers.time then
return Managers.time:time("main")
end
return Application.time_since_launch()
end

local function colour_for_type(t)
if t == "explosive_fire_barrel" then return Color.ui_red_light(255, true) end
if t == "explosive_explosion_barrel" then return Color.citadel_dorn_yellow(255, true) end
return Color.citadel_jokaero_orange(255, true)
end

local function player_from_unit(unit)
local player_unit_spawn = Managers.state and Managers.state.player_unit_spawn
return player_unit_spawn and unit and player_unit_spawn:owner(unit) or nil
end

local function resolved_player_unit(unit)
if not unit or not ALIVE[unit] then
return nil
end
local resolved_unit = AttackingUnitResolver.resolve(unit)
if resolved_unit and ALIVE[resolved_unit] and player_from_unit(resolved_unit) then
return resolved_unit
end
if player_from_unit(unit) then
return unit
end
return nil
end

local function strip_rich_text_tags(text)
if not text then
return nil
end
text = text:gsub("{#.-}", "")
text = text:gsub("\r", "")
text = text:gsub("\n", " ")
text = text:gsub("%[", "(")
text = text:gsub("%]", ")")
return text
end

local function safe_player_name(player)
return player and strip_rich_text_tags(player:name()) or nil
end

local function player_name_from_unit(unit)
local resolved_unit = resolved_player_unit(unit) or unit
local player = player_from_unit(resolved_unit)
return safe_player_name(player)
end

local function broadcast_incident(message, incident)
    -- Unlike mod:echo, the mission channel is visible to everyone.
    local category = incident and incident.btype == "poxburster"
        and "report_poxbursters" or "report_barrels"
    reports:queue_incident(message, category)
end

local function barrel_type_from_profile(name)
if not name then return "explosive_common" end
if name == "liquid_area_fire_burning_barrel" then return "explosive_fire_barrel" end
if name:find("promethium_barrel") or name:find("fire_barrel") then return "explosive_fire_barrel" end
if name:find("barrel_explosion") then return "explosive_explosion_barrel" end
return "explosive_common"
end

local function barrel_type_from_content(content)
if content == "fire" then return "explosive_fire_barrel" end
if content == "explosion" or content == "gas" then return "explosive_explosion_barrel" end
return "explosive_common"
end

local function barrel_name_from_type(t)
return t == "poxburster" and "Poxburster" or mod:localize(t)
end

local function source_position(unit)
if not unit then return nil end
-- Dying minions may no longer be ALIVE by the time their damage reports arrive.
local cached = POSITION_LOOKUP and POSITION_LOOKUP[unit]
if cached then return cached end
if ALIVE[unit] then
    if Unit.has_node(unit, "c_explosion") then
        return Unit.world_position(unit, Unit.node(unit, "c_explosion"))
    end
    return Unit.world_position(unit, 1)
end
end

-- Darktide positions may be Vector3 OR Vector3Box userdata.  The old
-- Vector3Box(pos) at create_incident() crashed on a boxed POSITION_LOOKUP entry.
-- Never permit a bad position to interrupt the damage/chat hook.
local function vector_from_box(value)
    if value == nil then return nil end
    local ok_method, unbox = pcall(function() return value.unbox end)
    if ok_method and type(unbox) == "function" then
        local ok, pos = pcall(unbox, value)
        if ok and pos then return pos end
    end
    return value
end

local function safe_position_box(value)
    if not value then return nil end
    local pos = vector_from_box(value)
    local ok, box = pcall(Vector3Box, pos)
    return ok and box or nil
end

local function safe_distance_squared(a, b)
    if not a or not b then return nil end
    local va, vb = vector_from_box(a), vector_from_box(b)
    local ok, dist = pcall(Vector3.distance_squared, va, vb)
    if ok and type(dist) == "number" then return dist end
    return nil
end

local function reset_state()
barrel_owner_by_unit = {}
barrel_state_seen = {}
active_incidents = {}
source_incident_ids = {}
recent_player_barrel_impacts = {}
incident_id = 0
    pox_owner_by_unit = {}
    recent_pox_deaths = {}
    barrel_was_tracking = false
    pox_was_tracking = false
    reset_mission_totals()
end

local function update_barrel_owner_meta(unit, btype, attacker_unit)
local owner_player_unit = resolved_player_unit(attacker_unit)
local owner_name = player_name_from_unit(owner_player_unit or attacker_unit)
local meta = barrel_owner_by_unit[unit] or {
btype = btype,
barrel_name = barrel_name_from_type(btype),
colour = colour_for_type(btype),
}
meta.btype = btype or meta.btype or "explosive_common"
meta.barrel_name = barrel_name_from_type(meta.btype)
meta.colour = colour_for_type(meta.btype)
meta.last_hit_t = main_time()
if owner_name then
if not meta.igniter_name then
meta.igniter_name = owner_name
meta.igniter_unit = owner_player_unit
end
meta.detonator_name = owner_name
meta.detonator_unit = owner_player_unit
meta.owner_name = owner_name
meta.owner_unit = owner_player_unit
end
barrel_owner_by_unit[unit] = meta
return meta
end

local function sync_incident_owner_meta(unit)
local id = unit and source_incident_ids[unit]
local incident = id and active_incidents[id]
local meta = unit and barrel_owner_by_unit[unit]
if not incident or not meta then
return
end
incident.btype = meta.btype or incident.btype
incident.barrel_name = meta.barrel_name or incident.barrel_name
incident.colour = meta.colour or incident.colour
incident.igniter_name = meta.igniter_name or incident.igniter_name
incident.igniter_unit = meta.igniter_unit or incident.igniter_unit
incident.detonator_name = meta.detonator_name or incident.detonator_name
incident.detonator_unit = meta.detonator_unit or incident.detonator_unit
incident.owner_name = incident.detonator_name or incident.owner_name
incident.owner_unit = incident.detonator_unit or incident.owner_unit
end

local function create_incident(source_unit, source_pos, btype, igniter_unit, igniter_name, detonator_unit, detonator_name)
incident_id = incident_id + 1
local started_t = main_time()
local incident = {
id = incident_id,
source_unit = source_unit,
source_position = safe_position_box(source_pos),
btype = btype,
barrel_name = barrel_name_from_type(btype),
colour = colour_for_type(btype),
igniter_unit = igniter_unit,
igniter_name = igniter_name,
detonator_unit = detonator_unit,
detonator_name = detonator_name or igniter_name,
owner_unit = detonator_unit or igniter_unit,
owner_name = detonator_name or igniter_name,
started_t = started_t,
last_event_t = started_t,
quiet_delay = btype == "explosive_fire_barrel" and FIRE_QUIET_DELAY or QUIET_DELAY,
max_age = btype == "explosive_fire_barrel" and FIRE_MAX_AGE or BLAST_MAX_AGE,
enemy_blast_kills = 0,
enemy_fire_kills = 0,
enemy_blast_ids = {},
enemy_fire_ids = {},
player_blast_damage = {},
player_fire_damage = {},
player_blast_toughness_damage = {},
player_fire_toughness_damage = {},
summary_player_toughness_damage = {},
player_blast_toughness_broken = {},
player_fire_toughness_broken = {},
player_blast_downs = {},
player_fire_downs = {},
player_blast_kills = {},
player_fire_kills = {},
player_catapults = {},
player_catapult_kills = {},
}
active_incidents[incident.id] = incident
if source_unit then
source_incident_ids[source_unit] = incident.id
end
return incident
end

local function get_or_create_barrel_incident(unit)
    if not track_barrels() then return nil end
local existing_id = source_incident_ids[unit]
if existing_id and active_incidents[existing_id] then
return active_incidents[existing_id]
end
local meta = barrel_owner_by_unit[unit] or {
btype = "explosive_common",
barrel_name = barrel_name_from_type("explosive_common"),
colour = colour_for_type("explosive_common"),
owner_name = "Someone",
}
local position = source_position(unit)
return create_incident(unit, position, meta.btype or "explosive_common", meta.igniter_unit, meta.igniter_name, meta.detonator_unit, meta.detonator_name)
end

local function nearest_incident_by_position(position, btype)
if not position then return nil end
local best_incident, best_distance_sq
for _, incident in pairs(active_incidents) do
if incident.btype == btype and incident.source_position then
local distance_sq = safe_distance_squared(position, incident.source_position)
if distance_sq and distance_sq <= MATCH_RADIUS_SQ and (not best_distance_sq or distance_sq < best_distance_sq) then
best_incident = incident
best_distance_sq = distance_sq
end
end
end
return best_incident
end

local function same_name(a, b)
return not a or not b or a == b
end

local function incident_detail_score(incident)
local score = incident.enemy_blast_kills + incident.enemy_fire_kills
local groups = {
incident.player_blast_damage,
incident.player_fire_damage,
incident.player_blast_toughness_damage,
incident.player_fire_toughness_damage,
incident.player_blast_toughness_broken,
incident.player_fire_toughness_broken,
incident.player_blast_downs,
incident.player_fire_downs,
incident.player_blast_kills,
incident.player_fire_kills,
incident.player_catapults,
incident.player_catapult_kills,
}
for i = 1, #groups do
for _ in pairs(groups[i]) do
score = score + 1
end
end
return score
end

local function incidents_are_compatible(a, b)
if not a or not b or a.id == b.id or a.btype ~= b.btype or a.btype == "poxburster" then
return false
end
if math.abs((a.started_t or 0) - (b.started_t or 0)) > INCIDENT_MERGE_WINDOW then
return false
end
if not same_name(a.owner_name, b.owner_name) then
return false
end
if not same_name(a.igniter_name, b.igniter_name) then
return false
end
if not same_name(a.detonator_name, b.detonator_name) then
return false
end
if a.source_position and b.source_position then
local distance_sq = safe_distance_squared(a.source_position, b.source_position)
if distance_sq and distance_sq > INCIDENT_MATCH_RADIUS_SQ then
return false
end
end
return true
end

local function merge_number_maps(dst, src)
for name, amount in pairs(src) do
dst[name] = (dst[name] or 0) + amount
end
end

local function merge_bool_maps(dst, src)
for name in pairs(src) do
dst[name] = true
end
end

local function merge_incident_into(dst, src)
if not dst or not src or dst.id == src.id then
return dst
end
if not dst.source_unit and src.source_unit then
dst.source_unit = src.source_unit
end
if not dst.source_position and src.source_position then
dst.source_position = safe_position_box(src.source_position)
end
if not dst.igniter_name and src.igniter_name then
dst.igniter_name = src.igniter_name
dst.igniter_unit = src.igniter_unit
end
if not dst.detonator_name and src.detonator_name then
dst.detonator_name = src.detonator_name
dst.detonator_unit = src.detonator_unit
end
if not dst.owner_name and src.owner_name then
dst.owner_name = src.owner_name
end
if not dst.owner_unit and src.owner_unit then
dst.owner_unit = src.owner_unit
end
dst.started_t = math.min(dst.started_t or 0, src.started_t or 0)
dst.last_event_t = math.max(dst.last_event_t or 0, src.last_event_t or 0)
dst.quiet_delay = math.max(dst.quiet_delay or QUIET_DELAY, src.quiet_delay or QUIET_DELAY)
dst.max_age = math.max(dst.max_age or BLAST_MAX_AGE, src.max_age or BLAST_MAX_AGE)
dst.enemy_blast_kills = (dst.enemy_blast_kills or 0) + (src.enemy_blast_kills or 0)
dst.enemy_fire_kills = (dst.enemy_fire_kills or 0) + (src.enemy_fire_kills or 0)
merge_bool_maps(dst.enemy_blast_ids, src.enemy_blast_ids)
merge_bool_maps(dst.enemy_fire_ids, src.enemy_fire_ids)
merge_number_maps(dst.player_blast_damage, src.player_blast_damage)
merge_number_maps(dst.player_fire_damage, src.player_fire_damage)
merge_number_maps(dst.player_blast_toughness_damage, src.player_blast_toughness_damage)
merge_number_maps(dst.player_fire_toughness_damage, src.player_fire_toughness_damage)
merge_number_maps(dst.summary_player_toughness_damage, src.summary_player_toughness_damage)
merge_bool_maps(dst.player_blast_toughness_broken, src.player_blast_toughness_broken)
merge_bool_maps(dst.player_fire_toughness_broken, src.player_fire_toughness_broken)
merge_bool_maps(dst.player_blast_downs, src.player_blast_downs)
merge_bool_maps(dst.player_fire_downs, src.player_fire_downs)
merge_bool_maps(dst.player_blast_kills, src.player_blast_kills)
merge_bool_maps(dst.player_fire_kills, src.player_fire_kills)
merge_bool_maps(dst.player_catapults, src.player_catapults)
merge_bool_maps(dst.player_catapult_kills, src.player_catapult_kills)
for unit, recent in pairs(recent_player_barrel_impacts) do
if recent.incident_id == src.id then
recent.incident_id = dst.id
end
end
if src.source_unit and source_incident_ids[src.source_unit] == src.id then
source_incident_ids[src.source_unit] = dst.id
end
active_incidents[src.id] = nil
return dst
end

local function find_merge_candidate(position, btype, owner_name)
local best_incident, best_score, best_t
local now = main_time()
for _, incident in pairs(active_incidents) do
if incident.btype == btype and (not owner_name or same_name(incident.owner_name, owner_name) or same_name(incident.detonator_name, owner_name) or same_name(incident.igniter_name, owner_name)) then
if now - (incident.started_t or now) <= INCIDENT_MERGE_WINDOW then
local score = incident_detail_score(incident)
local valid_position = true
if position and incident.source_position then
local d = safe_distance_squared(position, incident.source_position)
valid_position = d ~= nil and d <= INCIDENT_MATCH_RADIUS_SQ
end
if valid_position and (not best_incident or score > best_score or (score == best_score and (incident.started_t or 0) > best_t)) then
best_incident = incident
best_score = score
best_t = incident.started_t or 0
end
end
end
end
return best_incident
end

local function merge_duplicate_incidents()
local changed = true
while changed do
changed = false
local incidents = {}
for _, incident in pairs(active_incidents) do
incidents[#incidents + 1] = incident
end
for i = 1, #incidents do
local a = incidents[i]
if a and active_incidents[a.id] then
for j = i + 1, #incidents do
local b = incidents[j]
if b and active_incidents[b.id] and incidents_are_compatible(a, b) then
local a_score = incident_detail_score(a)
local b_score = incident_detail_score(b)
if b_score > a_score or (b_score == a_score and (b.started_t or 0) < (a.started_t or 0)) then
merge_incident_into(b, a)
a = b
else
merge_incident_into(a, b)
end
changed = true
break
end
end
end
if changed then
break
end
end
end
end

local function create_ad_hoc_incident(buffer_data, btype)
local attacker = buffer_data.attacking_unit
local owner_unit = resolved_player_unit(attacker)
local position = vector_from_box(buffer_data.hit_world_position)
local owner_name = player_name_from_unit(owner_unit or attacker) or "Someone"
local candidate = find_merge_candidate(position, btype, owner_name)
if candidate then
candidate.last_event_t = main_time()
if owner_unit then
candidate.igniter_unit = candidate.igniter_unit or owner_unit
candidate.igniter_name = candidate.igniter_name or owner_name
candidate.detonator_unit = candidate.detonator_unit or owner_unit
candidate.detonator_name = candidate.detonator_name or owner_name
candidate.owner_unit = candidate.owner_unit or owner_unit
candidate.owner_name = candidate.owner_name or owner_name
end
return candidate
end
return create_incident(nil, position, btype, owner_unit, owner_name, owner_unit, owner_name)
end



local function is_poxburster_unit(unit)
    if not unit then return false end
    local ext = ScriptUnit.has_extension(unit, "unit_data_system")
    if not ext or type(ext.breed) ~= "function" then return false end
    local ok, breed = pcall(ext.breed, ext)
    -- Current Darktide breed is chaos_poxwalker_bomber.
    return ok and breed and (breed.name == "chaos_poxwalker_bomber"
        or breed.name == "poxwalker_bomber") or false
end

local function register_pox_death(buffer_data)
    if not track_poxbursters() then return end
    local victim = buffer_data.attacked_unit
    if not is_poxburster_unit(victim) or buffer_data.attack_result ~= attack_results.died then
        return
    end
    local profile = buffer_data.damage_profile
    local profile_name = profile and profile.name or ""
    local killer = resolved_player_unit(buffer_data.attacking_unit)
    -- Credit players only for confirmed lethal attacks, not the natural self-destruct
    -- and not a blast hitting another Poxburster in a chain reaction.
    local player_killed = killer and not is_pox_explosion(profile_name)
        and not profile_name:find("instakill")
    local name = player_killed and player_name_from_unit(killer) or nil
    local position = source_position(victim) or vector_from_box(buffer_data.hit_world_position)
    local now = main_time()
    recent_pox_deaths[#recent_pox_deaths + 1] = {
        unit = victim, position = safe_position_box(position),
        name = name, owner = name and killer or nil, t = now,
    }
    if name then
        pox_owner_by_unit[victim] = { name = name, unit = killer, t = now }
        local id = source_incident_ids[victim]
        local incident = id and active_incidents[id]
        if incident then
            incident.owner_name = name
            incident.owner_unit = killer
            incident.detonator_name = name
            incident.detonator_unit = killer
        end
    end
end

local function recent_pox_at(position)
    if not position then return nil end
    local now = main_time()
    local best, best_sq, ambiguous
    for _, death in ipairs(recent_pox_deaths) do
        if now - death.t <= POX_DEATH_MATCH_WINDOW and death.position then
            local dsq = safe_distance_squared(position, death.position)
            if dsq and dsq <= POX_DEATH_MATCH_RADIUS_SQ then
                if not best or dsq < best_sq then
                    ambiguous = best ~= nil and math.abs(dsq - best_sq) < 4
                    best, best_sq = death, dsq
                elseif math.abs(dsq - best_sq) < 4 then
                    ambiguous = true
                end
            end
        end
    end
    return not ambiguous and best or nil
end

local function pox_incident(buffer_data)
    if not track_poxbursters() then return nil end
    local unit = buffer_data.attacking_unit
    local direct_id = unit and source_incident_ids[unit]
    if direct_id and active_incidents[direct_id] then
        return active_incidents[direct_id]
    end
    local impact = vector_from_box(buffer_data.hit_world_position)
    local direct_pox = unit and (is_poxburster_unit(unit) or pox_owner_by_unit[unit])
    local death = direct_pox and nil or recent_pox_at(impact)
    if death then unit = death.unit end
    -- The Beast of Nurgle death explosion uses the SAME damage profile.
    -- Never classify that as a Poxburster without confirmed minion evidence.
    if not direct_pox and not death then
        local previous = nearest_incident_by_position(impact, "poxburster")
        if previous and main_time() - previous.started_t < 1.5 then
            return previous
        end
        return nil
    end
    local existing_id = unit and source_incident_ids[unit]
    if existing_id and active_incidents[existing_id] then
        return active_incidents[existing_id]
    end
    local owner = unit and pox_owner_by_unit[unit]
    -- A dying Poxburster's position is likely cached only, so retain impact fallback.
    local position = unit and source_position(unit) or impact
    local incident = create_incident(unit, position, "poxburster", nil, nil,
        owner and owner.unit or (death and death.owner),
        owner and owner.name or (death and death.name))
    return incident
end

local function match_incident(buffer_data, profile_name)
if is_pox_explosion(profile_name) then
    return pox_incident(buffer_data)
end
if not track_barrels() then return nil end
local btype = barrel_type_from_profile(profile_name)
local attacker = buffer_data.attacking_unit
local direct_id = attacker and source_incident_ids[attacker]
if direct_id and active_incidents[direct_id] then
return active_incidents[direct_id]
end
local hit_position = vector_from_box(buffer_data.hit_world_position)
local by_position = nearest_incident_by_position(hit_position, btype)
if by_position then
return by_position
end
if BARREL_EXPLOSION_PROFILES[profile_name] and player_from_unit(attacker) then
return create_ad_hoc_incident(buffer_data, btype)
end
return nil
end

local function unit_key(unit)
return unit or false
end

local function sorted_keys(tbl)
local keys = {}
for key in pairs(tbl) do
keys[#keys + 1] = key
end
table.sort(keys)
return keys
end

local function record_player_damage(targets, incident, player_name, damage)
if not player_name or damage <= 0 then return end
targets[player_name] = (targets[player_name] or 0) + damage
incident.last_event_t = main_time()
end

local function record_player_toughness_damage(targets, broken_targets, incident, player_name, damage, broke)
if not player_name or damage <= 0 then return end
if broke then
broken_targets[player_name] = true
targets[player_name] = nil
else
targets[player_name] = (targets[player_name] or 0) + damage
end
incident.last_event_t = main_time()
end

local function record_named_event(targets, incident, player_name)
if not player_name then return end
targets[player_name] = true
incident.last_event_t = main_time()
end

local function record_enemy_kill(incident, target_unit, phase)
if not target_unit then
if phase == "fire" then
incident.enemy_fire_kills = incident.enemy_fire_kills + 1
else
incident.enemy_blast_kills = incident.enemy_blast_kills + 1
end
incident.last_event_t = main_time()
return
end
local ids = phase == "fire" and incident.enemy_fire_ids or incident.enemy_blast_ids
local key = unit_key(target_unit)
if ids[key] then return end
ids[key] = true
if phase == "fire" then
incident.enemy_fire_kills = incident.enemy_fire_kills + 1
else
incident.enemy_blast_kills = incident.enemy_blast_kills + 1
end
incident.last_event_t = main_time()
end

local function remember_barrel_impact(incident, attacked_unit)
-- Report the initial blast promptly, but retain an independent record for
-- delayed ledge deaths that happen AFTER the incident's first chat message.
incident.quiet_delay = math.max(incident.quiet_delay, CATAPULT_REPORT_DELAY)
local old = recent_player_barrel_impacts[attacked_unit]
recent_player_barrel_impacts[attacked_unit] = {
incident_id = incident.id,
t = main_time(),
catapult_reported = old and old.catapult_reported or false,
was_catapulted = old and old.was_catapulted or false,
death_reported = old and old.death_reported or false,
victim_name = player_name_from_unit(attacked_unit),
owner_name = incident.owner_name,
barrel_name = incident.barrel_name,
btype = incident.btype,
}
end

local function record_catapult_death(buffer_data)
local attacked_unit = buffer_data and buffer_data.attacked_unit
local recent = attacked_unit and recent_player_barrel_impacts[attacked_unit]
if not recent or recent.death_reported or main_time() - recent.t > CATAPULT_WINDOW then
    return
end
local incident = active_incidents[recent.incident_id]
local player_name = recent.victim_name or player_name_from_unit(attacked_unit)
if not player_name then return end
if incident then
    if incident.player_catapult_kills[player_name] then return end
    incident.player_catapults[player_name] = nil
    incident.player_catapult_kills[player_name] = true
    incident.last_event_t = main_time()
else
    -- The original barrel message has already been sent. A supplemental death
    -- message is preferable to holding EVERY blast report for 12 seconds.
    local source = recent.owner_name or "A barrel"
    local label = recent.barrel_name or "barrel"
    local message = string.format("%s likely catapulted %s to their death with %s", source, player_name, label)
    reports:queue_incident(message,
        recent.btype == "poxburster" and "report_poxbursters" or "report_barrels")
end
recent.death_reported = true
recent.catapult_reported = true
if mod:get("diagnostic_logging") then
    mod:info("IR Barrel ledge death: victim=%s owner=%s after=%.1fs", player_name,
        tostring(recent.owner_name), main_time() - recent.t)
end
end

local function join_names(names)
local count = #names
if count == 0 then
return ""
end
if count == 1 then
return names[1]
end
if count == 2 then
return names[1] .. " and " .. names[2]
end
return table.concat(names, ", ", 1, count - 1) .. ", and " .. names[count]
end

local function grouped_target_phrase(targets, singular_verb, plural_verb)
if #targets == 0 then
return nil
end
if #targets == 1 then
return targets[1] .. " " .. singular_verb
end
return join_names(targets) .. " " .. plural_verb
end

local function format_grouped_catapults(incident, target_map, death)
local targets = {}
for _, name in ipairs(sorted_keys(target_map)) do
if incident.owner_unit and player_name_from_unit(incident.owner_unit) == name then
targets[#targets + 1] = "themselves"
else
targets[#targets + 1] = name
end
end
if #targets == 0 then
return nil
end
local owner_name = incident.owner_name
if owner_name then
local action = death and "likely catapulted" or "catapulted"
local suffix = death and (#targets == 1 and " to their death" or " to their deaths") or ""
return string.format("%s %s %s%s", owner_name, action, join_names(targets), suffix)
end
return grouped_target_phrase(targets, death and "was likely catapulted to their death" or "was catapulted", death and "were likely catapulted to their deaths" or "were catapulted")
end

local function incident_headline(incident)
    if incident.btype == "poxburster" then
        if incident.owner_name then
            return string.format("%s detonated a Poxburster", incident.owner_name)
        end
        return "Poxburster self-detonated"
    end
local igniter_name = incident.igniter_name
local detonator_name = incident.detonator_name or incident.owner_name
local headline
if igniter_name and detonator_name then
if igniter_name == detonator_name then
headline = string.format("%s ignited & detonated %s", detonator_name, incident.barrel_name)
else
headline = string.format("%s ignited & %s detonated %s", igniter_name, detonator_name, incident.barrel_name)
end
elseif detonator_name then
headline = string.format("%s detonated %s", detonator_name, incident.barrel_name)
elseif igniter_name then
headline = string.format("%s ignited %s", igniter_name, incident.barrel_name)
else
headline = string.format("%s detonated (trigger unknown)", incident.barrel_name)
end
local total_enemy_kills = incident.enemy_blast_kills + incident.enemy_fire_kills
if total_enemy_kills > 0 then
headline = string.format("%s killing %d enem%s", headline, total_enemy_kills, total_enemy_kills == 1 and "y" or "ies")
end
return headline
end

local function record_catapult(incident, attacked_unit)
local recent = attacked_unit and recent_player_barrel_impacts[attacked_unit]
if not recent or recent.incident_id ~= incident.id or recent.catapult_reported then
return
end
local player_name = player_name_from_unit(attacked_unit)
if not player_name or incident.player_catapults[player_name] or incident.player_catapult_kills[player_name] then
return
end
incident.player_catapults[player_name] = true
recent.catapult_reported = true
recent.was_catapulted = true
incident.last_event_t = main_time()
end

local function has_player_effects(incident)
    local groups = {
        incident.player_blast_damage, incident.player_fire_damage,
        incident.player_blast_toughness_damage, incident.player_fire_toughness_damage,
        incident.player_blast_toughness_broken, incident.player_fire_toughness_broken,
        incident.player_blast_downs, incident.player_fire_downs,
        incident.player_blast_kills, incident.player_fire_kills,
        incident.player_catapults, incident.player_catapult_kills,
    }
    for _, group in ipairs(groups) do
        if next(group) then return true end
    end
    return false
end

local function accumulate_incident_summary(incident)
    if not summary_on(incident.btype) or incident.summary_counted then return end
    incident.summary_counted = true
    local kind = incident.btype == "poxburster" and "poxburster" or "barrel"
    local bucket = mission_totals[kind]
    if not bucket then return end
    -- The existing trigger detection can establish a player who hit a barrel
    -- or killed a Poxburster. If absent, do not invent a culprit.
    local cause = incident.detonator_name or incident.owner_name
    if cause == "Someone" or cause == "Unknown" or cause == "" then
        cause = nil
    end
    local source = cause or "Unattributed"
    local hp_map = {}
    for name, damage in pairs(incident.player_blast_damage) do
        hp_map[name] = (hp_map[name] or 0) + damage
    end
    for name, damage in pairs(incident.player_fire_damage) do
        hp_map[name] = (hp_map[name] or 0) + damage
    end
    local victims = {}
    for name in pairs(hp_map) do victims[name] = true end
    for name in pairs(incident.summary_player_toughness_damage) do victims[name] = true end
    for name in pairs(victims) do
        -- Do not call damage dealt to the detonator "damage to teammates".
        if not cause or name ~= cause then
            local hp = math.max(0, hp_map[name] or 0)
            local toughness = math.max(0, incident.summary_player_toughness_damage[name] or 0)
            if hp > 0 or toughness > 0 then
                bucket.hp = bucket.hp + hp
                bucket.toughness = bucket.toughness + toughness
                local row = bucket.sources[source]
                if not row then
                    row = { name = source, hp = 0, toughness = 0 }
                    bucket.sources[source] = row
                end
                row.hp = row.hp + hp
                row.toughness = row.toughness + toughness
            end
        end
    end
end

local function explosion_summary_rows()
    local rows = {}
    for _, category in ipairs({ "barrel", "poxburster" }) do
        if summary_on(category) then
        local bucket = mission_totals[category]
        local label = category == "barrel" and "Barrels" or "Poxbursters"
        local setting_id = category == "barrel"
            and "report_end_barrel_summary" or "report_end_poxburster_summary"
        local team_id = category == "barrel"
            and "report_end_barrel_team_total" or "report_end_poxburster_team_total"
        local hp, toughness = math.floor(bucket.hp + 0.5), math.floor(bucket.toughness + 0.5)
        if mod:get(team_id) ~= false then
            rows[#rows + 1] = { body = string.format(
                "%s TOTAL: %d HP + %d Toughness damage to players (self excluded when known)",
                label, hp, toughness), category = team_id }
        end
        if mod:get(setting_id) ~= false then
        local sources = {}
        for _, record in pairs(bucket.sources) do sources[#sources + 1] = record end
        table.sort(sources, function(a, b)
            local damage_a = a.hp + a.toughness
            local damage_b = b.hp + b.toughness
            if damage_a ~= damage_b then return damage_a > damage_b end
            return a.name < b.name
        end)
        for _, record in ipairs(sources) do
            local hp_done = math.floor(record.hp + 0.5)
            local toughness_done = math.floor(record.toughness + 0.5)
            local body
            if category == "poxburster" and record.name == "Unattributed" then
                -- A Poxburster detonates itself, but the killer / initiator may
                -- not be visible to this client. Do not claim a proven suicide.
                body = string.format(
                    "Poxbursters: Self-detonations dealt %d HP + %d Toughness damage to players",
                    hp_done, toughness_done)
            else
                local verb = record.name == "Unattributed" and "Unattributed" or record.name .. " caused"
                body = string.format(
                    "%s: %s %d HP + %d Toughness damage to players",
                    label, verb, hp_done, toughness_done)
            end
            rows[#rows + 1] = { body = body, category = setting_id }
        end
        end -- player breakdown enabled
        end -- a team total or player breakdown is enabled for this category
    end
    return rows
end

local function finalise_incident(incident)
    accumulate_incident_summary(incident)
    local enabled = incident.btype == "poxburster"
        and mod:get("report_poxbursters") or
        (incident.btype ~= "poxburster" and mod:get("report_barrels"))
    local useful = has_player_effects(incident) or mod:get("report_harmless_explosions")
    if not enabled or not useful then
        -- Clear suppressed incidents too, or they will be evaluated every frame.
        active_incidents[incident.id] = nil
        if incident.source_unit and source_incident_ids[incident.source_unit] == incident.id then
            source_incident_ids[incident.source_unit] = nil
        end
        return
    end
local parts = {}
if mod:get("report_toughness") then
for _, name in ipairs(sorted_keys(incident.player_blast_toughness_broken)) do
parts[#parts + 1] = string.format("Broke %s’s Toughness", name)
end
for _, name in ipairs(sorted_keys(incident.player_fire_toughness_broken)) do
parts[#parts + 1] = string.format("Barrel fire broke %s’s Toughness", name)
end
for _, name in ipairs(sorted_keys(incident.player_blast_toughness_damage)) do
parts[#parts + 1] = string.format("Dealt %d toughness damage to %s", math.floor(incident.player_blast_toughness_damage[name] + 0.5), name)
end
for _, name in ipairs(sorted_keys(incident.player_fire_toughness_damage)) do
parts[#parts + 1] = string.format("Barrel fire dealt %d toughness damage to %s", math.floor(incident.player_fire_toughness_damage[name] + 0.5), name)
end
end -- report_toughness
local catapults = format_grouped_catapults(incident, incident.player_catapults, false)
if catapults then
parts[#parts + 1] = catapults
end
for _, name in ipairs(sorted_keys(incident.player_blast_damage)) do
parts[#parts + 1] = string.format("Hurt %s by %d hp", name, math.floor(incident.player_blast_damage[name] + 0.5))
end
for _, name in ipairs(sorted_keys(incident.player_fire_damage)) do
parts[#parts + 1] = string.format("Barrel fire hurt %s by %d hp", name, math.floor(incident.player_fire_damage[name] + 0.5))
end
local blast_downs = sorted_keys(incident.player_blast_downs)
if #blast_downs > 0 then
parts[#parts + 1] = string.format("Downed %s", join_names(blast_downs))
end
local fire_downs = sorted_keys(incident.player_fire_downs)
if #fire_downs > 0 then
parts[#parts + 1] = string.format("Barrel fire downed %s", join_names(fire_downs))
end
local blast_kills = sorted_keys(incident.player_blast_kills)
if #blast_kills > 0 then
parts[#parts + 1] = string.format("Killed %s", join_names(blast_kills))
end
local fire_kills = sorted_keys(incident.player_fire_kills)
if #fire_kills > 0 then
parts[#parts + 1] = string.format("Barrel fire killed %s", join_names(fire_kills))
end
local catapult_kills = format_grouped_catapults(incident, incident.player_catapult_kills, true)
if catapult_kills then
parts[#parts + 1] = catapult_kills
end
local headline = incident_headline(incident)
-- Keep individual messages below common chat length limits. Split only between
-- independently meaningful sections, never in the middle of a name or word.
local MAX_CHAT_LENGTH = 210
local line = headline
for _, part in ipairs(parts) do
    if #line + #part + 3 > MAX_CHAT_LENGTH then
        broadcast_incident(line, incident)
        line = "[Incident] " .. part
    else
        line = line .. " • " .. part
    end
end
broadcast_incident(line, incident)
active_incidents[incident.id] = nil
if incident.source_unit and source_incident_ids[incident.source_unit] == incident.id then
source_incident_ids[incident.source_unit] = nil
end
end

mod:hook_safe("HazardPropExtension", "add_damage", function(self, damage_amount, hit_actor, attack_direction, attacking_unit)
if not track_barrels() then return end
local unit = self._unit
local btype = barrel_type_from_content(self._content)
local meta = update_barrel_owner_meta(unit, btype, attacking_unit)
if meta.detonator_name then
sync_incident_owner_meta(unit)
end
end)

mod:hook_safe("HazardPropExtension", "set_current_state", function(self, state)
if not track_barrels() then return end
local unit = self._unit
if state == "idle" then
barrel_state_seen[unit] = nil
return
end
local current = barrel_state_seen[unit]
local meta = barrel_owner_by_unit[unit]
local btype = meta and meta.btype or barrel_type_from_content(self._content)
if not meta then
meta = {
owner_name = nil,
owner_unit = nil,
btype = btype,
barrel_name = barrel_name_from_type(btype),
colour = colour_for_type(btype),
}
barrel_owner_by_unit[unit] = meta
end
if state == "triggered" and current ~= "triggered" then
barrel_state_seen[unit] = "triggered"
elseif state == "broken" and current ~= "broken" then
get_or_create_barrel_incident(unit)
sync_incident_owner_meta(unit)
barrel_state_seen[unit] = "broken"
end
end)

mod:hook(Damage, "deal_damage", function(func, unit, breed_or_nil, attacking_unit, attacking_unit_owner_unit, attack_result, attack_type, damage_profile, damage, permanent_damage, tougness_damage, hit_actor, attack_direction, hit_zone_name, herding_template_or_nil, is_critical_strike, damage_type, hit_world_position_or_nil, wounds_shape_or_nil, instakill, damage_absorbed)
if (not track_barrels()) and (not track_poxbursters()) then
    return func(unit, breed_or_nil, attacking_unit, attacking_unit_owner_unit, attack_result, attack_type, damage_profile, damage, permanent_damage, tougness_damage, hit_actor, attack_direction, hit_zone_name, herding_template_or_nil, is_critical_strike, damage_type, hit_world_position_or_nil, wounds_shape_or_nil, instakill, damage_absorbed)
end
local hazard_prop_extension = track_barrels()
    and ScriptUnit.has_extension(unit, "hazard_prop_system")
if hazard_prop_extension then
local btype = barrel_type_from_content(hazard_prop_extension._content)
local meta = update_barrel_owner_meta(unit, btype, attacking_unit_owner_unit or attacking_unit)
if meta.detonator_name then
sync_incident_owner_meta(unit)
end
end
local actual_damage_dealt = func(unit, breed_or_nil, attacking_unit, attacking_unit_owner_unit, attack_result, attack_type, damage_profile, damage, permanent_damage, tougness_damage, hit_actor, attack_direction, hit_zone_name, herding_template_or_nil, is_critical_strike, damage_type, hit_world_position_or_nil, wounds_shape_or_nil, instakill, damage_absorbed)
local profile_name = damage_profile and damage_profile.name
if not profile_name or damage ~= 0 or permanent_damage ~= 0 or not tougness_damage or tougness_damage <= 0 then
return actual_damage_dealt
end
local phase
if BARREL_EXPLOSION_PROFILES[profile_name] or is_pox_explosion(profile_name) then
phase = "blast"
elseif BARREL_FIRE_PROFILES[profile_name] then
phase = "fire"
else
return actual_damage_dealt
end
local player = player_from_unit(unit)
if not player then
return actual_damage_dealt
end
local incident = match_incident({attacking_unit = attacking_unit, attacked_unit = unit, hit_world_position = hit_world_position_or_nil}, profile_name)
if not incident then
return actual_damage_dealt
end
local player_name = safe_player_name(player)
local broke = attack_result == attack_results.toughness_broken
if phase == "blast" then
record_player_toughness_damage(incident.player_blast_toughness_damage, incident.player_blast_toughness_broken, incident, player_name, tougness_damage, broke)
record_player_damage(incident.summary_player_toughness_damage, incident, player_name, tougness_damage)
remember_barrel_impact(incident, unit)
else
record_player_toughness_damage(incident.player_fire_toughness_damage, incident.player_fire_toughness_broken, incident, player_name, tougness_damage, broke)
record_player_damage(incident.summary_player_toughness_damage, incident, player_name, tougness_damage)
end
return actual_damage_dealt
end)

local function on_attack_result(self, buffer_data)
-- Track only a confirmed human killing blow to the Poxburster.
register_pox_death(buffer_data)
local attacked_unit = buffer_data.attacked_unit
local hazard_prop_extension = track_barrels()
    and ScriptUnit.has_extension(attacked_unit, "hazard_prop_system")
if hazard_prop_extension then
local profile_name = buffer_data.damage_profile and buffer_data.damage_profile.name
local btype = barrel_type_from_content(hazard_prop_extension._content)
local meta = update_barrel_owner_meta(attacked_unit, btype, buffer_data.attacking_unit)
if meta.detonator_name then
sync_incident_owner_meta(attacked_unit)
end
end
local damage_profile = buffer_data.damage_profile
local profile_name = damage_profile and damage_profile.name
if not profile_name then
return
end
if OFF_NAVMESH_PROFILES[profile_name] and buffer_data.attack_result == attack_results.died then
record_catapult_death(buffer_data)
return
end
if buffer_data.attack_result == attack_results.died then
    local recent = recent_player_barrel_impacts[buffer_data.attacked_unit]
    if recent and recent.was_catapulted then
        record_catapult_death(buffer_data)
    end
end
local phase
if BARREL_EXPLOSION_PROFILES[profile_name] or is_pox_explosion(profile_name) then
phase = "blast"
elseif BARREL_FIRE_PROFILES[profile_name] then
phase = "fire"
else
return
end
local incident = match_incident(buffer_data, profile_name)
if not incident then
return
end
incident.last_event_t = main_time()
local owner_unit = resolved_player_unit(buffer_data.attacking_unit)
if owner_unit and incident.btype ~= "poxburster" then
incident.detonator_unit = incident.detonator_unit or owner_unit
incident.detonator_name = incident.detonator_name or player_name_from_unit(owner_unit) or incident.detonator_name
incident.owner_unit = incident.detonator_unit or incident.owner_unit
incident.owner_name = incident.detonator_name or incident.owner_name
end
local attacked_unit = buffer_data.attacked_unit
local player = player_from_unit(attacked_unit)
if player then
local player_name = safe_player_name(player)
if phase == "blast" then
record_player_damage(incident.player_blast_damage, incident, player_name, buffer_data.damage or 0)
remember_barrel_impact(incident, attacked_unit)
if buffer_data.attack_result == attack_results.knock_down then
record_named_event(incident.player_blast_downs, incident, player_name)
elseif buffer_data.attack_result == attack_results.died then
record_named_event(incident.player_blast_kills, incident, player_name)
end
else
record_player_damage(incident.player_fire_damage, incident, player_name, buffer_data.damage or 0)
if buffer_data.attack_result == attack_results.knock_down then
record_named_event(incident.player_fire_downs, incident, player_name)
elseif buffer_data.attack_result == attack_results.died then
record_named_event(incident.player_fire_kills, incident, player_name)
end
end
elseif buffer_data.attack_result == attack_results.died then
record_enemy_kill(incident, attacked_unit, phase)
end
end

local function update_incidents(dt)
local t = main_time()
local barrels_active = track_barrels()
local pox_active = track_poxbursters()
for id, incident in pairs(active_incidents) do
    -- Do not use the and/or fallback here: when Poxburster tracking is
    -- disabled but Barrel tracking is enabled, it would wrongly retain Poxbursters.
    local tracking
    if incident.btype == "poxburster" then
        tracking = pox_active
    else
        tracking = barrels_active
    end
    if not tracking then
        if incident.source_unit and source_incident_ids[incident.source_unit] == id then
            source_incident_ids[incident.source_unit] = nil
        end
        active_incidents[id] = nil
    end
end
-- Only discard a disabled category's metadata on an ON-to-OFF change.
-- Reallocating these tables each frame could create significant GC churn
-- when Poxbursters are enabled but Barrels are disabled (or vice versa).
if not barrels_active and barrel_was_tracking then
    barrel_owner_by_unit, barrel_state_seen = {}, {}
end
if not pox_active and pox_was_tracking then
    pox_owner_by_unit, recent_pox_deaths = {}, {}
end
barrel_was_tracking = barrels_active
pox_was_tracking = pox_active
-- Drop stale Poxburster death attribution rather than holding dead units.
for i = #recent_pox_deaths, 1, -1 do
    if t - recent_pox_deaths[i].t > POX_DEATH_MATCH_WINDOW then
        local death = recent_pox_deaths[i]
        pox_owner_by_unit[death.unit] = nil
        table.remove(recent_pox_deaths, i)
    end
end
for player_unit, recent in pairs(recent_player_barrel_impacts) do
    local alive = ALIVE and ALIVE[player_unit]
    local health_alive = HEALTH_ALIVE and HEALTH_ALIVE[player_unit]
    local health = alive and ScriptUnit.has_extension(player_unit, "health_system")
    local dead_by_extension = false
    if health and type(health.is_dead) == "function" then
        local ok, dead = pcall(health.is_dead, health)
        dead_by_extension = ok and dead == true
    end
    if (dead_by_extension or health_alive == false) and recent.was_catapulted then
        record_catapult_death({ attacked_unit = player_unit })
    end
    if t - recent.t > CATAPULT_WINDOW or recent.death_reported then
        recent_player_barrel_impacts[player_unit] = nil
    elseif alive then
        local incident = active_incidents[recent.incident_id]
        local unit_data_extension = ScriptUnit.has_extension(player_unit, "unit_data_system")
        local character_state_component = unit_data_extension and unit_data_extension:read_component("character_state")
        if character_state_component and PlayerUnitStatus.is_catapulted(character_state_component) then
            recent.was_catapulted = true
            if incident and not recent.catapult_reported then
                record_catapult(incident, player_unit)
            end
        end
    end
end
local to_finalise = {}
merge_duplicate_incidents()
for id, incident in pairs(active_incidents) do
local quiet_elapsed = t - incident.last_event_t
local total_elapsed = t - incident.started_t
if quiet_elapsed >= (incident.quiet_delay or QUIET_DELAY) or total_elapsed >= incident.max_age then
to_finalise[#to_finalise + 1] = id
end
end
for i = 1, #to_finalise do
local incident = active_incidents[to_finalise[i]]
if incident then
finalise_incident(incident)
end
end
end

local function flush_mission_summary()
    if not (barrel_summary_on() or poxburster_summary_on()) then return end
    merge_duplicate_incidents()
    for _, incident in pairs(active_incidents) do
        -- No need to send an unfinished incident into live chat on exit.
        accumulate_incident_summary(incident)
    end
end

return {
    reset = reset_state,
    update = update_incidents,
    on_attack_result = on_attack_result,
    flush_mission_summary = flush_mission_summary,
    summary_rows = explosion_summary_rows,
}
