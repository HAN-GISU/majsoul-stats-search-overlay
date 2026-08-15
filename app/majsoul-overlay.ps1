# ═══════════════════════════════════════════════════════════
#  작혼 전적 검색 오버레이 (Majsoul Stats Search Overlay)
#  v1.1.1  |  © 2026 HAN-GISU (github.com/HAN-GISU)  |  MIT License
#  데이터: amae-koromo(雀魂牌谱屋) 공개 API — 게임에 개입하지 않음
# ═══════════════════════════════════════════════════════════

# ===================== 설정 =====================
$Nickname        = '여기에닉네임'    # 본인 닉네임 (오버레이 ⚙ 설정에서도 변경 가능)
$PlayerId        = 0                # 0이면 닉네임으로 자동 검색
$Modes           = '16.15.12.11.9.8' # 집계할 방: 8=금동 9=금남 11=옥동 12=옥남 15=왕좌동 16=왕좌남
$RefreshSeconds  = 60               # 내 전적 자동 갱신 주기(초), 최소 15초
$AutoScanMinutes = 0                # 상대 자동 스캔 주기(분), 0이면 자동 스캔 끄기 (F8로 수동)
# 단축키: F8 = 지금 화면 스캔해서 상대 전적 띄우기, F7 = 상대 박스 모두 닫기
# ================================================

# 본체는 app\ 아래 - 설치 루트(data\·engine\·문서·exe)는 상위 폴더 기준
$script:BaseDir = $PSScriptRoot
if (-not $script:BaseDir) { $script:BaseDir = (Get-Location).Path }   # 대화형/테스트 실행 대비
elseif ((Split-Path $script:BaseDir -Leaf) -eq 'app') { $script:BaseDir = Split-Path $script:BaseDir -Parent }
$script:AppDir = $script:BaseDir
# 버전은 이 파일 머리 주석에서 읽음 - 표기 관리 지점을 늘리지 않기 위해
$script:AppVer = ''
try { if (((Get-Content $PSCommandPath -TotalCount 6) -join ' ') -match 'v\d+\.\d+\.\d+') { $script:AppVer = $Matches[0] } } catch {}

# 런타임 생성 파일(설정·로그·스캔 결과 등)은 전부 data\ 하위로 - 루트를 깔끔하게 유지
$script:DataDir = Join-Path $script:BaseDir 'data'
try {
    if (-not (Test-Path $script:DataDir)) { $null = New-Item -ItemType Directory $script:DataDir }
    # 구버전이 루트에 남긴 런타임 파일 1회 이주
    foreach ($mpat in @('overlay-pos.json', 'scan-log*.txt', 'scan-result.json', 'scan-box.json', 'report-result.json',
                        'detail-result.json', 'paddle-debug.txt', 'scan-plate-*.png', 'stable-*.json', 'scan-stop.flag')) {
        Get-ChildItem (Join-Path $script:BaseDir $mpat) -ErrorAction SilentlyContinue | ForEach-Object {
            try { Move-Item $_.FullName (Join-Path $script:DataDir $_.Name) -Force } catch {}
        }
    }
} catch {}

Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class Native {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  public struct RECT { public int L, T, R, B; }
  public struct POINT { public int X, Y; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint procId);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
}
'@
$null = [Native]::SetProcessDPIAware()

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Api = 'https://5-data.amae-koromo.com/api/v2/pl4'
$MajorNames = @{ 1 = '초심'; 2 = '작사'; 3 = '작걸'; 4 = '작호'; 5 = '작성'; 6 = '혼천'; 7 = '혼천' }   # 7 = 신식 혼천(107xx, 세부 단계·별도 점수제)
$MaxPts = @{
    1 = @(20, 80, 200); 2 = @(600, 800, 1000); 3 = @(1200, 1400, 2000)
    4 = @(2800, 3200, 3600); 5 = @(4500, 7500, 9000)
}
$EpochStart = 1262304000000

# 안정단위 모드별 상수 (amae-koromo 원본 데이터)
$ModeNames = @{ 8 = '금동'; 9 = '금남'; 11 = '옥동'; 12 = '옥남'; 15 = '왕좌동'; 16 = '왕좌남' }
$ModeDelta = @{ 8 = @(40, 20, 0, 0); 9 = @(80, 40, 0, 0); 11 = @(55, 30, 0, 0); 12 = @(110, 55, 0, 0); 15 = @(60, 30, 0, 0); 16 = @(120, 60, 0, 0) }
$PenaltyS = @(0, 0, 0, 20, 40, 60, 80, 100, 120, 165, 180, 195, 210, 225, 240, 255)   # 남장 4위 페널티 (단위 인덱스)
$PenaltyE = @(0, 0, 0, 10, 20, 30, 40, 50, 60, 80, 90, 100, 110, 120, 130, 140)       # 동장
$EastModes = @(8, 11, 15)

$script:CachedId = 0
$script:TodayDate = $null
$script:TodayCount = -1
$script:TodaySeq = @()
$script:TodayPts = @()
$script:TodayLvls = @()
$script:BaselinePt = $null
$script:BaselineTotal = $null   # 기준 시점까지의 총 국수 (서버 집계 지연 감지용)
$script:BaseCheckedAt = $null   # 마지막으로 기준을 재조회한 시점의 전체 국수
$script:SeqDoneMs = $null       # 순위 시퀀스를 복원해둔 시점 (이후 구간만 추가 조회)
$script:AnnouncedCount = -1  # 토스트 알림 기준 판 수
$script:LastShownPt = $null
$script:SessionStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:DayReports = @{}  # 과거 날짜 리포트 캐시
$script:NickCache = @{}   # OCR 토큰 -> 플레이어 id (미스는 $false)
$script:ExtCache = $null  # 통산 통계 캐시
$script:ExtCacheTime = [DateTime]::MinValue
$script:BasisCache = @{}  # id -> 최근 N국 기준 시작 시각 캐시
$script:SyncingUI = $false
$script:NetBusy = $false        # 갱신(네트워크) 진행 중 재진입 방지
$script:GameToastFired = $false # 이번 갱신에서 대국 반영 토스트가 떴는지
$script:Settings = @{
    Stable = $true; Danger = $true; RankColors = $false; Streak = $true; Spark = $true; Toast = $true
    ShowRank = $true; ShowGoal = $true; ShowGame = $true; ShowStat1 = $true; ShowStat2 = $true; ShowStat3 = $true; ShowStat4 = $true
    MortalWatch = $false; ShowTobi = $true; Anom = $true; OppMinN = 300
    AnomMode = 'pulse'; AnomHigh = '#FFE05252'; AnomLow = '#FFE0B830'
    AnomOffMe = ''; AnomOffOpp = ''; AnomCMe = ''; AnomCOpp = ''; AnomPctItems = ''
    DispOffMe = ''; DispOffOpp = ''
    UiScale = 1.0; BoxRatioX = 100; BoxRatioY = 100; FontScale = 100; SessionBase = 'today'; AnomPct = 20; BadgeDefs = ''; BadgeOn = $true
    UiScaleOpp = -1.0; BoxRatioXOpp = -1; BoxRatioYOpp = -1; FontScaleOpp = -1   # 상대 박스 개별값 (-1 = 내 박스 값 따름)
    BaseCustomKind = 'relday'; BaseCustomDays = -1; BaseCustomHours = -6; BaseCustomAbs = ''   # 기준 시점 '직접 지정'
    MyStableMode = 'auto'; OppStableMode = 'auto'; StableColors = ''; StableDual = $true; StableDualThrone = $true; StableRoomFirst = $true; TextColor = ''
    BgColor = ''; BgAlpha = -1   # (구버전 호환용 - 시작 시 테마별 키로 이주)
    TextColorLight = ''; TextColorDark = ''; TextColorTrans = ''
    BgColorLight = ''; BgColorDark = ''; BgColorTrans = ''
    BgAlphaLight = -1; BgAlphaDark = -1; BgAlphaTrans = -1
    MyBasis = 'm1'; OppBasis = 'm1'; MyStatScope = 'all'; OppStatScope = 'all'; KeyScan = 'F8'; KeyClose = 'F7'; KeyExit = 'F10'; DailyGoal = 0
}
$script:Presets = @{}     # 이름 -> @{ Theme; Settings }
$script:OppCache = @{}    # id -> 전적 데이터
$script:OppWindows = @{}  # id -> WPF 창

# ---------------- amae-koromo API ----------------

# UI 스레드가 네트워크 응답을 기다리는 동안에도 메시지 펌프를 돌려 오버레이가 멈추지 않게 하는 헬퍼.
# GUI 프로세스에서만 $script:UiPump가 켜지고, 자식 프로세스(-ScanOnce/-ReportOnce/-DetailOnce)는 기존 동기 방식 그대로.
function Invoke-UiPump {
    param([int]$Ms = 0)
    # 수면 없이 디스패처 프레임을 타이머로 종료 - 대기 중에도 애니메이션·클릭이 완전히 살아 있음
    # (이전 구현은 15ms Start-Sleep 루프라 긴 API 대기 시 UI가 얼어붙고 CPU를 태웠음)
    $frame = New-Object Windows.Threading.DispatcherFrame
    if ($Ms -le 0) {
        $null = [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background,
            [action] { $frame.Continue = $false }.GetNewClosure())
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        return
    }
    $t = New-Object Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds([math]::Max(10, $Ms))
    $t.Add_Tick({
        $t.Stop()
        $frame.Continue = $false
    }.GetNewClosure())
    $t.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-Api {
    param([int]$Ms)
    if ($script:UiPump) { Invoke-UiPump $Ms } else { Start-Sleep -Milliseconds $Ms }
}

function Invoke-Api {
    param([string]$Uri, [int]$TimeoutSec = 15)
    if (-not $script:UiPump) { return Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec }
    $task = $script:Http.GetStringAsync($Uri)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while (-not $task.IsCompleted) {
        if ([DateTime]::UtcNow -gt $deadline) { throw "API 시간 초과: $Uri" }
        Invoke-UiPump 30
    }
    if ($task.IsFaulted -or $task.IsCanceled) {
        $ex = $null
        if ($task.Exception) { $ex = $task.Exception.InnerException }
        if (-not $ex) { $ex = New-Object Exception "API 요청 실패: $Uri" }
        throw $ex
    }
    return ($task.Result | ConvertFrom-Json)
}

function Get-RangeStats {
    param($Id, $StartMs, $EndMs, [string]$ModeFilter = '')
    $mq = $script:Modes
    if ($ModeFilter) { $mq = $ModeFilter }
    foreach ($try in 1..3) {
        try {
            return Invoke-Api "$Api/player_stats/$Id/$StartMs/$EndMs`?mode=$mq" 15
        } catch {
            # 속도 제한(429/530) 대비 점진적 대기
            Wait-Api (500 * $try)
        }
    }
    return $null
}

function Get-PlayerId {
    if ($script:PlayerId) { return $script:PlayerId }
    if ($script:CachedId) { return $script:CachedId }
    $found = Invoke-Api "$Api/search_player/$([uri]::EscapeDataString($script:Nickname))?limit=20" 15
    $exact = @($found | Where-Object { $_.nickname -eq $script:Nickname })
    if ($exact.Count -eq 0) { $exact = @($found) }
    if ($exact.Count -eq 0) { throw "플레이어를 찾을 수 없습니다: $($script:Nickname)" }
    $script:CachedId = $exact[0].id
    return $script:CachedId
}

function Get-RankSequence {
    param($Id, $FromMs, $ToMs, $Depth)
    $st = Get-RangeStats $Id $FromMs $ToMs
    if (-not $st -or $st.count -eq 0) { return @() }
    $rates = @($st.rank_rates)
    if ($st.count -eq 1) {
        $best = 0
        for ($i = 1; $i -lt $rates.Count; $i++) { if ($rates[$i] -gt $rates[$best]) { $best = $i } }
        # 이 구간 종료 시점의 유효 단위/pt도 함께 수집 (누적 수지 그래프용)
        $eff = Get-EffectiveLevel $st.level
        return , @{ Rank = ($best + 1); Pt = [int]$eff.Pt; Lvl = [int]$eff.Id }
    }
    if (($ToMs - $FromMs) -le 120000 -or $Depth -ge 14) {
        $out = @()
        for ($i = 0; $i -lt $rates.Count; $i++) {
            $n = [int][math]::Round($rates[$i] * $st.count)
            for ($j = 0; $j -lt $n; $j++) { $out += , @{ Rank = ($i + 1); Pt = $null; Lvl = $null } }
        }
        return $out
    }
    Wait-Api 150
    $mid = [long](($FromMs + $ToMs) / 2)
    return @(Get-RankSequence $Id $FromMs $mid ($Depth + 1)) + @(Get-RankSequence $Id $mid $ToMs ($Depth + 1))
}

# "최근 N국" 기준 시작 시각을 이분 탐색으로 찾기 (count(start,end)가 N에 수렴하도록)
function Get-BasisStartMs {
    param($Id, $N, $EndMs, $Iters)
    $lo = [long]$EpochStart
    $hi = [long]$EndMs
    $full = Get-RangeStats $Id $lo $EndMs
    if (-not $full -or $full.count -le $N) { return [long]$EpochStart }
    for ($i = 0; $i -lt $Iters; $i++) {
        $mid = [long](($lo + $hi) / 2)
        $st = Get-RangeStats $Id $mid $EndMs
        $c = 0
        if ($st) { $c = $st.count }
        if ($c -ge $N) { $lo = $mid } else { $hi = $mid }
        Wait-Api 80
    }
    return $lo
}

# 기준 시점 epoch ms - 오늘 0시 / 실행 시점 / 직접 지정(고정 날짜·시각, 오늘 ±N일, 지금 ±N시간)
# 'SessionBase -eq ...' 문자열 비교를 각처에 흩뿌리지 않도록 여기서만 계산
function Get-BaseStartMs {
    $sb = [string]$script:Settings.SessionBase
    if ($sb -eq 'session') { return [long]$script:SessionStartMs }
    if ($sb -eq 'custom') {
        try {
            switch ([string]$script:Settings.BaseCustomKind) {
                'relday' { return [DateTimeOffset]::new([DateTime]::Today.AddDays([int]$script:Settings.BaseCustomDays)).ToUnixTimeMilliseconds() }
                'relhr' {
                    # 흐르는 창이라 매 갱신마다 미세하게 움직임 - 10분 단위로 고정해 재집계 빈도를 묶음
                    $ms = [DateTimeOffset]::UtcNow.AddHours([int]$script:Settings.BaseCustomHours).ToUnixTimeMilliseconds()
                    return [long]([math]::Floor($ms / 600000) * 600000)
                }
                default {
                    $dt = [DateTime]::ParseExact([string]$script:Settings.BaseCustomAbs, 'yyyy-MM-dd H', [Globalization.CultureInfo]::InvariantCulture)
                    return [DateTimeOffset]::new($dt).ToUnixTimeMilliseconds()
                }
            }
        } catch {}
    }
    return [DateTimeOffset]::new([DateTime]::Today).ToUnixTimeMilliseconds()
}

function Get-BasisStart {
    param($Id, $EndMs, [string]$Basis, $Iters = 18)
    switch ($Basis) {
        'base' {
            # 기준 시점(오늘 0시/실행 시점/직접 지정) 이후만 집계
            return [long](Get-BaseStartMs)
        }
        'm1' { return [DateTimeOffset]::UtcNow.AddMonths(-1).ToUnixTimeMilliseconds() }
        'm3' { return [DateTimeOffset]::UtcNow.AddMonths(-3).ToUnixTimeMilliseconds() }
        'm6' { return [DateTimeOffset]::UtcNow.AddMonths(-6).ToUnixTimeMilliseconds() }
        'y1' { return [DateTimeOffset]::UtcNow.AddYears(-1).ToUnixTimeMilliseconds() }
    }
    if ($Basis -notmatch '^g(\d+)$') { return [long]$EpochStart }
    $n = [int]$Matches[1]
    $key = "$Id|$Basis"
    $c = $script:BasisCache[$key]
    if ($c -and ((Get-Date) - $c.Time).TotalMinutes -lt 30) { return $c.Start }
    $start = Get-BasisStartMs $Id $n $EndMs $Iters
    $script:BasisCache[$key] = @{ Start = $start; Time = (Get-Date) }
    return $start
}

# 단위(랭크)별 평균 참조표 — 특이 수치 강조용 (금의방+ 전체 통계 근사치)
$script:StatRef = @{
    2 = @{ hr = 0.215; dl = 0.135; ryu = 0.47; ri = 0.185; fu = 0.29; dama = 0.10; dp = 6100; dpl = 5700; gs = 0.73; sente = 0.68; tobi = 0.10; wt = 11.9; avgpl = 2.5 }
    3 = @{ hr = 0.215; dl = 0.130; ryu = 0.47; ri = 0.185; fu = 0.30; dama = 0.10; dp = 6250; dpl = 5750; gs = 0.74; sente = 0.69; tobi = 0.09; wt = 11.8; avgpl = 2.5 }
    4 = @{ hr = 0.210; dl = 0.125; ryu = 0.47; ri = 0.185; fu = 0.30; dama = 0.105; dp = 6350; dpl = 5800; gs = 0.75; sente = 0.70; tobi = 0.085; wt = 11.7; avgpl = 2.5 }
    5 = @{ hr = 0.205; dl = 0.118; ryu = 0.47; ri = 0.180; fu = 0.30; dama = 0.11; dp = 6450; dpl = 5850; gs = 0.76; sente = 0.71; tobi = 0.08; wt = 11.6; avgpl = 2.5 }
}

# 강조 대상 통계 항목 (고급 설정에 나열되는 순서)
$script:AnomItems = @(
    @{ K = 'hr'; N = '화료율' }, @{ K = 'dl'; N = '방총율' }, @{ K = 'ryu'; N = '유국텐파이율' },
    @{ K = 'ri'; N = '리치율' }, @{ K = 'fu'; N = '후로율' }, @{ K = 'dama'; N = '다마화료율' },
    @{ K = 'dp'; N = '평균타점' }, @{ K = 'dpl'; N = '평균방총점' }, @{ K = 'tobi'; N = '토비율' },
    @{ K = 'gs'; N = '우형리치율' }, @{ K = 'sente'; N = '선제리치율' }, @{ K = 'wt'; N = '평균화료순' },
    @{ K = 'avgpl'; N = '평균순위' }
)

function Test-AnomEnabled {
    param([string]$K, [bool]$IsOpp)
    $off = [string]$(if ($IsOpp) { $script:Settings.AnomOffOpp } else { $script:Settings.AnomOffMe })
    if (-not $off) { return $true }
    return (@($off -split ',') -notcontains $K)
}

# 항목별 색상 재정의 맵 ("키=높음|낮음,...")
function Get-AnomCMap {
    param([bool]$IsOpp)
    $s = [string]$(if ($IsOpp) { $script:Settings.AnomCOpp } else { $script:Settings.AnomCMe })
    $m = @{}
    foreach ($p in @($s -split ',' | Where-Object { $_ })) {
        $kv = $p -split '='
        if ($kv.Count -lt 2) { continue }
        $hl = $kv[1] -split '\|'
        $m[$kv[0]] = @{ H = [string]$hl[0]; L = [string]$(if ($hl.Count -gt 1) { $hl[1] } else { '' }) }
    }
    return $m
}

function Set-AnomC {
    param([bool]$IsOpp, [string]$K, [string]$Which, [string]$Hex)
    $m = Get-AnomCMap $IsOpp
    if (-not $m.ContainsKey($K)) { $m[$K] = @{ H = ''; L = '' } }
    if ($Which -eq 'H') { $m[$K].H = $Hex } else { $m[$K].L = $Hex }
    $parts = @()
    foreach ($k in @($m.Keys)) { $parts += ('{0}={1}|{2}' -f $k, $m[$k].H, $m[$k].L) }
    $val = ($parts -join ',')
    if ($IsOpp) { $script:Settings.AnomCOpp = $val } else { $script:Settings.AnomCMe = $val }
}

# '낮을수록 좋은' 지표 - 기본 색 매핑을 반대로 적용해 색의 의미(빨강=강한 방향, 금색=약한 방향)를 전 항목 일관되게
$script:AnomLowGood = @('dl', 'dpl', 'tobi', 'wt', 'avgpl')

function Get-AnomColor {
    param([string]$K, [int]$Hot, [bool]$IsOpp)
    $m = Get-AnomCMap $IsOpp
    $hex = ''
    if ($m.ContainsKey($K)) { $hex = [string]$(if ($Hot -eq 2) { $m[$K].H } else { $m[$K].L }) }
    if (-not $hex) {
        # 항목별 커스텀이 없을 때만 방향 뒤집기 (커스텀 H/L은 사용자가 지정한 그대로)
        $eff = $Hot
        if ($script:AnomLowGood -contains $K) { $eff = $(if ($Hot -eq 2) { 1 } else { 2 }) }
        $hex = [string]$(if ($eff -eq 2) { $script:Settings.AnomHigh } else { $script:Settings.AnomLow })
        if (-not $hex) { $hex = $(if ($eff -eq 2) { '#FFE05252' } else { '#FFE0B830' }) }
    }
    if (-not $hex) { $hex = $(if ($Hot -eq 2) { '#FFE05252' } else { '#FFE0B830' }) }
    return $hex
}

# 0=보통, 1=평균보다 낮음, 2=평균보다 높음
# 항목별 기본 문턱값(%) - 실측 분포 기반 (활동 유저 19명·300국+·1년 창, 변동계수의 약 1.5배)
# 지표별 변동 폭이 극단적으로 달라 전역 한 값으로는 어떤 항목은 늘 발동, 어떤 항목은 영영 미발동
# (리치율은 실측 19% ≈ 전역 기본 20%라 별도 기본 없이 전역을 따름)
$script:AnomPctDefaults = @{
    hr = 11; dl = 25; ryu = 30; ri = 30; fu = 35; dama = 80
    dp = 11; dpl = 6; tobi = 60; gs = 12; sente = 8
    wt = 3; avgpl = 5
}

# 항목별 강조 문턱값(%) 해석: 개별 설정 > 항목 기본값 > 전역 설정
function Get-AnomPctFor {
    param([string]$K)
    $s = [string]$script:Settings.AnomPctItems
    if ($s) {
        foreach ($kv in ($s -split ',')) {
            $p = @($kv -split '=')
            if ($p.Count -eq 2 -and [string]$p[0] -eq $K) {
                $v = 0
                if ([int]::TryParse([string]$p[1], [ref]$v) -and $v -gt 0) { return $v }
            }
        }
    }
    $d = $script:AnomPctDefaults[$K]
    if ($null -ne $d) { return [int]$d }
    $g = [int]$script:Settings.AnomPct
    if ($g -le 0) { $g = 20 }
    return $g
}

function Set-AnomPctFor {
    param([string]$K, [int]$V)
    $parts = @()
    foreach ($kv in (([string]$script:Settings.AnomPctItems) -split ',')) {
        if ($kv -and @($kv -split '=')[0] -ne $K) { $parts += $kv }
    }
    if ($V -gt 0) { $parts += "$K=$V" }
    $script:Settings.AnomPctItems = ($parts -join ',')
}

function Get-StatHot {
    param([string]$K, [double]$V, [int]$Major, [bool]$IsOpp)
    if (-not $script:Settings.Anom) { return 0 }
    if (-not (Test-AnomEnabled $K $IsOpp)) { return 0 }
    $m = $Major
    if (-not $script:StatRef.ContainsKey($m)) { $m = 3 }
    if (-not $script:StatRef[$m].ContainsKey($K)) { return 0 }
    $ref = [double]$script:StatRef[$m][$K]
    if ($ref -le 0 -or $V -le 0) { return 0 }
    $ratio = $V / $ref
    $pct = [double](Get-AnomPctFor $K)
    $t = $pct / 100.0
    if ($ratio -ge (1 + $t)) { return 2 }   # 평균보다 높음
    if ($ratio -le (1 - $t)) { return 1 }   # 평균보다 낮음
    return 0
}

# 통계 항목 구조화 (줄 번호/키/값/표시 텍스트)
function Get-StatParts {
    param($Stats, $Ext)
    if (-not $Ext) { return @() }
    # 연대율(1·2위 합산율)·라스율(4위율) - player_stats의 rank_rates에서 직접 계산
    $rentai = 0.0
    $lasu = 0.0
    $rrR = @($Stats.rank_rates)
    if ($rrR.Count -ge 2) { $rentai = [double]$rrR[0] + [double]$rrR[1] }
    if ($rrR.Count -ge 4) { $lasu = [double]$rrR[3] }
    return @(
        @{ L = 1; K = 'hr'; V = [double]$Ext.'和牌率'; T = ('화료율 {0:P1}' -f [double]$Ext.'和牌率') },
        @{ L = 1; K = 'dl'; V = [double]$Ext.'放铳率'; T = ('방총율 {0:P1}' -f [double]$Ext.'放铳率') },
        @{ L = 1; K = 'ryu'; V = [double]$Ext.'流听率'; T = ('유국텐파이율 {0:P1}' -f [double]$Ext.'流听率') },
        @{ L = 2; K = 'ri'; V = [double]$Ext.'立直率'; T = ('리치율 {0:P1}' -f [double]$Ext.'立直率') },
        @{ L = 2; K = 'fu'; V = [double]$Ext.'副露率'; T = ('후로율 {0:P1}' -f [double]$Ext.'副露率') },
        @{ L = 2; K = 'dama'; V = [double]$Ext.'默听率'; T = ('다마화료율 {0:P1}' -f [double]$Ext.'默听率') },
        @{ L = 3; K = 'dp'; V = [double]$Ext.'平均打点'; T = ('평균타점 {0:N0}' -f [double]$Ext.'平均打点') },
        @{ L = 3; K = 'dpl'; V = [double]$Ext.'平均铳点'; T = ('평균방총점 {0:N0}' -f [double]$Ext.'平均铳点') },
        @{ L = 3; K = 'tobi'; V = [double]$Stats.negative_rate; T = ('토비율 {0:P1}' -f [double]$Stats.negative_rate) },
        @{ L = 5; K = 'wt'; V = [double]$Ext.'和了巡数'; T = ('평균화료순 {0:N2}' -f [double]$Ext.'和了巡数') },
        @{ L = 5; K = 'avgpl'; V = [double]$Stats.avg_rank; T = ('평균순위 {0:N2}' -f [double]$Stats.avg_rank) },
        @{ L = 5; K = 'rentai'; V = $rentai; T = ('연대율 {0:P1}' -f $rentai) },
        @{ L = 5; K = 'lasu'; V = $lasu; T = ('라스율 {0:P1}' -f $lasu) },
        @{ L = 4; K = 'gs'; V = [double]$Ext.'立直好型'; T = ('우형리치율 {0:P1}' -f [double]$Ext.'立直好型') },
        @{ L = 4; K = 'gs2'; V = [double]$Ext.'立直好型2'; T = ('우형2 {0:P1}' -f [double]$Ext.'立直好型2') },
        @{ L = 4; K = 'sente'; V = [double]$Ext.'先制率'; T = ('선제리치율 {0:P1}' -f [double]$Ext.'先制率') }
    )
}

# 국당 순수 기대수지 = 기대수지 - 4위율×현재 단위의 4위 페널티 (승단 카운트다운·국당수지 표시 공용)
# 혼천(별도 pt 체계)이나 4위 표본이 없는 경우엔 $null
function Get-NetPerGame {
    param($Stable, $Stats, [int]$LvlId)
    if (-not $Stable -or -not $Stats) { return $null }
    $maj = ([int][math]::Floor($LvlId / 100)) % 100
    $min = [int]($LvlId % 100)
    if ($maj -lt 1 -or $maj -ge 6) { return $null }
    $r = @($Stats.rank_rates)
    if ($r.Count -lt 4) { return $null }
    # 4위율 0(오늘 4위 없음 등)이어도 수지는 계산됨 - 페널티 항만 0이 됨
    $pidx = ($maj - 1) * 3 + ($min - 1)
    $penC = 0.0
    $penArr = @($Stable.Pen)
    if ($pidx -ge 0 -and $pidx -lt $penArr.Count) { $penC = [double]$penArr[$pidx] }
    return ([double]$Stable.E - ([double]$r[3] * $penC))
}

# 스타일 배지 — 사용자가 조건/문턱값을 편집하고 새로 추가할 수 있음
$script:DefaultBadges = '🗡|공격형|hr|ge|0.24;🛡|수비형|dl|le|0.11;⚡|후로형|fu|ge|0.40;🎴|멘젠형|fu|le|0.30;🥷|다마장인|dama|ge|0.15'
$script:BadgeStatNames = @{
    hr = '화료율'; dl = '방총율'; ryu = '유국텐파이율'; ri = '리치율'; fu = '후로율'; dama = '다마화료율'
    dp = '평균타점'; dpl = '평균방총점'; tobi = '토비율'; gs = '우형리치율'; sente = '선제리치율'
    wt = '평균화료순'; games = '전적 수'
}
$script:BadgePointKeys = @('dp', 'dpl', 'games', 'wt')

function Get-BadgeDefs {
    $s = [string]$script:Settings.BadgeDefs
    if (-not $s) { $s = $script:DefaultBadges }
    $out = @()
    foreach ($p in @($s -split ';' | Where-Object { $_ })) {
        $f = $p -split '\|'
        if ($f.Count -lt 5) { continue }
        $out += , @{ Icon = [string]$f[0]; Name = [string]$f[1]; K = [string]$f[2]; Op = [string]$f[3]; V = [double]$f[4] }
    }
    return $out
}

function Set-BadgeDefs {
    param($Defs)
    $script:Settings.BadgeDefs = (@($Defs | ForEach-Object { '{0}|{1}|{2}|{3}|{4}' -f $_.Icon, $_.Name, $_.K, $_.Op, $_.V }) -join ';')
}

function Get-StatValueMap {
    param($Stats, $Ext)
    $m = @{}
    if ($Stats) {
        $m['tobi'] = [double]$Stats.negative_rate
        $m['games'] = [double]$Stats.count
    }
    if ($Ext) {
        $m['hr'] = [double]$Ext.'和牌率'; $m['dl'] = [double]$Ext.'放铳率'; $m['ryu'] = [double]$Ext.'流听率'
        $m['ri'] = [double]$Ext.'立直率'; $m['fu'] = [double]$Ext.'副露率'; $m['dama'] = [double]$Ext.'默听率'
        $m['dp'] = [double]$Ext.'平均打点'; $m['dpl'] = [double]$Ext.'平均铳点'
        $m['gs'] = [double]$Ext.'立直好型'; $m['sente'] = [double]$Ext.'先制率'
        $m['wt'] = [double]$Ext.'和了巡数'
    }
    return $m
}

function Get-StyleBadges {
    param($Stats, $Ext)
    $vals = Get-StatValueMap $Stats $Ext
    $b = @()
    foreach ($d in (Get-BadgeDefs)) {
        $k = [string]$d.K
        if (-not $vals.ContainsKey($k)) { continue }
        $v = [double]$vals[$k]
        if ($v -le 0) { continue }
        $hit = $(if ([string]$d.Op -eq 'le') { $v -le [double]$d.V } else { $v -ge [double]$d.V })
        if ($hit) { $b += ([string]$d.Icon + [string]$d.Name) }
    }
    return ($b -join ' ')
}

function Get-BasisLabel {
    param([string]$Basis)
    switch ($Basis) {
        'base' {
            $sb2 = [string]$script:Settings.SessionBase
            if ($sb2 -eq 'session') { return '실행 후' }
            if ($sb2 -eq 'custom') {
                switch ([string]$script:Settings.BaseCustomKind) {
                    'relday' {
                        $d0 = [int]$script:Settings.BaseCustomDays
                        if ($d0 -eq 0) { return '오늘' }
                        if ($d0 -lt 0) { return ('{0}일 전부터' -f (-$d0)) }
                        return ('{0}일 후부터' -f $d0)
                    }
                    'relhr' {
                        $h0 = [int]$script:Settings.BaseCustomHours
                        if ($h0 -lt 0) { return ('최근 {0}시간' -f (-$h0)) }
                        return ('{0}시간 후부터' -f $h0)
                    }
                    default {
                        try {
                            $dt2 = [DateTime]::ParseExact([string]$script:Settings.BaseCustomAbs, 'yyyy-MM-dd H', [Globalization.CultureInfo]::InvariantCulture)
                            return $dt2.ToString('M/d H시')
                        } catch { return '지정 시점' }
                    }
                }
            }
            return '오늘'
        }
        'm1' { return '1개월' }
        'm3' { return '3개월' }
        'm6' { return '6개월' }
        'y1' { return '1년' }
        'g50' { return '50국' }
        'g100' { return '100국' }
        'g200' { return '200국' }
        default { return '전체' }
    }
}

# 단일 모드(또는 그룹) 국수 조회 - 404는 기록 없음(0)으로 처리
function Get-ModeCount {
    param($Id, $StartMs, $EndMs, [string]$Mq)
    $waits = @(600, 1500, 0)
    for ($t = 0; $t -lt 3; $t++) {
        try {
            $r = Invoke-Api "$Api/player_stats/$Id/$StartMs/$EndMs`?mode=$Mq" 12
            if ($r) { return [int]$r.count }
            return 0
        } catch {
            $code = 0
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            if ($code -eq 404) { return 0 }
            if ($waits[$t]) { Wait-Api $waits[$t] }
        }
    }
    # 조회 실패는 0국이 아님 - 호출부는 -1(불명)을 '전적 부족' 판정에 쓰면 안 됨
    # (429 폭주 시 319국 유저가 '금탁 0국 부족'으로 표시되던 사고)
    return -1
}

# 그룹 내 남/동 세부 다수결 (남장 모드 id를 받아 남 또는 동 반환)
# 동점(조회 실패로 0=0 포함)이면 PreferEast(현재 방의 동/남)를 따름 - 남장 고정 시
# 금동 온리 유저가 조회 실패 순간에 '금남 2국' 같은 엉뚱한 기준으로 새는 사고 방지
function Get-SubMode {
    param($Id, $StartMs, $EndMs, [int]$South, [bool]$PreferEast = $false)
    $sc = Get-ModeCount $Id $StartMs $EndMs "$South"
    $ec = Get-ModeCount $Id $StartMs $EndMs "$($South - 1)"
    if ($ec -gt $sc) { return ($South - 1) }
    if ($sc -gt $ec) { return $South }
    if ($PreferEast) { return ($South - 1) }
    return $South
}

# OCR로 확정된 방에 입장 불가능한 단위면 $false - 오매칭 기각용 (작걸 'sess'가 왕좌탁 상대로 잡히던 사고)
# 입장 범위: 금=작걸·작호, 옥=작호·작성, 왕좌=작성·혼천(구6·신7). 방 미감지/비단위전은 검사 안 함
function Test-RoomEntryOk {
    param($LvlId)
    $room = [int]$script:ScanRoomMode
    if ($room -le 0) { return $true }
    $maj = ([int][math]::Floor(([int]$LvlId) / 100)) % 100
    if ($maj -le 0) { return $true }
    if ($room -ge 15) { return ($maj -ge 5) }
    if ($room -ge 11) { return ($maj -eq 4 -or $maj -eq 5) }
    if ($room -ge 8) { return ($maj -eq 3 -or $maj -eq 4) }
    return $true
}

# 화면 OCR 토큰에서 현재 방 감지 ('금탁·4인 동풍전' 등) → 모드 id, 실패 시 0
function Get-RoomModeFromTokens {
    param($Tokens)
    $roomMap = @{ '금' = 9; '옥' = 12; '왕좌' = 16 }
    foreach ($tk in $Tokens) {
        $t = ([string]$tk.Text) -replace '\s', ''
        # 비단위전(친선전·대회전 등): 방 개념 없음 → 각자 다수결로 처리
        if ($t -match '(친선|대회|교류)전?') { return -1 }
        if ($t -match '(금|옥|왕좌)탁') {
            $grp = [string]$Matches[1]
            if ($t -match '(동풍|반장)전') {
                $isEastRoom = ([string]$Matches[1] -eq '동풍')
                $south = [int]$roomMap[$grp]
                if ($isEastRoom) { return ($south - 1) }
                return $south
            }
        }
    }
    return 0
}

# 주력 모드 판별: 기준 구간의 그룹별 국수 비교(금/옥/왕좌 → 남/동)
# (player_records 엔드포인트는 서버 측 차단이라 국수 다수결로 대체)
function Get-DominantMode {
    param($Id, $StartMs, $EndMs, [int]$LvlId = 0)
    $cnt = {
        param($mq)
        foreach ($try in 1..2) {
            try {
                $r = Invoke-Api "$Api/player_stats/$Id/$StartMs/$EndMs`?mode=$mq" 12
                if ($r) { return [int]$r.count }
                return 0
            } catch {
                $code = 0
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                if ($code -eq 404) { return 0 }   # 해당 모드 기록 없음
                Wait-Api 500
            }
        }
        return 0
    }
    $gold = & $cnt '9.8'
    $jade = & $cnt '12.11'
    $throne = & $cnt '16.15'
    $grp = ''
    if ($gold -ge $jade -and $gold -ge $throne -and $gold -gt 0) { $grp = '9.8' }
    elseif ($throne -ge $jade -and $throne -gt 0) { $grp = '16.15' }
    elseif ($jade -gt 0) { $grp = '12.11' }
    if (-not $grp) {
        # 기록 없음: 단위 기반 폴백
        $maj = ([int][math]::Floor($LvlId / 100)) % 100
        switch ($maj) { 4 { return 12 } 5 { return 12 } 6 { return 16 } default { return 9 } }
    }
    $south = @{ '9.8' = 9; '12.11' = 12; '16.15' = 16 }[$grp]
    $sc = & $cnt "$south"
    $ec = & $cnt "$($south - 1)"
    if ($ec -gt $sc) { return ($south - 1) }
    return $south
}

# Based on amae-koromo — estimateStableLevel2()
#   https://github.com/SAPikachu/amae-koromo
#   Copyright (c) 2020 SAPikachu, MIT License — see THIRD-PARTY-NOTICES.txt
#   (모드별 순위 보너스·4위 페널티 표 적용과 금탁·동장 연속값 확장은 자체 수정)
# 안정단위 추정: 버틸 수 있는 4위 페널티 p = 기대수지/4위율 을 페널티 표로 역산 (작호1 = 1)
function Get-StableLevel {
    param($Stats, [int]$ModeId = 12)
    $r = @($Stats.rank_rates)
    $s = @($Stats.rank_avg_score)
    if ($r.Count -lt 4 -or $s.Count -lt 4) { return $null }
    $isEast = ($EastModes -contains $ModeId)
    $pen = $PenaltyS
    if ($isEast) { $pen = $PenaltyE }
    $md = $ModeDelta[$ModeId]
    if (-not $md) { $md = $ModeDelta[12] }
    $isGold = ($ModeId -le 9)
    $uma = @(15, 5, -5, -15)
    $e = 0.0
    for ($i = 0; $i -lt 4; $i++) {
        if ($null -eq $s[$i]) { continue }
        $d = [math]::Ceiling(($s[$i] - 25000) / 1000 + $uma[$i]) + $md[$i]
        $e += $r[$i] * $d
    }
    if (-not $r[3]) {
        # 4위 표본이 없으면 안정단위는 상한 처리하되, 기대수지 E는 실측 그대로 (국당수지 표시용)
        $capTxt = '작성+'
        if ($isGold) { $capTxt = '작호+' }
        return @{ Val = 9.0; Text = $capTxt; E = $e; Pen = $pen }
    }
    $p = $e / $r[3]
    $step = 15.0
    if ($isEast) { $step = 10.0 }
    if ($ModeId -eq 12 -or $ModeId -eq 16) {
        # 옥남/왕좌남: 기존·검색사이트와 동일한 폐형식 유지 (표시값 회귀 없음)
        $v = $p / 15.0 - 10.0
        if ($v -ge 4) { return @{ Val = $v; Text = ('작성{0:N2}' -f ($v - 3)); E = $e; Pen = $pen } }
        return @{ Val = $v; Text = ('작호{0:N2}' -f $v); E = $e; Pen = $pen }
    }
    # 금탁·동장: 페널티 표가 불균일하므로 구간별 역산으로 연속값 확장
    $v = -5.0
    $floor = $false
    if ($p -ge $pen[9]) {
        $v = ($p - $pen[9]) / $step + 1.0
    } else {
        $matched = $false
        for ($k = 8; $k -ge 3; $k--) {
            if ($p -ge $pen[$k]) {
                $v = ($k - 8) + (($p - $pen[$k]) / ($pen[$k + 1] - $pen[$k]))
                $matched = $true
                break
            }
        }
        if (-not $matched) { $floor = $true }
    }
    $txt = ''
    if ($floor) { $txt = '작사1-' }
    elseif ($isGold -and $v -ge 4) { $txt = '작호+' }   # 금탁 단위 상한은 작호
    elseif ($v -ge 4) { $txt = ('작성{0:N2}' -f ($v - 3)) }
    elseif ($v -ge 1) { $txt = ('작호{0:N2}' -f $v) }
    elseif ($v -ge -2) { $txt = ('작걸{0:N2}' -f ($v + 3)) }
    else { $txt = ('작사{0:N2}' -f ($v + 6)) }
    return @{ Val = $v; Text = $txt; E = $e; Pen = $pen }
}

# 현재 테마의 커스텀 설정 키 접미사 (TextColor/BgColor/BgAlpha + Light|Dark|Trans)
function Get-ThemeKey {
    switch ($script:Theme) { 'dark' { return 'Dark' } 'trans' { return 'Trans' } }
    return 'Light'
}

# 구버전 단일 색 설정(TextColor 등)을 테마별 키로 이주 (시작·프리셋 적용 시)
function Convert-LegacyThemeColors {
    # 안정단위 마스터 토글은 제거됨 - 계산은 항상 수행, 표시는 표시 항목의 나/상대 토글이 지배
    $script:Settings.Stable = $true
    foreach ($mk in @('TextColor', 'BgColor')) {
        $ov = [string]$script:Settings[$mk]
        if ($ov) {
            foreach ($tk2 in @('Light', 'Dark', 'Trans')) {
                if (-not [string]$script:Settings["$mk$tk2"]) { $script:Settings["$mk$tk2"] = $ov }
            }
            $script:Settings[$mk] = ''
        }
    }
    if ([int]$script:Settings.BgAlpha -ge 0) {
        foreach ($tk2 in @('Light', 'Dark', 'Trans')) {
            if ([int]$script:Settings["BgAlpha$tk2"] -lt 0) { $script:Settings["BgAlpha$tk2"] = [int]$script:Settings.BgAlpha }
        }
        $script:Settings.BgAlpha = -1
    }
}

# 랭크 major → 등급 구간 키 (랭크 이름 색·안정단 계산 전 임시 닉 색용)
function Get-RankTier {
    param([int]$Major)
    switch ($Major) {
        2 { return 'sasa' }
        3 { return 'geol' }
        4 { return 'ho' }
        5 { return 'seong' }
    }
    if ($Major -ge 6) { return 'konten' }
    return ''
}

# 안정단위 값 → 등급 구간 (색상용)
function Get-StableTier {
    param([double]$V)
    if ($V -ge 4) { return 'seong' }
    if ($V -ge 1) { return 'ho' }
    if ($V -ge -2) { return 'geol' }
    return 'sasa'
}

# 등급별 색상 (기본값 + 사용자 재정의 'sasa=#..,geol=#..' 형식)
$script:StableTierDefaults = @{
    sasa = '#FF7BE38B'    # 작사: 초록
    geol = '#FFFFD666'    # 작걸: 노랑
    ho = '#FFFF9800'      # 작호: 주황
    seong = '#FFFF5544'   # 작성: 다홍
    konten = '#FF80DEEA'  # 혼천: 하늘색
    none = '#FF9AA3B6'    # 전적 부족: 회색
}
$script:StableTierNames = @{ sasa = '작사'; geol = '작걸'; ho = '작호'; seong = '작성'; konten = '혼천' }

function Get-StableTierColor {
    param([string]$Tier)
    $ov = [string]$script:Settings.StableColors
    if ($ov) {
        foreach ($pair in @($ov -split ',' | Where-Object { $_ })) {
            $kv = $pair -split '='
            if ($kv.Count -ge 2 -and $kv[0] -eq $Tier -and $kv[1]) { return [string]$kv[1] }
        }
    }
    if ($script:StableTierDefaults.ContainsKey($Tier)) { return $script:StableTierDefaults[$Tier] }
    return '#FF7BE38B'
}

function Set-StableTierColor {
    param([string]$Tier, [string]$Hex)
    $m = @{}
    foreach ($pair in @(([string]$script:Settings.StableColors) -split ',' | Where-Object { $_ })) {
        $kv = $pair -split '='
        if ($kv.Count -ge 2) { $m[$kv[0]] = $kv[1] }
    }
    $m[$Tier] = $Hex
    $script:Settings.StableColors = (@($m.Keys | ForEach-Object { '{0}={1}' -f $_, $m[$_] }) -join ',')
}

# 시작점 + 게임별 (Lvl, Pt)로 누적 수지 시리즈 생성 (승단/강단 넘어도 이어짐)
function Get-CumSeries {
    param([int]$StartLvl, $StartPt, $Lvls, $Pts)
    $out = New-Object Collections.ArrayList
    $null = $out.Add(0)
    $cum = 0
    $prev = $null
    if ($StartLvl -gt 0 -and $null -ne $StartPt) { $prev = @{ Id = $StartLvl; Pt = [int]$StartPt } }
    $lvArr = @($Lvls)
    $ptArr = @($Pts)
    for ($i = 0; $i -lt $ptArr.Count; $i++) {
        if ($null -eq $ptArr[$i]) { $null = $out.Add($null); continue }
        $lv = 0
        if ($i -lt $lvArr.Count -and $null -ne $lvArr[$i]) { $lv = [int]$lvArr[$i] }
        if ($lv -le 0 -and $prev) { $lv = [int]$prev.Id }
        $cur = @{ Id = $lv; Pt = [int]$ptArr[$i] }
        if ($prev) { $cum += (Get-PtDelta $prev $cur) }
        $prev = $cur
        $null = $out.Add($cum)
    }
    return @($out)
}

# 승단/강단을 넘어간 두 시점 사이의 pt 변동 (스케일 보정)
function Get-PtDelta {
    param($EffS, $EffE)
    if (-not $EffS -or -not $EffE) { return 0 }
    if ([int]$EffS.Id -eq [int]$EffE.Id) { return ([int]$EffE.Pt - [int]$EffS.Pt) }
    $mS = ([int][math]::Floor($EffS.Id / 100)) % 100; $nS = [int]($EffS.Id % 100)
    $mE = ([int][math]::Floor($EffE.Id / 100)) % 100; $nE = [int]($EffE.Id % 100)
    if (-not ($MaxPts.ContainsKey($mS) -and $MaxPts.ContainsKey($mE))) { return 0 }
    $halfE = [math]::Floor($MaxPts[$mE][$nE - 1] / 2)
    if ([int]$EffE.Id -gt [int]$EffS.Id) {
        return (($MaxPts[$mS][$nS - 1] - [int]$EffS.Pt) + ([int]$EffE.Pt - $halfE))
    }
    return (([int]$EffE.Pt - $halfE) - [int]$EffS.Pt)
}

# 특정 시점의 유효 단위/pt
function Get-PtAt {
    param($Id, [long]$Ms)
    $st = Get-RangeStats $Id $EpochStart $Ms
    if (-not $st) { return $null }
    return Get-EffectiveLevel $st.level
}

# 리포트 팩 생성 (일/주/월/년/전체) - 백그라운드 프로세스에서 호출됨
function Build-ReportPack {
    param([string]$Mode, [DateTime]$Anchor, [DateTime]$RangeEnd = [DateTime]::MinValue)
    $id = Get-PlayerId
    $today = [DateTime]::Today
    if ($Mode -eq 'day') {
        $s = $Anchor.Date
        $sMs = [DateTimeOffset]::new($s).ToUnixTimeMilliseconds()
        $eMs = [DateTimeOffset]::new($s.AddDays(1)).ToUnixTimeMilliseconds()
        $st = Get-RangeStats $id $sMs $eMs
        $n = 0; if ($st) { $n = [int]$st.count }
        $seq = @(); $pts = @(); $lvls = @(); $diff = 0
        $effS = Get-PtAt $id $sMs
        $effE = $effS
        if ($n -gt 0) {
            $seqObjs = @(Get-RankSequence $id $sMs $eMs 0)
            if ($seqObjs.Count -ne $n) { $seqObjs = @(Get-RankSequence $id $sMs $eMs 0) }
            $seq = @($seqObjs | ForEach-Object { $_.Rank })
            $pts = @($seqObjs | ForEach-Object { $_.Pt })
            $lvls = @($seqObjs | ForEach-Object { $_.Lvl })
            $effE = Get-PtAt $id $eMs
            $diff = Get-PtDelta $effS $effE
        }
        $rc = @(0, 0, 0, 0)
        foreach ($r in $seq) { if ($r -ge 1 -and $r -le 4) { $rc[$r - 1]++ } }
        $sl = 0; $sp = $null; $el = 0; $ep = $null
        if ($effS) { $sl = [int]$effS.Id; $sp = [int]$effS.Pt }
        if ($effE) { $el = [int]$effE.Id; $ep = [int]$effE.Pt }
        # 그날의 화료율/방총율 (한 줄 평 소재용, 실패해도 무시)
        $hr = $null; $dl = $null
        if ($n -gt 0) {
            try {
                Start-Sleep -Milliseconds 120
                $ext = Invoke-RestMethod -Uri "$Api/player_extended_stats/$id/$sMs/$eMs`?mode=$($script:Modes)" -TimeoutSec 15
                if ($ext) { $hr = [double]$ext.'和牌率'; $dl = [double]$ext.'放铳率' }
            } catch {}
        }
        return @{ Mode = 'day'; Anchor = $s.ToString('yyyy-MM-dd'); Title = ('{0}/{1}' -f $s.Month, $s.Day); N = $n; Diff = $diff; RankCounts = $rc; Seq = $seq; Pts = $pts; Lvls = $lvls; Buckets = @(); StartLvl = $sl; StartPt = $sp; EndLvl = $el; EndPt = $ep; Hr = $hr; Dl = $dl }
    }

    # 주/시즌/월/년: 구간 버킷 집계
    if ($Mode -eq 'season') {
        # 시즌 = 3개월 분기, 주차별 버킷
        $qm = ((([int]$Anchor.Month - 1) - (([int]$Anchor.Month - 1) % 3)) + 1)
        $s = New-Object DateTime $Anchor.Year, $qm, 1
        $qEnd = $s.AddMonths(3)
        $bounds = @()
        $d = $s
        while ($d -lt $qEnd) { $bounds += $d; $d = $d.AddDays(7) }
        $bounds += $qEnd
        $labels = @()
        for ($i = 1; $i -lt $bounds.Count; $i++) { $labels += [string]$i }
        $title = ('{0}년 {1}~{2}월 시즌' -f $s.Year, $qm, ($qm + 2))
    } elseif ($Mode -eq 'week') {
        $s = $Anchor.Date.AddDays(-(([int]$Anchor.DayOfWeek + 6) % 7))
        $bounds = @(); for ($i = 0; $i -le 7; $i++) { $bounds += $s.AddDays($i) }
        $labels = @('월', '화', '수', '목', '금', '토', '일')
        $title = ('{0}/{1}~{2}/{3} 주간' -f $s.Month, $s.Day, $s.AddDays(6).Month, $s.AddDays(6).Day)
    } elseif ($Mode -eq 'month') {
        $s = New-Object DateTime $Anchor.Year, $Anchor.Month, 1
        $dim = [DateTime]::DaysInMonth($s.Year, $s.Month)
        $bounds = @(); for ($i = 0; $i -le $dim; $i++) { $bounds += $s.AddDays($i) }
        $labels = @(1..$dim | ForEach-Object { [string]$_ })
        $title = ('{0}년 {1}월' -f $s.Year, $s.Month)
    } elseif ($Mode -eq 'range') {
        # 사용자 지정 기간: 길이에 따라 일/주/월 단위 버킷
        $s = $Anchor.Date
        $e = $RangeEnd.Date
        if ($e -lt $s) { $t0 = $s; $s = $e; $e = $t0 }
        if ($e -gt $today) { $e = $today }
        $rEnd = $e.AddDays(1)
        $span = ($rEnd - $s).Days
        $bounds = @(); $labels = @()
        if ($span -le 31) {
            $d = $s
            while ($d -lt $rEnd) { $bounds += $d; $labels += ('{0}/{1}' -f $d.Month, $d.Day); $d = $d.AddDays(1) }
            $bounds += $rEnd
        } elseif ($span -le 182) {
            $d = $s
            while ($d -lt $rEnd) { $bounds += $d; $labels += ('{0}/{1}' -f $d.Month, $d.Day); $d = $d.AddDays(7) }
            $bounds += $rEnd
        } else {
            $d = New-Object DateTime $s.Year, $s.Month, 1
            $bounds += $s
            $labels += ('{0:yy}/{1}' -f $s, $s.Month)
            $d = $d.AddMonths(1)
            while ($d -lt $rEnd) { $bounds += $d; $labels += ('{0:yy}/{1}' -f $d, $d.Month); $d = $d.AddMonths(1) }
            $bounds += $rEnd
        }
        if ($s.Year -ne $e.Year) {
            $title = ('{0}.{1}/{2}~{3}.{4}/{5}' -f $s.Year, $s.Month, $s.Day, $e.Year, $e.Month, $e.Day)
        } else {
            $title = ('{0}/{1}~{2}/{3}' -f $s.Month, $s.Day, $e.Month, $e.Day)
        }
    } elseif ($Mode -eq 'all') {
        # 전체 기간 = 연도별 버킷 (amae-koromo 데이터가 존재하는 2018년부터, 빈 앞구간은 아래서 잘라냄)
        $s = New-Object DateTime 2018, 1, 1
        $bounds = @(); for ($y = 2018; $y -le ($today.Year + 1); $y++) { $bounds += (New-Object DateTime $y, 1, 1) }
        $labels = @(2018..$today.Year | ForEach-Object { [string]$_ })
        $title = '전체'
    } else {
        $s = New-Object DateTime $Anchor.Year, 1, 1
        $bounds = @(); for ($i = 0; $i -le 12; $i++) { $bounds += $s.AddMonths($i) }
        $labels = @(1..12 | ForEach-Object { [string]$_ })
        $title = ('{0}년' -f $s.Year)
    }
    $buckets = @()
    $rcTotal = @(0, 0, 0, 0); $nTotal = 0; $diffTotal = 0
    $prevEff = Get-PtAt $id ([DateTimeOffset]::new($bounds[0]).ToUnixTimeMilliseconds())
    # 전체 기간: 계정 시작 전 시점이라 유효 단위가 없으면 초심1 0pt에서 출발한 것으로 간주
    if ($Mode -eq 'all' -and (-not $prevEff -or [int]$prevEff.Id -le 0)) { $prevEff = @{ Id = 101; Pt = 0 } }
    $startLvl = 0; $startPt = $null
    if ($prevEff) { $startLvl = [int]$prevEff.Id; $startPt = [int]$prevEff.Pt }
    $curLvlId = $startLvl; $endPt = $startPt
    for ($i = 0; $i -lt $bounds.Count - 1; $i++) {
        if ($bounds[$i] -gt $today) { break }
        $bs = [DateTimeOffset]::new($bounds[$i]).ToUnixTimeMilliseconds()
        $be = [DateTimeOffset]::new($bounds[$i + 1]).ToUnixTimeMilliseconds()
        $st = Get-RangeStats $id $bs $be
        $bn = 0; if ($st) { $bn = [int]$st.count }
        $bd = 0
        if ($bn -gt 0) {
            $effE = Get-PtAt $id $be
            $bd = Get-PtDelta $prevEff $effE
            if ($effE) {
                $prevEff = $effE
                $curLvlId = [int]$effE.Id
                $endPt = [int]$effE.Pt
            }
            $rates = @($st.rank_rates)
            for ($k = 0; $k -lt 4 -and $k -lt $rates.Count; $k++) { $rcTotal[$k] += [int][math]::Round($rates[$k] * $bn) }
        }
        $nTotal += $bn; $diffTotal += $bd
        $buckets += @{ Label = $labels[$i]; N = $bn; Diff = $bd; Lvl = $curLvlId; Pt = $endPt }
        Start-Sleep -Milliseconds 60
    }
    # 전체 기간: 첫 대국 이전의 빈 연도는 차트에서 제외
    if ($Mode -eq 'all') {
        while ($buckets.Count -gt 1 -and [int]$buckets[0].N -eq 0) { $buckets = @($buckets | Select-Object -Skip 1) }
    }
    return @{ Mode = $Mode; Anchor = $s.ToString('yyyy-MM-dd'); Title = $title; N = $nTotal; Diff = $diffTotal; RankCounts = $rcTotal; Seq = @(); Pts = @(); Buckets = $buckets; StartLvl = $startLvl; StartPt = $startPt; EndLvl = $curLvlId; EndPt = $endPt }
}

# 스트릭: 연대율 기준 — 1·2위 = 연대, 4위 = 라스(연속 라스)
function Get-StreakText {
    param($Seq)
    if ($Seq.Count -lt 2) { return '' }
    $last = $Seq[$Seq.Count - 1]
    if ($last -le 2) {
        $n = 0
        for ($i = $Seq.Count - 1; $i -ge 0 -and $Seq[$i] -le 2; $i--) { $n++ }
        if ($n -ge 2) { return "🔥${n}연속 연대" }
    } elseif ($last -eq 4) {
        $n = 0
        for ($i = $Seq.Count - 1; $i -ge 0 -and $Seq[$i] -eq 4; $i--) { $n++ }
        if ($n -ge 2) { return "💀${n}연속 라스" }
    }
    return ''
}

# 牌谱屋의 승단/강단 처리 지연 보정: pt가 상한/하한을 넘었으면 단위를 직접 이동
function Get-EffectiveLevel {
    param($Level)
    $id = [int]$Level.id
    $pt = [int]($Level.score + $Level.delta)
    for ($i = 0; $i -lt 6; $i++) {
        $maj = ([int][math]::Floor($id / 100)) % 100
        $min = [int]($id % 100)
        if ($maj -ge 6 -or -not $MaxPts.ContainsKey($maj)) { break }
        $max = $MaxPts[$maj][$min - 1]
        if ($pt -ge $max) {
            # 승단
            if ($min -lt 3) { $id = $id + 1 }
            elseif ($maj -lt 5) { $id = $id + 100 - 2 }  # x03 -> (x+1)01
            else { break }  # 작성3 -> 혼천은 스케일이 달라 서버 반영을 기다림
            $maj2 = ([int][math]::Floor($id / 100)) % 100
            $min2 = [int]($id % 100)
            $pt = [math]::Floor($MaxPts[$maj2][$min2 - 1] / 2)
        } elseif ($pt -lt 0) {
            # 강단 (작사1이 하한 - 그 아래로는 강등 없음)
            if ($min -gt 1) { $id = $id - 1 }
            elseif ($maj -gt 2) { $id = $id - 100 + 2 }  # x01 -> (x-1)03
            else { $pt = 0; break }
            $maj2 = ([int][math]::Floor($id / 100)) % 100
            $min2 = [int]($id % 100)
            $pt = [math]::Floor($MaxPts[$maj2][$min2 - 1] / 2)
        } else { break }
    }
    return @{ Id = $id; Pt = $pt }
}

function Get-RankLine {
    param([int]$LvlId, $Cur, $BasePt)
    $major = ([int][math]::Floor($LvlId / 100)) % 100
    $minor = [int]($LvlId % 100)
    if ($major -eq 6) {
        return [pscustomobject]@{ Text = ('랭크 혼천  점수 {0:N1}' -f ($Cur / 100)); Diff = 0; NoDiff = $true }
    }
    if ($major -ge 7) {
        # 신식 혼천(107xx): 세부 단계 + 별도 점수제 - 점수는 있는 그대로 표시
        return [pscustomobject]@{ Text = ('랭크 혼천{0}  점수 {1}' -f $minor, $Cur); Diff = 0; NoDiff = $true }
    }
    $rankName = '{0}{1}' -f $MajorNames[$major], $minor
    $max = $MaxPts[$major][$minor - 1]
    if ($null -eq $BasePt) { $BasePt = [math]::Floor($max / 2) }
    return [pscustomobject]@{
        Text = ('랭크 {0}  점수 {1}/{2} ({3}) ' -f $rankName, $Cur, $max, $BasePt)
        Diff = ($Cur - $BasePt); NoDiff = $false
    }
}

function Get-OverlayData {
    $id = Get-PlayerId
    $queryMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()   # 이 조회에 포함된 판의 상한 (순위 복원 이어붙이기 기준)
    $nowPlus = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeMilliseconds()
    # 기준 시점: 오늘 0시 / 실행 시점 / 직접 지정
    $baseMs = [long](Get-BaseStartMs)

    # '오늘 0시' 기준은 날짜가 바뀌면 누적 리셋. 기준 시점 자체가 움직인 경우(직접 지정 변경,
    # 상대 시간 창 이동, 자정의 relday 이동)는 기준값 변화로 감지해 항상 리셋
    $rollover = [bool]$script:ForceReset -or
                (($script:TodayDate -ne [DateTime]::Today) -and ([string]$script:Settings.SessionBase -eq 'today')) -or
                ($null -ne $script:BaseMsUsed -and [long]$script:BaseMsUsed -ne $baseMs)
    $script:BaseMsUsed = $baseMs
    $script:ForceReset = $false
    $script:TodayDate = [DateTime]::Today
    if ($rollover) {
        $script:TodayCount = -1
        $script:TodaySeq = @()
        $script:TodayPts = @()
        $script:TodayLvls = @()
        $script:AnnouncedCount = -1
        $script:BaselinePt = $null
        $script:BaselineLvl = $null
        $script:BaselineTotal = $null
        $script:BaseCheckedAt = $null
        $script:SeqDoneMs = $null
        $script:GoalCelebrated = $null
    }

    $statStart = Get-BasisStart $id $nowPlus $script:Settings.MyBasis
    $stats = Get-RangeStats $id $statStart $nowPlus
    # 기준 구간에 판이 없으면 API가 404를 준다 ('기준 시점 이후'로 막 바꾼 직후 등).
    # 실패로 볼 일이 아니므로 이름/랭크는 전체 기준으로 채우고 표본이 필요한 값만 비운다.
    $emptyBasis = (-not $stats)
    if ($emptyBasis) { $stats = Get-RangeStats $id $EpochStart $nowPlus }
    if (-not $stats) { throw '전적 조회 실패' }
    # 랭크/점수는 통계 기준과 무관하게 항상 전체 기간 기준 (승단 즉시 반영)
    $fullStats = $stats
    if (-not $emptyBasis -and $statStart -ne $EpochStart) {
        $f = Get-RangeStats $id $EpochStart $nowPlus
        if ($f) { $fullStats = $f }
    }
    # 통산 통계(화료율 등)는 잘 안 변하므로 10분에 한 번만 조회
    if ($emptyBasis) {
        $script:ExtCache = $null
        $script:ExtCacheTime = [DateTime]::Now
    } elseif ($null -eq $script:ExtCache -or ([DateTime]::Now - $script:ExtCacheTime).TotalSeconds -gt 600) {
        # 구간이 비면 여기도 404 - 실패해도 전체 갱신을 멈추지 않음
        try { $script:ExtCache = Invoke-Api "$Api/player_extended_stats/$id/$statStart/$nowPlus`?mode=$($script:Modes)" 15 }
        catch { $script:ExtCache = $null }
        $script:ExtCacheTime = [DateTime]::Now
    }
    $ext = $script:ExtCache

    $today = Get-RangeStats $id $baseMs $nowPlus
    $todayCount = 0
    if ($today) { $todayCount = $today.count }

    # 오늘 0시 시점 점수/단위 (오늘 변동 계산용)
    # 서버 집계 캐시가 늦으면 기준 조회가 직전 판을 빠뜨린 채 굳어버린다 ("오늘 0국인데 ▼6").
    # 기준 시점까지의 국수 + 오늘 국수 = 전체 국수가 맞지 않으면 기준을 다시 잡는다.
    $needBase = ($null -eq $script:BaselinePt)
    if (-not $needBase -and ([int]$script:BaselineTotal + $todayCount) -ne [int]$fullStats.count -and
        $script:BaseCheckedAt -ne [int]$fullStats.count) { $needBase = $true }
    if ($needBase) {
        $script:BaseCheckedAt = [int]$fullStats.count   # 같은 국수로는 한 번만 재조회
        $before = Get-RangeStats $id $EpochStart $baseMs
        if ($before) {
            $effB = Get-EffectiveLevel $before.level
            $script:BaselinePt = $effB.Pt
            $script:BaselineLvl = $effB.Id
            $script:BaselineTotal = [int]$before.count
        } elseif ($null -eq $script:BaselinePt) {
            # 기준 시점 이전 기록이 없음 (신규 계정 등) - 현재 값을 기준으로
            $effB = Get-EffectiveLevel $fullStats.level
            $script:BaselinePt = $effB.Pt
            $script:BaselineLvl = $effB.Id
            $script:BaselineTotal = 0
        }
    }
    # 오늘 구간 집계만 늦게 반영되는 경우가 있다 (구간 조회는 404인데 전체 국수는 이미 늘어난 상태).
    # 판 수는 차이로 보정 - 순위 시퀀스는 서버가 따라잡은 뒤 채워진다.
    if ($todayCount -eq 0 -and [int]$fullStats.count -gt [int]$script:BaselineTotal) {
        $todayCount = [int]$fullStats.count - [int]$script:BaselineTotal
    }

    if ($todayCount -ne $script:TodayCount) {
        if ($todayCount -eq 0) {
            $script:TodaySeq = @()
            $script:TodayPts = @()
            $script:TodayLvls = @()
            $script:TodayCount = 0
            $script:SeqDoneMs = $null
        } else {
            # 순위 복원은 구간 이분 탐색이라 구간이 길수록/판이 많을수록 비싸다.
            # 이미 복원해둔 시점 뒤쪽만 조회해 이어 붙이고, 개수가 안 맞을 때만 전체를 다시 훑는다.
            $seq = $null
            $addN = $todayCount - $script:TodayCount
            if ($script:SeqDoneMs -and $script:TodayCount -gt 0 -and $addN -gt 0) {
                $add = @(Get-RankSequence $id ([long]$script:SeqDoneMs) $nowPlus 0)
                if ($add.Count -eq $addN) {
                    $seq = @(@(0..($script:TodayCount - 1) | ForEach-Object {
                        @{ Rank = $script:TodaySeq[$_]; Pt = $script:TodayPts[$_]; Lvl = $script:TodayLvls[$_] }
                    }) + $add)
                }
            }
            if ($null -eq $seq) { $seq = @(Get-RankSequence $id $baseMs $nowPlus 0) }
            # 복원된 순위 개수가 실제 판 수와 일치할 때만 반영 (중간 조회 실패 시 다음 갱신 때 재시도)
            if ($seq.Count -eq $todayCount) {
                $script:TodaySeq = @($seq | ForEach-Object { $_.Rank })
                $script:TodayPts = @($seq | ForEach-Object { $_.Pt })
                $script:TodayLvls = @($seq | ForEach-Object { $_.Lvl })
                $script:TodayCount = $todayCount
                $script:SeqDoneMs = $queryMs
            }
        }
    }

    # 오늘 변동: 승단/강단으로 pt 스케일이 바뀐 경우 구간을 이어서 계산
    $effCur = Get-EffectiveLevel $fullStats.level
    $curPt = [int]$effCur.Pt
    $curLvl = [int]$effCur.Id
    $displayBase = $script:BaselinePt
    $todayDiff = $curPt - $script:BaselinePt
    if ($script:BaselineLvl -and $curLvl -ne [int]$script:BaselineLvl) {
        $majOld = ([int][math]::Floor($script:BaselineLvl / 100)) % 100
        $minOld = [int]($script:BaselineLvl % 100)
        $majNew = ([int][math]::Floor($curLvl / 100)) % 100
        $minNew = [int]($curLvl % 100)
        if ($MaxPts.ContainsKey($majOld) -and $MaxPts.ContainsKey($majNew)) {
            $maxOld = $MaxPts[$majOld][$minOld - 1]
            $halfNew = [math]::Floor($MaxPts[$majNew][$minNew - 1] / 2)
            if ($curLvl -gt [int]$script:BaselineLvl) {
                # 승단: (구단계에서 만점까지 오른 양) + (새 단계 시작점 이후 변동)
                $todayDiff = ($maxOld - $script:BaselinePt) + ($curPt - $halfNew)
            } else {
                # 강단: 0까지 잃은 양 + 새(아래) 단계 시작점 이후 변동
                $todayDiff = ($curPt - $halfNew) - $script:BaselinePt
            }
            $displayBase = $halfNew
        }
    }
    $script:CurLvlId = $curLvl
    $rank = Get-RankLine -LvlId $curLvl -Cur $curPt -BasePt $displayBase
    $stable = $null
    $domMode = 0
    $modeStats = $null
    $myMajNow = ([int][math]::Floor($curLvl / 100)) % 100
    if ($myMajNow -ne 6 -and -not $emptyBasis) {
        # 주력 모드 판별(10분 캐시) 후 그 모드 통계만으로 안정단위 계산
        $manualMode = 0
        if ([string]$script:Settings.MyStableMode -match '^\d+$') { $manualMode = [int]$script:Settings.MyStableMode }
        if ($manualMode -gt 0) {
            $domMode = $manualMode
        } else {
            $dmKey = ('{0}|{1}|{2}' -f $id, $script:Settings.MyBasis, $statStart)
            if ($script:MyDomModeKey -eq $dmKey -and $script:MyDomModeAt -and ((Get-Date) - $script:MyDomModeAt).TotalMinutes -lt 10) {
                $domMode = [int]$script:MyDomMode
            } else {
                $domMode = Get-DominantMode $id $statStart $nowPlus ([int]$curLvl)
                $script:MyDomMode = $domMode
                $script:MyDomModeKey = $dmKey
                $script:MyDomModeAt = Get-Date
            }
        }
        $modeStats = Get-RangeStats $id $statStart $nowPlus -ModeFilter "$domMode"
        if (-not $modeStats -or -not $modeStats.count) { $modeStats = Get-RangeStats $id $EpochStart $nowPlus -ModeFilter "$domMode" }
        if ($modeStats -and $modeStats.count) { $stable = Get-StableLevel $modeStats $domMode }
    }
    $suffix = ''
    $myColorVal = $null
    $myTier = ''
    if ($myMajNow -ge 6) {
        # 혼천(구식 6·신식 7)은 별도 pt 체계라 안정단위 공식이 성립하지 않음
        $suffix = '  안정 감히 계산할 수 없음 (혼천)'
        $myColorVal = 9.0
        $myTier = 'konten'
    } elseif ($stable) {
        $myTier = Get-StableTier ([double]$stable.Val)
        $suffix = '  안정 ' + $stable.Text + ' (' + $ModeNames[$domMode] + '·' + (Get-BasisLabel $script:Settings.MyBasis) + ' 기준 · ' + $modeStats.count + '국)'
        $myColorVal = $stable.Val
    } elseif ($emptyBasis) {
        $suffix = '  ' + (Get-BasisLabel $script:Settings.MyBasis) + ' 기준 · 0국'
    }
    $myBadges = Get-StyleBadges $fullStats $ext

    # 메인 박스 그래프: 오늘 누적 수지 (승단/강단 넘어도 이어짐)
    $cumSeries = @(Get-CumSeries ([int]$script:BaselineLvl) $script:BaselinePt $script:TodayLvls $script:TodayPts)

    # 승단 카운트다운 + 오늘 목표 (국당수지는 통계 줄 표시와 공용)
    $myENet = $null
    if ($stable -and $modeStats) { $myENet = Get-NetPerGame $stable $modeStats ([int]$curLvl) }
    $goalLine = ''
    $majC = ([int][math]::Floor($curLvl / 100)) % 100
    $minC = [int]($curLvl % 100)
    if ($majC -lt 6 -and $MaxPts.ContainsKey($majC)) {
        $remain = $MaxPts[$majC][$minC - 1] - $curPt
        $goalLine = "승단까지 ${remain}pt"
        if ($null -ne $myENet -and $myENet -gt 0.5) { $goalLine += ' (약 {0}국)' -f [math]::Ceiling($remain / $myENet) }
    }
    $dGoal = [int]$script:Settings.DailyGoal
    if ($dGoal -gt 0) {
        $ratio = [math]::Max(0.0, [math]::Min(1.0, $todayDiff / $dGoal))
        $cells = [int][math]::Round($ratio * 5)
        $bar = ('▰' * $cells) + ('▱' * (5 - $cells))
        if ($goalLine) { $goalLine += '   ' }
        $goalLine += ('목표 {0} {1}/{2}' -f $bar, $todayDiff, $dGoal)
        if ($todayDiff -ge $dGoal) { $goalLine += ' 🎉' }
    }
    $graphPts = $cumSeries
    # 내 지표 범위 (전체 방 합산 / 주력 방 / 안정단위 계산방 / 특정 방 고정) - 지표·평균순위에 적용
    $myScopeName = ''
    $msc = [string]$script:Settings.MyStatScope
    if ($msc -ne 'all' -and -not $emptyBasis) {
        $mq3 = ''
        if ($msc -match '^\d+\.') { $mq3 = $msc }   # 방 고정
        elseif ($msc -eq 'stable' -and $domMode) { $mq3 = "$domMode" }
        elseif ($msc -eq 'dom' -and $domMode) {
            if ($domMode -ge 15) { $mq3 = '16.15' } elseif ($domMode -ge 11) { $mq3 = '12.11' } else { $mq3 = '9.8' }
        }
        if ($mq3) {
            $s3 = $null
            if ($msc -eq 'stable' -and $modeStats -and $modeStats.count) { $s3 = $modeStats }
            else { $s3 = Get-RangeStats $id $statStart $nowPlus -ModeFilter $mq3 }
            # 범위 지정 ext는 10분 캐시 (매분 갱신마다 재조회하지 않도록)
            $eKey = ('{0}|{1}|{2}' -f $msc, $mq3, $statStart)
            $ext3 = $null
            if ($script:MyScopeExtKey -eq $eKey -and $script:MyScopeExtAt -and ((Get-Date) - $script:MyScopeExtAt).TotalSeconds -lt 600) {
                $ext3 = $script:MyScopeExt
            } else {
                try { $ext3 = Invoke-Api "$Api/player_extended_stats/$id/$statStart/$nowPlus`?mode=$mq3" 15 } catch {}
                $script:MyScopeExt = $ext3
                $script:MyScopeExtKey = $eKey
                $script:MyScopeExtAt = Get-Date
            }
            if ($s3 -and $s3.count -and $ext3) {
                $stats = $s3
                $ext = $ext3
                if ($msc -eq 'stable') { $myScopeName = [string]$ModeNames[[int]$domMode] }
                elseif ($mq3 -eq '16.15') { $myScopeName = '왕좌탁' } elseif ($mq3 -eq '12.11') { $myScopeName = '옥탁' } else { $myScopeName = '금탁' }
            }
        }
    }
    $myParts = @(Get-StatParts $stats $ext)
    if ($myParts.Count -gt 0) {
        # 국당수지는 안정단위 계산방(주력 방) 기준 - 안정단위와 같은 표본
        if ($null -ne $myENet) { $myParts += @{ L = 5; K = 'ppg'; V = [double]$myENet; T = ('국당수지 {0:+0.0;-0.0;±0}pt' -f [double]$myENet) } }
        $myParts += @{ L = 5; K = 'statsrc'; V = 0.0; T = ('({0}·{1})' -f $(if ($myScopeName) { $myScopeName } else { '전체' }), (Get-BasisLabel ([string]$script:Settings.MyBasis))) }
    }
    [pscustomobject]@{
        Name     = $stats.nickname
        NameSuffix = $suffix
        Badges = $myBadges
        NameColorVal = $myColorVal
        StableTier = $myTier
        RankLine = $rank.Text
        Diff     = $todayDiff
        NoDiff   = $rank.NoDiff
        Seq      = @($script:TodaySeq)
        Streak   = (Get-StreakText @($script:TodaySeq))
        Pts      = $graphPts
        RawPts   = @($script:TodayPts)
        Lvls     = @($script:TodayLvls)
        StartLvl = [int]$script:BaselineLvl
        StartPt  = $script:BaselinePt
        CurPt    = $curPt
        GoalLine = $goalLine
        GameLine = ('전적 {0} {1}국' -f (Get-BasisLabel 'base'), $todayCount)
        StatParts = $myParts
        RankMajor = (([int][math]::Floor($curLvl / 100)) % 100)
        IsOpp = $false
    }
}

function Get-OpponentData {
    param($Id, [switch]$SkipStable)
    if ($script:OppCache.ContainsKey("$Id")) { return $script:OppCache["$Id"] }
    $nowPlus = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeMilliseconds()
    $oppBasis = [string]$script:Settings.OppBasis
    $statStart = Get-BasisStart $Id $nowPlus $oppBasis -Iters 11
    # 지표 범위: 전체 방 합산(기본) / 현재 방 / 주력 방 / 안정단위 계산방 / 특정 방 고정 - 지표·전적 줄·평균순위에 적용
    $scopeMq = ''
    $scope = [string]$script:Settings.OppStatScope
    if ($scope -match '^\d') {
        # 방 고정 ('9.8'|'12.11'|'16.15')
        $scopeMq = $scope
    } elseif ($scope -eq 'room') {
        $r0 = [int]$script:ScanRoomMode
        if ($r0 -le 0 -and $script:RoomGuess -and $script:SawMyNick) { $r0 = [int]$script:RoomGuess }
        if ($r0 -ge 15) { $scopeMq = '16.15' } elseif ($r0 -ge 11) { $scopeMq = '12.11' } elseif ($r0 -ge 8) { $scopeMq = '9.8' }
    } elseif ($scope -eq 'dom') {
        $gN2 = Get-ModeCount $Id $statStart $nowPlus '9.8'
        $jN2 = Get-ModeCount $Id $statStart $nowPlus '12.11'
        $tN2 = Get-ModeCount $Id $statStart $nowPlus '16.15'
        if ($gN2 -gt 0 -or $jN2 -gt 0 -or $tN2 -gt 0) {
            if ($tN2 -ge $jN2 -and $tN2 -ge $gN2) { $scopeMq = '16.15' }
            elseif ($jN2 -ge $gN2) { $scopeMq = '12.11' }
            else { $scopeMq = '9.8' }
        }
    }
    $stats = Get-RangeStats $Id $statStart $nowPlus -ModeFilter $scopeMq
    # 기준 구간에 판이 없으면 API가 404 - 오래 쉰 상대라도 전체 기준으로는 보여준다
    $finalBasis = $oppBasis
    if (-not $stats) {
        $finalBasis = 'all'
        $statStart = [long]$EpochStart
        $stats = Get-RangeStats $Id $EpochStart $nowPlus -ModeFilter $scopeMq
    }
    if (-not $stats -and $scopeMq) {
        # 선택한 범위에 기록이 전혀 없으면 전체 합산으로 폴백
        $scopeMq = ''
        $finalBasis = $oppBasis
        $statStart = Get-BasisStart $Id $nowPlus $oppBasis -Iters 11
        $stats = Get-RangeStats $Id $statStart $nowPlus
        if (-not $stats) {
            $finalBasis = 'all'
            $statStart = [long]$EpochStart
            $stats = Get-RangeStats $Id $EpochStart $nowPlus
        }
    }
    if (-not $stats) { return $null }
    # 최소 표본 확보: 기간 내 국수가 부족하면 더 긴 기간으로 순차 확장
    $minN = [int]$script:Settings.OppMinN
    if ($minN -gt 0 -and $finalBasis -eq $oppBasis -and $oppBasis -match '^(m1|m3|m6|y1)$') {
        $ladder = @('m1', 'm3', 'm6', 'y1', 'all')
        $li = [Array]::IndexOf($ladder, $oppBasis)
        while ([int]$stats.count -lt $minN -and $li -lt $ladder.Count - 1) {
            $li++
            $finalBasis = $ladder[$li]
            $statStart = Get-BasisStart $Id $nowPlus $finalBasis -Iters 11
            $s2 = Get-RangeStats $Id $statStart $nowPlus -ModeFilter $scopeMq
            if ($s2) { $stats = $s2 } else { break }
        }
    }
    # 랭크/점수는 항상 전체 기간 기준 (승단 즉시 반영)
    $fullStats = $stats
    if ($statStart -ne $EpochStart) {
        $f = Get-RangeStats $Id $EpochStart $nowPlus
        if ($f) { $fullStats = $f }
    }
    $ext = $null
    $extMq = $(if ($scopeMq) { $scopeMq } else { $script:Modes })
    try { $ext = Invoke-Api "$Api/player_extended_stats/$Id/$statStart/$nowPlus`?mode=$extMq" 15 } catch {}
    $effOpp = Get-EffectiveLevel $fullStats.level
    $rank = Get-RankLine -LvlId ([int]$effOpp.Id) -Cur ([int]$effOpp.Pt) -BasePt $null
    $statParts = Get-StatParts $stats $ext
    # 안정단위: 방(금/옥/왕좌 감지) 인지형 표시 (결과는 OppCache에 통째로 캐시됨)
    # -SkipStable: 박스를 먼저 띄우기 위한 1차 데이터 - 안정단은 2차에서 채움
    $oppMajNow = ([int][math]::Floor([int]$effOpp.Id / 100)) % 100
    $suffix = ''
    $suffix2 = ''
    $suffixTier = ''    # 1번째 줄(주 기준) 자체의 구간 색
    $suffix2Tier = ''   # 2번째 줄(병행 기준) 자체의 구간 색
    $colorVal = $null
    $oppTier = ''
    if (-not $SkipStable) {
    # 모드별 최종 기준 라벨 - 확장 경로('1개월→전체') 대신 최종 기준만 간결하게 표시
    $mkLabel = {
        param([string]$b)
        return Get-BasisLabel $b
    }
    # 한 모드의 (통계, 안정단, 국수, 최종 기준) 묶음
    # 모드별 최소 표본: 공유 구간에서 이 모드 국수가 부족하면 이 모드만 더 긴 기간으로 개별 확장
    # (전체 통계의 확장은 합산 국수 기준이라, 병행 표시의 한쪽이 소수 표본으로 남는 문제 방지)
    $calc = {
        param([int]$m)
        $mBasis = $finalBasis
        $mStart = $statStart
        $ms = Get-RangeStats $Id $mStart $nowPlus -ModeFilter "$m"
        if ($minN -gt 0 -and $mBasis -match '^(m1|m3|m6|y1)$') {
            $ladder = @('m1', 'm3', 'm6', 'y1', 'all')
            $li = [Array]::IndexOf($ladder, $mBasis)
            while ((-not $ms -or [int]$ms.count -lt $minN) -and $li -lt $ladder.Count - 1) {
                $li++
                $mBasis = $ladder[$li]
                $mStart = Get-BasisStart $Id $nowPlus $mBasis -Iters 11
                $m2 = Get-RangeStats $Id $mStart $nowPlus -ModeFilter "$m"
                if ($m2) { $ms = $m2 }
            }
        }
        if (-not $ms -or -not $ms.count) {
            $ms = Get-RangeStats $Id $EpochStart $nowPlus -ModeFilter "$m"
            $mBasis = 'all'
        }
        $st2 = $null
        if ($ms -and $ms.count) { $st2 = Get-StableLevel $ms $m }
        return @{ M = $m; N = $(if ($ms) { [int]$ms.count } else { 0 }); S = $st2; B = $mBasis; St = $ms; Start = $mStart }
    }
    # 방 그룹 안의 동/남 선택: 현재 방 쪽을 먼저 보고, 그 표본이 최소 표본에 못 미치면 반대쪽(동↔남)도 계산해 보조로 제시
    # 둘 다 최소 표본을 넘으면 현재 방 기준만 쓴다 (반환: @{ P = 주 기준; X = 보조 또는 $null })
    $subPlan = {
        param([int]$South, [bool]$RoomEast)
        $mainM = $(if ($RoomEast) { $South - 1 } else { $South })
        $sibM = $(if ($RoomEast) { $South } else { $South - 1 })
        $rA = & $calc $mainM
        $res = @{ P = $rA; X = $null }
        if ($minN -le 0) { return $res }
        if ($rA -and $rA.S -and [int]$rA.N -ge $minN) { return $res }
        $rB = & $calc $sibM
        $okA = ($rA -and $rA.S -and [int]$rA.N -ge 20)   # 20국 미만은 표본으로 의미 없음
        $okB = ($rB -and $rB.S -and [int]$rB.N -ge 20)
        if (-not $okA) {
            # 현재 방 쪽이 표본으로 못 쓸 수준이면 반대쪽을 주 기준으로
            if ($okB) { $res.P = $rB }
            return $res
        }
        if ($okB) { $res.X = $rB }
        return $res
    }
    if ($oppMajNow -ge 6) {
        # 혼천(구식 6·신식 7)은 별도 pt 체계라 안정단위 공식이 성립하지 않음
        $suffix = '  안정 감히 계산할 수 없음 (혼천)'
        $colorVal = 9.0
        $oppTier = 'konten'
    } elseif ([string]$script:Settings.OppStableMode -match '^\d+$') {
        # 수동 고정 모드
        $r1 = & $calc ([int]$script:Settings.OppStableMode)
        if ($r1.S) {
            $suffix = '  안정 ' + $r1.S.Text + ' (' + $ModeNames[$r1.M] + '·' + (& $mkLabel $r1.B) + ' 기준 · ' + $r1.N + '국)'
            $colorVal = $r1.S.Val
            $oppTier = Get-StableTier ([double]$r1.S.Val)
        }
    } else {
        # 방 결정: OCR 감지 > 내 주력 기반 추정
        # (관전처럼 내가 없는 탁자에서는 내 기반 추정을 쓰지 않음 - 각자 다수결로)
        $room = [int]$script:ScanRoomMode
        $roomOcr = ($room -gt 0)
        if ($room -lt 0) { $room = 0 }   # 비단위전(친선전 등): 방 없음 - 개인별 다수결
        elseif (-not $room -and $script:RoomGuess -and $script:SawMyNick) { $room = [int]$script:RoomGuess }
        # 상대 단위로 보정 (입장 범위: 작사=동·은, 작걸=은·금, 작호=금·옥, 작성=옥·왕, 혼천=왕):
        #  - OCR 확정 방: 입장 불가능한 단위만 보정 (금탁에 작성·혼천 불가, 옥탁에 작걸 이하 불가, 왕좌탁에 작호 이하 불가)
        #  - 추정 방: 작호부터 옥탁 기본 취급
        if ($room) {
            $isEastRoom = ($EastModes -contains $room)
            $goldCut = 5
            if (-not $roomOcr) { $goldCut = 4 }
            $newSouth = 0
            if ($room -le 9 -and $oppMajNow -ge $goldCut) { $newSouth = $(if ($oppMajNow -ge 6) { 16 } else { 12 }) }
            elseif ($room -ge 11 -and $room -le 12 -and $oppMajNow -le 3) { $newSouth = 9 }
            elseif ($room -ge 15 -and $oppMajNow -le 4) { $newSouth = 12 }
            if ($newSouth) {
                $room = $newSouth
                if ($isEastRoom) { $room = $newSouth - 1 }
            }
        }
        $goldN = Get-ModeCount $Id $statStart $nowPlus '9.8'
        $jadeN = Get-ModeCount $Id $statStart $nowPlus '12.11'
        $pri = $null; $sec = $null
        $subX = $null   # 표본 부족 시 같은 방 그룹의 반대쪽(동↔남) 보조 기준
        if ($room -ge 8 -and $room -le 9) {
            # 금탁: 기본은 금 기준. 금 20국 이하면 전적 부족(회색), 옥 20국+면 옥 기준 병행(금캉스 구분)
            # 국수 조회 실패(-1)는 불명 - 부족 판정 대신 계산을 시도하고, calc 자체 국수로 20국 규칙 재확인
            $roomEast = ($EastModes -contains $room)
            if ($goldN -gt 20 -or $goldN -lt 0) {
                $sp = & $subPlan 9 $roomEast
                $pri = $sp.P
                $subX = $sp.X
                if ($pri -and (-not $pri.S -or ($goldN -lt 0 -and [int]$pri.N -le 20))) { $pri = $null; $subX = $null }
            }
            if ($script:Settings.StableDual -and ($jadeN -ge 20 -or $jadeN -lt 0)) {
                $sec = & $calc (Get-SubMode $Id $statStart $nowPlus 12 $roomEast)
                if ($sec -and (-not $sec.S -or ($jadeN -lt 0 -and [int]$sec.N -lt 20))) { $sec = $null }
            }
            if (-not $pri -and -not $sec -and $goldN -ge 0) {
                $suffix = '  안정 전적 부족 (금탁 ' + $goldN + '국)'
                $oppTier = 'none'
                $suffixTier = 'none'
                $colorVal = 0.0
            }
        } elseif ($room -ge 11 -and $room -le 12) {
            # 옥탁: 옥 20국+면 옥 기준, 아니면 금 기준 폴백, 그것도 부족하면 전적 부족
            # 국수 조회 실패(-1)는 불명 - 부족 판정 대신 계산을 시도하고, calc 자체 국수로 20국 규칙 재확인
            $roomEast = ($EastModes -contains $room)
            if ($jadeN -ge 20 -or $jadeN -lt 0) {
                $sp = & $subPlan 12 $roomEast
                $pri = $sp.P
                $subX = $sp.X
                if ($pri -and (-not $pri.S -or ($jadeN -lt 0 -and [int]$pri.N -lt 20))) { $pri = $null; $subX = $null }
            }
            if (-not $pri -and ($goldN -gt 20 -or $goldN -lt 0)) {
                $sp = & $subPlan 9 $roomEast
                $pri = $sp.P
                $subX = $sp.X
                if ($pri -and (-not $pri.S -or ($goldN -lt 0 -and [int]$pri.N -le 20))) { $pri = $null; $subX = $null }
            }
            # 왕캉스 구분: 왕좌 20국+ 기록이 있는 상대는 왕좌 기준을 병행 표시
            if ($script:Settings.StableDualThrone) {
                $throneN = Get-ModeCount $Id $statStart $nowPlus '16.15'
                if ($throneN -ge 20 -or $throneN -lt 0) {
                    $sec = & $calc (Get-SubMode $Id $statStart $nowPlus 16 $roomEast)
                    if ($sec -and (-not $sec.S -or ($throneN -lt 0 -and [int]$sec.N -lt 20))) { $sec = $null }
                }
            }
            if (-not $pri -and -not $sec -and $jadeN -ge 0 -and $goldN -ge 0) {
                $suffix = '  안정 전적 부족 (옥 ' + $jadeN + '국·금 ' + $goldN + '국)'
                $oppTier = 'none'
                $suffixTier = 'none'
                $colorVal = 0.0
            }
        } elseif ($room -ge 15 -and $room -le 16) {
            # 왕좌탁: (설정) 방 기준을 먼저 보여주고 주력(다수결) 모드가 다르면 병행 - 왕좌 기록 부족하면 다수결만
            $roomEast = ($EastModes -contains $room)
            $throneN = Get-ModeCount $Id $statStart $nowPlus '16.15'
            if ([bool]$script:Settings.StableRoomFirst -and ($throneN -gt 20 -or $throneN -lt 0)) {
                $sp = & $subPlan 16 $roomEast
                $pri = $sp.P
                $subX = $sp.X
                if ($pri -and (-not $pri.S -or ($throneN -lt 0 -and [int]$pri.N -le 20))) { $pri = $null; $subX = $null }
            }
            $dm = Get-DominantMode $Id $statStart $nowPlus ([int]$effOpp.Id)
            if (-not $pri) {
                $pri = & $calc $dm
            } elseif ($dm -ne [int]$pri.M) {
                $sec = & $calc $dm
                if ($sec -and (-not $sec.S -or [int]$sec.N -lt 20)) { $sec = $null }
            }
        } else {
            # 방 미감지/비단위전: 기존 다수결
            $dm = Get-DominantMode $Id $statStart $nowPlus ([int]$effOpp.Id)
            $pri = & $calc $dm
        }
        # 방 기준 표본이 최소 표본에 못 미쳤으면 같은 방의 반대쪽(동↔남)을 보조로 (병행 표시가 비어 있을 때만)
        if (-not $sec -and $subX -and $pri -and [int]$subX.M -ne [int]$pri.M) { $sec = $subX }
        if (-not $suffix) {
            $parts = @()
            $tiers = @()
            $best = $null
            foreach ($rr in @($pri, $sec)) {
                if ($rr -and $rr.S) {
                    $parts += ('안정 ' + $rr.S.Text + ' (' + $ModeNames[$rr.M] + '·' + $rr.N + '국·' + (& $mkLabel $rr.B) + ' 기준)')
                    $tiers += (Get-StableTier ([double]$rr.S.Val))
                    # 닉네임 색은 두 기준 중 높은 쪽 (안정단 값은 연속 단일 척도)
                    if (-not $best -or ([double]$rr.S.Val -gt [double]$best.S.Val)) { $best = $rr }
                }
            }
            if ($parts.Count -gt 0) {
                # 병행(금+옥)은 가로 폭이 넓어지지 않도록 두 줄로 - 줄마다 자기 구간 색
                $suffix = '  ' + $parts[0]
                $suffixTier = $tiers[0]
                if ($parts.Count -gt 1) { $suffix2 = '  ' + $parts[1]; $suffix2Tier = $tiers[1] }
                $colorVal = $best.S.Val
                $oppTier = Get-StableTier ([double]$best.S.Val)
            }
        }
    }
    }
    $badges = Get-StyleBadges $fullStats $ext
    # 평균순위는 통계 줄(평균화료순 뒤)로 이동 - 전적 줄은 국수만 (지표 범위가 좁혀져 있으면 방 표기)
    $scopeName = ''
    if ($scopeMq -eq '9.8') { $scopeName = '금탁' } elseif ($scopeMq -eq '12.11') { $scopeName = '옥탁' } elseif ($scopeMq -eq '16.15') { $scopeName = '왕좌탁' }
    # 지표 범위 '안정단위 계산방': 안정단 1줄이 실제 사용한 모드·구간의 지표로 교체 (라벨도 그 모드명)
    # 안정단 계산이 없는 상대(혼천 등)는 현재 방 → 주력 방 순으로 폴백
    if ($scope -eq 'stable' -and -not $SkipStable) {
        if ($pri -and $pri.S -and $pri.St) {
            $ext2 = $null
            try { $ext2 = Invoke-Api "$Api/player_extended_stats/$Id/$($pri.Start)/$nowPlus`?mode=$($pri.M)" 15 } catch {}
            if ($ext2) {
                $stats = $pri.St
                $ext = $ext2
                $statParts = Get-StatParts $stats $ext
                $scopeName = [string]$ModeNames[[int]$pri.M]
            }
        } else {
            $stMq = ''
            $stName = ''
            $r5 = [int]$script:ScanRoomMode
            if ($r5 -le 0 -and $script:RoomGuess -and $script:SawMyNick) { $r5 = [int]$script:RoomGuess }
            if ($r5 -ge 15) { $stMq = '16.15'; $stName = '왕좌탁' } elseif ($r5 -ge 11) { $stMq = '12.11'; $stName = '옥탁' } elseif ($r5 -ge 8) { $stMq = '9.8'; $stName = '금탁' }
            if (-not $stMq) {
                $g4 = Get-ModeCount $Id $statStart $nowPlus '9.8'
                $j4 = Get-ModeCount $Id $statStart $nowPlus '12.11'
                $t4 = Get-ModeCount $Id $statStart $nowPlus '16.15'
                if ($g4 -gt 0 -or $j4 -gt 0 -or $t4 -gt 0) {
                    if ($t4 -ge $j4 -and $t4 -ge $g4) { $stMq = '16.15'; $stName = '왕좌탁' }
                    elseif ($j4 -ge $g4) { $stMq = '12.11'; $stName = '옥탁' }
                    else { $stMq = '9.8'; $stName = '금탁' }
                }
            }
            if ($stMq) {
                $s4 = Get-RangeStats $Id $statStart $nowPlus -ModeFilter $stMq
                $ext4 = $null
                try { $ext4 = Invoke-Api "$Api/player_extended_stats/$Id/$statStart/$nowPlus`?mode=$stMq" 15 } catch {}
                if ($s4 -and $s4.count -and $ext4) {
                    $stats = $s4
                    $ext = $ext4
                    $statParts = Get-StatParts $stats $ext
                    $scopeName = $stName
                }
            }
        }
    }
    $gameLine = '전적 {0}국' -f $stats.count
    # 지표 출처 표기: 통계 마지막 줄 오른쪽에 방·기간 한 번만 (표시 항목 '지표 출처 표기' 토글)
    if (@($statParts).Count -gt 0) {
        # 국당수지: 안정단위 계산에 쓴 방·구간의 기대수지 순액 (혼천·표본 없음이면 생략)
        $oppENet = $null
        if ($pri -and $pri.S -and $pri.St) { $oppENet = Get-NetPerGame $pri.S $pri.St ([int]$effOpp.Id) }
        if ($null -ne $oppENet) { $statParts = @($statParts) + @(@{ L = 5; K = 'ppg'; V = [double]$oppENet; T = ('국당수지 {0:+0.0;-0.0;±0}pt' -f [double]$oppENet) }) }
        $srcLabel = $(if ($scopeName) { $scopeName } else { '전체' })
        $srcBasis = $finalBasis
        if ($scope -eq 'stable' -and $scopeName -and $pri -and $pri.B) { $srcBasis = [string]$pri.B }
        $statParts = @($statParts) + @(@{ L = 5; K = 'statsrc'; V = 0.0; T = ('({0}·{1})' -f $srcLabel, (Get-BasisLabel $srcBasis)) })
    }
    $d = [pscustomobject]@{
        Name     = $stats.nickname
        NameSuffix = $suffix
        NameSuffix2 = $suffix2
        SuffixTier = $suffixTier
        SuffixTier2 = $suffix2Tier
        Badges = $badges
        NameColorVal = $colorVal
        StableTier = $oppTier
        RankLine = $rank.Text
        Diff     = $rank.Diff
        NoDiff   = $rank.NoDiff
        Seq      = $null
        Streak   = ''
        Pts      = $null
        CurPt    = $null
        GoalLine = ''
        GameLine = $gameLine
        StatParts = $statParts
        RankMajor = (([int][math]::Floor([int]$effOpp.Id / 100)) % 100)
        IsOpp = $true
        StablePhase = (-not [bool]$SkipStable)   # false면 아직 안정단 미계산(1차 부분 데이터)
    }
    # -SkipStable 1차 부분 결과는 캐시 금지 - 캐시되면 2차 전체 조회가 이걸 돌려받아 안정단이 영영 안 채워짐
    if (-not $SkipStable) { $script:OppCache["$Id"] = $d }
    return $d
}

# ---------------- 화면 OCR ----------------

$script:OcrOk = $false
try {
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms, System.Runtime.WindowsRuntime
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $script:OcrOk = ([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages.Count -gt 0)
} catch {}

# 물리 픽셀 <-> WPF 좌표(DIP) 환산 배율. 창 위치 계산 전에 정해져 있어야 한다
$script:DpiScale = 1.0
try {
    $gDpi = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:DpiScale = $gDpi.DpiX / 96.0
    $gDpi.Dispose()
} catch {}

function Await($WinRtTask, $ResultType) {
    $t = $script:AsTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($WinRtTask))
    $null = $t.Wait(-1)
    $t.Result
}

function Convert-FullWidth {
    param([string]$s)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0xFF01 -and $c -le 0xFF5E) { $null = $sb.Append([char]($c - 0xFEE0)) }
        elseif ($c -eq 0x3000) { }
        else { $null = $sb.Append($ch) }
    }
    $sb.ToString()
}

# 화면 전체를 OCR해서 텍스트 후보 목록 반환: @{Text; X; Y} (물리 픽셀 좌표)
function New-ResizedBitmap {
    param($Bmp, [double]$Scale)
    $nw = [int]($Bmp.Width * $Scale)
    $nh = [int]($Bmp.Height * $Scale)
    $resized = New-Object Drawing.Bitmap $nw, $nh
    $g2 = [Drawing.Graphics]::FromImage($resized)
    $g2.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.DrawImage($Bmp, 0, 0, $nw, $nh)
    $g2.Dispose()
    return $resized
}

# 비트맵 하나를 모든 OCR 엔진으로 인식 → 토큰(@{Text;X;Y}, 비트맵 픽셀 기준) 반환
function Invoke-OcrBitmap {
    param($Bmp)
    $tmp = Join-Path $env:TEMP 'mjs-overlay-ocr.png'
    $Bmp.Save($tmp, [Drawing.Imaging.ImageFormat]::Png)

    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb2 = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

    $tokens = New-Object Collections.ArrayList
    foreach ($lang in [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
        if (-not $engine) { continue }
        $result = Await ($engine.RecognizeAsync($sb2)) ([Windows.Media.Ocr.OcrResult])
        foreach ($line in $result.Lines) {
            $lineText = ''
            $x = $null; $y = $null
            $wordTokens = @()
            foreach ($w in $line.Words) {
                $r = $w.BoundingRect
                if ($null -eq $x) { $x = [double]$r.X; $y = [double]$r.Y }
                $t = Convert-FullWidth $w.Text
                $lineText += $t
                $wordTokens += , @{ Text = $t; X = [double]$r.X; Y = [double]$r.Y }
            }
            # 줄 전체(완전한 닉 후보)를 단어 조각보다 먼저 시도
            if ($lineText) {
                $null = $tokens.Add(@{ Text = $lineText; X = $x; Y = $y })
            }
            foreach ($wt in $wordTokens) { $null = $tokens.Add($wt) }
        }
    }
    $stream.Dispose()
    return $tokens
}

# ---------------- 게임 창 위치 ----------------
# 모든 좌표 계산의 기준. 창모드·보조 모니터·모니터 걸침·다른 해상도를 지원하기 위해
# '주 모니터 전체'가 아니라 '게임 창의 16:9 화면 영역'을 기준으로 삼는다.
$script:GameTitleWords = @('작혼', '雀魂', 'Mahjong Soul', 'MahjongSoul', 'Majsoul', '雀魂麻将', '雀魂麻將')
$script:GameProcNames = @('Jantama_MahjongSoul', 'majsoul')

function Find-GameWindow {
    # 콜백 안에서 쓰는 값은 전부 script 스코프로 - 델리게이트 호출마다 스코프가 새로 생겨 지역 변수는 유지되지 않는다
    $script:FoundWin = [IntPtr]::Zero
    $script:FoundArea = 0.0
    $script:FindNames = @($script:GameProcNames)
    if ($script:GameProcName) { $script:FindNames = @([string]$script:GameProcName) + $script:FindNames }
    $cb = [Native+EnumProc] {
        param($h, $p)
        try {
            if (-not [Native]::IsWindowVisible($h) -or [Native]::IsIconic($h)) { return $true }
            $cr = New-Object Native+RECT
            if (-not [Native]::GetClientRect($h, [ref]$cr)) { return $true }
            if ($cr.R -lt 400 -or $cr.B -lt 300) { return $true }
            $area = [double]$cr.R * [double]$cr.B
            if ($area -le $script:FoundArea) { return $true }
            $hit = $false
            $procId = 0
            $null = [Native]::GetWindowThreadProcessId($h, [ref]$procId)
            try {
                $pn = (Get-Process -Id $procId -ErrorAction Stop).ProcessName
                foreach ($n in $script:FindNames) { if ($n -and $pn -like "*$n*") { $hit = $true; break } }
            } catch {}
            if (-not $hit) {
                $sb = New-Object Text.StringBuilder 512
                $null = [Native]::GetWindowTextW($h, $sb, 512)
                $t = $sb.ToString()
                if ($t) { foreach ($k in $script:GameTitleWords) { if ($t -like "*$k*") { $hit = $true; break } } }
            }
            if ($hit) { $script:FoundWin = $h; $script:FoundArea = $area }
        } catch {}
        return $true
    }
    $null = [Native]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:FoundWin
}

# 게임 화면은 항상 16:9로 그려진다 - 창 비율이 다르면 위아래(레터박스)/좌우(필러박스) 여백을 잘라낸다
function ConvertTo-ContentRect {
    param($R)
    $target = 16.0 / 9.0
    if ([double]$R.H -le 0) { return $R }
    $ar = [double]$R.W / [double]$R.H
    if ($ar -gt $target + 0.01) {
        $nw = [int]([double]$R.H * $target)
        $R.X += [int](([double]$R.W - $nw) / 2); $R.W = $nw
    } elseif ($ar -lt $target - 0.01) {
        $nh = [int]([double]$R.W / $target)
        $R.Y += [int](([double]$R.H - $nh) / 2); $R.H = $nh
    }
    return $R
}

# 게임 화면 영역(물리 픽셀, 가상 데스크톱 좌표). 창을 못 찾으면 주 모니터 전체로 대체.
function Get-GameRect {
    param([switch]$Fresh)
    if (-not $Fresh -and $script:GameRect -and ((Get-Date) - $script:GameRectAt).TotalMilliseconds -lt 1000) {
        return $script:GameRect
    }
    $r = $null
    try {
        $h = Find-GameWindow
        if ($h -ne [IntPtr]::Zero) {
            $cr = New-Object Native+RECT
            $pt = New-Object Native+POINT
            if ([Native]::GetClientRect($h, [ref]$cr) -and [Native]::ClientToScreen($h, [ref]$pt)) {
                if ($cr.R -gt 200 -and $cr.B -gt 150) {
                    $r = @{ X = [int]$pt.X; Y = [int]$pt.Y; W = [int]$cr.R; H = [int]$cr.B }
                }
            }
        }
    } catch {}
    if (-not $r) {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $r = @{ X = [int]$b.X; Y = [int]$b.Y; W = [int]$b.Width; H = [int]$b.Height }
    }
    $r = ConvertTo-ContentRect $r
    $script:GameRect = $r
    $script:GameRectAt = Get-Date
    return $r
}

# 게임 화면 영역을 DIP(창 좌표계) 단위로
function Get-GameRectDip {
    $r = Get-GameRect
    $d = [double]$script:DpiScale
    if ($d -le 0) { $d = 1.0 }
    return @{ X = $r.X / $d; Y = $r.Y / $d; W = $r.W / $d; H = $r.H / $d }
}

function Get-ScreenCapture {
    $r = Get-GameRect -Fresh
    $bmp = New-Object Drawing.Bitmap $r.W, $r.H
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.X, $r.Y, 0, 0, (New-Object Drawing.Size $r.W, $r.H))
    $g.Dispose()
    $script:CapRect = $r
    return $bmp
}

# 캡처 비트맵 좌표 -> 화면 절대 좌표 (게임 창이 어느 모니터에 있든 통하도록)
function Get-CapOrigin {
    if ($script:CapRect) { return @($script:CapRect.X, $script:CapRect.Y) }
    return @(0, 0)
}

# 게임 화면 전체 1.6배 확대 스캔
function Get-FullTokens {
    param($Bmp)
    $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    $scale = [math]::Min(1.6, [math]::Min($maxDim / $Bmp.Width, $maxDim / $Bmp.Height))
    $full = New-ResizedBitmap $Bmp $scale
    $o = Get-CapOrigin
    $out = New-Object Collections.ArrayList
    foreach ($t in (Invoke-OcrBitmap $full)) {
        $null = $out.Add(@{ Text = $t.Text; X = ($o[0] + $t.X / $scale); Y = ($o[1] + $t.Y / $scale); Src = 'f' })
    }
    $full.Dispose()
    return $out
}

# ═══ PaddleOCR 엔진 (동봉형, 있으면 우선 사용) ═══
# engine 폴더 아래 어디에 있든 PaddleOCR-json.exe를 찾음 (버전 폴더명 무관, 바로 넣어도 됨)
$script:PaddleExe = $null
try {
    $engDir = Join-Path $script:BaseDir 'engine'
    if (Test-Path $engDir) {
        $hit = Get-ChildItem $engDir -Filter 'PaddleOCR-json.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -First 1
        if ($hit) { $script:PaddleExe = $hit.FullName }
    }
} catch {}
$script:PaddleOk = [bool]$script:PaddleExe
$script:PaddleFails = 0

# 한 언어 모델 프로세스로 여러 이미지를 인식 (요청당 JSON 한 줄)
function Trace-Paddle { param([string]$M)
    try {
        $f = Join-Path $script:DataDir 'paddle-debug.txt'
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 200KB) { Remove-Item $f -Force }
        Add-Content -Path $f -Value "$(Get-Date -Format HH:mm:ss.fff) [$PID] $M" -Encoding UTF8
    } catch {}
}

function Invoke-PaddleBatch {
    param([string]$Config, [string[]]$Images)
    $out = @()
    $proc = $null
    Trace-Paddle "batch start: $Config ($($Images.Count) imgs)"
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = $script:PaddleExe
        $psi.Arguments = "--config_path=models/config_$Config.txt"
        $psi.WorkingDirectory = Split-Path $script:PaddleExe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.CreateNoWindow = $true
        $proc = [Diagnostics.Process]::Start($psi)
        Trace-Paddle "proc started: $Config pid=$($proc.Id)"
        $proc.BeginErrorReadLine()
        foreach ($img in $Images) {
            $proc.StandardInput.WriteLine('{"image_path": "' + $img.Replace([string][char]0x5C, '/') + '"}')
        }
        $proc.StandardInput.Flush()
        $got = 0
        for ($i = 0; $i -lt 400 -and $got -lt $Images.Count; $i++) {
            $task = $proc.StandardOutput.ReadLineAsync()
            if (-not $task.Wait(20000)) { Trace-Paddle "read timeout: $Config"; break }   # 20초 내 응답 없으면 포기
            $line = $task.Result
            if ($null -eq $line) { break }
            if (-not $line.StartsWith('{')) { continue }
            $res = $null
            try { $res = $line | ConvertFrom-Json } catch {}
            $out += , @{ Img = $Images[$got]; Res = $res }
            $got++
        }
    } catch { Trace-Paddle "batch 예외: $($_.Exception.Message)" } finally {
        if ($proc) { try { $proc.Kill() } catch {} }
    }
    Trace-Paddle "batch done: $Config -> $($out.Count)"
    return $out
}

# Paddle로 전체 화면 + 명패 확대 크롭을 인식해 파이프라인 토큰 형식으로 반환
function Get-PaddleTokens {
    param($Bmp)
    Trace-Paddle 'Get-PaddleTokens start'
    $tmp = $env:TEMP
    $imgs = @()
    $meta = @{}
    # 전체 화면
    $fp = Join-Path $tmp "mjs-paddle-$PID-full.png"
    $Bmp.Save($fp, [Drawing.Imaging.ImageFormat]::Png)
    $imgs += $fp
    $meta[$fp] = @{ RX = 0; RY = 0; Z = 1.0; Src = 'f' }
    # 명패 크롭 4곳 (4배 확대)
    $bands = @(
        @(0.000, 0.29, 0.15, 0.12),
        @(0.66,  0.07, 0.24, 0.12),
        @(0.85,  0.29, 0.15, 0.12),
        @(0.15,  0.74, 0.22, 0.14)
    )
    $bi = 0
    foreach ($bd in $bands) {
        $rx = [int]($Bmp.Width * $bd[0]); $ry = [int]($Bmp.Height * $bd[1])
        $rw = [int]($Bmp.Width * $bd[2]); $rh = [int]($Bmp.Height * $bd[3])
        if ($rx + $rw -gt $Bmp.Width) { $rw = $Bmp.Width - $rx }
        if ($ry + $rh -gt $Bmp.Height) { $rh = $Bmp.Height - $ry }
        try {
            $crop = $Bmp.Clone((New-Object Drawing.Rectangle $rx, $ry, $rw, $rh), $Bmp.PixelFormat)
            $big = New-ResizedBitmap $crop 4.0
            $crop.Dispose()
            $cp = Join-Path $tmp "mjs-paddle-$PID-b$bi.png"
            $big.Save($cp, [Drawing.Imaging.ImageFormat]::Png)
            $big.Dispose()
            $imgs += $cp
            $meta[$cp] = @{ RX = $rx; RY = $ry; Z = 4.0; Src = 'p' }
        } catch {}
        $bi++
    }
    Trace-Paddle "images ready: $($imgs.Count)"
    $tokens = New-Object Collections.ArrayList
    foreach ($cfg in 'japan', 'chinese', 'korean') {
        foreach ($r in (Invoke-PaddleBatch $cfg $imgs)) {
            if (-not $r.Res -or $r.Res.code -ne 100) { continue }
            $m = $meta[[string]$r.Img]
            foreach ($d in $r.Res.data) {
                # 신뢰도 필터: 잡음 원천 차단 (명패 크롭은 완화)
                $minScore = 0.60
                if ($m.Src -eq 'p') { $minScore = 0.45 }
                if ([double]$d.score -lt $minScore) { continue }
                $t = Convert-FullWidth ([string]$d.text)
                if (-not $t) { continue }
                $null = $tokens.Add(@{
                    Text = $t
                    X = ($m.RX + [double]$d.box[0][0] / $m.Z)
                    Y = ($m.RY + [double]$d.box[0][1] / $m.Z)
                    Src = [string]$m.Src
                })
            }
        }
    }
    Trace-Paddle "tokens: $($tokens.Count)"
    return $tokens
}

# 상대 명패 정밀 스캔 - 좁은 영역을 크게 확대할수록 인식률이 크게 오름
$script:PlateBands = @(
    @(0.000, 0.29, 0.15, 0.12, 8.0),   # 왼쪽 이름표 (정밀)
    @(0.66,  0.07, 0.24, 0.12, 8.0),   # 상단 이름표 (정밀)
    @(0.85,  0.29, 0.15, 0.12, 8.0),   # 오른쪽 이름표 (정밀)
    @(0.15,  0.74, 0.22, 0.14, 8.0),   # 하단(내 자리) 이름표 - 관전 시 4번째 플레이어 (정밀)
    @(0.00,  0.22, 0.24, 0.28, 4.0),   # 왼쪽 (광역)
    @(0.58,  0.03, 0.38, 0.22, 4.0),   # 상단 (광역)
    @(0.76,  0.22, 0.24, 0.28, 4.0),   # 오른쪽 (광역)
    @(0.10,  0.70, 0.32, 0.20, 4.0)    # 하단 (광역)
)

# 못 찾은 채로 스캔이 끝나면 OCR이 실제로 뭘 봤는지 확인할 수 있게 명패 크롭을 남긴다
function Save-PlateCrops {
    param($Bmp)
    $names = @('left', 'top', 'right', 'bottom')
    for ($i = 0; $i -lt 4; $i++) {
        $bd = $script:PlateBands[$i]
        try {
            $rx = [int]($Bmp.Width * $bd[0]); $ry = [int]($Bmp.Height * $bd[1])
            $rw = [int]($Bmp.Width * $bd[2]); $rh = [int]($Bmp.Height * $bd[3])
            if ($rx + $rw -gt $Bmp.Width) { $rw = $Bmp.Width - $rx }
            if ($ry + $rh -gt $Bmp.Height) { $rh = $Bmp.Height - $ry }
            if ($rw -le 0 -or $rh -le 0) { continue }
            $crop = $Bmp.Clone((New-Object Drawing.Rectangle $rx, $ry, $rw, $rh), $Bmp.PixelFormat)
            $crop.Save((Join-Path $script:DataDir "scan-plate-$($names[$i]).png"), [Drawing.Imaging.ImageFormat]::Png)
            $crop.Dispose()
        } catch {}
    }
}

function Get-PlateTokens {
    param($Bmp, [int]$Pass = 0)
    $out = New-Object Collections.ArrayList
    # @(x, y, w, h, 확대배율) - 이름표 주변만 좁게 자른 고배율 + 여유 있는 저배율(위치 오차 대비)
    $bands = $script:PlateBands
    # 1차 시도는 정밀(고배율) 밴드만 - 빠르게. 이후 시도에서 광역 밴드까지 확장
    if ($Pass -eq 0) { $bands = @($bands | Where-Object { [double]$_[4] -ge 6.0 }) }
    $o = Get-CapOrigin
    foreach ($bd in $bands) {
        $rx = [int]($Bmp.Width * $bd[0]); $ry = [int]($Bmp.Height * $bd[1])
        $rw = [int]($Bmp.Width * $bd[2]); $rh = [int]($Bmp.Height * $bd[3])
        if ($rx -lt 0) { $rx = 0 }
        if ($ry -lt 0) { $ry = 0 }
        if ($rx + $rw -gt $Bmp.Width) { $rw = $Bmp.Width - $rx }
        if ($ry + $rh -gt $Bmp.Height) { $rh = $Bmp.Height - $ry }
        if ($rw -le 0 -or $rh -le 0) { continue }
        try {
            $crop = $Bmp.Clone((New-Object Drawing.Rectangle $rx, $ry, $rw, $rh), $Bmp.PixelFormat)
            $z = [double]$bd[4]
            $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
            $lim = [math]::Min($maxDim / [math]::Max(1, $crop.Width), $maxDim / [math]::Max(1, $crop.Height))
            if ($z -gt $lim) { $z = $lim }
            $big = New-ResizedBitmap $crop $z
            $crop.Dispose()
            foreach ($t in (Invoke-OcrBitmap $big)) {
                $null = $out.Add(@{ Text = $t.Text; X = ($o[0] + $rx + $t.X / $z); Y = ($o[1] + $ry + $t.Y / $z); Src = 'p' })
            }
            $big.Dispose()
        } catch {}
    }
    return $out
}

$StopWords = @('랭크','전적','점수','평균순위','화료','방총','후로','칭호없음','로딩','불러오기','오버레이',
               '반장전','동장전','금의','옥의','왕좌의','은의','동의','금탁','친선전','단위전','대회전','관전',
               '동풍전','금의방','옥의방','왕좌의방','은의방','동의방','승격전','최종순위','종국','유국','오라스',
               '연장전','시합종료','정산','획득','합계','리치','쯔모','론','더블론','유국만관','최종성적',
               'MAKA','BETA','패보','패보재생','패산','등급전','잔여분석횟수','즐겨찾기','전체평점','이번평점',
               '텐파이표시','사용중','툴바','분기점','이전분기점으로','다음분기점으로','대국시작','기타패보')

$script:GoalOptions = @(0, 50, 100, 150, 200, 300, 500)
$script:MinNOptions = @(0, 10, 20, 30, 50, 70, 100, 150, 200, 300, 500, 700, 1000)

# 단축키 선택지와 가상 키코드
$script:KeyOptions = @('F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12', '사용 안 함')
$script:VKMap = @{}
for ($i = 1; $i -le 12; $i++) { $script:VKMap["F$i"] = 0x6F + $i }

# OCR이 반탁점(゚)을 。로 오인식하는 케이스 보정용 (ほ。→ぽ)
$script:HandakuMap = @{
    'は' = 'ぱ'; 'ひ' = 'ぴ'; 'ふ' = 'ぷ'; 'へ' = 'ぺ'; 'ほ' = 'ぽ'
    'ハ' = 'パ'; 'ヒ' = 'ピ'; 'フ' = 'プ'; 'ヘ' = 'ペ'; 'ホ' = 'ポ'
}
# 한자·라틴 글자로 잘못 읽히는 가타카나 혼동 보정표
$script:KanaLookalike = @{
    '厶' = 'ム'; '示' = 'ポ'; '工' = 'エ'; '力' = 'カ'; '口' = 'ロ'
    '夕' = 'タ'; '卜' = 'ト'; '二' = 'ニ'; '八' = 'ハ'; 'L' = 'ム'
    '才' = 'オ'; '一' = 'ー'; '-' = 'ー'; '―' = 'ー'; '─' = 'ー'; '亍' = 'テ'
}

# 가나 혼동 교정: OCR 전형 방향(큰→작은 가나, 무탁점→탁점) 일괄 치환용 맵과 양방향 대안 맵
$script:KanaFix = @{}
$script:KanaAlt = @{}
foreach ($pr in @('アァ', 'イィ', 'ウゥ', 'エェ', 'オォ', 'ヤャ', 'ユュ', 'ヨョ', 'ツッ',
                  'あぁ', 'いぃ', 'うぅ', 'えぇ', 'おぉ', 'やゃ', 'ゆゅ', 'よょ', 'つっ',
                  'カガ', 'キギ', 'クグ', 'ケゲ', 'コゴ', 'サザ', 'シジ', 'スズ', 'セゼ', 'ソゾ',
                  'タダ', 'チヂ', 'テデ', 'トド', 'ハバ', 'ヒビ', 'フブ', 'ヘベ', 'ホボ',
                  'かが', 'きぎ', 'くぐ', 'けげ', 'こご', 'さざ', 'しじ', 'すず', 'せぜ', 'そぞ',
                  'ただ', 'ちぢ', 'てで', 'とど', 'はば', 'ひび', 'ふぶ', 'へべ', 'ほぼ',
                  'バパ', 'ビピ', 'ブプ', 'ベペ', 'ボポ', 'ばぱ', 'びぴ', 'ぶぷ', 'べぺ', 'ぼぽ',
                  'ハパ', 'ヒピ', 'フプ', 'ヘペ', 'ホポ', 'はぱ', 'ひぴ', 'ふぷ', 'へぺ', 'ほぽ',
                  '剣剑', '悪恶')) {
    $a = [string]$pr[0]; $b = [string]$pr[1]
    $script:KanaFix[$a] = $b
    if (-not $script:KanaAlt.ContainsKey($a)) { $script:KanaAlt[$a] = @() }
    if (-not $script:KanaAlt.ContainsKey($b)) { $script:KanaAlt[$b] = @() }
    $script:KanaAlt[$a] += $b
    $script:KanaAlt[$b] += $a
}
# 바탕 글자 모양 혼동 (탁점은 제대로 읽은 경우: ハイグ → ハイゲ). 탁점을 지우는 대안보다 먼저 시도되게 앞에 삽입
foreach ($pr in @('クケ', 'グゲ', 'ソン', 'シツ', 'くけ', 'ぐげ')) {
    $a = [string]$pr[0]; $b = [string]$pr[1]
    if (-not $script:KanaAlt.ContainsKey($a)) { $script:KanaAlt[$a] = @() }
    if (-not $script:KanaAlt.ContainsKey($b)) { $script:KanaAlt[$b] = @() }
    $script:KanaAlt[$a] = @($b) + $script:KanaAlt[$a]
    $script:KanaAlt[$b] = @($a) + $script:KanaAlt[$b]
}

function Get-TokenVariants {
    param([string]$Raw, [bool]$Deep = $false)
    $variants = New-Object Collections.ArrayList
    try {
        $trimChars = [char[]]@('.', ',', [char]0xB7, "'", '|', '~', '-', '_', '/', [char]0x5C, '(', ')', '[', ']', '{', '}', '<', '>', '!', ':', ';', '"', [char]0x60, [char]0x2018, [char]0x2019,
                               [char]0x3001, [char]0x3002, [char]0xFF0C, [char]0xFF61, [char]0xFF64, [char]0x30FB)
        # 원본과 "앞뒤 구두점 제거본" 양쪽에 모든 보정을 적용
        $bases = New-Object Collections.ArrayList
        $null = $bases.Add($Raw)
        $trimmed = $Raw.Trim($trimChars)
        if ($trimmed -and $trimmed -ne $Raw) { $null = $bases.Add($trimmed) }

        foreach ($base in $bases) {
            if ($variants -notcontains $base) { $null = $variants.Add($base) }

            # 반탁점 오인식 (ほ。→ ぽ)
            $fixed = [regex]::Replace($base, '([はひふへほハヒフヘホ])[。゜°]', {
                param($m) $script:HandakuMap[$m.Groups[1].Value]
            })
            if ($fixed -ne $base -and $variants -notcontains $fixed) { $null = $variants.Add($fixed) }

            # 한자/라틴으로 잘못 읽힌 가나 보정 (示厶地 → ポム地, 才一 → オー)
            $kana = $base
            if ($base -match '[぀-ヿ一-鿿]') {
                foreach ($k in @($script:KanaLookalike.Keys)) { $kana = $kana.Replace($k, $script:KanaLookalike[$k]) }
                if ($kana -ne $base -and $variants -notcontains $kana) { $null = $variants.Add($kana) }
            }

            # 괄호 잡음 제거 - 라틴 여부와 무관 (テっっj가 テっっ」로 읽히는 케이스: 제거본의 접두 검색이
            # 실닉을 후보로 가져오고, 정규형 」→j 접기가 매칭을 이어받음)
            if ($base -match '[「」｢｣]') {
                $v = $base -replace '[「」｢｣]', ''
                if ($v -and $v.Length -ge 2 -and $variants -notcontains $v) { $null = $variants.Add($v) }
            }

            # 명패 토큰: 가나 크기/탁점·반탁점 혼동 보정 (リインテュノア → リィンデュノア, おリープ → おリーブ)
            if ($Deep) {
                foreach ($src in @($base, $kana, $fixed)) {
                    # 가나 또는 등록된 한자 혼동쌍(剣↔剑 등)이 있을 때만 - 한자 쌍을 추가하면 이 문자 클래스에도 넣을 것
                    if (-not $src -or $src -notmatch '[ぁ-ゖァ-ヺ剣剑悪恶]') { continue }
                    $chars = $src.ToCharArray()
                    $positions = @()
                    for ($i = 0; $i -lt $chars.Count; $i++) {
                        if ($script:KanaAlt.ContainsKey([string]$chars[$i])) { $positions += $i }
                    }
                    if ($positions.Count -eq 0 -or $positions.Count -gt 5) { continue }
                    # 전형 방향 일괄 치환 (큰→작은 가나, 무탁점→탁점)
                    $comb = [char[]]$chars.Clone()
                    $changed = $false
                    foreach ($pos in $positions) {
                        $c = [string]$chars[$pos]
                        if ($script:KanaFix.ContainsKey($c)) { $comb[$pos] = ([string]$script:KanaFix[$c])[0]; $changed = $true }
                    }
                    if ($changed) {
                        $v = -join $comb
                        if ($variants -notcontains $v) { $null = $variants.Add($v) }
                    }
                    # 같은 글자만 전체 양방향 치환 (えいえいおー → えぃえぃおー: 반복 가나가 모두 같은 방향으로 오인식된 경우)
                    $seenCh = @{}
                    foreach ($pos in $positions) {
                        $c = [string]$chars[$pos]
                        if ($seenCh.ContainsKey($c)) { continue }
                        $seenCh[$c] = $true
                        foreach ($alt in $script:KanaAlt[$c]) {
                            $v = $src.Replace($c, [string]$alt)
                            if ($variants -notcontains $v) { $null = $variants.Add($v) }
                        }
                    }
                    # 한 글자씩 양방향 치환
                    foreach ($pos in $positions) {
                        foreach ($alt in $script:KanaAlt[[string]$chars[$pos]]) {
                            $one = [char[]]$chars.Clone()
                            $one[$pos] = ([string]$alt)[0]
                            $v = -join $one
                            if ($variants -notcontains $v) { $null = $variants.Add($v) }
                        }
                    }
                }
            }

            # 숫자 0 ↔ 문자 o/O 혼동 (masay04 → masayo4)
            if ($base -match '0' -and $base -match '[A-Za-z]') {
                foreach ($v in @($base.Replace('0', 'o'), $base.Replace('0', 'O'))) {
                    if ($variants -notcontains $v) { $null = $variants.Add($v) }
                }
            }
            # 순위 마커 제거 (1위天然水 → 天然水)
            if ($base -match '^[1-4](위|位)') {
                $v = $base -replace '^[1-4](위|位)', ''
                if ($v -and $v.Length -ge 2 -and $variants -notcontains $v) { $null = $variants.Add($v) }
            }
            # 순위 배지 잡음 제거: 앞머리 숫자(+기호 1글자) 떼기 (1爿天然水 → 天然水)
            if ($base -match '^\d') {
                foreach ($v in @(($base -replace '^\d+', ''), ($base -replace '^\d+[^0-9]', ''))) {
                    if ($v -and $v.Length -ge 2 -and $variants -notcontains $v) { $null = $variants.Add($v) }
                }
            }
            # 장음 기호 ー ↔ 한자 一 혼동 (喝水我要喝ー桶 → 喝水我要喝一桶)
            if ($base.Contains([string][char]0x30FC)) {
                $v = $base.Replace([string][char]0x30FC, [string][char]0x4E00)
                if ($variants -notcontains $v) { $null = $variants.Add($v) }
            }
            # 가나 へ/ヘ로 잘못 읽힌 전각 물결 (じゃんにへにへ → じゃんに〜に〜)
            if ($base -match '[へヘ]' -and $base -match '[ぁ-ゖァ-ヺ]') {
                foreach ($v in @($base.Replace([string][char]0x3078, [string][char]0x301C), $base.Replace([string][char]0x30D8, [string][char]0x301C))) {
                    if ($v -ne $base -and $variants -notcontains $v) { $null = $variants.Add($v) }
                }
            }
            # 물결표 정규화: OCR의 ASCII ~ → 닉네임의 전각 물결 (貞~照 → 貞〜照)
            if ($base.Contains('~')) {
                foreach ($v in @($base.Replace('~', [string][char]0x301C), $base.Replace('~', [string][char]0xFF5E))) {
                    if ($variants -notcontains $v) { $null = $variants.Add($v) }
                }
            }
            # 라틴 혼동: l ↔ I ↔ 1 ↔ | (CompiIingjay → Compilingjay)
            if ($base -match '[A-Za-z]') {
                foreach ($v in @($base.Replace('I', 'l'), $base.Replace('l', 'I'),
                                 $base.Replace('|', 'l'), $base.Replace('|', 'I'),
                                 $base.Replace('1', 'l'), $base.Replace([string][char]0x300D, ''))) {
                    if ($v -and $v -ne $base -and $variants -notcontains $v) { $null = $variants.Add($v) }
                }
            }
        }
    } catch {}
    return $variants
}

# 두 문자열의 유사도 (레벤슈타인 기반, 0~1)
function Get-StrSimilarity {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return 0.0 }
    $n = $A.Length; $m = $B.Length
    $prev = New-Object 'int[]' ($m + 1)
    $cur = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1
            if ($A[$i - 1] -eq $B[$j - 1]) { $cost = 0 }
            $cur[$j] = [math]::Min([math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
        }
        [array]::Copy($cur, $prev, $m + 1)
    }
    $dist = $prev[$m]
    $mx = [math]::Max($n, $m)
    return (1.0 - ($dist / $mx))
}

# 유사도 비교 전 정규화: OCR이 서로 자주 바꿔 읽는 점·따옴표류(丶 ` ' 、 ・ …)를 한 글자로 통일
$script:DotChars = @([char]0x0060, [char]0x0027, [char]0x00B4, [char]0x2018, [char]0x2019, [char]0x02BB,
                     [char]0x02BC, [char]0x00B7, [char]0x2022, [char]0x30FB, [char]0x3001, [char]0x3002,
                     [char]0x30FD, [char]0x309D, [char]0x4E36, [char]0xFF0C, [char]0xFF61, [char]0xFF64)
function Get-NickCanon {
    param([string]$S, [switch]$StripDots)
    if (-not $S) { return '' }
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $S.ToCharArray()) {
        $c = $ch
        $code = [int]$c
        # 전각 영숫자·기호 → 반각 (Ａ→A, ～→~)
        if ($code -ge 0xFF01 -and $code -le 0xFF5E) { $c = [char]($code - 0xFEE0); $code = [int]$c }
        # 장식 문자 (점·따옴표류 + 마침표·말줄임·물결)
        if ($script:DotChars -contains $c -or $code -eq 0x2E -or $code -eq 0x2026 -or $code -eq 0x7E -or $code -eq 0x301C) {
            # StripDots(fold): 완전 제거 - 위치 무관하게 장식만 다른 닉을 같게 판정 (丶紅葉 ↔ 紅葉)
            if ($StripDots) { continue }
            # 기본(canon): 丶로 접고 연속 축약 - 유사도 계산에서 장식 존재 자체는 정보로 유지 (韶隼` ↔ 韶华丶)
            if ($sb.Length -gt 0 -and $sb[$sb.Length - 1] -eq [char]0x4E36) { continue }
            $null = $sb.Append([char]0x4E36); continue
        }
        # 가타카나 → 히라가나 (검색 API도 서버측에서 접는 축 - ー(장음)와 ヷ~ヺ는 제외)
        if ($code -ge 0x30A1 -and $code -le 0x30F6) { $c = [char]($code - 0x60); $code = [int]$c }
        # 라틴/숫자 혼동 클래스: 1|Il→l, 0Oo→o, 」→j(라틴 j가 닫는 괄호로 오인식됨), 나머지 대문자는 소문자로
        if ($code -eq 0x300D -or $code -eq 0xFF63) { $c = [char]0x6A; $code = 0x6A }
        elseif ($code -eq 0x31 -or $code -eq 0x7C -or $code -eq 0x49) { $c = [char]0x6C; $code = 0x6C }
        elseif ($code -eq 0x30 -or $code -eq 0x4F) { $c = [char]0x6F; $code = 0x6F }
        elseif ($code -ge 0x41 -and $code -le 0x5A) { $c = [char]($code + 0x20); $code = [int]$c }
        # 가나 크기·탁점 혼동을 대표형으로 접음 - 여러 글자가 어떤 조합으로 오인식됐든
        # (えいえぃおー든 えぃえいおー든) 정규형이 같으면 같은 닉으로 판정 (조합 폭발 없이 전 경우 커버)
        $k = [string]$c
        if ($script:KanaFix.ContainsKey($k)) { $null = $sb.Append(([string]$script:KanaFix[$k])[0]); continue }
        $null = $sb.Append($c)
    }
    return $sb.ToString()
}

# 통일 스코어러: 검색 응답 후보들을 신뢰 등급으로 점수화해 최적 후보를 고름
#  Conf 2 = 원문 정확 일치(-ceq) / 1 = fold 동일(장식 제거+가나·라틴 접기 후 동일) / 0 = canon 유사도 채택
#  검색 API가 대소문자·히라↔가타·작은 가나·탁점을 서버측에서 접어주므로 정답 후보는 대개 응답 안에 있음 -
#  위치별(앞/중간/뒤) 특례 없이 여기서 한 번에 판정. 유사(Conf 0)는 AllowSim일 때만 (잡음 증폭 방지)
function Select-NickCandidate {
    param([string]$T, $Cands, [bool]$AllowSim = $false, [switch]$Quiet)
    if (-not $T) { return $null }
    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-60).ToUnixTimeMilliseconds()
    $myNick = $script:Nickname
    $myFold = ''
    if ($myNick) { $myFold = Get-NickCanon $myNick -StripDots }
    $tFold = Get-NickCanon $T -StripDots
    $tCanon = Get-NickCanon $T
    $exact = $null
    $foldHits = New-Object Collections.ArrayList
    $best = $null; $bestS = 0.0; $secondS = 0.0; $nCand = 0
    $dormantExact = $null; $dormantExactTs = [long]0
    $dormantFold = $null; $dormantFoldTs = [long]0
    foreach ($c in $Cands) {
        if ($null -eq $c -or $c -is [array]) { continue }
        $nick = $c.nickname -as [string]
        if (-not $nick) { continue }
        $ts = $c.latest_timestamp -as [long]
        if ($null -eq $ts) { continue }
        if (($ts * 1000) -le $cutoff) {
            # 휴면 계정: 정확/fold 일치만 최후 폴백 후보로 보관 - 지금 판을 치는 복귀 유저는
            # 마지막 '기록된' 대국이 60일 이전이라 활동 필터에 걸릴 수 있음 (Credo1 사고)
            if (Test-RoomEntryOk $c.level.id) {
                $nFoldD = Get-NickCanon $nick -StripDots
                $isMyD = ($myNick -and ($nick -eq $myNick -or ($myFold.Length -ge 2 -and $nFoldD -ceq $myFold)))
                if (-not $isMyD) {
                    if ($nick -ceq $T) {
                        if ($ts -gt $dormantExactTs) { $dormantExact = $c; $dormantExactTs = $ts }
                    } elseif ($tFold.Length -ge 2 -and $nFoldD -ceq $tFold) {
                        if ($ts -gt $dormantFoldTs) { $dormantFold = $c; $dormantFoldTs = $ts }
                    }
                }
            }
            continue
        }
        if (-not (Test-RoomEntryOk $c.level.id)) {
            # 접두 풀(100명)에서는 기각 로그를 생략 (로그 홍수 방지)
            if (-not $Quiet) { $null = $script:ScanLog.Add(">>> 방 불일치 기각: $T -> $nick (lvl $($c.level.id))") }
            continue
        }
        # 내 닉 가드: 오인식된 내 닉이 내 계정을 상대로 착석시키는 사고 방지
        $nFold = Get-NickCanon $nick -StripDots
        if ($myNick -and ($nick -eq $myNick -or ($myFold.Length -ge 2 -and $nFold -ceq $myFold))) {
            $script:SawMyNick = $true
            continue
        }
        $nCand++
        if ($nick -ceq $T) { if ($null -eq $exact) { $exact = $c }; continue }
        if ($tFold.Length -ge 2 -and $nFold -ceq $tFold) { $null = $foldHits.Add($c); continue }
        if (-not $AllowSim) { continue }
        $nCanon = Get-NickCanon $nick
        # 길이 게이트: canon 기준, 짧은 쪽의 절반(최소 2)을 넘는 길이차는 기각
        $shortLen = [math]::Min($nCanon.Length, $tCanon.Length)
        if ([math]::Abs($nCanon.Length - $tCanon.Length) -gt [math]::Max(2, [int][math]::Floor($shortLen * 0.5))) { continue }
        $sim = Get-StrSimilarity $tCanon $nCanon
        if ($sim -gt $bestS) { $secondS = $bestS; $bestS = $sim; $best = $c }
        elseif ($sim -gt $secondS) { $secondS = $sim }
    }
    if ($exact) { return @{ Id = $exact.id; Nick = [string]$exact.nickname; Conf = 2; Sim = 1.0 } }
    if ($foldHits.Count -gt 0) {
        # fold 동일 다중 후보(장식만 다른 실계정 쌍)는 canon 유사도 → 최근 활동으로 재판별,
        # canon으로도 동률이면 사실상 동전던지기라 저신뢰(Conf 0)로 강등
        $ranked = @($foldHits | Sort-Object `
            @{ Expression = { -(Get-StrSimilarity $tCanon (Get-NickCanon ([string]$_.nickname))) } }, `
            @{ Expression = { -([long]($_.latest_timestamp -as [long])) } })
        $conf = 1
        if ($ranked.Count -ge 2) {
            $s1 = Get-StrSimilarity $tCanon (Get-NickCanon ([string]$ranked[0].nickname))
            $s2 = Get-StrSimilarity $tCanon (Get-NickCanon ([string]$ranked[1].nickname))
            if (($s1 - $s2) -lt 0.001) { $conf = 0 }
        }
        return @{ Id = $ranked[0].id; Nick = [string]$ranked[0].nickname; Conf = $conf; Sim = 1.0 }
    }
    if ($AllowSim -and $best) {
        $bCanon = Get-NickCanon ([string]$best.nickname)
        $shortLen = [math]::Min($tCanon.Length, $bCanon.Length)
        $ok = $false
        if ($shortLen -ge 4) {
            $ok = ($bestS -ge 0.60 -and ($bestS - $secondS) -ge 0.10)
        } elseif ($shortLen -ge 3 -and $tCanon.Length -ge 1 -and $bCanon.Length -ge 1) {
            # 3글자 닉은 임계 대신 편집 수로: 1편집 이내 + 첫 글자 일치 + 더 큰 격차.
            # 2글자 이하는 1편집이 이름의 절반이라 유사 채택 금지 (fold 동일만 허용 - 今ジ→今々 0.50 오채택 사고)
            $edits = [math]::Round((1.0 - $bestS) * [math]::Max($tCanon.Length, $bCanon.Length))
            $ok = ($edits -le 1 -and $tCanon[0] -eq $bCanon[0] -and ($bestS - $secondS) -ge 0.15)
        }
        # 후보가 하나뿐이면 격차 게이트가 무의미 - 유사도 자체를 더 높게 요구
        if ($ok -and $nCand -le 1 -and $bestS -lt 0.75) { $ok = $false }
        if ($ok) { return @{ Id = $best.id; Nick = [string]$best.nickname; Conf = 0; Sim = $bestS } }
    }
    # 활동 후보가 전혀 채택되지 못했을 때만 휴면 일치 폴백 (한 단계 강등 - 활동 매칭이 나오면 교체됨)
    if ($dormantExact) { return @{ Id = $dormantExact.id; Nick = [string]$dormantExact.nickname; Conf = 1; Sim = 1.0 } }
    if ($AllowSim -and $dormantFold) { return @{ Id = $dormantFold.id; Nick = [string]$dormantFold.nickname; Conf = 0; Sim = 1.0 } }
    return $null
}

# 접두사로 검색해 가장 비슷한 실존 닉을 찾음 (OCR이 뒷부분을 뭉갠 경우 구제)
# 앞 2글자 → 실패하면 첫 글자만 (2번째 글자까지 오인식된 경우 구제: 韶隼` → 韶 → 韶华丶)
# 성공 시 @{Id; Nick; Conf; Sim} 반환
function Find-ByPrefix {
    param([string]$Raw)
    if ($Raw.Length -gt 16) { return $false }
    $pres = New-Object Collections.ArrayList
    $c1 = $Raw.Substring(0, 1)
    $isCjk = ($c1 -match '^[぀-ヿ一-鿿]$')
    # CJK는 2글자부터(한자 닉은 짧음), 라틴은 3글자부터
    if (($isCjk -and $Raw.Length -lt 2) -or (-not $isCjk -and $Raw.Length -lt 3)) { return $false }
    if ($isCjk) {
        $has2 = ($Raw.Substring(0, 2) -match '^[぀-ヿ一-鿿]{2}$')
        if ($has2) { $null = $pres.Add($Raw.Substring(0, 2)) }
        # 접두 자체가 오인식됐을 수 있음: 첫/둘째 글자의 가나 혼동쌍 조합도 접두 후보로
        # (리터럴 접두 검색이라 えい로는 えぃ~ 닉을 못 가져옴)
        if ($has2) {
            $c2 = $Raw.Substring(1, 1)
            $a1 = @($c1); if ($script:KanaAlt.ContainsKey($c1)) { $a1 += @($script:KanaAlt[$c1]) }
            $a2 = @($c2); if ($script:KanaAlt.ContainsKey($c2)) { $a2 += @($script:KanaAlt[$c2]) }
            foreach ($x1 in $a1) {
                foreach ($x2 in $a2) {
                    $pp = [string]$x1 + [string]$x2
                    if ($pres -notcontains $pp -and $pres.Count -lt 7) { $null = $pres.Add($pp) }
                }
            }
        }
        $null = $pres.Add($c1)
        if ($script:KanaAlt.ContainsKey($c1)) {
            foreach ($x1 in @($script:KanaAlt[$c1])) {
                $s1 = [string]$x1
                if ($pres -notcontains $s1) { $null = $pres.Add($s1) }
            }
        }
    }
    # 선두 장식 채널 (최후 수단): 닉이 장식 문자로 시작하면 토큰의 어떤 접두로도 검색이 안 됨
    # (서버는 장식을 안 접음) - "장식+첫 글자" 리터럴 접두로 풀을 가져와 fold로 판정 (丶Aaron ← Aaron)
    foreach ($d in @([char]0x4E36, [char]0x3002, [char]0x30FB)) {
        $pp = [string]$d + $c1
        if ($pres -notcontains $pp) { $null = $pres.Add($pp) }
    }
    # fold 동일(Conf 1+)이 유사도 채택(Conf 0)보다 우선 - 앞 풀의 어중간한 유사가 뒤 풀의 확실한 매칭을 가리지 않게
    $fallback = $null
    foreach ($pre in $pres) {
        $pick = Find-ByPrefixOne $Raw $pre
        if ($pick) {
            if ([int]$pick.Conf -ge 1) { return $pick }
            if ($null -eq $fallback) { $fallback = $pick }
        }
    }
    if ($fallback) { return $fallback }
    return $false
}

function Find-ByPrefixOne {
    param([string]$Raw, [string]$Pre)
    $ck = "pre:$Pre"
    if (-not $script:NickCache.ContainsKey($ck)) {
        if ($script:ScanQueryLeft -le 0) { return $false }
        $script:ScanQueryLeft--
        try {
            Start-Sleep -Milliseconds 100
            $res = Invoke-RestMethod -Uri "$Api/search_player/$([uri]::EscapeDataString($Pre))?limit=100" -TimeoutSec 10
            # Invoke-RestMethod는 JSON 배열을 '한 덩어리'로 넘겨서 @()로 감싸면 중첩됨 - 한 겹 풀어줌
            $flat = New-Object Collections.ArrayList
            foreach ($x in @($res)) {
                if ($x -is [array]) { foreach ($y in $x) { $null = $flat.Add($y) } }
                elseif ($null -ne $x) { $null = $flat.Add($x) }
            }
            $script:NickCache[$ck] = @($flat.ToArray())
        } catch { return $false }
    }
    $pick = Select-NickCandidate $Raw @($script:NickCache[$ck]) $true -Quiet
    if ($pick) {
        $null = $script:ScanLog.Add((">>> 유사매칭(접두 {0}): $Raw -> $($pick.Nick) (conf $($pick.Conf), sim {1:N2})" -f $Pre, [double]$pick.Sim))
        return $pick
    }
    return $false
}

# 후보 닉네임으로서 그럴듯한지 (OCR 잡음 걸러내기)
function Test-NickPlausible {
    param([string]$T, [bool]$Lenient = $false)
    # 명패 위치 토큰은 위치 자체가 신뢰 근거 - 순수 숫자와 같은 글자 반복만 거름 ((+_+)~ 같은 기호 닉 허용)
    if ($Lenient) {
        if ($T -match '^[\d.,]+$') { return $false }
        if ($T -imatch '^([a-z0-9])\1+$') { return $false }
        return $true
    }
    if ($T -match '^[\d.,:%/()\-±▲▼xX×*·。、]+$') { return $false }
    if ($T -imatch '^([a-z0-9])\1+$') { return $false }
    # 한글 + 라틴/숫자 혼합은 대부분 OCR 잡음
    if ($T -match '[가-힣]' -and $T -match '[A-Za-z0-9]') { return $false }
    # 숫자·기호 비중이 과반이면 잡음 (단 물결표는 일본어 닉에 흔해서 가나·한자 토큰에선 세지 않음)
    $noise = '[\d.,:%/()\-_|~`]'
    if ($T -match '[぀-ヿ一-鿿]') { $noise = '[\d.,:%/()\-_|`]' }
    $bad = ([regex]::Matches($T, $noise)).Count
    if ($bad * 2 -gt $T.Length) { return $false }
    return $true
}

# 새 상대가 확정되는 즉시 부모에 알림 (1명씩 부분 표시) - 스캔 프로세스의 Scan-Opponents만 설정
function Notify-NewFound {
    param($FoundMap)
    if ($script:ScanOnProgress) { try { & $script:ScanOnProgress @($FoundMap.Values) } catch {} }
}

function Resolve-Tokens {
    param($Tokens, $FoundMap, [bool]$NoCenter = $false)
    $myNick = $script:Nickname
    $seen = @{}
    $b = Get-GameRect   # 토큰 좌표는 화면 절대 좌표 - 비율 판정은 게임 화면 영역 기준으로

    # 1) 후보 정리 - 중복 제거 (중앙 필터는 순위 화면 감지 후 적용)
    $cands = New-Object Collections.ArrayList
    $dedup = @{}
    $hasRank = $false
    foreach ($tk in $Tokens) {
        $raw = ($tk.Text -replace '\s', '')
        if ($raw -and $script:ScanLogTokens -ne $false) { $null = $script:ScanLog.Add($raw) }
        if (-not $raw -or $raw.Length -lt 2 -or $raw.Length -gt 20) { continue }
        $inBox = $false
        foreach ($r in $script:SkipRects) {
            if ($tk.X -ge $r.X1 -and $tk.X -le $r.X2 -and $tk.Y -ge $r.Y1 -and $tk.Y -le $r.Y2) { $inBox = $true; break }
        }
        if ($inBox) { continue }
        if ($raw -eq $myNick) { $script:SawMyNick = $true }
        # 'N위M국(…%)'는 내 리포트 패널의 순위 분포 줄 - 순위 화면 마커로 오탐하지 않음
        $rk = ($raw -match '^[1-4](위|位)(?!\d+(국|局))')
        if ($rk) {
            $hasRank = $true
            if (($raw -replace '^[1-4](위|位)', '') -eq $myNick) { $script:SawMyNick = $true }
        }
        if ($dedup.ContainsKey($raw)) { continue }
        $dedup[$raw] = $true
        $null = $cands.Add(@{ Raw = $raw; X = $tk.X; Y = $tk.Y; Src = [string]$tk.Src; Rk = $rk; Ix = $cands.Count })
    }

    # 순위 화면('N위' 마커)이 아니면 중앙(패산) 토큰 제외
    if (-not $NoCenter -and -not $hasRank) {
        $cands = @($cands | Where-Object {
            -not ($_.X -gt $b.X + $b.W * 0.30 -and $_.X -lt $b.X + $b.W * 0.70 -and
                  $_.Y -gt $b.Y + $b.H * 0.28 -and $_.Y -lt $b.Y + $b.H * 0.72)
        })
    }
    # 순위 화면이면: 화면 맨 위의 순위 묶음(열린 팝업/결과)만 취급 - 뒤에 비치는 다른 판 목록 배제
    if ($hasRank) {
        $minY = [double]::MaxValue
        foreach ($cd in $cands) { if ($cd.Rk -and [double]$cd.Y -lt $minY) { $minY = [double]$cd.Y } }
        $cands = @($cands | Where-Object { $_.Rk -and ([double]$_.Y - $minY) -lt ($b.H * 0.18) })
    }

    # 2) 우선순위: 순위 화면이면 'N위' 붙은 이름을 화면 위쪽(열린 팝업)부터,
    #    아니면 명패 토큰 → 긴 토큰 (조회 예산을 값어치 있는 곳에)
    #    Sort-Object는 동순위 순서를 보장하지 않으므로 마지막에 원래 OCR 순서(Ix)로 고정
    if ($hasRank) {
        $ordered = @($cands | Sort-Object @{ Expression = { if ($_.Rk) { 0 } else { 1 } } }, @{ Expression = { $_.Y } }, @{ Expression = { -($_.Raw.Length) } }, @{ Expression = { $_.Ix } })
    } else {
        $ordered = @($cands | Sort-Object @{ Expression = { if ($_.Src -eq 'p') { 0 } else { 1 } } }, @{ Expression = { -($_.Raw.Length) } }, @{ Expression = { $_.Ix } })
    }

    foreach ($phase in 0, 1) {
    foreach ($tk in $ordered) {
        $raw = [string]$tk.Raw
        try {

        # 이미 확정된 명패 근처의 토큰은 더 긴(완전한) 닉일 때만 진행 - 조회 예산 절약
        $preNear = $null
        foreach ($kv in @($FoundMap.GetEnumerator())) {
            if ([math]::Abs([double]$kv.Value.X - [double]$tk.X) -lt 240 -and [math]::Abs([double]$kv.Value.Y - [double]$tk.Y) -lt 60) {
                $preNear = $kv.Key
                break
            }
        }
        # (유사매칭으로 잡힌 자리는 정확 일치가 뒤집을 수 있어야 하므로 건너뛰지 않음)
        if ($null -ne $preNear -and -not $FoundMap[$preNear].Fz -and $raw.Length -le ([string]$FoundMap[$preNear].Nick).Length) { continue }
        # 정원이 찼는데 교체 후보(근처)도 아니면 종료 대상
        if ($FoundMap.Count -ge 4 -and $null -eq $preNear) { continue }

        # 가나가 포함된 토큰은 출처와 무관하게 정밀 보정 (이름일 가능성이 높음)
        $deep = (($tk.Src -eq 'p') -or ($raw -match '[ぁ-ゖァ-ヺ]'))
        $vlist = $null
        if ($phase -eq 0) {
            # 1단계: 원문과 구두점 제거본만 (완전한 닉의 정확 일치가 잡음 변형보다 먼저 예산을 쓰도록)
            $vlist = New-Object Collections.ArrayList
            $null = $vlist.Add($raw)
            $tr = $raw.Trim([char[]]@('.', ',', [char]0xB7, "'", '|', '~', '-', '_', '(', ')', '[', ']', '<', '>', '!', ':', ';', '"',
                                      [char]0x3001, [char]0x3002, [char]0xFF0C, [char]0xFF61, [char]0xFF64, [char]0x30FB))
            if ($tr -and $tr -ne $raw -and $vlist -notcontains $tr) { $null = $vlist.Add($tr) }
        } else {
            $vlist = Get-TokenVariants $raw $deep
        }
        foreach ($t in $vlist) {
            # 최소 길이: 한자/가나 2글자, 명패 라틴 3글자, 그 외 4글자
            $minLen = 4
            if ($t -match '[぀-ヿ一-鿿]') { $minLen = 2 }
            elseif ($tk.Src -eq 'p') { $minLen = 3 }
            if ($t.Length -lt $minLen -or $t.Length -gt 16) { continue }
            if ($t -eq $myNick) { $script:SawMyNick = $true; continue }
            if ($StopWords -contains $t) { continue }
            if (-not (Test-NickPlausible $t ($tk.Src -eq 'p'))) { continue }
            if ($seen.ContainsKey($t)) { continue }
            $seen[$t] = $true

            if (-not $script:NickCache.ContainsKey($t)) {
                # 조회 예산 초과 시 새 조회는 생략 (속도 제한 방지)
                if ($script:ScanQueryLeft -le 0) { continue }
                $script:ScanQueryLeft--
                try {
                    Start-Sleep -Milliseconds 100
                    $res = Invoke-RestMethod -Uri "$Api/search_player/$([uri]::EscapeDataString($t))?limit=10" -TimeoutSec 10
                    # 위치 신뢰가 있는 토큰(명패/순위 화면)만 유사(Conf 0) 채택 허용
                    $allowSim = (($tk.Src -eq 'p') -or [bool]$tk.Rk)
                    $pick = Select-NickCandidate $t @($res) $allowSim
                    # 변형은 검색어일 뿐 - 같은 후보들을 원본 토큰으로도 점수화해 더 높은 신뢰를 채택
                    # (テっっ」의 괄호 제거 변형 テっっ가 실닉 テっっj를 가져오고, 원본의 」→j 접기가 fold 일치)
                    if ($t -cne $raw) {
                        $pick2 = Select-NickCandidate $raw @($res) $allowSim -Quiet
                        if ($pick2 -and (-not $pick -or [int]$pick2.Conf -gt [int]$pick.Conf -or
                                ([int]$pick2.Conf -eq [int]$pick.Conf -and [double]$pick2.Sim -gt [double]$pick.Sim))) { $pick = $pick2 }
                    }
                    if ($pick) {
                        $script:NickCache[$t] = @{ Id = $pick.Id; Conf = [int]$pick.Conf; RealNick = [string]$pick.Nick }
                        if ([int]$pick.Conf -lt 2) {
                            $null = $script:ScanLog.Add((">>> 스코어 매칭: $t -> $($pick.Nick) (conf $($pick.Conf), sim {0:N2})" -f [double]$pick.Sim))
                        }
                    } else {
                        $script:NickCache[$t] = $false
                    }
                } catch {
                    $script:ScanLog.Add("!! 조회 실패: $t") | Out-Null
                }
            }
            $hit = $false
            if ($script:NickCache.ContainsKey($t)) { $hit = $script:NickCache[$t] }
            if ($hit) {
                $id = $hit.Id
                $conf = [int]$hit.Conf
                $key = "$id"
                if (-not $FoundMap.ContainsKey($key)) {
                    # 같은 명패 위치에 이미 다른 플레이어가 있으면: 높은 신뢰 등급이, 동급이면 더 긴(완전한) 닉이 승리
                    $nearKey = $null
                    foreach ($kv in @($FoundMap.GetEnumerator())) {
                        if ([math]::Abs([double]$kv.Value.X - [double]$tk.X) -lt 240 -and [math]::Abs([double]$kv.Value.Y - [double]$tk.Y) -lt 60) {
                            $nearKey = $kv.Key
                            break
                        }
                    }
                    $entry = @{ Id = $id; Nick = $t; X = $tk.X; Y = $tk.Y; Conf = $conf; Fz = ($conf -lt 1) }
                    if ($null -eq $nearKey) {
                        if ($FoundMap.Count -lt 4) {
                            $FoundMap[$key] = $entry
                            $null = $script:ScanLog.Add(">>> 매칭: $t (id $id, conf $conf)")
                            Notify-NewFound $FoundMap
                        }
                    } else {
                        $oldConf = 2
                        if ($FoundMap[$nearKey].ContainsKey('Conf')) { $oldConf = [int]$FoundMap[$nearKey].Conf }
                        elseif ([bool]$FoundMap[$nearKey].Fz) { $oldConf = 0 }
                        if ($conf -gt $oldConf -or ($conf -eq $oldConf -and $t.Length -gt ([string]$FoundMap[$nearKey].Nick).Length)) {
                            $FoundMap.Remove($nearKey)
                            $FoundMap[$key] = $entry
                            $null = $script:ScanLog.Add(">>> 근접 교체: $t (id $id, conf $conf)")
                            Notify-NewFound $FoundMap
                        } else {
                            $null = $script:ScanLog.Add(">>> 근접 중복 스킵: $t (id $id)")
                        }
                    }
                }
                break
            }
        }

        # 변형으로도 못 찾았고 명패에서 읽힌 토큰이면 접두사 유사매칭 시도 (2단계에서만)
        # CJK 시작(중간 장식 닉 '猫・ROBIN'도 구제) 또는 라틴 3글자 시작(선두 장식 채널: 丶Aaron ← Aaron)
        if ($phase -eq 1 -and $tk.Src -eq 'p' -and ($raw -match '^[぀-ヿ一-鿿]' -or $raw -cmatch '^[A-Za-z]{3}')) {
            $already = $false
            foreach ($kv in @($FoundMap.GetEnumerator())) {
                if ([math]::Abs([double]$kv.Value.X - [double]$tk.X) -lt 240 -and [math]::Abs([double]$kv.Value.Y - [double]$tk.Y) -lt 60) { $already = $true; break }
            }
            if (-not $already -and $FoundMap.Count -lt 4) {
                $fpick = Find-ByPrefix $raw
                if ($fpick) {
                    $fkey = "$($fpick.Id)"
                    if (-not $FoundMap.ContainsKey($fkey)) {
                        # 접두 풀에서 fold 동일(장식만 차이)이면 확정 취급, 유사도 채택이면 자리 표시(교체 가능)
                        $fconf = [int]$fpick.Conf
                        $FoundMap[$fkey] = @{ Id = $fpick.Id; Nick = $raw; X = $tk.X; Y = $tk.Y; Conf = $fconf; Fz = ($fconf -lt 1) }
                        Notify-NewFound $FoundMap
                    }
                }
            }
        }
        } catch {
            $null = $script:ScanLog.Add("!! 토큰 처리 오류: $raw - $($_.Exception.Message)")
        }
    }
    }
}

# 스캔 오케스트레이션: 전체 스캔 → 부족하면 정밀 스캔, 다 찾거나 시간이 다할 때까지 재촬영. 과정은 scan-log.txt에 기록
function Scan-Opponents {
    param([scriptblock]$OnProgress = $null)
    if (-not $script:OcrOk) { return @() }
    $script:ScanLog = New-Object Collections.ArrayList
    # 이전 스캔이 강제 종료되며 남긴 고아 엔진 프로세스 정리 (10분 이상 된 것만 - 병렬 스캔 보호)
    try {
        Get-Process PaddleOCR-json -ErrorAction SilentlyContinue |
            Where-Object { ((Get-Date) - $_.StartTime).TotalMinutes -gt 10 } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}
    # 이전 스캔들이 %TEMP%에 남긴 임시 OCR 이미지 정리 (PID 고유명이라 방치하면 무한 누적)
    try {
        Get-ChildItem (Join-Path $env:TEMP 'mjs-paddle-*.png') -ErrorAction SilentlyContinue |
            Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 30 } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {}
    $script:ScanQueryLeft = 60   # 스캔 1회당 최대 조회 수 (속도 제한 방지)
    $script:SkipRects = @()
    $script:SawMyNick = $false
    $script:ScanRoomMode = 0
    $script:ScanOnProgress = $OnProgress   # 매칭 확정 즉시 1명씩 알림 (Notify-NewFound)
    $script:OppDataMissing = $false        # 매칭됐지만 전적 조회 실패로 표시 못 한 상대 존재 여부
    # 시작 즉시 헤더 기록 - 첫 시도 완료 전에 죽어도 "로그 없음"이 아니라 시작 흔적이 남게
    $null = $script:ScanLog.Add("===== 스캔 시작 ($(Get-Date -Format 'HH:mm:ss'))")
    try { ($script:ScanLog -join "`r`n") | Out-File (Join-Path $script:DataDir 'scan-log.txt') -Encoding utf8 } catch {}
    $found = @{}
    $deadline = (Get-Date).AddSeconds(990)   # 부모의 안전망(999초)보다 조금 먼저 스스로 종료
    $stopFlag = Join-Path $script:DataDir 'scan-stop.flag'
    $try = 0
    while ($true) {
        # 목표 인원: 화면에 내 닉이 보이면(=내 대국) 3명, 아니면(관전 등) 4명
        $target = 4
        if ($script:SawMyNick) { $target = 3 }
        if ($found.Count -ge $target) { break }
        if ((Get-Date) -ge $deadline) { break }
        # 사용자 우아한 중지: 탐색만 끝내고 (호출부의) 안정단 채움은 계속 진행
        if (Test-Path $stopFlag) { $null = $script:ScanLog.Add('>>> 사용자 중지 - 여기까지 결과로 마무리'); break }
        if ($try -gt 0) { Start-Sleep -Milliseconds $(if ($try -lt 3) { 500 } else { 2000 }) }
        # 재시도마다 조회 예산 소량 리필 (재시도는 대부분 캐시 히트라 실제 추가 조회는 적음)
        if ($try -gt 0 -and $script:ScanQueryLeft -lt 30) { $script:ScanQueryLeft = 30 }
        # 로그 폭주 방지: 4회차부터는 토큰 원문 생략(매칭 결과 줄만 기록)
        $script:ScanLogTokens = ($try -lt 3)
        $null = $script:ScanLog.Add("===== 시도 $($try + 1) ($(Get-Date -Format 'HH:mm:ss'))")
        $try++
        $prevCount = $found.Count
        # 오버레이가 가린 영역 갱신: 내 박스 + 부분 표시로 이미 띄워진 상대 박스 (부모가 표시할 때마다 다시 씀, 5분 내 것만 신뢰)
        $script:SkipRects = @()
        try {
            $rf = Join-Path $script:DataDir 'scan-box.json'
            if ((Test-Path $rf) -and ((Get-Date) - (Get-Item $rf).LastWriteTime).TotalMinutes -lt 5) {
                $bx = Get-Content $rf -Raw | ConvertFrom-Json
                if ($null -ne $bx.Room) { $script:RoomGuess = [int]$bx.Room }
                foreach ($b in (@($bx) + @($bx.Opp))) {
                    if ($b -and [double]$b.W -gt 0 -and [double]$b.H -gt 0) {
                        $script:SkipRects += @{
                            X1 = [double]$b.X - 8; Y1 = [double]$b.Y - 8
                            X2 = [double]$b.X + [double]$b.W + 8
                            Y2 = [double]$b.Y + [double]$b.H + 8
                        }
                    }
                }
            }
        } catch {}
        $bmp = $null
        try { $bmp = Get-ScreenCapture } catch { continue }
        try {
            if ($script:PaddleOk) {
                # Paddle 엔진: 전체+명패를 한 번에 (빠르고 신뢰도 필터 내장)
                $pt = Get-PaddleTokens $bmp
                $null = $script:ScanLog.Add("--- Paddle 스캔 (토큰 $($pt.Count)개)")
                if (-not $script:ScanRoomMode) {
                    $script:ScanRoomMode = Get-RoomModeFromTokens $pt
                    if ($script:ScanRoomMode) { $null = $script:ScanLog.Add("--- 방 감지: $($ModeNames[$script:ScanRoomMode])") }
                }
                if ($pt.Count -eq 0) {
                    # 엔진이 연속으로 빈손이면 고장으로 보고 Windows OCR로 전환
                    $script:PaddleFails++
                    if ($script:PaddleFails -ge 2) {
                        $script:PaddleOk = $false
                        $null = $script:ScanLog.Add('!! Paddle 엔진 응답 없음 - Windows OCR로 폴백')
                    }
                } else { $script:PaddleFails = 0 }
                if ($pt.Count -gt 0) {
                    $isRank = (@($pt | Where-Object { ($_.Text -replace '\s', '') -match '^[1-4](위|位)' }).Count -gt 0)
                    Resolve-Tokens $pt $found $isRank
                    # Paddle이 정원을 못 채우면 Windows OCR 명패 정밀 패스로 보충
                    # (기호 전용 닉 등 CJK 모델 사각지대 - 예: (+_+)~ )
                    $target = 4
                    if ($script:SawMyNick) { $target = 3 }
                    if ($found.Count -lt $target -and $try -ge 2 -and -not $isRank) {
                        $null = $script:ScanLog.Add('--- 보충: Windows 명패 스캔')
                        try { Resolve-Tokens (Get-PlateTokens $bmp 0) $found } catch {}
                    }
                    if ($bmp) { $bmp.Dispose(); $bmp = $null }
                    continue
                }
                if ($script:PaddleOk) {
                    if ($bmp) { $bmp.Dispose(); $bmp = $null }
                    continue
                }
            }
            $fullT = Get-FullTokens $bmp
            if (-not $script:ScanRoomMode) {
                $script:ScanRoomMode = Get-RoomModeFromTokens $fullT
                if ($script:ScanRoomMode) { $null = $script:ScanLog.Add("--- 방 감지: $($ModeNames[$script:ScanRoomMode])") }
            }
            $isRankScreen = (@($fullT | Where-Object { ($_.Text -replace '\s', '') -match '^[1-4](위|位)(?!\d+(국|局))' }).Count -gt 0)
            if ($isRankScreen) {
                # 순위 화면(패보/결과 목록): 명패 밴드 무의미 - 순위 목록만 처리
                $null = $script:ScanLog.Add('--- 순위 화면 스캔')
                Resolve-Tokens $fullT $found $true
            } else {
                # 명패 정밀 스캔을 먼저: 명패 위치가 항상 정답이므로 잡음 조각이 자리를 선점하지 못하게 함
                $null = $script:ScanLog.Add('--- 정밀(명패) 스캔')
                Resolve-Tokens (Get-PlateTokens $bmp $try) $found
                $target = 4
                if ($script:SawMyNick) { $target = 3 }
                if ($found.Count -lt $target) {
                    # 2번째 시도부터는 중앙 제외 해제 (대국 소개/점수 결과 화면은 이름이 중앙에 나옴)
                    $noCenter = ($try -ge 1)
                    $null = $script:ScanLog.Add("--- 전체 스캔 (중앙 포함: $noCenter)")
                    Resolve-Tokens $fullT $found $noCenter
                }
            }
        } catch {
            $null = $script:ScanLog.Add("오류: $($_.Exception.Message)")
        }
        # 아직 못 찾은 자리가 있으면 OCR이 실제로 본 명패 이미지를 남긴다 (scan-plate-*.png, 매번 덮어씀)
        $tgt = 4
        if ($script:SawMyNick) { $tgt = 3 }
        if ($bmp -and $try -ge 2 -and $found.Count -lt $tgt) { Save-PlateCrops $bmp }
        if ($bmp) { $bmp.Dispose() }
        # 중간에 강제 종료돼도 과정을 볼 수 있게 시도마다 기록
        try { ($script:ScanLog -join "`r`n") | Out-File (Join-Path $script:DataDir 'scan-log.txt') -Encoding utf8 } catch {}
        # 새로 찾은 상대는 즉시 알림 - 사용자가 클릭으로 중지해도 여기까지는 표시됨
        # 매칭은 됐지만 전적 조회가 실패(429 등)한 상대가 남아 있으면 새 발견이 없어도 매 시도 재시도
        if ($OnProgress -and (($found.Count -gt $prevCount) -or ($script:OppDataMissing -and $found.Count -gt 0))) { try { & $OnProgress @($found.Values) } catch {} }
    }
    try { ($script:ScanLog -join "`r`n") | Out-File (Join-Path $script:DataDir 'scan-log.txt') -Encoding utf8 } catch {}
    return @($found.Values)
}

# ---------------- 테스트 모드 ----------------

# 내부 테스트: 게임 창을 어떻게 인식하고 있는지 확인 (창모드/보조 모니터 문제 진단용)
if ($args -contains '-TestRect') {
    # -TestRect X Y W H : 가상의 창 크기로 16:9 보정만 확인
    if ($args.Count -ge 5) {
        $c = ConvertTo-ContentRect @{ X = [int]$args[1]; Y = [int]$args[2]; W = [int]$args[3]; H = [int]$args[4] }
        '({0},{1}) {2}x{3}  ->  ({4},{5}) {6}x{7}  (비 {8:N3})' -f $args[1], $args[2], $args[3], $args[4], $c.X, $c.Y, $c.W, $c.H, ([double]$c.W / [double]$c.H)
        exit 0
    }
    $hw = Find-GameWindow
    $r = Get-GameRect -Fresh
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    [pscustomobject]@{
        게임창찾음 = ($hw -ne [IntPtr]::Zero)
        게임화면 = ('({0},{1}) {2}x{3}' -f $r.X, $r.Y, $r.W, $r.H)
        화면비 = ('{0:N3}' -f ([double]$r.W / [double]$r.H))
        주모니터 = ('({0},{1}) {2}x{3}' -f $b.X, $b.Y, $b.Width, $b.Height)
        DpiScale = $script:DpiScale
    } | Format-List
    # 실제로 그 영역을 캡처해 명패 크롭까지 저장 - 눈으로 확인 가능
    try {
        $bmp = Get-ScreenCapture
        Save-PlateCrops $bmp
        "캡처 {0}x{1} - scan-plate-left/top/right/bottom.png 저장됨" -f $bmp.Width, $bmp.Height
        $bmp.Dispose()
    } catch { "캡처 실패: $($_.Exception.Message)" }
    exit 0
}

# 내부 테스트: 토큰 시나리오(JSON)를 실제 매칭 파이프라인에 통과시켜 결과 출력
if ($args.Count -ge 2 -and $args[0] -eq '-TestResolve') {
    $sc = Get-Content ([string]$args[1]) -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Nickname = [string]$sc.MyNick
    $script:SawMyNick = $false
    $script:ScanQueryLeft = 45
    $script:SkipRects = @()
    $script:ScanOnProgress = $null
    $script:ScanLog = New-Object Collections.ArrayList
    $b = Get-GameRect   # 시나리오의 X/Y는 게임 화면 비율 - 절대 좌표로 변환
    $tokens = New-Object Collections.ArrayList
    foreach ($t in $sc.Tokens) {
        $null = $tokens.Add(@{ Text = [string]$t.T; X = ($b.X + [double]$t.X * $b.W); Y = ($b.Y + [double]$t.Y * $b.H); Src = [string]$t.S })
    }
    $found = @{}
    Resolve-Tokens $tokens $found ([bool]$sc.NoCenter)
    $target = 4
    if ($script:SawMyNick) { $target = 3 }
    [pscustomobject]@{
        SawMyNick = $script:SawMyNick
        Target = $target
        Found = @($found.Values | ForEach-Object { $_.Nick })
    } | ConvertTo-Json -Compress
    exit 0
}

if ($args -contains '-TestData') {
    try {
        $pos = Get-Content (Join-Path $script:DataDir 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
        if ($pos.Settings.MyBasis) { $script:Settings.MyBasis = [string]$pos.Settings.MyBasis }
    } catch {}
    Get-OverlayData | Format-List
    exit 0
}
if ($args -contains '-TestScan') {
    Write-Host "OCR 사용 가능: $script:OcrOk"
    $opps = Scan-Opponents
    foreach ($o in $opps) {
        Write-Host "== $($o.Nick) (id $($o.Id)) at ($([int]$o.X),$([int]$o.Y))"
        $d = Get-OpponentData $o.Id
        if ($d) { $d | Format-List }
    }
    Write-Host "(스캔 과정: $script:DataDir\scan-log.txt)"
    exit 0
}
if ($args -contains '-ScanOnce') {
    # 오버레이가 띄우는 백그라운드 스캔 프로세스: 결과를 scan-result.json으로 전달
    try {
        $pos = Get-Content (Join-Path $script:DataDir 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.OppBasis) { $script:Settings.OppBasis = [string]$pos.Settings.OppBasis }
        if ($pos.Settings.OppStatScope) { $script:Settings.OppStatScope = [string]$pos.Settings.OppStatScope }
        if ($pos.Settings.Stable -is [bool]) { $script:Settings.Stable = $pos.Settings.Stable }
        if ($pos.Settings.OppStableMode) { $script:Settings.OppStableMode = [string]$pos.Settings.OppStableMode }
        if ($pos.Settings.StableDual -is [bool]) { $script:Settings.StableDual = $pos.Settings.StableDual }
        if ($pos.Settings.StableRoomFirst -is [bool]) { $script:Settings.StableRoomFirst = $pos.Settings.StableRoomFirst }
        if ($pos.Settings.StableDualThrone -is [bool]) { $script:Settings.StableDualThrone = $pos.Settings.StableDualThrone }
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
        if ($null -ne $pos.Settings.OppMinN) { $script:Settings.OppMinN = [int]$pos.Settings.OppMinN }
    } catch {}
    $resPath = Join-Path $script:DataDir 'scan-result.json'
    $dataCache = @{}
    # 현재 dataCache 상태를 결과 파일로 기록 (부모가 쓰기 시각 변화를 감지해 즉시 반영)
    # Room/SawMy 동봉: 부모가 안정단 워커(-StableOnce)에 방 정보를 전달하는 데 사용
    $writeOpps = {
        param($Opps)
        $out = @()
        foreach ($o in $Opps) {
            $key = "$($o.Id)"
            if ($dataCache[$key]) {
                $out += [pscustomobject]@{
                    Id = $key; X = [double]$o.X; Y = [double]$o.Y; Data = $dataCache[$key]
                    Room = [int]$script:ScanRoomMode; SawMy = [bool]$script:SawMyNick
                }
            }
        }
        ConvertTo-Json -InputObject $out -Depth 6 | Out-File $resPath -Encoding utf8
    }
    # 부분 데이터(안정단 제외)만 빠르게 저장 - 안정단은 부모가 별도 워커로 병렬 계산 (탐색을 막지 않음)
    $saveOpps = {
        param($Opps)
        $miss = $false
        foreach ($o in $Opps) {
            $key = "$($o.Id)"
            if (-not $dataCache[$key]) { $dataCache[$key] = Get-OpponentData $o.Id -SkipStable }
            if (-not $dataCache[$key]) { $miss = $true }
        }
        $script:OppDataMissing = $miss   # 실패한 상대가 있으면 스캔 루프가 매 시도 재호출
        & $writeOpps $Opps
    }
    $opps = Scan-Opponents -OnProgress $saveOpps
    & $saveOpps $opps
    # 이번 스캔이 만든 임시 OCR 이미지는 스스로 정리
    try { Get-ChildItem (Join-Path $env:TEMP "mjs-paddle-$PID-*.png") -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
    exit 0
}
$stoIdx = [Array]::IndexOf($args, '-StableOnce')
if ($stoIdx -ge 0) {
    # 안정단 전용 백그라운드 워커: -StableOnce <room> <sawMy 0/1> <id1.id2...>
    # 스캔과 병렬로 돌며 한 명 끝날 때마다 stable-<id>.json으로 전달 (부모 StablePollTimer가 수거)
    try {
        $pos = Get-Content (Join-Path $script:DataDir 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.OppBasis) { $script:Settings.OppBasis = [string]$pos.Settings.OppBasis }
        if ($pos.Settings.OppStatScope) { $script:Settings.OppStatScope = [string]$pos.Settings.OppStatScope }
        if ($pos.Settings.Stable -is [bool]) { $script:Settings.Stable = $pos.Settings.Stable }
        if ($pos.Settings.OppStableMode) { $script:Settings.OppStableMode = [string]$pos.Settings.OppStableMode }
        if ($pos.Settings.StableDual -is [bool]) { $script:Settings.StableDual = $pos.Settings.StableDual }
        if ($pos.Settings.StableRoomFirst -is [bool]) { $script:Settings.StableRoomFirst = $pos.Settings.StableRoomFirst }
        if ($pos.Settings.StableDualThrone -is [bool]) { $script:Settings.StableDualThrone = $pos.Settings.StableDualThrone }
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
        if ($null -ne $pos.Settings.OppMinN) { $script:Settings.OppMinN = [int]$pos.Settings.OppMinN }
    } catch {}
    $script:ScanRoomMode = [int]$args[$stoIdx + 1]
    $script:SawMyNick = ([string]$args[$stoIdx + 2] -eq '1')
    # 방 미확정 시 폴백(내 주력 추정)은 스캔 자식과 같은 경로: scan-box.json의 Room
    try {
        $rf = Join-Path $script:DataDir 'scan-box.json'
        if (Test-Path $rf) {
            $bx = Get-Content $rf -Raw | ConvertFrom-Json
            if ($null -ne $bx.Room) { $script:RoomGuess = [int]$bx.Room }
        }
    } catch {}
    foreach ($oid in (([string]$args[$stoIdx + 3]) -split '\.')) {
        if (-not $oid) { continue }
        $d = $null
        try { $d = Get-OpponentData $oid } catch {}
        if ($d) { ConvertTo-Json -InputObject $d -Depth 6 | Out-File (Join-Path $script:DataDir "stable-$oid.json") -Encoding utf8 }
    }
    exit 0
}
$riIdx = [Array]::IndexOf($args, '-ReportOnce')
if ($riIdx -ge 0) {
    # 리포트 데이터 수집 백그라운드 프로세스: -ReportOnce <mode> <yyyy-MM-dd>
    try {
        $pos = Get-Content (Join-Path $script:DataDir 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
    } catch {}
    $rMode = [string]$args[$riIdx + 1]
    $rAnchor = [DateTime]::ParseExact([string]$args[$riIdx + 2], 'yyyy-MM-dd', $null)
    $rEnd2 = [DateTime]::MinValue
    if ($rMode -eq 'range' -and $args.Count -gt ($riIdx + 3)) {
        $rEnd2 = [DateTime]::ParseExact([string]$args[$riIdx + 3], 'yyyy-MM-dd', $null)
    }
    $pack = Build-ReportPack $rMode $rAnchor $rEnd2
    ConvertTo-Json -InputObject $pack -Depth 6 | Out-File (Join-Path $script:DataDir 'report-result.json') -Encoding utf8
    exit 0
}
$diIdx = [Array]::IndexOf($args, '-DetailOnce')
if ($diIdx -ge 0) {
    # 상세 지표 수집 백그라운드 프로세스: -DetailOnce <시작 yyyy-MM-dd> <끝(미포함) yyyy-MM-dd>
    try {
        $pos = Get-Content (Join-Path $script:DataDir 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
    } catch {}
    $dS = [DateTime]::ParseExact([string]$args[$diIdx + 1], 'yyyy-MM-dd', $null)
    $dE = [DateTime]::ParseExact([string]$args[$diIdx + 2], 'yyyy-MM-dd', $null)
    $sMs = [DateTimeOffset]::new($dS).ToUnixTimeMilliseconds()
    $eMs = [DateTimeOffset]::new($dE).ToUnixTimeMilliseconds()
    $ext = $null; $rst = $null
    try {
        $id = Get-PlayerId
        $rst = Get-RangeStats $id $sMs $eMs
        Start-Sleep -Milliseconds 120
        $ext = Invoke-RestMethod -Uri "$Api/player_extended_stats/$id/$sMs/$eMs`?mode=$($script:Modes)" -TimeoutSec 15
    } catch {}
    $dKey = ('{0}|{1}' -f $dS.ToString('yyyy-MM-dd'), $dE.ToString('yyyy-MM-dd'))
    ConvertTo-Json -InputObject @{ Anchor = $dKey; Ext = $ext; St = $rst } -Depth 6 | Out-File (Join-Path $script:DataDir 'detail-result.json') -Encoding utf8
    exit 0
}

# 내부 테스트: 상대 데이터 조립 경로 단독 실행 (-TestOpp <id> [room])
if ($args.Count -ge 2 -and $args[0] -eq '-TestOpp') {
    try {
        $pos = Get-Content (Join-Path $script:DataDir 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.OppBasis) { $script:Settings.OppBasis = [string]$pos.Settings.OppBasis }
        if ($pos.Settings.OppStatScope) { $script:Settings.OppStatScope = [string]$pos.Settings.OppStatScope }
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
        if ($null -ne $pos.Settings.OppMinN) { $script:Settings.OppMinN = [int]$pos.Settings.OppMinN }
    } catch {}
    $script:ScanRoomMode = 8
    if ($args.Count -ge 3) { $script:ScanRoomMode = [int]$args[2] }
    $script:SawMyNick = $true
    $d = Get-OpponentData ([long]$args[1]) -SkipStable
    if ($d) { $d | Format-List } else { '(null)' }
    exit 0
}

# ---------------- GUI ----------------

# 중복 실행 방지
$script:InstanceMutex = New-Object Threading.Mutex($false, 'MajsoulOverlayMutex')
if (-not $script:InstanceMutex.WaitOne(0)) { exit }

# 앱 아이콘은 스크립트에 내장 (base64) - 루트에 낱개 파일을 두지 않고 필요할 때 data\에 복원
$script:IconB64 = 'AAABAAEAQEAQAAAAAABoCgAAFgAAACgAAABAAAAAgAAAAAEABAAAAAAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACAAAAAgIAAgAAAAIAAgACAgAAAgICAAMDAwAAAAP8AAP8AAAD//wD/AAAA/wD/AP//AAD///8AAAAAAEZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmAAAAAAAARmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmQAAAAAZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmdmZmAAAAZmeP////////////////////////////////h2ZgAARmf///////////////////////////////////dmQABmf////////////////////////////////////3ZgAGZ/////////////////////////////////////hmAEZo/////////////////////////////////////2ZARm//////////////////////////////////////dmBmb/////////////////////////////////////9mYGZv/////////////////////////////////////2ZgZm//////////////////////////////////////ZmBmb/////////////////////////////////////9mYGZv/////////////////////////////////////2ZgZm//////////////////////////////////////ZmBmb/////////////////////////////////////9mYGZv/////////////////////////////////////2ZgZm//////////////////////////////////////ZmBmb/////////////////////////////////////9mYGZv////////////////+JmP/////////////////2ZgZm/////////////////4mY//////////////////ZmBmb/////////////////iZj/////////////////9mYGZv////////////////+JmP/////////////////2ZgZm/////////////////4mY//////////////////ZmBmb/////////////////iZj/////////////////9mYGZv////////////////+JmP/////////////////2ZgZm/////////////////4mY//////////////////ZmBmb/////////////////iZj/////////////////9mYGZv//////////mZmZmZmZmZmZmZmV///////////2ZgZm//////////+ZmZmZmZmZmZmZmZX///////////ZmBmb//////////5mZmZmZmZmZmZmZlf//////////9mYGZv//////////mZj///+JmP////mV///////////2ZgZm//////////+ZmP///4mY////+ZX///////////ZmBmb//////////5mY////iZj////5lf//////////9mYGZv//////////mZj///+JmP////mV///////////2ZgZm//////////+ZmP///4mY////+ZX///////////ZmBmb//////////5mY////iZj////5lf//////////9mYGZv//////////mZj///+JmP////mV///////////2ZgZm//////////+ZmZmZmZmZmZmZmZX///////////ZmBmb//////////5mZmZmZmZmZmZmZlf//////////9mYGZv//////////mZmZmZmZmZmZmZmV///////////2ZgZm/////////////////4mY//////////////////ZmBmb/////////////////iZj/////////////////9mYGZv////////////////+JmP/////////////////2ZgZm/////////////////4mY//////////////////ZmBmb/////////////////iZj/////////////////9mYGZv/////////////////////////////////////2ZgZm//////////////////////////////////////ZmBmb/////////////////////////////////////9mYGZv/////////////////////////////////////2ZgZm//////////////////////////////////////ZmBmb/////////////////////////////////////9mYGZv/////////////////////////////////////2ZgZm//////////////////////////////////////ZmBGaP////////////////////////////////////9mYAZo////////////////////////////////////+GZABmf////////////////////////////////////4ZgAGZo///////////////////////////////////4dmAABmeP/////////////////////////////////4dmQAAEZmeI//////////////////////////////iHdmYAAABGZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmQAAAAABmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmAAAAAAAAAEZmZmZmZmZmZmZmZmZmZmZmZmZmZmZmQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/gAAAAAAAf/wAAAAAAAAf8AAAAAAAAAfgAAAAAAAAA+AAAAAAAAADwAAAAAAAAAHAAAAAAAAAAcAAAAAAAAABwAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAACAAAAAAAAAAIAAAAAAAAAAgAAAAAAAAADAAAAAAAAAAMAAAAAAAAABwAAAAAAAAAHAAAAAAAAAAeAAAAAAAAAD8AAAAAAAAAP4AAAAAAAAD/wAAAAAAAAf/8AAAAAAAf///////////w=='

# 실행용 EXE 자동 빌드 - 아이콘 박힌 진입점 (없을 때만, 윈도우 내장 csc 사용이라 별도 설치 불필요)
try {
    $exePath = Join-Path $script:BaseDir '작혼 오버레이.exe'
    $icoPath = Join-Path $script:DataDir 'overlay.ico'
    if (-not (Test-Path $icoPath)) { [IO.File]::WriteAllBytes($icoPath, [Convert]::FromBase64String($script:IconB64)) }
    if (-not (Test-Path $exePath)) {
        $csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
        if ((Test-Path $csc) -and (Test-Path $icoPath)) {
            $lsrc = @'
class Launcher {
    static void Main() {
        var psi = new System.Diagnostics.ProcessStartInfo();
        psi.FileName = "powershell.exe";
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" +
            System.IO.Path.Combine(System.AppDomain.CurrentDomain.BaseDirectory, "app", "majsoul-overlay.ps1") + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        System.Diagnostics.Process.Start(psi);
    }
}
'@
            $tmpCs = Join-Path $env:TEMP 'mjs-launcher.cs'
            [IO.File]::WriteAllText($tmpCs, $lsrc)
            $null = & $csc /nologo /target:winexe "/win32icon:$icoPath" "/out:$exePath" $tmpCs 2>&1
            Remove-Item $tmpCs -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

# 갱신 중 UI 멈춤 방지: 비동기 HTTP + 메시지 펌프 활성화 (GUI 프로세스 전용)
try {
    Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
    $script:Http = New-Object System.Net.Http.HttpClient
    $script:Http.Timeout = [TimeSpan]::FromSeconds(30)
    $script:UiPump = $true
} catch { $script:UiPump = $false }

# 스팀 래퍼가 넘겨주는 게임 프로세스 이름 (-GameProc <이름>): 게임 종료 시 오버레이도 종료
$GameProcName = $null
$gpIdx = [Array]::IndexOf($args, '-GameProc')
if ($gpIdx -ge 0 -and ($gpIdx + 1) -lt $args.Count) { $GameProcName = [string]$args[$gpIdx + 1] }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$BoxXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight"
        Left="20" Top="20" ResizeMode="NoResize">
  <Border x:Name="RootBorder" CornerRadius="12" Background="#C7FFFFFF" Padding="16,10">
    <Grid>
      <StackPanel x:Name="Panel">
        <StackPanel x:Name="SetupPanel" Orientation="Horizontal" Visibility="Collapsed" Margin="0,0,0,6">
          <TextBlock x:Name="TbSetupL" Text="작혼 닉네임 입력: " FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center"/>
          <TextBox x:Name="TxSetupNick" FontFamily="Malgun Gothic" FontSize="12.5" Width="120" VerticalContentAlignment="Center"/>
          <TextBlock x:Name="BtnSetupApply" Text=" 확인" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="6,0,0,0" Cursor="Hand"/>
        </StackPanel>
        <TextBlock x:Name="TbName" FontFamily="Malgun Gothic" FontSize="17" FontWeight="ExtraBold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbRank" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbGoal" FontFamily="Malgun Gothic" FontSize="13" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.9" Visibility="Collapsed"/>
        <TextBlock x:Name="TbGame" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbStat" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E" TextWrapping="Wrap"/>
        <TextBlock x:Name="TbStat2" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbStat3" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbStat4" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbStat5" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <Canvas x:Name="SparkCanvas" Height="34" Margin="0,7,0,0" Visibility="Collapsed" ClipToBounds="True"/>
        <TextBlock x:Name="TbHelp" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E"
                   Opacity="0.85" Margin="0,6,0,0" Visibility="Collapsed"/>
        <StackPanel x:Name="SettingsPanel" Margin="0,6,0,0" Visibility="Collapsed">
          <CheckBox x:Name="CbToast" HorizontalAlignment="Left" Content="대국 반영 토스트" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" Margin="0,1,0,1"/>
          <CheckBox x:Name="CbMortal" HorizontalAlignment="Left" Content="기보 복사 감지 → 모탈 리뷰 열기" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" Margin="0,1,0,1"/>
          <StackPanel Orientation="Horizontal" Margin="0,1,0,1">
            <CheckBox x:Name="CbAnom" Content="특이 수치 강조" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center"/>
            <TextBlock x:Name="BtnAdv" Text="고급 설정 ▾" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85" Margin="10,0,0,0" VerticalAlignment="Center" Cursor="Hand"/>
          </StackPanel>
          <StackPanel x:Name="AnomRow" Orientation="Horizontal" Margin="16,2,0,1" Visibility="Collapsed">
            <TextBlock x:Name="TbAnomModeL" Text="방식 " FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="40"/>
            <ComboBox x:Name="CmbAnomMode" FontFamily="Malgun Gothic" FontSize="12" Width="82">
              <ComboBoxItem Content="깜박임"/>
              <ComboBoxItem Content="색만 변경"/>
            </ComboBox>
            <TextBlock x:Name="TbAnomHighL" Text=" 강함" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="6,0,3,0" ToolTip="강한 방향 특이일 때 색 (화료율 높음, 방총율 낮음 등)" ToolTipService.InitialShowDelay="0"/>
            <Border x:Name="SwHigh" Width="20" Height="16" CornerRadius="3" BorderThickness="1" BorderBrush="#88888888" Cursor="Hand"/>
            <TextBlock x:Name="TbAnomLowL" Text=" 약함" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="6,0,3,0" ToolTip="약한 방향 특이일 때 색 (화료율 낮음, 방총율 높음 등)" ToolTipService.InitialShowDelay="0"/>
            <Border x:Name="SwLow" Width="20" Height="16" CornerRadius="3" BorderThickness="1" BorderBrush="#88888888" Cursor="Hand"/>
          </StackPanel>
          <StackPanel x:Name="AdvPanel" Margin="16,2,0,4" Visibility="Collapsed"/>
          <StackPanel Orientation="Horizontal" Margin="0,1,0,1">
            <CheckBox x:Name="CbBadge" Content="스타일 배지" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center"/>
            <TextBlock x:Name="BtnBadgeAdv" Text="고급 설정 ▾" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85" Margin="10,0,0,0" VerticalAlignment="Center" Cursor="Hand"/>
          </StackPanel>
          <StackPanel x:Name="BadgePanel" Margin="16,2,0,4" Visibility="Collapsed"/>
          <TextBlock x:Name="BtnStableAdv" Text="고급 설정 ▾" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85" Margin="16,2,0,1" Cursor="Hand"/>
          <StackPanel x:Name="StablePanel" Margin="16,2,0,4" Visibility="Collapsed"/>
          <TextBlock x:Name="TbShowL" Text="── 표시 항목 ──" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.7" Margin="0,6,0,2"/>
          <StackPanel x:Name="DispPanel" Margin="0,0,0,2"/>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,1">
            <TextBlock x:Name="TbBasisMyL" Text="내 통계 기준 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <ComboBox x:Name="CmbBasisMy" FontFamily="Malgun Gothic" FontSize="12" Width="105">
              <ComboBoxItem Content="전체 기간"/>
              <ComboBoxItem Content="최근 1개월"/>
              <ComboBoxItem Content="최근 3개월"/>
              <ComboBoxItem Content="최근 6개월"/>
              <ComboBoxItem Content="최근 1년"/>
              <ComboBoxItem Content="⚠ 최근 50국" ToolTip="로딩이 오래 걸릴 수 있어요" ToolTipService.InitialShowDelay="0"/>
              <ComboBoxItem Content="⚠ 최근 100국" ToolTip="로딩이 오래 걸릴 수 있어요" ToolTipService.InitialShowDelay="0"/>
              <ComboBoxItem Content="⚠ 최근 200국" ToolTip="로딩이 오래 걸릴 수 있어요" ToolTipService.InitialShowDelay="0"/>
              <ComboBoxItem Content="기준 시점 이후" ToolTip="아래 '기준 시점' 설정(오늘 0시 / 실행 시점) 이후의 대국만 집계" ToolTipService.InitialShowDelay="0"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbBasisOppL" Text="상대 통계 기준 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <ComboBox x:Name="CmbBasisOpp" FontFamily="Malgun Gothic" FontSize="12" Width="105">
              <ComboBoxItem Content="전체 기간"/>
              <ComboBoxItem Content="최근 1개월"/>
              <ComboBoxItem Content="최근 3개월"/>
              <ComboBoxItem Content="최근 6개월"/>
              <ComboBoxItem Content="최근 1년"/>
              <ComboBoxItem Content="⚠ 최근 50국" ToolTip="로딩이 오래 걸릴 수 있어요" ToolTipService.InitialShowDelay="0"/>
              <ComboBoxItem Content="⚠ 최근 100국" ToolTip="로딩이 오래 걸릴 수 있어요" ToolTipService.InitialShowDelay="0"/>
              <ComboBoxItem Content="⚠ 최근 200국" ToolTip="로딩이 오래 걸릴 수 있어요" ToolTipService.InitialShowDelay="0"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbMinNL" Text="상대 최소 표본 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="기간 내 국수가 부족하면 더 긴 기간으로 자동 확장" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbMinN" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbMyScopeL" Text="내 지표 범위 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="내 박스의 화료율 등 지표를 어느 방 기록으로 계산할지" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbMyScope" FontFamily="Malgun Gothic" FontSize="12" Width="105">
              <ComboBoxItem Content="전체 방 합산"/>
              <ComboBoxItem Content="주력 방"/>
              <ComboBoxItem Content="안정단위 계산방"/>
              <ComboBoxItem Content="금탁"/>
              <ComboBoxItem Content="옥탁"/>
              <ComboBoxItem Content="왕좌탁"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbStatScopeL" Text="상대 지표 범위 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="화료율 등 지표를 어느 방 기록으로 계산할지. 해당 범위 기록이 없으면 전체 합산으로 폴백" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbStatScope" FontFamily="Malgun Gothic" FontSize="12" Width="105">
              <ComboBoxItem Content="전체 방 합산"/>
              <ComboBoxItem Content="현재 방"/>
              <ComboBoxItem Content="주력 방"/>
              <ComboBoxItem Content="안정단위 계산방"/>
              <ComboBoxItem Content="금탁"/>
              <ComboBoxItem Content="옥탁"/>
              <ComboBoxItem Content="왕좌탁"/>
            </ComboBox>
          </StackPanel>
          <TextBlock x:Name="TbBasisWarn" Text="⚠ '최근 N국' 기준은 로딩이 오래 걸릴 수 있어요" FontFamily="Malgun Gothic" FontSize="11" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.75" Margin="0,3,0,0"/>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,1">
            <TextBlock x:Name="TbBaseL" Text="기준 시점 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="오늘 전적/수지를 어디서부터 셀지" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbBase" FontFamily="Malgun Gothic" FontSize="12" Width="105">
              <ComboBoxItem Content="오늘 0시부터"/>
              <ComboBoxItem Content="실행 시점부터"/>
              <ComboBoxItem Content="직접 지정"/>
            </ComboBox>
          </StackPanel>
          <StackPanel x:Name="BasePanel" Margin="16,2,0,2" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal" Margin="0,1,0,1">
              <ComboBox x:Name="CmbBaseKind" FontFamily="Malgun Gothic" FontSize="12" Width="110">
                <ComboBoxItem Content="고정 날짜·시각"/>
                <ComboBoxItem Content="오늘 ± N일"/>
                <ComboBoxItem Content="지금 ± N시간"/>
              </ComboBox>
              <TextBox x:Name="TxBaseA" FontFamily="Malgun Gothic" FontSize="12" Width="72" Margin="4,0,0,0" VerticalContentAlignment="Center"/>
              <TextBox x:Name="TxBaseB" FontFamily="Malgun Gothic" FontSize="12" Width="30" Margin="3,0,0,0" VerticalContentAlignment="Center"/>
            </StackPanel>
            <TextBlock x:Name="TbBaseHint" Text="" FontFamily="Malgun Gothic" FontSize="10.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.7" Margin="1,1,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,1">
            <TextBlock x:Name="TbGoalL" Text="오늘 목표 pt " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <ComboBox x:Name="CmbGoal" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,5,0,1">
            <TextBlock x:Name="TbNickL" Text="내 닉네임 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="비운 채로 적용하면 닉네임 미설정 초기 상태로 되돌립니다" ToolTipService.InitialShowDelay="0"/>
            <TextBox x:Name="TxNick" FontFamily="Malgun Gothic" FontSize="12" Width="105" VerticalContentAlignment="Center"/>
            <TextBlock x:Name="BtnNickApply" Text=" 적용" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="6,0,0,0" Cursor="Hand"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,5,0,1">
            <TextBlock x:Name="TbKeyScanL" Text="스캔 키 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <ComboBox x:Name="CmbKeyScan" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbKeyCloseL" Text="상대 닫기 키 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <ComboBox x:Name="CmbKeyClose" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbKeyExitL" Text="종료 키 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <ComboBox x:Name="CmbKeyExit" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,6,0,1">
            <TextBlock x:Name="TbSizeTgtL" Text="크기·비율 대상 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="아래 크기·글자·비율 설정을 어느 박스에 적용할지" ToolTipService.InitialShowDelay="0"/>
            <TextBlock x:Name="TbSizeTgtMe" Text="내 박스" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Cursor="Hand" Margin="0,0,12,0"/>
            <TextBlock x:Name="TbSizeTgtOpp" Text="상대 박스" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Cursor="Hand" Opacity="0.45"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbScaleL" Text="박스 크기 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="박스 위에서 Ctrl+마우스휠로도 조절 (휠은 굴린 박스에 적용)" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbScale" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbFontScL" Text="글자 크기 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="오버레이 글자만 키우거나 줄임 (박스 크기와 독립)" ToolTipService.InitialShowDelay="0"/>
            <TextBox x:Name="TxFontSc" FontFamily="Malgun Gothic" FontSize="12" Width="32" MaxLength="3" VerticalContentAlignment="Center" HorizontalContentAlignment="Center"/>
            <TextBlock x:Name="TbFontScPct" Text="%" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="2,0,6,0"/>
            <Slider x:Name="SldFontSc" Width="106" Minimum="50" Maximum="200" SmallChange="1" IsMoveToPointEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="BtnFontScReset" Text=" 초기화" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.8" VerticalAlignment="Center" Cursor="Hand" Padding="6,0,0,0" TextDecorations="Underline"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbRatioXL" Text="박스 비율 가로 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="글자는 그대로 두고 박스만 - 가로는 내용 폭, 세로는 줄 간격" ToolTipService.InitialShowDelay="0"/>
            <TextBox x:Name="TxRatioX" FontFamily="Malgun Gothic" FontSize="12" Width="32" MaxLength="3" VerticalContentAlignment="Center" HorizontalContentAlignment="Center"/>
            <TextBlock x:Name="TbRatioXPct" Text="%" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="2,0,6,0"/>
            <Slider x:Name="SldRatioX" Width="106" Minimum="50" Maximum="200" SmallChange="1" IsMoveToPointEnabled="True" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbRatioYL" Text="박스 비율 세로 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <TextBox x:Name="TxRatioY" FontFamily="Malgun Gothic" FontSize="12" Width="32" MaxLength="3" VerticalContentAlignment="Center" HorizontalContentAlignment="Center"/>
            <TextBlock x:Name="TbRatioYPct" Text="%" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="2,0,6,0"/>
            <Slider x:Name="SldRatioY" Width="106" Minimum="50" Maximum="200" SmallChange="1" IsMoveToPointEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="BtnRatioReset" Text=" 초기화" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.8" VerticalAlignment="Center" Cursor="Hand" Padding="6,0,0,0" TextDecorations="Underline"/>
          </StackPanel>
          <TextBlock x:Name="TbThemeEditL" Text="── 색·투명도 (테마별 저장) ──" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.7" Margin="0,6,0,2"/>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbTxtColL" Text="기본 글자색 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <Border x:Name="SwTxtCol" Width="20" Height="16" CornerRadius="3" BorderThickness="1" BorderBrush="#88888888" Cursor="Hand"/>
            <TextBlock x:Name="BtnTxtColReset" Text=" 테마 기본" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.8" VerticalAlignment="Center" Cursor="Hand" Padding="8,0,0,0" TextDecorations="Underline"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbBgColL" Text="배경색 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <Border x:Name="SwBgCol" Width="20" Height="16" CornerRadius="3" BorderThickness="1" BorderBrush="#88888888" Cursor="Hand"/>
            <TextBlock x:Name="BtnBgColReset" Text=" 테마 기본" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.8" VerticalAlignment="Center" Cursor="Hand" Padding="8,0,0,0" TextDecorations="Underline"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbBgAlphaL" Text="배경 투명도 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <TextBox x:Name="TxBgAlpha" FontFamily="Malgun Gothic" FontSize="12" Width="32" MaxLength="3" VerticalContentAlignment="Center" HorizontalContentAlignment="Center"/>
            <TextBlock x:Name="TbBgAlphaPct" Text="%" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="2,0,6,0"/>
            <Slider x:Name="SldBgAlpha" Width="106" Minimum="0" Maximum="100" SmallChange="1" IsMoveToPointEnabled="True" VerticalAlignment="Center"/>
            <TextBlock x:Name="BtnBgAlphaReset" Text=" 테마 기본" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.8" VerticalAlignment="Center" Cursor="Hand" Padding="6,0,0,0" TextDecorations="Underline"/>
          </StackPanel>
          <TextBlock x:Name="TbPresetL" Text="── 프리셋 (테마·설정 전체 저장) ──" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.7" Margin="0,7,0,2"/>
          <StackPanel Orientation="Horizontal" Margin="0,1,0,1">
            <TextBox x:Name="TxPreset" FontFamily="Malgun Gothic" FontSize="12" Width="120" VerticalContentAlignment="Center" ToolTip="프리셋 이름"/>
            <TextBlock x:Name="BtnPresetSave" Text=" 저장" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Cursor="Hand" Padding="8,0,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,1,0,1">
            <ComboBox x:Name="CmbPreset" FontFamily="Malgun Gothic" FontSize="12" Width="120"/>
            <TextBlock x:Name="BtnPresetLoad" Text=" 불러오기" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Cursor="Hand" Padding="8,0,0,0"/>
            <TextBlock x:Name="BtnPresetDel" Text=" 삭제" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.75" VerticalAlignment="Center" Cursor="Hand" Padding="8,0,0,0"/>
          </StackPanel>
          <TextBlock x:Name="TbCrTitle" Text="작혼 전적 검색 오버레이" FontFamily="Malgun Gothic" FontSize="13" FontWeight="ExtraBold" Foreground="#FF16213E" Margin="0,2,0,1"/>
          <TextBlock x:Name="LnkRepo" Text="GitHub 저장소 ↗" Tag="https://github.com/HAN-GISU/majsoul-stats-search-overlay" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85"
                     TextDecorations="Underline" Cursor="Hand" Margin="0,0,0,2" ToolTip="브라우저로 열기" ToolTipService.InitialShowDelay="0"/>
          <TextBlock x:Name="TbSrcL" Text="── 전적 데이터 ──" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.7" Margin="0,7,0,2"/>
          <TextBlock x:Name="LnkSource" Text="amae-koromo (雀魂牌谱屋) ↗" Tag="https://amae-koromo.sapk.ch/" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85"
                     TextDecorations="Underline" Cursor="Hand" Margin="0,0,0,1" ToolTip="브라우저로 열기" ToolTipService.InitialShowDelay="0"/>
          <TextBlock x:Name="TbCrSrc2" Text="전적·통계 조회 (대국 반영까지 수 분 걸릴 수 있음)" FontFamily="Malgun Gothic" FontSize="11" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.65" Margin="0,0,0,1"/>
          <TextBlock x:Name="TbCrOcrL" Text="── 문자 인식 엔진 ──" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.7" Margin="0,7,0,2"/>
          <TextBlock x:Name="LnkOcr" Text="PaddleOCR-json ↗" Tag="https://github.com/hiroi-sora/PaddleOCR-json" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85"
                     TextDecorations="Underline" Cursor="Hand" Margin="0,0,0,1" ToolTip="브라우저로 열기" ToolTipService.InitialShowDelay="0"/>
          <TextBlock x:Name="TbCrOcr2" Text="hiroi-sora · Apache-2.0 (선택 설치, 엔진 포함판에 동봉)" FontFamily="Malgun Gothic" FontSize="11" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.65" Margin="0,0,0,1"/>
          <TextBlock x:Name="TbCrLicL" Text="── 라이선스 ──" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.7" Margin="0,7,0,2"/>
          <TextBlock x:Name="TbCrLic1" Text="MIT License © 2026 HAN-GISU" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85" Margin="0,0,0,1"/>
          <TextBlock x:Name="TbCrLic2" Text="안정단위 계산식: amae-koromo 구현 기반 (MIT)" FontFamily="Malgun Gothic" FontSize="11" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.65" Margin="0,0,0,0"/>
          <TextBlock x:Name="TbCrLic3" Text="서드파티 고지 전문 보기" FontFamily="Malgun Gothic" FontSize="11" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.75" Margin="0,1,0,1"
                     TextDecorations="Underline" Cursor="Hand" ToolTip="프로그램 폴더의 THIRD-PARTY-NOTICES.txt를 엽니다" ToolTipService.InitialShowDelay="0"/>
        </StackPanel>
      </StackPanel>
      <StackPanel x:Name="ScanPanel" Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Top"
                  Margin="-12,-8,0,0" Visibility="Collapsed">
        <TextBlock x:Name="BtnScan" Text="🔍" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E"
                   Padding="5,2" Cursor="Hand" ToolTip="상대 스캔" ToolTipService.InitialShowDelay="0"/>
        <TextBlock x:Name="BtnCloseOpp" Text="✕" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E"
                   Padding="5,2" Cursor="Hand" ToolTip="상대 박스 모두 닫기" ToolTipService.InitialShowDelay="0"/>
      </StackPanel>
      <StackPanel x:Name="CtrlPanel" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top"
                  Margin="0,-8,-12,0" Visibility="Collapsed">
        <TextBlock x:Name="BtnHelp" Text="?" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Padding="5,2" Cursor="Hand"/>
        <TextBlock x:Name="BtnRefresh" Text="⟳" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Padding="5,2" Cursor="Hand" ToolTip="즉시 새로고침" ToolTipService.InitialShowDelay="0"/>
        <TextBlock x:Name="BtnReport" Text="📋" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Padding="5,2" Cursor="Hand" ToolTip="오늘의 리포트 카드" ToolTipService.InitialShowDelay="0"/>
        <TextBlock x:Name="BtnSettings" Text="⚙" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Padding="5,2" Cursor="Hand"/>
        <TextBlock x:Name="BtnTheme" Text="◐" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Padding="5,2" Cursor="Hand"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$OppXaml = $BoxXaml -replace 'FontSize="17"', 'FontSize="14"' -replace 'FontSize="15"', 'FontSize="12.5"' -replace 'Padding="16,10"', 'Padding="12,7"'

function Get-HelpText {
    $ks = $script:Settings.KeyScan
    $kc = $script:Settings.KeyClose
    $ke = $script:Settings.KeyExit
    return "$ks : 화면 스캔 - 상대 전적 표시`r`n$kc : 상대 박스 모두 닫기`r`n$ke : 오버레이 종료`r`n드래그 : 위치 이동`r`n⟳ : 즉시 새로고침`r`n⚙ : 기능 켜기/끄기·키 설정`r`n◐ : 테마 전환 (밝은 / 다크 / 투명)`r`n? : 이 도움말 접기/펴기`r`n`r`n[안정단위] 지금 성적(순위 분포·평균점수)을 계속 유지하면`r`n최종적으로 정착하게 될 단위의 추정치 (옥남 기준, 牌谱屋 공식)`r`n· 작호2.31 = 작호2~3에 정착할 실력`r`n· 작호4 이상 = 작성급 → 작성1.20처럼 표시`r`n· 음수(작호-0.47) = 아직 작호 유지선 아래 (작걸대는 대부분 음수~1)"
}

function Update-HelpTexts {
    foreach ($b in Get-AllBoxes) {
        if ($b) {
            $b.BtnHelp.ToolTip = Get-HelpText
            $b.TbHelp.Text = Get-HelpText
        }
    }
}

# 기준 시점 설정(오늘 0시 / 실행 시점)에 따라 문구가 달라지는 라벨 갱신
function Update-BasisLabels {
    $lbl = Get-BasisLabel 'base'
    foreach ($b in Get-AllBoxes) {
        if ($b -and $b.TbGoalL) { $b.TbGoalL.Text = "$lbl 목표 pt " }
    }
    if ($script:MyBox -and $script:MyBox.DispPanel -and $script:MyBox.DispPanel.Visibility -eq 'Visible') {
        Build-DispPanel $script:MyBox
    }
}

function New-Brush {
    param([string]$Hex)
    New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

# 그림판 스타일 색상 팔레트 (클릭 시 색 선택)
$script:PaletteColors = @(
    '#FFE05252', '#FFFF7B7B', '#FFC62828', '#FFFF9800', '#FFE0B830', '#FFFFD666', '#FFC9A227', '#FFFFF176',
    '#FF7BE38B', '#FF4CAF50', '#FF2E7D32', '#FF80DEEA', '#FF4FC3F7', '#FF7FB3FF', '#FF3D74C9', '#FF1A237E',
    '#FFCE93D8', '#FFAB47BC', '#FF7B1FA2', '#FFF48FB1', '#FFEC407A', '#FFAD1457', '#FFBCAAA4', '#FF795548',
    '#FFFFFFFF', '#FFD9DCE1', '#FF9E9E9E', '#FF616161', '#FF16213E', '#FF000000'
)

function Show-ColorPicker {
    param($Anchor, [string]$Current, [scriptblock]$OnPick)
    $pop = New-Object Windows.Controls.Primitives.Popup
    $pop.PlacementTarget = $Anchor
    $pop.Placement = 'Bottom'
    $pop.StaysOpen = $true
    $pop.AllowsTransparency = $true

    $bd = New-Object Windows.Controls.Border
    $bd.Background = New-Brush '#FF262B38'
    $bd.CornerRadius = New-Object Windows.CornerRadius 8
    $bd.Padding = New-Object Windows.Thickness 8
    $bd.BorderThickness = New-Object Windows.Thickness 1
    $bd.BorderBrush = New-Brush '#FF4A5468'

    $sp = New-Object Windows.Controls.StackPanel
    $wp = New-Object Windows.Controls.WrapPanel
    $wp.Width = 208
    foreach ($hex in $script:PaletteColors) {
        $sq = New-Object Windows.Controls.Border
        $sq.Width = 22; $sq.Height = 22
        $sq.Margin = New-Object Windows.Thickness 2
        $sq.CornerRadius = New-Object Windows.CornerRadius 3
        $sq.Background = New-Brush $hex
        $sq.Cursor = [Windows.Input.Cursors]::Hand
        $sq.BorderThickness = New-Object Windows.Thickness 2
        if ($hex -eq $Current) { $sq.BorderBrush = New-Brush '#FFFFFFFF' } else { $sq.BorderBrush = New-Brush '#33FFFFFF' }
        $sq.Tag = $hex
        $sq.Add_MouseLeftButtonUp({
            & $script:PickCallback ([string]$args[0].Tag)
            $script:PickPopup.IsOpen = $false
        })
        $null = $wp.Children.Add($sq)
    }
    $null = $sp.Children.Add($wp)

    # 직접 입력
    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Object Windows.Thickness 2, 6, 2, 0
    $lb = New-Object Windows.Controls.TextBlock
    $lb.Text = 'HEX '
    $lb.Foreground = New-Brush '#FFD9DCE1'
    $lb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $lb.FontSize = 11.5
    $lb.VerticalAlignment = 'Center'
    $tx = New-Object Windows.Controls.TextBox
    $tx.Width = 100
    $tx.FontSize = 11.5
    $tx.Text = $Current
    $ok = New-Object Windows.Controls.TextBlock
    $ok.Text = '  적용'
    $ok.Foreground = New-Brush '#FFD9DCE1'
    $ok.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $ok.FontSize = 11.5
    $ok.FontWeight = [Windows.FontWeights]::Bold
    $ok.VerticalAlignment = 'Center'
    $ok.Cursor = [Windows.Input.Cursors]::Hand
    $ok.Tag = $tx
    $ok.Add_MouseLeftButtonUp({
        $t = ([string]$args[0].Tag.Text).Trim()
        if ($t -notmatch '^#') { $t = '#' + $t }
        if ($t -match '^#[0-9A-Fa-f]{6}$') { $t = '#FF' + $t.Substring(1) }
        if ($t -match '^#[0-9A-Fa-f]{8}$') {
            & $script:PickCallback $t
            $script:PickPopup.IsOpen = $false
        }
    })
    $null = $row.Children.Add($lb)
    $null = $row.Children.Add($tx)
    $null = $row.Children.Add($ok)
    $null = $sp.Children.Add($row)

    # 닫기 버튼 (StaysOpen=true라 명시적으로 닫음)
    $cl = New-Object Windows.Controls.TextBlock
    $cl.Text = '  닫기'
    $cl.Foreground = New-Brush '#FF8A93A6'
    $cl.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $cl.FontSize = 11.5
    $cl.VerticalAlignment = 'Center'
    $cl.Cursor = [Windows.Input.Cursors]::Hand
    $cl.Add_MouseLeftButtonUp({ $script:PickPopup.IsOpen = $false })
    $null = $row.Children.Add($cl)

    $bd.Child = $sp
    $pop.Child = $bd
    if ($script:PickPopup) { try { $script:PickPopup.IsOpen = $false } catch {} }
    $script:PickPopup = $pop
    $script:PickCallback = $OnPick
    $pop.IsOpen = $true
}

function New-StatWindow {
    param([string]$Xaml)
    $w = [Windows.Markup.XamlReader]::Parse($Xaml)
    $box = [pscustomobject]@{
        Win = $w
        RootBorder = $w.FindName('RootBorder')
        Panel = $w.FindName('Panel')
        SetupPanel = $w.FindName('SetupPanel')
        TbSetupL = $w.FindName('TbSetupL')
        TxSetupNick = $w.FindName('TxSetupNick')
        BtnSetupApply = $w.FindName('BtnSetupApply')
        BtnHelp = $w.FindName('BtnHelp')
        BtnTheme = $w.FindName('BtnTheme')
        TbName = $w.FindName('TbName')
        TbRank = $w.FindName('TbRank')
        TbGoal = $w.FindName('TbGoal')
        TbGame = $w.FindName('TbGame')
        TbStat = $w.FindName('TbStat')
        TbStat2 = $w.FindName('TbStat2')
        TbStat3 = $w.FindName('TbStat3')
        TbStat4 = $w.FindName('TbStat4')
        TbStat5 = $w.FindName('TbStat5')
        TbHelp = $w.FindName('TbHelp')
        SparkCanvas = $w.FindName('SparkCanvas')
        CtrlPanel = $w.FindName('CtrlPanel')
        ScanPanel = $w.FindName('ScanPanel')
        BtnScan = $w.FindName('BtnScan')
        BtnCloseOpp = $w.FindName('BtnCloseOpp')
        BtnRefresh = $w.FindName('BtnRefresh')
        BtnReport = $w.FindName('BtnReport')
        BtnSettings = $w.FindName('BtnSettings')
        SettingsPanel = $w.FindName('SettingsPanel')
        CbToast = $w.FindName('CbToast')
        CbMortal = $w.FindName('CbMortal')
        CbAnom = $w.FindName('CbAnom')
        TbAnomModeL = $w.FindName('TbAnomModeL')
        TbAnomHighL = $w.FindName('TbAnomHighL')
        TbAnomLowL = $w.FindName('TbAnomLowL')
        CmbAnomMode = $w.FindName('CmbAnomMode')
        SwHigh = $w.FindName('SwHigh')
        SwLow = $w.FindName('SwLow')
        AnomRow = $w.FindName('AnomRow')
        BtnAdv = $w.FindName('BtnAdv')
        AdvPanel = $w.FindName('AdvPanel')
        CbBadge = $w.FindName('CbBadge')
        BtnBadgeAdv = $w.FindName('BtnBadgeAdv')
        BadgePanel = $w.FindName('BadgePanel')
        BtnStableAdv = $w.FindName('BtnStableAdv')
        StablePanel = $w.FindName('StablePanel')
        TbBasisMyL = $w.FindName('TbBasisMyL')
        TbBasisOppL = $w.FindName('TbBasisOppL')
        TbBasisWarn = $w.FindName('TbBasisWarn')
        CmbBasisMy = $w.FindName('CmbBasisMy')
        CmbBasisOpp = $w.FindName('CmbBasisOpp')
        TbKeyScanL = $w.FindName('TbKeyScanL')
        TbKeyCloseL = $w.FindName('TbKeyCloseL')
        TbKeyExitL = $w.FindName('TbKeyExitL')
        CmbKeyScan = $w.FindName('CmbKeyScan')
        CmbKeyClose = $w.FindName('CmbKeyClose')
        CmbKeyExit = $w.FindName('CmbKeyExit')
        TbGoalL = $w.FindName('TbGoalL')
        CmbGoal = $w.FindName('CmbGoal')
        TbBaseL = $w.FindName('TbBaseL')
        CmbBase = $w.FindName('CmbBase')
        BasePanel = $w.FindName('BasePanel')
        CmbBaseKind = $w.FindName('CmbBaseKind')
        TxBaseA = $w.FindName('TxBaseA')
        TxBaseB = $w.FindName('TxBaseB')
        TbBaseHint = $w.FindName('TbBaseHint')
        TbMinNL = $w.FindName('TbMinNL')
        CmbMinN = $w.FindName('CmbMinN')
        TbMyScopeL = $w.FindName('TbMyScopeL')
        CmbMyScope = $w.FindName('CmbMyScope')
        TbStatScopeL = $w.FindName('TbStatScopeL')
        CmbStatScope = $w.FindName('CmbStatScope')
        TbScaleL = $w.FindName('TbScaleL')
        CmbScale = $w.FindName('CmbScale')
        TbShowL = $w.FindName('TbShowL')
        DispPanel = $w.FindName('DispPanel')
        TbNickL = $w.FindName('TbNickL')
        TxNick = $w.FindName('TxNick')
        BtnNickApply = $w.FindName('BtnNickApply')
        TbSrcL = $w.FindName('TbSrcL')
        TbCrTitle = $w.FindName('TbCrTitle')
        LnkRepo = $w.FindName('LnkRepo')
        TbCrSrc2 = $w.FindName('TbCrSrc2')
        TbCrOcrL = $w.FindName('TbCrOcrL')
        LnkOcr = $w.FindName('LnkOcr')
        TbCrOcr2 = $w.FindName('TbCrOcr2')
        TbCrLicL = $w.FindName('TbCrLicL')
        TbCrLic1 = $w.FindName('TbCrLic1')
        TbCrLic2 = $w.FindName('TbCrLic2')
        TbCrLic3 = $w.FindName('TbCrLic3')
        TbTxtColL = $w.FindName('TbTxtColL')
        TbBgColL = $w.FindName('TbBgColL')
        SwBgCol = $w.FindName('SwBgCol')
        BtnBgColReset = $w.FindName('BtnBgColReset')
        TbBgAlphaL = $w.FindName('TbBgAlphaL')
        TxBgAlpha = $w.FindName('TxBgAlpha')
        TbBgAlphaPct = $w.FindName('TbBgAlphaPct')
        TbSizeTgtL = $w.FindName('TbSizeTgtL')
        TbSizeTgtMe = $w.FindName('TbSizeTgtMe')
        TbSizeTgtOpp = $w.FindName('TbSizeTgtOpp')
        TbFontScL = $w.FindName('TbFontScL')
        TbFontScPct = $w.FindName('TbFontScPct')
        TxFontSc = $w.FindName('TxFontSc')
        SldFontSc = $w.FindName('SldFontSc')
        BtnFontScReset = $w.FindName('BtnFontScReset')
        TbRatioXL = $w.FindName('TbRatioXL')
        TbRatioYL = $w.FindName('TbRatioYL')
        TbRatioXPct = $w.FindName('TbRatioXPct')
        TbRatioYPct = $w.FindName('TbRatioYPct')
        TxRatioX = $w.FindName('TxRatioX')
        TxRatioY = $w.FindName('TxRatioY')
        SldRatioX = $w.FindName('SldRatioX')
        SldRatioY = $w.FindName('SldRatioY')
        BtnRatioReset = $w.FindName('BtnRatioReset')
        SldBgAlpha = $w.FindName('SldBgAlpha')
        BtnBgAlphaReset = $w.FindName('BtnBgAlphaReset')
        TbThemeEditL = $w.FindName('TbThemeEditL')
        SwTxtCol = $w.FindName('SwTxtCol')
        BtnTxtColReset = $w.FindName('BtnTxtColReset')
        TbPresetL = $w.FindName('TbPresetL')
        TxPreset = $w.FindName('TxPreset')
        BtnPresetSave = $w.FindName('BtnPresetSave')
        CmbPreset = $w.FindName('CmbPreset')
        BtnPresetLoad = $w.FindName('BtnPresetLoad')
        BtnPresetDel = $w.FindName('BtnPresetDel')
        LnkSource = $w.FindName('LnkSource')
    }
    foreach ($cmb in @($box.CmbKeyScan, $box.CmbKeyClose, $box.CmbKeyExit)) {
        foreach ($k in $script:KeyOptions) { $null = $cmb.Items.Add($k) }
    }
    foreach ($g in $script:GoalOptions) {
        if ($g -eq 0) { $null = $box.CmbGoal.Items.Add('끄기') }
        else { $null = $box.CmbGoal.Items.Add("+$g") }
    }
    foreach ($g in $script:MinNOptions) {
        if ($g -eq 0) { $null = $box.CmbMinN.Items.Add('끄기') }
        else { $null = $box.CmbMinN.Items.Add("${g}국") }
    }
    foreach ($s in $script:ScaleSteps) { $null = $box.CmbScale.Items.Add(('{0}%' -f [int]($s * 100))) }
    # Ctrl + 마우스휠로 크기 조절
    $w.Add_PreviewKeyDown({
        if (([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) -and
            ($args[1].Key -eq 'D0' -or $args[1].Key -eq 'NumPad0')) {
            $args[1].Handled = $true
            Set-UiScale 1.0
        }
    })
    $w.Add_PreviewMouseWheel({
        if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) {
            $args[1].Handled = $true
            $step = $(if ($args[1].Delta -gt 0) { 0.05 } else { -0.05 })
            # 휠을 굴린 박스의 대상(내/상대) 크기를 조절
            $isOppW = (-not [string]::IsNullOrEmpty([string]$args[0].Tag))
            Set-UiScale ([double](Get-SizeSetting 'UiScale' $isOppW) + $step) -Opp $isOppW
        }
    })
    $box.BtnHelp.ToolTip = (Get-HelpText)
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($box.BtnHelp, 0)
    [Windows.Controls.ToolTipService]::SetShowDuration($box.BtnHelp, 60000)
    $box.TbHelp.Text = (Get-HelpText)
    # ? 클릭: 박스 안에 도움말 표시/숨김
    $box.BtnHelp.Tag = $box
    $box.BtnHelp.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Show-HelpPin $args[0].Tag
    })
    # 마우스 오버 시에만 버튼들(🔍 ✕ / ? ⟳ 📋 ⚙ ◐) 표시
    $w.Add_MouseEnter({
        $box.CtrlPanel.Visibility = 'Visible'
        $box.ScanPanel.Visibility = 'Visible'
    }.GetNewClosure())
    $w.Add_MouseLeave({
        $box.CtrlPanel.Visibility = 'Collapsed'
        $box.ScanPanel.Visibility = 'Collapsed'
    }.GetNewClosure())
    # 🔍 클릭: 상대 스캔 (F8과 동일)
    $box.BtnScan.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Update-Opponents
    })
    # ✕ 클릭: 내 박스에서는 상대 박스 모두 닫기(F7), 상대 박스에서는 그 박스만 닫기 (오인식 정리용)
    $box.BtnCloseOpp.Tag = $box
    $box.BtnCloseOpp.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        $key = [string]$b.Win.Tag
        if ($key -and $script:OppWindows.ContainsKey($key)) {
            $script:OppClosed[$key] = $true   # 스캔 부분 갱신이 이 박스를 되살리지 않게
            try { $script:OppWindows[$key].Win.Close() } catch {}
            $script:OppWindows.Remove($key)
        } else {
            Close-Opponents
        }
    })
    # ⟳ 클릭: 즉시 새로고침 (진행 중엔 ⏳ 표시, 완료 시 토스트)
    $box.BtnRefresh.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        if ($script:NetBusy) { return }   # 이미 갱신 중이면 무시
        $s = $args[0]
        $s.Text = '⏳'
        try { $s.Dispatcher.Invoke([action] {}, [Windows.Threading.DispatcherPriority]::Render) } catch {}
        $script:GameToastFired = $false
        try { Refresh-All } catch {}
        $s.Text = '⟳'
        # 새 대국이 반영됐으면 대국 토스트가 이미 떴으므로 일반 갱신 토스트는 생략
        if (-not $script:GameToastFired) { Show-Toast '갱신되었습니다 ✓' $true }
    })
    # 📋 클릭: 오늘의 리포트 카드
    $box.BtnReport.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Show-ReportCard
    })
    # ⚙ 클릭: 설정 패널 열기/닫기 (클로저 대신 Tag로 박스 참조 - 스크립트 변수 접근 보장)
    $box.BtnSettings.Tag = $box
    $box.BtnSettings.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        if ($script:SettingsWin -and $script:SettingsWin.IsVisible) {
            $script:SettingsWin.Hide()
        } else {
            $script:SyncingUI = $true
            $b.CbToast.IsChecked = [bool]$script:Settings.Toast
            $b.CbMortal.IsChecked = [bool]$script:Settings.MortalWatch
            $b.CbAnom.IsChecked = [bool]$script:Settings.Anom
            $b.CmbAnomMode.SelectedIndex = $(if ([string]$script:Settings.AnomMode -eq 'static') { 1 } else { 0 })
            $b.SwHigh.Background = New-Brush ([string]$script:Settings.AnomHigh)
            $b.SwLow.Background = New-Brush ([string]$script:Settings.AnomLow)
            # 설정 창을 열 때 고급 설정 패널들은 항상 접힌 상태로 시작
            foreach ($ap in @(@($b.AdvPanel, $b.BtnAdv), @($b.BadgePanel, $b.BtnBadgeAdv), @($b.StablePanel, $b.BtnStableAdv))) {
                if ($ap[0]) { $ap[0].Visibility = 'Collapsed' }
                if ($ap[1]) { $ap[1].Text = '고급 설정 ▾' }
            }
            Build-DispPanel $b
            $b.TxNick.Text = [string]$script:Nickname
            $codes = @('all', 'm1', 'm3', 'm6', 'y1', 'g50', 'g100', 'g200', 'base')
            $iMy = [Array]::IndexOf($codes, [string]$script:Settings.MyBasis)
            $iOpp = [Array]::IndexOf($codes, [string]$script:Settings.OppBasis)
            $b.CmbBasisMy.SelectedIndex = [math]::Max(0, $iMy)
            $b.CmbBasisOpp.SelectedIndex = [math]::Max(0, $iOpp)
            $b.CmbKeyScan.SelectedIndex = [math]::Max(0, [Array]::IndexOf($script:KeyOptions, [string]$script:Settings.KeyScan))
            $b.CmbKeyClose.SelectedIndex = [math]::Max(0, [Array]::IndexOf($script:KeyOptions, [string]$script:Settings.KeyClose))
            $b.CmbKeyExit.SelectedIndex = [math]::Max(0, [Array]::IndexOf($script:KeyOptions, [string]$script:Settings.KeyExit))
            $b.CmbGoal.SelectedIndex = [math]::Max(0, [Array]::IndexOf($script:GoalOptions, [int]$script:Settings.DailyGoal))
            $b.CmbBase.SelectedIndex = [math]::Max(0, [Array]::IndexOf(@('today', 'session', 'custom'), [string]$script:Settings.SessionBase))
            Sync-BasePanel $b
            $b.CmbMinN.SelectedIndex = [math]::Max(0, [Array]::IndexOf($script:MinNOptions, [int]$script:Settings.OppMinN))
            $b.CmbStatScope.SelectedIndex = [math]::Max(0, [Array]::IndexOf(@('all', 'room', 'dom', 'stable', '9.8', '12.11', '16.15'), [string]$script:Settings.OppStatScope))
            $b.CmbMyScope.SelectedIndex = [math]::Max(0, [Array]::IndexOf(@('all', 'dom', 'stable', '9.8', '12.11', '16.15'), [string]$script:Settings.MyStatScope))
            Sync-RatioUi   # 크기 콤보·글자·비율 3종을 현재 편집 대상 값으로 (대상 링크 시각 포함)
            $b.CbBadge.IsChecked = [bool]$script:Settings.BadgeOn
            $script:SyncingUI = $false
            Sync-SettingSections
            Sync-TxtColSwatch
            Sync-PresetList $b
            if ($b.BadgePanel.Visibility -eq 'Visible') { Build-BadgePanel $b }
            if ($script:SettingsWin) {
                # 메인 박스 오른쪽에 붙여 표시 (화면 밖이면 왼쪽)
                $mw = $b.Win
                $script:SettingsWin.Left = $mw.Left + $mw.ActualWidth + 8
                $script:SettingsWin.Top = $mw.Top
                $script:SettingsWin.Show()
                $script:SettingsWin.UpdateLayout()
                $vw = [Windows.SystemParameters]::VirtualScreenWidth
                if ($script:SettingsWin.Left + $script:SettingsWin.ActualWidth -gt $vw) {
                    $script:SettingsWin.Left = [math]::Max(0, $mw.Left - $script:SettingsWin.ActualWidth - 8)
                }
                $vh = [Windows.SystemParameters]::VirtualScreenHeight
                if ($script:SettingsWin.Top + $script:SettingsWin.ActualHeight -gt $vh) {
                    $script:SettingsWin.Top = [math]::Max(0, $vh - $script:SettingsWin.ActualHeight - 8)
                }
            } else {
                $b.SettingsPanel.Visibility = 'Visible'
            }
        }
    })
    # 체크박스 토글 → 설정 저장 + 즉시 반영 (설정 키는 Tag에 저장)
    $box.CbToast.Tag = 'Toast'
    $box.CbMortal.Tag = 'MortalWatch'
    $box.CbAnom.Tag = 'Anom'
    $box.CbBadge.Tag = 'BadgeOn'
    $cbHandler = {
        $s = $args[0]
        $script:Settings[[string]$s.Tag] = [bool]$s.IsChecked
        Save-Pos
        Sync-SettingSections
        Refresh-Display
    }
    foreach ($cb in @($box.CbToast, $box.CbMortal, $box.CbAnom, $box.CbBadge)) {
        $cb.Add_Click($cbHandler)
    }
    # 첫 실행 닉네임 입력 (확인 버튼 또는 Enter)
    $box.BtnSetupApply.Tag = $box.TxSetupNick
    $box.BtnSetupApply.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Apply-Nickname ([string]$args[0].Tag.Text)
    })
    $box.TxSetupNick.Add_KeyDown({
        if ($args[1].Key -eq 'Return') { Apply-Nickname ([string]$args[0].Text) }
    })
    # 닉네임 변경 (적용 버튼 또는 Enter)
    $box.BtnNickApply.Tag = $box.TxNick
    $box.BtnNickApply.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Apply-Nickname ([string]$args[0].Tag.Text)
    })
    $box.TxNick.Add_KeyDown({
        if ($args[1].Key -eq 'Return') { Apply-Nickname ([string]$args[0].Text) }
    })
    # 크레딧 링크(제목 클릭) → Tag의 URL을 기본 브라우저로 열기
    $lnkHandler = {
        $args[1].Handled = $true
        try { Start-Process ([string]$args[0].Tag).Trim() } catch {}
    }
    foreach ($lk in @($box.LnkSource, $box.LnkRepo, $box.LnkOcr)) {
        if ($lk) { $lk.Add_MouseLeftButtonDown($lnkHandler) }
    }
    # 서드파티 고지 전문: 동봉 파일을 기본 편집기로 열기 (오프라인에서도 항상 열람 가능)
    if ($box.TbCrLic3) {
        $box.TbCrLic3.Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            try { Start-Process (Join-Path $script:AppDir 'THIRD-PARTY-NOTICES.txt') } catch {}
        })
    }
    # 통계 기준 변경 → 캐시 비우고 새 기준으로 다시 조회
    $box.CmbBasisMy.Tag = 'MyBasis'
    $box.CmbBasisOpp.Tag = 'OppBasis'
    $basisHandler = {
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $codes = @('all', 'm1', 'm3', 'm6', 'y1', 'g50', 'g100', 'g200', 'base')
        $script:Settings[[string]$s.Tag] = $codes[$s.SelectedIndex]
        Save-Pos
        $script:BasisCache = @{}
        if ($s.Tag -eq 'MyBasis') {
            $script:ExtCache = $null
            Request-OverlayUpdate
        } else {
            $script:OppCache = @{}   # 다음 F8 스캔부터 새 기준 적용
        }
    }
    $box.CmbBasisMy.Add_SelectionChanged($basisHandler)
    $box.CmbBasisOpp.Add_SelectionChanged($basisHandler)
    # 키 설정 변경
    $box.CmbKeyScan.Tag = 'KeyScan'
    $box.CmbKeyClose.Tag = 'KeyClose'
    $box.CmbKeyExit.Tag = 'KeyExit'
    $keyHandler = {
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings[[string]$s.Tag] = $script:KeyOptions[$s.SelectedIndex]
        Save-Pos
        Update-HelpTexts
    }
    $box.CmbKeyScan.Add_SelectionChanged($keyHandler)
    $box.CmbKeyClose.Add_SelectionChanged($keyHandler)
    $box.CmbKeyExit.Add_SelectionChanged($keyHandler)
    # 오늘 목표 변경
    $box.CmbGoal.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.DailyGoal = $script:GoalOptions[$s.SelectedIndex]
        Save-Pos
        Request-OverlayUpdate
    })
    # 강조 방식 (깜박임 / 색만 변경)
    $box.CmbAnomMode.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.AnomMode = @('pulse', 'static')[$s.SelectedIndex]
        Save-Pos
        Refresh-Display
    })
    # 강조 색상 선택
    $box.SwHigh.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Show-ColorPicker $args[0] ([string]$script:Settings.AnomHigh) {
            param($hex)
            $script:Settings.AnomHigh = $hex
            Save-Pos
            Sync-AnomSwatches
            Refresh-Display
        }
    })
    $box.SwLow.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Show-ColorPicker $args[0] ([string]$script:Settings.AnomLow) {
            param($hex)
            $script:Settings.AnomLow = $hex
            Save-Pos
            Sync-AnomSwatches
            Refresh-Display
        }
    })
    # 고급 설정 펼치기/접기
    $box.BtnAdv.Tag = $box
    $box.BtnAdv.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        if ($b.AdvPanel.Visibility -eq 'Visible') {
            $b.AdvPanel.Visibility = 'Collapsed'
            $args[0].Text = '고급 설정 ▾'
        } else {
            Build-AdvPanel $b
            $b.AdvPanel.Visibility = 'Visible'
            $args[0].Text = '고급 설정 ▴'
        }
    })
    # 기준 시점 변경 (오늘 0시 / 실행 시점 / 직접 지정)
    $box.CmbBase.Tag = $box
    $box.CmbBase.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.SessionBase = @('today', 'session', 'custom')[$s.SelectedIndex]
        if ([string]$script:Settings.SessionBase -eq 'session') { $script:SessionStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        # 기준이 바뀌면 오늘 집계 상태 초기화 후 재조회 (Get-OverlayData의 기준값 변화 감지가 처리)
        $script:ForceReset = $true
        Sync-BasePanel $s.Tag
        Update-BasisLabels
        Save-Pos
        Request-OverlayUpdate
    })
    # 기준 시점 직접 지정: 방식 콤보 + 값 입력 (Enter/포커스 아웃 시 반영)
    $box.CmbBaseKind.Tag = $box
    $box.CmbBaseKind.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.BaseCustomKind = @('abs', 'relday', 'relhr')[$s.SelectedIndex]
        $script:ForceReset = $true
        Sync-BasePanel $s.Tag
        Update-BasisLabels
        Save-Pos
        Request-OverlayUpdate
    })
    foreach ($tbx in @($box.TxBaseA, $box.TxBaseB)) {
        $tbx.Tag = $box
        $tbx.Add_LostFocus({ if (-not $script:SyncingUI) { Apply-BaseCustom $args[0].Tag } })
        $tbx.Add_KeyDown({
            if ($args[1].Key -eq 'Return') {
                Apply-BaseCustom $args[0].Tag
                $args[1].Handled = $true
            }
        })
    }
    # 기본 글자색 변경/초기화
    $box.SwTxtCol.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $cur = [string]$script:Settings["TextColor$(Get-ThemeKey)"]
        if (-not $cur) { $cur = '#FFD9DCE1' }
        Show-ColorPicker $args[0] $cur {
            param($hex)
            $script:Settings["TextColor$(Get-ThemeKey)"] = $hex
            Save-Pos
            foreach ($bb in Get-AllBoxes) { if ($bb) { Apply-Theme $bb } }
            Sync-TxtColSwatch
        }
    })
    $box.BtnTxtColReset.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $script:Settings["TextColor$(Get-ThemeKey)"] = ''
        Save-Pos
        foreach ($bb in Get-AllBoxes) { if ($bb) { Apply-Theme $bb } }
        Sync-TxtColSwatch
    })
    # 배경색 변경/초기화 + 투명도
    $box.SwBgCol.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $cur = [string]$script:Settings["BgColor$(Get-ThemeKey)"]
        if (-not $cur) { $cur = '#FF1C2233' }
        Show-ColorPicker $args[0] $cur {
            param($hex)
            $script:Settings["BgColor$(Get-ThemeKey)"] = $hex
            Save-Pos
            foreach ($bb in Get-AllBoxes) { if ($bb) { Apply-Theme $bb } }
            Sync-TxtColSwatch
        }
    })
    $box.BtnBgColReset.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $script:Settings["BgColor$(Get-ThemeKey)"] = ''
        Save-Pos
        foreach ($bb in Get-AllBoxes) { if ($bb) { Apply-Theme $bb } }
        Sync-TxtColSwatch
    })
    # 투명도 슬라이더: 드래그 중엔 즉시 반영만 하고, 저장은 드래그가 끝날 때 (파일 쓰기 스팸 방지)
    $box.SldBgAlpha.Add_ValueChanged({
        if ($script:SyncingUI) { return }
        Set-BgAlpha ([int][math]::Round($args[1].NewValue)) $false
    })
    $box.SldBgAlpha.Add_LostMouseCapture({ Save-Pos })
    $box.SldBgAlpha.Add_LostFocus({ Save-Pos })
    # 수치 입력칸: Enter 또는 포커스 이탈 시 적용 (값이 그대로면 '테마 기본' 상태 유지)
    $box.TxBgAlpha.Add_KeyDown({
        if ($args[1].Key -eq 'Return') {
            $v = 0
            if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v) -and $v -ne (Get-EffBgAlpha)) { Set-BgAlpha $v }
            else { Sync-TxtColSwatch }
        }
    })
    $box.TxBgAlpha.Add_LostFocus({
        $v = 0
        if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v) -and $v -ne (Get-EffBgAlpha)) { Set-BgAlpha $v }
        else { Sync-TxtColSwatch }
    })
    $box.BtnBgAlphaReset.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Set-BgAlpha (-1)
    })
    # 글자 크기 슬라이더 (투명도와 같은 방식, 현재 편집 대상에 적용)
    $box.SldFontSc.Add_ValueChanged({
        if ($script:SyncingUI) { return }
        Set-FontScale -V ([int][math]::Round($args[1].NewValue)) -Persist $false -Opp ($script:SizeTarget -eq 'opp')
    })
    $box.SldFontSc.Add_LostMouseCapture({ Save-Pos })
    $box.SldFontSc.Add_LostFocus({ Save-Pos })
    $box.TxFontSc.Add_KeyDown({
        if ($args[1].Key -eq 'Return') {
            $v = 0
            if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v)) { Set-FontScale -V $v -Opp ($script:SizeTarget -eq 'opp') } else { Sync-RatioUi }
        }
    })
    $box.TxFontSc.Add_LostFocus({
        $v = 0
        if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v)) { Set-FontScale -V $v -Opp ($script:SizeTarget -eq 'opp') } else { Sync-RatioUi }
    })
    $box.BtnFontScReset.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Set-FontScale -V 100 -Opp ($script:SizeTarget -eq 'opp')
    })
    # 박스 비율 슬라이더: 드래그 중엔 즉시 반영만, 저장은 드래그 끝에 (투명도와 같은 방식)
    $box.SldRatioX.Add_ValueChanged({
        if ($script:SyncingUI) { return }
        Set-BoxRatio -X ([int][math]::Round($args[1].NewValue)) -Persist $false -Opp ($script:SizeTarget -eq 'opp')
    })
    $box.SldRatioX.Add_LostMouseCapture({ Save-Pos })
    $box.SldRatioX.Add_LostFocus({ Save-Pos })
    $box.SldRatioY.Add_ValueChanged({
        if ($script:SyncingUI) { return }
        Set-BoxRatio -Y ([int][math]::Round($args[1].NewValue)) -Persist $false -Opp ($script:SizeTarget -eq 'opp')
    })
    $box.SldRatioY.Add_LostMouseCapture({ Save-Pos })
    $box.SldRatioY.Add_LostFocus({ Save-Pos })
    $box.TxRatioX.Add_KeyDown({
        if ($args[1].Key -eq 'Return') {
            $v = 0
            if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v)) { Set-BoxRatio -X $v -Opp ($script:SizeTarget -eq 'opp') } else { Sync-RatioUi }
        }
    })
    $box.TxRatioX.Add_LostFocus({
        $v = 0
        if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v)) { Set-BoxRatio -X $v -Opp ($script:SizeTarget -eq 'opp') } else { Sync-RatioUi }
    })
    $box.TxRatioY.Add_KeyDown({
        if ($args[1].Key -eq 'Return') {
            $v = 0
            if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v)) { Set-BoxRatio -Y $v -Opp ($script:SizeTarget -eq 'opp') } else { Sync-RatioUi }
        }
    })
    $box.TxRatioY.Add_LostFocus({
        $v = 0
        if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v)) { Set-BoxRatio -Y $v -Opp ($script:SizeTarget -eq 'opp') } else { Sync-RatioUi }
    })
    $box.BtnRatioReset.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Set-BoxRatio -X 100 -Y 100 -Opp ($script:SizeTarget -eq 'opp')
    })
    # 프리셋 저장/불러오기/삭제
    $box.BtnPresetSave.Tag = $box
    $box.BtnPresetSave.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        $nm = ([string]$b.TxPreset.Text).Trim()
        if (-not $nm) { Show-Toast '프리셋 이름을 입력하세요' $false; return }
        $snap = @{}
        foreach ($k in @($script:Settings.Keys)) { $snap[$k] = $script:Settings[$k] }
        $script:Presets[$nm] = @{ Theme = $script:Theme; Settings = $snap }
        Save-Pos
        Sync-PresetList $b
        Show-Toast "프리셋 '$nm' 저장됨 ✓" $true
    })
    $box.BtnPresetLoad.Tag = $box
    $box.BtnPresetLoad.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        if ($b.CmbPreset.SelectedIndex -lt 0) { return }
        $nm = [string]$b.CmbPreset.SelectedItem
        $pr = $script:Presets[$nm]
        if (-not $pr) { return }
        foreach ($k in @($pr.Settings.Keys)) { $script:Settings[$k] = $pr.Settings[$k] }
        if ($pr.Theme) { $script:Theme = [string]$pr.Theme }
        Convert-LegacyThemeColors   # 구버전 프리셋(단일 색 키) 호환
        $script:Nickname = [string]$script:Settings.Nickname
        Save-Pos
        foreach ($bb in Get-AllBoxes) { if ($bb) { Apply-Theme $bb } }
        Apply-ScaleAll
        Sync-SettingSections
        Sync-TxtColSwatch
        Refresh-Display
        Update-HelpTexts
        $script:OppCache = @{}
        $script:MyDomModeKey = $null
        Show-Toast "프리셋 '$nm' 적용됨 ✓" $true
        # 열린 설정 UI 값 재동기화를 위해 창을 닫음 (다시 열면 새 값)
        if ($script:SettingsWin) { $script:SettingsWin.Hide() }
        Request-OverlayUpdate
    })
    $box.BtnPresetDel.Tag = $box
    $box.BtnPresetDel.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        if ($b.CmbPreset.SelectedIndex -lt 0) { return }
        $nm = [string]$b.CmbPreset.SelectedItem
        $ans = [Windows.MessageBox]::Show($script:SettingsWin, "프리셋 '$nm'을(를) 삭제할까요?", '프리셋 삭제', 'YesNo', 'Question')
        if ($ans -ne 'Yes') { return }
        $script:Presets.Remove($nm)
        Save-Pos
        Sync-PresetList $b
        Show-Toast "프리셋 '$nm' 삭제됨" $false
    })
    # 박스 크기 변경 (현재 편집 대상에 적용)
    $box.CmbScale.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        Set-UiScale ([double]$script:ScaleSteps[$s.SelectedIndex]) -Opp ($script:SizeTarget -eq 'opp')
    })
    # 크기·비율 편집 대상 전환 (내 박스 / 상대 박스)
    foreach ($pair2 in @(@($box.TbSizeTgtMe, 'me'), @($box.TbSizeTgtOpp, 'opp'))) {
        $el2 = $pair2[0]
        if (-not $el2) { continue }
        $el2.Tag = [string]$pair2[1]
        $el2.Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $script:SizeTarget = [string]$args[0].Tag
            Sync-RatioUi
        })
    }
    # 배지 고급 설정 펼치기/접기
    $box.BtnBadgeAdv.Tag = $box
    $box.BtnBadgeAdv.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        if ($b.BadgePanel.Visibility -eq 'Visible') {
            $b.BadgePanel.Visibility = 'Collapsed'
            $args[0].Text = '고급 설정 ▾'
        } else {
            Build-BadgePanel $b
            $b.BadgePanel.Visibility = 'Visible'
            $args[0].Text = '고급 설정 ▴'
        }
    })
    # 안정단위 고급 설정 펼치기/접기
    $box.BtnStableAdv.Tag = $box
    $box.BtnStableAdv.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        if ($b.StablePanel.Visibility -eq 'Visible') {
            $b.StablePanel.Visibility = 'Collapsed'
            $args[0].Text = '고급 설정 ▾'
        } else {
            Build-StablePanel $b
            $b.StablePanel.Visibility = 'Visible'
            $args[0].Text = '고급 설정 ▴'
        }
    })
    # 상대 최소 표본 변경
    $box.CmbMinN.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.OppMinN = $script:MinNOptions[$s.SelectedIndex]
        Save-Pos
        $script:OppCache = @{}   # 다음 스캔부터 새 기준 적용
    })
    # 상대 지표 범위 변경 (전체 합산 / 현재 방 / 주력 방 / 안정단위 계산방)
    $box.CmbStatScope.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.OppStatScope = @('all', 'room', 'dom', 'stable', '9.8', '12.11', '16.15')[$s.SelectedIndex]
        Save-Pos
        $script:OppCache = @{}   # 다음 스캔부터 새 기준 적용
    })
    # 내 지표 범위 변경 (전체 합산 / 주력 방 / 안정단위 계산방)
    $box.CmbMyScope.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.MyStatScope = @('all', 'dom', 'stable', '9.8', '12.11', '16.15')[$s.SelectedIndex]
        Save-Pos
        $script:MyScopeExtKey = $null   # 범위 ext 캐시 무효화
        Request-OverlayUpdate
    })
    # 테마 버튼: 클릭 시 순환 (드래그로 번지지 않게 이벤트 소비)
    $box.BtnTheme.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Switch-Theme
    })
    # 드래그 이동
    $w.Add_MouseLeftButtonDown({ try { $w.DragMove() } catch {} }.GetNewClosure())
    return $box
}

function Apply-Theme {
    param($Box)
    switch ($script:Theme) {
        'dark'  { $bg = '#52000000'; $fg = '#FFD9DCE1'; $shadow = $false }
        'trans' { $bg = '#01000000'; $fg = '#FFFFFFFF'; $shadow = $true }
        default { $bg = '#C7FFFFFF'; $fg = '#FF16213E'; $shadow = $false }
    }
    # 사용자 지정 기본 글자색/배경색/투명도 - 테마별 저장 (미설정 부분은 테마 기본 유지)
    $tk = Get-ThemeKey
    if ([string]$script:Settings["TextColor$tk"]) { $fg = [string]$script:Settings["TextColor$tk"] }
    $bgc = [string]$script:Settings["BgColor$tk"]
    $bga = [int]$script:Settings["BgAlpha$tk"]
    if ($bgc -or $bga -ge 0) {
        try {
            $base = [Windows.Media.ColorConverter]::ConvertFromString($bg)
            $rgb = $base
            if ($bgc) { $rgb = [Windows.Media.ColorConverter]::ConvertFromString($bgc) }
            $a = $base.A
            if ($bga -ge 0) { $a = [byte][math]::Round(255.0 * $bga / 100.0) }
            $bg = ('#{0:X2}{1:X2}{2:X2}{3:X2}' -f $a, $rgb.R, $rgb.G, $rgb.B)
        } catch {}
    }
    $Box.RootBorder.Background = New-Brush $bg
    if ($Box.SetRoot) {
        $setBg = '#F5202433'
        if ($script:Theme -eq 'light') { $setBg = '#F8FFFFFF' }
        $Box.SetRoot.Background = New-Brush $setBg
        $Box.SetTitle.Foreground = New-Brush $fg
        $Box.SetClose.Foreground = New-Brush $fg
        if ($Box.SetExit) { $Box.SetExit.Foreground = New-Brush $fg }
        # 설정 탭 버튼: 활성=강조·밑줄, 비활성=흐리게
        if ($Box.SetTabs) {
            for ($sti = 0; $sti -lt $Box.SetTabs.Count; $sti++) {
                $stb = $Box.SetTabs[$sti]
                $stb.Foreground = New-Brush $fg
                if ($sti -eq [int]$script:SetTabIdx) {
                    $stb.FontWeight = [Windows.FontWeights]::ExtraBold
                    $stb.Opacity = 1.0
                    $stb.TextDecorations = [Windows.TextDecorations]::Underline
                } else {
                    $stb.FontWeight = [Windows.FontWeights]::Bold
                    $stb.Opacity = 0.55
                    $stb.TextDecorations = $null
                }
            }
        }
    }
    foreach ($tb in @($Box.TbName, $Box.TbRank, $Box.TbGoal, $Box.TbGame, $Box.TbStat, $Box.TbStat2, $Box.TbStat3, $Box.TbStat4, $Box.TbStat5, $Box.TbHelp,
                      $Box.BtnHelp, $Box.BtnSettings, $Box.BtnTheme, $Box.BtnReport, $Box.BtnScan, $Box.BtnCloseOpp,
                      $Box.CbToast, $Box.CbMortal, $Box.CbAnom,
                      $Box.TbBasisMyL, $Box.TbBasisOppL, $Box.TbBasisWarn, $Box.BtnRefresh,
                      $Box.TbKeyScanL, $Box.TbKeyCloseL, $Box.TbKeyExitL, $Box.TbGoalL, $Box.TbBaseL, $Box.TbBaseHint, $Box.TbMinNL, $Box.TbMyScopeL, $Box.TbStatScopeL, $Box.TbScaleL, $Box.TbShowL, $Box.TbNickL, $Box.BtnNickApply,
                      $Box.TbSetupL, $Box.BtnSetupApply, $Box.TbAnomModeL, $Box.TbAnomHighL, $Box.TbAnomLowL, $Box.BtnAdv, $Box.CbBadge, $Box.BtnBadgeAdv, $Box.BtnStableAdv,
                      $Box.TbShowL, $Box.TbSrcL, $Box.LnkSource,
                      $Box.TbCrTitle, $Box.LnkRepo, $Box.TbCrSrc2, $Box.TbCrOcrL, $Box.LnkOcr, $Box.TbCrOcr2, $Box.TbCrLicL, $Box.TbCrLic1, $Box.TbCrLic2, $Box.TbCrLic3,
                      $Box.TbThemeEditL, $Box.TbTxtColL, $Box.BtnTxtColReset, $Box.TbBgColL, $Box.BtnBgColReset, $Box.TbBgAlphaL, $Box.TbBgAlphaPct, $Box.BtnBgAlphaReset,
                      $Box.TbRatioXL, $Box.TbRatioYL, $Box.TbRatioXPct, $Box.TbRatioYPct, $Box.BtnRatioReset,
                      $Box.TbFontScL, $Box.TbFontScPct, $Box.BtnFontScReset, $Box.TbSizeTgtL, $Box.TbSizeTgtMe, $Box.TbSizeTgtOpp,
                      $Box.TbPresetL, $Box.BtnPresetSave, $Box.BtnPresetLoad, $Box.BtnPresetDel)) {
        if ($tb) { $tb.Foreground = New-Brush $fg }
    }
    if ($shadow) {
        $fx = New-Object Windows.Media.Effects.DropShadowEffect
        $fx.Color = [Windows.Media.Colors]::Black
        $fx.ShadowDepth = 0
        $fx.BlurRadius = 4
        $fx.Opacity = 0.95
        $Box.Panel.Effect = $fx
    } else {
        $Box.Panel.Effect = $null
    }
}

function Get-AllBoxes {
    $all = @($script:MyBox)
    foreach ($k in @($script:OppWindows.Keys)) { $all += $script:OppWindows[$k] }
    return $all
}

function Switch-Theme {
    $order = @('light', 'dark', 'trans')
    $i = [Array]::IndexOf($order, $script:Theme)
    $script:Theme = $order[($i + 1) % $order.Count]
    foreach ($b in Get-AllBoxes) { if ($b) { Apply-Theme $b } }
    Sync-TxtColSwatch   # 색·투명도 편집 줄을 새 테마의 값으로 (테마별 저장)
    Save-Pos
}

function Save-Pos {
    $script:Settings.Nickname = $script:Nickname   # 닉네임은 항상 설정 파일에 보존 (백그라운드 프로세스가 읽음)
    @{ Left = $script:MyBox.Win.Left; Top = $script:MyBox.Win.Top; PosVer = $script:PosVer
       Theme = $script:Theme; Settings = $script:Settings; Presets = $script:Presets } |
        ConvertTo-Json -Depth 6 | Out-File $script:PosFile -Encoding utf8
}

# 닉네임 변경: 상태 전부 리셋 후 새 닉으로 재조회
function Apply-Nickname {
    param([string]$NewNick)
    $NewNick = ([string]$NewNick).Trim()
    if ($NewNick -eq $script:Nickname) { return }
    if (-not $NewNick) {
        # 빈 닉 적용 = 닉네임 미설정 초기 상태로 되돌림 (첫 실행 온보딩과 동일)
        $script:Nickname = ''
        $script:PlayerId = 0
        $script:CachedId = 0
        $script:ExtCache = $null
        $script:BasisCache = @{}
        $script:TodayDate = $null
        $script:ForceReset = $true
        $script:LastShownPt = $null
        $script:LastData = $null
        $script:Settings.Nickname = ''
        Save-Pos
        if ($script:MyBox) {
            $script:MyBox.TxSetupNick.Text = ''
            $script:MyBox.SetupPanel.Visibility = 'Visible'
        }
        Show-Toast '닉네임 초기화 - 박스의 입력칸에 닉네임을 넣어 주세요' $true
        Update-Overlay
        return
    }
    $script:Nickname = $NewNick
    $script:PlayerId = 0
    $script:CachedId = 0
    $script:ExtCache = $null
    $script:BasisCache = @{}
    $script:TodayDate = $null
    $script:ForceReset = $true   # 다음 갱신 때 오늘 상태 전체 리셋 (기준 시점 설정과 무관하게)
    $script:LastShownPt = $null
    $script:LastData = $null
    $script:Settings.Nickname = $NewNick
    Save-Pos
    if ($script:MyBox) {
        $script:MyBox.SetupPanel.Visibility = 'Collapsed'
        # 재조회는 수 초~수십 초 걸림(오늘 순위 복원 포함) - 그동안 상태를 보여줘야 멈춘 것처럼 안 보임
        $script:MyBox.TbName.Text = $NewNick
        $script:MyBox.TbRank.Text = '⏳ 전적 불러오는 중...'
    }
    Show-Toast "닉네임 설정: $NewNick" $true
    Update-Overlay
}

# 설정 변경 직후 지연 갱신: '적용 중' 표시부터 그리고, 재조회는 UI 이벤트가 끝난 다음 틱에
# (콤보 SelectionChanged 안에서 바로 조회하면 드롭다운이 닫히지도 못하고 오버레이가 멈춘 것처럼 보임)
function Request-OverlayUpdate {
    if ($script:MyBox) {
        try { $script:MyBox.TbRank.Text = '⏳ 적용 중...' } catch {}
    }
    $null = [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::Background,
        [action] { Update-Overlay })
}

# ⟳ 즉시 새로고침: 내 전적 + 떠 있는 상대 박스 전부 재조회
function Refresh-All {
    if ($script:NetBusy) { return }
    $script:ExtCache = $null
    Update-Overlay
    $script:NetBusy = $true
    try {
        foreach ($k in @($script:OppWindows.Keys)) {
            $script:OppCache.Remove([string]$k)
            $d = Get-OpponentData $k
            if ($d) { Set-StatWindow $script:OppWindows[$k] $d }
        }
    } finally { $script:NetBusy = $false }
}

# 박스/리포트 크기 배율 적용 (0.6~2.0)
$script:ScaleSteps = @(0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0)
$script:AnomPctOptions = @(5, 10, 15, 20, 25, 30, 40, 50)

# 상대 박스 여부: 상대 박스만 Win.Tag에 계정 key가 실림 (생성 직후 태그 → Apply-Scale 순서 보장됨)
function Test-OppBox {
    param($Box)
    return (-not [string]::IsNullOrEmpty([string]$Box.Win.Tag))
}

# 대상별 크기·비율 설정값 조회 - 상대 키가 미설정(-1)이면 내 박스 값을 따름
function Get-SizeSetting {
    param([string]$Key, [bool]$IsOpp)
    if ($IsOpp) {
        $v = [double]$script:Settings["$($Key)Opp"]
        if ($v -ge 0) { return $v }
    }
    return [double]$script:Settings[$Key]
}

# 글자 크기 배율 - 오버레이 텍스트의 FontSize만 조절 (박스 크기 transform과 독립)
function Apply-FontScale {
    param($Box)
    if (-not $Box -or -not $Box.TbName) { return }
    $f = [math]::Max(50, [math]::Min(200, [int](Get-SizeSetting 'FontScale' (Test-OppBox $Box)))) / 100.0
    if (-not $Box.PSObject.Properties['FontBase']) { Add-Member -InputObject $Box -NotePropertyName FontBase -NotePropertyValue @{} }
    foreach ($nm in @('TbName', 'TbRank', 'TbGoal', 'TbGame', 'TbStat', 'TbStat2', 'TbStat3', 'TbStat4', 'TbStat5', 'TbHelp')) {
        $el = $Box.$nm
        if (-not $el) { continue }
        if (-not $Box.FontBase.ContainsKey($nm)) { $Box.FontBase[$nm] = [double]$el.FontSize }
        try { $el.FontSize = [math]::Max(6.0, [double]$Box.FontBase[$nm] * $f) } catch {}
    }
}

# 박스 비율 - 글자 왜곡 없이 적용: 가로 = 콘텐츠 폭(통계 개행 폭·최소 폭), 세로 = 줄 간격
function Apply-BoxRatio {
    param($Box)
    if (-not $Box -or -not $Box.TbStat) { return }
    $oppB = (Test-OppBox $Box)
    $rx = [math]::Max(50, [math]::Min(200, [int](Get-SizeSetting 'BoxRatioX' $oppB))) / 100.0
    $ry = [math]::Max(50, [math]::Min(200, [int](Get-SizeSetting 'BoxRatioY' $oppB))) / 100.0
    try {
        # 기준 폭 = 위쪽 줄들(닉/랭크/전적)의 자연 폭 중 최대
        $wMax = 340.0
        foreach ($el in @($Box.TbName, $Box.TbRank, $Box.TbGoal, $Box.TbGame)) {
            if (-not $el -or $el.Visibility -ne 'Visible') { continue }
            $el.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
            if ([double]$el.DesiredSize.Width -gt $wMax) { $wMax = [double]$el.DesiredSize.Width }
        }
        # 기본(100%)에 여유 5%를 굽는다 - 사용자가 105%를 '딱 적당'으로 고른 모습이 초기값
        $target = $wMax * 1.05 * $rx
        # 목표 폭이 자연 폭보다 크면 박스 최소 폭도 같이 늘려 통계가 짧아도 그 폭 유지
        if ($Box.Panel) { $Box.Panel.MinWidth = $(if ($target -gt $wMax) { $target } else { 0 }) }
        $Box.TbStat.MaxWidth = [math]::Max(160.0, $target)
        # 세로 = 줄 간격 (글자 높이보다 작아지지 않게 하한)
        foreach ($el in @($Box.TbName, $Box.TbRank, $Box.TbGoal, $Box.TbGame, $Box.TbStat)) {
            if (-not $el) { continue }
            if ([math]::Abs($ry - 1.0) -lt 0.005) {
                $el.ClearValue([Windows.Controls.TextBlock]::LineHeightProperty)
                $el.ClearValue([Windows.Controls.TextBlock]::LineStackingStrategyProperty)
            } else {
                $el.LineHeight = [math]::Max([double]$el.FontSize + 4.0, [double]$el.FontSize * 1.35 * $ry)
                $el.LineStackingStrategy = 'BlockLineHeight'
            }
        }
    } catch {}
}

function Apply-Scale {
    param($Box)
    if (-not $Box -or -not $Box.RootBorder) { return }
    $s = [double](Get-SizeSetting 'UiScale' (Test-OppBox $Box))
    if ($s -le 0) { $s = 1.0 }
    try {
        if ([math]::Abs($s - 1.0) -lt 0.001) { $Box.RootBorder.LayoutTransform = $null }
        else { $Box.RootBorder.LayoutTransform = New-Object Windows.Media.ScaleTransform $s, $s }
    } catch {}
    Apply-FontScale $Box
    Apply-BoxRatio $Box
    # 설정 별도 창은 항상 내 박스 배율을 따름 (편집 UI 왜곡 방지)
    if ($Box.SetRoot) {
        try {
            $sm = [double]$script:Settings.UiScale
            if ($sm -le 0) { $sm = 1.0 }
            if ([math]::Abs($sm - 1.0) -lt 0.001) { $Box.SetRoot.LayoutTransform = $null }
            else { $Box.SetRoot.LayoutTransform = New-Object Windows.Media.ScaleTransform $sm, $sm }
        } catch {}
    }
}

function Apply-ScaleAll {
    foreach ($b in Get-AllBoxes) { Apply-Scale $b }
    if ($script:ReportWin) {
        try {
            $s = [double]$script:Settings.UiScale
            if ([math]::Abs($s - 1.0) -lt 0.001) { $script:ReportWin.Content.LayoutTransform = $null }
            else { $script:ReportWin.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $s, $s }
        } catch {}
    }
}

# 박스 비율(가로/세로 %) 설정 - X/Y 중 지정한 축만 갱신 (50~200), 대상(내/상대)별 키에 기록
function Set-BoxRatio {
    param([int]$X = -1, [int]$Y = -1, [bool]$Persist = $true, [bool]$Opp = $false)
    $sfx = $(if ($Opp) { 'Opp' } else { '' })
    if ($X -ge 0) { $script:Settings["BoxRatioX$sfx"] = [math]::Max(50, [math]::Min(200, $X)) }
    if ($Y -ge 0) { $script:Settings["BoxRatioY$sfx"] = [math]::Max(50, [math]::Min(200, $Y)) }
    foreach ($b in Get-AllBoxes) { Apply-BoxRatio $b }
    Sync-RatioUi
    if ($Persist) { Save-Pos }
}

# 글자 크기 배율 설정 (50~200%), 대상(내/상대)별 키에 기록
function Set-FontScale {
    param([int]$V = -1, [bool]$Persist = $true, [bool]$Opp = $false)
    if ($V -ge 0) { $script:Settings[$(if ($Opp) { 'FontScaleOpp' } else { 'FontScale' })] = [math]::Max(50, [math]::Min(200, $V)) }
    foreach ($b in Get-AllBoxes) {
        Apply-FontScale $b
        Apply-BoxRatio $b   # 줄 간격·기준 폭이 글자 크기에 따라 달라짐
    }
    Sync-RatioUi
    if ($Persist) { Save-Pos }
}

# 크기·글자·비율 UI를 현재 편집 대상(내/상대) 값으로 동기화 + 대상 링크 시각 갱신
function Sync-RatioUi {
    $b = $script:MyBox
    if (-not $b -or -not $b.SldRatioX) { return }
    $opp = ($script:SizeTarget -eq 'opp')
    $old = $script:SyncingUI
    $script:SyncingUI = $true
    try {
        $b.TxRatioX.Text = [string][int](Get-SizeSetting 'BoxRatioX' $opp)
        $b.SldRatioX.Value = [double](Get-SizeSetting 'BoxRatioX' $opp)
        $b.TxRatioY.Text = [string][int](Get-SizeSetting 'BoxRatioY' $opp)
        $b.SldRatioY.Value = [double](Get-SizeSetting 'BoxRatioY' $opp)
        $b.TxFontSc.Text = [string][int](Get-SizeSetting 'FontScale' $opp)
        $b.SldFontSc.Value = [double](Get-SizeSetting 'FontScale' $opp)
        if ($b.CmbScale) {
            $idx = [Array]::IndexOf($script:ScaleSteps, [double](Get-SizeSetting 'UiScale' $opp))
            if ($idx -lt 0) { $idx = 3 }
            $b.CmbScale.SelectedIndex = $idx
        }
        foreach ($pair in @(@($b.TbSizeTgtMe, 'me'), @($b.TbSizeTgtOpp, 'opp'))) {
            $el = $pair[0]
            if (-not $el) { continue }
            if ($script:SizeTarget -eq $pair[1]) {
                $el.Opacity = 1.0
                $el.TextDecorations = [Windows.TextDecorations]::Underline
            } else {
                $el.Opacity = 0.45
                $el.TextDecorations = $null
            }
        }
    } finally { $script:SyncingUI = $old }
}

function Set-UiScale {
    param([double]$S, [bool]$Opp = $false)
    $S = [math]::Round([math]::Max(0.6, [math]::Min(2.0, $S)), 2)
    $key = $(if ($Opp) { 'UiScaleOpp' } else { 'UiScale' })
    if ([math]::Abs($S - [double]$script:Settings[$key]) -lt 0.001) { return }
    $script:Settings[$key] = $S
    Apply-ScaleAll
    Save-Pos
    # 설정의 크기 콤보는 현재 편집 대상과 일치할 때만 따라감
    if ($script:MyBox -and $script:MyBox.CmbScale -and ($Opp -eq ($script:SizeTarget -eq 'opp'))) {
        $script:SyncingUI = $true
        $idx = [Array]::IndexOf($script:ScaleSteps, $S)
        if ($idx -ge 0) { $script:MyBox.CmbScale.SelectedIndex = $idx }
        $script:SyncingUI = $false
    }
}

# 현재 유효 배경 투명도 (설정값, -1이면 테마 기본을 %로 환산)
function Get-EffBgAlpha {
    $av = [int]$script:Settings["BgAlpha$(Get-ThemeKey)"]
    if ($av -ge 0) { return $av }
    switch ($script:Theme) {
        'dark'  { return 32 }
        'trans' { return 0 }
        default { return 78 }
    }
}

# 배경 투명도 적용 (0~100, -1=테마 기본). Persist=false면 저장 없이 화면만 갱신 (드래그 중)
function Set-BgAlpha {
    param([int]$V, [bool]$Persist = $true)
    if ($V -ge 0) { $V = [math]::Max(0, [math]::Min(100, $V)) }
    $script:Settings["BgAlpha$(Get-ThemeKey)"] = $V
    if ($Persist) { Save-Pos }
    foreach ($bb in Get-AllBoxes) { if ($bb) { Apply-Theme $bb } }
    Sync-TxtColSwatch
}

# 기본 글자색 견본 동기화
function Sync-TxtColSwatch {
    $b = $script:MyBox
    if (-not $b -or -not $b.SwTxtCol) { return }
    if ($b.TbThemeEditL) {
        $tnm = '밝은'
        if ($script:Theme -eq 'dark') { $tnm = '다크' } elseif ($script:Theme -eq 'trans') { $tnm = '투명' }
        $b.TbThemeEditL.Text = ('── 색·투명도 · 지금 편집: {0} 테마 (◐로 전환) ──' -f $tnm)
    }
    $c = [string]$script:Settings["TextColor$(Get-ThemeKey)"]
    if (-not $c) {
        switch ($script:Theme) {
            'dark' { $c = '#FFD9DCE1' }
            'trans' { $c = '#FFFFFFFF' }
            default { $c = '#FF16213E' }
        }
    }
    try { $b.SwTxtCol.Background = New-Brush $c } catch {}
    if ($b.SwBgCol) {
        $bc = [string]$script:Settings["BgColor$(Get-ThemeKey)"]
        if (-not $bc) {
            switch ($script:Theme) {
                'light' { $bc = '#FFFFFFFF' }
                default { $bc = '#FF10131C' }
            }
        }
        try { $b.SwBgCol.Background = New-Brush $bc } catch {}
    }
    if ($b.SldBgAlpha) {
        $script:SyncingUI = $true
        $av = Get-EffBgAlpha
        $b.SldBgAlpha.Value = $av
        $b.TxBgAlpha.Text = [string]$av
        $script:SyncingUI = $false
    }
}

# 프리셋 콤보 목록 동기화
function Sync-PresetList {
    param($B)
    if (-not $B -or -not $B.CmbPreset) { return }
    $B.CmbPreset.Items.Clear()
    foreach ($nm in @($script:Presets.Keys | Sort-Object)) { $null = $B.CmbPreset.Items.Add($nm) }
    if ($B.CmbPreset.Items.Count -gt 0) { $B.CmbPreset.SelectedIndex = 0 }
}

# 체크 상태에 따라 하위 설정 섹션 표시/숨김
# 기준 시점 '직접 지정' 패널 동기화 (표시 여부·방식 콤보·입력값·힌트)
function Sync-BasePanel {
    param($b)
    if (-not $b -or -not $b.BasePanel) { return }
    $isCustom = ([string]$script:Settings.SessionBase -eq 'custom')
    $b.BasePanel.Visibility = $(if ($isCustom) { 'Visible' } else { 'Collapsed' })
    if (-not $isCustom) { return }
    $kind = [string]$script:Settings.BaseCustomKind
    $ki = [Array]::IndexOf(@('abs', 'relday', 'relhr'), $kind)
    if ($ki -lt 0) { $ki = 1 }
    $b.CmbBaseKind.SelectedIndex = $ki
    if ($kind -eq 'abs') {
        $parts = @(([string]$script:Settings.BaseCustomAbs) -split ' ')
        $b.TxBaseA.Text = [string]$parts[0]
        $b.TxBaseB.Text = $(if ($parts.Count -gt 1) { [string]$parts[1] } else { '0' })
        $b.TxBaseB.Visibility = 'Visible'
        $b.TbBaseHint.Text = '날짜(연-월-일)와 시(0~23)부터 집계'
    } elseif ($kind -eq 'relhr') {
        $b.TxBaseA.Text = [string][int]$script:Settings.BaseCustomHours
        $b.TxBaseB.Visibility = 'Collapsed'
        $b.TbBaseHint.Text = '지금 기준 시간 오프셋 (예: -6 = 최근 6시간)'
    } else {
        $b.TxBaseA.Text = [string][int]$script:Settings.BaseCustomDays
        $b.TxBaseB.Visibility = 'Collapsed'
        $b.TbBaseHint.Text = '오늘 0시 기준 일 오프셋 (예: -3 = 3일 전 0시부터)'
    }
}

# '직접 지정' 입력 반영 (형식이 틀리면 그 값만 무시하고 기존 설정 유지)
function Apply-BaseCustom {
    param($b)
    if (-not $b -or -not $b.CmbBaseKind) { return }
    $kind = @('abs', 'relday', 'relhr')[[math]::Max(0, $b.CmbBaseKind.SelectedIndex)]
    $script:Settings.BaseCustomKind = $kind
    $a = ([string]$b.TxBaseA.Text).Trim()
    if ($kind -eq 'abs') {
        $hh = 0
        if (-not [int]::TryParse(([string]$b.TxBaseB.Text).Trim(), [ref]$hh)) { $hh = 0 }
        $hh = [math]::Max(0, [math]::Min(23, $hh))
        $dt = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($a, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
            $script:Settings.BaseCustomAbs = ('{0} {1}' -f $dt.ToString('yyyy-MM-dd'), $hh)
        }
    } elseif ($kind -eq 'relhr') {
        $v = 0
        if ([int]::TryParse($a, [ref]$v)) { $script:Settings.BaseCustomHours = $v }
    } else {
        $v = 0
        if ([int]::TryParse($a, [ref]$v)) { $script:Settings.BaseCustomDays = $v }
    }
    $script:ForceReset = $true
    Sync-BasePanel $b
    Update-BasisLabels
    Save-Pos
    Request-OverlayUpdate
}

function Sync-SettingSections {
    foreach ($b in Get-AllBoxes) {
        if (-not $b -or -not $b.AnomRow) { continue }
        $anom = [bool]$script:Settings.Anom
        $b.BtnAdv.Visibility = $(if ($anom) { 'Visible' } else { 'Collapsed' })
        if (-not $anom) {
            $b.AdvPanel.Visibility = 'Collapsed'
            $b.BtnAdv.Text = '고급 설정 ▾'
        }
        $bg = [bool]$script:Settings.BadgeOn
        $b.BtnBadgeAdv.Visibility = $(if ($bg) { 'Visible' } else { 'Collapsed' })
        if (-not $bg) {
            $b.BadgePanel.Visibility = 'Collapsed'
            $b.BtnBadgeAdv.Text = '고급 설정 ▾'
        }
    }
}

# 강조 색상 견본 갱신
function Sync-AnomSwatches {
    foreach ($b in Get-AllBoxes) {
        if (-not $b -or -not $b.SwHigh) { continue }
        try {
            $b.SwHigh.Background = New-Brush ([string]$script:Settings.AnomHigh)
            $b.SwLow.Background = New-Brush ([string]$script:Settings.AnomLow)
        } catch {}
    }
}

# 표시 항목 (대상별 on/off) — 일부 항목은 내 박스에만 데이터가 있어 상대 박스에선 효과 없음
$script:DispItems = @(
    @{ K = 'Rank'; N = '랭크·점수 줄' }, @{ K = 'Goal'; N = '승단 카운트다운·목표 줄'; Me = $true }
    @{ K = 'Game'; N = '전적 줄' }, @{ K = 'Stat1'; N = '화료·방총·유국텐파이율' },
    @{ K = 'Stat2'; N = '리치·후로·다마화료율' }, @{ K = 'Stat3'; N = '평균타점·평균방총점' },
    @{ K = 'Tobi'; N = '토비율' }, @{ K = 'Wt'; N = '평균화료순' }, @{ K = 'AvgPl'; N = '평균순위' }, @{ K = 'Rentai'; N = '연대율' }, @{ K = 'Lasu'; N = '라스율' }, @{ K = 'Ppg'; N = '국당수지' }, @{ K = 'StatSrc'; N = '지표 출처 표기' }, @{ K = 'Stat4'; N = '우형리치·선제리치율' },
    @{ K = 'Stable'; N = '안정단위' }, @{ K = 'Badge'; N = '스타일 배지' },
    @{ K = 'NameColor'; N = '닉네임 강함 색상' },
    @{ K = 'SeqColor'; N = '{기준} 순위 색상'; Me = $true }, @{ K = 'Streak'; N = '연대/라스 스트릭'; Me = $true },
    @{ K = 'Spark'; N = '{기준} pt 그래프'; Me = $true }
)
$script:DispTarget = 'me'
$script:SizeTarget = 'me'   # 크기·글자·비율 설정의 편집 대상 (me/opp)

function Test-DispOn {
    param([string]$K, [bool]$IsOpp)
    $off = [string]$(if ($IsOpp) { $script:Settings.DispOffOpp } else { $script:Settings.DispOffMe })
    if (-not $off) { return $true }
    return (@($off -split ',') -notcontains $K)
}

# 도움말 고정 창 (마우스 오버 툴팁과 같은 모양, X 또는 ? 재클릭으로 닫힘)
function Hide-HelpPin {
    if ($script:HelpPop) {
        try { $script:HelpPop.IsOpen = $false } catch {}
        $script:HelpPop = $null
    }
    foreach ($b in Get-AllBoxes) {
        if ($b -and $b.BtnHelp) { try { $b.BtnHelp.ToolTip = (Get-HelpText) } catch {} }
    }
}

function Show-HelpPin {
    param($Box)
    if ($script:HelpPop -and $script:HelpPop.IsOpen) { Hide-HelpPin; return }
    try {
        $pop = New-Object Windows.Controls.Primitives.Popup
        $pop.PlacementTarget = $Box.BtnHelp
        $pop.Placement = 'Bottom'
        $pop.HorizontalOffset = -6
        $pop.StaysOpen = $true
        $pop.AllowsTransparency = $true

        $bd = New-Object Windows.Controls.Border
        $bd.Background = New-Brush '#FFF7F8FA'
        $bd.BorderBrush = New-Brush '#FF9AA3B0'
        $bd.BorderThickness = New-Object Windows.Thickness 1
        $bd.CornerRadius = New-Object Windows.CornerRadius 6
        $bd.Padding = New-Object Windows.Thickness 12, 8, 12, 10
        $sc = [double]$script:Settings.UiScale
        if ([math]::Abs($sc - 1.0) -ge 0.001) { $bd.LayoutTransform = New-Object Windows.Media.ScaleTransform $sc, $sc }

        $dp = New-Object Windows.Controls.DockPanel
        $x = New-Object Windows.Controls.TextBlock
        $x.Text = '✕'
        $x.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $x.FontSize = 12
        $x.FontWeight = [Windows.FontWeights]::Bold
        $x.Foreground = New-Brush '#FF6B7280'
        $x.Cursor = [Windows.Input.Cursors]::Hand
        $x.HorizontalAlignment = 'Right'
        $x.Margin = New-Object Windows.Thickness 10, 0, 0, 4
        [Windows.Controls.DockPanel]::SetDock($x, 'Top')
        $x.Add_MouseLeftButtonDown({ $args[1].Handled = $true; Hide-HelpPin })
        $null = $dp.Children.Add($x)

        $tx = New-Object Windows.Controls.TextBlock
        $tx.Text = (Get-HelpText)
        $tx.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $tx.FontSize = 12.5
        $tx.FontWeight = [Windows.FontWeights]::Bold
        $tx.Foreground = New-Brush '#FF16213E'
        $tx.TextWrapping = 'Wrap'
        $tx.MaxWidth = 420
        $null = $dp.Children.Add($tx)

        $bd.Child = $dp
        $pop.Child = $bd
        $script:HelpPop = $pop
        # 고정 창이 열린 동안에는 호버 툴팁을 끔 (겹침 방지)
        foreach ($b in Get-AllBoxes) { if ($b -and $b.BtnHelp) { $b.BtnHelp.ToolTip = $null } }
        $pop.IsOpen = $true
    } catch {}
}

function Build-DispPanel {
    param($Box)
    if (-not $Box.DispPanel) { return }
    $Box.DispPanel.Children.Clear()
    $fg = $Box.CbAnom.Foreground
    $isOpp = ($script:DispTarget -eq 'opp')

    $hdr = New-Object Windows.Controls.StackPanel
    $hdr.Orientation = 'Horizontal'
    $hdr.Margin = New-Object Windows.Thickness 0, 0, 0, 3
    foreach ($t in @(@{ K = 'me'; N = '내 박스' }, @{ K = 'opp'; N = '상대 박스' })) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = [string]$t.N
        $tb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $tb.FontSize = 12
        $tb.FontWeight = [Windows.FontWeights]::Bold
        $tb.Foreground = $fg
        $tb.Cursor = [Windows.Input.Cursors]::Hand
        $tb.Margin = New-Object Windows.Thickness 0, 0, 12, 0
        $tb.Tag = @{ K = [string]$t.K; B = $Box }
        if ([string]$t.K -eq $script:DispTarget) {
            $tb.Opacity = 1.0
            $tb.TextDecorations = [Windows.TextDecorations]::Underline
        } else { $tb.Opacity = 0.45 }
        $tb.Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $script:DispTarget = [string]$args[0].Tag.K
            Build-DispPanel $args[0].Tag.B
        })
        $null = $hdr.Children.Add($tb)
    }
    $null = $Box.DispPanel.Children.Add($hdr)

    foreach ($it in $script:DispItems) {
        # 내 박스에만 존재하는 데이터 항목은 상대 탭에서 숨김
        if ($isOpp -and $it.Me) { continue }
        $cb = New-Object Windows.Controls.CheckBox
        $cb.HorizontalAlignment = 'Left'   # 라벨 오른쪽 빈칸 클릭이 체크를 건드리지 않게
        # '{기준}'은 기준 시점 설정에 따라 '오늘' / '실행 후'로 바뀐다
        $cb.Content = ([string]$it.N) -replace '\{기준\}', (Get-BasisLabel 'base')
        $cb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $cb.FontSize = 12.5
        $cb.FontWeight = [Windows.FontWeights]::Bold
        $cb.Foreground = $fg
        $cb.Margin = New-Object Windows.Thickness 0, 1, 0, 1
        $cb.IsChecked = (Test-DispOn ([string]$it.K) $isOpp)
        $cb.Tag = @{ K = [string]$it.K; O = $isOpp }
        $cb.Add_Click({
            $k = [string]$args[0].Tag.K
            $o = [bool]$args[0].Tag.O
            $cur = [string]$(if ($o) { $script:Settings.DispOffOpp } else { $script:Settings.DispOffMe })
            $off = @($cur -split ',' | Where-Object { $_ })
            if ($args[0].IsChecked) { $off = @($off | Where-Object { $_ -ne $k }) }
            elseif ($off -notcontains $k) { $off += $k }
            $val = ($off -join ',')
            if ($o) { $script:Settings.DispOffOpp = $val } else { $script:Settings.DispOffMe = $val }
            Save-Pos
            Refresh-Display
        })
        if ([string]$it.K -eq 'Stable' -and $Box.BtnStableAdv -and $Box.StablePanel) {
            # 안정단위: 체크박스 오른쪽에 고급 설정 링크, 아래에 패널 (설정은 나/상대 공용)
            $srow = New-Object Windows.Controls.StackPanel
            $srow.Orientation = 'Horizontal'
            $srow.Margin = $cb.Margin
            $cb.Margin = New-Object Windows.Thickness 0
            $cb.VerticalAlignment = 'Center'
            $null = $srow.Children.Add($cb)
            $parB = $Box.BtnStableAdv.Parent
            if ($parB -and $parB -is [Windows.Controls.Panel]) { $parB.Children.Remove($Box.BtnStableAdv) }
            $Box.BtnStableAdv.Margin = New-Object Windows.Thickness 10, 0, 0, 0
            $Box.BtnStableAdv.VerticalAlignment = 'Center'
            $null = $srow.Children.Add($Box.BtnStableAdv)
            $null = $Box.DispPanel.Children.Add($srow)
            $parS = $Box.StablePanel.Parent
            if ($parS -and $parS -is [Windows.Controls.Panel]) { $parS.Children.Remove($Box.StablePanel) }
            $null = $Box.DispPanel.Children.Add($Box.StablePanel)
        } else {
            $null = $Box.DispPanel.Children.Add($cb)
        }
    }
}

# 스타일 배지 편집 패널
function Build-BadgePanel {
    param($Box)
    if (-not $Box.BadgePanel) { return }
    $Box.BadgePanel.Children.Clear()
    $fg = $Box.CbAnom.Foreground
    $bh = New-Object Windows.Controls.TextBlock
    $bh.Text = '── 배지 조건 ──'
    $bh.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $bh.FontSize = 11.5
    $bh.FontWeight = [Windows.FontWeights]::Bold
    $bh.Foreground = $fg
    $bh.Opacity = 0.7
    $bh.Margin = New-Object Windows.Thickness 0, 8, 0, 3
    $null = $Box.BadgePanel.Children.Add($bh)

    $defs = @(Get-BadgeDefs)
    for ($bi = 0; $bi -lt $defs.Count; $bi++) {
        $d = $defs[$bi]
        $isPt = ($script:BadgePointKeys -contains [string]$d.K)
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Object Windows.Thickness 0, 1, 0, 1

        $nm = New-Object Windows.Controls.TextBlock
        $nm.Text = ('{0}{1}' -f $d.Icon, $d.Name)
        $nm.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $nm.FontSize = 12
        $nm.FontWeight = [Windows.FontWeights]::Bold
        $nm.Foreground = $fg
        $nm.Width = 78
        $nm.VerticalAlignment = 'Center'
        $null = $row.Children.Add($nm)

        $cond = New-Object Windows.Controls.TextBlock
        $sn = [string]$script:BadgeStatNames[[string]$d.K]
        if (-not $sn) { $sn = [string]$d.K }
        $cond.Text = ('{0} {1} ' -f $sn, $(if ([string]$d.Op -eq 'le') { '≤' } else { '≥' }))
        $cond.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $cond.FontSize = 11.5
        $cond.Foreground = $fg
        $cond.Opacity = 0.85
        $cond.Width = 96
        $cond.TextAlignment = 'Right'
        $cond.VerticalAlignment = 'Center'
        $null = $row.Children.Add($cond)

        $tv = New-Object Windows.Controls.TextBox
        $tv.Width = 46
        $tv.FontSize = 11.5
        $tv.VerticalContentAlignment = 'Center'
        $tv.Text = $(if ($isPt) { [string][int]$d.V } else { '{0:N1}' -f ([double]$d.V * 100) })
        $tv.Tag = @{ I = $bi; P = $isPt; B = $Box }
        $applyVal = {
            $t = $args[0].Tag
            $dd = @(Get-BadgeDefs)
            $num = 0.0
            if ([double]::TryParse(([string]$args[0].Text).Trim(), [ref]$num)) {
                $dd[[int]$t.I].V = $(if ([bool]$t.P) { $num } else { $num / 100.0 })
                Set-BadgeDefs $dd
                Save-Pos
                Refresh-Display
                Build-BadgePanel $t.B
            }
        }
        $tv.Add_LostFocus($applyVal)
        $tv.Add_KeyDown({ if ($args[1].Key -eq 'Return') { $args[1].Handled = $true; & $script:BadgeApply $args[0] } })
        $script:BadgeApply = $applyVal
        $null = $row.Children.Add($tv)

        $un = New-Object Windows.Controls.TextBlock
        $un.Text = $(if ($isPt) { ' 점 ' } else { ' % ' })
        $un.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $un.FontSize = 11.5
        $un.Foreground = $fg
        $un.Opacity = 0.85
        $un.VerticalAlignment = 'Center'
        $null = $row.Children.Add($un)

        $del = New-Object Windows.Controls.TextBlock
        $del.Text = '✕'
        $del.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $del.FontSize = 11.5
        $del.FontWeight = [Windows.FontWeights]::Bold
        $del.Foreground = $fg
        $del.Opacity = 0.6
        $del.Cursor = [Windows.Input.Cursors]::Hand
        $del.VerticalAlignment = 'Center'
        $del.Tag = @{ I = $bi; B = $Box }
        $del.Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $t = $args[0].Tag
            $dd = @(Get-BadgeDefs)
            $keep = @()
            for ($j = 0; $j -lt $dd.Count; $j++) { if ($j -ne [int]$t.I) { $keep += , $dd[$j] } }
            Set-BadgeDefs $keep
            Save-Pos
            Refresh-Display
            Build-BadgePanel $t.B
        })
        $null = $row.Children.Add($del)
        $null = $Box.BadgePanel.Children.Add($row)
    }

    # 배지 추가 입력 행
    $add = New-Object Windows.Controls.StackPanel
    $add.Orientation = 'Horizontal'
    $add.Margin = New-Object Windows.Thickness 0, 4, 0, 0

    $aIcon = New-Object Windows.Controls.TextBox
    $aIcon.Width = 30; $aIcon.FontSize = 11.5; $aIcon.Text = '★'
    $aIcon.ToolTip = '아이콘(이모지)'
    $null = $add.Children.Add($aIcon)
    $aName = New-Object Windows.Controls.TextBox
    $aName.Width = 60; $aName.FontSize = 11.5; $aName.Margin = New-Object Windows.Thickness 2, 0, 2, 0
    $aName.ToolTip = '배지 이름'
    $null = $add.Children.Add($aName)
    $aStat = New-Object Windows.Controls.ComboBox
    $aStat.Width = 92; $aStat.FontSize = 11.5
    foreach ($kk in @('hr', 'dl', 'ryu', 'ri', 'fu', 'dama', 'dp', 'dpl', 'tobi', 'wt', 'gs', 'sente', 'games')) {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $ci.Content = [string]$script:BadgeStatNames[$kk]
        $ci.Tag = $kk
        $null = $aStat.Items.Add($ci)
    }
    $aStat.SelectedIndex = 0
    $null = $add.Children.Add($aStat)
    $aOp = New-Object Windows.Controls.ComboBox
    $aOp.Width = 42; $aOp.FontSize = 11.5; $aOp.Margin = New-Object Windows.Thickness 2, 0, 2, 0
    foreach ($oo in @('≥', '≤')) {
        $ci = New-Object Windows.Controls.ComboBoxItem
        $ci.Content = $oo
        $ci.Tag = $(if ($oo -eq '≤') { 'le' } else { 'ge' })
        $null = $aOp.Items.Add($ci)
    }
    $aOp.SelectedIndex = 0
    $null = $add.Children.Add($aOp)
    $aVal = New-Object Windows.Controls.TextBox
    $aVal.Width = 42; $aVal.FontSize = 11.5
    $aVal.ToolTip = '값 (%, 점수 항목은 점)'
    $null = $add.Children.Add($aVal)
    $aBtn = New-Object Windows.Controls.TextBlock
    $aBtn.Text = ' 추가'
    $aBtn.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $aBtn.FontSize = 11.5
    $aBtn.FontWeight = [Windows.FontWeights]::Bold
    $aBtn.Foreground = $fg
    $aBtn.Cursor = [Windows.Input.Cursors]::Hand
    $aBtn.VerticalAlignment = 'Center'
    $aBtn.Tag = @{ Icon = $aIcon; Name = $aName; Stat = $aStat; Op = $aOp; Val = $aVal; B = $Box }
    $aBtn.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $t = $args[0].Tag
        $nm = ([string]$t.Name.Text).Trim()
        $num = 0.0
        if (-not $nm) { return }
        if (-not [double]::TryParse(([string]$t.Val.Text).Trim(), [ref]$num)) { return }
        $key = [string]$t.Stat.SelectedItem.Tag
        $isPt = ($script:BadgePointKeys -contains $key)
        $dd = @(Get-BadgeDefs)
        $dd += , @{
            Icon = ([string]$t.Icon.Text).Trim(); Name = $nm; K = $key
            Op = [string]$t.Op.SelectedItem.Tag; V = $(if ($isPt) { $num } else { $num / 100.0 })
        }
        Set-BadgeDefs $dd
        Save-Pos
        Refresh-Display
        Build-BadgePanel $t.B
    })
    $null = $add.Children.Add($aBtn)
    $null = $Box.BadgePanel.Children.Add($add)

    # 배지 기본값 복원
    $brst = New-Object Windows.Controls.TextBlock
    $brst.Text = '배지 기본값으로 되돌리기'
    $brst.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $brst.FontSize = 11.5
    $brst.FontWeight = [Windows.FontWeights]::Bold
    $brst.Foreground = $fg
    $brst.Opacity = 0.75
    $brst.Margin = New-Object Windows.Thickness 0, 4, 0, 0
    $brst.Cursor = [Windows.Input.Cursors]::Hand
    $brst.Tag = $Box
    $brst.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $script:Settings.BadgeDefs = ''
        Save-Pos
        Refresh-Display
        Build-BadgePanel $args[0].Tag
    })
    $null = $Box.BadgePanel.Children.Add($brst)

}

# 안정단위 고급 설정: 기준 모드(나/상대) + 등급 구간 색상
function Build-StablePanel {
    param($Box)
    if (-not $Box.StablePanel) { return }
    $Box.StablePanel.Children.Clear()
    $fg = $Box.CbAnom.Foreground
    $modeCodes = @('auto', '8', '9', '11', '12', '15', '16')
    $modeLabels = @('자동(다수결)', '금동', '금남', '옥동', '옥남', '왕좌동', '왕좌남')

    foreach ($t in @(@{ K = 'MyStableMode'; N = '내 기준 모드' }, @{ K = 'OppStableMode'; N = '상대 기준 모드' })) {
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Object Windows.Thickness 0, 1, 0, 1
        $lb = New-Object Windows.Controls.TextBlock
        $lb.Text = [string]$t.N
        $lb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $lb.FontSize = 12
        $lb.FontWeight = [Windows.FontWeights]::Bold
        $lb.Foreground = $fg
        $lb.Width = 104
        $lb.VerticalAlignment = 'Center'
        $null = $row.Children.Add($lb)
        $cmb = New-Object Windows.Controls.ComboBox
        $cmb.Width = 110
        $cmb.FontSize = 11.5
        foreach ($ml in $modeLabels) { $null = $cmb.Items.Add($ml) }
        $ci = [Array]::IndexOf($modeCodes, [string]$script:Settings[[string]$t.K])
        $cmb.SelectedIndex = [math]::Max(0, $ci)
        $cmb.Tag = [string]$t.K
        $cmb.Add_SelectionChanged({
            $c = $args[0]
            if ($c.SelectedIndex -lt 0) { return }
            $codes = @('auto', '8', '9', '11', '12', '15', '16')
            $k = [string]$c.Tag
            $script:Settings[$k] = $codes[$c.SelectedIndex]
            Save-Pos
            if ($k -eq 'MyStableMode') {
                $script:MyDomModeKey = $null   # 판별 캐시 무효화
                Request-OverlayUpdate
            } else {
                $script:OppCache = @{}         # 다음 스캔부터 새 기준
            }
        })
        $null = $row.Children.Add($cmb)
        $null = $Box.StablePanel.Children.Add($row)
    }

    # 금캉스 구분: 금탁에서 옥탁 20국+ 상대는 옥 기준 병행 표시
    $cbd = New-Object Windows.Controls.CheckBox
    $cbd.HorizontalAlignment = 'Left'
    $cbd.Content = '금탁에서 옥탁 기준 병행 표시'
    $cbd.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $cbd.FontSize = 12
    $cbd.FontWeight = [Windows.FontWeights]::Bold
    $cbd.Foreground = $fg
    $cbd.Margin = New-Object Windows.Thickness 0, 3, 0, 1
    $cbd.IsChecked = [bool]$script:Settings.StableDual
    $cbd.ToolTip = '옥탁 20국 이상 기록이 있는 상대를 금탁에서 만나면 금·옥 기준을 모두 표시'
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($cbd, 0)
    $cbd.Add_Click({
        $script:Settings.StableDual = [bool]$args[0].IsChecked
        Save-Pos
        $script:OppCache = @{}   # 다음 스캔부터 적용
    })
    $null = $Box.StablePanel.Children.Add($cbd)

    # 왕캉스 구분: 옥탁에서 왕좌 20국+ 상대는 왕좌 기준 병행
    $cbt = New-Object Windows.Controls.CheckBox
    $cbt.HorizontalAlignment = 'Left'
    $cbt.Content = '옥탁에서 왕좌탁 기준 병행 표시'
    $cbt.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $cbt.FontSize = 12
    $cbt.FontWeight = [Windows.FontWeights]::Bold
    $cbt.Foreground = $fg
    $cbt.Margin = New-Object Windows.Thickness 0, 1, 0, 1
    $cbt.IsChecked = [bool]$script:Settings.StableDualThrone
    $cbt.ToolTip = '왕좌탁 20국 이상 기록이 있는 상대를 옥탁에서 만나면 옥·왕좌 기준을 모두 표시'
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($cbt, 0)
    $cbt.Add_Click({
        $script:Settings.StableDualThrone = [bool]$args[0].IsChecked
        Save-Pos
        $script:OppCache = @{}   # 다음 스캔부터 적용
    })
    $null = $Box.StablePanel.Children.Add($cbt)

    # 왕좌탁: 방 기준 우선 + 주력 병행
    $cbr = New-Object Windows.Controls.CheckBox
    $cbr.HorizontalAlignment = 'Left'
    $cbr.Content = '왕좌탁에서 왕좌 기준 우선 표시'
    $cbr.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $cbr.FontSize = 12
    $cbr.FontWeight = [Windows.FontWeights]::Bold
    $cbr.Foreground = $fg
    $cbr.Margin = New-Object Windows.Thickness 0, 1, 0, 1
    $cbr.IsChecked = [bool]$script:Settings.StableRoomFirst
    $cbr.ToolTip = '왕좌탁 기록(20국+)이 있으면 왕좌 기준을 먼저 보여주고, 주력 모드가 다르면 다음 줄에 병행. 끄면 기존처럼 주력(다수결) 기준만 표시'
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($cbr, 0)
    $cbr.Add_Click({
        $script:Settings.StableRoomFirst = [bool]$args[0].IsChecked
        Save-Pos
        $script:OppCache = @{}   # 다음 스캔부터 적용
    })
    $null = $Box.StablePanel.Children.Add($cbr)

    $hd = New-Object Windows.Controls.TextBlock
    $hd.Text = '── 구간 색상 ──'
    $hd.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $hd.FontSize = 11.5
    $hd.FontWeight = [Windows.FontWeights]::Bold
    $hd.Foreground = $fg
    $hd.Opacity = 0.7
    $hd.Margin = New-Object Windows.Thickness 0, 5, 0, 2
    $null = $Box.StablePanel.Children.Add($hd)

    foreach ($tk in 'sasa', 'geol', 'ho', 'seong', 'konten') {
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Object Windows.Thickness 0, 1, 0, 1
        $lb = New-Object Windows.Controls.TextBlock
        $lb.Text = [string]$script:StableTierNames[$tk]
        $lb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $lb.FontSize = 12
        $lb.FontWeight = [Windows.FontWeights]::Bold
        $lb.Foreground = $fg
        $lb.Width = 104
        $lb.VerticalAlignment = 'Center'
        $null = $row.Children.Add($lb)
        $sw = New-Object Windows.Controls.Border
        $sw.Width = 20; $sw.Height = 15
        $sw.CornerRadius = New-Object Windows.CornerRadius 3
        $sw.BorderThickness = New-Object Windows.Thickness 1
        $sw.BorderBrush = New-Brush '#88888888'
        $sw.Cursor = [Windows.Input.Cursors]::Hand
        $sw.Background = New-Brush (Get-StableTierColor $tk)
        $sw.Tag = @{ T = $tk; B = $Box }
        $sw.Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $t2 = $args[0].Tag
            $script:PickCtx = $t2
            Show-ColorPicker $args[0] (Get-StableTierColor ([string]$t2.T)) {
                param($hex)
                $c2 = $script:PickCtx
                Set-StableTierColor ([string]$c2.T) $hex
                Save-Pos
                Build-StablePanel $c2.B
                Refresh-Display
            }
        })
        $null = $row.Children.Add($sw)
        $null = $Box.StablePanel.Children.Add($row)
    }

    $rst = New-Object Windows.Controls.TextBlock
    $rst.Text = '색 기본값으로 되돌리기'
    $rst.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $rst.FontSize = 11.5
    $rst.FontWeight = [Windows.FontWeights]::Bold
    $rst.Foreground = $fg
    $rst.Opacity = 0.75
    $rst.Margin = New-Object Windows.Thickness 0, 4, 0, 0
    $rst.Cursor = [Windows.Input.Cursors]::Hand
    $rst.Tag = $Box
    $rst.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $script:Settings.StableColors = ''
        Save-Pos
        Build-StablePanel $args[0].Tag
        Refresh-Display
    })
    $null = $Box.StablePanel.Children.Add($rst)
}

# 고급 설정: 대상(나/상대)별 · 항목별 강조 on/off 및 색상
$script:AdvTarget = 'me'

function Build-AdvPanel {
    param($Box)
    $Box.AdvPanel.Children.Clear()
    $fg = $Box.CbAnom.Foreground
    $isOpp = ($script:AdvTarget -eq 'opp')

    # 방식·전역 강함/약함 색 행도 고급 설정 안에 배치
    if ($Box.AnomRow) {
        $parA = $Box.AnomRow.Parent
        if ($parA -and $parA -is [Windows.Controls.Panel]) { $parA.Children.Remove($Box.AnomRow) }
        $Box.AnomRow.Margin = New-Object Windows.Thickness 0, 0, 0, 3
        $Box.AnomRow.Visibility = 'Visible'
        $null = $Box.AdvPanel.Children.Add($Box.AnomRow)
    }

    # 대상 전환 (나 / 상대)
    $hdr = New-Object Windows.Controls.StackPanel
    $hdr.Orientation = 'Horizontal'
    $hdr.Margin = New-Object Windows.Thickness 0, 0, 0, 3
    foreach ($t in @(@{ K = 'me'; N = '내 박스' }, @{ K = 'opp'; N = '상대 박스' })) {
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = [string]$t.N
        $tb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $tb.FontSize = 12
        $tb.FontWeight = [Windows.FontWeights]::Bold
        $tb.Foreground = $fg
        $tb.Cursor = [Windows.Input.Cursors]::Hand
        $tb.Margin = New-Object Windows.Thickness 0, 0, 12, 0
        $tb.Tag = @{ K = [string]$t.K; B = $Box }
        if ([string]$t.K -eq $script:AdvTarget) {
            $tb.Opacity = 1.0
            $tb.TextDecorations = [Windows.TextDecorations]::Underline
        } else { $tb.Opacity = 0.45 }
        # 창 드래그(DragMove)가 마우스를 캡처하지 않도록 Down에서 처리
        $tb.Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $script:AdvTarget = [string]$args[0].Tag.K
            Build-AdvPanel $args[0].Tag.B
        })
        $null = $hdr.Children.Add($tb)
    }
    $null = $Box.AdvPanel.Children.Add($hdr)

    # 열 머릿말: 색 견본 두 칸(강함/약함 방향) + 문턱값
    $cap = New-Object Windows.Controls.StackPanel
    $cap.Orientation = 'Horizontal'
    $cap.Margin = New-Object Windows.Thickness 0, 0, 0, 1
    $sp0 = New-Object Windows.Controls.TextBlock
    $sp0.Width = 118
    $null = $cap.Children.Add($sp0)
    foreach ($ct in @('높음', '낮음')) {
        $cl2 = New-Object Windows.Controls.TextBlock
        $cl2.Text = $ct
        $cl2.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $cl2.FontSize = 9.5
        $cl2.FontWeight = [Windows.FontWeights]::Bold
        $cl2.Foreground = $fg
        $cl2.Opacity = 0.65
        $cl2.Width = 21
        $cl2.TextAlignment = 'Center'
        $null = $cap.Children.Add($cl2)
    }
    $cl3 = New-Object Windows.Controls.TextBlock
    $cl3.Text = '문턱값(±%)'
    $cl3.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $cl3.FontSize = 9.5
    $cl3.FontWeight = [Windows.FontWeights]::Bold
    $cl3.Foreground = $fg
    $cl3.Opacity = 0.65
    $cl3.Margin = New-Object Windows.Thickness 10, 0, 0, 0
    $null = $cap.Children.Add($cl3)
    $null = $Box.AdvPanel.Children.Add($cap)

    foreach ($it in $script:AnomItems) {
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Object Windows.Thickness 0, 1, 0, 1

        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = [string]$it.N
        $cb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $cb.FontSize = 12
        $cb.FontWeight = [Windows.FontWeights]::Bold
        $cb.Foreground = $fg
        $cb.Width = 118
        $cb.VerticalAlignment = 'Center'
        $cb.IsChecked = (Test-AnomEnabled ([string]$it.K) $isOpp)
        $cb.Tag = @{ K = [string]$it.K; O = $isOpp }
        $cb.Add_Click({
            $k = [string]$args[0].Tag.K
            $o = [bool]$args[0].Tag.O
            $cur = [string]$(if ($o) { $script:Settings.AnomOffOpp } else { $script:Settings.AnomOffMe })
            $off = @($cur -split ',' | Where-Object { $_ })
            if ($args[0].IsChecked) { $off = @($off | Where-Object { $_ -ne $k }) }
            elseif ($off -notcontains $k) { $off += $k }
            $val = ($off -join ',')
            if ($o) { $script:Settings.AnomOffOpp = $val } else { $script:Settings.AnomOffMe = $val }
            Save-Pos
            Refresh-Display
        })
        $null = $row.Children.Add($cb)

        # 항목별 높음/낮음 색 견본 (기본색은 방향 반전이 반영된 실표시 색을 미리보기)
        foreach ($w in @('H', 'L')) {
            $sw = New-Object Windows.Controls.Border
            $sw.Width = 18; $sw.Height = 14
            $sw.CornerRadius = New-Object Windows.CornerRadius 3
            $sw.Margin = New-Object Windows.Thickness 3, 0, 0, 0
            $sw.BorderThickness = New-Object Windows.Thickness 1
            $sw.BorderBrush = New-Brush '#88888888'
            $sw.Cursor = [Windows.Input.Cursors]::Hand
            $hotVal = $(if ($w -eq 'H') { 2 } else { 1 })
            $sw.Background = New-Brush (Get-AnomColor ([string]$it.K) $hotVal $isOpp)
            $sw.ToolTip = $(if ($w -eq 'H') { '평균보다 높을 때 색' } else { '평균보다 낮을 때 색' })
            [Windows.Controls.ToolTipService]::SetInitialShowDelay($sw, 0)
            $sw.Tag = @{ K = [string]$it.K; W = $w; O = $isOpp; B = $Box }
            $sw.Add_MouseLeftButtonDown({
                $args[1].Handled = $true
                $t = $args[0].Tag
                $cur = Get-AnomColor ([string]$t.K) $(if ([string]$t.W -eq 'H') { 2 } else { 1 }) ([bool]$t.O)
                $script:PickCtx = $t
                Show-ColorPicker $args[0] $cur {
                    param($hex)
                    $c = $script:PickCtx
                    Set-AnomC ([bool]$c.O) ([string]$c.K) ([string]$c.W) $hex
                    Save-Pos
                    Build-AdvPanel $c.B
                    Refresh-Display
                }
            })
            $null = $row.Children.Add($sw)
        }

        # 항목별 강조 문턱값: 수치 입력 + 슬라이더 (배경 투명도 스타일). '기본' = 항목 기본값/전역 설정 복귀
        $curPct = [int](Get-AnomPctFor ([string]$it.K))
        $tx2 = New-Object Windows.Controls.TextBox
        $tx2.Width = 27
        $tx2.FontSize = 11
        $tx2.MaxLength = 2
        $tx2.VerticalContentAlignment = 'Center'
        $tx2.HorizontalContentAlignment = 'Center'
        $tx2.VerticalAlignment = 'Center'
        $tx2.Margin = New-Object Windows.Thickness 6, 0, 0, 0
        $tx2.Text = [string]$curPct
        $pl2 = New-Object Windows.Controls.TextBlock
        $pl2.Text = '%'
        $pl2.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $pl2.FontSize = 11
        $pl2.Foreground = $fg
        $pl2.VerticalAlignment = 'Center'
        $pl2.Margin = New-Object Windows.Thickness 1, 0, 3, 0
        $sl2 = New-Object Windows.Controls.Slider
        $sl2.Minimum = 1
        $sl2.Maximum = 80
        $sl2.Width = 66
        $sl2.SmallChange = 1
        $sl2.IsMoveToPointEnabled = $true
        $sl2.VerticalAlignment = 'Center'
        $sl2.Value = $curPct
        $df2 = New-Object Windows.Controls.TextBlock
        $df2.Text = '기본'
        $df2.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $df2.FontSize = 10.5
        $df2.FontWeight = [Windows.FontWeights]::Bold
        $df2.Foreground = $fg
        $df2.Opacity = 0.7
        $df2.TextDecorations = [Windows.TextDecorations]::Underline
        $df2.Cursor = [Windows.Input.Cursors]::Hand
        $df2.VerticalAlignment = 'Center'
        $df2.Margin = New-Object Windows.Thickness 4, 0, 0, 0
        $df2.ToolTip = '항목 기본값(평균순위 5%) 또는 전역 ± 설정으로 복귀'
        [Windows.Controls.ToolTipService]::SetInitialShowDelay($df2, 0)
        $ctx2 = @{ K = [string]$it.K; Tx = $tx2; Sl = $sl2 }
        $tx2.Tag = $ctx2
        $sl2.Tag = $ctx2
        $df2.Tag = $ctx2
        $sl2.Add_ValueChanged({
            if ($script:SyncingUI) { return }
            $c2 = $args[0].Tag
            $v = [int][math]::Round($args[1].NewValue)
            Set-AnomPctFor ([string]$c2.K) $v
            $script:SyncingUI = $true
            $c2.Tx.Text = [string]$v
            $script:SyncingUI = $false
        })
        $sl2.Add_LostMouseCapture({ Save-Pos; Refresh-Display })
        $sl2.Add_LostFocus({ Save-Pos; Refresh-Display })
        $tx2.Add_KeyDown({
            if ($args[1].Key -ne 'Return') { return }
            $c2 = $args[0].Tag
            $v = 0
            if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v) -and $v -ge 1 -and $v -le 80) {
                Set-AnomPctFor ([string]$c2.K) $v
                Save-Pos
                $script:SyncingUI = $true
                $c2.Sl.Value = $v
                $script:SyncingUI = $false
                Refresh-Display
            }
        })
        # 포커스 이탈 시에도 반영 (Enter 없이 다른 곳을 눌러도 입력이 사라지지 않게) - 값이 바뀔 때만
        $tx2.Add_LostFocus({
            $c2 = $args[0].Tag
            $v = 0
            if ([int]::TryParse(([string]$args[0].Text).Trim(), [ref]$v) -and $v -ge 1 -and $v -le 80 -and $v -ne [int](Get-AnomPctFor ([string]$c2.K))) {
                Set-AnomPctFor ([string]$c2.K) $v
                Save-Pos
                $script:SyncingUI = $true
                $c2.Sl.Value = $v
                $script:SyncingUI = $false
                Refresh-Display
            }
        })
        $df2.Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $c2 = $args[0].Tag
            Set-AnomPctFor ([string]$c2.K) 0
            Save-Pos
            $v = [int](Get-AnomPctFor ([string]$c2.K))
            $script:SyncingUI = $true
            $c2.Tx.Text = [string]$v
            $c2.Sl.Value = $v
            $script:SyncingUI = $false
            Refresh-Display
        })
        $null = $row.Children.Add($tx2)
        $null = $row.Children.Add($pl2)
        $null = $row.Children.Add($sl2)
        $null = $row.Children.Add($df2)
        $null = $Box.AdvPanel.Children.Add($row)
    }

    # 항목별 색 초기화
    $rst = New-Object Windows.Controls.TextBlock
    $rst.Text = '항목별 색 초기화'
    $rst.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $rst.FontSize = 11.5
    $rst.FontWeight = [Windows.FontWeights]::Bold
    $rst.Foreground = $fg
    $rst.Opacity = 0.75
    $rst.Margin = New-Object Windows.Thickness 0, 4, 0, 0
    $rst.Cursor = [Windows.Input.Cursors]::Hand
    $rst.Tag = @{ O = $isOpp; B = $Box }
    $rst.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $t = $args[0].Tag
        if ([bool]$t.O) { $script:Settings.AnomCOpp = '' } else { $script:Settings.AnomCMe = '' }
        Save-Pos
        Build-AdvPanel $t.B
        Refresh-Display
    })
    $null = $Box.AdvPanel.Children.Add($rst)

    # 항목별 문턱값 초기화 (전 항목을 실측 기본값으로 - 문턱값은 내/상대 공용)
    $rstP = New-Object Windows.Controls.TextBlock
    $rstP.Text = '항목별 문턱값 초기화'
    $rstP.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $rstP.FontSize = 11.5
    $rstP.FontWeight = [Windows.FontWeights]::Bold
    $rstP.Foreground = $fg
    $rstP.Opacity = 0.75
    $rstP.Margin = New-Object Windows.Thickness 0, 2, 0, 0
    $rstP.Cursor = [Windows.Input.Cursors]::Hand
    $rstP.ToolTip = '모든 항목의 문턱값을 기본값(항목별 실측 기준)으로 되돌립니다'
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($rstP, 0)
    $rstP.Tag = @{ B = $Box }
    $rstP.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $script:Settings.AnomPctItems = ''
        Save-Pos
        Build-AdvPanel $args[0].Tag.B
        Refresh-Display
    })
    $null = $Box.AdvPanel.Children.Add($rstP)
}

# 설정 변경 즉시 화면에 반영 (캐시된 데이터로 다시 그림)
function Refresh-Display {
    if ($script:LastData) { Set-StatWindow $script:MyBox $script:LastData }
    foreach ($k in @($script:OppWindows.Keys)) {
        if ($script:OppCache.ContainsKey($k)) { Set-StatWindow $script:OppWindows[$k] $script:OppCache[$k] }
    }
}

function Set-StatWindow {
    param($Box, $Data)
    $isOppBox = [bool]$Data.IsOpp
    # 테마별 색상표
    if ($script:Theme -ne 'light') {
        $down = '#FFFF7B7B'; $up = '#FF7BE38B'; $zero = '#FFB8C0CE'
        $gold = '#FFFFD666'; $blue = '#FF7FB3FF'
        $cGreen = '#FF7BE38B'; $cOrange = '#FFFFC966'; $cRed = '#FFFF7B7B'
    } else {
        $down = '#FFD32F2F'; $up = '#FF2E7D32'; $zero = '#FF788296'
        $gold = '#FFC9A227'; $blue = '#FF3D74C9'
        $cGreen = '#FF2E7D32'; $cOrange = '#FFB8860B'; $cRed = '#FFC62828'
    }

    # 이름 줄: 닉네임 + 안정단위 (상대는 강함에 따라 색상)
    $Box.TbName.Inlines.Clear()
    $nameRun = New-Object Windows.Documents.Run
    $nameRun.Text = $Data.Name
    if ($null -ne $Data.NameColorVal -and (Test-DispOn 'NameColor' $isOppBox)) {
        $tier = [string]$Data.StableTier
        if (-not $tier) {
            # 구버전 캐시 폴백: 값 기준
            if ($Data.NameColorVal -gt 4) { $tier = 'seong' } elseif ($Data.NameColorVal -gt 1) { $tier = 'ho' } else { $tier = 'geol' }
        }
        $nameRun.Foreground = New-Brush (Get-StableTierColor $tier)
    } elseif (Test-DispOn 'NameColor' $isOppBox) {
        # 안정단 계산 전(1차 부분 데이터 등): 랭크 등급 색을 임시로 사용 - 계산되면 안정단 색으로 교체됨
        $rTier0 = Get-RankTier ([int]$Data.RankMajor)
        if ($rTier0) { $nameRun.Foreground = New-Brush (Get-StableTierColor $rTier0) }
    }
    $Box.TbName.Inlines.Add($nameRun)
    $sfxText = ''
    if ($Data.NameSuffix -and $script:Settings.Stable -and (Test-DispOn 'Stable' $isOppBox)) { $sfxText += [string]$Data.NameSuffix }
    if ($Data.Badges -and $script:Settings.BadgeOn -and (Test-DispOn 'Badge' $isOppBox)) { $sfxText += '  ' + [string]$Data.Badges }
    $sfx2Text = ''
    if ($Data.NameSuffix2 -and $script:Settings.Stable -and (Test-DispOn 'Stable' $isOppBox)) { $sfx2Text = [string]$Data.NameSuffix2 }
    if ($sfxText) {
        $sfx = New-Object Windows.Documents.Run
        $sfx.Text = $sfxText
        $sfx.FontSize = [math]::Max(10, $Box.TbName.FontSize - 4.5)
        if ($null -ne $Data.NameColorVal -and (Test-DispOn 'NameColor' $isOppBox)) {
            # 각 줄은 자기 구간 색 (금 기준 작호=주황, 옥 기준 작걸=노랑처럼 따로) - 없으면 닉네임 색
            $st1 = ''
            try { $st1 = [string]$Data.SuffixTier } catch {}
            if ($st1) { $sfx.Foreground = New-Brush (Get-StableTierColor $st1) }
            else { $sfx.Foreground = $nameRun.Foreground }
        }
        $Box.TbName.Inlines.Add($sfx)
        if ($sfx2Text) {
            # 병행(금+옥) 두 번째 기준은 다음 줄에
            $Box.TbName.Inlines.Add((New-Object Windows.Documents.LineBreak))
            $sfx2 = New-Object Windows.Documents.Run
            $sfx2.Text = $sfx2Text
            $sfx2.FontSize = $sfx.FontSize
            $sfx2.FontWeight = $sfx.FontWeight
            $sfx2.Foreground = $sfx.Foreground
            if ($null -ne $Data.NameColorVal -and (Test-DispOn 'NameColor' $isOppBox)) {
                $st2 = ''
                try { $st2 = [string]$Data.SuffixTier2 } catch {}
                if ($st2) { $sfx2.Foreground = New-Brush (Get-StableTierColor $st2) }
            }
            $Box.TbName.Inlines.Add($sfx2)
        }
    }

    # 표시 항목 토글
    if (Test-DispOn 'Rank' $isOppBox) { $Box.TbRank.Visibility = 'Visible' } else { $Box.TbRank.Visibility = 'Collapsed' }
    if (Test-DispOn 'Game' $isOppBox) { $Box.TbGame.Visibility = 'Visible' } else { $Box.TbGame.Visibility = 'Collapsed' }

    $Box.TbRank.Inlines.Clear()
    # 랭크 이름(작걸3 등)은 등급 구간 색으로 (구간 색 커스텀 반영)
    $rlText = [string]$Data.RankLine
    $rTier = Get-RankTier ([int]$Data.RankMajor)
    if ($rTier -and (Test-DispOn 'NameColor' $isOppBox) -and $rlText -match '^랭크 (\S+)(.*)$') {
        $Box.TbRank.Inlines.Add('랭크 ')
        $rnm = New-Object Windows.Documents.Run
        $rnm.Text = [string]$Matches[1]
        $rnm.Foreground = New-Brush (Get-StableTierColor $rTier)
        $Box.TbRank.Inlines.Add($rnm)
        $Box.TbRank.Inlines.Add([string]$Matches[2])
    } else {
        $Box.TbRank.Inlines.Add($rlText)
    }
    if (-not $Data.NoDiff) {
        $run = New-Object Windows.Documents.Run
        if ($Data.Diff -lt 0) {
            $run.Text = ('▼{0}' -f (-$Data.Diff))
            $run.Foreground = New-Brush $down
        } elseif ($Data.Diff -gt 0) {
            $run.Text = ('▲{0}' -f $Data.Diff)
            $run.Foreground = New-Brush $up
        } else {
            $run.Text = '±0'
            $run.Foreground = New-Brush $zero
        }
        $Box.TbRank.Inlines.Add($run)
    }

    if ($Data.GoalLine -and (Test-DispOn 'Goal' $isOppBox)) {
        $Box.TbGoal.Text = $Data.GoalLine
        $Box.TbGoal.Visibility = 'Visible'
    } else {
        $Box.TbGoal.Visibility = 'Collapsed'
    }

    # 전적 줄: 오늘 순위 나열은 등수별 색상 + 스트릭 (상대는 일반 텍스트)
    $Box.TbGame.Inlines.Clear()
    if ($Data.Seq -and @($Data.Seq).Count -gt 0) {
        $Box.TbGame.Inlines.Add('전적 ')
        $seq = @($Data.Seq)
        for ($i = 0; $i -lt $seq.Count; $i++) {
            if ($i -gt 0 -and $i % 5 -eq 0) { $Box.TbGame.Inlines.Add(' ') }
            $dr = New-Object Windows.Documents.Run
            $dr.Text = [string]$seq[$i]
            if (Test-DispOn 'SeqColor' $isOppBox) {
                switch ($seq[$i]) {
                    1 { $dr.Foreground = New-Brush $gold }
                    2 { $dr.Foreground = New-Brush $blue }
                    4 { $dr.Foreground = New-Brush $down }
                }
            }
            $Box.TbGame.Inlines.Add($dr)
        }
        if ($Data.Streak -and (Test-DispOn 'Streak' $isOppBox)) {
            $sr = New-Object Windows.Documents.Run
            $sr.Text = '  ' + $Data.Streak
            $sr.FontSize = [math]::Max(10, $Box.TbGame.FontSize - 2)
            if ($Data.Streak -like '💀*') { $sr.Foreground = New-Brush $down }
            else { $sr.Foreground = New-Brush $gold }
            $Box.TbGame.Inlines.Add($sr)
        }
    } else {
        $Box.TbGame.Inlines.Add($Data.GameLine)
    }

    # 통계 항목 렌더링 (특이 수치 심박 강조 포함)
    # 고정 줄 배정 없이 전 항목을 한 흐름으로 - 박스 폭에 맞춰 항목 단위로 자연 개행.
    # 항목 내부 공백은 NBSP라 라벨-값이 줄에 걸쳐 찢어지지 않음
    $sParts = @()
    if ($Data.StatParts) { $sParts = @($Data.StatParts | ForEach-Object { $_ }) }
    $rankMajor = 3
    if ($Data.RankMajor) { $rankMajor = [int]$Data.RankMajor }
    # 그룹(구 줄 단위) 토글 + 개별 토글 필터
    $groupKeys = @{ 1 = @('hr', 'dl', 'ryu'); 2 = @('ri', 'fu', 'dama'); 3 = @('dp', 'dpl', 'tobi'); 4 = @('gs', 'gs2', 'sente'); 5 = @('wt', 'avgpl', 'rentai', 'lasu', 'ppg', 'statsrc') }
    foreach ($gn in 1, 2, 3, 4, 5) {
        if (-not (Test-DispOn "Stat$gn" $isOppBox)) {
            $gk = $groupKeys[$gn]
            $sParts = @($sParts | Where-Object { $gk -notcontains [string]$_.K })
        }
    }
    foreach ($tg in @(@('Tobi', 'tobi'), @('Wt', 'wt'), @('AvgPl', 'avgpl'), @('Rentai', 'rentai'), @('Lasu', 'lasu'), @('Ppg', 'ppg'), @('StatSrc', 'statsrc'))) {
        if (-not (Test-DispOn $tg[0] $isOppBox)) { $sParts = @($sParts | Where-Object { [string]$_.K -ne $tg[1] }) }
    }
    # 표시 순서는 기존 줄 순서 유지 - PS5.1 Sort-Object는 동순위 순서를 보장하지 않으므로 원래 순서를 보조 키로.
    # 항목에 직접 쓰지 않고 래퍼로 정렬: 상대 박스의 StatParts는 JSON에서 온 PSCustomObject라 새 속성 대입이 예외를 냄
    $ordS = New-Object Collections.ArrayList
    $ixS = 0
    foreach ($pp in $sParts) { $null = $ordS.Add(@{ P = $pp; L = [int]$pp.L; Ix = $ixS }); $ixS++ }
    $sParts = @($ordS | Sort-Object @{ Expression = { [int]$_.L } }, @{ Expression = { [int]$_.Ix } } | ForEach-Object { $_.P })
    foreach ($tbOld in @($Box.TbStat2, $Box.TbStat3, $Box.TbStat4, $Box.TbStat5)) {
        if ($tbOld) { $tbOld.Inlines.Clear(); $tbOld.Visibility = 'Collapsed' }
    }
    $tb = $Box.TbStat
    $tb.Inlines.Clear()
    if ($sParts.Count -eq 0) {
        $tb.Visibility = 'Collapsed'
    } else {
        $tb.Visibility = 'Visible'
        $baseColor = ([Windows.Media.SolidColorBrush]$tb.Foreground).Color
        $first = $true
        foreach ($pp in $sParts) {
            if (-not $first) { $tb.Inlines.Add('  ') }
            $first = $false
            # CJK는 글자 사이 어디서든 개행될 수 있어 NBSP로는 못 막음 -
            # 항목을 내부 개행이 없는 TextBlock 컨테이너로 감싸 통째로만 줄을 넘김
            $it = New-Object Windows.Controls.TextBlock
            $it.Text = [string]$pp.T
            $hot = Get-StatHot ([string]$pp.K) ([double]$pp.V) $rankMajor $isOppBox
            if ($hot -gt 0) {
                $accHex = Get-AnomColor ([string]$pp.K) $hot $isOppBox
                $accColor = [Windows.Media.ColorConverter]::ConvertFromString($accHex)
                if ([string]$script:Settings.AnomMode -eq 'static') {
                    $it.Foreground = New-Object Windows.Media.SolidColorBrush $accColor
                } else {
                    $br = New-Object Windows.Media.SolidColorBrush $baseColor
                    $it.Foreground = $br
                    $ca = New-Object Windows.Media.Animation.ColorAnimation
                    $ca.From = $baseColor
                    $ca.To = $accColor
                    $ca.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(850))
                    $ca.AutoReverse = $true
                    $ca.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
                    $br.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
                }
            }
            $cont = New-Object Windows.Documents.InlineUIContainer $it
            $cont.BaselineAlignment = 'TextBottom'
            $tb.Inlines.Add($cont)
        }
    }
    # 통계 개행 폭·최소 폭·줄 간격 (박스 비율 반영 - 내용이 바뀔 때마다 기준 폭 재계산)
    Apply-BoxRatio $Box
    if (Test-DispOn 'Spark' $isOppBox) {
        Update-Spark $Box $Data
    } elseif ($Box.SparkCanvas) {
        $Box.SparkCanvas.Visibility = 'Collapsed'
    }
}

# 오늘 누적 수지 스파크라인 (호버 툴팁 + 최고/최저 표기)
function Update-Spark {
    param($Box, $Data)
    $cv = $Box.SparkCanvas
    if (-not $cv) { return }
    $pts = @()
    if ($Data -and $Data.Pts) { $pts = @($Data.Pts) }
    $seq = @(); if ($Data.Seq) { $seq = @($Data.Seq) }
    $raw = @(); if ($Data.RawPts) { $raw = @($Data.RawPts) }
    $lvls = @(); if ($Data.Lvls) { $lvls = @($Data.Lvls) }
    $meta = @()
    for ($i = 0; $i -lt $pts.Count; $i++) {
        if ($null -eq $pts[$i]) { continue }
        $lbl = '시작'
        $gLbl = '시작'
        $rawP = $Data.StartPt
        $rawL = 0
        if ($null -ne $Data.StartLvl) { $rawL = [int]$Data.StartLvl }
        if ($i -ge 1) {
            $gLbl = ('{0}국째' -f $i)
            if (($i - 1) -lt $seq.Count) { $lbl = ('{0}국째 · {1}위' -f $i, $seq[$i - 1]) }
            $rawP = $null; $rawL = 0
            if (($i - 1) -lt $raw.Count) { $rawP = $raw[$i - 1] }
            if (($i - 1) -lt $lvls.Count -and $null -ne $lvls[$i - 1]) { $rawL = [int]$lvls[$i - 1] }
        }
        $meta += @{ V = [int]$pts[$i]; L = $lbl; G = $gLbl; P = $rawP; Lv = $rawL }
    }
    if ($meta.Count -lt 2) { $cv.Visibility = 'Collapsed'; return }
    $cv.Children.Clear()
    $w = 300.0; $h = 30.0
    $cv.Width = $w; $cv.Height = $h + 38
    $vals = @($meta | ForEach-Object { $_.V })
    $min = ($vals | Measure-Object -Minimum).Minimum
    $max = ($vals | Measure-Object -Maximum).Maximum
    if ($max -eq $min) { $max = $min + 1 }
    # 테마별 색
    if ($script:Theme -ne 'light') {
        $upHex = '#FF7BE38B'; $dnHex = '#FFFF7B7B'; $axHex = '#66FFFFFF'
    } else {
        $upHex = '#FF2E7D32'; $dnHex = '#FFC62828'; $axHex = '#5516213E'
    }
    $lineColor = $upHex
    if ([int]$vals[$vals.Count - 1] -lt 0) { $lineColor = $dnHex }
    # 0 기준선
    if ($min -lt 0 -and $max -gt 0) {
        $zy = [double](2 + ($h - 4) * (1 - ((0 - $min) / ($max - $min))))
        $zl = New-Object Windows.Shapes.Rectangle
        $zl.Width = $w; $zl.Height = 1
        $zl.Fill = New-Brush $axHex
        [Windows.Controls.Canvas]::SetLeft($zl, 0)
        [Windows.Controls.Canvas]::SetTop($zl, $zy)
        $null = $cv.Children.Add($zl)
    }
    $pl = New-Object Windows.Shapes.Polyline
    $pl.Stroke = New-Brush $lineColor
    $pl.StrokeThickness = 2
    $pc = New-Object Windows.Media.PointCollection
    for ($i = 0; $i -lt $meta.Count; $i++) {
        $x = [double]($i * ($w - 8) / ($meta.Count - 1)) + 4
        $y = [double](2 + ($h - 4) * (1 - (($meta[$i].V - $min) / ($max - $min))))
        $pc.Add((New-Object Windows.Point $x, $y))
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 5; $dot.Height = 5
        $dot.Fill = New-Brush $lineColor
        [Windows.Controls.Canvas]::SetLeft($dot, $x - 2.5)
        [Windows.Controls.Canvas]::SetTop($dot, $y - 2.5)
        $null = $cv.Children.Add($dot)
    }
    $pl.Points = $pc
    $null = $cv.Children.Add($pl)
    # 호버 툴팁
    $slotW = ($w - 8) / ($meta.Count - 1)
    for ($i = 0; $i -lt $meta.Count; $i++) {
        $x = [double]($i * $slotW) + 4
        $cvVal = [int]$meta[$i].V
        $cvArrow = '±0'
        if ($cvVal -gt 0) { $cvArrow = "▲$cvVal" } elseif ($cvVal -lt 0) { $cvArrow = "▼$(-$cvVal)" }
        $tip = ('{0} · 누적 {1}pt' -f $meta[$i].L, $cvArrow)
        if ($null -ne $meta[$i].P -and [int]$meta[$i].Lv -gt 0) {
            $tip += (' · 시점 {0} {1}pt' -f (Get-LvlName ([int]$meta[$i].Lv)), [int]$meta[$i].P)
        }
        New-HitRect $cv ($x - $slotW / 2) 0 $slotW ($h + 4) $tip
    }
    # 오늘 최고점/최저점 (실제 단위·점수와 시점)
    $cands = @($meta | Where-Object { $null -ne $_.P -and [int]$_.Lv -gt 0 })
    if ($cands.Count -gt 0) {
        $hi = $null; $lo = $null
        foreach ($c in $cands) {
            $key = [long]$c.Lv * 100000 + [int]$c.P
            if ($null -eq $hi -or $key -gt ([long]$hi.Lv * 100000 + [int]$hi.P)) { $hi = $c }
            if ($null -eq $lo -or $key -lt ([long]$lo.Lv * 100000 + [int]$lo.P)) { $lo = $c }
        }
        $mkRow = {
            param($LabelText, $ValueText, $ValueHex, $Y)
            $tb = New-Object Windows.Controls.TextBlock
            $tb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
            $tb.FontSize = 11
            $tb.FontWeight = [Windows.FontWeights]::Bold
            $r1 = New-Object Windows.Documents.Run
            $r1.Text = $LabelText
            $r1.Foreground = $Box.TbGame.Foreground
            $r2 = New-Object Windows.Documents.Run
            $r2.Text = $ValueText
            $r2.Foreground = New-Brush $ValueHex
            $null = $tb.Inlines.Add($r1)
            $null = $tb.Inlines.Add($r2)
            [Windows.Controls.Canvas]::SetLeft($tb, 0)
            [Windows.Controls.Canvas]::SetTop($tb, $Y)
            $null = $cv.Children.Add($tb)
        }
        & $mkRow '최고 ' ('{0} {1}pt ({2})' -f (Get-LvlName ([int]$hi.Lv)), [int]$hi.P, $hi.G) $upHex ($h + 5)
        & $mkRow '최저 ' ('{0} {1}pt ({2})' -f (Get-LvlName ([int]$lo.Lv)), [int]$lo.P, $lo.G) $dnHex ($h + 21)
    }
    $cv.Visibility = 'Visible'
}

# 새 대국 반영 토스트 (Fx: 'up' 글리터 상승 / 'down' 하락 화살표, Magnitude: pt 증감 크기 → 파티클 수)
function Show-Toast {
    param([string]$Text, [bool]$Positive, [string]$Fx = '', [int]$Magnitude = 0)
    try {
        $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Grid>
    <Border x:Name="B" CornerRadius="10" Background="#D8202433" Padding="16,9" Margin="22,30,22,30">
      <TextBlock x:Name="T" FontFamily="Malgun Gothic" FontSize="17" FontWeight="ExtraBold"/>
    </Border>
    <Canvas x:Name="P" IsHitTestVisible="False"/>
  </Grid>
</Window>
'@
        $tw = [Windows.Markup.XamlReader]::Parse($x)
        $tb = $tw.FindName('T'); $bd = $tw.FindName('B'); $cv = $tw.FindName('P')
        $tb.Text = $Text
        if ($Positive) { $tb.Foreground = New-Brush '#FF7BE38B' } else { $tb.Foreground = New-Brush '#FFFF7B7B' }
        # 파티클 여백(22,30)만큼 창을 넓혔으므로 Border가 기존 위치에 오도록 보정
        $tw.Left = $script:MyBox.Win.Left - 22
        $tw.Top = $script:MyBox.Win.Top - 52 - 30
        if ($tw.Top -lt 0) { $tw.Top = $script:MyBox.Win.Top + 150 - 30 }
        $tw.Opacity = 0
        $tw.Show()
        # 페이드 인 → 유지 → 페이드 아웃
        $mkKf = { param($v, $ms) New-Object Windows.Media.Animation.LinearDoubleKeyFrame([double]$v, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($ms))) }
        $fade = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
        foreach ($k in @(@(0,0), @(1,250), @(1,3450), @(0,3900))) { [void]$fade.KeyFrames.Add((& $mkKf $k[0] $k[1])) }
        $tw.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        if ($Fx -eq 'up' -or $Fx -eq 'down') {
            $up = ($Fx -eq 'up')
            # 증감 색 글로우
            $glow = New-Object Windows.Media.Effects.DropShadowEffect
            $glow.ShadowDepth = 0; $glow.BlurRadius = 16; $glow.Opacity = 0.7
            $glow.Color = [Windows.Media.ColorConverter]::ConvertFromString($(if ($up) { '#FF7BE38B' } else { '#FFFF6B6B' }))
            $bd.Effect = $glow
            # 상승은 아래→위, 하락은 위→아래로 살짝 미끄러지며 등장
            $tt = New-Object Windows.Media.TranslateTransform
            $bd.RenderTransform = $tt
            $sl = New-Object Windows.Media.Animation.DoubleAnimation
            $sl.From = $(if ($up) { 14 } else { -14 }); $sl.To = 0
            $sl.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(400))
            $eo = New-Object Windows.Media.Animation.CubicEase; $eo.EasingMode = 'EaseOut'
            $sl.EasingFunction = $eo
            $tt.BeginAnimation([Windows.Media.TranslateTransform]::YProperty, $sl)
            # 파티클: 상승=피어오르는 글리터, 하락=떨어지는 화살표. 증감 폭이 클수록 개수 증가
            $tw.UpdateLayout()
            $W = [Math]::Max($tw.ActualWidth, 120); $H = [Math]::Max($tw.ActualHeight, 90)
            $rnd = New-Object System.Random
            if ($up) { $chars = '✦','✧','★','☆'; $cols = '#FFFFE082','#FF7BE38B','#FFFFF6C8','#FFB9F6CA' }
            else     { $chars = '▼','▾';          $cols = '#FFFF7B7B','#FFFF9E9E','#FFD95F5F' }
            $n = 14 + [Math]::Min(10, [int]([Math]::Abs($Magnitude) / 8))
            for ($i = 0; $i -lt $n; $i++) {
                $p = New-Object Windows.Controls.TextBlock
                $p.Text = [string]$chars[$rnd.Next($chars.Count)]
                $p.FontSize = 9 + $rnd.Next(8)
                $p.Foreground = New-Brush ([string]$cols[$rnd.Next($cols.Count)])
                $p.Opacity = 0
                $x0 = 4 + $rnd.NextDouble() * ($W - 18)
                if ($up) { $y0 = $H - 34 - $rnd.Next(14); $dy = -(34 + $rnd.Next(30)) }
                else     { $y0 = 24 + $rnd.Next(14);      $dy = 30 + $rnd.Next(28) }
                [Windows.Controls.Canvas]::SetLeft($p, $x0)
                [Windows.Controls.Canvas]::SetTop($p, $y0)
                [void]$cv.Children.Add($p)
                $bt = [TimeSpan]::FromMilliseconds($rnd.Next(1400))
                $durMs = 800 + $rnd.Next(700)
                $ay = New-Object Windows.Media.Animation.DoubleAnimation
                $ay.From = $y0; $ay.To = $y0 + $dy
                $ay.BeginTime = $bt; $ay.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($durMs))
                $ez = New-Object Windows.Media.Animation.CubicEase; $ez.EasingMode = $(if ($up) { 'EaseOut' } else { 'EaseIn' })
                $ay.EasingFunction = $ez
                $p.BeginAnimation([Windows.Controls.Canvas]::TopProperty, $ay)
                $ax = New-Object Windows.Media.Animation.DoubleAnimation
                $ax.From = $x0; $ax.To = $x0 + ($rnd.NextDouble() * 20 - 10)
                $ax.BeginTime = $bt; $ax.Duration = $ay.Duration
                $p.BeginAnimation([Windows.Controls.Canvas]::LeftProperty, $ax)
                $ao = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
                $ao.BeginTime = $bt
                foreach ($k in @(@(0,0), @(1,[int]($durMs*0.2)), @(0.9,[int]($durMs*0.6)), @(0,$durMs))) { [void]$ao.KeyFrames.Add((& $mkKf $k[0] $k[1])) }
                $p.BeginAnimation([Windows.UIElement]::OpacityProperty, $ao)
            }
        }
        $t = New-Object Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds(4)
        $t.Add_Tick({ $args[0].Stop(); $tw.Close() }.GetNewClosure())
        $t.Start()
    } catch { if ($env:MJS_TOAST_DEBUG) { Write-Host "Toast error: $_" } }
}

# 스캔/갱신 작업이 UI를 점유 중이면 토스트를 미뤘다가 한가해진 시점(ApplicationIdle)에 띄움
# - 바쁜 와중에 바로 띄우면 파티클 애니메이션이 그려지기도 전에 시계상으로 끝나버림
function Show-DeferredToast {
    param([string]$Text, [bool]$Positive, [string]$Fx = '', [int]$Magnitude = 0)
    try {
        $null = [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::ApplicationIdle,
            [action] { Show-Toast $Text $Positive $Fx $Magnitude }.GetNewClosure())
    } catch { Show-Toast $Text $Positive $Fx $Magnitude }
}

# ---- 리포트 카드 (일/주/월/연 탭 + 비동기 로딩) ----

function Get-PeriodAnchor {
    param([string]$Mode, [DateTime]$D)
    switch ($Mode) {
        'week' { return $D.Date.AddDays(-(([int]$D.DayOfWeek + 6) % 7)) }
        'season' {
            $qm = ((([int]$D.Month - 1) - (([int]$D.Month - 1) % 3)) + 1)
            return (New-Object DateTime $D.Year, $qm, 1)
        }
        'month' { return (New-Object DateTime $D.Year, $D.Month, 1) }
        'year' { return (New-Object DateTime $D.Year, 1, 1) }
        'all' { return (New-Object DateTime 2010, 1, 1) }
        'range' { return $D.Date }
        default { return $D.Date }
    }
}

# 기간의 [시작, 끝) 날짜 — 상세 지표 조회용. 끝은 내일을 넘지 않게 클램프
function Get-PeriodRange {
    param([string]$Mode, [DateTime]$Anchor)
    $s = Get-PeriodAnchor $Mode $Anchor
    switch ($Mode) {
        'week' { $e = $s.AddDays(7) }
        'season' { $e = $s.AddMonths(3) }
        'month' { $e = $s.AddMonths(1) }
        'year' { $e = $s.AddYears(1) }
        'all' { $e = [DateTime]::Today.AddDays(1) }
        'range' {
            $e = $s.AddDays(1)
            if ($script:ReportRangeEnd -is [DateTime]) { $e = ([DateTime]$script:ReportRangeEnd).Date.AddDays(1) }
            if ($e -le $s) { $e = $s.AddDays(1) }
        }
        default { $e = $s.AddDays(1) }
    }
    $cap = [DateTime]::Today.AddDays(1)
    if ($e -gt $cap) { $e = $cap }
    return @{ S = $s; E = $e }
}

# 상세 지표 캐시/요청 키: "시작|끝"
function Get-DetailKey {
    param([string]$Mode, [DateTime]$Anchor)
    $r = Get-PeriodRange $Mode $Anchor
    return ('{0:yyyy-MM-dd}|{1:yyyy-MM-dd}' -f $r.S, $r.E)
}

$script:ReportXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Border x:Name="Card" CornerRadius="16" Background="#F51C2233" Padding="26,20">
    <StackPanel Width="360">
      <DockPanel>
        <TextBlock x:Name="RcClose" Text="✕" DockPanel.Dock="Right" Foreground="#FF8A93A6" FontFamily="Malgun Gothic" FontSize="14" FontWeight="Bold" Cursor="Hand" Padding="8,0,0,0"/>
        <TextBlock x:Name="RcNext" Text="▶" DockPanel.Dock="Right" Foreground="#FF8A93A6" FontFamily="Malgun Gothic" FontSize="13" FontWeight="Bold" Cursor="Hand" Padding="8,1,0,0"/>
        <TextBlock x:Name="RcPrev" Text="◀" DockPanel.Dock="Right" Foreground="#FF8A93A6" FontFamily="Malgun Gothic" FontSize="13" FontWeight="Bold" Cursor="Hand" Padding="8,1,0,0"/>
        <TextBlock x:Name="RcCal" Text="📅" DockPanel.Dock="Right" Foreground="#FF8A93A6" FontFamily="Malgun Gothic" FontSize="13" Cursor="Hand" Padding="8,1,0,0" ToolTip="달력에서 기간 선택" ToolTipService.InitialShowDelay="0"/>
        <TextBlock x:Name="RcTitle" FontFamily="Malgun Gothic" FontSize="16" FontWeight="ExtraBold" Foreground="#FFF2F4F8"/>
      </DockPanel>
      <Popup x:Name="RcCalPop" StaysOpen="True" AllowsTransparency="True" Placement="Bottom" PlacementTarget="{Binding ElementName=RcCal}">
        <Border Background="#FF1C2233" CornerRadius="8" Padding="8" BorderBrush="#FF2E4266" BorderThickness="1">
          <StackPanel>
            <Calendar x:Name="RcCalendar"/>
            <DockPanel x:Name="RcCalApplyRow" Visibility="Collapsed" Margin="2,6,2,0">
              <TextBlock x:Name="RcCalApply" Text="적용" DockPanel.Dock="Right" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="ExtraBold" Foreground="#FF7FB3FF" Cursor="Hand" Padding="10,0,2,0"/>
              <TextBlock x:Name="RcCalHint" Text="시작일 클릭 후 종료일 클릭" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FF8A93A6"/>
            </DockPanel>
          </StackPanel>
        </Border>
      </Popup>
      <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
        <TextBlock x:Name="RcTabDay" Text="일간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabWeek" Text="주간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabMonth" Text="월간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabSeason" Text="시즌" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabYear" Text="연간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabAll" Text="전체" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabRange" Text="기간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand"/>
      </StackPanel>
      <TextBlock x:Name="RcSeq" FontFamily="Malgun Gothic" FontSize="22" FontWeight="ExtraBold" Margin="0,12,0,0" Foreground="#FFF2F4F8"/>
      <TextBlock x:Name="RcStats" FontFamily="Malgun Gothic" FontSize="14" FontWeight="Bold" Foreground="#FFD9DCE1" Margin="0,8,0,0"/>
      <TextBlock x:Name="RcStats2" FontFamily="Malgun Gothic" FontSize="14" FontWeight="Bold" Foreground="#FFD9DCE1" Margin="0,2,0,0"/>
      <StackPanel x:Name="RcDonutRow" Orientation="Horizontal" Margin="0,14,0,0" Visibility="Collapsed">
        <Grid Width="104" Height="104">
          <Canvas x:Name="RcDonut" Width="104" Height="104"/>
          <TextBlock x:Name="RcDonutCenter" HorizontalAlignment="Center" VerticalAlignment="Center" FontFamily="Malgun Gothic" FontWeight="ExtraBold" FontSize="15" Foreground="#FFF2F4F8"/>
        </Grid>
        <StackPanel x:Name="RcLegend" Margin="18,10,0,0"/>
      </StackPanel>
      <Canvas x:Name="RcBars" Height="100" Margin="0,12,0,0" Visibility="Collapsed" ClipToBounds="True"/>
      <TextBlock x:Name="RcCumL" Text="누적 수지" FontFamily="Malgun Gothic" FontSize="11" FontWeight="Bold" Foreground="#FF8A93A6" Margin="0,10,0,0" Visibility="Collapsed"/>
      <Canvas x:Name="RcCum" Height="84" Margin="0,4,0,0" Visibility="Collapsed" ClipToBounds="True"/>
      <Canvas x:Name="RcCanvas" Height="64" Margin="0,12,0,0" ClipToBounds="True" Visibility="Collapsed"/>
      <StackPanel x:Name="RcInfoGrid" Margin="0,12,0,0"/>
      <TextBlock x:Name="RcDetailBtn" Text="상세 지표 보기 +" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF7BA7E3" Margin="0,10,0,0" Cursor="Hand" Visibility="Collapsed"/>
      <StackPanel x:Name="RcDetailGrid" Margin="0,4,0,0"/>
      <TextBlock x:Name="RcComment" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FFFFD666" Margin="0,14,0,0" TextWrapping="Wrap"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Border CornerRadius="8" Background="#FF2E4266" Padding="12,6" Cursor="Hand">
          <TextBlock x:Name="RcSave" Text="PNG 저장" Foreground="#FFF2F4F8" FontFamily="Malgun Gothic" FontWeight="Bold" FontSize="13"/>
        </Border>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

# 리포트 달력 팝업 열기 - 단일 날짜(기존 탭) 또는 범위 선택(기간 탭)
function Open-ReportCalendar {
    param($W, [string]$ForceMode = '')
    $st = $W.Tag
    $mode = [string]$st.Mode
    if ($ForceMode) { $mode = $ForceMode }
    $pop = $W.FindName('RcCalPop')
    $cal = $W.FindName('RcCalendar')
    $applyRow = $W.FindName('RcCalApplyRow')
    $script:CalSyncing = $true
    try {
        $cal.DisplayDateEnd = [DateTime]::Today
        if ($mode -eq 'range') {
            $cal.SelectionMode = 'SelectedRange'
            $applyRow.Visibility = 'Visible'
            $cal.SelectedDates.Clear()
            # 이전 범위가 있으면 미리 표시
            if ($script:ReportRangeEnd -is [DateTime] -and $script:ReportAnchors.ContainsKey('range')) {
                $rs = [DateTime]$script:ReportAnchors['range']
                $re = [DateTime]$script:ReportRangeEnd
                try { $cal.SelectedDates.AddRange($rs, $re) } catch {}
                $cal.DisplayDate = $re
            } else {
                $cal.DisplayDate = [DateTime]::Today
            }
        } else {
            $cal.SelectionMode = 'SingleDate'
            $applyRow.Visibility = 'Collapsed'
            $cal.SelectedDate = [DateTime]$st.Anchor
            $cal.DisplayDate = [DateTime]$st.Anchor
        }
    } catch {}
    $script:CalSyncing = $false
    $pop.IsOpen = $true
}

function Set-ReportTabs {
    param($Rw, [string]$Mode)
    $map = @{ day = 'RcTabDay'; week = 'RcTabWeek'; month = 'RcTabMonth'; season = 'RcTabSeason'; year = 'RcTabYear'; all = 'RcTabAll'; range = 'RcTabRange' }
    foreach ($m in $map.Keys) {
        $tb = $Rw.FindName($map[$m])
        if ($m -eq $Mode) { $tb.Opacity = 1.0; $tb.TextDecorations = [Windows.TextDecorations]::Underline }
        else { $tb.Opacity = 0.45; $tb.TextDecorations = $null }
    }
    # 전체 탭은 이동할 이전/다음 기간이 없으므로 달력·화살표 숨김
    $navVis = 'Visible'
    if ($Mode -eq 'all') { $navVis = 'Collapsed' }
    foreach ($nm in @('RcCal', 'RcPrev', 'RcNext')) {
        $el = $Rw.FindName($nm)
        if ($el) { $el.Visibility = $navVis }
    }
    if ($Mode -eq 'all') {
        $pop = $Rw.FindName('RcCalPop')
        if ($pop) { $pop.IsOpen = $false }
    }
}

function Set-ReportLoading {
    param($Rw)
    $Rw.FindName('RcTitle').Text = ('📋 {0} — 리포트' -f $script:Nickname)
    $Rw.FindName('RcSeq').Visibility = 'Collapsed'
    $Rw.FindName('RcStats').Text = ''
    $Rw.FindName('RcStats2').Text = ''
    $Rw.FindName('RcDonutRow').Visibility = 'Collapsed'
    $Rw.FindName('RcBars').Visibility = 'Collapsed'
    $Rw.FindName('RcCanvas').Visibility = 'Collapsed'
    $Rw.FindName('RcDetailBtn').Visibility = 'Collapsed'
    $Rw.FindName('RcDetailGrid').Children.Clear()
    $rcC = $Rw.FindName('RcComment')
    $rcC.Cursor = $null
    $script:ReportFailed = $false
    $rcC.Text = '데이터 수집 중... (창은 그대로 두세요)'
    $an = New-Object Windows.Media.Animation.DoubleAnimation
    $an.From = 0.35; $an.To = 1
    $an.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(550))
    $an.AutoReverse = $true
    $an.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $rcC.BeginAnimation([Windows.UIElement]::OpacityProperty, $an)
}

function Get-LvlName {
    param([int]$LvlId)
    if ($LvlId -le 0) { return '?' }
    $maj = ([int][math]::Floor($LvlId / 100)) % 100
    $min = [int]($LvlId % 100)
    if ($maj -ge 6) { return '혼천' }
    if (-not $MajorNames.ContainsKey($maj)) { return '?' }
    return ('{0}{1}' -f $MajorNames[$maj], $min)
}

function Add-InfoRow {
    param($Panel, [string]$Label, [string]$Value, [string]$ValueHex = '#FFF2F4F8')
    $dp = New-Object Windows.Controls.DockPanel
    $dp.Margin = New-Object Windows.Thickness 0, 2, 0, 2
    $lb = New-Object Windows.Controls.TextBlock
    $lb.Text = $Label
    $lb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $lb.FontSize = 13; $lb.FontWeight = [Windows.FontWeights]::Bold
    $lb.Foreground = New-Brush '#FF8A93A6'
    $vb = New-Object Windows.Controls.TextBlock
    $vb.Text = $Value
    $vb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $vb.FontSize = 13; $vb.FontWeight = [Windows.FontWeights]::Bold
    $vb.Foreground = New-Brush $ValueHex
    $vb.HorizontalAlignment = 'Right'
    [Windows.Controls.DockPanel]::SetDock($vb, 'Right')
    $null = $dp.Children.Add($vb)
    $null = $dp.Children.Add($lb)
    $null = $Panel.Children.Add($dp)
}

# 상세 지표 렌더 (화료/방총/리치 등 — 율과 횟수 병기, 모든 기간 공용)
function Fill-DetailStats {
    param($Rw, $Res)
    try {
        $grid = $Rw.FindName('RcDetailGrid')
        $grid.Children.Clear()
        $ext = $Res.Ext
        if (-not $ext -or $null -eq $ext.count -or [int]$ext.count -le 0) {
            Add-InfoRow $grid '상세 지표' '데이터 없음' '#FF8A93A6'
            return
        }
        $rounds = [int]$ext.count   # 그날의 총 국(局) 수
        $hd = New-Object Windows.Controls.TextBlock
        $hd.Text = ('상세 지표 — 총 {0}국(局) 기준' -f $rounds)
        $hd.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $hd.FontSize = 11; $hd.FontWeight = [Windows.FontWeights]::Bold
        $hd.Foreground = New-Brush '#FF8A93A6'
        $hd.Margin = New-Object Windows.Thickness 0, 6, 0, 4
        $null = $grid.Children.Add($hd)
        # 화료 횟수는 원본값(리치/후로/다마 화료 합), 나머지는 율×국수 반올림
        $huleN = 0
        foreach ($k in @('立直和了', '副露和了', '默听和了')) { if ($null -ne $ext.$k) { $huleN += [int]$ext.$k } }
        $hr = [double]$ext.'和牌率'
        Add-InfoRow $grid '화료율' ('{0:P1} ({1}회)' -f $hr, $huleN) '#FF7BE38B'
        $dl = [double]$ext.'放铳率'
        Add-InfoRow $grid '방총율' ('{0:P1} ({1}회)' -f $dl, [int][math]::Round($dl * $rounds)) '#FFFF7B7B'
        $ri = [double]$ext.'立直率'
        Add-InfoRow $grid '리치율' ('{0:P1} ({1}회)' -f $ri, [int][math]::Round($ri * $rounds))
        $fu = [double]$ext.'副露率'
        Add-InfoRow $grid '후로율' ('{0:P1} ({1}회)' -f $fu, [int][math]::Round($fu * $rounds))
        $dmN = 0; if ($null -ne $ext.'默听和了') { $dmN = [int]$ext.'默听和了' }
        Add-InfoRow $grid '다마화료율' ('{0:P1} ({1}회)' -f [double]$ext.'默听率', $dmN)
        if ($null -ne $ext.'自摸率') { Add-InfoRow $grid '츠모율 (화료 중)' ('{0:P1}' -f [double]$ext.'自摸率') }
        if ($null -ne $ext.'平均打点') { Add-InfoRow $grid '평균타점' ('{0:N0}' -f [double]$ext.'平均打点') '#FF7BE38B' }
        if ($null -ne $ext.'最大累计番数') { Add-InfoRow $grid '최대 화료 번수' ('{0}판' -f [int]$ext.'最大累计番数') }
        if ($null -ne $ext.'平均铳点') { Add-InfoRow $grid '평균방총점' ('{0:N0}' -f [double]$ext.'平均铳点') '#FFFF7B7B' }
        $rst = $Res.St
        if ($rst -and $null -ne $rst.negative_rate -and $null -ne $rst.count -and [int]$rst.count -gt 0) {
            $tb = [double]$rst.negative_rate
            Add-InfoRow $grid '토비율' ('{0:P1} ({1}회)' -f $tb, [int][math]::Round($tb * [int]$rst.count))
        }
        if ($null -ne $ext.'和了巡数') { Add-InfoRow $grid '평균화료순' ('{0:N2}순' -f [double]$ext.'和了巡数') }
    } catch {}
}

function New-HitRect {
    param($Canvas, [double]$X, [double]$Y, [double]$W, [double]$H, [string]$Tip)
    $hr = New-Object Windows.Shapes.Rectangle
    $hr.Width = $W; $hr.Height = $H
    $hr.Fill = New-Brush '#01000000'
    $hr.ToolTip = $Tip
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($hr, 0)
    [Windows.Controls.ToolTipService]::SetShowDuration($hr, 30000)
    [Windows.Controls.Canvas]::SetLeft($hr, $X)
    [Windows.Controls.Canvas]::SetTop($hr, $Y)
    $null = $Canvas.Children.Add($hr)
}

function Fill-ReportContent {
    param($Rw, $Pack)
    try {
        $rcC = $Rw.FindName('RcComment')
        $rcC.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $rcC.Opacity = 1
        $rcC.Cursor = $null
        $script:ReportFailed = $false

        $mode = [string]$Pack.Mode
        Set-ReportTabs $Rw $mode
        $n = [int]$Pack.N
        $rc = @(0, 0, 0, 0)
        $prc = @($Pack.RankCounts)
        for ($k = 0; $k -lt 4 -and $k -lt $prc.Count; $k++) { $rc[$k] = [int]$prc[$k] }
        $top2 = $rc[0] + $rc[1]
        $rate = 0.0
        if ($n) { $rate = $top2 / $n }
        $diff = [int]$Pack.Diff
        $seq = @()
        if ($Pack.Seq) { $seq = @($Pack.Seq | ForEach-Object { [int]$_ }) }
        $bks = @()
        if ($Pack.Buckets) { $bks = @($Pack.Buckets | ForEach-Object { $_ }) }
        $unit = ''
        if ($mode -eq 'week') { $unit = '요일' } elseif ($mode -eq 'month') { $unit = '일' } elseif ($mode -eq 'year') { $unit = '월' } elseif ($mode -eq 'season') { $unit = '주차' } elseif ($mode -eq 'all') { $unit = '년' }

        $titleTxt = [string]$Pack.Title
        if ($mode -eq 'day' -and ([string]$Pack.Anchor) -eq ([DateTime]::Today.ToString('yyyy-MM-dd'))) { $titleTxt += ' (오늘)' }
        $Rw.FindName('RcTitle').Text = ('📋 {0} — {1} 리포트' -f $script:Nickname, $titleTxt)
        $Rw.FindName('RcStats').Text = ('총 {0}국   연대율 {1:P0}   1위 {2} · 라스 {3}' -f $n, $rate, $rc[0], $rc[3])

        $arrow = '±0'
        if ($diff -gt 0) { $arrow = "▲$diff" } elseif ($diff -lt 0) { $arrow = "▼$(-$diff)" }
        if ($mode -eq 'day') {
            $best = 0; $run = 0
            foreach ($r in $seq) {
                if ($r -le 2) { $run++; if ($run -gt $best) { $best = $run } } else { $run = 0 }
            }
            $Rw.FindName('RcStats2').Text = ('수지 {0}pt   최고 {1}연속 연대' -f $arrow, $best)
        } else {
            $bestB = $null
            foreach ($b in $bks) { if ([int]$b.N -gt 0 -and ($null -eq $bestB -or [int]$b.Diff -gt [int]$bestB.Diff)) { $bestB = $b } }
            $s2 = ('수지 {0}pt' -f $arrow)
            if ($bestB) {
                $bd = [int]$bestB.Diff
                $ba = "▲$bd"; if ($bd -lt 0) { $ba = "▼$(-$bd)" }
                $s2 += ('   베스트: {0}{1} ({2})' -f [string]$bestB.Label, $unit, $ba)
            }
            $Rw.FindName('RcStats2').Text = $s2
        }

        # 순위 나열 (일간만)
        $rcSeq = $Rw.FindName('RcSeq')
        $rcSeq.Inlines.Clear()
        if ($mode -eq 'day') {
            $rcSeq.Visibility = 'Visible'
            if ($seq.Count -eq 0) { $rcSeq.Inlines.Add('—') }
            for ($i = 0; $i -lt $seq.Count; $i++) {
                if ($i -gt 0 -and $i % 5 -eq 0) { $rcSeq.Inlines.Add(' ') }
                $dr = New-Object Windows.Documents.Run
                $dr.Text = [string]$seq[$i]
                switch ($seq[$i]) {
                    1 { $dr.Foreground = New-Brush '#FFFFD666' }
                    2 { $dr.Foreground = New-Brush '#FF7FB3FF' }
                    4 { $dr.Foreground = New-Brush '#FFFF7B7B' }
                    default { $dr.Foreground = New-Brush '#FFF2F4F8' }
                }
                $rcSeq.Inlines.Add($dr)
            }
        } else {
            $rcSeq.Visibility = 'Collapsed'
        }

        # 도넛
        $donut = $Rw.FindName('RcDonut')
        $legend = $Rw.FindName('RcLegend')
        $donut.Children.Clear()
        $legend.Children.Clear()
        if ($n -gt 0) {
            $Rw.FindName('RcDonutCenter').Text = "${n}국"
            $sliceColors = @('#FFFFD666', '#FF7FB3FF', '#FFB8C0CE', '#FFFF7B7B')
            $cx = 52.0; $cy = 52.0; $R = 50.0; $r0 = 30.0
            $startA = -90.0
            for ($k = 0; $k -lt 4; $k++) {
                if ($rc[$k] -eq 0) { continue }
                $frac = $rc[$k] / $n
                if ($frac -ge 0.999) {
                    $outerG = New-Object Windows.Media.EllipseGeometry (New-Object Windows.Point $cx, $cy), $R, $R
                    $innerG = New-Object Windows.Media.EllipseGeometry (New-Object Windows.Point $cx, $cy), $r0, $r0
                    $ring = New-Object Windows.Media.CombinedGeometry ([Windows.Media.GeometryCombineMode]::Exclude), $outerG, $innerG
                    $pth = New-Object Windows.Shapes.Path
                    $pth.Data = $ring
                    $pth.Fill = New-Brush $sliceColors[$k]
                    $null = $donut.Children.Add($pth)
                    break
                }
                $sweep = 360.0 * $frac
                $a0 = $startA * [math]::PI / 180.0
                $a1 = ($startA + $sweep) * [math]::PI / 180.0
                $p1 = New-Object Windows.Point ($cx + $R * [math]::Cos($a0)), ($cy + $R * [math]::Sin($a0))
                $p2 = New-Object Windows.Point ($cx + $R * [math]::Cos($a1)), ($cy + $R * [math]::Sin($a1))
                $p3 = New-Object Windows.Point ($cx + $r0 * [math]::Cos($a1)), ($cy + $r0 * [math]::Sin($a1))
                $p4 = New-Object Windows.Point ($cx + $r0 * [math]::Cos($a0)), ($cy + $r0 * [math]::Sin($a0))
                $isLarge = ($sweep -gt 180.0)
                $fig = New-Object Windows.Media.PathFigure
                $fig.StartPoint = $p1
                $fig.IsClosed = $true
                $null = $fig.Segments.Add((New-Object Windows.Media.ArcSegment $p2, (New-Object Windows.Size $R, $R), 0, $isLarge, ([Windows.Media.SweepDirection]::Clockwise), $true))
                $null = $fig.Segments.Add((New-Object Windows.Media.LineSegment $p3, $true))
                $null = $fig.Segments.Add((New-Object Windows.Media.ArcSegment $p4, (New-Object Windows.Size $r0, $r0), 0, $isLarge, ([Windows.Media.SweepDirection]::Counterclockwise), $true))
                $geo = New-Object Windows.Media.PathGeometry
                $null = $geo.Figures.Add($fig)
                $pth = New-Object Windows.Shapes.Path
                $pth.Data = $geo
                $pth.Fill = New-Brush $sliceColors[$k]
                $null = $donut.Children.Add($pth)
                $startA += $sweep
            }
            for ($k = 0; $k -lt 4; $k++) {
                $tbL = New-Object Windows.Controls.TextBlock
                $tbL.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
                $tbL.FontSize = 13.5
                $tbL.FontWeight = [Windows.FontWeights]::Bold
                $tbL.Margin = New-Object Windows.Thickness 0, 1, 0, 1
                $sq = New-Object Windows.Documents.Run
                $sq.Text = '■ '
                $sq.Foreground = New-Brush $sliceColors[$k]
                $null = $tbL.Inlines.Add($sq)
                $txt = New-Object Windows.Documents.Run
                $txt.Text = ('{0}위  {1}국 ({2:P0})' -f ($k + 1), $rc[$k], ($rc[$k] / $n))
                $txt.Foreground = New-Brush '#FFD9DCE1'
                $null = $tbL.Inlines.Add($txt)
                $null = $legend.Children.Add($tbL)
            }
            $Rw.FindName('RcDonutRow').Visibility = 'Visible'
        } else {
            $Rw.FindName('RcDonutRow').Visibility = 'Collapsed'
        }

        # 차트 영역
        $cv = $Rw.FindName('RcCanvas')
        $cv.Children.Clear(); $cv.Visibility = 'Collapsed'
        $bars = $Rw.FindName('RcBars')
        $bars.Children.Clear(); $bars.Visibility = 'Collapsed'
        $cum = $Rw.FindName('RcCum')
        $cum.Children.Clear(); $cum.Visibility = 'Collapsed'
        $Rw.FindName('RcCumL').Visibility = 'Collapsed'

        if ($mode -eq 'day') {
            # 일간: 누적 수지 꺾은선 (승단/강단 넘어도 이어짐)
            $lvlsArr = @(); if ($Pack.Lvls) { $lvlsArr = @($Pack.Lvls) }
            $ptsArr = @(); if ($Pack.Pts) { $ptsArr = @($Pack.Pts) }
            $sl0 = 0; if ($null -ne $Pack.StartLvl) { $sl0 = [int]$Pack.StartLvl }
            $cumD = @(Get-CumSeries $sl0 $Pack.StartPt $lvlsArr $ptsArr)
            $meta = @()
            for ($i = 0; $i -lt $cumD.Count; $i++) {
                if ($null -eq $cumD[$i]) { continue }
                $lbl = '시작'
                $rawP = $Pack.StartPt
                $rawL = $sl0
                if ($i -ge 1) {
                    if (($i - 1) -lt $seq.Count) { $lbl = ('{0}국째 · {1}위' -f $i, $seq[$i - 1]) }
                    $rawP = $null; $rawL = 0
                    if (($i - 1) -lt $ptsArr.Count) { $rawP = $ptsArr[$i - 1] }
                    if (($i - 1) -lt $lvlsArr.Count -and $null -ne $lvlsArr[$i - 1]) { $rawL = [int]$lvlsArr[$i - 1] }
                }
                $meta += @{ V = [int]$cumD[$i]; L = $lbl; P = $rawP; Lv = $rawL }
            }
            if ($meta.Count -ge 2) {
                $w2 = 350.0; $h2 = 58.0
                $cv.Width = $w2; $cv.Height = $h2 + 6
                $vv = @($meta | ForEach-Object { $_.V })
                $min = ($vv | Measure-Object -Minimum).Minimum
                $max = ($vv | Measure-Object -Maximum).Maximum
                if ($max -eq $min) { $max = $min + 1 }
                $lineHex = '#FF7BE38B'
                if ([int]$meta[$meta.Count - 1].V -lt 0) { $lineHex = '#FFFF7B7B' }
                if ($min -lt 0 -and $max -gt 0) {
                    $zy = [double](3 + ($h2 - 6) * (1 - ((0 - $min) / ($max - $min))))
                    $zl = New-Object Windows.Shapes.Rectangle
                    $zl.Width = $w2; $zl.Height = 1
                    $zl.Fill = New-Brush '#FF3A4358'
                    [Windows.Controls.Canvas]::SetLeft($zl, 0)
                    [Windows.Controls.Canvas]::SetTop($zl, $zy)
                    $null = $cv.Children.Add($zl)
                }
                $pl = New-Object Windows.Shapes.Polyline
                $pl.Stroke = New-Brush $lineHex
                $pl.StrokeThickness = 2.5
                $pc = New-Object Windows.Media.PointCollection
                $slotW = ($w2 - 10) / ($meta.Count - 1)
                for ($i = 0; $i -lt $meta.Count; $i++) {
                    $px = [double]($i * $slotW) + 5
                    $py = [double](3 + ($h2 - 6) * (1 - (($meta[$i].V - $min) / ($max - $min))))
                    $pc.Add((New-Object Windows.Point $px, $py))
                    $dot = New-Object Windows.Shapes.Ellipse
                    $dot.Width = 6; $dot.Height = 6
                    $dot.Fill = New-Brush $lineHex
                    [Windows.Controls.Canvas]::SetLeft($dot, $px - 3)
                    [Windows.Controls.Canvas]::SetTop($dot, $py - 3)
                    $null = $cv.Children.Add($dot)
                }
                $pl.Points = $pc
                $null = $cv.Children.Add($pl)
                for ($i = 0; $i -lt $meta.Count; $i++) {
                    $px = [double]($i * $slotW) + 5
                    $cvVal = [int]$meta[$i].V
                    $cvArrow = '±0'
                    if ($cvVal -gt 0) { $cvArrow = "▲$cvVal" } elseif ($cvVal -lt 0) { $cvArrow = "▼$(-$cvVal)" }
                    $tipD = ('{0} · 누적 {1}pt' -f $meta[$i].L, $cvArrow)
                    if ($null -ne $meta[$i].P -and [int]$meta[$i].Lv -gt 0) {
                        $tipD += (' · 시점 {0} {1}pt' -f (Get-LvlName ([int]$meta[$i].Lv)), [int]$meta[$i].P)
                    }
                    New-HitRect $cv ($px - $slotW / 2) 0 $slotW ($h2 + 6) $tipD
                }
                $Rw.FindName('RcCumL').Visibility = 'Visible'
                $cv.Visibility = 'Visible'
            }
        } elseif ($bks.Count -gt 0) {
            # 기간: 수지 막대 + 누적 선 + 승단/강등 마커
            $w2 = 350.0
            $bars.Width = $w2
            $maxAbs = 1
            foreach ($b in $bks) { $a = [math]::Abs([int]$b.Diff); if ($a -gt $maxAbs) { $maxAbs = $a } }
            $baseY = 42.0
            $scale = 36.0 / $maxAbs
            $slot = $w2 / $bks.Count
            $bw = [math]::Max(3.0, $slot - 3.0)
            $axis = New-Object Windows.Shapes.Rectangle
            $axis.Width = $w2; $axis.Height = 1
            $axis.Fill = New-Brush '#FF3A4358'
            [Windows.Controls.Canvas]::SetLeft($axis, 0)
            [Windows.Controls.Canvas]::SetTop($axis, $baseY)
            $null = $bars.Children.Add($axis)

            # 누적 수지 및 승단 이벤트 계산
            $cumVals = @(0)
            $running = 0
            for ($i = 0; $i -lt $bks.Count; $i++) {
                $running += [int]$bks[$i].Diff
                $cumVals += $running
            }
            $tips = @()
            for ($i = 0; $i -lt $bks.Count; $i++) {
                $bd = [int]$bks[$i].Diff
                $ba = '±0'; if ($bd -gt 0) { $ba = "▲$bd" } elseif ($bd -lt 0) { $ba = "▼$(-$bd)" }
                $ca = '±0'; $cval = [int]$cumVals[$i + 1]
                if ($cval -gt 0) { $ca = "▲$cval" } elseif ($cval -lt 0) { $ca = "▼$(-$cval)" }
                $tip = ('{0}{1} · {2}국 · 수지 {3}pt · 누적 {4}pt' -f [string]$bks[$i].Label, $unit, [int]$bks[$i].N, $ba, $ca)
                if ([int]$bks[$i].N -gt 0 -and $null -ne $bks[$i].Pt -and [int]$bks[$i].Lvl -gt 0) {
                    $tip += (' · 시점 {0} {1}pt' -f (Get-LvlName ([int]$bks[$i].Lvl)), [int]$bks[$i].Pt)
                }
                $prevL = $Pack.StartLvl
                if ($i -gt 0) { $prevL = $bks[$i - 1].Lvl }
                if ([int]$bks[$i].Lvl -ne [int]$prevL -and [int]$prevL -gt 0 -and [int]$bks[$i].Lvl -gt 0) {
                    if ([int]$bks[$i].Lvl -gt [int]$prevL) { $tip += (' · 🎉승단 ' + (Get-LvlName ([int]$bks[$i].Lvl))) }
                    else { $tip += (' · 강등 ' + (Get-LvlName ([int]$bks[$i].Lvl))) }
                }
                $tips += $tip
            }

            for ($i = 0; $i -lt $bks.Count; $i++) {
                $bd = [int]$bks[$i].Diff
                $bn = [int]$bks[$i].N
                $x0 = $i * $slot + 1.5
                if ($bn -gt 0) {
                    $h = [math]::Max(2.0, [math]::Abs($bd) * $scale)
                    $bar = New-Object Windows.Shapes.Rectangle
                    $bar.Width = $bw; $bar.Height = $h
                    $bar.RadiusX = 1.5; $bar.RadiusY = 1.5
                    if ($bd -ge 0) {
                        $bar.Fill = New-Brush '#FF7BE38B'
                        [Windows.Controls.Canvas]::SetTop($bar, $baseY - $h)
                    } else {
                        $bar.Fill = New-Brush '#FFFF7B7B'
                        [Windows.Controls.Canvas]::SetTop($bar, $baseY + 1)
                    }
                    [Windows.Controls.Canvas]::SetLeft($bar, $x0)
                    $null = $bars.Children.Add($bar)
                }
                $showLbl = $true
                if ($mode -eq 'month') { $dnum = $i + 1; $showLbl = ($dnum -eq 1 -or $dnum % 5 -eq 0) }
                if ($showLbl) {
                    $lb = New-Object Windows.Controls.TextBlock
                    $lb.Text = [string]$bks[$i].Label
                    $lb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
                    $lb.FontSize = 9.5
                    $lb.Foreground = New-Brush '#FF8A93A6'
                    [Windows.Controls.Canvas]::SetLeft($lb, $x0 + $bw / 2 - 5)
                    [Windows.Controls.Canvas]::SetTop($lb, 86)
                    $null = $bars.Children.Add($lb)
                }
                New-HitRect $bars ($i * $slot) 0 $slot 100 $tips[$i]
            }
            $bars.Visibility = 'Visible'

            # 누적 선그래프
            $ch = 66.0
            $cum.Width = $w2; $cum.Height = $ch + 18
            $cmin = ($cumVals | Measure-Object -Minimum).Minimum
            $cmax = ($cumVals | Measure-Object -Maximum).Maximum
            if ($cmax -eq $cmin) { $cmax = $cmin + 1 }
            # 0 기준선
            if ($cmin -lt 0 -and $cmax -gt 0) {
                $zy = 4 + ($ch - 8) * (1 - ((0 - $cmin) / ($cmax - $cmin)))
                $zl = New-Object Windows.Shapes.Rectangle
                $zl.Width = $w2; $zl.Height = 1
                $zl.Fill = New-Brush '#FF3A4358'
                [Windows.Controls.Canvas]::SetLeft($zl, 0)
                [Windows.Controls.Canvas]::SetTop($zl, $zy)
                $null = $cum.Children.Add($zl)
            }
            $pl2 = New-Object Windows.Shapes.Polyline
            $lineHex = '#FF7BE38B'
            if ([int]$cumVals[$cumVals.Count - 1] -lt 0) { $lineHex = '#FFFF7B7B' }
            $pl2.Stroke = New-Brush $lineHex
            $pl2.StrokeThickness = 2.5
            $pc2 = New-Object Windows.Media.PointCollection
            for ($i = 0; $i -lt $cumVals.Count; $i++) {
                $px = 0.0
                if ($i -gt 0) { $px = ($i - 1) * $slot + $slot / 2 + 1.5 }
                $py = [double](4 + ($ch - 8) * (1 - (($cumVals[$i] - $cmin) / ($cmax - $cmin))))
                $pc2.Add((New-Object Windows.Point $px, $py))
                if ($i -gt 0) {
                    $dot = New-Object Windows.Shapes.Ellipse
                    $dot.Width = 5; $dot.Height = 5
                    $dot.Fill = New-Brush $lineHex
                    [Windows.Controls.Canvas]::SetLeft($dot, $px - 2.5)
                    [Windows.Controls.Canvas]::SetTop($dot, $py - 2.5)
                    $null = $cum.Children.Add($dot)
                }
            }
            $pl2.Points = $pc2
            $null = $cum.Children.Add($pl2)
            # 승단/강등 마커
            for ($i = 0; $i -lt $bks.Count; $i++) {
                $prevL = $Pack.StartLvl
                if ($i -gt 0) { $prevL = $bks[$i - 1].Lvl }
                if ([int]$bks[$i].Lvl -ne [int]$prevL -and [int]$prevL -gt 0 -and [int]$bks[$i].Lvl -gt 0) {
                    $up = ([int]$bks[$i].Lvl -gt [int]$prevL)
                    $mk = New-Object Windows.Controls.TextBlock
                    $mk.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
                    $mk.FontSize = 10
                    $mk.FontWeight = [Windows.FontWeights]::ExtraBold
                    if ($up) {
                        $mk.Text = '▲' + (Get-LvlName ([int]$bks[$i].Lvl))
                        $mk.Foreground = New-Brush '#FFFFD666'
                    } else {
                        $mk.Text = '▼' + (Get-LvlName ([int]$bks[$i].Lvl))
                        $mk.Foreground = New-Brush '#FFFF7B7B'
                    }
                    $px = $i * $slot + $slot / 2 + 1.5
                    $py = [double](4 + ($ch - 8) * (1 - (($cumVals[$i + 1] - $cmin) / ($cmax - $cmin))))
                    $my = $py - 15
                    if ($my -lt 0) { $my = $py + 6 }
                    [Windows.Controls.Canvas]::SetLeft($mk, [math]::Max(0, $px - 14))
                    [Windows.Controls.Canvas]::SetTop($mk, $my)
                    $null = $cum.Children.Add($mk)
                }
                New-HitRect $cum ($i * $slot) 0 $slot ($ch + 18) $tips[$i]
            }
            $Rw.FindName('RcCumL').Visibility = 'Visible'
            $cum.Visibility = 'Visible'
        }

        # 개요 정보 그리드 (주식창 스타일)
        $grid = $Rw.FindName('RcInfoGrid')
        $grid.Children.Clear()
        $sl = 0; $el = 0
        if ($null -ne $Pack.StartLvl) { $sl = [int]$Pack.StartLvl }
        if ($null -ne $Pack.EndLvl) { $el = [int]$Pack.EndLvl }
        if ($sl -gt 0 -and $null -ne $Pack.StartPt) {
            Add-InfoRow $grid '시작' ('{0} · {1}pt' -f (Get-LvlName $sl), [int]$Pack.StartPt)
        }
        if ($el -gt 0 -and $null -ne $Pack.EndPt) {
            $endHex = '#FFF2F4F8'
            if ($el -gt $sl) { $endHex = '#FFFFD666' } elseif ($el -lt $sl -and $sl -gt 0) { $endHex = '#FFFF7B7B' }
            Add-InfoRow $grid '종료' ('{0} · {1}pt' -f (Get-LvlName $el), [int]$Pack.EndPt) $endHex
        }
        # 최고/최저 점수
        if ($mode -eq 'day') {
            $dayVals = @()
            if ($Pack.Pts) { $dayVals = @($Pack.Pts | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) }
            if ($dayVals.Count -gt 0) {
                Add-InfoRow $grid '최고 점수' ('{0}pt' -f (($dayVals | Measure-Object -Maximum).Maximum)) '#FF7BE38B'
                Add-InfoRow $grid '최저 점수' ('{0}pt' -f (($dayVals | Measure-Object -Minimum).Minimum)) '#FFFF7B7B'
            }
        } elseif ($bks.Count -gt 0) {
            $cands = @()
            if ($sl -gt 0 -and $null -ne $Pack.StartPt) { $cands += @{ L = $sl; P = [int]$Pack.StartPt } }
            foreach ($b in $bks) {
                if ([int]$b.N -gt 0 -and $null -ne $b.Pt -and [int]$b.Lvl -gt 0) { $cands += @{ L = [int]$b.Lvl; P = [int]$b.Pt } }
            }
            if ($cands.Count -gt 0) {
                $hi = $null; $lo = $null
                foreach ($c in $cands) {
                    $key = [long]$c.L * 100000 + $c.P
                    if ($null -eq $hi -or $key -gt ([long]$hi.L * 100000 + $hi.P)) { $hi = $c }
                    if ($null -eq $lo -or $key -lt ([long]$lo.L * 100000 + $lo.P)) { $lo = $c }
                }
                Add-InfoRow $grid '최고 점수' ('{0} · {1}pt' -f (Get-LvlName $hi.L), $hi.P) '#FF7BE38B'
                Add-InfoRow $grid '최저 점수' ('{0} · {1}pt' -f (Get-LvlName $lo.L), $lo.P) '#FFFF7B7B'
            }
        }
        if ($n -gt 0) {
            $avgRank = (1 * $rc[0] + 2 * $rc[1] + 3 * $rc[2] + 4 * $rc[3]) / $n
            Add-InfoRow $grid '평균 순위' ('{0:N2}' -f $avgRank)
            $perGame = $diff / $n
            $pgHex = '#FF7BE38B'; if ($perGame -lt 0) { $pgHex = '#FFFF7B7B' }
            Add-InfoRow $grid '국당 수지' ('{0:+0.0;-0.0;±0}pt' -f $perGame) $pgHex
        }
        if ($mode -ne 'day' -and $bks.Count -gt 0) {
            $busiest = $null
            foreach ($b in $bks) { if ([int]$b.N -gt 0 -and ($null -eq $busiest -or [int]$b.N -gt [int]$busiest.N)) { $busiest = $b } }
            if ($busiest) { Add-InfoRow $grid '최다 대국' ('{0}{1} ({2}국)' -f [string]$busiest.Label, $unit, [int]$busiest.N) }
        }

        # 상세 지표 (모든 기간, 버튼 클릭 시 백그라운드 로딩)
        $dBtn = $Rw.FindName('RcDetailBtn')
        $Rw.FindName('RcDetailGrid').Children.Clear()
        if ($n -gt 0) {
            $dKey = Get-DetailKey $mode ([DateTime]::ParseExact([string]$Pack.Anchor, 'yyyy-MM-dd', $null))
            if ($script:DetailCache.ContainsKey($dKey)) {
                $dBtn.Visibility = 'Collapsed'
                Fill-DetailStats $Rw $script:DetailCache[$dKey]
            } elseif ($script:DetailProc -and -not $script:DetailProc.HasExited -and $script:DetailReqAnchor -eq $dKey) {
                $dBtn.Text = '상세 지표 불러오는 중...'
                $dBtn.Visibility = 'Visible'
            } else {
                $dBtn.Text = '상세 지표 보기 +'
                $dBtn.Visibility = 'Visible'
            }
        } else {
            $dBtn.Visibility = 'Collapsed'
        }

        # 한 줄 평 — 수지(총/국당) 중심 등급 + 연대/라스 특수 케이스 + 화료·방총 첨언
        if ($mode -eq 'day') {
            if ($n -eq 0) {
                if (([string]$Pack.Anchor) -eq ([DateTime]::Today.ToString('yyyy-MM-dd'))) { $comment = '오늘은 아직 한 판도 안 쳤어요 🀄' }
                else { $comment = '이 날은 대국 기록이 없어요' }
            } else {
                $pg = $diff / $n
                $lastRate = $rc[3] / $n
                if ($rate -ge 0.7 -and $n -ge 5 -and $diff -gt 0) { $comment = '🔥 폼 미쳤습니다' }
                elseif ($diff -ge 200 -or ($pg -ge 30 -and $n -ge 3)) { $comment = '🚀 폭풍 성장의 날!' }
                elseif ($diff -ge 80) { $comment = '📈 수확의 날이네요' }
                elseif ($diff -gt 0) { $comment = '👍 준수한 하루' }
                elseif ($diff -eq 0) { $comment = '무난한 하루였습니다' }
                elseif ($lastRate -ge 0.5 -and $n -ge 4) { $comment = '⚰️ 오늘은 라스의 날' }
                elseif ($diff -le -200 -or ($pg -le -30 -and $n -ge 3)) { $comment = '💀 이 날은 접는 게 나았을지도...' }
                elseif ($diff -le -80 -or ($pg -le -15 -and $n -ge 3)) { $comment = '🩸 꽤 아픈 하루였네요' }
                else { $comment = '📉 내일의 나를 믿읍시다' }
                # 화료율/방총율이 있으면 원인 한마디 (백그라운드 조회 시에만 채워짐)
                $hr = $null; $dl = $null
                if ($null -ne $Pack.Hr) { $hr = [double]$Pack.Hr }
                if ($null -ne $Pack.Dl) { $dl = [double]$Pack.Dl }
                if ($diff -lt 0) {
                    if ($null -ne $dl -and $dl -ge 0.18) { $comment += "`n쏘인 게 너무 많았어요 (방총율 {0:P0})" -f $dl }
                    elseif ($null -ne $hr -and $hr -le 0.15) { $comment += "`n화료가 안 터진 날 (화료율 {0:P0})" -f $hr }
                    elseif ($null -ne $hr -and $null -ne $dl -and $hr -ge 0.22 -and $dl -le 0.13) { $comment += "`n내용은 나쁘지 않았는데 운이 야속했네요" }
                } elseif ($diff -gt 0) {
                    if ($null -ne $hr -and $hr -ge 0.28) { $comment += "`n화료 머신 가동 중 (화료율 {0:P0})" -f $hr }
                    elseif ($null -ne $dl -and $dl -le 0.10) { $comment += "`n수비가 빛난 날 (방총율 {0:P0})" -f $dl }
                }
            }
        } else {
            $lastRateP = 0.0
            if ($n -gt 0) { $lastRateP = $rc[3] / $n }
            # 기간 내 최저 누적 수지 (낙폭 후 반등 감지용)
            $minCum = 0; $cumV = 0
            foreach ($b in $bks) { $cumV += [int]$b.Diff; if ($cumV -lt $minCum) { $minCum = $cumV } }
            if ($n -eq 0) { $comment = '이 기간엔 대국 기록이 없어요' }
            elseif ($minCum -le -300 -and $diff -gt 0) { $comment = '🎢 바닥 찍고 반등한 구간!' }
            elseif ($diff -ge 500) { $comment = '📈 폭풍 성장 구간!' }
            elseif ($rate -ge 0.55 -and $diff -gt 0) { $comment = '🔥 흐름이 좋아요' }
            elseif ($diff -ge 150) { $comment = '📈 순항 중입니다' }
            elseif ($diff -gt 0) { $comment = '👍 플러스로 마감한 구간' }
            elseif ($diff -le -500) { $comment = '💀 시련의 구간이었네요...' }
            elseif ($lastRateP -ge 0.4) { $comment = '⚰️ 라스가 유난히 잦았던 구간이네요' }
            elseif ($diff -le -150) { $comment = '🩸 손실이 좀 컸던 구간' }
            elseif ($diff -lt 0) { $comment = '📉 다음 구간을 노려봅시다' }
            else { $comment = '꾸준히 진행 중' }
        }
        $rcC.Text = $comment
    } catch {}
}

function Request-Report {
    param([string]$Mode, [DateTime]$Anchor, [DateTime]$RangeEnd = [DateTime]::MinValue)
    $rw = $script:ReportWin
    if (-not $rw) { return }
    if ($Mode -eq 'range') {
        if ($RangeEnd -eq [DateTime]::MinValue -and $script:ReportRangeEnd -is [DateTime]) { $RangeEnd = [DateTime]$script:ReportRangeEnd }
        if ($RangeEnd -eq [DateTime]::MinValue) { $RangeEnd = $Anchor }
        if ($RangeEnd -lt $Anchor) { $t0 = $Anchor; $Anchor = $RangeEnd; $RangeEnd = $t0 }
        $script:ReportRangeEnd = $RangeEnd
    }
    $rw.Tag = @{ Mode = $Mode; Anchor = $Anchor; RangeEnd = $RangeEnd }
    $script:ReportAnchors[$Mode] = $Anchor
    Set-ReportTabs $rw $Mode
    $key = ('{0}|{1}' -f $Mode, $Anchor.ToString('yyyy-MM-dd'))
    if ($Mode -eq 'range') { $key += ('|{0}' -f $RangeEnd.ToString('yyyy-MM-dd')) }

    # 오늘-일간은 라이브 데이터로 즉시 표시 (초기 로딩 전엔 라이브 데이터가 없으니 백그라운드 조회로)
    if ($Mode -eq 'day' -and $Anchor -eq [DateTime]::Today -and $script:LastData) {
        $rc = @(0, 0, 0, 0)
        foreach ($r in @($script:TodaySeq)) { if ($r -ge 1 -and $r -le 4) { $rc[$r - 1]++ } }
        $diff = 0
        if ($script:LastData) { $diff = [int]$script:LastData.Diff }
        $pack = @{
            Mode = 'day'; Anchor = $Anchor.ToString('yyyy-MM-dd')
            Title = ('{0}/{1}' -f $Anchor.Month, $Anchor.Day)
            N = @($script:TodaySeq).Count; Diff = $diff; RankCounts = $rc
            Seq = @($script:TodaySeq); Pts = @($script:TodayPts); Lvls = @($script:TodayLvls); Buckets = @()
            StartLvl = [int]$script:BaselineLvl; StartPt = $script:BaselinePt
            EndLvl = [int]$script:CurLvlId; EndPt = $(if ($script:LastData) { $script:LastData.CurPt } else { $null })
        }
        Fill-ReportContent $rw $pack
        return
    }
    if ($script:ReportCache.ContainsKey($key)) {
        Fill-ReportContent $rw $script:ReportCache[$key]
        return
    }
    if ($script:ReportProc -and -not $script:ReportProc.HasExited) {
        Show-Toast '이미 리포트를 불러오는 중이에요' $false
        return
    }
    Set-ReportLoading $rw
    try { Remove-Item (Join-Path $script:DataDir 'report-result.json') -Force -ErrorAction SilentlyContinue } catch {}
    $script:ReportReqKey = $key
    $script:ReportStart = Get-Date
    $repArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ReportOnce', $Mode, $Anchor.ToString('yyyy-MM-dd'))
    if ($Mode -eq 'range') { $repArgs += $RangeEnd.ToString('yyyy-MM-dd') }
    $script:ReportProc = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList $repArgs
    $script:ReportPollTimer.Start()
}

function Show-ReportCard {
    param([string]$Mode = 'day', [DateTime]$Day = [DateTime]::Today)
    try {
        if ($script:ReportWin) {
            try { $script:ReportWin.Close() } catch {}
            $script:ReportWin = $null
        }
        $rw = [Windows.Markup.XamlReader]::Parse($script:ReportXaml)
        $rw.WindowStartupLocation = 'CenterScreen'
        $rw.Add_MouseLeftButtonDown({ try { $args[0].DragMove() } catch {} })
        $rw.Add_Closed({ if ($script:ReportWin -eq $args[0]) { $script:ReportWin = $null } })
        $rw.FindName('RcClose').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            [Windows.Window]::GetWindow($args[0]).Close()
        })
        # 실패 메시지 클릭 → 다시 시도
        $rw.FindName('RcComment').Add_MouseLeftButtonDown({
            if (-not $script:ReportFailed) { return }
            $args[1].Handled = $true
            $script:ReportFailed = $false
            $w = [Windows.Window]::GetWindow($args[0])
            $st = $w.Tag
            Request-Report ([string]$st.Mode) ([DateTime]$st.Anchor)
        })
        # 탭 전환
        $rw.FindName('RcTabDay').Tag = 'day'
        $rw.FindName('RcTabWeek').Tag = 'week'
        $rw.FindName('RcTabMonth').Tag = 'month'
        $rw.FindName('RcTabSeason').Tag = 'season'
        $rw.FindName('RcTabYear').Tag = 'year'
        $rw.FindName('RcTabAll').Tag = 'all'
        $tabHandler = {
            $args[1].Handled = $true
            $m = [string]$args[0].Tag
            # 탭마다 마지막으로 보던 기간을 독립적으로 기억
            $a = [DateTime]::Today
            if ($script:ReportAnchors.ContainsKey($m)) { $a = [DateTime]$script:ReportAnchors[$m] }
            Request-Report $m (Get-PeriodAnchor $m $a)
        }
        foreach ($tn in @('RcTabDay', 'RcTabWeek', 'RcTabMonth', 'RcTabSeason', 'RcTabYear', 'RcTabAll')) {
            $rw.FindName($tn).Add_MouseLeftButtonDown($tabHandler)
        }
        # '기간' 탭: 이전 범위가 있으면 바로 표시하고, 없으면 달력에서 범위 선택
        $rw.FindName('RcTabRange').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            if ($script:ReportRangeEnd -is [DateTime] -and $script:ReportAnchors.ContainsKey('range')) {
                Request-Report 'range' ([DateTime]$script:ReportAnchors['range']) ([DateTime]$script:ReportRangeEnd)
            }
            Open-ReportCalendar $w 'range'
        })
        # 범위 '적용' 버튼
        $rw.FindName('RcCalApply').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            $cal = $w.FindName('RcCalendar')
            $dates = @($cal.SelectedDates)
            if ($dates.Count -eq 0) { return }
            $s2 = ($dates | Measure-Object -Minimum).Minimum
            $e2 = ($dates | Measure-Object -Maximum).Maximum
            $w.FindName('RcCalPop').IsOpen = $false
            Request-Report 'range' ([DateTime]$s2).Date ([DateTime]$e2).Date
        })
        # ◀ ▶ 기간 이동
        $rw.FindName('RcPrev').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            $st = $w.Tag
            $m = [string]$st.Mode
            if ($m -eq 'all') { return }
            $a = [DateTime]$st.Anchor
            if ($m -eq 'range') {
                $re = [DateTime]$st.RangeEnd
                $span = [math]::Max(1, ($re.Date - $a.Date).Days + 1)
                Request-Report 'range' $a.AddDays(-$span) $re.AddDays(-$span)
                return
            }
            switch ($m) {
                'week' { $a = $a.AddDays(-7) }
                'season' { $a = $a.AddMonths(-3) }
                'month' { $a = $a.AddMonths(-1) }
                'year' { $a = $a.AddYears(-1) }
                default { $a = $a.AddDays(-1) }
            }
            Request-Report $m (Get-PeriodAnchor $m $a)
        })
        $rw.FindName('RcNext').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            $st = $w.Tag
            $m = [string]$st.Mode
            if ($m -eq 'all') { return }
            $a = [DateTime]$st.Anchor
            if ($m -eq 'range') {
                $re = [DateTime]$st.RangeEnd
                $span = [math]::Max(1, ($re.Date - $a.Date).Days + 1)
                $ns = $a.AddDays($span); $ne = $re.AddDays($span)
                if ($ns -gt [DateTime]::Today) { return }
                if ($ne -gt [DateTime]::Today) { $ne = [DateTime]::Today }
                Request-Report 'range' $ns $ne
                return
            }
            switch ($m) {
                'week' { $a = $a.AddDays(7) }
                'season' { $a = $a.AddMonths(3) }
                'month' { $a = $a.AddMonths(1) }
                'year' { $a = $a.AddYears(1) }
                default { $a = $a.AddDays(1) }
            }
            $a = Get-PeriodAnchor $m $a
            if ($a -gt (Get-PeriodAnchor $m ([DateTime]::Today))) { return }
            Request-Report $m $a
        })
        # 📅 달력에서 날짜(또는 기간 모드에선 범위)를 골라 이동 (전체 탭 제외)
        $rw.FindName('RcCal').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            $st = $w.Tag
            if ([string]$st.Mode -eq 'all') { return }
            $pop = $w.FindName('RcCalPop')
            if ($pop.IsOpen) { $pop.IsOpen = $false; return }
            Open-ReportCalendar $w
        })
        $rw.FindName('RcCalendar').Add_SelectedDatesChanged({
            if ($script:CalSyncing) { return }
            # 달력이 마우스를 붙잡고 있으면 다음 클릭이 먹히는 WPF 버그 해제
            try { [Windows.Input.Mouse]::Capture($null) } catch {}
            $cal = $args[0]
            if ([string]$cal.SelectionMode -ne 'SingleDate') { return }   # 범위 모드는 '적용' 버튼으로
            if ($null -eq $cal.SelectedDate) { return }
            $d = ([DateTime]$cal.SelectedDate).Date
            $w = $script:ReportWin
            if (-not $w) { return }
            $st = $w.Tag
            $m = [string]$st.Mode
            if ($m -eq 'all') { return }
            $w.FindName('RcCalPop').IsOpen = $false
            Request-Report $m (Get-PeriodAnchor $m $d)
        })
        # 상세 지표 로딩 (모든 기간) - 리포트 다른 부분은 그대로 두고 이 영역만 백그라운드로 채움
        $rw.FindName('RcDetailBtn').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            $st = $w.Tag
            $r = Get-PeriodRange ([string]$st.Mode) ([DateTime]$st.Anchor)
            $dKey = ('{0:yyyy-MM-dd}|{1:yyyy-MM-dd}' -f $r.S, $r.E)
            if ($script:DetailCache.ContainsKey($dKey)) { return }
            if ($script:DetailProc -and -not $script:DetailProc.HasExited) {
                Show-Toast '이미 상세 지표를 불러오는 중이에요' $false
                return
            }
            try { Remove-Item (Join-Path $script:DataDir 'detail-result.json') -Force -ErrorAction SilentlyContinue } catch {}
            $script:DetailReqAnchor = $dKey
            $script:DetailStart = Get-Date
            $script:DetailProc = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-DetailOnce', $r.S.ToString('yyyy-MM-dd'), $r.E.ToString('yyyy-MM-dd')
            $args[0].Text = '상세 지표 불러오는 중...'
            $script:DetailPollTimer.Start()
        })
        # PNG 저장
        $rw.FindName('RcSave').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            try {
                $wnd = [Windows.Window]::GetWindow($args[0])
                $card = $wnd.Content
                $cw = [int][math]::Ceiling($card.ActualWidth)
                $ch = [int][math]::Ceiling($card.ActualHeight)
                $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap($cw, $ch, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
                $rtb.Render($card)
                $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $st = $wnd.Tag
                $dir = Split-Path $script:PosFile
                $path = Join-Path $dir ('report-{0}-{1:yyyyMMdd}.png' -f [string]$st.Mode, ([DateTime]$st.Anchor))
                $fs = [IO.File]::Open($path, 'Create')
                $enc.Save($fs)
                $fs.Close()
                Show-Toast ('저장됨: ' + [IO.Path]::GetFileName($path)) $true
            } catch {
                Show-Toast '저장 실패' $false
            }
        })
        $script:ReportWin = $rw
        try {
            $sc = [double]$script:Settings.UiScale
            if ([math]::Abs($sc - 1.0) -ge 0.001) { $rw.Content.LayoutTransform = New-Object Windows.Media.ScaleTransform $sc, $sc }
        } catch {}
        $rw.Show()
        Request-Report $Mode (Get-PeriodAnchor $Mode $Day)
    } catch {}
}

# 리포트 백그라운드 수집 감시
$script:ReportProc = $null
$script:ReportStart = $null
$script:ReportReqKey = ''
$script:ReportCache = @{}
$script:ReportAnchors = @{}
$script:ReportWin = $null
$script:CalSyncing = $false
$script:CalPopClosed = $null
$reportPollTimer = New-Object Windows.Threading.DispatcherTimer
$reportPollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$reportPollTimer.Add_Tick({
    if (-not $script:ReportProc) { $script:ReportPollTimer.Stop(); return }
    if (-not $script:ReportProc.HasExited) {
        if ($script:ReportStart -and ((Get-Date) - $script:ReportStart).TotalSeconds -gt 180) {
            try { $script:ReportProc.Kill() } catch {}
        }
        return
    }
    $script:ReportProc = $null
    $script:ReportPollTimer.Stop()
    $pack = $null
    try { $pack = Get-Content (Join-Path $script:DataDir 'report-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if ($pack) {
        $script:ReportCache[$script:ReportReqKey] = $pack
        if ($script:ReportWin) {
            try {
                $cur = $script:ReportWin.Tag
                $curKey = ('{0}|{1}' -f [string]$cur.Mode, ([DateTime]$cur.Anchor).ToString('yyyy-MM-dd'))
                if ($curKey -eq $script:ReportReqKey) { Fill-ReportContent $script:ReportWin $pack }
            } catch {}
        }
    } elseif ($script:ReportWin) {
        try {
            $rcC = $script:ReportWin.FindName('RcComment')
            $rcC.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
            $rcC.Opacity = 1
            $rcC.Text = '불러오기 실패 - 여기를 눌러 다시 시도'
            $rcC.Cursor = [Windows.Input.Cursors]::Hand
            $script:ReportFailed = $true
        } catch {}
    }
})
$script:ReportPollTimer = $reportPollTimer

# 일간 상세 지표 백그라운드 수집 감시
$script:DetailProc = $null
$script:DetailStart = $null
$script:DetailReqAnchor = ''
$script:DetailCache = @{}
$detailPollTimer = New-Object Windows.Threading.DispatcherTimer
$detailPollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$detailPollTimer.Add_Tick({
    if (-not $script:DetailProc) { $script:DetailPollTimer.Stop(); return }
    if (-not $script:DetailProc.HasExited) {
        if ($script:DetailStart -and ((Get-Date) - $script:DetailStart).TotalSeconds -gt 60) {
            try { $script:DetailProc.Kill() } catch {}
        }
        return
    }
    $script:DetailProc = $null
    $script:DetailPollTimer.Stop()
    $res = $null
    try { $res = Get-Content (Join-Path $script:DataDir 'detail-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $ok = ($res -and $res.Ext -and $null -ne $res.Ext.count)
    # 기간이 오늘을 포함하면 대국이 계속 추가되므로 캐시하지 않음
    if ($ok) {
        try {
            $endD = [DateTime]::ParseExact((([string]$res.Anchor) -split '\|')[1], 'yyyy-MM-dd', $null)
            if ($endD -le [DateTime]::Today) { $script:DetailCache[[string]$res.Anchor] = $res }
        } catch {}
    }
    $rw = $script:ReportWin
    if (-not $rw) { return }
    try {
        $cur = $rw.Tag
        $curKey = Get-DetailKey ([string]$cur.Mode) ([DateTime]$cur.Anchor)
        if ($curKey -ne $script:DetailReqAnchor) { return }
        $btn = $rw.FindName('RcDetailBtn')
        if ($ok) {
            $btn.Visibility = 'Collapsed'
            Fill-DetailStats $rw $res
        } else {
            $btn.Text = '상세 지표 불러오기 실패 — 다시 시도'
        }
    } catch {}
})
$script:DetailPollTimer = $detailPollTimer

# --- 내 전적 박스 ---
$script:Theme = 'light'
$script:LastData = $null
# 설정 별도 창: 메인 박스의 SettingsPanel을 런타임에 이 창으로 옮겨 담는다 (배선은 그대로 유효)
$script:SettingsShellXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Border x:Name="SetRoot" CornerRadius="12" Background="#F5202433" Padding="16,10,12,14">
    <StackPanel Width="392">
      <DockPanel Margin="0,0,4,4">
        <TextBlock x:Name="SetClose" Text="✕" DockPanel.Dock="Right" FontFamily="Malgun Gothic" FontSize="14" FontWeight="Bold" Foreground="#FF8A93A6" Cursor="Hand" Padding="8,0,0,0"/>
        <TextBlock x:Name="SetTitle" Text="⚙ 설정" FontFamily="Malgun Gothic" FontSize="14.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8"/>
      </DockPanel>
      <StackPanel x:Name="SetTabStrip" Orientation="Horizontal" Margin="0,0,0,4"/>
      <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="760" Padding="0,0,10,0">
        <ScrollViewer.Resources>
          <!-- 안드로이드풍 슬림 스크롤바: 화살표 없이 얇은 둥근 썸만 -->
          <Style TargetType="{x:Type ScrollBar}">
            <Setter Property="Width" Value="5"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                  <Grid Background="Transparent" Width="5">
                    <Track x:Name="PART_Track" IsDirectionReversed="True">
                      <Track.Thumb>
                        <Thumb>
                          <Thumb.Template>
                            <ControlTemplate TargetType="{x:Type Thumb}">
                              <Border Background="#55AAB4C4" CornerRadius="2.5"/>
                            </ControlTemplate>
                          </Thumb.Template>
                        </Thumb>
                      </Track.Thumb>
                    </Track>
                  </Grid>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </ScrollViewer.Resources>
        <ContentControl x:Name="SetHost"/>
      </ScrollViewer>
    </StackPanel>
  </Border>
</Window>
'@

# 요소(또는 자손)의 x:Name으로 설정 탭 소속 판별 - 매핑에 없으면 -1 (호출부에서 직전 탭 유지)
function Get-SetTabIndex {
    param($El, $Map)
    $n = ''
    try { $n = [string]$El.Name } catch {}
    if ($n) { $v = $Map[$n]; if ($null -ne $v) { return [int]$v } }
    if ($El -is [Windows.Controls.Panel]) {
        foreach ($c in $El.Children) {
            $r = Get-SetTabIndex $c $Map
            if ($r -ge 0) { return $r }
        }
    }
    return -1
}

# 설정 창 탭 전환: 해당 탭 패널만 표시, 버튼 스타일은 Apply-Theme가 테마색에 맞춰 갱신
function Select-SetTab {
    param([int]$Idx)
    $script:SetTabIdx = $Idx
    for ($i = 0; $i -lt $script:SetTabPanels.Count; $i++) {
        if ($i -eq $Idx) { $script:SetTabPanels[$i].Visibility = 'Visible' }
        else { $script:SetTabPanels[$i].Visibility = 'Collapsed' }
    }
    if ($script:MyBox) { Apply-Theme $script:MyBox }
}
$script:SetTabIdx = 0
$script:SetTabPanels = @()
$script:SetTabBtns = @()

$my = New-StatWindow $BoxXaml
$win = $my.Win
$script:MyBox = $my

# 기본 위치 규칙이 바뀌면 올린다 - 저장된 위치가 이보다 낮으면 한 번만 새 기본값으로 재배치
$script:PosVer = 2

# 내 박스 기본 위치: 내 프로필(하단 왼쪽 아바타) 바로 위 - 패나 명패를 가리지 않는 자리
function Set-MyBoxDefaultPos {
    $w = $script:MyBox.Win
    $w.UpdateLayout()
    $h = [double]$w.ActualHeight
    if ($h -le 0) { $h = 200 }
    $g = Get-GameRectDip
    $w.Left = $g.X + $g.W * 0.142
    $w.Top = $g.Y + $g.H * 0.655 - $h
}

$posFile = Join-Path $script:DataDir 'overlay-pos.json'
$script:PosFile = $posFile
$script:HasSavedPos = $false
if (Test-Path $posFile) {
    try {
        $pos = Get-Content $posFile -Raw | ConvertFrom-Json
        # 기본 위치 규칙이 바뀌었으면(PosVer가 낮으면) 저장된 위치를 버리고 새 기본값으로 한 번 재배치
        if ($null -ne $pos.Left -and $null -ne $pos.Top -and ([int]$pos.PosVer) -ge $script:PosVer) {
            $win.Left = $pos.Left; $win.Top = $pos.Top
            $script:HasSavedPos = $true
        }
        if ($pos.Theme -and @('light', 'dark', 'trans') -contains $pos.Theme) { $script:Theme = $pos.Theme }
        if ($pos.Settings) {
            foreach ($k in @('Stable', 'Danger', 'RankColors', 'Streak', 'Spark', 'Toast', 'MortalWatch', 'ShowTobi', 'Anom', 'BadgeOn', 'StableDual', 'StableDualThrone', 'StableRoomFirst',
                             'ShowRank', 'ShowGoal', 'ShowGame', 'ShowStat1', 'ShowStat2', 'ShowStat3', 'ShowStat4')) {
                if ($null -ne $pos.Settings.$k) { $script:Settings[$k] = [bool]$pos.Settings.$k }
            }
            if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
            $codes = @('all', 'm1', 'm3', 'm6', 'y1', 'g50', 'g100', 'g200', 'base')
            if ($pos.Settings.MyBasis -and $codes -contains $pos.Settings.MyBasis) { $script:Settings.MyBasis = [string]$pos.Settings.MyBasis }
            if ($pos.Settings.OppBasis -and $codes -contains $pos.Settings.OppBasis) { $script:Settings.OppBasis = [string]$pos.Settings.OppBasis }
            # 구버전 설정(StatBasis 숫자) 이전
            if ($null -ne $pos.Settings.StatBasis -and [int]$pos.Settings.StatBasis -gt 0) {
                $script:Settings.MyBasis = 'g' + [int]$pos.Settings.StatBasis
            }
            foreach ($kk in @('KeyScan', 'KeyClose', 'KeyExit')) {
                if ($pos.Settings.$kk -and $script:KeyOptions -contains $pos.Settings.$kk) { $script:Settings[$kk] = [string]$pos.Settings.$kk }
            }
            if ($null -ne $pos.Settings.DailyGoal) { $script:Settings.DailyGoal = [int]$pos.Settings.DailyGoal }
            if ($null -ne $pos.Settings.OppMinN) { $script:Settings.OppMinN = [int]$pos.Settings.OppMinN }
            if ($null -ne $pos.Settings.UiScale) { $script:Settings.UiScale = [double]$pos.Settings.UiScale }
            if ($null -ne $pos.Settings.BgAlpha) { $script:Settings.BgAlpha = [int]$pos.Settings.BgAlpha }
            foreach ($bk in @('BgAlphaLight', 'BgAlphaDark', 'BgAlphaTrans')) {
                if ($null -ne $pos.Settings.$bk) { $script:Settings[$bk] = [int]$pos.Settings.$bk }
            }
            if ($pos.Settings.SessionBase) { $script:Settings.SessionBase = [string]$pos.Settings.SessionBase }
            if ($pos.Settings.BaseCustomKind) { $script:Settings.BaseCustomKind = [string]$pos.Settings.BaseCustomKind }
            if ($pos.Settings.BaseCustomAbs) { $script:Settings.BaseCustomAbs = [string]$pos.Settings.BaseCustomAbs }
            if ($null -ne $pos.Settings.BaseCustomDays) { $script:Settings.BaseCustomDays = [int]$pos.Settings.BaseCustomDays }
            if ($null -ne $pos.Settings.BaseCustomHours) { $script:Settings.BaseCustomHours = [int]$pos.Settings.BaseCustomHours }
            if ($null -ne $pos.Settings.AnomPct) { $script:Settings.AnomPct = [int]$pos.Settings.AnomPct }
            if ($null -ne $pos.Settings.BoxRatioX) { $script:Settings.BoxRatioX = [math]::Max(50, [math]::Min(200, [int]$pos.Settings.BoxRatioX)) }
            if ($null -ne $pos.Settings.BoxRatioY) { $script:Settings.BoxRatioY = [math]::Max(50, [math]::Min(200, [int]$pos.Settings.BoxRatioY)) }
            if ($null -ne $pos.Settings.FontScale) { $script:Settings.FontScale = [math]::Max(50, [math]::Min(200, [int]$pos.Settings.FontScale)) }
            if ($null -ne $pos.Settings.UiScaleOpp) { $script:Settings.UiScaleOpp = [double]$pos.Settings.UiScaleOpp }
            foreach ($ok9 in @('BoxRatioXOpp', 'BoxRatioYOpp', 'FontScaleOpp')) {
                if ($null -ne $pos.Settings.$ok9) {
                    $v9 = [int]$pos.Settings.$ok9
                    $script:Settings[$ok9] = $(if ($v9 -lt 0) { -1 } else { [math]::Max(50, [math]::Min(200, $v9)) })
                }
            }
            if ($null -ne $pos.Settings.BadgeDefs) { $script:Settings.BadgeDefs = [string]$pos.Settings.BadgeDefs }
            # 프리셋 복원 (PSObject → 해시테이블)
            if ($pos.Presets) {
                foreach ($pn in $pos.Presets.PSObject.Properties.Name) {
                    $pv = $pos.Presets.$pn
                    $ps2 = @{}
                    if ($pv.Settings) {
                        foreach ($spn in $pv.Settings.PSObject.Properties.Name) { $ps2[$spn] = $pv.Settings.$spn }
                    }
                    $script:Presets[$pn] = @{ Theme = [string]$pv.Theme; Settings = $ps2 }
                }
            }
            foreach ($sk in @('AnomMode', 'AnomHigh', 'AnomLow', 'AnomOffMe', 'AnomOffOpp', 'AnomCMe', 'AnomCOpp', 'AnomPctItems', 'DispOffMe', 'DispOffOpp',
                              'MyStableMode', 'OppStableMode', 'StableColors', 'TextColor', 'BgColor', 'OppStatScope', 'MyStatScope',
                              'TextColorLight', 'TextColorDark', 'TextColorTrans', 'BgColorLight', 'BgColorDark', 'BgColorTrans')) {
                if ($null -ne $pos.Settings.$sk) { $script:Settings[$sk] = [string]$pos.Settings.$sk }
            }
            # 구버전 설정(AnomOff 단일) 이전
            if ($pos.Settings.AnomOff -and -not $pos.Settings.AnomOffMe) {
                $script:Settings.AnomOffMe = [string]$pos.Settings.AnomOff
                $script:Settings.AnomOffOpp = [string]$pos.Settings.AnomOff
            }
            # 구버전 단일 색 설정 → 테마별 키로 이주
            Convert-LegacyThemeColors
        }
    } catch {}
}
# 설정 패널을 별도 창으로 이사
try {
    $sw2 = [Windows.Markup.XamlReader]::Parse($script:SettingsShellXaml)
    $my.Panel.Children.Remove($my.SettingsPanel)
    $sw2.FindName('SetHost').Content = $my.SettingsPanel
    $my.SettingsPanel.Visibility = 'Visible'
    # 탭 분할: SettingsPanel 자식들을 탭별 패널로 재분배 (탭 추가 = SetTabDefs 배열 + 매핑에 항목 추가가 전부)
    $script:SetTabDefs = @('설정', '닉네임/키/프리셋', '크레딧')
    $tabMap = @{ TbNickL = 1; TbKeyScanL = 1; TbKeyCloseL = 1; TbKeyExitL = 1; TbPresetL = 1; TxPreset = 1; CmbPreset = 1; TbSizeTgtL = 0; TbScaleL = 0
                 TbCrTitle = 2; LnkRepo = 2; TbSrcL = 2; LnkSource = 2; TbCrSrc2 = 2; TbCrOcrL = 2; LnkOcr = 2; TbCrOcr2 = 2; TbCrLicL = 2; TbCrLic1 = 2; TbCrLic2 = 2; TbCrLic3 = 2 }
    $script:SetTabPanels = @()
    $script:SetTabBtns = @()
    $strip = $sw2.FindName('SetTabStrip')
    for ($ti = 0; $ti -lt $script:SetTabDefs.Count; $ti++) {
        $tp = New-Object Windows.Controls.StackPanel
        $tp.Visibility = 'Collapsed'
        $script:SetTabPanels += $tp
        $tb = New-Object Windows.Controls.TextBlock
        $tb.Text = [string]$script:SetTabDefs[$ti]
        $tb.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
        $tb.FontSize = 12.5
        $tb.FontWeight = [Windows.FontWeights]::Bold
        $tb.Padding = New-Object Windows.Thickness 0, 1, 16, 2
        $tb.Cursor = [Windows.Input.Cursors]::Hand
        $tb.Tag = $ti
        $tb.Add_MouseLeftButtonDown({ $args[1].Handled = $true; Select-SetTab ([int]$args[0].Tag) })
        $script:SetTabBtns += $tb
        $null = $strip.Children.Add($tb)
    }
    # 탭 스트립 오른쪽 '종료' - 탭처럼 보이지만 버튼: 확인 후 오버레이 종료
    $tbExit = New-Object Windows.Controls.TextBlock
    $tbExit.Text = '종료'
    $tbExit.FontFamily = New-Object Windows.Media.FontFamily 'Malgun Gothic'
    $tbExit.FontSize = 12.5
    $tbExit.FontWeight = [Windows.FontWeights]::Bold
    $tbExit.Opacity = 0.55
    $tbExit.Padding = New-Object Windows.Thickness 0, 1, 0, 2
    $tbExit.Margin = New-Object Windows.Thickness 6, 0, 0, 0
    $tbExit.Cursor = [Windows.Input.Cursors]::Hand
    $tbExit.ToolTip = '오버레이 종료'
    [Windows.Controls.ToolTipService]::SetInitialShowDelay($tbExit, 0)
    $tbExit.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $r = [Windows.MessageBox]::Show($script:SettingsWin, '오버레이를 종료할까요?', '종료', 'YesNo', 'Question')
        if ("$r" -eq 'Yes') { $script:MyBox.Win.Close() }
    })
    $null = $strip.Children.Add($tbExit)
    $my | Add-Member -NotePropertyName SetExit -NotePropertyValue $tbExit -Force
    $kids = @()
    foreach ($k in $my.SettingsPanel.Children) { $kids += $k }
    $my.SettingsPanel.Children.Clear()
    $cur = 0
    foreach ($k in $kids) {
        $ki = Get-SetTabIndex $k $tabMap
        if ($ki -ge 0) { $cur = $ki }
        $null = $script:SetTabPanels[$cur].Children.Add($k)
    }
    foreach ($tp in $script:SetTabPanels) { $null = $my.SettingsPanel.Children.Add($tp) }
    $my | Add-Member -NotePropertyName SetTabs -NotePropertyValue $script:SetTabBtns -Force
    $my | Add-Member -NotePropertyName SetRoot -NotePropertyValue ($sw2.FindName('SetRoot')) -Force
    $my | Add-Member -NotePropertyName SetTitle -NotePropertyValue ($sw2.FindName('SetTitle')) -Force
    if ($script:AppVer) { $sw2.FindName('SetTitle').Text = '⚙ 설정  ' + $script:AppVer }
    $my | Add-Member -NotePropertyName SetClose -NotePropertyValue ($sw2.FindName('SetClose')) -Force
    $sw2.FindName('SetClose').Add_MouseLeftButtonDown({ $args[1].Handled = $true; $script:SettingsWin.Hide() })
    $sw2.Add_MouseLeftButtonDown({ try { $script:SettingsWin.DragMove() } catch {} })
    # 설정 창 위에서도 Ctrl+휠 크기 조절
    $sw2.Add_PreviewMouseWheel({
        if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) {
            $args[1].Handled = $true
            $step = $(if ($args[1].Delta -gt 0) { 0.05 } else { -0.05 })
            Set-UiScale ([double]$script:Settings.UiScale + $step)
        }
    })
    $script:SettingsWin = $sw2
    Select-SetTab $script:SetTabIdx
} catch {}

Apply-Theme $my
Apply-Scale $my
Update-HelpTexts
Update-BasisLabels
if (-not $script:HasSavedPos) {
    Set-MyBoxDefaultPos
    $script:NeedDefaultPos = $true   # 내용이 채워져 실제 높이가 나오면 한 번 더 맞춘다
}
# 닉네임 미설정 상태면 박스에 입력칸 표시
if (-not $script:Nickname -or $script:Nickname -eq '여기에닉네임') {
    $my.SetupPanel.Visibility = 'Visible'
}

function Update-Overlay {
    # 닉네임 미설정(첫 실행/초기화) 상태 - 조회 없이 안내만
    if (-not $script:Nickname -or $script:Nickname -eq '여기에닉네임') {
        $my.TbName.Text = '전적 오버레이'
        $my.TbRank.Text = '닉네임을 입력해 주세요'
        $my.TbGame.Text = ''
        foreach ($t in @($my.TbGoal, $my.TbStat, $my.TbStat2, $my.TbStat3, $my.TbStat4, $my.TbStat5)) { if ($t) { $t.Text = '' } }
        try { $my.SparkCanvas.Children.Clear() } catch {}
        # 미설정 상태에서는 입력칸이 항상 보여야 함
        if ($my.SetupPanel.Visibility -ne 'Visible') { $my.SetupPanel.Visibility = 'Visible' }
        return
    }
    if ($script:NetBusy) { return }   # 갱신 중 타이머/버튼 재진입 방지
    $script:NetBusy = $true
    try {
        $d = Get-OverlayData
        $script:LastData = $d
        Set-StatWindow $my $d
        if ($script:NeedDefaultPos) { $script:NeedDefaultPos = $false; Set-MyBoxDefaultPos; Save-Pos }
        # 새 판이 반영되면 토스트 알림
        if ($script:Settings.Toast -and $script:AnnouncedCount -ge 0 -and $script:TodayCount -gt $script:AnnouncedCount -and @($script:TodaySeq).Count -gt 0) {
            $lastRank = $script:TodaySeq[$script:TodaySeq.Count - 1]
            $txt = '{0}위' -f $lastRank
            $pos = ($lastRank -le 2)
            $mag = 0
            if ($null -ne $script:LastShownPt -and $null -ne $d.CurPt) {
                $delta = $d.CurPt - $script:LastShownPt
                if ($delta -ge 0) { $txt += "  ▲$delta" } else { $txt += "  ▼$(-$delta)" }
                $pos = ($delta -ge 0)
                $mag = [Math]::Abs($delta)
            }
            Show-DeferredToast $txt $pos $(if ($pos) { 'up' } else { 'down' }) $mag
            $script:GameToastFired = $true
        }
        if ($script:TodayCount -ge 0) { $script:AnnouncedCount = $script:TodayCount }
        if ($null -ne $d.CurPt) { $script:LastShownPt = $d.CurPt }
        # 목표 달성 축하 (기준 구간당 1회 - '오늘 0시' 기준이면 하루 1회, '실행 시점' 기준이면 세션 1회)
        $dg = [int]$script:Settings.DailyGoal
        $sbP = [string]$script:Settings.SessionBase
        $period = [string]$(if ($sbP -eq 'session') { "s$($script:SessionStartMs)" } elseif ($sbP -eq 'custom') { "c$($script:BaseMsUsed)" } else { [DateTime]::Today.ToString('yyyy-MM-dd') })
        if ($dg -gt 0 -and $d.Diff -ge $dg -and $script:GoalCelebrated -ne $period) {
            $script:GoalCelebrated = $period
            Show-DeferredToast "$(Get-BasisLabel 'base') 목표 +$dg pt 달성! 🎉" $true 'up' 60
            $script:GameToastFired = $true
        }
    } catch {
        $my.TbName.Text = '전적 오버레이'
        $my.TbRank.Text = '불러오기 실패'
        $my.TbGame.Text = "$($_.Exception.Message)"
        $my.TbStat.Text = ''
        $my.TbStat2.Text = ''
        $my.TbStat3.Text = ''
        $my.TbStat4.Text = ''
    } finally { $script:NetBusy = $false }
}

# --- 상대 박스 ---
# 스캔 프로세스가 오버레이가 가린 부분을 건너뛰도록 실시간 좌표 전달 (내 박스 + 이미 띄워진 상대 박스)
function Write-ScanBoxFile {
    try {
        $w0 = $script:MyBox.Win
        $rect = @{
            X = [double]$w0.Left * $script:DpiScale
            Y = [double]$w0.Top * $script:DpiScale
            W = [math]::Max(220, [double]$w0.ActualWidth) * $script:DpiScale
            H = [math]::Max(80, [double]$w0.ActualHeight) * $script:DpiScale
        }
        $opp = @()
        foreach ($k in @($script:OppWindows.Keys)) {
            $ow = $script:OppWindows[$k].Win
            if (-not $ow.IsVisible) { continue }
            $opp += @{
                X = [double]$ow.Left * $script:DpiScale
                Y = [double]$ow.Top * $script:DpiScale
                W = [math]::Max(220, [double]$ow.ActualWidth) * $script:DpiScale
                H = [math]::Max(80, [double]$ow.ActualHeight) * $script:DpiScale
            }
        }
        $rect.Opp = $opp
        # 방 추정 (OCR 실패 시 폴백): 수동 설정 > 내 주력 모드 > 내 단위 기반
        $guess = 0
        if ([string]$script:Settings.MyStableMode -match '^\d+$') { $guess = [int]$script:Settings.MyStableMode }
        elseif ($script:MyDomMode) { $guess = [int]$script:MyDomMode }
        else {
            $mj = ([int][math]::Floor([int]$script:CurLvlId / 100)) % 100
            $guess = switch ($mj) { 4 { 12 } 5 { 12 } 6 { 16 } default { 9 } }
        }
        $rect.Room = $guess
        ConvertTo-Json -InputObject $rect -Depth 4 | Out-File (Join-Path $script:DataDir 'scan-box.json') -Encoding utf8
    } catch {}
}

# F8: 스캔을 별도 프로세스에서 실행 (UI는 계속 반응) - 완료는 ScanPollTimer가 감지
function Update-Opponents {
    if (-not $script:OcrOk) { return }
    if ($script:ScanProc -and -not $script:ScanProc.HasExited) { return }   # 이미 스캔 중
    Close-Opponents
    Show-ScanIndicator
    $resFile = Join-Path $script:DataDir 'scan-result.json'
    try { Remove-Item $resFile -Force -ErrorAction SilentlyContinue } catch {}
    Write-ScanBoxFile
    $script:ScanShownWrite = $null
    $script:ScanBoxRefresh = 0
    $script:ScanStopping = $false
    $script:OppClosed = @{}   # 새 스캔 시작 - 이전에 닫은 박스 제한 해제
    try { Remove-Item (Join-Path $script:DataDir 'scan-stop.flag') -Force -ErrorAction SilentlyContinue } catch {}
    # 스캔 로그 2세대 보존 - 실패한 스캔을 다음 스캔이 덮어써서 사후 분석이 불가능하던 문제 방지
    try {
        $lg = Join-Path $script:DataDir 'scan-log.txt'
        if (Test-Path $lg) {
            $l1 = Join-Path $script:DataDir 'scan-log.1.txt'
            $l2 = Join-Path $script:DataDir 'scan-log.2.txt'
            if (Test-Path $l1) { Move-Item $l1 $l2 -Force }
            Move-Item $lg $l1 -Force
        }
    } catch {}
    $script:ScanStartTime = Get-Date
    $script:ScanProc = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ScanOnce'
    $script:ScanPollTimer.Start()
}

# 스캔 결과(JSON)로 상대 박스 표시
function Show-OpponentResult {
    param($Entries)
    # 결과에서 빠진 상대의 박스는 정리 (부분 표시 후 근접 교체로 다른 계정이 된 경우)
    $keep = @{}
    foreach ($o in $Entries) { $keep[[string]$o.Id] = $true }
    foreach ($k in @($script:OppWindows.Keys)) {
        if (-not $keep.ContainsKey($k)) {
            try { $script:OppWindows[$k].Win.Close() } catch {}
            $script:OppWindows.Remove($k)
        }
    }
    foreach ($o in $Entries) {
        $d = $o.Data
        if (-not $d) { continue }
        $key = [string]$o.Id
        # 사용자가 ✕로 닫은 박스는 이번 스캔 동안 다시 띄우지 않음
        if ($script:OppClosed -and $script:OppClosed.ContainsKey($key)) { continue }
        # 이미 안정단까지 채워 표시한 상대를 부분 데이터로 되돌리지 않음 (워커 결과 유실/깜박임 방지)
        $old = $script:OppCache[$key]
        $oldFull = $false
        try { $oldFull = [bool]$old.StablePhase } catch {}
        $newFull = $false
        try { $newFull = [bool]$d.StablePhase } catch {}
        if ($old -and $oldFull -and -not $newFull) { $d = $old }
        $script:OppCache[$key] = $d
        if (-not $script:OppWindows.ContainsKey($key)) {
            $box = New-StatWindow $OppXaml
            $bw = $box.Win
            $bw.Tag = $key
            $script:OppWindows[$key] = $box
            Apply-Theme $box
            Apply-Scale $box
            $box.BtnCloseOpp.ToolTip = '이 박스 닫기'
        }
        $box = $script:OppWindows[$key]
        Set-StatWindow $box $d
        $bw = $box.Win
        # 좌/우 어느 쪽에 붙일지는 박스 폭을 알아야 정해진다 - 화면 밖에서 먼저 띄워 실측
        if (-not $bw.IsVisible) {
            $bw.Left = -20000
            $bw.Show()
        }
        $bw.UpdateLayout()
        $boxW = [double]$bw.ActualWidth
        if ($boxW -le 0) { $boxW = 460 }
        # 기준은 주 모니터가 아니라 게임 화면 영역 (창모드·보조 모니터·모니터 걸침 대응)
        $g = Get-GameRectDip
        $plateX = $o.X / $script:DpiScale
        # 명패는 프로필 그림 아래에 있으므로, 박스 위쪽이 프로필 상단과 맞도록 그만큼 올린다
        $dipY = $o.Y / $script:DpiScale - $g.H * 0.11
        # 상단·오른쪽 자리(게임 화면 오른쪽 절반)는 명패 왼쪽에, 왼쪽 자리는 프로필을 비켜 오른쪽에
        if (($plateX - $g.X) -gt $g.W * 0.5) { $dipX = $plateX - $boxW - $g.W * 0.012 } else { $dipX = $plateX + $g.W * 0.057 }
        if ($dipX + $boxW -gt $g.X + $g.W) { $dipX = $g.X + $g.W - $boxW }
        if ($dipX -lt $g.X) { $dipX = $g.X }
        if ($dipY -gt $g.Y + $g.H - 110) { $dipY = $g.Y + $g.H - 110 }
        if ($dipY -lt $g.Y) { $dipY = $g.Y }
        $bw.Left = $dipX
        $bw.Top = $dipY
    }
}

# 안정단 미계산 상대를 별도 워커 프로세스로 병렬 계산 요청 (스캔과 독립 - 탐색을 막지 않음)
function Request-StableFill {
    param($Entries)
    if (-not [bool]$script:Settings.Stable) { return }
    $room = 0
    $sawMy = $true
    $need = @()
    foreach ($e in $Entries) {
        if ($null -ne $e.Room) { $room = [int]$e.Room }
        if ($null -ne $e.SawMy) { $sawMy = [bool]$e.SawMy }
        $key = [string]$e.Id
        if ($script:OppClosed -and $script:OppClosed.ContainsKey($key)) { continue }
        $full = $false
        try { $full = [bool]$e.Data.StablePhase } catch {}
        $cachedFull = $false
        try { $cachedFull = [bool]$script:OppCache[$key].StablePhase } catch {}
        if (-not $full -and -not $cachedFull -and -not $script:StableReq.ContainsKey($key)) { $need += $key }
    }
    if ($need.Count -eq 0) { return }
    foreach ($k in $need) { $script:StableReq[$k] = Get-Date }
    $sm = $(if ($sawMy) { '1' } else { '0' })
    $null = Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-StableOnce', "$room", $sm, ($need -join '.')
    $script:StablePollTimer.Start()
}

# 스캔 중 표시 (펄스 애니메이션)
function Show-ScanIndicator {
    Hide-ScanIndicator
    try {
        $x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize" Cursor="Hand">
  <Border CornerRadius="10" Background="#D8202433" Padding="16,9">
    <StackPanel>
      <TextBlock x:Name="TbScanMain" Text="🔍 상대 스캔 중... 0초" FontFamily="Malgun Gothic" FontSize="16" FontWeight="ExtraBold" Foreground="#FFF2F4F8"/>
      <TextBlock x:Name="TbScanSub" Text="" FontFamily="Malgun Gothic" FontSize="11.5" FontWeight="Bold" Foreground="#FFAAB4C4" Margin="1,3,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@
        $iw = [Windows.Markup.XamlReader]::Parse($x)
        $est = [int]$script:LastScanSecs
        if ($est -le 0) { $est = 50 }
        $iw.FindName('TbScanSub').Text = "보통 약 $est`초 · 클릭하면 여기까지 결과로 중지"
        $iw.Left = $script:MyBox.Win.Left
        $iw.Top = $script:MyBox.Win.Top - 64
        if ($iw.Top -lt 0) { $iw.Top = $script:MyBox.Win.Top + 150 }
        # 1차 클릭 = 우아한 중지(탐색만 멈추고 찾은 사람 안정단은 채운 뒤 종료), 2차 클릭 = 즉시 종료
        $iw.Add_MouseLeftButtonDown({
            try {
                if (-not $script:ScanStopping) {
                    $script:ScanStopping = $true
                    New-Item -ItemType File (Join-Path $script:DataDir 'scan-stop.flag') -Force | Out-Null
                    if ($script:ScanIndicator) {
                        try {
                            $script:ScanIndicator.FindName('TbScanMain').Text = '🔍 스캔 마무리 중...'
                            $script:ScanIndicator.FindName('TbScanSub').Text = '한 번 더 클릭하면 즉시 종료 (안정단은 따로 채워짐)'
                        } catch {}
                    }
                } elseif ($script:ScanProc -and -not $script:ScanProc.HasExited) {
                    $script:ScanProc.Kill()
                }
            } catch {}
        })
        $iw.Show()
        $an = New-Object Windows.Media.Animation.DoubleAnimation
        $an.From = 0.35; $an.To = 1
        $an.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(550))
        $an.AutoReverse = $true
        $an.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $iw.BeginAnimation([Windows.UIElement]::OpacityProperty, $an)
        $script:ScanIndicator = $iw
    } catch {}
}

function Hide-ScanIndicator {
    if ($script:ScanIndicator) {
        try { $script:ScanIndicator.Close() } catch {}
        $script:ScanIndicator = $null
    }
}

function Close-Opponents {
    foreach ($k in @($script:OppWindows.Keys)) {
        try { $script:OppWindows[$k].Win.Close() } catch {}
    }
    $script:OppWindows.Clear()
}

$win.Add_Closing({
    Save-Pos
    Close-Opponents
})

# 내 전적 갱신 타이머
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([math]::Max(15, $RefreshSeconds))
$timer.Add_Tick({ Update-Overlay })
$timer.Start()

# 상대 자동 스캔 타이머
if ($AutoScanMinutes -gt 0) {
    $scanTimer = New-Object Windows.Threading.DispatcherTimer
    $scanTimer.Interval = [TimeSpan]::FromMinutes([math]::Max(1, $AutoScanMinutes))
    $scanTimer.Add_Tick({ Update-Opponents })
    $scanTimer.Start()
}

# 백그라운드 스캔 프로세스 감시
$script:ScanProc = $null
$script:ScanStartTime = $null
$script:ScanIndicator = $null
$script:ScanStopping = $false
$script:OppClosed = @{}          # 사용자가 ✕로 개별 닫은 상대 박스 (이번 스캔 동안 재표시 금지)
$script:LastScanSecs = 50
$script:ScanShownWrite = $null   # 부분 결과 파일에서 마지막으로 표시한 시점
$script:ScanBoxRefresh = 0       # 상대 박스가 새로 뜬 뒤 scan-box.json 재기록 횟수
$scanPollTimer = New-Object Windows.Threading.DispatcherTimer
$scanPollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$scanPollTimer.Add_Tick({
    if (-not $script:ScanProc) {
        $script:ScanPollTimer.Stop()
        Hide-ScanIndicator
        return
    }
    if (-not $script:ScanProc.HasExited) {
        # 경과 시간 표시 갱신 (중지는 사용자가 인디케이터 클릭으로, 마무리 중 문구는 덮지 않음)
        if ($script:ScanStartTime) {
            $sec = [int]((Get-Date) - $script:ScanStartTime).TotalSeconds
            if ($script:ScanIndicator -and -not $script:ScanStopping) {
                try { $script:ScanIndicator.FindName('TbScanMain').Text = "🔍 상대 스캔 중... $sec`초" } catch {}
            }
            # 비정상 상황 안전망 (999초)
            if ($sec -gt 999) { try { $script:ScanProc.Kill() } catch {} }
        }
        # 스캔이 끝나기 전에도 확정된 상대는 즉시 표시 (자식이 찾는 즉시 저장하는 부분 결과 감지)
        try {
            $resFile = Join-Path $script:DataDir 'scan-result.json'
            if (Test-Path $resFile) {
                $wt = (Get-Item $resFile).LastWriteTimeUtc
                if ($wt -ne $script:ScanShownWrite) {
                    $entries = @(Get-Content $resFile -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ })
                    if ($entries.Count -gt 0) {
                        Show-OpponentResult $entries
                        Request-StableFill $entries
                        $script:ScanShownWrite = $wt
                        # 새로 뜬 박스 좌표를 자식에 전달 - 박스 안 텍스트가 다음 재시도의 OCR 잡음이 되지 않게
                        # (표시 직후엔 레이아웃 전이라 크기가 0일 수 있어 다음 틱에 한 번 더 씀)
                        $script:ScanBoxRefresh = 2
                        if ($script:ScanIndicator -and -not $script:ScanStopping) {
                            try { $script:ScanIndicator.FindName('TbScanSub').Text = "$($entries.Count)명 표시됨 · 클릭하면 여기까지 결과로 중지" } catch {}
                        }
                    }
                }
            }
        } catch {}
        if ($script:ScanBoxRefresh -gt 0) {
            Write-ScanBoxFile
            $script:ScanBoxRefresh--
        }
        return
    }
    $script:ScanProc = $null
    $script:ScanPollTimer.Stop()
    $script:ScanStopping = $false
    try { Remove-Item (Join-Path $script:DataDir 'scan-stop.flag') -Force -ErrorAction SilentlyContinue } catch {}
    $took = 0
    if ($script:ScanStartTime) { $took = [int]((Get-Date) - $script:ScanStartTime).TotalSeconds }
    Hide-ScanIndicator
    $resFile = Join-Path $script:DataDir 'scan-result.json'
    $entries = @()
    try {
        if (Test-Path $resFile) { $entries = Get-Content $resFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    } catch {}
    # PS5.1 ConvertFrom-Json은 배열을 한 덩어리로 반환하므로 반드시 풀어준다
    $entries = @($entries | ForEach-Object { $_ } | Where-Object { $_ })
    if ($entries.Count -eq 0) {
        Show-Toast '상대를 찾지 못했어요 😥' $false
    } else {
        # '보통 N초' 표시는 성공한 스캔의 소요 시간만 반영
        if ($took -ge 5 -and $took -le 300) { $script:LastScanSecs = $took }
        Show-OpponentResult $entries
        Request-StableFill $entries
    }
})
$script:ScanPollTimer = $scanPollTimer

# 안정단 워커(-StableOnce) 결과 수거: stable-<id>.json이 생기는 즉시 해당 박스만 갱신
$script:StableReq = @{}
try { Remove-Item (Join-Path $script:DataDir 'stable-*.json') -Force -ErrorAction SilentlyContinue } catch {}
$stablePollTimer = New-Object Windows.Threading.DispatcherTimer
$stablePollTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$stablePollTimer.Add_Tick({
    $done = @()
    foreach ($k in @($script:StableReq.Keys)) {
        $f = Join-Path $script:DataDir "stable-$k.json"
        if (Test-Path $f) {
            try {
                $d = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($d) {
                    $script:OppCache[$k] = $d
                    if ($script:OppWindows.ContainsKey($k)) { Set-StatWindow $script:OppWindows[$k] $d }
                }
            } catch {}
            try { Remove-Item $f -Force -ErrorAction SilentlyContinue } catch {}
            $done += $k
        } elseif (((Get-Date) - $script:StableReq[$k]).TotalSeconds -gt 240) {
            $done += $k   # 워커 실패/실종 - 포기 (다음 스캔에서 재시도)
        }
    }
    foreach ($k in $done) { $script:StableReq.Remove($k) }
    if ($script:StableReq.Count -eq 0) { $script:StablePollTimer.Stop() }
})
$script:StablePollTimer = $stablePollTimer

# 클립보드 감시: 작혼 기보 링크가 복사되면 모탈 리뷰 페이지 자동 오픈
$script:LastClip = ''
try { $script:LastClip = [Windows.Clipboard]::GetText() } catch {}
$clipTimer = New-Object Windows.Threading.DispatcherTimer
$clipTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
$clipTimer.Add_Tick({
    if (-not $script:Settings.MortalWatch) { return }
    $txt = ''
    try { $txt = [Windows.Clipboard]::GetText() } catch { return }
    if (-not $txt -or $txt -eq $script:LastClip) { return }
    $script:LastClip = $txt
    $t = $txt.Trim()
    $link = $null
    if ($t -match 'paipu=[\w-]+') {
        # 전체 링크가 복사된 경우: http부터 끝까지 사용
        $idx = $t.IndexOf('http')
        if ($idx -ge 0) { $link = $t.Substring($idx).Trim() }
        else { $link = 'https://mahjongsoul.game.yo-star.com/?' + ($t -replace '^.*(paipu=[\w-]+).*$', '$1') }
    } elseif ($t -match '^\d{6}-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(_a\d+)?(_\d+)?$') {
        # UUID만 복사된 경우
        $link = 'https://mahjongsoul.game.yo-star.com/?paipu=' + $t
    }
    if ($link) {
        try { Start-Process ('https://mjai.ekyu.moe/?url=' + [uri]::EscapeDataString($link)) } catch {}
        Show-Toast '🀄 기보 감지! 리뷰 준비 완료 - 실행 버튼만 누르세요' $true
    }
})
$clipTimer.Start()

# 단축키 폴링 (F8 = 스캔, F7 = 상대 박스 닫기)
$script:KeyDown = @{}
$hotkeyTimer = New-Object Windows.Threading.DispatcherTimer
$hotkeyTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$hotkeyTimer.Add_Tick({
    # Ctrl + 0 : 기본 크기 복원 (창 포커스 없이도 동작)
    $ctrl = ([Native]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0
    $zero = (([Native]::GetAsyncKeyState(0x30) -band 0x8000) -ne 0) -or (([Native]::GetAsyncKeyState(0x60) -band 0x8000) -ne 0)
    $z = ($ctrl -and $zero)
    if ($z -and -not $script:KeyDown['ctrl0']) { Set-UiScale 1.0 }
    $script:KeyDown['ctrl0'] = $z
    foreach ($def in @(@('KeyScan', 'scan'), @('KeyClose', 'close'), @('KeyExit', 'exit'))) {
        $vk = $script:VKMap[[string]$script:Settings[$def[0]]]
        if (-not $vk) { $script:KeyDown[$def[1]] = $false; continue }
        $dn = ([Native]::GetAsyncKeyState($vk) -band 0x8000) -ne 0
        $fired = $dn -and -not $script:KeyDown[$def[1]]
        $script:KeyDown[$def[1]] = $dn
        if ($fired) {
            switch ($def[1]) {
                'scan' { Update-Opponents }
                'close' { Close-Opponents }
                'exit' { $win.Close(); return }
            }
        }
    }
})
$hotkeyTimer.Start()

# 게임 프로세스 감시: 게임이 떴다가 종료되면 오버레이도 종료
if ($GameProcName) {
    $script:SawGame = $false
    $gameTimer = New-Object Windows.Threading.DispatcherTimer
    $gameTimer.Interval = [TimeSpan]::FromSeconds(15)
    $gameTimer.Add_Tick({
        $p = Get-Process -Name $GameProcName -ErrorAction SilentlyContinue
        if ($p) { $script:SawGame = $true }
        elseif ($script:SawGame) { $win.Close() }
    }.GetNewClosure())
    $gameTimer.Start()
}

# 창을 먼저 띄우고 데이터는 디스패처 시작 후 로드 (UiPump 덕분에 로딩 중에도 버튼·드래그 동작)
if ($script:Nickname -and $script:Nickname -ne '여기에닉네임') { $my.TbName.Text = $script:Nickname } else { $my.TbName.Text = '전적 오버레이' }
$my.TbRank.Text = '⏳ 전적 불러오는 중...'
$win.Show()
$null = $win.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background, [action] { Update-Overlay })
$app = New-Object Windows.Application
$null = $app.Run($win)
