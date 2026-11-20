# delivery (engine)

"Does environment X have the change of ticket K, and if not, from which version will it?" and the same
for a merged pull request. This is engine logic, not a provider. It joins:

- **board**: the ticket key, the key pattern, and the links to follow when the ticket has no commits;
- **git**, in the person's clone: commits whose message names the key, branches named after it, the
  first version tag that contains a commit, and ancestry;
- **repo**: the merge commit of a pull request;
- **cd**: each environment's version and branch, and the commit of a version.

## Commands (script `skills/setup/scripts/Get-Delivery.ps1`, `scripts.delivery`)

| Command | Output with `-Json` |
|---|---|
| `ticket -Key <key>` | ticket delivery, below |
| `deployed -Pr <id>` | `{ pr, commit, merged, publishes: [ publish ], instances: [ instance ] }` |

Ticket delivery:

```json
{ "key": "ABC-12",
  "branches": [ { "name": "origin/feature/ABC-12-x", "notOn": { "main": 2 }, "author": { "name": "...", "email": "..." } } ],
  "targets": [ { "branch": "main", "commits": 3, "newest": "sha", "newestDate": "yyyy-MM-dd",
                 "newestSubject": "...", "firstTag": "v1.4.2", "publish": { }, "author": { } } ],
  "instances": [ { "name": "qa", "version": "1.4.1", "verdict": "NOT_IN", "source": { },
                   "branch": "main", "firstVersion": "1.4.2" } ] }
```

- **Target branches** are the branches that get published (`cd targets`).
- **Publish** of a target: the cd provider's last successful publish of that branch (`cd publishes`),
  and whether it contains the newest commit.
- **Commits of a ticket**: `git log origin/<target> -E --grep "(^|[^0-9A-Za-z-])<KEY>([^0-9]|$)"`. The
  key must match the board's key pattern.
- **First version**: the oldest-created tag matching `delivery.tagPattern` (default `v*`) that
  contains the newest commit, without the tag's prefix.
- **Verdict** per environment: the version's commit (`cd environments`, `commit`), then
  `git merge-base --is-ancestor <newest> <versionCommit>`. The answer is `IN` or `NOT_IN`, else
  `UNKNOWN`. `NONE` means the ticket has no commits on any target branch.
- **Author** is the newest commit that is not a merge.

The brief calls `ticket` for each ticket whose status is in its view's `qaCheckStatuses`. Before
deciding `NONE`, it also calls `ticket` for the linked tickets whose link type is in
`brief.followLinks`.

## v1 (before the contract)

`jenkins ticket` and `jenkins deployed` did all of this inside the Jenkins script. They read the
environments from the publisher's log and found the merge commit with Bitbucket's message formats.
