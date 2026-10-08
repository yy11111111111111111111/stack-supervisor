#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Pester v5 test suite.
.DESCRIPTION
    Discovers *.Tests.ps1 files in the selected directory and runs them. Use -CI to treat a
    missing suite as a failure.
.EXAMPLE
    .\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = $PSScriptRoot,
    [switch]$CI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tests = @(Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue)
if ($tests.Count -eq 0) {
    Write-Host 'No test files found. See tests/README.md for the expected coverage.'
    if ($CI) { exit 1 }
    exit 0
}

$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -ge 5 } | Select-Object -First 1
if (-not $pester) {
    Write-Host 'Pester v5 is required to run the suite:  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser'
    exit 1
}

Import-Module Pester -MinimumVersion 5.0
$result = Invoke-Pester -Path $tests.FullName -PassThru -Output Detailed
if ($result.FailedCount -gt 0) { exit 1 }
exit 0

