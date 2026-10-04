local ADDON, ns = ...
local UI = ns.UI
local issecret = issecretvalue or function() return false end

-- An aggro viewer in the style of FFXIV's enemy list. Rows are plain display frames (no
-- clicking: this client won't target a specific mob through its nameplate, and targeting by
-- name picks the nearest one), so addon code can show, hide and restack them freely in combat.
-- Enemies are listed in the order they joined, so rows don't jump about as threat shifts.
--
-- Threat is shown as a gap where there's someone to compare with: your lead over the next
-- highest (party, raid or pets) while it's on you, or how far behind the one it's on you are.
-- Alone, or where the game hides the numbers, it's your threat % instead. The same goes on
-- each enemy's nameplate, beside its health bar, where the game lets addons add to it.

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
    showThreat = true,     -- threat on the right: the gap (see above) or your %
    showGap = true,        -- the gap where there's one; off = always the %
    plates = true,         -- the same threat beside each engaged enemy's nameplate
    plateSize = 11,
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

-- A unit's name as the game's own frames show it: on Forever that includes the surname
-- (GetUnitName's second argument), where UnitName gives only the first name.
local function FullName(unit)
    if GetUnitName then
        local ok, name = pcall(GetUnitName, unit, true)
        if ok and name then return name end
    end
    return UnitName(unit)
end

------------------------------------------------------------------------------
-- Threat gaps
------------------------------------------------------------------------------

local function Number(n)
    local a = math.abs(n)
    if a >= 1000000 then return string.format("%.1fm", n / 1000000) end
    if a >= 1000 then return string.format("%.1fk", n / 1000) end
    return tostring(math.floor(n + 0.5))
end

-- Your threat on `unit` against the highest of everyone else on it (your pet, your party or
-- raid and their pets): positive is your lead, negative how far behind you are. nil with nobody
-- else on it, or when the game hides the numbers.
local function ThreatGap(unit)
    local _, _, _, _, mine = UnitDetailedThreatSituation("player", unit)
    if mine == nil or issecret(mine) then return nil end
    local best
    local function Consider(who)
        if not UnitExists(who) or Safe(UnitIsUnit(who, "player")) ~= false then return end
        local _, _, _, _, v = UnitDetailedThreatSituation(who, unit)
        if v ~= nil and not issecret(v) and v > 0 and (not best or v > best) then best = v end
    end
    Consider("pet")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            Consider("raid" .. i)
            Consider("raidpet" .. i)
        end
    else
        for i = 1, 4 do
            Consider("party" .. i)
            Consider("partypet" .. i)
        end
    end
    if not best then return nil end
    return mine - best
end

-- Writes the threat into `fs`: the gap (green ahead, red behind) or the %, which may be secret
-- and so only ever goes to SetFormattedText.
local GAP_AHEAD, GAP_BEHIND, PLAIN = { 0.45, 0.95, 0.45 }, { 1.00, 0.40, 0.35 }, { 1, 1, 1 }
local function SetThreatText(fs, v)
    if ns.db.showGap and v.gap then
        local c = v.gap >= 0 and GAP_AHEAD or GAP_BEHIND
        fs:SetTextColor(c[1], c[2], c[3])
        fs:SetText((v.gap >= 0 and "+" or "") .. Number(v.gap))
    elseif issecret(v.percent) or v.percent ~= nil then
        fs:SetTextColor(PLAIN[1], PLAIN[2], PLAIN[3])
        pcall(fs.SetFormattedText, fs, "%d%%", v.percent)
    else
        fs:SetText("")
    end
end

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
    if ns.db.showThreat then SetThreatText(r.threat, v) end
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
-- Nameplates: a threat label beside each engaged enemy's health bar. Plates are re-used for
-- other enemies, so the label belongs to the plate and is filled from whoever's on it.
------------------------------------------------------------------------------

local plateLabels = {} -- nameplate frame -> our label on it

local function PlateLabel(unit)
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    -- Forbidden plates (in some instances) take nothing from addons.
    if not plate or plate:IsForbidden() then return nil end
    local label = plateLabels[plate]
    if not label then
        local uf = plate.UnitFrame
        local bar = uf and (uf.healthBar or (uf.HealthBarsContainer and uf.HealthBarsContainer.healthBar))
        local holder = CreateFrame("Frame", nil, plate)
        holder:SetAllPoints(bar or plate)
        holder:SetFrameLevel((bar or plate):GetFrameLevel() + 5)
        label = holder:CreateFontString(nil, "OVERLAY")
        label:SetPoint("LEFT", holder, "RIGHT", 4, 0)
        label:SetShadowOffset(1, -1)
        plateLabels[plate] = label
    end
    -- The font only when it's changed (this runs several times a second).
    local font = ns.db.font .. ns.db.plateSize .. ns.db.outline
    if label.font ~= font then
        label.font = font
        ns.Media:SetFont(label, ns.db.font, ns.db.plateSize, ns.db.outline)
    end
    return label
end

local function FrogPlatesShown()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    return isLoaded and isLoaded("FrogPlates")
end

local function HidePlateLabels()
    for _, label in pairs(plateLabels) do label:Hide() end
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
        HidePlateLabels()
        for i, unit in ipairs(units) do
            local _, _, percent = UnitDetailedThreatSituation("player", unit)
            local v = {
                name = FullName(unit),
                situation = Safe(UnitThreatSituation("player", unit)),
                percent = percent,
                gap = ThreatGap(unit),
                health = UnitHealth(unit), maxHealth = UnitHealthMax(unit),
                engaged = Safe(UnitAffectingCombat(unit)),
                mark = Safe(GetRaidTargetIndex(unit)),
                targeted = Safe(UnitIsUnit(unit, "target")),
                instant = instant,
            }
            if i <= db.maxRows then entries[i] = v end
            -- On its nameplate too, once you're on its threat list.
            -- (FrogPlates shows the same on its own nameplates.)
            if db.plates and v.situation ~= nil and not FrogPlatesShown() then
                local label = PlateLabel(unit)
                if label then
                    SetThreatText(label, v)
                    label:Show()
                end
            end
        end
    else
        HidePlateLabels()
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
    place(UI.Checkbox(p, "Show threat",
        function() return db.showThreat end, function(v) db.showThreat = v end), 28)
    place(UI.Checkbox(p, "...as your lead (or how far behind) when others are on it",
        function() return db.showGap end, function(v) db.showGap = v end), 28, 20)
    place(UI.Checkbox(p, "Threat beside enemies' nameplates",
        function() return db.plates end, function(v) db.plates = v end), 28)
    place(UI.Checkbox(p, "Show health line",
        function() return db.showHealth end, function(v) db.showHealth = v end), 36)
    place(UI.Help(p, "Enemies need a visible nameplate to be listed (V toggles enemy nameplates). "
        .. "The list is display-only: clicks pass straight through it. The lead is against the "
        .. "highest of your group and pets; alone, or where the game hides the numbers, it's "
        .. "your threat %.", 400), 54, 4)
end

local function BuildText(p)
    local db = ns.db
    local place = UI.Placer()
    place(UI.Dropdown(p, "Font", function() return ns.Media:List("font") end,
        function() return db.font end, function(v) db.font = v end), 30)
    place(UI.Dropdown(p, "Font outline", UI.OUTLINES, function() return db.outline end,
        function(v) db.outline = v end), 30)
    place(UI.Stepper(p, "Text size", 8, 24, 1, function() return db.size end, function(v) db.size = v end), 26)
    place(UI.Stepper(p, "Nameplate text size", 6, 20, 1, function() return db.plateSize end,
        function(v) db.plateSize = v end), 26)
end

function ns.ToggleConfig()
    if not ns.window then
        ns.window = UI.Window("EnmityListConfig", "EnmityList", 440, 540, {
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

-- /enmity test, in combat with your target: what the game lets addons see, for threat gaps and
-- nameplate threat. Prints, for the target: whether your threat numbers are secret (secret ones
-- can be shown but not subtracted), the raw threat values of you and your group on it, and whether
-- its nameplate frame is forbidden (forbidden ones can't have anything added to them).
local function Test()
    local unit = "target"
    if not UnitExists(unit) then
        print("|cffe08080EnmityList|r: target an enemy you're fighting first.")
        return
    end
    local function Describe(v)
        if v == nil then return "nil" end
        if issecret(v) then return "secret" end
        return tostring(v)
    end
    local _, status, percent, rawPercent, value = UnitDetailedThreatSituation("player", unit)
    print(string.format("|cffe08080EnmityList|r: in combat: %s. You: status %s, %% %s, raw %% %s, threat %s.",
        tostring(InCombatLockdown()), Describe(status), Describe(percent), Describe(rawPercent), Describe(value)))
    for _, other in ipairs({ "pet", "party1", "party2", "party3", "party4" }) do
        if UnitExists(other) then
            local _, _, p, _, v = UnitDetailedThreatSituation(other, unit)
            print(string.format("  %s: %% %s, threat %s", other, Describe(p), Describe(v)))
        end
    end
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
    if plate then
        print("  Its nameplate: " .. (plate:IsForbidden() and "forbidden" or "open to addons") .. ".")
    else
        print("  Its nameplate: none showing (V shows enemy nameplates).")
    end
end

SLASH_ENMITYLIST1 = "/enmity"
SlashCmdList.ENMITYLIST = function(msg)
    if strtrim(msg or ""):lower() == "test" then
        Test()
    else
        ns.ToggleConfig()
    end
end
function EnmityList_OnCompartmentClick() ns.ToggleConfig() end

-- Its entry in the game's Options > AddOns list (Options.lua).
ns.AddOptionsPanel({
    open = function()
        if not (ns.window and ns.window:IsShown()) then ns.ToggleConfig() end
    end,
    commands = { { "/enmity", "open or close the settings" } },
})
