import AppKit
import WebKit

/// The feature being asked for is the macOS motions in the input line, so they are measured rather
/// than assumed: real key events with real modifier flags, through whatever machinery the control
/// actually uses, and the resulting caret positions are reported as numbers.
enum Motions {
    static let sample = """
    git commit -m "fix the thing"
    git push --force-with-lease
    """

    struct Reading {
        let name: String
        let from: Int
        let caret: Int
        let text: String
        let expected: Int
        var matches: Bool { caret == expected }
    }

    private static func keyEvent(_ characters: String,
                                 _ keyCode: UInt16,
                                 _ flags: NSEvent.ModifierFlags,
                                 window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown,
                         location: .zero,
                         modifierFlags: flags,
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber,
                         context: nil,
                         characters: characters,
                         charactersIgnoringModifiers: characters,
                         isARepeat: false,
                         keyCode: keyCode)
    }

    private static let leftArrow = ("\u{F702}", UInt16(123))
    private static let rightArrow = ("\u{F703}", UInt16(124))
    private static let deleteKey = ("\u{7F}", UInt16(51))

    /// Returns the readings and the path that delivered the keys, because "which mechanism moved
    /// the caret" is part of the answer for T2.
    static func measureAppKit() -> (readings: [Reading], path: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled, .resizable],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        textView.isRichText = false
        textView.isEditable = true
        window.contentView = textView
        window.makeFirstResponder(textView)
        window.orderFrontRegardless()

        let text = sample as NSString
        let lineTwoStart = text.range(of: "git push").location
        let lineOneEnd = text.range(of: "\n").location
        let thing = text.range(of: "thing").location
        let the = text.range(of: "the ").location
        let lineTwoEnd = text.length
        let insideLineTwo = lineTwoStart + 5

        var path = "interpretKeyEvents"
        var readings: [Reading] = []

        func run(_ name: String,
                 from caret: Int,
                 key: (String, UInt16),
                 flags: NSEvent.ModifierFlags,
                 expected: Int) {
            textView.string = sample
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            guard let event = keyEvent(key.0, key.1, flags, window: window) else { return }
            textView.interpretKeyEvents([event])
            if textView.selectedRange().location == caret, textView.string == sample {
                // Nothing moved: the standard binding path did not deliver. Say so rather than
                // reporting a failure of the control — the harness is the suspect first.
                path = "interpretKeyEvents (no effect)"
            }
            readings.append(Reading(name: name,
                                    from: caret,
                                    caret: textView.selectedRange().location,
                                    text: textView.string,
                                    expected: expected))
        }

        run("Option+← from end of line 1", from: lineOneEnd, key: leftArrow, flags: [.option], expected: thing)
        run("Option+← from start of \"thing\"", from: thing, key: leftArrow, flags: [.option], expected: the)
        run("Option+→ from start of line 1", from: 0, key: rightArrow, flags: [.option], expected: 3)
        run("Cmd+← from inside line 2", from: insideLineTwo, key: leftArrow, flags: [.command], expected: lineTwoStart)
        run("Cmd+→ from inside line 2", from: insideLineTwo, key: rightArrow, flags: [.command], expected: lineTwoEnd)

        textView.string = sample
        textView.setSelectedRange(NSRange(location: lineOneEnd, length: 0))
        if let event = keyEvent(deleteKey.0, deleteKey.1, [.option], window: window) {
            textView.interpretKeyEvents([event])
        }
        readings.append(Reading(name: "Option+Delete from end of line 1",
                                from: lineOneEnd,
                                caret: textView.selectedRange().location,
                                text: textView.string,
                                expected: thing))

        window.close()
        return (readings, path)
    }

    /// Informational only. If the harness cannot drive a web text field headlessly, that is a fact
    /// about the harness; it must not be reported as a fact about the surface.
    static func measureWebView() -> (readings: [Reading], note: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        window.contentView = webView
        window.orderFrontRegardless()

        let html = """
        <!doctype html><meta charset="utf-8">
        <body style="margin:0"><textarea id="t" style="width:100%;height:100%"></textarea>
        <script>
        const t = document.getElementById('t');
        t.value = \(jsonString(sample));
        t.focus();
        </script>
        """
        webView.loadHTMLString(html, baseURL: nil)
        guard spin(until: { evaluate(webView, "document.readyState") as? String == "complete" },
                   timeout: 5) else {
            window.close()
            return ([], "the page never finished loading in a headless run")
        }

        let text = sample as NSString
        let lineTwoStart = text.range(of: "git push").location
        let lineOneEnd = text.range(of: "\n").location
        let thing = text.range(of: "thing").location

        var readings: [Reading] = []
        var delivered = false
        window.makeFirstResponder(webView)
        _ = evaluate(webView, "1")

        func run(_ name: String, from caret: Int, key: (String, UInt16), flags: NSEvent.ModifierFlags, expected: Int) {
            // Seeding has to come *after* the responder change: making the web view first responder
            // re-focuses the field and puts the caret back at the end, which silently moved the
            // starting point of the first run of this probe.
            window.makeFirstResponder(webView)
            let seeded = evaluate(webView,
                                  "t.value = \(jsonString(sample)); t.focus();"
                                      + " t.setSelectionRange(\(caret), \(caret)); t.selectionStart")
                as? Int ?? -1
            guard let event = keyEvent(key.0, key.1, flags, window: window) else { return }
            webView.keyDown(with: event)
            _ = spin(until: { (evaluate(webView, "t.selectionStart") as? Int ?? seeded) != seeded },
                     timeout: 1.5)
            let position = evaluate(webView, "t.selectionStart") as? Int ?? -1
            let value = evaluate(webView, "t.value") as? String ?? ""
            if position != seeded || value != sample { delivered = true }
            readings.append(Reading(name: name, from: seeded, caret: position, text: value, expected: expected))
        }

        let the = text.range(of: "the ").location
        let lineTwoEnd = text.length
        let insideLineTwo = lineTwoStart + 5

        run("Option+← from end of line 1", from: lineOneEnd, key: leftArrow, flags: [.option], expected: thing)
        run("Option+← from start of \"thing\"", from: thing, key: leftArrow, flags: [.option], expected: the)
        run("Option+→ from start of line 1", from: 0, key: rightArrow, flags: [.option], expected: 3)
        run("Cmd+← from inside line 2", from: insideLineTwo, key: leftArrow, flags: [.command], expected: lineTwoStart)
        run("Cmd+→ from inside line 2", from: insideLineTwo, key: rightArrow, flags: [.command], expected: lineTwoEnd)
        run("Option+Delete from end of line 1", from: lineOneEnd, key: deleteKey, flags: [.option], expected: thing)

        window.close()
        return (readings, delivered ? "keys reached the web text field" : "no key reached the web text field headlessly")
    }

    private static func evaluate(_ webView: WKWebView, _ script: String) -> Any? {
        var result: Any?
        var finished = false
        webView.evaluateJavaScript(script) { value, _ in
            result = value
            finished = true
        }
        _ = spin(until: { finished }, timeout: 2)
        return result
    }

    /// No `NSApp.run()` anywhere in this probe: the run loop is spun by hand so every scenario stays
    /// sequential and every wait has a deadline.
    @discardableResult
    static func spin(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }
}
