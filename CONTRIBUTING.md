# Contributing

The kit is an engine (setup, the brief, the planner, the delivery check, the write guard, install
and update) plus providers, one per service. Most contributions are a new provider for a service the
kit does not speak yet, or a fix to one. Read [`docs/contracts`](docs/contracts/README.md) first: it
says what every provider must do.

## Ground rules

- **Never print, log or commit a secret.** Credentials come from environment variables named in the
  configuration; a token goes only in a request header.
- **No write without the person's yes.** A provider's write commands are listed in its manifest's
  `guard`, so the write guard asks before they run. The skills show the exact text before writing.
- **The engine never names a service.** Anything particular to a service lives in its provider:
  its script, its manifest, its notes. Anything particular to a project lives in that project's
  pack, not here.
- **Same exit codes everywhere:** 0 ok, 1 bad input, 2 missing configuration or credentials, 3 the
  service refused (`refused:`) or did not answer (`unreachable:`).
- **Contracts grow by adding.** Do not rename or remove a field; add an optional one, or propose a
  new contract version.

## Adding a provider

1. Copy [`docs/provider-template`](docs/provider-template) to
   `skills/setup/providers/<capability>/<name>/` (or to a pack's `providers/` when it is private to
   one project).
2. Fill in `provider.json`: the capabilities it implements, its script, the contract commands it
   implements, the configuration keys it needs, its credential variables, and for a board its key
   pattern, ticket link and write guard.
3. Replace the two `kit-config` lines in the script with the block from any kit script. It must be
   identical; `Test-Kit.ps1 -Static` checks it.
4. Implement each command so that `-Json` prints the contract's shape. The fake provider
   (`skills/setup/providers/fake/Invoke-Fake.ps1`) answers every contract with fixed data: compare
   your output with its output.
5. Add the provider's default values (variable names, public addresses) under `providers.<name>` in
   `skills/setup/defaults/config.json`. Values of one company or project go in its pack.
6. Write `notes.md` for the agent: what is particular to the service.

## Testing without accounts

```powershell
pwsh -NoProfile -File .\skills\setup\scripts\Test-Kit.ps1 -Static          # the kit's own files
pwsh -NoProfile -File .\skills\setup\scripts\Test-Kit.ps1 -Fake            # the engine end to end, fake provider
pwsh -NoProfile -File .\skills\setup\scripts\Test-Kit.ps1 -Fake -KeepFake  # and keep the folder to read the brief
```

`-Fake` builds a throwaway git repository, pack and configuration in a temporary folder, runs init,
the brief, the planner, delivery, a board write, a chat link and the write guard, and checks each
answer. It never reads or changes your own configuration.

To try a provider against a real service without touching your own setup, point the kit at a test
configuration: set `<KIT_NAME>_CONFIG` (for a kit named `team-skills`, `TEAM_SKILLS_CONFIG`) to a file of your
own, run `Initialize-Config.ps1 init -Pack <a pack that chooses your provider>`, then
`Test-Kit.ps1` without switches, which calls each capability that is on.

## Before a pull request

- `Test-Kit.ps1 -Static` and `Test-Kit.ps1 -Fake` pass.
- No address, id, e-mail or name of a real company in the kit's files (the lint checks the kit's
  usual patterns; a pack can add its own, which `Test-Kit.ps1 -Static -Pack <folder>` applies).
- The contract file in `docs/contracts` says what you added.
- Texts a person reads exist in every language of `skills/setup/defaults/templates`, with the same
  `{{values}}`.
