# Neko bar

This is the Quickshell implementation of the Neko status bar. It is
shipped as a first-party plugin of [`neko-shell`](../../README.md), the
long-running shell host. The bar is mounted at startup and lives inside
the shell for its whole session.

- `manifest.json` declares the plugin (`id: neko.bar`, `kind: bar`) and points at `Bar.qml` as the entry point.
- `Bar.qml` is Neko-owned bar engine code, loaded by the neko-shell host. Users should not edit it directly.
- `widgets/` holds simple first-party bar widgets with sibling manifests.
- Feature plugins such as `../panels/audio/`, `../panels/network/`, `../panels/power/`, and `../agents/` provide richer popup bar plugins.
- The bar receives its config from the host shell as a `barConfig` property; the host loads it from `~/.config/neko/shell.json` (or `config/neko/shell.json` when the user has no file).
- `neko bar position` updates only the user shell.json file.

## Customizing

The bar config lives under the `bar:` key of [`~/.config/neko/shell.json`](../../../docs/neko-shell.md#shelljson). Out of the box the shell uses [`config/neko/shell.json`](../../../config/neko/shell.json). Once you customize anything via the bar gestures, `neko bar ...`, or by editing shell.json directly, your file is canonical — there is no deep-merge.

The bar is configured directly on the bar itself: drag empty bar space (or click-and-hold) to move the bar to another screen edge, double-left-click empty center-bar space to toggle transparency, and drag widgets to reorder them. The `neko bar position`, `neko bar transparent`, `neko bar move`, and `neko bar set` commands do the same from scripts. Enable or disable widgets with `neko plugin enable` and `neko plugin disable` (widget ids come from `neko plugin list`).

Example `shell.json` (bar subtree only shown):

```json
{
  "version": 1,
  "bar": {
    "position": "top",
    "transparent": false,
    "glass": true,
    "centerAnchor": "neko.clock",
    "layout": {
      "left": [
        { "id": "neko.menu" },
        { "id": "neko.spacer", "size": 12 },
        { "id": "neko.workspaces" }
      ],
      "center": [
        { "id": "neko.media" },
        { "id": "neko.clock", "format": "HH:mm" }
      ],
      "right": [
        { "id": "neko.audio" },
        { "id": "neko.power" }
      ]
    }
  }
}
```

`glass` leaves the bar itself clear and puts each widget on blur, tinted only against its text (dark under light text, light under dark), so the widgets take their color from what's under them rather than from the theme. Its text is black, or white where the top of the wallpaper is dark, checked again whenever the wallpaper changes. `transparent` wins over it, so double-clicking the bar goes between the two.

`centerAnchor` pins one center module to the exact horizontal/vertical center and flanks others around it. Set to an empty string to disable anchoring (the center list is centered as a group).

## Module catalogue

### First-party interactive widgets

| Name | What it does | Interactions |
|---|---|---|
| `neko.menu` | Neko menu launcher | left = menu · right = terminal |
| `neko.workspaces` | Workspaces 1 to 10 in kanji; on a horizontal bar also the island, which grows out of them to show notifications and the OSD (volume, brightness...) in their place | left = focus workspace · on a notification: left = open it, right = dismiss, hover = hold it |
| `neko.system-monitor` | CPU, CPU temperature and memory as rings around their icons; a popup with every core, the temperatures, memory and swap, disks, network, battery draw and the busiest processes | left = popup · middle = btop |
| `neko.clock` | Date/time label + popup with a month grid, ISO week numbers, and month stepping | left = popup · right = cycle label format · middle = timezone selector |
| `neko.media` | MPRIS now-playing — scrolling track + artist, cover-art popup | left = play/pause · middle = next · scroll = prev/next · right = popup |
| `neko.indicators` | Manual state indicators | left = indicator action |
| `neko.tray` | System tray | hover = reveal drawer · right on chevron = manage |
| `neko.weather` | Weather icon + popup with forecast | left = popup · right = full notification |
| `neko.microphone` | Mic icon + scroll volume | left = mute toggle · middle = audio panel · scroll = source volume |

| `neko.audio` | Volume icon + popup with master slider, output-device picker, per-app mixer | left = popup · right = mute · middle = popup · scroll = volume |
| `neko.network` | Wi-Fi/Ethernet icon + popup with Wi-Fi scan, signal, connect, DNS provider selection | left = popup |
| `neko.tailscale` | Tailscale status, connection switcher, machine browser, and copy actions | left = popup · right = toggle · middle = refresh |
| `neko.agents` | AI coding agent limits with pace, today, last week, and all-time model breakdown | left = panel · right = launch agent · middle = next subscription |
| `neko.power` | Battery/AC icon + popup with battery stats, power profiles, and system info | left = popup · right = toggle percentage |
| `neko.bluetooth` | Bluetooth icon + popup with device list, connect/disconnect, battery | left = popup · right = toggle radio |
| `neko.monitor` | Brightness and laptop display controls | left = popup |

The `neko.indicators` widget loads individual bar indicators from `indicators/`. Omit `items` (or set it to an empty array) to show all indicators in the default order, or set `items` to a subset such as `["Dnd", "Reminder", "NightLight"]`. Set `alwaysShow` to `true` to keep inactive indicators visible instead of revealing them only on hover. Multiple `neko.indicators` instances are allowed, so different sections can show different subsets.

## Orientation

All widgets work in `top`, `bottom`, `left`, and `right` positions. Popups anchor on the side opposite the bar edge, sliding into the workspace. Vertical bars use 28px width; widgets that show text fall back to compact icon-only forms (e.g. `media` hides its scrolling label).

## Custom user modules

The schema accepts arbitrary module ids that you provide. Set `type` to `command` for shell-driven output or `qml` for a custom QML widget. Both still go under `bar.layout.<section>` in `shell.json`.

Command module:

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        { "id": "neko.tray" },
        { "id": "vpn", "type": "command", "exec": "~/.config/neko/bar/scripts/vpn-status", "interval": 5, "tooltip": "VPN", "onClick": "nm-connection-editor" },
        { "id": "neko.audio" }
      ]
    }
  }
}
```

The command may print plain text or Waybar-style JSON, for example:

```json
{"text":"󰌆","tooltip":"Work VPN","class":"active"}
```

QML module:

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        { "id": "gpu", "type": "qml" },
        { "id": "neko.audio" }
      ]
    }
  }
}
```

Then create `~/.config/neko/bar/modules/gpu.qml`. If you want to store it elsewhere, add a `source` path.

Custom QML modules should be an `Item` with `implicitWidth` and `implicitHeight`. They may optionally define these properties, which the bar fills after loading:

```qml
import QtQuick

Item {
  property var bar
  property string moduleName
  property var settings

  implicitWidth: 28
  implicitHeight: bar ? bar.barSize : 26

  Text {
    anchors.centerIn: parent
    text: "GPU"
    color: bar ? bar.foreground : "white"
    font.family: bar ? bar.fontFamily : "monospace"
    font.pixelSize: 12
  }

  MouseArea {
    anchors.fill: parent
    onClicked: if (bar) bar.run("neko-launch-or-focus-tui btop")
  }
}
```

## Bar properties available to widgets

Widgets receive `bar` (the shell root), `moduleName` (string), and `settings` (object) injected at load time. The bar exposes:

- `bar.foreground`, `bar.background`, `bar.urgent` — theme colors (live-updated)
- `bar.fontFamily` — current monospace family
- `bar.position` — `"top" | "bottom" | "left" | "right"`
- `bar.vertical` — boolean shortcut
- `bar.barSize` — 26 horizontal / 28 vertical
- `bar.run(command)` — fire-and-forget bash exec (quote arguments with `Util.shellQuote` from `qs.Commons`)
- `bar.showTooltip(target, text)` / `bar.hideTooltip(target)` — shared tooltip popup
- `bar.requestPopout(owner)` / `bar.releasePopout(owner)` — one-popup-at-a-time coordinator

First-party bar widgets are manifest-backed just like third-party widgets.
Simple widgets carry sibling manifests such as `widgets/Workspaces.manifest.json`;
richer popup plugins live in feature directories such as `../panels/audio/`,
`../panels/network/`, and `../agents/`; and feature plugins such as
`neko.menu` and `neko.media` declare their bar-widget entry points in their own
`manifest.json`. Bar layout ids are namespaced, e.g. `neko.audio`,
`neko.network`, and `neko.clock`.

Third-party widgets ship as separate plugins under `~/.config/neko/plugins/<plugin-id>/` with their own `manifest.json` declaring `kinds: ["bar-widget"]` and a `barWidget` entry point. See the [shell reference](../../../docs/neko-shell.md#plugin-manifest) for the manifest schema. Rescan, enable, and place third-party plugins with `neko-shell shell rescanPlugins`, `neko plugin enable`, and `neko bar move`.
