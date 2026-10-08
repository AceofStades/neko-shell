import QtQuick
import Quickshell.Io
import qs.Commons

// Base item for plugin popup widgets. Many first-party plugins expose a bar
// button plus a popup from one QML entry point; this base owns the shared
// IPC-backed open/close lifecycle while implementations own button behavior,
// keyboard navigation, and content.
Item {
  id: root

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
  property string ipcTarget: ""
  property bool manageIpc: true
  property alias controller: panelController
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false

  readonly property bool opened: panelController.open
  readonly property color barForeground: bar ? bar.barForeground : NekoColor.foreground

  // Embedded in another widget's panel (the Connections widget shows Wi-Fi
  // and Bluetooth side by side): the host shows this panel's contents in its
  // own card and opens and closes it with showEmbedded/hideEmbedded, and
  // what this panel would do to a popup of its own goes to the host instead
  property Item embedHost: null
  readonly property bool embedded: embedHost !== null
  signal embeddedCloseRequested()
  signal embeddedSwitchRequested(int direction)
  function showEmbedded() { panelController.show() }
  function hideEmbedded() { panelController.hide() }

  function open() { panelController.show() }
  function close() {
    if (embedded) { embeddedCloseRequested(); return }
    panelController.hide()
  }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (embedded) { embeddedSwitchRequested(direction); return true }
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(root, direction)
    return false
  }

  // Read a single value from this panel's inline shell.json entry, with a
  // fallback for missing/null values. Matches BarWidget.setting().
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  PanelController {
    id: panelController
  }

  ShellIpc {
    enabled: root.manageIpc && root.ipcTarget !== "" && !root.embedded
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

}
