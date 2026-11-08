# Markdown user guide

Markdown is a notes app. Your notes are plain Markdown files in a folder, and they look finished while you write them:
the Markdown symbols hide when you leave a line and come back when you edit it. Notes sync between your devices through
iCloud, encrypted. You can also connect a GitHub repository and edit its Markdown files without installing git.

## Platforms

- **Mac:** the full app, with a menu bar, a Settings window and keyboard shortcuts.
- **iPhone:** the same notes, places and editor. Notes open over the sidebar, and a formatting bar sits above the
  keyboard.
- **iPad:** the sidebar and the note side by side. With a hardware keyboard, the Mac's shortcuts work too.
- **Windows and Linux:** Markdown also builds there. The editor shows the Markdown source with the same formatting
  commands, and **Read** shows the finished note. The live preview is on Mac, iPhone and iPad only. iCloud sync is only
  on Apple devices.

The guide notes where a feature works differently on a platform.

## Pages

- [Getting started](Getting-Started.md): the window, your first note, and where notes are kept.
- [Notes and folders](Notes-and-Folders.md): the sidebar, creating, renaming, pinning, moving and deleting notes, files
  opened on their own, and shared projects on the Mac.
- [Writing and reading](Writing-and-Reading.md): the editor, formatting, tables, code, images, links, Edit and Read,
  and saving.
- [Search and Quick Open](Search-and-Quick-Open.md): finding notes by name or by what they say.
- [Sync and encryption](Sync-and-Encryption.md): iCloud sync, encrypted notes, and notes edited on two devices.
- [GitHub repositories](GitHub-Repositories.md): connecting a repository, pulling, and committing and pushing.
- [Accounts and settings](Accounts-and-Settings.md): vault accounts, Settings, languages and updates.
- [Privacy and security](Privacy-and-Security.md): what Markdown sends over the network, web images, links and
  encrypted notes.
- [Keyboard shortcuts](Keyboard-Shortcuts.md): every shortcut on the Mac and on an iPad keyboard.

## Works with other v57 apps

- **Vault:** your notes sync through the vault every v57 app shares. Encrypted notes are sealed with the vault's key.
  The Mac's **Settings ▸ Remote** pane and your vault accounts come from Vault. See the
  [Vault guide](https://github.com/v57/Vault/blob/main/docs/README.md).
- **Shell:** Shell shows the same notes, encrypted ones included. See the
  [Shell guide](https://github.com/v57/Shell/blob/main/Docs/README.md).
- **Git:** Markdown uses the same GitHub sign-in as Git (and Dev). Sign in once in either app. See the
  [Git guide](https://github.com/v57/Git/blob/main/docs/README.md).
- **Code:** on the Mac, **Open With** offers Code for a note or a project folder. The projects Code and Git add show in
  Markdown's sidebar. See the [Code guide](https://github.com/v57/Code/blob/main/docs/README.md).

## For developers

The editor is the `MarkdownKit` library, which other apps can embed: see [MarkdownKit](MarkdownKit.md) and the
[README](../README.md#libraries).

## Network

Markdown contacts no server on its own. It syncs your notes through iCloud when iCloud is on, and it talks to GitHub
only when you sign in, connect a repository, pull or push. Images from the web load only when you ask for them.
[Privacy and security](Privacy-and-Security.md) lists every connection.
