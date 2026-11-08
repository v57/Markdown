# Writing and reading

## Live preview

Markdown styles your note as you type. Headings, **bold**, *italic*, ~~strikethrough~~, `code`, links, web addresses
and rules look finished. The Markdown symbols (`#`, `**`, `_` and so on) hide on every line except the one you're on.
Move the cursor to a line to see and edit its symbols.

What Markdown shows:

- Headings, in both `#` and underlined styles.
- Bulleted, numbered and nested lists. Wrapped lines line up under the item's text.
- Task lists with checkboxes.
- Quotes, including quotes with lists inside.
- Tables, as aligned grids.
- Fenced code blocks, with colours for the language.
- Images, links and horizontal rules.

The note follows your light or dark appearance.

On Windows and Linux, the editor shows the Markdown source, and **Read** shows the finished note.

## Lists, quotes and checkboxes

- Press Return in a list or quote to continue it. Numbered lists count up.
- Press Return on an empty item to end the list.
- Click or tap a checkbox to tick it. The note saves. On iPhone and iPad the keyboard stays down.

## Tables

A table shows as a grid. Click or tap into it to edit its Markdown. The toggle after the last header switches between
the grid and the source. When the window is too narrow for a table, it shows as source until there's room again.

## Code blocks

A fenced code block with a language (` ```swift `, ` ```json `, ` ```bash ` and others) is coloured like on GitHub. A
language Markdown doesn't know stays plain.

Each code block has a copy button. It copies exactly the block's code and shows that it copied.

## Format text

**On the Mac**, use the **Format** menu. It has:

- **Title**, **Heading**, **Subheading**
- **Bold**, **Italic**, **Strikethrough**, **Code**, **Add Link**
- **Checklist**, **Bulleted List**, **Numbered List**, **Block Quote**
- **Code Block**, **Table**
- **Toggle List**, **Toggle Checkbox**, **Toggle Checked Checkbox**, **Toggle Code**, **Toggle Note**, **Toggle
  Numbered List**

The toggles also sit in a bar under the editor while you edit. A toggle adds the mark to the selected lines, and
removes it when it's already there. **Toggle Note** makes a quote.

**On iPhone and iPad**, a formatting bar floats above the keyboard while you edit:

- **Text Style** (Aa) has **Title**, **Heading**, **Subheading**, **Bold**, **Italic**, **Strikethrough**, **Table**,
  **Code Block** and **Link**.
- The toggles for lists, checkboxes, code, quotes and numbered lists.
- **Hide Keyboard** puts the keyboard away.

The formatting works on the selected text or the lines it touches. See [Keyboard shortcuts](Keyboard-Shortcuts.md) for
the Format menu's shortcuts.

## Undo

Use **Edit ▸ Undo** (⌘Z) on the Mac. On iPhone and iPad, shake the device, swipe left with three fingers, or press ⌘Z
on a keyboard.

## Edit and Read

A note opens in **Edit**, where the line you're on shows its Markdown. **Read** hides every symbol, and a click or tap on
a link follows it.

- **On the Mac and iPad**, use the **Edit** / **Read** switch in the toolbar, or press ⇧⌘E. On the Mac, the **View**
  menu has **Edit Note** or **Read Note**.
- **On iPhone**, tap the eye button to read and the pencil button to edit.

Markdown remembers your choice for other notes and the next launch.

In **Read**, checkboxes and tables don't change, and code blocks still copy.

## Links

- A link to another note (`[Ideas](Ideas.md)`) opens that note in Markdown and shows it in the sidebar.
- A link to a heading (`[Setup](#setup)`, or `Other.md#setup`) scrolls to it.
- A link to a folder opens the folder's README.
- Web links (`http`, `https`) open in your browser. `mailto` links open a new mail.
- Any other link asks first. See [Privacy and security](Privacy-and-Security.md#links).

### Back and forward

After you follow links, go back and forward:

- **On the Mac and iPad**, use the ‹ and › buttons in the toolbar, or ⌘[ and ⌘].
- **On iPhone**, the note's **More** menu has **Back** and **Forward**.

## Images

- Images next to the note (`![](picture.png)`) show inside it, sized to fit.
- In a repository or project, a path that starts with `/` starts at its top folder.
- SVG images stay sharp. Animated GIFs play.
- If you replace an image file, choose **Reload** from the **More** menu to see the new one.
- Images from the web don't load until you ask. A bar says **This note's images from the web aren't loaded.** Click
  **Load Images** to load them for this note. See [Privacy and security](Privacy-and-Security.md#images-from-the-web).

## Saving

Markdown saves a note in place shortly after you stop typing. It also saves when you switch notes, leave the app or
quit.

The line under the note's title shows:

- where the note is,
- **Edited** while a change waits to be saved, then **Saved**, or **Synced** when the note syncs through iCloud,
- how many words the note has.

To save at once, choose **Save Now** from the **More** menu, or **File ▸ Save** (⌘S) on the Mac.

If a change can't be saved (for example, a file you may only read), a red **Not Saved** button appears. Click it to see
why. On the Mac, when a folder was opened read-only, **Allow Editing…** lets you choose the folder again so Markdown can
save.

If a note can't be opened, Markdown says **Couldn’t Open “…”** with the reason.

## The More menu

The **More** (…) button in the note's toolbar has:

- **Pin Note** or **Unpin Note**
- **Rename…**
- **Encrypt Note** or **Decrypt Note**
- **Open With** (Mac): Code or Finder
- **Open Project “…”…** (Mac, for a file inside a project you haven't opened)
- **Save Now**
- **Reload**: reads the folders and the note from disk again
- **Back** and **Forward** (iPhone)
