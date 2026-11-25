# =====================================================================
#  PC 사용 시간 제한 타이머 (센터 공용 컴퓨터용)
#  - 로그인 후 브라우저 창이 처음 열리는 순간부터 시간을 잽니다.
#  - 설정은 같은 폴더의 config.json 에서 바꿉니다. (이 파일은 수정하지 마세요)
# =====================================================================
param(
    [switch]$Resume,          # 감시 작업이 다시 띄울 때: 이전 타이머 이어서
    [double]$TestMinutes = 0  # 테스트용: N분 제한, 끝나면 브라우저만 닫음
)

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------- 설정
$defaults = @{
    LimitMinutes    = 30
    WarnMinutes     = @(5, 1)
    EndAction       = 'Shutdown'      # Shutdown | Logoff | CloseBrowser
    GraceSeconds    = 30
    CooldownMinutes = 0
    ExemptUsers     = @()
    Browsers        = @('chrome', 'msedge', 'whale', 'firefox', 'opera', 'brave', 'iexplore')
}
$cfg = @{} + $defaults
try {
    $json = Get-Content (Join-Path $ScriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in $defaults.Keys) {
        if ($null -ne $json.$k) { $cfg[$k] = $json.$k }
    }
} catch { }

$TestMode = $TestMinutes -gt 0
if ($TestMode) {
    $cfg.LimitMinutes    = $TestMinutes
    $cfg.EndAction       = 'CloseBrowser'
    $cfg.CooldownMinutes = 0
    $cfg.GraceSeconds    = 10
}

# 선생님 계정 등 제외
if (-not $TestMode -and (@($cfg.ExemptUsers) -contains $env:USERNAME)) { exit }

# 같은 사용자 세션에서 한 개만 실행
$mutexName = if ($TestMode) { 'Local\PCTimerTest' } else { 'Local\PCTimer' }
$created = $false
$Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$created)
if (-not $created) { exit }

$LimitSec = [double]$cfg.LimitMinutes * 60
$GraceSec = [int]$cfg.GraceSeconds
$CoolMin  = [double]$cfg.CooldownMinutes
$Action   = [string]$cfg.EndAction
$Browsers = @($cfg.Browsers | ForEach-Object { ([string]$_) -replace '\.exe$', '' })
$WarnList = @($cfg.WarnMinutes | ForEach-Object { [double]$_ })

$ActionText = switch ($Action) {
    'Logoff'       { '로그아웃됩니다' }
    'CloseBrowser' { '브라우저가 닫힙니다' }
    default        { '컴퓨터가 꺼집니다' }
}

# ---------------------------------------------------------------- 상태 파일 / 로그
$DataDir   = Join-Path $env:ProgramData 'PCTimer'
$StateFile = Join-Path $DataDir 'state.json'
$LogFile   = Join-Path $DataDir 'log.txt'
try { if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null } } catch { }
try { if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.old" -Force } } catch { }

function Write-Log([string]$msg) {
    if ($TestMode) { $msg = "[테스트] $msg" }
    try { Add-Content -Path $LogFile -Encoding UTF8 -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $env:USERNAME, $msg) } catch { }
}

try {
    $BootId = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks.ToString()
} catch { $BootId = 'unknown' }

# 모든 실행 상태는 이 해시테이블 하나에 (이벤트 핸들러에서 스코프 문제 없도록)
$S = @{
    Phase      = 'Waiting'   # Waiting | Running | Ending | Blocked | Done
    SavedPhase = 'Waiting'   # 파일에 저장되는 단계: Waiting | Running | Ended
    BaseUsed   = 0.0
    RunSw      = New-Object System.Diagnostics.Stopwatch
    SaveSw     = New-Object System.Diagnostics.Stopwatch
    EndSw      = New-Object System.Diagnostics.Stopwatch
    PopupSw    = New-Object System.Diagnostics.Stopwatch
    EndedAt    = [long]0
    EndReason  = ''
    Warned     = @{}
    Corner     = 'Bottom'
}

function Get-UsedSeconds { $S.BaseUsed + $S.RunSw.Elapsed.TotalSeconds }

function Read-State {
    try {
        if (Test-Path $StateFile) { return (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) }
    } catch { }
    return $null
}

function Write-State {
    if ($TestMode) { return }
    try {
        $obj = [ordered]@{
            bootId      = $BootId
            user        = $env:USERNAME
            phase       = $S.SavedPhase
            usedSeconds = [int](Get-UsedSeconds)
            lastUpdate  = [DateTime]::UtcNow.Ticks
            endedAt     = $S.EndedAt
        }
        Set-Content -Path $StateFile -Value ($obj | ConvertTo-Json) -Encoding UTF8
    } catch { }
}

function Get-MinutesSince($ticks) {
    try {
        $t = New-Object DateTime ([long]$ticks), ([DateTimeKind]::Utc)
        return ([DateTime]::UtcNow - $t).TotalMinutes
    } catch { return [double]::MaxValue }
}

function Get-CooldownLeftMinutes {
    if ($CoolMin -le 0 -or $S.EndedAt -le 0) { return 0 }
    $since = Get-MinutesSince $S.EndedAt
    if ($since -lt 0) { return 0 }
    return [Math]::Max(0, [Math]::Ceiling($CoolMin - $since))
}

# ---------------------------------------------------------------- 브라우저
function Get-BrowserWindows {
    @(Get-Process -Name $Browsers -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
}
function Stop-Browsers {
    Get-Process -Name $Browsers -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 화면
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$FontName = 'Malgun Gothic'
$BlockUserClose = {
    param($s, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) { $e.Cancel = $true }
}

# 오른쪽 아래 남은 시간 표시
$Overlay = New-Object System.Windows.Forms.Form
$Overlay.FormBorderStyle = 'None'
$Overlay.TopMost = $true
$Overlay.ShowInTaskbar = $false
$Overlay.StartPosition = 'Manual'
$Overlay.Size = New-Object System.Drawing.Size(210, 60)
$Overlay.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$Overlay.Opacity = 0.88
$Overlay.add_FormClosing($BlockUserClose)
$OverlayLabel = New-Object System.Windows.Forms.Label
$OverlayLabel.Dock = 'Fill'
$OverlayLabel.TextAlign = 'MiddleCenter'
$OverlayLabel.ForeColor = [System.Drawing.Color]::White
$OverlayLabel.Font = New-Object System.Drawing.Font($FontName, 16, [System.Drawing.FontStyle]::Bold)
$Overlay.Controls.Add($OverlayLabel)

function Set-OverlayPosition {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $wa.Right - $Overlay.Width - 12
    $y = if ($S.Corner -eq 'Top') { $wa.Top + 12 } else { $wa.Bottom - $Overlay.Height - 12 }
    $Overlay.Location = New-Object System.Drawing.Point($x, $y)
}
# 클릭하면 위/아래로 자리 옮김 (가리는 게 있을 때)
$OverlayLabel.add_Click({
    $S.Corner = if ($S.Corner -eq 'Top') { 'Bottom' } else { 'Top' }
    Set-OverlayPosition
})

function Show-Overlay([string]$text, [System.Drawing.Color]$color) {
    $OverlayLabel.Text = $text
    $Overlay.BackColor = $color
    if (-not $Overlay.Visible) { Set-OverlayPosition; $Overlay.Show() }
    $Overlay.TopMost = $true
}

# 시간 종료 안내창 (화면 가운데, 작업 저장은 가능하도록 전체화면 아님)
$EndForm = New-Object System.Windows.Forms.Form
$EndForm.FormBorderStyle = 'None'
$EndForm.TopMost = $true
$EndForm.ShowInTaskbar = $false
$EndForm.StartPosition = 'CenterScreen'
$EndForm.Size = New-Object System.Drawing.Size(760, 330)
$EndForm.BackColor = [System.Drawing.Color]::FromArgb(25, 35, 70)
$EndForm.add_FormClosing($BlockUserClose)
$EndLabel = New-Object System.Windows.Forms.Label
$EndLabel.Dock = 'Fill'
$EndLabel.TextAlign = 'MiddleCenter'
$EndLabel.ForeColor = [System.Drawing.Color]::White
$EndLabel.Font = New-Object System.Drawing.Font($FontName, 20, [System.Drawing.FontStyle]::Bold)
$EndForm.Controls.Add($EndLabel)

# 잠깐 떴다 사라지는 알림
function Show-Popup([string]$Text, [int]$Seconds = 8) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.ShowInTaskbar = $false
    $f.Size = New-Object System.Drawing.Size(600, 200)
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

function Format-Left([double]$sec) {
    $s = [int][Math]::Ceiling([Math]::Max(0, $sec))
    '{0}:{1:00}' -f [int][Math]::Floor($s / 60), ($s % 60)
}

# ---------------------------------------------------------------- 단계 전환
function Reset-Warnings {
    $S.Warned = @{}
    foreach ($w in $WarnList) { if ($w * 60 -ge $LimitSec) { $S.Warned["$w"] = $true } }
}

function Reset-Session {
    $S.BaseUsed = 0.0
    $S.RunSw.Reset()
    $S.EndedAt = [long]0
    $S.Phase = 'Waiting'
    $S.SavedPhase = 'Waiting'
    Reset-Warnings
    if ($Overlay.Visible) { $Overlay.Hide() }
    if ($EndForm.Visible) { $EndForm.Hide() }
    Write-State
    Write-Log '대기 시작 (브라우저가 열리면 시간 측정)'
}

function Start-Running {
    $S.Phase = 'Running'
    $S.SavedPhase = 'Running'
    $S.RunSw.Start()
    $S.SaveSw.Restart()
    Show-Overlay ('남은 시간 ' + (Format-Left ($LimitSec - (Get-UsedSeconds)))) ([System.Drawing.Color]::FromArgb(40, 40, 40))
    Write-State
    Write-Log ('시간 측정 시작 (이미 사용: {0}초)' -f [int]$S.BaseUsed)
}

function Update-EndText {
    $left = [int][Math]::Ceiling($GraceSec - $S.EndSw.Elapsed.TotalSeconds)
    if ($S.EndReason -eq 'cooldown') {
        $EndLabel.Text = "지금은 쉬는 시간이에요.`n$(Get-CooldownLeftMinutes)분 후에 다시 사용할 수 있어요.`n`n${left}초 후 $ActionText."
    } else {
        $EndLabel.Text = "사용 시간 $($cfg.LimitMinutes)분이 모두 끝났어요!`n`n${left}초 후 $ActionText.`n저장할 것이 있으면 지금 저장하세요."
    }
}

function Start-Ending([string]$reason) {
    $S.Phase = 'Ending'
    $S.EndReason = $reason
    $S.RunSw.Stop()
    if ($reason -eq 'timeup') {
        $S.SavedPhase = 'Ended'
        $S.EndedAt = [DateTime]::UtcNow.Ticks
        Write-State
        Write-Log '사용 시간 종료'
    }
    if ($Overlay.Visible) { $Overlay.Hide() }
    $S.EndSw.Restart()
    Update-EndText
    $EndForm.Show()
    $EndForm.TopMost = $true
    $EndForm.Activate()
}

function Enter-Blocked {
    $S.Phase = 'Blocked'
    if ($EndForm.Visible) { $EndForm.Hide() }
    Stop-Browsers
    Show-Overlay '사용 시간 종료' ([System.Drawing.Color]::FromArgb(190, 30, 30))
    $S.PopupSw.Restart()
}

function Invoke-EndAction {
    Write-Log "종료 동작 실행: $Action"
    switch ($Action) {
        'CloseBrowser' { Enter-Blocked }
        'Logoff' {
            $S.Phase = 'Done'; $S.EndSw.Restart()
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/l', '/f' -WindowStyle Hidden
        }
        default {
            $S.Phase = 'Done'; $S.EndSw.Restart()
            Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s', '/f', '/t', '0' -WindowStyle Hidden
        }
    }
}

# ---------------------------------------------------------------- 1초마다 실행
function Invoke-Tick {
    try {
        switch ($S.Phase) {
            'Waiting' {
                if ((Get-BrowserWindows).Count -gt 0) { Start-Running }
            }
            'Running' {
                $left = $LimitSec - (Get-UsedSeconds)
                if ($left -le 0) { Start-Ending 'timeup'; break }

                $color = if ($left -le 60) { [System.Drawing.Color]::FromArgb(190, 30, 30) }
                         elseif ($left -le 300) { [System.Drawing.Color]::FromArgb(220, 120, 20) }
                         else { [System.Drawing.Color]::FromArgb(40, 40, 40) }
                Show-Overlay ('남은 시간 ' + (Format-Left $left)) $color

                $crossed = $false
                foreach ($w in $WarnList) {
                    if (-not $S.Warned["$w"] -and $left -le $w * 60) { $S.Warned["$w"] = $true; $crossed = $true }
                }
                if ($crossed) {
                    $m = [int][Math]::Ceiling($left / 60)
                    Show-Popup "사용 시간이 ${m}분 남았어요.`n끝나면 $ActionText."
                    Write-Log "경고: 약 ${m}분 남음"
                }

                if ($S.SaveSw.Elapsed.TotalSeconds -ge 5) { Write-State; $S.SaveSw.Restart() }
            }
            'Ending' {
                if ($S.EndSw.Elapsed.TotalSeconds -ge $GraceSec) { Invoke-EndAction }
                else { Update-EndText; $EndForm.TopMost = $true }
            }
            'Blocked' {
                if ($CoolMin -gt 0 -and $S.EndedAt -gt 0 -and (Get-CooldownLeftMinutes) -le 0) {
                    Write-Log '쉬는 시간 끝, 다시 사용 가능'
                    Reset-Session
                    break
                }
                if ((Get-BrowserWindows).Count -gt 0) {
                    Stop-Browsers
                    if ($S.PopupSw.Elapsed.TotalSeconds -ge 5) {
                        $msg = '사용 시간이 끝나서 지금은 브라우저를 쓸 수 없어요.'
                        $cl = Get-CooldownLeftMinutes
                        if ($CoolMin -gt 0 -and $cl -gt 0) { $msg += "`n${cl}분 후에 다시 사용할 수 있어요." }
                        Show-Popup $msg 5
                        $S.PopupSw.Restart()
                    }
                }
            }
            'Done' {
                # 종료/로그아웃이 안 됐으면 1분 뒤 다시 시도
                if ($S.EndSw.Elapsed.TotalSeconds -ge 60) { Invoke-EndAction }
            }
        }
    } catch {
        Write-Log "오류: $_"
    }
}

# ---------------------------------------------------------------- 시작 시 판단
$st = if ($TestMode) { $null } else { Read-State }
$startMode = 'Fresh'
if ($st) {
    if ($Resume) {
        # 감시 작업이 다시 띄운 경우: 같은 부팅이면 하던 그대로 이어감
        if ($st.bootId -eq $BootId) {
            if ($st.phase -eq 'Ended') { $startMode = 'Ended' }
            elseif ($st.phase -eq 'Running') { $startMode = 'Resume' }
        }
    } elseif ($CoolMin -gt 0) {
        # 새로 로그인/재부팅: 쉬는 시간 중이거나, 쓰다가 재부팅했으면 이어서
        $sinceEnd = Get-MinutesSince $st.endedAt
        $sinceUpd = Get-MinutesSince $st.lastUpdate
        if ($st.phase -eq 'Ended' -and $sinceEnd -ge 0 -and $sinceEnd -lt $CoolMin) { $startMode = 'Cooldown' }
        elseif ($st.phase -eq 'Running' -and $sinceUpd -ge 0 -and $sinceUpd -lt $CoolMin) { $startMode = 'Resume' }
    }
}

Write-Log "시작 (모드: $startMode, 제한: $($cfg.LimitMinutes)분, 종료 동작: $Action)"
switch ($startMode) {
    'Resume' {
        Reset-Warnings
        $S.BaseUsed = [double]$st.usedSeconds
        Start-Running
    }
    { $_ -eq 'Ended' -or $_ -eq 'Cooldown' } {
        $S.EndedAt = [long]$st.endedAt
        $S.SavedPhase = 'Ended'
        if ($Action -eq 'CloseBrowser') { Enter-Blocked }
        elseif ($startMode -eq 'Cooldown') { Start-Ending 'cooldown' }
        else { Start-Ending 'resume' }
    }
    default { Reset-Session }
}

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 1000
$Timer.add_Tick({ Invoke-Tick })
$Timer.Start()

$Context = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($Context)
