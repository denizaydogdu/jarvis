import Foundation

// The pure decisions of the app's office integration: which cards to ask on a poll, how long to wait
// after a gate error, what a finished ask means, and what the gate's reply to an answer means.

// MARK: - Requests and panel text

extension OfisCards {
    /// The project caption and session id of every office request; they never leave the app.
    public static let project = "ofis"
    public static let sessionId = "ofis"
    /// Like a hook request: the queue expires an ask that waited so long that less than its minimum is left.
    public static let deadlineSeconds = 150

    /// The `.choice` request the queue asks for `ask`: one question, no tty (never focus-skipped).
    public static func request(for ask: OfisAsk, id: String) -> JarvisRequest {
        JarvisRequest(id: id, sessionId: sessionId, project: project, kind: .choice, speech: ask.speech, detail: "",
                      risky: ask.needsScreenConfirm, deadlineS: deadlineSeconds, choices: [ask.question])
    }

    /// An info display ("İletildi.", the office status): spoken, shown, never listened to.
    public static func infoRequest(_ text: String, id: String) -> JarvisRequest {
        JarvisRequest(id: id, sessionId: sessionId, project: project, kind: .stop, speech: text, detail: text,
                      risky: false, deadlineS: deadlineSeconds, info: true)
    }

    /// The menu's "Ofis durumu" display; a fresh id each time.
    public static func statusRequest(_ text: String) -> JarvisRequest {
        infoRequest(text, id: "ofis-status-" + UUID().uuidString.lowercased())
    }

    /// Whether option buttons carry the "1." number: an office ask's labels are already "A) …".
    public static func numbersOptions(_ r: JarvisRequest) -> Bool {
        !isOfficeAsk(r)
    }

    /// An office info display: the panel shows its text alone, without the "still working" line.
    public static func isOfficeInfo(_ r: JarvisRequest) -> Bool {
        r.isInfoStop && r.sessionId == sessionId && r.project == project
    }

    /// The buttons of an office ask: one per option, then `Konuşamam`. Never `Terminal`: no terminal waits.
    public static func buttons(for r: JarvisRequest) -> [AnswerButton] {
        AnswerButton.buttons(for: r, question: 0).filter { $0 != .terminal }
    }

    /// An office decision (not an office info display): it never comes from a terminal session.
    public static func isOfficeAsk(_ r: JarvisRequest) -> Bool {
        r.kind == .choice && r.sessionId == sessionId && r.project == project
    }
}

extension OfisAsk {
    /// `"<proje> — <baslik>"`, and the risk line below it for a high-risk card.
    public var panelBody: String {
        let head = [proje, baslik].filter { !$0.isEmpty }.joined(separator: " — ")
        guard let riskLine else { return head }
        return head.isEmpty ? riskLine : head + "\n" + riskLine
    }

    public var panelQuestion: String { question.question }

    /// The confirm step's line: `"<seçim> — Onaylıyor musun?"`.
    public func confirmQuestion(forOption index: Int) -> String {
        guard options.indices.contains(index) else { return "Onaylıyor musun?" }
        return "\(options[index].label) — Onaylıyor musun?"
    }

    /// The option a spoken answer picks: by option text, number or bare code (`IntentParser.officeChoice`).
    /// A yes/no card has no codes; "Evet" picks by its word, and a bare "hayır" (alone or with fillers,
    /// `IntentParser.bareNo`) picks "Hayır", the safe direction. Any other deny word never picks.
    public func spokenPick(_ heard: Heard) -> Int? {
        if kind == .yesNo, IntentParser.bareNo(heard),
           let no = options.firstIndex(where: { $0.answer == OfisCards.no }) {
            return no
        }
        let codes = kind == .choice ? options.map(\.answer) : []
        let texts = options.map { option in
            let prefix = option.answer + ") "
            return kind == .choice && option.label.hasPrefix(prefix) ? String(option.label.dropFirst(prefix.count))
                                                                      : option.label
        }
        return IntentParser.officeChoice(heard, codes: codes, texts: texts)
    }
}

// MARK: - Polling

/// What one `kararlar` poll asks: new, askable, not-snoozed cards in list order, and the cards that stay on
/// the page with their reason.
public struct OfisPollPlan: Equatable, Sendable {
    public struct Skip: Equatable, Sendable {
        public var note: String
        public var reason: String

        public init(note: String, reason: String) {
            self.note = note
            self.reason = reason
        }
    }

    public var asks: [OfisAsk]
    public var skips: [Skip]

    /// `pending`: notes already in the queue or being answered; they are never enqueued twice.
    public static func make(_ kararlar: [OfisKarar], seen: OfisSeen, pending: Set<String>, now: Date) -> OfisPollPlan {
        var asks: [OfisAsk] = []
        var skips: [Skip] = []
        var taken = pending
        for karar in kararlar {
            if let reason = OfisCards.skipReason(for: karar) {
                skips.append(Skip(note: karar.note, reason: reason))
                continue
            }
            guard !taken.contains(karar.note), seen.shouldAsk(karar.note, now: now),
                  let ask = OfisCards.ask(for: karar) else { continue }
            taken.insert(karar.note)
            asks.append(ask)
        }
        return OfisPollPlan(asks: asks, skips: skips)
    }
}

/// The gate's state as the poller sees it; logged once per change as `ofis: gate <state>`.
public enum OfisGateState: String, Equatable, Sendable {
    case ok, off, unreachable, unauthorized, error
    case rateLimited = "rate-limited"

    /// The normal poll interval.
    public static let pollSeconds: TimeInterval = 30
    static let offSeconds: TimeInterval = 5 * 60
    static let unreachableSeconds: TimeInterval = 2 * 60

    /// The state after a failed poll and the seconds to wait before the next one: gate off → 5 min,
    /// unreachable or any other failure → 2 min, rate limited → the Retry-After (at least 1 s),
    /// key refused → 5 min.
    public static func after(_ error: Error) -> (state: OfisGateState, wait: TimeInterval) {
        switch error as? OfisError {
        case .gateOff: return (.off, offSeconds)
        case .unreachable: return (.unreachable, unreachableSeconds)
        case .rateLimited(let s): return (.rateLimited, max(1, s))
        case .unauthorized: return (.unauthorized, offSeconds)
        default: return (.error, unreachableSeconds)
        }
    }
}

// MARK: - Answering

/// What the panel did besides picking, told to the poller through the app's side channel.
public enum OfisPanelMark: Equatable, Sendable {
    /// `Konuşamam`: quiet mode is on; the card is asked again after it, with no per-card snooze.
    case notNow
    /// `İptal` at the high-risk confirm step.
    case cancelled
    /// `Onaylıyorum` held at the high-risk confirm step.
    case confirmed
    /// "Ofis kararlarını sor" was off when the ask reached the panel: nothing was shown.
    case withdrawn
}

/// What to do once an office ask has ended.
public enum OfisOutcome: Equatable, Sendable {
    /// Send this answer; `ekranOnayi` only after the on-screen hold.
    case send(cevap: String, ekranOnayi: Bool)
    /// Nothing is sent; ask again after this many seconds.
    case snooze(TimeInterval)
    /// Nothing was shown: nothing is sent, and the next poll may ask again.
    case retry

    /// Silence, unclear speech or the timeout.
    public static let unansweredSnooze: TimeInterval = 10 * 60

    /// - `İptal` → 30-minute snooze; `Konuşamam`, withdrawn or expired in the queue → retry (nothing sent;
    ///   the poller does not ask while quiet mode is on).
    /// - Exactly one picked label that is one of the ask's buttons → send its code/word. A card that needs
    ///   the screen confirm is sent only when the hold was given, then with `ekranOnayi: true`.
    /// - Anything else (silence, unclear, handoff, a pick without the hold) → 10-minute snooze.
    public static func decide(ask: OfisAsk, response: JarvisResponse, mark: OfisPanelMark?) -> OfisOutcome {
        switch mark {
        case .cancelled: return .snooze(OfisSeen.cancelSnooze)
        case .notNow, .withdrawn: return .retry
        case .confirmed, nil: break
        }
        if response.status == .expired { return .retry }
        guard response.status == .answered, let labels = response.answers, labels.count == 1,
              let cevap = ask.answer(forLabel: labels[0]), OfisCards.isSendable(cevap) else {
            return .snooze(unansweredSnooze)
        }
        if ask.needsScreenConfirm {
            return mark == .confirmed ? .send(cevap: cevap, ekranOnayi: true) : .snooze(unansweredSnooze)
        }
        return .send(cevap: cevap, ekranOnayi: false)
    }
}

/// The gate's reply to an answer, and what Jarvis says and remembers about it.
public enum OfisReply: Equatable, Sendable {
    case delivered
    /// `zaten_iletildi`, `cevaplanmis` or `cevap-iletildi`: an answer already reached the office.
    case alreadyAnswered
    /// `ceo-ulasilamiyor`.
    case ceoUnreachable
    /// High risk, held on screen, and the gate still wants the confirm: continue with `onayla(taskId:)`.
    case needsScreenConfirm(taskId: String)
    /// Nothing reached the office. `reason` is for the log: a status code or `kod`, never gate text or key.
    case notDelivered(reason: String)

    /// `mayConfirm`: the hold was given and `onayla` has not been tried yet.
    public static func classify(_ result: Result<OfisCevapSonucu, Error>, mayConfirm: Bool) -> OfisReply {
        switch result {
        case .success(let sonuc):
            return sonuc.zatenIletildi ? .alreadyAnswered : .delivered
        case .failure(let error):
            guard let e = error as? OfisError else { return .notDelivered(reason: "unexpected error") }
            switch e {
            case .rejected(let kod, _) where kod == "cevaplanmis" || kod == "cevap-iletildi":
                return .alreadyAnswered
            case .failed(let kod) where kod == "ceo-ulasilamiyor":
                return .ceoUnreachable
            case .inputRequired(let kod, _, let taskId) where mayConfirm && kod == "ekran_onayi_gerekir" && !taskId.isEmpty:
                return .needsScreenConfirm(taskId: taskId)
            default:
                return .notDelivered(reason: e.description)
            }
        }
    }

    /// Spoken in info style after the answer; nil: nothing is said.
    public var speech: String? {
        switch self {
        case .delivered: return "İletildi."
        case .alreadyAnswered: return "Bu karar zaten cevaplanmış."
        case .ceoUnreachable: return "CEO şu an ulaşılamıyor, sayfadan cevaplayabilirsin."
        case .needsScreenConfirm, .notDelivered: return nil
        }
    }

    /// The decision is answered: it is remembered and never asked again.
    public var marksAsked: Bool { self == .delivered || self == .alreadyAnswered }

    /// Not answered: ask again after this many seconds.
    public var snooze: TimeInterval? {
        switch self {
        case .delivered, .alreadyAnswered, .needsScreenConfirm: return nil
        // He was told to answer on the page: do not ask again soon.
        case .ceoUnreachable: return OfisSeen.cancelSnooze
        case .notDelivered: return OfisOutcome.unansweredSnooze
        }
    }
}
