import Foundation

/// Why an office call did not produce a result. Descriptions never contain the gate key: every text that
/// comes from the gate has the key redacted before it is parsed (see `OfisClient`).
public enum OfisError: Error, Equatable, Sendable, CustomStringConvertible {
    /// HTTP 404: the gate is switched off (`jarvis.acik` in ofis.json), or a card endpoint answered 404.
    case gateOff
    /// HTTP 401 twice (after one key re-read), or no readable key file.
    case unauthorized
    /// HTTP 429, or the client's own limit; wait this many seconds before the next call.
    case rateLimited(retryAfter: TimeInterval)
    /// No Ofis Agent Card on 127.0.0.1:8800…8819, or the endpoint stopped answering.
    case unreachable
    /// A JSON-RPC error object (`-32602`, `-32001`, …).
    case rpc(code: Int)
    /// `TASK_STATE_REJECTED` with `status.message` data `kod` and text.
    case rejected(kod: String, text: String)
    /// `TASK_STATE_INPUT_REQUIRED`; continue with `OfisClient.onayla(taskId:)` after the on-screen confirm.
    case inputRequired(kod: String, text: String, taskId: String)
    /// `TASK_STATE_FAILED` (e.g. `ceo-ulasilamiyor`).
    case failed(kod: String)
    /// Any other HTTP status (403, 413, 415, 5xx) or a body that is not the expected JSON-RPC shape.
    case badResponse(status: Int)
    /// Refused locally: only option codes, "Evet" and "Hayır" are ever sent as an answer.
    case invalidAnswer

    public var description: String {
        switch self {
        case .gateOff: return "ofis gate is off"
        case .unauthorized: return "ofis gate refused the key"
        case .rateLimited(let s): return "ofis gate rate limited, retry after \(Int(s.rounded(.up))) s"
        case .unreachable: return "ofis gate unreachable"
        case .rpc(let code): return "ofis gate JSON-RPC error \(code)"
        case .rejected(let kod, _): return "ofis gate rejected the request (\(kod))"
        case .inputRequired(let kod, _, _): return "ofis gate needs input (\(kod))"
        case .failed(let kod): return "ofis gate task failed (\(kod))"
        case .badResponse(let status): return "ofis gate gave an unexpected response (HTTP \(status))"
        case .invalidAnswer: return "answer is not an option code or Evet/Hayır; not sent"
        }
    }
}

/// The gate's JSON uses snake_case (`risk_nedeni`, `zaten_iletildi`, …); every Ofis model is decoded with
/// this decoder, so the Swift names below are the camelCase forms and no key mapping is spelled out.
enum OfisJSON {
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

/// One option of a decision card.
public struct OfisSecenek: Decodable, Equatable, Sendable {
    public var kod: String
    public var metin: String

    public init(kod: String, metin: String) {
        self.kod = kod
        self.metin = metin
    }

    enum CodingKeys: CodingKey { case kod, metin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kod = try c.decode(String.self, forKey: .kod)
        metin = try c.decodeIfPresent(String.self, forKey: .metin) ?? ""
    }
}

/// One pending decision from the `kararlar` skill. Only `note` is required; the rest falls back to empty
/// values so that a new or missing field on the gate side does not drop the card.
public struct OfisKarar: Decodable, Equatable, Sendable {
    public var note: String
    public var baslik: String
    public var proje: String
    public var tur: String
    public var soru: String
    public var secenekler: [OfisSecenek]
    public var risk: String
    public var riskNedeni: String
    public var ekranOnayiGerekir: Bool
    public var soruldu: String
    /// An answer is already on its way (from the page or Jarvis); a new one would be refused.
    public var cevapIletildi: Bool

    public var isHighRisk: Bool { risk == "yuksek" }

    enum CodingKeys: CodingKey {
        case note, baslik, proje, tur, soru, secenekler, risk, riskNedeni, ekranOnayiGerekir, soruldu, cevapIletildi
    }

    public init(note: String, baslik: String, proje: String, tur: String, soru: String, secenekler: [OfisSecenek],
                risk: String, riskNedeni: String, ekranOnayiGerekir: Bool, soruldu: String, cevapIletildi: Bool) {
        self.note = note
        self.baslik = baslik
        self.proje = proje
        self.tur = tur
        self.soru = soru
        self.secenekler = secenekler
        self.risk = risk
        self.riskNedeni = riskNedeni
        self.ekranOnayiGerekir = ekranOnayiGerekir
        self.soruldu = soruldu
        self.cevapIletildi = cevapIletildi
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = try c.decode(String.self, forKey: .note)
        baslik = try c.decodeIfPresent(String.self, forKey: .baslik) ?? ""
        proje = try c.decodeIfPresent(String.self, forKey: .proje) ?? ""
        tur = try c.decodeIfPresent(String.self, forKey: .tur) ?? ""
        soru = try c.decodeIfPresent(String.self, forKey: .soru) ?? ""
        secenekler = try c.decodeIfPresent([OfisSecenek].self, forKey: .secenekler) ?? []
        risk = try c.decodeIfPresent(String.self, forKey: .risk) ?? ""
        riskNedeni = try c.decodeIfPresent(String.self, forKey: .riskNedeni) ?? ""
        ekranOnayiGerekir = try c.decodeIfPresent(Bool.self, forKey: .ekranOnayiGerekir) ?? false
        soruldu = try c.decodeIfPresent(String.self, forKey: .soruldu) ?? ""
        cevapIletildi = try c.decodeIfPresent(Bool.self, forKey: .cevapIletildi) ?? false
    }
}

/// The completed result of `karar-cevapla`.
public struct OfisCevapSonucu: Decodable, Equatable, Sendable {
    public var note: String
    /// The answer as delivered to the CEO (`"A) <option text>"` for a code).
    public var cevap: String
    /// `delivered` or `queued`.
    public var iletim: String
    /// True when the same answer had already been delivered; nothing was sent twice.
    public var zatenIletildi: Bool
    public var kanal: String

    enum CodingKeys: CodingKey { case note, cevap, iletim, zatenIletildi, kanal }

    public init(note: String, cevap: String, iletim: String, zatenIletildi: Bool, kanal: String) {
        self.note = note
        self.cevap = cevap
        self.iletim = iletim
        self.zatenIletildi = zatenIletildi
        self.kanal = kanal
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        cevap = try c.decodeIfPresent(String.self, forKey: .cevap) ?? ""
        iletim = try c.decodeIfPresent(String.self, forKey: .iletim) ?? ""
        zatenIletildi = try c.decodeIfPresent(Bool.self, forKey: .zatenIletildi) ?? false
        kanal = try c.decodeIfPresent(String.self, forKey: .kanal) ?? ""
    }
}

/// The data part of the `durum` skill. Every field is optional on the wire.
public struct OfisDurum: Decodable, Equatable, Sendable {
    public struct Adim: Decodable, Equatable, Sendable {
        /// `verildi`, `calisiyor`, `kontrol` or `ceo`.
        public var adim: String?
        public var etiket: String?
        /// What the job waits for ("senin cevabını bekliyor", …).
        public var not: String?
    }

    public struct Is: Decodable, Equatable, Sendable {
        public var not: String?
        public var baslik: String?
        public var proje: String?
        public var durum: String?
        public var adim: Adim?
        public var harcananUsd: Double?
        public var butceUsd: Double?
    }

    public struct Ceo: Decodable, Equatable, Sendable {
        public var durum: String?
        public var etiket: String?
        public var kuyruk: Int?
    }

    public struct Bugun: Decodable, Equatable, Sendable {
        public var gun: String?
        public var islerUsd: Double?
        public var ceoUsd: Double?
        public var toplamUsd: Double?
        /// `null` when unknown.
        public var toplamToken: Int?
    }

    public var calisan: [Is]
    public var sirada: [Is]
    public var bekleyenKarar: Int
    public var yuksekRiskliKarar: Int
    public var ceo: Ceo?
    public var bugun: Bugun?

    enum CodingKeys: CodingKey { case calisan, sirada, bekleyenKarar, yuksekRiskliKarar, ceo, bugun }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calisan = try c.decodeIfPresent([Is].self, forKey: .calisan) ?? []
        sirada = try c.decodeIfPresent([Is].self, forKey: .sirada) ?? []
        bekleyenKarar = try c.decodeIfPresent(Int.self, forKey: .bekleyenKarar) ?? 0
        yuksekRiskliKarar = try c.decodeIfPresent(Int.self, forKey: .yuksekRiskliKarar) ?? 0
        ceo = try c.decodeIfPresent(Ceo.self, forKey: .ceo)
        bugun = try c.decodeIfPresent(Bugun.self, forKey: .bugun)
    }
}
