--[[
    AutoStation v1.0.0-beta - Grounded 2 (UE4SS Lua)
    https://github.com/kamibiel/autostation
    -------------------------------------------------------------
    Keeps production stations (refinery/grinder, smelter, kiln, spinning
    wheel, cooking station...) running from nearby chests.

    How it works
      * Queue a recipe on a station by hand once -> that station is tracked
        with that recipe.
      * Every few seconds, for tracked stations near you:
          - finished items are moved to a nearby chest that ALREADY holds
            that item (if none does, they stay in the station);
          - the queue is topped up with the same recipe. The game itself
            takes the ingredients from nearby chests, exactly like crafting.
      * If a top-up ever takes ingredients from your BACKPACK, the station
        stops (chest stock ran out) so your inventory is never drained.
      * Cancelling/removing an item from the station's queue by hand
        stops tracking that station.

    Hotkeys
      Ctrl+F5  -> toggle tracking of the nearest station
      Ctrl+F11 -> list tracked stations in the log

    Log: ...\Win64\ue4ss\UE4SS.log  (lines starting with [AutoStation])
--]]

------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------
local Config = {
    TickMs        = 3000,  -- how often tracked stations are checked
    ChestRadius   = 1500,  -- cm (15 m) around the station
    ActiveRadius  = 4000,  -- cm (40 m): only stations this close to you work
    MaxFeedsPerTick = 3,   -- queue entries added per station per tick
    Verbose       = true,  -- log every move (beta: on)
}
------------------------------------------------------------------

local VERSION = "1.0.0-beta"
local TAG = "[AutoStation] "
local function log(m) print(TAG .. m .. "\n") end
local function vlog(m) if Config.Verbose then log(m) end end

local STATIONS = {
    "BP_Quern_C", "BP_Smelter_C", "BP_Kiln_C", "BP_SpinningWheel_C", "BP_CookingStation_C",
    "BP_Refinery_C", "BP_GlueFactory_C", "BP_PaintMixer_C", "BP_DryingRack_C",
    "BP_EverChar_Grill_C", "BP_MashBowl_C",
}

-- tracked[stationFullName] = { station=obj, recipeTable=obj, recipeName=FName, label=string, busy=false }
local Tracked = {}
local Suppress = 0     -- >0 while our own calls run (hooks must ignore them)

------------------------------------------------------------------
-- helpers
------------------------------------------------------------------
local function valid(o)
    local ok, r = pcall(function() return o ~= nil and o:IsValid() end)
    return ok and r
end
local function try(f, d)
    local ok, v = pcall(f)
    if ok and v ~= nil then return v end
    return d
end
local function loc(a) return try(function() return a:K2_GetActorLocation() end) end
local function dist(a, b)
    if not a or not b then return 1e12 end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
local function nameOf(o) return try(function() return o:GetFullName() end, "?") end
local function rowOf(item) return try(function() return item.ItemDataRowHandle.RowName:ToString() end, "?") end
local function stackOf(item) return try(function() return item.StackSize end, 0) end

local function forEachItem(inv, fn)
    if not valid(inv) then return end
    pcall(function() inv.Items:ForEach(function(_, it) local i = it:get(); if valid(i) then fn(i) end end) end)
end

local function localPC()
    for _, pc in ipairs(FindAllOf("SurvivalPlayerController") or {}) do
        if valid(pc) and try(function() return pc:IsLocalController() end, true) then return pc end
    end
end
local function playerInv(pc) return try(function() return pc.Pawn.InventoryComponent end) end

local function backpackCounts(pc)
    local t = {}
    forEachItem(playerInv(pc), function(i) local r = rowOf(i); t[r] = (t[r] or 0) + stackOf(i) end)
    return t
end

local function productionList(st)
    local list = {}
    pcall(function()
        st.ProductionItems:ForEach(function(_, p)
            local pi = p:get()
            list[#list + 1] = {
                item = pi.Item,
                row = rowOf(pi.Item),
                count = stackOf(pi.Item),
                recipeTable = try(function() return pi.RecipeRowHandle.DataTable end),
                recipeName = try(function() return pi.RecipeRowHandle.RowName end),
                recipeLabel = try(function() return pi.RecipeRowHandle.RowName:ToString() end, "?"),
            }
        end)
    end)
    return list
end

-- chest cache (refreshed every 30 s)
local ChestCache, ChestCacheAt = {}, 0
local function allChests()
    local now = os.time()
    if now - ChestCacheAt > 30 then
        ChestCache = {}
        for _, st in ipairs(FindAllOf("StorageBuilding") or {}) do
            if valid(st) then
                ChestCache[#ChestCache + 1] = { st = st, pos = loc(st), inv = try(function() return st.InventoryComponent end) }
            end
        end
        ChestCacheAt = now
    end
    return ChestCache
end

local function chestHolding(pos, row)
    local best, bestD
    for _, c in ipairs(allChests()) do
        if valid(c.st) and valid(c.inv) then
            local d = dist(pos, c.pos)
            if d <= Config.ChestRadius and (not bestD or d < bestD) then
                local has = false
                forEachItem(c.inv, function(i) if not has and rowOf(i) == row then has = true end end)
                if has then best, bestD = c, d end
            end
        end
    end
    return best
end

------------------------------------------------------------------
-- tracking
------------------------------------------------------------------
local function track(st, recipeTable, recipeName, why)
    if not valid(st) or not recipeName then return end
    local key = nameOf(st)
    local label = try(function() return recipeName:ToString() end, "?")
    local cur = Tracked[key]
    if cur and cur.label == label then return end
    Tracked[key] = { station = st, recipeTable = recipeTable, recipeName = recipeName, label = label }
    log(string.format("tracking %s -> %s (%s)", try(function() return st:GetClass():GetFName():ToString() end, "?"), label, why))
end

local function untrack(key, why)
    local t = Tracked[key]
    if not t then return end
    Tracked[key] = nil
    log(string.format("stopped %s -> %s (%s)", key:match("([%w_]+)$") or key, t.label, why))
end

------------------------------------------------------------------
-- work
------------------------------------------------------------------
-- Move finished items to a chest that already holds them. Uses the game's
-- own "take" (into the backpack) and then moves ONLY that amount.
local function collect(pc, t, pos)
    local st = t.station
    for _, p in ipairs(productionList(st)) do
        if try(function() return st:IsItemFinished(p.item) end, false) then
            local dest = chestHolding(pos, p.row)
            if not dest then return end -- nowhere to put it: leave it in the station
            local before = backpackCounts(pc)[p.row] or 0
            Suppress = Suppress + 1
            local ok = pcall(function() pc:ServerTryGetProductionItem(st, p.item) end)
            Suppress = Suppress - 1
            if not ok then return end
            -- after the take lands in the backpack, move exactly what came out
            ExecuteWithDelay(500, function()
                ExecuteInGameThread(function()
                    pcall(function()
                        local inv = playerInv(pc)
                        local gained = (backpackCounts(pc)[p.row] or 0) - before
                        if gained <= 0 or not valid(dest.inv) then return end
                        local moving
                        forEachItem(inv, function(i) if not moving and rowOf(i) == p.row then moving = i end end)
                        if not moving then return end
                        local okT = pcall(function() inv:ServerTransferItemTo(moving, dest.inv, math.min(gained, stackOf(moving)), false) end)
                        vlog(string.format("collected %s x%d -> chest (%s)", p.row, gained, okT and "ok" or "transfer failed"))
                    end)
                end)
            end)
            return -- one item per tick per station keeps things smooth
        end
    end
end

-- Top up the queue with the tracked recipe. Stops the station if the game
-- starts taking ingredients from the backpack (chests ran out).
local function feed(pc, t, key)
    local st = t.station
    for _ = 1, Config.MaxFeedsPerTick do
        if try(function() return st:ProductionCapacityIsFull() end, true) then return end
        local qBefore = #productionList(st)
        local bpBefore = backpackCounts(pc)
        Suppress = Suppress + 1
        local ok = pcall(function()
            pc:ServerCraftRecipeDataAtBuilding(st,
                { DataTable = t.recipeTable, RowName = t.recipeName },
                { RowName = FName("None") })
        end)
        Suppress = Suppress - 1
        if not ok then return end
        if #productionList(st) <= qBefore then
            vlog(t.label .. ": no ingredients nearby")
            return
        end
        local bpAfter = backpackCounts(pc)
        for row, n in pairs(bpBefore) do
            if (bpAfter[row] or 0) < n then
                untrack(key, "chest stock ran out - used backpack " .. row)
                return
            end
        end
        vlog(t.label .. ": queued one more")
    end
end

local function tick()
    local pc = localPC()
    if not valid(pc) then return end
    local me = loc(pc.Pawn)
    for key, t in pairs(Tracked) do
        if not valid(t.station) then
            Tracked[key] = nil
        else
            local pos = loc(t.station)
            if dist(me, pos) <= Config.ActiveRadius then
                collect(pc, t, pos)
                feed(pc, t, key)
            end
        end
    end
end

------------------------------------------------------------------
-- hooks: learn from the player's own actions
------------------------------------------------------------------
local function onManualCraft(building, recipe)
    if Suppress > 0 then return end
    local st = try(function() return building:get() end)
    local h = try(function() return recipe:get() end)
    if valid(st) and h then
        track(st, try(function() return h.DataTable end), try(function() return h.RowName end), "queued by hand")
    end
end

pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerController:ServerCraftRecipeDataAtBuilding",
        function(self, building, recipe) onManualCraft(building, recipe) end)
end)

-- Some UI paths use the variant without a recipe argument: read the queue a
-- moment later and track whatever recipe the newest entry has.
pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerController:ServerCraftRecipeAtBuilding",
        function(self, building)
            if Suppress > 0 then return end
            local st = try(function() return building:get() end)
            if not valid(st) then return end
            ExecuteWithDelay(500, function()
                ExecuteInGameThread(function()
                    pcall(function()
                        local list = productionList(st)
                        local p = list[#list]
                        if p and p.recipeName then track(st, p.recipeTable, p.recipeName, "queued by hand") end
                    end)
                end)
            end)
        end)
end)

pcall(function()
    RegisterHook("/Script/Maine.SurvivalPlayerController:ServerCancelProductionItem",
        function(self, building)
            if Suppress > 0 then return end
            local st = try(function() return building:get() end)
            if valid(st) then untrack(nameOf(st), "cancelled by hand") end
        end)
end)

------------------------------------------------------------------
-- hotkeys
------------------------------------------------------------------
local function nearestStation()
    local pc = localPC()
    if not valid(pc) then return end
    local me = loc(pc.Pawn)
    local best, bestD
    for _, c in ipairs(STATIONS) do
        for _, st in ipairs(FindAllOf(c) or {}) do
            if valid(st) then
                local d = dist(me, loc(st))
                if not bestD or d < bestD then best, bestD = st, d end
            end
        end
    end
    return best
end

RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        pcall(function()
            local st = nearestStation()
            if not st then log("no station nearby") return end
            local key = nameOf(st)
            if Tracked[key] then
                untrack(key, "hotkey")
            else
                local p = productionList(st)[1]
                if p and p.recipeName then
                    track(st, p.recipeTable, p.recipeName, "hotkey")
                else
                    log("queue a recipe on this station by hand first")
                end
            end
        end)
    end)
end)

RegisterKeyBind(Key.F11, { ModifierKey.CONTROL }, function()
    local n = 0
    for key, t in pairs(Tracked) do
        n = n + 1
        log(string.format("  #%d %s -> %s", n, key:match("([%w_]+)$") or key, t.label))
    end
    log(n .. " station(s) tracked")
end)

LoopAsync(Config.TickMs, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then log("tick error: " .. tostring(err)) end
    end)
    return false
end)

log("v" .. VERSION .. " loaded. Queue a recipe by hand once; Ctrl+F5 toggles the nearest station.")
