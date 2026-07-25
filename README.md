[简体中文](README.zh-CN.md)

# Unity Asset Links

Open local file links from Codex Desktop responses in the matching Unity Editor when they point into a Unity project's
`Assets`, `ProjectSettings`, or `Packages` directory. `Assets` links use Unity's normal asset-opening behavior,
`ProjectSettings` links open Project Settings, and `Packages` links open Package Manager. Code links preserve line and
column information.

## Prerequisites

- Windows 10/11.
- The official Codex Desktop app installed for the current Windows user.
- A Unity 2022.3 project.
- PowerShell 7, available as `pwsh`.
- Git, used to clone this repository.
- Node.js 20 or newer and npm, used during the first installation of Codex++ 1.0.0.
- Internet access when cloning the repository and installing Codex++ for the first time.

Run all PowerShell commands from the repository root. The scripts resolve files through `$PSScriptRoot` and do not
depend on a fixed drive letter or project name.

## Repository Location

This repository is both the long-term source directory for the Codex++ tweak and the long-term source directory for
the Unity Package Manager `file:` dependency. Keep it after installation; do not treat it as a temporary installer
that can be deleted.

### Inside a Unity Project

This layout is convenient when the repository primarily serves one project and you want to omit `-UnityProject`.
Place the repository below the Unity project root but outside `Assets`:

```powershell
$unityProject = "D:\Projects\ExampleUnityProject"
New-Item -ItemType Directory -Path (Join-Path $unityProject "Tools") -Force | Out-Null
git clone https://github.com/kpkhxlgy0/unity-links.git (Join-Path $unityProject "Tools/unity-links")
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
git clone https://github.com/kpkhxlgy0/unity-links.git D:\Tools\unity-links
Set-Location D:\Tools\unity-links
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -UnityProject D:\Projects\ExampleUnityProject
```

Codex++ only needs to be installed and injected once per Windows user. Install the Unity package separately in every
Unity project that needs link handling.

## First-Time Setup

Check the environment first, then install the pinned Codex++ 1.0.0 release. The normal installation script continues
by injecting the current Codex Appx and maintaining the tweak link:

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1
```

The script does not close, restart, or launch Codex. If it prints `Blocked` and exits with code `2`, manually close
Codex as instructed and run the same command again. Do not assume in advance that Codex must be closed; this is only
required when the script confirms that a running mirror would be modified.

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
compilation errors from this package. Finally, launch `Codex++` from the Windows Start menu; do not use the original
`Codex` entry. The maintenance scripts keep only the CMD shim and Start menu shortcut and do not create a desktop
shortcut. A desktop shortcut created by an older version is removed safely only when it actually targets the managed
Codex++ mirror.

## Routine Maintenance

### After a Codex Desktop Update

After every Codex Appx update, check the state and then perform the required maintenance:

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1
```

`Inject-CodexPlusPlus.ps1` automatically selects the highest installed Codex Appx version and maintains its separate
Codex++ mirror, CMD shim, Start menu shortcut, and the
`%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links` junction. It reads the actual desktop entry point from
`AppxManifest.xml`, so it remains compatible when an Appx contains both helper launchers and the desktop application.

State meanings:

- `Current`: the mirror, CMD shim, Start menu shortcut, and tweak junction are all correct.
- `InjectionRequired`: the latest Codex version has not been injected, or the mirror validation does not match.
- `LauncherRequired`: the CMD shim or Start menu shortcut is missing or stale; the desktop shortcut does not affect
  this state.
- `LinkRequired`: injection is correct, but the tweak junction is missing or still points to an old repository
  location.
- `Blocked`: a mirror that must be changed is running, or the live tweak path is a real directory that cannot be
  replaced safely.

### Moving the Repository

After moving the repository, the old junction and relative `file:` paths in Unity manifests do not update
automatically. Keep the old directory until all of these steps succeed:

1. Run `Inject-CodexPlusPlus.ps1` from the new directory so the tweak junction points to the new location.
2. Run `Install-UnityPackage.ps1` again for every affected Unity project; pass `-UnityProject` when the repository is
   outside that project.
3. Open those projects and wait for Unity to resolve the package again. Delete the old directory only after confirming
   that everything works.

### Uninjecting

```powershell
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1
```

Uninjection performs a non-purge uninstall against the exact app root recorded in `state.json`. It removes this
tweak's junction only after the uninstall is confirmed. It does not remove the Codex++ source or command, other
tweaks, this repository, or any Unity manifest.

Removing the Unity package is independent of uninjection. To remove the package, delete the
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

## Safety Boundaries and Exit Codes

The Codex maintenance scripts never terminate, launch, or automatically control Codex, and they never modify
WindowsApps directly. With Codex++ 1.0.0, do not run `codexplusplus debug` without an explicit `--app`; these
maintenance scripts do not use `debug`.

- `0`: the check completed without a safety block, or the normal-mode operation succeeded. In check mode, still read
  the printed state.
- `1`: invalid input, an unavailable prerequisite, a validation failure, or an operation failure prevented a verified
  target state.
- `2`: a safety block requires you to close Codex manually as instructed, or to resolve an unsafe directory or missing
  command before retrying.
