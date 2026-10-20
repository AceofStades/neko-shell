import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "OsdModel.js" as OsdModel

Item {
  id: root

  property bool opened: false

  // Over a fullscreen app the bar is out of sight, so the OSD leaves by curling
  // into a ball and rising toward the island's place at the top of the screen,
  // rather than fading where it stands. `curl` is the ball forming, `rise` the
  // ball going up; both run only on the way out, and a new show cancels them.
  readonly property bool fullscreenHere: !!panel.screen && Island.isFullscreen(panel.screen.name)
  property bool exiting: false
  property real curl: 0
  property real rise: 0

  onOpenedChanged: {
    if (opened) {
      curlExit.stop()
      exiting = false
      curl = 0
      rise = 0
    } else if (fullscreenHere && !Style.reduceMotion) {
      exiting = true
      curlExit.restart()
    }
  }

  SequentialAnimation {
    id: curlExit
    NumberAnimation { target: root; property: "curl"; to: 1; duration: Style.duration(260); easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "rise"; to: 1; duration: Style.duration(340); easing.type: Easing.InCubic }
    ScriptAction { script: { root.exiting = false; root.curl = 0; root.rise = 0 } }
  }
  property string icon: ""
  property string message: ""
  property string iconKey: ""
  property int value: 0
  property int maxValue: 100
  property bool hasProgress: true
  property int duration: 1200

  readonly property bool mediaOsd: iconKey.indexOf("media") === 0 || iconKey.indexOf("player") === 0

  // The card is built out of measured columns instead of fixed widths, so it
  // keeps exactly `pad` between border and content on every side whatever
  // glyph or message it carries. Messages grow with their text up to
  // `maxMessageWidth` and elide beyond it.
  readonly property int pad: Style.space(10)
  readonly property int sidePad: Style.space(18)
  readonly property int gap: Style.space(12)
  // A glyph next to a message reads airier than it measures: the icon outline
  // and the letterforms both fall away from their ink extremes, so the space
  // between them opens up well past the nominal gap. Text takes two thirds of
  // it; the progress bar's hard edge keeps the full gap.
  readonly property int messageGap: Math.round(root.gap * 2 / 3)
  readonly property int trackHeight: Style.space(6)
  readonly property int maxMessageWidth: root.mediaOsd ? Style.space(325) : Style.space(190)

  // Compute the bar width that fits within the island rest width.
  // Island.restRects[width] is the card width. Available space for the bar:
  // cardWidth - iconWidth - valueWidth - 2*gap - 2*pad (card horizontal padding).
  // But the card's width IS islandWidth, and the Row is centered with no extra
  // horizontal margins, so the Row can use up to islandWidth. We clamp the bar
  // to at least trackHeight (so it stays a pill) and at most the nominal barWidth.
  function barWidthFor(islandWidth) {
    var avail = islandWidth - root.iconWidth - root.valueWidth - 2 * root.gap
    return Math.max(root.trackHeight, Math.min(root.nominalBarWidth, avail))
  }
  readonly property int nominalBarWidth: Style.space(160)
  // 64 ticks are the backlight's or the volume's sixteen steps of four
  readonly property bool stepped: maxValue === 64
  // As wide as the compact island, not the whole group beside it
  readonly property real pillWidth: {
    var rest = panel.screen ? Island.restRects[panel.screen.name] : null
    return rest ? (rest.coreWidth || rest.width) : 0
  }

  // Nerd Font glyphs draw well outside their monospace cell, so the icon
  // column is measured by ink rather than by advance width. Progress OSDs pin
  // it to the widest glyph the model can return, so the bar doesn't shift when
  // volume crosses an icon threshold.
  readonly property int iconInkWidth: Math.ceil(iconMetrics.tightBoundingRect.width)
  readonly property int iconWidth: root.hasProgress
    ? Math.max(root.iconInkWidth, Math.ceil(widestIconMetrics.tightBoundingRect.width))
    : root.iconInkWidth
  // Same idea for the readout: it is as wide as the longest percentage so the
  // digits don't jitter between 9% and 100%.
  readonly property int valueWidth: Math.ceil(Math.max(valueMetrics.advanceWidth, messageMetrics.advanceWidth))
  readonly property int messageWidth: Math.min(Math.ceil(messageMetrics.advanceWidth), root.maxMessageWidth)
  // contentWidth uses the adaptive bar width when we know the island width,
  // otherwise falls back to nominalBarWidth for the standalone OSD window.
  readonly property int contentWidth: root.hasProgress
    ? (panel.screen && Island.restRects[panel.screen.name]
         ? root.iconWidth + root.gap + root.barWidthFor(root.pillWidth) + root.gap + root.valueWidth
         : root.iconWidth + root.gap + root.nominalBarWidth + root.gap + root.valueWidth)
    : (root.message === "" ? root.iconWidth : root.iconWidth + root.messageGap + root.messageWidth)

  function iconFor(name, percent) {
    return OsdModel.iconFor(name, percent)
  }

  function show(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration) {
    var next = OsdModel.stateForShow(iconName, rawMessage, rawValue, rawMax, rawProgressText, rawDuration)
    // The bar's island shows it instead while it's up
    if (Island.active) {
      opened = false
      Island.showOsd({ icon: next.icon, message: next.message, value: next.value, maxValue: next.maxValue, hasProgress: next.hasProgress }, next.duration)
      return
    }
    // Update before opening so a fresh OSD starts at its new value; only
    // subsequent updates while it remains open animate the progress bar.
    iconKey = next.iconKey
    maxValue = next.maxValue
    hasProgress = next.hasProgress
    value = next.value
    message = next.message
    icon = next.icon
    duration = next.duration
    opened = true
    if (duration > 0) hideTimer.restart()
    else hideTimer.stop()
  }

  function open(payloadJson) {
    try {
      var p = JSON.parse(payloadJson || "{}")
      show(p.icon || "", p.message || "", p.value === undefined ? "" : String(p.value), p.max === undefined ? "100" : String(p.max), p.progressText || "", p.duration === undefined ? "1200" : String(p.duration))
    } catch (e) {}
  }

  function close() { opened = false }

  // The keyboard backlight: its own key cycles the levels in firmware,
  // without a key the compositor sees or a signal anyone sends, so its
  // level is read a few times a second (a small sysfs read, no process) and
  // shown whenever it moves
  property string kbdLed: ""
  property int kbdMax: 0
  property int kbdLevel: -1

  Process {
    running: true
    command: ["neko-kbd-brightness", "path"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.kbdLed = String(text || "").trim()
    }
  }

  FileView {
    id: kbdMaxFile
    path: root.kbdLed ? root.kbdLed + "/max_brightness" : ""
    onLoaded: root.kbdMax = Number(String(text()).trim()) || 0
  }

  FileView {
    id: kbdLevelFile
    path: root.kbdLed ? root.kbdLed + "/brightness" : ""
    onLoaded: {
      var level = Number(String(text()).trim())
      if (!isFinite(level)) return
      // The first read only learns where it starts
      if (root.kbdLevel >= 0 && level !== root.kbdLevel && root.kbdMax > 0)
        root.show("keyboard", "", String(level), String(root.kbdMax), level + "/" + root.kbdMax, "1200")
      root.kbdLevel = level
    }
  }

  Timer {
    interval: 300
    repeat: true
    running: root.kbdLed !== "" && root.kbdMax > 0
    onTriggered: kbdLevelFile.reload()
  }

  Timer {
    id: hideTimer
    interval: root.duration
    onTriggered: root.opened = false
  }

  TextMetrics {
    id: messageMetrics
    font.family: Style.font.family
    font.weight: Font.Medium
    font.pixelSize: Style.font.body
    text: root.message
  }

  TextMetrics {
    id: valueMetrics
    font: messageMetrics.font
    text: "100%"
  }

  TextMetrics {
    id: iconMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.iconLarge
    text: root.icon
  }

  TextMetrics {
    id: widestIconMetrics
    font: iconMetrics.font
    text: OsdModel.widestIcon
  }

  ShellIpc {
    target: "osd"
    function show(payloadJson: string): string {
      root.open(payloadJson)
      return "ok"
    }
    function close(): string { root.close(); Island.hideOsd(); return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  OverlayWindow {
    id: panel
    shown: root.opened || root.exiting
    shownKeyboardFocus: WlrKeyboardFocus.None
    WlrLayershell.namespace: "neko-osd"
    // Visual-only surface: keep the layer-shell input region empty so the OSD
    // never blocks clicks to the desktop below it.
    mask: Region {}

    // Match the island's compact/rest width so the standalone OSD has the same
    // footprint as the bar's center island at rest.
    readonly property real islandWidth: (panel.screen && Island.restRects[panel.screen.name])
      ? (Island.restRects[panel.screen.name].coreWidth || Island.restRects[panel.screen.name].width)
      : Style.space(300)

    BorderSurface {
      id: card
      // A translucent pill (blurred by the compositor) that fades and rises in
      // Curling, it narrows to a ball as wide as it is tall
      width: panel.islandWidth + (height - panel.islandWidth) * root.curl
      height: card.borderTop + root.pad + Style.font.iconLarge + root.pad + card.borderBottom
      clip: root.exiting
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(56) + (root.opened || root.exiting ? 0 : -Style.space(8))
      transform: Translate { y: -root.rise * (card.parent.height - Style.space(56)) }
      scale: 1 - 0.25 * root.rise
      color: NekoColor.osd.background
      borderSpec: Border.flat(NekoColor.osd.border, 1)
      radius: height / 2
      opacity: root.opened || root.exiting ? 1 : 0

      Behavior on opacity { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      Behavior on anchors.bottomMargin { NumberAnimation { duration: Style.duration(200); easing.type: Easing.OutCubic } }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: card.borderTop + root.pad
        anchors.bottomMargin: card.borderBottom + root.pad
        spacing: root.hasProgress ? root.gap : root.messageGap
        // The contents give way as the ball forms
        opacity: 1 - Math.min(1, root.curl * 2.2)
        Item {
          width: root.iconWidth
          height: parent.height
          Text {
            textFormat: Text.PlainText
            // Sit the glyph's ink flush in the column, centered when the
            // column is wider than this particular glyph.
            x: Math.round((root.iconWidth - root.iconInkWidth) / 2 - iconMetrics.tightBoundingRect.x)
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            font: iconMetrics.font
            color: NekoColor.osd.icon
          }
        }
        Rectangle {
          visible: root.hasProgress && !root.stepped
          width: (panel.screen && Island.restRects[panel.screen.name])
               ? root.barWidthFor(root.pillWidth)
               : root.nominalBarWidth
          height: root.trackHeight
          radius: height / 2
          anchors.verticalCenter: parent.verticalCenter
          color: NekoColor.osd.track
          Rectangle {
            readonly property real fraction: root.hasProgress ? root.value / root.maxValue : 0

            height: parent.height
            radius: height / 2
            // Never narrower than it is tall once there is any value, so the fill stays a pill
            width: fraction > 0 ? Math.max(height, parent.width * fraction) : 0
            color: NekoColor.osd.fill

            Behavior on width {
              enabled: root.opened
              NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
            }
          }
        }
        // Sixteen steps, the fine steps filling one as they come (the backlight
        // and the volume report 64 ticks)
        Row {
          visible: root.hasProgress && root.stepped
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)
          readonly property real filled: root.hasProgress ? root.value / root.maxValue * 16 : 0
          readonly property real meter: (panel.screen && Island.restRects[panel.screen.name]) ? root.barWidthFor(root.pillWidth) : root.nominalBarWidth

          Repeater {
            model: 16
            Rectangle {
              required property int index
              width: Math.max(Style.space(3), (parent.meter - 15 * parent.spacing) / 16)
              height: root.trackHeight
              radius: height / 2
              color: NekoColor.osd.track

              Rectangle {
                height: parent.height
                radius: height / 2
                width: parent.width * Math.max(0, Math.min(1, parent.parent.filled - parent.index))
                color: NekoColor.osd.fill
              }
            }
          }
        }
        Text {
          textFormat: Text.PlainText
          visible: root.message !== ""
          width: root.hasProgress ? root.valueWidth : root.messageWidth
          // The readout hugs the card edge so a short percentage doesn't leave
          // a hole in the padding; the slack lands in the gap after the bar.
          horizontalAlignment: root.hasProgress ? Text.AlignRight : Text.AlignLeft
          anchors.verticalCenter: parent.verticalCenter
          text: root.message
          font: messageMetrics.font
          color: NekoColor.osd.text
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }
  }
}
