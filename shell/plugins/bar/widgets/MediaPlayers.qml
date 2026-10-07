import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "../../services/media/MediaModel.js" as MediaModel

// An icon for each media player with something loaded (Spotify, a browser
// playing YouTube...), in the accent while it plays. Hovering one grows the
// island into its card (see Island): art, track, a seek bar and the buttons.
// A click plays or pauses it.
BarWidget {
  id: root
  moduleName: "neko.media-players"

  readonly property var players: {
    var all = Mpris.players ? Mpris.players.values : []
    return all.filter(function(p) { return p && !MediaModel.isProxyPlayer(p) && MediaModel.hasTrackMetadata(p) })
  }

  // The app's icon from its desktop entry, else "". Browsers often don't name
  // their entry, so the player's name is tried as it is, in lower case and
  // with "google-" before it (Chrome is google-chrome)
  function iconFor(player) {
    var identity = String(player.identity || "").toLowerCase().replace(/\s+/g, "-")
    var names = [player.desktopEntry, player.identity, MediaModel.playerAppLabel(player), identity, identity ? "google-" + identity : ""]
    for (var i = 0; i < names.length; i++) {
      var name = String(names[i] || "")
      if (!name) continue
      var entry = typeof DesktopEntries.heuristicLookup === "function" ? DesktopEntries.heuristicLookup(name) : DesktopEntries.byId(name)
      if (entry && entry.icon) return Quickshell.iconPath(entry.icon, true)
    }
    return ""
  }

  visible: players.length > 0 && !root.vertical
  implicitWidth: visible ? row.implicitWidth : 0
  implicitHeight: root.barSize

  Row {
    id: row
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

        // A dot under the one that's playing
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
