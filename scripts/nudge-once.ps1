# И-95.1: nudge-once.ps1 v3 — одноразовый адресный толчок сессий (single-shot nudge).
# Протокол: PRE -> reload(опц.) -> CHECK-IDLE -> PRECLEAR -> SNAPSHOT A/MSGS-A
#           -> composer '1' -> нормализация пробелов -> ОДИН клик -> MSGS-C -> CONFIRM -> CLEANUP.
# Гарды: существующая вкладка по заголовку (без createTarget); ОДНА отправка максимум;
# при неопределённости — стоп без повтора; испытания только на одноразовом тестовом чате; КК не трогаем.
param(
  [Parameter(Mandatory = $true)][string]$To,
  [int]$ReadyTimeoutSec = 40,
  [switch]$Reload,
  [int]$DelaySec = 0
)
$CdpPort = '9222'
# reload по умолчанию ВЫКЛЮЧЕН: 16.10 чат «Тест» — дважды Page.reload убил renderer
# (прогон 1: CHECK-IDLE 40 с тишины; прогон 2: WS ReceiveAsync умер на 90 с).
# -Reload включает штатный reload; скрипт FAIL-SAFE при краше (TAB-CRASH detect).
# -DelaySec <N> — пауза перед стартом протокола (связка с продлением сессий).
$ErrorActionPreference = 'Continue'
$logDir = 'C:\kimi-work\wake-rail\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ('nudge-once-' + (Get-Date -Format 'yyyyMMdd') + '.log')
function L([string]$s) { $line = (Get-Date -Format 'HH:mm:ss') + ' | ' + $s; Add-Content -Path $logFile -Value $line -Encoding UTF8; Write-Output $line }

L ("=== NUDGE-ONCE v3 start | To=[" + $To + "] | Reload=" + $Reload + " | DelaySec=" + $DelaySec + " ===")
if (-not $To) { L 'ERROR: -To пуст'; exit 2 }

try {
  $ver = Invoke-RestMethod -UseBasicParsing -Uri ("http://127.0.0.1:" + $CdpPort + "/json/version") -TimeoutSec 10
  L ("PRE: port-open yes | Browser=" + $ver.Browser)
} catch {
  L ("ERROR: CDP port closed | " + $_.Exception.Message); exit 2
}
if ($DelaySec -gt 0) { L ("DELAY: " + $DelaySec + " s"); Start-Sleep -Seconds $DelaySec }

Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = 20MB
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$cts = New-Object Threading.CancellationTokenSource(90000)

try {
  $ws.ConnectAsync([Uri]$ver.webSocketDebuggerUrl, $cts.Token).Wait()
  $script:mid = 0
  function Send-Cmd([string]$method, [hashtable]$prm, [string]$sessionId, [int]$TimeoutSec = 20) {
    $script:mid++
    $msg = @{ id = $script:mid; method = $method; params = $prm }
    if ($sessionId) { $msg.sessionId = $sessionId }
    $bytes = [Text.Encoding]::UTF8.GetBytes($ser.Serialize($msg))
    $seg = New-Object ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).Wait()
    $buf = New-Object byte[] 1048576
    $swT = [Diagnostics.Stopwatch]::StartNew()
    while ($swT.Elapsed.TotalSeconds -lt $TimeoutSec) {
      $ms = New-Object IO.MemoryStream
      $innerSw = [Diagnostics.Stopwatch]::StartNew()
      while ($innerSw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $rseg = New-Object ArraySegment[byte] -ArgumentList @(,$buf)
        $res = $ws.ReceiveAsync($rseg, $cts.Token).Result
        $ms.Write($buf, 0, $res.Count)
        if ($res.EndOfMessage) { break }
      }
      $obj = $ser.DeserializeObject([Text.Encoding]::UTF8.GetString($ms.ToArray()))
      if ($obj -and $obj.ContainsKey('id') -and $obj['id'] -eq $script:mid) { return $obj }
    }
    throw ('Send-Cmd таймаут ' + $TimeoutSec + ' с: ' + $method)
  }
  function Eval([string]$expr, [string]$sessionId) {
    $r = Send-Cmd 'Runtime.evaluate' @{ expression = $expr; returnByValue = $true } $sessionId
    return $r.result.result.value
  }

  # --- вкладка ТОЛЬКО существующая, по заголовку ---
  $tabs = Invoke-RestMethod -UseBasicParsing -Uri ("http://127.0.0.1:" + $CdpPort + "/json/list") -TimeoutSec 10
  $tab = $null
  foreach ($t in $tabs) { if ($t.type -eq 'page' -and $t.title -and $t.title.IndexOf($To, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $tab = $t; break } }
  if (-not $tab) { L ("ERROR: вкладка не найдена [" + $To + "] — createTarget запрещён"); exit 2 }
  L ("TAB: [" + $tab.title + "] url=" + $tab.url)
  $att = Send-Cmd 'Target.attachToTarget' @{ targetId = $tab.id; flatten = $true } $null
  $sid = $att.result.sessionId
  L 'BACKGROUND: tab activation not requested'
  [void](Send-Cmd 'Page.enable' @{} $sid)
  [void](Send-Cmd 'Runtime.enable' @{} $sid)
  if ($Reload) { L 'RELOAD: штатный (-Reload)'; [void](Send-Cmd 'Page.reload' @{ ignoreCache = $false } $sid) }
  else { L 'RELOAD: пропущен (по умолчанию; краш-доказательства в шапке файла)' }

  # --- CHECK-IDLE: readyState + редактор жив + НЕТ генерации/редактора ---
  $deadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
  $ready = $false; $errStreak = 0
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    try {
      $st = Eval "document.readyState === 'complete' && document.querySelector('.chat-input-editor') !== null" $sid
      $busy = Eval "document.querySelector('.send-button-container') !== null && !document.querySelector('.send-button-container').className.toString().match(/stop|gener/i)" $sid
      $errStreak = 0
    } catch {
      $errStreak++
      if ($errStreak -ge 5) { L ("ERROR: TAB-CRASH suspect (" + $errStreak + " подряд)"); exit 2 }
      continue
    }
    if ($st -eq 'True' -and ($busy -eq $false -or $busy -eq 'False')) { $ready = $true; L 'CHECK-IDLE: ready'; break }
    if ($busy -eq 'True') { L 'CHECK-IDLE: ожидание (генерация/редактор)' }
  }
  if (-not $ready) { L 'ERROR: CHECK-IDLE таймаут'; exit 2 }
  Start-Sleep -Seconds 3

  # --- PRECLEAR: чистый композер (Backspace-цикл + cut-fallback) ---
  $pre = ''
  for ($k = 0; $k -lt 4; $k++) {
    $pre = Eval "(function(){ var ed = document.querySelector('.chat-input-editor'); if (!ed) return 'NO-EDITOR'; ed.focus(); var s2 = getSelection(); var r2 = document.createRange(); r2.selectNodeContents(ed); s2.removeAllRanges(); s2.addRange(r2); document.execCommand('cut'); } return JSON.stringify({after: ed.innerText, keys: n}); })()" $sid
    if ($pre -match '\"after\":\"\"') { break }
    Start-Sleep -Milliseconds 500
  }
  L ("PRECLEAR: " + $pre)
    $preF = Eval "(function(){ var ed=document.querySelector('.chat-input-editor'); if(!ed) return 'NO-EDITOR'; ed.focus(); var s=window.getSelection(); var r=document.createRange(); r.selectNodeContents(ed); s.removeAllRanges(); s.addRange(r); document.execCommand('delete'); ed.dispatchEvent(new Event('input',{bubbles:true})); return JSON.stringify({after:(ed.innerText||'').trim()}); })()" $sid
    [void](Eval "(function(){ var ed=document.querySelector('.chat-input-editor'); if(ed){ed.focus();} return 'F'; })()" $sid)
    Start-Sleep -Milliseconds 400
    [void](Send-Cmd 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'a'; code = 'KeyA'; windowsVirtualKeyCode = 65; nativeVirtualKeyCode = 65; modifiers = 2 } $sid)
    [void](Send-Cmd 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'a'; code = 'KeyA'; windowsVirtualKeyCode = 65; nativeVirtualKeyCode = 65; modifiers = 2 } $sid)
    [void](Send-Cmd 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Backspace'; code = 'Backspace'; windowsVirtualKeyCode = 8; nativeVirtualKeyCode = 8 } $sid)
    [void](Send-Cmd 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Backspace'; code = 'Backspace'; windowsVirtualKeyCode = 8; nativeVirtualKeyCode = 8 } $sid)
    Start-Sleep -Milliseconds 600
    $preF = Eval "(function(){ var ed=document.querySelector('.chat-input-editor'); return JSON.stringify({after:(ed&&ed.innerText||'').trim()}); })()" $sid
    L ("PRECLEAR-FORCE: " + $preF)

  # --- И-150: диагностический журнал (серия толчков) ---
  $diagLog = Join-Path $logDir ('i150-diag-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
  function DL([string]$s) { $line = (Get-Date -Format 'HH:mm:ss.fff') + ' | ' + $s; Add-Content -Path $diagLog -Value $line -Encoding UTF8; L ('И-150-DIAG: ' + $s) }

  # --- SNAPSHOT A + MSGS A ---
  $snapExpr = "(function(){ var t = document.body ? document.body.innerText : ''; var ind = []; ['1/2','2/2','Switched to','вариант','question 2'].forEach(function(x){ if (t.indexOf(x) >= 0) ind.push(x); }); var ed = document.querySelector('.chat-input-editor'); var btn = document.querySelector('.send-button-container'); return JSON.stringify({indicators: ind, editor: ed ? ed.innerText : null, btnCls: btn ? btn.className : null, title: document.title}); })()"
  $msgExpr = "JSON.stringify(Array.from(document.querySelectorAll('.segment-user')).map(function(e){return (e.innerText||'').split('\n')[0].trim().slice(0,70)}))"
  $msgA = Eval $msgExpr $sid
  $snapA = Eval $snapExpr $sid
  L ("SNAPSHOT-A: " + $snapA)
  L ("MSGS-A: " + $msgA)

    # --- И-95.2 v3: запрет SEND при активности в чате (двойной снимок ленты) ---
  # Маркеры веток (1/2, 2/2, Switched to) статичны — историю от активности не отличить.
  # Гонка детектится фактом: лента сообщений изменилась за окно наблюдения 3 с.
  $m1 = Eval $msgExpr $sid
  Start-Sleep -Seconds 3
  $m2 = Eval $msgExpr $sid
  if ($m1 -and $m2 -and ($m1 -ne $m2)) {
    L ("NO-SEND: активность в чате за 3 с — отправка запрещена, cleanup и стоп")
    [void](Eval "(function(){ var ed = document.querySelector('.chat-input-editor'); if (!ed) return 'NO-EDITOR'; ed.focus(); var r = document.createRange(); r.selectNodeContents(ed); r.deleteContents(); return 'CLEAN'; })()" $sid)
    exit 3
  }

  # --- COMPOSER: '1' ---
  $edBefore = Eval "(function(){ var ed = document.querySelector('.chat-input-editor'); return ed ? JSON.stringify({text: ed.innerText}) : 'NO-EDITOR'; })()" $sid
  DL ('COMPOSER-BEFORE: ' + $edBefore)
  $ins = Eval "(function(){ var ed = document.querySelector('.chat-input-editor'); if (!ed) return 'NO-EDITOR'; ed.focus(); var ok = document.execCommand('insertText', false, '1'); return ok ? 'INSERTED' : 'INSERT-FAIL'; })()" $sid
  Start-Sleep -Milliseconds 400
  $edNow = Eval "(function(){ var ed = document.querySelector('.chat-input-editor'); return ed ? JSON.stringify({text: ed.innerText}) : 'NO-EDITOR'; })()" $sid
  DL ('COMPOSER-AFTER-0.4s: ' + $edNow)
  Start-Sleep -Milliseconds 600
  $edNow2 = Eval "(function(){ var ed = document.querySelector('.chat-input-editor'); return ed ? JSON.stringify({text: ed.innerText}) : 'NO-EDITOR'; })()" $sid
  DL ('COMPOSER-AFTER-1.0s: ' + $edNow2)
  $edNow = $edNow2
  L ("COMPOSER: " + $ins + " | editor=" + $edNow)

  # --- SEND: один клик, только если нормализованное поле ровно '1' ---
  $sent = $false
  $edNorm = $null
  try { $edNorm = ((($edNow | ConvertFrom-Json).text) -replace '\s+', '') } catch { $edNorm = $null }
  if ($edNorm -eq '1') {
    $btnBefore = Eval "(function(){ var b = document.querySelector('.send-button-container'); return b ? b.className : 'NO-BTN'; })()" $sid
    DL ('SEND-BTN-BEFORE: ' + $btnBefore)
    $clickRes = Eval "(function(){ var b = document.querySelector('.send-button-container'); if (!b) return 'NO-BTN'; if (b.className.indexOf('disabled') >= 0) return 'DISABLED'; b.click(); return 'CLICKED'; })()" $sid
    L ('SEND: button=' + $clickRes + ' (click-replace)')
    $sent = ($clickRes -eq 'CLICKED')
    Start-Sleep -Seconds 4
    $btnAfter = Eval "(function(){ var b = document.querySelector('.send-button-container'); return b ? b.className : 'NO-BTN'; })()" $sid
    DL ('SEND-BTN-AFTER: ' + $btnAfter)
    Start-Sleep -Seconds 5
  } else {
    L ('SEND: ПРОПУЩЕНО — поле не ровно 1 (после trim: [' + $edNorm + '], стоп без повтора)')
  }
  $msgC = Eval $msgExpr $sid
  $snapB = Eval $snapExpr $sid
  L ("MSGS-C: " + $msgC)
  L ("SNAPSHOT-B: " + $snapB)

  # --- CONFIRM ---
  $a = $ser.DeserializeObject($snapA); $b = $ser.DeserializeObject($snapB)
  $ma = $ser.DeserializeObject($msgA); $mc = $ser.DeserializeObject($msgC)
  $verdict = @()
  if ($edNorm -eq '1') { $verdict += 'COMPOSER-1:PASS' } else { $verdict += 'COMPOSER-1:FAIL' }
  if (($a['indicators'] -join ',') -eq ($b['indicators'] -join ',')) { $verdict += 'BRANCH-UNCHANGED:PASS' } else { $verdict += 'BRANCH-UNCHANGED:FAIL' }
  if (($a['indicators'] -contains '1/2') -eq ($b['indicators'] -contains '1/2')) { $verdict += 'NO-1/2-TOGGLE:PASS' } else { $verdict += 'NO-1/2-TOGGLE:FAIL' }
  if ($sent) {
    if ([int]$mc.Count -gt [int]$ma.Count -and (($mc[$mc.Count - 1] -replace '\s+', '') -eq '1')) { $verdict += 'SENT-NEW-MSG:PASS' } else { $verdict += 'SENT-NEW-MSG:FAIL' }
  } else {
    $verdict += 'SENT-NEW-MSG:SKIP'
  }
  DL ('CONFIRM-VERDICTS: ' + ($verdict -join ' | '))
  L ("CONFIRM: " + ($verdict -join ' | '))
  $res = 'FAILED'
  if (-not $sent) { $res = 'SKIP-NOSEND' }
  elseif ([int]$mc.Count -gt [int]$ma.Count) { $res = 'DELIVERED' }
  # И-150: COMPOSER/SENT-вердикты — только комментарий; истина — msgsC>msgsA
  $composerNote = ($verdict | Where-Object { $_ -match 'COMPOSER|SENT' }) -join ','
  L ("RESULT=" + $res + " | msgsA=" + $ma.Count + " msgsC=" + $mc.Count + " | composer-comment: " + $composerNote)

  # --- CLEANUP ---
  $clr = ''
  for ($k2 = 0; $k2 -lt 4; $k2++) {
    $clr = Eval "(function(){ var ed = document.querySelector('.chat-input-editor'); if (!ed) return 'NO-EDITOR'; ed.focus(); var s3 = getSelection(); var r3 = document.createRange(); r3.selectNodeContents(ed); s3.removeAllRanges(); s3.addRange(r3); document.execCommand('cut'); } return JSON.stringify({after: ed.innerText, keys: n}); })()" $sid
    if ($clr -match '\"after\":\"\"') { break }
    Start-Sleep -Milliseconds 500
  }
  L ("CLEANUP: " + $clr)
  L '=== NUDGE-ONCE v3 end ==='
  exit 0
} catch {
  L ("CDP-ERROR: " + $_.Exception.Message)
  exit 2
}
