// lib/Lang.js: direction, prompts and stream parsing.
//
//     tests/run

import QtQuick
import "../lib/Lang.js" as Lang

QtObject {
  id: root

  property int checks: 0
  property var failed: []

  function check(name, actual, expected) {
    checks++
    var a = JSON.stringify(actual), e = JSON.stringify(expected)
    if (a !== e) failed.push(name + "\n    expected " + e + "\n    got      " + a)
  }

  Component.onCompleted: {
    // Direction.
    check("plain chinese", Lang.detect("今天天氣很好"), "zh")
    check("plain english", Lang.detect("The weather is nice today"), "en")
    check("chinese with a loanword", Lang.detect("這個 bug 很難修"), "zh")
    check("english with a dish name", Lang.detect("I love 火鍋"), "en")
    check("one english word", Lang.detect("serendipity"), "en")
    check("one han character", Lang.detect("愛"), "zh")
    check("numbers only", Lang.detect("12345"), "en")
    check("empty", Lang.detect(""), "en")
    check("simplified", Lang.detect("我们明天见"), "zh")
    check("target of zh", Lang.target("zh"), "en")
    check("target of en", Lang.target("en"), "zh")

    // Short or not, for explain mode.
    check("a word is short", Lang.isShort("ubiquitous"), true)
    check("a phrase is short", Lang.isShort("break the ice"), true)
    check("a sentence is not", Lang.isShort("I think we should break the ice first."), false)
    check("a chinese idiom is short", Lang.isShort("塞翁失馬"), true)
    check("a chinese sentence is not", Lang.isShort("我覺得我們應該先破冰。"), false)

    // Hy-MT2's template: instruction in the source language.
    var zh = Lang.translateMessages("你好", "zh", "hunyuan", "formal")
    check("hunyuan zh is one user turn", zh.length, 1)
    check("hunyuan zh prompt", zh[0].content, "将以下文本翻译为英语，注意只需要输出翻译后的结果，不要额外解释：\n\n你好")
    check("hunyuan zh casual", Lang.translateMessages("你好", "zh", "hunyuan")[0].content,
          "将以下文本翻译为英语，用自然、口语化的日常说法，像朋友聊天一样，注意只需要输出翻译后的结果，不要额外解释：\n\n你好")
    check("hunyuan en casual", Lang.translateMessages("hi", "en", "hunyuan")[0].content.indexOf("casual, everyday spoken Taiwanese") !== -1, true)
    check("hunyuan en formal has no style", Lang.translateMessages("hi", "en", "hunyuan", "formal")[0].content.indexOf("casual") === -1, true)
    var en = Lang.translateMessages("hello", "en", "hunyuan", "formal")
    check("hunyuan en prompt names traditional",
          en[0].content.indexOf("Translate the following text into Traditional Chinese. Note that") === 0, true)
    check("hunyuan en prompt ends with text", /\n\nhello$/.test(en[0].content), true)
    check("explaining an english word asks for traditional",
          Lang.explainMessages("serendipity", "en")[0].content.indexOf("繁體中文") !== -1, true)
    check("an english word gets the dictionary layout",
          Lang.explainMessages("serendipity", "en")[0].content.indexOf("英文例句") !== -1, true)
    check("a chinese idiom gets pinyin, not ipa",
          Lang.explainMessages("塞翁失馬", "zh")[0].content.indexOf("No IPA for Chinese") !== -1, true)
    check("a passage gets the passage prompt",
          Lang.explainMessages("I'm down for that, just let me know when you're free.", "en")[0].content.indexOf("慣用語") !== -1, true)
    var chat = Lang.translateMessages("hello", "en", "chat")
    check("chat has a system turn", chat[0].role, "system")
    check("chat asks for taiwan usage", chat[0].content.indexOf("Traditional Chinese characters") !== -1, true)

    // Request bodies.
    var o = Lang.requestBody("http://h:11434/api/chat", "m", [], { temperature: 0.7, topK: 20, think: false })
    check("ollama keeps the model", o.keep_alive, "30m")
    check("ollama think off", o.think, false)
    check("ollama options", o.options, { temperature: 0.7, top_k: 20 })
    var oa = Lang.requestBody("http://h:8080/v1/chat/completions", "m", [], { temperature: 0.7, think: false })
    check("openai flat options", oa.temperature, 0.7)
    check("openai has no keep_alive", oa.keep_alive, undefined)

    // Stream lines.
    check("sse delta", Lang.parseStreamLine('data: {"choices":[{"delta":{"content":"Hi"}}]}'),
          { delta: "Hi", done: false, error: "" })
    check("sse finish", Lang.parseStreamLine('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}').done, true)
    check("sse done", Lang.parseStreamLine("data: [DONE]").done, true)
    check("sse comment", Lang.parseStreamLine(": ping").delta, "")
    check("ollama delta", Lang.parseStreamLine('{"message":{"role":"assistant","content":"你"},"done":false}'),
          { delta: "你", done: false, error: "" })
    check("ollama done", Lang.parseStreamLine('{"message":{"content":""},"done":true}').done, true)
    check("ollama error", Lang.parseStreamLine('{"error":"model \\"x\\" not found, try pulling it first"}').error,
          'model "x" not found, try pulling it first')
    check("openai error", Lang.parseStreamLine('{"error":{"message":"bad"}}').error, "bad")
    check("garbage", Lang.parseStreamLine("<html>").delta, "")

    // Thinking blocks never reach the screen.
    check("closed think", Lang.stripThinking("<think>hmm</think>\nHello"), "Hello")
    check("open think", Lang.stripThinking("<think>still going"), "")
    check("no think", Lang.stripThinking("Hello"), "Hello")

    for (var i = 0; i < failed.length; i++) console.log("FAIL " + failed[i])
    console.log((failed.length ? "FAIL " : "ok ") + "lang: " + (checks - failed.length) + "/" + checks)
    Qt.exit(failed.length ? 1 : 0)
  }
}
