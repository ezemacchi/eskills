#Requires -Version 7
<#
.SYNOPSIS
    "What do I do now": the tickets in the person's brief that need something from them, in order, each
    with the reason and the action proposed. It proposes; it never acts.

.DESCRIPTION
    Starts from the brief (brief.json in paths.stateDir). It reuses that file when it is younger than
    chief.briefMaxAgeMinutes, else it runs the brief script first. -Refresh always runs it.

    Each ticket of each saved view, in view order, is matched against chief.rules; the first rule that
    matches gives the action. A ticket appears once. A rule matches when every condition it names holds:
      views         the ticket comes from one of these view ids
      statuses      the ticket's status is one of these
      qa            the brief's instance check said IN, NOT_IN, NONE or UNKNOWN
      tests         "none" or "some" linked tests (only views with "linkedTests": true count them)
      testStatuses  at least one linked test is in one of these statuses
      staleDays     the ticket has not been updated for at least this many days (needs "updated" in
                    the view's fields)
    A rule may carry its own reason ("reason": { "<language>": "text" }), used when the template has
    no @reason.<rule id>.

    Actions come from chief.actions, keyed by name. The kit's are test, comment, answer, teams,
    writeTests and finishTests; a pack or a role adds its own. An action may say:
      needs      capabilities that must be on; otherwise no rule proposes it
      recipient  "developer": the plan names the person to write to (the assignee when it is someone
                 else, else the newest author in git)
      label      { "<language>": "text" }, used when the template has no @label.<name>
      text       { "<language>": "text" }, the proposal ({{instance}}, {{who}}), when it has no @action.<name>.
                 It completes the plan's "I suggest: ...": lower case, no final period
      how        for the agent: how to carry it out. The plan lists it for the actions it proposes
    chief.use says which actions the person uses ({ "<name>": true }); roles set it, and several roles
    add theirs up. A rule whose action the person does not use proposes nothing. When no action is
    named in chief.use, every action is used. The agent performs them, each only after the person
    says yes.

    What the person decided is recorded in paths.stateDir\chief-state.json with "record", and decides
    whether the ticket is proposed again:
      done      not proposed again while the ticket keeps the same status and the same rule proposes
                it (when the record names no rule: while the instance testers use keeps its version)
      declined  not proposed again today
      later     not proposed again until -Until (yyyy-MM-dd; tomorrow by default)

    Texts come from the next-steps template: the team's (kit.templates.nextSteps, in user.language) with
    the person's own (paths.templates.nextSteps) on top, whose texts win.

    Commands:
      plan (default)   prints the plan, and writes next-steps.json to paths.stateDir. -Json prints it.
      record -Key <KEY> -Outcome done|declined|later [-Action <action>] [-Note <text>] [-Ref <id>]
                       [-Until yyyy-MM-dd]   records a decision. -Action defaults to the action the last
                       plan proposed for that ticket. -Ref is what the action produced (a comment id,
                       teams:<alias>).
      history [-Last <n>]   what was recorded, newest first.
      check            reads the configuration, the rules and the template and prints what the plan
                       would use (JSON). No network, no writes. Test-Kit.ps1 runs it.

    Writes only to paths.stateDir. Never writes to the board or the chat.

.NOTES
    Exit codes: 0 ok, 1 bad input, 2 missing configuration or credentials, 3 the brief could not reach
    Jira, Jenkins or Bitbucket, so the plan may be incomplete (it says which).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('plan', 'record', 'history', 'check')]
    [string] $Command = 'plan',
    [string] $Key,
    [string] $Action,
    [ValidateSet('done', 'declined', 'later')]
    [string] $Outcome,
    [string] $Note,
    [string] $Ref,
    [string] $Until,
    [int] $Last = 20,
    [switch] $Refresh,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

# kit-config:start (identical in every kit script; Test-Kit.ps1 checks it)
function Stop-Kit([int]$Code, [string]$Message) { [Console]::Error.WriteLine($Message); exit $Code }

function Merge-KitObject($Base, $Over) {
    if ($Base -isnot [Management.Automation.PSCustomObject] -or $Over -isnot [Management.Automation.PSCustomObject]) {
        if ($Over -is [array]) { return , $Over }
        return $Over
    }
    $out = [pscustomobject]@{}
    foreach ($p in $Base.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Over.PSObject.Properties) {
        $v = if ($out.PSObject.Properties[$p.Name]) { Merge-KitObject $out.($p.Name) $p.Value } else { $p.Value }
        $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $v -Force
    }
    $out
}

function Get-KitName {
    if ($script:kitName) { return $script:kitName }
    $dir = $PSScriptRoot
    while ($dir) {
        $marker = Join-Path $dir '.kit'
        if (Test-Path -LiteralPath $marker -PathType Leaf) { $script:kitName = (Get-Content -Raw -LiteralPath $marker).Trim(); return $script:kitName }
        $up = Split-Path -Parent $dir
        if ($up -eq $dir) { break }
        $dir = $up
    }
    Stop-Kit 2 "No .kit file in a folder above $PSScriptRoot. Reinstall the kit."
}

# Windows only for now: Get-KitHome, Get-KitEnv and Set-KitEnv are what a macOS or Linux port changes.
function Get-KitHome { Join-Path $env:LOCALAPPDATA (Get-KitName) }

# Read from the process first, then from the user's own: a program started before the variable was set does not have it.
function Get-KitEnv([string]$Name, [switch]$Saved) {
    if (-not $Name) { return $null }
    if ($Saved) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v
}

function Set-KitEnv([string]$Name, [string]$Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User') }

function Get-KitConfigVar { ((Get-KitName).ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_CONFIG' }

function Get-KitConfigPath {
    $override = [Environment]::GetEnvironmentVariable((Get-KitConfigVar), 'Process')
    if ($override) { return $override }
    Join-Path (Get-KitHome) 'config.json'
}

function Read-KitJson([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Stop-Kit 2 "Missing $File. Run /setup." }
    try { Get-Content -Raw -Encoding utf8 -LiteralPath $File | ConvertFrom-Json } catch { Stop-Kit 2 "$File is not valid JSON. Run /setup." }
}

# The person's roles in order: user.role holds one name, several separated by commas, or a list.
function Get-KitRoles($User) {
    if (-not ($User.PSObject.Properties['user'] -and $User.user -is [Management.Automation.PSCustomObject] -and $User.user.PSObject.Properties['role'])) { return }
    foreach ($entry in @($User.user.role)) {
        foreach ($name in ([string]$entry -split ',')) { $name = $name.Trim(); if ($name -match '^[A-Za-z0-9_-]+$') { $name } }
    }
}

# Several roles as one layer: the first role's value wins, except lists whose items all have an id,
# which add the later roles' items with an id not seen yet.
function Join-KitRole($First, $Next) {
    $out = [pscustomobject]@{}
    foreach ($p in $First.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Next.PSObject.Properties) {
        if (-not $out.PSObject.Properties[$p.Name]) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value; continue }
        $mine = $out.($p.Name)
        if ($mine -is [Management.Automation.PSCustomObject] -and $p.Value -is [Management.Automation.PSCustomObject]) { $out.($p.Name) = Join-KitRole $mine $p.Value }
        elseif ($mine -is [array] -and $p.Value -is [array] -and -not @(@($mine) + @($p.Value) | Where-Object { $_ -isnot [Management.Automation.PSCustomObject] -or -not $_.PSObject.Properties['id'] }).Count) {
            $seen = @($mine | ForEach-Object { [string]$_.id })
            $out.($p.Name) = @($mine) + @($p.Value | Where-Object { [string]$_.id -notin $seen })
        }
    }
    $out
}

function Get-KitConfig {
    $user = Read-KitJson (Get-KitConfigPath)
    if (-not $user.PSObject.Properties['kit'] -or -not $user.kit.defaultsFile) { Stop-Kit 2 "$(Get-KitConfigPath) does not name kit.defaultsFile. Run /setup." }
    $cfg = Read-KitJson $user.kit.defaultsFile
    if ($user.kit.PSObject.Properties['packFile'] -and $user.kit.packFile) {
        $cfg = Merge-KitObject $cfg (Read-KitJson $user.kit.packFile)
        # The person's roles: the pack's roles\<name>.json for each, read between the pack and the person.
        $roleLayer = $null
        foreach ($role in @(Get-KitRoles $user)) {
            $roleFile = Join-Path (Split-Path -Parent $user.kit.packFile) "roles\$role.json"
            if (-not (Test-Path -LiteralPath $roleFile -PathType Leaf)) { continue }
            $roleLayer = if ($null -eq $roleLayer) { Read-KitJson $roleFile } else { Join-KitRole $roleLayer (Read-KitJson $roleFile) }
        }
        if ($null -ne $roleLayer) { $cfg = Merge-KitObject $cfg $roleLayer }
    }
    $cfg = Merge-KitObject $cfg $user
    if ($cfg.version -ne 2) { Stop-Kit 2 "The configuration is version $($cfg.version); these scripts read version 2. Run /setup." }
    $cfg
}

function Get-KitValue($Config, [string]$Name, [switch]$Required, [switch]$Path) {
    $v = $Config
    foreach ($part in $Name -split '\.') {
        if ($null -eq $v -or $v -isnot [Management.Automation.PSCustomObject] -or -not $v.PSObject.Properties[$part]) { $v = $null; break }
        $v = $v.$part
    }
    if ($Required -and ($null -eq $v -or ($v -is [string] -and -not $v))) { Stop-Kit 2 "The configuration has no value for '$Name'. Run /setup." }
    if ($Path -and $v -is [string]) { $v = [Environment]::ExpandEnvironmentVariables($v.Replace('{kitHome}', (Get-KitHome))) }
    $v
}

# A team file (people, notes, a template, a guide): the project pack's copy when it has one, else the kit's.
function Get-KitTeamFile($Config, [string]$Relative) {
    if ($Config.kit.PSObject.Properties['packFile'] -and $Config.kit.packFile) {
        $packed = Join-Path (Split-Path -Parent $Config.kit.packFile) $Relative
        if (Test-Path -LiteralPath $packed -PathType Leaf) { return $packed }
    }
    Join-Path (Split-Path -Parent $Config.kit.defaultsFile) $Relative
}

function Test-KitCapability($Config, [string]$Name) {
    $c = Get-KitValue $Config "capabilities.$Name"
    [bool]($null -ne $c -and $c.provider -and $c.enabled -ne $false)
}
# kit-config:end

# kit-template:start (identical in every kit script that writes from a template; Test-Kit.ps1 checks it)
function Read-KitSnippets([string]$File) {
    $found = [ordered]@{}
    if (-not $File -or -not (Test-Path -LiteralPath $File -PathType Leaf)) { return $found }
    $current = $null
    $buffer = [Collections.Generic.List[string]]::new()
    foreach ($textLine in Get-Content -Encoding utf8 -LiteralPath $File) {
        if ($textLine -match '^<!--\s*@([A-Za-z0-9_.-]+)\s*-->\s*$') {
            if ($current) { $found[$current] = ($buffer -join "`n").Trim([char[]]"`r`n") }
            $current = $Matches[1]
            $buffer.Clear()
        }
        elseif ($current) { $buffer.Add($textLine) }
    }
    if ($current) { $found[$current] = ($buffer -join "`n").Trim([char[]]"`r`n") }
    $found
}

function Get-KitTemplate($Config, [string]$Name) {
    $pattern = [string](Get-KitValue $Config "kit.templates.$Name" -Required)
    $teamFile = $null
    foreach ($lang in @([string](Get-KitValue $Config 'user.language'), [string](Get-KitValue $Config 'kit.templateFallback')) | Where-Object { $_ }) {
        $candidate = Get-KitTeamFile $Config $pattern.Replace('{language}', $lang)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $teamFile = $candidate; break }
    }
    if (-not $teamFile) { Stop-Kit 2 "The kit's $Name template ($pattern) is missing. Reinstall the kit." }
    $team = Read-KitSnippets $teamFile
    $mineFile = Get-KitValue $Config "paths.templates.$Name" -Path
    $mine = Read-KitSnippets $mineFile
    $merged = [ordered]@{}
    foreach ($n in $team.Keys) { $merged[$n] = $team[$n] }
    foreach ($n in $mine.Keys) { if ($team.Contains($n)) { $merged[$n] = $mine[$n] } }
    [pscustomobject]@{
        name = $Name; team = $teamFile; mine = $(if ($mine.Count) { $mineFile } else { $null }); minePath = $mineFile
        snippets = $merged; unknown = @($mine.Keys | Where-Object { -not $team.Contains($_) })
    }
}

function Format-KitText($Template, [string]$Name, [hashtable]$Values = @{}) {
    if (-not $Template.snippets.Contains($Name)) { Stop-Kit 1 "The $($Template.name) template ($($Template.team)) has no text '@$Name'. Reinstall the kit." }
    $fill = { param($m) $found = $Values[$m.Groups[1].Value]; if ($null -eq $found) { '' } else { [string]$found } }.GetNewClosure()
    [regex]::Replace([string]$Template.snippets[$Name], '\{\{([A-Za-z0-9_]+)\}\}', [Text.RegularExpressions.MatchEvaluator]$fill)
}
# kit-template:end

$cfg = Get-KitConfig
$tpl = Get-KitTemplate $cfg 'nextSteps'
function Phrase([string]$Name, [hashtable]$Values = @{}) {
    if (-not $Values.ContainsKey('board')) { $Values['board'] = $script:boardName }
    if (-not $Values.ContainsKey('chat')) { $Values['chat'] = $script:chatName }
    Format-KitText $tpl $Name $Values
}
# kit-texts (names built from data, which Test-Kit.ps1 cannot find as Phrase calls; action, label and reason come from chief.rules): outcome.done outcome.declined outcome.later skipped.done skipped.declined skipped.later reason.other

$culture = try { [Globalization.CultureInfo]::GetCultureInfo((Phrase 'format.culture')) } catch { [Globalization.CultureInfo]::InvariantCulture }
$stateDir = [string](Get-KitValue $cfg 'paths.stateDir' -Required -Path)
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$briefPath = Join-Path $stateDir 'brief.json'
$planPath = Join-Path $stateDir 'next-steps.json'
$logPath = Join-Path $stateDir 'chief-state.json'
$logMax = 500

$actionDefs = Get-KitValue $cfg 'chief.actions'
$knownActions = @(if ($actionDefs) { $actionDefs.PSObject.Properties | ForEach-Object { $_.Name } })
if (-not $knownActions.Count) { Stop-Kit 2 'The configuration has no chief.actions. Reinstall the kit.' }
$useMap = Get-KitValue $cfg 'chief.use'
$usedActions = @(if ($useMap) { $useMap.PSObject.Properties | Where-Object { $_.Value -eq $true } | ForEach-Object { $_.Name } })
$rules = @(Get-KitValue $cfg 'chief.rules' | Where-Object { $_ })
if (-not $rules.Count) { Stop-Kit 2 'The configuration has no chief.rules. Run /setup.' }
foreach ($rule in $rules) {
    if (-not $rule.id) { Stop-Kit 1 'A rule in chief.rules has no id.' }
    if ([string]$rule.action -cnotin $knownActions) { Stop-Kit 1 "chief.rules '$($rule.id)' has the action '$($rule.action)'. Known: $($knownActions -join ', ')." }
}
$qaName = [string](Get-KitValue $cfg 'delivery.qaEnvironment')
$textLanguages = @([string](Get-KitValue $cfg 'user.language'), [string](Get-KitValue $cfg 'kit.templateFallback')) | Where-Object { $_ }

function Get-ActionDef([string]$Name) {
    if ($actionDefs -and $actionDefs.PSObject.Properties[$Name]) { return $actionDefs.$Name }
    $null
}

# Whether the person uses an action (chief.use; all of them when it names none) and its capabilities are on.
function Test-ActionUsable([string]$Name) {
    if ($usedActions.Count -and $Name -cnotin $usedActions) { return $false }
    $def = Get-ActionDef $Name
    $needs = if ($def -and $def.PSObject.Properties['needs']) { @($def.needs) } else { @() }
    foreach ($capability in @($needs | Where-Object { $_ })) {
        if (-not (Test-KitCapability $cfg ([string]$capability))) { return $false }
    }
    $true
}

# A text kept in the configuration, by language: the person's, else the fallback, else any.
function Get-InlineText($Map) {
    if ($null -eq $Map) { return $null }
    if ($Map -is [string]) { return $Map }
    foreach ($lang in $textLanguages) { if ($Map.PSObject.Properties[$lang] -and $Map.$lang) { return [string]$Map.$lang } }
    $any = @($Map.PSObject.Properties | Where-Object { $_.Value }) | Select-Object -First 1
    if ($any) { [string]$any.Value } else { $null }
}

function Format-InlineText([string]$Text, [hashtable]$Values) {
    if (-not $Values.ContainsKey('board')) { $Values['board'] = $script:boardName }
    if (-not $Values.ContainsKey('chat')) { $Values['chat'] = $script:chatName }
    $fill = { param($m) $found = $Values[$m.Groups[1].Value]; if ($null -eq $found) { '' } else { [string]$found } }.GetNewClosure()
    [regex]::Replace($Text, '\{\{([A-Za-z0-9_]+)\}\}', [Text.RegularExpressions.MatchEvaluator]$fill)
}

# An action's label or proposal: the template's text, else the action's own, else its name.
function Get-ActionText([string]$Kind, [string]$Name, [hashtable]$Values = @{}) {
    if ($tpl.snippets.Contains("$Kind.$Name")) { return Phrase "$Kind.$Name" $Values }
    $def = Get-ActionDef $Name
    $field = if ($Kind -eq 'label') { 'label' } else { 'text' }
    $own = if ($def -and $def.PSObject.Properties[$field]) { Get-InlineText $def.$field } else { $null }
    if ($own) { return Format-InlineText $own $Values }
    $Name
}

# Why a rule proposes its action: the template's text, else the rule's own, else the general one.
function Get-RuleReason($Rule, [hashtable]$Values) {
    if ($tpl.snippets.Contains("reason.$($Rule.id)")) { return Phrase "reason.$($Rule.id)" $Values }
    $own = if ($Rule.PSObject.Properties['reason']) { Get-InlineText $Rule.reason } else { $null }
    if ($own) { return Format-InlineText $own $Values }
    Phrase 'reason.other' $Values
}
$chatInfo = Get-KitValue $cfg 'providerInfo.chat'
$script:chatName = if ($chatInfo -and $chatInfo.displayName) { [string]$chatInfo.displayName } else { 'chat' }
$boardInfo = Get-KitValue $cfg 'providerInfo.board'
$script:boardName = if ($boardInfo -and $boardInfo.displayName) { [string]$boardInfo.displayName } else { [string](Get-KitValue $cfg 'capabilities.board.provider') }
$boardLink = if ($boardInfo) { [string]$boardInfo.link } else { '' }
$keyPattern = if ($boardInfo -and $boardInfo.keyPattern) { [string]$boardInfo.keyPattern } else { '^\S+$' }

if ($Command -eq 'check') {
    $briefScriptPath = [string](Get-KitValue $cfg 'scripts.brief')
    [pscustomobject]@{
        rules = @($rules | ForEach-Object {
                [pscustomobject]@{
                    id = $_.id; action = $_.action; used = (Test-ActionUsable ([string]$_.action))
                    reason = $(if ($tpl.snippets.Contains("reason.$($_.id)")) { "reason.$($_.id)" } elseif ($_.PSObject.Properties['reason'] -and $_.reason) { 'own' } else { 'reason.other' })
                }
            })
        actions = @($knownActions | ForEach-Object {
                $def = Get-ActionDef $_
                [pscustomobject]@{
                    name = $_; used = (Test-ActionUsable $_); label = (Get-ActionText 'label' $_ @{ instance = $qaName })
                    texts = $(if ($tpl.snippets.Contains("action.$_")) { 'template' } elseif ($def -and $def.PSObject.Properties['text']) { 'own' } else { 'missing' })
                    how = $(if ($def -and $def.PSObject.Properties['how']) { [string]$def.how } else { $null })
                }
            })
        brief = $(if ($briefScriptPath -and (Test-Path -LiteralPath $briefScriptPath -PathType Leaf)) { 'found' } else { 'missing: run /setup (init)' })
        stateDir = $stateDir
        template = [pscustomobject]@{ team = $tpl.team; mine = $tpl.mine; minePath = $tpl.minePath; unknown = $tpl.unknown }
    } | ConvertTo-Json -Depth 4
    exit 0
}

function Format-Day($Value) {
    if (-not $Value) { return '' }
    try { ([datetime]$Value).ToString((Phrase 'format.date'), $culture) } catch { [string]$Value }
}

function Format-Moment($Value) {
    if (-not $Value) { return '' }
    try { ([datetime]$Value).ToString((Phrase 'format.dateTime'), $culture) } catch { [string]$Value }
}

function Read-Log {
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { return }
    $data = try { Get-Content -Raw -Encoding utf8 -LiteralPath $logPath | ConvertFrom-Json } catch { $null }
    if ($null -eq $data -or -not $data.PSObject.Properties['log']) {
        Stop-Kit 1 "$logPath is damaged. Move it to another folder to start a new history; nothing else reads it."
    }
    @($data.log) | Where-Object { $_ }
}

function Read-BriefFile {
    if (-not (Test-Path -LiteralPath $briefPath -PathType Leaf)) { return $null }
    try { Get-Content -Raw -Encoding utf8 -LiteralPath $briefPath | ConvertFrom-Json } catch { $null }
}

# The brief's issue for a ticket: the first view that lists it.
function Find-BriefRow($Brief, [string]$TicketKey) {
    foreach ($view in @($Brief.views)) {
        foreach ($row in @($view.issues)) { if ($row.key -eq $TicketKey) { return [pscustomobject]@{ view = $view; row = $row } } }
    }
    $null
}

function Get-LabelValues($Check) {
    @{ instance = $(if ($Check -and $Check.instance) { $Check.instance } else { $qaName }) }
}

# --- history -----------------------------------------------------------------------------------------

if ($Command -eq 'history') {
    $entries = @(Read-Log)
    $shown = @($entries | Select-Object -Last ([Math]::Max(1, $Last)))
    [array]::Reverse($shown)
    if ($Json) { ConvertTo-Json -InputObject @($shown) -Depth 6; exit 0 }
    if (-not $shown.Count) { Phrase 'history.none'; exit 0 }
    $historyLines = @(Phrase 'history.title') + ''
    foreach ($entry in $shown) {
        $historyLines += Phrase 'history.line' @{
            when = (Format-Moment $entry.at); key = $entry.key; link = $entry.link
            label = (Get-ActionText 'label' ([string]$entry.action) @{ instance = $qaName }); outcome = (Phrase "outcome.$($entry.outcome)")
            note = $(if ($entry.note) { Phrase 'plan.note' @{ note = $entry.note } })
        }
    }
    $historyLines -join "`n"
    exit 0
}

# --- record ------------------------------------------------------------------------------------------

if ($Command -eq 'record') {
    if ($Key -notmatch $keyPattern) { Stop-Kit 1 "-Key is not a $($script:boardName) key ($keyPattern), got '$Key'." }
    if (-not $Outcome) { Stop-Kit 1 '-Outcome is required: done, declined or later.' }
    $planned = $null
    if (Test-Path -LiteralPath $planPath -PathType Leaf) {
        $lastPlan = try { Get-Content -Raw -Encoding utf8 -LiteralPath $planPath | ConvertFrom-Json } catch { $null }
        $planned = @($lastPlan.items) | Where-Object { $_ -and $_.key -eq $Key } | Select-Object -First 1
    }
    $chosen = if ($Action) { $Action } elseif ($planned) { [string]$planned.action } else { $null }
    if (-not $chosen) { Stop-Kit 1 "The last plan proposed nothing for $Key; say which action with -Action ($($knownActions -join ', '))." }
    if ($chosen -cnotin $knownActions) { Stop-Kit 1 "-Action must be one of $($knownActions -join ', '), got '$chosen'." }
    $untilDay = $null
    if ($Outcome -eq 'later') {
        if ($Until) {
            $parsedUntil = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($Until, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedUntil)) {
                Stop-Kit 1 "-Until must be a date like 2026-12-31, got '$Until'."
            }
            $untilDay = $parsedUntil.ToString('yyyy-MM-dd')
        }
        else { $untilDay = (Get-Date).Date.AddDays(1).ToString('yyyy-MM-dd') }
    }
    elseif ($Until) { Stop-Kit 1 '-Until goes only with -Outcome later.' }

    $briefNow = Read-BriefFile
    $found = if ($briefNow) { Find-BriefRow $briefNow $Key } else { $null }
    $entry = [ordered]@{
        at = (Get-Date).ToString('o'); key = $Key; action = $chosen; outcome = $Outcome
        rule = $(if ($planned -and [string]$planned.action -eq $chosen) { [string]$planned.rule } else { $null })
        note = $(if ($Note) { $Note.Trim() } else { $null }); ref = $(if ($Ref) { $Ref.Trim() } else { $null }); until = $untilDay
        status = $(if ($found) { [string]$found.row.status } else { $null })
        qaVersion = $(if ($briefNow -and $briefNow.qaInstance) { [string]$briefNow.qaInstance.version } else { $null })
        link = $(if ($found -and $found.row.link) { $found.row.link } elseif ($boardLink) { $boardLink.Replace('{key}', $Key) } else { $null })
    }
    $entries = [Collections.Generic.List[object]]::new()
    foreach ($old in @(Read-Log)) { $entries.Add($old) }
    $entries.Add([pscustomobject]$entry)
    $kept = @($entries | Select-Object -Last $logMax)
    Set-Content -LiteralPath $logPath -Value (ConvertTo-Json -InputObject ([pscustomobject]@{ log = $kept }) -Depth 6) -Encoding utf8
    if ($Json) { [pscustomobject]$entry | ConvertTo-Json -Depth 4 }
    else {
        Phrase 'record.ok' @{ key = $Key; label = (Get-ActionText 'label' $chosen @{ instance = $qaName }); outcome = (Phrase "outcome.$Outcome") }
    }
    exit 0
}

# --- plan: the brief ---------------------------------------------------------------------------------

$maxAge = [int](Get-KitValue $cfg 'chief.briefMaxAgeMinutes')
$brief = Read-BriefFile
$briefAge = if ($brief -and $brief.generated) { ((Get-Date) - [datetime]$brief.generated).TotalMinutes } else { $null }
$ranBrief = $false
if ($Refresh -or $null -eq $briefAge -or $briefAge -ge $maxAge) {
    $briefScript = [string](Get-KitValue $cfg 'scripts.brief' -Required)
    if (-not (Test-Path -LiteralPath $briefScript -PathType Leaf)) { Stop-Kit 2 "Missing kit script $briefScript. Run /setup (init)." }
    $ErrorActionPreference = 'Continue'
    $briefLines = & pwsh -NoProfile -File $briefScript -Json 2>&1
    $briefCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($briefCode -notin 0, 3) {
        $briefErr = (@($briefLines | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join ' ').Trim()
        Stop-Kit $(if ($briefCode -in 1, 2) { $briefCode } else { 1 }) $(if ($briefErr) { $briefErr } else { "The brief stopped (exit $briefCode)." })
    }
    $brief = Read-BriefFile
    if (-not $brief) { Stop-Kit 1 "The brief ran but $briefPath cannot be read." }
    $briefAge = 0
    $ranBrief = $true
}
if ($brief.qaInstance -and $brief.qaInstance.name) { $qaName = [string]$brief.qaInstance.name }
$qaVersionNow = if ($brief.qaInstance) { [string]$brief.qaInstance.version } else { '' }
$problemServices = @(@($brief.problems) | Where-Object { $_ } | ForEach-Object { $_.service })

# --- plan: rules -------------------------------------------------------------------------------------

function Get-IdleDays($Row) {
    if (-not $Row.PSObject.Properties['updated'] -or -not $Row.updated) { return $null }
    $when = [datetime]::MinValue
    if ($Row.updated -is [datetime]) { $when = $Row.updated }
    elseif (-not [datetime]::TryParse([string]$Row.updated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)) { return $null }
    [int][Math]::Floor(((Get-Date) - $when).TotalDays)
}

function Test-Rule($Rule, $View, $Row) {
    if (-not (Test-ActionUsable ([string]$Rule.action))) { return $false }
    if ($Rule.views -and [string]$View.id -notin @($Rule.views)) { return $false }
    if ($Rule.statuses -and [string]$Row.status -notin @($Rule.statuses)) { return $false }
    if ($Rule.qa -and (-not $Row.qa -or [string]$Row.qa.verdict -ne [string]$Rule.qa)) { return $false }
    if ($Rule.tests) {
        if (-not $Row.tests) { return $false }
        $hasTests = [int]$Row.tests.total -gt 0
        if (($Rule.tests -eq 'none' -and $hasTests) -or ($Rule.tests -eq 'some' -and -not $hasTests)) { return $false }
    }
    if ($Rule.testStatuses) {
        if (-not $Row.tests -or -not $Row.tests.byStatus) { return $false }
        $present = @($Row.tests.byStatus.PSObject.Properties | Where-Object { [int]$_.Value -gt 0 } | ForEach-Object { $_.Name })
        if (-not @($present | Where-Object { $_ -in @($Rule.testStatuses) }).Count) { return $false }
    }
    if ($Rule.staleDays) {
        $idle = Get-IdleDays $Row
        if ($null -eq $idle -or $idle -lt [int]$Rule.staleDays) { return $false }
    }
    $true
}

function Format-Tests($Counts) {
    if (-not $Counts) { return '' }
    if (-not [int]$Counts.total) { return Phrase 'tests.none' }
    $parts = @($Counts.byStatus.PSObject.Properties | ForEach-Object { Phrase 'tests.status' @{ count = $_.Value; status = $_.Name } })
    Phrase 'tests.counts' @{ total = $Counts.total; byStatus = ($parts -join ', ') }
}

function Get-Arrives($Check) {
    if (-not $Check) { return '' }
    if ($Check.firstVersion) { return Phrase 'arrives.version' @{ firstVersion = $Check.firstVersion } }
    if ($Check.branch) { return Phrase 'arrives.branch' @{ branch = $Check.branch } }
    Phrase 'arrives.unknown'
}

function Get-Via($Check) {
    if ($Check -and $Check.via) { Phrase 'qa.via' @{ keys = (@($Check.via) -join ', ') } } else { '' }
}

# A decision recorded earlier hides the ticket while it still applies. "done" holds while the ticket keeps
# its status and the same rule proposes it (its situation has not changed); a record made outside a plan
# has no rule, so the version of the instance testers use stands in for it.
function Test-StillApplies($Prior, $Row, [string]$RuleId) {
    switch ([string]$Prior.outcome) {
        'done' {
            if ([string]$Prior.status -ne [string]$Row.status) { return $false }
            if ($Prior.rule) { return ([string]$Prior.rule -eq $RuleId) }
            return ([string]$Prior.qaVersion -eq $qaVersionNow)
        }
        'declined' { return ([datetime]$Prior.at).Date -eq (Get-Date).Date }
        'later' { return ($Prior.until -and (Get-Date).Date -lt ([datetime]$Prior.until).Date) }
    }
    $false
}

# --- plan: who developed it (for a Teams message) -----------------------------------------------------

$script:people = $null
function Get-People {
    if ($null -ne $script:people) { return $script:people }
    $script:people = @()
    if (-not (Test-KitCapability $cfg 'chat')) { return $script:people }
    $teamsScript = [string](Get-KitValue $cfg 'scripts.chat')
    if (-not $teamsScript -or -not (Test-Path -LiteralPath $teamsScript -PathType Leaf)) { return $script:people }
    $ErrorActionPreference = 'Continue'
    $peopleLines = & pwsh -NoProfile -File $teamsScript people -Json 2>$null
    $peopleCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($peopleCode -eq 0) {
        $parsedPeople = try { ($peopleLines -join "`n") | ConvertFrom-Json } catch { $null }
        if ($parsedPeople) { $script:people = @($parsedPeople.people | Where-Object { $_ -and -not $_.you }) }
    }
    $script:people
}

function Find-Person([string]$PersonName, [string]$PersonEmail) {
    $list = @(Get-People)
    if ($PersonEmail) {
        $exact = $list | Where-Object { $_.email -and $_.email -eq $PersonEmail } | Select-Object -First 1
        if ($exact) { return $exact }
        $local = ($PersonEmail -split '@')[0]
        $sameLocal = $list | Where-Object { $_.email -and ($_.email -split '@')[0] -eq $local } | Select-Object -First 1
        if ($sameLocal) { return $sameLocal }
    }
    $tokens = @(([string]$PersonName).ToLowerInvariant() -split '[^\p{L}]+' | Where-Object { $_ })
    foreach ($token in $tokens) {
        $byAlias = $list | Where-Object { $_.alias -and $_.alias.ToLowerInvariant() -eq $token } | Select-Object -First 1
        if ($byAlias) { return $byAlias }
    }
    # A short alias for a longer first name: only when exactly one person fits.
    foreach ($token in $tokens) {
        $byStart = @($list | Where-Object { $_.alias -and $_.alias.Length -ge 3 -and $token.StartsWith($_.alias.ToLowerInvariant()) })
        if ($byStart.Count -eq 1) { return $byStart[0] }
    }
    $null
}

# The developer to write to: the assignee when it is someone else, else the newest author in git.
function Get-Developer($Row) {
    $me = [string](Get-KitValue $cfg 'user.name')
    $candidates = [Collections.Generic.List[object]]::new()
    $assigned = if ($Row.PSObject.Properties['assignee']) { [string]$Row.assignee } else { '' }
    if ($assigned -and $assigned -ne $me) { $candidates.Add([pscustomobject]@{ name = $assigned; email = $null; from = 'assignee' }) }
    if ($Row.qa -and $Row.qa.developer -and $Row.qa.developer.name) { $candidates.Add([pscustomobject]@{ name = $Row.qa.developer.name; email = $Row.qa.developer.email; from = 'git' }) }
    if (-not $candidates.Count) { return $null }
    $chosen = $candidates[0]
    $person = $null
    foreach ($candidate in $candidates) {
        $person = Find-Person $candidate.name $candidate.email
        if ($person) { $chosen = $candidate; break }
    }
    [pscustomobject]@{
        name = $chosen.name; email = $chosen.email; from = $chosen.from
        alias = $(if ($person) { $person.alias }); language = $(if ($person) { $person.language })
    }
}

# --- plan: build it ----------------------------------------------------------------------------------

$log = @(Read-Log)
$planMax = [int](Get-KitValue $cfg 'chief.max')
if ($planMax -lt 1) { $planMax = 8 }
$taken = @{}
$items = [Collections.Generic.List[object]]::new()
$skipped = [Collections.Generic.List[object]]::new()
foreach ($view in @($brief.views)) {
    if (-not $view.ok) { continue }
    foreach ($row in @($view.issues)) {
        if (-not $row -or $taken.ContainsKey([string]$row.key)) { continue }
        $rule = $rules | Where-Object { Test-Rule $_ $view $row } | Select-Object -First 1
        if (-not $rule) { continue }
        $taken[[string]$row.key] = $true
        $ruleAction = [string]$rule.action
        $prior = $log | Where-Object { $_.key -eq $row.key -and $_.action -eq $ruleAction } | Select-Object -Last 1
        if ($prior -and (Test-StillApplies $prior $row ([string]$rule.id))) {
            $skipped.Add([pscustomobject]@{ key = $row.key; link = $row.link; action = $ruleAction; outcome = $prior.outcome; at = $prior.at; until = $prior.until })
            continue
        }
        $latest = $log | Where-Object { $_.key -eq $row.key } | Select-Object -Last 1
        $items.Add([pscustomobject]@{ view = $view; row = $row; rule = $rule; action = $ruleAction; prior = $latest })
    }
}
$more = [Math]::Max(0, $items.Count - $planMax)
$chosenItems = @($items | Select-Object -First $planMax)

$planItems = [Collections.Generic.List[object]]::new()
$itemTexts = [Collections.Generic.List[string]]::new()
$n = 0
foreach ($pick in $chosenItems) {
    $n++
    $row = $pick.row
    $check = $row.qa
    $actionDef = Get-ActionDef $pick.action
    $developer = if ($actionDef -and $actionDef.PSObject.Properties['recipient'] -and [string]$actionDef.recipient -eq 'developer') { Get-Developer $row } else { $null }
    $instanceName = if ($check -and $check.instance) { $check.instance } else { $qaName }
    $values = @{
        instance = $instanceName; version = $(if ($check) { $check.version }); via = (Get-Via $check)
        status = $row.status; arrives = (Get-Arrives $check); tests = (Format-Tests $row.tests)
        days = (Get-IdleDays $row); rule = $pick.rule.id
    }
    $reason = Get-RuleReason $pick.rule $values
    $who = if ($developer) { Phrase 'who.person' @{ name = $developer.name; alias = $developer.alias } } else { Phrase 'who.unknown' }
    $actionText = Get-ActionText 'action' $pick.action @{ instance = $instanceName; who = $who }
    $label = Get-ActionText 'label' $pick.action @{ instance = $instanceName }
    $text = Phrase 'plan.item' @{
        n = $n; key = $row.key; link = $row.link; summary = $(if ($row.PSObject.Properties['summary']) { $row.summary }); status = $row.status
        reason = $reason; action = $actionText; view = $pick.view.title
    }
    if ($pick.prior) {
        $text += "`n" + (Phrase 'plan.last' @{
                label = (Get-ActionText 'label' ([string]$pick.prior.action) @{ instance = $instanceName }); outcome = (Phrase "outcome.$($pick.prior.outcome)")
                when = (Format-Day $pick.prior.at); note = $(if ($pick.prior.note) { Phrase 'plan.note' @{ note = $pick.prior.note } })
            })
    }
    $itemTexts.Add($text)
    $planItems.Add([pscustomobject]@{
            n = $n; key = $row.key; link = $row.link; summary = $(if ($row.PSObject.Properties['summary']) { $row.summary }); status = $row.status
            view = $pick.view.id; rule = $pick.rule.id; action = $pick.action; reason = $reason; proposal = $actionText; label = $label
            instance = $instanceName; qa = $check; tests = $row.tests; developer = $developer; last = $pick.prior
        })
}

$skippedTexts = @(foreach ($gone in $skipped) {
        Phrase "skipped.$($gone.outcome)" @{
            key = $gone.key; label = (Get-ActionText 'label' ([string]$gone.action) @{ instance = $qaName })
            when = (Format-Day $gone.at); until = (Format-Day $gone.until)
        }
    })
$markdown = Phrase 'plan' @{
    partial = $(if ($problemServices.Count) { Phrase 'plan.partial' @{ services = ($problemServices -join ', ') } })
    items = $(if ($itemTexts.Count) { $itemTexts -join "`n`n" } else { Phrase 'plan.none' })
    more = $(if ($more) { Phrase 'plan.more' @{ count = $more } })
    skipped = $(if ($skippedTexts.Count) { Phrase 'plan.skipped' @{ items = ($skippedTexts -join ', ') } })
}
$markdown = ($markdown -replace '(\r?\n){3,}', "`n`n").Trim() + "`n"

$plan = [pscustomobject]@{
    generated = (Get-Date).ToString('o')
    brief = [pscustomobject]@{ generated = $brief.generated; ageMinutes = [int]$briefAge; ranNow = $ranBrief; markdown = $brief.files.markdown; json = $briefPath }
    qaInstance = [pscustomobject]@{ name = $qaName; version = $qaVersionNow }
    problems = @($brief.problems | Where-Object { $_ })
    items = @($planItems)
    actions = @($planItems | ForEach-Object { [string]$_.action } | Select-Object -Unique | ForEach-Object {
            $def = Get-ActionDef $_
            [pscustomobject]@{ name = $_; label = (Get-ActionText 'label' $_ @{ instance = $qaName }); how = $(if ($def -and $def.PSObject.Properties['how']) { [string]$def.how } else { $null }) }
        })
    more = $more
    skipped = @($skipped)
    template = [pscustomobject]@{ team = $tpl.team; mine = $tpl.mine; minePath = $tpl.minePath; unknown = $tpl.unknown }
}
$planJson = ConvertTo-Json -InputObject $plan -Depth 10
Set-Content -LiteralPath $planPath -Value $planJson -Encoding utf8

if ($Json) { $planJson } else { $markdown }
exit $(if ($problemServices.Count) { 3 } else { 0 })
