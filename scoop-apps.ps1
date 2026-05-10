<#
.SYNOPSIS
    网吧常用工具一键安装(基于 Scoop)。

.DESCRIPTION
    - 前置:必须已运行 scoop-netcafe.ps1 并重开 PowerShell,使 scoop 可用
    - 按"套件"(profile)分组批量安装,也支持 -Extra 追加任意包
    - 自动添加需要的 bucket (extras / versions / java)
    - 单个软件失败不影响其他继续装,最后给汇总
    - 已安装的会跳过,可重复执行
    - 最后会检测系统级 VC++ / DirectX 运行库状态并给出提示

.PARAMETER Profile
    要安装的套件(可多选,逗号分隔):
        core     7zip aria2 git sudo                      (强烈建议必装)
        browser  firefox
        editor   notepadplusplus vscode
        media    potplayer vlc
        office   sumatrapdf
        utility  everything snipaste quicklook
        dev      python311 nodejs-lts dotnet-sdk          (开发环境)
        runtime  dotnet-runtime dotnet-windowsdesktop-runtime java/temurin-lts-jdk
                                                         (跑 .NET / Java 应用的运行时)
        all      以上全部
    默认: core,browser,editor,media,utility

.PARAMETER Extra
    额外要装的包,会在 Profile 之外追加。
    包名前可加 bucket: 例如 extras/googlechrome、versions/python310

.PARAMETER DryRun
    只打印将要执行的动作,不真正安装。

.PARAMETER SkipRuntimeCheck
    跳过末尾的 VC++/DirectX 系统运行库检测。

.EXAMPLE
    # 默认一键装
    .\scoop-apps.ps1

.EXAMPLE
    # 核心 + 开发环境 + 运行时
    .\scoop-apps.ps1 -Profile core,dev,runtime

.EXAMPLE
    # 装全套
    .\scoop-apps.ps1 -Profile all
#>

[CmdletBinding()]
param(
    [string[]]$Profile = @('core','browser','editor','media','utility'),
    [string[]]$Extra   = @(),
    [switch]  $DryRun,
    [switch]  $SkipRuntimeCheck
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  [!]  $msg" -ForegroundColor Yellow }
function Write-Fail($msg) { Write-Host "  [X]  $msg" -ForegroundColor Red }

# -------- 1. 检查 Scoop --------
Write-Step "检查 Scoop 是否可用"
$scoopCmd = Get-Command scoop -ErrorAction SilentlyContinue
if (-not $scoopCmd) {
    throw "Scoop 未安装或不在 PATH。请先运行 .\scoop-netcafe.ps1 ,并【重开一个新的 PowerShell 窗口】后再执行本脚本。"
}
Write-Ok "scoop 就绪: $($scoopCmd.Source)"

# -------- 2. 套件定义 --------
# 包名可带 bucket 前缀,形如 "extras/firefox"。脚本会自动添加缺少的 bucket。
$Sets = [ordered]@{
    core    = @('7zip','aria2','git','sudo')
    browser = @('extras/firefox')
    editor  = @('extras/notepadplusplus','extras/vscode')
    media   = @('extras/potplayer','extras/vlc')
    office  = @('sumatrapdf')
    utility = @('extras/everything','extras/snipaste','extras/quicklook')
    dev     = @('versions/python311','nodejs-lts','dotnet-sdk')
    runtime = @('dotnet-runtime','dotnet-windowsdesktop-runtime','java/temurin-lts-jdk')
}

# -------- 3. 解析 profile -> 合并包列表 --------
$profiles = if ($Profile -contains 'all') { @($Sets.Keys) } else { $Profile }
$packages = New-Object System.Collections.Generic.List[string]
foreach ($p in $profiles) {
    $key = $p.ToLower().Trim()
    if (-not $Sets.Contains($key)) {
        Write-Warn2 "未知套件: $p (跳过)"
        continue
    }
    foreach ($pkg in $Sets[$key]) { [void]$packages.Add($pkg) }
}
foreach ($e in $Extra) {
    if ($e) { [void]$packages.Add($e.Trim()) }
}
$packages = @($packages | Select-Object -Unique)

if ($packages.Count -eq 0) {
    throw "没有任何要安装的软件,请检查 -Profile 与 -Extra 参数"
}

Write-Step "计划安装 $($packages.Count) 个软件"
$packages | ForEach-Object { Write-Host "    - $_" }

# -------- 4. 添加需要的 bucket --------
Write-Step "检查并添加需要的 bucket"
$neededBuckets = [System.Collections.Generic.HashSet[string]]::new()
foreach ($pkg in $packages) {
    if ($pkg -match '^([^/]+)/') { [void]$neededBuckets.Add($matches[1]) }
}

$existingBuckets = @()
try {
    $existingBuckets = (& scoop bucket list) | ForEach-Object {
        # 兼容新旧格式:有的是 "name source ..." 有的是表格,取第一个词
        ($_ -split '\s+', 2)[0]
    } | Where-Object { $_ -and $_ -notmatch '^(Name|----|\s*$)' }
} catch {
    Write-Warn2 "无法列出 bucket: $($_.Exception.Message)"
}

foreach ($b in $neededBuckets) {
    if ($existingBuckets -contains $b) {
        Write-Ok "bucket 已存在: $b"
        continue
    }
    if ($DryRun) {
        Write-Host "  [dry-run] scoop bucket add $b"
        continue
    }
    try {
        Write-Host "  添加 bucket: $b"
        & scoop bucket add $b
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "bucket 添加成功: $b"
        } else {
            Write-Warn2 "bucket 添加返回码 $LASTEXITCODE : $b"
        }
    } catch {
        Write-Warn2 "添加 bucket $b 失败: $($_.Exception.Message)"
    }
}

# -------- 5. 逐个安装(单失败不中断) --------
Write-Step "开始安装(失败不会中断,最后有汇总)"
$ok = @(); $fail = @(); $skip = @()

foreach ($pkg in $packages) {
    $shortName = if ($pkg -match '/') { ($pkg -split '/')[1] } else { $pkg }

    # 是否已装
    $isInstalled = $false
    try {
        $listOut = & scoop list $shortName 2>$null
        if ($LASTEXITCODE -eq 0 -and $listOut -match "(?m)^\s*$([regex]::Escape($shortName))\s") {
            $isInstalled = $true
        }
    } catch { }

    if ($isInstalled) {
        Write-Ok "$shortName 已安装,跳过"
        $skip += $shortName
        continue
    }

    if ($DryRun) {
        Write-Host "  [dry-run] scoop install $pkg"
        continue
    }

    Write-Host "`n  -> 安装 $pkg ..." -ForegroundColor White
    try {
        & scoop install $pkg
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "$pkg 安装成功"
            $ok += $pkg
        } else {
            Write-Fail "$pkg 安装失败 (退出码 $LASTEXITCODE)"
            $fail += $pkg
        }
    } catch {
        Write-Fail "$pkg 安装异常: $($_.Exception.Message)"
        $fail += $pkg
    }
}

# -------- 6. 汇总 --------
Write-Step "安装汇总"
Write-Host ("  成功: {0}" -f $ok.Count)   -ForegroundColor Green
Write-Host ("  跳过: {0}" -f $skip.Count) -ForegroundColor Yellow
Write-Host ("  失败: {0}" -f $fail.Count) -ForegroundColor Red

if ($fail.Count -gt 0) {
    Write-Host "`n失败列表:" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "    $_" }
    Write-Host "`n可稍后重试: scoop install <包名>" -ForegroundColor Yellow
}

# -------- 7. 检测系统级运行库(VC++ / DirectX) --------
if (-not $SkipRuntimeCheck) {
    Write-Step "检测系统级运行库(VC++ / DirectX)"
    Write-Host "  这类运行库需要管理员权限才能装,网吧用户无法自行安装。"
    Write-Host "  绝大多数 Win10/11 系统已预装,下面只做检查给你参考。`n"

    # --- 7.1 VC++ 2015-2022 Redistributable (x64) ---
    $vcRegPath = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    $vcOk = $false
    $vcVer = $null
    try {
        if (Test-Path $vcRegPath) {
            $v = Get-ItemProperty -Path $vcRegPath -ErrorAction Stop
            if ($v.Installed -eq 1) {
                $vcOk  = $true
                $vcVer = "$($v.Major).$($v.Minor).$($v.Bld)"
            }
        }
    } catch { }
    if ($vcOk) {
        Write-Ok "VC++ 2015-2022 (x64) 已安装,版本 $vcVer"
    } else {
        Write-Warn2 "未检测到 VC++ 2015-2022 (x64)"
        Write-Host  "    下载: https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Gray
        Write-Host  "    (需要管理员权限,请用 U 盘带到网吧并请网管运行)" -ForegroundColor Gray
    }

    # x86 版本(32 位应用需要)
    $vcRegPath86 = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'
    if (-not (Test-Path $vcRegPath86)) {
        # 纯 32 位系统时 x86 在另一处
        $vcRegPath86 = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'
    }
    $vc86Ok = $false
    try {
        if (Test-Path $vcRegPath86) {
            $v86 = Get-ItemProperty -Path $vcRegPath86 -ErrorAction Stop
            if ($v86.Installed -eq 1) { $vc86Ok = $true }
        }
    } catch { }
    if ($vc86Ok) {
        Write-Ok "VC++ 2015-2022 (x86) 已安装"
    } else {
        Write-Warn2 "未检测到 VC++ 2015-2022 (x86) ,32 位老游戏/老软件可能用到"
        Write-Host  "    下载: https://aka.ms/vs/17/release/vc_redist.x86.exe" -ForegroundColor Gray
    }

    # --- 7.2 DirectX (Windows 10/11 自带 DX12,DX9 End-User Runtime 部分老游戏需要) ---
    $d3d9 = Join-Path $env:SystemRoot 'System32\d3d9.dll'
    $d3d11 = Join-Path $env:SystemRoot 'System32\d3d11.dll'
    $d3d12 = Join-Path $env:SystemRoot 'System32\d3d12.dll'
    $dxOk = (Test-Path $d3d11) -and (Test-Path $d3d12)
    if ($dxOk) {
        Write-Ok "DirectX 11/12 系统组件齐全(Win10/11 内建)"
    } else {
        Write-Warn2 "DirectX 系统文件不齐,这在 Win10/11 上很少见,建议修复系统"
    }
    if (Test-Path $d3d9) {
        Write-Ok "DirectX 9 基础组件存在"
        Write-Host "    老游戏如仍缺 d3dx9_*.dll ,可让网管装 DX9 End-User Runtime:" -ForegroundColor Gray
        Write-Host "    https://www.microsoft.com/download/details.aspx?id=35" -ForegroundColor Gray
    } else {
        Write-Warn2 "d3d9.dll 缺失"
    }
}

Write-Host "`n完成。" -ForegroundColor Magenta
