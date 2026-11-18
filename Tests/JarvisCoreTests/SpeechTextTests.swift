import Testing
@testable import JarvisCore

struct SpeechTextTests {
    private func bash(_ c: String) -> ToolCall {
        ToolCall(name: "Bash", command: c, filePath: nil, description: nil)
    }

    @Test func bashNotRisky() {
        let r = SpeechText.permission(project: "blog", call: bash("npm test"), risky: false)
        #expect(r.speech == "blog izin istiyor: şu komutu çalıştırmak: npm test. Onaylıyor musun?")
        #expect(r.detail == "npm test")
    }

    @Test func bashRiskyEndsWithOnayliyorum() {
        let r = SpeechText.permission(project: "blog", call: bash("git push origin main"), risky: true)
        #expect(r.speech == "blog riskli bir işlem istiyor: şu komutu çalıştırmak: git push origin main. Onaylamak için onaylıyorum de.")
    }

    @Test func multilineLongCommandIsShortened() {
        let cmd = (0..<100).map { "word\($0 % 10)" }.joined(separator: "\n")
        #expect(cmd.count >= 500)
        let r = SpeechText.permission(project: "p", call: bash(cmd), risky: false)
        #expect(!r.speech.contains("\n"))
        let prefix = "p izin istiyor: şu komutu çalıştırmak: "
        let suffix = ". Onaylıyor musun?"
        #expect(r.speech.hasPrefix(prefix) && r.speech.hasSuffix(suffix))
        let portion = String(r.speech.dropFirst(prefix.count).dropLast(suffix.count))
        #expect(portion.count <= 121)
        #expect(portion.hasSuffix("…"))
        #expect(r.detail == cmd)
    }

    @Test func editPhraseUsesFileName() {
        let c = ToolCall(name: "Edit", command: nil, filePath: "/a/b/Foo.swift", description: nil)
        let r = SpeechText.permission(project: "p", call: c, risky: false)
        #expect(r.speech == "p izin istiyor: Foo.swift dosyasını değiştirmek. Onaylıyor musun?")
        #expect(r.detail == "/a/b/Foo.swift")
    }

    @Test func mcpPhrase() {
        let c = ToolCall(name: "mcp__github__merge_pull_request", command: nil, filePath: nil, description: nil)
        let r = SpeechText.permission(project: "p", call: c, risky: false)
        #expect(r.speech.contains("github aracını kullanmak: merge_pull_request"))
        #expect(r.detail == "mcp__github__merge_pull_request")
    }

    @Test func exitPlanModeAndOther() {
        let a = ToolCall(name: "ExitPlanMode", command: nil, filePath: nil, description: nil)
        #expect(SpeechText.permission(project: "p", call: a, risky: false).speech == "p izin istiyor: planı onaylatmak. Onaylıyor musun?")
        let b = ToolCall(name: "WebFetch", command: nil, filePath: nil, description: nil)
        #expect(SpeechText.permission(project: "p", call: b, risky: false).speech.contains("WebFetch aracını kullanmak"))
    }

    @Test func stopWithText() {
        let r = SpeechText.stop(project: "blog", lastAssistantText: "Testleri ekledim. Hepsi geçti.")
        #expect(r.speech == "blog cevap verdi. Testleri ekledim. Hepsi geçti. Sırada ne var?")
        #expect(r.asksQuestion == false)
        #expect(r.info == false)
        #expect(r.displayText == "Testleri ekledim. Hepsi geçti.")
    }

    @Test func stopWithoutQuestionSaysCevapVerdi() {
        let r = SpeechText.stop(project: "blog", lastAssistantText: "Bitti! Her şey yolunda.")
        #expect(r.speech == "blog cevap verdi. Bitti! Her şey yolunda. Sırada ne var?")
        #expect(r.asksQuestion == false)
    }

    @Test func stopReadsWholeMessageUpTo120Words() {
        let text = (1...120).map { "w\($0)" }.joined(separator: " ") + "."
        let r = SpeechText.stop(project: "p", lastAssistantText: text)
        #expect(r.speech == "p cevap verdi. \(text) Sırada ne var?")
        #expect(!r.speech.contains("devamı ekranda"))
        let paragraphs = "Birinci paragraf burada.\n\nİkinci paragraf da var.\nSon satır"
        let p2 = SpeechText.stop(project: "p", lastAssistantText: paragraphs)
        #expect(p2.speech == "p cevap verdi. Birinci paragraf burada. İkinci paragraf da var. Son satır. Sırada ne var?")
        #expect(p2.displayText == "Birinci paragraf burada.\nİkinci paragraf da var.\nSon satır.")
    }

    @Test func stopLongMessageEndsWithDevamiEkranda() {
        let text = (1...200).map { "w\($0)" }.joined(separator: " ") + "."
        let reply = SpeechText.stop(project: "p", lastAssistantText: text)
        let spoken = (1...120).map { "w\($0)" }.joined(separator: " ")
        #expect(reply.speech == "p cevap verdi. \(spoken)… devamı ekranda. Sırada ne var?")
        // The panel shows everything.
        #expect(reply.displayText == text)
        let info = SpeechText.stop(project: "p", lastAssistantText: "Hâlâ sürüyor. " + text)
        #expect(info.info == true)
        #expect(info.speech.hasSuffix("… devamı ekranda."))
        let words = info.speech.dropFirst("p çalışıyor, bitince haber verecek. ".count).split(separator: " ")
        #expect(words.count == 120 + 2) // 120 words, then "devamı ekranda."
    }

    @Test func stopQuestionCutOffByCapIsSpokenLast() {
        let filler = (1...130).map { "w\($0)" }.joined(separator: " ") + "."
        let r = SpeechText.stop(project: "p", lastAssistantText: filler + " Göndereyim mi?")
        #expect(r.asksQuestion == true)
        let spoken = (1...120).map { "w\($0)" }.joined(separator: " ")
        #expect(r.speech == "p soruyor. \(spoken)… devamı ekranda. Göndereyim mi?")
        // Within the cap the question is read in place, not repeated.
        let short = SpeechText.stop(project: "p", lastAssistantText: "Göndereyim mi? Notlar aşağıda.")
        #expect(short.speech == "p soruyor. Göndereyim mi? Notlar aşağıda.")
    }

    @Test func stopDropsCodeFencesAndUrls() {
        let text = """
        Şunu çalıştırdım:
        ```bash
        swift test ?
        ls -la ?
        ```
        Ayrıntı: https://example.com/a?b=1. Belge [burada](https://x.org/docs) ve <https://y.org>.
        `swift build` temiz.
        """
        let r = SpeechText.stop(project: "p", lastAssistantText: text)
        #expect(r.asksQuestion == false) // a bare "?" inside the dropped fence is not a question
        #expect(!r.speech.contains("http"))
        #expect(!r.speech.contains("ls -la"))
        #expect(r.speech == "p cevap verdi. Şunu çalıştırdım: (kod). Ayrıntı: (bağlantı). Belge burada (bağlantı) ve (bağlantı). swift build temiz. Sırada ne var?")
        #expect(r.displayText == "Şunu çalıştırdım:\n(kod).\nAyrıntı: (bağlantı). Belge burada (bağlantı) ve (bağlantı).\nswift build temiz.")
        // An unterminated fence drops everything after it.
        let open = SpeechText.stop(project: "p", lastAssistantText: "Önce bu.\n```\nrm -rf x?\n")
        #expect(open.speech == "p cevap verdi. Önce bu. (kod). Sırada ne var?")
        #expect(open.asksQuestion == false)
    }

    @Test func stopCleaningEdgeCases() {
        // A one-line fence does not swallow the rest of the message.
        let one = SpeechText.stop(project: "p", lastAssistantText: "```ls -la```\nBitti.")
        #expect(one.speech == "p cevap verdi. (kod). Bitti. Sırada ne var?")
        // A link at the line end keeps its closing parenthesis; a parenthesised question still asks.
        let link = SpeechText.stop(project: "p", lastAssistantText: "Bak: https://x.org/a")
        #expect(link.speech == "p cevap verdi. Bak: (bağlantı). Sırada ne var?")
        let paren = SpeechText.stop(project: "p", lastAssistantText: "Bitti. (Göndereyim mi?)")
        #expect(paren.asksQuestion == true)
        #expect(SpeechText.lastQuestion(in: paren.displayText) == "(Göndereyim mi?)")
    }

    @Test func stopInfoWhenStillWorking() {
        let r = SpeechText.stop(project: "jarvis", lastAssistantText: "Yatakhane hâlâ yapılıyor, bitince haber vereceğim.")
        #expect(r.info == true)
        #expect(r.asksQuestion == false)
        #expect(r.speech == "jarvis çalışıyor, bitince haber verecek. Yatakhane hâlâ yapılıyor, bitince haber vereceğim.")
        for t in ["Build SÜRÜYOR.", "TESTLER HÂLÂ ÇALIŞIYOR.", "Testler arka planda çalışıyor.", "The job is STILL RUNNING.", "It hasn’t finished.",
                  "I WILL LET YOU KNOW.", "Arka planda derleniyor."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == true, "\(t)")
        }
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Testler geçti.").info == false)
        // A phrase inside a dropped code fence does not count.
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Bitti.\n```\necho still running\n```").info == false)
    }

    @Test func stillWorkingNeedsAnInProgressPhrase() {
        // "now passes" and "waiting for you" are not progress reports.
        for t in ["Testler artık çalışıyor.", "Onayını bekliyorum.", "Bitince söyle.", "Hâlâ aynı hata."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == false, "\(t)")
        }
        for t in ["Yatakhane hâlâ yapılıyor, bitince haber vereceğim.", "Testler arka planda çalışıyor."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == true, "\(t)")
        }
    }

    @Test func liveOtelExampleIsInfo() {
        let text = "Otel işi neredeyse bitti. Çalışan şu an son testlerini çalıştırıyor. Bitince sonucu sana yazacağım."
        let r = SpeechText.stop(project: "p", lastAssistantText: text)
        #expect(r.info == true)
        #expect(r.asksQuestion == false)
        for t in ["Sonucu bildireceğim.", "İş neredeyse bitti.", "Şu an derleme bitmek üzere çalışıyor.",
                  "ŞU AN testler koşuyor."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == true, "\(t)")
        }
        // "şu an" needs a later "-yor" word in the same sentence.
        for t in ["Şu an her şey yeşil.", "Şu an hazır. Testler artık çalışıyor."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == false, "\(t)")
        }
    }

    @Test func ongoingNowScanIsLinear() {
        // 60 KB of "şu an" with no "-yor" word: must not backtrack (this runs inside the hook).
        var text = ""
        while text.utf8.count < 60 * 1024 { text += "şu an " }
        let clock = ContinuousClock()
        var r: (speech: String, asksQuestion: Bool, info: Bool, displayText: String)?
        let elapsed = clock.measure { r = SpeechText.stop(project: "p", lastAssistantText: text) }
        #expect(r?.info == false)
        #expect(elapsed < .milliseconds(500))
        // The scan still finds a later "-yor" word in the same sentence, and only there.
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Şu an, sanırım, testler koşuyor.").info == true)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Testler koşuyor, şu an.").info == false)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Şuan yor.").info == false)
    }

    @Test func linkAndMarkupCleaningIsLinear() {
        // Pathological inputs for the link and markup cleaning, all inside the hook's path.
        let inputs = [
            String(repeating: "[", count: 30_000),
            "http://" + String(repeating: ".", count: 30_000) + "x",
            String(repeating: "<http://", count: 4_000),
            String(repeating: "[a](http://x", count: 3_000),
            "a" + String(repeating: ")", count: 30_000),
            String(repeating: "*", count: 30_000) + "a",
            String(repeating: "(", count: 30_000) + String(repeating: ")", count: 30_000),
            String(repeating: "x", count: 30_000) + String(repeating: "*", count: 30_000),
        ]
        let clock = ContinuousClock()
        for text in inputs {
            let elapsed = clock.measure { _ = SpeechText.stop(project: "p", lastAssistantText: text) }
            #expect(elapsed < .milliseconds(500), "\(text.prefix(12))")
        }
    }

    @Test func inputIsCappedBeforeCleaning() {
        let tail = " Göndereyim mi?"
        let text = String(repeating: "a ", count: SpeechText.inputCharLimit) + tail
        let r = SpeechText.stop(project: "p", lastAssistantText: text)
        // Everything after the first `inputCharLimit` characters is ignored.
        #expect(r.asksQuestion == false)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Kısa." + tail).asksQuestion == true)
    }

    @Test func linkLabelSearchStopsAtAClosingBracket() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "[x] foo](http://y) bitti.")
        // Not a markdown link: "[x]" is kept and nothing before the "]" is swallowed.
        #expect(r.displayText == "[x] foo]((bağlantı)) bitti.")
        let ok = SpeechText.stop(project: "p", lastAssistantText: "Bkz. [iki kelime](http://y) bitti.")
        #expect(ok.displayText == "Bkz. iki kelime (bağlantı) bitti.")
    }

    @Test func quotedPhrasesDoNotMakeInfo() {
        for t in ["Mesajımda \"haber vereceğim\" sözünü alıntı olarak yazdım.",
                  "“Bitince haber veririm” demiştim, ama iş bitti.",
                  "«Arka planda» kelimesini sildim.",
                  "`still running` durumunu kaldırdım."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == false, "\(t)")
        }
        // Outside quotes it still counts; an unclosed quote hides nothing.
        #expect(SpeechText.stop(project: "p", lastAssistantText: "\"Otel\" işi hâlâ yapılıyor.").info == true)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Build \"sürüyor.").info == true)
    }

    @Test func quotedQuestionMarkIsNotAQuestion() {
        let live = "İkincisi: Kısa bir cevaptı, kedi \"Sırada ne var?\" diye sordu. … Düzeltme bitince kısaca haber vereceğim."
        let r = SpeechText.stop(project: "p", lastAssistantText: live)
        #expect(r.asksQuestion == false)
        #expect(r.info == true) // the unquoted "haber vereceğim" at the end
        for t in ["Şunu sordum: “Göndereyim mi?” Tamam.", "«Göndereyim mi?» diye sordu.",
                  "`x?` ve \"ne var?\" yazdım."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).asksQuestion == false, "\(t)")
        }
        // A real question after a quoted one still asks; the quoted one is never the question line.
        let both = SpeechText.stop(project: "p", lastAssistantText: "Kedi \"Sırada ne var?\" dedi. Göndereyim mi?")
        #expect(both.asksQuestion == true)
        #expect(SpeechText.lastQuestion(in: both.displayText) == "Göndereyim mi?")
        let after = SpeechText.stop(project: "p", lastAssistantText: "Göndereyim mi? Kedi \"Sırada ne var?\" dedi.")
        #expect(SpeechText.lastQuestion(in: after.displayText) == "Göndereyim mi?")
        // An unclosed quote hides nothing.
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Şunu soruyorum: \"Göndereyim mi?").asksQuestion == true)
    }

    @Test func multiWordMarkdownLinkKeepsItsLabel() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "Bkz. [Apple belgeleri](https://x.org) ve (bkz. https://y.org).")
        #expect(r.displayText == "Bkz. Apple belgeleri (bağlantı) ve (bkz. (bağlantı)).")
    }

    @Test func spokenTextIsBoundedInCharacters() {
        let token = String(repeating: "x", count: 500)
        let r = SpeechText.stop(project: "p", lastAssistantText: (1...200).map { _ in token }.joined(separator: " "))
        #expect(r.speech.count <= SpeechText.spokenCharLimit)
        #expect(r.speech.split(separator: " ").allSatisfy { $0.count <= SpeechText.spokenWordChars + 1 })
        let longQuestion = (1...130).map { "w\($0)" }.joined(separator: " ") + ". "
            + (1...30).map { _ in String(repeating: "q", count: 60) }.joined(separator: " ") + " mi?"
        let q = SpeechText.stop(project: "p", lastAssistantText: longQuestion)
        #expect(q.asksQuestion == true)
        let appended = q.speech.components(separatedBy: "devamı ekranda. ").last ?? ""
        #expect(appended.count <= SpeechText.spokenQuestionChars)
        #expect(appended.hasSuffix("mi?"))
    }

    @Test func questionWinsOverInfo() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "Build hâlâ sürüyor. Beklemeli miyim?")
        #expect(r.asksQuestion == true)
        #expect(r.info == false)
        #expect(r.speech == "p soruyor. Build hâlâ sürüyor. Beklemeli miyim?")
    }

    @Test func displayTextIsBoundedForTheWire() {
        // Longer than the display limit, shorter than the input limit.
        let long = (1...1500).map { "kelime\($0)" }.joined(separator: " ") + ". Göndereyim mi?"
        #expect(long.count > SpeechText.displayCharLimit && long.count < SpeechText.inputCharLimit)
        let r = SpeechText.stop(project: "p", lastAssistantText: long)
        #expect(r.displayText.count <= SpeechText.displayCharLimit + 200)
        // The question survives the cut, so the panel can still show it.
        #expect(SpeechText.lastQuestion(in: r.displayText) == "Göndereyim mi?")
    }

    @Test func stopWithoutText() {
        for t in [nil, "  \n ", "**  **\n- "] as [String?] {
            let r = SpeechText.stop(project: "blog", lastAssistantText: t)
            #expect(r.speech == "blog cevap verdi. Sırada ne var?")
            #expect(r.asksQuestion == false)
            #expect(r.info == false)
            #expect(r.displayText == "")
        }
    }

    @Test func stopWithQuestionReadsWholeMessage() {
        let r = SpeechText.stop(project: "blog", lastAssistantText: "Testler geçti. Commit edip göndereyim mi?")
        #expect(r.speech == "blog soruyor. Testler geçti. Commit edip göndereyim mi?")
        #expect(r.asksQuestion == true)
    }

    @Test func stopQuestionLineIsTheLastOfSeveralQuestions() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "Bunu mu istedin? Bitti. Şimdi push edeyim mi? Notlar aşağıda.")
        #expect(r.speech == "p soruyor. Bunu mu istedin? Bitti. Şimdi push edeyim mi? Notlar aşağıda.")
        #expect(r.asksQuestion == true)
        #expect(SpeechText.lastQuestion(in: r.displayText) == "Şimdi push edeyim mi?")
    }

    @Test func stopStripsMarkdown() {
        let r = SpeechText.stop(project: "blog", lastAssistantText: "- **Ne oldu:** Jarvis bitti.")
        #expect(!r.speech.contains("*"))
        #expect(!r.speech.contains("-"))
        #expect(r.speech == "blog cevap verdi. Ne oldu: Jarvis bitti. Sırada ne var?")
    }

    @Test func stopStripsHeadingsCodeAndNumberedLists() {
        let text = "## Özet\n1. `swift test` __yeşil__\n* ikinci madde\nDevam edeyim mi?"
        let r = SpeechText.stop(project: "p", lastAssistantText: text)
        #expect(r.speech == "p soruyor. swift test yeşil. ikinci madde. Devam edeyim mi?")
        let plain = SpeechText.stop(project: "p", lastAssistantText: "## Özet\n1. `swift test` __yeşil__")
        #expect(plain.speech == "p cevap verdi. swift test yeşil. Sırada ne var?")
        let second = SpeechText.stop(project: "p", lastAssistantText: "1. `swift test` __yeşil__ oldu")
        #expect(second.speech == "p cevap verdi. swift test yeşil oldu. Sırada ne var?")
    }

    @Test func stopQuestionWrappedInEmphasis() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "Testler geçti. *Göndereyim mi?*")
        #expect(r.asksQuestion == true)
        #expect(r.speech == "p soruyor. Testler geçti. Göndereyim mi?")
        // A question inside quotes is only quoted, not asked (see quotedQuestionMarkIsNotAQuestion).
        let quoted = SpeechText.stop(project: "p", lastAssistantText: "Şunu sordum: “Göndereyim mi?” Tamam.")
        #expect(quoted.asksQuestion == false)
        #expect(quoted.displayText == "Şunu sordum: “Göndereyim mi?” Tamam.")
    }

    @Test func stopSkipsLeadingHeading() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "## Özet\nTestler geçti.")
        #expect(r.speech == "p cevap verdi. Testler geçti. Sırada ne var?")
        let onlyHeading = SpeechText.stop(project: "p", lastAssistantText: "## Özet")
        #expect(onlyHeading.speech == "p cevap verdi. Sırada ne var?")
    }

    @Test func stopNewlineEndsSentence() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "Testler geçti\nBuild de temiz")
        #expect(r.speech == "p cevap verdi. Testler geçti. Build de temiz. Sırada ne var?")
        let q = SpeechText.stop(project: "p", lastAssistantText: "Göndereyim mi?\nYoksa bekleyelim")
        #expect(q.speech == "p soruyor. Göndereyim mi? Yoksa bekleyelim.")
    }

    @Test func stopQuestionMarkInsideSentenceIsNotAQuestion() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "URL ?x=1 parametresini ekledim.")
        #expect(r.asksQuestion == false)
    }

    @Test func shortenRules() {
        #expect(SpeechText.shorten("a  b\n\nc", maxChars: 10) == "a b c")
        #expect(SpeechText.shorten("aaa bbb ccc", maxChars: 8) == "aaa bbb…")
        #expect(SpeechText.shorten("abcdefghij", maxChars: 4) == "abcd…")
    }

    // v1.3: "when it is done I will …" is a progress report, not a reply.
    @Test func futureWhenDoneIsInfo() {
        for t in ["Bitince uygulamayı yeniden başlatacağım ve izin penceresi tek başına çıkacak.",
                  "Testleri bitince göndereceğim.",
                  "BİTİNCE GÖNDERECEĞİM.",
                  "Derleme tamamlanınca deneyeceğiz.",
                  "Rapor tamamlandığında paylaşacağım.",
                  "Sonuç gelince bakacağım.",
                  "Build hazır olunca yükleyeceğim.",
                  "Bitti. Testler bittiğinde birleştireceğiz."] {
            let r = SpeechText.stop(project: "p", lastAssistantText: t)
            #expect(r.info == true, "\(t)")
            #expect(r.asksQuestion == false, "\(t)")
        }
    }

    @Test func futureWithoutTimeClauseIsNotInfo() {
        for t in ["Bunu yarın yapacağım.",
                  "Sonra bakarız.",
                  "Hazır göndereceğim.",                    // "hazır" without "olunca"
                  "Bitince söyle. Yarın göndereceğim.",     // clause and verb in different sentences
                  "Sonra testleri çalıştırdım.",            // past tense
                  "\"Bitince\" kelimesini sileceğim.",       // the time word only quoted
                  "“Bitince göndereceğim” demiştin, iş bitti."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == false, "\(t)")
        }
    }

    @Test func questionWinsOverFutureWhenDone() {
        let r = SpeechText.stop(project: "p", lastAssistantText: "Bitince yeniden başlatacağım. Devam edeyim mi?")
        #expect(r.asksQuestion == true)
        #expect(r.info == false)
    }

    @Test func futureWhenDoneScanIsLinear() {
        // Many time words and no future verb, and one long sentence with the verb at the very end.
        let inputs = [String(repeating: "sonra bitince hazır ", count: 1_000),
                      String(repeating: "x ", count: 9_000) + "bitince yapacağım."]
        let clock = ContinuousClock()
        for text in inputs {
            var r: (speech: String, asksQuestion: Bool, info: Bool, displayText: String)?
            let elapsed = clock.measure { r = SpeechText.stop(project: "p", lastAssistantText: text) }
            #expect(elapsed < .milliseconds(500))
            #expect(r?.info == text.hasSuffix("yapacağım."))
        }
    }

    @Test func eitherOrQuestionIsNotYesNo() {
        let live = SpeechText.stop(project: "p", lastAssistantText:
            "Kahve'yi kedinin düğmesine basarak mı seçtin, yoksa sesle mi söyledin?")
        #expect(live.asksQuestion == false)
        #expect(live.info == false)
        #expect(live.speech.hasPrefix("p soruyor. "))
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Çay mı kahve mi?").asksQuestion == false)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Bunu mu yapayım yoksa onu?").asksQuestion == false)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Göndereyim mi?").asksQuestion == true)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Hazır mısın?").asksQuestion == true)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Commit edip göndereyim mi?").asksQuestion == true)
    }

    @Test func eitherOrCheckIsLinear() {
        let text = String(repeating: "mı ", count: 20_000) + "mı?"
        let clock = ContinuousClock()
        var r: (speech: String, asksQuestion: Bool, info: Bool, displayText: String)?
        let elapsed = clock.measure { r = SpeechText.stop(project: "p", lastAssistantText: text) }
        #expect(elapsed < .milliseconds(500))
        #expect(r?.asksQuestion == false)
    }
    // MARK: - v1.4: narrow "sonra"

    @Test func sonraCountsOnlyAfterADiktenClause() {
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Testlerden sonra commit atacağım.").info == false)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Testler bittikten sonra commit atacağım.").info == true)
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Bundan sonra dikkat edeceğim.").info == false)
        for t in ["Derleme geçtikten sonra göndereceğim.", "Sonucu aldıktan sonra yazacağım.",
                  "Okuduktan sonra düzelteceğim.", "Gördükten sonra karar vereceğim.",
                  "Yükledikten sonra deneyeceğiz.", "Çıktıktan sonra bakacağım.",
                  "Kurduktan sonra başlatacağım.", "Gözden geçirildikten sonra birleştireceğim."] {
            #expect(SpeechText.stop(project: "p", lastAssistantText: t).info == true, "\(t)")
        }
        // "sonra" first in the sentence has no clause before it.
        #expect(SpeechText.stop(project: "p", lastAssistantText: "Sonra göndereceğim.").info == false)
    }

    // MARK: - v1.4: link edge cases

    @Test func adjacentMarkdownLinksKeepBothLabels() {
        #expect(SpeechText.replacingLinks("[a](http://x)[b](http://y)") == "a (bağlantı)b (bağlantı)")
        #expect(SpeechText.replacingLinks("[a](http://x),[b](http://y).") == "a (bağlantı),b (bağlantı).")
        // A destination with balanced parentheses ends at its own closing parenthesis.
        #expect(SpeechText.replacingLinks("[w](https://e.org/A_(b))!") == "w (bağlantı)!")
        // Existing shapes are unchanged.
        #expect(SpeechText.replacingLinks("[x] foo](http://y) bitti.") == "[x] foo]((bağlantı)) bitti.")
        #expect(SpeechText.replacingLinks("Bkz. [iki kelime](http://y) bitti.") == "Bkz. iki kelime (bağlantı) bitti.")
        #expect(SpeechText.replacingLinks("<https://y.org>.") == "(bağlantı).")
        #expect(SpeechText.replacingLinks("(bkz. https://y.org).") == "(bkz. (bağlantı)).")
    }

    @Test func whitespaceAroundALinkDestinationIsIgnored() {
        #expect(SpeechText.replacingLinks("[a]( http://x )") == "a (bağlantı)")
        #expect(SpeechText.replacingLinks("Bkz. [iki kelime](  http://x  ) bitti.") == "Bkz. iki kelime (bağlantı) bitti.")
        // Prose parentheses are not touched.
        #expect(SpeechText.replacingLinks("(bkz. https://y.org )") == "(bkz. (bağlantı) )")
    }

    @Test func fenceClosesOnlyOnALongEnoughRun() {
        let text = "Önce bu.\n````\n```\nrm -rf x?\n```\n````\nBitti."
        let r = SpeechText.stop(project: "p", lastAssistantText: text)
        #expect(r.speech == "p cevap verdi. Önce bu. (kod). Bitti. Sırada ne var?")
        #expect(r.asksQuestion == false)
        // A longer closing run closes; the other marker character does not.
        #expect(SpeechText.withoutCodeAndLinks("```\nx\n`````\nSon.") == ["(kod).", "Son."])
        #expect(SpeechText.withoutCodeAndLinks("~~~~\nx\n~~~\n```\n~~~~\nSon.") == ["(kod).", "Son."])
        // One-line fences still open and close at once.
        #expect(SpeechText.withoutCodeAndLinks("````ls````\nSon.") == ["(kod).", "Son."])
    }

    @Test func linkEdgeCasesStayLinear() {
        let inputs = [
            String(repeating: "[a](http://x)", count: 3_000),
            String(repeating: "[a]( http://x )", count: 2_000),
            "[a](" + String(repeating: " ", count: 30_000) + "http://x )",
            String(repeating: "](", count: 15_000) + "http://x",
            "[a](http://x" + String(repeating: "(", count: 30_000),
            "[a](http://x" + String(repeating: "()", count: 15_000) + ")",
            String(repeating: "`", count: 30_000) + "\n" + String(repeating: "``\n", count: 5_000),
            "``````\n" + String(repeating: "```\n", count: 5_000),
            // A one-line fence whose closer is almost long enough, many times over.
            String(repeating: "`", count: 5_000) + String(repeating: String(repeating: "`", count: 4_999) + "x", count: 3),
        ]
        let clock = ContinuousClock()
        for text in inputs {
            let elapsed = clock.measure { _ = SpeechText.stop(project: "p", lastAssistantText: text) }
            #expect(elapsed < .milliseconds(500), "\(text.prefix(12))")
        }
    }
}
