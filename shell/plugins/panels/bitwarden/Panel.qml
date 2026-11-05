import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.Ui
import qs.Commons

// The Bitwarden vault, behind a shield in the bar: unlock it, search it, copy
// a username, password or 2FA code, and add or edit items. neko-bitwarden
// holds it unlocked in memory (bw runs only to unlock, sync and save), copies
// marked sensitive so the clipboard history skips them, and clears them.
//
// Quicker unlocks are set on the settings page: a PIN, kept by the helper
// once the master password has unlocked it; and a face or a finger, checked
// through PAM as the lock screen checks them (system-auth runs Howdy first;
// neko-lock-fingerprint reads a finger), which then unlock with the master
// password the keyring kept.
Panel {
  id: root
  moduleName: "neko.bitwarden"
  ipcTarget: "neko.bitwarden"

  // logged-out, locked, unlocked, or "" before the first answer
  property string vaultState: ""
  property string account: ""
  property var settingsState: ({})
  property var can: ({})
  property var available: ({})
  property var items: []
  property var folders: []
  property string query: ""
  property int selected: 0
  // list, edit or settings
  property string page: "list"
  // The item being edited, its fields as the editor holds them
  property var draft: ({})
  property bool showPassword: false
  property bool confirmDelete: false
  // Locked with a PIN ready: ask for it, unless the master password was asked for
  property bool useMaster: false
  // Unlocking, saving or checking a face: bw takes a few seconds
  property string busy: ""
  property string note: ""
  property bool noteBad: false

  readonly property color foreground: bar ? bar.foreground : NekoColor.foreground
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property bool pinMode: !!can.pin && !useMaster

  readonly property var shown: {
    var needle = query.trim().toLowerCase()
    var list = items.filter(function(item) {
      if (!needle) return true
      return [item.name, item.username, item.uri].some(function(text) {
        return text && String(text).toLowerCase().indexOf(needle) >= 0
      })
    })
    list.sort(function(a, b) {
      if (a.favorite !== b.favorite) return a.favorite ? -1 : 1
      return String(a.name || "").localeCompare(String(b.name || ""))
    })
    return list
  }
  readonly property var current: shown.length > 0 ? shown[Math.max(0, Math.min(selected, shown.length - 1))] : null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onQueryChanged: selected = 0
  onOpenedChanged: {
    if (!opened) {
      query = ""
      note = ""
      page = "list"
      useMaster = false
      return
    }
    refresh()
    focusFirst()
  }
  onPageChanged: focusFirst()

  function focusFirst() {
    Qt.callLater(function() {
      if (root.vaultState === "locked") secretField.forceActiveFocus()
      else if (root.page === "list") searchField.forceActiveFocus()
      else if (root.page === "edit") nameField.forceActiveFocus()
    })
  }

  function run(args, handler, input) {
    var proc = processComponent.createObject(root, { args: args, handler: handler, input: input || "" })
    proc.running = true
  }

  function say(text, bad) {
    note = text
    noteBad = !!bad
    noteTimer.restart()
  }

  function applyStatus(reply) {
    var was = root.vaultState
    root.vaultState = reply.state || ""
    root.account = reply.account || ""
    root.settingsState = reply.settings || {}
    root.can = reply.can || {}
    root.available = reply.available || {}
    if (root.vaultState === "unlocked" && (was !== "unlocked" || root.items.length === 0)) loadItems()
    if (root.vaultState !== "unlocked") {
      root.items = []
      if (root.page === "edit") root.page = "list"
    }
  }

  function refresh() {
    run(["status"], function(ok, reply) { if (ok) root.applyStatus(reply) })
  }

  function loadItems() {
    run(["items"], function(ok, reply) { if (ok) root.items = reply.items || [] })
    run(["folders"], function(ok, reply) { if (ok) root.folders = reply.folders || [] })
  }

  // ------------------------------------------------------------ unlocking

  function unlock() {
    var secret = secretField.text
    if (!secret || busy) return
    secretField.text = ""
    busy = "Unlocking…"
    run([root.pinMode ? "unlock-pin" : "unlock"], root.unlocked, secret + "\n")
  }

  function unlocked(ok, reply) {
    root.busy = ""
    if (!ok) {
      root.say(reply.error || "Couldn't unlock", true)
      root.refresh()
      secretField.forceActiveFocus()
      return
    }
    root.useMaster = false
    root.applyStatus(reply)
    root.focusFirst()
  }

  function biometricUnlock(kind) {
    if (busy) return
    busy = kind === "face" ? "Look at the camera…" : "Touch the fingerprint reader…"
    if (kind === "face") facePam.start()
    else fingerPam.start()
  }

  function biometricPassed() {
    root.busy = "Unlocking…"
    root.run(["unlock-keyring"], root.unlocked)
  }

  function biometricFailed(text) {
    root.busy = ""
    root.say(text, true)
  }

  // ---------------------------------------------------------- the vault

  function copy(item, field) {
    if (!item) return
    var names = { username: "Username", password: "Password", totp: "Code", uri: "Site" }
    run(["copy", item.id, field], function(ok, reply) {
      if (!ok) { root.say(reply.error || "Couldn't copy", true); return }
      root.say(names[field] + " copied" + (reply.clearsIn > 0 ? " · clears in " + reply.clearsIn + "s" : ""), false)
    })
  }

  function openSite(item) {
    if (!item) return
    run(["open", item.id], function(ok, reply) {
      if (ok) root.close()
      else root.say(reply.error || "Couldn't open it", true)
    })
  }

  function sync() {
    if (busy) return
    busy = "Syncing…"
    run(["sync"], function(ok, reply) {
      root.busy = ""
      if (!ok) { root.say(reply.error || "Couldn't sync", true); return }
      root.applyStatus(reply)
      root.loadItems()
      root.say("Synced", false)
    })
  }

  function lock() {
    run(["lock"], function(ok, reply) {
      if (ok) root.applyStatus(reply)
      root.focusFirst()
    })
  }

  // -------------------------------------------------------------- editing

  function startNew() {
    draft = { type: 1, name: query.trim(), username: "", password: "", uri: "", totp: "", notes: "", folderId: null, favorite: false }
    showPassword = false
    confirmDelete = false
    page = "edit"
  }

  function startEdit(item) {
    if (!item) return
    run(["item", item.id], function(ok, reply) {
      if (!ok) { root.say(reply.error || "Couldn't open it", true); return }
      root.draft = reply.item
      root.showPassword = false
      root.confirmDelete = false
      root.page = "edit"
    })
  }

  function setDraft(name, value) {
    var next = Object.assign({}, draft)
    next[name] = value
    draft = next
  }

  function save() {
    if (busy) return
    if (!String(draft.name || "").trim()) { say("An item needs a name", true); return }
    busy = "Saving…"
    run(["save"], function(ok, reply) {
      root.busy = ""
      if (!ok) { root.say(reply.error || "Couldn't save", true); return }
      root.draft = ({})
      root.page = "list"
      root.loadItems()
      root.say("Saved", false)
    }, JSON.stringify(draft))
  }

  function remove() {
    if (busy || !draft.id) return
    if (!confirmDelete) { confirmDelete = true; return }
    busy = "Deleting…"
    run(["delete", draft.id], function(ok, reply) {
      root.busy = ""
      root.confirmDelete = false
      if (!ok) { root.say(reply.error || "Couldn't delete it", true); return }
      root.draft = ({})
      root.page = "list"
      root.loadItems()
      root.say("Moved to the trash", false)
    })
  }

  function generatePassword() {
    run(["generate", "20"], function(ok, reply) {
      if (!ok) return
      root.setDraft("password", reply.password)
      root.showPassword = true
    })
  }

  // ------------------------------------------------------------ settings

  function set(name, value) {
    run(["set", name, JSON.stringify(value)], function(ok, reply) {
      if (ok) root.applyStatus(reply)
      else root.say(reply.error || "Couldn't change that", true)
    })
  }

  function setPin(pin) {
    run(["pin"], function(ok, reply) {
      if (!ok) { root.say(reply.error || "Couldn't set the PIN", true); return }
      root.applyStatus(reply)
      root.say(pin ? "PIN set · it works after your next unlock with the master password" : "PIN removed", false)
    }, pin + "\n")
  }

  function glyph(item) {
    switch (item.type) {
      case 2: return "󰎚"
      case 3: return "󰆛"
      case 4: return "󰀉"
      case 5: return "󰣀"
      default: return "󰖟"
    }
  }

  // One request to neko-bitwarden: its JSON reply, or what it said went
  // wrong. A secret goes on its stdin, never its command line.
  Component {
    id: processComponent
    Process {
      property var args: []
      property var handler: null
      property string input: ""
      command: ["neko-bitwarden"].concat(args)
      stdinEnabled: input !== ""
      stdout: StdioCollector { id: out; waitForEnd: true }
      stderr: StdioCollector { id: err; waitForEnd: true }
      onStarted: {
        if (input === "") return
        write(input)
        input = ""
        stdinEnabled = false
      }
      onExited: function(code) {
        var reply = {}
        try { reply = JSON.parse(String(out.text || "").trim() || "{}") } catch (error) {}
        if (code !== 0) reply = { error: String(err.text || "").trim().replace(/^neko-core bitwarden: /, "") }
        if (handler) handler(code === 0, reply)
        destroy()
      }
    }
  }

  // The face: system-auth runs Howdy first, and asking for a password next
  // means the face didn't match
  PamContext {
    id: facePam
    config: "system-auth"
    user: root.userName
    onResponseRequiredChanged: {
      if (!responseRequired) return
      abort()
      root.biometricFailed("Face not recognized")
    }
    onCompleted: function(result) {
      if (result === PamResult.Success) root.biometricPassed()
      else root.biometricFailed("Face not recognized")
    }
    onError: function(error) { root.biometricFailed("Face unlock didn't work") }
  }

  // A finger, through neko's fingerprint profile, as the lock screen reads it
  PamContext {
    id: fingerPam
    config: "neko-lock-fingerprint"
    user: root.userName
    onCompleted: function(result) {
      if (result === PamResult.Success) root.biometricPassed()
      else root.biometricFailed("Fingerprint not recognized")
    }
    onError: function(error) { root.biometricFailed("Fingerprint unlock didn't work") }
  }

  Timer {
    id: noteTimer
    interval: 4000
    onTriggered: root.note = ""
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vaultState === "unlocked" ? "󰦝" : "󰒘"
    active: root.vaultState === "unlocked"
    tooltipText: root.vaultState === "unlocked" ? "Bitwarden · unlocked" : "Bitwarden"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.vaultState === "locked" ? secretField : root.page === "list" ? searchField : null
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    ColumnLayout {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(12)

      // Who, the vault's state, and what to do with it
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        PanelActionButton {
          visible: root.page !== "list"
          iconText: "󰅁"
          tooltipText: "Back"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.page = "list"
        }
        Text {
          visible: root.page === "list"
          text: root.vaultState === "unlocked" ? "󰦝" : "󰒘"
          color: root.vaultState === "unlocked" ? NekoColor.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
          Layout.rightMargin: Style.space(4)
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            text: root.page === "settings" ? "Settings" : root.page === "edit" ? (root.draft.id ? "Edit item" : "New item") : "Bitwarden"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.weight: Font.DemiBold
          }
          Text {
            Layout.fillWidth: true
            text: root.vaultState === "unlocked" ? root.items.length + " items · " + root.account
              : root.vaultState === "locked" ? "Locked · " + root.account
              : root.vaultState === "logged-out" ? "Not logged in" : "…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        PanelActionButton {
          visible: root.vaultState === "unlocked" && root.page === "list"
          iconText: "󰐕"
          tooltipText: "New item (Ctrl+N)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.startNew()
        }
        PanelActionButton {
          visible: root.vaultState !== "logged-out" && root.page !== "settings"
          iconText: "󰒓"
          tooltipText: "Settings"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.page = "settings"
        }
        PanelActionButton {
          visible: root.vaultState === "unlocked" && root.page === "list"
          iconText: "󰑐"
          tooltipText: "Sync"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.sync()
        }
        PanelActionButton {
          visible: root.vaultState === "unlocked"
          iconText: "󰌾"
          tooltipText: "Lock"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.lock()
        }
      }

      // ------------------------------------------------------ logged out

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.vaultState === "logged-out"
        spacing: Style.space(10)
        Text {
          Layout.fillWidth: true
          text: "Log in once with the Bitwarden CLI; neko unlocks it from then on."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
        Button {
          Layout.fillWidth: true
          iconText: "󰍂"
          text: "Log in"
          bordered: true
          foreground: root.foreground
          onClicked: {
            Quickshell.execDetached(["neko-launch-floating-terminal-with-presentation", "bw login"])
            root.close()
          }
        }
      }

      // ---------------------------------------------------------- locked

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.vaultState === "locked" && root.page === "list"
        spacing: Style.space(10)

        TextField {
          id: secretField
          Layout.fillWidth: true
          password: true
          enabled: !root.busy
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: root.busy || (root.pinMode ? "PIN" : "Master password")
          inputMethodHints: root.pinMode ? Qt.ImhDigitsOnly : Qt.ImhNone
          onAccepted: root.unlock()
          Keys.onEscapePressed: root.close()
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Button {
            Layout.fillWidth: true
            visible: !!root.can.face
            iconText: "󰄀"
            text: "Face"
            bordered: true
            enabled: !root.busy
            foreground: root.foreground
            onClicked: root.biometricUnlock("face")
          }
          Button {
            Layout.fillWidth: true
            visible: !!root.can.fingerprint
            iconText: "󰈷"
            text: "Fingerprint"
            bordered: true
            enabled: !root.busy
            foreground: root.foreground
            onClicked: root.biometricUnlock("fingerprint")
          }
          Button {
            Layout.fillWidth: true
            iconText: "󰌿"
            text: root.busy || "Unlock"
            bordered: true
            enabled: !root.busy && secretField.text.length > 0
            foreground: root.foreground
            onClicked: root.unlock()
          }
        }

        Text {
          Layout.fillWidth: true
          visible: !!root.can.pin
          text: root.useMaster ? "Use the PIN instead" : "Use the master password instead"
          color: NekoColor.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { root.useMaster = !root.useMaster; secretField.forceActiveFocus() }
          }
        }
      }

      // -------------------------------------------------------- the list

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.vaultState === "unlocked" && root.page === "list"
        spacing: Style.space(8)

        TextField {
          id: searchField
          Layout.fillWidth: true
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: "Search the vault"
          onTextChanged: root.query = text
          onAccepted: root.copy(root.current, "password")
          Keys.onPressed: function(event) {
            var ctrl = event.modifiers & Qt.ControlModifier
            if (event.key === Qt.Key_Down) { root.selected = Math.min(root.shown.length - 1, root.selected + 1); event.accepted = true }
            else if (event.key === Qt.Key_Up) { root.selected = Math.max(0, root.selected - 1); event.accepted = true }
            else if (ctrl && event.key === Qt.Key_U) { root.copy(root.current, "username"); event.accepted = true }
            else if (ctrl && event.key === Qt.Key_T) { root.copy(root.current, "totp"); event.accepted = true }
            else if (ctrl && event.key === Qt.Key_O) { root.openSite(root.current); event.accepted = true }
            else if (ctrl && event.key === Qt.Key_E) { root.startEdit(root.current); event.accepted = true }
            else if (ctrl && event.key === Qt.Key_N) { root.startNew(); event.accepted = true }
            else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
          }
        }

        ListView {
          id: list
          Layout.fillWidth: true
          Layout.preferredHeight: Style.space(330)
          clip: true
          model: root.shown
          currentIndex: root.selected
          boundsBehavior: Flickable.StopAtBounds
          spacing: Style.space(2)
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool picked: index === root.selected
            width: list.width
            height: Style.space(48)
            radius: Style.space(12)
            color: picked ? Util.alpha(root.foreground, 0.1) : rowMouse.containsMouse ? Util.alpha(root.foreground, 0.05) : "transparent"

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              onClicked: root.selected = row.index
              onDoubleClicked: root.startEdit(row.modelData)
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(8)
              Text {
                text: root.glyph(row.modelData)
                color: row.picked ? NekoColor.accent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                  Layout.fillWidth: true
                  text: (row.modelData.favorite ? "★ " : "") + (row.modelData.name || "Untitled")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  Layout.fillWidth: true
                  visible: text !== ""
                  text: row.modelData.username || ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              PanelActionButton {
                visible: !!row.modelData.username
                iconText: "󰀄"
                tooltipText: "Copy username (Ctrl+U)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.copy(row.modelData, "username")
              }
              PanelActionButton {
                visible: row.modelData.hasPassword
                iconText: "󰌆"
                tooltipText: "Copy password (Enter)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.copy(row.modelData, "password")
              }
              PanelActionButton {
                visible: row.modelData.hasTotp
                iconText: "󰦯"
                tooltipText: "Copy 2FA code (Ctrl+T)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.copy(row.modelData, "totp")
              }
              PanelActionButton {
                visible: !!row.modelData.uri
                iconText: "󰏌"
                tooltipText: "Open the site (Ctrl+O)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.openSite(row.modelData)
              }
              PanelActionButton {
                iconText: "󰏫"
                tooltipText: "Edit (Ctrl+E)"
                foreground: root.dim
                fontFamily: root.fontFamily
                onClicked: root.startEdit(row.modelData)
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.shown.length === 0
          text: root.items.length === 0 ? "The vault is empty" : "Nothing matches · Ctrl+N adds it"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }
      }

      // ------------------------------------------------------- the editor

      Flickable {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(editor.implicitHeight, Style.space(470))
        visible: root.vaultState === "unlocked" && root.page === "edit"
        contentWidth: width
        contentHeight: editor.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
          id: editor
          width: parent.width
          spacing: Style.space(8)

          ButtonGroup {
            Layout.fillWidth: true
            visible: !root.draft.id
            fontSize: Style.font.bodySmall
            options: [{ value: "1", label: "Login" }, { value: "2", label: "Note" }]
            value: String(root.draft.type || 1)
            onChanged: function(v) { root.setDraft("type", Number(v)) }
          }

          FieldLabel { text: "Name" }
          TextField {
            id: nameField
            Layout.fillWidth: true
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: root.draft.name || ""
            onTextEdited: root.setDraft("name", text)
            onAccepted: root.save()
          }

          ColumnLayout {
            Layout.fillWidth: true
            visible: (root.draft.type || 1) === 1
            spacing: Style.space(8)

            FieldLabel { text: "Username" }
            TextField {
              Layout.fillWidth: true
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              text: root.draft.username || ""
              onTextEdited: root.setDraft("username", text)
              onAccepted: root.save()
            }

            FieldLabel { text: "Password" }
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(4)
              TextField {
                Layout.fillWidth: true
                password: !root.showPassword
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                text: root.draft.password || ""
                onTextEdited: root.setDraft("password", text)
                onAccepted: root.save()
              }
              PanelActionButton {
                iconText: root.showPassword ? "󰈉" : "󰈈"
                tooltipText: root.showPassword ? "Hide" : "Show"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showPassword = !root.showPassword
              }
              PanelActionButton {
                iconText: "󰒲"
                tooltipText: "Make a strong password"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.generatePassword()
              }
            }

            FieldLabel { text: "Website" }
            TextField {
              Layout.fillWidth: true
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              placeholderText: "example.com"
              text: root.draft.uri || ""
              onTextEdited: root.setDraft("uri", text)
              onAccepted: root.save()
            }

            FieldLabel { text: "2FA secret" }
            TextField {
              Layout.fillWidth: true
              password: !root.showPassword
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              placeholderText: "The key, or an otpauth:// link"
              text: root.draft.totp || ""
              onTextEdited: root.setDraft("totp", text)
              onAccepted: root.save()
            }
          }

          FieldLabel { text: "Folder" }
          Dropdown {
            Layout.fillWidth: true
            showLabel: false
            fontFamily: root.fontFamily
            foreground: root.foreground
            options: [{ value: "", label: "No folder" }].concat(root.folders.map(function(f) { return { value: f.id, label: f.name } }))
            value: root.draft.folderId || ""
            onChanged: function(v) { root.setDraft("folderId", v || null) }
          }

          FieldLabel { text: "Notes" }
          Rectangle {
            Layout.fillWidth: true
            implicitHeight: Style.space(80)
            radius: Style.space(8)
            color: Util.alpha(root.foreground, 0.05)
            border.width: 1
            border.color: notesArea.activeFocus ? Util.alpha(NekoColor.accent, 0.7) : Util.alpha(root.foreground, 0.1)
            Controls.ScrollView {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              Controls.TextArea {
                id: notesArea
                text: root.draft.notes || ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: TextEdit.Wrap
                background: null
                onTextChanged: if (activeFocus) root.setDraft("notes", text)
              }
            }
          }

          RowLayout {
            Layout.fillWidth: true
            Text {
              Layout.fillWidth: true
              text: "Favorite"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            ToggleSwitch {
              checked: !!root.draft.favorite
              foreground: root.foreground
              onToggled: root.setDraft("favorite", !root.draft.favorite)
            }
          }

          RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Style.space(4)
            spacing: Style.space(8)
            Button {
              visible: !!root.draft.id
              iconText: "󰩺"
              text: root.confirmDelete ? "Delete it?" : "Delete"
              bordered: true
              enabled: !root.busy
              foreground: root.confirmDelete ? NekoColor.urgent : root.foreground
              onClicked: root.remove()
            }
            Item { Layout.fillWidth: true }
            Button {
              text: "Cancel"
              bordered: true
              enabled: !root.busy
              foreground: root.foreground
              onClicked: root.page = "list"
            }
            Button {
              iconText: "󰆓"
              text: root.busy || "Save"
              bordered: true
              selected: true
              enabled: !root.busy
              foreground: root.foreground
              onClicked: root.save()
            }
          }
        }
      }

      // ---------------------------------------------------------- settings

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.page === "settings"
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "UNLOCK"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // The PIN: set, change, or take away
        SettingRow {
          title: "PIN"
          detail: !root.settingsState.pin ? "Unlock with a short PIN after the master password has once"
            : root.can.pin ? "On" : "On · works after your next unlock with the master password"
        }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          TextField {
            id: pinField
            Layout.fillWidth: true
            password: true
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            placeholderText: root.settingsState.pin ? "New PIN" : "PIN, 4 or more"
            inputMethodHints: Qt.ImhDigitsOnly
            onAccepted: if (text.length >= 4) { root.setPin(text); text = "" }
          }
          Button {
            text: root.settingsState.pin ? "Change" : "Set"
            bordered: true
            enabled: pinField.text.length >= 4
            foreground: root.foreground
            onClicked: { root.setPin(pinField.text); pinField.text = "" }
          }
          Button {
            visible: !!root.settingsState.pin
            text: "Remove"
            bordered: true
            foreground: root.foreground
            onClicked: root.setPin("")
          }
        }

        SettingRow {
          title: "Face"
          detail: !root.available.face ? "Set up Howdy (install.sh offers it) to unlock with your face"
            : root.settingsState.face && !root.can.face ? "On · the next unlock with the master password keeps it in your keyring"
            : "Your face, as at the lock screen"
          switchVisible: !!root.available.face
          checked: !!root.settingsState.face
          onToggled: root.set("face", !root.settingsState.face)
        }
        SettingRow {
          title: "Fingerprint"
          detail: !root.available.fingerprint ? "Enroll a finger (install.sh offers it) to unlock with it"
            : root.settingsState.fingerprint && !root.can.fingerprint ? "On · the next unlock with the master password keeps it in your keyring"
            : "A finger on the reader"
          switchVisible: !!root.available.fingerprint
          checked: !!root.settingsState.fingerprint
          onToggled: root.set("fingerprint", !root.settingsState.fingerprint)
        }
        Text {
          Layout.fillWidth: true
          visible: !!root.available.face || !!root.available.fingerprint
          text: "Face and fingerprint keep your master password in the login keyring, which any program running as you could read."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSectionHeader {
          Layout.topMargin: Style.space(4)
          text: "SECURITY"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        FieldLabel { text: "Lock after idle" }
        ButtonGroup {
          Layout.fillWidth: true
          fontSize: Style.font.bodySmall
          options: [{ value: "1", label: "1 min" }, { value: "5", label: "5 min" }, { value: "15", label: "15 min" }, { value: "60", label: "1 hour" }, { value: "0", label: "Never" }]
          value: String(root.settingsState.autolock === undefined ? 15 : root.settingsState.autolock)
          onChanged: function(v) { root.set("autolock", Number(v)) }
        }

        FieldLabel { text: "Clear copied secrets after" }
        ButtonGroup {
          Layout.fillWidth: true
          fontSize: Style.font.bodySmall
          options: [{ value: "10", label: "10 s" }, { value: "30", label: "30 s" }, { value: "60", label: "1 min" }, { value: "0", label: "Never" }]
          value: String(root.settingsState.clear === undefined ? 30 : root.settingsState.clear)
          onChanged: function(v) { root.set("clear", Number(v)) }
        }

        SettingRow {
          title: "Lock with the screen"
          detail: "Locking the screen locks the vault too"
          switchVisible: true
          checked: root.settingsState.lockOnScreenLock !== false
          onToggled: root.set("lockOnScreenLock", root.settingsState.lockOnScreenLock === false)
        }
      }

      // What just happened: a copy, a save, or what went wrong
      Text {
        Layout.fillWidth: true
        visible: root.note !== "" || (root.busy !== "" && root.vaultState === "unlocked")
        text: root.note || root.busy
        color: root.noteBad ? NekoColor.urgent : NekoColor.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }

  // A small caption over a field
  component FieldLabel: Text {
    Layout.fillWidth: true
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // A setting: its name, a line on what it does, and a switch
  component SettingRow: RowLayout {
    id: setting
    property string title: ""
    property string detail: ""
    property bool switchVisible: false
    property bool checked: false
    signal toggled()
    Layout.fillWidth: true
    spacing: Style.space(10)
    ColumnLayout {
      Layout.fillWidth: true
      spacing: 0
      Text {
        text: setting.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
      Text {
        Layout.fillWidth: true
        text: setting.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
    ToggleSwitch {
      visible: setting.switchVisible
      checked: setting.checked
      foreground: root.foreground
      onToggled: setting.toggled()
    }
  }
}
