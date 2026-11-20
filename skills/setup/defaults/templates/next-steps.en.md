"What do I do now" template (chief-of-staff), the team's English version. It ships with the kit; if you edit it in your installed copy, an update keeps your version and offers to merge it with the new one.

Each text starts with a line holding only `<!-- @name -->` and runs to the next one. `{{value}}` is replaced by a value; a value that does not exist is left empty. This paragraph is not used.

To change a text for yourself, rather than editing this file, write only the texts you change in your own template (`paths.templates.nextSteps` in the configuration), each with the same `@name` line. Yours win, and your template never needs merging on update.

Reasons (`reason.<rule>`) go one per rule in `chief.rules`; a rule you added yourself with no reason here uses `reason.other`. Actions (`action.<action>` and `label.<action>`) go one per action.

<!-- @format.culture -->
en-GB
<!-- @format.date -->
dd/MM
<!-- @format.dateTime -->
dd/MM HH:mm

<!-- @plan -->
## What to do now

{{partial}}

{{items}}

{{more}}

{{skipped}}
<!-- @plan.item -->
{{n}}. [{{key}}]({{link}}) · {{summary}} · {{status}}
   - Why: {{reason}}
   - I suggest: {{action}}.
<!-- @plan.last -->
   - Before: {{label}}, {{outcome}} on {{when}}{{note}}.
<!-- @plan.note -->
 ({{note}})
<!-- @plan.none -->
Nothing to suggest now: no ticket in your views needs something from you.
<!-- @plan.more -->
There are {{count}} more; I will suggest them once you get through these.
<!-- @plan.skipped -->
Not suggested again for now: {{items}}.
<!-- @plan.partial -->
Note: the brief could not read {{services}}; this list may be incomplete.
<!-- @skipped.done -->
{{key}} ({{label}}, done on {{when}})
<!-- @skipped.declined -->
{{key}} (you said no on {{when}})
<!-- @skipped.later -->
{{key}} (postponed until {{until}})

<!-- @action.test -->
check the version on {{instance}} and, if it has the change, test it
<!-- @action.comment -->
leave a comment on the ticket (you see the text before it is posted)
<!-- @action.answer -->
read the latest comments and answer on the ticket (you see the text first)
<!-- @action.teams -->
write to {{who}} on {{chat}} (you see the message; you send it)
<!-- @action.writeTests -->
write its test cases from the specification
<!-- @action.finishTests -->
finish the tests in draft
<!-- @label.test -->
{{instance}} check
<!-- @label.comment -->
{{board}} comment
<!-- @label.answer -->
{{board}} answer
<!-- @label.teams -->
{{chat}} message
<!-- @label.writeTests -->
test cases
<!-- @label.finishTests -->
draft tests
<!-- @who.person -->
{{name}}
<!-- @who.unknown -->
whoever developed the change (I do not know who: tell me)

<!-- @reason.retest-ready -->
The fix is already on {{instance}} (version {{version}}){{via}}.
<!-- @reason.missing-info -->
It is in {{status}}: someone is waiting for information from you.
<!-- @reason.test-ready -->
{{instance}} already has the change (version {{version}}){{via}}.
<!-- @reason.retest-waiting -->
It waits for a retest, but {{instance}} runs {{version}} and {{arrives}}. Worth saying on the ticket that the retest waits for that version.
<!-- @reason.test-waiting -->
{{instance}} does not have the change yet (it runs {{version}}; {{arrives}}): testing now would give a false failure.
<!-- @reason.retest-no-fix -->
It waits for a retest, but I find no commits for the fix, neither on the ticket nor on its linked stories.
<!-- @reason.no-tests -->
It has no linked tests yet.
<!-- @reason.draft-tests -->
It has linked tests in draft ({{tests}}).
<!-- @reason.dc-stalled -->
It has been {{days}} days in {{status}} without movement.
<!-- @reason.other -->
It matches your rule "{{rule}}".

<!-- @arrives.version -->
it will have it from version {{firstVersion}}
<!-- @arrives.branch -->
the change has not reached {{branch}} yet
<!-- @arrives.unknown -->
I do not know from which version it will have it
<!-- @qa.via -->
; the change came through {{keys}}
<!-- @tests.none -->
none
<!-- @tests.counts -->
{{total}}: {{byStatus}}
<!-- @tests.status -->
{{count}} {{status}}

<!-- @outcome.done -->
done
<!-- @outcome.declined -->
no
<!-- @outcome.later -->
later
<!-- @history.title -->
## What I recorded
<!-- @history.line -->
- {{when}} · [{{key}}]({{link}}) · {{label}} · {{outcome}}{{note}}
<!-- @history.none -->
Nothing recorded yet.
<!-- @record.ok -->
Recorded: {{key}}, {{label}}, {{outcome}}.
