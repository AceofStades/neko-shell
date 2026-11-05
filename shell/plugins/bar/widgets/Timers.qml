import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// What the clock has running, beside the island as the Pomodoro is: the timer
// closest to done, with its progress round the pill, else the stopwatch, and
// whatever is ringing. A click pauses or resumes it; while it rings, a click
// dismisses and a right click snoozes. neko-clock keeps and rings them; this
// only reads its state file and draws.
BarWidget {
  id: root
  moduleName: "neko.timers"

  property var state: ({ timers: [], alarms: [], stopwatch: { running: false, startedAt: 0, accumulatedMs: 0 }, ringing: [] })
  property double now: Date.now()

  readonly property bool ringing: state.ringing.length > 0
  readonly property var soonest: {
    var best = null
    for (var i = 0; i < state.timers.length; i++) {
      var timer = state.timers[i]
      if (timer.state === "running" && (!best || timer.endsAt < best.endsAt)) best = timer
    }
    return best
  }
  // A paused timer still shows, dimmed, so it isn't forgotten
  readonly property var paused: {
    for (var i = 0; i < state.timers.length; i++) if (state.timers[i].state === "paused") return state.timers[i]
    return null
  }
  readonly property var timer: soonest || paused
  readonly property bool stopwatchOn: state.stopwatch.running || state.stopwatch.accumulatedMs > 0
  readonly property bool active: ringing || !!timer || stopwatchOn
  readonly property bool running: ringing || !!soonest || (!timer && state.stopwatch.running)

  readonly property real remaining: !timer ? 0 : timer.state === "running" ? Math.max(0, timer.endsAt - now) : timer.remainingMs
  readonly property real fraction: timer && timer.durationMs > 0 ? remaining / timer.durationMs : 0
  readonly property real elapsed: state.stopwatch.accumulatedMs + (state.stopwatch.running ? Math.max(0, now - state.stopwatch.startedAt) : 0)

  function pad2(value) {
    return (value < 10 ? "0" : "") + value
  }

  function formatSeconds(total) {
    var hours = Math.floor(total / 3600), minutes = Math.floor(total / 60) % 60, seconds = total % 60
    return hours > 0 ? hours + ":" + pad2(minutes) + ":" + pad2(seconds) : minutes + ":" + pad2(seconds)
  }

  readonly property string text: ringing ? (state.ringing[0].label || (state.ringing[0].kind === "timer" ? "Done" : "Alarm"))
    : timer ? formatSeconds(Math.ceil(remaining / 1000))
    : formatSeconds(Math.floor(elapsed / 1000))
  readonly property string icon: ringing ? "󰂞" : timer ? "󰔟" : "󱎫"

  function clock(args) {
    Quickshell.execDetached(["neko-clock"].concat(args))
  }

  visible: active && !root.vertical
  enabled: Island.mode === ""
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
  implicitWidth: visible ? content.implicitWidth + Style.space(30) : 0
  implicitHeight: root.barSize
  Behavior on implicitWidth {
    enabled: !Style.reduceMotion
    SpringAnimation { spring: Style.spring.stiffness; damping: Style.spring.damping; epsilon: Style.spring.epsilon }
  }

  readonly property real capsuleInset: Style.bar.capsuleInset

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/neko/clock.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try { root.state = JSON.parse(text()) } catch (error) {}
    }
  }

  // Only while something moves; the countdown draws, neko-clock keeps time
  Timer {
    interval: 500
    repeat: true
    running: root.visible && (!!root.soonest || root.state.stopwatch.running)
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    tooltipText: root.ringing ? "Click to dismiss · Right click to snooze 5 min" : "Click to " + (root.running ? "pause" : "resume")
    onPressed: function(mouseButton) {
      if (root.ringing) {
        root.clock([mouseButton === Qt.RightButton ? "snooze" : "dismiss"])
      } else if (root.timer) {
        root.clock([root.timer.state === "running" ? "timer-pause" : "timer-resume", root.timer.id])
      } else {
        root.clock(["stopwatch-toggle"])
      }
    }

    // A timer's time left, as one stroke round the pill from twelve o'clock
    Item {
      id: progress
      anchors.fill: parent
      anchors.leftMargin: Style.space(3)
      anchors.rightMargin: Style.space(3)
      anchors.topMargin: root.capsuleInset + Style.space(2)
      anchors.bottomMargin: root.capsuleInset + Style.space(2)
      visible: !!root.timer && !root.ringing
      property real shownFraction: root.fraction
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
          strokeColor: progress.shownFraction > 0.001 ? NekoColor.accent : "transparent"
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
        id: glyph
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
  }
}
