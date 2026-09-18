import QtQuick
import qs.Commons
import qs.Ui

// Image-based sibling of PanelActionButton for the bundled Zed/Herdr
// SVG logos, which have no Nerd Font glyphs. Same box, hover fill,
// tooltip, and enabled gating as PanelActionButton; the image itself
// is rendered as-is (sourceSize keeps the raster crisp on hidpi).
BorderSurface {
  id: root

  property string iconSource: ""
  property string tooltipText: ""
  property color foreground: Color.foreground
  property color hoverColor: foreground
  property string fontFamily: Style.font.family
  property real size: Style.space(22)

  property bool focusable: false

  signal clicked()

  activeFocusOnTab: focusable
  Keys.onReturnPressed: if (focusable) root.clicked()
  Keys.onEnterPressed: if (focusable) root.clicked()
  Keys.onSpacePressed: if (focusable) root.clicked()

  implicitWidth: size
  implicitHeight: size
  radius: Style.cornerRadius

  readonly property bool _showFocusRing: focusable && activeFocus
  readonly property bool _hot: mouse.containsMouse && root.enabled

  color: _showFocusRing
    ? Style.focusFillFor(hoverColor, hoverColor)
    : (_hot
      ? Style.hoverFillFor(hoverColor, hoverColor)
      : "transparent")
  borderSpec: _showFocusRing ? Border.controlSpec("focus", hoverColor, hoverColor) : Border.none()

  Behavior on color { ColorAnimation { duration: 60 } }

  Image {
    anchors.centerIn: parent
    source: root.iconSource
    width: root.size - Style.space(8)
    height: root.size - Style.space(8)
    fillMode: Image.PreserveAspectFit
    smooth: true
    mipmap: true
    sourceSize.width: 88
    sourceSize.height: 88
    opacity: root.enabled ? 1.0 : 0.4
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    enabled: root.enabled
    onClicked: {
      if (root.focusable) root.forceActiveFocus()
      root.clicked()
    }
  }

  PanelToolTip {
    visible: root.tooltipText !== "" && mouse.containsMouse
    text: root.tooltipText
    fontFamily: root.fontFamily
  }
}
