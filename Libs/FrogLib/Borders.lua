-- FrogLib Borders: the three border looks Frog Wizard's bars share, each crisp at any scale.
--   local e = FrogLib.Borders.Edges(frame, bar, layer, sublevel)
--       Four textures (made on `frame`) round `bar`: e:Place(size, out, color) puts them `size`
--       screen pixels thick, starting `out` pixels outside the bar; e:SetColor(c), e:SetShown(on).
--   local s = FrogLib.Borders.Stone(bar, levelAbove)
--       The grey stone border old frames and tooltips use, 3 units outside the bar (its line then
--       meets the fill): a BackdropTemplate frame. FrogLib.Borders.ColorStone(s, c) recolours it.
--   local f = FrogLib.Borders.Forever(bar, layer, sublevel)
--       Our Forever-style frame (Media\ForeverFrame.tga, 16x16): a dark outline, a light metallic
--       rim brighter along the top, and a dark inner line, each one texel wide, with the corners
--       cut. Nine-sliced at a whole number of screen pixels per texel (f:Place(thickness), 1 to 3),
--       so nothing stretches but its straight edges. It sits 2 texels out from the bar, its inner
--       line over the fill's edge. f:SetShown(on).
-- Pixel sizes change with the frame's scale: place them again when it changes.

local ADDON = ...
local Borders = FrogLib:Module("Borders", 1)
if not Borders then return end

local Pixel, NoSnap = FrogLib.Pixel, FrogLib.NoSnap
Borders.FOREVER_FILE = "Interface\\AddOns\\" .. ADDON .. "\\Libs\\FrogLib\\Media\\ForeverFrame.tga"
Borders.STONE_FILE = "Interface\\Tooltips\\UI-Tooltip-Border"
local FRAME_SIZE, FRAME_SLICE, FRAME_OUT = 16, 3, 2
local FRAME_KEYS = { "tl", "t", "tr", "l", "r", "bl", "b", "br" }
local SIDES = { "top", "bottom", "left", "right" }

------------------------------------------------------------------------------
-- Pixel edges
------------------------------------------------------------------------------

Borders.EdgesMethods = Borders.EdgesMethods or {}
local Edges = Borders.EdgesMethods
Borders.EdgesMeta = Borders.EdgesMeta or { __index = Edges }

function Borders.Edges(frame, bar, layer, sublevel)
    local e = { frame = frame, bar = bar or frame }
    for _, key in ipairs(SIDES) do
        local t = frame:CreateTexture(nil, layer or "BORDER", nil, sublevel or 0)
        NoSnap(t)
        e[key] = t
    end
    return setmetatable(e, Borders.EdgesMeta)
end

function Edges:Place(size, out, color)
    local p = Pixel(self.frame)
    local t, o = p * (size or 1), p * (out or 0)
    local bar = self.bar
    self.top:ClearAllPoints()
    self.top:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", -(o + t), o)
    self.top:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", o + t, o)
    self.top:SetHeight(t)
    self.bottom:ClearAllPoints()
    self.bottom:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", -(o + t), -o)
    self.bottom:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", o + t, -o)
    self.bottom:SetHeight(t)
    self.left:ClearAllPoints()
    self.left:SetPoint("TOPRIGHT", bar, "TOPLEFT", -o, o)
    self.left:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", -o, -o)
    self.left:SetWidth(t)
    self.right:ClearAllPoints()
    self.right:SetPoint("TOPLEFT", bar, "TOPRIGHT", o, o)
    self.right:SetPoint("BOTTOMLEFT", bar, "BOTTOMRIGHT", o, -o)
    self.right:SetWidth(t)
    if color then self:SetColor(color) end
end

function Edges:SetColor(c)
    for _, key in ipairs(SIDES) do self[key]:SetColorTexture(c.r, c.g, c.b, c.a or 1) end
end

function Edges:SetShown(shown)
    for _, key in ipairs(SIDES) do self[key]:SetShown(shown and true or false) end
end

------------------------------------------------------------------------------
-- Classic stone
------------------------------------------------------------------------------

function Borders.Stone(bar, levelAbove)
    local s = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    s:SetFrameLevel(bar:GetFrameLevel() + (levelAbove or 1))
    s:SetPoint("TOPLEFT", bar, "TOPLEFT", -3, 3)
    s:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 3, -3)
    s:SetBackdrop({ edgeFile = Borders.STONE_FILE, edgeSize = 12 })
    s:SetBackdropBorderColor(0.75, 0.75, 0.75, 1)
    return s
end

function Borders.ColorStone(s, c)
    c = c or { r = 0.75, g = 0.75, b = 0.75 }
    s:SetBackdropBorderColor(c.r, c.g, c.b, c.a or 1)
end

------------------------------------------------------------------------------
-- The Forever frame
------------------------------------------------------------------------------

Borders.ForeverMethods = Borders.ForeverMethods or {}
local Forever = Borders.ForeverMethods
Borders.ForeverMeta = Borders.ForeverMeta or { __index = Forever }

function Borders.Forever(bar, layer, sublevel)
    local f = { bar = bar, parts = {} }
    for _, key in ipairs(FRAME_KEYS) do
        local t = bar:CreateTexture(nil, layer or "OVERLAY", nil, sublevel or 5)
        t:SetTexture(Borders.FOREVER_FILE, nil, nil, "NEAREST")
        NoSnap(t)
        f.parts[key] = t
    end
    return setmetatable(f, Borders.ForeverMeta)
end

function Forever:Place(thickness)
    local p, bar = self.parts, self.bar
    local px = (thickness or 1) * Pixel(bar)
    local m, out = FRAME_SLICE * px, FRAME_OUT * px
    local a, b = FRAME_SLICE / FRAME_SIZE, (FRAME_SIZE - FRAME_SLICE) / FRAME_SIZE
    p.tl:SetTexCoord(0, a, 0, a)
    p.t:SetTexCoord(a, b, 0, a)
    p.tr:SetTexCoord(b, 1, 0, a)
    p.l:SetTexCoord(0, a, a, b)
    p.r:SetTexCoord(b, 1, a, b)
    p.bl:SetTexCoord(0, a, b, 1)
    p.b:SetTexCoord(a, b, b, 1)
    p.br:SetTexCoord(b, 1, b, 1)
    for _, t in pairs(p) do t:ClearAllPoints() end
    p.tl:SetPoint("TOPLEFT", bar, "TOPLEFT", -out, out)
    p.tr:SetPoint("TOPRIGHT", bar, "TOPRIGHT", out, out)
    p.bl:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", -out, -out)
    p.br:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", out, -out)
    for _, key in ipairs({ "tl", "tr", "bl", "br" }) do p[key]:SetSize(m, m) end
    p.t:SetPoint("TOPLEFT", p.tl, "TOPRIGHT")
    p.t:SetPoint("BOTTOMRIGHT", p.tr, "BOTTOMLEFT")
    p.b:SetPoint("TOPLEFT", p.bl, "TOPRIGHT")
    p.b:SetPoint("BOTTOMRIGHT", p.br, "BOTTOMLEFT")
    p.l:SetPoint("TOPLEFT", p.tl, "BOTTOMLEFT")
    p.l:SetPoint("BOTTOMRIGHT", p.bl, "TOPRIGHT")
    p.r:SetPoint("TOPLEFT", p.tr, "BOTTOMLEFT")
    p.r:SetPoint("BOTTOMRIGHT", p.br, "TOPRIGHT")
end

function Forever:SetShown(shown)
    for _, t in pairs(self.parts) do t:SetShown(shown and true or false) end
end

-- Its textures, for code that needs to tell them apart from the game's (PRT hides the rest).
function Forever:Textures()
    return self.parts
end
