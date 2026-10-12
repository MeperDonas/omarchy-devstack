import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// devstack — un icono en la barra para un stack de desarrollo local.
//
// Lee `devstack json` (ver bin/devstack en el repo omarchy-devstack) y muestra:
//   · un chip de estado con 4 colores: gris apagado / rojo error / amarillo
//     trabajando / verde arriba
//   · un chip por servicio declarado en el JSON del proyecto
//   · botones para levantar, bajar, abrir, reiniciar, ver logs y tomar el
//     control de puertos que ocupen procesos ajenos
//
// Varias instancias (una por proyecto) se configuran en el layout de la barra:
//   { "id": "devstack", "type": "qml", "source": "~/.config/omarchy/bar/modules/devstack.qml",
//     "project": "meperpos" }
Item {
  id: root
  property var bar
  property string moduleName
  property var settings

  // Proyecto: por el layout de la barra, o el que devstack tenga por defecto.
  readonly property string project: (settings && settings.project) ? String(settings.project) : ""
  readonly property string projectArg: project ? " " + project : ""

  property bool loaded: false
  property string name: "devstack"
  property var services: []
  property string openService: ""
  property bool popupOpen: false

  property string pending: ""
  property int pendingSeconds: 0
  property int pendingTimeout: 300
  property int stuckPolls: 0
  property int stuckAfterPolls: 6

  readonly property color colorOff: "#7A8394"
  readonly property color colorError: "#E05561"
  readonly property color colorWorking: "#E5B454"
  readonly property color colorOk: "#7FBF7F"

  readonly property bool starting: pending !== ""
  readonly property bool anyUp: services.some(function (s) { return s.up })
  readonly property bool allUp: services.length > 0 && services.every(function (s) {
    return s.health !== "" ? s.healthy : (s.port > 0 ? s.up : true)
  })
  readonly property bool stuck: stuckPolls >= stuckAfterPolls && services.some(function (s) {
    return s.health !== "" && s.up && !s.healthy
  })
  readonly property string missingText: {
    var faltan = []
    for (var i = 0; i < services.length; i++) {
      var s = services[i]
      if (s.health !== "" ? !s.healthy : (s.port > 0 && !s.up)) faltan.push(s.label)
    }
    return faltan.join(" + ")
  }

  readonly property string stateKind: !loaded ? "error"
    : starting ? "working"
    : stuck ? "error"
    : allUp ? "ok"
    : anyUp ? "working"
    : "off"
  readonly property color stateColor: stateKind === "ok" ? colorOk
    : stateKind === "error" ? colorError
    : stateKind === "working" ? colorWorking
    : colorOff

  readonly property string stateText: !loaded ? "Sin datos"
    : pending === "up" ? (pendingSeconds >= pendingTimeout ? "No terminó de levantar" : "Levantando… " + pendingSeconds + "s")
    : pending === "down" ? "Bajando… " + pendingSeconds + "s"
    : stuck ? "Servicio sin responder"
    : allUp ? (services.every(function (s) { return s.health === "" || s.healthy }) ? "Arriba" : "Arriba · compilando")
    : anyUp ? "Parcial · falta " + missingText
    : "Detenido"

  function svcColor(s) {
    if (s.health !== "") return s.healthy ? colorOk : (s.up ? (stuck ? colorError : colorWorking) : colorOff)
    return s.port > 0 ? (s.up ? colorOk : colorOff) : (s.managed ? colorOk : colorOff)
  }

  // Servicios cuyo puerto tiene un proceso que no levantó devstack, o que
  // escuchan sin contestar: los que hay que "tomar" con --force.
  readonly property var foreignServices: services.filter(function (s) { return s.type !== "docker" && s.up && !s.managed })
  readonly property var unresponsive: services.filter(function (s) { return s.health !== "" && s.up && !s.healthy })
  readonly property bool needsTakeover: foreignServices.length > 0 || unresponsive.length > 0
  readonly property string takeoverCommands: {
    var ids = []
    for (var i = 0; i < foreignServices.length; i++) ids.push(foreignServices[i].id)
    for (var j = 0; j < unresponsive.length; j++) if (ids.indexOf(unresponsive[j].id) < 0) ids.push(unresponsive[j].id)
    return ids.join(" ")
  }
  readonly property string takeoverLabel: {
    var ids = takeoverCommands.split(" ")
    if (ids.length === 1 && ids[0] !== "") {
      var one = services.filter(function (s) { return s.id === ids[0] })[0]
      return "Tomar el control de " + (one ? one.label : ids[0])
    }
    return "Tomar el control (" + (ids.length || 1) + " puertos)"
  }

  implicitWidth: 30
  implicitHeight: bar ? bar.barSize : 26

  function helperPath() { return (settings && settings.command) ? String(settings.command) : "devstack" }
  function refresh() { if (!probe.running) probe.running = true }
  function close() { root.popupOpen = false }
  function startPending(what) {
    root.pending = what
    root.pendingSeconds = 0
  }
  function runCommand(command) {
    popupOpen = false
    if (bar) bar.run(command)
    refreshTimer.restart()
  }
  function run(argument) {
    if (argument === "down") startPending("down")
    else if (argument === "up" || argument.indexOf("restart") === 0) startPending("up")
    else startPending("")
    runCommand(helperPath() + projectArg + " " + argument)
  }

  Process {
    id: probe
    command: ["/bin/bash", "-lc", root.helperPath() + root.projectArg + " json"]
    stdout: StdioCollector { id: probeOutput }
    onExited: {
      var data = null
      try {
        data = JSON.parse(String(probeOutput.text || ""))
      } catch (error) {
        data = null
      }
      if (!data) {
        root.loaded = false
        return
      }
      root.loaded = true
      root.name = data.name || "devstack"
      root.services = data.services || []
      root.openService = data.open || ""
      var unhealthy = root.services.some(function (s) { return s.health !== "" && s.up && !s.healthy })
      root.stuckPolls = unhealthy ? root.stuckPolls + 1 : 0
      // Una acción termina cuando llega a su estado destino *posible*: lo que no
      // maneja devstack (procesos ajenos) no cuenta.
      if (root.pending === "up" && root.allUp) root.pending = ""
      if (root.pending === "down") {
        var gone = root.services.every(function (s) { return !s.up || !s.managed })
        if (gone && !root.services.some(function (s) { return s.type === "docker" && s.up })) root.pending = ""
      }
      if (root.pending !== "" && root.pendingSeconds >= root.pendingTimeout) root.pending = ""
    }
  }

  Timer {
    id: pendingTimer
    interval: 1000
    repeat: true
    running: root.starting
    onTriggered: root.pendingSeconds += 1
  }

  Timer {
    id: refreshTimer
    interval: root.starting ? 2000 : 5000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  Rectangle {
    id: iconButton
    anchors.fill: parent
    radius: height / 2
    color: mouse.containsMouse ? Qt.rgba(1, 1, 1, 0.10) : "transparent"

    // Sin spinner: el icono respira mientras hay una acción en curso.
    Text {
      id: barGlyph
      anchors.centerIn: parent
      text: "󰒋"
      color: root.stateColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 16
      opacity: root.stateKind === "off" ? 0.72 : 1

      SequentialAnimation on opacity {
        running: root.stateKind === "working"
        loops: Animation.Infinite
        NumberAnimation { from: 0.45; to: 1; duration: 950; easing.type: Easing.InOutSine }
        NumberAnimation { from: 1; to: 0.45; duration: 950; easing.type: Easing.InOutSine }
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: root.popupOpen = !root.popupOpen
      onEntered: if (bar) bar.showTooltip(mouse, root.name + " · " + root.stateText)
      onExited: if (bar) bar.hideTooltip(mouse)
    }
  }

  PopupCard {
    id: popup
    anchorItem: iconButton
    bar: root.bar
    owner: root
    open: root.popupOpen
    // "hover": sin HyprlandFocusGrab, así el popup sobrevive al clic-arrastre de
    // slurp cuando estás encuadrando un screenshot.
    triggerMode: "hover"
    contentWidth: 320
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight + 32)
    margin: 14

    Column {
      id: contentColumn
      anchors.fill: parent
      anchors.margins: 16
      spacing: 14

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 10
        Text {
          text: "󰒋"
          color: root.stateColor
          font.family: bar ? bar.fontFamily : "monospace"
          font.pixelSize: 19
        }
        Text {
          text: root.name
          color: bar ? bar.foreground : "white"
          font.family: bar ? bar.fontFamily : "monospace"
          font.pixelSize: 15
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // Chip de estado: una sola línea; mientras hay una acción en curso muestra
      // tres puntos que rebotan.
      Rectangle {
        id: statusPill
        anchors.horizontalCenter: parent.horizontalCenter
        height: 26
        width: pillRow.implicitWidth + 22
        radius: height / 2
        color: Qt.rgba(root.stateColor.r, root.stateColor.g, root.stateColor.b, 0.12)
        border.width: 1
        border.color: Qt.rgba(root.stateColor.r, root.stateColor.g, root.stateColor.b, 0.38)

        Row {
          id: pillRow
          anchors.centerIn: parent
          spacing: 7

          Item {
            visible: root.starting
            width: 23
            height: 14

            Row {
              anchors.centerIn: parent
              spacing: 4

              Repeater {
                model: 3

                Rectangle {
                  width: 5
                  height: 5
                  radius: 2.5
                  color: root.stateColor
                  opacity: 0.2

                  SequentialAnimation on opacity {
                    running: root.starting
                    loops: Animation.Infinite
                    PauseAnimation { duration: index * 190 }
                    NumberAnimation { from: 0.2; to: 1; duration: 330; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 1; to: 0.2; duration: 330; easing.type: Easing.InOutSine }
                    PauseAnimation { duration: (2 - index) * 190 }
                  }
                }
              }
            }
          }

          Rectangle {
            visible: !root.starting
            width: 7
            height: 7
            radius: 3.5
            color: root.stateColor
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.stateText
            color: root.stateColor
            font.family: bar ? bar.fontFamily : "monospace"
            font.pixelSize: 11
            font.bold: root.stateKind === "ok" || root.starting
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }

      // Barra de progreso indeterminada: fina y lenta, sólo con acción en curso.
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.starting
        width: contentColumn.width
        height: 2
        radius: 1
        color: Qt.rgba(root.stateColor.r, root.stateColor.g, root.stateColor.b, 0.10)
        clip: true

        Rectangle {
          id: progressSegment
          height: parent.height
          radius: 1
          width: parent.width * 0.22
          color: Qt.rgba(root.stateColor.r, root.stateColor.g, root.stateColor.b, 0.85)

          SequentialAnimation on x {
            running: root.starting
            loops: Animation.Infinite
            NumberAnimation { from: 0; to: progressSegment.parent.width - progressSegment.width; duration: 1500; easing.type: Easing.InOutSine }
            NumberAnimation { from: progressSegment.parent.width - progressSegment.width; to: 0; duration: 1500; easing.type: Easing.InOutSine }
          }
        }
      }

      // Un chip por servicio declarado en el JSON del proyecto.
      Flow {
        anchors.horizontalCenter: parent.horizontalCenter
        width: contentColumn.width
        spacing: 6

        Repeater {
          model: root.services

          Chip {
            label: modelData.label + ((modelData.type !== "docker" && modelData.up && !modelData.managed) ? " ·ext" : "")
            lit: modelData.health !== "" ? modelData.healthy : modelData.up
            accent: root.svcColor(modelData)
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8
        ActionButton { label: "Levantar"; icon: "󰐊"; enabled: !root.allUp && root.pending === ""; onTriggered: root.run("up") }
        ActionButton { label: "Bajar"; icon: "󰍃"; enabled: root.anyUp && root.pending === ""; onTriggered: root.run("down") }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8
        ActionButton { label: "Abrir"; icon: "󰖟"; enabled: root.openService !== "" && root.pending === ""; onTriggered: root.run("open") }
        ActionButton { label: "Logs"; icon: "󱆃"; enabled: root.openService !== ""; onTriggered: root.run("logs " + root.openService) }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8
        ActionButton { label: "Reiniciar"; icon: "󰜉"; enabled: root.anyUp && root.pending === ""; onTriggered: root.run("restart") }
        ActionButton { label: "Menú"; icon: "󰒓"; enabled: true; onTriggered: root.runCommand("omarchy menu summon dev" + root.project) }
      }

      ActionButton {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.needsTakeover
        wide: true
        label: root.starting ? "Tomando el control…" : root.takeoverLabel
        icon: "󰒓"
        enabled: root.pending === ""
        onTriggered: root.run("restart " + root.takeoverCommands + " --force")
      }
    }
  }

  component Chip: Rectangle {
    id: chipRoot
    property string label
    property bool lit: false
    property color accent: "#7A8394"
    implicitWidth: chipRow.implicitWidth + 16
    height: 22
    radius: height / 2
    color: Qt.rgba(accent.r, accent.g, accent.b, lit ? 0.14 : 0.06)
    border.width: 1
    border.color: Qt.rgba(accent.r, accent.g, accent.b, lit ? 0.45 : 0.18)

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: 5
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 7
        height: 7
        radius: 3.5
        color: chipRoot.accent
        opacity: chipRoot.lit ? 1 : 0.55
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: chipRoot.label
        color: chipRoot.accent
        opacity: chipRoot.lit ? 1 : 0.7
        font.family: bar ? bar.fontFamily : "monospace"
        font.pixelSize: 10
      }
    }
  }

  component ActionButton: Rectangle {
    id: buttonRoot
    property string label
    property string icon: ""
    property bool enabled: true
    property bool wide: false
    signal triggered()
    width: wide ? 240 : 116
    height: 54
    radius: 2
    color: enabled ? (buttonMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.10)) : Qt.rgba(1, 1, 1, 0.04)
    border.color: enabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.10)
    border.width: 1
    opacity: enabled ? 1 : 0.45

    Column {
      anchors.centerIn: parent
      spacing: 2
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: buttonRoot.icon
        color: bar ? bar.foreground : "white"
        font.family: bar ? bar.fontFamily : "monospace"
        font.pixelSize: 17
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: buttonRoot.label
        color: bar ? bar.foreground : "white"
        font.family: bar ? bar.fontFamily : "monospace"
        font.pixelSize: 10
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
        width: buttonRoot.width - 12
      }
    }

    MouseArea {
      id: buttonMouse
      anchors.fill: parent
      enabled: parent.enabled
      hoverEnabled: true
      onClicked: parent.triggered()
    }
  }
}
