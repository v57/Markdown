# GitHub repositories

Connect a GitHub repository to edit its Markdown files in Markdown and push your changes back. You don't need git
installed.

Markdown downloads only a repository's Markdown files and their images. It keeps them on this device, in Markdown's
own data, not in your notes folder. Connect the repository on each device where you want it.

## Open Connect GitHub

Open the notes card's **Add** (+) menu and choose **Connect GitHub Repository…**. With a repository connected, the
**GitHub** card's + button opens it too.

The **Connect GitHub** sheet has your **Account**, **Your Repositories** once you're signed in, and **Any Public
Repository**.

## Sign in with GitHub

Signing in lets you edit your repositories, private ones included, and push changes.

1. Click **Sign In with GitHub…**. The **Sign in to GitHub** sheet lists what Markdown asks GitHub for.
2. Click **Continue on GitHub**. Markdown shows a code, copies it, and opens GitHub's device page in your browser.
3. Paste the code there and approve Markdown. If you closed the page, use **Open GitHub Again**.
4. When GitHub confirms, the sheet says **Connected as …**, and the **Account** card shows your GitHub name.

The sign-in is shared with Git and Dev. If you already signed in in one of them with the same iCloud Keychain, Markdown
is signed in too. If another of your vault accounts is signed in, the sheet offers **Use @name** so you don't have to
sign in again.

To sign out, click **Sign Out** in the **Account** card.

## Connect one of your repositories

Once you're signed in, **Your Repositories** lists them. Use **Filter your repositories** to find one. A lock marks a
private repository. Repositories you already connected are ticked.

Click a repository. Markdown shows **Downloading…**, closes the sheet, and adds the repository to the sidebar's
**GitHub** card with its README.

## Add a public repository without signing in

In **Any Public Repository**, type `owner/repository` or a github.com address, and click **Add**. Markdown adds the
repository to read and edit here. To push changes, you need to sign in, and push access to the repository.

If the repository is already connected, Markdown says **Already Connected**. If it can't be reached, it says
**Couldn’t Connect …** with the reason.

## Edit and see your changes

Edit the repository's notes as you edit any note. New notes in a repository are plain `.md` files.

The **GitHub** card's line shows how many repositories you connected and how many changes are waiting to be pushed
("2 to push"). Each repository's row shows its own count. A spinner shows while Markdown pulls or pushes.

## Pull

Choose **Pull** from the repository's menu to get GitHub's latest files. Markdown says **Already up to date.** or
**Updated 3 files.**, and the open note reloads.

Markdown never pulls on its own.

If a file changed both here and on GitHub, Markdown says **Changed Here and on GitHub**. Your version is kept, and
GitHub's is saved next to it as "Name (GitHub).md". Merge them, delete the "(GitHub)" copy, then push.

## Commit and push

1. Choose **Commit and Push…** from the repository's menu.
2. The prompt lists your changes (added, changed and deleted files). Type a message, or keep the one Markdown suggests,
   like "Update Ideas.md".
3. Click **Push**.

Markdown pulls first, then writes one commit and moves the branch forward. It never forces a push. It says **Pushed 3
changes to main.**, or **Nothing to commit.**

Without a sign-in, Markdown says **Sign In to Push**.

## Open on GitHub

Choose **Open on GitHub** from the repository's menu to open it in your browser.

## Disconnect

Choose **Disconnect…** from the repository's menu and confirm with **Disconnect**. Markdown removes its local copy. The
repository on GitHub isn't affected. If you have changes that weren't pushed, the question says how many will be lost.
