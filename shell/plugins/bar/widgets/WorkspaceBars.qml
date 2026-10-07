import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Five workspaces in the space of one ordinary status icon. Each thin mark
// grows with its state: short when empty, medium when occupied and tall in
// the accent when focused. The generous invisible button around each mark
// keeps every workspace easy to hit.
BarWidget {
  id: root

  readonly property int firstWorkspace: Math.max(1, Math.round(Number(setting("start", 1))))

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

  implicitWidth: bars.implicitWidth + Style.space(8)
  implicitHeight: root.barSize

  Row {
    id: bars
    anchors.centerIn: parent
    spacing: Style.space(1)

    Repeater {
      model: 5

      WidgetButton {
        id: workspaceButton
        required property int index
        readonly property int number: root.firstWorkspace + index
        readonly property var workspace: root.workspaceById(number)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === number

        bar: root.bar
        // The mark stays hairline-thin, while its invisible lane remains
        // comfortable to click on a scaled display.
        fixedWidth: Style.space(9)
        fixedHeight: root.barSize
        hasVisualContent: true
        labelVisible: false
        tooltipText: "Workspace " + number
        onPressed: function() { root.focusWorkspace(workspaceButton.number) }

        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(workspaceButton.focused ? 3.5 : 3)
          height: Style.space(workspaceButton.focused ? 18 : workspaceButton.occupied ? 12 : 7)
          radius: width / 2
          color: workspaceButton.focused ? NekoColor.accent : workspaceButton.foreground
          opacity: workspaceButton.focused ? 1 : workspaceButton.occupied ? 0.72 : 0.3

          Behavior on width { NumberAnimation { duration: Style.duration(150); easing.type: Easing.OutCubic } }
          Behavior on height { NumberAnimation { duration: Style.duration(190); easing.type: Easing.OutCubic } }
          Behavior on color { ColorAnimation { duration: Style.duration(150) } }
          Behavior on opacity { NumberAnimation { duration: Style.duration(150) } }
        }
      }
    }
  }
}
