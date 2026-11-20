Board comment guide, the team's version. It describes the structure and tone of each kind of comment; the agent writes the comment in the language the ticket uses. Each section starts with a line holding only `<!-- @name -->` and runs to the next one. This paragraph is not used.

To change a section for yourself, write it in your own guide (`paths.templates.boardComments` in the configuration) with the same `@name` line. Yours wins for that section; the others keep coming from here. Your guide never needs merging when the kit is updated.

<!-- @status -->
A status comment says where the ticket stands, in this order:

- Starts with `Status <d Mon>:` (for example `Status 19 Nov:`).
- What is done and where: environment and version, pull request or branch.
- How it was verified, and what was not verified.
- What remains, and who or what it waits on. A person it waits on is mentioned, so the board notifies them.

<!-- @failed-test -->
A failed test comment lets the developer reproduce it without asking:

- The test key and the step that failed.
- What was expected, then what happened, in one sentence each.
- The environment and its version (`/ci`, versions), and the test data used when it matters.
- No verdict on the cause unless it was checked.

<!-- @transition -->
The reason posted with a transition says why the ticket moves, so whoever opens it later understands without asking:

- One line: from which status to which, in plain words.
- The evidence for the move: what was checked, where, and in which version. Only what was checked.
- What comes next and who does it; mention them when they have to act.
