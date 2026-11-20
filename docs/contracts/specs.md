# specs

The specification files of a ticket: scope, acceptance criteria, scenarios, prototypes. Optional and
project-specific: a project that keeps specifications in a repository ships a provider in its pack.

## Commands

| Command | Output with `-Json` |
|---|---|
| `<story>` (positional: a key, a summary slug, or a short code the project uses) | `{ clone, ref, head, note, files: [ { kind, path } ] }` |
| `-Check` | `{ clone, origin, branch }` |

- `kind` is one of `scope`, `acceptance`, `non-functional`, `requirements`, `scenarios`,
  `prototypes`, `other`.
- `path` is a file path, or `<ref>:<path>` when the files are read from a remote branch without
  touching the person's checkout.
- `note` explains a fallback, for example that the server was unreachable and the local copy was read.

## v1 (before the contract)

`Get-AdaSpec.ps1`, in the Jira skill, for one project's specification repository.
