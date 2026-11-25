# PC 사용 시간 제한 타이머 제거 (관리자 권한 필요 - uninstall.bat 으로 실행하세요)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '관리자 권한이 필요합니다. uninstall.bat 을 실행하세요.' -ForegroundColor Red; exit 1 }

foreach ($name in 'PCTimer', 'PCTimer-Watchdog') {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
}
# 실행 중인 타이머 종료
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PCTimer*timer.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Remove-Item (Join-Path $env:ProgramFiles 'PCTimer') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramData 'PCTimer') -Recurse -Force -ErrorAction SilentlyContinue
Write-Host '제거 완료.' -ForegroundColor Green
