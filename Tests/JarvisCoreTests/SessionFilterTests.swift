import Testing
import Foundation
@testable import JarvisCore

@Suite struct SessionFilterTests {
    let home = "/Users/u"
    let prefixes = ["~/Dev/bim"]

    func ctx(cwd: String = "/Users/u/Dev/jarvis", sid: String = "s1",
             env: [String: String] = [:], tool: String? = nil) -> SessionContext {
        SessionContext(cwd: cwd, sessionId: sid, env: env, toolName: tool)
    }

    func reason(_ c: SessionContext, ofis: [String] = [], interactive: Bool = true) -> SkipReason? {
        SessionFilter.skipReason(c, excludedPrefixes: prefixes, ofisFileContents: ofis,
                                 isInteractive: interactive, home: home)
    }

    @Test func excludesBimRepo() {
        #expect(reason(ctx(cwd: "/Users/u/Dev/bim")) == .excluded)
    }
    @Test func excludesCaseInsensitivePrefix() {
        #expect(reason(ctx(cwd: "/Users/u/dev/bim/order-service")) == .excluded)
    }
    @Test func doesNotExcludeSiblingWithSharedPrefix() {
        #expect(reason(ctx(cwd: "/Users/u/Dev/bimbo")) == nil)
    }
    @Test func skipsOfisByEnv() {
        #expect(reason(ctx(env: ["OFIS_OTURUMU": "1"])) == .ofis)
    }
    @Test func skipsOfisBySessionIdInFile() {
        #expect(reason(ctx(sid: "abc-123"), ofis: ["{\"x\":\"abc-123\"}"]) == .ofis)
        #expect(reason(ctx(sid: "abc-123"), ofis: ["{\"x\":\"other\"}"]) == nil)
    }
    @Test func skipsAskUserQuestion() {
        #expect(reason(ctx(tool: "AskUserQuestion")) == .unsupportedTool)
    }
    @Test func skipsNonInteractive() {
        #expect(reason(ctx(), interactive: false) == .nonInteractive)
    }
    // I6: the transcript's project folder also identifies an excluded repo (Claude Code encodes "/" and "." as "-").
    @Test func excludesByTranscriptProjectFolder() throws {
        let h = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        let enc = (h + "/Dev/bim/order-service").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let dir = h + "/.claude/projects/" + enc.uppercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = dir + "/abc.jsonl"
        try "".write(toFile: t, atomically: true, encoding: .utf8)
        func r(_ path: String?) -> SkipReason? {
            SessionFilter.skipReason(
                SessionContext(cwd: h + "/elsewhere", sessionId: "s", env: [:], toolName: nil, transcriptPath: path),
                excludedPrefixes: ["~/Dev/bim"], ofisFileContents: [], isInteractive: true, home: h)
        }
        #expect(r(t) == .excluded)
        #expect(r(nil) == nil)
        #expect(r(h + "/.claude/projects/" + enc.replacingOccurrences(of: "-bim-", with: "-jarvis-") + "/abc.jsonl") == nil)
    }

    @Test func encodedProjectFolderMatchesDotsAndSlashes() {
        #expect(SessionFilter.encodedProjectName("~/Dev/bim", home: "/Users/u") == "-users-u-dev-bim")
        #expect(SessionFilter.encodedProjectName("/Users/a.b/x", home: "/h") == "-users-a-b-x")
    }

    @Test func excludedWinsOverOfis() {
        #expect(reason(ctx(cwd: "/Users/u/Dev/bim", env: ["OFIS_OTURUMU": "1"])) == .excluded)
    }

    func tempHome() throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.path
    }

    @Test func extraPrefixFromFileIsHonoured() throws {
        let h = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        try FileManager.default.createDirectory(atPath: h + "/.jarvis", withIntermediateDirectories: true)
        try "# comment\n\n~/Dev/secret\n".write(toFile: h + "/.jarvis/excluded-paths", atomically: true, encoding: .utf8)
        let p = SessionFilter.loadExcludedPrefixes(home: h)
        #expect(p.contains("~/Dev/bim"))
        #expect(p.contains("~/Dev/secret"))
        #expect(!p.contains { $0.hasPrefix("#") || $0.isEmpty })
        #expect(SessionFilter.skipReason(
            SessionContext(cwd: h + "/Dev/secret/x", sessionId: "s", env: [:], toolName: nil),
            excludedPrefixes: p, ofisFileContents: [], isInteractive: true, home: h) == .excluded)
    }

    @Test func loadsOfisFilesAndSkipsMissing() throws {
        let h = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        #expect(SessionFilter.loadOfisFileContents(home: h).isEmpty)
        let dir = h + "/Dev/ajan-ofisi/durum"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "{\"a\":\"x\"}".write(toFile: dir + "/ceo.json", atomically: true, encoding: .utf8)
        #expect(SessionFilter.loadOfisFileContents(home: h) == ["{\"a\":\"x\"}"])
    }

    @Test func ofisDirDefaultsToAjanOfisiUnderDev() throws {
        let h = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        #expect(JarvisPaths.ofisDir(home: h) == h + "/Dev/ajan-ofisi")
    }

    @Test func ofisDirReadsTheSettingFile() throws {
        let h = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        try FileManager.default.createDirectory(atPath: h + "/.jarvis", withIntermediateDirectories: true)
        // First usable line wins; `~` expands to the home folder, a trailing slash is trimmed.
        try "# comment\n\n~/code/ofis/\n/abs/later\n".write(toFile: h + "/.jarvis/ofis-dir", atomically: true, encoding: .utf8)
        #expect(JarvisPaths.ofisDir(home: h) == h + "/code/ofis")
        // A relative line is not usable: the later absolute line is taken instead.
        try "not absolute\n/abs/ofis\n".write(toFile: h + "/.jarvis/ofis-dir", atomically: true, encoding: .utf8)
        #expect(JarvisPaths.ofisDir(home: h) == "/abs/ofis")
    }

    @Test func loadsOfisFilesFromTheSettingFolder() throws {
        let h = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: h) }
        try FileManager.default.createDirectory(atPath: h + "/.jarvis", withIntermediateDirectories: true)
        try "~\n".write(toFile: h + "/.jarvis/ofis-dir", atomically: true, encoding: .utf8)
        #expect(JarvisPaths.ofisDir(home: h) == h)
        let dir = h + "/durum"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "{\"a\":\"y\"}".write(toFile: dir + "/sessions.json", atomically: true, encoding: .utf8)
        #expect(SessionFilter.loadOfisFileContents(home: h) == ["{\"a\":\"y\"}"])
    }
    // v1.4: Claude Code maps every character that is not ASCII alphanumeric to "-" in the project folder.
    @Test func nonAsciiExcludedPathMatchesTheTranscriptFolder() {
        let home = "/Users/test"
        #expect(SessionFilter.encodedProjectName("~/Dev/müşteri", home: home) == "-users-test-dev-m--teri")
        let t = "/Users/test/.claude/projects/-Users-test-Dev-m--teri-api/abc.jsonl"
        #expect(SessionFilter.transcriptIsExcluded(t, excludedPrefixes: ["~/Dev/müşteri"], home: home))
        #expect(SessionFilter.skipReason(
            SessionContext(cwd: "/tmp/elsewhere", sessionId: "s", env: [:], toolName: nil, transcriptPath: t),
            excludedPrefixes: ["~/Dev/müşteri"], ofisFileContents: [], isInteractive: true, home: home) == .excluded)
        // Non-ASCII letters in the transcript path itself are mapped the same way.
        #expect(SessionFilter.transcriptIsExcluded("/Users/test/.claude/projects/-Users-test-Dev-müşteri/a.jsonl",
                                                   excludedPrefixes: ["~/Dev/müşteri"], home: home))
        // Encoded before lowercasing: "İ" is one character for Claude Code, but lowercases to two.
        #expect(SessionFilter.encodedProjectName("~/Dev/İş", home: home) == "-users-test-dev---")
        #expect(SessionFilter.transcriptIsExcluded("/Users/test/.claude/projects/-Users-test-Dev---/a.jsonl",
                                                   excludedPrefixes: ["~/Dev/İş"], home: home))
        // A cwd in decomposed form ("u" + combining diaeresis) gives "u-" in the folder name; still excluded.
        #expect(SessionFilter.transcriptIsExcluded("/Users/test/.claude/projects/-Users-test-Dev-mu-s-teri/a.jsonl",
                                                   excludedPrefixes: ["~/Dev/müşteri"], home: home))
        // A different folder is still not excluded.
        #expect(!SessionFilter.transcriptIsExcluded("/Users/test/.claude/projects/-Users-test-Dev-jarvis/a.jsonl",
                                                    excludedPrefixes: ["~/Dev/müşteri"], home: home))
    }
}
