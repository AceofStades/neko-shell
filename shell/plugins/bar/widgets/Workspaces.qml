import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "../../notifications/NotificationLogic.js" as NotificationLogic

// Workspaces 1 to 10, always all ten, written in kanji (一 to 十). The
// focused one sits on an accent pill; empty ones are dimmed.
//
// On a horizontal bar this is also the island (see Island): a notification,
// OSD or player grows out of the workspaces' capsule, with the
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
  readonly property bool topAttached: !root.vertical && !!root.bar && root.bar.centerTopAttached === true
  readonly property real restInset: Style.bar.capsuleInset
  readonly property real restTopInset: root.topAttached ? 0 : root.restInset
  readonly property real restBottomInset: root.restInset
  readonly property real restWidth: root.width + 2 * Style.bar.capsulePadding - 4
  readonly property real restHeight: root.height - root.restTopInset - root.restBottomInset

  // Glass like the bar's capsules, blurred by the compositor (neko.lua's
  // neko-island rule), with the bar's text color and the capsules' tint
  // (Bar.qml's glassIslandCapsule), so it grows out of its capsule unchanged
  // On glass the capsule and the island are tinted dark, so their text stays
  // white whatever color the rest of the bar picked
  readonly property bool glassBar: !!root.bar && root.bar.glass === true
  readonly property color islandText: root.glassBar ? "#f2f2f2" : root.bar ? root.bar.barForeground : NekoColor.foreground
  readonly property color islandColor: root.glassBar && root.bar.glassIslandCapsule ? root.bar.glassIslandCapsule : Qt.rgba(0, 0, 0, 0.32)
  readonly property color islandDim: Util.alpha(root.islandText, 0.65)
  readonly property color islandTrack: Util.alpha(root.islandText, 0.2)

  // Where the island's surface sits: over this widget, from the screen's
  // left edge (the bar floats in by its margin)
  property real islandLeft: 0

  function placeIsland() {
    var point = root.mapToItem(null, 0, 0)
    // Attached, the bar meets the screen's sides; floating, it's in by the margin
    root.islandLeft = Math.round((root.topAttached ? 0 : Style.bar.floatMargin) + point.x + (root.width - island.implicitWidth) / 2)
  }

  onIslandModeChanged: {
    if (root.islandMode !== "") {
      Island.settling = false
      placeIsland()
    } else {
      // Back into the capsule's shape first, then the swap (checkSettled)
      Island.settling = true
      settleTimer.restart()
      root.checkSettled()
    }
  }

  function checkSettled() {
    if (Island.settling && Math.abs(pill.width - root.restWidth) < 1.5 && Math.abs(pill.height - root.restHeight) < 1.5)
      Island.settling = false
  }

  // However the spring goes, the center group is back soon after
  Timer {
    id: settleTimer
    interval: 700
    onTriggered: Island.settling = false
  }
  onWidthChanged: placeIsland()

  // Once the bar has laid itself out, so the first show starts in place
  Timer {
    interval: 1000
    running: true
    onTriggered: root.placeIsland()
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  // A surface of its own above the bar, so the compositor blurs it like the
  // bar. It stays mapped (mapping one costs a frame or more) and clear while
  // idle, taking the pointer only over the pill while it shows something.
  PanelWindow {
    id: island

    screen: root.QsWindow.window ? root.QsWindow.window.screen : null
    visible: root.islandUp
    color: "transparent"
    implicitWidth: Style.space(520)
    implicitHeight: Style.space(190)
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "neko-island"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors.top: true
    anchors.left: true
    margins.top: root.topAttached ? 0 : Style.bar.floatMargin
    margins.left: root.islandLeft
    mask: Region { item: root.islandMode !== "" ? pill : null }

    // The shoulders of a card attached to the screen's top edge: beside its
    // top corners, each fills the corner between the edge and the card's side
    // with a curve turned away from the card, so the card flows out of the
    // edge rather than hanging below it. Same tint as the card's own edges.
    Shape {
      id: shoulders
      readonly property real size: Style.space(16)
      readonly property real cardLeft: pill.x
      readonly property real cardRight: pill.x + pill.width
      readonly property real cardTop: pill.y
      anchors.fill: parent
      visible: pill.flush && pill.opacity > 0 && pill.height > size
      opacity: pill.opacity
      preferredRendererType: Shape.CurveRenderer

      // Each shoulder stacks like the card's edge beside it: the card's tint,
      // then the same wash the card lays over it (accent on the left, a hint
      // of the text color on the right), so the two read as one surface
      ShapePath {
        fillColor: pill.color
        strokeWidth: 0
        strokeColor: "transparent"
        startX: shoulders.cardLeft - shoulders.size
        startY: shoulders.cardTop
        PathLine { x: shoulders.cardLeft; y: shoulders.cardTop }
        PathLine { x: shoulders.cardLeft; y: shoulders.cardTop + shoulders.size }
        PathArc { x: shoulders.cardLeft - shoulders.size; y: shoulders.cardTop; radiusX: shoulders.size; radiusY: shoulders.size; direction: PathArc.Counterclockwise }
      }
      ShapePath {
        fillColor: pill.card ? Util.alpha(root.accent, 0.14) : "transparent"
        strokeWidth: 0
        strokeColor: "transparent"
        startX: shoulders.cardLeft - shoulders.size
        startY: shoulders.cardTop
        PathLine { x: shoulders.cardLeft; y: shoulders.cardTop }
        PathLine { x: shoulders.cardLeft; y: shoulders.cardTop + shoulders.size }
        PathArc { x: shoulders.cardLeft - shoulders.size; y: shoulders.cardTop; radiusX: shoulders.size; radiusY: shoulders.size; direction: PathArc.Counterclockwise }
      }
      ShapePath {
        fillColor: pill.color
        strokeWidth: 0
        strokeColor: "transparent"
        startX: shoulders.cardRight + shoulders.size
        startY: shoulders.cardTop
        PathLine { x: shoulders.cardRight; y: shoulders.cardTop }
        PathLine { x: shoulders.cardRight; y: shoulders.cardTop + shoulders.size }
        PathArc { x: shoulders.cardRight + shoulders.size; y: shoulders.cardTop; radiusX: shoulders.size; radiusY: shoulders.size }
      }
      ShapePath {
        fillColor: pill.card ? Util.alpha(root.islandText, 0.025) : "transparent"
        strokeWidth: 0
        strokeColor: "transparent"
        startX: shoulders.cardRight + shoulders.size
        startY: shoulders.cardTop
        PathLine { x: shoulders.cardRight; y: shoulders.cardTop }
        PathLine { x: shoulders.cardRight; y: shoulders.cardTop + shoulders.size }
        PathArc { x: shoulders.cardRight + shoulders.size; y: shoulders.cardTop; radiusX: shoulders.size; radiusY: shoulders.size }
      }
    }

    Rectangle {
      id: pill
      readonly property real targetWidth: root.islandMode === "media" ? Style.space(460)
        : root.islandMode === "pomodoro" ? Style.space(400)
        : root.islandMode === "notification" ? Style.space(410)
        : root.islandMode === "osd" ? Style.space(175)
        : root.islandMode === "faceauth" ? Style.space(120) : root.restWidth
      readonly property real targetHeight: root.islandMode === "media" ? mediaView.implicitHeight
        : root.islandMode === "pomodoro" ? pomodoroView.implicitHeight
        : root.islandMode === "notification" ? notificationView.implicitHeight
        : root.islandMode === "osd" || root.islandMode === "faceauth" ? Style.space(80) : root.restHeight

      readonly property bool card: root.islandMode === "media" || root.islandMode === "pomodoro"
      readonly property real targetRadius: card ? Style.space(26) : height / 2
      x: Math.round((island.width - width) / 2)
      y: root.restTopInset
      width: targetWidth
      height: targetHeight
      radius: targetRadius
      // Attached to the screen's top edge, the top is flat and flush, and the
      // shoulders beside it (below) curve it into the edge, like a notch
      readonly property bool flush: root.topAttached
      topLeftRadius: flush ? 0 : targetRadius
      topRightRadius: flush ? 0 : targetRadius
      bottomLeftRadius: targetRadius
      bottomRightRadius: targetRadius
      color: card && !root.glassBar && NekoColor.bar.capsule.a > 0 ? NekoColor.bar.capsule : root.islandColor
      // Held while it shrinks back into the capsule, then swapped out
      opacity: root.islandMode !== "" || Island.settling ? 1 : 0
      clip: true

      // A soft spring between shapes, so a change of width and height at
      // once (the capsule into an OSD, say) settles together without a jolt
      Behavior on width {
        enabled: !Style.reduceMotion
        SpringAnimation { spring: 3.2; damping: 0.36; epsilon: 0.25 }
      }
      Behavior on height {
        enabled: !Style.reduceMotion
        SpringAnimation { spring: 3.2; damping: 0.36; epsilon: 0.25 }
      }
      // Swapped with the center group as fast both ways: in as it goes, and
      // out as it comes back once the pill has its shape again
      Behavior on opacity { NumberAnimation { duration: Style.duration(root.islandMode !== "" ? 70 : 90) } }
      onWidthChanged: root.checkSettled()
      onHeightChanged: root.checkSettled()

      // A quiet tonal wash gives the two interactive cards some depth while
      // leaving the compositor blur visible underneath.
      Rectangle {
        anchors.fill: parent
        visible: pill.card
        radius: parent.radius
        topLeftRadius: parent.topLeftRadius
        topRightRadius: parent.topRightRadius
        bottomLeftRadius: parent.bottomLeftRadius
        bottomRightRadius: parent.bottomRightRadius
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: Util.alpha(root.accent, 0.14) }
          GradientStop { position: 0.42; color: Util.alpha(root.accent, 0.035) }
          GradientStop { position: 1; color: Util.alpha(root.islandText, 0.025) }
        }
      }

      // An outline only on a floating card: against the screen's edge it
      // would draw a seam where the shoulders join
      Rectangle {
        anchors.fill: parent
        visible: pill.card && !pill.flush
        radius: parent.radius
        topLeftRadius: parent.topLeftRadius
        topRightRadius: parent.topRightRadius
        bottomLeftRadius: parent.bottomLeftRadius
        bottomRightRadius: parent.bottomRightRadius
        color: "transparent"
        border.width: 1
        border.color: Util.alpha(root.islandText, 0.11)
      }

      HoverHandler {
        onHoveredChanged: Island.hovered = hovered
      }

      // Volume, brightness and the rest: a large glyph with its meter below.
      // Screen brightness shows its sixteen steps, and anything with only a
      // few levels (the keyboard backlight) a segment per level.
      Column {
        id: osdView
        // In a beat after the shape starts to form, so the glyph and meter
        // grow into a pill that's nearly there; out at once, before it shrinks
        property bool shown: false
        readonly property bool wanted: root.islandMode === "osd"
        onWantedChanged: {
          if (wanted) osdIn.restart()
          else { osdIn.stop(); shown = false }
        }
        Timer {
          id: osdIn
          interval: Style.duration(110)
          onTriggered: osdView.shown = true
        }

        // Held up off the pill's bottom edge; the glyph's line already leaves
        // room under it, so the meter needs little more
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(18)
        spacing: Style.space(3)
        opacity: shown ? 1 : 0
        scale: shown ? 1 : 0.82
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(osdView.shown ? 220 : 90); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutBack; easing.overshoot: 1.3 } }

        readonly property real fraction: Island.osd && Island.osd.maxValue > 0 ? Math.max(0, Math.min(1, Island.osd.value / Island.osd.maxValue)) : 0
        readonly property int segments: !Island.osd ? 0 : Island.osd.maxValue === 64 ? 16 : Island.osd.maxValue <= 10 ? Island.osd.maxValue : 0
        readonly property bool stepped: segments > 0

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: Island.osd ? Island.osd.icon : ""
          color: root.islandText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.round(Style.font.display * 1.35)
        }

        // A continuous meter
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !!Island.osd && Island.osd.hasProgress && !parent.stepped
          width: Style.space(124)
          height: Style.space(6)
          radius: height / 2
          color: root.islandTrack

          Rectangle {
            height: parent.height
            radius: height / 2
            width: parent.parent.fraction > 0 ? Math.max(height, parent.width * parent.parent.fraction) : 0
            color: root.accent
            Behavior on width { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
          }
        }

        // One segment per step, the fine steps (of brightness) filling it
        Row {
          id: steps
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !!Island.osd && Island.osd.hasProgress && parent.stepped
          spacing: Style.space(2)
          readonly property real filled: parent.fraction * parent.segments

          Repeater {
            model: steps.parent.segments
            Rectangle {
              required property int index
              // Sixteen dots, or a few dashes across the same width
              width: steps.parent.segments > 10 ? Style.space(6) : Math.round((Style.space(124) - steps.spacing * (steps.parent.segments - 1)) / steps.parent.segments)
              height: Style.space(6)
              radius: height / 2
              color: root.islandTrack

              Rectangle {
                height: parent.height
                radius: height / 2
                width: parent.width * Math.max(0, Math.min(1, steps.filled - parent.index))
                color: root.accent
              }
            }
          }
        }
      }

      // Face unlock: the face in its frame, breathing while Howdy looks. Let
      // in, it pops into a check with a ring rippling out; turned away, it
      // shakes its head and becomes a cross.
      Item {
        id: faceAuthView
        // In a beat after the shape starts to form, as the OSD does
        property bool shown: false
        readonly property bool wanted: root.islandMode === "faceauth"
        onWantedChanged: {
          if (wanted) faceAuthIn.restart()
          else { faceAuthIn.stop(); shown = false }
        }
        Timer {
          id: faceAuthIn
          interval: Style.duration(110)
          onTriggered: faceAuthView.shown = true
        }

        readonly property string state: Island.faceAuth
        // Kept while the pill closes, so it doesn't blank as it shrinks
        property string shownState: "scanning"
        onStateChanged: {
          if (state === "") return
          shownState = state
          approvedAnimation.stop()
          failedAnimation.stop()
          if (state === "scanning") {
            faceGlyph.opacity = 1
            faceGlyph.scale = 1
            faceGlyph.color = root.islandText
            resultGlyph.opacity = 0
            ring.opacity = 0
            shake.x = 0
          } else if (state === "approved") {
            approvedAnimation.restart()
          } else if (state === "failed") {
            failedAnimation.restart()
          }
        }

        readonly property real glyphSize: Math.round(Style.font.display * 1.35)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(16)
        width: glyphSize * 1.6
        height: glyphSize * 1.25
        opacity: shown ? 1 : 0
        scale: shown ? 1 : 0.82
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(faceAuthView.shown ? 220 : 90); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: Style.duration(320); easing.type: Easing.OutBack; easing.overshoot: 1.3 } }
        transform: Translate { id: shake }

        // The ripple a check sends out
        Rectangle {
          id: ring
          anchors.centerIn: parent
          width: faceAuthView.glyphSize
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Style.space(2)
          border.color: root.accent
          opacity: 0
        }

        Text {
          id: faceGlyph
          anchors.centerIn: parent
          text: "\u{F0C7B}"
          color: root.islandText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: faceAuthView.glyphSize

          // Breathes while it looks
          SequentialAnimation on opacity {
            running: faceAuthView.visible && faceAuthView.shownState === "scanning" && !Style.reduceMotion
            loops: Animation.Infinite
            onRunningChanged: if (!running && faceAuthView.shownState === "scanning") faceGlyph.opacity = 1
            NumberAnimation { to: 0.4; duration: Style.duration(650); easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: Style.duration(650); easing.type: Easing.InOutSine }
          }
        }

        Text {
          id: resultGlyph
          anchors.centerIn: parent
          text: faceAuthView.shownState === "failed" ? "\u{F0156}" : "\u{F012C}"
          color: faceAuthView.shownState === "failed" ? NekoColor.urgent : root.accent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: faceAuthView.glyphSize
          opacity: 0
        }

        SequentialAnimation {
          id: approvedAnimation
          // The face draws in a little, as if taking a breath...
          ParallelAnimation {
            NumberAnimation { target: faceGlyph; property: "opacity"; to: 0; duration: Style.duration(140); easing.type: Easing.InCubic }
            NumberAnimation { target: faceGlyph; property: "scale"; to: 0.6; duration: Style.duration(140); easing.type: Easing.InCubic }
          }
          // ...and pops out as a check, a ring rippling away from it
          ParallelAnimation {
            NumberAnimation { target: resultGlyph; property: "opacity"; from: 0; to: 1; duration: Style.duration(120) }
            NumberAnimation { target: resultGlyph; property: "scale"; from: 0.4; to: 1; duration: Style.duration(380); easing.type: Easing.OutBack; easing.overshoot: 2.2 }
            NumberAnimation { target: ring; property: "scale"; from: 0.7; to: 2.1; duration: Style.duration(560); easing.type: Easing.OutCubic }
            NumberAnimation { target: ring; property: "opacity"; from: 0.9; to: 0; duration: Style.duration(560); easing.type: Easing.OutCubic }
          }
        }

        SequentialAnimation {
          id: failedAnimation
          ColorAnimation { target: faceGlyph; property: "color"; to: NekoColor.urgent; duration: Style.duration(90) }
          // A shake of the head
          SequentialAnimation {
            NumberAnimation { target: shake; property: "x"; to: -Style.space(9); duration: Style.duration(50); easing.type: Easing.OutSine }
            NumberAnimation { target: shake; property: "x"; to: Style.space(8); duration: Style.duration(90); easing.type: Easing.InOutSine }
            NumberAnimation { target: shake; property: "x"; to: -Style.space(6); duration: Style.duration(80); easing.type: Easing.InOutSine }
            NumberAnimation { target: shake; property: "x"; to: Style.space(4); duration: Style.duration(70); easing.type: Easing.InOutSine }
            NumberAnimation { target: shake; property: "x"; to: -Style.space(2); duration: Style.duration(60); easing.type: Easing.InOutSine }
            NumberAnimation { target: shake; property: "x"; to: 0; duration: Style.duration(50); easing.type: Easing.OutSine }
          }
          // Then the face gives way to a cross
          ParallelAnimation {
            NumberAnimation { target: faceGlyph; property: "opacity"; to: 0; duration: Style.duration(140) }
            NumberAnimation { target: faceGlyph; property: "scale"; to: 0.7; duration: Style.duration(140) }
            NumberAnimation { target: resultGlyph; property: "opacity"; from: 0; to: 1; duration: Style.duration(160) }
            NumberAnimation { target: resultGlyph; property: "scale"; from: 0.6; to: 1; duration: Style.duration(260); easing.type: Easing.OutBack }
          }
        }
      }

      // Now playing: artwork gets its own framed stage, while metadata,
      // transport and the seek line form a quieter control deck beside it.
      Item {
        id: mediaView
        // Kept while the card closes, so it doesn't blank as it shrinks
        property var player: null
        readonly property var live: Island.mediaPlayer
        onLiveChanged: if (live) player = live
        readonly property real length: player ? Number(player.length) || 0 : 0
        readonly property real position: player ? Number(player.position) || 0 : 0
        // While the seek bar is dragged, where it's been dragged to (0..1)
        property real dragFraction: -1
        readonly property real fraction: dragFraction >= 0 ? dragFraction : length > 0 ? Math.min(1, position / length) : 0
        readonly property real pad: Style.space(16)
        readonly property real art: Style.space(104)
        readonly property bool spotify: !!player && (String(player.identity || "") + String(player.desktopEntry || "")).toLowerCase().indexOf("spotify") >= 0
        readonly property string sourceName: !player ? "PLAYER" : spotify ? "SPOTIFY" : String(player.identity || "PLAYER").toUpperCase()

        function clock(seconds) {
          var s = Math.max(0, Math.floor(seconds))
          var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), r = s % 60
          return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (r < 10 ? "0" : "") + r
        }

        anchors.fill: parent
        implicitHeight: Style.space(168)
        opacity: root.islandMode === "media" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(220) } }

        // The player doesn't announce its position as it plays; ask for it
        Timer {
          interval: 500
          repeat: true
          running: mediaView.visible && !!mediaView.player && mediaView.player.isPlaying
          onTriggered: mediaView.player.positionChanged()
        }

        Rectangle {
          x: mediaView.pad - Style.space(2)
          y: mediaView.pad - Style.space(2)
          width: mediaView.art + Style.space(4)
          height: width
          radius: Style.space(18)
          color: Util.alpha(root.accent, 0.13)
          border.width: 1
          border.color: Util.alpha(root.islandText, 0.12)
        }

        ClippingRectangle {
          id: mediaArtBox
          x: mediaView.pad
          y: mediaView.pad
          width: mediaView.art
          height: mediaView.art
          radius: Style.space(16)
          color: Util.alpha(root.islandText, 0.07)

          Image {
            id: mediaArt
            anchors.fill: parent
            source: mediaView.player && mediaView.player.trackArtUrl ? String(mediaView.player.trackArtUrl) : ""
            sourceSize.width: width * 2
            sourceSize.height: height * 2
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            visible: status === Image.Ready
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(42)
            visible: mediaArt.status === Image.Ready
            gradient: Gradient {
              GradientStop { position: 0; color: "transparent" }
              GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.72) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            width: artState.implicitWidth + Style.space(14)
            height: Style.space(22)
            radius: height / 2
            color: Qt.rgba(0, 0, 0, 0.56)

            Text {
              id: artState
              anchors.centerIn: parent
              text: mediaView.player && mediaView.player.isPlaying ? "PLAYING" : "PAUSED"
              color: "#f5f5f5"
              font.pixelSize: Style.font.caption - 1
              font.weight: Font.Bold
              font.letterSpacing: Style.spaceReal(0.7)
            }
          }

          Text {
            anchors.centerIn: parent
            visible: mediaArt.status !== Image.Ready
            text: "󰝚"
            color: root.islandDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
        }

        Text {
          x: mediaView.pad + mediaView.art + Style.space(18)
          y: mediaView.pad + Style.space(1)
          text: mediaView.player && mediaView.player.isPlaying ? "NOW PLAYING" : "PLAYBACK PAUSED"
          color: root.accent
          font.pixelSize: Style.font.caption
          font.weight: Font.Bold
          font.letterSpacing: Style.spaceReal(0.8)
        }

        // Source badge and a tiny live equalizer make playback state legible
        // without competing with the title.
        Rectangle {
          id: mediaSourceBadge
          anchors.right: parent.right
          anchors.rightMargin: mediaView.pad
          y: mediaView.pad - Style.space(3)
          width: sourceBadgeRow.implicitWidth + Style.space(14)
          height: Style.space(25)
          radius: height / 2
          color: Util.alpha(root.islandText, 0.075)
          border.width: 1
          border.color: Util.alpha(root.islandText, 0.09)

          Row {
            id: sourceBadgeRow
            anchors.centerIn: parent
            spacing: Style.space(7)

            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Repeater {
                model: [0.55, 1, 0.72]
                Rectangle {
                  id: eqBar
                  required property real modelData
                  required property int index
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(2)
                  radius: width / 2
                  color: mediaView.spotify ? "#1ed760" : root.accent
                  property real level: 0.3
                  height: Math.max(width, Style.space(11) * level)
                  SequentialAnimation on level {
                    running: mediaView.visible && !!mediaView.player && mediaView.player.isPlaying
                    loops: Animation.Infinite
                    NumberAnimation { to: eqBar.modelData; duration: 250 + eqBar.index * 80; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0.25 + eqBar.index * 0.1; duration: 330 + eqBar.index * 60; easing.type: Easing.InOutSine }
                  }
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: mediaView.sourceName
              color: mediaView.spotify ? "#1ed760" : root.islandDim
              font.pixelSize: Style.font.caption - 1
              font.weight: Font.Bold
              font.letterSpacing: Style.spaceReal(0.5)
              elide: Text.ElideRight
              maximumLineCount: 1
            }
          }
        }

        Text {
          x: mediaView.pad + mediaView.art + Style.space(18)
          y: mediaView.pad + Style.space(28)
          width: parent.width - x - mediaView.pad
          textFormat: Text.PlainText
          text: mediaView.player ? (mediaView.player.trackTitle || mediaView.player.identity || "Nothing playing") : "Nothing playing"
          color: root.islandText
          font.pixelSize: Style.font.title + 2
          font.weight: Font.Bold
          elide: Text.ElideRight
        }

        Text {
          x: mediaView.pad + mediaView.art + Style.space(18)
          y: mediaView.pad + Style.space(55)
          width: parent.width - x - mediaView.pad
          textFormat: Text.PlainText
          text: mediaView.player ? [mediaView.player.trackArtist, mediaView.player.trackAlbum].filter(function(t) { return !!t }).join("  •  ") : ""
          color: root.islandDim
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Item {
          x: mediaView.pad + mediaView.art + Style.space(12)
          y: mediaView.pad + Style.space(74)
          width: parent.width - x - mediaView.pad + Style.space(6)
          height: Style.space(44)

          Row {
            anchors.centerIn: parent
            spacing: Style.space(2)
            MediaButton {
              visible: !!mediaView.player && mediaView.player.shuffleSupported
              glyph: "󰒝"
              lit: !!mediaView.player && mediaView.player.shuffle
              onClicked: mediaView.player.shuffle = !mediaView.player.shuffle
            }
            MediaButton { glyph: "󰒮"; enabled: !!mediaView.player && mediaView.player.canGoPrevious; onClicked: mediaView.player.previous() }
            MediaButton {
              glyph: mediaView.player && mediaView.player.isPlaying ? "󰏤" : "󰐊"
              big: true
              enabled: !!mediaView.player && mediaView.player.canTogglePlaying
              onClicked: mediaView.player.togglePlaying()
            }
            MediaButton { glyph: "󰒭"; enabled: !!mediaView.player && mediaView.player.canGoNext; onClicked: mediaView.player.next() }
            MediaButton {
              visible: !!mediaView.player && mediaView.player.loopSupported
              glyph: mediaView.player && mediaView.player.loopState === MprisLoopState.Track ? "󰑘" : "󰑖"
              lit: !!mediaView.player && mediaView.player.loopState !== MprisLoopState.None
              onClicked: mediaView.player.loopState = mediaView.player.loopState === MprisLoopState.None ? MprisLoopState.Playlist
                : mediaView.player.loopState === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None
            }
          }
        }

        // Time and seek sit on their own baseline across the whole card.
        Item {
          x: mediaView.pad
          y: Style.space(134)
          width: parent.width - 2 * mediaView.pad
          height: Style.space(22)

          Text {
            id: elapsed
            anchors.verticalCenter: parent.verticalCenter
            text: mediaView.clock(mediaView.fraction * mediaView.length)
            color: root.islandDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
          Item {
            id: seek
            x: Style.space(43)
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(86)
            height: parent.height
            readonly property bool seekable: !!mediaView.player && mediaView.player.canSeek && mediaView.length > 0

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width
              height: Style.space(5)
              radius: height / 2
              color: root.islandTrack

              Rectangle {
                height: parent.height
                radius: height / 2
                width: mediaView.fraction > 0 ? Math.max(height, parent.width * mediaView.fraction) : 0
                color: root.accent
                Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
              }
            }
            Rectangle {
              x: parent.width * mediaView.fraction - width / 2
              anchors.verticalCenter: parent.verticalCenter
              width: seekArea.containsMouse || seekArea.pressed ? Style.space(13) : Style.space(9)
              height: width
              radius: width / 2
              color: root.islandText
              visible: seek.seekable && (seekArea.containsMouse || seekArea.pressed)
              Behavior on width { NumberAnimation { duration: Style.duration(120) } }
              Behavior on opacity { NumberAnimation { duration: Style.duration(120) } }
            }
            MouseArea {
              id: seekArea
              anchors.fill: parent
              enabled: seek.seekable
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              function at(x) { return Math.max(0, Math.min(1, x / width)) }
              onPressed: function(mouse) { mediaView.dragFraction = at(mouse.x) }
              onPositionChanged: function(mouse) { if (pressed) mediaView.dragFraction = at(mouse.x) }
              onReleased: {
                if (mediaView.player) mediaView.player.position = mediaView.dragFraction * mediaView.length
                mediaView.dragFraction = -1
              }
            }
          }
          Text {
            id: total
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: mediaView.clock(mediaView.length)
            color: root.islandDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Pomodoro reads as a focused instrument: the remaining time lives in
      // a progress dial, while phase context and controls stay grouped.
      Item {
        id: pomodoroView
        readonly property int round: Island.pomodoroCompleted % 4 + 1
        readonly property string status: Island.pomodoroRunning
          ? "Ends at " + Qt.formatTime(new Date(Island.pomodoroTargetAt), "HH:mm")
          : Island.pomodoroActive ? "Paused" : "Ready when you are"
        readonly property string headline: Island.pomodoroRunning
          ? (Island.pomodoroPhase === "focus" ? "Stay in the flow" : "Take a real pause")
          : Island.pomodoroActive ? "Session paused" : "Begin a focus block"
        readonly property string nextPhase: Island.pomodoroPhase !== "focus" ? "Focus up next"
          : pomodoroView.round === 4 ? "Long break up next" : "Short break up next"

        anchors.fill: parent
        implicitHeight: Style.space(168)
        opacity: root.islandMode === "pomodoro" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(220) } }

        Item {
          id: pomodoroDial
          x: Style.space(16)
          y: Style.space(16)
          width: Style.space(136)
          height: width
          readonly property real arcRadius: width / 2 - Style.space(10)
          readonly property bool hasProgress: Island.pomodoroFraction > 0.002

          Rectangle {
            anchors.centerIn: parent
            width: parent.width - Style.space(28)
            height: width
            radius: width / 2
            color: Util.alpha(root.islandText, 0.035)
            border.width: 1
            border.color: Util.alpha(root.islandText, 0.055)
          }

          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
              strokeWidth: Style.space(6)
              strokeColor: Util.alpha(root.islandText, 0.13)
              fillColor: "transparent"
              capStyle: ShapePath.RoundCap
              PathAngleArc {
                centerX: pomodoroDial.width / 2
                centerY: pomodoroDial.height / 2
                radiusX: pomodoroDial.arcRadius
                radiusY: pomodoroDial.arcRadius
                startAngle: -90
                sweepAngle: 360
              }
            }

            ShapePath {
              strokeWidth: Style.space(14)
              strokeColor: pomodoroDial.hasProgress ? Util.alpha(root.accent, 0.14) : "transparent"
              fillColor: "transparent"
              capStyle: ShapePath.RoundCap
              PathAngleArc {
                centerX: pomodoroDial.width / 2
                centerY: pomodoroDial.height / 2
                radiusX: pomodoroDial.arcRadius
                radiusY: pomodoroDial.arcRadius
                startAngle: -90
                sweepAngle: 360 * Island.pomodoroFraction
              }
            }

            ShapePath {
              strokeWidth: Style.space(6)
              strokeColor: pomodoroDial.hasProgress ? root.accent : "transparent"
              fillColor: "transparent"
              capStyle: ShapePath.RoundCap
              PathAngleArc {
                centerX: pomodoroDial.width / 2
                centerY: pomodoroDial.height / 2
                radiusX: pomodoroDial.arcRadius
                radiusY: pomodoroDial.arcRadius
                startAngle: -90
                sweepAngle: 360 * Island.pomodoroFraction
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(1)

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: Island.pomodoroClock(Island.pomodoroRemaining)
              color: root.islandText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.displayLarge
              font.weight: Font.Bold
              font.features: { "tnum": 1 }
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "REMAINING"
              color: root.islandDim
              font.pixelSize: Style.font.caption - 1
              font.weight: Font.DemiBold
              font.letterSpacing: Style.spaceReal(0.7)
            }
          }

          Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(8)
            width: Style.space(7)
            height: width
            radius: width / 2
            color: Island.pomodoroRunning ? root.accent : root.islandDim
            opacity: Island.pomodoroActive ? 1 : 0.45

            SequentialAnimation on opacity {
              running: pomodoroView.visible && Island.pomodoroRunning
              loops: Animation.Infinite
              NumberAnimation { to: 0.35; duration: 850; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1; duration: 850; easing.type: Easing.InOutSine }
            }
          }
        }

        Item {
          x: Style.space(170)
          y: Style.space(17)
          width: parent.width - x - Style.space(18)
          height: parent.height - Style.space(32)

          Row {
            id: phaseMark
            spacing: Style.space(7)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Island.pomodoroPhase === "focus" ? "󰔛" : "󰒲"
              color: root.accent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Island.pomodoroTitle.toUpperCase()
              color: root.accent
              font.pixelSize: Style.font.caption
              font.weight: Font.Bold
              font.letterSpacing: Style.spaceReal(0.8)
            }
          }

          Rectangle {
            anchors.right: parent.right
            y: -Style.space(2)
            width: roundLabel.implicitWidth + Style.space(14)
            height: Style.space(24)
            radius: height / 2
            color: Util.alpha(root.islandText, 0.065)
            border.width: 1
            border.color: Util.alpha(root.islandText, 0.08)

            Text {
              id: roundLabel
              anchors.centerIn: parent
              text: "ROUND " + pomodoroView.round + "/4"
              color: root.islandDim
              font.pixelSize: Style.font.caption - 1
              font.weight: Font.Bold
              font.letterSpacing: Style.spaceReal(0.4)
            }
          }

          Text {
            y: Style.space(34)
            width: parent.width
            text: pomodoroView.headline
            color: root.islandText
            font.pixelSize: Style.font.title + 2
            font.weight: Font.Bold
            elide: Text.ElideRight
          }

          Text {
            y: Style.space(59)
            width: parent.width
            text: pomodoroView.status + "  •  " + pomodoroView.nextPhase
            color: root.islandDim
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Row {
            y: Style.space(82)
            spacing: Style.space(6)

            Repeater {
              model: 4
              Rectangle {
                required property int index
                width: index === pomodoroView.round - 1 ? Style.space(25) : Style.space(10)
                height: Style.space(6)
                radius: height / 2
                color: index < pomodoroView.round ? root.accent : root.islandTrack
                opacity: index === pomodoroView.round - 1 ? 1 : index < pomodoroView.round ? 0.5 : 1
                Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: Island.pomodoroCompleted + " completed"
              color: root.islandDim
              font.pixelSize: Style.font.caption - 1
            }
          }

          Row {
            y: Style.space(105)
            spacing: Style.space(8)

            PomodoroButton {
              glyph: "󰑓"
              enabled: Island.pomodoroActive
              onClicked: Island.resetPomodoro()
            }
            PomodoroButton {
              glyph: Island.pomodoroRunning ? "󰏤" : "󰐊"
              label: Island.pomodoroRunning ? "Pause" : Island.pomodoroActive ? "Resume" : "Start"
              primary: true
              onClicked: Island.togglePomodoro()
            }
            PomodoroButton {
              glyph: "󰒭"
              enabled: Island.pomodoroActive
              onClicked: Island.skipPomodoro()
            }
          }
        }
      }

      // The newest notification: its icon, the app, the summary and the body
      Item {
        id: notificationView
        readonly property var n: Island.current
        readonly property string iconUrl: n ? (n.image ? n.image : root.iconSource(n.appIcon)) : ""
        readonly property string bodyText: n ? NotificationLogic.sanitizeBody(n.body, n.app, n.appIcon) : ""

        anchors.fill: parent
        implicitHeight: Math.max(Style.space(38), texts.implicitHeight) + 2 * Style.space(11)
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
          anchors.margins: Style.space(11)
          anchors.leftMargin: Style.space(22)
          anchors.rightMargin: Style.space(24)
          spacing: Style.space(12)

          Item {
            Layout.preferredWidth: Style.space(38)
            Layout.preferredHeight: Style.space(38)
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
                color: root.accent
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
              font.pixelSize: Style.font.title
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
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              elide: Text.ElideRight
              maximumLineCount: 2
            }
          }
        }
      }
    }
  }

  GridLayout {
    id: grid
    anchors.fill: parent
    // The workspace cells give way as the island becomes the player.
    // Gone at once as the island takes over, and back as quickly once it has
    // shrunk into the capsule's shape again
    opacity: root.islandMode === "" && !Island.settling ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(root.islandMode === "" ? 90 : 50) } }
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

        // The focused one's marker: a circle as wide as the cell and the
        // capsule allow
        Rectangle {
          readonly property real size: Math.min(cell.width - Style.space(2), cell.height - 2 * Style.bar.capsuleInset - Style.space(4))
          anchors.centerIn: parent
          width: size
          height: size
          radius: size / 2
          color: Util.alpha(root.accent, 0.22)
          opacity: cell.focused ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 140 } }
        }

        Text {
          anchors.centerIn: parent
          opacity: cell.shown
          text: root.kanji[cell.index]
          color: cell.focused ? root.accent : root.glassBar ? root.islandText : cell.foreground
          font.family: root.kanjiFamily || cell.fontFamily
          font.pixelSize: Style.bar.fontSize
          font.weight: cell.focused ? Font.Bold : Font.Normal
        }
      }
    }
  }

  // A media control in the island: a glyph that lights on hover
  component MediaButton: Item {
    id: mediaButton
    property string glyph: ""
    property bool big: false
    // A toggle that's on (shuffle, repeat)
    property bool lit: false
    signal clicked()

    width: big ? Style.space(42) : Style.space(34)
    height: width
    opacity: enabled ? 1 : 0.35
    scale: buttonArea.containsMouse && enabled ? 1.07 : 1

    Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: mediaButton.big ? (buttonArea.containsMouse ? Qt.lighter(root.accent, 1.15) : root.accent)
        : mediaButton.lit ? Util.alpha(root.accent, 0.18)
        : Util.alpha(root.islandText, buttonArea.containsMouse ? 0.11 : 0.045)
      border.width: mediaButton.big || mediaButton.lit ? 1 : 0
      border.color: mediaButton.big ? Util.alpha(root.islandText, 0.22) : Util.alpha(root.accent, 0.34)
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }
    Text {
      anchors.centerIn: parent
      text: mediaButton.glyph
      color: mediaButton.big ? "#101010" : mediaButton.lit ? root.accent : root.islandText
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: mediaButton.big ? Style.font.title + 5 : Style.font.title
    }
    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: mediaButton.clicked()
    }
  }

  component PomodoroButton: Item {
    id: pomodoroButton
    property string glyph: ""
    property string label: ""
    property bool primary: false
    signal clicked()

    width: primary ? Style.space(92) : Style.space(38)
    height: Style.space(38)
    opacity: enabled ? 1 : 0.3
    scale: pomodoroButtonArea.containsMouse && enabled ? 1.05 : 1

    Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: pomodoroButton.primary ? (pomodoroButtonArea.containsMouse ? Qt.lighter(root.accent, 1.15) : root.accent)
        : Util.alpha(root.islandText, pomodoroButtonArea.containsMouse ? 0.12 : 0.05)
      border.width: 1
      border.color: pomodoroButton.primary ? Util.alpha(root.islandText, 0.2) : Util.alpha(root.islandText, 0.08)
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(7)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: pomodoroButton.glyph
        color: pomodoroButton.primary ? "#101010" : root.islandText
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: pomodoroButton.primary ? Style.font.title + 2 : Style.font.title
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: pomodoroButton.primary && pomodoroButton.label !== ""
        text: pomodoroButton.label
        color: "#101010"
        font.pixelSize: Style.font.bodySmall
        font.weight: Font.Bold
      }
    }
    MouseArea {
      id: pomodoroButtonArea
      anchors.fill: parent
      enabled: pomodoroButton.enabled
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: pomodoroButton.clicked()
    }
  }
}
