# PC 사용 시간 관리 서버 설치 (관리 컴퓨터용) - install-server.bat 으로 실행하세요
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '관리자 권한이 필요합니다. install-server.bat 을 실행하세요.' -ForegroundColor Red; exit 1 }

$src  = $PSScriptRoot
$dst  = Join-Path $env:ProgramFiles 'PCTimerServer'
$data = Join-Path $env:ProgramData 'PCTimerServer'

try {
    $cfg = Get-Content (Join-Path $src 'server-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $port = [int]$cfg.Port

    # 이미 돌고 있으면 멈춤
    Stop-ScheduledTask -TaskName 'PCTimerServer' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Host "1) 파일 복사: $dst"
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($f in 'server.ps1', 'admin.html', 'server-config.json') {
        Copy-Item (Join-Path $src $f) (Join-Path $dst $f) -Force
    }
    Get-ChildItem $dst | Unblock-File

    Write-Host "2) 데이터 폴더: $data (관리자만 접근)"
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    & icacls.exe $data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

    if (-not (Test-Path (Join-Path $data 'data.json'))) {
        Write-Host ''
        Write-Host '3) 관리 화면에 들어갈 관리자 비밀번호를 정합니다.' -ForegroundColor Cyan
        & (Join-Path $dst 'server.ps1') -Init
    } else {
        Write-Host '3) 기존 데이터가 있어 그대로 씁니다. (비밀번호를 잊었으면 reset-admin-password.bat)'
    }

    Write-Host "4) 방화벽 열기 (포트 $port, 같은 네트워크만)"
    Remove-NetFirewallRule -DisplayName 'PCTimerServer' -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'PCTimerServer' -Direction Inbound -Protocol TCP -LocalPort $port `
        -RemoteAddress LocalSubnet -Action Allow -Profile Any | Out-Null

    Write-Host '5) 컴퓨터가 켜지면 자동으로 서버 실행 등록'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"{0}`"" -f (Join-Path $dst 'server.ps1'))
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
    Register-ScheduledTask -TaskName 'PCTimerServer' -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description '공용 PC 사용 시간 관리 서버' -Force | Out-Null
    Start-ScheduledTask -TaskName 'PCTimerServer'

    # 접속 주소 안내
    Start-Sleep -Seconds 3
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -ExpandProperty IPAddress)
    $ok = $false
    try { $ok = (Invoke-RestMethod -Uri "http://localhost:$port/api/ping" -Method Post -TimeoutSec 5).ok } catch { }

    Write-Host ''
    if ($ok) { Write-Host '설치 완료! 서버가 실행 중입니다.' -ForegroundColor Green }
    else { Write-Host '설치는 끝났지만 서버 응답이 아직 없습니다. 1분 뒤 아래 주소를 열어 보세요.' -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '■ 관리 화면 (이 컴퓨터에서):' -ForegroundColor Cyan
    Write-Host "    http://localhost:$port"
    Write-Host '■ 아이 PC의 config.json 에 넣을 ServerUrl (아래 중 하나):' -ForegroundColor Cyan
    Write-Host "    http://$($env:COMPUTERNAME):$port"
    foreach ($ip in $ips) { Write-Host "    http://${ip}:$port" }
    Write-Host ''
    Write-Host '※ 이 컴퓨터가 꺼져 있으면 아이들이 로그인할 수 없습니다.'
    Write-Host '※ IP 주소가 바뀌지 않도록 공유기에서 이 컴퓨터 IP를 고정해 두면 좋습니다.'
} catch {
    Write-Host "설치 실패: $_" -ForegroundColor Red
    exit 1
}
