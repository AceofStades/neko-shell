-- neko's Hyprland config. install.sh puts it in ~/.config/hypr when you choose
-- neko's config over your own, and may replace these files when neko updates
-- (with a backup). Your own changes go in user.lua next to this file, which
-- install.sh creates once and never touches again; it's loaded last, so it
-- wins over everything here.
--
-- configs/machine.lua is written by install.sh for this machine: where neko
-- lives, your terminal and file manager. ~/.config/neko/hardware.lua holds what
-- it found about the hardware (GPU environment, for one).

require("configs.env")
require("configs.monitors")
require("configs.settings")
require("configs.rules")
require("configs.keybinds")
require("configs.autostart")

local machine = require("configs.machine")
local home = os.getenv("HOME") or ""

-- Load a file if it's there, reporting rather than stopping on an error in it
local function load_optional(path)
  local file = io.open(path, "r")
  if not file then return end
  file:close()
  local ok, err = pcall(dofile, path)
  if not ok then print("neko: " .. tostring(err)) end
end

load_optional(home .. "/.config/neko/hardware.lua")

-- neko's Hyprland side: blur behind its surfaces, its keys, lid handling
load_optional(machine.neko .. "/default/hypr/neko.lua")

-- The current theme's border colors (neko theme set writes them)
load_optional(home .. "/.local/state/neko/current/theme/hyprland.lua")

-- Yours, last, so it wins
load_optional(home .. "/.config/hypr/user.lua")
