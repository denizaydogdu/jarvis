import Foundation
import Testing
@testable import JarvisCore

@Suite struct ProtocolTests {
    private func sampleRequest(detail: String = "rm -rf build") -> JarvisRequest {
        JarvisRequest(id: "1", sessionId: "s1", project: "jarvis", kind: .permission,
                      speech: "Onay?", detail: detail, risky: true, deadlineS: 150)
    }

    @Test func requestRoundTripUsesSnakeCaseKeys() throws {
        let req = sampleRequest()
        let data = try WireCodec.encodeLine(req)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"session_id\""))
        #expect(json.contains("\"deadline_s\""))
        #expect(try WireCodec.decodeLine(data, as: JarvisRequest.self) == req)
    }

    @Test func asksQuestionRoundTripsAndIsAlwaysEncoded() throws {
        var req = sampleRequest()
        req.asksQuestion = true
        let data = try WireCodec.encodeLine(req)
        #expect(String(decoding: data, as: UTF8.self).contains("\"asks_question\":true"))
        #expect(try WireCodec.decodeLine(data, as: JarvisRequest.self) == req)
        let plain = String(decoding: try WireCodec.encodeLine(sampleRequest()), as: UTF8.self)
        #expect(plain.contains("\"asks_question\":false"))
    }

    @Test func decodesRequestWithoutAsksQuestion() throws {
        let line = #"{"id":"1","session_id":"s1","project":"p","kind":"stop","speech":"x","detail":"","risky":false,"deadline_s":150}"#
        let r = try WireCodec.decodeLine(Data(line.utf8), as: JarvisRequest.self)
        #expect(r.asksQuestion == false)
        #expect(r.kind == .stop)
        #expect(r.deadlineS == 150)
    }

    @Test func decodesRequestWithoutInfo() throws {
        let line = #"{"id":"1","session_id":"s1","project":"p","kind":"stop","speech":"x","detail":"","risky":false,"deadline_s":150,"asks_question":false}"#
        let r = try WireCodec.decodeLine(Data(line.utf8), as: JarvisRequest.self)
        #expect(r.info == false)
        var info = r
        info.info = true
        let data = try WireCodec.encodeLine(info)
        #expect(String(decoding: data, as: UTF8.self).contains("\"info\":true"))
        #expect(try WireCodec.decodeLine(data, as: JarvisRequest.self) == info)
    }

    @Test func requestCarriesTty() throws {
        var req = sampleRequest()
        #expect(req.tty == "")
        req.tty = "/dev/ttys003"
        let data = try WireCodec.encodeLine(req)
        #expect(String(decoding: data, as: UTF8.self).contains("\"tty\":\"/dev/ttys003\""))
        #expect(try WireCodec.decodeLine(data, as: JarvisRequest.self) == req)
    }

    @Test func decodesRequestWithoutTty() throws {
        let line = #"{"id":"1","session_id":"s1","project":"p","kind":"permission","speech":"x","detail":"","risky":false,"deadline_s":150,"asks_question":false,"info":false}"#
        let r = try WireCodec.decodeLine(Data(line.utf8), as: JarvisRequest.self)
        #expect(r.tty == "")
        #expect(r.kind == .permission)
    }

    @Test func responseContinueIntentEncodesAsContinue() throws {
        let resp = JarvisResponse(id: "1", status: .answered, transcript: "testleri çalıştır", intent: .proceed)
        let json = String(decoding: try WireCodec.encodeLine(resp), as: UTF8.self)
        #expect(json.contains("\"intent\":\"continue\""))
    }

    @Test func encodeLineEndsWithSingleNewline() throws {
        let data = try WireCodec.encodeLine(sampleRequest(detail: "a\nb"))
        #expect(data.filter { $0 == 0x0A }.count == 1)
        #expect(data.last == 0x0A)
    }

    @Test func decodesOldRequestWithoutChoices() throws {
        let line = #"{"id":"1","session_id":"s1","project":"p","kind":"permission","speech":"x","detail":"","risky":false,"deadline_s":150,"asks_question":false,"info":false,"tty":""}"#
        let r = try WireCodec.decodeLine(Data(line.utf8), as: JarvisRequest.self)
        #expect(r.choices == [])
        #expect(r.kind == .permission)
    }

    @Test func choiceRequestRoundTrips() throws {
        let q = ChoiceQuestion(question: "Which?", header: "H", options: [
            ChoiceOption(label: "A", description: "first"), ChoiceOption(label: "B", description: ""),
        ])
        let req = JarvisRequest(id: "1", sessionId: "s", project: "p", kind: .choice, speech: "x", detail: "",
                                risky: false, deadlineS: 150, choices: [q])
        let data = try WireCodec.encodeLine(req)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"kind\":\"choice\""))
        #expect(json.contains("\"choices\":[{"))
        #expect(try WireCodec.decodeLine(data, as: JarvisRequest.self) == req)
    }

    @Test func responseAnswersAreOptionalOnTheWire() throws {
        let old = #"{"id":"1","status":"answered","transcript":"evet","intent":"allow"}"#
        let r = try WireCodec.decodeLine(Data(old.utf8), as: JarvisResponse.self)
        #expect(r.answers == nil)
        #expect(!String(decoding: try WireCodec.encodeLine(r), as: UTF8.self).contains("answers"))
        let withAnswers = JarvisResponse(id: "1", status: .answered, transcript: nil, intent: .none, answers: ["A", "B"])
        let data = try WireCodec.encodeLine(withAnswers)
        #expect(String(decoding: data, as: UTF8.self).contains("\"answers\":[\"A\",\"B\"]"))
        #expect(try WireCodec.decodeLine(data, as: JarvisResponse.self) == withAnswers)
    }
}
