<#
.SYNOPSIS
    Installs or updates the kit's skills in a Cursor skills folder, then refreshes the configuration.

.DESCRIPTION
    Copies every skill listed in kit.skills (skills/setup/defaults/config.json) into the target
    folder. A folder already there is replaced only when it is the kit's own (it has a .kit marker);
    any other folder with the same name is someone's own skill, and the install stops before copying
    anything unless -Force is given, which moves that folder to a backup first.

    The person's configuration, people and notes live outside the skills folder and are not touched.

    Files in the installed copy may be edited, and an update keeps those edits. Each installed folder
    holds .kit-installed.json: the SHA-256 of the kit version each file came from. A copy of that
    version is kept in <StateRoot>\base\<skill>\. On update, file by file:
      - untouched since it was installed: replaced by the new version;
      - edited: kept. When the kit changed it too, the new version is written next to it as
        <name>.kit-new<ext> (never a second SKILL.md, so Cursor does not load it) and listed as a
        pending merge, which /setup resolves;
      - deleted by the person: not created again; reported;
      - skills/setup/defaults/config.json: always replaced. An edited copy is backed up first; its
        values belong in the person's configuration (Initialize-Config.ps1 set).
    A folder installed before these records existed is replaced whole, as before.

    Then installs the kit's hooks (kit.hooks) for the agent that runs the skills: copies their scripts
    to hooks\<kit.name>\ next to the hooks file, and adds their entries to that file. Entries that are
    not the kit's are kept as they are; the kit's own (those that run a script in hooks\<kit.name>\)
    are replaced. Everything else in the file is kept. The previous file is copied to
    <StateRoot>\backup first. Hooks need PowerShell 7; without it they are not installed, because a
    hook that cannot start blocks every command.

.PARAMETER AgentHost
    The program that runs the skills: cursor (default) or claude (Claude Code). It sets the default
    skills folder and hooks file (kit.agentHosts) and the shape of the hook entries: Cursor's
    hooks.json events with failClosed, or Claude Code's settings.json PreToolUse groups with
    onFailure block.

.PARAMETER Target
    The skills folder. Default: the agent's, under the user's profile (.cursor\skills or
    .claude\skills).

.PARAMETER HooksFile
    The hooks file. Default: the agent's (.cursor\hooks.json or .claude\settings.json). Point it at a
    temporary file to try the install without touching your own hooks.

.PARAMETER StateRoot
    Where the original copies (base\) and backups (backup\) go. Default: %LOCALAPPDATA%\<kit.name>.
    Point it at a temporary folder together with -Target to try an install.

.PARAMETER Pack
    A project pack: a folder with pack.json (the project's values: which provider each capability
    uses, addresses, rules, presets), the team's people.md and notes.md, and its own providers. It is
    copied into the setup skill (setup\pack), so the installed kit carries it; its kit.name names the
    kit. A skill whose capability the pack turns off ("enabled": false) is not installed. Updating a
    kit installed with a pack needs -Pack again.

.PARAMETER Force
    Move a same-named folder that is not the kit's to <StateRoot>\backup.

.EXAMPLE
    pwsh -NoProfile -File .\Install.ps1 -Pack ..\my-project-pack
#>
[CmdletBinding()]
param(
    [ValidateSet('cursor', 'claude')]
    [string] $AgentHost = 'cursor',
    [string] $Target,
    [string] $HooksFile,
    [string] $StateRoot,
    [string] $Pack,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Merge-KitObject($Base, $Over) {
    if ($Base -isnot [Management.Automation.PSCustomObject] -or $Over -isnot [Management.Automation.PSCustomObject]) {
        if ($Over -is [array]) { return , $Over }
        return $Over
    }
    $out = New-Object PSObject
    foreach ($p in $Base.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Over.PSObject.Properties) {
        $v = if ($out.PSObject.Properties[$p.Name]) { Merge-KitObject $out.($p.Name) $p.Value } else { $p.Value }
        $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $v -Force
    }
    $out
}

$source = Join-Path $PSScriptRoot 'skills'
$defaults = Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $source 'setup\defaults\config.json') | ConvertFrom-Json
$hostPlaces = $defaults.kit.agentHosts.$AgentHost
if (-not $Target) { $Target = Join-Path $env:USERPROFILE ([string]$hostPlaces.skills) }
if (-not $HooksFile) { $HooksFile = Join-Path $env:USERPROFILE ([string]$hostPlaces.hooksFile) }
$packDir = $null
if ($Pack) {
    $packDir = [IO.Path]::GetFullPath($Pack)
    $packJson = Join-Path $packDir 'pack.json'
    if (-not (Test-Path -LiteralPath $packJson -PathType Leaf)) { Write-Host "Not installed: there is no pack.json in $packDir."; exit 1 }
    $defaults = Merge-KitObject $defaults (Get-Content -Raw -Encoding utf8 -LiteralPath $packJson | ConvertFrom-Json)
}
elseif (Test-Path -LiteralPath (Join-Path $Target 'setup\pack\pack.json') -PathType Leaf) {
    Write-Host "Not installed: the kit in $Target was installed with a project pack (setup\pack). Run again with -Pack <the pack's folder>, so the update keeps it."
    exit 1
}
$kitName = [string]$defaults.kit.name

# A skill is skipped when the pack turns off a capability it needs; a capability with no provider yet
# is still installed, because /setup chooses one.
$skills = @($defaults.kit.skills | Where-Object {
        $needs = @($defaults.kit.skillCapabilities.$_ | Where-Object { $_ })
        -not @($needs | Where-Object { $defaults.capabilities.$_.enabled -eq $false }).Count
    })

function Test-KitFolder([string]$Dir) {
    $marker = Join-Path $Dir '.kit'
    (Test-Path -LiteralPath $marker -PathType Leaf) -and ((Get-Content -Raw -LiteralPath $marker).Trim() -eq $kitName)
}

New-Item -ItemType Directory -Force -Path $Target | Out-Null

$conflicts = @($skills | Where-Object { (Test-Path -LiteralPath (Join-Path $Target $_)) -and -not (Test-KitFolder (Join-Path $Target $_)) })
if ($conflicts.Count -and -not $Force) {
    Write-Host "Not installed. These folders in $Target are not the kit's: $($conflicts -join ', ')."
    Write-Host 'They are your own skills with the same name. Run again with -Force to move them to a backup first.'
    exit 1
}

if (-not $StateRoot) { $StateRoot = Join-Path $env:LOCALAPPDATA $kitName }
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$manifestName = '.kit-installed.json'
$configRel = 'defaults/config.json'

function Get-Sha([string]$File) { (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash.ToLowerInvariant() }

# Files of a folder by relative path (forward slashes), without the install record and pending versions.
function Get-KitFiles([string]$Dir) {
    $list = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Dir)) { return $list }
    $root = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\') + '\'
    foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File -Force) {
        $rel = $f.FullName.Substring($root.Length) -replace '\\', '/'
        if ($rel -eq $manifestName -or $f.Name -match '\.kit-new(\.[^.]*)?$') { continue }
        $list[$rel] = $f.FullName
    }
    $list
}

function Get-PendingName([string]$Rel) {
    $dir = Split-Path -Parent $Rel
    $file = Split-Path -Leaf $Rel
    $ext = [IO.Path]::GetExtension($file)
    $stem = $file.Substring(0, $file.Length - $ext.Length)
    $name = if ($stem) { "$stem.kit-new$ext" } else { "$file.kit-new" }
    if ($dir) { "$dir/$name" } else { $name }
}

function Copy-KitFile([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $To) | Out-Null
    Copy-Item -LiteralPath $From -Destination $To -Force
}

# Installs one skill folder file by file, keeping the person's edits. Returns lines to report.
function Update-KitSkill([string]$Skill, [string]$From, [string]$Dest, [string]$Base) {
    $notes = [Collections.Generic.List[string]]::new()
    $recordFile = Join-Path $Dest $manifestName
    $record = $null
    if (Test-Path -LiteralPath $recordFile) { try { $record = Get-Content -Raw -Encoding utf8 -LiteralPath $recordFile | ConvertFrom-Json } catch { $record = $null } }
    $known = @{}
    $pending = [Collections.Generic.List[string]]::new()
    $deleted = [Collections.Generic.List[string]]::new()
    if ($record) {
        foreach ($p in $record.files.PSObject.Properties) { $known[$p.Name] = [string]$p.Value }
        foreach ($p in @($record.pending)) { if ($p) { $pending.Add([string]$p) } }
    }
    elseif (Test-Path -LiteralPath $Dest) {
        # Installed before install records existed: nothing tells an edit apart, so it is replaced whole.
        Remove-Item -LiteralPath $Dest -Recurse -Force
    }
    if (Test-Path -LiteralPath $Base) { if (-not $record) { Remove-Item -LiteralPath $Base -Recurse -Force } }

    $newFiles = Get-KitFiles $From
    $hashes = [ordered]@{}
    foreach ($rel in $newFiles.Keys) {
        $take = $false
        $srcHash = Get-Sha $newFiles[$rel]
        $here = Join-Path $Dest $rel
        $baseHash = $known[$rel]
        $exists = Test-Path -LiteralPath $here -PathType Leaf
        $mineHash = if ($exists) { Get-Sha $here }
        $pendingFile = Join-Path $Dest (Get-PendingName $rel)
        if ($Skill -eq 'setup' -and $rel -eq $configRel) {
            if ($exists -and $baseHash -and $mineHash -ne $baseHash) {
                $saved = Join-Path $StateRoot "backup\config-$stamp.json"
                Copy-KitFile $here $saved
                $notes.Add("Your edited $rel was replaced by the kit's (it always is) and saved at $saved. Put those values in your own configuration with Initialize-Config.ps1 set.")
            }
            $take = $true
        }
        elseif (-not $exists) {
            if ($baseHash) {
                $deleted.Add($rel); $hashes[$rel] = $baseHash
                if ($srcHash -ne $baseHash) { $notes.Add("You deleted $rel and the kit has a new version of it; it was not created again. The new one is in the kit's copy: $($newFiles[$rel])") }
                continue
            }
            $take = $true
        }
        elseif ($mineHash -eq $srcHash) { $take = $true }
        elseif ($baseHash -and $mineHash -eq $baseHash) { $take = $true }
        elseif ($baseHash -and $srcHash -eq $baseHash) {
            $hashes[$rel] = $baseHash
            continue
        }
        else {
            Copy-KitFile $newFiles[$rel] $pendingFile
            if (-not $pending.Contains($rel)) { $pending.Add($rel) }
            $hashes[$rel] = if ($baseHash) { $baseHash } else { '' }
            $notes.Add("You edited $rel and the kit changed it too: yours is kept, the new version is next to it ($(Split-Path -Leaf $pendingFile)). /setup merges them.")
            continue
        }
        if ($take) {
            Copy-KitFile $newFiles[$rel] $here
            Copy-KitFile $newFiles[$rel] (Join-Path $Base $rel)
            $hashes[$rel] = $srcHash
            [void]$pending.Remove($rel)
            if (Test-Path -LiteralPath $pendingFile) { Remove-Item -LiteralPath $pendingFile -Force }
        }
    }
    # Files the kit no longer ships: removed when untouched, kept (and no longer tracked) when edited.
    foreach ($rel in @($known.Keys | Where-Object { -not $newFiles.Contains($_) })) {
        $here = Join-Path $Dest $rel
        if ((Test-Path -LiteralPath $here -PathType Leaf) -and (Get-Sha $here) -eq $known[$rel]) { Remove-Item -LiteralPath $here -Force }
        elseif (Test-Path -LiteralPath $here -PathType Leaf) { $notes.Add("The kit no longer has $rel; your edited copy is kept.") }
        $old = Join-Path $Base $rel
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
        [void]$pending.Remove($rel)
    }
    $out = [ordered]@{ kit = $kitName; installedAt = (Get-Date).ToString('o'); base = $Base; files = [pscustomobject]$hashes; pending = @($pending); deleted = @($deleted) }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Set-Content -LiteralPath $recordFile -Value ([pscustomobject]$out | ConvertTo-Json -Depth 5) -Encoding utf8
    $notes
}

$kitConfigVar = ($kitName.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_CONFIG'
$utf8 = New-Object System.Text.UTF8Encoding $false

# A copy of one skill with {{kit.name}} and {{kit.configVar}} filled in its Markdown files. The install
# record hashes this copy, so an installed file the person did not edit matches the kit's.
function New-KitStage([string]$Skill) {
    $stage = Join-Path $StateRoot "stage\$Skill"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    $files = Get-KitFiles (Join-Path $source $Skill)
    foreach ($rel in $files.Keys) {
        $to = Join-Path $stage $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
        $text = if ($rel -like '*.md') { [IO.File]::ReadAllText($files[$rel]) } else { $null }
        if ($rel -eq '.kit') { [IO.File]::WriteAllText($to, $kitName, $utf8) }
        elseif ($text -and ($text.Contains('{{kit.name}}') -or $text.Contains('{{kit.configVar}}'))) {
            [IO.File]::WriteAllText($to, $text.Replace('{{kit.name}}', $kitName).Replace('{{kit.configVar}}', $kitConfigVar), $utf8)
        }
        else { Copy-Item -LiteralPath $files[$rel] -Destination $to -Force }
    }
    if ($Skill -eq 'setup' -and $packDir) {
        $packFiles = Get-KitFiles $packDir
        foreach ($rel in @($packFiles.Keys | Where-Object { $_ -notlike '.git/*' -and $_ -ne '.git' })) {
            $to = Join-Path $stage "pack\$rel"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
            Copy-Item -LiteralPath $packFiles[$rel] -Destination $to -Force
        }
    }
    $stage
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($skill in $skills) {
    $dest = Join-Path $Target $skill
    if ((Test-Path -LiteralPath $dest) -and -not (Test-KitFolder $dest)) {
        $backup = Join-Path $StateRoot "backup\$skill-$stamp"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        Move-Item -LiteralPath $dest -Destination $backup
        Write-Host "Moved your own '$skill' to $backup"
    }
    $report = @(Update-KitSkill $skill (New-KitStage $skill) $dest (Join-Path $StateRoot "base\$skill"))
    Write-Host "Installed $skill"
    foreach ($line in $report) { Write-Host "  $line" }
}

# A kit folder this version no longer ships (renamed, removed, or its capability turned off) would stay
# loaded as a skill whose scripts are gone; it is moved to the backup, where it can be copied back from.
$stale = @(Get-ChildItem -LiteralPath $Target -Directory | Where-Object { $_.Name -notin $skills -and (Test-KitFolder $_.FullName) })
foreach ($s in $stale) {
    $backup = Join-Path $StateRoot "backup\$($s.Name)-$stamp"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
    Move-Item -LiteralPath $s.FullName -Destination $backup
    Write-Host "No longer in the kit: $($s.Name). Moved to $backup (your edits, if any, are there)."
}

$exitCode = 0
$hookSpec = $defaults.kit.hooks
$hostEntries = if ($hookSpec) { if ($AgentHost -eq 'claude') { @($hookSpec.claude | Where-Object { $_ }) } else { @($hookSpec.entries | Where-Object { $_ }) } } else { @() }

# A Claude Code hook group is the kit's when one of its handlers runs a script in hooks\<kit.name>\.
function Test-KitGroup($Group, [string]$Marker) {
    @($Group.hooks | Where-Object { "$($_.command) $(@($_.args) -join ' ')".IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0
}

if ($hostEntries.Count) {
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        Write-Host 'Hooks not installed: they need PowerShell 7. Install it and run this again.'
    }
    else {
        $hooksPath = [IO.Path]::GetFullPath($HooksFile)
        $hookDir = Join-Path (Split-Path -Parent $hooksPath) "hooks\$kitName"
        $marker = "\hooks\$kitName\"
        $current = $null
        if (Test-Path -LiteralPath $hooksPath -PathType Leaf) {
            try { $current = Get-Content -Raw -Encoding utf8 -LiteralPath $hooksPath | ConvertFrom-Json }
            catch { $current = $false }
        }
        if ($current -eq $false) {
            Write-Host "Hooks not installed: $hooksPath is not valid JSON. Fix it (or move it away) and run this again; it was not changed."
            $exitCode = 1
        }
        else {
            New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
            $hookScripts = @($hostEntries | ForEach-Object { $_.script } | Sort-Object -Unique)
            Get-ChildItem -LiteralPath $hookDir -Filter '*.ps1' -File | Where-Object { $_.Name -notin $hookScripts } | Remove-Item -Force
            foreach ($script in $hookScripts) {
                Copy-Item -LiteralPath (Join-Path $source "$($hookSpec.source)\$script") -Destination (Join-Path $hookDir $script) -Force
            }
            [IO.File]::WriteAllText((Join-Path $hookDir '.kit'), $kitName, $utf8)
            if ($null -eq $current) { $current = if ($AgentHost -eq 'claude') { New-Object PSObject } else { [pscustomobject]@{ version = 1; hooks = [pscustomobject]@{} } } }
            if ($AgentHost -eq 'cursor' -and -not $current.PSObject.Properties['version']) { $current | Add-Member -NotePropertyName version -NotePropertyValue 1 }
            if (-not $current.PSObject.Properties['hooks'] -or $current.hooks -isnot [Management.Automation.PSCustomObject]) {
                $current | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force
            }
            $before = $current | ConvertTo-Json -Depth 20
            $kitEvents = @($hostEntries | ForEach-Object { $_.event } | Sort-Object -Unique)
            $allEvents = @(@($current.hooks.PSObject.Properties | ForEach-Object { $_.Name }) + $kitEvents | Sort-Object -Unique)
            foreach ($eventName in $allEvents) {
                if ($AgentHost -eq 'claude') {
                    $kept = @(if ($current.hooks.PSObject.Properties[$eventName]) { @($current.hooks.$eventName) | Where-Object { -not (Test-KitGroup $_ $marker) } })
                    $added = @($hostEntries | Where-Object { $_.event -eq $eventName } | ForEach-Object {
                            $handler = [ordered]@{
                                type = 'command'; command = 'pwsh'
                                args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $hookDir $_.script), '-AgentHost', 'claude')
                                onFailure = 'block'
                            }
                            if ($_.timeout) { $handler.timeout = [int]$_.timeout }
                            [pscustomobject]@{ matcher = [string]$_.matcher; hooks = @([pscustomobject]$handler) }
                        })
                }
                else {
                    $kept = @(if ($current.hooks.PSObject.Properties[$eventName]) {
                            @($current.hooks.$eventName) | Where-Object { "$($_.command)".IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -lt 0 }
                        })
                    $added = @($hostEntries | Where-Object { $_.event -eq $eventName } | ForEach-Object {
                            $entry = [ordered]@{ command = "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $hookDir $_.script)`"" }
                            if ($_.timeout) { $entry.timeout = [int]$_.timeout }
                            if ($null -ne $_.failClosed) { $entry.failClosed = [bool]$_.failClosed }
                            [pscustomobject]$entry
                        })
                }
                $list = @($kept + $added)
                if ($list.Count) { $current.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue $list -Force }
                else { $current.hooks.PSObject.Properties.Remove($eventName) }
            }
            $after = $current | ConvertTo-Json -Depth 20
            if ($after -ne $before -or -not (Test-Path -LiteralPath $hooksPath)) {
                if (Test-Path -LiteralPath $hooksPath) {
                    $backup = Join-Path $StateRoot "backup\hooks-$stamp.json"
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
                    Copy-Item -LiteralPath $hooksPath -Destination $backup
                    Write-Host "Your previous hooks file is saved at $backup"
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $hooksPath) | Out-Null
                Set-Content -LiteralPath "$hooksPath.tmp" -Value $after -Encoding utf8
                Move-Item -LiteralPath "$hooksPath.tmp" -Destination $hooksPath -Force
            }
            Write-Host "Installed hooks ($($kitEvents -join ', ')) in $hooksPath; scripts in $hookDir"
        }
    }
}

if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    & pwsh -NoProfile -File (Join-Path $Target 'setup\scripts\Initialize-Config.ps1') init | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'Configuration refreshed.' }
    Write-Host $(if ($AgentHost -eq 'claude') { 'Next: in Claude Code, start a new session and run /setup.' } else { 'Next: in Cursor, open a new chat and run /setup.' })
}
else {
    Write-Host 'PowerShell 7 is not installed. Install it (winget install Microsoft.PowerShell), restart the agent, and run /setup.'
}
exit $exitCode
