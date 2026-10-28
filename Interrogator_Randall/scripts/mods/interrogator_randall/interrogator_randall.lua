local mod = get_mod("interrogator_randall")
local Ammo = require("scripts/utilities/ammo")
local Pickups = require("scripts/settings/pickup/pickups")
local InteractionSettings = require("scripts/settings/interaction/interaction_settings")
local AmmoTracker = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/ammo_tracker")
local GrenadeTracker = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/grenade_tracker")
local ChatReports = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/chat_reports")
local HealingSummary = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/healing_summary")

local INTERACTION_TIMEOUT = 5
local ROSTER_INTERVAL = 1
local SUPPORTED = {
    small_clip = true,
    large_clip = true,
    ammo_cache_deployable = true,
}
local PICKUP_BY_DESCRIPTION = {
    loc_pickup_consumable_small_clip_01 = "small_clip",
    loc_pickup_consumable_large_clip_01 = "large_clip",
    loc_pickup_deployable_ammo_crate_01 = "ammo_cache_deployable",
}
local interaction_results = InteractionSettings.results

local clock = 0
local roster_elapsed = ROSTER_INTERVAL
local mission_marker = nil
local pending = {}
local grenade_pending = {}
local stats_by_id = {}
local grenade_stats_by_id = {}
local ammo_team = {total_offered=0,total_wasted=0,pickup_count=0}
local grenade_team = {total_offered=0,total_wasted=0,pickup_count=0}
local reports = ChatReports.new()
local healing_summary = HealingSummary.new()
function mod._healing_summary() return healing_summary end
-- The incidents module needs access to the same mission-chat queue.
function mod._chat_reports() return reports end
local IncidentTracker = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/incident_tracker")
local MedicaeTracker = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/medicae_tracker")
local MedStimmTracker = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/med_stimm_tracker")
local DaemonhostTracker = mod:io_dofile("interrogator_randall/scripts/mods/interrogator_randall/daemonhost_tracker")
local phase = "idle"
local carry_to_score = false
local summary_sent = false
-- Tracks whether a category was active at the previous update. This allows
-- clearing its state once on disable without running dormant trackers.
local enabled_trackers = {}

-- DMF still invokes update callbacks when a toggleable mod is disabled.
-- Keep a separate, fail-closed state driven by the documented lifecycle
-- callbacks rather than trusting hook state or is_enabled() alone.
local lifecycle_active = false
function mod._reporting_enabled(category)
    if not lifecycle_active then return false end
    if type(mod.is_enabled) == "function" and not mod:is_enabled() then
        return false
    end
    return not category or mod:get(category) ~= false
end

local function safe_method(object, method_name, ...)
    local method = object and object[method_name]

    if type(method) ~= "function" then
        return nil
    end

    local ok, value = pcall(method, object, ...)

    return ok and value or nil
end

local function safe_field(object, field_name)
    local ok, value = pcall(function()
        return object and object[field_name]
    end)

    return ok and value or nil
end

local function is_human(player)
    return safe_method(player, "is_human_controlled") == true
end

local function player_name(player)
    local name = safe_method(player, "name")

    return name and tostring(name) or "Unknown"
end

local function player_id(player)
    local account_id = safe_method(player, "account_id")

    if account_id and account_id ~= "" and account_id ~= "no_account_id" then
        return tostring(account_id)
    end

    local peer_id = safe_method(player, "peer_id") or "unknown_peer"
    local local_player_id = safe_method(player, "local_player_id") or 1

    return tostring(peer_id) .. ":" .. tostring(local_player_id)
end

local function ensure_stats(player)
    if not is_human(player) then
        return nil, nil
    end

    local id = player_id(player)
    local name = player_name(player)
    local stats = stats_by_id[id]

    if not stats then
        stats = AmmoTracker.new_stats(id, name)
        stats_by_id[id] = stats
    else
        stats.player_name = name
    end

    return stats, id
end

local function clear_pending_for_player(id)
    for target, record in pairs(pending) do
        if record.player_id == id then pending[target] = nil end
    end
    for target, record in pairs(grenade_pending) do
        if record.player_id == id then grenade_pending[target] = nil end
    end
end

local function reset_state()
    clock = 0
    roster_elapsed = ROSTER_INTERVAL
    pending = {}
    grenade_pending = {}
    stats_by_id = {}
    grenade_stats_by_id = {}
    ammo_team = {total_offered=0,total_wasted=0,pickup_count=0}
    grenade_team = {total_offered=0,total_wasted=0,pickup_count=0}
    reports:reset()
    healing_summary:reset()
    IncidentTracker.reset()
    MedicaeTracker.reset()
    MedStimmTracker.reset()
    DaemonhostTracker.reset()
    carry_to_score = false
    summary_sent = false
    enabled_trackers = {}
end

local function mission_context()
    local managers = rawget(_G, "Managers")
    local state = managers and managers.state
    local current_marker = state and state.player_unit_spawn

    if not current_marker then
        if phase == "awaiting_score" or phase == "score" then
            return nil
        end

        if mission_marker ~= nil or next(stats_by_id) ~= nil or next(grenade_stats_by_id) ~= nil then
            reset_state()
        end

        mission_marker = nil
        phase = "idle"

        return nil
    end

    if current_marker ~= mission_marker then
        reset_state()
        mission_marker = current_marker
        phase = "mission"
    end

    return state
end

local function reconcile_roster()
    local managers = rawget(_G, "Managers")
    local player_manager = managers and managers.player
    local players = safe_method(player_manager, "players")

    if not players then
        return
    end

    local present = {}

    for _, player in pairs(players) do
        if is_human(player) then
            local _, id = ensure_stats(player)
            present[id] = true
        end
    end

    for id in pairs(stats_by_id) do
        if not present[id] then
            stats_by_id[id] = nil
            clear_pending_for_player(id)
        end
    end
end

local function cleanup_pending()
    for target, record in pairs(pending) do
        if clock >= record.expires_at then pending[target] = nil end
    end
    for target, record in pairs(grenade_pending) do
        if clock >= record.expires_at then grenade_pending[target] = nil end
    end
end

local function player_for_unit(unit)
    local managers = rawget(_G, "Managers")
    local spawn = managers and managers.state and managers.state.player_unit_spawn
    local player = safe_method(spawn, "owner", unit)

    if player then
        return player
    end

    local player_manager = managers and managers.player
    player = safe_method(player_manager, "player_by_unit", unit)

    if player then
        return player
    end

    local players = safe_method(player_manager, "players") or {}

    for _, candidate in pairs(players) do
        if safe_field(candidate, "player_unit") == unit then
            return candidate
        end
    end
end

local function pickup_name(target)
    if not target then
        return nil
    end

    local ok, name = pcall(Unit.get_data, target, "pickup_type")

    return ok and name or nil
end

local function snapshot_ammo(unit, id, name)
    local unit_data = ScriptUnit.has_extension(unit, "unit_data_system")

    if not unit_data then
        return nil
    end

    local component = safe_method(unit_data, "read_component", "slot_secondary")
    local max_reserve = component and component.max_ammunition_reserve or 0

    if max_reserve <= 0 then
        return nil
    end

    return {
        player_id = id,
        player_name = name,
        slots = {
            {
                reserve = component.current_ammunition_reserve or 0,
                max_reserve = max_reserve,
                clip = Ammo.current_ammo_in_clips(component),
                max_clip = Ammo.max_ammo_in_clips(component),
            },
        },
    }
end

local function ammo_modifier()
    local managers = rawget(_G, "Managers")
    local difficulty = managers and managers.state and managers.state.difficulty

    return safe_method(difficulty, "get_ammo_modifier") or 1
end

local function ammo_tracking_enabled()
    return mod:get("report_ammo") ~= false or mod:get("report_end_ammo_summary") ~= false
        or mod:get("report_end_ammo_team_total") ~= false
end

local function grenade_tracking_enabled()
    return mod:get("report_grenades") ~= false or
        mod:get("report_end_grenade_summary") ~= false or
        mod:get("report_end_grenade_team_total") ~= false
end

local function grenade_snapshot(unit)
    if not unit or not ScriptUnit then return nil end
    local ok, ext = pcall(ScriptUnit.has_extension, unit, "ability_system")
    if not ok or not ext then return nil end
    -- An interactable grenade box already verifies the target has an equipped
    -- grenade ability. Clients can briefly report ability_is_equipped=false
    -- while charges have replicated; prefer the actual charge numbers here.
    local maximum = safe_method(ext,"max_ability_charges","grenade_ability")
    local current = safe_method(ext,"remaining_ability_charges","grenade_ability")
    if type(maximum) ~= "number" or type(current) ~= "number" or maximum <= 0 then return nil end
    return { current=current, maximum=maximum }
end

-- An interaction of type "grenade" is a real world pickup. Some maps do not
-- replicate the Unit.pickup_type field early enough for the started callback.
-- Use the verified interaction type, not just the optional unit metadata.
local function capture_grenade_start(extension, interactor, interaction)
    if not grenade_tracking_enabled() or not mission_context() then return end
    if interaction ~= "grenade" then return end
    local target = safe_field(extension, "_unit")
    if not target then return end
    -- The interaction-start hook can fire repeatedly before a single pickup
    -- finishes. Keep the FIRST valid charge snapshot and avoid needless
    -- player, pickup, and ability lookups for duplicate callbacks. A brief
    -- 0.4s window also allows a real retry to take a new snapshot.
    local previous = grenade_pending[target]
    if previous and previous.interactor == interactor
        and clock - previous.armed_at >= 0
        and clock - previous.armed_at < 0.4 then
        return
    end
    local pickup = pickup_name(target)
    local diagnostic = mod:get("diagnostic_logging")
    if diagnostic then
        mod:info("IR Grenade start: type=%s pickup=%s interactor=%s",
            tostring(interaction), tostring(pickup), tostring(interactor ~= nil))
    end
    -- GrenadeInteraction is specifically the small grenade charge-refill
    -- interaction in the game's pickup templates. Never infer this from a
    -- generic pocketable grenade weapon or talent-generated refill.
    if pickup ~= nil and pickup ~= "small_grenade" then
        if diagnostic then mod:info("IR Grenade skipped: unexpected pickup %s", tostring(pickup)) end
        return
    end
    if not interactor then
        if diagnostic then mod:info("IR Grenade skipped: no interactor") end
        return
    end
    local player = player_for_unit(interactor)
    if not is_human(player) then
        if diagnostic then mod:info("IR Grenade skipped: no human owner") end
        return
    end
    local before = grenade_snapshot(interactor)
    local pickup_data = Pickups.by_name.small_grenade
    if not before or not pickup_data then
        if diagnostic then
            mod:info("IR Grenade skipped: snapshot=%s pickup_settings=%s",
                tostring(before ~= nil), tostring(pickup_data ~= nil))
        end
        return
    end
    local id = player_id(player)
    grenade_pending[target] = {player_id=id, player_name=player_name(player),
        interactor=interactor, armed_at=clock,
        before=before, offered=tonumber(pickup_data.charges_restored) or 0,
        expires_at=clock+INTERACTION_TIMEOUT}
    if diagnostic then
        mod:info("IR Grenade armed: %s before=%.1f/%.1f budget=%.1f",
            player_name(player),before.current,before.maximum,
            tonumber(pickup_data.charges_restored) or 0)
    end
end

local function finish_grenade_interaction(extension, result)
    local target=safe_field(extension,"_unit")
    local record=target and grenade_pending[target]
    local diagnostic=mod:get("diagnostic_logging")
    if not record then
        if diagnostic and safe_method(extension,"interaction_type")=="grenade" then
            mod:info("IR Grenade stop without start: result=%s",tostring(result))
        end
        return
    end
    grenade_pending[target]=nil
    if not grenade_tracking_enabled() or result ~= interaction_results.success
        or clock >= record.expires_at then
        if diagnostic then mod:info("IR Grenade discarded: result=%s timeout=%s",tostring(result),tostring(clock >= record.expires_at)) end
        return
    end
    local event=GrenadeTracker.calculate(record.before.current,record.before.maximum,record.offered)
    if not event then
        if diagnostic then mod:info("IR Grenade discarded: invalid calculation") end
        return
    end
    local stats=grenade_stats_by_id[record.player_id]
    if not stats then
        stats=GrenadeTracker.new_stats(record.player_id,record.player_name)
        grenade_stats_by_id[record.player_id]=stats
    end
    stats.player_name=record.player_name
    GrenadeTracker.apply(stats,event)
    GrenadeTracker.apply(grenade_team,event)
    if mod:get("report_grenades") ~= false then
        local threshold=tonumber(mod:get("minimum_grenade_waste_to_report")) or 50
        if event.waste_percent>=threshold then
            reports:queue_incident(string.format(
                "%s took Grenade Pickup at %d%% capacity (%d%% wasted)",
                record.player_name,event.before_percent,event.display_waste_percent),"report_grenades")
        end
    end
    if diagnostic then
        mod:info("IR Grenade pickup: %s before=%.2f/%.2f offered=%.2f waste=%.1f%%",
            record.player_name,event.current,event.maximum,event.offered,event.waste_percent)
    end
end

local function capture_start(extension, interactor)
    local interaction = safe_method(extension, "interaction_type")
    if interaction == "grenade" then
        return capture_grenade_start(extension, interactor, interaction)
    end
    if interaction ~= "ammunition" or not ammo_tracking_enabled() then return end
    if not mission_context() then
        return
    end

    local target = safe_field(extension, "_unit")
    local contexts = safe_field(extension, "_override_contexts")
    local ammunition_context = safe_field(contexts, "ammunition")
    local description = safe_field(ammunition_context, "description")
    local name = PICKUP_BY_DESCRIPTION[description] or pickup_name(target)

    if not target or not interactor or not SUPPORTED[name] then
        return
    end

    local player = player_for_unit(interactor)

    if not is_human(player) then
        return
    end

    local stats, id = ensure_stats(player)
    local snapshot = snapshot_ammo(interactor, id, stats.player_name)
    local pickup_data = Pickups.by_name[name]

    if not snapshot or not pickup_data then
        return
    end

    pending[target] = {
        interactor = interactor,
        player_id = id,
        player_name = stats.player_name,
        snapshot = snapshot,
        pickup_data = pickup_data,
        modifier = ammo_modifier(),
        expires_at = clock + INTERACTION_TIMEOUT,
    }
end

local function finish_interaction(extension, result)
    finish_grenade_interaction(extension, result)
    local target = safe_field(extension, "_unit")
    local record = target and pending[target]

    if not record then
        return
    end

    pending[target] = nil

    if not ammo_tracking_enabled() then return end
    if result ~= interaction_results.success
        or clock >= record.expires_at
    then
        return
    end

    local stats = stats_by_id[record.player_id]

    if not stats then
        return
    end

    local result = AmmoTracker.calculate(
        record.snapshot,
        record.pickup_data,
        record.modifier
    )

    if not result then
        return
    end

    AmmoTracker.apply(stats, result)
    AmmoTracker.apply(ammo_team, result)

    local threshold = mod:get("minimum_waste_to_report") or 50

    if mod:get("report_ammo") ~= false and result.waste_percent >= threshold then
        mod._on_pickup_report(result, stats.player_name)
    end
end

function mod._on_pickup_report(result, name)
    if mod:get("report_ammo") == false then return end
    reports:queue_pickup(
        name,
        result.pickup_name,
        result.display_ammo_percent,
        result.display_waste_percent
    )
end

function mod._stats_by_id()
    return stats_by_id
end

function mod._chat_reports()
    return reports
end

function mod.update(dt)
    -- DMF update events may continue after hooks are disabled. The explicit
    -- lifecycle flag prevents hidden scans, tracking, and outbound messages.
    if not mod._reporting_enabled() then return end
    dt = dt or 0
    -- Reset unused trackers only on an ON-to-OFF transition, not every
    -- single frame (which formerly allocated new empty Lua tables repeatedly).
    local ammo_on = ammo_tracking_enabled()
    if not ammo_on and enabled_trackers.ammo then
        pending = {}
        stats_by_id = {}
        ammo_team = {total_offered=0,total_wasted=0,pickup_count=0}
    end
    enabled_trackers.ammo = ammo_on

    local grenade_on=grenade_tracking_enabled()
    if not grenade_on and enabled_trackers.grenades then
        grenade_pending={}
        grenade_stats_by_id={}
        grenade_team = {total_offered=0,total_wasted=0,pickup_count=0}
    end
    enabled_trackers.grenades=grenade_on

    reports:update(dt)

    local barrels_on = mod:get("report_barrels") ~= false
        or mod:get("report_end_barrel_summary") ~= false
        or mod:get("report_end_barrel_team_total") ~= false
    local pox_on = mod:get("report_poxbursters") ~= false
        or mod:get("report_end_poxburster_summary") ~= false
        or mod:get("report_end_poxburster_team_total") ~= false
    local incidents_on = barrels_on or pox_on
    if incidents_on then
        IncidentTracker.update(dt)
    elseif enabled_trackers.incidents then
        IncidentTracker.reset()
    end
    enabled_trackers.incidents = incidents_on

    local medicae_on = mod:get("report_medicae") ~= false
        or mod:get("report_end_medicae_summary") ~= false
        or mod:get("report_end_medicae_team_total") ~= false
    if medicae_on then
        MedicaeTracker.update(dt)
    elseif enabled_trackers.medicae then
        MedicaeTracker.reset()
    end
    enabled_trackers.medicae = medicae_on

    local stimm_on = mod:get("report_med_stimm") ~= false
        or mod:get("report_end_med_stimm_summary") ~= false
        or mod:get("report_end_med_stimm_team_total") ~= false
    if stimm_on then
        MedStimmTracker.update(dt)
    elseif enabled_trackers.med_stimm then
        MedStimmTracker.reset()
    end
    enabled_trackers.med_stimm = stimm_on

    local daemonhost_on = mod:get("report_daemonhost") ~= false
    if daemonhost_on then
        DaemonhostTracker.update(dt)
    elseif enabled_trackers.daemonhost then
        DaemonhostTracker.reset()
    end
    enabled_trackers.daemonhost = daemonhost_on

    if phase == "awaiting_score" or phase == "score" then
        return
    end

    if not mission_context() then
        return
    end

    clock = clock + dt
    roster_elapsed = roster_elapsed + dt
    cleanup_pending()

    if roster_elapsed >= ROSTER_INTERVAL then
        roster_elapsed = roster_elapsed % ROSTER_INTERVAL
        if ammo_on then
            reconcile_roster()
        end
    end
end

function mod.on_enabled(initial_call)
    -- DMF guarantees on_enabled for toggleable mods that are active.
    -- An installation that starts disabled never activates by accident.
    lifecycle_active = true
    if mod:get("diagnostic_logging") then
        mod:info("IR lifecycle ENABLED: scanner and reports allowed (initial=%s)",
            tostring(initial_call))
    end
end

function mod.on_disabled(initial_call)
    -- Clear the flag BEFORE reset and before any queued sender may run.
    lifecycle_active = false
    if mod:get("diagnostic_logging") then
        mod:info("IR lifecycle DISABLED: scanner and reports blocked (initial=%s)",
            tostring(initial_call))
    end
    reset_state()
    mission_marker = nil
    phase = "idle"
end

function mod.on_unload()
    lifecycle_active = false
    reset_state()
    mission_marker = nil
    phase = "idle"
end

local function end_result()
    local managers = rawget(_G, "Managers")
    local mechanism = managers and managers.mechanism

    return safe_method(mechanism, "end_result")
end

local function completed_result(result)
    return result == "won" or result == "lost"
end

local function start_mission()
    reset_state()
    local managers = rawget(_G, "Managers")
    mission_marker = managers
        and managers.state
        and managers.state.player_unit_spawn
        or nil
    phase = "mission"
    reconcile_roster()
end

local function leave_mission()
    if completed_result(end_result()) then
        pending = {}
        -- Settle any recently confirmed Med Stimm use before building results.
        MedStimmTracker.flush_all()
        IncidentTracker.flush_mission_summary()
        carry_to_score = true
        phase = "awaiting_score"
    else
        reset_state()
        mission_marker = nil
        phase = "idle"
    end
end

local function build_summary_rows()
    reconcile_roster()

    local managers = rawget(_G, "Managers")
    local player_manager = managers and managers.player
    local players = safe_method(player_manager, "players") or {}
    local rows = {}

    for _, player in pairs(players) do
        if is_human(player) then
            local stats, id = ensure_stats(player)
            local percent = AmmoTracker.summary_percent(stats)

            if percent ~= nil then
                rows[#rows + 1] = {
                    name = stats.player_name,
                    percent = percent,
                    slot = safe_method(player, "slot") or math.huge,
                    player_id = id,
                }
            end
        end
    end

    table.sort(rows, function(left, right)
        if left.percent ~= right.percent then
            return left.percent > right.percent
        end

        if left.slot ~= right.slot then
            return left.slot < right.slot
        end

        return left.player_id < right.player_id
    end)

    return rows
end

local function build_grenade_summary_rows()
    local rows={}
    for id,stats in pairs(grenade_stats_by_id) do
        local percent=GrenadeTracker.summary_percent(stats)
        if percent~=nil then
            rows[#rows+1]={name=stats.player_name,percent=percent,
                count=stats.pickup_count,id=id}
        end
    end
    table.sort(rows,function(a,b)
        if a.percent~=b.percent then return a.percent>b.percent end
        return a.id<b.id
    end)
    return rows
end

local function enter_score()
    local result = end_result()
    phase = "score"

    if not carry_to_score or summary_sent or not completed_result(result) then
        return
    end

    if mod:get("report_end_ammo_team_total") ~= false then
        reports:queue_ammo_team_total(ammo_team)
    end
    if mod:get("report_end_ammo_summary") ~= false then
        reports:queue_summary(build_summary_rows())
    end
    if mod:get("report_end_grenade_team_total") ~= false then
        reports:queue_grenade_team_total(grenade_team)
    end
    if mod:get("report_end_grenade_summary") ~= false then
        reports:queue_grenade_summary(build_grenade_summary_rows())
    end
    if mod:get("report_end_barrel_summary") ~= false or
        mod:get("report_end_poxburster_summary") ~= false or
        mod:get("report_end_barrel_team_total") ~= false or
        mod:get("report_end_poxburster_team_total") ~= false then
        reports:queue_explosion_summary(IncidentTracker.summary_rows())
    end
    if mod:get("report_end_medicae_summary") ~= false or
        mod:get("report_end_med_stimm_summary") ~= false or
        mod:get("report_end_medicae_team_total") ~= false or
        mod:get("report_end_med_stimm_team_total") ~= false then
        reports:queue_healing_summary(healing_summary:rows(
            mod:get("report_end_medicae_summary") ~= false,
            mod:get("report_end_med_stimm_summary") ~= false,
            mod:get("report_end_medicae_team_total") ~= false,
            mod:get("report_end_med_stimm_team_total") ~= false))
    end
    carry_to_score = false
    summary_sent = true
end

local function leave_score()
    reset_state()
    mission_marker = nil
    phase = "idle"
end

mod:hook_require(
    "scripts/game_states/game/gameplay_sub_states/gameplay_state_run",
    function(instance)
        mod:hook(
            instance,
            "on_enter",
            function(func, self, ...)
                func(self, ...)
                start_mission()
            end
        )

        mod:hook(
            instance,
            "on_exit",
            function(func, self, ...)
                leave_mission()

                return func(self, ...)
            end
        )
    end
)

mod:hook_require(
    "scripts/game_states/game/state_game_score",
    function(instance)
        mod:hook(
            instance,
            "on_enter",
            function(func, self, ...)
                func(self, ...)
                enter_score()
            end
        )

        mod:hook(
            instance,
            "on_exit",
            function(func, self, ...)
                local result = func(self, ...)
                leave_score()

                return result
            end
        )
    end
)

local function report_tracking_error(stage, err)
    local logger = mod and mod.error

    if type(logger) == "function" then
        pcall(
            logger,
            mod,
            "Ammo %s tracking failed: %s",
            stage,
            tostring(err)
        )
    end
end

-- hook_require can run more than once for an unchanged InteracteeExtension
-- class during DMF initialization. Register the wrappers only once per class.
-- Weak keys avoid keeping classes alive across game script reloads.
local hooked_interactee_classes = setmetatable({}, { __mode = "k" })
mod:hook_require(
    "scripts/extension_systems/interaction/interactee_extension",
    function(instance)
        if hooked_interactee_classes[instance] then return end
        if type(instance.started) ~= "function" or type(instance.stopped) ~= "function" then return end
        hooked_interactee_classes[instance] = true
        mod:hook(
            instance,
            "started",
            function(func, self, ...)
                if not mod._reporting_enabled() then return func(self, ...) end
                local ok, err = pcall(
                    capture_start,
                    self,
                    select(1, ...)
                )

                if not ok then
                    report_tracking_error("start", err)
                end

                local ok_med, err_med = pcall(MedicaeTracker.on_started, self, select(1, ...))
                if not ok_med then
                    mod:error("Medicae start callback: %s", tostring(err_med))
                end
                return func(self, ...)
            end
        )

        mod:hook(
            instance,
            "stopped",
            function(func, self, ...)
                if not mod._reporting_enabled() then return func(self, ...) end
                local ok, err = pcall(
                    finish_interaction,
                    self,
                    select(1, ...)
                )

                if not ok then
                    report_tracking_error("stop", err)
                end

                local ok_med, err_med = pcall(MedicaeTracker.on_stopped, self, select(1, ...), select(2, ...))
                if not ok_med then
                    mod:error("Medicae stop callback: %s", tostring(err_med))
                end
                return func(self, ...)
            end
        )
    end
)

-- One callback per DMF hook. Prior versions registered duplicate
-- AttackReportManager hooks that could suppress the Daemonhost callback.
mod:hook_safe("AttackReportManager", "_process_attack_result", function(self, buffer_data)
    if not mod._reporting_enabled() then return end
    if mod:get("report_barrels") ~= false or mod:get("report_end_barrel_summary") ~= false
        or mod:get("report_end_barrel_team_total") ~= false
        or mod:get("report_poxbursters") ~= false or mod:get("report_end_poxburster_summary") ~= false
        or mod:get("report_end_poxburster_team_total") ~= false then
        local ok, err = pcall(IncidentTracker.on_attack_result, self, buffer_data)
        if not ok then mod:error("Explosion result tracking: %s", tostring(err)) end
    end
    if mod:get("report_daemonhost") ~= false then
        local ok_host, err_host = pcall(DaemonhostTracker.on_attack_result, self, buffer_data)
        if not ok_host then mod:error("Daemonhost result tracking: %s", tostring(err_host)) end
    end
end)
