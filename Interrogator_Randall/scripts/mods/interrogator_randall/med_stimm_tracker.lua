-- Green Med Stimm / Health Booster tracker.
-- ActionUseSyringe.fixed_update exposes the injector and target, including use
-- on allies. PlayerUnitHealthExtension.add_heal exposes confirmed healing types.
-- Health values may be replicated later on client-only installations.
local mod = get_mod("interrogator_randall")
local DamageSettings = require("scripts/settings/damage/damage_settings")
local heal_types = DamageSettings.heal_types
local NORMAL = heal_types.syringe
local CORRUPTION = heal_types.blessing_syringe
local GREEN_STIMM_BUFF = "syringe_heal_corruption_buff"
local M = {}
local clock, pending, unresolved = 0, {}, {}
-- Missing client replication should not immediately become a second apparent
-- injection when a late health update or a repeated action callback arrives.
local RECOVERY_GRACE = 6.0
local RECONCILE_WINDOW = 8.0
local use_pre_snapshots = setmetatable({}, {__mode="k"})
local reported_actions = setmetatable({}, {__mode="k"})
-- An action can be signalled by several callbacks in the same update window.
-- Restrict deduplication to the same actor AND recipient, and preserve the
-- earliest pre-use snapshot. Real consecutive syringes are farther apart.
local recent_uses = setmetatable({}, {__mode="k"})
local DUPLICATE_USE_WINDOW = 0.85
local USE_DELAY = 1.8 -- allow replicated HP and corruption updates to settle
local HEAL_DELAY = 0.8 -- group separate HP and corruption callbacks
local function tracking_enabled()
    return mod:get("report_med_stimm") ~= false or
        mod:get("report_end_med_stimm_summary") ~= false or
        mod:get("report_end_med_stimm_team_total") ~= false
end

local function call(obj, method, ...)
    local fn = obj and obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, obj, ...)
    if ok then return value end
end
local function field(obj, k)
    local ok, value = pcall(function() return obj and obj[k] end)
    if ok then return value end
end
local function clamp(x, lo, hi) return math.min(hi, math.max(lo, x)) end
local function human_name(player)
    if not player or call(player, "is_human_controlled") ~= true then return nil end
    local name = call(player, "name")
    if type(name) ~= "string" or name == "" then return nil end
    return name:gsub("{#.-}", ""):gsub("[\r\n]", " "):gsub("%[", "("):gsub("%]", ")")
end
local function owner(unit, extension)
    local p = field(extension, "_player")
    if human_name(p) then return p end
    local mgrs = rawget(_G, "Managers")
    local players = mgrs and mgrs.player
    local spawn = mgrs and mgrs.state and mgrs.state.player_unit_spawn
    return call(spawn, "owner", unit) or call(players, "player_by_unit", unit)
end
local function snapshot(unit)
    local ext
    local ok = pcall(function()
        ext = unit and ScriptUnit and ScriptUnit.has_extension(unit, "health_system")
    end)
    if not ok or not ext then return nil end
    local hp = call(ext, "current_health")
    local corr = call(ext, "permanent_damage_taken")
    local max = call(ext, "max_health")
    local wounds = call(ext, "max_wounds")
    if type(hp) ~= "number" or type(max) ~= "number" or max <= 0
       or type(wounds) ~= "number" or wounds < 1 then return nil end
    return { hp=hp, corrupt=type(corr)=="number" and corr or nil, max=max, wounds=wounds }
end

function M.calculate(max_hp, wounds, hp_restored, corruption_cleared, confirmed_fully_wasted)
    if type(max_hp) ~= "number" or max_hp <= 0 or
        type(wounds) ~= "number" or wounds <= 0 then return nil end
    -- Darktide syringe buff: budget is max(one health segment, 25% max HP).
    -- Game decrements 'healing_remaining' by max(HP healed, corruption healed),
    -- NOT their sum. This is why both can be restored simultaneously.
    local budget = math.max(max_hp * 0.25, max_hp / wounds)
    local hp, corruption = math.max(0,hp_restored or 0),math.max(0,corruption_cleared or 0)
    local consumed = math.max(hp, corruption)
    -- At 100% waste there is no recovery event, so only classify it when
    -- an actual syringe use is observed at completely full, uncorrupted HP.
    if consumed < 0.01 and not confirmed_fully_wasted then return nil end
    local waste = clamp(100 * (budget - consumed) / budget,0,100)
    return { capacity=budget, healed=hp, cleared=corruption,
        wasted=math.floor(waste+0.5) }
end
function M.format(name, result, actor)
    if not name or not result then return nil end
    local prefix
    if actor == name then
        prefix = name .. " used Med Stimm (Health Booster)"
    elseif actor then
        prefix = actor .. " used Med Stimm on " .. name
    else
        prefix = name .. " received Med Stimm (Health Booster)"
    end
    return string.format("%s • healed %d HP • cleared %d corruption • %d%% waste",
       prefix, math.floor(result.healed+.5), math.floor(result.cleared+.5), result.wasted)
end
-- Capture positive HP/corruption changes while the stimm remains pending.
-- A target may heal and take damage before the 1.8s flush, so comparing only
-- the first/last health value can miss real recovery. These sampled values
-- supplement, rather than add to, add_heal callback totals.
local function sample_recovery(unit, entry)
    if not entry or not entry.before then return end
    local current = snapshot(unit)
    if not current then return end
    local previous_hp = entry.observed_hp or entry.before.hp
    if current.hp > previous_hp then
        entry.sampled_healed = (entry.sampled_healed or 0) + (current.hp - previous_hp)
    end
    entry.observed_hp = current.hp
    if current.corrupt ~= nil then
        local previous_corrupt = entry.observed_corrupt
        if previous_corrupt == nil then previous_corrupt = entry.before.corrupt end
        if previous_corrupt ~= nil and current.corrupt < previous_corrupt then
            entry.sampled_cleared = (entry.sampled_cleared or 0) + (previous_corrupt - current.corrupt)
        end
        entry.observed_corrupt = current.corrupt
    end
end

local function same_unmeasured_use(previous, entry)
    if not previous or not entry or previous.actor ~= entry.actor or
        previous.name ~= entry.name or not previous.before or not entry.before then return false end
    if math.abs(previous.before.hp - entry.before.hp) > 0.01 then return false end
    if previous.before.corrupt ~= nil and entry.before.corrupt ~= nil and
        math.abs(previous.before.corrupt - entry.before.corrupt) > 0.01 then return false end
    return clock - previous.last <= RECONCILE_WINDOW
end

local function record_unmeasured(entry)
    if not entry or not entry.use_confirmed then return end
    if mod:get("report_end_med_stimm_summary") == false and
        mod:get("report_end_med_stimm_team_total") == false then return end
    local summary = mod._healing_summary and mod._healing_summary()
    if summary then summary:record_stimm_unverified(entry.actor, entry.name) end
end

-- At the end of a short grace period, retain truly unmeasured injections,
-- but first check once more for health that reached our client late.
local function finish_unresolved(unit)
    local entry = unresolved[unit]
    unresolved[unit] = nil
    if not entry or not tracking_enabled() then return end
    sample_recovery(unit, entry)
    local after = snapshot(unit)
    if entry.before and after then
        local hp = math.max(entry.healed or 0, entry.sampled_healed or 0, math.max(0, after.hp - entry.before.hp))
        local corruption = math.max(entry.cleared or 0, entry.sampled_cleared or 0)
        if after.corrupt ~= nil and entry.before.corrupt ~= nil then
            corruption = math.max(corruption, math.max(0, entry.before.corrupt - after.corrupt))
        end
        local report = M.calculate(entry.max, entry.wounds, hp, corruption, false)
        if report then
            if mod:get("diagnostic_logging") then
                mod:info("IR Med Stimm late recovery: injector=%s recipient=%s restored=%.1f corruption=%.1f",
                    tostring(entry.actor), tostring(entry.name), hp, corruption)
            end
            local summary = mod._healing_summary and mod._healing_summary()
            if summary and (mod:get("report_end_med_stimm_summary") ~= false or
                mod:get("report_end_med_stimm_team_total") ~= false) then
                summary:record_stimm(entry.actor,entry.name,report)
            end
            if mod:get("report_med_stimm") ~= false then
                local threshold = clamp(tonumber(mod:get("minimum_med_stimm_waste_to_report")) or 50,0,100)
                if report.wasted >= threshold then
                    local chat = mod._chat_reports and mod._chat_reports()
                    if chat then chat:queue_incident(M.format(entry.name,report,entry.actor), "report_med_stimm") end
                end
            end
            return
        end
    end
    record_unmeasured(entry)
end

function M.flush(unit)
    local entry = pending[unit]
    pending[unit] = nil
    if not entry or not tracking_enabled() then return end
    sample_recovery(unit, entry)
    local after = snapshot(unit)
    local hp = math.max(entry.healed or 0, entry.sampled_healed or 0)
    local corrupt = math.max(entry.cleared or 0, entry.sampled_cleared or 0)
    if entry.before and after then
        hp = math.max(hp, math.max(0, after.hp - entry.before.hp))
        if after.corrupt ~= nil and entry.before.corrupt ~= nil then
            corrupt = math.max(corrupt, math.max(0, entry.before.corrupt - after.corrupt))
        end
    end
    local fully_healthy_at_use = entry.actor ~= nil and entry.before ~= nil
        and entry.before.hp >= entry.before.max - 0.01
        and entry.before.corrupt ~= nil and entry.before.corrupt <= 0.01
    local report = M.calculate(entry.max, entry.wounds, hp, corrupt, fully_healthy_at_use)
    if not report then
        -- A confirmed client-side injection can precede network-replicated
        -- healing. Hold the unresolved event briefly rather than emitting
        -- a misleading second report before its healing reaches this client.
        if entry.use_confirmed then
            local previous = unresolved[unit]
            if previous and not same_unmeasured_use(previous, entry) then
                finish_unresolved(unit)
                previous = nil
            end
            if previous then
                previous.deadline = math.max(previous.deadline, clock + RECOVERY_GRACE)
                previous.last = clock
            else
                entry.last = clock
                entry.deadline = clock + RECOVERY_GRACE
                unresolved[unit] = entry
            end
        end
        if mod:get("diagnostic_logging") then
            mod:info("IR Med Stimm awaiting recovery: injector=%s recipient=%s confirmed=%s healed=%.1f corruption=%.1f",
                tostring(entry.actor or "unverified"),tostring(entry.name),
                tostring(entry.use_confirmed == true),hp,corrupt)
        end
        return
    end
    local previous = unresolved[unit]
    if previous and same_unmeasured_use(previous,entry) then
        unresolved[unit] = nil
        if mod:get("diagnostic_logging") then
            mod:info("IR Med Stimm reconciled delayed or repeated use: injector=%s recipient=%s",
                tostring(entry.actor),tostring(entry.name))
        end
    elseif previous then
        finish_unresolved(unit)
    end
    if mod:get("diagnostic_logging") then
        mod:info("IR Med Stimm: injector=%s recipient=%s restored=%.1f corruption=%.1f waste=%d%%",
            tostring(entry.actor or "unverified"), tostring(entry.name),
            report.healed, report.cleared, report.wasted)
    end
    if mod:get("report_end_med_stimm_summary") ~= false or
        mod:get("report_end_med_stimm_team_total") ~= false then
        local summary = mod._healing_summary and mod._healing_summary()
        if summary then summary:record_stimm(entry.actor,entry.name,report) end
    end
    if mod:get("report_med_stimm") == false then return end
    local threshold = clamp(tonumber(mod:get("minimum_med_stimm_waste_to_report")) or 50,0,100)
    if report.wasted < threshold then return end
    local chat = mod._chat_reports and mod._chat_reports()
    if chat then chat:queue_incident(M.format(entry.name,report,entry.actor), "report_med_stimm") end
end
-- This action fires on the client performing an injection, including an ally.
-- Match the *green* syringe buff so the other three stimm types are excluded.
function M.observe_use(actor_unit, recipient_unit, before_snapshot)
    if not tracking_enabled() or not recipient_unit then return end
    local actor = human_name(owner(actor_unit))
    local name = human_name(owner(recipient_unit))
    if not actor or not name then
        if mod:get("diagnostic_logging") then
            mod:info("IR Med Stimm use skipped: actor_name=%s target_name=%s target_available=%s",
                tostring(actor), tostring(name), tostring(recipient_unit ~= nil))
        end
        return false
    end
    local recent = recent_uses[recipient_unit]
    if recent and recent.actor == actor and clock - recent.time < DUPLICATE_USE_WINDOW then
        if mod:get("diagnostic_logging") then
            mod:info("IR Med Stimm duplicate action ignored: injector=%s recipient=%s interval=%.2fs",
                actor,name,clock-recent.time)
        end
        return true
    end
    local existing = pending[recipient_unit]
    -- The server may run add_heal before the syringe's fixed_update returns.
    -- Keep that confirmed recovery and attach the injector, rather than
    -- reporting twice (once as recipient-only, once as actor+recipient).
    if existing and not existing.use_confirmed and clock - existing.last <= 1.5 then
        existing.actor = actor
        existing.name = name
        existing.use_confirmed = true
        existing.due = math.max(existing.due, clock + USE_DELAY)
        recent_uses[recipient_unit] = { actor=actor, time=clock }
        return true
    end
    if existing then M.flush(recipient_unit) end
    local before = before_snapshot or snapshot(recipient_unit)
    if not before then
        if mod:get("diagnostic_logging") then
            mod:info("IR Med Stimm use skipped: snapshot missing, injector=%s recipient=%s",actor,name)
        end
        return false
    end
    pending[recipient_unit] = { name=name, actor=actor, before=before,
        use_confirmed=true, max=before.max, wounds=before.wounds,
        observed_hp=before.hp, observed_corrupt=before.corrupt,
        healed=0, cleared=0, last=clock, due=clock+USE_DELAY }
    recent_uses[recipient_unit] = { actor=actor, time=clock }
    if mod:get("diagnostic_logging") then
        mod:info("IR Med Stimm use observed: injector=%s recipient=%s before=%.1f/%.1f",
            actor,name,before.hp,before.max)
    end
    return true
end

-- Server-side heal hooks are supplemental: they can also identify a Med Stimm
-- recipient if a use action is unavailable, but have no reliable injector field.
function M.observe_heal(extension, heal_type, actual)
    if not tracking_enabled() then return end
    if heal_type ~= NORMAL and heal_type ~= CORRUPTION then return end
    if type(actual) ~= "number" or actual <= 0 then return end
    local unit = field(extension, "_unit")
    if not unit then return end
    local name = human_name(owner(unit, extension))
    if not name then return end
    local existing = pending[unit]
    if existing and clock >= existing.due then M.flush(unit); existing = nil end
    if not existing then
        local max = call(extension,"max_health")
        local wounds = call(extension,"max_wounds")
        if type(max)~="number" or max<=0 or type(wounds)~="number" or wounds<=0 then return end
        existing = {name=name,max=max,wounds=wounds,healed=0,cleared=0,last=clock,due=clock+HEAL_DELAY}
        pending[unit]=existing
    end
    if heal_type == NORMAL then
        existing.healed = existing.healed + actual
    else
        existing.cleared = existing.cleared + actual
    end
    existing.last=clock
    existing.due=math.max(existing.due,clock+HEAL_DELAY)
end

-- Resolve the *actual* buff selected by a syringe action. Some character
-- talents override the action's base buff name, which must not be mistaken
-- for another stimm type or discarded when it is in fact a green Med Stimm.
local SpecialRulesSettings = require("scripts/settings/ability/special_rules_settings")
local special_rules = SpecialRulesSettings.special_rules
local function effective_syringe_buff(self)
    local settings = field(self, "_action_settings")
    if not settings then return nil end
    local talents = field(self, "_talent_extension")
    if call(talents, "has_special_rule", special_rules.buff_target_buff_name_override_one) then
        return field(settings, "override_buff_name_one") or field(settings, "buff_name")
    end
    if call(talents, "has_special_rule", special_rules.buff_target_buff_name_override_two) then
        return field(settings, "override_buff_name_two") or field(settings, "buff_name")
    end
    return field(settings, "buff_name")
end

mod:hook_require("scripts/extension_systems/weapon/actions/action_use_syringe", function(instance)
    if type(instance.fixed_update) ~= "function" then return end
    if type(instance.start) == "function" then
        mod:hook_safe(instance, "start", function(self)
            reported_actions[self] = nil
            use_pre_snapshots[self] = nil
        end)
    end
    -- This call is made for a *successfully executed* syringe action with
    -- the actual target unit, before the target component is discarded.
    -- The old _did_use transition remains as a fallback, not a second report.
    if type(instance._report_use_to_stat_system) == "function" then
        mod:hook_safe(instance,"_report_use_to_stat_system",function(self, actual_target)
            if not tracking_enabled() or reported_actions[self] then return end
            if effective_syringe_buff(self) ~= GREEN_STIMM_BUFF then return end
            local pre=use_pre_snapshots[self]
            local target=actual_target or (pre and pre.target)
            local actor=field(self,"_player_unit")
            local ok, handled = pcall(M.observe_use,actor,target,pre and pre.before)
            if ok and handled then reported_actions[self]=true end
            if not ok and type(mod.error)=="function" then
                pcall(mod.error,mod,"Med Stimm successful-action tracking failed: %s",tostring(handled))
            end
        end)
    end
    mod:hook(instance,"fixed_update",function(func,self,dt,t,time_in_action,...)
        local buff_name=effective_syringe_buff(self)
        local observe = tracking_enabled() and buff_name == GREEN_STIMM_BUFF
        local was_used = field(self,"_did_use")
        local actor = observe and field(self,"_player_unit")
        -- The original function clears its target during a successful use.
        local target = observe and call(self,"_target_unit")
        local pre_use = observe and snapshot(target or actor)
        if observe then use_pre_snapshots[self]={target=target,before=pre_use} end
        local result = func(self,dt,t,time_in_action,...)
        if tracking_enabled() and not was_used and field(self,"_did_use") == true then
            if observe and not reported_actions[self] then
                local ok, handled = pcall(M.observe_use, actor, target or actor, pre_use)
                if ok and handled then reported_actions[self]=true end
                if not ok and type(mod.error)=="function" then
                    pcall(mod.error,mod,"Med Stimm action tracking failed: %s",tostring(handled))
                end
            elseif not observe and mod:get("diagnostic_logging") then
                mod:info("IR Syringe used with different buff: %s (not counted as green Med Stimm)", tostring(buff_name))
            end
        end
        use_pre_snapshots[self]=nil
        return result
    end)
end)

mod:hook_require("scripts/extension_systems/health/player_unit_health_extension",function(instance)
    if type(instance.add_heal)~="function" then return end
    mod:hook(instance,"add_heal",function(func,self,amount,heal_type,...)
        local actual=func(self,amount,heal_type,...)
        if heal_type==NORMAL or heal_type==CORRUPTION then
            local ok,err=pcall(M.observe_heal,self,heal_type,actual)
            if not ok and type(mod.error)=="function" then
                pcall(mod.error,mod,"Med Stimm heal tracking failed: %s",tostring(err))
            end
        end
        return actual
    end)
end)
function M.update(dt)
    if not tracking_enabled() then M.reset();return end
    clock=clock+(dt or 0)
    for unit, entry in pairs(pending) do
        sample_recovery(unit, entry)
        if clock>=entry.due then M.flush(unit) end
    end
    for unit, entry in pairs(unresolved) do
        sample_recovery(unit, entry)
        if clock>=entry.deadline then finish_unresolved(unit) end
    end
end
function M.flush_all()
    for unit in pairs(pending) do M.flush(unit) end
    for unit in pairs(unresolved) do finish_unresolved(unit) end
end
function M.reset()
    clock=0;pending={};unresolved={}
    use_pre_snapshots=setmetatable({}, {__mode="k"})
    reported_actions=setmetatable({}, {__mode="k"})
    recent_uses=setmetatable({}, {__mode="k"})
end
return M
