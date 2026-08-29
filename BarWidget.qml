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
  readonly property string helper: decodeURIComponent(Qt.resolvedUrl("bin/hypr-layout-preset").toString().replace(/^file:\/\//, ""))

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
  readonly property bool locked: state.locked === true
  readonly property bool lockSupported: state.lockSupported === true
  readonly property bool setupPresent: state.setupPresent === true
  readonly property string lockReason: state.lockReason || ""
  readonly property int dynamicZone: state.dynamicZone || 0
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

  // One action process, reused.
  //
  // Absolute actions ("set thirds") coalesce to the last one asked for - an
  // earlier one is worth nothing once a newer one has arrived. Scroll notches
  // are different: they are relative, so dropping them loses distance the user
  // asked for. A wheel flick outruns the helper easily, so notches accumulate
  // and are spent as one larger step when the process frees up.
  property var pendingAction: null
  property int pendingNotches: 0

  function act(args) {
    if (actionProc.running) {
      root.pendingAction = args
      return
    }
    actionProc.command = [root.helper].concat(args)
    actionProc.running = true
  }

  function scrollBy(notches) {
    root.pendingNotches += notches
    root.flushScroll()
  }

  function flushScroll() {
    if (actionProc.running || root.pendingNotches === 0) return
    var n = root.pendingNotches
    root.pendingNotches = 0
    root.act([n > 0 ? "wider" : "narrower", (Math.abs(n) * root.mfactStep).toFixed(4)])
  }

  // A settle that lands while a status read is already in flight must not be
  // thrown away: it is usually the last one, describing the arrangement that
  // actually stuck. Dropping it is why the bar could sit showing the previous
  // preset after a fast `next`.
  property bool pendingRefresh: false

  function refresh() {
    if (statusProc.running) {
      root.pendingRefresh = true
      return
    }
    statusProc.running = true
  }

  // The preset catalogue only depends on which monitor the focused workspace is
  // on and how wide it is, so it is rebuilt when that changes rather than on
  // every window event.
  property string listedFor: ""

  function refreshList() {
    var signature = root.monitorName + "@" + root.monitorWidth
    if (listProc.running || signature === root.listedFor) return
    root.listedFor = signature
    listProc.running = true
  }

  Component.onCompleted: refresh()

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
        // Monitor and width are only known once status has been read.
        root.refreshList()
      }
    }
    onExited: {
      if (root.pendingRefresh) {
        root.pendingRefresh = false
        restatus.restart()
      }
    }
  }

  // Same reason as `drain`: a Process cannot be restarted from inside its own
  // onExited.
  Timer {
    id: restatus
    interval: 0
    onTriggered: root.refresh()
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
    // Deferred by a tick: restarting the same Process from inside its own
    // onExited is not safe.
    onExited: {
      root.refresh()
      if (root.pendingNotches !== 0 || root.pendingAction) drain.restart()
    }
  }

  // Scroll first - it is the gesture with a finger still on it. A queued
  // absolute action is spent afterwards, and only the newest one survives.
  Timer {
    id: drain
    interval: 0
    onTriggered: {
      if (root.pendingNotches !== 0) {
        root.flushScroll()
        return
      }
      if (root.pendingAction) {
        var next = root.pendingAction
        root.pendingAction = null
        root.act(next)
      }
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
      // A fullscreen window makes the layout unmeasurable, floating a window
      // removes it from the column set, and the monitor set changes the widths
      // the picker advertises. All three left the widget showing stale numbers.
      case "fullscreen":
      case "changefloatingmode":
      case "monitoradded":
      case "monitoraddedv2":
      case "monitorremoved":
        settle.restart()
        break
      }
    }
  }

  // A burst of events (closing a window moves every other one) would otherwise
  // spawn a hyprctl chain per event. 120ms rather than 90: Hyprland is still
  // settling the reflow at 90 on a busy workspace, and reading it mid-reflow is
  // what made the bar flicker through an intermediate arrangement.
  Timer {
    id: settle
    interval: 120
    onTriggered: root.refresh()
  }

  implicitWidth: barControls.implicitWidth
  implicitHeight: barControls.implicitHeight

  Grid {
    id: barControls
    columns: root.vertical ? 1 : 2
    spacing: 0

    WidgetButton {
      id: face
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
          + (root.locked ? "   Locked" : (root.snapped ? "" : "   (resized)")))

      onPressed: function(button) {
        if (button === Qt.RightButton) root.act(["next"])
        else if (button === Qt.MiddleButton) {
          if (!root.locked) root.act(["snap"])
        }
        else root.popupOpen = !root.popupOpen
      }

      onWheelMoved: function(delta) {
        if (!root.isMaster || root.locked) return
        root.scrollBy(delta > 0 ? 1 : -1)
      }
    }

    // Always visible, so both the current state and the toggle affordance are
    // obvious without opening the preset picker.
    WidgetButton {
      id: lockFace
      bar: root.bar
      text: root.locked ? "󰌾" : "󰌿"
      fontSize: Style.font.icon
      horizontalMargin: 5
      active: root.locked
      dimmed: !root.locked
      interactive: root.locked || root.lockSupported
      tooltipText: root.locked
        ? "Window positions locked · click to unlock"
        : (root.lockSupported ? "Lock window positions" : root.lockReason)
      onPressed: function(button) {
        if (button === Qt.LeftButton) root.act(["toggle-lock"])
      }
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

      Toggle {
        id: lockToggle
        width: parent.width
        label: "Lock window positions"
        description: root.locked
          ? "On · column " + (root.dynamicZone > 0 ? root.dynamicZone : "?") + " accepts new windows"
          : (root.lockSupported ? "Off · keep empty slots when windows close" : root.lockReason)
        checked: root.locked
        enabled: root.locked || root.lockSupported
        opacity: enabled ? 1 : 0.5
        foreground: root.bar ? root.bar.foreground : Color.foreground
        accent: root.bar ? root.bar.urgent : Color.urgent
        onClicked: root.act(["toggle-lock"])
      }

      Item {
        width: parent.width
        height: root.locked ? lockActions.implicitHeight : 0
        visible: root.locked
        clip: true

        Row {
          id: lockActions
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.spacing.controlGap

          Button {
            text: "Recapture"
            iconText: "󰑓"
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.act(["recapture-lock"])
          }

          Button {
            text: "Focused column is dynamic"
            iconText: "󰓫"
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.act(["dynamic-focused"])
          }
        }
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
        height: root.isMaster && !root.locked ? stepper.implicitHeight + Style.spacing.sm : 0
        visible: root.isMaster && !root.locked
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
            onClicked: root.scrollBy(-1)
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
            onClicked: root.scrollBy(1)
          }
        }
      }
    }
  }
}
