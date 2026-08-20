import AppKit

/// A code color scheme: one `NSColor` per Xcode-style syntax category.
///
/// Defaults are GitHub's official Light / Dark code themes (primer
/// github-syntax-theme-generator, lib/themes/light.json and dark.json — the
/// classic editor palette that powers github.com code rendering).
public struct CodeColorScheme {
    public var plainText: NSColor
    public var comment: NSColor
    public var prose: NSColor
    public var keyword: NSColor
    public var string: NSColor
    public var number: NSColor
    public var link: NSColor
    public var preprocessor: NSColor
    public var typeDeclaration: NSColor
    public var memberDeclaration: NSColor
    public var projectType: NSColor
    public var projectMember: NSColor
    public var otherType: NSColor
    public var otherMember: NSColor

    public init(
        plainText: NSColor,
        comment: NSColor,
        prose: NSColor,
        keyword: NSColor,
        string: NSColor,
        number: NSColor,
        link: NSColor,
        preprocessor: NSColor,
        typeDeclaration: NSColor,
        memberDeclaration: NSColor,
        projectType: NSColor,
        projectMember: NSColor,
        otherType: NSColor,
        otherMember: NSColor
    ) {
        self.plainText = plainText
        self.comment = comment
        self.prose = prose
        self.keyword = keyword
        self.string = string
        self.number = number
        self.link = link
        self.preprocessor = preprocessor
        self.typeDeclaration = typeDeclaration
        self.memberDeclaration = memberDeclaration
        self.projectType = projectType
        self.projectMember = projectMember
        self.otherType = otherType
        self.otherMember = otherMember
    }

    public func color(for kind: SyntaxKind) -> NSColor {
        switch kind {
        case .plainText: return plainText
        case .comment: return comment
        case .prose: return prose
        case .keyword: return keyword
        case .string: return string
        case .number: return number
        case .link: return link
        case .preprocessor: return preprocessor
        case .typeDeclaration: return typeDeclaration
        case .memberDeclaration: return memberDeclaration
        case .projectType: return projectType
        case .projectMember: return projectMember
        case .otherType: return otherType
        case .otherMember: return otherMember
        }
    }

    // MARK: - GitHub default schemes

    /// GitHub Light code theme (primer lib/themes/light.json).
    /// Plain #24292e · Comment #6a737d · Keyword #d73a49 · String #032f62 ·
    /// Constant (numbers) #005cc5 · Entity (types) #6f42c1 · Variable #e36209 ·
    /// Link #032f62 · Preprocessor (keyword) #d73a49.
    public nonisolated(unsafe) static let githubLight = CodeColorScheme(
        plainText: .hex("24292e"),
        comment: .hex("6a737d"),
        prose: .hex("24292e"),
        keyword: .hex("d73a49"),
        string: .hex("032f62"),
        number: .hex("005cc5"),
        link: .hex("032f62"),
        preprocessor: .hex("d73a49"),
        typeDeclaration: .hex("6f42c1"),
        memberDeclaration: .hex("6f42c1"),
        projectType: .hex("6f42c1"),
        projectMember: .hex("e36209"),
        otherType: .hex("6f42c1"),
        otherMember: .hex("e36209"))

    /// GitHub Dark code theme (primer lib/themes/dark.json).
    /// Plain #f6f8fa · Comment #959da5 · Keyword #ea4a5a · String #79b8ff ·
    /// Constant (numbers) #c8e1ff · Entity (types) #b392f0 · Variable #fb8532 ·
    /// Link #79b8ff · Preprocessor (keyword) #ea4a5a.
    public nonisolated(unsafe) static let githubDark = CodeColorScheme(
        plainText: .hex("f6f8fa"),
        comment: .hex("959da5"),
        prose: .hex("f6f8fa"),
        keyword: .hex("ea4a5a"),
        string: .hex("79b8ff"),
        number: .hex("c8e1ff"),
        link: .hex("79b8ff"),
        preprocessor: .hex("ea4a5a"),
        typeDeclaration: .hex("b392f0"),
        memberDeclaration: .hex("b392f0"),
        projectType: .hex("b392f0"),
        projectMember: .hex("fb8532"),
        otherType: .hex("b392f0"),
        otherMember: .hex("fb8532"))

    /// Resolves the scheme from the current app appearance: dark → GitHub Dark,
    /// otherwise GitHub Light. Resolved afresh on every parse, so an appearance
    /// switch re-applies the matching palette on the next restyle.
    /// Uses `NSAppearance.currentDrawing()` (not `NSApp.effectiveAppearance`) so the
    /// scheme can be resolved from a nonisolated context (the parser is not
    /// MainActor-isolated).
    public static var systemAware: CodeColorScheme {
        if NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return .githubDark
        }
        return .githubLight
    }
}

public extension NSColor {
    /// sRGB color from a 6-digit hex string ("24292e").
    static func hex(_ hex: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255
        let g = CGFloat((v >> 8) & 0xFF) / 255
        let b = CGFloat(v & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
