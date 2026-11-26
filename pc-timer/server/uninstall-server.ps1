# PC 사용 시간 관리 서버 제거 - uninstall-server.bat 으로 실행하세요
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host '관리자 권한이 필요합니다. uninstall-server.bat 을 실행하세요.' -ForegroundColor Red; exit 1 }

Stop-ScheduledTask -TaskName 'PCTimerServer' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'PCTimerServer' -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*PCTimerServer*server.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-NetFirewallRule -DisplayName 'PCTimerServer' -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:ProgramFiles 'PCTimerServer') -Recurse -Force -ErrorAction SilentlyContinue

$data = Join-Path $env:ProgramData 'PCTimerServer'
$ans = Read-Host "아이 명단/시간 데이터($data)도 지울까요? 지우면 되돌릴 수 없습니다. (y/N)"
if ($ans -eq 'y') { Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue; Write-Host '데이터도 지웠습니다.' }
else { Write-Host '데이터는 남겨 두었습니다. 다시 설치하면 그대로 이어집니다.' }
Write-Host '제거 완료.' -ForegroundColor Green
