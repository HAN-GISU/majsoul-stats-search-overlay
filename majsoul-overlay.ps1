# ═══════════════════════════════════════════════════════════
#  작혼 전적 검색 오버레이 (Majsoul Stats Search Overlay)
#  v1.0.1  |  © 2026 HAN-GISU (github.com/HAN-GISU)  |  MIT License
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

Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class Native{[DllImport("user32.dll")]public static extern bool SetProcessDPIAware();[DllImport("user32.dll")]public static extern short GetAsyncKeyState(int vKey);}'
$null = [Native]::SetProcessDPIAware()

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Api = 'https://5-data.amae-koromo.com/api/v2/pl4'
$MajorNames = @{ 1 = '초심'; 2 = '작사'; 3 = '작걸'; 4 = '작호'; 5 = '작성'; 6 = '혼천' }
$MaxPts = @{
    1 = @(20, 80, 200); 2 = @(600, 800, 1000); 3 = @(1200, 1400, 2000)
    4 = @(2800, 3200, 3600); 5 = @(4500, 7500, 9000)
}
$EpochStart = 1262304000000

$script:CachedId = 0
$script:TodayDate = $null
$script:TodayCount = -1
$script:TodaySeq = @()
$script:TodayPts = @()
$script:TodayLvls = @()
$script:BaselinePt = $null
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
    AnomOffMe = ''; AnomOffOpp = ''; AnomCMe = ''; AnomCOpp = ''
    DispOffMe = ''; DispOffOpp = ''
    UiScale = 1.0; SessionBase = 'today'; AnomPct = 20; BadgeDefs = ''; BadgeOn = $true
    MyBasis = 'm1'; OppBasis = 'm1'; KeyScan = 'F8'; KeyClose = 'F7'; KeyExit = 'F10'; DailyGoal = 0
}
$script:OppCache = @{}    # id -> 전적 데이터
$script:OppWindows = @{}  # id -> WPF 창

# ---------------- amae-koromo API ----------------

# UI 스레드가 네트워크 응답을 기다리는 동안에도 메시지 펌프를 돌려 오버레이가 멈추지 않게 하는 헬퍼.
# GUI 프로세스에서만 $script:UiPump가 켜지고, 자식 프로세스(-ScanOnce/-ReportOnce/-DetailOnce)는 기존 동기 방식 그대로.
function Invoke-UiPump {
    param([int]$Ms = 0)
    $end = [DateTime]::UtcNow.AddMilliseconds($Ms)
    do {
        $frame = New-Object Windows.Threading.DispatcherFrame
        $null = [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [Windows.Threading.DispatcherPriority]::Background,
            [action] { $frame.Continue = $false }.GetNewClosure())
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        if ([DateTime]::UtcNow -lt $end) { Start-Sleep -Milliseconds 15 }
    } while ([DateTime]::UtcNow -lt $end)
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
    param($Id, $StartMs, $EndMs)
    foreach ($try in 1..3) {
        try {
            return Invoke-Api "$Api/player_stats/$Id/$StartMs/$EndMs`?mode=$($script:Modes)" 15
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
        Start-Sleep -Milliseconds 80
    }
    return $lo
}

function Get-BasisStart {
    param($Id, $EndMs, [string]$Basis, $Iters = 18)
    switch ($Basis) {
        'base' {
            # 기준 시점(오늘 0시 또는 오버레이 실행 시점) 이후만 집계
            if ([string]$script:Settings.SessionBase -eq 'session') { return [long]$script:SessionStartMs }
            return [DateTimeOffset]::new([DateTime]::Today).ToUnixTimeMilliseconds()
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
    2 = @{ hr = 0.215; dl = 0.135; ryu = 0.47; ri = 0.185; fu = 0.29; dama = 0.10; dp = 6100; dpl = 5700; gs = 0.73; sente = 0.68; tobi = 0.10; wt = 11.9 }
    3 = @{ hr = 0.215; dl = 0.130; ryu = 0.47; ri = 0.185; fu = 0.30; dama = 0.10; dp = 6250; dpl = 5750; gs = 0.74; sente = 0.69; tobi = 0.09; wt = 11.8 }
    4 = @{ hr = 0.210; dl = 0.125; ryu = 0.47; ri = 0.185; fu = 0.30; dama = 0.105; dp = 6350; dpl = 5800; gs = 0.75; sente = 0.70; tobi = 0.085; wt = 11.7 }
    5 = @{ hr = 0.205; dl = 0.118; ryu = 0.47; ri = 0.180; fu = 0.30; dama = 0.11; dp = 6450; dpl = 5850; gs = 0.76; sente = 0.71; tobi = 0.08; wt = 11.6 }
}

# 강조 대상 통계 항목 (고급 설정에 나열되는 순서)
$script:AnomItems = @(
    @{ K = 'hr'; N = '화료율' }, @{ K = 'dl'; N = '방총율' }, @{ K = 'ryu'; N = '유국텐파이율' },
    @{ K = 'ri'; N = '리치율' }, @{ K = 'fu'; N = '후로율' }, @{ K = 'dama'; N = '다마화료율' },
    @{ K = 'dp'; N = '평균타점' }, @{ K = 'dpl'; N = '평균방총점' }, @{ K = 'tobi'; N = '토비율' },
    @{ K = 'gs'; N = '우형리치율' }, @{ K = 'sente'; N = '선제리치율' }, @{ K = 'wt'; N = '평균화료순' }
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

function Get-AnomColor {
    param([string]$K, [int]$Hot, [bool]$IsOpp)
    $m = Get-AnomCMap $IsOpp
    $hex = ''
    if ($m.ContainsKey($K)) { $hex = [string]$(if ($Hot -eq 2) { $m[$K].H } else { $m[$K].L }) }
    if (-not $hex) { $hex = [string]$(if ($Hot -eq 2) { $script:Settings.AnomHigh } else { $script:Settings.AnomLow }) }
    if (-not $hex) { $hex = $(if ($Hot -eq 2) { '#FFE05252' } else { '#FFE0B830' }) }
    return $hex
}

# 0=보통, 1=평균보다 낮음, 2=평균보다 높음
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
    $pct = [double]$script:Settings.AnomPct
    if ($pct -le 0) { $pct = 20 }
    $t = $pct / 100.0
    if ($ratio -ge (1 + $t)) { return 2 }   # 평균보다 높음
    if ($ratio -le (1 - $t)) { return 1 }   # 평균보다 낮음
    return 0
}

# 통계 항목 구조화 (줄 번호/키/값/표시 텍스트)
function Get-StatParts {
    param($Stats, $Ext)
    if (-not $Ext) { return @() }
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
        @{ L = 3; K = 'wt'; V = [double]$Ext.'和了巡数'; T = ('평균화료순 {0:N2}' -f [double]$Ext.'和了巡数') },
        @{ L = 4; K = 'gs'; V = [double]$Ext.'立直好型'; T = ('우형리치율 {0:P1}' -f [double]$Ext.'立直好型') },
        @{ L = 4; K = 'gs2'; V = [double]$Ext.'立直好型2'; T = ('우형2 {0:P1}' -f [double]$Ext.'立直好型2') },
        @{ L = 4; K = 'sente'; V = [double]$Ext.'先制率'; T = ('선제리치율 {0:P1}' -f [double]$Ext.'先制率') }
    )
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
        'base' { return $(if ([string]$script:Settings.SessionBase -eq 'session') { '실행 후' } else { '오늘' }) }
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

# 안정단위 추정 (amae-koromo estimateStableLevel2, 옥남 기준): 기대수지/(4위율*15) - 10
function Get-StableLevel {
    param($Stats)
    $r = @($Stats.rank_rates)
    $s = @($Stats.rank_avg_score)
    if ($r.Count -lt 4 -or $s.Count -lt 4) { return $null }
    if (-not $r[3]) { return @{ Val = 9.0; Text = '작성+' } }
    $uma = @(15, 5, -5, -15)
    $md = @(110, 55, 0, 0)
    $e = 0.0
    for ($i = 0; $i -lt 4; $i++) {
        if ($null -eq $s[$i]) { continue }
        $d = [math]::Ceiling(($s[$i] - 25000) / 1000 + $uma[$i]) + $md[$i]
        $e += $r[$i] * $d
    }
    $v = $e / ($r[3] * 15) - 10
    if ($v -ge 4) { return @{ Val = $v; Text = ('작성{0:N2}' -f ($v - 3)) } }
    return @{ Val = $v; Text = ('작호{0:N2}' -f $v) }
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

# 리포트 팩 생성 (일/주/월/년) - 백그라운드 프로세스에서 호출됨
function Build-ReportPack {
    param([string]$Mode, [DateTime]$Anchor)
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
    } else {
        $s = New-Object DateTime $Anchor.Year, 1, 1
        $bounds = @(); for ($i = 0; $i -le 12; $i++) { $bounds += $s.AddMonths($i) }
        $labels = @(1..12 | ForEach-Object { [string]$_ })
        $title = ('{0}년' -f $s.Year)
    }
    $buckets = @()
    $rcTotal = @(0, 0, 0, 0); $nTotal = 0; $diffTotal = 0
    $prevEff = Get-PtAt $id ([DateTimeOffset]::new($bounds[0]).ToUnixTimeMilliseconds())
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
    return @{ Mode = $Mode; Anchor = $s.ToString('yyyy-MM-dd'); Title = $title; N = $nTotal; Diff = $diffTotal; RankCounts = $rcTotal; Seq = @(); Pts = @(); Buckets = $buckets; StartLvl = $startLvl; StartPt = $startPt; EndLvl = $curLvlId; EndPt = $endPt }
}

# 스트릭: 연대율 기준 — 1·2위 = 승리(연승), 4위 = 라스(연속 라스)
function Get-StreakText {
    param($Seq)
    if ($Seq.Count -lt 2) { return '' }
    $last = $Seq[$Seq.Count - 1]
    if ($last -le 2) {
        $n = 0
        for ($i = $Seq.Count - 1; $i -ge 0 -and $Seq[$i] -le 2; $i--) { $n++ }
        if ($n -ge 2) { return "🔥${n}연승" }
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
    $todayMidnight = [DateTimeOffset]::new([DateTime]::Today).ToUnixTimeMilliseconds()
    $nowPlus = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeMilliseconds()
    # 기준 시점: 오늘 0시 또는 오버레이 실행 시점
    $baseMs = $todayMidnight
    if ([string]$script:Settings.SessionBase -eq 'session') { $baseMs = [long]$script:SessionStartMs }

    if ($script:TodayDate -ne [DateTime]::Today) {
        $script:TodayDate = [DateTime]::Today
        $script:TodayCount = -1
        $script:TodaySeq = @()
        $script:TodayPts = @()
        $script:TodayLvls = @()
        $script:AnnouncedCount = -1
        $script:BaselinePt = $null
        $script:BaselineLvl = $null
        $script:GoalCelebrated = $null
    }

    $statStart = Get-BasisStart $id $nowPlus $script:Settings.MyBasis
    $stats = Get-RangeStats $id $statStart $nowPlus
    if (-not $stats) { throw '전적 조회 실패' }
    # 랭크/점수는 통계 기준과 무관하게 항상 전체 기간 기준 (승단 즉시 반영)
    $fullStats = $stats
    if ($statStart -ne $EpochStart) {
        $f = Get-RangeStats $id $EpochStart $nowPlus
        if ($f) { $fullStats = $f }
    }
    # 통산 통계(화료율 등)는 잘 안 변하므로 10분에 한 번만 조회
    if ($null -eq $script:ExtCache -or ([DateTime]::Now - $script:ExtCacheTime).TotalSeconds -gt 600) {
        $script:ExtCache = Invoke-Api "$Api/player_extended_stats/$id/$statStart/$nowPlus`?mode=$($script:Modes)" 15
        $script:ExtCacheTime = [DateTime]::Now
    }
    $ext = $script:ExtCache

    # 오늘 0시 시점 점수/단위 (오늘 변동 계산용)
    if ($null -eq $script:BaselinePt) {
        $before = Get-RangeStats $id $EpochStart $baseMs
        if ($before) {
            $effB = Get-EffectiveLevel $before.level
            $script:BaselinePt = $effB.Pt
            $script:BaselineLvl = $effB.Id
        } else {
            $effB = Get-EffectiveLevel $fullStats.level
            $script:BaselinePt = $effB.Pt
            $script:BaselineLvl = $effB.Id
        }
    }

    $today = Get-RangeStats $id $baseMs $nowPlus
    $todayCount = 0
    if ($today) { $todayCount = $today.count }
    if ($todayCount -ne $script:TodayCount) {
        if ($todayCount -eq 0) {
            $script:TodaySeq = @()
            $script:TodayCount = 0
        } else {
            $seq = @(Get-RankSequence $id $baseMs $nowPlus 0)
            # 복원된 순위 개수가 실제 판 수와 일치할 때만 반영 (중간 조회 실패 시 다음 갱신 때 재시도)
            if ($seq.Count -eq $todayCount) {
                $script:TodaySeq = @($seq | ForEach-Object { $_.Rank })
                $script:TodayPts = @($seq | ForEach-Object { $_.Pt })
                $script:TodayLvls = @($seq | ForEach-Object { $_.Lvl })
                $script:TodayCount = $todayCount
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
    $stable = Get-StableLevel $stats
    $suffix = ''
    $myColorVal = $null
    if ($stable) {
        $suffix = '  안정 ' + $stable.Text + ' (' + (Get-BasisLabel $script:Settings.MyBasis) + ' 기준 · ' + $stats.count + '국)'
        $myColorVal = $stable.Val
    }
    $myBadges = Get-StyleBadges $fullStats $ext

    # 메인 박스 그래프: 오늘 누적 수지 (승단/강단 넘어도 이어짐)
    $cumSeries = @(Get-CumSeries ([int]$script:BaselineLvl) $script:BaselinePt $script:TodayLvls $script:TodayPts)

    # 승단 카운트다운 + 오늘 목표
    $goalLine = ''
    $majC = ([int][math]::Floor($curLvl / 100)) % 100
    $minC = [int]($curLvl % 100)
    if ($majC -lt 6 -and $MaxPts.ContainsKey($majC)) {
        $remain = $MaxPts[$majC][$minC - 1] - $curPt
        $goalLine = "승단까지 ${remain}pt"
        $rates = @($stats.rank_rates)
        if ($stable -and $rates.Count -ge 4 -and $rates[3]) {
            $e = ($stable.Val + 10) * $rates[3] * 15   # 국당 기대수지 (옥남 근사)
            if ($e -gt 0.5) { $goalLine += ' (약 {0}국)' -f [math]::Ceiling($remain / $e) }
        }
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
    [pscustomobject]@{
        Name     = $stats.nickname
        NameSuffix = $suffix
        Badges = $myBadges
        NameColorVal = $myColorVal
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
        GameLine = '전적 오늘 0국'
        StatParts = (Get-StatParts $stats $ext)
        RankMajor = (([int][math]::Floor($curLvl / 100)) % 100)
        IsOpp = $false
    }
}

function Get-OpponentData {
    param($Id)
    if ($script:OppCache.ContainsKey("$Id")) { return $script:OppCache["$Id"] }
    $nowPlus = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeMilliseconds()
    $oppBasis = [string]$script:Settings.OppBasis
    $statStart = Get-BasisStart $Id $nowPlus $oppBasis -Iters 11
    $stats = Get-RangeStats $Id $statStart $nowPlus
    if (-not $stats) { return $null }
    # 최소 표본 확보: 기간 내 국수가 부족하면 더 긴 기간으로 순차 확장
    $finalBasis = $oppBasis
    $minN = [int]$script:Settings.OppMinN
    if ($minN -gt 0 -and $oppBasis -match '^(m1|m3|m6|y1)$') {
        $ladder = @('m1', 'm3', 'm6', 'y1', 'all')
        $li = [Array]::IndexOf($ladder, $oppBasis)
        while ([int]$stats.count -lt $minN -and $li -lt $ladder.Count - 1) {
            $li++
            $finalBasis = $ladder[$li]
            $statStart = Get-BasisStart $Id $nowPlus $finalBasis -Iters 11
            $s2 = Get-RangeStats $Id $statStart $nowPlus
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
    try { $ext = Invoke-Api "$Api/player_extended_stats/$Id/$statStart/$nowPlus`?mode=$($script:Modes)" 15 } catch {}
    $effOpp = Get-EffectiveLevel $fullStats.level
    $rank = Get-RankLine -LvlId ([int]$effOpp.Id) -Cur ([int]$effOpp.Pt) -BasePt $null
    $statParts = Get-StatParts $stats $ext
    $stable = Get-StableLevel $stats
    $suffix = ''
    $colorVal = $null
    if ($stable) {
        $bLabel = Get-BasisLabel $finalBasis
        if ($finalBasis -ne $oppBasis) { $bLabel = (Get-BasisLabel $oppBasis) + '→' + $bLabel }
        $suffix = '  안정 ' + $stable.Text + ' (' + $bLabel + ' 기준 · ' + $stats.count + '국)'
        $colorVal = $stable.Val
    }
    $badges = Get-StyleBadges $fullStats $ext
    $gameLine = '전적 {0}국  평균순위 {1:N2}' -f $stats.count, $stats.avg_rank
    $d = [pscustomobject]@{
        Name     = $stats.nickname
        NameSuffix = $suffix
        Badges = $badges
        NameColorVal = $colorVal
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
    }
    $script:OppCache["$Id"] = $d
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

function Get-ScreenCapture {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
    $g.Dispose()
    return $bmp
}

# 전체 화면 1.6배 확대 스캔
function Get-FullTokens {
    param($Bmp)
    $maxDim = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    $scale = [math]::Min(1.6, [math]::Min($maxDim / $Bmp.Width, $maxDim / $Bmp.Height))
    $full = New-ResizedBitmap $Bmp $scale
    $out = New-Object Collections.ArrayList
    foreach ($t in (Invoke-OcrBitmap $full)) {
        $null = $out.Add(@{ Text = $t.Text; X = ($t.X / $scale); Y = ($t.Y / $scale); Src = 'f' })
    }
    $full.Dispose()
    return $out
}

# 상대 명패 정밀 스캔 - 좁은 영역을 크게 확대할수록 인식률이 크게 오름
function Get-PlateTokens {
    param($Bmp, [int]$Pass = 0)
    $out = New-Object Collections.ArrayList
    # @(x, y, w, h, 확대배율) - 이름표 주변만 좁게 자른 고배율 + 여유 있는 저배율(위치 오차 대비)
    $bands = @(
        @(0.000, 0.29, 0.15, 0.12, 8.0),   # 왼쪽 이름표 (정밀)
        @(0.66,  0.07, 0.24, 0.12, 8.0),   # 상단 이름표 (정밀)
        @(0.85,  0.29, 0.15, 0.12, 8.0),   # 오른쪽 이름표 (정밀)
        @(0.15,  0.74, 0.22, 0.14, 8.0),   # 하단(내 자리) 이름표 - 관전 시 4번째 플레이어 (정밀)
        @(0.00,  0.22, 0.24, 0.28, 4.0),   # 왼쪽 (광역)
        @(0.58,  0.03, 0.38, 0.22, 4.0),   # 상단 (광역)
        @(0.76,  0.22, 0.24, 0.28, 4.0),   # 오른쪽 (광역)
        @(0.10,  0.70, 0.32, 0.20, 4.0)    # 하단 (광역)
    )
    # 1차 시도는 정밀(고배율) 밴드만 - 빠르게. 이후 시도에서 광역 밴드까지 확장
    if ($Pass -eq 0) { $bands = @($bands | Where-Object { [double]$_[4] -ge 6.0 }) }
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
                $null = $out.Add(@{ Text = $t.Text; X = ($rx + $t.X / $z); Y = ($ry + $t.Y / $z); Src = 'p' })
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
                  'ハパ', 'ヒピ', 'フプ', 'ヘペ', 'ホポ', 'はぱ', 'ひぴ', 'ふぷ', 'へぺ', 'ほぽ')) {
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

            # 명패 토큰: 가나 크기/탁점·반탁점 혼동 보정 (リインテュノア → リィンデュノア, おリープ → おリーブ)
            if ($Deep) {
                foreach ($src in @($base, $kana, $fixed)) {
                    if (-not $src -or $src -notmatch '[ぁ-ゖァ-ヺ]') { continue }
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

# 앞 2글자를 접두사로 검색해 가장 비슷한 실존 닉을 찾음 (OCR이 뒷부분을 뭉갠 경우 구제)
function Find-ByPrefix {
    param([string]$Raw)
    if ($Raw.Length -lt 3 -or $Raw.Length -gt 16) { return $false }
    $pre = $Raw.Substring(0, 2)
    if ($pre -notmatch '^[぀-ヿ一-鿿]{2}$') {
        # 2번째 글자가 비CJK(오인식 기호 등)면 첫 글자만으로 검색 (貞~照 → 貞)
        if ($Raw.Substring(0, 1) -match '^[぀-ヿ一-鿿]$') { $pre = $Raw.Substring(0, 1) }
        else { return $false }
    }
    $ck = "pre:$pre"
    if (-not $script:NickCache.ContainsKey($ck)) {
        if ($script:ScanQueryLeft -le 0) { return $false }
        $script:ScanQueryLeft--
        try {
            Start-Sleep -Milliseconds 100
            $script:NickCache[$ck] = @(Invoke-RestMethod -Uri "$Api/search_player/$([uri]::EscapeDataString($pre))?limit=100" -TimeoutSec 10)
        } catch { return $false }
    }
    $cands = @($script:NickCache[$ck])
    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-60).ToUnixTimeMilliseconds()
    $best = $null; $bestS = 0.0; $secondS = 0.0
    foreach ($c in $cands) {
        if ($null -eq $c -or $c -is [array]) { continue }
        $nick = $c.nickname -as [string]
        if (-not $nick) { continue }
        $ts = $c.latest_timestamp -as [long]
        if ($null -eq $ts -or ($ts * 1000) -le $cutoff) { continue }
        if ([math]::Abs($nick.Length - $Raw.Length) -gt 2) { continue }
        $sim = Get-StrSimilarity $Raw $nick
        if ($sim -gt $bestS) { $secondS = $bestS; $bestS = $sim; $best = $c }
        elseif ($sim -gt $secondS) { $secondS = $sim }
    }
    # 충분히 비슷하고, 2등과 확실히 차이날 때만 채택
    if ($best -and $bestS -ge 0.55 -and ($bestS - $secondS) -ge 0.08) {
        $null = $script:ScanLog.Add(">>> 유사매칭: $Raw -> $($best.nickname) ({0:N2})" -f $bestS)
        return $best.id
    }
    return $false
}

# 후보 닉네임으로서 그럴듯한지 (OCR 잡음 걸러내기)
function Test-NickPlausible {
    param([string]$T)
    if ($T -match '^[\d.,:%/()\-±▲▼xX×*·。、]+$') { return $false }
    if ($T -imatch '^([a-z0-9])+$') { return $false }
    # 한글 + 라틴/숫자 혼합은 대부분 OCR 잡음
    if ($T -match '[가-힣]' -and $T -match '[A-Za-z0-9]') { return $false }
    # 숫자·기호 비중이 과반이면 잡음
    $bad = ([regex]::Matches($T, '[\d.,:%/()\-_|~`]')).Count
    if ($bad * 2 -gt $T.Length) { return $false }
    return $true
}

function Resolve-Tokens {
    param($Tokens, $FoundMap, [bool]$NoCenter = $false)
    $myNick = $script:Nickname
    $seen = @{}
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

    # 1) 후보 정리 - 중복 제거 (중앙 필터는 순위 화면 감지 후 적용)
    $cands = New-Object Collections.ArrayList
    $dedup = @{}
    $hasRank = $false
    foreach ($tk in $Tokens) {
        $raw = ($tk.Text -replace '\s', '')
        if ($raw -and $script:ScanLogTokens -ne $false) { $null = $script:ScanLog.Add($raw) }
        if (-not $raw -or $raw.Length -lt 2 -or $raw.Length -gt 20) { continue }
        $r = $script:MyBoxRect
        if ($r -and $tk.X -ge $r.X1 -and $tk.X -le $r.X2 -and $tk.Y -ge $r.Y1 -and $tk.Y -le $r.Y2) { continue }
        if ($raw -eq $myNick) { $script:SawMyNick = $true }
        # 'N위M국(…%)'는 내 리포트 패널의 순위 분포 줄 - 순위 화면 마커로 오탐하지 않음
        $rk = ($raw -match '^[1-4](위|位)(?!\d+(국|局))')
        if ($rk) {
            $hasRank = $true
            if (($raw -replace '^[1-4](위|位)', '') -eq $myNick) { $script:SawMyNick = $true }
        }
        if ($dedup.ContainsKey($raw)) { continue }
        $dedup[$raw] = $true
        $null = $cands.Add(@{ Raw = $raw; X = $tk.X; Y = $tk.Y; Src = [string]$tk.Src; Rk = $rk })
    }

    # 순위 화면('N위' 마커)이 아니면 중앙(패산) 토큰 제외
    if (-not $NoCenter -and -not $hasRank) {
        $cands = @($cands | Where-Object {
            -not ($_.X -gt $b.Width * 0.30 -and $_.X -lt $b.Width * 0.70 -and
                  $_.Y -gt $b.Height * 0.28 -and $_.Y -lt $b.Height * 0.72)
        })
    }
    # 순위 화면이면: 화면 맨 위의 순위 묶음(열린 팝업/결과)만 취급 - 뒤에 비치는 다른 판 목록 배제
    if ($hasRank) {
        $minY = [double]::MaxValue
        foreach ($cd in $cands) { if ($cd.Rk -and [double]$cd.Y -lt $minY) { $minY = [double]$cd.Y } }
        $cands = @($cands | Where-Object { $_.Rk -and ([double]$_.Y - $minY) -lt ($b.Height * 0.18) })
    }

    # 2) 우선순위: 순위 화면이면 'N위' 붙은 이름을 화면 위쪽(열린 팝업)부터,
    #    아니면 명패 토큰 → 긴 토큰 (조회 예산을 값어치 있는 곳에)
    if ($hasRank) {
        $ordered = @($cands | Sort-Object @{ Expression = { if ($_.Rk) { 0 } else { 1 } } }, @{ Expression = { $_.Y } }, @{ Expression = { -($_.Raw.Length) } })
    } else {
        $ordered = @($cands | Sort-Object @{ Expression = { if ($_.Src -eq 'p') { 0 } else { 1 } } }, @{ Expression = { -($_.Raw.Length) } })
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
        if ($null -ne $preNear -and $raw.Length -le ([string]$FoundMap[$preNear].Nick).Length) { continue }
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
            if (-not (Test-NickPlausible $t)) { continue }
            if ($seen.ContainsKey($t)) { continue }
            $seen[$t] = $true

            if (-not $script:NickCache.ContainsKey($t)) {
                # 조회 예산 초과 시 새 조회는 생략 (속도 제한 방지)
                if ($script:ScanQueryLeft -le 0) { continue }
                $script:ScanQueryLeft--
                try {
                    Start-Sleep -Milliseconds 100
                    $res = Invoke-RestMethod -Uri "$Api/search_player/$([uri]::EscapeDataString($t))?limit=5" -TimeoutSec 10
                    $id = $false
                    # 후보 순서: 대소문자 정확 일치 → 대소문자 무시 일치(최근 활동 순)
                    $hits = @($res | Where-Object { $_.nickname -ceq $t })
                    $hits += @($res | Where-Object { $_.nickname -ieq $t -and $_.nickname -cne $t } | Sort-Object latest_timestamp -Descending)
                    $cutoff = [DateTimeOffset]::UtcNow.AddDays(-60).ToUnixTimeMilliseconds()
                    foreach ($h in $hits) {
                        $hts = $h.latest_timestamp -as [long]
                        if ($null -ne $hts -and ($hts * 1000) -gt $cutoff) { $id = $h.id; break }
                    }
                    $script:NickCache[$t] = $id
                } catch {
                    $script:ScanLog.Add("!! 조회 실패: $t") | Out-Null
                }
            }
            $id = $false
            if ($script:NickCache.ContainsKey($t)) { $id = $script:NickCache[$t] }
            if ($id) {
                $key = "$id"
                if (-not $FoundMap.ContainsKey($key)) {
                    # 같은 명패 위치에 이미 다른 플레이어가 있으면: 더 긴(완전한) 닉네임이 승리
                    $nearKey = $null
                    foreach ($kv in @($FoundMap.GetEnumerator())) {
                        if ([math]::Abs([double]$kv.Value.X - [double]$tk.X) -lt 240 -and [math]::Abs([double]$kv.Value.Y - [double]$tk.Y) -lt 60) {
                            $nearKey = $kv.Key
                            break
                        }
                    }
                    if ($null -eq $nearKey) {
                        if ($FoundMap.Count -lt 4) {
                            $FoundMap[$key] = @{ Id = $id; Nick = $t; X = $tk.X; Y = $tk.Y }
                            $null = $script:ScanLog.Add(">>> 매칭: $t (id $id)")
                        }
                    } elseif ($t.Length -gt ([string]$FoundMap[$nearKey].Nick).Length) {
                        $FoundMap.Remove($nearKey)
                        $FoundMap[$key] = @{ Id = $id; Nick = $t; X = $tk.X; Y = $tk.Y }
                        $null = $script:ScanLog.Add(">>> 근접 교체: $t (id $id)")
                    } else {
                        $null = $script:ScanLog.Add(">>> 근접 중복 스킵: $t (id $id)")
                    }
                }
                break
            }
        }

        # 변형으로도 못 찾았고 명패에서 읽힌 CJK 토큰이면 접두사 유사매칭 시도 (2단계에서만)
        if ($phase -eq 1 -and $tk.Src -eq 'p' -and $raw -match '^[぀-ヿ一-鿿]{2}') {
            $already = $false
            foreach ($kv in @($FoundMap.GetEnumerator())) {
                if ([math]::Abs([double]$kv.Value.X - [double]$tk.X) -lt 240 -and [math]::Abs([double]$kv.Value.Y - [double]$tk.Y) -lt 60) { $already = $true; break }
            }
            if (-not $already -and $FoundMap.Count -lt 4) {
                $fid = Find-ByPrefix $raw
                if ($fid) {
                    $fkey = "$fid"
                    if (-not $FoundMap.ContainsKey($fkey)) {
                        $FoundMap[$fkey] = @{ Id = $fid; Nick = $raw; X = $tk.X; Y = $tk.Y }
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
    $script:ScanQueryLeft = 60   # 스캔 1회당 최대 조회 수 (속도 제한 방지)
    # 내 오버레이 박스가 가린 영역만 제외 (F8 시점에 부모가 기록한 실시간 좌표, 5분 내 것만 신뢰)
    $script:MyBoxRect = $null
    $script:SawMyNick = $false
    try {
        $rf = Join-Path $PSScriptRoot 'scan-box.json'
        if ((Test-Path $rf) -and ((Get-Date) - (Get-Item $rf).LastWriteTime).TotalMinutes -lt 5) {
            $bx = Get-Content $rf -Raw | ConvertFrom-Json
            if ([double]$bx.W -gt 0 -and [double]$bx.H -gt 0) {
                $script:MyBoxRect = @{
                    X1 = [double]$bx.X - 8; Y1 = [double]$bx.Y - 8
                    X2 = [double]$bx.X + [double]$bx.W + 8
                    Y2 = [double]$bx.Y + [double]$bx.H + 8
                }
            }
        }
    } catch {}
    $found = @{}
    $deadline = (Get-Date).AddSeconds(990)   # 부모의 안전망(999초)보다 조금 먼저 스스로 종료
    $try = 0
    while ($true) {
        # 목표 인원: 화면에 내 닉이 보이면(=내 대국) 3명, 아니면(관전 등) 4명
        $target = 4
        if ($script:SawMyNick) { $target = 3 }
        if ($found.Count -ge $target) { break }
        if ((Get-Date) -ge $deadline) { break }
        if ($try -gt 0) { Start-Sleep -Milliseconds $(if ($try -lt 3) { 500 } else { 2000 }) }
        # 재시도마다 조회 예산 소량 리필 (재시도는 대부분 캐시 히트라 실제 추가 조회는 적음)
        if ($try -gt 0 -and $script:ScanQueryLeft -lt 30) { $script:ScanQueryLeft = 30 }
        # 로그 폭주 방지: 4회차부터는 토큰 원문 생략(매칭 결과 줄만 기록)
        $script:ScanLogTokens = ($try -lt 3)
        $null = $script:ScanLog.Add("===== 시도 $($try + 1) ($(Get-Date -Format 'HH:mm:ss'))")
        $try++
        $prevCount = $found.Count
        $bmp = $null
        try { $bmp = Get-ScreenCapture } catch { continue }
        try {
            $fullT = Get-FullTokens $bmp
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
        if ($bmp) { $bmp.Dispose() }
        # 중간에 강제 종료돼도 과정을 볼 수 있게 시도마다 기록
        try { ($script:ScanLog -join "`r`n") | Out-File (Join-Path $PSScriptRoot 'scan-log.txt') -Encoding utf8 } catch {}
        # 새로 찾은 상대는 즉시 알림 - 사용자가 클릭으로 중지해도 여기까지는 표시됨
        if ($OnProgress -and $found.Count -gt $prevCount) { try { & $OnProgress @($found.Values) } catch {} }
    }
    try { ($script:ScanLog -join "`r`n") | Out-File (Join-Path $PSScriptRoot 'scan-log.txt') -Encoding utf8 } catch {}
    return @($found.Values)
}

# ---------------- 테스트 모드 ----------------

# 내부 테스트: 토큰 시나리오(JSON)를 실제 매칭 파이프라인에 통과시켜 결과 출력
if ($args.Count -ge 2 -and $args[0] -eq '-TestResolve') {
    $sc = Get-Content ([string]$args[1]) -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:Nickname = [string]$sc.MyNick
    $script:SawMyNick = $false
    $script:ScanQueryLeft = 45
    $script:MyBoxRect = $null
    $script:ScanLog = New-Object Collections.ArrayList
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $tokens = New-Object Collections.ArrayList
    foreach ($t in $sc.Tokens) {
        $null = $tokens.Add(@{ Text = [string]$t.T; X = [double]$t.X * $b.Width; Y = [double]$t.Y * $b.Height; Src = [string]$t.S })
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
        $pos = Get-Content (Join-Path $PSScriptRoot 'overlay-pos.json') -Raw | ConvertFrom-Json
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
    Write-Host "(스캔 과정: $PSScriptRoot\scan-log.txt)"
    exit 0
}
if ($args -contains '-ScanOnce') {
    # 오버레이가 띄우는 백그라운드 스캔 프로세스: 결과를 scan-result.json으로 전달
    try {
        $pos = Get-Content (Join-Path $PSScriptRoot 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.OppBasis) { $script:Settings.OppBasis = [string]$pos.Settings.OppBasis }
        if ($pos.Settings.Stable -is [bool]) { $script:Settings.Stable = $pos.Settings.Stable }
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
        if ($null -ne $pos.Settings.OppMinN) { $script:Settings.OppMinN = [int]$pos.Settings.OppMinN }
    } catch {}
    $resPath = Join-Path $PSScriptRoot 'scan-result.json'
    $dataCache = @{}
    # 찾은 상대들의 데이터를 조회해 즉시 저장 - 스캔 도중 중지/강제 종료돼도 여기까지의 상대는 표시됨
    $saveOpps = {
        param($Opps)
        $out = @()
        foreach ($o in $Opps) {
            $key = "$($o.Id)"
            if (-not $dataCache[$key]) { $dataCache[$key] = Get-OpponentData $o.Id }
            if ($dataCache[$key]) {
                $out += [pscustomobject]@{ Id = $key; X = [double]$o.X; Y = [double]$o.Y; Data = $dataCache[$key] }
            }
        }
        ConvertTo-Json -InputObject $out -Depth 6 | Out-File $resPath -Encoding utf8
    }
    $opps = Scan-Opponents -OnProgress $saveOpps
    & $saveOpps $opps
    exit 0
}
$riIdx = [Array]::IndexOf($args, '-ReportOnce')
if ($riIdx -ge 0) {
    # 리포트 데이터 수집 백그라운드 프로세스: -ReportOnce <mode> <yyyy-MM-dd>
    try {
        $pos = Get-Content (Join-Path $PSScriptRoot 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
    } catch {}
    $rMode = [string]$args[$riIdx + 1]
    $rAnchor = [DateTime]::ParseExact([string]$args[$riIdx + 2], 'yyyy-MM-dd', $null)
    $pack = Build-ReportPack $rMode $rAnchor
    ConvertTo-Json -InputObject $pack -Depth 6 | Out-File (Join-Path $PSScriptRoot 'report-result.json') -Encoding utf8
    exit 0
}
$diIdx = [Array]::IndexOf($args, '-DetailOnce')
if ($diIdx -ge 0) {
    # 일간 상세 지표 수집 백그라운드 프로세스: -DetailOnce <yyyy-MM-dd>
    try {
        $pos = Get-Content (Join-Path $PSScriptRoot 'overlay-pos.json') -Raw | ConvertFrom-Json
        if ($pos.Settings.Nickname) { $script:Nickname = [string]$pos.Settings.Nickname }
    } catch {}
    $day = [DateTime]::ParseExact([string]$args[$diIdx + 1], 'yyyy-MM-dd', $null)
    $sMs = [DateTimeOffset]::new($day).ToUnixTimeMilliseconds()
    $eMs = [DateTimeOffset]::new($day.AddDays(1)).ToUnixTimeMilliseconds()
    $ext = $null; $rst = $null
    try {
        $id = Get-PlayerId
        $rst = Get-RangeStats $id $sMs $eMs
        Start-Sleep -Milliseconds 120
        $ext = Invoke-RestMethod -Uri "$Api/player_extended_stats/$id/$sMs/$eMs`?mode=$($script:Modes)" -TimeoutSec 15
    } catch {}
    ConvertTo-Json -InputObject @{ Anchor = $day.ToString('yyyy-MM-dd'); Ext = $ext; St = $rst } -Depth 6 | Out-File (Join-Path $PSScriptRoot 'detail-result.json') -Encoding utf8
    exit 0
}

# ---------------- GUI ----------------

# 중복 실행 방지
$script:InstanceMutex = New-Object Threading.Mutex($false, 'MajsoulOverlayMutex')
if (-not $script:InstanceMutex.WaitOne(0)) { exit }

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

$script:DpiScale = 1.0
try {
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:DpiScale = $g.DpiX / 96.0
    $g.Dispose()
} catch {}

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
        <TextBlock x:Name="TbStat" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbStat2" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbStat3" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <TextBlock x:Name="TbStat4" FontFamily="Malgun Gothic" FontSize="15" FontWeight="Bold" Foreground="#FF16213E"/>
        <Canvas x:Name="SparkCanvas" Height="34" Margin="0,7,0,0" Visibility="Collapsed" ClipToBounds="True"/>
        <TextBlock x:Name="TbHelp" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E"
                   Opacity="0.85" Margin="0,6,0,0" Visibility="Collapsed"/>
        <StackPanel x:Name="SettingsPanel" Margin="0,6,0,0" Visibility="Collapsed">
          <CheckBox x:Name="CbToast" Content="대국 반영 토스트" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" Margin="0,1,0,1"/>
          <CheckBox x:Name="CbMortal" Content="기보 복사 감지 → 모탈 리뷰 열기" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" Margin="0,1,0,1"/>
          <CheckBox x:Name="CbAnom" Content="특이 수치 강조" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" Margin="0,1,0,1"/>
          <StackPanel x:Name="AnomRow" Orientation="Horizontal" Margin="16,2,0,1">
            <TextBlock x:Name="TbAnomModeL" Text="방식 " FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="40"/>
            <ComboBox x:Name="CmbAnomMode" FontFamily="Malgun Gothic" FontSize="12" Width="82">
              <ComboBoxItem Content="깜박임"/>
              <ComboBoxItem Content="색만 변경"/>
            </ComboBox>
            <TextBlock x:Name="TbAnomPctL" Text=" ±" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" ToolTip="단위 평균에서 이만큼 벗어나면 강조" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbAnomPct" FontFamily="Malgun Gothic" FontSize="12" Width="58"/>
            <TextBlock x:Name="TbAnomHighL" Text=" 높음" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="6,0,3,0"/>
            <Border x:Name="SwHigh" Width="20" Height="16" CornerRadius="3" BorderThickness="1" BorderBrush="#88888888" Cursor="Hand"/>
            <TextBlock x:Name="TbAnomLowL" Text=" 낮음" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="6,0,3,0"/>
            <Border x:Name="SwLow" Width="20" Height="16" CornerRadius="3" BorderThickness="1" BorderBrush="#88888888" Cursor="Hand"/>
          </StackPanel>
          <TextBlock x:Name="BtnAdv" Text="   고급 설정 ▾" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85" Margin="16,2,0,1" Cursor="Hand"/>
          <StackPanel x:Name="AdvPanel" Margin="16,2,0,4" Visibility="Collapsed"/>
          <CheckBox x:Name="CbBadge" Content="스타일 배지" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" Margin="0,1,0,1"/>
          <TextBlock x:Name="BtnBadgeAdv" Text="   고급 설정 ▾" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.85" Margin="16,2,0,1" Cursor="Hand"/>
          <StackPanel x:Name="BadgePanel" Margin="16,2,0,4" Visibility="Collapsed"/>
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
          <TextBlock x:Name="TbBasisWarn" Text="⚠ '최근 N국' 기준은 로딩이 오래 걸릴 수 있어요" FontFamily="Malgun Gothic" FontSize="11" FontWeight="Bold" Foreground="#FF16213E" Opacity="0.75" Margin="0,3,0,0"/>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,1">
            <TextBlock x:Name="TbBaseL" Text="기준 시점 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="오늘 전적/수지를 어디서부터 셀지" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbBase" FontFamily="Malgun Gothic" FontSize="12" Width="105">
              <ComboBoxItem Content="오늘 0시부터"/>
              <ComboBoxItem Content="실행 시점부터"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,4,0,1">
            <TextBlock x:Name="TbGoalL" Text="오늘 목표 pt " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <ComboBox x:Name="CmbGoal" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
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
          <StackPanel Orientation="Horizontal" Margin="0,5,0,1">
            <TextBlock x:Name="TbNickL" Text="내 닉네임 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100"/>
            <TextBox x:Name="TxNick" FontFamily="Malgun Gothic" FontSize="12" Width="105" VerticalContentAlignment="Center"/>
            <TextBlock x:Name="BtnNickApply" Text=" 적용" FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Padding="6,0,0,0" Cursor="Hand"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,1">
            <TextBlock x:Name="TbScaleL" Text="박스 크기 " FontFamily="Malgun Gothic" FontSize="12.5" FontWeight="Bold" Foreground="#FF16213E" VerticalAlignment="Center" Width="100" ToolTip="박스 위에서 Ctrl+마우스휠로도 조절" ToolTipService.InitialShowDelay="0"/>
            <ComboBox x:Name="CmbScale" FontFamily="Malgun Gothic" FontSize="12" Width="105"/>
          </StackPanel>
        </StackPanel>
      </StackPanel>
      <TextBlock x:Name="BtnScan" Text="🔍" FontFamily="Malgun Gothic" FontSize="12" FontWeight="Bold" Foreground="#FF16213E"
                 HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-12,-8,0,0" Padding="5,2"
                 Visibility="Collapsed" Cursor="Hand" ToolTip="상대 스캔" ToolTipService.InitialShowDelay="0"/>
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
        TbHelp = $w.FindName('TbHelp')
        SparkCanvas = $w.FindName('SparkCanvas')
        CtrlPanel = $w.FindName('CtrlPanel')
        BtnScan = $w.FindName('BtnScan')
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
        TbAnomPctL = $w.FindName('TbAnomPctL')
        CmbAnomPct = $w.FindName('CmbAnomPct')
        SwHigh = $w.FindName('SwHigh')
        SwLow = $w.FindName('SwLow')
        AnomRow = $w.FindName('AnomRow')
        BtnAdv = $w.FindName('BtnAdv')
        AdvPanel = $w.FindName('AdvPanel')
        CbBadge = $w.FindName('CbBadge')
        BtnBadgeAdv = $w.FindName('BtnBadgeAdv')
        BadgePanel = $w.FindName('BadgePanel')
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
        TbMinNL = $w.FindName('TbMinNL')
        CmbMinN = $w.FindName('CmbMinN')
        TbScaleL = $w.FindName('TbScaleL')
        CmbScale = $w.FindName('CmbScale')
        TbShowL = $w.FindName('TbShowL')
        DispPanel = $w.FindName('DispPanel')
        TbNickL = $w.FindName('TbNickL')
        TxNick = $w.FindName('TxNick')
        BtnNickApply = $w.FindName('BtnNickApply')
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
    foreach ($v in $script:AnomPctOptions) { $null = $box.CmbAnomPct.Items.Add(('{0}%' -f $v)) }
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
            Set-UiScale ([double]$script:Settings.UiScale + $step)
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
    # 마우스 오버 시에만 버튼들(🔍 / ? ⟳ 📋 ⚙ ◐) 표시
    $w.Add_MouseEnter({
        $box.CtrlPanel.Visibility = 'Visible'
        $box.BtnScan.Visibility = 'Visible'
    }.GetNewClosure())
    $w.Add_MouseLeave({
        $box.CtrlPanel.Visibility = 'Collapsed'
        $box.BtnScan.Visibility = 'Collapsed'
    }.GetNewClosure())
    # 🔍 클릭: 상대 스캔 (F8과 동일)
    $box.BtnScan.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        Update-Opponents
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
        if ($b.SettingsPanel.Visibility -eq 'Visible') {
            $b.SettingsPanel.Visibility = 'Collapsed'
        } else {
            $script:SyncingUI = $true
            $b.CbToast.IsChecked = [bool]$script:Settings.Toast
            $b.CbMortal.IsChecked = [bool]$script:Settings.MortalWatch
            $b.CbAnom.IsChecked = [bool]$script:Settings.Anom
            $b.CmbAnomMode.SelectedIndex = $(if ([string]$script:Settings.AnomMode -eq 'static') { 1 } else { 0 })
            $pi = [Array]::IndexOf($script:AnomPctOptions, [int]$script:Settings.AnomPct)
            $b.CmbAnomPct.SelectedIndex = [math]::Max(0, $pi)
            $b.SwHigh.Background = New-Brush ([string]$script:Settings.AnomHigh)
            $b.SwLow.Background = New-Brush ([string]$script:Settings.AnomLow)
            if ($b.AdvPanel.Visibility -eq 'Visible') { Build-AdvPanel $b }
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
            $b.CmbBase.SelectedIndex = $(if ([string]$script:Settings.SessionBase -eq 'session') { 1 } else { 0 })
            $b.CmbMinN.SelectedIndex = [math]::Max(0, [Array]::IndexOf($script:MinNOptions, [int]$script:Settings.OppMinN))
            $si = [Array]::IndexOf($script:ScaleSteps, [double]$script:Settings.UiScale)
            if ($si -lt 0) { $si = 3 }
            $b.CmbScale.SelectedIndex = $si
            $b.CbBadge.IsChecked = [bool]$script:Settings.BadgeOn
            $script:SyncingUI = $false
            Sync-SettingSections
            if ($b.BadgePanel.Visibility -eq 'Visible') { Build-BadgePanel $b }
            $b.SettingsPanel.Visibility = 'Visible'
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
            Update-Overlay
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
        Update-Overlay
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
    # 강조 기준(%) 변경
    $box.CmbAnomPct.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.AnomPct = [int]$script:AnomPctOptions[$s.SelectedIndex]
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
            $args[0].Text = '   고급 설정 ▾'
        } else {
            Build-AdvPanel $b
            $b.AdvPanel.Visibility = 'Visible'
            $args[0].Text = '   고급 설정 ▴'
        }
    })
    # 기준 시점 변경 (오늘 0시 / 실행 시점)
    $box.CmbBase.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        $script:Settings.SessionBase = @('today', 'session')[$s.SelectedIndex]
        if ([string]$script:Settings.SessionBase -eq 'session') { $script:SessionStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        # 기준이 바뀌면 오늘 집계 상태 초기화 후 재조회
        $script:TodayCount = -1
        $script:TodaySeq = @()
        $script:TodayPts = @()
        $script:TodayLvls = @()
        $script:BaselinePt = $null
        $script:BaselineLvl = $null
        $script:AnnouncedCount = -1
        Save-Pos
        Update-Overlay
    })
    # 박스 크기 변경
    $box.CmbScale.Add_SelectionChanged({
        if ($script:SyncingUI) { return }
        $s = $args[0]
        if ($s.SelectedIndex -lt 0) { return }
        Set-UiScale ([double]$script:ScaleSteps[$s.SelectedIndex])
    })
    # 배지 고급 설정 펼치기/접기
    $box.BtnBadgeAdv.Tag = $box
    $box.BtnBadgeAdv.Add_MouseLeftButtonDown({
        $args[1].Handled = $true
        $b = $args[0].Tag
        if ($b.BadgePanel.Visibility -eq 'Visible') {
            $b.BadgePanel.Visibility = 'Collapsed'
            $args[0].Text = '   고급 설정 ▾'
        } else {
            Build-BadgePanel $b
            $b.BadgePanel.Visibility = 'Visible'
            $args[0].Text = '   고급 설정 ▴'
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
    $Box.RootBorder.Background = New-Brush $bg
    foreach ($tb in @($Box.TbName, $Box.TbRank, $Box.TbGoal, $Box.TbGame, $Box.TbStat, $Box.TbStat2, $Box.TbStat3, $Box.TbStat4, $Box.TbHelp,
                      $Box.BtnHelp, $Box.BtnSettings, $Box.BtnTheme, $Box.BtnReport, $Box.BtnScan,
                      $Box.CbToast, $Box.CbMortal, $Box.CbAnom,
                      $Box.TbBasisMyL, $Box.TbBasisOppL, $Box.TbBasisWarn, $Box.BtnRefresh,
                      $Box.TbKeyScanL, $Box.TbKeyCloseL, $Box.TbKeyExitL, $Box.TbGoalL, $Box.TbBaseL, $Box.TbMinNL, $Box.TbScaleL, $Box.TbShowL, $Box.TbNickL, $Box.BtnNickApply,
                      $Box.TbSetupL, $Box.BtnSetupApply, $Box.TbAnomModeL, $Box.TbAnomHighL, $Box.TbAnomLowL, $Box.TbAnomPctL, $Box.BtnAdv, $Box.CbBadge, $Box.BtnBadgeAdv,
                      $Box.TbShowL)) {
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
    Save-Pos
}

function Save-Pos {
    $script:Settings.Nickname = $script:Nickname   # 닉네임은 항상 설정 파일에 보존 (백그라운드 프로세스가 읽음)
    @{ Left = $script:MyBox.Win.Left; Top = $script:MyBox.Win.Top; Theme = $script:Theme; Settings = $script:Settings } |
        ConvertTo-Json | Out-File $script:PosFile -Encoding utf8
}

# 닉네임 변경: 상태 전부 리셋 후 새 닉으로 재조회
function Apply-Nickname {
    param([string]$NewNick)
    $NewNick = ([string]$NewNick).Trim()
    if (-not $NewNick -or $NewNick -eq $script:Nickname) { return }
    $script:Nickname = $NewNick
    $script:PlayerId = 0
    $script:CachedId = 0
    $script:ExtCache = $null
    $script:BasisCache = @{}
    $script:TodayDate = $null    # 다음 갱신 때 오늘 상태 전체 리셋
    $script:LastShownPt = $null
    $script:LastData = $null
    $script:Settings.Nickname = $NewNick
    Save-Pos
    if ($script:MyBox) { $script:MyBox.SetupPanel.Visibility = 'Collapsed' }
    Show-Toast "닉네임 설정: $NewNick" $true
    Update-Overlay
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

function Apply-Scale {
    param($Box)
    if (-not $Box -or -not $Box.RootBorder) { return }
    $s = [double]$script:Settings.UiScale
    if ($s -le 0) { $s = 1.0 }
    try {
        if ([math]::Abs($s - 1.0) -lt 0.001) { $Box.RootBorder.LayoutTransform = $null }
        else { $Box.RootBorder.LayoutTransform = New-Object Windows.Media.ScaleTransform $s, $s }
    } catch {}
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

function Set-UiScale {
    param([double]$S)
    $S = [math]::Round([math]::Max(0.6, [math]::Min(2.0, $S)), 2)
    if ([math]::Abs($S - [double]$script:Settings.UiScale) -lt 0.001) { return }
    $script:Settings.UiScale = $S
    Apply-ScaleAll
    Save-Pos
    if ($script:MyBox -and $script:MyBox.CmbScale) {
        $script:SyncingUI = $true
        $idx = [Array]::IndexOf($script:ScaleSteps, $S)
        if ($idx -ge 0) { $script:MyBox.CmbScale.SelectedIndex = $idx }
        $script:SyncingUI = $false
    }
}

# 체크 상태에 따라 하위 설정 섹션 표시/숨김
function Sync-SettingSections {
    foreach ($b in Get-AllBoxes) {
        if (-not $b -or -not $b.AnomRow) { continue }
        $anom = [bool]$script:Settings.Anom
        $b.AnomRow.Visibility = $(if ($anom) { 'Visible' } else { 'Collapsed' })
        $b.BtnAdv.Visibility = $(if ($anom) { 'Visible' } else { 'Collapsed' })
        if (-not $anom) {
            $b.AdvPanel.Visibility = 'Collapsed'
            $b.BtnAdv.Text = '   고급 설정 ▾'
        }
        $bg = [bool]$script:Settings.BadgeOn
        $b.BtnBadgeAdv.Visibility = $(if ($bg) { 'Visible' } else { 'Collapsed' })
        if (-not $bg) {
            $b.BadgePanel.Visibility = 'Collapsed'
            $b.BtnBadgeAdv.Text = '   고급 설정 ▾'
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
    @{ K = 'Tobi'; N = '토비율' }, @{ K = 'Wt'; N = '평균화료순' }, @{ K = 'Stat4'; N = '우형리치·선제리치율' },
    @{ K = 'Stable'; N = '안정단위' }, @{ K = 'Badge'; N = '스타일 배지' },
    @{ K = 'NameColor'; N = '닉네임 강함 색상' },
    @{ K = 'SeqColor'; N = '오늘 순위 색상'; Me = $true }, @{ K = 'Streak'; N = '연승/연패 스트릭'; Me = $true },
    @{ K = 'Spark'; N = '오늘 pt 그래프'; Me = $true }
)
$script:DispTarget = 'me'

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
        $cb.Content = [string]$it.N
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
        $null = $Box.DispPanel.Children.Add($cb)
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

# 고급 설정: 대상(나/상대)별 · 항목별 강조 on/off 및 색상
$script:AdvTarget = 'me'

function Build-AdvPanel {
    param($Box)
    $Box.AdvPanel.Children.Clear()
    $fg = $Box.CbAnom.Foreground
    $isOpp = ($script:AdvTarget -eq 'opp')

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

        # 항목별 높음/낮음 색 견본
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
        if ($Data.NameColorVal -gt 4) { $nameRun.Foreground = New-Brush $cRed }
        elseif ($Data.NameColorVal -gt 3) { $nameRun.Foreground = New-Brush $cOrange }
        else { $nameRun.Foreground = New-Brush $cGreen }
    }
    $Box.TbName.Inlines.Add($nameRun)
    $sfxText = ''
    if ($Data.NameSuffix -and (Test-DispOn 'Stable' $isOppBox)) { $sfxText += [string]$Data.NameSuffix }
    if ($Data.Badges -and $script:Settings.BadgeOn -and (Test-DispOn 'Badge' $isOppBox)) { $sfxText += '  ' + [string]$Data.Badges }
    if ($sfxText) {
        $sfx = New-Object Windows.Documents.Run
        $sfx.Text = $sfxText
        $sfx.FontSize = [math]::Max(10, $Box.TbName.FontSize - 4.5)
        if ($null -ne $Data.NameColorVal -and (Test-DispOn 'NameColor' $isOppBox)) { $sfx.Foreground = $nameRun.Foreground }
        $Box.TbName.Inlines.Add($sfx)
    }

    # 표시 항목 토글
    if (Test-DispOn 'Rank' $isOppBox) { $Box.TbRank.Visibility = 'Visible' } else { $Box.TbRank.Visibility = 'Collapsed' }
    if (Test-DispOn 'Game' $isOppBox) { $Box.TbGame.Visibility = 'Visible' } else { $Box.TbGame.Visibility = 'Collapsed' }

    $Box.TbRank.Inlines.Clear()
    $Box.TbRank.Inlines.Add($Data.RankLine)
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

    # 통계 줄 렌더링 (특이 수치 심박 강조 포함)
    $sParts = @()
    if ($Data.StatParts) { $sParts = @($Data.StatParts | ForEach-Object { $_ }) }
    $rankMajor = 3
    if ($Data.RankMajor) { $rankMajor = [int]$Data.RankMajor }
    $lineMap = @{ 1 = $Box.TbStat; 2 = $Box.TbStat2; 3 = $Box.TbStat3; 4 = $Box.TbStat4 }
    foreach ($ln in 1, 2, 3, 4) {
        $tb = $lineMap[$ln]
        $lp = @($sParts | Where-Object { [int]$_.L -eq $ln })
        if (-not (Test-DispOn 'Tobi' $isOppBox)) { $lp = @($lp | Where-Object { [string]$_.K -ne 'tobi' }) }
        if (-not (Test-DispOn 'Wt' $isOppBox)) { $lp = @($lp | Where-Object { [string]$_.K -ne 'wt' }) }
        $tb.Inlines.Clear()
        if ($lp.Count -eq 0 -or -not (Test-DispOn "Stat$ln" $isOppBox)) {
            $tb.Visibility = 'Collapsed'
            continue
        }
        $tb.Visibility = 'Visible'
        $baseColor = ([Windows.Media.SolidColorBrush]$tb.Foreground).Color
        $first = $true
        foreach ($pp in $lp) {
            if (-not $first) { $tb.Inlines.Add('  ') }
            $first = $false
            $run = New-Object Windows.Documents.Run
            $run.Text = [string]$pp.T
            $hot = Get-StatHot ([string]$pp.K) ([double]$pp.V) $rankMajor $isOppBox
            if ($hot -gt 0) {
                $accHex = Get-AnomColor ([string]$pp.K) $hot $isOppBox
                $accColor = [Windows.Media.ColorConverter]::ConvertFromString($accHex)
                if ([string]$script:Settings.AnomMode -eq 'static') {
                    $run.Foreground = New-Object Windows.Media.SolidColorBrush $accColor
                } else {
                    $br = New-Object Windows.Media.SolidColorBrush $baseColor
                    $run.Foreground = $br
                    $ca = New-Object Windows.Media.Animation.ColorAnimation
                    $ca.From = $baseColor
                    $ca.To = $accColor
                    $ca.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(850))
                    $ca.AutoReverse = $true
                    $ca.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
                    $br.BeginAnimation([Windows.Media.SolidColorBrush]::ColorProperty, $ca)
                }
            }
            $tb.Inlines.Add($run)
        }
    }
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
        default { return $D.Date }
    }
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
        <TextBlock x:Name="RcTitle" FontFamily="Malgun Gothic" FontSize="16" FontWeight="ExtraBold" Foreground="#FFF2F4F8"/>
      </DockPanel>
      <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
        <TextBlock x:Name="RcTabDay" Text="일간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabWeek" Text="주간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabMonth" Text="월간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabSeason" Text="시즌" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand" Margin="0,0,14,0"/>
        <TextBlock x:Name="RcTabYear" Text="연간" FontFamily="Malgun Gothic" FontSize="13.5" FontWeight="ExtraBold" Foreground="#FFF2F4F8" Cursor="Hand"/>
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

function Set-ReportTabs {
    param($Rw, [string]$Mode)
    $map = @{ day = 'RcTabDay'; week = 'RcTabWeek'; month = 'RcTabMonth'; season = 'RcTabSeason'; year = 'RcTabYear' }
    foreach ($m in $map.Keys) {
        $tb = $Rw.FindName($map[$m])
        if ($m -eq $Mode) { $tb.Opacity = 1.0; $tb.TextDecorations = [Windows.TextDecorations]::Underline }
        else { $tb.Opacity = 0.45; $tb.TextDecorations = $null }
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

# 일간 상세 지표 렌더 (화료/방총/리치 등 — 율과 횟수 병기)
function Fill-DayDetail {
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
        if ($mode -eq 'week') { $unit = '요일' } elseif ($mode -eq 'month') { $unit = '일' } elseif ($mode -eq 'year') { $unit = '월' } elseif ($mode -eq 'season') { $unit = '주차' }

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
            $Rw.FindName('RcStats2').Text = ('수지 {0}pt   최고 연승 {1}' -f $arrow, $best)
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

        # 상세 지표 (일간 전용, 버튼 클릭 시 백그라운드 로딩)
        $dBtn = $Rw.FindName('RcDetailBtn')
        $Rw.FindName('RcDetailGrid').Children.Clear()
        if ($mode -eq 'day' -and $n -gt 0) {
            $anchorStr = [string]$Pack.Anchor
            if ($script:DetailCache.ContainsKey($anchorStr)) {
                $dBtn.Visibility = 'Collapsed'
                Fill-DayDetail $Rw $script:DetailCache[$anchorStr]
            } elseif ($script:DetailProc -and -not $script:DetailProc.HasExited -and $script:DetailReqAnchor -eq $anchorStr) {
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
                if ($diff -ge 200 -or ($pg -ge 30 -and $n -ge 3)) { $comment = '🚀 폭풍 성장의 날!' }
                elseif ($rate -ge 0.6 -and $n -ge 5 -and $diff -gt 0) { $comment = '🔥 폼 미쳤습니다' }
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
            if ($n -eq 0) { $comment = '이 기간엔 대국 기록이 없어요' }
            elseif ($diff -ge 500) { $comment = '📈 폭풍 성장 구간!' }
            elseif ($diff -ge 150) { $comment = '📈 순항 중입니다' }
            elseif ($rate -ge 0.55 -and $diff -gt 0) { $comment = '🔥 흐름이 좋아요' }
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
    param([string]$Mode, [DateTime]$Anchor)
    $rw = $script:ReportWin
    if (-not $rw) { return }
    $rw.Tag = @{ Mode = $Mode; Anchor = $Anchor }
    $script:ReportAnchors[$Mode] = $Anchor
    Set-ReportTabs $rw $Mode
    $key = ('{0}|{1}' -f $Mode, $Anchor.ToString('yyyy-MM-dd'))

    # 오늘-일간은 라이브 데이터로 즉시 표시
    if ($Mode -eq 'day' -and $Anchor -eq [DateTime]::Today) {
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
    try { Remove-Item (Join-Path $PSScriptRoot 'report-result.json') -Force -ErrorAction SilentlyContinue } catch {}
    $script:ReportReqKey = $key
    $script:ReportStart = Get-Date
    $script:ReportProc = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ReportOnce', $Mode, $Anchor.ToString('yyyy-MM-dd')
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
        $tabHandler = {
            $args[1].Handled = $true
            $m = [string]$args[0].Tag
            # 탭마다 마지막으로 보던 기간을 독립적으로 기억
            $a = [DateTime]::Today
            if ($script:ReportAnchors.ContainsKey($m)) { $a = [DateTime]$script:ReportAnchors[$m] }
            Request-Report $m (Get-PeriodAnchor $m $a)
        }
        foreach ($tn in @('RcTabDay', 'RcTabWeek', 'RcTabMonth', 'RcTabSeason', 'RcTabYear')) {
            $rw.FindName($tn).Add_MouseLeftButtonDown($tabHandler)
        }
        # ◀ ▶ 기간 이동
        $rw.FindName('RcPrev').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            $st = $w.Tag
            $m = [string]$st.Mode
            $a = [DateTime]$st.Anchor
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
            $a = [DateTime]$st.Anchor
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
        # 상세 지표 로딩 (일간 전용) - 리포트 다른 부분은 그대로 두고 이 영역만 백그라운드로 채움
        $rw.FindName('RcDetailBtn').Add_MouseLeftButtonDown({
            $args[1].Handled = $true
            $w = [Windows.Window]::GetWindow($args[0])
            $st = $w.Tag
            if ([string]$st.Mode -ne 'day') { return }
            $anchorStr = ([DateTime]$st.Anchor).ToString('yyyy-MM-dd')
            if ($script:DetailCache.ContainsKey($anchorStr)) { return }
            if ($script:DetailProc -and -not $script:DetailProc.HasExited) {
                Show-Toast '이미 상세 지표를 불러오는 중이에요' $false
                return
            }
            try { Remove-Item (Join-Path $PSScriptRoot 'detail-result.json') -Force -ErrorAction SilentlyContinue } catch {}
            $script:DetailReqAnchor = $anchorStr
            $script:DetailStart = Get-Date
            $script:DetailProc = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-DetailOnce', $anchorStr
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
    try { $pack = Get-Content (Join-Path $PSScriptRoot 'report-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
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
    try { $res = Get-Content (Join-Path $PSScriptRoot 'detail-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $ok = ($res -and $res.Ext -and $null -ne $res.Ext.count)
    # 오늘 날짜는 대국이 계속 추가되므로 캐시하지 않음
    if ($ok -and ([string]$res.Anchor) -ne ([DateTime]::Today.ToString('yyyy-MM-dd'))) {
        $script:DetailCache[[string]$res.Anchor] = $res
    }
    $rw = $script:ReportWin
    if (-not $rw) { return }
    try {
        $cur = $rw.Tag
        if ([string]$cur.Mode -ne 'day') { return }
        if ((([DateTime]$cur.Anchor).ToString('yyyy-MM-dd')) -ne $script:DetailReqAnchor) { return }
        $btn = $rw.FindName('RcDetailBtn')
        if ($ok) {
            $btn.Visibility = 'Collapsed'
            Fill-DayDetail $rw $res
        } else {
            $btn.Text = '상세 지표 불러오기 실패 — 다시 시도'
        }
    } catch {}
})
$script:DetailPollTimer = $detailPollTimer

# --- 내 전적 박스 ---
$script:Theme = 'light'
$script:LastData = $null
$my = New-StatWindow $BoxXaml
$win = $my.Win
$script:MyBox = $my

$posFile = Join-Path $PSScriptRoot 'overlay-pos.json'
$script:PosFile = $posFile
if (Test-Path $posFile) {
    try {
        $pos = Get-Content $posFile -Raw | ConvertFrom-Json
        $win.Left = $pos.Left; $win.Top = $pos.Top
        if ($pos.Theme -and @('light', 'dark', 'trans') -contains $pos.Theme) { $script:Theme = $pos.Theme }
        if ($pos.Settings) {
            foreach ($k in @('Stable', 'Danger', 'RankColors', 'Streak', 'Spark', 'Toast', 'MortalWatch', 'ShowTobi', 'Anom', 'BadgeOn',
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
            if ($pos.Settings.SessionBase) { $script:Settings.SessionBase = [string]$pos.Settings.SessionBase }
            if ($null -ne $pos.Settings.AnomPct) { $script:Settings.AnomPct = [int]$pos.Settings.AnomPct }
            if ($null -ne $pos.Settings.BadgeDefs) { $script:Settings.BadgeDefs = [string]$pos.Settings.BadgeDefs }
            foreach ($sk in @('AnomMode', 'AnomHigh', 'AnomLow', 'AnomOffMe', 'AnomOffOpp', 'AnomCMe', 'AnomCOpp', 'DispOffMe', 'DispOffOpp')) {
                if ($null -ne $pos.Settings.$sk) { $script:Settings[$sk] = [string]$pos.Settings.$sk }
            }
            # 구버전 설정(AnomOff 단일) 이전
            if ($pos.Settings.AnomOff -and -not $pos.Settings.AnomOffMe) {
                $script:Settings.AnomOffMe = [string]$pos.Settings.AnomOff
                $script:Settings.AnomOffOpp = [string]$pos.Settings.AnomOff
            }
        }
    } catch {}
}
Apply-Theme $my
Apply-Scale $my
Update-HelpTexts
# 닉네임 미설정 상태면 박스에 입력칸 표시
if (-not $script:Nickname -or $script:Nickname -eq '여기에닉네임') {
    $my.SetupPanel.Visibility = 'Visible'
}

function Update-Overlay {
    if ($script:NetBusy) { return }   # 갱신 중 타이머/버튼 재진입 방지
    $script:NetBusy = $true
    try {
        $d = Get-OverlayData
        $script:LastData = $d
        Set-StatWindow $my $d
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
            Show-Toast $txt $pos $(if ($pos) { 'up' } else { 'down' }) $mag
            $script:GameToastFired = $true
        }
        if ($script:TodayCount -ge 0) { $script:AnnouncedCount = $script:TodayCount }
        if ($null -ne $d.CurPt) { $script:LastShownPt = $d.CurPt }
        # 오늘 목표 달성 축하 (하루 1회)
        $dg = [int]$script:Settings.DailyGoal
        if ($dg -gt 0 -and $d.Diff -ge $dg -and $script:GoalCelebrated -ne [DateTime]::Today) {
            $script:GoalCelebrated = [DateTime]::Today
            Show-Toast "오늘 목표 +$dg pt 달성! 🎉" $true 'up' 60
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
# F8: 스캔을 별도 프로세스에서 실행 (UI는 계속 반응) - 완료는 ScanPollTimer가 감지
function Update-Opponents {
    if (-not $script:OcrOk) { return }
    if ($script:ScanProc -and -not $script:ScanProc.HasExited) { return }   # 이미 스캔 중
    Close-Opponents
    Show-ScanIndicator
    $resFile = Join-Path $PSScriptRoot 'scan-result.json'
    try { Remove-Item $resFile -Force -ErrorAction SilentlyContinue } catch {}
    # 스캔 프로세스가 내 박스가 가린 부분만 건너뛰도록 실시간 좌표 전달
    try {
        $w0 = $script:MyBox.Win
        @{
            X = [double]$w0.Left * $script:DpiScale
            Y = [double]$w0.Top * $script:DpiScale
            W = [math]::Max(220, [double]$w0.ActualWidth) * $script:DpiScale
            H = [math]::Max(80, [double]$w0.ActualHeight) * $script:DpiScale
        } | ConvertTo-Json | Out-File (Join-Path $PSScriptRoot 'scan-box.json') -Encoding utf8
    } catch {}
    $script:ScanStartTime = Get-Date
    $script:ScanProc = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-ScanOnce'
    $script:ScanPollTimer.Start()
}

# 스캔 결과(JSON)로 상대 박스 표시
function Show-OpponentResult {
    param($Entries)
    foreach ($o in $Entries) {
        $d = $o.Data
        if (-not $d) { continue }
        $key = [string]$o.Id
        $script:OppCache[$key] = $d
        if (-not $script:OppWindows.ContainsKey($key)) {
            $box = New-StatWindow $OppXaml
            $bw = $box.Win
            $bw.Tag = $key
            $script:OppWindows[$key] = $box
            Apply-Theme $box
            Apply-Scale $box
        }
        $box = $script:OppWindows[$key]
        Set-StatWindow $box $d
        # 닉네임 오른쪽에 배치 (화면 밖이면 안쪽으로)
        $dipX = $o.X / $script:DpiScale + 40
        $dipY = $o.Y / $script:DpiScale - 10
        $scrW = [System.Windows.SystemParameters]::PrimaryScreenWidth
        $scrH = [System.Windows.SystemParameters]::PrimaryScreenHeight
        if ($dipX -gt $scrW - 300) { $dipX = $scrW - 300 }
        if ($dipY -gt $scrH - 110) { $dipY = $scrH - 110 }
        if ($dipY -lt 0) { $dipY = 0 }
        $box.Win.Left = $dipX
        $box.Win.Top = $dipY
        if (-not $box.Win.IsVisible) { $box.Win.Show() }
    }
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
        # 클릭 = 수동 중지: 자식 프로세스를 종료하면 폴 타이머가 부분 결과를 표시함
        $iw.Add_MouseLeftButtonDown({
            try { if ($script:ScanProc -and -not $script:ScanProc.HasExited) { $script:ScanProc.Kill() } } catch {}
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
$script:LastScanSecs = 50
$scanPollTimer = New-Object Windows.Threading.DispatcherTimer
$scanPollTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$scanPollTimer.Add_Tick({
    if (-not $script:ScanProc) {
        $script:ScanPollTimer.Stop()
        Hide-ScanIndicator
        return
    }
    if (-not $script:ScanProc.HasExited) {
        # 경과 시간 표시 갱신 (중지는 사용자가 인디케이터 클릭으로)
        if ($script:ScanStartTime -and $script:ScanIndicator) {
            $sec = [int]((Get-Date) - $script:ScanStartTime).TotalSeconds
            try { $script:ScanIndicator.FindName('TbScanMain').Text = "🔍 상대 스캔 중... $sec`초" } catch {}
            # 비정상 상황 안전망 (999초)
            if ($sec -gt 999) { try { $script:ScanProc.Kill() } catch {} }
        }
        return
    }
    $script:ScanProc = $null
    $script:ScanPollTimer.Stop()
    $took = 0
    if ($script:ScanStartTime) { $took = [int]((Get-Date) - $script:ScanStartTime).TotalSeconds }
    Hide-ScanIndicator
    $resFile = Join-Path $PSScriptRoot 'scan-result.json'
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
    }
})
$script:ScanPollTimer = $scanPollTimer

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

Update-Overlay
$win.Show()
$app = New-Object Windows.Application
$null = $app.Run($win)
