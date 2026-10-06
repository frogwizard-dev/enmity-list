local _, ns = ...

-- The settings controls are FrogLib's (UI.lua); every change calls ns.Refresh().
ns.UI = FrogLib.UI.Kit({ refresh = function() ns.Refresh() end })
