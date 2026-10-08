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

  // On glass the card is dark whatever the theme, so its text stays light
  readonly property color foreground: settings.barGlass ? "#f2f2f2" : NekoColor.popups.text
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color accent: NekoColor.accent
  readonly property string fontFamily: Style.font.family
  readonly property int labelWidth: Style.space(140)

  readonly property var tabs: [
    { id: "appearance", label: "Appearance", icon: "\u{F03D8}" },
    { id: "bar", label: "Bar", icon: "\u{F035C}" },
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

        readonly property real fullWidth: Style.space(620)
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

              SectionTitle { text: "Layout" }
              SettingRow {
                label: "Preset"
                visible: (root.settings.barLayouts || []).length > 0
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: (root.settings.barLayouts || []).map(function(name) {
                    return { value: name, label: root.barLayoutLabel(name) }
                  })
                  value: root.settings.barLayout
                  onChanged: function(v) { root.run(["neko-bar", "layout", "use", v]) }
                }
              }

              SectionTitle { text: "Look" }
              // Docked along the edge, floating off it, or hanging from the
              // top edge with the dynamic island
              SettingRow {
                label: "Style"
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: [ { value: "docked", label: "Docked" }, { value: "floating", label: "Floating" }, { value: "attached", label: "Attached" } ]
                  value: root.settings.barStyle || (root.settings.barFloat ? "floating" : "docked")
                  onChanged: function(v) { root.run(["neko-settings", "set", "bar.style", v]) }
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

              SectionTitle { text: "Place" }
              SettingRow {
                label: "Position"
                ButtonGroup {
                  foreground: root.foreground
                  background: "transparent"
                  options: [ { value: "top", label: "Top" }, { value: "bottom", label: "Bottom" }, { value: "left", label: "Left" }, { value: "right", label: "Right" } ]
                  value: root.settings.barPosition
                  onChanged: function(v) { root.run(["neko-bar", "position", v]) }
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
