# =====================================================================
#  PC 사용 시간 관리 서버 (관리 컴퓨터에서 실행)
#  - 아이 PC들이 로그인/사용시간을 여기에 물어봅니다.
#  - 관리 화면: 브라우저에서 http://이컴퓨터주소:8787
#  - 데이터: C:\ProgramData\PCTimerServer\data.json
#
#  server.ps1 -Init  : 관리자 비밀번호 설정(처음 설치 또는 비밀번호 잊었을 때)
# =====================================================================
param([switch]$Init)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir   = Join-Path $env:ProgramData 'PCTimerServer'
$DataFile  = Join-Path $DataDir 'data.json'
$LogFile   = Join-Path $DataDir 'server.log'

Add-Type -AssemblyName System.Web.Extensions
$Js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Js.MaxJsonLength = [int]::MaxValue

# JSON 객체/배열 → PowerShell 해시테이블/ArrayList
function ConvertTo-Native($o) {
    if ($o -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $o.Keys) { $h[[string]$k] = ConvertTo-Native $o[$k] }
        return $h
    }
    if ($o -is [System.Array]) {
        $l = New-Object System.Collections.ArrayList
        foreach ($x in $o) { [void]$l.Add((ConvertTo-Native $x)) }
        return , $l
    }
    return $o
}

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

# ---------------------------------------------------------------- 설정
$Cfg = @{ Port = 8787; SessionTimeoutMinutes = 10; BonusResetsWeekly = $false }
try {
    $c = ConvertTo-Native ($Js.DeserializeObject((Get-Content (Join-Path $ScriptDir 'server-config.json') -Raw -Encoding UTF8)))
    foreach ($k in @($c.Keys)) { if ($k -notlike '_*') { $Cfg[$k] = $c[$k] } }
} catch { }

# ---------------------------------------------------------------- 비밀번호 / 토큰
function New-RandomHex([int]$bytes) {
    $b = New-Object byte[] $bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-PasswordHash([string]$pw) {
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 10000)
    $hash = $kdf.GetBytes(32)
    return ('{0}:{1}' -f [Convert]::ToBase64String($salt), [Convert]::ToBase64String($hash))
}

function Test-PasswordHash([string]$pw, [string]$stored) {
    try {
        $parts = $stored.Split(':')
        $salt = [Convert]::FromBase64String($parts[0])
        $expected = [Convert]::FromBase64String($parts[1])
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pw, $salt, 10000)
        $actual = $kdf.GetBytes(32)
        $diff = 0
        for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($actual[$i] -bxor $expected[$i]) }
        return ($diff -eq 0)
    } catch { return $false }
}

# ---------------------------------------------------------------- 데이터
function New-EmptyData {
    return @{
        version  = 1
        adminHash = ''
        settings = @{ weeklyMinutes = 30 }
        children = @{}
        sessions = @{}
        history  = (New-Object System.Collections.ArrayList)
    }
}

function Read-Data {
    if (-not (Test-Path $DataFile)) { return New-EmptyData }
    $d = ConvertTo-Native ($Js.DeserializeObject([IO.File]::ReadAllText($DataFile, [Text.Encoding]::UTF8)))
    $empty = New-EmptyData
    foreach ($k in @($empty.Keys)) { if ($null -eq $d[$k]) { $d[$k] = $empty[$k] } }
    if (-not ($d.history -is [System.Collections.ArrayList])) { $d.history = New-Object System.Collections.ArrayList }
    return $d
}

function Save-Data {
    $json = ConvertTo-Json -InputObject $Data -Depth 10 -Compress
    $tmp = "$DataFile.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path $DataFile) { [IO.File]::Replace($tmp, $DataFile, "$DataFile.bak") }
    else { [IO.File]::Move($tmp, $DataFile) }
    # 하루 한 번 백업
    $daily = Join-Path $DataDir ('backup\data-{0:yyyyMMdd}.json' -f (Get-Date))
    if (-not (Test-Path $daily)) {
        New-Item -ItemType Directory -Path (Split-Path $daily) -Force | Out-Null
        Copy-Item $DataFile $daily -Force
        Get-ChildItem (Split-Path $daily) -Filter 'data-*.json' | Sort-Object Name -Descending |
            Select-Object -Skip 60 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Add-History([hashtable]$h) {
    $h['t'] = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    [void]$Data.history.Add($h)
    while ($Data.history.Count -gt 3000) { $Data.history.RemoveAt(0) }
}

# ---------------------------------------------------------------- 주간 시간 계산
function Get-WeekStart {
    $d = (Get-Date).Date
    $off = ([int]$d.DayOfWeek + 6) % 7      # 월요일 = 0
    return $d.AddDays(-$off).ToString('yyyy-MM-dd')
}

function Update-Week($c) {
    $ws = Get-WeekStart
    if ([string]$c.weekStart -ne $ws) {
        $c.weekStart = $ws
        $c.usedBaseSec = [long]0
        $c.usedWeekSec = [long]0
        if ($Cfg.BonusResetsWeekly) { $c.bonusSec = [long]0 }
        return $true
    }
    return $false
}

function Get-WeeklySec($c) {
    $m = $c.weeklyMinutes
    if ($null -eq $m -or [string]$m -eq '') { $m = $Data.settings.weeklyMinutes }
    return [long]([double]$m * 60)
}

function Get-BaseLeft($c) { return [long][Math]::Max([long]0, [long](Get-WeeklySec $c) - [long]$c.usedBaseSec) }
function Get-Remaining($c) { return [long]((Get-BaseLeft $c) + [long]$c.bonusSec) }

# 사용 시간 차감: 기본 시간 먼저, 그다음 선물 시간
function Add-Usage($c, [long]$sec) {
    if ($sec -le 0) { return }
    $take = [long][Math]::Min([long]$sec, [long](Get-BaseLeft $c))
    $c.usedBaseSec = [long]$c.usedBaseSec + $take
    $rest = [long]($sec - $take)
    $c.bonusSec = [long][Math]::Max([long]0, [long]$c.bonusSec - $rest)
    $c.usedWeekSec = [long]$c.usedWeekSec + $sec
    $c.totalSec = [long]$c.totalSec + $sec
}

# ---------------------------------------------------------------- 세션
$Kicked = @{}        # 선생님이 끝낸 세션 토큰 → 안내 문구
$AdminTokens = @{}   # 관리 화면 로그인 토큰 → 만료 시각
$AdminFail = @{ fails = 0; until = [long]0 }

function Get-NowTicks { return [DateTime]::UtcNow.Ticks }

# 마지막 확인 이후 흐른 시간만큼 차감 (서버 시계 기준)
function Update-SessionCharge($s, $c) {
    $now = Get-NowTicks
    $gap = [long][Math]::Floor(($now - [long]$s.lastTicks) / 10000000)
    if ($gap -gt 0) {
        $s.lastTicks = [long]$s.lastTicks + $gap * 10000000
        $s.chargedSec = [long]$s.chargedSec + $gap
        if ($c) { Add-Usage $c $gap }
    }
}

function Close-Session([string]$tok, [string]$reason, [switch]$Charge) {
    $s = $Data.sessions[$tok]
    if (-not $s) { return }
    $c = $Data.children[[string]$s.childId]
    if ($Charge -and $c) { Update-SessionCharge $s $c }
    $Data.sessions.Remove($tok)
    Add-History @{
        type = 'session'; name = $(if ($c) { [string]$c.name } else { '(삭제됨)' })
        pc = [string]$s.pc; sec = [long]$s.chargedSec; note = $reason; start = [string]$s.startStr
    }
}

function Invoke-Sweep {
    $limit = [long]([double]$Cfg.SessionTimeoutMinutes * 60 * 10000000)
    $now = Get-NowTicks
    $changed = $false
    foreach ($tok in @($Data.sessions.Keys)) {
        if ($now - [long]$Data.sessions[$tok].lastTicks -gt $limit) {
            Close-Session $tok '연결 끊김'
            $changed = $true
        }
    }
    foreach ($tok in @($AdminTokens.Keys)) { if ($AdminTokens[$tok] -lt $now) { $AdminTokens.Remove($tok) } }
    return $changed
}

function Find-ChildByName([string]$name) {
    $n = $name.Trim()
    foreach ($c in $Data.children.Values) { if (([string]$c.name).Trim() -ieq $n) { return $c } }
    return $null
}

function Get-ChildSession($childId) {
    foreach ($s in $Data.sessions.Values) { if ([string]$s.childId -eq [string]$childId) { return $s } }
    return $null
}

# ---------------------------------------------------------------- 응답 도우미
function Fail([string]$message, [string]$code = 'error') { return @{ ok = $false; error = $code; message = $message } }

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$status = 200) {
    $r = $ctx.Response
    $r.StatusCode = $status
    $r.ContentType = $type
    $r.Headers['Cache-Control'] = 'no-store'
    $r.ContentLength64 = $bytes.Length
    $r.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Send-Json($ctx, $obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 10 -Compress
    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
}

function ConvertTo-Minutes($v) {
    if ($null -eq $v -or [string]$v -eq '') { return $null }
    $d = 0.0
    if (-not [double]::TryParse([string]$v, [ref]$d)) { throw '숫자를 넣어 주세요.' }
    return $d
}

# ---------------------------------------------------------------- 아이 PC용 API
function Invoke-ClientApi([string]$path, $body) {
    switch ($path) {
        '/api/ping' { return @{ ok = $true } }

        '/api/login' {
            $name = ([string]$body.name).Trim()
            $pw = [string]$body.password
            $pc = ([string]$body.pc).Trim()
            $c = Find-ChildByName $name
            $now = Get-NowTicks
            if (-not $c) { return (Fail '이름 또는 비밀번호가 맞지 않아요.') }
            if ([long]$c.lockUntil -gt $now) { return (Fail '비밀번호를 여러 번 틀렸어요. 1분 뒤에 다시 해 보세요.') }
            if (-not (Test-PasswordHash $pw ([string]$c.hash))) {
                $c.failCount = [int]$c.failCount + 1
                if ($c.failCount -ge 5) { $c.failCount = 0; $c.lockUntil = [long]($now + 60 * 10000000) }
                Save-Data
                return (Fail '이름 또는 비밀번호가 맞지 않아요.')
            }
            $c.failCount = 0
            [void](Update-Week $c)

            foreach ($tok in @($Data.sessions.Keys)) {
                $s = $Data.sessions[$tok]
                if ([string]$s.childId -eq [string]$c.id) {
                    if ([string]$s.pc -ieq $pc) { Close-Session $tok '다시 로그인' -Charge }
                    else { Save-Data; return (Fail ("다른 컴퓨터({0})에서 사용 중이에요." -f $s.pc)) }
                } elseif ([string]$s.pc -ieq $pc) {
                    Close-Session $tok '다른 아이가 로그인' -Charge
                }
            }

            $rem = Get-Remaining $c
            if ($rem -le 0) { Save-Data; return (Fail '이번 주 사용 시간을 모두 썼어요. 월요일에 다시 채워져요.' 'notime') }

            $token = New-RandomHex 24
            $Data.sessions[$token] = @{
                token = $token; childId = [string]$c.id; pc = $pc
                startTicks = $now; lastTicks = $now; chargedSec = [long]0
                startStr = (Get-Date).ToString('yyyy-MM-dd HH:mm')
            }
            Save-Data
            Write-Log ("로그인: {0} @ {1} (남은 {2}초)" -f $c.name, $pc, $rem)
            return @{ ok = $true; token = $token; name = [string]$c.name; remainingSec = $rem }
        }

        '/api/heartbeat' {
            $tok = [string]$body.token
            if ($Kicked.ContainsKey($tok)) { $m = $Kicked[$tok]; $Kicked.Remove($tok); return (Fail $m 'kicked') }
            $s = $Data.sessions[$tok]
            if (-not $s) { return (Fail '로그인이 끝났어요. 다시 로그인해 주세요.' 'expired') }
            $c = $Data.children[[string]$s.childId]
            if (-not $c) { Close-Session $tok '아이 삭제됨'; Save-Data; return (Fail '로그인이 끝났어요.' 'expired') }
            [void](Update-Week $c)
            Update-SessionCharge $s $c
            Save-Data
            return @{ ok = $true; remainingSec = (Get-Remaining $c); name = [string]$c.name }
        }

        '/api/logout' {
            $tok = [string]$body.token
            if ($Data.sessions.ContainsKey($tok)) {
                $s = $Data.sessions[$tok]
                $c = $Data.children[[string]$s.childId]
                Close-Session $tok ([string]$body.reason) -Charge
                Save-Data
                if ($c) { Write-Log ("로그아웃: {0} @ {1}" -f $c.name, $s.pc) }
            }
            return @{ ok = $true }
        }
    }
    return (Fail '알 수 없는 요청' 'notfound')
}

# ---------------------------------------------------------------- 관리 화면 API
function Get-AdminState {
    $changed = $false
    $list = New-Object System.Collections.ArrayList
    foreach ($c in $Data.children.Values) {
        if (Update-Week $c) { $changed = $true }
        $s = Get-ChildSession $c.id
        [void]$list.Add(@{
            id = [string]$c.id; name = [string]$c.name
            weeklyMinutes = $c.weeklyMinutes
            weeklySec = (Get-WeeklySec $c); baseLeftSec = (Get-BaseLeft $c)
            bonusSec = [long]$c.bonusSec; remainingSec = (Get-Remaining $c)
            usedWeekSec = [long]$c.usedWeekSec; totalSec = [long]$c.totalSec
            onlinePc = $(if ($s) { [string]$s.pc } else { '' })
            onlineSince = $(if ($s) { [string]$s.startStr } else { '' })
        })
    }
    if ($changed) { Save-Data }
    $sorted = New-Object System.Collections.ArrayList
    foreach ($x in ($list | Sort-Object { $_.name })) { [void]$sorted.Add($x) }
    $hist = New-Object System.Collections.ArrayList
    for ($i = $Data.history.Count - 1; $i -ge 0 -and $hist.Count -lt 300; $i--) { [void]$hist.Add($Data.history[$i]) }
    return @{
        ok = $true; children = $sorted; history = $hist
        settings = @{ weeklyMinutes = $Data.settings.weeklyMinutes }
        weekStart = (Get-WeekStart); serverTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        bonusResetsWeekly = [bool]$Cfg.BonusResetsWeekly
    }
}

function Get-ChildOrThrow($id) {
    $c = $Data.children[[string]$id]
    if (-not $c) { throw '아이를 찾을 수 없어요. 새로고침해 주세요.' }
    return $c
}

function Invoke-AdminApi([string]$path, $body, $ctx) {
    $now = Get-NowTicks
    if ($path -eq '/admin/api/login') {
        if ($AdminFail.until -gt $now) { return (Fail '비밀번호를 여러 번 틀렸어요. 1분 뒤에 다시 해 보세요.') }
        if (-not (Test-PasswordHash ([string]$body.password) ([string]$Data.adminHash))) {
            $AdminFail.fails = [int]$AdminFail.fails + 1
            if ($AdminFail.fails -ge 5) { $AdminFail.fails = 0; $AdminFail.until = $now + 60 * 10000000 }
            return (Fail '관리자 비밀번호가 맞지 않아요.')
        }
        $AdminFail.fails = 0
        $tok = New-RandomHex 24
        $AdminTokens[$tok] = $now + [long](12 * 3600) * 10000000
        return @{ ok = $true; token = $tok }
    }

    $tok = [string]$ctx.Request.Headers['X-Admin-Token']
    if (-not $tok -or -not $AdminTokens.ContainsKey($tok)) { return (Fail '다시 로그인해 주세요.' 'auth') }

    try {
        switch ($path) {
            '/admin/api/state' { return (Get-AdminState) }

            '/admin/api/logout' { $AdminTokens.Remove($tok); return @{ ok = $true } }

            '/admin/api/child/add' {
                $name = ([string]$body.name).Trim()
                $pw = [string]$body.password
                if (-not $name) { throw '이름을 넣어 주세요.' }
                if (-not $pw) { throw '비밀번호를 넣어 주세요.' }
                if (Find-ChildByName $name) { throw '같은 이름이 이미 있어요. (예: 김민수2)' }
                $id = New-RandomHex 6
                $c = @{
                    id = $id; name = $name; hash = (New-PasswordHash $pw)
                    weeklyMinutes = (ConvertTo-Minutes $body.weeklyMinutes)
                    weekStart = (Get-WeekStart); usedBaseSec = [long]0; usedWeekSec = [long]0
                    bonusSec = [long]0; totalSec = [long]0; failCount = 0; lockUntil = [long]0
                    created = (Get-Date).ToString('yyyy-MM-dd')
                }
                $Data.children[$id] = $c
                Add-History @{ type = 'admin'; name = $name; note = '아이 등록' }
                Save-Data
                return @{ ok = $true }
            }

            '/admin/api/child/update' {
                $c = Get-ChildOrThrow $body.id
                $name = ([string]$body.name).Trim()
                if (-not $name) { throw '이름을 넣어 주세요.' }
                $other = Find-ChildByName $name
                if ($other -and [string]$other.id -ne [string]$c.id) { throw '같은 이름이 이미 있어요.' }
                $notes = @()
                if ($name -ne [string]$c.name) { $notes += "이름 변경($($c.name)→$name)"; $c.name = $name }
                if ([string]$body.password) { $c.hash = New-PasswordHash ([string]$body.password); $c.failCount = 0; $c.lockUntil = [long]0; $notes += '비밀번호 변경' }
                $wm = ConvertTo-Minutes $body.weeklyMinutes
                if ([string]$wm -ne [string]$c.weeklyMinutes) { $c.weeklyMinutes = $wm; $notes += '주간 시간 변경' }
                if ($notes.Count) { Add-History @{ type = 'admin'; name = $name; note = ($notes -join ', ') } }
                Save-Data
                return @{ ok = $true }
            }

            '/admin/api/child/delete' {
                $c = Get-ChildOrThrow $body.id
                foreach ($t in @($Data.sessions.Keys)) {
                    if ([string]$Data.sessions[$t].childId -eq [string]$c.id) {
                        $Kicked[$t] = '선생님이 사용을 끝냈어요.'
                        Close-Session $t '아이 삭제' -Charge
                    }
                }
                $Data.children.Remove([string]$c.id)
                Add-History @{ type = 'admin'; name = [string]$c.name; note = '아이 삭제' }
                Save-Data
                return @{ ok = $true }
            }

            '/admin/api/gift' {
                $min = ConvertTo-Minutes $body.minutes
                if ($null -eq $min -or $min -eq 0) { throw '선물할 시간(분)을 넣어 주세요.' }
                $targets = if ([string]$body.id -eq 'all') { @($Data.children.Values) } else { @(Get-ChildOrThrow $body.id) }
                foreach ($c in $targets) {
                    [void](Update-Week $c)
                    $c.bonusSec = [long][Math]::Max([long]0, [long]$c.bonusSec + [long]($min * 60))
                    Add-History @{ type = 'gift'; name = [string]$c.name; minutes = $min; note = [string]$body.note }
                }
                Save-Data
                return @{ ok = $true }
            }

            '/admin/api/child/resetweek' {
                $c = Get-ChildOrThrow $body.id
                $c.usedBaseSec = [long]0; $c.usedWeekSec = [long]0; $c.weekStart = (Get-WeekStart)
                Add-History @{ type = 'admin'; name = [string]$c.name; note = '이번 주 시간 다시 채움' }
                Save-Data
                return @{ ok = $true }
            }

            '/admin/api/session/end' {
                $c = Get-ChildOrThrow $body.id
                foreach ($t in @($Data.sessions.Keys)) {
                    if ([string]$Data.sessions[$t].childId -eq [string]$c.id) {
                        $Kicked[$t] = '선생님이 사용을 끝냈어요.'
                        Close-Session $t '선생님이 끝냄' -Charge
                    }
                }
                Save-Data
                return @{ ok = $true }
            }

            '/admin/api/settings' {
                $wm = ConvertTo-Minutes $body.weeklyMinutes
                if ($null -eq $wm -or $wm -lt 0) { throw '기본 주간 시간(분)을 넣어 주세요.' }
                $Data.settings.weeklyMinutes = $wm
                if ([string]$body.newPassword) {
                    if (([string]$body.newPassword).Length -lt 4) { throw '관리자 비밀번호는 4자 이상으로 해 주세요.' }
                    $Data.adminHash = New-PasswordHash ([string]$body.newPassword)
                    Add-History @{ type = 'admin'; name = '-'; note = '관리자 비밀번호 변경' }
                }
                Save-Data
                return @{ ok = $true }
            }
        }
    } catch {
        return (Fail ([string]$_.Exception.Message))
    }
    return (Fail '알 수 없는 요청' 'notfound')
}

# ---------------------------------------------------------------- 관리자 비밀번호 설정 모드
if ($Init) {
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $Data = Read-Data
    while ($true) {
        $p1 = Read-Host '관리자 비밀번호를 정해 주세요 (4자 이상)' -AsSecureString
        $p2 = Read-Host '한 번 더 입력' -AsSecureString
        $s1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $s2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        if ($s1.Length -lt 4) { Write-Host '4자 이상으로 해 주세요.' -ForegroundColor Yellow; continue }
        if ($s1 -ne $s2) { Write-Host '두 번 입력한 비밀번호가 달라요.' -ForegroundColor Yellow; continue }
        break
    }
    $Data.adminHash = New-PasswordHash $s1
    Save-Data
    Write-Host '관리자 비밀번호를 저장했습니다.' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- 서버 실행
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$Data = Read-Data
if (-not $Data.adminHash) { Write-Log '관리자 비밀번호가 없습니다. reset-admin-password.bat 으로 먼저 정해 주세요.' }
$AdminHtmlPath = Join-Path $ScriptDir 'admin.html'

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add(('http://+:{0}/' -f [int]$Cfg.Port))
$Listener.Start()
Write-Log ('서버 시작 (포트 {0})' -f [int]$Cfg.Port)

while ($Listener.IsListening) {
    $ctx = $Listener.GetContext()
    try {
        $req = $ctx.Request
        $path = $req.Url.AbsolutePath.TrimEnd('/')
        if ($path -eq '') { $path = '/' }

        if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/admin')) {
            Send-Bytes $ctx ([IO.File]::ReadAllBytes($AdminHtmlPath)) 'text/html; charset=utf-8'
            continue
        }

        $body = @{}
        if ($req.HasEntityBody) {
            $sr = New-Object System.IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
            $txt = $sr.ReadToEnd()
            $sr.Close()
            if ($txt) { $body = ConvertTo-Native ($Js.DeserializeObject($txt)) }
            if (-not ($body -is [hashtable])) { $body = @{} }
        }

        if (Invoke-Sweep) { Save-Data }

        if ($path -like '/admin/api/*') { $result = Invoke-AdminApi $path $body $ctx }
        elseif ($path -like '/api/*') { $result = Invoke-ClientApi $path $body }
        else { $result = Fail '알 수 없는 요청' 'notfound' }
        Send-Json $ctx $result
    } catch {
        Write-Log ("오류: {0} ({1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
        try { Send-Json $ctx (Fail '서버 오류가 났어요.') } catch { }
    } finally {
        try { $ctx.Response.Close() } catch { }
    }
}
