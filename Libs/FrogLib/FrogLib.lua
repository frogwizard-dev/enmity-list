-- FrogLib: the code Frog Wizard's addons share. Each addon carries its own copy in Libs\FrogLib,
-- all made from the one in _shared\FrogLib by _tools\sync_froglib.py (never edit an addon's copy).
-- With several addons loaded, the newest copy of each part wins: a part only loads if no copy
-- with the same or a higher minor version has, so a newer one must stay compatible with the old.
--
--   FrogLib:Module(name, minor) -> the part's table to fill in, or nil if one as new is loaded
--   FrogLib.Pixel(frame)        -> one screen pixel in frame's units
--   FrogLib.NoSnap(region)      -> keep a texture exactly where it's put (no pixel snapping)
--   FrogLib.issecret(v), FrogLib.Safe(v) -> v, or nil when the game hides it from addons
--   FrogLib.Loaded(addon)       -> whether an addon is loaded
-- The parts: Options (the "Frog Wizard" section of Options > AddOns), Media (texture and font
-- lists), Borders (pixel, classic stone and Forever frames) and Threat (your lead on a unit).

local MINOR = 1

local lib = _G.FrogLib
if lib and (lib.minor or 0) >= MINOR then return end
lib = lib or {}
_G.FrogLib = lib
lib.minor = MINOR
lib.modules = lib.modules or {}

function lib:Module(name, minor)
    local m = self.modules[name]
    if m and (m.minor or 0) >= minor then return nil end
    m = m or {}
    m.minor = minor
    self.modules[name] = m
    self[name] = m
    return m
end

-- Midnight hides some combat values from addons ("secret values"): they can be handed to the
-- game's widgets, but not compared or used in arithmetic.
lib.issecret = issecretvalue or function() return false end

function lib.Safe(v)
    if lib.issecret(v) then return nil end
    return v
end

function lib.Pixel(frame)
    return 768 / select(2, GetPhysicalScreenSize()) / frame:GetEffectiveScale()
end

function lib.NoSnap(region)
    if region and region.SetSnapToPixelGrid then
        region:SetSnapToPixelGrid(false)
        region:SetTexelSnappingBias(0)
    end
end

function lib.Loaded(addon)
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    return isLoaded ~= nil and isLoaded(addon) and true or false
end
