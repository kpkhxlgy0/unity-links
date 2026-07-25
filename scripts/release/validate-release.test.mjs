import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { validateRelease } from "./validate-release.mjs";

const fixtureRoots = [];

function writeJson(root, relativePath, value) {
  const target = join(root, relativePath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, `${JSON.stringify(value, null, 2)}\n`);
}

function fixtureRoot() {
  const root = mkdtempSync(join(tmpdir(), "unity-links-release-"));
  fixtureRoots.push(root);
  writeFileSync(join(root, "LICENSE"), "MIT License\n\nCopyright (c) 2026 KPK\n");
  writeJson(root, "codex-tweak/manifest.json", {
    version: "0.1.0",
    githubRepo: "kpkhxlgy0/unity-links-codex",
  });
  writeJson(root, "codex-tweak/package.json", { version: "0.1.0", license: "MIT" });
  writeJson(root, "unity-package/package.json", {
    version: "0.1.0",
    license: "MIT",
    licensesUrl: "https://github.com/kpkhxlgy0/unity-links-unity/blob/master/LICENSE",
  });
  writeFileSync(
    join(root, ".gitmodules"),
    '[submodule "codex-tweak"]\n' +
      "\tpath = codex-tweak\n" +
      "\turl = git@github.com:kpkhxlgy0/unity-links-codex.git\n" +
      '[submodule "unity-package"]\n' +
      "\tpath = unity-package\n" +
      "\turl = git@github.com:kpkhxlgy0/unity-links-unity.git\n",
  );
  return root;
}

function updateJson(root, relativePath, patch) {
  const target = join(root, relativePath);
  const current = JSON.parse(readFileSync(target, "utf8"));
  writeJson(root, relativePath, { ...current, ...patch });
}

afterEach(() => {
  for (const root of fixtureRoots.splice(0)) rmSync(root, { recursive: true, force: true });
});

test("accepts a valid stable release", () => {
  assert.deepEqual(validateRelease(fixtureRoot(), "0.1.0"), {
    version: "0.1.0",
    tag: "v0.1.0",
  });
});

test("rejects non-stable versions", () => {
  for (const version of ["v0.1.0", "0.1", "0.1.0-beta.1", "latest"]) {
    assert.throws(() => validateRelease(fixtureRoot(), version), /stable MAJOR\.MINOR\.PATCH/);
  }
});

test("rejects every package version mismatch", () => {
  for (const relativePath of [
    "codex-tweak/manifest.json",
    "codex-tweak/package.json",
    "unity-package/package.json",
  ]) {
    const root = fixtureRoot();
    updateJson(root, relativePath, { version: "0.1.1" });
    assert.throws(() => validateRelease(root, "0.1.0"), new RegExp(relativePath.replaceAll("/", "[/\\\\]")));
  }
});

test("rejects a mismatched GitHub repository", () => {
  const root = fixtureRoot();
  updateJson(root, "codex-tweak/manifest.json", { githubRepo: "example/unity-links" });
  assert.throws(() => validateRelease(root, "0.1.0"), /kpkhxlgy0\/unity-links-codex/);
});

test("rejects incorrect component repository metadata", () => {
  const wrongLicenseUrl = fixtureRoot();
  updateJson(wrongLicenseUrl, "unity-package/package.json", {
    licensesUrl: "https://github.com/kpkhxlgy0/unity-links/blob/master/LICENSE",
  });
  assert.throws(() => validateRelease(wrongLicenseUrl, "0.1.0"), /unity-links-unity/);

  const missingGitmodules = fixtureRoot();
  rmSync(join(missingGitmodules, ".gitmodules"));
  assert.throws(() => validateRelease(missingGitmodules, "0.1.0"), /\.gitmodules/);

  const wrongGitmodules = fixtureRoot();
  writeFileSync(join(wrongGitmodules, ".gitmodules"), '[submodule "wrong"]\n\tpath = wrong\n');
  assert.throws(() => validateRelease(wrongGitmodules, "0.1.0"), /unity-links-codex\.git/);
});

test("rejects missing or incorrect MIT metadata", () => {
  const missingLicense = fixtureRoot();
  rmSync(join(missingLicense, "LICENSE"));
  assert.throws(() => validateRelease(missingLicense, "0.1.0"), /LICENSE/);

  const wrongCopyright = fixtureRoot();
  writeFileSync(join(wrongCopyright, "LICENSE"), "MIT License\nCopyright (c) 2026 Someone Else\n");
  assert.throws(() => validateRelease(wrongCopyright, "0.1.0"), /Copyright \(c\) 2026 KPK/);

  for (const relativePath of ["codex-tweak/package.json", "unity-package/package.json"]) {
    const root = fixtureRoot();
    updateJson(root, relativePath, { license: "Apache-2.0" });
    assert.throws(() => validateRelease(root, "0.1.0"), /license must be MIT/);
  }
});
