Brief template, the team's English version. It ships with the kit; if you edit it in your installed copy, an update keeps your version and offers to merge it with the new one.

Each text starts with a line holding only `<!-- @name -->` and runs to the next one. `{{value}}` is replaced by a value; a value that does not exist is left empty. This paragraph is not used.

To change a text for yourself, rather than editing this file, write only the texts you change in your own template (`paths.templates.brief` in the configuration), each with the same `@name` line. Yours win; the ones you do not write keep coming from here, and your template never needs merging on update.

<!-- @format.culture -->
en-GB
<!-- @format.when -->
dddd d MMMM, HH:mm
<!-- @format.date -->
dd/MM
<!-- @format.dateTime -->
dd/MM HH:mm

<!-- @brief -->
# Brief for {{user}} · {{date}}

{{sections}}
<!-- @section -->
## {{title}}
{{body}}

<!-- @title.attention -->
What matters
<!-- @title.changes -->
What changed since the last brief
<!-- @title.instances -->
Version on each instance
<!-- @title.pullRequests -->
My open pull requests
<!-- @title.merged -->
My pull requests merged in the last {{days}} days
<!-- @title.worktrees -->
My worktrees

<!-- @attention.item -->
- {{text}}
<!-- @attention.none -->
- Nothing urgent.
<!-- @attention.unreachable -->
Could not connect to {{service}} (VPN?): what depends on it is missing from this brief.
<!-- @attention.refused -->
{{service}} refused your credentials: run /setup to check them.
<!-- @attention.noClone -->
There is no clone of the code repository, so I cannot see what each instance has: /setup, step 5.
<!-- @attention.qaReady -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): {{instance}} already has the change (version {{version}}). It can be tested.
<!-- @attention.qaWaiting -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): {{instance}} does not have the change yet (it runs {{version}}); {{arrives}}.
<!-- @attention.qaNone -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): I found no commits for the change, neither for the ticket nor for its linked stories.
<!-- @attention.qaUnknown -->
[{{key}}]({{link}}) · {{summary}} ({{status}}): I could not tell whether {{instance}} has the change ({{why}}).
<!-- @attention.qaSkipped -->
I checked {{max}} tickets against {{instance}}; {{count}} were left unchecked because of the limit in the configuration.
<!-- @attention.changes -->
{{count}} change(s) in your views since the last brief (below).
<!-- @attention.prFailed -->
PR #{{id}} ({{title}}) failed in {{checks}}.
<!-- @attention.prConflict -->
PR #{{id}} ({{title}}) has conflicts with {{target}}.
<!-- @attention.prSonar -->
PR #{{id}} ({{title}}) did not pass {{quality}}: {{why}}.
<!-- @attention.prStale -->
PR #{{id}} ({{title}}) is {{behind}} commit(s) behind {{target}}: it needs a rebase.
<!-- @attention.prNeedsWork -->
PR #{{id}} ({{title}}) has change requests.
<!-- @attention.unpushed -->
The worktree {{name}} has {{count}} commit(s) not pushed.
<!-- @attention.noBitbucketToken -->
The {{repo}} token ({{variable}}) is missing, so your pull requests were not read: /setup, step 7.

<!-- @changes.first -->
- This is the first brief: from the next one, what changed shows here.
<!-- @changes.since -->
Since the last brief ({{when}}):
<!-- @changes.new -->
- [{{key}}]({{link}}) appeared in "{{view}}" ({{status}}).
<!-- @changes.status -->
- [{{key}}]({{link}}) went from {{from}} to {{to}} ("{{view}}").
<!-- @changes.newMany -->
- {{count}} new tickets in "{{view}}": {{keys}}.
<!-- @changes.gone -->
- {{key}} is no longer in "{{view}}" (it was {{status}}).
<!-- @changes.goneMany -->
- {{count}} tickets are no longer in "{{view}}": {{keys}}.
<!-- @changes.none -->
- Nothing changed in your views.

<!-- @view.empty -->
Nothing here.
<!-- @view.more -->
Showing the first {{count}}; {{board}} has more.
<!-- @view.badJql -->
{{board}} rejected this view's query; /setup (step 6) checks it.
<!-- @view.unreachable -->
Could not read this view from {{board}}.

<!-- @column.key -->
Ticket
<!-- @column.qa -->
On {{instance}}?
<!-- @column.tests -->
Linked tests
<!-- @field.summary -->
What it is
<!-- @field.status -->
Status
<!-- @field.priority -->
Priority
<!-- @field.assignee -->
Assignee
<!-- @field.reporter -->
Reporter
<!-- @field.updated -->
Updated
<!-- @field.created -->
Created
<!-- @field.issuetype -->
Type

<!-- @qa.IN -->
yes ({{version}}{{via}})
<!-- @qa.NOT_IN -->
no; {{arrives}}{{via}}
<!-- @qa.NONE -->
no commits for the change
<!-- @qa.UNKNOWN -->
unknown ({{why}})
<!-- @qa.skipped -->
not checked (limit)
<!-- @qa.notAsked -->
not asked in this status
<!-- @qa.via -->
, through {{keys}}
<!-- @arrives.version -->
it will have it from version {{firstVersion}}
<!-- @arrives.branch -->
it has not reached {{branch}} yet
<!-- @arrives.unknown -->
I do not know from which version it will have it
<!-- @why.noClone -->
the repository clone is missing
<!-- @why.unreachable -->
{{cd}} does not answer
<!-- @why.noVersion -->
its version could not be read
<!-- @why.versionCommit -->
the commit of its version was not found
<!-- @why.error -->
{{cd}} gave an unexpected answer

<!-- @tests.none -->
none
<!-- @tests.counts -->
{{total}}: {{byStatus}}
<!-- @tests.status -->
{{count}} {{status}}

<!-- @check.IN -->
[{{key}}]({{link}}): {{instance}} already has the change (version {{version}}){{via}}. It can be tested.
<!-- @check.NOT_IN -->
[{{key}}]({{link}}): {{instance}} does not have the change yet (it runs {{version}}){{via}}; {{arrives}}.
<!-- @check.NONE -->
[{{key}}]({{link}}): I found no commits for the change, neither for the ticket nor for its linked stories.
<!-- @check.UNKNOWN -->
[{{key}}]({{link}}): I could not tell whether {{instance}} has the change ({{why}}).

<!-- @instances.line -->
- {{name}}: {{version}}{{qa}}{{upgrade}} ({{source}})
<!-- @instances.qa -->
 · used by QA
<!-- @instances.upgrade.manual -->
 · upgraded by hand
<!-- @instances.upgrade.auto -->
 · upgraded with every publish
<!-- @instances.unknown -->
- {{name}}: could not read its version.
<!-- @instances.unreachable -->
- Could not connect to {{cd}} (VPN?).
<!-- @source.publisher -->
from upgrade run #{{build}}, {{when}}
<!-- @source.live -->
read live from its address

<!-- @pr.none -->
- You have no open pull requests.
<!-- @pr.noToken -->
- The {{repo}} token ({{variable}}) is missing; /setup, step 7, explains how to save it.
<!-- @pr.unreachable -->
- Could not connect to {{repo}} (VPN?).
<!-- @pr.refused -->
- {{repo}} refused the token ({{variable}}): it may have expired. /setup, step 7.
<!-- @pr.head -->
### [PR #{{id}}]({{link}}) · {{title}} · into {{target}}{{repo}} · {{verdict}}
<!-- @pr.repo -->
 (repo {{repo}})
<!-- @pr.jenkins -->
- {{checks}}: {{state}}{{build}}{{link}}
<!-- @pr.sonar -->
- {{quality}}: {{text}}{{link}}
<!-- @pr.review -->
- Review: {{text}}
<!-- @pr.merge -->
- Merge: {{text}}
<!-- @pr.branch -->
- Branch: {{text}}
<!-- @verdict.green -->
GREEN
<!-- @verdict.running -->
RUNNING
<!-- @verdict.failed -->
FAILING
<!-- @verdict.attention -->
ATTENTION
<!-- @verdict.noBuild -->
NO BUILD
<!-- @jenkins.ok -->
OK
<!-- @jenkins.failed -->
FAILED
<!-- @jenkins.running -->
running
<!-- @jenkins.none -->
no build yet
<!-- @jenkins.other -->
{{state}}
<!-- @jenkins.build -->
 build #{{n}}
<!-- @jenkins.link -->
 ([{{checks}}]({{url}}))
<!-- @sonar.pass -->
passed
<!-- @sonar.fail -->
did not pass: {{why}}
<!-- @sonar.none -->
no report
<!-- @sonar.pending -->
no report yet (the build has not finished)
<!-- @sonar.link -->
 ([{{quality}}]({{url}}))
<!-- @review.none -->
no reviewers assigned
<!-- @review.count -->
{{approved}} of {{total}} approved
<!-- @review.needsWork -->
; changes requested by: {{who}}
<!-- @merge.ok -->
no conflicts or blocks
<!-- @merge.conflict -->
has conflicts with {{target}}
<!-- @merge.vetoed -->
blocked: {{why}}
<!-- @merge.unknown -->
could not check it
<!-- @branch.behind -->
{{behind}} commit(s) behind {{target}}. {{checks}} may fail within seconds with "Committer identity unknown"; it needs a rebase onto origin/{{target}}.
<!-- @branch.upToDate -->
up to date with {{target}}

<!-- @merged.none -->
- You merged no pull requests into {{branches}} in the last {{days}} days.
<!-- @merged.line -->
- [PR #{{id}}]({{link}}) · {{title}} · into {{target}}, {{when}} · {{instances}}
<!-- @merged.in -->
{{name}}: yes
<!-- @merged.notIn -->
{{name}}: no
<!-- @merged.unknown -->
{{name}}: unknown
<!-- @merged.notFound -->
- [PR #{{id}}]({{link}}) · {{title}}: I do not see it merged in git yet.
<!-- @merged.noClone -->
- Without the repository clone I cannot tell which instance has each pull request.
<!-- @merged.more -->
- and {{count}} more.

<!-- @worktree.none -->
- No worktrees besides the main checkout.
<!-- @worktree.noClone -->
- No clone of the code repository is configured.
<!-- @worktree.line -->
- {{name}} ({{branch}}): {{parts}}
<!-- @worktree.missing -->
- {{name}}: the folder does not exist; git still has it registered.
<!-- @worktree.detached -->
- {{name}}: no branch (detached HEAD).
<!-- @worktree.target -->
target {{target}} ({{from}})
<!-- @worktree.noTarget -->
unknown target (no pull request)
<!-- @worktree.ahead -->
{{count}} commit(s) of its own
<!-- @worktree.behind -->
{{count}} behind {{target}}
<!-- @worktree.upToDate -->
up to date with {{target}}
<!-- @worktree.unpushed -->
{{count}} commit(s) not pushed
<!-- @worktree.pushed -->
all pushed
<!-- @worktree.neverPushed -->
the branch was never pushed
<!-- @worktree.dirty -->
{{count}} file(s) not committed
<!-- @worktree.clean -->
clean
<!-- @from.openPr -->
PR #{{id}} open
<!-- @from.mergedPr -->
PR #{{id}} already merged
