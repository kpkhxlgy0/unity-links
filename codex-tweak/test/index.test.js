const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const net = require("node:net");
const os = require("node:os");
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

test("finds the nearest Unity root and produces an Assets path", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-unity-link-"));
  try {
    fs.mkdirSync(path.join(root, "Assets", "Data"), { recursive: true });
    fs.mkdirSync(path.join(root, "ProjectSettings"), { recursive: true });
    fs.writeFileSync(
      path.join(root, "ProjectSettings", "ProjectVersion.txt"),
      "m_EditorVersion: 2022.3.23f1",
    );
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
    assert.equal(
      __test.findUnityTarget(path.join(root, "outside.txt"), fs, path).code,
      "notAssetFile",
    );
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
