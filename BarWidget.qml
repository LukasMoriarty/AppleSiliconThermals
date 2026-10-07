import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "AppleSiliconThermals"

  property int fanRpm: 0
  property int fanMin: 1199
  property int fanMax: 7199
  property int fanTarget: 0
  property bool fanControlEnabled: false
  property bool manualMode: false
  property real maxTemp: 0
  property real powerWatts: 0
  property string deviceModel: "Apple Silicon Mac"
  property bool isAppleSilicon: true
  property bool hasFan: true
  property int fanCount: 1
  // One entry per fan: { index, label, rpm, min, max, target }
  property var fans: []
  property var sensors: ({})

  // Presets scale with the highest fan max detected (Stats-style % of max).
  // Max uses the exact hardware value; the broker clamps each fan to its own range.
  readonly property int quietRpm: root.snapSpeed(Math.round(root.fanMax * 0.25))
  readonly property int regularRpm: root.snapSpeed(Math.round(root.fanMax * 0.5))
  readonly property int maxRpm: root.fanMax

  property bool popupOpen: false
  readonly property string helperPath: Qt.resolvedUrl("helper.sh").toString().replace(/^file:\/\//, "")

  function snapSpeed(val) {
    var min = root.fanMin || 1199
    var max = root.fanMax || 7199
    var clamped = Math.max(min, Math.min(max, val))
    var stepIndex = Math.round((clamped - min) / 50)
    return Math.min(max, min + stepIndex * 50)
  }

  function formatRpm(val) {
    return String(Math.round(Number(val) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }

  function applyData(jsonStr) {
    try {
      var data = JSON.parse(jsonStr)
      if (data) {
        if (data.is_apple_silicon !== undefined) root.isAppleSilicon = Boolean(data.is_apple_silicon)
        if (data.has_fan !== undefined) root.hasFan = Boolean(data.has_fan)
        if (data.fan_count !== undefined) root.fanCount = Number(data.fan_count)
        if (data.device_model) root.deviceModel = data.device_model

        if (!data.error) {
          root.fanRpm = (data.fan_rpm !== undefined) ? data.fan_rpm : 0
          root.fanMin = data.fan_min || 1199
          root.fanMax = data.fan_max || 7199
          root.fanTarget = (data.fan_target !== undefined) ? data.fan_target : 0
          root.fans = Array.isArray(data.fans) ? data.fans : []
          root.fanControlEnabled = Boolean(data.fan_control_enabled)
          root.manualMode = Boolean(data.manual_mode)
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

  function togglePopup() {
    popupOpen = !popupOpen
    if (popupOpen) refresh()
  }

  function close() {
    popupOpen = false
  }

  function setSpeed(target) {
    writeProc.targetSpeed = String(target)
    writeProc.running = true
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
    command: [root.helperPath, "get"]
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
      if (readProc.buffer.trim().length > 0) {
        root.applyData(readProc.buffer.trim())
        readProc.buffer = ""
      }
    }
  }

  Process {
    id: writeProc
    property string targetSpeed: "auto"
    command: [root.helperPath, "set", targetSpeed]
    onExited: function(code) {
      root.refresh()
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
      if (root.manualMode) return Color.accent
      return root.bar ? root.bar.barForeground : Color.foreground
    }

    tooltipText: {
      if (!root.isAppleSilicon) return "Apple Silicon Thermals: Unsupported non-Apple hardware"
      if (!root.hasFan) return "Apple Silicon Thermals: " + root.maxTemp + "°C (Fanless)"
      return "Apple Silicon Thermals: " + root.fanRpm + " RPM | " + root.maxTemp + "°C"
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
      running: root.isAppleSilicon && root.hasFan && root.fanRpm > 0
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

    Column {
      id: mainCol
      anchors.fill: parent
      visible: root.isAppleSilicon
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
            text: root.deviceModel + (root.hasFan ? (root.fanCount > 1 ? (" • " + root.fanCount + " Fans") : "") : " • Fanless")
            color: Qt.rgba(1, 1, 1, 0.6)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSeparator { width: parent.width }

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
              text: root.hasFan ? (root.manualMode ? ("Manual (" + root.fanTarget + " RPM)") : "Automatic (SMC)") : "Passive Cooling (Silent)"
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

        // Per-fan status, only shown when more than one fan is present (e.g. 14"/16" MacBook Pro, Mac Studio).
        // Each fan has its own hardware range; the shared target is clamped per fan by the broker.
        BorderSurface {
          width: parent.width
          visible: root.fans.length > 1
          radius: Style.spacing.labelGap
          color: Qt.rgba(0, 0.6, 1, 0.12)
          borderSpec: Border.flat(Color.accent, 1)
          height: fanList.implicitHeight + Style.space(12)

          Column {
            id: fanList
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(8)
            spacing: Style.space(4)

            Repeater {
              model: root.fans

              Item {
                required property var modelData
                width: fanList.width
                height: fanName.implicitHeight

                Text {
                  id: fanName
                  anchors.left: parent.left
                  text: "󰈐 " + ((modelData.label && modelData.label !== "Fan") ? modelData.label : ("Fan " + modelData.index))
                  color: Color.accent
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  anchors.right: parent.right
                  text: root.formatRpm(modelData.rpm) + " RPM"
                    + (modelData.target > 0 ? (" → " + root.formatRpm(modelData.target)) : "")
                    + "  (" + root.formatRpm(modelData.min) + "–" + root.formatRpm(modelData.max) + ")"
                  color: root.bar ? root.bar.foreground : Color.foreground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // Setup notification if fan_control is not yet active
        BorderSurface {
          width: parent.width
          visible: !root.fanControlEnabled
          radius: Style.cornerRadius
          color: Qt.rgba(1, 0.6, 0, 0.15)
          borderSpec: Border.flat(Color.accent, 1)
          height: Style.space(68)

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(8)
            spacing: Style.space(2)

            Text {
              text: "⚠ Manual fan control not configured"
              color: "#ffbb33"
              font.bold: true
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              text: "Run the one-time system setup documented in the plugin README to enable."
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              width: parent.width
            }
          }
        }

        // Manual mode toggle row
        Row {
          width: parent.width
          visible: root.fanControlEnabled
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Manual Fan Speed Control"
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            width: parent.width - toggleSwitch.width - Style.space(8)
          }

          ToggleSwitch {
            id: toggleSwitch
            anchors.verticalCenter: parent.verticalCenter
            checked: root.manualMode
            onToggled: {
              if (root.manualMode) {
                root.setSpeed("auto")
              } else {
                root.setSpeed(root.fanRpm >= root.fanMin ? root.snapSpeed(root.fanRpm) : root.quietRpm)
              }
            }
          }
        }

        // Slider for target RPM
        Column {
          width: parent.width
          visible: root.fanControlEnabled && root.manualMode
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
            value: root.fanTarget >= root.fanMin ? root.fanTarget : root.quietRpm
            onReleased: function(val) {
              root.setSpeed(val >= root.fanMax ? root.maxRpm : root.snapSpeed(val))
            }
          }
        }

        // Preset Chips
        Row {
          width: parent.width
          visible: root.fanControlEnabled
          spacing: Style.space(6)

          Button {
            text: "Auto"
            tooltipText: "Automatic Apple SMC hardware management"
            width: (parent.width - Style.space(18)) / 4
            selected: !root.manualMode
            onClicked: root.setSpeed("auto")
          }

          Button {
            text: "Quiet"
            tooltipText: "Quiet cooling: 25% (" + root.formatRpm(root.quietRpm) + " RPM)"
            width: (parent.width - Style.space(18)) / 4
            selected: root.manualMode && Math.abs(root.fanTarget - root.quietRpm) < 250
            onClicked: root.setSpeed(root.quietRpm)
          }

          Button {
            text: "Regular"
            tooltipText: "Balanced cooling: 50% (" + root.formatRpm(root.regularRpm) + " RPM)"
            width: (parent.width - Style.space(18)) / 4
            selected: root.manualMode && Math.abs(root.fanTarget - root.regularRpm) < 250
            onClicked: root.setSpeed(root.regularRpm)
          }

          Button {
            text: "Max"
            tooltipText: "Maximum cooling: 100% (" + root.formatRpm(root.maxRpm) + " RPM)"
            width: (parent.width - Style.space(18)) / 4
            selected: root.manualMode && root.fanTarget >= root.maxRpm - 50
            onClicked: root.setSpeed(root.maxRpm)
          }
        }

        // Percentage subtext row for preset chips
        Row {
          width: parent.width
          visible: root.fanControlEnabled
          spacing: Style.space(6)

          Text {
            width: (parent.width - Style.space(18)) / 4
            horizontalAlignment: Text.AlignHCenter
            text: "SMC"
            color: Qt.rgba(1, 1, 1, 0.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            width: (parent.width - Style.space(18)) / 4
            horizontalAlignment: Text.AlignHCenter
            text: "25%"
            color: Qt.rgba(1, 1, 1, 0.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            width: (parent.width - Style.space(18)) / 4
            horizontalAlignment: Text.AlignHCenter
            text: "50%"
            color: Qt.rgba(1, 1, 1, 0.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            width: (parent.width - Style.space(18)) / 4
            horizontalAlignment: Text.AlignHCenter
            text: "100%"
            color: Qt.rgba(1, 1, 1, 0.45)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
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
