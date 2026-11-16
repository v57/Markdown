# Notes and folders

The sidebar shows where your notes live and lists the notes of the place you pick. This page covers creating,
renaming, pinning, moving and deleting notes and folders, files opened on their own, and the projects the v57 apps
share.

## The sidebar

The sidebar shows your places as cards:

- **On My Mac**, **On My iPhone** or **On My iPad**: your notes folder.
  - **All Notes** lists every note in the folder and its folders.
  - **Notes** lists the notes at the top of the folder.
  - Each folder shows how many notes it holds. A folder with folders inside has an arrow that opens and closes it.
- **GitHub**: the repositories you connected. See [GitHub repositories](GitHub-Repositories.md).
- **Projects** (Mac and Windows): the projects the v57 apps share. See [Shared projects](#shared-projects).
- **Files**: files you opened on their own, under **Opened Files**.
- **Search**: results while you search. See [Search and Quick Open](Search-and-Quick-Open.md).

Pick a place to list its notes right under it. Pinned notes come first.

Each note shows its first line as its name, and its second line under it. A leading heading, bullet or quote marker
(`#`, `-`, `>`) is left out, and a long first line is cut at 60 characters. A note whose first line is empty shows its
file name. Encrypted notes show their lines too, read on this device.

The sidebar's status at the bottom says **iCloud** when your notes sync, or **On This Mac** (iPhone, iPad) when they
stay on this device.

### Sort notes

Open the notes card's **Add** (+) menu and choose **Sort Notes By**:

- **Date Edited**: newest first.
- **Title**: in alphabetical order of the names the sidebar shows.

Pinned notes stay first either way. Markdown remembers your choice.

### A folder's README

Pick a folder while none of its notes is open, and the note pane shows the folder's README, titled with the folder's
name, as GitHub does. Markdown looks for a file named `README` (any Markdown extension, any case) in the folder, then
in its `.github` and `docs` folders. A link to a folder that has none shows **No README**.

## Create notes and folders

- **New Note** and **New Folder** in the sidebar's bottom bar make a note or a folder in the place you're looking at.
  Outside your folders, they use the notes folder. From the keyboard: **File ▸ New Note** (⌘N) and **New Folder**
  (⇧⌘N), Ctrl+N and Ctrl+Shift+N on Linux and Windows.
- The notes card's **Add** (+) menu has **New Note** and **New Folder** too, and **Add Sample Notes** (see
  [Getting started](Getting-Started.md#try-the-sample-notes)).
- A folder's menu (right-click on the Mac, touch and hold on iPhone and iPad) has **New Note** and **New Folder** for
  that folder.
- In a place with no notes, click or tap the **New Note** row.
- In Quick Open, type a name and pick **New Note “…”** to make a note with that name.

A new note is named "Untitled", then "Untitled 2" and so on. A new folder is named "New Folder", and Markdown asks
you to rename it at once.

In the notes folder, a new note is encrypted (`.mdenc`) while **Encrypt New Notes** is on. In a GitHub repository or a
project, new notes are plain `.md` files.

## Rename

- From a note's or folder's menu in the sidebar, choose **Rename…** and type the new name in the row. Press Return.
- From the note's **More** menu, choose **Rename…**. A prompt asks for the name.

Rename changes the note's file name. The field holds the name without `.md` or `.mdenc`, and the note keeps its
extension whatever you type. Leaving the name as it was renames nothing. The sidebar still names a note by its first
line, unless that line is empty. A name with a `/` or one that starts with a `.` can't be used. If the name is taken,
Markdown says **An item named “…” already exists there.**

Pins and recent notes follow a renamed note.

## Pin a note

Choose **Pin Note** from the note's menu in the sidebar or its **More** menu. A pinned note shows a pin and stays at the
top of its list. Choose **Unpin Note** to put it back in order.

## Move notes

Drag a note onto a folder in the sidebar to move it there. If the open note moves, it stays open. If the folder already
has a note with that name, the moved note gets a number ("Untitled 2").

Drag a file from Finder (Mac) or the Files app (iPad) onto a folder to copy it in.

## Share a note

Use the **Share** button in the note's toolbar, or **Share** in its sidebar menu, to send the note's file with the
system's share options. An encrypted note is shared as its `.mdenc` file, which only opens in Markdown or Shell with
your vault.

Markdown has no export to HTML or PDF.

## Files opened on their own

A Markdown file you open from Finder or Files that isn't in one of the sidebar's folders is listed under **Files ▸
Opened Files**. Markdown edits it where it is.

- To take it off the list, choose **Remove from List** from its menu. The file stays where it is.
- Images and links next to such a file may not load, because Markdown can only read the file you opened.
- When the file is inside one of your shared projects (Mac and Windows), the **More** menu offers **Open Project
  “…”…**. It opens the project in the sidebar, so the note's images and linked files work.

## On the Mac

### Delete notes and folders

Choose **Move to Trash** from the note's or folder's menu, or select notes and press Delete. They go to the Trash,
where you can get them back.

<!-- only: linux windows -->

On Linux and Windows, deleted notes and folders go to the trash (the Recycle Bin on Windows) without asking. On Linux
the menu item is **Delete…**, and on Windows it is **Delete…** for a folder.

<!-- /only -->

### Work with several notes

⌘-click or ⇧-click notes to select several. Right-click the selection to:

- **Pin 3 Notes** or **Unpin 3 Notes**
- **Encrypt 3 Notes** or **Decrypt 3 Notes**
- **Show in Finder**
- **Share**
- **Move 3 to Trash**

A note's or folder's menu also has **Show in Finder**, and a note's has **Open With**: Code or Finder. An encrypted
note leaves Code out, because Code would show scrambled text.

<!-- only: windows -->

On Windows, these say **Explorer** instead of Finder.

<!-- /only -->

<!-- only: linux -->

On Linux, the menus have no **Show in** or **Open With** item.

<!-- /only -->

### Shared projects

The sidebar's **Projects** card lists the projects you added in Code, Git and the other v57 apps. They come through
the vault, so every app shows the same list.

- Pick a project to open its folder in the sidebar, with its folders and notes. If Markdown hasn't opened it before, it
  may ask you to choose the folder once. **Open in Markdown…** in the project's menu does the same.
- A project's menu has **New Note**, **New Folder**, **Reload** and **Close Project**. **Close Project** closes it in
  the sidebar; its files stay.
- The project folder's menu has **Open With**: Code or Finder.
- **On Other Devices** lists the same folder on your other devices that one of your Hubs reaches. **Copy SSH Command
  for …** copies a command that opens a terminal in that folder there.
- **Remove from List** takes a project off Markdown's list only. Adding its folder again brings it back.

Drop a folder from Finder on the sidebar to open it. If it isn't one of your projects yet, Markdown offers to add it.
Markdown shows only the notes folder, GitHub repositories and shared projects, so a folder you don't add isn't listed.

To reread every folder from disk, choose **Reload** from a project's menu, or **Reload** in a note's **More** menu (⌘R).

<!-- only: linux -->

On Linux, the sidebar has no **Projects** card.

<!-- /only -->

## On iPhone and iPad

### Delete notes and folders

Choose **Delete…** from the note's or folder's menu. Markdown asks first. The note or folder goes to **Recently
Deleted** in the Files app, where you can get it back.

### Shared projects

The **Projects** card isn't on iPhone and iPad: a project's folder is on another device.

To reread every folder from disk, choose **Reload** in a note's **More** menu.
