import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The power menu, over the whole screen: lock, sleep, hibernate (where it
// works), log out, restart and shut down, as a row of round buttons on glass.
// The three that end the session count down first, so a slip can be taken
// back; a second press goes at once. Keys: the arrows and Enter, or a letter
// each (L S H O R P), Esc to back out. The commands do the work in units of
// their own, so the shell going away mid-shutdown can't stop it halfway.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property int selected: 0
  // The action counting down, and when it goes
  property string armed: ""
  property double armedAt: 0
  property double now: Date.now()
  property bool canSuspend: true
  property bool canHibernate: false
  property string uptime: ""

  readonly property int countdownMs: 5000
  readonly property color foreground: NekoColor.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color accent: NekoColor.accent
  readonly property color urgent: NekoColor.urgent
  readonly property string userName: Quickshell.env("USER") || ""

  readonly property var actions: [
    { id: "lock", label: "Lock", icon: "󰌾", key: "l", command: ["neko-system-lock"], ends: false },
    { id: "suspend", label: "Sleep", icon: "󰒲", key: "s", command: ["systemctl", "suspend"], ends: false, shown: canSuspend },
    { id: "hibernate", label: "Hibernate", icon: "󰤁", key: "h", command: ["systemctl", "hibernate"], ends: false, shown: canHibernate },
    { id: "logout", label: "Log out", icon: "󰍃", key: "o", command: ["neko-system-logout"], ends: true, going: "Logging out" },
    { id: "reboot", label: "Restart", icon: "󰜉", key: "r", command: ["neko-system-reboot"], ends: true, going: "Restarting" },
    { id: "shutdown", label: "Shut down", icon: "󰐥", key: "p", command: ["neko-system-shutdown"], ends: true, going: "Shutting down" }
  ].filter(function(action) { return action.shown !== false })

  readonly property var armedAction: armed === "" ? null : actions.filter(function(a) { return a.id === armed })[0] || null
  readonly property int secondsLeft: armed === "" ? 0 : Math.max(0, Math.ceil((armedAt + countdownMs - now) / 1000))

  function open(payloadJson) {
    armed = ""
    // Lock: a stray Enter does nothing that can't be undone
    selected = 0
    opened = true
    probe.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    armed = ""
    opened = false
  }

  function dismiss() {
    close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "neko.power-menu")
  }

  function toggle() {
    if (opened) dismiss()
    else open("{}")
  }

  function run(action) {
    dismiss()
    Quickshell.execDetached(action.command)
  }

  // An action that ends the session counts down first; pressed again, or its
  // count run out, it goes
  function activate(action) {
    if (!action) return
    selected = actions.indexOf(action)
    if (!action.ends || armed === action.id) {
      run(action)
      return
    }
    armed = action.id
    armedAt = Date.now()
    now = armedAt
  }

  function move(step) {
    armed = ""
    selected = (selected + step + actions.length) % actions.length
  }

  // Whether sleep is switched off, whether hibernation works, and the uptime
  Process {
    id: probe
    command: ["bash", "-c", "neko-toggle-enabled suspend-off && echo suspend=no || echo suspend=yes; neko-hibernation-available && echo hibernate=yes || echo hibernate=no; echo \"uptime=$(uptime -p | sed 's/^up //')\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        String(text || "").split("\n").forEach(function(line) {
          var at = line.indexOf("=")
          if (at < 0) return
          var key = line.slice(0, at), value = line.slice(at + 1)
          if (key === "suspend") root.canSuspend = value === "yes"
          else if (key === "hibernate") root.canHibernate = value === "yes"
          else if (key === "uptime") root.uptime = value
        })
        root.selected = Math.min(root.selected, root.actions.length - 1)
      }
    }
  }

  // The countdown: only draws while open, and the action goes when it ends
  Timer {
    interval: 100
    repeat: true
    running: root.opened && root.armed !== ""
    onTriggered: {
      root.now = Date.now()
      if (root.now >= root.armedAt + root.countdownMs && root.armedAction) root.run(root.armedAction)
    }
  }

  OverlayWindow {
    id: overlay
    shown: root.opened
    WlrLayershell.namespace: "neko-power-menu"

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }
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
        if (event.key === Qt.Key_Escape) {
          if (root.armed !== "") root.armed = ""
          else root.dismiss()
        } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier)) || event.key === Qt.Key_Backtab) {
          root.move(-1)
        } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
          root.move(1)
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          root.activate(root.actions[root.selected])
        } else {
          var letter = String(event.text || "").toLowerCase()
          var match = root.actions.filter(function(a) { return a.key === letter })[0]
          if (!match) return
          root.activate(match)
        }
        event.accepted = true
      }
    }

    Column {
      anchors.centerIn: parent
      spacing: Style.space(26)
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }
      Behavior on scale { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }

      Column {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(4)
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.armedAction ? root.armedAction.going + " in " + root.secondsLeft : "See you, " + root.userName
          color: root.armedAction ? root.urgent : root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.display
          font.weight: Font.Bold
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.armedAction ? "Press it again to go now, Esc to stay" : root.uptime !== "" ? "Up " + root.uptime : " "
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      // The buttons, on a strip of glass
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        width: buttons.implicitWidth + Style.space(36)
        height: buttons.implicitHeight + Style.space(36)
        radius: Style.space(34)
        color: Util.alpha(NekoColor.popups.background, 0.72)
        border.width: 1
        border.color: Util.alpha(root.foreground, 0.12)

        MouseArea { anchors.fill: parent }

        Row {
          id: buttons
          anchors.centerIn: parent
          spacing: Style.space(14)

          Repeater {
            model: root.actions
            delegate: Item {
              id: tile
              required property var modelData
              required property int index
              readonly property bool picked: root.selected === index
              readonly property bool counting: root.armed === modelData.id
              readonly property color tint: modelData.ends ? root.urgent : root.accent
              width: Style.space(96)
              height: column.implicitHeight

              Column {
                id: column
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(10)

                Item {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(76)
                  height: width

                  Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: tile.counting ? Util.alpha(tile.tint, 0.28)
                      : tile.picked || mouse.containsMouse ? Util.alpha(tile.tint, 0.18)
                      : Util.alpha(root.foreground, 0.07)
                    border.width: tile.picked ? 2 : 1
                    border.color: tile.picked ? tile.tint : Util.alpha(root.foreground, 0.1)
                    Behavior on color { ColorAnimation { duration: Style.duration(140) } }
                  }

                  // The count running out, round the button
                  Canvas {
                    id: ring
                    anchors.fill: parent
                    visible: tile.counting
                    readonly property real fraction: tile.counting ? Math.min(1, (root.now - root.armedAt) / root.countdownMs) : 0
                    onFractionChanged: requestPaint()
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      ctx.lineWidth = 3
                      ctx.lineCap = "round"
                      ctx.strokeStyle = tile.tint
                      ctx.beginPath()
                      ctx.arc(width / 2, height / 2, width / 2 - 2, -Math.PI / 2, -Math.PI / 2 + fraction * 2 * Math.PI)
                      ctx.stroke()
                    }
                  }

                  Text {
                    anchors.centerIn: parent
                    text: tile.modelData.icon
                    color: tile.picked || tile.counting ? tile.tint : root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.iconLarge + Style.space(8)
                  }

                  MouseArea {
                    id: mouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: if (root.armed === "") root.selected = tile.index
                    onClicked: root.activate(tile.modelData)
                  }
                }

                Column {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(2)
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: tile.counting ? String(root.secondsLeft) : tile.modelData.label
                    color: tile.picked || tile.counting ? root.foreground : root.dim
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.weight: tile.picked ? Font.DemiBold : Font.Normal
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: tile.modelData.key.toUpperCase()
                    color: Util.alpha(root.foreground, 0.35)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
