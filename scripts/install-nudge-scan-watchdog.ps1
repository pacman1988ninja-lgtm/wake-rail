#Requires -Version 5.1
param([string]$Evidence = 'C:\kimi-work\artifacts\i306-nudge-watchdog-install.json')
$ErrorActionPreference = 'Stop'
$taskName = 'KimiNudgeScanWatchdog'
$script = 'C:\kimi-work\wake-rail\scripts\watchdog-nudge-scan-task.ps1'
$beforeTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$beforeDaemons = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'nudge-scan\.ps1' -and $_.CommandLine -notmatch 'watchdog|guard' })
$before = [ordered]@{ task_exists = [bool]$beforeTask; daemon_pids = @($beforeDaemons | ForEach-Object { $_.ProcessId }) }
if ($beforeTask) { Export-ScheduledTask -TaskName $taskName | Set-Content -Path 'C:\kimi-work\artifacts\i306-nudge-watchdog-task-backup.xml' -Encoding Unicode }
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"')
$startup = New-ScheduledTaskTrigger -AtStartup
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startup, $repeat) -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 20
$afterTask = Get-ScheduledTask -TaskName $taskName
$afterDaemons = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'nudge-scan\.ps1' -and $_.CommandLine -notmatch 'watchdog|guard' })
$after = [ordered]@{ task_state = [string]$afterTask.State; daemon_pids = @($afterDaemons | ForEach-Object { $_.ProcessId }); last_run_exists = Test-Path 'C:\kimi-work\wake-rail\state\nudge-scan-last-run.json' }
$record = [ordered]@{ before = $before; after = $after; ok = ($after.last_run_exists -and $after.daemon_pids.Count -gt 0) }
$parent = Split-Path -Parent $Evidence
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText($Evidence, ($record | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
$record | ConvertTo-Json -Depth 6
if (-not $record.ok) { exit 1 }
