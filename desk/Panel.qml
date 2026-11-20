import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Desk version of tthermal. The bar shows the hotter of CPU and GPU as a number; the panel shows
// both temperatures, the fans and the Auto / Full speed buttons. bin/tthermal-desk (user service)
// does the work and writes $XDG_RUNTIME_DIR/tthermal/status every 2 s.
Panel {
  id: root
  moduleName: "com.ttdevs.tthermal"
  ipcTarget: "com.ttdevs.tthermal"

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string statusPath: Quickshell.env("XDG_RUNTIME_DIR") + "/tthermal/status"
  // Colour steps for the bar number (°C): theme colour below warmAt, accent from warmAt, red from hotAt.
  readonly property int warmAt: 70
  readonly property int hotAt: 85
  readonly property var modes: ["auto", "full"]

  property var st: ({})
  // Week chart: {start, end, step, first, cpu_max, gpu_max} and [[bucket, cpu, gpu], ...] from bin/tthermal-week
  property var week: ({})
  property var weekPts: []
  property int nowSec: 0
  property bool cursorActive: false
  property int modeIndex: 0

  readonly property bool serviceReady: st.updated !== undefined && nowSec - Number(st.updated) < 10
  readonly property int hot: Number(st.hot || 0)
  readonly property int cpu: Number(st.cpu || 0)
  readonly property int gpu: Number(st.gpu || 0)
  readonly property string state: String(st.state || "auto")
  readonly property bool biosControl: st.control === "bios"
  readonly property string alert: String(st.alert || "")
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color tempColor: {
    if (!serviceReady) return Color.muted
    if (alert !== "" || hot >= hotAt) return Color.urgent
    if (hot >= warmAt) return Color.accent
    return fg
  }
  readonly property bool warm: serviceReady && (alert !== "" || hot >= warmAt)
  readonly property int fullMinutes: Math.max(1, Math.ceil(Number(st.full_left || 0) / 60))

  readonly property string stateLabel: {
    // W2/W4: sentence-case words, not raw keys in capitals
    if (!serviceReady) return "Off"
    if (biosControl) return "BIOS"
    if (state === "full") return "Full speed"
    if (state === "gaming") return "Gaming"
    return hot >= 60 ? "Busy" : "Quiet"
  }
  readonly property string stateSub: {
    if (!serviceReady) return "The fan helper isn't running"
    if (biosControl) return "CoolerControl is off · the BIOS runs the fans"
    if (state === "full") return "All fans at 100 % · Auto again in " + fullMinutes + " min"
    if (state === "gaming") return (st.held === "1" ? "Game mode on" : "GPU busy") + " · case fans at least 45 %"
    return hot >= 60 ? "Fans follow the heat" : "Idle · cool and quiet"
  }
  // Short hover text: the sensor the bar shows comes first.
  readonly property string hoverText: {
    if (!serviceReady) return "Fan helper off"
    var first = st.hot_src === "GPU" ? "GPU " + gpu + " °C" : "CPU " + cpu + " °C"
    var second = st.hot_src === "GPU" ? "CPU " + cpu + " °C" : "GPU " + gpu + " °C"
    var text = first + " · " + second
    if (alert !== "") text += " · " + alert + " fan stopped"
    else if (biosControl) text += " · BIOS fans"
    return text
  }

  function parseStatus(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var idx = lines[i].indexOf("=")
      if (idx > 0) next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
    }
    if (next.updated !== undefined) st = next
  }

  function startService() {
    Quickshell.execDetached(["systemctl", "--user", "start", "tthermal-desk"])
  }

  function setMode(name) {
    if (modes.indexOf(name) < 0) return
    Quickshell.execDetached([pluginDir + "/bin/tthermal-desk", name])
  }

  function parseWeek(raw) {
    var info = {}
    var pts = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      if (line.indexOf("=") > 0) {
        var parts = line.split(" ")
        for (var j = 0; j < parts.length; j++) {
          var kv = parts[j].split("=")
          info[kv[0]] = Number(kv[1])
        }
      } else {
        var p = line.split(" ")
        pts.push([Number(p[0]), Number(p[1]), Number(p[2])])
      }
    }
    week = info
    weekPts = pts
  }

  function refreshWeek() {
    if (!weekProc.running) weekProc.running = true
  }

  // Left label of the chart: "7 days ago", or when the log started if it is younger.
  function weekStartLabel() {
    if (!week.first) return ""
    if (week.end - week.first > 6.5 * 86400) return "7 days ago"
    var d = new Date(week.first * 1000)
    var today = new Date()
    var hm = Qt.formatTime(d, "HH:mm")
    if (d.toDateString() === today.toDateString()) return "today " + hm
    return Qt.formatDate(d, "ddd") + " " + hm
  }

  function fanText(key) {
    var rpm = Number(st[key] || 0)
    return rpm > 0 ? rpm + " rpm" : "stopped"
  }

  onOpenedChanged: {
    if (opened) {
      refreshWeek()
      cursorActive = false
      modeIndex = state === "full" ? 1 : 0
    }
  }

  implicitWidth: thermoButton.implicitWidth
  implicitHeight: thermoButton.implicitHeight

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: false
    printErrors: false
    onLoaded: root.parseStatus(text())
  }

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

  Process {
    id: weekProc
    command: [root.pluginDir + "/bin/tthermal-week"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: { root.parseWeek(text); weekCanvas.requestPaint() } }
  }

  Timer { interval: 600000; running: root.opened; repeat: true; onTriggered: root.refreshWeek() }

  BarIconButton {
    id: thermoButton
    bar: root.bar
    readonly property bool showNumber: root.serviceReady && !vertical
    text: showNumber ? "" : String.fromCodePoint(0xF050F)
    foreground: root.tempColor
    // The number sits beside the icon renderer on purpose: Omarchy 4.5 fits iconComponent content
    // into 12 px by its widest side, which shrinks text to a tiny size.
    hasVisualContent: true
    slotSize: Style.bar.iconSlot * (root.serviceReady && !vertical ? (root.alert !== "" ? 2 : 1.5) : 1)
    tooltipText: root.hoverText
    onPressed: function(b) { root.toggle() }

    // Drawn here so it can turn bold when warm: in themes where accent and text are close
    // (Moonlit Sands), weight is what makes "rising" visible.
    Text {
      anchors.centerIn: parent
      visible: thermoButton.showNumber
      scale: thermoButton.pressScale
      textFormat: Text.PlainText
      text: root.hot + "°" + (root.alert !== "" ? " !" : "")
      color: root.tempColor
      font.family: root.bar ? root.bar.fontFamily : ""
      // Same text setup as WidgetButton's own label, so it matches the other numbers on the bar
      font.pixelSize: Style.font.body
      font.bold: root.warm
      renderType: Text.NativeRendering
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: thermoButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        var d = dx !== 0 ? dx : dy
        root.modeIndex = Math.max(0, Math.min(root.modes.length - 1, root.modeIndex + d))
      }
      onActivateRequested: if (root.cursorActive) root.setMode(root.modes[root.modeIndex])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: header.implicitHeight

          PanelSectionHeader {
            id: header
            text: "COOLING"
            foreground: root.fg
            fontFamily: root.bar.fontFamily
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.state === "full" ? "Full" : root.state === "gaming" ? "Auto · Gaming" : "Auto"
            visible: root.serviceReady && !root.biosControl
            color: root.state === "full" ? Color.accent : root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }

        // Service missing: say so and offer Start (W2, L1: no command in the text, a button instead).
        Text {
          visible: !root.serviceReady
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "The fan helper isn't running, so the panel has no numbers."
          color: root.fg
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          visible: !root.serviceReady
          text: "Start"
          fontSize: Style.font.bodySmall
          tooltipText: "Start the fan helper"
          foreground: root.fg
          fontFamily: root.bar.fontFamily
          bordered: true
          onClicked: root.startService()
        }

        // Hero: hottest temperature and what the fans are doing
        Item {
          visible: root.serviceReady
          width: parent.width
          implicitHeight: Math.max(heroTemp.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroTemp
            textFormat: Text.PlainText
            text: root.hot + "°"
            color: root.tempColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroTemp.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.stateLabel
              color: root.tempColor
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.stateSub
              color: root.fg
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        Row {
          id: tempRow
          visible: root.serviceReady
          width: parent.width
          spacing: Style.space(8)
          readonly property real cellWidth: (width - spacing) / 2

          StatTile { width: tempRow.cellWidth; label: "CPU"; value: root.cpu + " °C" }
          StatTile { width: tempRow.cellWidth; label: "GPU · " + Number(root.st.gpu_util || 0) + " % busy"; value: root.gpu + " °C" }
        }

        Column {
          visible: root.serviceReady
          width: parent.width
          spacing: Style.space(4)

          PanelSectionHeader {
            text: "FANS"
            foreground: root.fg
            fontFamily: root.bar.fontFamily
          }

          InfoPair { label: "Cooler"; value: root.fanText("cooler") }
          InfoPair { label: "Rear"; value: root.fanText("rear") }
          InfoPair { label: "Top ×2"; value: root.fanText("top") }
          InfoPair { label: "Intake ×4"; value: root.fanText("intake") }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.alert !== "" ? root.alert + " fan stopped for over a minute. Check the fan and its hub plug." : "All fans OK"
            color: root.alert !== "" ? Color.urgent : root.fg
            opacity: root.alert !== "" ? 1 : 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Week chart: highest CPU and GPU temperature per 10 min
        Column {
          visible: root.serviceReady && root.weekPts.length > 1
          width: parent.width
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: weekHeader.implicitHeight

            PanelSectionHeader {
              id: weekHeader
              text: "WEEK"
              foreground: root.fg
              fontFamily: root.bar.fontFamily
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "max " + (root.week.cpu_max || 0) + "° CPU · " + (root.week.gpu_max || 0) + "° GPU"
              color: root.fg
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Canvas {
            id: weekCanvas
            width: parent.width
            height: Style.space(64)
            onWidthChanged: requestPaint()

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var pts = root.weekPts
              if (pts.length < 2) return
              var w = width, h = height
              var step = root.week.step || 600
              var b0 = Math.floor((Math.max(root.week.first || root.week.start, root.week.start) - root.week.start) / step)
              var b1 = Math.max(b0 + 1, Math.floor((root.week.end - root.week.start) / step))
              var tMin = 30, tMax = 90
              function x(b) { return (b - b0) / (b1 - b0) * w }
              function y(t) { return h - (Math.max(tMin, Math.min(tMax, t)) - tMin) / (tMax - tMin) * (h - 2) - 1 }
              var c = root.fg

              // Faint guide at the warm step (70 °C)
              ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, 0.15)
              ctx.lineWidth = 1
              ctx.beginPath(); ctx.moveTo(0, y(root.warmAt)); ctx.lineTo(w, y(root.warmAt)); ctx.stroke()

              // A missing bucket (PC off or logged out) breaks the line.
              function line(idx, alpha, dash) {
                ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, alpha)
                ctx.lineWidth = 1.5
                ctx.setLineDash(dash)
                ctx.beginPath()
                var prev = -2
                for (var i = 0; i < pts.length; i++) {
                  if (pts[i][0] !== prev + 1) ctx.moveTo(x(pts[i][0]), y(pts[i][idx]))
                  else ctx.lineTo(x(pts[i][0]), y(pts[i][idx]))
                  prev = pts[i][0]
                }
                ctx.stroke()
              }
              line(2, 0.45, [3, 3])
              line(1, 0.95, [])
            }
          }

          Item {
            width: parent.width
            implicitHeight: weekStart.implicitHeight

            InfoLabel { id: weekStart; text: root.weekStartLabel(); font.pixelSize: Style.font.caption }
            InfoLabel { anchors.horizontalCenter: parent.horizontalCenter; text: "— CPU   ┄ GPU"; font.pixelSize: Style.font.caption }
            InfoLabel { anchors.right: parent.right; text: "now"; font.pixelSize: Style.font.caption }
          }
        }

        Row {
          visible: root.serviceReady && !root.biosControl
          spacing: Style.space(6)

          Repeater {
            model: root.modes
            Button {
              required property var modelData
              required property int index
              // L1/W4: Gaming shows on the Auto button while it's on, not only in the tooltip
              text: modelData === "full" ? (root.state === "full" ? "Full speed · " + root.fullMinutes + " min" : "Full speed") : root.state === "gaming" ? "Auto · Gaming" : "Auto"
              fontSize: Style.font.bodySmall
              tooltipText: modelData === "full" ? "All fans at 100 %, back to Auto after 30 min" : "Fans follow CPU and GPU heat; Gaming switches on by itself"
              foreground: root.fg
              fontFamily: root.bar.fontFamily
              bordered: true
              active: modelData === "full" ? root.state === "full" : root.state !== "full"
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

        Text {
          textFormat: Text.PlainText
          text: root.serviceReady ? "Fan helper on" : "Fan helper off"
          color: root.fg
          opacity: 0.5
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
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
