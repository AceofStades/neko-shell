import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// The control center's quick-start island, a card beside the main one. It is
// the UniBar island's Pomodoro view carried over: the remaining time in a
// progress dial, phase context and controls grouped beside it, and a focus
// length to pick under both. The timer lives in Island; this reads and drives
// it, so a session started here shows on the right of the island.
Item {
  id: root

  property var bar: null
  // The card's own color, and how far its edge is from this item's, for the
  // settings circle that sits beside it
  property color surface: NekoColor.popups.background
  property real cardEdge: 0
  readonly property bool glass: !!bar && bar.glass === true
  // The island's own palette, so the card reads as the same surface
  readonly property color text: glass ? "#f2f2f2" : bar ? bar.barForeground : NekoColor.foreground
  readonly property color dim: Util.alpha(text, 0.65)
  readonly property color track: Util.alpha(text, 0.2)
  readonly property color accent: NekoColor.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int round: Island.pomodoroCompleted % 4 + 1
  readonly property string status: Island.pomodoroRunning
    ? "Ends at " + Qt.formatTime(new Date(Island.pomodoroTargetAt), "HH:mm")
    : Island.pomodoroActive ? "Paused" : "Ready when you are"
  readonly property string headline: Island.pomodoroRunning
    ? (Island.pomodoroPhase === "focus" ? "Stay in the flow" : "Take a real pause")
    : Island.pomodoroActive ? "Session paused" : "Begin a focus block"
  readonly property string nextPhase: Island.pomodoroPhase !== "focus" ? "Focus up next"
    : round === 4 ? "Long break up next" : "Short break up next"
  readonly property var lengths: [15, 25, 50]

  implicitWidth: Style.space(392)
  implicitHeight: Style.space(143)

  // The remaining time as a dial
  Item {
    id: dial
    width: Style.space(136)
    height: width
    readonly property real arcRadius: width / 2 - Style.space(10)
    readonly property bool hasProgress: Island.pomodoroFraction > 0.002

    Rectangle {
      anchors.centerIn: parent
      width: parent.width - Style.space(28)
      height: width
      radius: width / 2
      color: Util.alpha(root.text, 0.035)
      border.width: 1
      border.color: Util.alpha(root.text, 0.055)
    }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: Style.space(6)
        strokeColor: Util.alpha(root.text, 0.13)
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: dial.width / 2
          centerY: dial.height / 2
          radiusX: dial.arcRadius
          radiusY: dial.arcRadius
          startAngle: -90
          sweepAngle: 360
        }
      }

      ShapePath {
        strokeWidth: Style.space(14)
        strokeColor: dial.hasProgress ? Util.alpha(root.accent, 0.14) : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: dial.width / 2
          centerY: dial.height / 2
          radiusX: dial.arcRadius
          radiusY: dial.arcRadius
          startAngle: -90
          sweepAngle: 360 * Island.pomodoroFraction
        }
      }

      ShapePath {
        strokeWidth: Style.space(6)
        strokeColor: dial.hasProgress ? root.accent : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: dial.width / 2
          centerY: dial.height / 2
          radiusX: dial.arcRadius
          radiusY: dial.arcRadius
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
        color: root.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge
        font.weight: Font.Bold
        font.features: { "tnum": 1 }
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "REMAINING"
        color: root.dim
        font.family: root.fontFamily
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
      color: Island.pomodoroRunning ? root.accent : root.dim
      opacity: Island.pomodoroActive ? 1 : 0.45

      SequentialAnimation on opacity {
        running: root.visible && Island.pomodoroRunning && !Style.reduceMotion
        loops: Animation.Infinite
        NumberAnimation { to: 0.35; duration: 850; easing.type: Easing.InOutSine }
        NumberAnimation { to: 1; duration: 850; easing.type: Easing.InOutSine }
      }
    }
  }

  // Phase, headline and controls, beside the dial
  Item {
    x: dial.width + Style.space(16)
    width: parent.width - x
    height: dial.height

    Row {
      spacing: Style.space(7)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Island.pomodoroPhase === "focus" ? "󰔛" : "󰒲"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Island.pomodoroTitle.toUpperCase()
        color: root.accent
        font.family: root.fontFamily
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
      color: Util.alpha(root.text, 0.065)
      border.width: 1
      border.color: Util.alpha(root.text, 0.08)

      Text {
        id: roundLabel
        anchors.centerIn: parent
        text: "ROUND " + root.round + "/4"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption - 1
        font.weight: Font.Bold
        font.letterSpacing: Style.spaceReal(0.4)
      }
    }

    Text {
      y: Style.space(24)
      width: parent.width
      text: root.headline
      color: root.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.title + 2
      font.weight: Font.Bold
      elide: Text.ElideRight
    }

    Text {
      y: Style.space(49)
      width: parent.width
      text: root.status + "  •  " + root.nextPhase
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Row {
      y: Style.space(72)
      spacing: Style.space(6)

      Repeater {
        model: 4
        Rectangle {
          required property int index
          width: index === root.round - 1 ? Style.space(25) : Style.space(10)
          height: Style.space(6)
          radius: height / 2
          color: index < root.round ? root.accent : root.track
          opacity: index === root.round - 1 ? 1 : index < root.round ? 0.5 : 1
          Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Island.pomodoroCompleted + " completed"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption - 1
      }
    }

    Row {
      y: Style.space(95)
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

  // Pomodoro's settings: a circle off the card's right, with a cog, that opens
  // downward into the focus lengths while the pointer is on it. It spans the
  // gap to the card, so crossing it doesn't let it close, and it swallows
  // clicks so they don't reach the panel's dismissal area.
  Item {
    id: settingsCircle
    readonly property real gap: Style.space(10)
    readonly property real d: Style.space(44)
    readonly property real row: Style.space(38)
    property bool hoverOn: false

    x: root.width + root.cardEdge
    y: -root.cardEdge + Style.space(6)
    width: gap + d
    height: hoverOn ? d + root.lengths.length * row + Style.space(8) : d

    Behavior on height {
      enabled: !Style.reduceMotion
      SpringAnimation { spring: Style.spring.stiffness; damping: 0.55; epsilon: 0.5 }
    }

    HoverHandler {
      onHoveredChanged: settingsCircle.hoverOn = hovered
    }
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Rectangle {
      x: settingsCircle.gap
      width: settingsCircle.d
      height: parent.height
      radius: width / 2
      color: root.surface
      clip: true

      // The card's own tint and edge, so the two read as one family
      Rectangle { anchors.fill: parent; radius: parent.radius; color: Util.alpha(root.accent, 0.1) }
      Rectangle {
        anchors.fill: parent
        radius: parent.radius
        color: "transparent"
        border.width: 1
        border.color: Util.alpha(root.text, 0.11)
      }

      Text {
        width: parent.width
        height: settingsCircle.d
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "󰒓"
        color: settingsCircle.hoverOn ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.title + 2
        Behavior on color { ColorAnimation { duration: Style.duration(140) } }
      }

      Column {
        y: settingsCircle.d
        width: parent.width
        opacity: settingsCircle.hoverOn ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }

        Repeater {
          model: root.lengths

          Item {
            id: lengthButton
            required property int modelData
            readonly property bool selected: Island.pomodoroFocusDuration === modelData * 60

            width: parent.width
            height: settingsCircle.row
            scale: lengthArea.containsMouse ? 1.08 : 1
            Behavior on scale { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }

            Rectangle {
              anchors.centerIn: parent
              width: Style.space(32)
              height: width
              radius: width / 2
              color: lengthButton.selected ? root.accent : Util.alpha(root.text, lengthArea.containsMouse ? 0.14 : 0.06)
              border.width: 1
              border.color: lengthButton.selected ? Util.alpha(root.text, 0.2) : Util.alpha(root.text, 0.08)
              Behavior on color { ColorAnimation { duration: Style.duration(120) } }
            }
            Text {
              anchors.centerIn: parent
              text: lengthButton.modelData
              color: lengthButton.selected ? "#101010" : root.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.weight: Font.Bold
            }
            MouseArea {
              id: lengthArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: Island.setPomodoroFocusDuration(lengthButton.modelData * 60)
            }
          }
        }
      }
    }
  }

  // The island's own control button: a round glyph, or a wider primary pill
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
        : Util.alpha(root.text, pomodoroButtonArea.containsMouse ? 0.12 : 0.05)
      border.width: 1
      border.color: pomodoroButton.primary ? Util.alpha(root.text, 0.2) : Util.alpha(root.text, 0.08)
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }

    Row {
      anchors.centerIn: parent
      spacing: Style.space(7)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: pomodoroButton.glyph
        color: pomodoroButton.primary ? "#101010" : root.text
        font.family: root.fontFamily
        font.pixelSize: pomodoroButton.primary ? Style.font.title + 2 : Style.font.title
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: pomodoroButton.primary && pomodoroButton.label !== ""
        text: pomodoroButton.label
        color: "#101010"
        font.family: root.fontFamily
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
