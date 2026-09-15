import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.lukasmoriarty.applesiliconthermals"

  readonly property bool spinIcon: setting("spinIcon", true) === true

  property int fanRpm: 0
  property int fanMin: 1199
  property int fanMax: 7199
  property int fanTarget: 0
  property bool fanControlEnabled: false
  property string mode: "auto"
  readonly property bool manualMode: mode === "manual"
  property var temps: []
  property var curveStatus: null
  property string curveSensor: "Charge Regulator Temp"
  property int curveLow: 50
  property int curveHigh: 75
  property bool curveDirty: false
  property string binaryVersion: ""
  property string expectedVersion: ""
  property bool binaryAvailable: false
  property string commandError: ""
  property var pendingCommands: []
  readonly property bool needsSetup: !binaryAvailable || !expectedVersion || binaryVersion !== expectedVersion || (hasFan && !fanControlEnabled)
  property real maxTemp: 0
  property real powerWatts: 0
  property string deviceModel: "Apple Silicon Mac"
  property bool isAppleSilicon: true
  property bool hasFan: true
  property int fanCount: 1
  property var sensors: ({})

  property bool popupOpen: false
  readonly property bool opened: popupOpen
  readonly property string binPath: Qt.resolvedUrl("bin/apple-silicon-thermals").toString().replace(/^file:\/\//, "")

  readonly property string setupPath: Qt.resolvedUrl("setup.sh").toString().replace(/^file:\/\//, "")

  FileView {
    path: Qt.resolvedUrl("release.env").toString().replace(/^file:\/\//, "")
    watchChanges: true
    onLoaded: {
      var match = text().match(/^VERSION=(.+)$/m)
      root.expectedVersion = match ? match[1].trim() : ""
    }
    onFileChanged: reload()
  }

  function enqueue(args) {
    pendingCommands = pendingCommands.concat([args])
    drainWrites()
  }

  function drainWrites() {
    if (writeProc.running || pendingCommands.length === 0) return
    var args = pendingCommands[0]
    pendingCommands = pendingCommands.slice(1)
    commandError = ""
    writeProc.command = ["/bin/sh", "-c", 'exec "$@"', "ast", binPath].concat(args)
    writeProc.running = true
  }

  function saveCurve(start) {
    if (curveLow >= curveHigh) {
      commandError = "Low temperature must be below high temperature."
      return
    }
    enqueue(["curve", "config", curveSensor, String(curveLow), String(curveHigh)])
    if (start) enqueue(["curve", "on"])
    curveDirty = false
  }

  function snapSpeed(val) {
    var min = root.fanMin || 1199
    var max = root.fanMax || 7199
    var clamped = Math.max(min, Math.min(max, val))
    var stepIndex = Math.round((clamped - min) / 50)
    return Math.min(max, min + stepIndex * 50)
  }

  function applyData(jsonStr) {
    try {
      var data = JSON.parse(jsonStr)
      if (data) {
        root.binaryAvailable = true
        root.binaryVersion = data.version || ""
        if (data.is_apple_silicon !== undefined) root.isAppleSilicon = Boolean(data.is_apple_silicon)
        if (data.has_fan !== undefined) root.hasFan = Boolean(data.has_fan)
        if (data.fan_count !== undefined) root.fanCount = Number(data.fan_count)
        if (data.device_model) root.deviceModel = data.device_model

        if (!data.error) {
          root.fanRpm = (data.fan_rpm !== undefined) ? data.fan_rpm : 0
          root.fanMin = data.fan_min || 1199
          root.fanMax = data.fan_max || 7199
          root.fanTarget = (data.fan_target !== undefined) ? data.fan_target : 0
          root.fanControlEnabled = Boolean(data.fan_control_enabled)
          root.mode = data.mode || "auto"
          root.temps = (data.temps || []).map(function(t) { return t.label })
          root.curveStatus = data.curve_status || null
          if (!root.curveDirty && !writeProc.running && root.pendingCommands.length === 0) {
            if (data.curve) {
              root.curveSensor = data.curve.sensor
              root.curveLow = data.curve.low
              root.curveHigh = data.curve.high
            } else if (root.temps.indexOf(root.curveSensor) < 0 && root.temps.length > 0) {
              root.curveSensor = root.temps[0]
            }
          }
          root.maxTemp = (data.max_temp !== undefined) ? data.max_temp : 0
          root.powerWatts = (data.power_watts !== undefined) ? data.power_watts : 0
          root.sensors = data.sensors || {}
        }
      }
    } catch (e) {
      console.warn("AppleSiliconThermals parse error:", e, jsonStr)
    }
  }

  function refresh() {
    if (!readProc.running) {
      readProc.running = true
    }
  }

  function open() {
    popupOpen = true
    refresh()
  }

  function togglePopup() {
    popupOpen = !popupOpen
    if (popupOpen) refresh()
  }

  function close() {
    popupOpen = false
  }

  function setSpeed(target) {
    enqueue(["set", String(target)])
  }

  Component.onCompleted: root.refresh()

  // Periodic polling for live sensors
  Timer {
    interval: popupOpen ? 1500 : 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: readProc
    property string buffer: ""
    command: ["/bin/sh", "-c", 'exec "$1" get', "ast", root.binPath]
    onStarted: buffer = ""
    stdout: SplitParser {
      onRead: function(line) {
        var str = String(line).trim()
        if (str.startsWith("{") && str.endsWith("}")) {
          root.applyData(str)
        } else {
          readProc.buffer += line + "\n"
        }
      }
    }
    onExited: function(code) {
      if (code !== 0) root.binaryAvailable = false
      if (readProc.buffer.trim().length > 0) {
        root.applyData(readProc.buffer.trim())
        readProc.buffer = ""
      }
    }
  }

  Process {
    id: writeProc
    property string errorBuffer: ""
    onStarted: errorBuffer = ""
    stderr: StdioCollector { waitForEnd: true; onStreamFinished: writeProc.errorBuffer = text.trim() }
    onExited: function(code) {
      if (code !== 0) {
        root.commandError = errorBuffer || "Fan command failed."
        root.pendingCommands = []
      }
      root.refresh()
      Qt.callLater(root.drainWrites)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Bar icon button with dynamic spinning and thermal status
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: !root.isAppleSilicon ? "󰌺" : (root.hasFan ? "󰈐" : "󰔏")
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption

    // Change foreground color depending on heat or manual mode
    foreground: {
      if (!root.isAppleSilicon) return Qt.rgba(1, 1, 1, 0.35)
      if (root.maxTemp >= 80) return Color.urgent
      if (root.maxTemp >= 65) return "#ffaa00"
      if (root.mode !== "auto") return Color.accent
      return root.bar ? root.bar.barForeground : Color.foreground
    }

    tooltipText: {
      if (!root.isAppleSilicon) return "Apple Silicon Thermals: Unsupported non-Apple hardware"
      if (!root.hasFan) return "Apple Silicon Thermals: " + root.maxTemp + "°C (Fanless)"
      if (root.needsSetup) return "Apple Silicon Thermals: run setup.sh"
      return "Apple Silicon Thermals (" + root.mode + "): " + root.fanRpm + " RPM | " + root.maxTemp + "°C"
    }

    onPressed: function(b) {
      root.togglePopup()
    }

    // Dynamic glyph rotation when fan is active
    NumberAnimation on textRotation {
      from: 0
      to: 360
      duration: Math.max(400, Math.round(60000 / Math.max(root.fanRpm, 600)))
      loops: Animation.Infinite
      running: root.spinIcon && root.isAppleSilicon && root.hasFan && root.fanRpm > 0
      onStopped: button.textRotation = 0
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(root.isAppleSilicon ? mainCol.implicitHeight : unsupportedCol.implicitHeight)

    // Unsupported hardware notice column
    Column {
      id: unsupportedCol
      anchors.fill: parent
      visible: !root.isAppleSilicon
      spacing: Style.space(12)

      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(36)
          height: Style.space(36)
          radius: Style.spacing.labelGap
          color: Qt.rgba(1, 0.2, 0.2, 0.15)

          Text {
            anchors.centerIn: parent
            text: "󰌺"
            color: Color.urgent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            text: "Unsupported Hardware"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: "Apple Silicon Mac required"
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSeparator { width: parent.width }

      BorderSurface {
        width: parent.width
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
        height: Style.space(78)

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(10)
          spacing: Style.space(4)

          Text {
            text: "This plugin is designed exclusively for Apple Silicon Macs (M1 / M2 / Pro / Max / Ultra) running Linux."
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            width: parent.width
          }

          Text {
            text: "No Apple SMC hardware or macsmc_hwmon driver was found on this system."
            color: Qt.rgba(1, 1, 1, 0.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
            width: parent.width
          }
        }
      }
    }

    Flickable {
      anchors.fill: parent
      visible: root.isAppleSilicon
      contentHeight: mainCol.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

    Column {
      id: mainCol
      width: parent.width
      spacing: Style.space(12)

      // Header row
      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(36)
          height: Style.space(36)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)

          Text {
            anchors.centerIn: parent
            text: root.hasFan ? "󰈐" : "󰔏"
            color: root.manualMode ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.subtitle
          }
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            text: "Apple Silicon Thermals"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: root.deviceModel + (root.hasFan ? (root.fanCount > 1 ? (" • " + root.fanCount + " Fans Synchronized") : "") : " • Fanless")
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSeparator { width: parent.width }

        // Setup notification if fan_control is not yet active
        BorderSurface {
          width: parent.width
          visible: root.needsSetup
          radius: Style.cornerRadius
          color: Qt.rgba(1, 0.6, 0, 0.15)
          borderSpec: Border.flat(Color.accent, 1)
          height: setupNotice.implicitHeight + Style.space(16)

          Column {
            id: setupNotice
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            spacing: Style.space(2)

            Text {
              text: "Setup required"
              color: "#ffbb33"
              font.bold: true
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "Run in your terminal: " + root.setupPath
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              width: parent.width
            }
          }
        }

      // Hero Status Card
      BorderSurface {
        width: parent.width
        height: Style.space(64)
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)

        Row {
          anchors.fill: parent
          anchors.margins: Style.space(10)

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            width: parent.width * 0.55

            Text {
              text: root.hasFan ? (root.fanRpm > 0 ? (root.fanRpm + " RPM") : "0 RPM (Silent)") : (root.maxTemp + "°C")
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              text: root.hasFan ? (root.mode === "curve" ? "Temperature curve" : (root.manualMode ? ("Manual (" + root.fanTarget + " RPM)") : "Automatic (SMC)")) : "Passive Cooling (Silent)"
              color: (root.hasFan && root.manualMode) ? Color.accent : Qt.rgba(1, 1, 1, 0.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width * 0.45
            spacing: Style.space(2)

            Text {
              anchors.right: parent.right
              text: root.hasFan ? (root.maxTemp + "°C") : (root.powerWatts + " W")
              color: root.maxTemp >= 75 ? Color.urgent : (root.bar ? root.bar.foreground : Color.foreground)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              text: root.hasFan ? (root.powerWatts + " W (System Power)") : "System Power"
              color: Qt.rgba(1, 1, 1, 0.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Fan Control Section
      Column {
        width: parent.width
        visible: root.hasFan
        spacing: Style.space(8)

        // Multi-fan indicator if more than 1 fan is present (Mac Studio / Mac Pro)
        BorderSurface {
          width: parent.width
          visible: root.fanCount > 1
          radius: Style.spacing.labelGap
          color: Qt.rgba(0, 0.6, 1, 0.12)
          borderSpec: Border.flat(Color.accent, 1)
          height: Style.space(26)

          Text {
            anchors.centerIn: parent
            text: "󰈐 Synchronous Multi-Fan Control (" + root.fanCount + " Fans)"
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          width: parent.width
          visible: !root.needsSetup
          spacing: Style.space(6)
          Button {
            width: (parent.width - Style.space(12)) / 3
            text: "Auto"
            selected: root.mode === "auto"
            onClicked: root.setSpeed("auto")
          }
          Button {
            width: (parent.width - Style.space(12)) / 3
            text: "Curve"
            selected: root.mode === "curve"
            onClicked: root.saveCurve(true)
          }
          Button {
            width: (parent.width - Style.space(12)) / 3
            text: "Manual"
            selected: root.manualMode
            onClicked: root.setSpeed(root.snapSpeed(root.fanRpm))
          }
        }

        Column {
          width: parent.width
          visible: !root.needsSetup && root.mode === "curve"
          spacing: Style.space(8)
          Dropdown {
            width: parent.width
            label: "Track temperature"
            options: root.temps.map(function(sensor) {
              return { value: sensor, label: sensor.replace(/\s+Temp(?:erature)?$/i, "") }
            })
            value: root.curveSensor
            onChanged: function(value) { root.curveSensor = value; root.curveDirty = true }
          }
          Row {
            width: parent.width
            spacing: Style.space(12)
            NumberField {
              label: "Minimum below °C"
              value: root.curveLow
              from: 20; to: 100
              fieldWidth: (parent.width - Style.space(12)) / 2
              onModified: function(value) { root.curveLow = value; root.curveDirty = true }
            }
            NumberField {
              label: "Maximum above °C"
              value: root.curveHigh
              from: 20; to: 100
              fieldWidth: (parent.width - Style.space(12)) / 2
              onModified: function(value) { root.curveHigh = value; root.curveDirty = true }
            }
          }
          Button {
            width: parent.width
            text: "Apply curve"
            enabled: root.curveDirty && root.curveLow < root.curveHigh
            onClicked: root.saveCurve(false)
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            color: Color.foreground
            font.pixelSize: Style.font.caption
            text: {
              var status = root.curveStatus
              if (!status) return "Waiting for curve status"
              if (status.state === "released") return "Sensor unavailable: firmware control"
              if (status.state === "firmware-override") return "Firmware override: retrying after 60 seconds"
              return status.celsius + "°C → " + status.target + " RPM"
            }
          }
          Text {
            width: parent.width
            wrapMode: Text.Wrap
            color: Qt.rgba(1, 1, 1, 0.6)
            font.pixelSize: Style.font.caption
            text: "These sensors do not measure CPU temperature and can lag CPU load."
          }
        }

        Text {
          width: parent.width
          visible: root.commandError !== ""
          text: root.commandError
          wrapMode: Text.Wrap
          color: Color.urgent
          font.pixelSize: Style.font.caption
        }

        // Slider for target RPM
        Column {
          width: parent.width
          visible: !root.needsSetup && root.manualMode
          spacing: Style.space(4)

          Item {
            width: parent.width
            height: targetLabel.implicitHeight

            Text {
              id: targetLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Target speed:"
              color: Qt.rgba(1, 1, 1, 0.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.snapSpeed(rpmSlider.liveValue) + " RPM"
              color: Color.accent
              font.bold: true
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            id: rpmSlider
            width: parent.width
            bar: root.bar
            minimum: root.fanMin
            maximum: root.fanMax
            step: 50
            integer: true
            value: root.fanTarget >= root.fanMin ? root.fanTarget : 1799
            onReleased: function(val) {
              root.setSpeed(root.snapSpeed(val))
            }
          }
        }

        Row {
          width: parent.width
          visible: !root.needsSetup && root.manualMode
          spacing: Style.space(6)
          Button {
            text: "Quiet"
            width: (parent.width - Style.space(12)) / 3
            onClicked: root.setSpeed(root.snapSpeed(root.fanMax * 0.25))
          }
          Button {
            text: "Regular"
            width: (parent.width - Style.space(12)) / 3
            onClicked: root.setSpeed(root.snapSpeed(root.fanMax * 0.5))
          }
          Button {
            text: "Max"
            width: (parent.width - Style.space(12)) / 3
            onClicked: root.setSpeed(root.fanMax)
          }
        }
      }

      // Fanless Architecture Card (Visible on MacBook Air)
      BorderSurface {
        width: parent.width
        visible: !root.hasFan
        radius: Style.cornerRadius
        color: Style.normalFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent)
        height: Style.space(72)

        Row {
          anchors.fill: parent
          anchors.margins: Style.space(10)
          spacing: Style.space(10)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "󰔏"
            color: Color.accent
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            width: parent.width - Style.space(36)

            Text {
              text: "Passive Cooling Architecture"
              color: root.bar ? root.bar.foreground : Color.foreground
              font.bold: true
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              text: "This Mac uses silent passive cooling without physical fans. Thermals are automatically managed by the Apple Silicon SoC."
              color: Qt.rgba(1, 1, 1, 0.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              width: parent.width
            }
          }
        }
      }

      PanelSeparator { width: parent.width }

      // Sensor Telemetry List
      Column {
        width: parent.width
        spacing: Style.space(6)

        Text {
          text: "APPLE SILICON SENSORS"
          color: Qt.rgba(1, 1, 1, 0.5)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Grid {
          width: parent.width
          columns: 2
          spacing: Style.space(6)

          Row {
            width: (parent.width - Style.space(6)) / 2
            spacing: Style.space(4)
            Text { text: "NAND Flash:"; color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: Style.font.caption }
            Text { text: (root.sensors.nand || "--") + "°C"; color: root.bar ? root.bar.foreground : Color.foreground; font.bold: true; font.pixelSize: Style.font.caption }
          }

          Row {
            width: (parent.width - Style.space(6)) / 2
            spacing: Style.space(4)
            Text { text: "Battery:"; color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: Style.font.caption }
            Text { text: (root.sensors.battery || "--") + "°C"; color: root.bar ? root.bar.foreground : Color.foreground; font.bold: true; font.pixelSize: Style.font.caption }
          }

          Row {
            width: (parent.width - Style.space(6)) / 2
            spacing: Style.space(4)
            Text { text: "Regulator:"; color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: Style.font.caption }
            Text { text: (root.sensors.regulator || "--") + "°C"; color: root.bar ? root.bar.foreground : Color.foreground; font.bold: true; font.pixelSize: Style.font.caption }
          }

          Row {
            width: (parent.width - Style.space(6)) / 2
            spacing: Style.space(4)
            Text { text: "Wi-Fi / BT:"; color: Qt.rgba(1, 1, 1, 0.6); font.pixelSize: Style.font.caption }
            Text { text: (root.sensors.wifi || "--") + "°C"; color: root.bar ? root.bar.foreground : Color.foreground; font.bold: true; font.pixelSize: Style.font.caption }
          }
        }
      }
    }
    }
}
}
