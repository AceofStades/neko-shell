import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Wi-Fi and Bluetooth as one widget: the Wi-Fi icon with Bluetooth's state
// on it as a badge, and one panel with the two side by side. The two halves
// are the Wi-Fi and Bluetooth widgets themselves, embedded (Panel's
// embedHost), so their lists, scanning, pairing and keys all come along;
// Tab moves the keys across.
Panel {
  id: root
  moduleName: "neko.connections"
  ipcTarget: "neko.connections"

  readonly property var wifi: wifiLoader.item
  readonly property var bluetooth: bluetoothLoader.item
  // Which half has the keys
  property string keysOn: "wifi"

  readonly property bool bluetoothOn: !!bluetooth && !!bluetooth.adapter && bluetooth.adapter.enabled
  readonly property bool bluetoothConnected: bluetoothOn && (bluetooth.connectedDevices || []).length > 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function embed(item, host) {
    item.bar = Qt.binding(function() { return root.bar })
    item.embedHost = host
    item.embeddedCloseRequested.connect(root.close)
    item.embeddedSwitchRequested.connect(function() {
      root.keysOn = root.keysOn === "wifi" ? "bluetooth" : "wifi"
      root.focusKeys()
    })
    if (root.opened) item.showEmbedded()
  }

  function focusKeys() {
    var side = keysOn === "bluetooth" ? bluetooth : wifi
    if (side && side.embedFocusItem) side.embedFocusItem.forceActiveFocus()
  }

  onOpenedChanged: {
    if (opened) {
      keysOn = "wifi"
      if (wifi) wifi.showEmbedded()
      if (bluetooth) bluetooth.showEmbedded()
    } else {
      if (wifi) wifi.hideEmbedded()
      if (bluetooth) bluetooth.hideEmbedded()
    }
  }

  // The two widgets, kept off the bar; their contents go to the halves below
  Loader {
    id: wifiLoader
    visible: false
    source: Qt.resolvedUrl("../network/Panel.qml")
    onLoaded: root.embed(item, wifiSide)
  }
  Loader {
    id: bluetoothLoader
    visible: false
    source: Qt.resolvedUrl("../bluetooth/Panel.qml")
    onLoaded: root.embed(item, bluetoothSide)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.wifi ? root.wifi.icon : "\u{F05A9}"
    active: !!root.wifi && root.wifi.restricted
    tooltipText: "Wi-Fi and Bluetooth"
    onPressed: function(b) { root.toggle() }

    // Bluetooth on the Wi-Fi icon: a small mark at its foot, in the accent
    // while a device is connected, gone while Bluetooth is off
    Text {
      visible: root.bluetoothOn
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(3)
      text: root.bluetoothConnected ? "\u{F00B1}" : "\u{F00AF}"
      color: root.bluetoothConnected ? NekoColor.accent : Util.alpha(button.foreground, 0.8)
      font.family: button.fontFamily
      font.pixelSize: Math.round(Style.bar.fontSize * 0.72)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.keysOn === "bluetooth" && root.bluetooth ? root.bluetooth.embedFocusItem
      : root.wifi ? root.wifi.embedFocusItem : null
    readonly property real side: Style.space(380)
    readonly property real gap: Style.space(28)
    contentWidth: panel.fittedContentWidth(side * 2 + gap)
    contentHeight: panel.fittedContentHeight(Math.max(root.wifi ? root.wifi.embedHeight : 0, root.bluetooth ? root.bluetooth.embedHeight : 0))

    Item {
      anchors.fill: parent

      Item {
        id: wifiSide
        width: (parent.width - panel.gap) / 2
        height: parent.height
      }
      Rectangle {
        x: wifiSide.width + panel.gap / 2
        width: 1
        height: parent.height
        color: Util.alpha(root.bar ? root.bar.foreground : NekoColor.foreground, 0.1)
      }
      Item {
        id: bluetoothSide
        x: wifiSide.width + panel.gap
        width: wifiSide.width
        height: parent.height
      }
    }
  }
}
