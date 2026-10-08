#Requires -Version 5.1
<#
.SYNOPSIS
    Registers (or removes) the scheduled keeper task that keeps a supervised stack alive.

.DESCRIPTION
    The task launches a tiny WSH launcher instead of PowerShell directly. The scheduler
    runs console applications in the interactive session, and a console window is created
    even when the payload asks for a hidden window - which shows up as a black window
    flashing on the desktop at every interval. wscript.exe is a GUI-subsystem host, so
    wrapping the payload in a .vbs launcher removes the flash entirely.

.PARAMETER ConfigPath
    Supervisor configuration file the keeper should load.

.PARAMETER TaskName
    Name of the scheduled task. Default: StackKeeper.

.PARAMETER IntervalMinutes
    Repetition interval. Default: 2.

.PARAMETER Remove
    Unregister the task and delete the generated launcher instead of installing.

.EXAMPLE
    .\Install-Keeper.ps1 -ConfigPath C:\ProgramData\edge-gateway\supervisor.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ConfigPath,
    [string]$TaskName = 'StackKeeper',
    [int]$IntervalMinutes = 2,
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$keeperScript = Join-Path $repoRoot 'src\StackKeeper.ps1'
$configDir = Split-Path -Parent $ConfigPath
$launcher = Join-Path $configDir 'launch-keeper.vbs'

if ($Remove) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
    Write-Host ("Removed scheduled task '{0}' and launcher {1}" -f $TaskName, $launcher)
    return
}

if (-not (Test-Path -LiteralPath $keeperScript)) { throw "Keeper script not found: $keeperScript" }
if (-not (Test-Path -LiteralPath $ConfigPath))   { throw "Configuration not found: $ConfigPath" }
if (-not (Test-Path -LiteralPath $configDir))    { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

# The launcher is generated (not shipped) so that both paths are baked in and quoting
# cannot drift between file system layouts.
$launcherBody = 'CreateObject("WScript.Shell").Run "powershell.exe -ExecutionPolicy Bypass ' +
                '-NoProfile -WindowStyle Hidden -File {0} -ConfigPath ""{1}""", 0, False' -f $keeperScript, $ConfigPath
[System.IO.File]::WriteAllText($launcher, $launcherBody + [char]13 + [char]10, [System.Text.Encoding]::ASCII)

$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $launcher + '"')
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

$info = Get-ScheduledTaskInfo -TaskName $TaskName
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ("Registered '{0}'" -f $TaskName)
Write-Host ("  action  : {0} {1}" -f $task.Actions[0].Execute, $task.Actions[0].Arguments)
Write-Host ("  interval: {0}" -f $task.Triggers[0].Repetition.Interval)
Write-Host ("  next run: {0}" -f $info.NextRunTime)
Write-Host ''
Write-Host 'Run it once now to verify:  schtasks /run /tn ' -NoNewline
Write-Host $TaskName
