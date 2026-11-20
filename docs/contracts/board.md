# board

Tickets: the person's saved views, one ticket with its links, comments, and moving a ticket to
another status. Required: every other part of the kit hangs off tickets.

Provider today: `jira-cloud` (Jira Cloud REST, email and API token).

## Configuration the engine owns

Saved views live in the person's configuration (`board.views`, set up with `/setup`), not in the
provider:

```json
{ "id": "tests-draft", "title": "Test cases I wrote, in draft",
  "query": "project = {project} AND reporter = {me} AND status = Draft ORDER BY updated DESC",
  "fields": ["summary", "status", "updated"], "max": 20,
  "qaCheckStatuses": [], "linkedTests": false }
```

- `query` is in the provider's own query language (JQL for Jira, a filter for another service). The
  provider fills its placeholders (`{project}`, `{me}`, `{board}` for Jira).
- `qaCheckStatuses` (`"*"` for every status) and `linkedTests` are read by the brief, not by the
  provider.
- View presets per role ship in the project pack, keyed by provider, because the query is the
  provider's language.

## Commands

| Command | Output with `-Json` | Read by |
|---|---|---|
| `me` | `{ id, name, email, active }` | `/setup`, `Test-Kit.ps1` (the token's owner against `user.boardAccountId`) |
| `view -Id <id>` | `{ id, title, more, issues: [ { key, link, <field>: string, ... } ] }` | brief |
| `issue -Key <key>` | ticket, below | brief (links and linked tests), the agent |
| `comments -Key <key>` | `[ { id, author, created, body } ]` | the agent |
| `comment -Key <key> -Body/-BodyFile` | `{ id, key, link, duplicate: false }` | the agent; write |
| `edit-comment -Key <key> -CommentId <id> -Body/-BodyFile` | `{ id, key, link, changed }` | the agent; write |
| `transition -Key <key> -To <status> [-Body/-BodyFile]` | `{ key, from, to, transition, comment, commentDuplicate }` | the agent; write |
| `discover [-Days n]` | `{ me: { id, name, email }, accountId, days, projects: [ { key, name, types: [ { name, count } ], statuses: [ { name, category } ], boards: [ { id, name, type } ] } ] }` | `/setup`, to propose views |

Rows of `view`:

- `key` and `link` (the ticket's web address) are always present.
- Each name in the view's `fields` is a property whose value is a display string: the status name,
  the person's display name, the priority name. `updated` and `created` are ISO 8601 strings.
- `more` is true when the view has more tickets than `max`.

The ticket from `issue`:

```json
{ "key": "ABC-12", "link": "https://...", "title": "...", "type": "Story",
  "status": "In Progress", "statusCategory": "inProgress", "priority": "Medium",
  "assignee": "...", "reporter": "...", "labels": [], "parent": "ABC-1",
  "updated": "...", "created": "...", "comments": 3, "description": "...",
  "links": [ { "type": "Relates", "direction": "outward", "label": "relates to", "key": "ABC-40",
               "kind": "Test", "status": "Draft", "statusCategory": "todo", "title": "..." } ] }
```

- Rows of `view` also carry `statusCategory` when the view's fields include `status`.
- A provider may add its own flag for its own JSON (`-Raw` for Jira). Nothing in the engine reads it.

- `statusCategory` is one of `todo`, `inProgress`, `done`. Every board has some grouping like it
  (Jira status categories, a Linear state type, an Azure DevOps state category).
- `links[].type` is the link type's name as the board shows it. `kind` is the linked ticket's type.
  The brief counts links whose `kind` is the configured test type as tests, and follows links whose
  `type` is in `brief.followLinks` to find a fix that has commits.

## Writes

- Exactly one of `-Body` / `-BodyFile`, not empty.
- `comment` refuses (exit 1) when an equal comment is already there. `edit-comment` refuses a comment
  the token's owner did not write.
- `transition` refuses when the ticket is already in the target status, when no move leads there,
  when the only move is an administrator's, or when several moves lead there. It never picks a move
  that leads back to the current status.
- Each successful write appends `{ at, key, action, to, commentId }` to the write log.
- The manifest's `guard` names the hosts and commands the write guard asks about.

## Ticket keys, links and the write guard

The manifest says three more things, which `init` fills with the provider's configuration and keeps
in the person's configuration as `providerInfo.board`, so the engine never reads a provider's keys:

- `keyPattern`: what a key looks like (`^[A-Z][A-Z0-9]+-\d+$` for Jira). The engine validates keys
  with it and finds a ticket's commits by searching commit messages for the key with word boundaries.
- `linkPattern`: the web address of a ticket, with `{key}` and the provider's configuration keys in
  braces (`{site}/browse/{key}` for Jira). The engine links tickets it did not get from a view with it.
- `guard`: what the write guard watches. `hosts` (configuration keys holding the service's
  addresses), `writeCommands` (the script's commands that write), `mcpWriteTools` (a configuration
  key holding the MCP tool names that write) and `mcpWritePattern` (for a tool not in the list).

## v1 (before the contract)

- `view -Id` already returned these rows. `jql` was the view's query key, and `jira.views` held the views.
- `issue`, `comments`, `comment`, `edit-comment` and `me` passed Jira's JSON through. The brief read
  `fields.issuelinks[].outwardIssue|inwardIssue`, `type.name`, `fields.issuetype.name` and
  `fields.status.name`.
- `discover` did not exist. `/setup` used `footprint`, `statuses` and `boards`, which remain as
  Jira-only commands.
- The key pattern was written into the brief, the planner and the Jira script, and links were built
  from the Jira site in each of them.
- The write guard knew only Jira's addresses and the Jira script.
