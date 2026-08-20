import AppKit
import MdCode

// MARK: - Self-test harness (CLI-verifiable TDD: `Markdown --selftest`)

@MainActor
public enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    /// Reproduces the live edit sequence headlessly: sample doc → select-all+delete
    /// → type "Hello" → Return → "Hello". Mirrors the live path (storage replaces,
    /// attribute restyle, activeCharacterRange, and the textViewDidChangeSelection
    /// invalidations) and prints the line-fragment glyph ranges after every step so
    /// the step that corrupts line breaking (newline no longer ends line 1) is visible.
    public static func headlessSequenceProbe() {
        // Variant 2 (LIVE-MIRROR): the attribute restyle runs INSIDE the storage's
        // didProcessEditing callback (as reapplyMarkdown does in the text view),
        // instead of after replaceCharacters returns.
        final class RestyleDelegate: NSObject, NSTextStorageDelegate {
            var caret = 0
            var lm: EditorLayoutManager? = nil
            func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                             range editedRange: NSRange, changeInLength delta: Int) {
                guard editedMask.contains(.editedCharacters) else { return }
                let parsed = MarkdownParser.parse(textStorage.string, style: .standard)
                parsed.attributed.enumerateAttributes(in: NSRange(location: 0, length: parsed.attributed.length), options: []) { attrs, range, _ in
                    textStorage.setAttributes(attrs, range: range)   // NO begin/endEditing: fires per-run, still inside the callback
                }
                lm?.activeCharacterRange = NSRange(location: caret, length: 0)
            }
        }
        let storage2 = NSTextStorage()
        let lm2 = EditorLayoutManager()
        storage2.addLayoutManager(lm2)
        let container2 = NSTextContainer(size: NSSize(width: 600, height: 4000))
        lm2.addTextContainer(container2)
        let delegate = RestyleDelegate()
        delegate.lm = lm2
        storage2.delegate = delegate
        func step2(_ label: String) {
            lm2.ensureLayout(for: container2)
            var frags: [String] = []
            lm2.enumerateLineFragments(forGlyphRange: lm2.glyphRange(forCharacterRange: NSRange(location: 0, length: storage2.length), actualCharacterRange: nil)) { _, _, _, gr, _ in
                frags.append("[" + String(gr.location) + "," + String(NSMaxRange(gr)) + ")")
            }
            print("SEQPROBE2 " + label + " len=" + String(storage2.length) + " frags=" + frags.joined(separator: " "))
        }
        storage2.setAttributedString(NSAttributedString(string: SampleDocument.text))
        step2("sample")
        storage2.replaceCharacters(in: NSRange(location: 0, length: storage2.length), with: "")
        delegate.caret = 0
        lm2.activeCharacterRange = NSRange(location: 0, length: 0)
        step2("emptied")
        func type2(_ s: String) {
            storage2.replaceCharacters(in: NSRange(location: delegate.caret, length: 0), with: s)
            delegate.caret += (s as NSString).length
            let affected = lm2.affectedRange(for: NSRange(location: delegate.caret, length: 0))
            lm2.invalidateGlyphs(forCharacterRange: affected, changeInLength: 0, actualCharacterRange: nil)
            lm2.invalidateLayout(forCharacterRange: affected, actualCharacterRange: nil)
            step2("typed [" + s.replacingOccurrences(of: String(UnicodeScalar(10)), with: "\\n") + "]")
        }
        type2("Hello")
        type2(String(UnicodeScalar(10)))
        type2("Hello")
    }

    /// Live-view regression probe: typing "Hello" + Return + "Hello" must render
    /// BOTH lines completely. A report said the second line lost its first
    /// character ("Hello" / "ello"). Dumps storage attributes, glyph ids, the
    /// glyph-to-character mapping and fragment widths so the failure mode
    /// (parser attribute vs stale layout mapping vs draw skip) is identifiable
    /// from the log alone. Run via: Markdown --typingprobe
    public static func typingProbe() {
        headlessSequenceProbe()   // storage-level repro first (no window needed)
        guard let tv = EditorTextView.live else {
            print("TYPINGPROBE FAIL no live text view")
            NSApp.terminate(nil)
            return
        }
        func report(_ name: String, _ cond: Bool, _ extra: String = "") {
            print(String(format: "TYPINGPROBE %@ %@ %@", cond ? "PASS" : "FAIL", name, extra))
        }
        let nl = String(UnicodeScalar(10))
        let expected = "Hello" + nl + "Hello"
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.deleteBackward(nil)
        tv.insertText("Hello")
        tv.insertNewline(nil)
        tv.insertText("Hello")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let storage = tv.textStorage, let lm = tv.layoutManager else {
                print("TYPINGPROBE FAIL no storage/layout")
                NSApp.terminate(nil)
                return
            }
            let ns = storage.string as NSString
            report("string verbatim", storage.string == expected,
                   String(format: "got [%@] len=%d", storage.string, ns.length))
            var syntax: [Int] = []
            for i in 0..<ns.length {
                if storage.attribute(.markdownSyntax, at: i, effectiveRange: nil) != nil { syntax.append(i) }
            }
            print(String(format: "TYPINGPROBE syntaxChars=%@", syntax))
            report("no syntax attrs in plain text", syntax.isEmpty, String(format: "%@", syntax))
            lm.ensureLayout(for: tv.textContainer!)
            let gAll = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: ns.length), actualCharacterRange: nil)
            var parts: [String] = []
            var prevX: CGFloat? = nil
            var g = gAll.location
            while g < NSMaxRange(gAll) {
                let gl = lm.glyph(at: g, isValidIndex: nil)
                let ci = lm.characterIndexForGlyph(at: g)
                let loc = lm.location(forGlyphAt: g)
                let adv = prevX.map { Double(loc.x - $0) }
                parts.append(String(format: "g%d=ch%d gl%d x%.1f a%.1f", g, ci, gl, Double(loc.x), adv ?? -1))
                prevX = loc.x
                g += 1
            }
            print(String(format: "TYPINGPROBE glyphs %@", parts.joined(separator: " ")))
            var frags: [String] = []
            lm.enumerateLineFragments(forGlyphRange: gAll) { rect, used, _, glyphRange, _ in
                frags.append(String(format: "g[%d,%d) w%.1f y%.1f", glyphRange.location, NSMaxRange(glyphRange), used.width, rect.minY))
            }
            print(String(format: "TYPINGPROBE frags %@", frags.joined(separator: " ")))
            var props: [String] = []
            for g in gAll.location..<NSMaxRange(gAll) {
                props.append(String(format: "g%d=0x%X", g, lm.propertyForGlyph(at: g).rawValue))
            }
            print(String(format: "TYPINGPROBE props %@", props.joined(separator: " ")))
            var fragRanges: [NSRange] = []
            lm.enumerateLineFragments(forGlyphRange: gAll) { _, _, _, gr, _ in fragRanges.append(gr) }
            let breakOK = fragRanges.count == 2 && fragRanges[0] == NSRange(location: 0, length: 6) && fragRanges[1] == NSRange(location: 6, length: 5)
            report("second line keeps its first char", breakOK,
                   fragRanges.map { "[" + String($0.location) + "," + String(NSMaxRange($0)) + ")" }.joined(separator: " "))
            let gH1 = lm.glyphRange(forCharacterRange: NSRange(location: 0, length: 1), actualCharacterRange: nil)
            let gH2 = lm.glyphRange(forCharacterRange: NSRange(location: 6, length: 1), actualCharacterRange: nil)
            let gl1 = gH1.length > 0 ? lm.glyph(at: gH1.location, isValidIndex: nil) : 0
            let gl2 = gH2.length > 0 ? lm.glyph(at: gH2.location, isValidIndex: nil) : 0
            report("second-line H keeps its glyph", gl1 != 0 && gl1 == gl2,
                   String(format: "H gl=%d line2-H gl=%d", gl1, gl2))
            print("TYPINGPROBE done")
            NSApp.terminate(nil)
        }
    }

    public static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  PASS \(name)")
        } else {
            failed += 1
            print("  FAIL \(name) \(detail)")
        }
    }

    public static func runAndExit() -> Never {
        // Live-harness entry: the pure parser/layout/continuation/code-highlighting
        // assertions (~200) now live in Swift Testing tests (Tests/MdTests and
        // Tests/MdCodeTests) — `swift test` is the real correctness gate. This
        // entry verifies the harness links and exits cleanly; the window-backed
        // probes (typingProbe / scrollGeometryProbe / editPathProbe /
        // EmptyDocScrollProbe) run via --smoke / --typingprobe instead.
        print("SELFTEST live-harness OK")
        exit(0)
    }

    // MARK: - Task 19 tests (code syntax highlighting)
    // NOTE: the assertions formerly in codeHighlightTests() were ported to
    // Tests/MdCodeTests/CodeHighlightingTests.swift and the parser-integration
    // checks to Tests/MdTests/ParserTests.swift — `swift test` is now the gate.
    // This section is intentionally empty (DRY).

    /// Measures scroll content geometry in the LIVE text view: the document view
    /// frame must track the layout manager's usedRect (+ vertical textContainerInset)
    /// so the scroller covers exactly the document. Drives the caret to the end and
    /// re-measures, since selection-driven reflows (zero-width commands) change layout.
    public static func scrollGeometryProbe() {
        guard let tv = EditorTextView.live, let scroll = tv.enclosingScrollView else {
            print("SCROLLPROBE FAIL no live text view / scroll view")
            return
        }
        func report(_ name: String, _ cond: Bool, _ extra: String = "") {
            print("SCROLLPROBE \(cond ? "PASS" : "FAIL") \(name) \(extra)")
        }
        func measure(_ label: String) {
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
            let inset = tv.textContainerInset
            let expected = used.height + inset.height * 2
            let frameH = tv.frame.height
            let delta = frameH - expected
            print("SCROLLPROBE \(label): frameH=\(frameH) usedH=\(used.height) expected=\(expected) delta=\(delta) contentSize=\(scroll.contentSize)")
            report("frame tracks usedRect", abs(delta) < 1.0, "delta=\(delta)")
        }
        print("SCROLLPROBE lmDelegateIsTV=\((tv.layoutManager?.delegate as AnyObject?) === tv) minSize=\(tv.minSize) maxSize=\(tv.maxSize) autoresizing=\(tv.autoresizingMask.rawValue)")
        measure("launch-caret-0")
        tv.sizeToFit()
        measure("after-sizeToFit")
        let len = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: len, length: 0))
        tv.insertText("X")
        measure("after-insert-at-end")
        tv.deleteBackward(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            measure("caret-at-end")
            print("SCROLLPROBE done")
        }
    }

    /// Drives the live editor through insertText / deleteBackward / insertNewline to
    /// diagnose "backspace does nothing" / "second Enter does nothing" reports.
    public static func editPathProbe() {
        guard let tv = EditorTextView.live else {
            print("EDITPROBE FAIL no live text view")
            return
        }
        func report(_ name: String, _ cond: Bool, _ extra: String = "") {
            print("EDITPROBE \(cond ? "PASS" : "FAIL") \(name) \(extra)")
        }
        let ns = tv.string as NSString
        let startLen = ns.length
        print("EDITPROBE launch selection=\(tv.selectedRange) len=\(startLen)")

        // Heading line-height probe in the real text view (regression: selecting a heading
        // was reported to grow its line height and push everything below down).
        let headingRange = ns.range(of: "### Task list")
        if headingRange.location != NSNotFound {
            func headingFrags() -> String {
                tv.layoutManager?.ensureLayout(for: tv.textContainer!)
                let g = tv.layoutManager!.glyphRange(forCharacterRange: headingRange, actualCharacterRange: nil)
                var frags: [String] = []
                tv.layoutManager!.enumerateLineFragments(forGlyphRange: g) { rect, used, _, _, _ in
                    frags.append("h=\(rect.height)/y=\(rect.minY)")
                }
                return frags.joined(separator: " ")
            }
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            let dInactive = headingFrags()
            tv.setSelectedRange(NSRange(location: headingRange.location + headingRange.length, length: 0))
            let dActive = headingFrags()
            let stable = dInactive == dActive
            print("EDITPROBE \(stable ? "PASS" : "FAIL") heading line stable: inactive=[\(dInactive)] active=[\(dActive)]")
        }
        tv.setSelectedRange(NSRange(location: startLen, length: 0))
        tv.insertText("Z")
        let afterInsert = (tv.string as NSString).length
        report("insertText", tv.string.hasSuffix("Z"), "len \(startLen) -> \(afterInsert)")
        tv.deleteBackward(nil)
        let afterDelete = (tv.string as NSString).length
        report("deleteBackward", !tv.string.hasSuffix("Z") && afterDelete == startLen, "len \(afterInsert) -> \(afterDelete)")
        let nl0 = tv.string.filter { $0 == "\n" }.count
        tv.insertNewline(nil)
        let nl1 = tv.string.filter { $0 == "\n" }.count
        report("first newline", nl1 == nl0 + 1, "nl \(nl0) -> \(nl1)")
        tv.insertNewline(nil)
        let nl2 = tv.string.filter { $0 == "\n" }.count
        report("second newline", nl2 == nl0 + 2, "nl \(nl1) -> \(nl2)")
        // Smart list continuation: Return on a list item prepends the marker; Return
        // on the fresh marker-only item removes it again (exits the list).
        let cl0 = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: cl0, length: 0))
        tv.insertText("- [ ] task")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertNewline(nil)
        report("list continuation marker", tv.string.hasSuffix("- [ ] task\n- [ ] "), "suffix=[\(String(tv.string.suffix(24)))]")
        report("list continuation caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        tv.insertNewline(nil)
        report("list continuation exit", tv.string.hasSuffix("- [ ] task\n"), "suffix=[\(String(tv.string.suffix(16)))]")
        report("list continuation exit caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        // Smart quote continuation: Return on a quote line prepends "> "; Return on
        // the fresh marker-only "> " line removes it again (exits the quote).
        let cq0 = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: cq0, length: 0))
        tv.insertText("> quoted")
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.insertNewline(nil)
        report("quote continuation marker", tv.string.hasSuffix("> quoted\n> "), "suffix=[\(String(tv.string.suffix(18)))]")
        report("quote continuation caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        tv.insertNewline(nil)
        report("quote continuation exit", tv.string.hasSuffix("> quoted\n"), "suffix=[\(String(tv.string.suffix(12)))]")
        report("quote continuation exit caret", tv.selectedRange.location == (tv.string as NSString).length, "caret=\(tv.selectedRange.location) len=\((tv.string as NSString).length)")
        // Middle-of-text edits (common backspace case)
        let mid = (tv.string as NSString).length / 2
        tv.setSelectedRange(NSRange(location: mid, length: 0))
        tv.insertText("Q")
        let c = (tv.string as NSString).character(at: mid)
        report("middle insert", c == 0x51, "char at \(mid) = \(c)")
        let lenMid1 = (tv.string as NSString).length
        tv.deleteBackward(nil)
        let lenMid2 = (tv.string as NSString).length
        report("middle delete", lenMid2 == lenMid1 - 1, "len \(lenMid1) -> \(lenMid2)")
        // Select all → delete (regression: crashed in setTypingAttributes/font panel)
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.deleteBackward(nil)
        let lenAfterSelectAll = (tv.string as NSString).length
        report("select-all delete", lenAfterSelectAll == 0, "len -> \(lenAfterSelectAll)")
        print("EDITPROBE final selection=\(tv.selectedRange) len=\((tv.string as NSString).length)")
    }
}

// MARK: - Smoke mode (launch, log, self-quit)

@MainActor
public enum SmokeTest {
    public static func schedule() {
        // Drive the live editor through the real edit path after the window is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            SelfTest.scrollGeometryProbe()   // runs first: editPathProbe empties the doc
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            SelfTest.editPathProbe()         // after the scroll probe's async measurements
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            EmptyDocScrollProbe.run()        // frame must shrink to ~insets, not clamp
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            print("SMOKE OK")
            NSApp.terminate(nil)
        }
    }
}

/// After the edit probe empties the document, the text view frame must shrink to
/// just the vertical insets (no minSize clamp to the first viewport height).
@MainActor
public enum EmptyDocScrollProbe {
    public static func run() {
        guard let tv = EditorTextView.live else {
            print("EMPTYDOC FAIL no live text view")
            return
        }
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        let used = tv.layoutManager!.usedRect(for: tv.textContainer!)
        let expected = used.height + tv.textContainerInset.height * 2
        let frameH = tv.frame.height
        let delta = frameH - expected
        print("EMPTYDOC frameH=\(frameH) expected=\(expected) delta=\(delta) minSize=\(tv.minSize)")
        print("EMPTYDOC \(abs(delta) < 1.0 ? "PASS" : "FAIL") frame shrinks with content")
    }
}
