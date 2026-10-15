import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import "i18n.js" as I18n

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
  // Al darle a un botón, ¿se cierra el popup? Por defecto NO: te quedás viendo
  // cómo avanza (y podés seguir tocando). Poné true para el comportamiento
  // viejo (cerrar y esperar la notificación).
  readonly property bool closeAfterAction: setting("closeAfterAction", false)
  // Ancho del popup y ancho útil (lo que ocupan los botones): con los botones
  // llenando ese ancho no queda el hueco a los costados.
  readonly property int popupWidth: setting("popupWidth", 340)
  readonly property int contentWidth: popupWidth - 32
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
  // Lista de proyectos para el selector (sólo se pide al abrir el popup: en
  // `auto` el sondeo normal trae un proyecto, no la lista).
  property var projectList: []
  // Buscador: `devstack find` recorre tus carpetas y devuelve candidatos.
  property var found: []
  property bool searching: false
  property bool findRunning: false
  // Qué proyectos tienen una acción en curso disparada desde una fila (así el
  // botón chico muestra lo mismo que el grande).
  property var startingProjects: []
  property var startingAt: ({})
  // Proyecto fijado a mano: sin pin el widget sigue el foco de la terminal.
  property string pinned: ""
  // Firma de lo último aplicado: cada 5 s llega el mismo JSON y reasignar
  // `services`/`projects` recrea los delegados y sus animaciones de entrada.
  property string appliedSignature: ""
  property string appliedListSignature: ""
  property string suggested: ""
  property var services: []
  property string openService: ""
  property string pending: ""
  property int pendingSeconds: 0
  // Cuándo empezó la acción y qué dijo el CLI si falló: con eso el widget sabe
  // que una acción terminó, en vez de mostrar "levantando" hasta el timeout.
  property real pendingAt: 0
  property string failure: ""
  property int stuckPolls: 0
  // Idioma del widget (en | es). Vive en ~/.config/devstack/lang y se cambia
  // con el botoncito del popup o con `devstack lang en|es`.
  property string lang: "en"

  // El proyecto de las ACCIONES: el que el CLI resolvió (foco, ajuste o casa) o,
  // si todavía no resolvió nada, el del ajuste. Con `project` fijo acá, los
  // botones actuaban sobre ese proyecto aunque el popup mostrara otro.
  readonly property string effectiveProject: resolvedProject !== "" ? resolvedProject : projectName
  readonly property string projectArg: effectiveProject !== "" ? " " + shq(effectiveProject) : ""

  readonly property bool starting: pending !== ""
  readonly property bool allMode: mode === "all"
  readonly property var rowModel: allMode ? projects : projectList
  // En `all` los renglones son el contenido; en los otros modos son el
  // selector, y sólo tienen sentido si hay más de un proyecto declarado.
  readonly property bool showRows: allMode || projectList.length > 0
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
  // Servicios de un proyecto que responden pero no son de devstack: el puerto
  // lo tiene otro (típicamente el mismo puerto que declara otro proyecto), así
  // que "arriba" no significa que ese stack esté levantado.
  function foreignCount(p) {
    var svcs = p.services || []
    var n = 0
    for (var i = 0; i < svcs.length; i++) {
      var s = svcs[i]
      if (s.up && s.managed === false && s.type !== "docker") n++
    }
    return n
  }

  // Puertos que comparto con otro proyecto declarado (el "arriba" de uno puede
  // ser el proceso del otro).
  readonly property var clashPorts: {
    var mine = services.filter(function (s) { return s.port > 0 }).map(function (s) { return s.port })
    var out = []
    for (var i = 0; i < projectList.length; i++) {
      var other = projectList[i]
      if (other.project === root.effectiveProject) continue
      var svcs = other.services || []
      for (var j = 0; j < svcs.length; j++) {
        var p = svcs[j].port
        if (p > 0 && mine.indexOf(p) >= 0 && out.indexOf(p) < 0) out.push(p)
      }
    }
    return out
  }
  readonly property bool hasClash: !allMode && clashPorts.length > 0

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
    : stuck && pending === "" ? "error"
    : allUp ? "ok"
    : anyUp ? "working"
    : "off"
  readonly property color stateColor: stateKind === "ok" ? colorOk
    : stateKind === "error" ? colorError
    : stateKind === "working" ? colorWorking
    : colorOff

  readonly property string stateText: (allMode ? (!loaded ? t("noData")
      : everythingUp ? t("allUp") + projectsTotal
      : projectsUp > 0 ? projectsUp + "/" + projectsTotal + " arriba"
      : t("allStopped"))
    : noProject ? (root.showRows ? t("noProjectPick") : t("noProject"))
    : undeclared ? t("undeclared") + name
    : !loaded ? t("noData")
    : failure !== "" ? t("failed") + failure
    : pending === "up" ? (pendingSeconds >= pendingTimeout ? t("didNotFinish")
        : t("lifting") + pendingSeconds + "s" + (stuck ? t("serviceNoAnswer") : ""))
    : pending === "down" ? t("stopping") + pendingSeconds + "s"
    : stuck && pending === "" ? t("serviceNotResponding")
    : allUp ? (services.every(function (s) { return s.health === "" || s.healthy }) ? t("up") : t("upCompiling"))
    : anyUp ? t("partial") + missingText
    // El chip dice de dónde salió el proyecto: del foco, de tu ajuste/casa
    // ("por defecto") o porque lo fijaste. Así "Quitar el fijado" se entiende.
    : t("stopped")) + (allMode || !declared ? "" : pinned !== "" ? t("originPinned") : fallbackUsed ? t("originDefault") : t("originFocus"))

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
      return root.t("takeoverOne", { label: one ? one.label : ids[0] })
    }
    return root.t("takeoverMany", { n: ids.length || 1 })
  }

  implicitWidth: allMode ? 50 : 30
  implicitHeight: bar ? bar.barSize : 26

  Process {
    id: langProbe
    command: ["/bin/bash", "-lc", root.cli + " lang"]
    stdout: StdioCollector { id: langOutput }
    onExited: {
      var value = String(langOutput.text || "").trim()
      root.lang = value === "es" ? "es" : "en"
    }
  }

  function toggleLang() {
    var next = root.lang === "en" ? "es" : "en"
    bar.run("DEVDATA_NOTIFY=off " + cli + " lang " + next)
    root.lang = next
    refresh()
  }

  function refresh() { if (!probe.running) probe.running = true }
  function startPending(what) {
    root.pending = what
    root.pendingSeconds = 0
    root.pendingAt = Date.now() / 1000
    root.failure = ""
  }
  // Cita para el shell: '…' con los ' internos como '\''. Todo valor que venga de
  // afuera (rutas detectadas, nombres de proyecto, ids de servicio) pasa por acá
  // antes de entrar en un comando: un nombre de carpeta con $(…) o ; no puede
  // ejecutar nada.
  // Traducción: t("clave") o t("clave", { n: 7 })
  function t(key, subs) {
    return I18n.t(root.lang, key, subs)
  }

  function shq(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function runCommand(command) {
    if (root.closeAfterAction) close()
    refreshTimer.restart()
    refreshList()
    bar.run("DEVDATA_NOTIFY=" + root.notifyMode + " " + command)
  }
  // Lo que sigue saliendo por stdout (los logs) necesita una terminal: la barra
  // no tiene dónde mostrarlo, y por eso `logs` parecía no hacer nada. El
  // `|| read -r` final deja la ventana abierta si algo falla, para que el
  // mensaje no se pierda en un parpadeo.
  function runInTerminal(command) {
    if (root.closeAfterAction) close()
    refreshTimer.restart()
    // El comando entero va citado: así el shell que lanza el terminal lo recibe
    // tal cual y lo único que se parsea una segunda vez es lo que ya viene
    // citado adentro.
    bar.run("omarchy-launch-terminal bash -lc "
      + shq("DEVDATA_NOTIFY=" + root.notifyMode + " " + command + " || read -r"))
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
      : root.pinned !== "" ? cli + " " + root.pinned + " json"
      : root.mode === "fixed" ? cli + root.projectArg + " json"
      // El respaldo viaja como argumento: una sola pasada, sin segunda sonda.
      // Precedencia: la terminal que mirás → el ajuste `project` → el proyecto
      // de casa (`devstack use`). Todo en una sola llamada.
      : cli + " here json --window" + (root.projectName !== "" ? " --fallback " + root.projectName : "") + " --default"]
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
        var sigAll = JSON.stringify(data)
        if (sigAll !== root.appliedListSignature) {
          root.appliedListSignature = sigAll
          root.projects = data
        }
        root.services = []
        root.name = "devstack"
        root.declared = true
        if (root.pending === "up" && root.everythingUp) root.pending = ""
        if (root.pending !== "" && root.pendingSeconds >= root.pendingTimeout) root.pending = ""
      // Red de seguridad: si un servicio está arriba sin responder hace rato, la
      // acción no está progresando; se suelta el "levantando" (la acción sigue,
      // sólo se libera la UI).
      else if (root.pending !== "" && root.stuck && root.pendingSeconds >= root.stuckAfterPolls * 25) {
        root.failure = root.t("stuckHint")
        root.pending = ""
      }
      // El CLI deja su resultado al terminar (result.json): si la acción ya
      // acabó, se acabó el "levantando" — y si falló, se dice por qué.
      var lr = data.lastResult
      if (root.pending !== "" && lr && (lr.action === root.pending
          || (root.pending === "up" && lr.action === "restart"))
          && (lr.at || 0) + 2 >= root.pendingAt) {
        if (lr.ok === false) root.failure = lr.detail || "la última acción falló"
        root.pending = ""
      }
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
        return
      }
      // `fallback` lo informa el propio CLI cuando usó el respaldo del ajuste.
      root.fallbackUsed = data.fallback === true
      if (root.failure !== "" && root.pending === "") {
        // el aviso de error dura hasta la próxima acción o hasta que el estado
        // cambie solo (se limpia cuando ya no hay nada que reclamar)
        if (root.allUp) root.failure = ""
      }
      var sig = JSON.stringify([data.name, data.project, data.repo, data.open, data.services])
      if (sig !== root.appliedSignature) {
        root.appliedSignature = sig
        root.repo = data.repo || ""
        root.name = data.name || "devstack"
        root.resolvedProject = data.project || ""
        root.services = data.services || []
        root.openService = data.open || ""
      }
      var unhealthy = root.services.some(function (s) { return s.health !== "" && s.up && !s.healthy })
      root.stuckPolls = unhealthy ? root.stuckPolls + 1 : 0
      if (root.pending !== "" && root.pendingSeconds >= root.pendingTimeout) root.pending = ""
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

  // Lista para el selector: `all json` al abrir el popup (y tras una acción).
  Process {
    id: listProbe
    command: ["/bin/bash", "-lc", root.cli + " all json"]
    stdout: StdioCollector { id: listOutput }
    onExited: {
      var data = null
      try {
        data = JSON.parse(String(listOutput.text || ""))
      } catch (error) {
        data = null
      }
      if (!data || !data.length) return
      // Las acciones disparadas desde una fila también terminan: se sueltan
      // cuando su estado llegó o cuando su último resultado es de esta corrida.
      var still = []
      for (var i = 0; i < root.startingProjects.length; i++) {
        var name = root.startingProjects[i]
        var proj = null
        for (var j = 0; j < data.length; j++) if (data[j].project === name) { proj = data[j]; break }
        if (!proj) continue
        var lr = proj.lastResult
        if (proj.up > 0 || (lr && (lr.at || 0) + 2 >= (root.startingAt[name] || 0))) continue
        still.push(name)
      }
      if (still.length !== root.startingProjects.length) root.startingProjects = still

      var sig = JSON.stringify(data)
      if (sig === root.appliedListSignature) return
      root.appliedListSignature = sig
      root.projectList = data
    }
  }

  Process {
    id: findProbe
    command: ["/bin/bash", "-lc", root.cli + " find --json"]
    stdout: StdioCollector { id: findOutput }
    onRunningChanged: root.findRunning = running
    onExited: {
      var data = null
      try {
        data = JSON.parse(String(findOutput.text || ""))
      } catch (error) {
        data = null
      }
      root.found = data && data.length ? data : []
      root.findRunning = false
    }
  }

  function refreshList() {
    if (root.allMode || listProbe.running) return
    listProbe.running = true
  }

  // Fijar/soltar un proyecto: el renglón se clickea y el widget deja de seguir
  // el foco (o vuelve a seguirlo). El pin se guarda también en el CLI
  // (`devstack use`), así sobrevive al reinicio del shell y el CLI queda de
  // acuerdo con lo que muestra la barra.
  function pinProject(project) {
    if (root.allMode || !project) return
    root.pinned = project
    bar.run("DEVDATA_NOTIFY=off " + cli + " use " + project)
    refresh()
  }

  function unpinProject() {
    if (root.pinned === "") return
    root.pinned = ""
    bar.run("DEVDATA_NOTIFY=off " + cli + " use --clear")
    refresh()
  }

  function togglePin(project) {
    if (root.allMode || !project) return
    if (root.pinned === project) root.unpinProject()
    else root.pinProject(project)
  }

  // Buscar proyectos a mano: recorre tus carpetas (devstack find) y ofrece lo
  // que se puede levantar, sin depender de la lectura automática.
  function isStarting(project) {
    return root.startingProjects.indexOf(project) >= 0
  }

  function markStarting(project) {
    var at = root.startingAt
    at[project] = Date.now() / 1000
    root.startingAt = at
    if (root.startingProjects.indexOf(project) < 0) {
      var list = root.startingProjects.slice()
      list.push(project)
      root.startingProjects = list
    }
  }

  function findProjects() {
    root.searching = true
    root.found = []
    if (!findProbe.running) findProbe.running = true
  }

  // Elegir un candidato: si ya está declarado se levanta/baja y queda fijado; si
  // no, se declara y se levanta en una terminal para que veas lo que propone el
  // detector antes de que escriba nada por vos.
  function pickFound(candidate) {
    if (!candidate) return
    if (candidate.declared) {
      root.searching = false
      root.pinProject(candidate.project)
      root.runCommand(cli + " " + shq(candidate.project) + " " + (candidate.up > 0 ? "down" : "up"))
      return
    }
    // La lista que estás mirando ya no vale: ese candidato dejó de estar sin
    // declarar (y si el detector no lo pudo declarar, la próxima búsqueda lo
    // vuelve a mostrar tal cual).
    refindTimer.restart()
    root.runInTerminal(cli + " add " + shq(candidate.dir) + " --name " + shq(candidate.suggested)
      + " && " + cli + " " + shq(candidate.suggested) + " up")
  }

  onOpenedChanged: if (opened) { refresh(); refreshList() }

  // Tras elegir un candidato, la búsqueda se refresca sola (el popup se cierra
  // para la acción: al volver está al día).
  Timer {
    id: refindTimer
    interval: 7000
    onTriggered: if (root.searching && !findProbe.running) findProbe.running = true
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
    // Sólo el primer minuto de una acción va a 2 s (una compilación en frío
    // tarda, pero sondear cada 2 s durante los 5 minutos del timeout es
    // gastar sin motivo).
    interval: (root.starting && root.pendingSeconds < 60 ? 2 : root.refreshInterval) * 1000
    repeat: true
    running: true
    onTriggered: {
      root.refresh()
      // Con el popup abierto, los renglones de proyectos también se refrescan
      // (si no, quedaban con el estado de cuando lo abriste: "1/3" con todo
      // levantado).
      if (root.opened) root.refreshList()
    }
  }

  Component.onCompleted: {
    langProbe.running = true
    refresh()
  }

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
      onClicked: {
        root.toggle()
        if (root.opened) root.refreshList()
      }
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
    contentWidth: root.popupWidth
    contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight + 32)
    margin: 14

    Column {
      id: contentColumn
      anchors.fill: parent
      anchors.margins: 16
      spacing: 14

        // Encabezado: ícono y proyecto centrados, y a la derecha el botoncito de
        // idioma (alterna EN/ES, no es un dropdown).
        Item {
          width: contentColumn.width
          height: headerRow.implicitHeight > 0 ? headerRow.implicitHeight : 26

      Row {
        id: headerRow
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

        ActionButton {
          compact: true
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          icon: root.lang.toUpperCase()
          onTriggered: root.toggleLang()
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

      // Un renglón por proyecto: en `all` es el contenido; en `auto`/`fixed`
      // es el selector (un click fija ese proyecto, otro click vuelve al foco).
      Column {
        visible: root.showRows && !root.searching
        width: contentColumn.width
        spacing: 5

        Repeater {
          model: root.rowModel

          Item {
            width: parent.width
            height: 22

            Rectangle {
              anchors.fill: parent
              radius: 4
              color: rowHover.containsMouse && !root.allMode ? Qt.rgba(1, 1, 1, 0.07) : "transparent"
            }

            MouseArea {
              id: rowHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.togglePin(modelData.project)
            }

            Row {
            anchors.fill: parent
            spacing: 6
            Rectangle {
              width: 7
              height: 7
              radius: 3.5
              anchors.verticalCenter: parent.verticalCenter
              // Ámbar si lo que responde no es de devstack: así no se confunde
              // "alguien atiende el puerto" con "mi stack está arriba".
              color: modelData.allUp ? (root.foreignCount(modelData) > 0 ? root.colorWorking : root.colorOk)
                : (modelData.up > 0 ? root.colorWorking : root.colorOff)
            }
            Text {
              text: modelData.name
              width: parent.width - 100
              elide: Text.ElideRight
              color: bar ? bar.foreground : "white"
              font.family: bar ? bar.fontFamily : "monospace"
              font.pixelSize: 11
              // El que se está mostrando (por foco o por pin) va en negrita.
              font.bold: !root.allMode && modelData.project === root.resolvedProject
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: root.isStarting(modelData.project) ? root.t("liftingRow") : modelData.up + "/" + modelData.total
              color: modelData.allUp ? (root.foreignCount(modelData) > 0 ? root.colorWorking : root.colorOk)
                : (modelData.up > 0 ? root.colorWorking : root.colorOff)
              font.family: bar ? bar.fontFamily : "monospace"
              font.pixelSize: 10
              anchors.verticalCenter: parent.verticalCenter
            }
            // Un click por proyecto: levanta el que está abajo, baja el que está
            // arriba (el icono dice cuál va a hacer).
            ActionButton {
              compact: true
              icon: modelData.up > 0 ? "󰍃" : "󰐊"
              enabled: !root.isStarting(modelData.project)
              onTriggered: {
                if (modelData.up === 0) root.markStarting(modelData.project)
                root.runCommand(cli + " " + shq(modelData.project) + " " + (modelData.up > 0 ? "down" : "up"))
              }
            }
            }
          }
        }
      }

      // Quitar el fijado (el widget vuelve a seguir la terminal / tu default) y
      // buscar en tus carpetas: los dos en la misma fila.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: !root.searching
        spacing: 8
        ActionButton {
          label: root.t("unpin")
          icon: "󰁔"
          visible: !root.allMode && root.pinned !== ""
          onTriggered: root.unpinProject()
        }
        // En modo all el popup ya lista todos los proyectos; buscar sigue teniendo
        // sentido para los repos que todavía no declaraste.
        ActionButton { label: root.t("find"); icon: "󰍉"; visible: true; onTriggered: root.findProjects() }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.searching
        spacing: 8
        ActionButton { wide: true; label: root.t(root.findRunning ? "searching" : "findAgain"); icon: "󰍉"; enabled: !root.findRunning; onTriggered: root.findProjects() }
      }

      Column {
        visible: root.searching
        width: contentColumn.width
        spacing: 4

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.found.length > 0 ? root.found.length + root.t("projectsWithStack") : (root.findRunning ? "" : root.t("nothingFound"))
          color: bar ? bar.foreground : "white"
          font.family: bar ? bar.fontFamily : "monospace"
          font.pixelSize: 10
        }

        ListView {
          width: parent.width
          height: Math.min(contentHeight, 156)
          spacing: 4
          clip: true
          model: root.found
          boundsBehavior: Flickable.StopAtBounds

          delegate: Item {
            width: contentColumn.width
            height: 22

            required property var modelData

            Rectangle {
              anchors.fill: parent
              radius: 4
              color: foundHover.containsMouse ? Qt.rgba(1, 1, 1, 0.07) : "transparent"
            }

            MouseArea {
              id: foundHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.pickFound(modelData)
            }

            Row {
              anchors.fill: parent
              spacing: 6

              Rectangle {
                width: 7
                height: 7
                radius: 3.5
                anchors.verticalCenter: parent.verticalCenter
                color: modelData.declared ? (modelData.allUp ? root.colorOk : (modelData.up > 0 ? root.colorWorking : root.colorOff)) : root.colorWorking
              }

              Text {
                text: modelData.label !== undefined ? modelData.label : modelData.suggested
                width: parent.width - 92
                // Los nombres ya vienen cortos (la carpeta) y la ruta sólo
                // cuando hay dos iguales: un corte al final no rompe palabras.
                elide: Text.ElideRight
                color: bar ? bar.foreground : "white"
                font.family: bar ? bar.fontFamily : "monospace"
                font.pixelSize: 11
                font.bold: modelData.declared
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: modelData.declared ? modelData.up + "/" + modelData.total : modelData.services.length + " " + root.t("services")
                color: root.colorOff
                font.family: bar ? bar.fontFamily : "monospace"
                font.pixelSize: 10
                anchors.verticalCenter: parent.verticalCenter
              }

              ActionButton {
                compact: true
                icon: modelData.declared && modelData.up > 0 ? "󰍃" : "󰐊"
                onTriggered: root.pickFound(modelData)
              }
            }
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.searching
        spacing: 8
        ActionButton { wide: true; label: root.t("back"); icon: "󰁍"; onTriggered: root.searching = false }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.allMode
        spacing: 8
        ActionButton { wide: true; label: root.t("liftMissing"); icon: "󰐊"; enabled: !root.starting && !root.everythingUp; onTriggered: root.runInTerminal(cli + " all up") }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.allMode
        spacing: 8
        ActionButton { wide: true; label: root.t("dropAll"); icon: "󰍃"; enabled: !root.starting && root.projectsUp > 0; onTriggered: root.runInTerminal(cli + " all down") }
      }

      // Un chip por servicio declarado en el JSON del proyecto.
      Flow {
        anchors.horizontalCenter: parent.horizontalCenter
        width: contentColumn.width
        spacing: 6
        // Mientras buscás, el popup es la búsqueda: sin chips ni botones del
        // proyecto ocupando media pantalla.
        visible: !root.allMode && !root.searching

        Repeater {
          model: root.services

          Chip {
            label: modelData.label + (modelData.port > 0 ? " :" + modelData.port : "")
              + ((modelData.type !== "docker" && modelData.up && !modelData.managed) ? root.t("foreign") : "")
            lit: modelData.health !== "" ? modelData.healthy : modelData.up
            accent: root.svcColor(modelData)
          }
        }
      }

      Text {
        visible: root.hasClash
        width: contentColumn.width
        horizontalAlignment: Text.AlignHCenter
        text: "󰀦 :" + root.clashPorts.join(" · :") + root.t("clashWarning")
        color: root.colorWorking
        wrapMode: Text.WordWrap
        font.family: bar ? bar.fontFamily : "monospace"
        font.pixelSize: 10
      }

      // La salida: le mueve el puerto a este proyecto (elige uno libre, lo
      // escribe en url/health/cmd y reinicia). En un terminal para que veas qué
      // puerto eligió y qué reescribió.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.hasClash
        spacing: 8
        ActionButton {
          wide: true
          label: root.t("movePort") + (root.clashPorts[0] || "")
          icon: "󰒓"
          enabled: !root.starting
          onTriggered: root.runInTerminal(cli + projectArg + " port --auto && " + cli + projectArg + " restart")
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 8
        visible: root.declared && !root.allMode && !root.searching
        ActionButton { label: root.t("lift"); icon: "󰐊"; enabled: !root.allUp && !root.starting; onTriggered: root.run("up") }
        // Bajar queda habilitado incluso mientras levanta: es la salida cuando
        // una acción se cuelga (y "Cancelar" no existe en el CLI).
        ActionButton { label: root.t("drop"); icon: "󰍃"; enabled: root.anyUp; onTriggered: root.run("down") }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.declared && !root.allMode && !root.searching
        spacing: 8
        ActionButton { label: root.t("open"); icon: "󰖟"; enabled: root.openSvc !== undefined && root.openSvc.up; onTriggered: root.run("open") }
        ActionButton { label: root.t("logs"); icon: "󱆃"; enabled: root.openService !== ""; onTriggered: root.runInTerminal(cli + projectArg + " logs " + shq(root.openService)) }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.declared && !root.allMode && !root.searching
        spacing: 8
        ActionButton { label: root.t("restart"); icon: "󰜉"; enabled: root.anyUp && !root.starting; onTriggered: root.run("restart") }
        ActionButton { label: root.t("menu"); icon: "󰒓"; enabled: true; onTriggered: root.runCommand("omarchy menu summon " + shq(root.effectiveProject !== "" ? "dev." + root.effectiveProject : "dev")) }
      }

      // Repo reconocido pero sin declarar: se declara con el detector, en una
      // terminal, para ver qué infirió antes de que escriba nada.
      ActionButton {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.undeclared && !root.allMode
        wide: true
        label: root.t("declareThis")
        icon: "󰐊"
        enabled: !root.starting
        onTriggered: root.runInTerminal(cli + " add " + shq(root.repo) + (root.suggested !== "" ? " --name " + shq(root.suggested) : ""))
      }

      ActionButton {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.declared && !root.allMode && root.needsTakeover
        wide: true
        label: root.starting ? root.t("tookOver") : root.takeoverLabel
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
    width: compact ? 26 : (wide ? root.contentWidth : Math.floor((root.contentWidth - 8) / 2))
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
