import MarkdownKit
import SwiftUI

/// What a window shows above its columns: Quick Open, the welcome sheet, the folder
/// picker. Shared by the sidebar, Quick Open and the menu bar.
@Observable final class WindowState {
  var isQuickOpenShown = false
  var isWelcomeShown = false
  var isAddingFolder = false
}

/// The shown document's commands, for the menu bar.
struct DocumentActions {
  var save: () -> Void
  var reload: () -> Void
  var toggleMode: () -> Void
  var isEditing: Bool
}

private struct WindowStateKey: FocusedValueKey { typealias Value = WindowState }
private struct DocumentActionsKey: FocusedValueKey { typealias Value = DocumentActions }
private struct EditorCommandsKey: FocusedValueKey { typealias Value = MarkdownEditorCommands }

extension FocusedValues {
  var windowState: WindowState? {
    get { self[WindowStateKey.self] }
    set { self[WindowStateKey.self] = newValue }
  }
  var documentActions: DocumentActions? {
    get { self[DocumentActionsKey.self] }
    set { self[DocumentActionsKey.self] = newValue }
  }
  /// Set while a note is open for editing: the Format menu applies to it.
  var editorCommands: MarkdownEditorCommands? {
    get { self[EditorCommandsKey.self] }
    set { self[EditorCommandsKey.self] = newValue }
  }
}

/// The menu bar: Quick Open and Save in File, Edit/Read and Reload in View, the Format
/// menu, and the welcome window under Window.
struct MarkdownCommands: Commands {
  @FocusedValue(\.windowState) private var window
  @FocusedValue(\.documentActions) private var document
  @FocusedValue(\.editorCommands) private var editor

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button("Quick Open…") { window?.isQuickOpenShown = true }
        .keyboardShortcut("k", modifiers: .command)
        .disabled(window == nil)
    }
    CommandGroup(replacing: .saveItem) {
      Button("Save") { document?.save() }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(document == nil)
    }
    CommandGroup(before: .sidebar) {
      Button(document?.isEditing == false ? "Edit Note" : "Read Note") { document?.toggleMode() }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(document == nil)
      Button("Reload") { document?.reload() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(document == nil)
      Divider()
    }
    CommandMenu("Format") {
      format("Title", .heading(1), "1", [.command, .option])
      format("Heading", .heading(2), "2", [.command, .option])
      format("Subheading", .heading(3), "3", [.command, .option])
      Divider()
      format("Bold", .bold, "b", .command)
      format("Italic", .italic, "i", .command)
      format("Strikethrough", .strikethrough, "x", [.command, .shift])
      format("Code", .inlineCode, "e", .command)
      format("Add Link", .link, "k", [.command, .shift])
      Divider()
      format("Checklist", .checklist, "l", [.command, .shift])
      format("Bulleted List", .bulletList, "7", [.command, .shift])
      format("Numbered List", .numberedList, "9", [.command, .shift])
      format("Block Quote", .quote, "'", .command)
      Divider()
      format("Code Block", .codeBlock, "c", [.command, .option])
      format("Table", .table, "t", [.command, .option])
    }
    CommandGroup(after: .windowArrangement) {
      Divider()
      Button("Welcome to Markdown") { window?.isWelcomeShown = true }
        .keyboardShortcut("1", modifiers: [.command, .shift])
        .disabled(window == nil)
    }
  }

  private func format(
    _ title: String, _ format: MarkdownFormat, _ key: KeyEquivalent, _ modifiers: EventModifiers
  ) -> some View {
    Button(title) { editor?.apply(format) }
      .keyboardShortcut(key, modifiers: modifiers)
      .disabled(editor == nil)
  }
}
