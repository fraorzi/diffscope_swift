import DiffScopeGit
import Foundation

/// The two pipes, and the hang that lived between them.
///
/// Both runners used to read stdout to EOF and *only then* read stderr. stdout reaches EOF when git
/// and every process git started have exited, so a `pre-commit` hook writing more than the pipe
/// buffer to a stderr nobody is draining blocks in `write(2)` forever. Darwin grows a pipe to
/// 65536 bytes and stops: 64 KB of hook output commits in 0.28 s, 64 KB + 1 never returns. git
/// waits for the hook, the caller waits for a stdout EOF that can never arrive, and on the write
/// path the caller was the main thread — so the window froze rather than merely stalling. Any
/// `eslint` or `lint-staged` report longer than the buffer reproduced it.
///
/// These arms drive the product's own `GitWriter` and `GitRunner` through exactly that shape, and
/// then prove the reverted form still hangs, so the assertions above are not decoration.
func runHookDrainChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let fm = FileManager.default
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("diffscope-hookdrain-\(UUID().uuidString)")
    try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: scratch) }

    /// Four times the 65536 bytes Darwin grows a pipe to, so the block is certain rather than
    /// likely. The hook `cat`s this file instead of looping, so the byte count is exact and the
    /// measurement is of the drain rather than of a shell.
    let noiseBytes = 256 * 1024
    let noise = scratch.appendingPathComponent("report.txt")
    let line = "eslint  src/components/Very/Deeply/Nested/Thing.tsx  47:9  error  unused\n"
    var noiseText = ""
    while noiseText.utf8.count < noiseBytes { noiseText += line }
    noiseText = String(noiseText.prefix(noiseBytes))
    try? Data(noiseText.utf8).write(to: noise)

    /// A `pre-commit` that says a great deal and then approves the commit. The exit code is 0 on
    /// purpose: a refusal is already covered by DEC-113, and what is under test here is the
    /// *volume*, not the verdict.
    func installNoisyPreCommit(in repository: URL) {
        let hooks = repository.appendingPathComponent(".git/hooks")
        try? fm.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try? Data("#!/bin/sh\ncat \(noise.path) >&2\nexit 0\n".utf8).write(to: hook)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    let message = scratch.appendingPathComponent("message.txt")
    try? Data("noisy hook\n".utf8).write(to: message)

    let writer = GitWriter()

    /// The baseline every bound below is a multiple of. Absolute seconds are a bound on the
    /// machine, not on the behaviour (`BudgetChecks.swift` §1), and this suite runs alongside
    /// whatever else the owner has open. Load inflates the baseline and the bound together.
    var fixedElapsed: TimeInterval = 0

    print("\n=== the sequential drain is gone from both runners, and cannot come back unnoticed ===")
    do {
        // Cheapest arm, so it runs first: with the fix reverted the arms below do not fail, they
        // *hang*, and a suite that wedges names nothing. These two lines are what a reverted build
        // prints before it stops. They also cover the third call site somebody adds next year — the
        // sequential pair is a two-line signature that should never reappear in the Git module.
        let sources = ["Sources/DiffScopeGit/GitRunner.swift", "Sources/DiffScopeGit/GitWrite.swift"]
        var offenders: [String] = []
        for path in sources {
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\n")
            for index in lines.indices.dropLast()
            where lines[index].contains("outPipe.fileHandleForReading.readDataToEndOfFile()")
                && lines[index + 1].contains("errPipe.fileHandleForReading.readDataToEndOfFile()") {
                offenders.append("\(path):\(index + 1)")
            }
        }
        report("neither runner reads stdout to EOF and then stderr", offenders.isEmpty,
               offenders.joined(separator: ", "))
        report("and both go through the one drain that overlaps them",
               sources.allSatisfy {
                   ((try? String(contentsOfFile: $0, encoding: .utf8)) ?? "").contains("drainConcurrently(")
               })
    }

    print("\n=== the two pipes are drained at once: a hook that floods stderr must not hang a commit ===")
    do {
        let repository = makeRepository("noisy-hook", in: scratch)
        try? Data("one\n".utf8).write(to: repository.appendingPathComponent("a.txt"))
        _ = try? writer.run(.addPaths(["a.txt"]), in: repository)
        installNoisyPreCommit(in: repository)

        let started = Date()
        let result = try? writer.run(.commit(messageFile: message.path, amend: false, allowEmpty: false),
                                     in: repository)
        fixedElapsed = Date().timeIntervalSince(started)

        report("a commit behind a hook that writes 256 KB to stderr completes",
               result?.succeeded == true,
               result.map { "exit \($0.exitCode)" } ?? "the call never returned a result")
        report("and the hook's whole report is captured, not the first buffer of it",
               (result?.standardError.utf8.count ?? 0) >= noiseBytes,
               "\(result?.standardError.utf8.count ?? 0) bytes of \(noiseBytes)")
        // Both streams, not one: draining stderr while dropping stdout would pass the line above
        // and lose the summary DEC-113 needs when a hook refuses on stdout instead.
        report("and stdout survived the same invocation",
               !(result?.standardOutput.isEmpty ?? true),
               String(result?.standardOutput.count ?? 0))
        report("and the committed history has the commit in it",
               shell(["log", "--oneline"], in: repository).contains("noisy hook"),
               shell(["log", "--oneline"], in: repository))
    }

    print("\n=== the read runner drains both too: a textconv or filter may be as noisy as a hook ===")
    do {
        // A stand-in for git that writes 256 KB to **stderr first** and only then to stdout. Reads
        // do not run hooks, but they do run `filter.*` and `diff.*.textconv` programs, and the
        // stand-in makes the ordering the pathological one rather than hoping to hit it.
        let standIn = scratch.appendingPathComponent("noisy-git.sh")
        try? Data("#!/bin/sh\ncat \(noise.path) >&2\ncat \(noise.path)\nexit 0\n".utf8).write(to: standIn)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.path)

        let repository = makeRepository("noisy-read", in: scratch)
        let result = try? GitRunner(executableURL: standIn).run(.statusPorcelain(), in: repository)

        report("a read whose helper floods stderr before stdout completes",
               result?.succeeded == true,
               result.map { "exit \($0.exitCode)" } ?? "the call never returned a result")
        report("and both streams come back whole",
               (result?.standardOutput.count ?? 0) >= noiseBytes
                   && (result?.standardError.utf8.count ?? 0) >= noiseBytes,
               "stdout \(result?.standardOutput.count ?? 0), stderr \(result?.standardError.utf8.count ?? 0)")
    }

    print("\n=== negative control: the drain the fix removed still hangs on the same repository ===")
    do {
        // The reverted code, written out by hand and run against a real repository with the same
        // hook. This is the only honest way to show the arms above are load-bearing: assert on the
        // shape that was there, not on the shape that is.
        let repository = makeRepository("noisy-hook-control", in: scratch)
        try? Data("one\n".utf8).write(to: repository.appendingPathComponent("a.txt"))
        _ = try? writer.run(.addPaths(["a.txt"]), in: repository)
        installNoisyPreCommit(in: repository)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path, "commit", "-F", message.path, "--cleanup=strip"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "t"; environment["GIT_AUTHOR_EMAIL"] = "t@t"
        environment["GIT_COMMITTER_NAME"] = "t"; environment["GIT_COMMITTER_EMAIL"] = "t@t"
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        final class Box: @unchecked Sendable { var finished = false }
        let box = Box()
        let sequential = DispatchGroup()

        var launched = true
        do { try process.run() } catch { launched = false }
        report("the control's commit launches", launched, launched ? "" : "could not run git")

        if launched {
            DispatchQueue.global(qos: .userInitiated).async(group: sequential) {
                // *** THE BUG, ON PURPOSE. *** stdout to EOF, and only afterwards stderr — which is
                // what `GitRunner.run` and `GitWriter.invoke` both did until this milestone.
                _ = outPipe.fileHandleForReading.readDataToEndOfFile()
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                box.finished = true
            }

            // Ten times the fixed path's own cost on this machine, in this build, under whatever
            // load is present. The assertion is that the control did **not** finish, and load can
            // only make a run slower — so unlike an upper bound, this direction cannot be made to
            // fail by a busy machine. It fails only if the deadlock is absent, which is the thing
            // being controlled for.
            let bound = fixedElapsed * 10 + 0.5
            let verdict = sequential.wait(timeout: .now() + bound)
            report("the sequential drain does not finish, where the concurrent one took a fraction of the bound",
                   verdict == .timedOut && !box.finished,
                   String(format: "bound %.2f s against a %.2f s baseline", bound, fixedElapsed))

            // And the diagnosis, rather than a guess at it: read the stderr the hook is blocked on
            // and the whole chain unwedges — hook exits, git exits, stdout reaches EOF, the stuck
            // reader returns. Nothing else about the invocation changed.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let released = sequential.wait(timeout: .now() + fixedElapsed * 60 + 10)
            report("and it was stderr backpressure: draining stderr releases the same invocation",
                   released == .success, released == .success ? "" : "still stuck after stderr was read")
            if released != .success { process.terminate() }
        } else {
            report("and it was stderr backpressure: draining stderr releases the same invocation", false,
                   "the control never launched")
        }
    }
}
