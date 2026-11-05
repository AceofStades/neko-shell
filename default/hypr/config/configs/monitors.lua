-- Every display at its preferred mode, placed and scaled automatically. Set
-- them up in the control center's display page: neko-display writes
-- ~/.config/neko/displays.lua, which neko's module loads after this and so wins.
-- A rule of your own for one display can go in user.lua.

hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
