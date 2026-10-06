// SPDX-License-Identifier: GPL-2.0-or-later
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cellular modem widget: bar icon with LTE signal bars, plus a popup with
// operator, registration, LTE signal (RSRP/RSRQ/SNR), the IP address, and a
// mobile data switch. State comes from bin/lte-status (mmcli + nmcli);
// the switch brings the NetworkManager GSM profile up or down.
Panel {
  id: root
  moduleName: "xmm7360.lte"
  ipcTarget: "xmm7360.lte"

  property var info: ({ present: false })
  property bool busy: false
  property string lastError: ""

  readonly property int refreshSec: Math.max(3, Number(setting("refreshIntervalSec", 10)) || 10)
  readonly property bool hideWithoutModem: setting("hideWithoutModem", true) !== false
  readonly property bool present: info.present === true
  readonly property bool connected: info.state === "connected"
  readonly property bool shown: present || !hideWithoutModem
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/lte-status").toString().replace(/^file:\/\//, ""))

  // Nerd Font cellular glyphs: outline (no signal), then 1-3 bars.
  function signalIcon() {
    if (!present || !connected && info.registration !== "home" && info.registration !== "roaming") return String.fromCodePoint(0xf08bf)
    var q = info.quality
    if (q === null || q === undefined) return String.fromCodePoint(0xf08be)
    if (q >= 60) return String.fromCodePoint(0xf08be)
    if (q >= 30) return String.fromCodePoint(0xf08bd)
    return String.fromCodePoint(0xf08bc)
  }

  function techLabel() {
    var t = String(info.accessTech || "")
    if (t.indexOf("lte") >= 0) return "LTE"
    if (t.indexOf("umts") >= 0 || t.indexOf("hspa") >= 0) return "3G"
    if (t.indexOf("gsm") >= 0 || t.indexOf("edge") >= 0 || t.indexOf("gprs") >= 0) return "2G"
    return t ? t.toUpperCase() : ""
  }

  function stateLabel() {
    if (!present) return "No modem"
    if (busy) return connected ? "Disconnecting…" : "Connecting…"
    var s = String(info.state || "")
    if (s === "failed") return "Failed (" + (info.failedReason || "unknown") + ")"
    return s ? s.charAt(0).toUpperCase() + s.slice(1) : "Unknown"
  }

  function fmt(value, unit) {
    return value === null || value === undefined ? "—" : value + " " + unit
  }

  function tooltip() {
    if (!present) return "No cellular modem"
    var parts = [info.operator && info.operator !== "--" ? info.operator : "No network"]
    if (techLabel()) parts.push(techLabel())
    if (info.rsrp !== null && info.rsrp !== undefined) parts.push(info.rsrp + " dBm")
    parts.push(connected ? "connected" : String(info.state || ""))
    return parts.join(" · ")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // Mobile data on/off also flips the profile's autoconnect flag, so the
  // choice survives a reboot (NetworkManager would otherwise bring an
  // autoconnect profile back up at boot).
  function setData(on) {
    if (busy || !info.connection) return
    busy = true
    lastError = ""
    actionProc.command = ["bash", "-c",
      'nmcli connection modify id "$1" connection.autoconnect "$2" || echo "Couldn\'t save the autoconnect setting" >&2; ' +
      'nmcli --wait 60 connection "$3" id "$1"',
      "lte-data", info.connection, on ? "yes" : "no", on ? "up" : "down"]
    actionProc.running = true
  }

  function toggleData() { setData(!info.active) }

  // ---------- Speed test over the modem interface ----------
  property bool stOpen: false
  property bool stRunning: false
  property bool stExpectedStop: false
  property bool stPendingRun: false
  property string stPhase: ""        // "down" | "up" | ""
  property string stStderr: ""
  property real stDown: 0
  property real stUp: 0
  property string stError: ""
  readonly property string speedtestPath: decodeURIComponent(Qt.resolvedUrl("bin/lte-speedtest").toString().replace(/^file:\/\//, ""))
  readonly property bool canRunSpeedTest: connected && !!info.interface

  function openSpeedTest() {
    close()
    stOpen = true
    runSpeedTest()
  }

  function closeSpeedTest() {
    stOpen = false
    stPendingRun = false
    stPhaseTimer.stop()
    stPhase = ""
    stRunning = false
    if (speedTestProc.running) {
      stExpectedStop = true
      speedTestProc.running = false
    }
  }

  function runSpeedTest() {
    if (speedTestProc.running) {
      if (stExpectedStop) stPendingRun = true
      return
    }
    stError = ""
    stDown = 0
    stUp = 0
    stRunning = true
    startPhase("down")
  }

  function startPhase(next) {
    stExpectedStop = false
    stPhase = next
    stStderr = ""
    speedTestProc.command = [speedtestPath, next, info.interface || "wwan0"]
    speedTestProc.running = true
    stPhaseTimer.restart()
  }

  function stopPhase() {
    stPhaseTimer.stop()
    if (speedTestProc.running) {
      stExpectedStop = true
      speedTestProc.running = false
      return
    }
    finishPhase()
  }

  function finishPhase() {
    if (stPhase === "down") {
      startPhase("up")
      return
    }
    stPhase = ""
    stRunning = false
    stExpectedStop = false
  }

  function onSpeedLine(line) {
    var value = parseFloat(line)
    if (!isFinite(value) || value < 0) return
    if (stPhase === "down") stDown = value
    else if (stPhase === "up") stUp = value
  }

  onOpenedChanged: if (opened) refresh()

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: shown ? button.implicitHeight : 0

  Process {
    id: statusProc
    command: [root.helperPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.info = JSON.parse(String(text || "{}")) } catch (e) {}
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastError = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode === 0) root.lastError = ""
      root.refresh()
    }
  }

  Process {
    id: speedTestProc
    stdout: SplitParser { onRead: function(line) { root.onSpeedLine(line) } }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.stStderr = String(text || "").trim()
        if (root.stError !== "" && root.stStderr !== "") root.stError = root.stStderr
      }
    }
    onExited: function(exitCode) {
      stPhaseTimer.stop()
      if (root.stPendingRun) {
        root.stPendingRun = false
        root.stExpectedStop = false
        if (root.stOpen) Qt.callLater(root.runSpeedTest)
        return
      }
      if (!root.stExpectedStop && exitCode !== 0) {
        root.stError = root.stStderr || "Speed test failed"
        root.stPhase = ""
        root.stRunning = false
        return
      }
      root.stExpectedStop = false
      root.finishPhase()
    }
  }

  Timer {
    id: stPhaseTimer
    interval: 5000
    repeat: false
    onTriggered: root.stopPhase()
  }

  SpeedTestOverlay {
    fontFamily: Style.font.family
    layerNamespace: "xmm7360-lte-speedtest"
    title: (root.info.operator && root.info.operator !== "--" ? root.info.operator : "Mobile") +
      (root.techLabel() ? " · " + root.techLabel() : "")
    leftLabel: "DOWNLOAD"
    rightLabel: "UPLOAD"
    runAgainTooltip: "Measure again via fast.com (uses roughly 10–20 MB of mobile data)"
    scaleStops: [10, 25, 50, 100, 250, 500, 1000]
    running: root.stRunning
    leftValue: root.stDown
    rightValue: root.stUp
    leftLive: root.stRunning && root.stPhase === "down"
    rightLive: root.stRunning && root.stPhase === "up"
    error: root.stError
    open: root.stOpen
    onCloseRequested: root.closeSpeedTest()
    onRunAgainRequested: root.runSpeedTest()
  }

  Timer {
    interval: (root.opened ? 3 : root.refreshSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.signalIcon()
    opacity: root.connected ? 1.0 : 0.5
    tooltipText: root.tooltip()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleData()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.shown
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.toggleData()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: signal icon · operator/status · data switch ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, headerActions.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.signalIcon()
            color: root.bar.foreground
            opacity: root.connected ? 1.0 : 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title * 1.6
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.present && root.info.operator && root.info.operator !== "--"
                ? root.info.operator + (root.techLabel() ? "  " + root.techLabel() : "")
                : "Mobile network"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.stateLabel() + (root.info.registration === "roaming" ? " · roaming" : "")
              color: root.bar.foreground
              opacity: 0.7
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Button {
              id: speedAction
              visible: root.canRunSpeedTest
              iconText: String.fromCodePoint(0xf04c5)
              tooltipText: "Run a speed test over the mobile link (uses roughly 10–20 MB)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              iconSize: Style.font.subtitle * 1.5
              horizontalPadding: Style.space(5)
              verticalPadding: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.openSpeedTest()
            }

            ToggleSwitch {
              id: dataSwitch
              visible: root.present && !!root.info.connection
              checked: !!root.info.active
              busy: root.busy
              foreground: root.bar.foreground
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleData()
            }
          }
        }

        // ---------- Signal strength bar ----------
        Item {
          visible: root.present
          width: parent.width
          height: Style.space(6)

          Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: root.bar.foreground
            opacity: 0.15
          }

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            radius: height / 2
            width: parent.width * Math.max(0, Math.min(100, Number(root.info.quality) || 0)) / 100
            color: root.bar.foreground
            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
          }
        }

        PanelSeparator {
          visible: root.present
          foreground: root.bar.foreground
        }

        Column {
          visible: root.present
          width: parent.width
          spacing: Style.space(6)

          InfoPair { label: "RSRP"; value: root.fmt(root.info.rsrp, "dBm") }
          InfoPair { label: "RSRQ"; value: root.fmt(root.info.rsrq, "dB") }
          InfoPair { label: "SNR"; value: root.fmt(root.info.snr, "dB") }
          InfoPair { label: "Registration"; value: String(root.info.registration || "—") + (root.info.operatorId && root.info.operatorId !== "--" ? " (" + root.info.operatorId + ")" : "") }
          InfoPair { label: "IP address"; value: root.info.ip || "—" }
          InfoPair { label: "Connection"; value: root.info.connection ? root.info.connection + (root.info.interface ? " · " + root.info.interface : "") : "no GSM profile" }
          InfoPair { label: "Connect at boot"; value: root.info.connection ? (root.info.autoconnect ? "yes" : "no") : "—" }
          InfoPair { label: "Modem"; value: root.info.model || "—" }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: root.lastError
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: !root.present
          width: parent.width
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: "ModemManager doesn't see a modem."
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
