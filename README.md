# 网吧工具箱 (Netcafe Toolkit)

为网吧、机房、共享电脑等**受限 Windows 环境**(无管理员权限 + 系统盘还原)设计的自动化脚本集合。

## 设计目标

- **无需管理员权限** —— 只使用当前用户的权限范围
- **抗系统还原** —— 所有持久化数据写到非还原盘,重启后一键恢复
- **国内网络友好** —— 默认使用 Gitee / 国内镜像,避开被墙的官方源
- **一键化** —— 一条命令完成安装或恢复
- **可验证** —— 下载内容校验 SHA256,日志落盘

## 脚本列表

| 脚本 | 说明 |
|------|------|
| [`scoop-netcafe.ps1`](./scoop-netcafe.ps1) | 在非还原盘安装 Scoop 包管理器,支持重启恢复、自动盘符探测、卸载、预设软件 |

---

## scoop-netcafe.ps1

### 功能(v2)

- **自动探测非还原盘** —— 扫描所有本地盘,写小测试文件验证可写性,让你选
- **SHA256 校验** —— 下载安装脚本后打印 hash,可用 `-InstallerSha256` 强制校验
- **多源 fallback** —— 官方源失败自动切 Gitee,或用 `-Mirror` 指定自定义 URL
- **智能模式切换** —— 检测到健康的已有安装就只刷环境变量(恢复模式);坏了或 `-Force` 就重装
- **卸载** —— `-Uninstall` 清理环境变量和 PATH,可选删除目录
- **预设** —— `-Preset minimal|dev|none` 或自定义软件列表
- **干运行** —— 标准 `-WhatIf` 支持,只打印不执行
- **日志** —— 自动写到 `<ScoopRoot>\install.log`
- **前置检查** —— PowerShell 版本、OS 检测,非 Windows 友好退出

### 用法一:一行命令(推荐)

网吧打开 PowerShell,粘贴:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
irm https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/main/scoop-netcafe.ps1 -OutFile "$env:TEMP\scoop-netcafe.ps1"
& "$env:TEMP\scoop-netcafe.ps1"
```

首次运行会交互选择安装盘(默认选第一个非 C 盘);之后再运行,检测到已安装就直接恢复。

### 用法二:常用参数

```powershell
# 指定位置 + 开发者工具全家桶
.\scoop-netcafe.ps1 -ScoopRoot 'E:\Scoop' -Preset dev

# 只看会做什么,不实际执行
.\scoop-netcafe.ps1 -WhatIf

# 强制重装(修复损坏的安装)
.\scoop-netcafe.ps1 -Force

# 自定义软件清单
.\scoop-netcafe.ps1 -Preset 'aria2,git,7zip,ripgrep,fzf'

# 只用 Gitee 镜像(官方被墙时)
.\scoop-netcafe.ps1 -Mirror gitee

# 完全自定义镜像
.\scoop-netcafe.ps1 -Mirror 'https://your.mirror/install.ps1'

# 安装脚本做 SHA256 校验(从可信渠道拿到哈希后传入)
.\scoop-netcafe.ps1 -InstallerSha256 'abcdef012345...'

# 卸载(只动用户级,不删目录;会询问是否删目录)
.\scoop-netcafe.ps1 -Uninstall
```

### 参数速查

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `-ScoopRoot` | string | 自动探测 | Scoop 根目录,例如 `D:\Scoop` |
| `-Mirror` | string | `auto` | `auto` / `official` / `gitee` / 自定义 URL |
| `-InstallerSha256` | string | (无) | 可选。期望的安装脚本 SHA256 |
| `-Preset` | string | `minimal` | `none` / `minimal` / `dev` / 逗号分隔列表 |
| `-Force` | switch | false | 已安装时也强制重装 |
| `-Uninstall` | switch | false | 卸载模式 |
| `-WhatIf` | switch | false | 干运行 |

### 预设详情

- `none` —— 什么都不装
- `minimal` —— `aria2`(默认,强烈建议保留,能让后续下载快 3-10 倍)
- `dev` —— `aria2` + `git` + `7zip` + `nodejs` + `python` + `vscode-portable`

### 执行后

**关闭当前 PowerShell,重新打开一个新窗口**,然后:

```powershell
scoop --version
scoop list
scoop bucket add extras       # GUI 类软件源
scoop install ripgrep fzf     # 任何你想要的
```

---

## 工作原理

### 对付系统还原

Scoop 的根目录通过 `SCOOP` 环境变量决定。脚本把它指向**非还原盘**:

```
C:\                           ← 重启还原(环境变量也丢)
D:\Scoop\user\                ← Scoop 本体 + 所有已装软件(持久化)
D:\Scoop\user\shims\scoop.cmd ← 二次运行时的"存在证据"
D:\Scoop\global\              ← 可选的全局软件目录
D:\Scoop\install.log          ← 每次运行的日志
```

### 智能两态(安装 / 恢复)

```
首次运行  → 未发现 scoop.cmd  → 下载安装脚本 → 跑 → 配镜像 → 装 aria2 → 完成
再次运行  → 发现 scoop.cmd 且 scoop --version 成功 → 只重建环境变量和 PATH → 完成(秒级)
安装坏了  → scoop.cmd 存在但 --version 报错 → 自动切回安装模式
-Force    → 无视一切,重走完整安装流程
```

### 下载完整性

下载安装脚本后,脚本会:
1. 计算 SHA256 并打印
2. 如果传入了 `-InstallerSha256`,严格比对,不匹配直接终止
3. 没传的话只警告,让你自己核对(至少留下审计痕迹)

这能部分对抗**镜像被投毒**或**中间人攻击**。

### 哪些盘是"非还原"的?

网吧通常保留一个非还原分区,常见:
- **D 盘** —— 最常见
- **E 盘** 或更后面的盘符
- 少数会用某个固定目录(如 `C:\保留`)

脚本会自动扫描并让你选;不确定就建个测试文件重启验证。

---

## 进阶技巧

### 跨机器搬家

第一次装完后,把整个 `D:\Scoop` 目录打包备份到 U 盘。换机器时:

1. 把目录拷回新机器的非还原盘(保持同盘符最省事)
2. 再跑一次本脚本 —— 检测到已有 Scoop,只刷环境变量
3. 立刻可用,连下载都省了

### 推荐首批软件

```powershell
scoop install aria2           # 自动装了,如果你选 minimal 以上的 preset
scoop install 7zip git
scoop bucket add extras
scoop install vscode-portable
```

### 常见问题

| 问题 | 解决 |
|------|------|
| `irm` 访问不了 raw.githubusercontent.com | 把脚本存到 U 盘,本地运行 |
| 提示未签名无法加载 | 脚本里的 `Set-ExecutionPolicy -Scope CurrentUser` 会处理 |
| D 盘也还原了 | 用 `-ScoopRoot` 指定其他持久化位置,或问网管 |
| 装软件特别慢 | 默认已装 `aria2` 开启多线程;如果没装,`scoop install aria2` |
| 想验证没被投毒 | 自己先下载一份 install.ps1,算 sha256,之后都用 `-InstallerSha256` |
| 想彻底卸载 | `.\scoop-netcafe.ps1 -Uninstall` |

---

## 关于跨平台

Scoop 本身**只支持 Windows**。如果你在 macOS / Linux 的受限环境里需要类似方案:

- **macOS** —— 用户目录 Homebrew(把 brew 装到 `$HOME/brew`),或 [mise](https://mise.jdx.dev)
- **Linux** —— [mise](https://mise.jdx.dev) 或 [Nix 单用户模式](https://nixos.org/download)

本仓库后续会加入对应的 bootstrap 脚本,敬请期待。

---

## 规划中

- [ ] `windows/portable-vscode.ps1` —— 非还原盘便携 VS Code + 用户配置
- [ ] `windows/ssh-restore.ps1` —— SSH 密钥从持久化目录恢复到 `~/.ssh`
- [ ] `windows/git-config-restore.ps1` —— 全局 Git 配置恢复
- [ ] `macos/brew-userland.sh` —— 用户级 Homebrew
- [ ] `shared/install.sh` —— 跨平台统一入口
- [ ] GitHub Actions CI —— PSScriptAnalyzer lint + Windows runner 烟测

## 许可

MIT
