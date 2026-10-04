local ADDON, ns = ...

-- The bar textures and fonts the settings offer, and setting a font safely: FrogLib's Media
-- (Libs\FrogLib\Media.lua), with this addon's own fonts listed first.
local FONTS = "Interface\\AddOns\\" .. ADDON .. "\\Fonts\\"
ns.Media = FrogLib.Media.New({
    fonts = {
        { "Michroma (wide)", FONTS .. "Michroma.ttf" }, -- wide, like FFXIV's gauge numbers
        { "Source Sans 3 (Myriad-like)", FONTS .. "SourceSans3.ttf" },
    },
})
