# 아이 PC에서 로그인 화면/시간 제한 제거 (관리자 권한 필요 - uninstall.bat 으로 실행하세요)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '관리자 권한이 필요합니다. uninstall.bat 을 실행하세요.' -ForegroundColor Red; exit 1 }

foreach ($name in 'PCTimer', 'PCTimer-Watchdog') {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
# 실행 중인 프로그램 종료
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PCTimer*client.ps1*' -or $_.CommandLine -like '*PCTimer*timer.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 아이 계정들에 걸어 둔 '작업 관리자 막기' 풀기
$sub = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
foreach ($p in (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special })) {
    if ($p.Loaded) {
        Remove-ItemProperty -Path "Registry::HKEY_USERS\$($p.SID)\$sub" -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue
    } else {
        $hive = Join-Path $p.LocalPath 'NTUSER.DAT'
        if (Test-Path $hive) {
            & reg.exe load 'HKU\PCTimerTmp' $hive 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & reg.exe delete "HKU\PCTimerTmp\$sub" /v DisableTaskMgr /f 2>$null | Out-Null
                [GC]::Collect()
                & reg.exe unload 'HKU\PCTimerTmp' 2>$null | Out-Null
            }
        }
    }
}

Remove-Item (Join-Path $env:ProgramFiles 'PCTimer') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramData 'PCTimer') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host '제거 완료. (작업 관리자 막기도 풀었습니다)' -ForegroundColor Green
