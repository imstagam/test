# 관리 컴퓨터 진단: 서버가 돌고 있는지, 아이 PC가 들어올 수 있는지 확인하고 고쳐 줍니다
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Line { Say ('-' * 60) 'DarkGray' }

$dst = Join-Path $env:ProgramFiles 'PCTimerServer'
$port = 8787
try { $port = [int]((Get-Content (Join-Path $dst 'server-config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).Port) } catch { }

Say ''
Say '=== 관리 컴퓨터(서버) 확인 ===' 'Cyan'
Line

Say '1) 관리 프로그램이 설치돼 있나요?'
$task = Get-ScheduledTask -TaskName 'PCTimerServer' -ErrorAction SilentlyContinue
if (-not $task -or -not (Test-Path (Join-Path $dst 'server.ps1'))) {
    Say '   → 설치가 안 돼 있어요. install-server.bat 을 먼저 실행하세요.' 'Red'; return
}
Say '   → 설치돼 있어요 (OK)' 'Green'

Say '2) 관리 프로그램이 실행 중인가요?'
$ok = $false
try { $ok = (Invoke-RestMethod -Uri "http://localhost:$port/api/ping" -Method Post -TimeoutSec 5).ok } catch { }
if (-not $ok) {
    Say '   → 멈춰 있어요. 다시 시작합니다...' 'Yellow'
    Stop-ScheduledTask -TaskName 'PCTimerServer' -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName 'PCTimerServer'
    Start-Sleep -Seconds 6
    try { $ok = (Invoke-RestMethod -Uri "http://localhost:$port/api/ping" -Method Post -TimeoutSec 5).ok } catch { }
}
if ($ok) { Say '   → 실행 중이에요 (OK)' 'Green' }
else {
    Say '   → 시작이 안 돼요. 아래 기록 파일 마지막 줄을 사진 찍어 보내 주세요:' 'Red'
    Say ("     " + (Join-Path $env:ProgramData 'PCTimerServer\server.log')) 'White'
    $log = Join-Path $env:ProgramData 'PCTimerServer\server.log'
    if (Test-Path $log) { Get-Content $log -Tail 5 | ForEach-Object { Say "     $_" 'DarkYellow' } }
}

Say '3) 방화벽이 아이 PC를 들여보내나요?'
Remove-NetFirewallRule -DisplayName 'PCTimerServer' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'PCTimerServer' -Direction Inbound -Protocol TCP -LocalPort $port `
    -Action Allow -Profile Any | Out-Null
Say "   → Windows 방화벽에서 포트 $port 를 열었어요 (OK)" 'Green'
Say '   ※ V3, 알약 같은 백신에 방화벽 기능이 켜져 있으면 거기서도 포트를 허용해야 해요.' 'Yellow'

Say '4) 네트워크 종류'
Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
    $kind = switch ([string]$_.NetworkCategory) { 'Public' { '공용' } 'Private' { '개인' } 'DomainAuthenticated' { '도메인' } default { [string]$_.NetworkCategory } }
    Say ("   → {0}: {1} 네트워크" -f $_.InterfaceAlias, $kind)
}
Line

$ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress)
Say '■ 아이 PC의 config.json 에 넣을 주소 (ServerUrl):' 'Cyan'
foreach ($ip in $ips) { Say "    `"ServerUrl`": `"http://${ip}:$port`"," 'White' }
if ($ips.Count -gt 1) { Say '  (여러 개면 아이 PC와 앞자리 세 숫자가 같은 것을 쓰세요)' 'Gray' }
Say ''
Say "■ 관리 화면: http://localhost:$port" 'Cyan'
Say ''
Say '이제 아이 PC에서 check-connection.bat 을 실행해 연결을 다시 확인하세요.' 'Cyan'
Say ''
