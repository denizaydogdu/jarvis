import Testing
@testable import JarvisCore

struct IntentParserTests {
    static func p(_ t: String, risky: Bool = false) -> Decision {
        IntentParser.permission(Heard(text: t, confidence: 0.9), risky: risky)
    }
    static func s(_ t: String, _ c: Double = 0.9) -> Decision {
        IntentParser.stop(Heard(text: t, confidence: c))
    }
    static func d(_ st: ResponseStatus, _ i: Intent) -> Decision { Decision(status: st, intent: i) }

    @Test func normalizeTurkish() {
        #expect(IntentParser.normalize("İPTAL, Işık!") == ["iptal", "ışık"])
        #expect(IntentParser.normalize("  it's   ok ") == ["it", "s", "ok"])
    }

    @Test func permissionCases() {
        #expect(Self.p("EVET.") == Self.d(.answered, .allow))
        #expect(Self.p("Evet evet") == Self.d(.answered, .allow))
        #expect(Self.p("İPTAL") == Self.d(.answered, .deny))
        #expect(Self.p("hayır, önce testleri çalıştır") == Self.d(.answered, .deny))
        #expect(Self.p("hayır evet") == Self.d(.unclear, Intent.none))
        #expect(Self.p("önce testleri çalıştır") == Self.d(.unclear, Intent.none))
        #expect(Self.p("izin ver") == Self.d(.answered, .allow))
        #expect(Self.p("evet", risky: true) == Self.d(.unclear, Intent.none))
        #expect(Self.p("Onaylıyorum", risky: true) == Self.d(.answered, .allow))
        #expect(Self.p("") == Self.d(.timeout, Intent.none))
        #expect(Self.p("terminal") == Self.d(.handoff, Intent.none))
        #expect(Self.p("durum nedir") == Self.d(.unclear, Intent.none))
    }

    @Test func stopCases() {
        #expect(Self.s("Bu kadar.") == Self.d(.answered, Intent.none))
        #expect(Self.s("testleri de yaz", 0.8) == Self.d(.answered, .proceed))
        #expect(Self.s("testleri de yaz", 0.3) == Self.d(.unclear, Intent.none))
        #expect(Self.s("devam", 0.9) == Self.d(.unclear, Intent.none))
        #expect(Self.s("Terminal") == Self.d(.handoff, Intent.none))
        #expect(Self.s("") == Self.d(.timeout, Intent.none))
    }

    static func q(_ t: String, _ c: Double = 0.9) -> Decision {
        IntentParser.stop(Heard(text: t, confidence: c), asksQuestion: true)
    }

    @Test func stopQuestionCases() {
        // One clear class (all allow or all deny) after de-duplication → proceed, at any confidence.
        for t in ["evet", "Hayır.", "hayır", "tamam", "olur", "evet evet", "hayır dur"] {
            #expect(Self.q(t, 0.2) == Self.d(.answered, .proceed))
        }
        // Without a question, "tamam" stays done and a lone "evet" is unclear.
        #expect(Self.s("tamam") == Self.d(.answered, Intent.none))
        #expect(Self.s("evet") == Self.d(.unclear, Intent.none))
        // Other speech on a question follows the stop rules.
        #expect(Self.q("yok") == Self.d(.answered, Intent.none))
        #expect(Self.q("tamam bu kadar") == Self.d(.answered, Intent.none))
        #expect(Self.q("önce testleri yaz", 0.8) == Self.d(.answered, .proceed))
        #expect(Self.q("önce testleri yaz", 0.3) == Self.d(.unclear, Intent.none))
        #expect(Self.q("evet ama önce testleri yaz", 0.3) == Self.d(.unclear, Intent.none))
        #expect(Self.q("devam") == Self.d(.unclear, Intent.none))
        #expect(Self.q("terminal") == Self.d(.handoff, Intent.none))
        #expect(Self.q("") == Self.d(.timeout, Intent.none))
    }

    @Test func stopQuestionMixedOrQuestioningAnswersAreUnclear() {
        for t in ["evet hayır", "hayır evet", "tamam olmaz", "tamam mı", "olur mu", "evet mi", "hayır mı"] {
            #expect(Self.q(t) == Self.d(.unclear, Intent.none))
        }
        // An allow or deny word next to another word is not a clear answer; the stop rules decide.
        #expect(Self.q("evet lütfen", 0.2) == Self.d(.unclear, Intent.none))
        #expect(Self.q("evet lütfen", 0.8) == Self.d(.answered, .proceed))
    }

    @Test func normalizeSplitsOnPunctuation() {
        #expect(IntentParser.normalize("evet,hayır") == ["evet", "hayır"])
        #expect(IntentParser.normalize("bu-kadar") == ["bu", "kadar"])
    }

    @Test func permissionSafetyCases() {
        #expect(Self.p("hayır", risky: true) == Self.d(.answered, .deny))
        #expect(Self.p("izin ver", risky: true) == Self.d(.unclear, Intent.none))
        #expect(Self.p("hayır onaylıyorum", risky: true) == Self.d(.unclear, Intent.none))
        #expect(Self.p("izin bence ver") == Self.d(.unclear, Intent.none))
        #expect(Self.p("evet ama yapma") == Self.d(.unclear, Intent.none))
        #expect(Self.p("tamam değil") == Self.d(.unclear, Intent.none))
        #expect(Self.p("olmaz") == Self.d(.answered, .deny))
        #expect(Self.p("istemiyorum") == Self.d(.answered, .deny))
        #expect(Self.p("vazgeç") == Self.d(.answered, .deny))
        #expect(Self.p("olur mu") == Self.d(.unclear, Intent.none))
        #expect(Self.p("evet mi") == Self.d(.unclear, Intent.none))
        #expect(Self.p("terminal mi") == Self.d(.handoff, Intent.none))
        #expect(Self.p("   ") == Self.d(.timeout, Intent.none))
    }

    @Test func stopExtraCases() {
        for t in ["yok", "tamam", "yok teşekkürler", "tamam bu kadar"] {
            #expect(Self.s(t) == Self.d(.answered, Intent.none))
        }
        #expect(Self.s("testleri de yaz", 0.5) == Self.d(.answered, .proceed))
        #expect(Self.s("   ") == Self.d(.timeout, Intent.none))
    }

    // I3: allow needs a reply made only of allow words (at most 3 after de-duplication).
    @Test func permissionAllowOnlyWhenEveryTokenIsAllow() {
        for t in ["evet", "evet evet", "izin ver", "tamam olur", "Evet, izin ver", "evet evet evet evet"] {
            #expect(Self.p(t) == Self.d(.answered, .allow), "\(t)")
        }
        for t in ["evet ama önce testleri çalıştır", "tamam tamam görüşürüz", "evet lütfen", "tamam evet olur izin ver",
                  "ver izin", "izin"] {
            #expect(Self.p(t) == Self.d(.unclear, Intent.none), "\(t)")
        }
    }

    @Test func riskyAllowOnlyWithBareOnayliyorum() {
        #expect(Self.p("onaylıyorum onaylıyorum", risky: true) == Self.d(.answered, .allow))
        #expect(Self.p("onaylıyorum ama önce test et", risky: true) == Self.d(.unclear, Intent.none))
        #expect(Self.p("evet onaylıyorum", risky: true) == Self.d(.unclear, Intent.none))
        // Deny rules are unchanged.
        #expect(Self.p("hayır, önce testleri çalıştır", risky: true) == Self.d(.answered, .deny))
    }

    // I4: only a final recognition result carries a real confidence; partial-only text gets 0.
    @Test func recognizedConfidence() {
        #expect(Heard.recognized(text: "  testleri yaz ", confidences: [0.5, 1.0], isFinal: true)
                == Heard(text: "testleri yaz", confidence: 0.75))
        #expect(Heard.recognized(text: "testleri yaz", confidences: [0, 0], isFinal: false)
                == Heard(text: "testleri yaz", confidence: 0))
        #expect(Heard.recognized(text: "testleri yaz", confidences: [0.9], isFinal: false).confidence == 0)
        #expect(Heard.recognized(text: "testleri yaz", confidences: [], isFinal: true).confidence == 0)
        #expect(Heard.recognized(text: "   ", confidences: [0.9], isFinal: true) == Heard(text: "", confidence: 0))
        // Partial-only text no longer passes the stop gate, but a yes/no to a question still answers.
        let partial = Heard.recognized(text: "testleri de yaz", confidences: [0, 0, 0], isFinal: false)
        #expect(IntentParser.stop(partial) == Self.d(.unclear, Intent.none))
        let yes = Heard.recognized(text: "evet", confidences: [0], isFinal: false)
        #expect(IntentParser.stop(yes, asksQuestion: true) == Self.d(.answered, .proceed))
        #expect(IntentParser.permission(yes, risky: false) == Self.d(.answered, .allow))
    }

    static func c(_ t: String, _ options: [String]) -> Int? {
        IntentParser.choice(Heard(text: t, confidence: 0.9), options: options)
    }

    @Test func choiceVoiceByNumber() {
        let four = ["Hızlı yol", "Güvenli yol", "Testleri önce yaz", "Bekle"]
        #expect(Self.c("bir", four) == 0)
        #expect(Self.c("Birinci.", four) == 0)
        #expect(Self.c("ilk", four) == 0)
        #expect(Self.c("1", four) == 0)
        #expect(Self.c("iki", four) == 1)
        #expect(Self.c("ikinci seçenek", four) == 1)
        #expect(Self.c("ikinciyi seç", four) == 1)
        #expect(Self.c("2", four) == 1)
        #expect(Self.c("Üç", four) == 2)
        #expect(Self.c("üçüncü", four) == 2)
        #expect(Self.c("dört", four) == 3)
        #expect(Self.c("dördüncü olsun", four) == 3)
        #expect(Self.c("son", four) == 3)
        #expect(Self.c("sonuncu", four) == 3)
        #expect(Self.c("son", ["a", "b"]) == 1)
        // A number beyond the options picks nothing.
        #expect(Self.c("üçüncü", ["a", "b"]) == nil)
        #expect(Self.c("dört", ["a", "b", "c"]) == nil)
        // The same number twice is still one pick.
        #expect(Self.c("iki, ikinci", four) == 1)
    }

    @Test func choiceVoiceByLabel() {
        let options = ["React", "Vue", "Svelte Kit"]
        #expect(Self.c("React", options) == 0)
        #expect(Self.c("vue olsun", options) == 1)
        #expect(Self.c("SVELTE kit lütfen", options) == 2)
        // Every label token must be heard.
        #expect(Self.c("svelte", options) == nil)
        // Turkish casing: İ → i.
        #expect(Self.c("İLERİ", ["ileri", "geri"]) == 0)
        // A number word inside the matched label is part of the label, not a second pick.
        #expect(Self.c("son sürüm", ["Eski sürüm", "Son sürüm", "Hiçbiri"]) == 1)
        // Label and number naming the same option agree.
        #expect(Self.c("ikinci, vue", options) == 1)
    }

    @Test func choiceVoiceAmbiguousIsUnclear() {
        let options = ["React", "Vue", "Svelte"]
        #expect(Self.c("", options) == nil)
        // Two options named, or a label and a different number.
        #expect(Self.c("react ya da vue", options) == nil)
        #expect(Self.c("birinci vue", options) == nil)
        #expect(Self.c("bir iki", options) == nil)
        // A label contained in another: both match, so neither is picked.
        #expect(Self.c("react native", ["React", "React Native"]) == nil)
        // Nothing recognisable.
        #expect(Self.c("bilmiyorum", options) == nil)
        // A number word inside ordinary speech is not a pick.
        #expect(Self.c("bir dakika bekle", options) == nil)
        // Deny words, questioning and "terminal" never pick an option.
        #expect(Self.c("hayır react", options) == nil)
        #expect(Self.c("iptal", options) == nil)
        #expect(Self.c("vazgeç ikinci", options) == nil)
        #expect(Self.c("react istemiyorum", options) == nil)
        #expect(Self.c("ikinci mi", options) == nil)
        #expect(Self.c("terminal", options) == nil)
        #expect(Self.c("react", []) == nil)
    }

    @Test func choiceUnansweredClassifiesTheFailure() {
        func u(_ t: String) -> Decision { IntentParser.choiceUnanswered(Heard(text: t, confidence: 0.9)) }
        #expect(u("") == Self.d(.timeout, Intent.none))
        #expect(u("Terminal.") == Self.d(.handoff, Intent.none))
        #expect(u("bilmiyorum") == Self.d(.unclear, Intent.none))
        #expect(u("hayır") == Self.d(.unclear, Intent.none))
    }

    // Fix round 1: a pick needs filler-only context, so a negated or qualified label picks nothing.
    @Test func choiceVoiceNeedsFillerOnlyContext() {
        let options = ["React", "Vue", "Svelte"]
        #expect(Self.c("react'i seçme", options) == nil)
        #expect(Self.c("react olmasın", options) == nil)
        #expect(Self.c("vue'yu istemem", options) == nil)
        #expect(Self.c("react seçmeyelim", options) == nil)
        #expect(Self.c("bence react", options) == 0)
        #expect(Self.c("vue olsun", options) == 1)
        #expect(Self.c("ikinci, vue", options) == 1)
        #expect(Self.c("ikinci, react", options) == nil)
        // Apostrophe suffixes are fillers: "Vue'yu seç" picks Vue.
        #expect(Self.c("Vue'yu seç", options) == 1)
        #expect(Self.c("şu react", options) == 0)
        #expect(Self.c("react ama önce test", options) == nil)
    }

    @Test func bareBirCountsOnlyAlone() {
        let options = ["React", "Vue", "Svelte"]
        #expect(Self.c("bir", options) == 0)
        #expect(Self.c("bir tane", options) == nil)
        #expect(Self.c("bir seçenek seç", options) == nil)
        #expect(Self.c("birinci seçenek", options) == 0)
        #expect(Self.c("ilk seçenek olsun", options) == 0)
    }
}
