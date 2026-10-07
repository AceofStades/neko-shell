import QtQuick
import Quickshell.Io
import qs.Commons

// The shell draws stills only. OWE owns video backgrounds on the desktop, and
// it feeds the lock screen through its own socket.
Item {
  id: root

  property string path: ""
  property int version: 0
  // Unversioned images cache by path. A caller whose version changes with every
  // new file, as the lock's does, may cache too: the version is in the URL.
  property bool cached: version === 0
  // A caller that knows the size its screen needs, in physical pixels, sets
  // constrainDecode and decodeSize. The image then waits for that size rather
  // than decoding at the file's native size first.
  property bool constrainDecode: false
  property size decodeSize: Qt.size(0, 0)
  readonly property var current: imageLoader.item
  readonly property bool ready: current ? current.ready : false
  readonly property bool video: Util.isVideoPath(path)
  // Cache-bust images selected in a running lock session, so a theme switch
  // that replaces the file behind an unchanged path shows the new pixels.
  readonly property url imageUrl: path && !video ? Util.fileUrl(fallbackPath || path) + (version ? "?v=" + version : "") : ""

  // A PNG copy of an image this Qt has no plugin for (WebP, AVIF... without
  // qt6-imageformats), from neko-image-png; cleared with every new path
  property string fallbackPath: ""
  onPathChanged: fallbackPath = ""

  function useFallback() {
    if (fallbackPath || converter.running || !path) return
    converter.command = ["neko-image-png", path]
    converter.running = true
  }

  Process {
    id: converter
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var copy = String(text || "").trim()
        if (copy) root.fallbackPath = copy
      }
    }
  }

  Loader {
    id: imageLoader
    anchors.fill: parent
    active: root.path !== "" && !root.video
    sourceComponent: imageComponent
  }

  Component {
    id: imageComponent

    Image {
      readonly property bool ready: status === Image.Ready
      source: !root.constrainDecode || root.decodeSize.width > 0 ? root.imageUrl : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: root.cached
      sourceSize.width: root.constrainDecode ? root.decodeSize.width : (root.version > 0 ? width : 0)
      sourceSize.height: root.constrainDecode ? root.decodeSize.height : (root.version > 0 ? height : 0)
      onStatusChanged: if (status === Image.Error) root.useFallback()
    }
  }
}
