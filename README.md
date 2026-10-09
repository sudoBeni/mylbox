# mylbox

A calm, keyboard-friendly mail app for macOS that sorts your mail for you and shares chosen mails with your other projects.

- **One inbox for all accounts**: Gmail, iCloud, Outlook / Microsoft 365 and any IMAP provider.
- **Sorted automatically**: *Inbox* shows only important mail. *Updates* (receipts, notifications) and *Newsletters* get their own place. *Needs Reply* collects mails someone is waiting on.
- **Local AI, built in**: an open-source model (Qwen3.5 4B via llama.cpp) runs on the Mac. It sorts mail into Important / Updates / Newsletters / Spam, spots mails that need a reply and writes one-line summaries. Nothing leaves the Mac, and it works the same for every mail provider. Download the model once in Settings → General. Until then, simple built-in rules do the sorting.
- **Spam**: the AI flags spam into its own folder. *Mark as Spam* also moves a mail to the server's junk folder, which trains your provider's filter.
- **Rules**: "if from / to / subject / body … then add to a space, set a category, mark read, flag, archive".
- **Spaces → other projects**: a space (e.g. *Volleyball Finance*) collects mails about one topic and mirrors them as Markdown into a folder of another repository, so that project and its AI assistant have the full mail context.
- **Private by default**: remote images are blocked until you load them, scripts never run, and passwords live in the Keychain.

## Build & run

Requires macOS 26 and Xcode 26. llama.cpp is pulled in as a pinned, checksum-verified binary (release b11165).

```sh
scripts/build-app.sh            # builds and signs build/Mylbox.app (Developer ID if available)
scripts/build-app.sh --install  # also copies it to /Applications
swift test                      # unit tests
MYLBOX_NET_TESTS=1 swift test --filter NetworkTests   # connection checks against Gmail/iCloud/Outlook
MYLBOX_MODEL=/path/to/model.gguf swift test --filter LocalModelTests   # classifies sample mails with a real model
```

To open it in Xcode, open `Package.swift`. Data lives in `~/Library/Application Support/mylbox`; set `MYLBOX_HOME` to use another folder, for example for testing.

## Adding accounts

Settings (⌘,) → Accounts → Add Account.

| Provider | Login |
|---|---|
| Gmail | An **app password**: Google Account → Security → 2-Step Verification → App passwords. |
| iCloud | An **app-specific password**: account.apple.com → Sign-In and Security. |
| Other IMAP | Your password; fill in the server settings. |
| Outlook / Microsoft 365 | Microsoft sign-in (OAuth). This needs a free Azure app registration, see below. |

### Outlook: one-time Azure app registration

Microsoft no longer accepts passwords for IMAP, so mylbox signs in with OAuth, and that needs your own app registration:

1. Go to [portal.azure.com](https://portal.azure.com) → *App registrations* → *New registration*.
2. Name it `mylbox`. Under *Supported account types*, choose "Accounts in any organizational directory and personal Microsoft accounts". Don't add a redirect URI.
3. Open *Authentication* and set **Allow public client flows** to *Yes*.
4. Open *API permissions* → *Add a permission* → *APIs my organization uses* → search for **Office 365 Exchange Online**, then add the delegated permissions `IMAP.AccessAsUser.All` and `SMTP.Send`. (Work accounts may need an admin to approve these.)
5. Copy the *Application (client) ID* into mylbox and click **Sign In with Microsoft**. mylbox copies the code to the clipboard and opens the sign-in page.

## Sharing mails with another project (e.g. volleyball finance)

1. Click **+** next to *Spaces* in the sidebar and name the space *Volleyball Finance*.
2. Under *Add mails automatically from*, enter the senders or domains, e.g. `kasse@vbc.ch, @swissvolley.ch`.
3. Under *Export to a project*, choose the repository. mylbox writes into a `mail/` subfolder there, and it never writes into a folder with files it did not create.
4. You can also add any single mail with the *Spaces* menu or the context menu.

The export is updated after every sync:

```
mail/
  README.md            explains the folder
  INDEX.md             all threads, newest first, linked
  messages/2026-10-09_1430_jahresabrechnung_3f9a1c2b7e.md
  attachments/3f9a1c2b7e/Abrechnung.pdf
```

Each message file has YAML front matter (from, to, date, direction, thread, summary, attachments) followed by the text. For Claude Code in that repo, add this to its `CLAUDE.md`:

```md
Mails related to this project are mirrored by mylbox into `mail/`. Start with `mail/INDEX.md`;
each mail is a Markdown file in `mail/messages/`, attachments are in `mail/attachments/`.
```

Turn on *Keep mails out of git* if the mails should stay local and not be committed. Note that some tools skip files ignored by git when searching.

## Local AI

| Model | Download | Correct (16 test mails) | Per mail | Memory while sorting |
|---|---|---|---|---|
| **Qwen3.5 4B** (default) | 2.7 GB | 15 | ~2 s | ~3 GB |
| Qwen3.5 2B (light) | 1.3 GB | 13 | ~1 s | ~1.6 GB |

Also tested: Phi-4-mini (13/16, 2.7 GB RAM), Gemma 4 E2B (13/16, 3.5 GB RAM), Qwen2.5 1.5B (10/16). The model is loaded only while new mail is sorted and released afterwards, so it doesn't hold memory the rest of the time. Measured on Apple Silicon with llama.cpp b11165.

Models are stored in `~/Library/Application Support/mylbox/models` and checked against their published SHA-256 after downloading. A grammar forces the model's output into a fixed JSON shape, so classifications can't come back malformed. Rules and your own choices always win over the AI.

## Keyboard

| Key | Action |
|---|---|
| ⌘N | New mail |
| E | Archive (in the list) |
| R / ⌘R | Reply |
| ⇧⌘R | Reply all |
| F / ⇧⌘F | Forward |
| U / ⇧⌘U | Mark unread |
| # / ⌘⌫ | Delete |
| ⇧⌘N | Check for new mail |
| ⌘↩ | Send |

## Architecture

```
Sources/MylboxCore      no UI, unit-tested
  Net/        TextConnection (SwiftNIO + TLS/STARTTLS), IMAP client and parser, SMTP, Microsoft OAuth
  Mail/       MIME parser, message builder, sync engine, server actions, credentials
  Storage/    SQLite message store, config (JSON), Keychain
  Automation/ heuristics, rules engine, local model (llama.cpp), model download, triage
  Export/     space → Markdown exporter
Sources/Mylbox          SwiftUI app (AppModel + views)
```

Sync fetches the newest mails of Inbox and Sent (300 on the first sync, configurable), then all new mail every few minutes. Read and flag states are synced in both directions. Archive and delete move the mail on the server (Gmail: *All Mail* / *Bin*).

## Roadmap ideas

- IMAP IDLE (push) instead of polling
- Snooze and reminders, unsubscribe button
- Signatures, HTML compose, drafts synced to the server
- Gmail and Google Workspace via OAuth (no app password)
- AI-drafted replies
