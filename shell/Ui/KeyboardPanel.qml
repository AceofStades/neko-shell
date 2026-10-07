import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.Commons

// Layer-shell popup attached to a bar widget icon, designed for
// click-driven AND keyboard-driven panels (e.g. SUPER+CTRL+W summon).
//
// Built on PanelWindow with a brief WlrKeyboardFocus.Exclusive prime followed
// by OnDemand rather than PopupWindow (xdg-popup). The prime acquires focus
// both when the surface maps and when it reopens while still mapped for its
// fade-out. xdg-popups don't get that — they only receive keys after a
// click/hover routes focus through their parent surface — so keyboard-summoned
// popups fell flat without it.
//
// Exclusive would also grant map-time focus, but it makes Hyprland route
// *every* pointer event to the exclusive surface no matter which output
// the cursor is over, which leaves clicks on any other monitor unable to
// reach the dismissal surfaces below.
//
// API is a subset of Common.PopupCard: anchorItem, owner, bar, open,
// padding, margin, contentWidth/Height, centerOnBar, default contentItem.
// Missing on purpose (for now): triggerMode ("hover"), containsMouse.
//
// Positioning: full-screen layer-shell with the card placed inside at
// `cardOrigin`. We use the bar window's height/width for the perpendicular
// axis (away-from-bar) because mapToItem on the anchor returns
// bar-content-relative coords with internal layout offsets baked in
// (e.g. ~13px from the bar's vertical centering of its widget row). The
// parallel axis (along-the-bar) uses the anchor's content x/y since the
// bar spans full screen on that axis.
//
// Outside-click dismissal: an overlay MouseArea catches clicks, with the
// QsWindow.mask subtracting the bar strip so clicks on the bar still
// reach the bar widgets (activePopout coordinator hands off to another
// popup if the user clicks a different bar icon).
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property var borderSpec: Border.surfaceSpec("popups", "border", NekoColor.popups.border, Math.max(1, Style.space(2)))
  property bool centerOnBar: false
  property bool open: false
  property int gap: Math.max(Style.gapsOut, Style.space(5))  // distance between bar edge and panel
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false

  // Item that should take keyboard focus once the panel maps. Typically a
  // PanelKeyCatcher inside the panel content. Layer-shell grants focus to the
  // surface during the Exclusive prime, but Qt still needs an active-focus
  // target inside the surface for Keys.onPressed handlers to fire. Schedule
  // the focus through Qt.callLater so it runs after the surface is fully
  // mapped and child items have completed layout.
  property Item focusTarget: null

  default property alias contentItem: contentHolder.children

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && backingWindowVisible) focusPrimeTimer.restart()
  }

  // --- screen + lifetime ---------------------------------------------------

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open || card.opacity > 0 || popoutSwitching || (attached && shownHeight > 0.5)
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "neko-keyboard-panel"
  WlrLayershell.layer: WlrLayer.Overlay
  // Keyboard focus follows `open` (NOT `visible`). The window remains
  // mapped during the fade-out so the opacity animation has something to
  // animate, but keyboard/click ownership must release the moment the
  // logical close fires — otherwise the user is locked out for 140ms.
  //
  // Prime with Exclusive on every open, then settle on OnDemand. Hyprland
  // focuses OnDemand when a surface first maps, but not when an already-mapped
  // fade-out surface changes from None back to OnDemand. Exclusive also takes
  // focus when the previously focused application has constrained the pointer.
  // The brief prime covers both cases; OnDemand then releases compositor-wide
  // pointer hit-testing so clicks can reach the dismissal windows below.
  WlrLayershell.keyboardFocus: open
    ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  onBackingWindowVisibleChanged: beginFocusPrime()

  // Full-screen layer-shell. The visible card is positioned inside via
  // `cardOrigin`. The `mask` below makes the bar area click-through (so
  // the user can click another bar icon while the panel is open and the
  // activePopout coordinator swaps to that popup); everywhere else, the
  // overlay catches the click and dismisses via the MouseArea below.
  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  // Clickable region is the whole screen. Clicks in the bar strip are
  // forwarded to registered bar buttons so switching between panel icons
  // works in one click even when the overlay surface is above the bar.
  readonly property real _barStripSize: {
    if (!bar) return 0
    var actual = (root.barPos === "top" || root.barPos === "bottom") ? root.barH : root.barW
    return Math.max(bar.barSize, actual) + root.barInset + root.gap
  }
  mask: Region {
    width: root.screenW
    height: root.screenH
  }

  // Track every layout change between the bar's contentItem and the
  // anchor item. `transform` updates whenever any item in that chain
  // moves/resizes, which is what makes the position binding below
  // actually reactive — mapToItem on its own is a one-shot.
  TransformWatcher {
    id: anchorWatcher
    a: anchorWindow ? anchorWindow.contentItem : null
    b: anchorItem
  }

  // Anchor item's position within the bar's content surface. For a
  // full-width top bar, the content x maps directly to screen x; the y
  // returned here has the bar's internal padding baked in (e.g. ~13px
  // from vertical centering of the widget row), which is why `cardOrigin`
  // below uses `barH` for the perpendicular axis instead of this y.
  readonly property point anchorScreenPos: {
    anchorWatcher.transform  // reactive dependency
    if (!anchorItem || !anchorWindow) return Qt.point(0, 0)
    return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
  }
  readonly property real anchorW: anchorItem ? anchorItem.width : 0
  readonly property real anchorH: anchorItem ? anchorItem.height : 0
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - ((barPos === "left" || barPos === "right") ? barReachW + gap + margin : margin * 2))
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - ((barPos === "top" || barPos === "bottom") ? barReachH + gap + margin : margin * 2))
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function fittedContentHeight(implicitHeight, cap) {
    var desired = Math.max(root.verticalContentInset, (Number(implicitHeight) || 0) + root.verticalContentInset)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    if (cap !== undefined && Number(cap) > 0) maxHeight = Math.min(maxHeight, Number(cap))
    return Math.round(Math.min(desired, maxHeight))
  }

  function cappedContentHeight(height) {
    var desired = Math.max(root.padding * 2, Number(height) || root.padding * 2)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  // Desired top-left of the card in screen coordinates. For the
  // perpendicular axis (away-from-bar) we anchor to the bar window's edge
  // directly — not the anchor item's y/x — because mapToItem(barContent)
  // returns coordinates in the bar's content space, which can be offset
  // from the bar surface's screen-anchored corner by internal layout
  // (centering wrappers, padding). The bar's surface IS aligned to its
  // anchored screen edge, so using `barW`/`barH` gives the right edge
  // regardless of how the bar's internal widgets are positioned. For the
  // parallel axis (along the bar) the anchor item's reported position is
  // still consistent with the bar content origin, so it's accurate for
  // centering the card under the icon.
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  // Attached, the bar window reaches past the bar for its groups' shoulders
  readonly property real barH: !anchorWindow ? 0 : anchorWindow.barHeight !== undefined ? anchorWindow.barHeight : anchorWindow.height
  // A floating bar sits this far in from its screen edges, so its far edge
  // is that much further out and its content starts that much along
  // Attached to the top edge, the bar meets its edges and keeps no gap
  readonly property real barInset: bar && bar.centerTopAttached === true ? 0 : Style.bar.floatMargin
  readonly property real barInsetAcross: barInset
  readonly property real barReachW: barW + barInset
  readonly property real barReachH: barH + barInsetAcross
  // Attached style (a top bar hanging from the screen's edge): the card grows
  // down out of the bottom of the widget's group, flat-topped and joined to
  // it, its top corners curving into the group's edge, and snaps to the
  // screen's side when it comes near it. Floating, it's a card of its own.
  readonly property bool attached: !!bar && bar.centerTopAttached === true && barPos === "top" && !centerOnBar
  readonly property color attachedColor: bar && bar.attachedPanelColor !== undefined ? bar.attachedPanelColor : NekoColor.popups.background
  readonly property real snapReach: Style.space(40)
  readonly property bool snappedLeft: attached && cardOrigin.x <= 0.5
  readonly property bool snappedRight: attached && cardOrigin.x + contentWidth >= screenW - 0.5
  // It stays within its group's span when it fits there, against the
  // group's ends when it comes near them
  readonly property var groupSpan: {
    anchorWatcher.transform
    return attached && typeof bar.groupSpan === "function" ? bar.groupSpan(anchorItem) : null
  }
  readonly property bool groupFits: !!groupSpan && groupSpan.right - groupSpan.left >= contentWidth
  // Flush with the group's inner end, it runs straight down from it: no
  // shoulder on that side, and the group squares its corner there
  readonly property bool flushStart: groupFits && !snappedLeft && Math.abs(cardOrigin.x - groupSpan.left) < 0.5
  readonly property bool flushEnd: groupFits && !snappedRight && Math.abs(cardOrigin.x + contentWidth - groupSpan.right) < 0.5
  // Wider than its group (a widget on its own), it reaches past the group's
  // end: the group squares its corner there, a fillet joins the group's
  // side to the card's top, and that free top corner rounds
  readonly property bool overhangsStart: attached && !!groupSpan && !snappedLeft && cardOrigin.x < groupSpan.left - 0.5
  readonly property bool overhangsEnd: attached && !!groupSpan && !snappedRight && cardOrigin.x + contentWidth > groupSpan.right + 0.5
  readonly property real freeCorner: Style.space(18)
  Binding {
    when: root.attached && root.open && root.bar && root.bar.openCardFlushStart !== undefined
    target: root.bar
    property: "openCardFlushStart"
    value: root.flushStart || root.overhangsStart
    restoreMode: Binding.RestoreValue
  }
  Binding {
    when: root.attached && root.open && root.bar && root.bar.openCardFlushEnd !== undefined
    target: root.bar
    property: "openCardFlushEnd"
    value: root.flushEnd || root.overhangsEnd
    restoreMode: Binding.RestoreValue
  }

  // How far it has grown: a spring to the card's height as it opens, back to
  // nothing as it closes; the contents, at their full size, are clipped to it
  property real shownHeight: attached ? (open ? contentHeight : 0) : contentHeight
  Behavior on shownHeight {
    enabled: root.attached && !Style.reduceMotion
    SpringAnimation { spring: 3.2; damping: 0.36; epsilon: 0.5 }
  }

  // The contents come in once the card is mostly there, and go at once
  property bool contentShown: !attached
  function syncAttachedContent() {
    if (!attached) return
    if (open) contentIn.restart()
    else { contentIn.stop(); contentShown = false }
  }
  onAttachedChanged: contentShown = !attached || open
  Timer {
    id: contentIn
    interval: Style.duration(110)
    onTriggered: root.contentShown = true
  }

  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = 0, y = 0
    if (centerOnBar && (barPos === "top" || barPos === "bottom")) {
      x = screenW / 2 - contentWidth / 2
      y = barPos === "bottom" ? screenH - barReachH - contentHeight - gap : barReachH + gap
    } else if (centerOnBar) {
      x = barPos === "left" ? barReachW + gap : screenW - barReachW - contentWidth - gap
      y = screenH / 2 - contentHeight / 2
    } else if (barPos === "bottom") {
      x = barInset + anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = screenH - barReachH - contentHeight - gap
    } else if (barPos === "left") {
      x = barReachW + gap
      y = barInset + anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else if (barPos === "right") {
      x = screenW - barReachW - contentWidth - gap
      y = barInset + anchorScreenPos.y + anchorH / 2 - contentHeight / 2
    } else { // "top" (default)
      x = barInset + anchorScreenPos.x + anchorW / 2 - contentWidth / 2
      y = barReachH + gap
    }
    if (attached) {
      // Joined to the group's bottom edge, against the screen's side if near it
      y = barH - Style.bar.capsuleInset
      if (groupFits) {
        x = Math.max(groupSpan.left, Math.min(x, groupSpan.right - contentWidth))
        if (x - groupSpan.left < snapReach) x = groupSpan.left
        else if (groupSpan.right - x - contentWidth < snapReach) x = groupSpan.right - contentWidth
      }
      if (x < snapReach) x = 0
      else if (x + contentWidth > screenW - snapReach) x = screenW - contentWidth
      return Qt.point(Math.round(x), Math.round(y))
    }
    x = Math.max(margin, Math.min(x, screenW - contentWidth - margin))
    y = Math.max(margin, Math.min(y, screenH - contentHeight - margin))
    return Qt.point(Math.round(x), Math.round(y))
  }


  // --- popout coordination (same-bar single-popout model) -----------------

  // Coordinate on `open`, not `visible`. `visible` lags into the fade-out
  // animation, which made ownership transfer to a sibling popup race.
  onOpenChanged: {
    syncAttachedContent()
    if (open) {
      focusPrimed = false
      beginFocusPrime()
      if (focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
    } else {
      focusPrimeTimer.stop()
      focusPrimed = false
    }
    if (!bar) return
    if (open) {
      popoutSwitchClosing = false
      popoutSwitching = bar.activePopout && bar.activePopout !== coordinatorKey
      bar.requestPopout(coordinatorKey)
      if (popoutSwitching) popoutSwitchTimer.restart()
    } else {
      popoutSwitchClosing = !!(owner && owner.popoutSwitchClosing)
      popoutSwitching = false
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
      if (popoutSwitchClosing) closeSwitchTimer.restart()
    }
  }

  Timer {
    id: focusPrimeTimer
    // Leave enough time for multiple Qt/Wayland commit cycles after the
    // backing window becomes visible while keeping the compositor-wide
    // Exclusive phase imperceptibly short. This interval is covered by the
    // immediate hide/re-summon acceptance case.
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  Timer {
    id: popoutSwitchTimer
    interval: 150
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    id: closeSwitchTimer
    interval: 1
    onTriggered: root.popoutSwitchClosing = false
  }

  // --- outside-click dismissal --------------------------------------------

  // Catches clicks anywhere in the clickable region (i.e. everywhere on
  // screen except the bar strip, which is masked out). The card has its
  // own MouseArea below so clicks on it don't bubble up here. Disabled
  // during the fade-out so the dying overlay doesn't swallow clicks that
  // were meant for the apps behind it.
  MouseArea {
    id: dismissArea
    anchors.fill: parent
    enabled: root.open
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    property bool hoveringBar: false
    cursorShape: hoveringBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    function inBarRegion(px, py) {
      if (root.barPos === "bottom") return py >= root.screenH - root._barStripSize
      if (root.barPos === "left") return px <= root._barStripSize
      if (root.barPos === "right") return px >= root.screenW - root._barStripSize
      return py <= root._barStripSize
    }

    // A screen point in the bar window, which a floating bar keeps barInset
    // in from its screen edges
    function barPoint(px, py) {
      var inset = root.barInset
      if (root.barPos === "bottom") return Qt.point(px - inset, py - (root.screenH - root.barH - inset))
      if (root.barPos === "right") return Qt.point(px - (root.screenW - root.barW - inset), py - inset)
      return Qt.point(px - inset, py - root.barInsetAcross)
    }

    function pressTargetAt(px, py) {
      if (!root.anchorWindow || !root.anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return null
      var p = barPoint(px, py)
      var targets = root.bar.clickTargets
      for (var i = targets.length - 1; i >= 0; i--) {
        var target = targets[i]
        if (!target || !target.triggerPress || target.visible === false || target.opacity === 0 || !target.mapToItem) continue
        if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(target, root.anchorWindow)) continue
        var pos = root.anchorWindow.itemPosition(target)
        if (p.x >= pos.x && p.x <= pos.x + target.width && p.y >= pos.y && p.y <= pos.y + target.height) return target
      }
      return null
    }

    function forwardBarClick(px, py, button) {
      if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
      var target = pressTargetAt(px, py)
      if (!target) return false
      target.triggerPress(button)
      return true
    }

    onPositionChanged: function(mouse) { hoveringBar = inBarRegion(mouse.x, mouse.y) }
    onExited: hoveringBar = false
    onClicked: function(mouse) {
      // While Exclusive is priming, Hyprland may route a click from another
      // output here with translated coordinates. Never interpret that as a
      // click on this output's bar.
      if (root.focusPrimed && inBarRegion(mouse.x, mouse.y) && forwardBarClick(mouse.x, mouse.y, mouse.button)) return
      root.close()
    }
  }

  // The panel surface only spans the anchor's screen, and the compositor
  // hit-tests pointer input per output, so `dismissArea` above can never see
  // a click on another monitor. Give every other output a transparent twin
  // whose only job is to catch that click. They exist only while the panel is
  // logically open (not during the fade-out, matching `dismissArea.enabled`).
  //
  // Keyboard focus is None: these must catch the pointer without taking focus
  // from the panel when the cursor merely crosses onto their output.
  Variants {
    model: root.open ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        // Compare by output name: the anchor screen must be known before any
        // twin maps, or a twin would cover the panel's own output.
        visible: root.open && !!root.screen && modelData.name !== root.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "neko-keyboard-panel-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  // --- card ----------------------------------------------------------------

  // Attached, the card's top corners curve into the group's bottom edge,
  // except against the screen's side
  Shape {
    id: shoulders
    readonly property real size: Style.space(14)
    readonly property real cardLeft: card.x
    readonly property real cardRight: card.x + card.width
    readonly property real cardTop: card.y
    readonly property real groupLeft: root.groupSpan ? root.groupSpan.left : 0
    readonly property real groupRight: root.groupSpan ? root.groupSpan.right : 0

    anchors.fill: parent
    visible: root.attached && root.shownHeight > size
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.snappedLeft || root.flushStart || root.overhangsStart ? "transparent" : root.attachedColor
      strokeWidth: 0
      strokeColor: "transparent"
      startX: shoulders.cardLeft - shoulders.size
      startY: shoulders.cardTop
      PathLine { x: shoulders.cardLeft; y: shoulders.cardTop }
      PathLine { x: shoulders.cardLeft; y: shoulders.cardTop + shoulders.size }
      PathArc { x: shoulders.cardLeft - shoulders.size; y: shoulders.cardTop; radiusX: shoulders.size; radiusY: shoulders.size; direction: PathArc.Counterclockwise }
    }
    ShapePath {
      fillColor: root.snappedRight || root.flushEnd || root.overhangsEnd ? "transparent" : root.attachedColor
      strokeWidth: 0
      strokeColor: "transparent"
      startX: shoulders.cardRight + shoulders.size
      startY: shoulders.cardTop
      PathLine { x: shoulders.cardRight; y: shoulders.cardTop }
      PathLine { x: shoulders.cardRight; y: shoulders.cardTop + shoulders.size }
      PathArc { x: shoulders.cardRight + shoulders.size; y: shoulders.cardTop; radiusX: shoulders.size; radiusY: shoulders.size }
    }
    // Reaching past the group: fillets in the corner between the group's
    // side and the card's top
    ShapePath {
      fillColor: root.overhangsStart ? root.attachedColor : "transparent"
      strokeWidth: 0
      strokeColor: "transparent"
      startX: shoulders.groupLeft
      startY: shoulders.cardTop - shoulders.size
      PathLine { x: shoulders.groupLeft; y: shoulders.cardTop }
      PathLine { x: shoulders.groupLeft - shoulders.size; y: shoulders.cardTop }
      PathArc { x: shoulders.groupLeft; y: shoulders.cardTop - shoulders.size; radiusX: shoulders.size; radiusY: shoulders.size; direction: PathArc.Counterclockwise }
    }
    ShapePath {
      fillColor: root.overhangsEnd ? root.attachedColor : "transparent"
      strokeWidth: 0
      strokeColor: "transparent"
      startX: shoulders.groupRight
      startY: shoulders.cardTop - shoulders.size
      PathLine { x: shoulders.groupRight; y: shoulders.cardTop }
      PathLine { x: shoulders.groupRight + shoulders.size; y: shoulders.cardTop }
      PathArc { x: shoulders.groupRight; y: shoulders.cardTop - shoulders.size; radiusX: shoulders.size; radiusY: shoulders.size }
    }
  }

  BorderSurface {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.contentWidth
    height: root.attached ? root.shownHeight : root.contentHeight
    clip: root.attached
    color: root.attached ? "transparent" : NekoColor.popups.background
    borderSpec: root.attached ? Border.none() : root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    opacity: root.attached ? (root.open || root.shownHeight > 0.5 ? 1.0 : 0) : (root.open || root.popoutSwitching ? 1.0 : 0)

    // Attached: flat on top, joined to the group; rounded below, square
    // where it meets the screen's side
    Rectangle {
      anchors.fill: parent
      visible: root.attached
      color: root.attachedColor
      topLeftRadius: root.overhangsStart ? root.freeCorner : 0
      topRightRadius: root.overhangsEnd ? root.freeCorner : 0
      bottomLeftRadius: root.snappedLeft ? 0 : Style.space(18)
      bottomRightRadius: root.snappedRight ? 0 : Style.space(18)
    }

    Behavior on opacity {
      enabled: !root.popoutSwitching && !root.popoutSwitchClosing
      NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
    }

    // Swallow clicks on the card so they don't bubble to the dismissal
    // MouseArea behind us.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    // At the card's full size even while an attached card grows, so the
    // contents never squeeze; the card clips them
    Item {
      id: contentHolder
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.leftMargin: card.contentLeftInset
      height: root.contentHeight - card.contentTopInset - card.contentBottomInset
      opacity: root.attached ? (root.contentShown ? 1.0 : 0) : root.popoutSwitching ? (root.open ? 1.0 : 0) : 1.0

      Behavior on opacity {
        enabled: root.popoutSwitching || root.attached
        NumberAnimation { duration: Style.duration(root.attached && !root.contentShown ? 80 : 140); easing.type: Easing.OutCubic }
      }
    }
  }
}
