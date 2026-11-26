# 아이 PC 설치: 로그인 화면 + 사용 시간 제한 (관리자 권한 필요 - install.bat 으로 실행하세요)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '관리자 권한이 필요합니다. install.bat 을 실행하세요.' -ForegroundColor Red; exit 1 }

$src  = $PSScriptRoot
$dst  = Join-Path $env:ProgramFiles 'PCTimer'      # 아이 계정은 읽기만 가능
$data = Join-Path $env:ProgramData 'PCTimer'      # 로그인 상태/로그 (쓰기 가능)
$usersSid = 'S-1-5-32-545'                         # BUILTIN\Users

try {
    $cfg = Get-Content (Join-Path $src 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $url = ([string]$cfg.ServerUrl).TrimEnd('/')

    Write-Host "관리 컴퓨터 연결 확인: $url"
    $ok = $false
    try { $ok = (Invoke-RestMethod -Uri "$url/api/ping" -Method Post -TimeoutSec 5).ok } catch { }
    if ($ok) { Write-Host '  → 연결 성공' -ForegroundColor Green }
    else {
        Write-Host '  → 연결 안 됨! config.json 의 ServerUrl 과 관리 컴퓨터가 켜져 있는지 확인하세요.' -ForegroundColor Yellow
        $ans = Read-Host '  그래도 설치할까요? (y/N)'
        if ($ans -ne 'y') { exit 1 }
    }

    # 예전 버전(timer.ps1) 정리
    Remove-Item (Join-Path $dst 'timer.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $data 'state.json') -Force -ErrorAction SilentlyContinue

    Write-Host "1) 파일 복사: $dst"
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($f in 'client.ps1', 'launch.vbs', 'config.json') {
        Copy-Item (Join-Path $src $f) (Join-Path $dst $f) -Force
    }
    Get-ChildItem $dst | Unblock-File

    Write-Host "2) 상태 폴더 준비: $data"
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    & icacls.exe $data /grant "*${usersSid}:(OI)(CI)M" | Out-Null

    Write-Host '3) 로그인할 때 자동 실행 등록'
    $principal = New-ScheduledTaskPrincipal -GroupId $usersSid -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel -StartWhenAvailable
    $launch = Join-Path $dst 'launch.vbs'

    # (1) Windows 로그인 즉시 로그인 화면 실행
    $a1 = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launch`""
    $t1 = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName 'PCTimer' -Action $a1 -Trigger $t1 -Principal $principal `
        -Settings $settings -Description '공용 PC 로그인 화면/사용 시간 제한' -Force | Out-Null

    # (2) 감시: 1분마다 확인해서 누가 강제로 껐으면 다시 실행 (로그인 상태 유지)
    $a2 = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$launch`" -Resume"
    $t2 = New-ScheduledTaskTrigger -AtLogOn
    $t2.Delay = 'PT1M'
    $t2.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)).Repetition
    Register-ScheduledTask -TaskName 'PCTimer-Watchdog' -Action $a2 -Trigger $t2 -Principal $principal `
        -Settings $settings -Description '공용 PC 로그인 화면 (감시)' -Force | Out-Null

    Write-Host ''
    Write-Host '설치 완료!' -ForegroundColor Green
    Write-Host ("  - 관리 컴퓨터: {0} / 끝나면: {1} / 제외 계정: {2}" -f $url, $cfg.EndAction, ($cfg.ExemptUsers -join ', '))
    Write-Host '  - 다음 Windows 로그인(또는 재부팅)부터 로그인 화면이 뜹니다.'
    Write-Host '  - 설정을 바꾸려면 이 폴더의 config.json 을 고친 뒤 install.bat 을 다시 실행하세요.'
} catch {
    Write-Host "설치 실패: $_" -ForegroundColor Red
    exit 1
}
