' Template for a hidden launcher. Install-Keeper.ps1 generates one with real paths.
' Task Scheduler starts console applications in the interactive session; a direct
' powershell.exe action flashes a console window even with -WindowStyle Hidden.
' wscript.exe is a GUI-subsystem host, so this wrapper produces no window at all.
'
' Replace <SCRIPT> and <CONFIG> (or let Install-Keeper.ps1 generate the file).
CreateObject("WScript.Shell").Run "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File <SCRIPT> -ConfigPath ""<CONFIG>""", 0, False
