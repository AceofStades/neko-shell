import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "../../control-center" as ControlCenterPlugin

// The UniBar's exact center: a minute clock at rest and the anchor from which
// notifications, OSDs, media, Pomodoro and settings grow.
BarWidget {
  id: root
  moduleName: "neko.unibar-center"

  property date now: clock.date
  property real wheelAccumulator: 0
  readonly property string timeText: Qt.formatDateTime(now, String(setting("format", "HH:mm")))
  readonly property string hours: timeText.slice(0, 2)
  readonly property string minutes: timeText.slice(-2)

  // The whole UniBar is the island's compact shape. Bar.groupSpan crosses
  // the centered anchor, so this includes the monitor, both workspace banks
  // and every status control rather than just this clock slot.
  readonly property var islandGroupSpan: root.bar && typeof root.bar.groupSpan === "function"
    ? root.bar.groupSpan(root) : null
  // The compact island alone: the workspace bars and the clock between them.
  // Transient surfaces that take the island's width (the OSD) take this, not
  // the whole group, which the media and timer pills widen while they show.
  readonly property var coreSpan: root.bar && typeof root.bar.spanBetween === "function" && typeof root.bar.moduleItem === "function"
    ? root.bar.spanBetween(root.bar.moduleItem("neko.workspace-bars-left", root), root.bar.moduleItem("neko.workspace-bars-right", root)) : null
  readonly property real islandCoreWidth: coreSpan ? Math.max(1, coreSpan.right - coreSpan.left) : 0
  readonly property real islandSurfaceWidth: islandGroupSpan
    ? Math.max(1, islandGroupSpan.right - islandGroupSpan.left) : root.width
  readonly property real islandCenterOffset: {
    if (!islandGroupSpan || !root.QsWindow.window) return 0
    var here = root.mapToItem(root.QsWindow.window.contentItem, root.width / 2, 0)
    return (islandGroupSpan.left + islandGroupSpan.right) / 2 - here.x
  }

  implicitWidth: Style.space(72)
  implicitHeight: root.barSize

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.now = date
  }

  // The existing island renderer is hosted invisibly across the entire
  // UniBar. At rest its pill exactly covers the shared surface. While it is
  // open, its center glides to the screen-centered clock as it changes shape.
  Workspaces {
    id: islandHost
    width: Math.max(1, root.islandSurfaceWidth - 2 * Style.bar.capsulePadding + Style.space(4))
    height: parent.height
    x: Math.round((parent.width - width) / 2 + (Island.mode === "" ? root.islandCenterOffset : 0))
    y: 0
    bar: root.bar
    coreWidth: root.islandCoreWidth
    // It hosts only the island window. Disabling its hidden workspace grid
    // keeps those ten invisible buttons out of the clock's click routing.
    enabled: false
    opacity: 0
    z: -10

    onXChanged: placeIsland()

    Behavior on x {
      enabled: !Style.reduceMotion
      SpringAnimation { spring: Style.spring.stiffness; damping: Style.spring.damping; epsilon: Style.spring.epsilon }
    }
  }

  // The clock owns UniBar's control center directly, so opening it needs no
  // zero-width layout module beside the visible widgets. Its hidden button
  // contributes neither geometry nor a click target; the clock below is the
  // sole trigger and the shared KeyboardPanel morphs from this UniBar slot.
  // Found by the bar for summon/toggle, so keybinds and `neko open
  // control-center` reach this panel, which has no slot of its own
  readonly property var embeddedPanel: controlCenter

  ControlCenterPlugin.Panel {
    id: controlCenter
    anchors.fill: parent
    z: -5
    bar: root.bar
    settings: ({ hideButton: true, panelWidth: 780 })
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    z: 10
    bar: root.bar
    fixedWidth: root.implicitWidth
    fixedHeight: root.barSize
    hasVisualContent: true
    labelVisible: false
    tooltipText: "Open control center · Scroll: volume"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) controlCenter.toggle()
    }

    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0 || !root.bar) return
      root.bar.run("neko-audio-output-volume " + (wheel.steps > 0 ? "raise" : "lower"))
    }

    Item {
      anchors.fill: parent
      opacity: Island.mode === "" && !Island.settling ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(Island.mode === "" ? 140 : 60) } }

      Text {
        anchors.centerIn: parent
        textFormat: Text.RichText
        text: root.hours + '<font color="' + NekoColor.accent + '">:</font>' + root.minutes
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        font.letterSpacing: Style.spaceReal(0.7)
      }

    }
  }
}
