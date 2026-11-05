-- At login: hand the session's environment to systemd and the portals, then
-- start neko. neko brings its own polkit agent, clipboard history, idle and
-- lock; anything else you want started goes in user.lua.

local machine = require("configs.machine")

hl.on("hyprland.start", function()
  hl.exec_cmd("sh -c 'dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XCURSOR_THEME XCURSOR_SIZE"
    .. " && systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XCURSOR_THEME XCURSOR_SIZE"
    .. " && sleep 1 && systemctl --user restart xdg-desktop-portal-hyprland xdg-desktop-portal-gtk xdg-desktop-portal'")
  hl.exec_cmd(machine.neko .. "/bin/neko-session start")
end)
