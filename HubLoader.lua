--[[
    Hub Loader
    ----------
    One script to run in every game. It shows a small panel where you can connect
    the MCP bridge and launch the script for whatever game you are in.

    Game scripts live in the executor's workspace folder (for Xeno that is
    %LOCALAPPDATA%\Xeno\workspace):

        MaikoHub/games/<PlaceId>.lua    one specific place
        MaikoHub/games/<GameId>.lua     every place in that universe

    PlaceId wins over GameId so a single place can override its universe. Adding
    a game is just dropping a file in there named after its id -- nothing in this
    loader needs editing.

    A script can name itself for the picker with a first line of:
        -- @name Rock Fruit
    Otherwise it is listed by its id.

    Preferences (auto-launch, auto-connect) are remembered in MaikoHub/config.json.
]]

local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local BASE = "MaikoHub/games/"
local CONFIG_PATH = "MaikoHub/config.json"

local placeId = tostring(game.PlaceId)
local gameId  = tostring(game.GameId)

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------

local config = { autoLaunch = false, autoMCP = false }
do
    local ok, raw = pcall(readfile, CONFIG_PATH)
    if ok and type(raw) == "string" and raw ~= "" then
        local decoded
        ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
        if ok and type(decoded) == "table" then
            for k, v in pairs(decoded) do config[k] = v end
        end
    end
end

local function saveConfig()
    pcall(function()
        writefile(CONFIG_PATH, HttpService:JSONEncode(config))
    end)
end

----------------------------------------------------------------------
-- Script discovery
----------------------------------------------------------------------

local function fileExists(path)
    local ok, result = pcall(isfile, path)
    return ok and result == true
end

-- Executors return listfiles paths in varying shapes ("./a/b.lua", "a\\b.lua"),
-- so reduce to a bare filename before doing anything with it.
local function baseName(path)
    return (tostring(path):gsub("\\", "/"):match("([^/]+)$")) or tostring(path)
end

-- A script may declare "-- @name Something" on its first line.
local function readName(path)
    local ok, src = pcall(readfile, path)
    if not ok or type(src) ~= "string" then return nil end
    return src:sub(1, 400):match("^%s*%-%-%s*@name%s+([^\r\n]+)")
end

local function listScripts()
    local out = {}
    local ok, files = pcall(listfiles, "MaikoHub/games")
    if not ok or type(files) ~= "table" then return out end
    for _, path in ipairs(files) do
        local file = baseName(path)
        if file:sub(-4) == ".lua" then
            local id = file:sub(1, -5)
            out[#out + 1] = {
                id = id,
                path = BASE .. file,
                name = readName(BASE .. file) or id,
            }
        end
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

-- The script that matches the game we are actually in.
local function autoMatch()
    for _, id in ipairs({ placeId, gameId }) do
        local path = BASE .. id .. ".lua"
        if fileExists(path) then
            return { id = id, path = path, name = readName(path) or id }
        end
    end
    return nil
end

----------------------------------------------------------------------
-- Running a script
----------------------------------------------------------------------

local lastStatus = "Idle"

local function runScript(entry)
    if not entry then
        lastStatus = "No script selected"
        return false
    end
    local ok, source = pcall(readfile, entry.path)
    if not ok or type(source) ~= "string" or source == "" then
        lastStatus = "Cannot read " .. entry.path
        return false
    end
    -- Name the chunk after the file so errors point at the game script, not here.
    local fn, compileErr = loadstring(source, "@" .. entry.path)
    if not fn then
        lastStatus = "Compile error: " .. tostring(compileErr):sub(1, 60)
        return false
    end
    local ranOk, runErr = pcall(fn)
    if not ranOk then
        lastStatus = "Error: " .. tostring(runErr):sub(1, 60)
        return false
    end
    lastStatus = "Running " .. entry.name
    return true
end

----------------------------------------------------------------------
-- MCP bridge
----------------------------------------------------------------------

local mcpWanted = false

local function mcpConnected()
    return getgenv().MCP_Loaded == true
end

local function startMCP()
    if mcpWanted then return end
    mcpWanted = true
    task.spawn(function()
        while mcpWanted and not getgenv().MCP_Loaded do
            local bridgeUrl = getgenv().BridgeURL or "localhost:16384"
            pcall(function()
                loadstring(game:HttpGet("http://" .. bridgeUrl .. "/script.luau"))()
            end)
            task.wait(0.15)
        end
    end)
end

local function stopMCP()
    -- Only stops us retrying; an already-connected bridge stays up.
    mcpWanted = false
end

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------

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

local Icon = {
    package  = "rbxassetid://10734909540",
    activity = "rbxassetid://10709752035",
    play     = "rbxassetid://10734923549",
    x        = "rbxassetid://10747384394",
    minus    = "rbxassetid://10734896206",
    chevron  = "rbxassetid://10709790948",
    settings = "rbxassetid://10734950309",
}

local parentGui = (typeof(gethui) == "function" and gethui()) or game:GetService("CoreGui")
local existing = parentGui:FindFirstChild("HubLoaderUI")
if existing then existing:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "HubLoaderUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parentGui

-- Height fits the rows without scrolling; the body scrolls anyway so opening the
-- script dropdown (or adding rows later) can never clip the bottom of the panel.
local PANEL_W, PANEL_H = 300, 454

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
-- Deliberately not centred: something at the middle of the screen swallows clicks
-- there (buttons simply never fire), and this also keeps clear of the farm panel
-- which sits at x 40-312.
root.Position = UDim2.new(0, 360, 0.5, -PANEL_H / 2)
root.BackgroundColor3 = Theme.bg
root.BorderSizePixel = 0
root.Parent = gui
corner(root, 14)
do
    local s = Instance.new("UIStroke")
    s.Color = Theme.stroke
    s.Parent = root
end

-- Header
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 52)
header.BackgroundTransparency = 1
header.Parent = root

local logo = makeIcon(header, Icon.package, Theme.accent, 20)
logo.Position = UDim2.fromOffset(16, 16)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(44, 12)
title.Size = UDim2.new(1, -110, 0, 16)
title.Font = Enum.Font.GothamBold
title.Text = "Hub Loader"
title.TextColor3 = Theme.text
title.TextSize = 14
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

local subtitle = Instance.new("TextLabel")
subtitle.BackgroundTransparency = 1
subtitle.Position = UDim2.fromOffset(44, 28)
subtitle.Size = UDim2.new(1, -110, 0, 14)
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Game " .. gameId
subtitle.TextColor3 = Theme.muted
subtitle.TextSize = 11
subtitle.TextXAlignment = Enum.TextXAlignment.Left
subtitle.Parent = header

local function headerButton(icon, xOffset)
    local b = Instance.new("TextButton")
    b.Size = UDim2.fromOffset(26, 26)
    b.Position = UDim2.new(1, xOffset, 0, 13)
    b.BackgroundColor3 = Theme.card
    b.AutoButtonColor = false
    b.Text = ""
    b.Parent = header
    corner(b, 8)
    local i = makeIcon(b, icon, Theme.muted, 14)
    i.AnchorPoint = Vector2.new(0.5, 0.5)
    i.Position = UDim2.fromScale(0.5, 0.5)
    return b
end
local closeBtn = headerButton(Icon.x, -38)
local minBtn   = headerButton(Icon.minus, -70)

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -32, 0, 1)
divider.Position = UDim2.fromOffset(16, 52)
divider.BackgroundColor3 = Theme.stroke
divider.BorderSizePixel = 0
divider.Parent = root

-- Body
local body = Instance.new("ScrollingFrame")
body.Position = UDim2.fromOffset(0, 62)
body.Size = UDim2.new(1, 0, 1, -62)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 3
body.ScrollBarImageColor3 = Theme.stroke
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollingDirection = Enum.ScrollingDirection.Y
body.Parent = root

local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0, 16)
pad.PaddingRight = UDim.new(0, 16)
pad.PaddingBottom = UDim.new(0, 14)
pad.Parent = body

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local order = 0
local function nextOrder()
    order = order + 1
    return order
end

local function sectionLabel(text)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, 0, 0, 16)
    l.Font = Enum.Font.GothamBold
    l.Text = string.upper(text)
    l.TextColor3 = Theme.muted
    l.TextSize = 10
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.LayoutOrder = nextOrder()
    l.Parent = body
    return l
end

-- Status card
local statusCard = Instance.new("Frame")
statusCard.Size = UDim2.new(1, 0, 0, 54)
statusCard.BackgroundColor3 = Theme.card
statusCard.BorderSizePixel = 0
statusCard.LayoutOrder = nextOrder()
statusCard.Parent = body
corner(statusCard, 10)

local dot = Instance.new("Frame")
dot.Size = UDim2.fromOffset(7, 7)
dot.Position = UDim2.fromOffset(14, 14)
dot.BackgroundColor3 = Theme.muted
dot.BorderSizePixel = 0
dot.Parent = statusCard
corner(dot, 4)

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(29, 8)
statusLabel.Size = UDim2.new(1, -42, 0, 18)
statusLabel.Font = Enum.Font.GothamMedium
statusLabel.Text = "Idle"
statusLabel.TextColor3 = Theme.text
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Parent = statusCard

local matchLabel = Instance.new("TextLabel")
matchLabel.BackgroundTransparency = 1
matchLabel.Position = UDim2.fromOffset(29, 28)
matchLabel.Size = UDim2.new(1, -42, 0, 16)
matchLabel.Font = Enum.Font.Gotham
matchLabel.Text = "-"
matchLabel.TextColor3 = Theme.muted
matchLabel.TextSize = 11
matchLabel.TextXAlignment = Enum.TextXAlignment.Left
matchLabel.TextTruncate = Enum.TextTruncate.AtEnd
matchLabel.Parent = statusCard

-- Toggle row
local function toggleRow(icon, text, getter, onChange)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 40)
    row.BackgroundColor3 = Theme.card
    row.AutoButtonColor = false
    row.Text = ""
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 10)

    local i = makeIcon(row, icon, Theme.muted, 16)
    i.Position = UDim2.fromOffset(13, 12)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(38, 0)
    lbl.Size = UDim2.new(1, -90, 1, 0)
    lbl.Font = Enum.Font.GothamMedium
    lbl.Text = text
    lbl.TextColor3 = Theme.text
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local track = Instance.new("Frame")
    track.AnchorPoint = Vector2.new(1, 0.5)
    track.Position = UDim2.new(1, -13, 0.5, 0)
    track.Size = UDim2.fromOffset(38, 21)
    track.BackgroundColor3 = Theme.cardAlt
    track.BorderSizePixel = 0
    track.Parent = row
    corner(track, 11)

    local knob = Instance.new("Frame")
    knob.AnchorPoint = Vector2.new(0, 0.5)
    knob.Position = UDim2.new(0, 3, 0.5, 0)
    knob.Size = UDim2.fromOffset(15, 15)
    knob.BackgroundColor3 = Theme.muted
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 8)

    local function render()
        local on = getter()
        TweenService:Create(track, TweenInfo.new(0.18), {
            BackgroundColor3 = on and Theme.accent or Theme.cardAlt }):Play()
        TweenService:Create(knob, TweenInfo.new(0.18), {
            Position = on and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
            BackgroundColor3 = on and Color3.new(1, 1, 1) or Theme.muted }):Play()
        TweenService:Create(i, TweenInfo.new(0.18), {
            ImageColor3 = on and Theme.accent or Theme.muted }):Play()
    end

    row.MouseButton1Click:Connect(function()
        onChange(not getter())
        render()
    end)
    render()
    return row, render
end

-- Action row
local function actionRow(icon, text, onClick)
    local row = Instance.new("TextButton")
    row.Size = UDim2.new(1, 0, 0, 40)
    row.BackgroundColor3 = Theme.accent
    row.AutoButtonColor = false
    row.Text = ""
    row.LayoutOrder = nextOrder()
    row.Parent = body
    corner(row, 10)

    local i = makeIcon(row, icon, Color3.new(1, 1, 1), 16)
    i.Position = UDim2.fromOffset(13, 12)

    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.fromOffset(38, 0)
    lbl.Size = UDim2.new(1, -50, 1, 0)
    lbl.Font = Enum.Font.GothamBold
    lbl.Text = text
    lbl.TextColor3 = Color3.new(1, 1, 1)
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    row.MouseButton1Click:Connect(onClick)
    return row, lbl
end

----------------------------------------------------------------------
-- Rows
----------------------------------------------------------------------

sectionLabel("Bridge")

local mcpRow, renderMCP = toggleRow(Icon.activity, "MCP Bridge",
    function() return mcpWanted or mcpConnected() end,
    function(on)
        if on then startMCP() else stopMCP() end
    end)

sectionLabel("Script")

local scripts = listScripts()
local matched = autoMatch()
local selected = matched

-- Picker
local pickerRow = Instance.new("TextButton")
pickerRow.Size = UDim2.new(1, 0, 0, 40)
pickerRow.BackgroundColor3 = Theme.card
pickerRow.AutoButtonColor = false
pickerRow.Text = ""
pickerRow.LayoutOrder = nextOrder()
pickerRow.Parent = body
corner(pickerRow, 10)

local pickIcon = makeIcon(pickerRow, Icon.settings, Theme.muted, 16)
pickIcon.Position = UDim2.fromOffset(13, 12)

local pickLabel = Instance.new("TextLabel")
pickLabel.BackgroundTransparency = 1
pickLabel.Position = UDim2.fromOffset(38, 0)
pickLabel.Size = UDim2.new(1, -60, 1, 0)
pickLabel.Font = Enum.Font.GothamMedium
pickLabel.Text = "Script"
pickLabel.TextColor3 = Theme.text
pickLabel.TextSize = 12
pickLabel.TextXAlignment = Enum.TextXAlignment.Left
pickLabel.Parent = pickerRow

local pickValue = Instance.new("TextLabel")
pickValue.BackgroundTransparency = 1
pickValue.AnchorPoint = Vector2.new(1, 0.5)
pickValue.Position = UDim2.new(1, -30, 0.5, 0)
pickValue.Size = UDim2.new(0, 150, 0, 16)
pickValue.Font = Enum.Font.Gotham
pickValue.Text = "none"
pickValue.TextColor3 = Theme.muted
pickValue.TextSize = 11
pickValue.TextXAlignment = Enum.TextXAlignment.Right
pickValue.TextTruncate = Enum.TextTruncate.AtEnd
pickValue.Parent = pickerRow

local chev = makeIcon(pickerRow, Icon.chevron, Theme.muted, 14)
chev.AnchorPoint = Vector2.new(1, 0.5)
chev.Position = UDim2.new(1, -12, 0.5, 0)

local pickList = Instance.new("ScrollingFrame")
pickList.Size = UDim2.new(1, 0, 0, 0)
pickList.BackgroundColor3 = Theme.cardAlt
pickList.BorderSizePixel = 0
pickList.ScrollBarThickness = 3
pickList.ScrollBarImageColor3 = Theme.stroke
pickList.CanvasSize = UDim2.new()
pickList.AutomaticCanvasSize = Enum.AutomaticSize.Y
pickList.Visible = false
pickList.LayoutOrder = nextOrder()
pickList.Parent = body
corner(pickList, 10)
do
    local l = Instance.new("UIListLayout")
    l.SortOrder = Enum.SortOrder.LayoutOrder
    l.Parent = pickList
end

local function setSelected(entry)
    selected = entry
    pickValue.Text = entry and entry.name or "none"
    pickValue.TextColor3 = entry and Theme.accent or Theme.muted
end

local function refreshPicker()
    for _, c in ipairs(pickList:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    scripts = listScripts()
    if #scripts == 0 then
        local empty = Instance.new("TextLabel")
        empty.Size = UDim2.new(1, 0, 0, 30)
        empty.BackgroundTransparency = 1
        empty.Font = Enum.Font.Gotham
        empty.Text = "  no scripts in MaikoHub/games"
        empty.TextColor3 = Theme.muted
        empty.TextSize = 10
        empty.TextXAlignment = Enum.TextXAlignment.Left
        empty.Parent = pickList
        return
    end
    for idx, entry in ipairs(scripts) do
        local item = Instance.new("TextButton")
        item.Size = UDim2.new(1, 0, 0, 30)
        item.BackgroundTransparency = 1
        item.AutoButtonColor = false
        item.Font = Enum.Font.Gotham
        item.Text = "  " .. entry.name
        item.TextColor3 = (selected and selected.id == entry.id) and Theme.accent or Theme.text
        item.TextSize = 11
        item.TextXAlignment = Enum.TextXAlignment.Left
        item.LayoutOrder = idx
        item.Parent = pickList

        local tag = Instance.new("TextLabel")
        tag.BackgroundTransparency = 1
        tag.AnchorPoint = Vector2.new(1, 0.5)
        tag.Position = UDim2.new(1, -10, 0.5, 0)
        tag.Size = UDim2.fromOffset(70, 14)
        tag.Font = Enum.Font.Gotham
        tag.Text = (matched and matched.id == entry.id) and "this game" or ""
        tag.TextColor3 = Theme.good
        tag.TextSize = 9
        tag.TextXAlignment = Enum.TextXAlignment.Right
        tag.Parent = item

        item.MouseButton1Click:Connect(function()
            setSelected(entry)
            pickList.Visible = false
            pickList.Size = UDim2.new(1, 0, 0, 0)
            refreshPicker()
        end)
    end
end

pickerRow.MouseButton1Click:Connect(function()
    local opening = not pickList.Visible
    if opening then refreshPicker() end
    pickList.Visible = opening
    pickList.Size = opening and UDim2.new(1, 0, 0, 100) or UDim2.new(1, 0, 0, 0)
end)

local launchRow, launchLabel = actionRow(Icon.play, "Launch", function()
    runScript(selected)
end)

sectionLabel("On Join")

toggleRow(Icon.play, "Auto Launch",
    function() return config.autoLaunch end,
    function(on) config.autoLaunch = on saveConfig() end)

toggleRow(Icon.activity, "Auto Connect MCP",
    function() return config.autoMCP end,
    function(on) config.autoMCP = on saveConfig() end)

----------------------------------------------------------------------
-- Behaviour
----------------------------------------------------------------------

setSelected(matched)
if matched then
    matchLabel.Text = "Matched: " .. matched.name
else
    matchLabel.Text = "No script for this game"
end

task.spawn(function()
    while gui.Parent do
        statusLabel.Text = lastStatus
        local connected = mcpConnected()
        dot.BackgroundColor3 = connected and Theme.good
            or (mcpWanted and Theme.warn or Theme.muted)
        if connected then
            subtitle.Text = "MCP connected  -  Game " .. gameId
        elseif mcpWanted then
            subtitle.Text = "MCP connecting...  -  Game " .. gameId
        else
            subtitle.Text = "Game " .. gameId
        end
        renderMCP()
        task.wait(0.4)
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
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

local minimised = false
minBtn.MouseButton1Click:Connect(function()
    minimised = not minimised
    body.Visible = not minimised
    divider.Visible = not minimised
    TweenService:Create(root, TweenInfo.new(0.2), {
        Size = minimised and UDim2.fromOffset(PANEL_W, 52) or UDim2.fromOffset(PANEL_W, PANEL_H),
    }):Play()
end)

closeBtn.MouseButton1Click:Connect(function()
    gui:Destroy()
end)

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.RightAlt then
        root.Visible = not root.Visible
    end
end)

-- Remembered startup actions
if config.autoMCP and not mcpConnected() then
    startMCP()
end
if config.autoLaunch and matched then
    task.spawn(function()
        task.wait(0.5)
        runScript(matched)
    end)
end

lastStatus = matched and ("Ready - " .. matched.name) or "No script for this game"
