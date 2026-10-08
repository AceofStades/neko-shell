import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Wallpaper-first lock surface with one auth island that expands for passwords.
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
  property bool syncingPasswordText: false
  property bool passwordModeRequested: false
  property real entranceProgress: 0
  property real errorShake: 0

  readonly property bool compact: width < 760 || height < 620
  readonly property bool video: Util.isVideoPath(root.backgroundPath)
  readonly property bool feedActive: root.video && root.loadBackground && !root.displaysBlank && !root.powerSaverActive
  readonly property bool errorState: failureMessage.length > 0
  readonly property bool passwordMode: passwordModeRequested || passwordText.length > 0 || authenticatingPassword || errorState || !faceConfigured
  readonly property bool faceApproved: faceAuthState === "approved"
  readonly property bool faceFailed: faceAuthState === "failed"
  readonly property bool faceScanning: faceConfigured && !passwordMode && !faceApproved && (faceAuthenticating || faceAuthState === "scanning")
  readonly property bool fieldActive: passwordMode && (passwordInput.activeFocus || passwordText.length > 0 || authenticatingPassword)
  readonly property string timeText: Qt.formatDateTime(clock.date, "HH:mm")
  readonly property string dateText: Qt.formatDateTime(clock.date, "dddd  ·  d MMMM")
  readonly property string faceStatusText: faceApproved ? "Welcome back"
    : faceFailed ? "Face not recognized · trying again"
    : faceScanning ? "Looking for you"
    : faceConfigured ? "Face unlock ready"
    : fingerprintUnavailable ? "Sensor unavailable"
    : fingerprintConfigured ? "Touch the fingerprint sensor"
    : "Password required"
  readonly property color faceStateColor: faceApproved ? NekoColor.accent
    : faceFailed ? NekoColor.lock.textError
    : faceScanning ? NekoColor.accent
    : NekoColor.lock.placeholder
  readonly property int fieldFontSize: Math.round(Style.font.heading * 0.90)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.08)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.14)
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 8) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && !errorState
  readonly property var islandBorderSpec: Border.surfaceSpec("lock", "border", Util.alpha(NekoColor.lock.border, 0.58), 1, "border-alpha")
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", NekoColor.lock.borderError, 2, "border-alpha")
    : fieldActive
      ? Border.surfaceSpec("lock", "border-active", NekoColor.lock.borderActive, 2, "border-alpha")
      : Border.surfaceSpec("lock", "border", Util.alpha(NekoColor.lock.border, 0.34), 1, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  function forcePasswordFocus() {
    if (root.inputEnabled) passwordInput.forceActiveFocus()
  }

  function showPasswordMode() {
    passwordModeRequested = true
    root.wakeRequested()
    Qt.callLater(forcePasswordFocus)
  }

  function returnToFaceMode() {
    root.passwordTextEdited("")
    root.clearFailureRequested()
    passwordModeRequested = false
    root.wakeRequested()
    Qt.callLater(forcePasswordFocus)
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

  onPasswordTextChanged: {
    syncPasswordText()
    if (passwordText.length > 0) passwordModeRequested = true
  }
  onInputEnabledChanged: if (inputEnabled) Qt.callLater(forcePasswordFocus)
  onLoadBackgroundChanged: if (loadBackground) startEntrance()
  onFailureMessageChanged: {
    if (failureMessage.length > 0) {
      passwordModeRequested = true
      if (!Style.reduceMotion) errorAnimation.restart()
    }
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
    duration: Style.duration(900)
    easing.type: Easing.OutCubic
  }

  SequentialAnimation {
    id: errorAnimation
    NumberAnimation { target: root; property: "errorShake"; to: -11; duration: 52; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: 9; duration: 68; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: -6; duration: 64; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: 3; duration: 58; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "errorShake"; to: 0; duration: 78; easing.type: Easing.OutQuad }
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
      scale: 1.035 - 0.035 * root.entranceProgress
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

    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0.0; color: Util.alpha(NekoColor.background, 0.46) }
        GradientStop { position: 0.16; color: Util.alpha(NekoColor.background, 0.10) }
        GradientStop { position: 0.58; color: Util.alpha(NekoColor.background, 0.03) }
        GradientStop { position: 1.0; color: Util.alpha(NekoColor.background, 0.58) }
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

    // The lock indicator grows directly from the screen edge.
    Item {
      id: lockTab
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      width: 126
      height: 42
      opacity: Math.max(0, (root.entranceProgress - 0.10) / 0.70)
      transform: Translate { y: (1 - root.entranceProgress) * -18 }

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: -22
        width: parent.width
        height: 64
        radius: 21
        color: Util.alpha(NekoColor.background, 0.88)
        border.width: 1
        border.color: Util.alpha(NekoColor.lock.border, 0.32)
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 9
        spacing: 7

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰌾"
          color: NekoColor.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "LOCKED"
          color: Util.alpha(NekoColor.foreground, 0.76)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.weight: Font.DemiBold
          font.letterSpacing: 1.4
        }
      }
    }

    Column {
      id: clockStage
      anchors.top: parent.top
      anchors.topMargin: root.compact ? 66 : Math.max(94, root.height * 0.115)
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: root.compact ? -5 : -8
      opacity: Math.max(0, (root.entranceProgress - 0.02) / 0.74)
      transform: Translate { y: (1 - root.entranceProgress) * -26 }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.timeText
        color: NekoColor.foreground
        font.family: Style.font.family
        font.pixelSize: root.compact ? 82 : Math.min(174, root.height * 0.158)
        font.weight: Font.ExtraLight
        font.letterSpacing: -5
        style: Text.Raised
        styleColor: Util.alpha(NekoColor.background, 0.25)
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.dateText
        color: Util.alpha(NekoColor.foreground, 0.76)
        font.family: Style.font.family
        font.pixelSize: root.compact ? Style.font.bodySmall : Style.font.subtitle
        font.weight: Font.Medium
        font.letterSpacing: 0.8
      }
    }

    Item {
      id: unlockStage
      width: Math.min(root.passwordMode
        ? (root.compact ? 510 : 610)
        : (root.compact ? 346 : 382), root.width - 32)
      height: root.compact ? 74 : 86
      anchors.bottom: parent.bottom
      anchors.bottomMargin: root.compact ? 42 : Math.max(64, root.height * 0.072)
      anchors.horizontalCenter: parent.horizontalCenter
      opacity: Math.max(0, (root.entranceProgress - 0.18) / 0.82)
      scale: 0.92 + 0.08 * root.entranceProgress
      transform: Translate {
        x: root.errorShake
        y: (1 - root.entranceProgress) * 42
      }

      Behavior on width {
        NumberAnimation {
          duration: Style.duration(420)
          easing.type: Easing.OutCubic
        }
      }

      BorderSurface {
        id: authIsland
        anchors.fill: parent
        radius: height / 2
        color: Util.alpha(NekoColor.lock.background, 0.94)
        borderSpec: root.islandBorderSpec
        clip: true

        Rectangle {
          anchors.fill: parent
          anchors.margins: 1
          radius: authIsland.radius - 1
          color: Util.alpha(NekoColor.foreground, 0.022)
        }

        Item {
          id: avatarFrame
          anchors.left: parent.left
          anchors.leftMargin: root.compact ? 10 : 12
          anchors.verticalCenter: parent.verticalCenter
          width: root.compact ? 54 : 62
          height: width

          Rectangle {
            id: faceRipple
            anchors.centerIn: parent
            width: parent.width - 2
            height: width
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: root.faceStateColor
            visible: root.faceScanning || root.faceApproved

            SequentialAnimation on scale {
              running: faceRipple.visible && !Style.reduceMotion
              loops: Animation.Infinite
              NumberAnimation { from: 0.88; to: 1.18; duration: Style.duration(900); easing.type: Easing.OutCubic }
              NumberAnimation { to: 0.88; duration: Style.duration(20) }
            }

            SequentialAnimation on opacity {
              running: faceRipple.visible && !Style.reduceMotion
              loops: Animation.Infinite
              NumberAnimation { from: 0.78; to: 0.05; duration: Style.duration(900); easing.type: Easing.OutCubic }
              NumberAnimation { to: 0.78; duration: Style.duration(20) }
            }
          }

          Rectangle {
            id: avatar
            anchors.centerIn: parent
            width: parent.width - 8
            height: width
            radius: width / 2
            color: Util.alpha(root.faceStateColor, root.faceFailed ? 0.14 : 0.16)
            border.width: 1
            border.color: Util.alpha(root.faceStateColor, 0.72)
            clip: true

            Text {
              id: faceGlyph
              anchors.centerIn: parent
              text: root.faceApproved ? "\u{F012C}"
                : root.faceFailed ? "\u{F0156}"
                : root.faceConfigured ? "\u{F0C7B}"
                : root.userName.charAt(0).toUpperCase()
              color: root.faceStateColor
              font.family: Style.font.family
              font.pixelSize: root.faceConfigured ? Math.round(parent.width * 0.56) : Math.round(parent.width * 0.42)
              font.weight: Font.DemiBold

              SequentialAnimation on opacity {
                running: root.faceScanning && !Style.reduceMotion
                loops: Animation.Infinite
                NumberAnimation { to: 0.42; duration: Style.duration(620); easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: Style.duration(620); easing.type: Easing.InOutSine }
              }
            }

            Rectangle {
              id: scanBeam
              x: 7
              width: parent.width - 14
              height: 2
              radius: 1
              color: Util.alpha(NekoColor.accent, 0.92)
              visible: root.faceScanning
              opacity: visible ? 1 : 0

              SequentialAnimation on y {
                running: scanBeam.visible && !Style.reduceMotion
                loops: Animation.Infinite
                NumberAnimation { from: 9; to: avatar.height - 11; duration: Style.duration(1050); easing.type: Easing.InOutSine }
                NumberAnimation { to: 9; duration: Style.duration(1050); easing.type: Easing.InOutSine }
              }
            }
          }
        }

        Item {
          id: centerContent
          anchors.left: avatarFrame.right
          anchors.leftMargin: root.compact ? 9 : 12
          anchors.right: actionButton.left
          anchors.rightMargin: root.compact ? 8 : 10
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height - (root.compact ? 18 : 22)

          Column {
            id: faceCopy
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            opacity: root.passwordMode ? 0 : 1
            visible: opacity > 0

            Behavior on opacity { NumberAnimation { duration: Style.duration(150) } }

            Text {
              width: parent.width
              text: root.faceApproved ? "Hey, " + root.userName : root.userName
              color: NekoColor.lock.text
              elide: Text.ElideRight
              font.family: Style.font.family
              font.pixelSize: root.compact ? Style.font.body : Style.font.title
              font.weight: Font.DemiBold
            }

            Row {
              spacing: 7

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 5
                height: width
                radius: width / 2
                color: root.faceStateColor
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.faceStatusText
                color: root.faceStateColor
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          BorderSurface {
            id: inputField
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(NekoColor.background, 0.40)
            borderSpec: root.inputBorderSpec
            clip: true
            opacity: root.passwordMode ? 1 : 0
            visible: opacity > 0

            Behavior on opacity { NumberAnimation { duration: Style.duration(190) } }

            Text {
              anchors.left: parent.left
              anchors.leftMargin: root.compact ? 15 : 18
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
              anchors.leftMargin: root.compact ? 47 : 52
              anchors.rightMargin: 14
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
                  root.returnToFaceMode()
                  event.accepted = true
                }
              }
            }

            Text {
              anchors.fill: passwordInput
              text: root.authenticatingPassword ? "Checking…"
                : root.errorState ? root.failureMessage
                : "Password for " + root.userName
              visible: passwordInput.text.length === 0
              color: root.errorState ? NekoColor.lock.textError : NekoColor.lock.placeholder
              font.family: Style.font.family
              font.pixelSize: root.fieldFontSize
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
            }
          }
        }

        Rectangle {
          id: actionButton
          anchors.right: parent.right
          anchors.rightMargin: root.compact ? 10 : 12
          anchors.verticalCenter: parent.verticalCenter
          width: root.compact ? 44 : 50
          height: width
          radius: width / 2
          color: Util.alpha(root.errorState ? NekoColor.lock.textError : NekoColor.accent, root.passwordMode ? 0.17 : 0.12)
          border.width: 1
          border.color: Util.alpha(root.errorState ? NekoColor.lock.textError : NekoColor.accent, 0.36)

          Text {
            id: actionGlyph
            anchors.centerIn: parent
            text: root.authenticatingPassword ? "󰔟"
              : root.passwordMode ? (root.passwordText.length > 0 ? "→" : "󰌌")
              : "󰌌"
            color: root.errorState ? NekoColor.lock.textError : NekoColor.accent
            font.family: Style.font.family
            font.pixelSize: root.authenticatingPassword ? Style.font.icon
              : root.passwordMode && root.passwordText.length > 0 ? Style.font.heading
              : Style.font.icon
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
            enabled: root.inputEnabled && !root.authenticatingPassword
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
              if (!root.passwordMode) root.showPasswordMode()
              else if (root.passwordText.length > 0) root.submitCurrentPassword()
              else root.forcePasswordFocus()
            }
          }
        }
      }
    }

    Text {
      anchors.bottom: unlockStage.top
      anchors.bottomMargin: root.compact ? 11 : 15
      anchors.horizontalCenter: parent.horizontalCenter
      text: !root.inputEnabled ? "Preview · click anywhere to close"
        : root.passwordMode ? "Enter to unlock  ·  Esc to return to face unlock"
        : root.faceConfigured ? "Look at the camera  ·  type your password anytime"
        : root.fingerprintConfigured ? "Touch the sensor  ·  type your password anytime"
        : "Type your password to unlock"
      color: Util.alpha(NekoColor.foreground, 0.62)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 0.45
      opacity: Math.max(0, (root.entranceProgress - 0.34) / 0.66)
    }
  }
}
