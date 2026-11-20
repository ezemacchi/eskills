---
name: setup
description: Sets up the skills kit (board, ci, chat, brief-me, chief-of-staff) for one person, or changes it later, with the capabilities and providers the project pack chooses. Checks the tools, records the board credentials (the person types the token in his own terminal, never in chat), finds or clones the repositories, looks at that person's board (projects, issue types, statuses, boards) to choose the saved views the other skills show, sets up the brief, and runs the kit test. Use when the person runs /setup or /init, asks to change what the skills show or which repository they read, wants a skill to behave or look different, has just updated the kit (pending merges), or a kit script exits with code 2 or says "Run /setup".
---

# Kit setup

The kit's skills read every value (which provider each capability uses, its addresses and ids, clone paths, saved views) from one configuration. This skill is the only way to write it. Never edit a `config.json` by hand: a broken one stops every kit script. `defaults/config.json` is also replaced on every kit update; what a person wants different goes in their own file with `set`.

## Where each change goes

The installed kit's files may be edited; an update keeps the edits (see "Updating the kit"). Still, each kind of change has a better place, and the lighter ones never need merging:

| The person wants to change | Where |
|---|---|
| What the views show, the brief's sections, the plan's rules | Configuration, with `set` (steps 6 and 8) |
| A text of the brief or of the plan | Their own template (step 8) |
| The shape of a board comment or a chat message | Their own guide (`guides` prints where it goes) |
| A colleague's profile, a project note | Their own files (`paths.myPeople`, `paths.myNotes`) |
| How a skill behaves | That skill's `SKILL.md`, edited in place in the installed copy |
| Something that would help everyone | A proposal to the kit ("Proposing a change to the kit") |

When the person says they want a skill to behave or look different, find the row first and say which place you will use and why, then make the change there.

## How the configuration works

Four layers, each on top of the one before; a value in a later layer wins, and a list replaces the earlier list:

- **Kit defaults**: `defaults/config.json` in this skill's folder. Values every project shares. Replaced on every kit update.
- **The project pack**: `pack/pack.json` in this skill's folder, installed from the project's pack with `Install.ps1 -Pack`. What everyone in the project shares: which provider each capability uses and its addresses and patterns, the plan's rules. The pack also ships the team's people directory and project notes (`people.md`, `notes.md`), and may ship templates, guides and, for a service no kit provider covers, its own providers; each replaces the kit's file of the same name.
- **The role**: `pack/roles/<user.role>.json`, when the pack has roles. What everyone in that role shares: the saved views, whether they work with pull requests. `Install.ps1 -Role <name>` or step 6 sets `user.role`.
- **The person's own file**: `%LOCALAPPDATA%\{{kit.name}}\config.json` (or the path in the variable `{{kit.configVar}}`). Holds only what differs for that person: usually just their identity and where their clones are.

More:

- **Capabilities and providers**: what the project has is a list of capabilities (`capabilities`): `board` (tickets), `repo` (pull requests), `ci` (builds), `cd` (environments and versions), `chat` (messages), `specs` (specification files). Each names its provider (`capabilities.<name>.provider`), a folder with a `provider.json` and usually a script, in `providers/` here or in the pack. A capability with no provider, or `"enabled": false`, is off, and everything that needs it is skipped: sections of the brief, rules of the plan, checks of the test. To turn one off for the person: `set -Key capabilities.<name>.enabled -Value false -AsJson`, then `init`. `provider -Capability <name>` says which provider it uses and prints its notes.
- **Team files**: the people directory (`kit.teamPeople`) and the project notes (`kit.teamNotes`), from the pack (else the kit's empty ones in `defaults/`). The person's own additions go in `paths.myPeople` and `paths.myNotes`, and win over the team's.
- **Templates**: the texts of the brief and of "what do I do now", one file per language in `defaults/templates/` (`kit.templates`). The person's own template (`paths.templates.brief`, `paths.templates.nextSteps`) holds only the texts they change, and wins.
- **Writing guides**: the structure and tone of board comments (`boardComments`) and chat messages (`chatMessages`), in `defaults/guides/` (`kit.guides`). The agent applies them, not a script. The person's own guide (`paths.templates.boardComments`, `paths.templates.chatMessages`) holds only the sections they change, each with the same `<!-- @name -->` line, and wins; `guides` prints where each file is. Create it with the Write tool.
- Every script exits `0` ok, `1` bad input or not found, `2` missing configuration or credentials ("Run /setup"), `3` unreachable (usually the VPN). `-Json` output is what other skills parse.

The configuration script is `scripts\Initialize-Config.ps1` in this skill's folder (the folder this SKILL.md is in); call it `$setup` below. Run it with `pwsh -NoProfile -File $setup <command>`; every command prints JSON. After `init`, every kit script's path is under `scripts` in the person's file:

```powershell
$kit = (Get-Content -Raw (@($env:{{kit.configVar}}, "$env:LOCALAPPDATA\{{kit.name}}\config.json") | Where-Object { $_ })[0] | ConvertFrom-Json).scripts
# $kit.setup, $kit.test, $kit.secret, $kit.brief, $kit.chief,
# $kit.delivery (whether a ticket reached each environment; needs cd), and one per capability that is on:
# $kit.board, $kit.repo, $kit.ci, $kit.cd, $kit.chat, $kit.specs
```

| Command | Does |
|---|---|
| `init [-Pack <folder>] [-Role <name>]` | Creates or refreshes the person's file: points it at these defaults and the pack, moves a version 1 file to version 2 (keeping a copy in `backup\` next to it), records `-Role` as `user.role`, records the scripts' paths and each capability's, reports the role and the team and personal files. Safe to re-run. |
| `roles` | The pack's roles: name, title, description, views, the values each sets, and which is the person's (`current`). Empty for a pack without roles. |
| `provider -Capability <c>` | The provider a capability uses, whether it is on, its folder, and its notes (read them before using a provider-specific command). |
| `show [-Effective]` | The person's file, or the merged result. |
| `get -Key a.b` | One merged value. |
| `set -Key a.b -Value v` | Sets a value. `-AsJson` for a JSON value inline, `-ValueFile <file>` for objects and lists (write the file with the Write tool). Refuses `kit.*` and `version`. |
| `unset -Key a.b` | Removes the person's value, so the kit default applies again. |
| `preset -Name <name>` | Copies `board.viewPresets.<name>` into `board.views`. For a pack without roles; with roles, `set -Key user.role` instead. |
| `guides` | Where each writing guide is: the team's and the person's own. |
| `tools`, `repos`, `env` | Checks: PowerShell 7, git, curl; the configured and found clones; which credential variables are set (never their values). |
| `set-env -Name -Value` | Sets a user variable that is not a secret. Refuses the token variables. |

## The steps

Talk to the person in their language (`user.language`; ask on the first run). Re-running `/setup` repeats the checks and asks only what is missing or what the person wants to change; say what is already fine in one line and move on. Use AskQuestion for every choice.

### 1. Tools

`pwsh` must exist (PowerShell 7). If `Get-Command pwsh` finds nothing, ask the person to install it (`winget install Microsoft.PowerShell`), reopen Cursor, and run `/setup` again. Then `tools`: each line must say `ok: true`.

### 2. Configuration file

`init`. Check that every skill in `skills` says `installed: true`. A missing one means the kit was copied incompletely: tell the person to run the kit's `Install.ps1` again.

### 3. Board credentials

`env` lists the credential variables of every provider that is on (from their manifests), whether each is set, and whether it is a secret. With Jira Cloud (`jira-cloud`), the board needs an e-mail and a token:

1. The e-mail variable (`providers.jira-cloud.emailVar`) and the token variable (`providers.jira-cloud.tokenVar`).
2. E-mail: ask for the e-mail they sign in to Jira with, then `set-env -Name <emailVar> -Value <email>`.
3. Token: the person creates one at the page in `providers.jira-cloud.tokenHelpUrl` and saves it **himself, in his own terminal**:

   ```powershell
   pwsh -NoProfile -File "<full path of $kit.secret>" -Name <tokenVar>
   ```

   Give that command with the real path and variable name filled in, and wait for the person to say it is done. Never ask for the token in chat, never put it in a command, and never run the secret script yourself (it refuses when it is not run by a person). If the person pastes a token in the chat anyway, tell him to revoke it on that page and create a new one: it is now in the conversation log.
4. Check: `pwsh -NoProfile -File $kit.board me`. On success, record who it is: `set -Key user.name`, `user.email` and `user.boardAccountId` (the account id `me` prints).
   - Exit `3` with "refused": a wrong or expired token, or a token the API address does not accept. Try the site address once: `me -ApiBase <providers.jira-cloud.site>`. If that works, `set -Key providers.jira-cloud.apiBase -Value <site>`. Otherwise ask the person to create the token again.
   - Exit `3` "unreachable": network or VPN.
   - A program started before the variables were set does not see them; the scripts also read the person's saved variables, so this only matters for other tools.

### 4. VPN

When the ci capability is on: `pwsh -NoProfile -File $kit.ci ping`. Exit `3`: the CI is only reachable on the company network or VPN. Say so; the board may work without it, the CI and the repositories may not. Continue the setup and re-check at the end.

### 5. Repositories

`repos -Apply` searches the machine for clones of each repository the configuration lists in `repos` (the pack names them: usually the code repository, `paths.codeRepo`, and, when the specs capability is on, the specification repository, `paths.specsRepo`); each entry says what uses it (`uses`). It recognizes a clone by where its `origin` points, not by the folder's name, so a clone renamed or kept anywhere under the search roots is found (`discovery.roots`, `discovery.depth` levels down, skipping `discovery.skip` and hidden folders; worktrees are ignored). It takes a few seconds. For each repository:

- `configuredOk: true`: keep it; say where it is.
- `applied: true`: nothing valid was configured and exactly one clone was found, so it was recorded. Tell the person which folder will be used, and that they can change it.
- Several in `found`: AskQuestion which one to use (show each path), then `set -Key <key> -Value <path>` (the `key` it printed).
- None found: ask whether they have a clone somewhere the search does not reach (ask for the path), want one, or want to skip it. Say what needs the clone (`uses`). The clone address is `cloneUrl`:
  - code repository: whether a ticket's changes are merged, published, and on each instance (`$kit.delivery ticket` and `deployed`). Without it, `$kit.cd environments` and `$kit.ci status` still work. A partial clone is enough and much smaller, because those commands read only the history:
    `git clone --filter=blob:none --no-checkout <cloneUrl> <folder>`
  - specification repository: the story spec files, the basis for writing test cases. A normal clone: `git clone <cloneUrl> <folder>`.
  Give the person the clone command to run in his own terminal (it may ask for Bitbucket credentials), then record the folder with `set`.

### 6. The person's board

The views decide what the other skills show, so they must match the person's real work; do not assume a role from a job title.

`roles` lists the pack's roles (a pack ships one `roles\<name>.json` per role: its title, description, views, and other values such as `user.pullRequests`, listed in `sets`). The role file is read between the pack and the person's own file, so the person gets the team's views for that role without copying them, and later pack updates reach them.

**When the pack has roles:**

1. If the person already has one (`current: true`, set by `Install.ps1 -Role` or an earlier run), run every view (`view -Id <id>`) and show the counts in one short list. Say which role it is (its title), that the views come from the team's pack, and ask only whether they fit. Do not run `discover` when they do.
2. If the person has none, or says it does not fit: look at their real work (`discover`, and `footprint` for detail, as described below), summarize it in plain words, propose the role whose description matches, then `set -Key user.role -Value <name>` and run the views as in 1.
3. If the person's own file has `board.views` (an earlier `preset` copied them), those hide the role's. Show both lists; when they are the same, offer `unset -Key board.views` so the role's views apply and follow updates.
4. A view only this person wants: write the full list with the Write tool and `set -Key board.views -ValueFile <file>`. It replaces the role's list for them, and updates to the role's views stop reaching them; say so. A change the whole role would want belongs in the pack: propose it ("Proposing a change to the kit").

**Looking at the person's work** (a pack without roles, or a role to choose):

1. `pwsh -NoProfile -File $kit.board discover -Days 180 -Json`: who the token is, and each project the person worked in (as assignee or reporter) with its issue types counted, its statuses with their category (todo, inProgress, done), and its boards. Any board provider answers this the same way.
2. For the detail of who did what in which status, the Jira provider also has `footprint -Days 180 -Json` (counted by project, issue type and status, as assignee and as reporter).
3. If their main project is not `providers.jira-cloud.project`, ask, then `set -Key providers.jira-cloud.project`. If the project has several boards, ask which one they plan with (`set -Key providers.jira-cloud.board -Value <id> -AsJson`).
4. Summarize in plain words what they do ("you write test cases: 103 tests in Draft, 2 test sets; you file bugs"), and propose the role (or, in a pack without roles, the preset from `board.viewPresets`) that matches, for example:
   - writes test cases (reporter of tests and test sets): `qa-authoring`;
   - runs tests or reviews stories in QA (assignee of stories in a QA status, of test executions): `qa-execution`;
   - develops (assignee of stories in implementation): `dev`.
5. In a pack without roles: `preset -Name <name>`, then run every view (`view -Id <id>`) and show the counts. Offer to adjust: drop a view, change statuses (for example a tests view that should include `Defined`), add one for a status or issue type the footprint showed and no view covers. Write the full list with the Write tool and `set -Key board.views -ValueFile <file>`. A view (`query` is in the board provider's language: JQL for Jira):

   ```json
   { "id": "tests-draft", "title": "shown to the person", "query": "project = {project} AND reporter = {me} AND status = Draft ORDER BY updated DESC",
     "fields": ["summary", "status", "updated"], "max": 20, "qaCheckStatuses": [] }
   ```

   - Placeholders: `{project}` (`providers.jira-cloud.project`), `{me}` (the person's account id, `user.boardAccountId`), `{board}` (`providers.jira-cloud.board`). Inside JQL use single quotes, not double: `status = 'In Review'`.
   - `qaCheckStatuses`: for issues in these statuses, a brief checks whether the instance testers use already has the change (`"*"` for every status, `[]` for none).
   - `"linkedTests": true` (optional): the brief counts each issue's linked tests by status. Use it for stories the person writes or runs tests for.
   - `title` is shown to the person: write it in their language.
   - Every view must run with exit `0`; exit `1` says "check the JQL".
6. In a pack without roles: `set -Key user.role -Value <preset name or a few words>`.

### 7. Pull requests

When the person's role sets `user.pullRequests` (`roles` lists it in the role's `sets`), do not ask: say what the role decided, and change it only if the person says otherwise. Otherwise ask whether they open or review pull requests. `set -Key user.pullRequests -Value true|false -AsJson`. Only when true, and when the repo capability is on, the code host's token is needed (`env` lists it as needed; for Bitbucket Server, `providers.bitbucket-server.tokenVar`): the person creates it in Bitbucket (profile, HTTP access tokens, read access) and saves it with the secret script as in step 3.

### 8. Brief

1. `pwsh -NoProfile -File $kit.brief check`: the sections the brief will show, the views it reads, and the instance testers use (`delivery.qaEnvironment`). Sections with `"requires": "user.pullRequests"` appear only when step 7 turned pull requests on; sections with `"capabilities"` only when those capabilities are on.
2. Run the brief once (`pwsh -NoProfile -File $kit.brief`) and show it, so the person sees what `/brief-me` gives. The first one says there is nothing to compare with yet.
3. Offer changes, each through this script: the order or set of sections (`brief.sections`, a list written with the Write tool and set with `-ValueFile`), a view (step 6), or a text. Texts are best changed in the person's own template rather than the kit's, because it never needs merging: the check prints the team's file (`template.team`) and where the person's goes (`template.minePath`; `$kit.chief check` does the same for `/chief-of-staff`). Create it with the Write tool holding only the changed texts, each starting with the same `<!-- @name -->` line as in the team's template.

### 9. Test

`pwsh -NoProfile -File $kit.test`. Report in plain words what works and what does not, and what the person can do about each warning (connect the VPN, clone a repository). Then tell them what they can ask now: `/board`, `/ci`, `/brief-me`, `/chief-of-staff`, and writing a chat message to a colleague (each only when its capability is on).

## Updating the kit

A new copy of the kit is installed with its `Install.ps1` (with `-Pack <the project pack's folder>` when the kit was installed with a pack; it refuses without it, so the pack is not lost), which runs `init` at the end. A skill the new version no longer ships (renamed or removed) is moved to the backup folder, and the installer says where. The person's file, people, notes, own templates and the state folder are not touched. Each installed file the person did not touch is replaced; one they edited is kept; one they deleted is not created again; `defaults/config.json` is always replaced (an edited copy is backed up, and the installer says where). When the person edited a file the kit also changed, the new version is left next to theirs as `<name>.kit-new<ext>` and the file is a pending merge. After an update, run `pwsh -NoProfile -File $kit.test`; a new required value and every pending merge show there.

### 10. Update

Run this step after an update, when the test lists a merge, or when the person asks.

1. `changes` lists, per skill, the files the person edited (`edited`), the pending merges (`pending`: for each, `original` is the kit version their file started from, `mine` their file, `new` the kit's new version) and the files they deleted. Say in one line what is edited and that it is kept.
2. For each pending merge: read the three files. Say in plain words what the person changed (original against mine) and what the kit changed (original against new). Propose the merged file: the kit's changes plus the person's, and where both touched the same part, say so and ask which to keep. When `original` is empty (no record of it), compare only mine and new, and ask more.
3. Show the merged file, or for a long one the parts that differ from `new`, and wait for a yes. Then write it over `mine` with the Write tool and run `merged -Skill <skill> -Path <file>`, which records it and removes the `.kit-new` file. If the person wants to keep their file as it is, or take the kit's as it is, write that one instead and run the same command.
4. If the edited file was `defaults/config.json` (the installer printed where the old one was saved), compare the saved copy with the new one and move each value the person had changed into their own file with `set`, after a yes.
5. Run the test again.

| Command | Does |
|---|---|
| `changes` | Edited files, pending merges and deleted files of each installed skill. Needs no configuration. |
| `merged -Skill <skill> -Path <file>` | Records a resolved merge: the file in place is the person's final version, the new kit version becomes its original. |

## Proposing a change to the kit

When the person has something that would help everyone (or asks to propose a change):

1. Find what it is with them: a kit file they edited (`changes` lists them), sections of their own template or guide, a row of their people or notes file, or a value of their configuration (for example a view that could join a preset).
2. Ask, in plain words, what changed, the problem it solved, and how they used it. These go in the entry exactly as the person means them, in their language.
3. Run one of:

   ```powershell
   pwsh -NoProfile -File $setup propose -Topic "<few words>" -What "<what changed>" -Why "<the problem>" -How "<how they used it>" -Skill <skill> -Path <file>
   pwsh -NoProfile -File $setup propose -Topic ... -What ... -Why ... -How ... -Source <their own file> [-Section name1,name2]
   pwsh -NoProfile -File $setup propose -Topic ... -What ... -Why ... -How ... -Key <a.b>
   ```

   It prints the folder (`proposal`): the change (`change.patch`, `proposed.md` or `proposed-value.json`) and `LOG-entry.md`. Show the person `LOG-entry.md`.
4. Tell them to send that folder to whoever maintains the kit, who decides and records the decision in the kit's `LOG.md`. Offer to write the message with the `chat` skill (ask who maintains the kit if you do not know). Nothing is sent by itself.

| Command | Does |
|---|---|
| `propose ...` | Writes a proposal folder in `paths.proposals`: the change and its `LOG-entry.md`. |
