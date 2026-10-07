import QtQuick
import qs.Commons

// A battery drawn to scale: rounded body, terminal nub, a fill for the charge
// and the percentage inside it, with a bolt beside it while charging. The
// fill and bolt take stateColor (green on power, amber and red when low),
// else the text color.
Item {
  id: root

  property real fraction: 0
  property bool charging: false
  property bool low: false
  // The battery's state as a color, "" for none (see Model.batteryStateColor)
  property string stateColor: ""
  readonly property color fillColor: stateColor !== "" ? stateColor : foreground
  property bool showNumber: true
  property color foreground: NekoColor.bar.text
  property string fontFamily: Style.font.family

  readonly property real bodyWidth: 30
  readonly property real bodyHeight: 15
  readonly property real boltWidth: charging ? boltText.implicitWidth + 2 : 0

  implicitWidth: boltWidth + bodyWidth + 3
  implicitHeight: bodyHeight

  Text {
    id: boltText
    visible: root.charging
    anchors.verticalCenter: parent.verticalCenter
    anchors.right: body.left
    anchors.rightMargin: 2
    text: "󱐋"
    color: root.fillColor
    font.family: root.fontFamily
    font.pixelSize: 11
  }

  Rectangle {
    id: body
    x: (parent.width - width) / 2 + root.boltWidth / 2 - 1.5
    anchors.verticalCenter: parent.verticalCenter
    width: root.bodyWidth
    height: root.bodyHeight
    radius: 3.5
    color: "transparent"
    border.width: 1.2
    border.color: Util.alpha(root.foreground, 0.75)

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: 2
      width: Math.max(0, (parent.width - 4) * Math.min(1, Math.max(0, root.fraction)))
      radius: 1.5
      color: Util.alpha(root.fillColor, root.stateColor !== "" ? 0.75 : 0.5)
      Behavior on color { ColorAnimation { duration: Style.duration(200) } }

      Behavior on width { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }
    }

    Text {
      visible: root.showNumber
      anchors.centerIn: parent
      text: Math.round(root.fraction * 100)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: 10
      font.weight: Font.Bold
    }
  }

  // Terminal nub
  Rectangle {
    anchors.left: body.right
    anchors.leftMargin: 1
    anchors.verticalCenter: body.verticalCenter
    width: 2
    height: 6
    radius: 1
    color: Util.alpha(root.foreground, 0.75)
  }
}
