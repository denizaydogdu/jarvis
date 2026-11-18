import Foundation
import Testing
@testable import JarvisCore

private final class Box: @unchecked Sendable {
    var requests: [JarvisRequest] = []
    var logs: [String] = []
}

private func makeDeps(
    _ box: Box,
    response: JarvisResponse?,
    interactive: Bool = true,
    env: [String: String] = [:],
    excluded: [String] = ["~/Dev/bim"]
) -> HookDeps {
    HookDeps(
        send: { box.requests.append($0); return response },
        isInteractive: { interactive },
        excludedPrefixes: excluded,
        ofisFileContents: [],
        env: env,
        home: "/Users/test",
        log: { box.logs.append($0) },
        newId: { "req-1" }
    )
}

private func resp(_ status: ResponseStatus, _ intent: Intent, _ transcript: String? = "evet") -> JarvisResponse {
    JarvisResponse(id: "req-1", status: status, transcript: transcript, intent: intent)
}

private func input(cwd: String = "/tmp/proj", tool: String = "Bash", toolInput: String? = "{\"command\":\"ls\"}",
                   extra: String = "") -> Data {
    var s = "{\"session_id\":\"s1\",\"cwd\":\"\(cwd)\",\"tool_name\":\"\(tool)\""
    if let toolInput { s += ",\"tool_input\":\(toolInput)" }
    s += extra + "}"
    return Data(s.utf8)
}

private func parse(_ s: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
}

struct HookRunnerTests {
    @Test func permissionAllow() throws {
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(), deps: makeDeps(box, response: resp(.answered, .allow)))
        let obj = try parse(out)
        let hso = try #require(obj["hookSpecificOutput"] as? [String: Any])
        #expect(hso["hookEventName"] as? String == "PermissionRequest")
        let decision = try #require(hso["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "allow")
        #expect(box.requests.count == 1)
        #expect(box.requests[0].project == "proj")
        #expect(box.requests[0].deadlineS == 150)
        #expect(box.requests[0].id == "req-1")
        #expect(box.logs.contains("permission\tproj\tanswered\tallow\tevet"))
    }

    @Test func permissionDenyCarriesTranscript() throws {
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(),
                                 deps: makeDeps(box, response: resp(.answered, .deny, "hayır \"dur\"")))
        let obj = try parse(out)
        let decision = try #require((obj["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any])
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "Kullanıcı reddetti: hayır \"dur\"")
    }

    @Test func permissionUnclearYieldsEmpty() {
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(), deps: makeDeps(box, response: resp(.unclear, .none)))
        #expect(out == "")
    }

    @Test func stopProceedBlocksWithReason() throws {
        let box = Box()
        let out = HookRunner.run(event: .stop, stdin: input(tool: "x", toolInput: nil),
                                 deps: makeDeps(box, response: resp(.answered, .proceed, "devam et")))
        let obj = try parse(out)
        #expect(obj["decision"] as? String == "block")
        #expect(obj["reason"] as? String == "[Sesli talimat] devam et")
        #expect(box.requests.first?.kind == .stop)
    }

    @Test func stopNoneYieldsEmpty() {
        let box = Box()
        let out = HookRunner.run(event: .stop, stdin: input(), deps: makeDeps(box, response: resp(.answered, .none)))
        #expect(out == "")
    }

    @Test func handoffYieldsEmpty() {
        let box = Box()
        #expect(HookRunner.run(event: .permission, stdin: input(), deps: makeDeps(box, response: resp(.handoff, .none, nil))) == "")
        #expect(HookRunner.run(event: .stop, stdin: input(), deps: makeDeps(box, response: resp(.handoff, .none, nil))) == "")
    }

    @Test func unavailableYieldsEmptyAndLogs() {
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(), deps: makeDeps(box, response: nil))
        #expect(out == "")
        #expect(box.logs.contains("unavailable"))
    }

    @Test func garbageInputYieldsEmptyOutput() {
        for data in [Data("not json".utf8), Data(), Data("{\"cwd\":\"\"}".utf8), Data("{\"session_id\":\"a\"}".utf8)] {
            let box = Box()
            let out = HookRunner.run(event: .permission, stdin: data, deps: makeDeps(box, response: resp(.answered, .allow)))
            #expect(out == "")
            #expect(box.requests.isEmpty)
            #expect(box.logs.contains("error: bad input"))
        }
    }

    @Test func missingToolInputYieldsEmptyOutput() {
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(toolInput: nil), deps: makeDeps(box, response: resp(.unclear, .none)))
        #expect(out == "")
        #expect(box.requests.count == 1)
        #expect(box.requests[0].detail == "Bash")
    }

    @Test func excludedSessionNeverCallsSendAndLogsNoProject() {
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(cwd: "/Users/test/Dev/bim/order-service"),
                                 deps: makeDeps(box, response: resp(.answered, .allow)))
        #expect(out == "")
        #expect(box.requests.isEmpty)
        #expect(box.logs.contains("skipped: excluded"))
        #expect(!box.logs.joined().contains("order-service"))
    }

    @Test func excludedByTranscriptPathNeverCallsSend() {
        let box = Box()
        let extra = ",\"transcript_path\":\"/Users/test/.claude/projects/-Users-test-Dev-bim-order-service/x.jsonl\""
        let out = HookRunner.run(event: .stop, stdin: input(cwd: "/tmp/elsewhere", extra: extra),
                                 deps: makeDeps(box, response: resp(.answered, .proceed)))
        #expect(out == "")
        #expect(box.requests.isEmpty)
        #expect(box.logs == ["skipped: excluded"])
    }

    @Test func riskyFlagForwarded() {
        let box = Box()
        _ = HookRunner.run(event: .permission, stdin: input(toolInput: "{\"command\":\"git push\"}"),
                           deps: makeDeps(box, response: resp(.unclear, .none)))
        #expect(box.requests.first?.risky == true)
    }

    @Test func nonInteractiveSkips() {
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(), deps: makeDeps(box, response: resp(.answered, .allow), interactive: false))
        #expect(out == "")
        #expect(box.requests.isEmpty)
        #expect(box.logs.contains("skipped: nonInteractive"))
    }

    @Test func forceInteractiveEnvBypassesTtyOnly() {
        let box = Box()
        let env = ["JARVIS_FORCE_INTERACTIVE": "1"]
        _ = HookRunner.run(event: .permission, stdin: input(),
                           deps: makeDeps(box, response: resp(.unclear, .none), interactive: false, env: env))
        #expect(box.requests.count == 1)

        let box2 = Box()
        let out = HookRunner.run(event: .permission, stdin: input(cwd: "/Users/test/Dev/bim/x"),
                                 deps: makeDeps(box2, response: resp(.answered, .allow), interactive: false, env: env))
        #expect(out == "")
        #expect(box2.requests.isEmpty)
    }

    @Test func stopUsesTranscriptPath() throws {
        let path = try #require(Bundle.module.url(forResource: "transcript", withExtension: "jsonl", subdirectory: "Fixtures")).path
        let box = Box()
        _ = HookRunner.run(event: .stop, stdin: input(extra: ",\"transcript_path\":\"\(path)\""),
                           deps: makeDeps(box, response: resp(.timeout, .none, nil)))
        let speech = try #require(box.requests.first?.speech)
        #expect(speech.contains("Son cevap burada"))
        #expect(!speech.contains("Ilk cevap"))
    }

    @Test func stopQuestionSetsAsksQuestion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.jsonl").path
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Testler geçti.\n**Göndereyim mi?**"}]}}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let box = Box()
        let out = HookRunner.run(event: .stop, stdin: input(extra: ",\"transcript_path\":\"\(path)\""),
                                 deps: makeDeps(box, response: resp(.answered, .proceed, "Hayır")))
        let request = try #require(box.requests.first)
        #expect(request.asksQuestion == true)
        #expect(request.info == false)
        #expect(request.speech == "proj soruyor. Testler geçti. Göndereyim mi?")
        // The panel's full text travels in `detail` for stops.
        #expect(request.detail == "Testler geçti.\nGöndereyim mi?")
        let obj = try parse(out)
        #expect(obj["reason"] as? String == "[Sesli talimat] Hayır")
    }

    @Test func hookInfoStopNeverBlocks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.jsonl").path
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Yatakhane hâlâ yapılıyor, bitince haber vereceğim."}]}}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let box = Box()
        // Even an (impossible) proceed answer for an info stop must not block the turn.
        let out = HookRunner.run(event: .stop, stdin: input(extra: ",\"transcript_path\":\"\(path)\""),
                                 deps: makeDeps(box, response: resp(.answered, .proceed, "devam et")))
        let request = try #require(box.requests.first)
        #expect(request.info == true)
        #expect(request.asksQuestion == false)
        #expect(request.speech == "proj çalışıyor, bitince haber verecek. Yatakhane hâlâ yapılıyor, bitince haber vereceğim.")
        #expect(out == "")
    }

    @Test func worstCaseStopFitsTheWire() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 8000 characters of emoji (ZWJ families, 4-byte scalars) and control characters (\u0001 escapes
        // to 6 bytes), quotes and backslashes, then one 60 KB token and a question.
        // One "character" can be many bytes: a ZWJ family is 25 bytes, a mark-stacked letter more.
        let unit = "👨‍👩‍👧‍👦\u{01}👨‍👩‍👧‍👦\u{1F}e" + String(repeating: "\u{0303}", count: 40) + "\"\\"
        var body = ""
        while body.count < 8000 { body += unit }
        let text = body + "\n" + String(repeating: "ğ", count: 60 * 1024) + " " + body + " " + body + " mi?"
        let record: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": text]]]]
        let data = try JSONSerialization.data(withJSONObject: record)
        let path = dir.appendingPathComponent("t.jsonl").path
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let box = Box()
        _ = HookRunner.run(event: .stop, stdin: input(extra: ",\"transcript_path\":\"\(path)\""),
                           deps: makeDeps(box, response: resp(.timeout, .none, nil)))
        let request = try #require(box.requests.first)
        // The question lies beyond `SpeechText.inputCharLimit` and is ignored; only the size matters here.
        #expect(request.kind == .stop)
        #expect(try WireCodec.encodeLine(request).count < 64 * 1024)
    }

    @Test func oversizePermissionGoesToTheTerminal() {
        // Never shrink a permission: a truncated command must not be approvable by voice.
        let command = String(repeating: "\\u0001", count: 15_000) // JSON-escaped control chars in the command
        let box = Box()
        let out = HookRunner.run(event: .permission, stdin: input(toolInput: "{\"command\":\"\(command)\"}"),
                                 deps: makeDeps(box, response: resp(.answered, .allow)))
        #expect(out == "")
        #expect(box.requests.isEmpty)
        #expect(box.logs == ["skipped: too large"])
    }

    @Test func boundedForWireShrinksAnOversizedRequest() throws {
        let huge = String(repeating: "\u{01}", count: 40_000)
        let r = JarvisRequest(id: "1", sessionId: "s", project: "p", kind: .permission, speech: huge,
                              detail: huge, risky: false, deadlineS: 150).boundedForWire()
        #expect(try WireCodec.encodeLine(r).count < JarvisRequest.maxWireBytes)
        #expect(!r.speech.isEmpty)
    }

    @Test func hookFillsTtyFromClaudeRow() {
        let rows = [ProcessInfoRow(pid: 10, ppid: 9, tty: "ttys003", command: "/usr/bin/jarvis-hook"),
                    ProcessInfoRow(pid: 9, ppid: 1, tty: "ttys003", command: "/opt/homebrew/bin/claude")]
        for event in [HookEvent.permission, .stop] {
            let box = Box()
            var deps = makeDeps(box, response: resp(.timeout, .none, nil))
            deps.sessionTty = { ProcessTree.sessionTty(startPid: 10, rows: rows) }
            _ = HookRunner.run(event: event, stdin: input(), deps: deps)
            #expect(box.requests.map(\.tty) == ["/dev/ttys003"])
        }
        // Without a tty source the field stays empty (focus check then never applies).
        let box = Box()
        _ = HookRunner.run(event: .permission, stdin: input(), deps: makeDeps(box, response: resp(.timeout, .none, nil)))
        #expect(box.requests.map(\.tty) == [""])
    }

    @Test func permissionNeverAsksQuestion() {
        let box = Box()
        _ = HookRunner.run(event: .permission, stdin: input(), deps: makeDeps(box, response: resp(.timeout, .none, nil)))
        #expect(box.requests.first?.asksQuestion == false)
        #expect(box.requests.first?.info == false)
        #expect(box.requests.first?.detail == "ls")
    }

    @Test func logFileAppendsTimestampedLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = JarvisLog(path: dir.appendingPathComponent("j.log").path)
        log.append("one")
        log.append("two")
        let text = try String(contentsOfFile: dir.appendingPathComponent("j.log").path, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("\tone"))
        #expect(lines[0].contains("T"))
    }

    // MARK: - AskUserQuestion (`jarvis-hook ask`)

    static let askInput = #"{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}],"futureField":{"k":[1,true]}}"#
    static let twoQuestions = #"{"questions":[{"question":"A?","header":"","options":[{"label":"x"},{"label":"y"}]},{"question":"B?","header":"","options":[{"label":"1"},{"label":"2"},{"label":"3"}]}]}"#

    private func askResp(_ status: ResponseStatus, _ answers: [String]?) -> JarvisResponse {
        JarvisResponse(id: "req-1", status: status, transcript: nil, intent: .none, answers: answers)
    }

    private func ask(_ box: Box, _ toolInput: String = HookRunnerTests.askInput, response: JarvisResponse?,
                     cwd: String = "/tmp/proj", extra: String = "") -> String {
        HookRunner.run(event: .ask, stdin: input(cwd: cwd, tool: "AskUserQuestion", toolInput: toolInput, extra: extra),
                       deps: makeDeps(box, response: response))
    }

    @Test func askSendsAChoiceRequest() throws {
        let box = Box()
        _ = ask(box, response: askResp(.timeout, nil))
        let r = try #require(box.requests.first)
        #expect(r.kind == .choice)
        #expect(r.project == "proj")
        #expect(r.deadlineS == 150)
        #expect(r.choices == [ChoiceQuestion(question: "Which framework?", header: "Framework", options: [
            ChoiceOption(label: "React", description: "Component library"),
            ChoiceOption(label: "Vue", description: "Progressive framework"),
        ])])
        #expect(r.speech == "proj soruyor: Which framework? Seçenekler: 1, React; 2, Vue.")
        // PermissionRequest keeps skipping AskUserQuestion; the ask event is not blocked by that rule.
        #expect(!box.logs.contains("skipped: unsupportedTool"))
        #expect(box.logs == ["choice\tproj\ttimeout"])
    }

    @Test func askOutputEchoesQuestionsAndAddsAnswers() throws {
        let box = Box()
        let out = ask(box, response: askResp(.answered, ["React"]))
        // Exactly the documented shape: the original input echoed, plus `answers`.
        let expected = #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"questions":[{"question":"Which framework?","header":"Framework","options":[{"label":"React","description":"Component library"},{"label":"Vue","description":"Progressive framework"}],"multiSelect":false}],"answers":{"Which framework?":"React"},"futureField":{"k":[1,true]}}}}"#
        #expect(try parse(out) as NSDictionary == parse(expected) as NSDictionary)
        #expect(out.contains("\"multiSelect\":false"))
        #expect(out.contains("\"k\":[1,true]"))
        #expect(box.logs == ["choice\tproj\tanswered\tReact"])
    }

    @Test func askAnswersEveryQuestionInOrder() throws {
        let box = Box()
        let out = ask(box, Self.twoQuestions, response: askResp(.answered, ["y", "3"]))
        let hso = try #require(try parse(out)["hookSpecificOutput"] as? [String: Any])
        let updated = try #require(hso["updatedInput"] as? [String: Any])
        #expect(updated["answers"] as? [String: String] == ["A?": "y", "B?": "3"])
        #expect((updated["questions"] as? [Any])?.count == 2)
        #expect(box.logs == ["choice\tproj\tanswered\ty\t3"])
    }

    @Test func answersMustMatchLabelsExactly() {
        for answers in [["react"], ["React "], ["React!"], ["1"], [""]] {
            let box = Box()
            #expect(ask(box, response: askResp(.answered, answers)) == "", "\(answers)")
        }
        // A label of the other question does not answer this one.
        let box = Box()
        #expect(ask(box, Self.twoQuestions, response: askResp(.answered, ["1", "x"])) == "")
        #expect(box.logs.first == "choice\tproj\tanswered")
    }

    @Test func partialAnswersGiveNoOutput() {
        for answers: [String]? in [nil, [], ["x"], ["x", "1", "2"]] {
            let box = Box()
            #expect(ask(box, Self.twoQuestions, response: askResp(.answered, answers)) == "")
        }
        // Any status but answered gives no output, whatever answers it carries.
        for status in [ResponseStatus.timeout, .unclear, .handoff, .expired, .muted] {
            let box = Box()
            #expect(ask(box, Self.twoQuestions, response: askResp(status, ["x", "1"])) == "")
            #expect(box.logs == ["choice\tproj\t\(status.rawValue)"])
        }
        let box = Box()
        #expect(ask(box, response: nil) == "")
        #expect(box.logs == ["unavailable"])
    }

    @Test func unsupportedAskShapeGivesNoOutput() {
        let multi = #"{"questions":[{"question":"A?","options":[{"label":"x"},{"label":"y"}],"multiSelect":true}]}"#
        for toolInput in [multi, #"{"questions":[]}"#, "\"text\""] {
            let box = Box()
            #expect(ask(box, toolInput, response: askResp(.answered, ["x"])) == "")
            #expect(box.requests.isEmpty)
            #expect(box.logs == ["skipped: unsupported question"])
        }
        // Without a tool_input at all.
        let box = Box()
        #expect(HookRunner.run(event: .ask, stdin: input(tool: "AskUserQuestion", toolInput: nil),
                               deps: makeDeps(box, response: askResp(.answered, ["x"]))) == "")
        #expect(box.requests.isEmpty)
    }

    @Test func askForAnotherToolGivesNoOutput() {
        let box = Box()
        let out = HookRunner.run(event: .ask, stdin: input(tool: "Bash", toolInput: Self.askInput),
                                 deps: makeDeps(box, response: askResp(.answered, ["React"])))
        #expect(out == "")
        #expect(box.requests.isEmpty)
    }

    @Test func bimSessionAskIsSkipped() {
        let box = Box()
        #expect(ask(box, response: askResp(.answered, ["React"]), cwd: "/Users/test/Dev/bim/order-service") == "")
        #expect(box.requests.isEmpty)
        #expect(box.logs == ["skipped: excluded"])
        // By transcript path too, and OFIS and non-interactive sessions likewise.
        let byTranscript = Box()
        let extra = ",\"transcript_path\":\"/Users/test/.claude/projects/-Users-test-Dev-bim-x/t.jsonl\""
        #expect(ask(byTranscript, response: askResp(.answered, ["React"]), extra: extra) == "")
        #expect(byTranscript.logs == ["skipped: excluded"])
        let ofis = Box()
        #expect(HookRunner.run(event: .ask, stdin: input(tool: "AskUserQuestion", toolInput: Self.askInput),
                               deps: makeDeps(ofis, response: askResp(.answered, ["React"]), env: ["OFIS_OTURUMU": "1"])) == "")
        #expect(ofis.logs == ["skipped: ofis"])
        let headless = Box()
        #expect(HookRunner.run(event: .ask, stdin: input(tool: "AskUserQuestion", toolInput: Self.askInput),
                               deps: makeDeps(headless, response: askResp(.answered, ["React"]), interactive: false)) == "")
        #expect(headless.logs == ["skipped: nonInteractive"])
        #expect(ofis.requests.isEmpty && headless.requests.isEmpty && byTranscript.requests.isEmpty)
    }

    @Test func oversizeChoiceIsSkippedNeverTruncated() {
        let long = String(repeating: "\\u0001", count: 12_000)
        let toolInput = #"{"questions":[{"question":"Q?","options":[{"label":"a","description":"\#(long)"},{"label":"b"}]}]}"#
        let box = Box()
        #expect(ask(box, toolInput, response: askResp(.answered, ["a"])) == "")
        #expect(box.requests.isEmpty)
        #expect(box.logs == ["skipped: too large"])
    }
    // MARK: - v1.4: log hygiene

    @Test func loggedTranscriptHasNoLineBreaksOrTabs() {
        let box = Box()
        _ = HookRunner.run(event: .permission, stdin: input(),
                           deps: makeDeps(box, response: resp(.answered, .allow, "evet\ntamam\r\tolur")))
        #expect(box.logs == ["permission\tproj\tanswered\tallow\tevet tamam  olur"])
        let stopBox = Box()
        _ = HookRunner.run(event: .stop, stdin: input(tool: "x", toolInput: nil),
                           deps: makeDeps(stopBox, response: resp(.answered, .proceed, "a\rb\nc\td")))
        #expect(stopBox.logs == ["stop\tproj\tanswered\tcontinue\ta b c d"])
    }

    @Test func loggedLabelsHaveNoLineBreaksOrTabs() {
        let box = Box()
        let toolInput = #"{"questions":[{"question":"Q?","header":"","options":[{"label":"a\tb\rc\nd"},{"label":"e"}]}]}"#
        _ = ask(box, toolInput, response: askResp(.answered, ["a\tb\rc\nd"]))
        #expect(box.logs == ["choice\tproj\tanswered\ta b c d"])
    }

    @Test func logFieldReplacesLineBreaksAndTabs() {
        #expect(JarvisLog.field("a\nb\rc\td") == "a b c d")
        #expect(JarvisLog.field("a\r\nb") == "a  b")
        #expect(JarvisLog.field("düz metin") == "düz metin")
    }
}
