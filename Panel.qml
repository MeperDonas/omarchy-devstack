import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// devstack — barra de Omarchy para stacks de desarrollo locales.
//
// Un icono por proyecto (dos instancias con distinto `project` = dos proyectos),
// con chip de estado de cuatro colores, un chip por servicio y botones para
// levantar, bajar, abrir, ver logs, reiniciar y tomar el control de los puertos
// que ocupen procesos ajenos.
//
// Todo el trabajo lo hace el CLI `devstack` (bin/devstack): este panel sólo lee
// su salida JSON y le manda las acciones.
Panel {
  id: root
  moduleName: "meperdonas.devstack"
  ipcTarget: "meperdonas.devstack"

  // ------------------------------------------------------------ ajustes
  // all: el icono resume TODOS tus proyectos ("N/M arriba").
  // auto: el proyecto lo resuelve el CLI desde la ventana de terminal activa
  // (`devstack here json --window`), así el icono sigue lo que estás mirando.
  // fixed: el proyecto del ajuste `project`, como antes.
  readonly property string mode: setting("mode", "auto")
  readonly property string projectName: setting("project", "")
  // El CLI viaja DENTRO del plugin: `omarchy plugin add` clona el repo entero,
  // así que un solo `omarchy plugin add --enable` deja el widget funcionando.
  // Se usa ese binario y, si no está, el `devstack` del PATH; el ajuste
  // `command` manda si está puesto.
  readonly property string bundledCli: Quickshell.env("HOME") + "/.config/omarchy/plugins/meperdonas.devstack/bin/devstack"
  readonly property string configuredCli: setting("command", "")
  readonly property string cli: configuredCli !== ""
    ? configuredCli
    : "$( [ -x " + bundledCli + " ] && printf %s " + bundledCli + " || printf %s devstack )"
  readonly property int refreshInterval: setting("refreshIntervalSec", 5)
  readonly property int pendingTimeout: setting("pendingTimeoutSec", 300)
  readonly property int stuckAfterPolls: setting("stuckAfterPolls", 6)
  // El panel ya muestra el progreso: desde acá los avisos de escritorio sólo
  // traen el resultado (si no, caen encima del propio panel). all | final | off
  readonly property string notifyMode: setting("notifyMode", "final")
  readonly property color colorOff: setting("colorOff", "#7A8394")
  readonly property color colorError: setting("colorError", "#E05561")
  readonly property color colorWorking: setting("colorWorking", "#E5B454")
  readonly property color colorOk: setting("colorOk", "#7FBF7F")

  // ------------------------------------------------------------ estado
  property bool loaded: false
  property string name: "devstack"
  // El CLI devuelve el proyecto que resolvió (`devstack json` sin proyecto usa
  // el default): así las acciones siguientes y el botón Menú apuntan bien aunque
  // la entrada de la barra no traiga `project`.
  property string resolvedProject: ""
  property bool declared: true
  property bool fallbackUsed: false
  property string repo: ""
  property var projects: []
  property string suggested: ""
  property var services: []
  property string openService: ""
  property string pending: ""
  property int pendingSeconds: 0
  property int stuckPolls: 0

  readonly property string effectiveProject: projectName !== "" ? projectName : resolvedProject
  readonly property string projectArg: effectiveProject !== "" ? " " + effectiveProject : ""

  readonly property bool starting: pending !== ""
  readonly property bool allMode: mode === "all"
  readonly property int projectsTotal: projects.length
  readonly property int projectsUp: {
    var n = 0
    for (var i = 0; i < projects.length; i++) if (projects[i].up > 0) n++
    return n
  }
  readonly property bool everythingUp: projectsTotal > 0 && projects.every(function (p) { return p.allUp })
  // repo detectado pero sin declarar (se puede declarar con el detector)
  readonly property bool undeclared: loaded && !declared && repo !== ""
  // nada que mostrar (terminal fuera de cualquier repo)
  readonly property bool noProject: loaded && !declared && repo === ""
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

  readonly property string stateKind: allMode ? (!loaded ? "error" : everythingUp ? "ok" : projectsUp > 0 ? "working" : "off")
    : noProject ? "off"
    : undeclared ? "working"
    : !loaded ? "error"
    : starting ? "working"
    : stuck ? "error"
    : allUp ? "ok"
    : anyUp ? "working"
    : "off"
  readonly property color stateColor: stateKind === "ok" ? colorOk
    : stateKind === "error" ? colorError
    : stateKind === "working" ? colorWorking
    : colorOff

  readonly property string stateText: allMode ? (!loaded ? "Sin datos"
      : everythingUp ? "Todo arriba · " + projectsTotal
      : projectsUp > 0 ? projectsUp + "/" + projectsTotal + " arriba"
      : "Todo detenido")
    : noProject ? "Sin proyecto"
    : undeclared ? "Sin declarar · " + name
    : !loaded ? "Sin datos"
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

  // Servicios con el puerto en manos de un proceso ajeno, o que escuchan sin
  // contestar: son los que hay que "tomar" con --force.
  readonly property var foreignServices: services.filter(function (s) { return s.type !== "docker" && s.up && !s.managed })
  readonly property var unresponsive: services.filter(function (s) { return s.health !== "" && s.up && !s.healthy })
  readonly property var openSvc: services.filter(function (s) { return s.id === openService })[0]
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

  implicitWidth: allMode ? 50 : 30
  implicitHeight: bar ? bar.barSize : 26

  function refresh() { if (!probe.running) probe.running = true }
  function startPending(what) {
    root.pending = what
    root.pendingSeconds = 0
  }
  function runCommand(command) {
    // El popup se cierra: la barra queda visible y el resultado llega por
    // notificación (sólo el resultado, ver notifyMode).
    close()
    refreshTimer.restart()
    bar.run("DEVDATA_NOTIFY=" + root.notifyMode + " " + command)
  }
  // Lo que sigue saliendo por stdout (los logs) necesita una terminal: la barra
  // no tiene dónde mostrarlo, y por eso `logs` parecía no hacer nada. El
  // `|| read -r` final deja la ventana abierta si algo falla, para que el
  // mensaje no se pierda en un parpadeo.
  function runInTerminal(command) {
    close()
    refreshTimer.restart()
    bar.run("omarchy-launch-terminal bash -lc '" + "DEVDATA_NOTIFY=" + root.notifyMode + " " + command + " || read -r'")
  }
  function run(argument) {
    if (argument === "down") startPending("down")
    else if (argument === "up" || argument.indexOf("restart") === 0) startPending("up")
    else startPending("")
    runCommand(cli + projectArg + " " + argument)
  }

  Process {
    id: probe
    command: ["/bin/bash", "-lc", root.allMode
      ? cli + " all json"
      : root.mode === "fixed" ? cli + root.projectArg + " json"
      : cli + " here json --window"]
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
      if (root.allMode) {
        // all json devuelve un array de proyectos
        root.projects = data
        root.services = []
        root.name = "devstack"
        root.declared = true
        if (root.pending === "up" && root.everythingUp) root.pending = ""
        if (root.pending !== "" && root.pendingSeconds >= root.pendingTimeout) root.pending = ""
        return
      }
      root.declared = data.declared !== false
      if (!root.declared && root.mode === "auto") {
        // Sin proyecto declarado para la terminal activa: o hay un repo que
        // declarar, o no hay nada (p. ej. estás mirando el navegador).
        root.repo = data.repo || ""
        root.suggested = data.suggested || ""
        root.services = []
        root.name = data.name || ""
        root.resolvedProject = ""
        root.pending = ""
        // Respaldo: si hay un proyecto por defecto en los ajustes, se muestra
        // ése (así el icono no queda vacío por mirar otra ventana).
        if (data.repo === "" && root.projectName !== "" && !fallbackProbe.running) fallbackProbe.running = true
        return
      }
      root.fallbackUsed = false
      root.repo = data.repo || ""
      root.name = data.name || "devstack"
      root.resolvedProject = data.project || ""
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

  // Respaldo del modo auto: el proyecto del ajuste `project`, cuando la ventana
  // activa no está dentro de ningún repo detectable.
  Process {
    id: fallbackProbe
    command: ["/bin/bash", "-lc", root.cli + " " + root.projectName + " json"]
    stdout: StdioCollector { id: fallbackOutput }
    onExited: {
      var data = null
      try {
        data = JSON.parse(String(fallbackOutput.text || ""))
      } catch (error) {
        data = null
      }
      if (!data) return
      root.declared = true
      root.fallbackUsed = true
      root.name = data.name || root.projectName
      root.resolvedProject = data.project || root.projectName
      root.repo = data.repo || ""
      root.services = data.services || []
      root.openService = data.open || ""
      root.loaded = true
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
    interval: (root.starting ? 2 : root.refreshInterval) * 1000
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
    Row {
      anchors.centerIn: parent
      spacing: 1

    Text {
      id: barGlyph
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

    Text {
      visible: root.allMode
      anchors.verticalCenter: parent.verticalCenter
      text: root.projectsUp + "/" + root.projectsTotal
      color: root.stateColor
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 9
    }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      onClicked: root.toggle()
      onEntered: if (bar) bar.showTooltip(mouse, (root.name !== "" ? root.name + " · " : "") + root.stateText + (root.fallbackUsed ? " · por defecto" : ""))
      onExited: if (bar) bar.hideTooltip(mouse)
    }
  }

  PopupCard {
    id: popup
    anchorItem: iconButton
    bar: root.bar
    owner: root
    open: root.opened
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

      // Modo all: un renglón por proyecto.
      Column {
        visible: root.allMode
        width: contentColumn.width
        spacing: 5

        Repeater {
          model: root.projects

          Row {
            width: parent.width
            spacing: 6
            Rectangle {
              width: 7
              height: 7
              radius: 3.5
              anchors.verticalCenter: parent.verticalCenter
              color: modelData.allUp ? root.colorOk : (modelData.up > 0 ? root.colorWorking : root.colorOff)
            }
            Text {
              text: modelData.name
              width: parent.width - 100
              elide: Text.ElideRight
              color: bar ? bar.foreground : "white"
              font.family: bar ? bar.fontFamily : "monospace"
              font.pixelSize: 11
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: modelData.up + "/" + modelData.total
              color: modelData.allUp ? root.colorOk : (modelData.up > 0 ? root.colorWorking : root.colorOff)
              font.family: bar ? bar.fontFamily : "monospace"
              font.pixelSize: 10
              anchors.verticalCenter: parent.verticalCenter
            }
            // Un click por proyecto: levanta el que está abajo, baja el que está
            // arriba (el icono dice cuál va a hacer).
            ActionButton {
              compact: true
              icon: modelData.up > 0 ? "󰍃" : "󰐊"
              enabled: !root.starting
              onTriggered: root.runCommand(cli + " " + modelData.project + " " + (modelData.up > 0 ? "down" : "up"))
            }
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.allMode
        spacing: 8
        ActionButton { wide: true; label: "Levantar lo que falta"; icon: "󰐊"; enabled: !root.starting && !root.everythingUp; onTriggered: root.runInTerminal(cli + " all up") }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.allMode
        spacing: 8
        ActionButton { wide: true; label: "Bajar todo"; icon: "󰍃"; enabled: !root.starting && root.projectsUp > 0; onTriggered: root.runInTerminal(cli + " all down") }
      }

      // Un chip por servicio declarado en el JSON del proyecto.
      Flow {
        anchors.horizontalCenter: parent.horizontalCenter
        width: contentColumn.width
        spacing: 6
        visible: !root.allMode

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
        visible: root.declared && !root.allMode
        ActionButton { label: "Levantar"; icon: "󰐊"; enabled: !root.allUp && !root.starting; onTriggered: root.run("up") }
        ActionButton { label: "Bajar"; icon: "󰍃"; enabled: root.anyUp && !root.starting; onTriggered: root.run("down") }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.declared && !root.allMode
        spacing: 8
        ActionButton { label: "Abrir"; icon: "󰖟"; enabled: root.openSvc !== undefined && root.openSvc.up && !root.starting; onTriggered: root.run("open") }
        ActionButton { label: "Logs"; icon: "󱆃"; enabled: root.openService !== ""; onTriggered: root.runInTerminal(cli + projectArg + " logs " + root.openService) }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.declared && !root.allMode
        spacing: 8
        ActionButton { label: "Reiniciar"; icon: "󰜉"; enabled: root.anyUp && !root.starting; onTriggered: root.run("restart") }
        ActionButton { label: "Menú"; icon: "󰒓"; enabled: true; onTriggered: root.runCommand("omarchy menu summon " + (root.effectiveProject !== "" ? "dev." + root.effectiveProject : "dev")) }
      }

      // Repo reconocido pero sin declarar: se declara con el detector, en una
      // terminal, para ver qué infirió antes de que escriba nada.
      ActionButton {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.undeclared && !root.allMode
        wide: true
        label: "Declarar este stack"
        icon: "󰐊"
        enabled: !root.starting
        onTriggered: root.runInTerminal(cli + " add " + repo + (suggested !== "" ? " --name " + suggested : ""))
      }

      ActionButton {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.declared && !root.allMode && root.needsTakeover
        wide: true
        label: root.starting ? "Tomando el control…" : root.takeoverLabel
        icon: "󰒓"
        enabled: !root.starting
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
    property bool compact: false
    signal triggered()
    width: compact ? 26 : (wide ? 240 : 116)
    height: compact ? 22 : 54
    radius: 2
    color: enabled ? (buttonMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.18) : Qt.rgba(1, 1, 1, 0.10)) : Qt.rgba(1, 1, 1, 0.04)
    border.color: enabled ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.10)
    border.width: 1
    opacity: enabled ? 1 : 0.45

    Column {
      anchors.centerIn: parent
      spacing: 2
      Text {
        width: buttonRoot.compact ? buttonRoot.width : buttonRoot.width - 12
        horizontalAlignment: Text.AlignHCenter
        text: buttonRoot.icon
        color: bar ? bar.foreground : "white"
        font.family: bar ? bar.fontFamily : "monospace"
        font.pixelSize: buttonRoot.compact ? 13 : 17
      }
      Text {
        visible: !buttonRoot.compact
        width: buttonRoot.width - 12
        horizontalAlignment: Text.AlignHCenter
        text: buttonRoot.label
        color: bar ? bar.foreground : "white"
        font.family: bar ? bar.fontFamily : "monospace"
        font.pixelSize: 10
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
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
