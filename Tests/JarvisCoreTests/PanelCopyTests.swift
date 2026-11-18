import Testing
@testable import JarvisCore

@Suite struct PanelCopyTests {
    @Test func choiceCopiesQuestionAndNumberedOptions() {
        let text = PanelCopy.text(body: "Soru 1/2 · Framework", question: " Which framework? ", detail: "",
                                  options: [ChoiceOption(label: "React", description: "Component library"),
                                            ChoiceOption(label: "Vue", description: "")],
                                  numberedOptions: true)
        #expect(text == "Soru 1/2 · Framework\n\nWhich framework?\n\n1) React — Component library\n2) Vue")
    }

    @Test func officeOptionsKeepTheirOwnLabels() {
        let text = PanelCopy.text(body: "", question: "Hangisi?", detail: "",
                                  options: [ChoiceOption(label: "A) Bir", description: "")], numberedOptions: false)
        #expect(text == "Hangisi?\n\nA) Bir")
    }

    @Test func stopQuestionAlreadyInBodyIsNotRepeated() {
        let text = PanelCopy.text(body: "Bitti. Testler geçti. Push edeyim mi?", question: "Push edeyim mi?",
                                  detail: "", options: [], numberedOptions: true)
        #expect(text == "Bitti. Testler geçti. Push edeyim mi?")
    }

    @Test func stopQuestionFollowedByMoreTextIsNotRepeated() {
        let text = PanelCopy.text(body: "Push edeyim mi? Sonra deploy ederim.", question: "Push edeyim mi?",
                                  detail: "", options: [], numberedOptions: true)
        #expect(text == "Push edeyim mi? Sonra deploy ederim.")
    }

    @Test func permissionCopiesQuestionAndDetail() {
        let text = PanelCopy.text(body: "", question: "Komutu çalıştırayım mı?", detail: "rm -rf build",
                                  options: [], numberedOptions: true)
        #expect(text == "Komutu çalıştırayım mı?\n\nrm -rf build")
    }

    @Test func emptyCardCopiesNothing() {
        #expect(PanelCopy.text(body: " ", question: "", detail: "", options: [], numberedOptions: true) == "")
    }
}
