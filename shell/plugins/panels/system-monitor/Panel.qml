import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// System monitor: on the bar, CPU use, CPU temperature and memory as rings
// filling clockwise around their icons, read from /proc and the CPU's sensor
// every two seconds without starting a process. A click opens the details:
// every core, the temperatures, memory and swap, disks, network, power and
// the busiest processes, from neko-system-stats --details while it's open.
Panel {
  id: root
  moduleName: "neko.system-monitor"
  ipcTarget: "neko.system-monitor"
  manageIpc: false

  readonly property color foreground: NekoColor.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color accent: NekoColor.accent
  readonly property color urgent: NekoColor.urgent
  readonly property string fontFamily: Style.font.family

  // ---------- The bar's figures ----------
  property real cpu: 0
  property real temperature: 0
  property real memoryUsed: 0
  property real memoryTotal: 0
  readonly property real memory: memoryTotal > 0 ? memoryUsed / memoryTotal * 100 : 0
  property var lastCpu: null
  property string temperatureFile: ""

  // ---------- The panel's details ----------
  property var details: null
  property var previous: null
  // Per core use in percent, and network bytes a second, from two reads
  property var coreUse: []
  property real receiving: 0
  property real sending: 0

  function levelColor(value, warning, critical) {
    if (value >= critical) return urgent
    if (value >= warning) return Qt.tint(accent, Util.alpha(urgent, 0.55))
    return accent
  }

  function gib(kib) {
    return (kib / 1024 / 1024).toFixed(1)
  }

  function bytes(n) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
    return (i === 0 ? Math.round(n) : n.toFixed(n < 10 ? 1 : 0)) + " " + units[i]
  }

  function duration(seconds) {
    var days = Math.floor(seconds / 86400)
    var hours = Math.floor(seconds % 86400 / 3600)
    var minutes = Math.floor(seconds % 3600 / 60)
    return (days > 0 ? days + "d " : "") + (days > 0 || hours > 0 ? hours + "h " : "") + minutes + "m"
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

  function readDetails(text) {
    var next
    try { next = JSON.parse(String(text || "")) } catch (e) { return }
    if (!next || !next.cpus) return
    if (previous) {
      var use = []
      for (var i = 1; i < next.cpus.length && i < previous.cpus.length; i++) {
        var idle = next.cpus[i][0] - previous.cpus[i][0]
        var total = next.cpus[i][1] - previous.cpus[i][1]
        use.push(total > 0 ? Math.max(0, Math.min(100, 100 * (1 - idle / total))) : 0)
      }
      coreUse = use
      var seconds = (next.time - previous.time) / 1000
      if (seconds > 0) {
        receiving = Math.max(0, (next.network.rx - previous.network.rx) / seconds)
        sending = Math.max(0, (next.network.tx - previous.network.tx) / seconds)
      }
    }
    previous = next
    details = next
  }

  // Temperatures by what they belong to, hottest core in place of each core
  readonly property var temperatures: {
    if (!details) return []
    var names = { coretemp: "CPU", k10temp: "CPU", zenpower: "CPU", nvme: "SSD", iwlwifi_1: "Wi-Fi", iwlwifi: "Wi-Fi", acpitz: "Board", amdgpu: "GPU", pch_cannonlake: "Chipset" }
    var list = [], cores = []
    for (var i = 0; i < details.temps.length; i++) {
      var t = details.temps[i]
      if (/^Core \d+/.test(t.label)) { cores.push(t.value); continue }
      if (t.sensor === "nvme" && t.label !== "Composite" && t.label !== "") continue
      var name = names[t.sensor] || t.sensor
      if (/^Package/.test(t.label)) name = "CPU package"
      if (list.some(function(entry) { return entry.name === name })) continue
      list.push({ name: name, value: t.value })
    }
    if (cores.length > 0) list.push({ name: "Hottest core", value: Math.max.apply(null, cores) })
    // The CPU first, then the rest as the sensors come
    var order = ["CPU package", "Hottest core", "CPU"]
    return list.sort(function(a, b) {
      var x = order.indexOf(a.name), y = order.indexOf(b.name)
      return (x < 0 ? order.length : x) - (y < 0 ? order.length : y)
    })
  }

  readonly property real averageFreq: {
    if (!details || details.freqs.length === 0) return 0
    return details.freqs.reduce(function(sum, n) { return sum + n }, 0) / details.freqs.length
  }

  readonly property var memoryDetails: details ? details.memory : ({})
  readonly property real memoryCache: details ? (memoryDetails.Cached + memoryDetails.Buffers + memoryDetails.SReclaimable - memoryDetails.Shmem) : 0

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
      if (root.opened && !detailsProc.running) detailsProc.running = true
    }
  }

  onOpenedChanged: {
    if (!opened) return
    previous = null
    coreUse = []
    if (!detailsProc.running) detailsProc.running = true
  }

  Process {
    id: detailsProc
    command: ["neko-system-stats", "--details"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readDetails(text)
    }
    // The first read only sets the counters; the second gives the rates
    onExited: if (root.opened && root.coreUse.length === 0 && root.previous) running = true
  }

  // ---------- On the bar ----------
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    fixedWidth: rings.implicitWidth + Style.space(14)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.bar.run("neko-launch-tui btop")
      else root.toggle()
    }

    Row {
      id: rings
      anchors.centerIn: parent
      spacing: Style.space(6)

      Ring { icon: "󰻠"; value: root.cpu / 100; tint: root.levelColor(root.cpu, 80, 90) }
      Ring { icon: "󰔏"; value: root.temperature / 100; tint: root.levelColor(root.temperature, 70, 80) }
      Ring { icon: "󰍛"; value: root.memory / 100; tint: root.levelColor(root.memory, 80, 90) }
    }
  }

  // ---------- The details ----------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // Header: up how long, and btop
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: "System"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Caption {
              Layout.fillWidth: true
              text: root.details ? "Up " + root.duration(root.details.uptime) + "  ·  load " + root.details.load.map(function(n) { return n.toFixed(2) }).join("  ") : ""
            }
          }
          PanelActionButton {
            iconText: "󰄪"
            tooltipText: "Open btop"
            foreground: root.foreground
            onClicked: {
              root.bar.run("neko-launch-tui btop")
              root.close()
            }
          }
        }

        // CPU: the total, then a bar per core
        Section { title: "CPU"; value: Math.round(root.cpu) + "%"; tint: root.levelColor(root.cpu, 80, 90) }
        RowLayout {
          Layout.fillWidth: true
          Layout.topMargin: -Style.space(8)
          Caption {
            Layout.fillWidth: true
            text: root.details ? root.details.freqs.length + " threads, " + (root.averageFreq / 1000).toFixed(2) + " GHz on average" : ""
          }
          Caption {
            visible: !!root.details && !!root.details.gpu
            text: root.details && root.details.gpu ? "Graphics " + root.details.gpu.mhz + " / " + root.details.gpu.max + " MHz" : ""
          }
        }
        Row {
          id: cores
          Layout.fillWidth: true
          Layout.preferredWidth: column.width
          Layout.preferredHeight: Style.space(64)
          spacing: Style.space(4)
          readonly property int count: Math.max(1, root.coreUse.length || (root.details ? root.details.freqs.length : 1))

          Repeater {
            model: root.coreUse.length > 0 ? root.coreUse : (root.details ? root.details.freqs.map(function() { return 0 }) : [])

            Column {
              required property var modelData
              required property int index
              width: Math.floor((column.width - cores.spacing * (cores.count - 1)) / cores.count)
              spacing: Style.space(3)

              Rectangle {
                width: parent.width
                height: Style.space(48)
                radius: Style.space(4)
                color: Util.alpha(root.foreground, 0.1)

                Rectangle {
                  anchors.bottom: parent.bottom
                  width: parent.width
                  height: Math.max(parent.radius, parent.height * modelData / 100)
                  radius: parent.radius
                  color: root.levelColor(modelData, 80, 90)
                  Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                }
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: Math.round(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

        // Temperatures
        Section { title: "Temperatures"; value: Math.round(root.temperature) + "°C"; tint: root.levelColor(root.temperature, 70, 80) }
        GridLayout {
          Layout.fillWidth: true
          columns: 2
          columnSpacing: Style.space(20)
          rowSpacing: Style.space(4)
          Repeater {
            model: root.temperatures
            RowLayout {
              required property var modelData
              Layout.fillWidth: true
              Layout.preferredWidth: 1
              Caption { Layout.fillWidth: true; text: modelData.name }
              Text {
                text: Math.round(modelData.value) + "°C"
                color: modelData.value >= 70 ? root.levelColor(modelData.value, 70, 80) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

        // Memory: used, then cache, on one bar; swap below
        Section { title: "Memory"; value: Math.round(root.memory) + "%"; tint: root.levelColor(root.memory, 80, 90) }
        Meter {
          Layout.fillWidth: true
          value: root.memoryTotal > 0 ? root.memoryUsed / root.memoryTotal : 0
          extra: root.memoryTotal > 0 ? root.memoryCache / root.memoryTotal : 0
          tint: root.levelColor(root.memory, 80, 90)
        }
        RowLayout {
          Layout.fillWidth: true
          Caption {
            Layout.fillWidth: true
            text: root.gib(root.memoryUsed) + " of " + root.gib(root.memoryTotal) + " GiB used"
          }
          Caption {
            visible: !!root.details
            text: root.details ? root.gib(root.memoryCache) + " GiB cache, " + root.gib(root.memoryDetails.MemAvailable) + " free" : ""
          }
        }
        RowLayout {
          Layout.fillWidth: true
          visible: !!root.details && root.memoryDetails.SwapTotal > 0
          spacing: Style.space(10)
          Caption { text: "Swap" }
          Meter {
            Layout.fillWidth: true
            value: root.details && root.memoryDetails.SwapTotal > 0 ? 1 - root.memoryDetails.SwapFree / root.memoryDetails.SwapTotal : 0
            tint: root.accent
          }
          Caption {
            text: root.details ? root.gib(root.memoryDetails.SwapTotal - root.memoryDetails.SwapFree) + " of " + root.gib(root.memoryDetails.SwapTotal) + " GiB" : ""
          }
        }

        PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

        // Disks, one per filesystem
        Section { title: "Disks" }
        Repeater {
          model: root.details ? root.details.disks : []
          ColumnLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(4)
            RowLayout {
              Layout.fillWidth: true
              Text {
                Layout.fillWidth: true
                text: modelData.mount === "/" ? "System" : modelData.mount === "/home" ? "Home" : modelData.mount
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }
              Caption { text: root.bytes(modelData.used) + " of " + root.bytes(modelData.size) }
            }
            Meter {
              Layout.fillWidth: true
              value: modelData.size > 0 ? modelData.used / modelData.size : 0
              tint: root.levelColor(modelData.size > 0 ? modelData.used / modelData.size * 100 : 0, 80, 90)
            }
          }
        }

        PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

        // Network and power
        GridLayout {
          Layout.fillWidth: true
          columns: 2
          columnSpacing: Style.space(20)
          rowSpacing: Style.space(4)
          Figure { label: "Download"; value: root.bytes(root.receiving) + "/s" }
          Figure { label: "Upload"; value: root.bytes(root.sending) + "/s" }
          Figure { visible: !!root.details && root.details.power !== null; label: "Battery draw"; value: root.details && root.details.power !== null ? root.details.power.toFixed(1) + " W" : "" }
          Figure { label: "Received"; value: root.details ? root.bytes(root.details.network.rx) : "" }
        }

        PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

        // The busiest processes right now
        Section { title: "Busiest" }
        Repeater {
          model: root.details ? root.details.procs : []
          RowLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(10)
            Text {
              Layout.fillWidth: true
              text: modelData.name
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Caption { text: modelData.cpu.toFixed(1) + "% CPU" }
            Caption {
              Layout.preferredWidth: Style.space(70)
              horizontalAlignment: Text.AlignRight
              text: modelData.memory.toFixed(1) + "% RAM"
            }
          }
        }
      }
    }
  }

  // A ring filling clockwise from the top around an icon
  component Ring: Item {
    id: ring
    property string icon: ""
    property real value: 0
    property color tint: root.accent
    property real shown: Math.max(0, Math.min(1, value))
    // Inside the capsule behind the widget (inset 3 from the bar's edges), with a pixel to spare
    readonly property real size: root.bar ? root.bar.barSize - 2 * Style.space(3) - 2 : 22
    readonly property real stroke: Math.max(2, size / 10)

    width: size
    height: size

    Behavior on shown { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }

    Shape {
      anchors.fill: parent
      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeColor: Util.alpha(button.foreground, 0.2)
        strokeWidth: ring.stroke
        fillColor: "transparent"
        PathAngleArc {
          centerX: ring.size / 2
          centerY: ring.size / 2
          radiusX: (ring.size - ring.stroke) / 2
          radiusY: radiusX
          startAngle: 0
          sweepAngle: 360
        }
      }
      ShapePath {
        strokeColor: ring.tint
        strokeWidth: ring.stroke
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        PathAngleArc {
          centerX: ring.size / 2
          centerY: ring.size / 2
          radiusX: (ring.size - ring.stroke) / 2
          radiusY: radiusX
          startAngle: -90
          sweepAngle: 360 * ring.shown
        }
      }
    }

    Text {
      anchors.centerIn: parent
      text: ring.icon
      color: ring.tint === root.accent ? button.foreground : ring.tint
      font.family: button.fontFamily
      // The bar's text size, as far as the inside of the ring allows
      font.pixelSize: Math.min(Style.bar.fontSize, Math.round((ring.size - 2 * ring.stroke) * 0.8))
    }
  }

  // A section's title, with its headline figure on the right
  component Section: RowLayout {
    property string title: ""
    property string value: ""
    property color tint: root.foreground
    Layout.fillWidth: true
    Text {
      Layout.fillWidth: true
      text: parent.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
    }
    Text {
      visible: parent.value !== ""
      text: parent.value
      color: parent.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.weight: Font.DemiBold
    }
  }

  // A horizontal meter, with an optional lighter second part after the first
  component Meter: Item {
    property real value: 0
    property real extra: 0
    property color tint: root.accent
    implicitHeight: Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: Util.alpha(root.foreground, 0.1)
    }
    Rectangle {
      height: parent.height
      radius: height / 2
      width: Math.min(parent.width, parent.width * (parent.value + parent.extra))
      color: Util.alpha(parent.tint, 0.35)
      visible: parent.extra > 0
    }
    Rectangle {
      height: parent.height
      radius: height / 2
      width: Math.max(height, parent.width * Math.min(1, parent.value))
      color: parent.tint
      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    }
  }

  component Figure: ColumnLayout {
    property string label: ""
    property string value: ""
    Layout.fillWidth: true
    Layout.preferredWidth: 1
    spacing: 0
    Caption { text: parent.label }
    Text {
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component Caption: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
