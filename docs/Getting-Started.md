# Getting started

Install Markdown, write your first note and find your way around. Your notes are plain Markdown files in a folder on
your device, and the sidebar shows where they are.

## On the Mac

### Install

<!-- only: mac -->

Download **Markdown.dmg** or **Markdown.zip** from
[Markdown's releases on GitHub](https://github.com/v57/Markdown/releases) and move **Markdown** to your Applications
folder. It needs macOS 14 or later on a Mac with Apple silicon.

<!-- /only -->

<!-- only: linux -->

On Linux, download **Markdown-Linux-x64.tar.gz** or **Markdown-Linux-arm64.tar.gz**, whichever matches your computer,
from [Markdown's releases on GitHub](https://github.com/v57/Markdown/releases). It holds the app's folder, with a
`.desktop` file and its icon, made to go in `/opt/Markdown`.

<!-- /only -->

<!-- only: windows -->

On Windows, download **Markdown-Windows-x64.zip** or **Markdown-Windows-arm64.zip** from
[Markdown's releases on GitHub](https://github.com/v57/Markdown/releases), unzip it and open **Markdown** from the
folder.

<!-- /only -->

### The window

Markdown has two parts:

- **The sidebar** lists where your notes live: **All Notes**, your notes folder and its folders, connected GitHub
  repositories, files you opened on their own, and the projects the v57 apps share. Right under the place you picked,
  it lists that place's notes.
- **The note pane** shows the note you picked. With no note picked, it shows the folder's README, or the welcome.

<!-- only: mac -->

You can open more windows with **File ▸ New Window**. Each window keeps its own vault account and its own place.

<!-- /only -->

<!-- only: linux windows -->

On Linux and Windows, the shortcuts written with ⌘ in this guide use Ctrl: Ctrl+K for Quick Open, Ctrl+Shift+N for
New Folder. Markdown has no Settings window there, and the sidebar lists shared projects on Windows only.

<!-- /only -->

### Where your notes are kept

Your notes are files in a folder on your computer. The sidebar's first card is that folder, **On My Mac**. Its line
says how many notes there are and whether they sync through **iCloud** or stay as **plain files** on this computer.

<!-- only: mac windows -->

Open the card's **Add** (+) menu and choose **Show Notes Folder in Finder** (**in Explorer** on Windows) to see the
files. To keep your notes somewhere else, choose **Choose Notes Folder…** and pick a folder. Markdown writes your notes
there and keeps them in sync with it. The old folder keeps its files.

<!-- /only -->

<!-- only: linux windows -->

On Linux and Windows, iCloud isn't there: the card says **plain files**, and your notes stay on this computer. On
Linux, the notes folder stays where Markdown keeps it; the card's menu has no command to show or change it.

<!-- /only -->

### Open a Markdown file from elsewhere

Drag any Markdown or plain-text file onto the sidebar to open it. On the Mac you can also open it from Finder with
**Open With ▸ Markdown**. Markdown edits the file where it is. A file inside one of the sidebar's folders shows in its folder. Any other file is listed
under **Files ▸ Opened Files**. See [Notes and folders](Notes-and-Folders.md).

## On iPhone and iPad

### The window

Markdown has two parts:

- **The sidebar** lists where your notes live: **All Notes**, your notes folder and its folders, connected GitHub
  repositories and files you opened on their own. Right under the place you picked, it lists that place's notes.
- **The note pane** shows the note you picked. With no note picked, it shows the folder's README, or the welcome.

On iPhone, a note opens over the sidebar. Tap **Back** to return to the sidebar.

On iPad, the sidebar and the note sit side by side. Use the sidebar toggle in the sidebar's bottom bar to hide or show
the sidebar.

### Where your notes are kept

Your notes are files in a folder on your device. The sidebar's first card is that folder, **On My iPhone** or **On My
iPad**. Its line says how many notes there are and whether they sync through **iCloud** or stay as **plain files** on
this device.

The notes folder is in the Files app at **On My iPhone ▸ Markdown** (or **On My iPad ▸ Markdown**). Notes you add or
change there show up in Markdown.

### Open a Markdown file from elsewhere

Open any Markdown or plain-text file from the Files app with **Share ▸ Markdown** or **Open With**. On iPad you can also
drag it from Files onto the sidebar or the welcome. Markdown edits the file where it is. A file inside one of the
sidebar's folders shows in its folder. Any other file is listed under **Files ▸ Opened Files**. See
[Notes and folders](Notes-and-Folders.md).

## The welcome

The welcome shows when no note is open. It has:

- **New Note**: makes a note and opens it.
- **Quick Open…**: finds a note by its name or by what it says.
- **Add Sample Notes**: adds a folder of example notes to read and edit. See
  [Try the sample notes](#try-the-sample-notes).
- A list of up to eight notes you opened recently. With none yet, it says **No Recent Notes**.
- An option, **Encrypt new notes**, which is on at first. See [Sync and encryption](Sync-and-Encryption.md).

To show it again, choose **Window ▸ Welcome to Markdown** (⇧⌘1), or open Quick Open and pick **Welcome to Markdown**.

## Write your first note

1. Click **New Note** in the sidebar's bottom bar (or on the welcome).
2. A note named "Untitled" opens with the cursor in it. Start typing.
3. Markdown saves as you type. You don't need to save.

The sidebar names a note by its first line, and shows its second line under it. A heading, bullet or quote marker at
the start of a line is left out. A note whose first line is empty shows its file name. To change the file's name,
choose **Rename…** from the note's **More** menu or from its row in the sidebar.

A new note that you leave empty is removed when you move on to another note, unless you pinned it.

## Try the sample notes

To see what Markdown does before writing notes of your own, choose **Add Sample Notes**: on the welcome, in the notes
card's **Add** (+) menu, or in the notes card itself while you have no notes (on iPhone, the sidebar is the first
screen). Markdown adds a **Sample Notes** folder to your notes folder and opens its **Start Here** note, which lists
things to try. The folder also holds a trip plan with a table and tasks, a reading list, ideas, meeting notes, and a
few documentation notes with code and links between them.

They are plain `.md` notes. They sync like any other note when iCloud is on, and you remove them by deleting the
folder.

## Plain files

Because notes are plain files, other editors, your file manager and git can work on them too. Markdown notices changes
made outside the app and updates the sidebar and the open note.

Encrypted notes (`.mdenc`) are the exception: other apps see only scrambled text. See
[Sync and encryption](Sync-and-Encryption.md).

## Next

- [Notes and folders](Notes-and-Folders.md)
- [Writing and reading](Writing-and-Reading.md)
- [Keyboard shortcuts](Keyboard-Shortcuts.md)
