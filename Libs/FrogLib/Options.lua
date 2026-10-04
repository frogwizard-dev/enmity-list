-- FrogLib Options: an entry for an addon in the game's Options > AddOns list, under one shared
-- "Frog Wizard" section: its name, version and description, a button that opens its own settings
-- window, and its slash commands.
--   FrogLib.Options.Add(ADDON, ns, {
--       open = function() ... end,             -- opens the addon's settings
--       button = "Open settings",              -- optional label for that button
--       commands = { { "/xiv", "open the settings" } },
--   })                                         -- sets ns.optionsCategory once registered
-- The section itself is the global FrogwizardOptions, as before FrogLib, so addons with the old
-- per-addon Options.lua still join the same one.

local Options = FrogLib:Module("Options", 1)
if not Options then return end

local SECTION = "Frog Wizard"

local function Meta(addon, field)
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local value = get and get(addon, field)
    return value and value ~= "" and value or nil
end

local function Text(parent, font, text, width)
    local fs = parent:CreateFontString(nil, "ARTWORK", font)
    fs:SetJustifyH("LEFT")
    if width then fs:SetWidth(width) end
    fs:SetText(text)
    return fs
end

-- Closes the game's options window so the addon's own window isn't hidden behind it.
local function CloseOptions()
    if not (SettingsPanel and SettingsPanel:IsShown()) then return end
    if SettingsPanel.Close then
        pcall(SettingsPanel.Close, SettingsPanel, true)
    else
        pcall(HideUIPanel, SettingsPanel)
    end
end
Options.CloseOptions = CloseOptions

local function Build(addon, opts)
    local title = Meta(addon, "Title") or addon
    local panel = CreateFrame("Frame")
    panel.name = title

    local heading = Text(panel, "GameFontNormalHuge", title)
    heading:SetPoint("TOPLEFT", 16, -16)
    local version = Meta(addon, "Version")
    local sub = Text(panel, "GameFontDisableSmall", version and ("Version " .. version) or "")
    sub:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
    local notes = Text(panel, "GameFontHighlight", Meta(addon, "Notes") or "", 560)
    notes:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -14)

    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetText(opts.button or ("Open " .. title .. " settings"))
    button:SetWidth(math.max(200, button:GetFontString():GetStringWidth() + 40))
    button:SetHeight(26)
    button:SetPoint("TOPLEFT", notes, "BOTTOMLEFT", 0, -18)
    button:SetScript("OnClick", function()
        CloseOptions()
        opts.open()
    end)

    local last = button
    if opts.commands and #opts.commands > 0 then
        local label = Text(panel, "GameFontNormal", "Slash commands")
        label:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -24)
        last = label
        for _, c in ipairs(opts.commands) do
            local line = Text(panel, "GameFontHighlight", "|cffffd100" .. c[1] .. "|r   " .. c[2], 560)
            line:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -6)
            last = line
        end
    end
    local hint = Text(panel, "GameFontDisableSmall",
        "Also in the AddOn compartment, the button beside your minimap.", 560)
    hint:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -20)
    return panel, title
end

-- The section: whichever addon gets here first makes it, a page listing them all, each with a
-- button to its own settings. Each addon's page goes under it.
local function Section()
    local s = _G.FrogwizardOptions
    if s then return s end
    local panel = CreateFrame("Frame")
    panel.name = SECTION
    local heading = Text(panel, "GameFontNormalHuge", SECTION)
    heading:SetPoint("TOPLEFT", 16, -16)
    local intro = Text(panel, "GameFontHighlight",
        "Frog Wizard's addons. Each has its own page under this one, or open its settings here.", 560)
    intro:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -14)
    s = { panel = panel, entries = {}, rows = {} }
    -- One row per addon, laid out each time the page opens (addons join as they load).
    panel:SetScript("OnShow", function()
        table.sort(s.entries, function(a, b) return a.title < b.title end)
        local last = intro
        for i, e in ipairs(s.entries) do
            local row = s.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, panel)
                row:SetSize(560, 28)
                row.label = Text(row, "GameFontNormal", "")
                row.label:SetPoint("LEFT", 0, 0)
                row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                row.button:SetSize(140, 22)
                row.button:SetPoint("LEFT", 230, 0)
                row.button:SetText("Open settings")
                s.rows[i] = row
            end
            row.label:SetText(e.title)
            row.button:SetScript("OnClick", function()
                CloseOptions()
                e.open()
            end)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, i == 1 and -16 or -2)
            row:Show()
            last = row
        end
    end)
    s.category = Settings.RegisterCanvasLayoutCategory(panel, SECTION)
    Settings.RegisterAddOnCategory(s.category)
    _G.FrogwizardOptions = s
    return s
end

local function Register(addon, ns, opts)
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local panel, title = Build(addon, opts)
    local category
    if Settings.RegisterCanvasLayoutSubcategory then
        local s = Section()
        category = Settings.RegisterCanvasLayoutSubcategory(s.category, panel, title)
        table.insert(s.entries, { title = title, open = opts.open })
    else
        category = Settings.RegisterCanvasLayoutCategory(panel, title)
        Settings.RegisterAddOnCategory(category)
    end
    if ns then ns.optionsCategory = category end
end

function Options.Add(addon, ns, opts)
    if IsLoggedIn and IsLoggedIn() then
        pcall(Register, addon, ns, opts)
    else
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_LOGIN")
        f:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            pcall(Register, addon, ns, opts)
        end)
    end
end
