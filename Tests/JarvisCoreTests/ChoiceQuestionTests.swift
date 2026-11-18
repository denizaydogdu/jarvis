import Foundation
import Testing
@testable import JarvisCore

private func toolInput(_ json: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private let docExample = #"{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}]}"#

private func choiceRequest(_ choices: [ChoiceQuestion]) -> JarvisRequest {
    JarvisRequest(id: "c", sessionId: "s", project: "p", kind: .choice, speech: "x", detail: "", risky: false,
                  deadlineS: 150, choices: choices)
}

@Suite struct ChoiceQuestionTests {
    @Test func parsesSingleSelectQuestions() throws {
        let qs = try #require(ChoiceQuestion.parse(toolInput: toolInput(docExample)))
        #expect(qs == [ChoiceQuestion(question: "Which framework?", header: "Framework", options: [
            ChoiceOption(label: "React", description: "Component library"),
            ChoiceOption(label: "Vue", description: "Progressive framework"),
        ])])
        // multiSelect and header/description may be absent; the question text is kept exactly.
        let two = #"{"questions":[{"question":" A? ","options":[{"label":"x"},{"label":"y"},{"label":"z"},{"label":"w"}]},{"question":"B?","header":"H","options":[{"label":"1"},{"label":"2"}],"multiSelect":false}]}"#
        let parsed = try #require(ChoiceQuestion.parse(toolInput: toolInput(two)))
        #expect(parsed.count == 2)
        #expect(parsed[0].question == " A? ")
        #expect(parsed[0].header == "")
        #expect(parsed[0].options.map(\.label) == ["x", "y", "z", "w"])
        #expect(parsed[0].options.allSatisfy { $0.description == "" })
    }

    @Test func rejectsMultiSelect() throws {
        let multi = #"{"questions":[{"question":"A?","options":[{"label":"x"},{"label":"y"}],"multiSelect":false},{"question":"B?","options":[{"label":"x"},{"label":"y"}],"multiSelect":true}]}"#
        #expect(ChoiceQuestion.parse(toolInput: try toolInput(multi)) == nil)
    }

    @Test func rejectsUnsupportedShapes() throws {
        let q = #"{"question":"Q?","options":[{"label":"a"},{"label":"b"}]}"#
        let bad = [
            #"{}"#,
            #"{"questions":[]}"#,
            #"{"questions":"x"}"#,
            // Five questions.
            #"{"questions":[\#(q),\#(q.replacingOccurrences(of: "Q?", with: "Q2?")),\#(q.replacingOccurrences(of: "Q?", with: "Q3?")),\#(q.replacingOccurrences(of: "Q?", with: "Q4?")),\#(q.replacingOccurrences(of: "Q?", with: "Q5?"))]}"#,
            // One option, five options, no options.
            #"{"questions":[{"question":"Q?","options":[{"label":"a"}]}]}"#,
            #"{"questions":[{"question":"Q?","options":[{"label":"a"},{"label":"b"},{"label":"c"},{"label":"d"},{"label":"e"}]}]}"#,
            #"{"questions":[{"question":"Q?","options":[]}]}"#,
            // Empty question or label, non-string label, non-boolean multiSelect.
            #"{"questions":[{"question":"  ","options":[{"label":"a"},{"label":"b"}]}]}"#,
            #"{"questions":[{"question":"Q?","options":[{"label":""},{"label":"b"}]}]}"#,
            #"{"questions":[{"question":"Q?","options":[{"label":1},{"label":"b"}]}]}"#,
            #"{"questions":[{"question":"Q?","options":[{"label":"a"},{"label":"b"}],"multiSelect":"no"}]}"#,
            // The same question twice (answers are keyed by question text) or the same label twice.
            #"{"questions":[\#(q),\#(q)]}"#,
            #"{"questions":[{"question":"Q?","options":[{"label":"a"},{"label":"a"}]}]}"#,
        ]
        for json in bad {
            #expect(ChoiceQuestion.parse(toolInput: try toolInput(json)) == nil, "\(json)")
        }
    }

    @Test func choiceSpeechListsLabelsNeverDescriptions() {
        let q = ChoiceQuestion(question: "Which framework?", header: "Framework", options: [
            ChoiceOption(label: "React", description: "Component library"),
            ChoiceOption(label: "Vue", description: "Progressive framework"),
        ])
        #expect(SpeechText.choice(project: "jarvis", question: q)
            == "jarvis soruyor: Which framework? Seçenekler: 1, React; 2, Vue.")
        let plain = ChoiceQuestion(question: "Hangisi", header: "", options: [
            ChoiceOption(label: "A", description: ""), ChoiceOption(label: "B", description: ""),
        ])
        #expect(SpeechText.choice(project: "p", question: plain) == "p soruyor: Hangisi. Seçenekler: 1, A; 2, B.")
    }

    @Test func choiceButtonsAreTheOptionsPlusKonusamamAndTerminal() {
        let r = choiceRequest([
            ChoiceQuestion(question: "A?", header: "", options: [ChoiceOption(label: "x", description: ""),
                                                                 ChoiceOption(label: "y", description: "")]),
            ChoiceQuestion(question: "B?", header: "", options: [ChoiceOption(label: "1", description: ""),
                                                                 ChoiceOption(label: "2", description: ""),
                                                                 ChoiceOption(label: "3", description: "")]),
        ])
        #expect(AnswerButton.buttons(for: r) == [.option(0), .option(1), .notNow, .terminal])
        #expect(AnswerButton.buttons(for: r, question: 1) == [.option(0), .option(1), .option(2), .notNow, .terminal])
        #expect(AnswerButton.buttons(for: r, question: 2) == [.notNow, .terminal])
        #expect(AnswerButton.buttons(for: choiceRequest([])) == [.notNow, .terminal])
    }

    @Test func choicePanelShowsCounterHeaderAndQuestion() {
        let q1 = ChoiceQuestion(question: "A?", header: "Kapsam", options: [])
        let q2 = ChoiceQuestion(question: "B?", header: "", options: [])
        let r = choiceRequest([q1, q2])
        #expect(SpeechSplit.choicePanel(for: r, question: 0) == ("Soru 1/2 · Kapsam", "A?"))
        #expect(SpeechSplit.choicePanel(for: r, question: 1) == ("Soru 2/2", "B?"))
        #expect(SpeechSplit.choicePanel(for: choiceRequest([q1]), question: 0) == ("Kapsam", "A?"))
    }

    @Test func focusedChoiceHandsOff() {
        #expect(FocusRule.decide(kind: .choice, info: false, frontmostIsTerminal: true,
                                 selectedTty: "/dev/ttys1", requestTty: "/dev/ttys1") == .skipHandoff)
    }
}
