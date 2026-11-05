import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import qs.Ui
import qs.Commons

// The Bitwarden vault, behind a shield in the bar: unlock it, search it, and
// copy a username, password or 2FA code. neko-bitwarden holds it unlocked in
// memory (bw runs only to unlock and sync), copies marked sensitive so the
// clipboard history skips them, and clears them after 30 seconds.
//
// Where Howdy is set up for the login (pam_howdy in system-auth, as the lock
// screen checks), a face unlocks it too: the face is checked through PAM as
// the lock screen does, and the master password the keyring kept (with
// "Remember for face unlock" on) unlocks the vault.
Panel {
  id: root
  moduleName: "neko.bitwarden"
  ipcTarget: "neko.bitwarden"

  // logged-out, locked, unlocked, or "" before the first answer
  property string vaultState: ""
  property string account: ""
  property bool remember: false
  property var items: []
  property string query: ""
  property int selected: 0
  // Unlocking, syncing or checking a face: the vault takes a few seconds
  property string busy: ""
  property string note: ""
  property bool noteBad: false
  property bool faceAvailable: false
  // Held only from the press of Enter until the unlock process takes it
  property string pendingPassword: ""

  readonly property color foreground: bar ? bar.foreground : NekoColor.foreground
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")

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
      return
    }
    refresh()
    Qt.callLater(function() {
      if (root.vaultState === "unlocked") searchField.forceActiveFocus()
      else if (root.vaultState === "locked") passwordField.forceActiveFocus()
    })
  }

  function run(args, handler) {
    var proc = processComponent.createObject(root, { args: args, handler: handler })
    proc.running = true
  }

  function say(text, bad) {
    note = text
    noteBad = !!bad
    noteTimer.restart()
  }

  function applyStatus(reply) {
    root.vaultState = reply.state || ""
    root.account = reply.account || ""
    root.remember = reply.remember === true
    if (root.vaultState === "unlocked" && root.items.length === 0) loadItems()
    if (root.vaultState !== "unlocked") root.items = []
  }

  function refresh() {
    run(["status"], function(ok, reply) { if (ok) root.applyStatus(reply) })
  }

  function loadItems() {
    run(["items"], function(ok, reply) {
      if (ok) root.items = reply.items || []
    })
  }

  function unlock() {
    var password = passwordField.text
    if (!password || busy) return
    passwordField.text = ""
    pendingPassword = password
    busy = "Unlocking…"
    unlockProc.running = true
  }

  function unlocked(ok, reply) {
    root.busy = ""
    if (!ok) {
      root.say(reply.error || "Couldn't unlock", true)
      passwordField.forceActiveFocus()
      return
    }
    root.applyStatus(reply)
    root.loadItems()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function faceUnlock() {
    if (busy) return
    busy = "Look at the camera…"
    facePam.start()
  }

  function copy(item, field) {
    if (!item) return
    var names = { username: "Username", password: "Password", totp: "Code", uri: "Site" }
    run(["copy", item.id, field], function(ok, reply) {
      if (ok) root.say(names[field] + " copied · clears in " + (reply.clearsIn || 30) + "s", false)
      else root.say(reply.error || "Couldn't copy", true)
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
      Qt.callLater(function() { passwordField.forceActiveFocus() })
    })
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

  // One request to neko-bitwarden: its JSON reply, or what it said went wrong
  Component {
    id: processComponent
    Process {
      property var args: []
      property var handler: null
      command: ["neko-bitwarden"].concat(args)
      stdout: StdioCollector { id: out; waitForEnd: true }
      stderr: StdioCollector { id: err; waitForEnd: true }
      onExited: function(code) {
        var reply = {}
        try { reply = JSON.parse(String(out.text || "").trim() || "{}") } catch (error) {}
        if (code !== 0) reply = { error: String(err.text || "").trim().replace(/^neko-core bitwarden: /, "") }
        if (handler) handler(code === 0, reply)
        destroy()
      }
    }
  }

  // The master password goes to it on stdin, never on its command line
  Process {
    id: unlockProc
    command: ["neko-bitwarden", "unlock"]
    stdinEnabled: true
    stdout: StdioCollector { id: unlockOut; waitForEnd: true }
    stderr: StdioCollector { id: unlockErr; waitForEnd: true }
    onStarted: {
      write(root.pendingPassword + "\n")
      root.pendingPassword = ""
    }
    onExited: function(code) {
      var reply = {}
      try { reply = JSON.parse(String(unlockOut.text || "").trim() || "{}") } catch (error) {}
      if (code !== 0) reply = { error: String(unlockErr.text || "").trim().replace(/^neko-core bitwarden: /, "") }
      root.unlocked(code === 0, reply)
    }
  }

  // The face, checked as the lock screen checks it: system-auth runs Howdy
  // first, and asking for a password next means the face didn't match
  PamContext {
    id: facePam
    config: "system-auth"
    user: root.userName
    onResponseRequiredChanged: {
      if (!responseRequired) return
      abort()
      root.busy = ""
      root.say("Face not recognized", true)
    }
    onCompleted: function(result) {
      if (result === PamResult.Success) {
        root.busy = "Unlocking…"
        root.run(["unlock-keyring"], root.unlocked)
      } else {
        root.busy = ""
        root.say("Face not recognized", true)
      }
    }
    onError: function(error) {
      root.busy = ""
      root.say("Face unlock didn't work", true)
    }
  }

  // Whether Howdy guards the login, as the lock screen asks
  Process {
    running: true
    command: ["bash", "-c", "if [[ -r /usr/lib/security/pam_howdy.so && -r /etc/howdy/config.ini ]] && grep -q '^[[:space:]]*auth.*pam_howdy\\.so' /etc/pam.d/system-auth; then echo yes; else echo no; fi"]
    stdout: SplitParser { onRead: function(line) { root.faceAvailable = String(line).trim() === "yes" } }
  }

  Timer {
    id: noteTimer
    interval: 3500
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
    focusTarget: root.vaultState === "unlocked" ? searchField : passwordField
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    ColumnLayout {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(12)

      // Who, and the vault's state
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)
        Text {
          text: root.vaultState === "unlocked" ? "󰦝" : "󰒘"
          color: root.vaultState === "unlocked" ? NekoColor.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            text: "Bitwarden"
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
          visible: root.vaultState === "unlocked"
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
        visible: root.vaultState === "locked"
        spacing: Style.space(10)

        TextField {
          id: passwordField
          Layout.fillWidth: true
          password: true
          enabled: !root.busy
          foreground: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          placeholderText: root.busy || "Master password"
          onAccepted: root.unlock()
          Keys.onEscapePressed: root.close()
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)
          Button {
            Layout.fillWidth: true
            visible: root.faceAvailable && root.remember
            iconText: "󰄀"
            text: "Unlock with face"
            bordered: true
            enabled: !root.busy
            foreground: root.foreground
            onClicked: root.faceUnlock()
          }
          Button {
            Layout.fillWidth: true
            iconText: "󰌿"
            text: root.busy || "Unlock"
            bordered: true
            enabled: !root.busy && passwordField.text.length > 0
            foreground: root.foreground
            onClicked: root.unlock()
          }
        }

        // A face only stands in for the password once the keyring holds it
        RowLayout {
          Layout.fillWidth: true
          visible: root.faceAvailable
          Text {
            Layout.fillWidth: true
            text: root.remember ? "Face unlock is on; the keyring keeps your master password"
              : "Remember for face unlock (keeps the master password in your login keyring)"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          ToggleSwitch {
            checked: root.remember
            foreground: root.foreground
            onToggled: root.run(["remember", root.remember ? "off" : "on"], function(ok, reply) { if (ok) root.applyStatus(reply) })
          }
        }
      }

      // -------------------------------------------------------- unlocked

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.vaultState === "unlocked"
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
              onDoubleClicked: root.copy(row.modelData, "password")
            }

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(10)
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
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: root.shown.length === 0
          text: root.items.length === 0 ? "The vault is empty" : "Nothing matches"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
        }
      }

      // What just happened: a copy, or what went wrong
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
}
