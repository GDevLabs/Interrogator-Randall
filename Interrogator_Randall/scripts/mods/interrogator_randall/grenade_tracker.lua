-- Grenade pickup waste follows the same independently tracked live/summary pattern
-- as ammo. It covers only the map's small_grenade pickup, not generated charges.
local Grenades = {}
local function round(n) return math.floor(n + 0.5) end
function Grenades.calculate(current, maximum, restored_budget)
    if type(current) ~= "number" or type(maximum) ~= "number"
        or type(restored_budget) ~= "number" or maximum <= 0
        or current ~= current or maximum ~= maximum or restored_budget <= 0 then return nil end
    current = math.min(maximum, math.max(0, current))
    -- The small grenade box has charges_restored=100. The game clamps restored
    -- charges at the grenade ability's actual maximum, never 100 grenades.
    local offered = math.min(maximum, restored_budget)
    local missing = math.max(0, maximum - current)
    local wasted = math.max(0, offered - math.min(offered, missing))
    return {offered=offered, wasted=wasted, current=current, maximum=maximum,
        before_percent=round(100*current/maximum),
        waste_percent=100*wasted/offered,
        display_waste_percent=round(100*wasted/offered)}
end
function Grenades.new_stats(id,name)
    return {player_id=id,player_name=name,total_offered=0,total_wasted=0,pickup_count=0}
end
function Grenades.apply(stats,event)
    stats.total_offered=stats.total_offered+event.offered
    stats.total_wasted=stats.total_wasted+event.wasted
    stats.pickup_count=stats.pickup_count+1
end
function Grenades.summary_percent(stats)
    return stats.total_offered>0 and round(100*stats.total_wasted/stats.total_offered) or nil
end
return Grenades
