import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// A clock tile beside the island, as the Pomodoro is: the timer closest to
// done (and whatever is ringing), or with `kind` "stopwatch", the stopwatch.
// The active tile (Island.activeTile) shows its time; a passive one only its
// icon in a ring of progress. Hovering opens its card in the island; a click
// pauses or resumes it, and while it rings dismisses (a right click snoozes).
// neko-clock keeps and rings them; Island reads its state.
BarWidget {
  id: root
  moduleName: "neko.timers"
  property string kind: "timer"

  readonly property bool timerKind: kind === "timer"
  readonly property bool ringing: timerKind && Island.clockRinging
  readonly property bool present: timerKind ? (ringing || !!Island.clockTimer) : Island.stopwatchPresent
  readonly property bool running: ringing || (timerKind ? Island.timerRunning : Island.stopwatchRunning)
  readonly property bool tileActive: Island.activeTile === kind
  // The timer's time left, or the stopwatch's sweep round each minute
  readonly property real fraction: timerKind ? Island.timerFraction : (Island.stopwatchElapsed % 60000) / 60000

  readonly property string text: ringing ? (Island.clockState.ringing[0].label || (Island.clockState.ringing[0].kind === "timer" ? "Done" : "Alarm"))
    : timerKind ? Island.clockText(Island.timerRemaining, true)
    : Island.clockText(Island.stopwatchElapsed, false)
  readonly property string icon: ringing ? "󰂞" : timerKind ? "󰔟" : "󱎫"

  visible: present && !root.vertical
  enabled: Island.mode === "" || Island.mode === kind
  // Tucked behind the workspaces' capsule while the island is out, as the
  // Pomodoro is
  readonly property bool shownBeside: Island.mode === "" && !Island.settling
  property real reveal: 1
  Behavior on reveal {
    enabled: !Style.reduceMotion
    SpringAnimation { spring: Style.spring.stiffness; damping: Style.spring.damping; epsilon: Style.spring.epsilon }
  }
  onShownBesideChanged: root.reveal = shownBeside ? 1 : 0
  opacity: reveal
  transform: Translate { x: (1 - root.reveal) * Style.space(16) * -1 }
  implicitWidth: !visible ? 0 : tileActive ? content.implicitWidth + Style.space(30) : Style.space(40)
  implicitHeight: root.barSize
  Behavior on implicitWidth {
    enabled: !Style.reduceMotion
    SpringAnimation { spring: Style.spring.stiffness; damping: Style.spring.damping; epsilon: Style.spring.epsilon }
  }

  readonly property real capsuleInset: Style.bar.capsuleInset

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    tooltipText: ""
    onPressed: function(mouseButton) {
      if (root.ringing) Island.clock([mouseButton === Qt.RightButton ? "snooze" : "dismiss"])
      else if (!root.timerKind) Island.clock(["stopwatch-toggle"])
      else if (Island.clockTimer) Island.clock([Island.clockTimer.state === "running" ? "timer-pause" : "timer-resume", Island.clockTimer.id])
    }

    // Progress as one stroke round the pill from twelve o'clock; on a passive
    // tile, the pill is round, so it reads as a ring
    Item {
      id: progress
      anchors.fill: parent
      anchors.leftMargin: Style.space(3)
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: root.capsuleInset + Style.space(2)
      anchors.bottomMargin: root.capsuleInset + Style.space(2)
      visible: !root.ringing
      property real shownFraction: root.fraction
      readonly property real stroke: Style.spaceReal(2.2)
      readonly property real inset: stroke / 2 + Style.spaceReal(0.5)
      readonly property real arcRadius: (height - 2 * inset) / 2
      readonly property real leftCenter: inset + arcRadius
      readonly property real rightCenter: Math.max(leftCenter, width - inset - arcRadius)
      readonly property real perimeter: 2 * Math.max(0, rightCenter - leftCenter) + 2 * Math.PI * arcRadius
      readonly property real dash: Math.max(0.01, shownFraction * perimeter / stroke)
      readonly property real gap: Math.max(0.01, (1 - shownFraction) * perimeter / stroke)

      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          strokeWidth: progress.stroke
          strokeColor: Util.alpha(button.foreground, 0.18)
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          startX: progress.width / 2
          startY: progress.inset
          PathLine { x: progress.rightCenter; y: progress.inset }
          PathArc { x: progress.rightCenter; y: progress.height - progress.inset; radiusX: progress.arcRadius; radiusY: progress.arcRadius; direction: PathArc.Clockwise }
          PathLine { x: progress.leftCenter; y: progress.height - progress.inset }
          PathArc { x: progress.leftCenter; y: progress.inset; radiusX: progress.arcRadius; radiusY: progress.arcRadius; direction: PathArc.Clockwise }
          PathLine { x: progress.width / 2; y: progress.inset }
        }

        ShapePath {
          strokeWidth: progress.stroke + Style.spaceReal(0.3)
          strokeColor: progress.shownFraction > 0.001 ? (root.running ? NekoColor.accent : Util.alpha(button.foreground, 0.5)) : "transparent"
          strokeStyle: ShapePath.DashLine
          dashPattern: [progress.dash, progress.gap]
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          startX: progress.width / 2
          startY: progress.inset
          PathLine { x: progress.rightCenter; y: progress.inset }
          PathArc { x: progress.rightCenter; y: progress.height - progress.inset; radiusX: progress.arcRadius; radiusY: progress.arcRadius; direction: PathArc.Clockwise }
          PathLine { x: progress.leftCenter; y: progress.height - progress.inset }
          PathArc { x: progress.leftCenter; y: progress.inset; radiusX: progress.arcRadius; radiusY: progress.arcRadius; direction: PathArc.Clockwise }
          PathLine { x: progress.width / 2; y: progress.inset }
        }
      }
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(7)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.icon
        color: root.running ? NekoColor.accent : button.foreground
        opacity: root.running ? 1 : 0.65
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont - 1
        Behavior on color { ColorAnimation { duration: Style.duration(160) } }

        // Ringing, it rocks like a bell
        SequentialAnimation on rotation {
          running: root.ringing && !Style.reduceMotion
          loops: Animation.Infinite
          alwaysRunToEnd: true
          NumberAnimation { to: 14; duration: Style.duration(90) }
          NumberAnimation { to: -14; duration: Style.duration(180) }
          NumberAnimation { to: 0; duration: Style.duration(90) }
          PauseAnimation { duration: Style.duration(500) }
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.tileActive
        text: root.text
        color: button.foreground
        opacity: root.running ? 1 : 0.65
        font.family: button.fontFamily
        font.pixelSize: Style.bar.fontSize
        font.weight: Font.DemiBold
        font.letterSpacing: Style.spaceReal(0.7)
        font.features: { "tnum": 1 }
        elide: Text.ElideRight
        width: Math.min(implicitWidth, Style.space(110))
      }
    }

    HoverHandler {
      onHoveredChanged: {
        if (hovered) Island.showClock(root.kind)
        else Island.leaveClockIcon()
      }
    }
  }
}
