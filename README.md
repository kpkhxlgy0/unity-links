# Unity Asset Links

让 Codex Desktop 回复中的本地文件链接在属于 Unity 项目 `Assets`、`ProjectSettings` 或 `Packages` 目录时，
通过对应的 Unity Editor 打开。`Assets` 沿用 Unity 的普通资源打开逻辑，`ProjectSettings` 打开 Project
Settings，`Packages` 打开 Package Manager；代码链接保留行列信息。

## 前置条件

- Windows 10/11。
- 已为当前 Windows 用户安装官方 Codex Desktop。
- Unity 2022.3 项目。
- PowerShell 7，命令名为 `pwsh`。
- Git，用于克隆本仓库。
- Node.js 20 或更新版本及 npm；首次安装 Codex++ 1.0.0 时使用。
- 首次克隆仓库和首次安装 Codex++ 时可访问互联网。

所有 PowerShell 命令都应在本仓库根目录运行。脚本通过 `$PSScriptRoot` 定位文件，不依赖固定盘符或固定项目名。

## 放置仓库

这个仓库既是 Codex++ tweak 的长期源目录，也是 Unity Package Manager `file:` 依赖的长期源目录。安装成功后必须
保留它；不要把它当作可以删除的临时安装包。

### 放在一个 Unity 项目内

适合主要服务一个项目、希望省略 `-UnityProject` 的情况。仓库必须位于 Unity 项目根目录之下、`Assets` 之外：

```powershell
$unityProject = "D:\Projects\ExampleUnityProject"
New-Item -ItemType Directory -Path (Join-Path $unityProject "Tools") -Force | Out-Null
git clone https://github.com/kpkhxlgy0/unity-links.git (Join-Path $unityProject "Tools/unity-links")
Set-Location (Join-Path $unityProject "Tools/unity-links")
```

`Install-UnityPackage.ps1` 会从仓库目录向上查找同时包含 `Assets`、`Packages/manifest.json` 和
`ProjectSettings/ProjectVersion.txt` 的最近项目根目录。检测不到时会报错，不会创建或猜测 Unity 项目。

### 放在 Unity 项目外

适合用一个稳定仓库服务多个 Unity 项目。此时每个项目都显式传入路径：

```powershell
New-Item -ItemType Directory -Path D:\Tools -Force | Out-Null
git clone https://github.com/kpkhxlgy0/unity-links.git D:\Tools\unity-links
Set-Location D:\Tools\unity-links
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -UnityProject D:\Projects\ExampleUnityProject
```

Codex++ 只需按 Windows 用户全局安装和注入一次；Unity package 必须对每个需要链接功能的 Unity 项目分别安装。

## 首次安装

先检测环境，再安装固定的 Codex++ 1.0.0。普通安装脚本会继续执行当前 Codex Appx 的注入和 tweak 链接维护：

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1
```

脚本不会关闭、重启或启动 Codex。如果输出 `Blocked` 和退出码 `2`，按提示手动关闭 Codex，再重新运行同一命令。
不要提前假设需要关闭；只有脚本确认正在运行的镜像会被修改时才需要关闭。

然后为当前 Unity 项目安装 package。仓库位于该项目内部时不传参数：

```powershell
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-UnityPackage.ps1
```

仓库位于项目外，或要安装到其他项目时，两个命令都传入显式路径：

```powershell
pwsh -NoProfile -File .\Install-UnityPackage.ps1 `
    -UnityProject D:\Projects\AnotherUnityProject -CheckOnly
pwsh -NoProfile -File .\Install-UnityPackage.ps1 `
    -UnityProject D:\Projects\AnotherUnityProject
```

打开对应 Unity 项目，等待 Unity 完成 package 编译，并确认 Console 没有该 package 的编译错误。最后从 Windows
开始菜单启动 `Codex++`；不要从原始 `Codex` 入口启动。维护脚本只保留 CMD shim 和开始菜单快捷方式，不创建桌面
快捷方式；由旧版本创建且确实指向 Codex++ 受管镜像的桌面快捷方式会被安全移除。

## 日常维护

### Codex Desktop 更新后

每次 Codex Appx 更新后先检测，再按状态维护：

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1
```

`Inject-CodexPlusPlus.ps1` 自动选择版本最高的已安装 Codex Appx，维护对应的独立 Codex++ 镜像、CMD shim、开始
菜单快捷方式，以及 `%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links` junction。它从
`AppxManifest.xml` 读取真正的桌面入口，因此兼容 Appx 同时包含辅助启动器和桌面主程序的结构。

状态含义：

- `Current`：镜像、CMD、开始菜单快捷方式和 tweak junction 都正确。
- `InjectionRequired`：最新 Codex 版本尚未注入，或镜像校验不匹配。
- `LauncherRequired`：CMD 或开始菜单快捷方式缺失、过期；桌面快捷方式不参与此状态。
- `LinkRequired`：注入正确，但 tweak junction 缺失或仍指向旧仓库位置。
- `Blocked`：待修改镜像正在运行，或 live tweak 路径是不能安全替换的真实目录。

### 移动仓库

移动仓库后，旧 junction 和 Unity manifest 中的相对 `file:` 路径不会自动跟随。保留旧目录，直到以下步骤都成功：

1. 在新目录运行 `Inject-CodexPlusPlus.ps1`，让 tweak junction 指向新位置。
2. 对每个受影响的 Unity 项目重新运行 `Install-UnityPackage.ps1`；不在其项目目录内时传 `-UnityProject`。
3. 打开这些项目并等待 Unity 重新解析 package，确认无误后再删除旧目录。

### 取消注入

```powershell
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1
```

取消注入使用 `state.json` 记录的精确 app 根目录执行非 purge 卸载；卸载确认成功后才删除本 tweak 的 junction。
它不会删除 Codex++ 源码或命令、其他 tweak、本仓库，也不会修改任何 Unity manifest。

Unity package 的移除与 Codex++ 取消注入相互独立。要移除 package，只删除目标项目 manifest 中的
`com.kpk.codex-unity-link` 条目，然后让 Unity 重新解析。

## Unity manifest 写入

`Install-UnityPackage.ps1` 只插入或更新 `Packages/manifest.json` 中的 `com.kpk.codex-unity-link`，并生成相对于
目标项目 `Packages` 目录的 `file:` 路径。它不写 `Packages/packages-lock.json`，该文件仍由 Unity 维护。

如果 manifest 带有 ReadOnly 属性，脚本不会自行清除：受版本控制管理时先按当前系统的 checkout 流程使文件可写；
文件不受版本控制管理时可自行清除 ReadOnly。Windows ACL 拒绝写入会作为另一类错误报告。写入或写后校验失败时，
脚本会恢复原始字节。`-CheckOnly` 只读取并报告 `Current` 或 `UpdateRequired`，不要求 manifest 可写。

## 验证

维护脚本与 tweak 测试：

```powershell
pwsh -NoProfile -File .\scripts\tests\Run-Tests.ps1
Push-Location .\codex-tweak
try { npm test }
finally { Pop-Location }
codexplusplus validate-tweak (Resolve-Path .\codex-tweak).Path
```

Unity 项目打开且 package 编译完成后，可检查该项目的 Named Pipe：

```powershell
node .\codex-tweak\scripts\send-open.js `
    D:\Projects\ExampleUnityProject\Assets\Example.prefab
node .\codex-tweak\scripts\send-open.js `
    D:\Projects\ExampleUnityProject\ProjectSettings\EditorBuildSettings.asset:8
node .\codex-tweak\scripts\send-open.js `
    D:\Projects\ExampleUnityProject\Packages\manifest.json
```

成功响应包含 `"ok":true` 和 `"code":"opened"`。

## 安全边界与退出码

所有 Codex 维护脚本都不终止、启动或自动控制 Codex，也不直接修改 WindowsApps。Codex++ 1.0.0 不应在没有
显式 `--app` 的情况下运行 `codexplusplus debug`；这些维护脚本不使用 `debug`。

- `0`：检测成功且未被阻塞，或普通模式操作成功；检查模式下仍应读取打印状态。
- `1`：输入、环境、校验或操作失败，未达到可验证的目标状态。
- `2`：安全阻塞，需要按打印原因手动关闭 Codex，或处理不安全目录/缺失命令后重试。
