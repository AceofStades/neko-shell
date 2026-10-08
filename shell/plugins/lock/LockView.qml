import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Ui

// The lock screen, made of the bar's island. The wallpaper blurs and dims
// behind a large clock, and the island hangs from the top edge as it does
// on the bar: the face breathing while Howdy looks, then a check that pops
// with a ripple or a shake into a cross, as the island shows face unlock
// for sudo. Typing grows the island into the password field, a dot for each
// character; a wrong password shakes it.
//
// Everything that authenticates lives in Service.qml; this only draws its
// state and hands back what's typed.
Item {
  id: root

  property string backgroundPath: ""
  property string videoPosterPath: ""
  property int backgroundVersion: 0
  property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || "user"
  property bool faceConfigured: false
  property bool faceAuthenticating: false
  property string faceAuthState: ""
  property bool fingerprintConfigured: false
  property bool fingerprintUnavailable: false
  property bool fingerprintAuthenticating: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property bool displaysBlank: false
  property bool powerSaverActive: false
  property string passwordText: ""

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  property bool syncingPasswordText: false
  property bool passwordModeRequested: false
  // 0 to 1 as the lock comes up: the wallpaper blurs, the clock settles
  property real entrance: 0
  // The island hangs down once the lock is up
  property bool islandUp: false

  readonly property bool compact: width < 760 || height < 620
  readonly property bool video: Util.isVideoPath(backgroundPath)
  readonly property bool feedActive: video && loadBackground && !displaysBlank && !powerSaverActive
  readonly property bool errorState: failureMessage.length > 0
  readonly property bool passwordMode: passwordModeRequested || passwordText.length > 0 || authenticatingPassword || errorState || !faceConfigured
  readonly property bool faceApproved: faceAuthState === "approved"
  readonly property bool faceFailed: faceAuthState === "failed"
  // What the island shows: the face (and how it went) or the password field
  readonly property string islandState: faceApproved ? "approved"
    : passwordMode ? "password"
    : faceFailed ? "failed" : "face"

  readonly property color glass: Island.panelGlass
  readonly property color text: "#f2f2f2"
  readonly property color dim: Util.alpha(text, 0.62)
  readonly property color accent: NekoColor.accent
  readonly property color error: NekoColor.lock.textError
  readonly property string fontFamily: Style.font.family

  function forcePasswordFocus() {
    if (root.inputEnabled) passwordInput.forceActiveFocus()
  }

  function returnToFaceMode() {
    root.passwordTextEdited("")
    root.clearFailureRequested()
    passwordModeRequested = false
    root.wakeRequested()
    Qt.callLater(forcePasswordFocus)
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  function submitCurrentPassword() {
    var submitted = root.passwordText
    root.passwordTextEdited("")
    if (submitted.length > 0) root.submitPassword(submitted)
  }

  function startEntrance() {
    entranceAnimation.stop()
    islandUp = false
    entrance = Style.reduceMotion ? 1 : 0
    if (!Style.reduceMotion) entranceAnimation.start()
    Qt.callLater(function() { root.islandUp = true })
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  onPasswordTextChanged: {
    syncPasswordText()
    if (passwordText.length > 0) passwordModeRequested = true
  }
  onInputEnabledChanged: if (inputEnabled) Qt.callLater(forcePasswordFocus)
  onLoadBackgroundChanged: if (loadBackground) startEntrance()
  onFailureMessageChanged: {
    if (failureMessage.length === 0) return
    passwordModeRequested = true
    if (!Style.reduceMotion) islandShake.restart()
    errorFlash.restart()
  }

  Component.onCompleted: {
    syncPasswordText()
    if (loadBackground) startEntrance()
  }

  NumberAnimation {
    id: entranceAnimation
    target: root
    property: "entrance"
    from: 0
    to: 1
    duration: Style.duration(700)
    easing.type: Easing.OutCubic
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  // ------------------------------------------------------------ background
  Rectangle {
    anchors.fill: parent
    color: NekoColor.background

    BackgroundMedia {
      id: wallpaper
      anchors.fill: parent
      visible: false
      path: root.loadBackground ? (root.video ? root.videoPosterPath : root.backgroundPath) : ""
      version: root.backgroundVersion
      cached: true
      constrainDecode: true
      decodeSize: Qt.size(width, height)
    }

    // Blurred and dimmed as the lock comes up; once up it's a still frame
    MultiEffect {
      anchors.fill: parent
      source: wallpaper
      visible: !feedLoader.visible
      blurEnabled: true
      blurMax: 64
      blur: 0.85 * root.entrance
      brightness: -0.22 * root.entrance
      saturation: -0.1 * root.entrance
      scale: 1.04 - 0.04 * root.entrance
    }

    // A video wallpaper keeps playing, dimmed rather than blurred
    Loader {
      id: feedLoader
      anchors.fill: parent
      active: root.feedActive
      source: "LockFeedSurface.qml"
      visible: status === Loader.Ready
    }

    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0.0; color: Util.alpha("#000000", 0.4 * root.entrance) }
        GradientStop { position: 0.45; color: Util.alpha("#000000", 0.2 * root.entrance) }
        GradientStop { position: 1.0; color: Util.alpha("#000000", 0.5 * root.entrance) }
      }
    }
  }

  // Any movement wakes the screens; a click puts the keys back in the field
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onClicked: {
      root.wakeRequested()
      root.forcePasswordFocus()
    }
    onPositionChanged: root.wakeRequested()
  }

  // ----------------------------------------------------------------- clock
  // The time in big block letters (figlet's ANSI Shadow): the blocks in the
  // text color, the shadow they cast in the accent, two layers of the same
  // monospace text. A cat sits on it and blinks now and then.
  readonly property var glyphs: ({"0": [" ██████╗ ", "██╔═████╗", "██║██╔██║", "████╔╝██║", "╚██████╔╝", " ╚═════╝ "],
    "1": [" ██╗", "███║", "╚██║", " ██║", " ██║", " ╚═╝"],
    "2": ["██████╗ ", "╚════██╗", " █████╔╝", "██╔═══╝ ", "███████╗", "╚══════╝"],
    "3": ["██████╗ ", "╚════██╗", " █████╔╝", " ╚═══██╗", "██████╔╝", "╚═════╝ "],
    "4": ["██╗  ██╗", "██║  ██║", "███████║", "╚════██║", "     ██║", "     ╚═╝"],
    "5": ["███████╗", "██╔════╝", "███████╗", "╚════██║", "███████║", "╚══════╝"],
    "6": [" ██████╗ ", "██╔════╝ ", "███████╗ ", "██╔═══██╗", "╚██████╔╝", " ╚═════╝ "],
    "7": ["███████╗", "╚════██║", "    ██╔╝", "   ██╔╝ ", "   ██║  ", "   ╚═╝  "],
    "8": [" █████╗ ", "██╔══██╗", "╚█████╔╝", "██╔══██╗", "╚█████╔╝", " ╚════╝ "],
    "9": [" █████╗ ", "██╔══██╗", "╚██████║", " ╚═══██║", " █████╔╝", " ╚════╝ "],
    ":": ["   ", "██╗", "╚═╝", "██╗", "╚═╝", "   "]})
  readonly property var clockRows: {
    var time = Qt.formatDateTime(clock.date, "HH:mm")
    var rows = []
    for (var row = 0; row < 6; row++) {
      var parts = []
      for (var i = 0; i < time.length; i++) parts.push((glyphs[time.charAt(i)] || glyphs["0"])[row])
      rows.push(parts.join(" "))
    }
    return rows
  }
  readonly property string clockSolid: clockRows.map(function(r) { return r.replace(/[^█\n]/g, " ") }).join("\n")
  readonly property string clockShadow: clockRows.map(function(r) { return r.replace(/█/g, " ") }).join("\n")
  readonly property int clockColumns: clockRows.length > 0 ? clockRows[0].length : 1

  FontMetrics {
    id: cellMetrics
    font.family: root.fontFamily
    font.pixelSize: 100
  }
  // As wide as about three fifths of the screen, at most
  readonly property int clockPixelSize: Math.max(8, Math.floor(Math.min(root.width * (root.compact ? 0.8 : 0.6), 1150)
    / (clockColumns * Math.max(0.3, cellMetrics.advanceWidth("█") / 100))))

  // At the clock's size: the full block's height, so the rows meet without
  // a seam between them
  FontMetrics {
    id: blockMetrics
    font.family: root.fontFamily
    font.pixelSize: root.clockPixelSize
  }
  readonly property real clockLine: Math.max(1, Math.floor(blockMetrics.ascent + blockMetrics.descent))

  Item {
    id: clockBlock
    // Room above the digits for the cat; the shadow layer clips to this item
    readonly property real catRoom: cat.implicitHeight * 0.72
    anchors.horizontalCenter: parent.horizontalCenter
    width: clockText.implicitWidth
    height: catRoom + clockText.implicitHeight + dateLine.height + Style.space(18)
    y: Math.round(root.height * 0.42 - height / 2 + (1 - root.entrance) * Style.space(24))
    opacity: root.entrance
    // A soft shadow keeps it legible over a light wallpaper
    layer.enabled: true
    layer.effect: MultiEffect {
      shadowEnabled: true
      shadowColor: "#000000"
      shadowOpacity: 0.5
      shadowBlur: 1.0
      shadowVerticalOffset: 2
    }

    Text {
      id: clockShadowText
      y: clockBlock.catRoom
      text: root.clockShadow
      textFormat: Text.PlainText
      lineHeightMode: Text.FixedHeight
      lineHeight: root.clockLine
      color: Util.alpha(root.accent, 0.85)
      font.family: root.fontFamily
      font.pixelSize: root.clockPixelSize
    }
    Text {
      id: clockText
      y: clockBlock.catRoom
      text: root.clockSolid
      textFormat: Text.PlainText
      lineHeightMode: Text.FixedHeight
      lineHeight: root.clockLine
      color: root.text
      font.family: root.fontFamily
      font.pixelSize: root.clockPixelSize
    }

    // The cat, on the last digit
    Text {
      id: cat
      property bool blink: false
      anchors.right: clockText.right
      anchors.rightMargin: root.clockPixelSize * 1.2
      anchors.bottom: clockText.top
      anchors.bottomMargin: -root.clockPixelSize * 0.35
      text: " /\\_/\\\n( " + (blink ? "-.-" : "o.o") + " )\n > ^ <"
      textFormat: Text.PlainText
      color: root.text
      font.family: root.fontFamily
      font.pixelSize: Math.round(root.clockPixelSize * 1.15)
      lineHeight: 0.95

      Timer {
        interval: 4200
        repeat: true
        running: root.entrance >= 1 && !root.displaysBlank && !Style.reduceMotion
        onTriggered: {
          cat.blink = true
          catOpen.restart()
          interval = 3000 + Math.floor(Math.random() * 4000)
        }
      }
      Timer {
        id: catOpen
        interval: 170
        onTriggered: cat.blink = false
      }
    }

    Text {
      id: dateLine
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: clockText.bottom
      anchors.topMargin: Style.space(18)
      text: "──  " + Qt.formatDateTime(clock.date, "dddd, d MMMM").toLowerCase() + "  ──"
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: root.compact ? Style.font.body : Style.font.title
      font.letterSpacing: 1
    }
  }

  // ---------------------------------------------------------------- island
  Item {
    id: island

    readonly property real faceWidth: Style.space(root.compact ? 170 : 210)
    readonly property real faceHeight: Style.space(root.compact ? 92 : 108)
    readonly property real passwordWidth: Math.min(root.width - Style.space(48), Style.space(root.compact ? 360 : 440))
    readonly property real passwordHeight: Style.space(root.compact ? 96 : 104)
    readonly property bool wide: root.islandState === "password"

    width: !root.islandUp ? Style.space(120) : wide ? passwordWidth : faceWidth
    height: !root.islandUp ? 0 : wide ? passwordHeight : faceHeight
    x: Math.round((root.width - width) / 2) + shake.x
    y: 0

    Behavior on width {
      enabled: !Style.reduceMotion
      SpringAnimation { spring: 3.2; damping: 0.36; epsilon: 0.5 }
    }
    Behavior on height {
      enabled: !Style.reduceMotion
      SpringAnimation { spring: 3.2; damping: 0.36; epsilon: 0.5 }
    }

    Item { id: shake }

    SequentialAnimation {
      id: islandShake
      NumberAnimation { target: shake; property: "x"; to: -Style.space(12); duration: 50; easing.type: Easing.OutSine }
      NumberAnimation { target: shake; property: "x"; to: Style.space(10); duration: 90; easing.type: Easing.InOutSine }
      NumberAnimation { target: shake; property: "x"; to: -Style.space(7); duration: 80; easing.type: Easing.InOutSine }
      NumberAnimation { target: shake; property: "x"; to: Style.space(4); duration: 70; easing.type: Easing.InOutSine }
      NumberAnimation { target: shake; property: "x"; to: 0; duration: 60; easing.type: Easing.OutSine }
    }

    // The card and its shoulders are one shape, as on the bar: flat along
    // the top edge, curving into it at either side, rounded below
    Shape {
      id: islandShape
      readonly property real round: Math.min(Style.space(28), island.height / 2)
      readonly property real shoulder: Math.max(0, Math.min(Style.space(16), island.height - round))
      x: -shoulder
      width: island.width + shoulder * 2
      height: island.height
      visible: island.height > 1
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillColor: root.glass
        strokeWidth: 0
        strokeColor: "transparent"
        startX: 0
        startY: 0
        PathLine { x: islandShape.width; y: 0 }
        PathArc { x: islandShape.width - islandShape.shoulder; y: islandShape.shoulder; radiusX: islandShape.shoulder; radiusY: islandShape.shoulder; direction: PathArc.Counterclockwise }
        PathLine { x: islandShape.width - islandShape.shoulder; y: island.height - islandShape.round }
        PathArc { x: islandShape.width - islandShape.shoulder - islandShape.round; y: island.height; radiusX: islandShape.round; radiusY: islandShape.round }
        PathLine { x: islandShape.shoulder + islandShape.round; y: island.height }
        PathArc { x: islandShape.shoulder; y: island.height - islandShape.round; radiusX: islandShape.round; radiusY: islandShape.round }
        PathLine { x: islandShape.shoulder; y: islandShape.shoulder }
        PathArc { x: 0; y: 0; radiusX: islandShape.shoulder; radiusY: islandShape.shoulder; direction: PathArc.Counterclockwise }
      }
      // A wrong password flushes the island red for a moment
      ShapePath {
        id: errorWash
        property real strength: 0
        fillColor: Util.alpha(root.error, 0.32 * strength)
        strokeWidth: 0
        strokeColor: "transparent"
        startX: islandShape.shoulder
        startY: 0
        PathLine { x: islandShape.width - islandShape.shoulder; y: 0 }
        PathLine { x: islandShape.width - islandShape.shoulder; y: island.height - islandShape.round }
        PathArc { x: islandShape.width - islandShape.shoulder - islandShape.round; y: island.height; radiusX: islandShape.round; radiusY: islandShape.round }
        PathLine { x: islandShape.shoulder + islandShape.round; y: island.height }
        PathArc { x: islandShape.shoulder; y: island.height - islandShape.round; radiusX: islandShape.round; radiusY: islandShape.round }
        PathLine { x: islandShape.shoulder; y: 0 }
      }
    }

    SequentialAnimation {
      id: errorFlash
      NumberAnimation { target: errorWash; property: "strength"; to: 1; duration: 80 }
      NumberAnimation { target: errorWash; property: "strength"; to: 0; duration: 900; easing.type: Easing.InCubic }
    }

    // ------------------------------------------------------------ the face
    Item {
      id: faceView
      readonly property bool wanted: root.islandState !== "password"
      readonly property real glyphSize: Math.round(Style.font.display * (root.compact ? 1.4 : 1.7))
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(18)
      width: glyphSize * 1.6
      height: glyphSize * 1.25
      opacity: wanted && island.height > island.faceHeight * 0.7 ? 1 : 0
      scale: wanted ? 1 : 0.8
      visible: opacity > 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(faceView.wanted ? 220 : 80); easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: Style.duration(300); easing.type: Easing.OutBack } }
      transform: Translate { id: faceShake }

      readonly property string state: root.islandState
      onStateChanged: {
        approvedAnimation.stop()
        failedAnimation.stop()
        if (state === "approved") approvedAnimation.restart()
        else if (state === "failed") failedAnimation.restart()
        else {
          faceGlyph.opacity = 1
          faceGlyph.scale = 1
          faceGlyph.color = root.text
          resultGlyph.opacity = 0
          ring.opacity = 0
          faceShake.x = 0
        }
      }

      Rectangle {
        id: ring
        anchors.centerIn: parent
        width: faceView.glyphSize
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
        color: root.text
        font.family: root.fontFamily
        font.pixelSize: faceView.glyphSize

        SequentialAnimation on opacity {
          // Not while the displays are off: nothing would see it
          running: faceView.visible && root.islandState === "face" && root.faceAuthenticating && !root.displaysBlank && !Style.reduceMotion
          loops: Animation.Infinite
          onRunningChanged: if (!running && root.islandState === "face") faceGlyph.opacity = 1
          NumberAnimation { to: 0.4; duration: Style.duration(650); easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: Style.duration(650); easing.type: Easing.InOutSine }
        }
      }

      Text {
        id: resultGlyph
        anchors.centerIn: parent
        text: root.islandState === "failed" ? "\u{F0156}" : "\u{F012C}"
        color: root.islandState === "failed" ? root.error : root.accent
        font.family: root.fontFamily
        font.pixelSize: faceView.glyphSize
        opacity: 0
      }

      SequentialAnimation {
        id: approvedAnimation
        ParallelAnimation {
          NumberAnimation { target: faceGlyph; property: "opacity"; to: 0; duration: Style.duration(140); easing.type: Easing.InCubic }
          NumberAnimation { target: faceGlyph; property: "scale"; to: 0.6; duration: Style.duration(140); easing.type: Easing.InCubic }
        }
        ParallelAnimation {
          NumberAnimation { target: resultGlyph; property: "opacity"; from: 0; to: 1; duration: Style.duration(120) }
          NumberAnimation { target: resultGlyph; property: "scale"; from: 0.4; to: 1; duration: Style.duration(380); easing.type: Easing.OutBack; easing.overshoot: 2.2 }
          NumberAnimation { target: ring; property: "scale"; from: 0.7; to: 2.1; duration: Style.duration(560); easing.type: Easing.OutCubic }
          NumberAnimation { target: ring; property: "opacity"; from: 0.9; to: 0; duration: Style.duration(560); easing.type: Easing.OutCubic }
        }
      }

      SequentialAnimation {
        id: failedAnimation
        ColorAnimation { target: faceGlyph; property: "color"; to: root.error; duration: Style.duration(90) }
        SequentialAnimation {
          NumberAnimation { target: faceShake; property: "x"; to: -Style.space(9); duration: Style.duration(50); easing.type: Easing.OutSine }
          NumberAnimation { target: faceShake; property: "x"; to: Style.space(8); duration: Style.duration(90); easing.type: Easing.InOutSine }
          NumberAnimation { target: faceShake; property: "x"; to: -Style.space(6); duration: Style.duration(80); easing.type: Easing.InOutSine }
          NumberAnimation { target: faceShake; property: "x"; to: Style.space(4); duration: Style.duration(70); easing.type: Easing.InOutSine }
          NumberAnimation { target: faceShake; property: "x"; to: 0; duration: Style.duration(60); easing.type: Easing.OutSine }
        }
        ParallelAnimation {
          NumberAnimation { target: faceGlyph; property: "opacity"; to: 0; duration: Style.duration(140) }
          NumberAnimation { target: resultGlyph; property: "opacity"; from: 0; to: 1; duration: Style.duration(160) }
          NumberAnimation { target: resultGlyph; property: "scale"; from: 0.6; to: 1; duration: Style.duration(260); easing.type: Easing.OutBack }
        }
      }
    }

    // -------------------------------------------------------- the password
    Item {
      id: passwordView
      readonly property bool wanted: root.islandState === "password"
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.leftMargin: Style.space(22)
      anchors.rightMargin: Style.space(14)
      anchors.bottomMargin: Style.space(14)
      height: Style.space(root.compact ? 64 : 70)
      opacity: wanted && island.width > island.passwordWidth * 0.8 ? 1 : 0
      visible: opacity > 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(passwordView.wanted ? 200 : 70); easing.type: Easing.OutCubic } }

      Row {
        id: fieldRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Style.space(40)
        spacing: Style.space(12)

        Text {
          id: fieldGlyph
          anchors.verticalCenter: parent.verticalCenter
          text: "\u{F033E}"
          color: root.errorState ? root.error : root.authenticatingPassword ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon * 1.25
          Behavior on color { ColorAnimation { duration: Style.duration(150) } }
        }

        // A dot for each character, popping in as it's typed
        Item {
          id: dotsField
          anchors.verticalCenter: parent.verticalCenter
          width: fieldRow.width - fieldGlyph.width - submit.width - fieldRow.spacing * 2
          height: parent.height
          clip: true

          readonly property real dot: Style.space(10)
          readonly property real gap: Style.space(7)
          readonly property int shown: Math.min(root.passwordText.length, Math.max(1, Math.floor((width - Style.space(12)) / (dot + gap))))

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.passwordText.length === 0
            text: root.faceConfigured ? "Password, or Esc for your face" : "Password"
            color: Util.alpha(root.text, 0.45)
            elide: Text.ElideRight
            width: parent.width
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Row {
            id: dots
            anchors.verticalCenter: parent.verticalCenter
            spacing: dotsField.gap

            // Checking: the dots breathe until PAM answers
            SequentialAnimation on opacity {
              running: root.authenticatingPassword && !root.displaysBlank && !Style.reduceMotion
              loops: Animation.Infinite
              onRunningChanged: if (!running) dots.opacity = 1
              NumberAnimation { to: 0.35; duration: Style.duration(420); easing.type: Easing.InOutSine }
              NumberAnimation { to: 1; duration: Style.duration(420); easing.type: Easing.InOutSine }
            }

            Repeater {
              model: dotsField.shown
              Rectangle {
                width: dotsField.dot
                height: width
                radius: width / 2
                color: root.errorState ? root.error : root.text
                scale: 0
                Component.onCompleted: popIn.start()
                NumberAnimation on scale {
                  id: popIn
                  running: false
                  from: 0.2
                  to: 1
                  duration: Style.duration(220)
                  easing.type: Easing.OutBack
                  easing.overshoot: 2.4
                }
              }
            }
          }

          Rectangle {
            id: caret
            anchors.verticalCenter: parent.verticalCenter
            x: root.passwordText.length > 0 ? dots.width + Style.space(6) : 0
            width: Style.space(2)
            height: Style.space(20)
            radius: width / 2
            color: root.accent
            visible: root.passwordText.length > 0 && passwordInput.activeFocus && !root.authenticatingPassword
            SequentialAnimation on opacity {
              running: caret.visible && !root.displaysBlank && !Style.reduceMotion
              loops: Animation.Infinite
              NumberAnimation { to: 0; duration: 520; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1; duration: 520; easing.type: Easing.InOutSine }
            }
          }
        }

        Rectangle {
          id: submit
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(40)
          height: width
          radius: width / 2
          readonly property bool ready: root.passwordText.length > 0 && !root.authenticatingPassword
          color: ready ? root.accent : Util.alpha(root.text, 0.08)
          Behavior on color { ColorAnimation { duration: Style.duration(150) } }
          Text {
            anchors.centerIn: parent
            text: "\u{F0054}"
            color: submit.ready ? "#101010" : Util.alpha(root.text, 0.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.icon
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: submit.ready ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              root.wakeRequested()
              if (submit.ready) root.submitCurrentPassword()
              root.forcePasswordFocus()
            }
          }
        }
      }

      Text {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        horizontalAlignment: Text.AlignHCenter
        text: root.authenticatingPassword ? "Checking..."
          : root.errorState ? root.failureMessage
          : root.userName
        color: root.errorState ? root.error : root.dim
        elide: Text.ElideRight
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // The keys go here, wherever the pointer is; the dots above show them
    TextInput {
      id: passwordInput
      width: 1
      height: 1
      opacity: 0
      activeFocusOnPress: true
      enabled: root.inputEnabled && !root.authenticatingPassword
      readOnly: root.authenticatingPassword
      echoMode: TextInput.Password
      passwordMaskDelay: 0

      onTextChanged: {
        if (!root.syncingPasswordText) root.passwordTextEdited(text)
        if (text.length > 0) root.wakeRequested()
        if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
      }
      onAccepted: root.submitCurrentPassword()

      Keys.onPressed: function(event) {
        root.wakeRequested()
        // Holding a key down types one character, not a run of them
        if (event.isAutoRepeat && event.key !== Qt.Key_Backspace && event.key !== Qt.Key_Delete) {
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
          root.returnToFaceMode()
          event.accepted = true
        }
      }
    }
  }

  // Under the island, what else would let you in
  Row {
    anchors.horizontalCenter: parent.horizontalCenter
    y: island.height + Style.space(14)
    spacing: Style.space(16)
    opacity: root.islandUp && root.islandState !== "approved" ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Style.duration(240) } }

    Row {
      visible: root.faceConfigured && !root.passwordMode
      spacing: Style.space(6)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.faceFailed ? "Not recognized, or type your password" : "Looking for you, or start typing"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }

    Row {
      visible: root.fingerprintConfigured
      spacing: Style.space(6)
      Text {
        id: fingerprintGlyph
        anchors.verticalCenter: parent.verticalCenter
        text: "\u{F0237}"
        color: root.fingerprintUnavailable ? Util.alpha(root.text, 0.3) : root.fingerprintAuthenticating ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.fingerprintUnavailable ? "Reader unavailable" : "Touch the reader"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }
}
