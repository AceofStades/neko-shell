-- neko-shell's Hyprland side: blur behind its translucent surfaces, no layer
-- animations where surfaces should appear instantly, and keys that reach the
-- shell through its global shortcuts, so a keypress spawns nothing.
--
-- neko-session start loads this at runtime. To keep it across config reloads,
-- load it at the end of your own config:
--   dofile(os.getenv("HOME") .. "/Code/neko-shell/default/hypr/neko.lua")

local neko_path = os.getenv("NEKO_PATH")
if not neko_path and debug and debug.getinfo then
  neko_path = debug.getinfo(1, "S").source:match("^@(.*)/default/hypr/neko%.lua$")
end

-- Blur what shows through the translucent bar, menus and overlays.
-- ignore_alpha keeps nearly clear pixels (shadows, rounded corners) sharp.
hl.layer_rule({
  match = { namespace = "^neko-(menu|notifications|osd|clipboard|emojis|image-selector|keyboard-panel|network-qr|polkit|settings)$" },
  blur = true,
  ignore_alpha = 0.2,
})
-- The bar and its island blur behind anything but clear, so their glass can
-- sit on plain blur with next to no tint. The bar blurs only the wallpaper
-- (x-ray): the blur reaches further than the bar is tall, and would otherwise
-- pull the windows below it in, darkening the widgets' lower half. The island
-- hangs over the windows, so it blurs them, as glass over them would.
hl.layer_rule({ match = { namespace = "^neko-bar$" }, blur = true, ignore_alpha = 0.01, xray = true })
hl.layer_rule({ match = { namespace = "^neko-island$" }, blur = true, ignore_alpha = 0.01, xray = false })
-- The bar's panels grow out of its groups, so they blur what the bar does:
-- the wallpaper alone. Over the window below, the same tint would read a
-- shade off from the group it hangs from.
hl.layer_rule({ match = { namespace = "^neko-keyboard-panel$" }, blur = true, ignore_alpha = 0.2, xray = true })

-- The bar's panels (audio, network, clock...) are popups of the bar surface
hl.config({ decoration = { blur = { popups = true, popups_ignorealpha = 0.2 } } })

-- Windows round like the shell: its capsules, shoulders and cards are 14
-- across, and the shell reads this back for the corners that follow Hyprland
hl.config({ decoration = { rounding = 14 } })

-- Keep the bar and the overlays instant. Overlays stay mapped between opens and
-- grow from a parked 1x1, which Hyprland would otherwise animate as a slide.
hl.layer_rule({ match = { namespace = "^neko-bar$" }, no_anim = true, animation = "none" })
hl.layer_rule({
  match = { namespace = "^neko-(menu|image-selector|emojis|clipboard|keyboard-panel|osd|network-qr|settings|island)$" },
  no_anim = true,
  animation = "none",
})

-- Terminals neko opens for short tasks (a custom DNS prompt, a TUI from the
-- menu) float in the middle of the screen instead of tiling
hl.window_rule({
  name = "neko-floating-terminal",
  match = { class = "^org\\.neko\\.(terminal|btop|bash)$" },
  float = true,
  center = true,
  size = "875 600",
})

-- Display settings changed in the control center (neko-display writes them).
-- They come after your own monitor rules, so they win; a broken file is
-- reported rather than stopping the rest of this one.
local displays = (os.getenv("HOME") or "") .. "/.config/neko/displays.lua"
local displays_file = io.open(displays, "r")
if displays_file then
  displays_file:close()
  local ok, err = pcall(dofile, displays)
  if not ok then
    print("neko: " .. tostring(err))
  end
end

-- Media keys and the menu, only while neko is the running shell: neko-session
-- start sets the flag (in XDG_RUNTIME_DIR, gone after a reboot) and stop
-- clears it, so loading this file permanently never steals the keys from
-- another shell.
local flag = io.open((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/neko-active", "r")
if flag then
  flag:close()

  local keys = {
    "XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86AudioMute", "XF86AudioMicMute",
    "XF86MonBrightnessUp", "XF86MonBrightnessDown", "SUPER + XF86MonBrightnessUp", "SUPER + XF86MonBrightnessDown",
    "XF86KbdBrightnessUp", "XF86KbdBrightnessDown",
    "XF86AudioPlay", "XF86AudioPause",
    "SUPER + ALT + SPACE", "SUPER + SLASH", "SUPER + W", "CTRL + ALT + L",
    "switch:on:Lid Switch", "switch:off:Lid Switch",
  }
  for _, key in ipairs(keys) do
    hl.unbind(key)
  end

  local run = "env NEKO_PATH=" .. neko_path .. " PATH=" .. neko_path .. "/bin:$PATH "

  hl.bind("XF86AudioRaiseVolume", hl.dsp.global("neko:audio.raise"), { locked = true, repeating = true })
  hl.bind("XF86AudioLowerVolume", hl.dsp.global("neko:audio.lower"), { locked = true, repeating = true })
  hl.bind("XF86AudioMute", hl.dsp.global("neko:audio.mute-toggle"), { locked = true })
  hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd(run .. "neko-audio-input-mute"), { locked = true })
  -- Brightness moves along a perceptual curve: 16 steps, SUPER for 4 finer ones each
  hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd(run .. "neko-brightness-step up"), { locked = true, repeating = true })
  hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(run .. "neko-brightness-step down"), { locked = true, repeating = true })
  hl.bind("SUPER + XF86MonBrightnessUp", hl.dsp.exec_cmd(run .. "neko-brightness-step fine-up"), { locked = true, repeating = true })
  hl.bind("SUPER + XF86MonBrightnessDown", hl.dsp.exec_cmd(run .. "neko-brightness-step fine-down"), { locked = true, repeating = true })
  hl.bind("XF86KbdBrightnessUp", hl.dsp.exec_cmd(run .. "neko-kbd-brightness up"), { locked = true, repeating = true })
  hl.bind("XF86KbdBrightnessDown", hl.dsp.exec_cmd(run .. "neko-kbd-brightness down"), { locked = true, repeating = true })
  hl.bind("XF86AudioPlay", hl.dsp.global("neko:ipc.media.playPause"), { locked = true })
  hl.bind("XF86AudioPause", hl.dsp.global("neko:ipc.media.playPause"), { locked = true })
  hl.bind("SUPER + ALT + SPACE", hl.dsp.global("neko:menu.root"), { description = "Neko menu" })
  hl.bind("SUPER + SLASH", hl.dsp.exec_cmd(run .. "neko-menu-keybindings"), { description = "Keybindings cheat sheet" })
  hl.bind("SUPER + W", hl.dsp.exec_cmd(run .. "neko-wallpaper pick"), { description = "Pick a wallpaper" })
  hl.bind("CTRL + ALT + L", hl.dsp.exec_cmd(run .. "neko-system-lock"), { description = "Lock screen" })

  -- Lid: with an external monitor the laptop screen goes off instead of the
  -- machine suspending; without one, logind's default suspend still applies.
  -- Re-checked on every config load so a reload while docked keeps it off.
  hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd(run .. "neko-lid apply"), { locked = true })
  hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd(run .. [[neko-lid apply; hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })']]), { locked = true })
  hl.exec_cmd(run .. "neko-lid apply")
end
