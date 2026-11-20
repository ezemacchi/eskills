# specs

The specification files of a ticket: scope, acceptance criteria, scenarios, prototypes. Optional.

Provider today: `git-files`, in the engine, for specifications kept as files in a git repository.
Everything about the repository's layout is configuration (`providers.git-files`): the branch and
root folder, a regular expression that finds the story's code in any text (its named groups are the
code's parts; `fileCodePattern` when file names write the code differently), how each part is
written (`upper`, `pad`, `aliases`), the folder to list and how the story's file names start
(`folderTemplate`, `fileTemplate`, filled from `{root}` and the parts), and the kind of each file
(`kinds`, in order; `"story": true` marks a kind only stories have). A project sets those values in
its pack; it needs no script. A layout that may change is best described loosely: a folder template
of `{root}/` finds a story wherever it is kept.

## Commands

| Command | Output with `-Json` |
|---|---|
| `<story>` (positional: a key, a summary slug, or a short code the project uses) | `{ clone, ref, head, note, fallback, files: [ { kind, path } ] }` |
| `-Check` | `{ clone, origin, branch, coverage }` |

- `kind` is one of `scope`, `acceptance`, `non-functional`, `requirements`, `scenarios`,
  `prototypes`, `other`.
- `path` is a file path, or `<ref>:<path>` when the files are read from a remote branch without
  touching the person's checkout.
- `note` explains a fallback, for example that the server was unreachable and the local copy was read.
- `fallback` is `null` when the provider's values led to the files. Otherwise it names the wider
  search that found them, and `note` says which value did not fit: `whole-root` (outside the folder
  the values point to) or `name-search` (matched by name, to be checked against the story). When
  nothing is found the exit code is `1` and the message says what was searched and what to try.
- `coverage` says how the values fit the repository: `files` with a kind, `storyFiles` of a kind
  only stories have, `recognized` (a story code in the name), `unrecognized` (story files whose code
  the values cannot read), `misplaced` (files with a code the values would not lead to), and up to
  five `examples` of each. A provider without this check leaves it out; `Test-Kit.ps1` warns when
  `unrecognized` or `misplaced` is not 0.

## v1 (before the contract)

`Get-AdaSpec.ps1`, in the Jira skill, for one project's specification repository.
