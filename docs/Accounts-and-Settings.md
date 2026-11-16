# Accounts and settings

Keep notes for someone you work for apart from your own with vault accounts, and find Markdown's few settings: iCloud,
accounts, Remote access, languages and updates.

## Vault accounts

Your notes belong to your **Personal** account at first. If you keep notes for someone you work for, you can add
another vault account. Each account has its own:

- notes folder, synced through its own vault,
- connected GitHub repositories and GitHub sign-in,
- pinned notes and recent notes,
- folders and projects in the sidebar.

Each window shows one account. On the Mac and iPad, two windows can show two accounts side by side.

Accounts sync through the vault, so an account made on one device shows on your others. You can also manage accounts
in the Vault app. See the [Vault guide](https://github.com/v57/Vault/blob/main/docs/README.md).

### Switch accounts

With two or more accounts, the account picker shows at the top of the sidebar. Pick an account, and the window shows
its notes. With only **Personal**, the picker is hidden.

- **New Account…** in the picker adds an account.
- **Manage Accounts…** opens **Settings ▸ Accounts** on the Mac, or the **Accounts** sheet elsewhere.
- On the Mac, or an iPad with a keyboard, press ⌃⌘1 to ⌃⌘9 to switch to an account.

## Languages

Markdown comes in English and a few languages. If your device uses a language Markdown doesn't include, Markdown asks
once, shortly after it opens: **Show Markdown in …?** Click **Download** to get the translation from GitHub. If the
download fails, Markdown says **Couldn't Download the Translation**.

Nothing is downloaded unless you ask.

## On the Mac

### Settings

Choose **Markdown ▸ Settings…** (⌘,). The panes are:

- **Privacy**: **Use iCloud**, for every v57 app on this Mac. See [Sync and encryption](Sync-and-Encryption.md).
- **Accounts**: your vault accounts. **New Account…** adds one.
- **Remote**: which of your devices may sign in to this Mac over SSH. It's the same pane in every v57 app. See the
  [Vault guide](https://github.com/v57/Vault/blob/main/docs/README.md).
- **Languages**: the app's languages and translations you can download or update later.

<!-- only: linux windows -->

On Linux and Windows, Markdown has no Settings window. iCloud isn't there, **Manage Accounts…** in the account picker
opens the **Accounts** sheet, and the language question above is the only language setting.

<!-- /only -->

### Updates

The Mac app you download from GitHub can update itself. In the **Markdown** menu:

- **Check for Updates…** checks GitHub for a new version now.
- **Check for Updates Automatically** checks once a day. It's off until you turn it on.

When there's a new version, Markdown shows it with **Skip This Version**, **Remind Me Later** and **Install Update**.
Markdown downloads the update, checks its signature, and offers **Install and Relaunch**.

<!-- only: windows -->

On Windows, both commands are in the **Help** menu.

<!-- /only -->

<!-- only: linux -->

On Linux, Markdown doesn't update itself. Download a new version from
[Markdown's releases on GitHub](https://github.com/v57/Markdown/releases).

<!-- /only -->

## On iPhone and iPad

### Settings

There is no Settings screen in the app:

- **Privacy…** is in the notes card's **Add** (+) menu. It has **Use iCloud**, for every v57 app on this device.
- **Manage Accounts…** is in the account picker. It opens the **Accounts** sheet.
- The app's language is in the system's **Settings ▸ Apps ▸ Markdown ▸ Language**.
