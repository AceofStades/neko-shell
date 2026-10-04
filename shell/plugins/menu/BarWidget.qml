import QtQuick
import qs.Ui

BarWidget {
  id: root
  moduleName: "neko.menu"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-md-cat from the bar's Nerd Font
    text: "\udb80\udd1b"
    centerFigures: false
    horizontalMargin: 7.5
    onPressed: function(button) {
      if (!root.bar) return
      if (button === Qt.RightButton) root.bar.run("xdg-terminal-exec")
      else root.bar.run("neko-shell shell toggle neko.menu '{\"menu\":\"root\"}'")
    }
  }
}
