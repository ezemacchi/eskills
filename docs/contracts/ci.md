# ci

Builds: the latest build of a pull request, a branch or a named job, its stages, the end of its log,
and finding a job. Optional: `/ci` needs it.

Provider today: `jenkins` (Jenkins JSON API and the pipeline stage view, anonymous read).

## Commands

| Command | Output with `-Json` |
|---|---|
| `status [-Pr n \| -Branch b \| -Job name] [-Build n]` | build, below |
| `stages [same target]` | no `-Json`; for the person |
| `tail [same target] [-Lines n]` | no `-Json`; the end of the log |
| `find <text>` | `[ { job, open, result, title } ]` |
| `ping` | `{ reachable: true, root }` |

A build:

```json
{ "target": "PR-875", "build": 12, "result": "SUCCESS",
  "started": "ISO 8601", "minutes": 14, "commit": "sha",
  "cause": "...", "version": "1.2.3 or null",
  "stages": [ { "name": "Build", "status": "SUCCESS", "minutes": 3 } ],
  "quickFailure": "hint or null", "link": "https://..." }
```

- `result` is `SUCCESS`, `FAILURE`, `UNSTABLE`, `ABORTED`, `NOT_BUILT` or `RUNNING`.
- `version` is the version a named job (a release job) published, when it publishes one.
- `quickFailure` is a hint, in a sentence, when a build died in under a minute before any stage ran,
  else `null`. For Jenkins the text is `providers.jenkins.quickFailureHint`, which a project pack sets
  to its usual cause.
- Named jobs (`-Job <name>`) are the provider's configuration (`providers.jenkins.jobs`).

## v1 (before the contract)

- These were the generic half of `jenkins.ps1`, together with the project's deployment commands.
- `quickFailure` was true or false, and the text printed with it named a project rule file.
- `-Job` took the publish jobs of the deployment configuration; `version` read their `VERSION`
  parameter, then the build's display name.
