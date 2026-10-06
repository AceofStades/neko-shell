---
name: neko
description: >
  Use for any change to this Linux desktop: Hyprland config (~/.config/hypr/), the neko-shell bar,
  panels, menu, OSD, notifications, themes, wallpaper, keybindings, lid/monitor behavior, idle and
  lock, and the apps neko themes (btop, tmux, GTK). Explains where each setting lives and which
  neko command changes it, so edits land in the right file.
---

# neko desktop

Hyprland with a Lua config, and neko-shell (a Quickshell desktop) as the shell. The neko checkout is `~/Code/neko-shell`; its commands are `neko-*` in `bin/`, also reachable as `neko <group> <command>` (run `neko` to list groups).

## Where things live

| What | File |
|---|---|
| Hyprland config | `~/.config/hypr/hyprland.lua`, split into `configs/{env,monitors,autostart,settings,rules,keybinds}.lua` |
| neko's Hyprland side (blur rules, media keys, lid, SUPER+W, SUPER+/, SUPER+ALT+SPACE) | `~/Code/neko-shell/default/hypr/neko.lua`, loaded at the end of `hyprland.lua` |
| Shell layout and enabled plugins | `~/.config/neko/shell.json` |
| Live look overrides (bar float, capsules...) | `~/.config/neko/shell.toml` |
| Display settings from the control center (they override `monitors.lua`) | `~/.config/neko/displays.json`, written out as `displays.lua` for `neko.lua` to load |
| Machine settings (Quickshell binary, wallpaper folder, themed apps) | `~/.config/neko/env` |
| Your own themes (the wallpaper Material theme is `material`) | `~/.config/neko/themes/<name>/` |
| Rendered current theme | `~/.local/state/neko/current/theme/` (generated; don't edit) |
| Hooks | `~/.config/neko/hooks/{theme-set,wallpaper-set,session-start,font-set,battery-low}` |
| Idle, lock, screen off | `~/.config/hypr/hypridle.conf` (hyprlock locks; neko's own idle/lock/polkit plugins are off) |

## Changing things

- Settings: `neko-settings get|set|toggle <key>` with `colors` (material|neko), `bar.float`, `bar.capsules`, `app.<kitty|btop|tmux|gtk>`. The same options are in the menu under Settings.
- Theme: `neko-theme-material` re-themes from the wallpaper; `neko-session theme` re-applies the current theme.
- Wallpaper: `neko-wallpaper pick|random|set <image>|auto <minutes|off>`.
- Displays: `neko-display set <output> key=value...` for any `hl.monitor` field (`key=` clears it), `--trial` to undo after 15 seconds unless `neko-display keep`, `neko-display reset <output>` to go back to `monitors.lua`.
- Shell: `neko-session start|stop|restart`. Restart after any QML change.
- Keybindings: edit `configs/keybinds.lua`; give a bind `{ description = "..." }` so the SUPER+/ cheat sheet names it. Keys owned by `neko.lua` are rebound there only while neko runs.
- Bar widgets: `neko-shell shell putBarWidget <id> '{"section":"right","index":0}'`, or edit `bar.layout` in `shell.json` and restart.

## Rules

- `hyprctl dispatch` takes Lua: `hyprctl dispatch 'hl.dsp.exec_cmd("cmd")'`; `hyprctl keyword` and old-style dispatchers fail.
- The user does not want kitty themed by neko, and prefers their perceptual brightness curve (`neko-brightness-step`) to flat steps.
- sudo works without a terminal through Howdy face auth; still ask before system-wide changes.
- Tell the user what file you changed and how to undo it.
