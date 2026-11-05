-- Keys. neko's module adds the media, brightness and lid keys, the menu
-- (Super+Alt+Space), the keybindings cheat sheet (Super+/), the wallpaper
-- picker (Super+W) and the lock (Ctrl+Alt+L) while neko runs; the volume and
-- brightness keys here are the fallback for when it doesn't.

local machine = require("configs.machine")
local neko = "env NEKO_PATH=" .. machine.neko .. " PATH=" .. machine.neko .. "/bin:$PATH "

-- Window management and the session
hl.bind("SUPER + Q", hl.dsp.window.close(), { description = "Close window" })
hl.bind("SUPER + SHIFT + Q", hl.dsp.window.close())
hl.bind("SUPER + F", hl.dsp.window.float({ action = "toggle" }), { description = "Float window" })
hl.bind("ALT + Return", hl.dsp.window.fullscreen({ action = "toggle" }), { description = "Fullscreen" })
hl.bind("SUPER + ALT + P", hl.dsp.window.pseudo())
hl.bind("SUPER + G", hl.dsp.exec_raw("togglegroup", ""), { description = "Group windows" })
hl.bind("ALT + Tab", hl.dsp.exec_cmd("hyprctl dispatch 'hl.dsp.window.cycle_next()'"), { description = "Next window" })
hl.bind("CTRL + ALT + P", hl.dsp.global("neko:menu.system"), { description = "Power menu" })
hl.bind("XF86PowerOff", hl.dsp.global("neko:menu.system"), { locked = true })
hl.bind("SUPER + Escape", hl.dsp.exec_cmd(neko .. "neko-session restart"), { description = "Restart neko" })
hl.bind("CTRL + ALT + Delete", hl.dsp.exec_cmd("hyprctl dispatch exit 0"))

hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

-- Apps and neko's panels
hl.bind("ALT + Space", hl.dsp.global("neko:menu.apps"), { description = "Apps" })
hl.bind("SUPER + Return", hl.dsp.exec_cmd(machine.terminal), { description = "Terminal" })
hl.bind("SUPER + T", hl.dsp.exec_cmd(machine.terminal))
hl.bind("SUPER + E", hl.dsp.exec_cmd(machine.files), { description = "Files" })
hl.bind("SUPER + V", hl.dsp.global("neko:panel.neko.clipboard"), { description = "Clipboard" })
hl.bind("SUPER + period", hl.dsp.global("neko:panel.neko.emojis"), { description = "Emojis" })
hl.bind("SUPER + N", hl.dsp.global("neko:ipc.notifications.showHistory"), { description = "Notifications" })

-- Layouts: cycle master, dwindle and scrolling; Super+H/J/K/L resize the way
-- the current one does
local layout = neko .. "neko-hyprland-layout "
hl.bind("SUPER + Y", hl.dsp.exec_cmd(layout .. "cycle"), { description = "Next layout" })
hl.bind("SUPER + H", hl.dsp.exec_cmd(layout .. "resize h"), { repeating = true })
hl.bind("SUPER + L", hl.dsp.exec_cmd(layout .. "resize l"), { repeating = true })
hl.bind("SUPER + K", hl.dsp.exec_cmd(layout .. "resize k"), { repeating = true })
hl.bind("SUPER + J", hl.dsp.exec_cmd(layout .. "resize j"), { repeating = true })
hl.bind("SUPER + bracketleft", hl.dsp.exec_cmd(layout .. "scroll prev"))
hl.bind("SUPER + bracketright", hl.dsp.exec_cmd(layout .. "scroll next"))
hl.bind("SUPER + Space", hl.dsp.layout("swapwithmaster"), { description = "Swap with master" })
hl.bind("SUPER + I", hl.dsp.layout("addmaster"))
hl.bind("SUPER + CTRL + D", hl.dsp.layout("removemaster"))
hl.bind("SUPER + CTRL + Return", hl.dsp.layout("cyclenext"))
hl.bind("SUPER + ALT + K", hl.dsp.layout("cycleprev"))

-- Screenshots, with the laptop F6 key standing in for Print
local shot = neko .. "neko-capture-screenshot "
for _, key in ipairs({ "Print", "F6" }) do
  hl.bind("SUPER + " .. key, hl.dsp.exec_cmd(shot .. "fullscreen"), { description = "Screenshot" })
  hl.bind("SUPER + SHIFT + " .. key, hl.dsp.exec_cmd(shot .. "region"), { description = "Screenshot a region" })
  hl.bind("ALT + " .. key, hl.dsp.exec_cmd(shot .. "windows"), { description = "Screenshot a window" })
end
hl.bind("SUPER + SHIFT + S", hl.dsp.exec_cmd(shot .. "region copy"), { description = "Copy a region" })

-- Media
hl.bind("SUPER + S", hl.dsp.global("neko:ipc.media.playPause"), { description = "Play or pause" })
hl.bind("SUPER + D", hl.dsp.global("neko:ipc.media.next"), { description = "Next track" })
hl.bind("SUPER + A", hl.dsp.global("neko:ipc.media.previous"), { description = "Previous track" })

-- Volume and brightness when neko isn't running (neko's module replaces them)
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"), { locked = true, repeating = true })
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("brightnessctl set 5%+"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 5%-"), { locked = true, repeating = true })

-- Focus and movement
for key, direction in pairs({ left = "l", right = "r", up = "u", down = "d" }) do
  hl.bind("SUPER + " .. key, hl.dsp.focus({ direction = key }))
  hl.bind("SUPER + CTRL + " .. key, hl.dsp.exec_cmd("hyprctl dispatch movewindow " .. direction))
end

-- Workspaces
for i = 1, 10 do
  local key = tostring(i % 10)
  hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = tostring(i) }))
  hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = tostring(i) }))
  hl.bind("SUPER + CTRL + " .. key, hl.dsp.exec_raw("movetoworkspacesilent", tostring(i)))
end
hl.bind("SUPER + Tab", hl.dsp.focus({ workspace = "m+1" }), { description = "Next workspace" })
hl.bind("SUPER + SHIFT + Tab", hl.dsp.focus({ workspace = "m-1" }))
hl.bind("SUPER + SHIFT + bracketleft", hl.dsp.window.move({ workspace = "-1" }))
hl.bind("SUPER + SHIFT + bracketright", hl.dsp.window.move({ workspace = "+1" }))
hl.bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind("SUPER + U", hl.dsp.workspace.toggle_special(""), { description = "Scratchpad" })
hl.bind("SUPER + SHIFT + U", hl.dsp.window.move({ workspace = "special" }))
