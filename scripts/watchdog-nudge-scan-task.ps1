#Requires -Version 5.1
$ErrorActionPreference = 'Continue'
$dir = 'C:\kimi-work\wake-rail'
$stateDir = Join-Path $dir 'state'
$logDir = Join-Path $dir 'logs'
$stateFile = Join-Path $stateDir 'nudge-scan-last-run.json'
$guardLog = Join-Path $logDir 'watchdog-nudge-scan-task.log'
function Find-Daemon {
    $found = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -match 'nudge-scan\.ps1' -and $_.CommandLine -notmatch 'watchdog|guard'
    } | Select-Object -First 1)
    if ($found.Count -gt 0) { return $found }
    $pidFile = Join-Path $stateDir 'nudge-scan.pid'
    if (Test-Path $pidFile) {
        try {
            $daemonPid = [int](Get-Content $pidFile -Raw).Trim()
            if (Get-Process -Id $daemonPid -ErrorAction SilentlyContinue) {
                return @([pscustomobject]@{ ProcessId = $daemonPid })
            }
        } catch {}
    }
    return @()
}
function Write-GuardLog([string]$text) {
    Add-Content -Path $guardLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' | ' + $text) -Encoding UTF8
}
$now = Get-Date
$before = @(Find-Daemon)
$beforePid = if ($before.Count -gt 0) { [int]$before[0].ProcessId } else { $null }
$latest = Get-ChildItem $logDir -Filter 'nudge-scan-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$logAge = if ($latest) { [int]($now - $latest.LastWriteTime).TotalSeconds } else { $null }
$action = 'none'
$previous = $null
if (Test-Path $stateFile) { try { $previous = Get-Content $stateFile -Raw | ConvertFrom-Json } catch {} }
if ($beforePid) {
    if ($null -ne $logAge -and $logAge -gt 180) {
        $action = 'stale-no-kill'
        Write-GuardLog ('STALE-NO-KILL pid=' + $beforePid + ' log_age_sec=' + $logAge)
    }
} else {
    $allowStart = $true
    if ($previous -and $previous.last_start) {
        try {
            $lastStart = [datetime]$previous.last_start
            if (($now - $lastStart).TotalSeconds -lt 120) { $allowStart = $false }
        } catch {}
    }
    if ($allowStart) {
        $action = 'start'
        Write-GuardLog 'DAEMON-DOWN process=absent action=start'
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', 'C:\kimi-work\wake-rail\scripts\nudge-scan.ps1') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir 'daemon-guard-out.txt') -RedirectStandardError (Join-Path $logDir 'daemon-guard-err.txt')
        Start-Sleep -Seconds 15
    } else {
        $action = 'backoff'
        Write-GuardLog 'DAEMON-DOWN action=backoff delay=120'
    }
}
$after = @(Find-Daemon)
$afterPid = if ($after.Count -gt 0) { [int]$after[0].ProcessId } else { $null }
$latestAfter = Get-ChildItem $logDir -Filter 'nudge-scan-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$record = [ordered]@{
    checked_at = $now.ToString('yyyy-MM-dd HH:mm:ss')
    daemon_present = ($null -ne $afterPid)
    daemon_pid = $afterPid
    log_file = if ($latestAfter) { $latestAfter.FullName } else { $null }
    log_mtime = if ($latestAfter) { $latestAfter.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
    log_age_sec = if ($latestAfter) { [int]((Get-Date) - $latestAfter.LastWriteTime).TotalSeconds } else { $null }
    action = $action
    pid_before = $beforePid
    last_start = if ($action -eq 'start') { $now.ToString('yyyy-MM-dd HH:mm:ss') } elseif ($previous) { $previous.last_start } else { $null }
}
[IO.File]::WriteAllText($stateFile, ($record | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
Write-GuardLog ('STATE daemon_present=' + $record.daemon_present + ' pid=' + $record.daemon_pid + ' log_age_sec=' + $record.log_age_sec + ' action=' + $action)
