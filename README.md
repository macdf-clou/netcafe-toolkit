# 网吧工具箱 (Netcafe Toolkit)

为网吧、机房、共享电脑等**受限环境**(无管理员权限 + 系统盘还原)设计的 Windows 自动化脚本集合。

## 设计目标

- **无需管理员权限** —— 全部操作只使用当前用户的权限范围
- **抗系统还原** —— 所有持久化数据写到非还原盘,重启后一键恢复
- **国内网络友好** —— 默认使用 Gitee / 国内镜像,避开被墙的官方源
- **一键化** —— 一条命令完成安装或恢复

## 脚本列表

| 脚本 | 说明 |
|------|------|
| [`netcafe-setup.ps1`](./netcafe-setup.ps1) | **一键总入口**:串联下面两个,安装 Scoop + 常用软件 |
| [`scoop-netcafe.ps1`](./scoop-netcafe.ps1) | 在非还原盘安装 Scoop,支持重启后秒级恢复 |
| [`scoop-apps.ps1`](./scoop-apps.ps1) | 按套件批量装常用软件(浏览器/编辑器/媒体/工具/开发) |

## 最快上手:一条命令装全套

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
$base = 'https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/main'
foreach ($f in 'scoop-netcafe.ps1','scoop-apps.ps1','netcafe-setup.ps1') {
    irm "$base/$f" -OutFile "$env:TEMP\$f"
}
& "$env:TEMP\netcafe-setup.ps1"
```

默认会:
1. 在 `D:\Scoop` 安装 Scoop
2. 安装套件:`core + browser + editor + media + utility`
   - **core**: 7zip, aria2, git, sudo
   - **browser**: firefox
   - **editor**: notepad++, vscode
   - **media**: potplayer, vlc
   - **utility**: everything, snipaste, quicklook

想要定制:

```powershell
# 指定盘符,只装核心 + 加 Python 3.11
& "$env:TEMP\netcafe-setup.ps1" -ScoopRoot 'E:\Scoop' -Profile core -Extra versions/python311

# 装全套
& "$env:TEMP\netcafe-setup.ps1" -Profile all
```
---


---

## scoop-netcafe.ps1

### 功能

- 首次运行:在指定的非还原盘(默认 `D:\Scoop`)安装 Scoop,自动配置 Gitee 镜像
- 再次运行(例如重启后):检测到已有安装,只刷新环境变量,秒级恢复
- 官方源失败时自动 fallback 到 Gitee 镜像
- 全程用户级,不触碰系统环境变量

### 用法一:一行命令(推荐)

在网吧打开 PowerShell,粘贴执行:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
irm https://raw.githubusercontent.com/macdf-clou/netcafe-toolkit/main/scoop-netcafe.ps1 -OutFile "$env:TEMP\scoop-netcafe.ps1"
& "$env:TEMP\scoop-netcafe.ps1"
```

默认会装到 `D:\Scoop`。

### 用法二:指定安装盘

```powershell
& "$env:TEMP\scoop-netcafe.ps1" -ScoopRoot 'E:\Scoop'
```

### 用法三:本地脚本

把 `scoop-netcafe.ps1` 拷到本地(比如 U 盘),直接运行:

```powershell
.\scoop-netcafe.ps1
.\scoop-netcafe.ps1 -ScoopRoot 'E:\Scoop'
```

### 执行后

**关闭当前 PowerShell,重新打开一个新窗口**,然后:

```powershell
scoop --version              # 确认可用
scoop install aria2          # 推荐先装 aria2 加速后续下载
scoop install 7zip git       # 常用工具
scoop list                   # 查看已装软件
```

---

## 工作原理

### 为什么网吧能用 Scoop?

Scoop 本身就是**绿色、用户级**的包管理器 —— 所有文件都在用户目录里,不需要写系统路径,不需要 UAC 提权。这和网吧环境天然契合。

### 怎么对付还原卡?

脚本把 Scoop 的根目录设置到**非还原盘**(通过 `SCOOP` 环境变量),这样:

```
C:\  <- 重启会还原(环境变量也丢)
D:\Scoop\user\      <- Scoop 本体 + 已装软件(持久化)
D:\Scoop\global\    <- 可选的全局软件目录
```

重启后虽然环境变量丢了,但 D 盘里的文件都在。再次运行脚本时,它发现 `D:\Scoop\user\shims\scoop.cmd` 存在,就只做"重建环境变量 + 更新 PATH",不会重新下载 —— 几秒钟就能恢复。

### 哪些盘是"非还原"的?

网吧通常会保留一个非还原分区给用户存档,常见情况:

- **D 盘** —— 最常见,本脚本默认
- **E 盘** 或更后面的盘符
- 某个固定目录如 `C:\Users\Public\Documents\保留` (少见)

不确定的话,建个测试文件重启验证一下;或者直接问网管。

---

## 进阶技巧

### 跨机器搬家

第一次装完后,把整个 `D:\Scoop` 目录打包备份到 U 盘。下次换机器时:

1. 把目录拷回新机器的非还原盘(保持同盘符最省事)
2. 再跑一次本脚本 —— 检测到已有 Scoop,只刷环境变量
3. 立刻可用,连下载都省了

### 推荐安装的第一批软件

```powershell
scoop install aria2     # 多线程下载器,让后续安装飞快
scoop install 7zip      # 解压
scoop install git       # 版本控制
scoop bucket add extras # 添加 extras 软件源(GUI 类工具)
```

### 常见问题

| 问题 | 解决 |
|------|------|
| `irm` 命令无法访问 raw.githubusercontent.com | 先把脚本存到 U 盘,用本地方式运行 |
| 提示"无法加载文件,未签名" | 脚本里的 `Set-ExecutionPolicy -Scope CurrentUser` 会处理,如仍失败就手动先执行一遍 |
| D 盘也还原了 | 用 `-ScoopRoot` 指定其他持久化位置,或问网管 |
| 装软件特别慢 | 先 `scoop install aria2`,之后自动并行下载 |

---

## 贡献 / 规划中的脚本

欢迎 PR。规划中的其他脚本:

- [x] `scoop-apps.ps1` —— 常用软件一键批量安装
- [ ] `portable-vscode.ps1` —— 非还原盘部署便携版 VS Code + 用户配置
- [ ] `ssh-keys-restore.ps1` —— SSH 密钥从持久化目录恢复到 `~/.ssh`
- [ ] `git-config-restore.ps1` —— 全局 Git 配置一键恢复
- [ ] `browser-profile-portable.ps1` —— 便携 Firefox/Chrome 配置

## 许可

MIT
