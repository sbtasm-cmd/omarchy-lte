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
  // "home", "roaming", and their "-sms-only" variants (LTE without a CS domain)
  readonly property bool registered: /^(home|roaming)/.test(String(info.registration || ""))
  readonly property bool shown: present || !hideWithoutModem
  readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("bin/lte-status").toString().replace(/^file:\/\//, ""))

  // Nerd Font cellular glyphs: outline (no signal), then 1-3 bars.
  function signalIcon() {
    if (!present || !connected && !registered) return String.fromCodePoint(0xf08bf)
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
    if (busy) return pendingMode === "off" ? "Turning off…" : pendingMode === "network" ? "Joining network…" : "Connecting…"
    if (lteMode === "off") return "Off"
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
    if (info.traffic && info.traffic.total > 0) parts.push("Σ " + formatBytes(info.traffic.total))
    return parts.join(" · ")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // Three states (bin/lte-mode): "off" = WWAN radio off (NetworkManager keeps it
  // across reboots), "network" = registered without mobile data, "data" =
  // connected. Data on/off also flips the profile's autoconnect flag, so the
  // choice survives a reboot.
  readonly property string modePath: decodeURIComponent(Qt.resolvedUrl("bin/lte-mode").toString().replace(/^file:\/\//, ""))
  readonly property string lteMode: info.wwanRadio === false ? "off" : (info.active ? "data" : "network")
  property string pendingMode: ""

  function setLteMode(mode) {
    if (busy || mode === lteMode) return
    busy = true
    pendingMode = mode
    lastError = ""
    actionProc.command = [modePath, mode]
    actionProc.running = true
  }

  readonly property string logsPath: decodeURIComponent(Qt.resolvedUrl("bin/lte-logs").toString().replace(/^file:\/\//, ""))

  // Opens (or focuses) a terminal following the modem log.
  function openLogs() {
    close()
    // Detached: a Process-owned child would be torn down with the Process.
    Quickshell.execDetached(["omarchy-launch-or-focus-tui", "--app-id=org.omarchy.lte-logs", logsPath])
  }

  function setData(on) { setLteMode(on ? "data" : "network") }

  function toggleData() { setLteMode(lteMode === "data" ? "network" : "data") }

  // gsm.home-only=yes forbids mobile data while roaming; it applies on the
  // next activation, so an active connection is brought up again.
  function setDataRoaming(on) {
    if (busy || !info.connection) return
    busy = true
    lastError = ""
    actionProc.command = ["bash", "-c",
      'nmcli connection modify id "$1" gsm.home-only "$2" && ' +
      'if [ "$3" = yes ]; then nmcli --wait 60 connection up id "$1"; fi',
      "lte-roaming", info.connection, on ? "no" : "yes", info.active ? "yes" : "no"]
    actionProc.running = true
  }

  // ---------- Traffic counter (bin/lte_traffic.py, persisted across reboots) ----------
  property bool trafficConfirm: false
  readonly property string trafficPath: decodeURIComponent(Qt.resolvedUrl("bin/lte-traffic").toString().replace(/^file:\/\//, ""))

  function formatBytes(n) {
    n = Number(n) || 0
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (i === 0 ? n.toFixed(0) : n.toFixed(n < 10 ? 2 : 1)) + " " + units[i]
  }

  function formatSince(ts) {
    // "2026-10-09T13:13:54+0300" -> "09.10.2026 13:13"
    var m = String(ts || "").match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/)
    return m ? m[3] + "." + m[2] + "." + m[1] + " " + m[4] + ":" + m[5] : "—"
  }

  function resetTraffic() {
    if (!trafficConfirm) {
      trafficConfirm = true
      trafficConfirmTimer.restart()
      return
    }
    trafficConfirm = false
    trafficProc.command = [trafficPath, "reset"]
    trafficProc.running = true
  }

  // ---------- Network mode ----------
  readonly property string modeKey: info.allowedModes === "4g" ? "4g"
    : info.allowedModes === "3g" ? "3g"
    : (info.allowedModes || "").indexOf("4g") >= 0 ? "auto" : ""

  function setMode(key) {
    if (busy || !present || key === modeKey) return
    busy = true
    lastError = ""
    var args = key === "auto" ? ["--set-allowed-modes=3g|4g", "--set-preferred-mode=4g"]
      : ["--set-allowed-modes=" + key]
    actionProc.command = ["mmcli", "-m", "any"].concat(args)
    actionProc.running = true
  }

  // ---------- USSD (bin/lte-ussd: temporarily uses 3G, where the CS domain is available) ----------
  property bool ussdBusy: false
  property bool ussdActive: false
  property string ussdReply: ""
  property string ussdError: ""
  readonly property string ussdPath: decodeURIComponent(Qt.resolvedUrl("bin/lte-ussd").toString().replace(/^file:\/\//, ""))
  readonly property string balanceCode: String(setting("balanceCode", "") || "")

  function runUssd(args) {
    if (ussdBusy || !present) return
    ussdBusy = true
    ussdError = ""
    ussdProc.command = [ussdPath].concat(args)
    ussdProc.running = true
  }

  function sendUssd(text) {
    var value = String(text || "").trim()
    if (!value) return
    runUssd(ussdActive ? ["--respond", value] : [value])
  }

  function cancelUssd() { runUssd(["--cancel"]) }

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
    id: trafficProc
    onExited: root.refresh()
  }

  Timer {
    id: trafficConfirmTimer
    interval: 4000
    onTriggered: root.trafficConfirm = false
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

  Process {
    id: ussdProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var r = {}
        try { r = JSON.parse(String(text || "{}")) } catch (e) { r = { ok: false, error: "USSD helper failed" } }
        if (r.ok) root.ussdReply = String(r.reply || "").trim()
        root.ussdActive = !!r.sessionActive
        root.ussdError = String(r.error || "")
        root.ussdBusy = false
        ussdField.text = ""
        root.refresh()
      }
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
              text: root.stateLabel() + (String(root.info.registration || "").indexOf("roaming") === 0 ? " · roaming" : "")
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
              id: logsAction
              iconText: String.fromCodePoint(0xf0219)
              tooltipText: "Modem log (ModemManager, NetworkManager, kernel)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              iconSize: Style.font.subtitle * 1.5
              horizontalPadding: Style.space(5)
              verticalPadding: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.openLogs()
            }

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

            Row {
              id: modeSwitch
              visible: root.present
              spacing: 0
              anchors.verticalCenter: parent.verticalCenter

              Repeater {
                model: [
                  { key: "off", label: "Off", tip: "Modem off: not on the network" },
                  { key: "network", label: "Net", tip: "On the network (SMS, USSD), no mobile data" },
                  { key: "data", label: "Data", tip: "On the network with mobile data" }
                ]
                Button {
                  required property var modelData
                  text: root.busy && root.pendingMode === modelData.key ? "…" : modelData.label
                  tooltipText: modelData.tip
                  active: (root.busy ? root.pendingMode : root.lteMode) === modelData.key
                  enabled: !root.busy && (modelData.key !== "data" || !!root.info.connection)
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  fontSize: Style.font.bodySmall
                  bordered: true
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(3)
                  onClicked: root.setLteMode(modelData.key)
                }
              }
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

        // ---------- Traffic ----------
        PanelSeparator {
          visible: !!root.info.traffic
          foreground: root.bar.foreground
        }

        Column {
          visible: !!root.info.traffic
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(trafficHeader.implicitHeight, trafficReset.implicitHeight)

            PanelSectionHeader {
              id: trafficHeader
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "TRAFFIC  ·  since " + root.formatSince(root.info.traffic ? root.info.traffic.since : "")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Button {
              id: trafficReset
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.trafficConfirm ? "Confirm reset" : "Reset"
              tooltipText: "Zero the traffic counter"
              active: root.trafficConfirm
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.space(2)
              onClicked: root.resetTraffic()
            }
          }

          InfoPair { label: "↓ Received"; value: root.formatBytes(root.info.traffic ? root.info.traffic.rx : 0) }
          InfoPair { label: "↑ Sent"; value: root.formatBytes(root.info.traffic ? root.info.traffic.tx : 0) }
          InfoPair { label: "Σ Total"; value: root.formatBytes(root.info.traffic ? root.info.traffic.total : 0) }
        }

        // ---------- Data roaming ----------
        Item {
          visible: root.present && !!root.info.connection
          width: parent.width
          implicitHeight: roamingSwitch.implicitHeight

          InfoLabel {
            text: "Data roaming" + (String(root.info.registration || "").indexOf("roaming") === 0 ? " (roaming now)" : "")
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ToggleSwitch {
            id: roamingSwitch
            checked: !!root.info.dataRoaming
            busy: root.busy
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.setDataRoaming(!root.info.dataRoaming)
          }
        }

        // ---------- Network mode ----------
        Item {
          visible: root.present
          width: parent.width
          implicitHeight: modeRow.implicitHeight

          InfoLabel {
            text: "Network mode"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Row {
            id: modeRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: [
                { key: "auto", label: "Auto", tip: "3G + 4G, prefer 4G" },
                { key: "4g", label: "4G", tip: "LTE only" },
                { key: "3g", label: "3G", tip: "3G only" }
              ]
              Button {
                required property var modelData
                text: modelData.label
                tooltipText: modelData.tip
                active: root.modeKey === modelData.key
                enabled: !root.busy && !root.ussdBusy
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                bordered: true
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.setMode(modelData.key)
              }
            }
          }
        }

        PanelSeparator {
          visible: root.present
          foreground: root.bar.foreground
        }

        // ---------- USSD ----------
        Column {
          visible: root.present
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: root.ussdActive ? "USSD · MENU" : "USSD"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: ussdField
              width: parent.width - sendButton.width - (balanceButton.visible ? balanceButton.width + parent.spacing : 0) - parent.spacing
              placeholderText: root.ussdActive ? "Reply to the menu" : "*100#"
              enabled: !root.ussdBusy
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              foreground: root.bar.foreground
              onAccepted: root.sendUssd(text)
            }

            Button {
              id: sendButton
              text: root.ussdBusy ? "…" : "Send"
              enabled: !root.ussdBusy
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              anchors.verticalCenter: ussdField.verticalCenter
              onClicked: root.sendUssd(ussdField.text)
            }

            Button {
              id: balanceButton
              visible: root.balanceCode !== "" && !root.ussdActive
              text: "Balance"
              enabled: !root.ussdBusy
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              anchors.verticalCenter: ussdField.verticalCenter
              onClicked: root.runUssd([root.balanceCode])
            }
          }

          Text {
            visible: root.ussdBusy
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: "Switching to 3G and waiting for the network… (up to a minute)"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.ussdReply !== "" && !root.ussdBusy
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: root.ussdReply
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: root.ussdError !== "" && !root.ussdBusy
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: root.ussdError
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            visible: root.ussdActive && !root.ussdBusy
            text: "End session"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.cancelUssd()
          }
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
