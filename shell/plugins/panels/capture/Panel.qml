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
  // main, or for screenshots their recent ones ("shots") and their settings
  property string page: "main"
  property var shots: []
  property var shotSettings: ({ folder: "", after: "both" })
  property string armedShot: ""

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
    if (!opened) {
      page = "main"
      armedShot = ""
      return
    }
    shotSettingsProc.running = true
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

  // The takes, the folder and the settings: a recording's are the Recorder's
  // own pages; a screenshot's are here
  function openTakes() {
    if (recording) {
      close()
      Quickshell.execDetached(["neko-shell", "neko.recorder-page", "show", "history"])
    } else {
      page = "shots"
      loadShots()
    }
  }

  function openSettings() {
    if (recording) {
      close()
      Quickshell.execDetached(["neko-shell", "neko.recorder-page", "show", "settings"])
    } else {
      page = "settings"
    }
  }

  function openFolder() {
    var folder = recording ? (recordSettings.folder || Quickshell.env("HOME") + "/Videos") : shotSettings.folder
    close()
    Quickshell.execDetached(["xdg-open", folder])
  }

  function loadShots() {
    if (!shotsProc.running) shotsProc.running = true
  }

  function setShotSetting(key, value) {
    var next = Object.assign({}, shotSettings)
    next[key] = value
    shotSettings = next
    if (key === "after") after = value
    Quickshell.execDetached(["neko-capture-screenshot", "set", key, value])
  }

  function trashShot(file) {
    if (armedShot !== file) {
      armedShot = file
      disarmShot.restart()
      return
    }
    armedShot = ""
    shots = shots.filter(function(other) { return other !== file })
    Quickshell.execDetached(["gio", "trash", file])
  }

  function shortPath(path) {
    var home = Quickshell.env("HOME")
    path = String(path || "")
    return home && path.indexOf(home) === 0 ? "~" + path.slice(home.length) : path
  }

  function textKey(text) {
    if (page !== "main") {
      if (text === "h" || text === ",") page = "main"
      else if (text === "o") openFolder()
      return
    }
    if (text === "h") { openTakes(); return }
    if (text === ",") { openSettings(); return }
    if (text === "o") { openFolder(); return }
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
    id: shotSettingsProc
    command: ["neko-capture-screenshot", "settings"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.shotSettings = JSON.parse(String(text || "{}"))
          root.after = root.shotSettings.after || "both"
        } catch (error) {}
      }
    }
  }

  // The newest screenshots in the folder
  Process {
    id: shotsProc
    command: ["bash", "-c", "ls -t -- \"$1\"/*.png \"$1\"/*.jpg 2> /dev/null | head -n 24", "shots", root.shotSettings.folder]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.shots = String(text || "").split("\n").filter(function(line) { return line !== "" })
    }
  }

  Timer {
    id: disarmShot
    interval: 3000
    onTriggered: root.armedShot = ""
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
        if (Island.recordLive || root.page !== "main") return
        if (root.recording) recordControls.key("a")
        else root.screenshot("area")
      }
      onCloseRequested: {
        if (root.page !== "main") root.page = "main"
        else root.close()
      }
      blocked: shotFolderField.activeFocus
      onTabRequested: function(direction) { if (!Island.recordLive) root.kind = root.recording ? "screenshot" : "record" }
      onTextKey: function(text, modifiers) { root.textKey(text) }

      ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(14)

        // Where it is, and the way to the takes, the folder and the settings
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
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: root.page === "shots" ? "Screenshots" : root.page === "settings" ? "Screenshot settings" : "Capture"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
              Layout.fillWidth: true
              text: "Saves to " + root.shortPath(root.recording && root.page === "main" ? root.recordSettings.folder : root.shotSettings.folder)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
          PanelActionButton {
            visible: root.page === "main" && !Island.recordLive
            iconText: "󰋚"
            tooltipText: root.recording ? "Takes (h)" : "Recent screenshots (h)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openTakes()
          }
          PanelActionButton {
            iconText: "󰉋"
            tooltipText: "Open the folder (o)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openFolder()
          }
          PanelActionButton {
            visible: root.page === "main" && !Island.recordLive
            iconText: "󰒓"
            tooltipText: root.recording ? "Recording settings (,)" : "Screenshot settings (,)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openSettings()
          }
        }

        // ---------------------------------------------- recent screenshots

        Text {
          Layout.fillWidth: true
          visible: root.page === "shots" && root.shots.length === 0
          Layout.topMargin: Style.space(16)
          Layout.bottomMargin: Style.space(16)
          horizontalAlignment: Text.AlignHCenter
          text: "No screenshots yet"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Flickable {
          Layout.fillWidth: true
          visible: root.page === "shots" && root.shots.length > 0
          Layout.preferredHeight: Style.space(360)
          contentHeight: shotGrid.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          Flow {
            id: shotGrid
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: root.shots
              delegate: Rectangle {
                id: shot
                required property string modelData
                readonly property bool armed: root.armedShot === modelData
                width: (shotGrid.width - Style.space(16)) / 3
                height: Math.round(width * 9 / 16)
                radius: Style.space(10)
                color: Util.alpha(root.foreground, 0.06)
                clip: true
                Image {
                  anchors.fill: parent
                  source: "file://" + shot.modelData
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  sourceSize.width: 320
                }
                MouseArea {
                  id: shotMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.close()
                    Quickshell.execDetached(["xdg-open", shot.modelData])
                  }
                }
                // Copy it, draw on it, or move it to the trash (twice)
                Row {
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  anchors.margins: Style.space(4)
                  spacing: Style.space(2)
                  visible: shotMouse.containsMouse || shot.armed || copyButton.hovered || drawButton.hovered || trashButton.hovered
                  ShotButton { id: copyButton; glyph: "󰆏"; onClicked: Quickshell.execDetached(["bash", "-c", "wl-copy --type image/png < \"$1\"", "copy", shot.modelData]) }
                  ShotButton {
                    id: drawButton
                    glyph: "󰏫"
                    onClicked: {
                      root.close()
                      Quickshell.execDetached(["satty", "--filename", shot.modelData, "--output-filename", shot.modelData, "--copy-command", "wl-copy", "--early-exit"])
                    }
                  }
                  ShotButton { id: trashButton; glyph: shot.armed ? "󰗨" : "󰆴"; warn: shot.armed; onClicked: root.trashShot(shot.modelData) }
                }
              }
            }
          }
        }

        // ---------------------------------------------- screenshot settings

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.page === "settings"
          spacing: Style.space(12)
          Option {
            title: "By default, then"
            ButtonGroup {
              options: [{ value: "both", label: "Copy and save" }, { value: "copy", label: "Copy" }, { value: "save", label: "Save" }, { value: "edit", label: "Draw on it" }]
              value: root.shotSettings.after || "both"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              focusable: false
              onChanged: function(value) { root.setShotSetting("after", value) }
            }
          }
          Text {
            text: "Folder"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          TextField {
            id: shotFolderField
            Layout.fillWidth: true
            text: root.shortPath(root.shotSettings.folder)
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            onAccepted: {
              root.setShotSetting("folder", text.trim().replace(/^~/, Quickshell.env("HOME")))
              keyCatcher.forceActiveFocus()
            }
          }
        }

        // ------------------------------------------------ what to capture

        ColumnLayout {
          Layout.fillWidth: true
          visible: root.page === "main"
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

  // A small round button over a screenshot's thumbnail
  component ShotButton: Rectangle {
    id: shotButton
    property string glyph: ""
    property bool warn: false
    readonly property bool hovered: shotButtonMouse.containsMouse
    signal clicked()
    width: Style.space(26)
    height: width
    radius: width / 2
    color: warn ? Util.alpha(NekoColor.urgent, 0.85) : shotButtonMouse.containsMouse ? Qt.rgba(0, 0, 0, 0.8) : Qt.rgba(0, 0, 0, 0.6)
    Text {
      anchors.centerIn: parent
      text: shotButton.glyph
      color: "#f2f2f2"
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption + 2
    }
    MouseArea {
      id: shotButtonMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: shotButton.clicked()
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
