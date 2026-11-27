# 아이 PC → 관리 컴퓨터 연결 진단
$installed = Join-Path $env:ProgramFiles 'PCTimer\config.json'
$local = Join-Path $PSScriptRoot 'config.json'
$cfgPath = if (Test-Path $installed) { $installed } else { $local }

function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Line { Say ('-' * 60) 'DarkGray' }

Say ''
Say '=== 관리 컴퓨터 연결 확인 ===' 'Cyan'
Say "설정 파일: $cfgPath"
try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Say "설정 파일을 읽을 수 없어요. 쉼표(,)나 따옴표(`")가 빠졌는지 확인하세요." 'Red'; return }

$url = ([string]$cfg.ServerUrl).Trim().TrimEnd('/')
Say "관리 컴퓨터 주소(ServerUrl): $url" 'White'
Line

if ($url -match '관리컴퓨터이름' -or $url -eq 'http://192.168.0.10:8787') {
    Say '⚠ 주소가 설명서의 "예시 주소" 그대로일 수 있어요!' 'Yellow'
    Say '  관리 컴퓨터에서 check-server.bat 을 실행하면 진짜 주소가 나옵니다.' 'Yellow'
    Line
}

try { $uri = [Uri]$url; $hostName = $uri.Host; $port = $uri.Port }
catch { Say '주소 모양이 잘못됐어요. 예: http://192.168.0.25:8787' 'Red'; return }

# 이 PC의 IP
$myIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress)
Say ("이 PC의 IP: {0}" -f ($myIps -join ', '))
if ($hostName -match '^\d+\.\d+\.\d+\.\d+$') {
    $prefix = ($hostName -split '\.')[0..2] -join '.'
    if (-not ($myIps | Where-Object { $_ -like "$prefix.*" })) {
        Say "⚠ 관리 컴퓨터($hostName)와 이 PC의 IP 앞자리가 달라요." 'Yellow'
        Say '  같은 공유기(같은 와이파이/같은 랜선 망)에 연결돼 있는지 확인하세요.' 'Yellow'
    }
}
Line

Say "1) 관리 컴퓨터($hostName)가 네트워크에 보이나요?"
$pingOk = $false
try { $pingOk = Test-Connection -ComputerName $hostName -Count 2 -Quiet -ErrorAction SilentlyContinue } catch { }
if ($pingOk) { Say '   → 보여요 (OK)' 'Green' } else { Say '   → 응답 없음 (꺼져 있거나, 응답을 막아 둔 것일 수 있어요)' 'Yellow' }

Say "2) 관리 프로그램 문(포트 $port)이 열려 있나요?"
$tcpOk = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ar = $tcp.BeginConnect($hostName, $port, $null, $null)
    $tcpOk = $ar.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected
    $tcp.Close()
} catch { }
if ($tcpOk) { Say '   → 열려 있어요 (OK)' 'Green' } else { Say '   → 닫혀 있어요' 'Red' }

Say '3) 관리 프로그램이 대답하나요?'
$apiOk = $false
try { $apiOk = (Invoke-RestMethod -Uri "$url/api/ping" -Method Post -TimeoutSec 5).ok } catch { }
if ($apiOk) { Say '   → 대답해요 (OK)' 'Green' } else { Say '   → 대답 없음' 'Red' }
Line

if ($apiOk) {
    Say '✅ 연결 잘 돼요! 이 PC를 재부팅하면 로그인할 수 있어요.' 'Green'
} elseif ($pingOk -and -not $tcpOk) {
    Say '❌ 관리 컴퓨터는 켜져 있지만 관리 프로그램 문이 닫혀 있어요.' 'Red'
    Say '   → 관리 컴퓨터에서 check-server.bat 을 실행해 보세요.' 'White'
    Say '     (서버가 멈췄거나, 방화벽/백신(V3, 알약 등)이 막고 있을 수 있어요)' 'White'
} elseif (-not $pingOk -and -not $tcpOk) {
    Say '❌ 관리 컴퓨터를 찾을 수 없어요.' 'Red'
    Say '   → ① 관리 컴퓨터가 켜져 있나요?' 'White'
    Say '   → ② 주소(IP)가 맞나요? 관리 컴퓨터에서 check-server.bat 으로 확인하세요.' 'White'
    Say '   → ③ 두 컴퓨터가 같은 공유기에 연결돼 있나요?' 'White'
} else {
    Say '❌ 문은 열려 있지만 관리 프로그램이 대답하지 않아요.' 'Red'
    Say '   → 관리 컴퓨터를 재부팅하거나 install-server.bat 을 다시 실행해 보세요.' 'White'
}
Say ''
Say '주소를 고친 경우: client 폴더의 config.json 에서 ServerUrl 을 고친 뒤 install.bat 을 다시 실행하세요.' 'Cyan'
Say ''
