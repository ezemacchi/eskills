<#
.SYNOPSIS
    Saves a secret (an API token) as a user environment variable, typed by the user himself.

.DESCRIPTION
    Run it in your own terminal, not through an agent: it asks for the value without showing it, and
    the value never appears on a command line, in a file, or in an agent's chat. The variable names
    the kit uses are in the configuration (jira.tokenVar, bitbucket.tokenVar); /setup tells you which
    one to set.

.EXAMPLE
    pwsh -NoProfile -File Set-Secret.ps1 -Name JIRA_CLOUD_TOKEN
#>
param([Parameter(Mandatory)][string]$Name)

$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { [Console]::Error.WriteLine("'$Name' is not a variable name."); exit 1 }
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
    [Console]::Error.WriteLine('Run this in your own terminal: it reads the value from the keyboard.')
    exit 1
}

$secure = Read-Host "Paste the value for $Name (it is not shown) and press Enter" -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
if (-not $plain) { 'Nothing entered; nothing changed.'; exit 1 }

[Environment]::SetEnvironmentVariable($Name, $plain.Trim(), 'User')
$plain = $null
"Saved $Name for your user. Tell the agent it is done; the kit reads it from your user variables."
exit 0
