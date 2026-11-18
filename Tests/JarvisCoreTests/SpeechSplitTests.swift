import Testing
@testable import JarvisCore

@Suite struct SpeechSplitTests {
    @Test func permissionQuestionIsLastSentence() {
        let s = SpeechSplit.split("jarvis izin istiyor: şu komutu çalıştırmak: ls -la. Onaylıyor musun?")
        #expect(s.body == "jarvis izin istiyor: şu komutu çalıştırmak: ls -la.")
        #expect(s.question == "Onaylıyor musun?")
    }

    @Test func riskyQuestionEndsWithPeriod() {
        let s = SpeechSplit.split("jarvis riskli bir işlem istiyor: şu komutu çalıştırmak: rm -rf x. Onaylamak için onaylıyorum de.")
        #expect(s.body == "jarvis riskli bir işlem istiyor: şu komutu çalıştırmak: rm -rf x.")
        #expect(s.question == "Onaylamak için onaylıyorum de.")
    }

    @Test func stopUsesLastSeparator() {
        let s = SpeechSplit.split("jarvis cevap verdi. Testler geçti. Sırada ne var?")
        #expect(s.body == "jarvis cevap verdi. Testler geçti.")
        #expect(s.question == "Sırada ne var?")
    }

    @Test func singleSentenceIsTheQuestion() {
        let s = SpeechSplit.split("Sırada ne var?")
        #expect(s.body == "")
        #expect(s.question == "Sırada ne var?")
    }

    @Test func remainderWithoutEndingPunctuationKeepsWholeText() {
        let s = SpeechSplit.split("Birinci cümle. ikinci kısım")
        #expect(s.body == "")
        #expect(s.question == "Birinci cümle. ikinci kısım")
    }

    @Test func questionStopShowsSoruyorLineAndFullQuestion() {
        let r = JarvisRequest(id: "i", sessionId: "s", project: "blog", kind: .stop,
                              speech: "blog soruyor: Testler geçti, commit edip göndereyim mi?",
                              detail: "", risky: false, deadlineS: 150, asksQuestion: true)
        let s = SpeechSplit.split(for: r)
        #expect(s.body == "blog soruyor:")
        #expect(s.question == "Testler geçti, commit edip göndereyim mi?")
    }

    @Test func requestWithoutQuestionUsesPlainSplit() {
        let r = JarvisRequest(id: "i", sessionId: "s", project: "jarvis", kind: .stop,
                              speech: "jarvis cevap verdi. Testler geçti. Sırada ne var?",
                              detail: "", risky: false, deadlineS: 150)
        let s = SpeechSplit.split(for: r)
        #expect(s.body == "jarvis cevap verdi. Testler geçti.")
        #expect(s.question == "Sırada ne var?")
    }

    @Test func permissionMentioningSoruyorUsesPlainSplit() {
        let r = JarvisRequest(id: "i", sessionId: "s", project: "p", kind: .permission,
                              speech: "p izin istiyor: şu komutu çalıştırmak: echo p soruyor: x. Onaylıyor musun?",
                              detail: "", risky: false, deadlineS: 150)
        #expect(SpeechSplit.split(for: r).question == "Onaylıyor musun?")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let s = SpeechSplit.split("  Gövde.  Soru mu?  ")
        #expect(s.body == "Gövde.")
        #expect(s.question == "Soru mu?")
    }

    private func stop(_ text: String) -> JarvisRequest {
        let t = SpeechText.stop(project: "p", lastAssistantText: text)
        return JarvisRequest(id: "i", sessionId: "s", project: "p", kind: .stop, speech: t.speech,
                             detail: t.displayText, risky: false, deadlineS: 150,
                             asksQuestion: t.asksQuestion, info: t.info)
    }

    @Test func panelForQuestionStopShowsWholeTextAndLastQuestion() {
        let p = SpeechSplit.panel(for: stop("Bunu mu istedin? Bitti.\nŞimdi push edeyim mi? Notlar aşağıda."))
        #expect(p.body == "Bunu mu istedin? Bitti.\nŞimdi push edeyim mi? Notlar aşağıda.")
        #expect(p.question == "Şimdi push edeyim mi?")
        #expect(p.detail == "") // a stop's detail is the body, never the monospace block
    }

    @Test func panelForReplyAndInfoStops() {
        let reply = SpeechSplit.panel(for: stop("Testler geçti."))
        #expect(reply.body == "Testler geçti.")
        #expect(reply.question == "Sırada ne var?")
        let info = SpeechSplit.panel(for: stop("Build hâlâ sürüyor."))
        #expect(info.body == "Build hâlâ sürüyor.")
        #expect(info.question == "Çalışıyor, bitince haber verecek.")
        let empty = SpeechSplit.panel(for: stop(""))
        #expect(empty.body == "p cevap verdi.")
        #expect(empty.question == "Sırada ne var?")
    }

    @Test func panelForPermissionKeepsDetail() {
        let r = JarvisRequest(id: "i", sessionId: "s", project: "p", kind: .permission,
                              speech: "p izin istiyor: şu komutu çalıştırmak: ls. Onaylıyor musun?",
                              detail: "ls", risky: false, deadlineS: 150, info: true)
        let p = SpeechSplit.panel(for: r)
        #expect(p.body == "p izin istiyor: şu komutu çalıştırmak: ls.")
        #expect(p.question == "Onaylıyor musun?")
        #expect(p.detail == "ls")
    }
}
