import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The settings window, in tabs. With the bar's island up on its screen, it
// grows out of the island as the island's own cards do: from where the
// island rests, on a spring, hanging from the top edge when the bar is
// attached, and back into it on close. Without one it's a card in the
// middle of the screen.
//
// Every control runs the command the menu would (neko-settings, neko-bar,
// neko-wallpaper, neko-calendars, ...) and the window re-reads the state from
// `neko-settings json` once it finishes, so the two never disagree.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  // Up from the open's first frame to the close's last
  property bool windowShown: false
  property string tab: "appearance"
  property var settings: ({
    colors: "", barFloat: true, barCapsules: true, barPosition: "top", barGlass: false,
    barLayout: "", barLayouts: [],
    rotation: "off", apps: [], agent: "", agents: [], font: "", textSize: 0,
    powerProfile: "", powerProfiles: [], chargeLimit: 0, stayAwake: false, dnd: false,
    dns: "", weather: "", calendars: []
  })
  property var fonts: []
  // The bar as `neko-bar json` describes it: its layout, the widgets that can
  // go on it (with their options) and the saved layouts
  property var bar: ({ layout: { left: [], center: [], right: [] }, style: "floating", position: "top", widgets: [], presets: [] })
  // The widget picked in the Widgets tab: { section, index }
  property var picked: null
  readonly property var pickedEntry: picked ? (bar.layout[picked.section] || [])[picked.index] : undefined
  readonly property string pickedId: pickedEntry !== undefined ? entryId(pickedEntry) : ""
  readonly property var pickedInfo: widgetInfo(pickedId)

  // On glass the card is dark whatever the theme, so its text stays light
  readonly property color foreground: settings.barGlass ? "#f2f2f2" : NekoColor.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color accent: NekoColor.accent
  readonly property string fontFamily: Style.font.family
  readonly property int labelWidth: Style.space(140)

  readonly property var tabs: [
    { id: "appearance", label: "Appearance", icon: "\u{F03D8}" },
    { id: "bar", label: "Bar", icon: "\u{F035C}" },
    { id: "widgets", label: "Widgets", icon: "\u{F056E}" },
    { id: "wallpaper", label: "Wallpaper", icon: "\u{F0E09}" },
    { id: "system", label: "System", icon: "\u{F0493}" },
    { id: "calendars", label: "Calendars", icon: "\u{F00ED}" },
    { id: "apps", label: "Apps", icon: "\u{F003B}" }
  ]

  readonly property var agentNames: ({
    "claude": "Claude", "codex": "Codex", "opencode": "OpenCode", "pi": "Pi",
    "crush": "Crush", "grok": "Grok", "copilot": "Copilot", "cursor-agent": "Cursor"
  })
  readonly property var profileNames: ({ "power-saver": "Power saver", "balanced": "Balanced", "performance": "Performance" })

  // payload: { "tab": "calendars" } opens on that tab
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (payload.tab) root.tab = String(payload.tab)
    if (root.opened) return
    root.opened = true
    root.windowShown = true
    root.reload()
    if (root.fonts.length === 0 && !fontsProc.running) fontsProc.running = true
    // Once the window is on its screen, so it knows which island it grows from
    Qt.callLater(card.begin)
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    card.end()
  }

  // Torn down while open (a plugin reload), it mustn't leave the island
  // holding a card that's gone
  Component.onDestruction: if (root.windowShown && Island.settingsOpen) Island.settingsOpen = false

  function reload() {
    if (!stateProc.running) stateProc.running = true
    if (!barProc.running) barProc.running = true
  }

  // A command as an argument list (or a string for bash), run one at a time
  // in order, the state read again after each
  property var queue: []
  function run(command) {
    root.queue = root.queue.concat([typeof command === "string" ? ["bash", "-c", command] : command])
    root.runNext()
  }
  function runNext() {
    if (actionProc.running || root.queue.length === 0) return
    actionProc.command = root.queue[0]
    root.queue = root.queue.slice(1)
    actionProc.running = true
  }

  // ---------------------------------------------------------- bar layout
  function entryId(entry) {
    return typeof entry === "string" ? entry : String(entry && entry.id || "")
  }
  function entryValue(entry, key) {
    return entry && typeof entry === "object" ? entry[key] : undefined
  }
  function widgetInfo(id) {
    var widgets = root.bar.widgets || []
    for (var i = 0; i < widgets.length; i++) if (widgets[i].id === id) return widgets[i]
    return { id: id, name: String(id || "").replace(/^[^.]*\./, ""), description: "", schema: [] }
  }
  function onBar(id) {
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = root.bar.layout[sections[s]] || []
      for (var i = 0; i < list.length; i++) if (entryId(list[i]) === id) return true
    }
    return false
  }
  function groupAt(section, index) {
    var entry = (root.bar.layout[section] || [])[index]
    return entry === undefined ? "" : String(entryValue(entry, "group") || "")
  }
  // Attached, each side of the bar is one capsule whatever its groups say
  function sidesGrouped(section) {
    return root.bar.style === "attached" && root.bar.position === "top" && section !== "center"
  }
  function sharesNext(section, index) {
    var list = root.bar.layout[section] || []
    if (index + 1 >= list.length) return false
    if (sidesGrouped(section)) return true
    var group = groupAt(section, index)
    return group !== "" && group === groupAt(section, index + 1)
  }
  // Groups for a diagram: how many widgets each capsule holds, in order
  function capsuleCounts(entries, oneCapsule) {
    if (!entries || entries.length === 0) return []
    if (oneCapsule) return [entries.length]
    var counts = []
    var last = null
    for (var i = 0; i < entries.length; i++) {
      var group = String(entryValue(entries[i], "group") || "")
      if (group !== "" && group === last) counts[counts.length - 1] += 1
      else counts.push(1)
      last = group
    }
    return counts
  }

  // Changes show at once, the command following; the next read confirms them
  function setLayout(layout) {
    var next = {}
    for (var key in root.bar) next[key] = root.bar[key]
    next.layout = layout
    root.bar = next
  }
  function copyLayout() {
    var layout = root.bar.layout
    return { left: (layout.left || []).slice(), center: (layout.center || []).slice(), right: (layout.right || []).slice() }
  }
  // toIndex counts the section without the widget being moved
  function moveWidget(fromSection, fromIndex, toSection, toIndex) {
    var layout = copyLayout()
    var entry = layout[fromSection][fromIndex]
    if (entry === undefined) return
    layout[fromSection].splice(fromIndex, 1)
    toIndex = Math.max(0, Math.min(toIndex, layout[toSection].length))
    if (fromSection === toSection && toIndex === fromIndex) return
    layout[toSection].splice(toIndex, 0, entry)
    setLayout(layout)
    root.picked = { section: toSection, index: toIndex }
    root.run(["neko-bar", "move", entryId(entry), "--from-section", fromSection, "--from-index", String(fromIndex),
      "--section", toSection, "--index", String(toIndex)])
    // Its capsule is where it lands: dropped between two that share one, or
    // at a section's end beside one, it joins it; beside the one it shared
    // it stays; else it has its own
    var count = layout[toSection].length
    var before = toIndex > 0 ? groupAt(toSection, toIndex - 1) : null
    var after = toIndex + 1 < count ? groupAt(toSection, toIndex + 1) : null
    var own = String(entryValue(entry, "group") || "")
    var group = before && (before === after || after === null) ? before
      : after && before === null ? after
      : own !== "" && (own === before || own === after) ? own : ""
    if (group !== own) setOption(toSection, toIndex, "group", group === "" ? null : group)
  }
  function removeWidget(section, index) {
    var layout = copyLayout()
    var entry = layout[section][index]
    if (entry === undefined) return
    layout[section].splice(index, 1)
    setLayout(layout)
    root.picked = null
    root.run(["neko-bar", "remove", entryId(entry), "--from-section", section, "--from-index", String(index)])
  }
  // A null value clears the option back to the widget's default
  function setOption(section, index, key, value) {
    var layout = copyLayout()
    var entry = layout[section][index]
    if (entry === undefined) return
    var next = typeof entry === "string" ? { id: entry } : JSON.parse(JSON.stringify(entry))
    if (value === null) delete next[key]
    else next[key] = value
    layout[section][index] = next
    setLayout(layout)
    root.run(["neko-bar", "set", entryId(entry), key, JSON.stringify(value), "--json", "--section", section, "--index", String(index)])
  }
  // Joining a widget's capsule to the next one's, or parting them
  function setSharesNext(section, index, on) {
    var list = root.bar.layout[section] || []
    if (index + 1 >= list.length) return
    var here = groupAt(section, index)
    var next = groupAt(section, index + 1)
    if (on) {
      // Keep a name that's already there (the bar reads some, like unibar):
      // this one's, else the next one's, and what follows comes along
      var group = here || next || ("group-" + Date.now().toString(36))
      if (here !== group) setOption(section, index, "group", group)
      for (var i = index + 1; i < list.length && (i === index + 1 || (next !== "" && groupAt(section, i) === next)); i++)
        if (groupAt(section, i) !== group) setOption(section, i, "group", group)
      return
    }
    if (here === "" || here !== next) return
    // Split the capsule after this widget: what follows takes a group of its
    // own (none if it's alone), and this one leaves if it's now alone
    var end = index + 1
    while (end + 1 < list.length && groupAt(section, end + 1) === here) end++
    var rest = end > index + 1 ? here + "-" + Date.now().toString(36) : null
    for (var j = index + 1; j <= end; j++) setOption(section, j, "group", rest)
    if (index === 0 || groupAt(section, index - 1) !== here) setOption(section, index, "group", null)
  }

  function hasApp(app) {
    return root.settings.apps && root.settings.apps.indexOf(app) >= 0
  }

  function barLayoutLabel(name) {
    if (name === "unibar") return "UniBar"
    if (name === "pre-unibar") return "Original"
    return String(name || "").split(/[-_]/).map(function(word) {
      return word.length > 0 ? word.charAt(0).toUpperCase() + word.slice(1) : ""
    }).join(" ")
  }

  Process {
    id: stateProc
    command: ["neko-settings", "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.settings = JSON.parse(String(text || "{}")) } catch (e) {}
      }
    }
  }

  Process {
    id: barProc
    command: ["neko-bar", "json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.bar = JSON.parse(String(text || "{}")) } catch (e) {}
      }
    }
  }

  Process {
    id: fontsProc
    command: ["neko-font-list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.fonts = String(text || "").split("\n").filter(function(f) { return f !== "" })
    }
  }

  Process {
    id: actionProc
    onExited: {
      root.reload()
      root.runNext()
    }
  }

  OverlayWindow {
    id: window
    shown: root.windowShown
    WlrLayershell.namespace: "neko-settings"

    // Off the island there's a light scrim; out of it, only the card
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(NekoColor.menu.scrim, 0.35)
      opacity: !card.fromIsland && root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: Style.duration(140) } }
    }
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      // Hanging from the top edge, the card and its shoulders are one shape:
      // drawn apart, they'd meet between pixels and leave a seam
      Shape {
        id: hanging
        readonly property real round: Math.min(Style.space(26), card.height / 2)
        // Shoulders curve the card's sides into the edge, as the island's do
        readonly property real shoulder: Math.max(0, Math.min(Style.space(16), card.height - round))
        anchors.fill: parent
        visible: card.attached && card.height > 1
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          fillColor: Island.panelGlass
          strokeWidth: 0
          strokeColor: "transparent"
          startX: card.x - hanging.shoulder
          startY: card.y
          PathLine { x: card.x + card.width + hanging.shoulder; y: card.y }
          PathArc { x: card.x + card.width; y: card.y + hanging.shoulder; radiusX: hanging.shoulder; radiusY: hanging.shoulder; direction: PathArc.Counterclockwise }
          PathLine { x: card.x + card.width; y: card.y + card.height - hanging.round }
          PathArc { x: card.x + card.width - hanging.round; y: card.y + card.height; radiusX: hanging.round; radiusY: hanging.round }
          PathLine { x: card.x + hanging.round; y: card.y + card.height }
          PathArc { x: card.x; y: card.y + card.height - hanging.round; radiusX: hanging.round; radiusY: hanging.round }
          PathLine { x: card.x; y: card.y + hanging.shoulder }
          PathArc { x: card.x - hanging.shoulder; y: card.y; radiusX: hanging.shoulder; radiusY: hanging.shoulder; direction: PathArc.Counterclockwise }
        }
      }

      Item {
        id: card

        // Where the island rests on this screen, if it's up
        property var rest: null
        readonly property bool fromIsland: rest !== null
        readonly property bool attached: fromIsland && rest.attached === true
        property bool grown: false
        property bool animate: false
        property bool contentShown: false

        readonly property real fullWidth: Style.space(720)
        readonly property real fullHeight: Math.min(page.implicitHeight + Style.space(40),
          window.height - (fromIsland ? rest.y : 0) - Style.space(48))
        readonly property real restWidth: fromIsland ? rest.width : fullWidth
        readonly property real restHeight: fromIsland ? rest.height : fullHeight

        function begin() {
          var name = window.screen ? window.screen.name : ""
          var rect = Island.active ? Island.restRects[name] : undefined
          card.animate = false
          card.grown = false
          card.rest = rect ? rect : null
          if (card.fromIsland) {
            Island.settingsScreen = name
            Island.settingsOpen = true
          }
          // From the rest size, then out on the spring
          Qt.callLater(function() {
            card.animate = !Style.reduceMotion
            card.grown = true
            contentIn.restart()
          })
          keyCatcher.forceActiveFocus()
        }

        function end() {
          contentIn.stop()
          card.contentShown = false
          card.grown = false
          closeFallback.restart()
          card.checkClosed()
        }

        // Shrunk back into the island (or faded out): hand it back
        function checkClosed() {
          if (root.opened || !root.windowShown) return
          // Off the island it fades out over the fallback's interval
          var settled = !card.animate
            || card.fromIsland && Math.abs(card.width - card.restWidth) < 1.5 && Math.abs(card.height - card.restHeight) < 1.5
          if (!settled) return
          closeFallback.stop()
          Island.settingsOpen = false
          root.windowShown = false
          card.rest = null
        }

        Timer {
          id: contentIn
          interval: Style.duration(card.fromIsland ? 140 : 0)
          onTriggered: card.contentShown = true
        }
        Timer {
          id: closeFallback
          interval: card.fromIsland ? 800 : Style.duration(160)
          onTriggered: {
            card.animate = false
            card.checkClosed()
          }
        }

        width: grown ? fullWidth : restWidth
        height: grown ? fullHeight : restHeight
        x: fromIsland ? Math.round(rest.x + rest.width / 2 - width / 2) : Math.round((window.width - width) / 2)
        y: fromIsland ? rest.y : Math.round((window.height - height) / 2)
        clip: true
        opacity: fromIsland ? 1 : (grown ? 1 : 0)
        scale: fromIsland ? 1 : (grown ? 1 : 0.96)

        Behavior on width {
          enabled: card.animate && card.fromIsland
          SpringAnimation { spring: 3.2; damping: 0.38; epsilon: 0.5 }
        }
        Behavior on height {
          enabled: card.animate && card.fromIsland
          SpringAnimation { spring: 3.2; damping: 0.38; epsilon: 0.5 }
        }
        Behavior on opacity { NumberAnimation { duration: Style.duration(140) } }
        Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
        onWidthChanged: checkClosed()
        onHeightChanged: checkClosed()

        // Off the top edge (a floating bar, or no island) it's a card of its own
        Rectangle {
          id: cardFill
          anchors.fill: parent
          visible: !card.attached
          color: card.fromIsland ? Island.panelGlass : NekoColor.popups.background
          topLeftRadius: card.attached ? 0 : Math.min(Style.space(26), height / 2)
          topRightRadius: card.attached ? 0 : Math.min(Style.space(26), height / 2)
          bottomLeftRadius: Math.min(Style.space(26), height / 2)
          bottomRightRadius: Math.min(Style.space(26), height / 2)
          border.width: card.fromIsland ? 0 : 1
          border.color: NekoColor.popups.border
        }

        // Swallow clicks so only outside the card closes it
        MouseArea { anchors.fill: parent }

        // Laid out at full size from the start, so nothing reflows as the
        // card grows; the card clips it
        Flickable {
          id: scroller
          x: Math.round((card.width - card.fullWidth) / 2)
          y: 0
          width: card.fullWidth
          height: card.fullHeight
          contentWidth: width
          contentHeight: page.implicitHeight + Style.space(40)
          interactive: contentHeight > height
          boundsBehavior: Flickable.StopAtBounds
          clip: true
          opacity: card.contentShown ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: Style.duration(card.contentShown ? 200 : 60) } }

          ColumnLayout {
            id: page
            x: Style.space(24)
            y: Style.space(card.attached ? 16 : 20)
            width: card.fullWidth - Style.space(48)
            spacing: Style.space(10)

            RowLayout {
              Layout.fillWidth: true
              Text {
                Layout.fillWidth: true
                text: "Settings"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                font.weight: Font.DemiBold
              }
              PanelActionButton {
                iconText: "\u{F0156}"
                tooltipText: "Close"
                foreground: root.foreground
                onClicked: root.close()
              }
            }

            // The tabs
            Row {
              Layout.fillWidth: true
              Layout.bottomMargin: Style.space(4)
              spacing: Style.space(4)

              Repeater {
                model: root.tabs
                Rectangle {
                  id: tabChip
                  required property var modelData
                  readonly property bool current: root.tab === modelData.id
                  width: Math.floor((page.width - Style.space(4) * (root.tabs.length - 1)) / root.tabs.length)
                  height: Style.space(52)
                  radius: Style.space(14)
                  color: current ? Util.alpha(root.accent, 0.2)
                    : tabMouse.containsMouse ? Util.alpha(root.foreground, 0.08) : Util.alpha(root.foreground, 0.04)
                  Behavior on color { ColorAnimation { duration: Style.duration(120) } }

                  Column {
                    anchors.centerIn: parent
                    spacing: Style.space(2)
                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: tabChip.modelData.icon
                      color: tabChip.current ? root.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }
                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      text: tabChip.modelData.label
                      color: tabChip.current ? root.accent : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.tab = tabChip.modelData.id
                  }
                }
              }
            }

            // ---------------------------------------------------- Appearance
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tab === "appearance"
              spacing: Style.space(10)

              SectionTitle { text: "Colors" }
              SettingRow {
                label: "Palette"
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: [ { value: "material", label: "From wallpaper" }, { value: "neko", label: "Neko" } ]
                  value: root.settings.colors
                  onChanged: function(v) { root.run(["neko-settings", "set", "colors", v]) }
                }
              }

              SectionTitle { text: "Text" }
              SettingRow {
                label: "Font"
                Dropdown {
                  width: Style.space(260)
                  showLabel: false
                  foreground: root.foreground
                  options: root.fonts
                  value: root.settings.font
                  onChanged: function(v) { root.run(["neko-font-set", v]) }
                }
              }
              SettingRow {
                label: "Size"
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: [ { value: "11", label: "Small" }, { value: "12", label: "Default" }, { value: "14", label: "Large" }, { value: "16", label: "Larger" } ]
                  value: String(root.settings.textSize || "")
                  onChanged: function(v) { root.run(v === "12" ? ["neko-display-text-size", "reset"] : ["neko-display-text-size", v]) }
                }
              }
            }

            // ---------------------------------------------------------- Bar
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tab === "bar"
              spacing: Style.space(10)

              // Each choice drawn on a little screen, the bar's widgets on it
              SectionTitle { text: "Layout" }
              Flow {
                Layout.fillWidth: true
                spacing: Style.space(10)
                visible: (root.bar.presets || []).length > 0
                Repeater {
                  model: root.bar.presets || []
                  BarPreview {
                    required property var modelData
                    width: Math.floor((page.width - Style.space(20)) / 3)
                    barStyle: modelData.style
                    position: "top"
                    layout: modelData.layout
                    label: root.barLayoutLabel(modelData.name)
                    current: root.settings.barLayout === modelData.name
                    removable: modelData.source === "saved"
                    onPicked: root.run(["neko-bar", "layout", "use", modelData.name])
                    onRemoved: root.run(["neko-bar", "layout", "delete", modelData.name])
                  }
                }
              }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                TextField {
                  id: presetName
                  Layout.preferredWidth: Style.space(240)
                  foreground: root.foreground
                  placeholderText: "Save this layout as..."
                  validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9][A-Za-z0-9._-]*/ }
                  onAccepted: savePreset.clicked()
                }
                Button {
                  id: savePreset
                  text: "Save"
                  bordered: true
                  foreground: root.foreground
                  enabled: presetName.text.length > 0
                  onClicked: {
                    if (!enabled) return
                    root.run(["neko-bar", "layout", "save", presetName.text])
                    presetName.text = ""
                  }
                }
              }

              SectionTitle { text: "Style" }
              Row {
                spacing: Style.space(10)
                Repeater {
                  model: [ { value: "docked", label: "Docked" }, { value: "floating", label: "Floating" }, { value: "attached", label: "Attached" } ]
                  BarPreview {
                    required property var modelData
                    width: Math.floor((page.width - Style.space(20)) / 3)
                    barStyle: modelData.value
                    position: "top"
                    label: modelData.label
                    current: (root.settings.barStyle || (root.settings.barFloat ? "floating" : "docked")) === modelData.value
                    onPicked: root.run(["neko-settings", "set", "bar.style", modelData.value])
                  }
                }
              }
              SettingRow {
                label: "Glass"
                ToggleSwitch {
                  foreground: root.foreground
                  checked: root.settings.barGlass
                  onToggled: root.run(["neko-settings", "toggle", "bar.glass"])
                }
              }
              SettingRow {
                label: "Capsules"
                ToggleSwitch {
                  foreground: root.foreground
                  checked: root.settings.barCapsules
                  onToggled: root.run(["neko-settings", "toggle", "bar.capsules"])
                }
              }

              SectionTitle { text: "Position" }
              Row {
                spacing: Style.space(10)
                Repeater {
                  model: [ { value: "top", label: "Top" }, { value: "bottom", label: "Bottom" }, { value: "left", label: "Left" }, { value: "right", label: "Right" } ]
                  BarPreview {
                    required property var modelData
                    width: Math.floor((page.width - Style.space(30)) / 4)
                    // Only a top bar hangs from its edge; elsewhere it floats
                    barStyle: root.settings.barStyle === "attached" && modelData.value !== "top" ? "floating" : (root.settings.barStyle || "floating")
                    position: modelData.value
                    label: modelData.label
                    current: root.settings.barPosition === modelData.value
                    onPicked: root.run(["neko-bar", "position", modelData.value])
                  }
                }
              }
            }

            // ------------------------------------------------------ Widgets
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tab === "widgets"
              spacing: Style.space(10)

              SectionTitle { text: "On the bar" }
              Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "Drag a widget to move it, within its side of the bar or to another. Click one for its options."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // The bar's three sections side by side, first to last top down
              Item {
                id: editor
                Layout.fillWidth: true
                implicitHeight: zones.height

                readonly property real chipHeight: Style.space(32)
                readonly property real chipGap: Style.space(4)
                readonly property real headerHeight: Style.space(18)
                readonly property real chipsTop: Style.space(10) + headerHeight + chipGap
                readonly property real zoneWidth: (width - Style.space(8) * 2) / 3
                readonly property int mostChips: Math.max((root.bar.layout.left || []).length, (root.bar.layout.center || []).length, (root.bar.layout.right || []).length)
                readonly property var sectionIds: ["left", "center", "right"]

                // While dragging: where from, and where it would land (the
                // index counts the section without the dragged widget)
                property var dragFrom: null
                property string dragName: ""
                property point dragPoint: Qt.point(0, 0)
                property string dropSection: ""
                property int dropIndex: -1

                function zoneX(section) { return sectionIds.indexOf(section) * (zoneWidth + Style.space(8)) }
                function rowY(row) { return chipsTop + row * (chipHeight + chipGap) }

                function beginDrag(section, index, name) {
                  dragFrom = { section: section, index: index }
                  dragName = name
                }
                function dragTo(point) {
                  dragPoint = point
                  var column = Math.max(0, Math.min(2, Math.floor(point.x / (zoneWidth + Style.space(8)))))
                  var section = sectionIds[column]
                  var count = (root.bar.layout[section] || []).length
                  var index = 0
                  for (var i = 0; i < count; i++) {
                    if (dragFrom && dragFrom.section === section && dragFrom.index === i) continue
                    if (rowY(i) + chipHeight / 2 < point.y) index++
                  }
                  dropSection = section
                  dropIndex = index
                }
                function drop() {
                  if (dragFrom && dropSection !== "")
                    root.moveWidget(dragFrom.section, dragFrom.index, dropSection, dropIndex)
                  cancelDrag()
                }
                function cancelDrag() {
                  dragFrom = null
                  dropSection = ""
                  dropIndex = -1
                }
                // The row the drop line sits above, in the section as drawn
                function dropRow() {
                  if (dropSection === "") return 0
                  var rows = []
                  var count = (root.bar.layout[dropSection] || []).length
                  for (var i = 0; i < count; i++)
                    if (!(dragFrom && dragFrom.section === dropSection && dragFrom.index === i)) rows.push(i)
                  return dropIndex < rows.length ? rows[dropIndex] : (rows.length > 0 ? rows[rows.length - 1] + 1 : 0)
                }

                Item {
                  id: zones
                  width: parent.width
                  height: editor.rowY(Math.max(editor.mostChips, 3)) + Style.space(6)

                  Repeater {
                    model: [ { id: "left", label: "Left" }, { id: "center", label: "Center" }, { id: "right", label: "Right" } ]
                    Rectangle {
                      id: zone
                      required property var modelData
                      readonly property string section: modelData.id
                      readonly property var entries: root.bar.layout[section] || []
                      x: editor.zoneX(section)
                      width: editor.zoneWidth
                      height: zones.height
                      radius: Style.space(14)
                      color: editor.dropSection === section ? Util.alpha(root.accent, 0.1) : Util.alpha(root.foreground, 0.04)
                      border.width: editor.dropSection === section ? 1 : 0
                      border.color: Util.alpha(root.accent, 0.5)

                      Text {
                        x: Style.space(10)
                        y: Style.space(10)
                        height: editor.headerHeight
                        text: zone.modelData.label + (root.sidesGrouped(zone.section) && zone.entries.length > 0 ? " · one capsule" : "")
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        visible: zone.entries.length === 0
                        x: Style.space(10)
                        y: editor.chipsTop + Style.space(6)
                        text: "Empty"
                        color: Util.alpha(root.foreground, 0.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Repeater {
                        model: zone.entries
                        Item {
                          id: chip
                          required property var modelData
                          required property int index
                          readonly property string widgetId: root.entryId(modelData)
                          readonly property bool isPicked: !!root.picked && root.picked.section === zone.section && root.picked.index === index
                          readonly property bool isDragged: !!editor.dragFrom && editor.dragFrom.section === zone.section && editor.dragFrom.index === index
                          readonly property bool joinsNext: root.sharesNext(zone.section, index)
                          readonly property bool joinsPrevious: index > 0 && root.sharesNext(zone.section, index - 1)
                          x: Style.space(6)
                          y: editor.rowY(index)
                          width: zone.width - Style.space(12)
                          height: editor.chipHeight

                          // Widgets sharing a capsule are drawn joined
                          Rectangle {
                            x: Style.space(3)
                            y: chip.joinsPrevious ? -editor.chipGap : 0
                            width: Style.space(3)
                            height: parent.height + (chip.joinsPrevious ? editor.chipGap : 0) + (chip.joinsNext ? editor.chipGap : 0)
                            radius: width / 2
                            visible: chip.joinsNext || chip.joinsPrevious
                            color: Util.alpha(root.accent, 0.6)
                          }
                          Rectangle {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(9)
                            radius: Style.space(10)
                            opacity: chip.isDragged ? 0.35 : 1
                            color: chip.isPicked ? Util.alpha(root.accent, 0.24)
                              : chipMouse.containsMouse ? Util.alpha(root.foreground, 0.13) : Util.alpha(root.foreground, 0.08)
                            Behavior on color { ColorAnimation { duration: Style.duration(100) } }

                            Text {
                              id: grip
                              anchors.left: parent.left
                              anchors.leftMargin: Style.space(4)
                              anchors.verticalCenter: parent.verticalCenter
                              text: "\u{F01D9}"
                              color: Util.alpha(root.foreground, 0.4)
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                            }
                            Text {
                              anchors.left: grip.right
                              anchors.leftMargin: Style.space(4)
                              anchors.right: parent.right
                              anchors.rightMargin: Style.space(8)
                              anchors.verticalCenter: parent.verticalCenter
                              text: root.widgetInfo(chip.widgetId).name
                              elide: Text.ElideRight
                              color: chip.isPicked ? root.accent : root.foreground
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.bodySmall
                            }
                          }

                          MouseArea {
                            id: chipMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            preventStealing: true
                            cursorShape: editor.dragFrom ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            property point pressAt: Qt.point(0, 0)
                            property bool moved: false
                            onPressed: function(mouse) {
                              pressAt = Qt.point(mouse.x, mouse.y)
                              moved = false
                            }
                            onPositionChanged: function(mouse) {
                              if (!pressed) return
                              if (!moved && Math.abs(mouse.x - pressAt.x) + Math.abs(mouse.y - pressAt.y) < Style.space(6)) return
                              if (!moved) {
                                moved = true
                                editor.beginDrag(zone.section, chip.index, root.widgetInfo(chip.widgetId).name)
                              }
                              editor.dragTo(chip.mapToItem(editor, mouse.x, mouse.y))
                            }
                            onReleased: {
                              if (moved) editor.drop()
                              else root.picked = { section: zone.section, index: chip.index }
                            }
                            onCanceled: editor.cancelDrag()
                          }
                        }
                      }
                    }
                  }

                  // Where it would land
                  Rectangle {
                    visible: editor.dropSection !== ""
                    x: editor.zoneX(editor.dropSection) + Style.space(14)
                    y: editor.rowY(editor.dropRow()) - editor.chipGap / 2 - height / 2
                    width: editor.zoneWidth - Style.space(22)
                    height: Style.space(3)
                    radius: height / 2
                    color: root.accent
                  }

                  // The widget in hand
                  Rectangle {
                    visible: editor.dragFrom !== null
                    z: 10
                    width: editor.zoneWidth - Style.space(21)
                    height: editor.chipHeight
                    x: editor.dragPoint.x - width / 2
                    y: editor.dragPoint.y - height / 2
                    radius: Style.space(10)
                    color: Util.alpha(root.accent, 0.35)
                    border.width: 1
                    border.color: root.accent
                    Text {
                      anchors.centerIn: parent
                      width: parent.width - Style.space(16)
                      horizontalAlignment: Text.AlignHCenter
                      text: editor.dragName
                      elide: Text.ElideRight
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }
              }

              // Putting another widget on the bar, at its usual place
              Dropdown {
                id: addWidget
                Layout.preferredWidth: Style.space(280)
                showLabel: false
                foreground: root.foreground
                value: ""
                options: [ { value: "", label: "Add a widget..." } ].concat((root.bar.widgets || [])
                  .filter(function(w) { return w.allowMultiple || !root.onBar(w.id) })
                  .sort(function(a, b) { return a.name.localeCompare(b.name) })
                  .map(function(w) { return { value: w.id, label: w.name } }))
                onChanged: function(v) {
                  if (v !== "") root.run(["neko-bar", "put", v])
                  addWidget.value = ""
                }
              }

              // The picked widget: where it sits and what it shows
              Rectangle {
                Layout.fillWidth: true
                visible: root.pickedEntry !== undefined
                implicitHeight: pickedColumn.implicitHeight + Style.space(28)
                radius: Style.space(14)
                color: Util.alpha(root.foreground, 0.05)

                ColumnLayout {
                  id: pickedColumn
                  x: Style.space(14)
                  y: Style.space(14)
                  width: parent.width - Style.space(28)
                  spacing: Style.space(10)

                  RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(2)
                      Text {
                        text: root.pickedInfo.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.weight: Font.DemiBold
                      }
                      Text {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: root.pickedInfo.description || ""
                        wrapMode: Text.Wrap
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                    PanelActionButton {
                      iconText: "\u{F01B4}"
                      tooltipText: "Take it off the bar"
                      foreground: root.foreground
                      onClicked: root.removeWidget(root.picked.section, root.picked.index)
                    }
                  }

                  SettingRow {
                    label: "Side"
                    ButtonGroup {
                      foreground: root.foreground
                      background: "transparent"
                      options: [ { value: "left", label: "Left" }, { value: "center", label: "Center" }, { value: "right", label: "Right" } ]
                      value: root.picked ? root.picked.section : ""
                      onChanged: function(v) {
                        if (!root.picked || v === root.picked.section) return
                        root.moveWidget(root.picked.section, root.picked.index, v, (root.bar.layout[v] || []).length)
                      }
                    }
                  }
                  SettingRow {
                    label: "Order"
                    Row {
                      spacing: Style.space(6)
                      Button {
                        text: "Earlier"
                        bordered: true
                        foreground: root.foreground
                        enabled: !!root.picked && root.picked.index > 0
                        onClicked: root.moveWidget(root.picked.section, root.picked.index, root.picked.section, root.picked.index - 1)
                      }
                      Button {
                        text: "Later"
                        bordered: true
                        foreground: root.foreground
                        enabled: !!root.picked && root.picked.index + 1 < (root.bar.layout[root.picked.section] || []).length
                        onClicked: root.moveWidget(root.picked.section, root.picked.index, root.picked.section, root.picked.index + 1)
                      }
                    }
                  }
                  SettingRow {
                    label: "Joined to next"
                    visible: !!root.picked && !root.sidesGrouped(root.picked.section)
                      && root.picked.index + 1 < (root.bar.layout[root.picked.section] || []).length
                    ToggleSwitch {
                      foreground: root.foreground
                      checked: !!root.picked && root.sharesNext(root.picked.section, root.picked.index)
                      onToggled: root.setSharesNext(root.picked.section, root.picked.index, !checked)
                    }
                  }

                  // Whatever else the widget lets you change
                  Repeater {
                    model: root.pickedEntry !== undefined ? (root.pickedInfo.schema || []) : []
                    SettingRow {
                      id: optionRow
                      required property var modelData
                      readonly property var stored: root.entryValue(root.pickedEntry, modelData.key)
                      readonly property var shown: stored === undefined || stored === null ? modelData.defaultValue : stored
                      label: modelData.label || modelData.key

                      Loader {
                        sourceComponent: optionRow.modelData.type === "boolean" ? boolOption
                          : optionRow.modelData.type === "enum" ? enumOption
                          : optionRow.modelData.type === "multiselect" ? multiOption
                          : textOption

                        Component {
                          id: boolOption
                          ToggleSwitch {
                            foreground: root.foreground
                            checked: optionRow.shown === true
                            onToggled: root.setOption(root.picked.section, root.picked.index, optionRow.modelData.key, !(optionRow.shown === true))
                          }
                        }
                        Component {
                          id: enumOption
                          ButtonGroup {
                            foreground: root.foreground
                            background: "transparent"
                            options: (optionRow.modelData.options || []).map(function(o) { return typeof o === "object" ? o : { value: String(o), label: String(o) } })
                            value: String(optionRow.shown === undefined ? "" : optionRow.shown)
                            onChanged: function(v) { root.setOption(root.picked.section, root.picked.index, optionRow.modelData.key, v) }
                          }
                        }
                        Component {
                          id: multiOption
                          Flow {
                            width: Style.space(320)
                            spacing: Style.space(6)
                            Repeater {
                              model: optionRow.modelData.options || []
                              Button {
                                required property var modelData
                                readonly property var chosen: Array.isArray(optionRow.shown) ? optionRow.shown : []
                                text: modelData.label || modelData.value
                                bordered: true
                                selected: chosen.indexOf(modelData.value) >= 0
                                foreground: root.foreground
                                onClicked: {
                                  var next = chosen.filter(function(v) { return v !== modelData.value })
                                  if (!selected) next.push(modelData.value)
                                  root.setOption(root.picked.section, root.picked.index, optionRow.modelData.key, next)
                                }
                              }
                            }
                          }
                        }
                        Component {
                          id: textOption
                          RowLayout {
                            spacing: Style.space(8)
                            readonly property bool numeric: optionRow.modelData.type === "integer" || optionRow.modelData.type === "number"
                            function save() {
                              var value = optionField.text.trim()
                              if (value === "") root.setOption(root.picked.section, root.picked.index, optionRow.modelData.key, null)
                              else root.setOption(root.picked.section, root.picked.index, optionRow.modelData.key, numeric ? Number(value) : value)
                            }
                            TextField {
                              id: optionField
                              Layout.preferredWidth: Style.space(220)
                              foreground: root.foreground
                              text: optionRow.stored === undefined || optionRow.stored === null ? "" : String(optionRow.stored)
                              placeholderText: optionRow.modelData.defaultValue === undefined ? "" : String(optionRow.modelData.defaultValue)
                              inputMethodHints: parent.numeric ? Qt.ImhDigitsOnly : Qt.ImhNone
                              onAccepted: parent.save()
                            }
                            Button {
                              text: "Set"
                              bordered: true
                              foreground: root.foreground
                              enabled: optionField.text !== (optionRow.stored === undefined || optionRow.stored === null ? "" : String(optionRow.stored))
                              onClicked: parent.save()
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }

            // ---------------------------------------------------- Wallpaper
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tab === "wallpaper"
              spacing: Style.space(10)

              SectionTitle { text: "Wallpaper" }
              SettingRow {
                label: "Change"
                RowLayout {
                  spacing: Style.space(8)
                  Button {
                    text: "Pick..."
                    bordered: true
                    foreground: root.foreground
                    onClicked: {
                      root.close()
                      root.run(["neko-wallpaper", "pick"])
                    }
                  }
                  Button {
                    text: "Random"
                    bordered: true
                    foreground: root.foreground
                    onClicked: root.run(["neko-wallpaper", "random"])
                  }
                }
              }
              SettingRow {
                label: "Rotate"
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: [ { value: "off", label: "Off" }, { value: "15", label: "15 min" }, { value: "30", label: "30 min" }, { value: "60", label: "1 hour" } ]
                  value: root.settings.rotation
                  onChanged: function(v) { root.run(["neko-wallpaper", "auto", v]) }
                }
              }
            }

            // ------------------------------------------------------- System
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tab === "system"
              spacing: Style.space(10)

              SectionTitle { text: "Power" }
              SettingRow {
                label: "Profile"
                visible: (root.settings.powerProfiles || []).length > 0
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: (root.settings.powerProfiles || []).map(function(p) { return { value: p, label: root.profileNames[p] || p } })
                  value: root.settings.powerProfile
                  onChanged: function(v) { root.run(["neko-powerprofiles-set", "autodetect", v]) }
                }
              }
              SettingRow {
                label: "Charge limit"
                visible: root.settings.chargeLimit > 0
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: [ { value: "60", label: "60%" }, { value: "80", label: "80%" }, { value: "100", label: "Full" } ]
                  value: String(root.settings.chargeLimit)
                  onChanged: function(v) { root.run(["neko-battery-limit", "set", v]) }
                }
              }
              SettingRow {
                label: "Stay awake"
                ToggleSwitch {
                  foreground: root.foreground
                  checked: root.settings.stayAwake
                  onToggled: root.run(["neko-toggle-idle", "toggle"])
                }
              }

              SectionTitle { text: "Notifications" }
              SettingRow {
                label: "Do not disturb"
                ToggleSwitch {
                  foreground: root.foreground
                  checked: root.settings.dnd
                  onToggled: root.run(["neko-shell", "notifications", "toggleDnd"])
                }
              }

              SectionTitle { text: "Network" }
              // Changing it asks for your password (or face) through polkit
              SettingRow {
                label: "DNS"
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: [ { value: "DHCP", label: "Automatic" }, { value: "Cloudflare", label: "Cloudflare" }, { value: "Google", label: "Google" } ]
                  value: root.settings.dns
                  onChanged: function(v) { root.run(["neko-dns", v]) }
                }
              }

              SectionTitle { text: "Time and place" }
              SettingRow {
                label: "Weather"
                RowLayout {
                  spacing: Style.space(8)
                  TextField {
                    id: weatherField
                    Layout.preferredWidth: Style.space(220)
                    foreground: root.foreground
                    placeholderText: "Automatic (from your IP)"
                    text: root.settings.weather
                    onAccepted: if (text.trim() !== "") root.run(["neko-weather-location", "--set", text.trim()])
                  }
                  Button {
                    text: "Set"
                    bordered: true
                    foreground: root.foreground
                    enabled: weatherField.text.trim() !== "" && weatherField.text.trim() !== root.settings.weather
                    onClicked: root.run(["neko-weather-location", "--set", weatherField.text.trim()])
                  }
                  Button {
                    text: "Auto"
                    bordered: true
                    foreground: root.foreground
                    visible: root.settings.weather !== ""
                    onClicked: {
                      weatherField.text = ""
                      root.run(["neko-weather-location", "--clear"])
                    }
                  }
                }
              }
              SettingRow {
                label: "Timezone"
                Button {
                  text: "Change..."
                  bordered: true
                  foreground: root.foreground
                  onClicked: {
                    root.close()
                    root.run(["neko-menu-timezone"])
                  }
                }
              }
            }

            // ---------------------------------------------------- Calendars
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tab === "calendars"
              spacing: Style.space(10)

              SectionTitle { text: "Shown in the control center" }

              Repeater {
                model: root.settings.calendars || []
                Rectangle {
                  required property var modelData
                  required property int index
                  Layout.fillWidth: true
                  implicitHeight: Style.space(52)
                  radius: Style.space(14)
                  color: Util.alpha(root.foreground, 0.05)

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(14)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(10)
                    Text {
                      text: "\u{F00ED}"
                      color: root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.icon
                    }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0
                      Text {
                        Layout.fillWidth: true
                        text: modelData.name || "Calendar"
                        color: root.foreground
                        elide: Text.ElideRight
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }
                      Text {
                        Layout.fillWidth: true
                        // The address is a secret; enough of it to tell them apart
                        text: String(modelData.url || "").replace(/^(https?:\/\/[^\/]+).*$/, "$1/…")
                        color: root.dim
                        elide: Text.ElideMiddle
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                    PanelActionButton {
                      iconText: "\u{F01B4}"
                      tooltipText: "Remove"
                      foreground: root.foreground
                      onClicked: root.run(["neko-calendars", "remove", String(index + 1)])
                    }
                  }
                }
              }

              Text {
                visible: (root.settings.calendars || []).length === 0
                text: "No calendars yet"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              SectionTitle { text: "Add one" }
              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                TextField {
                  id: calendarName
                  Layout.preferredWidth: Style.space(140)
                  foreground: root.foreground
                  placeholderText: "Name"
                }
                TextField {
                  id: calendarUrl
                  Layout.fillWidth: true
                  foreground: root.foreground
                  placeholderText: "iCal address (https://...ics)"
                  onAccepted: addCalendar.clicked()
                }
                Button {
                  id: addCalendar
                  text: "Add"
                  bordered: true
                  foreground: root.foreground
                  enabled: /^(https?|webcal):\/\//.test(calendarUrl.text.trim())
                  onClicked: {
                    if (!enabled) return
                    root.run(["neko-calendars", "add", calendarName.text.trim() || "Calendar", calendarUrl.text.trim()])
                    calendarName.text = ""
                    calendarUrl.text = ""
                  }
                }
              }
              Text {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "For Google Calendar: Settings, then the calendar under \"Settings for my calendars\", then \"Integrate calendar\", and copy the \"Secret address in iCal format\". Anyone with it can read the calendar, so it stays in a file only you can read."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // --------------------------------------------------------- Apps
            ColumnLayout {
              Layout.fillWidth: true
              visible: root.tab === "apps"
              spacing: Style.space(10)

              SectionTitle { text: "Themed apps" }
              Repeater {
                model: [ { app: "gtk", label: "GTK apps" }, { app: "btop", label: "btop" }, { app: "tmux", label: "tmux" }, { app: "kitty", label: "kitty" } ]
                delegate: SettingRow {
                  required property var modelData
                  label: modelData.label
                  ToggleSwitch {
                    foreground: root.foreground
                    checked: root.hasApp(modelData.app)
                    onToggled: root.run(["neko-settings", "toggle", "app." + modelData.app])
                  }
                }
              }

              SectionTitle {
                text: "Default agent"
                visible: root.settings.agents && root.settings.agents.length > 0
              }
              SettingRow {
                label: "Agent"
                visible: root.settings.agents && root.settings.agents.length > 0
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: (root.settings.agents || []).map(function(a) { return { value: a, label: root.agentNames[a] || a } })
                  value: root.settings.agent
                  onChanged: function(v) { root.run(["neko-default-agent", v]) }
                }
              }
            }
          }
        }
      }
    }
  }

  // A little screen with the bar drawn on it: its style, the edge it's on
  // and the widgets it holds, a dot each, in their capsules
  component BarPreview: Item {
    id: preview
    property string barStyle: "floating"
    property string position: "top"
    // { left, center, right } as in shell.json; the bar's own when unset
    property var layout: null
    property bool current: false
    property bool removable: false
    property string label: ""
    property bool deleteHovered: false
    signal picked()
    signal removed()

    readonly property bool vertical: position === "left" || position === "right"
    readonly property bool hanging: barStyle === "attached" && position === "top"
    readonly property real thickness: Style.space(10)
    readonly property real margin: barStyle === "docked" || hanging ? 0 : Style.space(4)
    readonly property real dot: Style.space(4)
    readonly property var source: layout || root.bar.layout
    implicitHeight: screen.height + Style.space(22)

    Rectangle {
      id: screen
      width: preview.width
      height: Math.round(preview.width * 0.62)
      radius: Style.space(10)
      clip: true
      color: Util.alpha(root.foreground, preview.current ? 0.1 : 0.04)
      border.width: preview.current ? 2 : 1
      border.color: preview.current ? root.accent : previewMouse.containsMouse ? Util.alpha(root.foreground, 0.3) : Util.alpha(root.foreground, 0.12)
      Behavior on border.color { ColorAnimation { duration: Style.duration(100) } }

      readonly property real barX: preview.position === "right" ? width - preview.margin - preview.thickness : preview.margin
      readonly property real barY: preview.position === "bottom" ? height - preview.margin - preview.thickness : preview.margin
      readonly property real barLength: (preview.vertical ? height : width) - preview.margin * 2

      // A window, in the room the bar leaves
      Rectangle {
        readonly property real reach: preview.thickness + preview.margin * 2 + Style.space(3)
        x: preview.position === "left" ? reach : Style.space(6)
        y: preview.position === "top" ? reach : Style.space(6)
        width: screen.width - Style.space(6) - x - (preview.position === "right" ? reach : Style.space(6))
        height: screen.height - Style.space(6) - y - (preview.position === "bottom" ? reach : Style.space(6))
        radius: Style.space(4)
        color: Util.alpha(root.foreground, 0.06)
      }

      // Docked and floating bars have a strip of their own
      Rectangle {
        visible: !preview.hanging
        x: preview.vertical ? screen.barX : preview.margin
        y: preview.vertical ? preview.margin : screen.barY
        width: preview.vertical ? preview.thickness : screen.barLength
        height: preview.vertical ? screen.barLength : preview.thickness
        radius: preview.barStyle === "docked" ? 0 : preview.thickness / 2
        color: Util.alpha(root.foreground, preview.barStyle === "docked" ? 0.16 : 0.07)
      }

      Repeater {
        model: ["left", "center", "right"]
        Grid {
          id: previewSection
          required property string modelData
          readonly property var counts: root.capsuleCounts(preview.source[modelData] || [], preview.hanging && modelData !== "center")
          readonly property real inset: preview.hanging ? 0 : Style.space(2)
          columns: preview.vertical ? 1 : Math.max(1, counts.length)
          spacing: Style.space(3)
          x: preview.vertical ? screen.barX + Style.space(1)
            : modelData === "left" ? preview.margin + inset
            : modelData === "right" ? screen.width - preview.margin - inset - width
            : Math.round((screen.width - width) / 2)
          y: !preview.vertical ? (preview.hanging ? 0 : screen.barY + Style.space(1))
            : modelData === "left" ? preview.margin + inset
            : modelData === "right" ? screen.height - preview.margin - inset - height
            : Math.round((screen.height - height) / 2)

          Repeater {
            model: previewSection.counts
            Rectangle {
              required property int modelData
              readonly property real run: modelData * preview.dot + (modelData - 1) * Style.space(2) + Style.space(6)
              readonly property real across: preview.hanging ? preview.thickness + Style.space(1) : preview.thickness - Style.space(2)
              width: preview.vertical ? across : run
              height: preview.vertical ? run : across
              topLeftRadius: preview.hanging ? 0 : Math.min(width, height) / 2
              topRightRadius: preview.hanging ? 0 : Math.min(width, height) / 2
              bottomLeftRadius: Math.min(width, height) / 2
              bottomRightRadius: Math.min(width, height) / 2
              color: Util.alpha(root.foreground, preview.barStyle === "docked" ? 0.18 : 0.3)

              Grid {
                anchors.centerIn: parent
                columns: preview.vertical ? 1 : parent.modelData
                spacing: Style.space(2)
                Repeater {
                  model: parent.parent.modelData
                  Rectangle {
                    width: preview.dot
                    height: preview.dot
                    radius: width / 2
                    color: Util.alpha(root.foreground, 0.8)
                  }
                }
              }
            }
          }
        }
      }
    }

    Text {
      anchors.horizontalCenter: screen.horizontalCenter
      anchors.top: screen.bottom
      anchors.topMargin: Style.space(4)
      text: preview.label
      color: preview.current ? root.accent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.weight: preview.current ? Font.DemiBold : Font.Normal
    }

    MouseArea {
      id: previewMouse
      anchors.fill: screen
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: preview.picked()
    }

    PanelActionButton {
      visible: preview.removable && (previewMouse.containsMouse || preview.deleteHovered)
      anchors.right: screen.right
      anchors.top: screen.top
      anchors.margins: Style.space(2)
      iconText: "\u{F0156}"
      tooltipText: "Delete this layout"
      foreground: root.foreground
      onHovered: function(isHovered) { preview.deleteHovered = isHovered }
      onClicked: preview.removed()
    }
  }

  component SectionTitle: Text {
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.weight: Font.DemiBold
    font.capitalization: Font.AllUppercase
    font.letterSpacing: 1
    Layout.topMargin: Style.space(6)
  }

  component SettingRow: RowLayout {
    property string label: ""
    default property alias control: slot.data

    Layout.fillWidth: true
    spacing: Style.space(12)

    Text {
      text: parent.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      Layout.preferredWidth: root.labelWidth
    }

    Item {
      id: slot
      Layout.fillWidth: true
      implicitHeight: childrenRect.height
      implicitWidth: childrenRect.width
    }
  }
}
