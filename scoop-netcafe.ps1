<#
.SYNOPSIS
    网吧 / 受限 Windows 环境下 Scoop 一体化脚本:智能安装 + 重启恢复 + 卸载。

.DESCRIPTION
    面向"无管理员权限 + 系统盘还原"的场景。相比 v1 版本,v2 新增:

      * 自动扫描可写的非还原盘(写入小测试文件验证),列出候选让用户选
      * 下载 Scoop 安装脚本后做 SHA256 校验(可自定义 -InstallerSha256)
      * 支持官方源 / Gitee 镜像 / 自定义 -Mirror
      * -Force       强制重装(保留 D 盘已装软件的能力由 Scoop 本身提供)
      * -Uninstall   清理环境变量 + 目录(仅用户级,不动系统)
      * -Preset      安装完自动装一组预设软件(aria2 默认装上,大幅加速后续下载)
      * -WhatIf / -Confirm 支持(干运行)
      * 全程记日志到 $ScoopRoot\install.log
      * OS / PowerShell 版本预检
      * 既有安装自检(调用 scoop --version 验证可用)

    全程用户级权限,不触碰系统环境变量。

.PARAMETER ScoopRoot
    Scoop 根目录。默认不传时会自动探测可写的非还原盘。
    可用形式:'D:\Scoop'、'E:\MyTools\Scoop' 等。

.PARAMETER Mirror
    Scoop 安装脚本的来源。可选值:
      'auto'    (默认) 先试官方,失败走 Gitee
      'official' 只用官方 https://get.scoop.sh
      'gitee'    只用 Gitee 镜像
      一个自定义 https URL

.PARAMETER InstallerSha256
    期望的安装脚本 SHA256。提供后会校验下载内容是否匹配,不匹配直接终止。
    不传则只记录实际 hash,不阻断流程(但仍会打印出来供你核对)。

.PARAMETER Preset
    安装后批量安装一组软件:
      'minimal'  只装 aria2(默认,强烈推荐)
      'dev'      aria2 + git + 7zip + nodejs + python + vscode-portable
      'none'     什么都不装
    或者传一个逗号分隔的自定义列表,例如 'aria2,git,7zip'

.PARAMETER Force
    Scoop 已安装时,也重新下载并运行安装器(例如修复损坏的安装)。

.PARAMETER Uninstall
    卸载模式:删除用户级 SCOOP / SCOOP_GLOBAL 环境变量、从 PATH 移除 shims,
    并可选删除目录(会二次确认)。

.EXAMPLE
    # 默认流程:自动找盘、安装、装 aria2
    .\scoop-netcafe.ps1

.EXAMPLE
    # 指定位置 + 开发者预设
    .\scoop-netcafe.ps1 -ScoopRoot 'E:\Scoop' -Preset dev

.EXAMPLE
    # 干运行,只看会做什么
    .\scoop-netcafe.ps1 -WhatIf

.EXAMPLE
    # 强制重装,使用 Gitee 镜像,并校验安装脚本哈希
    .\scoop-netcafe.ps1 -Force -Mirror gitee -InstallerSha256 'abc123...'

.EXAMPLE
    # 卸载
    .\scoop-netcafe.ps1 -Uninstall

.NOTES
    仓库: https://github.com/macdf-clou/netcafe-toolkit
    许可: MIT
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ScoopRoot,

    [string]$Mirror = 'auto',

    [string]$InstallerSha256,

    [string]$Preset = 'minimal',

    [switch]$Force,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$script:LogBuffer = [System.Collections.Generic.List[string]]::new()

# ============================================================================
# 工具函数
# ============================================================================

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERR','STEP')][string]$Level = 'INFO'
    )
    $time  = Get-Date -Format 'HH:mm:ss'
    $line  = "[$time][$Level] $Message"
    $script:LogBuffer.Add($line) | Out-Null
    switch ($Level) {
        'STEP' { Write-Host ""; Write-Host "==> $Message" -ForegroundColor Cyan }
        'OK'   { Write-Host "  [OK]  $Message" -ForegroundColor Green }
        'WARN' { Write-Host "  [!]   $Message" -ForegroundColor Yellow }
        'ERR'  { Write-Host "  [ERR] $Message" -ForegroundColor Red }
        default{ Write-Host "  $Message" }
    }
}

function Save-Log {
    param([Parameter(Mandatory)][string]$Dir)
    if (-not (Test-Path $Dir)) { return }
    $path = Join-Path $Dir 'install.log'
    try {
        Add-Content -Path $path -Value ("=== run at " + (Get-Date).ToString('u') + " ===") -Encoding UTF8
        Add-Content -Path $path -Value $script:LogBuffer -Encoding UTF8
    } catch {
        # 非致命,忽略
    }
}

function Test-Preconditions {
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        throw "需要 PowerShell 5.0 或更高版本,当前 $($PSVersionTable.PSVersion)"
    }
    $isWin = $false
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $isWin = $IsWindows
    } else {
        $isWin = $true  # Windows PowerShell 5.x 只在 Windows 上存在
    }
    if (-not $isWin) {
        throw "Scoop 仅支持 Windows。macOS/Linux 请参考仓库 README 里的平台替代方案。"
    }
}

function Get-CandidateDrives {
    <#
      返回可写、非还原/非光驱/非网络盘候选列表。
      通过在根目录写入一个临时文件来验证可写性。
    #>
    $candidates = @()
    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
        # 3 = LocalDisk, 其他(2 可移动, 4 网络, 5 光驱)我们跳过
        if ($d.DriveType -ne 3) { continue }
        $root = "$($d.DeviceID)\"
        if ($d.DeviceID -eq 'C:') { continue }  # C 通常是还原盘
        $testFile = Join-Path $root (".scoop-write-test-" + [guid]::NewGuid().ToString('N'))
        try {
            Set-Content -Path $testFile -Value 'ok' -ErrorAction Stop
            Remove-Item $testFile -ErrorAction SilentlyContinue
            $sizeGB = if ($d.Size) { [math]::Round($d.Size / 1GB, 1) } else { 0 }
            $freeGB = if ($d.FreeSpace) { [math]::Round($d.FreeSpace / 1GB, 1) } else { 0 }
            $candidates += [pscustomobject]@{
                Drive  = $d.DeviceID
                Label  = $d.VolumeName
                SizeGB = $sizeGB
                FreeGB = $freeGB
            }
        } catch {
            # 不可写就跳过
        }
    }
    return $candidates
}

function Resolve-ScoopRoot {
    param([string]$Explicit)

    if ($Explicit) {
        $drive = Split-Path -Qualifier $Explicit
        if (-not (Test-Path "$drive\")) {
            throw "盘符 $drive 不存在。"
        }
        # 验证可写
        $testFile = Join-Path "$drive\" (".scoop-write-test-" + [guid]::NewGuid().ToString('N'))
        try {
            Set-Content -Path $testFile -Value 'ok' -ErrorAction Stop
            Remove-Item $testFile -ErrorAction SilentlyContinue
        } catch {
            throw "目录 $Explicit 不可写(可能是只读或系统还原盘)。"
        }
        return $Explicit
    }

    Write-Log "自动扫描可写的非系统盘..." STEP
    $cands = Get-CandidateDrives
    if (-not $cands -or $cands.Count -eq 0) {
        Write-Log "未找到可写的非系统盘,回退到 C:\Users\$env:USERNAME\Scoop(重启会丢!)" WARN
        return (Join-Path $env:USERPROFILE 'Scoop')
    }

    Write-Host ""
    Write-Host "  可用盘:" -ForegroundColor White
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        $label = if ($c.Label) { " [$($c.Label)]" } else { '' }
        Write-Host ("    [{0}] {1}{2}  容量 {3}GB / 可用 {4}GB" -f ($i+1), $c.Drive, $label, $c.SizeGB, $c.FreeGB)
    }
    Write-Host ""

    # 默认选第一个(通常 D:),但允许交互选择
    $default = 1
    $picked = $null
    if ([Console]::IsInputRedirected -or $WhatIfPreference) {
        $picked = $cands[0]
        Write-Log "非交互模式,自动选 $($picked.Drive)" INFO
    } else {
        $ans = Read-Host "  请输入编号 (回车选 $default,Q 取消)"
        if ($ans -match '^[Qq]') { throw "用户取消" }
        if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $default }
        $idx = 0
        if (-not [int]::TryParse($ans, [ref]$idx) -or $idx -lt 1 -or $idx -gt $cands.Count) {
            throw "无效选择: $ans"
        }
        $picked = $cands[$idx - 1]
    }
    $path = Join-Path "$($picked.Drive)\" 'Scoop'
    Write-Log "已选择: $path" OK
    return $path
}

function Get-InstallerSource {
    param([string]$Mirror)

    $official = 'https://get.scoop.sh'
    $gitee    = 'https://gitee.com/glsnames/scoop-installer/raw/master/bin/install.ps1'

    switch ($Mirror) {
        'official' { return @($official) }
        'gitee'    { return @($gitee) }
        'auto'     { return @($official, $gitee) }
        default {
            if ($Mirror -match '^https?://') { return @($Mirror) }
            throw "无效的 -Mirror 值:$Mirror。可选:auto / official / gitee / 自定义 URL"
        }
    }
}

function Get-InstallerScript {
    param(
        [string[]]$Urls,
        [string]$ExpectedSha256
    )
    foreach ($url in $Urls) {
        try {
            Write-Log "下载安装脚本: $url" INFO
            $content = Invoke-RestMethod -Uri $url -TimeoutSec 20 -UseBasicParsing
            if ($content -isnot [string]) {
                # 某些镜像可能返回字节数组
                $content = [System.Text.Encoding]::UTF8.GetString([byte[]]$content)
            }
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
            $hash = ([System.BitConverter]::ToString(
                        [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
                     ) -replace '-','').ToLower()
            Write-Log "下载成功,SHA256 = $hash" OK
            if ($ExpectedSha256) {
                if ($hash -ne $ExpectedSha256.ToLower()) {
                    throw "SHA256 不匹配!预期 $ExpectedSha256,实际 $hash"
                }
                Write-Log "SHA256 校验通过" OK
            } else {
                Write-Log "未提供 -InstallerSha256,跳过校验(请自行核对上方 hash)" WARN
            }
            return $content
        } catch {
            Write-Log "来源 $url 失败: $($_.Exception.Message)" WARN
        }
    }
    throw "所有安装脚本来源都失败。请检查网络,或把 install.ps1 拷到 U 盘离线运行。"
}

function Invoke-Uninstall {
    param([string]$Root)

    Write-Log "进入卸载模式" STEP

    $currentScoop  = [Environment]::GetEnvironmentVariable('SCOOP', 'User')
    $currentGlobal = [Environment]::GetEnvironmentVariable('SCOOP_GLOBAL', 'User')

    if ($PSCmdlet.ShouldProcess("用户环境变量 SCOOP / SCOOP_GLOBAL", "删除")) {
        [Environment]::SetEnvironmentVariable('SCOOP', $null, 'User')
        [Environment]::SetEnvironmentVariable('SCOOP_GLOBAL', $null, 'User')
        Write-Log "已清除 SCOOP / SCOOP_GLOBAL 用户环境变量" OK
    }

    $shims = if ($currentScoop) { Join-Path $currentScoop 'shims' } else { $null }
    if ($shims) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -and $userPath.Contains($shims)) {
            if ($PSCmdlet.ShouldProcess("用户 PATH", "移除 $shims")) {
                $newPath = ($userPath -split ';' | Where-Object { $_ -and $_ -ne $shims }) -join ';'
                [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
                Write-Log "已从 PATH 移除 $shims" OK
            }
        }
    }

    $targetRoot = if ($Root) { $Root } elseif ($currentScoop) { Split-Path -Parent $currentScoop } else { $null }
    if ($targetRoot -and (Test-Path $targetRoot)) {
        Write-Host ""
        $ans = Read-Host "  是否同时删除目录 $targetRoot (所有已装软件都会丢失!) [y/N]"
        if ($ans -match '^[Yy]') {
            if ($PSCmdlet.ShouldProcess($targetRoot, "递归删除")) {
                Remove-Item -Path $targetRoot -Recurse -Force -ErrorAction Stop
                Write-Log "已删除 $targetRoot" OK
            }
        } else {
            Write-Log "保留目录 $targetRoot(你随时可以手动删除)" INFO
        }
    }

    Write-Log "卸载完成。请关闭所有 PowerShell 窗口后再打开新窗口确认。" OK
}

function Install-Presets {
    param([string]$PresetName, [string]$ScoopCmd)

    $list = switch -Regex ($PresetName) {
        '^none$'    { @() ; break }
        '^minimal$' { @('aria2') ; break }
        '^dev$'     { @('aria2','git','7zip','nodejs','python','vscode-portable') ; break }
        default     { $PresetName -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
    }
    if (-not $list -or $list.Count -eq 0) {
        Write-Log "Preset=$PresetName,不安装任何软件" INFO
        return
    }
    Write-Log "预设安装: $($list -join ', ')" STEP
    # aria2 如果存在优先先装,让后续下载加速
    if ($list -contains 'aria2') {
        if ($PSCmdlet.ShouldProcess('aria2', 'scoop install')) {
            & $ScoopCmd install aria2
            # 开启 aria2 (scoop 会自动检测,但显式 config 确保)
            & $ScoopCmd config aria2-enabled true | Out-Null
            Write-Log "aria2 已启用多线程下载" OK
        }
        $list = $list | Where-Object { $_ -ne 'aria2' }
    }
    foreach ($pkg in $list) {
        if ($PSCmdlet.ShouldProcess($pkg, 'scoop install')) {
            try {
                & $ScoopCmd install $pkg
                Write-Log "已装: $pkg" OK
            } catch {
                Write-Log "装 $pkg 失败: $($_.Exception.Message)" WARN
            }
        }
    }
}

# ============================================================================
# 主流程
# ============================================================================

try {
    Test-Preconditions

    if ($Uninstall) {
        Invoke-Uninstall -Root $ScoopRoot
        return
    }

    # 1. 确定安装位置
    $ScoopRoot = Resolve-ScoopRoot -Explicit $ScoopRoot
    $userDir   = Join-Path $ScoopRoot 'user'
    $globalDir = Join-Path $ScoopRoot 'global'

    if ($PSCmdlet.ShouldProcess($ScoopRoot, "创建目录")) {
        New-Item -ItemType Directory -Path $userDir   -Force | Out-Null
        New-Item -ItemType Directory -Path $globalDir -Force | Out-Null
        Write-Log "目录已就绪: $userDir" OK
    }

    # 2. 环境变量(用户级)
    Write-Log "写入用户级环境变量" STEP
    if ($PSCmdlet.ShouldProcess("用户环境变量", "设置 SCOOP / SCOOP_GLOBAL")) {
        [Environment]::SetEnvironmentVariable('SCOOP',        $userDir,   'User')
        [Environment]::SetEnvironmentVariable('SCOOP_GLOBAL', $globalDir, 'User')
        $env:SCOOP        = $userDir
        $env:SCOOP_GLOBAL = $globalDir
        Write-Log "SCOOP        = $userDir" OK
        Write-Log "SCOOP_GLOBAL = $globalDir" OK
    }

    # 3. PATH
    Write-Log "把 shims 注入用户 PATH" STEP
    $shims = Join-Path $userDir 'shims'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $userPath) { $userPath = '' }
    if ($userPath -notlike "*$shims*") {
        if ($PSCmdlet.ShouldProcess("用户 PATH", "追加 $shims")) {
            $newPath = if ($userPath) { "$shims;$userPath" } else { $shims }
            [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
            Write-Log "已追加" OK
        }
    } else {
        Write-Log "PATH 已包含 shims,跳过" OK
    }
    if (($env:Path -split ';') -notcontains $shims) {
        $env:Path = "$shims;$env:Path"
    }

    # 4. 判断是否已安装
    $scoopCmd = Join-Path $shims 'scoop.cmd'
    $isInstalled = $false
    if (Test-Path $scoopCmd) {
        # 自检:版本能读出来才算健康
        try {
            $ver = & $scoopCmd --version 2>$null | Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and $ver) {
                Write-Log "检测到健康的 Scoop 安装 ($ver)" OK
                $isInstalled = $true
            } else {
                Write-Log "Scoop 文件存在但自检失败,将重装" WARN
            }
        } catch {
            Write-Log "Scoop 自检抛错,将重装: $($_.Exception.Message)" WARN
        }
    }

    if ($isInstalled -and -not $Force) {
        Write-Log "进入【恢复模式】:仅刷新环境变量,无需重装" STEP
        Write-Log "完成。请关闭并重开 PowerShell 后运行: scoop list" OK
        Install-Presets -PresetName $Preset -ScoopCmd $scoopCmd
        Save-Log -Dir $ScoopRoot
        Write-Host ""
        Write-Host "请重开 PowerShell 后使用 scoop。" -ForegroundColor Magenta
        return
    }

    # 5. 安装
    Write-Log "进入【安装模式】" STEP

    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Write-Log "执行策略已设为 RemoteSigned (CurrentUser)" OK
    } catch {
        Write-Log "设置执行策略失败,继续: $($_.Exception.Message)" WARN
    }

    $urls = Get-InstallerSource -Mirror $Mirror
    $script = Get-InstallerScript -Urls $urls -ExpectedSha256 $InstallerSha256

    if ($PSCmdlet.ShouldProcess('安装脚本', '执行')) {
        Invoke-Expression $script
    }
    if (-not (Test-Path $scoopCmd)) {
        throw "安装脚本执行完,但未发现 $scoopCmd。请检查上方日志。"
    }
    Write-Log "Scoop 本体安装完成" OK

    # 6. Gitee 镜像加速(仅在 Mirror=auto 或 gitee 时默认开启)
    if ($Mirror -in @('auto','gitee')) {
        Write-Log "配置 Gitee 镜像加速" STEP
        try {
            & $scoopCmd config SCOOP_REPO 'https://gitee.com/scoop-installer/scoop' | Out-Null
            & $scoopCmd bucket rm main 2>$null | Out-Null
            & $scoopCmd bucket add main 'https://gitee.com/scoop-bucket/main' | Out-Null
            Write-Log "已切换到 Gitee 源" OK
        } catch {
            Write-Log "镜像配置失败(可稍后手动): $($_.Exception.Message)" WARN
        }
    }

    # 7. 预设软件
    Install-Presets -PresetName $Preset -ScoopCmd $scoopCmd

    # 8. 收尾
    Save-Log -Dir $ScoopRoot
    Write-Log "全部完成!" STEP
    Write-Host ""
    Write-Host "日志已保存到: $(Join-Path $ScoopRoot 'install.log')" -ForegroundColor DarkGray
    Write-Host @"

下次到网吧重启后,只需再次运行本脚本即可秒级恢复。
现在请关闭当前 PowerShell 窗口,重新打开一个新窗口后使用:

    scoop list
    scoop install git 7zip
    scoop bucket add extras

"@ -ForegroundColor Magenta

} catch {
    Write-Log $_.Exception.Message ERR
    if ($ScoopRoot) { Save-Log -Dir $ScoopRoot }
    throw
}
