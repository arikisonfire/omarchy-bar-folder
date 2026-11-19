import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// One widget inside Bar Folder. A bar widget is instantiated from its own
// entry point, invisible and zero-width underneath the folder icon, so its
// popup still anchors to the bar right where the user clicked. The tile in
// the folder panel drives it through the click target the widget registers.
//
// `builtin.notifications` has no bar widget in Omarchy; it is implemented
// here on top of the shell's `notifications` IPC target.
Item {
  id: root

  required property string widgetId
  // The plugin that implements the widget; differs from widgetId when an
  // enabled local clone stands in for a built-in.
  property string pluginId: widgetId
  property url source: ""
  property bool builtin: false
  // The folder's own bar facade; popout coordination goes through it so
  // opening a hosted popup closes the folder panel and vice versa.
  property var realBar: null
  property var widgetSettings: ({})
  // Bar Folder's service, which runs the services of hosted plugins.
  property var folderService: null

  signal settingsPersisted(string widgetId, var settings)
  signal closeFolderRequested()

  readonly property var widget: loader.item
  readonly property bool failed: !builtin && (String(source) === "" || loader.status === Loader.Error)
  // Set by Bar Folder while its panel (and so this widget's tile) is open.
  property bool showing: false
  // The buttons the widget registers with its bar.
  property var targets: []
  // A visible item inside the widget that offers triggerPress without being
  // registered, e.g. a tray icon; see scanTree().
  property var treeTarget: null

  // The test the bar applies before it presses a button (Bar.qml,
  // moduleTargetClickable).
  function clickable(target) {
    return !!target
      && target.visible !== false
      && target.opacity !== 0
      && target.interactive !== false
      && target.pressable !== false
      && target.concealed !== true
      && typeof target.triggerPress === "function"
  }

  // The button the tile stands for, in this order:
  //   1. a registered button the bar itself would press;
  //   2. a visible item in the widget that offers triggerPress (a tray icon);
  //   3. a registered button that is only hidden for now: concealed, or hidden
  //      by the widget itself, as icons shown only at night or while active are.
  // A button in a part of the widget that is not shown at all, such as the
  // chevron of a closed drawer, never stands for the widget: its glyph and its
  // click would be the wrong ones.
  readonly property var primaryTarget: {
    var list = targets
    var i
    for (i = 0; i < list.length; i++) if (clickable(list[i])) return list[i]
    var found = treeTarget
    if (found && clickable(found)) return found
    for (i = 0; i < list.length; i++) {
      var target = list[i]
      if (!target || typeof target.triggerPress !== "function") continue
      if (target.visible !== false) return target
      if (target.parent && target.parent.visible !== false) return target
    }
    return null
  }

  // Finds the first visible item in the widget that can be pressed like a bar
  // button. Run on load, when the folder opens and when the widget changes
  // size (a tray icon appearing, say), not as a binding: it walks the tree.
  function scanTree() {
    var item = loader.item
    if (root.builtin || !item) {
      root.treeTarget = null
      return
    }
    var queue = [item]
    for (var seen = 0; queue.length > 0 && seen < 600; seen++) {
      var node = queue.shift()
      if (!node || node.visible === false) continue
      if (node !== item && root.clickable(node)) {
        root.treeTarget = node
        return
      }
      var kids = node.children
      if (kids) for (var i = 0; i < kids.length; i++) queue.push(kids[i])
    }
    root.treeTarget = null
  }

  Timer {
    id: treeScan
    interval: 250
    onTriggered: root.scanTree()
  }

  Connections {
    target: root.widget
    ignoreUnknownSignals: true
    function onImplicitWidthChanged() { treeScan.restart() }
    function onImplicitHeightChanged() { treeScan.restart() }
  }

  onTargetsChanged: treeScan.restart()

  readonly property string glyph: {
    if (widgetId === "builtin.notifications") return notifications.dnd ? "󰂛" : "󰂚"
    if (!primaryTarget) return ""
    if (typeof primaryTarget.text === "string" && primaryTarget.text) return primaryTarget.text
    return glyphIn(primaryTarget, 0)
  }

  // Widgets that paint their own label (no `text` on the button) usually
  // still draw a one-character icon somewhere inside; use the first one.
  function glyphIn(item, depth) {
    if (!item || depth > 6) return ""
    var kids = item.children
    if (!kids) return ""
    for (var i = 0; i < kids.length; i++) {
      var kid = kids[i]
      if (!kid || kid.visible === false) continue
      if (typeof kid.text === "string" && kid.font !== undefined) {
        var text = kid.text.trim()
        if (text.length > 0 && text.length <= 2) return text
      }
      var nested = glyphIn(kid, depth + 1)
      if (nested) return nested
    }
    return ""
  }
  readonly property bool active: {
    if (widgetId === "builtin.notifications") return notifications.dnd
    return primaryTarget ? primaryTarget.active === true : false
  }
  // Widgets that draw their bar icon (a logo, say) rather than use a glyph;
  // the tile shows that drawing when there is no glyph to find.
  readonly property var iconComponent: primaryTarget && primaryTarget.iconComponent ? primaryTarget.iconComponent : null
  // Greyed out on the bar, the stock "off" look; the tile follows.
  readonly property bool dimmed: primaryTarget ? primaryTarget.dimmed === true : false
  readonly property bool opened: widget ? widget.opened === true : false
  // The tile stands for this widget, so the widget draws its icon in the
  // tile's colors: hostBar.barForeground below, which bar icons draw with.
  // On the bar it is a contrast color for the bar background; here the
  // background is the tile, accent-colored while the widget is lit.
  readonly property color tileForeground: (active || opened) ? Commons.Color.popups.background : Commons.Color.popups.text

  // Last resort for a button that draws neither a glyph nor an iconComponent
  // (an image, say): a picture of it. It is taken in the bar's window, as the
  // tiles live in another window (the folder panel), and refreshed while the
  // folder is open. The result object keeps the picture alive.
  readonly property bool wantsSnapshot: !builtin && !!primaryTarget && !glyph && !iconComponent
    && primaryTarget.width > 0 && primaryTarget.height > 0
    && typeof primaryTarget.grabToImage === "function"
  property var snapshot: null
  readonly property string snapshotUrl: snapshot && wantsSnapshot ? String(snapshot.url) : ""
  // Bar size of the pictured button, so the tile can scale it like a glyph.
  readonly property size snapshotSize: primaryTarget && wantsSnapshot
    ? Qt.size(primaryTarget.width, primaryTarget.height) : Qt.size(0, 0)

  function takeSnapshot() {
    var target = root.primaryTarget
    if (!root.wantsSnapshot || !target) {
      root.snapshot = null
      return
    }
    target.grabToImage(function(result) {
      if (root.primaryTarget === target) root.snapshot = result
    }, Qt.size(Math.ceil(target.width * 4), Math.ceil(target.height * 4)))
  }

  onWantsSnapshotChanged: Qt.callLater(root.takeSnapshot)
  onShowingChanged: if (showing) Qt.callLater(root.takeSnapshot)

  Timer {
    interval: 1500
    repeat: true
    running: root.showing && root.wantsSnapshot
    onTriggered: root.takeSnapshot()
  }
  readonly property string status: {
    if (widgetId === "builtin.notifications") return notifications.dnd ? "Do Not Disturb" : "On"
    if (primaryTarget && primaryTarget.tooltipText) return String(primaryTarget.tooltipText)
    if (!widget) return ""
    if (typeof widget.heroStatusText === "string" && widget.heroStatusText) return widget.heroStatusText
    if (widget.brightnessAvailable === true && typeof widget.brightnessPercent === "number")
      return "Brightness " + widget.brightnessPercent + "%"
    return ""
  }

  function refresh() {
    if (widgetId === "builtin.notifications") notifications.call("isDnd")
    else root.scanTree()
  }

  function press(button) {
    if (widgetId === "builtin.notifications") {
      if (button === Qt.LeftButton) {
        notifications.call("toggleDnd")
      } else {
        notifications.call("showHistory")
        root.closeFolderRequested()
      }
      return true
    }
    if (!primaryTarget) root.scanTree()
    var target = primaryTarget
    if (target) {
      target.triggerPress(button)
      return true
    }
    if (button !== Qt.LeftButton) return false
    return toggle()
  }

  function wheel(delta) {
    if (primaryTarget && typeof primaryTarget.wheelMoved === "function") primaryTarget.wheelMoved(delta)
  }

  function open() {
    if (widgetId === "builtin.notifications") return press(Qt.RightButton)
    if (!widget) return false
    if (typeof widget.open === "function") { widget.open(); return true }
    return press(Qt.LeftButton)
  }

  function close() {
    if (widget && typeof widget.close === "function") widget.close()
  }

  function toggle() {
    if (widgetId === "builtin.notifications") return press(Qt.LeftButton)
    if (!widget) return false
    if (typeof widget.togglePanel === "function") { widget.togglePanel(); return true }
    if (typeof widget.toggle === "function") { widget.toggle(); return true }
    if (typeof widget.open === "function" && typeof widget.close === "function") {
      if (opened) widget.close()
      else widget.open()
      return true
    }
    return false
  }

  function execShell(method, id, payload) {
    var command = ["omarchy-shell", "-q", "shell", method, String(id || "")]
    if (payload !== undefined) command.push(String(payload || "{}"))
    Quickshell.execDetached(command)
    return true
  }

  // Do Not Disturb state for the built-in notifications tile.
  QtObject {
    id: notifications

    property bool dnd: false

    function call(method) {
      if (root.widgetId !== "builtin.notifications") return
      if (notificationProc.running) {
        notificationProc.pending = method
        return
      }
      notificationProc.command = ["omarchy-shell", "notifications", method]
      notificationProc.running = true
    }
  }

  Process {
    id: notificationProc

    property string pending: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text || "").trim()
        if (state === "on" || state === "off") notifications.dnd = state === "on"
      }
    }
    onRunningChanged: {
      if (running || pending === "") return
      var next = pending
      pending = ""
      notifications.call(next)
    }
  }

  Component.onCompleted: refresh()

  // Shell facade scoped to the hosted widget: its own id maps onto the hosted
  // instance, settings land in the folder entry, anything else goes through
  // the shell's IPC like a hotkey would.
  QtObject {
    id: hostShell

    readonly property string pluginId: root.widgetId
    // No handle to the folder's own shell API or bar: through it a hosted
    // plugin could reach the folder's settings and other plugins' services.
    readonly property var barConfig: root.realBar && root.realBar.shell ? root.realBar.shell.barConfig : ({})
    readonly property var idleConfig: ({})
    readonly property var appLibrary: null
    readonly property var bar: null

    function owns(id) {
      var key = String(id || "")
      return key === root.widgetId || key === root.pluginId
    }
    // Only the hosted plugin's own service, as the shell's scoped API does.
    // Reads `folderService.services`, so bindings update once it has started.
    function serviceFor(id) {
      if (!owns(id) || !root.folderService) return null
      return root.folderService.services[root.pluginId]
        ? root.folderService.serviceFor(root.pluginId) : null
    }
    function firstPartyServiceFor(id) { return null }
    function pluginShellForBarEntry(ownerId, moduleName) { return null }
    function mutateShellConfig(mutator) { return false }

    function summon(id, payloadJson) {
      return owns(id) ? root.open() : root.execShell("summon", id, payloadJson)
    }
    function hide(id) {
      if (!owns(id)) return root.execShell("hide", id)
      root.close()
      return true
    }
    function toggle(id, payloadJson) {
      return owns(id) ? root.toggle() : root.execShell("toggle", id, payloadJson)
    }
    function isPluginOpen(id) {
      return owns(id) && root.opened
    }
    function updateEntryInline(id, settings) {
      if (!owns(id)) return false
      var copy = {}
      for (var key in settings) if (key !== "id") copy[key] = settings[key]
      root.settingsPersisted(root.widgetId, copy)
      return true
    }
  }

  // What the hosted widget sees as `bar`.
  QtObject {
    id: hostBar

    readonly property var shell: hostShell
    readonly property string pluginId: root.widgetId
    readonly property string moduleName: root.widgetId

    readonly property color foreground: root.realBar ? root.realBar.foreground : Commons.Color.foreground
    readonly property color barForeground: root.tileForeground
    readonly property color background: root.realBar ? root.realBar.background : Commons.Color.background
    readonly property color urgent: root.realBar ? root.realBar.urgent : Commons.Color.urgent
    readonly property string fontFamily: root.realBar ? root.realBar.fontFamily : Style.font.family
    readonly property string position: root.realBar ? root.realBar.position : "top"
    readonly property bool vertical: root.realBar ? root.realBar.vertical === true : false
    readonly property int barSize: root.realBar ? root.realBar.barSize : Style.bar.sizeHorizontal
    readonly property bool transparent: root.realBar ? root.realBar.transparent === true : false
    readonly property bool foregroundAnimationEnabled: root.realBar ? root.realBar.foregroundAnimationEnabled !== false : true
    readonly property bool centerSectionRevealHeld: root.realBar ? root.realBar.centerSectionRevealHeld === true : false
    readonly property bool centerHoverRevealSuppressed: root.realBar ? root.realBar.centerHoverRevealSuppressed === true : false
    readonly property var activePopout: root.realBar ? root.realBar.activePopout : null
    // The real bar's targets, so a click on the bar while a hosted popup is
    // open reaches the folder icon instead of the hidden widget.
    readonly property var clickTargets: root.realBar ? root.realBar.clickTargets : []
    readonly property var layoutConfig: root.realBar ? root.realBar.layoutConfig : ({})

    function showTooltip(target, text) { }
    function hideTooltip(target) { }
    function registerClickTarget(target) {
      if (!target || root.targets.indexOf(target) !== -1) return
      var next = root.targets.slice()
      next.push(target)
      root.targets = next
    }
    function unregisterClickTarget(target) {
      root.targets = root.targets.filter(function(item) { return item !== target })
    }
    function requestPopout(owner) { if (root.realBar) root.realBar.requestPopout(owner) }
    function releasePopout(owner) { if (root.realBar) root.realBar.releasePopout(owner) }
    function switchPanelFrom(owner, direction) { return false }
    function targetBelongsToWindow(target, window) {
      return root.realBar ? root.realBar.targetBelongsToWindow(target, window) : false
    }
    function moduleWidgets(id) { return root.widget ? [root.widget] : [] }
    function run(command) { if (root.realBar) root.realBar.run(command) }
    function setCenterHoverRevealSuppressed(value) {
      if (root.realBar && typeof root.realBar.setCenterHoverRevealSuppressed === "function") root.realBar.setCenterHoverRevealSuppressed(value)
    }
  }

  Loader {
    id: loader
    anchors.fill: parent
    asynchronous: false
    active: !root.builtin && String(root.source) !== ""
    source: root.builtin ? "" : root.source
    onLoaded: {
      injectProps()
      // Twice, as the bar does: root bindings can read `bar` before assignment.
      Qt.callLater(injectProps)
      treeScan.restart()
    }
    onStatusChanged: if (status === Loader.Error) console.warn("Bar Folder: failed to load " + root.widgetId + " from " + root.source)

    function injectProps() {
      var target = loader.item
      if (!target) return
      if ("bar" in target) target.bar = hostBar
      if ("moduleName" in target && !target.moduleName) target.moduleName = root.widgetId
      if ("settings" in target) target.settings = root.widgetSettings
    }
  }

  onWidgetSettingsChanged: loader.injectProps()
}
