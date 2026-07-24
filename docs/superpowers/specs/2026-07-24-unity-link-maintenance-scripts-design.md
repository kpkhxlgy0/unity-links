# Unity Link Maintenance Scripts Design

## Goal

Provide lightweight, repeatable PowerShell entry points that install Codex++ 1.0.0, inject or remove its patch,
maintain the Unity-link tweak junction, and maintain the Unity local package independently. Move the standalone
`unity-links` Git repository below the Unity project without making it part of Perforce.

## Final Repository Location

The repository moves from:

`D:\workspace\codex-tweaks\unity-links`

to:

`D:\workspace\sgproj\FilePackages\unity-links`

`D:\workspace\sgproj\.p4ignore` already ignores `/FilePackages/`, so the nested Git repository remains local and
independent. Its `.git` directory and commit history are preserved.

After migration:

- The live Codex++ tweak junction points to `<repository>\codex-tweak`.
- The Unity manifest dependency is
  `"com.kpk.codex-unity-link": "file:../FilePackages/unity-links/unity-package"`.
- No file keeps a reference to the old `D:\workspace\codex-tweaks\unity-links` path.

## Structure

The repository root contains four user-facing scripts:

- `Install-CodexPlusPlus.ps1`: installs the official Codex++ 1.0.0 source build when Codex++ is missing, performs the
  initial injection, and establishes the live tweak junction.
- `Inject-CodexPlusPlus.ps1`: detects the current Windows Appx version, repairs injection when necessary, and
  maintains the live tweak junction. It never installs or updates Codex++ itself.
- `Uninject-CodexPlusPlus.ps1`: safely removes the Codex++ injection and this repository's live tweak junction
  without purging Codex++ source, commands, other tweaks, configuration, logs, or backups.
- `Install-UnityPackage.ps1`: locates a Unity project and maintains its local package dependency.

Shared pure functions live in `scripts/UnityLinkMaintenance.psm1`. Dependency-free tests live under
`scripts/tests/` and run with PowerShell directly; Pester is not required.

All four entry points resolve repository assets from `$PSScriptRoot`, so moving the repository as a unit does not
require editing any script.

## Codex++ Installation Flow

`Install-CodexPlusPlus.ps1` supports `-CheckOnly` and uses the official `b-nnett/codex-plusplus` v1.0.0 release,
pinned to immutable commit `f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7`:

1. Validate the local tweak manifest and discover the latest installed `OpenAI.Codex` Appx package.
2. Require PowerShell 7, Node.js 20 or newer, and npm.
3. If `codexplusplus` 1.0.0 or newer is already available, do not download, replace, or downgrade it; delegate to
   `Inject-CodexPlusPlus.ps1` for current-Appx repair and link maintenance.
4. If it is missing, download the source ZIP for the pinned commit over HTTPS into a fresh temporary directory.
   Never pipe a remote PowerShell script directly into the current process.
5. Validate the extracted `package.json` version is exactly 1.0.0 and the expected installer sources exist, then run
   the repository's locked npm install and build commands.
6. Replace `%USERPROFILE%\.codex-plusplus\source` transactionally, retaining the previous source until the new
   source and CLI have been verified.
7. Invoke the newly built CLI with an explicit latest-Appx `--app` path to perform the first Store-safe mirror
   injection and create its CLI/launcher integration.
8. Establish and verify this repository's tweak junction using the same safety checks as the injection script.
9. If the exact mirror that would be patched is running, report `Blocked` before downloading or replacing anything.
   The official unpatched Codex process may remain running because the version-specific managed mirror is a separate
   target.
10. Print a manual close/relaunch prompt when the running Codex is not the newly patched mirror. Never terminate or
    restart Codex.

`-CheckOnly` performs dependency, version, Appx, process, source-path, and junction discovery without network access
or filesystem mutations.

## Codex++ Injection Flow

`Inject-CodexPlusPlus.ps1` supports `-CheckOnly` and follows this sequence:

1. Validate that `codex-tweak/manifest.json` exists below `$PSScriptRoot`.
2. Resolve the `codexplusplus` executable and require version 1.0.0 or newer.
3. Query `Get-AppxPackage -Name OpenAI.Codex` and select the highest installed version.
4. Validate `<InstallLocation>\app\resources\app.asar` and derive the version-specific mirror path under
   `%LOCALAPPDATA%\codex-plusplus\store-apps\<PackageFullName>\app`.
5. Read `%APPDATA%\codex-plusplus\state.json` and run `codexplusplus status` to determine whether state points at
   that mirror and the current ASAR matches the patched hash.
6. In `-CheckOnly`, report one of `Current`, `InjectionRequired`, `LinkRequired`, or `Blocked` and make no changes.
7. If injection is required, invoke
   `codexplusplus repair --force --app <InstallLocation>\app`. The explicit Appx path prevents Codex++ 1.0.0 from
   repairing an obsolete recorded mirror.
8. Create or correct
   `%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links` as a junction to
   `<repository>\codex-tweak`. An existing real directory is never deleted or overwritten; the script stops with a
   clear error. An existing junction is replaced only when its target differs.
9. Re-run state, status, and junction checks. Exit nonzero if the repaired state does not match the latest Appx.
10. If any Codex process is running from a path other than the current patched mirror, print a prominent instruction
    to close it manually and launch the `Codex++` shortcut. The script never terminates or restarts Codex.

If the exact mirror that must be modified is already running, the operation is `Blocked`: the script performs no
injection and asks the user to close Codex and rerun it. Patching files used by a running process is not attempted.

The injection script does not install or update Codex++, download software, run `codexplusplus debug`, or modify the
official WindowsApps package.

## Codex++ Uninjection Flow

`Uninject-CodexPlusPlus.ps1` supports `-CheckOnly` and reverses only the injection layer:

1. Read Codex++ state and resolve the exact managed Appx mirror recorded in `state.json`.
2. Inspect the live `com.kpk.unity-asset-links` path with the same junction safety rules as injection.
3. Report `NotInjected`, `Ready`, `LinkOnly`, or `Blocked` without mutation in `-CheckOnly` mode.
4. If the recorded mirror is running, stop before changing anything and ask the user to close Codex manually and
   rerun. The script never closes it.
5. Invoke `codexplusplus uninstall --app <recorded mirror appRoot>` without `--purge`. This restores or removes the
   managed patch, launcher, watcher, runtime, and state using Codex++'s own backup-aware uninstall path.
6. Only after a successful Codex++ uninstall, remove the exact Unity-link junction if it is a junction or symbolic
   link. A real directory is `Blocked` and is never deleted.
7. If no injection state remains but the safe Unity-link junction exists, remove that link alone. This makes the
   command idempotent after a partially completed prior removal.
8. Verify the state is absent, the managed target is no longer active, and the Unity-link junction is absent.

Uninjection preserves `%USERPROFILE%\.codex-plusplus\source`, the `codexplusplus` command, other tweak directories,
the standalone `unity-links` repository, and the Unity manifest dependency. Unity package removal remains a separate
manual or future script concern.

## Unity Package Maintenance Flow

`Install-UnityPackage.ps1` supports `-UnityProject <path>` and `-CheckOnly`:

1. Validate `<repository>\unity-package\package.json`.
2. If `-UnityProject` is supplied, normalize and validate that directory.
3. Otherwise walk upward from `$PSScriptRoot` until a directory contains all three markers:
   - `Assets/`
   - `Packages/manifest.json`
   - `ProjectSettings/ProjectVersion.txt`
4. Compute the package path relative to the Unity project's `Packages` directory and format it with forward slashes
   and a `file:` prefix.
5. Parse `Packages/manifest.json` as JSON before changing it.
6. If `com.kpk.codex-unity-link` exists with the expected value, report `Current` and do nothing.
7. If it exists with another value, replace only that property value while preserving line endings and unrelated
   text.
8. If it is absent, insert one dependency property without reserializing the entire manifest.
9. Parse the result as JSON and verify the exact dependency value. A failed post-check restores the original text.

`-CheckOnly` reports the expected value and whether a change is required. The script never edits
`Packages/packages-lock.json`; an open Unity Editor updates it through Package Manager.

## Error Handling and Safety

- Every resolved path is converted to an absolute path before comparison.
- Repository migration verifies the source, destination, and containing directories before moving anything.
- The migration is performed from outside the source repository so the active shell is not inside the moved tree.
- No recursive deletion is used for repository migration.
- Junction replacement is limited to the exact tweak ID path and only when the existing item is a junction or
  symbolic link.
- Source installation is pinned to the immutable Codex++ 1.0.0 commit, validates the extracted version before
  running npm, and retains the previous source until the replacement CLI is verified.
- Uninjection never passes `--purge` and removes the Unity-link path only after proving it is a link.
- Missing commands, inaccessible Appx files, invalid JSON, ambiguous Unity roots, and failed Codex++ verification
  produce actionable errors and nonzero exit codes.
- None of the scripts submits Perforce changes, closes applications, launches UI automation, or modifies Unity
  assets.

## Testing

Tests are written before implementation and exercise real pure functions or temporary filesystem fixtures:

- Select the newest Appx package by version.
- Derive the matching Codex++ mirror path.
- Classify current, stale-injection, missing-link, and blocked states.
- Classify Codex++ install as already available, install required, dependency blocked, or target-mirror blocked.
- Validate pinned installer archive layout/version and transactional source replacement decisions without network
  access in unit tests.
- Classify uninjection as not injected, ready, link-only, running-target blocked, or unsafe-link blocked.
- Verify uninjection command construction never contains `--purge` and targets the recorded mirror explicitly.
- Resolve repository-relative tweak and package paths after simulated moves.
- Find a Unity root by walking upward from a nested `FilePackages/unity-links` directory.
- Compute the portable manifest value.
- Insert, update, and no-op the manifest property while preserving unrelated content and CRLF/LF style.
- Reject invalid manifest JSON and unsafe non-junction tweak targets.
- Verify `-CheckOnly` produces no filesystem mutations.

Final integration verification runs all four scripts in `-CheckOnly`, runs the existing Node tweak tests, validates the
tweak with Codex++, refreshes Unity after the manifest migration, and checks the Unity Console. Injection itself is
not performed while Codex is using the target mirror.

## Migration and Acceptance

Implementation completes in this order:

1. Add and test all four scripts in the current standalone repository.
2. Commit the implementation while the repository is still at its original path.
3. Move the repository to `D:\workspace\sgproj\FilePackages\unity-links`.
4. Run the injection script to repair the junction and, if allowed by process state, the latest Appx mirror. The
   installation script remains available for clean machines and is verified in `-CheckOnly` mode on this already
   installed machine.
5. Run the Unity package script to replace the old absolute manifest value with the computed relative value.
6. Let Unity refresh, then verify compilation and Console output.
7. Confirm the old repository path is absent, the nested Git worktree is clean, and Perforce does not include the
   ignored `FilePackages/unity-links` source.

Interactive acceptance consists of manually closing the official Codex process when prompted, starting the
`Codex++` shortcut, and clicking the existing Prefab, skill asset, and C# links. The automation stops before any
close or restart and waits for explicit user confirmation.
