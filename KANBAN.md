# KANBAN — Extract editor into Md package

Plan: .hermes/plans/2026-08-20_193042-extract-markdown-editor-into-md-package.md

## Columns

### To Do
- (none)

### In Progress
- [T1] MdCode target: Package.swift + Sources/MdCode/ (Agent A, wave 1)
- [T2] Md target: Sources/Md/ moves + @MainActor + app shell (Agent B, wave 1)

### Review (parent gate)
- [T3] swift build --target MdCode / --target Md green; files moved correctly

### Done
- (none)

## Waves
- Wave 1: A (MdCode+Package.swift) ∥ B (Md sources + app shell)
- Wave 2: C (MdTests + MdCodeTests + slim SelfTest)
- Wave 3: parent — xcodebuild + --selftest + commits
