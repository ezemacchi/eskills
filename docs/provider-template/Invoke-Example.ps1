#Requires -Version 7
<#
.SYNOPSIS
    TEMPLATE: the board capability for <service>. Copy this folder to
    skills/setup/providers/<capability>/<name>/ (or a pack's providers/), rename, and fill it in.

.DESCRIPTION
    Implement the commands of the capability's contract (docs/contracts/<capability>.md) that the
    manifest lists. With -Json each prints exactly the contract's shape; without it, text for a person.
    Read only your own keys (providers.<name>.*) and the common ones (paths.*, user.*, board.views).

    Before it runs, replace the two kit-config lines below with the kit-config block copied from any
    kit script (for example skills/setup/providers/board/jira-cloud/Invoke-Jira.ps1): it must be
    identical, and Test-Kit.ps1 -Static fails until it is.

.NOTES
    Exit codes: 0 ok, 1 bad input or an unexpected answer, 2 missing configuration or credentials,
    3 the service refused the credentials ("refused: ...") or could not be reached ("unreachable: ...").
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('me', 'view', 'issue', 'comments', 'comment', 'edit-comment', 'transition', 'discover', 'notes')]
    [string] $Command,
    [string] $Key,
    [string] $Id,
    [string] $To,
    [string] $Body,
    [string] $BodyFile,
    [string] $CommentId,
    [int] $Days = 180,
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

# kit-config:start
# kit-config:end

$cfg = Get-KitConfig
# One name for the prefix. A script-level loop variable spelled like it (PowerShell ignores case)
# would overwrite it.
$ProviderKey = 'providers.example-board'
$Site = ([string](Get-KitValue $cfg "$ProviderKey.site" -Required)).TrimEnd('/')
$TokenVar = [string](Get-KitValue $cfg "$ProviderKey.tokenVar" -Required)
$token = Get-KitEnv $TokenVar
if (-not $token) { Stop-Kit 2 "No token: set the user variable $TokenVar. /setup explains how." }

# Never put the token in a message, a file, or a command line: only in a request header.
function Invoke-Api([string]$Method, [string]$Path, $Payload = $null) {
    $request = @{ Uri = "$Site$Path"; Method = $Method; Headers = @{ Authorization = "Bearer $token"; Accept = 'application/json' }; TimeoutSec = 30 }
    if ($null -ne $Payload) { $request.Body = ($Payload | ConvertTo-Json -Depth 6); $request.ContentType = 'application/json; charset=utf-8' }
    try { Invoke-RestMethod @request }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($status -in 401, 403) { Stop-Kit 3 "refused: <service> refused the token in $TokenVar ($status)." }
        if ($status -eq 0) { Stop-Kit 3 'unreachable: cannot reach <service>.' }
        Stop-Kit 1 "Unexpected answer from <service> ($status) for $(($Path -split '\?')[0])."
    }
}

function Out-Contract($Value) {
    if ($Json) { ConvertTo-Json -InputObject $Value -Depth 8 } else { $Value | Format-List | Out-String -Width 160 }
}

switch ($Command) {
    'me' {
        # $u = Invoke-Api GET '/api/me'
        # Out-Contract ([pscustomobject]@{ id = $u.id; name = $u.name; email = $u.email; active = $true })
        Stop-Kit 1 'me: not written yet.'
    }
    'view' {
        # Run the saved view's query (board.views, the one with id -Id) in the service's own language,
        # and print { id, title, more, issues: [ { key, link, <field>: string, statusCategory } ] }.
        Stop-Kit 1 'view: not written yet.'
    }
    default { Stop-Kit 1 "$($Command): not written yet." }
}
exit 0
