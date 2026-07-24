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
