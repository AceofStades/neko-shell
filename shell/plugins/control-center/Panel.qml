import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "../panels/monitor/Model.js" as MonitorModel

// The cat button and its control center: quick toggles, volume and
// brightness, weather and wallpaper in one popup. Left click opens it,
// right click opens the neko menu.
Panel {
  id: root
  moduleName: "neko.control-center"
  ipcTarget: "neko.control-center"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: NekoColor.popups.text
  readonly property color dim: Util.alpha(NekoColor.popups.text, 0.6)
  readonly property color accent: NekoColor.accent
  readonly property string fontFamily: Style.font.family

  // State read when the popup opens
  property string uptime: ""
  property string weatherIcon: ""
  property string weatherText: ""
  property string ssid: ""
  property bool dnd: false
  property bool stayAwake: false
  property string rotation: ""
  property int reminders: 0
  property bool recorderInstalled: false
  property bool recording: false
  property real brightness: 0
  property var displays: []

  readonly property var scalePresets: ["1", "1.25", "1.5", "1.6", "2", "3", "4"]
  readonly property var focusedDisplay: {
    for (var i = 0; i < displays.length; i++) if (displays[i].focused) return displays[i]
    return displays.length > 0 ? displays[0] : null
  }
  readonly property var scaleOptions: focusedDisplay
    ? MonitorModel.availableScales(scalePresets, focusedDisplay.width, focusedDisplay.height)
    : []
  readonly property int enabledDisplays: displays.filter(function(d) { return !d.disabled }).length

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var adapter: Bluetooth.defaultAdapter

  onOpenedChanged: if (opened) refresh()

  function refresh() {
    stateProc.running = false
    stateProc.running = true
    if (!weatherProc.running) weatherProc.running = true
  }

  // Run a command, then read the state again
  function act(command) {
    actionProc.command = ["bash", "-c", command]
    actionProc.running = true
  }

  function runAndClose(command) {
    root.close()
    Quickshell.execDetached(["bash", "-c", command])
  }

  PwObjectTracker { objects: root.sink ? [root.sink] : [] }

  // One shell round trip for every toggle's state, as key=value lines
  Process {
    id: stateProc
    command: ["bash", "-c", [
      "echo uptime=$(uptime -p | sed 's/^up //')",
      "echo ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | awk -F: '$1==\"yes\"{print $2; exit}')",
      "echo dnd=$(neko-shell notifications isDnd 2>/dev/null)",
      "echo awake=$(neko-toggle-idle status | jq -r .enabled)",
      "echo rotation=$(cat ~/.config/neko/wallpaper-rotation 2>/dev/null)",
      "echo reminders=$(neko-reminder show --json 2>/dev/null | jq -r .count)",
      "echo recorder=$(command -v gpu-screen-recorder >/dev/null && echo yes)",
      "echo recording=$(pgrep -f '^gpu-screen-recorder' >/dev/null && echo yes)",
      "echo brightness=$(brightnessctl -m | awk -F, '{print $3/$5}')",
      "echo displays=$(hyprctl monitors all -j | jq -c '[.[] | {name, width, height, scale, focused, disabled}]')"
    ].join("; ")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var at = lines[i].indexOf("=")
          if (at < 0) continue
          var key = lines[i].slice(0, at)
          var value = lines[i].slice(at + 1)
          if (key === "uptime") root.uptime = value
          else if (key === "ssid") root.ssid = value
          else if (key === "dnd") root.dnd = value === "on"
          else if (key === "awake") root.stayAwake = value === "true"
          else if (key === "rotation") root.rotation = value
          else if (key === "reminders") root.reminders = Number(value) || 0
          else if (key === "recorder") root.recorderInstalled = value === "yes"
          else if (key === "recording") root.recording = value === "yes"
          else if (key === "brightness" && !brightnessSlider.dragging) root.brightness = Number(value) || 0
          else if (key === "displays") { try { root.displays = JSON.parse(value) } catch (e) {} }
        }
      }
    }
  }

  Process {
    id: weatherProc
    command: ["bash", "-c", "echo \"$(neko-weather-icon)\"; neko-weather-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n")
        root.weatherIcon = lines[0] || ""
        root.weatherText = (lines[1] || "").replace(/\s+·\s+/g, "  ·  ")
      }
    }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  // Brightness follows the slider without a process per pixel of drag
  Timer {
    id: brightnessDebounce
    interval: 60
    onTriggered: Quickshell.execDetached(["brightnessctl", "-q", "set", Math.max(1, Math.round(root.brightness * 100)) + "%"])
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰄛"
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.bar.run("neko-shell shell toggle neko.menu '{\"menu\":\"root\"}'")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        // Header: who and how long, with settings, lock and power
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          Text {
            text: "󰄛"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }
          ColumnLayout {
            spacing: 0
            Layout.fillWidth: true
            Text {
              text: Quickshell.env("USER") || "neko"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
              text: root.uptime ? "up " + root.uptime : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
          PanelActionButton {
            iconText: "󰒓"
            tooltipText: "Settings"
            foreground: root.foreground
            onClicked: root.runAndClose("neko-shell shell summon neko.settings '{}'")
          }
          PanelActionButton {
            iconText: "󰌾"
            tooltipText: "Lock"
            foreground: root.foreground
            onClicked: root.runAndClose("loginctl lock-session")
          }
          PanelActionButton {
            iconText: "󰐥"
            tooltipText: "Power"
            foreground: root.foreground
            onClicked: root.runAndClose("neko-menu summon system")
          }
        }

        // Weather
        Rectangle {
          Layout.fillWidth: true
          // Hidden while the weather can't be fetched rather than saying so
          visible: root.weatherIcon !== "" && root.weatherText !== ""
          implicitHeight: weatherRow.implicitHeight + Style.space(20)
          radius: Style.space(14)
          color: Util.alpha(root.foreground, 0.06)

          RowLayout {
            id: weatherRow
            anchors.fill: parent
            anchors.margins: Style.space(10)
            spacing: Style.space(10)
            Text {
              text: root.weatherIcon
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }
            Text {
              Layout.fillWidth: true
              text: root.weatherText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }
          }
        }

        // Quick toggles
        GridLayout {
          Layout.fillWidth: true
          columns: 2
          rowSpacing: Style.space(8)
          columnSpacing: Style.space(8)

          QuickTile {
            icon: Networking.wifiEnabled ? "󰖩" : "󰖪"
            label: "Wi-Fi"
            subtitle: Networking.wifiEnabled ? (root.ssid || "On") : "Off"
            active: Networking.wifiEnabled
            onClicked: { Networking.wifiEnabled = !Networking.wifiEnabled; root.refresh() }
          }
          QuickTile {
            icon: root.adapter && root.adapter.enabled ? "󰂯" : "󰂲"
            label: "Bluetooth"
            subtitle: root.adapter ? (root.adapter.enabled ? "On" : "Off") : "No adapter"
            active: !!root.adapter && root.adapter.enabled
            onClicked: if (root.adapter) root.adapter.enabled = !root.adapter.enabled
          }
          QuickTile {
            icon: root.dnd ? "󰂛" : "󰂚"
            label: "Do not disturb"
            subtitle: root.dnd ? "On" : "Off"
            active: root.dnd
            onClicked: root.act("neko-shell notifications toggleDnd")
          }
          QuickTile {
            icon: "󰅶"
            label: "Stay awake"
            subtitle: root.stayAwake ? "On" : "Off"
            active: root.stayAwake
            onClicked: root.act("neko-toggle-idle toggle")
          }
          QuickTile {
            icon: "󰀠"
            label: "Reminders"
            subtitle: root.reminders > 0 ? root.reminders + " set" : "Set one"
            active: root.reminders > 0
            Layout.columnSpan: root.recorderInstalled ? 1 : 2
            onClicked: root.runAndClose("neko-reminder -i")
          }
          QuickTile {
            visible: root.recorderInstalled
            icon: "󰑊"
            label: "Screen record"
            subtitle: root.recording ? "Recording" : "Off"
            active: root.recording
            onClicked: root.recording
              ? root.act("neko-capture-screenrecording --stop-recording")
              : root.runAndClose("neko-menu toggle trigger.capture.screenrecord")
          }
          QuickTile {
            icon: "󰁪"
            label: "Wallpaper rotation"
            Layout.columnSpan: 2
            subtitle: root.rotation ? "Every " + root.rotation + " min" : "Off"
            active: root.rotation !== ""
            onClicked: root.act(root.rotation ? "neko-wallpaper auto off" : "neko-wallpaper auto 30")
          }
        }

        // Volume and brightness
        SliderRow {
          icon: root.sink && root.sink.audio && root.sink.audio.muted ? "󰝟" : "󰕾"
          visible: !!(root.sink && root.sink.audio)
          PanelSlider {
            Layout.fillWidth: true
            bar: root.bar
            value: root.sink && root.sink.audio ? root.sink.audio.volume : 0
            onMoved: function(v) { if (root.sink && root.sink.audio) root.sink.audio.volume = v }
          }
        }
        SliderRow {
          icon: "󰃟"
          PanelSlider {
            id: brightnessSlider
            Layout.fillWidth: true
            bar: root.bar
            minimum: 0.01
            value: root.brightness
            onMoved: function(v) { root.brightness = v; brightnessDebounce.restart() }
          }
        }

        // Display: scale for the focused screen, and on/off once there are several
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.scaleOptions.length > 0

          Text {
            text: "Display scale" + (root.focusedDisplay && root.displays.length > 1 ? " · " + root.focusedDisplay.name : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          ButtonGroup {
            Layout.fillWidth: true
            fontSize: Style.font.bodySmall
            options: root.scaleOptions.map(function(v) { return { value: String(v), label: v + "x" } })
            value: root.focusedDisplay ? MonitorModel.normalizeScale(root.focusedDisplay.scale) : ""
            onChanged: function(v) { root.act("neko-hyprland-monitor-scaling " + v) }
          }
        }
        Repeater {
          model: root.displays.length > 1 ? root.displays : []
          delegate: RowLayout {
            required property var modelData
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: modelData.name + "  " + modelData.width + "x" + modelData.height
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            ToggleSwitch {
              checked: !modelData.disabled
              // Never switch off the last screen that's on
              interactive: modelData.disabled || root.enabledDisplays > 1
              onToggled: {
                var output = JSON.stringify(String(modelData.name))
                root.act(modelData.disabled
                  ? "hyprctl eval 'hl.monitor({ output = " + output + ", disabled = false, mode = \"preferred\", position = \"auto\", scale = \"auto\" })'"
                  : "hyprctl eval 'hl.monitor({ output = " + output + ", disabled = true })'")
              }
            }
          }
        }

        // Wallpaper
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Button {
            Layout.fillWidth: true
            iconText: "󰋩"
            text: "Pick wallpaper"
            bordered: true
            onClicked: root.runAndClose("neko-wallpaper pick")
          }
          Button {
            Layout.fillWidth: true
            iconText: "󰒝"
            text: "Random"
            bordered: true
            onClicked: root.act("neko-wallpaper random")
          }
        }
      }
    }
  }

  component QuickTile: Rectangle {
    id: tile
    property string icon: ""
    property string label: ""
    property string subtitle: ""
    property bool active: false
    signal clicked()

    Layout.fillWidth: true
    implicitHeight: Style.space(56)
    radius: Style.space(14)
    color: active ? Util.alpha(root.accent, tileArea.containsMouse ? 0.32 : 0.24)
                  : Util.alpha(root.foreground, tileArea.containsMouse ? 0.10 : 0.06)

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: tile.icon
        color: tile.active ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
      ColumnLayout {
        spacing: 0
        Layout.fillWidth: true
        Text {
          Layout.fillWidth: true
          text: tile.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.weight: Font.Medium
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          text: tile.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: tileArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
  }

  component SliderRow: RowLayout {
    property string icon: ""
    default property alias slider: sliderSlot.data

    Layout.fillWidth: true
    spacing: Style.space(10)

    Text {
      text: parent.icon
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
      Layout.preferredWidth: Style.space(22)
    }
    RowLayout {
      id: sliderSlot
      Layout.fillWidth: true
    }
  }
}
