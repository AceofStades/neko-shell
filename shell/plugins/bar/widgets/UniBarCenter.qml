import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "../../services/media/MediaModel.js" as MediaModel
import "../../control-center" as ControlCenterPlugin

// The UniBar's exact center: a minute clock at rest and the anchor from which
// notifications, OSDs, media, Pomodoro and settings grow. Its compact gestures
// keep common controls available without adding more permanent icons.
BarWidget {
  id: root
  moduleName: "neko.unibar-center"

  property date now: clock.date
  property real wheelAccumulator: 0
  readonly property string timeText: Qt.formatDateTime(now, String(setting("format", "HH:mm")))
  readonly property string hours: timeText.slice(0, 2)
  readonly property string minutes: timeText.slice(-2)

  readonly property var players: {
    var all = Mpris.players ? Mpris.players.values : []
    return all.filter(function(player) {
      return player && !MediaModel.isProxyPlayer(player) && MediaModel.hasTrackMetadata(player)
    })
  }
  readonly property var player: {
    var playing = null
    var spotify = null
    for (var i = 0; i < players.length; i++) {
      var candidate = players[i]
      var name = (String(candidate.identity || "") + " " + String(candidate.desktopEntry || "") + " " + String(candidate.dbusName || "")).toLowerCase()
      if (name.indexOf("spotify") >= 0) {
        if (candidate.isPlaying) return candidate
        spotify = candidate
      }
      if (candidate.isPlaying && !playing) playing = candidate
    }
    return playing || spotify || players[0] || null
  }
  readonly property bool playing: !!player && player.isPlaying
  // The whole UniBar is the island's compact shape. Bar.groupSpan crosses
  // the centered anchor, so this includes the monitor, both workspace banks
  // and every status control rather than just this clock slot.
  readonly property var islandGroupSpan: root.bar && typeof root.bar.groupSpan === "function"
    ? root.bar.groupSpan(root) : null
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

  // Keep the media island's IPC surface available in this layout even though
  // its old dedicated bar icon is folded into the clock.
  ShellIpc {
    target: "media-island"
    enabled: root.player !== null

    function status(): string {
      return JSON.stringify({
        available: root.player !== null,
        playing: root.playing,
        identity: root.player ? String(root.player.identity || "") : ""
      })
    }

    function show(): string {
      if (!root.player) return "no-player"
      Island.showMedia(root.player)
      return "ok"
    }

    function hide(): string {
      Island.mediaIconHovered = false
      Island.mediaPlayer = null
      return "ok"
    }
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
    // It hosts only the island window. Disabling its hidden workspace grid
    // keeps those ten invisible buttons out of the clock's click routing.
    enabled: false
    opacity: 0
    z: -10

    onXChanged: placeIsland()

    Behavior on x {
      enabled: !Style.reduceMotion
      SpringAnimation { spring: 3.2; damping: 0.36; epsilon: 0.25 }
    }
  }

  // The clock owns UniBar's control center directly, so opening it needs no
  // zero-width layout module beside the visible widgets. Its hidden button
  // contributes neither geometry nor a click target; the clock below is the
  // sole trigger and the shared KeyboardPanel morphs from this UniBar slot.
  ControlCenterPlugin.Panel {
    id: controlCenter
    anchors.fill: parent
    z: -5
    bar: root.bar
    settings: ({ hideButton: true, panelWidth: 440 })
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
    tooltipText: Island.pomodoroActive
      ? "Pomodoro " + Island.pomodoroClock(Island.pomodoroRemaining) + " · Right-click: pause/resume"
      : root.player ? "Middle-click: play/pause · Scroll: volume"
      : "Click: control center · Right-click: start Pomodoro · Scroll: volume"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.player && root.player.canTogglePlaying) root.player.togglePlaying()
      } else if (mouseButton === Qt.RightButton) {
        Island.togglePomodoro()
        Island.showPomodoro()
      } else {
        controlCenter.toggle()
      }
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

      // A tiny spectrum says music is active without spending another icon.
      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(5)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spaceReal(1.2)
        visible: root.playing

        Repeater {
          model: [0.45, 0.9, 0.62]

          Rectangle {
            id: level
            required property real modelData
            required property int index
            width: Style.spaceReal(1.6)
            height: Style.space(3) + Style.space(6) * shown
            radius: width / 2
            color: NekoColor.accent
            property real shown: 0.25 + index * 0.12

            SequentialAnimation on shown {
              running: root.playing
              loops: Animation.Infinite
              NumberAnimation { to: level.modelData; duration: 240 + level.index * 80; easing.type: Easing.InOutSine }
              NumberAnimation { to: 0.2 + level.index * 0.1; duration: 320 + level.index * 55; easing.type: Easing.InOutSine }
            }
          }
        }
      }

      // Pomodoro needs only a state light here; hovering the clock reveals
      // the full timer and its circular progress in the island.
      Rectangle {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        visible: Island.pomodoroActive
        width: Style.space(7)
        height: width
        radius: width / 2
        color: Island.pomodoroRunning ? NekoColor.accent : "transparent"
        border.width: Style.spaceReal(1.5)
        border.color: NekoColor.accent
      }
    }
  }
}
