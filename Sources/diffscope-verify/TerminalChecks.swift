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
