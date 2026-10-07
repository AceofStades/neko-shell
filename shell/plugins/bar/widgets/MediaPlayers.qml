import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "../../services/media/MediaModel.js" as MediaModel

// A concave capsule beside the workspace island holds one icon per player.
// Its inset follows the workspace capsule with a visible gap. Hovering an
// icon opens that player's card; clicking toggles playback.
BarWidget {
  id: root
  moduleName: "neko.media-players"
  readonly property bool ownCapsule: true

  readonly property var players: {
    var all = Mpris.players ? Mpris.players.values : []
    return all.filter(function(p) { return p && !MediaModel.isProxyPlayer(p) && MediaModel.hasTrackMetadata(p) })
  }

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

  visible: players.length > 0 && !root.vertical
  enabled: Island.mode === "" || Island.mode === "media"
  opacity: enabled ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Style.duration(200) } }
  implicitWidth: visible ? row.implicitWidth + Style.space(4) : 0
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

  Row {
    id: row
    x: Style.space(2)
    anchors.verticalCenter: parent.verticalCenter

    Repeater {
      model: root.players

      WidgetButton {
        id: cell
        required property var modelData
        readonly property bool playing: modelData.isPlaying
        readonly property string iconUrl: root.iconFor(modelData)

        bar: root.bar
        hasVisualContent: true
        fixedWidth: Style.bar.iconSlot
        fixedHeight: root.barSize
        tooltipText: ""
        onPressed: function(b) { if (cell.modelData.canTogglePlaying) cell.modelData.togglePlaying() }

        Image {
          id: appIcon
          anchors.centerIn: parent
          width: Style.bar.iconFont + 3
          height: width
          source: cell.iconUrl
          sourceSize.width: width * 2
          sourceSize.height: height * 2
          fillMode: Image.PreserveAspectFit
          smooth: true
          visible: status === Image.Ready
          opacity: cell.playing ? 1 : 0.45
        }
        Text {
          anchors.centerIn: parent
          visible: appIcon.status !== Image.Ready
          text: "󰝚"
          color: cell.playing ? NekoColor.accent : cell.foreground
          opacity: cell.playing ? 1 : 0.55
          font.family: cell.fontFamily
          font.pixelSize: Style.bar.iconFont
        }

        Rectangle {
          visible: cell.playing
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.bar.capsuleInset + Style.space(2)
          width: Style.space(3)
          height: width
          radius: width / 2
          color: NekoColor.accent
        }

        HoverHandler {
          onHoveredChanged: {
            if (hovered) Island.showMedia(cell.modelData)
            else Island.leaveMediaIcon()
          }
        }
      }
    }
  }
}
