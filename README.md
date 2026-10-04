# neko-shell

A Quickshell desktop for Hyprland: Omarchy's features, dressed in Noctalia's style.

neko-shell starts as a fork of the [Omarchy](https://github.com/omacom/omarchy) 4 shell (its bar, panels, menus, notifications, OSD, clipboard and emoji pickers), trimmed down to a desktop shell rather than a distribution, and restyled after [Noctalia](https://github.com/noctalia-dev/noctalia-shell).

## Roadmap

- [ ] Import Omarchy's shell and fix it for Qt 6.12
- [ ] Drop the distribution parts (updates, installers, Dropbox)
- [ ] Rename to neko (`NEKO_PATH`, `neko-*` commands, `~/.config/neko`)
- [ ] Run it in place of Noctalia
- [ ] Noctalia look: Eldritch palette, translucent surfaces, floating capsule bar
- [ ] Keybindings with descriptions and a searchable cheat sheet
- [ ] Media keys through global shortcuts instead of a process per keypress
- [ ] One palette for every app (theme templates)
- [ ] Laptop lid and external monitor handling
- [ ] Panels: Wi-Fi QR code, speed test, AI agent usage, Tailscale
- [ ] Self-documenting `neko` commands and hooks
- [ ] A Claude Code skill describing the setup

## Credits

- [Omarchy](https://github.com/omacom/omarchy), © David Heinemeier Hansson, MIT. The shell, its plugins and its commands are derived from `omacom/omarchy` at `035ce29f`.
- [Noctalia](https://github.com/noctalia-dev/noctalia-shell), © 2025 noctalia-dev, MIT. neko-shell's visual style follows Noctalia.
