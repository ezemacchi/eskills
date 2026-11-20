---
name: brief-me
description: Writes the person's brief in their language - what needs them now, what changed since the last brief, each of their saved board views, whether the instance testers use already has each ticket's change (and from which version it will), the version each instance runs, and, for people who work with pull requests, their open and merged pull requests and worktrees. Invoke with /brief-me.
disable-model-invocation: true
---

# Brief me

## Running it

```powershell
$kit = (pwsh -NoProfile -File "{{kit.setupScript}}" scripts) -join "`n" | ConvertFrom-Json
pwsh -NoProfile -File $kit.brief                    # the brief, in Markdown
pwsh -NoProfile -File $kit.brief qa -Key PROJ-123   # only: does the instance testers use have this ticket's change?
```

- The brief is written to `brief.md` and `brief.json` in the kit's state folder (`paths.stateDir`), and printed. `-Json` prints the JSON; other skills read that, never the Markdown.
- `qa -Key <KEY>` answers for one ticket. An answer is remembered while that instance runs the same version (a "not yet" for a shorter time); add `-Fresh` when the person says something was just deployed.
- It takes from a few seconds to a few minutes: each instance check reads git history and Jenkins. Say it is running; do not start it twice.
- Exit `0`: done. Exit `3`: written, but Jira, Jenkins or Bitbucket could not be reached; the brief itself says which and what is missing, so show it anyway and add that the person is probably not on the VPN. Exit `2`: something is not configured; offer `/setup`. Exit `1`: bad input or a broken configuration value; show the message.

## Replying

Show the brief as the script wrote it: same sections, same order, same tables, same verdicts. The only change: Jira summaries are often slugs (words joined by underscores, a product prefix, a story number). Rewrite each one, in the table cell where it is, as a few plain words in the person's language (`user.language`), keeping the key and link. Do not add verdicts, move items between sections, or drop rows.

Then offer one next step, the most useful given the brief: usually `/chief-of-staff` ("what do I do now"), or `/ci` for a failed pull request build, or `/board` for a ticket the person asks about.

## What it checks

- Views: the person's saved views (`board.views`), in order. A view with `qaCheckStatuses` checks the issues in those statuses (`["*"]` for every status) against the instance testers use (`delivery.qaEnvironment`; needs the cd capability): has the change, does not have it yet (and from which version it will), or no commits found. A ticket with no commits of its own is checked through the issues linked to it (`brief.followLinks`), which is how a bug report reaches the ticket that fixed it. At most `brief.qaCheckMax` checks per brief; the rest say so.
- A view with `"linkedTests": true` counts each issue's linked tests by status.
- Changes: tickets that appeared in, left, or changed status in a view since the last brief.
- Pull requests, merged pull requests and worktrees appear only for people with `user.pullRequests` on, and when the repo capability is on. They read Bitbucket with the person's token and run `git fetch` in the code clone (`paths.codeRepo`); nothing else in the clone changes.

## Changing what the brief shows

Most changes are configuration or the person's own template; prefer those. The installed kit's files may also be edited (to change how this skill behaves, edit this `SKILL.md` in place): an update keeps the edit, and when the kit changed the same file `/setup` offers to merge them. The table "Where each change goes" in `/setup` says which to use.

- Sections and their order: `brief.sections`. Write the new list to a JSON file with the Write tool and set it with `/setup` (`set -Key brief.sections -ValueFile <file>`). Section types: `attention`, `changes`, `views` (add `"views": ["<id>", ...]` to show only some), `instances`, `pullRequests`, `merged`, `worktrees`. `"requires": "<configuration key>"` shows a section only when that value is `true`; `"capabilities": ["cd"]` only when those capabilities are on.
- Views: `/setup`, step 6.
- Texts (titles, phrases, date formats, table column names): the person's own template (`paths.templates.brief`). `pwsh -NoProfile -File $kit.brief check` prints, under `template`, the team's file (`team`) and where the person's goes (`minePath`); `mine` is set once it exists. Open the team's file to see each text and its `{{values}}`. Create or extend the person's file with the Write tool, holding only the texts they change, each starting with the same `<!-- @name -->` line. Theirs win; a name the team's template does not have is ignored and listed in `template.unknown`. Changes show on the next brief.

## Limits

- Read-only: no Jira writes, no pull, merge, rebase or push.
- Never print, repeat, or write a token. The Bitbucket token is read from its environment variable by the script.
