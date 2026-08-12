# 관리자 권한이 아니면 스스로 권한을 요청해 다시 실행
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '관리자 권한을 요청합니다. 나타나는 창에서 [예]를 눌러주세요...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath
        )
    } catch {
        Write-Host ''
        Write-Host '[오류] 관리자 권한 실행이 취소되었거나 실패했습니다.' -ForegroundColor Red
        Write-Host '설치하려면 이 파일을 마우스 오른쪽 클릭 → [관리자 권한으로 실행] 해 주세요.'
        Write-Host ''
        Write-Host '아무 키나 누르면 닫힙니다.'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
    exit
}

Write-Host 'OCR 언어 구성요소 설치를 시작합니다.' -ForegroundColor Cyan
Write-Host '⚠ 이 창을 클릭하지 마세요! 클릭하면 설치가 일시정지됩니다. (멈췄다면 Esc를 누르세요)' -ForegroundColor Yellow
Write-Host ''

# 한국어/영어/일본어는 OCR만, 중국어는 기반 언어팩(Basic) 선행 설치 필요
$caps = @(
    'Language.OCR~~~ko-KR~0.0.1.0',
    'Language.OCR~~~en-US~0.0.1.0',
    'Language.OCR~~~ja-JP~0.0.1.0',
    'Language.Basic~~~zh-CN~0.0.1.0',
    'Language.OCR~~~zh-CN~0.0.1.0',
    'Language.Basic~~~zh-TW~0.0.1.0',
    'Language.OCR~~~zh-TW~0.0.1.0'
)
foreach ($cap in $caps) {
    Write-Host "== $cap 설치 중... (몇 분 걸릴 수 있어요)"
    try {
        $null = Add-WindowsCapability -Online -Name $cap -ErrorAction Stop
        Write-Host '   완료' -ForegroundColor Green
    } catch {
        Write-Host "   실패: $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Host ''
Write-Host '현재 설치된 OCR 언어:' -ForegroundColor Cyan
Get-WindowsCapability -Online -Name 'Language.OCR*' | Where-Object State -eq 'Installed' |
    Select-Object Name, State | Format-Table -AutoSize | Out-String | Write-Host
Write-Host '설치 완료! 오버레이를 껐다 켜면 적용됩니다. 아무 키나 누르면 닫힙니다.'
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
