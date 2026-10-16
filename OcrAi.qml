import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

import qs.Commons
import qs.Ui

// Screenshot -> OCR -> AI.
//
// One interaction is three steps: press the shortcut, drag a region, read the
// answer. Nothing is shown while you drag (it would end up in the capture); the
// card rises once text is recognized. A cancelled selection slips away in
// silence, and a region with no text says so in one muted line.
//
// The contract with the host (omarchy-shell) is documented here: open(payloadJson) / close() / opened.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool minimized: false

  // -- Runtime state ------------------------------------------
  // idle -> capturing (drag and OCR) -> thinking (AI stream) -> done / error
  property string stage: "idle"
  property string sourceText: ""     // OCR result, also the AI input
  property string actionId: ""       // current action id; empty means the default one
  property string errorMessage: ""

  // Two guards around a single AI call. The host gives us one Process, so
  // switching actions has to interrupt the previous run first, and SIGTERM is
  // asynchronous: the old process's exited can arrive after the new one began.
  //
  //   aiLaunched          this run really started (set in onStarted). A killed
  //                       process never set it, so its leftover events can be
  //                       told apart from the new run's.
  //   awaitingFirstChunk  the collector still holds the previous run's text;
  //                       nothing is shown until the first new chunk lands.
  property bool aiLaunched: false
  property bool awaitingFirstChunk: false

  // -- Config: ~/.config/omarchy/ocr-ai.json overrides the bundled config.json --
  property string position: "top-right"
  property string ocrLangs: "eng"
  property bool copyOcrToClipboard: true
  property var aiCommand: ["~/tools/bai", "-P", "river", "-p", "{pattern}"]
  property var actions: [{ "id": "raw", "label": "Original", "hotkey": "1", "pattern": "" }]

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string captureScript: Qt.resolvedUrl("scripts/capture-ocr.sh").toString().replace(/^file:\/\//, "")

  readonly property var defaultAction: {
    for (var i = 0; i < root.actions.length; i++)
      if (root.actions[i].default === true) return root.actions[i]
    return root.actions.length > 0 ? root.actions[0] : null
  }

  readonly property var currentAction: {
    for (var i = 0; i < root.actions.length; i++)
      if (root.actions[i].id === root.actionId) return root.actions[i]
    return root.defaultAction
  }

  readonly property bool currentActionUsesAi: {
    var a = root.currentAction
    return !!a && String(a.pattern || "") !== ""
  }

  // Card body: the raw action echoes the OCR text, everything else reads the AI stream
  readonly property string answer: root.currentActionUsesAi
    ? (root.awaitingFirstChunk ? "" : aiOut.text)
    : root.sourceText

  readonly property bool waitingForFirstChunk: root.stage === "thinking" && root.awaitingFirstChunk

  readonly property string modelName: {
    // Pick a name for this answer out of ai_command, purely for the card's watermark
    var argv = root.aiCommand || []
    for (var i = 0; i < argv.length - 1; i++)
      if (String(argv[i]) === "-P" || String(argv[i]) === "--profile") return String(argv[i + 1])
    return argv.length > 0 ? String(argv[0]).replace(/^.*\//, "") : "AI"
  }

  // -- Style --------------------------------------------------
  readonly property int cardWidth: 420
  readonly property int cardRadius: 8
  readonly property int pillHeight: 30
  readonly property int footerHeight: 44
  readonly property int bodyPadTop: 14
  readonly property int bodyPadBottom: 14
  readonly property int bodyPadX: 18

  // Breathing room between the card and the screen edge. The edge that meets
  // the bar clears the bar itself and then adds a thin gap.
  readonly property int screenMargin: 16
  readonly property int barGap: 8

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.6)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.34)
  readonly property color urgent: Color.urgent
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, 1)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.1)

  readonly property bool anchorTop: root.position.indexOf("top") === 0
  readonly property bool anchorLeft: root.position.indexOf("left") >= 0

  // A card sitting on the bar would cover its status icons, so the edge that
  // meets the bar clears it entirely and then leaves a thin gap: the card reads
  // as hung under the bar rather than floating. Thickness follows the bar's
  // orientation, and position comes from the barConfig snapshot the host hands
  // us; with no snapshot we assume Omarchy's default top bar.
  readonly property string barPosition: root.shell && root.shell.barConfig
    ? String(root.shell.barConfig.position || "top") : "top"
  readonly property bool barIsHorizontal: root.barPosition === "top" || root.barPosition === "bottom"
  readonly property bool cardSharesBarEdge: root.barIsHorizontal
    ? root.barPosition === (root.anchorTop ? "top" : "bottom")
    : root.barPosition === (root.anchorLeft ? "left" : "right")
  readonly property int barClearance: (root.barIsHorizontal ? Style.bar.sizeHorizontal
                                                            : Style.bar.sizeVertical)
    + root.barGap

  // Distance from the edge the card is anchored to: the bar's thickness plus a
  // gap when it shares that edge, otherwise just the ordinary margin. The
  // opposite side always gets the plain margin.
  readonly property int verticalMargin: root.barIsHorizontal && root.cardSharesBarEdge
    ? root.barClearance : root.screenMargin
  readonly property int horizontalMargin: !root.barIsHorizontal && root.cardSharesBarEdge
    ? root.barClearance : root.screenMargin

  // Height is measured on the screen the card actually lives on (on a
  // multi-monitor setup Qt.application.screens[0] is not necessarily it).
  readonly property int screenHeight: {
    var scr = panel.screen ? panel.screen
      : (Qt.application.screens.length > 0 ? Qt.application.screens[0] : null)
    return scr ? scr.height : 1080
  }

  // -- Card height: hug the content without leaving the screen --------
  // paintedHeight rather than implicitHeight: under maximumLineCount + elide
  // + lineHeight, implicitHeight does not have to match what is actually
  // painted, which clipped the OCR strip's second line in half. paintedHeight
  // is the real painted height, so following it cannot be wrong.
  readonly property int stripHeight: root.sourceText === "" ? 0
    : Math.ceil(stripLabel.paintedHeight) + 20
  // Available height is the screen minus the room taken on both sides: the
  // card's own position costs verticalMargin and the opposite side keeps a
  // screenMargin. Subtracting screenMargin*2 only let a long answer push the
  // footer (copy / collapse / close) off the bottom edge.
  readonly property int maxCardHeight:
    Math.max(root.screenHeight - root.verticalMargin - root.screenMargin, 160)
  readonly property int idealCardHeight:
    root.stripHeight + bodyLabel.implicitHeight + root.bodyPadTop + root.bodyPadBottom + root.footerHeight
  readonly property int cardHeight: Math.max(Math.min(root.idealCardHeight, root.maxCardHeight), 150)
  readonly property int panelHeight: (root.minimized ? root.pillHeight : root.cardHeight)
    + root.verticalMargin + root.screenMargin

  // -- Config loading -----------------------------------------
  // Either file may load first, so each one is parked until it arrives and the
  // two are merged then; the user's config always sits on top.
  //
  // The manifest deliberately omits keepLoaded: the instance is rebuilt on
  // every summon, so the config is re-read too and an edit applies to the next
  // summon without a shell restart. With keepLoaded: true the instance is
  // created once at shell start, freezing the config until the next restart.
  property var bundledConfig: null
  property var userConfig: null

  function loadConfig(jsonText, fromUser) {
    var cfg = null
    try {
      cfg = JSON.parse(jsonText)
    } catch (e) {
      console.warn("claw.ocr-ai: config parse failed:", e)
      return
    }
    if (!cfg || typeof cfg !== "object") return
    if (fromUser) root.userConfig = cfg
    else root.bundledConfig = cfg
    root.applyConfig()
  }

  function applyConfig() {
    var merged = {}
    var base = root.bundledConfig || {}
    for (var k in base) merged[k] = base[k]
    var over = root.userConfig
    if (over) for (var j in over) merged[j] = over[j]

    if (typeof merged.position === "string") {
      var p = merged.position
      if (p === "top-left" || p === "top-right" || p === "bottom-left" || p === "bottom-right")
        root.position = p
    }
    if (typeof merged.ocr_langs === "string" && merged.ocr_langs !== "")
      root.ocrLangs = merged.ocr_langs
    if (typeof merged.copy_ocr_to_clipboard === "boolean")
      root.copyOcrToClipboard = merged.copy_ocr_to_clipboard
    if (Array.isArray(merged.ai_command) && merged.ai_command.length > 0)
      root.aiCommand = merged.ai_command
    if (Array.isArray(merged.actions) && merged.actions.length > 0)
      root.actions = merged.actions
  }

  FileView {
    id: bundledConfigFile
    path: root.pluginDir + "config.json"
    printErrors: false
    onLoaded: root.loadConfig(text(), false)
  }

  FileView {
    id: userConfigFile
    path: Quickshell.env("HOME") + "/.config/omarchy/ocr-ai.json"
    printErrors: false
    onLoaded: root.loadConfig(text(), true)
  }

  // -- Host contract ------------------------------------------
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}

    // Callers may hand us a piece of text directly (skipping the screenshot), so
    // other sources can reuse the same card.
    if (payload.text) {
      root.adoptText(String(payload.text), root.actionById(payload.action))
      return
    }
    root.beginCapture()
  }

  function close() {
    if (captureProc.running) captureProc.running = false
    if (aiProc.running) aiProc.running = false
    aiIdleTimer.stop()
    root.stage = "idle"
    root.opened = false
    root.minimized = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide("claw.ocr-ai")
  }

  // When the instance goes away (panel hidden, plugin reloaded, shell exiting)
  // its child processes have to go with it. A slurp still waiting for a drag is
  // the worst leftover: it holds the input while showing nothing, so no later
  // summon can bring up a selection, and nothing points back to the cause.
  Component.onDestruction: {
    if (captureProc.running) captureProc.running = false
    if (aiProc.running) aiProc.running = false
  }

  // -- Capture -> OCR -----------------------------------------
  function beginCapture() {
    // A previous selection is still alive: throw it away and start over.
    //
    // Usually that is a double tap on the shortcut and only costs one more drag.
    // Otherwise the previous slurp is stuck (process alive, nothing on screen,
    // input held), and ignoring the press would mean every later press does
    // nothing. Restarting beats a keypress swallowed in silence.
    if (captureProc.running) captureProc.running = false

    if (aiProc.running) aiProc.running = false
    aiIdleTimer.stop()

    root.stage = "capturing"
    root.opened = false        // keep the screen clear while the region is dragged
    root.minimized = false
    root.sourceText = ""
    root.actionId = ""
    root.errorMessage = ""
    root.awaitingFirstChunk = false

    captureProc.running = true
  }

  // Only act when text really came back. Empty results are judged in onCaptureExited
  // instead: the host calls streamEnded(stdout) before streamEnded(stderr), so
  // reading stderr here would still show the previous run.
  function onCaptured(raw) {
    if (root.stage !== "capturing") return
    var text = String(raw || "").trim()
    if (text !== "") root.adoptText(text, null)
  }

  function onCaptureExited(exitCode) {
    if (root.stage !== "capturing") return   // text arrived, already on the AI path

    // Three ways to end up without text, told apart by the script's exit code
    // (see the contract at the top of scripts/capture-ocr.sh):
    //   0 + no output  the drag was cancelled: leave quietly, no trace
    //   3              a region was selected but holds no text: say so softly
    //   anything else  a real failure; the reason belongs on screen
    var err = String(captureErr.text || "").trim()

    if (exitCode === 0 && err === "") {
      root.dismiss()
      return
    }

    root.opened = true
    root.minimized = false
    if (exitCode === 3) {
      root.stage = "empty"
      root.errorMessage = ""
      return
    }

    root.errorMessage = err !== "" ? err : "OCR failed (exit code " + exitCode + ")"
    root.stage = "error"
  }

  function adoptText(text, action) {
    root.sourceText = text
    if (root.copyOcrToClipboard) Quickshell.execDetached(["wl-copy", text])
    // The capture phase ends here. Leave capturing first, or runAction's guard
    // (which blocks stray presses mid-drag) also blocks this legitimate first
    // run and the card never appears at all.
    root.stage = "idle"
    root.opened = true
    root.minimized = false
    root.runAction(action || root.defaultAction)
  }

  // ── AI ──────────────────────────────────────────────────────
  function expandHome(path) {
    var p = String(path || "")
    if (p === "~") return Quickshell.env("HOME")
    if (p.indexOf("~/") === 0) return Quickshell.env("HOME") + p.slice(1)
    return p
  }

  // Text travels on stdin: no temp file, no possibly huge OCR result inside argv,
  // and it is never parsed by a shell -- it is passed as its own argv slot and
  // handed straight to the pipe. The command is existence-checked first, or the
  // shell would print its own ugly "command not found" line.
  function aiArgv(action) {
    var argv = []
    var tmpl = root.aiCommand || []
    for (var i = 0; i < tmpl.length; i++)
      argv.push(String(tmpl[i]).replace(/\{pattern\}/g, String(action.pattern || "")))
    if (argv.length === 0) return []
    argv[0] = root.expandHome(argv[0])

    return ["sh", "-c",
      'exe=$1; text=$2; shift 2; '
        + 'command -v -- "$exe" >/dev/null 2>&1 '
        + '|| { printf "AI command not found: %s\\n" "$exe" >&2; exit 127; }; '
        + 'printf %s "$text" | "$exe" "$@"',
      "claw.ocr-ai", argv[0], root.sourceText].concat(argv.slice(1))
  }

  function runAction(action) {
    // Action ids are accepted too, so shell IPC can drive this directly:
    //   omarchy-shell shell call claw.ocr-ai runAction summarize
    if (typeof action === "string") action = root.actionById(action)
    if (!action || root.stage === "capturing" || root.sourceText === "") return
    root.actionId = action.id
    root.errorMessage = ""

    if (!action.pattern) {
      // the raw action: leave the AI alone
      if (aiProc.running) aiProc.running = false
      aiIdleTimer.stop()
      root.aiLaunched = false
      root.awaitingFirstChunk = false
      root.stage = "done"
      return
    }

    var argv = root.aiArgv(action)
    if (argv.length === 0) {
      root.errorMessage = "ai_command is not configured"
      root.stage = "error"
      return
    }

    root.stage = "thinking"
    root.aiLaunched = false
    root.awaitingFirstChunk = true

    // Interrupt the previous run first. SIGTERM is asynchronous, so the new
    // command only starts once the old process really exits; aiLaunched covers
    // that gap.
    if (aiProc.running) aiProc.running = false
    aiProc.command = argv
    aiProc.running = true
  }

  function onAiExited(exitCode) {
    if (root.stage !== "thinking" || !root.aiLaunched) return
    aiIdleTimer.stop()
    root.awaitingFirstChunk = false

    var err = String(aiErr.text || "").trim()
    if (err !== "") {
      root.errorMessage = err
      root.stage = "error"
    } else if (exitCode !== 0) {
      root.errorMessage = "AI command exited with code " + exitCode
      root.stage = "error"
    } else {
      root.stage = "done"
    }
  }

  function onAiStalled() {
    if (root.stage !== "thinking") return
    root.errorMessage = root.awaitingFirstChunk
      ? "The AI did not respond - check that ai_command works"
      : "The AI output stopped"
    root.stage = "error"
    if (aiProc.running) aiProc.running = false
  }

  Process {
    id: captureProc
    running: false
    command: ["bash", root.captureScript, root.ocrLangs]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onCaptured(text)
    }

    stderr: StdioCollector {
      id: captureErr
      waitForEnd: true
    }

    onExited: function(exitCode) { root.onCaptureExited(exitCode) }
  }

  Process {
    id: aiProc
    running: false

    stdout: StdioCollector {
      id: aiOut
      waitForEnd: false        // show chunks as they arrive: that is what makes it feel typed
      onDataChanged: {
        if (root.awaitingFirstChunk) {
          root.awaitingFirstChunk = false
          aiIdleTimer.interval = 30000   // words are flowing now, be patient
        }
        aiIdleTimer.restart()
      }
    }

    stderr: StdioCollector {
      id: aiErr
      waitForEnd: true
    }

    onStarted: {
      root.aiLaunched = true
      aiIdleTimer.restart()
    }

    onExited: function(exitCode) { root.onAiExited(exitCode) }
  }

  // A silent watchdog: a missing command, an expired key, a stalled network --
  // failures like these produce no output and no exited signal, and without it
  // the card would spin forever. Two stages: strict while waiting for the first
  // chunk (nearly every failure happens there), patient once words flow.
  Timer {
    id: aiIdleTimer
    interval: 12000
    repeat: false
    onTriggered: root.onAiStalled()
  }

  // -- Presentation -------------------------------------------
  readonly property string bodyText: {
    if (root.stage === "error") return root.errorMessage
    if (root.stage === "empty") return "No text found"
    if (root.stage === "thinking" && root.awaitingFirstChunk) return ""
    if (root.answer === "") return root.stage === "thinking" ? "" : "(no content)"
    return root.answer + (root.stage === "thinking" ? " ▍" : "")
  }

  property bool justCopied: false

  function copyAnswer() {
    var text = String(root.answer || "").trim()
    if (text === "") return
    Quickshell.execDetached(["wl-copy", text])
    root.justCopied = true
    copyResetTimer.restart()
  }

  Timer {
    id: copyResetTimer
    interval: 1200
    onTriggered: root.justCopied = false
  }

  function actionForHotkey(char) {
    for (var i = 0; i < root.actions.length; i++) {
      var hk = String(root.actions[i].hotkey !== undefined ? root.actions[i].hotkey : i + 1)
      if (hk === String(char)) return root.actions[i]
    }
    return null
  }

  function actionById(id) {
    for (var i = 0; i < root.actions.length; i++)
      if (root.actions[i].id === id) return root.actions[i]
    return null
  }

  // -- Layer surface ------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    WlrLayershell.namespace: "claw-ocr-ai"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // Only the visible card or pill takes mouse events. The rest of the panel's
    // rectangle (the margins, the space beside the pill when collapsed) passes
    // clicks straight through to the window behind: an overlay should never be
    // "thicker" than what it actually shows.
    mask: Region { item: root.minimized ? pill : card }

    // It covers only the corner the card lives in instead of the whole screen,
    // so it never blocks clicks meant for other windows.
    anchors {
      top: root.anchorTop
      bottom: !root.anchorTop
      left: root.anchorLeft
      right: !root.anchorLeft
    }
    implicitWidth: root.cardWidth + root.horizontalMargin + root.screenMargin
    implicitHeight: root.panelHeight

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
          root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Space) {
          if (!root.minimized) root.toggleMinimize()
          event.accepted = true
        } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
          var action = root.actionForHotkey(event.key - Qt.Key_0)
          if (action) {
            root.runAction(action)
            event.accepted = true
          }
        }
      }

      // -- Pill (collapsed state): the answer stays visible while you work --
      Rectangle {
        id: pill
        width: pillLabel.implicitWidth + 26 + chevron.implicitWidth + 6
        height: root.pillHeight
        radius: root.pillHeight / 2
        color: root.background
        border.color: root.border
        border.width: 1

        anchors {
          top: root.anchorTop ? parent.top : undefined
          bottom: root.anchorTop ? undefined : parent.bottom
          left: root.anchorLeft ? parent.left : undefined
          right: root.anchorLeft ? undefined : parent.right
          topMargin: root.anchorTop ? root.verticalMargin : 0
          bottomMargin: root.anchorTop ? 0 : root.verticalMargin
          leftMargin: root.anchorLeft ? root.horizontalMargin : 0
          rightMargin: root.anchorLeft ? 0 : root.horizontalMargin
        }

        opacity: root.minimized ? 1.0 : 0.0
        scale: root.minimized ? 1.0 : 0.88
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        Row {
          anchors.centerIn: parent
          spacing: 4

          Text {
            id: pillLabel
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var a = root.currentAction
              return a ? String(a.label) : root.modelName
            }
            font.pixelSize: 12
            font.weight: Font.Medium
            color: root.muted
          }

          Text {
            id: chevron
            anchors.verticalCenter: parent.verticalCenter
            text: root.anchorTop ? "↓" : "↑"
            font.pixelSize: 11
            color: root.faint
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            root.minimized = false
            keyCatcher.forceActiveFocus()
          }
        }
      }

      // -- Card ---------------------------------------------------------
      BorderSurface {
        id: card
        width: root.cardWidth
        height: root.cardHeight
        radius: root.cardRadius
        borderSpec: root.borderSpec
        color: root.background
        clip: true

        anchors {
          top: root.anchorTop ? parent.top : undefined
          bottom: root.anchorTop ? undefined : parent.bottom
          left: root.anchorLeft ? parent.left : undefined
          right: root.anchorLeft ? undefined : parent.right
          topMargin: root.anchorTop ? root.verticalMargin : 0
          bottomMargin: root.anchorTop ? 0 : root.verticalMargin
          leftMargin: root.anchorLeft ? root.horizontalMargin : 0
          rightMargin: root.anchorLeft ? 0 : root.horizontalMargin
        }

        opacity: root.minimized ? 0.0 : 1.0
        scale: root.minimized ? 0.94 : 1.0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

        // The OCR source, in two short lines, so you can always check what the
        // AI actually read.
        Item {
          id: strip
          anchors { top: parent.top; left: parent.left; right: parent.right }
          height: root.stripHeight
          visible: root.sourceText !== ""

          Text {
            id: stripLabel
            anchors {
              left: parent.left; right: parent.right; top: parent.top
              leftMargin: root.bodyPadX; rightMargin: root.bodyPadX; topMargin: 10
            }
            text: root.sourceText
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            font.pixelSize: 12
            lineHeight: 1.15
            color: root.faint
          }

          Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: root.hairline
          }
        }

        // The answer itself
        Flickable {
          id: flickable
          anchors {
            top: strip.bottom; left: parent.left; right: parent.right; bottom: footer.top
          }
          clip: true
          contentWidth: width
          contentHeight: bodyLabel.implicitHeight + root.bodyPadTop + root.bodyPadBottom
          boundsBehavior: Flickable.StopAtBounds

          ScrollBar.vertical: ScrollBar {
            policy: flickable.contentHeight > flickable.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
          }

          property bool autoScroll: true
          onMovementStarted: flickable.autoScroll = false

          Connections {
            target: root
            function onAnswerChanged() {
              // The raw action is static reading: always start at the top.
              // Following the bottom only makes sense for a streaming answer.
              if (!root.currentActionUsesAi) {
                flickable.contentY = 0
                return
              }
              if (flickable.autoScroll)
                flickable.contentY = Math.max(0, flickable.contentHeight - flickable.height)
            }
            function onSourceTextChanged() {
              flickable.autoScroll = true
              flickable.contentY = 0
            }
          }

          Text {
            id: bodyLabel
            x: root.bodyPadX
            y: root.bodyPadTop
            width: flickable.width - root.bodyPadX * 2
            text: root.bodyText
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: 15
            lineHeight: 1.25
            color: root.stage === "error" ? root.urgent
              : (root.stage === "empty" ? root.muted : root.foreground)
          }

          // Spin until the first chunk arrives, so "waiting" is something you can see
          Text {
            id: spinner
            visible: root.waitingForFirstChunk
            x: root.bodyPadX
            y: root.bodyPadTop
            color: root.faint
            font.pixelSize: 15

            property int frame: 0
            property var frames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            text: frames[frame]

            Timer {
              interval: 80
              repeat: true
              running: spinner.visible
              onTriggered: spinner.frame = (spinner.frame + 1) % spinner.frames.length
            }
          }

          // Clicking the empty area takes keyboard focus back, so Esc and the
          // number keys keep working.
          MouseArea {
            anchors.fill: parent
            z: -1
            onClicked: keyCatcher.forceActiveFocus()
          }
        }

        // -- Footer: actions + controls ------------------------------
        Item {
          id: footer
          anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
          height: root.footerHeight

          Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 1
            color: root.hairline
          }

          Row {
            // With no text there is nothing to act on, so the chips fold away
            // and only copy / collapse / close remain.
            visible: root.stage !== "empty"

            anchors {
              left: parent.left; leftMargin: root.bodyPadX - 6
              verticalCenter: parent.verticalCenter
            }
            spacing: 2

            Repeater {
              model: root.actions

              Rectangle {
                id: chip
                required property var modelData

                readonly property bool active: root.currentAction
                  && root.currentAction.id === modelData.id

                width: chipLabel.implicitWidth + 18
                height: 26
                radius: 6
                color: chip.active
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  : (chipHover.containsMouse
                      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                      : "transparent")
                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                  id: chipLabel
                  anchors.centerIn: parent
                  text: String(chip.modelData.label || chip.modelData.id)
                  font.pixelSize: 12
                  font.weight: chip.active ? Font.Medium : Font.Normal
                  color: chip.active ? root.foreground : root.muted
                }

                MouseArea {
                  id: chipHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.runAction(chip.modelData)
                    keyCatcher.forceActiveFocus()
                  }
                }
              }
            }
          }

          Row {
            anchors {
              right: parent.right; rightMargin: root.bodyPadX - 8
              verticalCenter: parent.verticalCenter
            }
            spacing: 2

            // copy
            Rectangle {
              width: 28; height: 28; radius: 14
              color: copyHover.containsMouse
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                : "transparent"
              Text {
                anchors.centerIn: parent
                text: root.justCopied ? "✓" : "⎘"
                font.pixelSize: 14
                color: root.justCopied ? root.foreground : root.muted
              }
              MouseArea {
                id: copyHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copyAnswer()
              }
            }

            // collapse to the pill
            Rectangle {
              width: 28; height: 28; radius: 14
              color: minHover.containsMouse
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                : "transparent"
              Text {
                anchors.centerIn: parent
                text: root.anchorTop ? "↓" : "↑"
                font.pixelSize: 13
                color: root.muted
              }
              MouseArea {
                id: minHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleMinimize()
              }
            }

            // close
            Rectangle {
              width: 28; height: 28; radius: 14
              color: closeHover.containsMouse
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                : "transparent"
              Text {
                anchors.centerIn: parent
                text: "✕"
                font.pixelSize: 13
                color: root.muted
              }
              MouseArea {
                id: closeHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.dismiss()
              }
            }
          }
        }

        // model name watermark
        Text {
          anchors {
            right: parent.right; rightMargin: root.bodyPadX
            bottom: footer.top; bottomMargin: 6
          }
          text: root.currentActionUsesAi ? root.modelName : ""
          font.pixelSize: 10
          color: root.faint
          opacity: 0.75
        }
      }
    }
  }

  function toggleMinimize() {
    root.minimized = !root.minimized
    if (!root.minimized) keyCatcher.forceActiveFocus()
  }
}
