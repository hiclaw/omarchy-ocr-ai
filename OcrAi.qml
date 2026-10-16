import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

import qs.Commons
import qs.Ui

// 截图 → OCR → AI。
//
// 一次交互只有三步：按下快捷键、框选区域、读结果。框选期间不显示任何窗口
// （否则会被截进图里），识别成功后才升起卡片并开始流式回答；取消选区、
// 或没识别到文字时静默收起，不弹错误、不留残影。
//
// 与宿主（omarchy-shell）的契约见此：open(payloadJson) / close() / opened。
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property bool minimized: false

  // ── 运行状态 ────────────────────────────────────────────────
  // idle → capturing（等待框选与识别）→ thinking（AI 流式输出）→ done / error
  property string stage: "idle"
  property string sourceText: ""     // OCR 结果，也是 AI 的输入
  property string actionId: ""       // 当前动作 id，空则用默认动作
  property string errorMessage: ""

  // 一次 AI 调用的两个守卫。宿主只给一个 Process，切换动作时要先打断上一轮，
  // 而 SIGTERM 是异步的：旧进程的 exited 可能在新一轮开始之后才到达。
  //   aiLaunched  —— 本轮真的启动过（onStarted 置位）。旧进程被杀时尚未置位，
  //                  因此可以据此把「上一轮的余音」和新进程的事件区分开。
  //   awaitingFirstChunk —— 采集器里还压着上一轮的文本，首字节到达前不显示。
  property bool aiLaunched: false
  property bool awaitingFirstChunk: false

  // ── 配置（~/.config/omarchy/ocr-ai.json 覆盖插件自带的 config.json）──
  property string position: "top-right"
  property string ocrLangs: "eng"
  property bool copyOcrToClipboard: true
  property var aiCommand: ["~/tools/bai", "-P", "river", "-p", "{pattern}"]
  property var actions: [{ "id": "raw", "label": "原文", "hotkey": "1", "pattern": "" }]

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

  // 回答正文：原文动作直接回显 OCR 文本，其余读 AI 的流
  readonly property string answer: root.currentActionUsesAi
    ? (root.awaitingFirstChunk ? "" : aiOut.text)
    : root.sourceText

  readonly property bool waitingForFirstChunk: root.stage === "thinking" && root.awaitingFirstChunk

  readonly property string modelName: {
    // 从 ai_command 里捡一个能代表这次回答的名字，纯粹用于卡片右下角的水印
    var argv = root.aiCommand || []
    for (var i = 0; i < argv.length - 1; i++)
      if (String(argv[i]) === "-P" || String(argv[i]) === "--profile") return String(argv[i + 1])
    return argv.length > 0 ? String(argv[0]).replace(/^.*\//, "") : "AI"
  }

  // ── 样式 ────────────────────────────────────────────────────
  readonly property int cardWidth: 420
  readonly property int cardRadius: 8
  readonly property int pillHeight: 30
  readonly property int footerHeight: 44
  readonly property int bodyPadTop: 14
  readonly property int bodyPadBottom: 14
  readonly property int bodyPadX: 18

  // 卡片离屏幕边缘的呼吸距离；贴着栏的那条边再让开栏本身，另加一道缝隙。
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

  // 卡片压在栏上会挡住状态图标，所以贴栏的那条边要整段让开栏本身，
  // 再留一道缝隙——这样卡片看起来是「挂」在栏下面，而不是浮在半空。
  // 栏的粗细是按方向取的，位置则从宿主给的 barConfig 快照读，
  // 读不到就按 Omarchy 默认的顶部栏处理。
  readonly property string barPosition: root.shell && root.shell.barConfig
    ? String(root.shell.barConfig.position || "top") : "top"
  readonly property bool barIsHorizontal: root.barPosition === "top" || root.barPosition === "bottom"
  readonly property bool cardSharesBarEdge: root.barIsHorizontal
    ? root.barPosition === (root.anchorTop ? "top" : "bottom")
    : root.barPosition === (root.anchorLeft ? "left" : "right")
  readonly property int barClearance: (root.barIsHorizontal ? Style.bar.sizeHorizontal
                                                            : Style.bar.sizeVertical)
    + root.barGap

  // 卡片贴着自己所锚的那条边的距离：贴栏就是栏厚 + 缝隙，否则只是普通边距。
  // 另一侧永远只留普通边距。
  readonly property int verticalMargin: root.barIsHorizontal && root.cardSharesBarEdge
    ? root.barClearance : root.screenMargin
  readonly property int horizontalMargin: !root.barIsHorizontal && root.cardSharesBarEdge
    ? root.barClearance : root.screenMargin

  // 高度按卡片实际所在的那块屏幕算（多屏时 Qt.application.screens[0] 未必是它）。
  readonly property int screenHeight: {
    var scr = panel.screen ? panel.screen
      : (Qt.application.screens.length > 0 ? Qt.application.screens[0] : null)
    return scr ? scr.height : 1080
  }

  // ── 卡片高度：贴合内容，但不越过屏幕 ─────────────────────────
  // 用 paintedHeight 而不是 implicitHeight：在 maximumLineCount + elide + lineHeight
  // 的组合下，implicitHeight 未必等于真正画出来的高度，结果是原文条的第二行
  // 被裁掉半个字。paintedHeight 是实际绘制高度，跟着它走就不会露馅。
  readonly property int stripHeight: root.sourceText === "" ? 0
    : Math.ceil(stripLabel.paintedHeight) + 20
  // 可用高度是屏幕高减去两头的留白：卡片本身的位置占用 verticalMargin，
  // 对面还要留一道 screenMargin。只扣 screenMargin*2 的话，长内容会把
  // 底部的页脚（复制/最小化/关闭）顶出屏幕外。
  readonly property int maxCardHeight:
    Math.max(root.screenHeight - root.verticalMargin - root.screenMargin, 160)
  readonly property int idealCardHeight:
    root.stripHeight + bodyLabel.implicitHeight + root.bodyPadTop + root.bodyPadBottom + root.footerHeight
  readonly property int cardHeight: Math.max(Math.min(root.idealCardHeight, root.maxCardHeight), 150)
  readonly property int panelHeight: (root.minimized ? root.pillHeight : root.cardHeight)
    + root.verticalMargin + root.screenMargin

  // ── 配置加载 ────────────────────────────────────────────────
  // 两份文件谁先读到不一定，所以各自暂存、读完再合并，用户配置总是压在上面。
  //
  // manifest 里刻意没有 keepLoaded：实例每次召唤都重建，配置也就每次都重读，
  // 改完配置文件下次召唤即生效，不必重启 shell。若改成 keepLoaded: true，
  // 实例只在 shell 启动时建一次，配置就会变成「启动时读死」，改文件不再生效。
  property var bundledConfig: null
  property var userConfig: null

  function loadConfig(jsonText, fromUser) {
    var cfg = null
    try {
      cfg = JSON.parse(jsonText)
    } catch (e) {
      console.warn("claw.ocr-ai: 配置解析失败:", e)
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

  // ── 宿主契约 ────────────────────────────────────────────────
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}

    // 允许调用方直接塞一段文本进来（跳过截图），便于别的来源复用这个卡片
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

  // 实例被拆掉时（面板收起、插件重载、shell 退出）子进程必须一起走。
  // 留一个还在等框选的 slurp 下来是最糟的结果：它握走输入却不显示任何界面，
  // 之后每次触发都再也框不出选区，而且看不出是谁干的。
  Component.onDestruction: {
    if (captureProc.running) captureProc.running = false
    if (aiProc.running) aiProc.running = false
  }

  // ── 捕获 → 识别 ─────────────────────────────────────────────
  function beginCapture() {
    // 上一轮选区还活着：掀掉重来。
    //
    // 正常情况这是「手滑连按两下」，代价只是重新框一次；异常情况是那一轮
    // slurp 卡住了（进程在、界面没出来，握走了输入），此时静默忽略就等于
    // 之后每一次按键都没反应。宁可重来，也不能有按键被无声吞掉。
    if (captureProc.running) captureProc.running = false

    if (aiProc.running) aiProc.running = false
    aiIdleTimer.stop()

    root.stage = "capturing"
    root.opened = false        // 框选期间不留任何窗口在屏幕上
    root.minimized = false
    root.sourceText = ""
    root.actionId = ""
    root.errorMessage = ""
    root.awaitingFirstChunk = false

    captureProc.running = true
  }

  // 只在真的识别出文字时动手。空结果要到 onCaptureExited 再判，
  // 因为宿主是先 streamEnded(stdout) 再 streamEnded(stderr)，在这里读 stderr
  // 拿到的还是上一轮的内容。
  function onCaptured(raw) {
    if (root.stage !== "capturing") return
    var text = String(raw || "").trim()
    if (text !== "") root.adoptText(text, null)
  }

  function onCaptureExited(exitCode) {
    if (root.stage !== "capturing") return   // 有文字时已经走进 AI 流程了

    // 没拿到文字分三种，脚本用退出码区分（见 scripts/capture-ocr.sh 头部契约）：
    //   0 + 无输出 → 用户取消了选区，安静收场，不留痕迹
    //   3          → 框了区域、图里确实没字，轻声说一句
    //   其它       → 真失败（缺依赖、截图/识别报错），原因必须摆到台面上
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

    root.errorMessage = err !== "" ? err : "OCR 失败（退出码 " + exitCode + "）"
    root.stage = "error"
  }

  function adoptText(text, action) {
    root.sourceText = text
    if (root.copyOcrToClipboard) Quickshell.execDetached(["wl-copy", text])
    // 捕获阶段到此结束。必须先离开 capturing，否则下面 runAction 的守卫
    // （拦住拖选途中的误触）会把这次正当的首跑一起挡掉，窗口再也出不来。
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

  // 文本走 stdin：既不落临时文件，也不把可能很长的识别结果塞进 argv，
  // 而且文本永远不参与 shell 解析——它以独立的 argv 位置传入，由 sh 原样交给管道。
  // 先自检命令是否存在，否则 shell 会吐一句带自己名字的英文报错，很难看。
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
        + '|| { printf "找不到 AI 命令：%s\\n" "$exe" >&2; exit 127; }; '
        + 'printf %s "$text" | "$exe" "$@"',
      "claw.ocr-ai", argv[0], root.sourceText].concat(argv.slice(1))
  }

  function runAction(action) {
    // 也接受动作 id，这样 shell IPC 可以直接驱动：
    //   omarchy-shell shell call claw.ocr-ai runAction summarize
    if (typeof action === "string") action = root.actionById(action)
    if (!action || root.stage === "capturing" || root.sourceText === "") return
    root.actionId = action.id
    root.errorMessage = ""

    if (!action.pattern) {
      // 原文动作：不惊动 AI
      if (aiProc.running) aiProc.running = false
      aiIdleTimer.stop()
      root.aiLaunched = false
      root.awaitingFirstChunk = false
      root.stage = "done"
      return
    }

    var argv = root.aiArgv(action)
    if (argv.length === 0) {
      root.errorMessage = "ai_command 未配置"
      root.stage = "error"
      return
    }

    root.stage = "thinking"
    root.aiLaunched = false
    root.awaitingFirstChunk = true

    // 先打断上一轮。SIGTERM 是异步的，新命令会在旧进程真正退出后才起来，
    // 中间那段由 aiLaunched 兜住。
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
      root.errorMessage = "AI 命令以代码 " + exitCode + " 退出"
      root.stage = "error"
    } else {
      root.stage = "done"
    }
  }

  function onAiStalled() {
    if (root.stage !== "thinking") return
    root.errorMessage = root.awaitingFirstChunk
      ? "AI 没有响应，检查 ai_command 是否可用"
      : "AI 输出中断"
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
      waitForEnd: false        // 边到边显示，才有逐字流出的感觉
      onDataChanged: {
        if (root.awaitingFirstChunk) {
          root.awaitingFirstChunk = false
          aiIdleTimer.interval = 30000   // 已经出字了，后面宽容一些
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

  // 静默看门狗：命令不存在、密钥失效、网络卡死这类失败都不会有任何输出，
  // 进程也不会发 exited，没有它就只剩一个永远转下去的卡片。
  // 分两段：等首字节要严一些（失败几乎都发生在这段），已经在出字了就宽容些。
  Timer {
    id: aiIdleTimer
    interval: 12000
    repeat: false
    onTriggered: root.onAiStalled()
  }

  // ── 展示 ────────────────────────────────────────────────────
  readonly property string bodyText: {
    if (root.stage === "error") return root.errorMessage
    if (root.stage === "empty") return "没识别到文字"
    if (root.stage === "thinking" && root.awaitingFirstChunk) return ""
    if (root.answer === "") return root.stage === "thinking" ? "" : "（无内容）"
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

  // ── 浮层 ────────────────────────────────────────────────────
  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    WlrLayershell.namespace: "claw-ocr-ai"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    // 只有可见的卡片／胶囊本身接收鼠标事件。面板那块矩形里其余留白
    // （边距、最小化后胶囊两侧的空白）对点击完全透明，点上去就是点后面的窗口——
    // 浮层不该比它实际占的地方更"厚"。
    mask: Region { item: root.minimized ? pill : card }

    // 只占卡片所在的那个角，不全屏铺开，因此不会挡住其他窗口的点击
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

      // ── 胶囊（最小化态）：留着答案，让用户回去接着干活 ──────────
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

      // ── 卡片 ────────────────────────────────────────────────
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

        // OCR 原文：短短两行，让人随时能核对「AI 到底读到了什么」
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

        // 回答正文
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
              // 「原文」是静态阅读：永远从文首看起。
              // 只有 AI 流式输出才需要一直跟着底部走。
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

          // 首字节到达前转起来，让「在等」这件事是看得见的
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

          // 点空白处把键盘焦点收回来，Esc / 数字键才继续有效
          MouseArea {
            anchors.fill: parent
            z: -1
            onClicked: keyCatcher.forceActiveFocus()
          }
        }

        // ── 页脚：动作 + 操作 ─────────────────────────────────
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
            // 没有文字时动作无从谈起，chips 一并收起，只留下复制/最小化/关闭
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

            // 复制
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

            // 收起为胶囊
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

            // 关闭
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

        // 模型名水印
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
