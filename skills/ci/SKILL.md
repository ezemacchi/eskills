---
name: ci
description: Reads the team's CI and deployments to answer how a pull request or branch build is going and why it failed, which version each test instance runs, and where a ticket stands - merged into its target branches, in which publish, and whether each instance (for example the one testers use) already has it, and if not from which version it will. Builds come from the ci provider (Jenkins today), instances from the cd provider. Invoke with /ci.
disable-model-invocation: true
---

# CI

## Scripts and configuration

Three scripts, all read-only, all set up with `/setup`:

- `$kit.ci`: builds (the ci capability; its provider, for example Jenkins, knows the addresses).
- `$kit.cd`: the environments, the version each runs, and the branches that get published (the cd capability; the project's provider).
- `$kit.delivery`: whether a ticket or a merged pull request reached each environment. The kit's own logic: git in the code clone, plus what the cd and repo providers say.

```powershell
$kit = (pwsh -NoProfile -File "{{kit.setupScript}}" scripts) -join "`n" | ConvertFrom-Json
pwsh -NoProfile -File $kit.ci <command> ...         # status, stages, tail, find, ping
pwsh -NoProfile -File $kit.cd <command> ...         # environments, targets, publishes, commit-of
pwsh -NoProfile -File $kit.delivery <command> ...   # ticket, deployed
```

| Command | Does |
|---|---|
| `delivery ticket -Key <KEY>` | Where a ticket stands: branches named after it, its commits on each target branch, the first version tag that has it, whether the last publish of each target has it, and whether each environment runs a version that has it. |
| `delivery deployed -Pr <n>` / `-Commit <sha>` | Whether a merged pull request (or a commit) is in the last publishes and on each environment. |
| `cd environments` | The version each environment runs, where that came from, and how environments get upgraded. Needs no clone. |
| `ci status -Pr <n>` / `-Branch <name>` / `-Job <name>` | Result, commit, failed or running stages, link. Job names are the keys of the ci provider's named jobs. |
| `ci stages ...` / `ci tail ... [-Lines 80]` | Every stage with its duration / the end of the console log. |
| `ci find -Branch <name>` | Which pull-request jobs built that branch, open or closed. |
| `ci ping` | Whether the CI is reachable. |

Add `-Build <n>` to a ci command to read a specific run instead of the last one. `-Json` is what other skills parse. In `ticket -Json`, each environment also says which branch its versions come from (`branch`) and the first version of that branch with the ticket (`firstVersion`), and each branch and target names the newest commit's author (`author`: name and e-mail from git). Nothing here triggers, rebuilds, or aborts anything.

- Exit `3`: the service is unreachable. Stop and say: "I can't reach <the service>; you're probably not on the VPN." Do not retry in a loop and do not guess a status.
- Exit `2`: something is not configured. `ticket` and `deployed` read git history and need the code repository clone (`paths.codeRepo`); without one, say so, answer what `cd environments` can, and offer `/setup` (step 5 sets up a small partial clone).
- For what is particular to a provider (job addresses, raw API calls, log lines, what a quick failure means), read its notes: `pwsh -NoProfile -File $kit.setup provider -Capability ci` (or `-Capability cd`) prints them (`notes`).

## "Is ticket X on the test instance?"

`delivery ticket -Key <KEY>` answers in one call. Relay it per environment, the one testers use first (`delivery.qaEnvironment`), with the version each runs:

- `IN`: that environment runs a version that has the ticket's changes.
- `NOT in`: it does not. Name the first version that has it (the first tag the script prints) and say that environment needs an upgrade to that version or later. The script prints how environments are upgraded; repeat it when it explains the gap, for example an environment that is never upgraded automatically.
- Merged and published is not "on the test instance". Before saying a ticket is ready to test, check the environment testers use.
- A ticket found only by commit message misses work committed without the key. When the ticket shows no commits but the person says it was merged, ask for the pull request number and use `delivery deployed -Pr <n>`.

## "How is this build going?"

1. `ci status -Pr <n>`, or `ci status -Branch <branch>` when the person names a branch (`git branch --show-current` for "this branch").
2. Report the result, the short commit, the stage it is in or the stages that failed, and the link.
3. On a failure, read `ci tail` and say what failed in plain words: the stage and the error line, not the whole log.
4. `quickFailure` set: the build died before any stage ran. Say the hint it gives; the provider's notes say what it usually means.

## "Can it be merged?"

Only when that pull request's own job reports `SUCCESS` on the commit the pull request points at. `RUNNING`, `FAILURE`, `UNSTABLE`, `ABORTED`, a missing job, or a green branch job are all "not yet". Answer the question; never merge.

## Limits

- Do not trigger, rebuild, or abort jobs.
- Do not start a background watcher or polling loop unless the person asks for it in that message. You may offer one.
