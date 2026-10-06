import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// CPU use, CPU temperature and memory, each an icon beside a thin gauge that
// fills from the bottom: the accent color, turning toward the urgent color
// past a warning level and to it past a critical one. The tooltip has the
// figures; a click opens btop. Read from /proc and the CPU's temperature
// sensor every two seconds, without starting a process.
BarWidget {
  id: root
  moduleName: "neko.system-monitor"

  // Percent, degrees and percent
  property real cpu: 0
  property real temperature: 0
  property real memoryUsed: 0
  property real memoryTotal: 0
  readonly property real memory: memoryTotal > 0 ? memoryUsed / memoryTotal * 100 : 0

  // The last /proc/stat totals, to take the use since then
  property var lastCpu: null
  // From neko-system-stats, which finds the CPU's package sensor
  property string temperatureFile: ""

  readonly property color accent: NekoColor.accent
  readonly property color urgent: NekoColor.urgent
  readonly property real gaugeHeight: Math.round(Style.font.body * 1.05)

  function levelColor(value, warning, critical) {
    if (value >= critical) return urgent
    if (value >= warning) return Qt.tint(accent, Util.alpha(urgent, 0.55))
    return accent
  }

  function gib(kib) {
    return (kib / 1024 / 1024).toFixed(1)
  }

  function readCpu(text) {
    var fields = String(text).split("\n")[0].trim().split(/\s+/).slice(1).map(Number)
    if (fields.length < 4) return
    var idle = fields[3] + (fields[4] || 0)
    var total = fields.reduce(function(sum, n) { return sum + n }, 0)
    if (lastCpu && total > lastCpu.total) cpu = 100 * (1 - (idle - lastCpu.idle) / (total - lastCpu.total))
    lastCpu = { idle: idle, total: total }
  }

  function readMemory(text) {
    var total = /MemTotal:\s+(\d+)/.exec(text)
    var available = /MemAvailable:\s+(\d+)/.exec(text)
    if (!total || !available) return
    memoryTotal = Number(total[1])
    memoryUsed = memoryTotal - Number(available[1])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: statFile
    path: "/proc/stat"
    onLoaded: root.readCpu(text())
  }
  FileView {
    id: memoryFile
    path: "/proc/meminfo"
    onLoaded: root.readMemory(text())
  }
  FileView {
    id: temperatureReader
    path: root.temperatureFile
    onLoaded: root.temperature = Number(String(text()).trim()) / 1000 || 0
  }

  Process {
    running: true
    command: ["neko-system-stats", "--cpu-temperature-file"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.temperatureFile = String(text || "").trim()
    }
  }

  Timer {
    interval: 2000
    running: root.visible
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      statFile.reload()
      memoryFile.reload()
      if (root.temperatureFile) temperatureReader.reload()
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    fixedWidth: stats.implicitWidth + Style.space(16)
    tooltipText: "CPU " + Math.round(root.cpu) + "%, " + Math.round(root.temperature) + "°C\n"
      + "Memory " + root.gib(root.memoryUsed) + " of " + root.gib(root.memoryTotal) + " GiB (" + Math.round(root.memory) + "%)"
    onPressed: root.bar.run("neko-launch-tui btop")

    Row {
      id: stats
      anchors.centerIn: parent
      spacing: Style.space(10)

      Stat { icon: "󰻠"; value: root.cpu / 100; tint: root.levelColor(root.cpu, 80, 90) }
      Stat { icon: "󰔏"; value: root.temperature / 100; tint: root.levelColor(root.temperature, 70, 80) }
      Stat { icon: "󰍛"; value: root.memory / 100; tint: root.levelColor(root.memory, 80, 90) }
    }
  }

  component Stat: Row {
    property string icon: ""
    property real value: 0
    property color tint: root.accent

    spacing: Style.space(3)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: parent.icon
      color: parent.tint === root.accent ? button.foreground : parent.tint
      font.family: button.fontFamily
      font.pixelSize: Style.font.body
    }

    // The gauge: a track, filled from the bottom
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(3, Style.space(4))
      height: root.gaugeHeight
      radius: width / 2
      color: Util.alpha(button.foreground, 0.2)

      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: Math.max(parent.width, parent.height * Math.max(0, Math.min(1, parent.parent.value)))
        radius: width / 2
        color: parent.parent.tint
        Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
      }
    }
  }
}
