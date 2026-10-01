local _, ns = ...

-- FFXIV gauges in two styles, shared by the XIV addons (copied as-is into each):
--   "line":   a hair-thin bright line with a soft glow and a spark at the fill's end
--             (the modern target bar);
--   "framed": a capsule in a gold rim, with a dark inner track and a glossy fill
--             (the classic HP/MP/TP parameter bar).
-- Both have round ends: each layer's ends are half-discs drawn just past its straight part.

local WHITE = "Interface\\Buttons\\WHITE8X8"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask" -- a soft-edged white circle
local SMOOTH = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut
local IMMEDIATE = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate

local GOLD_TOP = { 0.92, 0.80, 0.50 }
local GOLD_BOTTOM = { 0.66, 0.51, 0.27 }
local RIM = 2 -- gold rim thickness in the framed style

local Gauge = {}
Gauge.__index = Gauge

local function Tex(bar, layer, sublevel, file)
    local t = bar:CreateTexture(nil, layer, nil, sublevel)
    if not t:SetTexture(file or WHITE) then t:SetTexture(WHITE) end
    return t
end

-- A round end: an ordinary texture cut to a circle by a mask, so it can carry the same bar
-- texture or gradient as the straight part it finishes.
local function Cap(bar, layer, sublevel)
    local t = Tex(bar, layer, sublevel)
    local mask = bar:CreateMaskTexture()
    mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    t:AddMaskTexture(mask)
    t.mask = mask
    return t
end

-- Puts a round end of diameter d on `point` of `region`. Only the outer half is drawn (the
-- disc mask is centred on the end, the texture covers just the half outside it), so an end
-- never overlaps its straight part: an overlap shows as a darker circle once the gauge is
-- faded, because each piece is blended on its own.
local function PlaceCap(cap, region, point, side, d)
    cap:ClearAllPoints()
    cap:SetSize(d / 2, d)
    cap:SetPoint(side == "left" and "RIGHT" or "LEFT", region, point)
    cap.mask:ClearAllPoints()
    cap.mask:SetSize(d, d)
    cap.mask:SetPoint("CENTER", region, point)
end

local function Glow(bar, fill, side)
    local t = Tex(bar, "ARTWORK", 1)
    t:SetBlendMode("ADD")
    if side == "TOP" then
        t:SetPoint("BOTTOMLEFT", fill, "TOPLEFT")
        t:SetPoint("BOTTOMRIGHT", fill, "TOPRIGHT")
    else
        t:SetPoint("TOPLEFT", fill, "BOTTOMLEFT")
        t:SetPoint("TOPRIGHT", fill, "BOTTOMRIGHT")
    end
    return t
end

function ns.CreateGauge(parent)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture(WHITE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local g = setmetatable({ bar = bar, style = "line", h = 3 }, Gauge)

    -- Framed style: gold rim capsule (hidden in the line style).
    g.rim = Tex(bar, "BACKGROUND", -8)
    g.rimL = Cap(bar, "BACKGROUND", -8)
    g.rimR = Cap(bar, "BACKGROUND", -8)

    -- Track for the missing part.
    g.track = Tex(bar, "BACKGROUND", -4)
    g.trackCap = Cap(bar, "BACKGROUND", -4)
    g.trackCapL = Cap(bar, "BACKGROUND", -4)

    -- Round ends of the fill itself, drawn with the bar texture (see SetTexture).
    -- (All ends are placed in Layout and Anchor, once the height is known.)
    g.startCap = Cap(bar, "ARTWORK", 0)
    g.endCap = Cap(bar, "ARTWORK", 0)

    -- Line style: glow above and below, spark at the fill's end.
    local fill = bar:GetStatusBarTexture()
    g.glowTop = Glow(bar, fill, "TOP")
    g.glowBottom = Glow(bar, fill, "BOTTOM")
    g.spark = Tex(bar, "OVERLAY", 0, SPARK)
    g.spark:SetBlendMode("ADD")

    -- Framed style: glossy highlight along the top of the fill, carried round both ends by
    -- sharing each end's circular mask.
    local clear, shine = CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 0.4)
    g.sheen = Tex(bar, "ARTWORK", 3)
    g.sheen:SetGradient("VERTICAL", clear, shine)
    g.sheenL = Tex(bar, "ARTWORK", 3)
    g.sheenL:SetGradient("VERTICAL", clear, shine)
    g.sheenL:SetPoint("TOPLEFT", g.startCap, "TOPLEFT")
    g.sheenL:SetPoint("TOPRIGHT", g.startCap, "TOPRIGHT")
    g.sheenL:AddMaskTexture(g.startCap.mask)
    g.sheenR = Tex(bar, "ARTWORK", 3)
    g.sheenR:SetGradient("VERTICAL", clear, shine)
    g.sheenR:AddMaskTexture(g.endCap.mask)

    g:Anchor()
    g:Layout()
    return g
end

-- Everything that follows the fill's edge; the fill texture is replaced when the bar
-- texture changes, so this re-runs then.
function Gauge:Anchor()
    local fill = self.bar:GetStatusBarTexture()
    for _, t in ipairs({ self.glowTop, self.glowBottom }) do t:ClearAllPoints() end
    self.glowTop:SetPoint("BOTTOMLEFT", fill, "TOPLEFT")
    self.glowTop:SetPoint("BOTTOMRIGHT", fill, "TOPRIGHT")
    self.glowBottom:SetPoint("TOPLEFT", fill, "BOTTOMLEFT")
    self.glowBottom:SetPoint("TOPRIGHT", fill, "BOTTOMRIGHT")
    self.spark:ClearAllPoints()
    self.spark:SetPoint("CENTER", fill, "RIGHT")
    PlaceCap(self.endCap, fill, "RIGHT", "right", self.h)
    self.sheenR:ClearAllPoints()
    self.sheenR:SetPoint("TOPLEFT", self.endCap, "TOPLEFT")
    self.sheenR:SetPoint("TOPRIGHT", self.endCap, "TOPRIGHT")
    self.sheen:ClearAllPoints()
    self.sheen:SetPoint("TOPLEFT", fill, "TOPLEFT")
    self.sheen:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
    if self.absorb then self:AnchorAbsorb() end
end

function Gauge:Layout()
    local h, framed = self.h, self.style == "framed"
    self.bar:SetHeight(h)

    -- Dark border around the fill: 1px in the line style, 2px inside the gold rim.
    local pad = framed and 2 or 1
    self.track:ClearAllPoints()
    self.track:SetPoint("TOPLEFT", 0, pad)
    self.track:SetPoint("BOTTOMRIGHT", 0, -pad)
    if framed then
        self.track:SetVertexColor(0.07, 0.05, 0.03, 0.95)
    else
        self.track:SetVertexColor(0, 0, 0, 0.45)
    end
    self.trackCap:SetVertexColor(self.track:GetVertexColor())
    self.trackCapL:SetVertexColor(self.track:GetVertexColor())
    PlaceCap(self.trackCap, self.bar, "RIGHT", "right", h + pad * 2)
    PlaceCap(self.trackCapL, self.bar, "LEFT", "left", h + pad * 2)
    self.trackCapL:SetShown(framed)

    local outer = pad + RIM
    self.rim:ClearAllPoints()
    self.rim:SetPoint("TOPLEFT", 0, outer)
    self.rim:SetPoint("BOTTOMRIGHT", 0, -outer)
    -- The rim's ends are exactly as tall as its straight part, so the same gradient lines up.
    local bottom = CreateColor(GOLD_BOTTOM[1], GOLD_BOTTOM[2], GOLD_BOTTOM[3], 1)
    local top = CreateColor(GOLD_TOP[1], GOLD_TOP[2], GOLD_TOP[3], 1)
    self.rim:SetGradient("VERTICAL", bottom, top)
    PlaceCap(self.rimL, self.bar, "LEFT", "left", h + outer * 2)
    PlaceCap(self.rimR, self.bar, "RIGHT", "right", h + outer * 2)
    for _, cap in ipairs({ self.rimL, self.rimR }) do
        cap:SetGradient("VERTICAL", bottom, top)
    end
    for _, t in ipairs({ self.rim, self.rimL, self.rimR }) do t:SetShown(framed) end

    PlaceCap(self.startCap, self.bar, "LEFT", "left", h)
    PlaceCap(self.endCap, self.bar:GetStatusBarTexture(), "RIGHT", "right", h)

    -- The glow suits a hair-thin line; capped so a thick bar in line style doesn't turn into
    -- a haze, and faded further the thicker the bar (see SetColor).
    local glow = math.min(4, math.max(2, h + 1))
    self.glowTop:SetHeight(glow)
    self.glowBottom:SetHeight(glow)
    self.glowAlpha = 0.45 * math.max(0.3, math.min(1, 3 / h))
    self.spark:SetSize(math.min(12, math.max(8, h * 2)), h + glow * 2)
    for _, t in ipairs({ self.glowTop, self.glowBottom, self.spark }) do t:SetShown(not framed) end

    local sheenH = math.max(1, math.floor(h * 0.45))
    for _, t in ipairs({ self.sheen, self.sheenL, self.sheenR }) do
        t:SetHeight(sheenH)
        t:SetShown(framed)
    end

    if self.color then self:SetColor(unpack(self.color)) end
end

function Gauge:SetStyle(style)
    self.style = style
    self:Layout()
end

function Gauge:SetHeight(h)
    self.h = h
    self:Layout()
end

-- The fill's round ends use a thin slice of the same texture, so a shaded or glossy bar
-- texture carries its vertical shading into the curve.
function Gauge:SetTexture(path)
    self.bar:SetStatusBarTexture(path)
    for _, cap in ipairs({ self.startCap, self.endCap }) do
        if not cap:SetTexture(path) then cap:SetTexture(WHITE) end
        cap:SetTexCoord(0, 0.02, 0, 1)
    end
    self:Anchor()
end

-- Line style draws the core lighter than the tint so it reads as a lit line, with the glow
-- carrying the colour; framed style uses the colour as-is under its sheen.
function Gauge:SetColor(r, g, b)
    self.color = { r, g, b }
    local cr, cg, cb = r, g, b
    if self.style ~= "framed" then
        cr, cg, cb = r + (1 - r) * 0.35, g + (1 - g) * 0.35, b + (1 - b) * 0.35
    end
    self.bar:SetStatusBarColor(cr, cg, cb)
    self.startCap:SetVertexColor(cr, cg, cb)
    self.endCap:SetVertexColor(cr, cg, cb)
    local near, far = CreateColor(r, g, b, self.glowAlpha or 0.45), CreateColor(r, g, b, 0)
    self.glowTop:SetGradient("VERTICAL", near, far)
    self.glowBottom:SetGradient("VERTICAL", far, near)
    self.spark:SetVertexColor(r + (1 - r) * 0.6, g + (1 - g) * 0.6, b + (1 - b) * 0.6, 0.9)
end

-- Values may be secret; StatusBar setters accept them directly.
function Gauge:SetValues(value, max, instant)
    self.bar:SetMinMaxValues(0, max)
    self.bar:SetValue(value, instant and IMMEDIATE or SMOOTH)
end

------------------------------------------------------------------------------
-- Absorb shields (optional: EnableAbsorb once, then SetAbsorb)
------------------------------------------------------------------------------

-- A shield fills the missing part of the gauge from the fill's edge, and whatever doesn't fit
-- there is laid over the right end of the fill (so a shield at full health still shows). The
-- amount can be secret, so the split is done by clipping, never arithmetic:
--   ahead: a bar starting at the fill's edge, clipped to the missing part -> min(shield, missing)
--   over:  a right-to-left bar across the gauge, clipped to the fill      -> max(0, shield - missing)
local SHIELD_STRIPES = "Interface\\RaidFrame\\Shield-Overlay" -- Blizzard's diagonal shield stripes

local function ShieldBar(parent)
    local sb = CreateFrame("StatusBar", nil, parent)
    sb:SetStatusBarTexture(WHITE)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    local stripes = sb:CreateTexture(nil, "ARTWORK", nil, 1)
    sb.hasStripes = stripes:SetTexture(SHIELD_STRIPES, "REPEAT", "REPEAT") and true or false
    stripes:SetHorizTile(true)
    stripes:SetVertTile(true)
    stripes:SetAllPoints(sb:GetStatusBarTexture())
    sb.stripes = stripes
    return sb
end

function Gauge:EnableAbsorb()
    if self.absorb then return end
    local bar = self.bar
    local a = {}
    a.missClip = CreateFrame("Frame", nil, bar)
    a.missClip:SetClipsChildren(true)
    a.ahead = ShieldBar(a.missClip)
    a.fillClip = CreateFrame("Frame", nil, bar)
    a.fillClip:SetClipsChildren(true)
    a.over = ShieldBar(a.fillClip)
    a.over:SetReverseFill(true)
    a.over:SetAllPoints(bar)
    for _, f in ipairs({ a.missClip, a.fillClip }) do f:SetFrameLevel(bar:GetFrameLevel() + 2) end
    -- The ahead bar is as long as the whole gauge, so a full-size shield can reach its end.
    bar:HookScript("OnSizeChanged", function(_, w) a.ahead:SetWidth(w) end)
    a.ahead:SetWidth(bar:GetWidth())
    self.absorb = a
    self:AnchorAbsorb()
    self:SetAbsorbColor(1, 1, 1)
end

-- Follows the fill's edge; re-run when the fill texture is replaced (see Anchor).
function Gauge:AnchorAbsorb()
    local a = self.absorb
    if not a then return end
    local bar, fill = self.bar, self.bar:GetStatusBarTexture()
    a.missClip:ClearAllPoints()
    a.missClip:SetPoint("TOPLEFT", fill, "TOPRIGHT")
    a.missClip:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
    a.ahead:ClearAllPoints()
    a.ahead:SetPoint("TOPLEFT", fill, "TOPRIGHT")
    a.ahead:SetPoint("BOTTOMLEFT", fill, "BOTTOMRIGHT")
    a.fillClip:ClearAllPoints()
    a.fillClip:SetPoint("TOPLEFT", bar, "TOPLEFT")
    a.fillClip:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
end

-- Faint fill with bright stripes; a plainer, stronger fill if the stripe texture is missing.
function Gauge:SetAbsorbColor(r, g, b)
    local a = self.absorb
    if not a then return end
    for _, sb in ipairs({ a.ahead, a.over }) do
        sb:SetStatusBarColor(r, g, b, sb.hasStripes and 0.25 or 0.55)
        sb.stripes:SetVertexColor(r, g, b, 0.85)
    end
end

function Gauge:SetAbsorb(value, max)
    local a = self.absorb
    if not a then return end
    for _, sb in ipairs({ a.ahead, a.over }) do
        sb:SetMinMaxValues(0, max)
        sb:SetValue(value)
    end
end

function Gauge:ShowAbsorb(shown)
    local a = self.absorb
    if not a then return end
    a.missClip:SetShown(shown)
    a.fillClip:SetShown(shown)
end
