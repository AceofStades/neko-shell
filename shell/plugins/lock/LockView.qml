import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Neko's native session lock: the wallpaper stays recognizable, while the
// clock and authentication controls form one quiet, screen-edge composition.
Item {
  id: root

  property string backgroundPath: ""
  property string videoPosterPath: ""
  property int backgroundVersion: 0
  property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME") || "user"
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
  property bool syncingPasswordText: false
  property real entranceProgress: 0
  property real errorShake: 0

  readonly property bool compact: width < 760 || height < 620
  readonly property bool video: Util.isVideoPath(root.backgroundPath)
  readonly property bool feedActive: root.video && root.loadBackground && !root.displaysBlank && !root.powerSaverActive
  readonly property bool errorState: failureMessage.length > 0
  readonly property bool fieldActive: passwordInput.activeFocus || passwordText.length > 0 || authenticatingPassword
  readonly property string timeText: Qt.formatDateTime(clock.date, "HH:mm")
  readonly property string dateText: Qt.formatDateTime(clock.date, "dddd, d MMMM")
  readonly property string userInitial: userName.length > 0 ? userName.charAt(0).toUpperCase() : "N"
  readonly property int fieldFontSize: Math.round(Style.font.heading * 0.94)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.12)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.15)
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 8) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && !errorState
  readonly property var islandBorderSpec: Border.surfaceSpec("lock", "border", Util.alpha(NekoColor.lock.border, 0.78), 1, "border-alpha")
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", NekoColor.lock.borderError, 2, "border-alpha")
    : fieldActive
      ? Border.surfaceSpec("lock", "border-active", NekoColor.lock.borderActive, 2, "border-alpha")
      : Border.surfaceSpec("lock", "border", Util.alpha(NekoColor.lock.border, 0.50), 1, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  function forcePasswordFocus() {
    if (root.inputEnabled) passwordInput.forceActiveFocus()
  }

  function dropsAutoRepeat(key) {
    return key !== Qt.Key_Backspace && key !== Qt.Key_Delete
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  function startEntrance() {
    entranceAnimation.stop()
    entranceProgress = Style.reduceMotion ? 1 : 0
    if (!Style.reduceMotion) entranceAnimation.start()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  function submitCurrentPassword() {
    var submitted = root.passwordText
    root.passwordTextEdited("")
    if (submitted.length > 0) root.submitPassword(submitted)
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: if (inputEnabled) Qt.callLater(forcePasswordFocus)
  onLoadBackgroundChanged: if (loadBackground) startEntrance()
  onFailureMessageChanged: {
    if (failureMessage.length > 0 && !Style.reduceMotion) errorAnimation.restart()
  }

  Component.onCompleted: {
    syncPasswordText()
    if (loadBackground) startEntrance()
  }

  NumberAnimation {
    id: entranceAnimation
    target: root
    property: "entranceProgress"
    from: 0
    to: 1
    duration: Style.duration(820)
    easing.type: Easing.OutCubic
  }

  SequentialAnimation {
    id: errorAnimation
    NumberAnimation { target: root; property: "errorShake"; to: -12; duration: 55; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: 10; duration: 72; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: -7; duration: 68; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: 4; duration: 62; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: 0; duration: 82; easing.type: Easing.OutQuad }
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
  }

  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: NekoColor.background

    BackgroundMedia {
      id: wallpaper
      objectName: "lockWallpaper"
      anchors.fill: parent
      path: root.loadBackground ? (root.video ? root.videoPosterPath : root.backgroundPath) : ""
      version: root.backgroundVersion
      cached: true
      constrainDecode: true
      decodeSize: Qt.size(width, height)
      scale: 1.025 - 0.025 * root.entranceProgress
    }

    Loader {
      id: feedLoader
      objectName: "lockFeedLoader"
      anchors.fill: parent
      active: root.feedActive
      source: "LockFeedSurface.qml"
      visible: status === Loader.Ready
      scale: wallpaper.scale
    }

    // Only the screen edges are shaded. The artwork remains crisp and visible
    // through the center instead of becoming an anonymous blur.
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0.0; color: Util.alpha(NekoColor.background, 0.38) }
        GradientStop { position: 0.19; color: Util.alpha(NekoColor.background, 0.06) }
        GradientStop { position: 0.68; color: Util.alpha(NekoColor.background, 0.04) }
        GradientStop { position: 1.0; color: Util.alpha(NekoColor.background, 0.56) }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: {
        root.wakeRequested()
        root.forcePasswordFocus()
      }
      onPositionChanged: root.wakeRequested()
    }

    Column {
      id: clockStage
      anchors.top: parent.top
      anchors.topMargin: root.compact ? 44 : Math.max(62, root.height * 0.07)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: root.compact ? -1 : 2
      opacity: Math.max(0, (root.entranceProgress - 0.01) / 0.70)
      transform: Translate { y: (1 - root.entranceProgress) * -30 }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.dateText.toUpperCase()
        color: Util.alpha(NekoColor.foreground, 0.78)
        font.family: Style.font.family
        font.pixelSize: root.compact ? Style.font.bodySmall : Style.font.subtitle
        font.weight: Font.DemiBold
        font.letterSpacing: 2.0
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.timeText
        color: NekoColor.foreground
        font.family: Style.font.family
        font.pixelSize: root.compact ? 76 : Math.min(154, root.height * 0.135)
        font.weight: Font.ExtraLight
        font.letterSpacing: -4
        style: Text.Raised
        styleColor: Util.alpha(NekoColor.background, 0.22)
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰌾"
          color: NekoColor.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "NEKO SESSION LOCKED"
          color: Util.alpha(NekoColor.foreground, 0.66)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: Font.DemiBold
          font.letterSpacing: 1.5
        }
      }
    }

    Item {
      id: unlockStage
      width: Math.min(root.compact ? 520 : 680, root.width - 32)
      height: root.compact ? 82 : 98
      anchors.bottom: parent.bottom
      anchors.bottomMargin: root.compact ? 34 : Math.max(52, root.height * 0.055)
      anchors.horizontalCenter: parent.horizontalCenter
      opacity: Math.max(0, (root.entranceProgress - 0.16) / 0.84)
      scale: 0.94 + 0.06 * root.entranceProgress
      transform: Translate {
        x: root.errorShake
        y: (1 - root.entranceProgress) * 46
      }

      BorderSurface {
        id: authIsland
        anchors.fill: parent
        radius: height / 2
        color: NekoColor.lock.background
        borderSpec: root.islandBorderSpec

        Rectangle {
          anchors.fill: parent
          anchors.margins: 1
          radius: authIsland.radius - 1
          color: Util.alpha(NekoColor.foreground, 0.025)
        }

        Row {
          anchors.fill: parent
          anchors.leftMargin: root.compact ? 13 : 17
          anchors.rightMargin: root.compact ? 13 : 17
          anchors.topMargin: root.compact ? 11 : 15
          anchors.bottomMargin: root.compact ? 11 : 15
          spacing: root.compact ? 10 : 14

          Rectangle {
            id: avatar
            anchors.verticalCenter: parent.verticalCenter
            width: parent.height
            height: width
            radius: width / 2
            color: Util.alpha(NekoColor.accent, 0.16)
            border.width: 1
            border.color: Util.alpha(NekoColor.accent, 0.70)

            Text {
              anchors.centerIn: parent
              text: root.userInitial
              color: NekoColor.accent
              font.family: Style.font.family
              font.pixelSize: root.compact ? Style.font.title : Style.font.heading
              font.weight: Font.Bold
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: root.compact ? 125 : 158
            spacing: 2

            Text {
              width: parent.width
              text: root.userName
              color: NekoColor.lock.text
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: root.compact ? Style.font.body : Style.font.title
              font.weight: Font.DemiBold
            }

            Text {
              width: parent.width
              text: root.fingerprintUnavailable ? "Sensor unavailable"
                : root.fingerprintConfigured ? "Touch or type to unlock"
                : root.inputEnabled ? "Enter password" : "Lock preview"
              color: root.fingerprintUnavailable ? NekoColor.lock.textError : NekoColor.lock.placeholder
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: parent.height * 0.62
            color: Util.alpha(NekoColor.lock.text, 0.16)
          }

          BorderSurface {
            id: inputField
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - avatar.width - (root.compact ? 125 : 158) - 1 - parent.spacing * 3
            height: parent.height
            radius: height / 2
            color: Util.alpha(NekoColor.background, 0.48)
            borderSpec: root.inputBorderSpec
            clip: true

            Text {
              anchors.left: parent.left
              anchors.leftMargin: root.compact ? 16 : 20
              anchors.verticalCenter: parent.verticalCenter
              text: root.errorState ? "󰌾" : "󰌽"
              color: root.errorState ? NekoColor.lock.textError : (root.fieldActive ? NekoColor.accent : NekoColor.lock.placeholder)
              font.family: Style.font.family
              font.pixelSize: Style.font.icon
              Behavior on color { ColorAnimation { duration: Style.duration(150) } }
            }

            TextInput {
              id: passwordInput
              anchors.fill: parent
              anchors.leftMargin: root.compact ? 48 : 54
              anchors.rightMargin: root.compact ? 50 : 58
              verticalAlignment: TextInput.AlignVCenter
              horizontalAlignment: TextInput.AlignLeft
              activeFocusOnPress: true
              clip: true
              enabled: root.inputEnabled && !root.authenticatingPassword
              readOnly: root.authenticatingPassword
              echoMode: TextInput.Password
              passwordCharacter: "\u25CF"
              passwordMaskDelay: 0
              color: NekoColor.lock.text
              selectionColor: NekoColor.lock.selection
              selectedTextColor: NekoColor.lock.text
              font.family: Style.font.family
              font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
              font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
              cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
              cursorDelegate: Rectangle {
                width: 2
                color: NekoColor.lock.text
                visible: passwordInput.cursorVisible
              }

              onTextChanged: {
                if (!root.syncingPasswordText) root.passwordTextEdited(text)
                if (text.length > 0) root.wakeRequested()
                if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
              }
              onAccepted: root.submitCurrentPassword()

              Keys.onPressed: function(event) {
                root.wakeRequested()
                if (event.isAutoRepeat && root.dropsAutoRepeat(event.key)) {
                  event.accepted = true
                  return
                }
                if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
                  root.passwordTextEdited("")
                  event.accepted = true
                }
              }
            }

            Text {
              anchors.fill: passwordInput
              text: root.authenticatingPassword ? "Checking…"
                : root.errorState ? root.failureMessage
                : "Password"
              visible: passwordInput.text.length === 0
              color: root.errorState ? NekoColor.lock.textError : NekoColor.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: root.fieldFontSize
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
            }

            Rectangle {
              anchors.right: parent.right
              anchors.rightMargin: root.compact ? 8 : 10
              anchors.verticalCenter: parent.verticalCenter
              width: root.compact ? 34 : 40
              height: width
              radius: width / 2
              color: root.passwordText.length > 0 || root.authenticatingPassword || root.fingerprintConfigured
                ? Util.alpha(root.fingerprintUnavailable ? NekoColor.lock.textError : NekoColor.accent, 0.16)
                : "transparent"

              Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "transparent"
                border.width: 1
                border.color: Util.alpha(NekoColor.accent, 0.48)
                visible: root.fingerprintConfigured && root.fingerprintAuthenticating && root.passwordText.length === 0 && !root.fingerprintUnavailable

                SequentialAnimation on scale {
                  running: parent.visible && !Style.reduceMotion
                  loops: Animation.Infinite
                  NumberAnimation { from: 0.82; to: 1.18; duration: 720; easing.type: Easing.OutCubic }
                  NumberAnimation { to: 0.82; duration: 720; easing.type: Easing.InCubic }
                }
                SequentialAnimation on opacity {
                  running: parent.visible && !Style.reduceMotion
                  loops: Animation.Infinite
                  NumberAnimation { from: 0.9; to: 0.22; duration: 720; easing.type: Easing.OutCubic }
                  NumberAnimation { to: 0.9; duration: 720; easing.type: Easing.InCubic }
                }
              }

              Text {
                id: actionGlyph
                anchors.centerIn: parent
                text: root.authenticatingPassword ? "󰔟"
                  : root.passwordText.length > 0 ? "→"
                  : root.fingerprintUnavailable ? "󰺱"
                  : root.fingerprintConfigured ? "󰈷" : "→"
                color: root.fingerprintUnavailable ? NekoColor.lock.textError
                  : root.passwordText.length > 0 || root.authenticatingPassword || root.fingerprintConfigured
                    ? NekoColor.accent : NekoColor.lock.placeholder
                font.family: Style.font.family
                font.pixelSize: root.authenticatingPassword || (root.fingerprintConfigured && root.passwordText.length === 0)
                  ? Style.font.icon : Style.font.heading
                font.weight: Font.DemiBold

                RotationAnimation on rotation {
                  running: root.authenticatingPassword && !Style.reduceMotion
                  from: 0
                  to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: root.passwordText.length > 0 && !root.authenticatingPassword
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  root.wakeRequested()
                  root.submitCurrentPassword()
                }
              }
            }
          }
        }
      }
    }

    Text {
      anchors.bottom: unlockStage.top
      anchors.bottomMargin: root.compact ? 10 : 14
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.inputEnabled ? "Press Enter to unlock  ·  Esc to clear" : "Preview — click anywhere to close"
      color: Util.alpha(NekoColor.foreground, 0.62)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 0.6
      opacity: Math.max(0, (root.entranceProgress - 0.34) / 0.66)
    }
  }
}
