# neko-shell

A Quickshell desktop for Hyprland: a bar, panels, menus, notifications, on-screen display, clipboard and emoji pickers, with soft, translucent Material-style surfaces.

## Roadmap

- [x] Shell, panels and commands, renamed to neko (`NEKO_PATH`, `neko-*` commands, `~/.config/neko`)
- [x] Works on Qt 6.12
- [x] Run it as the session's shell
- [x] Look: translucent blurred surfaces, floating bar with capsules
- [x] Material You colors from the wallpaper (`neko-theme-material`, needs matugen)
- [x] Wallpaper picker, randomizer and rotation (`neko-wallpaper`, Style > Wallpaper, `SUPER+W`)
- [x] Settings in the menu: colors, bar, themed apps (`neko-settings`)
- [ ] A full settings panel
- [x] Keybindings with descriptions and a searchable cheat sheet (`SUPER+/`; add `{ description = "..." }` to a bind to name it)
- [x] Media keys through global shortcuts instead of a process per keypress (`default/hypr/neko.lua`)
- [x] One palette for every app: kitty, btop, tmux, GTK (`NEKO_THEME_APPS`)
- [x] Laptop lid and external monitor handling (`neko-lid`)
- [x] Panels: Wi-Fi QR code, speed test, AI agent usage, Tailscale
- [x] Agents panel: launch and account actions work (`neko-default-agent`, Settings > Default agent)
- [x] Self-documenting `neko` commands and hooks (`neko`, `~/.config/neko/hooks/`)
- [ ] A Claude Code skill describing the setup

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

Layout and plugins live in `~/.config/neko/shell.json`; turn off services another tool already handles with `"disabledPlugins": ["neko.idle", "neko.lock", "neko.polkit"]`.

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

neko-shell was inspired by many projects in the Linux desktop community, including Omarchy and Noctalia. See [LICENSE](LICENSE) for copyright notices.
