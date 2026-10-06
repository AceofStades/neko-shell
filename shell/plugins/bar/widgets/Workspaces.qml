import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Workspaces 1 to 10, always all ten, written in kanji (一 to 十). The
// focused one sits on an accent pill; empty ones are dimmed.
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

  GridLayout {
    id: grid
    anchors.fill: parent
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
          font.pixelSize: Style.font.body
          font.weight: cell.focused ? Font.Bold : Font.Normal
        }
      }
    }
  }
}
