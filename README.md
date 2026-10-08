# neko-shell

A desktop shell for Hyprland, built on Quickshell: a bar that hangs from the top of the screen as tinted glass, a dynamic island that grows out of it for notifications, media, volume and face unlock, and panels, menus, pickers and a lock screen made of the same pieces.

## Features

- **The bar**: docked, floating or attached to the top edge, its widgets in capsule groups you arrange by dragging in Settings. Layout presets (UniBar puts everything in one centered group) are picked from little drawings of each.
- **The dynamic island**: notifications, the volume and brightness OSD, music, a Pomodoro timer and face unlock grow out of the bar's center and shrink back into it; the settings window opens out of it too.
- **Panels**: a control center (quick toggles, sliders, weather, wallpaper, displays and a month calendar with your Google or any iCal calendars), Wi-Fi and Bluetooth (on their own or side by side as one Connections widget), audio, power, system monitor, AI agent usage, Tailscale.
- **Lock screen**: your wallpaper blurred behind a block-letter clock (with a cat), and the island for face unlock, fingerprint or password. A crashed lock comes back with `neko lock restart`.
- **Idle**: locks after five minutes, turns the screens off while locked, secures the session before sleep, respects apps that keep the screen awake.
- **Colors**: Material You colors from the wallpaper, or the fixed neko palette, applied to kitty, btop, tmux and GTK as well.
- **Wallpapers**: a picker, a randomizer and rotation on a timer.
- **Displays**: every Hyprland monitor setting in the control center, several displays arranged by dragging, with a 15-second undo for risky changes; laptop lid handling.
- **One command**: `neko` for everything, with built-in help.

## Requirements

- [Hyprland](https://hyprland.org) 0.56 or newer, with a Lua config (`~/.config/hypr/hyprland.lua`)
- [Quickshell](https://quickshell.org), a recent build (`quickshell-git` on the AUR)
- The packages in [`deps.txt`](deps.txt): a handful are required, most add one feature each

neko is developed on Arch Linux, and `deps.txt` names Arch packages; on other distributions it serves as a list of what to look for.

## Install

```bash
git clone <this repository> ~/.local/share/neko-shell
cd ~/.local/share/neko-shell
./install.sh
```

`install.sh` works from wherever you cloned to, as your user (never root), and installs no packages. It:

1. checks the dependencies in `deps.txt` and prints the `pacman` (and AUR helper) command for whatever is missing;
2. puts a `neko` launcher in `~/.local/bin`;
3. writes `~/.config/neko/env` and the default `~/.config/neko/shell.json`, if they aren't there yet;
4. adds a marked block to your `hyprland.lua` (after backing it up next to it) that loads neko's Hyprland module and starts neko at login;
5. checks that a PAM profile exists for the lock screen, and offers to start neko right away.

Run it again any time; it leaves what's already set up alone. `./install.sh --check` only reports dependencies; `./install.sh --yes` takes the defaults without asking.

## First steps

| Keys / command | What it does |
|---|---|
| `Super+Alt+Space` | The neko menu: apps, settings, captures, power |
| `Super+/` | Every keybinding, searchable |
| `Super+W` | Pick a wallpaper |
| `Ctrl+Alt+L` | Lock the screen |
| `neko settings` | The settings window (`neko settings widgets` opens a tab) |

Click the clock for the control center.

## The neko command

```bash
neko                         # what neko can do, by group
neko settings                # the settings window
neko open control-center     # open a panel or window (neko close ... closes it)
neko lock                    # lock now; neko lock restart brings a crashed lock back
neko wallpaper random        # any command: neko <group> <command>
neko pomodoro start          # anything the running shell answers: neko <target> <method>
neko session restart         # restart the shell
```

Every command explains itself with `--help`; `neko commands --all` lists them all.

## Configuration

Most of it is in the settings window. Underneath:

- `~/.config/neko/shell.json`: the bar's layout and widgets, and which plugins run. Turn off a service another tool handles with `"disabledPlugins": ["neko.idle", "neko.lock"]`.
- `~/.config/neko/calendars`: the calendar feeds the control center shows (Settings → Calendars manages it).
- `~/.config/neko/env`: machine settings, read when neko starts:

| Variable | Purpose |
|---|---|
| `NEKO_QUICKSHELL` | The Quickshell binary to run (default `quickshell`) |
| `NEKO_THEME` | Theme from `themes/` to start with (default `neko`) |
| `NEKO_WALLPAPER` | Image to use until a background has been picked |
| `NEKO_WALLPAPER_DIR` | Folder `neko wallpaper` picks from (default `~/Pictures/wallpapers`) |
| `NEKO_THEME_APPS` | Apps that follow the theme: any of `kitty btop tmux gtk` |
| `NEKO_REPLACES` | Command that stops the bar or shell neko takes over from |
| `NEKO_RESTORES` | Command that brings it back when neko stops |

### Hooks

Scripts in `~/.config/neko/hooks/` run on events; `<name>.d/` folders run every script inside.

| Hook | When | Argument |
|---|---|---|
| `theme-set` | A theme is applied, including wallpaper Material colors | theme name |
| `wallpaper-set` | The wallpaper changes | image path |
| `session-start` | neko takes over the session | |
| `font-set` | The font changes | font name |
| `battery-low` | Battery runs low | |

## The lock screen

The lock checks passwords through PAM, using the first of `/etc/pam.d/neko-lock-password`, `/etc/pam.d/vlock` (Arch's base `kbd` package has it) or `/etc/pam.d/hyprlock`. With [Howdy](https://github.com/boltgolt/howdy) set up in `system-auth`, it looks for your face as soon as it locks; with fprintd and `/etc/pam.d/neko-lock-fingerprint`, a finger works too.

If the shell ever crashes while locked, Hyprland keeps the session locked behind a red screen. Switch to a TTY (`Ctrl+Alt+F2`), log in and run `neko lock restart`: the lock screen comes back on your session, and you unlock as usual.

## Updating

```bash
cd ~/.local/share/neko-shell
git pull
neko session restart
```

## Uninstalling

```bash
./install.sh --uninstall
```

That stops neko, removes the launcher and takes neko's block out of `hyprland.lua` (with a backup). Your settings stay in `~/.config/neko` and `~/.local/state/neko`; delete those folders to remove everything.

## Security

See [SECURITY.md](SECURITY.md) for how neko handles root, the lock screen and your data, what it connects to, and how to report a problem privately.

## License

MIT; see [LICENSE](LICENSE). neko-shell was inspired by many projects in the Linux desktop community, and includes MIT-licensed code whose copyright notice is kept in LICENSE. The AI providers' logos in `shell/plugins/agents/assets` are trademarks of their owners, shown only to name their services.
