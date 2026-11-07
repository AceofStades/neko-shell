import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.Commons
import qs.Ui

// Recording, as the Recorder panel and the capture panel (Print) both show
// it, so the two always offer the same: an area, the focused window or the
// screen; desktop sound, the microphone, the pointer and the webcam; the
// countdown; the last take. While a take runs, its time and pause, stop and
// discard (pressed twice) instead. The panel holding it does the starting
// (it has to close first) and keeps the settings; this asks for both.
// Keys, through key(): A, W, S start; P, S, D while recording.
ColumnLayout {
  id: root

  property color foreground: NekoColor.popups.text
  property color dim: Util.alpha(foreground, 0.6)
  property string fontFamily: Style.font.family
  // neko-record's settings, and whether it can record at all
  property var settings: ({})
  property bool available: true
  property bool hasWebcam: false
  property var lastTake: null
  property bool shown: true

  signal record(var args)
  signal setSetting(string name, string value)
  signal openTake(var entry)

  readonly property string take: Island.recordStatus
  readonly property bool live: Island.recordLive
  property bool armedDiscard: false

  spacing: Style.space(12)

  function flip(name) {
    setSetting(name, settings[name] === "on" ? "off" : "on")
  }

  function discard() {
    if (!armedDiscard) {
      armedDiscard = true
      disarm.restart()
      return
    }
    armedDiscard = false
    Island.record(["stop", "--discard"])
  }

  // A key the panel passed on: true when it meant something here
  function key(text) {
    if (live) {
      if (text === "p") Island.record(["toggle-pause"])
      else if (text === "s") Island.record(["stop"])
      else if (text === "d") discard()
      else return false
      return true
    }
    if (!available) return false
    if (text === "a" || text === "r") record([])
    else if (text === "w") record(["--window"])
    else if (text === "s") record(["--monitor"])
    else return false
    return true
  }

  Timer {
    id: disarm
    interval: 3000
    onTriggered: root.armedDiscard = false
  }

  // ------------------------------------------------------ not installed

  Text {
    Layout.fillWidth: true
    visible: !root.available && !root.live
    text: "Recording needs gpu-screen-recorder. install.sh offers it, or install it with your package manager, then open this again."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  // ----------------------------------------------------------- a take

  ColumnLayout {
    Layout.fillWidth: true
    visible: root.live
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
              running: root.shown && root.take === "recording" && !Style.reduceMotion
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
        tooltipText: "P"
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
        tooltipText: "S"
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
        tooltipText: "D, twice"
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
    visible: !root.live && root.available
    spacing: Style.space(12)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(10)
      Target { glyph: "󰩭"; title: "Area"; detail: "Drag one, or click a window or display"; keyHint: "A"; onClicked: root.record([]) }
      Target { glyph: "󰖯"; title: "Window"; detail: "The one in focus"; keyHint: "W"; onClicked: root.record(["--window"]) }
      Target { glyph: "󰍹"; title: "Screen"; detail: "The one you're on"; keyHint: "S"; onClicked: root.record(["--monitor"]) }
    }

    // What goes into the take beside the picture
    Flow {
      Layout.fillWidth: true
      spacing: Style.space(6)
      Chip { glyph: "󰕾"; label: "Desktop sound"; on: root.settings.desktopAudio === "on"; onClicked: root.flip("desktopAudio") }
      Chip { glyph: "󰍬"; label: "Microphone"; on: root.settings.microphone === "on"; onClicked: root.flip("microphone") }
      Chip { glyph: "󰆽"; label: "Pointer"; on: root.settings.cursor === "on"; onClicked: root.flip("cursor") }
      Chip { glyph: "󰖠"; label: "Webcam"; visible: root.hasWebcam; on: root.settings.webcam === "on"; onClicked: root.flip("webcam") }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(10)
      Text {
        Layout.fillWidth: true
        text: "Countdown"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      ButtonGroup {
        options: [{ value: "0", label: "Off" }, { value: "3", label: "3 s" }, { value: "5", label: "5 s" }, { value: "10", label: "10 s" }]
        value: root.settings.countdown || "3"
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        focusable: false
        onChanged: function(value) { root.setSetting("countdown", value) }
      }
    }

    // The newest take, a click from playing it
    Rectangle {
      Layout.fillWidth: true
      visible: !!root.lastTake
      implicitHeight: lastRow.implicitHeight + Style.space(16)
      radius: Style.space(12)
      color: lastMouse.containsMouse ? Util.alpha(root.foreground, 0.1) : Util.alpha(root.foreground, 0.06)

      MouseArea {
        id: lastMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.openTake(root.lastTake)
      }

      RowLayout {
        id: lastRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(12)

        ClippingRectangle {
          implicitWidth: Style.space(88)
          implicitHeight: Math.round(implicitWidth * 9 / 16)
          radius: Style.space(8)
          color: Util.alpha(root.foreground, 0.08)
          Image {
            anchors.fill: parent
            source: root.lastTake && root.lastTake.thumb ? "file://" + root.lastTake.thumb : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize.width: 240
          }
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)
          Text {
            text: "Last take"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            Layout.fillWidth: true
            text: root.lastTake ? root.lastTake.label || "Screen" : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
          Text {
            text: root.lastTake ? Island.clockText(root.lastTake.durationMs || 0, false) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
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

  // What to record: a tile to click
  component Target: Rectangle {
    id: target
    property string glyph: ""
    property string title: ""
    property string detail: ""
    property string keyHint: ""
    signal clicked()
    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.preferredWidth: 1
    implicitHeight: targetColumn.implicitHeight + Style.space(24)
    radius: Style.space(14)
    color: targetMouse.containsMouse ? Util.alpha(NekoColor.urgent, 0.14) : Util.alpha(root.foreground, 0.06)
    border.width: 1
    border.color: targetMouse.containsMouse ? Util.alpha(NekoColor.urgent, 0.5) : Util.alpha(root.foreground, 0.08)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    ColumnLayout {
      id: targetColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(12)
      spacing: Style.space(3)
      RowLayout {
        Layout.fillWidth: true
        Text {
          text: target.glyph
          color: targetMouse.containsMouse ? NekoColor.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
        }
        Item { Layout.fillWidth: true }
        Text {
          text: target.keyHint
          color: Util.alpha(root.foreground, 0.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
      Text {
        Layout.topMargin: Style.space(4)
        text: target.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
      }
      Text {
        Layout.fillWidth: true
        text: target.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    MouseArea {
      id: targetMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: target.clicked()
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
    color: on ? Util.alpha(NekoColor.urgent, chipMouse.containsMouse ? 0.24 : 0.16) : chipMouse.containsMouse ? Util.alpha(root.foreground, 0.1) : Util.alpha(root.foreground, 0.06)
    border.width: 1
    border.color: on ? Util.alpha(NekoColor.urgent, 0.4) : Util.alpha(root.foreground, 0.08)
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: chip.glyph
        color: chip.on ? NekoColor.urgent : root.dim
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
}
