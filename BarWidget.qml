import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

// Bar face for `hypr-layout-preset`. All the compositor knowledge lives in that
// script; this reads its JSON and turns clicks back into its subcommands, so
// the widget and the CLI can never drift apart on what a preset means.
BarWidget {
  id: root
  moduleName: "cromewar.ultrawide-layouts"

  // Resolved next to this file rather than from a fixed path, so the plugin
  // runs from wherever `omarchy plugin add` cloned it. Process wants a
  // filesystem path, and resolvedUrl hands back a file:// URL.
  readonly property string helper: Qt.resolvedUrl("bin/hypr-layout-preset").toString().replace(/^file:\/\//, "")

  property var presets: []
  property var state: ({})
  property bool popupOpen: false

  readonly property string presetKey: state.key || ""
  readonly property string presetIcon: state.icon || "󱂬"
  readonly property string presetLabel: state.label || ""
  readonly property string geometry: state.geometry || ""
  readonly property string monitorName: state.monitor || ""
  readonly property int workspaceId: state.workspace || 0
  readonly property int monitorWidth: state.width || 0
  readonly property bool isMaster: state.layout === "master"
  // False once a manual resize has pulled the master off the preset's own
  // ratio. Worth showing, because that is the state the snap action undoes.
  readonly property bool snapped: state.snapped === true

  readonly property real mfactStep: {
    var v = Number(setting("mfactStep", 0.025))
    return isFinite(v) && v > 0 ? v : 0.025
  }
  readonly property bool showLabel: setting("showLabel", false) === true

  // open/close/opened on the widget root is the shape Bar.findPanelWidget looks
  // for, so `omarchy-shell shell toggle cromewar.ultrawide-layouts '{}'` reaches the
  // picker and a keybinding can open it without the mouse.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  // One action process, reused. A click that lands while the previous one is
  // still running is dropped rather than queued: the actions are all absolute
  // ("set thirds"), so a dropped one leaves no half-applied state behind, and
  // the refresh that follows re-reads whatever actually happened.
  function act(args) {
    if (actionProc.running) return
    actionProc.command = [root.helper].concat(args)
    actionProc.running = true
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  Component.onCompleted: {
    listProc.running = true
    refresh()
  }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.state = JSON.parse(text || "{}")
        } catch (e) {
          root.state = ({})
        }
      }
    }
  }

  // The preset catalogue carries the widths each one gives on the focused
  // monitor, so it is re-read whenever the focus moves to a different screen
  // rather than only at startup.
  Process {
    id: listProc
    command: [root.helper, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text || "[]")
          root.presets = Array.isArray(parsed) ? parsed : []
        } catch (e) {
          root.presets = []
        }
      }
    }
  }

  Process {
    id: actionProc
    onExited: {
      root.refresh()
      if (!listProc.running) listProc.running = true
    }
  }

  // Hyprland recalculates the layout before it emits these, so a refresh on the
  // event reads the settled geometry rather than the one being replaced.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      switch (String(event.name)) {
      case "workspace":
      case "workspacev2":
      case "focusedmon":
      case "focusedmonv2":
      case "openwindow":
      case "closewindow":
      case "movewindow":
      case "movewindowv2":
      case "configreloaded":
        settle.restart()
        break
      }
    }
  }

  // A burst of events (closing a window moves every other one) would otherwise
  // spawn a hyprctl chain per event.
  Timer {
    id: settle
    interval: 90
    onTriggered: {
      root.refresh()
      if (!listProc.running) listProc.running = true
    }
  }

  implicitWidth: face.implicitWidth
  implicitHeight: face.implicitHeight

  WidgetButton {
    id: face
    anchors.fill: parent
    bar: root.bar
    text: root.showLabel && !root.vertical && root.presetLabel !== ""
      ? root.presetIcon + "  " + root.presetLabel
      : root.presetIcon
    fontSize: root.showLabel && !root.vertical ? Style.font.body : Style.font.icon
    horizontalMargin: 7
    active: root.popupOpen
    // The popup is the detail view; a tooltip on top of it would fight it.
    tooltipText: root.popupOpen ? "" : (
      root.presetLabel
        + (root.geometry !== "" ? "   " + root.geometry : "")
        + (root.snapped ? "" : "   (resized)"))

    onPressed: function(button) {
      if (button === Qt.RightButton) root.act(["next"])
      else if (button === Qt.MiddleButton) root.act(["snap"])
      else root.popupOpen = !root.popupOpen
    }

    onWheelMoved: function(delta) {
      if (!root.isMaster) return
      root.act([delta > 0 ? "wider" : "narrower", String(root.mfactStep)])
    }
  }

  PopupCard {
    id: popup
    anchorItem: face
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(350))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      width: parent.width
      spacing: Style.spacing.sm

      Text {
        width: parent.width
        text: root.workspaceId > 0
          ? "Workspace " + root.workspaceId + " · " + root.monitorName
            + (root.monitorWidth > 0 ? " · " + root.monitorWidth + "px" : "")
          : "No focused workspace"
        color: Color.muted
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Repeater {
        model: root.presets

        BorderSurface {
          id: row

          required property var modelData

          readonly property bool current: modelData.key === root.presetKey

          width: column.width
          implicitHeight: Math.max(Style.spacing.popupRowHeight, rowContent.implicitHeight + Style.spacing.sm * 2)
          radius: Style.cornerRadius
          leftPadding: Style.spacing.sm
          rightPadding: Style.spacing.sm

          readonly property color tint: current
            ? (root.bar ? root.bar.urgent : Color.urgent)
            : (root.bar ? root.bar.foreground : Color.foreground)

          color: rowMouse.containsMouse
            ? Style.hoverFillFor(tint, Color.accent)
            : (current ? Style.normalFillFor(tint, Color.accent) : "transparent")
          borderSpec: current
            ? Border.controlSpec("normal", tint, tint)
            : Border.none()

          Behavior on color { ColorAnimation { duration: 60 } }

          // Anchored rather than a Row with fixed column widths: label length
          // and font size both vary by theme, and a fixed label column clips
          // "Center master" on any theme with a larger base size. The geometry
          // is right-aligned into whatever is left, so the numbers still line
          // up down the list.
          Item {
            id: rowContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.sm
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: Math.max(rowIcon.implicitHeight, rowLabel.implicitHeight)
            height: implicitHeight

            Text {
              id: rowIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20)
              horizontalAlignment: Text.AlignHCenter
              text: row.modelData.icon
              color: row.tint
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.icon
            }

            Text {
              id: rowLabel
              anchors.left: rowIcon.right
              anchors.leftMargin: Style.spacing.controlGap
              anchors.verticalCenter: parent.verticalCenter
              text: row.modelData.label
              color: row.tint
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              anchors.left: rowLabel.right
              anchors.leftMargin: Style.spacing.controlGap
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              horizontalAlignment: Text.AlignRight
              text: row.modelData.geometry
              color: row.current ? row.tint : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideLeft
            }
          }

          MouseArea {
            id: rowMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              // Re-picking the current preset is the snap gesture: it puts a
              // master that has been dragged out of shape back on its ratio.
              root.act(["set", row.modelData.key])
              root.popupOpen = false
            }
          }
        }
      }

      // Only the master layouts have a master column to size, so the stepper
      // stays out of the way under dwindle and scrolling.
      Item {
        width: parent.width
        height: root.isMaster ? stepper.implicitHeight + Style.spacing.sm : 0
        visible: root.isMaster
        clip: true

        Row {
          id: stepper
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.controlGap

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅁"
            tooltipText: "Narrower centre"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            bordered: true
            onClicked: root.act(["narrower", String(root.mfactStep)])
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(120)
            horizontalAlignment: Text.AlignHCenter
            text: root.geometry
            color: root.snapped
              ? (root.bar ? root.bar.foreground : Color.foreground)
              : Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅂"
            tooltipText: "Wider centre"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            bordered: true
            onClicked: root.act(["wider", String(root.mfactStep)])
          }
        }
      }
    }
  }
}
