import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The clock's customization popup: what the bar's label says, and the
// presets to say it in. A right click on the clock opens it.
//
// The UniBar's own clock format is read out of the bar layouts, so the
// preset named after it is the format the user actually has in the
// UniBar rather than a guess at it.
Panel {
  id: root
  moduleName: "neko.clock"
  ipcTarget: "neko.clock"
  // manageIpc: false: the bar widget owns the single IpcHandler the
  // target permits, and routes the customize call to this popup.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : NekoColor.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string format: setting("format", "dddd HH:mm")
  readonly property string verticalFormat: setting("verticalFormat", "HH\n—\nmm")
  readonly property string altFormat: setting("formatAlt", "d MMMM 'W'ww yyyy")

  // The bar layouts, read for the UniBar's clock format
  property var layouts: []
  readonly property string unibarFormat: Model.unibarClockFormat(root.layouts)
  readonly property var presets: Model.clockPresets(root.format, root.unibarFormat)

  function open() {
    root.controller.show()
    // The layouts are read on every open: a saved layout may have been
    // changed since the last time.
    if (!layoutsProc.running) layoutsProc.running = true
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Written the way the calendar panel writes its own settings: the entry
  // is merged and handed to the shell, which persists it and hands the
  // same value back to the widget.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function applyFormat(key, value) {
    var values = {}
    values[key] = value
    persistSettings(values)
  }

  Process {
    id: layoutsProc
    command: ["neko-bar", "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "{}"))
          root.layouts = data.presets || []
        } catch (e) {
          root.layouts = []
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(chooser.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // A field has the keyboard while it is being typed in
      blocked: chooser.editing
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: chooserColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: chooserColumn
          width: parent.width

          ClockFormatChooser {
            id: chooser
            width: parent.width
            format: root.format
            verticalFormat: root.verticalFormat
            altFormat: root.altFormat
            presets: root.presets
            vertical: root.bar ? root.bar.vertical : false
            foreground: root.contentForeground
            accent: NekoColor.accent
            fontFamily: root.contentFontFamily
            onApplied: function(key, value) { root.applyFormat(key, value) }
          }
        }
      }
    }
  }
}
