import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons

// Live activities for the island: something copied, a Bluetooth device
// connecting or going (with its battery, when it says), the charger plugged
// in or out, and the battery passing 20% and 10% on its way down. The Bluetooth devices are read
// into plain values every couple of seconds rather than held: BlueZ can take
// a device object away while something still has it, which crashes the shell.
// Nothing is shown for what's already so when the shell starts.
Item {
  id: root

  property var shell: null

  // address -> { name, icon, battery } for what's connected now
  property var connected: ({})
  property bool settled: false
  property int lowWarned: 100

  readonly property bool batteryPresent: !!UPower.displayDevice && UPower.displayDevice.isPresent
  readonly property int percent: batteryPresent ? Math.round(UPower.displayDevice.percentage * (UPower.displayDevice.percentage <= 1 ? 100 : 1)) : -1

  function deviceIcon(icon) {
    var kind = String(icon || "")
    if (/headset|headphone|audio-card/.test(kind)) return "󰋋"
    if (/phone/.test(kind)) return "󰄜"
    if (/keyboard/.test(kind)) return "󰌌"
    if (/mouse/.test(kind)) return "󰍽"
    if (/gaming|joystick/.test(kind)) return "󰊴"
    return "󰂱"
  }

  function snapshot() {
    var now = ({})
    var devices = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (!d || !d.connected || !d.address) continue
      now[d.address] = {
        name: String(d.deviceName || d.name || "Bluetooth device"),
        icon: root.deviceIcon(d.icon),
        battery: d.batteryAvailable ? Math.round(d.battery * 100) : -1
      }
    }
    return now
  }

  function checkBluetooth() {
    var now = snapshot()
    if (root.settled) {
      for (var address in now) {
        if (root.connected[address]) continue
        var device = now[address]
        Island.showActivity({ icon: device.icon, title: device.name + " connected", detail: device.battery >= 0 ? "Battery " + device.battery + "%" : "" }, 2600)
      }
      for (var gone in root.connected) {
        if (now[gone]) continue
        Island.showActivity({ icon: root.connected[gone].icon, title: root.connected[gone].name + " disconnected", detail: "", tint: NekoColor.foreground }, 2200)
      }
    }
    root.connected = now
  }

  function timeText(seconds) {
    if (!seconds || seconds <= 0) return ""
    var hours = Math.floor(seconds / 3600), minutes = Math.round(seconds % 3600 / 60)
    return hours > 0 ? hours + " h " + minutes + " min" : minutes + " min"
  }

  function checkLow() {
    if (!root.batteryPresent || !UPower.onBattery) {
      root.lowWarned = 100
      return
    }
    var mark = root.percent <= 10 ? 10 : root.percent <= 20 ? 20 : 100
    if (mark < root.lowWarned) {
      root.lowWarned = mark
      if (root.settled) {
        var left = root.timeText(UPower.displayDevice.timeToEmpty)
        Island.showActivity({ icon: mark <= 10 ? "󰂃" : "󰁻", title: "Battery at " + root.percent + "%", detail: left ? "About " + left + " left" : "Plug in soon", tint: NekoColor.urgent }, 3500)
      }
    }
  }

  // Each copy, as a line: "image", or "text" and its first few hundred
  // characters. Copies marked sensitive (passwords) never get this far.
  Process {
    id: clipboardWatch
    running: true
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--watch", "bash", "-c",
      "case ${CLIPBOARD_STATE:-data} in sensitive|clear|nil) exit 0 ;; esac; "
      + "types=$(wl-paste --list-types 2>/dev/null); grep -qx x-kde-passwordManagerHint <<< \"$types\" && exit 0; "
      + "if grep -q '^image/' <<< \"$types\"; then echo image; "
      + "else printf 'text\\t'; wl-paste --no-newline --type text 2>/dev/null | head -c 300 | tr '\\n\\t\\r' '   '; echo; fi"]
    stdout: SplitParser {
      onRead: function(line) {
        if (!root.settled) return
        if (line === "image") {
          Island.showActivity({ icon: "󰋩", title: "Image copied", detail: "" }, 2000)
          return
        }
        var text = line.indexOf("text\t") === 0 ? line.slice(5).replace(/\s+/g, " ").trim() : ""
        Island.showActivity({ icon: "󰅌", title: "Copied", detail: text }, 2000)
      }
    }
    onExited: clipboardRewatch.restart()
  }

  Timer {
    id: clipboardRewatch
    interval: 3000
    onTriggered: clipboardWatch.running = true
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      if (!root.settled || !root.batteryPresent) return
      if (UPower.onBattery) {
        var left = root.timeText(UPower.displayDevice.timeToEmpty)
        Island.showActivity({ icon: "󰂃", title: "On battery · " + root.percent + "%", detail: left ? "About " + left + " left" : "", tint: NekoColor.foreground }, 2400)
      } else {
        var full = root.timeText(UPower.displayDevice.timeToFull)
        Island.showActivity({ icon: "󰂄", title: "Charging · " + root.percent + "%", detail: full ? "Full in about " + full : "" }, 2400)
      }
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      root.checkBluetooth()
      root.checkLow()
    }
  }

  Timer {
    interval: 4000
    running: true
    onTriggered: root.settled = true
  }
}
