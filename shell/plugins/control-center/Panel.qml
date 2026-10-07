import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Pipewire
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "../panels/monitor/Model.js" as MonitorModel
import "../panels/weather/Model.js" as WeatherModel
import "../../services/BrightnessModel.js" as BrightnessModel

// The cat button and its control center: quick toggles, volume and
// brightness, weather and wallpaper in one popup. Left click opens it,
// right click opens the neko menu. The wallpaper and display tiles open pages
// of their own with their settings; Escape or the back button returns.
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
  // The last good weather report; a failed fetch keeps it rather than blanking the card
  property var weather: null
  // When it was fetched: it's fetched as the shell starts, so it's there on
  // the first open, and again on an open once it's a quarter of an hour old
  property real weatherFetched: 0
  readonly property var weatherNow: WeatherModel.openMeteoCurrentCondition(weather)
  readonly property var weatherDays: WeatherModel.openMeteoForecastDays(weather, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  property string ssid: ""
  property bool dnd: false
  property bool stayAwake: false
  property string rotation: ""
  property string wallpaper: ""
  property string colors: ""
  // "" for the main page, or "wallpaper" or "display" for their settings
  property string page: ""
  // The wallpaper's file name, readable: "a_red_alien.png" reads "a red alien"
  readonly property string wallpaperName: wallpaper.split("/").pop().replace(/\.[^.]*$/, "").replace(/[_-]+/g, " ")
  property int reminders: 0
  property bool recorderInstalled: false
  property bool recording: false
  // Brightness as a tick on the curve (0-64) and the backlight's raw maximum
  property int brightnessTick: 0
  property int brightnessMax: 0
  property var displays: []

  readonly property var focusedDisplay: {
    for (var i = 0; i < displays.length; i++) if (displays[i].focused) return displays[i]
    return displays.length > 0 ? displays[0] : null
  }

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var adapter: Bluetooth.defaultAdapter

  onOpenedChanged: if (opened) refresh(); else page = ""

  // Read ahead when the pointer comes to the button (see Bar's prefetch), so
  // the panel opens on current figures instead of filling in after
  function prefetch() { refresh() }

  function refresh() {
    stateProc.running = false
    stateProc.running = true
    if (!weatherProc.running && Date.now() - weatherFetched > 15 * 60 * 1000) weatherProc.running = true
  }

  Component.onCompleted: refresh()

  function rotationLabel(minutes) {
    return minutes === "60" ? "hour" : minutes + " min"
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
      "echo ssid=$(nmcli -t -f ACTIVE,SSID dev wifi list --rescan no 2>/dev/null | awk -F: '$1==\"yes\"{print $2; exit}')",
      "echo dnd=$(neko-shell notifications isDnd 2>/dev/null)",
      "echo awake=$(neko-toggle-idle status | jq -r .enabled)",
      "echo rotation=$(cat ~/.config/neko/wallpaper-rotation 2>/dev/null)",
      "echo wallpaper=$(readlink -f ~/.local/state/neko/current/background)",
      "echo colors=$(neko-settings get colors)",
      "echo reminders=$(neko-reminder show --json 2>/dev/null | jq -r .count)",
      "echo recorder=$(command -v gpu-screen-recorder >/dev/null && echo yes)",
      "echo recording=$(pgrep -f '^gpu-screen-recorder' >/dev/null && echo yes)",
      "echo brightness=$(brightnessctl -m | awk -F, '{print $3","$5}')",
      "echo displays=$(neko-display json)"
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
          else if (key === "wallpaper") root.wallpaper = value
          else if (key === "colors") root.colors = value
          else if (key === "reminders") root.reminders = Number(value) || 0
          else if (key === "recorder") root.recorderInstalled = value === "yes"
          else if (key === "recording") root.recording = value === "yes"
          else if (key === "brightness" && !brightnessSlider.dragging) {
            var reading = value.split(",")
            root.brightnessMax = Number(reading[1]) || 0
            if (root.brightnessMax > 0) root.brightnessTick = BrightnessModel.tickForRaw(Number(reading[0]) || 0, root.brightnessMax)
          }
          else if (key === "displays") { try { root.displays = JSON.parse(value) } catch (e) {} }
        }
      }
    }
  }

  Process {
    id: weatherProc
    command: ["neko-weather-report"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var report = JSON.parse(String(text || ""))
          if (report && report.current) {
            root.weather = report
            root.weatherFetched = Date.now()
          }
        } catch (e) {}
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
    onTriggered: if (root.brightnessMax > 0) Quickshell.execDetached(["brightnessctl", "-q", "set", String(BrightnessModel.rawForTick(root.brightnessTick, root.brightnessMax))])
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
    contentHeight: panel.fittedContentHeight(root.page === "wallpaper" ? wallpaperPage.implicitHeight
      : root.page === "display" ? displayPage.implicitHeight : column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: if (root.page) root.page = ""; else root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)
        visible: root.page === ""

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
          // Takes the free space so the buttons sit at the right edge
          Item { Layout.fillWidth: true }
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
            icon: root.displays.length > 1 ? "󰍺" : "󰍹"
            label: "Display"
            subtitle: root.displays.length > 1 ? root.displays.filter(function(d) { return d.enabled }).length + " of " + root.displays.length + " on"
              : root.focusedDisplay ? MonitorModel.normalizeScale(root.focusedDisplay.scale) + "x, " + Math.round(root.focusedDisplay.refreshRate) + " Hz" : ""
            opensPage: true
            onClicked: root.page = "display"
          }
          QuickTile {
            icon: "󰸉"
            label: "Wallpaper"
            subtitle: root.rotation ? "New one every " + root.rotationLabel(root.rotation) : root.wallpaperName
            active: root.rotation !== ""
            opensPage: true
            onClicked: root.page = "wallpaper"
          }
        }

        // Volume and brightness
        SliderRow {
          icon: root.sink && root.sink.audio && root.sink.audio.muted ? "󰝟" : "󰕾"
          label: root.sink && root.sink.audio ? Math.round(root.sink.audio.volume * 100) + "%" : ""
          visible: !!(root.sink && root.sink.audio)
          PanelSlider {
            Layout.fillWidth: true
            bar: root.bar
            value: root.sink && root.sink.audio ? root.sink.audio.volume : 0
            onMoved: function(v) { if (root.sink && root.sink.audio) root.sink.audio.volume = v }
          }
        }
        // Brightness moves by ticks on the curve: a mark per full step, the
        // wheel and drag landing on the fine steps between them
        SliderRow {
          icon: "󰃟"
          label: BrightnessModel.tickLabel(root.brightnessTick)
          visible: root.brightnessMax > 0
          PanelSlider {
            id: brightnessSlider
            Layout.fillWidth: true
            bar: root.bar
            maximum: BrightnessModel.ticks
            integer: true
            step: 1
            tickCount: BrightnessModel.ticks / BrightnessModel.ticksPerStep + 1
            tickColor: Qt.rgba(NekoColor.popups.background.r, NekoColor.popups.background.g, NekoColor.popups.background.b, 1)
            value: root.brightnessTick
            onMoved: function(v) { root.brightnessTick = v; brightnessDebounce.restart() }
          }
        }

        // Weather: now, and the next three days
        Rectangle {
          Layout.fillWidth: true
          visible: root.weatherNow !== null
          implicitHeight: weatherColumn.implicitHeight + Style.space(24)
          radius: Style.space(14)
          color: Util.alpha(root.foreground, 0.06)

          ColumnLayout {
            id: weatherColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(12)

              Text {
                text: root.weatherNow ? WeatherModel.iconForOpenMeteoCode(root.weatherNow.openMeteoWeatherCode, root.weatherNow.isDay === 0) : ""
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.displayLarge * 1.4
              }
              ColumnLayout {
                spacing: 0
                Text {
                  text: root.weatherNow ? root.weatherNow.temp_C + "°" : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                  font.weight: Font.DemiBold
                }
                Text {
                  text: root.weather ? root.weather.condition : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }
              Item { Layout.fillWidth: true }
              ColumnLayout {
                spacing: Style.space(2)
                Text {
                  Layout.alignment: Qt.AlignRight
                  text: root.weather ? root.weather.city : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: Font.Medium
                }
                Repeater {
                  model: root.weatherNow ? [
                    "Feels " + root.weatherNow.FeelsLikeC + "°",
                    "Humidity " + root.weatherNow.humidity + "%",
                    "Wind " + root.weatherNow.windspeedKmph + " km/h"
                  ] : []
                  delegate: Text {
                    required property string modelData
                    Layout.alignment: Qt.AlignRight
                    text: modelData
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            RowLayout {
              Layout.fillWidth: true
              visible: root.weatherDays.length > 0
              spacing: Style.space(6)

              Repeater {
                model: root.weatherDays
                delegate: Rectangle {
                  required property var modelData
                  Layout.fillWidth: true
                  implicitHeight: dayColumn.implicitHeight + Style.space(12)
                  radius: Style.space(10)
                  color: Util.alpha(root.foreground, 0.05)

                  ColumnLayout {
                    id: dayColumn
                    anchors.centerIn: parent
                    spacing: Style.space(2)
                    Text {
                      Layout.alignment: Qt.AlignHCenter
                      text: Qt.formatDate(new Date(modelData.date + "T12:00:00"), "ddd")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      Layout.alignment: Qt.AlignHCenter
                      text: WeatherModel.iconForOpenMeteoCode(modelData.openMeteoWeatherCode, false)
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.iconLarge
                    }
                    Text {
                      Layout.alignment: Qt.AlignHCenter
                      text: modelData.maxtempC + "° / " + modelData.mintempC + "°"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }
        }
      }

      // The wallpaper page: what's up now, changing it, rotation and colors
      ColumnLayout {
        id: wallpaperPage
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)
        visible: root.page === "wallpaper"

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          PanelActionButton {
            iconText: "󰅁"
            tooltipText: "Back"
            foreground: root.foreground
            onClicked: root.page = ""
          }
          Text {
            Layout.fillWidth: true
            text: "Wallpaper"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.weight: Font.DemiBold
          }
        }

        ClippingRectangle {
          Layout.fillWidth: true
          implicitHeight: Math.round(width * 9 / 16)
          radius: Style.space(14)
          color: Util.alpha(root.foreground, 0.06)

          // Only decoded while the page shows, at about twice its size; a
          // format this Qt can't read shows through a PNG copy
          BackgroundMedia {
            anchors.fill: parent
            path: root.page === "wallpaper" ? root.wallpaper : ""
            constrainDecode: true
            decodeSize: Qt.size(Style.space(760), Math.round(Style.space(760) * 9 / 16))
          }
        }
        Text {
          Layout.fillWidth: true
          Layout.topMargin: -Style.space(4)
          text: root.wallpaperName
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Button {
            Layout.fillWidth: true
            iconText: "󰋩"
            text: "Pick"
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

        Text {
          text: "Rotate"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        ButtonGroup {
          Layout.fillWidth: true
          fontSize: Style.font.bodySmall
          options: [ { value: "off", label: "Off" }, { value: "15", label: "15 min" }, { value: "30", label: "30 min" }, { value: "60", label: "1 hour" } ]
          value: root.rotation || "off"
          onChanged: function(v) { root.act("neko-wallpaper auto " + v) }
        }

        Text {
          text: "Colors"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        ButtonGroup {
          Layout.fillWidth: true
          fontSize: Style.font.bodySmall
          options: [ { value: "material", label: "From wallpaper" }, { value: "neko", label: "Neko" } ]
          value: root.colors
          onChanged: function(v) { root.act("neko-settings set colors " + v) }
        }
      }

      // The display page scrolls: it holds every setting Hyprland has
      Flickable {
        anchors.fill: parent
        visible: root.page === "display"
        contentHeight: displayPage.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        DisplayPage {
          id: displayPage
          width: parent.width
          bar: root.bar
          displays: root.displays
          foreground: root.foreground
          dim: root.dim
          accent: root.accent
          fontFamily: root.fontFamily
          onBack: root.page = ""
          onChanged: root.refresh()
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
    // Opens a page of its own rather than toggling, marked with a chevron
    property bool opensPage: false
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
      Text {
        visible: tile.opensPage
        text: "󰅂"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
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
    property string label: ""
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
    Text {
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignRight
      Layout.preferredWidth: Style.space(32)
    }
  }
}
