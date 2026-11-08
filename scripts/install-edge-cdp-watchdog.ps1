#Requires -Version 5.1
param([string]$Evidence = 'C:\kimi-work\artifacts\i306-edge-watchdog-install.json')
$ErrorActionPreference = 'Stop'
$taskName = 'KimiEdgeCdpWatchdog'
$script = 'C:\kimi-work\wake-rail\scripts\watchdog-edge-cdp.ps1'
function Get-Ports {
    $result = [ordered]@{}
    foreach ($port in @('9222')) {
        try {
            $v = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/version') -TimeoutSec 3
            $result[$port] = [bool]$v.Browser
        } catch { $result[$port] = $false }
    }
    return $result
}
$beforeTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$before = [ordered]@{ task_exists = [bool]$beforeTask; ports = Get-Ports }
if ($beforeTask) {
    Export-ScheduledTask -TaskName $taskName | Set-Content -Path 'C:\kimi-work\artifacts\i306-edge-watchdog-task-backup.xml' -Encoding Unicode
}
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"')
$startup = New-ScheduledTaskTrigger -AtStartup
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startup, $repeat) -Settings $settings -Principal $principal -Force | Out-Null
$task = Enable-ScheduledTask -TaskName $taskName
if ($task.State -ne 'Running') { Start-ScheduledTask -TaskName $taskName }
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 1
    $ports = Get-Ports
    if ($ports['9222']) { break }
}
$afterTask = Get-ScheduledTask -TaskName $taskName
$after = [ordered]@{
    task_state = [string]$afterTask.State
    action = $afterTask.Actions[0].Execute + ' ' + $afterTask.Actions[0].Arguments
    ports = $ports
}
$record = [ordered]@{ before = $before; after = $after; ok = ($after.task_state -eq 'Running' -and $ports['9222']) }
$parent = Split-Path -Parent $Evidence
if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
[IO.File]::WriteAllText($Evidence, ($record | ConvertTo-Json -Depth 7), (New-Object Text.UTF8Encoding $false))
$record | ConvertTo-Json -Depth 7
if (-not $record.ok) { exit 1 }
