import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Googlebook VM controls in the Omarchy menu. Keyboard first:
// U setup, S start, X stop, K K force stop, F shared folder, L log, B rebuild, Esc.
// Talks only to `googlebook-vm status --json` and `googlebook-vm <cmd>`.
// Polls every 2 s while open; nothing runs while closed.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property var targetScreen: null

  // Last status; notFound means the command is missing or its output is not JSON.
  property bool notFound: false
  property string vmState: ""
  property string step: ""
  property string share: ""
  property string shareMode: "off"
  property bool killArmed: false
  property bool erasePrompt: false

  readonly property color foreground: Color.menu.text
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color okColor: "#2ecc71"
  readonly property color busyColor: "#f39c12"

  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (screens[i].name === name) return screens[i]
    return null
  }

  function refresh() { if (!statusProc.running) statusProc.running = true }

  function open(payloadJson) {
    targetScreen = focusedScreen()
    killArmed = false
    erasePrompt = false
    refresh()
    opened = true
    Qt.callLater(function() { keyScope.forceActiveFocus() })
  }

  function close() { opened = false }
  function toggle() { if (opened) close(); else open("{}") }

  // Which keys are offered in the current state. Keys and buttons share this.
  function can(k) {
    if (root.notFound || root.vmState === "unsupported-cpu") return false
    var s = root.vmState
    switch (k) {
    case "U": return s === "unconfigured" || s === "setup-failed"
    case "S": return (s === "stopped" || s === "failed") && root.share === ""
    case "X":
    case "K": return s === "running"
    case "B": return s === "stopped"
    case "F": return root.share !== "" && root.shareMode !== "off"
    case "L": return s !== "unconfigured"
    case "D": return root.share !== ""
    }
    return false
  }

  function run(key) {
    var k = key.toUpperCase()
    if (!root.can(k)) return
    switch (k) {
    case "U": Quickshell.execDetached(["googlebook-vm", "setup"]); break
    case "S": Quickshell.execDetached(["googlebook-vm", "start"]); break
    case "X": Quickshell.execDetached(["googlebook-vm", "stop"]); break
    case "K":
      if (root.killArmed) {
        root.killArmed = false
        killTimer.stop()
        Quickshell.execDetached(["googlebook-vm", "kill"])
      } else {
        root.killArmed = true
        killTimer.restart()
      }
      return
    case "F": Quickshell.execDetached(["gio", "open", root.share]); close(); return
    case "D": Quickshell.execDetached(["googlebook-vm", "files", "--done"]); break
    case "L":
      Quickshell.execDetached(["googlebook-vm", "log", root.vmState === "running" ? "serial" : "setup"])
      close()
      return
    case "B":
      eraseField.text = ""
      root.erasePrompt = true
      Qt.callLater(function() { eraseField.forceActiveFocus() })
      return
    }
    root.killArmed = false
    Qt.callLater(root.refresh)
  }

  function subtitle() {
    if (root.notFound) return "googlebook-vm not found"
    switch (root.vmState) {
    case "unsupported-cpu": return "Unsupported CPU"
    case "unconfigured": return "Not set up"
    case "setting-up": return "Setting up" + (root.step !== "" ? "  •  " + root.step : "")
    case "setup-failed": return "Setup failed" + (root.step !== "" ? "  •  " + root.step : "")
    case "stopped": return "Stopped"
    case "running": return "Running"
    case "failed": return "Stopped after a failure"
    }
    return "…"
  }

  function badgeText() {
    if (root.notFound) return "OFF"
    return root.vmState === "" ? "…" : root.vmState.toUpperCase()
  }

  Process {
    id: statusProc
    command: ["googlebook-vm", "status", "--json"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var j = JSON.parse(text)
          root.vmState = String(j.state || "")
          root.step = String(j.step || "")
          root.share = String(j.share || "")
          root.shareMode = String(j.shareMode || "off")
          root.notFound = root.vmState === ""
        } catch (e) {
          root.notFound = true
        }
      }
    }
    onExited: function(code) { if (code !== 0) root.notFound = true }
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  Timer {
    id: killTimer
    interval: 3000
    onTriggered: root.killArmed = false
  }

  // One action button; hidden when the key is not offered in this state.
  component Action: Button {
    id: act
    property string key: ""
    visible: root.can(act.key)
    width: parent.width
    leftAlign: true
    bordered: true
    fontFamily: Style.font.family
    fontSize: Style.font.body
    onClicked: root.run(act.key)
  }

  PanelWindow {
    id: panel
    visible: root.opened
    screen: root.targetScreen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore

    WlrLayershell.namespace: "nixarchy-googlebook-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    onVisibleChanged: if (visible) Qt.callLater(function() { keyScope.forceActiveFocus() })

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    // ponytail: extra dim; some themes ship an almost transparent menu scrim.
    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.45) }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(420), Math.round(panel.width * 0.9))
      height: Math.min(content.implicitHeight + card.contentTopInset + card.contentBottomInset,
                      Math.round(panel.height * 0.9))
      anchors.centerIn: parent
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18), 1)
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      FocusScope {
        id: keyScope
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
            return
          }
          if (event.modifiers === Qt.NoModifier && !root.erasePrompt) {
            var text = event.text.toUpperCase()
            if (["U", "S", "X", "K", "F", "D", "L", "B"].indexOf(text) !== -1) {
              root.run(text)
              event.accepted = true
            }
          }
        }

        Column {
          id: content
          width: keyScope.width
          spacing: Style.space(12)

          // Header: title, state subtitle, status pill
          Item {
            width: parent.width
            height: Math.max(headerText.implicitHeight, badge.implicitHeight)

            Column {
              id: headerText
              anchors.left: parent.left
              anchors.right: badge.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Googlebook VM"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                width: parent.width
                text: root.subtitle()
                color: root.dim
                elide: Text.ElideRight
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            BorderSurface {
              id: badge
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              implicitHeight: Style.space(26)
              implicitWidth: badgeRow.implicitWidth + Style.space(16)
              color: "transparent"
              borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
              radius: Style.cornerRadius

              Row {
                id: badgeRow
                anchors.centerIn: parent
                spacing: Style.space(6)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: root.vmState === "running" ? root.okColor
                       : root.vmState === "setting-up" ? root.busyColor
                       : (root.vmState === "failed" || root.vmState === "setup-failed") ? Color.urgent : root.dim
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.badgeText()
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }
          }

          Text {
            visible: root.notFound
            width: parent.width
            text: "googlebook-vm not found: enable programs.googlebook-vm"
            color: root.foreground
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            visible: root.vmState === "unsupported-cpu"
            width: parent.width
            text: "This CPU can't run the Googlebook image: it needs GFNI and VAES (Intel 11th gen or newer, AMD Zen 4 or newer)."
            color: root.foreground
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          // Shared folder path and mode
          Text {
            visible: !root.notFound && root.share !== ""
            width: parent.width
            text: "Shared folder: " + root.share + "  (" + root.shareMode + ")"
            color: root.dim
            elide: Text.ElideMiddle
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: !root.notFound && root.share !== ""
            width: parent.width
            text: "Shared drive is open on the host: press D to release it"
            color: root.foreground
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: !root.notFound && root.shareMode === "usb"
            width: parent.width
            text: "Shared drive is not live: open it with googlebook-vm files while the VM is stopped"
            color: root.dim
            wrapMode: Text.Wrap
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Column {
            visible: !root.notFound
            width: parent.width
            spacing: Style.space(6)

            Action { key: "U"; text: "Set up the VM [U]" }
            Action { key: "S"; text: "Start [S]" }
            Action { key: "X"; text: "Stop (shut down Android) [X]" }
            Action {
              key: "K"
              text: root.killArmed ? "Press K again to force stop" : "Force stop [K K]"
              foreground: root.killArmed ? Color.urgent : root.foreground
            }
            Action { key: "F"; text: "Open shared folder [F]" }
            Action { key: "D"; text: "Release shared drive [D]" }
            Action { key: "L"; text: (root.vmState === "running" ? "Serial log" : "Setup log") + " [L]" }
            Action { key: "B"; text: "Rebuild (erases Android's data) [B]" }
          }

          // Rebuild confirmation: runs only on the exact text "erase".
          Column {
            visible: root.erasePrompt && root.can("B")
            width: parent.width
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: "Rebuilding erases everything saved in Android. Type erase and press Enter, or Esc to cancel."
              color: Color.urgent
              wrapMode: Text.Wrap
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            TextField {
              id: eraseField
              width: parent.width
              placeholderText: "erase"
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.erasePrompt = false
                  keyScope.forceActiveFocus()
                  event.accepted = true
                }
              }
              onAccepted: {
                if (text === "erase") {
                  Quickshell.execDetached(["googlebook-vm", "rebuild"])
                  root.erasePrompt = false
                  keyScope.forceActiveFocus()
                  Qt.callLater(root.refresh)
                }
              }
            }
          }

          Text {
            width: parent.width
            text: "Esc closes"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
