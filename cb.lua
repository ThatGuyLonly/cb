-- Raise A Catboy OC | v1.13 surface walking | place 129852792970565, v632.
-- Surface travel uses Roblox pathfinding and Humanoid:MoveTo.
-- No UI. Edit Settings below. Re-running replaces the previous OC instance.
-- Stop: getgenv().CatboyOC.Stop()
-- Return home once: getgenv().CatboyOC.TeleportToCafe()
local env = getgenv()
if env.Settings == nil then
    env.Settings = {
        ENABLED = true,
        AUTO_STEAL_EGGS = true,
        RARITY_FILTER = {"ALL"}, -- e.g. {"Rare", "Epic"}; empty means none.
        ZONE_FILTER = {"ALL"}, -- zone numbers or names, e.g. {1, 2, "Arcade Alley"}.
        SKIP_OUTGROWN_EGGS = true, -- once every cafe slot is occupied
        TRAIN_FOR_BETTER_EGGS = true,
        RESPECT_ZONE_SPEED = true,
        EGG_PRIORITY = "RARITY", -- RARITY or NEAREST.
        UPGRADE_EGG_RESERVE = 2, -- extra bag slots for eggs better than the weakest queued rarity
        MAX_EGGS_IN_QUEUE = 10, -- includes both carried-in inventory and growing eggs.
        AUTO_PLACE_EGGS = true,
        AUTO_HATCH = true,
        AUTO_EQUIP_BEST = true,
        AUTO_BUY_TRAIL = true,
        AUTO_GO_ON_WHEEL = true,
        AUTO_UPGRADE_WHEEL = true,
        AUTO_UPGRADE_CAFE = true,
        AUTO_CLAIM_INDEX = true,
        TELEPORT_TO_CAFE = false, -- one-shot; resets after the request is handled.
        DISABLE_GAMEPLAY_PAUSED = true,
        ANTI_AFK = true,
        MONEY_RESERVE = 0,
        WHEEL_SECONDS = 30,
        FARM_SECONDS_BETWEEN_WHEEL = 90,
        TICK_INTERVAL = 0.25,
        NOCLIP = true, -- Infinite Yield character noclip during automation.
        STOP_ON_REJECT_COUNT = false, -- pause only on a new increase while enabled.
        DEBUG = false,
        DEBUG_INTERVAL = 15,
    }
end
local Settings: any = env.Settings
assert(type(Settings) == "table", "Settings must be a table")
assert(game.PlaceId == 129852792970565, "This OC is for Raise A Catboy")
if env.CatboyOC and type(env.CatboyOC.Stop) == "function" then
    env.CatboyOC.Stop()
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local Pathfinding = game:GetService("PathfindingService")
local GuiService: any = game:GetService("GuiService")
local World: any = workspace -- StreamingIntegrityMode is absent from Real's static API definitions.
local Player = Players.LocalPlayer
local Shared = RS:WaitForChild("Shared", 20)
assert(Shared, "Shared modules have not loaded")
local Config = Shared:WaitForChild("Config", 20)
local Util = Shared:WaitForChild("Util", 20)
local Controllers = Player:WaitForChild("PlayerScripts"):WaitForChild("Client", 20):WaitForChild("Controllers", 20)
local function module(parent: Instance, name: string): any
    local object = parent:WaitForChild(name, 15)
    assert(object, "Missing module: " .. name)
    local ok, result = pcall(require, object)
    assert(ok, tostring(result))
    return result
end
local Snapshot = module(Controllers, "SnapshotController")
local Reveal = module(Controllers, "HatchRevealController")
local Placement = module(Util, "Placement")
local Catboys = module(Config, "CatboyConfig")
local SpeedConfig = module(Config, "SpeedConfig")
local ZoneConfig = module(Config, "ZoneConfig")
local RarityConfig = module(Config, "RarityConfig")
local PlotConfig = module(Config, "PlotConfig")
local PlacementConfig = module(Config, "PlacementConfig")
local Remotes = RS:WaitForChild("Remotes", 20)
assert(Remotes, "Remotes have not loaded")

local State: any = {
    Version = "1.13-pickup-and-wheel", Running = true, Status = "Starting", Errors = 0,
    Banked = 0, Lost = 0, Hatched = 0, Requests = 0,
    LastError = nil, LastNotice = nil, Settings = Settings,
    StartedAt = os.clock(), Mode = "IDLE", Capabilities = {},
}
env.CatboyOC = State
local connections: {RBXScriptConnection} = {}
local pending: any = {}
local cooldown: any = {}
local rejected: any = {}
local lastWheel = os.clock()
local move: any = nil
local cycle: any = nil
local homeRequested = false
local nextSupport = 0
local nextDebug = 0
local nextAfk = 0
local nextScan = 0
local candidate: any = nil
local areaBase: Instance? = nil
local areaEncoded: any = nil
local area: any = nil
local oldPauseMode: any = nil
local oldPauseNotice: any = nil
local pauseApplied = false
local oldKinds: any = {}
local bankAttempt: any = nil
local lastRejectCount = tonumber(Player:GetAttribute("RejectCount")) or 0

local defaults: any = {
    ENABLED=true, AUTO_STEAL_EGGS=true, RARITY_FILTER={"ALL"}, ZONE_FILTER={"ALL"},
    RESPECT_ZONE_SPEED=true, EGG_PRIORITY="RARITY", MAX_EGGS_IN_QUEUE=10,
    AUTO_PLACE_EGGS=true, AUTO_HATCH=true, AUTO_EQUIP_BEST=true, AUTO_BUY_TRAIL=true,
    AUTO_GO_ON_WHEEL=true, AUTO_UPGRADE_WHEEL=true, AUTO_UPGRADE_CAFE=true,
    AUTO_CLAIM_INDEX=true, TELEPORT_TO_CAFE=false,
    DISABLE_GAMEPLAY_PAUSED=true, ANTI_AFK=true, MONEY_RESERVE=0,
    WHEEL_SECONDS=30, FARM_SECONDS_BETWEEN_WHEEL=90, TICK_INTERVAL=0.25,
    UPGRADE_EGG_RESERVE=2, SKIP_OUTGROWN_EGGS=true, TRAIN_FOR_BETTER_EGGS=true, NOCLIP=true, STOP_ON_REJECT_COUNT=false, DEBUG=false, DEBUG_INTERVAL=15,
}
for key, value in pairs(defaults) do
    if Settings[key] == nil then Settings[key] = value end
end
local function number(key: string, fallback: number, minimum: number, maximum: number): number
    local n = tonumber(Settings[key])
    if not n or n ~= n then return fallback end
    return math.clamp(n, minimum, maximum)
end
local function status(message: string)
    State.Status = message
end
local function attr(name: string, fallback: any): any
    local value = Player:GetAttribute(name)
    if value == nil then return fallback end
    return value
end
local function carrying(): boolean
    return attr("CarryingEgg", "") ~= ""
end
local function character(): (BasePart?, Humanoid?)
    local c = Player.Character
    local r = c and c:FindFirstChild("HumanoidRootPart")
    local h = c and c:FindFirstChildOfClass("Humanoid")
    if r and r:IsA("BasePart") and h and h.Health > 0 then return r, h end
    return nil, nil
end
local function base(): Model?
    local lobby = workspace:FindFirstChild("Lobby")
    local bases = lobby and lobby:FindFirstChild("Bases")
    local b = bases and bases:FindFirstChild("Base" .. tostring(attr("PlotSlot", 0)))
    if b and b:IsA("Model") and b:GetAttribute("OwnerUserId") == Player.UserId then return b end
    return nil
end
local function snapshot(): any
    return Snapshot:Get() or {items={}, index={}, trailsOwned={}}
end
local function items(): any
    return snapshot().items or {}
end
local function findItem(id: string): any
    for _, item in pairs(items()) do if item.id == id then return item end end
    return nil
end
local function eggCount(): number
    local count = 0
    for _, item in pairs(items()) do if item.kind == "Egg" then count += 1 end end
    return count
end
local function send(name: string, payload: any, interval: number): boolean
    local now = os.clock()
    if now < (cooldown[name] or 0) then return false end
    local remote = Remotes:FindFirstChild(name)
    if not remote or not remote:IsA("RemoteEvent") then return false end
    cooldown[name] = now + interval
    if payload == nil then remote:FireServer() else remote:FireServer(payload) end
    State.Requests += 1
    return true
end
local function allowed(filter: any, value: any, label: any): boolean
    if type(filter) ~= "table" then return false end
    for key, item in pairs(filter) do
        local wanted = if type(key) == "string" and item == true then key else item
        wanted = string.lower(tostring(wanted))
        if wanted == "all" or wanted == string.lower(tostring(value)) or
            (label ~= nil and wanted == string.lower(tostring(label))) then return true end
    end
    return false
end
local brake: any = nil
local function releaseBrake()
    if brake then
        if brake.h.Parent and math.abs(brake.h.WalkSpeed-brake.applied)<0.1 then
            brake.h.WalkSpeed=brake.original
        end
        brake=nil
    end
end
local function stopMoving()
    releaseBrake()
    local r, h = character()
    if r and h then h:MoveTo(r.Position) end
    move = nil
end
local RunService = game:GetService("RunService")
local changedParts: {[BasePart]: boolean} = {}
local bodyParts: {BasePart} = {}
local trackedCharacter: Model? = nil
local added: RBXScriptConnection? = nil
local function releaseParts()
    for part in pairs(changedParts) do
        if part.Parent then part.CanCollide = true end
    end
    table.clear(changedParts)
    table.clear(bodyParts)
    if added then added:Disconnect(); added=nil end
    trackedCharacter=nil
end
table.insert(connections,RunService.Stepped:Connect(function()
    local model=Player.Character
    if not State.Running or not Settings.ENABLED or not Settings.NOCLIP or not model then
        if trackedCharacter then releaseParts() end
        return
    end
    if trackedCharacter~=model then
        releaseParts()
        trackedCharacter=model
        local function track(part: Instance)
            if part:IsA("BasePart") then table.insert(bodyParts,part) end
        end
        added=model.DescendantAdded:Connect(track)
        for _,part in ipairs(model:GetDescendants()) do track(part) end
    end
    for i=#bodyParts,1,-1 do
        local part=bodyParts[i]
        if not part:IsDescendantOf(model) then
            if changedParts[part] and part.Parent then part.CanCollide=true end
            changedParts[part]=nil
            table.remove(bodyParts,i)
        elseif part.CanCollide then
            changedParts[part]=true
            part.CanCollide=false
        end
    end
end))
-- Advance waypoints on physics updates, independently of the slower farming loop.
local function steer()
    if not move or not State.Running or not Settings.ENABLED then return end
    local r,h=character()
    if not r or not h then return end
    if State.Mode=="WHEEL" and cycle and cycle.part.Parent then
        local delta=r.Position-cycle.part.Position
        local distance=Vector2.new(delta.X,delta.Z).Magnitude
        if (attr("OnTreadmill",false) and distance<5) or (distance<1.1 and math.abs(delta.Y)<6) then
            stopMoving()
            h:Move(Vector3.zero)
            return
        end
        if distance<math.max(28,h.WalkSpeed*0.35) or brake then
            if not brake then brake={h=h,original=h.WalkSpeed,applied=h.WalkSpeed} end
            if math.abs(h.WalkSpeed-brake.applied)>0.1 then brake.original=h.WalkSpeed end
            brake.applied=math.min(brake.original,math.clamp(distance*1.4,5,60))
            h.WalkSpeed=brake.applied
        end
    elseif brake then releaseBrake() end
    local route=move.route
    local point=route and route[move.index]
    local lead=math.clamp(h.WalkSpeed*0.065,2,8)
    while point and move.index<#route do
        local delta=r.Position-point.Position
        if Vector2.new(delta.X,delta.Z).Magnitude>lead or math.abs(delta.Y)>8 then break end
        move.index+=1
        point=route[move.index]
    end
    local target=if point then point.Position else move.target
    if target~=move.command or os.clock()>=move.refresh then
        if point and point.Action==Enum.PathWaypointAction.Jump then h.Jump=true end
        h:MoveTo(target)
        move.command=target
        move.refresh=os.clock()+5
    end
end
table.insert(connections,RunService.Heartbeat:Connect(steer))
local function go(target: Vector3)
    releaseBrake()
    local r, h = character()
    if not r or not h then return end
    local route = nil
    if (r.Position-target).Magnitude > 8 then
        local path = Pathfinding:CreatePath({AgentRadius=2.5,AgentHeight=6,AgentCanJump=true,WaypointSpacing=18})
        local ok, err = pcall(function() path:ComputeAsync(r.Position,target) end)
        if not State.Running then return end
        if ok and path.Status == Enum.PathStatus.Success then
            route = path:GetWaypoints()
        else State.LastPathError = tostring(err or path.Status) end
    end
    move = {target=target, route=route, index=2, started=os.clock(), refresh=0,
        lastPosition=r.Position, lastProgress=os.clock()}
    steer()
end
local function movementStep(): string
    if not move then return "done" end
    if move.blocked then move=nil; return "failed" end
    local r, h = character()
    if not r or not h then return "wait" end
    local now = os.clock()
    local delta = r.Position - move.target
    if Vector2.new(delta.X, delta.Z).Magnitude < (if State.Mode=="WHEEL" then 1.1 else 4) and math.abs(delta.Y) < 9 then
        stopMoving()
        return "done"
    end
    if (r.Position - move.lastPosition).Magnitude > 1 then
        move.lastProgress = now
        move.lastPosition = r.Position
    end
    if now - move.lastProgress > 3 and now - move.lastProgress < 5 then h.Jump = true end
    if now - move.lastProgress > 8 or now - move.started > 120 then
        stopMoving()
        return "failed"
    end
    return "moving"
end
local function homeTarget(): Vector3?
    local b = base()
    local spawn = b and b:FindFirstChild("Spawn")
    if spawn and spawn:IsA("BasePart") then return spawn.Position + Vector3.new(0, 3, 0) end
    return nil
end
local function goHome(mode: string)
    local target = homeTarget()
    if not target then status("Waiting for café"); return end
    State.Mode = mode
    go(target)
end
local function ownAnchors(): any
    local result = {}
    for _, v in ipairs(CS:GetTagged("Placed")) do
        if v:IsA("BasePart") and v:GetAttribute("OwnerUserId") == Player.UserId then
            table.insert(result, v)
        end
    end
    return result
end
local function freePosition(): (number?, number?)
    local b = base()
    local floor = b and b:FindFirstChild("Floor")
    if not b or not floor or not floor:IsA("BasePart") then return nil, nil end
    local encoded = b:GetAttribute("PlacementArea")
    if b ~= areaBase or encoded ~= areaEncoded then
        area = Placement.Decode(encoded)
        areaEncoded, areaBase = encoded, b
    end
    if not area then return nil, nil end
    local occupied = {}
    local frame = Placement.BaseFrame(floor)
    for _, v in ipairs(ownAnchors()) do
        local x, z = Placement.ToLocal(frame, v.Position)
        table.insert(occupied, {Id=v:GetAttribute("ItemId"), X=x, Z=z, R=v:GetAttribute("Radius") or 3})
    end
    return Placement.FindFree(area, 0, 0, Placement.EggRadius(), occupied, nil, 40, 2)
end
local function fillIncubators(now: number, nearOnly: boolean): boolean
    if not Settings.AUTO_PLACE_EGGS then return false end
    local growing = 0
    local waiting = {}
    for _, item in pairs(items()) do
        if item.kind == "Egg" then
            if item.placed == "floor" then growing += 1
            elseif item.placed == "" then
                table.insert(waiting, item)
            end
        end
    end
    State.BagEggs, State.PlacedEggs = #waiting, growing
    if growing >= attr("EggCap", 10) or #waiting == 0 then return false end
    for _,item in ipairs(waiting) do
        if now < (pending["place:" .. item.id] or 0) then return true end
    end
    table.sort(waiting, function(a, b)
        local ra, rb = RarityConfig.ByKey[a.rarity], RarityConfig.ByKey[b.rarity]
        return (ra and ra.Rank or 0) > (rb and rb.Rank or 0)
    end)
    local target = homeTarget()
    local r = character()
    if not r or not target then return false end
    if (r.Position - target).Magnitude > 20 then
        if nearOnly then return false end
        goHome("PLACE_HOME")
        status("Returning to place eggs")
        return true
    end
    stopMoving()
    State.Mode = "IDLE"
    local x, z = freePosition()
    if not x then status("No free café floor space"); return false end
    local item = waiting[1]
    if send("RequestPlaceAt", {itemId=item.id, x=x, z=z, yaw=0}, 0.8) then
        pending["place:" .. item.id] = now + 4
        status("Placing " .. tostring(item.rarity) .. " egg")
    end
    return true
end
local function readyEgg(): boolean
    for _, item in pairs(items()) do
        if item.kind == "Egg" and item.placed == "floor" and tonumber(item.growRemaining) == 0 then return true end
    end
    for _, anchor in ipairs(ownAnchors()) do
        if anchor:GetAttribute("ItemKind") == "Egg" and anchor:GetAttribute("State") == "Ready" then return true end
    end
    return false
end
local gameState = RS:WaitForChild("GameState", 15)
local reopenUntil = 0
local lastPhase: any = nil
local function refreshPhase()
    if not gameState then return end
    local phase = gameState:GetAttribute("Phase")
    if phase ~= lastPhase then
        if phase == "Reopening" or (phase == "Day" and (lastPhase == "Night" or lastPhase == "Reopening")) then
            reopenUntil = os.clock() + 8
            nextScan = 0
            candidate = nil
        end
        lastPhase = phase
        State.Phase = phase
    end
end
if gameState then
    refreshPhase()
    table.insert(connections, gameState:GetAttributeChangedSignal("Phase"):Connect(refreshPhase))
end
local function hatchWindow(now: number): boolean
    refreshPhase()
    if not gameState or lastPhase=="Reopening" or now<reopenUntil then return false end
    local endsAt=tonumber(gameState:GetAttribute("PhaseEndsAt"))
    if not endsAt or endsAt-workspace:GetServerTimeNow()<=5 then return false end
    return lastPhase=="Night" or (lastPhase=="Day" and attr("OnTreadmill",false)==true)
end
local function hatch(now: number): boolean
    if not Settings.AUTO_HATCH or not hatchWindow(now) or Reveal:IsRevealing() or now<(State.HatchUntil or 0) then return false end
    for _, v in ipairs(ownAnchors()) do
        if v:GetAttribute("ItemKind") == "Egg" and
            (v:GetAttribute("Ready") == true or v:GetAttribute("State") == "Ready") then
            local id = v:GetAttribute("ItemId")
            if type(id) == "string" and now >= (pending["hatch:" .. id] or 0) then
                if send("RequestHatchEgg", {itemId=id}, 0.8) then
                    pending["hatch:" .. id] = now + 5
                    State.HatchUntil = now + 1.5
                    return true
                end
                return false
            end
        end
    end
    -- The snapshot is also authoritative; do not extrapolate its countdown.
    for _, item in pairs(items()) do
        if item.kind == "Egg" and item.placed == "floor" and tonumber(item.growRemaining) == 0 and
            now >= (pending["hatch:" .. item.id] or 0) then
            if send("RequestHatchEgg", {itemId=item.id}, 0.8) then
                pending["hatch:" .. item.id] = now + 5
                State.HatchUntil = now + 1.5
                return true
            end
            return false
        end
    end
    return false
end
local function support(now: number)
    if now < nextSupport then return end
    nextSupport = now + 1
    for key, deadline in pairs(pending) do
        if now > deadline + 60 then pending[key] = nil end
    end
    local snap = snapshot()
    local currentKinds = {}
    for _, item in pairs(snap.items or {}) do
        currentKinds[item.id] = item.kind
        if oldKinds[item.id] == "Egg" and item.kind == "Catboy" then State.Hatched += 1 end
    end
    oldKinds = currentKinds
    if Settings.AUTO_CLAIM_INDEX then
        for _, value in pairs(snap.index or {}) do
            if value == 1 then send("RequestIndexClaim", {}, 5); break end
        end
    end
    if Settings.AUTO_EQUIP_BEST and not carrying() then
        local hasCatboy = false
        for _, item in pairs(snap.items or {}) do if item.kind == "Catboy" then hasCatboy = true; break end end
        if hasCatboy then send("RequestEquipBest", {}, 12) end
    end
    local budget = attr("Money", 0) - number("MONEY_RESERVE", 0, 0, 1e30)
    -- At most one purchase per pass; observe the server balance before the next.
    if Settings.AUTO_UPGRADE_CAFE then
        for _, row in ipairs(PlotConfig.Pen.Levels) do
            if row.Level == attr("PenLevel", 0) + 1 and row.Cost <= budget then
                if send("RequestShop", {action="UpgradePen"}, 3) then return end
            end
        end
    end
    if Settings.AUTO_UPGRADE_WHEEL and attr("PenLevel", 0) >= 1 then
        for _, row in ipairs(SpeedConfig.Treadmills) do
            if row.Tier == attr("TreadmillTier", 0) + 1 and row.Cost <= budget then
                if send("RequestShop", {action="BuyTreadmill"}, 3) then return end
            end
        end
    end
    if Settings.AUTO_BUY_TRAIL then
        local owned = snap.trailsOwned or {}
        local bestOwned: any = nil
        local bestBuy: any = nil
        for _, row in ipairs(SpeedConfig.Trails) do
            if owned[row.Key] then
                if not bestOwned or row.Mult > bestOwned.Mult then bestOwned = row end
            elseif row.Cost <= budget and (not bestBuy or row.Mult > bestBuy.Mult) then bestBuy = row end
        end
        if bestBuy and (not bestOwned or bestBuy.Mult > bestOwned.Mult) then
            send("RequestShop", {action="BuyTrail", key=bestBuy.Key}, 3)
        elseif bestOwned and attr("TrailEquipped", "") ~= bestOwned.Key then
            send("RequestShop", {action="EquipTrail", key=bestOwned.Key}, 3)
        end
    end
end
local lockedCandidate: any = nil
local function cafeThreshold(): number
    if not Settings.SKIP_OUTGROWN_EGGS then return 0 end
    local slots = 0
    for _,level in ipairs(PlotConfig.Pen.Levels) do
        if level.Level == attr("PenLevel",0) then slots=level.Pods; break end
    end
    local count, weakest = 0, math.huge
    for _,item in pairs(items()) do
        if item.kind=="Catboy" and item.placed=="floor" then
            local row=Catboys.ById[item.catboyId]
            if not row then return 0 end
            count+=1
            weakest=math.min(weakest,row.Income)
        end
    end
    return if slots>0 and count>=slots then weakest else 0
end
local ceilings: any = {}
for rarity,rows in pairs(Catboys.ByRarity) do
    local maximum=0
    for _,row in ipairs(rows) do maximum=math.max(maximum,row.Income or 0) end
    ceilings[rarity]=maximum
end
local function chooseEgg(now: number): any
    if now < nextScan then return candidate end
    nextScan = now + 0.4
    candidate = nil
    lockedCandidate = nil
    local threshold=cafeThreshold()
    State.MinUpgradeIncome=threshold
    local r = character()
    if not r then return nil end
    local bestScore = -math.huge
    for _, egg in ipairs(CS:GetTagged("WorldEgg")) do
        if egg:IsA("Model") and egg.Parent and (egg:GetAttribute("CarriedBy") or 0) == 0 and
            now >= (rejected[egg] or 0) then
            local zone = egg:GetAttribute("ZoneIndex")
            local rarity = egg:GetAttribute("Rarity")
            local row = ZoneConfig.Zones[zone]
            if row and allowed(Settings.ZONE_FILTER, zone, row.Name) and
                allowed(Settings.RARITY_FILTER, rarity, nil) and
                (threshold==0 or egg:GetAttribute("IsSpecial")==true or (ceilings[rarity] or math.huge)>threshold) then
                local prompt = egg:FindFirstChildWhichIsA("ProximityPrompt", true)
                if prompt and prompt.Enabled and prompt.MaxActivationDistance > 0 then
                    local distance = (egg:GetPivot().Position - r.Position).Magnitude
                    local rankRow = RarityConfig.ByKey[rarity]
                    local rank = rankRow and rankRow.Rank or 0
                    local score = if Settings.EGG_PRIORITY == "NEAREST" then -distance else rank * 100000 - distance
                    local option={egg=egg,prompt=prompt,rarity=rarity,zone=zone,rank=rank,speed=row.RequiredSpeed}
                    if Settings.RESPECT_ZONE_SPEED and attr("Speed",0)<row.RequiredSpeed then
                        if not lockedCandidate or rank>lockedCandidate.rank or (rank==lockedCandidate.rank and row.RequiredSpeed<lockedCandidate.speed) then
                            lockedCandidate=option
                        end
                    elseif score > bestScore then
                        bestScore = score
                        candidate = option
                    end
                end
            end
        end
    end
    for egg, deadline in pairs(rejected) do
        if now > deadline or not egg.Parent then rejected[egg] = nil end
    end
    return candidate
end
local function beginBank()
    local r = character()
    local corridor = workspace:FindFirstChild("Corridor")
    local line = corridor and corridor:FindFirstChild("RedeemLine")
    if not r or not line or not line:IsA("BasePart") then status("Waiting for redeem line"); return end
    if not bankAttempt then
        local knownIds = {}
        for _, item in pairs(items()) do knownIds[item.id] = true end
        bankAttempt = {knownIds=knownIds, started=os.clock(), egg=cycle and cycle.egg}
    end
    -- Return on the lobby side of the line; its long axis spans the corridor.
    local home = homeTarget()
    local axisX = line.Size.X < line.Size.Z
    local target: Vector3
    if axisX then
        local sign = if home and home.X > line.Position.X then 1 else -1
        target = Vector3.new(line.Position.X + sign * (line.Size.X / 2 + 9), r.Position.Y,
            math.clamp(r.Position.Z, line.Position.Z-line.Size.Z/2+5, line.Position.Z+line.Size.Z/2-5))
    else
        local sign = if home and home.Z > line.Position.Z then 1 else -1
        target = Vector3.new(math.clamp(r.Position.X, line.Position.X-line.Size.X/2+5, line.Position.X+line.Size.X/2-5),
            r.Position.Y, line.Position.Z + sign * (line.Size.Z/2+9))
    end
    State.Mode = "BANK"
    go(target)
    status("Returning egg to redeem line")
end
local function wheel(now: number): boolean
    if not Settings.AUTO_GO_ON_WHEEL or attr("TreadmillTier", 0) < 1 then return false end
    local b = base()
    local part = b and b:FindFirstChild("Treadmill")
    if not part or not part:IsA("BasePart") then return false end
    cycle = {untilTime=now + number("WHEEL_SECONDS", 30, 5, 3600), part=part}
    State.Mode = "WHEEL"
    go(part.Position + Vector3.new(0, part.Size.Y/2+3, 0))
    status("Training on wheel")
    return true
end
local function configurePause()
    if Settings.DISABLE_GAMEPLAY_PAUSED and not pauseApplied then
        pcall(function() oldPauseMode = World.StreamingIntegrityMode end)
        pcall(function() oldPauseNotice = GuiService:GetGameplayPausedNotificationEnabled() end)
        local ok, err = pcall(function() World.StreamingIntegrityMode = Enum.StreamingIntegrityMode.Disabled end)
        State.Capabilities.DisableStreamingPause = ok
        State.Capabilities.StreamingPauseError = if ok then nil else tostring(err)
        State.Capabilities.HidePauseNotice = pcall(function() GuiService:SetGameplayPausedNotificationEnabled(false) end)
        pauseApplied = true
    elseif not Settings.DISABLE_GAMEPLAY_PAUSED and pauseApplied then
        if oldPauseMode then pcall(function() World.StreamingIntegrityMode = oldPauseMode end) end
        if oldPauseNotice ~= nil then pcall(function() GuiService:SetGameplayPausedNotificationEnabled(oldPauseNotice) end) end
        pauseApplied = false
    end
end
function State.TeleportToCafe()
    homeRequested = true
end
function State.Stop()
    State.Running = false
    releaseParts()
    stopMoving()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
    if pauseApplied then
        if oldPauseMode then pcall(function() World.StreamingIntegrityMode = oldPauseMode end) end
        if oldPauseNotice ~= nil then pcall(function() GuiService:SetGameplayPausedNotificationEnabled(oldPauseNotice) end) end
    end
    status("Stopped")
end
table.insert(connections, Player.Idled:Connect(function()
    if State.Running and Settings.ANTI_AFK then
        pcall(function()
            local user: any = game:GetService("VirtualUser")
            user:CaptureController()
            user:ClickButton2(Vector2.zero)
        end)
    end
end))
local notify = Remotes:FindFirstChild("Notify")
if notify and notify:IsA("RemoteEvent") then
    table.insert(connections, notify.OnClientEvent:Connect(function(...)
        State.LastNotice = {...}
    end))
end
local teleportEvent = Remotes:FindFirstChild("TeleportTo")
if teleportEvent and teleportEvent:IsA("RemoteEvent") then
    table.insert(connections, teleportEvent.OnClientEvent:Connect(function(payload)
        local root=character()
        State.LastReturnOrigin=if root then tostring(root.Position) else nil
        State.LastReturnMode=State.Mode
        State.ServerReturnCount=(State.ServerReturnCount or 0)+1
        if State.Mode=="EGG" then
            local previous=State.LastEggReturnAt
            State.LastEggReturnAt=os.clock()
            if previous and os.clock()-previous<60 then
                Settings.ENABLED=false
                State.PauseReason="Paused after two server returns while approaching eggs"
                stopMoving()
            end
        end
        State.LastServerTeleport = payload
        State.ServerTeleportAt = os.clock()
    end))
end
table.insert(connections, Player.CharacterAdded:Connect(function()
    move, cycle, bankAttempt, candidate = nil, nil, nil, nil
    State.Mode = "IDLE"
end))

local function tick(now: number)
    configurePause()
    if Settings.ANTI_AFK and now >= nextAfk then
        nextAfk = now + 60
        send("ActivityPing", nil, 30)
    end
    local count = tonumber(attr("RejectCount", 0)) or 0
    local previous = lastRejectCount
    lastRejectCount = count
    State.RejectCount = count
    if Settings.ENABLED and Settings.STOP_ON_REJECT_COUNT and count > previous then
        Settings.ENABLED = false
        State.PauseReason = string.format("Paused because RejectCount increased from %d to %d", previous, count)
    end
    if not Settings.ENABLED then
        stopMoving()
        State.Mode = "IDLE"
        status(State.PauseReason or "Paused by settings")
        return
    end
    State.PauseReason = nil
    if attr("DataLoaded", false) ~= true then status("Waiting for player data"); return end
    local r, h = character()
    if not r or not h then status("Waiting for respawn"); return end
    support(now)
    if Settings.TELEPORT_TO_CAFE then
        Settings.TELEPORT_TO_CAFE = false
        homeRequested = true
    end
    if bankAttempt and not carrying() then
        bankAttempt.cleared = bankAttempt.cleared or now
        local bankedId = nil
        for _, item in pairs(items()) do
            if item.kind == "Egg" and not bankAttempt.knownIds[item.id] then bankedId = item.id; break end
        end
        if bankedId then
            State.Banked += 1
            State.LastBankedItem = bankedId
            bankAttempt = nil
            stopMoving()
            State.Mode = "IDLE"
        elseif now - bankAttempt.cleared > 2 then
            State.Lost += 1
            if bankAttempt.egg then rejected[bankAttempt.egg] = now + 45 end
            candidate = nil
            State.LastFailedReturn = {elapsed=now-bankAttempt.started, position=tostring(r.Position)}
            bankAttempt = nil
            stopMoving()
            State.Mode = "IDLE"
        else return end
    end
    local c = Player.Character
    if c and c:GetAttribute("Ragdolled") == true then
        stopMoving()
        State.Mode = "IDLE"
        status("Recovering from guard catch")
        return
    end
    if State.ServerTeleportAt and now-State.ServerTeleportAt < 1.5 then
        stopMoving()
        State.Mode = "IDLE"
        status("Waiting for game-controlled return")
        return
    end
    if carrying() and State.Mode ~= "BANK" then beginBank(); return end
    if State.Mode == "BANK" then
        local result = movementStep()
        if result == "failed" or (result == "done" and carrying()) then
            if bankAttempt and now - bankAttempt.started > 120 then
                Settings.ENABLED = false
                State.LastError = "Could not bank carried egg; paused for manual recovery"
                State.PauseReason = State.LastError
                status(State.LastError)
            else beginBank() end
        end
        return
    end
    if homeRequested then
        homeRequested = false
        goHome("HOME_REQUEST")
        status("Returning to café")
        return
    end
    refreshPhase()
    local opening = lastPhase=="Reopening" or now<reopenUntil
    if opening and State.Mode=="PLACE_HOME" then stopMoving(); State.Mode="IDLE" end
    if State.Mode~="HOME_REQUEST" and Settings.AUTO_STEAL_EGGS and
        #items()<attr("BagLimit",100) then
        local chosen=chooseEgg(now)
        local count=eggCount()
        local limit=number("MAX_EGGS_IN_QUEUE",10,1,100)
        if count>=limit then
            local weakest=math.huge
            for _,item in pairs(items()) do
                if item.kind=="Egg" then
                    local rarity=RarityConfig.ByKey[item.rarity]
                    weakest=math.min(weakest,rarity and rarity.Rank or 0)
                end
            end
            if not chosen or chosen.rank<=weakest or count>=limit+number("UPGRADE_EGG_RESERVE",2,0,10) then chosen=nil end
        end
        local canTrain=Settings.TRAIN_FOR_BETTER_EGGS and Settings.AUTO_GO_ON_WHEEL and attr("TreadmillTier",0)>0
        local train=count<limit and canTrain and lockedCandidate and lockedCandidate.egg.Parent and
            not chosen
        if not opening and train and State.Mode~="EGG" and fillIncubators(now,false) then return end
        if train then
            State.TrainingTarget=lockedCandidate.speed
            State.TrainingZone=lockedCandidate.zone
            if State.Mode~="WHEEL" and wheel(now) then return end
            if State.Mode=="WHEEL" then
                cycle.untilTime=now+5
                chosen=nil
            end
        else
            State.TrainingTarget=nil
        end
        if chosen and chosen.egg.Parent and (State.Mode~="EGG" or
            not cycle or not cycle.egg.Parent or chosen.rank>(cycle.rank or 0)) then
            stopMoving()
            cycle={egg=chosen.egg,prompt=chosen.prompt,rank=chosen.rank,nextPrompt=now+0.7,deadline=now+90}
            State.Mode="EGG"
            local distance=math.clamp(chosen.prompt.MaxActivationDistance-2,2,8)
            go(chosen.egg:GetPivot().Position+Vector3.new(-distance,1.5,0))
            status("Collecting "..tostring(chosen.rarity).." in zone "..tostring(chosen.zone))
            return
        end
    else
        State.TrainingTarget=nil
    end
    if State.Mode=="PLACE_HOME" then
        local result=movementStep()
        if result=="done" or result=="failed" then State.Mode="IDLE" end
        return
    end

    if not opening and State.Mode~="HOME_REQUEST" and State.Mode~="EGG" and fillIncubators(now,true) then return end
    if lastPhase=="Night" and State.Mode~="HOME_REQUEST" and State.Mode~="EGG" and Settings.AUTO_HATCH and hatchWindow(now) and readyEgg() then
        if hatch(now) then status("Hatching during night"); return end
    end
    if State.Mode == "HOME" or State.Mode == "HOME_REQUEST" then
        local result = movementStep()
        if result ~= "moving" and result ~= "wait" then State.Mode = "IDLE" end
        return
    end
    if State.Mode == "EGG" then
        if not cycle or not cycle.egg.Parent or not cycle.prompt.Parent or (cycle.egg:GetAttribute("CarriedBy") or 0)~=0 then
            stopMoving(); State.Mode = "IDLE"; return
        end
        if not Settings.AUTO_STEAL_EGGS then stopMoving(); State.Mode = "IDLE"; return end
        local result = movementStep()
        if result == "failed" or now > cycle.deadline then
            rejected[cycle.egg] = now + 30
            candidate = nil
            stopMoving(); State.Mode = "IDLE"; return
        end
        if result == "done" and now >= cycle.nextPrompt then
            local part = cycle.prompt.Parent
            local pos = if part:IsA("Attachment") then part.WorldPosition else cycle.egg:GetPivot().Position
            if (r.Position - pos).Magnitude <= cycle.prompt.MaxActivationDistance then
                if type(fireproximityprompt) == "function" then
                    fireproximityprompt(cycle.prompt)
                else
                    cycle.prompt:InputHoldBegin()
                    task.wait(cycle.prompt.HoldDuration + 0.1)
                    cycle.prompt:InputHoldEnd()
                end
                cycle.nextPrompt = now + 1.5
            else go(pos + Vector3.new(-3, 2, 0)) end
        end
        return
    end
    if not opening and State.Mode=="WHEEL" and fillIncubators(now,false) then return end
    if State.Mode == "WHEEL" then
        if not Settings.AUTO_GO_ON_WHEEL or not cycle or now >= cycle.untilTime then
            stopMoving(); State.Mode = "IDLE"; lastWheel = now; return
        end
        local result = movementStep()
        if result == "failed" then State.Mode = "IDLE"; lastWheel = now; return end
        if result == "done" and not attr("OnTreadmill", false) and now > (cycle.retryAt or 0) then
            cycle.retryAt = now + 0.5
            go(cycle.part.Position + Vector3.new(0, cycle.part.Size.Y/2+3, 0))
        end
        if hatchWindow(now) and readyEgg() and hatch(now) then status("Training and hatching"); return end
        status(if State.TrainingTarget then "Training for zone "..State.TrainingZone.." ("..State.TrainingTarget.." speed)" else "Training on wheel")
        return
    end
    if now < (State.HatchUntil or 0) or Reveal:IsRevealing() then
        stopMoving()
        status("Waiting for hatch reveal")
        return
    end
    if fillIncubators(now,false) then return end
    if now - lastWheel >= number("FARM_SECONDS_BETWEEN_WHEEL", 90, 5, 86400) and wheel(now) then return end
    if wheel(now) then return end
    status("Waiting for matching eggs or upgrades")
end
task.spawn(function()
    while State.Running do
        local now = os.clock()
        local ok, err = pcall(tick, now)
        if not ok then
            State.Errors += 1
            State.LastError = tostring(err)
            if Settings.DEBUG then warn("[Catboy OC] " .. tostring(err)) end
            task.wait(2)
        end
        if Settings.DEBUG and now >= nextDebug then
            nextDebug = now + number("DEBUG_INTERVAL", 15, 2, 600)
            print("[Catboy OC] " .. State.Status .. " | banked=" .. State.Banked .. " hatched=" .. State.Hatched)
        end
        task.wait(number("TICK_INTERVAL", 0.25, 0.15, 2))
    end
end)
return State
