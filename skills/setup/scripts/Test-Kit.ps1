#Requires -Version 7
<#
.SYNOPSIS
    Checks the kit: its own files, the person's configuration, and that each script answers.

.DESCRIPTION
    Three levels, each including the ones before:
      -Static    the kit's files only, read from this copy: the defaults parse, every skill and
                 script exists, the configuration block is identical in every script, the
                 templates have the same texts in every language and every text a script uses,
                 the template block is identical in every script that has one, the view presets
                 are well formed, and no kit file outside setup/defaults holds a value that
                 belongs in the configuration (kit.lint). Run this before committing a kit change.
      -Offline   plus the person's configuration: identity, saved views, credential variables,
                 clones, people files, own templates, the scripts that need no network, and the
                 kit's hooks in -HooksFile, in the shape of -AgentHost (cursor, the default:
                 .cursor\hooks.json; claude: Claude Code's .claude\settings.json).
      (default)  plus each capability that is on, against its service (the board and every saved
                 view, the CI, the environments).
      -Fake      the kit's files, then the whole engine against the fake provider, with no account
                 and no network: a throwaway git repository, pack and configuration in a temporary
                 folder; init, the brief, the planner, delivery, a board write, a chat link and the
                 write guard, each checked against the answers the fake data must give. Does not
                 read or change the person's configuration. For whoever changes the engine or writes
                 a provider. -KeepFake keeps the temporary folder to look at what the engine wrote.

    Every script is run as a child process, so a configuration error in one is reported here
    instead of ending the test.

.NOTES
    Exit codes: 0 no failures (warnings allowed), 1 at least one failure.
#>
[CmdletBinding()]
param(
    [switch] $Static,
    [switch] $Offline,
    [string] $SkillsRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [ValidateSet('cursor', 'claude')]
    [string] $AgentHost = 'cursor',
    [string] $HooksFile,
    [string] $Pack,
    [switch] $Fake,
    [switch] $KeepFake,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$results = [Collections.Generic.List[object]]::new()
function Add-Result([string]$Area, [string]$Check, [ValidateSet('ok', 'warn', 'fail', 'skip')][string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ area = $Area; check = $Check; status = $Status; detail = $Detail })
}

function Invoke-Kit([string]$Script, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $lines = & pwsh -NoProfile -File $Script @Arguments 2>&1
    $code = $LASTEXITCODE
    $err = @($lines | Where-Object { $_ -is [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    $out = @($lines | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
    [pscustomobject]@{ code = $code; out = ($out -join "`n"); err = (($err -join ' ').Trim()) }
}

function ConvertFrom-KitJson([string]$Text) {
    try { $Text | ConvertFrom-Json -NoEnumerate } catch { $null }
}

function Merge-Object($Base, $Over) {
    if ($Base -isnot [Management.Automation.PSCustomObject] -or $Over -isnot [Management.Automation.PSCustomObject]) {
        if ($Over -is [array]) { return , $Over }
        return $Over
    }
    $out = [pscustomobject]@{}
    foreach ($p in $Base.PSObject.Properties) { $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    foreach ($p in $Over.PSObject.Properties) {
        $v = if ($out.PSObject.Properties[$p.Name]) { Merge-Object $out.($p.Name) $p.Value } else { $p.Value }
        $out | Add-Member -NotePropertyName $p.Name -NotePropertyValue $v -Force
    }
    $out
}

# A team file: the pack's copy when the pack has one, else the kit's (setup\defaults).
function Get-TeamFile([string]$Relative) {
    if ($script:packDir) {
        $packed = Join-Path $script:packDir $Relative
        if (Test-Path -LiteralPath $packed -PathType Leaf) { return $packed }
    }
    Join-Path $SkillsRoot "setup\defaults\$Relative"
}

# Every provider manifest in the kit and in the pack, with its folder.
function Get-ProviderManifests {
    $roots = @(Join-Path $SkillsRoot ([string]$defaults.kit.providerRoot))
    if ($script:packDir) { $roots += Join-Path $script:packDir 'providers' }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter 'provider.json' -File) {
            $manifest = ConvertFrom-KitJson (Get-Content -Raw -Encoding utf8 -LiteralPath $file.FullName)
            [pscustomobject]@{ file = $file.FullName; dir = $file.DirectoryName; manifest = $manifest }
        }
    }
}

function Get-Prop($Object, [string]$Dotted) {
    $v = $Object
    foreach ($part in $Dotted -split '\.') {
        if ($null -eq $v -or $v -isnot [Management.Automation.PSCustomObject] -or -not $v.PSObject.Properties[$part]) { return $null }
        $v = $v.$part
    }
    $v
}

function Read-Snippets([string]$File) {
    $found = [ordered]@{}
    $twice = [Collections.Generic.List[string]]::new()
    $current = $null
    $buffer = [Collections.Generic.List[string]]::new()
    foreach ($textLine in Get-Content -Encoding utf8 -LiteralPath $File) {
        if ($textLine -match '^<!--\s*@([A-Za-z0-9_.-]+)\s*-->\s*$') {
            if ($current) { $found[$current] = $buffer -join "`n" }
            $current = $Matches[1]
            if ($found.Contains($current)) { $twice.Add($current) }
            $buffer.Clear()
        }
        elseif ($current) { $buffer.Add($textLine) }
    }
    if ($current) { $found[$current] = $buffer -join "`n" }
    [pscustomobject]@{ snippets = $found; twice = @($twice) }
}

# The line every SKILL.md uses to find the kit's scripts. Install.ps1 fills {{kit.configVar}} and {{kit.name}}.
$locatorLine = '$kit = (pwsh -NoProfile -File "{{kit.setupScript}}" scripts) -join "`n" | ConvertFrom-Json'

function Expand-KitPath([string]$Value) {
    if (-not $Value) { return $Value }
    [Environment]::ExpandEnvironmentVariables($Value.Replace('{kitHome}', (Join-Path $env:LOCALAPPDATA $script:kitName)))
}

function Get-Placeholders([string]$Text) {
    (@([regex]::Matches($Text, '\{\{([A-Za-z0-9_]+)\}\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)) -join ','
}

function Test-Views([string]$Area, $Views, [switch]$AllowEmpty) {
    $list = @($Views | Where-Object { $null -ne $_ })
    if (-not $list.Count) {
        if ($AllowEmpty) { return }
        Add-Result $Area 'views' 'warn' 'No saved views; the other skills have nothing to show. /setup step 6 chooses them.'
        return
    }
    $ids = @{}
    foreach ($v in $list) {
        $missing = @('id', 'title', 'query' | Where-Object { -not (Get-Prop $v $_) })
        if ($missing.Count) { Add-Result $Area "view $($v.id)" 'fail' "Missing: $($missing -join ', ')."; continue }
        if ($ids[$v.id]) { Add-Result $Area "view $($v.id)" 'fail' 'The id is used twice.'; continue }
        $ids[$v.id] = $true
        $unknown = @([regex]::Matches($v.query, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin 'project', 'me', 'board' })
        if ($unknown.Count) { Add-Result $Area "view $($v.id)" 'fail' "Unknown placeholder: {$($unknown -join '}, {')}. Known: {project}, {me}, {board}."; continue }
        if ($v.query -match '"') { Add-Result $Area "view $($v.id)" 'fail' 'The query has double quotes; use single quotes inside it.'; continue }
        if ($v.PSObject.Properties['qaCheckStatuses'] -and $v.qaCheckStatuses -isnot [array]) { Add-Result $Area "view $($v.id)" 'fail' 'qaCheckStatuses must be a list: ["*"] for every status, [] for none.'; continue }
        if ($v.PSObject.Properties['linkedTests'] -and $v.linkedTests -isnot [bool]) { Add-Result $Area "view $($v.id)" 'fail' 'linkedTests must be true or false, without quotes.'; continue }
        Add-Result $Area "view $($v.id)" 'ok'
    }
}

# --- Static: the kit's own files ---------------------------------------------------------------

$defaultsFile = Join-Path $SkillsRoot 'setup\defaults\config.json'
$defaults = if (Test-Path -LiteralPath $defaultsFile) { ConvertFrom-KitJson (Get-Content -Raw -Encoding utf8 -LiteralPath $defaultsFile) }
if ($null -eq $defaults) {
    Add-Result 'kit' 'defaults' 'fail' "Missing or not valid JSON: $defaultsFile"
}
else {
    Add-Result 'kit' 'defaults' 'ok' $defaultsFile
    $engineKitName = [string]$defaults.kit.name
    $engineVersion = [string]$defaults.kit.version
    $installRecordFile = Join-Path $SkillsRoot 'setup\.kit-source.json'
    $installRecord = if (Test-Path -LiteralPath $installRecordFile -PathType Leaf) { ConvertFrom-KitJson (Get-Content -Raw -Encoding utf8 -LiteralPath $installRecordFile) }
    $commitNote = if ($installRecord -and $installRecord.PSObject.Properties['commit'] -and $installRecord.commit) { " (commit $($installRecord.commit))" } else { '' }
    if ($engineVersion -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') { Add-Result 'kit' 'version' 'ok' "$engineKitName $engineVersion$commitNote" }
    else { Add-Result 'kit' 'version' 'fail' "kit.version in $defaultsFile is '$engineVersion'; it must look like 1.2.0." }
    # The pack to check: -Pack, else the installed pack in use where this runs (the kit picks it by the
    # current folder's repository, the default, or the only one).
    $packFile = if ($Pack) { Join-Path ([IO.Path]::GetFullPath($Pack)) 'pack.json' }
    else {
        $installedPacks = @(Get-ChildItem -LiteralPath (Join-Path $SkillsRoot 'setup\packs') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'pack.json') -PathType Leaf } | ForEach-Object { $_.Name })
        if ($installedPacks.Count) {
            $pk = Invoke-Kit (Join-Path $SkillsRoot 'setup\scripts\Initialize-Config.ps1') @('packs')
            $inUse = if ($pk.code -eq 0) { [string](ConvertFrom-KitJson $pk.out).active } else { '' }
            if (-not $inUse) { $inUse = $installedPacks[0]; Add-Result 'kit' 'pack' 'warn' "Several packs and none in use here ($($installedPacks -join ', ')): checking $inUse. Run the test from a project's repository to check its pack." }
            Join-Path $SkillsRoot "setup\packs\$inUse\pack.json"
        }
        else { '' }
    }
    $script:packDir = $null
    if ($packFile -and (Test-Path -LiteralPath $packFile -PathType Leaf)) {
        $packCfg = ConvertFrom-KitJson (Get-Content -Raw -Encoding utf8 -LiteralPath $packFile)
        if ($null -eq $packCfg) { Add-Result 'kit' 'pack' 'fail' "Not valid JSON: $packFile" }
        else {
            $defaults = Merge-Object $defaults $packCfg
            $script:packDir = Split-Path -Parent $packFile
            Add-Result 'kit' 'pack' 'ok' "$packFile ($([string]$packCfg.pack.name))"
            if ($packCfg.PSObject.Properties['kit'] -and $packCfg.kit.PSObject.Properties['name'] -and [string]$packCfg.kit.name -ne $engineKitName) {
                Add-Result 'kit' 'pack kit.name' 'warn' "The pack sets kit.name ('$($packCfg.kit.name)'), which the installer ignores: the kit keeps its name, $engineKitName. Remove it from pack.json."
            }
            if ($packCfg.PSObject.Properties['kit'] -and $packCfg.kit.PSObject.Properties['minVersion']) {
                $minVersion = [string]$packCfg.kit.minVersion
                $minParsed = $null; $kitParsed = $null
                if (-not [version]::TryParse(($minVersion -split '[-+]')[0], [ref]$minParsed)) { Add-Result 'kit' 'pack kit.minVersion' 'fail' "kit.minVersion is '$minVersion'; it must look like 1.2.0." }
                elseif ([version]::TryParse(($engineVersion -split '[-+]')[0], [ref]$kitParsed) -and $kitParsed -lt $minParsed) { Add-Result 'kit' 'pack kit.minVersion' 'fail' "The pack needs $engineKitName $minVersion or later, and this kit is $engineVersion. Update the kit." }
                else { Add-Result 'kit' 'pack kit.minVersion' 'ok' "needs $minVersion or later; the kit is $engineVersion" }
            }
        }
    }
    elseif ($Pack) { Add-Result 'kit' 'pack' 'fail' "No pack.json in $Pack" }
    $script:kitName = $engineKitName
    if (-not $HooksFile -and $defaults.kit.agentHosts.$AgentHost) { $HooksFile = Join-Path $env:USERPROFILE ([string]$defaults.kit.agentHosts.$AgentHost.hooksFile) }
    $kitConfigVar = ($kitName.ToUpperInvariant() -replace '[^A-Z0-9]', '_') + '_CONFIG'
    $renderedLocator = $locatorLine.Replace('{{kit.setupScript}}', (Join-Path $SkillsRoot 'setup\scripts\Initialize-Config.ps1'))

    foreach ($skill in @($defaults.kit.skills)) {
        $md = Join-Path $SkillsRoot "$skill\SKILL.md"
        if (-not (Test-Path -LiteralPath $md)) { Add-Result 'kit' "skill $skill" 'fail' "No SKILL.md in $SkillsRoot\$skill"; continue }
        $head = (Get-Content -Raw -Encoding utf8 -LiteralPath $md) -split "`n" | Select-Object -First 6
        $name = ($head | Where-Object { $_ -match '^name:\s*(\S+)' } | Select-Object -First 1) -replace '^name:\s*', ''
        if ("$name".Trim() -ne $skill) { Add-Result 'kit' "skill $skill" 'fail' "SKILL.md says name '$("$name".Trim())'; the folder is '$skill'."; continue }
        if (-not ($head | Where-Object { $_ -match '^description:\s*\S' })) { Add-Result 'kit' "skill $skill" 'fail' 'SKILL.md has no description.'; continue }
        $markerFile = Join-Path $SkillsRoot "$skill\.kit"
        if (-not (Test-Path -LiteralPath $markerFile)) { Add-Result 'kit' "skill $skill" 'fail' 'No .kit marker; Install.ps1 would not recognize the folder as the kit''s.'; continue }
        if ((Get-Content -Raw -LiteralPath $markerFile).Trim() -ne $engineKitName) { Add-Result 'kit' "skill $skill" 'fail' ".kit does not say '$engineKitName' (kit.name); the scripts would read another kit's configuration."; continue }
        $mdText = Get-Content -Raw -Encoding utf8 -LiteralPath $md
        $findsScripts = $mdText.Contains('ConvertFrom-Json).scripts') -or $mdText.Contains(' scripts) -join "`n" | ConvertFrom-Json')
        if ($findsScripts -and -not ($mdText.Contains($locatorLine) -or $mdText.Contains($renderedLocator))) {
            Add-Result 'kit' "skill $skill" 'fail' "SKILL.md finds the scripts with a line other than the kit's: $locatorLine"; continue
        }
        Add-Result 'kit' "skill $skill" 'ok'
    }

    foreach ($p in @('kit.teamPeople', 'kit.teamNotes')) {
        $f = Get-TeamFile ([string](Get-Prop $defaults $p))
        Add-Result 'kit' $p $(if (Test-Path -LiteralPath $f -PathType Leaf) { 'ok' } else { 'fail' }) $f
    }

    $standalone = @($defaults.kit.standalone)
    $reference = $null
    foreach ($s in $defaults.kit.scripts.PSObject.Properties) {
        $file = Join-Path $SkillsRoot $s.Value
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Add-Result 'kit' "script $($s.Name)" 'fail' "Missing: $file"; continue }
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { Add-Result 'kit' "script $($s.Name)" 'fail' "Does not parse, line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)"; continue }
        if ($s.Name -in $standalone) { Add-Result 'kit' "script $($s.Name)" 'ok' 'standalone'; continue }
        $text = (Get-Content -Raw -Encoding utf8 -LiteralPath $file) -replace "`r`n", "`n"
        $m = [regex]::Match($text, '(?s)# kit-config:start.*?# kit-config:end')
        if (-not $m.Success) { Add-Result 'kit' "script $($s.Name)" 'fail' 'No configuration block (# kit-config:start ... # kit-config:end).'; continue }
        if ($null -eq $reference) { $reference = @{ name = $s.Name; text = $m.Value } }
        if ($m.Value -ne $reference.text) { Add-Result 'kit' "script $($s.Name)" 'fail' "Its configuration block differs from the one in '$($reference.name)'. Copy the block so every script has the same one."; continue }
        Add-Result 'kit' "script $($s.Name)" 'ok'
    }

    # Providers: a valid manifest, a script that exists, and the same configuration block.
    $knownCapabilities = @($defaults.capabilities.PSObject.Properties | ForEach-Object { $_.Name })
    $providerNames = @{}
    foreach ($pm in @(Get-ProviderManifests)) {
        $label = "provider $(Split-Path -Leaf $pm.dir)"
        $man = $pm.manifest
        if ($null -eq $man) { Add-Result 'kit' $label 'fail' "Not valid JSON: $($pm.file)"; continue }
        if (-not $man.name -or -not @($man.capabilities).Count) { Add-Result 'kit' $label 'fail' "$($pm.file) needs name and capabilities."; continue }
        $label = "provider $($man.name)"
        $strangeCaps = @($man.capabilities | Where-Object { $_ -notin $knownCapabilities })
        if ($strangeCaps.Count) { Add-Result 'kit' $label 'fail' "Unknown capability: $($strangeCaps -join ', '). Known: $($knownCapabilities -join ', ')."; continue }
        $providerNames[[string]$man.name] = $true
        if (-not $man.script) { Add-Result 'kit' $label 'ok' "no script yet ($(@($man.capabilities) -join ', '))"; continue }
        $file = Join-Path $pm.dir $man.script
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Add-Result 'kit' $label 'fail' "Missing: $file"; continue }
        $parseErrors = $null
        [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { Add-Result 'kit' $label 'fail' "Does not parse, line $($parseErrors[0].Extent.StartLineNumber): $($parseErrors[0].Message)"; continue }
        $text = (Get-Content -Raw -Encoding utf8 -LiteralPath $file) -replace "`r`n", "`n"
        $m = [regex]::Match($text, '(?s)# kit-config:start.*?# kit-config:end')
        if (-not $m.Success) { Add-Result 'kit' $label 'fail' 'No configuration block (# kit-config:start ... # kit-config:end).'; continue }
        if ($null -ne $reference -and $m.Value -ne $reference.text) { Add-Result 'kit' $label 'fail' "Its configuration block differs from the one in '$($reference.name)'. Copy the block so every script has the same one."; continue }
        Add-Result 'kit' $label 'ok' "$(@($man.capabilities) -join ', '): $($man.script)"
    }
    foreach ($cap in $knownCapabilities) {
        $chosen = [string](Get-Prop $defaults "capabilities.$cap.provider")
        if ($chosen -and -not $providerNames[$chosen]) { Add-Result 'kit' "capability $cap" 'fail' "Uses the provider '$chosen', which no provider.json in the kit or the pack names." }
    }

    # A provider configured with regular expressions fails only when a command runs; check them here.
    function Test-Pattern([string]$Label, [string]$Pattern) {
        try { return [regex]::new($Pattern) } catch { Add-Result 'kit' $Label 'fail' "Not a valid regular expression: $($_.Exception.InnerException.Message)"; return $null }
    }
    if ([string](Get-Prop $defaults 'capabilities.specs.provider') -eq 'git-files') {
        $gf = Get-Prop $defaults 'providers.git-files'
        $codeRegex = if ($gf.codePattern) { Test-Pattern 'git-files codePattern' ([string]$gf.codePattern) } else { Add-Result 'kit' 'git-files codePattern' 'fail' 'Empty: the provider cannot find a story code.'; $null }
        if ($codeRegex) {
            $codeParts = @(@($codeRegex.GetGroupNames() | Where-Object { $_ -notmatch '^\d+$' }) + 'root')
            $templateParts = @(foreach ($t in [string]$gf.folderTemplate, [string]$gf.fileTemplate) { [regex]::Matches($t, '\{(\w+)\}') | ForEach-Object { $_.Groups[1].Value } }) | Sort-Object -Unique
            $unknownParts = @($templateParts | Where-Object { $_ -notin $codeParts })
            $badKinds = @(@($gf.kinds) | Where-Object { -not $_.kind -or -not $_.match -or -not (Test-Pattern "git-files kind $($_.kind)" ([string]$_.match)) -or ($_.exclude -and -not (Test-Pattern "git-files kind $($_.kind)" ([string]$_.exclude))) })
            $fileRegex = if ($gf.fileCodePattern) { Test-Pattern 'git-files fileCodePattern' ([string]$gf.fileCodePattern) } else { $codeRegex }
            $fileParts = if ($fileRegex) { @(@($fileRegex.GetGroupNames() | Where-Object { $_ -notmatch '^\d+$' }) + 'root') } else { $codeParts }
            $unknownFileParts = @($templateParts | Where-Object { $_ -notin $fileParts })
            if (-not $gf.fileTemplate) { Add-Result 'kit' 'git-files' 'fail' 'fileTemplate is empty: every file would match.' }
            elseif ($unknownParts.Count) { Add-Result 'kit' 'git-files' 'fail' "The templates use {$($unknownParts -join '}, {')}, which codePattern has no named group for. Its parts: $($codeParts -join ', ')." }
            elseif ($unknownFileParts.Count) { Add-Result 'kit' 'git-files' 'fail' "The templates use {$($unknownFileParts -join '}, {')}, which fileCodePattern has no named group for. Its parts: $($fileParts -join ', ')." }
            elseif ($badKinds.Count) { Add-Result 'kit' 'git-files' 'fail' 'Every entry of kinds needs kind and match, both valid.' }
            else { Add-Result 'kit' 'git-files' 'ok' "code parts: $($codeParts -join ', ')" }
        }
    }
    if ([string](Get-Prop $defaults 'capabilities.cd.provider') -eq 'jenkins-deploy') {
        $jd = Get-Prop $defaults 'providers.jenkins-deploy'
        $needs = [ordered]@{ 'deployLog.instanceLine' = @('name', 'version'); 'deployLog.targetLine' = @('name'); 'deployLog.runningLine' = @('version'); liveVersion = @('version'); buildNameVersion = @('version') }
        $set = 0
        foreach ($key in $needs.Keys) {
            $pattern = [string](Get-Prop $jd $key)
            if (-not $pattern) { continue }
            $set++
            $rx = Test-Pattern "jenkins-deploy $key" $pattern
            if (-not $rx) { continue }
            $absent = @($needs[$key] | Where-Object { $_ -notin $rx.GetGroupNames() })
            if ($absent.Count) { Add-Result 'kit' "jenkins-deploy $key" 'fail' "Needs the named group(s) $($absent -join ', '): (?<$($absent[0])>...)." }
            else { Add-Result 'kit' "jenkins-deploy $key" 'ok' }
        }
        $publishJobs = Get-Prop $jd 'publish'
        if (-not $publishJobs -or -not @($publishJobs.PSObject.Properties).Count) { Add-Result 'kit' 'jenkins-deploy publish' 'fail' 'No publish jobs: targets and publishes have nothing to read.' }
        if (-not $set) { Add-Result 'kit' 'jenkins-deploy' 'warn' 'No patterns set: environment versions cannot be read (deployLog, liveVersion).' }
    }

    # Templates: every language has the same texts with the same {{values}}.
    $languages = @($defaults.kit.templateLanguages | Where-Object { $_ })
    $fallback = [string]$defaults.kit.templateFallback
    if ($fallback -notin $languages) { Add-Result 'kit' 'kit.templateFallback' 'fail' "'$fallback' is not in kit.templateLanguages ($($languages -join ', '))." }
    $teamTexts = @{}
    foreach ($t in @($defaults.kit.templates.PSObject.Properties)) {
        $byLang = [ordered]@{}
        $broken = $false
        foreach ($lang in $languages) {
            $f = Get-TeamFile $t.Value.Replace('{language}', $lang)
            if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Add-Result 'kit' "template $($t.Name) $lang" 'fail' "Missing: $f"; $broken = $true; continue }
            $read = Read-Snippets $f
            if ($read.twice.Count) { Add-Result 'kit' "template $($t.Name) $lang" 'fail' "Texts named twice: $($read.twice -join ', ')."; $broken = $true; continue }
            $byLang[$lang] = $read.snippets
        }
        if (-not $byLang.Count) { continue }
        $base = if ($byLang.Contains($fallback)) { $fallback } else { @($byLang.Keys)[0] }
        $teamTexts[$t.Name] = $byLang[$base]
        $diffs = [Collections.Generic.List[string]]::new()
        foreach ($lang in @($byLang.Keys | Where-Object { $_ -ne $base })) {
            $here = $byLang[$lang]
            foreach ($n in $byLang[$base].Keys) {
                if (-not $here.Contains($n)) { $diffs.Add("$lang lacks @$n") }
                elseif ((Get-Placeholders $here[$n]) -ne (Get-Placeholders $byLang[$base][$n])) { $diffs.Add("@$n has other {{values}} in $lang than in $base") }
            }
            foreach ($n in $here.Keys) { if (-not $byLang[$base].Contains($n)) { $diffs.Add("$lang has @$n, $base does not") } }
        }
        if ($diffs.Count) { Add-Result 'kit' "template $($t.Name)" 'fail' (($diffs | Select-Object -First 6) -join '; ') }
        elseif (-not $broken) { Add-Result 'kit' "template $($t.Name)" 'ok' "$($byLang.Count) language(s), $($byLang[$base].Count) texts" }
    }

    # Writing guides: the agent applies them, so they only need to exist and have named sections.
    $teamGuides = @{}
    foreach ($g in @($defaults.kit.guides.PSObject.Properties)) {
        $f = Get-TeamFile ([string]$g.Value)
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Add-Result 'kit' "guide $($g.Name)" 'fail' "Missing: $f"; continue }
        $read = Read-Snippets $f
        if ($read.twice.Count) { Add-Result 'kit' "guide $($g.Name)" 'fail' "Sections named twice: $($read.twice -join ', ')."; continue }
        if (-not $read.snippets.Count) { Add-Result 'kit' "guide $($g.Name)" 'fail' "$f has no sections (each starts with a line <!-- @name -->)."; continue }
        $teamGuides[$g.Name] = $read.snippets
        Add-Result 'kit' "guide $($g.Name)" 'ok' "$($read.snippets.Count) sections: $(@($read.snippets.Keys) -join ', ')"
    }

    # Scripts that write from a template: the same template block, and every text they use exists.
    $templateRef = $null
    foreach ($s in $defaults.kit.scripts.PSObject.Properties) {
        $file = Join-Path $SkillsRoot $s.Value
        if ($s.Name -in $standalone -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $text = (Get-Content -Raw -Encoding utf8 -LiteralPath $file) -replace "`r`n", "`n"
        $uses = [regex]::Match($text, 'Get-KitTemplate \$cfg ''([A-Za-z0-9]+)''')
        $block = [regex]::Match($text, '(?s)# kit-template:start.*?# kit-template:end')
        if (-not $uses.Success -and -not $block.Success) { continue }
        if (-not $block.Success) { Add-Result 'kit' "texts $($s.Name)" 'fail' 'Reads a template but has no template block (# kit-template:start ... # kit-template:end).'; continue }
        if ($null -eq $templateRef) { $templateRef = @{ name = $s.Name; text = $block.Value } }
        if ($block.Value -ne $templateRef.text) { Add-Result 'kit' "texts $($s.Name)" 'fail' "Its template block differs from the one in '$($templateRef.name)'. Copy the block so every script has the same one."; continue }
        if (-not $uses.Success) { continue }
        $known = $teamTexts[$uses.Groups[1].Value]
        if ($null -eq $known) { Add-Result 'kit' "texts $($s.Name)" 'fail' "Reads the template '$($uses.Groups[1].Value)', which kit.templates does not list."; continue }
        $used = [Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($text, "Phrase '([A-Za-z0-9_.-]+)'")) { $used.Add($m.Groups[1].Value) }
        $declared = [regex]::Match($text, '(?m)^# kit-texts[^:]*:(.*)$')
        if ($declared.Success) { foreach ($n in ($declared.Groups[1].Value -split '\s+' | Where-Object { $_ })) { $used.Add($n) } }
        if ($uses.Groups[1].Value -eq 'nextSteps') {
            # An action or a rule that carries its own texts (label and text; reason) needs none in the template.
            foreach ($rule in @($defaults.chief.rules)) {
                $actionDef = Get-Prop $defaults "chief.actions.$($rule.action)"
                if (-not ($actionDef -and (Get-Prop $actionDef 'label') -and (Get-Prop $actionDef 'text'))) { $used.Add("action.$($rule.action)"); $used.Add("label.$($rule.action)") }
                if (-not (Get-Prop $rule 'reason')) { $used.Add("reason.$($rule.id)") }
            }
        }
        if ($uses.Groups[1].Value -eq 'brief') {
            foreach ($section in @($defaults.brief.sections)) { if ($section.type -ne 'views') { $used.Add("title.$($section.type)") } }
        }
        $missing = @($used | Sort-Object -Unique | Where-Object { -not $known.Contains($_) })
        if ($missing.Count) { Add-Result 'kit' "texts $($s.Name)" 'fail' "The $($uses.Groups[1].Value) template has no @$($missing -join ', @')." }
        else { Add-Result 'kit' "texts $($s.Name)" 'ok' "$(@($used | Sort-Object -Unique).Count) texts used, all in the template" }
    }

    # The brief's sections and the chief's rules.
    foreach ($section in @($defaults.brief.sections)) {
        if ($section.requires -and $null -eq (Get-Prop $defaults ([string]$section.requires))) { Add-Result 'kit' "brief section $($section.type)" 'fail' "requires '$($section.requires)', which the defaults do not have." }
        $strangeCaps = @($section.capabilities | Where-Object { $_ -and $_ -notin $knownCapabilities })
        if ($strangeCaps.Count) { Add-Result 'kit' "brief section $($section.type)" 'fail' "Unknown capability: $($strangeCaps -join ', ')." }
    }
    $actionNames = @(if ($defaults.chief.actions) { $defaults.chief.actions.PSObject.Properties | ForEach-Object { $_.Name } })
    $ruleIds = @{}
    foreach ($rule in @($defaults.chief.rules)) {
        if (-not $rule.id -or -not $rule.action) { Add-Result 'kit' 'chief.rules' 'fail' 'A rule has no id or no action.'; continue }
        if ($ruleIds[$rule.id]) { Add-Result 'kit' "chief rule $($rule.id)" 'fail' 'The id is used twice.' }
        $ruleIds[$rule.id] = $true
        if ([string]$rule.action -cnotin $actionNames) { Add-Result 'kit' "chief rule $($rule.id)" 'fail' "Its action '$($rule.action)' is not in chief.actions ($($actionNames -join ', '))." }
        $ownReason = Get-Prop $rule 'reason'
        $reasonGaps = @(if ($ownReason -and $ownReason -isnot [string]) { $languages | Where-Object { -not (Get-Prop $ownReason $_) } })
        if ($reasonGaps.Count) { Add-Result 'kit' "chief rule $($rule.id)" 'fail' "Its reason has no text in: $($reasonGaps -join ', ')." }
    }
    # Actions: the template's texts, or their own in every language; their own also need a how for the agent.
    $nextStepsTexts = $teamTexts['nextSteps']
    foreach ($name in $actionNames) {
        $def = Get-Prop $defaults "chief.actions.$name"
        $inTemplate = $nextStepsTexts -and $nextStepsTexts.Contains("action.$name") -and $nextStepsTexts.Contains("label.$name")
        $strangeNeeds = @(@(Get-Prop $def 'needs') | Where-Object { $_ -and $_ -notin $knownCapabilities })
        if ($strangeNeeds.Count) { Add-Result 'kit' "chief action $name" 'fail' "needs an unknown capability: $($strangeNeeds -join ', ')."; continue }
        if ($inTemplate) { continue }
        $gaps = @(foreach ($field in 'label', 'text') { $map = Get-Prop $def $field; foreach ($lang in $languages) { if (-not ($map -is [string] -and $map) -and -not ($map -and (Get-Prop $map $lang))) { "$field.$lang" } } })
        $ownText = Get-Prop $def 'text'
        $periods = @(if ($ownText -and $ownText -isnot [string]) { $ownText.PSObject.Properties | Where-Object { "$($_.Value)".TrimEnd().EndsWith('.') } | ForEach-Object { $_.Name } })
        if ($gaps.Count) { Add-Result 'kit' "chief action $name" 'fail' "Not in the next-steps template, and its own texts miss: $($gaps -join ', ')." }
        elseif ($periods.Count) { Add-Result 'kit' "chief action $name" 'warn' "Its text ends with a period in: $($periods -join ', '). It completes the plan's sentence (""I suggest: ..."") and the plan adds the period." }
        elseif (-not (Get-Prop $def 'how')) { Add-Result 'kit' "chief action $name" 'warn' 'No how: the agent will not know how to carry it out.' }
        else { Add-Result 'kit' "chief action $name" 'ok' 'own texts and how' }
    }

    foreach ($preset in @($defaults.board.viewPresets.PSObject.Properties)) { Test-Views "preset $($preset.Name)" $preset.Value }

    # Roles: roles\<name>.json in the pack, read between the pack and the person whose user.role is <name>.
    $rolesDir = if ($script:packDir) { Join-Path $script:packDir 'roles' } else { $null }
    foreach ($rf in @(if ($rolesDir -and (Test-Path -LiteralPath $rolesDir -PathType Container)) { Get-ChildItem -LiteralPath $rolesDir -Filter '*.json' -File })) {
        $roleArea = "role $($rf.BaseName)"
        if ($rf.BaseName -notmatch '^[A-Za-z0-9_-]+$') { Add-Result 'kit' $roleArea 'fail' 'The file name is the value of user.role: use only letters, digits, - and _.'; continue }
        $roleCfg = ConvertFrom-KitJson (Get-Content -Raw -Encoding utf8 -LiteralPath $rf.FullName)
        if ($null -eq $roleCfg) { Add-Result 'kit' $roleArea 'fail' "Not valid JSON: $($rf.FullName)"; continue }
        $strange = @($roleCfg.PSObject.Properties.Name | Where-Object { $_ -in 'kit', 'version', 'providers', 'capabilities' })
        if ($strange.Count) { Add-Result 'kit' $roleArea 'fail' "A role holds what one role shares; $($strange -join ', ') belong in pack.json."; continue }
        $useMap = Get-Prop $roleCfg 'chief.use'
        $strangeUse = @(if ($useMap) { $useMap.PSObject.Properties.Name | Where-Object { $_ -cnotin $actionNames } })
        if ($strangeUse.Count) { Add-Result 'kit' $roleArea 'fail' "chief.use names actions that chief.actions does not have: $($strangeUse -join ', ')."; continue }
        if ($null -ne (Get-Prop $roleCfg 'chief.rules')) { Add-Result 'kit' $roleArea 'warn' "Sets chief.rules, which replace the pack's rules for whoever has this role. Rules belong in pack.json; a role says which actions it uses (chief.use)." }
        Add-Result 'kit' $roleArea $(if ((Get-Prop $roleCfg 'role.title')) { 'ok' } else { 'warn' }) $(if ((Get-Prop $roleCfg 'role.title')) { [string]$roleCfg.role.title } else { 'No role.title: /setup shows the file name instead.' })
        if ($null -ne (Get-Prop $roleCfg 'board.views')) { Test-Views $roleArea (Get-Prop $roleCfg 'board.views') }
    }

    # Hooks: every entry names a known event and a script of the kit that PowerShell can parse.
    $hookSpec = $defaults.kit.hooks
    if ($hookSpec) {
        $knownEvents = 'beforeShellExecution', 'beforeMCPExecution', 'preToolUse', 'postToolUse', 'beforeReadFile', 'afterFileEdit', 'beforeSubmitPrompt', 'sessionStart', 'stop'
        foreach ($entry in @($hookSpec.entries)) {
            $file = Join-Path $SkillsRoot "$($hookSpec.source)\$($entry.script)"
            if ($entry.event -notin $knownEvents) { Add-Result 'kit' "hook $($entry.event)" 'fail' "Unknown Cursor event '$($entry.event)'."; continue }
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Add-Result 'kit' "hook $($entry.event)" 'fail' "Missing: $file"; continue }
            $parseErrors = $null
            [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parseErrors) | Out-Null
            if ($parseErrors.Count) { Add-Result 'kit' "hook $($entry.event)" 'fail' "$($entry.script) does not parse: $($parseErrors[0].Message)"; continue }
            Add-Result 'kit' "hook $($entry.event)" 'ok' $entry.script
        }
        foreach ($entry in @($hookSpec.claude | Where-Object { $_ })) {
            $file = Join-Path $SkillsRoot "$($hookSpec.source)\$($entry.script)"
            $label = "claude hook $($entry.matcher)"
            if ($entry.event -ne 'PreToolUse' -or -not $entry.matcher) { Add-Result 'kit' $label 'fail' 'A Claude Code entry needs event PreToolUse and a matcher.'; continue }
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Add-Result 'kit' $label 'fail' "Missing: $file"; continue }
            Add-Result 'kit' $label 'ok' $entry.script
        }
    }

    # The guard's answer to one shell command, in the shape of the given agent: ask, allow or deny.
    function Get-GuardAnswer([string]$Script, [string]$Agent, [string]$Command) {
        if ($Agent -eq 'claude') {
            $sample = @{ hook_event_name = 'PreToolUse'; tool_name = 'Bash'; tool_input = @{ command = $Command } } | ConvertTo-Json -Compress -Depth 4
            $text = "$($sample | & pwsh -NoProfile -File $Script -AgentHost claude 2>$null)".Trim()
            if (-not $text) { return 'allow' }
            return [string](ConvertFrom-KitJson $text).hookSpecificOutput.permissionDecision
        }
        $sample = @{ hook_event_name = 'beforeShellExecution'; command = $Command } | ConvertTo-Json -Compress
        [string](ConvertFrom-KitJson ("$($sample | & pwsh -NoProfile -File $Script 2>$null)")).permission
    }

    # The person's edits to an installed copy (Install.ps1's records). The checks above already ran on
    # the edited files, so an edited script that broke a block or uses a missing text has failed there.
    $editedFiles = @{}
    $ch = Invoke-Kit (Join-Path $SkillsRoot $defaults.kit.scripts.setup) @('changes')
    $changes = if ($ch.code -eq 0) { ConvertFrom-KitJson $ch.out }
    if ($null -eq $changes) { Add-Result 'kit' 'changes' 'fail' $(if ($ch.err) { $ch.err } else { 'Could not read the install records.' }) }
    else {
        foreach ($s in @($changes.skills | Where-Object { $_.tracked })) {
            foreach ($rel in @($s.edited)) { $editedFiles["$($s.skill)/$rel"] = $true }
            if (@($s.edited).Count) { Add-Result 'changes' "edited $($s.skill)" 'ok' "Edited by you, kept on update: $(@($s.edited) -join ', ')" }
            foreach ($p in @($s.pending)) { Add-Result 'changes' "merge $($s.skill)" 'warn' "$($p.file): you edited it and the kit changed it too. The new version is $($p.new); /setup (step Update) merges them." }
            foreach ($d in @($s.deleted)) { Add-Result 'changes' "deleted $($s.skill)" 'ok' "$d was deleted by you; updates do not create it again." }
        }
    }

    $allow = @($defaults.kit.lint.allow)
    $patterns = @($defaults.kit.lint.patterns)
    $findings = 0
    # Only the kit's own skills: an installed kit shares its folder with the person's other skills.
    $kitDirs = @($defaults.kit.skills | ForEach-Object { Join-Path $SkillsRoot $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    foreach ($file in Get-ChildItem -LiteralPath $kitDirs -Recurse -File -Include '*.md', '*.ps1', '*.json', '*.txt') {
        $rel = [IO.Path]::GetRelativePath($SkillsRoot, $file.FullName) -replace '\\', '/'
        if (@($allow | Where-Object { $rel -like $_ }).Count) { continue }
        if ($file.Name -match '\.kit-new(\.[^.]*)?$' -or $file.Name -in '.kit-installed.json', '.kit-source.json') { continue }
        # In a person's own edits a configuration value is their choice: a warning, not a failure.
        $lintStatus = if ($editedFiles[$rel]) { 'warn' } else { 'fail' }
        $n = 0
        foreach ($line in Get-Content -Encoding utf8 -LiteralPath $file.FullName) {
            $n++
            # The line that finds the scripts carries the installed path, which Install.ps1 writes in.
            if ($line.Contains(' scripts) -join "`n" | ConvertFrom-Json')) { continue }
            foreach ($pat in $patterns) {
                if ($line -cmatch $pat.regex) {
                    $findings++
                    Add-Result 'lint' "$rel`:$n" $lintStatus "$($pat.name) '$($Matches[0])': move the value to the configuration (setup/defaults) and refer to its key."
                }
            }
        }
    }
    if (-not $findings) { Add-Result 'lint' 'kit files' 'ok' "No configuration values outside setup/defaults ($($patterns.Count) patterns)." }
}

# --- Offline: the person's configuration ------------------------------------------------------

if (-not $Static -and -not $Fake -and $null -ne $defaults) {
    $setup = Join-Path $SkillsRoot $defaults.kit.scripts.setup
    $r = Invoke-Kit $setup @('show', '-Effective')
    $cfg = if ($r.code -eq 0) { ConvertFrom-KitJson $r.out }
    if ($null -eq $cfg) {
        Add-Result 'config' 'configuration' 'fail' $(if ($r.err) { $r.err } else { 'Could not read the configuration. Run /setup.' })
    }
    else {
        $here = [IO.Path]::GetFullPath($defaultsFile)
        $there = [IO.Path]::GetFullPath([string]$cfg.kit.defaultsFile)
        if ($here -ne $there) { Add-Result 'config' 'kit.defaultsFile' 'warn' "The configuration reads the kit at $there; this test runs from $SkillsRoot. Run init from the copy in use." }
        else { Add-Result 'config' 'kit.defaultsFile' 'ok' $there }

        $scriptPaths = @{}
        foreach ($s in $defaults.kit.scripts.PSObject.Properties) {
            $configured = [string](Get-Prop $cfg "scripts.$($s.Name)")
            $scriptPaths[$s.Name] = $configured
            if (-not $configured -or -not (Test-Path -LiteralPath $configured -PathType Leaf)) { Add-Result 'config' "scripts.$($s.Name)" 'fail' "Not recorded or missing ('$configured'). Run /setup (init)." }
        }
        $capOn = @{}
        foreach ($cap in @($cfg.capabilities.PSObject.Properties | ForEach-Object { $_.Name })) {
            $c = $cfg.capabilities.$cap
            $capOn[$cap] = [bool]($c -and $c.provider -and $c.enabled -ne $false)
            if (-not $capOn[$cap]) { Add-Result 'config' "capability $cap" 'skip' $(if ($c.enabled -eq $false) { 'Turned off.' } else { 'No provider chosen.' }); continue }
            $configured = [string](Get-Prop $cfg "scripts.$cap")
            $scriptPaths[$cap] = $configured
            if ($null -eq (Get-Prop $cfg "providerInfo.$cap")) { Add-Result 'config' "capability $cap" 'fail' "The configuration does not describe its provider ($($c.provider)): no providerInfo.$cap. Run /setup (init)." }
            elseif ($configured -and -not (Test-Path -LiteralPath $configured -PathType Leaf)) { Add-Result 'config' "capability $cap" 'fail' "Its script $configured is missing. Run /setup (init)." }
            else { Add-Result 'config' "capability $cap" 'ok' "$($c.provider)$(if (-not $configured) { ' (no script)' })" }
        }

        foreach ($k in 'user.name', 'user.email', 'user.boardAccountId') {
            if (Get-Prop $cfg $k) { Add-Result 'config' $k 'ok' $(if ($k -ne 'user.boardAccountId') { [string](Get-Prop $cfg $k) }) }
            else { Add-Result 'config' $k 'fail' 'Empty. /setup step 3 records it from the board token.' }
        }
        foreach ($k in 'user.role', 'user.language') {
            if (Get-Prop $cfg $k) { Add-Result 'config' $k 'ok' (@(Get-Prop $cfg $k) -join ', ') } else { Add-Result 'config' $k 'warn' 'Empty. /setup asks for it.' }
        }
        $packRoles = @(ConvertFrom-KitJson (Invoke-Kit $setup @('roles')).out | ForEach-Object { $_ } | Where-Object { $_ })
        $myRoles = @(@(Get-Prop $cfg 'user.role') | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $strangeRoles = @($myRoles | Where-Object { $_ -notin @($packRoles | ForEach-Object { $_.name }) })
        if ($packRoles.Count -and $strangeRoles.Count) {
            Add-Result 'config' 'role' 'fail' "user.role names $(($strangeRoles | ForEach-Object { "'$_'" }) -join ', '), which the pack does not define ($(@($packRoles | ForEach-Object { $_.name }) -join ', ')), so no views come from it. /setup step 6."
        }
        elseif ($packRoles.Count -and $myRoles.Count) {
            $ownFile = ConvertFrom-KitJson (Invoke-Kit $setup @('show')).out
            if ($null -ne (Get-Prop $ownFile 'board.views')) { Add-Result 'config' 'role' 'warn' "Your own board.views replace the views of your roles ($($myRoles -join ', ')), so the team's updates to them do not reach you. /setup step 6 offers to drop yours." }
            else { Add-Result 'config' 'role' 'ok' "The views come from the pack's role$(if ($myRoles.Count -gt 1) { 's' }) $($myRoles -join ', ')." }
        }
        Test-Views 'config' (Get-Prop $cfg 'board.views')

        $e = Invoke-Kit $setup @('env')
        foreach ($v in @(ConvertFrom-KitJson $e.out) | ForEach-Object { $_ }) {
            if ($v.set) { Add-Result 'credentials' $v.variable 'ok' "set ($($v.scope))" }
            elseif ($v.needed) { Add-Result 'credentials' $v.variable 'fail' "Not set ($($v.provider)). /setup explains how." }
            else { Add-Result 'credentials' $v.variable 'skip' "Not needed: $($v.when) is off." }
        }

        $rp = Invoke-Kit $setup @('repos', '-NoSearch')
        foreach ($repo in @((ConvertFrom-KitJson $rp.out).repos)) {
            $uses = if ($repo.uses) { $repo.uses } else { 'what reads it' }
            if (-not $repo.configured) { Add-Result 'repos' $repo.key 'warn' "Not set: $uses will not work. /setup step 5." }
            elseif (-not $repo.configuredOk) { Add-Result 'repos' $repo.key 'fail' "$($repo.configured) is not a clone of $($repo.repo)." }
            else { Add-Result 'repos' $repo.key 'ok' $repo.configured }
        }

        foreach ($k in 'paths.myPeople', 'paths.myNotes') {
            $f = Expand-KitPath ([string](Get-Prop $cfg $k))
            if ($f -and (Test-Path -LiteralPath $f)) { Add-Result 'files' $k 'ok' $f } else { Add-Result 'files' $k 'skip' 'None yet (optional).' }
        }

        if ($capOn.chat -and $scriptPaths.chat) {
            $pp = Invoke-Kit $scriptPaths.chat @('people', '-Json')
            $people = (ConvertFrom-KitJson $pp.out).people
            $other = @($people | Where-Object { -not $_.you }) | Select-Object -First 1
            if ($pp.code -ne 0) { Add-Result 'scripts' 'chat people' 'fail' $pp.err }
            elseif (-not $other) { Add-Result 'scripts' 'chat people' 'warn' 'No people in the people files yet.' }
            else {
                Add-Result 'scripts' 'chat people' 'ok' "$(@($people).Count) people"
                $l = Invoke-Kit $scriptPaths.chat @('-To', $other.alias, '-Message', 'kit test', '-Json')
                Add-Result 'scripts' 'chat link' $(if ($l.code -eq 0) { 'ok' } else { 'fail' }) $(if ($l.code -ne 0) { $l.err } else { 'built, not opened' })
            }
        }
        if ($capOn.board -and $scriptPaths.board) {
            $n = Invoke-Kit $scriptPaths.board @('notes')
            Add-Result 'scripts' 'board notes' $(if ($n.code -eq 0) { 'ok' } else { 'fail' }) $n.err
        }
        if ($capOn.specs -and $scriptPaths.specs -and (Get-Prop $cfg 'paths.specsRepo')) {
            $a = Invoke-Kit $scriptPaths.specs @('-Check', '-Json')
            $chk = if ($a.code -eq 0) { ConvertFrom-KitJson $a.out }
            if ($null -eq $chk) { Add-Result 'scripts' 'specifications' 'fail' $(if ($a.err) { $a.err } else { 'Unexpected answer from -Check.' }) }
            else {
                Add-Result 'scripts' 'specifications' 'ok' "$($chk.clone) (origin $($chk.origin))"
                $cov = $chk.coverage
                if ($cov -and ($cov.unrecognized -or $cov.misplaced)) {
                    $gaps = @(
                        if ($cov.unrecognized) { "$($cov.unrecognized) story files have a name the code pattern does not recognize (e.g. $(@($cov.examples.unrecognized | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))" }
                        if ($cov.misplaced) { "$($cov.misplaced) files with a story code are where the folder or file template would not look (e.g. $(@($cov.examples.misplaced | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))" }
                    )
                    Add-Result 'scripts' 'specs coverage' 'warn' "$($gaps -join '; '). The pack's provider values no longer fit the repository: lookups for those stories fall back to wider searches and say so. Fix the values in the pack."
                }
                elseif ($cov) { Add-Result 'scripts' 'specs coverage' 'ok' "$($cov.recognized) files with a story code, all where the templates look" }
            }
        }

        foreach ($t in @($defaults.kit.templates.PSObject.Properties)) {
            $mine = Expand-KitPath ([string](Get-Prop $cfg "paths.templates.$($t.Name)"))
            if (-not $mine -or -not (Test-Path -LiteralPath $mine -PathType Leaf)) { Add-Result 'files' "paths.templates.$($t.Name)" 'skip' 'No own template (optional); the team''s is used.'; continue }
            $read = Read-Snippets $mine
            $team = $teamTexts[$t.Name]
            $strange = @(if ($team) { $read.snippets.Keys | Where-Object { -not $team.Contains($_) } })
            if ($strange.Count) { Add-Result 'files' "paths.templates.$($t.Name)" 'warn' "$mine has texts the team's template does not, so they are ignored: @$($strange -join ', @'). Check the names." }
            elseif (-not $read.snippets.Count) { Add-Result 'files' "paths.templates.$($t.Name)" 'warn' "$mine has no texts (each starts with a line <!-- @name -->)." }
            else { Add-Result 'files' "paths.templates.$($t.Name)" 'ok' "$mine ($($read.snippets.Count) own texts)" }
        }
        foreach ($g in @($defaults.kit.guides.PSObject.Properties)) {
            $mine = Expand-KitPath ([string](Get-Prop $cfg "paths.templates.$($g.Name)"))
            if (-not $mine -or -not (Test-Path -LiteralPath $mine -PathType Leaf)) { Add-Result 'files' "paths.templates.$($g.Name)" 'skip' 'No own guide (optional); the team''s is used.'; continue }
            $read = Read-Snippets $mine
            $team = $teamGuides[$g.Name]
            $strange = @(if ($team) { $read.snippets.Keys | Where-Object { -not $team.Contains($_) } })
            if ($strange.Count) { Add-Result 'files' "paths.templates.$($g.Name)" 'warn' "$mine has sections the team's guide does not: @$($strange -join ', @'). The agent still reads them; check the names if you meant to replace a team section." }
            elseif (-not $read.snippets.Count) { Add-Result 'files' "paths.templates.$($g.Name)" 'warn' "$mine has no sections (each starts with a line <!-- @name -->)." }
            else { Add-Result 'files' "paths.templates.$($g.Name)" 'ok' "$mine ($($read.snippets.Count) own sections)" }
        }
        if ($scriptPaths.brief) {
            $bc = Invoke-Kit $scriptPaths.brief @('check')
            $got = if ($bc.code -eq 0) { ConvertFrom-KitJson $bc.out }
            if ($null -eq $got) { Add-Result 'scripts' 'brief' 'fail' $bc.err }
            elseif ($got.bitbucketToken -eq 'missing') { Add-Result 'scripts' 'brief' 'warn' 'Pull-request sections are on but the Bitbucket token is not set; they will say so. /setup step 7.' }
            else { Add-Result 'scripts' 'brief' 'ok' "sections: $(@($got.sections) -join ', ')" }
        }
        if ($scriptPaths.chief) {
            $cc = Invoke-Kit $scriptPaths.chief @('check')
            $got = if ($cc.code -eq 0) { ConvertFrom-KitJson $cc.out }
            if ($null -eq $got) { Add-Result 'scripts' 'chief-of-staff' 'fail' $cc.err }
            else { Add-Result 'scripts' 'chief-of-staff' 'ok' "$(@($got.rules).Count) rules" }
        }

        # Hooks: the kit's entries are in the hooks file, their scripts exist, and the guard answers.
        $hooksCfg = if (Test-Path -LiteralPath $HooksFile -PathType Leaf) { ConvertFrom-KitJson (Get-Content -Raw -Encoding utf8 -LiteralPath $HooksFile) }
        $marker = "\hooks\$($defaults.kit.name)\"
        if ($AgentHost -eq 'claude' -and $hookSpec -and @($hookSpec.claude).Count) {
            if ($null -eq $hooksCfg) { Add-Result 'hooks' 'settings file' 'warn' "No readable $HooksFile, so writes are not confirmed by Claude Code. Run the kit's Install.ps1 -AgentHost claude." }
            else {
                foreach ($entry in @($hookSpec.claude)) {
                    $found = @(@(Get-Prop $hooksCfg 'hooks.PreToolUse') | Where-Object { $_.matcher -eq $entry.matcher } | ForEach-Object { $_.hooks } |
                            Where-Object { "$($_.command) $(@($_.args) -join ' ')".IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                    if (-not $found.Count) { Add-Result 'hooks' "PreToolUse $($entry.matcher)" 'warn' "Not in $HooksFile. Run the kit's Install.ps1 -AgentHost claude."; continue }
                    $scriptFile = @($found[0].args) | Where-Object { $_ -like "*$($entry.script)" } | Select-Object -First 1
                    if (-not $scriptFile -or -not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) { Add-Result 'hooks' "PreToolUse $($entry.matcher)" 'fail' "The entry runs '$scriptFile', which does not exist. Run the kit's Install.ps1 -AgentHost claude."; continue }
                    if ($found[0].onFailure -ne 'block') { Add-Result 'hooks' "PreToolUse $($entry.matcher)" 'warn' 'The entry has no onFailure block: if the guard fails, the action goes through. Run the kit''s Install.ps1 -AgentHost claude.'; continue }
                    Add-Result 'hooks' "PreToolUse $($entry.matcher)" 'ok' $scriptFile
                    if ($entry.matcher -like '*Bash*') {
                        foreach ($probe in @(@{ want = 'ask'; command = 'pwsh -NoProfile -File $kit.board transition -Key ABC-1 -To Done' }, @{ want = 'allow'; command = 'git status' })) {
                            $got = Get-GuardAnswer $scriptFile 'claude' $probe.command
                            Add-Result 'hooks' "guard answers $($probe.want)" $(if ($got -eq $probe.want) { 'ok' } else { 'fail' }) "$($probe.command) -> $got"
                        }
                    }
                }
            }
        }
        elseif ($AgentHost -eq 'cursor' -and $hookSpec -and @($hookSpec.entries).Count) {
            if ($null -eq $hooksCfg) { Add-Result 'hooks' 'hooks file' 'warn' "No readable $HooksFile, so writes are not confirmed by Cursor. Run the kit's Install.ps1." }
            else {
                foreach ($entry in @($hookSpec.entries)) {
                    $found = @(@(Get-Prop $hooksCfg "hooks.$($entry.event)") | Where-Object { "$($_.command)".IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and "$($_.command)" -like "*$($entry.script)*" })
                    if (-not $found.Count) { Add-Result 'hooks' $entry.event 'warn' "Not in $HooksFile, so this kind of Jira write is not confirmed by Cursor. Run the kit's Install.ps1."; continue }
                    $scriptFile = [regex]::Match([string]$found[0].command, '-File\s+"([^"]+)"').Groups[1].Value
                    if (-not $scriptFile -or -not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) { Add-Result 'hooks' $entry.event 'fail' "The entry runs '$scriptFile', which does not exist; Cursor blocks every action this hook checks. Run the kit's Install.ps1."; continue }
                    if (-not $found[0].failClosed) { Add-Result 'hooks' $entry.event 'warn' 'The entry has no failClosed: if the guard fails, the action goes through. Run the kit''s Install.ps1.'; continue }
                    Add-Result 'hooks' $entry.event 'ok' $scriptFile
                    if ($entry.event -eq 'beforeShellExecution') {
                        foreach ($probe in @(
                                @{ want = 'ask'; command = 'pwsh -NoProfile -File $kit.board transition -Key ABC-1 -To Done' },
                                @{ want = 'allow'; command = 'git status' })) {
                            $got = Get-GuardAnswer $scriptFile 'cursor' $probe.command
                            if ($got -eq $probe.want) { Add-Result 'hooks' "guard answers $($probe.want)" 'ok' $probe.command }
                            else { Add-Result 'hooks' "guard answers $($probe.want)" 'fail' "For '$($probe.command)' it answered '$got'." }
                        }
                    }
                }
            }
        }

        # --- Online: Jira and Jenkins ---------------------------------------------------------
        if (-not $Offline) {
            if ($capOn.board -and $scriptPaths.board) {
                $m = Invoke-Kit $scriptPaths.board @('me', '-Json')
                if ($m.code -ne 0) { Add-Result 'board' 'me' 'fail' $m.err }
                else {
                    $me = ConvertFrom-KitJson $m.out
                    $id = [string](Get-Prop $cfg 'user.boardAccountId')
                    if ($id -and $me.id -ne $id) { Add-Result 'board' 'me' 'warn' "The token is $($me.name)'s, but user.boardAccountId names another account; views show that account's issues." }
                    else { Add-Result 'board' 'me' 'ok' $me.name }
                    foreach ($v in @(Get-Prop $cfg 'board.views')) {
                        if (-not $v.id) { continue }
                        $vr = Invoke-Kit $scriptPaths.board @('view', '-Id', $v.id, '-Json')
                        $got = if ($vr.code -eq 0) { ConvertFrom-KitJson $vr.out }
                        if ($null -eq $got) { Add-Result 'board' "view $($v.id)" 'fail' $vr.err }
                        else { Add-Result 'board' "view $($v.id)" 'ok' "$(@($got.issues).Count) issue(s)$(if ($got.more) { ', more not shown' })" }
                    }
                }
            }
            if ($capOn.ci -and $scriptPaths.ci) {
                $pg = Invoke-Kit $scriptPaths.ci @('ping')
                if ($pg.code -eq 3) { Add-Result 'ci' 'ping' 'warn' 'Unreachable: probably off the VPN. CI was not tested.' }
                elseif ($pg.code -ne 0) { Add-Result 'ci' 'ping' 'fail' $pg.err }
                else { Add-Result 'ci' 'ping' 'ok' }
            }
            if ($capOn.cd -and $scriptPaths.cd) {
                $vs = Invoke-Kit $scriptPaths.cd @('environments', '-NoCommit', '-Json')
                $got = if ($vs.code -eq 0) { ConvertFrom-KitJson $vs.out }
                if ($vs.code -eq 3) { Add-Result 'cd' 'versions' 'warn' 'Unreachable: probably off the VPN. Environments were not tested.' }
                elseif ($null -eq $got) { Add-Result 'cd' 'versions' 'fail' $vs.err }
                else { Add-Result 'cd' 'versions' 'ok' (($got | ForEach-Object { "$($_.name) $($_.version)" }) -join ', ') }
            }
        }
    }
}

# --- Fake: the engine end to end against the fake provider ------------------------------------

if ($Fake -and $null -ne $defaults) {
    $sandbox = Join-Path ([IO.Path]::GetTempPath()) "kit-fake-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $savedConfigVar = [Environment]::GetEnvironmentVariable($kitConfigVar, 'Process')
    $savedHomeVar = [Environment]::GetEnvironmentVariable(($kitConfigVar -replace '_CONFIG$', '_HOME'), 'Process')
    function Invoke-SandboxGit([string]$Dir, [string[]]$GitArgs) {
        $ErrorActionPreference = 'Continue'
        $gitOut = & git -C $Dir @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $gitOut" }
    }
    function Add-FakeCommit([string]$Dir, [string]$Text, [string]$Tag) {
        Add-Content -LiteralPath (Join-Path $Dir 'changes.txt') -Value $Text
        Invoke-SandboxGit $Dir @('add', '-A')
        Invoke-SandboxGit $Dir @('commit', '-q', '-m', $Text)
        if ($Tag) { Invoke-SandboxGit $Dir @('tag', $Tag) }
    }
    function Get-Row($Brief, [string]$TicketKey) { @($Brief.views | ForEach-Object { $_.issues }) | Where-Object { $_.key -eq $TicketKey } | Select-Object -First 1 }
    try {
        New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
        $origin = Join-Path $sandbox 'origin.git'
        $work = Join-Path $sandbox 'work'
        $clone = Join-Path $sandbox 'clone'
        $packDir = Join-Path $sandbox 'pack'
        $state = Join-Path $sandbox 'state'
        Invoke-SandboxGit $sandbox @('init', '-q', '--bare', $origin)
        Invoke-SandboxGit $sandbox @('init', '-q', '-b', 'main', $work)
        Invoke-SandboxGit $work @('config', 'user.name', 'Dana Dev')
        Invoke-SandboxGit $work @('config', 'user.email', 'dana.dev@example.invalid')
        Add-FakeCommit $work 'Initial commit' 'v1.0.0'
        Add-FakeCommit $work 'FAKE-1 single sign-on' 'v1.1.0'
        Add-FakeCommit $work 'FAKE-2 save crash' $null
        Add-FakeCommit $work 'FAKE-5 export fix' 'v1.2.0'
        Invoke-SandboxGit $work @('checkout', '-q', '-b', 'feature/FAKE-3-monthly-report')
        Add-FakeCommit $work 'FAKE-3 monthly report' $null
        Invoke-SandboxGit $work @('remote', 'add', 'origin', $origin)
        Invoke-SandboxGit $work @('push', '-q', 'origin', 'main', 'feature/FAKE-3-monthly-report', '--tags')
        Invoke-SandboxGit $sandbox @('clone', '-q', $origin, $clone)

        # A specification repository laid out unlike any real one: the provider must take it all from configuration.
        $specsOrigin = Join-Path $sandbox 'specs.git'
        $specsWork = Join-Path $sandbox 'specs-work'
        $specsClone = Join-Path $sandbox 'specs'
        Invoke-SandboxGit $sandbox @('init', '-q', '--bare', $specsOrigin)
        Invoke-SandboxGit $sandbox @('init', '-q', '-b', 'main', $specsWork)
        Invoke-SandboxGit $specsWork @('config', 'user.name', 'Dana Dev')
        Invoke-SandboxGit $specsWork @('config', 'user.email', 'dana.dev@example.invalid')
        New-Item -ItemType Directory -Force -Path (Join-Path $specsWork 'docs\A1') | Out-Null
        foreach ($specFile in 'A1_ST_007_login.md', 'A1_ST_007_login.ac.md', 'A1_ST_007_login.feature', 'A1_ST_007_notes.txt', 'A1_ST_070_other.md') {
            Set-Content -LiteralPath (Join-Path $specsWork "docs\A1\$specFile") -Value 'spec'
        }
        # Two drifts the configuration does not cover: a story kept in another area's folder, and a story whose code it cannot read.
        New-Item -ItemType Directory -Force -Path (Join-Path $specsWork 'docs\B2') | Out-Null
        foreach ($specFile in 'A1_ST_009_moved.md', 'A1_ST_009_moved.ac.md') { Set-Content -LiteralPath (Join-Path $specsWork "docs\B2\$specFile") -Value 'spec' }
        Set-Content -LiteralPath (Join-Path $specsWork 'docs\A1\A1_XX_010_new.ac.md') -Value 'spec'
        Invoke-SandboxGit $specsWork @('add', '-A')
        Invoke-SandboxGit $specsWork @('commit', '-q', '-m', 'Specs')
        Invoke-SandboxGit $specsWork @('remote', 'add', 'origin', $specsOrigin)
        Invoke-SandboxGit $specsWork @('push', '-q', 'origin', 'main')
        Invoke-SandboxGit $sandbox @('clone', '-q', '-b', 'main', $specsOrigin, $specsClone)

        New-Item -ItemType Directory -Force -Path $packDir, $state | Out-Null
        $packJson = [ordered]@{
            pack = @{ name = 'fake'; description = 'The fake project, for Test-Kit.ps1 -Fake.' }
            kit = @{ name = $kitName }
            capabilities = [ordered]@{ board = @{ provider = 'fake' }; repo = @{ provider = 'fake' }; ci = @{ provider = 'fake' }; cd = @{ provider = 'fake' }; chat = @{ provider = 'fake' }; specs = @{ provider = 'git-files' } }
            board = @{ testIssueType = 'Test' }
            brief = @{ followLinks = @('Relates') }
            delivery = @{ qaEnvironment = 'qa' }
            # An action the pack defines, with its own texts and how, proposed for the tickets no instance has (qa NONE).
            chief = [ordered]@{
                actions = @{ ping = [ordered]@{ needs = @('chat'); recipient = 'developer'; label = @{ en = 'ping them'; es = 'avisarle' }; text = @{ en = 'ask {{who}} how it is going'; es = 'preguntale a {{who}} cómo viene' }; how = 'Write to the developer through the chat skill.' } }
                rules = @(
                    [ordered]@{ id = 'ping-none'; qa = 'NONE'; action = 'ping'; reason = @{ en = 'No instance has it yet.'; es = 'Ninguna instancia lo tiene todavía.' } },
                    [ordered]@{ id = 'test-ready'; qa = 'IN'; action = 'test' },
                    [ordered]@{ id = 'test-waiting'; qa = 'NOT_IN'; action = 'teams' },
                    [ordered]@{ id = 'no-tests'; tests = 'none'; action = 'writeTests' })
            }
            providers = [ordered]@{
                fake        = @{ qualityName = 'Quality' }
                'git-files' = [ordered]@{
                    branch = 'main'; root = 'docs'; codePattern = '(?<area>[A-Za-z]\d+)-(?<type>story|task)-(?<num>\d+)'; codeHelp = 'an <area>-story-<n> code'
                    fileCodePattern = '^(?<area>[A-Z]\d+)_(?<type>ST|TK)_(?<num>\d+)_'
                    upper = @('area'); pad = @{ num = 3 }; aliases = @{ type = @{ story = 'ST'; task = 'TK' } }
                    folderTemplate = '{root}/{area}/'; fileTemplate = '{area}_{type}_{num}_'
                }
            }
        }
        Set-Content -LiteralPath (Join-Path $packDir 'pack.json') -Value ($packJson | ConvertTo-Json -Depth 6) -Encoding utf8
        # The views and pull requests come only from the role, so every check below that reads them also checks the role layer.
        New-Item -ItemType Directory -Force -Path (Join-Path $packDir 'roles') | Out-Null
        $roleJson = [ordered]@{
            role = @{ title = 'Tester'; description = 'Tests the tickets assigned to them.' }
            user = @{ pullRequests = $true }
            chief = @{ use = [ordered]@{ test = $true; teams = $true; writeTests = $true; ping = $true } }
            board = @{ views = @([ordered]@{ id = 'mine'; title = 'My tickets'; query = 'assignee = {me}'; fields = @('summary', 'status', 'updated'); max = 20; qaCheckStatuses = @('*'); linkedTests = $true }) }
        }
        Set-Content -LiteralPath (Join-Path $packDir 'roles\qa.json') -Value ($roleJson | ConvertTo-Json -Depth 6) -Encoding utf8
        # A second role that clashes with the first on a view id and on a single value: the first role must win both.
        $writerJson = [ordered]@{
            role = @{ title = 'Writer'; description = 'Writes test cases.' }
            user = @{ pullRequests = $false }
            chief = @{ use = @{ finishTests = $true } }
            board = @{ views = @(
                    [ordered]@{ id = 'mine'; title = 'Written by me'; query = 'reporter = {me}'; fields = @('summary', 'status'); max = 5; qaCheckStatuses = @() },
                    [ordered]@{ id = 'drafts'; title = 'My drafts'; query = 'reporter = {me} AND status = Draft'; fields = @('summary', 'status'); max = 1; qaCheckStatuses = @() }) }
        }
        Set-Content -LiteralPath (Join-Path $packDir 'roles\writer.json') -Value ($writerJson | ConvertTo-Json -Depth 6) -Encoding utf8
        $userConfig = [ordered]@{
            version = 2
            user = [ordered]@{ name = 'Fake Person'; email = 'fake.person@example.invalid'; boardAccountId = 'fake-1'; language = 'en' }
            paths = [ordered]@{
                stateDir = $state; codeRepo = $clone; specsRepo = $specsClone; proposals = (Join-Path $sandbox 'proposals')
                myPeople = (Join-Path $sandbox 'my-people.md'); myNotes = (Join-Path $sandbox 'my-notes.md')
                templates = [ordered]@{ brief = (Join-Path $sandbox 'none.md'); nextSteps = (Join-Path $sandbox 'none.md'); boardComments = (Join-Path $sandbox 'none.md'); chatMessages = (Join-Path $sandbox 'none.md') }
            }
        }
        $fakeConfig = Join-Path $sandbox 'config.json'
        Set-Content -LiteralPath $fakeConfig -Value ($userConfig | ConvertTo-Json -Depth 8) -Encoding utf8
        [Environment]::SetEnvironmentVariable($kitConfigVar, $fakeConfig, 'Process')

        $setupScript = Join-Path $SkillsRoot $defaults.kit.scripts.setup
        $badRole = Invoke-Kit $setupScript @('init', '-Pack', $packDir, '-Role', 'nobody')
        Add-Result 'fake' 'role unknown' $(if ($badRole.code -eq 1 -and $badRole.err -match 'qa') { 'ok' } else { 'fail' }) "init -Role nobody: exit $($badRole.code), $("$($badRole.err)".Trim())"
        $in = Invoke-Kit $setupScript @('init', '-Pack', $packDir, '-Role', 'qa,writer')
        $inData = if ($in.code -eq 0) { ConvertFrom-KitJson $in.out }
        $off = @($inData.capabilities | Where-Object { $_.capability -ne 'specs' -and -not ($_.on -and $_.script) })
        if ($null -eq $inData) { throw "init failed: $($in.err)" }
        Add-Result 'fake' 'init' $(if ($off.Count) { 'fail' } else { 'ok' }) $(if ($off.Count) { "Not on with a script: $(@($off | ForEach-Object { $_.capability }) -join ', ')" } else { 'board, repo, ci, cd and chat on the fake provider' })
        $views = @(ConvertFrom-KitJson (Invoke-Kit $setupScript @('get', '-Key', 'board.views')).out | ForEach-Object { $_ })
        $pullRequests = ConvertFrom-KitJson (Invoke-Kit $setupScript @('get', '-Key', 'user.pullRequests')).out
        $roleOk = $inData.role -eq 'qa,writer' -and ($views.id -join ',') -eq 'mine,drafts' -and $views[0].title -eq 'My tickets' -and $pullRequests -eq $true
        Add-Result 'fake' 'roles' $(if ($roleOk) { 'ok' } else { 'fail' }) "init -Role qa,writer recorded '$($inData.role)'; views $(@($views | ForEach-Object { "$($_.id) ($($_.title))" }) -join ', '); pull requests $pullRequests. Expected mine (My tickets, the first role's), drafts (the second's), and true (the first role's)"
        $kitScripts = (ConvertFrom-KitJson (Get-Content -Raw -Encoding utf8 -LiteralPath $fakeConfig)).scripts

        $b = Invoke-Kit $kitScripts.brief @('-Json')
        $brief = if ($b.code -eq 0) { ConvertFrom-KitJson $b.out }
        if ($null -eq $brief) { Add-Result 'fake' 'brief' 'fail' "exit $($b.code): $($b.err)" }
        else {
            $want = [ordered]@{ 'FAKE-1' = @('IN', $null); 'FAKE-2' = @('NOT_IN', '1.2.0'); 'FAKE-3' = @('NONE', $null); 'FAKE-4' = @('NOT_IN', '1.2.0'); 'FAKE-6' = @('NONE', $null) }
            foreach ($k in $want.Keys) {
                $row = Get-Row $brief $k
                $got = if ($row -and $row.qa) { [string]$row.qa.verdict } else { '(no check)' }
                $first = if ($row -and $row.qa) { [string]$row.qa.firstVersion } else { '' }
                $okVerdict = $got -eq $want[$k][0] -and (-not $want[$k][1] -or $first -eq $want[$k][1])
                Add-Result 'fake' "brief qa $k" $(if ($okVerdict) { 'ok' } else { 'fail' }) "verdict $got$(if ($first) { ", first version $first" })$(if ($row.qa.via) { ", through $(@($row.qa.via) -join ', ')" }); expected $($want[$k][0])$(if ($want[$k][1]) { ", first version $($want[$k][1])" })"
            }
            $tested = Get-Row $brief 'FAKE-1'
            Add-Result 'fake' 'brief linked tests' $(if ($tested.tests.total -eq 1) { 'ok' } else { 'fail' }) "FAKE-1 has $($tested.tests.total) linked test(s); expected 1"
            $openPr = @($brief.pullRequests) | Select-Object -First 1
            Add-Result 'fake' 'brief open pull request' $(if ($openPr -and $openPr.verdict -eq 'failed' -and $openPr.sonar -eq 'fail' -and @($openPr.needsWork).Count -eq 1) { 'ok' } else { 'fail' }) "verdict $($openPr.verdict), checks $($openPr.jenkins), quality $($openPr.sonar), needs work from $(@($openPr.needsWork) -join ', ')"
            $mergedPr = @($brief.merged) | Select-Object -First 1
            $mergedIn = @($mergedPr.instances | ForEach-Object { "$($_.name) $($_.verdict)" }) -join ', '
            Add-Result 'fake' 'brief merged pull request' $(if ($mergedIn -eq 'qa NOT_IN, staging IN') { 'ok' } else { 'fail' }) "PR $($mergedPr.id): $mergedIn; expected qa NOT_IN, staging IN"
            $md = if ($brief.files.markdown -and (Test-Path -LiteralPath $brief.files.markdown)) { Get-Content -Raw -Encoding utf8 -LiteralPath $brief.files.markdown } else { '' }
            Add-Result 'fake' 'brief text' $(if ($md -match 'FAKE-1' -and $md -match 'Quality' -and $md -notmatch '\{\{') { 'ok' } else { 'fail' }) "brief.md has the tickets, the quality tool's name, and no unfilled {{value}}"
        }

        $c = Invoke-Kit $kitScripts.chief @('plan', '-Json')
        $plan = if ($c.code -eq 0) { ConvertFrom-KitJson $c.out }
        $actions = @{}
        foreach ($item in @($plan.items)) { $actions[[string]$item.key] = [string]$item.action }
        Add-Result 'fake' 'planner' $(if ($actions['FAKE-1'] -eq 'test' -and $actions['FAKE-2'] -eq 'teams') { 'ok' } else { 'fail' }) "FAKE-1 $($actions['FAKE-1']), FAKE-2 $($actions['FAKE-2']); expected test and a message to the developer"
        $pinged = @($plan.items | Where-Object { $_.action -eq 'ping' })
        $pingDef = @($plan.actions | Where-Object { $_.name -eq 'ping' }) | Select-Object -First 1
        $pingOk = $pinged.Count -and $pinged[0].proposal -clike 'ask *' -and $pinged[0].label -eq 'ping them' -and $pinged[0].reason -eq 'No instance has it yet.' -and $pingDef.how
        Add-Result 'fake' 'planner own action' $(if ($pingOk) { 'ok' } else { 'fail' }) "the pack's action ping: $($pinged.Count) item(s), proposal '$(if ($pinged.Count) { $pinged[0].proposal })', reason '$(if ($pinged.Count) { $pinged[0].reason })', how listed $([bool]$pingDef.how)"
        [void](Invoke-Kit $setupScript @('set', '-Key', 'chief.use.ping', '-Value', 'false', '-AsJson'))
        $noPing = ConvertFrom-KitJson (Invoke-Kit $kitScripts.chief @('plan', '-Json')).out
        [void](Invoke-Kit $setupScript @('unset', '-Key', 'chief.use'))
        $stillPinged = @($noPing.items | Where-Object { $_.action -eq 'ping' }).Count
        Add-Result 'fake' 'planner actions used' $(if ($noPing -and -not $stillPinged) { 'ok' } else { 'fail' }) "with chief.use.ping = false, $stillPinged ping item(s); expected none"

        $t = Invoke-Kit $kitScripts.delivery @('ticket', '-Key', 'FAKE-2', '-Json')
        $ticket = if ($t.code -eq 0) { ConvertFrom-KitJson $t.out }
        $envs = @($ticket.instances | ForEach-Object { "$($_.name) $($_.verdict)$(if ($_.firstVersion) { " from $($_.firstVersion)" })" }) -join ', '
        Add-Result 'fake' 'delivery ticket' $(if ($envs -eq 'qa NOT_IN from 1.2.0, staging IN from 1.2.0') { 'ok' } else { 'fail' }) "FAKE-2: $envs"
        $d = Invoke-Kit $kitScripts.delivery @('deployed', '-Pr', '6', '-Json')
        $deployed = if ($d.code -eq 0) { ConvertFrom-KitJson $d.out }
        Add-Result 'fake' 'delivery deployed' $(if ($deployed.merged -and (@($deployed.publishes)[0]).verdict -eq 'IN') { 'ok' } else { 'fail' }) "PR 6 merged $($deployed.merged), last release $((@($deployed.publishes)[0]).verdict)"
        $tn = ConvertFrom-KitJson (Invoke-Kit $kitScripts.delivery @('ticket', '-Key', 'FAKE-2', '-NoFetch', '-Json')).out
        $envsNoFetch = @($tn.instances | ForEach-Object { "$($_.name) $($_.verdict)$(if ($_.firstVersion) { " from $($_.firstVersion)" })" }) -join ', '
        Add-Result 'fake' 'delivery without fetch' $(if ($envsNoFetch -eq $envs) { 'ok' } else { 'fail' }) "FAKE-2 with -NoFetch: $envsNoFetch; expected the same as with the fetch"

        $rv = @(ConvertFrom-KitJson (Invoke-Kit $kitScripts.repo @('prs', '-Role', 'reviewer', '-Json')).out | ForEach-Object { $_ })
        Add-Result 'fake' 'repo reviews' $(if ($rv.Count -eq 1 -and $rv[0].id -eq 8 -and $rv[0].myReview -eq 'none' -and $rv[0].author -eq 'Dana Dev') { 'ok' } else { 'fail' }) "prs -Role reviewer: $(@($rv | ForEach-Object { "#$($_.id) by $($_.author), my review $($_.myReview)" }) -join '; '); expected #8 by Dana Dev, none"
        $src = @(ConvertFrom-KitJson (Invoke-Kit $kitScripts.repo @('prs', '-Source', 'feature/FAKE-4-export', '-Json')).out | ForEach-Object { $_ })
        Add-Result 'fake' 'repo branch' $(if ($src.Count -eq 1 -and $src[0].id -eq 8) { 'ok' } else { 'fail' }) "prs -Source feature/FAKE-4-export: $(@($src | ForEach-Object { "#$($_.id)" }) -join ', '); expected #8, someone else's"
        $mg = ConvertFrom-KitJson (Invoke-Kit $kitScripts.repo @('mergeable', '-Pr', '7', '-Repo', 'demo', '-Project', 'DEMO', '-Json')).out
        Add-Result 'fake' 'repo mergeable' $(if ($mg -and $mg.canMerge -eq $false -and @($mg.vetoDetails).Count -eq @($mg.vetoes).Count -and @($mg.vetoes).Count -eq 1) { 'ok' } else { 'fail' }) "canMerge $($mg.canMerge), $(@($mg.vetoes).Count) veto(es) with $(@($mg.vetoDetails).Count) detail(s)"

        $w = Invoke-Kit $kitScripts.board @('comment', '-Key', 'FAKE-1', '-Body', 'Retest passed on qa 1.1.0.', '-Json')
        $logged = Test-Path -LiteralPath (Join-Path $state 'fake-writes.jsonl')
        Add-Result 'fake' 'board write' $(if ($w.code -eq 0 -and $logged) { 'ok' } else { 'fail' }) "comment answered $($w.code); write log $(if ($logged) { 'written' } else { 'missing' })"
        $l = Invoke-Kit $kitScripts.chat @('-To', 'dana', '-Message', 'kit test', '-Json')
        $link = ConvertFrom-KitJson $l.out
        Add-Result 'fake' 'chat link' $(if ($l.code -eq 0 -and $link.prefilled -eq $false) { 'ok' } else { 'fail' }) "prefilled $($link.prefilled) (the fake cannot carry the message, so the skill's paste fallback applies)"

        $s = Invoke-Kit $kitScripts.specs @('Login, a1-story-7 in the summary', '-Json')
        $spec = if ($s.code -eq 0) { ConvertFrom-KitJson $s.out }
        $kinds = @($spec.files | ForEach-Object { $_.kind }) -join ' '
        $wrongFile = @($spec.files | Where-Object { $_.path -notmatch 'A1_ST_007_' }).Count
        Add-Result 'fake' 'specs files' $(if ($kinds -eq 'scope acceptance scenarios other' -and -not $wrongFile) { 'ok' } else { 'fail' }) "a1-story-7: $(if ($spec) { $kinds } else { "exit $($s.code): $($s.err)" }); expected scope acceptance scenarios other, only A1_ST_007_ files"
        $sn = Invoke-Kit $kitScripts.specs @('no code here', '-Json')
        Add-Result 'fake' 'specs no code' $(if ($sn.code -eq 1 -and $sn.err -match 'an <area>-story-<n> code' -and $sn.err -match 'What to try') { 'ok' } else { 'fail' }) "exit $($sn.code): $("$($sn.err)".Trim())"
        $sm = ConvertFrom-KitJson (Invoke-Kit $kitScripts.specs @('a1-story-9', '-Json')).out
        Add-Result 'fake' 'specs moved story' $(if ($sm.fallback -eq 'whole-root' -and @($sm.files).Count -eq 2 -and $sm.note -match 'folderTemplate') { 'ok' } else { 'fail' }) "a1-story-9, kept under B2: fallback $($sm.fallback), $(@($sm.files).Count) file(s); expected whole-root, 2, a note naming folderTemplate"
        $su = ConvertFrom-KitJson (Invoke-Kit $kitScripts.specs @('A1_XX_010', '-Json')).out
        Add-Result 'fake' 'specs unreadable code' $(if ($su.fallback -eq 'name-search' -and @($su.files).Count -eq 1 -and $su.note -match 'codePattern') { 'ok' } else { 'fail' }) "A1_XX_010: fallback $($su.fallback), $(@($su.files).Count) file(s); expected name-search, 1, a note naming codePattern"
        $sx = Invoke-Kit $kitScripts.specs @('a1-story-99', '-Json')
        Add-Result 'fake' 'specs missing story' $(if ($sx.code -eq 1 -and $sx.err -match 'Also searched' -and $sx.err -match 'What to try') { 'ok' } else { 'fail' }) "a1-story-99: exit $($sx.code), the error says what was searched and what to try"
        $sc = ConvertFrom-KitJson (Invoke-Kit $kitScripts.specs @('-Check', '-Json')).out
        Add-Result 'fake' 'specs coverage' $(if ($sc.coverage.unrecognized -eq 1 -and $sc.coverage.misplaced -eq 2) { 'ok' } else { 'fail' }) "unrecognized $($sc.coverage.unrecognized), misplaced $($sc.coverage.misplaced); expected 1 (A1_XX_010) and 2 (the files under B2)"

        $guardScript = Join-Path $SkillsRoot "$($defaults.kit.hooks.source)\$(@($defaults.kit.hooks.entries)[0].script)"
        foreach ($agent in 'cursor', 'claude') {
            foreach ($probe in @(@{ want = 'ask'; command = 'pwsh -NoProfile -File $kit.board comment -Key FAKE-1 -Body hi' }, @{ want = 'allow'; command = 'pwsh -NoProfile -File $kit.board issue -Key FAKE-1' })) {
                $got = Get-GuardAnswer $guardScript $agent $probe.command
                Add-Result 'fake' "guard $agent $($probe.want)" $(if ($got -eq $probe.want) { 'ok' } else { 'fail' }) "$($probe.command) -> $got$(if ($agent -eq 'claude' -and $got -eq 'allow') { ' (no answer, so Claude Code''s own permission flow applies)' })"
            }
        }

        # --- The installer and project packs, in a copy of the clone; <KIT>_HOME keeps the person's folders in the sandbox.
        $installer = Join-Path (Split-Path -Parent $SkillsRoot) 'Install.ps1'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { Add-Result 'fake' 'install' 'skip' "No Install.ps1 next to ${SkillsRoot}: run the test from the kit's clone to check the installer." }
        else {
            $ib = Join-Path $sandbox 'install'
            $clone2 = Join-Path $ib 'kit'
            New-Item -ItemType Directory -Force -Path $clone2 | Out-Null
            Copy-Item -LiteralPath $SkillsRoot -Destination (Join-Path $clone2 'skills') -Recurse
            Copy-Item -LiteralPath $installer -Destination $clone2
            $uninstaller = Join-Path (Split-Path -Parent $SkillsRoot) 'Uninstall.ps1'
            if (Test-Path -LiteralPath $uninstaller -PathType Leaf) { Copy-Item -LiteralPath $uninstaller -Destination $clone2 }
            $prefix = $kitConfigVar -replace '_CONFIG$', ''
            [Environment]::SetEnvironmentVariable($kitConfigVar, $null, 'Process')
            [Environment]::SetEnvironmentVariable("${prefix}_HOME", (Join-Path (Join-Path $ib 'home') $kitName), 'Process')
            $skills2 = Join-Path $ib 'skills'
            $hooks2 = Join-Path $ib 'hooks.json'
            $installArgs = @('-Target', $skills2, '-HooksFile', $hooks2, '-StateRoot', (Join-Path $ib 'state'))
            $i1 = Invoke-Kit (Join-Path $clone2 'Install.ps1') $installArgs
            $source2 = Join-Path $skills2 'setup\.kit-source.json'
            Add-Result 'fake' 'install kit alone' $(if ($i1.code -eq 0 -and (Test-Path -LiteralPath $source2) -and (Get-Content -Raw (Join-Path $skills2 'setup\.kit')).Trim() -eq $kitName) { 'ok' } else { 'fail' }) "exit $($i1.code); install record $(Test-Path -LiteralPath $source2)"

            $setup2 = Join-Path $skills2 'setup\scripts\Initialize-Config.ps1'
            $v1 = Invoke-Kit $setup2 @('version')
            $ver = if ($v1.code -eq 0) { ConvertFrom-KitJson $v1.out } else { $null }
            $verOk = $ver -and $ver.version -eq $engineVersion -and $ver.name -eq $kitName -and $ver.source -eq $clone2 -and $ver.installedAt
            Add-Result 'fake' 'installed version' $(if ($verOk) { 'ok' } else { 'fail' }) "exit $($v1.code); $(if ($ver) { "$($ver.name) $($ver.version) from $($ver.source)" })"

            function New-FakePack([string]$Dir, [string]$Name, [string]$RepoName) {
                New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'roles') | Out-Null
                $values = [ordered]@{ pack = @{ name = $Name; description = "The $Name project." }; repos = @(@{ path = 'paths.codeRepo'; name = $RepoName; cloneUrl = "fake://code/x/$RepoName.git"; uses = 'tests' }) }
                Set-Content -LiteralPath (Join-Path $Dir 'pack.json') -Value ($values | ConvertTo-Json -Depth 5) -Encoding utf8
                Set-Content -LiteralPath (Join-Path $Dir 'roles\tester.json') -Value '{ "role": { "title": "Tester" } }' -Encoding utf8
            }
            $alpha = Join-Path $ib 'alpha-src\alpha-pack'
            New-FakePack $alpha 'alpha' 'alpha-app'
            $zip = Join-Path $ib 'alpha-pack.zip'
            Compress-Archive -Path $alpha -DestinationPath $zip
            $a1 = Invoke-Kit $setup2 @('add-pack', '-From', $zip)
            $alphaOk = $a1.code -eq 0 -and (Test-Path -LiteralPath (Join-Path $clone2 'packs\alpha\pack.json')) -and (Test-Path -LiteralPath (Join-Path $skills2 'setup\packs\alpha\pack.json')) -and (Test-Path -LiteralPath (Join-Path $ib "home\$kitName\alpha\config.json"))
            Add-Result 'fake' 'add pack from a zip' $(if ($alphaOk) { 'ok' } else { 'fail' }) "exit $($a1.code)$(if ($a1.code) { ": $($a1.err)" }); in packs\alpha, installed, and its own configuration"

            $beta = Join-Path $ib 'beta-pack'
            New-FakePack $beta 'beta' 'beta-app'
            $b1 = Invoke-Kit $setup2 @('add-pack', '-From', $beta)
            $both = @(Get-ChildItem -LiteralPath (Join-Path $skills2 'setup\packs') -Directory | ForEach-Object { $_.Name }) -join ','
            Add-Result 'fake' 'add a second pack' $(if ($b1.code -eq 0 -and $both -eq 'alpha,beta') { 'ok' } else { 'fail' }) "exit $($b1.code)$(if ($b1.code) { ": $($b1.err)" }); installed: $both"

            $work = Join-Path $ib 'work-beta'
            Invoke-SandboxGit $ib @('init', '-q', $work)
            Invoke-SandboxGit $work @('remote', 'add', 'origin', 'fake://code/x/beta-app.git')
            Push-Location $work; try { $inBeta = ConvertFrom-KitJson (Invoke-Kit $setup2 @('packs')).out } finally { Pop-Location }
            Push-Location $ib; try { $outside = ConvertFrom-KitJson (Invoke-Kit $setup2 @('packs')).out; $noScripts = Invoke-Kit $setup2 @('scripts') } finally { Pop-Location }
            Add-Result 'fake' 'pack by repository' $(if ($inBeta.active -eq 'beta' -and $inBeta.chosenBy -eq 'repository') { 'ok' } else { 'fail' }) "in a clone of beta-app: $($inBeta.active) ($($inBeta.chosenBy))"
            Add-Result 'fake' 'pack not chosen' $(if (-not $outside.active -and $outside.chosenBy -eq 'unchosen' -and $noScripts.code -eq 2) { 'ok' } else { 'fail' }) "outside every repository with two packs and no default: $($outside.chosenBy); scripts exit $($noScripts.code)"
            [void](Invoke-Kit $setup2 @('default-pack', '-Name', 'alpha'))
            Push-Location $ib; try { $dflt = ConvertFrom-KitJson (Invoke-Kit $setup2 @('packs')).out } finally { Pop-Location }
            Add-Result 'fake' 'default pack' $(if ($dflt.active -eq 'alpha' -and $dflt.chosenBy -eq 'default') { 'ok' } else { 'fail' }) "outside every repository: $($dflt.active) ($($dflt.chosenBy))"

            $gamma = Join-Path $ib 'gamma-pack'
            New-FakePack $gamma 'gamma' 'gamma-app'
            Set-Content -LiteralPath (Join-Path $gamma 'helper.ps1') -Value 'Write-Output hi' -Encoding utf8
            $g1 = Invoke-Kit $setup2 @('add-pack', '-From', $gamma)
            Add-Result 'fake' 'pack with a program' $(if ($g1.code -eq 1 -and $g1.err -match 'AllowScripts' -and -not (Test-Path -LiteralPath (Join-Path $clone2 'packs\gamma'))) { 'ok' } else { 'fail' }) "exit $($g1.code): refused until the person agrees"

            $delta = Join-Path $ib 'delta-pack'
            New-FakePack $delta 'delta' 'delta-app'
            $deltaValues = Get-Content -Raw (Join-Path $delta 'pack.json') | ConvertFrom-Json
            $deltaValues | Add-Member -NotePropertyName kit -NotePropertyValue ([pscustomobject]@{ minVersion = '99.0.0' }) -Force
            Set-Content -LiteralPath (Join-Path $delta 'pack.json') -Value ($deltaValues | ConvertTo-Json -Depth 5) -Encoding utf8
            $d1 = Invoke-Kit $setup2 @('add-pack', '-From', $delta)
            $d2 = Invoke-Kit (Join-Path $clone2 'Install.ps1') ($installArgs + @('-Pack', $delta))
            $newerOk = $d1.code -eq 1 -and $d1.err -match '99\.0\.0' -and -not (Test-Path -LiteralPath (Join-Path $clone2 'packs\delta')) -and $d2.code -eq 1 -and "$($d2.out)" -match '99\.0\.0'
            Add-Result 'fake' 'pack needing a newer kit' $(if ($newerOk) { 'ok' } else { 'fail' }) "add-pack exit $($d1.code), not left in packs\: $(-not (Test-Path -LiteralPath (Join-Path $clone2 'packs\delta'))); Install -Pack exit $($d2.code)"

            $hookEntries = @((Get-Content -Raw $hooks2 | ConvertFrom-Json).hooks.beforeShellExecution | Where-Object { "$($_.command)" -match [regex]::Escape("\hooks\$kitName\") })
            Add-Result 'fake' 'one guard' $(if ($hookEntries.Count -eq 1) { 'ok' } else { 'fail' }) "$($hookEntries.Count) kit entr$(if ($hookEntries.Count -eq 1) { 'y' } else { 'ies' }) for beforeShellExecution after three installs"

            # An install under an earlier name (a pack used to rename the kit): its folders, its guard and the person's configuration move over.
            $skills3 = Join-Path $ib 'skills-old'
            New-Item -ItemType Directory -Force -Path (Join-Path $skills3 'board') | Out-Null
            Set-Content -LiteralPath (Join-Path $skills3 'board\.kit') -Value 'oldkit' -NoNewline
            Set-Content -LiteralPath (Join-Path $skills3 'board\.kit-installed.json') -Value '{}'
            Set-Content -LiteralPath (Join-Path $skills3 'board\SKILL.md') -Value 'old'
            $hooks3 = Join-Path $ib 'hooks-old.json'
            Set-Content -LiteralPath $hooks3 -Value (@{ version = 1; hooks = @{ beforeShellExecution = @(@{ command = 'pwsh -File "x\hooks\oldkit\Guard-Write.ps1"'; failClosed = $true }) } } | ConvertTo-Json -Depth 6)
            $oldHome = Join-Path $ib 'home\oldkit'
            New-Item -ItemType Directory -Force -Path $oldHome | Out-Null
            Set-Content -LiteralPath (Join-Path $oldHome 'config.json') -Value (@{ version = 2; kit = @{ packFile = (Join-Path $clone2 'packs\alpha\pack.json') }; user = @{ name = 'Old Me' } } | ConvertTo-Json -Depth 4)
            [Environment]::SetEnvironmentVariable("${prefix}_HOME", (Join-Path (Join-Path $ib 'home') 'fresh'), 'Process')
            Remove-Item -LiteralPath (Join-Path $clone2 'packs\beta') -Recurse -Force
            $m1 = Invoke-Kit (Join-Path $clone2 'Install.ps1') @('-Target', $skills3, '-HooksFile', $hooks3, '-StateRoot', (Join-Path $ib 'state-old'))
            $movedMarker = (Get-Content -Raw (Join-Path $skills3 'board\.kit')).Trim()
            $oldEntries = @((Get-Content -Raw $hooks3 | ConvertFrom-Json).hooks.beforeShellExecution | Where-Object { "$($_.command)" -match '\\hooks\\oldkit\\' }).Count
            $migratedName = if (Test-Path -LiteralPath (Join-Path $ib 'home\fresh\alpha\config.json')) { [string](Get-Content -Raw (Join-Path $ib 'home\fresh\alpha\config.json') | ConvertFrom-Json).user.name } else { '' }
            $migrateOk = $m1.code -eq 0 -and $movedMarker -eq $kitName -and -not $oldEntries -and $migratedName -eq 'Old Me'
            Add-Result 'fake' 'install over an earlier name' $(if ($migrateOk) { 'ok' } else { 'fail' }) "exit $($m1.code); board now says '$movedMarker'; $oldEntries old guard entr$(if ($oldEntries -eq 1) { 'y' } else { 'ies' }); configuration moved: '$migratedName'"

            # Uninstall the first install: only the kit's skills and hook entries go; another program's entry and the person's data stay.
            $uninstall2 = Join-Path $clone2 'Uninstall.ps1'
            if (-not (Test-Path -LiteralPath $uninstall2 -PathType Leaf)) { Add-Result 'fake' 'uninstall' 'skip' 'No Uninstall.ps1 next to Install.ps1.' }
            else {
                [Environment]::SetEnvironmentVariable("${prefix}_HOME", (Join-Path (Join-Path $ib 'home') $kitName), 'Process')
                $withOther = Get-Content -Raw $hooks2 | ConvertFrom-Json
                $withOther.hooks | Add-Member -NotePropertyName sessionStart -NotePropertyValue @([pscustomobject]@{ command = 'pwsh -File "x\my-own-hook.ps1"' }) -Force
                Set-Content -LiteralPath $hooks2 -Value ($withOther | ConvertTo-Json -Depth 10) -Encoding utf8
                $uArgs = @('-Target', $skills2, '-HooksFile', $hooks2)
                $l1 = Invoke-Kit $uninstall2 ($uArgs + '-List')
                $stillThere = @(Get-ChildItem -LiteralPath $skills2 -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.kit') }).Count
                Add-Result 'fake' 'uninstall, listing' $(if ($l1.code -eq 0 -and $stillThere -ge 6) { 'ok' } else { 'fail' }) "-List: exit $($l1.code), $stillThere kit skill folders still in place"
                $u1 = Invoke-Kit $uninstall2 $uArgs
                $left = @(Get-ChildItem -LiteralPath $skills2 -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.kit') }).Count
                $after = Get-Content -Raw $hooks2 | ConvertFrom-Json
                $kitLeft = @(@($after.hooks.PSObject.Properties | ForEach-Object { $_.Value }) | Where-Object { "$($_.command)" -match [regex]::Escape("\hooks\$kitName\") }).Count
                $otherKept = @($after.hooks.sessionStart | Where-Object { "$($_.command)" -match 'my-own-hook' }).Count
                $dataKept = Test-Path -LiteralPath (Join-Path $ib "home\$kitName\alpha\config.json")
                $inBackup = @(Get-ChildItem -LiteralPath (Join-Path $ib "home\$kitName\backup") -Directory -Filter 'uninstall-*' -ErrorAction SilentlyContinue).Count
                $uOk = $u1.code -eq 0 -and -not $left -and -not $kitLeft -and $otherKept -eq 1 -and $dataKept -and $inBackup -eq 1
                Add-Result 'fake' 'uninstall' $(if ($uOk) { 'ok' } else { 'fail' }) "exit $($u1.code); kit skills left $left, kit hook entries left $kitLeft, other entry kept $otherKept, configuration kept $dataKept, skills in a backup $inBackup"
                $u2 = Invoke-Kit $uninstall2 ($uArgs + '-RemoveData')
                Add-Result 'fake' 'uninstall with data' $(if ($u2.code -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $ib "home\$kitName"))) { 'ok' } else { 'fail' }) "-RemoveData: exit $($u2.code); the person's folder removed $(-not (Test-Path -LiteralPath (Join-Path $ib "home\$kitName")))"
            }
        }
    }
    catch { Add-Result 'fake' 'sandbox' 'fail' $_.Exception.Message }
    finally {
        [Environment]::SetEnvironmentVariable($kitConfigVar, $savedConfigVar, 'Process')
        [Environment]::SetEnvironmentVariable(($kitConfigVar -replace '_CONFIG$', '_HOME'), $savedHomeVar, 'Process')
        if ($KeepFake) { Add-Result 'fake' 'sandbox' 'ok' "Kept at $sandbox (the brief is state\brief.md)." }
        elseif (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$summary = [pscustomobject]@{
    ok = @($results | Where-Object status -eq 'ok').Count
    warn = @($results | Where-Object status -eq 'warn').Count
    fail = @($results | Where-Object status -eq 'fail').Count
    skip = @($results | Where-Object status -eq 'skip').Count
}
if ($Json) {
    ConvertTo-Json -InputObject ([pscustomobject]@{ summary = $summary; results = $results.ToArray() }) -Depth 5
}
else {
    foreach ($r in $results) { '{0,-5} {1,-12} {2,-28} {3}' -f $r.status, $r.area, $r.check, $r.detail }
    "$($summary.ok) ok, $($summary.warn) warning(s), $($summary.fail) failure(s), $($summary.skip) skipped"
}
exit $(if ($summary.fail) { 1 } else { 0 })
