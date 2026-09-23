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
  // Runtime state lives OUTSIDE the plugin tree. The shell watches a local
  // plugin directory and hot-reloads on any change, so writing the snapshot and
  // a heartbeat in there reloaded the plugin roughly once a second. Must match
  // plugin_paths.state_dir().
  // The running version, read from the manifest. Users need to be able to say
  // which build they are on without digging through files.
  property string pluginVersion: ""

  readonly property string stateDir: {
    var xdg = String(Quickshell.env("XDG_STATE_HOME") || "")
    var base = xdg !== "" ? xdg : (String(Quickshell.env("HOME") || "") + "/.local/state")
    return base + "/lanarchy"
  }

  readonly property int refreshIntervalSec: {
    var n = parseInt(String(setting("refreshIntervalSec", 15)), 10)
    if (!isFinite(n)) n = 15
    return Math.max(5, Math.min(120, n))
  }

  // glance | setup | form
  property string view: "glance"
  // Set just before open() to land on a view other than the glance.
  property string pendingView: ""
  // list is the dash; map is the letterbox
  property string glanceTab: "list"
  property var mapEdges: []
  property var mapLayout: []
  property string mapSelectedId: ""
  // Moving to another card cancels a half-pressed Remove, so coming back to a
  // card never finds it still armed from a click you had forgotten about.
  onMapSelectedIdChanged: root.removeArmedId = ""
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
  property var events: []
  property var devices: []
  property var newDevices: []
  property var sparks: ({})
  property var gateway: null
  property var wan: null
  property bool devicesOpen: false
  property bool renaming: false
  // Inline rename, on the card itself.
  property string editingId: ""
  property string editingText: ""
  property var invNames: []
  property bool ignoredOpen: false
  property int ignoredCount: 0
  // What the panel holds right now. ignoredCount comes from the last snapshot
  // and lags a probe behind every change the user just made.
  readonly property var ignoredList: root.invIgnored instanceof Array ? root.invIgnored : []
  property var flaps: ({})
  property var invSettings: ({})
  property var invIgnored: []
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
    // The one structure that is true on every LAN: a machine reaches the
    // internet through the default gateway. Before this, with no reverse proxy
    // configured the hub fell back to "the first machine in the list", so the
    // map asserted that every box routed through whichever machine happened to
    // be first, and drew measured bytes along those invented links.
    var edges = []
    var i, mid, gid
    var gw = root.gateway ? "__gateway__" : ""
    var hub = root.mapHubId()
    var anchor = gw || hub
    if (!anchor) {
      root.mapEdges = []
      return
    }

    for (i = 0; i < root.machines.length; i++) {
      mid = String(root.machines[i].id || "")
      // Never draw a node connected to itself.
      if (!mid || mid === anchor) continue
      if (!root.mapRowVisible(root.machines[i], "machine")) continue
      edges.push({ from: mid, to: anchor, kind: "lan" })
    }

    // A reverse proxy is a service behind the gateway, not the gateway itself.
    if (gw && hub && hub !== gw)
      edges.push({ from: hub, to: gw, kind: "lan" })

    for (i = 0; i < root.groups.length; i++) {
      gid = String(root.groups[i].id || "")
      if (gid === anchor || gid === hub) continue
      if (!root.mapRowVisible(root.groups[i], String(root.groups[i].zone || "") === "external" ? "external" : "service"))
        continue
      var external = String(root.groups[i].zone || "") === "external"
      edges.push({ from: hub || anchor, to: gid, kind: external ? "wan" : "service" })
    }


    // No edge to the internet: it is not a placed node. The arrow off the
    // gateway card says the same thing without spending a card's worth of space.

    root.mapEdges = edges
  }

  function glanceRowById(id) {
    var sid = String(id || "")
    if (sid === "__lan__") return root.lanClusterRow()
    if (sid === "__gateway__") return root.gateway
    if (sid === "__wan__") return root.wan
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
  // What recalcMapLayout says the map needs; the popup follows it.
  property real mapContentHeight: Style.space(460)
  // One clear horizontal lane per row of machines, sitting in the gutter
  // directly BELOW that row. A card's uplink drops into its own row's lane, so
  // it never has to reach past the row beneath it.
  //
  // A single lane under the whole grid could not work once the band wrapped:
  // every card in the top row had to cross the bottom row to reach it, and
  // dodging through the 8px gaps between columns put the wire on the card
  // borders, which is what "traffic running through the cards" looked like.
  property var mapRowLanes: []
  // The vertical trunk every row lane empties into, in a corridor reserved to
  // the right of the grid and left of the gateway. Nothing is ever drawn there,
  // so the trunk crosses nothing.
  property real mapTrunkX: 0
  // Bottom-most lane, which is what the panel height has to cover.
  property real mapGutterY: 0
  property real mapEgressY: 0
  // The gateway's placed geometry, so the internet arrow can hang off it.
  readonly property var gatewayBox: {
    for (var i = 0; i < root.mapLayout.length; i++)
      if (String(root.mapLayout[i].id) === "__gateway__") return root.mapLayout[i]
    return null
  }
  // Same height as a machine card. The gateway and the internet are two more
  // nodes in the chain, not a special exhibit that needs its own proportions.
  readonly property real mapEgressH: root.mapCardH
  property real mapSplitX: 0
  property real mapBarWidth: 0
  property bool mapHasExternal: false

  // Only flag unusually slow peers — normal LAN RTT (3–15ms) must not recolour cards.
  function rttHot(row) {
    if (!row || String(row.status) !== "up") return false
    var n = Number(row.rtt_ms)
    return isFinite(n) && n > 50
  }

  // Traffic flow, from measured throughput only.
  //
  // A node reports `rates` (rx_bps / tx_bps) when telemetry could read its
  // counters: /proc/net/dev locally, or over SSH with BatchMode. Everything
  // the map animates is derived from those numbers. When neither endpoint
  // reported, the edge has NO measurement, and the map says so by not moving
  // rather than by inventing a pace.
  function edgeFlow(rowA, rowB) {
    function rates(row) {
      if (!row || !row.rates) return null
      var rx = Number(row.rates.rx_bps)
      var tx = Number(row.rates.tx_bps)
      if (!isFinite(rx) && !isFinite(tx)) return null
      return { rx: isFinite(rx) ? Math.max(0, rx) : 0, tx: isFinite(tx) ? Math.max(0, tx) : 0 }
    }
    var a = rates(rowA)
    var b = rates(rowB)
    if (!a && !b) return { rx: 0, tx: 0, bps: 0, measured: false }
    // Take the busier endpoint's view of the link.
    var rx = Math.max(a ? a.rx : 0, b ? b.rx : 0)
    var tx = Math.max(a ? a.tx : 0, b ? b.tx : 0)
    return { rx: rx, tx: tx, bps: Math.max(rx, tx), measured: true }
  }

  function edgeFlowBps(rowA, rowB) {
    return root.edgeFlow(rowA, rowB).bps
  }

  // Packets in flight on one direction of a link, straight off the byte rate.
  // Zero below 1 kB/s: a measured-but-idle link should look idle.
  function flowPacketCount(bps) {
    var v = Number(bps) || 0
    if (v < 1000) return 0
    var decades = Math.log(v / 1000) / Math.LN10
    return Math.max(1, Math.min(6, 1 + Math.round(decades * 1.8)))
  }

  // Pixels per second for a packet. Monotonic in the real rate, log-scaled so a
  // 1 kB/s trickle and a 100 MB/s transfer are both legible on the same map.
  function flowSpeedPxPerSec(bps) {
    var v = Number(bps) || 0
    if (v < 1000) return 0
    // Speed is the channel the eye reads best, so it carries most of the range:
    // ~1 kB/s crawls, ~100 kB/s is a brisk stream, ~10 MB/s is a rush.
    var t = Math.min(1, (Math.log(1 + v / 1000) / Math.LN10) / 3.5)
    return 12 + 188 * t
  }

  function edgeFlowWidth(bps) {
    var v = Number(bps) || 0
    if (v < 800) return 1.8
    if (v < 80000) return 1.8 + (v / 80000) * 2.4
    return Math.min(5.2, 4.2 + Math.log(v / 80000) / Math.log(25))
  }

  // No dash march, no pulse, no idle shimmer. There was a set of helpers here
  // that made an unmeasured link crawl at a tenth pace, which is motion with no
  // measurement behind it. Nothing called them any more and the comment still
  // promised the behaviour, so both are gone: the only thing that moves on this
  // map is a packet standing for bytes someone counted.

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

  // Every drawable edge, resolved once per layout change: geometry, colour, the
  // width its real link rate earns, and how fast packets should walk it. The
  // canvas and the packet Repeater both read this, so neither recomputes routes
  // per frame.
  readonly property var mapEdgeRoutes: {
    var out = []
    var boxes = ({})
    var i
    for (i = 0; i < root.mapLayout.length; i++) {
      var b = root.mapLayout[i]
      boxes[b.id] = { x: b.x, y: b.y, w: b.w, h: b.h }
    }
    var barMidX = root.mapHasExternal ? (root.mapSplitX + root.mapBarWidth / 2) : 0

    for (i = 0; i < root.mapEdges.length; i++) {
      var e = root.mapEdges[i]
      var aBox = boxes[String(e.from || "")]
      var bBox = boxes[String(e.to || "")]
      if (!aBox || !bBox) continue
      var rowA = root.glanceRowById(e.from)
      var rowB = root.glanceRowById(e.to)
      // The gateway-to-internet link has no counters behind it. Drawing packets
      // there would be inventing throughput, so the edge stays still.
      var internetLink = String(e.to || "") === "__wan__" || String(e.from || "") === "__wan__"
      var flow = internetLink
          ? ({ rx: 0, tx: 0, bps: 0, measured: false })
          : root.edgeFlow(rowA, rowB)
      var kind = String(e.kind || "")
      var pts = null
      if (kind === "lan" && root.machineById(String(e.from || "")))
        pts = root.machineUplinkPoints(aBox, bBox)
      if (!pts) pts = root.mapEdgePoints(aBox, bBox, barMidX, kind)
      var len = root.polylineLength(pts)
      if (!(len > 0)) continue
      // A dead endpoint should not look like it is carrying traffic.
      var down = String((rowA && rowA.status) || "") === "down"
          || String((rowB && rowB.status) || "") === "down"
      out.push({
        points: pts,
        length: len,
        kind: kind,
        internetLink: internetLink,
        // Endpoints, so selecting a card can pick out its own route. The row
        // lane is a shared bus: without this, five hosts' wires overlay into
        // one line and there is no way to see whose traffic is whose.
        fromId: String(e.from || ""),
        toId: String(e.to || ""),
        width: internetLink ? Style.space(10) : root.edgeFlowWidth(flow.bps),
        down: down,
        // Measured throughput, both directions. rx walks the route forwards,
        // tx walks it back, so the picture shows which way the bytes go.
        measured: flow.measured,
        rxBps: flow.rx,
        txBps: flow.tx,
        // Measured bytes are shown even when an endpoint's service check is
        // down: a failing health URL does not mean the wire is idle. `down`
        // only dims the lane.
        rxPackets: root.flowPacketCount(flow.rx),
        txPackets: root.flowPacketCount(flow.tx),
        rxSpeed: root.flowSpeedPxPerSec(flow.rx),
        txSpeed: root.flowSpeedPxPerSec(flow.tx),
        color: String(down ? root.urgent : (kind === "wan" ? Color.accent : root.themeGreen)),
        // Stagger so parallel routes do not march in lockstep.
        stagger: ((i * 17) + String(e.from || "").length * 3 + String(e.to || "").length * 5) % 97
      })
    }
    return out
  }

  // Is this route the selected card's own? Nothing selected means every
  // measured route is its own subject, which is the default view.
  function routeIsSelected(route) {
    var sel = String(root.mapSelectedId || "")
    if (!sel) return true
    return String(route.fromId || "") === sel || String(route.toId || "") === sel
  }

  // The lane for the row a card sits in: the first lane below its bottom edge.
  function mapLaneBelow(box) {
    var bottom = box.y + box.h
    var best = -1
    for (var i = 0; i < root.mapRowLanes.length; i++) {
      var ly = Number(root.mapRowLanes[i])
      if (ly > bottom + 1 && (best < 0 || ly < best)) best = ly
    }
    return best
  }

  // Orthogonal route between two cards as a point list. Canvas strokes it and the
  // travelling packets walk it, so both read the same geometry from one place.
  //
  // Four segments, and every one of them runs in space nothing is drawn in:
  //
  //   1. straight down out of the card into its OWN row's gutter lane
  //   2. right along that lane, between two rows of cards
  //   3. down the trunk, in the reserved corridor right of the grid
  //   4. right into the gateway's left face, at the gateway's midline
  //
  // The previous route ran every card down to one lane beneath the whole grid,
  // so a top-row card had to get past the bottom row, and the only way through
  // was the 8px gap between two columns. That is what put wires on the cards.
  function machineUplinkPoints(aBox, bBox) {
    var aBottom = aBox.y + aBox.h
    var laneY = root.mapLaneBelow(aBox)
    if (!(laneY > aBottom + 2)) return null

    var aCx = aBox.x + aBox.w / 2
    var trunkX = root.mapTrunkX
    var enterY = bBox.y + bBox.h / 2
    var enterX = bBox.x

    // The trunk must genuinely be clear of both the card and the gateway, or
    // there is no corridor and the honest answer is to draw nothing.
    if (!(trunkX > aBox.x + aBox.w) || !(trunkX < bBox.x)) return null

    return [
      { x: aCx,    y: aBottom },
      { x: aCx,    y: laneY   },
      { x: trunkX, y: laneY   },
      { x: trunkX, y: enterY  },
      { x: enterX, y: enterY  }
    ]
  }

  function machineById(id) {
    for (var i = 0; i < root.machines.length; i++)
      if (String(root.machines[i].id || "") === String(id)) return root.machines[i]
    return null
  }

  function mapEdgePoints(aBox, bBox, barMidX, kind) {
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

    var pts = [{ x: a0.x, y: a0.y }, { x: a1.x, y: a1.y }]

    if (Math.abs(a1.x - b1.x) < 1.5 || Math.abs(a1.y - b1.y) < 1.5) {
      pts.push({ x: b1.x, y: b1.y })
    } else if (kind === "wan" && barMidX) {
      pts.push({ x: barMidX, y: a1.y })
      pts.push({ x: barMidX, y: b1.y })
      pts.push({ x: b1.x, y: b1.y })
    } else if (aAbove || bAbove) {
      // Horizontal run strictly in the gap between the two cards.
      var gapLo = aAbove ? aBot : bBot
      var gapHi = aAbove ? bBox.y : aBox.y
      var midY = (gapLo + gapHi) / 2
      pts.push({ x: a1.x, y: midY })
      pts.push({ x: b1.x, y: midY })
      pts.push({ x: b1.x, y: b1.y })
    } else {
      var gapL = aCx <= bCx ? (aBox.x + aBox.w) : (bBox.x + bBox.w)
      var gapR = aCx <= bCx ? bBox.x : aBox.x
      var midX = (gapL + gapR) / 2
      pts.push({ x: midX, y: a1.y })
      pts.push({ x: midX, y: b1.y })
      pts.push({ x: b1.x, y: b1.y })
    }
    // Terminate on the border, never continue to the box centre.
    pts.push({ x: b0.x, y: b0.y })
    return pts
  }

  function strokeMapEdge(ctx, aBox, bBox, barMidX, kind) {
    var pts = root.mapEdgePoints(aBox, bBox, barMidX, kind)
    ctx.moveTo(pts[0].x, pts[0].y)
    for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y)
  }

  // Total run length of a polyline, and the point a given distance along it.
  function polylineLength(pts) {
    var total = 0
    for (var i = 1; i < pts.length; i++) {
      var dx = pts[i].x - pts[i - 1].x
      var dy = pts[i].y - pts[i - 1].y
      total += Math.sqrt(dx * dx + dy * dy)
    }
    return total
  }

  function polylinePointAt(pts, dist) {
    if (!pts || pts.length === 0) return { x: 0, y: 0 }
    if (pts.length === 1) return { x: pts[0].x, y: pts[0].y }
    var d = dist
    for (var i = 1; i < pts.length; i++) {
      var dx = pts[i].x - pts[i - 1].x
      var dy = pts[i].y - pts[i - 1].y
      var seg = Math.sqrt(dx * dx + dy * dy)
      if (seg <= 0) continue
      if (d <= seg) {
        var t = d / seg
        return { x: pts[i - 1].x + dx * t, y: pts[i - 1].y + dy * t }
      }
      d -= seg
    }
    return { x: pts[pts.length - 1].x, y: pts[pts.length - 1].y }
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
    var measured = false
    var i, m
    var router = root.routerMachine()
    var routerId = router ? String(router.id || "") : ""
    for (i = 0; i < root.machines.length; i++) {
      m = root.machines[i]
      if (String(m.id || "") === routerId) continue
      if (!m.rates) continue
      if (m.rates.rx_bps != null) rx += Number(m.rates.rx_bps) || 0
      if (m.rates.tx_bps != null) tx += Number(m.rates.tx_bps) || 0
      measured = true
    }
    return { rx_bps: rx, tx_bps: tx, measured: measured }
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

    // A discovered card has no inventory node to flag, so the loop below
    // matched nothing and wrote the same list straight back: the button did
    // nothing at all, then jumped to the List tab, which made it look as though
    // it had. Hiding one means telling discovery to stop offering it.
    if (!root.invNodeById(id) && !root.mapHiddenForId(id)) {
      var drow = root.glanceRowById(id)
      if (drow && (drow.mac || drow.ip)) {
        root.ignoreDevice(drow)
        if (root.mapSelectedId === id) root.mapSelectedId = ""
        return
      }
    }

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
    // Overrides ride along on every write. The CLI also preserves them when
    // absent, but sending what the panel currently holds keeps the file and the
    // UI from drifting apart.
    return {
      schemaVersion: 2,
      nodes: nodes,
      settings: settings && typeof settings === "object" ? settings : {},
      ignored: root.invIgnored instanceof Array ? root.invIgnored : [],
      names: root.invNames instanceof Array ? root.invNames : []
    }
  }

  // Writes are serialised. One Process was reused with no queue, and changing a
  // running Process's command applies to its NEXT run, so a second click while
  // a write was in flight updated the UI and never reached disk.
  property var pendingWrite: null

  function runInventoryWrite(payloadObj) {
    // A write already in flight: remember the latest intent and send it when the
    // current one finishes. Only the newest matters, since each payload is the
    // whole inventory rather than a delta.
    if (invWriteProc.running) {
      root.pendingWrite = payloadObj
      return true
    }
    root.sendInventoryWrite(payloadObj)
    return true
  }

  function sendInventoryWrite(payloadObj) {
    invWriteProc.payload = JSON.stringify(payloadObj)
    invWriteProc.command = ["python3", root.pluginDir + "/inventory_cli.py", "write", "-"]
    invWriteProc.stdinEnabled = true
    invWriteProc.running = true
  }

  function drainPendingWrite() {
    if (!root.pendingWrite) return false
    var next = root.pendingWrite
    root.pendingWrite = null
    root.sendInventoryWrite(next)
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

  function agoText(iso) {
    var then = Date.parse(String(iso || ""))
    if (!isFinite(then)) return ""
    var secs = Math.max(0, Math.floor((Date.now() - then) / 1000))
    if (secs < 60) return secs + "s"
    if (secs < 3600) return Math.floor(secs / 60) + "m"
    if (secs < 86400) return Math.floor(secs / 3600) + "h"
    return Math.floor(secs / 86400) + "d"
  }

  function nodeLabelById(id) {
    var row = root.glanceRowById(id)
    if (row && row.label) return String(row.label)
    for (var i = 0; i < root.nodes.length; i++)
      if (String(root.nodes[i].id) === String(id)) return String(root.nodes[i].label || id)
    return String(id)
  }

  // A box that bounces is not the same as a box that is down, and the events
  // ring already knew. Anything above this in an hour is unstable, not unlucky.
  readonly property int flapThreshold: 4

  readonly property var flapping: {
    var out = []
    for (var id in root.flaps)
      if (Number(root.flaps[id]) >= root.flapThreshold)
        out.push({ id: id, count: Number(root.flaps[id]) })
    out.sort(function (a, b) { return b.count - a.count })
    return out
  }

  function osSubline(row) {
    // "MACHINE" on a card of machines says nothing, so an unknown OS now says
    // nothing either and the row falls back to how the box is connected. A
    // header is for facts; padding the slot with the word for "thing" is worse
    // than leaving it empty.
    var os = row && row.os ? row.os : null
    var label = os ? String(os.label || "") : ""
    if (label && os && String(os.confidence || "") === "guess") label += "?"
    var link = root.linkKindText(row)
    if (!label) return link || ""
    return link ? (label + " · " + link) : label
  }

  // Wired or wireless, stated only when it is actually known. Link details come
  // from the telemetry hop, so a box we cannot reach says nothing rather than
  // guessing. UniFi reports this for every client once a key is configured.
  function linkKindText(row) {
    var link = row && row.link ? row.link : null
    if (!link) return ""
    var kind = String(link.kind || "")
    if (kind === "wifi") return "wifi"
    if (kind === "eth") return "wired"
    return ""
  }

  function osDetail(row) {
    var os = row && row.os ? row.os : null
    if (!os || String(os.family || "unknown") === "unknown") return ""
    var out = String(os.label || "")
    if (os.release) out += " " + String(os.release)
    var src = String(os.source || "")
    if (src && src !== "inventory") out += " (via " + src + ")"
    return out
  }

  function gatewaySubline() {
    // Just the role. The model went here too and overflowed a narrow card; it
    // belongs on the metric line where there is room for it.
    return "gateway"
  }

  function gatewayMetric() {
    if (!root.gateway) return ""
    var parts = []
    if (root.gateway.model) parts.push(String(root.gateway.model))
    if (root.gateway.ip) parts.push(String(root.gateway.ip))
    var t = root.rttText(root.gateway)
    if (t !== "—") parts.push(t)
    return parts.join(" · ")
  }

  // What the monitored hosts are pushing. Deliberately NOT called WAN: it counts
  // traffic that never leaves the LAN and misses every host without telemetry.
  // Nothing here can read the gateway's WAN interface.
  // The LAN measurements the bucket used to carry. Real numbers, shown with the
  // other real numbers instead of inside a pretend map node.
  function lanMetricsText() {
    var m = root.lanMeta
    if (!m || typeof m !== "object") return ""
    var parts = []
    var dns = Number(m.dns_ms)
    if (isFinite(dns)) parts.push("dns " + Math.round(dns) + "ms")
    var n = Number(m.neighbors)
    if (isFinite(n) && n > 0) parts.push(n + " neighbours")
    return parts.join(" · ")
  }

  function monitoredHostsText() {
    var m = root.wan && root.wan.monitored_hosts ? root.wan.monitored_hosts : null
    if (!m || !m.measured) return ""
    var d = root.fmtRate(m.rx_bps)
    var u = root.fmtRate(m.tx_bps)
    if (!d && !u) return ""
    return "↓" + (d || "0") + " ↑" + (u || "0") + " · " + m.hosts + " host"
        + (m.hosts === 1 ? "" : "s")
  }

  function wanMetric() {
    if (!root.wan) return ""
    var parts = []
    var t = root.rttText(root.wan)
    if (t !== "—") parts.push(t)
    if (root.wan.public_ip) parts.push(String(root.wan.public_ip))
    return parts.join(" · ")
  }

  function recalcMapLayout() {
    if (!mapArea || mapArea.width <= 0) return
    var w = mapArea.width
    var layout = []
    // Cards fill the row they are given. A fixed 108 left a third of the map
    // empty with seven machines on a 1920 screen, and the grid hugged the
    // top-left corner of a mostly blank area.
    var cardW = Style.space(150)
    var cardH = root.mapCardH
    var externals = root.externalGroups()
    var router = root.routerMachine()
    var hub = root.hubGroup()
    // The internet is always out there, so the external rail always exists.
    root.mapHasExternal = externals.length > 0 || root.wan !== null

    // Reserve a compact exit assembly; extra width belongs to the LAN grid.
    // Width goes to the machines. The old split reserved a 23% router band and
    // a 34% external rail, so more than half the map was held for a zone
    // divider that no longer exists and an internet card that is now an arrow.
    // Only what the gateway card and the exit label actually occupy is kept.
    var gatewayW = root.gateway || root.mapHasExternal ? Style.space(190) : 0
    var exitW = root.wan ? Style.space(166) : 0
    var externalW = externals.length
        ? Math.min(Style.space(200), Math.max(Style.space(140), w * 0.16)) : 0

    var barW = gatewayW
    var rightW = exitW + externalW
    var leftW = Math.max(Style.space(260), w - barW - rightW - Style.space(18))
    var barX = leftW + Style.space(10)
    // A corridor the grid is not allowed to use, so the trunk that collects
    // every row lane has somewhere to run without touching a card.
    var trunkGutter = Style.space(30)
    var gridW = Math.max(Style.space(200), leftW - trunkGutter)
    root.mapTrunkX = gridW + trunkGutter / 2
    root.mapSplitX = barX
    root.mapBarWidth = barW

    function place(row, subline, x, y, wCard, hCard, kind, metric, lights) {
      layout.push({
        id: String(row.id || ""),
        label: String(row.label || row.id || ""),
        subline: typeof subline === "function" ? subline(row) : subline,
        status: root.displayStatus(row),
        rtt_ms: row.rtt_ms,
        rates: row.rates || null,
        os: row.os || null,
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
    // Wrap instead of cram. The old maths spaced n cards evenly across the band
    // and then refused to shrink a card below a readable width, so past roughly
    // six machines every card overlapped its neighbour. Capacity now comes from
    // the available width, and the band grows downwards, which is what the
    // panel is sized from.
    function colBand(rows, subline, y, kind, metricFn, lightsFn, colX, colW) {
      var n = rows.length
      if (n <= 0) return y
      var minW = Style.space(88)
      var gapX = Style.space(8)
      // Machine rows need a gutter wide enough to hold a lane with clearance on
      // both sides. At 10 the lane was pressed against the cards above and
      // below it, which is why routing that was technically outside the cards
      // still read as running through them.
      var gapY = kind === "machine" ? Style.space(30) : Style.space(10)
      var perRow = Math.max(1, Math.floor((colW + gapX) / (minW + gapX)))
      var rowsUsed = Math.ceil(n / perRow)
      // Spread the cards evenly rather than leaving a ragged last row.
      var columns = Math.max(1, Math.ceil(n / rowsUsed))
      // Widen to consume the row, up to a readable maximum, then centre what is
      // left over. Cards used to stay narrow and leave the remainder blank.
      var cw = Math.max(minW, Math.min(cardW, (colW - gapX * (columns - 1)) / columns))
      var spanW = cw * columns + gapX * (columns - 1)
      var startX = colX + Math.max(0, (colW - spanW) / 2)
      if (kind === "machine") {
        // One lane per row, centred in the gutter under that row. The last row
        // gets a lane too: there is nothing below it to cross.
        var lanes = []
        for (var r2 = 0; r2 < rowsUsed; r2++)
          lanes.push(y + (r2 + 1) * cardH + r2 * gapY + gapY / 2)
        root.mapRowLanes = lanes
      }
      var i, row, r, c
      for (i = 0; i < n; i++) {
        row = rows[i]
        r = Math.floor(i / columns)
        c = i % columns
        place(row, subline, startX + c * (cw + gapX), y + r * (cardH + gapY),
              cw, cardH, kind,
              metricFn ? metricFn(row) : root.rttText(row),
              lightsFn ? lightsFn(row) : [])
      }
      return y + rowsUsed * cardH + (rowsUsed - 1) * gapY
    }

    var machines = root.internalMachines(router)
    // gridW, not leftW: the trunk corridor is not the grid's to fill.
    var machineBandBottom = colBand(machines, root.osSubline, Style.space(28), "machine",
                                    root.machineMetric, null, 0, gridW)
    // The bottom-most lane is what the panel height has to cover; the lanes
    // above it sit in gutters the cards already account for.
    root.mapGutterY = root.mapRowLanes.length
        ? Number(root.mapRowLanes[root.mapRowLanes.length - 1])
        : machineBandBottom

    // The gateway sits on the grid, centred against the machines it serves.
    // It used to be positioned to meet the collection lane, which pushed it
    // off-centre relative to every other card: the cards were being bent to fit
    // the wiring. The wiring bends instead.
    var gridTop = Style.space(28)
    root.mapEgressY = Math.max(gridTop,
        gridTop + (machineBandBottom - gridTop - root.mapEgressH) / 2)

    // Prefer the real default gateway on the router boundary.
    // Never place the same hub id twice (left gateway + bar).
    var hubOnRouterBar = false
    if (root.mapHasExternal) {
      var rw = Math.max(Style.space(150), barW - Style.space(6))
      var rh = root.mapEgressH
      var ry = root.mapEgressY
      if (root.gateway) {
        // The real next hop, not a machine standing in for one.
        place(root.gateway, root.gatewaySubline(), barX + (barW - rw) / 2, ry, rw, rh,
              "router", [root.gateway.model || "", root.gateway.ip || "",
                         "RTT  " + root.rttText(root.gateway)].filter(function(v) { return v !== "" }).join("\n"), [])
      } else if (router) {
        place(router, "router", barX + (barW - rw) / 2, ry, rw, rh, "router",
              root.routerMetric(router), [])
      } else if (hub) {
        place(hub, "router", barX + (barW - rw) / 2, ry, rw, rh, "router",
              root.serviceMetric(hub), root.serviceLights(hub))
        hubOnRouterBar = true
      }
    }

    // Everything below the machines flows from wherever that band actually
    // ended, so a wrapped row pushes the rest down instead of being drawn over.
    var cursorY = machineBandBottom + Style.space(26)

    if (hub && !hubOnRouterBar && String(hub.zone || "") !== "external") {
      var hubW = Style.space(120)
      var hubH = Style.space(100)
      place(hub, "reverse proxy", (leftW - hubW) / 2, cursorY, hubW, hubH, "hub",
            root.serviceMetric(hub), root.serviceLights(hub))
      cursorY += hubH + Style.space(26)
    }

    var svcs = root.internalGroups(hub)
    if (svcs.length) {
      cursorY = colBand(svcs, "service", cursorY, "service", root.serviceMetric,
                        root.serviceLights, 0, leftW) + Style.space(26)
    }

    // No LAN bucket card. It aggregated leftover `host` rows and LAN metrics
    // into a fake node on the topology, which is neither a device nor a link.
    // The Devices drawer does the aggregation as a list you can act on, and the
    // LAN metrics belong in the footer with the other measurements.

    // The internet is not a box on your network and does not get a card. It is
    // an arrow leaving the gateway, drawn in the margin, costing no layout.

    if (externals.length) {
      var railX = barX + barW + Style.space(6)
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
    // The panel is sized from this: the map asks for the height it needs and
    // the popup grows to fit, rather than clipping content into a fixed box.
    var lowest = 0
    for (var li = 0; li < layout.length; li++)
      lowest = Math.max(lowest, layout[li].y + layout[li].h)
    // Exactly what the content needs. The old 300 floor was reserving room for
    // a LAN bucket that no longer exists, which is where the dead space came
    // from.
    // The bottom row's lane sits BELOW the lowest card, so height taken from
    // cards alone clipped it off the edge along with the drops feeding it.
    root.mapContentHeight = Math.max(lowest, root.mapGutterY) + Style.space(16)

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
    // The network fills the map. A discovered box you have never curated still
    // gets a card; the inventory only records the overrides you made.
    if (data.auto instanceof Array && data.auto.length > 0) {
      root.machines = root.machines.concat(data.auto)
    }
    root.lan = data.lan instanceof Array ? data.lan : []
    root.proxies = data.proxies instanceof Array ? data.proxies : []
    root.groups = data.groups instanceof Array ? data.groups : []
    root.quietLan = data.quiet_lan instanceof Array ? data.quiet_lan : []
    root.quietProxies = data.quiet_proxies instanceof Array ? data.quiet_proxies : []
    root.lanMeta = data.lan_meta && typeof data.lan_meta === "object" ? data.lan_meta : {}
    root.unifi = data.unifi && typeof data.unifi === "object" ? data.unifi : {}
    root.discover = data.discover instanceof Array ? data.discover : []
    root.devices = data.devices instanceof Array ? data.devices : []
    root.newDevices = data.new_devices instanceof Array ? data.new_devices : []
    root.sparks = data.sparks && typeof data.sparks === "object" ? data.sparks : ({})
    root.gateway = data.gateway && typeof data.gateway === "object" ? data.gateway : null
    root.wan = data.wan && typeof data.wan === "object" ? data.wan : null
    root.ignoredCount = Number(data.ignored_count) || 0
    root.events = data.events instanceof Array ? data.events : []
    root.flaps = data.flaps && typeof data.flaps === "object" ? data.flaps : ({})
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
    root.glanceTab = "map"
    root.formConfirmDelete = false
    root.formFieldFocused = false
    root.cancelInlineEdit()
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
    // root.nowMs, not Date.now(): a binding needs something that changes, or a
    // stopped collector keeps reading as fresh forever.
    return Math.max(0, (root.nowMs - t) / 1000)
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
    var h = root.labHealth
    if (h.total === 0) return "NO DATA"
    // Say what is actually true. "ALL CLEAR" used to appear whenever nothing was
    // explicitly down, so degraded and unknown nodes were silently clear.
    var parts = []
    if (h.down > 0) parts.push(h.down + " DOWN")
    if (h.degraded > 0) parts.push(h.degraded + " DEGRADED")
    if (h.unknown > 0) parts.push(h.unknown + " UNKNOWN")
    if (parts.length === 0) return "LIVE · ALL CLEAR"
    return "LIVE · " + parts.join(" · ")
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
    // An edit in progress is the innermost thing on screen; Esc belongs to it
    // before it belongs to the view.
    if (root.editingId !== "") {
      root.cancelInlineEdit()
      return
    }
    if (root.renaming) {
      root.renaming = false
      return
    }
    if (root.view === "barmenu") {
      root.view = "glance"
      return
    }
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
    root.invIgnored = data.ignored instanceof Array ? data.ignored : []
    root.invNames = data.names instanceof Array ? data.names : []
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
    // Anchor the name to the hardware as well as the node, so it keeps working
    // if the box changes address, and so it shows up on every surface.
    root.rememberName(node, String(root.formLabel || "").trim())
    writeNodes(next)
  }

  function deleteFormNode() {
    if (!root.formConfirmDelete) {
      root.formConfirmDelete = true
      return
    }
    // The node being edited is about to stop existing, so the form it is being
    // edited in has to go with it.
    root.view = "setup"
    var next = []
    var i
    for (i = 0; i < root.nodes.length; i++) {
      if (String(root.nodes[i].id) !== String(root.formId)) next.push(root.nodes[i])
    }
    writeNodes(next)
  }

  // Remove whatever card you are looking at, whichever kind it is. Getting a
  // box off the map used to mean Setup, find it in the list, open it, Delete,
  // Confirm delete; and that path did not exist at all for a discovered box,
  // which had to be hunted down in the Devices drawer instead.
  //
  // The two kinds are genuinely different and both are handled here so the
  // caller does not have to know which it has: a curated node stops existing,
  // a discovered one goes on the ignored list so discovery stops re-adding it
  // on the next sweep. Restoring either is `lanarchy restore <mac>` or the
  // ignored list in Setup.
  // Which card has had Remove pressed once. Removing is destructive, so it asks
  // again; tracking the id rather than a flag means selecting a different card
  // disarms it instead of arming the new one.
  property string removeArmedId: ""

  function removeCardById(sid) {
    var id = String(sid || "")
    if (!id || id === "__lan__" || id === "__gateway__" || id === "__wan__") return false

    var inv = root.invNodeById(id)
    if (inv) {
      var next = []
      for (var i = 0; i < root.nodes.length; i++)
        if (String(root.nodes[i].id) !== id) next.push(root.nodes[i])
      root.writeNodes(next)
      if (root.mapSelectedId === id) root.mapSelectedId = ""
      return true
    }

    // Discovered: needs the row, because the ignored list is keyed by hardware.
    var row = root.glanceRowById(id)
    if (!row || (!row.mac && !row.ip)) return false
    root.ignoreDevice(row)
    if (root.mapSelectedId === id) root.mapSelectedId = ""
    return true
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
    // Adding something is a deliberate act: you want to see it. `host` exists to
    // collapse reverse-proxy names into the LAN bucket, not to hide a device you
    // just asked for. Anything you add by hand gets its own card.
    var isMachine = String(c.type || "") === "machine" || c.addedByHand === true
    var node = {
      type: isMachine ? "machine" : "host",
      label: label,
      ip: c.ip ? String(c.ip) : null
    }
    if (c.mac) node.mac = String(c.mac)
    // Keep the mDNS service list: it is the only evidence that separates a Mac
    // from a Linux box when TTL cannot (both answer 64), and os_lib reads it.
    if (c.services instanceof Array && c.services.length > 0) {
      node.services = c.services.slice(0, 12)
    }
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

  function discoverCount(onlyMachines) {
    var n = 0
    for (var i = 0; i < root.discover.length; i++) {
      var c = root.discover[i]
      if (onlyMachines && String(c.type || "") !== "machine") continue
      if (root.inventoryHasDevice(c)) continue
      if (root.discoveredNode(c)) n++
    }
    return n
  }

  function addAllDiscovered(onlyMachines) {
    // Bulk add in ONE inventory write. discoveredNode() only checks ids already
    // on disk, so batch-local collisions are resolved here.
    var next = root.nodes.slice()
    var taken = ({})
    var i
    for (i = 0; i < next.length; i++) taken[String(next[i].id)] = true

    var added = 0
    for (i = 0; i < root.discover.length; i++) {
      var c = root.discover[i]
      if (onlyMachines && String(c.type || "") !== "machine") continue
      if (root.inventoryHasDevice(c)) continue
      var node = root.discoveredNode(c)
      if (!node) continue
      var base = String(node.id)
      var id = base
      if (taken[id]) {
        var tail = String(c.ip || c.mac || "").split(/[.:]/).pop()
        id = tail ? (base + "-" + tail) : base
        var n = 2
        while (taken[id]) {
          id = base + "-" + n
          n++
        }
      }
      node.id = id
      taken[id] = true
      next.push(node)
      added++
    }

    if (added === 0) {
      root.inventoryError = "Nothing new to add"
      return
    }
    root.findHostsHint = "Added " + added + (onlyMachines ? " machine" : " host") + (added === 1 ? "" : "s")
    root.returnToMap()
    root.writeNodes(next)
  }

  // Removing a device is an override, not a deletion: it is remembered against
  // the hardware, so it stays gone when its address changes, and it can be
  // brought back from "show ignored".
  // Your name for a box, kept against the hardware so it survives a DHCP move.
  // Works for a discovered machine you never curated, which otherwise had no
  // way to be called anything but its address.
  // A name belongs to a MAC. An address is a lease; naming by address means the
  // name follows whatever answers there next.
  function nameKeyFor(row) {
    if (!row) return ""
    var mac = String(row.mac || "").toLowerCase().replace(/-/g, ":")
    if (mac.length === 17) return "mac:" + mac
    var ip = String(row.ip || "")
    return ip ? "ip:" + ip : ""
  }

  function rememberName(row, label) {
    var key = root.nameKeyFor(row)
    if (!key || !label) return
    var entry = ({ label: label })
    if (key.indexOf("mac:") === 0) entry.mac = key.substring(4)
    else entry.ip = key.substring(3)

    var names = (root.invNames instanceof Array ? root.invNames.slice() : [])
    var replaced = false
    for (var i = 0; i < names.length; i++) {
      if (root.nameKeyFor(names[i]) === key) {
        names[i] = entry
        replaced = true
        break
      }
    }
    if (!replaced) names.push(entry)
    root.invNames = names
  }

  function beginInlineEdit(nodeId, current) {
    if (!nodeId || nodeId === "__lan__") return
    root.mapSelectedId = nodeId
    root.editingText = String(current || "")
    root.editingId = String(nodeId)
  }

  function cancelInlineEdit() {
    root.editingId = ""
    root.editingText = ""
  }

  function commitInlineEdit() {
    var id = root.editingId
    var label = String(root.editingText || "").trim()
    root.editingId = ""
    if (!id || !label) return
    var row = root.glanceRowById(id)
    if (!row) return
    if (String(row.label || "") === label) return
    root.renameRow(row, label)
  }

  function renameRow(row, newLabel) {
    var label = String(newLabel || "").trim()
    if (!row || !label) {
      root.renaming = false
      return
    }
    var sid = String(row.id || "")

    // A curated node owns its own label; edit it in place.
    if (sid.indexOf("auto:") !== 0) {
      var next = []
      for (var i = 0; i < root.nodes.length; i++) {
        var n = root.nodes[i]
        if (String(n.id) === sid) {
          var copy = ({})
          for (var k in n) copy[k] = n[k]
          copy.label = label
          next.push(copy)
        } else next.push(n)
      }
      root.renaming = false
      root.writeNodes(next)
      return
    }

    if (!root.nameKeyFor(row)) {
      root.inventoryError = "No MAC or address to anchor a name to"
      root.renaming = false
      return
    }
    root.rememberName(row, label)
    root.renaming = false
    root.writeInventoryWithOverrides(root.invIgnored, root.invNames)
  }

  // Overrides only. Deliberately sends NO nodes: the panel's copy can be older
  // than the file (a node added from another view, or by another instance), and
  // resending it would delete whatever it does not know about.
  function writeInventoryWithOverrides(ignored, names) {
    if (!root.inventoryReady || root.inventoryLoading) return
    root.runInventoryWrite({
      schemaVersion: 2,
      settings: root.invSettings && typeof root.invSettings === "object" ? root.invSettings : {},
      ignored: ignored || [],
      names: names || []
    })
  }

  // Adopting an arrival puts it in the inventory, which is also what stops it
  // being announced: the ledger treats anything curated as dealt with.
  function adoptNewDevice(row) {
    if (!row) return
    // It is about to become an inventory node; it should stop being an arrival
    // the moment you say so, not one probe later.
    root.forgetRowLocally(row.mac, row.ip)
    root.addDiscovered({
      type: "machine",
      label: String(row.label || row.mac || "device"),
      ip: row.ip ? String(row.ip) : null,
      mac: row.mac ? String(row.mac) : null,
      host: null,
      source: "new"
    })
  }

  // Find any row the panel currently knows about by hardware address.
  // Rename a device straight from the drawer, without hunting for its card.
  function beginDeviceRename(row) {
    if (!row || !row.mac) return
    root.editingId = "dev:" + String(row.mac).toLowerCase()
    root.editingText = String(row.label || "")
  }

  function commitDeviceRename() {
    var id = root.editingId
    if (id.indexOf("dev:") !== 0) return
    var mac = id.substring(4)
    var label = String(root.editingText || "").trim()
    root.editingId = ""
    if (!label) return
    root.rememberName({ mac: mac }, label)
    root.writeInventoryWithOverrides(root.invIgnored, root.invNames)
  }

  function rowByMac(mac) {
    var key = String(mac || "").toLowerCase().replace(/-/g, ":")
    if (key.length !== 17) return null
    var bands = [root.newDevices, root.devices, root.machines, root.lan, root.quietLan]
    for (var b = 0; b < bands.length; b++) {
      var band = bands[b]
      if (!(band instanceof Array)) continue
      for (var i = 0; i < band.length; i++)
        if (String(band[i].mac || "").toLowerCase() === key) return band[i]
    }
    return null
  }

  // Every identity worth dismissing for one device.
  //
  // A host answers under more than one: a MAC per interface, and an address per
  // interface on top of that. The list held a single entry, preferring the MAC,
  // so dismissing a machine removed exactly one of its faces and the next scan
  // handed it back under another.
  function ignoreEntriesFor(row) {
    var out = []
    var seen = ({})
    var when = new Date().toISOString()
    var label = String((row && row.label) || "")

    function add(mac, ip) {
      var entry = ({})
      if (mac) entry.mac = String(mac).toLowerCase()
      if (ip) entry.ip = String(ip)
      if (!entry.mac && !entry.ip) return
      var k = (entry.mac || "") + "|" + (entry.ip || "")
      if (seen[k]) return
      seen[k] = true
      if (label) entry.label = label
      entry.ts = when
      out.push(entry)
    }

    if (row) { add(row.mac, null); add(null, row.ip) }
    return out
  }

  function ignoreDevice(row) {
    if (!row) return
    var entries = root.ignoreEntriesFor(row)
    if (!entries.length) return
    var entry = entries[0]

    var next = (root.invIgnored instanceof Array ? root.invIgnored.slice() : [])
    var added = false
    for (var e = 0; e < entries.length; e++) {
      var cand = entries[e]
      var dup = false
      for (var i = 0; i < next.length; i++) {
        var k = next[i]
        if (cand.mac && String(k.mac || "").toLowerCase() === cand.mac) { dup = true; break }
        if (cand.ip && !cand.mac && String(k.ip || "") === cand.ip) { dup = true; break }
      }
      if (!dup) { next.push(cand); added = true }
    }
    if (!added) return
    root.invIgnored = next

    // Drop it from view now. The models are only replaced when the next
    // snapshot lands, up to a full probe interval away, so without this the row
    // sits there after you click and the button looks broken.
    root.forgetRowLocally(entry.mac, entry.ip)
    root.writeInventoryWithOverrides(next, root.invNames)
  }

  // Remove a device from the lists that are on screen right now.
  function forgetRowLocally(mac, ip) {
    var key = String(mac || "").toLowerCase()
    var addr = String(ip || "")

    function without(list) {
      if (!(list instanceof Array)) return list
      var out = []
      for (var i = 0; i < list.length; i++) {
        var m = String(list[i].mac || "").toLowerCase()
        var a = String(list[i].ip || "")
        if ((key && m === key) || (!key && addr && a === addr)) continue
        out.push(list[i])
      }
      return out
    }

    root.newDevices = without(root.newDevices)
    root.devices = without(root.devices)
    root.machines = without(root.machines)
  }

  function restoreIgnored(index) {
    if (!(root.invIgnored instanceof Array)) return
    var next = []
    for (var i = 0; i < root.invIgnored.length; i++)
      if (i !== index) next.push(root.invIgnored[i])
    root.invIgnored = next
    root.writeInventoryWithOverrides(next, root.invNames)
  }

  function restoreAllIgnored() {
    root.invIgnored = []
    root.writeInventoryWithOverrides([], root.invNames)
  }

  // Identity, not id. Two adds of one box produced `nano` and `nano-245`,
  // because the only check was whether the slug collided.
  function inventoryHasDevice(c) {
    if (!c) return false
    var mac = String(c.mac || "").toLowerCase()
    var ip = String(c.ip || "")
    var host = String(c.host || "").toLowerCase().replace(/\.(local|lan)$/, "")
    for (var i = 0; i < root.nodes.length; i++) {
      var n = root.nodes[i]
      if (mac && String(n.mac || "").toLowerCase() === mac) return true
      if (ip && String(n.ip || "") === ip) return true
      if (host) {
        var ndns = String(n.dns || "").toLowerCase().replace(/\.(local|lan)$/, "")
        if (ndns && ndns === host) return true
        if (String(n.label || "").toLowerCase() === host) return true
      }
    }
    return false
  }

  function addDiscovered(c) {
    if (c) c.addedByHand = true
    if (root.inventoryHasDevice(c)) {
      root.inventoryError = "Already in your inventory"
      return
    }
    var node = root.discoveredNode(c)
    if (!node) {
      root.inventoryError = "Nothing to add"
      return
    }
    var next = root.nodes.slice()
    next.push(node)

    // Take it out of the "things you could add" list straight away. The
    // collector filters it out on the next pass, but that is a probe away and
    // until then the row you just added is still sitting there to be added
    // again.
    root.forgetCandidateLocally(c)
    root.forgetRowLocally(c.mac, c.ip)

    // And go and look at it. Adding a box is a request to see it on the map.
    root.returnToMap()
    root.writeNodes(next)
  }

  function forgetCandidateLocally(c) {
    if (!c || !(root.discover instanceof Array)) return
    var mac = String(c.mac || "").toLowerCase()
    var ip = String(c.ip || "")
    var out = []
    for (var i = 0; i < root.discover.length; i++) {
      var d = root.discover[i]
      if (mac && String(d.mac || "").toLowerCase() === mac) continue
      if (!mac && ip && String(d.ip || "") === ip) continue
      out.push(d)
    }
    root.discover = out
  }

  function returnToMap() {
    root.view = "glance"
    root.glanceTab = "map"
    root.formConfirmDelete = false
    root.formFieldFocused = false
    root.cancelInlineEdit()
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
      // A right-click on the bar icon asks for a specific view; otherwise the
      // panel always opens on the glance.
      root.view = root.pendingView !== "" ? root.pendingView : "glance"
      // The map is the thing. Opening onto whichever tab happened to be left
      // selected three sessions ago is not a preference, it is a leftover.
      if (root.pendingView === "") root.glanceTab = "map"
      root.pendingView = ""
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
      root.renaming = false
      root.cancelInlineEdit()
    }
  }

  FileView {
    id: manifestFile
    path: root.pluginDir + "/manifest.json"
    printErrors: false
    onLoaded: {
      try {
        root.pluginVersion = String(JSON.parse(text()).version || "")
      } catch (e) {
        root.pluginVersion = ""
      }
    }
  }

  FileView {
    id: snapshotView
    path: root.stateDir + "/snapshot.json"
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

  // Keep CPython's __pycache__ out of the plugin tree: the shell watches that
  // directory and reloads the plugin when bytecode is written into it.
  readonly property var pyEnv: ({ "PYTHONPYCACHEPREFIX": root.stateDir + "/pycache" })

  Process {
    id: daemonProc
    environment: root.pyEnv
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
      heartbeatProc.command = ["touch", root.stateDir + "/.panel-heartbeat"]
      heartbeatProc.running = true
    }
  }

  Process {
    id: actionProc
    environment: root.pyEnv
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
    environment: root.pyEnv
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
    environment: root.pyEnv
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
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
        // A queued write on top of a failure would bury the error.
        root.pendingWrite = null
        root.loadInventory()
        return
      }
      // Send whatever was clicked while this write was in flight, before
      // reloading, or the reload would overwrite the newer intent.
      if (root.drainPendingWrite()) return
      // Editing a node returns to the list it was edited from. Everything else
      // has already navigated itself and must not be yanked elsewhere.
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
    id: meshRow
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
        visible: meshRow.nodeId !== ""
        Layout.preferredWidth: 56
        Layout.preferredHeight: 14
        Layout.alignment: Qt.AlignVCenter
        // `nodeId: nodeId` would bind the Sparkline's own property to itself:
        // QML resolves an unqualified name against the innermost object first.
        nodeId: meshRow.nodeId
        series: root.sparks[meshRow.nodeId] || null
        pluginDir: root.pluginDir
        live: root.opened && root.view === "glance" && root.glanceTab === "list"
            && meshRow.nodeId !== ""
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
    readonly property bool isEgress: nodeId === "__gateway__"
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
    border.width: selected || status === "down" || mapBox.isEgress ? 2 : 1
    border.color: {
      if (selected || status === "up" || status === "degraded" || status === "down")
        return Qt.alpha(root.statusColor(status), selected || status === "down" ? 1.0 : 0.88)
      return root.borderIdle
    }
    antialiasing: true

    // Mask the zone divider beneath the gateway's translucent status fill.
    Rectangle {
      visible: mapBox.isEgress
      anchors.fill: parent
      radius: mapBox.radius
      color: Color.popups.background
      z: -1
    }

    // Status as light. A card's health is legible across the room without
    // reading the dot or the label: green sits still, amber breathes, red
    // pulses hard. Drawn as a halo behind the card so the fill stays the
    // status colour decided in 0.3.6 and nothing washes over the text.
    Rectangle {
      id: halo
      z: -1
      anchors.centerIn: parent
      width: parent.width + Style.space(16)
      height: parent.height + Style.space(16)
      radius: parent.radius + Style.space(8)
      color: "transparent"
      antialiasing: true
      visible: mapBox.status === "up" || mapBox.status === "degraded"
          || mapBox.status === "down" || mapBox.selected
      border.width: Style.space(8)
      border.color: Qt.alpha(root.statusColor(mapBox.status), halo.glow)

      property real glow: 0.10
      Behavior on glow { NumberAnimation { duration: 240 } }

      states: [
        State {
          name: "down"
          when: mapBox.status === "down"
          PropertyChanges { halo.glow: 0.34 }
        },
        State {
          name: "degraded"
          when: mapBox.status === "degraded"
          PropertyChanges { halo.glow: 0.22 }
        }
      ]

      SequentialAnimation on opacity {
        running: mapBox.status === "down" || mapBox.status === "degraded"
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation {
          to: mapBox.status === "down" ? 0.35 : 0.6
          duration: mapBox.status === "down" ? 620 : 1100
          easing.type: Easing.InOutSine
        }
        NumberAnimation {
          to: 1
          duration: mapBox.status === "down" ? 620 : 1100
          easing.type: Easing.InOutSine
        }
        onRunningChanged: if (!running) halo.opacity = 1
      }
    }

    Rectangle {
      // Only the exception is worth a chip. Every card carrying "ALERT" said
      // nothing (it is the default) while eating half the width of a narrow
      // card, so the platform line had to elide to "LINUX...".
      visible: !mapBox.isLan && !mapBox.notifyOn
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
        // The notify chip floats over the top-right of the card, so the
        // platform line must reserve its width or the two overprint.
        width: Math.max(Style.space(24),
                        parent.width - (mapBox.notifyOn || mapBox.isLan ? 0 : Style.space(52)))
        text: mapBox.nodeId === "__gateway__" ? "DEFAULT GATEWAY" : mapBox.subline.toUpperCase()
        color: root.inkDim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.letterSpacing: mapBox.isEgress ? 0.6 : 1.2
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
        // Double-click the name to rename it, right here. Going out to a form
        // to change one word is too many steps for the most common edit.
        Item {
          Layout.fillWidth: true
          implicitHeight: cardName.implicitHeight

          Text {
            id: cardName
            anchors.fill: parent
            visible: root.editingId !== mapBox.nodeId
            text: mapBox.label
            color: root.ink
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          MouseArea {
            anchors.fill: parent
            enabled: !mapBox.isLan && root.editingId !== mapBox.nodeId
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.IBeamCursor
            onDoubleClicked: root.beginInlineEdit(mapBox.nodeId, mapBox.label)
            onClicked: mapBox.activated()
          }

          TextInput {
            id: cardEdit
            anchors.fill: parent
            visible: root.editingId === mapBox.nodeId
            text: root.editingText
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            selectByMouse: true
            clip: true
            onTextChanged: if (visible) root.editingText = text
            onAccepted: root.commitInlineEdit()
            Keys.onEscapePressed: root.cancelInlineEdit()
            onVisibleChanged: if (visible) { selectAll(); forceActiveFocus() }
          }
        }
      }

      Text {
        width: parent.width
        text: mapBox.metric !== "" ? mapBox.metric : root.rttText(mapBox.rttRow)
        color: (mapBox.metric === "—" || mapBox.metric === "") ? root.inkDim : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: mapBox.isEgress ? Text.Wrap : Text.NoWrap
        maximumLineCount: mapBox.isEgress ? 5 : 1
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
        visible: !mapBox.isEgress
        width: parent.width
        height: Style.space(16)
        nodeId: mapBox.sparklineId
        series: root.sparks[mapBox.sparklineId] || null
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

  // A ticking clock, so anything derived from "how old is this" actually
  // re-evaluates. Elapsed time alone cannot invalidate a binding.
  property double nowMs: Date.now()
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // ONE health model. Every surface reads this: the bar colour, the status
  // pill, the IPC. Previously each counted its own way, over overlapping
  // arrays, so the bar could show a green tick while the Internet card was red.
  readonly property var labHealth: {
    var seen = ({})
    var counts = { up: 0, degraded: 0, down: 0, unknown: 0, muted: 0, total: 0 }

    function take(row) {
      if (!row) return
      var id = String(row.id || "")
      // The LAN bucket holds demoted copies of rows that are already counted in
      // their own band, so a single failure used to be counted twice.
      if (!id || seen[id]) return
      seen[id] = true
      var st = String(row.status || "unknown")
      // Turning notifications off for a box is a statement that you do not want
      // to hear about it. It was still counted as down, so it kept the bar icon
      // red and the header on "1 DOWN" for a machine you had deliberately
      // silenced, which is the one state muting is supposed to remove. It
      // counts as muted instead: still in the total, still red on its own card,
      // just no longer an alarm.
      if (st !== "up" && !root.notifyEnabledForNodeId(id)) {
        counts.muted++
        counts.total++
        return
      }
      if (st === "up") counts.up++
      else if (st === "degraded") counts.degraded++
      else if (st === "down") counts.down++
      else counts.unknown++
      counts.total++
    }

    var bands = [root.machines, root.groups, root.lanBucketRows(), root.quietProxies]
    for (var b = 0; b < bands.length; b++)
      for (var i = 0; i < bands[b].length; i++) take(bands[b][i])

    // The gateway and the internet are part of the lab's health. Leaving them
    // out is how a red Internet card coexisted with "ALL CLEAR".
    take(root.gateway)
    take(root.wan)
    return counts
  }

  readonly property int glanceDownCount: root.labHealth.down
  readonly property int glanceDegradedCount: root.labHealth.degraded

  readonly property var barDisplayModes: [
    { key: "downs", label: "Down count", hint: "3↓ when something is down, a tick when all is well" },
    { key: "upfrac", label: "Up / total", hint: "12/14" },
    { key: "worstrtt", label: "Worst latency", hint: "the slowest node's RTT" },
    { key: "hosts", label: "Host traffic", hint: "↓ down ↑ up, summed over hosts with telemetry" },
    { key: "none", label: "Icon only", hint: "no text, just the castle" }
  ]

  readonly property string barDisplay: {
    var v = String((root.invSettings && root.invSettings.barDisplay) || "downs")
    if (v === "wan") v = "hosts"   // renamed: it was never WAN throughput
    for (var i = 0; i < root.barDisplayModes.length; i++)
      if (root.barDisplayModes[i].key === v) return v
    return "downs"
  }

  function setBarDisplay(key) {
    var settings = ({})
    var k
    for (k in root.invSettings) settings[k] = root.invSettings[k]
    settings.barDisplay = String(key || "downs")
    root.invSettings = settings
    root.view = "glance"
    if (!root.inventoryReady || root.inventoryLoading) return
    if (!(root.nodes instanceof Array) || root.nodes.length === 0) return
    root.runInventoryWrite(root.inventoryWritePayload(root.nodes, settings))
  }

  readonly property int glanceTotalCount: root.machines.length + root.groups.length

  readonly property real glanceWorstRtt: {
    var worst = -1
    for (var i = 0; i < root.machines.length; i++) {
      var v = Number(root.machines[i].rtt_ms)
      if (isFinite(v) && v > worst) worst = v
    }
    return worst
  }

  readonly property string barText: {
    if (!root.asOf) return "…"
    var mode = root.barDisplay
    if (mode === "none") return ""
    if (mode === "downs")
      return root.glanceDownCount > 0 ? (root.glanceDownCount + "↓")
          : (root.glanceDegradedCount > 0 ? (root.glanceDegradedCount + "!") : "✓")
    if (mode === "upfrac") {
      var total = root.glanceTotalCount
      if (total <= 0) return ""
      return (total - root.glanceDownCount) + "/" + total
    }
    if (mode === "worstrtt") {
      var r = root.glanceWorstRtt
      if (!(r >= 0)) return "—"
      return (r >= 100 ? Math.round(r) : Math.round(r * 10) / 10) + "ms"
    }
    if (mode === "hosts") {
      var t = root.lanTrafficTotals()
      var d = root.fmtRate(t.rx_bps)
      var u = root.fmtRate(t.tx_bps)
      return (d || u) ? ("↓" + (d || "0") + " ↑" + (u || "0")) : "idle"
    }
    return ""
  }

  readonly property color barHealthColor: {
    if (root.glanceDownCount > 0) return (root.themeRed && String(root.themeRed) !== "") ? root.themeRed : root.urgent
    if (root.glanceDegradedCount > 0) return root.themeYellow
    if (!root.asOf || root.snapshotStale()) return root.inkDim
    // Unknown is not healthy. A lab we cannot see is not a lab that is fine.
    if (root.labHealth.unknown > 0 && root.labHealth.up === 0) return root.inkDim
    return root.themeGreen
  }

  // Scriptable surface. `omarchy-shell donnie.homelab-mesh <fn>` drives the
  // panel without the mouse, which also makes the views testable.
  IpcHandler {
    // NOT the plugin id: the host's Ui/Panel base already registers a handler on
    // that target, and a second registration for the same target is discarded,
    // which silently removed every function below.
    target: "lanarchy"

    function open(): void { root.pendingView = ""; root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.pendingView = ""; root.toggle() }
    function refresh(): void { root.refresh() }

    function map(): void {
      root.glanceTab = "map"
      root.pendingView = ""
      if (root.opened) root.view = "glance"
      else root.open()
    }

    function list(): void {
      root.glanceTab = "list"
      root.pendingView = ""
      if (root.opened) root.view = "glance"
      else root.open()
    }

    function setup(): void {
      root.pendingView = "setup"
      if (root.opened) root.goSetup()
      else root.open()
    }

    // The right-click chooser, without the right-click.
    function modes(): void {
      root.pendingView = "barmenu"
      if (root.opened) root.view = "barmenu"
      else root.open()
    }

    function barDisplay(mode: string): void { root.setBarDisplay(String(mode || "downs")) }

    // Device management, scriptable. These are the same functions the buttons
    // call, so exercising them here exercises the real path rather than a copy.
    function ignore(mac: string): string {
      var row = root.rowByMac(mac)
      if (!row) return "no device with mac " + mac
      root.ignoreDevice(row)
      return "ignored " + String(row.label || mac)
    }

    function restore(mac: string): string {
      var key = String(mac || "").toLowerCase()
      for (var i = 0; i < root.invIgnored.length; i++) {
        if (String(root.invIgnored[i].mac || "").toLowerCase() === key) {
          root.restoreIgnored(i)
          return "restored " + key
        }
      }
      return "not ignored: " + key
    }

    function rename(mac: string, label: string): string {
      var row = root.rowByMac(mac)
      if (!row) return "no device with mac " + mac
      root.renameRow(row, String(label || ""))
      return "renamed to " + label
    }

    function overrides(): string {
      return JSON.stringify({
        ignored: root.invIgnored,
        names: root.invNames,
        ready: root.inventoryReady,
        loading: root.inventoryLoading,
        nodes: root.nodes.length
      })
    }

    function version(): string { return root.pluginVersion }

    function status(): string {
      if (!root.asOf) return "probing"
      var h = root.labHealth
      var parts = []
      if (h.down) parts.push(h.down + " down")
      if (h.degraded) parts.push(h.degraded + " degraded")
      if (h.unknown) parts.push(h.unknown + " unknown")
      if (!parts.length) parts.push("all up")
      // Excluded from the alarm, not hidden. A silenced box that is genuinely
      // off should still be findable here rather than disappearing from the
      // count entirely.
      if (h.muted) parts.push(h.muted + " muted")
      if (root.snapshotStale()) parts.push("STALE")
      return parts.join(" · ") + " · " + h.total + " tracked · " + root.asOf
    }
  }

  // Bar entry: the castle plus a live readout. A WidgetButton (not
  // BarIconButton) because BarIconButton draws its iconComponent inside a
  // fixed square canvas, which clips any text beside the mark.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    // Reserve exactly the width drawn, or the readout paints over the
    // neighbouring widget as the reading changes length.
    fixedWidth: root.vertical ? -1 : barRow.implicitWidth + Style.space(10)
    fixedHeight: root.vertical ? barRow.implicitHeight + Style.space(10) : -1
    tooltipText: {
        var lines = [root.pluginVersion !== "" ? ("Lanarchy v" + root.pluginVersion) : "Lanarchy"]
        if (root.asOf) {
            lines.push(root.glanceDownCount > 0
                ? (root.glanceDownCount + " down · " + root.glanceTotalCount + " tracked")
                : ("all up · " + root.glanceTotalCount + " tracked"))
        } else {
            lines.push("probing…")
        }
        lines.push("Left-click: dashboard · Middle: refresh · Right-click: choose the readout")
        return lines.join("\n")
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.RightButton) {
        if (root.opened && root.view === "barmenu") {
          root.view = "glance"
          return
        }
        root.pendingView = "barmenu"
        if (root.opened) root.view = "barmenu"
        else root.open()
      }
    }

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: root.barText === "" ? 0 : Style.space(4)

      LanarchyIcon {
        anchors.verticalCenter: parent.verticalCenter
        iconSize: Style.space(14)
        color: root.barHealthColor
        alert: root.urgent
        alarmed: root.glanceDownCount > 0
        active: root.opened || root.glanceDownCount > 0 || root.glanceDegradedCount > 0
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.barText !== ""
        text: root.barText
        color: root.barHealthColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: root.glanceDownCount > 0
      }
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
    // No artificial cap: fittedContentHeight already clamps to the space the
    // screen actually has. Capping at 760 made the panel clip its own content
    // on a display with room to spare.
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Block Esc/keys while form fields focused — TextField handles input.
      // NOT `enabled`: that propagates down and disables the panel's own text
      // fields and buttons. `blocked` forwards keys to descendants instead.
      blocked: (root.view === "form" && root.formFieldFocused) || root.renaming
          || root.editingId !== ""
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

      // The panel grows to fit its content. This only ever scrolls when the
      // content is taller than the screen itself, which is the one case where
      // growing further is impossible.
      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        interactive: contentHeight > height + 1
        boundsBehavior: Flickable.StopAtBounds
        clip: interactive
        ScrollBar.vertical: ScrollBar {
          policy: panelScroll.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
          width: 6
        }

      Item {
        id: contentColumn
        width: panelScroll.width
        implicitHeight: glanceBody.implicitHeight
        height: implicitHeight

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

        // ——— BAR ICON CHOOSER (right-click on the bar icon) ———
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.view === "barmenu"

          Row {
            spacing: Style.space(8)
            LanarchyIcon {
              anchors.verticalCenter: parent.verticalCenter
              iconSize: Style.space(20)
              color: root.barHealthColor
              alert: root.urgent
              alarmed: root.glanceDownCount > 0
              active: true
            }
            Column {
              spacing: Style.space(2)
              Text {
                text: "What the bar icon shows"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                font.letterSpacing: 1.2
              }
              Text {
                text: "Right-click the icon any time · Esc back"
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            Repeater {
              model: root.barDisplayModes
              Rectangle {
                id: modeRow
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(34)
                radius: Style.space(6)
                readonly property bool picked: root.barDisplay === String(modeRow.modelData.key)
                color: picked
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
                    : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
                border.width: 1
                border.color: picked ? Qt.alpha(Color.accent, 0.55) : "transparent"

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modeRow.picked ? "●" : "○"
                    color: modeRow.picked ? Color.accent : root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(modeRow.modelData.label)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: modeRow.picked
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(modeRow.modelData.hint)
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setBarDisplay(modeRow.modelData.key)
                }
              }
            }
          }
        }

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
                Text {
                  // Which build am I on. Read from manifest.json, so it can only
                  // ever be the version that actually shipped.
                  visible: root.pluginVersion !== ""
                  text: "v" + root.pluginVersion
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
              Text {
                width: parent.width
                text: root.glanceTab === "map"
                    ? (root.mapHasExternal
                        ? "solid = measured traffic, dashed = no telemetry · click a card to follow its own path · double-click a name to rename"
                        : "solid = measured traffic, dashed = no telemetry · click a card to follow its own path · double-click a name to rename")
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
          visible: root.view === "setup" || root.view === "form"
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
            // Grow to whatever the topology needs; the popup grows with it.
            height: Math.max(Style.space(140), root.mapContentHeight)
            visible: root.glanceTab === "map"
            radius: Style.space(14)
            color: Color.popups.background
            border.width: 1
            border.color: Qt.alpha(Color.accent, 0.35)
            // Width only. The layout reads mapArea.width and *writes*
            // mapContentHeight, which drives this height, so recalculating on a
            // height change fed the layout its own output and forced a second
            // full pass and repaint every time the topology grew a row.
            onWidthChanged: root.recalcMapLayout()
            clip: true

            // No vertical divider and no zone captions. The chain reads
            // left to right on its own: machines, then the gateway they go
            // through, then the internet. A full-height line separating two
            // halves of a picture that is already ordered is just furniture.

            // One property animation drives every packet. Nothing repaints the
            // canvas per frame any more: the routes only change when the layout,
            // the statuses or the rates change.
            NumberAnimation {
              id: flowClock
              // edgePhase lives on root, so the animation needs an explicit
              // target; "NumberAnimation on edgePhase" would bind to mapArea.
              target: root
              property: "edgePhase"
              // A wall clock in seconds, so packet speeds below are literally
              // pixels per second rather than an arbitrary phase.
              running: root.opened && root.view === "glance"
                  && root.glanceTab === "map" && root.mapAnimate
              loops: Animation.Infinite
              from: 0
              to: 3600
              duration: 3600000
              easing.type: Easing.Linear
            }

            // Static geometry: the soft underglow and the route itself.
            Canvas {
              id: edgeCanvas
              anchors.fill: parent
              z: 0
              renderStrategy: Canvas.Cooperative
              property var routes: root.mapEdgeRoutes
              onRoutesChanged: requestPaint()
              // The selection decides what is dimmed, and the canvas repaints
              // only when told to, so it has to be watched explicitly.
              property string selection: root.mapSelectedId
              onSelectionChanged: requestPaint()
              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                var list = root.mapEdgeRoutes
                for (var i = 0; i < list.length; i++) {
                  var r = list[i]
                  var pts = r.points
                  // A link with no telemetry looked exactly like a measured
                  // link that happens to be idle: both are a static line. That
                  // reads as "the map is broken" rather than "nothing is
                  // measuring this box", so an unmeasured link is dashed.
                  // Only hosts whose byte counters can be read report rates, so
                  // most discovered devices are legitimately unmeasured.
                  var unmeasured = !r.measured && !r.internetLink
                  // Selecting a card picks its own route out of the shared bus.
                  // Everything else recedes rather than vanishing, so the
                  // topology still reads while one host's path is followed.
                  // The exit to the internet is on every host's path, so it
                  // never recedes; dimming it made the map look half-dead when
                  // a single card was selected.
                  var faded = (r.internetLink || root.routeIsSelected(r)) ? 1.0 : 0.22
                  // Both strokes carry the dash. Dashing only the thin line
                  // left the wider underglow solid underneath it, which filled
                  // the gaps back in and made the link look solid anyway.
                  if (unmeasured) ctx.setLineDash([Style.space(4), Style.space(5)])
                  // WAN emphasis is fixed; other widths track endpoint rates.
                  ctx.strokeStyle = Qt.alpha(r.color, (r.down ? 0.20 : 0.26) * faded)
                  ctx.lineWidth = r.width
                  ctx.beginPath()
                  ctx.moveTo(pts[0].x, pts[0].y)
                  for (var j = 1; j < pts.length; j++) ctx.lineTo(pts[j].x, pts[j].y)
                  ctx.stroke()
                  // Give the static internet exit a clear visual hierarchy.
                  ctx.strokeStyle = Qt.alpha(r.color,
                      (r.internetLink ? 0.85 : (r.down ? 0.34 : 0.55)) * faded)
                  ctx.lineWidth = r.internetLink ? Style.space(3) : 1.4
                  ctx.beginPath()
                  ctx.moveTo(pts[0].x, pts[0].y)
                  for (j = 1; j < pts.length; j++) ctx.lineTo(pts[j].x, pts[j].y)
                  ctx.stroke()
                  if (unmeasured) ctx.setLineDash([])
                  // Static terminal sockets make the exit read as a physical
                  // connection. Their size is constant, never a traffic signal.
                  if (r.internetLink) {
                    var arrow = root.polylinePointAt(pts, r.length / 2)
                    ctx.beginPath()
                    ctx.moveTo(arrow.x - Style.space(4), arrow.y - Style.space(5))
                    ctx.lineTo(arrow.x + Style.space(1), arrow.y)
                    ctx.lineTo(arrow.x - Style.space(4), arrow.y + Style.space(5))
                    ctx.stroke()
                    ctx.fillStyle = r.color
                    for (var end = 0; end < 2; end++) {
                      var port = pts[end === 0 ? 0 : pts.length - 1]
                      ctx.beginPath()
                      ctx.arc(port.x, port.y, Style.space(4), 0, Math.PI * 2)
                      ctx.fill()
                    }
                  }
                }
              }
            }

            // Travelling packets. Every one of these is measured throughput:
            // the count comes from the byte rate, the speed is pixels per second
            // derived from that rate, and rx walks the route while tx walks back.
            // An edge with no telemetry gets nothing, so a still line means "not
            // measured" rather than "idle".
            Repeater {
              model: root.mapAnimate ? root.mapEdgeRoutes : []
              z: 1
              delegate: Item {
                id: flowLane
                required property var modelData
                anchors.fill: parent
                // With a card selected, only that host's packets move. That
                // is the whole point: on a shared lane you otherwise cannot
                // tell which box the bytes belong to.
                visible: modelData.measured && root.routeIsSelected(modelData)
                opacity: modelData.down ? 0.55 : 1.0

                // rx forwards, tx backwards.
                Repeater {
                  model: 2
                  delegate: Item {
                    id: direction
                    required property int index
                    anchors.fill: parent
                    readonly property bool inbound: direction.index === 0
                    readonly property int count: direction.inbound
                        ? flowLane.modelData.rxPackets : flowLane.modelData.txPackets
                    readonly property real speed: direction.inbound
                        ? flowLane.modelData.rxSpeed : flowLane.modelData.txSpeed

                    Repeater {
                      model: direction.count
                      delegate: Rectangle {
                        id: packet
                        required property int index
                        readonly property real span: flowLane.modelData.length
                        // Evenly spaced along the route, so a busy link reads as a
                        // stream and a trickle reads as a single dot.
                        readonly property real travelled: {
                          if (!(packet.span > 0) || direction.count <= 0) return 0
                          var offset = packet.span * (packet.index / direction.count)
                          var d = root.edgePhase * direction.speed + offset + flowLane.modelData.stagger
                          var walked = d % packet.span
                          return direction.inbound ? walked : (packet.span - walked)
                        }
                        readonly property var pos: root.polylinePointAt(flowLane.modelData.points, packet.travelled)

                        width: Math.max(4.5, Math.min(8, flowLane.modelData.width * 1.1))
                        height: width
                        radius: width / 2
                        x: pos.x - width / 2
                        y: pos.y - height / 2
                        // Outbound bytes read cooler than inbound, so direction is
                        // visible without watching which way a dot moves.
                        color: direction.inbound
                            ? flowLane.modelData.color
                            : Qt.lighter(flowLane.modelData.color, 1.5)
                        opacity: 0.95
                        antialiasing: true

                        // Two rings of falloff so a packet reads as light on the
                        // wire rather than a hard dot sliding along it.
                        Rectangle {
                          anchors.centerIn: parent
                          width: parent.width * 2.4
                          height: width
                          radius: width / 2
                          color: Qt.alpha(parent.color, 0.26)
                          z: -1
                          antialiasing: true
                        }
                        Rectangle {
                          anchors.centerIn: parent
                          width: parent.width * 4.2
                          height: width
                          radius: width / 2
                          color: Qt.alpha(parent.color, 0.12)
                          z: -2
                          antialiasing: true
                        }
                      }
                    }
                  }
                }
              }
            }

            // The internet, as an arrow out of the gateway. No card, no column,
            // no reserved space: it sits in the margin the gateway card already
            // leaves, and states only what is known.
            Item {
              id: internetExit
              visible: root.wan !== null && root.gatewayBox !== null
              z: 2
              x: root.gatewayBox ? root.gatewayBox.x + root.gatewayBox.w : 0
              y: root.gatewayBox ? root.gatewayBox.y : 0
              width: Math.max(Style.space(10), mapArea.width - x - Style.space(6))
              height: root.gatewayBox ? root.gatewayBox.h : 0

              readonly property color tint: root.wan && String(root.wan.status) === "up"
                  ? root.themeGreen : root.urgent

              // The label decides where the arrow stops, or the head draws on
              // top of the text.
              readonly property real labelW: Math.max(exitLabel.implicitWidth,
                                                      exitMetric.implicitWidth)
              readonly property real headX:
                Math.max(Style.space(10), width - labelW - Style.space(16))

              // shaft
              Rectangle {
                x: 0
                y: parent.height / 2 - height / 2
                width: Math.max(Style.space(8), internetExit.headX)
                height: 2
                color: Qt.alpha(internetExit.tint, 0.55)
                antialiasing: true
              }
              // head
              Canvas {
                id: arrowHead
                width: Style.space(10)
                height: Style.space(10)
                x: internetExit.headX
                y: parent.height / 2 - height / 2
                onPaint: {
                  var c = getContext("2d")
                  c.clearRect(0, 0, width, height)
                  c.fillStyle = internetExit.tint
                  c.beginPath()
                  c.moveTo(0, 0)
                  c.lineTo(width, height / 2)
                  c.lineTo(0, height)
                  c.closePath()
                  c.fill()
                }
                Connections {
                  target: internetExit
                  function onTintChanged() { arrowHead.requestPaint() }
                }
              }
              Column {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                Text {
                  id: exitLabel
                  text: "INTERNET"
                  color: internetExit.tint
                  font.family: root.fontFamily
                  font.pixelSize: 9
                  font.bold: true
                  font.letterSpacing: 1.1
                }
                Text {
                  id: exitMetric
                  visible: text !== ""
                  text: root.wanMetric()
                  color: root.muted
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
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
              // Nothing selected: this space used to hold an instruction, which
              // is the least useful thing a dashboard can show. It now answers
              // the question you actually opened the panel for.
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.mapSelectedId === ""

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  Text {
                    text: "RECENT"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                  }
                  Text {
                    visible: root.lanMetricsText() !== ""
                    text: root.lanMetricsText()
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    visible: root.monitoredHostsText() !== ""
                    text: "monitored hosts " + root.monitoredHostsText()
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    visible: root.flapping.length > 0
                    text: {
                      // `visible` does not stop a binding being evaluated, so an
                      // empty list must be handled here, not upstream.
                      if (root.flapping.length === 0) return ""
                      // Name every unstable box, not just the worst one. It
                      // said "unstable: <one host>" while three others were
                      // flapping just as hard and went unmentioned.
                      var parts = []
                      for (var i = 0; i < Math.min(3, root.flapping.length); i++)
                        parts.push(root.nodeLabelById(root.flapping[i].id)
                            + " " + root.flapping[i].count + "x")
                      var more = root.flapping.length - parts.length
                      return "unstable in the last hour: " + parts.join(" \u00b7 ")
                          + (more > 0 ? " \u00b7 +" + more + " more" : "")
                    }
                    color: root.themeYellow
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    visible: root.flapping.length === 0 && root.events.length === 0
                    text: "no status changes recorded yet"
                    color: root.muted
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Repeater {
                  model: root.events
                  delegate: Row {
                    id: eventRow
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      width: Style.space(34)
                      horizontalAlignment: Text.AlignRight
                      text: root.agoText(eventRow.modelData.ts)
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: String(eventRow.modelData.to) === "up" ? "▲" : "▼"
                      color: String(eventRow.modelData.to) === "up" ? root.themeGreen : root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: root.nodeLabelById(eventRow.modelData.id)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: String(eventRow.modelData.from) + " → " + String(eventRow.modelData.to)
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    // One row per node now, so the row has to say how many
                    // times that node flipped or the collapsing loses the fact.
                    Text {
                      visible: Number(eventRow.modelData.changes || 1) > 1
                      text: "×" + Number(eventRow.modelData.changes || 1)
                      color: root.themeYellow
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              Text {
                width: parent.width
                visible: root.mapSelectedId !== ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
                text: {
                  if (!root.mapSelectedId) return ""
                  var row = root.glanceRowById(root.mapSelectedId)
                  if (!row) return root.mapSelectedId
                  if (row.id === "__lan__") return row.metric + " · List → LAN to Show demoted cards back onto the map"
                  var metric = row.members ? root.serviceMetric(row) : root.machineMetric(row)
                  var line = String(row.label || row.id) + " · " + String(row.status) + " · " + metric
                  var os = root.osDetail(row)
                  if (os) line += " · " + os
                  return line
                }
              }
              // Rename in place. A discovered box had no way to be called
              // anything but its address before this.
              Row {
                visible: root.renaming && root.mapSelectedId !== ""
                spacing: Style.space(8)
                width: parent.width
                TextField {
                  id: renameField
                  width: Style.space(200)
                  placeholderText: "name this box"
                  onAccepted: root.renameRow(root.glanceRowById(root.mapSelectedId), text)
                }
                SegBtn {
                  label: "Save"
                  active: true
                  onTapped: root.renameRow(root.glanceRowById(root.mapSelectedId), renameField.text)
                }
                SegBtn {
                  label: "Cancel"
                  active: false
                  onTapped: root.renaming = false
                }
              }

              Row {
                visible: !root.renaming && root.mapSelectedId !== "" && root.mapSelectedId !== "__lan__"
                spacing: Style.space(8)
                SegBtn {
                  label: "Rename"
                  active: false
                  onTapped: {
                    var row = root.glanceRowById(root.mapSelectedId)
                    renameField.text = row ? String(row.label || "") : ""
                    root.renaming = true
                    renameField.forceActiveFocus()
                  }
                }
                SegBtn {
                  label: root.notifyEnabledForNodeId(root.mapSelectedId) ? "Notify on" : "Notify off"
                  active: root.notifyEnabledForNodeId(root.mapSelectedId)
                  onTapped: root.toggleNotifyForNodeId(root.mapSelectedId)
                }
                SegBtn {
                  // Was "Move to LAN", which named the LAN bucket card. That
                  // card was removed, so the label pointed at a place the user
                  // could no longer see.
                  label: root.mapHiddenForId(root.mapSelectedId) ? "Show on map" : "Hide"
                  active: root.mapHiddenForId(root.mapSelectedId)
                  onTapped: root.toggleMapHidden(root.mapSelectedId)
                }
                SegBtn {
                  // Removal, in the row where every other action on a card
                  // already lives. It used to mean Setup, find it in the list,
                  // open it, Delete, Confirm delete, and for a discovered box
                  // there was no path at all.
                  label: root.removeArmedId === root.mapSelectedId
                      ? "Remove — confirm" : "Remove"
                  active: root.removeArmedId === root.mapSelectedId
                  onTapped: {
                    if (root.removeArmedId !== root.mapSelectedId) {
                      root.removeArmedId = root.mapSelectedId
                      return
                    }
                    root.removeArmedId = ""
                    root.removeCardById(root.mapSelectedId)
                  }
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

              // Hardware that has never been on this network before. The ledger
              // has already ruled out the first-run baseline, one-off ARP blips
              // and anything already dealt with, so every row here is an actual
              // arrival worth a second of attention.
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.newDevices.length > 0

                Rectangle {
                  width: parent.width
                  implicitHeight: newHead.implicitHeight + Style.space(10)
                  radius: Style.space(6)
                  color: Qt.alpha(root.themeYellow, 0.10)
                  border.width: 1
                  border.color: Qt.alpha(root.themeYellow, 0.45)
                  Row {
                    id: newHead
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    spacing: Style.space(8)
                    Text {
                      text: "NEW ON YOUR NETWORK"
                      color: root.themeYellow
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      font.letterSpacing: 1.2
                    }
                    Text {
                      text: root.newDevices.length + (root.newDevices.length === 1 ? " device" : " devices")
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Repeater {
                  model: root.newDevices
                  delegate: Row {
                    id: newRow
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(6)
                    Text {
                      width: Style.space(110)
                      text: String(newRow.modelData.label || newRow.modelData.mac || "device")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      width: Style.space(86)
                      text: String(newRow.modelData.ip || "")
                      color: root.inkDim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      width: Style.space(70)
                      text: String(newRow.modelData.kind || "")
                          + (newRow.modelData.randomized ? " · rnd" : "")
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                    Text {
                      text: root.agoText(newRow.modelData.first_seen)
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: "adopt"
                      color: root.themeGreen
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.adoptNewDevice(newRow.modelData)
                      }
                    }
                    Text {
                      text: "ignore"
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.ignoreDevice(newRow.modelData)
                      }
                    }
                  }
                }
              }

              // Everything else on the network. Speakers, TVs and phones are
              // real and are listed, but they are not topology, so they live in
              // a bounded drawer rather than on the map.
              Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.devices.length > 0 || root.ignoredList.length > 0

                Row {
                  width: parent.width
                  spacing: Style.space(8)
                  SegBtn {
                    label: (root.devicesOpen ? "▾ " : "▸ ") + "Devices (" + root.devices.length + ")"
                    active: root.devicesOpen
                    onTapped: root.devicesOpen = !root.devicesOpen
                  }
                  SegBtn {
                    visible: root.ignoredList.length > 0
                    label: (root.ignoredOpen ? "▾ " : "▸ ") + "Ignored (" + root.ignoredList.length + ")"
                    active: root.ignoredOpen
                    onTapped: root.ignoredOpen = !root.ignoredOpen
                  }
                  SegBtn {
                    // restoreAllIgnored() existed with nothing able to call it.
                    visible: root.ignoredOpen && root.ignoredList.length > 1
                    label: "Restore all"
                    active: false
                    onTapped: root.restoreAllIgnored()
                  }
                }

                // Bounded, scrolls in place: the page itself never scrolls.
                Flickable {
                  width: parent.width
                  visible: root.devicesOpen
                  height: Math.min(Style.space(150), deviceCol.implicitHeight)
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  contentWidth: width
                  contentHeight: deviceCol.implicitHeight
                  interactive: contentHeight > height
                  ScrollBar.vertical: ScrollBar { width: 6 }

                  Column {
                    id: deviceCol
                    width: parent.width
                    spacing: Style.space(2)
                    Repeater {
                      model: root.devices
                      delegate: Row {
                        id: deviceRow
                        required property var modelData
                        width: deviceCol.width
                        spacing: Style.space(6)
                        Text {
                          width: Style.space(120)
                          text: String(deviceRow.modelData.label || "device")
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                        Text {
                          width: Style.space(80)
                          text: String(deviceRow.modelData.kind || "")
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                        Text {
                          width: Style.space(90)
                          text: String(deviceRow.modelData.ip || "")
                          color: root.inkDim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                        Text {
                          text: "rename"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.beginDeviceRename(deviceRow.modelData)
                          }
                        }
                        Text {
                          text: "remove"
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.ignoreDevice(deviceRow.modelData)
                          }
                        }
                      }
                    }
                  }
                }

                Flickable {
                  width: parent.width
                  visible: root.ignoredOpen
                  height: Math.min(Style.space(110), ignoredCol.implicitHeight)
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  contentWidth: width
                  contentHeight: ignoredCol.implicitHeight
                  interactive: contentHeight > height
                  ScrollBar.vertical: ScrollBar { width: 6 }

                  Column {
                    id: ignoredCol
                    width: parent.width
                    spacing: Style.space(2)
                    Repeater {
                      model: root.ignoredList
                      delegate: Row {
                        id: ignoredRow
                        required property var modelData
                        required property int index
                        width: ignoredCol.width
                        spacing: Style.space(6)
                        Text {
                          width: Style.space(160)
                          text: String(ignoredRow.modelData.label || ignoredRow.modelData.mac
                                       || ignoredRow.modelData.ip || "device")
                          color: root.muted
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                        Text {
                          text: "restore"
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.restoreIgnored(ignoredRow.index)
                          }
                        }
                      }
                    }
                  }
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
                ? "Arrows select · Enter mutes · h hides · a toggles Flow · m list"
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
          // Bootstrap: a fresh install finds a whole lab, so do not make the
          // user click "+ add" twenty times to see their own map.
          Row {
            visible: !root.inventoryLoading && root.discover.length > 0
            spacing: Style.space(6)
            SegBtn {
              visible: root.discoverCount(true) > 0
              label: "+ Add all machines (" + root.discoverCount(true) + ")"
              active: false
              onTapped: root.addAllDiscovered(true)
            }
            SegBtn {
              visible: root.discoverCount(false) > root.discoverCount(true)
              label: "+ Add everything (" + root.discoverCount(false) + ")"
              active: false
              onTapped: root.addAllDiscovered(false)
            }
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
}
