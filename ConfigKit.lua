local _, ns = ...

-- Settings controls shared by the XIV addons (copied into each; no addon depends on another).
-- Every control calls ns.Refresh() after a change.
local UI = {}
ns.UI = UI

function UI.Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetText(text)
    return fs
end

function UI.Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

function UI.Checkbox(parent, text, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    UI.Label(cb, text, "GameFontHighlight"):SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb:SetChecked(get())
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked())
        ns.Refresh()
    end)
    return cb
end

function UI.Stepper(parent, text, min, max, step, get, set, fmt)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(300, 24)
    UI.Label(f, text, "GameFontHighlight"):SetPoint("LEFT", 4, 0)
    local minus = UI.Button(f, "-", 24)
    minus:SetPoint("LEFT", 150, 0)
    local val = UI.Label(f, "", "GameFontHighlight")
    val:SetWidth(44)
    val:SetPoint("LEFT", minus, "RIGHT", 4, 0)
    local plus = UI.Button(f, "+", 24)
    plus:SetPoint("LEFT", val, "RIGHT", 4, 0)
    local function refresh() val:SetText(fmt and string.format(fmt, get()) or get()) end
    local function change(d)
        local v = math.max(min, math.min(max, get() + d))
        set(math.floor(v / step + 0.5) * step)
        refresh()
        ns.Refresh()
    end
    minus:SetScript("OnClick", function() change(-step) end)
    plus:SetScript("OnClick", function() change(step) end)
    f:SetScript("OnShow", refresh)
    refresh()
    return f
end

-- groups() returns { { title = "...", items = { { name = , path = } } } }
function UI.Dropdown(parent, text, groups, get, set)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(380, 26)
    UI.Label(f, text, "GameFontHighlight"):SetPoint("LEFT", 4, 0)
    local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    dd:SetWidth(210)
    dd:SetPoint("LEFT", 150, 0)
    dd:SetupMenu(function(_, root)
        local all, count = groups(), 0
        for _, group in ipairs(all) do count = count + #group.items end
        if count > 20 then root:SetScrollMode(20 * 20) end
        for _, group in ipairs(all) do
            if group.title then root:CreateTitle(group.title) end
            for _, item in ipairs(group.items) do
                root:CreateRadio(item.name, function() return get() == item.path end, function()
                    set(item.path)
                    ns.Refresh()
                end)
            end
        end
    end)
    return f
end

function UI.Options(...)
    local items = {}
    for i = 1, select("#", ...), 2 do
        local path, name = select(i, ...)
        items[#items + 1] = { path = path, name = name }
    end
    local groups = { { items = items } }
    return function() return groups end
end

UI.OUTLINES = UI.Options("", "None", "OUTLINE", "Outline", "THICKOUTLINE", "Thick outline")

function UI.ColorSwatch(parent, text, get, set)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(300, 24)
    UI.Label(f, text, "GameFontHighlight"):SetPoint("LEFT", 4, 0)
    local sw = CreateFrame("Button", nil, f, "BackdropTemplate")
    sw:SetSize(40, 18)
    sw:SetPoint("LEFT", 150, 0)
    sw:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    sw:SetBackdropBorderColor(1, 1, 1, 0.6)
    local function refresh()
        local c = get()
        sw:SetBackdropColor(c.r, c.g, c.b, 1)
    end
    local function apply(r, g, b)
        set(r, g, b)
        refresh()
        ns.Refresh()
    end
    sw:SetScript("OnClick", function()
        local c = get()
        local r0, g0, b0 = c.r, c.g, c.b
        ColorPickerFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        ColorPickerFrame:SetupColorPickerAndShow({
            r = r0, g = g0, b = b0,
            swatchFunc = function() apply(ColorPickerFrame:GetColorRGB()) end,
            cancelFunc = function() apply(r0, g0, b0) end,
        })
    end)
    refresh()
    return f
end

function UI.TextBox(parent, text, get, set)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(380, 26)
    UI.Label(f, text, "GameFontHighlight"):SetPoint("LEFT", 4, 0)
    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(200, 20)
    eb:SetPoint("LEFT", 156, 0)
    eb:SetAutoFocus(false)
    eb:SetText(get())
    eb:SetScript("OnShow", function(self) self:SetText(get()) end)
    eb:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        set(self:GetText())
        ns.Refresh()
    end)
    eb:SetScript("OnEnterPressed", eb.ClearFocus)
    eb:SetScript("OnEscapePressed", eb.ClearFocus)
    return f
end

function UI.Help(parent, text, width)
    local fs = UI.Label(parent, text, "GameFontDisableSmall")
    fs:SetWidth(width)
    fs:SetJustifyH("LEFT")
    return fs
end

function UI.Placer()
    local y = 0
    return function(w, h, x)
        w:SetPoint("TOPLEFT", x or 0, y)
        y = y - h
    end
end

-- A movable settings window with tabs. pages = { { key, label, build(page) } }
function UI.Window(globalName, title, width, height, pages)
    local f = CreateFrame("Frame", globalName, UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(width, height)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    UI.Label(f, title):SetPoint("TOP", 0, -5)
    tinsert(UISpecialFrames, globalName)

    local frames, tabs = {}, {}
    local function select(key)
        for k, page in pairs(frames) do page:SetShown(k == key) end
        for k, tab in pairs(tabs) do
            if k == key then tab:LockHighlight() else tab:UnlockHighlight() end
        end
    end
    for i, def in ipairs(pages) do
        local key = def[1]
        local tab = UI.Button(f, def[2], 100)
        tab:SetPoint("TOPLEFT", 14 + (i - 1) * 104, -30)
        tab:SetScript("OnClick", function() select(key) end)
        tabs[key] = tab
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", 16, -62)
        page:SetPoint("BOTTOMRIGHT", -16, 12)
        frames[key] = page
        def[3](page)
    end
    select(pages[1][1])
    return f
end

-- Text templates: "value / max" -> ("%d / %d", {value, max}). Words: value, max, percent
-- (percent.1 for a decimal), plus any extra words the addon passes in `strings` (formatted %s).
-- Values may be secret, so they only ever reach SetFormattedText.
local compiled = {}
function UI.Compile(template, strings)
    local key = template .. "\0" .. (strings and table.concat(strings, ",") or "")
    local c = compiled[key]
    if c then return c end
    local isString = {}
    for _, w in ipairs(strings or {}) do isString[w] = true end
    local args = {}
    local pattern = template:gsub("%%", "%%%%")
    pattern = pattern:gsub("||", "|")
    pattern = pattern:gsub("|", "||")
    pattern = pattern:gsub("(%a+)(%.?%d*)", function(word, suffix)
        local w = word:lower()
        if isString[w] then
            args[#args + 1] = w
            return "%s" .. suffix
        elseif w == "value" or w == "max" then
            args[#args + 1] = w
            return "%d" .. suffix
        elseif w == "percent" then
            args[#args + 1] = "percent"
            local places = tonumber(suffix:match("^%.(%d)"))
            if places then return "%." .. math.min(places, 3) .. "f%%" end
            return "%d%%" .. suffix
        end
    end)
    c = { pattern = pattern, args = args }
    compiled[key] = c
    return c
end

function UI.SetTemplateText(fs, template, vals, strings)
    if not template or strtrim(template) == "" then
        fs:Hide()
        return
    end
    fs:Show()
    local c = UI.Compile(template, strings)
    local a = c.args
    pcall(fs.SetFormattedText, fs, c.pattern, vals[a[1]], vals[a[2]], vals[a[3]], vals[a[4]], vals[a[5]], vals[a[6]])
end
