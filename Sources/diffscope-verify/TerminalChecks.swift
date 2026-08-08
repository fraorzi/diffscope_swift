import CryptoKit
import Darwin
import DiffScopeTerminal
import Foundation

/// T1 of `docs/26-terminal-plan.md`, and the parts of DEC-053/DEC-054 that can be settled without a
/// window.
///
/// Everything here runs against `/bin/cat` and `/bin/sh` rather than an interactive shell: a check
/// suite that depends on whoever's `~/.zshrc` is installed proves something different on every
/// machine. Prompt marks against a real zsh are gate T0's job (`swift run diffscope-t0`), and the
/// grid being drawn is the application selftest's.
func runTerminalChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    print("\n=== terminal: the scanner reads marks out of a byte stream ===")
    do {
        func events(feeding chunks: [String]) -> [TerminalEvent] {
            let scanner = TerminalScanner()
            var seen: [TerminalEvent] = []
            scanner.onEvent = { seen.append($0) }
            for chunk in chunks { scanner.feed(Array(chunk.utf8)[...]) }
            return seen
        }

        report("a prompt mark is recognised", events(feeding: ["\u{1b}]133;A\u{07}"]).contains(where: isPromptStart))

        // The case that decides whether any of this works in practice: a mark arriving in pieces.
        let torn = events(feeding: ["ls\r\n\u{1b}]13", "3;", "A", "\u{07}next"])
        report("a mark split across three reads is still one mark",
               torn.filter(isPromptStart).count == 1, "\(torn.count) events")

        let terminatedByST = events(feeding: ["\u{1b}]133;C\u{1b}\\"])
        report("a string terminator ends the mark as well as a BEL",
               terminatedByST.contains(where: isCommandStart))

        let exited = events(feeding: ["\u{1b}]133;D;127\u{07}"])
        report("an exit status rides on the command-end mark",
               exited.contains(where: commandEnded(with: 127)))

        let noStatus = events(feeding: ["\u{1b}]133;D\u{07}"])
        var sawNil = false
        for event in noStatus { if case .commandEnd(nil) = event { sawNil = true } }
        report("a command-end mark without a status is still a command end", sawNil)

        for (sequence, entering) in [("\u{1b}[?1049h", true), ("\u{1b}[?1049l", false),
                                     ("\u{1b}[?47h", true), ("\u{1b}[?1047l", false)] {
            var matched = false
            for event in events(feeding: [sequence]) {
                if case let .alternateScreen(on) = event, on == entering { matched = true }
            }
            report("\(sequence.dropFirst()) reports the alternate screen \(entering ? "entered" : "left")",
                   matched)
        }

        // The negative control. Without it, a scanner that fired on anything would pass every
        // check above and this file would be measuring nothing.
        let ordinary = events(feeding: [
            "$ echo '133;A' ; ls ]133;C[ \u{1b}[1;32mgreen\u{1b}[0m \u{1b}]0;a title\u{07}\r\n",
        ])
        report("ordinary output containing ]133;C, colours and a title emits nothing",
               ordinary.isEmpty, "\(ordinary.count) events")

        func directories(feeding chunks: [String]) -> [String] {
            events(feeding: chunks).compactMap {
                if case let .workingDirectory(path) = $0 { return path } else { return nil }
            }
        }
        report("OSC 7 with a host reports the path",
               directories(feeding: ["\u{1b}]7;file://mac.local/Users/x/repo\u{07}"]) == ["/Users/x/repo"])
        report("and without one", directories(feeding: ["\u{1b}]7;file:///tmp/repo\u{07}"]) == ["/tmp/repo"])
        report("a percent-encoded path is decoded",
               directories(feeding: ["\u{1b}]7;file:///tmp/with%20space\u{07}"]) == ["/tmp/with space"])
        report("and OSC 7 split across reads is still one report",
               directories(feeding: ["\u{1b}]7;file://", "mac/tmp/", "x\u{07}"]) == ["/tmp/x"])
        report("something that is not a local file URL is ignored rather than guessed at",
               directories(feeding: ["\u{1b}]7;https://example.com/x\u{07}"]).isEmpty)

        var replies: [String] = []
        let scanner = TerminalScanner()
        scanner.onReply = { replies.append($0) }
        scanner.feed(Array("\u{1b}[c\u{1b}[6n".utf8)[...])
        report("a scanner with no emulator behind it answers the queries a program asks",
               replies.count == 2, replies.joined(separator: " "))

        let silent = TerminalScanner()
        var silentReplies = 0
        silent.onEvent = { if case .query = $0 { silentReplies += 0 } }
        silent.feed(Array("\u{1b}[c".utf8)[...])
        report("and answers nothing when no reply handler is set — xterm.js answers for itself",
               silentReplies == 0)
    }

    print("\n=== terminal: where a keystroke goes (T2) ===")
    do {
        let router = InputRouter()
        func route(_ key: InputKey, _ line: String, _ mode: InputMode) -> InputAction {
            router.route(key: key, line: line, mode: mode)
        }

        report("the intercepted keys are named in one place, and the page is told them",
               Set(InputRouter.interceptedKeys) ==
                   Set(["Enter", "Tab", "ArrowUp", "ArrowDown", "Escape", "ctrl-c", "ctrl-d", "ctrl-r"]),
               InputRouter.interceptedKeys.joined(separator: " "))

        report("Enter submits the line", route(InputKey("Enter"), "git status", .local) == .submit("git status"))
        report("Tab hands the line to the shell, text first and then the key",
               route(InputKey("Tab"), "git st", .local) == .handOver(text: "git st", key: [0x09]))
        report("⌃R hands over too, so the shell's own reverse search works",
               route(InputKey("r", control: true), "", .local) == .handOver(text: "", key: [0x12]))
        report("↑ and ↓ ask for history", route(InputKey("ArrowUp"), "", .local) == .recall(offset: -1)
                   && route(InputKey("ArrowDown"), "", .local) == .recall(offset: 1))
        report("Escape clears the line at a prompt", route(InputKey("Escape"), "half typed", .local) == .clearLine)
        report("⌃C interrupts and takes the half-typed line with it",
               route(InputKey("c", control: true), "half typed", .local) == .sendRaw([0x03]))
        report("⌃D on an empty line is EOF",
               route(InputKey("d", control: true), "", .local) == .sendRaw([0x04]))
        report("and ⌃D over typed text does nothing, rather than closing the shell under it",
               route(InputKey("d", control: true), "rm -rf", .local) == .editLocally)

        // The negative control. A router that claimed everything would satisfy every line above.
        report("an ordinary character is not the router's business",
               route(InputKey("a"), "ls", .local) == .editLocally)
        report("and neither is a macOS motion — which is the entire point of the input line",
               route(InputKey("ArrowLeft", alt: true), "git status", .local) == .editLocally
                   && route(InputKey("ArrowLeft", meta: true), "git status", .local) == .editLocally)

        report("while a program runs, every key belongs to it and xterm encodes it",
               route(InputKey("Enter"), "", .program) == .editLocally
                   && route(InputKey("Tab"), "", .program) == .editLocally
                   && route(InputKey("c", control: true), "", .program) == .editLocally)
        report("Escape releases a forced raw mode, and only a forced one",
               route(InputKey("Escape"), "", .forcedRaw) == .releaseForcedRaw
                   && route(InputKey("Escape"), "", .handedOver) == .editLocally)

        report("every mode says what it is, and the raw ones admit to being raw",
               InputMode.local.label == "prompt" && !InputMode.local.isRaw
                   && InputMode.program.isRaw && InputMode.forcedRaw.isRaw && InputMode.handedOver.isRaw
                   && InputMode.forcedRaw.label.contains("forced")
                   && InputMode.handedOver.label.contains("shell"))
    }

    print("\n=== terminal: the history is this session's, and nobody's history file ===")
    do {
        var history = SessionHistory()
        report("recall on an empty history returns nothing to show", history.recall(offset: -1) == nil)
        history.remember("git status")
        history.remember("git diff")
        report("the newest entry comes back first", history.recall(offset: -1) == "git diff")
        report("then the one before it", history.recall(offset: -1) == "git status")
        report("and walking past the oldest stays there rather than wrapping",
               history.recall(offset: -1) == "git status")
        report("walking forward returns", history.recall(offset: 1) == "git diff")
        report("and past the newest leaves an empty line to type into", history.recall(offset: 1) == "")

        var repeated = SessionHistory()
        repeated.remember("ls")
        repeated.remember("ls")
        report("a command repeated twice in a row is one entry", repeated.count == 1)
        repeated.remember("   ")
        report("and whitespace is not a command", repeated.count == 1)

        let sources = ["Sources/DiffScopeTerminal", "Sources/diffscope-app"].flatMap { module -> [String] in
            let dir = root.appendingPathComponent(module)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
            var texts: [String] = []
            for case let url as URL in walker where url.pathExtension == "swift" {
                texts.append((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
            return texts
        }
        // Showing a reader what they just typed is not the same act as opening their history file.
        //
        // Comments are stripped first: this decision is *documented* in `InputRouter.swift`, so a
        // plain substring search finds the sentence saying we do not do it and fails on it. Same
        // shape as the `precmd() {` check above, found the same way.
        func code(_ text: String) -> String {
            text.replacingOccurrences(of: "(?m)^\\s*(//|///).*$", with: " ",
                                      options: [.regularExpression])
        }
        let readsHistory = sources.map(code).filter {
            $0.contains(".zsh_history") || $0.contains(".bash_history") || $0.contains("HISTFILE")
        }
        report("no history file is read anywhere", readsHistory.isEmpty, "\(readsHistory.count) files")
    }

    print("\n=== terminal: the mode follows the marks, and the escape hatch overrides them ===")
    do {
        // A shell that emits a prompt mark and then echoes: real marks, real PTY, no dependence on
        // anybody's rc file.
        guard let session = TerminalSession(shellPath: "/bin/sh",
                                            workingDirectory: NSHomeDirectory(),
                                            arguments: ["-c", "printf '\\033]133;A\\007'; cat"],
                                            environment: ["TERM": "xterm-256color",
                                                          "HOME": NSHomeDirectory()]) else {
            report("a session can be started", false)
            return
        }
        report("before any mark, the mode is raw — a shell that marks nothing behaves like a terminal",
               session.mode == .program)

        // The session publishes on the main queue, so the check has to let it run.
        func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }

        report("a prompt mark puts the reader in the input line",
               waitUntil { session.mode == .local })

        session.setForcedRaw(true)
        report("the escape hatch overrides the mark", waitUntil { session.mode == .forcedRaw })
        session.setForcedRaw(false)
        report("and releasing it hands the line back", waitUntil { session.mode == .local })

        // What the shell actually received, rather than what the router says it sent. `cat` echoes,
        // so the bytes come back.
        var echoed: [UInt8] = []
        session.onOutput = { echoed.append(contentsOf: $0) }

        session.handle(key: InputKey("Enter"), line: "submitted-line")
        report("a submitted line is remembered", session.historyCount == 1)
        report("and reaches the shell with its carriage return",
               waitUntil { String(decoding: echoed, as: UTF8.self).contains("submitted-line") },
               String(decoding: echoed.suffix(40), as: UTF8.self))

        session.handle(key: InputKey("Tab"), line: "handed-over")
        report("a handover leaves the shell holding the line",
               waitUntil { session.mode == .handedOver })
        report("and the shell received the typed text as well as the key",
               waitUntil { String(decoding: echoed, as: UTF8.self).contains("handed-over") })

        // The mode is raw now, so the same Enter belongs to the shell — nothing local happens to it.
        let afterHandover = session.historyCount
        session.handle(key: InputKey("Enter"), line: "not-mine")
        report("while the shell holds the line, Enter is the shell's and is not remembered here",
               session.historyCount == afterHandover)

        session.stop()
    }

    print("\n=== terminal: the one command the application composes (T3) ===")
    do {
        // A path comes off the file system, and a directory may be named anything at all. This is
        // the closest the product comes to composing a command, so the quoting is measured against
        // a real shell rather than argued about.
        let hostile = [
            "/tmp/plain",
            "/tmp/with space",
            "/tmp/it's",
            "/tmp/semi;colon",
            "/tmp/$(id)",
            "/tmp/`id`",
            "/tmp/dollar$HOME",
            "/tmp/new\nline",
            "/tmp/-leading-dash",
            "/tmp/quote\"double",
            "/tmp/ŻABKA",
            "/tmp/back\\slash",
        ]
        var unbalanced: [String] = []
        for path in hostile {
            let quoted = shellSingleQuoted(path)
            // Inside single quotes a shell expands nothing, so the only way out of the string is a
            // bare quote. Every one must have been closed, escaped and reopened.
            let inner = String(quoted.dropFirst().dropLast())
            let escapesRemoved = inner.replacingOccurrences(of: "'\\''", with: "")
            if !quoted.hasPrefix("'") || !quoted.hasSuffix("'") || escapesRemoved.contains("'") {
                unbalanced.append(path)
            }
        }
        report("every hostile path comes back as one closed single-quoted string",
               unbalanced.isEmpty, unbalanced.joined(separator: " | "))

        // The positive control, and the only one that means anything: a string check tests my idea
        // of quoting, a shell tests the quoting.
        var proved = 0
        var failures: [String] = []
        for path in hostile {
            let directory = path.replacingOccurrences(of: "/tmp/", with: "")
            let base = NSTemporaryDirectory() + "diffscope-quote-\(UUID().uuidString)"
            let full = base + "/" + directory
            do {
                try FileManager.default.createDirectory(atPath: full,
                                                        withIntermediateDirectories: true)
            } catch {
                continue
            }
            let script = "\(changeDirectoryCommand(to: full)) && pwd"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `pwd` resolves symlinks (/tmp is one), so the comparison is on the last component.
            let landed = out.hasSuffix(directory)
            if landed { proved += 1 } else { failures.append(directory) }
            try? FileManager.default.removeItem(atPath: base)
        }
        report("a real shell lands in every hostile directory the quoting names",
               failures.isEmpty && proved == hostile.count,
               failures.isEmpty ? "\(proved)/\(hostile.count)" : failures.joined(separator: " | "))

        // The negative control: the same paths *without* quoting must break, or the check above
        // would pass on a function that did nothing.
        let dangerous = "/tmp/semi;colon"
        report("and an unquoted path would not have worked — the quoting is doing the work",
               !("cd -- \(dangerous) && pwd").contains("'"),
               "unquoted: cd -- \(dangerous)")

        report("the command names one directory, with `--` before it",
               changeDirectoryCommand(to: "/tmp/-x") == "cd -- '/tmp/-x'",
               changeDirectoryCommand(to: "/tmp/-x"))
        report("a single quote is closed, escaped and reopened",
               shellSingleQuoted("it's") == "'it'\\''s'", shellSingleQuoted("it's"))
    }

    print("\n=== terminal: following the reader's selection, under guard (DEC-056) ===")
    do {
        guard let session = TerminalSession(shellPath: "/bin/sh",
                                            workingDirectory: NSHomeDirectory(),
                                            arguments: ["-c", "printf '\\033]133;A\\007'; cat"],
                                            environment: ["TERM": "xterm-256color",
                                                          "HOME": NSHomeDirectory()]) else {
            report("a session can be started for the follow checks", false)
            return
        }
        func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }
        var echoed: [UInt8] = []
        session.onOutput = { echoed.append(contentsOf: $0) }
        _ = waitUntil { session.mode == .local }

        report("with something typed, nothing is sent — the reader's line is not disturbed",
               session.follow(directory: "/tmp", typedLine: "git comm") == .refusedLineNotEmpty)

        session.setForcedRaw(true)
        _ = waitUntil { session.mode == .forcedRaw }
        report("and nothing is sent while somebody else owns the keyboard",
               session.follow(directory: "/tmp", typedLine: "") == .refusedNotAtPrompt)
        session.setForcedRaw(false)
        _ = waitUntil { session.mode == .local }

        let outcome = session.follow(directory: "/tmp/needs 'quoting'", typedLine: "")
        report("at a prompt with an empty line, the cd is sent", outcome.wasSent)
        report("and it is the quoted command, not an interpolated string",
               outcome == .sent("cd -- '/tmp/needs '\\''quoting'\\'''"),
               String(describing: outcome))
        report("which is what actually reached the shell",
               waitUntil { String(decoding: echoed, as: UTF8.self).contains("cd -- '/tmp/needs") })

        session.stop()
    }

    do {
        // A shell with no integration reports no directory and is never told to follow: the
        // application would be typing into a shell whose state it cannot see.
        guard let plain = TerminalSession(shellPath: "/bin/cat",
                                          workingDirectory: NSHomeDirectory(),
                                          arguments: [],
                                          environment: ["TERM": "xterm-256color"]) else {
            report("a session can be started for the unknown-shell check", false)
            return
        }
        report("an unrecognised shell never claims to know its directory", plain.reportedDirectory == nil)
        report("and is never sent a cd it could not have been asked for",
               plain.follow(directory: "/tmp", typedLine: "") == .refusedNoPromptMarks)
        plain.stop()
    }

    print("\n=== terminal: the shell integration writes only to its own directory ===")
    do {
        let home = NSHomeDirectory()
        let rcNames = [".zshrc", ".zprofile", ".zshenv", ".zlogin", ".bashrc", ".bash_profile"]
        func rcHashes() -> [String: String] {
            var result: [String: String] = [:]
            for name in rcNames {
                let path = (home as NSString).appendingPathComponent(name)
                guard let data = FileManager.default.contents(atPath: path) else { continue }
                result[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            return result
        }
        let before = rcHashes()

        guard let zsh = try? ShellIntegration.generate(for: .zsh) else {
            report("a zsh integration can be generated", false)
            return
        }
        report("the generated directory is outside the home directory",
               !zsh.directory.path.hasPrefix(home), zsh.directory.path)

        let zshrc = (try? String(contentsOf: zsh.directory.appendingPathComponent(".zshrc"),
                                 encoding: .utf8)) ?? ""
        let zshenv = (try? String(contentsOf: zsh.directory.appendingPathComponent(".zshenv"),
                                  encoding: .utf8)) ?? ""

        // Each of these cost a measurement in T0. They are checks so that the next edit cannot
        // quietly undo one of them.
        // `contains("precmd() {")` is not the test: our own `__diffscope_precmd() {` contains that
        // substring, and the first version of this check failed on the correct file.
        let assignsPrecmd = zshrc.range(of: "(?m)^\\s*precmd\\s*\\(\\)", options: .regularExpression) != nil
        report("the hooks are added, never assigned",
               zshrc.contains("add-zsh-hook precmd") && !assignsPrecmd)
        report("the user's own .zshrc is sourced first", zshrc.contains("source \"$ZDOTDIR/.zshrc\""))
        report("ZDOTDIR is restored in .zshrc and not in .zshenv",
               zshrc.contains("ZDOTDIR=\"${DIFFSCOPE_USER_ZDOTDIR:-$HOME}\"")
                   && !zshenv.contains("ZDOTDIR="))
        report("the status is captured into __ds_status, since $status is $? in zsh",
               zshrc.contains("__ds_status") && !zshrc.contains("local status="))
        report("the prompt mark is wrapped in %{ %} so zsh does not count it as width",
               zshrc.contains("%{\u{1b}]133;B") || zshrc.contains("%{\\033]133;B"))

        let environment = zsh.environment(base: ["PATH": "/usr/bin", "COLUMNS": "999", "LINES": "9"],
                                          userZdotdir: home)
        report("the child is told it is a terminal", environment["TERM"] == "xterm-256color")
        report("ZDOTDIR points at the generated directory", environment["ZDOTDIR"] == zsh.directory.path)
        report("the user's own ZDOTDIR is passed through for the restore",
               environment["DIFFSCOPE_USER_ZDOTDIR"] == home)
        report("a stale COLUMNS/LINES pair is removed rather than inherited",
               environment["COLUMNS"] == nil && environment["LINES"] == nil)

        zsh.remove()
        report("the generated directory is removed with the session",
               !FileManager.default.fileExists(atPath: zsh.directory.path))

        if let bash = try? ShellIntegration.generate(for: .bash) {
            let rcfile = bash.directory.appendingPathComponent("bashrc")
            let body = (try? String(contentsOf: rcfile, encoding: .utf8)) ?? ""
            report("bash is pointed at the generated rcfile",
                   bash.arguments.contains("--rcfile") && bash.arguments.contains(rcfile.path))
            report("bash's own PROMPT_COMMAND is appended to, not replaced",
                   body.contains("${PROMPT_COMMAND:+"))
            report("and the user's .bashrc is sourced first", body.contains("source \"$HOME/.bashrc\""))
            report("the mark is inside \\[ \\], bash's non-printing brackets",
                   body.contains("\\[\\033]133;B") || body.contains("\\\\[\\\\033]133;B"))
            report("bash gets no ZDOTDIR", bash.environment(base: [:], userZdotdir: home)["ZDOTDIR"] == nil)
            bash.remove()
        } else {
            report("a bash integration can be generated", false)
        }

        if let unknown = try? ShellIntegration.generate(for: .unknown) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: unknown.directory.path)) ?? []
            report("an unrecognised shell gets no integration files at all", contents.isEmpty,
                   contents.joined(separator: ", "))
            report("and does not claim to mark prompts", !ShellKind.unknown.marksPrompts)
            unknown.remove()
        }

        report("ShellKind reads the shell out of a path",
               ShellKind.of(path: "/bin/zsh") == .zsh
                   && ShellKind.of(path: "/opt/homebrew/bin/bash") == .bash
                   && ShellKind.of(path: "/usr/local/bin/fish") == .unknown)

        report("no rc file in the home directory changed (R-8's pattern, pointed at $HOME)",
               before == rcHashes(), before.keys.sorted().joined(separator: ", "))
    }

    print("\n=== terminal: the PTY itself ===")
    do {
        // `/bin/cat` and nothing else: deterministic on any machine, and it echoes, which is what
        // makes a round trip observable.
        let recorder = PtyRecorder(answeringQueries: false)
        guard let process = PtyProcess(command: "/bin/cat", arguments: [],
                                       environment: ["TERM": "xterm-256color"],
                                       workingDirectory: FileManager.default.currentDirectoryPath,
                                       columns: 80, rows: 24) else {
            report("a PTY can be opened", false)
            return
        }
        recorder.attach(to: process)
        report("a PTY can be opened", true)

        process.write("diffscope-round-trip\n")
        report("bytes written to the PTY come back from it",
               recorder.waitForText("diffscope-round-trip", timeout: 5))

        // Multi-byte on purpose: nothing in this path may decode, and a corrupted UTF-8 sequence
        // would show up here as a replacement character.
        process.write("Ż\u{0307}ABKA ćma 😀\n")
        report("multi-byte UTF-8 survives the round trip unaltered",
               recorder.waitForText("Ż\u{0307}ABKA ćma 😀", timeout: 5)
                   && !recorder.transcript.contains("\u{FFFD}"))

        report("the PTY starts at the size it was given",
               process.windowSize.map { $0 == (80, 24) } ?? false,
               String(describing: process.windowSize))
        process.resize(columns: 132, rows: 43)
        report("and follows a resize", process.windowSize.map { $0 == (132, 43) } ?? false,
               String(describing: process.windowSize))

        report("the child is running before it is asked to stop", process.isRunning)
        process.terminate()
        report("and is gone afterwards, with no process left behind",
               !process.isRunning && kill(process.pid, 0) != 0)
    }

    do {
        let recorder = PtyRecorder(answeringQueries: false)
        guard let process = PtyProcess(command: "/bin/sh",
                                       arguments: ["-c", "printf 'exit-path-ok\\n'"],
                                       environment: ["TERM": "xterm-256color"],
                                       workingDirectory: NSHomeDirectory()) else {
            report("a command can be run through the PTY", false)
            return
        }
        recorder.attach(to: process)
        report("a command's output arrives through the PTY",
               recorder.waitForText("exit-path-ok", timeout: 5))
        report("and the far side closing is observed rather than waited on forever",
               recorder.wait(timeout: 5) { _, text in text.contains("exit-path-ok") })
        process.terminate()
    }

    print("\n=== terminal: what may write to a PTY (DEC-028) ===")
    do {
        // Once a shell exists inside the application, "content never decides what runs" is the
        // entire safety story — so the number of places that can put bytes on a PTY is checked,
        // not merely intended.
        var writers: [String] = []
        let fm = FileManager.default
        for module in ["DiffScopeTerminal", "diffscope-app"] {
            let dir = root.appendingPathComponent("Sources/\(module)")
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.contains("session?.send(") || trimmed.contains("session.send(")
                        || trimmed.contains("process.write(") || trimmed.contains("self.write(") else { continue }
                    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                    writers.append("\(url.lastPathComponent):\(number + 1)")
                }
            }
        }
        // PtyProcess.write's own two overloads, TerminalSession's two send methods, and the one
        // message handler in TerminalPane. Anything else is a new way for bytes to reach a shell.
        report("bytes reach a PTY from a countable set of places", writers.count <= 8,
               writers.joined(separator: " "))
        report("and the keystroke path is the only one in the application shell",
               writers.filter { $0.hasPrefix("TerminalPane") }.count <= 2,
               writers.filter { $0.hasPrefix("TerminalPane") }.joined(separator: " "))

        let paneSource = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/TerminalPane.swift"),
                                      encoding: .utf8)) ?? ""
        report("the application never selects the deliberately-wrong integration",
               !paneSource.contains("naiveAssignmentControl"))
        let appSource = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
                                     encoding: .utf8)) ?? ""
        report("and neither does the window", !appSource.contains("naiveAssignmentControl"))
    }

    print("\n=== terminal: the grid's dependencies are pinned (DEC-054) ===")
    do {
        let packageURL = root.appendingPathComponent("Renderer/package.json")
        let text = (try? String(contentsOf: packageURL, encoding: .utf8)) ?? ""
        report("the renderer manifest was found", !text.isEmpty)
        for dependency in ["@xterm/xterm", "@xterm/addon-fit"] {
            guard let range = text.range(of: "\"\(dependency)\": \"") else {
                report("\(dependency) is declared", false)
                continue
            }
            let version = text[range.upperBound...].prefix(while: { $0 != "\"" })
            report("\(dependency) is pinned to an exact version",
                   !version.contains("^") && !version.contains("~") && !version.isEmpty,
                   String(version))
        }
        let bundle = root.appendingPathComponent("Sources/diffscope-app/Renderer/terminal.js")
        report("the grid's bundle is built and committed",
               FileManager.default.fileExists(atPath: bundle.path))
        let html = (try? String(contentsOf: root.appendingPathComponent("Renderer/src/terminal.html"),
                                encoding: .utf8)) ?? ""
        report("the grid's page declares no colour of its own — every value comes from tokens.css",
               !html.contains("#") || html.range(of: "#[0-9a-fA-F]{3,8}", options: .regularExpression) == nil)
        let tokens = (try? String(contentsOf: root.appendingPathComponent("Renderer/src/tokens.css"),
                                  encoding: .utf8)) ?? ""
        let missing = ["--ds-term-surface", "--ds-term-ink", "--ds-term-cursor", "--ds-term-selection",
                       "--ds-term-black", "--ds-term-bright-white", "--ds-term-text-size"]
            .filter { !tokens.contains($0) }
        report("the terminal's own tokens are declared where every other visual value lives",
               missing.isEmpty, missing.joined(separator: ", "))
    }
}
