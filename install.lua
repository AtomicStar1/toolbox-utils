-- One-time installer / loadstring entry point.
-- Downloads the hub loader + game scripts into the local Xeno workspace, then
-- launches the loader immediately. Safe to re-run any time to update.

local RAW = "https://raw.githubusercontent.com/AtomicStar1/toolbox-utils/main/"

local FILES = {
    { url = RAW .. "HubLoader.lua",          path = "MaikoHub/loader.lua" },
    { url = RAW .. "RockFruit_AutoFarm.lua", path = "MaikoHub/games/10008473853.lua" },
    { url = RAW .. "RockFruit_Moon.lua",     path = "MaikoHub/games/82878101790702.lua" },
    { url = RAW .. "RockFruit_Autoexec.lua", path = "MaikoHub/autoexec_ref.lua" }, -- reference copy, not auto-run
}

pcall(function()
    if not isfolder("MaikoHub") then makefolder("MaikoHub") end
    if not isfolder("MaikoHub/games") then makefolder("MaikoHub/games") end
end)

for _, f in ipairs(FILES) do
    local ok, body = pcall(function() return game:HttpGet(f.url) end)
    if ok and body and #body > 0 then
        writefile(f.path, body)
    else
        warn("[install] failed to download " .. f.url)
    end
end

-- MaikoHub/autoexec_ref.lua above is just a reference copy inside the
-- workspace -- writefile can't reach the real Xeno autoexec folder
-- (%LOCALAPPDATA%\Xeno\autoexec\, outside the workspace root it's sandboxed
-- to). To get the loader back automatically after a rejoin, copy that file's
-- contents into %LOCALAPPDATA%\Xeno\autoexec\ by hand, once.

loadstring(readfile("MaikoHub/loader.lua"), "@MaikoHub/loader.lua")()
