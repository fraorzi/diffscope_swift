import DiffScopeShell
import Foundation

/// G2 of `23-release-gates.md`: a design can be pasted in without touching behaviour, and **cannot
/// hide a difference**.
///
/// Two layers guard that, deliberately. This file checks the *source*: that every visual value is
/// declared in one place, and that nothing in the stylesheet reaches for a way to make a mark
/// disappear. The application selftest then checks the *live document* — computed style on real
/// elements — because a stylesheet can be read and still be wrong about what the reader gets.
///
/// Neither is sufficient alone. A rule can be added anywhere; a value can be inlined in JavaScript.
func runDesignChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let rendererDir = root.appendingPathComponent("Renderer/src")
    let html = (try? String(contentsOf: rendererDir.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
    let tokens = (try? String(contentsOf: rendererDir.appendingPathComponent("tokens.css"), encoding: .utf8)) ?? ""
    let script = (try? String(contentsOf: rendererDir.appendingPathComponent("main.js"), encoding: .utf8)) ?? ""

    print("\n=== every visual value is declared in one file (G2) ===")
    do {
        report("tokens.css exists and is not empty", !tokens.isEmpty, "\(tokens.count) bytes")
        report("index.html exists", !html.isEmpty)

        // Comments are stripped first: a hex code in prose about hex codes is not a declaration,
        // and failing on one would teach the next reader to work around the check.
        func stripped(_ text: String) -> String {
            var out = text
            // `(?s)`, because a CSS comment that explains something is usually more than one line
            // — and without it this stripped only the one-liners, then reported the hex colour
            // inside a three-line note as a literal declared in the stylesheet.
            out = out.replacingOccurrences(of: "(?s)/\\*.*?\\*/", with: " ",
                                           options: [.regularExpression])
            out = out.replacingOccurrences(of: "(?m)^\\s*//.*$", with: " ",
                                           options: [.regularExpression])
            return out
        }

        let literals: [(String, String)] = [
            ("a hex colour", "#[0-9a-fA-F]{3,8}\\b"),
            ("an rgb() or hsl() colour", "\\b(rgba?|hsla?)\\("),
            ("a font stack", "font-family\\s*:"),
            ("a pixel size", ":[^;{}]*\\b[0-9]+px"),
        ]
        for (what, pattern) in literals {
            let hits = stripped(html).ranges(of: pattern)
            report("index.html declares no \(what) of its own", hits.isEmpty,
                   hits.prefix(3).joined(separator: " | "))
        }

        // The same rule for the script: a style set from JavaScript would sit outside the token
        // file just as surely as one in the stylesheet.
        let scriptStyles = stripped(script).ranges(of: "style\\.(background|color|font|border)\\s*=")
        report("main.js sets no style values of its own", scriptStyles.isEmpty,
               scriptStyles.prefix(3).joined(separator: " | "))

        // Since T1 there are two surfaces, and the grid takes its colours from the same file
        // (DEC-054) — so both pages and both scripts count as users of a token.
        let terminalHTML = (try? String(contentsOf: rendererDir.appendingPathComponent("terminal.html"),
                                        encoding: .utf8)) ?? ""
        let terminalScript = (try? String(contentsOf: rendererDir.appendingPathComponent("terminal.js"),
                                          encoding: .utf8)) ?? ""
        report("terminal.html exists", !terminalHTML.isEmpty)
        for (what, pattern) in literals {
            let hits = stripped(terminalHTML).ranges(of: pattern)
            report("terminal.html declares no \(what) of its own", hits.isEmpty,
                   hits.prefix(3).joined(separator: " | "))
        }

        // Every `var(--ds-…)` a surface reaches for must exist, or the design silently loses a
        // property and the mark quietly falls back to nothing.
        let used = Set((html + terminalHTML + terminalScript).ranges(of: "--ds-[a-z0-9-]+"))
        let missing = used.filter { !tokens.contains("\($0):") }
        report("every token the stylesheet uses is defined", missing.isEmpty,
               missing.sorted().joined(separator: ", "))
        report("the stylesheet actually uses tokens", used.count > 20, "\(used.count) referenced")

        // The other direction: a token nobody references is a value a designer would change to no
        // effect, which is worse than not offering it.
        let declared = Set(tokens.ranges(of: "--ds-[a-z0-9-]+(?=\\s*:)"))

        // Except that two thirds of the window is AppKit, which cannot read this file (DEC-066).
        // Those tokens are declared inside `@chrome` blocks and are exempt from the rule above —
        // and the exemption is a redirect rather than a hole: each one must be named in
        // `Theme.swift` instead, which is the hand-mirroring step that until now had no check
        // behind it at all.
        let chromeBlocks = tokens.ranges(of: "(?s)/\\* @chrome.*?/\\* @endchrome \\*/")
        let chrome = Set(chromeBlocks.flatMap { $0.ranges(of: "--ds-[a-z0-9-]+(?=\\s*:)") })
        report("the chrome block is found and non-empty", !chrome.isEmpty,
               "\(chrome.count) tokens in \(chromeBlocks.count) blocks")

        let unused = declared.subtracting(used).subtracting(chrome)
        report("every token declared is actually used, or declared for the chrome", unused.isEmpty,
               unused.sorted().joined(separator: ", "))

        let theme = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/Theme.swift"),
                                 encoding: .utf8)) ?? ""
        let unmirrored = chrome.filter { !theme.contains($0) }.sorted()
        report("every chrome token has a counterpart in Theme.swift",
               unmirrored.isEmpty, unmirrored.joined(separator: ", "))

        // The negative control. A `contains` over two long files will agree with almost anything,
        // and this check's whole value is that it disagrees when a design adds a chrome token and
        // stops at the stylesheet.
        report("negative control: a chrome token absent from Theme.swift is reported",
               !theme.contains("--ds-invented-for-this-check"))
    }

    print("\n=== the empty state's buttons carry a rim and keep their behaviour ===")
    do {
        let shell = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
                                 encoding: .utf8)) ?? ""
        let theme = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/Theme.swift"),
                                 encoding: .utf8)) ?? ""
        report("the rim and the fill come from the token table",
               theme.contains("--ds-button-rim") && theme.contains("--ds-button-fill")
                   && shell.contains("Theme.buttonRim"))
        // The reason this is a check rather than a comment: the obvious way to get the design's
        // rim is to draw the button, and a drawn button loses the key-equivalent ring, the pressed
        // state and the focus behaviour — on the first screen a stranger meets.
        report("and they are still system buttons, not drawn ones",
               !shell.contains("chooseFolder.isBordered = false")
                   && shell.contains("button.bezelColor = Theme.buttonFill"))
        report("the default button keeps its key equivalent",
               shell.contains("chooseFolder.keyEquivalent = \"\\r\""))
    }

    print("\n=== the two panes share one horizontal position (12-… §5.4) ===")
    do {
        let script = (try? String(contentsOf: rendererDir.appendingPathComponent("main.js"),
                                  encoding: .utf8)) ?? ""
        // §5.4 asks for horizontal scrolling to be linked, and only the vertical half was wired
        // for three milestones: on a minified file the panes drifted apart and the reader was
        // comparing column 200 of one side with column 40 of the other.
        report("scrolling one pane moves the other on both axes",
               script.contains("b.scrollDOM.scrollTop = a.scrollDOM.scrollTop")
                   && script.contains("b.scrollDOM.scrollLeft = a.scrollDOM.scrollLeft"))
        report("and the shared position has a control that is not a scrollbar",
               html.contains("id=\"track\"") && script.contains("function updateTrack"))
        report("which is quietened rather than hidden when there is nothing to scroll",
               html.contains("#track:disabled") && !html.contains("#track:disabled { display: none"))
    }

    print("\n=== nothing animates without an off switch (DEC-064, 24-… §5) ===")
    do {
        // The rule this replaced was stronger and free: *nothing animates*, so reduced motion was
        // honoured by construction. The product owner reopened it, and a guarantee by construction
        // becomes a guarantee by check — with the negative control that makes it one.
        let terminalHTML = (try? String(contentsOf: rendererDir.appendingPathComponent("terminal.html"),
                                        encoding: .utf8)) ?? ""
        func guarded(_ page: String) -> Bool {
            let animates = page.range(of: "(transition|animation)\\s*:", options: .regularExpression) != nil
            guard animates else { return true }
            guard let block = page.range(of: "(?s)@media \\(prefers-reduced-motion: reduce\\).*?\\}\\s*\\}",
                                         options: .regularExpression) else { return false }
            let body = String(page[block])
            return body.contains("transition: none") && body.contains("animation: none")
        }
        report("every animated surface carries a prefers-reduced-motion block that switches it off",
               guarded(html) && guarded(terminalHTML))

        // The durations are tokens, so the design's motion register and the stylesheet cannot
        // drift to different numbers.
        report("durations and curves come from tokens like every other value",
               !html.contains("transition:") || html.contains("var(--ds-motion-"))

        let hostile = """
            .thing { transition: opacity 200ms ease; }
            """
        // The chrome animates too, and AppKit has no media query — the system setting is read
        // directly, and the check says so rather than trusting that someone remembered.
        let shell = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
                                 encoding: .utf8)) ?? ""
        let animatesChrome = shell.contains("NSAnimationContext")
        report("the chrome asks the system before it animates",
               !animatesChrome || shell.contains("accessibilityDisplayShouldReduceMotion"))
        report("and its duration is the same token the webviews use",
               !animatesChrome || shell.contains("Theme.motionQuick"))

        report("negative control: an animation with no reduce block is caught", !guarded(hostile))
        let hostileWithEmptyBlock = """
            .thing { transition: opacity 200ms ease; }
            @media (prefers-reduced-motion: reduce) { .other { color: red; } }
            """
        report("and so is a reduce block that switches nothing off",
               !guarded(hostileWithEmptyBlock))
    }

    print("\n=== a design may restyle a mark and may not hide one (G2) ===")
    do {
        // The classes that carry a difference. Hiding any of these turns a correct model into a
        // false picture, which is the one regression CSS alone can cause.
        let carriers = ["ds-changed", "ds-fallback", "ds-moved", "ds-formatting", "ds-behaviour",
                        "ds-uncertain", "ds-invisible", "ds-fold", "ds-fold-formatting",
                        "ds-badge", "ds-gutter-changed", "ds-chip"]
        var offenders: [String] = []
        for name in carriers {
            // The rule body for this class, if the stylesheet declares one.
            guard let range = html.range(of: "\\.\(name)\\s*\\{[^}]*\\}", options: .regularExpression)
            else { continue }
            let body = String(html[range])
            for forbidden in ["display: none", "display:none", "visibility: hidden",
                              "visibility:hidden", "opacity: 0;", "opacity:0;"] {
                if body.contains(forbidden) { offenders.append("\(name): \(forbidden)") }
            }
        }
        report("no class carrying a difference is hidden by the stylesheet",
               offenders.isEmpty, offenders.joined(separator: ", "))

        // DEC-035: colour alone is not a signal. Every mark must declare at least one property that
        // survives greyscale — a texture, an underline, an outline or an edge.
        let shapeProperties = ["text-decoration", "background: repeating-linear-gradient",
                               "outline", "border", "font-weight", "background: var(--ds-fill"]
        var colourOnly: [String] = []
        for name in ["ds-changed", "ds-fallback", "ds-moved", "ds-formatting", "ds-behaviour",
                     "ds-uncertain", "ds-invisible", "ds-gutter-changed"] {
            guard let range = html.range(of: "\\.\(name)\\s*\\{[^}]*\\}", options: .regularExpression)
            else { colourOnly.append("\(name): no rule at all"); continue }
            let body = String(html[range])
            if !shapeProperties.contains(where: { body.contains($0) }) { colourOnly.append(name) }
        }
        report("every mark is distinguishable by something other than colour (DEC-035)",
               colourOnly.isEmpty, colourOnly.joined(separator: ", "))

        // INV-4 is a promise about what is *seen*. The bar that carries every fallback notice is
        // therefore not something a design may lay out to nothing.
        if let range = html.range(of: "#notices\\s*\\{[^}]*\\}", options: .regularExpression) {
            let body = String(html[range])
            report("the notice bar is not styled away",
                   !body.contains("display: none") && !body.contains("visibility: hidden"), body)
        } else {
            report("the notice bar has a rule", false)
        }
    }

    print("\n=== the design checks can actually fail ===")
    do {
        // Applied to a deliberately hostile stylesheet rather than to the real one. A check that has
        // only ever seen a passing input is an assumption wearing a check's clothes — the same
        // reasoning as M6-B's budget-0 control and the selftest's injected `display: none`.
        let hostile = """
        .ds-changed { display: none; color: #ff0000; }
        .ds-moved { color: rgb(200, 0, 0); }
        #notices { visibility: hidden; }
        """
        report("a hex colour in the stylesheet is caught",
               !hostile.ranges(of: "#[0-9a-fA-F]{3,8}\\b").isEmpty)
        report("an rgb() colour is caught",
               !hostile.ranges(of: "\\b(rgba?|hsla?)\\(").isEmpty)

        let changedBody = hostile.range(of: "\\.ds-changed\\s*\\{[^}]*\\}", options: .regularExpression)
            .map { String(hostile[$0]) } ?? ""
        report("a hidden mark is caught", changedBody.contains("display: none"))

        // And the mark that is *only* a colour: no texture, no underline, no outline, no edge.
        let shapeProperties = ["text-decoration", "background: repeating-linear-gradient",
                               "outline", "border", "font-weight"]
        let movedBody = hostile.range(of: "\\.ds-moved\\s*\\{[^}]*\\}", options: .regularExpression)
            .map { String(hostile[$0]) } ?? ""
        report("a mark reduced to colour alone is caught",
               !shapeProperties.contains(where: { movedBody.contains($0) }), movedBody)

        let barBody = hostile.range(of: "#notices\\s*\\{[^}]*\\}", options: .regularExpression)
            .map { String(hostile[$0]) } ?? ""
        report("a notice bar styled away is caught", barBody.contains("visibility: hidden"))
    }

    print("\n=== the AppKit chrome reads from the same table ===")
    do {
        let appDir = root.appendingPathComponent("Sources/diffscope-app")
        let theme = (try? String(contentsOf: appDir.appendingPathComponent("Theme.swift"), encoding: .utf8)) ?? ""
        let main = (try? String(contentsOf: appDir.appendingPathComponent("main.swift"), encoding: .utf8)) ?? ""
        report("Theme.swift exists", !theme.isEmpty)

        // The chrome is two thirds of the window. A design that only reaches the webview leaves the
        // lists, the status line and the empty state looking like a different application.
        let inlineFonts = main.ranges(of: "ofSize: [0-9]+")
        report("no font size is written inline in the application",
               inlineFonts.isEmpty, inlineFonts.prefix(3).joined(separator: " | "))
        let inlineColours = main.ranges(of: "= \\.(secondaryLabelColor|labelColor|systemRed|systemBlue)")
        report("no colour is written inline in the application",
               inlineColours.isEmpty, inlineColours.prefix(3).joined(separator: " | "))
        // The chrome's colours are checked token by token where they are declared; this is the
        // rest of the mirror — type and spacing, which have no `@chrome` block because both
        // surfaces use them.
        report("the token names are mirrored, not invented separately",
               theme.contains("--ds-font") && theme.contains("--ds-space") && theme.contains("--ds-text"))
    }
}

private extension String {
    /// Every match of a pattern, as strings. Small helper so the checks above read as statements
    /// about the file rather than as regular-expression plumbing.
    func ranges(of pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: text.length))
            .map { text.substring(with: $0.range) }
    }
}

/// G3 of `23-release-gates.md`: the claims made to a third-party tester in `25-tester-packet.md`.
///
/// The privacy paragraph is the part of that document a stranger has to take on trust, so it is the
/// part that gets checked. "No network code" is a statement about the source; this is the source
/// being asked.
func runTesterPacketChecks(_ reportRaw: (String, Bool, String) -> Void) {
    func report(_ name: String, _ ok: Bool, _ detail: String = "") { reportRaw(name, ok, detail) }

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fm = FileManager.default

    print("\n=== the design contract describes the window that exists (G2) ===")
    do {
        // `24-design-contract.md` is the document a designer works from, and until M8-P **nothing
        // read it**. It claimed to list *every class the renderer emits* while describing a window
        // with one webview in it: the terminal landed the day after G2 passed and the contract was
        // never told. Sixth instance in this project of a written promise nothing runs against —
        // after `runBundleFreshnessCheck`, `checkAttr`, `MANIFEST.json`, T-10 and §9's missing row.
        let contract = (try? String(
            contentsOf: root.appendingPathComponent("docs/24-design-contract.md"),
            encoding: .utf8)) ?? ""
        let rendererSources = root.appendingPathComponent("Renderer/src")
        let diffHTML = (try? String(contentsOf: rendererSources.appendingPathComponent("index.html"),
                                    encoding: .utf8)) ?? ""
        let termHTML = (try? String(contentsOf: rendererSources.appendingPathComponent("terminal.html"),
                                    encoding: .utf8)) ?? ""
        let diffScript = (try? String(contentsOf: rendererSources.appendingPathComponent("main.js"),
                                      encoding: .utf8)) ?? ""
        let shell = (try? String(
            contentsOf: root.appendingPathComponent("Sources/diffscope-app/main.swift"),
            encoding: .utf8)) ?? ""

        report("the contract exists and is not empty", !contract.isEmpty, "\(contract.count) bytes")

        // The class the hostile-probe control applies is the selftest's own instrument, not
        // something a reader ever sees, so it is not part of the contract.
        let emitted = Set(diffScript.ranges(of: "ds-[a-z-]+")).subtracting(["ds-hostile-probe"])
        let undocumented = emitted.filter { !contract.contains("`\($0)`") }.sorted()
        report("every class the renderer applies is described in the contract",
               undocumented.isEmpty, undocumented.joined(separator: ", "))

        // Ids, because half the load-bearing surface is an element rather than a class: the notice
        // bar, the unrenderable state, and every part of the terminal pane.
        let ids = Set((diffHTML + termHTML).ranges(of: "id=\"[a-z-]+\""))
            .map { $0.replacingOccurrences(of: "id=\"", with: "").replacingOccurrences(of: "\"", with: "") }
        let undocumentedIds = ids.filter { !contract.contains("`#\($0)`") }.sorted()
        report("every element the two webviews emit is described in the contract",
               undocumentedIds.isEmpty, undocumentedIds.joined(separator: ", "))

        // §6 tells a designer which pictures to look at, and a picture nobody is told about is a
        // state nobody checks. This is how the terminal's three snapshots were missing from a
        // document whose whole job is "look at every state it draws".
        // Three call sites, because there are three things worth photographing: the diff document,
        // the terminal grid, and the whole window. `moveFocus(to:named:)` also takes a `named:` and
        // is not a snapshot — the first version of this check matched it and demanded the contract
        // list "repositories", "files" and "diff" as pictures.
        let snapshots = Set(shell.ranges(of: "(snapshot|snapshotTerminal|windowSnapshot)\\(named: \"[a-z-]+\""))
            .compactMap { $0.split(separator: "\"").dropFirst().first.map(String.init) }
        let unlisted = snapshots.filter { !contract.contains("`\($0)`") }.sorted()
        report("every snapshot the selftest writes is listed in the contract's walkthrough",
               unlisted.isEmpty, unlisted.joined(separator: ", "))

        // The negative control. Every assertion above is a `contains` over a long document, and a
        // document long enough will contain almost anything by accident.
        report("negative control: a class the renderer does not emit is not in the contract",
               !contract.contains("`ds-invented-for-this-check`"))
        report("and the contract names the terminal at all",
               contract.lowercased().contains("terminal") && contract.contains("--ds-term-"))
    }

    print("\n=== the privacy statement given to a tester is true of the source (G3) ===")
    do {
        // Every Swift file that ships inside the application, which is all of them except the
        // check suite itself.
        var shipped: [String] = []
        // Every shipped module. A module missing from this list is a module the privacy claim was
        // never checked against — the T4 lesson that a list of things is itself a thing that can be
        // incomplete, which is why `DiffScopeShell` was added here in the same commit that created it.
        for module in ["DiffScopeEngine", "DiffScopeGit", "DiffScopeSyntax", "DiffScopeTerminal",
                       "DiffScopeShell", "diffscope-app"] {
            let dir = root.appendingPathComponent("Sources/\(module)")
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                shipped.append((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            }
        }
        report("the application's own sources were found", shipped.count > 10, "\(shipped.count) files")

        // Named individually rather than as one pattern, so a failure says which capability appeared.
        let networkAPIs = ["URLSession", "NWConnection", "NWBrowser", "CFNetwork",
                           "getaddrinfo", "Network.framework"]
        var found: [String] = []
        for api in networkAPIs where shipped.contains(where: { $0.contains(api) }) { found.append(api) }
        report("no network API appears anywhere in the shipped sources",
               found.isEmpty, found.joined(separator: ", "))

        // The renderer runs in a webview, which is the one component that *could* reach the network
        // without any Swift being involved. Every source is asked, not just the first one written.
        let browserAPIs = ["fetch(", "XMLHttpRequest", "new WebSocket", "navigator.sendBeacon"]
        var rendererSources: [String: String] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Renderer/src").path)) ?? []
            where name.hasSuffix(".js") {
            rendererSources[name] = (try? String(contentsOf: root.appendingPathComponent("Renderer/src/\(name)"),
                                                 encoding: .utf8)) ?? ""
        }
        report("every renderer source was found", rendererSources.count >= 2,
               rendererSources.keys.sorted().joined(separator: ", "))
        let inRenderer = rendererSources.flatMap { name, text in
            browserAPIs.filter { text.contains($0) }.map { "\(name): \($0)" }
        }
        report("the renderer makes no requests of its own", inRenderer.isEmpty,
               inRenderer.joined(separator: ", "))

        // Since T1 the bundles carry third-party code (xterm.js, DEC-054). A claim about the
        // sources we wrote is no longer a claim about what ships, so the built bundles are asked
        // the same question.
        var inBundles: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("Sources/diffscope-app/Renderer").path)) ?? []
            where name.hasSuffix(".js") {
            let text = (try? String(contentsOf: root.appendingPathComponent("Sources/diffscope-app/Renderer/\(name)"),
                                    encoding: .utf8)) ?? ""
            inBundles += browserAPIs.filter { text.contains($0) }.map { "\(name): \($0)" }
        }
        report("and neither does anything bundled with it", inBundles.isEmpty,
               inBundles.joined(separator: ", "))

        // The packet tells a tester that deleting one file makes the application forget everything.
        let packet = (try? String(contentsOf: root.appendingPathComponent("docs/25-tester-packet.md"),
                                  encoding: .utf8)) ?? ""
        report("the tester packet exists", !packet.isEmpty)
        report("and names the only file the application writes",
               packet.contains("Application Support/DiffScope/config.json"))
        report("and tells the tester to keep a file that diffs wrongly",
               packet.lowercased().contains("keep the file"))
        report("and explains the Gatekeeper step, which is where an unsigned build loses people",
               packet.contains("Right-click") && packet.contains("Open"))

        // T4. The packet used to say the application "cannot commit, stage, push, pull, or change
        // anything in your repositories". Since DEC-053 that is false, and it is the one document
        // that goes to a stranger who is about to point this at their own work.
        report("the packet tells the tester the terminal exists",
               packet.contains("⌃`") && packet.lowercased().contains("terminal"))
        report("and that it runs what they type, naming the command that would change things",
               packet.contains("git commit"))
        report("and that their shell startup files are not modified",
               packet.contains("~/.zshrc") && packet.lowercased().contains("never edit"))
        report("and it no longer claims the application cannot change a repository",
               !packet.contains("It cannot commit"))

        // DEC-057 made the keyboard map data and generated the menu from it, so the menu cannot
        // disagree with the map. The packet is a **third** transcription of the same map, by hand,
        // and it drifted exactly as §9's table did before DEC-057: DEC-065 moved open-in-editor
        // from ⌘O to ⌘⏎ and the packet went on saying ⌘O for two milestones, while a second line
        // had Structural on ⌘2 and Raw on ⌘1 — contradicting the packet's own mode list.
        //
        // A keystroke printed for a stranger who is about to press it is worth the same treatment
        // as a row of the coverage table.
        let shortcuts = Set(KeyboardMap.bindings.map(\.shortcut))
        // Keys the packet names that are deliberately **not** the application's. `⌃C` is the one
        // that matters: the packet tells the tester to press it to stop a command, and it reaches
        // the shell through the terminal rather than being bound here. Listing it is the honest
        // form — the alternative is a check that quietly skips anything it does not recognise.
        let shellKeys: Set<String> = ["⌃C", "⌃R"]
        var unknown: [String] = []
        // `⌘⏎`, `⌥⌘→`, `⇧⌘↑`, `⌃\``: a modifier run followed by one character, which is what
        // `KeyboardBinding.shortcut` composes. The key position is **any** character rather than a
        // list of acceptable ones — the first version excluded `]` to avoid Markdown link syntax
        // and promptly failed on `⌃⌘]`, which is a real binding. Excluding `,` would have broken
        // `⌘,` the same way. Whether a token is a shortcut is decided by the map, not by a guess
        // about punctuation.
        let pattern = try! NSRegularExpression(pattern: "[⌃⌥⇧⌘]+.")
        let range = NSRange(packet.startIndex..., in: packet)
        for match in pattern.matches(in: packet, range: range) {
            guard let found = Range(match.range, in: packet) else { continue }
            let token = String(packet[found])
            if shortcuts.contains(token) || shellKeys.contains(token) { continue }
            unknown.append(token)
        }
        report("every keystroke the packet prints is one the application actually binds",
               unknown.isEmpty, Set(unknown).sorted().joined(separator: " "))
        // The control: a check that only ever sees a correct packet would pass on any packet. A
        // shortcut nothing binds has to be caught, or the assertion above is decoration.
        let hostile = packet + "\n\nPress ⌘J to do the thing.\n"
        var caughtHostile = false
        for match in pattern.matches(in: hostile, range: NSRange(hostile.startIndex..., in: hostile)) {
            guard let found = Range(match.range, in: hostile) else { continue }
            let token = String(hostile[found])
            if !shortcuts.contains(token), !shellKeys.contains(token) { caughtHostile = true }
        }
        report("control: a keystroke nothing binds is caught", caughtHostile)
    }

    // T4: eleven documents promised something that stopped being true when the terminal landed.
    // The old sentences are cheap to write back in by accident, so the promise is now a check.
    print("\n=== no document promises what DEC-053 stopped being true ===")
    do {
        // Current-state documents. Historical records — the decision log, the experiment log — are
        // *not* here on purpose: this project records corrections with the correction visible
        // rather than by editing the past, so DEC-003's own text stays as it was written and
        // carries an amendment pointer instead.
        let currentState = [
            "docs/25-tester-packet.md",
            "docs/01-product-brief.md",
            "docs/11-git-behavior-specification.md",
            "docs/17-security-privacy-and-licensing.md",
            "docs/18-version-one-scope.md",
            "docs/23-release-gates.md",
            // Added after a grep found a retired sentence in this file that the check had missed:
            // §12's definition of done still said "incapable of modifying a repository". A list of
            // documents is itself a thing that can be incomplete, so it is worth being generous.
            "docs/21-agent-handoff.md",
            "docs/00-index.md",
            "docs/15-test-corpus-plan.md",
            // The design-adoption document, added with it: it describes the window a reader will
            // see, and a document that describes the window and never mentions the shell in it is
            // the silent half of this check.
            "docs/27-design-adoption.md",
        ]
        // Each phrase is an unqualified claim about what the product cannot do. The qualified forms
        // — "on its own", "on any path of its own" — are the point and are not matched.
        let retired = ["It cannot commit", "incapable of modifying a repository.",
                       "It never writes.", "Strictly read-only;"]

        func offences(in text: String) -> [String] { retired.filter { text.contains($0) } }

        var stale: [String] = []
        var silent: [String] = []
        for path in currentState {
            let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
            guard !text.isEmpty else { stale.append("\(path): unreadable"); continue }
            for phrase in offences(in: text) { stale.append("\(path): \(phrase)") }
            // Removing a false sentence without saying the true thing is the worse defect: the
            // reader is left with no statement at all about what can change their repository.
            if !text.lowercased().contains("terminal") { silent.append(path) }
        }
        report("no current-state document still makes the unqualified claim", stale.isEmpty,
               stale.joined(separator: " | "))
        report("and every one of them says the terminal exists", silent.isEmpty,
               silent.joined(separator: ", "))

        // The negative control. Without it this whole table could be matching nothing at all and
        // would read exactly the same.
        let hostile = "This product is demonstrably incapable of modifying a repository."
        report("the check catches the retired sentence when it is put back",
               !offences(in: hostile).isEmpty, hostile)

        // DEC-003 is where a reader lands first, so the amendment has to be on the entry itself.
        let decisions = (try? String(contentsOf: root.appendingPathComponent("docs/04-decision-log.md"),
                                     encoding: .utf8)) ?? ""
        if let range = decisions.range(of: "## DEC-003") {
            let entry = String(decisions[range.lowerBound...].prefix(900))
            report("DEC-003 carries its own pointer to the amendment that narrowed it",
                   entry.contains("DEC-053"))
        } else {
            report("DEC-003 exists in the decision log", false)
        }
    }

    print("\n=== the packaging script produces something a stranger can run (G3) ===")
    do {
        let script = (try? String(contentsOf: root.appendingPathComponent("Scripts/package.sh"),
                                  encoding: .utf8)) ?? ""
        report("Scripts/package.sh exists", !script.isEmpty)
        // The classic way this step fails: a bundle that reads from the checkout works on the
        // machine that built it and nowhere else. The script proves independence rather than
        // assuming it, and that proof is part of the script rather than a thing someone remembers.
        report("it proves the bundle runs away from the source tree",
               script.contains("proving it runs with nothing from the source tree")
                   && script.contains("mktemp -d"))
        report("it records a checksum beside the zip", script.contains("shasum -a 256"))
        report("the resource bundle is placed where both lookup rules find it",
               script.contains("Contents/Resources/") && script.contains("Contents/MacOS/"))
    }
}
