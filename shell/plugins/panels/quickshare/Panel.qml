import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Quick Share, behind a share button in the bar: let phones nearby see this
// one for a while, answer what they send (the code on both screens should
// match), pick files and send them to a phone in the list or to whoever
// scans a QR code, and follow each transfer. The Quick Share service, a
// separate program, does the work; neko-quickshare talks to it over the
// session bus and `watch` follows it, so the bar knows of a request at once.
// The button shows only on a machine with the service installed.
Panel {
  id: root
  moduleName: "neko.quickshare"
  ipcTarget: "neko.quickshare"

  // ready, old, stopped or missing; "" before the first word
  property string serviceState: ""
  property var snapshot: null
  property string minimum: ""
  property var picked: []
  property bool showSettings: false
  property string note: ""
  property bool noteBad: false
  property double now: Date.now() / 1000

  readonly property color foreground: bar ? bar.foreground : NekoColor.foreground
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property color soft: Util.alpha(foreground, 0.06)
  readonly property color softer: Util.alpha(foreground, 0.1)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool ready: serviceState === "ready" && !!snapshot
  readonly property var devices: ready ? snapshot.devices || [] : []
  readonly property var transfers: ready ? snapshot.transfers || [] : []
  readonly property var requests: transfers.filter(function(t) { return t.direction === "inbound" && t.state === "waiting_acceptance" })
  readonly property var shown: transfers.filter(function(t) { return !(t.direction === "inbound" && t.state === "waiting_acceptance") }).slice().reverse()
  readonly property bool busy: transfers.some(function(t) { return ["completed", "rejected", "cancelled", "failed"].indexOf(t.state) < 0 })
  readonly property int visibleFor: ready && snapshot.visible && snapshot.visibility_expires_at ? Math.max(0, Math.ceil(snapshot.visibility_expires_at - now)) : 0
  readonly property bool visibleNow: ready && snapshot.visible && (snapshot.visibility_expires_at === null || visibleFor > 0)
  readonly property var qr: ready && snapshot.qr_send && snapshot.qr_send.expires_at > now ? snapshot.qr_send : null

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: serviceState !== "" && serviceState !== "missing"

  onOpenedChanged: {
    if (!opened) {
      showSettings = false
      note = ""
    }
  }

  function run(args, input, handler) {
    var proc = processComponent.createObject(root, { args: args, input: input || "", handler: handler || null })
    proc.running = true
  }

  function say(text, bad) {
    note = text
    noteBad = !!bad
    noteTimer.restart()
  }

  function act(args, input, done) {
    run(args, input, function(ok, reply) {
      if (!ok) root.say(reply.error || "Quick Share didn't do that", true)
      else if (done) done(reply)
    })
  }

  function pickFiles() {
    picker.running = true
  }

  function send(device) {
    if (picked.length === 0) {
      say("Choose the files first", true)
      return
    }
    act(["send", device.id], JSON.stringify(picked) + "\n", function() {
      root.say("Waiting for " + device.name + " to accept")
      root.picked = []
    })
  }

  function sendByQr() {
    if (picked.length === 0) {
      say("Choose the files first", true)
      return
    }
    act(["qr-send"], JSON.stringify(picked) + "\n", function() { root.picked = [] })
  }

  function baseName(path) {
    var text = String(path || "")
    return text.slice(text.lastIndexOf("/") + 1)
  }

  function sizeText(bytes) {
    if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + " GB"
    if (bytes >= 1048576) return (bytes / 1048576).toFixed(1) + " MB"
    return Math.max(1, Math.round(bytes / 1024)) + " KB"
  }

  function stateText(t) {
    switch (t.state) {
      case "connecting": return "Connecting"
      case "authenticating": return "Checking the code"
      case "negotiating": return "Choosing how to connect"
      case "waiting_acceptance": return t.direction === "outbound" ? "Waiting for them to accept" : "Asking you"
      case "transferring": return (t.direction === "outbound" ? "Sending · " : "Receiving · ") + Math.round(100 * t.transferred_bytes / Math.max(1, t.total_bytes)) + "%"
      case "completed": return t.direction === "outbound" ? "Sent" : "Received"
      case "rejected": return "Declined"
      case "cancelled": return "Cancelled"
      default: return t.error || "Failed"
    }
  }

  function shortPath(path) {
    var home = Quickshell.env("HOME")
    path = String(path || "")
    return home && path.indexOf(home) === 0 ? "~" + path.slice(home.length) : path
  }

  // The service's state as it changes: one JSON line each time. Under
  // pdeathsig, so a restart of the shell doesn't leave one behind.
  Process {
    id: watcher
    running: true
    command: ["setpriv", "--pdeathsig", "TERM", "neko-quickshare", "watch"]
    stdout: SplitParser {
      onRead: function(line) {
        var reply
        try { reply = JSON.parse(line) } catch (error) { return }
        root.serviceState = reply.state || ""
        root.snapshot = reply.snapshot || null
        root.minimum = reply.minimum || ""
      }
    }
    // The session bus went away, or it failed: try again in a while
    onExited: rewatch.restart()
  }

  Timer {
    id: rewatch
    interval: 10000
    onTriggered: watcher.running = true
  }

  // The visibility countdown, only while it's on show
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.visibleNow && root.visibleFor > 0
    onTriggered: root.now = Date.now() / 1000
  }

  Process {
    id: picker
    command: ["neko-file-select", "--title", "Send with Quick Share", "--multiple"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var paths = String(text || "").split("\n").filter(function(line) { return line !== "" })
        if (paths.length > 0) root.picked = paths
      }
    }
  }

  Process {
    id: folderPicker
    command: ["neko-file-select", "--title", "Save received files in", "--directory"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var folder = String(text || "").split("\n")[0]
        if (folder) root.act(["folder", folder])
      }
    }
  }

  Component {
    id: processComponent
    Process {
      property var args: []
      property var handler: null
      property string input: ""
      command: ["neko-quickshare"].concat(args)
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
        if (code !== 0) reply = { error: String(err.text || "").trim().replace(/^neko-core quickshare: /, "") }
        if (handler) handler(code === 0, reply)
        destroy()
      }
    }
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
    text: "󰒗"
    // A phone asking stands out; so does being visible, or a transfer going
    active: root.requests.length > 0
    dimmed: !root.ready
    tooltipText: root.requests.length > 0 ? "Quick Share · " + root.requests[0].device_name + " wants to send you files"
      : root.visibleNow ? "Quick Share · visible to phones nearby"
      : root.busy ? "Quick Share · transferring" : "Quick Share"
    onPressed: function(mouseButton) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    ColumnLayout {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(12)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Text {
          text: "󰒗"
          color: root.visibleNow ? NekoColor.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
          Layout.rightMargin: Style.space(4)
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: 0
          Text {
            text: "Quick Share"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.weight: Font.DemiBold
          }
          Text {
            Layout.fillWidth: true
            text: !root.ready ? (root.serviceState === "old" ? "The service needs an update" : "The service isn't running")
              : root.visibleNow ? "Visible to phones nearby" + (root.visibleFor > 0 ? " · " + Math.floor(root.visibleFor / 60) + ":" + ("0" + root.visibleFor % 60).slice(-2) : "")
              : "Hidden from phones nearby"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
        PanelActionButton {
          visible: root.ready
          iconText: "󰒓"
          tooltipText: "Settings"
          foreground: root.showSettings ? NekoColor.accent : root.foreground
          fontFamily: root.fontFamily
          onClicked: root.showSettings = !root.showSettings
        }
      }

      // ------------------------------------------------------- not ready

      Text {
        Layout.fillWidth: true
        visible: !root.ready
        text: root.serviceState === "old"
          ? "This Quick Share service is older than " + root.minimum + ", which has fixes the protocol needs. Update it, then open this again."
          : "The Quick Share service is installed but not running. Start it, and phones nearby can find this one."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
      Button {
        Layout.fillWidth: true
        visible: root.serviceState === "stopped"
        iconText: "󰐊"
        text: "Start the service"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.act(["start"])
      }

      // -------------------------------------------------------- settings

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.ready && root.showSettings
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: "Received files"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              Layout.fillWidth: true
              text: root.ready ? root.shortPath(root.snapshot.download_directory) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }
          }
          Button {
            text: "Change"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: folderPicker.running = true
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
              text: "Change the network for a transfer"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              Layout.fillWidth: true
              text: "Lets it set up a temporary hotspot when a phone asks for one, for speed. Off keeps your network as it is."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
          ToggleSwitch {
            checked: root.ready && root.snapshot.network_consent === true
            foreground: root.foreground
            onToggled: root.act(["network", root.snapshot.network_consent ? "off" : "on"])
          }
        }

        PanelSeparator { Layout.fillWidth: true }
      }

      // ---------------------------------------------------- being visible

      RowLayout {
        Layout.fillWidth: true
        visible: root.ready
        spacing: Style.space(10)
        Text {
          Layout.fillWidth: true
          text: "Let phones see this one"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        ButtonGroup {
          options: [{ value: "0", label: "Off" }, { value: "120", label: "2 min" }, { value: "600", label: "10 min" }]
          value: !root.visibleNow ? "0" : root.visibleFor > 120 ? "600" : "120"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          focusable: false
          onChanged: function(value) { root.act(["visible", value]) }
        }
      }

      // ------------------------------------------------ asking to send you

      Repeater {
        model: root.requests
        delegate: Rectangle {
          id: request
          required property var modelData
          Layout.fillWidth: true
          implicitHeight: requestColumn.implicitHeight + Style.space(24)
          radius: Style.space(14)
          color: Util.alpha(NekoColor.accent, 0.1)
          border.width: 1
          border.color: Util.alpha(NekoColor.accent, 0.35)

          ColumnLayout {
            id: requestColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            spacing: Style.space(6)
            Text {
              Layout.fillWidth: true
              text: request.modelData.device_name + " wants to send you " + (request.modelData.files.length === 1 ? request.modelData.files[0] : request.modelData.files.length + " files")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.weight: Font.DemiBold
              wrapMode: Text.WordWrap
            }
            Text {
              Layout.fillWidth: true
              text: root.sizeText(request.modelData.total_bytes) + (request.modelData.pin_code ? " · check the phone shows " + request.modelData.pin_code : "")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
            RowLayout {
              Layout.fillWidth: true
              Layout.topMargin: Style.space(4)
              spacing: Style.space(8)
              Button {
                Layout.fillWidth: true
                text: "Decline"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.act(["reject", request.modelData.id])
              }
              Button {
                Layout.fillWidth: true
                iconText: "󰄬"
                text: "Accept"
                selected: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.act(["accept", request.modelData.id])
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ send

      ColumnLayout {
        Layout.fillWidth: true
        visible: root.ready
        spacing: Style.space(8)

        Rectangle {
          Layout.fillWidth: true
          implicitHeight: pickRow.implicitHeight + Style.space(20)
          radius: Style.space(12)
          color: pickMouse.containsMouse ? root.softer : root.soft
          border.width: 1
          border.color: Util.alpha(root.foreground, 0.08)

          MouseArea {
            id: pickMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pickFiles()
          }

          RowLayout {
            id: pickRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(10)
            Text {
              text: root.picked.length > 0 ? "󰈙" : "󰐕"
              color: root.picked.length > 0 ? NekoColor.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                Layout.fillWidth: true
                text: root.picked.length === 0 ? "Choose files to send"
                  : root.picked.length === 1 ? root.baseName(root.picked[0]) : root.picked.length + " files"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideMiddle
              }
              Text {
                Layout.fillWidth: true
                text: root.picked.length === 0 ? "Then pick a phone below, or show a QR code"
                  : root.picked.length > 1 ? root.picked.map(root.baseName).join(", ") : "Pick a phone below to send it"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
            PanelActionButton {
              visible: root.picked.length > 0
              iconText: "󰅖"
              tooltipText: "Clear"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.picked = []
            }
          }
        }

        Text {
          text: root.devices.length > 0 ? "Nearby" : "No phones nearby yet. On the phone, open Quick Share and set it to be seen by everyone."
          Layout.fillWidth: true
          Layout.topMargin: Style.space(4)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.devices
          delegate: Rectangle {
            id: device
            required property var modelData
            Layout.fillWidth: true
            implicitHeight: deviceRow.implicitHeight + Style.space(16)
            radius: Style.space(10)
            color: deviceMouse.containsMouse && root.picked.length > 0 ? root.softer : "transparent"
            opacity: root.picked.length > 0 ? 1 : 0.6

            MouseArea {
              id: deviceMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: root.picked.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.send(device.modelData)
            }

            RowLayout {
              id: deviceRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)
              Text {
                text: /tab/i.test(device.modelData.name) ? "󰓶" : "󰄜"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }
              Text {
                Layout.fillWidth: true
                text: device.modelData.name
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                text: device.modelData.transport === "bluetooth" ? "󰂯" : "󰈀"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
              }
            }
          }
        }

        Button {
          Layout.fillWidth: true
          visible: root.snapshot && root.snapshot.qr_send_supported === true && !root.qr
          enabled: root.picked.length > 0
          iconText: "󰐲"
          text: "Show a QR code to send"
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.sendByQr()
        }

        // The QR code: scanned on the phone, it asks for the files; the code
        // on both screens still has to match
        ColumnLayout {
          Layout.fillWidth: true
          visible: !!root.qr
          spacing: Style.space(6)
          Rectangle {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: Style.space(180)
            implicitHeight: implicitWidth
            radius: Style.space(10)
            color: "#ffffff"
            Image {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              source: root.qr ? root.qr.image : ""
              sourceSize.width: 360
              fillMode: Image.PreserveAspectFit
              smooth: false
            }
          }
          Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: root.qr ? "Scan with the phone's camera · " + root.qr.file_count + (root.qr.file_count === 1 ? " file" : " files") : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Button {
            Layout.alignment: Qt.AlignHCenter
            text: "Stop showing it"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.act(["qr-stop", root.qr.id])
          }
        }
      }

      // ------------------------------------------------------- transfers

      Repeater {
        model: root.shown.slice(0, 5)
        delegate: ColumnLayout {
          id: transfer
          required property var modelData
          readonly property bool live: ["completed", "rejected", "cancelled", "failed"].indexOf(modelData.state) < 0
          Layout.fillWidth: true
          spacing: Style.space(4)
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Text {
              text: transfer.modelData.direction === "outbound" ? "󰁝" : "󰁅"
              color: transfer.live ? NekoColor.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
            }
            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0
              Text {
                Layout.fillWidth: true
                text: (transfer.modelData.files.length === 1 ? transfer.modelData.files[0] : transfer.modelData.files.length + " files")
                  + (transfer.modelData.direction === "outbound" ? " to " : " from ") + transfer.modelData.device_name
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }
              Text {
                Layout.fillWidth: true
                text: root.stateText(transfer.modelData) + " · " + root.sizeText(transfer.modelData.total_bytes)
                  + (transfer.modelData.state === "waiting_acceptance" && transfer.modelData.pin_code ? " · code " + transfer.modelData.pin_code : "")
                color: transfer.modelData.state === "failed" ? NekoColor.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
            PanelActionButton {
              visible: transfer.live
              iconText: "󰅖"
              tooltipText: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.act(["cancel", transfer.modelData.id])
            }
          }
          Rectangle {
            Layout.fillWidth: true
            visible: transfer.modelData.state === "transferring"
            implicitHeight: Style.space(4)
            radius: height / 2
            color: root.softer
            Rectangle {
              width: parent.width * Math.min(1, transfer.modelData.transferred_bytes / Math.max(1, transfer.modelData.total_bytes))
              height: parent.height
              radius: height / 2
              color: NekoColor.accent
              Behavior on width { NumberAnimation { duration: Style.duration(200) } }
            }
          }
        }
      }

      Text {
        Layout.fillWidth: true
        visible: root.note !== ""
        text: root.note
        color: root.noteBad ? NekoColor.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }
}
