<#
.SYNOPSIS
    网吧环境下 Scoop 一体化脚本:首次安装 + 重启后恢复。

.DESCRIPTION
    - 自动检测 Scoop 是否已安装在持久化盘
    - 未安装则自动安装(使用 Gitee 镜像,国内加速)
    - 已安装则只恢复环境变量,重开 PowerShell 即可使用
    - 全部操作只需用户权限,无需管理员

.PARAMETER ScoopRoot
    Scoop 的安装根目录,必须位于"非还原盘"上。
    默认 D:\Scoop,可按你网吧的实际情况修改(例如 E:\Scoop)。

.EXAMPLE
    # 使用默认 D:\Scoop
    .\scoop-netcafe.ps1

.EXAMPLE
    # 自定义安装位置
    .\scoop-netcafe.ps1 -ScoopRoot 'E:\MyScoop'
#>

[CmdletBinding()]
param(
    [string]$ScoopRoot = 'D:\Scoop'
)

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}
function Write-Ok($msg) {
    Write-Host "  [OK] $msg" -ForegroundColor Green
}
function Write-Warn2($msg) {
    Write-Host "  [!] $msg" -ForegroundColor Yellow
}

# -------- 1. 校验持久化盘 --------
Write-Step "校验安装目录: $ScoopRoot"
$driveLetter = (Split-Path -Qualifier $ScoopRoot).TrimEnd(':')
if (-not (Test-Path "$driveLetter`:\")) {
    throw "盘符 $driveLetter : 不存在,请用 -ScoopRoot 指定一个存在的非还原盘,例如 E:\Scoop"
}
$userDir   = Join-Path $ScoopRoot 'user'
$globalDir = Join-Path $ScoopRoot 'global'
if (-not (Test-Path $userDir))   { New-Item -ItemType Directory -Path $userDir   -Force | Out-Null }
if (-not (Test-Path $globalDir)) { New-Item -ItemType Directory -Path $globalDir -Force | Out-Null }
Write-Ok "目录就绪: $userDir"

# -------- 2. 设置环境变量(用户级) --------
Write-Step "写入用户级环境变量 SCOOP / SCOOP_GLOBAL"
[Environment]::SetEnvironmentVariable('SCOOP',        $userDir,   'User')
[Environment]::SetEnvironmentVariable('SCOOP_GLOBAL', $globalDir, 'User')
$env:SCOOP        = $userDir
$env:SCOOP_GLOBAL = $globalDir
Write-Ok "SCOOP        = $userDir"
Write-Ok "SCOOP_GLOBAL = $globalDir"

# -------- 3. 把 shims 加入 Path(用户级) --------
Write-Step "把 Scoop shims 注入用户 PATH"
$shims = Join-Path $userDir 'shims'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if ($userPath -notlike "*$shims*") {
    $newPath = if ($userPath) { "$shims;$userPath" } else { $shims }
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Ok "已追加 $shims"
} else {
    Write-Ok "PATH 已包含 shims,跳过"
}
# 当前会话也立即生效
if (($env:Path -split ';') -notcontains $shims) {
    $env:Path = "$shims;$env:Path"
}

# -------- 4. 判断是否已安装 --------
$scoopCmd = Join-Path $shims 'scoop.cmd'
$installed = Test-Path $scoopCmd

if ($installed) {
    Write-Step "检测到 Scoop 已存在 -> 进入【恢复模式】"
    Write-Ok  "无需重装,环境变量已刷新"
    Write-Host "`n请关闭本窗口,重开 PowerShell 后执行:  scoop list`n" -ForegroundColor Magenta
    return
}

# -------- 5. 首次安装 --------
Write-Step "未检测到 Scoop -> 进入【安装模式】"

# 放宽执行策略(仅当前用户)
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Write-Ok "执行策略已设为 RemoteSigned (CurrentUser)"
} catch {
    Write-Warn2 "设置执行策略失败: $($_.Exception.Message),继续尝试安装"
}

# 优先官方源,失败则用 Gitee 镜像
$installed = $false
try {
    Write-Step "尝试官方源安装: get.scoop.sh"
    Invoke-Expression (Invoke-RestMethod -Uri 'https://get.scoop.sh' -TimeoutSec 15)
    $installed = $true
} catch {
    Write-Warn2 "官方源失败: $($_.Exception.Message)"
}

if (-not $installed) {
    try {
        Write-Step "切换到 Gitee 镜像安装"
        Invoke-Expression (Invoke-RestMethod -Uri 'https://gitee.com/glsnames/scoop-installer/raw/master/bin/install.ps1')
        $installed = $true
    } catch {
        throw "Gitee 镜像也失败: $($_.Exception.Message)"
    }
}

if (-not (Test-Path $scoopCmd)) {
    throw "安装脚本执行完毕,但未发现 $scoopCmd,请检查上面的日志"
}
Write-Ok "Scoop 本体安装完成"

# -------- 6. 配置国内镜像加速 --------
Write-Step "配置 Gitee 镜像加速"
try {
    & $scoopCmd config SCOOP_REPO 'https://gitee.com/scoop-installer/scoop' | Out-Null
    # 重建 main bucket 指向 gitee
    & $scoopCmd bucket rm main 2>$null | Out-Null
    & $scoopCmd bucket add main 'https://gitee.com/scoop-bucket/main' | Out-Null
    Write-Ok "已切换到 Gitee 源"
} catch {
    Write-Warn2 "镜像配置失败(可稍后手动配置): $($_.Exception.Message)"
}

# -------- 7. 收尾 --------
Write-Step "完成!下次到网吧只需再次运行本脚本即可恢复环境"
Write-Host @"

常用命令:
  scoop install 7zip git aria2    # 推荐先装 aria2 加速后续下载
  scoop list                       # 查看已装软件
  scoop update                     # 更新 scoop 本体与 bucket
  scoop bucket add extras          # 添加 extras 软件源

重要:请关闭当前 PowerShell 窗口,重新打开一个新窗口,再执行 scoop 命令。
"@ -ForegroundColor Magenta
