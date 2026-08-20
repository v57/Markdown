import AppKit

/// Draws the task-list checkbox. The layout manager renders this image in place of the
/// "[x]"/"[ ]" characters (which stay in the source string, marked .markdownCheckbox).
public enum CheckboxRenderer {
    public static func image(checked: Bool, size: CGFloat = 13) -> NSImage {
        let s = NSSize(width: size, height: size)
        return NSImage(size: s, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            if checked {
                NSColor.controlAccentColor.setFill()
                box.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: rect.minX + 3, y: rect.midY))
                check.line(to: NSPoint(x: rect.midX - 0.5, y: rect.minY + 3))
                check.line(to: NSPoint(x: rect.maxX - 2.5, y: rect.maxY - 3))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                box.lineWidth = 1.2
                box.stroke()
            }
            return true
        }
    }
}
