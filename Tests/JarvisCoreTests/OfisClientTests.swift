import Foundation
import Testing
@testable import JarvisCore

private let secret = "k-SECRET-0123456789abcdef"

private struct Fixture {
    let dir: String
    let keyPath: String
    let logPath: String
    let clock = OfisTestClock()

    init(key: String? = secret) throws {
        dir = try ofisTempDir()
        keyPath = dir + "/jarvis_anahtari"
        logPath = dir + "/jarvis.log"
        if let key { try (key + "\n").write(toFile: keyPath, atomically: true, encoding: .utf8) }
    }

    func client(burst: Int = OfisClient.defaultBurst,
                perSecond: Double = OfisClient.defaultRefillPerSecond) -> OfisClient {
        let clock = self.clock
        return OfisClient(keyPath: keyPath, session: ofisStubSession(), log: JarvisLog(path: logPath),
                          burst: burst, refillPerSecond: perSecond, now: { clock.now })
    }

    var log: String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
}

/// Gate on `port` whose POSTs are answered by `post`.
private func gate(port: Int = 8800, cardPorts: Set<Int>? = nil,
                  post: @escaping @Sendable (URLRequest, Data) throws -> (Int, [String: String], Data))
    -> OfisStubHandler {
    { request, body in
        let p = request.url?.port ?? 0
        if request.httpMethod == "GET" {
            guard (cardPorts ?? [port]).contains(p), request.url?.path == "/.well-known/agent-card.json" else {
                throw URLError(.cannotConnectToHost)
            }
            return (200, ["Content-Type": "application/json"], ofisCard(port: p))
        }
        guard p == port, request.url?.path == "/a2a" else { throw URLError(.cannotConnectToHost) }
        return try post(request, body)
    }
}

/// The ask of a card with these option codes (none: a yes/no card).
private func cardAsk(_ note: String = "n.md", codes: [String] = ["A", "B"]) -> OfisAsk {
    OfisCards.ask(for: OfisKarar(note: note, baslik: "b", proje: "p", tur: "ceo-sorusu", soru: "?",
                                 secenekler: codes.map { OfisSecenek(kod: $0, metin: "metin " + $0) }, risk: "normal",
                                 riskNedeni: "", ekranOnayiGerekir: false, soruldu: "", cevapIletildi: false))!
}

private func ok(_ task: String) -> (Int, [String: String], Data) {
    (200, ["Content-Type": "application/json"], rpcTask(task))
}

private func message(_ body: Data) -> [String: Any] {
    (jsonObject(body)["params"] as? [String: Any])?["message"] as? [String: Any] ?? [:]
}

private func dataPart(_ body: Data) -> [String: Any] {
    ((message(body)["parts"] as? [[String: Any]])?.first?["data"] as? [String: Any]) ?? [:]
}

/// Every test touching `OfisStubProtocol` lives here, serialized, so the shared stub handler is never raced.
@Suite(.serialized) struct OfisClientTests {

    // MARK: request shape

    @Test func durumRequestShapeAndParsing() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in ok(durumTaskSample) })
        let client = f.client()
        let (text, data) = try await client.durum()

        #expect(text.hasPrefix("Ofis durumu: 1 iş çalışıyor, 0 iş sırada."))
        #expect(data.calisan.count == 1)
        #expect(data.calisan.first?.not == "2026-11-14-100000-blog.md")
        #expect(data.calisan.first?.adim?.etiket == "blog ekibi çalışıyor")
        #expect(data.calisan.first?.harcananUsd == 0.41)
        #expect(data.calisan.first?.butceUsd == 6.0)
        #expect(data.sirada.isEmpty)
        #expect(data.bekleyenKarar == 2)
        #expect(data.yuksekRiskliKarar == 1)
        #expect(data.ceo?.etiket == "boşta")
        #expect(data.bugun?.toplamUsd == 0.41)
        #expect(data.bugun?.toplamToken == 182000)

        let card = try #require(ofisStub.cardGets.first)
        #expect(card.request.url?.absoluteString == "http://127.0.0.1:8800/.well-known/agent-card.json")
        #expect(card.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(card.request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(card.request.timeoutInterval == 0.3)

        let post = try #require(ofisStub.posts.first)
        #expect(ofisStub.posts.count == 1)
        #expect(post.request.url?.absoluteString == "http://127.0.0.1:8800/a2a")
        #expect(post.request.url?.host == "127.0.0.1")
        #expect(post.request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(post.request.allHTTPHeaderFields?.keys.contains { $0.lowercased() == "origin" } == false)
        #expect(post.request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
        #expect(post.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = jsonObject(post.body)
        #expect(body["jsonrpc"] as? String == "2.0")
        #expect(body["method"] as? String == "SendMessage")
        #expect(body["id"] != nil)
        let msg = message(post.body)
        #expect(msg["role"] as? String == "ROLE_USER")
        #expect((msg["messageId"] as? String)?.isEmpty == false)
        #expect(msg["taskId"] == nil)
        let parts = try #require(msg["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        #expect(parts.first?["text"] as? String == "durum")
    }

    @Test func messageIdsAreUniqueAndEndpointIsCached() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in ok(kararlarTask()) })
        let client = f.client()
        _ = try await client.kararlar()
        _ = try await client.kararlar()
        #expect(ofisStub.cardGets.count == 1)
        let ids = ofisStub.posts.compactMap { message($0.body)["messageId"] as? String }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(dataPart(ofisStub.posts[0].body)["skill"] as? String == "kararlar")
    }

    // MARK: discovery

    @Test func discoveryTakesFirstOfisCardAndForcesLoopbackHost() async throws {
        let f = try Fixture()
        ofisStub.reset { request, _ in
            let p = request.url?.port ?? 0
            if request.httpMethod == "GET" {
                switch p {
                case 8800...8802: throw URLError(.cannotConnectToHost)
                case 8803: return (200, [:], ofisCard(port: 8803, name: "Başka ajan"))
                case 8804: return (200, [:], ofisCard(port: 8804, host: "localhost"))
                case 8805: return (200, [:], ofisCard(port: 8805))
                default: throw URLError(.cannotConnectToHost)
                }
            }
            guard p == 8804 else { throw URLError(.cannotConnectToHost) }
            return ok(kararlarTask())
        }
        let client = f.client()
        _ = try await client.kararlar()
        #expect(ofisStub.cardGets.map { $0.request.url?.port ?? 0 } == [8800, 8801, 8802, 8803, 8804])
        #expect(ofisStub.posts.first?.request.url?.absoluteString == "http://127.0.0.1:8804/a2a")
    }

    @Test func cardWithForeignHostIsIgnored() async throws {
        let f = try Fixture()
        ofisStub.reset { request, _ in
            if request.httpMethod == "GET", request.url?.port == 8800 {
                return (200, [:], ofisCard(port: 8800, host: "evil.example.com"))
            }
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: OfisError.unreachable) { try await f.client().kararlar() }
        #expect(ofisStub.posts.isEmpty)
        #expect(ofisStub.cardGets.count == 20)
    }

    @Test func cachedEndpointFailingTriggersOneRediscovery() async throws {
        let f = try Fixture()
        let live = OfisPortBox(8800)
        ofisStub.reset { request, _ in
            let p = request.url?.port ?? 0
            guard p == live.port else { throw URLError(.cannotConnectToHost) }
            if request.httpMethod == "GET" { return (200, [:], ofisCard(port: p)) }
            return ok(kararlarTask())
        }
        let client = f.client()
        _ = try await client.kararlar()
        live.port = 8806          // the office restarted on another port
        _ = try await client.kararlar()
        let posts = ofisStub.posts.map { $0.request.url?.port ?? 0 }
        #expect(posts == [8800, 8800, 8806])
        // The retried POST reuses the messageId: the gate dedupes, nothing is done twice.
        let ids = ofisStub.posts.compactMap { message($0.body)["messageId"] as? String }
        #expect(ids[1] == ids[2])
        #expect(ids[0] != ids[1])
        #expect(ofisStub.cardGets.map { $0.request.url?.port ?? 0 } == [8800] + Array(8800...8806))
    }

    @Test func noGateIsUnreachableAndCard404IsGateOff() async throws {
        let f = try Fixture()
        ofisStub.reset { _, _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: OfisError.unreachable) { try await f.client().durum() }
        #expect(ofisStub.cardGets.map { $0.request.url?.port ?? 0 } == Array(8800...8819))

        ofisStub.reset { request, _ in
            if request.url?.port == 8800 { return (404, [:], Data()) }
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: OfisError.gateOff) { try await f.client().durum() }
        #expect(ofisStub.posts.isEmpty)
    }

    // MARK: HTTP errors

    @Test func http404IsGateOff() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in (404, [:], Data()) })
        await #expect(throws: OfisError.gateOff) { try await f.client().kararlar() }
        #expect(ofisStub.posts.count == 1)
    }

    @Test func unauthorizedRereadsKeyAndRetriesOnce() async throws {
        let f = try Fixture(key: "old-key")
        let keyPath = f.keyPath
        ofisStub.reset(gate { request, _ in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-key" {
                try "new-key\n".write(toFile: keyPath, atomically: true, encoding: .utf8)  // regenerated
                return (401, [:], Data())
            }
            return ok(kararlarTask())
        })
        let kararlar = try await f.client().kararlar()
        #expect(kararlar.count == 2)
        #expect(ofisStub.posts.map { $0.request.value(forHTTPHeaderField: "Authorization") ?? "" }
                == ["Bearer old-key", "Bearer new-key"])
        let ids = ofisStub.posts.compactMap { message($0.body)["messageId"] as? String }
        #expect(ids.count == 2 && ids[0] == ids[1])
    }

    @Test func secondUnauthorizedGivesUp() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in (401, [:], Data()) })
        await #expect(throws: OfisError.unauthorized) { try await f.client().kararlar() }
        #expect(ofisStub.posts.count == 2)
    }

    @Test func missingKeyFileIsUnauthorizedWithoutSending() async throws {
        let f = try Fixture(key: nil)
        ofisStub.reset(gate { _, _ in ok(kararlarTask()) })
        await #expect(throws: OfisError.unauthorized) { try await f.client().kararlar() }
        #expect(ofisStub.posts.isEmpty)
    }

    @Test func tooManyRequestsBacksOffForRetryAfter() async throws {
        let f = try Fixture()
        let limited = OfisPortBox(1)
        ofisStub.reset(gate { _, _ in
            limited.port == 1 ? (429, ["Retry-After": "60"], Data()) : ok(kararlarTask())
        })
        let client = f.client()
        await #expect(throws: OfisError.rateLimited(retryAfter: 60)) { try await client.kararlar() }
        #expect(ofisStub.posts.count == 1)
        limited.port = 0
        f.clock.advance(20)
        // Still backing off: nothing is sent, the remaining wait is reported.
        await #expect(throws: OfisError.rateLimited(retryAfter: 40)) { try await client.kararlar() }
        #expect(ofisStub.posts.count == 1)
        f.clock.advance(40)
        _ = try await client.kararlar()
        #expect(ofisStub.posts.count == 2)
    }

    @Test func missingRetryAfterDefaultsToSixtySeconds() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in (429, [:], Data()) })
        await #expect(throws: OfisError.rateLimited(retryAfter: 60)) { try await f.client().kararlar() }
    }

    @Test func clientSideTokenBucket() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in ok(kararlarTask()) })
        let client = f.client(burst: 4, perSecond: 0.05)
        // The card GET takes the first permit, then three POSTs.
        for _ in 0..<3 { _ = try await client.kararlar() }
        await #expect(throws: OfisError.rateLimited(retryAfter: 20)) { try await client.kararlar() }
        #expect(ofisStub.posts.count == 3)
        f.clock.advance(20)
        _ = try await client.kararlar()
        #expect(ofisStub.posts.count == 4)
        #expect(OfisClient.defaultBurst == 10)
        #expect(OfisClient.defaultRefillPerSecond == 0.5)
    }

    @Test func otherHttpStatusIsBadResponse() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in (403, [:], Data()) })
        await #expect(throws: OfisError.badResponse(status: 403)) { try await f.client().kararlar() }
        ofisStub.reset(gate { _, _ in (200, [:], json("not json")) })
        await #expect(throws: OfisError.badResponse(status: 200)) { try await f.client().kararlar() }
    }

    // MARK: skills and task states

    @Test func kararlarParsesDocSample() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in ok(kararlarTask()) })
        let kararlar = try await f.client().kararlar()
        #expect(kararlar.count == 2)
        let a = kararlar[0]
        #expect(a.note == "2026-11-14-blog-ceo-sorusu.md")
        #expect(a.baslik == "Test yaklaşımı")
        #expect(a.proje == "blog")
        #expect(a.tur == "ceo-sorusu")
        #expect(a.soru == "Hangisini seçelim?")
        #expect(a.secenekler == [OfisSecenek(kod: "A", metin: "Birim testler"), OfisSecenek(kod: "B", metin: "Uçtan uca")])
        #expect(a.risk == "normal")
        #expect(!a.isHighRisk)
        #expect(a.ekranOnayiGerekir == false)
        #expect(a.soruldu == "2026-11-14T10:00")
        #expect(a.cevapIletildi == false)
        let b = kararlar[1]
        #expect(b.secenekler.isEmpty)
        #expect(b.risk == "yuksek")
        #expect(b.isHighRisk)
        #expect(b.riskNedeni == "zorla gönderme ya da geçmişi yeniden yazma")
        #expect(b.ekranOnayiGerekir)
    }

    @Test func malformedCardIsSkippedNotFatal() async throws {
        let f = try Fixture()
        let data = #"{"kararlar": [{"baslik": "no note"}, {"note": "ok.md", "soru": "?"}]}"#
        ofisStub.reset(gate { _, _ in ok(kararlarTask(data)) })
        let kararlar = try await f.client().kararlar()
        #expect(kararlar.map(\.note) == ["ok.md"])
    }

    @Test func cevaplaSendsCodeAndParsesResult() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in ok(cevapCompletedTask) })
        let result = try await f.client().cevapla(ask: cardAsk("2026-11-14-blog-ceo-sorusu.md"), cevap: "A",
                                                  ekranOnayi: false)
        #expect(result == OfisCevapSonucu(note: "2026-11-14-blog-ceo-sorusu.md", cevap: "A) Birim testler",
                                          iletim: "delivered", zatenIletildi: false, kanal: "Jarvis üzerinden"))
        let post = try #require(ofisStub.posts.first)
        let d = dataPart(post.body)
        #expect(d["skill"] as? String == "karar-cevapla")
        #expect(d["note"] as? String == "2026-11-14-blog-ceo-sorusu.md")
        #expect(d["cevap"] as? String == "A")
        let flag = try #require(d["ekran_onayi"] as? NSNumber)
        #expect(CFGetTypeID(flag) == CFBooleanGetTypeID() && flag.boolValue == false)
    }

    @Test func onlyTheCardsOwnAnswersAreSent() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in ok(cevapCompletedTask) })
        let client = f.client()
        let choice = cardAsk("c.md", codes: ["A", "b2"])
        let yesNo = cardAsk("y.md", codes: [])
        let refused: [(OfisAsk, String)] = [
            (choice, ""), (choice, "push et lütfen"), (choice, "A\nB"), (choice, "B"), (choice, "a"),
            (choice, "A) metin A"), (choice, "Evet"), (choice, "Hayır"),
            (yesNo, "evet"), (yesNo, "A"), (yesNo, "Evet, push et"), (yesNo, ""),
        ]
        for (ask, bad) in refused {
            await #expect(throws: OfisError.invalidAnswer) {
                try await client.cevapla(ask: ask, cevap: bad, ekranOnayi: false)
            }
        }
        #expect(ofisStub.requests.isEmpty)
        for (ask, good) in [(yesNo, "Evet"), (yesNo, "Hayır"), (choice, "A"), (choice, "b2")] {
            _ = try await client.cevapla(ask: ask, cevap: good, ekranOnayi: false)
        }
        #expect(ofisStub.posts.compactMap { dataPart($0.body)["cevap"] as? String } == ["Evet", "Hayır", "A", "b2"])
        #expect(ofisStub.posts.compactMap { dataPart($0.body)["note"] as? String } == ["y.md", "y.md", "c.md", "c.md"])
    }

    @Test func inputRequiredThenOnayla() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, body in
            message(body)["taskId"] == nil ? ok(inputRequiredTask) : ok(cevapCompletedTask)
        })
        let client = f.client()
        do {
            _ = try await client.cevapla(ask: cardAsk("2026-11-14-blog-push.md", codes: []), cevap: "Evet",
                                       ekranOnayi: false)
            Issue.record("expected inputRequired")
        } catch let e as OfisError {
            guard case .inputRequired(let kod, let text, let taskId) = e else {
                Issue.record("wrong error \(e)"); return
            }
            #expect(kod == "ekran_onayi_gerekir")
            #expect(text.hasPrefix("Bu karar yüksek riskli"))
            #expect(taskId == "t-risk")
        }
        let result = try await client.onayla(taskId: "t-risk")
        #expect(result.iletim == "delivered")
        let msg = message(ofisStub.posts[1].body)
        #expect(msg["taskId"] as? String == "t-risk")
        #expect(msg["role"] as? String == "ROLE_USER")
        let parts = try #require(msg["parts"] as? [[String: Any]])
        #expect(parts.count == 1)
        let d = try #require(parts.first?["data"] as? [String: Any])
        #expect(d.count == 1)
        #expect((d["ekran_onayi"] as? NSNumber)?.boolValue == true)
    }

    @Test func rejectedFailedAndRpcErrors() async throws {
        let f = try Fixture()
        let client = f.client()
        ofisStub.reset(gate { _, _ in ok(statusTask(state: "TASK_STATE_REJECTED", kod: "cevaplanmis", text: "Zaten cevaplanmış.")) })
        await #expect(throws: OfisError.rejected(kod: "cevaplanmis", text: "Zaten cevaplanmış.")) {
            try await client.cevapla(ask: cardAsk(), cevap: "A", ekranOnayi: false)
        }
        ofisStub.reset(gate { _, _ in ok(statusTask(state: "TASK_STATE_FAILED", kod: "ceo-ulasilamiyor", text: "CEO yok.")) })
        await #expect(throws: OfisError.failed(kod: "ceo-ulasilamiyor")) {
            try await client.cevapla(ask: cardAsk(), cevap: "A", ekranOnayi: false)
        }
        ofisStub.reset(gate { _, _ in
            (200, [:], json(#"{"jsonrpc": "2.0", "id": 1, "error": {"code": -32602, "message": "bad params"}}"#))
        })
        await #expect(throws: OfisError.rpc(code: -32602)) { try await client.kararlar() }
    }

    // MARK: follow-up: cancellation, resend, empty task id, bucket, undecodable cards

    @Test func cancelledPostRethrowsCancellationAndKeepsTheEndpoint() async throws {
        let f = try Fixture()
        let cancel = OfisPortBox(0)
        ofisStub.reset(gate { _, _ in
            if cancel.port == 1 { throw URLError(.cancelled) }
            return ok(kararlarTask())
        })
        let client = f.client()
        _ = try await client.kararlar()
        cancel.port = 1
        await #expect(throws: CancellationError.self) { try await client.kararlar() }
        #expect(ofisStub.posts.count == 2)
        #expect(ofisStub.cardGets.count == 1)  // no rediscovery
        cancel.port = 0
        _ = try await client.kararlar()
        #expect(ofisStub.cardGets.count == 1)  // the endpoint is still cached
        #expect(ofisStub.posts.count == 3)
    }

    @Test func cancelledTaskIsCancellationNotUnreachable() async throws {
        let f = try Fixture()
        ofisStub.reset(gate { _, _ in ok(kararlarTask()) })
        let client = f.client()
        // During discovery: no card is asked, nothing becomes `.unreachable`.
        let fresh = Task { () async throws -> [OfisKarar] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.kararlar()
        }
        let first = await fresh.result
        #expect(throws: CancellationError.self) { try first.get() }
        #expect(ofisStub.requests.isEmpty)

        // With a cached endpoint: nothing is sent and the endpoint stays.
        _ = try await client.kararlar()
        let cached = Task { () async throws -> [OfisKarar] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.kararlar()
        }
        let second = await cached.result
        #expect(throws: CancellationError.self) { try second.get() }
        #expect(ofisStub.posts.count == 1)
        _ = try await client.kararlar()
        #expect(ofisStub.cardGets.count == 1)
    }

    @Test func postThatMayHaveReachedTheGateIsNeverResent() async throws {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .badServerResponse] {
            let f = try Fixture()
            let failing = OfisPortBox(0)
            ofisStub.reset(gate { _, _ in
                if failing.port == 1 { throw URLError(code) }
                return ok(kararlarTask())
            })
            let client = f.client()
            _ = try await client.kararlar()
            failing.port = 1
            await #expect(throws: OfisError.unreachable) { try await client.kararlar() }
            #expect(ofisStub.posts.count == 2, "resent after \(code)")
            #expect(ofisStub.cardGets.count == 1, "rediscovered after \(code)")
        }
    }

    @Test func refusedConnectionRediscoversAndResends() async throws {
        for refusal: Error in [URLError(.cannotFindHost),
                               NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)),
                               URLError(.unknown, userInfo: [NSUnderlyingErrorKey:
                                   NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))])] {
            let f = try Fixture()
            let refusing = OfisPortBox(0)
            ofisStub.reset(gate { _, _ in
                if refusing.port == 1 { refusing.port = 0; throw refusal }
                return ok(kararlarTask())
            })
            let client = f.client()
            _ = try await client.kararlar()
            refusing.port = 1
            _ = try await client.kararlar()
            #expect(ofisStub.posts.count == 3, "not resent after \(refusal)")
            #expect(ofisStub.cardGets.count == 2)
        }
    }

    @Test func inputRequiredWithoutTaskIdIsBadResponse() async throws {
        let f = try Fixture()
        let client = f.client()
        let noId = #"{"status": {"state": "TASK_STATE_INPUT_REQUIRED", "message": {"parts": [{"data": {"kod": "ekran_onayi_gerekir"}}]}}}"#
        for task in [noId, statusTask(state: "TASK_STATE_INPUT_REQUIRED", kod: "ekran_onayi_gerekir", text: "x", id: "")] {
            ofisStub.reset(gate { _, _ in ok(task) })
            await #expect(throws: OfisError.badResponse(status: 200)) {
                try await client.cevapla(ask: cardAsk(codes: []), cevap: "Evet", ekranOnayi: false)
            }
        }
    }

    @Test func cardGetsTakePermitsButRefusedPortsGiveThemBack() async throws {
        let f = try Fixture()
        // The gate on 8815: fifteen refused ports, one card, then POSTs, with only three permits.
        ofisStub.reset(gate(port: 8815) { _, _ in ok(kararlarTask()) })
        let client = f.client(burst: 3, perSecond: 0.05)
        _ = try await client.kararlar()
        _ = try await client.kararlar()
        #expect(ofisStub.cardGets.count == 16)
        await #expect(throws: OfisError.rateLimited(retryAfter: 20)) { try await client.kararlar() }
        #expect(ofisStub.posts.count == 2)

        // A card GET that got an answer keeps its permit; an empty bucket stops the scan.
        let g = try Fixture()
        ofisStub.reset { request, _ in
            if request.httpMethod == "GET" { return (200, [:], ofisCard(port: 8800, name: "Başka")) }
            throw URLError(.cannotConnectToHost)
        }
        await #expect(throws: OfisError.rateLimited(retryAfter: 20)) { try await g.client(burst: 3, perSecond: 0.05).kararlar() }
        #expect(ofisStub.cardGets.count == 3)
    }

    @Test func undecodableCardIsLoggedOncePerNote() async throws {
        let f = try Fixture()
        let data = #"{"kararlar": [{"baslik": "no note"}, {"note": "bad.md", "secenekler": "x"}, {"note": "ok.md"}]}"#
        ofisStub.reset(gate { _, _ in ok(kararlarTask(data)) })
        let client = f.client()
        #expect(try await client.kararlar().map(\.note) == ["ok.md"])
        #expect(try await client.kararlar().map(\.note) == ["ok.md"])
        let lines = f.log.split(separator: "\n").filter { $0.contains("undecodable") }
        #expect(lines.count == 2)
        #expect(lines.contains { $0.hasSuffix("\tofis: skipped #0: undecodable") })
        #expect(lines.contains { $0.hasSuffix("\tofis: skipped bad.md: undecodable") })
    }

    // MARK: the key never leaks

    @Test func keyNeverAppearsInErrorsLogsOrAsks() async throws {
        let f = try Fixture()
        // A hostile or buggy gate echoing the Authorization header back in every text it returns.
        let echo: @Sendable (URLRequest) -> String = { $0.value(forHTTPHeaderField: "Authorization") ?? "" }
        var descriptions: [String] = []
        func collect(_ body: () async throws -> Void) async {
            do { try await body() } catch { descriptions.append("\(error)"); descriptions.append(error.localizedDescription)
                                            descriptions.append(String(reflecting: error)) }
        }
        let client = f.client()

        ofisStub.reset(gate { r, _ in ok(statusTask(state: "TASK_STATE_REJECTED", kod: echo(r), text: "anahtar " + echo(r))) })
        await collect { _ = try await client.kararlar() }
        ofisStub.reset(gate { r, _ in ok(statusTask(state: "TASK_STATE_INPUT_REQUIRED", kod: echo(r), text: echo(r), id: echo(r))) })
        await collect { _ = try await client.cevapla(ask: cardAsk(), cevap: "A", ekranOnayi: false) }
        ofisStub.reset(gate { r, _ in ok(statusTask(state: "TASK_STATE_FAILED", kod: echo(r), text: echo(r))) })
        await collect { _ = try await client.kararlar() }
        ofisStub.reset(gate { _, _ in (401, [:], Data()) })
        await collect { _ = try await client.kararlar() }
        ofisStub.reset(gate { _, _ in (404, [:], Data()) })
        await collect { _ = try await client.kararlar() }
        ofisStub.reset(gate { _, _ in (500, [:], Data()) })
        await collect { _ = try await client.kararlar() }
        ofisStub.reset(gate { _, _ in (429, ["Retry-After": "5"], Data()) })
        await collect { _ = try await client.kararlar() }
        f.clock.advance(10)
        ofisStub.reset { _, _ in throw URLError(.cannotConnectToHost) }
        await collect { _ = try await client.kararlar() }
        #expect(descriptions.count == 24)

        // Echoed into a card: neither the parsed card nor the ask built from it carry the key.
        let card = #"{"kararlar": [{"note": "n.md", "baslik": "KEY", "proje": "KEY", "soru": "KEY?", "secenekler": [{"kod": "A", "metin": "KEY"}], "risk": "yuksek", "risk_nedeni": "KEY"}]}"#
        f.clock.advance(120)
        ofisStub.reset(gate { r, _ in ok(kararlarTask(card.replacingOccurrences(of: "KEY", with: echo(r)))) })
        let kararlar = try await client.kararlar()
        let first = try #require(kararlar.first)
        let ask = try #require(OfisCards.ask(for: first))
        let askText = "\(ask)" + ask.speech + ask.question.question + ask.question.header
            + ask.options.map { $0.label + $0.answer }.joined() + (ask.riskLine ?? "") + "\(kararlar)"
        #expect(askText.contains("Bearer"))  // the echo did arrive…
        #expect(!askText.contains(secret))   // …but without the key

        for d in descriptions { #expect(!d.contains(secret), "leaked in: \(d)") }
        #expect(!f.log.contains(secret))
        #expect(!"\(client)".contains(secret))
    }

    @Test func standardPaths() {
        #expect(OfisClient.standardKeyPath(home: "/Users/x") == "/Users/x/Dev/ajan-ofisi/durum/jarvis_anahtari")
        #expect(OfisClient.defaultPorts == 8800...8819)
    }

    @Test func standardKeyPathFollowsTheOfisDirSetting() throws {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: h + "/.jarvis", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: h) }
        try "~/code/ofis\n".write(toFile: h + "/.jarvis/ofis-dir", atomically: true, encoding: .utf8)
        #expect(OfisClient.standardKeyPath(home: h) == h + "/code/ofis/durum/jarvis_anahtari")
    }
}

/// A mutable Int shared with a stub handler.
final class OfisPortBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ v: Int) { value = v }
    var port: Int {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
