# cd

Environments: which version each environment runs, where that answer came from, which branch an
environment's versions are built from, which commit a version is, which branches get published, and
the last publishes. Optional: the brief's environment versions, its QA column and the delivery check
need it.

Provider today: `jenkins-deploy`, in the engine, for projects that publish versions with Jenkins
jobs and upgrade environments with a deployment job. What is particular to a project is configuration
(`providers.jenkins-deploy`): the publish jobs and their branches, the deployment job, regular
expressions for the lines of its log that name each environment's version (`deployLog`), for the
version in an environment's own address (`liveVersion`) and in a publish run's name
(`buildNameVersion`), and the environments. Other services that fit: Argo CD applications, Azure
DevOps environments, GitHub or GitLab deployments.

## Commands

| Command | Output with `-Json` |
|---|---|
| `environments [-NoCommit] [-Repo <clone>]` | `[ environment ]` |
| `targets` | `{ branches: [ string ], note }` |
| `commit-of -Version <v>` | `{ version, commit }`; `commit` is `null` when unknown |
| `publishes [-Runs n]` | `[ publish ]` |

An environment:

```json
{ "name": "qa", "version": "1.4.2", "branch": "main", "upgrade": "manual",
  "source": { "kind": "deploy-log", "ref": "123", "at": "ISO 8601" },
  "commit": "sha or null" }
```

- `version` is `null` when it could not be learned.
- `branch` is the branch this environment's versions come from, or `null`. The delivery check uses it
  to pick which of a ticket's target branches matters for the environment.
- `upgrade` is `auto` or `manual`, as configured.
- `source.kind` is `deploy-log` (a deployment job's log: `ref` is its run), `live` (the running
  environment reported its own version; `ref` is its address) or `config`. The brief writes it with
  its template.
- `commit` is the commit of `version` (as `commit-of` would answer), unless `-NoCommit`, which skips
  that work when only the versions are needed.

`targets.branches` are the branches that get published: the delivery check looks for a ticket's
commits on them. `targets.note` says, in a sentence for the person, how environments get upgraded.

A publish, the last successful run of one publishing job among its last `-Runs` runs:

```json
{ "job": "release", "branch": "main", "runs": 8, "build": 111,
  "version": "1.4.2", "displayVersion": "1.4.2", "when": "yyyy-MM-dd HH:mm",
  "commit": "sha", "cause": "...", "url": "https://...", "chart": "https://... or null",
  "publishingNow": null }
```

- `build` and the fields after it are `null` when none of the last `runs` succeeded.
- `version` is the version the run published; `displayVersion` the one its name shows (they differ
  only when the run was given a version by hand).
- `publishingNow` is the number of a run still publishing, else `null`.

Versions compare as dotted numbers after dropping any suffix that starts with `-`
(`1.4.2-rc` compares as `1.4.2`).

## v1 (before the contract)

These were the project-specific half of `jenkins.ps1`.

- `versions` returned `[ { name, version, source } ]`.
- `source` was text that the brief parsed: `publisher #N, yyyy-MM-dd HH:mm`, or text starting with
  `live`.
- Versions came from the deployment job's log lines and from the running environment's redirect.
- A version's commit was the `v<version>` tag, else the release job's build of that version.
- The publishing jobs, their branches and the instances were read by the brief from the Jenkins
  configuration.
