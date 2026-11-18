import Foundation
import Testing

/// Runs the built `jarvis-hook` binary (next to the test bundle in the build folder).
private final class BundleToken {}

@Suite(.serialized) struct HookCommandTests {
    private var hookBinary: URL {
        Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("jarvis-hook")
    }

    private func run(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = hookBinary
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    @Test func installSettingsRejectsMissingOrRelativeHookBinary() throws {
        #expect(FileManager.default.isExecutableFile(atPath: hookBinary.path), "build jarvis-hook first")
        let dir = NSTemporaryDirectory() + "jarvis-cmd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let settings = dir + "/settings.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: settings))

        #expect(try run(["install-settings"]) == 1)
        #expect(try run(["install-settings", settings]) == 1)
        #expect(try run(["install-settings", "--hook-binary", settings]) == 1)
        #expect(try run(["install-settings", "--hook-binary", "bin/jarvis-hook", settings]) == 1)
        #expect(try run(["install-settings", "--hook-binary", "./jarvis-hook", settings]) == 1)
        #expect(try run(["install-settings", "--hook-binary", "~/jarvis-hook", settings]) == 1)
        // Nothing was written and no backup was made.
        #expect(try String(contentsOfFile: settings, encoding: .utf8) == "{}")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["settings.json"])
    }

    @Test func unknownSubcommandExitsZero() throws {
        #expect(try run([]) == 0)
        #expect(try run(["nonsense"]) == 0)
    }
    @Test func closedStdoutDoesNotKillTheHook() throws {
        // install-settings prints the backup path; with the reader gone that write raises SIGPIPE.
        let dir = NSTemporaryDirectory() + "jarvis-cmd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let settings = dir + "/settings.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: settings))
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let p = Process()
        p.executableURL = hookBinary
        p.arguments = ["install-settings", "--hook-binary", "/opt/jarvis/jarvis-hook", settings]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationReason == .exit)
        #expect(p.terminationStatus == 0)
    }

    /// Runs the hook with a stderr whose reader is gone, so every write to it fails with EPIPE.
    private func runWithClosedStderr(_ args: [String]) throws -> Process {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let p = Process()
        p.executableURL = hookBinary
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = pipe
        try p.run()
        try pipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p
    }

    @Test func closedStderrDoesNotKillTheHook() throws {
        // With SIGPIPE ignored, `FileHandle.write(_: Data)` raised an Objective-C exception (SIGABRT)
        // on EPIPE; the throwing `write(contentsOf:)` fails quietly instead.
        let usage = try runWithClosedStderr(["nonsense"])
        #expect(usage.terminationReason == .exit)
        #expect(usage.terminationStatus == 0)
        let fail = try runWithClosedStderr(["install-settings"])
        #expect(fail.terminationReason == .exit)
        #expect(fail.terminationStatus == 1)
    }
}
