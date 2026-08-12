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

        let menu = body(of: "showAddSourceMenu", in: shell)
        report("the button's menu is found in the shell", !menu.isEmpty, "\(menu.count) bytes")
        report("it is composed from the keyboard map",
               menu.contains("KeyboardMap.bindings(in: .sources)"))
        report("and it names no title of its own",
               !menu.contains("NSMenuItem(title: \""), menu)

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
