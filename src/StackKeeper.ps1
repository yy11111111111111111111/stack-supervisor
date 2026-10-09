#Requires -Version 5.1
<#
.SYNOPSIS
    Keeps every component of a supervised stack alive, using the OS scheduler instead of
    trusting the components to watch each other.

.DESCRIPTION
    Mutual process supervision has a single point of failure: if every supervisor is
    stopped at once - by a cleaner, a security tool, a logoff, or an unlucky process-tree
    cleanup - nothing is left to notice. This keeper is launched by the operating system
    scheduler, so it does not belong to any process tree that a session can tear down.

    It reads a component list from the supervisor configuration and, for each component,
    checks the detection rule and runs the recovery command when the component is absent.

.PARAMETER ConfigPath
    Path to the supervisor configuration file.

.PARAMETER Quiet
    Suppress console output (used when invoked by the scheduler).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'
$script:CRLF = [string][char]13 + [char]10

function Write-KeeperLog {
    param([string]$Message, [string]$Path)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($Path) {
        try { [System.IO.File]::AppendAllText($Path, $line + $script:CRLF, (New-Object System.Text.UTF8Encoding($true))) } catch { }
    }
    if (-not $Quiet) { Write-Host $line }
}

function Test-KeeperCommandLineMatch {
    param([object[]]$Processes, [Parameter(Mandatory)][int]$SelfProcessId, [Parameter(Mandatory)][string]$Pattern)
    return [bool](@($Processes | Where-Object {
        $_.ProcessId -ne $SelfProcessId -and $_.CommandLine -match $Pattern
    }).Count -gt 0)
}

$config = ([System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)) | ConvertFrom-Json
$logPath = [string]$config.keepAlive.log
$recovered = @()

foreach ($component in $config.keepAlive.components) {
    $present = $false
    switch ([string]$component.detect.kind) {
        'process' {
            $present = [bool](Get-Process -Name ([string]$component.detect.name) -ErrorAction SilentlyContinue)
        }
        'commandLine' {
            # Excluding the current process matters: a detection command that embeds the
            # pattern it searches for will otherwise match itself and report a false positive.
            $self = $PID
            $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'")
            $present = Test-KeeperCommandLineMatch -Processes $processes -SelfProcessId $self -Pattern ([string]$component.detect.pattern)
        }
    }
    if (-not $present) {
        $command = [string]$component.start
        $parts = [regex]::Match($command, '^\s*"?([^"]+?)"?\s+(.*)$')
        if ($parts.Success) {
            Start-Process -FilePath $parts.Groups[1].Value -ArgumentList $parts.Groups[2].Value -WindowStyle Hidden
        } else {
            Start-Process -FilePath $command -WindowStyle Hidden
        }
        $recovered += [string]$component.name
        Start-Sleep -Seconds 3
    }
}

if ($recovered.Count -gt 0) { Write-KeeperLog -Message ('recovered: ' + ($recovered -join ', ')) -Path $logPath }
