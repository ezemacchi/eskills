# Team skills kit

Agent skills for working with a team's ticket board, code host, CI/CD and chat, for anyone on the team (QA or development). They run in Cursor and in Claude Code. The kit is an engine; each project brings a pack with its own values (which service it uses for what, their addresses, its people, its notes). Each person sets the kit up for themselves with `/setup`.

Everything a project may have is a **capability**, and each capability is implemented by a **provider**:

| Capability | What it is | Providers today |
|---|---|---|
| board | tickets: saved views, one ticket and its links, comments, status changes | Jira Cloud |
| repo | pull requests, their checks, review, merge | Bitbucket Server |
| ci | builds: status, stages, log | Jenkins |
| cd | environments: which version each runs, what gets published | a project's own provider, in its pack |
| chat | a message to a colleague, which the person sends | Microsoft Teams |
| specs | a ticket's specification files | a project's own provider, in its pack |

A capability the project does not have is off, and whatever needs it does not appear. What a provider must do is written in [`docs/contracts`](docs/contracts/README.md); adding one is in [`CONTRIBUTING.md`](CONTRIBUTING.md).

| Skill | What it does |
|---|---|
| `/setup` | The center. Sets the kit up for the person: credentials, clones, which capabilities they use, and what the other skills show based on what they do on the board. Can be run again to change anything. |
| `/board` | Reads the board with the person's token: what is pending (their saved views), what a story asks and where its specification is, its tests, comments and history. Comments or moves a ticket only after the person approves exactly what will be done. |
| `/ci` | How a build is going and why it failed, which version each environment runs, and whether a ticket already reached the environment testers use (and if not, from which version it will). |
| `chat` | Writes a message to a colleague following their profile and opens the chat with it ready. It never sends; the person does. |
| `/brief-me` | The person's brief: what needs them, what changed since the last brief, their board views, whether the test environment has each ticket's change, which version each environment runs, and for people who work with pull requests, their open and merged pull requests and worktrees. Read-only. |
| `/chief-of-staff` | "What do I do now?": from the brief, proposes what to do with each ticket, in order and with the reason, and does what the person picks (test, comment, message the developer, write or finish tests), each step only after a yes. |

## Requirements

- Cursor or Claude Code, on Windows (other systems are not supported yet).
- PowerShell 7 (`winget install Microsoft.PowerShell`), git and curl.
- The credentials of the project's services, for example a Jira API token. `/setup` explains how to create it; the person saves it in their own terminal, never in a chat.
- A pack for the project (see "Writing a pack").

## Install or update

```powershell
git clone https://github.com/ezemacchi/eskills.git
pwsh -NoProfile -File .\eskills\Install.ps1                    # Cursor
pwsh -NoProfile -File .\eskills\Install.ps1 -AgentHost claude  # Claude Code
```

Then restart the agent and run `/setup`. Without a project pack, `/setup` asks for it (a zip or a folder your team gives you; drag it into the chat or say where it is) and installs it with `add-pack`, which puts it in the clone's `packs\` folder and installs the kit again. git ignores `packs\`, so a private pack kept there is never committed. You can also put packs there yourself before installing, or pass folders elsewhere with `-Pack`.

**Several projects.** Each project has its own pack, and they are installed side by side. The kit uses the pack whose repositories include the folder it runs in (any clone or worktree of the project), else your default (`/setup` asks), else the only one; each project keeps its own configuration. Adding another project is another `add-pack`.

`-Role` is optional, for a single pack: one or more of its roles (`roles\<name>.json`), separated by commas, the main one first (`-Role dev,qa`). With it, the person starts with their roles' views and settings. Without it, `/setup` looks at their work on the board and proposes roles.

It copies the skills to the agent's skills folder (`.cursor\skills` or `.claude\skills`), with the packs inside the setup skill (`setup\packs\<name>`). A skill every pack's capabilities turn off is not installed, and a kit skill a new version no longer ships is moved to a backup. A folder with the same name that is not the kit's stops the install; `-Force` moves it to a backup first. An update installs every pack in `packs\` and stops if a pack already installed is missing, so it is not lost. The kit always keeps its name (`eskills`): one configuration folder, one write guard.

It also installs a write guard: a hook the agent runs before every shell command and every MCP tool, which asks the person before any write to a project service, whether through the provider's script, a direct call to the service's address, or an MCP tool that writes. What it watches comes from each active provider's manifest. In Cursor it is added to `.cursor\hooks.json`; in Claude Code to `.claude\settings.json` (PreToolUse groups that block when the hook fails; when there is nothing to ask the hook answers nothing, so Claude Code's own permissions apply). Everything else in the file is kept, and the file is backed up first. `-HooksFile <another path>` tries the install without touching yours.

The guard is a net, not a lock: it does not see an address kept in a variable by an earlier command, or a script written first and run later. So the skills still say that services are not called by hand, and that every write is shown and waits for a yes before it reaches the guard.

Updating keeps the person's configuration, people and notes, and any kit file they edited in their copy: if the kit changed it too, `/setup` proposes how to merge them.

## Where things live

The configuration has four layers, each winning over the one before:

- **Kit values**: `skills/setup/defaults/config.json`. What every project shares (providers start unchosen). Replaced on update.
- **Project values**: the pack's `pack.json` (installed in `setup\packs\<name>`). What everyone in the project shares: which provider each capability uses, their addresses, ids and patterns (under `providers.<name>`), the planner's rules. The pack also brings the team's people and notes (`people.md`, `notes.md`).
- **Role values**: the pack's `roles\<name>.json` for each of the person's roles (`user.role`). What everyone in one role shares: the saved views, whether they work with pull requests. Read, not copied, so a pack update reaches everyone in the role. With several roles, the person gets the views of all of them (the first role's when two share an id) and every other value from the first role that sets it.
- **The person's values**: one file per project, `%LOCALAPPDATA%\eskills\<pack>\config.json`. Only what differs for them in that project: usually their identity and where their clones are.

And:

- **Providers**: folders with a `provider.json` (capabilities, script, credentials), in `skills/setup/providers/` or in the pack.
- **Texts** of the brief and the planner: templates per language in `skills/setup/defaults/templates/`; a person's own template holds only the texts they change.
- **Writing guides** for board comments and chat messages: `skills/setup/defaults/guides/`; a person's own guide holds only the sections they change.
- **State** (the last brief, what was checked, what the person decided per ticket) and **the write log**: in `paths.stateDir`.
- **Credentials**: user environment variables. No script prints a token.

## Writing a pack

A pack is a folder with:

- `pack.json`: the pack's name (`pack.name`: letters, digits, `-` and `_`; it names the project's folder and configuration), the repositories that tell the kit it is in this project (`repos`, each with its `name` and `cloneUrl`), the provider of each capability, their values under `providers.<name>`, the planner's rules (`chief.rules`) and any actions of its own (`chief.actions`: a label and a proposal per language, the capabilities they need, and a `how` that tells the agent how to carry them out), the test environment (`delivery.qaEnvironment`), and lint patterns that keep the project's values out of the kit;
- `roles/<name>.json`, one per role in the project: a title and description for `/setup` (`role.title`, `role.description`) and the values everyone in that role shares, usually `board.views`, `user.pullRequests` and which planner actions the role uses (`chief.use`: `{ "<action>": true }`; the planner then applies only the rules whose action the person uses). A pack without roles can ship view presets instead (`board.viewPresets`), which `/setup` copies into each person's file;
- `people.md` and `notes.md`: the team and what the skills need to know about the project;
- optionally `templates/` or `guides/` files that replace the kit's, and `providers/<capability>/<name>/` for a service no kit provider covers. Prefer configuring a kit provider: most of what makes a project different (a code pattern, a log line, an address) is a value, and a pack with only values is just configuration.

[`examples/pack`](examples/pack) is a complete example with invented values. Keep a real pack private: it holds internal addresses and the team's e-mails.

## Proposing a change

When a person changed something that would help everyone (a kit file they edited, a text of their own template or guide, a view), their agent can propose it: `/setup` builds a folder with the change and an entry saying what changed, why and how it was used. Decisions are recorded in [`LOG.md`](LOG.md). Changes to one project's values go to that project's pack.

## For maintainers

- A value that differs between people, projects or environments goes in the configuration, never in a script or a `SKILL.md`. `Test-Kit.ps1 -Static` fails on one outside `setup/defaults` (addresses, absolute paths, GUIDs, field ids); `-Pack <folder>` adds the pack's own patterns.
- Every script has the same configuration block between `# kit-config:start` and `# kit-config:end`, and scripts that write from a template the same template block; change one, copy it to all. The test checks both, and that every text a script uses exists in every language.
- The kit's name (`eskills`, from `kit.name` in the defaults; a pack cannot change it) is the text of each skill's `.kit` file. From it come the person's folder (`%LOCALAPPDATA%\<name>`, or `<NAME>_HOME`), one subfolder per project pack (written `{kitHome}` in paths), and the variables `<NAME>_CONFIG` (one configuration file, for tests and tools) and `<NAME>_PACK` (the project in use, instead of the current folder's repository). `SKILL.md` files say `{{kit.name}}`, `{{kit.configVar}}` and `{{kit.setupScript}}`, which `Install.ps1` fills in. What only works on Windows is in three functions of the block: `Get-KitRoot`, `Get-KitEnv`, `Set-KitEnv`.
- Installed files may be edited: `Install.ps1` records each file's hash (`.kit-installed.json`) and a copy of the kit's version; an update replaces untouched files, keeps edited ones (leaving the new version beside as `<name>.kit-new<ext>` when the kit changed it too) and never recreates a deleted one.
- Between skills the contract is the `-Json` output, never the text. Exit codes everywhere: 0 ok, 1 bad input, 2 missing configuration or credentials, 3 the service refused or did not answer.
- Tests: `Test-Kit.ps1 -Static` (the kit's files), `Test-Kit.ps1 -Fake` (the whole engine against the fake provider, with no account and no network), and `Test-Kit.ps1` with a real configuration (each active capability against its service). To try a configuration without touching yours: set `<KIT_NAME>_CONFIG` to another file and run `Initialize-Config.ps1 init -Pack <folder>`; to try an install, point `<KIT_NAME>_HOME`, `-Target`, `-HooksFile` and `-StateRoot` at a temporary folder (`-Fake` does).

- Publishing a copy: `tools/Export-Public.ps1 -Destination <empty folder> -Name <public name> -Pack <each project's pack>` copies the tracked files with no git history, renames the kit, and scans the copy for the packs' `publish.scanPatterns`, e-mail addresses, GUIDs and token shapes. It does not create a repository or push.

## License

MIT. See [LICENSE](LICENSE).
