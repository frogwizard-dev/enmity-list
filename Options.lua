local ADDON, ns = ...

-- Shared by all of these addons (each keeps its own copy; keep them identical).
-- An entry for the addon in the game's Options > AddOns list, so it can be found there: its
-- name, version and description, a button that opens its own settings window, and its slash
-- commands. Usage, from any file loaded after this one:
--   ns.AddOptionsPanel({
--       open = function() ... end,             -- opens the addon's settings
--       button = "Open settings",              -- optional label for that button
--       commands = { { "/xiv", "open the settings" } },
--   })

local function Meta(field)
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local value = get and get(ADDON, field)
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

local function Build(opts)
    local title = Meta("Title") or ADDON
    local panel = CreateFrame("Frame")
    panel.name = title

    local heading = Text(panel, "GameFontNormalHuge", title)
    heading:SetPoint("TOPLEFT", 16, -16)
    local version = Meta("Version")
    local sub = Text(panel, "GameFontDisableSmall", version and ("Version " .. version) or "")
    sub:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
    local notes = Text(panel, "GameFontHighlight", Meta("Notes") or "", 560)
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

local pending
local function Register()
    if not pending or not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local panel, title = Build(pending)
    local category = Settings.RegisterCanvasLayoutCategory(panel, title)
    Settings.RegisterAddOnCategory(category)
    ns.optionsCategory = category
    pending = nil
end

function ns.AddOptionsPanel(opts)
    pending = opts
    if IsLoggedIn and IsLoggedIn() then
        pcall(Register)
    else
        local f = CreateFrame("Frame")
        f:RegisterEvent("PLAYER_LOGIN")
        f:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            pcall(Register)
        end)
    end
end
