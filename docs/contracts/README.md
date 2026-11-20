# Provider contracts

The kit is an engine plus providers. The engine (setup, the brief, the next-steps planner, the
delivery check, the write guard, templates, install and update) never talks to a service. It runs a
provider script and reads its JSON. A provider implements one capability for one service.

| Capability | What it answers | Provider today | Contract |
|---|---|---|---|
| board | tickets: saved views, one ticket and its links, comments, moving a ticket | Jira Cloud | [board.md](board.md) |
| repo | pull requests, their checks, quality report, merge check, the merge commit of a pull request | Bitbucket Server | [repo.md](repo.md) |
| ci | builds: status, stages, log, find a build | Jenkins | [ci.md](ci.md) |
| cd | environments: which version each runs, which commit a version is | Jenkins publish and deployment jobs (`jenkins-deploy`) | [cd.md](cd.md) |
| chat | people and a message ready to send, which the person sends | Microsoft Teams | [chat.md](chat.md) |
| specs | the specification files of a ticket | files in a git repository (`git-files`) | [specs.md](specs.md) |

[delivery.md](delivery.md) is not a capability: it is the engine's answer to "does environment X have
the change of ticket K, and if not, from which version will it", built from board, repo, cd and git.

Every capability except board is optional. A person, or a project pack, turns a capability off and
everything that needs it is skipped: brief sections, next-step rules, checks in `Test-Kit.ps1`.

## Rules every provider follows

- **One script per provider**, run as `pwsh -NoProfile -File <script> <command> [-Param value] [-Json]`.
  The first positional argument is the command.
- **`-Json`** prints one JSON document on standard output and nothing else. Without `-Json` the
  output is for a person and may change freely; consumers never parse it.
- **Exit codes**, the same in every script of the kit:

  | Code | Meaning |
  |---|---|
  | 0 | ok |
  | 1 | bad input, or the service refused the request for a reason in the request (not found, invalid query, a write refused by a safety check) |
  | 2 | missing configuration or credentials: the person runs `/setup` |
  | 3 | the service could not be reached or refused the credentials |

- **Errors go to standard error**, in plain words. With exit 3 the first line starts with `refused:`
  (the service answered and rejected the credentials) or `unreachable:` (no answer: network, VPN,
  service down). The brief tells the person which one.
- **Never print, log or echo a secret.** Credentials come from the variables named in the
  provider's manifest; the error text never includes the request.
- **Writes** (a comment, a status change, anything that changes the service) happen only after the
  person has seen exactly what will be done and said yes. Each write appends one line to the write
  log (`paths.stateDir`, file named by `providers.<name>.writeLog`), and the write guard (a hook that
  asks the person before any write) knows the provider's hosts and write commands.
- **Configuration** is read through the kit-config block every script carries (identical in all of
  them; `Test-Kit.ps1` checks it). A provider reads only its own keys and the common ones it declares.

## The manifest: provider.json

Each provider folder holds `provider.json`. Providers live in `skills/setup/providers/<capability>/<name>/`
in the kit and in `providers/<capability>/<name>/` in a project pack; the pack's wins for the same name.

```json
{
  "contract": 1,
  "name": "jira-cloud",
  "displayName": "Jira",
  "capabilities": ["board"],
  "script": "Invoke-Jira.ps1",
  "commands": ["me", "view", "issue", "comments", "comment", "edit-comment", "transition", "notes"],
  "config": ["site", "apiBase", "emailVar", "tokenVar"],
  "secrets": [{ "key": "emailVar", "secret": false },
              { "key": "tokenVar", "secret": true }],
  "keyPattern": "^[A-Z][A-Z0-9]+-\\d+$",
  "notes": "reference.md"
}
```

- `contract`: the version of the capability contract the provider implements.
- `capabilities`: the capabilities it implements. One script may serve several: a code host often has
  pull requests, builds and deployments (repo, ci and cd) behind one API.
- `script`: the script, relative to the folder, or `null` while the engine still calls the service
  itself (a provider being moved out of the engine).
- `commands`: the contract commands it implements. A consumer that needs a missing command treats the
  capability as off for that use and says so.
- `config`: keys under `providers.<name>` it needs; `Test-Kit.ps1` checks they are set. The values
  live in the configuration (the kit's defaults for what every project shares, the pack for the rest).
- `secrets`: the configuration keys under `providers.<name>` that name the variables it reads
  credentials from; `secret: false` for a value that is not a secret (an e-mail), `when` for a
  configuration key that must be true for it to be needed. `/setup` and `Test-Kit.ps1` use this list.
- `keyPattern` (board only): what a ticket key looks like. The engine uses it to validate keys and to
  find a ticket's commits.
- `notes`: a Markdown file for the agent, about what is particular to this service. `/setup`'s
  `provider -Capability <c>` prints it.
- `names`: labels the engine's texts use, each naming the configuration key under `providers.<name>`
  that holds it (the repo provider's `quality`, for example: the quality tool the person knows).
- `linkPattern` and `guard` (board): see [board.md](board.md).

`init` keeps what the engine needs from each manifest, with the configuration filled in, as
`providerInfo.<capability>` in the person's configuration: the display name, the key pattern, the
ticket link, the labels, the credential variables and what the write guard watches.

A capability is on when `capabilities.<name>.provider` names a provider and `enabled` is not `false`.
`init` records the script of each capability that is on as `scripts.<capability>`, which is what the
skills run.

## Versions

A contract changes only by adding: new optional commands, new optional fields. A field is never
renamed or removed within a version. A breaking change is a new `contract` number, and the engine
says which providers it can run.
