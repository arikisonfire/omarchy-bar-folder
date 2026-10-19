import QtQuick 6.11
import Quickshell

// Runs the services of plugins that live inside the folder.
//
// The shell only starts a third-party plugin's service while that plugin is
// in the bar layout (or in `plugins`), and it never hands one plugin another
// plugin's service. A plugin moved into the folder would therefore lose its
// backend. This service, created once by the shell however many bars there
// are, starts those services the same way the shell does and hands each one
// only to the widget of the same plugin. resolve-widgets.sh sets
// `serviceUrl` only when the shell does not run that service itself.
Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  // pluginId -> { url, instance, shell }. Reassigned on every change so the
  // hosted widgets' `serviceFor` bindings re-evaluate.
  property var services: ({})
  // pluginId -> { url, manifest } from the latest sync.
  property var wanted: ({})
  // The latest resolved widget list from the Bar Folder widgets.
  property var lastList: []
  property bool shuttingDown: false

  function serviceFor(pluginId) {
    var entry = root.services[String(pluginId || "")]
    return entry ? entry.instance : null
  }

  // Called by every Bar Folder instance with its resolved widget list. The
  // last list wins after a short pause, so bars that update one after another
  // do not start and stop the same service.
  function sync(list) {
    root.lastList = list || []
    syncDelay.restart()
  }

  // True when the plugin sits in the bar layout itself, e.g. after
  // `omarchy bar put`: then the shell runs its service and we must not.
  function onBar(pluginId) {
    var layout = root.shell && root.shell.barConfig ? root.shell.barConfig.layout : null
    if (!layout || typeof layout !== "object") return false
    for (var section in layout) {
      var entries = layout[section]
      if (!entries || typeof entries === "string" || entries.length === undefined) continue
      for (var i = 0; i < entries.length; i++) {
        var entry = entries[i]
        var id = entry && typeof entry === "object" ? entry.id : entry
        if (String(id || "") === pluginId) return true
      }
    }
    return false
  }

  function applySync() {
    if (root.shuttingDown) return
    var list = root.lastList || []
    var wanted = ({})
    for (var i = 0; i < list.length; i++) {
      var item = list[i]
      if (!item || !item.serviceUrl || !item.pluginId) continue
      var url = String(item.serviceUrl)
      if (!/^file:\/\//.test(url) || root.onBar(String(item.pluginId))) continue
      wanted[String(item.pluginId)] = { url: url, manifest: item.manifest || null }
    }
    root.wanted = wanted

    for (var existing in root.services) {
      var entry = root.services[existing]
      if (!wanted[existing] || wanted[existing].url !== entry.url) root.stop(existing)
    }
    for (var id in wanted)
      if (!root.services[id]) root.start(id, wanted[id].url, wanted[id].manifest)
  }

  function start(id, url, manifest) {
    var component = Qt.createComponent(url, Component.PreferSynchronous)
    function finalize() {
      // Skip when the plugin left the folder while its component was loading.
      if (root.shuttingDown || root.services[id]) return
      if (!root.wanted[id] || root.wanted[id].url !== url) return
      if (component.status !== Component.Ready) {
        console.warn("Bar Folder: service failed to load for " + id + ": " + component.errorString())
        return
      }
      var facade = facadeComponent.createObject(null, { pluginId: id })
      // No visual parent, as the shell does for third-party services: object
      // traversal from the hosted service must not reach this folder.
      var instance = component.createObject(null)
      if (!instance) {
        console.warn("Bar Folder: could not create the service of " + id)
        if (facade) facade.destroy()
        return
      }
      if ("omarchyPath" in instance) instance.omarchyPath = root.omarchyPath
      if ("manifest" in instance) instance.manifest = manifest ? JSON.parse(JSON.stringify(manifest)) : null
      if ("shell" in instance) instance.shell = facade
      if (facade) facade.instance = instance
      var next = ({})
      for (var key in root.services) next[key] = root.services[key]
      next[id] = { url: url, instance: instance, shell: facade }
      root.services = next
    }
    if (component.status === Component.Loading) component.statusChanged.connect(finalize)
    else finalize()
  }

  function stop(id) {
    var entry = root.services[id]
    var next = ({})
    for (var key in root.services) if (key !== id) next[key] = root.services[key]
    root.services = next
    if (!entry) return
    if (entry.instance) entry.instance.destroy()
    if (entry.shell) entry.shell.destroy()
  }

  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onBarConfigChanged() { syncDelay.restart() }
  }

  Timer {
    id: syncDelay
    interval: 250
    onTriggered: root.applySync()
  }

  // Hosted services have no parent, so they do not die with this item on
  // their own.
  Component.onDestruction: {
    root.shuttingDown = true
    for (var id in root.services) {
      var entry = root.services[id]
      if (entry && entry.instance) entry.instance.destroy()
      if (entry && entry.shell) entry.shell.destroy()
    }
  }

  // What a hosted service sees as `shell`: scoped to its own plugin id, like
  // the shell's own per-plugin API. Opening its own panel goes through the
  // folder, anything else through the shell's IPC, as a hotkey would.
  Component {
    id: facadeComponent

    QtObject {
      property string pluginId: ""
      property var instance: null
      readonly property var appLibrary: null
      readonly property var bar: null
      readonly property var barConfig: root.shell ? root.shell.barConfig : ({})
      readonly property var idleConfig: ({})

      function owns(id) { return String(id || "") === pluginId }
      function folderCall(method) {
        Quickshell.execDetached(["omarchy-shell", "-q", "io.github.arikisonfire.bar-folder", method, pluginId])
        return true
      }
      function shellCall(method, id, payloadJson) {
        var command = ["omarchy-shell", "-q", "shell", method, String(id || "")]
        if (payloadJson !== undefined) command.push(String(payloadJson || "{}"))
        Quickshell.execDetached(command)
        return true
      }

      function serviceFor(id) { return owns(id) ? instance : null }
      function firstPartyServiceFor(id) { return null }
      function pluginShellForBarEntry(ownerId, moduleName) { return null }
      function summon(id, payloadJson) { return owns(id) ? folderCall("openWidget") : shellCall("summon", id, payloadJson) }
      function hide(id) { return owns(id) ? folderCall("closeWidget") : shellCall("hide", id) }
      function toggle(id, payloadJson) { return owns(id) ? folderCall("toggleWidget") : shellCall("toggle", id, payloadJson) }
      function isPluginOpen(id) { return false }
      function updateEntryInline(id, settings) { return false }
      function mutateShellConfig(mutator) { return false }
    }
  }
}
