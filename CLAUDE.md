# neko-shell

A Quickshell desktop for Hyprland (Lua config). `shell/` is the QML desktop (bar, panels, menus, OSD, notifications, pickers), `bin/` the `neko-*` commands it calls, `default/` the menu, Hyprland module and theme templates, `config/neko/` the default `shell.json`, `themes/` the shipped themes.

## Rules

- Commits are unsigned (`commit.gpgsign=false` is set in this repo) and carry **no attribution trailers** (no Co-Authored-By, no session links). Keep each commit to one coherent change.
- No upstream names in code, comments or docs. The README says only that neko was inspired by other projects; `LICENSE` keeps the required MIT copyright lines and must not lose them.
- Never add package installers, updaters or migrations. Commands that would install something should fail with a clear message instead.
- Anything that needs root runs from a root-owned path (see `bin/neko-dns`), never from this user-writable checkout.
- Markdown: full lines, no hard wrapping. Bash: `#!/bin/bash`, two-space indent, `[[ ]]` for strings and files, `(( ))` for numbers.

## Working on it

- After editing QML, run `bin/neko-session restart`, then check `journalctl --user -t neko-shell --since -30s` for `WARN`/`ERROR` lines. Harmless ones: `inotifywait` missing, `propertyCache`, `desktopentry`, `Deleted existing file`, `Qt.atob`.
- `neko-session theme` re-renders the theme and applies it live; `neko-session start|stop` swaps neko in and out of the session.
- Commands need `NEKO_PATH=<checkout> PATH=<checkout>/bin:$PATH`; `~/.config/neko/env` holds machine settings and is sourced by `neko-session` (`NEKO_QUICKSHELL` points at the Quickshell build to use).
- `neko-shell <target> <method> [args]` talks to the running shell; `neko-shell shell debugBarGeometry` reports every bar widget's position and size, which is the way to check layout changes without a screenshot.
- `neko commands --check` validates the `# neko:summary=` / `# neko:args=` metadata every command carries.
- Don't run `bash -x` or test loops from zsh with unquoted variables (zsh doesn't word-split); use `bash -c` or a script.

## Pitfalls

- Qt 6.12's QtQuick exports a `Color` type that shadows any QML singleton named `Color`, so the theme singleton is `NekoColor`. Don't add singletons named after Qt types (`Color`, `Palette`).
- `hyprctl dispatch` takes Lua in this setup: `hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'`, not `dpms on`. `hyprctl eval '<lua>'` changes Hyprland at runtime; a config reload undoes it.
- Adding a bar widget while the shell runs rebuilds the bar's widgets before the old ones are gone. Quickshell keeps only the first IpcHandler per target and never promotes a later one, so those panels drop out of `qs ipc` until the next restart; neko's own socket (what `neko-shell` uses when socat is installed) tracks handlers itself and keeps working. Don't try to fix it by toggling a handler's `enabled` on unregister: that crashes Quickshell (SIGSEGV in its handler registry).
- Theme sections override whole `[section]`s via `themes/<name>/shell.<section>.toml`; `neko-theme-material` builds a theme from the wallpaper by recoloring `themes/neko`'s files, so new colors in those files need a mapping there.
