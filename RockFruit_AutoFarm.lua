-- @name Rock Fruit
--[[
    Rock Fruit - Auto Farm
    Built against place 119091355492870 (SeaTex Studio)

    Verified behaviour this is built on:
      - Quest state lives on the LocalPlayer attribute "Quest" (JSON):
            {"Title":"Bacon Shadow Garden","Current":0,"Max":5,...}
      - Quest givers are workspace.NpcQuest.NPC_QuestN, gated by level via
        ReplicatedStorage.Modules.QuestModule ({ Level = n, Npc = Model }).
      - Accepting is a ProximityPrompt on the NPC's HumanoidRootPart. Xeno's
        fireproximityprompt is broken, so we drive InputHoldBegin/End ourselves.
      - Quests REPEAT on their own. The only reason to revisit the board is to
        move up a level bracket, and the game refuses to swap while one is
        active -- the old one must be cancelled (red X on the quest panel).
      - Mobs live in workspace.Mob, named exactly like the quest Title.
      - Damage goes through Tool:Activate() on the equipped weapon. Never
        mouse1click(): that fires a real click at the OS cursor and presses
        whatever is under your mouse, including this menu.
      - Rebirth requires max level, which the HUD marks as "Lv. N (Max)". We
        read that text rather than hardcoding a cap, so it survives updates.
]]

local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local HttpService        = game:GetService("HttpService")
local TweenService       = game:GetService("TweenService")
local UserInputService   = game:GetService("UserInputService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local VirtualInputManager = game:GetService("VirtualInputManager")
local TeleportService    = game:GetService("TeleportService")
local GuiService         = game:GetService("GuiService")

local LP = Players.LocalPlayer

-- Every reload bumps this. Loops from a previous run compare against it and
-- exit, otherwise old threads keep teleporting the character and fight the new one.
getgenv().__RFF_GEN = (getgenv().__RFF_GEN or 0) + 1
local MY_GEN = getgenv().__RFF_GEN

-- Early builds attacked with mouse1click(), which fires a REAL click at the OS
-- cursor. Those loops predate the generation guard, so they cannot be shut down
-- and keep clicking (~15/sec) until you rejoin -- pressing whatever is under your
-- mouse. Nothing here needs it, so stub it out. Original kept for restoring.
if not getgenv().__RFF_REAL_MOUSE1CLICK then
    getgenv().__RFF_REAL_MOUSE1CLICK = getgenv().mouse1click or mouse1click
end
getgenv().mouse1click = function() end

-- [npcName] = questTitle, learned as quests are accepted. Kept across reloads.
getgenv().__RFF_QUESTMAP = getgenv().__RFF_QUESTMAP or {}
-- [mobName] = {x, y, z} last seen. Mobs only stream in near the player, so this
-- is how Select mode can travel back to a mob type that is not currently loaded.
getgenv().__RFF_MOBS = getgenv().__RFF_MOBS or {}

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------

-- Everything starts off. Nothing acts on the character until it is switched on
-- deliberately. The Skills table is the exception: it only filters which keys
-- Auto Skills uses, and Auto Skills itself is off, so nothing fires regardless.
local State = {
    AutoFarm     = false,
    FarmMode     = "Level",   -- "Level" (quest ladder) | "Select" (one chosen mob)
    Target       = nil,       -- mob name, Select mode only
    AutoQuest    = false,
    AutoEquip    = false,
    AutoHaki     = false,    -- keep Buso/armament haki switched on
    AutoSkills   = false,
    AutoWeaponSwitch = false,  -- alternate between the categories picked in SwitchWeapons
    -- Per-weapon-category cast keys. Fruit is wired up (UseDevilFruit,
    -- verified live -- same plain-tool-name pattern as Sword/Melee); Special
    -- (UseSpecial) is not, no account to test it against yet.
    WeaponSkills = {
        Melee = { Z = true, X = true, C = true, V = true, F = true },
        Sword = { Z = true, X = true, C = true, V = true, F = true },
        Fruit = { Z = true, X = true, C = true, V = true, F = true },
    },
    -- Which categories Auto Weapon Switch rotates between. Off by default for
    -- Fruit -- keeps existing Sword/Melee behaviour unchanged for anyone who
    -- already had the switcher on. A category with nothing owned for it
    -- (toolNameFor returns nil) is silently skipped regardless of this.
    SwitchWeapons = { Sword = true, Melee = true, Fruit = false },
    Distance     = 9,         -- studs to hover above/behind the mob (reach is ~10)
    AutoBoss     = false,     -- kill any live boss in workspace.Boss first
    AutoSummon   = false,     -- summon one when none is alive (needs Orb Boss)
    BossPick     = "Any",     -- "Any" or one exact boss name from SpawnBossList
    AutoStats    = false,     -- spend stat points as they come in
    StatPick     = { Melee = true, Defense = true, Sword = true, Power = true },
    AutoGacha    = false,     -- roll a gacha automatically
    GachaSource  = "Random",  -- "Random" (gems) | "Moon" (event stones)
    GachaTier    = "x15",     -- "x5" | "x10" | "x15"
    KeepGems     = 1000,      -- never spend the currency below this
    FastAttack   = false,
    AutoRebirth  = false,
    Weapon       = "Melee",   -- auto-picked below
    Kills        = 0,
    Status       = "Idle",

    -- Utils
    AntiAFK      = false,
    MobESP       = false,
    PlayerESP    = false,
    AutoPotion   = false,
    PotionSelect = { Rebirth = false, EXP = false, Lucky = false, Item = false, Diamond = false },
    AutoLoadSettings = false,
}

-- Pick whichever weapon stat is actually trained. This matters a lot: on a
-- Sword 22000 / Melee 1 account the sword does ~50x the damage.
do
    local sword = tonumber(LP:GetAttribute("Sword")) or 0
    local melee = tonumber(LP:GetAttribute("Melee")) or 0
    State.Weapon = (sword >= melee) and "Sword" or "Melee"
end

-- Weapon reach measured at roughly 10 studs: 15 lands nothing at all. Capping the
-- slider near that stops you dialling in a distance that silently stops damaging.
local DIST_MIN     = 4
local DIST_MAX     = 12
local ATTACK_DELAY = 0.12  -- seconds between swings when FastAttack is on

----------------------------------------------------------------------
-- Lucide icons (asset ids from the Fluent icon set)
----------------------------------------------------------------------

local Icon = {
    swords    = "rbxassetid://10734975692",
    sword     = "rbxassetid://10734975486",
    target    = "rbxassetid://10734977012",
    crosshair = "rbxassetid://10709818534",
    settings  = "rbxassetid://10734950309",
    user      = "rbxassetid://10747373176",
    mappin    = "rbxassetid://10734886004",
    package   = "rbxassetid://10734909540",
    x         = "rbxassetid://10747384394",
    minus     = "rbxassetid://10734896206",
    activity  = "rbxassetid://10709752035",
    shield    = "rbxassetid://10734951847",
    coins     = "rbxassetid://10709811110",
    chevron   = "rbxassetid://10709790948",
    flame     = "rbxassetid://10723376114",
    star      = "rbxassetid://10734966248",
    gauge     = "rbxassetid://10723395708",
    fist      = "rbxassetid://10723405508",
}

local Theme = {
    bg      = Color3.fromRGB(14, 16, 22),
    card    = Color3.fromRGB(22, 26, 35),
    cardAlt = Color3.fromRGB(28, 33, 44),
    stroke  = Color3.fromRGB(42, 48, 62),
    accent  = Color3.fromRGB(91, 140, 255),
    good    = Color3.fromRGB(74, 222, 128),
    text    = Color3.fromRGB(230, 233, 239),
    muted   = Color3.fromRGB(138, 147, 166),
}

----------------------------------------------------------------------
-- Game helpers
----------------------------------------------------------------------

local QuestModule = require(ReplicatedStorage.Modules.QuestModule)

local function getRoot()
    local char = LP.Character
    return char and char:FindFirstChild("HumanoidRootPart") or nil
end

local function getHumanoid()
    local char = LP.Character
    return char and char:FindFirstChildOfClass("Humanoid") or nil
end

-- Is this somewhere that actually exists in the world? Guards against a runaway
-- that looks exactly like flinging:
--
--   mob not loaded -> travel to its quest NPC -> if the character is far away the
--   island streams out and that NPC reads as fallen (measured at Y = -584181) ->
--   we teleport down to it -> now even further away -> repeat.
--
-- Observed jumping 946,406 studs per tick with velocity 0, so it was never
-- physics, just chasing a garbage coordinate. Refusing the bad target breaks the
-- loop wherever it starts.
local function sanePos(p)
    if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z then return false end  -- NaN
    return math.abs(p.X) < 50000
       and math.abs(p.Z) < 50000
       and p.Y > -500 and p.Y < 100000
end

-- Teleporting by CFrame every frame makes the physics solver treat each jump as
-- motion, so velocity integrates upward without bound -- measured at 1,113,557
-- studs/s while farming. The moment the pinning stops (a quest-accept hold, a
-- mob dying) that stored energy releases and flings the character across the map,
-- which is also what dragged us out of ProximityPrompt range mid-accept.
-- Zeroing the assembly velocity on every teleport keeps it at walking speed.
local function tpTo(cf)
    local root = getRoot()
    if not root then return end
    if not sanePos(cf.Position) then return end   -- never chase a bad coordinate
    root.CFrame = cf
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

-- Island list, in the same order the game's own Teleport window uses (its
-- "layout" attribute), each backed by workspace.Gates.TeleportPart.<name> -- the
-- exact part the game's own button pivots to. This is the same operation the
-- game's Frame_Teleport button performs (HandlerMain ~863):
--     character:PivotTo(TeleportPart[name].CFrame * CFrame.new(0, 5, 0))
-- Purely client-side, no remote involved, so replicating it directly is exactly
-- as legitimate as clicking the button ourselves.
local function islandList()
    local list = {}
    local isl = workspace:FindFirstChild("island")
    if not isl then return list end
    for _, v in ipairs(isl:GetChildren()) do
        list[#list + 1] = { name = v.Name, layout = tonumber(v:GetAttribute("layout")) or 0 }
    end
    table.sort(list, function(a, b) return a.layout < b.layout end)
    return list
end

local function teleportToIsland(name)
    local char = LP.Character
    if not char then return false, "no character" end
    -- The game's own check is LocalPlayer:FindFirstChild("InCombat") (HandlerMain
    -- ~864), on the Player instance, not the Character. Checking the wrong one
    -- would silently never block, so mirror the source exactly.
    if LP:FindFirstChild("InCombat") then return false, "in combat" end

    local gates = workspace:FindFirstChild("Gates")
    local part = gates and gates:FindFirstChild("TeleportPart") and gates.TeleportPart:FindFirstChild(name)
    if not part then return false, "unknown island" end

    local dest = part.Position + Vector3.new(0, 5, 0)
    if not sanePos(dest) then return false, "bad destination" end

    char:PivotTo(CFrame.new(dest))
    local root = char:FindFirstChild("HumanoidRootPart")
    if root then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    return true
end

-- A stand-on platform used to live here. Removed after measuring it: with the
-- velocity zeroing in tpTo already in place it changed nothing that mattered
-- (maxVel 421 vs 432, zero fling jumps and zero damage taken either way) and it
-- left the humanoid toppled in FallingDown rather than cleanly in Freefall,
-- because aiming at a mob below you tilts the root. tpTo does the real work.

local function getQuest()
    local raw = LP:GetAttribute("Quest")
    if type(raw) ~= "string" or raw == "" or raw == "[]" then return nil end
    local ok, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok and type(data) == "table" and data.Title then return data end
    return nil
end

-- Highest-level quest entry the player actually qualifies for.
local function getBestQuestEntry()
    local level = tonumber(LP:GetAttribute("Level")) or 1
    local best
    for _, entry in ipairs(QuestModule) do
        if entry.Npc and entry.Npc.Parent and level >= entry.Level then
            if not best or entry.Level > best.Level then best = entry end
        end
    end
    return best
end

local function npcForQuest(quest)
    if not quest then return nil end
    for npcName, title in pairs(getgenv().__RFF_QUESTMAP) do
        if title == quest.Title then return npcName end
    end
    return nil
end

local function getPrompt(npc)
    local hrp = npc and npc:FindFirstChild("HumanoidRootPart")
    return hrp and hrp:FindFirstChildWhichIsA("ProximityPrompt") or nil
end

-- The mob catalogue comes straight from the quest givers. Every NPC_QuestN
-- carries two attributes: Name (the mob its quest asks for) and Level (the
-- requirement). That is exact and available immediately, with no scanning.
--
-- The earlier approach -- tour the NPCs and tag whatever mobs spawned within 600
-- studs -- got 8 of 17 levels wrong, because mobs stay loaded once spawned so
-- neighbouring islands' mobs sit inside the radius too.
local function mobCatalog()
    local list = {}
    local folder = workspace:FindFirstChild("NpcQuest")
    if not folder then return list end
    for _, npc in ipairs(folder:GetChildren()) do
        if npc:IsA("Model") then
            local attrs = npc:GetAttributes()
            local mob = attrs.Name
            local lvl = tonumber(attrs.Level)
            local hrp = npc:FindFirstChild("HumanoidRootPart")
            if mob and lvl and hrp then
                list[#list + 1] = {
                    name = tostring(mob),
                    lvl = lvl,
                    npcPos = hrp.Position,
                }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.lvl ~= b.lvl then return a.lvl < b.lvl end
        return a.name < b.name
    end)
    return list
end

local function catalogEntry(mobName)
    for _, e in ipairs(mobCatalog()) do
        if e.name == mobName then return e end
    end
    return nil
end

-- Last known-good position of each mob's quest giver. NPCs read as fallen while
-- their island is streamed out, so a position is only cached while it looks sane
-- and is never overwritten with a garbage one.
local npcHome = {}

local function cacheNpcHomes()
    local folder = workspace:FindFirstChild("NpcQuest")
    if not folder then return end
    for _, npc in ipairs(folder:GetChildren()) do
        if npc:IsA("Model") then
            local mob = npc:GetAttributes().Name
            local hrp = npc:FindFirstChild("HumanoidRootPart")
            if mob and hrp and sanePos(hrp.Position) then
                npcHome[tostring(mob)] = hrp.Position
            end
        end
    end
end

-- Learn the exact spot a mob actually stands, which is more precise than the
-- quest giver's position. Purely a refinement: the NPC position is the fallback.
local function rememberMobs()
    local folder = workspace:FindFirstChild("Mob")
    if not folder then return end
    local reg = getgenv().__RFF_MOBS
    for _, m in ipairs(folder:GetChildren()) do
        local hrp = m:FindFirstChild("HumanoidRootPart")
        if hrp and sanePos(hrp.Position) then   -- never store a streamed-out spot
            reg[m.Name] = { x = hrp.Position.X, y = hrp.Position.Y, z = hrp.Position.Z }
        end
    end
end

-- Catalogue (quest mobs, with levels) plus anything else we have actually seen.
-- Event and Moon mobs have no quest NPC, so without the learned half they could
-- never appear in the target list at all. They sort last with an unknown level.
local function knownMobs()
    local list = mobCatalog()
    local seen = {}
    for _, e in ipairs(list) do seen[e.name] = true end
    for name in pairs(getgenv().__RFF_MOBS) do
        if not seen[name] then
            seen[name] = true
            list[#list + 1] = { name = name, lvl = nil }
        end
    end
    table.sort(list, function(a, b)
        local al, bl = a.lvl or math.huge, b.lvl or math.huge
        if al ~= bl then return al < bl end
        return a.name < b.name
    end)
    return list
end

-- Where to stand to find a given mob. Every candidate is sanity-checked, so a
-- streamed-out NPC or a stale bad entry is skipped rather than chased.
local function mobLocation(mobName)
    local e = getgenv().__RFF_MOBS[mobName]
    if e and e.x then
        local v = Vector3.new(e.x, e.y, e.z)
        if sanePos(v) then return v end
    end
    if npcHome[mobName] and sanePos(npcHome[mobName]) then
        return npcHome[mobName]
    end
    local c = catalogEntry(mobName)
    if c and c.npcPos and sanePos(c.npcPos) then return c.npcPos end
    return nil
end

local function findMob(name)
    local folder = workspace:FindFirstChild("Mob")
    local root = getRoot()
    if not folder or not root then return nil end

    local best, bestDist
    for _, model in ipairs(folder:GetChildren()) do
        if model.Name == name then
            local hum = model:FindFirstChildOfClass("Humanoid")
            local hrp = model:FindFirstChild("HumanoidRootPart")
            if hum and hrp and hum.Health > 0 then
                local dist = (hrp.Position - root.Position).Magnitude
                if not bestDist or dist < bestDist then best, bestDist = model, dist end
            end
        end
    end
    return best
end

-- Weapon categories: Sword/Melee always exist; Fruit only if the account
-- actually owns a Devil Fruit (UseDevilFruit attribute set) -- verified live
-- on this account (UseDevilFruit = "Lightning", a plain tool-name string,
-- same pattern as UseSword/UseMelee, sitting in the Backpack as a real Tool
-- with an identical Frame_SkillList_Lightning panel once equipped).
local CATEGORY_ATTR = { Sword = "UseSword", Melee = "UseMelee", Fruit = "UseDevilFruit" }
local CATEGORY_ORDER = { "Sword", "Melee", "Fruit" }

local function toolNameFor(category)
    local attr = CATEGORY_ATTR[category]
    local name = attr and LP:GetAttribute(attr)
    return (type(name) == "string" and name ~= "") and name or nil
end

-- Which category a given equipped-tool name belongs to.
local function categoryForTool(toolName)
    if type(toolName) ~= "string" or toolName == "" then return nil end
    for _, cat in ipairs(CATEGORY_ORDER) do
        if toolName == toolNameFor(cat) then return cat end
    end
    return nil
end

-- Categories the user has picked to rotate between (State.SwitchWeapons) AND
-- that the account actually owns right now (toolNameFor returns something)
-- -- so ticking "Fruit" on an account that doesn't have one yet just does
-- nothing instead of erroring.
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
    if not State.AutoEquip then return end
    local char = LP.Character
    if not char then return end

    local wanted = toolNameFor(State.Weapon)
    if not wanted then return end
    if char:FindFirstChild(wanted) then return end

    local tool = LP.Backpack:FindFirstChild(wanted)
    local hum = getHumanoid()
    if tool and hum then pcall(function() hum:EquipTool(tool) end) end
end

-- Swing via the equipped Tool, never a real mouse click. Also hits harder:
-- 14098 dmg / 46 swings vs 8056 / 40 for mouse1click in a head-to-head.
local function attack()
    local char = LP.Character
    if not char then return end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return end
    pcall(function() tool:Activate() end)
end

-- Skills are bound to Z/X/C/V and the game shows their state in
-- HUD.Main.Frame_SkillList_<equipped tool>.Border.Main.<KEY>, where the Ready
-- label reads "Ready" or "UnReady" and a CooldownFrame counts down.
--
-- Each row also has Auto and Use buttons, but Use is hidden (mobile only) so
-- clicking it does nothing. Sending the keypress is the path the game actually
-- listens on: verified Ready -> UnReady with a 6s cooldown appearing.
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

-- Which of the CURRENT weapon's selected skills have fired at least once
-- since it was equipped. Written by useSkills(), read by switchWeapons() --
-- see the comment above that function for why this replaced two earlier,
-- live-tested-and-failed approaches (fixed timer, and "time since anything
-- last fired").
local usedThisEquip = {}

-- lastSkill tracks the last time ANYTHING actually fired; kept separate from
-- lastScan so firing several skills in one pass doesn't also throttle how
-- often this function bothers re-scanning the panel.
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
    -- mash several off-cooldown hotkeys back-to-back just as fast; stopping
    -- after one and waiting out a fixed gap before trying again only left
    -- 2nd/3rd+ ready skills sitting unused for no real reason.
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

-- Weapon Switcher: hop between Sword and Melee so both movesets' skills get
-- used, since each has its OWN independent cooldown pool -- verified live: with
-- Sword mid-cooldown on 3 of 5 skills, switching to Melee showed all 5 Melee
-- skills fully Ready, and switching back showed Sword's cooldowns completely
-- unaffected by anything cast on Melee. So alternating roughly doubles active
-- skill uptime instead of idling on one weapon's cooldowns.
--
-- Adaptive, not timer-based: stay on the current weapon as long as it still has
-- a selected skill ready; only hop once it has nothing left AND the other
-- weapon does. This overrides equipWeapon()'s single-preference behaviour, so
-- the two must never both run in the same tick.
local function anySkillReady(toolName)
    local hud = LP.PlayerGui:FindFirstChild("HUD")
    local frame = hud and hud.Main:FindFirstChild("Frame_SkillList_" .. toolName)
    local main = frame and frame:FindFirstChild("Border") and frame.Border:FindFirstChild("Main")
    -- The game only creates Frame_SkillList_<tool> once that tool has
    -- actually been equipped -- it does not exist yet for a weapon still
    -- sitting in the Backpack. Confirmed live: a session that only ever
    -- equipped Sword had no Frame_SkillList_Ryusoken (melee) at all, so this
    -- returned false for melee forever and the switcher could never make its
    -- first switch to it -- needs to equip melee to see its skills, but only
    -- switches if it already sees a ready skill. Treat "panel doesn't exist
    -- yet" as worth trying rather than "definitely not ready", so the
    -- switcher can make one exploratory switch and bootstrap the panel;
    -- every check after that is a real ready/not-ready read.
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

-- Two earlier designs for "when to give up on the current weapon" both
-- failed live on the Moon Defense sibling script, in opposite directions:
--   1. Force a switch WEAPON_MAX_DWELL seconds after the weapon was EQUIPPED,
--      regardless of anySkillReady(current). Cut rotations short -- with 5
--      independent-cooldown skills (confirmed live: firing one doesn't touch
--      the other four), a weapon could still have 3-4 *other* skills
--      genuinely ready at the dwell mark and get switched away anyway.
--   2. Force a switch only once nothing had fired in a while ("stalled" =
--      time since the last successful cast). With skills on staggered
--      several-second cooldowns, SOME skill is almost always about to come
--      back ready, so that almost never crossed the threshold and the
--      switcher got stuck on one weapon indefinitely.
-- Both were guessing "exhausted" from an indirect signal. Tracking directly
-- instead: usedThisEquip records every selected skill that has actually
-- fired since this weapon was equipped, so the switch condition is exact --
-- go through every chosen skill, then hand off -- rather than inferred from
-- elapsed time or momentary readiness. ROTATE_SAFETY_CAP is only a backstop
-- for a selected skill whose cooldown just never comes up in reasonable
-- time; it should rarely if ever be the thing that actually triggers a switch.
local WEAPON_MIN_GAP = 0.5   -- floor between switches, just enough to dodge equip-thrash
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
-- hardcoded Sword/Melee pair -- Fruit slots into this the same way without
-- special-casing a third branch everywhere.
local function switchWeapons()
    if not State.AutoEquip then return end
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

    -- If only one category is enabled (or the equipped tool's category was
    -- just deselected), there is nothing to rotate to -- fall through to try
    -- the enabled list below, which still recovers correctly either way.
    if currentCategory and State.SwitchWeapons[currentCategory] then
        -- A weapon freshly equipped after sitting unused often has EVERY
        -- selected skill already off cooldown, so usedThisEquip fills up
        -- within a single useSkills() pass -- looks "exhausted" a fraction of
        -- a second after equipping. That is actively harmful for a
        -- long-animation skill (a "time stop" style ability): the switch
        -- away happens mid-animation, while the lockout it causes still has
        -- nothing usable, and re-equipping likely cancels the
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

    -- Walk the enabled list starting right after the current category (or
    -- from the top if current isn't even in it), take the first one with
    -- something ready -- or whose panel doesn't exist yet, see anySkillReady.
    local startIdx = 0
    for i, cat in ipairs(enabled) do if cat == currentCategory then startIdx = i end end
    for step = 1, #enabled do
        local cat = enabled[(startIdx + step - 1) % #enabled + 1]
        local name = toolNameFor(cat)
        if name and name ~= current and anySkillReady(name) then
            lastWeaponSwitch = os.clock()
            usedThisEquip = {}
            weaponEquippedSince = os.clock()
            equipNamed(name)
            return
        end
    end
end

-- Bosses ------------------------------------------------------------
-- Live bosses land in workspace.Boss. They are not tied to a quest, so this is
-- independent of the Level/Select modes and simply takes priority when one exists.
--
-- State.BossPick is "Any" or one exact boss name. When a name is picked, a live
-- boss of a DIFFERENT name is ignored -- otherwise summoning "Dark Bacon" would
-- immediately get overridden by farming whatever else happened to be up.
local function findBoss()
    local folder = workspace:FindFirstChild("Boss")
    if not folder then return nil end
    local root = getRoot()
    local best, bestDist
    for _, m in ipairs(folder:GetChildren()) do
        if State.BossPick == "Any" or m.Name == State.BossPick then
            local hum = m:FindFirstChildOfClass("Humanoid")
            local hrp = m:FindFirstChild("HumanoidRootPart")
            if hum and hrp and hum.Health > 0 then
                local d = root and (hrp.Position - root.Position).Magnitude or 0
                if not bestDist or d < bestDist then best, bestDist = m, d end
            end
        end
    end
    return best
end

-- How many of an item the player holds, read off the Inventory attribute.
local function ownedCount(itemName)
    local raw = LP:GetAttribute("Inventory")
    if type(raw) ~= "string" or raw == "" then return 0 end
    local ok, inv = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(inv) ~= "table" then return 0 end
    local entry = inv[itemName]
    if not entry then return 0 end
    if type(entry) == "table" then return tonumber(entry.amount) or 0 end
    return tonumber(entry) or 0
end

-- The Summon Boss window's own button just does
--     NetworkFramework.fireServer("SummonBoss", bossName)
-- (Frame_SummonBoss.Handler_SummonBoss line ~34), reading the full boss list and
-- its requirement item straight from ReplicatedStorage.Modules.SpawnBossList
-- rather than the window's rendered rows -- so this works even if the window has
-- never been opened.
local NetworkFrameworkEarly = require(ReplicatedStorage.Modules.NetworkFramework)
local SpawnBossList = require(ReplicatedStorage.Modules.SpawnBossList)

local function bossCatalog()
    local list = {}
    for name, item in pairs(SpawnBossList) do
        list[#list + 1] = { name = name, item = tostring(item) }
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local lastSummon = 0

local function trySummonBoss()
    if os.clock() - lastSummon < 12 then return false end

    local candidates = {}
    if State.BossPick == "Any" then
        candidates = bossCatalog()
    else
        for _, e in ipairs(bossCatalog()) do
            if e.name == State.BossPick then candidates = { e } break end
        end
    end
    if #candidates == 0 then
        State.Status = "No such boss: " .. tostring(State.BossPick)
        return false
    end

    for _, e in ipairs(candidates) do
        if ownedCount(e.item) > 0 then
            lastSummon = os.clock()
            pcall(function()
                NetworkFrameworkEarly.fireServer("SummonBoss", e.name)
            end)
            State.Status = "Summoned " .. e.name
            return true
        end
    end

    -- Nothing affordable. Name what is missing instead of silently doing nothing.
    State.Status = "Need " .. candidates[1].item
    return false
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local NetworkFramework = require(ReplicatedStorage.Modules.NetworkFramework)

-- Haki ---------------------------------------------------------------
-- Pressing J just does Remotes.Action:FireServer("Misc", "buso")
-- (Character.Script.ClientEvent line ~263), so we can toggle it without the
-- keybind -- which matters because that script dies on respawn under this
-- executor and the key stops working entirely.
--
-- Two different BusoHaki attributes exist and only one is the live state:
--   Player.BusoHaki     = whether haki is unlocked at all (always true here)
--   Character.BusoHaki  = whether it is currently switched ON
-- Reading the player one makes it look permanently active. Watch the character
-- one; it resets to false on every respawn, which is what makes this worth
-- automating in the first place.
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
    if not hum or hum.Health <= 0 then return end   -- dead: wait for the respawn
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

-- Potions --------------------------------------------------------------
-- Verified live: using ANY inventory item (potion or otherwise) is just
-- Remotes.Inventory:FireServer(exactItemName) -- a single string argument,
-- no "Use" verb, no confirmation needed. The confirm dialog the normal UI
-- shows first (HUD.HandlerMain ~line 350: opens Frame_Alert if
-- CanUseItem[name], otherwise fires the same remote immediately) is a
-- client-side nicety only; the server accepts the remote directly either way.
-- Each X2 boost's remaining time is tracked in a plain player attribute
-- (x2ExpTime, x2RebirthTime, etc, in seconds) -- refresh only once that drops
-- to POTION_REFRESH_AT so a 15-minute potion isn't discarded early, and only
-- for whichever ones are actually selected.
local POTIONS = {
    { key = "Rebirth", item = "X2 Rebirth 15min.", timeAttr = "x2RebirthTime" },
    { key = "EXP",     item = "X2 EXP 15min.",     timeAttr = "x2ExpTime" },
    { key = "Lucky",   item = "X2 Lucky 15min.",   timeAttr = "x2LuckTime" },
    { key = "Item",    item = "X2 Item 15min.",    timeAttr = "x2ItemTime" },
    { key = "Diamond", item = "X2 Diamond 15min.", timeAttr = "x2DiamondTime" },
}
local POTION_REFRESH_AT = 20 -- seconds remaining -- refresh just before it runs out, not all at once
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

-- Gacha --------------------------------------------------------------
-- Both gacha windows wire their Open x5/x10/x15 buttons to a single call:
--     Random Items -> NetworkFramework.fireServer("RandomItem", "<tier>")
--     Moon event   -> NetworkFramework.fireServer("EventMoon",  "<tier>")
-- (HandlerMain ~915 and Handler_EventMoon ~90), so neither needs its window open.
--
-- Within a source every tier is the same rate, so the tier only decides batch
-- size. Verified on Random: x5 cost 50 gems for +5 points, x15 cost 150 for +15.
local GACHA = {
    Random = {
        event    = "RandomItem",
        currency = "Diamond",      -- gems
        unit     = "gems",
        cost     = { x5 = 50, x10 = 100, x15 = 150 },
    },
    Moon = {
        event    = "EventMoon",
        currency = "MoonStone",    -- event stones
        unit     = "stones",
        cost     = { x5 = 25, x10 = 50, x15 = 75 },
    },
}

local lastGacha = 0

local function rollGacha()
    if not State.AutoGacha then return end
    if os.clock() - lastGacha < 3 then return end

    local src = GACHA[State.GachaSource]
    if not src then return end
    local cost = src.cost[State.GachaTier]
    if not cost then return end

    local held = tonumber(LP:GetAttribute(src.currency)) or 0
    local floor = tonumber(State.KeepGems) or 0

    if held < cost then
        State.Status = string.format("No %s for %s gacha", src.unit, State.GachaSource)
        return
    end
    if held - cost < floor then
        State.Status = string.format("Gacha paused - keeping %d %s", floor, src.unit)
        return
    end

    lastGacha = os.clock()
    pcall(function()
        NetworkFramework.fireServer(src.event, State.GachaTier)
    end)
    State.Status = string.format("Rolled %s %s", State.GachaSource, State.GachaTier)
end

-- Stats --------------------------------------------------------------
-- The stats window's own Plus button just does:
--     Remotes.System:FireServer("UpStats", <StatName>, <amount>)
-- (Frame_Stats.Handler line 453). Calling that directly skips the UI entirely --
-- no opening the window, no filling in the amount box, no flicker.
--
-- Worth knowing why the UI route was fragile: the amount lives in
-- Frame_Stats.Stats.Box.TextBox, and if it holds more points than you own every
-- click is silently ignored. Firing the remote sidesteps that completely.
local STAT_NAMES = { "Melee", "Defense", "Sword", "Power" }
local STAT_CHUNK = 500   -- spend in batches so one bad call cannot dump everything

local lastSpend = 0

local function spendStats()
    if not State.AutoStats then return end
    if os.clock() - lastSpend < 2 then return end
    lastSpend = os.clock()

    local points = tonumber(LP:GetAttribute("Point")) or 0
    if points <= 0 then return end

    local picked = {}
    for _, n in ipairs(STAT_NAMES) do
        if State.StatPick[n] then picked[#picked + 1] = n end
    end
    if #picked == 0 then
        State.Status = "No stat selected"
        return
    end

    local spent = 0
    for _, name in ipairs(picked) do
        points = tonumber(LP:GetAttribute("Point")) or 0
        if points <= 0 then break end
        local amount = math.min(points, STAT_CHUNK)
        local ok = pcall(function()
            Remotes.System:FireServer("UpStats", name, amount)
        end)
        if ok then spent = spent + amount end
        task.wait(0.15)
    end

    if spent > 0 then
        State.Status = string.format("Spent %d points", spent)
    end
end

-- Kill the character so the server respawns it. Clears most stuck states:
-- wedged in geometry, PlatformStand left on, a broken/ragdolled humanoid, or a
-- corpse that never respawned. Returns true once we are alive again.
local function resetCharacter()
    local hum = getHumanoid()
    if hum then
        pcall(function() hum.Health = 0 end)
    elseif LP.Character then
        pcall(function() LP.Character:BreakJoints() end)
    end

    local deadline = os.clock() + 20
    while os.clock() < deadline do
        task.wait(0.5)
        local h = getHumanoid()
        if h and h.Health > 0 and getRoot() then
            task.wait(1)  -- let the spawn settle before farming again
            return true
        end
    end
    return false
end

-- Quests repeat on their own, so the only reason to touch the quest board is to
-- move up to a higher-level one. The game refuses to hand over a new quest while
-- one is active, so the old must be cancelled -- the red X on the quest panel.
local function cancelQuest()
    local hud = LP.PlayerGui:FindFirstChild("HUD")
    local frame = hud and hud.Main:FindFirstChild("Frame_Quest")
    if not frame then return false end

    local btn
    for _, v in ipairs(frame:GetDescendants()) do
        if v.Name == "Close_" then btn = v end
    end
    if not btn then return false end

    frame.Visible = true
    task.wait(0.15)

    local inset = GuiService:GetGuiInset()
    local cx = btn.AbsolutePosition.X + btn.AbsoluteSize.X / 2 + inset.X
    local cy = btn.AbsolutePosition.Y + btn.AbsoluteSize.Y / 2 + inset.Y
    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
    task.wait(0.1)
    VirtualInputManager:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
    task.wait(0.6)
    return true
end

-- Rejoining, with fallbacks.
--
-- TeleportService reports failure ASYNCHRONOUSLY through TeleportInitFailed, not
-- by throwing, so wrapping the call in pcall catches nothing and any fallback
-- placed after it never runs. Chain off the event instead.
--
-- VIP/private servers reject TeleportToPlaceInstance outright ("attempted to
-- teleport to a place that is restricted"), so on a VIP server stage 1 always
-- fails. Stage 2 lands in a public server. If teleporting is blocked entirely we
-- disconnect instead: ending the session is the whole point (it is the only thing
-- that clears farm loops left by older builds), and the player can relaunch from
-- their own VIP link.
local function rejoin(sameServer)
    local stage = sameServer and 1 or 2
    local conn

    local function attempt()
        if stage == 1 then
            State.Status = "Rejoining same server"
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP)
        elseif stage == 2 then
            State.Status = "Rejoining any server"
            TeleportService:Teleport(game.PlaceId, LP)
        else
            if conn then conn:Disconnect() conn = nil end
            State.Status = "Teleport blocked - disconnecting"
            task.wait(0.4)
            LP:Kick("Teleport is restricted in this server.\n\nRejoin from your own server link. "
                .. "Leaving is what clears the old farm loops.")
        end
    end

    conn = TeleportService.TeleportInitFailed:Connect(function(player, result, message)
        if player ~= LP then return end
        State.Status = "Rejoin failed: " .. tostring(message or result)
        stage = stage + 1
        task.spawn(attempt)
    end)

    task.spawn(function()
        local ok, err = pcall(attempt)
        if not ok then
            State.Status = "Rejoin error: " .. tostring(err)
            stage = stage + 1
            pcall(attempt)
        end
    end)
end

-- Max level is whatever the HUD says it is: it renders "Lv. 22000 (Max)". Reading
-- the suffix instead of hardcoding 22000 keeps this working after a level-cap update.
local levelLabel
local function isMaxLevel()
    if not (levelLabel and levelLabel.Parent) then
        levelLabel = nil
        local hud = LP.PlayerGui:FindFirstChild("HUD")
        if not hud then return false end
        for _, v in ipairs(hud:GetDescendants()) do
            if v:IsA("TextLabel") and v.Name == "LevelText" then levelLabel = v break end
        end
    end
    if not levelLabel then return false end
    return string.find(tostring(levelLabel.Text), "%(Max%)") ~= nil
end

-- The Rebirth button is likewise just NetworkFramework.fireServer("Rebirth")
-- (Frame_Stats.Handler line 569), so no window needs opening here either.
local function doRebirth()
    return (pcall(function()
        NetworkFramework.fireServer("Rebirth")
    end))
end

----------------------------------------------------------------------
-- Farm loop
----------------------------------------------------------------------

local lastQuestCurrent = nil
local lastAttack = 0
local lastEngageTime = 0
local farmThread
local acceptedNpc = nil

-- Stand on the mob and swing.
local function engage(mob)
    local mobRoot = mob:FindFirstChild("HumanoidRootPart")
    if not mobRoot then return end

    if State.AutoWeaponSwitch then switchWeapons() else equipWeapon() end

    -- Sit above and slightly behind. Height is what keeps their melee off you;
    -- the horizontal offset just stops you sitting inside the model.
    local targetPos = mobRoot.Position
    local d = tonumber(State.Distance) or 6
    local stand = targetPos + Vector3.new(0, d, d * 0.5)

    -- Aim straight at the mob, pitch included. Measured damage over 7s per config:
    --
    --   d=5  pitch 20139 | flat 20139     (in range either way)
    --   d=10 pitch 14097 | flat     0     (facing is what lands the hit)
    --   d=15 pitch     0 | flat     0     (beyond the weapon's reach entirely)
    --
    -- So facing horizontally makes M1 miss at any useful hover height. It does
    -- tilt the root and leave the humanoid toppled, but damage still lands and
    -- the platform keeps velocity down, which is what actually mattered.
    local function facing(from)
        return CFrame.lookAt(from, targetPos)
    end

    -- Pin every frame. There used to be a 5-stud tolerance here to cut down on
    -- teleports while a platform held the character up. With no platform there is
    -- nothing to stand on, so between teleports it freefalls (measured ~4.6 studs
    -- per tick) until it crosses the threshold and snaps back -- which reads as
    -- drifting backwards right after each teleport. tpTo zeroes velocity, so
    -- pinning every frame costs nothing and holds position exactly.
    tpTo(facing(stand))

    local now = os.clock()
    local delay = State.FastAttack and ATTACK_DELAY or (ATTACK_DELAY * 3)
    if now - lastAttack >= delay then
        lastAttack = now
        attack()
    end

    -- useSkills() now fires every ready skill per pass (see its own comment),
    -- which can cost up to ~0.3s of task.wait if several go off at once. That
    -- used to run right here, inline in the same tick as tpTo() above -- on
    -- the farm this stalled the position-pin between teleports and visibly
    -- made movement choppy. Just mark "still actively fighting" here instead;
    -- the actual firing happens in its own loop below, decoupled from
    -- movement, same as ESP/Anti-AFK already are.
    lastEngageTime = os.clock()
end

-- Mode: one specific mob, no quests involved at all.
--
-- No quest counter to read kills from here, so count deaths directly. This must
-- hook each humanoid exactly once: findMob returns the NEAREST mob, which flips
-- between candidates as we teleport, so hooking on "target changed" attaches
-- dozens of handlers to the same humanoid and one death counts dozens of kills.
-- Weak keys so dead mobs do not pile up.
local hookedMobs = setmetatable({}, { __mode = "k" })
local function stepSelect()
    local target = State.Target
    if not target then
        State.Status = "No target selected"
        return
    end

    local mob = findMob(target)

    if mob then
        local hum = mob:FindFirstChildOfClass("Humanoid")
        if hum and not hookedMobs[hum] then
            hookedMobs[hum] = true
            hum.Died:Once(function() State.Kills = State.Kills + 1 end)
        end
    end
    if not mob then
        -- Travel to where we last saw this type and wait for it to spawn.
        local pos = mobLocation(target)
        if pos then
            tpTo(CFrame.new(pos.X, pos.Y + 8, pos.Z))
            State.Status = "Waiting for " .. target
        else
            State.Status = "No location for " .. target
        end
        return
    end

    State.Status = "Farming " .. target
    engage(mob)
end

-- Mode: follow the quest ladder for your level.
local function stepLevel()
    local quest = getQuest()

    -- Track kills off the quest counter. The counter wraps (5/5 -> 0/5) because
    -- quests repeat themselves, so a drop means a completed cycle, not a reset.
    if quest then
        if lastQuestCurrent then
            if quest.Current >= lastQuestCurrent then
                State.Kills = State.Kills + (quest.Current - lastQuestCurrent)
            else
                State.Kills = State.Kills + ((quest.Max or 0) - lastQuestCurrent) + quest.Current
            end
        end
        lastQuestCurrent = quest.Current
    end

    local best = getBestQuestEntry()
    local holderNpc = acceptedNpc or npcForQuest(quest)
    local needQuest = (not quest) or (holderNpc and best and holderNpc ~= best.Npc.Name)

    if needQuest then
        if not State.AutoQuest then
            State.Status = "No quest (AutoQuest off)"
            return
        end
        local prompt = getPrompt(best and best.Npc)
        if not prompt then
            State.Status = "No quest NPC for your level"
            return
        end

        if quest then
            State.Status = "Cancelling old quest"
            cancelQuest()
        end

        -- Use the NPC's live position only if it looks real; while its island is
        -- streamed out it reads as fallen and would drag us out of the world.
        local npcPos = best.Npc.HumanoidRootPart.Position
        if not sanePos(npcPos) then
            npcPos = npcHome[tostring(best.Npc:GetAttributes().Name)]
            if not npcPos then
                State.Status = "Quest NPC not loaded"
                return
            end
        end

        State.Status = "Accepting quest"
        local stand = CFrame.new(npcPos + Vector3.new(0, 3, 3))
        tpTo(stand)
        task.wait(0.3)

        -- Re-assert position every frame for the whole hold. A single teleport is
        -- not enough: anything that moves the character mid-hold drags us out of
        -- the prompt's range and the accept is silently dropped.
        local ok = pcall(function()
            prompt:InputHoldBegin()
            local deadline = os.clock() + prompt.HoldDuration + 0.15
            while os.clock() < deadline do
                tpTo(stand)
                RunService.Heartbeat:Wait()
            end
            prompt:InputHoldEnd()
        end)
        if not ok then
            pcall(function() fireproximityprompt(prompt) end)
        end

        task.wait(0.6)

        local fresh = getQuest()
        if fresh and best then
            acceptedNpc = best.Npc.Name
            getgenv().__RFF_QUESTMAP[best.Npc.Name] = fresh.Title
        end

        lastQuestCurrent = nil
        return
    end

    -- Joined mid-quest and the map has no entry: assume we are on the right one
    -- rather than cancelling and throwing away existing progress.
    if quest and not acceptedNpc and best then
        acceptedNpc = npcForQuest(quest) or best.Npc.Name
    end

    local mob = findMob(quest.Title)
    if not mob then
        -- Mobs only stream in near the player, so waiting where we stand can wait
        -- forever. Travel to the mob's spot (or its quest giver) and let it spawn.
        local pos = mobLocation(quest.Title)
        if pos then
            tpTo(CFrame.new(pos.X, pos.Y + 8, pos.Z))
        end
        State.Status = "Waiting for " .. tostring(quest.Title)
        return
    end

    State.Status = "Farming " .. quest.Title
    engage(mob)
end

local function stepFarm()
    local hum = getHumanoid()
    local root = getRoot()
    if not root or not hum or hum.Health <= 0 then
        State.Status = "Waiting for character"
        return
    end

    -- If we somehow ended up outside the world, get back before doing anything
    -- else. Chasing mobs from down there is what turns one bad teleport into an
    -- endless descent.
    if not sanePos(root.Position) then
        local spawn = workspace:FindFirstChild("SpawnLocation")
        if spawn then
            root.CFrame = CFrame.new(spawn.Position + Vector3.new(0, 5, 0))
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
        State.Status = "Recovering position"
        task.wait(1)
        return
    end

    cacheNpcHomes()
    rememberMobs()

    -- A live boss outranks whatever else we were doing.
    if State.AutoBoss then
        local boss = findBoss()
        if boss then
            State.Status = "Boss: " .. boss.Name
            engage(boss)
            return
        elseif State.AutoSummon then
            if trySummonBoss() then return end
        end
    end

    if State.FarmMode == "Select" then
        stepSelect()
    else
        stepLevel()
    end
end

local function startFarm()
    if farmThread then return end
    farmThread = task.spawn(function()
        while State.AutoFarm and getgenv().__RFF_GEN == MY_GEN do
            local ok, err = pcall(stepFarm)
            if not ok then State.Status = "Error: " .. tostring(err) end
            RunService.Heartbeat:Wait()
        end
        farmThread = nil
        State.Status = "Idle"
    end)
end

local function stopFarm()
    State.AutoFarm = false
end

-- Event/Moon mobs have no quest NPC, so there is nothing to read them from -- they
-- have to be found by going there. Sweep the island's CURRENT bounding box on a
-- grid, since mobs only stream in within a few hundred studs.
--
-- Everything here is derived live: if an update moves the island, resizes it, or
-- swaps which mobs spawn, the next scan simply reflects that. Names are never
-- hardcoded. Mobs previously learned inside the scanned area that no longer turn
-- up are dropped, so enemies deleted by an update stop appearing in the list.
local SCAN_SPACING = 320
local SCAN_DWELL   = 3.5
local SCAN_MAX_POINTS = 16

local scanning = false

-- Sweep any rectangular region and learn what lives there. Used for both a named
-- island and "wherever I am standing", so areas that are not under workspace.island
-- (the Moon, any future event zone) are reachable with the same code.
local function scanRegion(centre, size, label, onDone)
    if scanning then return end
    scanning = true

    local wasFarming = State.AutoFarm
    State.AutoFarm = false
    task.wait(0.25)

    local nx = math.clamp(math.ceil(size.X / SCAN_SPACING), 1, 4)
    local nz = math.clamp(math.ceil(size.Z / SCAN_SPACING), 1, 4)
    if nx * nz > SCAN_MAX_POINTS then nx, nz = 4, 4 end

    local startCF = getRoot() and getRoot().CFrame
    local foundHere = {}
    local point, total = 0, nx * nz

    for ix = 1, nx do
        for iz = 1, nz do
            if getgenv().__RFF_GEN ~= MY_GEN then break end
            point = point + 1
            local fx = (nx == 1) and 0.5 or ((ix - 1) / (nx - 1))
            local fz = (nz == 1) and 0.5 or ((iz - 1) / (nz - 1))
            local dest = Vector3.new(
                centre.X - size.X / 2 + size.X * fx,
                centre.Y + size.Y / 2,
                centre.Z - size.Z / 2 + size.Z * fz)

            State.Status = string.format("Scanning %s %d/%d", label, point, total)
            local deadline = os.clock() + SCAN_DWELL
            while os.clock() < deadline do
                tpTo(CFrame.new(dest))
                RunService.Heartbeat:Wait()
            end

            local folder = workspace:FindFirstChild("Mob")
            if folder then
                for _, m in ipairs(folder:GetChildren()) do
                    local hrp = m:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        foundHere[m.Name] = true
                        getgenv().__RFF_MOBS[m.Name] =
                            { x = hrp.Position.X, y = hrp.Position.Y, z = hrp.Position.Z }
                    end
                end
            end
        end
    end

    -- Prune anything we had learned inside this island that is no longer there.
    -- Quest mobs are left alone: they come from the NPCs, not from scanning.
    local questMobs = {}
    for _, e in ipairs(mobCatalog()) do questMobs[e.name] = true end
    local minX, maxX = centre.X - size.X / 2, centre.X + size.X / 2
    local minZ, maxZ = centre.Z - size.Z / 2, centre.Z + size.Z / 2
    local removed = {}
    for name, e in pairs(getgenv().__RFF_MOBS) do
        if not questMobs[name] and not foundHere[name] and e.x then
            if e.x >= minX and e.x <= maxX and e.z >= minZ and e.z <= maxZ then
                getgenv().__RFF_MOBS[name] = nil
                removed[#removed + 1] = name
            end
        end
    end

    if startCF then tpTo(startCF) end
    scanning = false

    local names = {}
    for n in pairs(foundHere) do names[#names + 1] = n end
    State.Status = string.format("%s: %d mobs%s", label, #names,
        #removed > 0 and (", " .. #removed .. " gone") or "")

    if onDone then pcall(onDone) end
    if wasFarming then
        State.AutoFarm = true
        startFarm()
    end
end

-- Scan a named island, resolved live from its current bounding box. The name match
-- is loose so a rename like "Event Island 2" still resolves instead of silently
-- scanning nothing.
local function scanIsland(islandName, onDone)
    local islands = workspace:FindFirstChild("island")
    local isl = islands and islands:FindFirstChild(islandName)
    if not isl and islands then
        local want = islandName:lower():gsub("%s*island%s*", "")
        for _, v in ipairs(islands:GetChildren()) do
            if v.Name:lower():find(want, 1, true) then isl = v break end
        end
    end
    if not isl then
        State.Status = "No island: " .. islandName
        if onDone then pcall(onDone) end
        return
    end
    local cf, size = isl:GetBoundingBox()
    scanRegion(cf.Position, size, isl.Name, onDone)
end

-- Scan around wherever the player currently stands. This is the one that works
-- for the Moon and anything else that is not a child of workspace.island.
local function scanHere(onDone)
    local root = getRoot()
    if not root then
        State.Status = "No character"
        if onDone then pcall(onDone) end
        return
    end
    scanRegion(root.Position, Vector3.new(900, 400, 900), "this area", onDone)
end


----------------------------------------------------------------------
-- Watchdog
----------------------------------------------------------------------
-- If farming is on but nothing has died for a while, something is wrong -- dead
-- and not respawning, wedged in terrain, mobs never streaming in. Try resetting
-- the character first, and only if that fails twice tell the player to rejoin.
--
-- The rejoin prompt is deliberately once per session (flag lives in getgenv, so
-- reloading the script will not make it reappear) and dismissable, because some
-- stalls are just a slow mob respawn and not worth nagging about.

local STUCK_SECONDS = 90   -- no kills for this long while farming = stuck
local MAX_RESETS    = 2    -- resets to try before giving up and asking to rejoin

local showStuckPopup  -- assigned once the UI exists

task.spawn(function()
    local lastKills = State.Kills
    local lastChange = os.clock()
    local resets = 0

    while getgenv().__RFF_GEN == MY_GEN do
        task.wait(5)

        if not State.AutoFarm then
            lastKills = State.Kills
            lastChange = os.clock()
            resets = 0
        else
            local hum = getHumanoid()
            local dead = (not hum) or hum.Health <= 0

            if State.Kills ~= lastKills then
                lastKills = State.Kills
                lastChange = os.clock()
                resets = 0
            elseif dead or (os.clock() - lastChange) > STUCK_SECONDS then
                -- Respawning is destructive on this executor: it kills the game's
                -- own Anims/ClientEvent scripts, and ClientEvent binds Run/Dash.
                -- So sprint and dash die until you rejoin.
                --
                -- That cost only applies while you are ALIVE. If you are already
                -- dead and not coming back, the death has broken them anyway, so
                -- forcing a respawn there is free and needs no permission.
                local deadTooLong = dead and (os.clock() - lastChange) > 20

                if deadTooLong and resets < MAX_RESETS then
                    resets = resets + 1
                    State.Status = string.format("Dead - respawning (%d/%d)", resets, MAX_RESETS)
                    local ok = resetCharacter()
                    lastChange = os.clock()
                    if not ok and showStuckPopup then showStuckPopup() end
                elseif not dead then
                    -- Alive but making no progress. A reset would cost sprint and
                    -- dash, so say so rather than doing it behind your back.
                    State.Status = "Stuck - rejoin needed"
                    if showStuckPopup then showStuckPopup() end
                    lastChange = os.clock()  -- stop hammering
                end
            end
        end
    end
end)

-- Stat spender: independent of farming so banked points get used while idle too.
task.spawn(function()
    while getgenv().__RFF_GEN == MY_GEN do
        pcall(spendStats)
        task.wait(2)
    end
end)

-- Haki keeper: runs regardless of farming, so it comes back on after a death
-- whether or not you were farming at the time.
task.spawn(function()
    while getgenv().__RFF_GEN == MY_GEN do
        pcall(keepHaki)
        task.wait(1)
    end
end)

-- Gacha roller: also independent of farming, so gems get spent while idle.
task.spawn(function()
    while getgenv().__RFF_GEN == MY_GEN do
        pcall(rollGacha)
        task.wait(3)
    end
end)

-- Rebirth watcher: independent of the farm loop so it still fires while idle.
task.spawn(function()
    while getgenv().__RFF_GEN == MY_GEN do
        if State.AutoRebirth and isMaxLevel() then
            State.Status = "Rebirthing"
            pcall(doRebirth)
            task.wait(6)
        end
        task.wait(2)
    end
end)

----------------------------------------------------------------------
-- Utils
----------------------------------------------------------------------

-- Anti-AFK: Roblox's own idle-kick fires LocalPlayer.Idled after a few minutes
-- of no input. A no-op keypress resets that timer without doing anything else.
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

-- No FPS toggle: setfpscap/getfpscap exist as functions on this executor (do
-- not error, return values) but are non-functional no-ops on this client.
-- Measured with RunService.RenderStepped over real time, independent of the
-- executor's own (separately unreliable) getfpscap() readback: setfpscap(5)
-- measured 373.7 fps against a 374 fps baseline -- zero effect, not just
-- imprecise. Do not re-add a cap-based FPS feature without re-measuring first;
-- the function existing and returning ok=true proves nothing on its own.

-- ESP: a Highlight instance renders through walls/terrain when set to
-- AlwaysOnTop, which is a plain built-in Roblox Instance -- no executor-specific
-- drawing API required, so this works regardless of what Xeno does or doesn't
-- expose beyond that. One Highlight + one distance/HP label per live target,
-- added and removed as targets appear/die/leave.
local espHighlights = {}   -- [model] = { highlight = Highlight, gui = BillboardGui }

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
    gui.Name = "RFF_ESP"
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
        -- Bosses too, same folder pattern as findBoss().
        local bossFolder = workspace:FindFirstChild("Boss")
        if bossFolder then
            for _, m in ipairs(bossFolder:GetChildren()) do
                local hum = m:FindFirstChildOfClass("Humanoid")
                local hrp = m:FindFirstChild("HumanoidRootPart")
                if hum and hrp and hum.Health > 0 then
                    wanted[m] = true
                    espEnsure(m, ESP_MOB_COLOR)
                    local entry = espHighlights[m]
                    if entry and root then
                        local d = math.floor((hrp.Position - root.Position).Magnitude)
                        entry.label.Text = string.format("%s (Boss)\n%d studs - %d%% HP",
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

    -- Drop anything that died, left, or is no longer wanted (ESP switched off).
    for model in pairs(espHighlights) do
        if not wanted[model] then espRemove(model) end
    end
end

-- Settings save/load, as NAMED PRESETS rather than one slot -- e.g. a
-- "Farming" preset and a separate "Boss" preset. Each preset is its own file
-- under SETTINGS_DIR; META_PATH is a small separate pointer file recording
-- which preset to auto-load and whether to, since that decision has to be
-- readable before any preset's own content has been loaded (a preset's
-- AutoLoadSettings flag cannot be its own trigger).
--
-- Nested tables (WeaponSkills.Melee/.Sword, StatPick) are merged key-by-key
-- into the EXISTING table objects rather than replaced outright -- the UI's
-- chip rows captured those specific table references when they were built, so
-- swapping in a new table would desync the chips from what the game logic
-- actually reads.
local SETTINGS_DIR = "MaikoHub/settings/rockfruit"
local META_PATH = "MaikoHub/settings/rockfruit_meta.json"
-- listfiles() on this Xeno client is unreliable: measured it returning 0
-- results for a real directory moments after correctly returning 2, with zero
-- writes/deletes in between and isfile() confirming the files never left disk.
-- So the preset list is tracked in this manifest instead of ever calling
-- listfiles() -- same "don't trust the executor readback" fix as setfpscap.
local INDEX_PATH = "MaikoHub/settings/rockfruit_index.json"

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
            if k ~= "Status" and k ~= "Kills" then copy[k] = v end
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

local applySettingsToUI  -- assigned once the UI exists, so Load can refresh it

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

-- Boot-time auto-load, before the UI exists (applySettingsToUI being nil here
-- is fine -- nothing to refresh yet). Reads the meta pointer, not a preset's
-- own flag, since a preset cannot gate its own loading.
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
    while getgenv().__RFF_GEN == MY_GEN do
        pcall(applyAntiAFK)
        pcall(checkPotions)
        if State.MobESP or State.PlayerESP or next(espHighlights) then
            pcall(updateESP)
        end
        task.wait(0.5)
    end
end)

-- useSkills() fires every ready skill per pass now, which can cost up to
-- ~0.3s of task.wait if several go off together -- used to run inline inside
-- engage()'s tick (same coroutine as tpTo()), which visibly stalled the
-- farm's position-pin between teleports. Its own loop here keeps that cost
-- off the movement thread; ENGAGE_WINDOW just keeps "only cast while
-- actually on a mob" (cooldowns shouldn't burn while walking around) without
-- needing engage() to call it directly.
local ENGAGE_WINDOW = 0.5
task.spawn(function()
    while getgenv().__RFF_GEN == MY_GEN do
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

local existing = parentGui:FindFirstChild("RockFruitFarmUI")
if existing then existing:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "RockFruitFarmUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parentGui

local PANEL_W, PANEL_H = 320, 600

-- Every row that has visual state derived from State registers its render
-- function here, so a programmatic change (Load Settings) can refresh the
-- whole panel in one pass instead of every row needing its own bespoke hook.
-- allRenderers is populated progressively as rows below get built; this
-- closure captures it by reference, so it sees everything registered by the
-- time it is actually called (on a Load click), not just what exists right now.
local allRenderers = {}
local function registerRenderer(fn) allRenderers[#allRenderers + 1] = fn end
applySettingsToUI = function()
    for _, fn in ipairs(allRenderers) do pcall(fn) end
end

local function corner(parent, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 10)
    c.Parent = parent
    return c
end

local function stroke(parent, color, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or Theme.stroke
    s.Thickness = thickness or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Parent = parent
    return s
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
stroke(root, Theme.stroke, 1)

-- Header ------------------------------------------------------------
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 56)
header.BackgroundTransparency = 1
header.Parent = root

local logo = makeIcon(header, Icon.swords, Theme.accent, 22)
logo.Position = UDim2.fromOffset(18, 17)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(48, 13)
title.Size = UDim2.new(1, -120, 0, 16)
title.Font = Enum.Font.GothamBold
title.Text = "Rock Fruit"
title.TextColor3 = Theme.text
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(48, 31)
subtitle.Size = UDim2.new(1, -120, 0, 14)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Auto Farm"
subtitle.TextColor3 = Theme.muted
subtitle.TextSize = 12
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

local function headerButton(icon, xOffset)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(28, 28)
    btn.Position = UDim2.new(1, xOffset, 0, 14)
    btn.BackgroundColor3 = Theme.card
    btn.AutoButtonColor = false
    btn.Text = ""
    btn.Parent = header
    corner(btn, 9)
    local i = makeIcon(btn, icon, Theme.muted, 14)
    i.AnchorPoint = Vector2.new(0.5, 0.5)
    i.Position = UDim2.fromScale(0.5, 0.5)
    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.cardAlt }):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.card }):Play()
    end)
    return btn
end

local closeBtn = headerButton(Icon.x, -40)
local minBtn   = headerButton(Icon.minus, -76)

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -36, 0, 1)
divider.Position = UDim2.fromOffset(18, 56)
divider.BackgroundColor3 = Theme.stroke
divider.BorderSizePixel = 0
divider.Parent = root

-- Body --------------------------------------------------------------
local body = Instance.new("Frame")
body.Name = "Body"
body.Position = UDim2.fromOffset(0, 65)
body.Size = UDim2.new(1, 0, 1, -65)
body.BackgroundTransparency = 1
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

local orders = {}
local function nextOrder(parent)
    orders[parent] = (orders[parent] or 0) + 1
    return orders[parent]
end

-- Status card
local statusCard = Instance.new("Frame")
statusCard.Size = UDim2.new(1, 0, 0, 84)
statusCard.BackgroundColor3 = Theme.card
statusCard.BorderSizePixel = 0
statusCard.LayoutOrder = nextOrder(body)
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

local function statLine(parent, icon, y)
    local i = makeIcon(parent, icon, Theme.muted, 13)
    i.Position = UDim2.fromOffset(14, y)
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(33, y - 2)
    lbl.Size = UDim2.new(1, -46, 0, 16)
    lbl.Font = Enum.Font.Gotham
    lbl.Text = "-"
    lbl.TextColor3 = Theme.muted
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextTruncate = Enum.TextTruncate.AtEnd
    lbl.Parent = parent
    return lbl
end

local questLabel = statLine(statusCard, Icon.target, 40)
local killsLabel = statLine(statusCard, Icon.coins, 62)

-- Tabs
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, 36)
tabBar.BackgroundColor3 = Theme.cardAlt
tabBar.BorderSizePixel = 0
tabBar.LayoutOrder = nextOrder(body)
tabBar.Parent = body
corner(tabBar, 10)

local pageHolder = Instance.new("Frame")
pageHolder.Size = UDim2.new(1, 0, 1, -164)
pageHolder.BackgroundTransparency = 1
pageHolder.LayoutOrder = nextOrder(body)
pageHolder.Parent = body

-- Pages scroll, so adding rows can never clip the panel.
local function makePage()
    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.fromScale(1, 1)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 3
    page.ScrollBarImageColor3 = Theme.stroke
    page.CanvasSize = UDim2.new()
    page.AutomaticCanvasSize = Enum.AutomaticSize.Y
    page.ScrollingDirection = Enum.ScrollingDirection.Y
    page.Visible = false
    page.Parent = pageHolder
    local l = Instance.new("UIListLayout")
    l.Padding = UDim.new(0, 10)
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = page
    local p = Instance.new("UIPadding")
    p.PaddingRight = UDim.new(0, 8)
    p.PaddingBottom = UDim.new(0, 12)
    p.Parent = page
    return page
end

-- Five pages rather than one long scroll. Everything used to live on a single
-- page which grew to 1394px of content in a 299px viewport -- technically fine
-- since it scrolls, but miserable to actually use.
local pageFarm     = makePage()
local pageCombat   = makePage()
local pageExtra    = makePage()
local pageUtils    = makePage()
local pageTeleport = makePage()
local pageServer   = makePage()

local TABS = {
    { name = "Farm",   page = pageFarm },
    { name = "Fight",  page = pageCombat },
    { name = "Extra",  page = pageExtra },
    { name = "Utils",  page = pageUtils },
    { name = "Move",   page = pageTeleport },
    { name = "Server", page = pageServer },
}
local TAB_W = 1 / #TABS

local tabHighlight = Instance.new("Frame")
tabHighlight.Size = UDim2.new(TAB_W, -4, 1, -4)
tabHighlight.Position = UDim2.fromOffset(2, 2)
tabHighlight.BackgroundColor3 = Theme.accent
tabHighlight.BorderSizePixel = 0
tabHighlight.Parent = tabBar
corner(tabHighlight, 7)

-- Populated later, once each tab's own section defines what "fresh" means for
-- it. Right now only Move uses this, to reread the island list on every visit.
local tabShownCallbacks = {}

local tabButtons = {}
local function selectTab(name)
    for idx, tab in ipairs(TABS) do
        tab.page.Visible = (tab.name == name)
        if tab.name == name then
            TweenService:Create(tabHighlight, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
                Position = UDim2.new(TAB_W * (idx - 1), 2, 0, 2),
            }):Play()
        end
    end
    for tabName, btn in pairs(tabButtons) do
        btn.TextColor3 = (tabName == name) and Color3.new(1, 1, 1) or Theme.muted
    end
    if tabShownCallbacks[name] then tabShownCallbacks[name]() end
end

for idx, tab in ipairs(TABS) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(TAB_W, 0, 1, 0)
    btn.Position = UDim2.new(TAB_W * (idx - 1), 0, 0, 0)
    btn.BackgroundTransparency = 1
    btn.AutoButtonColor = false
    btn.Font = Enum.Font.GothamMedium
    btn.Text = tab.name
    btn.TextSize = 12
    btn.TextColor3 = Theme.muted
    btn.Parent = tabBar
    btn.MouseButton1Click:Connect(function() selectTab(tab.name) end)
    tabButtons[tab.name] = btn
end
selectTab("Farm")

-- Row builders --------------------------------------------------------
-- Section heading with a hairline running to the right edge, so groups read as
-- distinct blocks instead of one long list of rows.
local function sectionLabel(parent, text)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 20)
    row.BackgroundTransparency = 1
    row.LayoutOrder = nextOrder(parent)
    row.Parent = parent

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

    -- TextBounds is only known once it has rendered, so re-fit next frame.
    task.defer(function()
        if line.Parent then
            line.Size = UDim2.new(1, -(l.TextBounds.X + 10), 0, 1)
        end
    end)
    return row
end

local function toggleRow(parent, icon, text, key, onChange)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.AutoButtonColor = false
    row.Text = ""
    row.LayoutOrder = nextOrder(parent)
    row.Parent = parent
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
        TweenService:Create(track, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
            BackgroundColor3 = on and Theme.accent or Theme.cardAlt,
        }):Play()
        TweenService:Create(knob, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
            Position = on and UDim2.new(1, -22, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
            BackgroundColor3 = on and Color3.new(1, 1, 1) or Theme.muted,
        }):Play()
        TweenService:Create(i, TweenInfo.new(0.18), {
            ImageColor3 = on and Theme.accent or Theme.muted,
        }):Play()
    end

    row.MouseButton1Click:Connect(function()
        State[key] = not State[key]
        render()
        if onChange then onChange(State[key]) end
    end)

    registerRenderer(render)
    render()
    return row, render
end

-- Two-option segmented control bound to a State key.
local function segmentRow(parent, icon, text, key, options, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder(parent)
    row.Parent = parent
    corner(row, 11)

    local i = makeIcon(row, icon, Theme.muted, 16)
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
        TweenService:Create(highlight, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
            Position = UDim2.fromOffset(State[key] == options[1] and 2 or 62, 2),
        }):Play()
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
        btn.MouseButton1Click:Connect(function()
            State[key] = name
            render()
            if onChange then onChange(name) end
        end)
        buttons[name] = btn
    end

    registerRenderer(render)
    render()
    return row
end

-- Row of toggle chips bound to a table of booleans. Used for both the skill cast
-- keys and the stat picker, so they look and behave the same.
local function chipRow(parent, icon, text, stateTable, keys, labels, chipW)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder(parent)
    row.Parent = parent
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
        chip.Text = labels and labels[idx] or key
        chip.TextSize = 11
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
        registerRenderer(render)
        render()
    end
    return row
end


-- Draggable slider bound to a numeric State key.
local function sliderRow(parent, icon, text, key, minVal, maxVal, suffix)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 60)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder(parent)
    row.Parent = parent
    corner(row, 11)

    local i = makeIcon(row, icon, Theme.muted, 16)
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
        local a = (State[key] - minVal) / (maxVal - minVal)
        a = math.clamp(a, 0, 1)
        fill.Size = UDim2.fromScale(a, 1)
        knob.Position = UDim2.fromScale(a, 0.5)
        valueLbl.Text = tostring(State[key]) .. (suffix or "")
    end

    -- GuiInset only offsets Y, so comparing raw X against AbsolutePosition is fine.
    local function setFromX(x)
        local a = (x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1)
        a = math.clamp(a, 0, 1)
        State[key] = math.floor(minVal + a * (maxVal - minVal) + 0.5)
        render()
    end

    local dragging = false
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            setFromX(input.Position.X)
        end
    end)

    registerRenderer(render)
    render()
    return row
end

-- Single-select chips: exactly one option stays lit, stored as a string on State.
local function choiceRow(parent, icon, text, key, options, chipW)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 46)
    row.BackgroundColor3 = Theme.card
    row.BorderSizePixel = 0
    row.LayoutOrder = nextOrder(parent)
    row.Parent = parent
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

local function actionRow(parent, icon, text, subtitle, onClick)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, subtitle and 58 or 46)
    row.BackgroundColor3 = Theme.card
    row.AutoButtonColor = false
    row.Text = ""
    row.LayoutOrder = nextOrder(parent)
    row.Parent = parent
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

----------------------------------------------------------------------
-- Farm tab
----------------------------------------------------------------------

sectionLabel(pageFarm, "Farming")

local targetRow, targetValue, targetList, refreshTargets

segmentRow(pageFarm, Icon.settings, "Mode", "FarmMode", { "Level", "Select" }, function()
    if targetRow then
        targetRow.Visible = (State.FarmMode == "Select")
        targetList.Visible = false
        targetList.Size = UDim2.new(1, 0, 0, 0)
    end
end)

toggleRow(pageFarm, Icon.swords, "Auto Farm", "AutoFarm", function(on)
    if on then
        State.AutoFarm = true
        startFarm()
    else
        stopFarm()
    end
end)

toggleRow(pageFarm, Icon.mappin, "Auto Accept Quest", "AutoQuest")

-- Target picker (Select mode only) -----------------------------------
targetRow = Instance.new("TextButton")
targetRow.Size = UDim2.new(1, 0, 0, 46)
targetRow.BackgroundColor3 = Theme.card
targetRow.AutoButtonColor = false
targetRow.Text = ""
targetRow.Visible = false
targetRow.LayoutOrder = nextOrder(pageFarm)
targetRow.Parent = pageFarm
corner(targetRow, 11)

do
    local i = makeIcon(targetRow, Icon.target, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(1, -60, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = "Target"
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = targetRow

    targetValue = Instance.new("TextLabel")
    targetValue.BackgroundTransparency = 1
    targetValue.AnchorPoint = Vector2.new(1, 0.5)
    targetValue.Position = UDim2.new(1, -30, 0.5, 0)
    targetValue.Size = UDim2.new(0, 130, 0, 16)
    targetValue.Font = Enum.Font.Gotham
    targetValue.Text = "none"
    targetValue.TextColor3 = Theme.muted
    targetValue.TextSize = 12
    targetValue.TextXAlignment = Enum.TextXAlignment.Right
    targetValue.TextTruncate = Enum.TextTruncate.AtEnd
    targetValue.Parent = targetRow

    local chev = makeIcon(targetRow, Icon.chevron, Theme.muted, 14)
    chev.AnchorPoint = Vector2.new(1, 0.5)
    chev.Position = UDim2.new(1, -14, 0.5, 0)
end

targetList = Instance.new("ScrollingFrame")
targetList.Size = UDim2.new(1, 0, 0, 0)
targetList.BackgroundColor3 = Theme.cardAlt
targetList.BorderSizePixel = 0
targetList.ScrollBarThickness = 3
targetList.ScrollBarImageColor3 = Theme.stroke
targetList.CanvasSize = UDim2.new()
targetList.AutomaticCanvasSize = Enum.AutomaticSize.Y
targetList.Visible = false
targetList.LayoutOrder = nextOrder(pageFarm)
targetList.Parent = pageFarm
corner(targetList, 11)

do
    local l = Instance.new("UIListLayout")
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = targetList
end

refreshTargets = function()
    for _, c in ipairs(targetList:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
    end
    local mobs = knownMobs()
    if #mobs == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, 0, 0, 34)
        empty.BackgroundTransparency = 1
        empty.Font = Enum.Font.Gotham
        empty.Text = "  no quest NPCs found"
        empty.TextColor3 = Theme.muted
        empty.TextSize = 11
        empty.TextXAlignment = Enum.TextXAlignment.Left
        empty.Parent = targetList
        return
    end
    for idx, mob in ipairs(mobs) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, 0, 0, 34)
        item.BackgroundTransparency = 1
        item.AutoButtonColor = false
        item.Font = Enum.Font.Gotham
        item.Text = "  " .. mob.name
        item.TextColor3 = (State.Target == mob.name) and Theme.accent or Theme.text
        item.TextSize = 12
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.LayoutOrder = idx
        item.Parent = targetList

        local lvl = Instance.new("TextLabel")
        lvl.BackgroundTransparency = 1
        lvl.AnchorPoint = Vector2.new(1, 0.5)
        lvl.Position = UDim2.new(1, -10, 0.5, 0)
        lvl.Size = UDim2.fromOffset(60, 14)
        lvl.Font = Enum.Font.Gotham
        lvl.Text = mob.lvl and ("Lv." .. mob.lvl) or "?"
        lvl.TextColor3 = Theme.muted
        lvl.TextSize = 11
        lvl.TextXAlignment = Enum.TextXAlignment.Right
        lvl.Parent = item

        item.MouseButton1Click:Connect(function()
            State.Target = mob.name
            targetValue.Text = mob.name
            targetValue.TextColor3 = Theme.accent
            targetList.Visible = false
            targetList.Size = UDim2.new(1, 0, 0, 0)
            refreshTargets()
        end)
    end
end

targetRow.MouseButton1Click:Connect(function()
    local opening = not targetList.Visible
    if opening then refreshTargets() end
    targetList.Visible = opening
    targetList.Size = opening and UDim2.new(1, 0, 0, 136) or UDim2.new(1, 0, 0, 0)
end)

actionRow(pageFarm, Icon.crosshair, "Scan Event Island", "Finds event mobs (~55s)", function()
    task.spawn(function()
        scanIsland("Event Island", function() refreshTargets() end)
    end)
end)

actionRow(pageFarm, Icon.mappin, "Scan Here", "Sweeps where you stand - use on Moon", function()
    task.spawn(function()
        scanHere(function() refreshTargets() end)
    end)
end)


sectionLabel(pageFarm, "Boss")

toggleRow(pageFarm, Icon.crosshair, "Auto Boss", "AutoBoss")
toggleRow(pageFarm, Icon.star, "Auto Summon Boss", "AutoSummon")

-- Boss picker: "Any" (fight/summon whichever) or one exact boss from
-- SpawnBossList. Same dropdown pattern as the mob Target picker below.
local bossRow = Instance.new("TextButton")
bossRow.Size = UDim2.new(1, 0, 0, 46)
bossRow.BackgroundColor3 = Theme.card
bossRow.AutoButtonColor = false
bossRow.Text = ""
bossRow.LayoutOrder = nextOrder(pageFarm)
bossRow.Parent = pageFarm
corner(bossRow, 11)

local bossValue
do
    local i = makeIcon(bossRow, Icon.crosshair, Theme.muted, 16)
    i.Position = UDim2.fromOffset(14, 15)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(40, 0)
    lbl.Size = UDim2.new(1, -60, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = "Boss"
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 13
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = bossRow

    bossValue = Instance.new("TextLabel")
    bossValue.BackgroundTransparency = 1
    bossValue.AnchorPoint = Vector2.new(1, 0.5)
    bossValue.Position = UDim2.new(1, -30, 0.5, 0)
    bossValue.Size = UDim2.new(0, 130, 0, 16)
    bossValue.Font = Enum.Font.Gotham
    bossValue.Text = "Any"
    bossValue.TextColor3 = Theme.muted
    bossValue.TextSize = 12
    bossValue.TextXAlignment = Enum.TextXAlignment.Right
    bossValue.TextTruncate = Enum.TextTruncate.AtEnd
    bossValue.Parent = bossRow

    local chev = makeIcon(bossRow, Icon.chevron, Theme.muted, 14)
    chev.AnchorPoint = Vector2.new(1, 0.5)
    chev.Position = UDim2.new(1, -14, 0.5, 0)
end

local bossList = Instance.new("ScrollingFrame")
bossList.Size = UDim2.new(1, 0, 0, 0)
bossList.BackgroundColor3 = Theme.cardAlt
bossList.BorderSizePixel = 0
bossList.ScrollBarThickness = 3
bossList.ScrollBarImageColor3 = Theme.stroke
bossList.CanvasSize = UDim2.new()
bossList.AutomaticCanvasSize = Enum.AutomaticSize.Y
bossList.Visible = false
bossList.LayoutOrder = nextOrder(pageFarm)
bossList.Parent = pageFarm
corner(bossList, 11)
do
    local l = Instance.new("UIListLayout")
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = bossList
end

local refreshBossList
refreshBossList = function()
    for _, c in ipairs(bossList:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
    end

    local options = { { name = "Any", item = nil } }
    for _, e in ipairs(bossCatalog()) do options[#options + 1] = e end

    for idx, e in ipairs(options) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, 0, 0, 34)
        item.BackgroundTransparency = 1
        item.AutoButtonColor = false
        item.Font = Enum.Font.Gotham
        item.Text = "  " .. e.name
        item.TextColor3 = (State.BossPick == e.name) and Theme.accent or Theme.text
        item.TextSize = 12
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.LayoutOrder = idx
        item.Parent = bossList

        if e.item then
            local req = Instance.new("TextLabel")
            req.BackgroundTransparency = 1
            req.AnchorPoint = Vector2.new(1, 0.5)
            req.Position = UDim2.new(1, -10, 0.5, 0)
            req.Size = UDim2.fromOffset(90, 14)
            req.Font = Enum.Font.Gotham
            req.Text = e.item
            req.TextColor3 = Theme.muted
            req.TextSize = 11
            req.TextXAlignment = Enum.TextXAlignment.Right
            req.TextTruncate = Enum.TextTruncate.AtEnd
            req.Parent = item
        end

        item.MouseButton1Click:Connect(function()
            State.BossPick = e.name
            bossValue.Text = e.name
            bossValue.TextColor3 = (e.name == "Any") and Theme.muted or Theme.accent
            bossList.Visible = false
            bossList.Size = UDim2.new(1, 0, 0, 0)
            refreshBossList()
        end)
    end
end

bossRow.MouseButton1Click:Connect(function()
    local opening = not bossList.Visible
    if opening then refreshBossList() end
    bossList.Visible = opening
    bossList.Size = opening and UDim2.new(1, 0, 0, 104) or UDim2.new(1, 0, 0, 0)
end)

local bossNote = Instance.new("TextLabel")
bossNote.BackgroundTransparency = 1
bossNote.Size = UDim2.new(1, 0, 0, 44)
bossNote.Font = Enum.Font.Gotham
bossNote.Text = "Auto Boss kills a live boss first. Summoning needs\nits item -- Orb Boss for both right now."
bossNote.TextColor3 = Theme.muted
bossNote.TextSize = 11
bossNote.TextWrapped = true
bossNote.TextXAlignment = Enum.TextXAlignment.Left
bossNote.TextYAlignment = Enum.TextYAlignment.Top
bossNote.LayoutOrder = nextOrder(pageFarm)
bossNote.Parent = pageFarm

-- Consistent explanatory note under a section.
local function noteLabel(parent, text, height)
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
    l.LayoutOrder = nextOrder(parent)
    l.Parent = parent
    return l
end

----------------------------------------------------------------------
-- Fight tab
----------------------------------------------------------------------

sectionLabel(pageCombat, "Combat")

toggleRow(pageCombat, Icon.shield, "Auto Equip Weapon", "AutoEquip")
toggleRow(pageCombat, Icon.fist, "Auto Haki", "AutoHaki")
toggleRow(pageCombat, Icon.flame, "Auto Skills", "AutoSkills")
chipRow(pageCombat, Icon.star, "Melee Keys", State.WeaponSkills.Melee,
    { "Z", "X", "C", "V", "F" }, nil, 24)
chipRow(pageCombat, Icon.star, "Sword Keys", State.WeaponSkills.Sword,
    { "Z", "X", "C", "V", "F" }, nil, 24)
chipRow(pageCombat, Icon.star, "Fruit Keys", State.WeaponSkills.Fruit,
    { "Z", "X", "C", "V", "F" }, nil, 24)
toggleRow(pageCombat, Icon.activity, "Fast Attack", "FastAttack")
toggleRow(pageCombat, Icon.swords, "Weapon Switcher", "AutoWeaponSwitch")
chipRow(pageCombat, Icon.swords, "Switch Between", State.SwitchWeapons,
    { "Sword", "Melee", "Fruit" }, nil, 52)
choiceRow(pageCombat, Icon.sword, "Weapon", "Weapon", { "Melee", "Sword", "Fruit" }, 46)
sliderRow(pageCombat, Icon.gauge, "Distance", "Distance", DIST_MIN, DIST_MAX, " studs")

noteLabel(pageCombat,
    "Weapon reach is about 10 studs. Lower hits harder,\nhigher keeps mobs off you.\nSwitcher rotates through whichever categories are\nlit in Switch Between (each has its own cooldowns) --\na category you don't own is skipped automatically.\nWeapon picks the starting one and what M1 uses when\neverything enabled is on cooldown. The Keys rows choose\nwhich skills each category casts.")

----------------------------------------------------------------------
-- Extra tab
----------------------------------------------------------------------

sectionLabel(pageExtra, "Progression")

toggleRow(pageExtra, Icon.gauge, "Auto Stats", "AutoStats")
chipRow(pageExtra, Icon.star, "Spend On", State.StatPick,
    { "Melee", "Defense", "Sword", "Power" }, { "MEL", "DEF", "SWD", "PWR" }, 38)
toggleRow(pageExtra, Icon.package, "Auto Rebirth", "AutoRebirth")

noteLabel(pageExtra,
    "Rebirth fires only at max level. Keeps money and\nitems, resets your level.")

sectionLabel(pageExtra, "Gacha")

toggleRow(pageExtra, Icon.coins, "Auto Gacha", "AutoGacha")
choiceRow(pageExtra, Icon.star, "Source", "GachaSource", { "Random", "Moon" }, 58)
choiceRow(pageExtra, Icon.chevron, "Batch", "GachaTier", { "x5", "x10", "x15" }, 38)
sliderRow(pageExtra, Icon.gauge, "Keep Currency", "KeepGems", 0, 20000, "")

noteLabel(pageExtra,
    "Random spends gems, Moon spends event stones.\nEvery batch size costs the same per roll.")

local hint = Instance.new("TextLabel")
hint.BackgroundTransparency = 1
hint.Size = UDim2.new(1, 0, 0, 22)
hint.Font = Enum.Font.Gotham
hint.Text = "Right Ctrl toggles the menu"
hint.TextColor3 = Theme.muted
hint.TextSize = 11
hint.TextXAlignment = Enum.TextXAlignment.Center
hint.LayoutOrder = nextOrder(pageFarm)
hint.Parent = pageFarm

----------------------------------------------------------------------
-- Utils tab
----------------------------------------------------------------------

sectionLabel(pageUtils, "Quality of Life")

toggleRow(pageUtils, Icon.activity, "Anti-AFK", "AntiAFK", function() applyAntiAFK() end)

noteLabel(pageUtils,
    "Anti-AFK resets Roblox's idle-kick timer.\n(An FPS toggle was tried and dropped: setfpscap()\nmeasurably does nothing on this client, not just\nsomething cosmetic -- 5 vs 999 gave the same real fps.)")

sectionLabel(pageUtils, "ESP")

toggleRow(pageUtils, Icon.crosshair, "Mob ESP", "MobESP")
toggleRow(pageUtils, Icon.user, "Player ESP", "PlayerESP")

noteLabel(pageUtils,
    "Highlights through walls/terrain, with distance and\nHP. Mob ESP also covers live bosses. Range is capped\nby the game itself, not this script: mobs only exist\nas objects once you are close enough for them to\nstream in, so nothing further away can be shown.")

sectionLabel(pageUtils, "Potions")

toggleRow(pageUtils, Icon.flame, "Auto Potion", "AutoPotion")
chipRow(pageUtils, Icon.star, "Auto-Use", State.PotionSelect,
    { "Rebirth", "EXP", "Lucky", "Item", "Diamond" }, nil, 46)

noteLabel(pageUtils,
    "Refreshes a selected X2 potion once it has about 20s\nleft, not all at once -- each one keeps its own 15min\ntimer. Stops on its own once you run out of that potion.")

sectionLabel(pageUtils, "Settings")

-- Preset name input. A TextBox row, styled like the other cards.
local presetNameRow = Instance.new("Frame")
presetNameRow.Size = UDim2.new(1, 0, 0, 46)
presetNameRow.BackgroundColor3 = Theme.card
presetNameRow.BorderSizePixel = 0
presetNameRow.LayoutOrder = nextOrder(pageUtils)
presetNameRow.Parent = pageUtils
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

actionRow(pageUtils, Icon.package, "Save As", "Saves the name above as a new preset", function()
    local name = presetNameBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        State.Status = "Enter a preset name first"
        return
    end
    local ok = saveSettingsAs(name)
    State.Status = ok and ("Saved as \"" .. name .. "\"") or "Save failed"
    if refreshPresetList then refreshPresetList() end
end)

-- Preset picker: same dropdown pattern as Target/Boss above.
local presetRow, presetValue, presetList, refreshPresetList

presetRow = Instance.new("TextButton")
presetRow.Size = UDim2.new(1, 0, 0, 46)
presetRow.BackgroundColor3 = Theme.card
presetRow.AutoButtonColor = false
presetRow.Text = ""
presetRow.LayoutOrder = nextOrder(pageUtils)
presetRow.Parent = pageUtils
corner(presetRow, 11)

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

presetList = Instance.new("ScrollingFrame")
presetList.Size = UDim2.new(1, 0, 0, 0)
presetList.BackgroundColor3 = Theme.cardAlt
presetList.BorderSizePixel = 0
presetList.ScrollBarThickness = 3
presetList.ScrollBarImageColor3 = Theme.stroke
presetList.CanvasSize = UDim2.new()
presetList.AutomaticCanvasSize = Enum.AutomaticSize.Y
presetList.Visible = false
presetList.LayoutOrder = nextOrder(pageUtils)
presetList.Parent = pageUtils
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
            pad.PaddingRight = UDim.new(0, 28)  -- keep text clear of the delete button
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

        -- Delete: its own sibling button, so clicking it does not also fire the
        -- item's own click (Roblox click hit-testing only fires the topmost
        -- GuiButton actually under the cursor, not every ancestor/descendant).
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

toggleRow(pageUtils, Icon.star, "Auto Load on Start", "AutoLoadSettings", function(on)
    writeMeta(on, lastPresetName)
end)

noteLabel(pageUtils,
    "Save As stores everything on this panel under the\nname above. Auto Load restores whichever preset you\nlast saved or loaded, on every future run (autoexec).")

----------------------------------------------------------------------
-- Move tab
----------------------------------------------------------------------
-- Same click the game's own Frame_Teleport window performs -- character:PivotTo
-- the named TeleportPart, no remote, so this is exactly as legitimate as using
-- the game's own button. See teleportToIsland() above for the mechanics and the
-- InCombat guard it respects.

sectionLabel(pageTeleport, "Islands")

local teleportGrid = Instance.new("Frame")
teleportGrid.Size = UDim2.new(1, 0, 0, 0)
teleportGrid.AutomaticSize = Enum.AutomaticSize.Y
teleportGrid.BackgroundTransparency = 1
teleportGrid.LayoutOrder = nextOrder(pageTeleport)
teleportGrid.Parent = pageTeleport

local teleportGridLayout = Instance.new("UIGridLayout")
teleportGridLayout.CellSize = UDim2.new(0.5, -5, 0, 50)
teleportGridLayout.CellPadding = UDim2.new(0, 10, 0, 10)
teleportGridLayout.SortOrder = Enum.SortOrder.LayoutOrder
teleportGridLayout.Parent = teleportGrid

-- Rebuilt rather than built once, so an island added, removed, or renamed by a
-- future update shows up without needing a script reload. Rebuilds whenever the
-- Move tab is opened (tabShownCallbacks) and live if workspace.island itself
-- changes while the tab happens to already be open.
local function refreshIslands()
    if getgenv().__RFF_GEN ~= MY_GEN then return end  -- guard against a stale
                                                        -- connection outliving a reload
    for _, c in ipairs(teleportGrid:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
    end

    local list = islandList()
    if #list == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, 0, 0, 34)
        empty.BackgroundTransparency = 1
        empty.Font = Enum.Font.Gotham
        empty.Text = "  no islands found"
        empty.TextColor3 = Theme.muted
        empty.TextSize = 11
        empty.TextXAlignment = Enum.TextXAlignment.Left
        empty.Parent = teleportGrid
        return
    end

    for idx, isl in ipairs(list) do
        local btn = Instance.new("TextButton")
        btn.BackgroundColor3 = Theme.card
        btn.AutoButtonColor = false
        btn.Text = ""
        btn.LayoutOrder = idx
        btn.Parent = teleportGrid
        corner(btn, 11)

        local icon = makeIcon(btn, Icon.mappin, Theme.muted, 14)
        icon.Position = UDim2.fromOffset(10, 18)

        local lbl = Instance.new("TextLabel")
        lbl.BackgroundTransparency = 1
        lbl.Position = UDim2.fromOffset(31, 0)
        lbl.Size = UDim2.new(1, -40, 1, 0)
        lbl.Font = Enum.Font.GothamMedium
        lbl.Text = (isl.name:gsub("%s*[Ii]sland%s*", ""))
        lbl.TextColor3 = Theme.text
        lbl.TextSize = 12
        lbl.TextWrapped = true
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.TextYAlignment = Enum.TextYAlignment.Center
        lbl.Parent = btn

        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.cardAlt }):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.15), { BackgroundColor3 = Theme.card }):Play()
        end)
        btn.MouseButton1Click:Connect(function()
            local ok, err = teleportToIsland(isl.name)
            State.Status = ok and ("Teleported to " .. isl.name) or ("Teleport blocked: " .. tostring(err))
        end)
    end
end

tabShownCallbacks["Move"] = refreshIslands
refreshIslands()

local islandFolder = workspace:FindFirstChild("island")
if islandFolder then
    islandFolder.ChildAdded:Connect(function() task.wait(0.2) refreshIslands() end)
    islandFolder.ChildRemoved:Connect(function() task.wait(0.2) refreshIslands() end)
end

noteLabel(pageTeleport,
    "Blocked while in combat, same as the game's own\nbutton. Auto Farm will teleport you right back if on.", 40)

----------------------------------------------------------------------
-- Server tab
----------------------------------------------------------------------

sectionLabel(pageServer, "Session")

actionRow(pageServer, Icon.user, "Rejoin Same Server", "VIP servers usually block this", function()
    stopFarm()
    rejoin(true)
end)

actionRow(pageServer, Icon.crosshair, "Rejoin (Any Server)", "Lands in a public server", function()
    stopFarm()
    rejoin(false)
end)

actionRow(pageServer, Icon.x, "Leave Game", "Always works - relaunch from your link", function()
    stopFarm()
    task.wait(0.2)
    LP:Kick("Left via Rock Fruit menu.\n\nRejoin from your own server link to clear the old farm loops.")
end)

local note = Instance.new("TextLabel")
note.BackgroundTransparency = 1
note.Size = UDim2.new(1, 0, 0, 72)
note.Font = Enum.Font.Gotham
note.Text = "Rejoin clears farm loops left behind by older\nversions of this script. They cannot be stopped\nany other way and will fight you for position."
note.TextColor3 = Theme.muted
note.TextSize = 11
note.TextWrapped = true
note.TextYAlignment = Enum.TextYAlignment.Top
note.TextXAlignment = Enum.TextXAlignment.Left
note.LayoutOrder = nextOrder(pageServer)
note.Parent = pageServer

----------------------------------------------------------------------
-- UI behaviour
----------------------------------------------------------------------

task.spawn(function()
    while gui.Parent do
        statusLabel.Text = State.Status
        dot.BackgroundColor3 = State.AutoFarm and Theme.good or Theme.muted

        if State.FarmMode == "Select" then
            questLabel.Text = State.Target and ("Target: " .. State.Target) or "No target selected"
        else
            local quest = getQuest()
            if quest then
                questLabel.Text = string.format("%s  %d/%d",
                    tostring(quest.Title), quest.Current or 0, quest.Max or 0)
            else
                questLabel.Text = "No active quest"
            end
        end

        killsLabel.Text = string.format("%d killed  -  Lv.%s",
            State.Kills, tostring(LP:GetAttribute("Level") or "?"))

        task.wait(0.3)
    end
end)

-- Dragging
do
    local dragging, dragStart, startPos = false, nil, nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
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
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            root.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

local minimised = false
minBtn.MouseButton1Click:Connect(function()
    minimised = not minimised
    body.Visible = not minimised
    divider.Visible = not minimised
    TweenService:Create(root, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
        Size = minimised and UDim2.fromOffset(PANEL_W, 56) or UDim2.fromOffset(PANEL_W, PANEL_H),
    }):Play()
end)

closeBtn.MouseButton1Click:Connect(function()
    stopFarm()
    gui:Destroy()
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        root.Visible = not root.Visible
    end
end)

LP.CharacterAdded:Connect(function()
    task.wait(1.5)
    lastQuestCurrent = nil
end)

-- Keep learning mob locations even while the farm is off, so the Select list
-- fills up as you move around.
task.spawn(function()
    while getgenv().__RFF_GEN == MY_GEN do
        pcall(rememberMobs)
        task.wait(2)
    end
end)

----------------------------------------------------------------------
-- Stuck popup
----------------------------------------------------------------------

showStuckPopup = function()
    -- Once per session, not once per script load, so reloading does not re-nag.
    if getgenv().__RFF_STUCK_WARNED then return end
    getgenv().__RFF_STUCK_WARNED = true

    local shade = Instance.new("Frame")
    shade.Size = UDim2.fromScale(1, 1)
    shade.BackgroundColor3 = Color3.new(0, 0, 0)
    shade.BackgroundTransparency = 1
    shade.ZIndex = 50
    shade.Parent = gui
    TweenService:Create(shade, TweenInfo.new(0.2), { BackgroundTransparency = 0.45 }):Play()

    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromOffset(320, 190)
    card.BackgroundColor3 = Theme.bg
    card.BorderSizePixel = 0
    card.ZIndex = 51
    card.Parent = shade
    corner(card, 14)
    stroke(card, Theme.stroke, 1)

    local icon = makeIcon(card, Icon.shield, Theme.accent, 22)
    icon.Position = UDim2.fromOffset(22, 22)
    icon.ZIndex = 52

    local heading = Instance.new("TextLabel")
    heading.BackgroundTransparency = 1
    heading.Position = UDim2.fromOffset(54, 20)
    heading.Size = UDim2.new(1, -74, 0, 20)
    heading.Font = Enum.Font.GothamBold
    heading.Text = "Farming is stuck"
    heading.TextColor3 = Theme.text
    heading.TextSize = 15
    heading.TextXAlignment = Enum.TextXAlignment.Left
    heading.ZIndex = 52
    heading.Parent = card

    local text = Instance.new("TextLabel")
    text.BackgroundTransparency = 1
    text.Position = UDim2.fromOffset(22, 58)
    text.Size = UDim2.new(1, -44, 0, 66)
    text.Font = Enum.Font.Gotham
    text.Text = "Resetting your character did not fix it. This usually means the "
        .. "session itself is broken and only rejoining clears it.\n\nFarming has been stopped."
    text.TextColor3 = Theme.muted
    text.TextSize = 12
    text.TextWrapped = true
    text.TextXAlignment = Enum.TextXAlignment.Left
    text.TextYAlignment = Enum.TextYAlignment.Top
    text.ZIndex = 52
    text.Parent = card

    local function popupButton(label, xScale, primary, onClick)
        local b = Instance.new("TextButton")
        b.AnchorPoint = Vector2.new(0, 1)
        b.Position = UDim2.new(xScale, xScale == 0 and 22 or 6, 1, -20)
        b.Size = UDim2.new(0.5, -28, 0, 34)
        b.BackgroundColor3 = primary and Theme.accent or Theme.card
        b.AutoButtonColor = false
        b.Font = Enum.Font.GothamMedium
        b.Text = label
        b.TextColor3 = primary and Color3.new(1, 1, 1) or Theme.text
        b.TextSize = 13
        b.ZIndex = 52
        b.Parent = card
        corner(b, 9)
        b.MouseButton1Click:Connect(onClick)
        return b
    end

    local function dismiss()
        TweenService:Create(shade, TweenInfo.new(0.15), { BackgroundTransparency = 1 }):Play()
        task.wait(0.15)
        shade:Destroy()
    end

    popupButton("Dismiss", 0, false, function() task.spawn(dismiss) end)
    popupButton("Leave Game", 0.5, true, function()
        stopFarm()
        task.spawn(function()
            task.wait(0.2)
            LP:Kick("Farming was stuck.\n\nRejoin from your own server link.")
        end)
    end)

    stopFarm()
end

State.Status = "Ready"
