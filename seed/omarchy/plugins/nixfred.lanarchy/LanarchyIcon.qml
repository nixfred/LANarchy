import QtQuick
import QtQuick.Shapes

// Castle socket: battlements around an Ethernet-shaped gate.
// Theme-recolorable Shape from assets/castle-socket (64×64 viewBox).
Item {
  id: root
  property real iconSize: width > 0 ? width : 16
  property color color: "#c0caf5"
  property color alert: "#f7768e"
  property bool alarmed: false
  property bool active: false

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property color ink: root.alarmed ? root.alert : root.color

  Shape {
    id: mark
    width: 64
    height: 64
    anchors.centerIn: parent
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer
    opacity: root.active ? 1 : 0.88
    transform: Scale {
      origin.x: 32
      origin.y: 32
      xScale: root.iconSize / 64
      yScale: root.iconSize / 64
    }

    ShapePath {
      fillColor: root.ink
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill
      PathSvg {
        path: "M8 8H18V16H26V8H38V16H46V8H56V48L60 56H4L8 48ZM18 27V47H25V53H39V47H46V27H41V39H37V27H34V41H30V27H27V39H23V27Z"
      }
    }
  }

  SequentialAnimation on opacity {
    running: root.active && !root.alarmed
    loops: Animation.Infinite
    NumberAnimation { to: 0.72; duration: 1100; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1; duration: 1100; easing.type: Easing.InOutSine }
  }
}
