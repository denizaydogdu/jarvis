import Foundation

public enum RequestKind: String, Codable, Sendable {
    /// `choice`: Claude's multiple-choice question (AskUserQuestion), answered with one option per question.
    case permission, stop, choice
}

public struct JarvisRequest: Codable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var project: String
    public var kind: RequestKind
    public var speech: String
    public var detail: String
    public var risky: Bool
    public var deadlineS: Int
    public var asksQuestion: Bool
    /// A stop whose reply says the session is still working: spoken, never listened to, never blocks.
    public var info: Bool
    /// Controlling terminal of the session's `claude` process, e.g. "/dev/ttys003"; "" when unknown.
    public var tty: String
    /// The questions of a `.choice` request, in order; empty for every other kind.
    public var choices: [ChoiceQuestion]

    public init(id: String, sessionId: String, project: String, kind: RequestKind,
                speech: String, detail: String, risky: Bool, deadlineS: Int, asksQuestion: Bool = false,
                info: Bool = false, tty: String = "", choices: [ChoiceQuestion] = []) {
        self.id = id
        self.sessionId = sessionId
        self.project = project
        self.kind = kind
        self.speech = speech
        self.detail = detail
        self.risky = risky
        self.deadlineS = deadlineS
        self.asksQuestion = asksQuestion
        self.info = info
        self.tty = tty
        self.choices = choices
    }

    /// The socket server drops request lines over 64 KB; requests are kept below this, with margin.
    public static let maxWireBytes = 60 * 1024

    /// This request, with `detail` and then `speech` halved until its wire line fits `maxWireBytes`.
    /// Character caps upstream normally suffice; this catches characters that are many bytes each.
    public func boundedForWire() -> JarvisRequest {
        var r = self
        while let size = try? WireCodec.encodeLine(r).count, size >= Self.maxWireBytes {
            // Each step strictly shortens a field (n → n/2 including the "…"), so the loop ends.
            if r.detail.count > 1 {
                r.detail = Self.halved(r.detail)
            } else if r.speech.count > 1 {
                r.speech = Self.halved(r.speech)
            } else {
                break
            }
        }
        return r
    }

    private static func halved(_ s: String) -> String {
        String(s.prefix(max(0, s.count / 2 - 1))) + "…"
    }

    /// Info mode applies only to a stop that asks nothing; a question always wins.
    public var isInfoStop: Bool { kind == .stop && info && !asksQuestion }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case project, kind, speech, detail, risky
        case deadlineS = "deadline_s"
        case asksQuestion = "asks_question"
        case info, tty, choices
    }

    /// `asks_question`, `info`, `tty` and `choices` are optional on the wire so an older installed hook binary stays compatible.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        project = try c.decode(String.self, forKey: .project)
        kind = try c.decode(RequestKind.self, forKey: .kind)
        speech = try c.decode(String.self, forKey: .speech)
        detail = try c.decode(String.self, forKey: .detail)
        risky = try c.decode(Bool.self, forKey: .risky)
        deadlineS = try c.decode(Int.self, forKey: .deadlineS)
        asksQuestion = try c.decodeIfPresent(Bool.self, forKey: .asksQuestion) ?? false
        info = try c.decodeIfPresent(Bool.self, forKey: .info) ?? false
        tty = try c.decodeIfPresent(String.self, forKey: .tty) ?? ""
        choices = try c.decodeIfPresent([ChoiceQuestion].self, forKey: .choices) ?? []
    }
}

public enum ResponseStatus: String, Codable, Sendable {
    case answered, timeout, unclear
    /// Kept for wire compatibility; no longer produced.
    case muted
    case expired, handoff
}

public enum Intent: String, Codable, Sendable {
    case allow, deny
    case proceed = "continue"
    case none
}

public struct JarvisResponse: Codable, Equatable, Sendable {
    public var id: String
    public var status: ResponseStatus
    public var transcript: String?
    public var intent: Intent
    /// For an answered `.choice`: one option label per question, in order. Optional on the wire (absent
    /// when nil), so an older hook binary or app stays compatible.
    public var answers: [String]?

    public init(id: String, status: ResponseStatus, transcript: String?, intent: Intent, answers: [String]? = nil) {
        self.id = id
        self.status = status
        self.transcript = transcript
        self.intent = intent
        self.answers = answers
    }
}

public enum WireCodec {
    /// Encodes one JSON object followed by a single trailing newline.
    /// JSON escapes newlines inside strings, so the trailing byte is the only 0x0A.
    public static func encodeLine<T: Encodable>(_ v: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(v)
        data.append(0x0A)
        return data
    }

    public static func decodeLine<T: Decodable>(_ d: Data, as: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: d)
    }
}
