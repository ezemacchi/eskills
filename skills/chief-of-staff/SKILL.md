---
name: chief-of-staff
description: Answers "what do I do now" - starts from the brief and proposes, in order and with the reason for each, what to do with the tickets that need the person, using the actions of their roles (for a tester - test what the instance testers use already has, tell a developer or the ticket that a fix has not arrived, answer a question, write or finish tests; other roles bring their own actions), then carries out the one the person picks, each step only after they say yes. Invoke with /chief-of-staff.
disable-model-invocation: true
---

# Chief of staff

## Getting the plan

```powershell
$kit = (pwsh -NoProfile -File "{{kit.setupScript}}" scripts) -join "`n" | ConvertFrom-Json
pwsh -NoProfile -File $kit.chief                 # the plan, in Markdown
pwsh -NoProfile -File $kit.chief -Json           # the same, with each item's data
```

- It reuses the last brief when it is recent (`chief.briefMaxAgeMinutes`) and runs it otherwise. `-Refresh` always runs it; use that when the person says something just changed.
- Exit `0`: done. Exit `3`: the brief could not reach Jira, Jenkins or Bitbucket; the plan says so and may be incomplete (probably no VPN). Exit `2`: not configured; offer `/setup`. Exit `1`: show the message.
- `next-steps.json` in the state folder holds the last plan; `brief.markdown` in it is the brief it came from.

## Replying

1. If the person has not seen the brief in this conversation, show it first, as `/brief-me` does: as written, with each Jira summary that is a slug rewritten as a few plain words in the person's language.
2. Show the plan as written, with the same summary rewrite. Do not reorder it or add items: the order comes from the configured rules (`chief.rules`), first match wins.
3. Ask which item to take with AskQuestion: one option per item (the first few), plus "none for now".

## Carrying out an item

The plan proposes; nothing happens until the person picks an item, and every write waits for a yes given after they have seen exactly what will be written.

- `test`: run `pwsh -NoProfile -File $kit.brief qa -Key <KEY> -Fresh` first; the instance may have changed. If it has the change, say so with the version, list the ticket's linked tests (`/board`), and help the person run them. If it does not, say from which version it will and offer `comment` or `teams` instead. Never say something was tested; the person tests.
- `comment`: draft the comment following the `/board` skill ("Writing" and the team's notes). For a retest that waits for a version, say which instance, which version it runs, and from which version the fix is there. Show the exact text, wait for a yes, write it to a file with the Write tool, and post it with `pwsh -NoProfile -File $kit.board comment -Key <KEY> -BodyFile <file>`.
- `answer`: read the ticket's latest comments (`/board`, `comments -Key`), say in plain words what is being asked, ask the person for what they know, then draft and post as for `comment`.
- `teams`: the developer is in the item (`developer`: name, and `alias` when they are in the people directory). Without an alias, ask the person who it is. Follow the `chat` skill: read the recipient's profile, draft, show the message and who it goes to, and open it with `-Open` after a yes. The person presses Send.
- `writeTests`: read the story's specification with `/board` (acceptance criteria and the specification files), propose test cases, and give them as text for the person to create in Jira.
- `finishTests`: list the linked tests still in draft (`/board`), go through them with the person, and say what each one needs. Moving a test out of draft is done in Jira by the person.
- Any other action comes from the project's pack or the person's roles: the plan's `actions` list (with `-Json`) gives its `how`. Follow it, with the limits below. When an action has `recipient: developer`, the person to write to is in the item (`developer`), as for `teams`.

## Recording what happened

After each item, record the outcome so the next plan does not propose it again:

```powershell
pwsh -NoProfile -File $kit.chief record -Key <KEY> -Outcome done [-Ref <comment id or teams:alias>] [-Note "<short note>"]
pwsh -NoProfile -File $kit.chief record -Key <KEY> -Outcome declined          # the person said no
pwsh -NoProfile -File $kit.chief record -Key <KEY> -Outcome later [-Until 2026-12-31]   # tomorrow by default
pwsh -NoProfile -File $kit.chief history                                       # what was recorded
```

- `-Action` defaults to the action the last plan proposed for that ticket; pass it when the person did something else (one of the names `pwsh -NoProfile -File $kit.chief check` lists under `actions`).
- `done` hides the item while the ticket keeps its status and the same rule proposes it, that is, while its situation has not changed (a fix arriving on the instance, for example, changes it); `declined`, for today; `later`, until that date.
- Record only through the script. Never edit the state file by hand.

## Changing the plan

Prefer configuration and the person's own template. The installed kit's files may also be edited (to change how this skill behaves, edit this `SKILL.md` in place): an update keeps the edit, and when the kit changed the same file `/setup` offers to merge them. The table "Where each change goes" in `/setup` says which to use.

- Order and actions: `chief.rules`. Write the list to a JSON file with the Write tool and set it with `/setup` (`set -Key chief.rules -ValueFile <file>`). The script's help (`Get-Help` on it) lists the conditions a rule can use.
- Which actions the person uses: `chief.use`, set by their roles (`check` says, per rule and per action, whether it is `used`). To stop one for this person only: `/setup` `set -Key chief.use.<action> -Value false -AsJson`.
- New actions belong in the project's pack (`chief.actions`): a label and a proposal per language, the capabilities they need, and a `how` for the agent. Propose them there rather than in one person's file.
- How the plan reads: the person's own template (`paths.templates.nextSteps`). `pwsh -NoProfile -File $kit.chief check` prints, under `template`, the team's file (`team`) and where the person's goes (`minePath`). Create or extend the person's file with the Write tool, holding only the texts they change, each starting with the same `<!-- @name -->` line; theirs win, and a name the team's template does not have is ignored and listed in `template.unknown`.

## Limits

- No Jira write without the exact text shown and a yes. A transition only with the target status shown and a yes, through the `/board` skill ("Moving an issue"). No field edits: say what to change and that it is done in Jira.
- Nothing is sent on the chat; the person presses Send.
- Never print, repeat, or write a token.
