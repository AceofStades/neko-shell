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
  match = { namespace = "^neko-(bar|menu|notifications|osd|reminders|clipboard|emojis|image-selector|keyboard-panel|network-qr|polkit)$" },
  blur = true,
  ignore_alpha = 0.2,
})

-- The bar's panels (audio, network, clock...) are popups of the bar surface
hl.config({ decoration = { blur = { popups = true, popups_ignorealpha = 0.2 } } })

-- Keep the bar and the overlays instant. Overlays stay mapped between opens and
-- grow from a parked 1x1, which Hyprland would otherwise animate as a slide.
hl.layer_rule({ match = { namespace = "^neko-bar$" }, no_anim = true, animation = "none" })
hl.layer_rule({
  match = { namespace = "^neko-(menu|image-selector|emojis|clipboard|keyboard-panel|osd|reminders|network-qr)$" },
  no_anim = true,
  animation = "none",
})

-- Media keys and the menu, only while neko is the running shell: neko-session
-- start sets the flag (in XDG_RUNTIME_DIR, gone after a reboot) and stop
-- clears it, so loading this file permanently never steals the keys from
-- another shell.
local flag = io.open((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/neko-active", "r")
if flag then
  flag:close()

  local keys = {
    "XF86AudioRaiseVolume", "XF86AudioLowerVolume", "XF86AudioMute", "XF86AudioMicMute",
    "XF86MonBrightnessUp", "XF86MonBrightnessDown", "XF86AudioPlay", "XF86AudioPause",
    "SUPER + ALT + SPACE",
  }
  for _, key in ipairs(keys) do
    hl.unbind(key)
  end

  local run = "env NEKO_PATH=" .. neko_path .. " PATH=" .. neko_path .. "/bin:$PATH "

  hl.bind("XF86AudioRaiseVolume", hl.dsp.global("neko:audio.raise"), { locked = true, repeating = true })
  hl.bind("XF86AudioLowerVolume", hl.dsp.global("neko:audio.lower"), { locked = true, repeating = true })
  hl.bind("XF86AudioMute", hl.dsp.global("neko:audio.mute-toggle"), { locked = true })
  hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd(run .. "neko-audio-input-mute"), { locked = true })
  hl.bind("XF86MonBrightnessUp", hl.dsp.global("neko:brightness.raise"), { locked = true, repeating = true })
  hl.bind("XF86MonBrightnessDown", hl.dsp.global("neko:brightness.lower"), { locked = true, repeating = true })
  hl.bind("XF86AudioPlay", hl.dsp.global("neko:ipc.media.playPause"), { locked = true })
  hl.bind("XF86AudioPause", hl.dsp.global("neko:ipc.media.playPause"), { locked = true })
  hl.bind("SUPER + ALT + SPACE", hl.dsp.global("neko:menu.root"))
end
