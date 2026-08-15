import Foundation

enum SampleDocument {
    static let text = """
    # Markdown Editor

    A **live-preview** markdown editor built on *AppKit* `NSTextView`. The markdown
    symbols only appear on the line you're editing — in the ~~tertiary~~ **tertiary color**,
    just like Obsidian. Here's a [link to Apple](https://www.apple.com).

    ## Features

    - Headings, **bold**, *italic*, ***both***, ~~strikethrough~~, and `inline code`
    - Bullet and numbered lists, nested lists, and task lists
    - Blockquotes, fenced code blocks, tables, and horizontal rules

    ### Task list

    - [x] Renders checkboxes inline
    - [ ] Hides syntax symbols on inactive lines
    - [ ] Looks good in dark mode

    > This is a blockquote. The `>` marker hides when you edit another line.

    ```swift
    let greeting = "Hello from the code block"
    print(greeting)   // no syntax highlighting needed
    ```

    | Feature | Status |
    |---------|--------|
    | Headings | ✅ |
    | Tables | ✅ |

    ---

    1. Numbered items work too
    2. With nesting:
       1. like this

    Click the link above, tick a checkbox, or edit any line to see its symbols appear.
    Escape example: \\*not italic\\*.
    """
}
