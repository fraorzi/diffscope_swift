import Foundation
import DiffScopeGit

/// What the box beside a path says, and whether the path it says it about is the right one.
///
/// Two defects, both found by the UI audit of 2026-08-30, both in the same six lines.
///
/// **The key never matched a non-ASCII path.** `staging(in:)` was left on the line-based status
/// form when the file list moved to `-z` (DEC-111), and it stripped quotes by hand. `core.quotePath`
/// is on by default, so `żółć.txt` arrives as `"\305\274\303\263\305\202\304\207.txt"` and trimming
/// the quotes leaves the escapes. Every non-ASCII file drew *not staged* whatever the index held,
/// and — because the click's verb is chosen from the drawn state — could never be taken back out of
/// the commit.
///
/// **A conflict drew the same mark as a staged-and-edited file.** Every unmerged status pair fell
/// through to `.partial`, so the control offered *stage* and *unstage* as a reversible pair over an
/// operation that is not: `git add` on an unmerged path collapses stages 1, 2 and 3 into one blob
/// and `git restore --staged` cannot put them back.
func runStagingStateChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== the staging box names the right path, and knows a conflict from a part ===")

    guard let root = try? FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask,
        appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()), create: true) else {
        report("a scratch directory could be made", false)
        return
    }
    defer { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    func makeRepository(_ name: String) -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        git(["init", "-q", "-b", "main"], in: url)
        git(["config", "user.email", "check@example.invalid"], in: url)
        git(["config", "user.name", "check"], in: url)
        return url
    }

    let reader = RepositoryStateReader()

    // ---- the non-ASCII path -------------------------------------------------------------------

    let quoted = makeRepository("quoted")
    // Left at its default on purpose. `core.quotePath` being on is the condition, and a check that
    // turns it off would be measuring a repository nobody has.
    let awkward = "żółć.txt"
    try? "one\n".write(to: quoted.appendingPathComponent(awkward), atomically: true, encoding: .utf8)
    git(["add", "--", awkward], in: quoted)
    git(["commit", "-qm", "first"], in: quoted)
    try? "two\n".write(to: quoted.appendingPathComponent(awkward), atomically: true, encoding: .utf8)
    git(["add", "--", awkward], in: quoted)
    try? "three\n".write(to: quoted.appendingPathComponent(awkward), atomically: true, encoding: .utf8)

    let states = reader.staging(in: quoted)
    report("a non-ASCII path is keyed by the name the rest of the application uses",
           states[awkward] != nil,
           "keys: \(states.keys.sorted().joined(separator: " | "))")
    report("and its box says staged-then-edited, which is what the index holds",
           states[awkward] == .partial, String(describing: states[awkward]))

    // The negative control, and it has to be the *old* parse rather than a hostile string: the
    // defect was not a missing branch, it was a plausible one. This is what the code did before.
    let raw = git(["status", "--porcelain", "-uall"], in: quoted)
    var trimmedKeys: [String] = []
    for line in raw.split(separator: "\n") {
        let characters = Array(line)
        guard characters.count > 3 else { continue }
        trimmedKeys.append(String(characters[3...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }
    report("control: the hand-trimmed parse this replaced does not produce that key",
           !trimmedKeys.contains(awkward),
           "it produced: \(trimmedKeys.joined(separator: " | "))")

    // ---- the conflict -------------------------------------------------------------------------

    let merging = makeRepository("merging")
    let path = "c.txt"
    try? "base\n".write(to: merging.appendingPathComponent(path), atomically: true, encoding: .utf8)
    git(["add", "--", path], in: merging)
    git(["commit", "-qm", "base"], in: merging)
    git(["checkout", "-q", "-b", "other"], in: merging)
    try? "theirs\n".write(to: merging.appendingPathComponent(path), atomically: true, encoding: .utf8)
    git(["commit", "-qam", "theirs"], in: merging)
    git(["checkout", "-q", "main"], in: merging)
    try? "ours\n".write(to: merging.appendingPathComponent(path), atomically: true, encoding: .utf8)
    git(["commit", "-qam", "ours"], in: merging)
    git(["merge", "other"], in: merging)

    let stages = git(["ls-files", "-u", "--", path], in: merging)
        .split(separator: "\n").count
    report("the scratch repository really is mid-conflict", stages == 3, "\(stages) stages")
    report("an unmerged path is drawn as a conflict, not as a part",
           reader.staging(in: merging)[path] == .conflicted,
           String(describing: reader.staging(in: merging)[path]))

    // Both controls on the classifier itself, because the mapping is the thing that was wrong and a
    // repository can only exhibit one pair at a time.
    report("control: every unmerged pair reaches it",
           ["UU", "AA", "DD", "AU", "UA", "DU", "UD"].allSatisfy { pair in
               let characters = Array(pair)
               return RepositoryStateReader.staging(index: characters[0],
                                                    worktree: characters[1]) == .conflicted
           })
    report("control: staged-then-edited is still a part, not a conflict",
           RepositoryStateReader.staging(index: "M", worktree: "M") == .partial)
}
