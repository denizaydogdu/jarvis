import Foundation
import JarvisCore

/// Writes to stderr. The throwing API, because SIGPIPE is ignored: on a closed stderr the old
/// `write(_: Data)` raised an Objective-C exception (SIGABRT); this one fails quietly.
func printError(_ text: String) {
    try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
}

func usage() {
    printError("usage: jarvis-hook permission|stop|ask|install-settings --hook-binary <abs> <settings.json>\n")
}

final class RowsCache {
    private var rows: [ProcessInfoRow]?
    var value: [ProcessInfoRow] {
        if let rows { return rows }
        let fresh = ProcessTree.currentRows()
        rows = fresh
        return fresh
    }
}

func runHook(_ event: HookEvent) {
    let stdin = FileHandle.standardInput.readDataToEndOfFile()
    let home = NSHomeDirectory()
    let paths = JarvisPaths.standard(home: home)
    let log = JarvisLog(path: paths.log)
    // `ps` runs at most once, and only when a rule needs it.
    let rows = RowsCache()
    let deps = HookDeps(
        send: { SocketClient.send($0, path: paths.socket, timeout: 150) },
        isInteractive: { ProcessTree.isInteractive(startPid: getppid(), rows: rows.value) },
        excludedPrefixes: SessionFilter.loadExcludedPrefixes(home: home),
        ofisFileContents: SessionFilter.loadOfisFileContents(home: home),
        env: ProcessInfo.processInfo.environment,
        home: home,
        log: { log.append($0) },
        newId: { UUID().uuidString },
        sessionTty: { ProcessTree.sessionTty(startPid: getppid(), rows: rows.value) }
    )
    let out = HookRunner.run(event: event, stdin: stdin, deps: deps)
    if !out.isEmpty { print(out) }
}

func installSettings(_ args: [String]) -> Never {
    func fail(_ msg: String) -> Never {
        printError("jarvis-hook install-settings: \(msg)\n")
        exit(1)
    }
    let use = "usage: jarvis-hook install-settings --hook-binary <absolute path> <settings.json>"
    guard args.count == 3, args[0] == "--hook-binary" else { fail(use) }
    guard args[1].hasPrefix("/") else { fail("--hook-binary must be an absolute path") }
    // The path becomes a shell command in settings.json: refuse anything a shell would split or interpret.
    let unsafe = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ";&|$`'\"\\()<>"))
    guard args[1].unicodeScalars.allSatisfy({ !unsafe.contains($0) }) else {
        fail("--hook-binary must not contain whitespace or any of ;&|$`'\"\\()<>")
    }
    let exe = args[1]
    do {
        print(try SettingsMerger.install(settingsPath: args[2], hookBinary: exe))
        exit(0)
    } catch {
        fail("\(error)")
    }
}

// Never break a session: every path exits 0. Ignore SIGPIPE first, so a closed stdout or socket peer
// ends a write with EPIPE instead of killing the hook.
signal(SIGPIPE, SIG_IGN)
switch CommandLine.arguments.dropFirst().first {
case "permission": runHook(.permission)
case "stop": runHook(.stop)
case "ask": runHook(.ask)
case "install-settings": installSettings(Array(CommandLine.arguments.dropFirst(2)))
default: usage()
}
exit(0)
