import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../../notifications/NotificationLogic.js" as NotificationLogic

// Workspaces 1 to 10, always all ten, written in kanji (一 to 十). The
// focused one sits on an accent pill; empty ones are dimmed.
//
// On a horizontal bar this is also the island (see Island): a notification
// or an OSD grows a dark pill out of the workspaces' capsule to show it, the
// workspaces fading out beneath, and it shrinks back into the capsule after.
BarWidget {
  id: root
  moduleName: "neko.workspaces"

  readonly property var kanji: ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
  readonly property color accent: NekoColor.accent
  readonly property real cellSize: root.vertical ? root.barSize : Style.space(24)

  // A font with the kanji, loaded from its file: fontconfig knows which one
  // has them, but Qt's own fallback can settle on another face of the same
  // family that doesn't (Droid Sans has a dozen), and draws boxes
  property string kanjiFontFile: ""
  readonly property string kanjiFamily: kanjiFont.status === FontLoader.Ready ? kanjiFont.name : ""

  Process {
    running: true
    command: ["fc-match", "--format=%{file}", ":lang=ja"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.kanjiFontFile = String(text || "").trim()
    }
  }

  FontLoader {
    id: kanjiFont
    source: root.kanjiFontFile ? "file://" + root.kanjiFontFile : ""
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  implicitWidth: grid.implicitWidth
  implicitHeight: grid.implicitHeight

  // ---------- The island ----------
  readonly property bool islandUp: !root.vertical && root.visible && !!root.bar && !root.bar.barHidden
  property bool islandCounted: false
  readonly property string islandMode: Island.mode

  function countIsland() {
    if (root.islandUp === root.islandCounted) return
    Island.islands += root.islandUp ? 1 : -1
    root.islandCounted = root.islandUp
  }

  onIslandUpChanged: countIsland()
  Component.onCompleted: countIsland()
  Component.onDestruction: if (root.islandCounted) Island.islands -= 1

  // The capsule the bar draws behind this widget: inset from the bar's edges
  // and a little from the slot's ends. The island grows out of it.
  readonly property real restInset: Style.space(3)
  readonly property real restWidth: root.width - 4
  readonly property real restHeight: root.height - 2 * root.restInset

  readonly property color islandColor: Qt.rgba(0.05, 0.05, 0.06, 0.94)
  readonly property color islandText: "#f2f2f2"
  readonly property color islandDim: Qt.rgba(0.95, 0.95, 0.95, 0.6)

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  PopupWindow {
    id: island

    visible: root.islandUp && (root.islandMode !== "" || pill.opacity > 0)
    color: "transparent"
    implicitWidth: Style.space(460)
    implicitHeight: Style.space(150)
    // Only the pill takes the pointer; the rest of the popup lets it through
    mask: Region { item: pill }

    anchor {
      item: root
      rect.x: (root.width - island.implicitWidth) / 2
      rect.y: 0
      rect.width: 1
      rect.height: 1
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      adjustment: PopupAdjustment.None
    }

    Rectangle {
      id: pill
      readonly property real targetWidth: root.islandMode === "notification" ? Style.space(420)
        : root.islandMode === "osd" ? Math.max(root.restWidth, Style.space(300)) : root.restWidth
      readonly property real targetHeight: root.islandMode === "notification" ? notificationView.implicitHeight : root.restHeight

      x: Math.round((island.width - width) / 2)
      y: root.restInset
      width: targetWidth
      height: targetHeight
      radius: Math.min(height / 2, Style.space(22))
      color: root.islandColor
      opacity: root.islandMode !== "" ? 1 : 0
      clip: true

      Behavior on width { NumberAnimation { duration: Style.duration(420); easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
      Behavior on height { NumberAnimation { duration: Style.duration(420); easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
      Behavior on opacity { NumberAnimation { duration: Style.duration(root.islandMode !== "" ? 120 : 320) } }

      HoverHandler {
        onHoveredChanged: Island.hovered = hovered
      }

      // Volume, brightness and the rest: a glyph, a meter and the value
      Row {
        anchors.centerIn: parent
        spacing: Style.space(12)
        opacity: root.islandMode === "osd" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: Island.osd ? Island.osd.icon : ""
          color: root.islandText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.bar.iconFont
        }
        Rectangle {
          visible: !!Island.osd && Island.osd.hasProgress
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(170)
          height: Style.space(5)
          radius: height / 2
          color: Qt.rgba(1, 1, 1, 0.18)

          Rectangle {
            readonly property real fraction: Island.osd && Island.osd.maxValue > 0 ? Math.max(0, Math.min(1, Island.osd.value / Island.osd.maxValue)) : 0
            height: parent.height
            radius: height / 2
            width: fraction > 0 ? Math.max(height, parent.width * fraction) : 0
            color: root.islandText
            Behavior on width { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
          }
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          visible: text !== ""
          text: Island.osd ? Island.osd.message : ""
          color: root.islandText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.bar.fontSize
        }
      }

      // The newest notification: its icon, the app, the summary and the body
      Item {
        id: notificationView
        readonly property var n: Island.current
        readonly property string iconUrl: n ? (n.image ? n.image : root.iconSource(n.appIcon)) : ""
        readonly property string bodyText: n ? NotificationLogic.sanitizeBody(n.body, n.app, n.appIcon) : ""

        anchors.fill: parent
        implicitHeight: Math.max(Style.space(40), texts.implicitHeight) + 2 * Style.space(12)
        opacity: root.islandMode === "notification" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(220) } }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          onClicked: function(mouse) {
            if (mouse.button === Qt.RightButton) Island.dismiss()
            else Island.invoke()
          }
        }

        RowLayout {
          anchors.fill: parent
          anchors.margins: Style.space(12)
          anchors.leftMargin: Style.space(16)
          anchors.rightMargin: Style.space(18)
          spacing: Style.space(12)

          Item {
            Layout.preferredWidth: Style.space(40)
            Layout.preferredHeight: Style.space(40)
            Layout.alignment: Qt.AlignVCenter

            Image {
              id: notificationIcon
              anchors.fill: parent
              source: notificationView.iconUrl
              sourceSize.width: width * 2
              sourceSize.height: height * 2
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              smooth: true
              visible: status === Image.Ready
            }
            Text {
              anchors.centerIn: parent
              visible: notificationIcon.status !== Image.Ready
              text: notificationView.n && notificationView.n.glyph ? notificationView.n.glyph : "󰂚"
              color: root.islandText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.display
            }
          }

          ColumnLayout {
            id: texts
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(1)

            RowLayout {
              Layout.fillWidth: true
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: notificationView.n ? notificationView.n.app : ""
                color: root.islandDim
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              // More waiting behind this one
              Text {
                visible: Island.count > 1
                text: "+" + (Island.count - 1)
                color: root.islandDim
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
              }
            }
            Text {
              Layout.fillWidth: true
              visible: text !== ""
              textFormat: Text.PlainText
              text: notificationView.n ? notificationView.n.summary : ""
              color: root.islandText
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
              maximumLineCount: 1
            }
            Text {
              Layout.fillWidth: true
              visible: text !== ""
              textFormat: Text.PlainText
              text: notificationView.bodyText
              color: root.islandDim
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 2
            }
          }
        }

        // How long it has left, as a hairline along the bottom
        Rectangle {
          visible: Island.lifetime > 0
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.bottomMargin: Style.space(5)
          anchors.leftMargin: Style.space(22)
          height: 2
          radius: 1
          width: (parent.width - Style.space(44)) * Island.remaining
          color: Qt.rgba(1, 1, 1, 0.25)
        }
      }
    }
  }

  GridLayout {
    id: grid
    anchors.fill: parent
    // Out of the way while the island is out
    opacity: root.islandMode === "" ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
    columns: root.vertical ? 1 : 10
    columnSpacing: 0
    rowSpacing: 0

    Repeater {
      model: 10

      WidgetButton {
        id: cell
        required property int index
        readonly property int number: index + 1
        readonly property var workspace: root.workspaceById(number)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === number
        readonly property real shown: focused || occupied ? 1 : 0.45

        bar: root.bar
        hasVisualContent: true
        tooltipText: "Workspace " + number
        fixedWidth: root.cellSize
        fixedHeight: root.vertical ? Style.space(24) : root.barSize
        onPressed: function() { root.focusWorkspace(cell.number) }

        Rectangle {
          anchors.centerIn: parent
          width: cell.width - Style.space(4)
          height: Math.min(cell.height - Style.space(6), Style.space(22))
          radius: height / 2
          color: Util.alpha(root.accent, 0.22)
          opacity: cell.focused ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 140 } }
        }

        Text {
          anchors.centerIn: parent
          opacity: cell.shown
          text: root.kanji[cell.index]
          color: cell.focused ? root.accent : cell.foreground
          font.family: root.kanjiFamily || cell.fontFamily
          font.pixelSize: Style.bar.fontSize
          font.weight: cell.focused ? Font.Bold : Font.Normal
        }
      }
    }
  }
}
