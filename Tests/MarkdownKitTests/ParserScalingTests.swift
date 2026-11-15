#if canImport(AppKit)
  import Foundation
  import Testing
  @testable import MarkdownKit

  /// A long note parses in time proportional to its length: each line's block and list item were found by scanning
  /// every block and item, so a 3.5 MB note held the main thread for 86 s as it opened.
  @Suite struct ParserScalingTests {
    /// `count` sections of a heading, a paragraph with inline markup, a nested list and a fenced block.
    private func note(sections count: Int) -> String {
      (0..<count).map { i in
        """
        ## Section \(i)

        Some *emphasis* and **bold** text with `code \(i)` and a [link](https://example.invalid/\(i)).

        - item one \(i)
          - nested \(i)
        - item two

        ```swift
        let x\(i) = \(i)
        ```

        """
      }.joined(separator: "\n")
    }

    private func parseTime(sections: Int) -> Duration {
      let text = note(sections: sections)
      let clock = ContinuousClock()
      return clock.measure { _ = MarkdownParser.parse(text) }
    }

    @Test func longNotesParseInLinearTime() {
      _ = parseTime(sections: 200)  // warm up
      let small = parseTime(sections: 1000)
      let large = parseTime(sections: 4000)
      // Four times the text: about four times the time (quadratic was sixteen).
      #expect(large < small * 8, "1000 sections \(small), 4000 sections \(large)")
    }
  }
#endif
