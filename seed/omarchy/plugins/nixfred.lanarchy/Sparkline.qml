import QtQuick
import Quickshell
import qs.Ui

// Compact Pulse NetHistoryGraph: canvas, niceMax ceiling, hover crosshair + tip.
// Series arrive from snapshot.sparks, built once per probe. rx_bps is drawn only when present.
Item {
  id: spark
  property string nodeId: ""
  property string pluginDir: ""
  property bool live: visible && nodeId !== ""
  property color stroke: "#c0caf5"
  property color rateStroke: "#7aa2f7"
  property color muted: "#7e959f"
  property string fontFamily: ""
  property int hoverIndex: -1
  property var rttValues: []
  property var rxValues: []

  implicitWidth: 56
  implicitHeight: 16
  visible: nodeId !== ""
  clip: false

  readonly property int n: Math.max(rttValues.length, rxValues.length)
  readonly property real rttCeil: niceMax(peakOf(rttValues), 2)
  readonly property real rxCeil: niceMax(peakOf(rxValues), 10000)
  readonly property bool hasRx: peakOf(rxValues) > 0
  readonly property string hoverText: tipAt(hoverIndex)

  function num(v) {
    var n = Number(v)
    return isFinite(n) ? n : 0
  }

  function peakOf(arr) {
    var peak = 0
    if (!arr) return 0
    for (var i = 0; i < arr.length; i++) {
      if (arr[i] == null) continue
      var v = Number(arr[i])
      if (isFinite(v) && v > peak) peak = v
    }
    return peak
  }

  function niceMax(v, floor) {
    var n = Math.max(floor, num(v) * 1.15)
    if (!isFinite(n) || n <= 0) n = floor
    var p = Math.pow(10, Math.floor(Math.log(n) / Math.LN10))
    var f = n / p
    return (f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10) * p
  }

  function fmtRate(bps) {
    var v = Number(bps)
    if (!isFinite(v) || v < 0) return ""
    if (v < 1000) return Math.round(v) + "B"
    if (v < 1000000) return Math.round(v / 1000) + "k"
    return (v / 1000000).toFixed(1) + "M"
  }

  function tipAt(i) {
    if (i < 0 || i >= spark.n) return ""
    var bits = []
    var rtt = i < rttValues.length ? rttValues[i] : null
    var rx = i < rxValues.length ? rxValues[i] : null
    if (rtt == null) bits.push("no ping")
    else bits.push((Number(rtt) < 10 ? Number(rtt).toFixed(1) : Math.round(Number(rtt))) + " ms")
    if (rx != null) bits.push("↓" + spark.fmtRate(rx))
    return bits.join("  ·  ")
  }

  function xFor(i) {
    if (spark.n <= 1) return width / 2
    return 1 + (width - 2) * i / (spark.n - 1)
  }

  function applyPayload(raw) {
    var data = {}
    try { data = JSON.parse(raw || "{}") || {} } catch (e) { data = {} }
    spark.rttValues = data.values instanceof Array ? data.values : []
    spark.rxValues = data.rx_bps instanceof Array ? data.rx_bps : []
    spark.hoverIndex = -1
    graph.requestPaint()
  }

  // Series arrive from the snapshot, which the collector already builds in one
  // pass over the history it is holding anyway. This component used to launch a
  // Python process every four seconds, per row, and re-parse the whole history
  // file each time: roughly ten processes a second on a forty-row lab, to draw
  // some lines. It now renders what it is given and spawns nothing.
  property var series: null

  function applySeries() {
    var s = spark.series
    if (!s) {
      spark.rttValues = []
      spark.rxValues = []
    } else {
      spark.rttValues = s.values instanceof Array ? s.values : []
      spark.rxValues = s.rx_bps instanceof Array ? s.rx_bps : []
    }
    spark.hoverIndex = -1
    graph.requestPaint()
  }

  onSeriesChanged: spark.applySeries()
  onNodeIdChanged: spark.applySeries()
  onWidthChanged: graph.requestPaint()
  onHeightChanged: graph.requestPaint()
  Component.onCompleted: spark.applySeries()

  Canvas {
    id: graph
    anchors.fill: parent
    onPaint: {
      var c = getContext("2d")
      var w = width
      var h = height
      c.reset()
      c.clearRect(0, 0, w, h)
      function yAt(v, ceil) {
        if (ceil <= 0) return h - 1
        var t = v / ceil
        if (t < 0) t = 0
        if (t > 1) t = 1
        return 1 + (h - 2) * (1 - t)
      }
      function trace(arr, ceil, style, widthPx, dashed) {
        if (!arr || !arr.length) return
        c.lineWidth = widthPx
        c.strokeStyle = style
        c.setLineDash(dashed ? [2, 2] : [])
        c.beginPath()
        var pen = false
        var i, v
        for (i = 0; i < arr.length; i++) {
          if (arr[i] == null) { pen = false; continue }
          v = Number(arr[i])
          if (!isFinite(v)) { pen = false; continue }
          var x = spark.xFor(i)
          var y = yAt(v, ceil)
          if (!pen) c.moveTo(x, y)
          else c.lineTo(x, y)
          pen = true
        }
        c.stroke()
        c.setLineDash([])
      }
      if (spark.hasRx)
        trace(spark.rxValues, spark.rxCeil, Qt.alpha(spark.rateStroke, 0.7), 1, true)
      trace(spark.rttValues, spark.rttCeil, spark.stroke, 1.4, false)
      var last = -1
      var i
      for (i = spark.rttValues.length - 1; i >= 0; i--) {
        if (spark.rttValues[i] != null) { last = i; break }
      }
      if (last >= 0) {
        c.fillStyle = spark.stroke
        c.beginPath()
        c.arc(spark.xFor(last), yAt(Number(spark.rttValues[last]), spark.rttCeil), 2, 0, Math.PI * 2)
        c.fill()
      }
    }
  }

  Rectangle {
    visible: spark.hoverIndex >= 0
    x: spark.hoverIndex >= 0 ? spark.xFor(spark.hoverIndex) : 0
    y: 0
    width: 1
    height: parent.height
    color: spark.muted
  }

  PanelToolTip {
    visible: spark.hoverIndex >= 0 && spark.hoverText !== ""
    delay: 0
    text: spark.hoverText
    fontFamily: spark.fontFamily
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onExited: spark.hoverIndex = -1
    onPositionChanged: function(mouse) {
      if (spark.n <= 0) { spark.hoverIndex = -1; return }
      var i = Math.round((mouse.x - 1) / Math.max(1, width - 2) * (spark.n - 1))
      if (i < 0) i = 0
      if (i >= spark.n) i = spark.n - 1
      spark.hoverIndex = i
    }
  }
}
