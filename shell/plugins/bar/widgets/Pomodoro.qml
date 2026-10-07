import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// A compact timer on the workspace island's right edge. At rest it is only
// a timer mark; an active session grows just enough to show its clock. Hover
// hands the full controls to the workspace island.
BarWidget {
  id: root
  moduleName: "neko.pomodoro"
  readonly property bool ownCapsule: true
  readonly property bool sessionActive: Island.pomodoroActive
  readonly property bool sessionRunning: Island.pomodoroRunning
  readonly property string clock: Island.pomodoroClock(Island.pomodoroRemaining)

  visible: !root.vertical
  enabled: Island.mode === "" || Island.mode === "pomodoro"
  opacity: Island.mode === "" ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
  implicitWidth: sessionActive ? Style.space(92) : Style.space(40)
  implicitHeight: root.barSize
  Behavior on implicitWidth {
    NumberAnimation { duration: Style.duration(300); easing.type: Easing.OutCubic }
  }

  readonly property real capsuleInset: Style.bar.capsuleInset
  readonly property real capsuleHeight: root.barSize - 2 * capsuleInset
  readonly property real endRadius: capsuleHeight / 2
  readonly property real workspaceCenter: width + Style.space(2) + endRadius
  readonly property real notchRadius: endRadius + Style.space(4)
  readonly property real tipX: workspaceCenter - Math.sqrt(Math.max(0, notchRadius * notchRadius - endRadius * endRadius))

  // The music control owns the same shape on the other side. Paint that path
  // backwards so this edge cups the workspace capsule while keeping a gap.
  Shape {
    anchors.fill: parent
    visible: !!root.bar && !root.bar.transparent && (root.bar.glass || NekoColor.bar.capsule.a > 0)
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { origin.x: root.width / 2; xScale: -1; yScale: 1 }

    ShapePath {
      fillColor: root.bar && root.bar.glass ? root.bar.glassIslandCapsule : NekoColor.bar.capsule
      strokeWidth: 0
      startX: Style.space(2) + root.endRadius
      startY: root.capsuleInset
      PathLine { x: root.tipX; y: root.capsuleInset }
      PathArc { x: root.tipX; y: root.capsuleInset + root.capsuleHeight; radiusX: root.notchRadius; radiusY: root.notchRadius; direction: PathArc.Counterclockwise }
      PathLine { x: Style.space(2) + root.endRadius; y: root.capsuleInset + root.capsuleHeight }
      PathArc { x: Style.space(2) + root.endRadius; y: root.capsuleInset; radiusX: root.endRadius; radiusY: root.endRadius }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    anchors.leftMargin: root.sessionActive ? Style.space(4) : 0
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    tooltipText: ""
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) Island.resetPomodoro()
      else Island.togglePomodoro()
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(7)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰔛"
        color: root.sessionRunning ? NekoColor.accent : button.foreground
        opacity: root.sessionActive && !root.sessionRunning ? 0.65 : 1
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont + 1
        Behavior on color { ColorAnimation { duration: Style.duration(160) } }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.sessionActive
        text: root.clock
        color: button.foreground
        opacity: root.sessionRunning ? 1 : 0.65
        font.family: button.fontFamily
        font.pixelSize: Style.bar.fontSize
        font.weight: Font.DemiBold
        font.features: { "tnum": 1 }
      }
    }

    HoverHandler {
      onHoveredChanged: {
        if (hovered) Island.showPomodoro()
        else Island.leavePomodoroIcon()
      }
    }
  }
}
