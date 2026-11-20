---
name: chat
description: Writes a message to a colleague following their profile (who they are, language, how to write to them) and opens a 1:1 chat with it ready to send (Microsoft Teams through the teams provider), or copies it; it never sends anything, the person presses Send. Use when the person wants to ask a colleague something over chat (a developer about a bug they reported, a product question, a test-data question), asks for a chat link with a message, or a ticket being looked at raises a question for someone.
---

# Chat message

## Scripts and configuration

The chat service comes from the configuration (the chat capability). Read what is particular to it once per conversation, before writing: `pwsh -NoProfile -File $kit.setup provider -Capability chat` prints its notes (`notes`). People come from the team's directory (the project pack's), overlaid by the person's own additions (`paths.myPeople`), which win for the same alias.

```powershell
$kit = (pwsh -NoProfile -File "{{kit.setupScript}}" scripts) -join "`n" | ConvertFrom-Json
pwsh -NoProfile -File $kit.chat people                                   # alias, e-mail, language, what they are asked about, and where the profiles are
pwsh -NoProfile -File $kit.chat -To <alias or e-mail> -MessageFile <file> -Open   # opens the chat with the message ready
pwsh -NoProfile -File $kit.chat -To <alias or e-mail> -MessageFile <file> -Copy   # copies it instead
```

- `-Message "<text>"` works for one line. `-Json` prints `to`, `email`, `prefilled`, `opened`, `copied`, `warning` and the link, for other skills.
- `prefilled: true`: the chat opens with the message in the compose box. `prefilled: false`: the service cannot carry the message in a link, so the script copied the message and opened the conversation; tell the person to paste it.
- Exit `1`: unknown person (it lists the aliases), empty message, or the person writing to themselves. Exit `2`: configuration missing; use the setup skill.
- Nothing in this skill sends a message. The person reads it and presses Send.

## People

`people` prints where the profiles are: the team's file, and the person's own when it exists. Read the recipient's profile there before writing. For someone not in either file, ask the person for the e-mail, then add a table row and a short profile to the person's own file (`paths.myPeople`; create it with the same table header as the team's file). When the person corrects how a message to someone was written, add the correction to that profile in their own file. Prefer the person's own file to editing the team's: it never needs merging when the kit is updated.

## Writing the message

The reader is busy with other work and does not know the ticket in detail.

- The shape comes from the writing guide: `pwsh -NoProfile -File $kit.setup guides` prints where the team's guide `chatMessages` is and where the person's own is (`mine`, when `mineExists`). Read the team's, then the person's: a section there replaces the team's section with the same `@name`, and a section the team does not have is an extra shape the person uses. Sections: `question`, `retest-failed`, `confirmation` (questions the person already answered are confirmations, not open questions). For a message no section covers, follow the rules below.
- Write in the recipient's language (their profile says which).
- No internal codes without saying what they are.
- Follow the provider's notes on formatting (some services show Markdown literally).
- Then apply the recipient's profile, which wins over the guide.

## Sending it

1. Write each message to its own UTF-8 file with the Write tool (for example `$env:TEMP\msg-<alias>.txt`). Do not put long multi-line text in a shell command; it hangs the shell tool.
2. Show the person the message text, and say who it goes to.
3. When they want it opened, run the script with `-Open`. If the chat does not open, the provider's notes say what to do instead (usually `-Copy`).
4. Never paste a chat link into this conversation: it repeats the whole message, encoded.
5. A `warning` means the service may cut the message; shorten it.
