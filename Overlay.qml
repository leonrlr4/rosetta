import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "lib/Lang.js" as Lang

// Rosetta: highlight text anywhere, press a key, read it in the other language.
//
// bin/rosetta reads the highlight and the pointer position and summons this
// overlay with them. The model is called with curl, one process per request,
// streaming; the card grows as the words arrive. Nothing runs while it is
// closed, and the model itself is unloaded by Ollama after keepAlive.
Item {
  id: root

  property var shell: null

  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
                                       + "/leonrlr4.rosetta/config.json"

  // ---- settings ------------------------------------------------------------
  // Defaults, overlaid key by key with config.json. Translation goes to a
  // model trained only to translate; explaining needs a general one.
  readonly property var defaults: ({
    font: "LXGW WenKai TC",
    tone: "casual",           // or "formal"
    translate: {
      endpoint: "http://127.0.0.1:11434/api/chat",
      model: "hf.co/tencent/Hy-MT2-7B-GGUF:Q4_K_M",
      style: "hunyuan",
      // Tencent's recommended sampling for Hy-MT2. The context is cut from
      // Ollama's 32K default, which held 9.2 GB on the iGPU for a 6000-char
      // selection at most; 8K holds that with room for the answer.
      options: { temperature: 0.7, topP: 0.6, topK: 20, repeatPenalty: 1.05, numCtx: 8192 }
    },
    explain: {
      endpoint: "http://127.0.0.1:11434/api/chat",
      model: "qwen3.5:4b",
      style: "chat",
      options: { temperature: 0.3, think: false, numCtx: 8192 }
    }
  })
  property var config: root.defaults

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.config = root.merge(root.defaults, root.parseConfig(text())); root.configReady() }
    onLoadFailed: { root.config = root.defaults; root.configReady() }
  }

  // The file is read again on every open: the watch does not see a file
  // created after the shell started, and the first press after writing
  // config.json must already use it. The request waits for that read, and
  // goes anyway after a moment if no answer comes.
  property bool runPending: false
  function configReady() {
    if (!root.runPending) return
    root.runPending = false
    configTimeout.stop()
    root.run()
  }
  Timer { id: configTimeout; interval: 250; onTriggered: root.configReady() }

  function parseConfig(s) {
    try { return JSON.parse(s) } catch (e) { return {} }
  }
  function merge(base, over) {
    if (typeof over !== "object" || over === null || Array.isArray(over)) return base
    var out = {}
    for (var k in base) out[k] = base[k]
    for (var j in over) {
      out[j] = (typeof base[j] === "object" && base[j] !== null && !Array.isArray(base[j]))
        ? root.merge(base[j], over[j]) : over[j]
    }
    return out
  }

  // ---- state ---------------------------------------------------------------
  property bool opened: false
  property string source: ""
  property string from: "en"                  // detected, or swapped by hand
  property string mode: "translate"           // or "explain"
  property string result: ""
  property string error: ""
  property bool busy: false
  property bool editing: false
  property bool copied: false
  property real pointerX: -1
  property real pointerY: -1
  property string screenName: ""

  readonly property string to: Lang.target(root.from)
  readonly property var route: root.mode === "explain" ? root.config.explain : root.config.translate
  readonly property string shown: Lang.stripThinking(root.result)

  // Timing, for the footer: how long until the first word, and how fast after.
  property double startedAt: 0
  property double firstAt: 0
  property double endedAt: 0
  property int chunks: 0

  // Answers already given, by mode, direction and text, so flipping between
  // modes or pressing the key twice does not ask the model again.
  property var cache: ({})

  // ---- theme ---------------------------------------------------------------
  readonly property color bg: Color.menu.background
  readonly property color fg: Color.menu.text
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.62)
  readonly property color dimmer: Qt.rgba(fg.r, fg.g, fg.b, 0.38)
  readonly property color hairline: Qt.rgba(fg.r, fg.g, fg.b, 0.09)
  // A grey accent has no hue to turn; the second gradient colour then falls
  // back to the text colour so the border still visibly travels.
  readonly property color accent2: accent.hslSaturation < 0.12
    ? Qt.rgba(fg.r, fg.g, fg.b, 0.9)
    : Qt.hsla((accent.hslHue + 0.14) % 1, Math.min(1, accent.hslSaturation + 0.1), Math.min(0.78, accent.hslLightness + 0.08), 1)
  readonly property string uiFont: Style.font.menuFamily
  readonly property string textFont: root.config.font || Style.font.menuFamily

  // ---- lifecycle -----------------------------------------------------------
  // bin/rosetta passes the selection as a file in this user's runtime
  // directory, so it is never on a command line; `text` is for callers that
  // summon the overlay directly. Only a file in that directory, named the way
  // bin/rosetta names them, is read: the payload arrives over IPC, and this
  // must not become a way to show (and send to the model) any file.
  readonly property string selectionDir: (Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + Quickshell.env("UID")))
                                         + "/leonrlr4.rosetta/"
  function open(payloadJson) {
    var p = {}
    try { p = JSON.parse(payloadJson || "{}") } catch (e) {}
    var file = String(p.file || "")
    if (file) {
      if (file.indexOf(root.selectionDir + "selection.") !== 0 || file.indexOf("/", root.selectionDir.length) !== -1) return
      var reader = readerComponent.createObject(root, { payload: p, path: file })
      reader.running = true
      return
    }
    root.openWith(p, String(p.text || ""))
  }

  // cat and rm in one process: the file is gone as soon as it is read.
  Component {
    id: readerComponent
    Process {
      id: reader
      property var payload: ({})
      property string path: ""
      command: ["/usr/bin/bash", "-c", 'cat -- "$1"; rm -f -- "$1"', "_", reader.path]
      stdout: StdioCollector { id: readOut }
      onExited: { root.openWith(reader.payload, readOut.text); Qt.callLater(function() { reader.destroy() }) }
    }
  }

  function openWith(p, raw) {
    var text = String(raw || "").replace(/\r\n/g, "\n").trim().slice(0, 6000)

    // The key pressed again over the same text puts the card away.
    if (root.opened && text && text === root.source) { root.close(); return }

    root.pointerX = typeof p.x === "number" ? p.x : -1
    root.pointerY = typeof p.y === "number" ? p.y : -1
    root.screenName = p.screen || ""
    root.copied = false
    root.editing = false
    root.opened = true
    root.mode = "translate"
    root.setSourceFresh(text)
    if (!text) root.startEditing()
    else Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    root.cancel()
    root.opened = false
    root.editing = false
  }

  function toggle() { if (root.opened) root.close(); else root.open("{}") }

  // What tests/live reads through `omarchy-shell shell call leonrlr4.rosetta
  // inspect`, instead of screenshots. The shell's IPC socket is the user's
  // own, so nothing here reaches another user.
  function inspect(arg) {
    return JSON.stringify({ opened: root.opened, busy: root.busy, mode: root.mode, from: root.from,
                            source: root.source, result: root.shown, error: root.error,
                            firstTokenMs: root.firstAt ? root.firstAt - root.startedAt : 0,
                            totalMs: root.endedAt ? root.endedAt - root.startedAt : 0,
                            pending: root.proc !== null && root.proc.running,
                            card: { x: card.x, y: card.y, width: card.width, height: card.height } })
  }

  function setSource(text) {
    root.source = text
    root.from = Lang.detect(text)
    root.run()
  }

  function setSourceFresh(text) {
    root.source = text
    root.from = Lang.detect(text)
    root.cancel()
    root.result = ""
    root.error = ""
    root.runPending = true
    configTimeout.restart()
    configFile.reload()
  }

  // ---- requests ------------------------------------------------------------
  property int generation: 0
  property var proc: null

  // Everything that changes the answer, so editing config.json takes effect
  // on the next press instead of after the shell restarts.
  function cacheKey() {
    var r = root.route
    return [root.mode, root.from, r.endpoint, r.model, r.style, root.config.tone, root.source].join("|")
  }

  function run() {
    root.cancel()
    root.error = ""
    root.result = ""
    root.copied = false
    if (!root.source) return

    var hit = root.cache[root.cacheKey()]
    if (hit) {
      root.result = hit.text
      root.startedAt = 0
      root.firstAt = 0
      root.endedAt = 0
      root.chunks = 0
      return
    }

    var r = root.route
    var messages = root.mode === "explain"
      ? Lang.explainMessages(root.source, root.from)
      : Lang.translateMessages(root.source, root.from, r.style, root.config.tone)
    var body = JSON.stringify(Lang.requestBody(r.endpoint, r.model, messages, r.options))

    var gen = ++root.generation
    root.busy = true
    root.startedAt = Date.now()
    root.firstAt = 0
    root.endedAt = 0
    root.chunks = 0
    // The body goes in on stdin, never in argv: every local user can read a
    // process's command line in /proc, and the body is the selected text.
    // --fail-with-body so a 404 for a model that is not pulled still prints
    // Ollama's JSON error, which names the model. --proto keeps an endpoint
    // in config.json from turning into file:// or any other scheme curl
    // speaks, and --url keeps one starting with "-" from being read as an
    // option.
    root.proc = requestComponent.createObject(root, {
      gen: gen,
      body: body,
      command: ["/usr/bin/curl", "-sS", "-N", "--fail-with-body", "--proto", "=http,https",
                "--connect-timeout", "2", "--max-time", "240",
                "-H", "Content-Type: application/json", "--data-binary", "@-", "--url", String(r.endpoint)]
    })
    root.proc.running = true
  }

  function cancel() {
    root.generation++
    if (root.proc) {
      root.proc.running = false
      root.proc.destroy()
      root.proc = null
    }
    root.busy = false
  }

  function onLine(gen, line) {
    if (gen !== root.generation) return
    var m = Lang.parseStreamLine(line)
    if (m.error) { root.fail(m.error); return }
    if (m.delta) {
      if (!root.firstAt) root.firstAt = Date.now()
      root.chunks++
      root.result += m.delta
    }
    if (m.done) root.finish(gen)
  }

  function onExit(gen, code, stderr) {
    if (gen !== root.generation || !root.busy) return
    if (code === 0) { root.finish(gen); return }
    // A partial answer stays on screen with the reason under it, and is not
    // cached: a cut-off answer coming back later as "cached" would look
    // complete. 28 is curl's --max-time, 18 and 56 a connection dropped
    // mid-stream (Ollama restarted).
    root.fail(code === 7
      ? "Ollama 沒有回應（" + root.route.endpoint + "）。啟動它：sudo systemctl enable --now ollama"
      : code === 28 ? "等太久了（240 秒），答案沒寫完。"
      : (code === 18 || code === 56) && root.result ? "連線中斷，答案沒寫完。"
      : (stderr.trim() || ("curl 結束碼 " + code)))
  }

  function finish(gen) {
    if (gen !== root.generation) return
    root.busy = false
    root.endedAt = Date.now()
    if (!root.shown) return
    root.remember(root.cacheKey(), root.result)
    // Chinese is always shown in Traditional characters with Taiwan usage.
    // The prompt asks for that, but a model trained mostly on Simplified text
    // slips; OpenCC's s2tw turns those characters Traditional. Not s2twp:
    // its phrase table rewrites words that are already Traditional and
    // correct, 項目 → 專案, 腳本 → 指令碼, 參數 → 引數, which changed the
    // meaning of a translated PR review ("gates" became 檢查專案).
    if (/[\u4e00-\u9fff]/.test(root.result)) {
      var conv = openccComponent.createObject(root, { key: root.cacheKey(), gen: gen, input: root.result })
      conv.running = true
    }
  }

  function remember(key, text) {
    var c = Object.assign({}, root.cache)
    c[key] = { text: text }
    root.cache = c
  }

  // One process per conversion, fed on stdin like curl so the answer is
  // never in argv either. A single reused Process lost conversions: when a
  // translation finished while the previous conversion was still running,
  // `running = true` was a no-op, and the old output then arrived carrying
  // the new generation and replaced the new answer.
  Component {
    id: openccComponent
    Process {
      id: conv
      property string key: ""
      property int gen: 0
      property string input: ""
      command: ["/usr/bin/opencc", "-c", "s2tw"]
      stdinEnabled: true
      onStarted: { write(conv.input); stdinEnabled = false }
      // Later, not now: the last of stdout can still be on its way.
      onExited: Qt.callLater(function() { conv.destroy() })
      stdout: StdioCollector {
        onStreamFinished: {
          var t = text
          if (!t) return
          root.remember(conv.key, t)
          if (conv.gen === root.generation && t !== root.result) root.result = t
        }
      }
    }
  }

  function fail(msg) {
    root.busy = false
    root.endedAt = Date.now()
    if (/not found/i.test(msg) && /model/i.test(msg))
      msg += "\n還沒下載這個模型：ollama pull " + root.route.model
    root.error = msg
  }

  Component {
    id: requestComponent
    Process {
      id: p
      property int gen: 0
      property string body: ""
      stdinEnabled: true
      onStarted: { write(p.body); stdinEnabled = false }
      stdout: SplitParser { onRead: function(line) { root.onLine(p.gen, line) } }
      stderr: StdioCollector { id: err }
      onExited: function(code) { root.onExit(p.gen, code, err.text) }
    }
  }

  // ---- actions -------------------------------------------------------------
  function copyAndClose() {
    if (!root.shown) return
    Quickshell.clipboardText = root.shown.trim()
    root.copied = true
    closeSoon.restart()
  }
  Timer { id: closeSoon; interval: 420; onTriggered: root.close() }

  function setMode(m) {
    if (root.mode === m) return
    root.mode = m
    root.run()
  }

  function swap() {
    root.from = root.to
    root.run()
  }

  function startEditing() {
    root.cancel()
    root.editing = true
    Qt.callLater(function() {
      editor.forceActiveFocus()
      editor.cursorPosition = editor.length
    })
  }

  function commitEdit() {
    root.editing = false
    keys.forceActiveFocus()
    // Same cap as bin/rosetta puts on a selection.
    var t = editor.text.trim().slice(0, 6000)
    if (t && t !== root.source) root.setSource(t)
    else if (!t) root.close()
    else root.run()
  }

  // ---- the surface ---------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    screen: {
      var list = Quickshell.screens
      for (var i = 0; i < list.length; i++) if (list[i].name === root.screenName) return list[i]
      return list.length ? list[0] : null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-rosetta"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The page under the card stays readable: a faint veil, not a scrim.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.14)
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 180 } }
    }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    readonly property int margin: 14
    readonly property real maxCardHeight: Math.min(560, panel.height * 0.6)
    readonly property bool hasPointer: root.pointerX >= 0 && root.pointerY >= 0
    // Decided from the room below the pointer for the tallest card, once per
    // open, so a card growing with the answer never jumps to the other side.
    readonly property bool above: hasPointer && root.pointerY + 24 + maxCardHeight > panel.height - margin

    // ---- glow -------------------------------------------------------------
    RectangularShadow {
      anchors.fill: card
      radius: card.radius
      blur: root.busy ? 46 : 30
      spread: root.busy ? 2 : 0
      color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, root.error ? 0 : (root.busy ? glowPulse.value : 0.22))
      opacity: card.opacity
      Behavior on blur { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
    }
    QtObject {
      id: glowPulse
      property real value: 0.3
      SequentialAnimation on value {
        running: root.busy && root.opened
        loops: Animation.Infinite
        NumberAnimation { to: 0.5; duration: 900; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0.24; duration: 900; easing.type: Easing.InOutSine }
      }
    }

    Rectangle {
      id: card
      readonly property real wantWidth: root.mode === "explain" ? 600
        : Math.max(420, Math.min(640, 300 + Math.max(root.source.length, root.shown.length) * 4))
      width: Math.min(wantWidth, panel.width - panel.margin * 2)
      height: Math.min(content.implicitHeight + 36, panel.maxCardHeight)
      x: !panel.hasPointer ? (panel.width - width) / 2
         : Math.max(panel.margin, Math.min(root.pointerX + 18 + width > panel.width - panel.margin
                                             ? root.pointerX - width - 18 : root.pointerX + 18,
                                           panel.width - width - panel.margin))
      y: !panel.hasPointer ? panel.height * 0.28
         : panel.above ? Math.max(panel.margin, root.pointerY - 16 - height)
         : Math.min(root.pointerY + 24, panel.height - height - panel.margin)
      radius: Math.max(Style.cornerRadius, 16)
      color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 1)
      clip: true

      Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

      // Entrance: up from the pointer side, scaling in.
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.95
      transformOrigin: panel.above ? Item.Bottom : Item.Top
      Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }

      MouseArea { anchors.fill: parent; onClicked: if (!root.editing) keys.forceActiveFocus() }

      // Accent wash from the top-left corner.
      Rectangle {
        width: parent.width; height: 120
        opacity: root.busy ? 0.16 : 0.08
        Behavior on opacity { NumberAnimation { duration: 500 } }
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0; color: root.accent }
          GradientStop { position: 0.7; color: "transparent" }
        }
      }
      Rectangle {
        width: parent.width; height: 120
        gradient: Gradient {
          GradientStop { position: 0; color: "transparent" }
          GradientStop { position: 1; color: Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 1) }
        }
      }

      Column {
        id: content
        x: 22; y: 18
        width: parent.width - 44
        spacing: 14

        // ---- header: direction and mode ---------------------------------
        Item {
          width: parent.width
          height: 28

          Row {
            spacing: 10
            anchors.verticalCenter: parent.verticalCenter

            LangChip { text: Lang.chip(root.from); strong: false }
            // The arrow, with a spark running along it while the model writes.
            Item {
              width: 44; height: 28
              anchors.verticalCenter: parent.verticalCenter
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width; height: 1.5; radius: 1
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0; color: root.dimmer }
                  GradientStop { position: 1; color: root.accent }
                }
              }
              Text {
                anchors.right: parent.right; anchors.rightMargin: -3
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: -1
                text: "›"
                color: root.accent
                font.pixelSize: 18
                font.family: root.uiFont
              }
              Rectangle {
                id: spark
                width: 6; height: 6; radius: 3
                anchors.verticalCenter: parent.verticalCenter
                color: root.accent2
                visible: root.busy
                NumberAnimation on x {
                  running: root.busy && root.opened
                  from: -3; to: 41; duration: 700
                  loops: Animation.Infinite
                  easing.type: Easing.InOutQuad
                }
                layer.enabled: true
                layer.effect: MultiEffect { blurEnabled: true; blur: 0.4; brightness: 0.3 }
              }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.swap() }
            }
            LangChip { text: Lang.chip(root.to); strong: true }
          }

          // Translate / Explain, with a sliding pill.
          Rectangle {
            id: modes
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: modeRow.width + 6; height: 28
            radius: 14
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
            border.width: 1
            border.color: root.hairline

            Rectangle {
              id: pill
              y: 3; height: parent.height - 6
              radius: height / 2
              x: 3 + (root.mode === "explain" ? tTranslate.width : 0)
              width: root.mode === "explain" ? tExplain.width : tTranslate.width
              color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22)
              border.width: 1
              border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.55)
              Behavior on x { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
              Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            }
            Row {
              id: modeRow
              x: 3
              anchors.verticalCenter: parent.verticalCenter
              ModeTab { id: tTranslate; label: "翻譯"; active: root.mode === "translate"; onPicked: root.setMode("translate") }
              ModeTab { id: tExplain; label: "解釋"; active: root.mode === "explain"; onPicked: root.setMode("explain") }
            }
          }
        }

        // ---- the source -------------------------------------------------
        Item {
          width: parent.width
          height: root.editing ? Math.max(editor.contentHeight, 22) + 16 : sourceText.height

          Text {
            id: sourceText
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.editing
            text: root.source
            color: root.dim
            font.family: root.textFont
            font.pixelSize: 14
            lineHeight: 1.15
            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.IBeamCursor
              onClicked: { editor.text = root.source; root.startEditing() }
            }
          }

          Rectangle {
            anchors.fill: parent
            visible: root.editing
            radius: 10
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
            border.width: 1
            border.color: editor.activeFocus ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.6) : root.hairline

            TextEdit {
              id: editor
              textFormat: TextEdit.PlainText
              x: 10; y: 8
              width: parent.width - 20
              color: root.fg
              font.family: root.textFont
              font.pixelSize: 15
              wrapMode: TextEdit.Wrap
              selectByMouse: true
              selectionColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)
              Text {
                visible: !editor.text
                text: "輸入或貼上要翻譯的文字 · Type text to translate"
                color: root.dimmer
                font: editor.font
              }
              Keys.onPressed: function(event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                  root.commitEdit(); event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  if (root.source) { root.editing = false; keys.forceActiveFocus() } else root.close()
                  event.accepted = true
                }
              }
            }
          }
        }

        // ---- divider, a light running across while the model writes ------
        Item {
          width: parent.width
          height: 1
          visible: !root.editing || root.source
          Rectangle { anchors.fill: parent; color: root.hairline }
          Rectangle {
            id: beam
            width: parent.width * 0.35; height: 1
            visible: root.busy
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: "transparent" }
              GradientStop { position: 0.5; color: root.accent }
              GradientStop { position: 1; color: "transparent" }
            }
            NumberAnimation on x {
              running: root.busy && root.opened
              from: -beam.width; to: content.width
              duration: 1100; loops: Animation.Infinite
              easing.type: Easing.InOutCubic
            }
          }
        }

        // ---- the answer -------------------------------------------------
        Item {
          id: answer
          width: parent.width
          visible: !root.editing
          readonly property real room: panel.maxCardHeight - 36 - 28 - sourceText.height - 1 - footer.height - 14 * 4
          // A partial answer and the reason it stopped can both be on screen.
          readonly property real errorRoom: root.error ? errorText.height + (root.shown ? 8 : 0) : 0
          height: !root.shown && root.busy ? skeleton.height
                : !root.shown ? errorRoom
                : Math.min(resultText.contentHeight + 4, Math.max(60, room - errorRoom)) + errorRoom

          // Waiting for the first word: shimmering lines.
          Column {
            id: skeleton
            visible: !root.shown && root.busy && !root.error
            width: parent.width
            spacing: 10
            Repeater {
              model: [0.92, 0.78, 0.52]
              Rectangle {
                required property var modelData
                required property int index
                width: skeleton.width * modelData
                height: 12; radius: 6
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
                clip: true
                Rectangle {
                  width: 140; height: parent.height
                  gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop { position: 0; color: "transparent" }
                    GradientStop { position: 0.5; color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35) }
                    GradientStop { position: 1; color: "transparent" }
                  }
                  NumberAnimation on x {
                    running: skeleton.visible && root.opened
                    from: -140; to: skeleton.width
                    duration: 1200; loops: Animation.Infinite
                    easing.type: Easing.InOutSine
                  }
                }
              }
            }
          }

          Flickable {
            id: flick
            width: parent.width
            height: parent.height - answer.errorRoom
            visible: !!root.shown
            contentHeight: resultText.contentHeight + 4
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // Keep the newest words in view while they stream in.
            onContentHeightChanged: if (root.busy && contentHeight > height) contentY = contentHeight - height

            TextEdit {
              id: resultText
              textFormat: TextEdit.PlainText
              // Selecting part of the answer must not take the keys away
              // from the card: Esc, Enter and Ctrl+C would stop working.
              activeFocusOnPress: false
              width: flick.width
              readOnly: true
              selectByMouse: true
              text: root.shown
              color: root.fg
              font.family: root.textFont
              font.pixelSize: root.mode === "explain" || root.shown.length > 160 ? 16 : 20
              wrapMode: TextEdit.Wrap
              selectionColor: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.4)

              // Caret at the end of the text while the model writes.
              Rectangle {
                readonly property rect end: resultText.positionToRectangle(resultText.length)
                visible: root.busy
                x: end.x + 2; y: end.y + 3
                width: Math.round(resultText.font.pixelSize * 0.5)
                height: end.height - 6
                radius: 2
                color: root.accent
                SequentialAnimation on opacity {
                  running: root.busy && root.opened
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.15; duration: 420 }
                  NumberAnimation { to: 1; duration: 420 }
                }
              }
            }
          }

          Text {
            id: errorText
            textFormat: Text.PlainText
            anchors.bottom: parent.bottom
            visible: !!root.error
            width: parent.width
            text: root.error
            color: root.urgent
            font.family: root.uiFont
            font.pixelSize: 12
            wrapMode: Text.Wrap
          }
        }

        // ---- footer: keys and speed --------------------------------------
        Item {
          id: footer
          width: parent.width
          height: 18

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.editing ? "⏎ 翻譯   ⇧⏎ 換行   esc 取消"
                               : "⏎ 複製   tab 翻譯/解釋   s 對調   e 編輯   r 重來   esc"
            color: root.dimmer
            font.family: root.uiFont
            font.pixelSize: 11
          }
          Text {
            id: stats
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            color: root.copied ? root.accent : root.dimmer
            font.family: root.uiFont
            font.pixelSize: 11
            text: {
              if (root.copied) return "已複製 ✓"
              if (root.busy && !root.firstAt) return "載入 " + root.route.model.replace(/^hf\.co\/[^/]+\//, "") + "…"
              if (!root.startedAt) return root.shown ? "cached" : ""
              var first = root.firstAt ? (root.firstAt - root.startedAt) : 0
              var end = root.endedAt || Date.now()
              var secs = root.firstAt ? Math.max(0.001, (end - root.firstAt) / 1000) : 0
              return (first ? first + " ms" : "") + (secs && root.chunks > 2 ? " · " + Math.round(root.chunks / secs) + " tok/s" : "")
            }
            scale: root.copied ? 1.08 : 1
            Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutBack } }
          }
        }
      }

      // ---- keys ----------------------------------------------------------
      Item {
        id: keys
        focus: true
        Keys.onPressed: function(event) {
          var ctrl = event.modifiers & Qt.ControlModifier
          switch (event.key) {
          case Qt.Key_Escape: case Qt.Key_Q:
            root.close(); break
          case Qt.Key_Return: case Qt.Key_Enter:
            root.copyAndClose(); break
          case Qt.Key_C:
            if (ctrl && resultText.selectedText) { Quickshell.clipboardText = resultText.selectedText; root.copied = true }
            else root.copyAndClose()
            break
          case Qt.Key_Tab: case Qt.Key_Backtab:
            root.setMode(root.mode === "translate" ? "explain" : "translate"); break
          case Qt.Key_S:
            root.swap(); break
          case Qt.Key_R:
            var c = Object.assign({}, root.cache); delete c[root.cacheKey()]; root.cache = c
            root.run(); break
          case Qt.Key_E: case Qt.Key_I:
            editor.text = root.source; root.startEditing(); break
          case Qt.Key_Up: case Qt.Key_K:
            flick.contentY = Math.max(0, flick.contentY - 40); break
          case Qt.Key_Down: case Qt.Key_J:
            flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + 40); break
          default:
            return
          }
          event.accepted = true
        }
      }
    }

    // ---- the travelling border ------------------------------------------
    // A conical gradient stroked around the card; it turns quickly while the
    // model writes and drifts slowly once it is done.
    Shape {
      id: ring
      x: card.x; y: card.y
      width: card.width; height: card.height
      opacity: card.opacity
      scale: card.scale
      transformOrigin: card.transformOrigin
      preferredRendererType: Shape.CurveRenderer
      property real angle: 0
      NumberAnimation on angle {
        running: root.opened
        from: 0; to: 360
        duration: root.busy ? 2200 : 9000
        loops: Animation.Infinite
      }
      ShapePath {
        strokeWidth: 1.5
        fillColor: "transparent"
        strokeGradient: ConicalGradient {
          centerX: ring.width / 2; centerY: ring.height / 2
          angle: ring.angle
          GradientStop { position: 0.00; color: root.error ? root.urgent : root.accent }
          GradientStop { position: 0.25; color: root.error ? root.urgent : root.accent2 }
          GradientStop { position: 0.50; color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.busy ? 0.10 : 0.06) }
          GradientStop { position: 0.75; color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, root.busy ? 0.10 : 0.06) }
          GradientStop { position: 1.00; color: root.error ? root.urgent : root.accent }
        }
        PathRectangle {
          x: 0.75; y: 0.75
          width: ring.width - 1.5; height: ring.height - 1.5
          radius: card.radius
        }
      }
    }
  }

  // ---- small pieces ----------------------------------------------------------
  component LangChip: Rectangle {
    property alias text: label.text
    property bool strong: false
    height: 26
    width: label.implicitWidth + 22
    radius: 13
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    color: strong ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.18) : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
    border.width: 1
    border.color: strong ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.6) : root.hairline
    Behavior on width { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
    Text {
      id: label
      anchors.centerIn: parent
      color: parent.strong ? root.accent : root.dim
      font.family: root.uiFont
      font.pixelSize: 12
      font.weight: Font.DemiBold
      font.letterSpacing: 0.5
    }
  }

  component ModeTab: Item {
    id: tab
    property string label: ""
    property bool active: false
    signal picked()
    width: tabText.implicitWidth + 24
    height: 22
    Text {
      id: tabText
      anchors.centerIn: parent
      text: tab.label
      color: tab.active ? root.fg : root.dimmer
      font.family: root.textFont
      font.pixelSize: 12
      Behavior on color { ColorAnimation { duration: 200 } }
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: tab.picked() }
  }
}
