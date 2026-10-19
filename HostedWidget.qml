import QtQuick 6.11
import Quickshell
import Quickshell.Io
import qs.Commons

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
  property var targets: []

  // The first registered button is the one the widget draws in the bar.
  readonly property var primaryTarget: {
    for (var i = 0; i < targets.length; i++) {
      var target = targets[i]
      if (target && typeof target.triggerPress === "function") return target
    }
    return null
  }

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
  readonly property bool opened: widget ? widget.opened === true : false
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
    if (primaryTarget) {
      primaryTarget.triggerPress(button)
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

    readonly property color foreground: root.realBar ? root.realBar.foreground : Color.foreground
    readonly property color barForeground: root.realBar ? root.realBar.barForeground : Color.foreground
    readonly property color background: root.realBar ? root.realBar.background : Color.background
    readonly property color urgent: root.realBar ? root.realBar.urgent : Color.urgent
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
