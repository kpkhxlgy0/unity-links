const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { EventEmitter } = require("node:events");
const net = require("node:net");
const path = require("node:path");
const { __test } = require("../index.js");

const windowsPath = path.win32;

function createVirtualFs({ files = [], directories = [] }) {
  const normalize = (value) => windowsPath.normalize(value).toLowerCase();
  const fileKeys = new Set(files.map(normalize));
  const directoryKeys = new Set(directories.map(normalize));

  return {
    existsSync(value) {
      const key = normalize(value);
      return fileKeys.has(key) || directoryKeys.has(key);
    },
    realpathSync(value) {
      const normalized = windowsPath.normalize(value);
      const key = normalize(normalized);
      if (!fileKeys.has(key) && !directoryKeys.has(key)) throw new Error("Path not found");
      return normalized;
    },
    statSync(value) {
      const key = normalize(value);
      if (!fileKeys.has(key) && !directoryKeys.has(key)) throw new Error("Path not found");
      return { isFile: () => fileKeys.has(key) };
    },
  };
}

test("parses Windows paths with line and column", () => {
  assert.deepEqual(
    __test.parseDestination("D:/Projects/ExampleUnityProject/Assets/GameEntry.cs:12:4"),
    {
      path: "D:\\Projects\\ExampleUnityProject\\Assets\\GameEntry.cs",
      line: 12,
      column: 4,
    },
  );
});

test("parses file URLs emitted by Markdown renderers", () => {
  assert.deepEqual(
    __test.parseDestination("file:///D:/Projects/ExampleUnityProject/Assets/Light.prefab"),
    {
      path: "D:\\Projects\\ExampleUnityProject\\Assets\\Light.prefab",
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
    "D:\\Projects\\ExampleUnityProject\\",
    crypto,
    path.win32,
  );
  assert.equal(
    actual,
    "kpk-codex-unity-link-v1-562b1e523731c184d83aaafbb3ca32da391c438f759d8aacfbb2200d470b9bda",
  );
});

test("finds the nearest Unity root and produces an Assets path", () => {
  const root = "D:\\Projects\\ExampleUnityProject";
  const assets = windowsPath.join(root, "Assets");
  const file = windowsPath.join(assets, "Data", "A.asset");
  const version = windowsPath.join(root, "ProjectSettings", "ProjectVersion.txt");
  const fsApi = createVirtualFs({ files: [file, version], directories: [assets] });

  const result = __test.findUnityTarget(file, fsApi, windowsPath);

  assert.equal(result.ok, true);
  assert.equal(result.assetPath, "Assets/Data/A.asset");
});

test("does not route a directory or a file outside Assets", () => {
  const root = "D:\\Projects\\ExampleUnityProject";
  const assets = windowsPath.join(root, "Assets");
  const outside = windowsPath.join(root, "outside.txt");
  const version = windowsPath.join(root, "ProjectSettings", "ProjectVersion.txt");
  const fsApi = createVirtualFs({ files: [outside, version], directories: [assets] });

  assert.equal(__test.findUnityTarget(assets, fsApi, windowsPath).code, "notAssetFile");
  assert.equal(__test.findUnityTarget(outside, fsApi, windowsPath).code, "notAssetFile");
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

test("gracefully closes the Pipe after a successful response", async () => {
  const socket = new EventEmitter();
  let ended = false;
  let destroyed = false;
  socket.setEncoding = () => {};
  socket.write = () => {
    queueMicrotask(() => socket.emit("data", '{"ok":true,"code":"opened"}\n'));
  };
  socket.end = () => {
    ended = true;
  };
  socket.destroy = () => {
    destroyed = true;
  };
  const request = __test.sendPipeRequest(
    "fake-pipe",
    { version: 1, requestId: "r1", action: "openAsset" },
    {
      net: {
        createConnection() {
          queueMicrotask(() => socket.emit("connect"));
          return socket;
        },
      },
      connectTimeoutMs: 300,
      responseTimeoutMs: 1000,
    },
  );

  assert.equal((await request).code, "opened");
  assert.equal(ended, true);
  assert.equal(destroyed, false);
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
  const root = "D:\\Projects\\ExampleUnityProject";
  const assets = windowsPath.join(root, "Assets");
  const file = windowsPath.join(assets, "A.asset");
  const version = windowsPath.join(root, "ProjectSettings", "ProjectVersion.txt");
  const fsApi = createVirtualFs({ files: [file, version], directories: [assets] });
  const revealed = [];
  const result = await __test.handleOpenAsset(
    { path: file, line: 0, column: 0 },
    {
      crypto,
      fs: fsApi,
      net,
      path: windowsPath,
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
  assert.deepEqual(revealed, [file]);
});

test("renderer captures one eligible Assets link and cleans up", async () => {
  const listeners = new Map();
  const anchor = {
    getAttribute() {
      return "D:/Projects/ExampleUnityProject/Assets/Light.prefab";
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

test("renderer captures Codex file-reference buttons", async () => {
  const listeners = new Map();
  const button = {
    getAttribute(name) {
      if (name === "data-prompt-link-href") {
        return "D:/Projects/ExampleUnityProject/Assets/Light.prefab";
      }
      return null;
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
  const opened = [];
  __test.startRenderer(
    {
      ipc: {
        invoke: async (_channel, destination) => {
          opened.push(destination);
          return { ok: true, handled: true, code: "opened" };
        },
      },
    },
    documentApi,
  );
  const event = {
    button: 0,
    defaultPrevented: false,
    altKey: false,
    ctrlKey: false,
    metaKey: false,
    shiftKey: false,
    target: {
      closest(selector) {
        if (selector === '[data-file-reference="true"][data-prompt-link-href]') return button;
        return null;
      },
    },
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopImmediatePropagation() {},
  };

  listeners.get("click")(event);
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(opened, [{
    path: "D:\\Projects\\ExampleUnityProject\\Assets\\Light.prefab",
    line: 0,
    column: 0,
  }]);
  __test.stopRenderer();
});

test("renderer replays Codex behavior when main declines the path", async () => {
  const listeners = new Map();
  const anchor = {
    clicks: 0,
    getAttribute() {
      return "D:/Projects/ExampleUnityProject/Assets/Folder";
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
