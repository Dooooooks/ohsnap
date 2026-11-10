import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// OhSnap, shell side.
//
// 1. A click-through outline over the spot a dragged window will snap to.
//    ohsnap.lua (loaded into Hyprland) calls:
//      omarchy-shell ohsnap show <monitor> <x> <y> <w> <h>   (monitor-relative, logical px)
//      omarchy-shell ohsnap hide
// 2. Runs ohsnap-watch, which reports the mouse release so windows snap the
//    instant they are dropped. It needs the `input` group; without it, it exits
//    with 77 and snapping falls back to the next mouse movement.
Item {
  id: root

  property var shell: null

  property string monitor: ""
  property bool shown: false
  property rect box: Qt.rect(0, 0, 0, 0)

  ShellIpc {
    target: "ohsnap"
    function show(monitor: string, x: int, y: int, w: int, h: int): string {
      root.monitor = monitor
      root.box = Qt.rect(x, y, Math.max(0, w), Math.max(0, h))
      root.shown = true
      return "ok"
    }
    function hide(): string { root.shown = false; return "ok" }
    function ping(): string { return "ok" }
    function watcher(): string { return watch.running ? "running" : (root.watcherDisabled ? "no-permission" : "stopped") }
  }

  // ---- Mouse-release watcher ------------------------------------------------
  readonly property string watcherPath: decodeURIComponent(String(Qt.resolvedUrl("ohsnap-watch")).replace(/^file:\/\//, ""))
  property bool watcherDisabled: false

  Process {
    id: watch
    command: [root.watcherPath]
    running: true
    onExited: function(exitCode, exitStatus) {
      // 77: no access to the mouse; trying again won't help until re-login.
      if (exitCode === 77) root.watcherDisabled = true
      else restartWatch.restart()
    }
  }

  Timer {
    id: restartWatch
    interval: 3000
    onTriggered: if (!root.watcherDisabled) watch.running = true
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      readonly property bool active: root.shown && modelData.name === root.monitor

      screen: modelData
      // Stay mapped for a moment after hiding so the fade-out can play.
      visible: active || outline.opacity > 0
      anchors { top: true; left: true; bottom: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      WlrLayershell.namespace: "omarchy-snap-preview"
      // Visual only: never take clicks or the drag away from the window.
      mask: Region {}

      Rectangle {
        id: outline
        readonly property int inset: Style.space(6)

        x: root.box.x + inset
        y: root.box.y + inset
        width: Math.max(0, root.box.width - 2 * inset)
        height: Math.max(0, root.box.height - 2 * inset)
        radius: Style.cornerRadius
        color: Util.alpha(Commons.Color.accent, 0.18)
        border.color: Util.alpha(Commons.Color.accent, 0.85)
        border.width: Math.max(2, Style.space(2))

        opacity: win.active ? 1 : 0
        scale: win.active ? 1 : 0.97

        Behavior on opacity { NumberAnimation { duration: Style.duration(win.active ? 160 : 110); easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: Style.duration(160); easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut } }
        Behavior on x { enabled: win.active && outline.opacity > 0.99; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
        Behavior on y { enabled: win.active && outline.opacity > 0.99; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
        Behavior on width { enabled: win.active && outline.opacity > 0.99; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
        Behavior on height { enabled: win.active && outline.opacity > 0.99; NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      }
    }
  }
}
