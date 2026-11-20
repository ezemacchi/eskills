# Changelog

What changed in each version of the kit. Versions are major.minor.patch: a patch fixes, a minor version adds, and a major version breaks something a pack or a tool relied on. The installed version is `kit.version` in `skills/setup/defaults/config.json`; each version is also a git tag (`v1.0.0`) and a GitHub release.

## Unreleased

## 1.0.0 - 2026-11-20

The first numbered version.

### Skills

- `/setup` sets the kit up for one person: tools, board credentials (typed in the person's own terminal, never in a chat), clones, their roles and saved views, and the brief. It also adds a project pack (`add-pack`, from a zip or a folder), merges kit files the person edited after an update, proposes a change to the kit, and removes the kit.
- `/board` reads the board with the person's token, and comments or moves a ticket only after they approve exactly what will be done.
- `/ci` says how a build is going and why it failed, which version each environment runs, and whether a ticket's change reached the environment testers use.
- `chat` writes a message to a colleague following their profile and opens the chat with it ready; the person sends it.
- `/brief-me` is the person's brief: what needs them, what changed since the last one, their views, environments, and their pull requests when they work with them.
- `/chief-of-staff` proposes what to do with each ticket, in order and with the reason, and does what the person picks, each step after a yes.

### Engine

- Capabilities and the providers that implement them: board (Jira Cloud), repo (Bitbucket Server), ci (Jenkins), cd (Jenkins deploy jobs), chat (Microsoft Teams), specs (files in a git repository), and a fake provider for tests with no account.
- Four configuration layers: the kit's values, the project pack, the person's roles (one or more), and the person's own file for each project.
- Several project packs side by side. The one in use is chosen by the repository a command runs in, else the person's default, else the only one.
- The planner's rules and actions are data in the pack, and each role says which actions it uses.
- Contracts for tools outside the kit (`docs/contracts`): `-Json` output, exit codes, and the `scripts` and `version` commands.

### Install and safety

- `bootstrap.ps1` installs or updates the kit in one command.
- `Install.ps1` keeps the person's configuration, state and edited files across updates, and takes over an install made under an earlier name.
- `Uninstall.ps1` removes only the kit's skills and its guard's hook entries, and keeps the person's data unless `-RemoveData`.
- A write guard in Cursor and Claude Code asks the person before any write to a project service.
- A pack can require a minimum kit version (`kit.minVersion`); the installer and `add-pack` refuse it on an older kit.
- `Test-Kit.ps1` checks the kit's files, runs the whole engine against the fake provider, and tests a real configuration against its services.
