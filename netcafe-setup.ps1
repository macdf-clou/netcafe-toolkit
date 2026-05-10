<#
.SYNOPSIS
    网吧一键装机总入口:Scoop + 常用软件,一条命令搞定。

.DESCRIPTION
    串联执行:
      1. scoop-netcafe.ps1  —— 在非还原盘安装/恢复 Scoop
      2. scoop-apps.ps1     —— 批量安装选定套件

    注意:Scoop 首次安装后,它的 shims 要写入 PATH。
    本脚本里通过 $env:Path 让当前进程立即能调用 scoop,
    但建议安装完成后仍新开一个 PowerShell 使用,避免缓存问题。

.PARAMETER ScoopRoot
    Scoop 根目录,非还原盘。默认 D:\Scoop。

.PARAMETER Profile
    要安装的套件,见 scoop-apps.ps1。默认 core,browser,editor,media,utility。

.PARAMETER Extra
    额外追加的包,例如 versions/python311

.PARAMETER SkipApps
    只装 Scoop 本体,不装软件。

.EXAMPLE
    # 最常用:默认一键装
    .\netcafe-setup.ps1

.EXAMPLE
    # 指定非还原盘 + 只装核心 + Python 3.11
    .\netcafe-setup.ps1 -ScoopRoot 'E:\Scoop' -Profile core -Extra versions/python311

.EXAMPLE
    # 装全套
    .\netcafe-setup.ps1 -Profile all
#>

[CmdletBinding()]
param(
    [string]  $ScoopRoot = 'D:\Scoop',
    [string[]]$Profile   = @('core','browser','editor','media','utility'),
    [string[]]$Extra     = @(),
    [switch]  $SkipApps
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Banner($msg) {
    Write-Host ""
    Write-Host ("#" * 60) -ForegroundColor DarkCyan
    Write-Host ("#  $msg") -ForegroundColor DarkCyan
    Write-Host ("#" * 60) -ForegroundColor DarkCyan
}

# -------- 1. 执行 Scoop 安装脚本 --------
Write-Banner "步骤 1/2  安装/恢复 Scoop"
$scoopScript = Join-Path $root 'scoop-netcafe.ps1'
if (-not (Test-Path $scoopScript)) {
    throw "找不到 $scoopScript ,请确认 scoop-netcafe.ps1 与本脚本在同一目录"
}
& $scoopScript -ScoopRoot $ScoopRoot

# -------- 2. 让当前进程立即识别 scoop --------
# scoop-netcafe.ps1 已经把 SCOOP / PATH 写到用户级,
# 这里再同步一次到当前会话,避免 scoop-apps.ps1 找不到 scoop。
$shims = Join-Path $ScoopRoot 'user\shims'
if (Test-Path $shims) {
    if (($env:Path -split ';') -notcontains $shims) {
        $env:Path = "$shims;$env:Path"
    }
    $env:SCOOP        = Join-Path $ScoopRoot 'user'
    $env:SCOOP_GLOBAL = Join-Path $ScoopRoot 'global'
}

if ($SkipApps) {
    Write-Banner "已跳过软件安装。请【重开 PowerShell】后使用 scoop 命令。"
    return
}

# -------- 3. 执行软件安装脚本 --------
Write-Banner "步骤 2/2  批量安装常用软件"
$appsScript = Join-Path $root 'scoop-apps.ps1'
if (-not (Test-Path $appsScript)) {
    throw "找不到 $appsScript"
}
& $appsScript -Profile $Profile -Extra $Extra

Write-Banner "全部完成!建议关闭本窗口,重开 PowerShell 再使用。"
