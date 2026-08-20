# KANBAN — Add iOS support to Md (UIKit alternative)

Plan: .hermes/plans/2026-08-20_204833-ios-support-UIKit-alternative.md

## Columns

### To Do
- (none)

### In Progress
- (none)

### Review (parent gate)
- iOS on-simulator test RUN blocked by Xcode SwiftPM test-host plumbing in the
  app-project setup (compile-verified: MdUIKitTests bundle TEST BUILD SUCCEEDED;
  runtime-gated by the 48 macOS tests on shared logic).

### Done
- [W1A] MdCode: hex CodeColorScheme (no AppKit) — package green
- [W1B] MdCore: EditorLayoutManagerCore extraction + AppKit subclass + Package.swift
- [W1C] MdCore: style spec (MarkdownColor/Font/Paragraph + MarkdownStyling) + moves
- [W2] MdCore: MarkdownParser de-AppKit + MarkdownRenderer + MdCoreTests (48 tests green)
- [W3A] MdUIKit: plumbing (style, layout drawing, checkbox/image/color)
- [W3B] MdUIKit: editor (EditorTextView, MarkdownEditorViewController, SwiftUI wrapper)
- [W4] MdUIKit target + MdUIKitTests (iOS build clean; macOS suite green)
- [W5] README + macOS app build + selftest + final gate (all green, 4 commits)

## Waves
- Wave 1: A (MdCode hex) ∥ B (layout core + Package.swift; B failed HTTP 524, parent took over) ∥ C (style-spec)
- Wave 2: D (parser de-AppKit + renderer + tests) — parent-implemented
- Wave 3: E (MdUIKit plumbing) ∥ F (MdUIKit editor; F hit iteration budget, parent wrote the 3 editor files)
- Wave 4: parent — MdUIKit target, MdUIKitTests, README, final gate, commits
