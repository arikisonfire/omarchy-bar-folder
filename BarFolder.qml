import QtQuick 6.11
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar Folder: a simple folder for bar icons. One icon on the bar; its panel
// shows a tile per widget inside. Clicking a tile opens that widget's own
// popup (it takes over from this panel), right/middle click and scroll are
// forwarded to the widget.
//
// Drag and drop: drop a bar icon onto the folder icon to move it in; drag a
// tile out of the panel (onto the bar, or anywhere outside the panel) to put
// it back on the bar; drop a tile on another tile to reorder.
//
// shell.json entry:
//   { "id": "io.github.arikisonfire.bar-folder",
//     "widgets": ["omarchy.bluetooth", ...],      // order = tile order
//     "labels": { "<id>": "Tile title" },         // optional
//     "icons": { "<id>": "<glyph>" },             // optional, used when the widget draws no glyph
//     "columns": 2,                                // optional
//     "widgetSettings": { "<id>": { ... } } }     // inline settings for each widget inside
//
// Until "widgets" exists the panel offers to move the default set in; the
// bar layout is only ever changed after that confirmation or a drag.
Panel {
  id: root
  moduleName: "io.github.arikisonfire.bar-folder"
  ipcTarget: "io.github.arikisonfire.bar-folder"
  manageIpc: false

  readonly property var defaultWidgets: [
    "omarchy.bluetooth", "omarchy.network", "omarchy.audio", "omarchy.monitor", "builtin.notifications"
  ]
  readonly property var defaultLabels: ({
    "omarchy.bluetooth": "Bluetooth",
    "omarchy.network": "Wi-Fi",
    "omarchy.audio": "Sound",
    "omarchy.monitor": "Display",
    "builtin.notifications": "Notifications"
  })

  readonly property bool configured: root.settings !== null && root.settings !== undefined
    && root.settings.widgets !== undefined && root.settings.widgets !== null
  readonly property var widgetIds: {
    // Settings arrays arrive as QML lists, which Array.isArray rejects.
    var value = root.setting("widgets", [])
    var ids = []
    if (value && typeof value !== "string" && value.length !== undefined)
      for (var i = 0; i < value.length; i++) ids.push(String(value[i]))
    return ids
  }
  readonly property var labels: root.setting("labels", ({}))
  readonly property var icons: root.setting("icons", ({}))
  readonly property var widgetSettings: root.setting("widgetSettings", ({}))
  readonly property int columns: Math.max(1, Math.min(4, Math.round(Number(root.setting("columns", 2)) || 2)))

  property var resolved: []
  property string resolvedKey: ""
  // Our own service (FolderService.qml), which runs the services of the
  // plugins inside the folder. The shell creates it once for all bars.
  readonly property var folderService: root.bar && root.bar.shell
    && typeof root.bar.shell.serviceFor === "function" ? root.bar.shell.serviceFor(root.moduleName) : null
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property int tileWidth: Style.space(158)
  readonly property int tileHeight: Style.space(58)
  readonly property int tileGap: Style.space(8)

  function hostAt(index) {
    return hosts.itemAt(index)
  }

  function hostFor(id) {
    for (var i = 0; i < hosts.count; i++) {
      var host = hosts.itemAt(i)
      if (host && host.widgetId === id) return host
    }
    for (var j = 0; j < hosts.count; j++) {
      var clone = hosts.itemAt(j)
      if (clone && clone.pluginId === id) return clone
    }
    return null
  }

  function syncServices() {
    if (root.folderService && typeof root.folderService.sync === "function")
      root.folderService.sync(root.resolved)
  }

  // The first line of a widget's tooltip, without a leading "<title> · ".
  // Tooltips are often several lines, which would overflow the tile.
  function statusLine(text, title) {
    var lines = String(text || "").split("\n")
    var line = ""
    for (var i = 0; i < lines.length && !line; i++) line = lines[i].trim()
    var prefix = String(title || "") + " · "
    if (title && line.indexOf(prefix) === 0 && line.length > prefix.length) line = line.slice(prefix.length)
    return line
  }

  function resolveWidgets() {
    var key = JSON.stringify(root.widgetIds)
    if (key === root.resolvedKey) return
    root.resolvedKey = key
    if (root.widgetIds.length === 0) {
      root.resolved = []
      return
    }
    var script = String(Qt.resolvedUrl("resolve-widgets.sh")).replace(/^file:\/\//, "")
    resolver.command = [script].concat(root.widgetIds)
    resolver.running = true
  }

  function persistWidgetSettings(id, values) {
    var entry = {}
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    var nested = {}
    var current = root.widgetSettings || {}
    for (var other in current) nested[other] = current[other]
    nested[id] = values
    entry.widgetSettings = nested
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function titleFor(item) {
    if (!item) return ""
    var id = String(item.id)
    if (root.labels && root.labels[id]) return String(root.labels[id])
    if (root.defaultLabels[id]) return root.defaultLabels[id]
    return String(item.name || id)
  }

  function defaultTitles() {
    return root.defaultWidgets.map(function(id) { return root.defaultLabels[id] || id })
  }

  function activate(index, button) {
    var host = hostAt(index)
    if (!host) return
    host.press(button)
  }

  function moveCursor(dx, dy) {
    var count = root.resolved.length
    if (count === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      return
    }
    var next = root.selectedIndex + dx + dy * root.columns
    root.selectedIndex = Math.max(0, Math.min(count - 1, next))
  }

  onWidgetIdsChanged: resolveWidgets()
  onFolderServiceChanged: syncServices()
  Component.onCompleted: {
    resolveWidgets()
    slotScan.restart()
  }

  // ---- layout changes -----------------------------------------------------

  function runLayout(args) {
    // Detached with a short delay: the bar applies its own drop (and may
    // rebuild this widget) first, and the edit must survive that rebuild.
    var script = String(Qt.resolvedUrl("layout.sh")).replace(/^file:\/\//, "")
    Quickshell.execDetached(["sh", "-c", "sleep 0.35; exec \"$0\" \"$@\"", script].concat(args))
  }

  // ---- bar icon -> folder ---------------------------------------------------
  // The bar has no drag API for widgets, but every module slot exposes
  // `dragSource`, `moduleName` and `region`, and its pointer MouseArea keeps
  // tracking the cursor for the whole drag. Watching the slots is enough to
  // tell when a widget is released on top of this icon.

  property var barSlots: []
  property var barDragSlot: null
  // Kept apart from barDragSlot: the bar rebuilds its slots when it applies
  // its own drop, which nulls the slot reference before we see the release.
  property bool barDragging: false
  property string barDragId: ""
  property bool barDropHover: false

  function isModuleSlot(item) {
    return !!item && ("dragSource" in item) && ("moduleName" in item) && ("region" in item)
  }

  function ownSlot() {
    var node = root.parent
    while (node) {
      if (root.isModuleSlot(node)) return node
      node = node.parent
    }
    return null
  }

  function collectBarSlots() {
    var own = root.ownSlot()
    if (!own) return
    var top = own
    while (top.parent) top = top.parent
    var found = []
    var queue = [top]
    for (var guard = 0; queue.length > 0 && guard < 5000; guard++) {
      var node = queue.shift()
      if (!node) continue
      if (root.isModuleSlot(node)) {
        found.push(node)
        continue
      }
      var kids = node.children
      if (kids) for (var i = 0; i < kids.length; i++) queue.push(kids[i])
    }
    root.barSlots = found
    for (var j = 0; j < found.length; j++) root.watchSlot(found[j])
  }

  // The bar clears `dragSource` right before it applies its own drop, which
  // rebuilds the slots, so the release has to be handled synchronously here;
  // polling alone would only ever see the slots after they are gone.
  property var watchedSlots: []

  function watchSlot(slot) {
    if (!slot || root.watchedSlots.indexOf(slot) !== -1) return
    root.watchedSlots = root.watchedSlots.filter(function(item) { return !!item && !!item.parent }).concat([slot])
    slot.dragSourceChanged.connect(function() {
      try {
        if (slot.dragSource === true) {
          if (slot !== root.ownSlot()) root.startBarDrag(slot)
        } else if (root.barDragging && root.barDragSlot === slot) {
          root.barDropHover = root.barDragId !== "" && root.pointerOverIcon(slot)
          root.finishBarDrag()
        }
      } catch (e) {
      }
    })
  }

  function startBarDrag(slot) {
    root.barDragging = true
    root.barDragSlot = slot
    root.barDragId = slot.customType ? "" : String(slot.moduleName || "")
  }

  function finishBarDrag() {
    var id = root.barDragId
    var dropped = root.barDropHover
    root.barDragging = false
    root.barDragSlot = null
    root.barDragId = ""
    root.barDropHover = false
    if (dropped && id && id !== root.moduleName && root.widgetIds.indexOf(id) === -1)
      root.runLayout(["absorb", id])
  }

  function slotPointer(slot) {
    var kids = slot ? slot.children : null
    if (!kids) return null
    for (var i = 0; i < kids.length; i++)
      if (kids[i] && ("dragging" in kids[i]) && ("pressedX" in kids[i])) return kids[i]
    return null
  }

  function pointerOverIcon(slot) {
    var pointer = root.slotPointer(slot)
    if (!pointer) return false
    var p = pointer.mapToItem(button, pointer.mouseX, pointer.mouseY)
    return p.x >= 0 && p.x <= button.width && p.y >= -button.height / 2 && p.y <= button.height * 1.5
  }

  property int idleTicks: 0

  function pollBarDrag() {
    var own = root.ownSlot()
    var active = null
    var stale = false
    for (var i = 0; i < root.barSlots.length; i++) {
      var slot = root.barSlots[i]
      try {
        if (!slot || !slot.parent) stale = true
        else if (slot !== own && slot.dragSource === true) active = slot
      } catch (e) {
        stale = true
      }
    }

    if (active) {
      if (!root.barDragging || root.barDragSlot !== active) root.startBarDrag(active)
      root.barDropHover = root.barDragId !== "" && root.pointerOverIcon(active)
      return
    }

    if (!root.barDragging) {
      // The bar recreates its slots whenever the layout changes, and the
      // layout signal does not reach third-party widgets reliably, so refresh
      // the list when an entry died and every couple of seconds while idle.
      root.idleTicks++
      if (stale || root.idleTicks >= 12) {
        root.idleTicks = 0
        root.collectBarSlots()
      }
      return
    }
    // Fallback when the release signal was missed.
    root.finishBarDrag()
  }

  Timer {
    id: dragWatch
    interval: root.barDragging ? 30 : 150
    running: true
    repeat: true
    onTriggered: root.pollBarDrag()
  }

  // Slots are recreated whenever the layout changes.
  Timer {
    id: slotScan
    interval: 800
    onTriggered: root.collectBarSlots()
  }

  Connections {
    target: root.bar
    ignoreUnknownSignals: true
    function onLayoutConfigChanged() { slotScan.restart() }
  }

  // ---- tile -> bar -----------------------------------------------------------

  property int tileDragIndex: -1
  // Ids already dragged out; hidden until the layout change lands.
  property var pendingOut: []
  onResolvedChanged: {
    pendingOut = []
    syncServices()
  }
  property point tileDragPoint: Qt.point(0, 0)
  // null | { kind: "tile", index } | { kind: "bar", anchor, after, x, y, length } | { kind: "outside" }
  property var tileDropTarget: null

  function barGeometry() {
    var window = button.QsWindow.window
    var position = root.bar ? root.bar.position : "top"
    var vertical = position === "left" || position === "right"
    var screenW = panel.width
    var screenH = panel.height
    var barW = window ? window.width : screenW
    var barH = window ? window.height : 0
    // Offset of the bar window inside the full-screen panel window.
    var ox = position === "right" ? screenW - barW : 0
    var oy = position === "bottom" ? screenH - barH : 0
    return { window: window, position: position, vertical: vertical, x: ox, y: oy, width: barW, height: barH }
  }

  function barDropAt(scene) {
    var geo = root.barGeometry()
    if (!geo.window) return null
    var inBar = scene.x >= geo.x && scene.x <= geo.x + geo.width
      && scene.y >= geo.y && scene.y <= geo.y + geo.height
    if (!inBar) return null

    var axis = geo.vertical ? scene.y - geo.y : scene.x - geo.x
    var best = null
    var bestDistance = Infinity
    for (var i = 0; i < root.barSlots.length; i++) {
      var slot = root.barSlots[i]
      try {
        if (!slot || !slot.moduleName || !slot.visible || slot.width <= 0 || slot.height <= 0) continue
        if (root.bar && typeof root.bar.targetBelongsToWindow === "function"
            && !root.bar.targetBelongsToWindow(slot, geo.window)) continue
        var pos = slot.mapToItem(null, 0, 0)
        var start = geo.vertical ? pos.y : pos.x
        var size = geo.vertical ? slot.height : slot.width
        var before = Math.abs(axis - start)
        var after = Math.abs(axis - (start + size))
        var distance = Math.min(before, after)
        if (distance < bestDistance) {
          bestDistance = distance
          best = {
            kind: "bar",
            anchor: String(slot.moduleName),
            after: after < before,
            along: (after < before ? start + size : start),
            cross: geo.vertical ? pos.x : pos.y,
            length: geo.vertical ? slot.width : slot.height
          }
        }
      } catch (e) {
      }
    }
    if (!best) return { kind: "outside" }
    best.x = geo.vertical ? geo.x + best.cross : geo.x + best.along
    best.y = geo.vertical ? geo.y + best.along : geo.y + best.cross
    best.vertical = geo.vertical
    return best
  }

  function beginTileDrag(index) {
    root.tileDragIndex = index
    root.tileDropTarget = null
    root.collectBarSlots()
  }

  function updateTileDrag(scene) {
    root.tileDragPoint = scene
    var bar = root.barDropAt(scene)
    if (bar) {
      root.tileDropTarget = bar
      return
    }
    var inGrid = grid.mapFromItem(null, scene.x, scene.y)
    var child = grid.childAt(inGrid.x, inGrid.y)
    if (child && ("index" in child) && child.index !== undefined) {
      root.tileDropTarget = { kind: "tile", index: child.index }
      return
    }
    var inCard = keyCatcher.mapFromItem(null, scene.x, scene.y)
    var margin = panel.padding + Style.space(4)
    var insideCard = inCard.x >= -margin && inCard.x <= keyCatcher.width + margin
      && inCard.y >= -margin && inCard.y <= keyCatcher.height + margin
    root.tileDropTarget = insideCard ? null : { kind: "outside" }
  }

  function finishTileDrag() {
    var index = root.tileDragIndex
    var target = root.tileDropTarget
    root.tileDragIndex = -1
    root.tileDropTarget = null
    if (index < 0 || index >= root.resolved.length || !target) return
    var id = String(root.resolved[index].id)

    if (target.kind === "tile") {
      if (target.index !== index) root.runLayout(["reorder", id, String(target.index)])
      return
    }
    root.pendingOut = root.pendingOut.concat([id])
    if (target.kind === "bar") {
      root.runLayout(["release", id, target.anchor, target.after ? "after" : "before"])
    } else {
      root.runLayout(["release", id])
    }
    if (root.resolved.length <= 1) root.close()
  }

  function cancelTileDrag() {
    root.tileDragIndex = -1
    root.tileDropTarget = null
  }

  onOpenedChanged: {
    if (!opened) return
    for (var i = 0; i < hosts.count; i++) {
      var host = hosts.itemAt(i)
      if (host) host.refresh()
    }
    root.cursorActive = false
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, root.resolved.length - 1))
  }

  Process {
    id: resolver
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var list = JSON.parse(String(text || "[]"))
          root.resolved = Array.isArray(list) ? list : []
        } catch (e) {
          console.warn("Bar Folder: could not resolve widgets:", e)
          root.resolved = []
        }
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    // Toggle a hosted widget's own panel, e.g. from a hotkey.
    function toggleWidget(id: string): string {
      var host = root.hostFor(id)
      if (!host) return "unknown"
      host.toggle()
      return id
    }
    function openWidget(id: string): string {
      var host = root.hostFor(id)
      if (!host) return "unknown"
      host.open()
      return id
    }
    function closeWidget(id: string): string {
      var host = root.hostFor(id)
      if (!host) return "unknown"
      host.close()
      return id
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Drop highlight while a bar widget is being dragged.
  Rectangle {
    anchors.centerIn: button
    width: button.width
    height: Math.min(button.height, Style.bar.iconSlot)
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    visible: root.barDragging && root.barDragId !== ""
    color: Util.alpha(Color.accent, root.barDropHover ? 0.35 : 0.12)
    border.width: root.barDropHover ? Math.max(1, Style.space(1)) : 0
    border.color: Color.accent

    Behavior on color { ColorAnimation { duration: 90 } }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    z: 1
    bar: root.bar
    text: root.opened ? String(root.setting("iconOpen", "\udb83\uddcf")) : String(root.setting("icon", "\udb80\ude56"))
    tooltipText: "Bar Folder"
    onPressed: function(b) { root.toggle() }
  }

  // Widgets inside the folder live here: zero width and clipped, centred on
  // the icon so their popups open where the folder's own panel does.
  Item {
    id: hostLayer
    anchors.centerIn: button
    width: 0
    height: button.height
    clip: true

    Repeater {
      id: hosts
      model: root.resolved

      delegate: HostedWidget {
        required property var modelData
        anchors.fill: parent
        widgetId: String(modelData.id)
        pluginId: String(modelData.pluginId || modelData.id)
        folderService: root.folderService
        source: String(modelData.url || "")
        builtin: modelData.builtin === true
        realBar: root.bar
        widgetSettings: root.widgetSettings && root.widgetSettings[modelData.id]
          ? root.widgetSettings[modelData.id] : ({})
        onSettingsPersisted: function(id, values) { root.persistWidgetSettings(id, values) }
        onCloseFolderRequested: root.close()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(220), grid.implicitWidth, setupButtons.implicitWidth)
      + panel.padding * 2 + Border.left(panel.borderSpec) + Border.right(panel.borderSpec))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: {
        if (!root.configured) root.runLayout(["setup"].concat(root.defaultWidgets))
        else if (root.cursorActive) root.activate(root.selectedIndex, Qt.LeftButton)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(10)

        Text {
          text: "Bar Folder"
          color: Color.popups.text
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        // First run: nothing is moved until the user says so.
        Column {
          visible: !root.configured
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Keep your bar tidy. Move these icons into the folder? You can drag icons in and out at any time."
            color: Color.popups.text
            opacity: 0.8
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.defaultTitles().join("  ·  ")
            textFormat: Text.PlainText
            color: Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Row {
            id: setupButtons
            spacing: Style.space(8)

            Button {
              text: "Move into folder"
              bordered: true
              active: true
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.runLayout(["setup"].concat(root.defaultWidgets))
            }

            Button {
              text: "Start empty"
              bordered: true
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.runLayout(["setup"])
            }
          }
        }

        Text {
          visible: root.configured && root.resolved.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          text: "The folder is empty. Drag an icon from the bar onto the folder icon to add it."
          color: Color.popups.text
          opacity: 0.7
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        Grid {
          id: grid
          visible: root.configured
          columns: root.columns
          spacing: root.tileGap

          Repeater {
            model: root.resolved

            delegate: Rectangle {
              id: tile

              required property var modelData
              required property int index

              readonly property var host: { hosts.count; return hosts.itemAt(tile.index) }
              readonly property bool failed: !host || host.failed
              readonly property bool highlighted: mouse.containsMouse
                || (root.cursorActive && root.selectedIndex === tile.index)
              readonly property bool lit: !!host && (host.active || host.opened)
              readonly property string title: root.titleFor(modelData)
              readonly property string glyph: {
                if (tile.failed) return "󰀦"
                if (host.glyph) return host.glyph
                return root.icons && root.icons[modelData.id] ? String(root.icons[modelData.id]) : "󰐱"
              }
              readonly property string status: tile.failed ? "Failed to load" : root.statusLine(host.status, tile.title)

              readonly property bool dragged: root.tileDragIndex === tile.index
              readonly property bool dropTarget: !!root.tileDropTarget && root.tileDropTarget.kind === "tile"
                && root.tileDropTarget.index === tile.index && root.tileDragIndex !== tile.index

              visible: root.pendingOut.indexOf(String(modelData.id)) === -1
              width: root.tileWidth
              height: root.tileHeight
              clip: true
              radius: Style.cornerRadius
              opacity: tile.dragged ? 0.35 : 1
              color: Util.alpha(Color.popups.text, tile.highlighted && root.tileDragIndex < 0 ? 0.13 : 0.06)
              border.width: tile.dropTarget || (root.cursorActive && root.selectedIndex === tile.index) ? Math.max(1, Style.space(1)) : 0
              border.color: Color.accent

              Behavior on color { ColorAnimation { duration: 120 } }

              Rectangle {
                id: badge
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(34)
                height: width
                radius: Style.cornerRadius > 0 ? width / 2 : 0
                color: tile.lit ? Color.accent : Util.alpha(Color.popups.text, 0.12)

                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                  anchors.centerIn: parent
                  text: tile.glyph
                  textFormat: Text.PlainText
                  color: tile.failed ? Color.urgent : (tile.lit ? Color.popups.background : Color.popups.text)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.iconLarge
                }
              }

              Column {
                anchors.left: badge.right
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  text: tile.title
                  textFormat: Text.PlainText
                  wrapMode: Text.NoWrap
                  maximumLineCount: 1
                  elide: Text.ElideRight
                  color: Color.popups.text
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  text: tile.status
                  textFormat: Text.PlainText
                  wrapMode: Text.NoWrap
                  maximumLineCount: 1
                  elide: Text.ElideRight
                  color: Color.popups.text
                  opacity: 0.65
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                preventStealing: true
                cursorShape: dragging ? Qt.ClosedHandCursor : (tile.failed ? Qt.ArrowCursor : Qt.PointingHandCursor)

                property real pressX: 0
                property real pressY: 0
                property bool dragging: false
                property bool justDragged: false

                onEntered: root.selectedIndex = tile.index
                onPressed: function(event) {
                  pressX = event.x
                  pressY = event.y
                  dragging = false
                  justDragged = false
                }
                onPositionChanged: function(event) {
                  if (!(event.buttons & Qt.LeftButton)) return
                  if (!dragging && Math.abs(event.x - pressX) + Math.abs(event.y - pressY) >= Style.space(8)) {
                    dragging = true
                    root.beginTileDrag(tile.index)
                  }
                  if (dragging) root.updateTileDrag(mouse.mapToItem(null, event.x, event.y))
                }
                onReleased: function(event) {
                  if (!dragging) return
                  dragging = false
                  justDragged = true
                  root.finishTileDrag()
                }
                onCanceled: {
                  if (dragging) root.cancelTileDrag()
                  dragging = false
                }
                onClicked: function(event) {
                  if (justDragged) {
                    justDragged = false
                    return
                  }
                  root.activate(tile.index, event.button)
                }
                onWheel: function(event) { if (tile.host) tile.host.wheel(event.angleDelta.y) }
              }
            }
          }
        }

        // Hint under the tiles.
        Text {
          width: parent.width
          visible: root.configured && root.resolved.length > 0
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
          text: root.tileDragIndex >= 0 ? "Drop on the bar to take it out" : "Drag tiles to reorder or out to the bar"
          color: Color.popups.text
          opacity: 0.45
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // Insertion marker drawn over the bar while a tile is dragged onto it.
      Rectangle {
        readonly property var target: root.tileDropTarget
        readonly property point at: target && target.kind === "bar"
          ? keyCatcher.mapFromItem(null, target.x, target.y) : Qt.point(0, 0)
        visible: root.tileDragIndex >= 0 && !!target && target.kind === "bar"
        z: 100
        color: Color.accent
        width: target && target.vertical ? target.length : Math.max(2, Style.space(2))
        height: target && target.vertical ? Math.max(2, Style.space(2)) : (target ? target.length : 0)
        x: target && target.vertical ? at.x : at.x - width / 2
        y: target && target.vertical ? at.y - height / 2 : at.y
        radius: 1
      }

      // Drag ghost.
      Rectangle {
        readonly property point at: keyCatcher.mapFromItem(null, root.tileDragPoint.x, root.tileDragPoint.y)
        readonly property var item: root.tileDragIndex >= 0 ? root.resolved[root.tileDragIndex] : null
        readonly property var host: root.tileDragIndex >= 0 ? hosts.itemAt(root.tileDragIndex) : null
        readonly property bool leaving: !!root.tileDropTarget && root.tileDropTarget.kind !== "tile"
        visible: !!item
        z: 101
        // Below and right of the pointer, so the bar insertion marker stays visible.
        x: at.x + Style.space(14)
        y: at.y + Style.space(18)
        width: ghostRow.implicitWidth + Style.space(16)
        height: Style.space(34)
        radius: Style.cornerRadius
        color: Color.popups.background
        border.width: Math.max(1, Style.space(1))
        border.color: Color.accent
        opacity: 0.95

        Row {
          id: ghostRow
          anchors.centerIn: parent
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var ghost = parent.parent
              if (ghost.host && ghost.host.glyph) return ghost.host.glyph
              var id = ghost.item ? ghost.item.id : ""
              return root.icons && root.icons[id] ? String(root.icons[id]) : "\udb81\udc31"
            }
            textFormat: Text.PlainText
            color: Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.icon
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var ghost = parent.parent
              var title = root.titleFor(ghost.item)
              if (!ghost.leaving) return title
              return ghost.item && ghost.item.builtin ? title + "  \u2192 remove" : title + "  \u2192 bar"
            }
            textFormat: Text.PlainText
            color: Color.popups.text
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }
      }
    }
  }
}
