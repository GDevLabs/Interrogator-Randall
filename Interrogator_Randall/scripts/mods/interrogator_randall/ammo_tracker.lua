local AmmoTracker = {}

local function round(value)
    return math.floor(value + 0.5)
end

function AmmoTracker.calculate(snapshot, pickup_data, modifier)
    local total_current = 0
    local total_max = 0
    local total_offered = 0
    local total_missing = 0
    local total_wasted = 0
    local pickup_copy = {}

    for key, value in pairs(pickup_data) do
        pickup_copy[key] = value
    end

    pickup_copy.modifier = modifier or 1

    for _, slot in ipairs(snapshot.slots or {}) do
        if (slot.max_reserve or 0) > 0 then
            local current = (slot.reserve or 0) + (slot.clip or 0)
            local maximum = (slot.max_reserve or 0) + (slot.max_clip or 0)
            local missing = math.max(0, maximum - current)
            local offered = pickup_copy.ammo_amount_func(
                slot.max_reserve,
                slot.max_clip,
                pickup_copy
            )

            offered = math.max(0, offered or 0)
            total_current = total_current + current
            total_max = total_max + maximum
            total_missing = total_missing + missing
            total_offered = total_offered + offered
            total_wasted = total_wasted
                + math.max(0, offered - math.min(offered, missing))
        end
    end

    if total_max <= 0 or total_offered <= 0 then
        return nil
    end

    local ammo_percent = 100 * total_current / total_max
    local waste_percent = 100 * total_wasted / total_offered

    return {
        pickup_name = pickup_data.name,
        offered = total_offered,
        missing = total_missing,
        wasted = total_wasted,
        ammo_before_percent = ammo_percent,
        waste_percent = waste_percent,
        display_ammo_percent = round(ammo_percent),
        display_waste_percent = round(waste_percent),
    }
end

function AmmoTracker.new_stats(player_id, player_name)
    return {
        player_id = player_id,
        player_name = player_name,
        total_offered = 0,
        total_wasted = 0,
        pickup_count = 0,
    }
end

function AmmoTracker.apply(stats, result)
    stats.total_offered = stats.total_offered + result.offered
    stats.total_wasted = stats.total_wasted + result.wasted
    stats.pickup_count = stats.pickup_count + 1
end

function AmmoTracker.summary_percent(stats)
    if stats.total_offered <= 0 then
        return nil
    end

    return round(100 * stats.total_wasted / stats.total_offered)
end

return AmmoTracker
