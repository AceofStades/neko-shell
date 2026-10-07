import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "../../services/media/MediaModel.js" as MediaModel

// One music control sits beside the workspace island. Its concave edge
// follows the workspace capsule with a gap, and fades as the island changes
// to an OSD or notification. Hovering opens the selected player's card.
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
  opacity: enabled ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
  implicitWidth: visible ? Style.space(40) : 0
  implicitHeight: root.barSize

  readonly property real capsuleInset: Style.bar.capsuleInset
  readonly property real capsuleHeight: root.barSize - 2 * capsuleInset
  readonly property real endRadius: capsuleHeight / 2
  readonly property real workspaceCenter: width + Style.space(2) + endRadius
  readonly property real notchRadius: endRadius + Style.space(4)
  readonly property real tipX: workspaceCenter - Math.sqrt(Math.max(0, notchRadius * notchRadius - endRadius * endRadius))

  Shape {
    anchors.fill: parent
    visible: !!root.bar && !root.bar.transparent && (root.bar.glass || NekoColor.bar.capsule.a > 0)
    preferredRendererType: Shape.CurveRenderer

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
    bar: root.bar
    hasVisualContent: true
    tooltipText: ""
    onPressed: function(b) { if (root.player && root.player.canTogglePlaying) root.player.togglePlaying() }

    Image {
      id: appIcon
      anchors.centerIn: parent
      width: Style.bar.iconFont + 3
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
      text: "󰝚"
      color: root.playing ? NekoColor.accent : button.foreground
      opacity: root.playing ? 1 : 0.6
      font.family: button.fontFamily
      font.pixelSize: Style.bar.iconFont + 1
      Behavior on color { ColorAnimation { duration: Style.duration(200) } }
    }

    HoverHandler {
      onHoveredChanged: {
        if (hovered && root.player) Island.showMedia(root.player)
        else if (!hovered) Island.leaveMediaIcon()
      }
    }
  }
}
