import Foundation

public enum TranscriptReader {
    /// The file is read backwards in chunks of this size.
    static let chunkBytes = 64 * 1024
    /// At most this much of the file's end is read; an older assistant message is not found.
    static let maxReadBytes = 4 * 1024 * 1024

    /// Returns the text of the last assistant message that has text, or nil.
    /// Reads backwards from the end of the file in `chunkBytes` chunks, at most `maxReadBytes`, and stops
    /// at the first (newest) assistant line with text. Each line is parsed on its own, so a malformed or
    /// non-UTF-8 line elsewhere does not hide the answer.
    public static func lastAssistantText(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }

        var end = size
        var budget = UInt64(maxReadBytes)
        // The start of the newest line not yet complete: pieces read later come first in the file.
        // Kept as separate pieces (newest last) so a long line is joined once, not copied per chunk.
        var partial: [Data] = []
        while end > 0, budget > 0 {
            let length = min(UInt64(chunkBytes), end, budget)
            let start = end - length
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(length)), chunk.count == Int(length) else { return nil }
            end = start
            budget -= length

            // Lines that end inside this chunk, newest first. The bytes before the chunk's first
            // newline belong to a line that starts in an earlier chunk.
            var lineEnd = chunk.endIndex
            var cursor = chunk.endIndex
            while let newline = chunk[chunk.startIndex..<cursor].lastIndex(of: 0x0A) {
                var line = Data(chunk[(newline + 1)..<lineEnd])
                if !partial.isEmpty {
                    for piece in partial.reversed() { line.append(piece) }
                    partial.removeAll()
                }
                if let text = assistantText(line) { return text }
                lineEnd = newline
                cursor = newline
            }
            partial.append(Data(chunk[chunk.startIndex..<lineEnd]))
        }
        // The file's first line is complete only when the whole file was read.
        guard end == 0 else { return nil }
        var first = Data()
        for piece in partial.reversed() { first.append(piece) }
        return assistantText(first)
    }

    /// The text of one transcript line when it is an assistant message with text: string content, or the
    /// last `text` item of array content.
    private static func assistantText(_ line: Data) -> String? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any] else { return nil }
        if let s = message["content"] as? String { return s }
        if let items = message["content"] as? [[String: Any]],
           let text = items.last(where: { $0["type"] as? String == "text" })?["text"] as? String {
            return text
        }
        return nil
    }
}
