--[[
    AutoStation v1.0.2-beta - Grounded 2 (UE4SS Lua)
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
    TickMs          = 3000,  -- how often tracked stations are checked
    ChestRadius     = 1500,  -- cm (15 m) around the station
    ActiveRadius    = 4000,  -- cm (40 m): only stations this close to you work
    MaxFeedsPerTick = 2,     -- queue entries added per station per tick
    StationsPerTick = 3,     -- stations handled per tick (round-robin)
    IdleSeconds     = 30,    -- rest time for a station with no ingredients nearby
    Verbose         = false, -- log every move
}
------------------------------------------------------------------

local VERSION = "1.0.2-beta"
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
local Pending = nil    -- finished item in transit (backpack -> chest), done next tick
local CheckLater = {}  -- stations queued by hand through the no-recipe variant

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
    if cur and cur.label == label then
        cur.sleepUntil, cur.idle = 0, false -- queued by hand again: wake it up
        return
    end
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
    -- Step 1 of 2: take ONE finished item into the backpack. The move to the
    -- chest happens on the next tick (no delayed callbacks).
    if Pending then return end
    local st = t.station
    for _, p in ipairs(productionList(st)) do
        if try(function() return st:IsItemFinished(p.item) end, false) then
            local dest = chestHolding(pos, p.row)
            if not dest then return end -- nowhere to put it: leave it in the station
            local before = backpackCounts(pc)[p.row] or 0
            Suppress = Suppress + 1
            local ok = pcall(function() pc:ServerTryGetProductionItem(st, p.item) end)
            Suppress = Suppress - 1
            if ok then Pending = { row = p.row, before = before, dest = dest } end
            return
        end
    end
end

-- Step 2 of 2: move exactly what came out of the station into the chest.
local function finishPending(pc)
    local job = Pending
    Pending = nil
    if not job then return end
    local inv = playerInv(pc)
    local gained = (backpackCounts(pc)[job.row] or 0) - job.before
    if gained <= 0 or not valid(job.dest.inv) then return end
    local moving
    forEachItem(inv, function(i) if not moving and rowOf(i) == job.row then moving = i end end)
    if not moving then return end
    local okT = pcall(function() inv:ServerTransferItemTo(moving, job.dest.inv, math.min(gained, stackOf(moving)), false) end)
    vlog(string.format("stored %s x%d (%s)", job.row, gained, okT and "ok" or "transfer failed"))
end

-- Total of `row` in chests near `pos`.
local function chestTotal(pos, row)
    local total = 0
    for _, c in ipairs(allChests()) do
        if valid(c.st) and valid(c.inv) and dist(pos, c.pos) <= Config.ChestRadius then
            forEachItem(c.inv, function(i) if rowOf(i) == row then total = total + stackOf(i) end end)
        end
    end
    return total
end

-- Move `amount` of `row` from chests near `pos` into the backpack.
-- Returns true when the full amount was moved.
local function refundFromChests(pc, pos, row, amount)
    local inv = playerInv(pc)
    if not valid(inv) then return false end
    local left = amount
    local chests = {}
    for _, c in ipairs(allChests()) do
        if valid(c.st) and valid(c.inv) then
            local d = dist(pos, c.pos)
            if d <= Config.ChestRadius then chests[#chests + 1] = { c = c, d = d } end
        end
    end
    table.sort(chests, function(a, b) return a.d < b.d end)
    for _, e in ipairs(chests) do
        local stacks = {}
        forEachItem(e.c.inv, function(i) if rowOf(i) == row then stacks[#stacks + 1] = i end end)
        for _, s in ipairs(stacks) do
            if left <= 0 then break end
            local n = math.min(left, stackOf(s))
            if n > 0 and pcall(function() e.c.inv:ServerTransferItemTo(s, inv, n, false) end) then
                left = left - n
            end
        end
        if left <= 0 then break end
    end
    if left > 0 then
        log(string.format("could only give back %d of %d %s to your backpack", amount - left, amount, row))
    else
        vlog(string.format("took %d %s from a chest instead of your backpack", amount, row))
    end
    return left <= 0
end

-- Top up the queue with the tracked recipe. If the game takes anything from
-- the backpack (chests ran out), the station is stopped.
local function feed(pc, t, key)
    local st = t.station
    local pos = loc(st)
    t.ingredients = t.ingredients or {}
    for _ = 1, Config.MaxFeedsPerTick do
        if try(function() return st:ProductionCapacityIsFull() end, true) then return end
        -- Known ingredients (learned from earlier refills): if the chests no
        -- longer hold a full batch, wait instead of letting the game dip into
        -- the backpack.
        for row, per in pairs(t.ingredients) do
            if chestTotal(pos, row) < per then
                if not t.idle then vlog(t.label .. ": chests are low on " .. row .. ", waiting") end
                t.idle = true
                t.sleepUntil = os.time() + Config.IdleSeconds
                return
            end
        end
        local qBefore = #productionList(st)
        local bpBefore = backpackCounts(pc)
        Suppress = Suppress + 1
        local ok = pcall(function()
            pc:ServerCraftRecipeDataAtBuilding(st,
                { DataTable = t.recipeTable, RowName = t.recipeName },
                { RowName = FName("None") })
        end)
        Suppress = Suppress - 1
        if not ok then t.sleepUntil = os.time() + Config.IdleSeconds return end
        if #productionList(st) <= qBefore then
            -- no ingredients nearby: rest this station for a while
            if not t.idle then vlog(t.label .. ": waiting for ingredients") end
            t.idle = true
            t.sleepUntil = os.time() + Config.IdleSeconds
            return
        end
        t.idle = false
        -- The game spends backpack ingredients before chest ones. Give back
        -- whatever it took from the backpack using the same ingredient from a
        -- nearby chest, so in the end the chest pays and the backpack is unchanged.
        local bpAfter = backpackCounts(pc)
        for row, n in pairs(bpBefore) do
            local used = n - (bpAfter[row] or 0)
            if used > 0 then
                t.ingredients[row] = math.max(t.ingredients[row] or 0, used)
                if not refundFromChests(pc, pos, row, used) then
                    untrack(key, "chests ran out of " .. row)
                    return
                end
            end
        end
    end
end

local Order, Cursor = {}, 0
local function tick()
    local pc = localPC()
    if not valid(pc) then return end

    -- finish last tick's move first; never feed while an item is in transit
    if Pending then finishPending(pc) return end

    -- stations queued by hand through the variant without a recipe argument
    if #CheckLater > 0 then
        local list = CheckLater
        CheckLater = {}
        for _, st in ipairs(list) do
            if valid(st) then
                local q = productionList(st)
                local p = q[#q]
                if p and p.recipeName then track(st, p.recipeTable, p.recipeName, "queued by hand") end
            end
        end
    end

    local me = loc(pc.Pawn)
    local now = os.time()

    -- round-robin: only a few stations per tick
    Order = {}
    for key, t in pairs(Tracked) do
        if not valid(t.station) then Tracked[key] = nil else Order[#Order + 1] = key end
    end
    table.sort(Order)
    local n = #Order
    if n == 0 then return end
    local done = 0
    for _ = 1, n do
        Cursor = Cursor % n + 1
        local key = Order[Cursor]
        local t = Tracked[key]
        if t and (t.sleepUntil or 0) <= now then
            local pos = loc(t.station)
            if dist(me, pos) <= Config.ActiveRadius then
                collect(pc, t, pos)
                if Pending then return end -- item in transit: stop here this tick
                feed(pc, t, key)
                done = done + 1
                if done >= Config.StationsPerTick then return end
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
            if valid(st) then CheckLater[#CheckLater + 1] = st end -- read on next tick
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
