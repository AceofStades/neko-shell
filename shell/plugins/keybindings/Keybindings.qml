import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "KeyboardModel.js" as Model

// Every keybinding, on a drawn keyboard (Super+/). Hold modifiers and the
// keys bound with them light up, with what each does listed below; press a
// whole shortcut, or point at a key, to see just its bindings; type to
// search. Nothing runs while it's open: Hyprland sits in a submap of its own
// (neko.lua) where only Super+/ works, to close it again.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property var bindings: []
  // Modifiers held on the keyboard, or picked by clicking them
  property var heldMods: []
  property var pickedMods: []
  // The key being looked at (a binding's key name, lowercase), and its mods
  property string lookedKey: ""
  property var lookedMods: []
  property string hoverKey: ""
  property string query: ""

  readonly property var mods: lookedKey !== "" ? lookedMods : heldMods.length > 0 ? heldMods : pickedMods
  readonly property string focusKey: lookedKey !== "" ? lookedKey : hoverKey
  readonly property var bound: Model.boundKeys(bindings, mods)
  readonly property var listed: Model.shown(bindings, mods, focusKey, query)

  readonly property color foreground: NekoColor.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color accent: NekoColor.accent
  readonly property real unit: Math.min(Style.space(46), (overlay.width - Style.space(120)) / 19.5)

  function open(payloadJson) {
    heldMods = []
    pickedMods = []
    lookedKey = ""
    hoverKey = ""
    query = ""
    opened = true
    reader.running = true
    // Nothing else bound runs while it's open
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap(\"neko-keybindings\")"])
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!opened) return
    opened = false
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap(\"reset\")"])
  }

  function dismiss() {
    close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "neko.keybindings")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  function togglePicked(mod) {
    lookedKey = ""
    var next = pickedMods.slice()
    var at = next.indexOf(mod)
    if (at >= 0) next.splice(at, 1)
    else next.push(mod)
    pickedMods = Model.MODIFIERS.filter(function(m) { return next.indexOf(m) >= 0 })
  }

  function modsFromEvent(event) {
    var held = []
    if (event.modifiers & Qt.MetaModifier) held.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) held.push("CTRL")
    if (event.modifiers & Qt.AltModifier) held.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) held.push("SHIFT")
    return held
  }

  // A pressed key's name as Hyprland's bindings spell it
  function keyName(event) {
    var code = event.key
    if (code >= Qt.Key_A && code <= Qt.Key_Z) return String.fromCharCode(code).toLowerCase()
    if (code >= Qt.Key_0 && code <= Qt.Key_9) return String.fromCharCode(code)
    if (code >= Qt.Key_F1 && code <= Qt.Key_F12) return "f" + (code - Qt.Key_F1 + 1)
    var named = ({})
    named[Qt.Key_Return] = "return"; named[Qt.Key_Enter] = "return"; named[Qt.Key_Space] = "space"
    named[Qt.Key_Tab] = "tab"; named[Qt.Key_Backspace] = "backspace"; named[Qt.Key_Delete] = "delete"
    named[Qt.Key_Slash] = "slash"; named[Qt.Key_Question] = "slash"; named[Qt.Key_Period] = "period"; named[Qt.Key_Comma] = "comma"
    named[Qt.Key_Minus] = "minus"; named[Qt.Key_Equal] = "equal"; named[Qt.Key_BracketLeft] = "bracketleft"; named[Qt.Key_BracketRight] = "bracketright"
    named[Qt.Key_Left] = "left"; named[Qt.Key_Right] = "right"; named[Qt.Key_Up] = "up"; named[Qt.Key_Down] = "down"
    named[Qt.Key_Print] = "print"; named[Qt.Key_Home] = "home"; named[Qt.Key_End] = "end"
    return named[code] || ""
  }

  Process {
    id: reader
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.bindings = Model.clean(JSON.parse(String(text || "[]"))) } catch (error) {}
      }
    }
  }

  OverlayWindow {
    id: overlay
    shown: root.opened
    WlrLayershell.namespace: "neko-keybindings"

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function(event) {
        event.accepted = true
        var mod = Model.modifierForKey(event.key, Qt)
        if (mod !== "") {
          var held = root.modsFromEvent(event)
          if (held.indexOf(mod) < 0) held.push(mod)
          root.heldMods = Model.MODIFIERS.filter(function(m) { return held.indexOf(m) >= 0 })
          root.lookedKey = ""
          return
        }
        if (event.key === Qt.Key_Escape && event.modifiers === Qt.NoModifier) {
          if (root.query !== "" || root.lookedKey !== "") { root.query = ""; root.lookedKey = "" }
          else root.dismiss()
          return
        }
        var held = root.modsFromEvent(event)
        // Typing with nothing held searches
        if (held.length === 0 && root.pickedMods.length === 0 && Util.editsFilter(event, root.query)) {
          root.query = Util.editedFilter(event, root.query)
          root.lookedKey = ""
          return
        }
        var name = root.keyName(event)
        if (name === "") return
        root.lookedMods = held.length > 0 ? held : root.pickedMods
        root.lookedKey = name
      }
      Keys.onReleased: function(event) {
        event.accepted = true
        if (Model.modifierForKey(event.key, Qt) === "") return
        root.heldMods = root.modsFromEvent(event).filter(function(m) { return m !== Model.modifierForKey(event.key, Qt) })
      }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: content.implicitWidth + Style.space(48)
      height: content.implicitHeight + Style.space(44)
      radius: Style.space(28)
      color: Util.alpha(NekoColor.popups.background, 0.82)
      border.width: 1
      border.color: Util.alpha(root.foreground, 0.12)
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.97
      Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }
      Behavior on scale { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }

      MouseArea { anchors.fill: parent }

      ColumnLayout {
        id: content
        anchors.centerIn: parent
        spacing: Style.space(16)

        // What's being looked at, and the search
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text {
            text: "󰌌"
            color: root.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
          }
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: root.lookedKey !== "" ? Model.combo({ modmask: Model.maskOf(root.lookedMods), key: root.lookedKey })
                : root.mods.length > 0 ? root.mods.join(" + ") + " + …" : "Keybindings"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
              text: root.query !== "" ? "Searching \"" + root.query + "\" · Esc clears"
                : "Hold keys, or click the modifiers, to see what they do · type to search · Esc closes"
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
          Text {
            text: root.listed.length + (root.listed.length === 1 ? " binding" : " bindings")
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // The keyboard: the main block, then the keys on the right
        Row {
          Layout.alignment: Qt.AlignHCenter
          spacing: root.unit * 0.5

          Column {
            spacing: root.unit * 0.1
            Repeater {
              model: Model.MAIN
              delegate: KeyRow { required property var modelData; required property int index; keys: modelData; topGap: index === 1 }
            }
          }
          Column {
            spacing: root.unit * 0.1
            Repeater {
              model: Model.SIDE
              delegate: KeyRow { required property var modelData; required property int index; keys: modelData; topGap: index === 1 }
            }
          }
        }

        // What the keys do
        Flickable {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.min(listFlow.implicitHeight, Style.space(220))
          contentHeight: listFlow.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          Flow {
            id: listFlow
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.listed
              delegate: Rectangle {
                required property var modelData
                width: (listFlow.width - Style.space(12)) / 3
                height: Style.space(34)
                radius: Style.space(10)
                color: Util.alpha(root.foreground, 0.05)
                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.combo(modelData)
                    color: root.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.weight: Font.DemiBold
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.parent.width - x - Style.space(14)
                    text: Model.action(modelData)
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // One row of keys; a gap object is empty space of that many units
  component KeyRow: Row {
    property var keys: []
    property bool topGap: false
    spacing: root.unit * 0.1
    topPadding: topGap ? root.unit * 0.35 : 0
    Repeater {
      model: parent.keys
      delegate: Item {
        id: key
        required property var modelData
        readonly property bool gap: modelData.gap !== undefined
        readonly property var names: gap ? [] : modelData.names
        readonly property string modifier: names.length === 1 && Model.MODIFIERS.indexOf(names[0].toUpperCase()) >= 0 ? names[0].toUpperCase() : ""
        readonly property bool isMod: modifier !== ""
        readonly property bool held: isMod && root.mods.indexOf(modifier) >= 0
        readonly property bool hasBinding: !isMod && names.some(function(n) { return root.bound[n] === true })
        readonly property bool looked: !isMod && names.indexOf(root.focusKey) >= 0
        width: (gap ? modelData.gap : modelData.width) * root.unit + (gap ? 0 : (modelData.width - 1) * root.unit * 0.1)
        height: root.unit

        Rectangle {
          anchors.fill: parent
          visible: !key.gap
          radius: Style.space(8)
          color: key.looked ? Util.alpha(root.accent, 0.45)
            : key.held ? Util.alpha(root.accent, 0.35)
            : key.hasBinding ? Util.alpha(root.accent, 0.16)
            : Util.alpha(root.foreground, keyMouse.containsMouse ? 0.12 : 0.06)
          border.width: 1
          border.color: key.held || key.looked ? root.accent : key.hasBinding ? Util.alpha(root.accent, 0.4) : Util.alpha(root.foreground, 0.08)
          Behavior on color { ColorAnimation { duration: Style.duration(90) } }

          Text {
            anchors.centerIn: parent
            text: key.gap ? "" : key.modelData.label
            color: key.hasBinding || key.held || key.looked ? root.foreground : root.dim
            font.family: Style.font.family
            font.pixelSize: key.modelData && String(key.modelData.label).length > 2 ? Style.font.caption : Style.font.bodySmall
            font.weight: key.hasBinding ? Font.DemiBold : Font.Normal
          }

          MouseArea {
            id: keyMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: {
              if (key.isMod) return
              if (containsMouse) root.hoverKey = key.names[0]
              else if (root.hoverKey === key.names[0]) root.hoverKey = ""
            }
            onClicked: {
              if (key.isMod) root.togglePicked(key.modifier)
              else {
                root.lookedMods = root.mods
                root.lookedKey = root.lookedKey === key.names[0] ? "" : key.names[0]
              }
            }
          }
        }
      }
    }
  }
}
