import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The clock's timers, alarms and stopwatch, on the control center's calendar
// card, whose tabs pick `tab`. neko-clock keeps and rings them (as its own
// systemd units, so they ring with the shell down); this reads its state
// file and asks it for every change. The countdowns here only draw: nothing
// on this page has to be on time.
ColumnLayout {
  id: root

  property color foreground: NekoColor.popups.text
  property color dim: Util.alpha(foreground, 0.6)
  property color accent: NekoColor.accent
  property string fontFamily: Style.font.family
  // Whether it's on show, so the countdowns only tick while they're seen
  property bool shown: false

  property string tab: "timers"
  onTabChanged: problem = ""
  property var state: ({ timers: [], alarms: [], stopwatch: { running: false, startedAt: 0, accumulatedMs: 0, laps: [] }, ringing: [] })
  property double now: Date.now()
  // What neko-clock said about the last thing typed, when it couldn't read it
  property string problem: ""
  // Weekdays picked for a new alarm, Sunday being 0
  property var alarmDays: []

  readonly property var weekdays: ["S", "M", "T", "W", "T", "F", "S"]
  readonly property color soft: Util.alpha(foreground, 0.06)
  readonly property color softer: Util.alpha(foreground, 0.1)

  spacing: Style.space(10)

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
    return days.map(function(day) { return names[day] }).join(" ")
  }

  function ringingLabel(event) {
    var what = event.kind === "timer" ? "Timer done" : "Alarm"
    return event.label ? what + ": " + event.label : what
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
      timerAdd.text = ""
      alarmAdd.text = ""
      root.alarmDays = []
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

  // What's ringing, to quiet it or bring it back in five minutes
  Rectangle {
    Layout.fillWidth: true
    visible: root.state.ringing.length > 0
    implicitHeight: Style.space(44)
    radius: height / 2
    color: Util.alpha(root.accent, 0.18)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(14)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(6)
      Text {
        text: "󰂞"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
      Text {
        Layout.fillWidth: true
        text: root.state.ringing.length > 0 ? root.ringingLabel(root.state.ringing[0]) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }
      Chip { text: "Snooze"; onClicked: root.clock(["snooze"]) }
      Chip { text: "Stop"; strong: true; onClicked: root.clock(["dismiss"]) }
    }
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

    AddField {
      id: timerAdd
      icon: "󰔟"
      placeholder: "25 focus, 1h 30m, 90s"
      onSubmitted: function(value) { root.problem = ""; root.clock(["timer-add", value]) }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      Repeater {
        model: [{ label: "1m", value: "1" }, { label: "5m", value: "5" }, { label: "10m", value: "10" }, { label: "25m", value: "25" }, { label: "1h", value: "60" }]
        Chip {
          required property var modelData
          Layout.fillWidth: true
          text: modelData.label
          onClicked: root.clock(["timer-add", modelData.value])
        }
      }
    }

    Empty {
      visible: root.state.timers.length === 0
      icon: "󰔟"
      title: "No timers"
      hint: "Type a length, a name after it if you like"
    }

    Repeater {
      model: root.state.timers
      Rectangle {
        id: timerRow
        required property var modelData
        readonly property bool done: modelData.state === "done"
        readonly property bool running: modelData.state === "running"
        Layout.fillWidth: true
        implicitHeight: Style.space(56)
        radius: Style.space(16)
        color: root.soft

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(6)
          spacing: Style.space(10)

          Ring {
            size: Style.space(36)
            fraction: timerRow.modelData.durationMs > 0 ? root.remaining(timerRow.modelData) / timerRow.modelData.durationMs : 0
            live: timerRow.running
            Text {
              anchors.centerIn: parent
              text: timerRow.done ? "󰄬" : "󰔟"
              color: timerRow.running ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: timerRow.done ? "Done" : root.countdown(root.remaining(timerRow.modelData))
              color: timerRow.running ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              font.features: { "tnum": 1 }
            }
            Text {
              Layout.fillWidth: true
              text: (timerRow.modelData.label || "Timer") + " · " + root.countdown(timerRow.modelData.durationMs)
                + (timerRow.modelData.state === "paused" ? " · paused" : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            visible: !timerRow.done
            iconText: timerRow.running ? "󰏤" : "󰐊"
            tooltipText: timerRow.running ? "Pause" : "Resume"
            foreground: root.foreground
            onClicked: root.clock([timerRow.running ? "timer-pause" : "timer-resume", timerRow.modelData.id])
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
            foreground: root.dim
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

    AddField {
      id: alarmAdd
      icon: "󰀠"
      placeholder: "7:30 work, 7pm"
      onSubmitted: function(value) {
        root.problem = ""
        root.clock(["alarm-add", value, root.alarmDays.slice().sort().join(",")])
      }
    }

    // The days a new alarm repeats on; none rings once
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      Repeater {
        model: 7
        Rectangle {
          id: day
          required property int index
          readonly property bool picked: root.alarmDays.indexOf(index) >= 0
          Layout.fillWidth: true
          implicitHeight: Style.space(28)
          radius: height / 2
          color: picked ? root.accent : dayMouse.containsMouse ? root.softer : root.soft
          Behavior on color { ColorAnimation { duration: Style.duration(120) } }
          Text {
            anchors.centerIn: parent
            text: root.weekdays[day.index]
            color: day.picked ? NekoColor.popups.background : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.weight: Font.DemiBold
          }
          MouseArea {
            id: dayMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleDay(day.index)
          }
        }
      }
    }
    Text {
      Layout.fillWidth: true
      Layout.topMargin: -Style.space(4)
      text: root.alarmDays.length === 0 ? "Rings once · pick days to repeat" : "Repeats " + root.daysLabel(root.alarmDays.slice().sort()).toLowerCase()
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
    }

    Empty {
      visible: root.state.alarms.length === 0
      icon: "󰀠"
      title: "No alarms"
      hint: "Type a time, a name after it if you like"
    }

    Repeater {
      model: root.state.alarms
      Rectangle {
        id: alarmRow
        required property var modelData
        Layout.fillWidth: true
        implicitHeight: Style.space(56)
        radius: Style.space(16)
        color: root.soft

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(6)
          spacing: Style.space(10)
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: Qt.formatTime(new Date(2000, 0, 1, alarmRow.modelData.hour, alarmRow.modelData.minute), "HH:mm")
              color: alarmRow.modelData.enabled ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
              font.features: { "tnum": 1 }
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
            foreground: root.dim
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
    spacing: Style.space(10)

    // A ring that sweeps once a minute, the time inside it
    Ring {
      Layout.alignment: Qt.AlignHCenter
      size: Style.space(118)
      stroke: Style.spaceReal(4)
      fraction: (root.elapsed() % 60000) / 60000
      live: root.state.stopwatch.running

      Row {
        anchors.centerIn: parent
        Text {
          id: watchWhole
          text: root.formatSeconds(Math.floor(root.elapsed() / 1000))
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Math.round(Style.font.display * 1.1)
          font.weight: Font.DemiBold
          font.features: { "tnum": 1 }
        }
        Text {
          anchors.baseline: watchWhole.baseline
          text: "." + Math.floor(root.elapsed() / 100) % 10
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.weight: Font.DemiBold
          font.features: { "tnum": 1 }
        }
      }
    }

    Row {
      Layout.alignment: Qt.AlignHCenter
      spacing: Style.space(18)
      RoundButton {
        anchors.verticalCenter: parent.verticalCenter
        icon: "󰑐"
        enabled: root.elapsed() > 0
        onClicked: root.clock(["stopwatch-reset"])
      }
      RoundButton {
        anchors.verticalCenter: parent.verticalCenter
        icon: root.state.stopwatch.running ? "󰏤" : "󰐊"
        main: true
        onClicked: root.clock(["stopwatch-toggle"])
      }
      RoundButton {
        anchors.verticalCenter: parent.verticalCenter
        icon: "󰌖"
        enabled: root.state.stopwatch.running
        onClicked: root.clock(["stopwatch-lap"])
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
        Layout.leftMargin: Style.space(6)
        Layout.rightMargin: Style.space(6)
        Text {
          Layout.fillWidth: true
          text: "Lap " + modelData.number
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          text: root.formatSeconds(Math.floor(modelData.split / 1000)) + "." + Math.floor(modelData.split / 100) % 10
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.features: { "tnum": 1 }
        }
        Text {
          text: root.formatSeconds(Math.floor(modelData.total / 1000))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.features: { "tnum": 1 }
          Layout.preferredWidth: Style.space(56)
          horizontalAlignment: Text.AlignRight
        }
      }
    }
  }

  // ------------------------------------------------------------ parts

  // One rounded field for a whole entry: what it is, and a name after it
  component AddField: Rectangle {
    id: field
    property string icon: ""
    property string placeholder: ""
    property alias text: input.text
    signal submitted(string value)

    function submit() {
      var value = input.text.trim()
      if (value) field.submitted(value)
    }

    Layout.fillWidth: true
    implicitHeight: Style.space(40)
    radius: height / 2
    color: root.soft
    border.width: 1
    border.color: input.activeFocus ? Util.alpha(root.accent, 0.7) : Util.alpha(root.foreground, 0.08)
    Behavior on border.color { ColorAnimation { duration: Style.duration(120) } }

    Text {
      id: fieldIcon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(14)
      anchors.verticalCenter: parent.verticalCenter
      text: field.icon
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }
    TextInput {
      id: input
      anchors.left: fieldIcon.right
      anchors.right: addButton.left
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      color: root.foreground
      selectionColor: Util.alpha(root.accent, 0.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      clip: true
      onAccepted: field.submit()
      Text {
        anchors.fill: parent
        visible: !input.text
        text: field.placeholder
        color: Util.alpha(root.foreground, 0.4)
        font: input.font
        elide: Text.ElideRight
      }
    }
    MouseArea {
      anchors.fill: parent
      anchors.rightMargin: addButton.width + Style.space(5)
      cursorShape: Qt.IBeamCursor
      onPressed: function(mouse) { input.forceActiveFocus(); mouse.accepted = false }
    }
    Rectangle {
      id: addButton
      anchors.right: parent.right
      anchors.rightMargin: Style.space(5)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(30)
      height: width
      radius: width / 2
      color: input.text.trim() ? root.accent : root.softer
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
      Text {
        anchors.centerIn: parent
        text: "󰐕"
        color: input.text.trim() ? NekoColor.popups.background : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: field.submit()
      }
    }
  }

  // A soft pill to press
  component Chip: Rectangle {
    id: chip
    property string text: ""
    property bool strong: false
    signal clicked()
    implicitWidth: chipText.implicitWidth + Style.space(24)
    implicitHeight: Style.space(30)
    radius: height / 2
    color: strong ? root.accent : chipMouse.containsMouse ? root.softer : root.soft
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.text
      color: chip.strong ? NekoColor.popups.background : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.weight: Font.DemiBold
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  // A round control; the main one filled with the accent
  component RoundButton: Rectangle {
    id: roundButton
    property string icon: ""
    property bool main: false
    signal clicked()
    width: main ? Style.space(52) : Style.space(40)
    height: width
    radius: width / 2
    opacity: enabled ? 1 : 0.4
    color: main ? root.accent : roundMouse.containsMouse ? root.softer : root.soft
    Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    Text {
      anchors.centerIn: parent
      text: roundButton.icon
      color: roundButton.main ? NekoColor.popups.background : root.foreground
      font.family: root.fontFamily
      font.pixelSize: roundButton.main ? Style.font.iconLarge : Style.font.icon
    }
    MouseArea {
      id: roundMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: roundButton.clicked()
    }
  }

  // A progress ring from twelve o'clock; what it holds sits in its middle
  component Ring: Item {
    id: ring
    property real size: Style.space(36)
    property real stroke: Style.spaceReal(2.5)
    property real fraction: 0
    property bool live: false
    implicitWidth: size
    implicitHeight: size
    Layout.preferredWidth: size
    Layout.preferredHeight: size

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeWidth: ring.stroke
        strokeColor: root.softer
        fillColor: "transparent"
        PathAngleArc {
          centerX: ring.size / 2
          centerY: ring.size / 2
          radiusX: ring.size / 2 - ring.stroke
          radiusY: ring.size / 2 - ring.stroke
          startAngle: 0
          sweepAngle: 360
        }
      }
      ShapePath {
        strokeWidth: ring.stroke
        strokeColor: ring.fraction > 0.001 ? (ring.live ? root.accent : root.dim) : "transparent"
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.size / 2
          centerY: ring.size / 2
          radiusX: ring.size / 2 - ring.stroke
          radiusY: ring.size / 2 - ring.stroke
          startAngle: -90
          sweepAngle: 360 * Math.max(0, Math.min(1, ring.fraction))
        }
      }
    }
  }

  // What a tab says while it's empty
  component Empty: ColumnLayout {
    id: empty
    property string icon: ""
    property string title: ""
    property string hint: ""
    Layout.fillWidth: true
    Layout.topMargin: Style.space(14)
    spacing: Style.space(4)
    Text {
      Layout.alignment: Qt.AlignHCenter
      text: empty.icon
      color: Util.alpha(root.foreground, 0.3)
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.font.display * 1.2)
    }
    Text {
      Layout.alignment: Qt.AlignHCenter
      text: empty.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
    }
    Text {
      Layout.alignment: Qt.AlignHCenter
      text: empty.hint
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
