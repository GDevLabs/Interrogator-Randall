-- End-of-mission summaries are INDEPENDENT of the live-report toggles/thresholds.
-- Medicae: relative to each player's maximum HP, not a literal station-charge loss.
-- Green Med Stimm: unused HP-equivalent budget after accounting for HP and corruption.
local Summary = {}
Summary.__index = Summary

local function valid(value)
    return type(value) == "number" and value == value and value >= 0 and value < math.huge
end
local function nearest(value) return math.floor(value + 0.5) end
local function count_label(n, singular, plural)
    return tostring(n) .. " " .. (n == 1 and singular or plural)
end
local function add_row(group, key, display, capacity, unused, cleared)
    local row = group[key]
    if not row then
        row = { name=display, uses=0, capacity=0, unused=0, corruption=0 }
        group[key] = row
    end
    row.uses = row.uses + 1
    row.capacity = row.capacity + capacity
    row.unused = row.unused + unused
    row.corruption = row.corruption + (cleared or 0)
end
function Summary.new()
    return setmetatable({stations={}, stimms={}, unmeasured_stimms={}}, Summary)
end
function Summary:reset()
    self.stations, self.stimms, self.unmeasured_stimms = {}, {}, {}
end
-- Must represent a confirmed successful station interaction with a BEFORE
-- snapshot; unknown healing is not counted as 100% waste.
function Summary:record_medicae(name, max_hp, restored_hp, cleared_corruption)
    if type(name) ~= "string" or name == "" or not valid(max_hp) or max_hp <= 0
        or not valid(restored_hp) then return false end
    local used = math.min(max_hp, restored_hp)
    add_row(self.stations, name, name, max_hp, max_hp-used,
        valid(cleared_corruption) and cleared_corruption or 0)
    return true
end
-- A Med Stimm consumes the greater of HP healed and corruption cleared, NOT
-- their sum. The tracker confirms a syringe action/heal before calling this.
-- Unverified injectors must never be blamed on the recipient.
function Summary:record_stimm(actor, recipient, result)
    if type(result) ~= "table" or not valid(result.capacity) or
        result.capacity <= 0 or not valid(result.healed) or
        not valid(result.cleared) then return false end
    local used = math.min(result.capacity, math.max(result.healed, result.cleared))
    local name = type(actor) == "string" and actor ~= "" and actor or nil
    local recipient_name = type(recipient)=="string" and recipient~="" and recipient or "Recipient unverified"
    local label = (name or "Injector unverified") .. " on " .. recipient_name
    -- Key is a non-printable separator to avoid two different name pairs
    -- colliding. This records the injector AND the person actually healed.
    local key = (name or "_injector_unverified") .. "\001" .. recipient_name
    add_row(self.stimms, key, label, result.capacity, result.capacity-used, result.cleared)
    return true
end
-- The injector and recipient were observed, but client-side healing was not.
-- Keep this out of percentage denominators to avoid a false 100% waste claim.
function Summary:record_stimm_unverified(actor, recipient)
    local who = type(actor)=="string" and actor~="" and actor or "Injector unverified"
    local target = type(recipient)=="string" and recipient~="" and recipient or "Recipient unverified"
    local label=who.." on "..target
    local row=self.unmeasured_stimms[label]
    if not row then row={name=label,uses=0};self.unmeasured_stimms[label]=row end
    row.uses=row.uses+1
    return true
end
local function collect(group)
    local players = {}
    local total = {uses=0, capacity=0, unused=0, corruption=0}
    for _, row in pairs(group) do
        players[#players+1]=row
        total.uses=total.uses+row.uses
        total.capacity=total.capacity+row.capacity
        total.unused=total.unused+row.unused
        total.corruption=total.corruption+row.corruption
    end
    table.sort(players,function(a,b)
        if a.unused ~= b.unused then return a.unused > b.unused end
        return a.name < b.name
    end)
    local pct=total.capacity>0 and nearest(100*total.unused/total.capacity) or 0
    return players,total,pct
end
-- Only report categories with actual tracked uses. Totals are measured over
-- ALL tracked uses, never just live messages passing the slider threshold.
function Summary:rows(medicae_enabled, stimm_enabled, medicae_team, stimm_team)
    local rows = {}
    if medicae_enabled or medicae_team then
        local players,total,pct=collect(self.stations)
        if total.uses>0 then
            if medicae_team then
                rows[#rows+1]={body=string.format(
                    "Medicae TOTAL: %d%% healing wasted across %s (estimated)",
                    pct,count_label(total.uses,"use","uses")),
                    category="report_end_medicae_team_total"}
            end
            if medicae_enabled then
            for _,row in ipairs(players) do
                local player_pct = row.capacity > 0 and nearest(100 * row.unused / row.capacity) or 0
                rows[#rows+1]={body=string.format(
                    "Medicae: %s - %d%% healing wasted across %s (estimated)",
                    row.name,player_pct,count_label(row.uses,"use","uses")),
                    category="report_end_medicae_summary"}
            end
            end
        end
    end
    if stimm_enabled or stimm_team then
        local players,total,pct=collect(self.stimms)
        local unmeasured,total_unmeasured={},0
        for _,entry in pairs(self.unmeasured_stimms) do
            unmeasured[#unmeasured+1]=entry
            total_unmeasured=total_unmeasured+entry.uses
        end
        table.sort(unmeasured,function(a,b)return a.name<b.name end)
        if total.uses>0 then
            if stimm_team then
                rows[#rows+1]={body=string.format(
                    "Med Stimm TOTAL: %d%% healing wasted across %s",
                    pct,count_label(total.uses,"injection","injections")),
                    category="report_end_med_stimm_team_total"}
            end
            if stimm_enabled then
            for _,row in ipairs(players) do
                local player_pct = row.capacity > 0 and nearest(100 * row.unused / row.capacity) or 0
                rows[#rows+1]={body=string.format(
                    "Med Stimm: %s - %d%% healing wasted across %s",
                    row.name,player_pct,count_label(row.uses,"injection","injections")),
                    category="report_end_med_stimm_summary"}
            end
            end
        end
        if total_unmeasured>0 then
            -- The combined unmeasured count is itself a team-wide total.
            -- Never leak it into player-only results when Team Total is OFF.
            if stimm_team then
                rows[#rows+1]={body=string.format(
                    "Med Stimm: %s unmeasured (not counted as wasted)",
                    count_label(total_unmeasured,"confirmed injection","confirmed injections")),
                    category="report_end_med_stimm_team_total"}
            end
            if stimm_enabled then
            for _,row in ipairs(unmeasured) do
                rows[#rows+1]={body=string.format(
                    "Med Stimm: %s - healing unverified across %s",
                    row.name,count_label(row.uses,"injection","injections")),
                    category="report_end_med_stimm_summary"}
            end
            end
        end
    end
    return rows
end
return Summary
