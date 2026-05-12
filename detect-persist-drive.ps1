<#
.SYNOPSIS
    探测网吧/机房哪个盘是"非还原盘",推荐给 Scoop 用。

.DESCRIPTION
    两阶段检测:
    1) 启发式评分:根据卷标、空间、可写性、还原软件痕迹给每个盘打分
    2) 重启验证:在候选盘写时间戳标记,重启后再跑一次;
       若标记的写入时间早于本次开机时间 -> 该盘在重启后仍然存在 -> 非还原盘

    第一次跑:扫盘 + 写标记 + 提示重启
    第二次跑:读标记 + 对比开机时间 + 给出最终推荐

.PARAMETER MinFreeGB
    候选盘需要的最小空余空间,默认 5GB。

.PARAMETER NoWriteMarkers
    只做静态打分,不写标记(用于只看看不想留痕)。

.PARAMETER ShowAll
    显示所有盘,包括系统盘/不可写盘。默认只显示候选盘。

.EXAMPLE
    # 第一次跑(会写标记文件)
    .\detect-persist-drive.ps1

.EXAMPLE
    # 重启后再跑一次,拿最终答案
    .\detect-persist-drive.ps1

.EXAMPLE
    # 不留痕,只打分
    .\detect-persist-drive.ps1 -NoWriteMarkers -ShowAll
#>

[CmdletBinding()]
param(
    [int]   $MinFreeGB      = 5,
    [switch]$NoWriteMarkers,
    [switch]$ShowAll
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Bad($msg)   { Write-Host "  [X]  $msg" -ForegroundColor Red }

$MarkerName = '.netcafe-persist-test'

# -------- 0. 系统信息 --------
$sysInfo  = Get-CimInstance Win32_OperatingSystem
$bootTime = $sysInfo.LastBootUpTime
$sysDrive = ($env:SystemDrive).TrimEnd(':')

Write-Step "系统信息"
Write-Host ("  系统盘     : {0}:" -f $sysDrive)
Write-Host ("  上次开机   : {0}" -f $bootTime)
Write-Host ("  当前时间   : {0}" -f (Get-Date))

# -------- 1. 还原软件特征 --------
Write-Step "检测还原软件/机制特征"
$restoreHints = @()

$regKeys = @(
    @{ Path = 'HKLM:\SOFTWARE\PowerShadow';          Name = '影子系统 (PowerShadow)' },
    @{ Path = 'HKLM:\SOFTWARE\Faronics\Deep Freeze'; Name = 'Deep Freeze' },
    @{ Path = 'HKLM:\SOFTWARE\LMI\hjgx';             Name = '还原精灵' },
    @{ Path = 'HKLM:\SOFTWARE\RainGreen';            Name = '雨过天晴(猜测键名,可能不准)' }
)
foreach ($k in $regKeys) {
    if (Test-Path $k.Path) {
        $restoreHints += $k.Name
        Write-Warn2 ("注册表命中: {0}" -f $k.Name)
    }
}

$svcNames = @('PowerShadow','DFServ','hjgx','SnpApp','rgss')
foreach ($s in $svcNames) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if ($svc) {
        $restoreHints += "服务 $s ($($svc.Status))"
        Write-Warn2 ("服务存在: {0} [{1}]" -f $s, $svc.Status)
    }
}

if (Get-Command uwfmgr -ErrorAction SilentlyContinue) {
    try {
        $cfg = & uwfmgr get-config 2>&1
        if ($cfg -match 'Filter state.*ON|Current Session.*Turned on') {
            $restoreHints += 'UWF (Unified Write Filter) 已启用'
            Write-Warn2 "UWF 已启用,系统盘被过滤写入"
        }
    } catch { }
}

if (-not $restoreHints) {
    Write-Ok "未发现常见还原软件的注册表/服务痕迹"
    Write-Host "  注意:硬件还原卡无法通过软件检测,唯一方法是重启验证标记" -ForegroundColor Gray
}

# -------- 2. 扫盘 --------
Write-Step "枚举本地盘"

$disks = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }  # 3 = Local Fixed

$labelHints = '用户|数据|保留|存档|资料|存储|DATA|PUBLIC|USERDATA|GAMES|PERSIST|PRIVATE'
$results = New-Object System.Collections.Generic.List[object]

foreach ($d in $disks) {
    $letter = $d.DeviceID.TrimEnd(':')
    $root   = $d.DeviceID + '\'
    $freeGB = if ($d.FreeSpace) { [math]::Round($d.FreeSpace / 1GB, 1) } else { 0 }
    $sizeGB = if ($d.Size)      { [math]::Round($d.Size      / 1GB, 1) } else { 0 }
    $label  = if ($d.VolumeName) { $d.VolumeName } else { '' }

    # 可写性探针
    $writable = $false
    $probe = Join-Path $root '.nt-write-probe'
    try {
        'x' | Out-File -FilePath $probe -Encoding ASCII -ErrorAction Stop
        Remove-Item $probe -ErrorAction SilentlyContinue
        $writable = $true
    } catch { }

    # 读取标记文件
    $markerPath   = Join-Path $root $MarkerName
    $markerStatus = '无标记'
    $markerTime   = $null
    $rebootProven = $false
    if (Test-Path $markerPath) {
        try {
            $raw = Get-Content $markerPath -TotalCount 1 -ErrorAction Stop
            if ($raw -match '^netcafe-persist-test\|(.+)$') {
                $markerTime = [DateTime]::Parse($Matches[1])
                if ($markerTime -lt $bootTime) {
                    $rebootProven = $true
                    $markerStatus = ("重启保留 √ ({0:MM-dd HH:mm})" -f $markerTime)
                } else {
                    $ageMin = [math]::Round(((Get-Date) - $markerTime).TotalMinutes, 1)
                    $markerStatus = ("本次开机后写入 ({0}min 前)" -f $ageMin)
                }
            } else {
                $markerStatus = '标记格式异常'
            }
        } catch {
            $markerStatus = '标记读取失败'
        }
    }

    # 打分
    $score = 0
    $notes = New-Object System.Collections.Generic.List[string]
    if ($letter -eq $sysDrive) { $score -= 50; [void]$notes.Add('系统盘') }
    if (-not $writable)        { $score -= 100; [void]$notes.Add('不可写') }
    if ($freeGB -ge $MinFreeGB) { $score += 20 } else { $score -= 30; [void]$notes.Add("空间<${MinFreeGB}GB") }
    if ($freeGB -ge 20)         { $score += 10 }
    if ($label -match $labelHints) { $score += 25; [void]$notes.Add("卷标提示") }
    if ($rebootProven)            { $score += 100 }
    elseif ($markerTime)          { $score += 5 }

    $results.Add([PSCustomObject]@{
        Drive        = "$letter:"
        Label        = $label
        Free         = "${freeGB}GB"
        Total        = "${sizeGB}GB"
        Writable     = $writable
        IsSystem     = ($letter -eq $sysDrive)
        MarkerStatus = $markerStatus
        RebootProven = $rebootProven
        Score        = $score
        Notes        = ($notes -join '; ')
    }) | Out-Null
}

# -------- 3. 输出表格 --------
Write-Step "检测结果"
$view = if ($ShowAll) {
    $results
} else {
    $results | Where-Object { $_.Writable -and -not $_.IsSystem }
}
if (-not $view -or @($view).Count -eq 0) {
    Write-Warn2 "没有可写的非系统盘。加 -ShowAll 看全部。"
    $view = $results
}
$view | Sort-Object Score -Descending |
    Format-Table -AutoSize Drive, Label, Free, Total, MarkerStatus, Score, Notes

# -------- 4. 写标记文件 --------
if (-not $NoWriteMarkers) {
    Write-Step "写入/刷新标记文件"
    $candidates = $results | Where-Object { $_.Writable -and -not $_.IsSystem -and -not $_.RebootProven }
    if (@($candidates).Count -eq 0) {
        Write-Ok "没有待验证的候选盘(已验证的跳过)"
    }
    foreach ($r in $candidates) {
        $letter = $r.Drive.TrimEnd(':')
        $path = "${letter}:\$MarkerName"
        try {
            $line = "netcafe-persist-test|" + (Get-Date).ToString('o')
            $line | Out-File -FilePath $path -Encoding ASCII -Force
            Write-Ok "写入 $path"
        } catch {
            Write-Bad ("写 {0} 失败: {1}" -f $path, $_.Exception.Message)
        }
    }
}

# -------- 5. 推荐 --------
Write-Step "推荐"

$best = $results |
    Where-Object { $_.Writable -and -not $_.IsSystem } |
    Sort-Object Score -Descending |
    Select-Object -First 1

if (-not $best) {
    Write-Bad "没找到合适的候选盘。"
    Write-Host "  可能原因:所有非系统盘都不可写/空间不足/只插了只读 U 盘" -ForegroundColor Yellow
    Write-Host "  建议:问网管哪个盘不还原,或 -ShowAll 看完整列表" -ForegroundColor Yellow
    return
}

$recommendRoot = "$($best.Drive.TrimEnd(':')):\Scoop"

if ($best.RebootProven) {
    Write-Ok ("{0} 通过重启验证 (评分 {1}) —— 这就是非还原盘" -f $best.Drive, $best.Score)
    Write-Host "`n可以直接跑:" -ForegroundColor Magenta
    Write-Host "  .\netcafe-setup.ps1 -ScoopRoot '$recommendRoot' -Admin" -ForegroundColor White
    Write-Host "`n或一键命令:" -ForegroundColor Magenta
    Write-Host ("  & ([scriptblock]::Create((iwr -useb https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/main/install.ps1))) -ScoopRoot '{0}' -Admin" -f $recommendRoot) -ForegroundColor White
} else {
    Write-Warn2 ("{0} 是目前分数最高的候选(评分 {1}),但尚未经过重启验证" -f $best.Drive, $best.Score)
    Write-Host ""
    Write-Host "下一步:" -ForegroundColor Magenta
    Write-Host "  1) 重启电脑" -ForegroundColor White
    Write-Host "  2) 重开 PowerShell 再跑一次本脚本" -ForegroundColor White
    Write-Host ("  3) 那时如果 {0} 显示 '重启保留 √',就用它作为 ScoopRoot" -f $best.Drive) -ForegroundColor White
    if ($restoreHints.Count -eq 0) {
        Write-Host ""
        Write-Host "  (未检出软件还原痕迹,但硬件还原卡必须靠这一步验证。急用可先当它是非还原盘试一把)" -ForegroundColor Gray
    }
}
