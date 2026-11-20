<#
.SYNOPSIS
    Syncs a specification clone safely and lists the spec files for one story.

.PARAMETER Story
    Any text that holds the story's code: the code itself, a ticket summary, or a link to a spec
    file. The project's code is providers.git-files.codePattern.

.DESCRIPTION
    The clone is paths.specsRepo in the kit configuration. Everything about the repository's layout
    is configuration (providers.git-files):
      branch          the branch the specs live on
      root            the folder that holds the specs
      codePattern     a regular expression that finds the story's code; its named groups are the
                      parts of the code, used in the templates below
      fileCodePattern the same for the code as it appears in file names, with the same groups,
                      when it is written differently there (optional; codePattern by default)
      codeHelp        how the code looks, for the message when none is found
      upper, pad,     how each part is written before it fills a template: upper-cased, padded with
      aliases         zeros to a width, or replaced (an alias is matched ignoring case)
      folderTemplate  the folder to list, from {root} and the parts
      fileTemplate    how the story's file names start, from the parts
      kinds           in order, the kind of each file, from a regular expression on its path
                      (match, and optionally exclude); a file no kind matches is 'other'. A kind
                      marked "story": true is one only stories have (acceptance criteria, say)
    Pulls only when the clone is on that branch with no local changes. Otherwise fetches and lists
    files as origin/<branch>:<path>, readable with git -C <clone> show origin/<branch>:<path>.

    When the templates find nothing, it searches on before giving up, and says so: first names
    starting with the story's prefix anywhere under root (fallback "whole-root"), then names that
    contain what was passed, or a shorter tail of it (fallback "name-search"; this also covers a code
    codePattern does not recognize). Files found that way come with a note naming the value that
    did not fit. When nothing is found, the error says what was searched and what to try.

    -Check also reports how the values fit the repository (coverage): files of a story-only kind
    whose name codePattern does not recognize, and files with a recognized code that folderTemplate
    or fileTemplate would not lead to. Test-Kit.ps1 warns when either is not 0.

.EXAMPLE
    Get-GitSpecs.ps1 <story code>
    Get-GitSpecs.ps1 -Check

.NOTES
    Exit codes: 0 found (or -Check passed), 1 no files matched or bad input, 2 no clone configured.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Story,
    [string] $Clone,
    [switch] $Check,
    [switch] $Json
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
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $script:kitName = (Get-Content -Raw -LiteralPath $marker).Trim()
            $script:kitSkillsRoot = Split-Path -Parent $dir
            return $script:kitName
        }
        $up = Split-Path -Parent $dir
        if ($up -eq $dir) { break }
        $dir = $up
    }
    Stop-Kit 2 "No .kit file in a folder above $PSScriptRoot. Reinstall the kit."
}

# The folder that holds the installed skills: the parent of the skill whose .kit names the kit.
function Get-KitSkillsRoot { [void](Get-KitName); $script:kitSkillsRoot }

function Get-KitVarPrefix { (Get-KitName).ToUpperInvariant() -replace '[^A-Z0-9]', '_' }

# Windows only for now: Get-KitRoot, Get-KitEnv and Set-KitEnv are what a macOS or Linux port changes.
# The kit's folder for the person: %LOCALAPPDATA%\<kit name>, or the folder in <KIT>_HOME.
function Get-KitRoot {
    $over = [Environment]::GetEnvironmentVariable((Get-KitVarPrefix) + '_HOME', 'Process')
    if ($over) { return $over }
    Join-Path $env:LOCALAPPDATA (Get-KitName)
}

# Read from the process first, then from the user's own: a program started before the variable was set does not have it.
function Get-KitEnv([string]$Name, [switch]$Saved) {
    if (-not $Name) { return $null }
    if ($Saved) { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($Name, 'User') }
    $v
}

function Set-KitEnv([string]$Name, [string]$Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User') }

function Get-KitConfigVar { (Get-KitVarPrefix) + '_CONFIG' }

# The project pack in use, among those installed in setup\packs: the one <KIT>_PACK names; else the one
# whose repositories (repos[].name) include the git repository of the current folder; else the person's
# default (defaultPack in settings.json, in the kit's folder); else the only one. $null without packs.
# When several are installed and none of that applies it stops, unless -Quiet (then $null).
function Get-KitPack([switch]$Quiet) {
    if (-not $script:kitPackKnown) {
        $script:kitPackKnown = $true
        $script:kitPack = $null
        $script:kitPackFrom = 'none'
        $packsDir = Join-Path (Get-KitSkillsRoot) 'setup\packs'
        $script:kitPacks = @(Get-ChildItem -LiteralPath $packsDir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'pack.json') -PathType Leaf } | ForEach-Object { $_.Name })
        if ($script:kitPacks.Count) {
            $forced = [Environment]::GetEnvironmentVariable((Get-KitVarPrefix) + '_PACK', 'Process')
            $origin = ''
            if (-not $forced) {
                $here = try { $PWD.ProviderPath } catch { '' }
                if ($here) { $origin = "$(& git -C $here remote get-url origin 2>$null)".Trim() }
            }
            $settingsFile = Join-Path (Get-KitRoot) 'settings.json'
            $default = if (Test-Path -LiteralPath $settingsFile -PathType Leaf) { try { [string](Get-Content -Raw -Encoding utf8 -LiteralPath $settingsFile | ConvertFrom-Json).defaultPack } catch { '' } } else { '' }
            if ($forced) {
                if ($forced -notin $script:kitPacks) { Stop-Kit 2 "$((Get-KitVarPrefix) + '_PACK') names '$forced', which is not installed ($($script:kitPacks -join ', '))." }
                $script:kitPack = $forced; $script:kitPackFrom = 'variable'
            }
            if (-not $script:kitPack -and $origin) {
                foreach ($name in $script:kitPacks) {
                    $packValues = try { Get-Content -Raw -Encoding utf8 -LiteralPath (Join-Path $packsDir "$name\pack.json") | ConvertFrom-Json } catch { $null }
                    $mine = @($packValues.repos | Where-Object { $_ -and $_.name -and $origin -match "[/:]$([regex]::Escape([string]$_.name))(\.git)?/?$" })
                    if ($mine.Count) { $script:kitPack = $name; $script:kitPackFrom = 'repository'; break }
                }
            }
            if (-not $script:kitPack -and $default -and $default -in $script:kitPacks) { $script:kitPack = $default; $script:kitPackFrom = 'default' }
            if (-not $script:kitPack -and $script:kitPacks.Count -eq 1) { $script:kitPack = $script:kitPacks[0]; $script:kitPackFrom = 'only' }
            if (-not $script:kitPack) { $script:kitPackFrom = 'unchosen' }
        }
    }
    if ($script:kitPackFrom -eq 'unchosen' -and -not $Quiet) {
        Stop-Kit 2 "This folder is not in a repository of any installed project ($($script:kitPacks -join ', ')) and no default is chosen. Work from a project's repository, or choose a default with /setup."
    }
    $script:kitPack
}

# The person's files for the project in use: <kit folder>\<pack>, or the kit folder without packs.
# With -Quiet, $null while the project is not chosen.
function Get-KitHome([switch]$Quiet) {
    $pack = Get-KitPack -Quiet:$Quiet
    if ($pack) { return Join-Path (Get-KitRoot) $pack }
    if ($script:kitPackFrom -eq 'unchosen') { return $null }
    Get-KitRoot
}

function Get-KitConfigPath([switch]$Quiet) {
    $override = [Environment]::GetEnvironmentVariable((Get-KitConfigVar), 'Process')
    if ($override) { return $override }
    $folder = Get-KitHome -Quiet:$Quiet
    if (-not $folder) { return $null }
    Join-Path $folder 'config.json'
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

$cfg = Get-KitConfig
if (-not $Clone) { $Clone = Get-KitValue $cfg 'paths.specsRepo' -Path }
$ProviderKey = 'providers.git-files'
$SpecBranch = Get-KitValue $cfg "$ProviderKey.branch" -Required
$SpecRoot = ([string](Get-KitValue $cfg "$ProviderKey.root" -Required)).Trim('/')
$CodePattern = [string](Get-KitValue $cfg "$ProviderKey.codePattern" -Required)
$CodeHelp = [string](Get-KitValue $cfg "$ProviderKey.codeHelp")
if (-not $CodeHelp) { $CodeHelp = 'a story code' }
$Upper = @(Get-KitValue $cfg "$ProviderKey.upper" | Where-Object { $_ })
$Pad = Get-KitValue $cfg "$ProviderKey.pad"
$Aliases = Get-KitValue $cfg "$ProviderKey.aliases"
$FolderTemplate = [string](Get-KitValue $cfg "$ProviderKey.folderTemplate" -Required)
$FileTemplate = [string](Get-KitValue $cfg "$ProviderKey.fileTemplate" -Required)
$Kinds = @(Get-KitValue $cfg "$ProviderKey.kinds" | Where-Object { $_ })
$specsEntry = @(Get-KitValue $cfg 'repos') | Where-Object { $_.path -eq 'paths.specsRepo' } | Select-Object -First 1
$Host_ = if ($specsEntry -and $specsEntry.cloneUrl) { ([uri]$specsEntry.cloneUrl).Host } else { 'the specification server' }

if (-not $Clone -or -not (Test-Path -LiteralPath (Join-Path $Clone '.git'))) {
    Stop-Kit 2 "No specification clone (paths.specsRepo is '$Clone'). Set it with /setup, which can also clone it."
}

function Invoke-Git {
    # Windows PowerShell turns git's stderr warnings into terminating errors under Stop.
    $ErrorActionPreference = 'Continue'
    & git -C $Clone @args 2>$null
}

$FileCodePattern = [string](Get-KitValue $cfg "$ProviderKey.fileCodePattern")
if (-not $FileCodePattern) { $FileCodePattern = $CodePattern }
$GroupNames = @{}
foreach ($pattern in $CodePattern, $FileCodePattern) { $GroupNames[$pattern] = @(([regex]$pattern).GetGroupNames() | Where-Object { $_ -notmatch '^\d+$' }) }

# The parts of the story code a text holds, as the templates use them: an alias when one matches
# (ignoring case), else upper-cased when listed in upper; then padded with zeros when listed in pad.
# $null when the pattern (codePattern unless another is given) finds no code in the text.
function Get-CodeParts([string]$Text, [string]$Pattern = $CodePattern) {
    if ($Text -notmatch $Pattern) { return $null }
    $found = $Matches.Clone()
    $p = @{ root = $SpecRoot }
    foreach ($name in $GroupNames[$Pattern]) {
        $value = [string]$found[$name]
        $alias = if ($Aliases -and $Aliases.PSObject.Properties[$name]) { $Aliases.$name.PSObject.Properties | Where-Object { $_.Name -ieq $value } | Select-Object -First 1 } else { $null }
        if ($alias) { $value = [string]$alias.Value }
        elseif ($name -in $Upper) { $value = $value.ToUpper() }
        if ($Pad -and $Pad.PSObject.Properties[$name] -and $value -match '^\d+$') { $value = "{0:D$([int]$Pad.$name)}" -f [int]$value }
        $p[$name] = $value
    }
    $p
}

function Expand-SpecTemplate([string]$Template, $Parts) {
    [regex]::Replace($Template, '\{(\w+)\}', { param($m) [string]$Parts[$m.Groups[1].Value] }.GetNewClosure())
}

# The first kind whose expressions match a path, or $null.
function Get-Kind([string]$Path) {
    foreach ($k in $Kinds) {
        if ($Path -match [string]$k.match -and (-not $k.exclude -or $Path -notmatch [string]$k.exclude)) { return $k }
    }
    $null
}

# What a person may have passed, from the most specific to the least: the text's last path segment
# without extensions, then the same without its leading words; each with a letter and a digit, so a
# plain word never matches half the repository.
function Get-NameCandidates([string]$Text) {
    $leaf = (($Text -replace '[?#].*$', '') -split '[\\/]')[-1] -replace '(\.[A-Za-z0-9]{1,8})+$', ''
    $tokens = @($leaf -split '[^A-Za-z0-9]+' | Where-Object { $_ })
    for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
        $c = $tokens[$i..($tokens.Count - 1)] -join '_'
        if ($c.Length -ge 6 -and $c -match '\d' -and $c -match '[A-Za-z]') { $c }
    }
}

# How well the configuration fits the repository. unrecognized: files of a kind only stories have
# ("story": true) whose name fileCodePattern does not recognize. misplaced: files whose code it
# recognizes but whose folder or name the templates would not lead to. Both should be 0.
function Get-Coverage([string]$Ref) {
    $typed = 0; $story = 0; $recognized = 0
    $unrecognized = [Collections.Generic.List[string]]::new()
    $misplaced = [Collections.Generic.List[string]]::new()
    foreach ($f in @(Invoke-Git ls-tree -r --name-only $Ref "$SpecRoot/")) {
        $k = Get-Kind $f
        if (-not $k) { continue }
        $typed++
        $leaf = Split-Path $f -Leaf
        $p = Get-CodeParts $leaf $FileCodePattern
        if ($k.story -eq $true) { $story++; if (-not $p) { $unrecognized.Add($f) } }
        if (-not $p) { continue }
        $recognized++
        if (-not $f.StartsWith((Expand-SpecTemplate $FolderTemplate $p), [StringComparison]::Ordinal) -or -not ($leaf -like "$(Expand-SpecTemplate $FileTemplate $p)*")) { $misplaced.Add($f) }
    }
    [pscustomobject]@{
        ref = $Ref; files = $typed; storyFiles = $story; recognized = $recognized
        unrecognized = $unrecognized.Count; misplaced = $misplaced.Count
        examples = [pscustomobject]@{ unrecognized = @($unrecognized | Select-Object -First 5); misplaced = @($misplaced | Select-Object -First 5) }
    }
}

$branch = Invoke-Git branch --show-current
$dirty = Invoke-Git status --porcelain

if ($Check) {
    $origin = Invoke-Git remote get-url origin
    # Offline: the clone as it is, or its last fetched copy of the branch when it is on another one.
    $checkRef = if ($branch -eq $SpecBranch -and -not $dirty) { 'HEAD' } elseif (Invoke-Git rev-parse --verify --quiet "origin/$SpecBranch") { "origin/$SpecBranch" } else { 'HEAD' }
    $coverage = Get-Coverage $checkRef
    if ($Json) { [pscustomobject]@{ clone = $Clone; origin = "$origin"; branch = "$branch"; coverage = $coverage } | ConvertTo-Json -Depth 4; exit 0 }
    "Specification clone $Clone (origin $origin)"
    "At $($coverage.ref): $($coverage.files) spec files, $($coverage.storyFiles) of a story-only kind, $($coverage.recognized) with a story code."
    if ($coverage.unrecognized) { "$($coverage.unrecognized) story files have a name fileCodePattern does not recognize, e.g. $($coverage.examples.unrecognized -join ', ')" }
    if ($coverage.misplaced) { "$($coverage.misplaced) files have a story code but folderTemplate or fileTemplate would not find them, e.g. $($coverage.examples.misplaced -join ', ')" }
    exit 0
}

if (-not $Story) { Stop-Kit 1 'Pass a story code, slug or spec link, or -Check.' }
$parts = Get-CodeParts $Story

$ref = 'HEAD'
$note = $null

if ($branch -eq $SpecBranch -and -not $dirty) {
    Invoke-Git pull --ff-only --quiet origin $SpecBranch | Out-Null
    if ($LASTEXITCODE -ne 0) { $note = "Could not reach $Host_ (VPN?). Local copy may be out of date." }
}
else {
    Invoke-Git fetch --quiet origin $SpecBranch | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $ref = "origin/$SpecBranch"
        $note = "Clone is on '$branch' or has local changes; not pulled. Read files with: git -C $Clone show origin/${SpecBranch}:<path>"
    }
    else { $note = "Could not reach $Host_ (VPN?) and the clone is not clean $SpecBranch. Local copy may be out of date." }
}

$head = Invoke-Git log -1 --format='%h %cd' --date=short $ref
$files = @()
$fallback = $null
$fallbackNote = $null
$tried = [Collections.Generic.List[string]]::new()

if ($parts) {
    $folder = Expand-SpecTemplate $FolderTemplate $parts
    $prefix = Expand-SpecTemplate $FileTemplate $parts
    $files = @(Invoke-Git ls-tree -r --name-only $ref $folder | Where-Object { (Split-Path $_ -Leaf) -like "$prefix*" })
    if (-not $files.Count -and $folder.TrimEnd('/') -ne $SpecRoot) {
        $tried.Add("names starting with $prefix anywhere under $SpecRoot/")
        $files = @(Invoke-Git ls-tree -r --name-only $ref "$SpecRoot/" | Where-Object { (Split-Path $_ -Leaf) -like "$prefix*" })
        if ($files.Count) {
            $fallback = 'whole-root'
            $fallbackNote = "Found outside $folder, by searching all of $SpecRoot/: the pack's folderTemplate (providers.git-files) does not fit where this story's files are."
        }
    }
}
if (-not $files.Count) {
    $all = @(Invoke-Git ls-tree -r --name-only $ref "$SpecRoot/")
    $candidates = @(Get-NameCandidates $Story)
    foreach ($candidate in $candidates) {
        $hits = @($all | Where-Object { ('_' + ((Split-Path $_ -Leaf) -replace '[^A-Za-z0-9]+', '_') + '_').IndexOf("_$($candidate)_", [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if (-not $hits.Count) { continue }
        if ($hits.Count -gt 40) { $tried.Add("names containing '$candidate' ($($hits.Count) files: too many to be one story's)"); break }
        $files = $hits
        $fallback = 'name-search'
        $fallbackNote = if ($parts) { "No file name starts with $prefix; these names contain '$candidate'. Check they are this story's: the pack's fileTemplate (providers.git-files) does not fit this story's file names." }
        else { "The pack's codePattern (providers.git-files) does not recognize '$Story' as $CodeHelp; these names contain '$candidate'. Check they are this story's." }
        break
    }
    if (-not $files.Count -and $candidates.Count -and -not @($tried | Where-Object { $_ -like 'names containing*' }).Count) { $tried.Add("names containing '$($candidates[0])' or a shorter tail of it") }
}

if (-not $files.Count) {
    $msg = if ($parts) { "No spec files for $prefix under $folder at $ref ($head)." } else { "Cannot find $CodeHelp in '$Story'." }
    if ($tried.Count) { $msg += " Also searched: $($tried -join '; ')." }
    $msg += ' What to try:'
    if (-not $parts) { $msg += " pass the story's code as its ticket's description writes it, or a link to one of its spec files;" }
    $msg += " a story newer than the clone ($head) is not in it yet;"
    $msg += " if the specification repository changed how it names or places files, the pack's providers.git-files values need updating (-Check counts the files they cannot find)."
    if ($note) { $msg += " $note" }
    Stop-Kit 1 $msg
}
if ($fallbackNote) { $note = if ($note) { "$note $fallbackNote" } else { $fallbackNote } }

function Format-Path([string] $p) {
    if ($ref -ne 'HEAD') { return "${ref}:$p" }
    (Join-Path $Clone $p) -replace '\\', '/'
}

$listed = @{}
$rows = [Collections.Generic.List[object]]::new()
foreach ($k in $Kinds) {
    $match = [string]$k.match
    $exclude = [string]$k.exclude
    foreach ($h in @($files | Where-Object { $_ -match $match -and (-not $exclude -or $_ -notmatch $exclude) } | Sort-Object)) {
        $rows.Add([pscustomobject]@{ kind = [string]$k.kind; path = (Format-Path $h) })
        $listed[$h] = $true
    }
}
foreach ($f in $files | Where-Object { -not $listed[$_] }) { $rows.Add([pscustomobject]@{ kind = 'other'; path = (Format-Path $f) }) }

if ($Json) {
    [pscustomobject]@{ clone = $Clone; ref = $ref; head = $head; note = $note; fallback = $fallback; files = $rows.ToArray() } | ConvertTo-Json -Depth 4
    exit 0
}
"specifications $ref $head"
foreach ($r in $rows) { '{0,-15} {1}' -f $r.kind, $r.path }
if ($note) { $note }
exit 0
