import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Commands panel: a list of saved long-running commands with an on/off switch
// each, plus a field to run a one-off command. Every command runs as a
// transient systemd user unit, so it survives shell restarts, has its own
// journal, and saved commands can auto-restart when they die.
//
//   saved:    omarchy-toggle-<slug>.service   (description "omarchy toggle: <name>")
//   one-shot: omarchy-once-<timestamp>.service (description = the command)
Panel {
  id: root
  moduleName: "command-toggle"
  ipcTarget: "command-toggle"
  manageIpc: false   // this panel owns the IPC target so it can expose the saved commands

  readonly property string pluginId: "command-toggle"
  readonly property string icon: String(setting("icon", "󰆍"))
  readonly property int pollInterval: Math.max(1, Number(setting("interval", 3)))

  readonly property string helper: {
    var path = String(Qt.resolvedUrl("toggle-run")).replace(/^file:\/\//, "")
    try { return decodeURIComponent(path) } catch (e) { return path }
  }

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- saved commands (persisted on the shell.json entry as `commands`) ----
  readonly property var saved: {
    var list = setting("commands", [])
    var out = []
    // Settings cross the host boundary as QVariant sequences, which are not
    // JS arrays (Array.isArray is false), so go by length instead.
    if (typeof list === "string") { try { list = JSON.parse(list) } catch (e) { list = [] } }
    if (list && typeof list.length === "number") {
      for (var i = 0; i < list.length; i++) {
        var e = list[i]
        if (!e || typeof e !== "object") continue
        var cmd = String(e.command || "").trim()
        if (!cmd) continue
        out.push({
          name: String(e.name || "").trim() || cmd.split(/\s+/)[0],
          command: cmd,
          restart: e.restart !== false
        })
      }
    }
    // Legacy single-command entry from v1 of this plugin.
    if (out.length === 0 && String(setting("command", "")).trim() !== "") {
      out.push({
        name: String(setting("name", "toggle")),
        command: String(setting("command", "")).trim(),
        restart: setting("restartOnFailure", true) !== false
      })
    }
    return out
  }

  // ---- live unit state, from systemctl ----
  // unit name -> { active, sub, description }
  property var units: ({})
  // unit -> true while a start/stop is in flight
  property var busyUnits: ({})
  // unit -> true when we saw it running and it went away without us stopping it
  property var finishedUnits: ({})
  // unit -> true when we asked systemd to stop it (suppresses "finished")
  property var stoppingUnits: ({})
  // one-shots we started or discovered, newest first: { unit, command }
  property var onceHistory: []
  property bool pollReady: false

  readonly property var onceRows: {
    var rows = []
    var history = onceHistory || []
    for (var i = 0; i < history.length; i++) {
      var h = history[i]
      rows.push({ unit: h.unit, command: h.command, state: stateFor(h.unit) })
    }
    return rows
  }

  readonly property int runningCount: {
    var n = 0
    for (var i = 0; i < saved.length; i++) if (isOn(stateFor(unitFor(saved[i])))) n++
    for (var j = 0; j < onceRows.length; j++) if (isOn(onceRows[j].state)) n++
    return n
  }

  function slugFor(name) {
    var s = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
    return s || "toggle"
  }
  function unitFor(entry) { return "omarchy-toggle-" + slugFor(entry.name) }

  function stateFor(unit) {
    var u = units ? units[unit] : undefined
    if (u) return u.active
    if (finishedUnits && finishedUnits[unit]) return "finished"
    return "inactive"
  }
  function isOn(state) { return state === "active" || state === "activating" || state === "reloading" }
  function isBusy(unit) { return !!busyUnits && busyUnits[unit] === true }

  function stateLabel(state) {
    switch (state) {
      case "active": return "running"
      case "activating": return "restarting"
      case "deactivating": return "stopping"
      case "failed": return "failed"
      case "finished": return "finished"
      default: return "stopped"
    }
  }
  function stateColor(state) {
    if (state === "failed") return urgent
    if (isOn(state)) return fg
    return dim
  }

  // ---- polling ----
  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyUnits(list) {
    var next = ({})
    for (var i = 0; i < list.length; i++) {
      var u = list[i]
      if (!u || !u.unit) continue
      var name = String(u.unit).replace(/\.service$/, "")
      next[name] = { active: String(u.active || ""), sub: String(u.sub || ""), description: String(u.description || "") }
    }

    // Units that were on and vanished on their own -> finished.
    var fin = Object.assign({}, finishedUnits)
    var stopping = Object.assign({}, stoppingUnits)
    for (var prev in units) {
      if (next[prev]) continue
      if (isOn(units[prev].active)) {
        if (stopping[prev]) delete stopping[prev]
        else fin[prev] = true
      }
    }
    for (var live in next) {
      if (fin[live]) delete fin[live]
      if (stopping[live] && !isOn(next[live].active)) delete stopping[live]
    }

    // Discover one-shots we do not know about (e.g. started before a shell restart).
    var history = onceHistory.slice()
    for (var unit in next) {
      if (unit.indexOf("omarchy-once-") !== 0) continue
      var known = false
      for (var k = 0; k < history.length; k++) if (history[k].unit === unit) { known = true; break }
      if (!known) history.unshift({ unit: unit, command: next[unit].description || unit })
    }
    // Keep one-shots that are still loaded or that ran to completion on their
    // own; anything else that is gone (stopped, reset, dismissed) drops off.
    history = history.filter(function(h) { return next[h.unit] || fin[h.unit] })

    units = next
    finishedUnits = fin
    stoppingUnits = stopping
    onceHistory = history
    pollReady = true
  }


  // ---- control ----
  function markBusy(unit, value) {
    var b = Object.assign({}, busyUnits)
    if (value) b[unit] = true
    else delete b[unit]
    busyUnits = b
  }

  function startUnit(unit, description, restart, command) {
    if (isBusy(unit) || !command) return
    markBusy(unit, true)
    var fin = Object.assign({}, finishedUnits); delete fin[unit]; finishedUnits = fin
    var proc = controlComponent.createObject(root, {
      command: [helper, unit, description, restart ? "yes" : "no", command],
      unit: unit
    })
    proc.running = true
  }

  function stopUnit(unit) {
    if (isBusy(unit)) return
    markBusy(unit, true)
    var s = Object.assign({}, stoppingUnits); s[unit] = true; stoppingUnits = s
    var proc = controlComponent.createObject(root, {
      command: ["systemctl", "--user", "stop", unit],
      unit: unit
    })
    proc.running = true
  }

  // Clear a failed unit from systemd and forget about it.
  function dismissUnit(unit) {
    var fin = Object.assign({}, finishedUnits); delete fin[unit]; finishedUnits = fin
    onceHistory = onceHistory.filter(function(h) { return h.unit !== unit })
    var proc = controlComponent.createObject(root, {
      command: ["systemctl", "--user", "reset-failed", unit],
      unit: unit
    })
    proc.running = true
  }

  function toggleSaved(entry) {
    var unit = unitFor(entry)
    if (isOn(stateFor(unit))) stopUnit(unit)
    else startUnit(unit, "omarchy toggle: " + entry.name, entry.restart, entry.command)
  }

  function runOnce(command) {
    var cmd = String(command || "").trim()
    if (!cmd) return
    var unit = "omarchy-once-" + Date.now()
    onceHistory = [{ unit: unit, command: cmd }].concat(onceHistory)
    startUnit(unit, cmd, false, cmd)
  }

  function showLog(unit) {
    if (!bar) return
    bar.run("omarchy-launch-floating-terminal-with-presentation journalctl --user -u "
            + bar.shellQuote(unit) + " -n 100 -f")
  }

  // ---- persistence ----
  function persistSaved(list) {
    var clean = []
    for (var i = 0; i < list.length; i++) {
      clean.push({ name: list[i].name, command: list[i].command, restart: list[i].restart !== false })
    }
    // The omarchy-shell CLI splits a JSON array argument into separate
    // arguments; a leading space stops that and JSON.parse ignores it.
    persistProc.command = ["omarchy-shell", "shell", "setBarWidget", pluginId, "commands", " " + JSON.stringify(clean), "{}"]
    persistProc.running = true
  }

  function removeSaved(index) {
    if (index < 0 || index >= saved.length) return
    var entry = saved[index]
    var unit = unitFor(entry)
    if (isOn(stateFor(unit))) stopUnit(unit)
    var list = saved.slice()
    list.splice(index, 1)
    persistSaved(list)
  }

  function saveOnce(row) {
    var name = row.command.split(/\s+/)[0].replace(/^.*\//, "")
    var base = name, n = 2
    var taken = function(candidate) {
      for (var i = 0; i < saved.length; i++) if (slugFor(saved[i].name) === slugFor(candidate)) return true
      return false
    }
    while (taken(name)) name = base + "-" + (n++)
    persistSaved(saved.concat([{ name: name, command: row.command, restart: true }]))
  }

  // ---- keyboard cursor ----
  // sections: "saved" (rows), "input" (the field, index -1), "once" (rows)
  property string focusSection: "input"
  property int selectedIndex: -1
  property bool cursorActive: false

  readonly property var sections: {
    var list = []
    if (saved.length > 0) list.push("saved")
    list.push("input")
    if (onceRows.length > 0) list.push("once")
    return list
  }
  function sectionCount(s) {
    if (s === "saved") return saved.length
    if (s === "once") return onceRows.length
    return 0
  }
  function sectionFirst(s) { return s === "input" ? -1 : 0 }

  function moveCursor(delta) {
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = sectionFirst(focusSection); return }
    var max = sectionCount(focusSection) - 1
    if (delta > 0) {
      if (focusSection !== "input" && selectedIndex < max) { selectedIndex++; return }
      if (sIdx < sections.length - 1) { focusSection = sections[sIdx + 1]; selectedIndex = sectionFirst(focusSection) }
    } else {
      if (focusSection !== "input" && selectedIndex > 0) { selectedIndex--; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        selectedIndex = prev === "input" ? -1 : sectionCount(prev) - 1
      }
    }
  }

  // Change handlers can fire while the object is still being constructed;
  // skip cursor bookkeeping until Component.onCompleted.
  property bool ready: false

  function clampCursor() {
    if (!ready || !sections) return
    if (sections.indexOf(focusSection) < 0) { focusSection = "input"; selectedIndex = -1; return }
    var count = sectionCount(focusSection)
    if (focusSection === "input") { selectedIndex = -1; return }
    if (count === 0) { focusSection = "input"; selectedIndex = -1; return }
    if (selectedIndex >= count) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  function activateCursor() {
    if (focusSection === "saved" && saved[selectedIndex]) toggleSaved(saved[selectedIndex])
    else if (focusSection === "input") input.forceActiveFocus()
    else if (focusSection === "once" && onceRows[selectedIndex]) {
      var row = onceRows[selectedIndex]
      if (isOn(row.state)) stopUnit(row.unit)
      else dismissUnit(row.unit)
    }
  }

  function deleteCursor() {
    if (focusSection === "saved") removeSaved(selectedIndex)
    else if (focusSection === "once" && onceRows[selectedIndex]) {
      var row = onceRows[selectedIndex]
      if (isOn(row.state)) stopUnit(row.unit)
      else dismissUnit(row.unit)
    }
  }

  function logCursor() {
    if (focusSection === "saved" && saved[selectedIndex]) showLog(unitFor(saved[selectedIndex]))
    else if (focusSection === "once" && onceRows[selectedIndex]) showLog(onceRows[selectedIndex].unit)
  }

  function ensureCursorVisible(item) {
    if (!item || !panelFlick) return
    var pt = item.mapToItem(panelFlick.contentItem, 0, 0)
    var top = pt.y, bottom = top + item.height
    var viewTop = panelFlick.contentY, viewBottom = viewTop + panelFlick.height
    var margin = 6
    if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin) panelFlick.contentY = bottom + margin - panelFlick.height
  }

  Component.onCompleted: { ready = true; clampCursor() }
  onSavedChanged: clampCursor()
  onOnceRowsChanged: clampCursor()
  onOpenedChanged: {
    if (opened) {
      refresh()
      focusSection = saved.length > 0 ? "saved" : "input"
      selectedIndex = saved.length > 0 ? 0 : -1
      cursorActive = false
    } else {
      keyCatcher.forceActiveFocus()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function findSaved(name) {
    for (var i = 0; i < saved.length; i++) if (saved[i].name === name || slugFor(saved[i].name) === slugFor(name)) return saved[i]
    return null
  }

  // omarchy-shell command-toggle <method> [args]
  //
  // No method here takes a command. IPC arguments only ever name a command
  // that already exists in the saved list, and the name is resolved against
  // that list before anything runs; an unknown name is an error, never a new
  // command. Commands themselves are only ever created in the popup or by
  // editing shell.json by hand, so nothing that arrives over IPC can become
  // a shell program. Keep it that way: never add a method that accepts a
  // command string, and never pass an IPC argument to startUnit() or
  // persistSaved().
  IpcHandler {
    target: "command-toggle"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function state(): string {
      var out = { running: root.runningCount, saved: [], once: root.onceRows }
      for (var i = 0; i < root.saved.length; i++) {
        var e = root.saved[i]
        out.saved.push({ name: e.name, unit: root.unitFor(e), state: root.stateFor(root.unitFor(e)), command: e.command })
      }
      return JSON.stringify(out)
    }
    function start(name: string): string {
      var e = root.findSaved(name)
      if (!e) return "unknown command: " + name
      if (!root.isOn(root.stateFor(root.unitFor(e)))) root.toggleSaved(e)
      return "ok"
    }
    function stop(name: string): string {
      var e = root.findSaved(name)
      if (!e) return "unknown command: " + name
      if (root.isOn(root.stateFor(root.unitFor(e)))) root.toggleSaved(e)
      return "ok"
    }
    function flip(name: string): string {
      var e = root.findSaved(name)
      if (!e) return "unknown command: " + name
      root.toggleSaved(e)
      return "ok"
    }
    function remove(name: string): string {
      for (var i = 0; i < root.saved.length; i++) {
        if (root.saved[i].name === name || root.slugFor(root.saved[i].name) === root.slugFor(name)) {
          root.removeSaved(i)
          return "ok"
        }
      }
      return "unknown command: " + name
    }
    function refresh(): void { root.refresh() }
  }

  // ---- processes ----
  Process {
    id: statusProc
    command: ["systemctl", "--user", "list-units", "omarchy-toggle-*", "omarchy-once-*",
              "--all", "--plain", "--no-legend", "--output=json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var list = []
        try { list = JSON.parse(String(text || "").trim() || "[]") } catch (e) { list = [] }
        root.applyUnits(Array.isArray(list) ? list : [])
      }
    }
  }

  Component {
    id: controlComponent
    Process {
      property string unit: ""
      stdout: StdioCollector { waitForEnd: true }
      onExited: function(exitCode) {
        root.markBusy(unit, false)
        root.refresh()
        settleTimer.restart()
        destroy()
      }
    }
  }

  Process {
    id: persistProc
    stdout: StdioCollector { waitForEnd: true }
  }

  Timer {
    id: settleTimer
    interval: 800
    onTriggered: root.refresh()
  }

  Timer {
    interval: (root.opened ? 1 : root.pollInterval) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- bar button ----
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon + (root.runningCount > 0 ? " " + root.runningCount : "")
    active: root.runningCount > 0
    tooltipText: root.runningCount > 0
      ? root.runningCount + " command" + (root.runningCount === 1 ? "" : "s") + " running"
      : "Commands"
    onPressed: function(b) { root.toggle() }
  }

  // ---- popup ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: input.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onDeleteRequested: if (root.cursorActive) root.deleteCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/" || t === "i") { input.forceActiveFocus(); return }
        if (t === "r") { root.refresh(); return }
        if (t === "o" && root.cursorActive) root.logCursor()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Commands"
            meta: root.runningCount > 0
              ? (root.runningCount + " RUNNING")
              : (root.pollReady ? "ALL STOPPED" : "CHECKING")
            foreground: root.fg
            fontFamily: root.fontFamily
            iconOpacity: root.runningCount > 0 ? 1.0 : 0.7
            iconComponent: Component {
              Text {
                text: root.icon
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ---- saved ----
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.saved.length > 0

            PanelSectionHeader {
              text: "SAVED"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.saved
              SavedRow {
                required property var modelData
                required property int index
                width: column.width
                entry: modelData
                rowIndex: index
              }
            }
          }

          PanelSeparator { foreground: root.fg; visible: root.saved.length > 0 }

          // ---- one-shot ----
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "RUN ONCE"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            TextField {
              id: input
              width: parent.width
              placeholderText: "command, Enter to run"
              foreground: root.fg
              font.family: root.fontFamily
              hasCursor: root.cursorActive && root.focusSection === "input"
              onAccepted: {
                root.runOnce(text)
                text = ""
                keyCatcher.forceActiveFocus()
              }
              Keys.onEscapePressed: function(event) {
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
              onHoveredChanged: if (hovered) {
                root.cursorActive = true
                root.focusSection = "input"
                root.selectedIndex = -1
              }
            }

            Repeater {
              model: root.onceRows
              OnceRow {
                required property var modelData
                required property int index
                width: column.width
                row: modelData
                rowIndex: index
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "j/k move   enter toggle   x remove or stop   o log   / type   right-click log"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // ---- row components ----
  component SavedRow: CursorSurface {
    id: savedRow
    required property var entry
    required property int rowIndex
    readonly property string unit: root.unitFor(entry)
    readonly property string state: root.stateFor(unit)
    readonly property bool on: root.isOn(state)

    hasCursor: root.cursorActive && root.focusSection === "saved" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(savedRow)
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Color.accent)
    implicitHeight: savedInner.implicitHeight + Style.spacing.xl

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "saved"
        root.selectedIndex = savedRow.rowIndex
      }
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.showLog(savedRow.unit)
        else root.toggleSaved(savedRow.entry)
      }
    }

    Item {
      id: savedInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(savedText.implicitHeight, savedControls.implicitHeight)

      Column {
        id: savedText
        anchors.left: parent.left
        anchors.right: savedControls.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Row {
          spacing: Style.space(8)
          Text {
            id: savedName
            textFormat: Text.PlainText
            text: savedRow.entry.name
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            text: root.stateLabel(savedRow.state)
            color: root.stateColor(savedRow.state)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.baseline: savedName.baseline
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: savedRow.entry.command
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: savedControls
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        PanelActionButton {
          iconText: "󰆴"
          tooltipText: "Remove"
          foreground: root.dim
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.removeSaved(savedRow.rowIndex)
        }

        ToggleSwitch {
          interactive: false
          checked: savedRow.on
          busy: root.isBusy(savedRow.unit)
          foreground: root.fg
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }

  component OnceRow: CursorSurface {
    id: onceRow
    required property var row
    required property int rowIndex
    readonly property bool on: root.isOn(row.state)

    hasCursor: root.cursorActive && root.focusSection === "once" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(onceRow)
    foreground: root.fg
    fill: Style.hoverFillFor(root.fg, Color.accent)
    implicitHeight: onceInner.implicitHeight + Style.spacing.xl

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.RightButton
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "once"
        root.selectedIndex = onceRow.rowIndex
      }
      onClicked: root.showLog(onceRow.row.unit)
    }

    Item {
      id: onceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(onceText.implicitHeight, onceControls.implicitHeight)

      Column {
        id: onceText
        anchors.left: parent.left
        anchors.right: onceControls.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: onceRow.row.command
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
        Text {
          textFormat: Text.PlainText
          text: root.stateLabel(onceRow.row.state)
          color: root.stateColor(onceRow.row.state)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: onceControls
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        PanelActionButton {
          iconText: "󰐃"
          tooltipText: "Save to list"
          foreground: root.dim
          hoverColor: root.fg
          fontFamily: root.fontFamily
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.saveOnce(onceRow.row)
        }

        PanelActionButton {
          iconText: "󰈙"
          tooltipText: "Log"
          foreground: root.dim
          hoverColor: root.fg
          fontFamily: root.fontFamily
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.showLog(onceRow.row.unit)
        }

        PanelActionButton {
          iconText: onceRow.on ? "󰓛" : "󰅖"
          tooltipText: onceRow.on ? "Stop" : "Dismiss"
          foreground: root.dim
          hoverColor: onceRow.on ? root.urgent : root.fg
          fontFamily: root.fontFamily
          anchors.verticalCenter: parent.verticalCenter
          onClicked: onceRow.on ? root.stopUnit(onceRow.row.unit) : root.dismissUnit(onceRow.row.unit)
        }
      }
    }
  }
}
