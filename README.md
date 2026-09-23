[简体中文](README.zh-CN.md)

# Unity Asset Links

Open local file links from Codex Desktop or Claude Code Desktop responses in the matching Unity Editor when they point into a Unity project's
`Assets`, `ProjectSettings`, or `Packages` directory. `Assets` links use Unity's normal asset-opening behavior,
`ProjectSettings` links open Project Settings, and `Packages` links open Package Manager. Code links preserve line and
column information.

## Prerequisites

- Windows 10/11.
- The official Codex Desktop app, Claude Code Desktop, or both installed for the current Windows user.
- Claude++ 0.3.3 or newer for the included Claude Tweak 0.1.4 and current Claude Desktop file references.
- A Unity 2022.3 project.
- PowerShell 7, available as `pwsh`.
- Git, used to clone this repository.
- Node.js 20 or newer and npm, used only during the first installation of Codex++ 1.0.4. Claude++ end users do not
  need Node.js.
- Internet access when cloning the repository and installing Codex++ for the first time.

Run all PowerShell commands from the repository root. The scripts resolve files through `$PSScriptRoot` and do not
depend on a fixed drive letter or project name.

## Repository Location

This repository is the integration and installation entry point. It pins the independently published
[Codex++ tweak](https://github.com/kpkhxlgy0/unity-links-codex) at `codex-tweak/` and
[Claude++ tweak](https://github.com/kpkhxlgy0/unity-links-claude) at `claude-tweak/`, plus the shared
[Unity package](https://github.com/kpkhxlgy0/unity-links-unity) at `unity-package/` through Git submodules. Keep the
checkout after local installation; do not treat it as a temporary installer that can be deleted.

The component submodules use GitHub SSH URLs. Configure a working GitHub SSH key before cloning with
`--recurse-submodules` or initializing an existing checkout.

### Inside a Unity Project

This layout is convenient when the repository primarily serves one project and you want to omit `-UnityProject`.
Place the repository below the Unity project root but outside `Assets`:

```powershell
$unityProject = "D:\Projects\ExampleUnityProject"
New-Item -ItemType Directory -Path (Join-Path $unityProject "Tools") -Force | Out-Null
git clone --recurse-submodules `
    https://github.com/kpkhxlgy0/unity-links.git `
    (Join-Path $unityProject "Tools/unity-links")
Set-Location (Join-Path $unityProject "Tools/unity-links")
```

`Install-UnityPackage.ps1` searches upward from the repository for the nearest project root containing `Assets`,
`Packages/manifest.json`, and `ProjectSettings/ProjectVersion.txt`. If it cannot find one, it reports an error instead
of creating or guessing a Unity project.

### Outside Unity Projects

This layout is convenient when one stable repository serves multiple Unity projects. Pass each project path
explicitly:

```powershell
New-Item -ItemType Directory -Path D:\Tools -Force | Out-Null
git clone --recurse-submodules https://github.com/kpkhxlgy0/unity-links.git D:\Tools\unity-links
Set-Location D:\Tools\unity-links
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -UnityProject D:\Projects\ExampleUnityProject
```

Each Desktop host only needs its own ++ runtime and tweak junction once per Windows user. Both hosts share the same
Unity package, installed separately in every Unity project that needs link handling.

### Existing Clones

After pulling the repository split, initialize the pinned components before running any installer:

```powershell
git pull --ff-only
git submodule update --init --recursive
```

The paths remain `codex-tweak/`, `claude-tweak/`, and `unity-package/`, so existing junctions and Unity `file:`
dependencies stay valid after submodule initialization. Maintenance scripts report the exact initialization command
when a component is missing; they never fetch or modify Git state automatically.

### Direct Component Installation

Codex++ Store users install only `unity-links-codex`. The Claude++ component is currently installed through the
umbrella junction rather than the Tweak Store. Unity Package Manager users install only `unity-links-unity`; the
current stable tagged Git URL is:

```text
https://github.com/kpkhxlgy0/unity-links-unity.git#v0.2.5
```

Use this umbrella checkout when you need the coordinated Windows installer, local `file:` dependency, integration
tests, or development against the exact component set.

## First-Time Setup

Check the environment first, then install the pinned Codex++ 1.0.4 release. The installation script is also the
routine-maintenance entry point: it delegates Codex discovery to the native Codex++ installer, refreshes the patch,
and removes the one previous Store mirror replaced by the run. It does not inspect or modify the Unity Links tweak
junction:

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1
```

After Install succeeds on first use, create the Unity Links tweak junction separately:

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1
```

For Claude Code Desktop, install Claude++ from its official Windows release with the bundled `install.ps1`, then
create the separate Claude Tweak junction. These commands do not install or maintain Claude++ itself:

```powershell
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1
```

Restart only the host whose junction changed. Codex and Claude junctions are independent and can coexist.

The Install script does not close, restart, or launch Codex. If Install prints `Blocked` and exits with code `2`,
manually close Codex as instructed and run the same command again. Do not assume in advance that Codex must be closed;
this is only required when Install confirms that a running mirror would be modified.

Next, install the package in the current Unity project. Omit the parameter when the repository is located inside that
project:

```powershell
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-UnityPackage.ps1
```

When the repository is outside the project, or when installing into another project, pass the explicit path to both
commands:

```powershell
pwsh -NoProfile -File .\Install-UnityPackage.ps1 `
    -UnityProject D:\Projects\AnotherUnityProject -CheckOnly
pwsh -NoProfile -File .\Install-UnityPackage.ps1 `
    -UnityProject D:\Projects\AnotherUnityProject
```

Open the target Unity project, wait for package compilation to finish, and confirm that the Console contains no
compilation errors from this package. For Store mirrors, the wrapper verifies and preserves the package-aware
PowerShell launcher, CMD shim and `Codex++` Start menu shortcut generated by Codex++ 1.0.4. Missing or stale launchers
require `codexplusplus repair`; keep the original Store app registered. Standalone installs retain direct executable
launchers. A desktop shortcut is removed safely only when it actually targets the managed Codex++ Store mirror.

## Routine Maintenance

### After a Codex Desktop Update

After every Codex Desktop update, check the state and then run the same installation/maintenance entry point:

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1
```

`Install-CodexPlusPlus.ps1` invokes Codex++ as `install --no-watcher` without `--app`, so Codex++ uses its own
`locateCodex()` implementation for both standalone and Microsoft Store installs. Standalone installs are maintained in
place. Store installs use the version-specific mirror created by Codex++. After native installation, the wrapper reads
the recorded app root and validates Store launchers without rewriting them; standalone launchers still use the actual
desktop executable. It records
`state.json.appRoot` before maintenance and, after native install and status verification succeed, removes only the
replaced previous Store mirror. Check mode inspects the recorded state and prints the cleanup plan without running
discovery or changing files. Install does not inspect, create, repair, or reload the Unity Links tweak junction.

To remove every recognized old managed mirror instead of only the replaced previous mirror, pass the explicit option:

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly -CleanupAllOldVersions
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CleanupAllOldVersions
```

The all-old mode only considers recognized `OpenAI.Codex_*` directories directly below the managed `store-apps`
root. Both modes exclude the verified current mirror and block deletion when process discovery fails or a target is
running.

State meanings:

- `Current`: the mirror, CMD shim, and Start menu shortcut are all correct.
- `InjectionRequired`: the latest Codex version has not been injected, or the mirror validation does not match.
- `LauncherRequired`: the CMD shim or Start menu shortcut is missing or stale; the desktop shortcut does not affect
  this state.
- `Blocked`: a mirror that must be changed or removed is running, or process discovery failed.

### Shared Codex++ Maintenance

Unity Links and Unreal Links share the same per-user Codex++ managed mirror. Run only one Editor Links maintenance
script at a time; both projects coordinate through one shared lock. A safety block reports its exact reason:

- `MaintenanceBusy`: another Unity Links or Unreal Links maintenance script holds the shared lock.
- `ProcessQueryFailed`: the script could not reliably determine whether Codex is running, so it performs no write.
- `DesktopAppRunning` / `MirrorRunning`: the desktop executable is running under an app root that would be changed.
  Codex CLI processes started by VS Code or Cursor are outside that root and do not block maintenance.
- `OldMirrorRunning`: an old mirror selected for cleanup is still running and will not be deleted.
- `UnsafeLink`: an Inject or Uninject target is a real directory and will not be replaced or removed automatically.

Normal mode re-runs the native Codex++ install path, so Codex must be closed before a patch or Store mirror can be
refreshed. Codex++ itself selects the supported app location and performs Store mirroring; the wrapper adds the shared
lock, pinned first installation, status verification, and guarded old-mirror cleanup. Junction maintenance is a
separate Inject or Uninject operation. The scripts never stop or restart Codex. Do not run concurrent raw
`codexplusplus install` or `repair` commands for this shared setup; use `Install-CodexPlusPlus.ps1` so both engines
observe the same safety checks.

### Moving the Repository

After moving the repository, the old junction and relative `file:` paths in Unity manifests do not update
automatically. Keep the old directory until all of these steps succeed:

1. Run `Inject-CodexPlusPlus.ps1` from the new directory if Codex uses this repository.
2. Run `Inject-ClaudePlusPlus.ps1` from the new directory if Claude uses this repository.
3. Run `Install-UnityPackage.ps1` again for every affected Unity project; pass `-UnityProject` when the repository is
   outside that project.
4. Open those projects and wait for Unity to resolve the package again. Delete the old directory only after confirming
   that everything works.

### Managing Only the Unity Links Tweak Junction

`Inject-CodexPlusPlus.ps1` creates or repairs only this repository's tweak junction. Run it once after the first
successful Install, or when the junction is missing, unsafe, or points at an old repository location. It does not
inspect or repair the Codex Appx mirror or launchers, and routine Appx maintenance does not require rerunning it:

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1
```

To remove only that junction:

```powershell
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1
```

Neither junction command installs, repairs, or uninstalls Codex++, changes launchers, reads `state.json`, or deletes
managed mirrors. A real directory at the live tweak path is blocked and never overwritten or removed. Restart Codex
after changing the junction so the tweak is loaded or unloaded.

Claude uses the same junction-only workflow under its own runtime root:

```powershell
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-ClaudePlusPlus.ps1
pwsh -NoProfile -File .\Uninject-ClaudePlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-ClaudePlusPlus.ps1
```

These scripts manage only `%APPDATA%\claude-plusplus\tweaks\com.kpk.unity-asset-links`; they do not call Claude++
installation, control Claude processes, or change the Codex junction. Restart Claude after a Claude junction change.

Removing the Unity package is independent of removing the tweak junction. To remove the package, delete the
`com.kpk.codex-unity-link` entry from the target project's manifest and let Unity resolve packages again.

## Unity Manifest Updates

`Install-UnityPackage.ps1` only inserts or updates `com.kpk.codex-unity-link` in `Packages/manifest.json` and generates
a `file:` path relative to the target project's `Packages` directory. It does not write `Packages/packages-lock.json`;
Unity continues to maintain that file.

If the manifest has the ReadOnly attribute, the script does not clear it automatically. When version control manages
the file, use that system's checkout workflow to make it writable; otherwise, you can clear ReadOnly yourself. A
Windows ACL denial is reported as a separate error. If writing or post-write validation fails, the script restores the
original bytes. `-CheckOnly` only reads and reports `Current` or `UpdateRequired`, so it does not require a writable
manifest.

## Verification

Run the maintenance-script and tweak tests:

```powershell
pwsh -NoProfile -File .\scripts\tests\Run-Tests.ps1
Push-Location .\codex-tweak
try { npm test }
finally { Pop-Location }
codexplusplus validate-tweak (Resolve-Path .\codex-tweak).Path
Push-Location .\claude-tweak
try { npm test }
finally { Pop-Location }
```

After the Unity project is open and the package has compiled, you can check that project's Named Pipe:

```powershell
node .\codex-tweak\scripts\send-open.js `
    D:\Projects\ExampleUnityProject\Assets\Example.prefab
node .\codex-tweak\scripts\send-open.js `
    D:\Projects\ExampleUnityProject\ProjectSettings\EditorBuildSettings.asset:8
node .\codex-tweak\scripts\send-open.js `
    D:\Projects\ExampleUnityProject\Packages\manifest.json
```

A successful response contains `"ok":true` and `"code":"opened"`.

## Release Process

The three components and umbrella use independent stable versions. Run each named workflow from its repository's
GitHub Actions page. For the `v0.3.0` umbrella release:

1. Validate and publish `unity-links-unity` at `v0.2.5`.
2. Validate and publish `unity-links-codex` at `v0.2.2`.
3. Validate and publish `unity-links-claude` at `v0.1.3`.
4. Update this repository's three submodule pointers to those released commits.
5. Run the umbrella integration tests and Unity link smoke checks from both Desktop hosts.
6. Run this repository's `Release` workflow from `master` with `0.3.0`.
7. Review and manually publish the generated umbrella Draft Release.
8. Submit only the released Codex component commit for Codex++ Tweak Store review; the Claude component remains a
   junction install.

Never move or reuse a release tag. If a workflow retry finds the requested tag at the same commit, it may reuse that
tag; a tag pointing elsewhere is an error. The umbrella workflow reads each component's own version and requires all
three submodules to point to their matching component tags. Update checks are advisory and only see published
Releases, so a Draft Release does not notify users of an update.

## Safety Boundaries and Exit Codes

The Codex maintenance scripts never terminate, launch, or automatically control Codex, and they never modify
WindowsApps directly. With Codex++ 1.0.2, do not run `codexplusplus debug` without an explicit `--app`; these
maintenance scripts do not use `debug`. They also keep the Codex++ watcher disabled and serialize global maintenance
with `Local\CodexPlusPlus.EditorLinks.Maintenance.v1`.

- `0`: the check completed without a safety block, or the normal-mode operation succeeded. In check mode, still read
  the printed state.
- `1`: invalid input, an unavailable prerequisite, a validation failure, or an operation failure prevented a verified
  target state.
- `2`: a safety block requires you to close Codex manually as instructed, or to resolve an unsafe directory or missing
  command before retrying.

## License

This project is licensed under the [MIT License](LICENSE).
