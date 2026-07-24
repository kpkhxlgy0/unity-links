# Unity Asset Links

让 Codex Desktop 回复中的本地文件链接在属于 Unity 项目 `Assets` 目录时，通过对应的 Unity Editor 打开。
Prefab 会沿用 Unity 的 Prefab 打开逻辑，自定义 `.asset` 可进入其注册的编辑器；代码链接保留行列信息。

## 要求与目录

- Windows
- Unity 2022.3
- Node.js 20 或更新版本（仅首次安装 Codex++ 时需要）
- Codex++ 1.0.0 或更新的兼容版本

四个维护脚本都从本仓库根目录运行，并使用 `$PSScriptRoot` 自定位，所以仓库移动后无需修改脚本。仓库可以放在
Unity 项目的 `FilePackages/unity-links` 下，但这只是便于自动发现 Unity 项目的推荐示例，不是硬编码依赖。

```powershell
Set-Location <unity-links 仓库目录>
```

## 推荐维护流程

首次使用：

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1
pwsh -NoProfile -File .\Install-UnityPackage.ps1
```

Codex Desktop 更新后，先检测，再按需重新注入：

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1
```

脚本不会关闭或重启 Codex。若 Codex 正从待修改的镜像运行，脚本会返回 `Blocked`，此时应手动关闭 Codex，
重新运行脚本，再手动启动。若脚本完成修改时 Codex 仍从官方 Appx 运行，它也会提示手动重启后再验证链接。

### `Install-CodexPlusPlus.ps1`

缺少兼容 CLI 时，从固定 commit `f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7` 安装官方 Codex++ v1.0.0
源码、构建并进行首次注入，然后交给 Inject 脚本完成 tweak 链接验证。已存在 1.0.0 或更新兼容版时不会下载、
替换或降级，而是直接交给 Inject 脚本。

`-CheckOnly` 只解析版本、前置条件、最新 Codex Appx 和运行状态，不联网、不创建临时目录、不运行 npm，也不修改
Codex++ state、镜像或 junction。

### `Inject-CodexPlusPlus.ps1`

自动选择版本最高的已安装 Codex Appx，并维护其独立的 Codex++ 镜像和
`%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links` junction。普通模式必要时执行明确的
`repair --force --app <官方 app 目录>`，再把 junction 校正到当前仓库的 `codex-tweak`。脚本从
`AppxManifest.xml` 自动读取真实桌面入口，并维护 Codex++ 的 CMD、桌面快捷方式和开始菜单快捷方式；这兼容
新版 Appx 同时包含 `Codex.exe` 启动器与 `ChatGPT.exe` 桌面主程序的结构。

它不会安装、下载或升级 Codex++，也不会修改 WindowsApps。`-CheckOnly` 完全只读。

状态含义：

- `Current`：最新镜像和 tweak junction 都正确。
- `InjectionRequired`：Codex 更新后，最新版本镜像尚未注入或校验不匹配。
- `LauncherRequired`：镜像正确，但 Codex++ 启动器仍指向 Appx 中错误的辅助启动程序。
- `LinkRequired`：注入正确，但 junction 缺失或指向旧仓库位置。
- `Blocked`：待修改镜像正在运行，或 live tweak 路径是不能安全替换的真实目录。

### `Uninject-CodexPlusPlus.ps1`

使用记录在 `state.json` 中的精确 app 根目录执行官方、非 purge 的 `uninstall --app <记录的镜像>`；仅在卸载成功
并确认 state 已移除后，才删除 Unity-link junction。它不会使用 `--purge`，也不会删除 Codex++ 源码/命令、其他
tweak、本仓库或 Unity package 引用。

状态含义：

- `NotInjected`：没有注入 state，也没有残留 junction。
- `Ready`：可对记录的镜像执行取消注入。
- `LinkOnly`：没有注入 state，仅需移除安全的残留 junction。
- `Blocked`：记录的镜像正在运行、CLI 缺失、state 无效，或 live tweak 路径是真实目录。

### `Install-UnityPackage.ps1`

仓库位于 Unity 项目内部时，脚本从自身目录向上查找同时含有 `Assets`、`Packages/manifest.json` 和
`ProjectSettings/ProjectVersion.txt` 的项目根目录。也可以显式指定其他项目：

```powershell
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -UnityProject D:\path\to\UnityProject
```

脚本只插入或更新 `Packages/manifest.json` 中的 `com.kpk.codex-unity-link`，并使用可搬迁的相对 `file:` 路径。
它不会写 `Packages/packages-lock.json`，该文件仍由 Unity 维护。`-CheckOnly` 只报告 `Current` 或
`UpdateRequired`。

Unity package 的移除与 Codex++ 取消注入是两个独立操作。取消注入脚本不会修改 Unity manifest；若要移除
package，应只删除 manifest 中的 `com.kpk.codex-unity-link` 条目并让 Unity 重新解析。

## 验证

```powershell
pwsh -NoProfile -File .\scripts\tests\Run-Tests.ps1
Push-Location .\codex-tweak
try { npm test }
finally { Pop-Location }
codexplusplus validate-tweak (Resolve-Path .\codex-tweak).Path
```

Unity 项目打开并完成 package 编译后，可直接检查 Named Pipe：

```powershell
node .\codex-tweak\scripts\send-open.js D:\path\to\UnityProject\Assets\Example.prefab
```

成功响应包含 `"ok":true` 和 `"code":"opened"`。

## 安全边界与退出码

所有 Codex 维护脚本都不终止、启动或自动控制 Codex，也不直接修改 WindowsApps。Codex++ 1.0.0 不应在没有
显式 `--app` 的情况下运行 `codexplusplus debug`；这些维护脚本完全不使用 `debug`。

- `0`：检测成功且未被阻塞，或普通模式操作成功。检查模式下仍应读取打印的状态判断是否需要维护。
- `1`：输入、环境、校验或操作失败，未达到可验证的目标状态。
- `2`：安全阻塞，需要按打印原因手动关闭 Codex 或处理真实目录/缺失命令后重试。
