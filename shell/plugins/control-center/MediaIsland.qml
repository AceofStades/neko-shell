import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Widgets
import qs.Commons
import qs.Ui
import "../services/media/MediaModel.js" as MediaModel

// The control center's music island, the left-hand twin of the quick-start
// island. It is the UniBar island's now-playing view carried over: the
// artwork on its own framed stage, the title and transport beside it and the
// seek line along the foot. With nothing playing the neko takes the stage.
Item {
  id: root

  property var bar: null
  readonly property bool glass: !!bar && bar.glass === true
  // The island's own palette, so the card reads as the same surface
  readonly property color text: glass ? "#f2f2f2" : bar ? bar.barForeground : NekoColor.foreground
  readonly property color dim: Util.alpha(text, 0.65)
  readonly property color track: Util.alpha(text, 0.2)
  readonly property color accent: NekoColor.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // The same pick the bar's music control makes: the playing one, Spotify
  // first, and a video in a browser stays out of it
  function isBrowser(p) {
    return /chrom|firefox|brave|vivaldi|opera|edge|zen|librewolf|floorp|qutebrowser|epiphany|falkon/i
      .test(String(p.identity || "") + " " + String(p.desktopEntry || "") + " " + String(p.dbusName || ""))
  }
  readonly property var players: {
    var all = Mpris.players ? Mpris.players.values : []
    return all.filter(function(p) {
      return p && !MediaModel.isProxyPlayer(p) && MediaModel.hasTrackMetadata(p) && (!isBrowser(p) || String(p.trackAlbum || "").trim() !== "")
    })
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

  readonly property real length: player ? Number(player.length) || 0 : 0
  readonly property real position: player ? Number(player.position) || 0 : 0
  // While the seek bar is dragged, where it's been dragged to (0..1)
  property real dragFraction: -1
  readonly property real fraction: dragFraction >= 0 ? dragFraction : length > 0 ? Math.min(1, position / length) : 0
  readonly property real art: Style.space(104)
  readonly property bool spotify: !!player && (String(player.identity || "") + String(player.desktopEntry || "")).toLowerCase().indexOf("spotify") >= 0
  readonly property string sourceName: !player ? "PLAYER" : spotify ? "SPOTIFY" : String(player.identity || "PLAYER").toUpperCase()

  // What the neko says when it's quiet; a new one each time it falls quiet
  readonly property var quips: [
    "It's quiet. Suspiciously quiet.",
    "No music? The cat is judging you.",
    "Purr-fect silence. Or press play somewhere.",
    "Even a cat needs a soundtrack.",
    "Nothing playing. Nap time, then.",
    "Too quiet. The neko wants a tune.",
    "Zero tunes. Maximum cat energy."
  ]
  property int quipIndex: Math.floor(Math.random() * quips.length)
  onPlayerChanged: if (!player) quipIndex = Math.floor(Math.random() * quips.length)

  function clock(seconds) {
    var s = Math.max(0, Math.floor(seconds))
    var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), r = s % 60
    return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (r < 10 ? "0" : "") + r
  }

  implicitWidth: Style.space(392)
  // The artwork and, under it, the seek line when there's something to seek;
  // the neko alone when nothing plays
  implicitHeight: player ? root.art + Style.space(14) + Style.space(22) : root.art

  // The player doesn't announce its position as it plays; ask for it
  Timer {
    interval: 500
    repeat: true
    running: root.visible && !!root.player && root.player.isPlaying
    onTriggered: root.player.positionChanged()
  }

  // The artwork's stage
  Rectangle {
    x: -Style.space(2)
    y: -Style.space(2)
    width: root.art + Style.space(4)
    height: width
    radius: Style.space(18)
    color: Util.alpha(root.accent, 0.13)
    border.width: 1
    border.color: Util.alpha(root.text, 0.12)
  }

  ClippingRectangle {
    id: artBox
    width: root.art
    height: root.art
    radius: Style.space(16)
    color: Util.alpha(root.text, 0.07)

    Image {
      id: art
      anchors.fill: parent
      source: root.player && root.player.trackArtUrl ? String(root.player.trackArtUrl) : ""
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
      visible: art.status === Image.Ready
      gradient: Gradient {
        GradientStop { position: 0; color: "transparent" }
        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.72) }
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(8)
      visible: !!root.player
      width: artState.implicitWidth + Style.space(14)
      height: Style.space(22)
      radius: height / 2
      color: Qt.rgba(0, 0, 0, 0.56)

      Text {
        id: artState
        anchors.centerIn: parent
        text: root.player && root.player.isPlaying ? "PLAYING" : "PAUSED"
        color: "#f5f5f5"
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption - 1
        font.weight: Font.Bold
        font.letterSpacing: Style.spaceReal(0.7)
      }
    }

    // No artwork: a note when something plays, the neko when nothing does
    Text {
      anchors.centerIn: parent
      visible: art.status !== Image.Ready
      text: root.player ? "󰝚" : "󰄛"
      color: root.player ? root.dim : root.accent
      font.family: root.fontFamily
      font.pixelSize: root.player ? Style.font.displayLarge : Math.round(Style.font.displayLarge * 1.9)
    }
  }

  // Title block, beside the artwork
  Item {
    x: root.art + Style.space(18)
    width: parent.width - x
    height: root.art

    Text {
      y: Style.space(1)
      text: root.player ? (root.player.isPlaying ? "NOW PLAYING" : "PLAYBACK PAUSED") : "ALL QUIET"
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.weight: Font.Bold
      font.letterSpacing: Style.spaceReal(0.8)
    }

    // Source badge and a tiny live equalizer make playback state legible
    // without competing with the title.
    Rectangle {
      anchors.right: parent.right
      y: -Style.space(3)
      visible: !!root.player
      width: sourceRow.implicitWidth + Style.space(14)
      height: Style.space(25)
      radius: height / 2
      color: Util.alpha(root.text, 0.075)
      border.width: 1
      border.color: Util.alpha(root.text, 0.09)

      Row {
        id: sourceRow
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
              color: root.spotify ? "#1ed760" : root.accent
              property real level: 0.3
              height: Math.max(width, Style.space(11) * level)
              SequentialAnimation on level {
                running: root.visible && !!root.player && root.player.isPlaying && !Style.reduceMotion
                loops: Animation.Infinite
                NumberAnimation { to: eqBar.modelData; duration: 250 + eqBar.index * 80; easing.type: Easing.InOutSine }
                NumberAnimation { to: 0.25 + eqBar.index * 0.1; duration: 330 + eqBar.index * 60; easing.type: Easing.InOutSine }
              }
            }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: root.sourceName
          color: root.spotify ? "#1ed760" : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption - 1
          font.weight: Font.Bold
          font.letterSpacing: Style.spaceReal(0.5)
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }

    Text {
      y: Style.space(27)
      width: parent.width
      textFormat: Text.PlainText
      text: root.player ? (root.player.trackTitle || root.player.identity || "Nothing playing") : "Nothing playing"
      color: root.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.title + 2
      font.weight: Font.Bold
      elide: Text.ElideRight
    }

    Text {
      y: Style.space(54)
      width: parent.width
      textFormat: Text.PlainText
      text: root.player
        ? [root.player.trackArtist, root.player.trackAlbum].filter(function(t) { return !!t }).join("  •  ")
        : root.quips[root.quipIndex]
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: root.player ? Text.NoWrap : Text.WordWrap
      maximumLineCount: root.player ? 1 : 2
      elide: Text.ElideRight
    }

    Text {
      y: Style.space(96)
      visible: !root.player
      width: parent.width
      text: "Start something and it shows up here."
      color: Util.alpha(root.text, 0.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Row {
      y: Style.space(70)
      x: -Style.space(6)
      visible: !!root.player
      spacing: Style.space(2)

      MediaButton {
        visible: !!root.player && root.player.shuffleSupported
        glyph: "󰒝"
        lit: !!root.player && root.player.shuffle
        onClicked: root.player.shuffle = !root.player.shuffle
      }
      MediaButton { glyph: "󰒮"; enabled: !!root.player && root.player.canGoPrevious; onClicked: root.player.previous() }
      MediaButton {
        glyph: root.player && root.player.isPlaying ? "󰏤" : "󰐊"
        big: true
        enabled: !!root.player && root.player.canTogglePlaying
        onClicked: root.player.togglePlaying()
      }
      MediaButton { glyph: "󰒭"; enabled: !!root.player && root.player.canGoNext; onClicked: root.player.next() }
      MediaButton {
        visible: !!root.player && root.player.loopSupported
        glyph: root.player && root.player.loopState === MprisLoopState.Track ? "󰑘" : "󰑖"
        lit: !!root.player && root.player.loopState !== MprisLoopState.None
        onClicked: root.player.loopState = root.player.loopState === MprisLoopState.None ? MprisLoopState.Playlist
          : root.player.loopState === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None
      }
    }
  }

  // Time and seek sit on their own baseline across the whole card
  Item {
    y: root.art + Style.space(14)
    width: parent.width
    height: Style.space(22)
    visible: !!root.player

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.clock(root.fraction * root.length)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
    Item {
      id: seek
      x: Style.space(43)
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(86)
      height: parent.height
      readonly property bool seekable: !!root.player && root.player.canSeek && root.length > 0

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: Style.space(5)
        radius: height / 2
        color: root.track

        Rectangle {
          height: parent.height
          radius: height / 2
          width: root.fraction > 0 ? Math.max(height, parent.width * root.fraction) : 0
          color: root.accent
          Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
        }
      }
      Rectangle {
        x: parent.width * root.fraction - width / 2
        anchors.verticalCenter: parent.verticalCenter
        width: seekArea.containsMouse || seekArea.pressed ? Style.space(13) : Style.space(9)
        height: width
        radius: width / 2
        color: root.text
        visible: seek.seekable && (seekArea.containsMouse || seekArea.pressed)
        Behavior on width { NumberAnimation { duration: Style.duration(120) } }
      }
      MouseArea {
        id: seekArea
        anchors.fill: parent
        enabled: seek.seekable
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        function at(x) { return Math.max(0, Math.min(1, x / width)) }
        onPressed: function(mouse) { root.dragFraction = at(mouse.x) }
        onPositionChanged: function(mouse) { if (pressed) root.dragFraction = at(mouse.x) }
        onReleased: {
          if (root.player) root.player.position = root.dragFraction * root.length
          root.dragFraction = -1
        }
      }
    }
    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.clock(root.length)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // The island's transport button: round, a wider accent one for play
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
        : Util.alpha(root.text, buttonArea.containsMouse ? 0.11 : 0.045)
      border.width: mediaButton.big || mediaButton.lit ? 1 : 0
      border.color: mediaButton.big ? Util.alpha(root.text, 0.22) : Util.alpha(root.accent, 0.34)
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }
    Text {
      anchors.centerIn: parent
      text: mediaButton.glyph
      color: mediaButton.big ? "#101010" : mediaButton.lit ? root.accent : root.text
      font.family: root.fontFamily
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
}
