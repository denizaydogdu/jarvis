import Foundation

public struct Heard: Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }

    /// A recognition result reduced to text and confidence. Only a final result carries real segment
    /// confidences; partial-only text gets 0 (the stop gate then treats it as unclear).
    public static func recognized(text: String, confidences: [Float], isFinal: Bool) -> Heard {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return Heard(text: "", confidence: 0) }
        guard isFinal, !confidences.isEmpty else { return Heard(text: t, confidence: 0) }
        return Heard(text: t, confidence: Double(confidences.reduce(0, +)) / Double(confidences.count))
    }
}

public struct Decision: Equatable, Sendable {
    public var status: ResponseStatus
    public var intent: Intent
    public init(status: ResponseStatus, intent: Intent) {
        self.status = status
        self.intent = intent
    }
}

public enum IntentParser {
    private static let denyWords: Set<String> = ["hayır", "reddet", "dur", "iptal", "değil", "olmaz", "yapma", "istemiyorum", "vazgeç"]
    private static let allowWords: Set<String> = ["evet", "onayla", "onaylıyorum", "tamam", "olur"]
    private static let questionParticles: Set<String> = ["mı", "mi", "mu", "mü"]
    private static let stopDone: Set<String> = [
        "yok", "tamam", "bu kadar", "yok teşekkürler", "tamam bu kadar",
    ]
    private static let quotes = CharacterSet(charactersIn: "'\u{2019}\u{2018}\"\u{201C}\u{201D}`\u{00B4}")

    /// Lowercases with the Turkish locale, strips punctuation and quotes, splits on whitespace.
    public static func normalize(_ s: String) -> [String] {
        let lowered = s.lowercased(with: Locale(identifier: "tr_TR"))
        // Punctuation becomes a space so "evet,hayır" still yields two tokens.
        let stripped = String(String.UnicodeScalarView(lowered.unicodeScalars.map {
            CharacterSet.punctuationCharacters.contains($0) || quotes.contains($0) ? " " : $0
        }))
        return stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// The whole answers that mean "not now" (quiet mode), after fillers are removed.
    private static let notNowPhrases: Set<String> = [
        "şu an konuşamam", "şuan konuşamam", "şimdi konuşamam", "konuşamam", "sonra", "sonra konuşalım",
    ]
    /// Words that may surround a not-now phrase without changing it ("şey, sonra", "kedi, konuşamam").
    private static let notNowFillers: Set<String> = ["şey", "ya", "kedi"]

    /// True when the whole answer is "şu an konuşamam", "şimdi konuşamam", "konuşamam", "sonra" or
    /// "sonra konuşalım", optionally with fillers ("şey", "ya", "kedi"). Checked before every other rule
    /// for every kind, so "sonra konuşalım" never becomes an instruction; "sonra" inside a longer answer
    /// ("evet sonra", "bunu sonra yap") is not it.
    public static func notNow(_ h: Heard) -> Bool {
        let words = normalize(h.text).filter { !notNowFillers.contains($0) }
        return notNowPhrases.contains(words.joined(separator: " "))
    }

    public static func permission(_ h: Heard, risky: Bool) -> Decision {
        let tokens = normalize(h.text)
        if tokens.isEmpty { return Decision(status: .timeout, intent: Intent.none) }
        if tokens.contains("terminal") { return Decision(status: .handoff, intent: Intent.none) }

        if tokens.contains(where: { questionParticles.contains($0) }) {
            return Decision(status: .unclear, intent: Intent.none)
        }

        // "izin ver" counts as two allow tokens only as an adjacent pair.
        var isAllow = tokens.map { allowWords.contains($0) }
        for i in tokens.indices.dropLast() where tokens[i] == "izin" && tokens[i + 1] == "ver" {
            isAllow[i] = true
            isAllow[i + 1] = true
        }
        let hasDeny = tokens.contains { denyWords.contains($0) }
        let hasAllow = isAllow.contains(true)

        if hasDeny && hasAllow { return Decision(status: .unclear, intent: Intent.none) }
        if hasDeny { return Decision(status: .answered, intent: .deny) }
        if risky {
            // Only the bare confirmation word (repeats allowed): "onaylıyorum ama önce test et" is unclear.
            if Set(tokens) == ["onaylıyorum"] { return Decision(status: .answered, intent: .allow) }
            return Decision(status: .unclear, intent: Intent.none)
        }
        // Allow only a reply made entirely of allow words, at most 3 after de-duplication, so qualified,
        // ambient or echoed speech ("evet ama önce testleri çalıştır") never approves.
        if isAllow.allSatisfy({ $0 }) && Set(tokens).count <= 3 {
            return Decision(status: .answered, intent: .allow)
        }
        return Decision(status: .unclear, intent: Intent.none)
    }

    /// A short yes/no reply to Claude's question, or nil when the utterance is not one (the stop rules decide).
    /// Repeats count once and question particles are set aside. At most 2 words that are all allow
    /// words, or all deny words, → proceed. Mixed allow and deny, or a question particle → unclear.
    private static func questionAnswer(_ tokens: [String]) -> Decision? {
        var words: [String] = []
        for t in tokens where !questionParticles.contains(t) && !words.contains(t) { words.append(t) }
        guard words.count <= 2,
              words.contains(where: { allowWords.contains($0) || denyWords.contains($0) }) else { return nil }
        let allAllow = words.allSatisfy { allowWords.contains($0) }
        let allDeny = words.allSatisfy { denyWords.contains($0) }
        let hasParticle = tokens.contains { questionParticles.contains($0) }
        let mixed = words.contains { allowWords.contains($0) } && words.contains { denyWords.contains($0) }
        if hasParticle || mixed { return Decision(status: .unclear, intent: Intent.none) }
        if allAllow || allDeny { return Decision(status: .answered, intent: .proceed) }
        return nil
    }

    /// `asksQuestion`: Claude's last message asked something, so a short yes/no answers it and
    /// goes back as the next instruction ("tamam" then answers rather than meaning "done").
    public static func stop(_ h: Heard, asksQuestion: Bool = false) -> Decision {
        let tokens = normalize(h.text)
        if tokens.isEmpty { return Decision(status: .timeout, intent: Intent.none) }
        if tokens.contains("terminal") { return Decision(status: .handoff, intent: Intent.none) }
        if asksQuestion, let d = questionAnswer(tokens) { return d }
        if stopDone.contains(tokens.joined(separator: " ")) {
            return Decision(status: .answered, intent: Intent.none)
        }
        if tokens.count >= 2 && h.confidence >= 0.5 {
            return Decision(status: .answered, intent: .proceed)
        }
        return Decision(status: .unclear, intent: Intent.none)
    }

    /// Spoken option numbers (1-based); `lastOption` stands for the last option, whatever the count.
    /// Includes the common accusative/possessive forms ("ikinciyi", "sonuncusu").
    private static let lastOption = 0
    private static let numberWords: [String: Int] = {
        var m: [String: Int] = [:]
        let forms: [(Int, [String])] = [
            (1, ["1", "bir", "birinci", "birinciyi", "birincisi", "ilk", "ilki", "ilkini"]),
            (2, ["2", "iki", "ikinci", "ikinciyi", "ikincisi"]),
            (3, ["3", "üç", "üçüncü", "üçüncüyü", "üçüncüsü"]),
            (4, ["4", "dört", "dördüncü", "dördüncüyü", "dördüncüsü"]),
            (lastOption, ["son", "sonuncu", "sonuncuyu", "sonuncusu"]),
        ]
        for (n, words) in forms { for w in words { m[w] = n } }
        return m
    }()
    /// The only words that may surround a pick ("bence ikinci seçenek olsun", "Vue'yu seç"). Anything
    /// else ("seçme", "olmasın", "istemem", "ama önce …") makes the answer more than a pick → nil.
    /// The one-letter and two-letter entries are the case suffixes that splitting at an apostrophe leaves.
    private static let choiceFillers: Set<String> = [
        "seçenek", "seçeneği", "seçeneğini", "şık", "şıkkı", "numara", "numaralı", "olan", "olsun",
        "lütfen", "seç", "seçiyorum", "seçtim", "seçelim", "evet", "tamam", "bence", "şu", "o", "the",
        "i", "ı", "u", "ü", "yi", "yı", "yu", "yü", "nı", "ni", "nu", "nü",
    ]
    /// With these, a bare "bir" is an article ("bir seçenek seç"), not option one.
    private static let birArticleWords: Set<String> = ["seçenek", "seçeneği", "seçeneğini", "şık", "şıkkı"]

    /// The option (0-based) a spoken answer clearly picks, or nil. One linear pass over the words.
    /// - Any deny word, question particle or "terminal" → nil: those never pick an option.
    /// - By label: every token of a normalised label is in the answer. Exactly one option may match.
    /// - By number: "bir/birinci/ilk/1" … "dört/dördüncü/4", "son/sonuncu" (last). Number words inside the
    ///   matched label belong to the label. A bare "bir" next to "seçenek"/"şık" is an article → nil.
    /// - Every other word must be a filler (`choiceFillers`), so "React'i seçme", "React olmasın" or
    ///   "bir dakika bekle" pick nothing.
    /// - Label and number must agree; two different picks → nil.
    /// - A not-now answer (`notNow`, e.g. "sonra") → nil, even when an option is labelled "Sonra".
    public static func choice(_ h: Heard, options: [String]) -> Int? {
        // Not-now wins even over an option labelled "Sonra": the answer falls through as heard and the
        // queue turns quiet mode on. That option is still picked by its number.
        if notNow(h) { return nil }
        let tokens = normalize(h.text)
        guard !tokens.isEmpty, !options.isEmpty else { return nil }
        if tokens.contains(where: { $0 == "terminal" || denyWords.contains($0) || questionParticles.contains($0) }) {
            return nil
        }
        let heard = Set(tokens)
        var labelMatch: Int?
        for (i, label) in options.enumerated() {
            let labelTokens = normalize(label)
            guard !labelTokens.isEmpty, labelTokens.allSatisfy(heard.contains) else { continue }
            if labelMatch != nil { return nil }
            labelMatch = i
        }
        let labelTokens = labelMatch.map { Set(normalize(options[$0])) } ?? []
        var numberPick: Int?
        var bareBir = false
        for t in tokens where !labelTokens.contains(t) {
            if let n = numberWords[t] {
                if t == "bir" { bareBir = true }
                let index = n == lastOption ? options.count - 1 : n - 1
                guard index < options.count, numberPick == nil || numberPick == index else { return nil }
                numberPick = index
            } else if !choiceFillers.contains(t) {
                return nil
            }
        }
        if bareBir, tokens.contains(where: birArticleWords.contains) { return nil }
        if let labelMatch {
            guard numberPick == nil || numberPick == labelMatch else { return nil }
            return labelMatch
        }
        return numberPick
    }

    /// The option (0-based) a spoken answer to an office decision clearly picks, or nil.
    /// - By the option text (`texts`, e.g. "Birim testler") or by number, exactly as `choice`.
    /// - By the bare option code (`codes`, e.g. "A", "a şıkkı", "B seçeneği"): every other word must be a
    ///   filler, or must pick the same option on its own ("A, birim testler"). Two different codes → nil.
    /// - A code word inside the matched option text belongs to that text ("A planı").
    /// - Any deny word, question particle or "terminal" → nil, as for `choice`; so is a not-now answer.
    public static func officeChoice(_ h: Heard, codes: [String], texts: [String]) -> Int? {
        // As in `choice`: not-now is never a pick; that option is still picked by its code or number.
        if notNow(h) { return nil }
        let spoken = normalize(h.text)
        guard !spoken.isEmpty, !texts.isEmpty else { return nil }
        if spoken.contains(where: { $0 == "terminal" || denyWords.contains($0) || questionParticles.contains($0) }) {
            return nil
        }
        if let pick = choice(h, options: texts) { return pick }
        // Codes that are one word each; a code shared by two options picks neither.
        var codeIndex: [String: Int?] = [:]
        for (i, code) in codes.enumerated() where i < texts.count {
            let codeWords = normalize(code)
            guard codeWords.count == 1 else { continue }
            let shared: Int? = codeIndex[codeWords[0]] == nil ? i : nil
            codeIndex[codeWords[0]] = .some(shared)
        }
        var codePick: Int?
        var rest: [String] = []
        for word in spoken {
            guard let entry = codeIndex[word] else { rest.append(word); continue }
            guard let i = entry, codePick == nil || codePick == i else { return nil }
            codePick = i
        }
        guard let codePick else { return nil }
        if rest.allSatisfy(choiceFillers.contains) { return codePick }
        let restPick = choice(Heard(text: rest.joined(separator: " "), confidence: h.confidence), options: texts)
        return restPick == codePick ? codePick : nil
    }

    /// True when the answer is a bare "hayır": the word alone or with pick fillers only ("hayır lütfen",
    /// "bence hayır"). Any allow word ("evet", "tamam"), question particle, other deny word or other word
    /// makes it more than a bare no → false. Used only where "Hayır" is the safe direction.
    public static func bareNo(_ h: Heard) -> Bool {
        let tokens = normalize(h.text)
        guard tokens.contains("hayır") else { return false }
        return tokens.allSatisfy { $0 == "hayır" || (choiceFillers.contains($0) && !allowWords.contains($0)) }
    }

    /// Classifies an answer that picked no option: silence → timeout, "terminal" → handoff, else unclear.
    /// It never answers.
    public static func choiceUnanswered(_ h: Heard) -> Decision {
        let tokens = normalize(h.text)
        if tokens.isEmpty { return Decision(status: .timeout, intent: Intent.none) }
        if tokens.contains("terminal") { return Decision(status: .handoff, intent: Intent.none) }
        return Decision(status: .unclear, intent: Intent.none)
    }
}
