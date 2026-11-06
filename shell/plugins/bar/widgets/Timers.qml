import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// A clock tile beside the island, as the Pomodoro is: the timer closest to
// done (and whatever is ringing), or with `kind` "stopwatch", the stopwatch,
// or with "recording", a screen recording's take. The active tile
// (Island.activeTile) shows its time; a passive one only its icon in a ring
// of progress. Hovering opens its card in the island; a click pauses or
// resumes it, and while it rings dismisses (a right click snoozes, or stops
// a take). neko-clock and neko-record keep them; Island reads their state.
BarWidget {
  id: root
  moduleName: "neko.timers"
  property string kind: "timer"

  readonly property bool timerKind: kind === "timer"
  readonly property bool recordKind: kind === "recording"
  readonly property bool ringing: timerKind && Island.clockRinging
  readonly property bool present: recordKind ? Island.recordLive : timerKind ? (ringing || !!Island.clockTimer) : Island.stopwatchPresent
  readonly property bool running: ringing || (recordKind ? Island.recordRunning : timerKind ? Island.timerRunning : Island.stopwatchRunning)
  // A take's tile sits left of the island, with the music; the clock's right
  readonly property bool leftSide: recordKind
  readonly property bool tileActive: leftSide ? Island.leftActiveTile === kind : Island.activeTile === kind
  // The timer's time left, or the stopwatch's or the take's sweep round each minute
  readonly property real fraction: timerKind ? Island.timerFraction
    : ((recordKind ? Island.recordElapsed : Island.stopwatchElapsed) % 60000) / 60000
  // What's live shows in its own colour: a take in the urgent one, as being
  // recorded is worth noticing
  readonly property color liveColor: recordKind ? NekoColor.urgent : NekoColor.accent

  readonly property string text: ringing ? (Island.clockState.ringing[0].label || (Island.clockState.ringing[0].kind === "timer" ? "Done" : "Alarm"))
    : recordKind ? (Island.recordStatus === "countdown" ? String(Island.recordCountdown)
      : Island.recordStatus === "starting" ? "Starting"
      : Island.recordStatus === "saving" ? "Saving" : Island.clockText(Island.recordElapsed, false))
    : timerKind ? Island.clockText(Island.timerRemaining, true)
    : Island.clockText(Island.stopwatchElapsed, false)
  readonly property string icon: ringing ? "󰂞" : recordKind ? (Island.recordStatus === "paused" ? "󰏤" : "󰑊") : timerKind ? "󰔟" : "󱎫"

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
  transform: Translate { x: (1 - root.reveal) * Style.space(16) * (root.leftSide ? 1 : -1) }
  // It sizes its own ends: the bar draws the pill a little in from the slot
  // (tileEnd); the slot is sized so the pill is round when passive and hugs
  // the time when active
  readonly property bool capsulePadded: false
  readonly property real capsuleInset: Style.bar.capsuleInset
  readonly property real capsuleTop: !!root.bar && root.bar.centerTopAttached === true ? 0 : capsuleInset
  readonly property real capsuleHeight: root.barSize - capsuleTop - capsuleInset
  readonly property real tileEnd: 2 + Style.bar.widgetGap / 2
  readonly property real ringGap: Style.spaceReal(2)
  implicitWidth: !visible ? 0 : (tileActive ? content.implicitWidth + capsuleHeight : capsuleHeight) + 4
  implicitHeight: root.barSize
  Behavior on implicitWidth {
    enabled: !Style.reduceMotion
    SpringAnimation { spring: Style.spring.stiffness; damping: Style.spring.damping; epsilon: Style.spring.epsilon }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    tooltipText: ""
    onPressed: function(mouseButton) {
      if (root.recordKind) {
        if (mouseButton === Qt.RightButton || !Island.recordRunning && Island.recordStatus !== "paused") Island.record(["stop"])
        else Island.record(["toggle-pause"])
      }
      else if (root.ringing) Island.clock([mouseButton === Qt.RightButton ? "snooze" : "dismiss"])
      else if (!root.timerKind) Island.clock(["stopwatch-toggle"])
      else if (Island.clockTimer) Island.clock([Island.clockTimer.state === "running" ? "timer-pause" : "timer-resume", Island.clockTimer.id])
    }

    // Progress as one stroke round the pill from twelve o'clock; on a passive
    // tile, the pill is round, so it reads as a ring
    Item {
      id: progress
      anchors.fill: parent
      // As far from the pill on every side
      anchors.leftMargin: root.tileEnd + root.ringGap
      anchors.rightMargin: root.tileEnd + root.ringGap
      anchors.topMargin: root.capsuleTop + root.ringGap
      anchors.bottomMargin: root.capsuleInset + root.ringGap
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
          strokeColor: progress.shownFraction > 0.001 ? (root.running ? root.liveColor : Util.alpha(button.foreground, 0.5)) : "transparent"
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
        color: root.running ? root.liveColor : button.foreground
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
