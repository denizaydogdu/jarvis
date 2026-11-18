import Foundation
import Testing
@testable import JarvisCore

struct TranscriptReaderTests {
    private var fixture: String {
        Bundle.module.url(forResource: "transcript", withExtension: "jsonl", subdirectory: "Fixtures")!.path
    }

    @Test func readerPicksLastAssistantText() {
        #expect(TranscriptReader.lastAssistantText(path: fixture) == "Son cevap burada. Ikinci cumle.")
    }

    @Test func readerMissingFileReturnsNil() {
        #expect(TranscriptReader.lastAssistantText(path: "/nonexistent/x.jsonl") == nil)
    }

    @Test func readerSkipsMalformedLines() {
        // The fixture contains a non-JSON line between assistant lines.
        #expect(TranscriptReader.lastAssistantText(path: fixture) != nil)
    }

    @Test func readerHandlesStringContentAndLastTextItem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = dir.appendingPathComponent("t.jsonl")
        try """
        {"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}
        {"type":"assistant","message":{"content":"plain"}}
        """.write(to: p, atomically: true, encoding: .utf8)
        #expect(TranscriptReader.lastAssistantText(path: p.path) == "plain")
        try """
        {"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}
        """.write(to: p, atomically: true, encoding: .utf8)
        #expect(TranscriptReader.lastAssistantText(path: p.path) == "b")
    }
    // MARK: - v1.4: tail read

    private func tempFile(_ data: Data) throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = dir.appendingPathComponent("t.jsonl")
        try data.write(to: p)
        return (p, { try? FileManager.default.removeItem(at: dir) })
    }

    private func userLine(_ n: Int) -> String {
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(String(repeating: "u", count: n))\"}}\n"
    }

    private func assistantLine(_ text: String) -> String {
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}\n"
    }

    @Test func twentyMegabyteTranscriptIsFast() throws {
        var s = ""
        let filler = userLine(1000)
        s += assistantLine("eski")
        while s.utf8.count < 20 * 1024 * 1024 { s += filler }
        s += assistantLine("son")
        s += userLine(200) + userLine(300)
        let (p, cleanup) = try tempFile(Data(s.utf8))
        defer { cleanup() }
        let clock = ContinuousClock()
        var r: String?
        let elapsed = clock.measure { r = TranscriptReader.lastAssistantText(path: p.path) }
        #expect(r == "son")
        #expect(elapsed < .milliseconds(200))
    }

    @Test func invalidByteInAnEarlierLineIsTolerated() throws {
        var d = Data(assistantLine("ilk").utf8)
        d += Data([0x7B, 0xFF, 0xFE, 0x7D, 0x0A]) // "{\xFF\xFE}" — not UTF-8
        d += Data(assistantLine("son").utf8)
        d += Data(userLine(10).utf8)
        let (p, cleanup) = try tempFile(d)
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == "son")
    }

    @Test func lineSplitAcrossChunksAndNoTrailingNewline() throws {
        // A 150 KB assistant line spans three 64 KB chunks; the file does not end with a newline.
        let long = String(repeating: "a", count: 150 * 1024)
        var s = assistantLine("eski") + assistantLine(long)
        s += String(userLine(5).dropLast())
        let (p, cleanup) = try tempFile(Data(s.utf8))
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == long)
        // The last line itself without a trailing newline.
        let (p2, cleanup2) = try tempFile(Data((userLine(70_000) + String(assistantLine("son").dropLast())).utf8))
        defer { cleanup2() }
        #expect(TranscriptReader.lastAssistantText(path: p2.path) == "son")
    }

    @Test func lineBoundaryExactlyAtChunkBoundary() throws {
        // The tail (one user line) is exactly 64 KB, so the assistant line ends right at a chunk boundary.
        let tail = userLine(64 * 1024 - userLine(0).utf8.count)
        #expect(tail.utf8.count == 64 * 1024)
        let (p, cleanup) = try tempFile(Data((assistantLine("eski") + assistantLine("sinirda") + tail).utf8))
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == "sinirda")
    }

    @Test func assistantLineWithoutTextIsSkipped() throws {
        let toolOnly = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"t\"}]}}\n"
        let (p, cleanup) = try tempFile(Data((assistantLine("metin") + toolOnly + userLine(3)).utf8))
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == "metin")
    }

    @Test func readStopsAfterFourMegabytes() throws {
        // The only assistant text lies more than 4 MB before the end: nothing is found.
        var s = assistantLine("cok eski")
        let filler = userLine(1000)
        while s.utf8.count < 5 * 1024 * 1024 { s += filler }
        let (p, cleanup) = try tempFile(Data(s.utf8))
        defer { cleanup() }
        let clock = ContinuousClock()
        var r: String? = "x"
        let elapsed = clock.measure { r = TranscriptReader.lastAssistantText(path: p.path) }
        #expect(r == nil)
        #expect(elapsed < .milliseconds(200))
    }

    @Test func multibyteTextStraddlingTheChunkBoundary() throws {
        // A 128 KB file: the reader's two 64 KB chunks meet at byte 65536, which falls in the middle of
        // a two-byte "ü"/"ş" of the assistant text. Lines are joined as bytes before decoding, so the
        // character survives whole.
        let prefix = assistantLine("").utf8.count - "\"}]}}\n".utf8.count
        // Every character of the text is two bytes after an optional "a" that makes byte 65536 odd within it.
        let lead = (65536 - prefix) % 2 == 1 ? "" : "a"
        let text = lead + String(repeating: "üş", count: 20_000)
        let line = assistantLine(text)
        let tail = userLine(2 * 65536 - line.utf8.count - userLine(0).utf8.count)
        let bytes = Data((line + tail).utf8)
        #expect(bytes.count == 2 * 65536)
        #expect(bytes[65536] & 0xC0 == 0x80) // a UTF-8 continuation byte: the character straddles the boundary
        let (p, cleanup) = try tempFile(bytes)
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == text)
    }

    @Test func crlfLineEndings() throws {
        let s = (assistantLine("eski") + assistantLine("son çözüm") + userLine(4))
            .replacingOccurrences(of: "\n", with: "\r\n")
        let (p, cleanup) = try tempFile(Data(s.utf8))
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == "son çözüm")
    }

    @Test func rawLineSeparatorInsideAssistantText() throws {
        // A raw U+2028 (valid unescaped inside a JSON string) in the newest assistant text. The tail
        // reader splits lines on "\n" only and returns that text. Note: this differs from the old
        // forward reader (before v1.4), which split on every Unicode newline, broke this line in two
        // and so returned the older "eski" instead.
        let text = "birinci\u{2028}ikinci"
        let (p, cleanup) = try tempFile(Data((assistantLine("eski") + assistantLine(text) + userLine(3)).utf8))
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == text)
    }

    @Test func emptyFileReturnsNil() throws {
        let (p, cleanup) = try tempFile(Data())
        defer { cleanup() }
        #expect(TranscriptReader.lastAssistantText(path: p.path) == nil)
    }
}
