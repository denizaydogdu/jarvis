import Foundation
import Testing
@testable import JarvisCore

private func karar(note: String = "n1.md", options: [(String, String)] = [("A", "Birim testler"), ("B", "Uçtan uca")],
                   risk: String = "normal", riskNedeni: String = "", ekranOnayi: Bool = false,
                   iletildi: Bool = false) -> OfisKarar {
    OfisKarar(note: note, baslik: "Test yaklaşımı", proje: "blog", tur: "ceo-sorusu", soru: "Hangisini seçelim?",
              secenekler: options.map { OfisSecenek(kod: $0.0, metin: $0.1) }, risk: risk, riskNedeni: riskNedeni,
              ekranOnayiGerekir: ekranOnayi, soruldu: "2026-11-14T10:00", cevapIletildi: iletildi)
}

private func ask(_ k: OfisKarar = karar()) -> OfisAsk { OfisCards.ask(for: k)! }

private func heard(_ s: String) -> Heard { Heard(text: s, confidence: 0.9) }

private func answered(_ labels: [String]) -> JarvisResponse {
    JarvisResponse(id: "x", status: .answered, transcript: nil, intent: Intent.none, answers: labels)
}

private func status(_ s: ResponseStatus) -> JarvisResponse {
    JarvisResponse(id: "x", status: s, transcript: nil, intent: Intent.none)
}

@Suite struct OfisVoiceTests {
    let codes = ["A", "B"]
    let texts = ["Birim testler", "Uçtan uca"]

    @Test func optionTextPicks() {
        #expect(IntentParser.officeChoice(heard("birim testler"), codes: codes, texts: texts) == 0)
        #expect(IntentParser.officeChoice(heard("uçtan uca olsun"), codes: codes, texts: texts) == 1)
    }

    @Test func bareCodePicks() {
        #expect(IntentParser.officeChoice(heard("A"), codes: codes, texts: texts) == 0)
        #expect(IntentParser.officeChoice(heard("a şıkkı"), codes: codes, texts: texts) == 0)
        #expect(IntentParser.officeChoice(heard("B seçeneği"), codes: codes, texts: texts) == 1)
        #expect(IntentParser.officeChoice(heard("b seçeneği olsun lütfen"), codes: codes, texts: texts) == 1)
    }

    @Test func ordinalStillPicks() {
        #expect(IntentParser.officeChoice(heard("ikinci seçenek"), codes: codes, texts: texts) == 1)
    }

    @Test func codeAndTextMustAgree() {
        #expect(IntentParser.officeChoice(heard("A, birim testler"), codes: codes, texts: texts) == 0)
        #expect(IntentParser.officeChoice(heard("B, birim testler"), codes: codes, texts: texts) == nil)
        #expect(IntentParser.officeChoice(heard("a b"), codes: codes, texts: texts) == nil)
    }

    @Test func codeInsideTheOptionTextBelongsToTheText() {
        let texts = ["A planı", "B planı"]
        #expect(IntentParser.officeChoice(heard("A planı"), codes: codes, texts: texts) == 0)
        #expect(IntentParser.officeChoice(heard("B, A planı"), codes: codes, texts: texts) == nil)
    }

    @Test func denyWordsTerminalAndQuestionsNeverPick() {
        for s in ["A değil", "hayır A", "terminal", "A mı", "birim testler mi", "A şıkkı olmaz", "iptal"] {
            #expect(IntentParser.officeChoice(heard(s), codes: codes, texts: texts) == nil, "\(s)")
        }
    }

    @Test func otherWordsPickNothing() {
        for s in ["", "a bir dakika", "c", "A ama önce testleri çalıştır", "tamam"] {
            #expect(IntentParser.officeChoice(heard(s), codes: codes, texts: texts) == nil, "\(s)")
        }
    }

    @Test func askUsesOptionTextsAndCodes() {
        let a = ask()
        #expect(a.spokenPick(heard("uçtan uca")) == 1)
        #expect(a.spokenPick(heard("a şıkkı")) == 0)
        // The button label "A) Birim testler" is not what is matched: the option text alone is enough.
        #expect(a.spokenPick(heard("birim testler")) == 0)
    }

    @Test func yesNoAskPicksEvetByItsWord() {
        let a = ask(karar(options: []))
        #expect(a.spokenPick(heard("evet")) == 0)
        #expect(a.spokenPick(heard("a")) == nil)
    }

    /// R1: on a yes/no card a bare "hayır" (alone or with fillers) picks "Hayır", the safe direction.
    @Test func yesNoAskPicksHayirOnlyWhenBare() {
        let a = ask(karar(options: []))
        #expect(a.options[1].answer == "Hayır")
        for bare in ["hayır", "Hayır.", "HAYIR", "hayır lütfen", "bence hayır", "hayır olsun", "hayır, hayır"] {
            #expect(a.spokenPick(heard(bare)) == 1, "\(bare)")
        }
        for mixed in ["hayır evet", "evet hayır", "hayır tamam", "hayır mı", "hayır terminal", "hayır ama önce test et",
                      "iptal", "yok", "istemiyorum", "hayır değil", ""] {
            #expect(a.spokenPick(heard(mixed)) == nil, "\(mixed)")
        }
        #expect(IntentParser.bareNo(heard("hayır")))
        #expect(!IntentParser.bareNo(heard("hayır evet")))
    }

    @Test func hayirStillPicksNothingOnAChoiceCard() {
        let a = ask()
        #expect(a.spokenPick(heard("hayır")) == nil)
        #expect(a.spokenPick(heard("hayır lütfen")) == nil)
    }
}

@Suite struct OfisRequestTests {
    @Test func askBecomesAChoiceRequest() {
        let a = ask()
        let r = OfisCards.request(for: a, id: "ofis-1")
        #expect(r.id == "ofis-1")
        #expect(r.kind == .choice)
        #expect(r.project == "ofis")
        #expect(r.deadlineS == 150)
        #expect(r.speech == a.speech)
        #expect(r.choices == [a.question])
        #expect(r.tty == "")
        #expect(!r.isInfoStop)
        #expect(!OfisCards.isOfficeInfo(r))
    }

    /// R4: the menu's status display is an office info display with its own unique id.
    @Test func statusRequestIsAnOfficeInfo() {
        let r = OfisCards.statusRequest("Ofis durumu: …")
        #expect(r.isInfoStop)
        #expect(OfisCards.isOfficeInfo(r))
        #expect(r.detail == "Ofis durumu: …")
        #expect(OfisCards.statusRequest("x").id != OfisCards.statusRequest("x").id)
    }

    /// R3: office option buttons show their own "A) …" label, without the "1." number.
    @Test func officeOptionButtonsAreNotNumbered() {
        let r = OfisCards.request(for: ask(), id: "x")
        #expect(!OfisCards.numbersOptions(r))
        #expect(AnswerButton.optionText(0, label: "A) Birim testler", numbered: OfisCards.numbersOptions(r))
                == "A) Birim testler")
        let hook = JarvisRequest(id: "h", sessionId: "s", project: "p", kind: .choice, speech: "x", detail: "",
                                 risky: false, deadlineS: 150, choices: [ask().question])
        #expect(OfisCards.numbersOptions(hook))
        #expect(AnswerButton.optionText(1, label: "Vue", numbered: true) == "2. Vue")
    }

    @Test func infoRequestIsAnInfoStop() {
        let r = OfisCards.infoRequest("İletildi.", id: "ofis-2")
        #expect(r.isInfoStop)
        #expect(r.project == "ofis")
        #expect(r.speech == "İletildi.")
        #expect(r.detail == "İletildi.")
        #expect(OfisCards.isOfficeInfo(r))
    }

    @Test func buttonsAreOptionsThenKonusamamWithoutTerminal() {
        let r = OfisCards.request(for: ask(), id: "x")
        #expect(OfisCards.buttons(for: r) == [.option(0), .option(1), .notNow])
        #expect(AnswerButton.notNow.title == "Konuşamam")
        #expect(AnswerButton.cancel.title == "İptal")
    }

    @Test func panelTextAndConfirmQuestion() {
        let normal = ask()
        #expect(normal.panelBody == "blog — Test yaklaşımı")
        #expect(normal.panelQuestion == "Hangisini seçelim?")
        let risky = ask(karar(risk: "yuksek", riskNedeni: "zorla gönderme"))
        #expect(risky.panelBody == "blog — Test yaklaşımı\nYüksek risk: zorla gönderme")
        #expect(risky.confirmQuestion(forOption: 1) == "B) Uçtan uca — Onaylıyor musun?")
        #expect(risky.confirmQuestion(forOption: 9) == "Onaylıyor musun?")
    }
}

@Suite struct OfisPollPlanTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func asksNewAskableCardsInListOrder() {
        let plan = OfisPollPlan.make([karar(note: "a.md"), karar(note: "b.md")], seen: OfisSeen(), pending: [], now: now)
        #expect(plan.asks.map(\.note) == ["a.md", "b.md"])
        #expect(plan.skips.isEmpty)
    }

    @Test func pendingAskedSnoozedAndDuplicateNotesAreNotAskedAgain() {
        var seen = OfisSeen()
        seen.markAsked("asked.md", at: now)
        seen.snooze("snoozed.md", now: now)
        let list = [karar(note: "pending.md"), karar(note: "asked.md"), karar(note: "snoozed.md"),
                    karar(note: "new.md"), karar(note: "new.md")]
        let plan = OfisPollPlan.make(list, seen: seen, pending: ["pending.md"], now: now)
        #expect(plan.asks.map(\.note) == ["new.md"])
    }

    @Test func snoozeEndsAfterItsTime() {
        var seen = OfisSeen()
        seen.snooze("s.md", for: 600, now: now)
        #expect(OfisPollPlan.make([karar(note: "s.md")], seen: seen, pending: [], now: now + 599).asks.isEmpty)
        #expect(OfisPollPlan.make([karar(note: "s.md")], seen: seen, pending: [], now: now + 600).asks.count == 1)
    }

    @Test func unaskableCardsAreSkipsWithTheirReason() {
        let five = (0..<5).map { (String(UnicodeScalar(UInt8(65 + $0))), "x") }
        let plan = OfisPollPlan.make([karar(note: "many.md", options: five), karar(note: "on-way.md", iletildi: true)],
                                     seen: OfisSeen(), pending: [], now: now)
        #expect(plan.asks.isEmpty)
        #expect(plan.skips == [OfisPollPlan.Skip(note: "many.md", reason: "more than 4 options"),
                               OfisPollPlan.Skip(note: "on-way.md", reason: "answer already on its way")])
    }
}

@Suite struct OfisGateStateTests {
    @Test func intervalsPerError() {
        #expect(OfisGateState.ok.rawValue == "ok")
        #expect(OfisGateState.pollSeconds == 30)
        #expect(OfisGateState.after(OfisError.gateOff) == (.off, 300))
        #expect(OfisGateState.after(OfisError.unreachable) == (.unreachable, 120))
        #expect(OfisGateState.after(OfisError.badResponse(status: 500)) == (.error, 120))
        #expect(OfisGateState.after(OfisError.rpc(code: -32602)) == (.error, 120))
        #expect(OfisGateState.after(OfisError.rateLimited(retryAfter: 42)) == (.rateLimited, 42))
        #expect(OfisGateState.after(OfisError.rateLimited(retryAfter: 0.2)) == (.rateLimited, 1))
        #expect(OfisGateState.after(OfisError.unauthorized) == (.unauthorized, 300))
        #expect(OfisGateState.after(CancellationError()) == (.error, 120))
        #expect(OfisGateState.rateLimited.rawValue == "rate-limited")
    }
}

@Suite struct OfisOutcomeTests {
    let normal = ask()
    let risky = ask(karar(risk: "yuksek"))
    let confirmOnly = ask(karar(ekranOnayi: true))

    @Test func normalPickSendsTheCodeWithoutScreenConfirm() {
        #expect(OfisOutcome.decide(ask: normal, response: answered(["B) Uçtan uca"]), mark: nil)
                == .send(cevap: "B", ekranOnayi: false))
    }

    @Test func yesNoPickSendsTheWord() {
        let yn = ask(karar(options: []))
        #expect(OfisOutcome.decide(ask: yn, response: answered(["Hayır"]), mark: nil) == .send(cevap: "Hayır", ekranOnayi: false))
    }

    @Test func highRiskSendsOnlyAfterTheHold() {
        #expect(OfisOutcome.decide(ask: risky, response: answered(["A) Birim testler"]), mark: .confirmed)
                == .send(cevap: "A", ekranOnayi: true))
        #expect(OfisOutcome.decide(ask: confirmOnly, response: answered(["A) Birim testler"]), mark: .confirmed)
                == .send(cevap: "A", ekranOnayi: true))
        // A pick without the hold never sends.
        #expect(OfisOutcome.decide(ask: risky, response: answered(["A) Birim testler"]), mark: nil)
                == .snooze(OfisOutcome.unansweredSnooze))
    }

    @Test func notNowSendsNothingAndIsRetriedWithoutPerCardSnooze() {
        // Quiet mode covers it: the poller asks again once quiet mode has ended.
        for s in [ResponseStatus.expired, .handoff, .unclear, .answered] {
            #expect(OfisOutcome.decide(ask: normal, response: status(s), mark: .notNow) == .retry)
        }
        // Even a pick recorded before the press is never sent.
        #expect(OfisOutcome.decide(ask: normal, response: answered(["B) Uçtan uca"]), mark: .notNow) == .retry)
    }

    @Test func cancelSnoozesThirtyMinutes() {
        #expect(OfisOutcome.decide(ask: risky, response: status(.unclear), mark: .cancelled) == .snooze(30 * 60))
    }

    @Test func silenceUnclearHandoffSnoozeTenMinutes() {
        for s in [ResponseStatus.timeout, .unclear, .handoff] {
            #expect(OfisOutcome.decide(ask: normal, response: status(s), mark: nil) == .snooze(10 * 60))
        }
        #expect(OfisOutcome.unansweredSnooze == 600)
    }

    @Test func notShownIsRetriedWithoutSnooze() {
        #expect(OfisOutcome.decide(ask: normal, response: status(.expired), mark: nil) == .retry)
        #expect(OfisOutcome.decide(ask: normal, response: status(.handoff), mark: .withdrawn) == .retry)
    }

    @Test func unknownOrMalformedAnswersNeverSend() {
        #expect(OfisOutcome.decide(ask: normal, response: answered(["Uçtan uca"]), mark: nil) == .snooze(600))
        #expect(OfisOutcome.decide(ask: normal, response: answered(["A) Birim testler", "B) Uçtan uca"]), mark: nil)
                == .snooze(600))
        #expect(OfisOutcome.decide(ask: normal, response: answered([]), mark: nil) == .snooze(600))
    }
}

@Suite struct OfisReplyTests {
    let sonuc = OfisCevapSonucu(note: "n", cevap: "A) x", iletim: "delivered", zatenIletildi: false, kanal: "Jarvis üzerinden")

    @Test func deliveredSaysIletildi() {
        let r = OfisReply.classify(.success(sonuc), mayConfirm: false)
        #expect(r == .delivered)
        #expect(r.speech == "İletildi.")
        #expect(r.marksAsked)
        #expect(r.snooze == nil)
    }

    @Test func alreadyAnswered() {
        var again = sonuc
        again.zatenIletildi = true
        for result: Result<OfisCevapSonucu, Error> in [
            .success(again),
            .failure(OfisError.rejected(kod: "cevaplanmis", text: "")),
            .failure(OfisError.rejected(kod: "cevap-iletildi", text: "")),
        ] {
            let r = OfisReply.classify(result, mayConfirm: true)
            #expect(r == .alreadyAnswered)
            #expect(r.speech == "Bu karar zaten cevaplanmış.")
            #expect(r.marksAsked)
            #expect(r.snooze == nil)
        }
    }

    @Test func ceoUnreachableSaysSoAndSnoozes() {
        let r = OfisReply.classify(.failure(OfisError.failed(kod: "ceo-ulasilamiyor")), mayConfirm: false)
        #expect(r == .ceoUnreachable)
        #expect(r.speech == "CEO şu an ulaşılamıyor, sayfadan cevaplayabilirsin.")
        #expect(!r.marksAsked)
        #expect(r.snooze == OfisSeen.cancelSnooze)
    }

    @Test func inputRequiredContinuesOnlyAfterTheHold() {
        let e = OfisError.inputRequired(kod: "ekran_onayi_gerekir", text: "", taskId: "t1")
        #expect(OfisReply.classify(.failure(e), mayConfirm: true) == .needsScreenConfirm(taskId: "t1"))
        let r = OfisReply.classify(.failure(e), mayConfirm: false)
        #expect(r == .notDelivered(reason: e.description))
        #expect(r.speech == nil)
        #expect(!r.marksAsked)
        #expect(r.snooze == OfisOutcome.unansweredSnooze)
        // No task id to continue: not delivered.
        let noTask = OfisError.inputRequired(kod: "ekran_onayi_gerekir", text: "", taskId: "")
        #expect(OfisReply.classify(.failure(noTask), mayConfirm: true) == .notDelivered(reason: noTask.description))
    }

    @Test func otherErrorsAreNotDeliveredSilently() {
        for e in [OfisError.unreachable, .gateOff, .rejected(kod: "yok", text: "metin"), .failed(kod: "x"),
                  .rateLimited(retryAfter: 5), .invalidAnswer] {
            let r = OfisReply.classify(.failure(e), mayConfirm: true)
            #expect(r == .notDelivered(reason: e.description))
            #expect(r.speech == nil)
            #expect(r.snooze == OfisOutcome.unansweredSnooze)
        }
        #expect(OfisReply.classify(.failure(CancellationError()), mayConfirm: true) == .notDelivered(reason: "unexpected error"))
    }
}
