# RallyMail

A calm, keyboard-first mail app for macOS. One list, two verbs, nothing ever deleted. Conversations read like chat, and whole conversations can be shared with your other projects as Markdown.

- **Chats, Courts and Infos.** The app opens on *Chats*: everything with the same people in one timeline, like a messenger (Reto alone is one chat, Reto and Lea together another). A marker shows where each topic picks up. *Courts* are your own areas, e.g. Volleyball Finance or Business: each court lists its topics, and Courts is the only place with Done and Later. *Infos* sit in the lower third of the list, always in sight: one row per sender of one-way mail (GitHub, Coolify, receipts, newsletters) with a count of new ones. Reading is enough there. Right-click a sender to move it to Infos or back to Chats, now and for future mail.
- **Topics: one list.** Mail from people is a row: who, the one-line summary, the subject in fine print. Mail from machines is folded into one *Updates* and one *Newsletters* row you can open or clear. Below that the list simply continues as *Earlier*: everything you have ever handled, newest first, with sticky month headers and a date rail to jump.
- **Two verbs.** *Done* hides a conversation and archives it on the server. *Later* brings it back the next morning. Nothing leaves the list on its own; only you move a row.
- **Conversations like chat.** One bubble per message, only the new text: quotes, signatures and the header lines mail clients add ("Von: … Gesendet: …", "Am … schrieb …") are filtered out, read from the HTML part where mail programs mark them. A forwarded mail shows under its author's name and date, "via" the person who passed it on; forwarding a mail that is already in the chat is just a note. A mail sent twice is one bubble, text pasted below instead of quoted folds behind "Repeats …", and the fixed text of relay services (tutti, Airbnb) folds behind "Boilerplate". Under every bubble: who got it. When someone adds or drops a person, the chat says so. When someone changes what another person wrote earlier (edits or answers inside the quote), their bubble shows exactly which words changed. Attachments get version labels. "original" shows any mail exactly as it arrived. Nothing is ever dropped or rewritten: a bubble differs from the mail only in whitespace, and folded parts are one click away.
- **Clear audience.** The reply box says in words who gets the mail: "To Reto · copy to Lea". Click a role to cycle To, Cc, Bcc. Leave someone out and a note warns you. Hidden copies are marked orange, and a mail you got as a hidden copy warns before you reply.
- **Spaces bundle conversations.** A space is a filter on the same list, not a folder. Press P to put a conversation into a space, tick "also future mail from this sender" once, and that person is sorted forever. A space can be mirrored as Markdown into a folder of another repository, so that project and its AI assistant have the full mail context.
- **Waiting for.** Mails you sent that got no answer after a few days show up with a Nudge button.
- **One search over everything.** Open, done, folded, sent, attachment names. Results are grouped by person. Searching inside a space searches only that space.
- **On-device AI.** An open-source model running locally sorts mail, spots mails that need a reply and writes the one-line summary that becomes each row's headline. Nothing leaves the Mac.
- **One inbox for all accounts.** Gmail, iCloud, Outlook / Microsoft 365 and any IMAP provider. Private by default: remote images are blocked until you load them, scripts never run, passwords live in the Keychain.

## Build & run

Requires macOS 26 and Xcode 26.

```sh
scripts/build-app.sh            # builds and signs build/RallyMail.app (Developer ID if available)
scripts/build-app.sh --install  # also copies it to /Applications
swift test                      # unit tests
RALLYMAIL_NET_TESTS=1 swift test --filter NetworkTests   # connection checks against Gmail/iCloud/Outlook
```

The app icon's source is `Resources/AppIcon.svg`; `scripts/make-icon.sh` renders `AppIcon.icns` from it (needs `brew install librsvg`). To open it in Xcode, open `Package.swift`. Data lives in `~/Library/Application Support/RallyMail` (an older `mylbox` folder is moved there automatically); set `RALLYMAIL_HOME` to use another folder, for example for testing.

To look at the app with example mail and no real account:

```sh
RALLYMAIL_SEED=/tmp/rallymail-demo swift test --filter DemoSeed
RALLYMAIL_HOME=/tmp/rallymail-demo swift run RallyMail
```

## Adding accounts

Settings (⌘,) → Accounts → Add Account.

| Provider | Login |
|---|---|
| Gmail | An **app password**: Google Account → Security → 2-Step Verification → App passwords. |
| iCloud | An **app-specific password**: account.apple.com → Sign-In and Security. |
| Other IMAP | Your password; fill in the server settings. |
| Outlook / Microsoft 365 | Microsoft sign-in (OAuth). This needs a free Azure app registration, see below. |

The first sync downloads **everything** by default, so that search and *Earlier* are complete. That takes a while once; afterwards only new mail is fetched. A smaller first download can be chosen in Settings → General.

### Outlook: one-time Azure app registration

Microsoft no longer accepts passwords for IMAP, so RallyMail signs in with OAuth, and that needs your own app registration:

1. Go to [portal.azure.com](https://portal.azure.com) → *App registrations* → *New registration*.
2. Name it `RallyMail`. Under *Supported account types*, choose "Accounts in any organizational directory and personal Microsoft accounts". Don't add a redirect URI.
3. Open *Authentication* and set **Allow public client flows** to *Yes*.
4. Open *API permissions* → *Add a permission* → *APIs my organization uses* → search for **Office 365 Exchange Online**, then add the delegated permissions `IMAP.AccessAsUser.All` and `SMTP.Send`. (Work accounts may need an admin to approve these.)
5. Copy the *Application (client) ID* into RallyMail and click **Sign In with Microsoft**. RallyMail copies the code to the clipboard and opens the sign-in page.

## Spaces: bundling conversations and sharing them with a repo

1. Click **+ New space** in the strip under the title bar and name it, e.g. *Volleyball Finance*.
2. Open a conversation and press **P** (or click the space chip) to put it into the space. Leave "also put future mail from this sender here" ticked and that sender is sorted automatically from now on. Alternatively enter senders or domains in the space's settings, e.g. `kasse@vbc.ch, @swissvolley.ch`.
3. Under *Export to a project*, choose the repository. RallyMail writes into a `mail/` subfolder there, and it never writes into a folder with files it did not create.

Click the space in the strip to see only that space: open conversations on top, everything earlier below. The line above the list shows where it is mirrored.

The export is updated after every sync:

```
mail/
  README.md            explains the folder
  INDEX.md             all conversations, newest first, linked
  messages/2026-10-09_1430_jahresabrechnung_3f9a1c2b7e.md
  attachments/3f9a1c2b7e/Abrechnung.pdf
```

Each message file has YAML front matter (from, to, date, direction, thread, summary, attachments) followed by the text. For Claude Code in that repo, add this to its `CLAUDE.md`:

```md
Mails related to this project are mirrored by RallyMail into `mail/`. Start with `mail/INDEX.md`;
each mail is a Markdown file in `mail/messages/`, attachments are in `mail/attachments/`.
```

Turn on *Keep mails out of git* if the mails should stay local and not be committed. Note that some tools skip files ignored by git when searching.

## Keyboard

| Key | Action |
|---|---|
| J / K, ↓ / ↑ | Move through the list |
| ↩ | Open the conversation |
| D | Done (or Reopen, under Earlier) |
| L | Later: back tomorrow morning |
| R | Reply (opens the conversation, focuses the reply box) |
| P | Put the conversation into a space |
| Esc | Close the conversation |
| ⌘K | Search |
| ⌘N | New mail |
| ⌘↩ | Send |
| ⌘Z | Undo the last Done or Later (while the confirmation shows) |
| ⇧⌘N | Check for new mail |

Delete and *Mark as Spam* live in the context menu of a row; they are not needed in the normal flow.

## Security: a mail can only be looked at

Mail is hostile input. RallyMail is built so that a mail can never run, redirect, phone home or drop a file that runs itself. The rules live in one place, `MailSandbox`, and `Tests/RallyMailCoreTests/SecurityTests.swift` feeds a mail that tries everything at once (script, meta refresh, tracking pixel, `javascript:` and `file:` links, iframe, form, event handlers, right-to-left file names, double extensions) through every rule.

| Threat | What RallyMail does |
|---|---|
| Scripts in HTML mail | The conversation view never renders HTML, only text. The "original" view runs the HTML in a WebKit view with JavaScript off **and** a Content-Security-Policy of `default-src 'none'`, `script-src 'none'`. Script tags, event handlers and `javascript:` URLs are also stripped before the page is built. |
| Automatic redirects, forms, frames | Only the page RallyMail built itself may load. Meta refresh, form posts, iframes, objects and `window.open` are blocked; they never reach the network. |
| Links | A link does nothing until you click it. A clicked `http(s)` link opens in your browser, never inside the mail view. `javascript:`, `file:`, `data:` and custom schemes are dropped. No referrer is sent. |
| Tracking pixels, remote images | Blocked by default. "Load Images" is per mail and per view, and even then scripts and frames stay forbidden. |
| Attachments | Opened only on your click. Files are written with a safe name (no path separators, no hidden names, no right-to-left tricks) and marked with the quarantine flag, so Gatekeeper checks them like a browser download. Files that could run code (`.app`, `.command`, `.sh`, `.pkg`, `.dmg`, `.html`, `.svg`, `.jar`, double extensions …) are only revealed in Finder, with a warning. |
| Mail content in your repos | The exported Markdown states that mail is untrusted input and must be treated as data, never as instructions, so an AI assistant working in that repo is warned. Exported attachments carry the quarantine flag too. |
| Transport | IMAP and SMTP always use TLS or STARTTLS with full certificate and hostname verification (SwiftNIO SSL defaults). Passwords and OAuth tokens live in the Keychain. |
| The local AI | Runs on this Mac only. Mail never leaves the machine for sorting or summaries. |

## Architecture

```
Sources/RallyMailCore   no UI, unit-tested
  Net/        TextConnection (SwiftNIO + TLS/STARTTLS), IMAP client and parser, SMTP, Microsoft OAuth
  Mail/       MIME parser (incl. format=flowed), message builder, sync engine, server actions, credentials,
              HTMLText (HTML → lines with quote/signature regions), Segmenter (own text, quote header,
              forwarded body), ChatTimeline (bubbles and notes: forwards, duplicates, repeats),
              MessageFormatter (chat layout), Threading (conversations, edits to earlier messages)
  Storage/    SQLite store (messages, threads), config (JSON), Keychain
  Automation/ heuristics, rules engine, local model (llama.cpp) and triage
  Export/     space → Markdown exporter
Sources/RallyMail       SwiftUI app
  AppModel    list state, conversation actions (Done, Later, Reopen, spaces), sync, sending
  Views/      MainView (list, filter strip, rail), Rows, ConversationView (bubbles, edits, space picker),
              Composer (audience editor), OriginalMessageView, Settings
```

Every message carries a `thread_id`. Replies are joined by their References / In-Reply-To headers (in any order of arrival), new mail with the same subject and the same people within two weeks (three days for companies), and replies without headers by subject plus a shared participant. Conversations that share a file number in the subject with the same organisation are bundled into one topic automatically; weaker matches (same organisation or person, similar subject) are suggestions, and the local model is asked whether the two are one matter before a suggestion is shown.

Audits on a copy of a real database (never the live one): `RALLYMAIL_AUDIT=<db copy> RALLYMAIL_AUDIT_DUMP=<txt> swift test --filter PipelineAudit` lists leaked quotes, generated lines, forwards, repeats and duplicates; `--filter FormatterAudit` checks that no bubble changes content; `--filter SuggestionAudit` lists topic suggestions; `RALLYMAIL_AUDIT_PROBE=<message id>` shows how one mail is cut. A conversation's space, snooze time and "waiting" state live in the `threads` table. *Done* archives on the server (Gmail: *All Mail*), *Reopen* moves back to the inbox. Read and flag states sync in both directions.

## Roadmap ideas

- IMAP IDLE (push) instead of polling
- Deadlines extracted from mail, shown as a small week strip above the list
- AI-drafted reply suggestions
- Gmail and Google Workspace via OAuth (no app password)
- Signatures, HTML compose, drafts synced to the server
