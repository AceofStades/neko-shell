import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The focused window, the way a Mac's menu bar shows it: the app's name in
// bold (from its desktop entry), then the window's title, dimmer.
BarWidget {
  id: root
  moduleName: "neko.active-window"

  readonly property var toplevel: ToplevelManager.activeToplevel
  readonly property string appId: toplevel ? (toplevel.appId || "") : ""
  readonly property string title: toplevel ? (toplevel.title || "") : ""
  readonly property string appName: {
    if (!appId) return ""
    var entry = typeof DesktopEntries.heuristicLookup === "function" ? DesktopEntries.heuristicLookup(appId) : DesktopEntries.byId(appId)
    if (entry && entry.name) return entry.name
    // org.example.App or app-name: the last part, capitalized
    var name = appId.split(".").pop().replace(/[-_]+/g, " ")
    return name.charAt(0).toUpperCase() + name.slice(1)
  }
  // The title, unless it only repeats the app's name
  readonly property string detail: title.toLowerCase() === appName.toLowerCase() ? "" : title
  readonly property string tooltip: detail ? appName + ": " + detail : appName
  readonly property int maxLabelWidth: Number(setting("maxWidth", 420))

  visible: appName !== "" && !vertical
  // The name and the whole title side by side, before the title is cut short
  readonly property real fullWidth: nameText.implicitWidth + (detail ? label.spacing + detailText.implicitWidth : 0)

  implicitWidth: visible ? Math.min(maxLabelWidth, fullWidth) + Style.spacing.controlPaddingX * 2 : 0
  implicitHeight: barSize

  Behavior on implicitWidth {
    NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic }
  }

  Item {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(8)
    clip: true

    Row {
      id: label
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      width: parent.width
      spacing: Style.space(8)

      Text {
        id: nameText
        textFormat: Text.PlainText
        text: root.appName
        color: root.bar ? root.bar.barForeground : NekoColor.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        font.weight: Font.Bold
      }

      Text {
        id: detailText
        visible: root.detail !== ""
        width: Math.max(0, label.width - nameText.implicitWidth - label.spacing)
        textFormat: Text.PlainText
        text: root.detail
        color: root.bar ? root.bar.barForeground : NekoColor.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        opacity: 0.6
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor

    onClicked: function(mouse) {
      if (!root.toplevel) return
      if (mouse.button === Qt.MiddleButton) {
        root.toplevel.close()
      } else if (mouse.button === Qt.RightButton) {
        root.toplevel.close()
      } else {
        root.toplevel.activate()
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }
}
