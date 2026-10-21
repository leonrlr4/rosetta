.pragma library

// Which way to translate, and what to send the model. Pure functions, no
// QML types, so tests/test_lang.qml can exercise every branch head-less.

var HAN = /[㐀-䶿一-鿿豈-﫿\u{20000}-\u{2ffff}]/gu
var KANA = /[぀-ヿ]/g
var HANGUL = /[가-힯]/g
var LATIN_WORD = /[A-Za-zÀ-ɏ]+(?:['’-][A-Za-zÀ-ɏ]+)*/g

function count(re, s) {
  var m = s.match(re)
  return m ? m.length : 0
}

// "zh" or "en": the language the selection is mostly in.
//
// A Han character carries about as much as an English word, but mixed text
// in this direction ("這個 bug 很難修") is Chinese with loanwords, and mixed
// text the other way ("I love 火鍋") is English with a dish name. Weighting a
// Latin word at 1.5 Han characters gets both right; at 1.0 the second one
// ties and falls to Chinese.
function detect(text) {
  var s = String(text || "")
  var han = count(HAN, s) + count(KANA, s) + count(HANGUL, s)
  var words = count(LATIN_WORD, s)
  if (han === 0 && words === 0) return "en"
  return han >= words * 1.5 ? "zh" : "en"
}

function target(source) { return source === "zh" ? "en" : "zh" }

// Chinese output is always Traditional Chinese with Taiwan usage.
function languageName(lang) { return lang === "en" ? "English" : "繁體中文" }

// Short label for the direction chips.
function chip(lang) { return lang === "zh" ? "中文" : "EN" }

// A single word or a short phrase gets a dictionary-style answer in explain
// mode; anything longer is explained as a passage.
function isShort(text) {
  var s = String(text || "").trim()
  if (!s) return false
  if (detect(s) === "zh") return count(HAN, s) <= 6 && !/[。！？；\n]/.test(s)
  return count(LATIN_WORD, s) <= 3 && !/[.!?;\n]/.test(s.replace(/\.$/, ""))
}

// The prompt for one translation, as OpenAI-style chat messages.
//
// tone "casual" asks for how people actually talk ("I'm going crazy with
// this project", 「會議暫時延後了」) instead of the register of a notice;
// "formal" sends Tencent's template unchanged. Hy-MT2 follows a style clause
// placed inside its instruction sentence without breaking the
// output-only-the-translation rule; tried on 2026-10-21.
//
// style "hunyuan" is Tencent's own template for Hy-MT2, from its model card:
// no system prompt, the instruction in the source language, and the target
// named in that language too ("Chinese names should be used in Chinese
// prompts"). Given anything else it drifts into commentary. style "chat" is
// for general instruction-tuned models.
function translateMessages(text, source, style, tone) {
  var to = languageName(target(source))
  var casual = tone !== "formal"
  if (style === "hunyuan") {
    if (source === "zh")
      return [{ role: "user", content: "将以下文本翻译为英语" +
        (casual ? "，用自然、口语化的日常说法，像朋友聊天一样" : "") +
        "，注意只需要输出翻译后的结果，不要额外解释：\n\n" + text }]
    return [{ role: "user", content: "Translate the following text into Traditional Chinese" +
      (casual ? ", in casual, everyday spoken Taiwanese Mandarin, the way people actually talk" : "") +
      ". Note that you should only output the translated result without any additional explanation:\n\n" + text }]
  }
  return [
    { role: "system", content:
      "You are a professional translator between Chinese and English. Translate the user's text into " + to +
      (casual ? ", in casual, natural everyday spoken language, the way people actually talk" : "") +
      ". Keep meaning, formatting, line breaks, code, URLs and names. Output only the translation, " +
      "with no quotes, notes or explanation." +
      (target(source) === "zh" ? " Use Traditional Chinese characters and Taiwan usage." : "") },
    { role: "user", content: text }
  ]
}

// Explain mode: the meaning and use of the selection, written in the other
// language, so a learner reading it understands it.
//
// A word or short phrase gets a fixed dictionary layout, spelled out line by
// line. Asked loosely ("give senses with examples"), qwen3.5:4b wrote the
// examples only in the answer language, repeated each one, and ran a Chinese
// idiom together into one paragraph with invented IPA; with the layout below
// it gives the source-language example and its translation on separate lines.
// The instructions are in the language of the answer, which keeps the model
// answering in it.
var EXPLAIN_WORD_ZH =
  "你是朋友般的英文家教，用繁體中文、台灣口語回答。照這個格式，不要多寫：\n" +
  "第一行：最貼切的中文翻譯\n" +
  "第二行：詞性 · 發音（IPA）\n" +
  "接著 2 到 3 個意思，每個意思三行：\n" +
  "1. 這個意思的中文說明\n" +
  "   英文例句（日常口語）\n" +
  "   例句的中文翻譯\n" +
  "最後一行：「小提醒：」加上常見搭配或語感差別，一句話。\n" +
  "不要用 Markdown 粗體或標題。"

var EXPLAIN_WORD_EN =
  "You are a friendly Chinese tutor. Answer in English, casual and conversational. Use exactly this format, nothing else:\n" +
  "Line 1: the best English translation\n" +
  "Line 2: pinyin with tone marks · part of speech\n" +
  "Then 2-3 senses or usages, each three lines:\n" +
  "1. what it means, in English\n" +
  "   a Chinese example sentence (everyday spoken, Traditional characters)\n" +
  "   its English translation\n" +
  "Last line: \"Tip: \" plus one sentence on the origin, nuance or a common collocation.\n" +
  "No Markdown bold or headings. No IPA for Chinese."

var EXPLAIN_PASSAGE_ZH =
  "你是朋友般的英文家教，用繁體中文、台灣口語回答。先給一段自然的中文翻譯，" +
  "空一行，再用幾行短句說明裡面的慣用語、俚語、縮寫和語氣，也就是直翻會漏掉的地方。" +
  "像朋友聊天一樣講，不要開場白，不要用 Markdown 粗體或標題。"

var EXPLAIN_PASSAGE_EN =
  "You are a friendly Chinese tutor. Answer in English, casual and conversational. First give a natural " +
  "English translation, then a blank line, then a few short lines on idioms, slang, set phrases and tone, " +
  "the things a literal translation would miss. No preamble, no Markdown bold or headings."

function explainMessages(text, source) {
  var short = isShort(text)
  var system = source === "en"
    ? (short ? EXPLAIN_WORD_ZH : EXPLAIN_PASSAGE_ZH)
    : (short ? EXPLAIN_WORD_EN : EXPLAIN_PASSAGE_EN)
  return [{ role: "system", content: system }, { role: "user", content: text }]
}

// One line of a streamed response, as { delta, done, error }. Two shapes:
// Ollama's native /api/chat (one JSON object per line), and the
// OpenAI-compatible server-sent events that Ollama, llama-server and
// LM Studio all serve on /v1/chat/completions.
function parseStreamLine(line) {
  var s = String(line || "").trim()
  if (!s || s.charAt(0) === ":") return { delta: "", done: false, error: "" }
  if (s.indexOf("data:") === 0) s = s.slice(5).trim()
  if (s === "[DONE]") return { delta: "", done: true, error: "" }
  var msg
  try { msg = JSON.parse(s) } catch (e) { return { delta: "", done: false, error: "" } }
  if (msg.error) {
    var err = typeof msg.error === "string" ? msg.error : (msg.error.message || JSON.stringify(msg.error))
    return { delta: "", done: true, error: err }
  }
  if (msg.message !== undefined || msg.done !== undefined)
    return { delta: (msg.message && msg.message.content) || "", done: msg.done === true, error: "" }
  var choice = msg.choices && msg.choices[0]
  if (!choice) return { delta: "", done: false, error: "" }
  var delta = (choice.delta && choice.delta.content) || ""
  return { delta: delta, done: !!choice.finish_reason, error: "" }
}

// The request body for one call. An endpoint ending in /api/chat is Ollama's
// native API, which is the only way to keep the model loaded between
// presses (keep_alive) and to switch a hybrid model's reasoning off (think);
// anything else is sent the OpenAI shape.
function requestBody(endpoint, model, messages, options) {
  var o = options || {}
  if (/\/api\/chat\/?$/.test(endpoint)) {
    var body = { model: model, messages: messages, stream: true, keep_alive: o.keepAlive || "30m",
                 options: {} }
    if (o.think !== undefined) body.think = o.think
    if (o.temperature !== undefined) body.options.temperature = o.temperature
    if (o.topP !== undefined) body.options.top_p = o.topP
    if (o.topK !== undefined) body.options.top_k = o.topK
    if (o.repeatPenalty !== undefined) body.options.repeat_penalty = o.repeatPenalty
    if (o.numCtx !== undefined) body.options.num_ctx = o.numCtx
    return body
  }
  var b = { model: model, messages: messages, stream: true }
  if (o.temperature !== undefined) b.temperature = o.temperature
  if (o.topP !== undefined) b.top_p = o.topP
  if (o.topK !== undefined) b.top_k = o.topK
  if (o.repeatPenalty !== undefined) b.repeat_penalty = o.repeatPenalty
  return b
}

// Reasoning models (Qwen3 and friends) may open with a <think> block even
// when asked not to; it is never part of the translation.
function stripThinking(text) {
  var s = String(text || "")
  s = s.replace(/<think>[\s\S]*?<\/think>\s*/g, "")
  var open = s.indexOf("<think>")
  if (open !== -1) s = s.slice(0, open)
  return s.replace(/^\s+/, "")
}
