-- @name Moon Defense
--[[
    Rock Fruit - Moon Defense
    Place 82878101790702 ("[Event] Moon"), a separate reserved-server place in the
    same GameId as the main game (10008473853) -- reached from GoMoon in the main
    place, which consumes 1 "Space Ticket" and opens a short-lived teleport zone
    (workspace.TeleportMoonZone) you must walk into before it despawns.

    Verified live on this place:
      - workspace attributes carry the wave state directly:
            Active, StartWave, Wave, Time (seconds left), Startin, Skip
      - The structure to defend is workspace.island.Moon.RocketTower. It has no
        Humanoid -- health is plain attributes: MaxHealth, Health, Death (bool).
      - Mobs spawn in workspace.Mob and grow in number through the wave (observed
        6 -> ~29 while watching). Every single mob shares the EXACT same
        Humanoid.WalkToPoint regardless of where it spawned -- they all converge
        on one fixed point near the tower. So there is no need to guess mob
        approach vectors: station at that shared point and fight what arrives.
      - MoonStone (the "Event Stone" currency, spent later via the main game's
        Random/Moon gacha) pays out even on a loss -- observed +2 and +4 across
        two runs where the tower or the player died before the wave ended.
      - Player attributes (Level, Sword, Melee, UseSword, UseMelee, PointItem...)
        are shared with the main place, so weapon selection works the same way.

    NOT verified (the connection here is short and drops unpredictably -- on
    player death, and apparently on some kind of time limit too):
      - What happens at the end of a wave: does Wave increment and a new one
        start automatically, or is there a manual "next wave" action?
      - Whether Auto Skills' key list (Z X C V F) is identical here -- assumed
        yes since Frame_SkillList_<tool> is present in this place's HUD too.
      - Exact effect of Death=true on the tower (assumed: run ends).
    This is a first cut built from solid partial data, not a fully proven script
    like the main farm. Watch it the first few times.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local GuiService        = game:GetService("GuiService")
local HttpService       = game:GetService("HttpService")

local LP = Players.LocalPlayer
-- Timeout, not a bare WaitForChild: this runs at the top of the script before
-- anything else (UI included), so if Remotes were ever slow to replicate this
-- would hang the whole script forever with no error and no visible UI.
-- keepHaki() already calls through Remotes inside a pcall, so a nil here just
-- means Auto Haki silently does nothing instead of the whole script dying.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

getgenv().__RFM_GEN = (getgenv().__RFM_GEN or 0) + 1
local MY_GEN = getgenv().__RFM_GEN

-- The loader should only ever run this file on PlaceId 82878101790702, but
-- verify anyway: without this, running it elsewhere silently shows plausible
-- nonsense (the main game's own workspace.Mob and an unrelated workspace.Time
-- attribute get read as if they were Moon wave state -- caught this exact thing
-- while testing the script from the main place).
local ON_MOON = game.PlaceId == 82878101790702

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------

local State = {
    AutoDefend  = false,
    AutoSkills  = false,
    AutoHaki    = false,
    AutoWeaponSwitch = false,
    -- Per-weapon-category cast keys, same structure as the main script. Fruit
    -- is wired up (UseDevilFruit, verified live -- same plain-tool-name
    -- pattern as Sword/Melee).
    WeaponSkills = {
        Melee = { Z = true, X = true, C = true, V = true, F = true },
        Sword = { Z = true, X = true, C = true, V = true, F = true },
        Fruit = { Z = true, X = true, C = true, V = true, F = true },
    },
    -- Which categories Auto Weapon Switch rotates between. Off by default for
    -- Fruit -- keeps existing Sword/Melee behaviour unchanged. A category
    -- with nothing owned for it is silently skipped regardless of this.
    SwitchWeapons = { Sword = true, Melee = true, Fruit = false },
    FastAttack  = false,
    Weapon      = "Melee",
    Distance    = 9,     -- same measured-safe hover height as the main script
    Status      = "Idle",

    -- Utils. No FPS toggle here either -- confirmed on the main game that
    -- setfpscap() is a measurable no-op on this client (RenderStepped-based fps
    -- measurement showed 373.7 fps at cap=5, same as an uncapped baseline).
    AntiAFK      = false,
    MobESP       = false,
    PlayerESP    = false,
    AutoPotion   = false,
    PotionSelect = { Rebirth = false, EXP = false, Lucky = false, Item = false, Diamond = false },
    AutoLoadSettings = false,
}

do
    local sword = tonumber(LP:GetAttribute("Sword")) or 0
    local melee = tonumber(LP:GetAttribute("Melee")) or 0
    State.Weapon = (sword >= melee) and "Sword" or "Melee"
end

local ATTACK_DELAY = 0.12
local DIST_MIN, DIST_MAX = 4, 12

local Icon = {
    swords    = "rbxassetid://10734975692",
    shield    = "rbxassetid://10734951367",
    flame     = "rbxassetid://10723376114",
    activity  = "rbxassetid://10709752035",
    gauge     = "rbxassetid://10723395708",
    star      = "rbxassetid://10734966248",
    x         = "rbxassetid://10747384394",
    minus     = "rbxassetid://10734896206",
    sword     = "rbxassetid://10734975486",
    crosshair = "rbxassetid://10709818534",
    user      = "rbxassetid://10747373176",
    settings  = "rbxassetid://10734950309",
    package   = "rbxassetid://10734909540",
    fist      = "rbxassetid://10723405508",
}

local Theme = {
    bg      = Color3.fromRGB(14, 16, 22),
    card    = Color3.fromRGB(22, 26, 35),
    cardAlt = Color3.fromRGB(28, 33, 44),
    stroke  = Color3.fromRGB(42, 48, 62),
    accent  = Color3.fromRGB(91, 140, 255),
    good    = Color3.fromRGB(74, 222, 128),
    warn    = Color3.fromRGB(250, 204, 21),
    text    = Color3.fromRGB(230, 233, 239),
    muted   = Color3.fromRGB(138, 147, 166),
}

----------------------------------------------------------------------
-- Game helpers
----------------------------------------------------------------------

local function getRoot()
    local char = LP.Character
    return char and char:FindFirstChild("HumanoidRootPart") or nil
end

local function getHumanoid()
    local char = LP.Character
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

-- Same sanity guard as the main script: refuse to chase an insane coordinate.
local function sanePos(p)
    if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z then return false end
    return math.abs(p.X) < 50000 and math.abs(p.Z) < 50000 and p.Y > -500 and p.Y < 100000
end

local function tpTo(cf)
    local root = getRoot()
    if not root then return end
    if not sanePos(cf.Position) then return end
    root.CFrame = cf
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function getTower()
    local isl = workspace:FindFirstChild("island")
    local moon = isl and isl:FindFirstChild("Moon")
    return moon and moon:FindFirstChild("RocketTower") or nil
end

-- The one thing that makes this mode simple: every mob's WalkToPoint is
-- identical, so read it off whichever mob happens to be alive right now.
local function defendPoint()
    local folder = workspace:FindFirstChild("Mob")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            local hum = m:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 and hum.WalkToPoint then
                local p = hum.WalkToPoint
                if sanePos(p) then return p end
            end
        end
    end
    -- No mobs alive right now (between waves): fall back to just outside the
    -- tower so we are in position when the next wave's mobs start converging.
    local tower = getTower()
    if tower then
        local pos = tower:GetPivot().Position
        return pos + Vector3.new(0, 0, 8)
    end
    return nil
end

-- Picks whichever mob will reach the shared convergence point soonest, not
-- whichever is nearest to the player -- distance alone under-ranks a fast mob
-- that is still far off but will out-run a closer slow one, and over-ranks a
-- close mob that is no real threat yet. Time-to-arrival (distance / WalkSpeed)
-- covers both "kill the fast ones first" and "prioritize whatever threatens
-- the tower soonest" with one metric, since every mob walks toward the same
-- point near RocketTower.
local DEFAULT_MOB_SPEED = 16 -- fallback if WalkSpeed ever reads 0 / missing

local function findPriorityMob()
    local folder = workspace:FindFirstChild("Mob")
    local point = defendPoint()
    if not folder or not point then return nil end
    local best, bestEta
    for _, m in ipairs(folder:GetChildren()) do
        local hum = m:FindFirstChildOfClass("Humanoid")
        local hrp = m:FindFirstChild("HumanoidRootPart")
        if hum and hrp and hum.Health > 0 then
            local dist = (hrp.Position - point).Magnitude
            local speed = (hum.WalkSpeed and hum.WalkSpeed > 0) and hum.WalkSpeed or DEFAULT_MOB_SPEED
            local eta = dist / speed
            if not bestEta or eta < bestEta then best, bestEta = m, eta end
        end
    end
    return best
end

-- How far to stand from a given mob so M1 actually connects. Tested live: a
-- normal Bacon lands fine around 6 studs, but the vehicle-shaped fast mobs
-- (Bacon Car / Bacon Motorcycle) need roughly 8 -- their hittable hitbox
-- clearly extends past their HumanoidRootPart the way a normal humanoid's
-- doesn't. A single fixed distance can't serve both: too close and the big
-- ones whiff, too far and the normal ones do. Deriving it from the model's
-- own bounding box instead scales automatically -- small mob, short reach;
-- big mob, longer reach -- rather than needing a per-mob-type table.
-- Bounding-box scaling alone still whiffed on Bacon Motorcycle -- its raw
-- speed likely eats into whatever margin the box-derived distance gives it,
-- the same way a plain Bacon at 20 WalkSpeed doesn't need this at all.
-- Simplest live-tested fix: give it a distance floor by name until there is a
-- better per-mob signal than "bigger box = more reach".
local NAME_MIN_DISTANCE = {
    ["Bacon Motorcycle"] = 10,
}

local function approachDistance(model)
    local ok, cf, size = pcall(function() return model:GetBoundingBox() end)
    local base = 6
    if ok and size then
        local radius = math.max(size.X, size.Z) / 2
        base = math.clamp(radius + 4, 6, 12)
    end
    local floor = NAME_MIN_DISTANCE[model.Name]
    if floor and floor > base then base = floor end

    -- One more stud of buffer on top of everything above, but only for mobs
    -- actually moving faster than a plain Bacon (WalkSpeed 20) -- normal mobs
    -- already land fine and don't need it; the Car still whiffed occasionally
    -- even after the box-derived distance, so every fast mob gets the margin,
    -- not just the ones with a name-based floor.
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum and hum.WalkSpeed and hum.WalkSpeed > DEFAULT_MOB_SPEED + 4 then
        base = base + 1
    end
    return base
end

-- Weapon categories: Sword/Melee always exist; Fruit only if the account
-- actually owns a Devil Fruit (UseDevilFruit attribute set) -- verified live,
-- same plain-tool-name-string pattern as UseSword/UseMelee.
local CATEGORY_ATTR = { Sword = "UseSword", Melee = "UseMelee", Fruit = "UseDevilFruit" }
local CATEGORY_ORDER = { "Sword", "Melee", "Fruit" }

local function toolNameFor(category)
    local attr = CATEGORY_ATTR[category]
    local name = attr and LP:GetAttribute(attr)
    return (type(name) == "string" and name ~= "") and name or nil
end

-- Categories selected in State.SwitchWeapons AND actually owned right now.
local function enabledCategories()
    local list = {}
    for _, cat in ipairs(CATEGORY_ORDER) do
        if State.SwitchWeapons[cat] and toolNameFor(cat) then
            list[#list + 1] = cat
        end
    end
    return list
end

local function equipWeapon()
    local char = LP.Character
    if not char then return end
    local wanted = toolNameFor(State.Weapon)
    if not wanted then return end
    if char:FindFirstChild(wanted) then return end
    local tool = LP.Backpack:FindFirstChild(wanted)
    local hum = getHumanoid()
    if tool and hum then pcall(function() hum:EquipTool(tool) end) end
end

local function attack()
    local char = LP.Character
    if not char then return end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return end
    pcall(function() tool:Activate() end)
end

-- Ported from the main farm script: Player.BusoHaki only reflects whether
-- haki is unlocked (always true here), not whether it's switched on --
-- Character.BusoHaki is the live on/off state, and it resets to false on
-- every respawn, which is why this needs to run continuously rather than once.
local function hakiUnlocked()
    return LP:GetAttribute("BusoHaki") == true
end

local function hakiActive()
    local char = LP.Character
    return char ~= nil and char:GetAttribute("BusoHaki") == true
end

local lastHaki = 0

local function keepHaki()
    if not State.AutoHaki then return end
    if os.clock() - lastHaki < 2 then return end

    local char = LP.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return end
    if hakiActive() then return end

    if not hakiUnlocked() then
        State.Status = "Haki not unlocked"
        return
    end

    lastHaki = os.clock()
    pcall(function()
        Remotes.Action:FireServer("Misc", "buso")
    end)
end

-- Potions -- ported from the main script; see its comment for the full story.
-- Verified live: using any inventory item is Remotes.Inventory:FireServer(
-- exactItemName), a single string argument, no confirmation needed even
-- though the normal UI shows one first. Each X2 boost's remaining time is a
-- plain player attribute in seconds (x2ExpTime, x2RebirthTime, etc).
local POTIONS = {
    { key = "Rebirth", item = "X2 Rebirth 15min.", timeAttr = "x2RebirthTime" },
    { key = "EXP",     item = "X2 EXP 15min.",     timeAttr = "x2ExpTime" },
    { key = "Lucky",   item = "X2 Lucky 15min.",   timeAttr = "x2LuckTime" },
    { key = "Item",    item = "X2 Item 15min.",    timeAttr = "x2ItemTime" },
    { key = "Diamond", item = "X2 Diamond 15min.", timeAttr = "x2DiamondTime" },
}
local POTION_REFRESH_AT = 20
local lastPotionCheck = 0

local function checkPotions()
    if not State.AutoPotion then return end
    if os.clock() - lastPotionCheck < 3 then return end
    lastPotionCheck = os.clock()

    local invRaw = LP:GetAttribute("Inventory")
    if type(invRaw) ~= "string" then return end
    local ok, inv = pcall(function() return HttpService:JSONDecode(invRaw) end)
    if not ok or type(inv) ~= "table" then return end

    for _, p in ipairs(POTIONS) do
        if State.PotionSelect[p.key] then
            local remaining = tonumber(LP:GetAttribute(p.timeAttr)) or 0
            if remaining <= POTION_REFRESH_AT then
                local entry = inv[p.item]
                local owned = entry and tonumber(entry.amount) or 0
                if owned > 0 then
                    pcall(function() Remotes.Inventory:FireServer(p.item) end)
                end
            end
        end
    end
end

-- Same mechanism as the main script's Auto Skills, unverified here specifically
-- but the skill panel structure (Frame_SkillList_<tool>) is present in this
-- place's HUD too.
local SKILL_KEYS = {
    { name = "Z", code = Enum.KeyCode.Z },
    { name = "X", code = Enum.KeyCode.X },
    { name = "C", code = Enum.KeyCode.C },
    { name = "V", code = Enum.KeyCode.V },
    { name = "F", code = Enum.KeyCode.F },
}

local function skillPanel()
    local char = LP.Character
    if not char then return nil end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return nil end
    local hud = LP.PlayerGui:FindFirstChild("HUD")
    local frame = hud and hud.Main:FindFirstChild("Frame_SkillList_" .. tool.Name)
    local border = frame and frame:FindFirstChild("Border")
    return border and border:FindFirstChild("Main") or nil
end

-- Which entry in State.WeaponSkills a given equipped-tool name belongs to.
local function categoryForTool(toolName)
    if type(toolName) ~= "string" or toolName == "" then return nil end
    for _, cat in ipairs(CATEGORY_ORDER) do
        if toolName == toolNameFor(cat) then return cat end
    end
    return nil
end

-- Which of the CURRENT weapon's selected skills have fired at least once
-- since it was equipped -- lets the switcher wait for every chosen skill to
-- get a turn instead of guessing from elapsed time or "is anything ready
-- right now", both of which failed live (see switchWeapons). Reset on every
-- equip, written by useSkills(), read by switchWeapons().
local usedThisEquip = {}

-- lastSkill tracks the last time ANYTHING actually fired -- kept separate
-- from lastScan below so firing several skills in one pass doesn't also
-- throttle how often this function bothers re-scanning the panel.
local lastSkill = 0
local lastScan = 0
local function useSkills()
    if not State.AutoSkills then return end
    if os.clock() - lastScan < 0.1 then return end
    lastScan = os.clock()

    local char = LP.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    local picks = tool and State.WeaponSkills[categoryForTool(tool.Name)]
    if not picks then return end

    local panel = skillPanel()
    if not panel then return end
    -- Fire every ready skill in this pass, not just the first -- a human can
    -- mash several off-cooldown hotkeys back-to-back just as fast, this was
    -- only leaving 2nd/3rd+ ready skills unused for no real reason (`return`
    -- right after the first cast, plus a 0.35s gate before trying again).
    for _, skill in ipairs(SKILL_KEYS) do
        local row = panel:FindFirstChild(skill.name)
        local ready = row and row:FindFirstChild("Ready")
        if picks[skill.name] and ready and ready.Text == "Ready" then
            lastSkill = os.clock()
            usedThisEquip[skill.name] = true
            VirtualInputManager:SendKeyEvent(true, skill.code, false, game)
            task.wait(0.06)
            VirtualInputManager:SendKeyEvent(false, skill.code, false, game)
        end
    end
end

-- Weapon Switcher: hop between Sword and Melee to use both movesets' skills,
-- since each has an independent cooldown pool -- verified on the main game
-- (switching off a partially-cooled-down weapon showed the other fully Ready,
-- and switching back showed the first untouched). Ported here because DPS
-- against the tower is the actual bottleneck, not targeting.
local function anySkillReady(toolName)
    local hud = LP.PlayerGui:FindFirstChild("HUD")
    local frame = hud and hud.Main:FindFirstChild("Frame_SkillList_" .. toolName)
    local main = frame and frame:FindFirstChild("Border") and frame.Border:FindFirstChild("Main")
    -- The game only creates Frame_SkillList_<tool> once that tool has actually
    -- been equipped -- it does not exist yet for a weapon still sitting in the
    -- Backpack. Confirmed live: a fresh Moon session that only ever equipped
    -- Sword had no Frame_SkillList_Ryusoken (melee) at all, so this returned
    -- false for melee forever and the switcher could never make its first
    -- switch to it -- needs to equip melee to see its skills, but only
    -- switches if it already sees a ready skill. Treat "panel doesn't exist
    -- yet" as worth trying rather than "definitely not ready", so the
    -- switcher can make one exploratory switch and bootstrap the panel; every
    -- check after that is a real ready/not-ready read.
    if not main then return true end
    local picks = State.WeaponSkills[categoryForTool(toolName)]
    if not picks then return false end
    for _, skill in ipairs(SKILL_KEYS) do
        if picks[skill.name] then
            local row = main:FindFirstChild(skill.name)
            local ready = row and row:FindFirstChild("Ready")
            if ready and ready.Text == "Ready" then return true end
        end
    end
    return false
end

local function equipNamed(toolName)
    local char = LP.Character
    if not char or type(toolName) ~= "string" or toolName == "" then return end
    if char:FindFirstChild(toolName) then return end
    local tool = LP.Backpack:FindFirstChild(toolName)
    local hum = getHumanoid()
    if tool and hum then pcall(function() hum:EquipTool(tool) end) end
end

-- Two earlier versions of this both failed live, in opposite directions:
--   1. Force a switch WEAPON_MAX_DWELL (3.5s) after the weapon was EQUIPPED,
--      regardless of anySkillReady(current). Cut rotations short -- with 5
--      independent-cooldown skills (confirmed live: firing Z doesn't touch
--      X/C/V/F), a weapon could still have 3-4 *other* skills genuinely
--      ready at the 3.5s mark and get switched away anyway.
--   2. Force a switch only once nothing had fired in a while (stalled = time
--      since the last successful cast). With skills on staggered ~4-6s
--      cooldowns, SOME skill is almost always about to come back ready, so
--      that almost never crossed the threshold and the switcher got stuck on
--      one weapon forever -- confirmed live, that's what "stuck on sword" was.
-- Both were guessing "exhausted" from indirect signals. Tracking directly
-- instead: usedThisEquip records every selected skill that has actually
-- fired since this weapon was equipped, so the switch condition is exact --
-- go through every chosen skill, then hand off -- rather than inferred from
-- elapsed time or momentary readiness. ROTATE_SAFETY_CAP is only a backstop
-- for a selected skill whose cooldown just never comes up in reasonable
-- time; it should rarely if ever be the thing that actually triggers a switch.
local WEAPON_MIN_GAP = 0.5
local WEAPON_MIN_DWELL = 3    -- floor on this weapon before "exhausted" is even considered,
                              -- so a long-animation skill (time stop) has room to actually
                              -- play out instead of getting cut off/cancelled by an alpha-strike
                              -- switch-back a fraction of a second after equipping.
local ROTATE_SAFETY_CAP = 12

local lastWeaponSwitch = 0
local weaponEquippedSince = 0

local function allSelectedSkillsUsed(toolName)
    local picks = State.WeaponSkills[categoryForTool(toolName)]
    if not picks then return true end
    for _, skill in ipairs(SKILL_KEYS) do
        if picks[skill.name] and not usedThisEquip[skill.name] then return false end
    end
    return true
end

-- Generalized to rotate through however many categories are both selected in
-- State.SwitchWeapons and actually owned (enabledCategories()), rather than a
-- hardcoded Sword/Melee pair -- same change as the main script.
local function switchWeapons()
    if os.clock() - lastWeaponSwitch < WEAPON_MIN_GAP then return end

    local enabled = enabledCategories()
    if #enabled == 0 then return end

    local char = LP.Character
    local current
    if char then
        for _, v in ipairs(char:GetChildren()) do if v:IsA("Tool") then current = v.Name end end
    end

    if not current then
        equipNamed(toolNameFor(State.SwitchWeapons[State.Weapon] and State.Weapon or enabled[1]))
        weaponEquippedSince = os.clock()
        usedThisEquip = {}
        return
    end

    local currentCategory = categoryForTool(current)

    if currentCategory and State.SwitchWeapons[currentCategory] then
        -- A weapon freshly equipped after sitting unused often has EVERY
        -- selected skill already off cooldown, so usedThisEquip fills up
        -- within a single useSkills() pass -- looks "exhausted" a fraction of
        -- a second after equipping. Confirmed live this is actively harmful
        -- for a long-animation skill (a "time stop" style ability): the
        -- switch away happens mid-animation, while the lockout it causes
        -- still has nothing usable, and re-equipping likely cancels the
        -- animation/effect outright. WEAPON_MIN_DWELL is an unconditional
        -- floor -- ignore how "used up" the weapon looks until at least this
        -- long has passed, regardless of ROTATE_SAFETY_CAP too.
        if os.clock() - weaponEquippedSince < WEAPON_MIN_DWELL then return end

        -- Stay only while something is actually usable RIGHT NOW and not
        -- everything selected has had its turn yet. allSelectedSkillsUsed
        -- alone was wrong: if a selected skill was already mid-cooldown from
        -- before this equip (not fired by us, so never marked used), this
        -- weapon could sit doing nothing for however long THAT skill takes
        -- to come back -- confirmed live, cost real DPS in Moon Defense
        -- waiting ~5s with both selected skills on cooldown before switching.
        -- If nothing is ready right now, there's nothing to gain by waiting
        -- on one that isn't -- move on to the other weapon instead.
        local safetyExpired = os.clock() - weaponEquippedSince > ROTATE_SAFETY_CAP
        local somethingReady = anySkillReady(current)
        if somethingReady and not allSelectedSkillsUsed(current) and not safetyExpired then return end
    end

    local startIdx = 0
    for i, cat in ipairs(enabled) do if cat == currentCategory then startIdx = i end end
    for step = 1, #enabled do
        local cat = enabled[(startIdx + step - 1) % #enabled + 1]
        local name = toolNameFor(cat)
        if name and name ~= current and anySkillReady(name) then
            lastWeaponSwitch = os.clock()
            weaponEquippedSince = os.clock()
            usedThisEquip = {}
            equipNamed(name)
            return
        end
    end
end

----------------------------------------------------------------------
-- Defend loop
----------------------------------------------------------------------

local lastAttack = 0
local lastEngageTime = 0
local defendThread

local function stepDefend()
    if not ON_MOON then
        State.Status = "Wrong place - not on the Moon"
        return
    end

    local root = getRoot()
    local hum = getHumanoid()
    if not root or not hum or hum.Health <= 0 then
        State.Status = "Waiting for character"
        return
    end

    local tower = getTower()
    if tower and tower:GetAttribute("Death") then
        State.Status = "Tower destroyed"
        return
    end

    if State.AutoWeaponSwitch then switchWeapons() else equipWeapon() end

    local point = defendPoint()
    if not point then
        State.Status = "No tower found"
        return
    end

    local mob = findPriorityMob()
    local aimAt = mob and mob:FindFirstChild("HumanoidRootPart")

    -- Chase whichever mob is actually alive and closest to arriving, wherever
    -- it currently is -- same principle as the main farm script's "always
    -- engage something real" rule. The first version tried to be clever and
    -- only engaged a mob once it wandered within 20 studs of the shared
    -- convergence point, otherwise just hovered there doing nothing;
    -- live-tested and it let the tower take unanswered damage the whole time
    -- (77% -> 44% in 14s while "Defending") because most mobs never got
    -- attacked at all. Only fall back to the convergence point when nothing
    -- is alive to fight yet.
    --
    -- Positioning used to hover State.Distance studs above/back from the mob,
    -- copied from the main farm script where that keeps stationary mobs from
    -- hitting back. Confirmed live on Moon that mobs only ever attack
    -- RocketTower, never the player, so there is nothing to keep distance
    -- from -- and that offset was exactly why fast mobs walked past without
    -- getting hit by M1: hovering above put the melee hitbox out of reach of
    -- a moving target.
    --
    -- Standing exactly on top of the mob (previous version) turned out risky
    -- live -- died shortly after switching to it, right after "mobs only
    -- attack the tower" had held up in the wave before, so overlapping a mob
    -- may expose you to something (splash/contact) that keeping just outside
    -- its hitbox does not. Now stands a few studs in front of the mob, on the
    -- side facing the shared convergence point (its own walk direction) --
    -- close enough for M1's short reach without occupying the same space.
    local anchor = aimAt and aimAt.Position or point
    local STAND_OFFSET = mob and approachDistance(mob) or 6
    local toPoint = point - anchor
    local dir = toPoint.Magnitude > 0.5 and toPoint.Unit or Vector3.new(0, 0, 1)
    local stand = anchor + dir * STAND_OFFSET + Vector3.new(0, 1, 0)
    tpTo(CFrame.lookAt(stand, anchor))

    if mob then
        State.Status = "Defending - fighting " .. mob.Name
        local now = os.clock()
        local delay = State.FastAttack and ATTACK_DELAY or (ATTACK_DELAY * 3)
        if now - lastAttack >= delay then
            lastAttack = now
            attack()
        end
        -- useSkills() fires every ready skill per pass (see its own comment),
        -- which can cost up to ~0.3s of task.wait if several go off at once.
        -- That used to run right here, inline in the same tick as tpTo()
        -- above -- confirmed live this stalls the position-pin between
        -- teleports and makes Auto Defend visibly choppy, to the point of
        -- missing kills it would otherwise land. Just mark "still actively
        -- fighting" here instead; the actual firing happens in its own loop
        -- below, decoupled from movement, same fix already applied to the
        -- main farm script for the same reason.
        lastEngageTime = os.clock()
    else
        State.Status = "Defending - waiting for mobs"
    end
end

local function startDefend()
    if defendThread then return end
    defendThread = task.spawn(function()
        while State.AutoDefend and getgenv().__RFM_GEN == MY_GEN do
            local ok, err = pcall(stepDefend)
            if not ok then State.Status = "Error: " .. tostring(err) end
            RunService.Heartbeat:Wait()
        end
        defendThread = nil
        State.Status = "Idle"
    end)
end

local function stopDefend()
    State.AutoDefend = false
end

----------------------------------------------------------------------
-- Utils (ported from the main script; see its comments for the full story)
----------------------------------------------------------------------

local antiAfkConn = nil
local function applyAntiAFK()
    if State.AntiAFK and not antiAfkConn then
        antiAfkConn = LP.Idled:Connect(function()
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
                task.wait(0.05)
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
            end)
        end)
    elseif not State.AntiAFK and antiAfkConn then
        antiAfkConn:Disconnect()
        antiAfkConn = nil
    end
end

-- ESP via Highlight (built-in Roblox Instance, no executor drawing API needed).
-- Note: mobs/bosses here only exist as objects within the wave's own spawn
-- range, same streaming limit as the main game -- ESP cannot show what has not
-- streamed in yet.
local espHighlights = {}

local function espRemove(model)
    local entry = espHighlights[model]
    if entry then
        pcall(function() entry.highlight:Destroy() end)
        pcall(function() entry.gui:Destroy() end)
        espHighlights[model] = nil
    end
end

local function espEnsure(model, color)
    if espHighlights[model] then return end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    local hl = Instance.new("Highlight")
    hl.FillColor = color
    hl.FillTransparency = 0.6
    hl.OutlineColor = color
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = model

    local gui = Instance.new("BillboardGui")
    gui.Name = "RFM_ESP"
    gui.Size = UDim2.fromOffset(160, 36)
    gui.StudsOffset = Vector3.new(0, 3, 0)
    gui.AlwaysOnTop = true
    gui.Parent = hrp

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.Text = model.Name
    label.TextColor3 = color
    label.TextSize = 14
    label.TextStrokeTransparency = 0.3
    label.Parent = gui

    espHighlights[model] = { highlight = hl, gui = gui, label = label }
end

local ESP_MOB_COLOR = Color3.fromRGB(248, 113, 113)
local ESP_PLAYER_COLOR = Color3.fromRGB(96, 165, 250)

local function updateESP()
    local root = getRoot()
    local wanted = {}

    if State.MobESP then
        local folder = workspace:FindFirstChild("Mob")
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                local hum = m:FindFirstChildOfClass("Humanoid")
                local hrp = m:FindFirstChild("HumanoidRootPart")
                if hum and hrp and hum.Health > 0 then
                    wanted[m] = true
                    espEnsure(m, ESP_MOB_COLOR)
                    local entry = espHighlights[m]
                    if entry and root then
                        local d = math.floor((hrp.Position - root.Position).Magnitude)
                        entry.label.Text = string.format("%s\n%d studs - %d%% HP",
                            m.Name, d, math.floor(100 * hum.Health / math.max(hum.MaxHealth, 1)))
                    end
                end
            end
        end
    end

    if State.PlayerESP then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP and p.Character then
                local hum = p.Character:FindFirstChildOfClass("Humanoid")
                local hrp = p.Character:FindFirstChild("HumanoidRootPart")
                if hum and hrp and hum.Health > 0 then
                    wanted[p.Character] = true
                    espEnsure(p.Character, ESP_PLAYER_COLOR)
                    local entry = espHighlights[p.Character]
                    if entry and root then
                        local d = math.floor((hrp.Position - root.Position).Magnitude)
                        entry.label.Text = string.format("%s\n%d studs", p.Name, d)
                    end
                end
            end
        end
    end

    for model in pairs(espHighlights) do
        if not wanted[model] then espRemove(model) end
    end
end

-- Settings save/load, as named presets -- same design as the main script, own
-- folder/meta file so the two never collide (different State shape; porting one
-- over the other would corrupt whichever loads second).
local SETTINGS_DIR = "MaikoHub/settings/rockfruit_moon"
local META_PATH = "MaikoHub/settings/rockfruit_moon_meta.json"
-- listfiles() proved unreliable on this Xeno client (measured returning 0
-- results for a real directory moments after correctly returning 2, with no
-- writes/deletes in between, while isfile() stayed true the whole time) -- so
-- the preset list is tracked in this manifest instead, same fix as the main script.
local INDEX_PATH = "MaikoHub/settings/rockfruit_moon_index.json"

local function ensureSettingsDir()
    pcall(function()
        if not isfolder("MaikoHub/settings") then makefolder("MaikoHub/settings") end
        if not isfolder(SETTINGS_DIR) then makefolder(SETTINGS_DIR) end
    end)
end

local function presetPath(name)
    return SETTINGS_DIR .. "/" .. name .. ".json"
end

local function readIndex()
    local ok, raw = pcall(readfile, INDEX_PATH)
    if not ok or type(raw) ~= "string" or raw == "" then return {} end
    local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
    return (decOk and type(data) == "table") and data or {}
end

local function writeIndex(names)
    pcall(function()
        writefile(INDEX_PATH, HttpService:JSONEncode(names))
    end)
end

local function indexAdd(name)
    local names = readIndex()
    for _, n in ipairs(names) do
        if n == name then return end
    end
    names[#names + 1] = name
    writeIndex(names)
end

local function indexRemove(name)
    local names = readIndex()
    local out = {}
    for _, n in ipairs(names) do
        if n ~= name then out[#out + 1] = n end
    end
    writeIndex(out)
end

local function listPresets()
    ensureSettingsDir()
    local names = readIndex()
    table.sort(names)
    return names
end

local function writeMeta(autoLoad, presetName)
    pcall(function()
        writefile(META_PATH, HttpService:JSONEncode({ autoLoad = autoLoad, preset = presetName }))
    end)
end

local function readMeta()
    local ok, raw = pcall(readfile, META_PATH)
    if not ok or type(raw) ~= "string" or raw == "" then return nil end
    local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
    return (decOk and type(data) == "table") and data or nil
end

local lastPresetName = "Default"

local function saveSettingsAs(name)
    if type(name) ~= "string" or name == "" then return false end
    ensureSettingsDir()
    local ok = pcall(function()
        local copy = {}
        for k, v in pairs(State) do
            if k ~= "Status" then copy[k] = v end
        end
        writefile(presetPath(name), HttpService:JSONEncode(copy))
    end)
    if ok then
        indexAdd(name)
        lastPresetName = name
        writeMeta(State.AutoLoadSettings, name)
    end
    return ok
end

local function deletePreset(name)
    local ok = pcall(delfile, presetPath(name))
    local gone = ok and not isfile(presetPath(name))
    if gone then indexRemove(name) end
    return gone
end

local applySettingsToUI

local function loadSettingsNamed(name)
    local ok, raw = pcall(readfile, presetPath(name))
    if not ok or type(raw) ~= "string" or raw == "" then return false end
    local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not decOk or type(data) ~= "table" then return false end

    for k, v in pairs(data) do
        if type(v) == "table" and type(State[k]) == "table" then
            for k2, v2 in pairs(v) do State[k][k2] = v2 end
        else
            State[k] = v
        end
    end
    lastPresetName = name
    writeMeta(State.AutoLoadSettings, name)
    if applySettingsToUI then applySettingsToUI() end
    applyAntiAFK()
    return true
end

do
    local meta = readMeta()
    if meta and meta.autoLoad and type(meta.preset) == "string" then
        lastPresetName = meta.preset
        local ok, raw = pcall(readfile, presetPath(meta.preset))
        if ok and type(raw) == "string" and raw ~= "" then
            local decOk, data = pcall(function() return HttpService:JSONDecode(raw) end)
            if decOk and type(data) == "table" then
                for k, v in pairs(data) do
                    if type(v) == "table" and type(State[k]) == "table" then
                        for k2, v2 in pairs(v) do State[k][k2] = v2 end
                    else
                        State[k] = v
                    end
                end
            end
        end
    elseif meta and type(meta.preset) == "string" then
        lastPresetName = meta.preset
    end
end

task.spawn(function()
    while getgenv().__RFM_GEN == MY_GEN do
        pcall(applyAntiAFK)
        pcall(keepHaki)
        pcall(checkPotions)
        if State.MobESP or State.PlayerESP or next(espHighlights) then
            pcall(updateESP)
        end
        task.wait(0.5)
    end
end)

-- useSkills() fires every ready skill per pass now, which can cost up to
-- ~0.3s of task.wait if several go off together -- own loop keeps that cost
-- off the movement thread, same fix already applied to the main farm script.
-- ENGAGE_WINDOW keeps "only cast while actually fighting a mob" without
-- needing stepDefend() to call it directly.
local ENGAGE_WINDOW = 0.5
task.spawn(function()
    while getgenv().__RFM_GEN == MY_GEN do
        if os.clock() - lastEngageTime < ENGAGE_WINDOW then
            pcall(useSkills)
        end
        task.wait(0.1)
    end
end)

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------

local parentGui = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local existing = parentGui:FindFirstChild("RockFruitMoonUI")
if existing then existing:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "RockFruitMoonUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parentGui

local PANEL_W, PANEL_H = 320, 460

local function corner(o, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 10)
    c.Parent = o
    return c
end

local function makeIcon(parent, image, color, size)
    local img = Instance.new("ImageLabel")
    img.BackgroundTransparency = 1
    img.Image = image
    img.ImageColor3 = color or Theme.muted
    img.Size = UDim2.fromOffset(size or 16, size or 16)
    img.Parent = parent
    return img
end

local root = Instance.new("Frame")
root.Name = "Root"
root.Size = UDim2.fromOffset(PANEL_W, PANEL_H)
root.Position = UDim2.new(0, 40, 0.5, -PANEL_H / 2)
root.BackgroundColor3 = Theme.bg
root.BorderSizePixel = 0
root.Parent = gui
corner(root, 14)
do
    local s = Instance.new("UIStroke")
    s.Color = Theme.stroke
    s.Parent = root
end

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 54)
header.BackgroundTransparency = 1
header.Parent = root

local logo = makeIcon(header, Icon.shield, Theme.accent, 22)
logo.Position = UDim2.fromOffset(18, 16)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(48, 11)
title.Size = UDim2.new(1, -114, 0, 16)
title.Font = Enum.Font.GothamBold
title.Text = "Moon Defense"
title.TextColor3 = Theme.text
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(48, 29)
subtitle.Size = UDim2.new(1, -114, 0, 14)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Wave --  -  Tower --%"
subtitle.TextColor3 = Theme.muted
subtitle.TextSize = 12
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(28, 28)
closeBtn.Position = UDim2.new(1, -40, 0, 13)
closeBtn.BackgroundColor3 = Theme.card
closeBtn.AutoButtonColor = false
closeBtn.Text = ""
closeBtn.Parent = header
corner(closeBtn, 9)
do
    local i = makeIcon(closeBtn, Icon.x, Theme.muted, 14)
    i.AnchorPoint = Vector2.new(0.5, 0.5)
    i.Position = UDim2.fromScale(0.5, 0.5)
end

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -36, 0, 1)
divider.Position = UDim2.fromOffset(18, 54)
divider.BackgroundColor3 = Theme.stroke
divider.BorderSizePixel = 0
divider.Parent = root

local body = Instance.new("ScrollingFrame")
body.Position = UDim2.fromOffset(0, 62)
body.Size = UDim2.new(1, 0, 1, -62)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 3
body.ScrollBarImageColor3 = Theme.stroke
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.Parent = root

local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 20)
pad.PaddingRight = UDim.new(0, 20)
pad.PaddingBottom = UDim.new(0, 18)
pad.Parent = body

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 12)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local order = 0
local function nextOrder() order = order + 1 return order end

-- Same registry pattern as the main script: every row with State-derived
-- visuals registers its render function so Load Settings can refresh the
-- whole panel in one pass.
local allRenderers = {}
local function registerRenderer(fn) allRenderers[#allRenderers + 1] = fn end
applySettingsToUI = function()
    for _, fn in ipairs(allRenderers) do pcall(fn) end
end

-- Section heading with a hairline to the right edge, ported from the main
-- script -- this panel outgrew being one undivided list of rows.
local function sectionLabel(text)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 20)
    row.BackgroundTransparency = 1
    row.LayoutOrder = nextOrder()
    row.Parent = body

    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(0, 0, 1, 0)
    l.AutomaticSize = Enum.AutomaticSize.X
    l.Font = Enum.Font.GothamBold
    l.Text = string.upper(text)
    l.TextColor3 = Theme.muted
    l.TextSize = 11
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = row

    local line = Instance.new("Frame")
    line.AnchorPoint = Vector2.new(1, 0.5)
    line.Position = UDim2.new(1, 0, 0.5, 1)
    line.Size = UDim2.new(1, -(l.TextBounds.X + 10), 0, 1)
    line.BackgroundColor3 = Theme.stroke
    line.BorderSizePixel = 0
    line.Parent = row
    task.defer(function()
        if line.Parent then line.Size = UDim2.new(1, -(l.TextBounds.X + 10), 0, 1) end
    end)
    return row
end

local function noteLabel(text, height)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, 0, 0, height or 44)
    l.Font = Enum.Font.Gotham
    l.Text = text
    l.TextColor3 = Theme.muted
    l.TextSize = 11
    l.TextWrapped = true
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Top
    l.LayoutOrder = nextOrder()
    l.Parent = body
    return l
end

local function actionRow(icon, text, subtitle, onClick)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, subtitle and 58 or 46)
    row.BackgroundColor3 = Theme.card
    row.AutoButtonColor = false
    row.Text = ""
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 11)

    local i = makeIcon(row, icon, Theme.accent, 16)
    i.Position = UDim2.fromOffset(14, subtitle and 20 or 15)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, subtitle and 11 or 0)
    lbl.Size = UDim2.new(1, -54, 0, subtitle and 16 or 46)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = text
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    if subtitle then
        local sub = Instance.new("TextLabel")
        sub.BackgroundTransparency = 1
        sub.Position = UDim2.fromOffset(40, 29)
        sub.Size = UDim2.new(1, -54, 0, 14)
        sub.Font = Enum.Font.Gotham
        sub.Text = subtitle
        sub.TextColor3 = Theme.muted
        sub.TextSize = 11
        sub.TextXAlignment = Enum.TextXAlignment.Left
        sub.TextTruncate = Enum.TextTruncate.AtEnd
        sub.Parent = row
    end

    row.MouseEnter:Connect(function()
        TweenService:Create(row, TweenInfo.new(0.15), { BackgroundColor3 = Theme.cardAlt }):Play()
    end)
    row.MouseLeave:Connect(function()
        TweenService:Create(row, TweenInfo.new(0.15), { BackgroundColor3 = Theme.card }):Play()
    end)
    row.MouseButton1Click:Connect(onClick)
    return row
end

-- Status card
local statusCard = Instance.new("Frame")
statusCard.Size = UDim2.new(1, 0, 0, 84)
statusCard.BackgroundColor3 = Theme.card
statusCard.BorderSizePixel = 0
statusCard.LayoutOrder = nextOrder()
statusCard.Parent = body
corner(statusCard, 10)

local dot = Instance.new("Frame")
dot.Size = UDim2.fromOffset(7, 7)
dot.Position = UDim2.fromOffset(14, 15)
dot.BackgroundColor3 = Theme.muted
dot.BorderSizePixel = 0
dot.Parent = statusCard
corner(dot, 4)

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(29, 9)
statusLabel.Size = UDim2.new(1, -42, 0, 18)
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.Text = "Idle"
statusLabel.TextColor3 = Theme.text
statusLabel.TextSize = 13
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Parent = statusCard

local timeLabel = Instance.new("TextLabel")
timeLabel.BackgroundTransparency = 1
timeLabel.Position = UDim2.fromOffset(14, 38)
timeLabel.Size = UDim2.new(1, -28, 0, 16)
timeLabel.Font = Enum.Font.Gotham
timeLabel.Text = "-"
timeLabel.TextColor3 = Theme.muted
timeLabel.TextSize = 12
timeLabel.TextXAlignment = Enum.TextXAlignment.Left
timeLabel.Parent = statusCard

local mobLabel = Instance.new("TextLabel")
mobLabel.BackgroundTransparency = 1
mobLabel.Position = UDim2.fromOffset(14, 60)
mobLabel.Size = UDim2.new(1, -28, 0, 16)
mobLabel.Font = Enum.Font.Gotham
mobLabel.Text = "-"
mobLabel.TextColor3 = Theme.muted
mobLabel.TextSize = 12
mobLabel.TextXAlignment = Enum.TextXAlignment.Left
mobLabel.Parent = statusCard

local function toggleRow(icon, text, key, onChange)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.AutoButtonColor = false
    row.Text = ""
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 11)

    local i = makeIcon(row, icon, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(1, -96, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = text
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local track = Instance.new("Frame")
    track.AnchorPoint = Vector2.new(1, 0.5)
    track.Position = UDim2.new(1, -14, 0.5, 0)
    track.Size = UDim2.fromOffset(42, 23)
    track.BackgroundColor3 = Theme.cardAlt
    track.BorderSizePixel = 0
    track.Parent = row
    corner(track, 12)

    local knob = Instance.new("Frame")
    knob.AnchorPoint = Vector2.new(0, 0.5)
    knob.Position = UDim2.new(0, 3, 0.5, 0)
    knob.Size = UDim2.fromOffset(17, 17)
    knob.BackgroundColor3 = Theme.muted
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 9)

    local function render()
        local on = State[key]
        TweenService:Create(track, TweenInfo.new(0.18), { BackgroundColor3 = on and Theme.accent or Theme.cardAlt }):Play()
        TweenService:Create(knob, TweenInfo.new(0.18), {
            Position = on and UDim2.new(1, -22, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
            BackgroundColor3 = on and Color3.new(1, 1, 1) or Theme.muted }):Play()
        TweenService:Create(i, TweenInfo.new(0.18), { ImageColor3 = on and Theme.accent or Theme.muted }):Play()
    end
    row.MouseButton1Click:Connect(function()
        State[key] = not State[key]
        render()
        if onChange then onChange(State[key]) end
    end)
    registerRenderer(render)
    render()
    return row
end

local function segmentRow(text, key, options)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 11)

    local i = makeIcon(row, Icon.sword, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(1, -174, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = text
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local seg = Instance.new("Frame")
    seg.AnchorPoint = Vector2.new(1, 0.5)
    seg.Position = UDim2.new(1, -14, 0.5, 0)
    seg.Size = UDim2.fromOffset(124, 28)
    seg.BackgroundColor3 = Theme.cardAlt
    seg.BorderSizePixel = 0
    seg.Parent = row
    corner(seg, 9)

    local highlight = Instance.new("Frame")
    highlight.Size = UDim2.fromOffset(60, 24)
    highlight.Position = UDim2.fromOffset(2, 2)
    highlight.BackgroundColor3 = Theme.accent
    highlight.BorderSizePixel = 0
    highlight.Parent = seg
    corner(highlight, 7)

    local buttons = {}
    local function render()
        for name, btn in pairs(buttons) do
            btn.TextColor3 = (State[key] == name) and Color3.new(1, 1, 1) or Theme.muted
        end
        TweenService:Create(highlight, TweenInfo.new(0.18), {
            Position = UDim2.fromOffset(State[key] == options[1] and 2 or 62, 2) }):Play()
    end
    for idx, name in ipairs(options) do
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.fromOffset(60, 24)
        btn.Position = UDim2.fromOffset(2 + (idx - 1) * 60, 2)
        btn.BackgroundTransparency = 1
        btn.AutoButtonColor = false
        btn.Font = Enum.Font.GothamMedium
        btn.Text = name
        btn.TextSize = 12
        btn.TextColor3 = Theme.muted
        btn.Parent = seg
        btn.MouseButton1Click:Connect(function() State[key] = name render() end)
        buttons[name] = btn
    end
    render()
end

-- Row of toggle chips bound to a table of booleans (e.g. State.WeaponSkills.Melee).
local function chipRow(icon, text, stateTable, keys, chipW)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 11)

    local i = makeIcon(row, icon, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)

    local gap = chipW + 4
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(1, -(40 + 16 + #keys * gap), 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = text
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextTruncate = Enum.TextTruncate.AtEnd
    lbl.Parent = row

    for idx, key in ipairs(keys) do
        local chip = Instance.new("TextButton")
        chip.AnchorPoint = Vector2.new(1, 0.5)
        chip.Position = UDim2.new(1, -14 - (#keys - idx) * gap, 0.5, 0)
        chip.Size = UDim2.fromOffset(chipW, 26)
        chip.BackgroundColor3 = Theme.cardAlt
        chip.AutoButtonColor = false
        chip.Font = Enum.Font.GothamBold
        chip.Text = key
        chip.TextSize = 12
        chip.TextColor3 = Theme.muted
        chip.Parent = row
        corner(chip, 8)

        local function render()
            local on = stateTable[key]
            TweenService:Create(chip, TweenInfo.new(0.15), {
                BackgroundColor3 = on and Theme.accent or Theme.cardAlt,
                TextColor3 = on and Color3.new(1, 1, 1) or Theme.muted,
            }):Play()
        end
        chip.MouseButton1Click:Connect(function()
            stateTable[key] = not stateTable[key]
            render()
        end)
        render()
    end
    return row
end

-- Single-select chips: exactly one option stays lit, stored as a string on
-- State. Ported from the main script for the 3-way Weapon preference (Fruit
-- support) -- segmentRow above is hardcoded to exactly 2 options.
local function choiceRow(icon, text, key, options, chipW)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 11)

    local i = makeIcon(row, icon, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)

    local gap = chipW + 4
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(1, -(40 + 16 + #options * gap), 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = text
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextTruncate = Enum.TextTruncate.AtEnd
    lbl.Parent = row

    local chips = {}
    local function render()
        for name, chip in pairs(chips) do
            local on = State[key] == name
            TweenService:Create(chip, TweenInfo.new(0.15), {
                BackgroundColor3 = on and Theme.accent or Theme.cardAlt,
                TextColor3 = on and Color3.new(1, 1, 1) or Theme.muted,
            }):Play()
        end
    end

    for idx, name in ipairs(options) do
        local chip = Instance.new("TextButton")
        chip.AnchorPoint = Vector2.new(1, 0.5)
        chip.Position = UDim2.new(1, -14 - (#options - idx) * gap, 0.5, 0)
        chip.Size = UDim2.fromOffset(chipW, 26)
        chip.BackgroundColor3 = Theme.cardAlt
        chip.AutoButtonColor = false
        chip.Font = Enum.Font.GothamBold
        chip.Text = name
        chip.TextSize = 11
        chip.TextColor3 = Theme.muted
        chip.Parent = row
        corner(chip, 8)
        chip.MouseButton1Click:Connect(function()
            State[key] = name
            render()
        end)
        chips[name] = chip
    end
    registerRenderer(render)
    render()
    return row
end

local function sliderRow(text, key, minVal, maxVal, suffix)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 60)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 11)

    local i = makeIcon(row, Icon.gauge, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 12)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 9)
    lbl.Size = UDim2.new(1, -108, 0, 18)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = text
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local valueLbl = Instance.new("TextLabel")
    valueLbl.BackgroundTransparency = 1
    valueLbl.AnchorPoint = Vector2.new(1, 0)
    valueLbl.Position = UDim2.new(1, -14, 0, 9)
    valueLbl.Size = UDim2.fromOffset(70, 18)
    valueLbl.Font = Enum.Font.Gotham
    valueLbl.Text = tostring(State[key]) .. (suffix or "")
    valueLbl.TextColor3 = Theme.accent
    valueLbl.TextSize = 12
    valueLbl.TextXAlignment = Enum.TextXAlignment.Right
    valueLbl.Parent = row

    local track = Instance.new("Frame")
    track.Position = UDim2.fromOffset(14, 41)
    track.Size = UDim2.new(1, -28, 0, 7)
    track.BackgroundColor3 = Theme.cardAlt
    track.BorderSizePixel = 0
    track.Parent = row
    corner(track, 3)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.fromScale(0, 1)
    fill.BackgroundColor3 = Theme.accent
    fill.BorderSizePixel = 0
    fill.Parent = track
    corner(fill, 3)

    local knob = Instance.new("Frame")
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.fromScale(0, 0.5)
    knob.Size = UDim2.fromOffset(16, 16)
    knob.BackgroundColor3 = Color3.new(1, 1, 1)
    knob.BorderSizePixel = 0
    knob.ZIndex = 2
    knob.Parent = track
    corner(knob, 7)

    local function render()
        local a = math.clamp((State[key] - minVal) / (maxVal - minVal), 0, 1)
        fill.Size = UDim2.fromScale(a, 1)
        knob.Position = UDim2.fromScale(a, 0.5)
        valueLbl.Text = tostring(State[key]) .. (suffix or "")
    end
    local function setFromX(x)
        local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        State[key] = math.floor(minVal + a * (maxVal - minVal) + 0.5)
        render()
    end
    local dragging = false
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            setFromX(input.Position.X)
        end
    end)
    render()
end

toggleRow(Icon.swords, "Auto Defend", "AutoDefend", function(on)
    if on then State.AutoDefend = true startDefend() else stopDefend() end
end)
toggleRow(Icon.shield, "Auto Skills", "AutoSkills")
toggleRow(Icon.fist, "Auto Haki", "AutoHaki")
chipRow(Icon.star, "Melee Keys", State.WeaponSkills.Melee, { "Z", "X", "C", "V", "F" }, 24)
chipRow(Icon.star, "Sword Keys", State.WeaponSkills.Sword, { "Z", "X", "C", "V", "F" }, 24)
chipRow(Icon.star, "Fruit Keys", State.WeaponSkills.Fruit, { "Z", "X", "C", "V", "F" }, 24)
toggleRow(Icon.activity, "Fast Attack", "FastAttack")
toggleRow(Icon.swords, "Weapon Switcher", "AutoWeaponSwitch")
chipRow(Icon.swords, "Switch Between", State.SwitchWeapons, { "Sword", "Melee", "Fruit" }, 52)
choiceRow(Icon.sword, "Weapon", "Weapon", { "Melee", "Sword", "Fruit" }, 46)
sliderRow("Distance", "Distance", DIST_MIN, DIST_MAX, " studs")

local note = Instance.new("TextLabel")
note.BackgroundTransparency = 1
note.Size = UDim2.new(1, 0, 0, 54)
note.Font = Enum.Font.Gotham
note.Text = "First cut, not fully proven like the main farm.\nAll mobs converge on one shared point near the\ntower -- this hovers there and fights whatever comes."
note.TextColor3 = Theme.muted
note.TextSize = 11
note.TextWrapped = true
note.TextXAlignment = Enum.TextXAlignment.Left
note.TextYAlignment = Enum.TextYAlignment.Top
note.LayoutOrder = nextOrder()
note.Parent = body

----------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------

sectionLabel("Quality of Life")
toggleRow(Icon.activity, "Anti-AFK", "AntiAFK", function() applyAntiAFK() end)
noteLabel("Resets Roblox's idle-kick timer. No FPS toggle:\nsetfpscap() measurably does nothing on this client.")

sectionLabel("ESP")
toggleRow(Icon.crosshair, "Mob ESP", "MobESP")
toggleRow(Icon.user, "Player ESP", "PlayerESP")
noteLabel("Range is capped by the game itself: mobs only exist\nonce they have streamed in near you.")

sectionLabel("Potions")
toggleRow(Icon.flame, "Auto Potion", "AutoPotion")
chipRow(Icon.star, "Auto-Use", State.PotionSelect, { "Rebirth", "EXP", "Lucky", "Item", "Diamond" }, 46)
noteLabel("Refreshes a selected X2 potion once it has about 20s\nleft, not all at once. Stops on its own once you run\nout of that potion.")

sectionLabel("Settings")

local presetNameRow = Instance.new("Frame")
presetNameRow.Size = UDim2.new(1, 0, 0, 46)
presetNameRow.BackgroundColor3 = Theme.card
presetNameRow.BorderSizePixel = 0
presetNameRow.LayoutOrder = nextOrder()
presetNameRow.Parent = body
corner(presetNameRow, 11)
do
    local i = makeIcon(presetNameRow, Icon.settings, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(0, 90, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = "Preset"
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = presetNameRow
end
local presetNameBox = Instance.new("TextBox")
presetNameBox.AnchorPoint = Vector2.new(1, 0.5)
presetNameBox.Position = UDim2.new(1, -14, 0.5, 0)
presetNameBox.Size = UDim2.fromOffset(136, 28)
presetNameBox.BackgroundColor3 = Theme.cardAlt
presetNameBox.Font = Enum.Font.Gotham
presetNameBox.Text = "Default"
presetNameBox.PlaceholderText = "name..."
presetNameBox.TextColor3 = Theme.text
presetNameBox.TextSize = 13
presetNameBox.ClearTextOnFocus = false
presetNameBox.Parent = presetNameRow
corner(presetNameBox, 7)
do
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 8)
    pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = presetNameBox
end

local refreshPresetList

actionRow(Icon.package, "Save As", "Saves the name above as a new preset", function()
    local name = presetNameBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        State.Status = "Enter a preset name first"
        return
    end
    local ok = saveSettingsAs(name)
    State.Status = ok and ("Saved as \"" .. name .. "\"") or "Save failed"
    if refreshPresetList then refreshPresetList() end
end)

local presetRow = Instance.new("TextButton")
presetRow.Size = UDim2.new(1, 0, 0, 46)
presetRow.BackgroundColor3 = Theme.card
presetRow.AutoButtonColor = false
presetRow.Text = ""
presetRow.LayoutOrder = nextOrder()
presetRow.Parent = body
corner(presetRow, 11)

local presetValue
do
    local i = makeIcon(presetRow, Icon.chevron, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(1, -60, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = "Load Preset"
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = presetRow

    presetValue = Instance.new("TextLabel")
    presetValue.BackgroundTransparency = 1
    presetValue.AnchorPoint = Vector2.new(1, 0.5)
    presetValue.Position = UDim2.new(1, -30, 0.5, 0)
    presetValue.Size = UDim2.new(0, 100, 0, 16)
    presetValue.Font = Enum.Font.Gotham
    presetValue.Text = "choose..."
    presetValue.TextColor3 = Theme.muted
    presetValue.TextSize = 12
    presetValue.TextXAlignment = Enum.TextXAlignment.Right
    presetValue.TextTruncate = Enum.TextTruncate.AtEnd
    presetValue.Parent = presetRow

    local chev = makeIcon(presetRow, Icon.chevron, Theme.muted, 14)
    chev.AnchorPoint = Vector2.new(1, 0.5)
    chev.Position = UDim2.new(1, -14, 0.5, 0)
end

local presetList = Instance.new("ScrollingFrame")
presetList.Size = UDim2.new(1, 0, 0, 0)
presetList.BackgroundColor3 = Theme.cardAlt
presetList.BorderSizePixel = 0
presetList.ScrollBarThickness = 3
presetList.ScrollBarImageColor3 = Theme.stroke
presetList.CanvasSize = UDim2.new()
presetList.AutomaticCanvasSize = Enum.AutomaticSize.Y
presetList.Visible = false
presetList.LayoutOrder = nextOrder()
presetList.Parent = body
corner(presetList, 11)
do
    local l = Instance.new("UIListLayout")
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = presetList
end

refreshPresetList = function()
    for _, c in ipairs(presetList:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
    end
    local names = listPresets()
    if #names == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, 0, 0, 34)
        empty.BackgroundTransparency = 1
        empty.Font = Enum.Font.Gotham
        empty.Text = "  no presets saved yet"
        empty.TextColor3 = Theme.muted
        empty.TextSize = 11
        empty.TextXAlignment = Enum.TextXAlignment.Left
        empty.Parent = presetList
        return
    end
    for idx, name in ipairs(names) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, 0, 0, 34)
        item.BackgroundTransparency = 1
        item.AutoButtonColor = false
        item.Font = Enum.Font.Gotham
        item.Text = "  " .. name
        item.TextColor3 = (lastPresetName == name) and Theme.accent or Theme.text
        item.TextSize = 12
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.TextTruncate = Enum.TextTruncate.AtEnd
        item.LayoutOrder = idx
        item.Parent = presetList
        do
            local pad = Instance.new("UIPadding")
            pad.PaddingRight = UDim.new(0, 28)
            pad.Parent = item
        end
        item.MouseButton1Click:Connect(function()
            local ok = loadSettingsNamed(name)
            State.Status = ok and ("Loaded \"" .. name .. "\"") or "Load failed"
            presetValue.Text = name
            presetValue.TextColor3 = Theme.accent
            presetNameBox.Text = name
            presetList.Visible = false
            presetList.Size = UDim2.new(1, 0, 0, 0)
            refreshPresetList()
        end)

        local del = Instance.new("TextButton")
        del.AnchorPoint = Vector2.new(1, 0.5)
        del.Position = UDim2.new(1, -6, 0.5, 0)
        del.Size = UDim2.fromOffset(22, 22)
        del.BackgroundTransparency = 1
        del.AutoButtonColor = false
        del.Text = ""
        del.Parent = item
        local delIcon = makeIcon(del, Icon.x, Theme.muted, 13)
        delIcon.AnchorPoint = Vector2.new(0.5, 0.5)
        delIcon.Position = UDim2.fromScale(0.5, 0.5)
        del.MouseEnter:Connect(function()
            TweenService:Create(delIcon, TweenInfo.new(0.12), { ImageColor3 = Color3.fromRGB(248, 113, 113) }):Play()
        end)
        del.MouseLeave:Connect(function()
            TweenService:Create(delIcon, TweenInfo.new(0.12), { ImageColor3 = Theme.muted }):Play()
        end)
        del.MouseButton1Click:Connect(function()
            local ok = deletePreset(name)
            State.Status = ok and ("Deleted \"" .. name .. "\"") or "Delete failed"
            if ok and presetValue.Text == name then
                presetValue.Text = "choose..."
                presetValue.TextColor3 = Theme.muted
            end
            refreshPresetList()
        end)
    end
end

presetRow.MouseButton1Click:Connect(function()
    local opening = not presetList.Visible
    if opening then refreshPresetList() end
    presetList.Visible = opening
    presetList.Size = opening and UDim2.new(1, 0, 0, 104) or UDim2.new(1, 0, 0, 0)
end)

toggleRow(Icon.star, "Auto Load on Start", "AutoLoadSettings", function(on)
    writeMeta(on, lastPresetName)
end)

noteLabel("Save As stores everything on this panel under the\nname above. Auto Load restores whichever preset you\nlast saved or loaded, on every future run (autoexec).")

----------------------------------------------------------------------
-- Behaviour
----------------------------------------------------------------------

task.spawn(function()
    while gui.Parent do
        -- pcall'd like the defend loop -- this used to run bare, so a single
        -- unexpected nil (e.g. a HUD label already destroyed, an attribute
        -- read racing a respawn) would silently kill the whole status readout
        -- for the rest of the session with no error shown anywhere.
        local ok, err = pcall(function()
            if not ON_MOON then
                statusLabel.Text = "Wrong place"
                dot.BackgroundColor3 = Theme.warn
                subtitle.Text = "This only works on the Moon place"
                timeLabel.Text = "Currently on PlaceId " .. tostring(game.PlaceId)
                mobLabel.Text = "Go through GoMoon in the main game first"
            else
                statusLabel.Text = State.Status
                dot.BackgroundColor3 = State.AutoDefend and Theme.good or Theme.muted

                local tower = getTower()
                local wave = workspace:GetAttribute("Wave")
                local timeLeft = workspace:GetAttribute("Time")
                local pct = tower and math.floor(
                    100 * (tonumber(tower:GetAttribute("Health")) or 0)
                        / math.max(tonumber(tower:GetAttribute("MaxHealth")) or 1, 1))
                subtitle.Text = string.format("Wave %s  -  Tower %s%%",
                    tostring(wave or "?"), tostring(pct or "?"))
                timeLabel.Text = "Time left: " .. tostring(timeLeft and math.floor(timeLeft) or "?") .. "s"

                local folder = workspace:FindFirstChild("Mob")
                local count = 0
                if folder then for _ in ipairs(folder:GetChildren()) do count = count + 1 end end
                mobLabel.Text = count .. " mobs active  -  MoonStone " .. tostring(LP:GetAttribute("MoonStone") or "?")
            end
        end)
        if not ok then warn("[Moon Defense] status loop: " .. tostring(err)) end

        task.wait(0.3)
    end
end)

do
    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = root.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                                       startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

closeBtn.MouseButton1Click:Connect(function()
    stopDefend()
    gui:Destroy()
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        root.Visible = not root.Visible
    end
end)

State.Status = "Ready"
