import Foundation

public enum SpeechText {
    public static func permission(project: String, call: ToolCall, risky: Bool) -> (speech: String, detail: String) {
        let what = phrase(for: call, commandLimit: risky ? 300 : 120)
        let speech = risky
            ? "\(project) riskli bir işlem istiyor: \(what). Onaylamak için onaylıyorum de."
            : "\(project) izin istiyor: \(what). Onaylıyor musun?"
        return (speech, detail(for: call))
    }

    /// Words of the cleaned message that are spoken; the panel shows the rest.
    public static let spokenWordLimit = 120
    /// The panel text is cut here so a request line stays far below the socket's 64 KB limit.
    public static let displayCharLimit = 8000
    /// Only this much of the assistant text is processed. Speech and display are capped far below it;
    /// this bounds the cost of every cleaning step inside the hook.
    public static let inputCharLimit = 20_000
    /// Character bounds on what is spoken, so the speech (and the request line) stays small whatever
    /// the message holds: each word, the whole speech, and a question appended after the word cap.
    public static let spokenCharLimit = 2000
    public static let spokenWordChars = 40
    public static let spokenQuestionChars = 300
    static let moreOnScreen = "… devamı ekranda."
    static let codePlaceholder = "(kod)."
    static let linkPlaceholder = "(bağlantı)"
    /// Shown on the panel's bold line for an info stop.
    public static let infoLine = "Çalışıyor, bitince haber verecek."

    /// Phrases that say the session keeps working after this turn (matched lowercased, Turkish- and
    /// English-aware). Bare "çalışıyor" ("tests now pass"), "bekliyorum" ("waiting for your approval"),
    /// "bitince" and "hâlâ" are deliberately absent: they are too common outside progress reports.
    static let stillWorkingPhrases = [
        "hâlâ çalışıyor", "hala çalışıyor", "arka planda çalışıyor", "hâlâ yapılıyor", "hala yapılıyor",
        "haber vereceğim", "haber veririm", "bitince haber", "sürüyor", "devam ediyor", "arka planda",
        "yazacağım", "bildireceğim", "neredeyse bitti",
        "still running", "will report", "will let you know", "in the background", "hasn't", "not yet",
    ]

    /// The Stop hook fires at every turn end. The whole last assistant message is cleaned
    /// (markdown, code fences, URLs) and its first `spokenWordLimit` words are read out:
    /// - it asks something (a sentence ends with `?`): `"<project> soruyor. <message>"`; if the word cap
    ///   cut the last question off, that question is appended so it is always heard;
    /// - it says it is still working: `"<project> çalışıyor, bitince haber verecek. <message>"` (`info`);
    /// - otherwise: `"<project> cevap verdi. <message> Sırada ne var?"`.
    /// `displayText` is the full cleaned text for the panel, one source line per line, bounded.
    public static func stop(project: String, lastAssistantText: String?)
        -> (speech: String, asksQuestion: Bool, info: Bool, displayText: String) {
        let lines = messageLines(String((lastAssistantText ?? "").prefix(inputCharLimit)))
        let sentenceList = lines.flatMap { $0 }
        let all = sentenceList.map(\.text)
        // A "?" inside quotes only quotes a question; it does not ask one.
        let questionIndex = sentenceList.lastIndex(where: \.asks)
        let joined = all.joined(separator: " ")
        // Quoted text is ignored for the still-working check too.
        let unquoted = sentenceList.map(\.unquoted).joined(separator: " ")
        let display = boundedDisplay(lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n"),
                                     question: questionIndex.map { all[$0] })

        let words = joined.split(whereSeparator: { $0.isWhitespace }).map { shorten(String($0), maxChars: spokenWordChars) }

        if let qi = questionIndex {
            let wordsThroughQuestion = all[...qi].reduce(0) { $0 + $1.split(whereSeparator: { $0.isWhitespace }).count }
            let tail = wordsThroughQuestion > spokenWordLimit ? " " + spokenQuestion(all[qi]) : ""
            // An either/or question is not answered by yes/no: reply mode, same speech.
            let yesNo = !isEitherOr(sentenceList[qi].unquoted)
            return (speech("\(project) soruyor. ", words, tail), yesNo, false, display)
        }
        if !unquoted.isEmpty, isStillWorking(unquoted) || sentenceList.contains(where: { isFutureWhenDone($0.unquoted) }) {
            return (speech("\(project) çalışıyor, bitince haber verecek. ", words, ""), false, true, display)
        }
        guard !words.isEmpty else { return ("\(project) cevap verdi. Sırada ne var?", false, false, display) }
        return (speech("\(project) cevap verdi. ", words, " Sırada ne var?"), false, false, display)
    }

    /// `prefix` + the first `spokenWordLimit` words + `suffix`, at most `spokenCharLimit` characters.
    /// A message cut by words or by characters ends with "… devamı ekranda."; the suffix always survives.
    private static func speech(_ prefix: String, _ words: [String], _ suffix: String) -> String {
        var message = words.prefix(spokenWordLimit).joined(separator: " ")
        var cut = words.count > spokenWordLimit
        let room = max(0, spokenCharLimit - prefix.count - suffix.count - moreOnScreen.count)
        if message.count > room {
            message = shorten(message, maxChars: room)
            cut = true
        }
        if cut {
            while let last = message.last, ".,;:…".contains(last) { message.removeLast() }
            message += moreOnScreen
        }
        // Last guard for a pathological project name.
        return shorten(prefix + message + suffix, maxChars: spokenCharLimit)
    }

    /// The last sentence of `text` that asks something: the panel's bold question line.
    public static func lastQuestion(in text: String) -> String? {
        sentences(text).last(where: \.asks)?.text
    }

    /// Question particles with and without personal endings (matched on the Turkish-lowercased word).
    static let questionParticles: Set<String> = [
        "mı", "mi", "mu", "mü", "mısın", "misin", "musun", "müsün", "mıyım", "miyim", "muyum", "müyüm",
        "mıyız", "miyiz", "muyuz", "müyüz",
    ]

    /// An either/or question: the (unquoted) sentence has the whole word "yoksa" or at least two
    /// separate question-particle tokens. One linear pass over the words; no regex.
    static func isEitherOr(_ unquotedSentence: String) -> Bool {
        let lowered = unquotedSentence.lowercased(with: Locale(identifier: "tr_TR"))
        var particles = 0
        for word in lowered.split(whereSeparator: { !$0.isLetter }) {
            if word == "yoksa" { return true }
            if questionParticles.contains(String(word)) {
                particles += 1
                if particles >= 2 { return true }
            }
        }
        return false
    }

    static func isStillWorking(_ text: String) -> Bool {
        let plain = text.replacingOccurrences(of: "\u{2019}", with: "'")
        // Turkish lowercasing maps I→ı, İ→i; English lowercasing keeps "STILL" → "still".
        let turkish = plain.lowercased(with: Locale(identifier: "tr_TR"))
        let english = plain.lowercased(with: Locale(identifier: "en_US_POSIX"))
        if stillWorkingPhrases.contains(where: { turkish.contains($0) || english.contains($0) }) { return true }
        return sentences(turkish).contains { isOngoingNow($0.text) }
    }

    /// "şu an" as two whole words, followed later in the same sentence by a word ending in "yor"
    /// ("şu an son testlerini çalıştırıyor"). One linear pass over the words; no regex backtracking,
    /// since this runs inside the hook on arbitrary text.
    static func isOngoingNow(_ lowercasedSentence: String) -> Bool {
        var previous: Substring?
        var sawNow = false
        for word in lowercasedSentence.split(whereSeparator: { !$0.isLetter }) {
            if sawNow, word.count > 3, word.hasSuffix("yor") { return true }
            if previous == "şu", word == "an" { sawNow = true }
            previous = word
        }
        return false
    }

    /// One-word time clauses ("when it is done"); "hazır olunca" is matched as a word pair.
    static let timeClauseWords: Set<String> = ["bitince", "bittiğinde", "tamamlanınca", "tamamlandığında",
                                                "gelince"]
    /// "sonra" is a time clause only after a "-dikten" verb ("testler bittikten sonra"); "bundan sonra"
    /// or "testlerden sonra" are not. "duktan" is the standard spelling of the brief's "dukdan"; both count.
    static let afterClauseEndings = ["dikten", "dıktan", "dukdan", "duktan", "dükten",
                                     "tikten", "tıktan", "tuktan", "tükten"]
    /// First-person future endings: "başlatacağım", "göndereceğim", "yapacağız", "deneyeceğiz".
    static let firstPersonFutureEndings = ["acağım", "eceğim", "acağız", "eceğiz"]

    /// A sentence (quoted text already removed) that says what the session will do once something
    /// finishes: a time-clause word and a first-person future verb. One linear pass over the words of
    /// the Turkish-lowercased sentence; no regex, since this runs inside the hook on arbitrary text.
    static func isFutureWhenDone(_ unquotedSentence: String) -> Bool {
        let lowered = unquotedSentence.lowercased(with: Locale(identifier: "tr_TR"))
        var sawTime = false
        var sawFuture = false
        var previous: Substring?
        for word in lowered.split(whereSeparator: { !$0.isLetter }) {
            if timeClauseWords.contains(String(word)) || (previous == "hazır" && word == "olunca")
                || (word == "sonra" && previous.map { p in afterClauseEndings.contains { p.hasSuffix($0) } } == true) {
                sawTime = true
            }
            if word.count > 6, firstPersonFutureEndings.contains(where: { word.hasSuffix($0) }) {
                sawFuture = true
            }
            if sawTime && sawFuture { return true }
            previous = word
        }
        return false
    }

    /// The sentence without its trailing closing marks. An index walk: linear in the closers trimmed.
    private static func withoutTrailingClosers(_ sentence: String) -> Substring {
        var end = sentence.endIndex
        while end > sentence.startIndex {
            let before = sentence.index(before: end)
            guard closers.contains(sentence[before]) else { break }
            end = before
        }
        return sentence[..<end]
    }

    private static let questionWordLimit = 25

    /// A question appended after the word cap keeps its tail: a Turkish question carries its verb and
    /// particle at the end.
    private static func spokenQuestion(_ question: String) -> String {
        var words = question.split(separator: " ").map { shorten(String($0), maxChars: spokenWordChars) }
        if words.count > questionWordLimit {
            words = Array(words.suffix(questionWordLimit))
            words[0] = "…" + words[0]
        }
        let spoken = words.joined(separator: " ")
        guard spoken.count > spokenQuestionChars else { return spoken }
        return "…" + spoken.suffix(spokenQuestionChars - 1)
    }

    /// Cleaned sentences per source line, each ending in punctuation. Leading heading lines only label
    /// what follows and are skipped; later headings stay as a sentence.
    static func messageLines(_ text: String) -> [[Sentence]] {
        var lines: [[Sentence]] = []
        for line in withoutCodeAndLinks(text) {
            let parts = sentences(line)
            guard let first = parts.first else { continue }
            if first.heading && lines.isEmpty { continue }
            lines.append(parts.map { var p = $0; p.text = punctuated(p.text); return p })
        }
        return lines
    }

    private static func punctuated(_ sentence: String) -> String {
        if let l = withoutTrailingClosers(sentence).last, ".!?:;…".contains(l) { return sentence }
        return sentence + "."
    }

    /// Source lines with each fenced code block (```` ``` ```` or `~~~`, closed or not) replaced by one
    /// `(kod).` line and URLs replaced by `(bağlantı)`. A markdown link keeps its label. A fence opens with
    /// a run of at least three backticks or tildes and closes only on a line that starts with a run of the
    /// same character at least as long.
    static func withoutCodeAndLinks(_ text: String) -> [String] {
        var result: [String] = []
        var fence: (marker: Character, length: Int)?
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if leadingRun(of: open.marker, in: trimmed) >= open.length { fence = nil }
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = leadingRun(of: marker, in: trimmed)
                if length >= 3 {
                    // "```ls```" on one line opens and closes the block at once.
                    if longestRun(of: marker, in: trimmed.dropFirst(length)) < length { fence = (marker, length) }
                    result.append(codePlaceholder)
                    continue
                }
            }
            result.append(replacingLinks(withoutControlCharacters(rawLine)))
        }
        return result
    }

    /// Length of the longest run of `marker` in `text`. One pass.
    private static func longestRun(of marker: Character, in text: Substring) -> Int {
        var longest = 0
        var current = 0
        for c in text {
            current = c == marker ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    /// Length of the run of `marker` at the start of `line`.
    private static func leadingRun(of marker: Character, in line: String) -> Int {
        var n = 0
        for c in line {
            guard c == marker else { break }
            n += 1
        }
        return n
    }

    /// Control characters (tabs included) are neither speakable nor displayable; they become spaces.
    private static func withoutControlCharacters(_ line: Substring) -> String {
        String(String.UnicodeScalarView(line.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
    }

    /// Marks that may end a sentence right after a URL; they stay outside the link.
    private static let urlTrailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", ">", "\"", "'",
                                                      "\u{2019}", "\u{201D}"]
    private static let urlSchemes: [[Character]] = ["https://", "http://", "www."].map(Array.init)
    /// Never occurs in a line here: control characters were replaced by spaces before this step.
    private static let removed: Character = "\u{0}"

    /// URLs become `(bağlantı)`: `[label](url)` → `label (bağlantı)`, `<url>` and bare URLs → `(bağlantı)`.
    /// One linear pass over whitespace-separated tokens (a URL never contains whitespace); no regex, so
    /// no input can make it backtrack inside the hook. Whitespace around a markdown link's destination
    /// is dropped first (`[a]( url )`). A markdown destination ends at its own closing parenthesis
    /// (parentheses inside it balanced), so several links in one token (`[a](x)[b](y)`) all keep their labels.
    static func replacingLinks(_ line: String) -> String {
        var out: [Character] = []
        out.reserveCapacity(line.count)
        // Where the search for a markdown link's "[" may stop: each stretch is searched at most once.
        var searchFloor = 0
        var token: [Character] = []

        func flush() {
            defer { token.removeAll(keepingCapacity: true) }
            var start = 0
            while let (u, schemeLength) = urlStart(token, from: start) {
                if u - start >= 2, token[u - 2] == "]", token[u - 1] == "(",
                   let close = destinationEnd(token, from: u), close > u + schemeLength {
                    // A markdown link: the "[" is in this token or earlier on the line (multi-word label).
                    // The search stops at a "]": "[x] foo](url)" has no label to keep.
                    var prefix = Array(token[start..<(u - 2)])
                    var label = false
                    if let open = prefix.lastIndex(where: { $0 == "[" || $0 == "]" }) {
                        if prefix[open] == "[" {
                            prefix.remove(at: open)
                            label = true
                        }
                    } else if let open = out[searchFloor...].lastIndex(where: { $0 == "[" || $0 == "]" }),
                              out[open] == "[" {
                        out[open] = removed
                        label = true
                    }
                    out += prefix
                    if label {
                        out.append(" ")
                        out += Array(linkPlaceholder)
                    } else {
                        out += ["]", "("] + Array(linkPlaceholder) + [")"]
                    }
                    searchFloor = out.count
                    start = close + 1
                    continue
                }
                // A bare or <angle-bracketed> URL runs to the end of the token, minus trailing marks.
                var end = token.count
                while end > u, urlTrailing.contains(token[end - 1]) { end -= 1 }
                guard end > u + schemeLength else { break }
                var prefix = Array(token[start..<u])
                var suffix = Array(token[end...])
                if prefix.last == "<", suffix.first == ">" {
                    prefix.removeLast()
                    suffix.removeFirst()
                }
                out += prefix
                out += Array(linkPlaceholder)
                out += suffix
                searchFloor = out.count
                return
            }
            out += token[start...]
        }

        for ch in tighteningLinkDestinations(line) {
            if ch.isWhitespace {
                flush()
                out.append(ch)
            } else {
                token.append(ch)
            }
        }
        flush()
        return String(out.filter { $0 != removed })
    }

    /// The index of the ")" that closes a markdown link destination starting at `from`, with parentheses
    /// inside it balanced; nil when it does not close in the token. One pass.
    private static func destinationEnd(_ token: [Character], from: Int) -> Int? {
        var depth = 0
        for i in from..<token.count {
            if token[i] == "(" {
                depth += 1
            } else if token[i] == ")" {
                if depth == 0 { return i }
                depth -= 1
            }
        }
        return nil
    }

    /// `line` with the whitespace right after a markdown "](" and right before the ")" that closes that
    /// destination removed, so the link is one token. Other whitespace is kept. One pass.
    private static func tighteningLinkDestinations(_ line: String) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(line.count)
        var inDestination = false
        var atDestinationStart = false
        var depth = 0
        var pending: [Character] = []
        for ch in line {
            guard inDestination else {
                out.append(ch)
                if ch == "(", out.count >= 2, out[out.count - 2] == "]" {
                    inDestination = true
                    atDestinationStart = true
                    depth = 0
                }
                continue
            }
            if ch.isWhitespace {
                if !atDestinationStart { pending.append(ch) }
                continue
            }
            atDestinationStart = false
            if ch == ")", depth == 0 {
                // Whitespace before the closing parenthesis is dropped.
                pending.removeAll(keepingCapacity: true)
                inDestination = false
                out.append(ch)
                continue
            }
            if !pending.isEmpty {
                // Whitespace inside the destination: not a link destination after all; keep everything.
                out += pending
                pending.removeAll(keepingCapacity: true)
                inDestination = false
                out.append(ch)
                if ch == "(", out.count >= 2, out[out.count - 2] == "]" {
                    inDestination = true
                    atDestinationStart = true
                    depth = 0
                }
                continue
            }
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            out.append(ch)
        }
        out += pending
        return out
    }

    /// The first position in `token` at or after `from` where a URL scheme starts (ASCII case-insensitive),
    /// with its length.
    /// Constant work per position: linear in the token.
    private static func urlStart(_ token: [Character], from: Int) -> (Int, Int)? {
        guard from < token.count else { return nil }
        for i in from..<token.count {
            for scheme in urlSchemes where i + scheme.count <= token.count {
                var match = true
                for k in scheme.indices where token[i + k].lowercased() != String(scheme[k]) {
                    match = false
                    break
                }
                if match { return (i, scheme.count) }
            }
        }
        return nil
    }

    /// Cuts the panel text at `displayCharLimit` (at a space). When the cut removed the question, it is
    /// appended on its own line so the panel's question line can still be found.
    private static func boundedDisplay(_ text: String, question: String?) -> String {
        guard text.count > displayCharLimit else { return text }
        var kept = shorten(text, maxChars: displayCharLimit, collapse: false)
        if let question, lastQuestion(in: kept) != question {
            let q = question.count > 500 ? "…" + question.suffix(500) : question
            kept += "\n" + q
        }
        return kept
    }

    /// Closing marks that may follow a sentence's `.`, `!` or `?`; trimmed from every sentence's end.
    private static let closers: Set<Character> = ["*", "_", "\"", "'", ")", "\u{201D}", "»", "`"]

    /// One cleaned sentence. `asks`: it ends with a "?" that is not inside quotes. `unquoted`: its text
    /// without quoted spans, for phrase checks.
    struct Sentence {
        var text: String
        var heading: Bool
        var asks: Bool
        var unquoted: String
    }

    /// Quote pairs whose content is only quoted: "…", “…”, «…» and `…` (no nesting).
    private static let quotePairs: [Character: Character] = ["\"": "\"", "\u{201C}": "\u{201D}", "«": "»", "`": "`"]

    /// Marks every character of each closed quote span, quotes included. An unclosed quote marks nothing.
    /// Linear: spans are disjoint, so each character is marked at most once.
    static func quotedMask(_ chars: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count)
        var open: (closer: Character, start: Int)?
        for (i, c) in chars.enumerated() {
            if let o = open {
                if c == o.closer {
                    for k in o.start...i { mask[k] = true }
                    open = nil
                }
            } else if let closer = quotePairs[c] {
                open = (closer, i)
            }
        }
        return mask
    }

    /// Markdown-free sentences of `text`, each whitespace-collapsed and non-empty; `heading` marks
    /// sentences from a line that started with `#`.
    /// A sentence ends at `.`, `!` or `?` (plus any closers) followed by whitespace or the end,
    /// and at every newline. Backticks are dropped from the text but still delimit quoted spans.
    static func sentences(_ text: String) -> [Sentence] {
        var result: [Sentence] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let raw = String(rawLine)
            let heading = raw.trimmingCharacters(in: .whitespaces).hasPrefix("#")
            let chars = Array(cleanLine(raw))
            let quoted = quotedMask(chars)
            var current = ""
            var plain = ""
            func take(_ k: Int) {
                guard chars[k] != "`" else { return }
                current.append(chars[k])
                if !quoted[k] { plain.append(chars[k]) }
            }
            var i = 0
            while i < chars.count {
                take(i)
                if ".!?".contains(chars[i]) {
                    var j = i + 1
                    while j < chars.count, closers.contains(chars[j]) { j += 1 }
                    if j == chars.count || chars[j].isWhitespace {
                        for k in (i + 1)..<j { take(k) }
                        let asks = chars[i] == "?" && !quoted[i]
                        append(current, plain, heading: heading, asks: asks, to: &result)
                        current = ""
                        plain = ""
                        i = j
                        continue
                    }
                }
                i += 1
            }
            append(current, plain, heading: heading, asks: false, to: &result)
        }
        return result
    }

    private static func append(_ sentence: String, _ plain: String, heading: Bool, asks: Bool,
                               to result: inout [Sentence]) {
        var collapsed = sentence.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // A closing mark that closes one opened in the sentence ("(bağlantı)", “Gönder mi?”) is text,
        // not a closer. Counted once and kept up to date, so a long run of closers stays linear.
        var counts: [Character: Int] = [:]
        for c in collapsed where "()\u{201C}\u{201D}«»\"".contains(c) { counts[c, default: 0] += 1 }
        func n(_ c: Character) -> Int { counts[c, default: 0] }
        while let last = collapsed.last, closers.contains(last) {
            let balanced: Bool
            switch last {
            case ")": balanced = n(")") <= n("(")
            case "\u{201D}": balanced = n("\u{201D}") <= n("\u{201C}")
            case "»": balanced = n("»") <= n("«")
            case "\"": balanced = n("\"") % 2 == 0
            default: balanced = false
            }
            if balanced { break }
            counts[last, default: 0] -= 1
            collapsed.removeLast()
        }
        // A leading emphasis marker (`*Göndereyim mi?*`) is markup, not speech.
        let markers = collapsed.prefix(while: { $0 == "*" || $0 == "_" }).count
        if markers > 0 { collapsed = String(collapsed.dropFirst(markers)) }
        collapsed = collapsed.trimmingCharacters(in: .whitespaces)
        let unquoted = plain.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !collapsed.isEmpty { result.append(Sentence(text: collapsed, heading: heading, asks: asks, unquoted: unquoted)) }
    }

    /// Strips a heading marker and a list prefix at the line start, then `**` and `__`. Backticks stay
    /// until `sentences` has used them as quote marks.
    private static func cleanLine(_ raw: String) -> String {
        var line = Substring(raw.trimmingCharacters(in: .whitespaces))
        while line.first == "#" { line = line.dropFirst() }
        line = line.drop(while: { $0.isWhitespace })
        if line == "-" || line == "*" || line.hasPrefix("- ") || line.hasPrefix("* ") {
            line = line.dropFirst(min(2, line.count))
        } else {
            let digits = line.prefix(while: { $0.isASCII && $0.isNumber })
            if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
                line = line.dropFirst(digits.count + 2)
            }
        }
        return String(line)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
    }

    /// `collapse`: whitespace runs (newlines included) become one space first.
    public static func shorten(_ s: String, maxChars: Int, collapse: Bool = true) -> String {
        let collapsed = collapse ? s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") : s
        guard collapsed.count > maxChars else { return collapsed }
        let head = String(collapsed.prefix(maxChars))
        // Cut at the last space before maxChars; hard-cut when there is none.
        if let space = head.lastIndex(where: { $0 == " " || $0 == "\n" }) {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }

    private static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private static func phrase(for call: ToolCall, commandLimit: Int) -> String {
        if call.name == "Bash" {
            return "şu komutu çalıştırmak: " + shorten(call.command ?? "", maxChars: commandLimit)
        }
        if fileTools.contains(call.name) {
            let file = (call.filePath as NSString?)?.lastPathComponent ?? ""
            return "\(file) dosyasını değiştirmek"
        }
        if call.name.hasPrefix("mcp__") {
            let parts = call.name.components(separatedBy: "__")
            if parts.count >= 3 {
                return "\(parts[1]) aracını kullanmak: \(parts[2...].joined(separator: "__"))"
            }
        }
        if call.name == "ExitPlanMode" { return "planı onaylatmak" }
        return "\(call.name) aracını kullanmak"
    }

    private static func detail(for call: ToolCall) -> String {
        if call.name == "Bash" { return call.command ?? "" }
        if fileTools.contains(call.name) { return call.filePath ?? call.name }
        return call.name
    }

    /// Spoken characters per option label; the panel shows the whole label.
    static let spokenLabelChars = 80

    /// One multiple-choice question: `"<project> soruyor: <question>. Seçenekler: 1, <label>; 2, <label>."`
    /// The question keeps its own closing punctuation. Descriptions are shown on screen, never spoken.
    /// Long questions and labels are shortened for speech only; the answer is always the full label.
    public static func choice(project: String, question: ChoiceQuestion) -> String {
        var text = shorten(question.question, maxChars: spokenQuestionChars)
        if let last = text.last, !".?!…".contains(last) { text += "." }
        let options = question.options.enumerated()
            .map { "\($0.offset + 1), \(shorten($0.element.label, maxChars: spokenLabelChars))" }
            .joined(separator: "; ")
        return "\(project) soruyor: \(text) Seçenekler: \(options)."
    }
}
