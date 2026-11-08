# Sync and encryption

## How your notes sync

Your notes sync between your Mac, iPhone and iPad through iCloud, encrypted. They go through the vault that every v57
app shares, not through iCloud Drive. On each device, they are also plain files in the notes folder.

You need:

- the same Apple Account on each device, with iCloud and iCloud Keychain on;
- **Use iCloud** on in Markdown (it is at first).

Markdown syncs when it starts and each time you bring it to the front. It doesn't sync in the background. Make a note
on your iPhone, then bring Markdown forward on your Mac, and the note is there. While a note syncs, the line under its
title says **Synced** instead of **Saved**.

New notes, edits, new folders, renames, moves and deletes all sync.

Shell shows the same notes. See the [Shell guide](https://github.com/v57/Shell/blob/main/Docs/README.md).

Connected GitHub repositories don't sync this way. Each device keeps its own copy. See
[GitHub repositories](GitHub-Repositories.md).

### A note edited on two devices

If you edit the same note on two devices before they sync (for example, both offline), Markdown keeps both edits. It
merges the note line by line. Lines changed on both devices stay in the note between conflict markers, so you can pick
what to keep.

### Turn iCloud off

- **On the Mac**, open **Markdown ▸ Settings ▸ Privacy**.
- **On iPhone and iPad**, open the notes card's **Add** (+) menu and choose **Privacy…**.

Switch off **Use iCloud** and confirm with **Turn Off**. This applies to every v57 app on this device: they stop
syncing through iCloud and iCloud Keychain. What's already in iCloud stays, and your other devices keep it.

With iCloud off, the sidebar says **On This Mac** (iPhone, iPad) and **plain files**. Your notes stay on this device
only. Switch **Use iCloud** on again to sync.

### Notes from older versions

Earlier versions kept notes in Markdown's iCloud Drive folder. The first time a new version starts, Markdown copies
those notes into the notes folder once. The originals stay in iCloud Drive.

## Encrypted notes

An encrypted note is a `.mdenc` file. Its text is sealed with your vault's key, which your devices share through iCloud
Keychain. Markdown and Shell open it on any of your devices. Finder, Files, other apps and other people see only
scrambled text.

### Encrypt new notes

While **Encrypt New Notes** is on, new notes in the notes folder are encrypted. It's on at first.

- **On the Mac**, the **File** menu has **Encrypt New Notes**.
- On every device, the welcome's options have **Encrypt new notes**.

New notes in a GitHub repository or a project are always plain `.md` files.

### Encrypt or decrypt a note

Choose **Encrypt Note** from the note's menu in the sidebar or its **More** menu. The file becomes `.mdenc` and stays
open. Choose **Decrypt Note** to save it as plain text again. Pins follow the note.

On the Mac, select several notes and choose **Encrypt 3 Notes** or **Decrypt 3 Notes** to change them all.

### Open an encrypted file

Open a `.mdenc` file from Finder or the Files app, and Markdown shows it decrypted. A `.mdenc` file made with another
vault doesn't open: Markdown says **Couldn’t Open “…”** with the reason.
