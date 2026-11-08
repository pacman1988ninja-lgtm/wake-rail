#И-98: nudge-scan.ps1 - автопродление сессий по триггеру "Стоп по бюджету".
# Цикл: все page-вкладки одного окна CDP 9222.
# Триггер: 'Стоп по бюджету', маркер не обработан. Один маркер = один адресат.
# Действие: отдельный nudge-once.ps1 на порту контура; bringToFront + insertText + клик,
# RESULT=DELIVERED только по росту пользовательских сообщений.
# И-101 (16.10): через фильтр проходят только чат-вкладки (kimi.ai/chat или title " - Kimi");
# вкладка-ловушка не останавливает цикл; каждый WS-вызов - с таймаутом ~20 с.
# И-103 (17.10): детектор читает последний .segment-assistant (ассистент пишет
# стоп-префикс); добавлены -DetectOnly (сухой прогон) и -Once (один цикл).
# Дедуп: маркер-файл state\nudge-scan.markers.json (вкладка -> fp/first/processed);
# сброс маркера, когда стоп исчез. Гарды: вкладки без стопа не трогаем; индикаторы
# ветвления -> пропуск; BOM обязателен; без createTarget; КК нет. Самотолчок НЕ взводит.
# И-143 (18.10): детекторы "постановка" и "вердикт" - пуши председателю о новых постановках
# и подписаниях. Тот же прогон и залы, что сдача (И-104.2), свои state-файлы
# (nudge-scan.postanovka.json / nudge-scan.verdict.json); since = момент деплоя -
# бэклог не догоняем. UID budilnik-postanovka-/budilnik-verdict-<comment_id>.
param(
  [int]$PollSec = 45,
  [int]$StopTtlSec = 1800,  # И-129: порог "просрочен" >= 30 мин от первого детекта (было 900 с)
  [switch]$DetectOnly,  # И-103: сухой прогон - только детект и лог
  [switch]$Once        # И-103: один цикл и выход (для теста)
)
$ErrorActionPreference = 'Continue'
$logDir = 'C:\kimi-work\wake-rail\logs'
$stateDir = 'C:\kimi-work\wake-rail\state'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
# И-128: имя лога вычисляется на КАЖДУЮ запись (L) - ротация по дате без рестарта демона.
# Get-ScanLogFile с параметром [datetime] - для проверок с имитацией даты.
function Get-ScanLogFile([datetime]$d = (Get-Date)) { Join-Path $logDir ('nudge-scan-' + $d.ToString('yyyyMMdd') + '.log') }
$logFile = Get-ScanLogFile
$markerFile = Join-Path $stateDir 'nudge-scan.markers.json'
function L([string]$s) { $line = (Get-Date -Format 'HH:mm:ss') + ' | ' + $s; Add-Content -Path (Get-ScanLogFile) -Value $line -Encoding UTF8 }
$markers = @{}
if (Test-Path $markerFile) { try { $markers = ConvertFrom-Json ([IO.File]::ReadAllText($markerFile)) -AsHashtable } catch { $markers = @{} } }
function Save-Markers { [IO.File]::WriteAllText($markerFile, ($markers | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false))) }
function Get-CdpTabs {
  try {
    $items = Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:9222/json/list' -TimeoutSec 10
    foreach ($item in @($items)) { $item | Add-Member -NotePropertyName 'cdp_port' -NotePropertyValue '9222' -Force }
    return @($items)
  } catch { L ('CDP-ERR port=9222 ' + $_.Exception.Message); return @() }
}
# === И-104.2: детект сдачи (перенос из budilnik-sessii.ps1; тик 2 мин -> цикл демона 45-65 с) ===
# Функции Get-SdachaDem/Send-SdachaPutDem/Send-SdachaCommentDem - точные копии боевых
# будильника (И-6/И-9/И-11), UID budilnik-sdacha-<id> сохранён (идемпотентность, автоочистка И-10).
# Фильтр: 'сдан|сдача|отч[её]т' + ОТ .../Исполнитель/... + номер (боевой фильтр И-104.1).
# Дедуп: отдельный state nudge-scan.sdacha.json (pushed по comment_id; будильник не трогаем).
$budConfigPath   = 'C:\kimi-config\budilnik.config.json'
$sdachaCcfgPath  = 'C:\kimi-config\budilnik.caldav.json'
$sdachaStatePath = Join-Path $stateDir 'nudge-scan.sdacha.json'

function Read-SdachaState {
    if (Test-Path $sdachaStatePath) {
        try { return (Get-Content $sdachaStatePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    $st = [pscustomobject]@{ since = (Get-Date).ToUniversalTime().AddMinutes(-10).ToString('o'); pushed = @() }
    Save-SdachaState $st
    return $st
}
function Save-SdachaState([object]$St) {
    $tmp = $sdachaStatePath + '.tmp'
    ($St | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $sdachaStatePath -Force
}

function Get-SdachaDem {
    param([string]$Body)
    if ($Body -notmatch 'сдан|сдача|отч[её]т') { return $null }
    $mWho = [regex]::Match($Body, 'ОТ:\s*(\S+(?:/\S+)+)\s+/\s+КОМУ')
    if (-not $mWho.Success) { return $null }
    $who = $mWho.Groups[1].Value.Trim()
    if ($who -notmatch '/Исполнитель/') { return $null }
    $mOrd = [regex]::Match($Body, 'И-(\d+(?:\.\d+)?)')
    if ($mOrd.Success) { $ord = 'И-' + $mOrd.Groups[1].Value }
    else {
        $mOrd = [regex]::Match($Body, '№\s*(\d+(?:\.\d+)?)')
        if (-not $mOrd.Success) { return $null }
        $ord = $mOrd.Groups[1].Value
    }
    [pscustomobject]@{ Order = $ord; Who = $who }
}

function Send-SdachaPutDem {
    param([object]$CaldavCfg, [string]$Order, [string]$Who, [string]$CommentId)
    $uid   = 'budilnik-sdacha-' + $CommentId
    $start = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('yyyyMMddTHHmmssZ')
    $text  = '{0} / сдан / {1}' -f $Order, $Who
    $ics   = "BEGIN:VCALENDAR`r`nVERSION:2.0`r`nPRODID:-//budilnik-sessii//SDACHA//RU`r`nBEGIN:VEVENT`r`nUID:$uid`r`nDTSTART:$start`r`nSUMMARY:$text`r`nDESCRIPTION:$text`r`nEND:VEVENT`r`nEND:VCALENDAR"
    $cred  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f $CaldavCfg.caldavLogin, $CaldavCfg.caldavPassword)))
    $uri   = '{0}/{1}.ics' -f ([string]$CaldavCfg.calendarUrl).TrimEnd('/'), $uid
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Authorization', "Basic $cred")
            $wc.Headers.Add('Content-Type', 'text/calendar; charset=utf-8')
            try { $wc.UploadData($uri, 'PUT', [Text.Encoding]::UTF8.GetBytes($ics)) | Out-Null } finally { $wc.Dispose() }
            return
        } catch {
            $code = 0
            try { $code = [int]([System.Net.WebException]$_.Exception).Response.StatusCode } catch { }
            if ($attempt -lt 3 -and $code -ge 500) { Start-Sleep -Seconds 2; continue }
            throw
        }
    }
}

function Send-SdachaCommentDem {
    param([object]$CaldavCfg, [object]$Cfg, [string]$Repo, [int]$Issue)
    $cbody = 'пуш отправлен {0:HH:mm}' -f (Get-Date)
    $curi  = 'https://api.github.com/repos/{0}/{1}/issues/{2}/comments' -f $Cfg.githubOrg, $Repo, $Issue
    $ghTok = [string]$CaldavCfg.githubToken
    if (-not $ghTok) { $ghTok = [string]$Cfg.githubToken }
    Invoke-RestMethod -Uri $curi -Method Post -Headers @{
        Authorization = "token $ghTok"
        Accept        = 'application/vnd.github+json'
        'User-Agent'  = 'nudge-scan-sdacha'
    } -Body ([Text.Encoding]::UTF8.GetBytes((@{ body = $cbody } | ConvertTo-Json))) -ContentType 'application/json; charset=utf-8' -TimeoutSec 30
}

# === И-143: детекторы "постановка"/"вердикт" - общие функции состояния и push ===
function Read-KindState([string]$Path) {
    if (Test-Path $Path) { try { return (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    $st = [pscustomobject]@{ since = (Get-Date).ToUniversalTime().ToString('o'); pushed = @() }
    Save-KindState $Path $st
    return $st
}
function Save-KindState([string]$Path, [object]$St) {
    $tmp = $Path + '.tmp'
    ($St | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $Path -Force
}
function Get-VerdictDem([string]$Body) {
    # И-143.2: канон вердикта без шапки ОТ/КОМУ; актор из тега '[… | вердикт | И-N]'
    if ($Body -notmatch 'ВЕРДИКТ:') { return $null }
    if ($Body -notmatch 'ПОДПИСАН') { return $null }
    $who = 'контролёр контура'
    $mTag = [regex]::Match($Body, '\[\s*([^\]|]+?)\s*\|\s*вердикт\s*\|\s*(И-\d+(?:\.\d+)?)')
    $ord = $null
    if ($mTag.Success) { $who = $mTag.Groups[1].Value.Trim(); $ord = $mTag.Groups[2].Value }
    else {
        $mWho = [regex]::Match($Body, 'Кими/[^\s\]]+/Контролёр')
        if ($mWho.Success) { $who = $mWho.Value }
        $mOrd = [regex]::Match($Body, 'И-(\d+(?:\.\d+)?)')
        if ($mOrd.Success) { $ord = 'И-' + $mOrd.Groups[1].Value }
    }
    if (-not $ord) { return $null }
    [pscustomobject]@{ Order = $ord; Who = $who }
}
function Get-PostanovkaDem([string]$Body) {
    # И-143.2: разводка по маркерам: вердикт = 'ВЕРДИКТ:' + 'ПОДПИСАН' (той же строкой), постановка = 'Постановлено:' + 'Тема:' + 'КОМУ:'
    if ($Body -notmatch 'Постановлено:') { return $null }
    if ($Body -notmatch 'Тема:') { return $null }
    if ($Body -notmatch 'КОМУ:') { return $null }
    $mV = [regex]::Match($Body, 'ВЕРДИКТ:')
    if ($mV.Success -and $Body.Substring($mV.Index, [Math]::Min(200, $Body.Length - $mV.Index)) -match 'ПОДПИСАН') { return $null }
    $mWho = [regex]::Match($Body, 'КОМУ:\s*(\S+(?:/\S+)+)')
    if (-not $mWho.Success) { return $null }
    $mOrd = [regex]::Match($Body, 'Тема:\s*И-(\d+(?:\.\d+)?)')
    if (-not $mOrd.Success) { $mOrd = [regex]::Match($Body, 'И-(\d+(?:\.\d+)?)') }
    if (-not $mOrd.Success) { return $null }
    [pscustomobject]@{ Order = 'И-' + $mOrd.Groups[1].Value; Who = $mWho.Groups[1].Value.Trim() }
}
function Send-KindPushDem {
    param([object]$CaldavCfg, [string]$Kind, [string]$Text, [string]$CommentId)
    $uid   = 'budilnik-' + $Kind + '-' + $CommentId
    $start = (Get-Date).ToUniversalTime().AddMinutes(1).ToString('yyyyMMddTHHmmssZ')
    $ics   = "BEGIN:VCALENDAR`r`nVERSION:2.0`r`nPRODID:-//budilnik-sessii//KIND//RU`r`nBEGIN:VEVENT`r`nUID:$uid`r`nDTSTART:$start`r`nSUMMARY:$Text`r`nDESCRIPTION:$Text`r`nEND:VEVENT`r`nEND:VCALENDAR"
    $cred  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(('{0}:{1}' -f $CaldavCfg.caldavLogin, $CaldavCfg.caldavPassword)))
    $uri   = '{0}/{1}.ics' -f ([string]$CaldavCfg.calendarUrl).TrimEnd('/'), $uid
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('Authorization', "Basic $cred")
            $wc.Headers.Add('Content-Type', 'text/calendar; charset=utf-8')
            try { $wc.UploadData($uri, 'PUT', [Text.Encoding]::UTF8.GetBytes($ics)) | Out-Null } finally { $wc.Dispose() }
            return
        } catch {
            $code = 0
            try { $code = [int]([System.Net.WebException]$_.Exception).Response.StatusCode } catch { }
            if ($attempt -lt 3 -and $code -ge 500) { Start-Sleep -Seconds 2; continue }
            throw
        }
    }
}

# === И-138: пагинированное чтение зала (бюджет 5 страниц; HALL_TOO_LONG вместо молчания) ===
# === И-157: реестр триггеров вкладок из budilnik.config.json (ключ "triggers") ===
# Нет ключа/невалиден -> заморожено с логом (И-163). Записи независимы: ошибка одной -> TRIGGER-ERR <id>, остальные работают.
# Лог: "TRIGGER <id>: fp=... -> sent, verdict=..." / "TRIGGER <id>: skip(disabled)" / "TRIGGER-ERR <id>: ..."
$script:trigStateFile = Join-Path $stateDir 'nudge-scan.triggers-state.json'
function Read-TrigState {
    if (Test-Path $script:trigStateFile) { try { return (Get-Content $script:trigStateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { } }
    return [pscustomobject]@{}
}
function Save-TrigState([object]$St) {
    $tmp = $script:trigStateFile + '.tmp'
    ($St | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:trigStateFile -Force
}
function Get-TrigStateEntry([object]$St, [string]$Id) {
    $p = $St.PSObject.Properties[$Id]
    if ($p) { return $p.Value }
    return $null
}
function Set-TrigStateEntry([object]$St, [string]$Id, [object]$Val) {
    if ($St.PSObject.Properties[$Id]) { $St.$Id = $Val } else { $St | Add-Member -NotePropertyName $Id -NotePropertyValue $Val -Force }
}
$script:tmplRead = @'
(function(){
  var marker = "__PATTERN__";
  var payload = "__PAYLOAD__";
  var body = document.body.innerText || '';
  var idx = body.lastIndexOf(marker);
  if (idx < 0) return JSON.stringify({found:false});
  var before = body.substring(Math.max(0, idx-250), idx);
  var fp = 0; for (var i=0;i<before.length;i++){ fp = ((fp*31) + before.charCodeAt(i)) % 1000000007; }
  var after = body.substring(idx + marker.length);
  var afterTrim = after.replace(/^\s+/, '');
  var userTurn = document.querySelector('.segment-user, [class*="user-turn"], [class*="user-message"]');
  var hasUserAfter = false;
  if (userTurn) { var r = document.createRange(); r.selectNodeContents(userTurn); hasUserAfter = (r.comparePoint(document.body, idx + marker.length) === 1); }
  var userReplied = (!hasUserAfter) && afterTrim.indexOf(payload) === 0;
  return JSON.stringify({found:true, userReplied:userReplied, fp:String(fp), tail:afterTrim.substring(0,60)});
})()
'@
function Get-TrigExprs([bool]$IsPx, [string]$Payload) {
    if ($IsPx) {
        $ed = "(function(){ var eds = document.querySelectorAll('div[contenteditable=true]'); var ed = eds[eds.length-1]; return ed ? (ed.innerText || '').trim() : 'NO'; })()"
        $ins = "(function(){ var eds = document.querySelectorAll('div[contenteditable=true]'); var ed = eds[eds.length-1]; if (!ed) return 'NO-EDITOR'; ed.focus(); return document.execCommand('insertText', false, '__PAYLOAD__') ? 'INSERTED' : 'FAIL'; })()".Replace('__PAYLOAD__', $Payload)
    } else {
        $ed = "(function(){ var ed = document.querySelector('.chat-input-editor'); return ed ? (ed.innerText || '').trim() : 'NO'; })()"
        $ins = "(function(){ var ed = document.querySelector('.chat-input-editor'); if (!ed) return 'NO-EDITOR'; ed.focus(); return document.execCommand('insertText', false, '__PAYLOAD__') ? 'INSERTED' : 'FAIL'; })()".Replace('__PAYLOAD__', $Payload)
    }
    return @{ ed = $ed; ins = $ins }
}
# И-168.2/И-168.3: lastFire writer — детерминированная запись через node (БЕЗ ConvertTo-Json-пайплайна:
# конвейер PS 5.1 ConvertFrom-Json|ConvertTo-Json доказанно возвращает пустоту, см. инцидент 19.10 20:00:33).
# backup + атомарная замена + read-back. Вызывается ТОЛЬКО после реального fire (payload отправлен).
function Set-TriggerLastFire([string]$TrigId) {
  try {
    if (-not $TrigId) { return }
    $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $js = @'
const fs=require('fs');
const p='C:/kimi-config/budilnik.config.json';
const id=process.argv[1], ts=process.argv[2];
const c=JSON.parse(fs.readFileSync(p,'utf8').replace(/^\uFEFF/,''));
if(!c.triggers)c.triggers={};
if(!c.triggers[id]||typeof c.triggers[id]!=='object')c.triggers[id]={};
c.triggers[id].lastFire=ts;
const bak=p+'.bak-lf';
fs.copyFileSync(p,bak);
const tmp=p+'.tmp';
const prev=p+'.prev';
try{
  if(fs.existsSync(tmp))fs.rmSync(tmp);
  fs.writeFileSync(tmp,JSON.stringify(c,null,2),'utf8');
  if(fs.existsSync(prev))fs.rmSync(prev);
  fs.renameSync(p,prev);
  fs.renameSync(tmp,p);
  fs.rmSync(prev);
}catch(e){
  try{ if(fs.existsSync(bak)) fs.copyFileSync(bak,p); }catch(_){}
  throw e;
}
const rb=JSON.parse(fs.readFileSync(p,'utf8').replace(/^\uFEFF/,''));
process.stdout.write((rb.triggers&&rb.triggers[id]&&rb.triggers[id].lastFire===ts)?'OK':'READBACK-FAIL');
'@
    $out = [string](& node -e $js $TrigId $ts 2>$null)
    if ($out -eq 'OK') { L ('TRIGGER ' + $TrigId + ': lastFire=' + $ts + ' (read-back ок)') }
    else { L ('TRIGGER ' + $TrigId + ': lastFire WRITE-FAIL out="' + $out + '"') }
  } catch { L ('TRIGGER ' + $TrigId + ': lastFire ERR ' + $_.Exception.Message) }
}
function Invoke-TriggerRegistryDem([object]$BudCfg) {
    try {
        $trg = $null
        try { $trg = $BudCfg.triggers } catch { }
        if ($null -eq $trg -or -not ($trg -is [PSCustomObject])) { $trg = [pscustomobject]@{} }
        # И-168: stop-budget-auto — managed-запись (source of truth: budilnik.config.json)
        $sbRec = $null
        try { $sbRec = $budCfg.triggers.'stop-budget-auto' } catch { }
        if ($null -eq $sbRec) {
          $sbRec = [pscustomobject]@{ type = 'stop-budget'; tab = '*'; pattern = '(встроен)'; enabled = $true; managed = $true; action = [pscustomobject]@{ kind = 'nudge'; payload = '1' } }
          try {
            $budCfg.triggers | Add-Member -NotePropertyName 'stop-budget-auto' -NotePropertyValue $sbRec -Force
            [IO.File]::WriteAllText($budConfigPath, ($budCfg | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding -ArgumentList 1))
          } catch { }
        }
        $trg = $budCfg.triggers
        $sbGate = $budCfg.triggers.'stop-budget-auto'
        $sbNow = -not ($sbGate -and -not [bool]$sbGate.enabled)
        if ($script:lastSbState -ne $sbNow) {
            $script:lastSbState = $sbNow
            if ($sbNow) { L 'TRIGGER stop-budget-auto: enabled (автопродление включено)' } else { L 'TRIGGER stop-budget-auto: skip(disabled — автопродление выключено)' }
        }
        if (-not $sbNow) { return }
        if (@($trg.PSObject.Properties).Count -eq 0) {
            L 'TRIGGER: ключ triggers отсутствует или пуст — заморожено (И-163, без молчаливого legacy)'
            return
        }
        $tabsT = Get-CdpTabs
        $stT = Read-TrigState
        $changed = $false
        foreach ($prop in $trg.PSObject.Properties) {
            $id = [string]$prop.Name
            $rec = $prop.Value
            try {
                # И-168.3: disabled-молчание — лог только при СМЕНЕ состояния (не каждый цикл)
                $enNow = [bool]$rec.enabled
                $prevEn = $null
                try { $prevEn = [bool]$script:trigEnState[$id] } catch { }
                if (-not $enNow) {
                    if ($prevEn -ne $false) { $script:trigEnState[$id] = $false; L ('TRIGGER ' + $id + ': skip(disabled)') }
                    continue
                }
                if ($prevEn -ne $true) { $script:trigEnState[$id] = $true; L ('TRIGGER ' + $id + ': enabled') }
                $nfR = $false
                try { $nfR = [bool]$BudCfg.nightFreeze } catch { }
                if ($nfR) { $hhR = [int](Get-Date -Format 'HH'); if ($hhR -ge 0 -and $hhR -lt 7) { L ('TRIGGER ' + $id + ': nightFreeze пропуск'); continue } }
                $tabName = [string]$rec.tab
                # И-163.1: белый список — контент-матч только на разрешённых записях
                # И-168.1: stop-budget изъят из проверки белого списка (whitelist относится только к content-match)
                $wl = @('px-b24-yesno')
                $recType = [string]$rec.type
                if ($recType -eq 'content-match' -and $wl -notcontains $id) { L ('TRIGGER ' + $id + ': skip(вне белого списка И-163.1)'); continue }
                $pattern = [string]$rec.pattern
                $payload = [string]$rec.action.payload
                if (-not $payload) { $payload = '1' }
                $tTab = $null
                foreach ($tt in $tabsT) {
                    if (($tt.title + '') -eq $tabName -or ($tt.title + '') -eq ($tabName + ' - Kimi')) { $tTab = $tt; break }
                }
                if (-not $tTab) { continue }
                $isPx = (($tTab.url + '') -match 'perplexity\.ai')
                $readExpr = $script:tmplRead.Replace('__PATTERN__', $pattern).Replace('__PAYLOAD__', $payload)
                $wsT = New-Object System.Net.WebSockets.ClientWebSocket
                try {
                    $ctsT = New-Object Threading.CancellationTokenSource(15000)
                    try { $wsT.ConnectAsync([Uri]$tTab.webSocketDebuggerUrl, $ctsT.Token).Wait() } finally { $ctsT.Dispose() }
                    $script:mid = 0
                    $r = Eval $wsT $readExpr
                    if (-not $r) { continue }
                    $info = $r | ConvertFrom-Json
                    $cur = Get-TrigStateEntry $stT $id
                    if (-not $info.found) {
                        if ($cur -and [string]$cur.fp) { Set-TrigStateEntry $stT $id ([pscustomobject]@{ fp = ''; last_shot = '' }); $changed = $true; L ('TRIGGER ' + $id + ': промпт исчез, маркер сброшен') }
                        continue
                    }
                    if ($info.userReplied) {
                        if ($cur -and [string]$cur.fp) { Set-TrigStateEntry $stT $id ([pscustomobject]@{ fp = ''; last_shot = '' }); $changed = $true; L ('TRIGGER ' + $id + ': пользователь ответил, маркер сброшен') }
                        continue
                    }
                    $nowT = Get-Date
                    if ($cur -and [string]$cur.fp -eq [string]$info.fp) {
                        $ls = $null
                        try { $ls = [datetime]::Parse([string]$cur.last_shot) } catch { }
                        if ($ls -and (($nowT - $ls).TotalMinutes -lt 10)) { continue }
                    }
                    $verdict = 'FAILED'
                    $info2 = $null
                    if ($script:trigFirstPass) {
                      $verdict = 'STARTUP-SKIP'
                    } else {
                      $ex = Get-TrigExprs $isPx $payload
                      $ins = Eval $wsT $ex.ins
                      Start-Sleep -Milliseconds 600
                      [void](Send-CmdDem $wsT 'Input.dispatchKeyEvent' (@{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }))
                      [void](Send-CmdDem $wsT 'Input.dispatchKeyEvent' (@{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }))
                      Start-Sleep -Seconds 3
                      $edAfter = Eval $wsT $ex.ed
                      $r2 = Eval $wsT $readExpr
                      $info2 = $r2 | ConvertFrom-Json
                      if ($ins -eq 'INSERTED' -and $edAfter -eq '' -and $info2.userReplied) { $verdict = 'DELIVERED' }
                    }
                    Set-TrigStateEntry $stT $id ([pscustomobject]@{ fp = [string]$info.fp; last_shot = $nowT.ToString('o') })
                    $changed = $true
                    L ('TRIGGER ' + $id + ': fp=' + $info.fp + ' verdict=' + $verdict + $(if ($null -ne $info2) { ' (tail=' + $info2.tail + ')' } else { ' (И-214 startup-skip)' }))
                    Set-TriggerLastFire $id
                } finally { try { $wsT.Dispose() } catch { } }
            } catch { L ('TRIGGER-ERR ' + $id + ': ' + $_.Exception.Message) }
        }
        if ($changed) { Save-TrigState $stT }
        if ($script:trigFirstPass) { $script:trigFirstPass = $false; L 'И-214: первый проход триггеров завершён (обстрел подавлен), дальше обычный режим' }
    } catch { L ('TRIGGER-ERR registry: ' + $_.Exception.Message) }
}


function Send-ZalNoticeDem([string]$Text) {
  # И-169.7: финальное сообщение о самоотмене managed-стопа — в зал #14
  try {
    # токен читаем из файла конфига напрямую: $budCfg в scope fire-блока пуст (загружается только внутри цикла сдача-скана)
    $cfgN = $null
    try { $cfgN = Get-Content 'C:\kimi-config\budilnik.config.json' -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    $tok = [string]$cfgN.githubToken
    $org = [string]$cfgN.githubOrg
    if (-not $tok -or -not $org) { L 'И-169.7 ZAL-NOTICE: нет токена/org в конфиге'; return }
    $body = @{ body = $Text } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $org + '/Bistro24/issues/14/comments') -Headers @{ Authorization = 'token ' + $tok; 'User-Agent' = 'nudge-scan' } -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null
    L 'И-169.7 ZAL-NOTICE: отправлено в зал #14'
  } catch { L ('И-169.7 ZAL-NOTICE ERR: ' + $_.Exception.Message) }
}

function Get-HallComments {
    param([object]$Cnt, [string]$Since)
    $headers = @{ Authorization = "token $([string]$budCfg.githubToken)"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'nudge-scan-sdacha' }
    $all = @()
    $page = 1
    $tooLong = $false
    while ($true) {
        $uri = ('https://api.github.com/repos/' + $budCfg.githubOrg + '/' + [string]$Cnt.repo + '/issues/' + [int]$Cnt.issue + '/comments?per_page=100&page=' + $page + '&since=' + [uri]::EscapeDataString([string]$Since))
        $batch = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 30
        if ($null -eq $batch -or @($batch).Count -eq 0) { break }
        foreach ($cm in @($batch)) { $all += $cm }
        if (@($batch).Count -lt 100) { break }
        $page++
        if ($page -gt 5) { $tooLong = $true; break }
    }
    if ($tooLong) { L ('И-138 HALL_TOO_LONG: зал {0}/#{1}: больше 5 страниц за окно since' -f [string]$Cnt.repo, [int]$Cnt.issue) }
    return $all
}

# === И-166: CONFIG-GUARD — сторож budilnik.config.json ===
$script:lastSbState = $null
$script:trigEnState = @{}
$script:ManagedSeriesMode = $false  # И-172: серия N=3 ВЫКЛЮЧЕНА - один managed-толчок на стоп (код серии сохранён за флагом)
$script:quarCount = 0
$script:tripFired = $false
$script:cfgGuardBad = 0
$script:cfgGuardRestores = 0
$script:cfgGuardDayCount = 0
$script:cfgGuardDate = ''
function Invoke-ConfigGuard([string]$CfgPath) {
  $len = 0
  try { $len = (Get-Item $CfgPath -ErrorAction Stop).Length } catch { $len = 0 }
  $bad = ($len -lt 100)
  if (-not $bad) {
    try { Get-Content $CfgPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json | Out-Null } catch { $bad = $true }
  }
  if ($bad) {
    $script:cfgGuardBad++
    if ($script:cfgGuardBad -ge 2) {
      $bak = Get-ChildItem 'C:\kimi-config' -Filter 'budilnik.config.json.bak*' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($bak) {
        try {
          Copy-Item $bak.FullName $CfgPath -Force
          $v = Get-Content $CfgPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
          if (($v.githubToken.Length -gt 5) -and ($v.caldavPassword.Length -gt 5)) {
            $script:cfgGuardBad = 0
            $script:cfgGuardRestores++
            L ('CONFIG-GUARD restore ' + $bak.Name)
            $today = (Get-Date).ToString('yyyy-MM-dd')
            if ($script:cfgGuardDate -ne $today) { $script:cfgGuardDate = $today; $script:cfgGuardDayCount = 0 }
            $script:cfgGuardDayCount = [int]$script:cfgGuardDayCount + 1
            if ([int]$script:cfgGuardDayCount -ge 2) { L 'CONFIG-GUARD: 2+ восстановлений за сутки - требуется весть председателю' }
            return $true
          }
        } catch { L ('CONFIG-GUARD ERR ' + $_.Exception.Message) }
      }
    }
  } else {
    $script:cfgGuardBad = 0
  }
  return $false
}

function Invoke-SdachaScanDem {
    try {
        $ccfg = $null
        try { $ccfg = Get-Content $sdachaCcfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if ($null -eq $ccfg -or -not $ccfg.caldavLogin -or -not $ccfg.caldavPassword -or -not $ccfg.calendarUrl) { L 'И-104.2 СКАН: caldav-cfg нет - пропуск'; return }
        Invoke-ConfigGuard $budConfigPath | Out-Null
        $budCfg = $null
        try { $budCfg = Get-Content $budConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if ($null -eq $budCfg) { L 'И-104.2 СКАН: budilnik.config.json не читается - пропуск'; return }
        Invoke-TriggerRegistryDem $budCfg
        $st = Read-SdachaState
        $sinceDt = $null
        try { $sinceDt = [datetime]::Parse([string]$st.since, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $sinceDt = $null }
        $cmMap = @{}
        $allC = @()
        foreach ($cnt in @($budCfg.contours)) {
            try {
                $batchAll = Get-HallComments -Cnt $cnt -Since ([string]$st.since)
                foreach ($cm in @($batchAll)) { $cmMap[[string]$cm.id] = $cnt; $allC += $cm }
            } catch { L ('И-104.2 СКАН: чтение зала {0}/#{1}: {2}' -f [string]$cnt.repo, [int]$cnt.issue, $_.Exception.Message) }
        }
        $fresh = @()
        foreach ($cm in $allC) {
            if ($null -eq $sinceDt) { $fresh += $cm; continue }
            try {
                $ca = [datetime]::Parse([string]$cm.created_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ($ca -gt $sinceDt) { $fresh += $cm }
            } catch { }
        }
        $fresh = @($fresh | Sort-Object { [datetime]::Parse([string]$_.created_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) })
        L ('И-104.2 СКАН: комментариев={0} свежих={1} pushed={2}' -f @($allC).Count, @($fresh).Count, @($st.pushed).Count)
        $sdSeen = 0
        foreach ($cm in $fresh) {
            $cid = [string]$cm.id
            if (@($st.pushed) -contains $cid) { continue }
            $sd = Get-SdachaDem ([string]$cm.body)
            if (-not $sd) { continue }
            $sdSeen++
            if (-not $sd.Order -or -not $sd.Who) { L ('И-104.2 СКАН: parse fail: {0}' -f $cid); continue }
            $freshSt = Read-SdachaState
            if (@($freshSt.pushed) -contains $cid) { continue }
            try {
                Send-SdachaPutDem -CaldavCfg $ccfg -Order $sd.Order -Who $sd.Who -CommentId $cid
                $st.pushed = @(@($st.pushed) + $cid | Select-Object -Unique)
                Save-SdachaState $st
                L ('И-104.2 ПУШ: {0} / сдан / {1}, комментарий {2}' -f $sd.Order, $sd.Who, $cid)
                try { Send-SdachaCommentDem -CaldavCfg $ccfg -Cfg $budCfg -Repo ([string]$cmMap[$cid].repo) -Issue ([int]$cmMap[$cid].issue) }
                catch { L ('И-104.2: подтверждение в зал не удалось: {0}' -f $_.Exception.Message) }
            } catch {
                L ('И-104.2 ОШИБКА push: {0}; pushed НЕ поставлен, повтор в следующем цикле (идемпотентно по UID)' -f $_.Exception.Message)
            }
        }
        # И-147: тела свежих комментариев - для триггеров hall-substring
        $script:lastHallBodies = @()
        foreach ($cmH in $fresh) { $script:lastHallBodies += [pscustomobject]@{ id = [string]$cmH.id; body = [string]$cmH.body } }
        # === И-143: постановка/вердикт - те же $fresh, свои state-файлы, since=деплой ===
        foreach ($kind in @('postanovka','verdict')) {
            $kindPath = Join-Path $stateDir ('nudge-scan.' + $kind + '.json')
            $kst = Read-KindState $kindPath
            try { $ksince = [datetime]::Parse([string]$kst.since, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $ksince = (Get-Date).ToUniversalTime() }
            $kSeen = 0
            foreach ($cm in $fresh) {
                $cid = [string]$cm.id
                if (@($kst.pushed) -contains $cid) { continue }
                try { $ca = [datetime]::Parse([string]$cm.created_at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { continue }
                if ($ca -le $ksince) { continue }
                $det = $null
                if ($kind -eq 'postanovka') { $det = Get-PostanovkaDem ([string]$cm.body) } else { $det = Get-VerdictDem ([string]$cm.body) }
                if (-not $det) { continue }
                $kSeen++
                $verb = 'поставлен'
                if ($kind -eq 'verdict') { $verb = 'вердикт подписан' }
                try {
                    Send-KindPushDem -CaldavCfg $ccfg -Kind $kind -Text ('{0} / {1} / {2}' -f $det.Order, $verb, $det.Who) -CommentId $cid
                    $kst.pushed = @(@($kst.pushed) + $cid | Select-Object -Unique)
                    Save-KindState $kindPath $kst
                    L ('И-143 ПУШ {0}: {1} / {2} / {3}, комментарий {4}' -f $kind, $det.Order, $verb, $det.Who, $cid)
                    try { Send-SdachaCommentDem -CaldavCfg $ccfg -Cfg $budCfg -Repo ([string]$cmMap[$cid].repo) -Issue ([int]$cmMap[$cid].issue) } catch { L ('И-143: подтверждение в зал не удалось: {0}' -f $_.Exception.Message) }
                } catch {
                    L ('И-143 ОШИБКА push {0}: {1}; pushed НЕ поставлен, повтор в следующем цикле (идемпотентно по UID)' -f $kind, $_.Exception.Message)
                }
            }
            if ($kSeen -eq 0) { L ('И-143 СКАН {0}: свежих=0 (детект жив)' -f $kind) }
        }
        $script:sdQuiet = [int]$script:sdQuiet + 1
        if ($sdSeen -gt 0) { $script:sdQuiet = 0 } elseif ([int]$script:sdQuiet -ge 30) { L ('И-138: сдач новых: 0 (30 циклов тишины - детект жив)'); $script:sdQuiet = 0 }
    } catch { L ('И-104.2 СКАН ERR: {0}' -f $_.Exception.Message) }
}
Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = 20MB
function Eval([System.Net.WebSockets.ClientWebSocket]$ws, [string]$expr) {
  $script:mid++
  $cts = New-Object Threading.CancellationTokenSource(20000)  # И-101: таймаут WS-вызова
  try {
    $msg = @{ id = $script:mid; method = 'Runtime.evaluate'; params = @{ expression = $expr; returnByValue = $true } }
    $bytes = [Text.Encoding]::UTF8.GetBytes($ser.Serialize($msg))
    $ws.SendAsync((New-Object ArraySegment[byte] -ArgumentList @(,$bytes)), 'Text', $true, $cts.Token).Wait()
    $buf = New-Object byte[] 1048576
    while ($true) {
      $ms = New-Object IO.MemoryStream
      do { $r = $ws.ReceiveAsync((New-Object ArraySegment[byte] -ArgumentList @(,$buf)), $cts.Token).Result; $ms.Write($buf, 0, $r.Count) } while (-not $r.EndOfMessage)
      $o = $ser.DeserializeObject([Text.Encoding]::UTF8.GetString($ms.ToArray()))
      if ($o -and $o.ContainsKey('id') -and $o['id'] -eq $script:mid) { return $o['result']['result'].value }
    }
  } finally { $cts.Dispose() }
}
function Send-CmdDem([System.Net.WebSockets.ClientWebSocket]$ws, [string]$method, [hashtable]$params) {
  $script:mid++
  $cts2 = New-Object Threading.CancellationTokenSource(20000)
  try {
    $msg = @{ id = $script:mid; method = $method; params = $params }
    $bytes = [Text.Encoding]::UTF8.GetBytes($ser.Serialize($msg))
    $ws.SendAsync((New-Object ArraySegment[byte] -ArgumentList @(,$bytes)), 'Text', $true, $cts2.Token).Wait()
    $buf = New-Object byte[] 1048576
    while ($true) {
      $ms = New-Object IO.MemoryStream
      do { $r = $ws.ReceiveAsync((New-Object ArraySegment[byte] -ArgumentList @(,$buf)), $cts2.Token).Result; $ms.Write($buf, 0, $r.Count) } while (-not $r.EndOfMessage)
      $o = $ser.DeserializeObject([Text.Encoding]::UTF8.GetString($ms.ToArray()))
      if ($o -and $o.ContainsKey('id') -and $o['id'] -eq $script:mid) { return $o }
    }
  } finally { $cts2.Dispose() }
}
L ('=== NUDGE-SCAN start (И-98) pid=' + $PID + ' ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ===')
$script:wsB = $null
$script:midB = 0
$script:sdQuiet = 0
$script:lastHallBodies = @()
# === И-147: конфиг сессий (галочки + индивидуальные триггеры), вне git ===
$cfgPath = Join-Path (Split-Path $logDir) 'sessions.config.json'
$script:sessCfg = $null
$script:sessCfgMtime = $null
$script:sessSnap = ''
$triggerStateFile = Join-Path $stateDir 'nudge-scan.triggers.json'
$script:triggerState = [pscustomobject]@{}
$script:trigFirstPass = $true   # И-214: первый проход триггеров после старта демона — без отправки «1»
if (Test-Path $triggerStateFile) { try { $j = Get-Content $triggerStateFile -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j) { $script:triggerState = $j } } catch { } }
function Save-TriggerState { [IO.File]::WriteAllText($triggerStateFile, ($script:triggerState | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true))) }
function Load-SessCfg {
  if (-not (Test-Path $cfgPath)) { if ($script:sessCfg) { $script:sessCfg = $null; L 'И-147 КОНФИГ удалён, legacy-режим' }; return }
  try {
    $fi = Get-Item $cfgPath
    if ($script:sessCfgMtime -ne $fi.LastWriteTimeUtc) {
      $script:sessCfg = (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json)
      $script:sessCfgMtime = $fi.LastWriteTimeUtc
      L ('И-147 КОНФИГ ПЕРЕЧИТАН mtime=' + $fi.LastWriteTimeUtc.ToString('HH:mm:ss') + ' сессий=' + @($script:sessCfg.sessions).Count)
    }
  } catch { L ('И-147 КОНФИГ ERR ' + $_.Exception.Message); $script:sessCfg = $null }
}
function Get-SessEntry([string]$Sess) {
  if (-not $script:sessCfg) { return $null }
  foreach ($s in @($script:sessCfg.sessions)) {
    if ($Sess -eq [string]$s.match) { return $s }
    if ($s.match -and ($Sess -match [string]$s.match)) { return $s }
  }
  return $null
}
# И-170: single-instance guard - pid-file state\nudge-scan.pid (Get-Process, CIM-независимо)
$script:daemonPidFile = 'C:\kimi-work\wake-rail\state\nudge-scan.pid'
try {
  $stateDir = Split-Path $script:daemonPidFile -Parent
  if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
  $oldD = 0
  if (Test-Path $script:daemonPidFile) { try { $oldD = [int](Get-Content $script:daemonPidFile -Raw -ErrorAction Stop).Trim() } catch { } }
  if ($oldD -gt 0 -and $oldD -ne $PID) {
    if (Get-Process -Id $oldD -ErrorAction SilentlyContinue) {
      $freshD = $false
      try { $lgD = Get-ChildItem $logDir -Filter 'nudge-scan-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($lgD -and ((Get-Date) - $lgD.LastWriteTime).TotalSeconds -lt 90) { $freshD = $true } } catch { }
      if ($freshD) { L ('И-170: already running pid=' + $oldD + ' - выход'); exit 0 }
    }
  }
  [IO.File]::WriteAllText($script:daemonPidFile, [string]$PID, (New-Object Text.UTF8Encoding $false))
  L ('И-170: pid-file записан pid=' + $PID)
} catch { L ('И-170 PID-FILE ERR: ' + $_.Exception.Message) }

# И-169.7: страховка «exception не гасит демон» - глобальный trap с анти-зацикливанием
$script:trapCount = 0
trap { $script:trapCount++; L ('И-169.7 TRAP: ' + $_.Exception.Message); if ($script:trapCount -gt 50) { L 'И-169.7 TRAP-LIMIT: 50 подряд - выход'; exit 1 }; continue }

while ($true) {
  try {
    try { Invoke-SdachaScanDem } catch { L ('И-104.2 ERR ' + $_.Exception.Message) }
    $tabs = Get-CdpTabs
    # === И-168: КАРАНТИН + ТРИПВАЙР челлендж-доменов ===
    $quar = $false
    try { $quar = [bool]$budCfg.quarantine } catch { }
    if ($quar) {
        $script:quarCount = [int]$script:quarCount + 1
        if ($script:quarCount -ge 10) { $script:quarCount = 0; L 'карантин: тихие циклы (quarantine=true)' }
        continue
    }
    # Трипвайр: вкладка с челлендж-доменом -> полный стоп
    $tabsT = $null
    try { $tabsT = Get-CdpTabs } catch { }
    if ($tabsT) {
        $bad = $null
        foreach ($tb in $tabsT) {
            $u = [string]$tb.url
            if ($u -match 'count\.perplexity\.ai' -or $u -match 'cf-chl' -or $u -match '/cdn-cgi/') { $bad = $u; break }
        }
        if ($bad) {
            if (-not $script:tripFired) {
                $script:tripFired = $true
                $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                L ('QUARANTINE-TRIP ' + $bad + ' ' + $now)
                # Весть в зал через маркер-файл (демон не имеет GitHub-токена здесь; контролёр/пульт забирают)
                [IO.File]::WriteAllText('C:\kimi-work\wake-rail\state\quarantine-trip.flag', ($bad + ' ' + $now), (New-Object Text.UTF8Encoding -ArgumentList 0))
            }
            continue
        } else {
            $script:tripFired = $false
        }
    }
    # === И-163: nightFreeze — ночная заморозка рабочих сессий (00:00-07:00, И-163.1) ===
    $nf = $false
    try { $nf = [bool]$budCfg.nightFreeze } catch { }
    if ($nf) {
        $hh = [int](Get-Date -Format 'HH')
        if ($hh -ge 0 -and $hh -lt 7) { continue }
    }
    Load-SessCfg
    $snap = @()
    foreach ($tb in $tabs) {
      if ($tb.type -ne 'page') { continue }
      if (($tb.url + '') -notmatch 'kimi\.ai/chat' -and ($tb.title + '') -notmatch ' - Kimi$') { continue }
      $sn = (($tb.title + '') -replace ' - Kimi$','').Trim()
      $e2 = Get-SessEntry $sn
      $st = 'default'
      if ($e2) { if ([bool]$e2.enabled) { $st = 'on' } else { $st = 'off' } }
      $snap += ($sn + '=' + $st)
    }
    $snapS = $snap -join '; '
    if ($snapS -ne $script:sessSnap) { $script:sessSnap = $snapS; L ('И-147 СЕССИИ: ' + $snapS) }
    $seenSessionPorts = @{}
    foreach ($tab in $tabs) {
      if ($tab.type -ne 'page') { continue }
      # И-101: только чат-вкладки Kimi (URL kimi.ai/chat или title " - Kimi"); прочие - молча
      if (($tab.url + '') -notmatch 'kimi\.ai/chat' -and ($tab.title + '') -notmatch ' - Kimi$') { continue }
      $sessN = (($tab.title + '') -replace ' - Kimi$','').Trim()
      $actualPort = '9222'
      if ($seenSessionPorts.ContainsKey($sessN)) { L ($sessN + ' | DEDUP-SKIP duplicate-window port=9222'); continue }
      $seenSessionPorts[$sessN] = $actualPort
      $sEntry = Get-SessEntry $sessN
      if ($sEntry -and -not [bool]$sEntry.enabled) {
        $offKey = 'off:' + $sessN
        if (-not $script:triggerState.PSObject.Properties[$offKey]) {
          $script:triggerState | Add-Member -NotePropertyName $offKey -NotePropertyValue (Get-Date).ToString('o') -Force
          Save-TriggerState
          L ($sessN + ' | И-147 ОТКЛЮЧЕНА галочкой, скан и толчки пропущены')
        }
        continue
      }
      # И-98.3-зачистка (16.10): мёртвый блок активации вкладки (SendAsync($ab) с пустой $ab
      # + поглощающий catch) удалён - вкладку читаем фоном, без поднятия окна (И-98.3).
      $ws = New-Object System.Net.WebSockets.ClientWebSocket
      try {
        $ctsC = New-Object Threading.CancellationTokenSource(20000)  # И-101
        try { $ws.ConnectAsync([Uri]$tab.webSocketDebuggerUrl, $ctsC.Token).Wait() } finally { $ctsC.Dispose() }
        $script:mid = 0
        # И-103.1: скан стоп-строки по сегментам ассистента (до 8 последних непустых);
        # диагностика КАЖДЫЙ цикл по КАЖДОМУ чату (HARD BLOCK постановки И-103.1).
        $scanJ = Eval $ws "JSON.stringify((function(){var a=document.querySelectorAll('.segment-assistant');var re=/^Стоп по бюджету \d{2}\.\d{2}\.\d{4} \d{2}:\d{2} \(МСК\)/;var parts=[];for(var i=a.length-1;i>=0&&parts.length<8;i--){var t0=(a[i].innerText||'').trim();if(t0)parts.push(t0)}var ls=parts.join('\n').split(/\n+/);var tailLine=ls.length?ls[ls.length-1].slice(0,50):'';for(var k=0;k<ls.length;k++){var s=ls[k].trim();if(re.test(s))return JSON.stringify({found:s,scanned:a.length,window:parts.length,tailLine:tailLine})}return JSON.stringify({found:'',scanned:a.length,window:parts.length,tailLine:tailLine})})())"
        $short = ($tab.title + '').Substring(0, [Math]::Min(28, ($tab.title + '').Length))
        $sess = (($tab.title + '') -replace ' - Kimi$','').Trim()
        # И-133.0: метки сессий для лога (карта); прочие - прежний префикс заголовка
        $labels = @{ 'Кими/Инфра/Исполнитель/Web' = 'Инфра веб'; 'Кими/Инфра/Исполнитель/Web-2' = 'Инфра веб 2' }
        if ($labels.ContainsKey($sess)) { $short = $labels[$sess] }
        $scan = $null
        if ($scanJ) { try { $scan = $ser.DeserializeObject($ser.DeserializeObject($scanJ)) } catch { $scan = $null } }
        $isStop = $false
        $foundLine = ''
        if ($scan -and $scan['found']) { $foundLine = [string]$scan['found']; $isStop = $true }
        # И-147: стоп-толчок только если триггер stop-line->nudge назначен (по конфигу сессии)
        $stopNudgeAllowed = $true
        if ($sEntry) {
          $stopNudgeAllowed = $false
          foreach ($t in @($sEntry.triggers)) {
            if ([string]$t.condition.type -eq 'stop-line' -and [string]$t.action.type -eq 'nudge') { $stopNudgeAllowed = $true }
          }
        }
        if (-not $stopNudgeAllowed -and $isStop) { L ($short + ' | И-147 стоп есть, но триггер stop-line->nudge не назначен, пропуск'); $isStop = $false }
        if (-not $isStop) {
          # И-169.7.1: резюм — любой ответ не-стоп снимает managed-стопы сессии
          $removed = 0
          foreach ($mk in @($markers.Keys)) {
            if ($mk.StartsWith($sess + '|') -and -not $markers[$mk]['cancelled']) { $markers.Remove($mk); $removed++ }
          }
          if ($removed -gt 0) { Save-Markers; L ($short + ' | РЕЗЮМ: ' + $removed + ' managed-стоп(ов) снято ответом не-стоп') }
          L ($short + ' | СКАН: cdp_port=' + $actualPort + ' стоп=НЕТ сегментов=' + $scan['scanned'] + ' окно=' + $scan['window'] + ' хвост="' + $scan['tailLine'] + '"')
          continue
        }
        # стоп найден - метка по событию (sess + текст стопа): новый стоп = новое событие
        $fp = $sess + '|' + $foundLine
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $m = $markers[$fp]
        L ($short + ' | СТОП-НАЙДЕН: "' + $foundLine + '" fp=' + $fp + ' state=' + ($m | ConvertTo-Json -Compress -Depth 2))
        # И-169.7.1: managed-стоп — толчки циклом (интервал 5 мин, не чаще) до N=3 без резюма; резюм снимает стоп (ветка -not $isStop)
        if ($m -and $m['cancelled']) { L ($short + ' | managed-стоп снят (И-169.7.1), fire запрещён КЛЮЧ=' + $fp); continue }
        # И-172: одноразовый толчок уже отправлен по этому стопу - повторных не даём (новый стоп = новый fp)
        if ($m -and ($m['state'] -eq 'closed')) { L ($short + ' | state=closed (одноразовый толчок отправлен) КЛЮЧ=' + $fp); continue }
        if ($m -and $m['lastNudge'] -and (($now - [int64]$m['lastNudge']) -lt 300)) {
          if ([string]$m['annN'] -ne [string]$m['lastNudge']) { $m['annN'] = [string]$m['lastNudge']; Save-Markers; L ($short + ' | managed-толчок свеж (интервал 5 мин) КЛЮЧ=' + $fp) }
          continue
        }
        if ($m -and $m['firstNudge'] -and (($now - [int64]$m['firstNudge']) -gt 21600)) { L ($short + ' | managed-стоп просрочен (общий возраст ' + ($now - [int64]$m['firstNudge']) + 'с > 6ч) КЛЮЧ=' + $fp); continue }
        if (-not $m) { $m = @{ first = $now; processed = $null; lastTry = $null; nudges = 0; firstNudge = $null; lastNudge = $null }; $markers[$fp] = $m }
        if ($isStop) {
          $c1 = Eval $ws "document.querySelectorAll('[class*=markdown]').length"
          Start-Sleep -Seconds 3
          $c2 = Eval $ws "document.querySelectorAll('[class*=markdown]').length"
          if ([int]$c2 -gt [int]$c1) { $m['lastTry'] = $now; Save-Markers; L ($short + ' | пропущено-активность КЛЮЧ=' + $fp); continue }
          if ($DetectOnly) {
            L ($short + ' | DETECT-ONLY: стоп найден, толчок не выполнялся')
          } else {
            Start-Sleep -Seconds (Get-Random -Minimum 0 -Maximum 11)  # И-103.3: джиттер отправки толчка 0..10 с
            $nudgePort = '9222'
            L ($short + ' | NUDGE-TARGET cdp_port=9222 КЛЮЧ=' + $fp)
            $nudgeOut = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File 'C:\kimi-work\wake-rail\scripts\nudge-once.ps1' -To ([string]$tab.title) -DelaySec 0 *>&1
            $nudgeText = (($nudgeOut | ForEach-Object { $_.ToString() }) -join "`n")
            $res = 'FAILED'
            if ($nudgeText -match 'RESULT=DELIVERED') { $res = 'DELIVERED' }
            if ($res -eq 'DELIVERED') {
              $m['processed'] = $now
              $m['lastNudge'] = $now
              if (-not $m['firstNudge']) { $m['firstNudge'] = $now }
              # И-172: один managed-толчок на стоп - state closed; серия N=3 только за флагом ManagedSeriesMode
              if ($script:ManagedSeriesMode) { $m['nudges'] = [int]$m['nudges'] + 1 }
              $m['state'] = 'closed'
              L ($short + ' | managed-толчок отправлен (одноразовый) state=closed КЛЮЧ=' + $fp)
            } else { $m['lastTry'] = $now }
            Save-Markers
            L ($short + ' | продлено RESULT=' + $res + ' nudges=' + [int]$m['nudges'] + ' cdp_port=' + $nudgePort + ' КЛЮЧ=' + $fp)
            Set-TriggerLastFire 'stop-budget-auto'
            # И-169.7.1: N=3 без резюма → снять + одно финальное извещение в зал #14
            if ($script:ManagedSeriesMode -and ($res -eq 'DELIVERED') -and ([int]$m['nudges'] -ge 3)) {
              $m['cancelled'] = $now
              Save-Markers
              L ($short + ' | И-169.7.1 SELF-CANCEL: 3 толчка без резюма, managed-стоп снят. КЛЮЧ=' + $fp)
              Send-ZalNoticeDem ('[nudge-scan] И-169.7.1: managed-стоп самоотменён (3 толчка без резюма). Сессия: ' + $sess + ' КЛЮЧ: ' + $fp)
            }
          }
        } else {
          if ($markers.ContainsKey($sess)) { $markers.Remove($sess); Save-Markers; L ($short + ' | ожила, маркер сброшен') } else { L ($short + ' | таб') }
        }
        # И-147: триггеры типа hall-substring (по телам зала из Invoke-SdachaScanDem)
        if ($sEntry) {
          foreach ($t in @($sEntry.triggers)) {
            if ([string]$t.condition.type -ne 'hall-substring') { continue }
            $txt = [string]$t.condition.text
            if (-not $txt) { continue }
            foreach ($hb in @($script:lastHallBodies)) {
              if ([string]$hb.body -notmatch [regex]::Escape($txt)) { continue }
              $evKey = 'trig:' + [string]$t.id + '|' + [string]$hb.id
              if ($script:triggerState.PSObject.Properties[$evKey]) { continue }
              $script:triggerState | Add-Member -NotePropertyName $evKey -NotePropertyValue (Get-Date).ToString('o') -Force
              Save-TriggerState
              if ([string]$t.action.type -eq 'push') {
                try {
                  Send-KindPushDem -CaldavCfg $ccfg -Kind ([string]$t.action.kind) -Text ('И-147: ' + $sessN + ' / ' + $txt) -CommentId ('hall-' + [string]$hb.id)
                  L ($short + ' | И-147 ТРИГГЕР ' + $t.id + ' PUSH событие=' + $hb.id)
                } catch { L ($short + ' | И-147 ТРИГГЕР ' + $t.id + ' ERR ' + $_.Exception.Message) }
              } else {
                L ($short + ' | И-147 ТРИГГЕР ' + $t.id + ' LOG событие=' + $hb.id + ' (действие=' + [string]$t.action.type + ')')
              }
            }
          }
        }
      } catch { L (($tab.title + '') + ' | ERR ' + $_.Exception.Message) }
      finally { try { $ws.Dispose() } catch {} }
    }
  } catch { L ('CDP-ERR ' + $_.Exception.Message) }
  if ($Once) { L '--- ONCE: цикл завершён ---'; break }
  # И-171: надзор демона за сторожем (вахтёр-вахтёра) - pid-file сторожа перезаписывается каждым его циклом; старше 180с - сторож мёртв/завис
  try {
    $wPidF = 'C:\kimi-work\wake-rail\watcher-nudge-scan.pid'
    if (Test-Path $wPidF) {
      $wAge = [int]((Get-Date) - (Get-Item $wPidF).LastWriteTime).TotalSeconds
      if ($wAge -gt 180) {
        $wPid = 0
        try { $wPid = [int](Get-Content $wPidF -Raw -ErrorAction Stop).Trim() } catch { }
        L ('И-171: сторож подозрителен (pid-file ' + $wAge + 'с) pid=' + $wPid)
        if ($wPid -gt 0 -and $wPid -ne $PID) { try { Stop-Process -Id $wPid -Force -ErrorAction Stop; L ('И-171: убит сторож pid=' + $wPid) } catch { } }
        Remove-Item $wPidF -Force -ErrorAction SilentlyContinue
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','C:\kimi-work\wake-rail\scripts\watchdog-nudge-scan.ps1'
        L 'И-171: сторож перезапущен демоном'
      }
    } else {
      L 'И-171: pid-file сторожа отсутствует - поднимаю сторожа'
      Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','C:\kimi-work\wake-rail\scripts\watchdog-nudge-scan.ps1'
    }
  } catch { L ('И-171 SUPERVISOR ERR: ' + $_.Exception.Message) }
  Start-Sleep -Seconds (40 + (Get-Random -Maximum 16))  # И-163.1: джиттер цикла 40..55 с (был 45+0..20)
}
