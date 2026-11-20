---
name: board
description: Reads the team's ticket board (Jira Cloud through the jira-cloud provider; another board through its own provider) with the person's own API token to answer what to work on, what a story asks for and where its spec files are (acceptance criteria, scenarios, prototypes), its status, sprint, linked tests and comments, and the person's saved views (for example test cases in draft, bugs they filed); posts or edits a comment, or moves an issue to another status, only after the person approves exactly what will be done. Invoke with /board.
disable-model-invocation: true
---

# Board

## Scripts and configuration

Everything this skill knows about the site, the project, the board and the field ids comes from the kit configuration (set up with `/setup`). Project knowledge that is not in code (how stories are named, the workflow and its statuses, test-case naming, who files what) is in the project notes: run `notes` once per conversation before answering anything project-specific, and follow it.

```powershell
$kit = (Get-Content -Raw (@($env:{{kit.configVar}}, "$env:LOCALAPPDATA\{{kit.name}}\config.json") | Where-Object { $_ })[0] | ConvertFrom-Json).scripts
pwsh -NoProfile -File $kit.board <command> ...
```

If the configuration file is missing, or a script exits `2`, use the setup skill and stop.

| Command | Does |
|---|---|
| `notes` | The team's project notes, then the person's own. No credentials needed. |
| `view` | Lists the person's saved views. `view -Id <id>` runs one. |
| `search -Jql "<jql>" [-Fields summary,status,priority] [-Max 50]` | Issues, one line each: `KEY \| column \| ...`. |
| `issue -Key <KEY>` | Fields, sprint, points, epic, linked tests first, other links, description. |
| `comments -Key <KEY>` / `changelog -Key <KEY>` | All comments / the full history, oldest first. |
| `transitions -Key <KEY>` | The moves Jira offers from the current status. Lists only; moves nothing. |
| `sprints` | Active and future sprints of the configured board. |
| `me` / `user -Query <email or name>` | Whose token this is / someone's account id, to mention them. |
| `discover [-Days 180]` | Who the token is, and each project the person worked in with its issue types counted, its statuses and their category (todo, inProgress, done), and its boards. Used by `/setup`. |
| `footprint [-Days 180]`, `statuses`, `boards` | Jira's own detail behind `discover`: issues counted by project, type and status; the project's statuses per issue type; its boards. |
| `comment -Key <KEY> -BodyFile <file>` | Adds a comment. See "Writing". |
| `edit-comment -Key <KEY> -CommentId <id> -BodyFile <file>` | Replaces one of the person's own comments. |
| `transition -Key <KEY> -To '<status>' [-BodyFile <file>]` | Moves the issue to that status, then posts the reason as a comment. See "Moving an issue". |

`-Json` gives the board contract's shape (the same for any board provider), which other skills parse. `-Raw` gives Jira's own JSON, for a field the contract and the text leave out.

- Exit `0` ok. `1` bad input or an unexpected answer (the message says which; for a view, "check the JQL"). `2` configuration or credentials missing: use the setup skill. `3` Jira refused the account or is unreachable: the network, or an expired or revoked token; say which the message names and stop.
- The token is never printed. Do not echo the token variable, put it on a command line, or write it to a file.
- Link for the person: `<providers.jira-cloud.site>/browse/<KEY>`; `search` and `view` print it.
- Do not guess a ticket's state from branch names when the script fails.
- In JQL passed on the command line use single quotes inside: `status = 'In Review'`.

## Saved views

`board.views` in the configuration holds the queries the person looks at most, chosen in `/setup` from what they actually do in Jira. Prefer them over writing JQL: "what do I have pending" is the views, run in order. `{project}`, `{me}` and `{board}` in a view stand for the configured project, the person and the board. To add, drop or change a view, use the setup skill (step 6); do not edit the configuration by hand.

## Reading a story and its spec

Say what the story does in plain words, then the key. Do not hand a summary slug or a work-item code to a person as if it explained anything; the notes say how to read them.

The spec files (the source of truth for a story: scope, acceptance criteria, non-functional requirements, scenarios, clickable prototypes) are listed by the specification script, when the project has one (the specs capability; `pwsh -NoProfile -File $kit.setup provider -Capability specs` says whether it is on):

```powershell
pwsh -NoProfile -File $kit.specs <the story's code, a text that holds it (its summary), or a link to one of its spec files>
```

- The project notes (`notes`) say what a story's code looks like and which prototype to open first.
- One line per file with its kind: `scope`, `acceptance`, `non-functional`, `requirements`, `scenarios`, `prototypes`.
- Paths printed as `origin/<branch>:<path>` mean the clone has local changes or is on another branch; read them with `git -C <clone> show origin/<branch>:<path>`. Never pull, stash or reset that clone yourself.
- "Could not reach" means the person is probably off the VPN; say the local copy may be out of date.
- `fallback` in the `-Json` answer (a note at the end of the text says the same): the files were found by a wider search, because the pack's specification values did not lead to them. `whole-root`: they are outside the folder the values point to. `name-search`: they were matched by name, so check each file's name against the story before using it. Use them, and tell the person in one line that the project's specification settings no longer fit the repository and which value the note names; offer to propose the fix to the pack (setup skill, "Proposing a change to the kit").
- Exit `1`: nothing was found, even with the wider searches. Tell the person in plain words what was searched and the options the message lists, after re-checking the code in the ticket's description. Never say the story has no specification on that basis alone. Exit `2`: no specification clone; `/setup` step 5 sets one up.

For "this ticket", take the key from the current git branch name (`git branch --show-current`) when the folder is a clone.

## Answering

- Answer with the link, what the issue is in plain words, its status and its sprint. A table only when listing several issues.
- For "what do I have pending", run the saved views, and separate what waits on the person from what waits on someone else, naming who. Recommend the next one with a one-line reason.
- When explaining what the person can do next with an issue, read `transitions` and match the target status (after `->`), not the transition name. The notes list the traps.

## Writing

The script adds and edits comments and moves issues. It cannot create issues or edit fields: for those, show the exact change and say it has to be done in Jira. Do not work around it with a hand-written REST call or another tool.

Every write is confirmed twice. First by you: show exactly what will be done and wait for a yes. Then by Cursor: a hook installed with the kit stops each write (this script's `comment`, `edit-comment` and `transition`, a direct call to the Jira address, and the Atlassian MCP's writing tools) and asks the person. The hook is the second barrier, not the only one: never run a write hoping the person will catch it there. If the person declines in Cursor, do not retry the write another way. Each successful write is recorded in the local log (`providers.jira-cloud.writeLog` in `paths.stateDir`).

Posting a comment, in order:

1. Show the person the exact text for each ticket and wait for a yes in a message after they have seen it. People read these comments to learn why a ticket is where it is; a wrong one costs more than a slow one. "Comment the tickets" is the go-ahead to draft, not to post.
2. Write each text to its own UTF-8 file with the Write tool and pass `-BodyFile`. `-Body "<text>"` is fine for one line; long multi-line strings in a command hang the shell tool.
3. The script signs every comment (`board.commentSignature`) on a line of its own, so the team can tell an agent wrote it on the person's behalf. Do not type the signature yourself.
4. It refuses (exit `1`, "already has this comment") when the ticket already has the same text, so re-running after a partial failure is safe. Report that as already done.
5. It prints `ok <KEY> comment <id> | <link>`. Read it back with `comments -Key`.

To fix a posted comment, edit it with `edit-comment` (the id is in the `ok` line or `comments -Json`) rather than posting a correction under it. Same rule: show the new full text, post after a yes. It edits only the token owner's own comments.

### Moving an issue

1. Read the issue's current status, its latest comments and its changelog, and `transitions -Key`. Someone else may already have moved it.
2. Show the person the ticket, its current status, the target status (as `transitions` shows it after `->`) and the reason, as the exact comment text, shaped by the guide's `transition` section. Wait for a yes given after they have seen it. Do not choose a target the workflow rules in the notes do not support, and do not skip steps.
3. Write the reason to a file with the Write tool and run `transition -Key <KEY> -To '<status>' -BodyFile <file>`. The script picks the move by the target status, then posts the reason as a signed comment.
4. It prints `moved <KEY> from '<a>' to '<b>'` and the comment's `ok` line. Report both.

The script refuses, and nothing changes, when no move leads to that status, when several do, when the only one is an "(admin)" move, or when the issue is already there. Say which and stop. When Jira requires a field for the move, the message names it in Jira's words: tell the person the move has to be done in Jira, where that field can be filled.

What goes in a comment:

- Its shape comes from the writing guide: `pwsh -NoProfile -File $kit.setup guides` prints where the team's guide `boardComments` is and where the person's own is (`mine`, when `mineExists`). Read the team's, then the person's: a section there replaces the team's section with the same `@name`, and a section the team does not have is an extra shape the person uses. Sections: `status` (a status comment), `failed-test`, `transition` (the reason posted with a transition). For a comment no section covers, follow the rules below.
- Say only what you checked. "The change is on the qa instance (version 0.1.80); retest pending" rather than "fixed", unless it was verified.
- A comment that asks someone something mentions them, so Jira notifies them: `[~accountid:<id>]` at the start of the sentence addressed to them. The name alone notifies nobody. Get the id with `user -Query <email>`; e-mails are in the people directory (`pwsh -NoProfile -File $kit.chat people`). Ask the person for an e-mail that is not there.
- Plain language: what happened, where (environment and version, pull request, branch), how it was verified, and what was not verified.
- Write in the language the ticket's comments use.
