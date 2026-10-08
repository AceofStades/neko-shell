# Security

## Reporting a problem

Please report security problems privately, through this repository's "Report a vulnerability" button (GitHub's private vulnerability reporting), not in a public issue. Say what's affected and how to reproduce it; you'll get an answer there.

## How neko is put together

### It runs as you

The shell, its panels and the `neko-*` commands run as your user, from the checkout. `install.sh` never uses root and installs no packages: for anything missing it prints the command for you to run.

Two helpers can change system settings, and only when you set them up yourself:

- `neko-dns` (the DNS choice in Settings and the Wi-Fi panel) and `neko-theme-set-browser-policy` (browser colors) need root. They never run as root from the checkout, which you can write to: they run only from a root-owned copy you install, for example `sudo install -Dm755 bin/neko-dns /usr/local/bin/neko-dns`, and ask through sudo or polkit. As root they ignore your `PATH`.
- A few commands run a system tool through `sudo` and ask for your password in the terminal (`neko-menu-timezone` runs `timedatectl`).

### The lock screen

The lock is part of the shell and uses Wayland's session lock (ext-session-lock), so the compositor keeps the screen covered whatever the shell does. Passwords are checked through PAM, with the first profile of `/etc/pam.d/neko-lock-password`, `/etc/pam.d/vlock` (from Arch's base `kbd` package) or `/etc/pam.d/hyprlock`. Face unlock (Howdy) and fingerprint (fprintd) use their own PAM conversations. Typed passwords stay in memory only until PAM answers.

If the shell dies while the screen is locked, Hyprland keeps the session locked behind its own red failsafe screen. neko's Hyprland module turns on `misc:allow_session_lock_restore` so a new shell can take the lock over: from a TTY, `neko lock restart` brings the lock screen back. The trade-off is that any program running as you could take over a lock its predecessor left; a program running as you can already do whatever you can, so this adds no new reach.

### Talking to the shell

`neko <target> <method>` talks to the running shell over a socket in `$XDG_RUNTIME_DIR`, which only you can open. Any program running as you can drive the shell the same way.

### Your data

- Calendar addresses (`~/.config/neko/calendars`) are secrets; the file and the feed cache (`~/.cache/neko/calendars`) are readable only by you.
- Settings and state stay in `~/.config/neko` and `~/.local/state/neko`. Nothing is sent anywhere except the requests below.
- The lock screen keeps no copy of your screen; it shows your wallpaper.

### What it connects to

- Weather: `wttr.in` (which also guesses your city from your IP address unless you set one in Settings → System) and `open-meteo.com`.
- Connectivity checks: `ping.archlinux.org`, to notice Wi-Fi sign-in pages.
- Calendars: the iCal feeds you add.
- Speed test: `fast.com`, when you run it.
- Agent usage: the AI providers' APIs (Anthropic, OpenAI, xAI, Fireworks), with your own credentials, only for the agents you use.
