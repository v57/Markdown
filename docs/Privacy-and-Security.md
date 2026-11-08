# Privacy and security

## What Markdown sends over the network

Markdown contacts no server on its own. It has no account of its own, no analytics and no tracking. GitHub is never
contacted when the app starts.

It connects only in these cases:

| When | To | What |
|---|---|---|
| iCloud is on (**Use iCloud**) | Apple's iCloud | Your notes, encrypted with your vault's key, and the vault's other records. Markdown syncs when it starts and when you bring it to the front. |
| You sign in to GitHub, open **Connect GitHub** while signed in, connect, pull or push a repository | GitHub | Your sign-in, the repository list, and the repository's Markdown files and images. |
| You click **Load Images** on a note | The servers in the note's image links | Requests for those images, without cookies. |
| You follow a web or mail link | Your browser or mail app | Markdown hands the link to that app. |
| You click **Download** for a translation (Mac: also **Settings ▸ Languages**) | GitHub | The translation files. |
| You choose **Check for Updates…**, or turn on **Check for Updates Automatically** (Mac app downloaded from GitHub) | GitHub | A check for the latest release, and the update if you install it. |

Turn iCloud off in **Settings ▸ Privacy** (Mac) or **Add (+) ▸ Privacy…** (iPhone and iPad). Your notes then stay on
this device. See [Sync and encryption](Sync-and-Encryption.md).

## Images from the web

A note can link to images on other servers. Loading one tells that server that the note was opened, and from where. So
Markdown doesn't load them until you ask.

A note with web images shows a bar: **This note's images from the web aren't loaded.** Click **Load Images** to load
them for that note. Markdown loads them without cookies.

Images stored next to the note, in its folder, always show. They don't use the network.

## Links

A link's text can hide where it leads. Markdown opens a link at once only when it's safe:

- `http`, `https` and `mailto` links open in your browser or mail app.
- Links to Markdown notes and folders open in Markdown.
- Links to programs, scripts and launchers never run. On the Mac, Markdown shows them in Finder instead. On iPhone and
  iPad they don't open.
- Every other link asks first: **Open this link?** or **Open “…”?**, with the full target and the app that would open
  it. Click **Open** to go ahead.

This covers other kinds of links, like `tel:`, `sms:`, `smb:` or `shortcuts:`, and files like PDFs and pictures.

## Encrypted notes

An encrypted note (`.mdenc`) is sealed with your vault's key. The key reaches your devices through iCloud Keychain.
Without it, the file is scrambled text: Finder, Files, other apps, iCloud and anyone you share the file with can't read
it.

- New notes in the notes folder are encrypted while **Encrypt New Notes** is on, as it is at first.
- On the Mac, **Open With** leaves Code out for an encrypted note.
- Notes in GitHub repositories and projects are plain files.

See [Sync and encryption](Sync-and-Encryption.md).

## Synced notes stay in the notes folder

A note's name can't take it out of its folder. Markdown turns slashes in a new note's name into dashes and drops leading dots, and
won't rename a note to a name with a `/` or a leading `.`. A synced note whose path would lead outside your notes folder
is refused, and nothing is written.

## Your GitHub sign-in

Markdown keeps your GitHub sign-in in the keychain. Your **Personal** account shares it with Git and Dev. Another vault
account keeps its own. **Sign Out** in the **Connect GitHub** sheet removes it.

Commit and Push never forces. It pulls first, so it doesn't overwrite changes made on GitHub.

## Deleting

- On the Mac, deleted notes and folders go to the Trash.
- On iPhone and iPad, Markdown asks first, and they go to **Recently Deleted** in the Files app.

You can get them back from either place. A new note you leave empty is deleted for good, since there's nothing in it.

## Files Markdown can reach

- On iPhone and iPad, Markdown reads its own notes folder, its repositories, and files you open with it from Files.
- On the Mac, the App Store version asks you to choose a folder before it opens it, and a failed save offers **Allow
  Editing…**. The version downloaded from GitHub opens your projects without asking.
