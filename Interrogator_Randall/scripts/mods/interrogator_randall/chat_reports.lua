local ChatManagerConstants = require(
    "scripts/foundation/managers/chat/chat_manager_constants"
)

local ChatReports = {}
ChatReports.__index = ChatReports
local mod = get_mod("interrogator_randall")
-- A second, explicit safety check is needed for scheduled reports if a
-- Darktide Mod Framework toggle disables this mod during a session. DMF
-- disables registered hooks, but a pending chat queue must never send after
-- the mod itself has been switched off.
local function enabled(category)
    -- No sender may bypass the lifecycle state maintained by the main mod.
    -- Fail closed before that module finishes loading, too.
    return type(mod._reporting_enabled) == "function"
        and mod._reporting_enabled(category)
end

local MESSAGE_LIFETIME = 18
-- Results screens can queue several summary categories back-to-back. Keep
-- them eligible longer than ordinary mid-mission incidents when the Strike
-- Team channel is temporarily busy or connects late. The queue is still
-- discarded on score exit, on mod disable, and at the next mission reset.
local SUMMARY_MESSAGE_LIFETIME = 60
local SUMMARY_INTERVAL = 0.45
local INCIDENT_SPACING = 0.35
local MISSION = ChatManagerConstants.ChannelTag.MISSION
local LABELS = {
    small_clip = { verb = "took", label = "Small Ammo" },
    large_clip = { verb = "took", label = "Large Ammo" },
    ammo_cache_deployable = { verb = "used", label = "Ammo Crate" },
}

function ChatReports.format_pickup(
    name,
    pickup_name,
    ammo_percent,
    waste_percent
)
    local item = LABELS[pickup_name]

    if not item then
        return nil
    end

    return string.format(
        "%s %s %s at %d%% (%d%% wasted)",
        name,
        item.verb,
        item.label,
        ammo_percent,
        waste_percent
    )
end

function ChatReports.format_summary(name, percent)
    if percent == nil then
        return nil
    end

    return string.format("%s wasted %d%% of picked-up ammo", name, percent)
end

function ChatReports.new()
    return setmetatable({
        clock = 0,
        queue = {},
        last_incident_send = -INCIDENT_SPACING,
        last_actual_send = -INCIDENT_SPACING,
    }, ChatReports)
end

function ChatReports:_enqueue(body, earliest_send, expires_at, category)
    if not body or not enabled(category) then
        return
    end

    self.queue[#self.queue + 1] = {
        body = body,
        earliest_send = earliest_send,
        expires_at = expires_at,
        category = category,
    }
end

local function mission_channel()
    local managers = rawget(_G, "Managers")
    local chat = managers and managers.chat

    if not chat or type(chat.connected_chat_channels) ~= "function" then
        return nil, nil
    end

    local ok, channels = pcall(chat.connected_chat_channels, chat)

    if not ok or not channels then
        return nil, nil
    end

    for handle, channel in pairs(channels) do
        if channel.tag == MISSION then
            return chat, handle
        end
    end

    return nil, nil
end

function ChatReports:update(dt)
    self.clock = self.clock + (dt or 0)
    if #self.queue == 0 then return end

    while #self.queue > 0 do
        local item = self.queue[1]

        if not enabled(item.category) or self.clock >= item.expires_at then
            table.remove(self.queue, 1)
        elseif self.clock >= item.earliest_send and
            self.clock - self.last_actual_send >= INCIDENT_SPACING then
            local chat, handle = mission_channel()
            local sent = false

            if chat and type(chat.send_channel_message) == "function" then
                local ok, accepted = pcall(
                    chat.send_channel_message,
                    chat,
                    handle,
                    item.body
                )
                sent = ok and accepted ~= false
            end

            if sent then
                self.last_actual_send = self.clock
                if mod:get("diagnostic_logging") and item.category == "report_medicae" then
                    mod:info("IR Medicae chat submitted: %s", item.body)
                end
                table.remove(self.queue, 1)
            else
                break
            end
        else
            break
        end
    end
end

function ChatReports:queue_pickup(
    name,
    pickup_name,
    ammo_percent,
    waste_percent
)
    local body = ChatReports.format_pickup(
        name,
        pickup_name,
        ammo_percent,
        waste_percent
    )

    self:_enqueue(body, self.clock, self.clock + MESSAGE_LIFETIME, "report_ammo")
    self:update(0)
end

-- Sent to the real, shared mission channel (not mod:echo, which is local only).
function ChatReports:queue_incident(body, category)
    if not body or not enabled(category) then return end
    local earliest = math.max(self.clock, self.last_incident_send + INCIDENT_SPACING)
    self.last_incident_send = earliest
    self:_enqueue(body, earliest, self.clock + MESSAGE_LIFETIME, category)
    self:update(0)
end

function ChatReports:queue_ammo_team_total(team)
    if not team or team.total_offered <= 0 then return end
    local pct = math.floor(100 * team.total_wasted / team.total_offered + 0.5)
    local pickups = team.pickup_count
    local body = string.format("Ammo TOTAL: %d%% of picked-up ammo wasted across %d %s",
        pct, pickups, pickups == 1 and "pickup" or "pickups")
    self:_enqueue(body, self.clock, self.clock + SUMMARY_MESSAGE_LIFETIME,
        "report_end_ammo_team_total")
    self:update(0)
end

function ChatReports:queue_grenade_team_total(team)
    if not team or team.total_offered <= 0 then return end
    local pct = math.floor(100 * team.total_wasted / team.total_offered + 0.5)
    local pickups = team.pickup_count
    local body = string.format("Grenades TOTAL: %d%% of picked-up grenade capacity wasted across %d %s",
        pct, pickups, pickups == 1 and "pickup" or "pickups")
    self:_enqueue(body, self.clock, self.clock + SUMMARY_MESSAGE_LIFETIME,
        "report_end_grenade_team_total")
    self:update(0)
end

function ChatReports:queue_summary(rows)
    local expires_at = self.clock + SUMMARY_MESSAGE_LIFETIME

    for index, row in ipairs(rows or {}) do
        self:_enqueue(
            ChatReports.format_summary(row.name, row.percent),
            self.clock + (index - 1) * SUMMARY_INTERVAL,
            expires_at,
            "report_end_ammo_summary"
        )
    end

    self:update(0)
end

function ChatReports:queue_grenade_summary(rows)
    local expires_at=self.clock+SUMMARY_MESSAGE_LIFETIME
    for i,row in ipairs(rows or {}) do
        local body=string.format("%s wasted %d%% of picked-up grenade capacity across %d %s",
            row.name,row.percent,row.count,row.count==1 and "pickup" or "pickups")
        self:_enqueue(body,self.clock+(i-1)*SUMMARY_INTERVAL,
            expires_at,"report_end_grenade_summary")
    end
    self:update(0)
end

function ChatReports:queue_explosion_summary(rows)
    local expires_at = self.clock + SUMMARY_MESSAGE_LIFETIME
    local scheduled = 0
    for _, row in ipairs(rows or {}) do
        -- Distinct categories also protect unsent messages if a toggle
        -- changes while score-screen chat reports are queued.
        if row.category and enabled(row.category) then
            self:_enqueue(row.body,
                self.clock + scheduled * SUMMARY_INTERVAL,
                expires_at, row.category)
            scheduled = scheduled + 1
        end
    end
    self:update(0)
end

function ChatReports:queue_healing_summary(rows)
    local expires_at = self.clock + SUMMARY_MESSAGE_LIFETIME
    for index, row in ipairs(rows or {}) do
        -- The independent summary toggles are applied when constructing rows.
        -- Do not couple delivery to the live Medicae/Med Stimm switches.
        self:_enqueue(row.body, self.clock + (index - 1)*SUMMARY_INTERVAL,
            expires_at, row.category)
    end
    self:update(0)
end

function ChatReports:reset()
    self.clock = 0
    self.queue = {}
    self.last_incident_send = -INCIDENT_SPACING
    self.last_actual_send = -INCIDENT_SPACING
end

return ChatReports
