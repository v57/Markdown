import Foundation

/// One language configuration for the regex-based code scanner: comment and string
/// forms, keyword sets, declaration patterns, and preprocessor conventions.
struct LanguageSpec {
    /// Canonical display name, e.g. "Swift".
    let name: String
    /// Fence info-string aliases, lowercased, e.g. ["swift"] or ["js", "javascript"].
    let aliases: [String]

    /// Line comment markers, e.g. ["//"] for the C family, ["#"] for Python/Shell.
    var lineComments: [String] = []
    /// Block comment pairs, e.g. [("/*", "*/")]. Checked BEFORE line comments so
    /// Lua's "--[[ ... ]]" wins over "--".
    var blockComments: [(open: String, close: String)] = []
    /// Whether block comments nest (Swift: /* /* */ */). Non-nesting languages
    /// close at the first close marker.
    var nestedBlockComments = false

    /// String literal forms (longest open is tried first at scan time).
    var strings: [StringDelim] = []
    /// Character literal delimiter (C family "'"). Needs a close on the SAME line;
    /// a lone apostrophe (Rust lifetimes 'a) stays plain text.
    var charLiteral: Character? = nil

    /// Reserved words. Case-sensitive unless `keywordsCaseInsensitive` (SQL).
    var keywords: Set<String> = []
    /// Match keywords case-insensitively (SQL is conventionally uppercased).
    var keywordsCaseInsensitive = false
    /// Declaration keywords and the kind their following name gets:
    /// "class" → .typeDeclaration, "func" → .memberDeclaration, ...
    var declKeywords: [String: SyntaxKind] = [:]

    /// '#'-directives (`#include`, `#if`, `#region`). `hashDirectivesAnchored`
    /// requires the directive to start the line (C family); free-standing matches
    /// any `#word` (Swift's `#available`, `#selector`, `#if`).
    var hashDirectives = false
    var hashDirectivesAnchored = true
    /// '@'-words (`@available`, `@interface`, `@Override`) → preprocessor.
    var atWords = false
    /// Rust attributes `#[...]` / `#![...]` → preprocessor.
    var rustAttributes = false

    /// Capitalized identifiers are type references (Swift/Java/C#/Kotlin/...).
    var capitalizedIsType = false
    /// `$name` / `${name}` are variables (Shell/PHP/Perl/Ruby/PowerShell).
    var shellVars = false
    /// `.name` accesses are otherMembers. Off for C/C++ where header names
    /// (`#include <stdio.h>`) and struct fields would produce noise.
    var memberAccess = true
    /// After a #include/#import directive, `<header.h>` contents are strings
    /// (GitHub colors header names as strings). C family only.
    var headerStrings = false
}

/// A quoted string form. `open`/`close` are usually equal ("\""), but differ for
/// raw strings (Swift #"..."#, Rust r#"..."#, C# @"..."). `escape` is the
/// character that escapes the next character inside the string (nil = raw).
struct StringDelim {
    let open: String
    let close: String
    let escape: Character?
    let multiline: Bool   // may span lines (Swift """...""", JS `...`, Go `...`)

    init(open: String, close: String? = nil, escape: Character? = "\\", multiline: Bool = false) {
        self.open = open
        self.close = close ?? open
        self.escape = escape
        self.multiline = multiline
    }
}