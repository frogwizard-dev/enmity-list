local ADDON, ns = ...
local UI = ns.UI
local issecret, Safe = FrogLib.issecret, FrogLib.Safe
local Threat, Icons = FrogLib.Threat, FrogLib.Icons

-- An aggro viewer in the style of FFXIV's enemy list: display-only rows (this client won't target a
-- given mob through its nameplate), free to restack in combat, in the order enemies joined. Threat is
-- your lead over the next highest, or how far behind you are, where there's someone to compare with;
-- otherwise your threat %. The same shows beside each enemy's nameplate.

local MAX_PLATES = 40

-- The bar textures and fonts the settings offer, and setting a font safely (FrogLib's Media),
-- with this addon's own fonts listed first.
local FONTS = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\"
ns.Media = FrogLib.Media.New({
    fonts = {
        { "Michroma (wide)", FONTS .. "Michroma.ttf" }, -- wide, like FFXIV's gauge numbers
        { "Source Sans 3 (Myriad-like)", FONTS .. "SourceSans3.ttf" },
    },
})

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

-- FFXIV's enmity dot: green (low) -> yellow -> orange -> red (it's attacking you).
local THREAT_COLORS = {
    [0] = { 0.35, 0.85, 0.35 },
    [1] = { 0.95, 0.85, 0.25 },
    [2] = { 1.00, 0.55, 0.15 },
    [3] = { 0.95, 0.25, 0.20 },
}
local NO_THREAT = { 0.55, 0.55, 0.55 }
-- The health line: FFXIV's engaged and not-yet-engaged colours (FrogLib.Color.XIV).
local ENGAGED, PASSIVE = FrogLib.Color.XIV.engaged, FrogLib.Color.XIV.passive

local List = {}
ns.List = List

------------------------------------------------------------------------------
-- Threat gaps
------------------------------------------------------------------------------

-- Your threat on `unit` against the highest of everyone else on it: your lead, or how far behind
-- (negative); nil with nobody else on it or the numbers hidden. FrogLib's, shared with FrogPlates.
local ThreatGap = FrogLib.Threat.Gap

-- Writes the threat into `text`: the gap (green ahead, red behind; FrogLib's, as FrogPlates
-- writes it) or the %, which may be secret and so only ever goes to SetFormattedText.
local GAP_AHEAD, GAP_BEHIND = { r = 0.45, g = 0.95, b = 0.45 }, { r = 1.00, g = 0.40, b = 0.35 }
local PLAIN = { 1, 1, 1 }
local function SetThreatText(text, entry)
    if ns.db.showGap and entry.gap then
        Threat.SetGapText(text, entry.gap, GAP_AHEAD, GAP_BEHIND)
    elseif issecret(entry.percent) or entry.percent ~= nil then
        text:SetTextColor(PLAIN[1], PLAIN[2], PLAIN[3])
        pcall(text.SetFormattedText, text, "%d%%", entry.percent)
    else
        text:SetText("")
    end
end

------------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------------

local MARK_SIZE = 14

local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:EnableMouse(false) -- click-through: never blocks clicks on the world behind it

    -- A dark translucent band behind each row, as FFXIV's list has.
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetPoint("TOPLEFT", 0, -1)
    row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
    row.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.bg:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0))
    -- Your current target: a light band.
    row.targeted = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.targeted:SetAllPoints(row.bg)
    row.targeted:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.targeted:SetGradient("HORIZONTAL", CreateColor(1, 0.95, 0.7, 0.28), CreateColor(1, 0.95, 0.7, 0))
    row.targeted:Hide()

    row.dot = row:CreateTexture(nil, "ARTWORK")
    if not row.dot:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask") then
        row.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    end
    row.dot:SetSize(12, 12)
    row.dot:SetPoint("LEFT", 4, 0)

    -- The raid mark: an icon written into text (FrogLib.Icons), as which mark it is can be secret
    -- in instances. Its size is fixed, so the name and health line keep their place without one.
    row.mark = row:CreateFontString(nil, "ARTWORK")
    row.mark:SetFont(STANDARD_TEXT_FONT, 12, "")
    row.mark:SetSize(MARK_SIZE, MARK_SIZE)
    row.mark:SetPoint("LEFT", row.dot, "RIGHT", 4, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetShadowOffset(1, -1)
    row.name:SetPoint("TOPLEFT", row.mark, "TOPRIGHT", 4, 2)
    row.threat = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.threat:SetJustifyH("RIGHT")
    row.threat:SetPoint("TOPRIGHT", -4, -3)
    row.threat:SetShadowOffset(1, -1)

    row.health = FrogLib.Gauge.New(row)
    row.health:SetHeight(3)
    row.health.bar:SetPoint("BOTTOMLEFT", row.mark, "BOTTOMRIGHT", 5, -4)
    row.health.bar:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row:Hide()
    return row
end

local function StyleRow(row)
    local db = ns.db
    row:SetSize(db.width, db.rowHeight)
    ns.Media:SetNameFont(row.name, db.font, db.size, db.outline) -- names in other scripts draw too
    ns.Media:SetFont(row.threat, db.font, math.max(8, db.size - 2), db.outline)
    row.name:SetPoint("RIGHT", row, "RIGHT", db.showThreat and -40 or -4, 0)
    row.threat:SetShown(db.showThreat)
    row.health.bar:SetShown(db.showHealth)
end

-- entry: { name, situation, percent, gap, health, maxHealth, engaged, mark, targeted, instant }
local function FillRow(row, entry)
    -- Cleared first: text set while a font file is still loading can render blank, and
    -- rewriting the same text doesn't redraw it.
    row.name:SetText("")
    row.name:SetText(entry.name)
    local dotColor = entry.situation and THREAT_COLORS[entry.situation] or NO_THREAT
    row.dot:SetVertexColor(dotColor[1], dotColor[2], dotColor[3])
    if ns.db.showThreat then SetThreatText(row.threat, entry) end
    row.health:SetValues(entry.health, entry.maxHealth, entry.instant)
    local color = entry.engaged and ENGAGED or PASSIVE
    row.health:SetColor(color.r, color.g, color.b)
    -- The mark may be secret: never tested, only written (nothing shows for "no mark").
    row.mark:SetShown(Icons.SetRaidMark(row.mark, entry.mark, MARK_SIZE))
    row.targeted:SetShown(entry.targeted == true)
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
        local unitFrame = plate.UnitFrame
        local bar = unitFrame and (unitFrame.healthBar
            or (unitFrame.HealthBarsContainer and unitFrame.HealthBarsContainer.healthBar))
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

-- FrogPlates and XIVPlates show the same threat text on their plates themselves, while they restyle them with their
-- threat text on (skin.threatText; one loaded with its plates or its text turned off leaves them to us).
local function FrogPlatesShown()
    local plates = FrogLib.Plates
    local skin = plates and plates.state and plates.state.skin
    local ask = skin and (skin.threatText or skin.enabled)
    if not ask then return false end
    local ok, on = pcall(ask)
    return ok and on and true or false
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
    local frame = CreateFrame("Frame", "EnmityListFrame", UIParent)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    -- Dragged while unlocked; the tint marks it (FrogLib's Mover.lua).
    FrogLib.Mover.Make(frame, { save = function(point) ns.db.point = point end, tint = 6, tintLevel = -1 })
    self.frame = frame

    self.rows = {}
    for i = 1, 20 do self.rows[i] = CreateRow(frame) end

    local events = CreateFrame("Frame")
    for _, event in ipairs({ "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UNIT_HEALTH", "UNIT_MAXHEALTH",
        "UNIT_THREAT_LIST_UPDATE", "UNIT_THREAT_SITUATION_UPDATE", "UNIT_NAME_UPDATE", "UNIT_FLAGS",
        "PLAYER_TARGET_CHANGED", "RAID_TARGET_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED" }) do
        pcall(events.RegisterEvent, events, event)
    end
    -- A unit event only counts for a mob with a plate (the list is made from them); party, raid and pet units' health
    -- and the like are skipped.
    events:SetScript("OnEvent", function(frame, event, unit)
        if event == "NAME_PLATE_UNIT_ADDED" then
            joinCount = joinCount + 1
            joined[unit] = joinCount
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            joined[unit] = nil
        elseif type(unit) == "string" and event:find("^UNIT_") and not joined[unit] then
            return
        end
        self.dirty = true
        frame:Show() -- the redraw runs again
    end)
    -- Coalesce everything into at most ~6 redraws a second; threat also drifts continuously, so while rows show it's
    -- looked at twice a second too. Nothing runs while there are none (the frame hides; its events go on).
    local waited = 0
    events:SetScript("OnUpdate", function(frame, elapsed)
        waited = waited + elapsed
        if waited > 0.15 and (self.dirty or waited > 0.5) then
            waited = 0
            self.dirty = false
            self:Refresh()
            if self.shownRows == 0 and not self.dirty then frame:Hide() end
        end
    end)
    self.events = events

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
    local frame = self.frame
    frame:SetScale(db.scale)
    frame:ClearAllPoints()
    frame:SetPoint(db.point[1], UIParent, db.point[3], db.point[4], db.point[5])
    frame:SetSize(db.width, db.rowHeight)
    frame:EnableMouse(not db.locked)
    frame.unlockTint:SetShown(not db.locked)
    for _, row in ipairs(self.rows) do StyleRow(row) end
    self:Refresh(true)
end

local SAMPLE = {
    { name = "Anemos Flan", situation = 3, percent = 100, health = 0.82, maxHealth = 1, engaged = true },
    { name = "Anemos Harpeia", situation = 1, percent = 64, health = 0.55, maxHealth = 1, engaged = true },
    { name = "Anemos Harpeia", situation = 0, percent = 12, health = 0.30, maxHealth = 1, engaged = true },
}

-- The lists a refresh fills, kept and reused (it runs several times a second in a fight).
local liveEntries, units, entryPool = {}, {}, {}
local function ByJoined(first, second) return joined[first] < joined[second] end

function List:Refresh(instant)
    local db = ns.db
    local entries = wipe(liveEntries)
    if not db.locked then
        -- Unlocked: sample rows to position and style against.
        entries = SAMPLE
    elseif not db.onlyInCombat or InCombatLockdown() then
        wipe(units)
        for unit in pairs(joined) do
            if Eligible(unit) then units[#units + 1] = unit end
        end
        table.sort(units, ByJoined)
        HidePlateLabels()
        local targetPlate = C_NamePlate.GetNamePlateForUnit("target")
        for i, unit in ipairs(units) do
            -- Threat reads as secret through a plate's token, plainly through "target": your target's read that way.
            local _, _, percent = UnitDetailedThreatSituation("player", FrogLib.Threat.Readable(unit))
            local entry = entryPool[i] or {}
            entryPool[i] = entry
            entry.name = FrogLib.Unit.Name(unit)
            entry.situation = Safe(UnitThreatSituation("player", unit))
            entry.percent = percent
            entry.gap = ThreatGap(unit)
            entry.health, entry.maxHealth = UnitHealth(unit), UnitHealthMax(unit)
            entry.engaged = Safe(UnitAffectingCombat(unit))
            entry.mark = GetRaidTargetIndex(unit) -- may be secret (FillRow)
            -- (The plate frames compared: whether two units are the same can be secret.)
            entry.targeted = targetPlate ~= nil and C_NamePlate.GetNamePlateForUnit(unit) == targetPlate
            entry.instant = instant
            if i <= db.maxRows then entries[i] = entry end
            -- On its nameplate too, once you're on its threat list (FrogPlates shows the same on its own).
            if db.plates and entry.situation ~= nil and not FrogPlatesShown() then
                local label = PlateLabel(unit)
                if label then
                    SetThreatText(label, entry)
                    label:Show()
                end
            end
        end
    else
        HidePlateLabels()
    end

    for i, row in ipairs(self.rows) do
        local entry = entries[i]
        if entry then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 0, -(i - 1) * db.rowHeight)
            FillRow(row, entry)
            row:Show()
        else
            row:Hide()
        end
    end
    self.shownRows = #entries
    self.frame:SetHeight(math.max(1, #entries) * db.rowHeight)
    -- Rows come from a settings change too (not only an event): the threat drift redraw runs again for them.
    if #entries > 0 and self.events then self.events:Show() end
end

------------------------------------------------------------------------------
-- Settings window
------------------------------------------------------------------------------

local function BuildLayout(page)
    local db = ns.db
    local place = UI.Placer()
    place(UI.Checkbox(page, "Unlock to move (drag the list; shows a preview)",
        function() return not db.locked end, function(value) db.locked = not value end), 34)
    place(UI.Stepper(page, "Scale", 0.5, 2, 0.05, db, "scale", "%.2f"), 26)
    place(UI.Stepper(page, "Width", 120, 400, 10, db, "width"), 26)
    place(UI.Stepper(page, "Row height", 20, 48, 1, db, "rowHeight"), 26)
    place(UI.Stepper(page, "Most rows shown", 1, 20, 1, db, "maxRows"), 32)
    place(UI.Checkbox(page, "Only enemies in combat (like FFXIV)", db, "engagedOnly"), 28)
    place(UI.Checkbox(page, "Hide the list when you're out of combat", db, "onlyInCombat"), 28)
    place(UI.Checkbox(page, "Show threat", db, "showThreat"), 28)
    place(UI.Checkbox(page, "...as your lead (or how far behind) when others are on it", db, "showGap"), 28, 20)
    place(UI.Checkbox(page, "Threat beside enemies' nameplates", db, "plates"), 28)
    place(UI.Checkbox(page, "Show health line", db, "showHealth"), 36)
    place(UI.Help(page, "Enemies need a visible nameplate to be listed (V toggles enemy nameplates). "
        .. "The list is display-only: clicks pass straight through it. The lead is against the "
        .. "highest of your group and pets; alone, or where the game hides the numbers, it's "
        .. "your threat %.", 400), 54, 4)
end

local function BuildText(page)
    local db = ns.db
    local place = UI.Placer()
    place(UI.Dropdown(page, "Font", function() return ns.Media:List("font") end, db, "font"), 30)
    place(UI.Dropdown(page, "Font outline", UI.OUTLINES, db, "outline"), 30)
    place(UI.Stepper(page, "Text size", 8, 24, 1, db, "size"), 26)
    place(UI.Stepper(page, "Nameplate text size", 6, 20, 1, db, "plateSize"), 26)
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
loader:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" and addonName == ADDON then
        EnmityListDB = EnmityListDB or {}
        EnmityListDB.driverMode = nil -- leftover from the clickable version
        FrogLib.Util.CopyDefaults(ns.defaults, EnmityListDB)
        ns.db = EnmityListDB
    elseif event == "PLAYER_LOGIN" then
        List:Init()
    end
end)

-- /enmity test, in combat with your target: what the game lets addons see of its threat (secret or
-- not, yours and your group's) and if its nameplate is forbidden (nothing can be added to those).
local function Test()
    local unit = "target"
    if not UnitExists(unit) then
        print("|cffe08080EnmityList|r: target an enemy you're fighting first.")
        return
    end
    local function Describe(value)
        if value == nil then return "nil" end
        if issecret(value) then return "secret" end
        return tostring(value)
    end
    local _, status, percent, rawPercent, value = UnitDetailedThreatSituation("player", unit)
    print(string.format("|cffe08080EnmityList|r: in combat: %s. You: status %s, %% %s, raw %% %s, threat %s.",
        tostring(InCombatLockdown()), Describe(status), Describe(percent), Describe(rawPercent), Describe(value)))
    for _, other in ipairs({ "pet", "party1", "party2", "party3", "party4" }) do
        if UnitExists(other) then
            local _, _, theirPercent, _, theirValue = UnitDetailedThreatSituation(other, unit)
            print(string.format("  %s: %% %s, threat %s", other, Describe(theirPercent), Describe(theirValue)))
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
SlashCmdList.ENMITYLIST = function(input)
    local command, rest = strtrim(input or ""):match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()
    if command == "test" then
        Test()
    elseif command == "lab" then
        ns.LabUI.Command(rest) -- the threat lab (Lab.lua, LabUI.lua)
    else
        ns.ToggleConfig()
    end
end
function EnmityList_OnCompartmentClick() ns.ToggleConfig() end

-- Its entry in the game's Options > AddOns list (Options.lua).
FrogLib.Options.Add("EnmityList", ns, {
    open = function()
        if not (ns.window and ns.window:IsShown()) then ns.ToggleConfig() end
    end,
    commands = {
        { "/enmity", "open or close the settings" },
        { "/enmity lab", "the threat lab: how much threat each of your abilities makes, measured as you fight" },
        { "/enmity lab verbose", "a chat line for each clean threat lab measurement (on/off)" },
        { "/enmity lab reset", "delete the threat lab's measurements for this character" },
    },
})
