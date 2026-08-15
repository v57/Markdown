import AppKit

// MARK: - Self-test harness (CLI-verifiable TDD: `Markdown --selftest`)

enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    static func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passed += 1
            print("  PASS \(name)")
        } else {
            failed += 1
            print("  FAIL \(name) \(detail)")
        }
    }

    static func runAndExit() -> Never {
        print("SELFTEST START")
        check("empty doc parses", MarkdownParser.parse("", style: .standard).blocks.isEmpty)
        let sample = MarkdownParser.parse(SampleDocument.text, style: .standard)
        check("sample doc parses without crash", sample.attributed.length >= 0)
        print("SELFTEST \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

// MARK: - Smoke mode (launch, log, self-quit)

enum SmokeTest {
    static func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("SMOKE OK")
            NSApp.terminate(nil)
        }
    }
}
