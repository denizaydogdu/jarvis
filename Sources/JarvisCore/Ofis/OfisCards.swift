import Foundation

/// What Jarvis asks for one office decision card.
public struct OfisAsk: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The card has 1–4 options; the answer is an option `kod`.
        case choice
        /// The card has no options; the answer is "Evet" or "Hayır".
        case yesNo
    }

    /// One button: `label` is shown (and matched by voice), `answer` is exactly what is sent as `cevap`.
    public struct Option: Equatable, Sendable {
        public var label: String
        public var answer: String

        public init(label: String, answer: String) {
            self.label = label
            self.answer = answer
        }
    }

    public var note: String
    public var proje: String
    public var baslik: String
    public var kind: Kind
    /// `"Ofis soruyor: <proje> — <baslik>. <soru> Seçenekler: …"`.
    public var speech: String
    /// The question for the existing choice panel; its option labels are `options[i].label`.
    public var question: ChoiceQuestion
    public var options: [Option]
    /// The card's `risk` is `yuksek`.
    public var highRisk: Bool
    /// Send only after the on-screen hold-to-confirm: `risk == yuksek` or the gate's `ekran_onayi_gerekir`.
    public var needsScreenConfirm: Bool
    /// The line shown for a high-risk card (`"Yüksek risk: <risk_nedeni>"`), nil otherwise.
    public var riskLine: String?

    /// The wire answer for a picked button label; nil for anything that is not one of the buttons.
    public func answer(forLabel label: String) -> String? {
        options.first { $0.label == label }?.answer
    }
}

public enum OfisCards {
    public static let maxOptions = 4
    public static let yes = "Evet"
    public static let no = "Hayır"

    /// The only answers ever sent: an option code of 1–3 ASCII letters/digits, or exactly "Evet"/"Hayır".
    /// Free text never reaches the gate.
    public static func isSendable(_ cevap: String) -> Bool {
        cevap == yes || cevap == no || isCode(cevap)
    }

    static func isCode(_ kod: String) -> Bool {
        (1...3).contains(kod.unicodeScalars.count)
            && kod.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    /// Why a card is not asked by Jarvis (it stays on the page), or nil when it is askable.
    public static func skipReason(for karar: OfisKarar) -> String? {
        if karar.note.isEmpty { return "no note name" }
        if karar.cevapIletildi { return "answer already on its way" }
        if karar.secenekler.count > maxOptions { return "more than 4 options" }
        let codes = karar.secenekler.map(\.kod)
        if !codes.allSatisfy(isCode) || Set(codes).count != codes.count { return "unsupported option code" }
        return nil
    }

    /// The ask for a card, or nil when the card stays on the page (see `skipReason`). With a `log`, a skipped
    /// card is logged as `ofis: skipped <note>: <reason>` — the note name only, never the question text.
    public static func ask(for karar: OfisKarar, log: JarvisLog? = nil) -> OfisAsk? {
        if let reason = skipReason(for: karar) {
            log?.append("ofis: skipped \(JarvisLog.field(karar.note)): \(reason)")
            return nil
        }
        let kind: OfisAsk.Kind = karar.secenekler.isEmpty ? .yesNo : .choice
        let options: [OfisAsk.Option] = kind == .yesNo
            ? [OfisAsk.Option(label: yes, answer: yes), OfisAsk.Option(label: no, answer: no)]
            : karar.secenekler.map { OfisAsk.Option(label: "\($0.kod)) \($0.metin)", answer: $0.kod) }
        let question = ChoiceQuestion(question: karar.soru, header: karar.baslik,
                                      options: options.map { ChoiceOption(label: $0.label, description: "") })
        let riskLine: String? = karar.isHighRisk
            ? (karar.riskNedeni.isEmpty ? "Yüksek risk" : "Yüksek risk: \(karar.riskNedeni)")
            : nil
        return OfisAsk(note: karar.note, proje: karar.proje, baslik: karar.baslik, kind: kind,
                       speech: speech(for: karar, kind: kind), question: question, options: options,
                       highRisk: karar.isHighRisk, needsScreenConfirm: karar.isHighRisk || karar.ekranOnayiGerekir,
                       riskLine: riskLine)
    }

    /// `"Ofis soruyor: <proje> — <baslik>. <soru> Seçenekler: A, <metin>; B, <metin>."` (yes/no: `Evet; Hayır`).
    static func speech(for karar: OfisKarar, kind: OfisAsk.Kind) -> String {
        var soru = SpeechText.shorten(karar.soru, maxChars: SpeechText.spokenQuestionChars)
        if let last = soru.last, !".?!…".contains(last) { soru += "." }
        let options = kind == .yesNo
            ? "\(yes); \(no)"
            : karar.secenekler
                .map { "\($0.kod), \(SpeechText.shorten($0.metin, maxChars: SpeechText.spokenLabelChars))" }
                .joined(separator: "; ")
        let head = "Ofis soruyor: \(karar.proje) — \(karar.baslik)."
        return (soru.isEmpty ? head : head + " " + soru) + " Seçenekler: \(options)."
    }
}

/// Which office notes were already asked and which are snoozed (İptal, the CEO unreachable). Pure value; the app keeps one in
/// memory and persists it to `~/.jarvis/ofis-seen.json` (0600) with note names and timestamps only.
public struct OfisSeen: Equatable, Sendable {
    /// The 30-minute snooze (İptal, the CEO unreachable). (Was `sonra`, after the old "Sonra" button.)
    public static let cancelSnooze: TimeInterval = 30 * 60

    /// note → when it was asked. An asked note is not asked again until it is snoozed.
    public private(set) var asked: [String: Date] = [:]
    /// note → ask again from this moment on.
    public private(set) var snoozed: [String: Date] = [:]

    public init() {}

    public static func path(in paths: JarvisPaths) -> String { paths.dir + "/ofis-seen.json" }

    public func shouldAsk(_ note: String, now: Date) -> Bool {
        if asked[note] != nil { return false }
        if let until = snoozed[note], now < until { return false }
        return true
    }

    public mutating func markAsked(_ note: String, at date: Date) {
        asked[note] = date
        snoozed[note] = nil
    }

    /// Ask the note again `interval` after `now` (default: 30 minutes).
    public mutating func snooze(_ note: String, for interval: TimeInterval = OfisSeen.cancelSnooze, now: Date) {
        asked[note] = nil
        snoozed[note] = now + interval
    }

    /// Forget notes that are no longer pending, so the file stays small.
    public mutating func prune(keeping pending: Set<String>) {
        asked = asked.filter { pending.contains($0.key) }
        snoozed = snoozed.filter { pending.contains($0.key) }
    }

    // MARK: persistence

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// The saved state; a missing, unreadable or corrupt file starts empty.
    public static func load(from path: String) -> OfisSeen {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return OfisSeen() }
        let f = formatter()
        func dates(_ key: String) -> [String: Date]? {
            guard let raw = obj[key] else { return [:] }
            guard let dict = raw as? [String: String] else { return nil }
            var out: [String: Date] = [:]
            for (note, stamp) in dict {
                guard let d = f.date(from: stamp) else { return nil }
                out[note] = d
            }
            return out
        }
        guard let asked = dates("asked"), let snoozed = dates("snoozed") else { return OfisSeen() }
        var seen = OfisSeen()
        seen.asked = asked
        seen.snoozed = snoozed
        return seen
    }

    /// A temp file next to `path`, unique per save: concurrent saves never write or rename each other's.
    static func tempPath(for path: String) -> String { path + ".tmp-" + UUID().uuidString }

    /// Writes `{"asked": {note: ISO date}, "snoozed": {note: ISO date}}` atomically with mode 0600; the
    /// directory is created with mode 0700 when missing.
    public func save(to path: String) throws {
        let f = Self.formatter()
        let obj: [String: [String: String]] = [
            "asked": asked.mapValues { f.string(from: $0) },
            "snoozed": snoozed.mapValues { f.string(from: $0) },
        ]
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let tmp = Self.tempPath(for: path)
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        chmod(tmp, 0o600)  // createFile honours the umask; make the mode exact
        guard rename(tmp, path) == 0 else {
            unlink(tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
