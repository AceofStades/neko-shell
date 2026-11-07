import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "../recorder" as Recorder

// Capture, grown out of the island on Print: a screenshot or a recording of
// an area, a window or the screen, with what goes with it (copy or save, a
// delay; sound, the microphone, the pointer, the webcam, a countdown), and
// the screen tools beside them (text, a QR code, a color). It takes no room
// in the bar: its card anchors to the island's centre, so it opens from it.
// neko-capture-screenshot and neko-record do the work. Recording is the
// Recorder panel's own controls, so the two always offer the same; while a
// take runs, those show its controls instead.
Panel {
  id: root
  moduleName: "neko.capture"
  ipcTarget: "neko.capture"

  // screenshot or record
  property string kind: "screenshot"
  property var recordSettings: ({})
  property bool recordAvailable: true
  property var lastTake: null
  property bool hasWebcam: false
  property string after: "both"
  property int delay: 0

  readonly property color foreground: NekoColor.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color soft: Util.alpha(foreground, 0.06)
  readonly property color softer: Util.alpha(foreground, 0.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool recording: kind === "record"
  readonly property color tint: recording ? NekoColor.urgent : NekoColor.accent
  // The island's centre, which the card grows out of
  readonly property Item island: bar && typeof bar.moduleItem === "function" ? bar.moduleItem("neko.unibar-center", root) : null

  implicitWidth: 0
  implicitHeight: 0
  visible: false

  onOpenedChanged: {
    if (!opened) return
    statusProc.running = true
    historyProc.running = true
    webcamCheck.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The card goes first, so it isn't in the picker's frozen screen or the shot
  function later(seconds, command) {
    close()
    Quickshell.execDetached(["bash", "-c", "sleep " + (seconds + 0.35) + "; exec \"$@\"", "capture"].concat(command))
  }

  function screenshot(target) {
    var mode = target === "screen" ? "fullscreen" : target === "window" ? "windows" : "smart"
    later(delay, ["neko-capture-screenshot", mode].concat(after === "both" ? [] : [after]))
  }

  function tool(command) {
    close()
    Quickshell.execDetached(["bash", "-c", "sleep 0.35; exec " + command])
  }

  function setRecord(name, value) {
    var next = Object.assign({}, recordSettings)
    next[name] = value
    recordSettings = next
    Quickshell.execDetached(["neko-record", "set", name, value])
  }

  function textKey(text) {
    if ((recording || Island.recordLive) && recordControls.key(text)) return
    if (Island.recordLive) return
    if (text === "1") kind = "screenshot"
    else if (text === "2") kind = "record"
    else if (!recording && text === "a") screenshot("area")
    else if (!recording && text === "w") screenshot("window")
    else if (!recording && text === "s") screenshot("screen")
    else if (text === "t") tool("neko-capture-text")
    else if (text === "q") tool("neko-capture-qr")
    else if (text === "c") tool("hyprpicker -a")
  }

  Process {
    id: statusProc
    command: ["neko-record", "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var status = JSON.parse(String(text || "{}"))
          root.recordSettings = status.settings || {}
          root.recordAvailable = status.available !== false
        } catch (error) {}
      }
    }
  }

  Process {
    id: historyProc
    command: ["neko-record", "history", "1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var takes = JSON.parse(String(text || "[]"))
          root.lastTake = takes.length > 0 ? takes[0] : null
        } catch (error) {}
      }
    }
  }

  Process {
    id: webcamCheck
    command: ["neko-hw-webcam"]
    onExited: function(code) { root.hasWebcam = code === 0 }
  }

  // Holds the panel's place for the bar; nothing to see
  Item { id: button; anchors.fill: parent }

  KeyboardPanel {
    id: panel
    anchorItem: root.island || button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: {
        if (Island.recordLive) return
        if (root.recording) recordControls.key("a")
        else root.screenshot("area")
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { if (!Island.recordLive) root.kind = root.recording ? "screenshot" : "record" }
      onTextKey: function(text, modifiers) { root.textKey(text) }

      ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        // ------------------------------------------------ what to capture

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(14)

          // Screenshot or recording, as two halves of one switch
          Rectangle {
            Layout.fillWidth: true
            visible: !Island.recordLive
            implicitHeight: Style.space(40)
            radius: height / 2
            color: root.soft
            Rectangle {
              x: root.recording ? parent.width / 2 : 3
              y: 3
              width: parent.width / 2 - 3
              height: parent.height - 6
              radius: height / 2
              color: Util.alpha(root.tint, 0.22)
              border.width: 1
              border.color: Util.alpha(root.tint, 0.5)
              Behavior on x { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
            }
            Row {
              anchors.fill: parent
              Repeater {
                model: [{ value: "screenshot", label: "Screenshot", icon: "󰄀" }, { value: "record", label: "Record", icon: "󰑊" }]
                delegate: Item {
                  required property var modelData
                  width: parent.width / 2
                  height: parent.height
                  Row {
                    anchors.centerIn: parent
                    spacing: Style.space(8)
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.icon
                      color: root.kind === modelData.value ? root.tint : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.label
                      color: root.kind === modelData.value ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.weight: root.kind === modelData.value ? Font.DemiBold : Font.Normal
                    }
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.kind = modelData.value
                  }
                }
              }
            }
          }

          // Recording, or a take running: the Recorder panel's own controls
          Recorder.RecordControls {
            id: recordControls
            Layout.fillWidth: true
            visible: root.recording || Island.recordLive
            foreground: root.foreground
            dim: root.dim
            fontFamily: root.fontFamily
            settings: root.recordSettings
            available: root.recordAvailable
            hasWebcam: root.hasWebcam
            lastTake: root.lastTake
            shown: root.opened
            onRecord: function(args) { root.later(0, ["neko-record", "start"].concat(args)) }
            onSetSetting: function(name, value) { root.setRecord(name, value) }
            onOpenTake: function(entry) {
              root.close()
              Quickshell.execDetached(["xdg-open", entry.file])
            }
          }

          RowLayout {
            Layout.fillWidth: true
            visible: !root.recording && !Island.recordLive
            spacing: Style.space(10)
            Target { glyph: "󰩭"; title: "Area"; detail: "Drag, or click a window"; keyHint: "A"; onClicked: root.screenshot("area") }
            Target { glyph: "󰖯"; title: "Window"; detail: "Click one"; keyHint: "W"; onClicked: root.screenshot("window") }
            Target { glyph: "󰍹"; title: "Screen"; detail: "The one you're on"; keyHint: "S"; onClicked: root.screenshot("screen") }
          }

          // A screenshot's options
          ColumnLayout {
            Layout.fillWidth: true
            visible: !root.recording && !Island.recordLive
            spacing: Style.space(10)
            Option {
              title: "Then"
              ButtonGroup {
                options: [{ value: "both", label: "Copy and save" }, { value: "copy", label: "Copy" }, { value: "save", label: "Save" }, { value: "edit", label: "Draw on it" }]
                value: root.after
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                onChanged: function(value) { root.after = value }
              }
            }
            Option {
              title: "Delay"
              ButtonGroup {
                options: [{ value: "0", label: "None" }, { value: "3", label: "3 s" }, { value: "5", label: "5 s" }, { value: "10", label: "10 s" }]
                value: String(root.delay)
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                onChanged: function(value) { root.delay = Number(value) }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; visible: !Island.recordLive }

          // The screen's other tools
          RowLayout {
            Layout.fillWidth: true
            visible: !Island.recordLive
            spacing: Style.space(6)
            Tool { glyph: "󰴑"; label: "Text"; keyHint: "T"; onClicked: root.tool("neko-capture-text") }
            Tool { glyph: "󰐲"; label: "QR code"; keyHint: "Q"; onClicked: root.tool("neko-capture-qr") }
            Tool { glyph: "󰃉"; label: "Color"; keyHint: "C"; onClicked: root.tool("hyprpicker -a") }
          }
        }
      }
    }
  }

  // What to capture: a tile to click
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
    color: targetMouse.containsMouse ? Util.alpha(root.tint, 0.14) : root.soft
    border.width: 1
    border.color: targetMouse.containsMouse ? Util.alpha(root.tint, 0.5) : Util.alpha(root.foreground, 0.08)
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
          color: targetMouse.containsMouse ? root.tint : root.foreground
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

  // An option: its name, and its choices on the right
  component Option: RowLayout {
    property string title: ""
    default property alias choices: holder.data
    Layout.fillWidth: true
    spacing: Style.space(10)
    Text {
      Layout.fillWidth: true
      text: parent.title
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item {
      id: holder
      implicitWidth: childrenRect.width
      implicitHeight: childrenRect.height
    }
  }

  // One of the screen's tools
  component Tool: Rectangle {
    id: toolButton
    property string glyph: ""
    property string label: ""
    property string keyHint: ""
    signal clicked()
    Layout.fillWidth: true
    implicitHeight: Style.space(38)
    radius: height / 2
    color: toolMouse.containsMouse ? root.softer : "transparent"
    Row {
      anchors.centerIn: parent
      spacing: Style.space(8)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: toolButton.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: toolButton.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: toolButton.keyHint
        color: Util.alpha(root.foreground, 0.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    MouseArea {
      id: toolMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: toolButton.clicked()
    }
  }
}
