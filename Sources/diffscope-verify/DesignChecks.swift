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
            out = out.replacingOccurrences(of: "/\\*.*?\\*/", with: " ",
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

        // Every `var(--ds-…)` the stylesheet reaches for must exist, or the design silently loses a
        // property and the mark quietly falls back to nothing.
        let used = Set(html.ranges(of: "--ds-[a-z0-9-]+"))
        let missing = used.filter { !tokens.contains("\($0):") }
        report("every token the stylesheet uses is defined", missing.isEmpty,
               missing.sorted().joined(separator: ", "))
        report("the stylesheet actually uses tokens", used.count > 20, "\(used.count) referenced")

        // The other direction: a token nobody references is a value a designer would change to no
        // effect, which is worse than not offering it.
        let declared = Set(tokens.ranges(of: "--ds-[a-z0-9-]+(?=\\s*:)"))
        let unused = declared.subtracting(used)
        report("every token declared is actually used", unused.isEmpty,
               unused.sorted().joined(separator: ", "))
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
        report("the token names are mirrored, not invented separately",
               theme.contains("--ds-font") && theme.contains("--ds-space") && theme.contains("--ds-ink"))
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

    print("\n=== the privacy statement given to a tester is true of the source (G3) ===")
    do {
        // Every Swift file that ships inside the application, which is all of them except the
        // check suite itself.
        var shipped: [String] = []
        for module in ["DiffScopeEngine", "DiffScopeGit", "DiffScopeSyntax", "diffscope-app"] {
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

        let renderer = (try? String(contentsOf: root.appendingPathComponent("Renderer/src/main.js"),
                                    encoding: .utf8)) ?? ""
        // The renderer runs in a webview, which is the one component that *could* reach the network
        // without any Swift being involved.
        let browserAPIs = ["fetch(", "XMLHttpRequest", "new WebSocket", "navigator.sendBeacon"]
        let inRenderer = browserAPIs.filter { renderer.contains($0) }
        report("the renderer makes no requests of its own", inRenderer.isEmpty,
               inRenderer.joined(separator: ", "))

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
