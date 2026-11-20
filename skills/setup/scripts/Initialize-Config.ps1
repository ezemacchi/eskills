<#
.SYNOPSIS
    Creates and edits the kit configuration. The only script that writes config.json.

.DESCRIPTION
    The configuration has two layers. The kit's defaults (defaults/config.json in the setup skill)
    ship with the kit and are replaced when the kit is updated. The user's config.json holds only
    what differs for that person. Every kit script reads the defaults overlaid by the user's file,
    so a kit update changes team values without touching anyone's own settings.

    The user's file is %LOCALAPPDATA%\<kit name>\config.json, or the path in the variable
    <KIT_NAME>_CONFIG (useful to try a configuration without touching the real one). The kit name is
    the text of the .kit file in each installed skill folder; for a kit named team-skills the
    variable is TEAM_SKILLS_CONFIG. A path value may start with {kitHome}, the folder
    %LOCALAPPDATA%\<kit name>.

    Four layers, read in order, the later winning: the kit's defaults, the project pack's pack.json
    (kit.packFile), the pack's files for the person's roles (roles\<name>.json next to pack.json for
    each name in user.role), and the user's file. A pack holds a project's values: which provider each
    capability uses, their addresses, the team's people and notes, rules. A role file holds what
    everyone in that role shares, such as the saved views; because it is read, not copied, a pack
    update reaches everyone in the role. A person may have several roles, in order: the first role's
    value wins, except lists whose items all have an id (views, planner rules), which add the later
    roles' items with a new id. Providers are folders with a provider.json, under kit.providerRoot in
    the kit and providers\ in the pack.

    Commands (all print JSON):
      init [-Pack <folder>] [-Role <name>[,<name>...]]
                               creates or refreshes the user's file: points it at these defaults and
                               the pack (-Pack, else the pack installed in setup\pack, else the one
                               already recorded), moves a version 1 file to version 2 (a copy is
                               kept in backup\ next to it), records -Role as user.role (the pack's
                               roles, in order), records the kit's scripts and the script of each
                               capability that is on, and reports the team's people and notes files
                               next to the user's own
      roles                    the pack's roles: name, title, description, views, the values each
                               sets, and which are the person's (current, and their order)
      provider -Capability <c> the provider a capability uses: its manifest, folder and notes
                               (the provider's own reference, when it has one)
      show [-Effective]        the user's file, or the merged result
      get -Key a.b.c           one merged value
      set -Key a.b.c -Value v  sets a value in the user's file; -ValueFile <json file> or -AsJson
                               for objects and lists
      unset -Key a.b.c         removes the user's value, so the kit default applies again
      preset -Name <name>      copies board.viewPresets.<name> into board.views (for a pack without
                               roles; with roles, set user.role instead)
      tools                    PowerShell, git and curl, and whether each is good enough
      repos [-Apply]           the configured clones of each repository in the configuration's repos
                               list, and every clone of it found on the machine (matched by its
                               origin, not its folder name; see discovery.*).
                               -Apply records a clone when none valid is configured and exactly one
                               was found; it never replaces a configured clone that is valid.
                               -NoSearch checks only the configured clones
      env                      which credential variables the providers that are on read (their
                               manifests' secrets), and whether each is set, never a secret's value
      set-env -Name -Value     sets a user variable that is not a secret; refuses token variables
      guides                   where each writing guide is (kit.guides): the team's, and the person's
                               own (paths.templates.<name>) when it exists. The agent reads the
                               team's, then the person's, whose sections win.
      changes                  the installed kit files the person edited, the pending merges (an
                               edited file the kit also changed: the original, theirs and the new
                               one), and the files they deleted. Reads each skill's
                               .kit-installed.json (written by Install.ps1); needs no configuration.
      propose -Topic -What -Why -How  and one source:
                 -Skill -Path          a kit file the person edited: change.patch against the
                                       kit version it came from (git diff --no-index)
                 -Source <file> [-Section a,b]
                                       the person's own file (template, guide, people, notes),
                                       or only those sections of it: proposed.md
                 -Key a.b              a value of the person's configuration: proposed-value.json
                               writes a proposal to paths.proposals\<date>-<topic>\: the change plus
                               LOG-entry.md (date, who, skill and file, what changed, why, how it
                               was used, and empty decision lines for whoever maintains the kit)
      merged -Skill -Path      records that the pending merge of one file (-Path relative to the
                               skill folder, as changes prints it) is resolved: the file in place is
                               the person's final version, the new kit version becomes its original,
                               and the .kit-new file is removed

.NOTES
    Exit codes: 0 ok, 1 bad input, 2 missing configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('init', 'show', 'get', 'set', 'unset', 'preset', 'roles', 'tools', 'repos', 'env', 'set-env', 'changes', 'merged', 'guides', 'propose', 'provider')]
    [string] $Command,
    [string] $Pack,
    [string[]] $Role,
    [string] $Capability,
    [string] $Skill,
    [string] $Path,
    [string] $Topic,
    [string] $What,
    [string] $Why,
    [string] $How,
    [string] $Source,
    [string[]] $Section,
    [string] $Key,
    [string] $Value,
    [string] $ValueFile,
    [switch] $AsJson,
    [string] $Name,
    [switch] $Effective,
    [switch] $Apply,
    [switch] $NoSearch
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

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

$SetupRoot = Split-Path -Parent $PSScriptRoot
$SkillsRoot = Split-Path -Parent $SetupRoot
$DefaultsFile = Join-Path $SetupRoot 'defaults\config.json'
$ConfigPath = Get-KitConfigPath

function Out-Json($Object) { ConvertTo-Json -InputObject $Object -Depth 20 }

function Read-UserConfig {
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) { return Read-KitJson $ConfigPath }
    $null
}

function Save-UserConfig($User) {
    $dir = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = "$ConfigPath.tmp"
    Set-Content -LiteralPath $tmp -Value (Out-Json $User) -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
}

function Test-KeyName([string]$Dotted) {
    if ($Dotted -notmatch '^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z][A-Za-z0-9_-]*)*$') { Stop-Kit 1 "-Key must look like section.name, got '$Dotted'." }
}

function Get-LeafKeys($Object, [string]$Prefix) {
    foreach ($p in $Object.PSObject.Properties) {
        $k = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
        if ($p.Value -is [Management.Automation.PSCustomObject]) { Get-LeafKeys $p.Value $k } else { $k }
    }
}

# The roles a project pack defines: roles\<name>.json next to its pack.json, each read between the pack
# and the person for whoever has user.role = <name>.
function Get-PackRoles([string]$PackFile) {
    if (-not $PackFile) { return }
    $dir = Join-Path (Split-Path -Parent $PackFile) 'roles'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | Sort-Object Name) {
        $r = Read-KitJson $f.FullName
        [pscustomobject]@{
            name        = $f.BaseName
            title       = $(if ($r.PSObject.Properties['role']) { [string]$r.role.title } else { '' })
            description = $(if ($r.PSObject.Properties['role']) { [string]$r.role.description } else { '' })
            file        = $f.FullName
            views       = @(@(if ($r.PSObject.Properties['board']) { $r.board.views }) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = $_.id; title = $_.title } })
            sets        = @(Get-LeafKeys $r '' | Where-Object { $_ -notlike 'role.*' })
        }
    }
}

function Assert-PackRole([string]$PackFile, [string]$Name) {
    $known = @(Get-PackRoles $PackFile)
    if (-not $known.Count) { return }
    if (-not @($known | Where-Object { $_.name -eq $Name }).Count) { Stop-Kit 1 "No role '$Name' in the pack. Its roles: $(@($known | ForEach-Object { $_.name }) -join ', ')." }
}

# Role names from -Role or a set value: one name, several separated by commas, or a list.
function Split-RoleNames($Value) {
    @(@($Value) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

# How user.role is stored: one name as text, several as a list in their order.
function ConvertTo-RoleValue([string[]]$Names) {
    if ($Names.Count -eq 1) { return $Names[0] }
    , [string[]]$Names
}

function Set-Dotted($Object, [string]$Dotted, $NewValue) {
    $parts = $Dotted -split '\.'
    $node = $Object
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $p = $parts[$i]
        if (-not $node.PSObject.Properties[$p] -or $node.$p -isnot [Management.Automation.PSCustomObject]) {
            $node | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $node = $node.$p
    }
    $node | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $NewValue -Force
}

function Remove-Dotted($Object, [string]$Dotted) {
    $parts = $Dotted -split '\.'
    $node = $Object
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        if (-not $node.PSObject.Properties[$parts[$i]]) { return $false }
        $node = $node.($parts[$i])
        if ($node -isnot [Management.Automation.PSCustomObject]) { return $false }
    }
    if (-not $node.PSObject.Properties[$parts[-1]]) { return $false }
    $node.PSObject.Properties.Remove($parts[-1])
    $true
}

# Every provider folder (one holding provider.json), in the kit and in the pack; the pack's wins for a name.
function Get-KitProviders($Config) {
    $roots = @(Join-Path $SkillsRoot ([string](Get-KitValue $Config 'kit.providerRoot' -Required)))
    if ($Config.kit.PSObject.Properties['packFile'] -and $Config.kit.packFile) { $roots += Join-Path (Split-Path -Parent $Config.kit.packFile) 'providers' }
    $byName = [ordered]@{}
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter 'provider.json' -File) {
            $manifest = try { Get-Content -Raw -Encoding utf8 -LiteralPath $file.FullName | ConvertFrom-Json } catch { Stop-Kit 1 "$($file.FullName) is not valid JSON." }
            $manifest | Add-Member -NotePropertyName dir -NotePropertyValue $file.DirectoryName -Force
            $byName[[string]$manifest.name] = $manifest
        }
    }
    $byName
}

# The manifest of the provider a capability uses, when the capability is on and that provider exists.
function Get-ActiveProvider($Config, $Providers, [string]$Cap) {
    if (-not (Test-KitCapability $Config $Cap)) { return $null }
    $manifest = $Providers[[string](Get-KitValue $Config "capabilities.$Cap.provider")]
    if (-not $manifest -or $Cap -notin @($manifest.capabilities)) { return $null }
    $manifest
}

function Get-CapabilityNames($Config) { @((Get-KitValue $Config 'capabilities').PSObject.Properties | ForEach-Object { $_.Name }) }

# The credential variables of the providers that are on, from their manifests' secrets.
function Get-KitCredentials($Config) {
    $providers = Get-KitProviders $Config
    $seen = @{}
    foreach ($cap in Get-CapabilityNames $Config) {
        $manifest = Get-ActiveProvider $Config $providers $cap
        if (-not $manifest -or $seen[$manifest.name]) { continue }
        $seen[$manifest.name] = $true
        foreach ($s in @($manifest.secrets | Where-Object { $_ })) {
            $keyName = "providers.$($manifest.name).$($s.key)"
            $variable = [string](Get-KitValue $Config $keyName)
            if (-not $variable) { continue }
            [pscustomobject]@{
                key = $keyName; variable = $variable; secret = ($s.secret -eq $true); provider = [string]$manifest.name
                needed = (-not $s.when -or (Get-KitValue $Config ([string]$s.when)) -eq $true); when = $s.when
            }
        }
    }
}

function Get-SecretVars($Config) { @(Get-KitCredentials $Config | Where-Object { $_.secret } | ForEach-Object { $_.variable }) }

# What the engine and the write guard need from a provider, with its configuration filled in, so they
# never read a provider's own keys: its name, how a ticket key looks and links, and what writes.
function Get-ProviderInfo($Config, $Manifest, [string]$Cap) {
    $prefix = "providers.$($Manifest.name)"
    $fill = { param($Text) [regex]::Replace([string]$Text, '\{(\w+)\}', { param($m) if ($m.Groups[1].Value -eq 'key') { return '{key}' }; ([string](Get-KitValue $Config "$prefix.$($m.Groups[1].Value)")).TrimEnd('/') }) }
    $info = [ordered]@{ name = [string]$Manifest.name; displayName = [string]$Manifest.displayName; dir = [string]$Manifest.dir }
    if ($Manifest.keyPattern) { $info.keyPattern = [string]$Manifest.keyPattern }
    if ($Manifest.linkPattern) { $info.link = & $fill $Manifest.linkPattern }
    if ($Manifest.names) {
        $names = [ordered]@{}
        foreach ($n in $Manifest.names.PSObject.Properties) { $names[$n.Name] = [string](Get-KitValue $Config "$prefix.$($n.Value)") }
        $info.names = [pscustomobject]$names
    }
    $info.credentials = @(foreach ($s in @($Manifest.secrets | Where-Object { $_ })) {
            [pscustomobject]@{ variable = [string](Get-KitValue $Config "$prefix.$($s.key)"); secret = ($s.secret -eq $true); when = $s.when }
        })
    if ($Manifest.guard) {
        $hosts = @(foreach ($k in @($Manifest.guard.hosts)) {
                $address = [string](Get-KitValue $Config "$prefix.$k")
                if ($address -match '^https?://([^/:\s]+)') { $Matches[1].ToLowerInvariant() }
            }) | Sort-Object -Unique
        $tools = if ($Manifest.guard.mcpWriteTools) { @(Get-KitValue $Config "$prefix.$($Manifest.guard.mcpWriteTools)" | Where-Object { $_ }) } else { @() }
        $info.guard = [pscustomobject]@{
            capability = $Cap
            scriptNames = @($(if ($Manifest.script) { [IO.Path]::GetFileNameWithoutExtension([string]$Manifest.script) }) | Where-Object { $_ })
            writeCommands = @($Manifest.guard.writeCommands | Where-Object { $_ })
            hosts = @($hosts)
            mcpWriteTools = @($tools)
            mcpWritePattern = [string]$Manifest.guard.mcpWritePattern
        }
    }
    [pscustomobject]$info
}

# A configuration older than version 2 kept each service's values at the top level; version 2 keeps them
# under providers.<name>, and the engine's own under board, delivery and paths. Which old key goes where
# is the project pack's knowledge (migrations.fromVersion1: moves, old key -> new key; sections, old
# top-level section -> provider name), because only a project that had a version 1 knows its keys.
function Convert-KitConfigV1($User, $Map) {
    foreach ($m in @(if ($Map -and $Map.moves) { $Map.moves.PSObject.Properties })) {
        $moved = Get-KitValue $User $m.Name
        if ($null -eq $moved) { continue }
        Set-Dotted $User ([string]$m.Value) $moved
        [void](Remove-Dotted $User $m.Name)
    }
    foreach ($view in @(Get-KitValue $User 'board.views')) {
        if ($view -and $view.PSObject.Properties['jql'] -and -not $view.PSObject.Properties['query']) {
            $view | Add-Member -NotePropertyName query -NotePropertyValue $view.jql
            $view.PSObject.Properties.Remove('jql')
        }
    }
    foreach ($s in @(if ($Map -and $Map.sections) { $Map.sections.PSObject.Properties })) {
        if (-not $User.PSObject.Properties[$s.Name]) { continue }
        foreach ($p in @($User.($s.Name).PSObject.Properties)) { Set-Dotted $User "providers.$($s.Value).$($p.Name)" $p.Value }
        $User.PSObject.Properties.Remove($s.Name)
    }
    if ($User.PSObject.Properties['scripts']) { $User.PSObject.Properties.Remove('scripts') }
    $User | Add-Member -NotePropertyName version -NotePropertyValue 2 -Force
    $User
}

function Get-Origin([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $null }
    $o = & git -C $Dir remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    "$o".Trim()
}

# Folders holding a .git folder, breadth first, at most discovery.depth levels below each root. Does not
# descend into a clone, nor into hidden, system or linked folders. A .git file marks a worktree of a clone
# found elsewhere, so it is skipped.
function Find-Clones($Config) {
    $depth = [int](Get-KitValue $Config 'discovery.depth')
    if ($depth -lt 1) { $depth = 3 }
    $skip = @(Get-KitValue $Config 'discovery.skip')
    $roots = foreach ($r in @(Get-KitValue $Config 'discovery.roots')) {
        if ($r -eq '{fixedDrives}') { [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object { $_.RootDirectory.FullName } }
        else { [Environment]::ExpandEnvironmentVariables([string]$r) }
    }
    $hidden = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint
    $seen = @{}
    $found = [Collections.Generic.List[string]]::new()
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($r in $roots) { if ($r -and (Test-Path -LiteralPath $r -PathType Container)) { $queue.Enqueue(@([IO.DirectoryInfo]::new($r), 0)) } }
    while ($queue.Count) {
        $dir, $level = $queue.Dequeue()
        $full = $dir.FullName.TrimEnd('\')
        if ($seen[$full]) { continue }
        $seen[$full] = $true
        $git = Join-Path $full '.git'
        if ([IO.Directory]::Exists($git)) { $found.Add($full); continue }
        if ([IO.File]::Exists($git) -or $level -ge $depth) { continue }
        try {
            foreach ($child in $dir.EnumerateDirectories()) {
                if ($child.Attributes -band $hidden) { continue }
                if ($child.Name -in $skip) { continue }
                $queue.Enqueue(@($child, ($level + 1)))
            }
        }
        catch { continue }
    }
    $found
}

function Get-Sha([string]$File) { (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash.ToLowerInvariant() }

function Get-PendingName([string]$Rel) {
    $dir = Split-Path -Parent $Rel
    $leaf = Split-Path -Leaf $Rel
    $ext = [IO.Path]::GetExtension($leaf)
    $stem = $leaf.Substring(0, $leaf.Length - $ext.Length)
    $name = if ($stem) { "$stem.kit-new$ext" } else { "$leaf.kit-new" }
    if ($dir) { "$dir/$name" } else { $name }
}

function Read-InstallRecord([string]$SkillDir) {
    $recordFile = Join-Path $SkillDir '.kit-installed.json'
    if (-not (Test-Path -LiteralPath $recordFile -PathType Leaf)) { return $null }
    try { Get-Content -Raw -Encoding utf8 -LiteralPath $recordFile | ConvertFrom-Json } catch { Stop-Kit 1 "$recordFile is not valid JSON. Run the kit's Install.ps1 again." }
}

# What the person changed in each installed skill folder, against the kit version it came from.
function Get-KitChanges {
    if (-not (Test-Path -LiteralPath $DefaultsFile -PathType Leaf)) { Stop-Kit 2 "The kit's defaults are missing: $DefaultsFile. Reinstall the kit." }
    foreach ($name in @((Read-KitJson $DefaultsFile).kit.skills)) {
        $dir = Join-Path $SkillsRoot $name
        $record = Read-InstallRecord $dir
        if ($null -eq $record) { [pscustomobject]@{ skill = $name; tracked = $false; edited = @(); pending = @(); deleted = @() }; continue }
        $pendingList = @($record.pending | Where-Object { $_ })
        $edited = foreach ($p in $record.files.PSObject.Properties) {
            $here = Join-Path $dir $p.Name
            if ((Test-Path -LiteralPath $here -PathType Leaf) -and (Get-Sha $here) -ne [string]$p.Value) { $p.Name }
        }
        $pendingOut = foreach ($rel in $pendingList) {
            $original = Join-Path ([string]$record.base) $rel
            [pscustomobject]@{
                file = $rel; mine = (Join-Path $dir $rel)
                original = $(if ($record.files.$rel -and (Test-Path -LiteralPath $original)) { $original } else { $null })
                new = (Join-Path $dir (Get-PendingName $rel))
            }
        }
        [pscustomobject]@{ skill = $name; tracked = $true; base = [string]$record.base; edited = @($edited); pending = @($pendingOut); deleted = @($record.deleted | Where-Object { $_ }) }
    }
}

function Get-KitGuides($Config) {
    $guides = Get-KitValue $Config 'kit.guides'
    foreach ($g in @(if ($guides) { $guides.PSObject.Properties })) {
        $team = Get-KitTeamFile $Config ([string]$g.Value)
        $mine = Get-KitValue $Config "paths.templates.$($g.Name)" -Path
        [pscustomobject]@{
            name = $g.Name; team = $team; teamOk = (Test-Path -LiteralPath $team -PathType Leaf)
            mine = $mine; mineExists = [bool]($mine -and (Test-Path -LiteralPath $mine -PathType Leaf))
        }
    }
}

function ConvertTo-Slug([string]$Text) {
    $slug = (($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    if ($slug) { $slug } else { 'change' }
}

# A unified diff of the kit version against the person's file, with paths as they are in the kit's
# repository (a/skills/<skill>/<path>), so whoever maintains the kit can git apply it.
function New-KitPatch([string]$Original, [string]$Mine, [string]$RepoPath) {
    $work = Join-Path ([IO.Path]::GetTempPath()) "kit-proposal-$([guid]::NewGuid().ToString('N'))"
    try {
        foreach ($side in @(@('a', $Original), @('b', $Mine))) {
            $to = Join-Path $work "$($side[0])/$RepoPath"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
            Copy-Item -LiteralPath $side[1] -Destination $to
            # Install.ps1 filled the kit's name into installed Markdown; the kit's own copy has the placeholders.
            if ($RepoPath -like '*.md') {
                $text = [IO.File]::ReadAllText($to)
                $back = $text.Replace((Get-KitConfigVar), '{{kit.configVar}}').Replace("\$(Get-KitName)\", '\{{kit.name}}\')
                if ($back -ne $text) { [IO.File]::WriteAllText($to, $back, [Text.UTF8Encoding]::new($false)) }
            }
        }
        Push-Location $work
        try { $diff = & git -c core.autocrlf=false diff --no-index --no-color --no-prefix -- "a/$RepoPath" "b/$RepoPath" 2>&1 }
        finally { Pop-Location }
        if ($LASTEXITCODE -gt 1) { Stop-Kit 1 "git diff failed: $($diff -join ' ')" }
        ($diff -join "`n") + "`n"
    }
    finally { if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force } }
}

switch ($Command) {
    'guides' { Out-Json @(Get-KitGuides (Get-KitConfig)) }

    'propose' {
        if (-not $Topic -or -not $What -or -not $Why) { Stop-Kit 1 'propose needs -Topic, -What (what changed) and -Why (the problem it solves); -How (how it was used) is recommended.' }
        $kinds = @(@([bool]($Skill -or $Path), [bool]$Source, [bool]$Key) | Where-Object { $_ })
        if ($kinds.Count -ne 1) { Stop-Kit 1 'propose needs exactly one source: -Skill and -Path (an edited kit file), -Source (your own file), or -Key (a configuration value).' }
        $cfg = Get-KitConfig
        $root = Get-KitValue $cfg 'paths.proposals' -Required -Path
        $folder = Join-Path $root "$(Get-Date -Format 'yyyy-MM-dd')-$(ConvertTo-Slug $Topic)"
        $n = 2
        while (Test-Path -LiteralPath $folder) { $folder = Join-Path $root "$(Get-Date -Format 'yyyy-MM-dd')-$(ConvertTo-Slug $Topic)-$n"; $n++ }

        if ($Skill -or $Path) {
            if (-not $Skill -or -not $Path) { Stop-Kit 1 'An edited kit file needs both -Skill and -Path (as changes prints them).' }
            $rel = $Path -replace '\\', '/'
            $dir = Join-Path $SkillsRoot $Skill
            $record = Read-InstallRecord $dir
            if ($null -eq $record) { Stop-Kit 1 "$dir has no install record, so there is no original to compare with. Install the kit with Install.ps1 first." }
            $mine = Join-Path $dir $rel
            $original = Join-Path ([string]$record.base) $rel
            if (-not (Test-Path -LiteralPath $mine -PathType Leaf)) { Stop-Kit 1 "No such file: $mine" }
            if (-not $record.files.$rel -or -not (Test-Path -LiteralPath $original -PathType Leaf)) { Stop-Kit 1 "$Skill/$rel has no kit original (it is not a kit file, or its merge is pending: resolve it first)." }
            if ((Get-Sha $mine) -eq [string]$record.files.$rel) { Stop-Kit 1 "$Skill/$rel is not edited; there is nothing to propose." }
            $patch = New-KitPatch $original $mine "skills/$Skill/$rel"
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'change.patch') -Value $patch -Encoding utf8 -NoNewline
            $where = "skills/$Skill/$rel"
            $changeFile = 'change.patch'
        }
        elseif ($Source) {
            $from = [Environment]::ExpandEnvironmentVariables($Source)
            if (-not (Test-Path -LiteralPath $from -PathType Leaf)) { Stop-Kit 1 "No such file: $from" }
            $text = Get-Content -Raw -Encoding utf8 -LiteralPath $from
            $wanted = @($Section | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().TrimStart('@') } | Where-Object { $_ })
            if ($wanted.Count) {
                $blocks = [regex]::Split($text, '(?m)^(?=<!--\s*@[A-Za-z0-9_.-]+\s*-->\s*$)')
                $kept = @($blocks | Where-Object { $_ -match '^<!--\s*@([A-Za-z0-9_.-]+)\s*-->' -and $Matches[1] -in $wanted })
                $missing = @($wanted | Where-Object { $w = $_; -not ($kept | Where-Object { $_ -match "^<!--\s*@$([regex]::Escape($w))\s*-->" }) })
                if ($missing.Count) { Stop-Kit 1 "$from has no section @$($missing -join ', @')." }
                $text = ($kept -join '').TrimEnd() + "`n"
            }
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'proposed.md') -Value $text -Encoding utf8 -NoNewline
            $where = "$(Split-Path -Leaf $from)$(if ($wanted.Count) { " (sections @$($wanted -join ', @'))" })"
            $changeFile = 'proposed.md'
        }
        else {
            Test-KeyName $Key
            $user = Read-UserConfig
            $proposedValue = if ($null -ne $user) { Get-KitValue $user $Key } else { $null }
            if ($null -eq $proposedValue) { Stop-Kit 1 "Your own configuration has no value for '$Key'; only what you changed can be proposed." }
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'proposed-value.json') -Value (Out-Json ([pscustomobject]@{ key = $Key; value = $proposedValue })) -Encoding utf8
            $where = "configuration: $Key"
            $changeFile = 'proposed-value.json'
        }

        $who = [string](Get-KitValue $cfg 'user.name')
        # The entry is read by whoever maintains the kit, in the proposer's language when the kit has it.
        $labels = if ([string](Get-KitValue $cfg 'user.language') -eq 'es') {
            @{ who = 'Quién'; noName = '(sin user.name en la configuración)'; where = 'Skill y archivo'; what = 'Qué cambió'; why = 'Por qué (el problema que tenía)'; how = 'Cómo lo usó'; noHow = '(no lo dijo)'; change = 'Cambio propuesto'; decision = 'Decisión: (aceptada o rechazada)'; reason = 'Motivo de la decisión:'; date = 'Fecha de la decisión:' }
        }
        else {
            @{ who = 'Who'; noName = '(no user.name in the configuration)'; where = 'Skill and file'; what = 'What changed'; why = 'Why (the problem it had)'; how = 'How it was used'; noHow = '(not said)'; change = 'Proposed change'; decision = 'Decision: (accepted or rejected)'; reason = 'Reason for the decision:'; date = 'Date of the decision:' }
        }
        $entry = @(
            "## $(Get-Date -Format 'yyyy-MM-dd') - $Topic"
            ''
            "- $($labels.who): $(if ($who) { $who } else { $labels.noName })"
            "- $($labels.where): $where"
            "- $($labels.what): $What"
            "- $($labels.why): $Why"
            "- $($labels.how): $(if ($How) { $How } else { $labels.noHow })"
            "- $($labels.change): $changeFile"
            "- $($labels.decision)"
            "- $($labels.reason)"
            "- $($labels.date)"
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $folder 'LOG-entry.md') -Value ($entry + "`n") -Encoding utf8 -NoNewline
        Out-Json ([pscustomobject]@{ proposal = $folder; files = @($changeFile, 'LOG-entry.md'); source = $where })
    }

    'changes' {
        $all = @(Get-KitChanges)
        Out-Json ([pscustomobject]@{
                skillsRoot = $SkillsRoot
                edited = (@($all | ForEach-Object { $_.edited }) | Measure-Object).Count
                pending = (@($all | ForEach-Object { $_.pending }) | Measure-Object).Count
                skills = $all
            })
    }

    'merged' {
        if (-not $Skill -or -not $Path) { Stop-Kit 1 'merged needs -Skill and -Path (as changes prints them).' }
        $rel = $Path -replace '\\', '/'
        $dir = Join-Path $SkillsRoot $Skill
        $record = Read-InstallRecord $dir
        if ($null -eq $record) { Stop-Kit 1 "$dir has no install record; nothing to merge." }
        if ($rel -notin @($record.pending)) { Stop-Kit 1 "$Skill/$rel has no pending merge. Pending: $((@($record.pending) | Where-Object { $_ }) -join ', ')." }
        $newFile = Join-Path $dir (Get-PendingName $rel)
        $mine = Join-Path $dir $rel
        if (-not (Test-Path -LiteralPath $newFile -PathType Leaf)) { Stop-Kit 1 "The kit's new version ($newFile) is missing. Run the kit's Install.ps1 again." }
        if (-not (Test-Path -LiteralPath $mine -PathType Leaf)) { Stop-Kit 1 "$mine is missing: write the merged file first." }
        $baseCopy = Join-Path ([string]$record.base) $rel
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $baseCopy) | Out-Null
        Copy-Item -LiteralPath $newFile -Destination $baseCopy -Force
        $record.files | Add-Member -NotePropertyName $rel -NotePropertyValue (Get-Sha $newFile) -Force
        $record.pending = @($record.pending | Where-Object { $_ -and $_ -ne $rel })
        Remove-Item -LiteralPath $newFile -Force
        Set-Content -LiteralPath (Join-Path $dir '.kit-installed.json') -Value ($record | ConvertTo-Json -Depth 5) -Encoding utf8
        Out-Json ([pscustomobject]@{ merged = "$Skill/$rel"; edited = ((Get-Sha $mine) -ne $record.files.$rel); pending = @($record.pending) })
    }

    'init' {
        if (-not (Test-Path -LiteralPath $DefaultsFile -PathType Leaf)) { Stop-Kit 2 "The kit's defaults are missing: $DefaultsFile. Reinstall the kit." }
        $defaults = Read-KitJson $DefaultsFile
        $user = Read-UserConfig
        $created = $null -eq $user
        if ($created) { $user = [pscustomobject]@{ version = $defaults.version } }
        $installedPack = Join-Path $SetupRoot 'pack\pack.json'
        $recordedPack = if ($user.PSObject.Properties['kit'] -and $user.kit -and $user.kit.PSObject.Properties['packFile']) { [string]$user.kit.packFile } else { '' }
        $packFile = if ($Pack) {
            $candidate = Join-Path ([IO.Path]::GetFullPath($Pack)) 'pack.json'
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { Stop-Kit 1 "No pack.json in $Pack." }
            $candidate
        }
        elseif (Test-Path -LiteralPath $installedPack -PathType Leaf) { $installedPack }
        elseif ($recordedPack -and (Test-Path -LiteralPath $recordedPack -PathType Leaf)) { $recordedPack }
        else { $null }

        $migratedFrom = $null
        if (-not $created -and [int]$user.version -lt 2) {
            $backupDir = Join-Path (Split-Path -Parent $ConfigPath) 'backup'
            New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            $migratedFrom = Join-Path $backupDir "config-v$([int]$user.version)-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
            Copy-Item -LiteralPath $ConfigPath -Destination $migratedFrom
            $migrationMap = if ($packFile) { (Read-KitJson $packFile).migrations.fromVersion1 } else { $null }
            $user = Convert-KitConfigV1 $user $migrationMap
        }
        Set-Dotted $user 'kit.defaultsFile' $DefaultsFile
        if ($packFile) { Set-Dotted $user 'kit.packFile' $packFile } else { [void](Remove-Dotted $user 'kit.packFile') }
        if ($Role) {
            if (-not @(Get-PackRoles $packFile).Count) { Stop-Kit 1 "-Role needs a pack with roles (roles\<name>.json next to pack.json)." }
            $roleNames = Split-RoleNames $Role
            foreach ($r in $roleNames) { Assert-PackRole $packFile $r }
            Set-Dotted $user 'user.role' (ConvertTo-RoleValue $roleNames)
        }

        $scripts = [ordered]@{}
        foreach ($p in $defaults.kit.scripts.PSObject.Properties) {
            $full = Join-Path $SkillsRoot $p.Value
            if (Test-Path -LiteralPath $full -PathType Leaf) { $scripts[$p.Name] = $full }
        }
        Set-Dotted $user 'scripts' ([pscustomobject]$scripts)
        Save-UserConfig $user

        $cfg = Get-KitConfig
        $providers = Get-KitProviders $cfg
        $providerInfo = [ordered]@{}
        $capabilities = foreach ($cap in Get-CapabilityNames $cfg) {
            $manifest = Get-ActiveProvider $cfg $providers $cap
            if ($manifest -and $manifest.script) {
                $full = Join-Path $manifest.dir $manifest.script
                if (Test-Path -LiteralPath $full -PathType Leaf) { $scripts[$cap] = $full }
            }
            if ($manifest) { $providerInfo[$cap] = Get-ProviderInfo $cfg $manifest $cap }
            [pscustomobject]@{
                capability = $cap; on = (Test-KitCapability $cfg $cap); provider = [string](Get-KitValue $cfg "capabilities.$cap.provider")
                found = [bool]$manifest; script = $scripts[$cap]
            }
        }
        Set-Dotted $user 'scripts' ([pscustomobject]$scripts)
        Set-Dotted $user 'providerInfo' ([pscustomobject]$providerInfo)
        Save-UserConfig $user

        $cfg = Get-KitConfig
        New-Item -ItemType Directory -Force -Path (Get-KitValue $cfg 'paths.stateDir' -Required -Path) | Out-Null

        $skills = @($cfg.kit.skills | ForEach-Object {
                $dir = Join-Path $SkillsRoot $_
                [pscustomobject]@{ skill = $_; installed = (Test-Path -LiteralPath (Join-Path $dir 'SKILL.md')) }
            })
        $files = foreach ($pair in @(@('people', 'kit.teamPeople', 'paths.myPeople'), @('notes', 'kit.teamNotes', 'paths.myNotes'))) {
            $team = Get-KitTeamFile $cfg ([string](Get-KitValue $cfg $pair[1] -Required))
            $mine = Get-KitValue $cfg $pair[2] -Path
            [pscustomobject]@{ file = $pair[0]; team = $team; teamOk = (Test-Path -LiteralPath $team); mine = $mine; mineExists = [bool]($mine -and (Test-Path -LiteralPath $mine)) }
        }
        $language = [string](Get-KitValue $cfg 'user.language')
        $fallback = [string](Get-KitValue $cfg 'kit.templateFallback')
        $templates = Get-KitValue $cfg 'kit.templates'
        $files += foreach ($t in @(if ($templates) { $templates.PSObject.Properties })) {
            $team = @($language, $fallback | Where-Object { $_ } | ForEach-Object { Get-KitTeamFile $cfg $t.Value.Replace('{language}', $_) } |
                    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
            $mine = Get-KitValue $cfg "paths.templates.$($t.Name)" -Path
            [pscustomobject]@{ file = "$($t.Name) template"; team = $team; teamOk = [bool]$team; mine = $mine; mineExists = [bool]($mine -and (Test-Path -LiteralPath $mine)) }
        }
        $files += foreach ($g in @(Get-KitGuides $cfg)) {
            [pscustomobject]@{ file = "$($g.name) guide"; team = $g.team; teamOk = $g.teamOk; mine = $g.mine; mineExists = $g.mineExists }
        }
        $myRoles = @(Get-KitRoles $cfg)
        $packRoles = @(Get-PackRoles $packFile)
        $roleFiles = @(foreach ($r in $myRoles) { $packRoles | Where-Object { $_.name -eq $r } | ForEach-Object { $_.file } })
        Out-Json ([pscustomobject]@{
                config = $ConfigPath; created = $created; migratedFrom = $migratedFrom; defaults = $DefaultsFile; pack = $packFile
                role = ($myRoles -join ','); roles = @($myRoles); roleFiles = @($roleFiles)
                skills = $skills; capabilities = @($capabilities); scripts = [pscustomobject]$scripts; files = @($files)
            })
    }

    'provider' {
        if (-not $Capability) { Stop-Kit 1 'provider needs -Capability: board, repo, ci, cd, chat or specs.' }
        $cfg = Get-KitConfig
        $providers = Get-KitProviders $cfg
        $providerName = [string](Get-KitValue $cfg "capabilities.$Capability.provider")
        $manifest = if ($providerName) { $providers[$providerName] } else { $null }
        $notesFile = if ($manifest -and $manifest.notes) { Join-Path $manifest.dir $manifest.notes } else { $null }
        Out-Json ([pscustomobject]@{
                capability = $Capability; on = (Test-KitCapability $cfg $Capability); provider = $providerName
                found = [bool]$manifest; dir = $(if ($manifest) { $manifest.dir }); manifest = $manifest
                notesFile = $notesFile
                notes = $(if ($notesFile -and (Test-Path -LiteralPath $notesFile -PathType Leaf)) { Get-Content -Raw -Encoding utf8 -LiteralPath $notesFile })
            })
    }

    'show' {
        if ($Effective) { Out-Json (Get-KitConfig); break }
        $user = Read-UserConfig
        if ($null -eq $user) { Stop-Kit 2 "No configuration at $ConfigPath. Run init first." }
        Out-Json $user
    }

    'get' {
        Test-KeyName $Key
        Out-Json (Get-KitValue (Get-KitConfig) $Key)
    }

    'set' {
        Test-KeyName $Key
        if ($Key -like 'kit.*' -or $Key -eq 'version') { Stop-Kit 1 "'$Key' belongs to the kit; init sets it." }
        if ([bool]$ValueFile -and $PSBoundParameters.ContainsKey('Value')) { Stop-Kit 1 'Pass -Value or -ValueFile, not both.' }
        if ($ValueFile) {
            if (-not (Test-Path -LiteralPath $ValueFile -PathType Leaf)) { Stop-Kit 1 "No such file: $ValueFile" }
            try { $new = Get-Content -Raw -Encoding utf8 -LiteralPath $ValueFile | ConvertFrom-Json -NoEnumerate } catch { Stop-Kit 1 "$ValueFile is not valid JSON." }
        }
        elseif ($AsJson) {
            try { $new = $Value | ConvertFrom-Json -NoEnumerate } catch { Stop-Kit 1 '-Value is not valid JSON.' }
        }
        elseif ($PSBoundParameters.ContainsKey('Value')) { $new = $Value }
        else { Stop-Kit 1 'set needs -Value or -ValueFile.' }
        if ($Key -eq 'user.role' -and $new) {
            $roleNames = Split-RoleNames $new
            $rolePack = [string](Get-KitValue (Get-KitConfig) 'kit.packFile')
            foreach ($r in $roleNames) { Assert-PackRole $rolePack $r }
            if (@(Get-PackRoles $rolePack).Count) { $new = ConvertTo-RoleValue $roleNames }
        }
        $user = Read-UserConfig
        if ($null -eq $user) { Stop-Kit 2 "No configuration at $ConfigPath. Run init first." }
        Set-Dotted $user $Key $new
        Save-UserConfig $user
        Out-Json ([pscustomobject]@{ set = $Key; value = (Get-KitValue (Get-KitConfig) $Key) })
    }

    'unset' {
        Test-KeyName $Key
        $user = Read-UserConfig
        if ($null -eq $user) { Stop-Kit 2 "No configuration at $ConfigPath. Run init first." }
        if ($Key -like 'kit.*' -or $Key -eq 'version') { Stop-Kit 1 "'$Key' belongs to the kit; init sets it." }
        $removed = Remove-Dotted $user $Key
        if ($removed) { Save-UserConfig $user }
        Out-Json ([pscustomobject]@{ unset = $Key; removed = $removed; value = (Get-KitValue (Get-KitConfig) $Key) })
    }

    'preset' {
        if (-not $Name) { Stop-Kit 1 'preset needs -Name.' }
        $cfg = Get-KitConfig
        $views = Get-KitValue $cfg "board.viewPresets.$Name"
        if ($null -eq $views) {
            if (@(Get-PackRoles ([string]$cfg.kit.packFile) | Where-Object { $_.name -eq $Name }).Count) {
                Stop-Kit 1 "'$Name' is a role of this pack: set -Key user.role -Value $Name. Its views then come from the pack and follow its updates."
            }
            $presets = Get-KitValue $cfg 'board.viewPresets'
            $known = @(if ($presets) { $presets.PSObject.Properties | ForEach-Object { $_.Name } }) -join ', '
            Stop-Kit 1 "No view preset '$Name'. Presets: $(if ($known) { $known } else { 'none' })."
        }
        $user = Read-UserConfig
        Set-Dotted $user 'board.views' @($views)
        Save-UserConfig $user
        Out-Json ([pscustomobject]@{ preset = $Name; views = @($views | ForEach-Object { [pscustomobject]@{ id = $_.id; title = $_.title } }) })
    }

    'roles' {
        $cfg = Get-KitConfig
        $mine = @(Get-KitRoles $cfg)
        Out-Json @(Get-PackRoles ([string]$cfg.kit.packFile) | ForEach-Object {
                $_ | Add-Member -NotePropertyName current -NotePropertyValue ($_.name -in $mine) -PassThru |
                    Add-Member -NotePropertyName order -NotePropertyValue ([array]::IndexOf([string[]]$mine, [string]$_.name) + 1) -PassThru
            })
    }

    'tools' {
        $git = Get-Command git -ErrorAction SilentlyContinue
        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        Out-Json @(
            [pscustomobject]@{ tool = 'PowerShell'; ok = ($PSVersionTable.PSVersion.Major -ge 7); version = "$($PSVersionTable.PSVersion)"; need = '7 or later, run as pwsh' }
            [pscustomobject]@{ tool = 'git'; ok = [bool]$git; version = $(if ($git) { "$(& git --version)".Trim() } else { $null }); need = 'any recent git' }
            [pscustomobject]@{ tool = 'curl'; ok = [bool]$curl; version = $(if ($curl) { "$((& curl.exe --version) | Select-Object -First 1)".Trim() } else { $null }); need = 'curl.exe (ships with Windows 10 and later)' }
        )
    }

    'repos' {
        $cfg = Get-KitConfig
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $clones = if ($NoSearch) { @() } else { @(Find-Clones $cfg | ForEach-Object { [pscustomobject]@{ path = $_; origin = (Get-Origin $_) } }) }
        $seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        $user = Read-UserConfig
        $changed = $false
        $wanted = @(Get-KitValue $cfg 'repos' | Where-Object { $_ -and $_.path -and $_.name -and (-not $_.capability -or (Test-KitCapability $cfg ([string]$_.capability))) })
        $out = foreach ($entry in $wanted) {
            $pathKey = [string]$entry.path
            $pattern = "[/:]$([regex]::Escape([string]$entry.name))(\.git)?/?$"
            $configured = Get-KitValue $cfg $pathKey -Path
            $origin = Get-Origin $configured
            $ok = [bool]($origin -and $origin -match $pattern)
            $found = @($clones | Where-Object { $_.origin -and $_.origin -match $pattern })
            $applied = $false
            if ($Apply -and -not $ok -and $found.Count -eq 1 -and $null -ne $user) {
                Set-Dotted $user $pathKey $found[0].path
                $changed = $true
                $applied = $true
            }
            [pscustomobject]@{
                key = $pathKey; repo = [string]$entry.name; uses = [string]$entry.uses; configured = $configured
                configuredOk = $ok; configuredOrigin = $origin
                found = $found; applied = $applied; cloneUrl = [string]$entry.cloneUrl
            }
        }
        if ($changed) { Save-UserConfig $user }
        Out-Json ([pscustomobject]@{ searched = [pscustomobject]@{ clones = $clones.Count; seconds = $seconds }; repos = @($out) })
    }

    'env' {
        $cfg = Get-KitConfig
        $vars = foreach ($c in @(Get-KitCredentials $cfg)) {
            $proc = [Environment]::GetEnvironmentVariable($c.variable, 'Process')
            $usr = Get-KitEnv $c.variable -Saved
            [pscustomobject]@{
                key = $c.key; variable = $c.variable; provider = $c.provider; secret = $c.secret; needed = $c.needed; when = $c.when
                set = [bool]($proc -or $usr)
                scope = $(if ($usr) { 'user' } elseif ($proc) { 'process only' } else { $null })
                value = $(if (-not $c.secret) { if ($usr) { $usr } else { $proc } } else { $null })
            }
        }
        Out-Json @($vars)
    }

    'set-env' {
        if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Stop-Kit 1 "-Name must be a variable name, got '$Name'." }
        $cfg = Get-KitConfig
        if ($Name -in @(Get-SecretVars $cfg)) { Stop-Kit 1 "$Name holds a secret. The user sets it himself with Set-Secret.ps1 in his own terminal." }
        if (-not $Value) { Stop-Kit 1 'set-env needs -Value.' }
        Set-KitEnv $Name $Value
        Out-Json ([pscustomobject]@{ variable = $Name; scope = 'user'; value = $Value })
    }
}
exit 0
