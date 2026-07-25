import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const STABLE_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const EXPECTED_REPOSITORY = "kpkhxlgy0/unity-links-codex";
const EXPECTED_UNITY_LICENSE_URL =
  "https://github.com/kpkhxlgy0/unity-links-unity/blob/master/LICENSE";
const EXPECTED_COPYRIGHT = "Copyright (c) 2026 KPK";
const EXPECTED_SUBMODULES = [
  '[submodule "codex-tweak"]',
  "path = codex-tweak",
  "url = git@github.com:kpkhxlgy0/unity-links-codex.git",
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
  const unityPackage = readJson(repositoryRoot, "unity-package/package.json", errors);

  for (const [relativePath, json] of [
    ["codex-tweak/manifest.json", tweakManifest],
    ["codex-tweak/package.json", tweakPackage],
    ["unity-package/package.json", unityPackage],
  ]) {
    if (json && json.version !== requestedVersion) {
      errors.push(`${relativePath}: version must be ${requestedVersion}, got ${String(json.version)}`);
    }
  }

  if (tweakManifest && tweakManifest.githubRepo !== EXPECTED_REPOSITORY) {
    errors.push(`codex-tweak/manifest.json: githubRepo must be ${EXPECTED_REPOSITORY}`);
  }
  if (unityPackage && unityPackage.licensesUrl !== EXPECTED_UNITY_LICENSE_URL) {
    errors.push(`unity-package/package.json: licensesUrl must be ${EXPECTED_UNITY_LICENSE_URL}`);
  }
  for (const [relativePath, json] of [
    ["codex-tweak/package.json", tweakPackage],
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
  return { version: requestedVersion, tag: `v${requestedVersion}` };
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
    console.log(`release-validation=passed version=${result.version} tag=${result.tag}`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
