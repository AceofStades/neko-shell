# neko-shell

A Quickshell desktop for Hyprland: a bar, panels, menus, notifications, on-screen display, clipboard and emoji pickers, with soft, translucent Material-style surfaces.

## Roadmap

- [x] Shell, panels and commands, renamed to neko (`NEKO_PATH`, `neko-*` commands, `~/.config/neko`)
- [x] Works on Qt 6.12
- [x] Run it as the session's shell
- [ ] Look: Eldritch palette, translucent blurred surfaces, floating capsule bar
- [ ] Material You colors from the wallpaper
- [ ] Keybindings with descriptions and a searchable cheat sheet
- [ ] Media keys through global shortcuts instead of a process per keypress
- [ ] One palette for every app (theme templates)
- [ ] Laptop lid and external monitor handling
- [ ] Panels: Wi-Fi QR code, speed test, AI agent usage, Tailscale
- [ ] Self-documenting `neko` commands and hooks
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
| `NEKO_REPLACES` | Command that stops the shell neko takes over from |
| `NEKO_RESTORES` | Command that brings that shell back on stop |

Layout and plugins live in `~/.config/neko/shell.json`; turn off services another tool already handles with `"disabledPlugins": ["neko.idle", "neko.lock", "neko.polkit"]`.

## Inspiration

neko-shell was inspired by many projects in the Linux desktop community, including Omarchy and Noctalia. See [LICENSE](LICENSE) for copyright notices.
