<#
.SYNOPSIS
    网吧常用工具一键安装(基于 Scoop)。

.DESCRIPTION
    - 前置:必须已运行 scoop-netcafe.ps1 并重开 PowerShell,使 scoop 可用
    - 按"套件"(profile)分组批量安装,也支持 -Extra 追加任意包
    - 自动添加需要的 bucket (extras / versions)
    - 单个软件失败不影响其他继续装,最后给汇总
    - 已安装的会跳过,可重复执行

.PARAMETER Profile
    要安装的套件(可多选,逗号分隔):
        core     7zip aria2 git sudo            (强烈建议必装)
        browser  firefox
        editor   notepadplusplus vscode
        media    potplayer vlc
        office   sumatrapdf
        utility  everything snipaste quicklook
        dev      python311 nodejs-lts
        all      以上全部
    默认: core,browser,editor,media,utility

.PARAMETER Extra
    额外要装的包,会在 Profile 之外追加。
    包名前可加 bucket: 例如 extras/googlechrome、versions/python310

.PARAMETER DryRun
    只打印将要执行的动作,不真正安装。

.EXAMPLE
    # 默认一键装(core + 浏览器 + 编辑器 + 媒体 + 工具)
    .\scoop-apps.ps1

.EXAMPLE
    # 只装核心 + 开发环境(含 Python 3.11)
    .\scoop-apps.ps1 -Profile core,dev

.EXAMPLE
    # 默认套件再加 Chrome 和 Python 3.11
    .\scoop-apps.ps1 -Extra extras/googlechrome,versions/python311

.EXAMPLE
    # 装全套
    .\scoop-apps.ps1 -Profile all
#>

[CmdletBinding()]
param(
    [string[]]$Profile = @('core','browser','editor','media','utility'),
    [string[]]$Extra   = @(),
    [switch]  $DryRun
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
# 包名可带 bucket 前缀,形如 "extras/firefox"
$Sets = [ordered]@{
    core    = @('7zip','aria2','git','sudo')
    browser = @('extras/firefox')
    editor  = @('extras/notepadplusplus','extras/vscode')
    media   = @('extras/potplayer','extras/vlc')
    office  = @('sumatrapdf')
    utility = @('extras/everything','extras/snipaste','extras/quicklook')
    dev     = @('versions/python311','nodejs-lts')
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

Write-Host "`n完成。" -ForegroundColor Magenta
