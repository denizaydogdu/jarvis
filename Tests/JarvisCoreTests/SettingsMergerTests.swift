import Foundation
import Testing
@testable import JarvisCore

private let bin = "/Users/test/.jarvis/jarvis-hook"

private func obj(_ d: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
}

private func commands(_ root: [String: Any], _ event: String) -> [String] {
    let hooks = root["hooks"] as? [String: Any]
    let groups = hooks?[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

@Suite struct SettingsMergerTests {
    @Test func addsBothGroupsToEmptySettings() throws {
        let out = try obj(SettingsMerger.merge(Data("{}".utf8), hookBinary: bin))
        #expect(commands(out, "PermissionRequest") == ["\(bin) permission"])
        #expect(commands(out, "Stop") == ["\(bin) stop"])
        let hooks = out["hooks"] as? [String: Any]
        let perm = (hooks?["PermissionRequest"] as? [[String: Any]])?.first
        #expect(perm?["matcher"] as? String == "*")
        let h = (perm?["hooks"] as? [[String: Any]])?.first
        #expect(h?["type"] as? String == "command")
        #expect(h?["timeout"] as? Int == 180)
    }

    @Test func preservesExistingStopHooks() throws {
        let src = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"codex-notify stop"}]}]}}"#
        let out = try obj(SettingsMerger.merge(Data(src.utf8), hookBinary: bin))
        let stop = (out["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 2)
        #expect(commands(out, "Stop").contains("codex-notify stop"))
        #expect(commands(out, "Stop").contains("\(bin) stop"))
    }

    @Test func preservesUnrelatedKeys() throws {
        let src = #"{"permissions":{"allow":["Bash(ls)"]},"env":{"A":"b"},"model":"opus"}"#
        let out = try obj(SettingsMerger.merge(Data(src.utf8), hookBinary: bin))
        #expect((out["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
        #expect((out["env"] as? [String: String]) == ["A": "b"])
        #expect(out["model"] as? String == "opus")
    }

    @Test func mergerAddsPreToolUseAskGroupIdempotently() throws {
        let src = #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard.sh"}]}]}}"#
        let once = try SettingsMerger.merge(Data(src.utf8), hookBinary: bin)
        let groups = try #require((try obj(once)["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        try #require(groups.count == 2)
        // The user's own group is untouched and stays first.
        #expect(groups[0]["matcher"] as? String == "Bash")
        #expect(commands(try obj(once), "PreToolUse") == ["guard.sh", "\(bin) ask"])
        #expect(groups[1]["matcher"] as? String == "AskUserQuestion")
        let h = try #require((groups[1]["hooks"] as? [[String: Any]])?.first)
        #expect(h["type"] as? String == "command")
        #expect(h["timeout"] as? Int == 180)
        // Merging again changes nothing.
        let twice = try SettingsMerger.merge(once, hookBinary: bin)
        #expect(try obj(once) as NSDictionary == obj(twice) as NSDictionary)
        // An ask hook installed from another path counts as installed.
        let old = #"{"hooks":{"PreToolUse":[{"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"/opt/old/jarvis-hook ask"}]}]}}"#
        let merged = try obj(SettingsMerger.merge(Data(old.utf8), hookBinary: bin))
        #expect(commands(merged, "PreToolUse") == ["/opt/old/jarvis-hook ask"])
        // Existing settings get all three groups.
        let fresh = try obj(SettingsMerger.merge(Data("{}".utf8), hookBinary: bin))
        #expect(commands(fresh, "PreToolUse") == ["\(bin) ask"])
        #expect(commands(fresh, "PermissionRequest") == ["\(bin) permission"])
        #expect(commands(fresh, "Stop") == ["\(bin) stop"])
    }

    @Test func isIdempotent() throws {
        let once = try SettingsMerger.merge(Data("{}".utf8), hookBinary: bin)
        let twice = try SettingsMerger.merge(once, hookBinary: bin)
        #expect(try obj(once) as NSDictionary == obj(twice) as NSDictionary)
        #expect(commands(try obj(twice), "Stop").count == 1)
    }

    // M7: an existing jarvis-hook entry under another path counts as installed.
    @Test func existingHookAtAnotherPathIsAlreadyInstalled() throws {
        let src = #"{"hooks":{"PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"/opt/old/jarvis-hook permission"}]}],"Stop":[{"hooks":[{"type":"command","command":"/opt/old/jarvis-hook stop"}]}]}}"#
        let out = try obj(SettingsMerger.merge(Data(src.utf8), hookBinary: bin))
        #expect(commands(out, "PermissionRequest") == ["/opt/old/jarvis-hook permission"])
        #expect(commands(out, "Stop") == ["/opt/old/jarvis-hook stop"])
    }

    @Test func similarButDifferentCommandIsNotInstalled() throws {
        let src = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/my-jarvis-hook stop --x"}]}]}}"#
        let out = try obj(SettingsMerger.merge(Data(src.utf8), hookBinary: bin))
        #expect(commands(out, "Stop").contains("\(bin) stop"))
    }

    @Test func invalidJsonThrows() {
        #expect(throws: (any Error).self) { try SettingsMerger.merge(Data("not json".utf8), hookBinary: bin) }
        #expect(throws: (any Error).self) { try SettingsMerger.merge(Data("[1]".utf8), hookBinary: bin) }
    }

    @Test func slashesNotEscaped() throws {
        let out = try SettingsMerger.merge(Data("{}".utf8), hookBinary: bin)
        #expect(String(decoding: out, as: UTF8.self).contains(bin))
    }
}

@Suite struct SettingsInstallTests {
    @Test func installBacksUpAndRewritesPreservingMode() throws {
        let dir = NSTemporaryDirectory() + "jarvis-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/settings.json"
        let src = #"{"model":"opus"}"#
        try Data(src.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        let backup = try SettingsMerger.install(settingsPath: path, hookBinary: bin)
        #expect(backup.hasPrefix(path + ".bak-jarvis-"))
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == src)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect(attrs[.posixPermissions] as? Int == 0o600)
        #expect(commands(try obj(Data(contentsOf: URL(fileURLWithPath: path))), "Stop") == ["\(bin) stop"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).count == 2)
    }

    @Test func installInvalidJsonLeavesFileUntouched() throws {
        let dir = NSTemporaryDirectory() + "jarvis-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/settings.json"
        try Data("oops".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try SettingsMerger.install(settingsPath: path, hookBinary: bin) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["settings.json"])
    }
}

@Suite struct SettingsMergerFixTests {
    @Test func floatsAreRefused() {
        for src in [#"{"a":0.1}"#, #"{"a":1.0}"#, #"{"a":[{"b":1e3}]}"#, #"{"a":-2.5E-1}"#] {
            #expect(throws: SettingsMergerError.self) { try SettingsMerger.merge(Data(src.utf8), hookBinary: bin) }
        }
    }

    @Test func boolsIntsAndStringsPreserved() throws {
        let src = #"{"t":true,"f":false,"n":null,"i":42,"neg":-7,"s":"v1.0 e \"2.5\" x"}"#
        let out = try obj(SettingsMerger.merge(Data(src.utf8), hookBinary: bin))
        #expect(out["t"] as? Bool == true)
        #expect(out["f"] as? Bool == false)
        #expect(out["i"] as? Int == 42)
        #expect(out["neg"] as? Int == -7)
        #expect(out["s"] as? String == #"v1.0 e "2.5" x"#)
    }

    @Test func symlinkIsRefused() throws {
        let dir = NSTemporaryDirectory() + "jarvis-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: dir + "/real.json"))
        try FileManager.default.createSymbolicLink(atPath: dir + "/settings.json", withDestinationPath: dir + "/real.json")
        #expect(throws: SettingsMergerError.self) { try SettingsMerger.install(settingsPath: dir + "/settings.json", hookBinary: bin) }
        #expect(try String(contentsOfFile: dir + "/real.json", encoding: .utf8) == "{}")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/settings.json") == dir + "/real.json")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).count == 2)
    }

    @Test func existingBackupIsNotOverwritten() throws {
        let dir = NSTemporaryDirectory() + "jarvis-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/settings.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
        let now = Date()
        let first = try SettingsMerger.install(settingsPath: path, hookBinary: bin, now: now)
        try Data("precious".utf8).write(to: URL(fileURLWithPath: first))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(throws: SettingsMergerError.self) { try SettingsMerger.install(settingsPath: path, hookBinary: bin, now: now) }
        #expect(try String(contentsOfFile: first, encoding: .utf8) == "precious")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).count == 2)
    }
    // v1.4: a number JSONSerialization would not write back byte for byte is refused.
    @Test func longIntegersAndNegativeZeroAreRefused() {
        func refused(_ json: String) -> Bool { SettingsMerger.containsNonIntegerNumber(Data(json.utf8)) }
        #expect(refused(#"{"a":1234567890123456789}"#))      // 19 digits
        #expect(refused(#"{"a":-1234567890123456789}"#))
        #expect(refused(#"{"a":[-0]}"#))
        #expect(refused(#"{"a":-0}"#))
        #expect(!refused(#"{"a":123456789012345678}"#))      // 18 digits round-trip exactly
        #expect(!refused(#"{"a":-123456789012345678,"b":0,"c":-1,"d":10}"#))
        #expect(!refused(#"{"a":"-0","b":"12345678901234567890"}"#)) // inside strings
        #expect(throws: SettingsMergerError.self) {
            try SettingsMerger.merge(Data(#"{"n":99999999999999999999}"#.utf8), hookBinary: bin)
        }
        #expect(throws: SettingsMergerError.self) { try SettingsMerger.merge(Data(#"{"n":-0}"#.utf8), hookBinary: bin) }
    }
}
