# =====================================================================
#  아이 PC용: 로그인 화면 + 사용 시간 제한
#  - Windows가 켜지면 전체 화면 로그인 창을 띄웁니다.
#  - 아이가 이름/비밀번호로 로그인하면 관리 서버에 남은 시간을 물어보고 그만큼 쓸 수 있습니다.
#  - 설정은 같은 폴더의 config.json (이 파일은 수정하지 마세요)
# =====================================================================
param(
    [switch]$Resume,   # 감시 작업이 다시 띄울 때: 로그인 상태 이어가기
    [switch]$Test      # 시험 모드: 창 모드, 브라우저 안 닫음, 작업관리자 안 막음
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------- 설정
$defaults = @{
    ServerUrl          = 'http://관리컴퓨터이름:8787'
    CenterName         = '우리 센터'
    WarnMinutes        = @(5, 1)
    EndAction          = 'Lock'        # Lock | Logoff | Shutdown
    GraceSeconds       = 30
    ExemptUsers        = @()
    Browsers           = @('chrome', 'msedge', 'whale', 'firefox', 'opera', 'brave', 'iexplore')
    DisableTaskManager = $true
    HeartbeatSeconds   = 30
}
$cfg = @{} + $defaults
try {
    $json = Get-Content (Join-Path $ScriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in $defaults.Keys) { if ($null -ne $json.$k) { $cfg[$k] = $json.$k } }
} catch { }
if ($Test) { $cfg.EndAction = 'Lock'; $cfg.GraceSeconds = 10 }

if (-not $Test -and (@($cfg.ExemptUsers) -contains $env:USERNAME)) { exit }

$mutexName = if ($Test) { 'Local\PCTimerClientTest' } else { 'Local\PCTimerClient' }
$created = $false
$Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
if (-not $created) { exit }

$ServerUrl = ([string]$cfg.ServerUrl).TrimEnd('/')
$GraceSec  = [int]$cfg.GraceSeconds
$HbSec     = [Math]::Max(10, [int]$cfg.HeartbeatSeconds)
$Action    = [string]$cfg.EndAction
$Browsers  = @($cfg.Browsers | ForEach-Object { ([string]$_) -replace '\.exe$', '' })
$WarnList  = @($cfg.WarnMinutes | ForEach-Object { [double]$_ })

$DataDir     = Join-Path $env:ProgramData 'PCTimer'
$SessionFile = Join-Path $DataDir 'session.json'
$LogFile     = Join-Path $DataDir 'log.txt'
try { if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null } } catch { }
try { if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.old" -Force } } catch { }

function Write-Log([string]$msg) {
    if ($Test) { $msg = "[시험] $msg" }
    try { Add-Content -Path $LogFile -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $env:USERNAME, $msg) } catch { }
}

# 작업 관리자로 로그인 창을 끄지 못하게 (이 Windows 계정에만 적용)
if (-not $Test) {
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'
        if ($cfg.DisableTaskManager) {
            if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
            New-ItemProperty -Path $key -Name 'DisableTaskMgr' -Value 1 -PropertyType DWord -Force | Out-Null
        } elseif (Test-Path $key) {
            Remove-ItemProperty -Path $key -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue
        }
    } catch { }
}

# ---------------------------------------------------------------- 서버 통신
function Invoke-Api([string]$path, [hashtable]$body) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Compress))
        $req = [System.Net.HttpWebRequest]::Create($ServerUrl + $path)
        $req.Method = 'POST'
        $req.ContentType = 'application/json; charset=utf-8'
        $req.Timeout = 4000
        $req.ReadWriteTimeout = 4000
        $req.Proxy = $null
        $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $txt = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        return ($txt | ConvertFrom-Json)
    } catch {
        return $null   # 연결 실패
    }
}

# ---------------------------------------------------------------- 로그인 정보 저장 (강제 종료 후 이어가기용)
function Save-SessionFile {
    if ($Test) { return }
    try {
        $o = @{ token = $S.Token; name = $S.Name; remainingSec = [int](Get-LocalRemaining); savedTicks = [DateTime]::UtcNow.Ticks }
        Set-Content -Path $SessionFile -Value (ConvertTo-Json -InputObject $o -Compress) -Encoding UTF8
    } catch { }
}
function Read-SessionFile {
    try { if (Test-Path $SessionFile) { return (Get-Content $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json) } } catch { }
    return $null
}
function Remove-SessionFile { try { Remove-Item $SessionFile -Force -ErrorAction SilentlyContinue } catch { } }

# ---------------------------------------------------------------- 브라우저
function Get-BrowserWindows {
    @(Get-Process -Name $Browsers -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
}
function Stop-Browsers {
    if ($Test) { return }
    Get-Process -Name $Browsers -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 상태
$S = @{
    Phase    = 'Locked'      # Locked | Active | Ending | Done
    Token    = ''
    Name     = ''
    Remaining = 0.0          # 마지막으로 서버에서 받은 남은 시간(초)
    SyncSw   = New-Object System.Diagnostics.Stopwatch   # 그 뒤로 흐른 시간
    HbSw     = New-Object System.Diagnostics.Stopwatch   # 마지막 서버 확인 이후
    EndSw    = New-Object System.Diagnostics.Stopwatch
    PingSw   = New-Object System.Diagnostics.Stopwatch
    Online   = $true
    Warned   = @{}
    Corner   = 'Bottom'
    Ticks    = 0
}
function Get-LocalRemaining { $S.Remaining - $S.SyncSw.Elapsed.TotalSeconds }

function Format-Left([double]$sec) {
    $s = [int][Math]::Ceiling([Math]::Max(0, $sec))
    $m = [int][Math]::Floor($s / 60)
    if ($m -ge 60) { return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($m / 60), ($m % 60), ($s % 60)) }
    return ('{0}:{1:00}' -f $m, ($s % 60))
}
function Format-Minutes([double]$sec) {
    $m = [int][Math]::Floor([Math]::Max(0, $sec) / 60)
    if ($m -ge 60) { return ('{0}시간 {1}분' -f [int][Math]::Floor($m / 60), ($m % 60)) }
    if ($m -lt 1) { return ('{0}초' -f [int][Math]::Max(0, $sec)) }
    return ('{0}분' -f $m)
}

# ---------------------------------------------------------------- 화면
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$FontName = 'Malgun Gothic'
function New-Font([float]$size, [switch]$Bold) {
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font($FontName, $size, $style)
}
function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [float]$size, [switch]$Bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = New-Font $size -Bold:$Bold
    $l.BackColor = [System.Drawing.Color]::Transparent
    return $l
}
$BlockUserClose = {
    param($s, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $e.Cancel = $true }
}
$ColorDark  = [System.Drawing.Color]::FromArgb(40, 40, 40)
$ColorWarn  = [System.Drawing.Color]::FromArgb(220, 120, 20)
$ColorRed   = [System.Drawing.Color]::FromArgb(190, 30, 30)
$ColorBlue  = [System.Drawing.Color]::FromArgb(47, 111, 237)
$ColorNavy  = [System.Drawing.Color]::FromArgb(22, 32, 64)
$ColorGray  = [System.Drawing.Color]::FromArgb(110, 115, 130)

# ---- 로그인 화면 (모든 모니터를 덮음)
$LockForm = New-Object System.Windows.Forms.Form
$LockForm.FormBorderStyle = 'None'
$LockForm.StartPosition = 'Manual'
$LockForm.BackColor = $ColorNavy
$LockForm.ShowInTaskbar = $false
if ($Test) {
    $LockForm.FormBorderStyle = 'FixedSingle'
    $LockForm.Text = 'PC 로그인 화면 (시험)'
    $LockForm.ShowInTaskbar = $true
    $LockForm.ClientSize = New-Object System.Drawing.Size(900, 640)
    $LockForm.StartPosition = 'CenterScreen'
    $LockForm.add_FormClosed({ [System.Windows.Forms.Application]::Exit() })
} else {
    $LockForm.TopMost = $true
    $LockForm.Bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $LockForm.add_FormClosing($BlockUserClose)
}

$Card = New-Object System.Windows.Forms.Panel
$Card.Size = New-Object System.Drawing.Size(520, 470)
$Card.BackColor = [System.Drawing.Color]::White
if ($Test) {
    $Card.Location = New-Object System.Drawing.Point(190, 85)
} else {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $ps = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $Card.Location = New-Object System.Drawing.Point(([int](($ps.X - $vs.X) + ($ps.Width - 520) / 2)), ([int](($ps.Y - $vs.Y) + ($ps.Height - 470) / 2)))
}
$LockForm.Controls.Add($Card)

$TitleLabel = New-Label ([string]$cfg.CenterName) 0 28 520 44 22 -Bold
$TitleLabel.TextAlign = 'MiddleCenter'
$TitleLabel.ForeColor = $ColorNavy
$SubLabel = New-Label '이름과 비밀번호를 넣고 로그인하세요' 0 76 520 28 12
$SubLabel.TextAlign = 'MiddleCenter'
$SubLabel.ForeColor = $ColorGray

$NameCaption = New-Label '이름' 60 122 400 24 11
$NameBox = New-Object System.Windows.Forms.TextBox
$NameBox.Location = New-Object System.Drawing.Point(60, 148)
$NameBox.Size = New-Object System.Drawing.Size(400, 40)
$NameBox.Font = New-Font 16
$NameBox.ImeMode = 'Hangul'

$PwCaption = New-Label '비밀번호' 60 202 400 24 11
$PwBox = New-Object System.Windows.Forms.TextBox
$PwBox.Location = New-Object System.Drawing.Point(60, 228)
$PwBox.Size = New-Object System.Drawing.Size(400, 40)
$PwBox.Font = New-Font 16
$PwBox.UseSystemPasswordChar = $true

$LoginBtn = New-Object System.Windows.Forms.Button
$LoginBtn.Text = '로그인'
$LoginBtn.Location = New-Object System.Drawing.Point(60, 296)
$LoginBtn.Size = New-Object System.Drawing.Size(400, 54)
$LoginBtn.Font = New-Font 16 -Bold
$LoginBtn.FlatStyle = 'Flat'
$LoginBtn.FlatAppearance.BorderSize = 0
$LoginBtn.BackColor = $ColorBlue
$LoginBtn.ForeColor = [System.Drawing.Color]::White
$LoginBtn.Cursor = [System.Windows.Forms.Cursors]::Hand

$MsgLabel = New-Label '' 20 360 480 60 12
$MsgLabel.TextAlign = 'MiddleCenter'
$MsgLabel.ForeColor = $ColorRed

$StatusLabel = New-Label '' 20 430 480 26 9
$StatusLabel.TextAlign = 'MiddleCenter'
$StatusLabel.ForeColor = $ColorGray

$Card.Controls.AddRange(@($TitleLabel, $SubLabel, $NameCaption, $NameBox, $PwCaption, $PwBox, $LoginBtn, $MsgLabel, $StatusLabel))
$LockForm.AcceptButton = $LoginBtn

$ClockLabel = New-Label '' 0 0 400 60 28 -Bold
$ClockLabel.ForeColor = [System.Drawing.Color]::White
$ClockLabel.TextAlign = 'MiddleCenter'
$ClockLabel.Location = New-Object System.Drawing.Point(([int]($Card.Left + 60)), ([int]($Card.Top - 80)))
$LockForm.Controls.Add($ClockLabel)

function Set-Msg([string]$text, [switch]$Info) {
    $MsgLabel.ForeColor = if ($Info) { $ColorGray } else { $ColorRed }
    $MsgLabel.Text = $text
}
function Set-Status {
    $StatusLabel.Text = if ($S.Online) { "관리 컴퓨터 연결됨 · $env:COMPUTERNAME" } else { "⚠ 관리 컴퓨터에 연결 안 됨 · $env:COMPUTERNAME" }
}

# ---- 남은 시간 표시 (오른쪽 아래) + 그만하기 버튼
$Overlay = New-Object System.Windows.Forms.Form
$Overlay.FormBorderStyle = 'None'
$Overlay.TopMost = $true
$Overlay.ShowInTaskbar = $false
$Overlay.StartPosition = 'Manual'
$Overlay.Size = New-Object System.Drawing.Size(340, 66)
$Overlay.BackColor = $ColorDark
$Overlay.Opacity = 0.92
$Overlay.add_FormClosing($BlockUserClose)
$OverlayLabel = New-Label '' 8 4 232 58 13 -Bold
$OverlayLabel.ForeColor = [System.Drawing.Color]::White
$OverlayLabel.TextAlign = 'MiddleCenter'
$StopBtn = New-Object System.Windows.Forms.Button
$StopBtn.Text = '그만하기'
$StopBtn.Location = New-Object System.Drawing.Point(244, 13)
$StopBtn.Size = New-Object System.Drawing.Size(88, 40)
$StopBtn.Font = New-Font 11 -Bold
$StopBtn.FlatStyle = 'Flat'
$StopBtn.BackColor = [System.Drawing.Color]::White
$StopBtn.ForeColor = $ColorDark
$Overlay.Controls.AddRange(@($OverlayLabel, $StopBtn))

function Set-OverlayPosition {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $wa.Right - $Overlay.Width - 12
    $y = if ($S.Corner -eq 'Top') { $wa.Top + 12 } else { $wa.Bottom - $Overlay.Height - 12 }
    $Overlay.Location = New-Object System.Drawing.Point($x, $y)
}
# 글자를 누르면 위/아래로 자리 옮김
$OverlayLabel.add_Click({
    $S.Corner = if ($S.Corner -eq 'Top') { 'Bottom' } else { 'Top' }
    Set-OverlayPosition
})

# ---- 시간 종료 안내창
$EndForm = New-Object System.Windows.Forms.Form
$EndForm.FormBorderStyle = 'None'
$EndForm.TopMost = $true
$EndForm.ShowInTaskbar = $false
$EndForm.StartPosition = 'CenterScreen'
$EndForm.Size = New-Object System.Drawing.Size(760, 330)
$EndForm.BackColor = [System.Drawing.Color]::FromArgb(25, 35, 70)
$EndForm.add_FormClosing($BlockUserClose)
$EndLabel = New-Label '' 0 0 760 330 20 -Bold
$EndLabel.ForeColor = [System.Drawing.Color]::White
$EndLabel.TextAlign = 'MiddleCenter'
$EndForm.Controls.Add($EndLabel)

# ---- 잠깐 떴다 사라지는 알림
function Show-Popup([string]$Text, [int]$Seconds = 8) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.ShowInTaskbar = $false
    $f.Size = New-Object System.Drawing.Size(620, 210)
    $f.BackColor = [System.Drawing.Color]::FromArgb(230, 110, 20)
    $l = New-Object System.Windows.Forms.Label
    $l.Dock = 'Fill'
    $l.TextAlign = 'MiddleCenter'
    $l.ForeColor = [System.Drawing.Color]::White
    $l.Font = New-Object System.Drawing.Font($FontName, 18, [System.Drawing.FontStyle]::Bold)
    $l.Text = $Text + "`n`n(누르면 닫혀요)"
    $f.Controls.Add($l)
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = [Math]::Max(1, $Seconds) * 1000
    $t.add_Tick({ param($s, $e) $s.Stop(); $f.Close() }.GetNewClosure())
    $l.add_Click({ $f.Close() }.GetNewClosure())
    $f.add_FormClosed({ $t.Stop(); $t.Dispose() }.GetNewClosure())
    $f.Tag = $t
    $f.Show()
    $t.Start()
}

# ---------------------------------------------------------------- 단계 전환
function Show-Lock {
    $S.Phase = 'Locked'
    $S.Token = ''; $S.Name = ''
    if ($Overlay.Visible) { $Overlay.Hide() }
    if ($EndForm.Visible) { $EndForm.Hide() }
    $NameBox.Text = ''; $PwBox.Text = ''
    Set-Msg ''
    Set-Status
    if (-not $LockForm.Visible) { $LockForm.Show() }
    $LockForm.WindowState = 'Normal'
    $LockForm.Activate()
    $NameBox.Focus() | Out-Null
}

function Update-Overlay {
    $left = Get-LocalRemaining
    $OverlayLabel.Text = "$($S.Name)`n남은 시간 $(Format-Left $left)"
    $Overlay.BackColor = if ($left -le 60) { $ColorRed } elseif ($left -le 300) { $ColorWarn } else { $ColorDark }
}

function Start-Active([string]$token, [string]$name, [double]$remaining, [switch]$Welcome) {
    $S.Phase = 'Active'
    $S.Token = $token
    $S.Name = $name
    $S.Remaining = $remaining
    $S.SyncSw.Restart()
    $S.HbSw.Restart()
    $S.Warned = @{}
    foreach ($w in $WarnList) { if ($w * 60 -ge $remaining) { $S.Warned["$w"] = $true } }
    Save-SessionFile
    if ($LockForm.Visible) { $LockForm.Hide() }
    Update-Overlay
    if (-not $Overlay.Visible) { Set-OverlayPosition; $Overlay.Show() }
    $Overlay.TopMost = $true
    if ($Welcome) { Show-Popup "$name, 반가워요!`n이번 주 남은 시간: $(Format-Minutes $remaining)" 4 }
    Write-Log ('로그인: {0} (남은 {1}초)' -f $name, [int]$remaining)
}

# 서버에 로그아웃 알리고 정리 (화면 전환은 따로)
function Close-ServerSession([string]$reason) {
    if ($S.Token) { $null = Invoke-Api '/api/logout' @{ token = $S.Token; reason = $reason } }
    $S.Token = ''
    Remove-SessionFile
}

function Invoke-EndAction {
    Stop-Browsers
    switch ($Action) {
        'Logoff' {
            $S.Phase = 'Done'; $S.EndSw.Restart()
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/l', '/f' -WindowStyle Hidden
        }
        'Shutdown' {
            $S.Phase = 'Done'; $S.EndSw.Restart()
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s', '/f', '/t', '0' -WindowStyle Hidden
        }
        default { Show-Lock }
    }
}

function Update-EndText {
    $left = [int][Math]::Ceiling($GraceSec - $S.EndSw.Elapsed.TotalSeconds)
    $what = switch ($Action) { 'Logoff' { '로그아웃됩니다' } 'Shutdown' { '컴퓨터가 꺼집니다' } default { '브라우저가 닫히고 처음 화면으로 돌아가요' } }
    $EndLabel.Text = "$($S.Name), 남은 시간을 모두 썼어요!`n`n${left}초 후 $what.`n저장할 것이 있으면 지금 저장하세요."
}

function Start-Ending {
    Write-Log "시간 종료: $($S.Name)"
    Close-ServerSession '시간 다 씀'
    $S.Phase = 'Ending'
    if ($Overlay.Visible) { $Overlay.Hide() }
    $S.EndSw.Restart()
    Update-EndText
    $EndForm.Show()
    $EndForm.TopMost = $true
    $EndForm.Activate()
}

function Invoke-Login {
    $name = $NameBox.Text.Trim()
    $pw = $PwBox.Text
    if (-not $name -or -not $pw) { Set-Msg '이름과 비밀번호를 모두 넣어 주세요.'; return }
    $LoginBtn.Enabled = $false
    Set-Msg '확인하는 중...' -Info
    [System.Windows.Forms.Application]::DoEvents()
    $r = Invoke-Api '/api/login' @{ name = $name; password = $pw; pc = $env:COMPUTERNAME }
    $LoginBtn.Enabled = $true
    $PwBox.Text = ''
    if ($null -eq $r) {
        $S.Online = $false; Set-Status
        Set-Msg "관리 컴퓨터에 연결할 수 없어요.`n선생님께 알려 주세요."
        return
    }
    $S.Online = $true; Set-Status
    if (-not $r.ok) { Set-Msg ([string]$r.message); $PwBox.Focus() | Out-Null; return }
    Start-Active ([string]$r.token) ([string]$r.name) ([double]$r.remainingSec) -Welcome
}
$LoginBtn.add_Click({ Invoke-Login })

$StopBtn.add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show($Overlay,
        "사용을 끝낼까요?`n남은 시간은 저장되고, 브라우저가 닫혀요.", '그만하기',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes -and $S.Phase -eq 'Active') {
        $left = Get-LocalRemaining
        Write-Log "그만하기: $($S.Name)"
        Close-ServerSession '스스로 그만함'
        Invoke-EndAction
        if ($S.Phase -eq 'Locked') { Set-Msg "수고했어요! 남은 시간 $(Format-Minutes $left)은 저장됐어요." -Info }
    }
})

# 서버에 사용 중임을 알리고 남은 시간 받아오기
function Sync-Heartbeat {
    $S.HbSw.Restart()
    $r = Invoke-Api '/api/heartbeat' @{ token = $S.Token }
    if ($null -eq $r) { $S.Online = $false; return }   # 연결 끊김: 내 시계로 계속 셈
    $S.Online = $true
    if (-not $r.ok) {
        Write-Log "서버가 사용을 끝냄: $($r.message)"
        $S.Token = ''
        Remove-SessionFile
        Invoke-EndAction
        Show-Popup ([string]$r.message) 6
        return
    }
    $S.Remaining = [double]$r.remainingSec
    $S.SyncSw.Restart()
    # 선물로 시간이 늘었으면 경고를 다시 할 수 있게
    foreach ($w in $WarnList) { if ($S.Remaining -gt $w * 60 + 5) { $S.Warned["$w"] = $false } }
    Save-SessionFile
}

# ---------------------------------------------------------------- 1초마다
function Invoke-Tick {
    try {
        $S.Ticks++
        switch ($S.Phase) {
            'Locked' {
                $ClockLabel.Text = (Get-Date).ToString('tt h:mm')
                if ((Get-BrowserWindows).Count -gt 0) { Stop-Browsers }
                if (-not $Test) {
                    if (-not $LockForm.Visible) { $LockForm.Show() }
                    if ($LockForm.WindowState -ne 'Normal') { $LockForm.WindowState = 'Normal' }
                    $LockForm.TopMost = $true
                    if (($S.Ticks % 3) -eq 0 -and [System.Windows.Forms.Form]::ActiveForm -ne $LockForm) { $LockForm.Activate() }
                }
                if (-not $S.PingSw.IsRunning -or $S.PingSw.Elapsed.TotalSeconds -ge 30) {
                    $S.PingSw.Restart()
                    $S.Online = ($null -ne (Invoke-Api '/api/ping' @{}))
                    Set-Status
                }
            }
            'Active' {
                $hb = $S.HbSw.Elapsed.TotalSeconds
                if ($hb -ge $HbSec -or ((Get-LocalRemaining) -le 0 -and $hb -ge 5)) { Sync-Heartbeat }
                if ($S.Phase -ne 'Active') { break }

                $left = Get-LocalRemaining
                if ($left -le 0) { Start-Ending; break }
                Update-Overlay
                if (-not $Overlay.Visible) { $Overlay.Show() }
                $Overlay.TopMost = $true

                $crossed = $false
                foreach ($w in $WarnList) {
                    if (-not $S.Warned["$w"] -and $left -le $w * 60) { $S.Warned["$w"] = $true; $crossed = $true }
                }
                if ($crossed) {
                    $m = [int][Math]::Ceiling($left / 60)
                    Show-Popup "남은 시간이 ${m}분이에요.`n저장할 것은 미리 저장하세요."
                }
            }
            'Ending' {
                if ($S.EndSw.Elapsed.TotalSeconds -ge $GraceSec) { Invoke-EndAction }
                else { Update-EndText; $EndForm.TopMost = $true }
            }
            'Done' {
                if ($S.EndSw.Elapsed.TotalSeconds -ge 60) { Invoke-EndAction }   # 끄기 실패 시 재시도
            }
        }
    } catch {
        Write-Log "오류: $_"
    }
}

# ---------------------------------------------------------------- 시작
$saved = if ($Test) { $null } else { Read-SessionFile }
Write-Log ("시작 (이어가기: {0}, 서버: {1})" -f [bool]$Resume, $ServerUrl)
Show-Lock
if ($saved -and $saved.token) {
    if ($Resume) {
        # 누가 프로그램을 강제로 껐다가 다시 켜진 경우: 로그인 상태 그대로 이어감
        $r = Invoke-Api '/api/heartbeat' @{ token = [string]$saved.token }
        if ($r -and $r.ok) {
            Start-Active ([string]$saved.token) ([string]$r.name) ([double]$r.remainingSec)
        } elseif ($null -eq $r) {
            $elapsed = ([DateTime]::UtcNow.Ticks - [long]$saved.savedTicks) / 10000000
            Start-Active ([string]$saved.token) ([string]$saved.name) ([double]$saved.remainingSec - $elapsed)
            $S.Online = $false
        } else {
            Remove-SessionFile
        }
    } else {
        # 새로 로그인(재부팅 등): 지난 사용은 끝난 것으로 처리
        $null = Invoke-Api '/api/logout' @{ token = [string]$saved.token; reason = '재부팅/재로그인' }
        Remove-SessionFile
    }
}

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 1000
$Timer.add_Tick({ Invoke-Tick })
$Timer.Start()

$Context = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($Context)
