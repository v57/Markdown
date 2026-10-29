import ComponentKit
import SwiftUI

extension View {
  /// Tells something that needs only an OK (an error, a result) as a kit sheet: over the window on the Mac and iPad,
  /// a system sheet on iPhone. Shown while `message` holds text; OK (Return) or Escape clears it. `extra` adds one more
  /// button before OK ("Allow Editing…").
  func notice(
    _ title: String, message: Binding<String?>, systemImage: String = "exclamationmark.triangle", hue: Hue = .orange,
    extra: NoticeButton? = nil
  ) -> some View {
    kitSheet(isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
      KitSheet(title: title, meta: message.wrappedValue, systemImage: systemImage, hue: hue, width: 400) {
        EmptyView()
      } footer: {
        if let extra {
          Button(extra.title) {
            message.wrappedValue = nil
            extra.action()
          }
        }
        Button("OK") { message.wrappedValue = nil }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
      }
    }
  }
}

/// A notice's second button.
struct NoticeButton {
  var title: String
  var action: () -> Void
}
