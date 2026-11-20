#Requires -Version 7
<#
.SYNOPSIS
    Agent hook (Cursor or Claude Code): asks the person before any write to a service the kit's
    providers talk to, whoever makes it.

.DESCRIPTION
    Installed by Install.ps1 for the program's shell and MCP events, and reads the hook's JSON from
    standard input.
    What to watch comes from the person's configuration: providerInfo.<capability>.guard, which
    Initialize-Config.ps1 init fills from each provider's provider.json (its script, its write
    commands, the hosts of its addresses, its MCP write tools). Nothing here names a service.

      a shell command       "ask" for:
                              - a provider's script (its file name, $kit.<capability> or
                                scripts.<capability>) run with one of its write commands: shows the
                                service, the action, the ticket (-Key), a target status (-To), a
                                comment id (-CommentId) and the first lines of -BodyFile or -Body;
                              - a command that names a provider's host and looks like a write: curl
                                with -X/--request POST|PUT|DELETE|PATCH, -d, --data*, --json, -F or
                                --form; Invoke-RestMethod or Invoke-WebRequest (or irm, iwr) with
                                -Method other than Get, or -Body. A clear read passes; the host with
                                no recognizable reader asks.
                            "allow" for everything else.
      an MCP tool           "ask" for a provider's MCP write tools (matched on the end of the tool's
                            name), or, for a provider that lists none, a tool whose name matches its
                            write pattern; "allow" for the rest.

    When the configuration cannot be read or describes no provider, any kit script run with comment,
    edit-comment or transition still asks, and so does any MCP tool whose name starts like a write
    (create, edit, update, add, transition, delete).

    It is a net, not a lock: an address kept in a variable by an earlier command, or a script written
    first and run later, is not seen here. The written rule (no hand-made API calls) still holds.

    Never prints a token: for a direct call it shows the method and the address, not the command.

    -AgentHost says which program runs it, because each reads and answers in its own shape:
      cursor  beforeShellExecution (command) and beforeMCPExecution (tool_name, tool_input) in;
              { permission: allow|ask, user_message, agent_message } out.
      claude  Claude Code's PreToolUse in: tool_name Bash or PowerShell with tool_input.command, or an
              MCP tool (mcp__<server>__<tool>); { hookSpecificOutput: { hookEventName: PreToolUse,
              permissionDecision: ask, permissionDecisionReason, additionalContext } } out. Nothing is
              printed when there is nothing to ask: "allow" there would skip Claude Code's own
              permission prompt.

.NOTES
    Always exits 0 with at most one JSON answer on standard output. Both programs run it so that a
    crash or a timeout blocks the action (Cursor's failClosed, Claude Code's onFailure: block).
#>
param(
    [ValidateSet('cursor', 'claude')]
    [string] $AgentHost = 'cursor'
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Send-Answer([string]$Permission, [string]$UserMessage = '', [string]$AgentMessage = '') {
    if ($AgentHost -eq 'claude') {
        if ($Permission -ne 'allow') {
            $decision = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = $Permission }
            if ($UserMessage) { $decision.permissionDecisionReason = $UserMessage }
            if ($AgentMessage) { $decision.additionalContext = $AgentMessage }
            [Console]::Out.Write(([pscustomobject]@{ hookSpecificOutput = [pscustomobject]$decision } | ConvertTo-Json -Compress -Depth 4))
        }
        exit 0
    }
    $answer = [ordered]@{ permission = $Permission }
    if ($UserMessage) { $answer.user_message = $UserMessage }
    if ($AgentMessage) { $answer.agent_message = $AgentMessage }
    [Console]::Out.Write(($answer | ConvertTo-Json -Compress))
    exit 0
}

# The hook's input in one shape whatever the program: a shell command, or an MCP tool and its input.
function ConvertFrom-HookInput($HookInput) {
    if ($AgentHost -eq 'claude') {
        $tool = [string]$HookInput.tool_name
        if ($tool -in 'Bash', 'PowerShell') { return [pscustomobject]@{ kind = 'shell'; command = [string]$HookInput.tool_input.command; cwd = [string]$HookInput.cwd } }
        if ($tool -like 'mcp__*') { return [pscustomobject]@{ kind = 'mcp'; tool_name = $tool; tool_input = $HookInput.tool_input } }
        return $null
    }
    $eventName = [string]$HookInput.hook_event_name
    if ($eventName -eq 'beforeMCPExecution' -or (-not $eventName -and $HookInput.PSObject.Properties['tool_name'])) {
        return [pscustomobject]@{ kind = 'mcp'; tool_name = [string]$HookInput.tool_name; tool_input = $HookInput.tool_input }
    }
    [pscustomobject]@{ kind = 'shell'; command = [string]$HookInput.command; cwd = [string]$HookInput.cwd }
}

function Get-Dotted($Object, [string]$Dotted) {
    $v = $Object
    foreach ($part in $Dotted -split '\.') {
        if ($null -eq $v -or $v -isnot [Management.Automation.PSCustomObject] -or -not $v.PSObject.Properties[$part]) { return $null }
        $v = $v.$part
    }
    $v
}

# The kit's name: the .kit file above this script (a kit checkout), else this folder's name, which the
# installer sets to the kit's name (hooks\<kit name>\).
function Get-GuardKitName {
    $dir = $PSScriptRoot
    while ($dir) {
        $marker = Join-Path $dir '.kit'
        if (Test-Path -LiteralPath $marker -PathType Leaf) { return (Get-Content -Raw -LiteralPath $marker).Trim() }
        $up = Split-Path -Parent $dir
        if ($up -eq $dir) { break }
        $dir = $up
    }
    Split-Path -Leaf $PSScriptRoot
}

$defaultWritePattern = '(create|edit|update|add|transition|delete)[A-Z]'
$fallbackRule = [pscustomobject]@{
    capability = '*'; displayName = 'a service'; scriptNames = @(); writeCommands = @('comment', 'edit-comment', 'transition')
    hosts = @(); mcpWriteTools = @(); mcpWritePattern = $defaultWritePattern
}

# The rules of every provider that is on, and how many lines of a text to show. The person's value
# wins over the project pack's, which wins over the kit's, as in the kit scripts. $null when unreadable.
function Read-GuardConfig {
    $kitName = Get-GuardKitName
    $override = [Environment]::GetEnvironmentVariable((($kitName.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_CONFIG'), 'Process')
    $userFile = if ($override) { $override } else { Join-Path (Join-Path $env:LOCALAPPDATA $kitName) 'config.json' }
    try {
        $userCfg = Get-Content -Raw -Encoding utf8 -LiteralPath $userFile | ConvertFrom-Json
        $layers = @($userCfg)
        if ($userCfg.kit.packFile) { $layers += Get-Content -Raw -Encoding utf8 -LiteralPath ([string]$userCfg.kit.packFile) | ConvertFrom-Json }
        $layers += Get-Content -Raw -Encoding utf8 -LiteralPath ([string]$userCfg.kit.defaultsFile) | ConvertFrom-Json
    }
    catch { return $null }
    $rules = @(foreach ($p in @($userCfg.providerInfo.PSObject.Properties)) {
            $g = $p.Value.guard
            if (-not $g) { continue }
            [pscustomobject]@{
                capability = $p.Name; displayName = $(if ($p.Value.displayName) { [string]$p.Value.displayName } else { [string]$p.Value.name })
                scriptNames = @($g.scriptNames | Where-Object { $_ }); writeCommands = @($g.writeCommands | Where-Object { $_ })
                hosts = @($g.hosts | Where-Object { $_ }); mcpWriteTools = @($g.mcpWriteTools | Where-Object { $_ })
                mcpWritePattern = [string]$g.mcpWritePattern
            }
        })
    if (-not $rules.Count) { return $null }
    $lines = [int](Get-Setting $layers 'guard.previewLines')
    [pscustomobject]@{ rules = $rules; previewLines = $(if ($lines -gt 0) { $lines } else { 6 }) }
}

function Get-Setting($Layers, [string]$Dotted) {
    foreach ($layer in $Layers) {
        $v = Get-Dotted $layer $Dotted
        if ($null -ne $v) { return $v }
    }
    $null
}

# The value after a parameter in a command line: -Name 'a b', -Name "a b" or -Name a.
function Get-ArgValue([string]$Text, [string]$Name) {
    $m = [regex]::Match($Text, "(?i)(?<![\w-])-$Name\s+(?:'([^']*)'|`"([^`"]*)`"|(\S+))")
    if (-not $m.Success) { return $null }
    foreach ($g in 1..3) { if ($m.Groups[$g].Success) { return $m.Groups[$g].Value } }
}

function Get-Preview([string]$File, [string]$Cwd, [int]$Lines) {
    if (-not $File) { return $null }
    $full = if ([IO.Path]::IsPathRooted($File)) { $File } elseif ($Cwd) { Join-Path $Cwd $File } else { $File }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return "(could not read $File)" }
    $all = @(Get-Content -Encoding utf8 -LiteralPath $full)
    $shown = @($all | Select-Object -First $Lines)
    ($shown -join "`n") + $(if ($all.Count -gt $Lines) { "`n(... $($all.Count - $Lines) more lines)" })
}

function Get-ScriptPattern($Rule) {
    if ($Rule.capability -eq '*') { return '(?i)\$kit\.\w+\b|scripts\.\w+\b' }
    $names = @($Rule.scriptNames | ForEach-Object { "$([regex]::Escape($_))(\.ps1)?" })
    $names += "\`$kit\.$([regex]::Escape($Rule.capability))\b", "scripts\.$([regex]::Escape($Rule.capability))\b"
    '(?i)' + ($names -join '|')
}

function Test-ShellCommand($HookInput, $Guard) {
    $command = [string]$HookInput.command
    $cwd = [string]$HookInput.cwd

    # 1. A provider's script, writing.
    foreach ($rule in $Guard.rules) {
        if (-not @($rule.writeCommands).Count -or $command -notmatch (Get-ScriptPattern $rule)) { continue }
        $verbs = ($rule.writeCommands | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $action = [regex]::Match($command, "(?i)(?<![\w-])($verbs)(?![\w-])")
        if (-not $action.Success) { continue }
        $what = $action.Groups[1].Value.ToLowerInvariant()
        $key = Get-ArgValue $command 'Key'
        $to = Get-ArgValue $command 'To'
        $commentId = Get-ArgValue $command 'CommentId'
        $bodyFile = Get-ArgValue $command 'BodyFile'
        $body = Get-ArgValue $command 'Body'
        $parts = [Collections.Generic.List[string]]::new()
        $parts.Add("$($rule.displayName) write: $what on $(if ($key) { $key } else { '(ticket not found in the command)' })")
        if ($commentId) { $parts.Add("Comment: $commentId") }
        if ($what -eq 'transition' -or $to) { $parts.Add("Target status: $(if ($to) { $to } else { '(not found in the command)' })") }
        $preview = if ($bodyFile) { Get-Preview $bodyFile $cwd $Guard.previewLines } elseif ($body) { $body }
        if ($preview) { $parts.Add("Text:`n$preview") }
        Send-Answer 'ask' ($parts -join "`n") "A hook asked the person to confirm this $($rule.displayName) write. If they decline, do not retry it another way."
    }

    # 2. A direct call to a provider's address.
    $named = @(foreach ($rule in $Guard.rules) {
            foreach ($h in @($rule.hosts)) {
                if ($command.IndexOf($h, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [pscustomobject]@{ host = $h; service = $rule.displayName } }
            }
        })
    if (-not $named.Count) { Send-Answer 'allow' }
    $service = $named[0].service
    $readers = '(?i)(?<![\w-])(curl(\.exe)?|Invoke-RestMethod|Invoke-WebRequest|irm|iwr)(?![\w-])'
    # curl's short flags are case-sensitive: -f (fail) and -D (dump headers) do not write.
    $curlWrite = '(?<![\w-])(-X\s*|--request\s+)[''"]?(?i:POST|PUT|DELETE|PATCH)\b|(?<![\w-])(-d|-F)(?![\w-])|(?i)(?<![\w-])--(data[\w-]*|json|form)\b'
    $psWrite = '(?i)(?<![\w-])-Method\s+(?![''"]?Get[''"]?(?![\w-]))\S|(?<![\w-])-Body\b'
    $address = [regex]::Match($command, "(?i)https?://[^\s'`"]*($([string]::Join('|', @($named | ForEach-Object { [regex]::Escape($_.host) }))))[^\s'`"]*").Value
    if (-not $address) { $address = $named[0].host }
    $address = ($address -split '\?')[0]
    if ($command -notmatch $readers) {
        Send-Answer 'ask' "This command names $service's address ($address) and the hook cannot tell whether it only reads. Allow it only if you know what it does." "A hook asked the person to confirm a command that names the $service address. Use the kit's script for $service instead of calling the API by hand."
    }
    if ($command -cmatch $curlWrite -or $command -match $psWrite) {
        Send-Answer 'ask' "Direct write to $service, outside the kit's script: $address" "A hook asked the person to confirm a direct write to the $service API. Use the kit's script for $service instead of calling the API by hand."
    }
    Send-Answer 'allow'
}

function Test-McpTool($HookInput, $Guard) {
    $tool = [string]$HookInput.tool_name
    $hit = $null
    foreach ($rule in $Guard.rules) {
        $listed = @($rule.mcpWriteTools)
        $isWrite = if ($listed.Count) { @($listed | Where-Object { $tool -match "(?i)(^|[^A-Za-z0-9])$([regex]::Escape($_))$" }).Count -gt 0 }
        elseif ($rule.mcpWritePattern) { $tool -match "(?i)(^|[^A-Za-z0-9])$($rule.mcpWritePattern)" }
        else { $false }
        if ($isWrite) { $hit = $rule; break }
    }
    if (-not $hit) { Send-Answer 'allow' }

    $toolInput = $HookInput.tool_input
    if ($toolInput -is [string]) { try { $toolInput = $toolInput | ConvertFrom-Json } catch { $toolInput = $null } }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("$($hit.displayName) write through an MCP tool: $tool")
    if ($toolInput -is [Management.Automation.PSCustomObject]) {
        foreach ($p in @($toolInput.PSObject.Properties | Select-Object -First 8)) {
            $v = if ($p.Value -is [string]) { $p.Value } else { $p.Value | ConvertTo-Json -Compress -Depth 4 }
            if ($v.Length -gt 300) { $v = $v.Substring(0, 300) + ' ...' }
            $lines.Add("$($p.Name): $v")
        }
    }
    Send-Answer 'ask' ($lines -join "`n") "A hook asked the person to confirm this MCP write ($($hit.displayName)). If they decline, do not retry it another way."
}

try {
    $hookText = [Console]::In.ReadToEnd()
    $hookInput = ConvertFrom-HookInput ($hookText | ConvertFrom-Json)
    if ($null -eq $hookInput) { Send-Answer 'allow' }
    $guard = Read-GuardConfig
    if ($null -eq $guard) { $guard = [pscustomobject]@{ rules = @($fallbackRule); previewLines = 6 } }
    if ($hookInput.kind -eq 'mcp') { Test-McpTool $hookInput $guard }
    Test-ShellCommand $hookInput $guard
}
catch {
    Send-Answer 'ask' "The kit's write guard could not check this action ($($_.Exception.Message)). Allow it only if you know it does not write to a service." 'A hook could not check this action and asked the person.'
}
