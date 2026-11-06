import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui

// The control center's page for staying awake: keeping the screen on, how
// long idle takes before the screensaver and the lock, whether the machine
// may sleep at all, and on a laptop, working on with the lid closed (lit in
// the urgent color on battery, which drains with the lid shut). Each goes
// through neko-settings, or neko-toggle-idle for staying awake.
ColumnLayout {
  id: root

  property color foreground: NekoColor.popups.text
  property color dim: Util.alpha(foreground, 0.6)
  property color accent: NekoColor.accent
  property string fontFamily: Style.font.family

  property bool stayAwake: false
  property string screensaver: "150"
  property string lock: "300"
  property bool sleepAllowed: true
  property bool lidAwake: false
  property bool hasLid: false

  readonly property bool onBattery: UPower.onBattery && !!UPower.displayDevice && UPower.displayDevice.isPresent

  signal back()
  signal changed()

  spacing: Style.space(12)

  function load() {
    if (!reader.running) reader.running = true
  }

  function run(command) {
    Quickshell.execDetached(["bash", "-c", command + "; true"])
    reloadSoon.restart()
  }

  Process {
    id: reader
    command: ["bash", "-c", [
      "echo awake=$(neko-toggle-idle status | jq -r .enabled)",
      "echo screensaver=$(neko-settings get idle.screensaver)",
      "echo lock=$(neko-settings get idle.lock)",
      "echo sleep=$(neko-settings get sleep)",
      "echo lid=$(neko-settings get lid.awake)",
      "echo haslid=$(ls /proc/acpi/button/lid/*/state > /dev/null 2>&1 && echo yes)"
    ].join("; ")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        String(text || "").split("\n").forEach(function(line) {
          var at = line.indexOf("=")
          if (at < 0) return
          var key = line.slice(0, at), value = line.slice(at + 1)
          if (key === "awake") root.stayAwake = value === "true"
          else if (key === "screensaver") root.screensaver = value
          else if (key === "lock") root.lock = value
          else if (key === "sleep") root.sleepAllowed = value !== "off"
          else if (key === "lid") root.lidAwake = value === "on"
          else if (key === "haslid") root.hasLid = value === "yes"
        })
      }
    }
  }

  Timer {
    id: reloadSoon
    interval: 400
    onTriggered: {
      root.load()
      root.changed()
    }
  }

  Component.onCompleted: load()

  // Header
  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(6)
    PanelActionButton {
      iconText: "󰅁"
      tooltipText: "Back"
      foreground: root.foreground
      onClicked: root.back()
    }
    Text {
      Layout.fillWidth: true
      text: "Staying awake"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.weight: Font.DemiBold
    }
  }

  // The big switch: nothing idles while it's on
  Card {
    lit: root.stayAwake
    SettingLine {
      glyph: "󰅶"
      title: "Stay awake"
      detail: root.stayAwake ? "The screen stays on: no screensaver, lock or sleep while you're away" : "Idle goes to the screensaver, then the lock, as set below"
      checked: root.stayAwake
      onToggled: {
        root.stayAwake = !root.stayAwake
        root.run("neko-toggle-idle toggle")
      }
    }
  }

  // When idle, and whether it sleeps
  Card {
    opacity: root.stayAwake ? 0.5 : 1
    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(10)
      Caption { text: "Screensaver after" }
      ButtonGroup {
        Layout.fillWidth: true
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        options: [{ value: "0", label: "Never" }, { value: "60", label: "1 min" }, { value: "150", label: "2½ min" }, { value: "300", label: "5 min" }, { value: "600", label: "10 min" }]
        value: root.screensaver
        onChanged: function(v) { root.screensaver = v; root.run("neko-settings set idle.screensaver " + v) }
      }
      Caption { text: "Lock after" }
      ButtonGroup {
        Layout.fillWidth: true
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        options: [{ value: "0", label: "Never" }, { value: "300", label: "5 min" }, { value: "600", label: "10 min" }, { value: "900", label: "15 min" }, { value: "1800", label: "30 min" }]
        value: root.lock
        onChanged: function(v) { root.lock = v; root.run("neko-settings set idle.lock " + v) }
      }
      SettingLine {
        Layout.topMargin: Style.space(4)
        glyph: "󰒲"
        title: "Let it sleep"
        detail: root.sleepAllowed ? "Sleep works from the power menu and the lid" : "It stays up: sleep is off everywhere"
        checked: root.sleepAllowed
        onToggled: {
          root.sleepAllowed = !root.sleepAllowed
          root.run("neko-settings set sleep " + (root.sleepAllowed ? "on" : "off"))
        }
      }
    }
  }

  // The lid: only on a machine that has one
  Card {
    visible: root.hasLid
    lit: root.lidAwake
    warn: root.lidAwake && root.onBattery
    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      SettingLine {
        glyph: "󰌢"
        title: "Keep working with the lid closed"
        detail: root.lidAwake ? "Closing the lid only turns the screen off" : "Closing the lid puts it to sleep"
        checked: root.lidAwake
        tint: root.lidAwake && root.onBattery ? NekoColor.urgent : root.accent
        onToggled: {
          root.lidAwake = !root.lidAwake
          root.run("neko-settings set lid.awake " + (root.lidAwake ? "on" : "off"))
        }
      }
      Text {
        Layout.fillWidth: true
        visible: root.lidAwake && root.onBattery
        text: "On battery: it keeps draining with the lid shut"
        color: NekoColor.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
      Caption {
        Layout.fillWidth: true
        text: "With a monitor plugged in, closing the lid always just turns the laptop's own screen off."
        wrapMode: Text.WordWrap
      }
    }
  }

  component Caption: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // A rounded section, tinted when what it holds is on
  component Card: Rectangle {
    id: card
    property bool lit: false
    property bool warn: false
    default property alias content: inner.data
    Layout.fillWidth: true
    implicitHeight: inner.implicitHeight + Style.space(28)
    radius: Style.space(16)
    color: warn ? Util.alpha(NekoColor.urgent, 0.1) : lit ? Util.alpha(root.accent, 0.1) : Util.alpha(root.foreground, 0.05)
    border.width: 1
    border.color: warn ? Util.alpha(NekoColor.urgent, 0.35) : lit ? Util.alpha(root.accent, 0.3) : Util.alpha(root.foreground, 0.08)
    Behavior on color { ColorAnimation { duration: Style.duration(160) } }
    ColumnLayout {
      id: inner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(14)
      spacing: Style.space(8)
    }
  }

  // An icon, what it is, a line on what it does now, and its switch
  component SettingLine: RowLayout {
    id: row
    property string glyph: ""
    property string title: ""
    property string detail: ""
    property bool checked: false
    property color tint: root.accent
    signal toggled()
    Layout.fillWidth: true
    spacing: Style.space(12)
    Rectangle {
      implicitWidth: Style.space(36)
      implicitHeight: implicitWidth
      radius: width / 2
      color: row.checked ? Util.alpha(row.tint, 0.2) : Util.alpha(root.foreground, 0.07)
      Text {
        anchors.centerIn: parent
        text: row.glyph
        color: row.checked ? row.tint : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
    }
    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(1)
      Text {
        Layout.fillWidth: true
        text: row.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        text: row.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
    ToggleSwitch {
      checked: row.checked
      foreground: root.foreground
      accent: row.tint
      onToggled: row.toggled()
    }
  }
}
