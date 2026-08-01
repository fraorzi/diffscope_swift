import AppKit
import CryptoKit
import DiffScopeTerminal
import Darwin
import Foundation

// Gate T0 of docs/26-terminal-plan.md §3, kept runnable after T1 and pointed at the shipping
// `DiffScopeTerminal` module. Deliberately outside diffscope-verify: it drives ten real interactive
// shells and depends on this machine's own ~/.zshrc, which is not a property a check suite should
// have.

let repositoryRoot = FileManager.default.currentDirectoryPath
let home = NSHomeDirectory()
let userZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"] ?? home

struct Outcome {
    let id: String
    let title: String
    let ok: Bool
    let detail: String
}

var outcomes: [Outcome] = []

func record(_ id: String, _ title: String, _ ok: Bool, _ detail: String = "") {
    outcomes.append(Outcome(id: id, title: title, ok: ok, detail: detail))
    print("  \(ok ? "PASS" : "FAIL")  \(id)  \(title)\(detail.isEmpty ? "" : " — \(detail)")")
}

func hashes(of names: [String]) -> [String: String] {
    var result: [String: String] = [:]
    for name in names {
        let path = (home as NSString).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        result[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return result
}

let rcFiles = [".zshrc", ".zprofile", ".zshenv", ".zlogin"]
let rcBefore = hashes(of: rcFiles)

let integration: ShellIntegration
do {
    integration = try ShellIntegration.generate(for: .zsh)
} catch {
    print("could not generate the shell integration: \(error)")
    exit(1)
}

var spawnedAgents: Set<pid_t> = []

func makeShell(columns: UInt16 = 80, rows: UInt16 = 24) -> Shell? {
    Shell(command: "/bin/zsh",
          arguments: ["-i"],
          environment: integration.environment(base: ProcessInfo.processInfo.environment,
                                               userZdotdir: userZdotdir),
          workingDirectory: repositoryRoot,
          columns: columns,
          rows: rows)
}

func finish(_ shell: Shell) {
    spawnedAgents.formUnion(shell.reportedAgentPids)
    shell.close()
}

@discardableResult
func run(_ shell: Shell, _ line: String, timeout: TimeInterval = 8)
    -> (started: Bool, exit: Int?, prompted: Bool) {
    let startsBefore = shell.count(isCommandStart)
    let endsBefore = shell.count(isCommandEnd)
    let promptsBefore = shell.count(isPromptStart)
    shell.send(line + "\n")
    let started = shell.waitForCount(isCommandStart, atLeast: startsBefore + 1, timeout: timeout)
    let ended = shell.waitForCount(isCommandEnd, atLeast: endsBefore + 1, timeout: timeout)
    let prompted = shell.waitForCount(isPromptStart, atLeast: promptsBefore + 1, timeout: timeout)
    var code: Int?
    if ended, let last = shell.events.last(where: { isCommandEnd($0.event) }),
       case let .commandEnd(value) = last.event {
        code = value
    }
    return (started, code, prompted)
}

extension Substring {
    var nilIfEmpty: Substring? { isEmpty ? nil : self }
}

func agentPid(in text: String) -> pid_t? {
    for part in text.components(separatedBy: "T0-AGENT=").dropFirst() {
        if let digits = part.prefix(while: \.isNumber).nilIfEmpty, let pid = pid_t(digits) { return pid }
    }
    return nil
}

func occurrences(of needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

print("=== T0 — the four unknowns of docs/26-terminal-plan.md §3 ===\n")
print("  shell         /bin/zsh -i on a forkpty PTY")
print("  integration   \(integration.directory.path)")
print("  working dir   \(repositoryRoot)\n")

// ------------------------------------------------- S0: the control — marks come from us, or not

// Without this, every result below would also hold if something already in the user's setup were
// emitting OSC 133, and nothing here would have measured the integration at all.
var plainEnvironment = ProcessInfo.processInfo.environment
plainEnvironment["ZDOTDIR"] = nil
plainEnvironment["TERM"] = "xterm-256color"
plainEnvironment["COLUMNS"] = nil
plainEnvironment["LINES"] = nil

if let shell = Shell(command: "/bin/zsh",
                     arguments: ["-i"],
                     environment: plainEnvironment,
                     workingDirectory: repositoryRoot) {
    let alive = shell.waitForText("(main)", timeout: 15)
    let marks = shell.events.filter { event in
        isPromptStart(event.event) || isCommandStart(event.event) || isCommandEnd(event.event)
    }
    record("S0", "an unmodified shell reaches its prompt and emits no marks at all",
           alive && marks.isEmpty,
           alive ? "\(marks.count) marks" : "the shell never printed its prompt")

    // This shell has no integration, so it cannot report its agent on the side channel the others
    // use — and until it was asked directly it leaked exactly one ssh-agent per run.
    shell.send("echo T0-AGENT=$SSH_AGENT_PID\n")
    // Waiting for the marker alone matched the *echo of the typed line*, where the text is still
    // `$SSH_AGENT_PID`, and the parse then ran before the answer existed. Wait for the parse.
    _ = shell.wait(timeout: 5) { _, text in agentPid(in: text) != nil }
    if let pid = agentPid(in: shell.transcript) { spawnedAgents.insert(pid) }
    finish(shell)
}

// ---------------------------------------------------------------- S1: reliability across shells

var latencies: [Double] = []
var withoutPrompt = 0
for _ in 0..<5 {
    guard let shell = makeShell() else { withoutPrompt += 1; continue }
    if shell.waitForEvent(isPromptStart, timeout: 15), let ms = shell.millisecondsToFirstPrompt {
        latencies.append(ms)
    } else {
        withoutPrompt += 1
    }
    finish(shell)
}
record("S1", "a prompt mark in every one of five fresh shells",
       withoutPrompt == 0 && latencies.count == 5,
       latencies.isEmpty
           ? "no marks at all"
           : String(format: "first mark at %.0f–%.0f ms (median %.0f)",
                    latencies.min()!, latencies.max()!, latencies.sorted()[latencies.count / 2]))

// ------------------------------------------------- S2–S5: one long-lived shell, driven like a user

if let shell = makeShell() {
    let reachedPrompt = shell.waitForEvent(isPromptStart, timeout: 15)
    record("S2a", "the shell reaches a prompt before anything is typed", reachedPrompt)

    let echo = run(shell, "echo T0-OUTPUT-OK")
    let roundTripped = occurrences(of: "T0-OUTPUT-OK", in: shell.transcript) >= 2
    record("S2b", "echo: C mark, output round-trips, D;0, then another A",
           echo.started && echo.exit == 0 && echo.prompted && roundTripped,
           "exit \(String(describing: echo.exit)), output seen \(occurrences(of: "T0-OUTPUT-OK", in: shell.transcript))×")

    let failing = run(shell, "false")
    record("S3a", "a command that fails reports D;1 and prompts again",
           failing.exit == 1 && failing.prompted, "exit \(String(describing: failing.exit))")

    let missing = run(shell, "diffscope-no-such-command-t0")
    record("S3b", "a command that does not exist reports D;127 and prompts again",
           missing.exit == 127 && missing.prompted, "exit \(String(describing: missing.exit))")

    let beforeClear = shell.transcript.count
    let cleared = run(shell, "clear")
    let afterClear = String(shell.transcript.dropFirst(beforeClear))
    let clearedScreen = afterClear.contains("\u{1b}[H") || afterClear.contains("\u{1b}[2J")
    record("S4", "clear: the screen is wiped and the prompt is still detected",
           cleared.exit == 0 && cleared.prompted && clearedScreen,
           clearedScreen ? "erase sequence seen" : "no erase sequence in the transcript")

    shell.resize(columns: 100, rows: 30)
    let atPrompt = run(shell, "echo COLS=$COLUMNS")
    record("S5a", "a resize at the prompt reaches the shell",
           atPrompt.prompted && shell.transcript.contains("COLS=100"),
           shell.transcript.contains("COLS=100") ? "COLUMNS=100" : "COLUMNS did not follow")

    let startsBefore = shell.count(isCommandStart)
    let endsBefore = shell.count(isCommandEnd)
    let promptsBefore = shell.count(isPromptStart)
    shell.send("sleep 2\n")
    let running = shell.waitForCount(isCommandStart, atLeast: startsBefore + 1, timeout: 8)
    shell.resize(columns: 120, rows: 40)
    let finished = shell.waitForCount(isCommandEnd, atLeast: endsBefore + 1, timeout: 8)
        && shell.waitForCount(isPromptStart, atLeast: promptsBefore + 1, timeout: 8)
    let afterProgram = run(shell, "echo COLS=$COLUMNS")
    record("S5b", "a resize while a program runs, and the marks still parse afterwards",
           running && finished && afterProgram.prompted && shell.transcript.contains("COLS=120"),
           shell.transcript.contains("COLS=120") ? "COLUMNS=120" : "COLUMNS did not follow")

    finish(shell)
} else {
    record("S2a", "the shell reaches a prompt before anything is typed", false, "could not spawn a shell")
}

// ------------------------------------------- S6: the user's own precmd survives the integration

if let shell = makeShell() {
    let prompted = shell.waitForEvent(isPromptStart, timeout: 15)
    let sawPromptEnd = shell.waitForEvent(isPromptEnd, timeout: 3)
    let branchInPrompt = shell.waitForText("(main)", timeout: 3)
    record("S6", "the user's vcs_info still reaches the prompt, and the B mark rides on it",
           prompted && branchInPrompt && sawPromptEnd,
           branchInPrompt ? "prompt contains (main)" : "the branch is gone from the prompt")
    finish(shell)
}

// ------------------------ S6b: the same shell with the wrong integration, to show what it costs

if let naive = try? ShellIntegration.generate(for: .zsh, style: .naiveAssignmentControl) {
    if let shell = Shell(command: "/bin/zsh",
                         arguments: ["-i"],
                         environment: naive.environment(base: ProcessInfo.processInfo.environment,
                                                        userZdotdir: userZdotdir),
                         workingDirectory: repositoryRoot) {
        let prompted = shell.waitForEvent(isPromptStart, timeout: 15)
        let branchSurvived = shell.waitForText("(main)", timeout: 3)
        record("S6b", "a plain precmd assignment marks the prompt and destroys vcs_info",
               prompted && !branchSurvived,
               prompted
                   ? (branchSurvived ? "the branch survived — the hazard is not what was recorded"
                                     : "marks arrive, the branch is gone from the prompt")
                   : "no marks at all")
        finish(shell)
    }
    naive.remove()
}

// ------------------------------------------------------------------ S7: a full-screen program

if let shell = makeShell() {
    _ = shell.waitForEvent(isPromptStart, timeout: 15)
    let startsBefore = shell.count(isCommandStart)
    shell.send("vim\n")
    let launched = shell.waitForCount(isCommandStart, atLeast: startsBefore + 1, timeout: 8)
    let entered = shell.waitForEvent({ event in
        if case let .alternateScreen(on) = event { return on }
        return false
    }, timeout: 10)

    let promptsBeforeQuit = shell.count(isPromptStart)
    shell.send(":q\r")
    let left = shell.waitForEvent({ event in
        if case let .alternateScreen(on) = event { return !on }
        return false
    }, timeout: 10)
    let returned = shell.waitForCount(isPromptStart, atLeast: promptsBeforeQuit + 1, timeout: 8)
    let afterVim = run(shell, "echo T0-AFTER-VIM")

    record("S7", "vim enters the alternate screen, :q leaves it, and the shell is usable after",
           launched && entered && left && afterVim.exit == 0,
           "queries answered: \(Set(shell.events.queries).sorted().joined(separator: ", "))"
               + (returned ? "" : " · no prompt mark between :q and the next command"))
    finish(shell)
}

// ------------------------------------------------------------------- S8: the macOS text motions

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let appKit = Motions.measureAppKit()
print("\n  caret positions in NSTextView (\(appKit.path)):")
for reading in appKit.readings {
    print(String(format: "    %-34@  %3d → %3d (expected %3d)%@",
                 reading.name as NSString, reading.from, reading.caret, reading.expected,
                 reading.matches ? "" : "  ←"))
}
let motionsAgree = appKit.readings.allSatisfy(\.matches)
let deletion = appKit.readings.last.map { !$0.text.contains("thing") && $0.text.contains("the ") } ?? false
record("S8a", "Option/Cmd motions land where macOS puts them, in a plain NSTextView",
       motionsAgree, "\(appKit.readings.filter(\.matches).count)/\(appKit.readings.count) readings agree")
record("S8b", "Option+Delete removes exactly the last word", deletion,
       appKit.readings.last.map { String($0.text.split(separator: "\n").first ?? "") } ?? "")

let web = Motions.measureWebView()
print("\n  caret positions in a WKWebView textarea — \(web.note):")
for reading in web.readings {
    print(String(format: "    %-34@  %3d → %3d (expected %3d)%@",
                 reading.name as NSString, reading.from, reading.caret, reading.expected,
                 reading.matches ? "" : "  ←"))
}
let webDeletion = web.readings.last.map { !$0.text.contains("thing") && $0.text.contains("the ") } ?? false
record("S8c", "the same motions in a DOM text field inside a WKWebView",
       web.readings.count == appKit.readings.count && web.readings.allSatisfy(\.matches) && webDeletion,
       "\(web.readings.filter(\.matches).count)/\(web.readings.count) readings agree with AppKit")

// ------------------------------------------------------ S9: nothing of the user's was written to

let rcAfter = hashes(of: rcFiles)
let untouched = rcBefore == rcAfter
record("S9a", "every rc file has the same SHA-256 it had before the run", untouched,
       rcBefore.keys.sorted().joined(separator: ", "))
record("S9b", "the generated ZDOTDIR lives outside the home directory",
       !integration.directory.path.hasPrefix(home), integration.directory.path)

integration.remove()

// The user's own rc runs `eval "$(ssh-agent -s)"`, so every interactive shell leaves an agent
// behind. Only the pids our own shells reported are killed, and only after checking what they are.
var reaped = 0
for pid in spawnedAgents {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-p", "\(pid)", "-o", "comm="]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let name = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if name.contains("ssh-agent"), kill(pid, SIGTERM) == 0 { reaped += 1 }
}
print("\n  \(spawnedAgents.count) ssh-agent processes were started by these shells' rc files, \(reaped) reaped")

let failures = outcomes.filter { !$0.ok }
print("\n\(outcomes.count - failures.count)/\(outcomes.count) scenarios passed")
if !failures.isEmpty {
    print("FAILED: \(failures.map(\.id).joined(separator: ", "))")
    exit(1)
}
print("T0 PASSED")
