#Requires -Version 5.1
# register-watcher-events-task.ps1 - I-328: autostart for watchdog-events-watcher.ps1
# Mirrors install-nudge-scan-watchdog.ps1 (I-306) / KimiNudgeScanWatchdog task pattern.
# Task: wake-rail-watcher-events (AtStartup + 1-min repetition, hidden powershell -File,
# MultipleInstances IgnoreNew, ExecutionTimeLimit 0, Interactive/Limited principal).
# Watchdog is self-guarding (Global mutex + process scan) -> re-runs spawn no duplicates.
param([string]$Evidence = 'C:\kimi-work\artifacts\i328-watcher-events-install.json')
$ErrorActionPreference = 'Stop'
$taskName = 'wake-rail-watcher-events'
$dir = 'C:\kimi-work\tools\ruki-v3'
$script = Join-Path $dir 'watchdog-events-watcher.ps1'
if (-not (Test-Path $script)) { throw "watchdog script missing: $script" }

function Watchdog-Pids { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'watchdog-events-watcher\.ps1' -and $_.CommandLine -notmatch 'Where-Object' } | ForEach-Object { $_.ProcessId }) }
function Node-Ew-Pids { @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'events-watcher\.js' -and $_.CommandLine -notmatch 'Where-Object' } | ForEach-Object { $_.ProcessId }) }

$beforeTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$before = [ordered]@{ task_exists = [bool]$beforeTask; watchdog_pids = @(Watchdog-Pids); node_ew_pids = @(Node-Ew-Pids) }
if ($beforeTask) { Export-ScheduledTask -TaskName $taskName | Set-Content -Path ($Evidence + '.task.xml') -Encoding Unicode }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"') -WorkingDirectory $dir
$startup = New-ScheduledTaskTrigger -AtStartup
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-21-673771678-3376713479-78881437-1000' -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startup, $repeat) -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 8

$afterTask = Get-ScheduledTask -TaskName $taskName
$after = [ordered]@{ task_state = [string]$afterTask.State; watchdog_pids = @(Watchdog-Pids); node_ew_pids = @(Node-Ew-Pids); log_tail = @(Get-Content (Join-Path $dir 'logs\watchdog-events-watcher.log') -Tail 4 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { [string]$_ }) }
$record = [ordered]@{ before = $before; after = $after; ok = ($after.watchdog_pids.Count -eq 1 -and $after.node_ew_pids.Count -ge 1) }
$parent = Split-Path -Parent $Evidence
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText($Evidence, ($record | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
$record | ConvertTo-Json -Depth 6
if (-not $record.ok) { exit 1 }
