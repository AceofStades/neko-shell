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
  // Tucked behind the workspaces' capsule while the island is out: it slips
  // in at once as the island takes over, and slides back out from behind
  // the capsule once the island has shrunk into it again
  readonly property bool shownBeside: Island.mode === "" && !Island.settling
  property real reveal: 1
  // Started by hand: a Behavior would read its duration before the change
  // and slide out at the quick speed it slips in at
  onShownBesideChanged: {
    revealAnimation.stop()
    revealAnimation.to = shownBeside ? 1 : 0
    revealAnimation.duration = Style.duration(shownBeside ? 280 : 60)
    revealAnimation.easing.type = shownBeside ? Easing.OutCubic : Easing.InCubic
    revealAnimation.start()
  }
  NumberAnimation { id: revealAnimation; target: root; property: "reveal" }
  opacity: reveal
  transform: Translate { x: (1 - root.reveal) * Style.space(16) * -1 }
  implicitWidth: sessionActive ? Style.space(92) : Style.space(40)
  implicitHeight: root.barSize
  Behavior on implicitWidth {
    NumberAnimation { duration: Style.duration(300); easing.type: Easing.OutCubic }
  }

  readonly property bool topAttached: !!root.bar && root.bar.centerTopAttached === true
  readonly property real capsuleInset: Style.bar.capsuleInset
  readonly property real capsuleTop: root.topAttached ? 0 : root.capsuleInset
  readonly property real capsuleHeight: root.barSize - root.capsuleTop - root.capsuleInset
  readonly property real endRadius: capsuleHeight / 2
  readonly property real workspaceCenter: width + Style.space(2) + endRadius
  readonly property real notchRadius: endRadius + Style.space(4)
  readonly property real tipX: workspaceCenter - Math.sqrt(Math.max(0, notchRadius * notchRadius - endRadius * endRadius))

  // The music control owns the same shape on the other side. Paint that path
  // backwards so this edge cups the workspace capsule while keeping a gap.
  Shape {
    anchors.fill: parent
    visible: !!root.bar && !root.bar.transparent && (root.bar.glass || NekoColor.bar.capsule.a > 0) && !root.topAttached
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { origin.x: root.width / 2; xScale: -1; yScale: 1 }

    ShapePath {
      fillColor: root.bar && root.bar.glass ? root.bar.glassIslandCapsule : NekoColor.bar.capsule
      strokeWidth: 0
      startX: Style.space(2) + root.endRadius
      startY: root.capsuleTop
      PathLine { x: root.tipX; y: root.capsuleTop }
      PathArc { x: root.tipX; y: root.capsuleTop + root.capsuleHeight; radiusX: root.notchRadius; radiusY: root.notchRadius; direction: PathArc.Counterclockwise }
      PathLine { x: Style.space(2) + root.endRadius; y: root.capsuleTop + root.capsuleHeight }
      PathArc { x: Style.space(2) + root.endRadius; y: root.capsuleTop; radiusX: root.endRadius; radiusY: root.endRadius }
    }
  }

  // Attached to the screen's top edge (with the workspaces between this and
  // its twin): flat along the top, a shoulder curving the outer side into
  // the edge, a rounded bottom outer corner, and the notch following the
  // workspaces' attached capsule, straight down and round its bottom corner,
  // a few pixels off
  readonly property real shoulder: Style.space(8)
  readonly property real islandLeft: root.width + Style.space(2)
  readonly property real notchGap: Style.space(4)
  readonly property real notchCurveCenterX: root.islandLeft + root.endRadius
  readonly property real notchCurveCenterY: root.capsuleTop + root.capsuleHeight - root.endRadius
  readonly property real notchBottomX: root.notchCurveCenterX - Math.sqrt(Math.max(0, (root.endRadius + root.notchGap) * (root.endRadius + root.notchGap) - root.endRadius * root.endRadius))

  Shape {
    anchors.fill: parent
    visible: !!root.bar && !root.bar.transparent && (root.bar.glass || NekoColor.bar.capsule.a > 0) && root.topAttached
    preferredRendererType: Shape.CurveRenderer
    transform: Scale { origin.x: root.width / 2; xScale: -1; yScale: 1 }

    ShapePath {
      fillColor: root.bar && root.bar.glass ? root.bar.glassIslandCapsule : NekoColor.bar.capsule
      strokeWidth: 0
      strokeColor: "transparent"
      startX: Style.space(2) - root.shoulder
      startY: root.capsuleTop
      PathLine { x: root.islandLeft - root.notchGap; y: root.capsuleTop }
      PathLine { x: root.islandLeft - root.notchGap; y: root.notchCurveCenterY }
      PathArc { x: root.notchBottomX; y: root.capsuleTop + root.capsuleHeight; radiusX: root.endRadius + root.notchGap; radiusY: root.endRadius + root.notchGap; direction: PathArc.Counterclockwise }
      PathLine { x: Style.space(2) + root.endRadius; y: root.capsuleTop + root.capsuleHeight }
      PathArc { x: Style.space(2); y: root.capsuleTop + root.capsuleHeight - root.endRadius; radiusX: root.endRadius; radiusY: root.endRadius }
      PathLine { x: Style.space(2); y: root.capsuleTop + root.shoulder }
      PathArc { x: Style.space(2) - root.shoulder; y: root.capsuleTop; radiusX: root.shoulder; radiusY: root.shoulder; direction: PathArc.Counterclockwise }
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

    // One continuous progress stroke wraps the icon and clock together. The
    // path begins at twelve o'clock and walks clockwise around the pill.
    Item {
      id: compactProgress
      anchors.fill: parent
      anchors.leftMargin: Style.space(3)
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: root.capsuleInset + Style.space(2)
      anchors.bottomMargin: root.capsuleInset + Style.space(2)
      visible: root.sessionActive
      property real shownFraction: Island.pomodoroFraction
      readonly property real stroke: Style.spaceReal(2.2)
      readonly property real inset: stroke / 2 + Style.spaceReal(0.5)
      readonly property real arcRadius: (height - 2 * inset) / 2
      readonly property real leftCenter: inset + arcRadius
      readonly property real rightCenter: width - inset - arcRadius
      readonly property real perimeter: 2 * Math.max(0, rightCenter - leftCenter) + 2 * Math.PI * arcRadius
      readonly property real dash: Math.max(0.01, shownFraction * perimeter / stroke)
      readonly property real gap: Math.max(0.01, (1 - shownFraction) * perimeter / stroke)

      Behavior on shownFraction {
        NumberAnimation { duration: Style.duration(240); easing.type: Easing.OutCubic }
      }

      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          strokeWidth: compactProgress.stroke
          strokeColor: Util.alpha(button.foreground, 0.18)
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          startX: compactProgress.width / 2
          startY: compactProgress.inset
          PathLine { x: compactProgress.rightCenter; y: compactProgress.inset }
          PathArc {
            x: compactProgress.rightCenter
            y: compactProgress.height - compactProgress.inset
            radiusX: compactProgress.arcRadius
            radiusY: compactProgress.arcRadius
            direction: PathArc.Clockwise
          }
          PathLine { x: compactProgress.leftCenter; y: compactProgress.height - compactProgress.inset }
          PathArc {
            x: compactProgress.leftCenter
            y: compactProgress.inset
            radiusX: compactProgress.arcRadius
            radiusY: compactProgress.arcRadius
            direction: PathArc.Clockwise
          }
          PathLine { x: compactProgress.width / 2; y: compactProgress.inset }
        }

        ShapePath {
          strokeWidth: compactProgress.stroke + Style.spaceReal(0.3)
          strokeColor: compactProgress.shownFraction > 0.001 ? NekoColor.accent : "transparent"
          strokeStyle: ShapePath.DashLine
          dashPattern: [compactProgress.dash, compactProgress.gap]
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          startX: compactProgress.width / 2
          startY: compactProgress.inset
          PathLine { x: compactProgress.rightCenter; y: compactProgress.inset }
          PathArc {
            x: compactProgress.rightCenter
            y: compactProgress.height - compactProgress.inset
            radiusX: compactProgress.arcRadius
            radiusY: compactProgress.arcRadius
            direction: PathArc.Clockwise
          }
          PathLine { x: compactProgress.leftCenter; y: compactProgress.height - compactProgress.inset }
          PathArc {
            x: compactProgress.leftCenter
            y: compactProgress.inset
            radiusX: compactProgress.arcRadius
            radiusY: compactProgress.arcRadius
            direction: PathArc.Clockwise
          }
          PathLine { x: compactProgress.width / 2; y: compactProgress.inset }
        }
      }
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
        font.pixelSize: Style.bar.iconFont - 1
        Behavior on color { ColorAnimation { duration: Style.duration(160) } }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.sessionActive
        text: root.clock
        color: button.foreground
        opacity: root.sessionActive && !root.sessionRunning ? 0.65 : 1
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
