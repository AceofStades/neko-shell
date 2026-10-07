import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "../../services/media/MediaModel.js" as MediaModel

// One music control sits beside the workspace island. Its concave edge
// follows the workspace capsule with a gap, then fades as the island grows
// into the selected player, an OSD or a notification.
BarWidget {
  id: root
  moduleName: "neko.media-players"
  readonly property bool ownCapsule: true

  readonly property var players: {
    var all = Mpris.players ? Mpris.players.values : []
    return all.filter(function(p) { return p && !MediaModel.isProxyPlayer(p) && MediaModel.hasTrackMetadata(p) })
  }
  readonly property var player: {
    var playing = null
    var spotify = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      var name = (String(p.identity || "") + " " + String(p.desktopEntry || "") + " " + String(p.dbusName || "")).toLowerCase()
      if (name.indexOf("spotify") >= 0) {
        if (p.isPlaying) return p
        spotify = p
      }
      if (p.isPlaying && !playing) playing = p
    }
    return playing || spotify || players[0] || null
  }
  readonly property bool spotifyPlayer: !!player && (String(player.identity || "") + " " + String(player.desktopEntry || "") + " " + String(player.dbusName || "")).toLowerCase().indexOf("spotify") >= 0
  readonly property bool playing: !!player && player.isPlaying
  readonly property string iconUrl: player && !spotifyPlayer ? iconFor(player) : ""

  function iconFor(player) {
    var identity = String(player.identity || "")
    var desktopEntry = String(player.desktopEntry || "")
    var dbusApp = String(player.dbusName || "").replace(/^org\.mpris\.MediaPlayer2\./, "").replace(/\.instance.*$/, "")
    var chrome = /(^|[^a-z])chrome([^a-z]|$)/i.test(identity + " " + desktopEntry + " " + dbusApp)
    var names = chrome ? ["google-chrome", "com.google.Chrome"] : []
    var raw = [desktopEntry, identity, MediaModel.playerAppLabel(player), dbusApp]
    for (var i = 0; i < raw.length; i++) {
      var name = String(raw[i] || "").trim()
      if (!name) continue
      names.push(name)
      names.push(name.replace(/\.desktop$/i, "").toLowerCase().replace(/\s+/g, "-"))
    }

    for (var j = 0; j < names.length; j++) {
      var entry = typeof DesktopEntries.heuristicLookup === "function" ? DesktopEntries.heuristicLookup(names[j]) : DesktopEntries.byId(names[j])
      if (entry && entry.icon) {
        var desktopIcon = Quickshell.iconPath(entry.icon, true)
        if (desktopIcon) return desktopIcon
      }
    }
    for (var k = 0; k < names.length; k++) {
      var themedIcon = Quickshell.iconPath(names[k], true)
      if (themedIcon) return themedIcon
    }
    return ""
  }

  visible: player !== null && !root.vertical
  enabled: Island.mode === "" || Island.mode === "media"
  opacity: Island.mode === "" ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
  implicitWidth: visible ? Style.space(root.playing ? 62 : 40) : 0
  implicitHeight: root.barSize
  Behavior on implicitWidth {
    NumberAnimation { duration: Style.duration(280); easing.type: Easing.OutCubic }
  }

  readonly property bool topAttached: !!root.bar && root.bar.centerTopAttached === true
  readonly property real capsuleInset: Style.bar.capsuleInset
  readonly property real capsuleTop: root.topAttached ? 0 : root.capsuleInset
  readonly property real capsuleHeight: root.barSize - root.capsuleTop - root.capsuleInset
  readonly property real endRadius: capsuleHeight / 2
  readonly property real workspaceCenter: width + Style.space(2) + endRadius
  readonly property real notchRadius: endRadius + Style.space(4)
  readonly property real tipX: workspaceCenter - Math.sqrt(Math.max(0, notchRadius * notchRadius - endRadius * endRadius))

  Shape {
    anchors.fill: parent
    visible: !!root.bar && !root.bar.transparent && (root.bar.glass || NekoColor.bar.capsule.a > 0) && !root.topAttached
    preferredRendererType: Shape.CurveRenderer

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
    bar: root.bar
    hasVisualContent: true
    tooltipText: ""
    onPressed: function(b) { if (root.player && root.player.canTogglePlaying) root.player.togglePlaying() }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(5)

      Item {
        id: compactAppMark
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(25)
        height: width

        Rectangle {
          anchors.fill: parent
          radius: width / 2
          color: Util.alpha(root.spotifyPlayer ? "#1ed760" : NekoColor.accent, 0.14)
          opacity: root.playing ? 1 : 0
          scale: root.playing ? 1 : 0.72
          Behavior on opacity { NumberAnimation { duration: Style.duration(180) } }
          Behavior on scale { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutBack } }
        }

        Image {
          id: appIcon
          anchors.centerIn: parent
          width: Style.bar.iconFont + 2
          height: width
          source: root.iconUrl
          sourceSize.width: width * 2
          sourceSize.height: height * 2
          fillMode: Image.PreserveAspectFit
          smooth: true
          visible: !root.spotifyPlayer && status === Image.Ready
          opacity: root.playing ? 1 : 0.55
        }

        Text {
          anchors.centerIn: parent
          visible: root.spotifyPlayer || appIcon.status !== Image.Ready
          text: root.spotifyPlayer ? "󰓇" : "󰝚"
          color: root.playing ? (root.spotifyPlayer ? "#1ed760" : NekoColor.accent) : button.foreground
          opacity: root.playing ? 1 : 0.6
          font.family: button.fontFamily
          font.pixelSize: Style.bar.iconFont
          Behavior on color { ColorAnimation { duration: Style.duration(200) } }
        }
      }

      Item {
        id: compactSpectrum
        anchors.verticalCenter: parent.verticalCenter
        width: root.playing ? Style.space(22) : 0
        height: Style.space(18)
        opacity: root.playing ? 1 : 0
        clip: true

        Behavior on width { NumberAnimation { duration: Style.duration(220); easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: Style.duration(160) } }

        Row {
          anchors.centerIn: parent
          spacing: Style.space(2)

          Repeater {
            model: [0.35, 0.78, 1.0, 0.58]

            Item {
              id: spectrumSlot
              required property real modelData
              required property int index
              width: Style.space(3)
              height: compactSpectrum.height
              property real level: 0.24 + index * 0.07

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: Math.max(width, parent.height * spectrumSlot.level)
                radius: width / 2
                color: root.spotifyPlayer && spectrumSlot.index % 2 === 0 ? "#1ed760" : NekoColor.accent
              }

              SequentialAnimation on level {
                running: root.playing
                loops: Animation.Infinite
                NumberAnimation { to: spectrumSlot.modelData; duration: 230 + spectrumSlot.index * 65; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.2 + spectrumSlot.index * 0.09; duration: 310 + spectrumSlot.index * 45; easing.type: Easing.InOutSine }
              }
            }
          }
        }
      }
    }

    HoverHandler {
      onHoveredChanged: {
        if (hovered && root.player) Island.showMedia(root.player)
        else if (!hovered) Island.leaveMediaIcon()
      }
    }
  }

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
}
