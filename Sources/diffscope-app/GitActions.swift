import AppKit
import DiffScopeEngine
import DiffScopeGit
import DiffScopeShell

/// Version two's verbs, where the window meets `WriteActions` (DEC-092).
///
/// Three rules hold everywhere in this file, and they are the reason it is one file rather than
/// twenty methods scattered through the window:
///
/// 1. **Every write asks what `Confirmation.required(for:)` says to ask** — never what the call
///    site thinks is reasonable.
/// 2. **Every write is followed by a read.** The index is shared with WebStorm and with the
///    terminal drawer; the interface's picture of it is refreshed from git rather than patched.
/// 3. **Every failure lands in the status line as git's own words.** A Git interface that
///    swallows `error: your local changes would be overwritten` and says *could not switch branch*
///    is one a reader cannot get themselves out of.
extension Controller {

    // ---- the picture of the repository ---------------------------------------------------------

    /// Re-reads everything version two draws. Cheap enough to run after every write: five plumbing
    /// reads against a repository whose objects are already warm.
    func refreshGitState() {
        guard let repository = state.selectedRepository else {
            state.staging = [:]; state.branches = []; state.stashes = []; state.operation = .none
            operationBanner?.show(.none)
            return
        }
        let previousStaging = state.staging
        state.staging = gitState.staging(in: repository.url)
        state.branches = gitState.branches(in: repository.url)
        state.stashes = gitState.stashes(in: repository.url)
        let head = (try? reader.headState(of: repository.url)) ?? .unborn(intendedBranch: nil)
        state.operation = gitState.operation(in: repository.url, head: head)

        operationBanner?.show(state.operation)
        bannerHeightConstraint?.constant = operationBanner?.isHidden == false ? Theme.bannerHeight : 0
        commitBox?.branchName = head.displayText
        commitBox?.status.stringValue = commitSummaryLine()
        branchButton?.title = head.displayText
        updateSyncButton()
        // **Only the boxes that changed.** Both callers run `reloadFiles()` immediately before this,
        // and `reloadFiles` already redraws what moved — so an unconditional reload here rebuilt
        // sixty-three stacks of views one line after DEC-112 had carefully rebuilt one. The staging
        // read above is a *second* read of the index, so it can legitimately differ from the one
        // `reloadFiles` made; what cannot be justified is redrawing when it does not.
        let changed = state.fileRows.indices.filter { index in
            guard let path = state.fileRows[index].file?.path else { return false }
            return previousStaging[path] != state.staging[path]
        }
        redraw.reloadRows(fileTable, .file, IndexSet(changed), reason: "refreshGitState")
    }

    /// `3 files staged · 2 not staged`, or the reason there is nothing to commit. In `ChromeLabels`'
    /// spirit — composed in one place, so a check can read the sentence rather than the layout.
    func commitSummaryLine() -> String {
        let staged = state.staging.values.filter { $0 != .none }.count
        let unstaged = state.staging.values.filter { $0 != .all }.count
        if staged == 0 && unstaged == 0 { return "nothing to commit" }
        if staged == 0 { return "\(unstaged) changed, none staged" }
        return "\(staged) staged" + (unstaged > 0 ? " · \(unstaged) not staged" : "")
    }

    func updateSyncButton() {
        guard let syncButton else { return }
        let current = state.branches.first { $0.isCurrent }
        if let current, !current.hasUpstream {
            syncButton.mode = .publish
        } else if let current, current.behind > 0 {
            syncButton.mode = .pull(current.behind)
        } else if let current, current.ahead > 0 {
            syncButton.mode = .push(current.ahead)
        } else {
            syncButton.mode = .fetch
        }
    }

    /// What the box beside a path draws. `partial` is a file staged and then edited again — the
    /// state that exists in git and that a two-state checkbox has to lie about.
    func inclusion(of path: String) -> InclusionState {
        switch state.staging[path] ?? .none {
        case .none: return .none
        case .partial: return .partial
        case .all: return .all
        case .conflicted: return .conflicted
        }
    }

    // ---- staging -------------------------------------------------------------------------------

    /// The box was clicked. A file that is not fully staged becomes staged; one that is comes back
    /// out — which is the hybrid DEC-092 chose: the checkbox means *in this commit*, and it is a
    /// real index write rather than a note the interface keeps.
    @objc func toggleInclusion(_ sender: CheckButton) {
        guard let repository = state.selectedRepository,
              state.fileRows.indices.contains(sender.tag),
              let file = state.fileRows[sender.tag].file else { return }
        // **A conflict is not a checkbox question.** `git add` on an unmerged path collapses
        // stages 1, 2 and 3 into a single blob, and `git restore --staged` sets the entry to HEAD
        // without restoring them — so the pair this control offers is an irreversible operation
        // and an inverse that does not exist. Taking it silently resolved the conflict to whatever
        // was in the working tree, conflict markers included, and printed "unstage — done".
        guard sender.inclusion != .conflicted else {
            statusLabel.stringValue =
                "\(file.path) has a merge conflict — resolve it first"
                + (KeyboardMap.binding(id: "git.resolve").map { " (\($0.shortcut))" } ?? "")
                + ", because staging it would discard the other side"
            return
        }
        let verb = sender.inclusion == .all ? "unstage" : "stage"
        perform(verb) {
            if sender.inclusion == .all {
                try self.actions.unstage(paths: [file.path], in: repository.url,
                                         hasCommits: self.hasCommits(repository))
            } else {
                try self.actions.stage(paths: [file.path], in: repository.url)
            }
        }
        // **Say why the row went** (DEC-106). Two of the four scopes answer a question a staged file
        // changes the answer to, so ticking its box correctly removes it from the list — and to the
        // reader that is a file moving under the pointer for no stated reason, which is how it was
        // reported. The selection already stays where it was; this says what happened to the row.
        guard !state.files.contains(where: { $0.path == file.path }) else { return }
        switch state.scope {
        case .unstagedVsIndex, .stagedVsHead:
            let name = (file.path as NSString).lastPathComponent
            statusLabel.stringValue = "\(verb) — \(name) is no longer part of "
                + "\(state.scope.title); it is in \(ComparisonScope.allLocalVsHead.title)"
        case .allLocalVsHead, .branchVsMergeBase:
            break
        }
    }

    func hasCommits(_ repository: RepositorySnapshot) -> Bool {
        if case .unborn = (try? reader.headState(of: repository.url)) ?? .unborn(intendedBranch: nil) {
            return false
        }
        return true
    }

    /// The named verb, as opposed to the box. `git add` on an unmerged path is git's own way of
    /// saying *I have resolved this*, so this route stays open — but it asks first, and the question
    /// names what goes, because the collapse cannot be undone from inside this application.
    @objc func stageSelectedFile() {
        guard let repository = state.selectedRepository, let file = selectedFilePath() else { return }
        if state.staging[file] == .conflicted,
           !confirm("Mark “\(file)” as resolved?",
                    detail: "It still has a merge conflict. Staging it keeps the file as it stands "
                        + "now — conflict markers included, if any are left — and discards the other "
                        + "side. There is no undo for this.",
                    verb: "Mark Resolved") { return }
        perform("stage") { try self.actions.stage(paths: [file], in: repository.url) }
    }

    @objc func unstageSelectedFile() {
        guard let repository = state.selectedRepository, let file = selectedFilePath() else { return }
        perform("unstage") {
            try self.actions.unstage(paths: [file], in: repository.url,
                                     hasCommits: self.hasCommits(repository))
        }
    }

    /// **Conflicted paths are left out, and the count says so.** Sweeping them in would resolve
    /// every conflict in the repository to whatever the working tree happens to hold, irreversibly,
    /// from a verb whose name promises breadth rather than a decision about any one file.
    @objc func stageEverything() {
        guard let repository = state.selectedRepository else { return }
        let all = state.fileRows.compactMap { $0.file?.path }
        let paths = all.filter { state.staging[$0] != .conflicted }
        guard !paths.isEmpty else {
            statusLabel.stringValue = all.isEmpty
                ? "nothing to stage"
                : "every changed file has a merge conflict — resolve them first"
                    + (KeyboardMap.binding(id: "git.resolve").map { " (\($0.shortcut))" } ?? "")
            return
        }
        perform("stage") { try self.actions.stage(paths: paths, in: repository.url) }
        let skipped = all.count - paths.count
        if skipped > 0 {
            let resolve = KeyboardMap.binding(id: "git.resolve").map { " (\($0.shortcut) to resolve)" } ?? ""
            statusLabel.stringValue = "stage — \(paths.count) staged · \(skipped) left out "
                + "for having a merge conflict" + resolve
        }
    }

    @objc func unstageEverything() {
        guard let repository = state.selectedRepository else { return }
        let paths = state.fileRows.compactMap { $0.file?.path }
        guard !paths.isEmpty else { return }
        perform("unstage") {
            try self.actions.unstage(paths: paths, in: repository.url,
                                     hasCommits: self.hasCommits(repository))
        }
    }

    /// The one operation in this menu that can lose work no object database holds. It names the
    /// file, says where an untracked one goes, and has no keystroke (DEC-092 §5, point 5).
    @objc func discardSelectedFile() {
        guard let repository = state.selectedRepository,
              let row = state.fileRows.indices.first(where: { state.fileRows[$0].file != nil
                  && $0 == fileTable.selectedRow }),
              let file = state.fileRows[row].file else { return }
        let untracked = file.kind == .untracked
        let question = untracked
            ? "Move “\(file.path)” to the Trash?"
            : "Discard every change to “\(file.path)”?"
        let detail = untracked
            ? "The file is not in the repository, so it can only be recovered from the Trash."
            : "The file goes back to what is in the index. There is no undo for this."
        guard confirm(question, detail: detail, verb: untracked ? "Move to Trash" : "Discard") else { return }
        perform("discard") {
            try self.actions.discard(tracked: untracked ? [] : [file.path],
                                     untracked: untracked ? [file.path] : [], in: repository.url)
        }
    }

    /// **Stage the hunk the reader is standing in** — M12's own operation, reached from the
    /// keyboard rather than from a click, because the change stops are already where the reader
    /// navigates and asking the page for the caret's line needs nothing new drawn.
    @objc func stageHunkUnderCursor() { stageHunk(unstage: false) }
    @objc func unstageHunkUnderCursor() { stageHunk(unstage: true) }

    func stageHunk(unstage: Bool) {
        guard let repository = state.selectedRepository, let file = state.selectedFile else {
            statusLabel.stringValue = "no file selected"
            return
        }
        bridge("window.diffscopeCurrentLine()") { [weak self] value, _ in
            guard let self else { return }
            let line = (value as? Int) ?? (value as? NSNumber)?.intValue ?? 1
            let scope: ComparisonScope = unstage ? .stagedVsHead : .unstagedVsIndex
            guard let pair = try? self.scopes.pinnedPair(for: file, scope: scope,
                                                         in: repository.url) else { return }
            let old = splitLines(pair.oldBytes)
            let new = splitLines(pair.newBytes)
            guard case let .exact(walk) = stagingWalk(old: old, new: new) else {
                self.statusLabel.stringValue =
                    "this file is too far apart for hunk staging — stage the whole file"
                return
            }
            let selection = hunkSelection(walk: walk, aroundNewLine: line)
            guard !selection.isEmpty,
                  let patch = stagingPatch(path: file.path, old: old, new: new,
                                           walk: walk, selection: selection) else {
                self.statusLabel.stringValue = "nothing to \(unstage ? "unstage" : "stage") here"
                return
            }
            self.perform(unstage ? "unstage hunk" : "stage hunk") {
                try self.actions.apply(patch: patchData(patch), to: .index, reverse: unstage,
                                       intentToAdd: file.kind == .untracked ? file.path : nil,
                                       in: repository.url)
            }
        }
    }

    /// Staging a **selection of lines** — the operation this product can prove and other clients
    /// cannot (INV-6). Called from the renderer with the lines the reader picked.
    func stageSelection(_ lines: [Int], from file: ChangedFile, unstage: Bool) {
        guard let repository = state.selectedRepository else { return }
        let scope: ComparisonScope = unstage ? .stagedVsHead : .unstagedVsIndex
        guard let pair = try? scopes.pinnedPair(for: file, scope: scope, in: repository.url) else { return }
        let old = splitLines(pair.oldBytes)
        let new = splitLines(pair.newBytes)
        guard case let .exact(walk) = stagingWalk(old: old, new: new) else {
            statusLabel.stringValue = "this file is too far apart for line staging — stage the whole file"
            return
        }
        // The reader picks *lines of the new side*; the selection is the walk steps those lines are.
        let wanted = Set(lines)
        var selection: Set<Int> = []
        for (position, step) in walk.enumerated() {
            switch step {
            case let .addition(index) where wanted.contains(index): selection.insert(position)
            case let .removal(index) where wanted.contains(-index - 1): selection.insert(position)
            default: break
            }
        }
        guard let patch = stagingPatch(path: file.path, old: old, new: new,
                                       walk: walk, selection: selection) else { return }
        perform(unstage ? "unstage lines" : "stage lines") {
            try self.actions.apply(patch: patchData(patch), to: .index, reverse: unstage,
                                   intentToAdd: file.kind == .untracked ? file.path : nil,
                                   in: repository.url)
        }
    }

    // ---- committing ----------------------------------------------------------------------------

    @objc func commitStaged() {
        guard let repository = state.selectedRepository else { return }
        let summary = commitBox.summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let amending = commitBox.amend.state == .on
        guard !summary.isEmpty else {
            statusLabel.stringValue = "a commit needs a summary"
            commitBox.window?.makeFirstResponder(commitBox.summary)
            return
        }
        // An empty commit is possible and is asked for by name (DEC-092) — but it is asked for,
        // rather than being what happens when nothing was staged.
        let nothingStaged = state.staging.values.allSatisfy { $0 == .none }
        if nothingStaged, !amending {
            guard confirm("Nothing is staged. Commit anyway?",
                          detail: "The commit will contain no changes. That is sometimes what you want — a marker, or a trigger — and it is never what you want by accident.",
                          verb: "Commit empty") else { return }
        }
        let failure = perform("commit") {
            _ = try self.actions.commit(summary: summary, description: self.commitBox.descriptionText,
                                        amend: amending, allowEmpty: nothingStaged,
                                        in: repository.url)
            DispatchQueue.main.async { self.commitBox.clear() }
        }
        // **A refused commit says so where the commit was asked for** (DEC-113). The status line is a
        // sentence at the bottom of the window; the reader's eyes are on the button they just
        // pressed, and a hook that rejects a message leaves everything else looking untouched — the
        // fields still full, the files still staged. That is *nothing happened* to anybody who was
        // not watching the status line, which is how it was reported.
        //
        // The first line only: `lint-staged` can print thirty, and the whole report is in the status
        // line and in the command drawer, which is where a reader goes when the first line is not
        // enough.
        if let failure {
            let firstLine = failure.split(separator: "\n").first.map(String.init) ?? failure
            commitBox.status.stringValue = "refused — \(firstLine)"
            commitBox.status.toolTip = failure
        } else {
            commitBox.status.toolTip = nil
        }
    }

    /// The amend switch **borrows the fields rather than blocking them**, which is what amending
    /// is: the last commit's message becomes editable, because changing it is half the point of
    /// the operation. Blocked fields would leave `--amend` able to change only the *content*, and
    /// the reader with no way to fix the typo they turned the switch on for.
    ///
    /// What the reader had already typed is kept and put back when the switch goes off.
    @objc func amendToggled() {
        guard let repository = state.selectedRepository, let commitBox else { return }
        if commitBox.amend.state == .on {
            commitBox.draftSummary = commitBox.summaryText
            commitBox.draftBody = commitBox.descriptionText
            let message = gitState.commitMessage(of: "HEAD", in: repository.url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                statusLabel.stringValue = "there is no commit to amend yet"
                commitBox.amend.state = .off
                return
            }
            // Subject, blank line, body — the shape `composeMessage` writes, read back the same way.
            let parts = message.components(separatedBy: "\n\n")
            commitBox.summary.stringValue = parts[0].replacingOccurrences(of: "\n", with: " ")
            commitBox.body.string = parts.dropFirst().joined(separator: "\n\n")
            statusLabel.stringValue = "amending the last commit — edit its message, or leave it as it is"
        } else {
            commitBox.summary.stringValue = commitBox.draftSummary
            commitBox.body.string = commitBox.draftBody
        }
        commitBox.body.needsDisplay = true
    }

    @objc func focusCommitSummary() {
        guard let commitBox else { return }
        window.makeFirstResponder(commitBox.summary)
    }

    /// True while the commit box holds focus — which is what decides whether ⌘⏎ commits or opens
    /// the editor (DEC-092, GitHub Desktop's own rule).
    func commitBoxHasFocus() -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let view = responder as? NSView, view.isDescendant(of: commitBox) { return true }
        // A field being edited answers with its *field editor*, whose delegate is the field.
        if let editor = responder as? NSText, let delegate = editor.delegate as? NSView {
            return delegate.isDescendant(of: commitBox)
        }
        return false
    }

    @objc func undoLastCommit() {
        guard let repository = state.selectedRepository else { return }
        guard confirm("Undo the last commit?",
                      detail: "The commit is removed and everything it contained stays staged. Nothing is lost.",
                      verb: "Undo") else { return }
        perform("undo commit") { try self.actions.undoLastCommit(in: repository.url) }
    }

    // ---- branches, stashes, tags, worktrees ------------------------------------------------------

    @objc func showBranchMenu(_ sender: NSView?) {
        guard let repository = state.selectedRepository else { return }
        let menu = NSMenu(title: "Branches")
        for branch in state.branches {
            let item = menu.addItem(withTitle: branch.name, action: #selector(checkoutBranch(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = branch.name
            item.state = branch.isCurrent ? .on : .off
            if branch.hasUpstream, branch.ahead + branch.behind > 0 {
                item.toolTip = "\(branch.ahead) ahead, \(branch.behind) behind \(branch.upstream ?? "")"
            }
        }
        menu.addItem(.separator())
        for (title, selector) in [("New Branch…", #selector(newBranch)),
                                  ("Rename Branch…", #selector(renameBranch)),
                                  ("Delete Branch…", #selector(deleteBranch)),
                                  ("Merge a Branch into This One…", #selector(mergeBranch))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
        }
        present(menu, from: sender ?? branchButton, repository: repository)
    }

    @objc func checkoutBranch(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let name = sender.representedObject as? String,
              name != state.branches.first(where: { $0.isCurrent })?.name else { return }
        perform("checkout") { try self.actions.checkout(branch: name, in: repository.url) }
    }

    @objc func newBranch() {
        guard let repository = state.selectedRepository,
              let name = ask("Name the new branch", detail: "It starts at the current commit.",
                             placeholder: "feature/…") else { return }
        perform("branch") {
            try self.actions.createBranch(name, at: nil, checkout: true, in: repository.url)
        }
    }

    @objc func renameBranch() {
        guard let repository = state.selectedRepository,
              let current = state.branches.first(where: { $0.isCurrent }),
              let name = ask("Rename “\(current.name)”", detail: "", placeholder: current.name) else { return }
        perform("rename") {
            try self.actions.renameBranch(from: current.name, to: name, in: repository.url)
        }
    }

    @objc func deleteBranch() {
        guard let repository = state.selectedRepository else { return }
        let others = state.branches.filter { !$0.isCurrent }
        guard !others.isEmpty else {
            statusLabel.stringValue = "there is no other branch to delete"
            return
        }
        let menu = NSMenu(title: "Delete")
        for branch in others {
            let item = menu.addItem(withTitle: branch.name, action: #selector(deleteBranchNamed(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = branch.name
        }
        present(menu, from: branchButton, repository: repository)
    }

    @objc func deleteBranchNamed(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let name = sender.representedObject as? String else { return }
        guard confirm("Delete the branch “\(name)”?",
                      detail: "If it holds commits that are on no other branch, they are only reachable through the reflog afterwards.",
                      verb: "Delete") else { return }
        perform("delete branch") {
            do { try self.actions.deleteBranch(name, force: false, in: repository.url) }
            catch {
                // git refuses an unmerged branch, and it is right to. The second question is a
                // different question, and it is asked rather than assumed.
                guard self.confirm("“\(name)” is not fully merged. Delete it anyway?",
                                   detail: "Its commits stay in the object database until git collects them, and the reflog is the only way back to them.",
                                   verb: "Delete anyway") else { return }
                try self.actions.deleteBranch(name, force: true, in: repository.url)
            }
        }
    }

    @objc func mergeBranch() {
        guard let repository = state.selectedRepository else { return }
        let menu = NSMenu(title: "Merge")
        for branch in state.branches where !branch.isCurrent {
            let item = menu.addItem(withTitle: branch.name, action: #selector(mergeBranchNamed(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = branch.name
        }
        present(menu, from: branchButton, repository: repository)
    }

    @objc func mergeBranchNamed(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let name = sender.representedObject as? String else { return }
        let outcome = actions.merge(name, squash: false, in: repository.url)
        // A conflict is an outcome, not a fault: the banner takes over from here.
        if case let .failure(failure) = outcome {
            statusLabel.stringValue = failure.description
        } else {
            statusLabel.stringValue = "merged \(name)"
        }
        afterWrite()
    }

    @objc func stashEverything() {
        guard let repository = state.selectedRepository else { return }
        perform("stash") {
            try self.actions.stashAll(message: nil, keepIndex: false, includeUntracked: true,
                                      in: repository.url)
        }
    }

    @objc func showStashMenu(_ sender: Any?) {
        guard let repository = state.selectedRepository else { return }
        let menu = NSMenu(title: "Stashes")
        if state.stashes.isEmpty {
            menu.addItem(withTitle: "No stashes", action: nil, keyEquivalent: "").isEnabled = false
        }
        for stash in state.stashes {
            let item = menu.addItem(withTitle: "\(stash.ref) — \(stash.subject)", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, verb) in [("Restore and keep the stash", "apply"), ("Restore", "pop"),
                                  ("Discard", "drop")] {
                let action = submenu.addItem(withTitle: title, action: #selector(stashAction(_:)),
                                             keyEquivalent: "")
                action.target = self
                action.representedObject = "\(verb)\u{1f}\(stash.ref)"
            }
            item.submenu = submenu
        }
        present(menu, from: branchButton, repository: repository)
    }

    @objc func stashAction(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository,
              let encoded = sender.representedObject as? String else { return }
        let parts = encoded.components(separatedBy: "\u{1f}")
        guard parts.count == 2 else { return }
        let verb: WriteActions.StashVerb = parts[0] == "pop" ? .pop : (parts[0] == "drop" ? .drop : .apply)
        if verb == .drop {
            guard confirm("Discard \(parts[1])?",
                          detail: "A dropped stash is not on any branch and is very hard to recover.",
                          verb: "Discard") else { return }
        }
        perform("stash \(parts[0])") { try self.actions.stash(parts[1], verb: verb, in: repository.url) }
    }

    @objc func showTagMenu(_ sender: Any?) {
        guard let repository = state.selectedRepository else { return }
        let menu = NSMenu(title: "Tags")
        let new = menu.addItem(withTitle: "New Tag at HEAD…", action: #selector(newTag), keyEquivalent: "")
        new.target = self
        let tags = gitState.tags(in: repository.url)
        if !tags.isEmpty { menu.addItem(.separator()) }
        for tag in tags {
            let item = menu.addItem(withTitle: tag, action: #selector(deleteTagNamed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag
            item.toolTip = "Delete this tag"
        }
        present(menu, from: branchButton, repository: repository)
    }

    @objc func newTag() {
        guard let repository = state.selectedRepository,
              let name = ask("Name the tag", detail: "It is created at the current commit.",
                             placeholder: "v1.0.0") else { return }
        perform("tag") { try self.actions.tag(name, message: nil, at: nil, in: repository.url) }
    }

    @objc func deleteTagNamed(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let name = sender.representedObject as? String else { return }
        guard confirm("Delete the tag “\(name)”?", detail: "It is removed here; a tag already pushed stays on the remote.",
                      verb: "Delete") else { return }
        perform("delete tag") { try self.actions.deleteTag(name, in: repository.url) }
    }

    @objc func showWorktreeMenu(_ sender: Any?) {
        guard let repository = state.selectedRepository else { return }
        let menu = NSMenu(title: "Worktrees")
        for worktree in gitState.worktrees(in: repository.url) {
            let title = "\(URL(fileURLWithPath: worktree.path).lastPathComponent)"
                + (worktree.branch.map { " — \($0)" } ?? "")
                + (worktree.isMain ? "  (main)" : "")
            let item = menu.addItem(withTitle: title, action: #selector(openWorktree(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = worktree.path
            item.state = worktree.isCurrent ? .on : .off
        }
        menu.addItem(.separator())
        let new = menu.addItem(withTitle: "New Worktree…", action: #selector(newWorktree), keyEquivalent: "")
        new.target = self
        present(menu, from: branchButton, repository: repository)
    }

    /// A worktree is a directory with a repository in it, and this application already knows how to
    /// show one of those: it is added as a source rather than being a second kind of thing.
    @objc func openWorktree(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let source = ConfiguredSource(kind: .repository,
                                      path: URL(fileURLWithPath: path).standardizedFileURL.path)
        // DEC-069's rule, the same as `add(kind:)` uses: the same directory rather than the same
        // string, so a worktree opened twice does not appear twice.
        if !state.configuration.sources.contains(where: {
            $0.kind == source.kind && PathIdentity.same($0.path, source.path)
        }) {
            state.configuration.sources.append(source)
            if let problem = configStore.save(state.configuration) { statusLabel.stringValue = problem }
        }
        rescan()
    }

    @objc func newWorktree() {
        guard let repository = state.selectedRepository,
              let name = ask("Name the worktree", detail: "It is created beside the repository, on a branch of the same name.",
                             placeholder: "feature") else { return }
        let path = repository.url.deletingLastPathComponent()
            .appendingPathComponent("\(repository.url.lastPathComponent)-\(name)").path
        perform("worktree") {
            try self.actions.addWorktree(path: path, branch: name, checkout: nil, in: repository.url)
        }
    }

    // ---- history -------------------------------------------------------------------------------

    /// The commit the History lens has selected, or `nil`. Version two's commit verbs act on it,
    /// which is why they are disabled rather than hidden when no commit is picked.
    func pickedCommit() -> String? { state.pickedCommits.last }

    @objc func revertPickedCommit() {
        guard let repository = state.selectedRepository, let sha = pickedCommit() else {
            statusLabel.stringValue = "pick a commit in History first"
            return
        }
        perform("revert") { try self.actions.revert(sha, in: repository.url) }
    }

    @objc func cherryPickCommit() {
        guard let repository = state.selectedRepository, let sha = pickedCommit() else {
            statusLabel.stringValue = "pick a commit in History first"
            return
        }
        perform("cherry-pick") { try self.actions.cherryPick([sha], in: repository.url) }
    }

    @objc func resetToPickedCommit() {
        guard let repository = state.selectedRepository, let sha = pickedCommit() else {
            statusLabel.stringValue = "pick a commit in History first"
            return
        }
        let menu = NSMenu(title: "Reset")
        for kind in WriteActions.ResetKind.allCases {
            let item = menu.addItem(withTitle: "Reset \(kind.rawValue) to \(String(sha.prefix(7)))",
                                    action: #selector(resetKind(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.toolTip = kind.consequence
        }
        present(menu, from: branchButton, repository: repository)
    }

    @objc func resetKind(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let sha = pickedCommit(),
              let raw = sender.representedObject as? String,
              let kind = WriteActions.ResetKind(rawValue: raw) else { return }
        guard confirm("Reset to \(String(sha.prefix(7)))?", detail: kind.consequence,
                      verb: "Reset \(kind.rawValue)") else { return }
        perform("reset") { try self.actions.reset(to: sha, kind: kind, in: repository.url) }
    }

    /// Rewriting the branch around the commit History has picked: lazygit's verbs and GitHub
    /// Desktop's two gestures, offered as words because a drag is not a keyboard route (DEC-016).
    @objc func rewriteHistory(_ sender: Any?) {
        guard let repository = state.selectedRepository, let sha = pickedCommit() else {
            statusLabel.stringValue = "pick a commit in History first"
            return
        }
        let menu = NSMenu(title: "Rewrite")
        for verb in WriteActions.RewriteVerb.allCases {
            let title: String
            switch verb {
            case .reword: title = "Reword…"
            case .squash: title = "Squash into the commit before it"
            case .fixup: title = "Fold into the commit before it, drop the message"
            case .drop: title = "Drop this commit"
            case .moveUp: title = "Move earlier"
            case .moveDown: title = "Move later"
            }
            let item = menu.addItem(withTitle: title, action: #selector(rewriteVerb(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = verb.rawValue
            item.toolTip = verb.consequence
        }
        menu.addItem(.separator())
        let amend = menu.addItem(withTitle: "Amend this commit with what is staged",
                                 action: #selector(amendOldCommit), keyEquivalent: "")
        amend.target = self
        present(menu, from: (sender as? NSView) ?? branchButton, repository: repository)
    }

    @objc func rewriteVerb(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let sha = pickedCommit(),
              let raw = sender.representedObject as? String,
              let verb = WriteActions.RewriteVerb(rawValue: raw) else { return }
        var message: String?
        if verb == .reword {
            let existing = gitState.commitMessage(of: sha, in: repository.url)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let typed = ask("Reword \(String(sha.prefix(7)))",
                                  detail: "The commit keeps its changes. Its current message is “\(existing.prefix(60))”.",
                                  placeholder: existing) else { return }
            message = typed
        }
        // Every verb here rewrites commits that already exist, so every one of them is class C —
        // and the sheet says which of the six is about to happen rather than *are you sure*.
        guard confirm("\(sender.title.replacingOccurrences(of: "…", with: "")) — \(String(sha.prefix(7)))?",
                      detail: verb.consequence
                          + " Every commit after it gets a new identity, and a branch already pushed will need a force push.",
                      verb: "Rewrite") else { return }
        perform("rewrite") {
            _ = try self.actions.rewrite(sha, as: verb, newMessage: message, in: repository.url)
        }
    }

    @objc func amendOldCommit() {
        guard let repository = state.selectedRepository, let sha = pickedCommit() else { return }
        guard confirm("Amend \(String(sha.prefix(7))) with what is staged?",
                      detail: "The staged changes are folded into that commit. Every commit after it gets a new identity.",
                      verb: "Amend") else { return }
        perform("amend old commit") { _ = try self.actions.amendOldCommit(sha, in: repository.url) }
    }

    // ---- the banner's verbs ----------------------------------------------------------------------

    @objc func bannerVerb(_ sender: NSButton) {
        guard let repository = state.selectedRepository else { return }
        let verb = sender.title
        if case .bisecting = state.operation {
            let map = ["Good": "good", "Bad": "bad", "Skip": "skip", "Reset": "reset"]
            guard let subcommand = map[verb] else { return }
            let outcome = actions.bisect(subcommand, in: repository.url)
            report(outcome)
            afterWrite()
            return
        }
        let outcome = actions.continueOperation(state.operation, verb: verb, in: repository.url)
        report(outcome)
        afterWrite()
    }

    @objc func startBisect() {
        guard let repository = state.selectedRepository else { return }
        if case .bisecting = state.operation {
            report(actions.bisect("reset", in: repository.url))
        } else {
            report(actions.bisect("start", in: repository.url))
            report(actions.bisect("bad", in: repository.url))
            statusLabel.stringValue = "bisect started — mark a good commit to narrow it down"
        }
        afterWrite()
    }

    // ---- the remote ------------------------------------------------------------------------------

    @objc func fetchRemote() {
        guard let repository = state.selectedRepository, let remote = firstRemote(of: repository) else { return }
        statusLabel.stringValue = "fetching \(remote)…"
        let outcome = actions.fetch(remote: remote, in: repository.url)
        report(outcome, success: "fetched \(remote)")
        afterWrite()
    }

    @objc func pullRemote() {
        guard let repository = state.selectedRepository, let remote = firstRemote(of: repository),
              let branch = state.branches.first(where: { $0.isCurrent })?.name else { return }
        let outcome = actions.pull(remote: remote, branch: branch, rebase: false, in: repository.url)
        report(outcome, success: "pulled \(remote)/\(branch)")
        afterWrite()
    }

    @objc func pushRemote() {
        guard let repository = state.selectedRepository, let remote = firstRemote(of: repository),
              let current = state.branches.first(where: { $0.isCurrent }) else { return }
        let outcome = actions.push(remote: remote, branch: current.name,
                                   setUpstream: !current.hasUpstream, forceWithLease: false,
                                   in: repository.url)
        report(outcome, success: "pushed \(remote)/\(current.name)")
        afterWrite()
    }

    /// The only force this application can perform, behind the only confirmation that asks the
    /// reader to type something (DEC-092 §5).
    @objc func forcePush() {
        guard let repository = state.selectedRepository, let remote = firstRemote(of: repository),
              let current = state.branches.first(where: { $0.isCurrent }) else { return }
        guard let typed = ask("Force-push “\(current.name)”?",
                              detail: "This replaces the branch on \(remote) with the one here. The lease makes it refuse if somebody else has pushed since this window last looked — type the branch name to go ahead.",
                              placeholder: current.name),
              typed == current.name else {
            statusLabel.stringValue = "force push cancelled"
            return
        }
        let outcome = actions.push(remote: remote, branch: current.name, setUpstream: false,
                                   forceWithLease: true, in: repository.url)
        report(outcome, success: "force-pushed \(remote)/\(current.name)")
        afterWrite()
    }

    @objc func syncButtonPressed() {
        guard let syncButton else { return }
        switch syncButton.mode {
        case .fetch: fetchRemote()
        case .pull: pullRemote()
        case .push, .publish: pushRemote()
        }
    }

    func firstRemote(of repository: RepositorySnapshot) -> String? {
        guard let result = try? GitRunner().run(.remotes(), in: repository.url), result.succeeded,
              let first = result.trimmedOutput.split(separator: "\n").first else {
            statusLabel.stringValue = "this repository has no remote"
            return nil
        }
        return String(first)
    }

    // ---- conflicts -------------------------------------------------------------------------------

    /// The conflicted paths, with the two sides offered by name. DEC-092 hands the *resolving* to
    /// the editor, as GitHub Desktop does — what this offers is the three moves that do not need
    /// one: take our side, take theirs, or say it is resolved as it stands.
    @objc func resolveConflicts(_ sender: Any?) {
        guard let repository = state.selectedRepository else { return }
        let conflicts = gitState.conflicts(in: repository.url)
        guard !conflicts.isEmpty else {
            statusLabel.stringValue = "nothing is conflicted"
            return
        }
        let menu = NSMenu(title: "Conflicts")
        for conflict in conflicts {
            let item = menu.addItem(withTitle: conflict.path, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, side) in [("Take our side", "ours"), ("Take their side", "theirs"),
                                  ("Mark resolved as it stands", "asis")] {
                // A path added on both sides has no base and no *ours* to take in the sense the
                // word implies; the option is dropped rather than offered and then refused.
                if conflict.addedOnBothSides, side != "asis" { continue }
                let action = submenu.addItem(withTitle: title, action: #selector(resolveConflict(_:)),
                                             keyEquivalent: "")
                action.target = self
                action.representedObject = "\(side)\u{1f}\(conflict.path)"
            }
            let open = submenu.addItem(withTitle: "Open in the editor",
                                       action: #selector(openConflictInEditor(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = conflict.path
            item.submenu = submenu
        }
        present(menu, from: (sender as? NSView) ?? branchButton, repository: repository)
    }

    @objc func resolveConflict(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository,
              let encoded = sender.representedObject as? String else { return }
        let parts = encoded.components(separatedBy: "\u{1f}")
        guard parts.count == 2 else { return }
        let side: WriteActions.ConflictSide = parts[0] == "ours" ? .ours
            : (parts[0] == "theirs" ? .theirs : .asIs)
        if side != .asIs {
            guard confirm("Take the \(parts[0]) side of “\(parts[1])”?",
                          detail: "The other side's version of this file is discarded. The commits on both sides are untouched.",
                          verb: "Take \(parts[0])") else { return }
        }
        perform("resolve") { try self.actions.resolve(paths: [parts[1]], taking: side, in: repository.url) }
    }

    /// The same launcher DEC-082 built for ⌘⏎, pointed at the conflicted file: DEC-092 hands the
    /// resolving to the editor, so the interface has to open one.
    @objc func openConflictInEditor(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository,
              let path = sender.representedObject as? String else { return }
        let template = state.configuration.editorTemplate ?? EditorCommand.defaultTemplate
        guard let command = EditorCommand(template: template,
                                          file: repository.url.appendingPathComponent(path).path,
                                          line: 1) else {
            statusLabel.stringValue = "the editor command could not be built"
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        do { try process.run() } catch { statusLabel.stringValue = "the editor did not open: \(error)" }
    }

    // ---- the reflog, which is the net under every restore point ------------------------------------

    @objc func showReflog(_ sender: Any?) {
        guard let repository = state.selectedRepository else { return }
        let entries = gitState.reflog(in: repository.url, limit: 50)
        let menu = NSMenu(title: "Reflog")
        if entries.isEmpty {
            menu.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        for entry in entries.prefix(40) {
            let item = menu.addItem(withTitle: "\(entry.selector)  \(entry.action)",
                                    action: #selector(resetToReflogEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.sha
            item.toolTip = "\(entry.sha) · \(entry.date) — reset the branch here"
        }
        present(menu, from: (sender as? NSView) ?? branchButton, repository: repository)
    }

    @objc func resetToReflogEntry(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let sha = sender.representedObject as? String else { return }
        guard confirm("Move this branch back to \(sha)?",
                      detail: WriteActions.ResetKind.mixed.consequence
                          + " This is how a rewrite is undone when its restore point is gone.",
                      verb: "Reset") else { return }
        perform("reset") { try self.actions.reset(to: sha, kind: .mixed, in: repository.url) }
    }

    // ---- custom commands -------------------------------------------------------------------------

    /// lazygit's custom commands, run **in the terminal drawer** so nothing this application does
    /// to a repository happens where the reader cannot see it.
    @objc func showCustomCommands(_ sender: Any?) {
        guard let repository = state.selectedRepository else { return }
        let menu = NSMenu(title: "Commands")
        for command in state.configuration.customCommands {
            let item = menu.addItem(withTitle: command.name, action: #selector(runCustomCommand(_:)),
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = command.name
            item.toolTip = command.command
        }
        if !state.configuration.customCommands.isEmpty { menu.addItem(.separator()) }
        let new = menu.addItem(withTitle: "New Command…", action: #selector(newCustomCommand),
                               keyEquivalent: "")
        new.target = self
        if !state.configuration.customCommands.isEmpty {
            let forget = menu.addItem(withTitle: "Forget a Command…", action: #selector(forgetCustomCommand),
                                      keyEquivalent: "")
            forget.target = self
        }
        present(menu, from: (sender as? NSView) ?? branchButton, repository: repository)
    }

    @objc func newCustomCommand() {
        guard let name = ask("Name the command", detail: "It appears in this menu.",
                             placeholder: "Push and open the PR"),
              let body = ask("What should it run?",
                             detail: "It runs in the terminal drawer, in the selected repository. {repo}, {branch}, {file} and {sha} are filled in from what is selected.",
                             placeholder: "git push -u origin {branch}") else { return }
        state.configuration.customCommands.append(CustomCommand(name: name, command: body))
        if let problem = configStore.save(state.configuration) { statusLabel.stringValue = problem }
        else { statusLabel.stringValue = "saved “\(name)”" }
    }

    @objc func forgetCustomCommand() {
        guard let name = ask("Which command should be forgotten?", detail: "",
                             placeholder: state.configuration.customCommands.first?.name ?? "") else { return }
        state.configuration.customCommands.removeAll { $0.name == name }
        configStore.save(state.configuration)
        statusLabel.stringValue = "forgot “\(name)”"
    }

    @objc func runCustomCommand(_ sender: NSMenuItem) {
        guard let repository = state.selectedRepository, let name = sender.representedObject as? String,
              let command = state.configuration.customCommands.first(where: { $0.name == name }) else { return }
        let text = command.expanded(repository: repository.url.path,
                                    branch: state.branches.first { $0.isCurrent }?.name,
                                    file: selectedFilePath(), sha: pickedCommit())
        startTerminalIfNeeded()
        if !terminalVisible { setTerminalVisible(true, startingShell: true) }
        terminal.follow(directory: repository.url.path, force: true)
        // Typed into the drawer rather than executed: the reader sees the command, sees its output,
        // and can stop it. A custom command that ran invisibly would be the second execution path
        // this product has spent two milestones not having.
        terminal.type(text)
        statusLabel.stringValue = "typed “\(name)” into the terminal"
    }

    // ---- the record ------------------------------------------------------------------------------

    /// *It writes only what you asked for, and it shows you the command it ran* — the second half,
    /// made real. Every write, with its exact argv and its exit code.
    @objc func showCommandRecord() {
        let text = NSTextView()
        text.isEditable = false
        text.font = Theme.font(Theme.textSizeSmall)
        text.string = GitWriter.commandRecord.reversed().map { entry in
            let stamp = DateFormatter.localizedString(from: entry.date, dateStyle: .none, timeStyle: .medium)
            let outcome = entry.succeeded ? "ok" : "exit \(entry.exitCode)"
            return "\(stamp)  [\(outcome)]  \(entry.commandLine)"
                + (entry.standardError.isEmpty ? "" : "\n            \(entry.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }.joined(separator: "\n")
        if text.string.isEmpty { text.string = "This window has not changed anything yet." }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        let window = recordWindow ?? NSWindow(contentRect: scroll.frame,
                                              styleMask: [.titled, .closable, .resizable],
                                              backing: .buffered, defer: false)
        window.title = "What DiffScope Ran"
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        recordWindow = window
    }

    // ---- the plumbing every verb above goes through -----------------------------------------------

    /// Runs a write, says what happened, and re-reads. The `do`/`catch` is here rather than at
    /// thirty call sites so that a failure cannot be swallowed by a call site that forgot one.
    /// Runs a write, says what happened, and refreshes. Returns the failure text, or `nil` when the
    /// write succeeded, so a caller with a better place to show it than the status line can use one
    /// (DEC-113).
    @discardableResult
    func perform(_ label: String, _ body: @escaping () throws -> Void) -> String? {
        var failureText: String?
        do {
            try body()
            statusLabel.stringValue = "\(label) — done"
        } catch let failure as GitWriteFailure {
            failureText = failure.description
            statusLabel.stringValue = "\(label) — \(failure.description)"
        } catch {
            failureText = "\(error)"
            statusLabel.stringValue = "\(label) — \(error)"
        }
        afterWrite()
        return failureText
    }

    func report(_ outcome: Result<GitInvocationResult, GitWriteFailure>, success: String? = nil) {
        switch outcome {
        case .success:
            if let success { statusLabel.stringValue = success }
        case let .failure(failure):
            statusLabel.stringValue = failure.description
        }
    }

    /// After every write: the file list, the repository sweep, the state, and the file on screen.
    /// DEC-092 §5 point 6 — refresh currently assumes changes come from outside, and after a write
    /// they also come from inside.
    func afterWrite() {
        reloadFiles()
        refreshGitState()
        // **The repository that was written to, not all of them.** `rescan()` re-discovers every
        // configured source and sweeps every repository it finds; a staged line changes the counts
        // of exactly one.
        refreshOpenRepositoryRow()
    }

    // ---- asking --------------------------------------------------------------------------------

    /// The confirmation sheet. One question, one consequence, one verb on the button — never
    /// *OK*, because a button that says OK is one a reader presses without reading the sheet.
    func confirm(_ question: String, detail: String, verb: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func ask(_ question: String, detail: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func present(_ menu: NSMenu, from view: NSView, repository: RepositorySnapshot) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + Theme.space2), in: view)
    }

    func selectedFilePath() -> String? {
        guard fileTable.selectedRow >= 0, state.fileRows.indices.contains(fileTable.selectedRow) else { return nil }
        return state.fileRows[fileTable.selectedRow].file?.path
    }
}
