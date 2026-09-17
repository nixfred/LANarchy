import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// OmarPlugs-5oy.1: Quattro KeyboardPanel + inventory setup (view stack).
// Glance JSON unchanged (machines / lan / proxies). Setup edits nodes[] via inventory_cli.
Panel {
  id: root
  moduleName: "donnie.homelab-mesh"
  ipcTarget: "donnie.homelab-mesh"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color ink: Color.popups.text
  readonly property color inkDim: Util.alpha(ink, 0.66)
  readonly property color card: Util.alpha(ink, 0.05)
  readonly property color rule: Util.alpha(ink, 0.14)
  readonly property color muted: inkDim
  readonly property color dim: Util.alpha(ink, 0.72)
  readonly property color borderIdle: Style.normalBorderColor
  readonly property color borderHover: Style.hoverBorderColor
  property string themePaletteRaw: ""
  readonly property color themeGreen: root.themeColor("green", "#a6e3a1")
  readonly property color themeYellow: root.themeColor("yellow", "#f9e2af")
  readonly property color themeRed: root.themeColor("red", "")
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Install dir = directory that holds this Panel (marketplace id path or local symlink).
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("manifest.json"))
    if (u.indexOf("file://") === 0)
      u = u.replace(/^file:\/\/(localhost)?/, "")
    var cut = u.lastIndexOf("/")
    return cut >= 0 ? u.substring(0, cut) : u
  }
  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 15)), 10)
    if (!isFinite(n)) n = 15
    return Math.max(5, Math.min(120, n))
  }

  // glance | setup | form
  property string view: "glance"
  // list is the dash; map is the letterbox
  property string glanceTab: "list"
  property var mapEdges: []
  property var mapLayout: []
  property string mapSelectedId: ""
  property real edgePhase: 0
  property bool mapAnimate: true
  property bool loading: false
  property bool expectedStop: false
  property string error: ""
  property string asOf: ""
  property var machines: []
  property var lan: []
  property var proxies: []
  property var groups: []
  property var quietLan: []
  property var quietProxies: []
  property var lanMeta: ({})
  property var unifi: ({})
  property var discover: []
  property var invSettings: ({})
  property string actionStatus: ""
  property bool findHostsBusy: false
  property string findHostsHint: ""

  // setup / form state
  property var nodes: []
  property bool inventoryLoading: false
  property bool inventoryReady: false
  property string inventoryError: ""
  property bool formIsNew: true
  property string formId: ""
  property string formType: "machine"   // machine | host | proxy
  property string formLabel: ""
  property string formDns: ""
  property string formIp: ""
  property string formCheck: "http"     // http | tcp
  property string formUrl: ""
  property string formPort: ""
  property bool formNotify: true
  property bool formConfirmDelete: false
  property bool formFieldFocused: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function themeColor(role, fallback) {
    var aliases = {
      "green": ["green", "color2", "bright_green"],
      "yellow": ["yellow", "color3", "bright_yellow"],
      "red": ["red", "color1", "bright_red"]
    }
    var keys = aliases[role] || [role]
    var lines = String(root.themePaletteRaw || "").split("\n")
    var found = ({})
    var i, m
    for (i = 0; i < lines.length; i++) {
      m = /^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/.exec(lines[i])
      if (m) found[m[1].toLowerCase()] = m[2]
    }
    for (i = 0; i < keys.length; i++) {
      if (found[keys[i]]) return found[keys[i]]
    }
    if (role === "red" && (!fallback || fallback === "")) return root.urgent
    return fallback
  }

  function statusGlyph(status) {
    var s = String(status || "unknown")
    if (s === "up" || s === "down") return "●"
    return "○"
  }

  function statusColor(status) {
    var s = String(status || "unknown")
    if (s === "up") return root.themeGreen
    if (s === "degraded") return root.themeYellow
    if (s === "down") return (root.themeRed && String(root.themeRed) !== "") ? root.themeRed : root.urgent
    return root.muted
  }

  function fmtRate(bps) {
    var v = Number(bps)
    if (!isFinite(v) || v < 0) return ""
    if (v < 1000) return Math.round(v) + "B"
    if (v < 1000000) return Math.round(v / 1000) + "k"
    return (v / 1000000).toFixed(1) + "M"
  }

  function machineMetric(row) {
    if (!row) return "—"
    var bits = []
    var link = row.link
    if (link && link.speed_mbit) {
      var mb = Number(link.speed_mbit)
      if (link.kind === "wifi") bits.push(Math.round(mb) + "M wifi")
      else if (mb >= 1000) bits.push((mb / 1000) + "G")
      else bits.push(Math.round(mb) + "M")
      if (link.grade === "degraded") bits.push("slow")
    }
    if (row.rates && row.rates.rx_bps != null) {
      var r = root.fmtRate(row.rates.rx_bps)
      if (r) bits.push("↓" + r)
    }
    if (row.talkers && row.talkers.total > 0)
      bits.push(row.talkers.total + " talk")
    if (row.uptime_s != null) {
      var up = root.uptimeText(row.uptime_s)
      if (up) bits.push(up)
    }
    bits.push(root.rttText(row))
    return bits.join("  ")
  }

  function uptimeText(secs) {
    var n = Number(secs)
    if (!isFinite(n) || n <= 0) return ""
    if (n < 3600) return Math.round(n / 60) + "m up"
    if (n < 86400) return Math.round(n / 3600) + "h up"
    return (Math.round(n / 86400 * 10) / 10) + "d up"
  }

  function displayStatus(row) {
    if (!row) return "unknown"
    if (String(row.status) === "up" && row.link && row.link.grade === "degraded")
      return "degraded"
    return String(row.status || "unknown")
  }

  function sshHostFor(row) {
    if (row && row.host) return String(row.host)
    var inv = row ? root.invNodeById(row.id) : null
    if (inv && inv.dns) return String(inv.dns)
    return ""
  }

  function openSsh(row) {
    var host = root.sshHostFor(row)
    if (!host) return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--app-id=org.omarchy.terminal", "-e", "ssh", host])
  }

  function wakeNode(row) {
    if (!row) return
    var target = String(row.mac || row.id || "")
    if (!target) return
    root.actionStatus = "Waking " + String(row.label || row.id)
    actionProc.command = ["python3", root.pluginDir + "/probe.py", "wol", target]
    actionProc.running = true
  }

  function speedtestNode(row) {
    if (!row || actionProc.running) return
    var id = String(row.id || "")
    if (!id) return
    root.actionStatus = "Speedtest " + String(row.label || id) + "..."
    actionProc.command = ["python3", root.pluginDir + "/probe.py", "speedtest", "--id", id]
    actionProc.running = true
  }

  function serviceMetric(row) {
    if (!row) return "—"
    var frac = String(row.up || 0) + "/" + String(row.total || 0)
    var ms = root.rttText(row)
    return ms === "—" ? frac : frac + "  " + ms
  }

  function serviceLights(row) {
    if (!row || !row.members) return []
    var out = []
    for (var i = 0; i < row.members.length; i++) out.push(String(row.members[i].status || "unknown"))
    return out
  }

  function hubGroup() {
    var i
    for (i = 0; i < root.groups.length; i++) {
      if (String(root.groups[i].key || "") === "caddy") return root.groups[i]
    }
    return root.groups.length ? root.groups[0] : null
  }

  function lanClusterRow() {
    var rows = root.lanBucketRows()
    var up = 0
    var down = 0
    var lights = []
    var i, s
    for (i = 0; i < rows.length; i++) {
      s = String(rows[i].status || "unknown")
      if (i < 8) lights.push(s)
      if (s === "up") up++
      else if (s === "down") down++
    }
    var status = "unknown"
    if (down && !up && down === rows.length)
      status = "down"
    else if (down || (up && up < rows.length))
      status = "degraded"
    else if (up)
      status = "up"
    return {
      id: "__lan__",
      label: "LAN",
      kind: "lan",
      status: status,
      up: up,
      total: rows.length,
      lights: lights,
      members: rows,
      metric: root.lanClusterMetric(up, rows.length)
    }
  }

  function lanClusterMetric(up, total) {
    var bits = [(up + "/" + total) + (total ? " in LAN" : "")]
    var demoted = root.mapHiddenCount()
    if (demoted) bits.push(demoted + " demoted")
    var meta = root.lanMeta || {}
    if (meta.dns_ms != null) bits.push("dns " + Math.round(Number(meta.dns_ms)) + "ms")
    if (meta.neighbors != null) bits.push(meta.neighbors + " neigh")
    if (root.discover.length) bits.push(root.discover.length + " new")
    var u = root.unifi || {}
    if (u.model) bits.push(u.model)
    var nCli = (u.clients instanceof Array) ? u.clients.length : 0
    if (nCli) bits.push(nCli + " unifi")
    return bits.join(" · ")
  }

  function unifiMetric() {
    var u = root.unifi || {}
    var bits = []
    if (u.model) bits.push(String(u.model))
    var nDev = (u.devices instanceof Array) ? u.devices.length : 0
    if (nDev) bits.push(nDev + (nDev === 1 ? " device" : " devices"))
    var nCli = (u.clients instanceof Array) ? u.clients.length : 0
    if (nCli) bits.push(nCli + (nCli === 1 ? " client" : " clients"))
    var nNew = (u.discover instanceof Array) ? u.discover.length : 0
    if (nNew) bits.push(nNew + " new")
    if (u.auth === "none" && u.ok) bits.push("no key")
    if (u.error && u.auth !== "none") bits.push(String(u.error))
    return bits.join(" · ") || "controller"
  }

  function unifiLights() {
    var u = root.unifi || {}
    var devs = u.devices instanceof Array ? u.devices : []
    if (!devs.length) return [u.ok ? "up" : "down"]
    var out = []
    var i
    for (i = 0; i < devs.length; i++) {
      var s = String(devs[i].state || devs[i].status || "")
      out.push(s === "up" || s === "1" ? "up" : "down")
    }
    return out
  }

  function unifiVisible() {
    var u = root.unifi || {}
    if (u.ok) return true
    if (u.devices instanceof Array && u.devices.length) return true
    if (u.url) return true
    return false
  }

  // L7 map hub = reverse proxy (Caddy). Physical router stays on the bar for WAN/rates only.
  function mapHubId() {
    var hubRow = root.hubGroup()
    if (hubRow) return String(hubRow.id || "")
    if (root.machines.length) return String(root.machines[0].id || "")
    return ""
  }

  function rebuildMapEdges() {
    var hub = root.mapHubId()
    var router = root.routerMachine()
    var routerId = router ? String(router.id || "") : ""
    var edges = []
    var i, mid, gid
    if (!hub) {
      root.mapEdges = []
      return
    }
    for (i = 0; i < root.machines.length; i++) {
      mid = String(root.machines[i].id || "")
      if (!mid || mid === hub || mid === routerId) continue
      if (!root.mapRowVisible(root.machines[i], "machine")) continue
      edges.push({ from: mid, to: hub, kind: "lan" })
    }
    // Router feeds the reverse proxy (L3 gateway ↔ L7 front door).
    if (routerId && routerId !== hub)
      edges.push({ from: routerId, to: hub, kind: "lan" })
    for (i = 0; i < root.groups.length; i++) {
      gid = String(root.groups[i].id || "")
      if (gid === hub) continue
      if (!root.mapRowVisible(root.groups[i], String(root.groups[i].zone || "") === "external" ? "external" : "service"))
        continue
      var kind = String(root.groups[i].zone || "") === "external" ? "wan" : "service"
      // WAN leaves via the router when we have one; otherwise hub → cloud.
      if (kind === "wan" && routerId)
        edges.push({ from: routerId, to: gid, kind: kind })
      else
        edges.push({ from: hub, to: gid, kind: kind })
    }
    if (root.lanBucketRows().length)
      edges.push({ from: hub, to: "__lan__", kind: "lan" })
    root.mapEdges = edges
  }

  function glanceRowById(id) {
    var sid = String(id || "")
    if (sid === "__lan__") return root.lanClusterRow()
    var bands = [root.machines, root.groups, root.lan, root.proxies, root.quietLan, root.quietProxies]
    var b, i, row
    for (b = 0; b < bands.length; b++) {
      for (i = 0; i < bands[b].length; i++) {
        row = bands[b][i]
        if (String(row.id || "") === sid) return row
      }
    }
    return null
  }

  function sparklineIdFor(row) {
    if (!row) return ""
    if (String(row.id || "") === "__lan__") return ""
    if (row.members && row.members.length) {
      var m = row.members[0]
      return String((m && m.id) || "")
    }
    return String(row.id || "")
  }

  readonly property int mapLanCap: 12
  readonly property int mapCardH: Style.space(94)
  property real mapSplitX: 0
  property real mapBarWidth: 0
  property bool mapHasExternal: false

  // Only flag unusually slow peers — normal LAN RTT (3–15ms) must not recolour cards.
  function rttHot(row) {
    if (!row || String(row.status) !== "up") return false
    var n = Number(row.rtt_ms)
    return isFinite(n) && n > 50
  }

  // Traffic flow: width from real endpoint rates only; slow shared pulse.
  function edgeFlowBps(rowA, rowB) {
    function rate(row) {
      if (!row || !row.rates) return 0
      var rx = Number(row.rates.rx_bps)
      var tx = Number(row.rates.tx_bps)
      return Math.max(isFinite(rx) ? rx : 0, isFinite(tx) ? tx : 0)
    }
    return Math.max(rate(rowA), rate(rowB))
  }

  function edgeFlowWidth(bps) {
    var v = Number(bps) || 0
    if (v < 800) return 1.8
    if (v < 80000) return 1.8 + (v / 80000) * 2.4
    return Math.min(5.2, 4.2 + Math.log(v / 80000) / Math.log(25))
  }

  // Dash march: busy links keep full pace; quiet/no-rate links crawl at 1/10.
  function edgeFlowSpeed(bps) {
    var v = Number(bps) || 0
    if (v < 800) return 0.1
    return 1.0
  }

  function edgeFlowPeriod(bps) {
    return 1.0
  }

  function edgePulseSec(rowA, rowB) {
    return root.edgeFlowPeriod(root.edgeFlowBps(rowA, rowB))
  }

  function setMapAnimate(on) {
    root.mapAnimate = !!on
    var settings = ({})
    var k
    for (k in root.invSettings) settings[k] = root.invSettings[k]
    settings.mapAnimate = root.mapAnimate
    root.invSettings = settings
    if (!root.inventoryReady || root.inventoryLoading) return
    if (!(root.nodes instanceof Array) || root.nodes.length === 0) return
    root.runInventoryWrite(root.inventoryWritePayload(root.nodes, settings))
  }

  // Visio-style: attach to card borders only, Manhattan elbows in the gutters.
  function mapBoxAnchor(box, towardX, towardY) {
    var cx = box.x + box.w / 2
    var cy = box.y + box.h / 2
    var dx = towardX - cx
    var dy = towardY - cy
    if (Math.abs(dx) >= Math.abs(dy)) {
      return {
        x: dx >= 0 ? box.x + box.w : box.x,
        y: cy,
        side: dx >= 0 ? "right" : "left"
      }
    }
    return {
      x: cx,
      y: dy >= 0 ? box.y + box.h : box.y,
      side: dy >= 0 ? "bottom" : "top"
    }
  }

  function mapStubOut(anchor, dist) {
    var d = dist || Style.space(12)
    if (anchor.side === "left") return { x: anchor.x - d, y: anchor.y }
    if (anchor.side === "right") return { x: anchor.x + d, y: anchor.y }
    if (anchor.side === "top") return { x: anchor.x, y: anchor.y - d }
    return { x: anchor.x, y: anchor.y + d }
  }

  function strokeMapEdge(ctx, aBox, bBox, barMidX, kind) {
    var aCx = aBox.x + aBox.w / 2
    var aCy = aBox.y + aBox.h / 2
    var bCx = bBox.x + bBox.w / 2
    var bCy = bBox.y + bBox.h / 2
    var stub = Style.space(10)
    var a0, b0, a1, b1
    var aBot = aBox.y + aBox.h
    var bBot = bBox.y + bBox.h
    // Clear vertical stack (machine→hub→service): leave bottom, enter top.
    var aAbove = aBot <= bBox.y + 2
    var bAbove = bBot <= aBox.y + 2

    if (kind === "wan" && barMidX) {
      a0 = { x: aBox.x + aBox.w, y: aCy, side: "right" }
      b0 = { x: bBox.x, y: bCy, side: "left" }
    } else if (aAbove) {
      a0 = { x: aCx, y: aBot, side: "bottom" }
      b0 = { x: bCx, y: bBox.y, side: "top" }
    } else if (bAbove) {
      a0 = { x: aCx, y: aBox.y, side: "top" }
      b0 = { x: bCx, y: bBot, side: "bottom" }
    } else if (aCx <= bCx) {
      a0 = { x: aBox.x + aBox.w, y: aCy, side: "right" }
      b0 = { x: bBox.x, y: bCy, side: "left" }
    } else {
      a0 = { x: aBox.x, y: aCy, side: "left" }
      b0 = { x: bBox.x + bBox.w, y: bCy, side: "right" }
    }

    a1 = root.mapStubOut(a0, stub)
    b1 = root.mapStubOut(b0, stub)
    ctx.moveTo(a0.x, a0.y)
    ctx.lineTo(a1.x, a1.y)

    if (Math.abs(a1.x - b1.x) < 1.5 || Math.abs(a1.y - b1.y) < 1.5) {
      ctx.lineTo(b1.x, b1.y)
    } else if (kind === "wan" && barMidX) {
      ctx.lineTo(barMidX, a1.y)
      ctx.lineTo(barMidX, b1.y)
      ctx.lineTo(b1.x, b1.y)
    } else if (aAbove || bAbove) {
      // Horizontal run strictly in the gap between the two cards.
      var gapLo = aAbove ? aBot : bBot
      var gapHi = aAbove ? bBox.y : aBox.y
      var midY = (gapLo + gapHi) / 2
      ctx.lineTo(a1.x, midY)
      ctx.lineTo(b1.x, midY)
      ctx.lineTo(b1.x, b1.y)
    } else {
      var gapL = aCx <= bCx ? (aBox.x + aBox.w) : (bBox.x + bBox.w)
      var gapR = aCx <= bCx ? bBox.x : aBox.x
      var midX = (gapL + gapR) / 2
      ctx.lineTo(midX, a1.y)
      ctx.lineTo(midX, b1.y)
      ctx.lineTo(b1.x, b1.y)
    }
    // Terminate on the border — never continue to the box centre.
    ctx.lineTo(b0.x, b0.y)
  }

  function routerMachine() {
    var i, m, id, label
    for (i = 0; i < root.machines.length; i++) {
      m = root.machines[i]
      id = String(m.id || "").toLowerCase()
      label = String(m.label || "").toLowerCase()
      if (id === "redultra" || label.indexOf("redultra") >= 0) return m
      if (String(m.mapBand || "") === "router" || String(m.role || "") === "router") return m
    }
    var u = root.unifi || {}
    var tip = String(u.url || "")
    for (i = 0; i < root.machines.length; i++) {
      m = root.machines[i]
      if (m.ip && tip.indexOf(String(m.ip)) >= 0) return m
    }
    return null
  }

  function lanTrafficTotals() {
    var rx = 0
    var tx = 0
    var i, m
    var router = root.routerMachine()
    var routerId = router ? String(router.id || "") : ""
    for (i = 0; i < root.machines.length; i++) {
      m = root.machines[i]
      if (String(m.id || "") === routerId) continue
      if (!m.rates) continue
      if (m.rates.rx_bps != null) rx += Number(m.rates.rx_bps) || 0
      if (m.rates.tx_bps != null) tx += Number(m.rates.tx_bps) || 0
    }
    return { rx_bps: rx, tx_bps: tx }
  }

  function routerMetric(row) {
    var bits = []
    var tot = root.lanTrafficTotals()
    var down = root.fmtRate(tot.rx_bps)
    var up = root.fmtRate(tot.tx_bps)
    if (down || up) bits.push("↓" + (down || "0") + " ↑" + (up || "0"))
    if (row) bits.push(root.rttText(row))
    var u = root.unifi || {}
    var nCli = (u.clients instanceof Array) ? u.clients.length : 0
    if (nCli) bits.push(nCli + " cli")
    return bits.join("  ") || "router"
  }

  function mapHiddenForId(sid) {
    var id = String(sid || "")
    if (!id || id === "__lan__") return false
    var ids = root.groupMemberIds(id)
    if (!ids.length) ids = [id]
    var i, inv, seen = false
    for (i = 0; i < ids.length; i++) {
      inv = root.invNodeById(ids[i])
      if (!inv) continue
      seen = true
      if (inv.mapHidden !== true) return false
    }
    return seen
  }

  function mapHiddenCount() {
    return root.mapHiddenEntries().length
  }

  function lanBucketRows() {
    // Natural leftovers + anything demoted from the main map via Hide / Move to LAN.
    var out = []
    var seen = ({})
    var i, row, id, g, m
    for (i = 0; i < root.quietLan.length; i++) {
      row = root.quietLan[i]
      id = String(row.id || "")
      if (!id || seen[id]) continue
      seen[id] = true
      out.push(row)
    }
    for (i = 0; i < root.groups.length; i++) {
      g = root.groups[i]
      id = String(g.id || "")
      if (!id || seen[id] || !root.mapHiddenForId(id)) continue
      seen[id] = true
      out.push(g)
    }
    for (i = 0; i < root.machines.length; i++) {
      m = root.machines[i]
      id = String(m.id || "")
      if (!id || seen[id] || !root.mapHiddenForId(id)) continue
      seen[id] = true
      out.push(m)
    }
    return out
  }

  function toggleMapHidden(sid) {
    var id = String(sid || "")
    if (!id || id === "__lan__") return
    var ids = root.groupMemberIds(id)
    if (!ids.length) ids = [id]
    var hide = !root.mapHiddenForId(id)
    var next = []
    var i, node, nid, hit
    for (i = 0; i < root.nodes.length; i++) {
      node = JSON.parse(JSON.stringify(root.nodes[i]))
      nid = String(node.id || "")
      hit = false
      for (var j = 0; j < ids.length; j++) {
        if (ids[j] === nid) { hit = true; break }
      }
      if (hit) {
        if (hide) node.mapHidden = true
        else delete node.mapHidden
      }
      next.push(node)
    }
    root.writeNodes(next)
    if (hide) {
      // Jump to List so the demoted card is visible in the LAN bucket.
      root.glanceTab = "list"
    }
    root.rebuildMapEdges()
    root.recalcMapLayout()
  }

  function mapHiddenEntries() {
    var out = []
    var seen = ({})
    var i, g, m, id, label, kind
    for (i = 0; i < root.groups.length; i++) {
      g = root.groups[i]
      id = String(g.id || "")
      if (!id || seen[id] || !root.mapHiddenForId(id)) continue
      seen[id] = true
      out.push({
        id: id,
        label: String(g.label || id),
        kind: String(g.zone || "") === "external" ? "external" : "service",
        status: root.displayStatus(g)
      })
    }
    for (i = 0; i < root.machines.length; i++) {
      m = root.machines[i]
      id = String(m.id || "")
      if (!id || seen[id] || !root.mapHiddenForId(id)) continue
      seen[id] = true
      out.push({
        id: id,
        label: String(m.label || id),
        kind: "machine",
        status: root.displayStatus(m)
      })
    }
    return out
  }

  function unhideAllMap() {
    var next = []
    var i, node
    for (i = 0; i < root.nodes.length; i++) {
      node = JSON.parse(JSON.stringify(root.nodes[i]))
      delete node.mapHidden
      next.push(node)
    }
    root.writeNodes(next)
    root.rebuildMapEdges()
    root.recalcMapLayout()
  }

  // Always include settings (even {}) so inventory_cli does not merge stale on-disk keys.
  function inventoryWritePayload(nodes, settings) {
    return {
      schemaVersion: 2,
      nodes: nodes,
      settings: settings && typeof settings === "object" ? settings : {}
    }
  }

  function runInventoryWrite(payloadObj) {
    var text = JSON.stringify(payloadObj)
    invWriteProc.command = [
      "bash", "-c",
      "f=$(mktemp /tmp/homelab-mesh-inv.XXXXXX.json) && printf '%s' '" + text.replace(/'/g, "'\\''") + "' > \"$f\" && python3 \"" + root.pluginDir + "/inventory_cli.py\" write \"$f\"; ec=$?; rm -f \"$f\"; exit $ec"
    ]
    invWriteProc.running = true
    return true
  }

  // mapHidden demotes into the LAN bucket; everything else stays on the letterbox.
  function mapRowVisible(row, kind) {
    if (!row) return false
    var id = String(row.id || "")
    if (kind === "router" || kind === "hub") return true
    if (root.mapHiddenForId(id)) return false
    return true
  }

  function internalGroups(hub) {
    var out = []
    var i, g
    for (i = 0; i < root.groups.length; i++) {
      g = root.groups[i]
      if (hub && String(g.id) === String(hub.id)) continue
      if (String(g.zone || "") === "external") continue
      if (!root.mapRowVisible(g, "service")) continue
      out.push(g)
    }
    return out
  }

  function externalGroups() {
    var out = []
    var i, g
    for (i = 0; i < root.groups.length; i++) {
      g = root.groups[i]
      if (String(g.zone || "") !== "external") continue
      if (root.mapHiddenForId(g.id)) continue
      out.push(g)
    }
    return out
  }

  function internalMachines(router) {
    var out = []
    var rid = router ? String(router.id || "") : ""
    var i, m
    for (i = 0; i < root.machines.length; i++) {
      m = root.machines[i]
      if (rid && String(m.id || "") === rid) continue
      if (!root.mapRowVisible(m, "machine")) continue
      out.push(m)
    }
    return out
  }

  function recalcMapLayout() {
    if (!mapArea || mapArea.width <= 0) return
    var w = mapArea.width
    var h = mapArea.height
    var layout = []
    var cardW = Style.space(108)
    var cardH = root.mapCardH
    var externals = root.externalGroups()
    var router = root.routerMachine()
    var hub = root.hubGroup()
    root.mapHasExternal = externals.length > 0

    // INTERNAL (~2/3) | ROUTER BAR | EXTERNAL (~1/3) — classic LAN-heavy letterbox
    var barW = root.mapHasExternal ? Style.space(140) : 0
    var usable = Math.max(Style.space(400), w - barW)
    var leftW = root.mapHasExternal
        ? Math.max(Style.space(300), Math.floor(usable * (2 / 3)))
        : w
    var rightW = root.mapHasExternal ? Math.max(Style.space(140), usable - leftW) : 0
    var barX = leftW
    root.mapSplitX = barX
    root.mapBarWidth = barW

    function place(row, subline, x, y, wCard, hCard, kind, metric, lights) {
      layout.push({
        id: String(row.id || ""),
        label: String(row.label || row.id || ""),
        subline: subline,
        status: root.displayStatus(row),
        rtt_ms: row.rtt_ms,
        rates: row.rates || null,
        x: x,
        y: y,
        w: wCard,
        h: hCard,
        kind: kind || subline,
        metric: metric || "",
        lights: lights || [],
        sparklineId: root.sparklineIdFor(row),
        zone: String(row.zone || "")
      })
    }
    function colBand(rows, subline, y, kind, metricFn, lightsFn, colX, colW) {
      var n = rows.length
      if (n <= 0) return
      var gap = colW / (n + 1)
      var cw = Math.max(Style.space(88), Math.min(cardW, gap - Style.space(6)))
      var i, row
      for (i = 0; i < n; i++) {
        row = rows[i]
        place(row, subline, colX + gap * (i + 1) - cw / 2, y, cw, cardH, kind,
              metricFn ? metricFn(row) : root.rttText(row),
              lightsFn ? lightsFn(row) : [])
      }
    }

    var machines = root.internalMachines(router)
    colBand(machines, "machine", Style.space(28), "machine", root.machineMetric, null, 0, leftW)

    // Prefer redUltra on the router bar; only fall back to Caddy there when no router machine.
    // Never place the same hub id twice (left gateway + bar).
    var hubOnRouterBar = false
    if (root.mapHasExternal) {
      var rw = Math.min(Style.space(118), barW - Style.space(14))
      var rh = Style.space(124)
      var ry = Math.max(Style.space(56), (h - rh) / 2 - Style.space(12))
      if (router) {
        place(router, "router", barX + (barW - rw) / 2, ry, rw, rh, "router",
              root.routerMetric(router), [])
      } else if (hub) {
        place(hub, "router", barX + (barW - rw) / 2, ry, rw, rh, "router",
              root.serviceMetric(hub), root.serviceLights(hub))
        hubOnRouterBar = true
      }
    }

    if (hub && !hubOnRouterBar && String(hub.zone || "") !== "external") {
      var hubW = Style.space(120)
      var hubH = Style.space(100)
      place(hub, "reverse proxy", (leftW - hubW) / 2, Style.space(132), hubW, hubH, "hub",
            root.serviceMetric(hub), root.serviceLights(hub))
    }

    var svcs = root.internalGroups(hub)
    colBand(svcs, "service", Style.space(250), "service", root.serviceMetric, root.serviceLights, 0, leftW)

    if (root.lanBucketRows().length && root.mapRowVisible(root.lanClusterRow(), "lan")) {
      var cluster = root.lanClusterRow()
      var clusterW = Math.min(Style.space(280), leftW - Style.space(20))
      place(cluster, "LAN bucket", (leftW - clusterW) / 2, Style.space(360),
            clusterW, Style.space(72), "lan", cluster.metric, cluster.lights)
    }

    if (externals.length) {
      var railX = barX + barW
      var cw = Math.min(Style.space(120), Math.max(Style.space(96), rightW - Style.space(16)))
      var gapY = Style.space(10)
      var startY = Style.space(36)
      var i, row, y
      for (i = 0; i < externals.length; i++) {
        row = externals[i]
        y = startY + i * (cardH + gapY)
        place(row, "external", railX + (rightW - cw) / 2, y, cw, cardH, "external",
              root.serviceMetric(row), root.serviceLights(row))
      }
    }
    root.mapLayout = layout
    if (edgeCanvas) edgeCanvas.requestPaint()
  }

  function moveMapSelection(dx, dy) {
    var cards = root.mapLayout
    if (cards.length === 0) return
    var cur = -1
    for (var i = 0; i < cards.length; i++) {
      if (cards[i].id === root.mapSelectedId) { cur = i; break }
    }
    if (cur < 0) {
      root.mapSelectedId = cards[0].id
      return
    }
    var next = cur
    if (dx !== 0) {
      next = Math.max(0, Math.min(cards.length - 1, cur + dx))
    } else if (dy !== 0) {
      var fromY = cards[cur].y
      var fromX = cards[cur].x + cards[cur].w / 2
      var bestDist = Infinity
      for (var j = 0; j < cards.length; j++) {
        var c = cards[j]
        if (dy > 0 ? c.y <= fromY : c.y >= fromY) continue
        var dist = Math.abs(c.y - fromY) * 10000 + Math.abs(c.x + c.w / 2 - fromX)
        if (dist < bestDist) { bestDist = dist; next = j }
      }
    }
    root.mapSelectedId = cards[next].id
  }

  function rttText(row) {
    if (!row || row.status === "unknown" || row.status === "down") return "—"
    if (row.rtt_ms === null || row.rtt_ms === undefined) return "—"
    var n = Number(row.rtt_ms)
    if (!isFinite(n)) return "—"
    if (n < 10) return (Math.round(n * 10) / 10) + " ms"
    return Math.round(n) + " ms"
  }

  function asOfShort() {
    if (!root.asOf) return ""
    var s = root.asOf
    var t = s.indexOf("T")
    if (t >= 0 && s.length >= t + 9) return s.substring(t + 1, t + 9)
    return s
  }

  function applyPayload(text) {
    var data = {}
    try { data = JSON.parse(text || "{}") || {} } catch (e) {
      // Keep last-good glance; a mid-write or empty read must not flash ERROR/PROBING.
      if (!root.asOf) {
        root.error = "Bad probe JSON"
        root.loading = false
      }
      return
    }
    if (data.error) {
      root.error = String(data.error)
      root.loading = false
      return
    }
    if (!data.as_of && root.asOf) return
    root.asOf = String(data.as_of || "")
    root.machines = data.machines instanceof Array ? data.machines : []
    root.lan = data.lan instanceof Array ? data.lan : []
    root.proxies = data.proxies instanceof Array ? data.proxies : []
    root.groups = data.groups instanceof Array ? data.groups : []
    root.quietLan = data.quiet_lan instanceof Array ? data.quiet_lan : []
    root.quietProxies = data.quiet_proxies instanceof Array ? data.quiet_proxies : []
    root.lanMeta = data.lan_meta && typeof data.lan_meta === "object" ? data.lan_meta : {}
    root.unifi = data.unifi && typeof data.unifi === "object" ? data.unifi : {}
    root.discover = data.discover instanceof Array ? data.discover : []
    root.error = ""
    root.loading = false
    if (root.opened) {
      root.rebuildMapEdges()
      root.recalcMapLayout()
    }
  }

  function ensureDaemon() {
    if (daemonProc.running) return
    daemonProc.command = ["python3", root.pluginDir + "/daemon.py"]
    daemonProc.running = true
  }

  function refresh() {
    // Only show PROBING on first fill — reloads must not grey the pill/bar.
    if (!root.asOf) root.loading = true
    root.ensureDaemon()
    snapshotView.reload()
  }

  function slugify(label) {
    var s = String(label || "").toLowerCase().trim()
    s = s.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    return s || "node"
  }

  function nodeTarget(n) {
    if (!n) return ""
    var t = String(n.type || "")
    if (t === "proxy") {
      if (String(n.check || "") === "http") return String(n.url || "")
      var h = String(n.dns || n.ip || "")
      if (h && n.port !== undefined && n.port !== null) return h + ":" + n.port
      return h
    }
    var parts = []
    if (n.dns) parts.push(String(n.dns))
    if (n.ip) parts.push(String(n.ip))
    return parts.join(" · ")
  }

  function syncFormFocus() {
    // One place instead of an N² chain of onActiveFocusChanged handlers.
    root.formFieldFocused = labelField.focused || dnsField.focused || ipField.focused
        || urlField.focused || portField.focused
  }

  function goSetup() {
    root.view = "setup"
    root.formConfirmDelete = false
    loadInventory()
  }

  function goGlance() {
    root.view = "glance"
    root.formConfirmDelete = false
    root.formFieldFocused = false
    if (root.opened) refresh()
  }

  function groupMemberIds(sid) {
    var row = root.glanceRowById(sid)
    if (row && row.member_ids) return row.member_ids
    if (row && row.members && row.id && String(row.id).indexOf("svc-") === 0) {
      var ids = []
      var i
      for (i = 0; i < row.members.length; i++) ids.push(String(row.members[i].id || ""))
      return ids
    }
    return [String(sid || "")]
  }

  function notifyEnabledForNodeId(sid) {
    if (String(sid) === "__lan__") return true
    var ids = root.groupMemberIds(sid)
    var i, inv
    for (i = 0; i < ids.length; i++) {
      inv = root.invNodeById(ids[i])
      if (inv && inv.notify === false) return false
    }
    return true
  }

  function invNodeById(sid) {
    var id = String(sid || "")
    var i
    for (i = 0; i < root.nodes.length; i++) {
      if (String(root.nodes[i].id || "") === id) return root.nodes[i]
    }
    return null
  }

  function mapCardTooltip(id, label, status, notifyOn) {
    if (String(id) === "__lan__") {
      var cluster = root.lanClusterRow()
      var lines = [cluster.metric, "List → LAN: leftovers + demoted cards · Show brings them back"]
      var unknown = (root.lanMeta && root.lanMeta.unknown_hosts) ? root.lanMeta.unknown_hosts : []
      var u
      for (u = 0; u < unknown.length && u < 6; u++)
        lines.push("new " + String(unknown[u].ip || "") + " " + String(unknown[u].mac || ""))
      return lines.join("\n")
    }
    var row = root.glanceRowById(id)
    var tip = root.listRowTooltip(row)
    if (tip) return tip
    return String(label || id) + "\n" + String(status || "unknown").toUpperCase() + "\nNotify " + (notifyOn ? "on" : "off")
  }

  function listRowTooltip(row) {
    if (!row) return ""
    var id = String(row.id || "")
    var lines = [
      String(row.label || id),
      String(row.status || "unknown").toUpperCase() + " · " + root.rttText(row)
    ]
    if (row.members) {
      var i, m, bit
      for (i = 0; i < row.members.length; i++) {
        m = row.members[i]
        bit = String(m.role || m.id) + " " + String(m.status || "")
        if (m.ttfb_ms != null) bit += " " + Math.round(Number(m.ttfb_ms)) + "ms ttfb"
        lines.push(bit)
      }
    }
    if (row.link && row.link.speed_mbit)
      lines.push(String(row.link.iface || "link") + " " + String(row.link.speed_mbit) + " Mbit"
        + (row.link.grade === "degraded" ? " (slow port)" : ""))
    if (row.rates && row.rates.rx_bps != null)
      lines.push("↓" + root.fmtRate(row.rates.rx_bps) + "  ↑" + root.fmtRate(row.rates.tx_bps))
    if (row.talkers && row.talkers.total != null) {
      var talk = String(row.talkers.total) + " talk"
      var top = row.talkers.top || []
      var t
      for (t = 0; t < top.length && t < 4; t++)
        talk += "  " + String(top[t].host || "") + "×" + String(top[t].count || 0)
      lines.push(talk)
    }
    if (row.uptime_s != null) {
      var up = root.uptimeText(row.uptime_s)
      if (up) lines.push(up)
    }
    if (row.mac) lines.push("mac " + String(row.mac))
    var inv = root.invNodeById(id)
    if (inv) {
      var tgt = root.nodeTarget(inv)
      if (tgt) lines.push(tgt)
      lines.push("Notify " + (inv.notify === false ? "off" : "on"))
    }
    return lines.join("\n")
  }

  function toggleNotifyForNodeId(sid) {
    var id = String(sid || "")
    if (!id || id === "__lan__") return
    var targets = {}
    var ids = root.groupMemberIds(id)
    var i
    for (i = 0; i < ids.length; i++) targets[String(ids[i])] = true
    var turnOn = !root.notifyEnabledForNodeId(id)
    var next = []
    var n
    for (i = 0; i < root.nodes.length; i++) {
      n = JSON.parse(JSON.stringify(root.nodes[i]))
      if (targets[String(n.id)]) {
        if (turnOn) delete n.notify
        else n.notify = false
      }
      next.push(n)
    }
    root.mapSelectedId = id
    if (!root.writeNodes(next)) {
      if (root.view === "glance")
        root.actionStatus = root.inventoryError || "Save refused"
    }
  }

  function asOfAgeSec() {
    if (!root.asOf) return -1
    var t = Date.parse(String(root.asOf))
    if (!isFinite(t)) return -1
    return Math.max(0, (Date.now() - t) / 1000)
  }

  function snapshotStale() {
    var age = root.asOfAgeSec()
    if (age < 0) return true
    // Allow a missed probe + write lag before greying STALE / bar.
    return age > (root.refreshIntervalSec * 4 + 15)
  }

  readonly property string glanceStatusLine: {
    if (root.loading) return "PROBING"
    if (root.error) return "ERROR"
    if (!root.asOf) return "NO DATA"
    if (root.snapshotStale()) return "STALE"
    var total = root.machines.length + root.groups.length + root.lanBucketRows().length + root.quietProxies.length
    if (total === 0) return "NO DATA"
    var down = 0
    var bands = [root.machines, root.groups, root.lanBucketRows(), root.quietProxies]
    var b, i
    for (b = 0; b < bands.length; b++) {
      for (i = 0; i < bands[b].length; i++) {
        if (String(bands[b][i].status) === "down") down++
      }
    }
    if (down > 0) return "LIVE · " + down + " DOWN"
    return "LIVE · ALL CLEAR"
  }

  readonly property color glanceStatusTint: {
    if (root.error) return root.urgent
    if (glanceStatusLine.indexOf("DOWN") >= 0 || glanceStatusLine === "STALE" || glanceStatusLine === "ERROR")
      return root.urgent
    if (glanceStatusLine === "PROBING" || glanceStatusLine === "NO DATA") return root.inkDim
    return root.ink
  }

  function goFormNew() {
    root.formIsNew = true
    root.formId = ""
    root.formType = "machine"
    root.formLabel = ""
    root.formDns = ""
    root.formIp = ""
    root.formCheck = "http"
    root.formUrl = ""
    root.formPort = ""
    root.formNotify = true
    root.formConfirmDelete = false
    root.view = "form"
  }

  function goFormEdit(node) {
    root.formIsNew = false
    root.formId = String(node.id || "")
    root.formType = String(node.type || "machine")
    root.formLabel = String(node.label || "")
    root.formDns = String(node.dns || "")
    root.formIp = (node.ip === null || node.ip === undefined) ? "" : String(node.ip)
    root.formCheck = String(node.check || "http")
    root.formUrl = String(node.url || "")
    root.formPort = (node.port === null || node.port === undefined) ? "" : String(node.port)
    root.formNotify = node.notify !== false
    root.formConfirmDelete = false
    root.view = "form"
  }

  function navigateBack() {
    if (root.view === "form") {
      root.view = "setup"
      root.formConfirmDelete = false
      root.formFieldFocused = false
      return
    }
    if (root.view === "setup") {
      goGlance()
      return
    }
    root.close()
  }

  function loadInventory() {
    root.inventoryError = ""
    root.inventoryLoading = true
    root.inventoryReady = false
    if (invDumpProc.running) invDumpProc.running = false
    invDumpProc.command = ["python3", root.pluginDir + "/inventory_cli.py", "dump"]
    invDumpProc.running = true
  }

  function applyInventoryDump(text) {
    var data = {}
    try { data = JSON.parse(text || "{}") || {} } catch (e) {
      root.inventoryError = "Bad inventory JSON"
      root.inventoryLoading = false
      root.inventoryReady = false
      return
    }
    if (data.error) {
      root.inventoryError = String(data.error)
      root.inventoryLoading = false
      root.inventoryReady = false
      return
    }
    if (!(data.nodes instanceof Array)) {
      root.inventoryError = "Inventory dump missing nodes"
      root.inventoryLoading = false
      root.inventoryReady = false
      return
    }
    root.nodes = data.nodes
    root.mapEdges = data.edges instanceof Array ? data.edges : []
    // Drop retired mapQuietUp if still on disk from older builds.
    var rawSettings = data.settings && typeof data.settings === "object" ? data.settings : ({})
    var cleaned = ({})
    var sk
    for (sk in rawSettings) {
      if (sk === "mapQuietUp") continue
      cleaned[sk] = rawSettings[sk]
    }
    root.invSettings = cleaned
    root.mapAnimate = cleaned.mapAnimate !== false
    if (!root.asOf) {
      var seeded = []
      var i, n
      for (i = 0; i < root.nodes.length; i++) {
        n = root.nodes[i]
        if (String(n.type || "") === "machine")
          seeded.push({ id: String(n.id || ""), label: String(n.label || n.id || ""), status: "unknown" })
      }
      if (seeded.length) root.machines = seeded
      if (data.groups instanceof Array) root.groups = data.groups
    } else if (root.groups.length === 0 && data.groups instanceof Array) {
      root.groups = data.groups
    }
    root.inventoryLoading = false
    root.inventoryReady = true
    root.rebuildMapEdges()
    root.recalcMapLayout()
    if (data.migratedFromV1) {
      // migrate once on first setup open when still on v1 file
      if (invMigrateProc.running) invMigrateProc.running = false
      invMigrateProc.command = ["python3", root.pluginDir + "/inventory_cli.py", "migrate"]
      invMigrateProc.running = true
    }
  }

  function buildFormNode() {
    var label = String(root.formLabel || "").trim()
    if (!label) return null
    var node
    if (root.formIsNew) {
      node = {}
    } else {
      var existing = root.invNodeById(root.formId)
      if (!existing) return null
      node = JSON.parse(JSON.stringify(existing))
    }
    node.id = root.formIsNew ? root.slugify(label) : String(root.formId || root.slugify(label))
    node.type = String(root.formType || "machine")
    node.label = label
    var dns = String(root.formDns || "").trim()
    var ip = String(root.formIp || "").trim()
    if (node.type === "machine" || node.type === "host") {
      delete node.check
      delete node.url
      delete node.port
      if (dns) node.dns = dns
      else delete node.dns
      node.ip = ip ? ip : null
      if (!dns && !ip) return null
      if (root.formNotify) delete node.notify
      else node.notify = false
      return node
    }
    node.check = String(root.formCheck || "tcp")
    if (node.check === "http") {
      var url = String(root.formUrl || "").trim()
      if (!url) return null
      node.url = url
      delete node.dns
      delete node.ip
      delete node.port
      if (root.formNotify) delete node.notify
      else node.notify = false
      return node
    }
    if (dns) node.dns = dns
    else delete node.dns
    if (ip) node.ip = ip
    else node.ip = null
    delete node.url
    var port = parseInt(String(root.formPort || ""), 10)
    if (!isFinite(port)) return null
    if (!dns && !ip) return null
    node.port = port
    if (root.formNotify) delete node.notify
    else node.notify = false
    return node
  }

  function saveForm() {
    var node = root.buildFormNode()
    if (!node) {
      root.inventoryError = root.formIsNew || root.invNodeById(root.formId)
          ? "Fill required fields"
          : "Node missing from inventory"
      return
    }
    var next = []
    var i
    if (root.formIsNew) {
      for (i = 0; i < root.nodes.length; i++) next.push(root.nodes[i])
      next.push(node)
    } else {
      for (i = 0; i < root.nodes.length; i++) {
        if (String(root.nodes[i].id) === String(root.formId)) next.push(node)
        else next.push(root.nodes[i])
      }
    }
    writeNodes(next)
  }

  function deleteFormNode() {
    if (!root.formConfirmDelete) {
      root.formConfirmDelete = true
      return
    }
    var next = []
    var i
    for (i = 0; i < root.nodes.length; i++) {
      if (String(root.nodes[i].id) !== String(root.formId)) next.push(root.nodes[i])
    }
    writeNodes(next)
  }

  function cleanDiscoverLabel(raw) {
    var s = String(raw || "").trim()
    s = s.replace(/\s+[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){1,5}\s*$/i, "").trim()
    return s || String(raw || "").trim()
  }

  function discoveredNode(c) {
    if (!c) return null
    var label = root.cleanDiscoverLabel(c.label || c.host || c.ip || "")
    if (!label) return null
    var isMachine = String(c.type || "") === "machine"
    var node = {
      type: isMachine ? "machine" : "host",
      label: label,
      ip: c.ip ? String(c.ip) : null
    }
    if (c.mac) node.mac = String(c.mac)
    if (c.host) {
      var h = String(c.host).replace(/\.local$/i, "")
      node.dns = h.indexOf(".") >= 0 ? h : (h + ".local")
    } else if (isMachine && String(c.source || "") === "unifi") {
      // Homelabbers usually have internal DNS — prefer .lan over typing IPs.
      node.dns = root.slugify(label).replace(/_/g, "-") + ".lan"
    }
    if (!node.dns && !node.ip) return null
    var id = root.slugify(label)
    if (root.invNodeById(id)) id = id + "-" + String(c.ip || c.mac || "").split(/[.:]/).pop()
    node.id = id
    return node
  }

  function findHosts() {
    root.findHostsBusy = true
    root.findHostsHint = root.unifiVisible()
        ? "Scanning UniFi clients, mDNS, and ARP neighbors…"
        : "Scanning mDNS + ARP… Add UniFi secrets for wired machine names."
    root.refresh()
    findHostsTimer.restart()
  }

  function discoverSourceLabel(c) {
    var src = String((c && c.source) || "")
    if (src === "unifi") return String(c.type || "") === "machine" ? "unifi · box" : "unifi"
    if (src === "mdns") return "mdns"
    if (src === "neigh") return "arp"
    return src || "found"
  }

  function addDiscovered(c) {
    var node = root.discoveredNode(c)
    if (!node) {
      root.inventoryError = "Nothing to add"
      return
    }
    var next = root.nodes.slice()
    next.push(node)
    root.writeNodes(next)
  }

  function writeNodes(nextNodes) {
    if (!root.inventoryReady || root.inventoryLoading) {
      root.inventoryError = "Inventory not loaded"
      return false
    }
    if (!(nextNodes instanceof Array) || nextNodes.length === 0) {
      root.inventoryError = "Refusing empty inventory write"
      return false
    }
    root.nodes = nextNodes
    root.inventoryError = ""
    return root.runInventoryWrite(root.inventoryWritePayload(nextNodes, root.invSettings))
  }

  onOpenedChanged: {
    if (opened) {
      root.view = "glance"
      root.mapSelectedId = ""
      root.ensureDaemon()
      loadInventory()
      // Re-apply last snapshot for map layout; avoid PROBING flash when bar already live.
      if (!root.asOf) root.loading = true
      snapshotView.reload()
      if (root.asOf) {
        root.rebuildMapEdges()
        root.recalcMapLayout()
      }
    } else {
      root.view = "glance"
      root.formFieldFocused = false
    }
  }

  FileView {
    id: snapshotView
    path: root.pluginDir + "/snapshot.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    // Apply while closed so the bar chip stays LIVE instead of ageing into grey.
    onLoaded: root.applyPayload(text())
  }

  FileView {
    id: themePaletteFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.themePaletteRaw = text()
    onLoadFailed: root.themePaletteRaw = ""
  }

  Connections {
    target: Color
    function onBackgroundChanged() { themePaletteFile.reload() }
    function onAccentChanged() { themePaletteFile.reload() }
  }

  Timer {
    id: findHostsTimer
    interval: 2500
    repeat: false
    onTriggered: {
      root.findHostsBusy = false
      var n = root.discover.length
      if (n > 0)
        root.findHostsHint = n + " candidate" + (n === 1 ? "" : "s") + " · wired UniFi boxes first"
      else if (root.unifiVisible())
        root.findHostsHint = "No new hosts — inventory may already cover the LAN"
      else
        root.findHostsHint = "Nothing new. Point settings.unifi + unifi-secrets.json at your gateway, or rely on .lan / Caddy names."
    }
  }

  Process {
    id: daemonProc
    stdout: StdioCollector { waitForEnd: false }
    stderr: StdioCollector { waitForEnd: false }
    onExited: function(exitCode) {
      // Exit 0 = another instance already holds the flock; do not thrash-restart.
      if (exitCode === 0) return
      restartDaemon.restart()
    }
  }

  Timer {
    id: restartDaemon
    interval: 750
    repeat: false
    onTriggered: root.ensureDaemon()
  }

  // Keep collector + bar health alive without opening the panel.
  Timer {
    id: bootDaemon
    interval: 400
    running: true
    repeat: false
    onTriggered: {
      root.ensureDaemon()
      snapshotView.reload()
    }
  }

  // The collector's probe gate reads this file's mtime: a fresh heartbeat means
  // the panel is open, so probe at full pace even on battery.
  Process { id: heartbeatProc }

  Timer {
    id: heartbeat
    interval: 8000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (heartbeatProc.running) return
      heartbeatProc.command = ["touch", root.pluginDir + "/.panel-heartbeat"]
      heartbeatProc.running = true
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = {}
        try { data = JSON.parse(text || "{}") || {} } catch (e) { data = {} }
        if (data.ok && data.mbps != null)
          root.actionStatus = String(data.method || "speed") + " · " + Number(data.mbps).toFixed(1) + " Mbps"
        else if (data.ok)
          root.actionStatus = "Magic packet sent" + (data.mac ? " · " + data.mac : "")
        else if (data.error) root.actionStatus = String(data.error)
        else if (String(text || "").length) root.actionStatus = String(text).trim()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: invDumpProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyInventoryDump(String(text || ""))
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.inventoryLoading)
        root.inventoryError = "Inventory dump failed"
      root.inventoryLoading = false
    }
  }

  Process {
    id: invMigrateProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: invWriteProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").length)
          root.inventoryError = String(text).trim()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        if (!root.inventoryError) root.inventoryError = "Save failed"
        root.loadInventory()
        return
      }
      if (root.view === "form") root.view = "setup"
      root.formConfirmDelete = false
      root.formFieldFocused = false
      root.loadInventory()
    }
  }

  // Safety net if inotify misses a write; bar stays fresh while panel is closed.
  Timer {
    interval: Math.max(10000, root.refreshIntervalSec * 1000)
    running: true
    repeat: true
    onTriggered: snapshotView.reload()
  }

  // Compact dash row: colour light + label + optional member lights + metric.
  component MeshRow: Item {
    property string label: ""
    property string status: "unknown"
    property string metric: ""
    property bool showMetric: true
    property bool showSpeedtest: false
    property var lights: []
    property string hoverTip: ""
    property string nodeId: ""
    signal speedtestTapped()

    width: ListView.view ? ListView.view.width : (parent ? parent.width : 0)
    height: Style.space(22)

    PanelToolTip {
      visible: rowMa.containsMouse && hoverTip !== "" && rowSpark.hoverIndex < 0
      text: hoverTip
      fontFamily: root.fontFamily
    }

    MouseArea {
      id: rowMa
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton

    RowLayout {
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        text: root.statusGlyph(status)
        color: root.statusColor(status)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.preferredWidth: Style.space(12)
      }
      Text {
        text: label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Sparkline {
        id: rowSpark
        visible: nodeId !== ""
        Layout.preferredWidth: 56
        Layout.preferredHeight: 14
        Layout.alignment: Qt.AlignVCenter
        nodeId: nodeId
        pluginDir: root.pluginDir
        live: root.opened && root.view === "glance" && root.glanceTab === "list" && nodeId !== ""
        stroke: root.ink
        rateStroke: Color.accent
        muted: root.inkDim
        fontFamily: root.fontFamily
      }
      Row {
        spacing: 3
        visible: lights && lights.length > 1
        Repeater {
          model: lights
          Rectangle {
            required property var modelData
            width: 6
            height: 6
            radius: 3
            anchors.verticalCenter: parent.verticalCenter
            color: root.statusColor(String(modelData || "unknown"))
          }
        }
      }
      Text {
        visible: showMetric
        text: metric
        color: (metric === "—") ? root.muted : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
      }
      Text {
        visible: showSpeedtest
        text: "speed"
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
        MouseArea {
          anchors.fill: parent
          anchors.margins: -4
          cursorShape: Qt.PointingHandCursor
          onClicked: speedtestTapped()
        }
      }
    }
    }
  }

  component SetupRow: Item {
    property var node: ({})
    property string trailing: ""
    property string sourceChip: ""
    signal activated()

    width: parent ? parent.width : 0
    height: Style.space(46)

    Rectangle {
      anchors.fill: parent
      anchors.margins: Style.space(1)
      radius: Style.space(6)
      color: setupMa.containsMouse ? Qt.alpha(root.ink, 0.06) : "transparent"
      border.width: 1
      border.color: setupMa.containsMouse ? root.borderHover : Qt.alpha(root.ink, 0.10)
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(9)
      anchors.rightMargin: Style.space(9)
      spacing: Style.space(8)

      Rectangle {
        Layout.preferredWidth: chipText.implicitWidth + Style.space(12)
        Layout.preferredHeight: Style.space(22)
        radius: Style.space(4)
        color: Qt.alpha(String(node.type || "") === "machine" ? root.themeGreen : root.ink, 0.12)
        border.width: 1
        border.color: Qt.alpha(String(node.type || "") === "machine" ? root.themeGreen : root.ink, 0.28)
        Text {
          id: chipText
          anchors.centerIn: parent
          text: String(node.type || "")
          color: String(node.type || "") === "machine" ? root.themeGreen : root.muted
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
      Rectangle {
        visible: sourceChip !== ""
        Layout.preferredWidth: srcText.implicitWidth + Style.space(10)
        Layout.preferredHeight: Style.space(20)
        radius: Style.space(4)
        color: Qt.alpha(Color.accent, 0.12)
        border.width: 1
        border.color: Qt.alpha(Color.accent, 0.35)
        Text {
          id: srcText
          anchors.centerIn: parent
          text: sourceChip
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: 9
          font.bold: true
        }
      }
      Text {
        text: String(node.label || node.id || "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        Layout.fillWidth: true
      }
      Text {
        text: root.nodeTarget(node)
        color: root.muted
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: Style.space(140)
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
      }
      Text {
        visible: trailing !== ""
        text: trailing
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
      }
    }

    MouseArea {
      id: setupMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: activated()
    }
  }

  component BandCap: Text {
    property string title: ""
    text: title
    color: root.muted
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.1
  }

  component MapCard: Rectangle {
    id: mapBox
    property string nodeId: ""
    property string label: ""
    property string subline: ""
    property string status: "unknown"
    property string kind: ""
    property string metric: ""
    property var lights: []
    property var rttRow: null
    property string sparklineId: ""
    property bool selected: false
    property bool notifyOn: true
    readonly property bool isLan: nodeId === "__lan__"
    signal activated()
    signal notifyClicked()

    width: Style.space(108)
    height: root.mapCardH
    radius: Style.space(14)
    // One signal: status drives fill and rim. Role (router / reverse proxy) is the subline, not a second colour.
    color: {
      if (cardMa.containsMouse) return Qt.alpha(root.statusColor(status), 0.22)
      if (status === "up") return Qt.alpha(root.themeGreen, 0.16)
      if (status === "degraded") return Qt.alpha(root.themeYellow, 0.18)
      if (status === "down") return Qt.alpha(root.statusColor("down"), 0.20)
      return root.card
    }
    border.width: selected || status === "down" ? 2 : 1
    border.color: {
      if (selected || status === "up" || status === "degraded" || status === "down")
        return Qt.alpha(root.statusColor(status), selected || status === "down" ? 1.0 : 0.88)
      return root.borderIdle
    }

    Rectangle {
      visible: !mapBox.isLan
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(8)
      width: notifyLab.implicitWidth + Style.space(14)
      height: Style.space(18)
      radius: Style.space(9)
      color: mapBox.notifyOn ? Qt.alpha(root.ink, 0.08) : Qt.alpha(root.urgent, 0.14)
      border.width: 1
      border.color: mapBox.notifyOn ? Qt.alpha(root.ink, 0.22) : Qt.alpha(root.urgent, 0.45)
      z: 2
      Text {
        id: notifyLab
        anchors.centerIn: parent
        text: mapBox.notifyOn ? "ALERT" : "MUTE"
        color: mapBox.notifyOn ? root.inkDim : root.urgent
        font.family: root.fontFamily
        font.pixelSize: 8
        font.bold: true
        font.letterSpacing: 0.6
      }
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: mapBox.notifyClicked()
      }
    }

    PanelToolTip {
      visible: cardMa.containsMouse && cardSpark.hoverIndex < 0
      text: root.mapCardTooltip(mapBox.nodeId, mapBox.label, mapBox.status, mapBox.notifyOn)
      fontFamily: root.fontFamily
    }

    MouseArea {
      id: cardMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: mapBox.activated()

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: subline.toUpperCase()
        color: root.inkDim
        font.family: root.fontFamily
        font.pixelSize: 10
        font.letterSpacing: 1.2
        elide: Text.ElideRight
      }

      RowLayout {
        width: parent.width
        spacing: Style.space(6)
        Text {
          text: root.statusGlyph(status)
          color: root.statusColor(status)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          Layout.preferredWidth: Style.space(12)
        }
        Text {
          text: label
          color: root.ink
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          Layout.fillWidth: true
        }
      }

      Text {
        width: parent.width
        text: mapBox.metric !== "" ? mapBox.metric : root.rttText(rttRow)
        color: (mapBox.metric === "—" || mapBox.metric === "") ? root.inkDim : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Row {
        spacing: 4
        visible: lights && lights.length > 0
        Repeater {
          model: lights
          Rectangle {
            required property var modelData
            width: 7
            height: 7
            radius: 4
            color: root.statusColor(String(modelData || "unknown"))
          }
        }
      }

      Sparkline {
        id: cardSpark
        width: parent.width
        height: Style.space(16)
        nodeId: mapBox.sparklineId
        pluginDir: root.pluginDir
        live: root.opened && root.view === "glance" && root.glanceTab === "map" && mapBox.sparklineId !== ""
        stroke: root.ink
        rateStroke: Color.accent
        muted: root.inkDim
        fontFamily: root.fontFamily
      }
    }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: 1
      color: root.rule
      opacity: selected ? 0.5 : 0.25
    }
  }

  // Pulse Panel.qml Action — page/tab pills
  component TabAction: Rectangle {
    id: act
    property string text: ""
    property bool selected: false
    signal clicked()
    implicitWidth: caption.implicitWidth + Style.space(26)
    implicitHeight: Style.space(34)
    radius: Style.space(9)
    color: act.selected ? Qt.alpha(root.ink, Style.selectedFillAlpha)
                        : tabMa.containsMouse ? Style.hoverFill : Style.normalFill
    border.color: act.selected ? root.ink
                               : tabMa.containsMouse ? Style.hoverBorderColor : Style.normalBorderColor
    Behavior on color { ColorAnimation { duration: 120 } }
    Text {
      id: caption
      anchors.centerIn: parent
      text: act.text
      color: act.selected ? root.ink : root.inkDim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: act.selected
    }
    MouseArea {
      id: tabMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: act.clicked()
    }
  }

  component SegBtn: Rectangle {
    property string label: ""
    property bool active: false
    signal tapped()
    implicitWidth: segLab.implicitWidth + Style.space(16)
    implicitHeight: Style.space(28)
    radius: Style.space(4)
    color: active ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
                  : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, active ? 0.28 : 0.10)
    Text {
      id: segLab
      anchors.centerIn: parent
      text: label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: active
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tapped() }
  }

  readonly property int glanceDownCount: {
    var n = 0
    var i
    for (i = 0; i < root.machines.length; i++)
      if (String(root.machines[i].status) === "down") n++
    for (i = 0; i < root.groups.length; i++)
      if (String(root.groups[i].status) === "down") n++
    return n
  }

  readonly property int glanceDegradedCount: {
    var n = 0
    var i
    for (i = 0; i < root.machines.length; i++)
      if (root.displayStatus(root.machines[i]) === "degraded") n++
    for (i = 0; i < root.groups.length; i++)
      if (String(root.groups[i].status) === "degraded") n++
    return n
  }

  readonly property color barHealthColor: {
    if (root.glanceDownCount > 0) return (root.themeRed && String(root.themeRed) !== "") ? root.themeRed : root.urgent
    if (root.glanceDegradedCount > 0) return root.themeYellow
    if (!root.asOf || root.snapshotStale()) return root.inkDim
    return root.themeGreen
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "Lanarchy"
    active: root.opened
    useActiveColor: false
    iconComponent: Component {
      Item {
        LanarchyIcon {
          anchors.centerIn: parent
          iconSize: Style.space(14)
          color: root.barHealthColor
          alert: root.urgent
          alarmed: root.glanceDownCount > 0
          active: root.opened || root.glanceDownCount > 0 || root.glanceDegradedCount > 0
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    padding: root.view === "glance" && root.glanceTab === "map" ? Style.space(12) : Style.space(8)
    borderSpec: root.view === "glance" && root.glanceTab === "map"
        ? Border.flat(Color.accent, 2) : Border.none()
    contentWidth: panel.fittedContentWidth(root.view === "glance" && root.glanceTab === "map"
        ? Style.space(1280) : Style.space(560))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Block Esc/keys while form fields focused — TextField handles input.
      enabled: !(root.view === "form" && root.formFieldFocused)
      onCloseRequested: root.navigateBack()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.view !== "glance") return
        var k = String(text || "").toLowerCase()
        if (k === "r") root.refresh()
        if (k === "m" || k === "l") root.glanceTab = root.glanceTab === "map" ? "list" : "map"
        if (k === "h" && root.mapSelectedId) root.toggleMapHidden(root.mapSelectedId)
        if (k === "a" && root.glanceTab === "map") root.setMapAnimate(!root.mapAnimate)
        if (k === "s") root.goSetup()
      }
      onMoveRequested: function(dx, dy) {
        if (root.view === "glance" && root.glanceTab === "map") root.moveMapSelection(dx, dy)
      }
      onActivateRequested: {
        if (root.view === "glance" && root.glanceTab === "map") root.toggleNotifyForNodeId(root.mapSelectedId)
      }

      Item {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        implicitHeight: glanceBody.implicitHeight

        Rectangle {
          anchors.fill: parent
          anchors.margins: -Style.space(10)
          radius: Style.space(14)
          color: Color.popups.background
          z: -1
        }

        Column {
          id: glanceBody
          width: parent.width
          spacing: Style.space(10)

        // Header — Pulse heading + Omastorm status strip
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.view === "glance"
          Row {
            width: parent.width
            spacing: Style.space(10)
            Column {
              width: Math.max(Style.space(120), parent.width - Style.space(200))
              spacing: Style.space(3)
              Row {
                spacing: Style.space(8)
                LanarchyIcon {
                  iconSize: Style.space(22)
                  color: root.ink
                  alert: root.urgent
                  alarmed: root.glanceDownCount > 0
                  active: true
                }
                Text {
                  text: "LANARCHY"
                  color: root.ink
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  font.letterSpacing: 2.5
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Text {
                width: parent.width
                text: root.glanceTab === "map"
                    ? (root.mapHasExternal
                        ? "2⁄3 INTERNAL · reverse proxy hub · router bar · Visio elbows · Flow toggles animation"
                        : "Machines → Caddy → services · Flow toggles animation")
                    : "Dash · colour lights · Move to LAN for noise"
                color: root.inkDim
                font.family: root.fontFamily
                font.pixelSize: 11
                elide: Text.ElideRight
              }
            }
            Rectangle {
              id: statusPill
              height: Style.space(32)
              width: statusRow.implicitWidth + Style.space(20)
              radius: Style.space(16)
              color: Qt.alpha(root.glanceStatusTint, 0.16)
              border.color: Qt.alpha(root.glanceStatusTint, 0.72)
              border.width: 1
              Row {
                id: statusRow
                anchors.centerIn: parent
                spacing: Style.space(7)
                Rectangle {
                  width: 6
                  height: 6
                  radius: 3
                  color: root.glanceStatusTint
                  anchors.verticalCenter: parent.verticalCenter
                  SequentialAnimation on opacity {
                    running: root.opened && !root.loading && !root.error
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.35; duration: 900 }
                    NumberAnimation { to: 1; duration: 900 }
                  }
                }
                Text {
                  text: root.glanceStatusLine + (root.asOfShort() ? " · " + root.asOfShort() : "")
                  color: root.ink
                  font.family: root.fontFamily
                  font.pixelSize: 9
                  font.bold: true
                }
              }
            }
          }
          Row {
            width: parent.width
            spacing: Style.space(8)
            TabAction {
              text: "Map"
              selected: root.glanceTab === "map"
              onClicked: root.glanceTab = "map"
            }
            TabAction {
              text: "List"
              selected: root.glanceTab === "list"
              onClicked: root.glanceTab = "list"
            }
            Item { width: Style.space(8); height: 1 }
            TabAction {
              visible: root.glanceTab === "map"
              text: "Flow"
              selected: root.mapAnimate
              onClicked: root.setMapAnimate(!root.mapAnimate)
            }
            Item { width: Style.space(8); height: 1 }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "⚙ Setup"
              color: root.inkDim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(8)
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goSetup()
              }
            }
          }
        }

        Item {
          width: parent.width
          height: Style.space(28)
          visible: root.view !== "glance"
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.view === "setup" ? "Setup" : (root.formIsNew ? "Add node" : "Edit node")
            color: root.ink
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
        }

        Text {
          visible: root.view === "glance" && root.error !== ""
          width: parent.width
          text: root.error
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        Text {
          visible: (root.view === "setup" || root.view === "form") && root.inventoryError !== ""
          width: parent.width
          text: root.inventoryError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
        }

        // ——— GLANCE ———
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.view === "glance"

            Rectangle {
            id: mapArea
            width: parent.width
            height: Style.space(460)
            visible: root.glanceTab === "map"
            radius: Style.space(14)
            color: Color.popups.background
            border.width: 1
            border.color: Qt.alpha(Color.accent, 0.35)
            onWidthChanged: root.recalcMapLayout()
            onHeightChanged: root.recalcMapLayout()
            clip: true

            // Full-height router column between INTERNAL and EXTERNAL
            Rectangle {
              id: routerBar
              visible: root.mapHasExternal && root.mapBarWidth > 0
              x: root.mapSplitX
              y: Style.space(6)
              width: root.mapBarWidth
              height: parent.height - Style.space(12)
              radius: Style.space(10)
              color: Qt.alpha(Color.accent, 0.08)
              border.width: 1
              border.color: Qt.alpha(Color.accent, 0.45)

              // Router column: body + one slow pulse (aggregate rates belong here only)
              Canvas {
                id: routerTrafficCanvas
                anchors.fill: parent
                anchors.margins: Style.space(4)
                property real phase: root.edgePhase
                onPhaseChanged: requestPaint()
                onPaint: {
                  var ctx = getContext("2d")
                  ctx.clearRect(0, 0, width, height)
                  var tot = root.lanTrafficTotals()
                  var bps = Math.max(tot.rx_bps || 0, tot.tx_bps || 0)
                  var w = root.edgeFlowWidth(bps)
                  var cx = width / 2
                  var y0 = 10
                  var y1 = height - 10
                  var accent = Color.accent
                  ctx.lineCap = "round"
                  ctx.strokeStyle = Qt.alpha(accent, 0.22)
                  ctx.lineWidth = w
                  ctx.beginPath()
                  ctx.moveTo(cx, y0)
                  ctx.lineTo(cx, y1)
                  ctx.stroke()
                  if (root.mapAnimate) {
                    // March visibility is fixed — rate only thickens the underglow / sets pace.
                    ctx.strokeStyle = Qt.alpha(accent, 0.9)
                    ctx.lineWidth = 2.2
                    ctx.setLineDash([8, 14])
                    ctx.lineDashOffset = -(phase * root.edgeFlowSpeed(bps))
                    ctx.beginPath()
                    ctx.moveTo(cx, y0)
                    ctx.lineTo(cx, y1)
                    ctx.stroke()
                    ctx.setLineDash([])
                  }
                }
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: Style.space(6)
                text: "ROUTER"
                color: root.inkDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.4
                font.bold: true
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(6)
                text: {
                  var t = root.lanTrafficTotals()
                  var d = root.fmtRate(t.rx_bps)
                  var u = root.fmtRate(t.tx_bps)
                  return (d || u) ? ("↓" + (d || "0") + "  ↑" + (u || "0")) : "idle"
                }
                color: root.ink
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

              Text {
              visible: root.mapHasExternal
              x: Style.space(10)
              y: Style.space(6)
              text: "INTERNAL"
              color: root.themeGreen
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              font.bold: true
            }
            Text {
              visible: root.mapHasExternal
              x: root.mapSplitX + root.mapBarWidth + Style.space(10)
              y: Style.space(6)
              text: "EXTERNAL"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
              font.bold: true
            }

            Timer {
              interval: 50
              running: root.opened && root.view === "glance" && root.glanceTab === "map" && root.mapAnimate
              repeat: true
              onTriggered: {
                // ~44 dash-units/sec against [8,14] (~22px period).
                root.edgePhase = (root.edgePhase + 2.2) % 1000
                edgeCanvas.requestPaint()
                if (routerTrafficCanvas) routerTrafficCanvas.requestPaint()
              }
            }

            Canvas {
              id: edgeCanvas
              anchors.fill: parent
              z: 0
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var boxes = ({})
                var i, box
                for (i = 0; i < root.mapLayout.length; i++) {
                  box = root.mapLayout[i]
                  boxes[box.id] = {
                    x: box.x, y: box.y, w: box.w, h: box.h
                  }
                }
                var barMidX = root.mapHasExternal
                    ? (root.mapSplitX + root.mapBarWidth / 2)
                    : 0

                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                for (i = 0; i < root.mapEdges.length; i++) {
                  var e = root.mapEdges[i]
                  var aBox = boxes[String(e.from || "")]
                  var bBox = boxes[String(e.to || "")]
                  if (!aBox || !bBox) continue
                  var rowA = root.glanceRowById(e.from)
                  var rowB = root.glanceRowById(e.to)
                  var bps = root.edgeFlowBps(rowA, rowB)
                  var w = root.edgeFlowWidth(bps)
                  var kind = String(e.kind || "")
                  var isWan = kind === "wan"
                  var base = isWan ? Color.accent : root.themeGreen
                  // Soft underglow: width tracks real endpoint rates (deba looks fat when busy).
                  ctx.strokeStyle = Qt.alpha(base, 0.28)
                  ctx.lineWidth = w
                  ctx.setLineDash([])
                  ctx.beginPath()
                  root.strokeMapEdge(ctx, aBox, bBox, barMidX, kind)
                  ctx.stroke()
                  if (root.mapAnimate) {
                    // Same march on every edge; phase stagger so they don't lockstep.
                    // Pace from endpoint rates: busy ≈ full speed, quiet ≈ 1/10.
                    var stagger = ((i * 17) + String(e.from || "").length * 3 + String(e.to || "").length * 5) % 22
                    var pace = root.edgeFlowSpeed(bps)
                    ctx.strokeStyle = Qt.alpha(base, 0.88)
                    ctx.lineWidth = 2.0
                    ctx.setLineDash([8, 14])
                    ctx.lineDashOffset = -(root.edgePhase * pace + stagger)
                    ctx.beginPath()
                    root.strokeMapEdge(ctx, aBox, bBox, barMidX, kind)
                    ctx.stroke()
                    ctx.setLineDash([])
                  }
                }
              }
            }

            Repeater {
              model: root.mapLayout
              z: 1
              delegate: MapCard {
                required property var modelData
                z: 1
                x: modelData.x
                y: modelData.y
                width: modelData.w
                height: modelData.h
                nodeId: String(modelData.id || "")
                label: String(modelData.label || "")
                subline: String(modelData.subline || "")
                status: String(modelData.status || "unknown")
                kind: String(modelData.kind || "")
                metric: String(modelData.metric || "")
                lights: modelData.lights || []
                rttRow: modelData
                sparklineId: String(modelData.sparklineId || "")
                selected: root.mapSelectedId === String(modelData.id || "")
                notifyOn: root.notifyEnabledForNodeId(nodeId)
                onActivated: {
                  root.mapSelectedId = nodeId
                  if (nodeId === "__lan__") {
                    root.glanceTab = "list"
                  }
                }
                onNotifyClicked: root.toggleNotifyForNodeId(nodeId)
              }
            }
          }

          Rectangle {
            width: parent.width
            visible: root.glanceTab === "map"
            radius: Style.space(4)
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
            implicitHeight: mapDetail.implicitHeight + Style.space(16)
            Column {
              id: mapDetail
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(6)
              Text {
                width: parent.width
                color: root.mapSelectedId ? root.foreground : root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                text: {
                  if (!root.mapSelectedId) return "Click a machine, the Caddy hub, a service, or the LAN cluster"
                  var row = root.glanceRowById(root.mapSelectedId)
                  if (!row) return root.mapSelectedId
                  if (row.id === "__lan__") return row.metric + " · List → LAN to Show demoted cards back onto the map"
                  var metric = row.members ? root.serviceMetric(row) : root.machineMetric(row)
                  return String(row.label || row.id) + " · " + String(row.status) + " · " + metric
                }
              }
              Row {
                visible: root.mapSelectedId !== "" && root.mapSelectedId !== "__lan__"
                spacing: Style.space(8)
                SegBtn {
                  label: root.notifyEnabledForNodeId(root.mapSelectedId) ? "Notify on" : "Notify off"
                  active: root.notifyEnabledForNodeId(root.mapSelectedId)
                  onTapped: root.toggleNotifyForNodeId(root.mapSelectedId)
                }
                SegBtn {
                  label: root.mapHiddenForId(root.mapSelectedId) ? "Show on map" : "Move to LAN"
                  active: root.mapHiddenForId(root.mapSelectedId)
                  onTapped: root.toggleMapHidden(root.mapSelectedId)
                }
                SegBtn {
                  label: "Edit in Setup"
                  active: false
                  onTapped: {
                    var node = root.invNodeById(root.mapSelectedId)
                    var ids = root.groupMemberIds(root.mapSelectedId)
                    if (!node && ids.length) node = root.invNodeById(ids[0])
                    root.goSetup()
                    if (node) root.goFormEdit(node)
                  }
                }
                SegBtn {
                  visible: {
                    var row = root.glanceRowById(root.mapSelectedId)
                    return !!(row && !row.members && root.sshHostFor(row))
                  }
                  label: "SSH"
                  active: false
                  onTapped: root.openSsh(root.glanceRowById(root.mapSelectedId))
                }
                SegBtn {
                  visible: {
                    var row = root.glanceRowById(root.mapSelectedId)
                    return !!(row && row.status === "down" && row.mac)
                  }
                  label: "Wake"
                  active: false
                  onTapped: root.wakeNode(root.glanceRowById(root.mapSelectedId))
                }
                SegBtn {
                  visible: {
                    var row = root.glanceRowById(root.mapSelectedId)
                    return !!(row && !row.members)
                  }
                  label: "Speedtest"
                  active: false
                  onTapped: root.speedtestNode(root.glanceRowById(root.mapSelectedId))
                }
              }
              Text {
                visible: root.actionStatus !== ""
                width: parent.width
                text: root.actionStatus
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Flickable {
            id: listScroll
            width: parent.width
            height: Math.min(Style.space(420), listCol.implicitHeight)
            visible: root.glanceTab === "list"
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: width
            contentHeight: listCol.implicitHeight
            Column {
              id: listCol
              width: listScroll.width
              spacing: Style.space(6)

              BandCap { title: "MACHINES"; width: parent.width }
              Repeater {
                model: root.machines
                MeshRow {
                  required property var modelData
                  width: parent.width
                  nodeId: root.sparklineIdFor(modelData)
                  label: String(modelData.label || modelData.id || "")
                  status: root.displayStatus(modelData)
                  metric: root.machineMetric(modelData)
                  hoverTip: root.listRowTooltip(modelData)
                  showSpeedtest: true
                  onSpeedtestTapped: root.speedtestNode(modelData)
                }
              }

              BandCap {
                visible: root.unifiVisible()
                title: "UNIFI"
                width: parent.width
              }
              MeshRow {
                visible: root.unifiVisible()
                width: parent.width
                label: String((root.unifi && root.unifi.name) || "UniFi")
                status: (root.unifi && root.unifi.ok) ? "up" : "down"
                metric: root.unifiMetric()
                lights: root.unifiLights()
                hoverTip: {
                  var u = root.unifi || {}
                  var bits = [u.model || "UniFi OS", u.auth === "none" ? "local /api/system · drop API key in unifi-secrets.json" : ("auth " + u.auth)]
                  if (u.mac) bits.push(u.mac)
                  if (u.url) bits.push(u.url)
                  return bits.join(" · ")
                }
              }

              BandCap { title: "SERVICES"; width: parent.width }
              Repeater {
                model: root.groups
                MeshRow {
                  required property var modelData
                  width: parent.width
                  nodeId: root.sparklineIdFor(modelData)
                  label: String(modelData.label || modelData.id || "")
                  status: String(modelData.status || "unknown")
                  metric: root.serviceMetric(modelData)
                  lights: root.serviceLights(modelData)
                  hoverTip: root.listRowTooltip(modelData)
                }
              }

              BandCap {
                visible: root.lanBucketRows().length > 0
                title: "LAN"
                width: parent.width
              }
              Row {
                visible: root.mapHiddenCount() > 0
                width: parent.width
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.mapHiddenCount() + " demoted from map"
                  color: root.inkDim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                SegBtn {
                  label: "Show all on map"
                  active: false
                  onTapped: root.unhideAllMap()
                }
              }
              Repeater {
                model: root.lanBucketRows()
                RowLayout {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(8)
                  height: Style.space(22)
                  MeshRow {
                    Layout.fillWidth: true
                    nodeId: root.sparklineIdFor(modelData)
                    label: String(modelData.label || modelData.id || "")
                      + (root.mapHiddenForId(modelData.id) ? " · demoted" : "")
                    status: String(modelData.status || "unknown")
                    metric: modelData.members ? root.serviceMetric(modelData) : root.rttText(modelData)
                    lights: modelData.members ? root.serviceLights(modelData) : []
                    hoverTip: root.listRowTooltip(modelData)
                  }
                  SegBtn {
                    visible: root.mapHiddenForId(modelData.id)
                    label: "Show"
                    active: false
                    onTapped: root.toggleMapHidden(String(modelData.id || ""))
                  }
                }
              }

              BandCap {
                visible: root.quietProxies.length > 0
                title: "PROXIES"
                width: parent.width
              }
              Repeater {
                model: root.quietProxies
                MeshRow {
                  required property var modelData
                  width: parent.width
                  nodeId: root.sparklineIdFor(modelData)
                  label: String(modelData.label || modelData.id || "")
                  status: String(modelData.status || "unknown")
                  metric: root.rttText(modelData)
                  hoverTip: root.listRowTooltip(modelData)
                }
              }
            }
          }

          Text {
            visible: root.actionStatus !== "" && root.glanceTab === "list"
            width: parent.width
            text: root.actionStatus
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.glanceTab === "map"
                ? "Move to LAN / Show on map · click LAN cluster · m list"
                : "LAN bucket = leftovers + demoted · Show restores · m map · r refresh"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ——— SETUP LIST ———
        Flickable {
          id: setupScroll
          width: parent.width
          height: Math.min(Style.space(560), setupCol.implicitHeight)
          visible: root.view === "setup"
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          contentWidth: width
          contentHeight: setupCol.implicitHeight
          interactive: contentHeight > height
          flickDeceleration: 6000
          maximumFlickVelocity: 2600
          ScrollBar.vertical: ScrollBar {
            policy: setupScroll.contentHeight > setupScroll.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
            width: 6
          }

          Column {
            id: setupCol
            width: setupScroll.width - (setupScroll.contentHeight > setupScroll.height ? 10 : 0)
            spacing: Style.space(8)

          Text {
            visible: root.inventoryLoading
            width: parent.width
            text: "Loading…"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Find hosts — primary path for homelabbers (UniFi / mDNS / .lan), not typing IPs.
          Rectangle {
            visible: !root.inventoryLoading
            width: parent.width
            radius: Style.space(10)
            color: Qt.alpha(Color.accent, 0.10)
            border.width: 1
            border.color: Qt.alpha(Color.accent, 0.45)
            implicitHeight: findCol.implicitHeight + Style.space(20)

            Column {
              id: findCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              Text {
                width: parent.width
                text: "Find hosts on your network"
                color: root.ink
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                width: parent.width
                text: root.unifiVisible()
                    ? "Uses UniFi wired clients as real boxes/VMs, plus mDNS services and ARP neighbors. Reverse-proxy names (.lan via Caddy) stay as hosts — add the box itself from UniFi."
                    : "Searches mDNS + ARP. Drop a UniFi API key in unifi-secrets.json to name wired machines (Home Assistant, yanagiba, …) instead of raw IPs."
                color: root.inkDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
              Row {
                spacing: Style.space(8)
                Rectangle {
                  implicitWidth: findLab.implicitWidth + Style.space(24)
                  implicitHeight: Style.space(34)
                  radius: Style.space(8)
                  color: root.findHostsBusy ? Qt.alpha(Color.accent, 0.25) : Qt.alpha(Color.accent, 0.55)
                  border.width: 1
                  border.color: Color.accent
                  Text {
                    id: findLab
                    anchors.centerIn: parent
                    text: root.findHostsBusy ? "Searching…" : "Search network"
                    color: root.ink
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: !root.findHostsBusy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.findHosts()
                  }
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.findHostsHint !== ""
                  text: root.findHostsHint
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          BandCap {
            visible: !root.inventoryLoading && root.nodes.length > 0
            title: "INVENTORY"
            width: parent.width
          }
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: !root.inventoryLoading && root.nodes.length > 0
            Repeater {
              model: root.nodes
              SetupRow {
                required property var modelData
                width: parent.width
                node: modelData
                onActivated: root.goFormEdit(modelData)
              }
            }
          }

          BandCap {
            visible: !root.inventoryLoading && root.discover.length > 0
            title: "FOUND · click to add · machines first"
            width: parent.width
          }
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: !root.inventoryLoading && root.discover.length > 0
            Repeater {
              model: root.discover
              SetupRow {
                required property var modelData
                width: parent.width
                node: root.discoveredNode(modelData) || {}
                sourceChip: root.discoverSourceLabel(modelData)
                trailing: "+ add"
                onActivated: root.addDiscovered(modelData)
              }
            }
          }

          Rectangle {
            visible: !root.inventoryLoading && root.nodes.length === 0 && root.discover.length === 0
            width: parent.width
            height: Style.space(56)
            radius: Style.space(8)
            color: Qt.alpha(root.ink, 0.04)
            border.width: 1
            border.color: root.borderIdle
            Text {
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              horizontalAlignment: Text.AlignHCenter
              text: "No inventory yet — Search network above, or add a node by .lan name"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }
          }

          Row {
            spacing: Style.space(8)
            visible: !root.inventoryLoading
            Rectangle {
              implicitWidth: addLab.implicitWidth + Style.space(20)
              implicitHeight: Style.space(32)
              radius: Style.space(6)
              color: Qt.alpha(root.ink, 0.08)
              border.width: 1
              border.color: root.borderIdle
              Text {
                id: addLab
                anchors.centerIn: parent
                text: "Add node manually"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.goFormNew()
              }
            }
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Esc back to glance"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          }
        }

        // ——— FORM ———
        // Law of the panel: every control on screen at once. Two columns, labels
        // inline, never a scrolling settings form.
        Column {
          id: formCol
          width: parent.width
          spacing: Style.space(10)
          visible: root.view === "form"

          component Field: Column {
            id: field
            property string caption: ""
            property alias text: input.text
            property alias placeholder: input.placeholderText
            property alias focused: input.activeFocus
            property alias input: input
            spacing: Style.space(3)
            Text {
              text: field.caption
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            TextField {
              id: input
              width: field.width
              onActiveFocusChanged: root.syncFormFocus()
            }
          }

          // Type + notify on one line (was two stacked rows)
          Row {
            spacing: Style.space(6)
            SegBtn { label: "machine"; active: root.formType === "machine"; onTapped: root.formType = "machine" }
            SegBtn { label: "host"; active: root.formType === "host"; onTapped: root.formType = "host" }
            SegBtn { label: "proxy"; active: root.formType === "proxy"; onTapped: root.formType = "proxy" }
            Item { width: Style.space(10); height: 1 }
            SegBtn {
              label: root.formNotify ? "Notify on" : "Notify off"
              active: root.formNotify
              onTapped: root.formNotify = !root.formNotify
            }
            Item { width: Style.space(10); height: 1 }
            SegBtn {
              visible: root.formType === "proxy"
              label: "http"
              active: root.formCheck === "http"
              onTapped: root.formCheck = "http"
            }
            SegBtn {
              visible: root.formType === "proxy"
              label: "tcp"
              active: root.formCheck === "tcp"
              onTapped: root.formCheck = "tcp"
            }
          }

          readonly property real colW: (formCol.width - Style.space(10)) / 2
          readonly property bool addressable: root.formType !== "proxy" || root.formCheck === "tcp"

          Row {
            spacing: Style.space(10)
            Field {
              id: labelField
              width: formCol.colW
              caption: "Label"
              placeholder: "required"
              text: root.formLabel
              onTextChanged: root.formLabel = text
            }
            Field {
              id: dnsField
              width: formCol.colW
              visible: formCol.addressable
              caption: "DNS"
              placeholder: "hostname.lan"
              text: root.formDns
              onTextChanged: root.formDns = text
            }
            Field {
              id: urlField
              width: formCol.colW
              visible: root.formType === "proxy" && root.formCheck === "http"
              caption: "URL"
              placeholder: "http://…"
              text: root.formUrl
              onTextChanged: root.formUrl = text
            }
          }

          Row {
            spacing: Style.space(10)
            visible: formCol.addressable
            Field {
              id: ipField
              width: formCol.colW
              caption: "IP"
              placeholder: "optional if DNS set"
              text: root.formIp
              onTextChanged: root.formIp = text
            }
            Field {
              id: portField
              width: formCol.colW
              visible: root.formType === "proxy" && root.formCheck === "tcp"
              caption: "Port"
              placeholder: "443"
              text: root.formPort
              onTextChanged: root.formPort = text
            }
          }

          Row {
            spacing: Style.space(8)
            Rectangle {
              implicitWidth: saveLab.implicitWidth + Style.space(20)
              implicitHeight: Style.space(32)
              radius: Style.space(4)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)
              Text {
                id: saveLab
                anchors.centerIn: parent
                text: "Save"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.saveForm() }
            }
            Rectangle {
              implicitWidth: cancelLab.implicitWidth + Style.space(20)
              implicitHeight: Style.space(32)
              radius: Style.space(4)
              color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
              Text {
                id: cancelLab
                anchors.centerIn: parent
                text: "Cancel"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.view = "setup"; root.formConfirmDelete = false; root.formFieldFocused = false }
              }
            }
            Rectangle {
              visible: !root.formIsNew
              implicitWidth: delLab.implicitWidth + Style.space(20)
              implicitHeight: Style.space(32)
              radius: Style.space(4)
              color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, root.formConfirmDelete ? 0.35 : 0.12)
              Text {
                id: delLab
                anchors.centerIn: parent
                text: root.formConfirmDelete ? "Confirm delete" : "Delete"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteFormNode() }
            }
            Item { width: Style.space(8); height: 1 }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Esc back"
              color: root.muted
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
        }
      }
    }
  }
}
