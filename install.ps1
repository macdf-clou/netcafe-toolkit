<#
.SYNOPSIS
    网吧工具箱一键安装引导器。

.DESCRIPTION
    从 GitHub 下载 scoop-netcafe.ps1 / scoop-apps.ps1 / netcafe-setup.ps1,
    然后以指定参数运行 netcafe-setup.ps1。

.PARAMETER ScoopRoot
    Scoop 根目录(非还原盘)。默认 D:\Scoop。

.PARAMETER Profile
    软件套件,见 scoop-apps.ps1。默认 core,browser,editor,media,utility,runtime。

.PARAMETER Extra
    额外追加包。

.PARAMETER Admin
    你有管理员权限时加上,会额外装 VC++ 2015-2022 运行库(extras/vcredist2022)。

.PARAMETER SkipApps
    只装 Scoop 本体,不装软件。

.PARAMETER AutoDetect
    安装前先跑探测脚本,让你挑盘。

.PARAMETER DetectOnly
    只跑探测脚本,不装任何东西(用于先看看哪个盘安全)。

.PARAMETER Branch
    仓库分支,默认 main。

.EXAMPLE
    # 最短:默认套件
    irm https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/main/install.ps1 | iex

.EXAMPLE
    # 只探测哪个盘是非还原盘,不装东西
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/main/install.ps1))) -DetectOnly

.EXAMPLE
    # 带参数:管理员权限 + 装全套
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/main/install.ps1))) -Profile all -Admin
#>

[CmdletBinding()]
param(
    [string]  $ScoopRoot = 'D:\Scoop',
    [string[]]$Profile   = @('core','browser','editor','media','utility','runtime'),
    [string[]]$Extra     = @(),
    [switch]  $Admin,
    [switch]  $SkipApps,
    [switch]  $AutoDetect,
    [switch]  $DetectOnly,
    [string]  $Branch    = 'main'
)

$ErrorActionPreference = 'Stop'

Write-Host "`n== 网吧工具箱一键安装 ==" -ForegroundColor Cyan
Write-Host "  ScoopRoot = $ScoopRoot"
Write-Host "  Profile   = $($Profile -join ',')"
if ($Extra)    { Write-Host "  Extra     = $($Extra -join ',')" }
if ($Admin)    { Write-Host "  Admin     = 是(会装 VC++ 运行库)" -ForegroundColor Yellow }
if ($SkipApps) { Write-Host "  SkipApps  = 是(只装 Scoop)" -ForegroundColor Yellow }

try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
} catch {
    Write-Host "  [!] 设置执行策略失败,继续: $($_.Exception.Message)" -ForegroundColor Yellow
}

$base = "https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/$Branch"
$dst  = Join-Path $env:TEMP 'netcafe-toolkit'
if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }

$files = 'scoop-netcafe.ps1','scoop-apps.ps1','netcafe-setup.ps1','detect-persist-drive.ps1'
Write-Host "`n下载脚本到 $dst" -ForegroundColor Cyan
foreach ($f in $files) {
    $u = "$base/$f"
    $o = Join-Path $dst $f
    Write-Host "  $f"
    Invoke-RestMethod -Uri $u -OutFile $o
}

Write-Host "`n调起 netcafe-setup.ps1" -ForegroundColor Cyan
$setup = Join-Path $dst 'netcafe-setup.ps1'

# 拼接参数
$args = @{
    ScoopRoot = $ScoopRoot
    Profile   = $Profile
}
if ($Extra)      { $args['Extra']      = $Extra }
if ($Admin)      { $args['Admin']      = $true }
if ($SkipApps)   { $args['SkipApps']   = $true }
if ($AutoDetect) { $args['AutoDetect'] = $true }

# -DetectOnly: 只跑探测脚本,不装东西
if ($DetectOnly) {
    Write-Host "`n只跑探测 (DetectOnly 模式)" -ForegroundColor Cyan
    $detect = Join-Path $dst 'detect-persist-drive.ps1'
    & $detect
    return
}

& $setup @args
