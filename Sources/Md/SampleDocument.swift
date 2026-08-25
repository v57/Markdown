import Foundation

public enum SampleDocument {
  public static let text = """
    Hello World
    # H1
    Hello World
    ###### H6
    Hello World
    Body **Body** *Body* ***Body*** ~~Body~~ [Link](https://www.apple.com)

    Hello `code`

    ---

    - List
    1. A
    2. B
       1. B2
    - [x] Renders checkboxes inline
    - [ ] Hides syntax symbols on inactive lines
    > Quote
    > Second one

    ```swift
    let a = 10
    print("Hello World")
    ```

    | Feature | Status |
    |---------|--------|
    | Headings | ✅ |
    | Tables | ✅ |
    """
}
