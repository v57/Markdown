# KANBAN — Add iOS support to Md (UIKit alternative)

Plan: .hermes/plans/2026-08-20_204833-ios-support-UIKit-alternative.md

## Columns

### To Do
- (none — all waves dispatched)

### In Progress
- [W1A] MdCode: hex CodeColorScheme (no AppKit) — keeps package green (Agent A)
- [W1B] MdCore: EditorLayoutManagerCore extraction + AppKit subclass; owns Package.swift (Agent B)
- [W2] MdCore: style spec (MarkdownColor/Font/Paragraph + MarkdownStyling) + moves (Agent C)
- [W3] MdCore: MarkdownParser de-AppKit + MarkdownRenderer + MdTests/MdCoreTests (Agent D)
- [W4] MdUIKit: UIKit editor stack (Agent E)

### Review (parent gate)
- (wave results pending)

### Done
- (none)

## Waves
- Wave 1: A (MdCode hex) ∥ B (layout core + Package.swift)
- Wave 2: C (style-spec scaffolding)
- Wave 3: D (parser de-AppKit + renderer + tests)
- Wave 4: E (MdUIKit stack)
- Wave 5: parent — iOS build verify, demo app, README, final gate, commits
