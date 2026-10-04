local _, ns = ...
local Media = {}
ns.Media = Media

local BUILTIN = {
    statusbar = {
        { name = "Flat", path = "Interface\\Buttons\\WHITE8X8" },
        { name = "Blizzard", path = "Interface\\TargetingFrame\\UI-StatusBar" },
        { name = "Blizzard Raid", path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill" },
    },
    font = {
        { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
        { name = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
        { name = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
        { name = "Skurri", path = "Fonts\\SKURRI.TTF" },
    },
}

-- FrogUI's own bar textures (flat and matte, made for it), listed wherever FrogUI is loaded.
local FROG_BARS = "Interface\\AddOns\\FrogUI\\Media\\Bars\\"
local FROG_BAR_NAMES = { "Matte", "Soft", "Grain", "Satin", "Inset", "Brushed", "Stripes",
    "Dark Matte", "Dark Soft", "Dark Grain", "Dark Inset" }

local GROUPS = { "Frog", "Bundled", "Blizzard", "EllesmereUI", "Shared media" }
local MICHROMA = "Interface\\AddOns\\EnmityList\\Fonts\\Michroma.ttf" -- wide, like FFXIV's gauge numbers

-- No bundled font here (XIVTarget carries the one copy); a missing font file falls back to
-- the game's own.
local CUSTOM_FONT = STANDARD_TEXT_FONT

-- Everything available right now, grouped for the dropdowns and de-duplicated by path.
-- Built fresh each time so media registered by addons that load late still shows up.
function Media:List(kind)
    local buckets, seen = {}, {}
    for _, g in ipairs(GROUPS) do buckets[g] = {} end
    local function add(group, name, path)
        if type(path) ~= "string" or seen[path:lower()] then return end
        seen[path:lower()] = true
        table.insert(buckets[group], { name = name, path = path })
    end

    if kind == "font" then
        add("Bundled", "Michroma (wide)", MICHROMA)
        add("Bundled", "Source Sans 3 (Myriad-like)", "Interface\\AddOns\\EnmityList\\Fonts\\SourceSans3.ttf")
    end
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if kind == "statusbar" and isLoaded and isLoaded("FrogUI") then
        for _, name in ipairs(FROG_BAR_NAMES) do add("Frog", name, FROG_BARS .. name .. ".tga") end
    end
    for _, m in ipairs(BUILTIN[kind]) do
        add("Blizzard", m.name, m.path)
    end

    -- EllesmereUI doesn't register its bar textures with LibSharedMedia, so read its catalogue.
    local E = _G.EllesmereUI
    if kind == "statusbar" and E and E.BAR_TEXTURE_ORDER and E.BAR_TEXTURE_FILES and E.MEDIA_PATH then
        for _, key in ipairs(E.BAR_TEXTURE_ORDER) do
            local file = E.BAR_TEXTURE_FILES[key]
            if file then
                add("EllesmereUI", (E.BAR_TEXTURE_NAMES and E.BAR_TEXTURE_NAMES[key]) or key, E.MEDIA_PATH .. "textures\\" .. file)
            end
        end
    end

    -- EllesmereUI's fonts, plus anything other addons share, come through LibSharedMedia.
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local names = {}
        for name in pairs(LSM:HashTable(kind)) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local path = LSM:Fetch(kind, name, true)
            local group = (type(path) == "string" and path:find("EllesmereUI", 1, true)) and "EllesmereUI" or "Shared media"
            add(group, name, path)
        end
    end

    local groups = {}
    for _, g in ipairs(GROUPS) do
        if #buckets[g] > 0 then
            table.sort(buckets[g], function(a, b) return a.name < b.name end)
            groups[#groups + 1] = { title = g, items = buckets[g] }
        end
    end
    return groups
end

-- Falls back to the bundled font, then the game's own, if a file is missing (e.g. EllesmereUI's
-- Expressway without EllesmereUI installed).
-- Redraws a FontString's text in its current font. One whose words don't change can keep
-- drawing the old font (the target's target name rarely changes).
local function Redraw(fs)
    pcall(function()
        local text = fs:GetText()
        fs:SetText("")
        fs:SetText(text)
    end)
end

-- A font file WoW hasn't finished loading can be refused on the first try (seen right after a
-- restart), so a refused font is retried a few times; the fallback only shows until it takes.
function Media:SetFont(fs, path, size, outline)
    if not fs then return end
    local wanted = path .. "|" .. size .. "|" .. (outline or "")
    fs.mediaFont = wanted
    if not fs:SetFont(path, size, outline) then
        if not fs:SetFont(CUSTOM_FONT, size, outline) then
            fs:SetFont(STANDARD_TEXT_FONT, size, outline)
        end
        for _, delay in ipairs({ 0.2, 1, 3 }) do
            C_Timer.After(delay, function()
                -- By now the text may be forbidden (aura text in restricted content); skip it.
                if fs.mediaFont ~= wanted or (fs.IsForbidden and fs:IsForbidden()) then return end
                local ok, set = pcall(fs.SetFont, fs, path, size, outline)
                if ok and set then Redraw(fs) end
            end)
        end
    end
    Redraw(fs)
end
