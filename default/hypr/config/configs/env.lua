-- Environment for a Wayland session. GPU-specific variables come from
-- ~/.config/neko/hardware.lua, which install.sh writes for the GPU it finds.

hl.env("CLUTTER_BACKEND", "wayland")
hl.env("GDK_BACKEND", "wayland,x11")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_QPA_PLATFORMTHEME", "qt5ct")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")

-- The cursor GNOME's settings name, when there is one
local function gsetting(key)
  local handle = io.popen("gsettings get org.gnome.desktop.interface " .. key .. " 2>/dev/null")
  if not handle then return "" end
  local value = (handle:read("*a") or ""):gsub("'", ""):gsub("%s+$", "")
  handle:close()
  return value
end

local cursor_theme = gsetting("cursor-theme")
local cursor_size = gsetting("cursor-size")
if cursor_theme ~= "" then hl.env("XCURSOR_THEME", cursor_theme) end
hl.env("XCURSOR_SIZE", cursor_size ~= "" and cursor_size or "24")
