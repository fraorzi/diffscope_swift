import Foundation

/// The application the owner opens from Spotlight is the commit they last made.
///
/// This is the one obligation in the repository that a document cannot discharge. It was asked for
/// as *never having to ask again*, and the only mechanism with that property is a hook: the install
/// happens because a commit happened, not because anybody remembered. What a check can do is make
/// sure the mechanism is still wired, because a hook that has quietly stopped running looks exactly
/// like one that has nothing to do.
///
/// Four things, and the fourth is the one that rots: `core.hooksPath`. It lives in `.git/config`,
/// which is **not** part of the repository, so a fresh clone has the hooks on disk and none of them
/// armed. The check fails there on purpose and prints the single command that arms them.
func runInstallChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }
    let fm = FileManager.default

    print("\n=== the installed application is the commit that was made ===")

    func executable(_ path: String) -> Bool {
        fm.isExecutableFile(atPath: path)
    }
    func text(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    report("Scripts/make-app.sh assembles the bundle and is executable",
           executable("Scripts/make-app.sh"))
    report("Scripts/install.sh installs it and is executable",
           executable("Scripts/install.sh"))

    // One description of what the application is. `package.sh` owes a tester a proof run and a zip;
    // the installer owes the owner a current /Applications entry. Both must be assembling the same
    // bundle, or the thing that was proved is not the thing that was installed.
    report("the release script and the installer assemble the same bundle",
           text("Scripts/package.sh").contains("Scripts/make-app.sh")
               && text("Scripts/install.sh").contains("Scripts/make-app.sh"))

    for hook in ["post-commit", "post-merge"] {
        let path = ".githooks/\(hook)"
        report("\(hook) runs the installer and is executable",
               executable(path) && text(path).contains("Scripts/install.sh"))
    }

    // The installer must not replace a working application with a failed build: it stages into
    // `dist/` and only swaps when there is an executable to swap in.
    report("a failed build cannot replace the installed application",
           text("Scripts/install.sh").contains("[ -x \"$APP/Contents/MacOS/DiffScope\" ]"))

    let configured = (try? shellOutput("git config core.hooksPath")) ?? ""
    report("this clone has the hooks armed",
           configured.trimmingCharacters(in: .whitespacesAndNewlines) == ".githooks",
           configured.isEmpty
               ? "run: git config core.hooksPath .githooks"
               : "core.hooksPath is \(configured.trimmingCharacters(in: .whitespacesAndNewlines))")
}

private func shellOutput(_ command: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
