-- Rock Fruit hub loader autoexec
-- Runs on every game join. The loader itself only does anything in a game that
-- has a matching file under MaikoHub/games/ (Rock Fruit right now) -- everywhere
-- else it silently does nothing, so this is safe alongside any other game.
--
-- This exists because ANY client rejoin (a normal server rejoin, or the Moon
-- teleport, which reloads the client even though it is the same PlaceId) wipes
-- injected scripts. Without this, the farm UI has to be relaunched by hand after
-- every one of those. Auto Launch inside the loader itself stays off by default
-- (its own toggle), so this only brings the PICKER back automatically, not the
-- farm running unattended, unless that toggle has been turned on deliberately.
pcall(function()
    loadstring(readfile("MaikoHub/loader.lua"), "@MaikoHub/loader.lua")()
end)
