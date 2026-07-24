# Unity Link Maintenance Scripts Design

## Goal

Provide two lightweight, repeatable PowerShell entry points that maintain the Codex++ injection/tweak link and the
Unity local package independently. Move the standalone `unity-links` Git repository below the Unity project without
making it part of Perforce.

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

The repository root contains two user-facing scripts:

- `Update-CodexPlusPlus.ps1`: detects the current Windows Appx version, repairs injection when necessary, and
  maintains the live tweak junction.
- `Install-UnityPackage.ps1`: locates a Unity project and maintains its local package dependency.

Shared pure functions live in `scripts/UnityLinkMaintenance.psm1`. Dependency-free tests live under
`scripts/tests/` and run with PowerShell directly; Pester is not required.

Both entry points resolve repository assets from `$PSScriptRoot`, so moving the repository as a unit does not require
editing either script.

## Codex++ Maintenance Flow

`Update-CodexPlusPlus.ps1` supports `-CheckOnly` and follows this sequence:

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

The script does not install or update Codex++, download software, run `codexplusplus debug`, or modify the official
WindowsApps package.

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
- Missing commands, inaccessible Appx files, invalid JSON, ambiguous Unity roots, and failed Codex++ verification
  produce actionable errors and nonzero exit codes.
- Neither script submits Perforce changes, closes applications, launches UI automation, or modifies Unity assets.

## Testing

Tests are written before implementation and exercise real pure functions or temporary filesystem fixtures:

- Select the newest Appx package by version.
- Derive the matching Codex++ mirror path.
- Classify current, stale-injection, missing-link, and blocked states.
- Resolve repository-relative tweak and package paths after simulated moves.
- Find a Unity root by walking upward from a nested `FilePackages/unity-links` directory.
- Compute the portable manifest value.
- Insert, update, and no-op the manifest property while preserving unrelated content and CRLF/LF style.
- Reject invalid manifest JSON and unsafe non-junction tweak targets.
- Verify `-CheckOnly` produces no filesystem mutations.

Final integration verification runs both scripts in `-CheckOnly`, runs the existing Node tweak tests, validates the
tweak with Codex++, refreshes Unity after the manifest migration, and checks the Unity Console. Injection itself is
not performed while Codex is using the target mirror.

## Migration and Acceptance

Implementation completes in this order:

1. Add and test the scripts in the current standalone repository.
2. Commit the implementation while the repository is still at its original path.
3. Move the repository to `D:\workspace\sgproj\FilePackages\unity-links`.
4. Run the Codex++ maintenance script to repair the junction and, if allowed by process state, the latest Appx
   mirror.
5. Run the Unity package script to replace the old absolute manifest value with the computed relative value.
6. Let Unity refresh, then verify compilation and Console output.
7. Confirm the old repository path is absent, the nested Git worktree is clean, and Perforce does not include the
   ignored `FilePackages/unity-links` source.

Interactive acceptance consists of manually closing the official Codex process when prompted, starting the
`Codex++` shortcut, and clicking the existing Prefab, skill asset, and C# links. The automation stops before any
close or restart and waits for explicit user confirmation.
