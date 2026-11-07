#Requires -Version 5.1
param([switch]$Once)
$ErrorActionPreference = 'Continue'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$logDir = 'C:\kimi-work\wake-rail\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'watchdog-edge-cdp.log'
$instances = @(
    [ordered]@{ port = '9222'; profile = 'C:\kimi-work\wake-rail\cdp-profile'; url = 'https://www.kimi.ai/chat/1a171ebd-4a32-8926-8000-09502d436107?chat_enter_method=history' },
    [ordered]@{ port = '9223'; profile = 'C:\kimi-work\wake-rail\cdp-profile-b24'; url = 'https://www.kimi.ai/chat/1a1b4a1f-8dd2-8782-8000-0950f3b2e3ba?chat_enter_method=history' },
    [ordered]@{ port = '9224'; profile = 'C:\kimi-work\wake-rail\cdp-profile-chz'; url = 'https://www.kimi.ai/chat/1a1af74f-80e2-8207-8000-0950824703f5?chat_enter_method=history' }
)
function Write-Log([string]$message) {
    Add-Content -Path $logFile -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' | ' + $message) -Encoding UTF8
}
function Test-Cdp([string]$port) {
    try {
        $v = Invoke-RestMethod -UseBasicParsing -Uri ('http://127.0.0.1:' + $port + '/json/version') -TimeoutSec 3
        return [bool]$v.Browser
    } catch { return $false }
}
function Ensure-Instance($item) {
    $port = [string]$item.port
    if (Test-Cdp $port) { Write-Log ('OK port=' + $port); return }
    $root = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object {
        $_.CommandLine -match ('--remote-debugging-port=' + $port + '(\s|$)') -and $_.CommandLine -notmatch '--type='
    })
    if ($root.Count -gt 0) {
        Write-Log ('STALE-NO-KILL port=' + $port + ' pid=' + $root[0].ProcessId)
        return
    }
    Write-Log ('START-BEFORE port=' + $port + ' cdp=closed profile=' + $item.profile)
    Start-Process -FilePath $edge -ArgumentList @(
        '--remote-debugging-port=' + $port,
        '--user-data-dir=' + $item.profile,
        '--no-first-run',
        '--no-default-browser-check',
        $item.url
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
}
do {
    foreach ($item in $instances) { Ensure-Instance $item }
    if (-not $Once) { Start-Sleep -Seconds 30 }
} while (-not $Once)
