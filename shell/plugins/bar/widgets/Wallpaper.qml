import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// Wallpaper: left picks, right or scroll sets a random one, middle toggles rotation
BarWidget {
  id: root
  moduleName: "neko.wallpaper"

  // neko-wallpaper writes the rotation interval here, and removes it when rotation is off
  property string rotationMinutes: ""
  readonly property bool rotating: rotationMinutes !== ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: rotationFile
    path: Quickshell.env("HOME") + "/.config/neko/wallpaper-rotation"
    watchChanges: true
    printErrors: false
    onLoaded: root.rotationMinutes = text().trim()
    onLoadFailed: root.rotationMinutes = ""
    // text() is stale in the change signal itself, so re-read through onLoaded
    onFileChanged: reload()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸉"
    active: root.rotating
    tooltipText: root.rotating
      ? "Wallpaper, new one every " + root.rotationMinutes + " minutes"
      : "Wallpaper (left: pick, right: random, middle: rotate)"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.bar.run("neko-wallpaper random")
      else if (b === Qt.MiddleButton) root.bar.run(root.rotating ? "neko-wallpaper auto off" : "neko-wallpaper auto 30")
      else root.bar.run("neko-wallpaper pick")
    }
    onWheelMoved: function(delta) {
      root.bar.run("neko-wallpaper random")
    }
  }
}
