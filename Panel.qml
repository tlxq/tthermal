import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.power"
  ipcTarget: "omarchy.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property int modeIndex: 0
  property bool cursorActive: false

  // ---------- tthermal ----------
  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property var modes: ["auto", "cool", "balanced", "fast"]
  readonly property var modeProfiles: ({ auto: "balanced", cool: "power-saver", balanced: "balanced", fast: "performance" })
  readonly property var modeTips: ({
    auto: "Auto — picks Quiet or Working",
    cool: "Lock to Cool",
    balanced: "Lock to Balanced",
    fast: "Lock to Fast"
  })
  readonly property int maxTemp: Math.max(65, Math.min(95, Number(setting("maxTemp", 80)) || 80))
  readonly property string mode: modes.indexOf(String(setting("mode", "auto"))) >= 0 ? String(setting("mode", "auto")) : "auto"
  readonly property bool manualMode: mode !== "auto"
  // Auto: working (input recently, lid open or external screen), quiet (idle or
  // lid closed alone), background (quiet but the CPU stays busy, e.g. a transcode).
  readonly property int quietAfterSec: Math.max(30, Number(setting("quietAfterSec", 120)) || 120)
  readonly property int backgroundMax: Math.max(65, Math.min(95, Number(setting("backgroundMax", 70)) || 70))
  property string autoState: "working"
  property real cpuAvg: 0
  property real cpuAvgAt: 0
  property real backgroundSince: 0
  property string appliedProfile: ""
  readonly property bool hasExternalScreen: {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++)
      if (!String(screens[i].name || "").startsWith("eDP")) return true
    return false
  }
  readonly property int effectiveMax: !manualMode && autoState === "background" ? Math.min(maxTemp, backgroundMax) : maxTemp
  property string batteryCare: ""
  property bool confirmOffOpen: false
  property var thermal: ({})
  property int nowSec: 0
  readonly property bool helperReady: thermal.updated !== undefined && nowSec - Number(thermal.updated) < 15
  readonly property int temp: Number(thermal.temp || 0)
  readonly property string guardState: helperReady ? String(thermal.state || "released") : "missing"
  readonly property bool holding: guardState === "holding"
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color thermalColor: {
    if (!helperReady) return Color.muted
    if (holding) return Color.urgent
    if (manualMode) return Color.accent
    if (autoState === "quiet") return Qt.rgba(fg.r, fg.g, fg.b, 0.5)
    return fg
  }
  // W2: a word, never the raw state key (quiet → "Quiet"); the keys stay internal
  function word(key) { var k = String(key || ""); return k.charAt(0).toUpperCase() + k.slice(1) }
  readonly property string thermalLabel: {
    if (!helperReady) return "Off"
    if (holding) return "Holding"
    if (manualMode) return word(mode)
    return word(autoState)
  }
  readonly property string thermalSub: {
    if (!helperReady) return "Temperature control is off"
    if (holding) return "Pulling power to stay under " + effectiveMax + "°"
    if (manualMode) return "Locked · max " + maxTemp + "° still respected"
    if (autoState === "quiet") return thermal.lid === "closed" ? "Lid closed · cool and quiet" : "Idle · cool and quiet"
    if (autoState === "background") return "Background load · held at " + effectiveMax + "°"
    return "Snappy · under your max"
  }
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // One spot in the bar: the battery icon, plus the temperature only
  // when it gets close to the max, plus the % when the battery runs low on battery power.
  readonly property bool tempHot: helperReady && (holding || temp >= maxTemp - 5)
  readonly property bool batteryLow: batteryPresent && discharging && batteryFraction <= 0.25
  readonly property bool batteryCritical: batteryLow && batteryFraction <= 0.10
  readonly property bool showBatteryPct: showPercentage || batteryLow
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectModeByDelta(delta) {
    modeIndex = Model.selectProfileIndex(modeIndex, delta, modes)
  }

  function activateSelectedMode() {
    if (modeIndex < 0 || modeIndex >= modes.length) return
    setMode(modes[modeIndex])
  }

  function modeIcon(name) {
    if (name === "auto") return String.fromCodePoint(0xF0450)
    return Model.profileIcon(modeProfiles[name])
  }

  function wantedProfile() {
    if (manualMode) return modeProfiles[mode]
    return autoState === "quiet" ? "power-saver" : "balanced"
  }

  function evaluateAuto() {
    // CPU averaged over ~60 s, so short spikes from background services
    // (~16 % on average) don't count. Background starts above 40 %, ends below
    // 25 %, and lasts at least 2 minutes.
    var cpu = Number(thermal.cpu || 0)
    var now = Date.now()
    cpuAvg = cpuAvgAt > 0 ? cpuAvg + (cpu - cpuAvg) * (1 - Math.exp(-(now - cpuAvgAt) / 60000)) : cpu
    cpuAvgAt = now
    var lidClosedAlone = thermal.lid === "closed" && !hasExternalScreen
    var stayBackground = autoState === "background" && (cpuAvg >= 25 || now - backgroundSince < 120000)
    var next
    if (!idleMonitor.isIdle && !lidClosedAlone) next = "working"
    else if (cpuAvg > 40 || stayBackground) next = "background"
    else next = "quiet"
    if (next !== autoState) {
      if (next === "background") backgroundSince = now
      autoState = next
      sendControl()
    }
    applyProfile()
  }

  function saveSetting(key, value) {
    var next = Object.assign({}, root.settings)
    next[key] = value
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  function setMode(name) {
    if (modes.indexOf(name) < 0) return
    if (name !== mode) saveSetting("mode", name)
    sendControl()
    applyProfile()
  }

  function applyProfile() {
    var want = wantedProfile()
    if (want === appliedProfile || profileProc.running) return
    profileProc.command = [pluginDir + "/bin/tthermal-profile", want]
    profileProc.running = true
    appliedProfile = want
  }

  function setMaxTemp(value) {
    var v = Math.max(65, Math.min(95, Math.round(value)))
    if (v !== maxTemp) saveSetting("maxTemp", v)
    sendControl()
  }

  function sendControl() {
    if (controlProc.running) return
    var quietFan = !manualMode && (autoState === "quiet" || autoState === "background")
    // Background jobs want steady throughput; a burst only overshoots the lower max.
    var burst = !(!manualMode && autoState === "background")
    controlProc.command = [pluginDir + "/bin/tthermal-control", "1", String(root.effectiveMax), quietFan ? "4" : "7", burst ? "1" : "0"]
    controlProc.running = true
  }

  function parseThermal(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var idx = lines[i].indexOf("=")
      if (idx > 0) next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
    }
    if (next.updated !== undefined) {
      thermal = next
      evaluateAuto()
    }
  }

  function refreshBatteryCare() {
    if (!careGetProc.running) careGetProc.running = true
  }

  function setBatteryCare(on) {
    if (careSetProc.running || batteryCare === "unsupported") return
    careSetProc.command = [pluginDir + "/bin/tthermal-battery-care", on ? "on" : "off"]
    careSetProc.running = true
  }

  function turnOff() {
    confirmOffOpen = false
    close()
    Quickshell.execDetached([pluginDir + "/bin/tthermal-off"])
  }

  function enableHelper() {
    if (installProc.running) return
    installProc.command = ["pkexec", pluginDir + "/helper/install.sh"]
    installProc.running = true
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  readonly property string heroStatusText: {
    // W4/W8: plain status words, no slogans.
    if (fullyCharged) return "Fully charged"
    if (charging) return "Charging…"
    if (discharging) return "On battery"
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  IpcHandler {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      refreshBatteryCare()
      confirmOffOpen = false
      var idx = modes.indexOf(mode)
      modeIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? barIcons.implicitWidth : 0
  implicitHeight: batteryPresent ? barIcons.implicitHeight : 0

  Process {
    id: batteryProc
    command: ["omarchy-battery-status", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process { id: profileProc; onExited: function(code) { if (code !== 0) root.appliedProfile = "" } }

  IdleMonitor {
    id: idleMonitor
    enabled: true
    timeout: root.quietAfterSec
    respectInhibitors: false
    onIsIdleChanged: root.evaluateAuto()
  }
  Process { id: controlProc }

  Process {
    id: careGetProc
    command: [root.pluginDir + "/bin/tthermal-battery-care", "get"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.batteryCare = String(text).trim() }
  }

  Process { id: careSetProc; onExited: root.refreshBatteryCare() }
  Process { id: installProc; onExited: statusFile.reload() }

  FileView {
    id: statusFile
    path: "/run/tthermal/status"
    watchChanges: false
    printErrors: false
    onLoaded: root.parseThermal(text())
  }

  // Status from the root helper; also drives the bar thermometer.
  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.nowSec = Math.floor(Date.now() / 1000)
      statusFile.reload()
    }
  }

  // Heartbeat: the helper lets go of the power limits when this stops.
  Timer {
    interval: 20000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sendControl()
  }

  Component.onCompleted: {
    applyProfile()
    if (setting("batteryCareInit", false) !== true) {
      saveSetting("batteryCareInit", true)
      setBatteryCare(true)
    } else {
      refreshBatteryCare()
    }
  }
  Component.onDestruction: Quickshell.execDetached([pluginDir + "/bin/tthermal-control", "0", String(maxTemp)])

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  Item {
    id: barIcons
    anchors.fill: parent
    implicitWidth: barRow.implicitWidth
    implicitHeight: barRow.implicitHeight

    Row {
      id: barRow
      height: parent.height

      // Omarchy 4.5 fits everything in the icon slot (text or iconComponent) into 12 px by its
      // widest side. So the slot holds only the battery glyph, the % goes in labelText (Omarchy's
      // own label, like its stock battery) and the hot temperature is a full-size number beside it.
      BarIconButton {
        id: button
        bar: root.bar
        readonly property bool showPct: root.showBatteryPct && !vertical
        text: root.batteryIcon()
        labelText: showPct ? Math.round(root.batteryFraction * 100) + "%" : ""
        foreground: root.batteryCritical ? Color.urgent : root.batteryLow ? Color.accent : root.fg
        slotSize: Style.bar.iconSlot * (showPct ? 2 : 1)
        tooltipText: root.hoverText
        onPressed: function(b) { root.barPressed(b) }
      }

      // Hot: accent + bold, so it reads as "rising" even in themes where accent and text are close.
      BarIconButton {
        id: tempButton
        bar: root.bar
        visible: root.tempHot && !vertical
        text: ""
        hasVisualContent: true
        slotSize: Style.bar.iconSlot * 1.5
        tooltipText: root.hoverText
        onPressed: function(b) { root.barPressed(b) }

        Text {
          anchors.centerIn: parent
          scale: tempButton.pressScale
          textFormat: Text.PlainText
          text: root.temp + "°"
          color: Color.accent
          font.family: root.bar ? root.bar.fontFamily : ""
          // Same text setup as WidgetButton's own label, so it matches the other numbers on the bar
          font.pixelSize: Style.font.body
          font.bold: true
          renderType: Text.NativeRendering
        }
      }
    }
  }

  readonly property string hoverText: root.helperReady
    ? Math.round(root.batteryFraction * 100) + " % · CPU " + root.temp + " °C / max " + root.maxTemp + " °C · " + root.thermalLabel.toLowerCase()
    : Math.round(root.batteryFraction * 100) + " % · temperature control is off"

  function barPressed(b) {
    if (!root.batteryPresent) return
    if (b === Qt.RightButton) root.togglePercentage()
    else root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.confirmOffOpen) { if (dx !== 0) offConfirm.selectedIndex = offConfirm.selectedIndex === 0 ? 1 : 0; return }
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectModeByDelta(dx)
        else if (dy !== 0) root.selectModeByDelta(dy)
      }
      onActivateRequested: {
        if (root.confirmOffOpen) {
          if (offConfirm.selectedIndex === 1) root.turnOff()
          else root.confirmOffOpen = false
        } else if (root.cursorActive) {
          root.activateSelectedMode()
        }
      }
      onCloseRequested: {
        if (root.confirmOffOpen) root.confirmOffOpen = false
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Battery"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Battery size"; value: root.batteryInfo.size || "" }
            InfoPair { label: "Charge cycles"; value: root.batteryInfo.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Charge limit" : (root.discharging ? "Time left" : "Time to full")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Battery state" : (root.discharging ? "Discharging" : "Charging")
              value: root.chargeThresholdActive ? "Holding" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
          }
        }

        // ---------- Battery care ----------
        Item {
          visible: root.batteryCare === "on" || root.batteryCare === "off"
          width: parent.width
          implicitHeight: Math.max(careLabels.implicitHeight, careSwitch.implicitHeight)

          Column {
            id: careLabels
            anchors.left: parent.left
            anchors.right: careSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Battery care"
              color: root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.batteryCare === "on" ? "Stops at 80 %, resumes below 75 %" : "Charges to 100 %"
              color: root.fg
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          ToggleSwitch {
            id: careSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.batteryCare === "on"
            busy: careSetProc.running
            foreground: root.fg
            onToggled: root.setBatteryCare(!checked)
          }
        }

        // ---------- Thermal (tthermal) ----------
        PanelSeparator {
          foreground: root.fg
        }

        Column {
          width: parent.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: thermalHeader.implicitHeight

            PanelSectionHeader {
              id: thermalHeader
              text: "THERMAL"
              foreground: root.fg
              fontFamily: root.bar.fontFamily
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.helperReady
              textFormat: Text.PlainText
              text: root.manualMode ? root.word(root.mode) + " · Locked" : "Auto"
              color: root.manualMode ? Color.accent : root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          // Helper not installed yet: one-time setup.
          Column {
            visible: !root.helperReady
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "tthermal needs a small helper to set CPU power limits. It installs once and asks for your password."
              color: root.fg
              opacity: 0.7
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              width: parent.width
              text: installProc.running ? "Installing…" : "Turn on temperature control"
              iconText: String.fromCodePoint(0xF050F)
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.enableHelper()
            }
          }

          // Temperature hero
          Item {
            visible: root.helperReady
            width: parent.width
            implicitHeight: Math.max(thermoIcon.implicitHeight, thermoTemp.implicitHeight)

            Text {
              id: thermoIcon
              textFormat: Text.PlainText
              text: String.fromCodePoint(0xF050F)
              color: root.thermalColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Text {
              id: thermoTemp
              textFormat: Text.PlainText
              text: root.temp + "°"
              color: root.thermalColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
              anchors.left: thermoIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Column {
              anchors.left: thermoTemp.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: root.thermalLabel
                color: root.thermalColor
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.thermalSub
                color: root.fg
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // 30–100 °C track with the max marker
          Item {
            visible: root.helperReady
            width: parent.width
            implicitHeight: Style.space(14)

            readonly property real tempFraction: Math.max(0, Math.min(1, (root.temp - 30) / 70))
            readonly property real maxFraction: Math.max(0, Math.min(1, (root.maxTemp - 30) / 70))

            Rectangle {
              id: tempTrack
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(8)
              radius: height / 2
              color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
            }

            Rectangle {
              anchors.left: tempTrack.left
              anchors.verticalCenter: tempTrack.verticalCenter
              height: tempTrack.height
              radius: tempTrack.radius
              width: Math.max(tempTrack.height, tempTrack.width * parent.tempFraction)
              color: root.thermalColor
              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
              Behavior on color { ColorAnimation { duration: 200 } }
            }

            Rectangle {
              x: tempTrack.width * parent.maxFraction - width / 2
              anchors.verticalCenter: parent.verticalCenter
              width: 2
              height: parent.height
              color: root.fg
            }
          }

          // CPU · Power limit · Fan
          Row {
            id: statRow
            visible: root.helperReady
            width: parent.width
            spacing: Style.space(8)

            readonly property real cellWidth: (width - spacing * 2) / 3

            StatTile { width: statRow.cellWidth; label: "CPU"; value: (Number(root.thermal.mhz || 0) / 1000).toFixed(1) + " GHz" }
            StatTile { width: statRow.cellWidth; label: "Power limit"; value: (root.thermal.pl1 || "—") + " W" }
            StatTile {
              width: statRow.cellWidth
              label: root.thermal.fan_level && root.thermal.fan_level !== "auto" ? "Fan · L" + root.thermal.fan_level : "Fan"
              value: Number(root.thermal.fan || 0) > 0 ? root.thermal.fan + " rpm" : "off"
            }
          }

          // Max temp
          Column {
            visible: root.helperReady
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: maxLabel.implicitHeight

              PanelSectionHeader {
                id: maxLabel
                text: "MAX TEMP"
                foreground: root.fg
                fontFamily: root.bar.fontFamily
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: Math.round(maxSlider.dragging ? maxSlider.liveValue : root.maxTemp) + " °C"
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
            }

            PanelSlider {
              id: maxSlider
              bar: root.bar
              width: parent.width
              height: Style.spacing.controlHeight
              minimum: 65
              maximum: 95
              step: 1
              integer: true
              value: root.maxTemp
              onReleased: function(v) { root.setMaxTemp(v) }
            }
          }

          // Mode
          Item {
            visible: root.helperReady
            width: parent.width
            implicitHeight: modeRow.implicitHeight

            PanelSectionHeader {
              text: "MODE"
              foreground: root.fg
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Row {
              id: modeRow
              anchors.right: parent.right
              spacing: Style.space(6)

              Repeater {
                model: root.modes
                Button {
                  required property var modelData
                  required property int index
                  iconText: root.modeIcon(String(modelData))
                  iconSize: Style.font.title
                  tooltipText: root.modeTips[modelData]
                  foreground: root.fg
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                  bordered: true
                  active: root.mode === modelData
                  hasCursor: root.cursorActive && root.modeIndex === index
                  onClicked: root.setMode(String(modelData))
                  onHovered: function(h) {
                    if (h) {
                      root.cursorActive = true
                      root.modeIndex = index
                    }
                  }
                }
              }
            }
          }

          // Footer: turn off (asks first)
          Item {
            width: parent.width
            implicitHeight: offButton.implicitHeight

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.helperReady ? "Fan helper on" : "Fan helper off"
              color: root.fg
              opacity: 0.5
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Button {
              id: offButton
              anchors.right: parent.right
              iconText: String.fromCodePoint(0xF0425)
              iconSize: Style.font.title
              tooltipText: "Turn off the fan helper"
              foreground: root.fg
              fontFamily: root.bar.fontFamily
              onClicked: {
                offConfirm.selectedIndex = 0
                root.confirmOffOpen = true
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: offConfirm
        anchors.fill: parent
        z: 10
        opened: root.confirmOffOpen
        message: "Turn off the fan helper? Omarchy's own battery icon comes back and power limits return to factory. Battery care stays as it is."
        confirmText: "Turn off"
        fontFamily: root.bar.fontFamily
        onCanceled: root.confirmOffOpen = false
        onConfirmed: root.turnOff()
      }
    }
  }

  component StatTile: Rectangle {
    property string label: ""
    property string value: ""

    implicitHeight: tileColumn.implicitHeight + Style.space(16)
    radius: Style.cornerRadius
    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.06)

    Column {
      id: tileColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      InfoLabel { text: label; font.pixelSize: Style.font.caption }
      InfoValue { text: value }
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
