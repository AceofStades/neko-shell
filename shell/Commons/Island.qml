pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

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
  // Closing, the island shrinks back into the workspaces' capsule before the
  // center group comes back in its place; set while it does
  property bool settling: false
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
    running: root.active && root.current !== null && root.lifetime > 0 && !root.hovered && !root.osdShown && root.mode !== "media" && root.faceAuth === ""
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

  // ---------- Face unlock ----------
  // Howdy looking for a face (sudo, a polkit prompt, the lock screen): a
  // watcher asleep on its IR camera's opens and closes (it polls nothing)
  // says when it starts and how it went. "scanning", "approved", "failed" or
  // "" when there's nothing to show; without Howdy the watcher just exits.
  property string faceAuth: ""

  function faceAuthEvent(line) {
    var event = String(line || "").trim()
    if (event === "scanning") {
      faceAuthClear.stop()
      faceAuth = "scanning"
      faceAuthStale.restart()
    } else if (event === "approved" || event === "failed") {
      faceAuthStale.stop()
      faceAuth = event
      // Long enough for the check's pop or the shake and cross to play out
      faceAuthClear.interval = event === "approved" ? 1200 : 1700
      faceAuthClear.restart()
    } else if (event === "done") {
      faceAuthStale.stop()
      faceAuth = ""
    }
  }

  Process {
    running: true
    command: ["setpriv", "--pdeathsig", "TERM", "neko-faceauth-watch"]
    stdout: SplitParser { onRead: data => root.faceAuthEvent(data) }
  }

  Timer {
    id: faceAuthClear
    onTriggered: root.faceAuth = ""
  }

  // Howdy gives up long before this; a close the watcher missed can't leave
  // the face up for good
  Timer {
    id: faceAuthStale
    interval: 20000
    onTriggered: root.faceAuth = ""
  }

  // ---------- Media ----------
  // The player whose card shows while the pointer is on its icon in the bar
  // (the media players widget) or on the card itself; it closes a moment
  // after the pointer leaves both, so it can cross from one to the other
  property var mediaPlayer: null
  property bool mediaIconHovered: false
  readonly property bool mediaShown: mediaPlayer !== null && (mediaIconHovered || hovered || mediaCloseTimer.running)

  function showMedia(player) {
    mediaPlayer = player
    mediaIconHovered = true
    mediaCloseTimer.stop()
  }

  function leaveMediaIcon() {
    mediaIconHovered = false
    if (!hovered) mediaCloseTimer.restart()
  }

  Timer {
    id: mediaCloseTimer
    interval: 350
    onTriggered: if (!root.mediaIconHovered && !root.hovered) root.mediaPlayer = null
  }

  // ---------- Pomodoro ----------
  // The timer lives here rather than in the bar widget so every screen reads
  // one session and the island can render the same card from any bar.
  property string pomodoroPhase: "focus"
  property bool pomodoroActive: false
  property bool pomodoroRunning: false
  property int pomodoroRemaining: pomodoroDuration("focus")
  property real pomodoroTargetAt: 0
  property int pomodoroCompleted: 0
  property bool pomodoroLoaded: false
  property bool pomodoroIconHovered: false
  property bool pomodoroRequested: false
  readonly property bool pomodoroShown: pomodoroRequested && (pomodoroIconHovered || hovered || pomodoroCloseTimer.running)
  readonly property real pomodoroFraction: {
    var duration = pomodoroDuration(pomodoroPhase)
    return duration > 0 ? Math.max(0, Math.min(1, 1 - pomodoroRemaining / duration)) : 0
  }
  readonly property string pomodoroTitle: pomodoroPhase === "focus" ? "Focus"
    : pomodoroPhase === "longBreak" ? "Long break" : "Short break"

  function pomodoroDuration(phase) {
    return phase === "focus" ? 25 * 60 : phase === "longBreak" ? 15 * 60 : 5 * 60
  }

  function pomodoroClock(seconds) {
    var value = Math.max(0, Math.ceil(Number(seconds) || 0))
    var minutes = Math.floor(value / 60)
    var remainder = value % 60
    return minutes + ":" + (remainder < 10 ? "0" : "") + remainder
  }

  function persistPomodoro() {
    if (!pomodoroLoaded) return
    pomodoroStateFile.setText(JSON.stringify({
      version: 1,
      phase: pomodoroPhase,
      active: pomodoroActive,
      running: pomodoroRunning,
      remaining: pomodoroRemaining,
      targetAt: pomodoroTargetAt,
      completed: pomodoroCompleted
    }, null, 2) + "\n")
  }

  function loadPomodoro(raw) {
    if (pomodoroLoaded) return
    var state = null
    try { state = raw && String(raw).trim() ? JSON.parse(raw) : null } catch (e) {
      console.warn("pomodoro state parse failed:", e)
    }
    if (state && state.version === 1) {
      var phase = String(state.phase || "")
      pomodoroPhase = ["focus", "shortBreak", "longBreak"].indexOf(phase) >= 0 ? phase : "focus"
      pomodoroActive = state.active === true
      pomodoroRunning = pomodoroActive && state.running === true
      pomodoroRemaining = Math.max(0, Math.min(pomodoroDuration(pomodoroPhase), Math.round(Number(state.remaining) || 0)))
      pomodoroTargetAt = pomodoroRunning ? Number(state.targetAt) || 0 : 0
      pomodoroCompleted = Math.max(0, Math.round(Number(state.completed) || 0))
      if (!pomodoroActive) pomodoroRemaining = pomodoroDuration("focus")
    }
    pomodoroLoaded = true
    if (pomodoroRunning) syncPomodoro()
  }

  function startPomodoro() {
    if (!pomodoroLoaded) return
    if (!pomodoroActive) {
      pomodoroPhase = "focus"
      pomodoroRemaining = pomodoroDuration(pomodoroPhase)
      pomodoroActive = true
    }
    if (pomodoroRemaining <= 0) pomodoroRemaining = pomodoroDuration(pomodoroPhase)
    pomodoroRunning = true
    pomodoroTargetAt = Date.now() + pomodoroRemaining * 1000
    persistPomodoro()
  }

  function pausePomodoro() {
    if (!pomodoroActive || !pomodoroRunning) return
    syncPomodoro()
    pomodoroRunning = false
    pomodoroTargetAt = 0
    persistPomodoro()
  }

  function togglePomodoro() {
    if (pomodoroRunning) pausePomodoro()
    else startPomodoro()
  }

  function resetPomodoro() {
    pomodoroPhase = "focus"
    pomodoroActive = false
    pomodoroRunning = false
    pomodoroRemaining = pomodoroDuration(pomodoroPhase)
    pomodoroTargetAt = 0
    persistPomodoro()
  }

  function advancePomodoro(finished) {
    var oldPhase = pomodoroPhase
    if (oldPhase === "focus") {
      if (finished) pomodoroCompleted += 1
      pomodoroPhase = pomodoroCompleted > 0 && pomodoroCompleted % 4 === 0 ? "longBreak" : "shortBreak"
    } else {
      pomodoroPhase = "focus"
    }
    pomodoroActive = true
    pomodoroRemaining = pomodoroDuration(pomodoroPhase)
    // A completed phase flows into the next one; a manual skip preserves
    // whether the user had paused the clock.
    if (pomodoroRunning) pomodoroTargetAt = Date.now() + pomodoroRemaining * 1000
    else pomodoroTargetAt = 0
    persistPomodoro()
    if (finished) {
      var summary = oldPhase === "focus" ? "Focus complete" : "Break complete"
      var body = oldPhase === "focus" ? pomodoroTitle + " is ready" : "Time for another focus session"
      Quickshell.execDetached(["notify-send", "-a", "Neko Pomodoro", "-i", "alarm-symbolic", summary, body])
    }
  }

  function skipPomodoro() {
    if (!pomodoroActive) return
    advancePomodoro(false)
  }

  function syncPomodoro() {
    if (!pomodoroRunning) return
    pomodoroRemaining = Math.max(0, Math.ceil((pomodoroTargetAt - Date.now()) / 1000))
    if (pomodoroRemaining <= 0) advancePomodoro(true)
  }

  function showPomodoro() {
    pomodoroRequested = true
    pomodoroIconHovered = true
    pomodoroCloseTimer.stop()
  }

  function leavePomodoroIcon() {
    pomodoroIconHovered = false
    if (!hovered) pomodoroCloseTimer.restart()
  }

  onHoveredChanged: {
    if (!hovered && !mediaIconHovered && mediaPlayer) mediaCloseTimer.restart()
    if (!hovered && !pomodoroIconHovered && pomodoroRequested) pomodoroCloseTimer.restart()
  }

  FileView {
    id: pomodoroStateFile
    path: Quickshell.env("HOME") + "/.local/state/neko/pomodoro.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadPomodoro(text())
    onLoadFailed: root.loadPomodoro("")
  }

  Timer {
    interval: 250
    repeat: true
    running: root.pomodoroLoaded && root.pomodoroRunning
    onTriggered: root.syncPomodoro()
  }

  Timer {
    id: pomodoroCloseTimer
    interval: 350
    onTriggered: if (!root.pomodoroIconHovered && !root.hovered) root.pomodoroRequested = false
  }

  ShellIpc {
    target: "pomodoro"

    function status(): string {
      return JSON.stringify({
        active: root.pomodoroActive,
        running: root.pomodoroRunning,
        phase: root.pomodoroPhase,
        remaining: root.pomodoroRemaining,
        completed: root.pomodoroCompleted
      })
    }

    function start(): string {
      root.startPomodoro()
      return "ok"
    }

    function pause(): string {
      root.pausePomodoro()
      return "ok"
    }

    function toggle(): string {
      root.togglePomodoro()
      return "ok"
    }

    function reset(): string {
      root.resetPomodoro()
      return "ok"
    }

    function skip(): string {
      root.skipPomodoro()
      return "ok"
    }

    function show(): string {
      root.pomodoroRequested = true
      root.pomodoroIconHovered = true
      pomodoroCloseTimer.stop()
      return "ok"
    }

    function hide(): string {
      root.pomodoroIconHovered = false
      root.pomodoroRequested = false
      pomodoroCloseTimer.stop()
      return "ok"
    }
  }

  Component.onCompleted: Qt.callLater(function() { pomodoroStateFile.reload() })

  // What the island shows: "faceauth", "osd", "pomodoro", "media",
  // "notification" or "" (the workspaces). Face unlock, asking for you,
  // outranks all; a passing OSD outranks the card the pointer asked for,
  // which outranks a notification.
  readonly property string mode: !active ? "" : faceAuth !== "" ? "faceauth" : osdShown ? "osd" : pomodoroShown ? "pomodoro" : mediaShown ? "media" : current ? "notification" : ""
}
