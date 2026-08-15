import AppKit

final class EditorLayoutManager: NSLayoutManager {
    /// Lines that are "active" (contain the selection/caret). Syntax glyphs outside this range are not drawn.
    var activeCharacterRange: NSRange = NSRange(location: 0, length: 0)
}
