# Claude++ Unity Asset Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建独立的 `unity-links-claude` Tweak，并把它作为 `claude-tweak` submodule 接入
`unity-links`，让 Claude++ Desktop 中的 Unity 本地链接获得与 Codex++ `Unity Asset Links` v0.2.2
一致的打开、安全、回退和提示行为。

**Architecture:** Claude Renderer Tweak 捕获合格的本地链接，通过 Claude++ namespaced IPC 调用 Main Tweak；
Main 复用 Codex Tweak 的路径验证和 Windows Named Pipe v1 协议，把请求路由到现有 Unity Package。
Claude++ API lease 负责 Main IPC handler 的热重载清理；总仓库只增加 submodule、junction 管理、发布验证和
文档，不修改 Codex Tweak、Unity Package 或 Claude++ 本体。

**Tech Stack:** Node.js 24、CommonJS、Node `node:test`、Claude++ SDK/Runtime v0.2.1、PowerShell 7、
Git submodule、GitHub Actions、Windows Named Pipe、Electron Main 能力。

## Global Constraints

- 行为基线固定为 `unity-links-codex` v0.2.2。实现前先比较对应函数和测试；除已批准的 Main IPC lease 生命周期差异外，发现任何用户可见差异都必须停下并向用户确认。
- Claude++ 兼容基线固定为 `kpkhxlgy0/ClaudePlusPlus` v0.2.1 commit `6b7a0386cc351537f658c8a48fad1d25b6dd0385`。
- `codex-tweak/`、`unity-package/`、Named Pipe v1 请求格式和 Unity C# 接收器不得修改。
- 不修改 `D:\Unity\ClaudePlusPlus`，不加入 Claude++ Store，不增加设置页、配置项、注册表、URL scheme、
  localhost 服务、Native Messaging host、常驻接收器或进程控制。
- `Inject-ClaudePlusPlus.ps1` / `Uninject-ClaudePlusPlus.ps1` 只管理
  `%APPDATA%\claude-plusplus\tweaks\com.kpk.unity-asset-links` junction；Claude++ 安装继续由 Claude++ 自己的
  `install.ps1` 负责。
- 新仓库必须从空 Git 历史开始，不 fork、不复制 Codex 仓库 `.git` 历史；默认分支使用 `master`。
- 所有文本文件使用项目既有格式；源文件和脚本通过 `apply_patch` 创建或修改，`icon.png` 作为既有二进制资产用 `Copy-Item` 复制。
- GitHub 仓库创建、push、tag、workflow dispatch 和 Release 发布都是外部写操作；执行到相应检查点时必须取得用户当前任务的明确授权。
- 本次不改 Unity-loaded 代码，因此不运行 Unity 编译门禁；最终仍需在现有 Unity Package 上做 Claude → Pipe → Unity 的实机点击验收。

---

## Task 1: 初始化独立 Claude Tweak 仓库和发行契约

**Files:**

- Create: `D:\workspace\unity-links-claude\.gitignore`
- Create: `D:\workspace\unity-links-claude\manifest.json`
- Create: `D:\workspace\unity-links-claude\package.json`
- Create: `D:\workspace\unity-links-claude\LICENSE`
- Create: `D:\workspace\unity-links-claude\icon.png`
- Create: `D:\workspace\unity-links-claude\scripts\release\validate-release.mjs`
- Create: `D:\workspace\unity-links-claude\scripts\release\validate-release.test.mjs`

- [ ] **Step 1: 创建无历史继承的本地仓库**

Run:

```powershell
New-Item -ItemType Directory -Path D:\workspace\unity-links-claude
git -C D:\workspace\unity-links-claude init -b master
```

Expected: 新仓库分支为 `master`，没有 remote、commit 或来自 `unity-links-codex` 的历史。

- [ ] **Step 2: 先写发行校验失败测试**

在 `scripts/release/validate-release.test.mjs` 建立临时 fixture，并覆盖这些断言：

```js
test("accepts the Claude tweak 0.1.0 release contract", () => {
  assert.deepEqual(validateRelease(fixtureRoot(), "0.1.0"), {
    version: "0.1.0",
    tag: "v0.1.0",
  });
});

test("rejects a manifest that drifts from the Claude++ contract", () => {
  for (const patch of [
    { id: "example.wrong" },
    { githubRepo: "kpkhxlgy0/unity-links-codex" },
    { minRuntime: "0.2.0" },
    { scope: "renderer" },
    { main: "other.js" },
    { permissions: ["ipc"] },
  ]) {
    const root = fixtureRoot();
    updateJson(root, "manifest.json", patch);
    assert.throws(() => validateRelease(root, "0.1.0"));
  }
});
```

另测非稳定版本、manifest/package 版本不一致、错误 icon URL、缺失 `icon.png` 和非 MIT license。入口、文档、
workflow 与最终分发白名单在 Task 5 文件齐备后加入校验，避免用临时入口或占位文件制造假绿色。

- [ ] **Step 3: 运行测试确认失败**

Run:

```powershell
node --test D:\workspace\unity-links-claude\scripts\release\validate-release.test.mjs
```

Expected: FAIL，原因是 `validate-release.mjs` 和发行文件尚不存在。

- [ ] **Step 4: 实现最小 manifest、package 和发行校验器**

`manifest.json` 使用精确值：

```json
{
  "id": "com.kpk.unity-asset-links",
  "name": "Unity Asset Links",
  "version": "0.1.0",
  "githubRepo": "kpkhxlgy0/unity-links-claude",
  "homepage": "https://github.com/kpkhxlgy0/unity-links",
  "iconUrl": "https://raw.githubusercontent.com/kpkhxlgy0/unity-links-claude/master/icon.png",
  "description": "Open Claude links under Assets, ProjectSettings, or Packages in the matching Unity Editor.",
  "author": "KPK",
  "tags": ["unity", "links", "workflow"],
  "minRuntime": "0.2.1",
  "scope": "both",
  "main": "index.js",
  "permissions": ["ipc", "filesystem"]
}
```

`package.json` 使用 `name: "kpk-claude-unity-asset-links"`、`version: "0.1.0"`、`license: "MIT"`、
`private: true` 和 `test: "node --test test/*.test.js"`。

发行校验器固定验证：

```js
const EXPECTED_ID = "com.kpk.unity-asset-links";
const EXPECTED_REPOSITORY = "kpkhxlgy0/unity-links-claude";
const EXPECTED_ICON =
  "https://raw.githubusercontent.com/kpkhxlgy0/unity-links-claude/master/icon.png";
const EXPECTED_MIN_RUNTIME = "0.2.1";
const EXPECTED_SCOPE = "both";
const EXPECTED_MAIN = "index.js";
const EXPECTED_PERMISSIONS = ["ipc", "filesystem"];
```

用 `Copy-Item -LiteralPath D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\icon.png` 复用同一图标；
LICENSE 使用现有 MIT 文本和 `Copyright (c) 2026 KPK`，不得复制 `.git`。

- [ ] **Step 5: 运行发行测试**

Run:

```powershell
node --test D:\workspace\unity-links-claude\scripts\release\validate-release.test.mjs
node D:\workspace\unity-links-claude\scripts\release\validate-release.mjs `
  D:\workspace\unity-links-claude 0.1.0
```

Expected: 两条命令 PASS，CLI 输出 `release-validation=passed version=0.1.0 tag=v0.1.0`。

- [ ] **Step 6: 提交仓库骨架**

```powershell
git -C D:\workspace\unity-links-claude add .
git -C D:\workspace\unity-links-claude commit -m "chore: bootstrap Claude++ Unity Links release contract"
```

---

## Task 2: 从 Codex v0.2.2 机械迁移完整行为基线

**Files:**

- Create: `D:\workspace\unity-links-claude\index.js`
- Create: `D:\workspace\unity-links-claude\test\index.test.js`
- Reference only: `D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\index.js`
- Reference only: `D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\test\index.test.js`

- [ ] **Step 1: 记录 Codex 基线并验证其自身为绿色**

Run:

```powershell
git -C D:\workspace\sgproj\FilePackages\unity-links\codex-tweak describe --tags --exact-match
node --test D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\test\index.test.js
```

Expected: tag 为 `v0.2.2`，22 个 Codex 行为测试全部 PASS。若 tag 或测试不符，停止并先报告基线漂移。

- [ ] **Step 2: 先迁移测试并确认入口缺失**

把 `codex-tweak/test/index.test.js` 机械复制为 Claude 测试，只把用户可见宿主词从 `Codex` 改为 `Claude`；测试向量、路径、Pipe 断言和安全断言保持不变。

Run:

```powershell
npm test --prefix D:\workspace\unity-links-claude
```

Expected: FAIL，原因是 `../index.js` 不存在。

- [ ] **Step 3: 机械复制业务实现并保持函数对照**

复制 Codex `index.js` 后，只允许以下宿主适配：

1. 用户提示中的 `Codex` 改为 `Claude`。
2. Task 3 中移除 Codex 专属的 persistent Main handler 注册标志。
3. 不改变下列 `__test` 接口和算法：

```js
parseDestination
splitLineColumn
hasSupportedProjectSegment
isEligibleClick
normalizeProjectRoot
pipeNameForProjectRoot
hasReparsePointSegment
findUnityTarget
sendPipeRequest
handleOpenAsset
startMain
showNotice
replayOriginalClick
startRenderer
stopRenderer
```

必须保留相同的请求字段、超时、响应大小限制、`requestId` 校验和 Explorer 回退。

- [ ] **Step 4: 运行完整行为测试并做源差异审计**

Run:

```powershell
npm test --prefix D:\workspace\unity-links-claude
git diff --no-index -- `
  D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\index.js `
  D:\workspace\unity-links-claude\index.js
```

Expected: 所有迁移测试 PASS；差异只包含 Claude 文案和下一任务明确实现的生命周期差异。若出现路径、协议、安全或回退差异，停止并向用户确认。

- [ ] **Step 5: 提交行为迁移**

```powershell
git -C D:\workspace\unity-links-claude add index.js test/index.test.js
git -C D:\workspace\unity-links-claude commit -m "feat: port Unity asset link behavior to Claude++"
```

---

## Task 3: 实现 Claude++ API lease 生命周期差异

**Files:**

- Modify: `D:\workspace\unity-links-claude\test\index.test.js`
- Modify: `D:\workspace\unity-links-claude\index.js`

- [ ] **Step 1: 把 Codex 热重载测试改成 Claude lease 测试**

删除“跨热重载只注册一次”的 Codex 专属断言，改为：

```js
test("registers one Main handler for every Claude++ API lease", () => {
  const first = fakeMainApi();
  const second = fakeMainApi();

  tweak.__test.startMain(first.api, fakeMainDeps());
  assert.equal(first.handlers.length, 1);

  first.dispose();
  tweak.__test.startMain(second.api, fakeMainDeps());
  assert.equal(second.handlers.length, 1);
});
```

补充同一 lease 重复注册会由宿主拒绝、Renderer `stop()` 能移除 listener/notice 的断言。

- [ ] **Step 2: 运行定向测试确认 persistent flag 导致失败**

Run:

```powershell
node --test --test-name-pattern "Claude\+\+ API lease" `
  D:\workspace\unity-links-claude\test\index.test.js
```

Expected: FAIL，第二个 lease 没有收到 handler，证明 Codex 的 `globalThis[Symbol]` 状态不能直接照搬。

- [ ] **Step 3: 最小化修改 `startMain`**

Main 每次启动都向当前 lease 注册一次：

```js
function startMain(api, injectedDeps) {
  const deps = injectedDeps && Object.keys(injectedDeps).length > 0
    ? injectedDeps
    : defaultMainDeps(api);
  api.ipc.handle("open-asset", (candidate) => handleOpenAsset(candidate, deps));
}
```

移除 Codex 使用的 `Symbol.for(...)` / `globalThis` 注册状态，不在 Tweak 内自行跨 lease 保存 Main handler。
`start(api)` 仍按 `api.process` 分派；Renderer listener 的模块内状态和 `stop()` 清理保持 Codex 行为。

- [ ] **Step 4: 运行生命周期和完整测试**

Run:

```powershell
node --test --test-name-pattern "Claude\+\+ API lease|renderer" `
  D:\workspace\unity-links-claude\test\index.test.js
npm test --prefix D:\workspace\unity-links-claude
```

Expected: 定向与完整测试全部 PASS；每个新 lease 恰好注册一个 handler，旧 lease 的释放职责留给 Claude++ Runtime。

- [ ] **Step 5: 提交生命周期适配**

```powershell
git -C D:\workspace\unity-links-claude add index.js test/index.test.js
git -C D:\workspace\unity-links-claude commit -m "fix: align Main IPC lifecycle with Claude++ leases"
```

---

## Task 4: 用真实 Claude++ v0.2.1 SDK/Runtime 验证兼容性

**Files:**

- Create: `D:\workspace\unity-links-claude\scripts\compatibility\validate-claudeplusplus.mjs`
- Create: `D:\workspace\unity-links-claude\scripts\compatibility\validate-claudeplusplus.test.mjs`
- Modify: `D:\workspace\unity-links-claude\package.json`

- [ ] **Step 1: 先写兼容性脚本的 fixture 测试**

测试必须确认脚本会：

- 用 Claude++ `validateTweakManifest()` 验证真实 manifest；
- 用 Claude++ `evaluateRendererTweak()` 在 `require === undefined` 的 evaluator 中加载 `index.js`；
- 启动/停止 Renderer 后 listener 归零；
- 用 Claude++ `createMainTweakApiLease()` 注册 `claudepp:com.kpk.unity-asset-links:open-asset`；
- dispose 第一个 lease 后 handler 被移除，第二个 lease 可再次注册且只有一个有效 handler。

核心断言：

```js
const validation = validateTweakManifest(manifest);
assert.equal(validation.ok, true, JSON.stringify(validation.errors));

const rendererTweak = evaluateRendererTweak(source, tweakEntry, rendererApi);
await rendererTweak.start(rendererApi);
assert.equal(documentFixture.listenerCount("click"), 1);
await rendererTweak.stop();
assert.equal(documentFixture.listenerCount("click"), 0);

const first = createMainTweakApiLease(mainOptions);
tweak.__test.startMain(first.api, fakeMainDeps);
assert.equal(bridge.handlerCount(namespacedChannel), 1);
await first.dispose();
assert.equal(bridge.handlerCount(namespacedChannel), 0);
```

- [ ] **Step 2: 运行测试确认兼容性脚本缺失**

Run:

```powershell
node --test D:\workspace\unity-links-claude\scripts\compatibility\validate-claudeplusplus.test.mjs
```

Expected: FAIL，原因是兼容性入口尚未实现。

- [ ] **Step 3: 实现只读兼容性入口**

命令接口固定为：

```text
validate-claudeplusplus.mjs <claude-plusplus-root> <tweak-root>
```

脚本通过 `pathToFileURL` 导入：

```text
<claude-plusplus-root>/packages/sdk/src/index.ts
<claude-plusplus-root>/packages/runtime/src/preload/tweak-host.ts
<claude-plusplus-root>/packages/runtime/src/tweak-api.ts
```

它只读取两个仓库并构造内存 bridge/document/storage，不写 Claude++ checkout，不启动 Electron，不连接真实 Pipe。成功时输出：

```text
claudeplusplus-compatibility=passed runtime=0.2.1 tweak=0.1.0
```

- [ ] **Step 4: 在固定 Claude++ commit 上运行真实验证**

Run:

```powershell
git -C D:\Unity\ClaudePlusPlus rev-parse HEAD
npm run build --prefix D:\Unity\ClaudePlusPlus --workspace @claude-plusplus/sdk
npm run build --prefix D:\Unity\ClaudePlusPlus --workspace @claude-plusplus/runtime
node --import file:///D:/Unity/ClaudePlusPlus/node_modules/tsx/dist/loader.mjs `
  D:\workspace\unity-links-claude\scripts\compatibility\validate-claudeplusplus.mjs `
  D:\Unity\ClaudePlusPlus D:\workspace\unity-links-claude
```

Expected: HEAD 为 `6b7a0386cc351537f658c8a48fad1d25b6dd0385`，两次 build PASS，兼容性输出 PASS。
若本地 HEAD 不符，使用临时 checkout 固定 commit 验证，不修改现有 Claude++ 工作区。

- [ ] **Step 5: 把兼容测试加入 npm test 并提交**

`package.json`：

```json
"test": "node --test test/*.test.js scripts/release/*.test.mjs scripts/compatibility/*.test.mjs"
```

Run and commit:

```powershell
npm test --prefix D:\workspace\unity-links-claude
git -C D:\workspace\unity-links-claude add package.json scripts/compatibility
git -C D:\workspace\unity-links-claude commit -m "test: validate Claude++ runtime compatibility"
```

---

## Task 5: 补齐独立仓库文档与 CI/Release 工作流

**Files:**

- Create: `D:\workspace\unity-links-claude\README.md`
- Create: `D:\workspace\unity-links-claude\README.zh-CN.md`
- Create: `D:\workspace\unity-links-claude\.github\workflows\ci.yml`
- Create: `D:\workspace\unity-links-claude\.github\workflows\release.yml`
- Modify: `D:\workspace\unity-links-claude\scripts\release\validate-release.test.mjs`

- [ ] **Step 1: 先扩充发行测试，要求所有分发文件和文档存在**

增加断言：英文/中文 README 都说明 Windows-only、Claude++ v0.2.1、`scope: both`、Unity Package 是独立
组件、junction 由总仓库管理、无 Store 安装声明；CI 和 Release workflow 必须固定 Claude++ commit
`6b7a0386cc351537f658c8a48fad1d25b6dd0385`。

此时把最终分发白名单加入 `validate-release.mjs`：`.github/**`、`.gitignore`、
`scripts/compatibility/**`、`scripts/release/**`、`test/**`、`icon.png`、`index.js`、`LICENSE`、
`manifest.json`、`package.json`、`README.md`、`README.zh-CN.md`；忽略 `.git/**` 和本地 CI 工具目录
`.ci-tools/**` / `.release-tools/**`。测试必须拒绝缺失入口和白名单外文件。

- [ ] **Step 2: 运行发行测试确认失败**

```powershell
npm test --prefix D:\workspace\unity-links-claude
```

Expected: FAIL，缺少 README/workflow。

- [ ] **Step 3: 编写双语 README**

README 必须覆盖：

1. 点击 `Assets`、`ProjectSettings`、`Packages` 链接的行为；
2. 安全拒绝和 Unity 未运行时 Explorer 回退；
3. Claude++ 由其 `install.ps1` 安装，Tweak junction 由 umbrella 的 `Inject-ClaudePlusPlus.ps1` 管理；
4. Unity Package 通过 `Install-UnityPackage.ps1` 安装；
5. 本仓库不在 Claude++ Store；
6. `npm test`、兼容性验证和 v0.1.0 Release 流程；
7. MIT License。

- [ ] **Step 4: 编写 CI**

`.github/workflows/ci.yml` 对 push/PR 使用 Windows + Node 24，顺序为：

```yaml
- run: npm test
- run: node ./scripts/release/validate-release.mjs $env:GITHUB_WORKSPACE 0.1.0
- run: git diff --check
- uses: actions/checkout@v6
  with:
    repository: kpkhxlgy0/ClaudePlusPlus
    ref: 6b7a0386cc351537f658c8a48fad1d25b6dd0385
    path: .ci-tools/claude-plusplus
    persist-credentials: false
```

随后在 `.ci-tools/claude-plusplus` 执行 `npm ci --ignore-scripts`，构建 SDK/Runtime，并用该 checkout 的
`tsx/dist/loader.mjs` 执行兼容性脚本。

- [ ] **Step 5: 编写手动 Draft Release workflow**

Release workflow 与 Codex Tweak 保持相同保护：只允许 `master`、输入稳定版本、先执行完整测试、发行校验、
固定 Claude++ 兼容验证和 `git diff --check`，再创建或复用指向 `GITHUB_SHA` 的 `v0.1.0` tag，最后用
`gh release create --verify-tag --draft --generate-notes` 创建 Draft Release。不得自动发布 Store 或非 draft
Release。

- [ ] **Step 6: 全量验证和提交**

```powershell
npm test --prefix D:\workspace\unity-links-claude
node D:\workspace\unity-links-claude\scripts\release\validate-release.mjs `
  D:\workspace\unity-links-claude 0.1.0
git -C D:\workspace\unity-links-claude diff --check
git -C D:\workspace\unity-links-claude add README.md README.zh-CN.md .github scripts/release
git -C D:\workspace\unity-links-claude commit -m "docs: add Claude Unity Links distribution workflows"
```

---

## Task 6: 创建 GitHub 仓库并推送独立组件

**External state:**

- Create: `https://github.com/kpkhxlgy0/unity-links-claude`
- Push: local `master` to `origin/master`

- [ ] **Step 1: 执行外部写入前停下确认**

向用户报告独立仓库的 commit 列表、`npm test`、Claude++ 固定版本兼容结果、release validator 和
`git diff --check`。明确询问是否现在创建公开仓库并 push；未得到当前任务授权时不得继续。

- [ ] **Step 2: 创建公开非 fork 仓库**

授权后运行：

```powershell
gh repo create kpkhxlgy0/unity-links-claude `
  --public `
  --source D:\workspace\unity-links-claude `
  --remote origin
```

Expected: GitHub 显示独立根提交，不带 `unity-links-codex` fork 标记。

- [ ] **Step 3: 推送并核验**

```powershell
git -C D:\workspace\unity-links-claude push -u origin master
gh repo view kpkhxlgy0/unity-links-claude --json nameWithOwner,isFork,defaultBranchRef,url
```

Expected: `isFork: false`，默认分支 `master`，远端 HEAD 与本地 HEAD 相同。

---

## Task 7: 把 `claude-tweak` submodule 和布局契约加入总仓库

**Files:**

- Modify: `D:\workspace\sgproj\FilePackages\unity-links\.gitmodules`
- Add submodule: `D:\workspace\sgproj\FilePackages\unity-links\claude-tweak`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\UnityLinkCommon.psm1`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\UnityLinkMaintenance.Tests.ps1`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\ModuleBoundaries.Tests.ps1`

- [ ] **Step 1: 先扩展布局和 submodule 失败测试**

要求 `Get-UnityLinkRepositoryLayout` 新增但不重命名既有 Codex 字段：

```powershell
Assert-Equal (Join-Path $root "codex-tweak") $layout.TweakRoot
Assert-Equal (Join-Path $root "claude-tweak") $layout.ClaudeTweakRoot
Assert-Equal (Join-Path $root "claude-tweak/manifest.json") $layout.ClaudeTweakManifest
Assert-Equal (Join-Path $root "unity-package") $layout.PackageRoot
```

初始化测试创建三份 manifest，并调用：

```powershell
Assert-UnityLinkComponentInitialized -Layout $layout -Component CodexTweak
Assert-UnityLinkComponentInitialized -Layout $layout -Component ClaudeTweak
Assert-UnityLinkComponentInitialized -Layout $layout -Component UnityPackage
```

`.gitmodules` 测试增加：

```text
[submodule "claude-tweak"]
path = claude-tweak
url = git@github.com:kpkhxlgy0/unity-links-claude.git
```

- [ ] **Step 2: 运行 PowerShell 测试确认失败**

```powershell
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\Run-Tests.ps1
```

Expected: FAIL，缺少 Claude layout 和 submodule。

- [ ] **Step 3: 添加 submodule**

```powershell
git -C D:\workspace\sgproj\FilePackages\unity-links submodule add `
  git@github.com:kpkhxlgy0/unity-links-claude.git claude-tweak
```

确认 `.gitmodules` 使用上述 SSH URL，submodule HEAD 等于独立仓库已推送的 `master` commit。

- [ ] **Step 4: 最小扩展公共布局函数**

`Get-UnityLinkRepositoryLayout` 保留 `TweakRoot` / `TweakManifest` 作为 Codex 兼容字段，新增：

```powershell
ClaudeTweakRoot = Join-Path $root "claude-tweak"
ClaudeTweakManifest = Join-Path $root "claude-tweak/manifest.json"
```

`Assert-UnityLinkComponentInitialized` 的 ValidateSet 改为
`("CodexTweak", "ClaudeTweak", "UnityPackage")`，用 `switch` 精确选择三个 manifest。缺失时仍只报告同一条
`git -C "<root>" submodule update --init --recursive` 命令。

- [ ] **Step 5: 运行布局测试并提交**

```powershell
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\Run-Tests.ps1
git -C D:\workspace\sgproj\FilePackages\unity-links diff --check
git -C D:\workspace\sgproj\FilePackages\unity-links add `
  .gitmodules claude-tweak scripts/UnityLinkCommon.psm1 `
  scripts/tests/UnityLinkMaintenance.Tests.ps1 scripts/tests/ModuleBoundaries.Tests.ps1
git -C D:\workspace\sgproj\FilePackages\unity-links commit -m "feat: pin Claude++ Unity Links component"
```

---

## Task 8: 增加 Claude++ junction 注入和卸载入口

**Files:**

- Create: `D:\workspace\sgproj\FilePackages\unity-links\Inject-ClaudePlusPlus.ps1`
- Create: `D:\workspace\sgproj\FilePackages\unity-links\Uninject-ClaudePlusPlus.ps1`
- Create: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\InjectClaudeCheckOnly.Integration.ps1`
- Create: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\UninjectClaudeCheckOnly.Integration.ps1`
- Create: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\TweakJunctionIsolation.Integration.ps1`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\ModuleBoundaries.Tests.ps1`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\Run-Tests.ps1`
- Reuse unchanged: `D:\workspace\sgproj\FilePackages\unity-links\scripts\CodexTweakLink.psm1`

- [ ] **Step 1: 先写 Claude junction 集成测试**

在临时 `APPDATA` 下验证：

- Inject `-CheckOnly` 报 `LinkRequired` 且不创建路径；
- Inject 创建指向 `$layout.ClaudeTweakRoot` 的 junction，再次运行幂等；
- 普通目录、symlink 和未知 reparse point 返回安全阻断且原内容保留；
- Uninject `-CheckOnly` 报 `UninjectRequired` 且不删除；
- Uninject 只删除精确 junction，保留同级 sentinel 和源目录；
- Claude 操作不改 `%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links`；
- Codex 操作不改 `%APPDATA%\claude-plusplus\tweaks\com.kpk.unity-asset-links`。

`Run-Tests.ps1` 的发现范围改为同时运行 `*.Tests.ps1` 和 `*.Integration.ps1`，去重后按名称排序；这样现有 Codex 集成测试和新增 Claude 集成测试都进入本地/CI 门禁。

- [ ] **Step 2: 运行测试确认入口缺失**

```powershell
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\Run-Tests.ps1
```

Expected: FAIL，缺少两个 Claude 入口。

- [ ] **Step 3: 按 Codex 入口逐行复刻 Claude 入口**

Inject 的唯一参数和核心值：

```powershell
[CmdletBinding()]
param([switch] $CheckOnly)

Assert-UnityLinkComponentInitialized -Layout $layout -Component ClaudeTweak
$linkPath = Join-Path $env:APPDATA "claude-plusplus/tweaks/com.kpk.unity-asset-links"
$linkState = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $layout.ClaudeTweakRoot
```

Uninject 使用同一路径和 expected target。两者继续复用现有 `CodexTweakLink.psm1` 的通用 junction 函数；
为避免破坏现有 Codex 入口，不重命名该模块，也不复制第二套 junction 算法。

输出文案只把宿主改成 Claude：junction 变化后提示 `Restart Claude`。不得导入
`CodexPlusPlusMaintenance.psm1`，不得调用 Claude++ `install.ps1`、Appx、mirror、launcher、注册表、
`Start-Process`、`Stop-Process` 或应用关闭/启动逻辑。

- [ ] **Step 4: 扩展 PowerShell 7 和边界测试**

`ModuleBoundaries.Tests.ps1` 的 public entry points 增加两个 Claude 脚本，确认 Windows PowerShell 5.1
通过 `#Requires -Version 7.0` 失败。读取两个脚本文本并断言：

```powershell
Assert-True ($text.Contains('claude-plusplus/tweaks/com.kpk.unity-asset-links'))
Assert-True ($text.Contains('CodexTweakLink.psm1'))
Assert-True (!$text.Contains('CodexPlusPlusMaintenance.psm1'))
Assert-True (!$text.Contains('Start-Process'))
Assert-True (!$text.Contains('Stop-Process'))
Assert-True (!$text.Contains('Get-AppxPackage'))
Assert-True (!$text.Contains('Registry'))
```

- [ ] **Step 5: 运行完整 PowerShell 测试并提交**

```powershell
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\Run-Tests.ps1
git -C D:\workspace\sgproj\FilePackages\unity-links diff --check
git -C D:\workspace\sgproj\FilePackages\unity-links add `
  Inject-ClaudePlusPlus.ps1 Uninject-ClaudePlusPlus.ps1 scripts/tests
git -C D:\workspace\sgproj\FilePackages\unity-links commit -m "feat: manage Claude++ Unity Links junction"
```

Expected: 现有 Codex、Unity Package、Claude junction 和交叉隔离测试全部 PASS。

---

## Task 9: 更新总仓库文档和独立组件版本发布验证

**Files:**

- Modify: `D:\workspace\sgproj\FilePackages\unity-links\README.md`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\README.zh-CN.md`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\docs\design.md`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\release\validate-release.mjs`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\release\validate-release.test.mjs`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\.github\workflows\release.yml`
- Modify: `D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\UnityLinkMaintenance.Tests.ps1`

- [ ] **Step 1: 先写三组件发行契约失败测试**

总仓库保留一个 umbrella `version` 输入，但三个组件独立版本：

```js
assert.deepEqual(validateRelease(root, "0.2.2"), {
  version: "0.2.2",
  tag: "v0.2.2",
  componentVersions: {
    codexTweak: "0.2.2",
    claudeTweak: "0.1.0",
    unityPackage: "0.2.3",
  },
});
```

校验规则改为：

- umbrella `requestedVersion` 只决定总仓库 tag，仍要求稳定 semver；
- Codex manifest/package 版本必须彼此相等；
- Claude manifest/package 版本必须彼此相等；
- Unity package 版本独立；
- 三个组件版本都必须是稳定 semver，但不要求相互相等或等于 umbrella version；
- 三个 repo/license/submodule 元数据各自正确。

这样消除现有单一版本假设，精确支持 `0.2.2` / `0.1.0` / `0.2.3`。

- [ ] **Step 2: 运行发行测试确认旧校验器失败**

```powershell
node --test D:\workspace\sgproj\FilePackages\unity-links\scripts\release\validate-release.test.mjs
```

Expected: FAIL，旧实现缺少 Claude 组件且强制所有组件等于 requestedVersion。

- [ ] **Step 3: 实现独立组件版本校验**

新增：

```js
const EXPECTED_CODEX_REPOSITORY = "kpkhxlgy0/unity-links-codex";
const EXPECTED_CLAUDE_REPOSITORY = "kpkhxlgy0/unity-links-claude";
```

读取 `claude-tweak/manifest.json` 与 `claude-tweak/package.json`，验证 manifest 精确身份、
`minRuntime: 0.2.1`、`scope: both`、`main: index.js`、`permissions: ["ipc", "filesystem"]`；
`.gitmodules` 必须包含三个组件。CLI 成功输出同时打印三个组件版本，供发布日志审阅。

- [ ] **Step 4: 更新总仓库 Release workflow**

保持现有 Codex++ 固定校验不变，并新增：

1. `node --test ./claude-tweak/test/index.test.js`；
2. checkout `kpkhxlgy0/ClaudePlusPlus` commit `6b7a0386cc351537f658c8a48fad1d25b6dd0385` 到
   `.release-tools/claude-plusplus`；
3. `npm ci --ignore-scripts`，构建 Claude++ SDK/Runtime；
4. 通过 submodule 内兼容脚本验证 Claude Tweak；
5. 组件 tag 检查从各组件自身 metadata 读取版本：

```powershell
$components = @(
    @{ Path = "codex-tweak"; Version = (Get-Content codex-tweak/manifest.json -Raw | ConvertFrom-Json).version },
    @{ Path = "claude-tweak"; Version = (Get-Content claude-tweak/manifest.json -Raw | ConvertFrom-Json).version },
    @{ Path = "unity-package"; Version = (Get-Content unity-package/package.json -Raw | ConvertFrom-Json).version })

foreach ($component in $components)
{
    $tag = "v$($component.Version)"
    git -C $component.Path fetch --tags origin
    # 要求 submodule HEAD 精确等于该 tag commit
}
```

总仓库自身仍用 `inputs.version` 创建 Draft Release tag；不要把三个组件强制成同一个版本。

- [ ] **Step 5: 更新双语文档和设计说明**

README 变成 Codex++ / Claude++ 双接收端说明，明确：

- `claude-tweak` 第三个 submodule；
- Claude++ 用自身 `install.ps1` 安装，不需要 Node.js 作为 Unity Links 日常依赖；
- `Inject-ClaudePlusPlus.ps1` / `Uninject-ClaudePlusPlus.ps1` 只管 junction；
- Codex 维护脚本不管理 Claude，Claude junction 脚本不管理 Codex；
- 两端共用一个 Unity Package；
- Claude 第一版不在 Store；
- 移动仓库后分别重跑需要的 Inject；
- 发布顺序和三个独立版本/tag。

`docs/design.md` 从 Codex-only 拓展为双宿主架构，保留 Named Pipe、安全和 Unity 行为章节；明确 Claude lease 是唯一宿主内部差异。

- [ ] **Step 6: 运行发行和总仓库测试**

```powershell
node --test D:\workspace\sgproj\FilePackages\unity-links\scripts\release\validate-release.test.mjs
node D:\workspace\sgproj\FilePackages\unity-links\scripts\release\validate-release.mjs `
  D:\workspace\sgproj\FilePackages\unity-links 0.2.2
$env:UNITY_LINKS_SKIP_UNITY_PROJECT_TESTS = "1"
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\Run-Tests.ps1
Remove-Item Env:UNITY_LINKS_SKIP_UNITY_PROJECT_TESTS
git -C D:\workspace\sgproj\FilePackages\unity-links diff --check
```

Expected: 全部 PASS；校验输出三个实际组件版本。

- [ ] **Step 7: 提交总仓库发行与文档更新**

```powershell
git -C D:\workspace\sgproj\FilePackages\unity-links add `
  README.md README.zh-CN.md docs/design.md .github/workflows/release.yml `
  scripts/release scripts/tests/UnityLinkMaintenance.Tests.ps1
git -C D:\workspace\sgproj\FilePackages\unity-links commit -m "docs: integrate Claude++ Unity Links distribution"
```

---

## Task 10: 全量自动验证和偏差审计

**Files:**

- Verify only: `D:\workspace\unity-links-claude\**`
- Verify only: `D:\workspace\sgproj\FilePackages\unity-links\**`
- Verify unchanged: `D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\**`
- Verify unchanged: `D:\workspace\sgproj\FilePackages\unity-links\unity-package\**`
- Verify unchanged: `D:\Unity\ClaudePlusPlus\**`

- [ ] **Step 1: 独立 Tweak 全量门禁**

```powershell
npm test --prefix D:\workspace\unity-links-claude
node D:\workspace\unity-links-claude\scripts\release\validate-release.mjs `
  D:\workspace\unity-links-claude 0.1.0
node --import file:///D:/Unity/ClaudePlusPlus/node_modules/tsx/dist/loader.mjs `
  D:\workspace\unity-links-claude\scripts\compatibility\validate-claudeplusplus.mjs `
  D:\Unity\ClaudePlusPlus D:\workspace\unity-links-claude
git -C D:\workspace\unity-links-claude diff --check
git -C D:\workspace\unity-links-claude status --short
```

Expected: 全部 PASS，status clean。

- [ ] **Step 2: 总仓库全量门禁**

```powershell
$env:UNITY_LINKS_SKIP_UNITY_PROJECT_TESTS = "1"
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\scripts\tests\Run-Tests.ps1
Remove-Item Env:UNITY_LINKS_SKIP_UNITY_PROJECT_TESTS
node --test D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\test\index.test.js
node --test D:\workspace\sgproj\FilePackages\unity-links\claude-tweak\test\index.test.js
node --test D:\workspace\sgproj\FilePackages\unity-links\scripts\release\validate-release.test.mjs
git -C D:\workspace\sgproj\FilePackages\unity-links diff --check
git -C D:\workspace\sgproj\FilePackages\unity-links submodule status --recursive
```

Expected: 全部 PASS，三个 submodule 都已初始化且没有 `-`、`+` 或冲突标记。

- [ ] **Step 3: 做 Codex-first 源码偏差审计**

比较两个 `index.js` 和两份行为测试。审计结论必须逐项归类为：

1. Claude 用户可见文案；
2. manifest/repository/runtime metadata；
3. 已批准的 Claude API lease handler 生命周期；
4. 无其他差异。

任何第四类之外无法解释的实现差异都必须先修复或向用户确认。尤其确认路径解析、项目识别、安全校验、Pipe 名、请求 JSON、超时、Explorer 回退和 replay 行为完全一致。

- [ ] **Step 4: 确认禁止修改的仓库和 submodule 未漂移**

```powershell
git -C D:\workspace\sgproj\FilePackages\unity-links diff --submodule=log master...HEAD -- codex-tweak unity-package
git -C D:\Unity\ClaudePlusPlus status --short
```

Expected: `codex-tweak` 与 `unity-package` 指针未改变，Claude++ 工作区没有本任务产生的修改。

---

## Task 11: junction 实装与真实 Claude → Unity 点击验收

**Files / state:**

- Junction: `%APPDATA%\claude-plusplus\tweaks\com.kpk.unity-asset-links`
- Existing Unity receiver: installed `com.kpk.unity-asset-links` package
- User-operated apps: Claude Desktop、匹配项目的 Unity Editor

- [ ] **Step 1: 只读检查 junction 状态**

```powershell
pwsh -NoProfile -File `
  D:\workspace\sgproj\FilePackages\unity-links\Inject-ClaudePlusPlus.ps1 -CheckOnly
```

Expected: `Current` 或 `LinkRequired`；`Blocked` 时停止，不覆盖普通目录或未知 reparse point。

- [ ] **Step 2: 请求用户关闭 Claude 后注入**

说明脚本只创建 junction，不会关闭或启动 Claude。用户确认 Claude 已关闭后运行：

```powershell
pwsh -NoProfile -File `
  D:\workspace\sgproj\FilePackages\unity-links\Inject-ClaudePlusPlus.ps1
```

Expected: junction 精确指向 `claude-tweak` submodule；Codex junction 不变。

- [ ] **Step 3: 用户重开 Claude 并验证 Tweak 已加载**

不使用 Windows UI 自动化。请用户确认 Claude++ Tweak 列表显示 `Unity Asset Links`，没有 load/manifest 错误。

- [ ] **Step 4: 在现有 Unity 项目做五类点击**

由用户在 Claude 回复中点击真实绝对路径链接：

1. `Assets` 资源；
2. 带 `:line:column` 的脚本；
3. `ProjectSettings` 文件；
4. `Packages` 文件；
5. 不支持的 web/相对路径。

Expected: 前四项进入匹配 Unity 和对应 UI；第五项保留 Claude 原行为。一次点击只执行一次。

- [ ] **Step 5: 验证 Unity 未运行和热重载**

用户关闭匹配 Unity 后再点受支持链接：只在 Explorer 定位并显示短提示，不启动 Unity。随后重启/热重载 Claude++ 再测试一次：仍只触发一个 handler，没有重复打开。

- [ ] **Step 6: 验证 Codex/Claude 并存**

保持两个 junction 同时存在，分别从 Codex 和 Claude 点击同一项目的 Unity 链接。Expected: 两端都通过同一 Unity Package 工作，互不移除 junction、不串工作区、无重复执行。

- [ ] **Step 7: 记录验收证据**

记录自动测试输出、Claude++ Tweak 列表截图，以及至少一张 `Assets` 打开成功截图；若用户方便，补一段包含 Claude 点击和 Unity 响应的短录屏。不要把包含内部绝对路径或敏感项目内容的截图提交到公开仓库。

---

## Task 12: 发布 v0.1.0 并固定最终 submodule

**External state:**

- Tag/Release: `kpkhxlgy0/unity-links-claude` `v0.1.0`
- Update/push: umbrella `claude-tweak` gitlink if release commit differs

- [ ] **Step 1: 发布前再次请求外部写入授权**

向用户汇报实机验收、两个仓库 HEAD、独立组件 release validator 和总仓库测试结果。得到明确“提交/推送/发布”授权后继续。

- [ ] **Step 2: 推送独立组件最终 commit**

```powershell
git -C D:\workspace\unity-links-claude push origin master
```

Expected: `origin/master` 等于本地 HEAD，工作树 clean。

- [ ] **Step 3: 触发独立组件 v0.1.0 Release workflow**

```powershell
gh workflow run release.yml `
  --repo kpkhxlgy0/unity-links-claude `
  --ref master `
  -f version=0.1.0
gh run watch --repo kpkhxlgy0/unity-links-claude --exit-status
```

Expected: workflow 创建指向 master HEAD 的 `v0.1.0` tag 和 Draft Release；不写 Claude++ Store。

- [ ] **Step 4: 核验 tag 和 Release**

```powershell
git -C D:\workspace\unity-links-claude fetch --tags origin
git -C D:\workspace\unity-links-claude rev-parse HEAD
git -C D:\workspace\unity-links-claude rev-list -n 1 v0.1.0
gh release view v0.1.0 --repo kpkhxlgy0/unity-links-claude --json isDraft,tagName,targetCommitish,url
```

Expected: HEAD 与 tag commit 相同，Release 为 Draft。由用户审阅后决定何时 publish；不得自动提交 Store。

- [ ] **Step 5: 固定并提交 umbrella gitlink**

如果 `claude-tweak` 已经指向 tag commit，只需验证；否则更新到 `v0.1.0` 后重新跑 Task 10 总仓库门禁，再提交：

```powershell
git -C D:\workspace\sgproj\FilePackages\unity-links\claude-tweak fetch --tags origin
git -C D:\workspace\sgproj\FilePackages\unity-links\claude-tweak checkout v0.1.0
git -C D:\workspace\sgproj\FilePackages\unity-links add claude-tweak
git -C D:\workspace\sgproj\FilePackages\unity-links commit -m "chore: pin Claude Unity Links v0.1.0"
```

- [ ] **Step 6: 最终交付报告**

报告两个仓库、commit/tag/Release URL、自动测试、实机验收、junction 目标和未做事项（Claude++ Store、
Unreal Links）。未收到 push 授权时，总仓库只保留本地 commits，不自行 push。

---

## Final Self-Review Checklist

- [ ] 每个设计要求都映射到上述任务和测试，没有待定占位符、模糊路径或未定义接口。
- [ ] Claude Tweak 对 Codex v0.2.2 的所有 22 个行为测试都有对应测试。
- [ ] 唯一代码行为差异是 Claude++ API lease 的 Main handler 生命周期。
- [ ] Renderer 经过 Claude++ 真实 `require === undefined` evaluator 验证。
- [ ] Main 经过 Claude++ 真实 lease dispose/reload 验证。
- [ ] `codex-tweak`、`unity-package`、Claude++ 本体和 Named Pipe 协议未修改。
- [ ] 两个 Claude junction 脚本不安装/维护应用，也不修改注册表或控制进程。
- [ ] 三个 submodule 使用独立版本和对应 tag，不再错误假设版本相同。
- [ ] 发布只创建 Draft Release，不加入 Claude++ Store。
- [ ] 真实点击证明 Claude → Claude++ → Pipe → Unity 完整链路可用。
