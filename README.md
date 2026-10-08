# neko-shell

A Quickshell desktop for Hyprland: a bar, panels, menus, notifications, on-screen display, clipboard and emoji pickers, with soft, translucent Material-style surfaces.

## Roadmap

- [x] Shell, panels and commands, renamed to neko (`NEKO_PATH`, `neko-*` commands, `~/.config/neko`)
- [x] Works on Qt 6.12
- [x] Run it as the session's shell
- [x] Look: translucent blurred surfaces, floating bar with capsules
- [x] Material You colors from the wallpaper (`neko-theme-material`, needs matugen)
- [x] Wallpaper picker, randomizer and rotation (`neko-wallpaper`, the control center's Wallpaper tile, Style > Wallpaper, `SUPER+W`)
- [x] Settings in the menu: colors, bar, themed apps (`neko-settings`)
- [x] A settings window in tabs (appearance, bar, widgets, wallpaper, system, calendars, apps) that grows out of the bar's dynamic island (Settings > Open settings window); the bar's layouts, style and position drawn as little screens to pick from, and its widgets dragged between sections, joined into capsules and configured
- [x] One command, `neko`: `neko settings`, `neko open <panel>`, `neko lock` (`neko lock restart` brings a crashed lock screen back), and `neko <target> <method>` for anything the running shell offers
- [x] Calendar events from iCal feeds, Google Calendar's secret address included, in the control center's calendar (`neko-calendars`, `neko-calendar-events`)
- [x] Keybindings with descriptions and a searchable cheat sheet (`SUPER+/`; add `{ description = "..." }` to a bind to name it)
- [x] Media keys through global shortcuts instead of a process per keypress (`default/hypr/neko.lua`)
- [x] One palette for every app: kitty, btop, tmux, GTK (`NEKO_THEME_APPS`)
- [x] Laptop lid and external monitor handling (`neko-lid`)
- [x] Every Hyprland display setting in the control center, kept across reloads, with a 15-second undo for risky changes (`neko-display`); several displays extended (arranged by dragging, with snapping), mirrored or one at a time
- [x] Panels: Wi-Fi QR code, speed test, AI agent usage, Tailscale
- [x] Agents panel: launch and account actions work (`neko-default-agent`, Settings > Default agent)
- [x] Self-documenting `neko` commands and hooks (`neko`, `~/.config/neko/hooks/`)
- [x] A Claude Code skill describing the setup (`skills/neko`, linked into `~/.claude/skills`)

## Running

```bash
bin/neko-session start   # take over as the session's shell
bin/neko-session stop    # hand back to the previous one
```

Machine settings go in `~/.config/neko/env`, which `neko-session` sources:

| Variable | Purpose |
|---|---|
| `NEKO_QUICKSHELL` | Quickshell binary, for when the packaged one lags behind Qt (default `quickshell`) |
| `NEKO_THEME` | Theme from `themes/` to start with (default `neko`) |
| `NEKO_WALLPAPER` | Image to use until a background has been picked |
| `NEKO_WALLPAPER_DIR` | Folder `neko-wallpaper` picks from (default `~/Pictures/wallpapers`) |
| `NEKO_THEME_APPS` | Apps that follow the theme: any of `kitty btop tmux gtk` |
| `NEKO_REPLACES` | Command that stops the shell neko takes over from |
| `NEKO_RESTORES` | Command that brings that shell back on stop |

Layout and plugins live in `~/.config/neko/shell.json`; turn off a service only when another tool handles the same job, for example `"disabledPlugins": ["neko.idle", "neko.lock"]` while using an external idle daemon and lock screen.

## Hooks

Scripts in `~/.config/neko/hooks/` run on events; `<name>.d/` folders run every script inside.

| Hook | When | Argument |
|---|---|---|
| `theme-set` | A theme is applied, including wallpaper Material colors | theme name |
| `wallpaper-set` | The wallpaper changes | image path |
| `session-start` | neko takes over the session | |
| `font-set` | The font changes | font name |
| `battery-low` | Battery runs low | |

## Inspiration

neko-shell was inspired by many projects in the Linux desktop community. See [LICENSE](LICENSE) for copyright notices.
