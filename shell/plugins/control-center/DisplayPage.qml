import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../panels/monitor/Model.js" as MonitorModel
import "Arrange.js" as Arrange

// The control center's display page: every Hyprland monitor setting for one
// display, applied and kept through neko-display, and with more than one,
// how they work together: extended (arranged by dragging them), mirrored, or
// just one of them on. Changes that can leave a screen unreadable (mode,
// rotation, color depth and mode, mirroring, turning displays off) are
// trials, undone after 15 seconds unless kept.
ColumnLayout {
  id: root

  // neko-display json
  property var displays: []
  property QtObject bar: null
  property color foreground: NekoColor.popups.text
  property color dim: Util.alpha(foreground, 0.6)
  property color accent: NekoColor.accent
  property string fontFamily: Style.font.family

  signal back()
  // A change went through; read the displays again
  signal changed()

  property string selectedName: ""
  readonly property var display: {
    for (var i = 0; i < displays.length; i++) if (displays[i].name === selectedName) return displays[i]
    for (var j = 0; j < displays.length; j++) if (displays[j].focused) return displays[j]
    return displays.length > 0 ? displays[0] : null
  }
  readonly property var saved: display ? display.saved : ({})
  readonly property var others: displays.filter(function(d) { return display && d.name !== display.name })
  readonly property int enabledCount: displays.filter(function(d) { return d.enabled }).length
  property bool advanced: false
  // Dragged displays snap their edges and centers to the others'
  property bool snapping: true

  // Modes as "2880x1800@60.00Hz": the resolutions, largest first, and the
  // rates each one offers, fastest first
  readonly property var modes: {
    var byResolution = {}
    var list = display ? display.modes : []
    for (var i = 0; i < list.length; i++) {
      var match = /^(\d+)x(\d+)@([\d.]+)Hz$/.exec(list[i])
      if (!match) continue
      var key = match[1] + "x" + match[2]
      if (!byResolution[key]) byResolution[key] = { width: Number(match[1]), height: Number(match[2]), rates: [] }
      if (byResolution[key].rates.indexOf(match[3]) < 0) byResolution[key].rates.push(match[3])
    }
    var resolutions = Object.keys(byResolution).map(function(k) { return byResolution[k] })
    resolutions.sort(function(a, b) { return b.width * b.height - a.width * a.height })
    resolutions.forEach(function(r) { r.rates.sort(function(a, b) { return Number(b) - Number(a) }) })
    return resolutions
  }
  readonly property string resolution: display ? display.width + "x" + display.height : ""
  readonly property var rates: {
    for (var i = 0; i < modes.length; i++) if (modes[i].width + "x" + modes[i].height === resolution) return modes[i].rates
    return []
  }
  // The listed rate closest to the one the display runs at
  readonly property string rate: {
    var best = ""
    for (var i = 0; i < rates.length; i++) {
      if (!best || Math.abs(Number(rates[i]) - display.refreshRate) < Math.abs(Number(best) - display.refreshRate)) best = rates[i]
    }
    return best
  }

  // A setting as it stands: saved, or else how the display runs now
  function current(key) {
    if (!display) return ""
    if (saved[key] !== undefined) return String(saved[key])
    if (key === "mode") return display.width + "x" + display.height + "@" + display.refreshRate.toFixed(3)
    if (key === "transform") return String(display.transform)
    if (key === "bitdepth") return String(display.bitdepth)
    if (key === "cm") return display.cm
    if (key === "mirror") return display.mirrorOf !== "none" ? display.mirrorOf : ""
    if (key === "vrr") return String(display.vrrDefault)
    if (key === "sdrbrightness") return String(display.sdrBrightness)
    if (key === "sdrsaturation") return String(display.sdrSaturation)
    return ""
  }

  function change(key, value) {
    if (display) run(["neko-display", "set", display.name, key + "=" + value])
  }

  // Apply a change the display might not survive as a trial: neko-display
  // undoes it after 15 seconds unless it's kept, on its own, so a dark
  // screen can't stop that
  function setRisky(key, value) {
    if (!display || current(key) === String(value)) return
    run(["neko-display", "set", "--trial", display.name, key + "=" + value])
  }

  // How the displays work together: "extend", "mirror:<shown>" or "only:<on>"
  readonly property string layoutMode: {
    for (var i = 0; i < displays.length; i++) {
      if (displays[i].enabled && displays[i].mirrorOf !== "none") return "mirror:" + displays[i].mirrorOf
    }
    var on = displays.filter(function(d) { return d.enabled })
    if (displays.length > 1 && on.length === 1) return "only:" + on[0].name
    return "extend"
  }

  function screenName(d) {
    return /^(eDP|LVDS|DSI)/.test(d.name) ? "the laptop screen" : d.name
  }

  function mirroring(d) {
    return d.mirrorOf !== "none" || !!d.saved.mirror
  }

  // Extending only turns displays on, so it needs no undo; mirroring and
  // leaving one display on can leave nothing to see
  function setLayoutMode(mode) {
    if (mode === layoutMode) return
    var kind = mode.split(":")[0]
    var target = mode.slice(kind.length + 1)
    var later = []
    for (var i = 0; i < displays.length; i++) {
      var d = displays[i]
      if (kind === "extend") {
        if (!d.enabled) run(["neko-display", "set", d.name, "disabled=false"])
        if (mirroring(d)) later.push(["neko-display", "set", d.name, "mirror="])
      } else if (d.name === target) {
        var on = ["neko-display", "set", "--trial", d.name]
        if (!d.enabled) on.push("disabled=false")
        if (mirroring(d)) on.push("mirror=")
        if (on.length > 4) run(on)
      } else if (kind === "mirror") {
        later.push(["neko-display", "set", "--trial", d.name, "mirror=" + target].concat(d.enabled ? [] : ["disabled=false"]))
      } else if (d.enabled) {
        later.push(["neko-display", "set", "--trial", d.name, "disabled=true"])
      }
    }
    later.forEach(run)
  }

  function keep() {
    settledTrial = trialUntil
    run(["neko-display", "keep"])
  }

  function revert() {
    settledTrial = trialUntil
    run(["neko-display", "undo"])
  }

  // When an open trial ends, from neko-display json
  readonly property real trialUntil: display ? display.trialUntil : 0
  readonly property bool trialOpen: trialUntil > clock.date.getTime() && trialUntil !== settledTrial
  // The trial kept, undone, or read again after it ran out
  property real settledTrial: 0
  readonly property int countdown: Math.max(0, Math.ceil((trialUntil - clock.date.getTime()) / 1000))

  SystemClock {
    id: clock
    enabled: root.trialUntil > 0
    precision: SystemClock.Seconds
    // Read the displays again once the trial has been undone
    onDateChanged: if (root.trialUntil > 0 && root.settledTrial !== root.trialUntil && date.getTime() >= root.trialUntil + 1000) {
      root.settledTrial = root.trialUntil
      Qt.callLater(root.changed)
    }
  }

  // Commands run one after another, then the displays are read again
  property var queue: []

  function run(argv) {
    queue = queue.concat([argv])
    if (!runner.running) next()
  }

  function next() {
    if (queue.length === 0) {
      changed()
      return
    }
    runner.command = queue[0]
    queue = queue.slice(1)
    runner.running = true
  }

  Process {
    id: runner
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim()) console.warn("neko-display: " + String(text).trim())
    }
    onExited: root.next()
  }

  spacing: Style.space(10)

  // Header
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
      text: "Display"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.weight: Font.DemiBold
    }
    PanelActionButton {
      visible: !!root.display && Object.keys(root.saved).length > 0
      iconText: "󰑓"
      tooltipText: "Back to my Hyprland config"
      foreground: root.foreground
      onClicked: if (root.display) root.run(["neko-display", "reset", root.display.name])
    }
  }

  // Keep or undo the last change
  Rectangle {
    Layout.fillWidth: true
    visible: root.trialOpen
    implicitHeight: keepRow.implicitHeight + Style.space(16)
    radius: Style.space(12)
    color: Util.alpha(root.accent, 0.18)

    RowLayout {
      id: keepRow
      anchors.fill: parent
      anchors.margins: Style.space(8)
      anchors.leftMargin: Style.space(12)
      spacing: Style.space(8)
      Text {
        Layout.fillWidth: true
        text: "Keep these settings?\nUndoing in " + root.countdown + " s"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
      Button {
        text: "Undo"
        bordered: true
        onClicked: root.revert()
      }
      Button {
        text: "Keep"
        bordered: true
        onClicked: root.keep()
      }
    }
  }

  // How the displays work together
  Caption { text: "Multiple displays"; visible: root.displays.length > 1 }
  Dropdown {
    Layout.fillWidth: true
    visible: root.displays.length > 1
    showLabel: false
    fontFamily: root.fontFamily
    options: [{ value: "extend", label: "Extend across them" }]
      .concat(root.displays.map(function(d) { return { value: "mirror:" + d.name, label: "Mirror " + root.screenName(d) } }))
      .concat(root.displays.map(function(d) { return { value: "only:" + d.name, label: "Only " + root.screenName(d) } }))
    value: root.layoutMode
    onChanged: function(v) { root.setLayoutMode(v) }
  }

  // Extended displays as boxes to drag where they stand: the pointer
  // crosses between displays where their boxes meet
  Item {
    id: arrangement
    Layout.fillWidth: true
    Layout.preferredHeight: Style.space(190)
    visible: root.layoutMode === "extend" && rects.length > 1
    clip: true

    // Where the displays are, or where a drop put them until they're read again
    property var placed: null
    readonly property var rects: placed || Arrange.rects(root.displays)
    // Held still while a box is dragged, so the view doesn't move under it
    property var frozen: null
    readonly property var view: frozen || Arrange.fit(rects, width, height, Style.space(10))
    property string dragging: ""
    property var dragRect: null
    property var guides: ({ x: [], y: [] })

    Connections {
      target: root
      function onDisplaysChanged() { arrangement.placed = null }
    }

    function others(name) {
      return rects.filter(function(r) { return r.name !== name })
    }

    // Drag a box by dx, dy view pixels from where it is, snapping if asked
    function dragBy(name, dx, dy) {
      var from = null
      for (var i = 0; i < rects.length; i++) if (rects[i].name === name) from = rects[i]
      if (!from) return
      if (!dragging) {
        frozen = view
        dragging = name
        root.selectedName = name
      }
      var scale = view.scale
      var r = { x: from.x + dx / scale, y: from.y + dy / scale, width: from.width, height: from.height }
      if (root.snapping) {
        var snapped = Arrange.snap(r, others(name), Style.space(10) / scale)
        r.x = snapped.x
        r.y = snapped.y
        guides = { x: snapped.guidesX, y: snapped.guidesY }
      }
      dragRect = r
    }

    function endDrag() {
      dragging = ""
      dragRect = null
      frozen = null
      guides = { x: [], y: [] }
    }

    // Drop a box: out of the others' way, touching one, applied at once
    function drop(name) {
      var placed = Arrange.drop(rects, name, dragRect.x, dragRect.y)
      endDrag()
      var moved = placed.some(function(p) {
        return rects.some(function(r) { return r.name === p.name && (r.x !== p.x || r.y !== p.y) })
      })
      if (!moved) return
      arrangement.placed = placed
      root.run(["neko-display", "place"].concat(placed.map(function(p) { return p.name + "=" + p.x + "x" + p.y })))
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.space(12)
      color: Util.alpha(root.foreground, 0.05)
    }

    // Where a dragged box meets another's edge or center
    Repeater {
      model: arrangement.guides.x
      delegate: Rectangle {
        required property var modelData
        x: Math.round(arrangement.view.x + modelData * arrangement.view.scale)
        width: 1
        height: arrangement.height
        color: root.accent
      }
    }
    Repeater {
      model: arrangement.guides.y
      delegate: Rectangle {
        required property var modelData
        y: Math.round(arrangement.view.y + modelData * arrangement.view.scale)
        width: arrangement.width
        height: 1
        color: root.accent
      }
    }

    Repeater {
      model: arrangement.rects
      delegate: Rectangle {
        id: box
        required property var modelData
        readonly property bool moving: arrangement.dragging === modelData.name
        readonly property var at: moving ? arrangement.dragRect : modelData
        readonly property bool selected: !!root.display && root.display.name === modelData.name

        x: Math.round(arrangement.view.x + at.x * arrangement.view.scale)
        y: Math.round(arrangement.view.y + at.y * arrangement.view.scale)
        width: Math.round(modelData.width * arrangement.view.scale)
        height: Math.round(modelData.height * arrangement.view.scale)
        z: moving ? 2 : 1
        radius: Style.space(6)
        color: selected ? Util.alpha(root.accent, 0.3) : Util.alpha(root.foreground, 0.12)
        border.width: selected ? 2 : 1
        border.color: selected ? root.accent : Util.alpha(root.foreground, 0.3)
        opacity: moving ? 0.85 : 1

        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(8)
          Text {
            width: parent.width
            text: box.modelData.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.weight: Font.DemiBold
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
          Text {
            width: parent.width
            visible: box.height > Style.space(44)
            text: box.modelData.width + " × " + box.modelData.height
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }

        MouseArea {
          property point start

          anchors.fill: parent
          // The page scrolls; a drag here moves the box instead
          preventStealing: true
          cursorShape: arrangement.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
          onPressed: function(mouse) { start = mapToItem(arrangement, mouse.x, mouse.y) }
          onPositionChanged: function(mouse) {
            var p = mapToItem(arrangement, mouse.x, mouse.y)
            if (!arrangement.dragging && Math.abs(p.x - start.x) + Math.abs(p.y - start.y) < 4) return
            arrangement.dragBy(box.modelData.name, p.x - start.x, p.y - start.y)
          }
          onReleased: {
            if (arrangement.dragging) arrangement.drop(box.modelData.name)
            else root.selectedName = box.modelData.name
          }
          onCanceled: arrangement.endDrag()
        }
      }
    }
  }

  RowLayout {
    Layout.fillWidth: true
    visible: arrangement.visible
    Caption {
      Layout.fillWidth: true
      text: root.snapping ? "Snap to edges and centers" : "Place freely (still touching another)"
    }
    ToggleSwitch {
      checked: root.snapping
      onToggled: root.snapping = !root.snapping
    }
  }

  // Which display; the arrangement picks one too, when it shows them all
  ButtonGroup {
    Layout.fillWidth: true
    visible: root.displays.length > 1 && (!arrangement.visible || arrangement.rects.length < root.displays.length)
    fontSize: Style.font.bodySmall
    options: root.displays.map(function(d) { return { value: d.name, label: d.name } })
    value: root.display ? root.display.name : ""
    onChanged: function(v) { root.selectedName = v }
  }

  RowLayout {
    Layout.fillWidth: true
    visible: !!root.display
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0
      Text {
        Layout.fillWidth: true
        text: root.display ? root.display.description : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
      Text {
        text: !root.display ? "" : !root.display.enabled ? "Off"
          : root.resolution + " at " + Math.round(root.display.refreshRate) + " Hz, " + MonitorModel.normalizeScale(root.display.scale) + "x"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    // Never switch off the last screen that's on
    ToggleSwitch {
      visible: root.displays.length > 1
      checked: !!root.display && root.display.enabled
      interactive: !!root.display && (!root.display.enabled || root.enabledCount > 1)
      onToggled: root.change("disabled", root.display.enabled ? "true" : "false")
    }
  }

  ColumnLayout {
    Layout.fillWidth: true
    visible: !!root.display && root.display.enabled
    spacing: Style.space(10)

    Caption { text: "Resolution" }
    Dropdown {
      Layout.fillWidth: true
      showLabel: false
      fontFamily: root.fontFamily
      options: root.modes.map(function(m) { return { value: m.width + "x" + m.height, label: m.width + " × " + m.height } })
        .concat([{ value: "preferred", label: "Preferred" }, { value: "highres", label: "Highest resolution" }, { value: "highrr", label: "Highest refresh rate" }])
      value: /^(preferred|highres|highrr)$/.test(root.current("mode")) ? root.current("mode") : root.resolution
      onChanged: function(v) {
        if (/^(preferred|highres|highrr)$/.test(v)) { root.setRisky("mode", v); return }
        // Keep the rate when the new resolution offers it, else take its fastest
        for (var i = 0; i < root.modes.length; i++) {
          var m = root.modes[i]
          if (m.width + "x" + m.height !== v) continue
          root.setRisky("mode", v + "@" + (m.rates.indexOf(root.rate) >= 0 ? root.rate : m.rates[0]))
        }
      }
    }

    Caption { text: "Refresh rate"; visible: root.rates.length > 1 }
    ButtonGroup {
      Layout.fillWidth: true
      visible: root.rates.length > 1 && root.rates.length <= 4
      fontSize: Style.font.bodySmall
      options: root.rates.map(function(r) { return { value: r, label: Math.round(Number(r)) + " Hz" } })
      value: root.rate
      onChanged: function(v) { root.setRisky("mode", root.resolution + "@" + v) }
    }
    Dropdown {
      Layout.fillWidth: true
      visible: root.rates.length > 4
      showLabel: false
      fontFamily: root.fontFamily
      options: root.rates.map(function(r) { return { value: r, label: Number(r).toFixed(2) + " Hz" } })
      value: root.rate
      onChanged: function(v) { root.setRisky("mode", root.resolution + "@" + v) }
    }

    Caption { text: "Scale" }
    ButtonGroup {
      Layout.fillWidth: true
      fontSize: Style.font.bodySmall
      options: (root.display ? MonitorModel.availableScales(["1", "1.25", "1.5", "1.6", "2", "3"], root.display.width, root.display.height) : [])
        .map(function(v) { return { value: String(v), label: v + "x" } })
      value: root.display ? MonitorModel.normalizeScale(root.display.scale) : ""
      onChanged: function(v) { root.change("scale", v) }
    }

    Caption { text: "Rotation" }
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(10)
      ButtonGroup {
        Layout.fillWidth: true
        fontSize: Style.font.bodySmall
        options: [ { value: "0", label: "0°" }, { value: "1", label: "90°" }, { value: "2", label: "180°" }, { value: "3", label: "270°" } ]
        value: String(Number(root.current("transform")) % 4)
        onChanged: function(v) { root.setRisky("transform", Number(v) + (Number(root.current("transform")) >= 4 ? 4 : 0)) }
      }
      Text {
        text: "Flip"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      ToggleSwitch {
        checked: Number(root.current("transform")) >= 4
        onToggled: root.setRisky("transform", (Number(root.current("transform")) + 4) % 8)
      }
    }

    PanelSeparator { foreground: root.foreground; Layout.fillWidth: true }

    Caption { text: "Color depth" }
    ButtonGroup {
      Layout.fillWidth: true
      fontSize: Style.font.bodySmall
      options: [ { value: "8", label: "8-bit" }, { value: "10", label: "10-bit" } ]
      value: root.current("bitdepth")
      onChanged: function(v) { root.setRisky("bitdepth", v) }
    }

    Caption { text: "Variable refresh rate" }
    ButtonGroup {
      Layout.fillWidth: true
      fontSize: Style.font.bodySmall
      options: [ { value: "0", label: "Off" }, { value: "1", label: "On" }, { value: "2", label: "Fullscreen" }, { value: "3", label: "Games" } ]
      value: root.current("vrr")
      onChanged: function(v) { root.change("vrr", v) }
    }

    Caption { text: "Color mode" }
    Dropdown {
      Layout.fillWidth: true
      showLabel: false
      fontFamily: root.fontFamily
      options: [
        { value: "auto", label: "Automatic" },
        { value: "srgb", label: "sRGB" },
        { value: "dcip3", label: "DCI-P3" },
        { value: "dp3", label: "Display P3" },
        { value: "adobe", label: "Adobe RGB" },
        { value: "wide", label: "Wide gamut (BT.2020)" },
        { value: "edid", label: "From the display (EDID)" },
        { value: "hdr", label: "HDR" },
        { value: "hdredid", label: "HDR, from the display (EDID)" }
      ]
      value: root.current("cm")
      onChanged: function(v) { root.setRisky("cm", v) }
    }

    // How SDR content looks inside HDR
    ColumnLayout {
      Layout.fillWidth: true
      visible: /^hdr/.test(root.current("cm"))
      spacing: Style.space(10)

      Caption { text: "SDR brightness  " + Number(root.current("sdrbrightness")).toFixed(2) }
      PanelSlider {
        Layout.fillWidth: true
        bar: root.bar
        minimum: 0.5
        maximum: 3
        step: 0.05
        value: Number(root.current("sdrbrightness")) || 1
        onReleased: function(v) { root.change("sdrbrightness", v.toFixed(2)) }
      }
      Caption { text: "SDR saturation  " + Number(root.current("sdrsaturation")).toFixed(2) }
      PanelSlider {
        Layout.fillWidth: true
        bar: root.bar
        minimum: 0
        maximum: 2
        step: 0.05
        value: Number(root.current("sdrsaturation")) || 1
        onReleased: function(v) { root.change("sdrsaturation", v.toFixed(2)) }
      }
      Caption { text: "SDR transfer" }
      ButtonGroup {
        Layout.fillWidth: true
        fontSize: Style.font.bodySmall
        options: [ { value: "default", label: "Default" }, { value: "gamma22", label: "Gamma 2.2" }, { value: "srgb", label: "sRGB" } ]
        value: root.saved.sdr_eotf || "default"
        onChanged: function(v) { root.change("sdr_eotf", v === "default" ? "" : v) }
      }
    }

    // Overrides for what the display reports about itself, and the rest
    Button {
      Layout.fillWidth: true
      text: root.advanced ? "Fewer settings" : "More settings"
      iconText: root.advanced ? "󰅃" : "󰅀"
      bordered: true
      onClicked: root.advanced = !root.advanced
    }

    ColumnLayout {
      Layout.fillWidth: true
      visible: root.advanced
      spacing: Style.space(10)

      // Placement that follows the other displays, and mirroring just this one
      Caption { text: "Place it automatically"; visible: root.others.length > 0 }
      ButtonGroup {
        Layout.fillWidth: true
        visible: root.others.length > 0
        fontSize: Style.font.bodySmall
        options: [ { value: "auto", label: "Auto" }, { value: "auto-left", label: "Left" }, { value: "auto-right", label: "Right" }, { value: "auto-up", label: "Above" }, { value: "auto-down", label: "Below" } ]
        value: root.saved.position && String(root.saved.position).indexOf("auto") === 0 ? root.saved.position : ""
        onChanged: function(v) { root.change("position", v) }
      }
      Caption { text: "Mirror"; visible: root.others.length > 0 }
      Dropdown {
        Layout.fillWidth: true
        visible: root.others.length > 0
        showLabel: false
        fontFamily: root.fontFamily
        options: [{ value: "", label: "Don't mirror" }].concat(root.others.map(function(d) { return { value: d.name, label: "Mirror " + d.name } }))
        value: root.current("mirror")
        onChanged: function(v) { root.setRisky("mirror", v) }
      }

      Caption { text: "HDR support" }
      ButtonGroup {
        Layout.fillWidth: true
        fontSize: Style.font.bodySmall
        options: [ { value: "-1", label: "Never" }, { value: "0", label: "Detect" }, { value: "1", label: "Always" } ]
        value: String(root.saved.supports_hdr !== undefined ? root.saved.supports_hdr : 0)
        onChanged: function(v) { root.change("supports_hdr", v === "0" ? "" : v) }
      }
      Caption { text: "Wide color support" }
      ButtonGroup {
        Layout.fillWidth: true
        fontSize: Style.font.bodySmall
        options: [ { value: "-1", label: "Never" }, { value: "0", label: "Detect" }, { value: "1", label: "Always" } ]
        value: String(root.saved.supports_wide_color !== undefined ? root.saved.supports_wide_color : 0)
        onChanged: function(v) { root.change("supports_wide_color", v === "0" ? "" : v) }
      }

      Caption { text: "Luminance in nits: min, max, max average" }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        SettingField { key: "min_luminance"; placeholder: "Min" }
        SettingField { key: "max_luminance"; placeholder: "Max" }
        SettingField { key: "max_avg_luminance"; placeholder: "Avg" }
      }
      Caption { text: "SDR luminance in nits: min, max" }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        SettingField { key: "sdr_min_luminance"; placeholder: "Min" }
        SettingField { key: "sdr_max_luminance"; placeholder: "Max" }
      }
      Caption { text: "ICC profile" }
      SettingField { key: "icc"; placeholder: "/path/to/profile.icc" }
      Caption { text: "Reserved space in pixels: top right bottom left" }
      SettingField {
        key: "reserved_area"
        placeholder: "0 0 0 0"
        shown: root.saved.reserved_area
          ? [root.saved.reserved_area.top, root.saved.reserved_area.right, root.saved.reserved_area.bottom, root.saved.reserved_area.left].join(" ")
          : ""
      }
    }
  }

  component Caption: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // A typed setting, saved when editing ends; empty goes back to the default
  component SettingField: TextField {
    property string key: ""
    property string placeholder: ""
    property string shown: root.saved[key] !== undefined ? String(root.saved[key]) : ""

    Layout.fillWidth: true
    foreground: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    placeholderText: placeholder
    text: shown
    onEditingFinished: if (text.trim() !== shown) root.change(key, text.trim())
  }
}
