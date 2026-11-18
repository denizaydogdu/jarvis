import Foundation
@testable import JarvisCore

/// A response the stub gives: HTTP status, headers, body. A thrown error fails the load (e.g. connection refused).
typealias OfisStubHandler = @Sendable (URLRequest, Data) throws -> (Int, [String: String], Data)

/// Shared state of `OfisStubProtocol`. Every suite that uses it is `.serialized` and lives in one suite,
/// so tests never see each other's handler.
final class OfisStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: OfisStubHandler?
    private var seen: [(URLRequest, Data)] = []

    func reset(_ h: @escaping OfisStubHandler) {
        lock.lock(); defer { lock.unlock() }
        handler = h
        seen = []
    }

    func current() -> OfisStubHandler? {
        lock.lock(); defer { lock.unlock() }
        return handler
    }

    func record(_ r: URLRequest, _ body: Data) {
        lock.lock(); defer { lock.unlock() }
        seen.append((r, body))
    }

    var requests: [(request: URLRequest, body: Data)] {
        lock.lock(); defer { lock.unlock() }
        return seen.map { (request: $0.0, body: $0.1) }
    }

    var posts: [(request: URLRequest, body: Data)] { requests.filter { $0.request.httpMethod == "POST" } }
    var cardGets: [(request: URLRequest, body: Data)] { requests.filter { $0.request.httpMethod == "GET" } }
}

let ofisStub = OfisStubState()

/// Answers every request of the session from `ofisStub`; nothing reaches the network.
final class OfisStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        ofisStub.record(request, body)
        guard let handler = ofisStub.current() else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (status, headers, data) = try handler(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// A clock the tests move by hand.
final class OfisTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ s: TimeInterval) { lock.lock(); current += s; lock.unlock() }
}

func ofisStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfisStubProtocol.self]
    return OfisClient.makeSession(configuration: config)
}

func ofisTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "ofis-tests-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

func json(_ s: String) -> Data { Data(s.utf8) }

func jsonObject(_ d: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
}

/// The JSON-RPC envelope with a `{"task": …}` result.
func rpcTask(_ task: String, id: Int = 1) -> Data {
    json(#"{"jsonrpc": "2.0", "id": \#(id), "result": {"task": \#(task)}}"#)
}

func ofisCard(port: Int, name: String = "Ofis", host: String = "127.0.0.1") -> Data {
    json(#"{"name": "\#(name)", "description": "Ajan ofisi", "url": "http://\#(host):\#(port)/a2a", "version": "1.0"}"#)
}

// MARK: - Samples from docs/gelistirici/jarvis-a2a.md (only the elided `"message": {…}` is left out)

let durumTaskSample = #"""
{"id": "t-durum", "contextId": "c1", "metadata": {"skill": "durum"},
  "status": {"state": "TASK_STATE_COMPLETED", "timestamp": "2026-11-14T16:47:38.510Z"},
  "artifacts": [{"artifactId": "a1", "name": "durum", "parts": [
    {"text": "Ofis durumu: 1 iş çalışıyor, 0 iş sırada.\n- blog — Giriş sayfası: blog ekibi çalışıyor\nBekleyen karar: 2 (1 tanesi yüksek riskli).\nCEO: boşta.\nBugünkü harcama: $0.41 · 182 bin token."},
    {"data": {
      "calisan": [{"not": "2026-11-14-100000-blog.md", "baslik": "Giriş sayfası", "proje": "blog",
                   "durum": "calisiyor", "adim": {"adim": "calisiyor", "etiket": "blog ekibi çalışıyor", "not": ""},
                   "harcanan_usd": 0.41, "butce_usd": 6.0}],
      "sirada": [],
      "bekleyen_karar": 2, "yuksek_riskli_karar": 1,
      "ceo": {"durum": "idle", "etiket": "boşta", "kuyruk": 0},
      "bugun": {"gun": "2026-11-14", "isler_usd": 0.41, "ceo_usd": 0.0, "toplam_usd": 0.41, "toplam_token": 182000}},
     "mediaType": "application/json"}]}]}
"""#

let kararlarDataSample = #"""
{"kararlar": [
  {"note": "2026-11-14-blog-ceo-sorusu.md", "baslik": "Test yaklaşımı", "proje": "blog", "tur": "ceo-sorusu",
   "soru": "Hangisini seçelim?", "secenekler": [{"kod": "A", "metin": "Birim testler"}, {"kod": "B", "metin": "Uçtan uca"}],
   "risk": "normal", "risk_nedeni": "", "ekran_onayi_gerekir": false, "soruldu": "2026-11-14T10:00",
   "cevap_iletildi": false},
  {"note": "2026-11-14-blog-push.md", "baslik": "blog — main", "proje": "blog", "tur": "proje-sorusu",
   "soru": "main dalına zorla gönderelim mi?", "secenekler": [], "risk": "yuksek",
   "risk_nedeni": "zorla gönderme ya da geçmişi yeniden yazma", "ekran_onayi_gerekir": true,
   "soruldu": "2026-11-14T11:00", "cevap_iletildi": false}]}
"""#

func kararlarTask(_ data: String = kararlarDataSample) -> String {
    #"""
    {"id": "t-kararlar", "contextId": "c2", "metadata": {"skill": "kararlar"},
     "status": {"state": "TASK_STATE_COMPLETED"},
     "artifacts": [{"artifactId": "a2", "name": "kararlar", "parts": [
       {"text": "Bekleyen karar: 2."}, {"data": \#(data), "mediaType": "application/json"}]}]}
    """#
}

let cevapCompletedTask = #"""
{"id": "t-cevap", "contextId": "c3", "metadata": {"skill": "karar-cevapla"},
 "status": {"state": "TASK_STATE_COMPLETED"},
 "artifacts": [{"artifactId": "a3", "name": "karar-cevapla", "parts": [
   {"text": "Cevap iletildi."},
   {"data": {"note": "2026-11-14-blog-ceo-sorusu.md", "cevap": "A) Birim testler", "iletim": "delivered",
             "zaten_iletildi": false, "kanal": "Jarvis üzerinden"}, "mediaType": "application/json"}]}]}
"""#

let inputRequiredTask = #"""
{"id": "t-risk", "contextId": "c4",
 "status": {"state": "TASK_STATE_INPUT_REQUIRED", "message": {"role": "ROLE_AGENT", "parts": [
  {"text": "Bu karar yüksek riskli (zorla gönderme ya da geçmişi yeniden yazma). Cevabı ekrandaki onay düğmesiyle ver; sesle onay yetmez."},
  {"data": {"kod": "ekran_onayi_gerekir", "note": "2026-11-14-blog-push.md", "risk": "yuksek", "risk_nedeni": "zorla gönderme ya da geçmişi yeniden yazma", "ekran_onayi_gerekir": true},
   "mediaType": "application/json"}]}}}
"""#

func statusTask(state: String, kod: String, text: String, id: String = "t-x") -> String {
    #"""
    {"id": "\#(id)", "contextId": "c5", "status": {"state": "\#(state)", "message": {"role": "ROLE_AGENT", "parts": [
      {"text": "\#(text)"}, {"data": {"kod": "\#(kod)"}, "mediaType": "application/json"}]}}}
    """#
}
