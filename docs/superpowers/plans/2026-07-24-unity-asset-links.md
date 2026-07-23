# Unity Asset Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build a lightweight Codex++ 1.0.0 tweak that routes normal clicks on files below a detected Unity project's Assets directory to that project's running Unity Editor.

**Architecture:** A scope=both Codex++ tweak parses links in the renderer and performs trusted path and Named Pipe work in the Electron main process. An Editor-only local UPM package listens on a project-specific Pipe, validates every request against its own project root, and invokes AssetDatabase.OpenAsset on Unity's main thread.

**Tech Stack:** Codex++ 1.0.0 tweak API, CommonJS JavaScript, Node 20+ built-ins, Electron shell, Windows Named Pipes, Unity 2022.3 Editor C#, Unity Package Manager.

## Global Constraints

- Source root is D:\workspace\codex-tweaks\unity-links and is a standalone Git repository.
- Do not copy tweak or receiver source into D:\workspace\sgproj\Assets.
- Codex++ runtime floor is exactly 1.0.0; the tweak version starts at 0.1.0.
- Runtime code has no third-party npm or Unity package dependencies.
- Only existing files strictly below a detected project Assets directory are routed to Unity.
- Modified clicks, directories, non-local URLs, and files outside Assets preserve Codex behavior.
- Unity is never launched automatically; unavailable Unity falls back to Explorer reveal plus a short Codex notice.
- The transport is Windows Named Pipe only; no TCP listener, MCP server, or helper executable.
- The Unity receiver exposes only openAsset and independently validates project root and asset containment.
- Unity 2022.3's bundled .NET 4.8 reference exposes only None, Asynchronous, and WriteThrough PipeOptions; do not use CurrentUserOnly. Exact project-root matching, Assets containment, reparse-point rejection, and the single openAsset action are mandatory compensating controls.
- The Unity assembly is Editor-only and must not enter player builds.
- Do not run codexplusplus debug without --app on Codex++ 1.0.0 because it remirrors the Store ASAR over the patch.
- Do not run Unity automated tests or battle regression tests; this task uses Node tests, direct protocol checks, Unity compile, and Console verification.
- Packages/manifest.json and a Unity-generated Packages/packages-lock.json change remain local/default-changelist changes unless the user explicitly requests Perforce submission.
- Read D:\workspace\sgproj\docs\agent-rules\verification.md before the Unity integration task.

---

## Planned File Map

- Create codex-tweak/manifest.json: Codex++ metadata, scope, and permission declarations.
- Create codex-tweak/package.json: dependency-free Node test commands.
- Create codex-tweak/index.js: pure parsing helpers, main-process routing and transport, renderer click lifecycle.
- Create codex-tweak/test/index.test.js: built-in node:test coverage for parsing, routing, transport, reload, and click eligibility.
- Create codex-tweak/scripts/send-open.js: direct protocol smoke client independent of the Codex UI.
- Create unity-package/package.json: local UPM package metadata.
- Create unity-package/Editor/KPK.CodexUnityLink.Editor.asmdef: Editor-only assembly boundary.
- Create unity-package/Editor/UnityAssetLinkProtocol.cs: request/response DTOs and bounded JSON protocol.
- Create unity-package/Editor/UnityAssetLinkPath.cs: root normalization, Pipe identity, and safe asset resolution.
- Create unity-package/Editor/UnityAssetLinkReceiver.cs: Pipe lifetime, main-thread queue, and AssetDatabase.OpenAsset.
- Create README.md: installation, use, recovery, and removal.
- Modify D:\workspace\sgproj\Packages\manifest.json: add one local file dependency.
- Unity may modify D:\workspace\sgproj\Packages\packages-lock.json: generated lock entry; review but do not hand-author it.

---

### Task 1: Tweak Manifest and Pure Link Parsing

**Files:**
- Create: codex-tweak/manifest.json
- Create: codex-tweak/package.json
- Create: codex-tweak/index.js
- Create: codex-tweak/test/index.test.js

**Interfaces:**
- Produces: parseDestination(raw) -> { path, line, column } | null.
- Produces: hasAssetsSegment(path) -> boolean.
- Produces: isEligibleClick(event) -> boolean.
- Produces: normalizeProjectRoot(path, pathApi) -> string.
- Produces: pipeNameForProjectRoot(path, cryptoApi, pathApi) -> string.
- Produces: module.exports.__test for Node-only tests.

- [ ] **Step 1: Write the initial manifest and package metadata**

Create codex-tweak/manifest.json with exactly:

    {
      "id": "com.kpk.unity-asset-links",
      "name": "Unity Asset Links",
      "version": "0.1.0",
      "githubRepo": "kpk-local/unity-asset-links",
      "description": "Open Codex file links under Assets in the matching Unity Editor.",
      "author": "KPK",
      "tags": ["unity", "links", "workflow"],
      "minRuntime": "1.0.0",
      "scope": "both",
      "main": "index.js",
      "permissions": ["ipc", "filesystem"]
    }

Create codex-tweak/package.json with exactly:

    {
      "name": "kpk-codex-unity-asset-links",
      "version": "0.1.0",
      "private": true,
      "scripts": {
        "test": "node --test test/*.test.js"
      }
    }

- [ ] **Step 2: Write failing parser tests**

Create codex-tweak/test/index.test.js with these initial tests:

    const test = require("node:test");
    const assert = require("node:assert/strict");
    const crypto = require("node:crypto");
    const path = require("node:path");
    const { __test } = require("../index.js");

    test("parses Windows paths with line and column", () => {
      assert.deepEqual(
        __test.parseDestination("D:/workspace/sgproj/Assets/GameEntry.cs:12:4"),
        {
          path: "D:\\workspace\\sgproj\\Assets\\GameEntry.cs",
          line: 12,
          column: 4,
        },
      );
    });

    test("parses file URLs emitted by Markdown renderers", () => {
      assert.deepEqual(
        __test.parseDestination("file:///D:/workspace/sgproj/Assets/Light.prefab"),
        {
          path: "D:\\workspace\\sgproj\\Assets\\Light.prefab",
          line: 0,
          column: 0,
        },
      );
    });

    test("rejects web URLs and relative paths", () => {
      assert.equal(__test.parseDestination("https://example.com/Assets/a.prefab"), null);
      assert.equal(__test.parseDestination("Assets/a.prefab"), null);
    });

    test("recognizes only a complete Assets segment", () => {
      assert.equal(__test.hasAssetsSegment("D:\\p\\Assets\\a.prefab"), true);
      assert.equal(__test.hasAssetsSegment("D:\\p\\AssetsBackup\\a.prefab"), false);
    });

    test("accepts only an unmodified primary click", () => {
      assert.equal(
        __test.isEligibleClick({
          button: 0,
          defaultPrevented: false,
          altKey: false,
          ctrlKey: false,
          metaKey: false,
          shiftKey: false,
        }),
        true,
      );
      assert.equal(
        __test.isEligibleClick({
          button: 0,
          defaultPrevented: false,
          altKey: false,
          ctrlKey: true,
          metaKey: false,
          shiftKey: false,
        }),
        false,
      );
    });

    test("builds a deterministic case-insensitive project Pipe name", () => {
      const actual = __test.pipeNameForProjectRoot(
        "D:\\workspace\\sgproj\\",
        crypto,
        path.win32,
      );
      assert.equal(
        actual,
        "kpk-codex-unity-link-v1-89889fa57e5a473624456426acde9465c1669501e10ce77420e48f45f190662d",
      );
    });

- [ ] **Step 3: Run the tests and verify the module is missing**

Run:

    cd D:\workspace\codex-tweaks\unity-links\codex-tweak
    npm test

Expected: FAIL because index.js or __test is missing.

- [ ] **Step 4: Implement the pure parser and identity helpers**

Create codex-tweak/index.js with this complete initial module:

    const PIPE_PREFIX = "kpk-codex-unity-link-v1-";
    let rendererCleanup;

    function parseDestination(raw) {
      if (typeof raw !== "string" || raw.trim() === "") return null;
      let value = raw.trim();
      if (/^(https?|mailto):/i.test(value)) return null;

      if (/^file:/i.test(value)) {
        try {
          const url = new URL(value);
          if (url.protocol !== "file:" || (url.hostname && url.hostname !== "localhost")) {
            return null;
          }
          value = decodeURIComponent(url.pathname);
        } catch {
          return null;
        }
      } else {
        try {
          value = decodeURIComponent(value);
        } catch {
          return null;
        }
      }

      value = value.replace(/^\/([A-Za-z]:[\\/])/, "$1");
      const parsed = splitLineColumn(value);
      if (!/^[A-Za-z]:[\\/]/.test(parsed.path)) return null;
      return {
        path: parsed.path.replace(/\//g, "\\"),
        line: parsed.line,
        column: parsed.column,
      };
    }

    function splitLineColumn(value) {
      let match = /^(.*):(\d+):(\d+)$/.exec(value);
      if (match) {
        return {
          path: match[1],
          line: Number(match[2]),
          column: Number(match[3]),
        };
      }
      match = /^(.*):(\d+)$/.exec(value);
      if (match) {
        return { path: match[1], line: Number(match[2]), column: 0 };
      }
      return { path: value, line: 0, column: 0 };
    }

    function hasAssetsSegment(filePath) {
      return /[\\/]Assets[\\/]/i.test(filePath);
    }

    function isEligibleClick(event) {
      return event.button === 0
        && !event.defaultPrevented
        && !event.altKey
        && !event.ctrlKey
        && !event.metaKey
        && !event.shiftKey;
    }

    function normalizeProjectRoot(projectRoot, pathApi) {
      const resolved = pathApi.resolve(projectRoot).replace(/\//g, "\\");
      return resolved.replace(/[\\]+$/, "").toLowerCase();
    }

    function pipeNameForProjectRoot(projectRoot, cryptoApi, pathApi) {
      const normalized = normalizeProjectRoot(projectRoot, pathApi);
      const digest = cryptoApi.createHash("sha256").update(normalized, "utf8").digest("hex");
      return PIPE_PREFIX + digest;
    }

    function start(api) {
      if (api.process === "renderer") return;
    }

    function stop() {
      if (rendererCleanup) {
        rendererCleanup();
        rendererCleanup = undefined;
      }
    }

    module.exports = {
      start,
      stop,
      __test: {
        parseDestination,
        splitLineColumn,
        hasAssetsSegment,
        isEligibleClick,
        normalizeProjectRoot,
        pipeNameForProjectRoot,
      },
    };

- [ ] **Step 5: Run tests and validate the tweak**

Run:

    npm test
    codexplusplus validate-tweak D:\workspace\codex-tweaks\unity-links\codex-tweak

Expected: all six tests PASS; validation reports a valid tweak and existing index.js.

- [ ] **Step 6: Commit Task 1**

Run:

    git -C D:\workspace\codex-tweaks\unity-links add codex-tweak
    git -C D:\workspace\codex-tweaks\unity-links commit -m "feat: parse Unity asset links"

Expected: one commit containing only the four Task 1 files.

---

### Task 2: Main-Process Project Routing and Named Pipe Client

**Files:**
- Modify: codex-tweak/index.js
- Modify: codex-tweak/test/index.test.js
- Create: codex-tweak/scripts/send-open.js

**Interfaces:**
- Consumes: parseDestination and pipeNameForProjectRoot from Task 1.
- Produces: findUnityTarget(filePath, fsApi, pathApi) -> routing result.
- Produces: sendPipeRequest(pipePath, payload, deps) -> Promise of Unity response.
- Produces: handleOpenAsset(candidate, deps) -> Promise of renderer-facing result.
- Produces: startMain(api, deps) with reload-safe one-time IPC registration.

- [ ] **Step 1: Add failing routing, transport, and reload tests**

Append imports to codex-tweak/test/index.test.js:

    const fs = require("node:fs");
    const os = require("node:os");
    const net = require("node:net");

Append these tests:

    test("finds the nearest Unity root and produces an Assets path", () => {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-unity-link-"));
      try {
        fs.mkdirSync(path.join(root, "Assets", "Data"), { recursive: true });
        fs.mkdirSync(path.join(root, "ProjectSettings"), { recursive: true });
        fs.writeFileSync(path.join(root, "ProjectSettings", "ProjectVersion.txt"), "m_EditorVersion: 2022.3.23f1");
        const file = path.join(root, "Assets", "Data", "A.asset");
        fs.writeFileSync(file, "asset");
        const result = __test.findUnityTarget(file, fs, path);
        assert.equal(result.ok, true);
        assert.equal(result.assetPath, "Assets/Data/A.asset");
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    });

    test("does not route a directory or a file outside Assets", () => {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-unity-link-"));
      try {
        fs.mkdirSync(path.join(root, "Assets"), { recursive: true });
        fs.mkdirSync(path.join(root, "ProjectSettings"), { recursive: true });
        fs.writeFileSync(path.join(root, "ProjectSettings", "ProjectVersion.txt"), "version");
        fs.writeFileSync(path.join(root, "outside.txt"), "outside");
        assert.equal(__test.findUnityTarget(path.join(root, "Assets"), fs, path).code, "notAssetFile");
        assert.equal(__test.findUnityTarget(path.join(root, "outside.txt"), fs, path).code, "notAssetFile");
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    });

    test("round trips one newline-delimited request over a Windows Pipe", async () => {
      const pipeName = "kpk-codex-unity-link-test-" + process.pid + "-" + Date.now();
      const pipePath = "\\\\.\\pipe\\" + pipeName;
      const server = net.createServer((socket) => {
        socket.once("data", (data) => {
          const request = JSON.parse(data.toString("utf8").trim());
          socket.end(JSON.stringify({
            version: 1,
            requestId: request.requestId,
            ok: true,
            code: "opened",
            message: "",
          }) + "\n");
        });
      });
      await new Promise((resolve, reject) => server.listen(pipePath, resolve).once("error", reject));
      try {
        const response = await __test.sendPipeRequest(
          pipePath,
          { version: 1, requestId: "r1", action: "openAsset" },
          { net, connectTimeoutMs: 300, responseTimeoutMs: 1000 },
        );
        assert.equal(response.code, "opened");
      } finally {
        await new Promise((resolve) => server.close(resolve));
      }
    });

    test("registers the main IPC handler only once across hot reloads", () => {
      const key = Symbol.for("com.kpk.unity-asset-links.main-runtime");
      delete globalThis[key];
      let registrations = 0;
      const api = {
        ipc: {
          handle() {
            registrations += 1;
          },
        },
      };
      __test.startMain(api, {});
      __test.startMain(api, {});
      assert.equal(registrations, 1);
      delete globalThis[key];
    });

    test("reveals an asset when the matching Unity Pipe is unavailable", async () => {
      const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-unity-link-"));
      try {
        fs.mkdirSync(path.join(root, "Assets"), { recursive: true });
        fs.mkdirSync(path.join(root, "ProjectSettings"), { recursive: true });
        fs.writeFileSync(path.join(root, "ProjectSettings", "ProjectVersion.txt"), "version");
        const file = path.join(root, "Assets", "A.asset");
        fs.writeFileSync(file, "asset");
        const revealed = [];
        const result = await __test.handleOpenAsset(
          { path: file, line: 0, column: 0 },
          {
            crypto,
            fs,
            net,
            path,
            shell: {
              showItemInFolder(value) {
                revealed.push(value);
              },
              openPath: async () => "",
            },
            log: { warn() {} },
            sendPipeRequest: async () => {
              throw new Error("unavailable");
            },
          },
        );
        assert.equal(result.code, "unityUnavailable");
        assert.deepEqual(revealed, [fs.realpathSync(file)]);
      } finally {
        fs.rmSync(root, { recursive: true, force: true });
      }
    });

- [ ] **Step 2: Run the focused tests and verify the new functions are missing**

Run:

    npm test

Expected: existing parser tests PASS; new tests FAIL because findUnityTarget, sendPipeRequest, and startMain are undefined.

- [ ] **Step 3: Implement target discovery**

Add these functions above start() in codex-tweak/index.js and export them through __test:

    function findUnityTarget(candidatePath, fsApi, pathApi) {
      let absolute;
      try {
        absolute = fsApi.realpathSync(candidatePath);
        if (!fsApi.statSync(absolute).isFile()) {
          return { ok: false, handled: false, code: "notAssetFile" };
        }
      } catch {
        return {
          ok: false,
          handled: true,
          code: "fileMissing",
          message: "The linked file does not exist.",
        };
      }

      let current = pathApi.dirname(absolute);
      let projectRoot;
      while (true) {
        const assets = pathApi.join(current, "Assets");
        const version = pathApi.join(current, "ProjectSettings", "ProjectVersion.txt");
        if (fsApi.existsSync(assets) && fsApi.existsSync(version)) {
          projectRoot = current;
          break;
        }
        const parent = pathApi.dirname(current);
        if (parent === current) break;
        current = parent;
      }
      if (!projectRoot) {
        return { ok: false, handled: false, code: "notUnityProject" };
      }

      const assetsRoot = pathApi.join(projectRoot, "Assets");
      const relative = pathApi.relative(assetsRoot, absolute);
      if (relative === "" || relative.startsWith("..") || pathApi.isAbsolute(relative)) {
        return { ok: false, handled: false, code: "notAssetFile" };
      }
      return {
        ok: true,
        absolutePath: absolute,
        projectRoot,
        assetPath: "Assets/" + relative.split(pathApi.sep).join("/"),
      };
    }

- [ ] **Step 4: Implement bounded one-request Pipe transport**

Add:

    function sendPipeRequest(pipePath, payload, deps) {
      const netApi = deps.net;
      const connectTimeoutMs = deps.connectTimeoutMs || 300;
      const responseTimeoutMs = deps.responseTimeoutMs || 2500;
      return new Promise((resolve, reject) => {
        const socket = netApi.createConnection(pipePath);
        let settled = false;
        let buffer = "";
        let responseTimer;
        const connectTimer = setTimeout(() => finish(new Error("unityUnavailable")), connectTimeoutMs);

        function finish(error, value) {
          if (settled) return;
          settled = true;
          clearTimeout(connectTimer);
          clearTimeout(responseTimer);
          socket.destroy();
          if (error) reject(error);
          else resolve(value);
        }

        socket.setEncoding("utf8");
        socket.once("connect", () => {
          clearTimeout(connectTimer);
          responseTimer = setTimeout(() => finish(new Error("unityUnavailable")), responseTimeoutMs);
          socket.write(JSON.stringify(payload) + "\n");
        });
        socket.on("data", (chunk) => {
          buffer += chunk;
          if (buffer.length > 65536) {
            finish(new Error("responseTooLarge"));
            return;
          }
          const newline = buffer.indexOf("\n");
          if (newline < 0) return;
          try {
            finish(undefined, JSON.parse(buffer.slice(0, newline)));
          } catch {
            finish(new Error("invalidResponse"));
          }
        });
        socket.once("error", (error) => finish(error));
        socket.once("end", () => {
          if (!settled) finish(new Error("unityUnavailable"));
        });
      });
    }

- [ ] **Step 5: Implement routing, fallback, and reload-safe IPC registration**

Add:

    async function handleOpenAsset(candidate, deps) {
      const target = findUnityTarget(candidate.path, deps.fs, deps.path);
      if (!target.ok) {
        if (target.code === "fileMissing") {
          const parent = deps.path.dirname(candidate.path);
          if (deps.fs.existsSync(parent)) void deps.shell.openPath(parent);
          deps.log.warn("file link rejected", target.code, candidate.path);
        }
        return target;
      }

      const requestId = deps.crypto.randomUUID();
      const pipeName = pipeNameForProjectRoot(target.projectRoot, deps.crypto, deps.path);
      const pipePath = "\\\\.\\pipe\\" + pipeName;
      const payload = {
        version: 1,
        requestId,
        action: "openAsset",
        projectRoot: target.projectRoot,
        assetPath: target.assetPath,
        line: candidate.line || 0,
        column: candidate.column || 0,
      };

      try {
        const transport = deps.sendPipeRequest || sendPipeRequest;
        const response = await transport(pipePath, payload, {
          net: deps.net,
          connectTimeoutMs: 300,
          responseTimeoutMs: 2500,
        });
        if (response.requestId !== requestId) throw new Error("responseMismatch");
        if (response.ok) return { ok: true, handled: true, code: response.code };
        deps.log.warn("Unity rejected asset link", response.code, target.assetPath);
        deps.shell.showItemInFolder(target.absolutePath);
        return {
          ok: false,
          handled: true,
          code: response.code || "openFailed",
          message: response.message || "Unity could not open this asset.",
        };
      } catch (error) {
        deps.log.warn("Unity asset link unavailable", String(error));
        deps.shell.showItemInFolder(target.absolutePath);
        return {
          ok: false,
          handled: true,
          code: "unityUnavailable",
          message: "The matching Unity project is not open. The file was revealed in Explorer.",
        };
      }
    }

    function defaultMainDeps(api) {
      return {
        crypto: require("node:crypto"),
        fs: require("node:fs"),
        net: require("node:net"),
        path: require("node:path"),
        shell: require("electron").shell,
        log: api.log,
      };
    }

    function startMain(api, injectedDeps) {
      const key = Symbol.for("com.kpk.unity-asset-links.main-runtime");
      const runtime = globalThis[key] || {
        registered: false,
        implementation: undefined,
      };
      globalThis[key] = runtime;
      runtime.implementation = (candidate) =>
        handleOpenAsset(candidate, Object.keys(injectedDeps || {}).length > 0
          ? injectedDeps
          : defaultMainDeps(api));

      if (!runtime.registered) {
        api.ipc.handle("open-asset", (candidate) => runtime.implementation(candidate));
        runtime.registered = true;
      }
    }

Change start(api) to:

    function start(api) {
      if (api.process === "main") {
        startMain(api, {});
      }
    }

Export findUnityTarget, sendPipeRequest, handleOpenAsset, and startMain through __test.

- [ ] **Step 6: Create the direct smoke client**

Create codex-tweak/scripts/send-open.js:

    const crypto = require("node:crypto");
    const fs = require("node:fs");
    const net = require("node:net");
    const path = require("node:path");
    const { __test } = require("../index.js");

    async function main() {
      const parsed = __test.parseDestination(process.argv[2]);
      if (!parsed) throw new Error("Pass an absolute Windows asset path.");
      const target = __test.findUnityTarget(parsed.path, fs, path);
      if (!target.ok) throw new Error(target.code);
      const requestId = crypto.randomUUID();
      const pipeName = __test.pipeNameForProjectRoot(target.projectRoot, crypto, path);
      const response = await __test.sendPipeRequest(
        "\\\\.\\pipe\\" + pipeName,
        {
          version: 1,
          requestId,
          action: "openAsset",
          projectRoot: target.projectRoot,
          assetPath: target.assetPath,
          line: parsed.line,
          column: parsed.column,
        },
        { net, connectTimeoutMs: 300, responseTimeoutMs: 2500 },
      );
      process.stdout.write(JSON.stringify(response) + "\n");
      if (!response.ok) process.exitCode = 1;
    }

    main().catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });

- [ ] **Step 7: Run tests and commit Task 2**

Run:

    npm test
    git -C D:\workspace\codex-tweaks\unity-links add codex-tweak
    git -C D:\workspace\codex-tweaks\unity-links commit -m "feat: route assets over named pipes"

Expected: all tests PASS; commit contains main routing, transport, tests, and smoke client.

---

### Task 3: Renderer Click Lifecycle and User Feedback

**Files:**
- Modify: codex-tweak/index.js
- Modify: codex-tweak/test/index.test.js

**Interfaces:**
- Consumes: parseDestination, hasAssetsSegment, and main IPC channel open-asset.
- Produces: startRenderer(api, documentApi) and stopRenderer().
- Produces: replayOriginalClick(anchor) for main results with handled=false.
- Produces: showNotice(message, documentApi) for handled failures.

- [ ] **Step 1: Add failing renderer lifecycle tests with a tiny fake DOM**

Append:

    test("renderer captures one eligible Assets link and cleans up", async () => {
      const listeners = new Map();
      const anchor = {
        clicks: 0,
        getAttribute() {
          return "D:/workspace/sgproj/Assets/Light.prefab";
        },
        click() {
          this.clicks += 1;
        },
      };
      const documentApi = {
        body: { append() {} },
        addEventListener(name, handler) {
          listeners.set(name, handler);
        },
        removeEventListener(name) {
          listeners.delete(name);
        },
        createElement() {
          return {
            dataset: {},
            style: {},
            remove() {},
          };
        },
      };
      const api = {
        ipc: {
          invoke: async () => ({ ok: true, handled: true, code: "opened" }),
        },
      };
      __test.startRenderer(api, documentApi);
      const event = {
        button: 0,
        defaultPrevented: false,
        altKey: false,
        ctrlKey: false,
        metaKey: false,
        shiftKey: false,
        target: { closest: () => anchor },
        preventDefault() {
          this.defaultPrevented = true;
        },
        stopImmediatePropagation() {},
      };
      listeners.get("click")(event);
      await new Promise((resolve) => setImmediate(resolve));
      assert.equal(event.defaultPrevented, true);
      __test.stopRenderer();
      assert.equal(listeners.has("click"), false);
    });

    test("renderer replays Codex behavior when main declines the path", async () => {
      const listeners = new Map();
      const anchor = {
        clicks: 0,
        getAttribute() {
          return "D:/workspace/sgproj/Assets/Folder";
        },
        click() {
          this.clicks += 1;
        },
      };
      const documentApi = {
        body: { append() {} },
        addEventListener(name, handler) {
          listeners.set(name, handler);
        },
        removeEventListener() {},
        createElement() {
          return { dataset: {}, style: {}, remove() {} };
        },
      };
      __test.startRenderer(
        { ipc: { invoke: async () => ({ ok: false, handled: false }) } },
        documentApi,
      );
      const event = {
        button: 0,
        defaultPrevented: false,
        altKey: false,
        ctrlKey: false,
        metaKey: false,
        shiftKey: false,
        target: { closest: () => anchor },
        preventDefault() {
          this.defaultPrevented = true;
        },
        stopImmediatePropagation() {},
      };
      listeners.get("click")(event);
      await new Promise((resolve) => setImmediate(resolve));
      assert.equal(event.defaultPrevented, true);
      assert.equal(anchor.clicks, 1);
      __test.stopRenderer();
    });

- [ ] **Step 2: Run tests and verify startRenderer is missing**

Run:

    npm test

Expected: prior tests PASS; renderer lifecycle test FAILS because startRenderer is undefined.

- [ ] **Step 3: Implement renderer capture, replay, notice, and cleanup**

Add these module-level fields:

    const replayBypass = new WeakSet();
    const notices = new Set();

Add:

    function showNotice(message, documentApi) {
      const notice = documentApi.createElement("div");
      notice.dataset.codexUnityAssetLinkNotice = "true";
      notice.textContent = message;
      notice.style.position = "fixed";
      notice.style.right = "16px";
      notice.style.bottom = "16px";
      notice.style.zIndex = "2147483647";
      notice.style.maxWidth = "420px";
      notice.style.padding = "10px 12px";
      notice.style.borderRadius = "8px";
      notice.style.background = "var(--color-background-panel, #222)";
      notice.style.color = "var(--color-token-text-primary, #fff)";
      notice.style.boxShadow = "0 8px 28px rgba(0, 0, 0, 0.28)";
      documentApi.body.append(notice);
      notices.add(notice);
      const timer = setTimeout(() => {
        notices.delete(notice);
        notice.remove();
      }, 3500);
      return () => {
        clearTimeout(timer);
        notices.delete(notice);
        notice.remove();
      };
    }

    function replayOriginalClick(anchor) {
      replayBypass.add(anchor);
      try {
        anchor.click();
      } finally {
        replayBypass.delete(anchor);
      }
    }

    function startRenderer(api, documentApi) {
      stopRenderer();
      const onClick = (event) => {
        if (!isEligibleClick(event)) return;
        const anchor = event.target && event.target.closest
          ? event.target.closest("a[href]")
          : null;
        if (!anchor || replayBypass.has(anchor)) return;
        const parsed = parseDestination(anchor.getAttribute("href") || anchor.href);
        if (!parsed || !hasAssetsSegment(parsed.path)) return;

        event.preventDefault();
        event.stopImmediatePropagation();
        void api.ipc.invoke("open-asset", parsed)
          .then((result) => {
            if (!result || result.handled === false) {
              replayOriginalClick(anchor);
              return;
            }
            if (!result.ok) {
              showNotice(
                result.message || "Unity could not open this asset.",
                documentApi,
              );
            }
          })
          .catch(() => {
            showNotice("Unity link handling failed.", documentApi);
          });
      };
      documentApi.addEventListener("click", onClick, true);
      rendererCleanup = () => documentApi.removeEventListener("click", onClick, true);
    }

    function stopRenderer() {
      if (rendererCleanup) {
        rendererCleanup();
        rendererCleanup = undefined;
      }
      for (const notice of notices) notice.remove();
      notices.clear();
    }

Change start(api) and stop():

    function start(api) {
      if (api.process === "main") {
        startMain(api, {});
        return;
      }
      startRenderer(api, document);
    }

    function stop() {
      stopRenderer();
    }

Export startRenderer, stopRenderer, replayOriginalClick, and showNotice through __test.

- [ ] **Step 4: Run tests, validate, and commit Task 3**

Run:

    npm test
    codexplusplus validate-tweak D:\workspace\codex-tweaks\unity-links\codex-tweak
    git -C D:\workspace\codex-tweaks\unity-links add codex-tweak
    git -C D:\workspace\codex-tweaks\unity-links commit -m "feat: intercept Unity asset clicks"

Expected: all tests PASS and Codex++ validation succeeds.

---

### Task 4: Editor-Only Unity Named Pipe Receiver

**Files:**
- Create: unity-package/package.json
- Create: unity-package/Editor/KPK.CodexUnityLink.Editor.asmdef
- Create: unity-package/Editor/UnityAssetLinkProtocol.cs
- Create: unity-package/Editor/UnityAssetLinkPath.cs
- Create: unity-package/Editor/UnityAssetLinkReceiver.cs

**Interfaces:**
- Consumes: protocol version 1 and Pipe identity algorithm from the JavaScript tweak.
- Produces: Pipe kpk-codex-unity-link-v1-<sha256(normalized-project-root)>.
- Produces: one-request/one-response UTF-8 newline-delimited JSON protocol.
- Produces: AssetDatabase.OpenAsset execution on Unity's main thread.

- [ ] **Step 1: Create package metadata and Editor-only assembly**

Create unity-package/package.json:

    {
      "name": "com.kpk.codex-unity-link",
      "version": "0.1.0",
      "displayName": "KPK Codex Unity Link",
      "description": "Opens Codex Desktop asset links in the matching Unity Editor.",
      "unity": "2022.3",
      "author": {
        "name": "KPK"
      }
    }

Create unity-package/Editor/KPK.CodexUnityLink.Editor.asmdef:

    {
      "name": "KPK.CodexUnityLink.Editor",
      "rootNamespace": "KPK.CodexUnityLink.Editor",
      "references": [],
      "includePlatforms": [
        "Editor"
      ],
      "excludePlatforms": [],
      "allowUnsafeCode": false,
      "overrideReferences": false,
      "precompiledReferences": [],
      "autoReferenced": true,
      "defineConstraints": [],
      "versionDefines": [],
      "noEngineReferences": false
    }

- [ ] **Step 2: Implement bounded protocol DTOs**

Create unity-package/Editor/UnityAssetLinkProtocol.cs:

    using System;
    using UnityEngine;

    namespace KPK.CodexUnityLink.Editor
    {
        [Serializable]
        internal sealed class UnityAssetLinkRequest
        {
            public int version;
            public string requestId;
            public string action;
            public string projectRoot;
            public string assetPath;
            public int line;
            public int column;
        }

        [Serializable]
        internal sealed class UnityAssetLinkResponse
        {
            public int version;
            public string requestId;
            public bool ok;
            public string code;
            public string message;
        }

        internal static class UnityAssetLinkProtocol
        {
            internal const int Version = 1;
            internal const int MaxMessageChars = 65536;

            internal static bool TryParse(
                string json,
                out UnityAssetLinkRequest request,
                out UnityAssetLinkResponse error)
            {
                request = null;
                error = null;
                if (string.IsNullOrEmpty(json) || json.Length > MaxMessageChars)
                {
                    error = Failure(null, "invalidRequest", "Request is empty or too large.");
                    return false;
                }

                try
                {
                    request = JsonUtility.FromJson<UnityAssetLinkRequest>(json);
                }
                catch (Exception)
                {
                    error = Failure(null, "invalidRequest", "Request JSON is invalid.");
                    return false;
                }

                if (request == null
                    || request.version != Version
                    || request.action != "openAsset"
                    || string.IsNullOrEmpty(request.requestId)
                    || string.IsNullOrEmpty(request.projectRoot)
                    || string.IsNullOrEmpty(request.assetPath))
                {
                    error = Failure(
                        request != null ? request.requestId : null,
                        "invalidRequest",
                        "Request version, id, or action is invalid.");
                    return false;
                }
                return true;
            }

            internal static UnityAssetLinkResponse Success(string requestId)
            {
                return new UnityAssetLinkResponse
                {
                    version = Version,
                    requestId = requestId,
                    ok = true,
                    code = "opened",
                    message = string.Empty
                };
            }

            internal static UnityAssetLinkResponse Failure(string requestId, string code, string message)
            {
                return new UnityAssetLinkResponse
                {
                    version = Version,
                    requestId = requestId ?? string.Empty,
                    ok = false,
                    code = code,
                    message = message
                };
            }

            internal static string Serialize(UnityAssetLinkResponse response)
            {
                return JsonUtility.ToJson(response);
            }
        }
    }

- [ ] **Step 3: Implement matching Pipe identity and safe asset resolution**

Create unity-package/Editor/UnityAssetLinkPath.cs:

    using System;
    using System.IO;
    using System.Security.Cryptography;
    using System.Text;

    namespace KPK.CodexUnityLink.Editor
    {
        internal static class UnityAssetLinkPath
        {
            private const string PipePrefix = "kpk-codex-unity-link-v1-";

            internal static string NormalizeProjectRoot(string projectRoot)
            {
                return Path.GetFullPath(projectRoot)
                    .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                    .Replace('/', '\\')
                    .ToLowerInvariant();
            }

            internal static string GetPipeName(string projectRoot)
            {
                var normalized = NormalizeProjectRoot(projectRoot);
                using (var sha = SHA256.Create())
                {
                    var bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(normalized));
                    var digest = BitConverter.ToString(bytes).Replace("-", string.Empty).ToLowerInvariant();
                    return PipePrefix + digest;
                }
            }

            internal static bool TryResolveAsset(
                string currentProjectRoot,
                UnityAssetLinkRequest request,
                out string assetPath,
                out UnityAssetLinkResponse error)
            {
                assetPath = null;
                error = null;
                if (!string.Equals(
                        NormalizeProjectRoot(currentProjectRoot),
                        NormalizeProjectRoot(request.projectRoot),
                        StringComparison.OrdinalIgnoreCase))
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "wrongProject",
                        "The request belongs to another Unity project.");
                    return false;
                }

                var normalizedAssetPath = (request.assetPath ?? string.Empty).Replace('\\', '/');
                var segments = normalizedAssetPath.Split('/');
                if (segments.Length < 2
                    || segments[0] != "Assets"
                    || Array.Exists(segments, segment => segment == ".." || segment == "."))
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "assetOutsideProject",
                        "The requested path is outside this project's Assets directory.");
                    return false;
                }

                var assetsRoot = Path.Combine(currentProjectRoot, "Assets");
                if ((File.GetAttributes(assetsRoot) & FileAttributes.ReparsePoint) != 0)
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "assetOutsideProject",
                        "A reparse-point Assets directory is not accepted.");
                    return false;
                }
                var absolute = Path.GetFullPath(
                    Path.Combine(currentProjectRoot, normalizedAssetPath.Replace('/', Path.DirectorySeparatorChar)));
                var assetsPrefix = assetsRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                if (!absolute.StartsWith(assetsPrefix, StringComparison.OrdinalIgnoreCase))
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "assetOutsideProject",
                        "The requested path escapes this project's Assets directory.");
                    return false;
                }

                var current = assetsRoot;
                for (var i = 1; i < segments.Length; i++)
                {
                    current = Path.Combine(current, segments[i]);
                    if (!File.Exists(current) && !Directory.Exists(current))
                    {
                        error = UnityAssetLinkProtocol.Failure(
                            request.requestId,
                            "assetMissing",
                            "The requested Unity asset does not exist.");
                        return false;
                    }
                    if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    {
                        error = UnityAssetLinkProtocol.Failure(
                            request.requestId,
                            "assetOutsideProject",
                            "Reparse-point asset paths are not accepted.");
                        return false;
                    }
                }

                if (!File.Exists(absolute))
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "assetMissing",
                        "The requested Unity asset is not a file.");
                    return false;
                }
                assetPath = normalizedAssetPath;
                return true;
            }
        }
    }

- [ ] **Step 4: Implement the receiver lifecycle and main-thread open**

Create unity-package/Editor/UnityAssetLinkReceiver.cs:

    using System;
    using System.Collections.Concurrent;
    using System.IO;
    using System.IO.Pipes;
    using System.Text;
    using System.Threading;
    using System.Threading.Tasks;
    using UnityEditor;
    using UnityEngine;

    namespace KPK.CodexUnityLink.Editor
    {
        [InitializeOnLoad]
        internal static class UnityAssetLinkReceiver
        {
            private sealed class PendingRequest
            {
                internal string json;
                internal TaskCompletionSource<string> completion;
            }

            private static readonly ConcurrentQueue<PendingRequest> PendingRequests = new();
            private static readonly ConcurrentQueue<string> PendingErrors = new();
            private static readonly object PipeGate = new();
            private static CancellationTokenSource cancellation;
            private static NamedPipeServerStream activePipe;
            private static string projectRoot;

            static UnityAssetLinkReceiver()
            {
                projectRoot = Directory.GetParent(Application.dataPath).FullName;
                EditorApplication.update += ProcessPendingRequests;
                AssemblyReloadEvents.beforeAssemblyReload += Stop;
                EditorApplication.quitting += Stop;
                Start();
                Debug.Log($"[CodexUnityLink] Listening for project: {projectRoot}");
            }

            private static void Start()
            {
                cancellation = new CancellationTokenSource();
                var pipeName = UnityAssetLinkPath.GetPipeName(projectRoot);
                _ = Task.Run(() => ListenAsync(pipeName, cancellation.Token));
            }

            private static void Stop()
            {
                if (cancellation == null) return;
                cancellation.Cancel();
                lock (PipeGate)
                {
                    if (activePipe != null)
                    {
                        activePipe.Dispose();
                        activePipe = null;
                    }
                }
                cancellation.Dispose();
                cancellation = null;
                while (PendingRequests.TryDequeue(out var pending))
                {
                    pending.completion.TrySetCanceled();
                }
                while (PendingErrors.TryDequeue(out _))
                {
                }
            }

            private static async Task ListenAsync(string pipeName, CancellationToken token)
            {
                while (!token.IsCancellationRequested)
                {
                    try
                    {
                        using (var pipe = new NamedPipeServerStream(
                                   pipeName,
                                   PipeDirection.InOut,
                                   1,
                                   PipeTransmissionMode.Byte,
                                   PipeOptions.Asynchronous))
                        {
                            lock (PipeGate)
                            {
                                activePipe = pipe;
                            }
                            await pipe.WaitForConnectionAsync(token);
                            await ServeAsync(pipe, token);
                        }
                    }
                    catch (OperationCanceledException)
                    {
                        return;
                    }
                    catch (ObjectDisposedException)
                    {
                        if (token.IsCancellationRequested) return;
                    }
                    catch (IOException)
                    {
                        if (token.IsCancellationRequested) return;
                    }
                    catch (Exception exception)
                    {
                        PendingErrors.Enqueue(exception.Message);
                        try
                        {
                            await Task.Delay(1000, token);
                        }
                        catch (OperationCanceledException)
                        {
                            return;
                        }
                    }
                    finally
                    {
                        lock (PipeGate)
                        {
                            activePipe = null;
                        }
                    }
                }
            }

            private static async Task ServeAsync(Stream stream, CancellationToken token)
            {
                using (var reader = new StreamReader(stream, Encoding.UTF8, false, 4096, true))
                using (var writer = new StreamWriter(
                           stream,
                           new UTF8Encoding(false),
                           4096,
                           true) { AutoFlush = true })
                {
                    var json = await reader.ReadLineAsync();
                    if (json == null) return;
                    var completion = new TaskCompletionSource<string>(
                        TaskCreationOptions.RunContinuationsAsynchronously);
                    PendingRequests.Enqueue(new PendingRequest
                    {
                        json = json,
                        completion = completion
                    });
                    using (token.Register(() => completion.TrySetCanceled()))
                    {
                        var response = await completion.Task;
                        await writer.WriteLineAsync(response);
                    }
                }
            }

            private static void ProcessPendingRequests()
            {
                while (PendingErrors.TryDequeue(out var message))
                {
                    Debug.LogError($"[CodexUnityLink] Pipe listener failed: {message}");
                }
                while (PendingRequests.TryDequeue(out var pending))
                {
                    try
                    {
                        pending.completion.TrySetResult(ProcessRequest(pending.json));
                    }
                    catch (Exception exception)
                    {
                        var response = UnityAssetLinkProtocol.Failure(
                            null,
                            "openFailed",
                            exception.Message);
                        pending.completion.TrySetResult(SerializeFailure(response));
                    }
                }
            }

            private static string ProcessRequest(string json)
            {
                if (!UnityAssetLinkProtocol.TryParse(json, out var request, out var error))
                    return SerializeFailure(error);
                if (!UnityAssetLinkPath.TryResolveAsset(projectRoot, request, out var assetPath, out error))
                    return SerializeFailure(error);

                var asset = AssetDatabase.LoadAssetAtPath<UnityEngine.Object>(assetPath);
                if (asset == null)
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "assetMissing",
                        "Unity could not load the requested asset.");
                    return SerializeFailure(error);
                }

                bool opened;
                if (request.line <= 0)
                    opened = AssetDatabase.OpenAsset(asset);
                else if (request.column <= 0)
                    opened = AssetDatabase.OpenAsset(asset, request.line);
                else
                    opened = AssetDatabase.OpenAsset(asset, request.line, request.column);

                if (!opened)
                {
                    error = UnityAssetLinkProtocol.Failure(
                        request.requestId,
                        "openFailed",
                        "Unity did not accept the asset open request.");
                    return SerializeFailure(error);
                }
                return UnityAssetLinkProtocol.Serialize(
                    UnityAssetLinkProtocol.Success(request.requestId));
            }

            private static string SerializeFailure(UnityAssetLinkResponse response)
            {
                Debug.LogWarning($"[CodexUnityLink] {response.code}: {response.message}");
                return UnityAssetLinkProtocol.Serialize(response);
            }
        }
    }

- [ ] **Step 5: Review C# against repository style before importing**

Check:

    rg -n ".{121}" D:\workspace\codex-tweaks\unity-links\unity-package\Editor
    rg -n "TODO|FIXME|condition == false|\?\." D:\workspace\codex-tweaks\unity-links\unity-package\Editor

Expected: no lines above 120 characters, no placeholders, no UnityEngine.Object null propagation, and no style violations. Correct any reported line by an exact formatting-only edit.

- [ ] **Step 6: Commit Task 4**

Run:

    git -C D:\workspace\codex-tweaks\unity-links add unity-package
    git -C D:\workspace\codex-tweaks\unity-links commit -m "feat: add Unity asset link receiver"

Expected: one commit containing only the local UPM package.

---

### Task 5: Install the Tweak and Local UPM Package

**Files:**
- Modify: D:\workspace\sgproj\Packages\manifest.json
- Review generated modification: D:\workspace\sgproj\Packages\packages-lock.json
- Create symlink through Codex++: %APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links

**Interfaces:**
- Consumes: completed Codex tweak and Unity package.
- Produces: live Codex++ tweak and a compiled receiver in sgproj.

- [ ] **Step 1: Re-read Unity verification rules and confirm the target instance**

Read D:\workspace\sgproj\docs\agent-rules\verification.md completely.

List MCP resources and read the exact instances resource URI returned by the server. Confirm an instance whose Assets path is D:/workspace/sgproj/Assets and whose Unity version is 2022.3.23f1. If multiple instances exist, call mcp__unityMCP__set_active_instance with the exact sgproj@hash. Stop rather than target another project if sgproj is absent.

- [ ] **Step 2: Validate and link the Codex++ tweak**

Run:

    cd D:\workspace\codex-tweaks\unity-links\codex-tweak
    npm test
    codexplusplus validate-tweak D:\workspace\codex-tweaks\unity-links\codex-tweak
    codexplusplus dev D:\workspace\codex-tweaks\unity-links\codex-tweak --replace --no-watch

Expected: tests PASS, validation succeeds, and the live tweak path is a link to the standalone source directory.

- [ ] **Step 3: Open the two Unity package files for edit in Perforce**

Use mcp__perforce_p4_mcp__modify_files with:

    action: edit
    changelist: default
    file_paths:
      - D:\workspace\sgproj\Packages\manifest.json
      - D:\workspace\sgproj\Packages\packages-lock.json

Then use mcp__perforce_p4_mcp__query_changelists with action=get and changelist_id=default. Confirm both exact files are opened and do not submit.

- [ ] **Step 4: Add the local package dependency**

Insert this property immediately after com.kpk.aiagent in Packages/manifest.json:

    "com.kpk.codex-unity-link": "file:D:/workspace/codex-tweaks/unity-links/unity-package",

Do not hand-edit Packages/packages-lock.json. Unity Package Manager owns the lock entry.

- [ ] **Step 5: Refresh Unity and inspect compile output**

Call:

    mcp__unityMCP__refresh_unity({
      scope: "all",
      mode: "if_dirty",
      compile: "request",
      wait_for_ready: true
    })

Then call:

    mcp__unityMCP__read_console({
      action: "get",
      types: ["error", "warning"],
      format: "detailed",
      include_stacktrace: true,
      page_size: 200
    })

Expected: the package resolves, KPK.CodexUnityLink.Editor compiles, and there are no real project errors. Ignore only the documented McpLog.cs disposed-object domain-reload noise.

- [ ] **Step 6: Review Unity-generated lock and Perforce scope**

Use mcp__perforce_p4_mcp__query_files action=diff separately for:

    //sgproj/trunk/Packages/manifest.json
    //sgproj/trunk/Packages/packages-lock.json

Expected: manifest has one dependency; lock has only the corresponding local package entry and dependency metadata. Use query_changelists get default again to ensure no unrelated file was opened. Do not submit.

- [ ] **Step 7: Directly verify Prefab, custom skill Asset, and C# routing**

Run these one at a time while sgproj Unity is open:

    node D:\workspace\codex-tweaks\unity-links\codex-tweak\scripts\send-open.js D:\workspace\sgproj\Assets\Light.prefab

    node D:\workspace\codex-tweaks\unity-links\codex-tweak\scripts\send-open.js D:\workspace\sgproj\Assets\Plugins\SkillTimeline\Editor\Data\SkillGraphData\1.asset

    node D:\workspace\codex-tweaks\unity-links\codex-tweak\scripts\send-open.js D:\workspace\sgproj\Assets\GameEntry.cs:1:1

Expected for each command: one JSON response with ok=true and code=opened. The Prefab enters normal Prefab handling, the skill asset reaches SkillGraphDataOpener, and the C# file reaches Unity's configured code editor.

- [ ] **Step 8: Re-read the Unity Console after direct opens**

Call read_console again with error and warning types.

Expected: no real errors were introduced by receiver startup or asset opens.

---

### Task 6: Documentation, Final Validation, and Handoff

**Files:**
- Create: README.md
- Modify if verification found a defect: only the smallest directly responsible source/test file.

**Interfaces:**
- Consumes: installed and verified end-to-end feature.
- Produces: repeatable local installation, recovery, and uninstall instructions.

- [ ] **Step 1: Write the README**

Create README.md with these sections and exact operational facts:

    # Unity Asset Links

    Opens ordinary Codex Desktop file links below a Unity project's Assets directory
    through AssetDatabase.OpenAsset in the matching running Unity Editor.

    ## Requirements

    - Windows
    - Codex++ 1.0.0 or newer compatible runtime
    - Unity 2022.3
    - The local Unity package installed in the target project

    ## Source and Live Locations

    Source:
    D:\workspace\codex-tweaks\unity-links

    Live Codex++ link:
    %APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links

    Unity package:
    D:\workspace\codex-tweaks\unity-links\unity-package

    ## Install

    1. Run:
       codexplusplus dev D:\workspace\codex-tweaks\unity-links\codex-tweak --replace --no-watch
    2. Add this dependency to the Unity project's Packages/manifest.json:
       "com.kpk.codex-unity-link": "file:D:/workspace/codex-tweaks/unity-links/unity-package"
    3. Let Unity compile, then reload Codex++ tweaks or restart Codex++.

    ## Behavior

    - Normal clicks on existing Assets files open through Unity.
    - Ctrl, Shift, Alt, Meta, and middle clicks keep Codex behavior.
    - Directories and files outside Assets keep Codex behavior.
    - If the matching Unity project is closed, Explorer reveals the file and Codex shows a notice.
    - Unity is never started automatically.

    ## Verify

    Run npm test inside codex-tweak, validate with codexplusplus validate-tweak,
    and use codex-tweak/scripts/send-open.js for a direct Pipe smoke check.

    ## Recovery

    On Codex++ 1.0.0, do not run codexplusplus debug without --app.
    If the Codex++ patch is overwritten, run:
    codexplusplus repair --force

    ## Remove

    Remove the com.kpk.codex-unity-link dependency from the Unity project and
    remove the live tweak link from %APPDATA%\codex-plusplus\tweaks. Keep or
    delete the standalone Git repository separately.

- [ ] **Step 2: Run fresh final checks**

Run:

    cd D:\workspace\codex-tweaks\unity-links\codex-tweak
    npm test
    codexplusplus validate-tweak D:\workspace\codex-tweaks\unity-links\codex-tweak
    codexplusplus status
    git -C D:\workspace\codex-tweaks\unity-links status --short

Expected:

- All Node tests PASS.
- Tweak validation succeeds.
- Codex++ status reports version 1.0.0 and current ASAR matches patched.
- Git shows only README.md before the documentation commit.

- [ ] **Step 3: Commit documentation**

Run:

    git -C D:\workspace\codex-tweaks\unity-links add README.md
    git -C D:\workspace\codex-tweaks\unity-links commit -m "docs: document Unity asset links"

Expected: standalone Git working tree is clean.

- [ ] **Step 4: Final state audit**

Verify:

    git -C D:\workspace\codex-tweaks\unity-links log --oneline -6
    git -C D:\workspace\codex-tweaks\unity-links status --short

Use Perforce MCP query_changelists get default and report the exact local project files still opened. Do not submit them. Report the Codex++ live link, the UPM source path, Node test count, Unity compile/Console result, the three direct-open results, and the v1.0.0 debug caveat.

If interactive click acceptance is still needed, ask the user to launch the Codex++ shortcut and click three links pointing to:

    D:\workspace\sgproj\Assets\Light.prefab
    D:\workspace\sgproj\Assets\Plugins\SkillTimeline\Editor\Data\SkillGraphData\1.asset
    D:\workspace\sgproj\Assets\GameEntry.cs:1

The implementation is complete only after all non-interactive checks pass; interactive visual confirmation is an acceptance check and must be reported separately if the user has not performed it.
