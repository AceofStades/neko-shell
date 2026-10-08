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
- `hyprctl output create headless NAME` adds a pretend display for testing multi-display features (`hyprctl output remove NAME` when done); each display gets its own bar, so the duplicate IPC handler warnings that follow are expected.
- `neko commands --check` validates the `# neko:summary=` / `# neko:args=` metadata every command carries.
- Don't run `bash -x` or test loops from zsh with unquoted variables (zsh doesn't word-split); use `bash -c` or a script.

## Pitfalls

- Qt 6.12's QtQuick exports a `Color` type that shadows any QML singleton named `Color`, so the theme singleton is `NekoColor`. Don't add singletons named after Qt types (`Color`, `Palette`).
- `hyprctl dispatch` takes Lua in this setup: `hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'`, not `dpms on`. `hyprctl eval '<lua>'` changes Hyprland at runtime; a config reload undoes it.
- Adding a bar widget while the shell runs rebuilds the bar's widgets before the old ones are gone. Quickshell keeps only the first IpcHandler per target and never promotes a later one, so those panels drop out of `qs ipc` until the next restart; neko's own socket (what `neko-shell` uses when socat is installed) tracks handlers itself and keeps working. Don't try to fix it by toggling a handler's `enabled` on unregister: that crashes Quickshell (SIGSEGV in its handler registry).
- `hl.monitor` keeps any field a later call leaves out, so going back to a default at runtime takes `hyprctl reload` (`neko-display` does this).
- `hyprctl monitors` gives `mirrorOf` as the mirrored display's id, not its name; `neko-display json` turns it into the name.
- QML `Timer`s were seen to stall while an open panel drew nothing new, and the shell can stall with a screen that's gone dark. Deadlines that must hold (like `neko-display`'s 15-second undo) run as their own process, and countdowns read `SystemClock`.
- Qt's font fallback can draw boxes for CJK text when several files share a family name (every Droid Sans face is "Droid Sans"), and whether it does depends on which fonts happen to be loaded. Load the file `fc-match :lang=ja` names with a `FontLoader` and use its family, as the workspaces widget does.
- A killed shell leaves its `Process` children running, re-parented to init, so every restart adds another long-running watcher. Start those under `setpriv --pdeathsig TERM` so the kernel ends them with the shell, or read the file they'd watch with a `FileView` instead (as the OSD does for the keyboard backlight).
- Restarting the shell while the session is locked kills the lock screen and strands the lock (check `neko-hyprland-session-locked` first; exit 0 means locked). The next shell takes it back over, which needs `misc:allow_session_lock_restore` (set in `default/hypr/neko.lua`); without it Hyprland answers with a protocol error and the shell crash-loops until `neko-session` gives up.
- Theme sections override whole `[section]`s via `themes/<name>/shell.<section>.toml`; `neko-theme-material` builds a theme from the wallpaper by recoloring `themes/neko`'s files, so new colors in those files need a mapping there.
