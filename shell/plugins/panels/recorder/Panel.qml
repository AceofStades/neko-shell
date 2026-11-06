import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Ui
import qs.Commons

// The screen recorder, behind a record button in the bar: pick an area, a
// window or a display and record it, with desktop sound, the microphone, the
// pointer and the webcam as you like; a take's controls while it runs; the
// takes saved, to open, copy or throw away; and the recording settings.
// neko-record runs each take as its own unit, so the shell can restart
// mid-take; Island reads its state for the tile and card beside the island.
Panel {
  id: root
  moduleName: "neko.recorder"
  ipcTarget: "neko.recorder"

  property var settingsState: ({})
  property bool available: true
  property bool hasWebcam: false
  property var takes: []
  property int selected: 0
  // main, history or settings
  property string page: "main"
  // A take to throw away, armed by the first press
  property string armedTrash: ""
  property bool armedDiscard: false
  property string note: ""

  readonly property color foreground: bar ? bar.foreground : NekoColor.foreground
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color soft: Util.alpha(foreground, 0.06)
  readonly property color softer: Util.alpha(foreground, 0.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string take: Island.recordStatus
  readonly property bool live: Island.recordLive
  readonly property string home: Quickshell.env("HOME")
  readonly property var current: takes.length > 0 ? takes[Math.max(0, Math.min(selected, takes.length - 1))] : null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) {
      page = "main"
      armedTrash = ""
      armedDiscard = false
      note = ""
      return
    }
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onPageChanged: {
    armedTrash = ""
    if (page === "history") loadTakes()
  }

  // A take saved: the history and its newest row follow
  Connections {
    target: Island
    function onRecordStateChanged() {
      if (root.opened && Island.recordStatus === "idle") root.loadTakes()
    }
  }

  function run(args, handler) {
    var proc = processComponent.createObject(root, { args: args, handler: handler || null })
    proc.running = true
  }

  function refresh() {
    run(["status"], function(ok, reply) {
      if (!ok) return
      root.settingsState = reply.settings || {}
      root.available = reply.available !== false
    })
    loadTakes()
    webcamCheck.running = true
  }

  function loadTakes() {
    run(["history", "40"], function(ok, reply) {
      if (ok) root.takes = Array.isArray(reply) ? reply : []
    })
  }

  function set(name, value) {
    var next = Object.assign({}, root.settingsState)
    next[name] = value
    root.settingsState = next
    run(["set", name, value], function(ok, reply) {
      if (!ok) {
        root.note = reply.error || "Couldn't change that"
        root.refresh()
      }
    })
  }

  function flip(name) {
    set(name, settingsState[name] === "on" ? "off" : "on")
  }

  // The panel goes first, so it isn't in the picker's frozen screen or the take
  function record(args) {
    if (!available || live) return
    close()
    startDelay.args = ["start"].concat(args || [])
    startDelay.restart()
  }

  function discard() {
    if (!armedDiscard) {
      armedDiscard = true
      disarmTimer.restart()
      return
    }
    armedDiscard = false
    Island.record(["stop", "--discard"])
  }

  function openTake(entry) {
    if (!entry) return
    Quickshell.execDetached(["xdg-open", entry.file])
    close()
  }

  function copyPath(entry) {
    if (!entry) return
    Quickshell.execDetached(["wl-copy", entry.file])
    note = "Copied " + shortPath(entry.file)
  }

  function trash(entry) {
    if (!entry) return
    if (armedTrash !== entry.file) {
      armedTrash = entry.file
      disarmTimer.restart()
      return
    }
    armedTrash = ""
    run(["trash", entry.file], function(ok, reply) {
      if (!ok) root.note = reply.error || "Couldn't move it to the trash"
      root.loadTakes()
    })
  }

  function openFolder() {
    Quickshell.execDetached(["xdg-open", settingsState.folder || (home + "/Videos")])
    close()
  }

  function shortPath(path) {
    path = String(path || "")
    return home && path.indexOf(home) === 0 ? "~" + path.slice(home.length) : path
  }

  function sizeText(bytes) {
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + " GB"
    if (bytes >= 1048576) return Math.round(bytes / 1048576) + " MB"
    return Math.max(1, Math.round(bytes / 1024)) + " KB"
  }

  function whenText(ms) {
    var date = new Date(ms), today = new Date()
    var yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1)
    var time = Qt.formatTime(date, "HH:mm")
    if (date.toDateString() === today.toDateString()) return "Today " + time
    if (date.toDateString() === yesterday.toDateString()) return "Yesterday " + time
    return Qt.formatDate(date, "d MMM") + " " + time
  }

  function moveSelection(step) {
    if (takes.length === 0) return
    selected = Math.max(0, Math.min(takes.length - 1, selected + step))
    armedTrash = ""
    historyList.positionViewAtIndex(selected, ListView.Contain)
  }

  function textKey(text, modifiers) {
    if (page === "history") {
      if (text === "c") copyPath(current)
      else if (text === "x") trash(current)
      else if (text === "o") openFolder()
      else if (text === "h") page = "main"
      return
    }
    if (page === "settings") {
      if (text === ",") page = "main"
      return
    }
    if (live) {
      if (text === "p") Island.record(["toggle-pause"])
      else if (text === "s") Island.record(["stop"])
      else if (text === "d") discard()
      return
    }
    if (text === "r") record([])
    else if (text === "d") record(["--monitor"])
    else if (text === "h") page = "history"
    else if (text === ",") page = "settings"
    else if (text === "o") openFolder()
  }

  Component {
    id: processComponent
    Process {
      property var args: []
      property var handler: null
      command: ["neko-record"].concat(args)
      stdout: StdioCollector { id: out; waitForEnd: true }
      stderr: StdioCollector { id: err; waitForEnd: true }
      onExited: function(code) {
        var reply = {}
        try { reply = JSON.parse(String(out.text || "").trim() || "{}") } catch (error) {}
        if (code !== 0) reply = { error: String(err.text || "").trim().replace(/^neko-core record: /, "") }
        if (handler) handler(code === 0, reply)
        destroy()
      }
    }
  }

  Process {
    id: webcamCheck
    command: ["neko-hw-webcam"]
    onExited: function(code) { root.hasWebcam = code === 0 }
  }

  Timer {
    id: startDelay
    property var args: []
    interval: Style.duration(260) + 60
    onTriggered: Island.record(args)
  }

  Timer {
    id: disarmTimer
    interval: 3000
    onTriggered: {
      root.armedTrash = ""
      root.armedDiscard = false
    }
  }

  Timer {
    interval: 4000
    running: root.note !== ""
    onTriggered: root.note = ""
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.live ? (root.take === "paused" ? "󰏤" : "󰑊") : "󰻂"
    active: root.live
    tooltipText: root.live ? "Recording · " + Island.clockText(Island.recordElapsed, false) : "Recorder"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (root.live) Island.record(["stop"])
        else root.record([])
      } else if (mouseButton === Qt.MiddleButton) {
        if (root.live) Island.record(["toggle-pause"])
        else root.openFolder()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: folderField.activeFocus
      onMoveRequested: function(dx, dy) { if (root.page === "history" && dy !== 0) root.moveSelection(dy) }
      onActivateRequested: {
        if (root.page === "history") root.openTake(root.current)
        else if (root.page === "main" && !root.live) root.record([])
      }
      onDeleteRequested: if (root.page === "history") root.trash(root.current)
      onCloseRequested: {
        if (root.page !== "main") root.page = "main"
        else root.close()
      }
      onTextKey: function(text, modifiers) { root.textKey(text, modifiers) }

      ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(12)

        // What it is, what it's doing, and the way to the other pages
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          PanelActionButton {
            visible: root.page !== "main"
            iconText: "󰅁"
            tooltipText: "Back"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.page = "main"
          }
          Text {
            visible: root.page === "main"
            text: root.live ? "󰑊" : "󰻂"
            color: root.live ? NekoColor.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            Layout.rightMargin: Style.space(4)
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: root.page === "history" ? "Takes" : root.page === "settings" ? "Recording settings" : "Recorder"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
              Layout.fillWidth: true
              text: root.page === "history" ? (root.takes.length === 1 ? "1 take" : root.takes.length + " takes") + " · " + root.shortPath(root.settingsState.folder)
                : !root.available ? "gpu-screen-recorder isn't installed"
                : root.live ? (root.take === "paused" ? "Paused" : root.take === "saving" ? "Saving" : root.take === "countdown" ? "Starting" : "Recording") + " · " + (Island.recordState.label || "")
                : "Saves to " + root.shortPath(root.settingsState.folder)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
          PanelActionButton {
            visible: root.page === "main"
            iconText: "󰋚"
            tooltipText: "Takes (h)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.page = "history"
          }
          PanelActionButton {
            iconText: "󰉋"
            tooltipText: "Open the folder (o)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openFolder()
          }
          PanelActionButton {
            visible: root.page === "main"
            iconText: "󰒓"
            tooltipText: "Settings (,)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.page = "settings"
          }
        }

        // ------------------------------------------------------ not installed

        Text {
          Layout.fillWidth: true
          visible: root.page === "main" && !root.available
          text: "Recording needs gpu-screen-recorder. install.sh offers it, or install it with your package manager, then open this again."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ----------------------------------------------------------- a take

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.page === "main" && root.live
          spacing: Style.space(14)

          Rectangle {
            Layout.fillWidth: true
            implicitHeight: liveColumn.implicitHeight + Style.space(28)
            radius: Style.space(16)
            color: Util.alpha(NekoColor.urgent, root.take === "recording" ? 0.1 : 0.05)
            border.width: 1
            border.color: Util.alpha(NekoColor.urgent, 0.25)

            ColumnLayout {
              id: liveColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                Layout.alignment: Qt.AlignHCenter
                spacing: Style.space(10)
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(12)
                  height: width
                  radius: width / 2
                  color: root.take === "recording" ? NekoColor.urgent : root.dim
                  SequentialAnimation on opacity {
                    running: root.opened && root.take === "recording" && !Style.reduceMotion
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.take === "countdown" ? String(Island.recordCountdown) : Island.clockText(Island.recordElapsed, false)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                  font.weight: Font.Bold
                  font.features: { "tnum": 1 }
                }
              }
              Text {
                Layout.alignment: Qt.AlignHCenter
                text: root.take === "countdown" ? "Starting in a moment"
                  : root.take === "starting" ? "Starting the recorder"
                  : root.take === "paused" ? "Paused · resume to carry on in the same file"
                  : root.take === "saving" ? "Trimming it and evening out the sound"
                  : (Island.recordState.audio ? "With sound · " : "Silent · ") + (Island.recordState.label || "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Button {
              Layout.fillWidth: true
              iconText: root.take === "paused" ? "󰐊" : "󰏤"
              text: root.take === "paused" ? "Resume" : "Pause"
              tooltipText: "p"
              bordered: true
              enabled: root.take === "recording" || root.take === "paused"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: Island.record(["toggle-pause"])
            }
            Button {
              Layout.fillWidth: true
              iconText: "󰓛"
              text: root.take === "countdown" ? "Cancel" : "Stop and save"
              tooltipText: "s"
              selected: true
              enabled: root.take !== "saving"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: Island.record(["stop"])
            }
            Button {
              Layout.fillWidth: true
              iconText: "󰆴"
              text: root.armedDiscard ? "Throw away?" : "Discard"
              tooltipText: "d, twice"
              bordered: true
              enabled: root.take === "recording" || root.take === "paused"
              foreground: root.armedDiscard ? NekoColor.urgent : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.discard()
            }
          }
        }

        // ------------------------------------------------------- ready to go

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.page === "main" && !root.live && root.available
          spacing: Style.space(12)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)
            TargetTile {
              glyph: "󰩭"
              title: "Area or window"
              detail: "Click a window or a display, or drag an area"
              keyHint: "r"
              primary: true
              onClicked: root.record([])
            }
            TargetTile {
              glyph: "󰍹"
              title: "Whole display"
              detail: "The display you're on"
              keyHint: "d"
              onClicked: root.record(["--monitor"])
            }
          }

          // What goes into the take beside the picture
          Flow {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Chip { glyph: "󰕾"; label: "Desktop sound"; on: root.settingsState.desktopAudio === "on"; onClicked: root.flip("desktopAudio") }
            Chip { glyph: "󰍬"; label: "Microphone"; on: root.settingsState.microphone === "on"; onClicked: root.flip("microphone") }
            Chip { glyph: "󰆽"; label: "Pointer"; on: root.settingsState.cursor === "on"; onClicked: root.flip("cursor") }
            Chip { glyph: "󰖠"; label: "Webcam"; visible: root.hasWebcam; on: root.settingsState.webcam === "on"; onClicked: root.flip("webcam") }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)
            Text {
              text: "Countdown"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Item { Layout.fillWidth: true }
            ButtonGroup {
              options: [{ value: "0", label: "Off" }, { value: "3", label: "3 s" }, { value: "5", label: "5 s" }, { value: "10", label: "10 s" }]
              value: root.settingsState.countdown || "3"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              focusable: false
              onChanged: function(value) { root.set("countdown", value) }
            }
          }

          // The newest take, a click from playing it
          TakeRow {
            visible: root.takes.length > 0
            entry: root.takes.length > 0 ? root.takes[0] : null
            compact: true
          }

          Text {
            Layout.fillWidth: true
            visible: !!Island.recordState.error
            text: Island.recordState.error || ""
            color: NekoColor.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------------------------------------------------------- the takes

        Text {
          Layout.fillWidth: true
          visible: root.page === "history" && root.takes.length === 0
          Layout.topMargin: Style.space(20)
          Layout.bottomMargin: Style.space(20)
          horizontalAlignment: Text.AlignHCenter
          text: "Nothing recorded yet"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        ListView {
          id: historyList
          Layout.fillWidth: true
          visible: root.page === "history" && root.takes.length > 0
          implicitHeight: Math.min(contentHeight, Style.space(430))
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds
          model: root.takes
          delegate: TakeRow {
            required property var modelData
            required property int index
            width: historyList.width
            entry: modelData
            picked: index === root.selected
            onHoveredRow: root.selected = index
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.page === "history" && root.takes.length > 0
          text: "Enter plays · c copies the path · x twice moves it to the trash"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }

        // ------------------------------------------------------ the settings

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.page === "settings"
          spacing: Style.space(14)

          SettingChoice {
            title: "Frame rate"
            name: "fps"
            options: [{ value: "30", label: "30" }, { value: "60", label: "60" }, { value: "120", label: "120" }]
          }
          SettingChoice {
            title: "Quality"
            name: "quality"
            options: [{ value: "medium", label: "Medium" }, { value: "high", label: "High" }, { value: "very_high", label: "Very high" }, { value: "ultra", label: "Ultra" }]
          }
          SettingChoice {
            title: "Codec"
            name: "codec"
            options: [{ value: "auto", label: "Auto" }, { value: "h264", label: "H.264" }, { value: "hevc", label: "HEVC" }, { value: "av1", label: "AV1" }]
          }
          SettingChoice {
            title: "File"
            name: "container"
            options: [{ value: "mp4", label: "MP4" }, { value: "mkv", label: "MKV" }]
          }
          SettingChoice {
            visible: root.hasWebcam
            title: "Webcam size"
            name: "webcamSize"
            options: [{ value: "small", label: "Small" }, { value: "medium", label: "Medium" }, { value: "large", label: "Large" }]
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                text: "Noise reduction"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                Layout.fillWidth: true
                text: "Quiets steady background noise on the microphone when the take is saved"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
            ToggleSwitch {
              checked: root.settingsState.noiseReduction === "on"
              foreground: root.foreground
              onToggled: root.flip("noiseReduction")
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Text {
              text: "Folder"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            TextField {
              id: folderField
              Layout.fillWidth: true
              text: root.shortPath(root.settingsState.folder)
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              onAccepted: {
                root.set("folder", text.trim())
                keyCatcher.forceActiveFocus()
              }
              Keys.onEscapePressed: {
                text = root.shortPath(root.settingsState.folder)
                keyCatcher.forceActiveFocus()
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.note !== ""
          text: root.note
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideMiddle
        }
      }
    }
  }

  // What to record: a big tile to click
  component TargetTile: Rectangle {
    id: tile
    property string glyph: ""
    property string title: ""
    property string detail: ""
    property string keyHint: ""
    property bool primary: false
    signal clicked()
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.preferredWidth: 1
    implicitHeight: tileColumn.implicitHeight + Style.space(28)
    radius: Style.space(14)
    color: tileMouse.containsMouse ? root.softer : root.soft
    border.width: 1
    border.color: primary ? Util.alpha(NekoColor.urgent, tileMouse.containsMouse ? 0.5 : 0.3) : Util.alpha(root.foreground, 0.08)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    ColumnLayout {
      id: tileColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(14)
      spacing: Style.space(4)
      RowLayout {
        Layout.fillWidth: true
        Text {
          text: tile.glyph
          color: tile.primary ? NekoColor.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
        }
        Item { Layout.fillWidth: true }
        Text {
          text: tile.keyHint
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Text {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        text: tile.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Text {
        Layout.fillWidth: true
        text: tile.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tile.clicked()
    }
  }

  // Something to record along with the picture, on or off
  component Chip: Rectangle {
    id: chip
    property string glyph: ""
    property string label: ""
    property bool on: false
    signal clicked()
    implicitWidth: chipRow.implicitWidth + Style.space(22)
    implicitHeight: Style.space(32)
    radius: height / 2
    color: on ? Util.alpha(NekoColor.accent, chipMouse.containsMouse ? 0.26 : 0.18) : chipMouse.containsMouse ? root.softer : root.soft
    border.width: 1
    border.color: on ? Util.alpha(NekoColor.accent, 0.4) : Util.alpha(root.foreground, 0.08)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: chip.glyph
        color: chip.on ? NekoColor.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: chip.label
        color: chip.on ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  // A saved take: its picture, what it was, when and how long; a click plays it
  component TakeRow: Rectangle {
    id: row
    property var entry: null
    property bool picked: false
    property bool compact: false
    readonly property bool armed: !!entry && root.armedTrash === entry.file
    signal hoveredRow()
    Layout.fillWidth: true
    implicitHeight: rowLayout.implicitHeight + Style.space(compact ? 16 : 14)
    radius: Style.space(12)
    color: picked || rowMouse.containsMouse ? root.softer : compact ? root.soft : "transparent"
    Behavior on color { ColorAnimation { duration: Style.duration(100) } }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) row.hoveredRow()
      onClicked: root.openTake(row.entry)
    }

    RowLayout {
      id: rowLayout
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(12)

      ClippingRectangle {
        implicitWidth: Style.space(compact ? 88 : 104)
        implicitHeight: Math.round(implicitWidth * 9 / 16)
        radius: Style.space(8)
        color: Util.alpha(root.foreground, 0.08)
        Image {
          anchors.fill: parent
          source: row.entry && row.entry.thumb ? "file://" + row.entry.thumb : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          sourceSize.width: 240
        }
        Rectangle {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(4)
          width: durationText.implicitWidth + Style.space(8)
          height: durationText.implicitHeight + Style.space(2)
          radius: Style.space(4)
          color: Qt.rgba(0, 0, 0, 0.6)
          Text {
            id: durationText
            anchors.centerIn: parent
            text: row.entry ? Island.clockText(row.entry.durationMs || 0, false) : ""
            color: "#f2f2f2"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption - 1
            font.features: { "tnum": 1 }
          }
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)
        Text {
          Layout.fillWidth: true
          text: row.compact ? "Last take" : (row.entry ? row.entry.label || "Screen" : "")
          color: row.compact ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: row.compact ? Style.font.caption : Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          visible: row.compact
          text: row.entry ? row.entry.label || "Screen" : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          text: row.entry ? root.whenText(row.entry.createdAt) + " · " + root.sizeText(row.entry.size || 0) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: !row.compact && (rowMouse.containsMouse || row.picked)
        iconText: "󰆏"
        tooltipText: "Copy the path (c)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.copyPath(row.entry)
      }
      PanelActionButton {
        visible: !row.compact && (rowMouse.containsMouse || row.picked || row.armed)
        iconText: row.armed ? "󰗨" : "󰆴"
        tooltipText: row.armed ? "Again to move it to the trash" : "Move to the trash (x)"
        foreground: row.armed ? NekoColor.urgent : root.foreground
        fontFamily: root.fontFamily
        onClicked: root.trash(row.entry)
      }
    }
  }

  // A setting with a few values, one picked
  component SettingChoice: RowLayout {
    id: choice
    property string title: ""
    property string name: ""
    property var options: []
    Layout.fillWidth: true
    spacing: Style.space(10)
    Text {
      Layout.fillWidth: true
      text: choice.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    ButtonGroup {
      options: choice.options
      value: root.settingsState[choice.name] || ""
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      focusable: false
      onChanged: function(value) { root.set(choice.name, value) }
    }
  }
}
