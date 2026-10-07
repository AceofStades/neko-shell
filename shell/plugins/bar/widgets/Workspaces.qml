import QtQuick
import QtQuick.Layouts
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
// On a horizontal bar this is also the island (see Island): a notification
// or an OSD grows a dark pill out of the workspaces' capsule to show it, the
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
  readonly property real restInset: Style.bar.capsuleInset
  readonly property real restWidth: root.width + 2 * Style.bar.capsulePadding - 4
  readonly property real restHeight: root.height - 2 * root.restInset

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
    root.islandLeft = Math.round(Style.bar.floatMargin + point.x + (root.width - island.implicitWidth) / 2)
  }

  onIslandModeChanged: if (root.islandMode !== "") placeIsland()
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
    implicitWidth: Style.space(460)
    implicitHeight: Math.max(Style.space(150), root.height - root.restInset + Style.space(4) + mediaView.implicitHeight + Style.space(4))
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "neko-island"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors.top: true
    anchors.left: true
    margins.top: Style.bar.floatMargin
    margins.left: root.islandLeft
    mask: Region { item: root.islandMode !== "" ? pill : null }

    Rectangle {
      id: pill
      readonly property real targetWidth: root.islandMode === "media" ? Style.space(440)
        : root.islandMode === "notification" ? Style.space(360)
        : root.islandMode === "osd" ? Style.space(150) : root.restWidth
      readonly property real targetHeight: root.islandMode === "media" ? mediaView.implicitHeight
        : root.islandMode === "notification" ? notificationView.implicitHeight
        : root.islandMode === "osd" ? Style.space(66) : root.restHeight

      // Keep the media card four pixels below the workspace capsule.
      readonly property bool card: root.islandMode === "media"
      x: Math.round((island.width - width) / 2)
      y: card ? root.height - root.restInset + Style.space(4) : root.restInset
      Behavior on y { NumberAnimation { duration: Style.duration(420); easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
      width: targetWidth
      height: targetHeight
      radius: card ? Style.space(24) : height / 2
      color: card && !root.glassBar && NekoColor.bar.capsule.a > 0 ? NekoColor.bar.capsule : root.islandColor
      opacity: root.islandMode !== "" ? 1 : 0
      clip: true

      Behavior on width { NumberAnimation { duration: Style.duration(420); easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
      Behavior on height { NumberAnimation { duration: Style.duration(420); easing.type: Easing.OutBack; easing.overshoot: 1.1 } }
      Behavior on opacity { NumberAnimation { duration: Style.duration(root.islandMode !== "" ? 120 : 320) } }

      HoverHandler {
        onHoveredChanged: Island.hovered = hovered
      }

      // Volume, brightness and the rest: a large glyph with its meter below.
      // Screen brightness shows its sixteen steps, and anything with only a
      // few levels (the keyboard backlight) a segment per level.
      Column {
        anchors.centerIn: parent
        spacing: Style.space(8)
        opacity: root.islandMode === "osd" ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }

        readonly property real fraction: Island.osd && Island.osd.maxValue > 0 ? Math.max(0, Math.min(1, Island.osd.value / Island.osd.maxValue)) : 0
        readonly property int segments: !Island.osd ? 0 : Island.osd.maxValue === 64 ? 16 : Island.osd.maxValue <= 10 ? Island.osd.maxValue : 0
        readonly property bool stepped: segments > 0

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: Island.osd ? Island.osd.icon : ""
          color: root.islandText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Math.round(Style.font.display * 1.15)
        }

        // A continuous meter
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !!Island.osd && Island.osd.hasProgress && !parent.stepped
          width: Style.space(104)
          height: Style.space(5)
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
              width: steps.parent.segments > 10 ? Style.space(5) : Math.round((Style.space(104) - steps.spacing * (steps.parent.segments - 1)) / steps.parent.segments)
              height: Style.space(5)
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

      // A player's card: art, track, controls and a seek bar, with an
      // equalizer that moves while it plays.
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
        readonly property real art: Style.space(80)
        readonly property bool spotify: !!player && (String(player.identity || "") + String(player.desktopEntry || "")).toLowerCase().indexOf("spotify") >= 0

        function clock(seconds) {
          var s = Math.max(0, Math.floor(seconds))
          var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), r = s % 60
          return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (r < 10 ? "0" : "") + r
        }

        anchors.fill: parent
        implicitHeight: pad + art + Style.space(14) + Style.space(16) + pad
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

        ClippingRectangle {
          id: mediaArtBox
          x: mediaView.pad
          y: mediaView.pad
          width: mediaView.art
          height: mediaView.art
          radius: Style.space(14)
          color: Util.alpha(root.islandText, 0.08)

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
          Text {
            anchors.centerIn: parent
            visible: mediaArt.status !== Image.Ready
            text: "󰝚"
            color: root.islandDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.displayLarge
          }
        }

        // The app's mark, with an equalizer that dances while it plays
        Row {
          id: mediaMark
          anchors.right: parent.right
          anchors.rightMargin: mediaView.pad + Style.space(2)
          y: mediaView.pad
          spacing: Style.space(8)

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Repeater {
              model: [0.55, 1, 0.7, 0.85]
              Rectangle {
                id: eqBar
                required property real modelData
                required property int index
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(3)
                radius: width / 2
                color: root.accent
                property real level: 0.35
                height: Math.max(width, Style.space(13) * level)
                SequentialAnimation on level {
                  running: mediaView.visible && !!mediaView.player && mediaView.player.isPlaying
                  loops: Animation.Infinite
                  NumberAnimation { to: eqBar.modelData; duration: 260 + eqBar.index * 70; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 0.25 + eqBar.index * 0.08; duration: 300 + eqBar.index * 50; easing.type: Easing.InOutSine }
                }
              }
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: mediaView.spotify ? "󰓇" : "󰝚"
            color: mediaView.spotify ? "#1ed760" : root.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.bar.iconFont + 2
          }
        }

        Column {
          x: mediaView.pad + mediaView.art + Style.space(16)
          y: mediaView.pad
          width: parent.width - x - mediaView.pad
          height: mediaView.art
          spacing: Style.space(2)

          Text {
            width: parent.width - mediaMark.width - Style.space(10)
            textFormat: Text.PlainText
            text: mediaView.player ? (mediaView.player.trackTitle || mediaView.player.identity || "") : ""
            color: root.islandText
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: mediaView.player ? [mediaView.player.trackArtist, mediaView.player.trackAlbum].filter(function(t) { return !!t }).join("  ·  ") : ""
            color: root.islandDim
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Item { width: 1; height: Style.space(6) }

          // Shuffle, back, play, forward, repeat
          Row {
            spacing: Style.space(6)
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

        // Where the track is, with a bar to drag or click to move it
        Row {
          x: mediaView.pad
          y: mediaView.pad + mediaView.art + Style.space(14)
          width: parent.width - 2 * mediaView.pad
          height: Style.space(16)
          spacing: Style.space(10)

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
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - elapsed.width - total.width - 2 * parent.spacing
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
                width: Math.max(height, parent.width * mediaView.fraction)
                color: root.accent
              }
            }
            Rectangle {
              x: parent.width * mediaView.fraction - width / 2
              anchors.verticalCenter: parent.verticalCenter
              width: seekArea.containsMouse || seekArea.pressed ? Style.space(13) : Style.space(9)
              height: width
              radius: width / 2
              color: root.islandText
              visible: seek.seekable
              Behavior on width { NumberAnimation { duration: Style.duration(120) } }
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
            anchors.verticalCenter: parent.verticalCenter
            text: mediaView.clock(mediaView.length)
            color: root.islandDim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
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
        implicitHeight: Math.max(Style.space(32), texts.implicitHeight) + 2 * Style.space(9)
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
          anchors.margins: Style.space(9)
          anchors.leftMargin: Style.space(20)
          anchors.rightMargin: Style.space(22)
          spacing: Style.space(10)

          Item {
            Layout.preferredWidth: Style.space(32)
            Layout.preferredHeight: Style.space(32)
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
              font.pixelSize: Style.font.body
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
              font.pixelSize: Style.font.bodySmall
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
    // Keep the workspaces visible while the separate media card is open.
    opacity: root.islandMode === "" || root.islandMode === "media" ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
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

    width: big ? Style.space(36) : Style.space(30)
    height: width
    opacity: enabled ? 1 : 0.35

    // The big one (play) is filled with the accent; the rest light on hover
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: mediaButton.big ? (buttonArea.containsMouse ? Qt.lighter(root.accent, 1.15) : root.accent)
        : Util.alpha(root.islandText, buttonArea.containsMouse ? 0.16 : 0)
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }
    Text {
      anchors.centerIn: parent
      text: mediaButton.glyph
      color: mediaButton.big ? "#101010" : mediaButton.lit ? root.accent : root.islandText
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: mediaButton.big ? Style.font.title + 4 : Style.font.title
    }
    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: mediaButton.clicked()
    }
  }
}
