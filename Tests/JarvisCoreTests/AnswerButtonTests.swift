import Testing
@testable import JarvisCore

private func req(kind: RequestKind, risky: Bool = false, asksQuestion: Bool = false, info: Bool = false) -> JarvisRequest {
    JarvisRequest(id: "i", sessionId: "s", project: "p", kind: kind, speech: "x", detail: "d", risky: risky,
                  deadlineS: 120, asksQuestion: asksQuestion, info: info)
}

@Suite struct AnswerButtonTests {
    @Test func buttonsForPermission() {
        #expect(AnswerButton.buttons(for: req(kind: .permission)) == [.yes, .no, .notNow, .terminal])
    }

    @Test func buttonsForRiskyPermission() {
        #expect(AnswerButton.buttons(for: req(kind: .permission, risky: true)) == [.confirm, .no, .notNow, .terminal])
    }

    @Test func buttonsForStop() {
        #expect(AnswerButton.buttons(for: req(kind: .stop)) == [.done, .notNow, .terminal])
    }

    @Test func buttonsForStopQuestion() {
        #expect(AnswerButton.buttons(for: req(kind: .stop, asksQuestion: true)) == [.yes, .no, .notNow, .terminal])
    }

    @Test func questionFlagDoesNotChangePermissionButtons() {
        #expect(AnswerButton.buttons(for: req(kind: .permission, risky: true, asksQuestion: true)) == [.confirm, .no, .notNow, .terminal])
    }

    @Test func infoButtonsAreOkOnly() {
        #expect(AnswerButton.buttons(for: req(kind: .stop, info: true)) == [.ok])
        #expect(AnswerButton.ok.title == "Tamam")
        // A question always wins over info; info never changes permission buttons.
        #expect(AnswerButton.buttons(for: req(kind: .stop, asksQuestion: true, info: true)) == [.yes, .no, .notNow, .terminal])
        #expect(AnswerButton.buttons(for: req(kind: .permission, info: true)) == [.yes, .no, .notNow, .terminal])
    }

    @Test func confirmRequiresHold() {
        #expect(AnswerButton.fixedButtons.filter(\.requiresHold) == [.confirm])
    }

    @Test func titles() {
        #expect(AnswerButton.fixedButtons.map(\.title) == ["Evet", "Onaylıyorum", "Hayır", "Terminal", "Yok, bitti", "Tamam", "Konuşamam", "İptal"])
        #expect(AnswerButton.notNow.logName == "notnow")
        #expect(!AnswerButton.notNow.requiresHold)
    }

    @Test func optionButtonsAreNotAmongTheFixedButtons() {
        #expect(!AnswerButton.fixedButtons.contains(.option(0)))
        #expect(!AnswerButton.option(1).requiresHold)
        #expect(AnswerButton.option(1).logName == "option2")
        #expect(AnswerButton.terminal.logName == "terminal")
    }
}
