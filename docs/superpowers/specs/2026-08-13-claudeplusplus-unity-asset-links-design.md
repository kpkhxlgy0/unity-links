# Claude++ Unity Asset Links 设计

## 目标

在现有 `unity-links` 产品中增加 Claude++ Desktop 接收端，使用户在 Claude Code Desktop 回复里普通左键
点击 Unity 项目本地文件链接时，获得与 Codex++ `Unity Asset Links` 完全一致的打开行为。

本次迁移只新增 Claude++ Tweak 和对应的 junction 管理入口。现有 Codex++ Tweak、Unity Editor Package、
Named Pipe v1 协议及 Unity 端打开逻辑保持不变。

## 参考基线

- Codex++ Tweak：`kpkhxlgy0/unity-links-codex` `v0.2.2`。
- 总仓库：`kpkhxlgy0/unity-links` 当前 `master`。
- Unity Package：`kpkhxlgy0/unity-links-unity` `v0.2.3`。
- Claude++ Runtime：`kpkhxlgy0/ClaudePlusPlus` `v0.2.1`。
- Claude++ 生命周期和安装方式以现有 `Feishu to Claude` 生产 Tweak 为宿主参考。

实现前和实现过程中都必须以当前 Codex++ Tweak 为行为基线。若发现必须产生新的用户可见差异，应先说明
差异、原因和影响，取得确认后再实现。

## 已确认决策

1. 先只迁移 Unity Links，不同时处理 Unreal Links。
2. 新建公开独立仓库 `kpkhxlgy0/unity-links-claude`，不 fork、不继承 Codex Tweak 历史。
3. 总仓库使用 `claude-tweak` submodule 固定该组件，布局与 `codex-tweak`、`unity-package` 对齐。
4. Claude++ Tweak 初始版本为 `0.1.0`，功能基线对应 Codex++ Tweak `0.2.2`。
5. 第一版不增加设置页、配置项或新行为。
6. Claude++ 本体继续通过自身发布包的 `install.ps1` 安装和维护；Unity Links 只维护 Tweak junction。
7. 第一版发布 GitHub Release，但不加入 Claude++ Tweak Store。

## 仓库与组件结构

总仓库新增：

```text
unity-links/
  claude-tweak/                 # git submodule: kpkhxlgy0/unity-links-claude
  Inject-ClaudePlusPlus.ps1
  Uninject-ClaudePlusPlus.ps1
  codex-tweak/                  # 保持不变
  unity-package/                # 保持不变
```

`unity-links-claude` 的分发边界与 `unity-links-codex` 对齐：

```text
unity-links-claude/
  .github/
  scripts/release/
  test/
  icon.png
  index.js
  LICENSE
  manifest.json
  package.json
  README.md
  README.zh-CN.md
```

Claude Tweak manifest 使用：

| 字段 | 值 |
| --- | --- |
| `id` | `com.kpk.unity-asset-links` |
| `name` | `Unity Asset Links` |
| `version` | `0.1.0` |
| `githubRepo` | `kpkhxlgy0/unity-links-claude` |
| `scope` | `both` |
| `main` | `index.js` |
| `minRuntime` | `0.2.1` |
| `permissions` | `['ipc', 'filesystem']` |

名称、图标、说明和标签保持与 Codex Tweak 一致，只把宿主及仓库元数据改为 Claude++。

## 运行时架构

```text
Claude Renderer 中的本地链接点击
  -> Claude++ Renderer Tweak
  -> Claude++ namespaced IPC
  -> Claude++ Main Tweak
  -> 项目识别与路径安全校验
  -> 按项目根确定的 Windows Named Pipe
  -> 匹配项目的 Unity Editor Package
  -> Unity 主线程打开资源或对应设置界面
```

### Renderer Tweak

Renderer 在 `document` 上安装一个 capture-phase click listener，并在停止或热重载时移除。它只拦截满足以下
全部条件的点击：

- 普通鼠标左键；
- 没有 `Alt`、`Ctrl`、`Meta` 或 `Shift` 修饰键；
- Markdown `a[href]` 或 Claude 文件引用节点；
- 可解析为 Windows 绝对路径或合法的本机 `file:` URL；
- 路径包含 `Assets`、`ProjectSettings` 或 `Packages` 项目段。

Renderer 只做语法筛选，不读取文件系统。无法识别的链接保留 Claude 原行为。Main 返回
`handled: false` 时，Renderer 使用一次性 bypass 回放原点击；已处理但失败时显示短暂提示。

### Main Tweak

Main 负责所有可信文件系统和本地传输工作：

1. 拒绝空值、非文件、路径穿越和不支持的根目录。
2. 规范化真实路径并向上查找包含 `Assets` 和 `ProjectSettings/ProjectVersion.txt` 的 Unity 项目根。
3. 要求词法路径与规范路径识别为同一项目，并拒绝 junction、symlink 和其他重解析点别名。
4. 把路径转换成以 `Assets`、`ProjectSettings` 或 `Packages` 开头的 Unity 项目相对路径。
5. 根据规范化项目根计算现有 v1 Pipe 名并发送一次请求。
6. 校验响应 `requestId`、大小、JSON 和超时结果。

Main 只使用 Claude++ Main Tweak 中可用的 Node 和 Electron 能力，不启动 Unity 或其他辅助进程。

### Unity Editor Package

Unity Package 不做代码或协议修改。它继续：

- 为每个项目根监听独立 Named Pipe；
- 在接收线程完成协议、项目根和路径校验；
- 把合法请求排队到 Unity 主线程；
- 对 `Assets` 使用 `AssetDatabase.OpenAsset`；
- 对 `ProjectSettings` 打开 Project Settings；
- 对 `Packages` 打开 Package Manager，并尽可能选中目标包。

## 与 Codex++ 的一致性和必要宿主差异

所有路径解析、项目识别、安全校验、Pipe 名、请求格式、超时、回退和提示语义均从 Codex Tweak `v0.2.2`
迁移，并保持相同测试向量。

唯一预先批准的内部差异是 Main IPC 生命周期：

- Codex++ 当前实现使用 `globalThis` 上的 `Symbol` 保存注册状态，以避免其热重载重复注册同一 handler。
- Claude++ 为每次 Main Tweak 启动建立独立 API lease，并在 reload 时自动移除该 lease 注册的 IPC handler。
- Claude Tweak 因此在每次 `start()` 中正常注册 handler，不保留跨 lease 的全局“已经注册”标志，由 Claude++
  Runtime 负责释放。

这项差异不会改变用户行为；若照搬 Codex 的持久注册标志，Claude++ reload 后反而可能不再注册 handler。

## 错误处理

- 非法或不支持的链接：不拦截，保留 Claude 原行为。
- 文件缺失：按 Codex 现有语义返回结构化失败，并在适用时定位父目录。
- 项目不匹配或安全检查失败：不向任何 Unity 实例发送请求。
- 匹配 Unity 未运行或连接失败：不启动 Unity；在 Explorer 中定位文件并显示短暂提示。
- Unity 拒绝或打开失败：显示 Unity 返回的说明，并按现有逻辑定位文件。
- 响应超限、无效 JSON、`requestId` 不匹配或超时：视为已处理失败，不自动重试。
- Tweak reload：清理 Renderer listener、提示节点和该 API lease 的 Main IPC handler，避免重复执行。

## 安全边界

- 只接受本机 Windows 绝对路径和受限 `file:` URL。
- HTTP、HTTPS、mailto、目录和项目外文件不进入 Pipe。
- Main 与 Unity 两端独立验证项目根、允许目录、穿越和别名。
- Pipe 只负责路由到候选项目，完整项目根仍包含在请求中并由 Unity 再次验证。
- 不修改注册表、WindowsApps 或系统 URL scheme。
- 不运行 localhost 服务、Native Messaging host 或常驻接收器。
- 不终止、启动或重启 Claude、Codex 或 Unity。

## 安装和维护

Claude++ 本体由其正式发布包安装：

```powershell
pwsh -NoProfile -File .\install.ps1
```

Unity Links 总仓库只增加 junction 管理命令：

```powershell
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1
pwsh -NoProfile -File .\Uninject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-ClaudePlusPlus.ps1
```

目标固定为：

```text
%APPDATA%\claude-plusplus\tweaks\com.kpk.unity-asset-links
  -> <unity-links>\claude-tweak
```

命令只拥有这个路径：

- `-CheckOnly` 不写文件。
- 缺失时可创建指向当前 `claude-tweak` 的 junction。
- 指向错误但类型安全的 junction 可修正。
- 同名普通目录、符号链接或未知重解析点必须阻断并保留。
- Uninject 只删除仍精确指向当前源码的 junction，不删除目标目录。
- 不检查或维护 Claude++ 本体，不影响 Codex Tweak 或其他 Claude Tweak。
- junction 发生变化后提示用户手动重启 Claude。

现有 `Install-UnityPackage.ps1` 继续作为所有桌面接收端共用的 Unity Package 安装入口；同一 Unity 项目只需
安装一次接收端。

## 发布模型

`unity-links-claude` 首次发布 `v0.1.0`。发布工作流验证 manifest、入口、图标、README、LICENSE、测试和
分发文件白名单，成功后生成 GitHub Release。总仓库随后把 `claude-tweak` submodule 固定到该 Release 对应提交。

第一版不修改 Claude++ 仓库的 `store/index.json`，也不声明已进入 Claude++ Tweak Store。manifest 中的
`githubRepo` 只提供身份、发布来源和版本检查信息。本地开发及当前安装流程使用 junction。

## 验证

### `unity-links-claude` 自动测试

- Windows 路径、`file:` URL、行号和列号解析。
- `Assets`、`ProjectSettings`、`Packages` 筛选。
- 项目根发现、项目相对路径和 Pipe 名稳定性。
- 文件缺失、穿越、junction、symlink、越界和项目别名拒绝。
- Renderer 点击资格、拦截、原点击回放、提示显示和清理。
- Main IPC 请求、Pipe 成功、Unity 拒绝、无效响应、超时和 Explorer 回退。
- Claude++ Renderer 的无 Node `require` 求值环境可以加载并启动 Tweak。
- Claude++ Main start/lease dispose/reload 后只存在一个有效 handler。
- release 校验拒绝 manifest 身份、版本、权限、入口、图标或分发白名单漂移。

### 总仓库自动测试

- `codex-tweak`、`claude-tweak` 和 `unity-package` 均为已初始化且固定的 submodule。
- Claude Inject/Uninject 的 `-CheckOnly`、幂等性、错误目标和不安全目录门禁。
- Claude junction 操作不修改 Codex junction，Codex junction 操作也不修改 Claude junction。
- Claude junction 命令不调用 Claude++ 安装、Appx、mirror、launcher、进程控制或注册表逻辑。
- 现有 Codex++、Unity Package 和发布测试继续通过。

### 实机验收

1. 在 Claude++ 中点击 `Assets` 文件，确认由精确匹配项目的 Unity Editor 打开。
2. 验证带行号和列号的链接。
3. 点击 `ProjectSettings` 和 `Packages` 文件，确认进入对应 Unity UI。
4. 关闭匹配 Unity 后点击，确认只定位 Explorer 并显示提示，不启动 Unity。
5. 热重载或重启 Claude++ 后再次点击，确认一次点击只执行一次。
6. 同时保留 Codex 与 Claude Tweak，确认两端共用 Unity 接收器且互不干扰。

本次不修改 Unity-loaded C#，因此不因迁移本身重新执行 Unity 编译门禁。真实点击验收会使用已安装现有
Unity Package 的项目，证明 Claude++ 到 Unity 的完整链路。

## 成功标准

- Claude++ 中受支持的 Unity 链接与 Codex++ `v0.2.2` 行为一致。
- 不支持的链接保留 Claude 原行为。
- 匹配项目未运行时不启动 Unity，只执行既有 Explorer 回退。
- 热重载、重启和两个桌面 Tweak 并存时没有重复打开或串路由。
- 新组件可独立测试、发布和通过 junction 安装。
- 总仓库固定三个组件版本，所有既有和新增自动测试通过。

## 非目标

- 修改 Unity Package 或 Named Pipe v1 协议。
- 支持 macOS、Linux 或非本机路径。
- 启动、选择或等待 Unity Editor。
- 增加设置页、自定义路径、开关或其他配置。
- 加入 Claude++ Tweak Store。
- 合并 Codex 与 Claude 两个 Tweak 仓库，或引入新的共享运行时代码仓库。
- 同时迁移 Unreal Links。
