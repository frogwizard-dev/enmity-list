local _, ns = ...
local UI = ns.UI

-- The threat lab's window (/enmity lab): your abilities' threat by either method (the fit from
-- normal play, or clean samples), with filters, a breakdown of the one you click, and what the
-- lab is doing right now. Measuring and solving are Lab.lua's.

local LabUI = {}
ns.LabUI = LabUI

local WIDTH, HEIGHT = 840, 620
local ROWS, ROW_H = 10, 22
local GOOD, WARN, DIM, BAD = "|cff70e070", "|cffffd100", "|cff9d9d9d", "|cffff6060"

local STANCES = {
    { "def", "Defensive Stance" }, { "battle", "Battle Stance" }, { "bers", "Berserker Stance" },
    { "bear", "Bear Form" }, { "cat", "Cat Form" }, { "none", "No stance" }, { "any", "All stances" },
}
local STANCE_NAMES = {}
for _, s in ipairs(STANCES) do STANCE_NAMES[s[1]] = s[2] end
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

local function Num(n)
    local a = math.abs(n)
    if a >= 1000000 then return string.format("%.1fm", n / 1000000) end
    if a >= 10000 then return string.format("%.1fk", n / 1000) end
    if a < 10 and a ~= math.floor(a) then return string.format("%.1f", n) end
    return tostring(math.floor(n + 0.5))
end

local function Signed(n)
    return (n > 0 and "+" or "") .. Num(n)
end

-- Threat in the game's units (raw / scale).
local function Threat(raw)
    local scale = ns.Lab:Scale()
    return raw / scale
end

local function Avg(t) return t.n > 0 and Threat(t.sum) / t.n or 0 end

local function Spread(t)
    if t.n == 0 or not t.mn then return "" end
    local mean = t.sum / t.n
    local var = math.max(0, t.sq / t.n - mean * mean)
    local sd = Threat(math.sqrt(var))
    local s = Num(Threat(t.mn)) .. " - " .. Num(Threat(t.mx))
    if t.n > 1 then s = s .. "  (sd " .. Num(sd) .. ")" end
    return s
end

local function PerRage(t)
    if t.rn == 0 or t.r <= 0 then return "-" end
    return string.format("%.1f", Avg(t) / (t.r / t.rn))
end

-- Threat per second of the global cooldown the ability takes (1.5 s unless measured otherwise).
local function PerSecond(value, row)
    if row.sets or row.swing then return "-" end
    if row.nma then return "on swing" end
    if row.gcd == 0 then return "off GCD" end
    return Num(value / (row.gcd or 1.5))
end

-- How much of the threat came from the damage itself; the rest is the ability's bonus threat.
local function FromDamage(t)
    if t.sets or t.dn == 0 or t.dt == 0 then return "-" end
    local threat = Threat(t.dt) / t.dn
    local damage = t.dm / t.dn
    if threat <= 0 then return "-" end
    return string.format("%d%% (+%s)", math.floor(damage / threat * 100 + 0.5), Num(threat - damage))
end

local function DiffLabel(d)
    if d == 99 then return "boss (??)" end
    if type(d) ~= "number" then return "unknown" end
    if d == 0 then return "same level" end
    if d <= -5 then return "5+ below" end
    if d >= 5 then return "5+ above" end
    return (d > 0 and "+" or "") .. d
end

local function LevelLabel(lv)
    if lv == 0 then return "?" end
    return lv .. "-" .. (lv + 4)
end

------------------------------------------------------------------------------
-- Controls
------------------------------------------------------------------------------

local function Filter() return ns.Lab.db.ui end
local function Method() return Filter().method == "clean" and "clean" or "fit" end

local function Dropdown(parent, label, width, options, get, set)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width + 60, 26)
    local text = UI.Label(f, label, "GameFontHighlightSmall")
    text:SetPoint("LEFT", 0, 0)
    local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    dd:SetWidth(width)
    dd:SetPoint("LEFT", text, "RIGHT", 6, 0)
    dd:SetupMenu(function(_, root)
        for _, o in ipairs(options) do
            root:CreateRadio(o[2], function() return get() == o[1] end, function()
                set(o[1])
                LabUI:Refresh()
            end)
        end
    end)
    f.dd = dd
    return f
end

local function LevelStepper(parent, get, set)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(86, 22)
    local minus = UI.Button(f, "-", 22, 20)
    minus:SetPoint("LEFT", 0, 0)
    local val = UI.Label(f, "", "GameFontHighlight")
    val:SetWidth(32)
    val:SetPoint("LEFT", minus, "RIGHT", 2, 0)
    local plus = UI.Button(f, "+", 22, 20)
    plus:SetPoint("LEFT", val, "RIGHT", 2, 0)
    local function show() val:SetText(get()) end
    local function change(d)
        set(math.max(1, math.min(80, get() + d)))
        show()
        LabUI:Refresh()
    end
    -- Shift-click: steps of 5.
    minus:SetScript("OnClick", function() change(IsShiftKeyDown() and -5 or -1) end)
    plus:SetScript("OnClick", function() change(IsShiftKeyDown() and 5 or 1) end)
    f.Show_ = show
    show()
    return f
end

local function CreateRow(parent, i)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(WIDTH - 44, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r.stripe = r:CreateTexture(nil, "BACKGROUND")
    r.stripe:SetAllPoints()
    r.stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)
    r.selected = r:CreateTexture(nil, "BACKGROUND", nil, 1)
    r.selected:SetAllPoints()
    r.selected:SetColorTexture(1, 0.82, 0, 0.18)
    r.selected:Hide()
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 4, ROW_H - 4)
    r.icon:SetPoint("LEFT", 4, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    r.cells = {}
    for _, key in ipairs({ "name", "c1", "c2", "c3", "c4", "c5", "c6", "c7" }) do
        local fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetWordWrap(false)
        r.cells[key] = fs
    end
    r:SetScript("OnClick", function(self)
        if self.id then
            LabUI.selected = self.id
            LabUI:Refresh()
        end
    end)
    r:Hide()
    return r
end

-- Puts the row's (or header's) cells where the method's columns are.
local function Layout(cells, method)
    for _, fs in pairs(cells) do fs:Hide() end
    for _, c in ipairs(COLUMNS[method]) do
        local fs = cells[c.key]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", c.x, 0)
        fs:SetWidth(c.w)
        fs:SetJustifyH(c.justify or "RIGHT")
        fs:Show()
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
    local f = CreateFrame("Frame", "EnmityListLabFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    UI.Label(f, "EnmityList - Threat lab"):SetPoint("TOP", 0, -5)
    tinsert(UISpecialFrames, "EnmityListLabFrame")
    self.frame = f

    local left = 18
    -- Status: what the lab is doing, this session's counts and what wasn't used.
    f.status = UI.Label(f, "", "GameFontHighlight")
    f.status:SetPoint("TOPLEFT", left, -32)
    f.status:SetWidth(WIDTH - 36)
    f.status:SetJustifyH("LEFT")
    f.discards = UI.Help(f, "", WIDTH - 36)
    f.discards:SetPoint("TOPLEFT", f.status, "BOTTOMLEFT", 0, -4)
    f.info = UI.Help(f, "", WIDTH - 36)
    f.info:SetPoint("TOPLEFT", f.discards, "BOTTOMLEFT", 0, -4)

    -- Filters.
    local method = Dropdown(f, "Method", 130, METHODS,
        function() return Method() end, function(v)
            Filter().method = v
            self.selected = nil
        end)
    method:SetPoint("TOPLEFT", left, -104)
    local stance = Dropdown(f, "Stance", 130, STANCES,
        function() return Filter().stance end, function(v) Filter().stance = v end)
    stance:SetPoint("LEFT", method, "RIGHT", 4, 0)
    local outcome = Dropdown(f, "Outcome", 100, OUTCOMES,
        function() return Filter().outcome end, function(v) Filter().outcome = v end)
    outcome:SetPoint("LEFT", stance, "RIGHT", 4, 0)
    local lvLabel = UI.Label(f, "Your level", "GameFontHighlightSmall")
    lvLabel:SetPoint("LEFT", outcome, "RIGHT", 4, 0)
    f.lvMin = LevelStepper(f, function() return Filter().lvMin end, function(v)
        Filter().lvMin = v
        if Filter().lvMax < v then Filter().lvMax = v end
    end)
    f.lvMin:SetPoint("LEFT", lvLabel, "RIGHT", 6, 0)
    local to = UI.Label(f, "to", "GameFontHighlightSmall")
    to:SetPoint("LEFT", f.lvMin, "RIGHT", 4, 0)
    f.lvMax = LevelStepper(f, function() return Filter().lvMax end, function(v)
        Filter().lvMax = v
        if Filter().lvMin > v then Filter().lvMin = v end
    end)
    f.lvMax:SetPoint("LEFT", to, "RIGHT", 4, 0)

    -- The fit's headline: threat per point of damage, and how many windows it's from.
    f.headline = UI.Label(f, "", "GameFontHighlight")
    f.headline:SetPoint("TOPLEFT", left, -136)
    f.headline:SetWidth(WIDTH - 36)
    f.headline:SetJustifyH("LEFT")

    -- The table.
    local head = CreateFrame("Frame", nil, f)
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

    local body = CreateFrame("Frame", nil, f)
    body:SetSize(WIDTH - 44, ROWS * ROW_H)
    body:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
    body:EnableMouseWheel(true)
    body:SetScript("OnMouseWheel", function(_, delta)
        self.offset = math.max(0, math.min((self.count or 0) - ROWS, (self.offset or 0) - delta))
        self:Refresh()
    end)
    self.rows = {}
    for i = 1, ROWS do self.rows[i] = CreateRow(body, i) end
    f.empty = UI.Help(body, "", WIDTH - 80)
    f.empty:SetPoint("TOP", 0, -30)
    f.empty:SetJustifyH("CENTER")
    f.more = UI.Help(f, "", 300)
    f.more:SetPoint("TOPRIGHT", body, "BOTTOMRIGHT", 0, -2)
    f.more:SetJustifyH("RIGHT")

    -- The breakdown of the ability clicked.
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", body, "BOTTOMLEFT", 0, -18)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -36, 44)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(WIDTH - 90, 10)
    scroll:SetScrollChild(child)
    f.detail = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.detail:SetPoint("TOPLEFT", 4, -4)
    f.detail:SetWidth(WIDTH - 96)
    f.detail:SetJustifyH("LEFT")
    f.detail:SetJustifyV("TOP")
    f.detail:SetSpacing(2)
    f.detailChild = child
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.12)
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", scroll, "TOPLEFT", 0, 6)
    sep:SetPoint("BOTTOMRIGHT", scroll, "TOPRIGHT", 20, 6)

    -- Bottom: reset and the chat line switch.
    local reset = UI.Button(f, "Reset data...", 120, 22)
    reset:SetPoint("BOTTOMLEFT", 16, 14)
    reset:SetScript("OnClick", function() self:AskReset() end)
    local verbose = UI.Checkbox(f, "A chat line for each clean measurement",
        function() return ns.Lab.db.verbose end, function(v) ns.Lab.db.verbose = v and true or false end)
    verbose:SetPoint("LEFT", reset, "RIGHT", 16, 0)
    local tip = UI.Help(f, "Play normally, auto-attack and all; pulling 2-3 mobs helps rage. "
        .. "Open world only: dungeons hide threat.", 330)
    tip:SetPoint("BOTTOMRIGHT", -18, 16)
    tip:SetJustifyH("RIGHT")

    -- Live status while open.
    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed > 0.5 or (self.dirty and elapsed > 0.1) then
            elapsed = 0
            self.dirty = false
            self:Refresh()
        end
    end)
    ns.Lab.OnSample = function() self.dirty = true end
    f:SetScript("OnShow", function() self:Refresh() end)
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
    full = "too many abilities",
}

local function Reasons(counts)
    local list = {}
    for reason, n in pairs(counts) do list[#list + 1] = { reason, n } end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local parts = {}
    for _, r in ipairs(list) do parts[#parts + 1] = (REASON_SHORT[r[1]] or r[1]) .. " " .. r[2] end
    return table.concat(parts, ", ")
end

function LabUI:Status()
    local f, Lab = self.frame, ns.Lab
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
    local s = Lab.session
    text = text .. string.format("  This session: %d windows used for the fit, %d clean measurements.",
        s.fitUsed, s.samples)
    f.status:SetText(text)

    local d = {}
    local skipped = Reasons(s.fitSkipped)
    d[#d + 1] = skipped ~= "" and ("Left out of the fit: " .. skipped .. ".") or "Nothing left out of the fit."
    if s.discarded > 0 then
        d[#d + 1] = string.format("%d windows weren't clean enough for a clean measurement (%s).",
            s.discarded, Reasons(s.discards))
    end
    if (s.fitSkipped.group or 0) > 0 then
        d[#d + 1] = "The fit needs you alone (no group, no pet): the game doesn't say whose damage is whose."
    else
        d[#d + 1] = "Play normally; pulling 2-3 mobs helps rage."
    end
    f.discards:SetText(table.concat(d, "  "))

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
    if Lab.cleu then info[#info + 1] = "Using the combat log." end
    f.info:SetText(table.concat(info, "  "))
end

-- Header cells for the method.
function LabUI:Header(method)
    Layout(self.head.cells, method)
    for _, c in ipairs(COLUMNS[method]) do self.head.cells[c.key]:SetText(c.label) end
end

-- Fills the visible rows from `list`: each entry { id, icon, cells = { name, c1 ... } }.
function LabUI:Fill(list, method)
    self.count = #list
    self.offset = math.max(0, math.min(self.offset or 0, #list - ROWS))
    for i, r in ipairs(self.rows) do
        local e = list[i + self.offset]
        r.id = e and e.id
        if e then
            Layout(r.cells, method)
            r.icon:SetTexture(e.icon or 134400)
            for k, v in pairs(e.cells) do r.cells[k]:SetText(v) end
            r.selected:SetShown(e.id == self.selected)
            r:Show()
        else
            r:Hide()
        end
    end
    local f = self.frame
    f.more:SetText(#list > ROWS and string.format("%d-%d of %d (scroll for more)", self.offset + 1,
        math.min(#list, self.offset + ROWS), #list) or "")
end

local function NameCell(name, rank)
    return name .. (rank and (" " .. DIM .. rank .. "|r") or "")
end

function LabUI:CleanTable()
    local f = self.frame
    local rows = ns.Lab:Rows(Filter())
    local list = {}
    for _, row in ipairs(rows) do
        local cells = { name = NameCell(row.name, row.rank), c1 = row.n }
        if row.sets then
            cells.c2, cells.c3 = WARN .. "sets threat|r", "-"
        else
            cells.c2, cells.c3 = Num(Avg(row)), PerRage(row)
        end
        cells.c4 = PerSecond(Avg(row), row)
        cells.c5 = FromDamage(row)
        cells.c6 = Spread(row)
        list[#list + 1] = { id = "clean:" .. row.name, name = row.name, icon = row.icon, cells = cells }
    end
    self:Fill(list, "clean")
    f.headline:SetText(DIM .. "Clean samples: one ability alone between two threat updates. Exact, but rare "
        .. "in normal play.|r")
    if #list == 0 then
        f.empty:SetText(next(ns.Lab.db.agg) and "No clean measurements match these filters."
            or "No clean measurements yet. They need one ability alone between two threat updates "
            .. "(no auto-attack swing in between); the fit doesn't.")
        f.empty:Show()
    else
        f.empty:Hide()
    end
end

function LabUI:FitTable()
    local f = self.frame
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
                    cells.c2 = Num(bonus)
                end
                cells.c3 = row.avgDmg > 0 and Num(row.fromDamage / scale) or "-"
                cells.c4 = Num(total)
                cells.c5 = (row.cost and row.cost > 0) and string.format("%.1f", total / row.cost) or "-"
                cells.c6 = PerSecond(total, row)
            end
            cells.c7 = string.format("±%s (%d)", Num((row.se or 0) / scale), row.seen)
            list[#list + 1] = { id = "fit:" .. row.key, icon = row.icon, cells = cells }
        end
    end
    self:Fill(list, "fit")

    local need = Lab.FIT.MIN_WINDOWS
    local where = (STANCE_NAMES[Filter().stance] or Filter().stance) .. ", your level "
        .. Filter().lvMin .. "-" .. Filter().lvMax
    if view.needStance then
        f.headline:SetText(WARN .. "Pick one stance for the fit:|r each stance has its own threat multiplier.")
    elseif not view.sol then
        f.headline:SetText(string.format("%sFit:|r %d of %d windows so far (%s).", WARN, view.n, need, where))
    else
        local m = view.m and view.m / scale
        local text = string.format("%sFit:|r threat = damage x %s%s plus each ability's bonus, from %d windows (%s).",
            GOOD, m and string.format("%.2f", m) or "?",
            view.mSe and string.format(" (±%.2f)", view.mSe / scale) or "", view.n, where)
        if view.rage and math.abs(view.rage) > 0 then
            text = text .. string.format("  Rage gained: %s each.", Num(view.rage / scale))
        end
        f.headline:SetText(text)
    end
    if #list == 0 then
        if view.needStance then
            f.empty:SetText("Each stance multiplies threat differently, so the fit is per stance.")
        else
            f.empty:SetText(string.format("Not enough windows yet for the fit (%d of %d). Play normally in "
                .. "the open world, alone: every threat update counts.", view.n, need))
        end
        f.empty:Show()
    else
        f.empty:Hide()
    end
end

local function Group(list, label)
    local parts = {}
    for _, t in ipairs(list) do
        parts[#parts + 1] = string.format("%s %s%dx|r avg %s", label(t.key), DIM, t.n, Num(Avg(t)))
    end
    return table.concat(parts, "   ")
end

-- The clean samples' breakdown of an ability (by name), as lines.
function LabUI:CleanDetail(name, lines)
    local Lab = ns.Lab
    local b = Lab:Breakdown(name, Filter())
    local total = 0
    for _, t in ipairs(b.outcome) do total = total + t.n end
    lines[#lines + 1] = WARN .. name .. "|r  " .. total .. " clean measurements with these filters"
    if b.rank[1] then lines[#lines + 1] = "Rank:   " .. Group(b.rank, tostring) end
    if b.level[1] then lines[#lines + 1] = "Your level:   " .. Group(b.level, LevelLabel) end
    if b.diff[1] then lines[#lines + 1] = "Enemy's level:   " .. Group(b.diff, DiffLabel) end
    if b.outcome[1] then
        lines[#lines + 1] = "Outcome:   " .. Group(b.outcome, function(k) return OUTCOME_NAMES[k] or k end)
    end
    if b.stance[1] then
        lines[#lines + 1] = "Stance (all):   " .. Group(b.stance, function(k) return STANCE_NAMES[k] or k end)
    end
    if #b.recent == 0 then return end
    lines[#lines + 1] = " "
    lines[#lines + 1] = WARN .. "Latest clean measurements|r (every stance and outcome)"
    local scale = Lab:Scale()
    for i, r in ipairs(b.recent) do
        if i > 20 then break end
        local s, meta = r.s, Lab.db.spells[r.id] or {}
        local when = date and s.at and date("%d %b %H:%M", s.at) or ""
        local mob = s.mob and (s.mob .. " ") or ""
        local vs = s.ml and (s.ml < 0 and "??" or s.ml) or "?"
        lines[#lines + 1] = string.format("%s%s|r  %s  %s  %s%s|r%s%s  you %s vs %s%s (%s)  %s, %s%s",
            DIM, when, meta.rank or "", OUTCOME_NAMES[s.o] or s.o,
            s.th >= 0 and GOOD or BAD, Signed(s.th / scale),
            s.dmg and ("  " .. s.dmg .. " dmg") or "",
            s.r and ("  " .. s.r .. " rage") or "",
            s.lv or "?", mob, vs, s.c or "?",
            STANCE_NAMES[s.st] or s.st or "?", TANK[s.tk] or "?",
            s.z and (", " .. s.z) or "")
    end
end

-- The fit's numbers for one of its rows, then that ability's other variants and clean samples.
function LabUI:FitDetail(key, lines)
    local view, scale = self.view, ns.Lab:Scale()
    local row
    for _, r in ipairs(view and view.rows or {}) do
        if r.key == key then row = r end
    end
    if not row then return end
    lines[#lines + 1] = WARN .. row.name .. (row.rank and (" (" .. row.rank .. ")") or "") .. "|r"
    lines[#lines + 1] = string.format("Bonus threat: %s ± %s (solved %s), in %d windows; %d uses.",
        Num(math.max(0, row.bonus) / scale), Num((row.se or 0) / scale), Num(row.bonus / scale), row.seen, row.uses)
    if row.bonus < -2 * (row.se or 0) then
        lines[#lines + 1] = BAD .. "Solved below 0, which can't be: shown as 0. More windows (or a fresh "
            .. "start with Reset) should settle it.|r"
    end
    if row.avgDmg > 0 and view.m then
        lines[#lines + 1] = string.format("Average damage per use %s, times %.2f = %s threat from damage.",
            Num(row.avgDmg), view.m / scale, Num(row.fromDamage / scale))
    end
    lines[#lines + 1] = string.format("Per use: %s threat%s.", Num(row.total / scale),
        row.cost and string.format(" for %s rage", Num(row.cost)) or "")
    if not row.enough then
        lines[#lines + 1] = DIM .. "Not enough data yet: it needs to appear in " .. ns.Lab.FIT.MIN_SEEN
            .. " windows.|r"
    end
    -- The same ability's other variants.
    local others = {}
    for _, r in ipairs(view.rows) do
        if r ~= row and r.info.spell and r.info.spell == row.info.spell then
            others[#others + 1] = string.format("%s: %s ± %s (%d)", r.name, Num(r.bonus / scale),
                Num((r.se or 0) / scale), r.seen)
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
    local f = self.frame
    local sel = self.selected
    local lines = {}
    if sel and sel:match("^fit:") then
        self:FitDetail(sel:sub(5), lines)
    elseif sel and sel:match("^clean:") then
        self:CleanDetail(sel:sub(7), lines)
    end
    if #lines == 0 then
        lines[1] = DIM .. "Click an ability for its breakdown"
            .. (Method() == "fit" and ": the fit's numbers, and its clean measurements if any.|r"
                or " by rank, level and level difference, and its latest measurements.|r")
    end
    f.detail:SetText(table.concat(lines, "\n"))
    f.detailChild:SetHeight(f.detail:GetStringHeight() + 8)
end

function LabUI:Refresh()
    if not (self.frame and self.frame:IsShown()) then return end
    local f = self.frame
    self:Status()
    f.lvMin.Show_()
    f.lvMax.Show_()
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
    local cmd, rest = (args or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not Lab.db then return end
    if cmd == "" then
        LabUI:Toggle()
    elseif cmd == "reset" then
        LabUI:AskReset()
    elseif cmd == "verbose" then
        Lab.db.verbose = not Lab.db.verbose
        print("|cffe08080EnmityList|r: threat lab chat lines " .. (Lab.db.verbose and "on." or "off."))
        LabUI:Refresh()
    elseif cmd == "units" then
        local v = (rest or ""):lower()
        if v == "1" or v == "100" then
            Lab.db.units = tonumber(v)
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
