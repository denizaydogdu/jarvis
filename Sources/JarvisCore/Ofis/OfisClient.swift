import Foundation

/// Client of the Ofis Jarvis gate (A2A 1.0 JSON-RPC over HTTP on 127.0.0.1).
///
/// - The endpoint comes from the Agent Card on 127.0.0.1:8800…8819 (first card named "Ofis") and is cached;
///   the ports are scanned again only when the cached endpoint stops answering.
/// - The key file is read for every request and once more after a 401. The key goes only into the
///   `Authorization` header: it is never stored, logged or put into an error, and it is redacted from every
///   gate response before parsing, so an echoing gate cannot leak it either.
/// - No `Origin` header, host always `127.0.0.1`, no cookies, no cache, no redirects.
/// - A POST is sent again (after a rediscovery) only when it certainly never reached a server: the
///   connection was refused or the host not found. A timeout, a lost connection or any received response
///   is never resent (a 401 is the one exception: the gate refused it before doing anything). A resend
///   reuses the same `messageId`, so the gate returns the same task without doing anything twice.
/// - Cancellation (the calling task, `CancellationError`, `URLError.cancelled`) rethrows as
///   `CancellationError`; it never clears the cached endpoint, rediscovers or becomes `.unreachable`.
/// - A token bucket of `burst` permits refilled at `refillPerSecond` (10 and 0.5/s: 30 a minute
///   sustained). Every POST and every Agent Card GET takes one; a card GET whose connection was refused
///   reached no server and gives its permit back. After a 429 nothing is sent until `Retry-After` has
///   passed. Both throw `OfisError.rateLimited` without touching the network.
public actor OfisClient {
    public static let defaultPorts = 8800...8819
    public static let defaultBurst = 10
    public static let defaultRefillPerSecond = 0.5
    /// Per-port timeout of the Agent Card scan.
    public static let cardTimeout: TimeInterval = 0.3
    static let requestTimeout: TimeInterval = 5
    static let defaultRetryAfter: TimeInterval = 60

    /// `<Ofis folder>/durum/jarvis_anahtari`; the folder comes from `JarvisPaths.ofisDir`
    /// (`~/.jarvis/ofis-dir`, default `~/Dev/ajan-ofisi`).
    public static func standardKeyPath(home: String) -> String {
        JarvisPaths.ofisDir(home: home) + "/durum/jarvis_anahtari"
    }

    /// An ephemeral session for the gate: no cookies, no cache, no credential storage, short timeouts.
    public static func makeSession(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private let keyPath: String
    private let session: URLSession
    private let ports: ClosedRange<Int>
    private let log: JarvisLog?
    private let now: @Sendable () -> Date
    private var bucket: RequestBucket
    private var blockedUntil: Date?
    private var endpoint: URL?
    private var rpcID = 0
    /// Notes (or `#index`) of undecodable cards already logged in this run.
    private var loggedUndecodable: Set<String> = []

    public init(keyPath: String, session: URLSession = OfisClient.makeSession(),
                ports: ClosedRange<Int> = OfisClient.defaultPorts, log: JarvisLog? = nil,
                burst: Int = OfisClient.defaultBurst, refillPerSecond: Double = OfisClient.defaultRefillPerSecond,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.keyPath = keyPath
        self.session = session
        self.ports = ports
        self.log = log
        self.now = now
        bucket = RequestBucket(capacity: Double(max(1, burst)), perSecond: max(0.001, refillPerSecond), start: now())
    }

    // MARK: skills

    /// The `durum` skill: the Turkish text to read aloud and the same content as data.
    public func durum() async throws -> (text: String, data: OfisDurum) {
        let artifact = try await completed(parts: [["text": "durum"]])
        guard let data = artifact.data, let durum = try? OfisJSON.decoder.decode(OfisDurum.self, from: data) else {
            throw OfisError.badResponse(status: 200)
        }
        return (artifact.text, durum)
    }

    /// The `kararlar` skill. A card that cannot be decoded is left out (it stays on the page) and logged
    /// once per note as `ofis: skipped <note|#index>: undecodable`.
    public func kararlar() async throws -> [OfisKarar] {
        let artifact = try await completed(parts: [["data": ["skill": "kararlar"]]])
        guard let data = artifact.data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["kararlar"] as? [Any] else { throw OfisError.badResponse(status: 200) }
        var result: [OfisKarar] = []
        for (index, item) in raw.enumerated() {
            if let d = try? JSONSerialization.data(withJSONObject: item),
               let karar = try? OfisJSON.decoder.decode(OfisKarar.self, from: d) {
                result.append(karar)
                continue
            }
            let note = ((item as? [String: Any])?["note"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let name = note.map(JarvisLog.field) ?? "#\(index)"
            if loggedUndecodable.insert(name).inserted { log?.append("ofis: skipped \(name): undecodable") }
        }
        return result
    }

    /// The `karar-cevapla` skill for the card behind `ask`. `cevap` must be one of that card's own
    /// answers (`ask.options[].answer`: an option code, or "Evet"/"Hayır" for a card without options);
    /// anything else throws `invalidAnswer` and nothing is sent. `ekranOnayi` is true only after the
    /// on-screen hold-to-confirm, never after a voice answer.
    public func cevapla(ask: OfisAsk, cevap: String, ekranOnayi: Bool) async throws -> OfisCevapSonucu {
        guard !ask.note.isEmpty, OfisCards.isSendable(cevap), ask.options.contains(where: { $0.answer == cevap }) else {
            throw OfisError.invalidAnswer
        }
        let part: [String: Any] = ["skill": "karar-cevapla", "note": ask.note, "cevap": cevap, "ekran_onayi": ekranOnayi]
        return try await cevapSonucu(parts: [["data": part]], taskId: nil)
    }

    /// Continues an input-required `karar-cevapla` task with `{"ekran_onayi": true}` (the gate remembers the
    /// note and the answer). Only after the on-screen hold-to-confirm.
    public func onayla(taskId: String) async throws -> OfisCevapSonucu {
        try await cevapSonucu(parts: [["data": ["ekran_onayi": true]]], taskId: taskId)
    }

    private func cevapSonucu(parts: [[String: Any]], taskId: String?) async throws -> OfisCevapSonucu {
        let artifact = try await completed(parts: parts, taskId: taskId)
        guard let data = artifact.data,
              let result = try? OfisJSON.decoder.decode(OfisCevapSonucu.self, from: data) else {
            throw OfisError.badResponse(status: 200)
        }
        return result
    }

    // MARK: JSON-RPC

    struct Artifact {
        var text: String
        var data: Data?
    }

    /// Sends one `SendMessage` and returns the artifact of a completed task; every other outcome throws.
    private func completed(parts: [[String: Any]], taskId: String? = nil) async throws -> Artifact {
        rpcID += 1
        var message: [String: Any] = ["messageId": UUID().uuidString.lowercased(), "role": "ROLE_USER", "parts": parts]
        if let taskId { message["taskId"] = taskId }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": rpcID, "method": "SendMessage",
                                       "params": ["message": message]]
        let body = try JSONSerialization.data(withJSONObject: envelope)
        let response = try await post(body)
        return try Self.artifact(from: response)
    }

    static func artifact(from body: Data) throws -> Artifact {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw OfisError.badResponse(status: 200)
        }
        if let error = obj["error"] as? [String: Any] {
            throw OfisError.rpc(code: (error["code"] as? Int) ?? 0)
        }
        guard let result = obj["result"] as? [String: Any], let task = result["task"] as? [String: Any],
              let status = task["status"] as? [String: Any], let state = status["state"] as? String else {
            throw OfisError.badResponse(status: 200)
        }
        let statusParts = (status["message"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let statusText = text(of: statusParts)
        let kod = (dataPart(of: statusParts)?["kod"] as? String) ?? ""
        switch state {
        case "TASK_STATE_COMPLETED":
            guard let artifacts = task["artifacts"] as? [[String: Any]],
                  let parts = artifacts.first?["parts"] as? [[String: Any]] else {
                throw OfisError.badResponse(status: 200)
            }
            let data = dataPart(of: parts).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            return Artifact(text: text(of: parts), data: data)
        case "TASK_STATE_REJECTED":
            throw OfisError.rejected(kod: kod, text: statusText)
        case "TASK_STATE_INPUT_REQUIRED":
            // Without a task id it could never be continued.
            guard let taskId = task["id"] as? String, !taskId.isEmpty else { throw OfisError.badResponse(status: 200) }
            throw OfisError.inputRequired(kod: kod, text: statusText, taskId: taskId)
        case "TASK_STATE_FAILED":
            throw OfisError.failed(kod: kod)
        default:
            // The gate only returns final or input-required tasks.
            throw OfisError.badResponse(status: 200)
        }
    }

    private static func text(of parts: [[String: Any]]) -> String {
        parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func dataPart(of parts: [[String: Any]]) -> [String: Any]? {
        parts.lazy.compactMap { $0["data"] as? [String: Any] }.first
    }

    // MARK: HTTP

    /// POSTs `body` to the endpoint and returns the (key-redacted) 200 body. Handles discovery, one
    /// rediscovery after a transport failure, one key re-read after a 401, 404, 429 and the client limit.
    private func post(_ body: Data) async throws -> Data {
        var rediscovered = false
        var reauthorized = false
        while true {
            try Task.checkCancellation()
            let url: URL
            if let cached = endpoint {
                url = cached
            } else {
                url = try await discover()
                rediscovered = true
            }
            try takePermit()
            guard let key = readKey() else { throw OfisError.unauthorized }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: Self.requestTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.httpShouldHandleCookies = false
            request.httpBody = body

            let data: Data
            let http: HTTPURLResponse
            do {
                let (d, r) = try await session.data(for: request, delegate: NoRedirect.shared)
                guard let h = r as? HTTPURLResponse else { throw OfisError.badResponse(status: 0) }
                data = d
                http = h
            } catch let e as OfisError {
                throw e
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                // It may have reached the gate (timeout, lost connection): never resend.
                guard Self.neverReachedServer(error) else { throw OfisError.unreachable }
                endpoint = nil
                if rediscovered { throw OfisError.unreachable }
                continue  // nothing listens on the cached endpoint: scan the ports once more
            }

            switch http.statusCode {
            case 200:
                return Self.redact(key, in: data)
            case 401:
                if reauthorized { throw OfisError.unauthorized }
                reauthorized = true  // the key file may have been regenerated: read it again
            case 404:
                throw OfisError.gateOff
            case 429:
                let wait = Self.retryAfter(http)
                blockedUntil = now() + wait
                log?.append("ofis: gate rate limited for \(Int(wait)) s")
                throw OfisError.rateLimited(retryAfter: wait)
            default:
                throw OfisError.badResponse(status: http.statusCode)
            }
        }
    }

    private func takePermit() throws {
        let t = now()
        if let until = blockedUntil {
            if t < until { throw OfisError.rateLimited(retryAfter: until.timeIntervalSince(t)) }
            blockedUntil = nil
        }
        if let wait = bucket.take(at: t) { throw OfisError.rateLimited(retryAfter: wait) }
    }

    private func readKey() -> String? {
        guard let raw = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A key that would break the header line is not a key.
        guard !key.isEmpty, !key.contains(where: { $0.isNewline }) else { return nil }
        return key
    }

    static func isCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// True only for failures where the request certainly reached no server: connection refused or the
    /// host not found. Everything else (timeout, lost connection, …) may have been received.
    static func neverReachedServer(_ error: Error) -> Bool {
        if let code = (error as? URLError)?.code, code == .cannotConnectToHost || code == .cannotFindHost {
            return true
        }
        var current: NSError? = error as NSError
        for _ in 0..<4 {
            guard let e = current else { break }
            if e.domain == NSPOSIXErrorDomain, e.code == Int(ECONNREFUSED) { return true }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let s = TimeInterval(raw.trimmingCharacters(in: .whitespaces)), s > 0, s.isFinite else {
            return defaultRetryAfter
        }
        return min(s, 3600)
    }

    /// The response body with every occurrence of the key replaced. JSON never escapes the characters a
    /// key file holds, so a textual replacement covers every string in the body.
    static func redact(_ key: String, in data: Data) -> Data {
        guard !key.isEmpty, let text = String(data: data, encoding: .utf8), text.contains(key) else { return data }
        return Data(text.replacingOccurrences(of: key, with: "[gizli]").utf8)
    }

    // MARK: discovery

    /// Scans the ports for the first Agent Card named "Ofis" and caches its endpoint (host forced to
    /// 127.0.0.1). A card endpoint answering 404 means the gate is off.
    private func discover() async throws -> URL {
        var sawGateOff = false
        for port in ports {
            try Task.checkCancellation()
            guard let cardURL = URL(string: "http://127.0.0.1:\(port)/.well-known/agent-card.json") else { continue }
            var request = URLRequest(url: cardURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: Self.cardTimeout)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            try takePermit()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request, delegate: NoRedirect.shared)
            } catch {
                if Self.isCancellation(error) { throw CancellationError() }
                if Self.neverReachedServer(error) { bucket.giveBack() }
                continue
            }
            guard let http = response as? HTTPURLResponse else { continue }
            if http.statusCode == 404 { sawGateOff = true; continue }
            guard http.statusCode == 200, let url = Self.endpoint(fromCard: data) else { continue }
            endpoint = url
            log?.append("ofis: gate found on port \(url.port ?? port)")
            return url
        }
        throw sawGateOff ? OfisError.gateOff : OfisError.unreachable
    }

    /// The JSON-RPC endpoint of an "Ofis" card: its `url` (or the first `supportedInterfaces[].url`), only
    /// when it is plain http on a loopback host; the host is always rewritten to 127.0.0.1.
    static func endpoint(fromCard data: Data) -> URL? {
        guard let card = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              card["name"] as? String == "Ofis" else { return nil }
        let interfaces = card["supportedInterfaces"] as? [[String: Any]] ?? []
        guard let raw = (card["url"] as? String) ?? interfaces.lazy.compactMap({ $0["url"] as? String }).first,
              var parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "http",
              let host = parts.host?.lowercased(), host == "127.0.0.1" || host == "localhost",
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}

/// A bucket of request permits: `capacity` at once, refilled at `perSecond`.
struct RequestBucket: Sendable {
    let capacity: Double
    let perSecond: Double
    private var permits: Double
    private var last: Date

    init(capacity: Double, perSecond: Double, start: Date) {
        self.capacity = capacity
        self.perSecond = perSecond
        permits = capacity
        last = start
    }

    /// Takes one permit; nil when taken, else the seconds until one is available.
    mutating func take(at date: Date) -> TimeInterval? {
        let elapsed = max(0, date.timeIntervalSince(last))
        permits = Swift.min(capacity, permits + elapsed * perSecond)
        last = Swift.max(last, date)
        if permits >= 1 {
            permits -= 1
            return nil
        }
        return (1 - permits) / perSecond
    }

    /// Returns a permit taken for a request that reached no server.
    mutating func giveBack() {
        permits = Swift.min(capacity, permits + 1)
    }
}

/// Refuses every redirect, so the `Authorization` header never follows one anywhere.
private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
