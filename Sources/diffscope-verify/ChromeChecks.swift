import DiffScopeGit
import DiffScopeShell
import Foundation

/// What the window says about itself (DEC-071 onward).
///
/// Two thirds of the interface is AppKit, and until `ChromeLabels` existed every string in it was
/// composed inside an `NSTextField` where only a picture could see it. These checks link the same
/// file the window draws from, so a caption is a claim the suite can ask about.
func runChromeChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    print("\n=== the two lists say what they are, and how many (DEC-071) ===")
    do {
        let repositories = ChromeLabels.repositoriesHeader(count: 3, collapsed: false)
        report("the repositories header names its pane", repositories.caption == "REPOSITORIES",
               repositories.caption)

        let files = ChromeLabels.changedFilesHeader(count: 12, collapsed: false)
        report("the changed-files header names its pane", files.caption == "CHANGED FILES",
               files.caption)
        // The count is the point of this header: the status line's own sentence is at the far edge
        // of the window from the list it counts, which is the defect DEC-058 paid for three times.
        report("and carries the number of files beside it", files.count == "12", files.count)

        // Collapsed (DEC-060) the word cannot fit, so the rule is *the word goes and the count
        // stays*. A header that dropped the count instead would leave the reader a pane with no
        // statement of size at all.
        let railHeader = ChromeLabels.repositoriesHeader(count: 3, collapsed: true)
        report("collapsed, the repositories header keeps its count and drops the word",
               railHeader.caption == "3", "\(railHeader)")
        let spineHeader = ChromeLabels.changedFilesHeader(count: 63, collapsed: true)
        report("collapsed, the changed-files header keeps its count and drops the word",
               spineHeader.caption.isEmpty && spineHeader.count == "63", "\(spineHeader)")

        // Every count a real working tree can produce, against the width the rail and the spine
        // actually have. A number the label clips is a number that lies about its magnitude.
        var overflowing: [Int] = []
        for count in [0, 1, 9, 10, 63, 99, 100, 999, 1000, 1001, 5000, 10000] {
            if !ChromeLabels.fitsCollapsedPane(
                ChromeLabels.repositoriesHeader(count: count, collapsed: true)) {
                overflowing.append(count)
            }
            if !ChromeLabels.fitsCollapsedPane(
                ChromeLabels.changedFilesHeader(count: count, collapsed: true)) {
                overflowing.append(count)
            }
        }
        report("every collapsed header fits the pane it is drawn in", overflowing.isEmpty,
               overflowing.map(String.init).joined(separator: ", "))
        report("and a count past the fourth digit says so rather than being clipped",
               ChromeLabels.compactCount(999) == "999"
                   && ChromeLabels.compactCount(1000) == "999+"
                   && ChromeLabels.compactCount(48291) == "999+",
               ChromeLabels.compactCount(48291))

        // The controls. Without these the assertions above are four `==` against a file that could
        // be returning anything at all.
        report("negative control: a header that kept its word when collapsed is caught",
               !ChromeLabels.fitsCollapsedPane(
                   ChromeLabels.PaneHeaderText(caption: "REPOSITORIES", count: "")))
        report("negative control: an uncompacted five-digit count is caught",
               !ChromeLabels.fitsCollapsedPane(
                   ChromeLabels.PaneHeaderText(caption: "", count: "48291")))
    }

    print("\n=== every pill prints its key, and an empty scope says so (DEC-073) ===")
    do {
        // The map was visible only in the menu bar. A reader looking at the control had no way to
        // learn its key without opening a menu — DEC-016 is about being able to *use* the keyboard,
        // and this is about being able to find out that you can.
        let scopeHints = ChromeLabels.pillHints(bindingIDs: ["scope.allLocal", "scope.unstaged",
                                                            "scope.staged", "scope.base"])
        report("the scope pills print the keys the map binds",
               scopeHints == ["⇧⌘1", "⇧⌘2", "⇧⌘3", "⇧⌘4"], scopeHints.joined(separator: " "))
        let modeHints = ChromeLabels.pillHints(bindingIDs: ["mode.structural", "mode.expanded",
                                                           "mode.raw"])
        report("and so do the mode pills, in the order DEC-065 numbers them",
               modeHints == ["⌘1", "⌘2", "⌘3"], modeHints.joined(separator: " "))
        let lensHints = ChromeLabels.pillHints(bindingIDs: ["lens.diff", "lens.blame", "lens.history"])
        report("and the lens pills", lensHints == ["⌃⌘D", "⌃⌘B", "⌃⌘H"],
               lensHints.joined(separator: " "))

        // Every hint drawn is a keystroke the map composes, checked as a set rather than one by one:
        // a pill printing a key nothing binds teaches a reader a keystroke that does nothing.
        let shortcuts = Set(KeyboardMap.bindings.map(\.shortcut))
        report("no pill prints a key the map does not have",
               (scopeHints + modeHints + lensHints).allSatisfy { shortcuts.contains($0) })
        // The control. A binding that does not exist has to produce **nothing** rather than a
        // plausible-looking string.
        report("negative control: a hint for a binding the map does not have is empty",
               ChromeLabels.pillHint(bindingID: "scope.invented").isEmpty)

        // The four scopes, and the third state the window could not draw: available and empty.
        report("an empty scope says which one it is and what is empty about it",
               ChromeLabels.scopeState(shortTitle: ComparisonScope.stagedVsHead.shortTitle,
                                       emptyDescription: ComparisonScope.stagedVsHead.emptyDescription)
                   == "Staged — nothing staged")
        report("and each scope words it for itself rather than sharing one sentence",
               Set(ComparisonScope.allCases.map(\.emptyDescription)).count
                   == ComparisonScope.allCases.count,
               ComparisonScope.allCases.map(\.emptyDescription).joined(separator: " | "))
        // The pills' four words are the scopes' own, so the control and the sentence cannot come to
        // call the same scope two things.
        report("the pill's word and the empty sentence's word are the same word",
               ComparisonScope.allCases.map(\.shortTitle)
                   == ["All local", "Unstaged", "Staged", "vs base"],
               ComparisonScope.allCases.map(\.shortTitle).joined(separator: " "))
        report("negative control: the empty state is not the unavailable state's sentence",
               ChromeLabels.scopeState(shortTitle: "Staged", emptyDescription: "nothing staged")
                   != "Staged — no upstream to compare against")
    }

    print("\n=== the base is a block that says it can be changed (DEC-072) ===")
    do {
        let now = ISO8601DateFormatter().date(from: "2026-08-12T12:00:00Z")!
        func ago(_ days: Int) -> String {
            ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double(days) * 86400))
        }
        // One composition, two presentations. The block draws the caption itself, so the sentence
        // and the block must be the same string with a word in front of it — otherwise the row and
        // the status line drift, which is what happened to the tester packet's keyboard map.
        let detail = baseDetail(ref: "origin/master", chosenByUser: false,
                                committerDate: ago(63), now: now)
        report("the block's detail is the status line's sentence without its first word",
               detail == "origin/master · newest commit 9 weeks old"
                   && baseSummary(ref: "origin/master", chosenByUser: false,
                                  committerDate: ago(63), now: now) == "base " + detail,
               detail)
        report("a ref the reader chose still says so in the block",
               baseDetail(ref: "release", chosenByUser: true, committerDate: ago(1), now: now)
                   == "release (yours) · newest commit 1 day old")
        report("and an undetermined base is named rather than left blank",
               baseDetail(ref: nil, chosenByUser: false, committerDate: nil, now: now)
                   == "not determined")

        let comparing = ChromeLabels.baseBlock(detail: detail, comparingAgainstBase: true)
        let idle = ChromeLabels.baseBlock(detail: detail, comparingAgainstBase: false)
        report("the block names itself", comparing.caption == "Base", comparing.caption)
        // The substance of DEC-072: `newest commit 9 weeks old` beside `HEAD ↔ working tree` reads
        // as a statement about what is on screen. The dashed rim says it is not — in the same shape
        // the window already uses for an unavailable scope and an unknown count, so it survives a
        // greyscale screenshot (DEC-035).
        report("it is solid while the base is what is being compared", !comparing.dashed)
        report("and dashed while it is not", idle.dashed)

        // The keystroke on it is the map's, not a string typed beside it (DEC-071).
        let shortcuts = Set(KeyboardMap.bindings.map(\.shortcut))
        report("the keystroke drawn on the block is one the map composes",
               shortcuts.contains(comparing.shortcut)
                   && comparing.shortcut == KeyboardMap.binding(id: "sources.baseBranch")?.shortcut,
               comparing.shortcut)
        report("negative control: a keystroke the map does not have is not among them",
               !shortcuts.contains("⌘J"))
    }

    print("\n=== the status line says what the watcher is doing, and prints the map's keys (DEC-075) ===")
    do {
        report("watching says so, with how old the window is",
               ChromeLabels.watcherStatus(.watching, refreshedSecondsAgo: 4)
                   == "● Watching · refreshed 4s ago",
               ChromeLabels.watcherStatus(.watching, refreshedSecondsAgo: 4))
        // A window that has never refreshed does not say it refreshed zero seconds ago: the age is
        // absent, because the clause exists to make the counts honest and `0s` would do the opposite.
        report("and a window that has never refreshed omits the age rather than saying zero",
               ChromeLabels.watcherStatus(.watching, refreshedSecondsAgo: nil) == "● Watching")
        // Shape, not colour (DEC-035): a filled dot against a hollow one survives greyscale.
        report("not watching is a different shape, not a different shade",
               ChromeLabels.watcherStatus(.unavailable("no FSEvents stream"),
                                          refreshedSecondsAgo: nil).hasPrefix("○")
                   && ChromeLabels.watcherStatus(.watching, refreshedSecondsAgo: nil).hasPrefix("●"))
        report("and it carries the reason, which is the half a reader can act on",
               ChromeLabels.watcherStatus(.stopped("kbtree was moved or renamed"),
                                          refreshedSecondsAgo: 30)
                   == "○ Watching stopped — kbtree was moved or renamed · refreshed 30s ago")

        report("the age reads in the units of a window being watched",
               ChromeLabels.refreshedAgo(seconds: 0) == "just now"
                   && ChromeLabels.refreshedAgo(seconds: 4) == "4s ago"
                   && ChromeLabels.refreshedAgo(seconds: 90) == "1m ago"
                   && ChromeLabels.refreshedAgo(seconds: 7200) == "2h ago",
               ChromeLabels.refreshedAgo(seconds: 90))
        // A clock that goes backwards — a sweep stamped in the future by a skewed clock — must not
        // print a negative age, for the same reason `stalenessDescription` says *dated in the future*.
        report("negative control: a negative age is not printed as one",
               ChromeLabels.refreshedAgo(seconds: -5) == "just now")

        // **The legend disagrees with the design, on purpose.** The design writes `⌥↑↓ change`;
        // DEC-065 gives ⌥↑↓ to files and ⌘↑↓ to changes, and a legend printed from a picture rather
        // than from the map is the tester packet's defect on a surface every reader sees.
        let legend = ChromeLabels.keyLegend()
        report("the legend prints the keys the map actually binds",
               legend == "⌘↑↓ change · ⌥↑↓ file · ⌘⏎ open in editor", legend)
        report("and not the key the design drew for changes", !legend.contains("⌥↑↓ change"), legend)

        // Every modifier run in it is a shortcut the map composes — the same rule, and the same
        // check, as the tester packet's.
        let shortcuts = Set(KeyboardMap.bindings.map(\.shortcut))
        let pattern = try! NSRegularExpression(pattern: "[⌃⌥⇧⌘]+[^ ]")
        var unknown: [String] = []
        for match in pattern.matches(in: legend,
                                     range: NSRange(legend.startIndex..., in: legend)) {
            guard let found = Range(match.range, in: legend) else { continue }
            let token = String(legend[found])
            // `⌘↑↓` is one run standing for two bindings, so both are asked for.
            let candidates = token.hasSuffix("↑") || token.hasSuffix("↓")
                ? [String(token.dropLast()) + "↑", String(token.dropLast()) + "↓"]
                : [token]
            if !candidates.allSatisfy({ shortcuts.contains($0) }) { unknown.append(token) }
        }
        report("every keystroke the legend prints is one the map composes", unknown.isEmpty,
               unknown.joined(separator: " "))
        report("negative control: a keystroke nothing binds would be caught",
               !shortcuts.contains("⌥⌘↑"))

        report("the layout is offered as words, not as glyphs nobody can name",
               ChromeLabels.layoutTitles == ["Unified", "Side by side"],
               ChromeLabels.layoutTitles.joined(separator: " | "))
    }

    print("\n=== a group header is short, and no two are the same (DEC-074) ===")
    do {
        let workspace = groupHeaderTitles(["packages/web", "packages/api"])
        report("a declared package reads as the design writes it",
               workspace["packages/web"] == "PACKAGES/WEB" && workspace["packages/api"] == "PACKAGES/API",
               workspace.values.sorted().joined(separator: ", "))

        // The fixture tree, which is where the old headers failed: nine groups whose last two
        // components are identical, in a pane that truncates from the head.
        let deep = (0...8).map { "packages/app-\($0)/src/components/nested" }
        let titles = groupHeaderTitles(deep)
        report("nine groups that differ only in their second component stay short and separate",
               Set(titles.values).count == 9 && titles[deep[0]] == "PACKAGES/APP-0…",
               titles.values.sorted().joined(separator: " "))

        // A collision at depth 2 has to lengthen rather than draw the same header twice.
        let siblings = groupHeaderTitles(["src/components/Button", "src/components/Card"])
        report("a collision lengthens the header instead of repeating it",
               Set(siblings.values).count == 2
                   && siblings["src/components/Button"] == "SRC/COMPONENTS/BUTTON",
               siblings.values.sorted().joined(separator: ", "))

        // Upper-casing cannot separate these at any depth, so the list keeps its paths.
        let cased = groupHeaderTitles(["a/Web", "a/web"])
        report("two groups differing only in case keep their paths rather than colliding",
               cased["a/Web"] == "a/Web" && cased["a/web"] == "a/web",
               cased.values.sorted().joined(separator: ", "))

        report("the repository-root sentinel is left alone",
               groupHeaderTitles([repositoryRootGroup, "src/app"])[repositoryRootGroup]
                   == repositoryRootGroup)

        // The property the whole rule rests on, over generated keys rather than over the four
        // examples above: **two groups may never share a header.** A shortening that collides is a
        // list that lies about where its files are.
        var rng = Rng(state: 0xC0FFEE)
        var collisions = 0
        var checked = 0
        for _ in 0..<200 {
            let words = ["packages", "src", "app", "web", "api", "components", "nested", "lib", "ui"]
            var keys = Set<String>()
            for _ in 0..<(2 + rng.next(6)) {
                let depth = 1 + rng.next(5)
                keys.insert((0..<depth).map { _ in words[rng.next(words.count)] }
                    .joined(separator: "/"))
            }
            let generated = groupHeaderTitles(Array(keys))
            checked += keys.count
            if Set(generated.values).count != keys.count { collisions += 1 }
        }
        report("no two groups ever share a header, over 200 generated lists", collisions == 0,
               "\(collisions) colliding lists of \(checked) keys")

        // The control: the rule this replaced. The last two components were the obvious shortening
        // and they collapse the fixture tree's nine groups into one header.
        let naive = Set(deep.map { key -> String in
            let parts = key.split(separator: "/")
            return parts.suffix(2).joined(separator: "/").uppercased()
        })
        report("negative control: shortening from the tail would have drawn one header nine times",
               naive.count == 1, naive.joined(separator: ", "))
    }

    print("\n=== every ink the chrome draws clears 4.5:1 on the surface it is drawn on ===")
    do {
        // `27-…` §3 records the adopted design's tertiary text failing contrast at 2.7:1 and being
        // **fixed by measurement rather than by eye**. Nothing then held that fixed: the corrected
        // pair was measured against the paper, and the chrome band, the control trough and the
        // selected row are three other surfaces the same ink is drawn on. Measured in step 62, the
        // faint step is 4.47:1 on the chrome, 4.32:1 on the trough, 4.12:1 on a selected row and
        // 3.47:1 on the thumb in dark — every one of them under the threshold the design was held to.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let tokens = (try? String(contentsOf: root.appendingPathComponent("Renderer/src/tokens.css"),
                                  encoding: .utf8)) ?? ""
        let halves = tokens.components(separatedBy: "@media (prefers-color-scheme: dark)")
        report("the token file has both appearances in it", halves.count == 2,
               "\(halves.count) parts")

        func value(_ name: String, dark: Bool) -> String? {
            let source = dark ? (halves.last ?? "") : (halves.first ?? "")
            guard let range = source.range(of: "\(name):\\s*#[0-9a-fA-F]{6}",
                                           options: .regularExpression) else {
                return dark ? value(name, dark: false) : nil
            }
            return String(source[range].suffix(7))
        }
        func luminance(_ hex: String) -> Double {
            let digits = Array(hex.dropFirst())
            let channels = stride(from: 0, to: 6, by: 2).map { index -> Double in
                let byte = Double(UInt8(String(digits[index...index + 1]), radix: 16) ?? 0) / 255
                return byte <= 0.03928 ? byte / 12.92 : pow((byte + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        }
        func ratio(_ ink: String, _ surface: String) -> Double {
            let a = luminance(ink), b = luminance(surface)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }

        // **Hand-maintained, and each entry names where it is drawn.** A cross product would be a
        // check about a palette; this is a check about the window. The list grows when a label does
        // — the same discipline as the shipped-module list in the privacy check.
        let pairs: [(ink: String, surface: String, where_: String)] = [
            ("--ds-text", "--ds-chrome", "the application name and the repository in the title bar"),
            ("--ds-dim", "--ds-chrome", "the comparison text and the base block's ref"),
            ("--ds-faint", "--ds-chrome", "the SCOPE caption, the key legend, the repository's path"),
            ("--ds-text", "--ds-panel-repos", "a repository's name"),
            ("--ds-dim", "--ds-panel-repos", "its head state"),
            ("--ds-faint", "--ds-panel-repos", "the REPOSITORIES caption and the path under it"),
            ("--ds-text", "--ds-panel-files", "a file's name and its kind glyph"),
            ("--ds-dim", "--ds-panel-files", "its counts and the group headers"),
            ("--ds-faint", "--ds-panel-files", "the CHANGED FILES caption"),
            ("--ds-text", "--ds-row-selected", "the selected row's name"),
            ("--ds-dim", "--ds-row-selected", "the selected row's counts"),
            ("--ds-faint", "--ds-row-selected", "the selected repository's path"),
            ("--ds-text", "--ds-control-thumb", "the chosen pill"),
            ("--ds-faint", "--ds-control-thumb", "its key hint — the raised surface, and the binding one in dark"),
            ("--ds-dim", "--ds-control-trough", "the pills not chosen"),
            ("--ds-faint", "--ds-control-trough", "their key hints, and an unavailable scope"),
            ("--ds-text", "--ds-empty-bg", "the first screen a stranger meets"),
            ("--ds-dim", "--ds-empty-bg", "its explanation"),
            // The same ink is drawn in the diff pane, which is a different file's business but the
            // same token: a threshold that held only for the chrome would be half a rule.
            ("--ds-faint", "--ds-bg", "the pane behind the code"),
            ("--ds-faint", "--ds-code", "the gutters beside it"),
            ("--ds-faint", "--ds-fold", "a folded range's own row"),
        ]
        var failing: [String] = []
        for pair in pairs {
            for dark in [false, true] {
                guard let ink = value(pair.ink, dark: dark),
                      let surface = value(pair.surface, dark: dark) else {
                    failing.append("\(pair.ink)/\(pair.surface): undeclared"); continue
                }
                let measured = ratio(ink, surface)
                if measured < 4.5 {
                    failing.append(String(format: "%@ on %@ %@ %.2f:1 (%@)", pair.ink, pair.surface,
                                          dark ? "dark" : "light", measured, pair.where_))
                }
            }
        }
        report("every ink/surface pair the chrome draws clears 4.5:1 in both appearances",
               failing.isEmpty, failing.joined(separator: " | "))

        // Three controls, and the second is the one that matters: **the value this check was
        // written against, as a literal.** Reading it from the token file would have made the check
        // pass the moment DEC-076 changed the file — a control that the fix satisfies is not a
        // control. `#6b6b74` is what `--ds-faint` was in light, and it is 4.47:1 on the chrome band.
        report("negative control: the design's first tertiary colour is caught",
               ratio("#8a8a94", "#f2f2f5") < 4.5,
               String(format: "%.2f:1", ratio("#8a8a94", "#f2f2f5")))
        report("negative control: and so is the value this check was written against",
               ratio("#6b6b74", "#ececed") < 4.5,
               String(format: "%.2f:1 on the chrome band", ratio("#6b6b74", "#ececed")))
        report("and its dark counterpart on the raised thumb",
               ratio("#86868f", "#33333a") < 4.5,
               String(format: "%.2f:1", ratio("#86868f", "#33333a")))

        // DEC-076's own trade-off, asserted rather than remembered: three inks that read as two are
        // worse than a step that clears the threshold by a tenth, so the third ink has to stay
        // visibly apart from the second in both appearances.
        for dark in [false, true] {
            guard let dim = value("--ds-dim", dark: dark), let faint = value("--ds-faint", dark: dark)
            else { continue }
            report("the third ink is still a step away from the second (\(dark ? "dark" : "light"))",
                   ratio(dim, faint) >= 1.10,
                   String(format: "%.2f:1 between %@ and %@", ratio(dim, faint),
                          dim as NSString, faint as NSString))
        }
    }

    print("\n=== the contract describes the chrome it cannot see ===")
    do {
        // The class table in `24-…` §3 lists what the *renderer* emits, and the chrome emits nothing:
        // it draws views. So the same rule is applied to the views — seventh instance in this
        // project of a written promise with nothing running against it, and the one the contract
        // itself was caught by in M8-P.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let contract = (try? String(contentsOf: root.appendingPathComponent("docs/24-design-contract.md"),
                                    encoding: .utf8)) ?? ""
        var drawn: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("Sources/diffscope-app").path)) ?? []
        where name.hasSuffix(".swift") {
            let source = (try? String(
                contentsOf: root.appendingPathComponent("Sources/diffscope-app/\(name)"),
                encoding: .utf8)) ?? ""
            let regex = try! NSRegularExpression(
                pattern: "final class ([A-Za-z]+): (NSView|NSTableRowView|NSObject, WKNavigationDelegate)")
            let text = source as NSString
            for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                drawn.append(text.substring(with: match.range(at: 1)))
            }
        }
        report("the chrome's own views were found", drawn.count >= 5,
               drawn.sorted().joined(separator: ", "))
        let undocumented = drawn.filter { !contract.contains("`\($0)`") }.sorted()
        report("every view the chrome draws is described in the contract", undocumented.isEmpty,
               undocumented.joined(separator: ", "))
        report("negative control: a view the chrome does not draw is not in the contract",
               !contract.contains("`InventedForThisCheck`"))
    }

    print("\n=== a pointer route only opens a binding the map already has (DEC-071) ===")
    do {
        // The `+` button, and the rule it is the first instance of. DEC-016 calls a function
        // reachable only by pointer a defect; the mirror of that is a pointer control that reaches
        // something the keyboard map does not have, which is the same defect with the surfaces
        // swapped.
        let adding = KeyboardMap.bindings(in: .sources).filter { $0.id.hasPrefix("sources.add") }
        report("the map has the source-adding bindings the button offers", adding.count == 2,
               adding.map(\.id).joined(separator: ", "))
        report("and each of them prints a shortcut the map composes",
               adding.allSatisfy { !$0.key.isEmpty && $0.shortcut.count > 1 },
               adding.map(\.shortcut).joined(separator: " "))

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let shell = (try? String(
            contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
            encoding: .utf8)) ?? ""

        /// The body of one method, so the assertion is about the menu the button pops up rather
        /// than about a four-thousand-line file that contains almost anything.
        func body(of method: String, in source: String) -> String {
            guard let start = source.range(of: "func \(method)") else { return "" }
            let rest = source[start.upperBound...]
            guard let end = rest.range(of: "\n    }") else { return String(rest) }
            return String(rest[..<end.lowerBound])
        }

        let menu = body(of: "sourceMenu", in: shell)
        report("the builder both buttons use is found in the shell", !menu.isEmpty,
               "\(menu.count) bytes")
        report("it is composed from the keyboard map",
               menu.contains("KeyboardMap.bindings(in: .sources)"))
        report("and it names no title of its own",
               !menu.contains("NSMenuItem(title: \""), menu)
        // The second instance of the rule: `Sources ⌄` in the title bar opens the **whole** Sources
        // menu, and the `+` on the repositories header opens the half of it that adds. One builder,
        // so neither can grow an item the menu bar does not have.
        report("both pointer routes go through that one builder",
               body(of: "showSourcesMenu", in: shell).contains("sourceMenu(additionsOnly: false)")
                   && body(of: "showAddSourceMenu", in: shell)
                       .contains("sourceMenu(additionsOnly: true)"))
        report("and the whole Sources menu is four bindings, not two",
               KeyboardMap.bindings(in: .sources).count == 4,
               KeyboardMap.bindings(in: .sources).map(\.id).joined(separator: ", "))

        // The control. `contains` over a method body will agree with a correct one and with an
        // empty one alike, so a hand-written item has to be caught.
        let hostile = """
            func showAddSourceMenu(_ sender: NSButton) {
                let menu = NSMenu()
                menu.addItem(NSMenuItem(title: "Add Root Folder…", action: nil, keyEquivalent: "o"))
            }
            """
        let hostileBody = body(of: "showAddSourceMenu", in: hostile)
        report("negative control: a menu item titled by hand is caught",
               hostileBody.contains("NSMenuItem(title: \"")
                   && !hostileBody.contains("KeyboardMap.bindings(in: .sources)"))
    }
}
