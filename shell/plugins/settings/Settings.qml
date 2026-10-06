import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The settings window: a translucent card centered over a light scrim. Every
// control runs the same command the Settings menu does (neko-settings,
// neko-bar, neko-wallpaper, neko-default-agent) and the window re-reads the
// state from `neko-settings json` once it finishes, so the two never disagree.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property var settings: ({
    colors: "", barFloat: true, barCapsules: true, barPosition: "top",
    rotation: "off", apps: [], agent: "", agents: []
  })

  readonly property color foreground: NekoColor.popups.text
  readonly property color dim: Util.alpha(NekoColor.popups.text, 0.6)
  readonly property string fontFamily: Style.font.family
  readonly property int labelWidth: Style.space(150)

  readonly property var agentNames: ({
    "claude": "Claude", "codex": "Codex", "opencode": "OpenCode", "pi": "Pi",
    "crush": "Crush", "grok": "Grok", "copilot": "Copilot", "cursor-agent": "Cursor"
  })

  function open(payloadJson) {
    root.opened = true
    root.reload()
    // The window is created hidden; take focus once it maps so Esc works
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
  }

  function reload() {
    if (!stateProc.running) stateProc.running = true
  }

  function run(command) {
    if (actionProc.running) return
    actionProc.command = ["bash", "-c", command]
    actionProc.running = true
  }

  function hasApp(app) {
    return root.settings.apps && root.settings.apps.indexOf(app) >= 0
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
    id: actionProc
    onExited: root.reload()
  }

  OverlayWindow {
    shown: root.opened
    WlrLayershell.namespace: "neko-settings"

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(NekoColor.menu.scrim, 0.35)

      MouseArea {
        anchors.fill: parent
        onClicked: root.close()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()

      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: Style.space(520)
        height: content.implicitHeight + Style.space(48)
        color: NekoColor.popups.background
        borderSpec: Border.flat(NekoColor.popups.border, 1)
        radius: Style.space(18)

        // Swallow clicks so only the scrim closes the window
        MouseArea { anchors.fill: parent }

        ColumnLayout {
          id: content
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(24)
          spacing: Style.space(10)

          Text {
            text: "Settings"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            font.weight: Font.DemiBold
            Layout.bottomMargin: Style.space(4)
          }

          SectionTitle { text: "Colors" }
          SettingRow {
            label: "Palette"
            ButtonGroup {
              options: [ { value: "material", label: "From wallpaper" }, { value: "neko", label: "Neko" } ]
              value: root.settings.colors
              onChanged: function(v) { root.run("neko-settings set colors " + v) }
            }
          }

          SectionTitle { text: "Bar" }
          SettingRow {
            label: "Floating"
            ToggleSwitch {
              checked: root.settings.barFloat
              onToggled: root.run("neko-settings toggle bar.float")
            }
          }
          SettingRow {
            label: "Capsules"
            ToggleSwitch {
              checked: root.settings.barCapsules
              onToggled: root.run("neko-settings toggle bar.capsules")
            }
          }
          SettingRow {
            label: "Position"
            ButtonGroup {
              options: [ { value: "top", label: "Top" }, { value: "bottom", label: "Bottom" }, { value: "left", label: "Left" }, { value: "right", label: "Right" } ]
              value: root.settings.barPosition
              onChanged: function(v) { root.run("neko-bar position " + v) }
            }
          }

          SectionTitle { text: "Wallpaper" }
          SettingRow {
            label: "Change"
            RowLayout {
              spacing: Style.space(8)
              Button {
                text: "Pick..."
                bordered: true
                onClicked: {
                  root.close()
                  root.run("neko-wallpaper pick")
                }
              }
              Button {
                text: "Random"
                bordered: true
                onClicked: root.run("neko-wallpaper random")
              }
            }
          }
          SettingRow {
            label: "Rotate"
            ButtonGroup {
              options: [ { value: "off", label: "Off" }, { value: "15", label: "15 min" }, { value: "30", label: "30 min" }, { value: "60", label: "1 hour" } ]
              value: root.settings.rotation
              onChanged: function(v) { root.run("neko-wallpaper auto " + v) }
            }
          }

          SectionTitle { text: "Themed apps" }
          Repeater {
            model: [ { app: "gtk", label: "GTK apps" }, { app: "btop", label: "btop" }, { app: "tmux", label: "tmux" }, { app: "kitty", label: "kitty" } ]
            delegate: SettingRow {
              required property var modelData
              label: modelData.label
              ToggleSwitch {
                checked: root.hasApp(modelData.app)
                onToggled: root.run("neko-settings toggle app." + modelData.app)
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
              options: (root.settings.agents || []).map(function(a) { return { value: a, label: root.agentNames[a] || a } })
              value: root.settings.agent
              onChanged: function(v) { root.run("neko-default-agent " + v) }
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
    Layout.topMargin: Style.space(8)
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
