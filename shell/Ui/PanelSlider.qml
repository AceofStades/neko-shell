import QtQuick
import qs.Commons

Item {
  id: root

  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property color trackColor: bar ? Style.selectedFillFor(bar.foreground, NekoColor.accent) : "#333"
  property color fillColor: bar ? bar.foreground : NekoColor.foreground
  property color knobColor: bar ? bar.foreground : NekoColor.foreground
  property bool dragging: false
  property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  property real liveValue: value

  // macOS-style notches. When > 1, that many evenly-spaced tick marks are cut
  // into the track (drawn in the panel background color, so only the part
  // crossing the track shows). Purely visual — snapping is the caller's job via
  // `integer`/`step` or an index-based value. Default 0 leaves the track plain.
  property int tickCount: 0
  property color tickColor: bar ? bar.background : NekoColor.background
  // Fine steps between two marks (0 for none). A drag or the wheel lands on
  // the marks, like macOS's sixteen notches; holding Shift gets the fine steps
  // between them, which show as small dots while the pointer is on the track
  // or Shift is down. Needs `integer`, with the marks `fineCount` apart.
  property int fineCount: 0
  property bool fineHeld: false

  onValueChanged: if (!dragging) liveValue = value

  signal moved(real value)
  signal released(real value)

  // Right-click is a secondary action on the whole track — audio uses it to
  // mute the channel the slider belongs to. Dragging stays left-button only.
  signal rightClicked()

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
  readonly property bool _hot: mouseArea.containsMouse || root.dragging

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    height: root.trackHeight
    radius: height / 2
    color: root.trackColor
  }

  Rectangle {
    id: fill
    anchors.verticalCenter: track.verticalCenter
    anchors.left: track.left
    height: track.height
    radius: track.radius
    color: root.fillColor
    width: track.width * root.progress

    Behavior on width {
      enabled: !root.dragging || (root.fineCount > 1 && !root.fineHeld)
      NumberAnimation { duration: Style.duration(root.dragging ? 70 : 140); easing.type: Easing.OutCubic }
    }
  }

  Repeater {
    model: root.tickCount > 1 ? root.tickCount : 0
    Rectangle {
      required property int index
      width: Math.max(1, Style.space(2))
      height: root.trackHeight + Style.space(4)
      radius: 1
      color: root.tickColor
      anchors.verticalCenter: track.verticalCenter
      x: Math.max(0, Math.min(track.width - width,
                              track.width * (index / (root.tickCount - 1)) - width / 2))
    }
  }

  // The fine steps between the marks
  Repeater {
    model: root.fineCount > 1 && root.tickCount > 1 ? (root.tickCount - 1) * root.fineCount + 1 : 0
    Rectangle {
      required property int index
      readonly property bool onMark: index % root.fineCount === 0
      visible: !onMark
      width: Style.space(2)
      height: width
      radius: width / 2
      color: root.fillColor
      opacity: root._hot || root.fineHeld ? 0.5 : 0
      anchors.verticalCenter: track.verticalCenter
      x: Math.max(0, Math.min(track.width - width, track.width * (index / ((root.tickCount - 1) * root.fineCount)) - width / 2))
      Behavior on opacity { NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic } }
    }
  }

  BorderSurface {
    id: knob
    width: root.knobSize
    height: root.knobSize
    radius: root.knobSize / 2
    color: root.knobColor
    borderSpec: Border.flat(root.bar ? root.bar.background : "#101315", Math.max(1, Style.space(2)))
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progress - width / 2))
    scale: root._hot ? 1.15 : 1.0

    Behavior on x {
      // Snapped to marks while dragged, it eases tick to tick; free, it follows
      enabled: !root.dragging || (root.fineCount > 1 && !root.fineHeld)
      NumberAnimation { duration: Style.duration(root.dragging ? 70 : 140); easing.type: Easing.OutCubic }
    }

    Behavior on scale {
      NumberAnimation { duration: Style.duration(110); easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton

    function valueFromX(x, modifiers) {
      var clamped = Math.max(0, Math.min(track.width, x))
      var raw = root.minimum + (clamped / track.width) * root.range
      if (root.integer) raw = Math.round(raw)
      // Without Shift, onto the nearest mark
      if (root.fineCount > 1 && !(modifiers & Qt.ShiftModifier)) raw = Math.round(raw / root.fineCount) * root.fineCount
      return Math.max(root.minimum, Math.min(root.maximum, raw))
    }

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = true
      root.fineHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
      var next = valueFromX(mouse.x, mouse.modifiers)
      root.liveValue = next
      root.moved(next)
    }
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.rightClicked()
    }
    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      root.fineHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
      var next = valueFromX(mouse.x, mouse.modifiers)
      root.liveValue = next
      root.moved(next)
    }
    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = false
      root.fineHeld = false
      root.released(root.liveValue)
      root.liveValue = root.value
    }
    onWheel: function(wheel) {
      // A mark at a time, or with Shift a fine step at a time
      var size = root.fineCount > 1 && !(wheel.modifiers & Qt.ShiftModifier) ? root.step * root.fineCount : root.step
      var delta = wheel.angleDelta.y > 0 ? size : -size
      var next = Math.max(root.minimum, Math.min(root.maximum, root.liveValue + delta))
      if (root.integer) next = Math.round(next)
      // Landing on the marks: from between two, onto the next one that way
      if (root.fineCount > 1 && !(wheel.modifiers & Qt.ShiftModifier)) {
        var onMark = Math.round(root.liveValue / root.fineCount) * root.fineCount === root.liveValue
        if (!onMark) next = (wheel.angleDelta.y > 0 ? Math.ceil(root.liveValue / root.fineCount) : Math.floor(root.liveValue / root.fineCount)) * root.fineCount
        next = Math.max(root.minimum, Math.min(root.maximum, next))
      }
      root.liveValue = next
      root.moved(next)
      root.released(next)
    }
  }
}
