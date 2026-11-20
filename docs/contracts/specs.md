# specs

The specification files of a ticket: scope, acceptance criteria, scenarios, prototypes. Optional.

Provider today: `git-files`, in the engine, for specifications kept as files in a git repository.
Everything about the repository's layout is configuration (`providers.git-files`): the branch and
root folder, a regular expression that finds the story's code in any text (its named groups are the
code's parts), how each part is written (`upper`, `pad`, `aliases`), the folder to list and how the
story's file names start (`folderTemplate`, `fileTemplate`, filled from `{root}` and the parts), and
the kind of each file (`kinds`, in order). A project sets those values in its pack; it needs no script.

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
