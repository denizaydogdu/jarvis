import Foundation

public enum HookEvent: String, Sendable {
    /// `ask`: PreToolUse for AskUserQuestion (Claude's multiple-choice question).
    case permission, stop, ask
}

public struct HookDeps {
    public var send: (JarvisRequest) -> JarvisResponse?
    public var isInteractive: () -> Bool
    public var excludedPrefixes: [String]
    public var ofisFileContents: [String]
    public var env: [String: String]
    public var home: String
    public var log: (String) -> Void
    public var newId: () -> String
    /// Controlling terminal of the session's `claude` process ("/dev/ttysNNN"), "" when unknown.
    public var sessionTty: () -> String

    public init(
        send: @escaping (JarvisRequest) -> JarvisResponse?,
        isInteractive: @escaping () -> Bool,
        excludedPrefixes: [String],
        ofisFileContents: [String],
        env: [String: String],
        home: String,
        log: @escaping (String) -> Void,
        newId: @escaping () -> String,
        sessionTty: @escaping () -> String = { "" }
    ) {
        self.send = send
        self.isInteractive = isInteractive
        self.excludedPrefixes = excludedPrefixes
        self.ofisFileContents = ofisFileContents
        self.env = env
        self.home = home
        self.log = log
        self.newId = newId
        self.sessionTty = sessionTty
    }
}

public enum HookRunner {
    /// Returns the hook's stdout. An empty string means "no output" (the normal terminal flow continues).
    public static func run(event: HookEvent, stdin: Data, deps: HookDeps) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let sessionId = obj["session_id"] as? String, !sessionId.isEmpty,
              let cwd = obj["cwd"] as? String, !cwd.isEmpty else {
            deps.log("error: bad input")
            return ""
        }
        let toolName = obj["tool_name"] as? String
        let toolInput = obj["tool_input"] as? [String: Any] ?? [:]

        // Only PermissionRequest passes the tool name: AskUserQuestion stays unsupported there (never asked
        // twice), while the `.ask` event, which exists for that tool, is filtered like any session.
        let ctx = SessionContext(
            cwd: cwd, sessionId: sessionId, env: deps.env,
            toolName: event == .permission ? toolName : nil,
            transcriptPath: obj["transcript_path"] as? String
        )
        // nonInteractive is the last rule, so decide everything else first and walk the
        // process tree only when nothing else skipped the session.
        let forced = deps.env["JARVIS_FORCE_INTERACTIVE"] == "1"
        var reason = SessionFilter.skipReason(
            ctx, excludedPrefixes: deps.excludedPrefixes, ofisFileContents: deps.ofisFileContents,
            isInteractive: true, home: deps.home
        )
        if reason == nil, !forced, !deps.isInteractive() { reason = .nonInteractive }
        if let reason {
            deps.log("skipped: \(reason.rawValue)")
            return ""
        }

        let project = (cwd as NSString).lastPathComponent
        let request: JarvisRequest
        switch event {
        case .ask:
            return ask(obj: obj, toolName: toolName, sessionId: sessionId, cwd: cwd, deps: deps)
        case .permission:
            let call = ToolCall.from(toolName: toolName ?? "", toolInput: toolInput)
            let risky = RiskClassifier.isRisky(call, cwd: cwd)
            let texts = SpeechText.permission(project: project, call: call, risky: risky)
            // An empty detail (e.g. Bash without a command) falls back to the tool name.
            request = JarvisRequest(
                id: deps.newId(), sessionId: sessionId, project: project, kind: .permission,
                speech: texts.speech, detail: texts.detail.isEmpty ? call.name : texts.detail,
                risky: risky, deadlineS: 150, tty: deps.sessionTty()
            )
            // Never shrink a permission: a truncated command must not be approvable by voice.
            // Too large for the wire → the normal terminal prompt.
            let size = (try? WireCodec.encodeLine(request).count) ?? Int.max
            if size >= JarvisRequest.maxWireBytes {
                deps.log("skipped: too large")
                return ""
            }
        case .stop:
            let last = (obj["transcript_path"] as? String).flatMap { TranscriptReader.lastAssistantText(path: $0) }
            let texts = SpeechText.stop(project: project, lastAssistantText: last)
            // For a stop, `detail` carries the full cleaned text the panel shows.
            request = JarvisRequest(
                id: deps.newId(), sessionId: sessionId, project: project, kind: .stop,
                speech: texts.speech, detail: texts.displayText, risky: false, deadlineS: 150,
                asksQuestion: texts.asksQuestion, info: texts.info, tty: deps.sessionTty()
            ).boundedForWire()
        }
        guard let response = deps.send(request) else {
            deps.log("unavailable")
            return ""
        }

        var line = "\(request.kind.rawValue)\t\(JarvisLog.field(project))\t\(response.status.rawValue)\t\(response.intent.rawValue)"
        if response.status == .answered { line += "\t" + JarvisLog.field(response.transcript ?? "") }
        deps.log(line)

        guard response.status == .answered else { return "" }
        // Belt and braces: an info stop never blocks the turn, whatever the app answered.
        if request.isInfoStop { return "" }
        let transcript = response.transcript ?? ""
        let output: [String: Any]
        switch (event, response.intent) {
        case (.permission, .allow):
            output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                             "decision": ["behavior": "allow"]]]
        case (.permission, .deny):
            output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
                                             "decision": ["behavior": "deny",
                                                          "message": "Kullanıcı reddetti: \(transcript)"]]]
        case (.stop, .proceed):
            output = ["decision": "block", "reason": "[Sesli talimat] \(transcript)"]
        default:
            return ""
        }
        return serialized(output)
    }

    private static func serialized(_ output: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(output),
              let data = try? JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// AskUserQuestion via PreToolUse. Session filtering has already run (BIM first). Only a supported
    /// call is sent (see `ChoiceQuestion.parse`); anything else, and any answer that is not exactly one
    /// label per question, gives no output, so the normal dialog appears.
    private static func ask(obj: [String: Any], toolName: String?, sessionId: String, cwd: String,
                            deps: HookDeps) -> String {
        guard toolName == "AskUserQuestion",
              let original = obj["tool_input"] as? [String: Any],
              let questions = ChoiceQuestion.parse(toolInput: original) else {
            deps.log("skipped: unsupported question")
            return ""
        }
        let project = (cwd as NSString).lastPathComponent
        let request = JarvisRequest(
            id: deps.newId(), sessionId: sessionId, project: project, kind: .choice,
            speech: SpeechText.choice(project: project, question: questions[0]), detail: "",
            risky: false, deadlineS: 150, tty: deps.sessionTty(), choices: questions
        )
        // Like a permission, never shrink a choice: every option must reach the app whole.
        let size = (try? WireCodec.encodeLine(request).count) ?? Int.max
        if size >= JarvisRequest.maxWireBytes {
            deps.log("skipped: too large")
            return ""
        }
        guard let response = deps.send(request) else {
            deps.log("unavailable")
            return ""
        }

        let answers = response.status == .answered ? validAnswers(response.answers, for: questions) : nil
        var line = "choice\t\(JarvisLog.field(project))\t\(response.status.rawValue)"
        if let answers { line += answers.map { "\t" + JarvisLog.field($0) }.joined() }
        deps.log(line)
        guard let answers else {
            if response.status == .answered { deps.log("error: answers do not match the questions") }
            return ""
        }

        // `updatedInput` replaces the whole input: echo the original object, unknown fields included,
        // and add the answers keyed by each question's exact text.
        var updated = original
        updated["answers"] = Dictionary(zip(questions.map(\.question), answers), uniquingKeysWith: { first, _ in first })
        return serialized(["hookSpecificOutput": ["hookEventName": "PreToolUse",
                                                  "permissionDecision": "allow",
                                                  "updatedInput": updated]])
    }

    /// The answers when there is exactly one per question and each is exactly one of its labels.
    static func validAnswers(_ answers: [String]?, for questions: [ChoiceQuestion]) -> [String]? {
        guard let answers, answers.count == questions.count else { return nil }
        for (a, q) in zip(answers, questions) where !q.options.contains(where: { $0.label == a }) {
            return nil
        }
        return answers
    }
}
