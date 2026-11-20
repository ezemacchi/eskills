# Jenkins reference

Read this only when the ci provider's script does not cover the question, or when its output disagrees with a run's log. Addresses are given as configuration keys; read their values with the setup skill (`Initialize-Config.ps1 get -Key providers.jenkins`).

## Jobs

| Key | What it is |
|---|---|
| `providers.jenkins.multibranch` | The verify pipeline, one child job per pull request and branch. |
| `providers.jenkins.jobs.<name>` | A named job, for example a release job, read with `status -Job <name>`. Its version is the run's `providers.jenkins.versionParameter` parameter, else the version in a display name `<build>_<version>`. |

Pull-request and branch children of `providers.jenkins.multibranch`:

- Pull request: `PR-<number>` (the code host's number). Display name `<title> (#<n>)`.
- Branch: the name with `/` encoded twice: `fix/X-1-y` becomes `fix%252FX-1-y`.
- `color`: `blue` success, `red` failure, `*_anime` running, `disabled` closed (merged or declined).
- A pull-request job's branch is in `lastBuild.actions[].lastBuiltRevision.branch[].name`. Jobs built in merge mode report `origin/PR-<n>` there instead; match `lastBuiltRevision.SHA1` against `git rev-parse origin/<branch>`.
- A pull-request job that dies in about 20 seconds with `Committer identity unknown` could not merge the pull request into its target without creating a commit: the branch is behind its target and needs a rebase onto it. It is not an infrastructure problem.

Links:

- Multibranch run (Blue Ocean): `<providers.jenkins.root>/blue/organizations/jenkins/<providers.jenkins.blueOceanPipeline>/detail/<child encoded once>/<build>/pipeline`.
- Named job run: the classic page `<job>/<build>/`.

## Raw calls

`curl.exe --globoff -sS -A "Mozilla/5.0" --max-time 30 "<url>"`. `--globoff` is required for `tree=...[...]`.

| Need | Path on the job or build |
|---|---|
| Latest run and result | `<job>/api/json?tree=lastBuild[number,result,building,timestamp,url]` |
| Recent runs | `<job>/api/json?tree=builds[number,result,building,displayName]{0,8}` |
| Commit a run built | `<job>/<build>/api/json?tree=actions[lastBuiltRevision[SHA1,branch[name]]]` |
| Who started it, parameters | `<job>/<build>/api/json?tree=actions[causes[shortDescription],parameters[name,value]]` |
| Stage-by-stage progress | `<job>/<build>/wfapi/describe` (`stages[].name,status,durationMillis`) |
| Console log | `<job>/<build>/consoleText` (read the end only) |
| All pull-request jobs with their branch | `<multibranch>/api/json?tree=jobs[name,color,displayName,lastBuild[number,result,building,actions[lastBuiltRevision[SHA1,branch[name]]]]]` |

`result` is `null` while `building` is `true`. If a run's log disagrees with this file, trust the log and tell the person, so whoever maintains the kit corrects it.
