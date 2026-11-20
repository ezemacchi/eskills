# Proposals log

Every improvement someone proposes for the kit is recorded here: who proposed it, what it changes,
why, how they used it, and the maintainers' decision. Rejected proposals stay, with their reason, so
they are not proposed again without something new.

Proposals about one project's values (its people, notes, view presets, rules) belong in that
project's pack and its own log, not here.

## How a proposal arrives

1. The person asks their agent to propose a change. `/setup` builds it with
   `Initialize-Config.ps1 propose` in `paths.proposals\<date>-<topic>\`: the change (`change.patch`,
   `proposed.md` or `proposed-value.json`) and `LOG-entry.md`.
2. The person sends that folder to the maintainers, or opens a pull request with the change and the
   entry.

## How it is decided

1. Read `LOG-entry.md` and the change.
   - `change.patch`: an edited kit file. Apply it from the repository root with `git apply change.patch`.
   - `proposed.md`: sections of a template or a guide. Copy them into the kit's file in
     `skills/setup/defaults/`.
   - `proposed-value.json`: a configuration value. Move it into `skills/setup/defaults/config.json`.
2. If accepted, apply it and run `Test-Kit.ps1 -Static` and `Test-Kit.ps1 -Fake`.
3. Either way, paste `LOG-entry.md` at the end of this file, fill in the decision (accepted or
   rejected), the reason and the date, and commit it with the change.

## Proposals
