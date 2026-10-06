pragma Singleton
import QtQuick
import Quickshell

// The bar's island: while one is up (the workspaces widget on a horizontal
// bar), notifications and the OSD show there instead of in their own
// windows, the island growing out of the workspaces to hold them.
//
// The notification service hands over its popup model; the island shows the
// newest popup and runs its countdown here, once for every bar, so a popup
// expires once however many screens show it. The OSD hands over each show.
Singleton {
  id: root

  // Islands on the bars count themselves in while they're up
  property int islands: 0
  readonly property bool active: islands > 0

  // ---------- Notifications ----------
  // Set by the notification service when it starts
  property var notifications: null
  readonly property var popups: notifications ? notifications.popupModel : null
  property int count: 0
  // The newest popup, copied out of the model as it changes
  property var current: null
  // Of its lifetime, how much is left; paused while the island is hovered
  property real remaining: 1
  property bool hovered: false
  readonly property real lifetime: current && notifications ? notifications.durationFor(current.urgency, current.expireTimeout) : 0

  function readCurrent() {
    count = popups ? popups.count : 0
    var row = count > 0 ? popups.get(0) : null
    var next = row ? {
      originalId: row.originalId, timestamp: row.timestamp, app: row.app, appIcon: row.appIcon,
      summary: row.summary, body: row.body, image: row.image, glyph: row.glyph,
      urgency: row.urgency, expireTimeout: row.expireTimeout
    } : null
    // A new popup, or new words in this one, gets a full look
    if (!next || !current || next.timestamp !== current.timestamp || next.summary !== current.summary || next.body !== current.body)
      remaining = 1
    current = next
  }

  function dismiss() {
    if (notifications && count > 0) notifications.dismissPopup(0)
  }

  function invoke() {
    if (notifications && count > 0) notifications.invokePopupDefault(0)
  }

  Connections {
    target: root.popups
    function onCountChanged() { root.readCurrent() }
    function onDataChanged() { root.readCurrent() }
  }
  onPopupsChanged: readCurrent()

  Timer {
    interval: 50
    repeat: true
    running: root.active && root.current !== null && root.lifetime > 0 && !root.hovered && !root.osdShown
    onTriggered: {
      root.remaining -= interval / root.lifetime
      if (root.remaining <= 0 && root.notifications && root.count > 0) {
        root.remaining = 1
        root.notifications.expirePopup(0)
      }
    }
  }

  // ---------- OSD ----------
  // { icon, message, value, maxValue, hasProgress }
  property var osd: null
  property bool osdShown: false

  function showOsd(state, duration) {
    osd = state
    osdShown = true
    osdTimer.interval = Math.max(300, duration || 1200)
    osdTimer.restart()
  }

  function hideOsd() {
    osdShown = false
  }

  Timer {
    id: osdTimer
    onTriggered: root.osdShown = false
  }

  // What the island shows: "osd", "notification" or "" (the workspaces)
  readonly property string mode: !active ? "" : osdShown ? "osd" : current ? "notification" : ""
}
