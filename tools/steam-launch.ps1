# 스팀 시작 옵션용 래퍼: 오버레이를 먼저 띄우고 게임을 실행한다.
# 스팀 시작 옵션 예시:
# powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\경로\majsoul-overlay\tools\steam-launch.ps1" %command%

if ($args.Count -eq 0) {
    # 게임 명령 없이 실행된 경우: 오버레이만 시작
    Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path (Split-Path $PSScriptRoot -Parent) 'app\majsoul-overlay.ps1')
    exit
}

$exe = $args[0]
$procName = [IO.Path]::GetFileNameWithoutExtension($exe)
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path (Split-Path $PSScriptRoot -Parent) 'app\majsoul-overlay.ps1'), '-GameProc', $procName

$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
& $exe @rest
