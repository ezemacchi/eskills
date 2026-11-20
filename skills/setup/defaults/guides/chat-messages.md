Chat message guide, the team's version. It describes the structure and tone of each kind of message; the agent writes it in the recipient's language and then applies the recipient's profile. Each section starts with a line holding only `<!-- @name -->` and runs to the next one. This paragraph is not used.

To change a section for yourself, write it in your own guide (`paths.templates.chatMessages` in the configuration) with the same `@name` line. Yours wins for that section; the others keep coming from here. Your guide never needs merging when the kit is updated.

<!-- @question -->
A question for a colleague who is busy with other work and does not know the ticket in detail:

- First line: who is writing, the story's reference, and what the story is in a few plain words. The reference is the ticket key unless the recipient's profile asks for another.
- Per question: one or two sentences of context, then the options, the recommended one first and marked.
- End with what the writer will do with the answer, when that helps the reader choose.

<!-- @retest-failed -->
A retest that failed, sent to the developer of the fix:

- First line: who is writing, the ticket's reference, and that the retest failed.
- The test or issue key, the step, what was expected, what happened.
- The environment and its version (`/ci`, versions), and whether that version has the fix.
- What the writer needs: a new fix, a look at the data, or a call.

<!-- @confirmation -->
A confirmation of something the writer already knows the answer to:

- Say it is a confirmation, not an open question: "I understand that ...; is that right?"
- One message, one point to confirm per line.
- Say what the writer will do if the answer is yes, so a short "yes" is enough.
