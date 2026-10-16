import SwiftUI

extension ToolbarContent {
  /// The kit's toolbar views (`KitTitle`, `ToolGroup`, `KitSegmented`) draw their own cards, so the toolbar's own
  /// Liquid Glass capsule doesn't go behind them.
  @ToolbarContentBuilder func kitBare() -> some ToolbarContent {
    if #available(macOS 26, iOS 26, *) {
      sharedBackgroundVisibility(.hidden)
    } else {
      self
    }
  }
}
