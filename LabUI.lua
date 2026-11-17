local _, ns = ...
local UI = ns.UI

-- The threat lab's window (/enmity lab): your abilities' threat by either method (the fit from
-- normal play, or clean samples), with filters, a breakdown of the one you click, and what the
-- lab is doing right now. Measuring and solving are Lab.lua's.

local LabUI = {}
ns.LabUI = LabUI

local WIDTH, HEIGHT = 840, 620
local ROWS, ROW_HEIGHT = 10, 22
local GOOD, WARN, DIM, BAD = "|cff70e070", "|cffffd100", "|cff9d9d9d", "|cffff6060"

local STANCES = {
    { "def", "Defensive Stance" }, { "battle", "Battle Stance" }, { "bers", "Berserker Stance" },
    { "bear", "Bear Form" }, { "cat", "Cat Form" }, { "none", "No stance" }, { "any", "All stances" },
}
local STANCE_NAMES = {}
for _, stance in ipairs(STANCES) do STANCE_NAMES[stance[1]] = stance[2] end
local OUTCOMES = { { "hits", "Hits only" }, { "all", "All outcomes" }, { "misses", "Misses only" } }
local METHODS = { { "fit", "Fit (normal play)" }, { "clean", "Clean samples" } }
local OUTCOME_NAMES = {
    hit = "hit", crit = "crit", glance = "glancing", pblock = "partly blocked", landed = "landed",
    side = "other enemy", miss = "miss", dodge = "dodge", parry = "parry", block = "blocked",
    resist = "resisted", immune = "immune", evade = "evaded", deflect = "deflected", reflect = "reflected",
    absorb = "absorbed",
}
local TANK = { [0] = "not tanking", [1] = "not tanking (high)", [2] = "tanking (insecure)", [3] = "tanking" }

-- Columns of each method's table.
local COLUMNS = {
    clean = {
        { key = "name", label = "Ability", x = 28, w = 210, justify = "LEFT" },
        { key = "c1", label = "Uses", x = 242, w = 44 },
        { key = "c2", label = "Avg threat", x = 290, w = 76 },
        { key = "c3", label = "Per rage", x = 370, w = 60 },
        { key = "c4", label = "Per sec", x = 434, w = 62 },
        { key = "c5", label = "From damage", x = 500, w = 110 },
        { key = "c6", label = "Spread (min-max)", x = 614, w = 170 },
    },
    fit = {
        { key = "name", label = "Ability", x = 28, w = 210, justify = "LEFT" },
        { key = "c1", label = "Uses", x = 242, w = 44 },
        { key = "c2", label = "Bonus", x = 290, w = 60 },
        { key = "c3", label = "From damage", x = 354, w = 80 },
        { key = "c4", label = "Per use", x = 438, w = 62 },
        { key = "c5", label = "Per rage", x = 504, w = 56 },
        { key = "c6", label = "Per sec", x = 564, w = 60 },
        { key = "c7", label = "± (windows)", x = 628, w = 156 },
    },
}

------------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------------

local function Number(value)
    local size = math.abs(value)
    if size >= 1000000 then return string.format("%.1fm", value / 1000000) end
    if size >= 10000 then return string.format("%.1fk", value / 1000) end
    if size < 10 and size ~= math.floor(size) then return string.format("%.1f", value) end
    return tostring(math.floor(value + 0.5))
end

local function Signed(value)
    return (value > 0 and "+" or "") .. Number(value)
end

-- Threat in the game's units (raw / scale).
local function Threat(raw)
    local scale = ns.Lab:Scale()
    return raw / scale
end

local function Average(totals) return totals.n > 0 and Threat(totals.sum) / totals.n or 0 end

local function Spread(totals)
    if totals.n == 0 or not totals.mn then return "" end
    local mean = totals.sum / totals.n
    local variance = math.max(0, totals.sq / totals.n - mean * mean)
    local deviation = Threat(math.sqrt(variance))
    local text = Number(Threat(totals.mn)) .. " - " .. Number(Threat(totals.mx))
    if totals.n > 1 then text = text .. "  (sd " .. Number(deviation) .. ")" end
    return text
end

local function PerRage(totals)
    if totals.rn == 0 or totals.r <= 0 then return "-" end
    return string.format("%.1f", Average(totals) / (totals.r / totals.rn))
end

-- Threat per second of the global cooldown the ability takes (1.5 s unless measured otherwise).
local function PerSecond(value, row)
    if row.sets or row.swing then return "-" end
    if row.nma then return "on swing" end
    if row.gcd == 0 then return "off GCD" end
    return Number(value / (row.gcd or 1.5))
end

-- How much of the threat came from the damage itself; the rest is the ability's bonus threat.
local function FromDamage(totals)
    if totals.sets or totals.dn == 0 or totals.dt == 0 then return "-" end
    local threat = Threat(totals.dt) / totals.dn
    local damage = totals.dm / totals.dn
    if threat <= 0 then return "-" end
    return string.format("%d%% (+%s)", math.floor(damage / threat * 100 + 0.5), Number(threat - damage))
end

local function DiffLabel(difference)
    if difference == 99 then return "boss (??)" end
    if type(difference) ~= "number" then return "unknown" end
    if difference == 0 then return "same level" end
    if difference <= -5 then return "5+ below" end
    if difference >= 5 then return "5+ above" end
    return (difference > 0 and "+" or "") .. difference
end

local function LevelLabel(level)
    if level == 0 then return "?" end
    return level .. "-" .. (level + 4)
end

------------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------------

local function Filter() return ns.Lab.db.ui end
local function Method() return Filter().method == "clean" and "clean" or "fit" end

local function Dropdown(parent, label, width, options, get, set)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width + 60, 26)
    local text = UI.Label(frame, label, "GameFontHighlightSmall")
    text:SetPoint("LEFT", 0, 0)
    local dropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    dropdown:SetWidth(width)
    dropdown:SetPoint("LEFT", text, "RIGHT", 6, 0)
    dropdown:SetupMenu(function(_, root)
        for _, option in ipairs(options) do
            root:CreateRadio(option[2], function() return get() == option[1] end, function()
                set(option[1])
                LabUI:Refresh()
            end)
        end
    end)
    return frame
end

local function LevelStepper(parent, get, set)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(86, 22)
    local minus = UI.Button(frame, "-", 22, 20)
    minus:SetPoint("LEFT", 0, 0)
    local value = UI.Label(frame, "", "GameFontHighlight")
    value:SetWidth(32)
    value:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    local plus = UI.Button(frame, "+", 22, 20)
    plus:SetPoint("LEFT", value, "RIGHT", 2, 0)
    local function Show() value:SetText(get()) end
    local function Change(step)
        set(math.max(1, math.min(80, get() + step)))
        Show()
        LabUI:Refresh()
    end
    -- Shift-click: steps of 5.
    minus:SetScript("OnClick", function() Change(IsShiftKeyDown() and -5 or -1) end)
    plus:SetScript("OnClick", function() Change(IsShiftKeyDown() and 5 or 1) end)
    frame.Show_ = Show
    Show()
    return frame
end

local function CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(WIDTH - 44, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.04 or 0)
    row.selected = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.18)
    row.selected:Hide()
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.cells = {}
    for _, key in ipairs({ "name", "c1", "c2", "c3", "c4", "c5", "c6", "c7" }) do
        local cell = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        cell:SetWordWrap(false)
        row.cells[key] = cell
    end
    row:SetScript("OnClick", function(self)
        if self.id then
            LabUI.selected = self.id
            LabUI:Refresh()
        end
    end)
    row:Hide()
    return row
end

-- Puts the row's (or header's) cells where the method's columns are.
local function Layout(cells, method)
    for _, cell in pairs(cells) do cell:Hide() end
    for _, column in ipairs(COLUMNS[method]) do
        local cell = cells[column.key]
        cell:ClearAllPoints()
        cell:SetPoint("LEFT", column.x, 0)
        cell:SetWidth(column.w)
        cell:SetJustifyH(column.justify or "RIGHT")
        cell:Show()
    end
end

------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------

StaticPopupDialogs["ENMITYLIST_LAB_RESET"] = {
    text = "Delete every threat lab measurement for this character (both methods)?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        ns.Lab:Reset()
        LabUI.selected = nil
        LabUI:Refresh()
        print("|cffe08080EnmityList|r: threat lab data reset.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function LabUI:AskReset()
    StaticPopup_Show("ENMITYLIST_LAB_RESET")
end

function LabUI:Build()
    local frame = CreateFrame("Frame", "EnmityListLabFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    UI.Label(frame, "EnmityList: Threat lab"):SetPoint("TOP", 0, -5)
    tinsert(UISpecialFrames, "EnmityListLabFrame")
    self.frame = frame

    local left = 18
    -- Status: what the lab is doing, this session's counts and what wasn't used.
    frame.status = UI.Label(frame, "", "GameFontHighlight")
    frame.status:SetPoint("TOPLEFT", left, -32)
    frame.status:SetWidth(WIDTH - 36)
    frame.status:SetJustifyH("LEFT")
    frame.discards = UI.Help(frame, "", WIDTH - 36)
    frame.discards:SetPoint("TOPLEFT", frame.status, "BOTTOMLEFT", 0, -4)
    frame.info = UI.Help(frame, "", WIDTH - 36)
    frame.info:SetPoint("TOPLEFT", frame.discards, "BOTTOMLEFT", 0, -4)

    -- Filters.
    local method = Dropdown(frame, "Method", 130, METHODS,
        function() return Method() end, function(value)
            Filter().method = value
            self.selected = nil
        end)
    method:SetPoint("TOPLEFT", left, -104)
    local stance = Dropdown(frame, "Stance", 130, STANCES,
        function() return Filter().stance end, function(value) Filter().stance = value end)
    stance:SetPoint("LEFT", method, "RIGHT", 4, 0)
    local outcome = Dropdown(frame, "Outcome", 100, OUTCOMES,
        function() return Filter().outcome end, function(value) Filter().outcome = value end)
    outcome:SetPoint("LEFT", stance, "RIGHT", 4, 0)
    local levelLabel = UI.Label(frame, "Your level", "GameFontHighlightSmall")
    levelLabel:SetPoint("LEFT", outcome, "RIGHT", 4, 0)
    frame.lvMin = LevelStepper(frame, function() return Filter().lvMin end, function(value)
        Filter().lvMin = value
        if Filter().lvMax < value then Filter().lvMax = value end
    end)
    frame.lvMin:SetPoint("LEFT", levelLabel, "RIGHT", 6, 0)
    local to = UI.Label(frame, "to", "GameFontHighlightSmall")
    to:SetPoint("LEFT", frame.lvMin, "RIGHT", 4, 0)
    frame.lvMax = LevelStepper(frame, function() return Filter().lvMax end, function(value)
        Filter().lvMax = value
        if Filter().lvMin > value then Filter().lvMin = value end
    end)
    frame.lvMax:SetPoint("LEFT", to, "RIGHT", 4, 0)

    -- The fit's headline: threat per point of damage, and how many windows it's from.
    frame.headline = UI.Label(frame, "", "GameFontHighlight")
    frame.headline:SetPoint("TOPLEFT", left, -136)
    frame.headline:SetWidth(WIDTH - 36)
    frame.headline:SetJustifyH("LEFT")

    -- The table.
    local head = CreateFrame("Frame", nil, frame)
    head:SetSize(WIDTH - 44, 16)
    head:SetPoint("TOPLEFT", left + 4, -158)
    head.cells = {}
    for _, key in ipairs({ "name", "c1", "c2", "c3", "c4", "c5", "c6", "c7" }) do
        head.cells[key] = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    end
    self.head = head
    local line = head:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.35)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 0, -2)
    line:SetPoint("BOTTOMRIGHT", 0, -2)

    local body = CreateFrame("Frame", nil, frame)
    body:SetSize(WIDTH - 44, ROWS * ROW_HEIGHT)
    body:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
    body:EnableMouseWheel(true)
    body:SetScript("OnMouseWheel", function(_, delta)
        self.offset = math.max(0, math.min((self.count or 0) - ROWS, (self.offset or 0) - delta))
        self:Refresh()
    end)
    self.rows = {}
    for i = 1, ROWS do self.rows[i] = CreateRow(body, i) end
    frame.empty = UI.Help(body, "", WIDTH - 80)
    frame.empty:SetPoint("TOP", 0, -30)
    frame.empty:SetJustifyH("CENTER")
    frame.more = UI.Help(frame, "", 300)
    frame.more:SetPoint("TOPRIGHT", body, "BOTTOMRIGHT", 0, -2)
    frame.more:SetJustifyH("RIGHT")

    -- The breakdown of the ability clicked.
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -18)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 44)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(WIDTH - 90, 10)
    scroll:SetScrollChild(child)
    frame.detail = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.detail:SetPoint("TOPLEFT", 4, -4)
    frame.detail:SetWidth(WIDTH - 96)
    frame.detail:SetJustifyH("LEFT")
    frame.detail:SetJustifyV("TOP")
    frame.detail:SetSpacing(2)
    frame.detailChild = child
    local separator = frame:CreateTexture(nil, "ARTWORK")
    separator:SetColorTexture(1, 1, 1, 0.12)
    separator:SetHeight(1)
    separator:SetPoint("BOTTOMLEFT", scroll, "TOPLEFT", 0, 6)
    separator:SetPoint("BOTTOMRIGHT", scroll, "TOPRIGHT", 20, 6)

    -- Bottom: reset and the chat line switch.
    local reset = UI.Button(frame, "Reset data...", 120, 22)
    reset:SetPoint("BOTTOMLEFT", 16, 14)
    reset:SetScript("OnClick", function() self:AskReset() end)
    local verbose = UI.Checkbox(frame, "A chat line for each clean measurement",
        function() return ns.Lab.db.verbose end, function(value) ns.Lab.db.verbose = value and true or false end)
    verbose:SetPoint("LEFT", reset, "RIGHT", 16, 0)
    local tip = UI.Help(frame, "Play normally, auto-attack and all; pulling 2-3 mobs helps rage. "
        .. "Open world only: dungeons hide threat.", 330)
    tip:SetPoint("BOTTOMRIGHT", -18, 16)
    tip:SetJustifyH("RIGHT")

    -- Live status while open.
    local waited = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        waited = waited + elapsed
        if waited > 0.5 or (self.dirty and waited > 0.1) then
            waited = 0
            self.dirty = false
            self:Refresh()
        end
    end)
    ns.Lab.OnSample = function() self.dirty = true end
    frame:SetScript("OnShow", function() self:Refresh() end)
end

function LabUI:Toggle()
    if not ns.Lab.db then return end
    if not self.frame then
        self:Build()
        self.frame:Show()
        self:Refresh()
        return
    end
    self.frame:SetShown(not self.frame:IsShown())
end

------------------------------------------------------------------------------
-- Filling it
------------------------------------------------------------------------------

local REASON_SHORT = {
    noaction = "no action seen", several = "several actions", swing = "auto-attack swing",
    target = "target changed", stance = "stance changed", rage = "rage from elsewhere",
    healed = "healed", late = "update too late", extra = "other damage on target",
    dot = "DoT tick", dropped = "threat dropped", hidden = "hidden by the game", proc = "proc/DoT",
    group = "in a group (others' damage)", taunt = "taunt", long = "too long", outlier = "far off the fit",
    full = "too many abilities", size = "hit size hidden",
}

-- Since Forever 1.60.1.70938 the game hides how hard every hit lands (Lab.sizesHidden).
local SIZES_HIDDEN = "The game hides how hard every hit lands, in the open world too, so the fit learns only "
    .. "from misses and actions that deal no damage."

local function Reasons(counts)
    local list = {}
    for reason, count in pairs(counts) do list[#list + 1] = { reason, count } end
    table.sort(list, function(first, second) return first[2] > second[2] end)
    local parts = {}
    for _, entry in ipairs(list) do parts[#parts + 1] = (REASON_SHORT[entry[1]] or entry[1]) .. " " .. entry[2] end
    return table.concat(parts, ", ")
end

function LabUI:Status()
    local frame, Lab = self.frame, ns.Lab
    local state = Lab:State()
    local text
    if state == "hidden" then
        text = WARN .. "Paused:|r threat numbers are hidden here (dungeons): measure in the open world."
    elseif state == "idle" then
        text = DIM .. "Paused:|r not in combat."
    elseif state == "notarget" then
        text = DIM .. "Paused:|r no target."
    else
        text = GOOD .. "Measuring.|r"
    end
    local session = Lab.session
    text = text .. string.format("  This session: %d windows used for the fit, %d clean measurements.",
        session.fitUsed, session.samples)
    frame.status:SetText(text)

    local discards = {}
    local skipped = Reasons(session.fitSkipped)
    discards[#discards + 1] = skipped ~= "" and ("Left out of the fit: " .. skipped .. ".") or "Nothing left out of the fit."
    if session.discarded > 0 then
        discards[#discards + 1] = string.format("%d windows weren't clean enough for a clean measurement (%s).",
            session.discarded, Reasons(session.discards))
    end
    if Lab.sizesHidden then discards[#discards + 1] = SIZES_HIDDEN end
    if (session.fitSkipped.group or 0) > 0 then
        discards[#discards + 1] = "The fit needs you alone (no group, no pet): the game doesn't say whose damage is whose."
    elseif not Lab.sizesHidden then
        discards[#discards + 1] = "Play normally; pulling 2-3 mobs helps rage."
    end
    frame.discards:SetText(table.concat(discards, "  "))

    local scale, how = Lab:Scale()
    local info = {}
    if scale == 1 then
        info[1] = "Threat as the game reports it (" .. how .. ")."
    else
        info[1] = "Threat in game units: the game's raw value / 100 (" .. how .. ")."
    end
    if Lab.lag then info[#info + 1] = string.format("Update lag about %.2f s.", Lab.lag) end
    if Lab.defiance then
        local max = Lab.defianceMax
        info[#info + 1] = "Defiance " .. tostring(Lab.defiance) .. (max and ("/" .. max) or "") .. "."
    end
    info[#info + 1] = "Current stance: " .. (STANCE_NAMES[Lab.Stance()] or Lab.Stance()) .. "."
    if Lab.readsCombatLog then info[#info + 1] = "Using the combat log." end
    frame.info:SetText(table.concat(info, "  "))
end

-- Header cells for the method.
function LabUI:Header(method)
    Layout(self.head.cells, method)
    for _, column in ipairs(COLUMNS[method]) do self.head.cells[column.key]:SetText(column.label) end
end

-- Fills the visible rows from `list`: each entry { id, icon, cells = { name, c1 ... } }.
function LabUI:Fill(list, method)
    self.count = #list
    self.offset = math.max(0, math.min(self.offset or 0, #list - ROWS))
    for i, row in ipairs(self.rows) do
        local entry = list[i + self.offset]
        row.id = entry and entry.id
        if entry then
            Layout(row.cells, method)
            row.icon:SetTexture(entry.icon or 134400)
            for key, text in pairs(entry.cells) do row.cells[key]:SetText(text) end
            row.selected:SetShown(entry.id == self.selected)
            row:Show()
        else
            row:Hide()
        end
    end
    self.frame.more:SetText(#list > ROWS and string.format("%d-%d of %d (scroll for more)", self.offset + 1,
        math.min(#list, self.offset + ROWS), #list) or "")
end

local function NameCell(name, rank)
    return name .. (rank and (" " .. DIM .. rank .. "|r") or "")
end

function LabUI:CleanTable()
    local frame = self.frame
    local rows = ns.Lab:Rows(Filter())
    local list = {}
    for _, row in ipairs(rows) do
        local cells = { name = NameCell(row.name, row.rank), c1 = row.n }
        if row.sets then
            cells.c2, cells.c3 = WARN .. "sets threat|r", "-"
        else
            cells.c2, cells.c3 = Number(Average(row)), PerRage(row)
        end
        cells.c4 = PerSecond(Average(row), row)
        cells.c5 = FromDamage(row)
        cells.c6 = Spread(row)
        list[#list + 1] = { id = "clean:" .. row.name, name = row.name, icon = row.icon, cells = cells }
    end
    self:Fill(list, "clean")
    frame.headline:SetText(DIM .. "Clean samples: one ability alone between two threat updates. Exact, but rare "
        .. "in normal play.|r")
    if #list == 0 then
        frame.empty:SetText(next(ns.Lab.db.agg) and "No clean measurements match these filters."
            or "No clean measurements yet. They need one ability alone between two threat updates "
            -- With sizes hidden the fit skips landed swings too, so don't contrast the two.
            .. (ns.Lab.sizesHidden and "(no auto-attack swing in between)."
                or "(no auto-attack swing in between); the fit doesn't."))
        frame.empty:Show()
    else
        frame.empty:Hide()
    end
end

function LabUI:FitTable()
    local frame = self.frame
    local Lab = ns.Lab
    local view = Lab:FitView(Filter())
    self.view = view
    local list = {}
    local scale = Lab:Scale()
    for _, row in ipairs(view.rows or {}) do
        -- On other enemies, a single-target ability does nothing: those rows stay in the breakdown.
        local nothing = row.info.side and row.avgDmg == 0 and math.abs(row.bonus) <= 2 * (row.se or 0) + scale
        if not nothing then
            local cells = { name = NameCell(row.name, row.rank), c1 = row.uses }
            if not row.enough then
                cells.c2 = DIM .. "not enough data|r"
                cells.c3, cells.c4, cells.c5, cells.c6 = "", "", "", ""
            else
                local bonus = row.bonus / scale
                local total = row.total / scale
                -- Below zero can't be: shown as 0, marked when clearly below (the breakdown has the
                -- solved value).
                if bonus < 0 then
                    cells.c2 = (row.bonus < -2 * (row.se or 0)) and (BAD .. "0*|r") or "0"
                else
                    cells.c2 = Number(bonus)
                end
                cells.c3 = row.avgDmg > 0 and Number(row.fromDamage / scale) or "-"
                cells.c4 = Number(total)
                cells.c5 = (row.cost and row.cost > 0) and string.format("%.1f", total / row.cost) or "-"
                cells.c6 = PerSecond(total, row)
            end
            cells.c7 = string.format("±%s (%d)", Number((row.se or 0) / scale), row.seen)
            list[#list + 1] = { id = "fit:" .. row.key, icon = row.icon, cells = cells }
        end
    end
    self:Fill(list, "fit")

    local need = Lab.FIT.MIN_WINDOWS
    local where = (STANCE_NAMES[Filter().stance] or Filter().stance) .. ", your level "
        .. Filter().lvMin .. "-" .. Filter().lvMax
    if view.needStance then
        frame.headline:SetText(WARN .. "Pick one stance for the fit:|r each stance has its own threat multiplier.")
    elseif not view.sol then
        frame.headline:SetText(string.format("%sFit:|r %d of %d windows so far (%s).", WARN, view.n, need, where))
    else
        local perDamage = view.m and view.m / scale
        local text
        if not perDamage and Lab.sizesHidden then
            -- No damage in any window, so nothing to multiply: each row is the ability's whole threat.
            text = string.format("%sFit:|r each ability's whole threat per use (the game hides damage), from %d "
                .. "windows (%s).", GOOD, view.n, where)
        else
            text = string.format("%sFit:|r threat = damage x %s%s plus each ability's bonus, from %d windows (%s).",
                GOOD, perDamage and string.format("%.2f", perDamage) or "?",
                view.mSe and string.format(" (±%.2f)", view.mSe / scale) or "", view.n, where)
        end
        if view.rage and math.abs(view.rage) > 0 then
            text = text .. string.format("  Rage gained: %s each.", Number(view.rage / scale))
        end
        frame.headline:SetText(text)
    end
    if #list == 0 then
        if view.needStance then
            frame.empty:SetText("Each stance multiplies threat differently, so the fit is per stance.")
        elseif Lab.sizesHidden then
            frame.empty:SetText(string.format("Not enough windows yet for the fit (%d of %d). The game hides how "
                .. "hard every hit lands, in the open world too, so only threat updates without a landed hit "
                .. "count: misses, Sunder Armor, shouts. It fills slowly, and an ability that deals damage shows up "
                .. "only when it misses. Clean samples still measure its whole threat per use.", view.n, need))
        else
            frame.empty:SetText(string.format("Not enough windows yet for the fit (%d of %d). Play normally in "
                .. "the open world, alone: every threat update counts.", view.n, need))
        end
        frame.empty:Show()
    else
        frame.empty:Hide()
    end
end

local function Group(list, Label)
    local parts = {}
    for _, totals in ipairs(list) do
        parts[#parts + 1] = string.format("%s %s%dx|r avg %s", Label(totals.key), DIM, totals.n, Number(Average(totals)))
    end
    return table.concat(parts, "   ")
end

-- The clean samples' breakdown of an ability (by name), as lines.
function LabUI:CleanDetail(name, lines)
    local Lab = ns.Lab
    local breakdown = Lab:Breakdown(name, Filter())
    local total = 0
    for _, totals in ipairs(breakdown.outcome) do total = total + totals.n end
    lines[#lines + 1] = WARN .. name .. "|r  " .. total .. " clean measurements with these filters"
    if breakdown.rank[1] then lines[#lines + 1] = "Rank:   " .. Group(breakdown.rank, tostring) end
    if breakdown.level[1] then lines[#lines + 1] = "Your level:   " .. Group(breakdown.level, LevelLabel) end
    if breakdown.diff[1] then lines[#lines + 1] = "Enemy's level:   " .. Group(breakdown.diff, DiffLabel) end
    if breakdown.outcome[1] then
        lines[#lines + 1] = "Outcome:   " .. Group(breakdown.outcome, function(key) return OUTCOME_NAMES[key] or key end)
    end
    if breakdown.stance[1] then
        lines[#lines + 1] = "Stance (all):   " .. Group(breakdown.stance, function(key) return STANCE_NAMES[key] or key end)
    end
    if #breakdown.recent == 0 then return end
    lines[#lines + 1] = " "
    lines[#lines + 1] = WARN .. "Latest clean measurements|r (every stance and outcome)"
    local scale = Lab:Scale()
    for i, recent in ipairs(breakdown.recent) do
        if i > 20 then break end
        local sample, meta = recent.sample, Lab.db.spells[recent.id] or {}
        local when = date and sample.at and date("%d %b %H:%M", sample.at) or ""
        local mob = sample.mob and (sample.mob .. " ") or ""
        local versus = sample.ml and (sample.ml < 0 and "??" or sample.ml) or "?"
        lines[#lines + 1] = string.format("%s%s|r  %s  %s  %s%s|r%s%s  you %s vs %s%s (%s)  %s, %s%s",
            DIM, when, meta.rank or "", OUTCOME_NAMES[sample.o] or sample.o,
            sample.th >= 0 and GOOD or BAD, Signed(sample.th / scale),
            sample.dmg and ("  " .. sample.dmg .. " dmg") or "",
            sample.r and ("  " .. sample.r .. " rage") or "",
            sample.lv or "?", mob, versus, sample.c or "?",
            STANCE_NAMES[sample.st] or sample.st or "?", TANK[sample.tk] or "?",
            sample.z and (", " .. sample.z) or "")
    end
end

-- The fit's numbers for one of its rows, then that ability's other variants and clean samples.
function LabUI:FitDetail(key, lines)
    local view, scale = self.view, ns.Lab:Scale()
    local row
    for _, candidate in ipairs(view and view.rows or {}) do
        if candidate.key == key then row = candidate end
    end
    if not row then return end
    lines[#lines + 1] = WARN .. row.name .. (row.rank and (" (" .. row.rank .. ")") or "") .. "|r"
    lines[#lines + 1] = string.format("Bonus threat: %s ± %s (solved %s), in %d windows; %d uses.",
        Number(math.max(0, row.bonus) / scale), Number((row.se or 0) / scale), Number(row.bonus / scale), row.seen, row.uses)
    if row.bonus < -2 * (row.se or 0) then
        lines[#lines + 1] = BAD .. "Solved below 0, which can't be: shown as 0. More windows (or a fresh "
            .. "start with Reset) should settle it.|r"
    end
    if row.avgDmg > 0 and view.m then
        lines[#lines + 1] = string.format("Average damage per use %s, times %.2f = %s threat from damage.",
            Number(row.avgDmg), view.m / scale, Number(row.fromDamage / scale))
    end
    lines[#lines + 1] = string.format("Per use: %s threat%s.", Number(row.total / scale),
        row.cost and string.format(" for %s rage", Number(row.cost)) or "")
    if not row.enough then
        lines[#lines + 1] = DIM .. "Not enough data yet: it needs to appear in " .. ns.Lab.FIT.MIN_SEEN
            .. " windows.|r"
    end
    -- The same ability's other variants.
    local others = {}
    for _, other in ipairs(view.rows) do
        if other ~= row and other.info.spell and other.info.spell == row.info.spell then
            others[#others + 1] = string.format("%s: %s ± %s (%d)", other.name, Number(other.bonus / scale),
                Number((other.se or 0) / scale), other.seen)
        end
    end
    if #others > 0 then lines[#lines + 1] = "Also:   " .. table.concat(others, "   ") end
    if row.info.spell then
        lines[#lines + 1] = " "
        local meta = ns.Lab.db.spells[row.info.spell]
        if meta and meta.name then self:CleanDetail(meta.name, lines) end
    end
end

function LabUI:Detail()
    local frame = self.frame
    local selected = self.selected
    local lines = {}
    if selected and selected:match("^fit:") then
        self:FitDetail(selected:sub(5), lines)
    elseif selected and selected:match("^clean:") then
        self:CleanDetail(selected:sub(7), lines)
    end
    if #lines == 0 then
        lines[1] = DIM .. "Click an ability for its breakdown"
            .. (Method() == "fit" and ": the fit's numbers, and its clean measurements if any.|r"
                or " by rank, level and level difference, and its latest measurements.|r")
    end
    frame.detail:SetText(table.concat(lines, "\n"))
    frame.detailChild:SetHeight(frame.detail:GetStringHeight() + 8)
end

function LabUI:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    local frame = self.frame
    self:Status()
    frame.lvMin.Show_()
    frame.lvMax.Show_()
    local method = Method()
    self:Header(method)
    if method == "fit" then self:FitTable() else self:CleanTable() end
    self:Detail()
end

------------------------------------------------------------------------------
-- /enmity lab [reset | verbose | units auto/1/100]
------------------------------------------------------------------------------

function LabUI.Command(args)
    local Lab = ns.Lab
    local command, rest = (args or ""):match("^(%S*)%s*(.-)$")
    command = (command or ""):lower()
    if not Lab.db then return end
    if command == "" then
        LabUI:Toggle()
    elseif command == "reset" then
        LabUI:AskReset()
    elseif command == "verbose" then
        Lab.db.verbose = not Lab.db.verbose
        print("|cffe08080EnmityList|r: threat lab chat lines " .. (Lab.db.verbose and "on." or "off."))
        LabUI:Refresh()
    elseif command == "units" then
        local units = (rest or ""):lower()
        if units == "1" or units == "100" then
            Lab.db.units = tonumber(units)
        else
            Lab.db.units = "auto"
        end
        local scale, how = Lab:Scale()
        print(string.format("|cffe08080EnmityList|r: threat lab shows the game's raw threat / %d (%s).", scale, how))
        LabUI:Refresh()
    else
        print("|cffe08080EnmityList|r: /enmity lab (the window), /enmity lab reset, /enmity lab verbose, "
            .. "/enmity lab units auto, 1 or 100")
    end
end
