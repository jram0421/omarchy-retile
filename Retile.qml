import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Retile: lays the current workspace's windows out as draggable tiles, then
// applies the arrangement with hyprctl (windows are floated and given exact
// positions and sizes). Nothing changes until Apply.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property var tiles: []          // {address, title, cls, x, y, w, h} in layout px
  property int selected: -1
  property string status: ""

  // Usable area of the active monitor, in layout (logical) pixels.
  property real areaX: 0
  property real areaY: 0
  property real areaW: 1920
  property real areaH: 1080
  property int workspaceId: -1
  readonly property real gap: 8
  readonly property int gridCols: 24
  readonly property int gridRows: 12
  readonly property real stepX: areaW / gridCols
  readonly property real stepY: areaH / gridRows

  property color background: Commons.Color.menu.background
  property color foreground: Commons.Color.menu.text
  property color border: Commons.Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Commons.Color.menu.scrim
  property color selectedBackground: Commons.Color.menu.selectedBackground
  property color selectedText: Commons.Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding

  // ---- lifecycle -------------------------------------------------------
  function open(payloadJson) {
    root.status = ""
    root.selected = -1
    root.opened = true
    monitorsProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "jmramsay.retile")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- reading Hyprland state -----------------------------------------
  Process {
    id: monitorsProc
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var mons = JSON.parse(text)
          var mon = null
          for (var i = 0; i < mons.length; i++) if (mons[i].focused) mon = mons[i]
          if (!mon && mons.length) mon = mons[0]
          if (!mon) return
          var sc = mon.scale > 0 ? mon.scale : 1
          var rv = mon.reserved || [0, 0, 0, 0]   // left, top, right, bottom
          root.workspaceId = mon.activeWorkspace.id
          root.areaX = mon.x + rv[0] + root.gap
          root.areaY = mon.y + rv[1] + root.gap
          root.areaW = mon.width / sc - rv[0] - rv[2] - root.gap * 2
          root.areaH = mon.height / sc - rv[1] - rv[3] - root.gap * 2
          clientsProc.running = true
        } catch (e) {
          root.status = "Could not read monitors"
        }
      }
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var list = JSON.parse(text)
          var out = []
          for (var i = 0; i < list.length; i++) {
            var c = list[i]
            if (!c.mapped || c.hidden || c.workspace.id !== root.workspaceId) continue
            out.push({
              address: c.address,
              title: String(c.title || ""),
              cls: String(c.class || ""),
              x: c.at[0], y: c.at[1], w: c.size[0], h: c.size[1]
            })
          }
          root.tiles = out
          root.selected = out.length ? 0 : -1
          // Existing windows may overlap; start from a clean grid if so.
          if (root.hasOverlap()) {
            root.presetGrid()
          }
          if (!out.length) root.status = "No windows on this workspace"
        } catch (e) {
          root.status = "Could not read windows"
        }
      }
    }
  }

  // ---- editing ---------------------------------------------------------
  function snapX(v) { return root.areaX + Math.round((v - root.areaX) / root.stepX) * root.stepX }
  function snapY(v) { return root.areaY + Math.round((v - root.areaY) / root.stepY) * root.stepY }

  function clampTile(t) {
    // Keep the tile inside the usable area with a sensible minimum size.
    t.w = Math.max(root.stepX * 2, Math.min(t.w, root.areaW))
    t.h = Math.max(root.stepY * 2, Math.min(t.h, root.areaH))
    t.x = Math.max(root.areaX, Math.min(t.x, root.areaX + root.areaW - t.w))
    t.y = Math.max(root.areaY, Math.min(t.y, root.areaY + root.areaH - t.h))
    return t
  }

  // True if rect t overlaps any tile other than index i (touching edges is fine).
  function overlapsOthers(i, t) { return root.overlapsIn(root.tiles, i, t) }

  function overlapsIn(list, i, t) {
    var eps = 0.5
    for (var j = 0; j < list.length; j++) {
      if (j === i) continue
      var o = list[j]
      if (t.x < o.x + o.w - eps && t.x + t.w > o.x + eps &&
          t.y < o.y + o.h - eps && t.y + t.h > o.y + eps)
        return true
    }
    return false
  }

  function hasOverlap() {
    for (var i = 0; i < root.tiles.length; i++)
      if (root.overlapsOthers(i, root.tiles[i])) return true
    return false
  }

  // Applies the change unless it would make tiles overlap. A move that is
  // blocked on one axis still slides along the other.
  function setTile(i, patch) {
    var cur = root.tiles[i]
    var attempts = [patch]
    if (patch.x !== undefined && patch.y !== undefined && patch.w === undefined) {
      attempts.push({ x: patch.x })
      attempts.push({ y: patch.y })
    }
    for (var a = 0; a < attempts.length; a++) {
      var t = root.clampTile(Object.assign({}, cur, attempts[a]))
      if (root.overlapsOthers(i, t)) continue
      var next = root.tiles.slice()
      next[i] = t
      root.tiles = next
      return
    }
  }

  // Nearest grid-aligned spot where tile j (from list) fits without overlap,
  // measured from (tx, ty). Returns null if the workspace is full.
  function freeSpot(list, j, tx, ty) {
    var o = list[j]
    var maxX = root.areaX + root.areaW - o.w
    var maxY = root.areaY + root.areaH - o.h
    // Candidate coordinates: the grid, the dragged tile's start, and every
    // other tile's edges (so tiles can sit flush against off-grid neighbours).
    var xs = [tx], ys = [ty]
    for (var gx = 0; gx <= root.gridCols; gx++) xs.push(root.areaX + gx * root.stepX)
    for (var gy = 0; gy <= root.gridRows; gy++) ys.push(root.areaY + gy * root.stepY)
    for (var k = 0; k < list.length; k++) {
      if (k === j) continue
      var n = list[k]
      xs.push(n.x + n.w, n.x - o.w, n.x)
      ys.push(n.y + n.h, n.y - o.h, n.y)
    }
    var best = null, bestD = Infinity
    for (var a = 0; a < xs.length; a++) {
      var x = xs[a]
      if (x < root.areaX - 0.5 || x > maxX + 0.5) continue
      for (var b = 0; b < ys.length; b++) {
        var y = ys[b]
        if (y < root.areaY - 0.5 || y > maxY + 0.5) continue
        var d = (x - tx) * (x - tx) + (y - ty) * (y - ty)
        if (d >= bestD) continue
        if (root.overlapsIn(list, j, { x: x, y: y, w: o.w, h: o.h })) continue
        bestD = d
        best = { x: x, y: y, w: o.w, h: o.h }
      }
    }
    return best
  }

  // While dragging, the tile moves freely (overlap is allowed temporarily).
  function dragTile(i, x, y) {
    var list = root.tiles.slice()
    list[i] = root.clampTile(Object.assign({}, list[i], { x: x, y: y }))
    root.tiles = list
  }

  // On drop: if the tile's centre is over another tile, snap onto it. Tiles
  // underneath are pushed to the nearest open space (preferring the dragged
  // tile's start position). If that is impossible, the tile goes back.
  function dropTile(i, fromX, fromY) {
    var list = root.tiles.slice()
    var t = list[i]
    var cx = t.x + t.w / 2, cy = t.y + t.h / 2
    for (var j = 0; j < list.length; j++) {
      if (j === i) continue
      var o = list[j]
      if (cx >= o.x && cx <= o.x + o.w && cy >= o.y && cy <= o.y + o.h) {
        t = root.clampTile(Object.assign({}, t, { x: o.x, y: o.y }))
        list[i] = t
        break
      }
    }
    var ok = true
    for (var k = 0; k < list.length && ok; k++) {
      if (k === i) continue
      var q = list[k]
      var hit = t.x < q.x + q.w - 0.5 && t.x + t.w > q.x + 0.5 &&
                t.y < q.y + q.h - 0.5 && t.y + t.h > q.y + 0.5
      if (!hit) continue
      var spot = root.freeSpot(list, k, fromX, fromY)
      if (!spot) { ok = false; break }
      list[k] = Object.assign({}, q, { x: spot.x, y: spot.y })
    }
    if (ok && !root.hasOverlapIn(list)) { root.tiles = list; return }
    // Revert only the dragged tile.
    var back = root.tiles.slice()
    back[i] = Object.assign({}, back[i], { x: fromX, y: fromY })
    root.tiles = back
  }

  function hasOverlapIn(list) {
    for (var i = 0; i < list.length; i++)
      if (root.overlapsIn(list, i, list[i])) return true
    return false
  }

  function presetColumns() {
    var n = root.tiles.length
    if (!n) return
    var next = []
    var w = root.areaW / n
    for (var i = 0; i < n; i++)
      next.push(Object.assign({}, root.tiles[i], { x: root.areaX + i * w, y: root.areaY, w: w, h: root.areaH }))
    root.tiles = next
  }

  function presetRows() {
    var n = root.tiles.length
    if (!n) return
    var next = []
    var h = root.areaH / n
    for (var i = 0; i < n; i++)
      next.push(Object.assign({}, root.tiles[i], { x: root.areaX, y: root.areaY + i * h, w: root.areaW, h: h }))
    root.tiles = next
  }

  function presetGrid() {
    var n = root.tiles.length
    if (!n) return
    var cols = Math.ceil(Math.sqrt(n))
    var rows = Math.ceil(n / cols)
    var w = root.areaW / cols
    var h = root.areaH / rows
    var next = []
    for (var i = 0; i < n; i++)
      next.push(Object.assign({}, root.tiles[i], {
        x: root.areaX + (i % cols) * w, y: root.areaY + Math.floor(i / cols) * h, w: w, h: h
      }))
    root.tiles = next
  }

  function cycle(delta) {
    if (!root.tiles.length) return
    root.selected = (root.selected + delta + root.tiles.length) % root.tiles.length
  }

  // ---- applying --------------------------------------------------------
  function applyLayout() {
    if (!root.tiles.length) return
    var half = root.gap / 2
    var parts = []
    for (var i = 0; i < root.tiles.length; i++) {
      var t = root.tiles[i]
      // Addresses come from hyprctl; accept only the expected 0x<hex> form.
      if (!/^0x[0-9a-f]+$/.test(t.address)) continue
      var win = "address:" + t.address
      var x = Math.round(t.x + half), y = Math.round(t.y + half)
      var w = Math.round(t.w - root.gap), h = Math.round(t.h - root.gap)
      parts.push("dispatch hl.dsp.window.float({ action = \"on\", window = \"" + win + "\" })")
      parts.push("dispatch hl.dsp.window.resize({ x = " + w + ", y = " + h + ", window = \"" + win + "\" })")
      parts.push("dispatch hl.dsp.window.move({ x = " + x + ", y = " + y + ", window = \"" + win + "\" })")
    }
    applyProc.command = ["hyprctl", "--batch", parts.join(" ; ")]
    applyProc.running = true
  }

  // Hands every window on the workspace back to Hyprland's tiling layout.
  function tileAll() {
    if (!root.tiles.length) return
    var parts = []
    for (var i = 0; i < root.tiles.length; i++) {
      var a = root.tiles[i].address
      if (!/^0x[0-9a-f]+$/.test(a)) continue
      parts.push("dispatch hl.dsp.window.float({ action = \"off\", window = \"address:" + a + "\" })")
    }
    applyProc.command = ["hyprctl", "--batch", parts.join(" ; ")]
    applyProc.running = true
  }

  Process {
    id: applyProc
    onExited: function(code) {
      if (code === 0) root.dismiss()
      else root.status = "Apply failed (exit " + code + ")"
    }
  }

  // ---- UI --------------------------------------------------------------
  OverlayWindow {
    id: panel
    shown: root.opened
    WlrLayershell.namespace: "omarchy-retile"

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(panel.width - Style.gapsOut * 2, Style.space(1100))
      height: Math.min(panel.height - Style.gapsOut * 2, Style.space(700))
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
          else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.applyLayout(); event.accepted = true }
          else if (event.key === Qt.Key_Tab) { root.cycle(1); event.accepted = true }
          else if (event.key === Qt.Key_Backtab) { root.cycle(-1); event.accepted = true }
          else if (event.key === Qt.Key_C) { root.presetColumns(); event.accepted = true }
          else if (event.key === Qt.Key_R) { root.presetRows(); event.accepted = true }
          else if (event.key === Qt.Key_G) { root.presetGrid(); event.accepted = true }
          else if (event.key === Qt.Key_T) { root.tileAll(); event.accepted = true }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        // Header: title and hint
        Text {
          width: parent.width
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
          elide: Text.ElideRight
          text: root.status !== "" ? root.status
              : "Retile  —  drag · corner resizes  ·  C cols  R rows  G grid  ·  T back to tiling  ·  Enter apply  ·  Esc cancel"
        }

        // Canvas: the usable monitor area, scaled to fit.
        Item {
          id: canvasBox
          width: parent.width
          height: parent.height - y

          readonly property real scaleF: Math.min(width / root.areaW, height / root.areaH)

          Rectangle {
            id: canvas
            width: root.areaW * canvasBox.scaleF
            height: root.areaH * canvasBox.scaleF
            anchors.centerIn: parent
            radius: root.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: root.border

            Repeater {
              model: root.tiles.length
              delegate: Rectangle {
                id: tile
                required property int index
                readonly property var t: root.tiles[index]
                readonly property bool isSel: root.selected === index
                z: isSel ? 1 : 0

                x: (t.x - root.areaX) * canvasBox.scaleF
                y: (t.y - root.areaY) * canvasBox.scaleF
                width: t.w * canvasBox.scaleF
                height: t.h * canvasBox.scaleF
                radius: root.cornerRadius
                color: isSel ? root.selectedBackground : "transparent"
                border.width: isSel ? 2 : 1
                border.color: root.border
                clip: true

                Text {
                  anchors.fill: parent
                  anchors.margins: Style.spacing.md
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  elide: Text.ElideRight
                  color: tile.isSel ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  text: tile.t.cls + "\n" + tile.t.title
                }

                // Move
                MouseArea {
                  anchors.fill: parent
                  property real startX: 0
                  property real startY: 0
                  property real tileX: 0
                  property real tileY: 0
                  onPressed: function(m) {
                    root.selected = tile.index
                    var p = mapToItem(canvas, m.x, m.y)
                    startX = p.x; startY = p.y
                    tileX = tile.t.x; tileY = tile.t.y
                  }
                  onPositionChanged: function(m) {
                    if (!pressed) return
                    var p = mapToItem(canvas, m.x, m.y)
                    root.dragTile(tile.index,
                      root.snapX(tileX + (p.x - startX) / canvasBox.scaleF),
                      root.snapY(tileY + (p.y - startY) / canvasBox.scaleF))
                  }
                  onReleased: root.dropTile(tile.index, tileX, tileY)
                  onCanceled: root.dropTile(tile.index, tileX, tileY)
                }

                // Resize (bottom-right corner)
                Rectangle {
                  width: Style.space(18); height: width
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  color: root.border
                  opacity: 0.8
                  MouseArea {
                    anchors.fill: parent
                    property real startX: 0
                    property real startY: 0
                    property real w0: 0
                    property real h0: 0
                    onPressed: function(m) {
                      root.selected = tile.index
                      var p = mapToItem(canvas, m.x, m.y)
                      startX = p.x; startY = p.y
                      w0 = tile.t.w; h0 = tile.t.h
                    }
                    onPositionChanged: function(m) {
                      if (!pressed) return
                      var p = mapToItem(canvas, m.x, m.y)
                      var nw = w0 + (p.x - startX) / canvasBox.scaleF
                      var nh = h0 + (p.y - startY) / canvasBox.scaleF
                      root.setTile(tile.index, {
                        w: Math.round(nw / root.stepX) * root.stepX,
                        h: Math.round(nh / root.stepY) * root.stepY
                      })
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
