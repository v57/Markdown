#if canImport(UIKit)
import UIKit

/// Draws the task-list checkbox. The layout manager renders this image in place
/// of the "[x]"/"[ ]" characters (which stay in the source string, marked
/// .markdownCheckbox). Mirrors `Sources/Md/CheckboxAttachment.swift` (AppKit).
public enum CheckboxRenderer {
    public static func image(checked: Bool, size: CGFloat = 13) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let box = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3)
            if checked {
                UIColor.tintColor.setFill()
                box.fill()
                let check = UIBezierPath()
                check.move(to: CGPoint(x: rect.minX + 3, y: rect.midY))
                check.addLine(to: CGPoint(x: rect.midX - 0.5, y: rect.minY + 3))
                check.addLine(to: CGPoint(x: rect.maxX - 2.5, y: rect.maxY - 3))
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                UIColor.white.setStroke()
                check.stroke()
            } else {
                UIColor.secondaryLabel.setStroke()
                box.lineWidth = 1.2
                box.stroke()
            }
        }
    }
}
#endif
