#Requires -Version 5.1
param([switch]$Once)
$ErrorActionPreference = 'Continue'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$logDir = 'C:\kimi-work\wake-rail\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'watchdog-edge-cdp.log'
$instances = @(
    [ordered]@{ port = '9222'; profile = 'C:\kimi-work\wake-rail\cdp-profile'; url = 'https://www.kimi.ai/chat/1a171ebd-4a32-8926-8000-09502d436107?chat_enter_method=history' }
)
$nextAttempt = @{}
$backoffSec = @{}
function Write-Log([string]$message) {
    Add-Content -Path $logFile -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' | ' + $message) -Encoding UTF8
}
function Test-Cdp([string]$port) {
    try {
        $v = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/version') -TimeoutSec 3
        return [bool]$v.Browser
    } catch { return $false }
}
function New-ChatTarget([string]$port, [string]$url) {
    $ver = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/version') -TimeoutSec 5
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object Threading.CancellationTokenSource(10000)
    try {
        $ws.ConnectAsync([Uri]$ver.webSocketDebuggerUrl, $cts.Token).Wait()
        $msg = @{ id = 1; method = 'Target.createTarget'; params = @{ url = $url } } | ConvertTo-Json -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $ws.SendAsync((New-Object ArraySegment[byte] -ArgumentList @(,$bytes)), [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
        $buf = New-Object byte[] 65536
        $ms = New-Object IO.MemoryStream
        do {
            $res = $ws.ReceiveAsync((New-Object ArraySegment[byte] -ArgumentList @(,$buf)), $cts.Token).Result
            $ms.Write($buf, 0, $res.Count)
        } while (-not $res.EndOfMessage)
        $answer = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($ms.ToArray()))
        if (-not $answer.result.targetId) { throw 'Target.createTarget returned no targetId' }
        return [string]$answer.result.targetId
    } finally {
        $ws.Dispose()
        $cts.Dispose()
    }
}
function Ensure-Instance($item) {
    $port = [string]$item.port
    if (Test-Cdp $port) {
        $backoffSec[$port] = 0
        $nextAttempt[$port] = [datetime]::MinValue
        Write-Log ('OK port=' + $port)
        return
    }
    $root = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object {
        $_.CommandLine -match ('--remote-debugging-port=' + $port + '(\s|$)') -and $_.CommandLine -notmatch '--type='
    })
    if ($root.Count -gt 0) {
        Write-Log ('STALE-NO-KILL port=' + $port + ' pid=' + $root[0].ProcessId)
        return
    }
    $now = Get-Date
    if ($nextAttempt.ContainsKey($port) -and $now -lt $nextAttempt[$port]) {
        Write-Log ('BACKOFF port=' + $port + ' retry_in_sec=' + [int]($nextAttempt[$port] - $now).TotalSeconds)
        return
    }
    Write-Log ('START-BEFORE port=' + $port + ' cdp=closed process=absent profile=' + $item.profile)
    Start-Process -FilePath $edge -ArgumentList @(
        '--remote-debugging-port=' + $port,
        '--user-data-dir=' + $item.profile,
        '--no-first-run',
        '--no-default-browser-check',
        '--start-minimized',
        'about:blank'
    )
    $up = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Cdp $port) { $up = $true; break }
    }
    $rootAfter = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object {
        $_.CommandLine -match ('--remote-debugging-port=' + $port + '(\s|$)') -and $_.CommandLine -notmatch '--type='
    })
    $pidText = if ($rootAfter.Count -gt 0) { [string]$rootAfter[0].ProcessId } else { 'none' }
    Write-Log ('START-AFTER port=' + $port + ' cdp=' + $(if ($up) { 'open' } else { 'closed' }) + ' pid=' + $pidText)
    if ($up) {
        $backoffSec[$port] = 0
        $nextAttempt[$port] = [datetime]::MinValue
        try {
            $targetId = New-ChatTarget $port ([string]$item.url)
            Write-Log ('CHAT-TARGET port=' + $port + ' target=' + $targetId + ' url=' + $item.url)
        } catch {
            Write-Log ('CHAT-TARGET-ERR port=' + $port + ' error=' + $_.Exception.Message)
        }
    } else {
        $previous = if ($backoffSec.ContainsKey($port)) { [int]$backoffSec[$port] } else { 0 }
        $delay = if ($previous -le 0) { 30 } else { [Math]::Min(300, $previous * 2) }
        $backoffSec[$port] = $delay
        $nextAttempt[$port] = (Get-Date).AddSeconds($delay)
        Write-Log ('START-BACKOFF port=' + $port + ' delay_sec=' + $delay)
    }
}
do {
    foreach ($item in $instances) { Ensure-Instance $item }
    if (-not $Once) { Start-Sleep -Seconds 30 }
} while (-not $Once)
