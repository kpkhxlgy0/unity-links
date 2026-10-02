[English](README.md)

# Unity Asset Links

让 Codex Desktop 或 Claude Code Desktop 回复中的本地文件链接在属于 Unity 项目 `Assets`、`ProjectSettings` 或 `Packages` 目录时，
通过对应的 Unity Editor 打开。`Assets` 沿用 Unity 的普通资源打开逻辑，`ProjectSettings` 打开 Project
Settings，`Packages` 打开 Package Manager；代码链接保留行列信息。

## 前置条件

- Windows 10/11。
- 已为当前 Windows 用户安装官方 Codex Desktop、Claude Code Desktop，或两者都安装。
- 使用本仓库的 Claude Tweak 0.1.4 时，需要 Claude++ 0.3.3 或更新版本以支持新版 Claude 文件引用。
- Unity 2022.3 项目。
- PowerShell 7，命令名为 `pwsh`。
- Git，用于克隆本仓库。
- Node.js 20 或更新版本及 npm；只在首次安装 Codex++ 1.0.6 时使用。Claude++ 普通用户不需要 Node.js。
- 首次克隆仓库和首次安装 Codex++ 时可访问互联网。

所有 PowerShell 命令都应在本仓库根目录运行。脚本通过 `$PSScriptRoot` 定位文件，不依赖固定盘符或固定项目名。

## 放置仓库

这个仓库是集成和安装总入口。它通过 Git submodule，将独立发布的
[Codex++ tweak](https://github.com/kpkhxlgy0/unity-links-codex) 固定在 `codex-tweak/`，将
[Claude++ tweak](https://github.com/kpkhxlgy0/unity-links-claude) 固定在 `claude-tweak/`，并将两端共用的
[Unity package](https://github.com/kpkhxlgy0/unity-links-unity) 固定在 `unity-package/`。本地安装成功后仍需
保留这个 checkout；不要把它当作可以删除的临时安装包。

组件 submodule 使用 GitHub SSH 地址。使用 `--recurse-submodules` 克隆或初始化已有 checkout 前，请先配置可用的
GitHub SSH key。

### 放在一个 Unity 项目内

适合主要服务一个项目、希望省略 `-UnityProject` 的情况。仓库必须位于 Unity 项目根目录之下、`Assets` 之外：

```powershell
$unityProject = "D:\Projects\ExampleUnityProject"
New-Item -ItemType Directory -Path (Join-Path $unityProject "Tools") -Force | Out-Null
git clone --recurse-submodules `
    https://github.com/kpkhxlgy0/unity-links.git `
    (Join-Path $unityProject "Tools/unity-links")
Set-Location (Join-Path $unityProject "Tools/unity-links")
```

`Install-UnityPackage.ps1` 会从仓库目录向上查找同时包含 `Assets`、`Packages/manifest.json` 和
`ProjectSettings/ProjectVersion.txt` 的最近项目根目录。检测不到时会报错，不会创建或猜测 Unity 项目。

### 放在 Unity 项目外

适合用一个稳定仓库服务多个 Unity 项目。此时每个项目都显式传入路径：

```powershell
New-Item -ItemType Directory -Path D:\Tools -Force | Out-Null
git clone --recurse-submodules https://github.com/kpkhxlgy0/unity-links.git D:\Tools\unity-links
Set-Location D:\Tools\unity-links
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -UnityProject D:\Projects\ExampleUnityProject
```

每个桌面宿主只需按 Windows 用户安装一次各自的 ++ runtime 和 tweak junction；两端共用同一个 Unity
package，并对每个需要链接功能的 Unity 项目分别安装。

### 已有仓库

拉取拆仓改动后，先初始化固定的组件，再运行安装脚本：

```powershell
git pull --ff-only
git submodule update --init --recursive
```

路径仍为 `codex-tweak/`、`claude-tweak/` 和 `unity-package/`，因此完成 submodule 初始化后，已有 junction
和 Unity `file:` 依赖仍然有效。组件缺失时，维护脚本会打印准确的初始化命令，但不会自动获取或修改 Git 状态。

### 直接安装组件

Codex++ 商店用户只安装 `unity-links-codex`；Claude++ 组件当前通过总仓库 junction 安装，不通过 Tweak
Store。Unity Package Manager 用户只安装 `unity-links-unity`。
当前稳定版带标签的 Git URL 为：

```text
https://github.com/kpkhxlgy0/unity-links-unity.git#v0.2.5
```

需要协调式 Windows 安装、本地 `file:` 依赖、集成测试，或针对固定组件组合开发时，再使用本总入口仓库。

## 首次安装

先检测环境，再安装固定的 Codex++ 1.0.6。安装脚本也是日常维护入口：它委托 Codex++ 原生发现并维护独立版或
Store 版，修正启动入口，并清理本次被替换的上一个 Store 镜像。它不会检查或修改 Unity Links tweak junction：

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1
```

首次使用时，Install 成功后再单独创建 Unity Links tweak junction：

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1
```

Claude Code Desktop 使用 Claude++ 正式 Windows 发布包自带的 `install.ps1` 安装 Claude++，然后创建独立的
Claude Tweak junction。下面两个命令不会安装或维护 Claude++ 本体：

```powershell
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1
```

只需重启 junction 发生变化的宿主。Codex 与 Claude junction 相互独立，可以同时存在。

Install 脚本不会关闭、重启或启动 Codex。如果 Install 输出 `Blocked` 和退出码 `2`，按提示手动关闭 Codex，再重新
运行同一命令。不要提前假设需要关闭；只有 Install 确认正在运行的镜像会被修改时才需要关闭。

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
开始菜单启动 `Codex++`。Store 镜像只校验并保留 Codex++ 1.0.6 生成的包身份 PowerShell 启动器、CMD shim
和开始菜单快捷方式；缺失或过期时提示运行 `codexplusplus repair`，不会覆盖成直接 EXE 启动。官方 Store
安装必须保持注册。独立安装版保留直接启动真实 EXE 的方式。旧版本创建且确实指向受管镜像的桌面快捷方式
会被安全移除。

## 日常维护

### Codex Desktop 更新后

每次 Codex Desktop 更新后先检测，再运行同一个安装/维护入口：

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1
```

`Install-CodexPlusPlus.ps1` 使用原生 `install --no-watcher`，不传 `--app`，由 Codex++ 的 `locateCodex()` 选择
独立版或 Store 版。完成后，包装脚本保留并校验 Store 包身份启动入口，独立版仍根据 app root 校正入口。脚本会在维护前记录
`state.json` 指向的镜像；只有新的当前镜像完全校验成功后，才删除这一个被替换的上一版镜像。检查模式只打印
相同的清理计划，不删除任何内容。Install 不会检查、创建、修复或 reload Unity Links tweak junction；Codex
Desktop 更新后，已有的正确 junction 不需要重复执行 Inject。

如需清理当前版本以外所有可识别的旧受管镜像，显式传入：

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly -CleanupAllOldVersions
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CleanupAllOldVersions
```

全量模式只考虑受管 `store-apps` 根目录下直接一级、名称符合 `OpenAI.Codex_*` 的目录。两种模式都会排除已验证
的当前镜像；进程查询失败或待清理镜像仍在运行时不会删除。

状态含义：

- `Current`：镜像、CMD 和开始菜单快捷方式都正确。
- `InjectionRequired`：最新 Codex 版本尚未注入，或镜像校验不匹配。
- `LauncherRequired`：CMD 或开始菜单快捷方式缺失、过期；桌面快捷方式不参与此状态。
- `Blocked`：待修改或清理的镜像正在运行，或进程查询失败。

### 共享 Codex++ 维护

Unity Links 和 Unreal Links 共用同一份当前用户 Codex++ 受管镜像。任一时刻只运行一个 Editor Links
维护脚本；两个项目通过同一把共享锁协调。安全阻塞会报告明确原因：

- `MaintenanceBusy`：另一个 Unity Links 或 Unreal Links 维护脚本正持有共享锁。
- `ProcessQueryFailed`：脚本无法可靠确认 Codex 是否在运行，因此不执行任何写入。
- `DesktopAppRunning` / `MirrorRunning`：桌面应用正在待修改的 app root 下运行。VS Code/Cursor 插件启动且位于
  编辑器扩展目录的 `codex.exe` 不会阻断维护。
- `OldMirrorRunning`：选中清理的旧镜像仍在运行，因此不会删除。
- `UnsafeLink`：Inject 或 Uninject 的目标是一个真实目录，脚本不会自动替换或删除。

只要进程查询成功，已经正确 patch 的 Codex 运行时仍允许维护启动入口。同版本 ASAR 漂移会直接修复受管镜像；
只有最新镜像是新建、过期、缺失或不完整时，才在可靠确认 Codex 已关闭后从官方 Appx 重建。junction 维护是
独立的 Inject 或 Uninject 操作，不参与 Install 阻塞。脚本不会终止或重启 Codex。不要对这套共享环境直接运行
原始 `codexplusplus install` 或 `repair` 命令；请使用 `Install-CodexPlusPlus.ps1`，让两个引擎遵守相同的安全检查。

### 移动仓库

移动仓库后，旧 junction 和 Unity manifest 中的相对 `file:` 路径不会自动跟随。保留旧目录，直到以下步骤都成功：

1. Codex 使用本仓库时，在新目录运行 `Inject-CodexPlusPlus.ps1`。
2. Claude 使用本仓库时，在新目录运行 `Inject-ClaudePlusPlus.ps1`。
3. 对每个受影响的 Unity 项目重新运行 `Install-UnityPackage.ps1`；不在其项目目录内时传 `-UnityProject`。
4. 打开这些项目并等待 Unity 重新解析 package，确认无误后再删除旧目录。

### 只管理 Unity Links tweak junction

`Inject-CodexPlusPlus.ps1` 只创建或修复本仓库的 tweak junction。首次 Install 成功后运行一次；junction 缺失、
不安全或仍指向旧仓库位置时再运行。它不检查或修复 Codex Appx 镜像和启动入口，日常 Appx 维护也不需要重复运行：

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1
```

如需只移除该 junction：

```powershell
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1
```

这两个 junction 命令都不会安装、修复或卸载 Codex++，不会修改启动入口、读取 `state.json` 或删除受管镜像。
如果 live tweak 路径是一个真实目录，脚本会阻塞且不会覆盖或删除。修改 junction 后重启 Codex，tweak 才会加载或卸载。

Claude 在自己的 runtime 根目录使用相同的 junction-only 流程：

```powershell
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1
pwsh -NoProfile -File .\Uninject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-ClaudePlusPlus.ps1
```

这些脚本只管理 `%APPDATA%\claude-plusplus\tweaks\com.kpk.unity-asset-links`，不会调用 Claude++ 安装流程、
控制 Claude 进程或改动 Codex junction。Claude junction 变化后重启 Claude。

Unity package 的移除与 tweak junction 的移除相互独立。要移除 package，只删除目标项目 manifest 中的
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
Push-Location .\claude-tweak
try { npm test }
finally { Pop-Location }
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

## 发布流程

三个组件与总入口使用独立稳定版本。每个 workflow 都从对应仓库的 GitHub Actions 页面运行。总入口
`v0.3.0` 的发布顺序为：

1. 验证并发布 `unity-links-unity` 的 `v0.2.5`。
2. 验证并发布 `unity-links-codex` 的 `v0.2.2`。
3. 验证并发布 `unity-links-claude` 的 `v0.1.3`。
4. 将本仓库的三个 submodule 指针更新到上述已发布 commit。
5. 运行总入口集成测试，并从两个桌面宿主执行 Unity 链接 smoke check。
6. 从 `master` 运行本仓库的 `Release` workflow，输入 `0.3.0`。
7. 检查并手动发布生成的总入口 Draft Release。
8. 只使用已发布的 Codex 组件 commit 提交 Codex++ Tweak Store 审核；Claude 组件继续使用 junction 安装。

不要移动或复用发布标签。工作流重试时，如果所需标签已指向同一提交，可以继续使用；标签指向其他提交时会失败。
总入口 workflow 会读取每个组件自己的版本，并要求三个 submodule 都指向各自匹配的组件标签。更新检查只提供提示，
并且只能看到已经发布的 Releases，因此 Draft Release 不会向用户提示更新。

## 安全边界与退出码

所有 Codex 维护脚本都不终止、启动或自动控制 Codex，也不直接修改 WindowsApps。Codex++ 1.0.2 不应在没有
显式 `--app` 的情况下运行 `codexplusplus debug`；这些维护脚本不使用 `debug`。脚本还会保持 Codex++
watcher 禁用，并通过 `Local\CodexPlusPlus.EditorLinks.Maintenance.v1` 串行执行全局维护。

- `0`：检测成功且未被阻塞，或普通模式操作成功；检查模式下仍应读取打印状态。
- `1`：输入、环境、校验或操作失败，未达到可验证的目标状态。
- `2`：安全阻塞，需要按打印原因手动关闭 Codex，或处理不安全目录/缺失命令后重试。

## 开源协议

本项目采用 [MIT License](LICENSE)。
