local ADDON, ns = ...
local UI = ns.UI
local issecret = issecretvalue or function() return false end

-- An aggro viewer in the style of FFXIV's enemy list. Rows are plain display frames (no
-- clicking: this client won't target a specific mob through its nameplate, and targeting by
-- name picks the nearest one), so addon code can show, hide and restack them freely in combat.
-- Enemies are listed in the order they joined, so rows don't jump about as threat shifts.

local MAX_PLATES = 40

ns.defaults = {
    locked = true,
    point = { "RIGHT", "UIParent", "RIGHT", -260, 60 },
    scale = 1,
    width = 220,
    rowHeight = 30,
    maxRows = 10,
    engagedOnly = true,    -- only enemies in combat, like FFXIV; off = every hostile nameplate
    onlyInCombat = false,  -- hide the whole list out of combat
    showThreat = true,     -- threat % on the right
    showHealth = true,     -- thin health line under the name
    font = "Interface\\AddOns\\EnmityList\\Fonts\\SourceSans3.ttf",
    outline = "OUTLINE",
    size = 13,
}

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- FFXIV's enmity dot: green (low) -> yellow -> orange -> red (it's attacking you).
local THREAT_COLORS = {
    [0] = { 0.35, 0.85, 0.35 },
    [1] = { 0.95, 0.85, 0.25 },
    [2] = { 1.00, 0.55, 0.15 },
    [3] = { 0.95, 0.25, 0.20 },
}
local NO_THREAT = { 0.55, 0.55, 0.55 }
local ENGAGED = { 0.95, 0.42, 0.50 }
local PASSIVE = { 0.96, 0.86, 0.56 }

local function Safe(v)
    if issecret(v) then return nil end
    return v
end

local List = {}
ns.List = List

------------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------------

local function CreateRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:EnableMouse(false) -- click-through: never blocks clicks on the world behind it

    -- A dark translucent band behind each row, as FFXIV's list has.
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetPoint("TOPLEFT", 0, -1)
    r.bg:SetPoint("BOTTOMRIGHT", 0, 1)
    r.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    r.bg:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0))
    -- Your current target: a light band.
    r.targeted = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.targeted:SetAllPoints(r.bg)
    r.targeted:SetTexture("Interface\\Buttons\\WHITE8X8")
    r.targeted:SetGradient("HORIZONTAL", CreateColor(1, 0.95, 0.7, 0.28), CreateColor(1, 0.95, 0.7, 0))
    r.targeted:Hide()

    r.dot = r:CreateTexture(nil, "ARTWORK")
    if not r.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask") then
        r.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    end
    r.dot:SetSize(12, 12)
    r.dot:SetPoint("LEFT", 4, 0)

    r.mark = r:CreateTexture(nil, "ARTWORK")
    r.mark:SetSize(14, 14)
    r.mark:SetPoint("LEFT", r.dot, "RIGHT", 4, 0)
    r.mark:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")

    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r.name:SetShadowOffset(1, -1)
    r.name:SetPoint("TOPLEFT", r.mark, "TOPRIGHT", 4, 2)
    r.threat = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.threat:SetJustifyH("RIGHT")
    r.threat:SetPoint("TOPRIGHT", -4, -3)
    r.threat:SetShadowOffset(1, -1)

    r.health = ns.CreateGauge(r)
    r.health:SetHeight(3)
    r.health.bar:SetPoint("BOTTOMLEFT", r.mark, "BOTTOMRIGHT", 5, -4)
    r.health.bar:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r:Hide()
    return r
end

local function StyleRow(r)
    local db = ns.db
    r:SetSize(db.width, db.rowHeight)
    ns.Media:SetFont(r.name, db.font, db.size, db.outline)
    ns.Media:SetFont(r.threat, db.font, math.max(8, db.size - 2), db.outline)
    r.name:SetPoint("RIGHT", r, "RIGHT", db.showThreat and -40 or -4, 0)
    r.threat:SetShown(db.showThreat)
    r.health.bar:SetShown(db.showHealth)
end

-- vals: { name, threatSituation, threatPercent, health, maxHealth, engaged, mark, targeted }
local function FillRow(r, v)
    -- Cleared first: text set while a font file is still loading can render blank, and
    -- rewriting the same text doesn't redraw it.
    r.name:SetText("")
    r.name:SetText(v.name)
    local tc = v.situation and THREAT_COLORS[v.situation] or NO_THREAT
    r.dot:SetVertexColor(tc[1], tc[2], tc[3])
    if ns.db.showThreat then
        -- May be secret: never compared, only handed to SetFormattedText.
        if issecret(v.percent) or v.percent ~= nil then
            pcall(r.threat.SetFormattedText, r.threat, "%d%%", v.percent)
        else
            r.threat:SetText("")
        end
    end
    r.health:SetValues(v.health, v.maxHealth, v.instant)
    local c = v.engaged and ENGAGED or PASSIVE
    r.health:SetColor(c[1], c[2], c[3])
    if v.mark then
        SetRaidTargetIconTexture(r.mark, v.mark)
        r.mark:Show()
    else
        r.mark:Hide()
    end
    r.targeted:SetShown(v.targeted == true)
end

------------------------------------------------------------------------------
-- The list
------------------------------------------------------------------------------

local joined, joinCount = {}, 0 -- unit token -> order it appeared in (reset when its plate is reused)

local function Eligible(unit)
    if not UnitExists(unit) then return false end
    local attackable, dead = Safe(UnitCanAttack("player", unit)), Safe(UnitIsDead(unit))
    if not attackable or dead then return false end
    if ns.db.engagedOnly and not Safe(UnitAffectingCombat(unit)) then return false end
    return true
end

function List:Init()
    local f = CreateFrame("Frame", "EnmityListFrame", UIParent)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        local p, _, rp, x, y = frame:GetPoint()
        ns.db.point = { p, "UIParent", rp, x, y }
    end)
    f.unlockTint = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.unlockTint:SetPoint("TOPLEFT", -6, 6)
    f.unlockTint:SetPoint("BOTTOMRIGHT", 6, -6)
    f.unlockTint:SetColorTexture(0.3, 0.6, 1, 0.2)
    self.frame = f

    self.rows = {}
    for i = 1, 20 do self.rows[i] = CreateRow(f) end

    local ev = CreateFrame("Frame")
    for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_HEALTH", "UNIT_MAXHEALTH",
        "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_NAME_UPDATE", "UNIT_FLAGS",
        "PLAYER_TARGET_CHANGED", "RAID_TARGET_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }) do
        pcall(ev.RegisterEvent, ev, event)
    end
    ev:SetScript("OnEvent", function(_, event, unit)
        if event == "NAME_PLATE_UNIT_ADDED" then
            joinCount = joinCount + 1
            joined[unit] = joinCount
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            joined[unit] = nil
        end
        self.dirty = true
    end)
    -- Coalesce everything into at most ~6 redraws a second; threat also drifts continuously.
    local elapsed = 0
    ev:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed > 0.15 and (self.dirty or elapsed > 0.5) then
            elapsed = 0
            self.dirty = false
            self:Refresh()
        end
    end)

    -- Nameplates already on screen at login/reload.
    for i = 1, MAX_PLATES do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            joinCount = joinCount + 1
            joined[unit] = joinCount
        end
    end
    self:Apply()
end

function List:Apply()
    local db = ns.db
    local f = self.frame
    f:SetScale(db.scale)
    f:ClearAllPoints()
    f:SetPoint(db.point[1], UIParent, db.point[3], db.point[4], db.point[5])
    f:SetSize(db.width, db.rowHeight)
    f:EnableMouse(not db.locked)
    f.unlockTint:SetShown(not db.locked)
    for _, r in ipairs(self.rows) do StyleRow(r) end
    self:Refresh(true)
end

local SAMPLE = {
    { name = "Anemos Flan", situation = 3, percent = 100, health = 0.82, maxHealth = 1, engaged = true },
    { name = "Anemos Harpeia", situation = 1, percent = 64, health = 0.55, maxHealth = 1, engaged = true },
    { name = "Anemos Harpeia", situation = 0, percent = 12, health = 0.30, maxHealth = 1, engaged = true },
}

function List:Refresh(instant)
    local db = ns.db
    local entries = {}
    if not db.locked then
        -- Unlocked: sample rows to position and style against.
        entries = SAMPLE
    elseif not db.onlyInCombat or InCombatLockdown() then
        local units = {}
        for unit in pairs(joined) do
            if Eligible(unit) then units[#units + 1] = unit end
        end
        table.sort(units, function(a, b) return joined[a] < joined[b] end)
        for i = 1, math.min(#units, db.maxRows) do
            local unit = units[i]
            local _, _, percent = UnitDetailedThreatSituation("player", unit)
            entries[i] = {
                name = UnitName(unit),
                situation = Safe(UnitThreatSituation("player", unit)),
                percent = percent,
                health = UnitHealth(unit), maxHealth = UnitHealthMax(unit),
                engaged = Safe(UnitAffectingCombat(unit)),
                mark = Safe(GetRaidTargetIndex(unit)),
                targeted = Safe(UnitIsUnit(unit, "target")),
                instant = instant,
            }
        end
    end

    for i, r in ipairs(self.rows) do
        local v = entries[i]
        if v then
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(i - 1) * db.rowHeight)
            FillRow(r, v)
            r:Show()
        else
            r:Hide()
        end
    end
    self.frame:SetHeight(math.max(1, #entries) * db.rowHeight)
end

------------------------------------------------------------------------------
-- Settings window
------------------------------------------------------------------------------

local function BuildLayout(p)
    local db = ns.db
    local place = UI.Placer()
    place(UI.Checkbox(p, "Unlock to move (drag the list; shows a preview)",
        function() return not db.locked end, function(v) db.locked = not v end), 34)
    place(UI.Stepper(p, "Scale", 0.5, 2, 0.05, function() return db.scale end, function(v) db.scale = v end, "%.2f"), 26)
    place(UI.Stepper(p, "Width", 120, 400, 10, function() return db.width end, function(v) db.width = v end), 26)
    place(UI.Stepper(p, "Row height", 20, 48, 1, function() return db.rowHeight end, function(v) db.rowHeight = v end), 26)
    place(UI.Stepper(p, "Most rows shown", 1, 20, 1, function() return db.maxRows end, function(v) db.maxRows = v end), 32)
    place(UI.Checkbox(p, "Only enemies in combat (like FFXIV)",
        function() return db.engagedOnly end, function(v) db.engagedOnly = v end), 28)
    place(UI.Checkbox(p, "Hide the list when you're out of combat",
        function() return db.onlyInCombat end, function(v) db.onlyInCombat = v end), 28)
    place(UI.Checkbox(p, "Show threat %",
        function() return db.showThreat end, function(v) db.showThreat = v end), 28)
    place(UI.Checkbox(p, "Show health line",
        function() return db.showHealth end, function(v) db.showHealth = v end), 36)
    place(UI.Help(p, "Enemies need a visible nameplate to be listed (V toggles enemy nameplates). "
        .. "The list is display-only: clicks pass straight through it.", 400), 40, 4)
end

local function BuildText(p)
    local db = ns.db
    local place = UI.Placer()
    place(UI.Dropdown(p, "Font", function() return ns.Media:List("font") end,
        function() return db.font end, function(v) db.font = v end), 30)
    place(UI.Dropdown(p, "Font outline", UI.OUTLINES, function() return db.outline end,
        function(v) db.outline = v end), 30)
    place(UI.Stepper(p, "Text size", 8, 24, 1, function() return db.size end, function(v) db.size = v end), 26)
end

function ns.ToggleConfig()
    if not ns.window then
        ns.window = UI.Window("EnmityListConfig", "EnmityList", 440, 470, {
            { "layout", "Layout", BuildLayout },
            { "text", "Text", BuildText },
        })
        return
    end
    ns.window:SetShown(not ns.window:IsShown())
end

------------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------------

function ns.Refresh()
    List:Apply()
    -- Font files load on first use; text set in that moment can render blank.
    C_Timer.After(0.1, function() List:Refresh(true) end)
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        EnmityListDB = EnmityListDB or {}
        EnmityListDB.driverMode = nil -- leftover from the clickable version
        CopyDefaults(ns.defaults, EnmityListDB)
        ns.db = EnmityListDB
    elseif event == "PLAYER_LOGIN" then
        List:Init()
    end
end)

SLASH_ENMITYLIST1 = "/enmity"
SlashCmdList.ENMITYLIST = ns.ToggleConfig
function EnmityList_OnCompartmentClick() ns.ToggleConfig() end

-- Its entry in the game's Options > AddOns list (Options.lua).
ns.AddOptionsPanel({
    open = function()
        if not (ns.window and ns.window:IsShown()) then ns.ToggleConfig() end
    end,
    commands = { { "/enmity", "open or close the settings" } },
})
