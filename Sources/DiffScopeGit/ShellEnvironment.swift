import Foundation

/// The `PATH` the reader's own shell has, for the programs git runs on their behalf (DEC-114).
///
/// **An application launched from Spotlight does not inherit a terminal's environment.** launchd
/// hands it `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else, while the reader's `node`, `npx`,
/// `pnpm` and everything else live where their shell puts them — under `~/.nvm/versions/node/…`, in
/// `/opt/homebrew/bin`, in `~/.bun/bin`. Git does not care. Git's **hooks** do: husky's `commit-msg`
/// is `npx --no-install commitlint`, and with the launchd `PATH` that is `npx: command not found`,
/// exit 127, and a commit refused for a reason that has nothing to do with the commit.
///
/// The owner reported it as a rejection they could not explain: the same commit, from the same
/// repository, is accepted in a terminal and refused in the window.
///
/// **The login shell is asked once and the answer is kept.** `$SHELL -l -c` runs the reader's rc
/// files, which is the only place their `PATH` exists — nvm writes it there and nowhere a process
/// can look it up. The application already starts a login shell for its terminal pane, so this is
/// not a new kind of side effect; what is new is that the answer is now used for git.
///
/// **It never blocks and it never breaks.** The resolution runs off the main thread with a deadline;
/// if the shell is slow, missing, or prints something that is not a `PATH`, the inherited
/// environment stands and hooks fail exactly as they did before — which is to say the failure mode
/// of this code is *the behaviour it replaces*, and there is no state in which it is worse.
public struct ShellEnvironment: Sendable {
    /// How long the login shell has to answer. A shell that takes longer than this has an rc file
    /// doing something a git client should not be waiting for.
    public static let deadline: TimeInterval = 3

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?
    nonisolated(unsafe) private static var resolved = false

    /// The `PATH` to give git, or `nil` while nothing better than the inherited one is known.
    public static var loginPath: String? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Asks the login shell, once. Safe to call from anywhere; later calls do nothing.
    ///
    /// - Parameter shell: the shell to ask, for the check that has to know what the answer was.
    @discardableResult
    public static func resolve(shell: String? = nil) -> String? {
        lock.lock()
        if resolved, shell == nil {
            defer { lock.unlock() }
            return cached
        }
        lock.unlock()

        let path = read(shell: shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")

        lock.lock()
        if shell == nil {
            resolved = true
            if let path { cached = path }
        }
        lock.unlock()
        return path
    }

    /// Runs the shell and returns what it prints, when that looks like a `PATH` at all.
    ///
    /// The command is `printf %s "$PATH"` rather than `echo $PATH`: a shell that prints a banner —
    /// and rc files do print banners — would otherwise hand back a `PATH` with a greeting in it. The
    /// last line is taken for the same reason, and the result has to contain a `/` and at least one
    /// separator before it is believed.
    public static func read(shell: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        // An rc file that reads from the terminal would otherwise wait for a terminal that is not
        // there. There is nothing to say, and saying nothing immediately is the answer.
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(Self.deadline)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard text.contains("/"), text.contains(":") else { return nil }
        return text
    }

    /// The environment to hand a git invocation: the caller's, with the login `PATH` when there is
    /// one and the inherited one otherwise.
    public static func applied(to environment: [String: String]) -> [String: String] {
        guard let path = loginPath else { return environment }
        var copy = environment
        copy["PATH"] = path
        return copy
    }
}
