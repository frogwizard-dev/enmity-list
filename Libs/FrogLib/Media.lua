-- FrogLib Media: the bar textures and fonts the settings offer, and setting a font safely.
--   ns.Media = FrogLib.Media.New({
--       fonts = { { "Michroma (wide)", "Interface\\AddOns\\MyAddon\\Fonts\\Michroma.ttf" } },
--       fallbackFont = "...",  -- for a font file that won't load (default: the game's own)
--   })
--   ns.Media:List("statusbar" | "font") -> { { title = group, items = { { name =, path = } } } }
--   ns.Media:SetFont(fs, path, size, outline)
--   FrogLib.Media.Register(kind, name, path)  -- listed by every addon as "Frog" (FrogUI's bars)
-- An addon's own fonts are listed as "Bundled"; then Frog, the game's own, EllesmereUI's and
-- anything shared through LibSharedMedia. Built fresh each time, so late additions show up.

local Media = FrogLib:Module("Media", 1)
if not Media then return end

local GROUPS = { "Bundled", "Frog", "Blizzard", "EllesmereUI", "Shared media" }
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

-- Shared registrations (kept across newer copies of this part).
Media.registered = Media.registered or { statusbar = {}, font = {} }

function Media.Register(kind, name, path)
    local list = Media.registered[kind]
    if not list then return end
    for _, m in ipairs(list) do
        if m.path == path then return end
    end
    list[#list + 1] = { name = name, path = path }
end

Media.Instance = Media.Instance or {}
local Instance = Media.Instance
Media.InstanceMeta = Media.InstanceMeta or { __index = Instance }

function Media.New(opts)
    return setmetatable({ opts = opts or {} }, Media.InstanceMeta)
end

function Instance:List(kind)
    local buckets, seen = {}, {}
    for _, g in ipairs(GROUPS) do buckets[g] = {} end
    local function add(group, name, path)
        if type(path) ~= "string" or seen[path:lower()] then return end
        seen[path:lower()] = true
        table.insert(buckets[group], { name = name, path = path })
    end

    if kind == "font" then
        for _, f in ipairs(self.opts.fonts or {}) do add("Bundled", f[1], f[2]) end
    end
    for _, m in ipairs(Media.registered[kind] or {}) do add("Frog", m.name, m.path) end
    for _, m in ipairs(BUILTIN[kind] or {}) do add("Blizzard", m.name, m.path) end

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
            if g ~= "Bundled" then table.sort(buckets[g], function(a, b) return a.name < b.name end) end
            groups[#groups + 1] = { title = g, items = buckets[g] }
        end
    end
    return groups
end

-- Redraws a FontString's text in its current font. One whose words don't change can keep
-- drawing the old font (the target's target name rarely changes).
local function Redraw(fs)
    pcall(function()
        local text = fs:GetText()
        fs:SetText("")
        fs:SetText(text)
    end)
end

-- A font from an addon that isn't loaded (EllesmereUI's, after it's turned off or removed):
-- asking for it raises an error rather than just failing, so it isn't asked for at all.
local function FromMissingAddOn(path)
    local addon = path:match("^[Ii]nterface[\\/][Aa]dd[Oo]ns[\\/]([^\\/]+)")
    return addon ~= nil and not FrogLib.Loaded(addon)
end

-- A font file WoW hasn't finished loading can be refused on the first try (seen right after a
-- restart), so a refused font is retried a few times; the fallback only shows until it takes.
function Instance:SetFont(fs, path, size, outline)
    if not fs then return end
    local wanted = path .. "|" .. size .. "|" .. (outline or "")
    fs.frogFont = wanted
    local usable = not FromMissingAddOn(path)
    local ok, set = false, false
    if usable then ok, set = pcall(fs.SetFont, fs, path, size, outline) end
    if not (ok and set) then
        local fallback = self.opts.fallbackFont
        if not (fallback and fs:SetFont(fallback, size, outline)) then
            fs:SetFont(STANDARD_TEXT_FONT, size, outline)
        end
        for _, delay in ipairs(usable and { 0.2, 1, 3 } or {}) do
            C_Timer.After(delay, function()
                -- By now the text may be forbidden (aura text in restricted content); skip it.
                if fs.frogFont ~= wanted or (fs.IsForbidden and fs:IsForbidden()) then return end
                local ok2, set2 = pcall(fs.SetFont, fs, path, size, outline)
                if ok2 and set2 then Redraw(fs) end
            end)
        end
    end
    Redraw(fs)
end
