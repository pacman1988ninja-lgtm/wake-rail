# watchdog-nudge-scan.ps1 - сторож демона nudge-scan (И-131, тело И-103.6; И-131.1: mutex; И-131.2: GC-KeepAlive)
# Отдельный процесс: падение демона не роняет сторожа. Молчит: записи только
# при событиях + heartbeat раз в час. Антипетля: не более 3 рестартов за 10 минут,
# при превышении - сторож останавливается с записью и не плодит процессы.
$ErrorActionPreference = 'Continue'
$dir = 'C:\kimi-work\wake-rail'
$logDir = Join-Path $dir 'logs'
function Get-WatcherLogFile([datetime]$d = (Get-Date)) { Join-Path $logDir ('watcher-nudge-scan-' + $d.ToString('yyyyMMdd') + '.log') }
function W([string]$s) { $line = (Get-Date -Format 'HH:mm:ss') + ' | ' + $s; Add-Content -Path (Get-WatcherLogFile) -Value $line -Encoding UTF8 }
function Find-Daemon {
  # И-171.1: CIM-вызов с таймаутом (job ≤25с) - зависание WMI не останавливает цикл
  $p = $null
  try {
    $job = Start-Job -ScriptBlock { (Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'nudge-scan\.ps1' -and $_.CommandLine -notmatch 'watchdog' } | Select-Object -First 1).ProcessId }
    if (Wait-Job -Job $job -Timeout 25) { $p = Receive-Job -Job $job }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  } catch { }
  if (-not $p) {
    # И-169.7: CIM-слепота fallback - демон жив, если его лог свеж (<100с)
    try {
      $lg = Get-ChildItem $logDir -Filter 'nudge-scan-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($lg -and ((Get-Date) - $lg.LastWriteTime).TotalSeconds -lt 100) { return 'alive-log' }
    } catch { }
  }
  return $p
}

$me = $PID
# И-131.1: именованный mutex - второй экземпляр при старте обнаруживает первого и выходит с записью
$mtx = $null
try {
  $mtx = New-Object System.Threading.Mutex($false, 'Global\wake-rail-watchdog-nudge-scan')
  if (-not $mtx.WaitOne(0)) { W "DUPLICATE: mutex занят живым сторожом - выход pid=$me"; exit 0 }
} catch { W ("MUTEX_ERR: " + $_.Exception.Message) }
$other = $null
try {
  $ojob = Start-Job -ScriptBlock { Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'watchdog-nudge-scan\.ps1' -and $_.ProcessId -ne $using:me } }
  if (Wait-Job -Job $ojob -Timeout 25) { $other = Receive-Job -Job $ojob }
  Remove-Job -Job $ojob -Force -ErrorAction SilentlyContinue
} catch { }
if ($other) { W ("DUPLICATE: жив сторож PID=" + ($other.ProcessId -join ',') + " - выход pid=$me"); if ($mtx) { $mtx.ReleaseMutex() | Out-Null }; exit 0 }

# И-169.7: pid-file гвард - CIM-независимый, Get-Process видит процессы всегда
$pidFile = Join-Path $dir 'watcher-nudge-scan.pid'
if (Test-Path $pidFile) {
  $oldPid = 0
  try { $oldPid = [int](Get-Content $pidFile -Raw -ErrorAction Stop).Trim() } catch { }
  if ($oldPid -gt 0 -and $oldPid -ne $me) {
    if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) { W "DUPLICATE: pid-file жив PID=$oldPid - выход pid=$me"; if ($mtx) { $mtx.ReleaseMutex() | Out-Null }; exit 0 }
  }
}
[IO.File]::WriteAllText($pidFile, [string]$me, (New-Object Text.UTF8Encoding $false))

$restartTimes = New-Object System.Collections.Generic.List[datetime]
$lastHb = [datetime]::MinValue
W "WATCHER START pid=$me"

while ($true) {
  $now = Get-Date
  # И-171.2: heartbeat-сталость - pid-file перезаписывается каждым циклом; если старше 180с - прошлый цикл застрял (CIM-висок) - self-restart с кодом 2
  try {
    if (Test-Path $pidFile) {
      $age = [int](($now - (Get-Item $pidFile).LastWriteTime).TotalSeconds)
      if ($age -gt 180) { W ("self-restart: heartbeat stale (pid-file " + $age + "s) - выход с кодом 2"); if ($mtx) { $mtx.ReleaseMutex() | Out-Null }; exit 2 }
    }
  } catch { }
  if (($now - $lastHb).TotalMinutes -ge 60) {
    $dp = Find-Daemon
    W ("HEARTBEAT watcher=alive pid=" + $me + " daemon_pid=" + $(if ($dp) { $dp } else { 'DOWN' }))
    $lastHb = $now
  }
  $daemonPid = Find-Daemon
  if (-not $daemonPid) {
    $cutoff = $now.AddMinutes(-10)
    $restartTimes.RemoveAll({ param($t) $t -lt $cutoff })
    if ($restartTimes.Count -ge 3) {
      W ("ANTI-LOOP: " + $restartTimes.Count + " рестарта за 10 минут - сторож останавливается (pid=$me)")
      exit 1
    }
    W ("DAEMON DOWN причина=процесс-отсутствует pid_до=none - рестарт по И-103.3 (попытка " + ($restartTimes.Count + 1) + ")")
    # И-168.3.1: перезапуск с захватом вывода - причина падения фиксируется в лог
    $bootOut = Join-Path $logDir 'daemon-boot-out.txt'
    $bootErr = Join-Path $logDir 'daemon-boot-err.txt'
    $proc = $null
    try {
      $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','C:\kimi-work\wake-rail\scripts\nudge-scan.ps1' -RedirectStandardOutput $bootOut -RedirectStandardError $bootErr -PassThru
    } catch { W ("RESTART LAUNCH-ERR: " + $_.Exception.Message) }
    # И-168.3.1: терпение 15с (вместо 5с) - старт powershell под нагрузкой/AV-скан дольше 5с
    Start-Sleep 15
    $newPid = Find-Daemon
    if (-not $newPid) {
      # И-168.3.1: перепроверка через 5с до засчитывания неудачи (детект-глюк CommandLine)
      Start-Sleep 5
      $newPid = Find-Daemon
    }
    if ($newPid) { W ("RESTART OK pid_после=" + $newPid); $restartTimes.Add((Get-Date)) }
    else {
      $diag = ''
      if ($proc) { try { if ($proc.HasExited) { $diag = ' exit=' + $proc.ExitCode } } catch { } }
      foreach ($f in @($bootOut, $bootErr)) {
        if (Test-Path $f) {
          $tail = Get-Content $f -Tail 3 -Encoding UTF8 -ErrorAction SilentlyContinue
          if ($tail) { $diag += ' ' + (Split-Path $f -Leaf) + '="' + (($tail -join ' / ') -replace '\s+', ' ').Trim() + '"' }
        }
      }
      W ("RESTART FAILED: процесс не поднялся" + $diag)
      $restartTimes.Add((Get-Date))
    }
  }
  # И-171.3: pid-file перезаписывается каждым циклом - свежесть по чтению (сигнал зависания)
  try { [IO.File]::WriteAllText($pidFile, [string]$me, (New-Object Text.UTF8Encoding $false)) } catch { }
  # И-131.2: удержание ссылки на mutex от сборщика на длинной дистанции
  [GC]::KeepAlive($mtx)
  Start-Sleep 60
}
