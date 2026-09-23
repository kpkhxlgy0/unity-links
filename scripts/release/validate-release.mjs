import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const STABLE_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const EXPECTED_CODEX_REPOSITORY = "kpkhxlgy0/unity-links-codex";
const EXPECTED_CLAUDE_REPOSITORY = "kpkhxlgy0/unity-links-claude";
const EXPECTED_CLAUDE_ID = "com.kpk.unity-asset-links";
const EXPECTED_CLAUDE_MIN_RUNTIME = "0.3.3";
const EXPECTED_CLAUDE_SCOPE = "both";
const EXPECTED_CLAUDE_MAIN = "index.js";
const EXPECTED_CLAUDE_PERMISSIONS = ["ipc", "filesystem", "claude-sessions"];
const EXPECTED_UNITY_LICENSE_URL =
  "https://github.com/kpkhxlgy0/unity-links-unity/blob/master/LICENSE";
const EXPECTED_COPYRIGHT = "Copyright (c) 2026 KPK";
const EXPECTED_SUBMODULES = [
  '[submodule "codex-tweak"]',
  "path = codex-tweak",
  "url = git@github.com:kpkhxlgy0/unity-links-codex.git",
  '[submodule "claude-tweak"]',
  "path = claude-tweak",
  "url = git@github.com:kpkhxlgy0/unity-links-claude.git",
  '[submodule "unity-package"]',
  "path = unity-package",
  "url = git@github.com:kpkhxlgy0/unity-links-unity.git",
];

function readJson(repositoryRoot, relativePath, errors) {
  try {
    return JSON.parse(readFileSync(resolve(repositoryRoot, relativePath), "utf8"));
  } catch (error) {
    errors.push(`${relativePath}: ${error instanceof Error ? error.message : String(error)}`);
    return null;
  }
}

export function validateRelease(repositoryRoot, requestedVersion) {
  const errors = [];
  if (!STABLE_VERSION.test(requestedVersion)) {
    errors.push(`version must be a stable MAJOR.MINOR.PATCH value without v: ${requestedVersion}`);
  }

  const tweakManifest = readJson(repositoryRoot, "codex-tweak/manifest.json", errors);
  const tweakPackage = readJson(repositoryRoot, "codex-tweak/package.json", errors);
  const claudeManifest = readJson(repositoryRoot, "claude-tweak/manifest.json", errors);
  const claudePackage = readJson(repositoryRoot, "claude-tweak/package.json", errors);
  const unityPackage = readJson(repositoryRoot, "unity-package/package.json", errors);

  for (const [relativePath, json] of [
    ["codex-tweak/manifest.json", tweakManifest],
    ["codex-tweak/package.json", tweakPackage],
    ["claude-tweak/manifest.json", claudeManifest],
    ["claude-tweak/package.json", claudePackage],
    ["unity-package/package.json", unityPackage],
  ]) {
    if (json && !STABLE_VERSION.test(json.version)) {
      errors.push(`${relativePath}: version must be a stable MAJOR.MINOR.PATCH value`);
    }
  }

  if (tweakManifest && tweakPackage && tweakManifest.version !== tweakPackage.version) {
    errors.push(
      `codex-tweak/package.json: version must match codex-tweak/manifest.json (${String(tweakManifest.version)})`,
    );
  }
  if (claudeManifest && claudePackage && claudeManifest.version !== claudePackage.version) {
    errors.push(
      `claude-tweak/package.json: version must match claude-tweak/manifest.json (${String(claudeManifest.version)})`,
    );
  }

  if (tweakManifest && tweakManifest.githubRepo !== EXPECTED_CODEX_REPOSITORY) {
    errors.push(`codex-tweak/manifest.json: githubRepo must be ${EXPECTED_CODEX_REPOSITORY}`);
  }
  if (claudeManifest?.githubRepo !== EXPECTED_CLAUDE_REPOSITORY) {
    errors.push(`claude-tweak/manifest.json: githubRepo must be ${EXPECTED_CLAUDE_REPOSITORY}`);
  }
  if (claudeManifest?.id !== EXPECTED_CLAUDE_ID) {
    errors.push(`claude-tweak/manifest.json: id must be ${EXPECTED_CLAUDE_ID}`);
  }
  if (claudeManifest?.minRuntime !== EXPECTED_CLAUDE_MIN_RUNTIME) {
    errors.push(`claude-tweak/manifest.json: minRuntime must be ${EXPECTED_CLAUDE_MIN_RUNTIME}`);
  }
  if (claudeManifest?.scope !== EXPECTED_CLAUDE_SCOPE) {
    errors.push(`claude-tweak/manifest.json: scope must be ${EXPECTED_CLAUDE_SCOPE}`);
  }
  if (claudeManifest?.main !== EXPECTED_CLAUDE_MAIN) {
    errors.push(`claude-tweak/manifest.json: main must be ${EXPECTED_CLAUDE_MAIN}`);
  }
  if (JSON.stringify(claudeManifest?.permissions) !== JSON.stringify(EXPECTED_CLAUDE_PERMISSIONS)) {
    errors.push(
      `claude-tweak/manifest.json: permissions must be ${JSON.stringify(EXPECTED_CLAUDE_PERMISSIONS)}`,
    );
  }
  if (unityPackage && unityPackage.licensesUrl !== EXPECTED_UNITY_LICENSE_URL) {
    errors.push(`unity-package/package.json: licensesUrl must be ${EXPECTED_UNITY_LICENSE_URL}`);
  }
  for (const [relativePath, json] of [
    ["codex-tweak/package.json", tweakPackage],
    ["claude-tweak/package.json", claudePackage],
    ["unity-package/package.json", unityPackage],
  ]) {
    if (json && json.license !== "MIT") {
      errors.push(`${relativePath}: license must be MIT`);
    }
  }

  try {
    const license = readFileSync(resolve(repositoryRoot, "LICENSE"), "utf8");
    if (!license.includes("MIT License")) errors.push("LICENSE: MIT License heading is missing");
    if (!license.includes(EXPECTED_COPYRIGHT)) errors.push(`LICENSE: ${EXPECTED_COPYRIGHT} is missing`);
  } catch (error) {
    errors.push(`LICENSE: ${error instanceof Error ? error.message : String(error)}`);
  }

  try {
    const gitmodules = readFileSync(resolve(repositoryRoot, ".gitmodules"), "utf8");
    for (const required of EXPECTED_SUBMODULES) {
      if (!gitmodules.includes(required)) errors.push(`.gitmodules: missing ${required}`);
    }
  } catch (error) {
    errors.push(`.gitmodules: ${error instanceof Error ? error.message : String(error)}`);
  }

  if (errors.length > 0) throw new Error(errors.join("\n"));
  return {
    version: requestedVersion,
    tag: `v${requestedVersion}`,
    componentVersions: {
      codexTweak: tweakManifest.version,
      claudeTweak: claudeManifest.version,
      unityPackage: unityPackage.version,
    },
  };
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  try {
    const repositoryRoot = process.argv[2];
    const requestedVersion = process.argv[3];
    if (!repositoryRoot || !requestedVersion) {
      throw new Error("usage: validate-release.mjs <repository-root> <version>");
    }
    const result = validateRelease(repositoryRoot, requestedVersion);
    console.log(
      `release-validation=passed version=${result.version} tag=${result.tag} `
      + `components=codex-tweak@${result.componentVersions.codexTweak},`
      + `claude-tweak@${result.componentVersions.claudeTweak},`
      + `unity-package@${result.componentVersions.unityPackage}`,
    );
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
