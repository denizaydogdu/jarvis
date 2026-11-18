import Foundation
import Testing
@testable import JarvisCore

struct ChoiceTimingTests {
    private func q(_ text: String, _ labels: [String]) -> ChoiceQuestion {
        ChoiceQuestion(question: text, header: "", options: labels.map { ChoiceOption(label: $0, description: "") })
    }

    private func choice(_ questions: [ChoiceQuestion], project: String = "p") -> JarvisRequest {
        JarvisRequest(id: "c", sessionId: "s", project: project, kind: .choice, speech: "", detail: "",
                      risky: false, deadlineS: 150, choices: questions)
    }

    @Test func estimateIsSpokenCharactersPlusListeningPerQuestion() {
        // "p soruyor: A? Seçenekler: 1, x; 2, y." is 37 characters.
        let one = choice([q("A?", ["x", "y"])])
        #expect(abs(ChoiceTiming.estimatedSeconds(for: one) - (37 * 0.12 + 20)) < 1e-9)
        let questions = [q("A?", ["x", "y"]), q("Hangisi olsun?", ["React", "Vue", "Svelte"])]
        let chars = questions.reduce(0) { $0 + SpeechText.choice(project: "p", question: $1).count }
        #expect(abs(ChoiceTiming.estimatedSeconds(for: choice(questions)) - (Double(chars) * 0.12 + 40)) < 1e-9)
    }

    @Test func onlyAChoiceHasAnEstimate() {
        let permission = JarvisRequest(id: "x", sessionId: "s", project: "p", kind: .permission, speech: "uzun",
                                       detail: "", risky: false, deadlineS: 150)
        #expect(ChoiceTiming.estimatedSeconds(for: permission) == 0)
        #expect(!ChoiceTiming.asksSilently(permission, capSeconds: 0))
    }

    @Test func longChoiceIsAskedSilently() {
        let label = String(repeating: "uzun seçenek ", count: 6)
        let long = choice((1...4).map { q("Soru \($0) için hangisini seçeyim?", (1...4).map { "\($0) \(label)" }) })
        #expect(ChoiceTiming.estimatedSeconds(for: long) > 110)
        #expect(ChoiceTiming.asksSilently(long, capSeconds: 110))
        let short = choice([q("A?", ["x", "y"])])
        #expect(!ChoiceTiming.asksSilently(short, capSeconds: 110))
        // The comparison is against what is left of the cap, not the 110 s constant.
        #expect(ChoiceTiming.asksSilently(short, capSeconds: 20))
        // Exactly at the cap still speaks: only "more than" goes silent.
        #expect(!ChoiceTiming.asksSilently(short, capSeconds: ChoiceTiming.estimatedSeconds(for: short)))
    }
}
