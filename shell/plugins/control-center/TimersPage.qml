import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The control center's timers page: timers, alarms and the stopwatch. neko-clock
// keeps them and rings them (as its own systemd units, so they ring with the
// shell down); this page reads its state file and asks it for every change.
// The countdowns here only draw: nothing on this page has to be on time.
ColumnLayout {
  id: root

  property color foreground: NekoColor.popups.text
  property color dim: Util.alpha(foreground, 0.6)
  property color accent: NekoColor.accent
  property string fontFamily: Style.font.family
  // Whether the page is up, so the countdowns only tick while they're seen
  property bool shown: false
  signal back()

  property string tab: "timers"
  property var state: ({ timers: [], alarms: [], stopwatch: { running: false, startedAt: 0, accumulatedMs: 0, laps: [] }, ringing: [] })
  property double now: Date.now()
  // What neko-clock said about the last thing typed, when it couldn't read it
  property string problem: ""
  // Weekdays picked for a new alarm, Sunday being 0
  property var alarmDays: []

  readonly property var weekdays: ["S", "M", "T", "W", "T", "F", "S"]
  // For the control center's tile: what's going on, without a ticking clock
  readonly property int runningTimers: state.timers.filter(function(t) { return t.state === "running" }).length
  readonly property int alarmsOn: state.alarms.filter(function(a) { return a.enabled }).length
  readonly property bool busy: runningTimers > 0 || state.stopwatch.running || state.ringing.length > 0
  readonly property string summary: {
    if (state.ringing.length > 0) return "Ringing"
    var parts = []
    if (runningTimers > 0) parts.push(runningTimers === 1 ? "1 timer" : runningTimers + " timers")
    if (state.stopwatch.running) parts.push("stopwatch")
    if (alarmsOn > 0) parts.push(alarmsOn === 1 ? "1 alarm" : alarmsOn + " alarms")
    return parts.length > 0 ? parts.join(" · ") : "Timers, alarms, stopwatch"
  }

  spacing: Style.space(12)

  function clock(args) {
    clockProc.command = ["neko-clock"].concat(args)
    clockProc.running = true
  }

  function pad2(value) {
    return (value < 10 ? "0" : "") + value
  }

  function formatSeconds(total) {
    var hours = Math.floor(total / 3600), minutes = Math.floor(total / 60) % 60, seconds = total % 60
    return hours > 0 ? hours + ":" + pad2(minutes) + ":" + pad2(seconds) : minutes + ":" + pad2(seconds)
  }

  // Rounded up, so a timer reads 5:00 as it starts and 0:00 only when done
  function countdown(ms) {
    return formatSeconds(Math.ceil(Math.max(0, ms) / 1000))
  }

  function stopwatchText(ms) {
    return formatSeconds(Math.floor(Math.max(0, ms) / 1000)) + "." + Math.floor(Math.max(0, ms) / 100) % 10
  }

  function remaining(timer) {
    if (timer.state === "running") return Math.max(0, timer.endsAt - root.now)
    if (timer.state === "paused") return timer.remainingMs
    return 0
  }

  function elapsed() {
    var watch = root.state.stopwatch
    return watch.accumulatedMs + (watch.running ? Math.max(0, root.now - watch.startedAt) : 0)
  }

  function daysLabel(days) {
    var joined = (days || []).slice().sort().join("")
    if (joined === "") return "Once"
    if (joined === "0123456") return "Every day"
    if (joined === "12345") return "Weekdays"
    if (joined === "06") return "Weekends"
    var names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    return days.map(function(day) { return names[day] }).join(", ")
  }

  function ringingLabel(event) {
    var what = event.kind === "timer" ? "Timer done" : "Alarm"
    return event.label ? what + ": " + event.label : what
  }

  function addTimer(duration) {
    var text = String(duration || "").trim()
    if (!text) return
    root.problem = ""
    root.clock(["timer-add", text].concat(labelField.text.trim() ? [labelField.text.trim()] : []))
  }

  function addAlarm() {
    var text = alarmField.text.trim()
    if (!text) return
    root.problem = ""
    var days = root.alarmDays.slice().sort().join(",")
    root.clock(["alarm-add", text, days].concat(alarmLabelField.text.trim() ? [alarmLabelField.text.trim()] : []))
  }

  function toggleDay(day) {
    var next = root.alarmDays.slice()
    var at = next.indexOf(day)
    if (at < 0) next.push(day)
    else next.splice(at, 1)
    root.alarmDays = next
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/neko/clock.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try { root.state = JSON.parse(text()) } catch (error) {}
    }
  }

  Process {
    id: clockProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var said = String(text || "").trim().replace(/^neko-core clock: /, "")
        if (!said) return
        root.problem = said.charAt(0).toUpperCase() + said.slice(1)
      }
    }
    onExited: function(code) {
      if (code !== 0) return
      // Taken: clear what was typed
      if (root.tab === "timers") { durationField.text = ""; labelField.text = "" }
      if (root.tab === "alarms") { alarmField.text = ""; alarmLabelField.text = ""; root.alarmDays = [] }
    }
  }

  // Only while seen, and finer while the stopwatch's tenths are on show
  Timer {
    interval: root.tab === "stopwatch" && root.state.stopwatch.running ? 100 : 500
    repeat: true
    running: root.shown
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(6)
    PanelActionButton {
      iconText: "󰅁"
      tooltipText: "Back"
      foreground: root.foreground
      onClicked: root.back()
    }
    Text {
      Layout.fillWidth: true
      text: "Timers"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.weight: Font.DemiBold
    }
  }

  // What's ringing, to quiet it or bring it back in five minutes
  Rectangle {
    Layout.fillWidth: true
    visible: root.state.ringing.length > 0
    implicitHeight: ringingRow.implicitHeight + Style.space(20)
    radius: Style.space(14)
    color: Util.alpha(root.accent, 0.16)
    border.width: 1
    border.color: Util.alpha(root.accent, 0.5)

    RowLayout {
      id: ringingRow
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(8)
      Text {
        text: "󰂞"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
      }
      Text {
        Layout.fillWidth: true
        text: root.state.ringing.length > 0 ? root.ringingLabel(root.state.ringing[0]) + (root.state.ringing.length > 1 ? " and " + (root.state.ringing.length - 1) + " more" : "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Button {
        text: "Snooze 5 min"
        bordered: true
        foreground: root.foreground
        onClicked: root.clock(["snooze"])
      }
      Button {
        text: "Dismiss"
        bordered: true
        foreground: root.foreground
        onClicked: root.clock(["dismiss"])
      }
    }
  }

  ButtonGroup {
    Layout.fillWidth: true
    fontSize: Style.font.bodySmall
    options: [
      { value: "timers", label: "Timers", icon: "󰔟" },
      { value: "alarms", label: "Alarms", icon: "󰀠" },
      { value: "stopwatch", label: "Stopwatch", icon: "󱎫" }
    ]
    value: root.tab
    onChanged: function(v) { root.tab = v; root.problem = "" }
  }

  Text {
    Layout.fillWidth: true
    visible: root.problem !== ""
    text: root.problem
    color: NekoColor.urgent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }

  // ------------------------------------------------------------ timers

  ColumnLayout {
    Layout.fillWidth: true
    visible: root.tab === "timers"
    spacing: Style.space(10)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      TextField {
        id: durationField
        Layout.fillWidth: true
        Layout.preferredWidth: 2
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        placeholderText: "5, 1:30 or 1h 30m"
        onAccepted: root.addTimer(text)
      }
      TextField {
        id: labelField
        Layout.fillWidth: true
        Layout.preferredWidth: 2
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        placeholderText: "Label (optional)"
        onAccepted: root.addTimer(durationField.text)
      }
      Button {
        iconText: "󰐕"
        text: "Start"
        bordered: true
        foreground: root.foreground
        onClicked: root.addTimer(durationField.text)
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      Repeater {
        model: [{ label: "1 min", value: "1" }, { label: "5 min", value: "5" }, { label: "10 min", value: "10" }, { label: "25 min", value: "25" }, { label: "1 hour", value: "60" }]
        Button {
          required property var modelData
          Layout.fillWidth: true
          text: modelData.label
          fontSize: Style.font.bodySmall
          bordered: true
          foreground: root.foreground
          onClicked: root.addTimer(modelData.value)
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: root.state.timers.length === 0
      Layout.topMargin: Style.space(12)
      text: "No timers. Type a length or pick one above."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }

    Repeater {
      model: root.state.timers
      Rectangle {
        id: timerRow
        required property var modelData
        readonly property bool done: modelData.state === "done"
        readonly property real progress: modelData.durationMs > 0 ? root.remaining(modelData) / modelData.durationMs : 0
        Layout.fillWidth: true
        implicitHeight: Style.space(64)
        radius: Style.space(14)
        color: Util.alpha(root.foreground, 0.06)

        // How much is left, as a fill along the row's foot
        Rectangle {
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(14)
          anchors.bottomMargin: Style.space(8)
          width: (parent.width - Style.space(28)) * timerRow.progress
          height: Style.space(3)
          radius: height / 2
          color: timerRow.modelData.state === "running" ? root.accent : root.dim
          visible: !timerRow.done
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(8)
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: timerRow.done ? "Done" : root.countdown(root.remaining(timerRow.modelData))
              color: timerRow.done ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
              Layout.fillWidth: true
              text: (timerRow.modelData.label ? timerRow.modelData.label + " · " : "") + root.countdown(timerRow.modelData.durationMs)
                + (timerRow.modelData.state === "paused" ? " · paused" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
          PanelActionButton {
            visible: !timerRow.done
            iconText: timerRow.modelData.state === "running" ? "󰏤" : "󰐊"
            tooltipText: timerRow.modelData.state === "running" ? "Pause" : "Resume"
            foreground: root.foreground
            onClicked: root.clock([timerRow.modelData.state === "running" ? "timer-pause" : "timer-resume", timerRow.modelData.id])
          }
          PanelActionButton {
            iconText: "󰑐"
            tooltipText: timerRow.done ? "Run again" : "Restart"
            foreground: root.foreground
            onClicked: root.clock(["timer-restart", timerRow.modelData.id])
          }
          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Remove"
            foreground: root.foreground
            onClicked: root.clock(["timer-remove", timerRow.modelData.id])
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ alarms

  ColumnLayout {
    Layout.fillWidth: true
    visible: root.tab === "alarms"
    spacing: Style.space(10)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      TextField {
        id: alarmField
        Layout.fillWidth: true
        Layout.preferredWidth: 2
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        placeholderText: "7:30, 19:30 or 7pm"
        onAccepted: root.addAlarm()
      }
      TextField {
        id: alarmLabelField
        Layout.fillWidth: true
        Layout.preferredWidth: 2
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        placeholderText: "Label (optional)"
        onAccepted: root.addAlarm()
      }
      Button {
        iconText: "󰐕"
        text: "Add"
        bordered: true
        foreground: root.foreground
        onClicked: root.addAlarm()
      }
    }

    // The days it repeats on; none rings once
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      Text {
        text: root.alarmDays.length === 0 ? "Once" : "Repeats"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.preferredWidth: Style.space(58)
      }
      Repeater {
        model: 7
        Button {
          required property int index
          Layout.fillWidth: true
          text: root.weekdays[index]
          fontSize: Style.font.bodySmall
          bordered: true
          selected: root.alarmDays.indexOf(index) >= 0
          foreground: root.foreground
          onClicked: root.toggleDay(index)
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: root.state.alarms.length === 0
      Layout.topMargin: Style.space(12)
      text: "No alarms. Type a time to add one."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignHCenter
    }

    Repeater {
      model: root.state.alarms
      Rectangle {
        id: alarmRow
        required property var modelData
        Layout.fillWidth: true
        implicitHeight: Style.space(60)
        radius: Style.space(14)
        color: Util.alpha(root.foreground, 0.06)
        opacity: modelData.enabled ? 1 : 0.6

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(8)
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: Qt.formatTime(new Date(2000, 0, 1, alarmRow.modelData.hour, alarmRow.modelData.minute), "HH:mm")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
              Layout.fillWidth: true
              text: (alarmRow.modelData.label ? alarmRow.modelData.label + " · " : "") + root.daysLabel(alarmRow.modelData.days)
                + (alarmRow.modelData.snoozed ? " · snoozed" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
          ToggleSwitch {
            checked: alarmRow.modelData.enabled
            foreground: root.foreground
            accent: root.accent
            onToggled: root.clock([alarmRow.modelData.enabled ? "alarm-disable" : "alarm-enable", alarmRow.modelData.id])
          }
          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Remove"
            foreground: root.foreground
            onClicked: root.clock(["alarm-remove", alarmRow.modelData.id])
          }
        }
      }
    }
  }

  // --------------------------------------------------------- stopwatch

  ColumnLayout {
    Layout.fillWidth: true
    visible: root.tab === "stopwatch"
    spacing: Style.space(12)

    Text {
      Layout.fillWidth: true
      Layout.topMargin: Style.space(8)
      text: root.stopwatchText(root.elapsed())
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.font.display * 1.6)
      font.weight: Font.DemiBold
      horizontalAlignment: Text.AlignHCenter
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      Button {
        Layout.fillWidth: true
        iconText: root.state.stopwatch.running ? "󰏤" : "󰐊"
        text: root.state.stopwatch.running ? "Pause" : (root.elapsed() > 0 ? "Resume" : "Start")
        bordered: true
        foreground: root.foreground
        onClicked: root.clock(["stopwatch-toggle"])
      }
      Button {
        Layout.fillWidth: true
        iconText: "󰌖"
        text: "Lap"
        bordered: true
        enabled: root.state.stopwatch.running
        foreground: root.foreground
        onClicked: root.clock(["stopwatch-lap"])
      }
      Button {
        Layout.fillWidth: true
        iconText: "󰑐"
        text: "Reset"
        bordered: true
        enabled: root.elapsed() > 0
        foreground: root.foreground
        onClicked: root.clock(["stopwatch-reset"])
      }
    }

    // Newest first: each lap's own time, and the total when it was taken
    Repeater {
      model: {
        var laps = root.state.stopwatch.laps || [], rows = []
        for (var i = laps.length - 1; i >= 0; i--) rows.push({ number: i + 1, split: laps[i] - (i > 0 ? laps[i - 1] : 0), total: laps[i] })
        return rows
      }
      RowLayout {
        required property var modelData
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(14)
        Layout.rightMargin: Style.space(14)
        Text {
          Layout.fillWidth: true
          text: "Lap " + modelData.number
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          text: root.stopwatchText(modelData.split)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          Layout.preferredWidth: Style.space(90)
          horizontalAlignment: Text.AlignRight
        }
        Text {
          text: root.stopwatchText(modelData.total)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          Layout.preferredWidth: Style.space(90)
          horizontalAlignment: Text.AlignRight
        }
      }
    }
  }
}
