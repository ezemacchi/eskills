# chat

People and a message ready to send to one of them. The person always presses Send; a provider never
sends. Optional: the next-steps planner's "write to the developer" step and the message skill need it.

Provider today: `teams` (a Microsoft Teams deep link that opens a 1:1 chat with the message already
in the compose box).

## Commands

| Command | Output with `-Json` |
|---|---|
| `people` | `{ teamFile, myFile, people: [ { alias, email, language, askedAbout, you, source } ] }` |
| `link -To <alias or email> -Message <text> \| -MessageFile <file> [-Open] [-Copy]` | `{ to, email, prefilled, opened, copied, length, warning, url }` |

- `people` reads the pack's people file with the person's own on top (same alias: the person's
  wins). The file is a Markdown table `` | `alias` | email | language | asked about | ``.
- `link` refuses an unknown alias (exit 1) and a message to yourself (exit 1).
- `prefilled` is true when opening `url` shows the message in the compose box. When the service
  cannot do that (no deep link with a message), the provider copies the message to the clipboard,
  opens the conversation, and returns `prefilled: false`. The skill then tells the person to paste it.
- `warning` is set when the link is longer than the service accepts (`maxLinkLength`).
- What is particular to the service (formatting it shows literally, what to do when it does not
  open) goes in the provider's notes, which the chat skill reads before writing.
- The planner's texts name the service by its display name (`{{chat}}`).

## v1 (before the contract)

`New-TeamsMessageLink.ps1` returned `{ to, email, length, opened, copied, warning, url }`. There was
no `prefilled`, because Teams always pre-fills.
