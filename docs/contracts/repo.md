# repo

Pull requests on the code host: the person's open and merged pull requests, the checks on a commit,
the quality report, whether a pull request can merge, and which commit merged it. Optional: the
brief's pull-request, merged and worktree sections need it.

Provider today: `bitbucket-server` (Bitbucket Server REST 1.0, a personal access token).

Git itself is not part of this contract. The engine runs git in the person's clone (`paths.codeRepo`)
for fetch, ancestry, ahead and behind counts and worktrees; every code host speaks git.

## Commands

| Command | Output with `-Json` |
|---|---|
| `prs -State open\|merged [-Max n]` | `[ pullRequest ]`, the token owner's as author |
| `checks -Commit <sha>` | `[ { key, state, url, build, pullRequestBuild } ]` |
| `quality -Commit <sha> -Repo <slug> -Project <key>` | `{ result, name, link, details: [ string ] }` or `null` |
| `mergeable -Pr <id> -Repo <slug> -Project <key>` | `{ conflicted, vetoes: [ string ] }` |
| `merge-commit -Pr <id> -Target <branch>[,<branch>] [-Clone <folder>]` | `{ pr, commit, target, subject }`; `commit` is `null` when not found |

A pull request:

```json
{ "id": 875, "title": "...", "link": "https://...",
  "repo": "app", "project": "PRJ", "primary": true,
  "source": "feature/abc-12-thing", "target": "main",
  "latestCommit": "40-char sha",
  "reviewers": [ { "name": "...", "state": "approved" } ],
  "closedAt": "ISO 8601 or null" }
```

- `primary` is true for the project's code repository (the one cloned in `paths.codeRepo`). The brief
  counts behind commits and lists merged pull requests only for it.
- `reviewers[].state` is `approved`, `needsWork` or `none`.
- `checks[].state` is `success`, `failed` or `running`, else the host's own word. `key` is the check's
  own name. `pullRequestBuild` marks a build of a pull-request job, which the brief prefers over the
  others. `build` is the CI build number when the check's address carries one.
- `quality.result` is `pass` or `fail`, else the host's own word. `name` is what the person calls the
  tool (Sonar), `details` the report's lines without decoration. `null` when the commit has no report.
- `merge-commit` finds the commit that merged the pull request into one of the targets, from the
  clone's history. The host knows its own merge-message format; the engine does not guess it. It
  does not fetch: the caller fetches first. `target` is the first of the given branches that contains
  the commit.

The manifest's `names.quality` names the configuration key that holds the quality tool's name; `init`
puts it in `providerInfo.repo.names.quality`, and the brief's texts use it as `{{quality}}`.

Errors: no token is exit 2. A refused token is exit 3 with `refused:`, no answer is exit 3 with
`unreachable:`; after either, the brief does not call the provider again in the same run. Any other
failure of one call (a merged pull request's merge check answers 409, for example) is that item's
missing value.

## v1 (before the contract)

- The brief called the Bitbucket REST API itself:
  - `/rest/api/1.0/dashboard/pull-requests` for the open and merged lists;
  - `/rest/build-status/1.0/commits/{sha}` for checks;
  - `/rest/insights/1.0/.../reports/{key}` for the quality report;
  - `.../pull-requests/{id}/merge` for the merge check.
- Reviewer states were `APPROVED` / `NEEDS_WORK`, build states `SUCCESSFUL` / `FAILED` /
  `INPROGRESS`, quality results `PASS` / `FAIL`, and `closedDate` was in epoch milliseconds.
- The brief chose the pull-request build by the Jenkins job naming (`/PR-<n>`) itself.
- `jenkins deployed` found the merge commit with
  `git log --grep "Pull request #<n>:" --grep "Merge pull request #<n> in "` (Bitbucket's two formats).
