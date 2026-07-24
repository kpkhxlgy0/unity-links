# Unity Asset Links

Opens ordinary Codex Desktop file links below a Unity project's `Assets` directory through
`AssetDatabase.OpenAsset` in the matching running Unity Editor.

## Requirements

- Windows
- Codex++ 1.0.0 or a newer compatible runtime
- Unity 2022.3
- The local Unity package installed in each target project

The runtime uses only Node, Electron, Windows Named Pipes, and Unity Editor APIs. It has no third-party runtime
dependencies and never starts Unity automatically.

## Locations

- Source: `D:\workspace\codex-tweaks\unity-links`
- Live Codex++ link: `%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links`
- Unity package: `D:\workspace\codex-tweaks\unity-links\unity-package`

## Install

Validate the tweak first:

```powershell
cd D:\workspace\codex-tweaks\unity-links\codex-tweak
npm test
codexplusplus validate-tweak D:\workspace\codex-tweaks\unity-links\codex-tweak
```

Codex++ 1.0.0 advertises `--no-watch`, but its CLI rejects that flag because of a boolean-option parser bug. Use the
watching command below, wait for `Codex++ dev link ready`, and then press Ctrl+C. Stopping the watcher keeps the link:

```powershell
codexplusplus dev D:\workspace\codex-tweaks\unity-links\codex-tweak --replace
```

On a Codex++ version where `--no-watch` is fixed, the one-shot form is:

```powershell
codexplusplus dev D:\workspace\codex-tweaks\unity-links\codex-tweak --replace --no-watch
```

Add this dependency to the Unity project's `Packages/manifest.json`:

```json
"com.kpk.codex-unity-link": "file:D:/workspace/codex-tweaks/unity-links/unity-package"
```

Let Unity resolve the package and compile `KPK.CodexUnityLink.Editor`. Reload Codex++ tweaks or restart Codex if the
tweak was linked after Codex started.

## Behavior

- A normal click on an existing file below `Assets` opens it through the matching Unity project.
- Prefabs use Unity's normal Prefab handling, custom assets reach their registered opener, and source links preserve
  line and column information.
- Ctrl, Shift, Alt, Meta, and non-primary clicks keep Codex behavior.
- Directories, non-local URLs, and files outside `Assets` keep Codex behavior.
- If the matching Unity project is unavailable, Explorer reveals the file and Codex shows a short notice.
- The Unity receiver accepts only the `openAsset` action and validates the exact project root and asset containment.

## Verify

Run the Node tests and manifest validation shown above. With the Unity project open, run a direct Pipe check:

```powershell
node D:\workspace\codex-tweaks\unity-links\codex-tweak\scripts\send-open.js `
  D:\workspace\sgproj\Assets\Light.prefab
```

A successful response contains `"ok":true` and `"code":"opened"`.

## Recovery

On Codex++ 1.0.0, do not run `codexplusplus debug` without an explicit `--app` path; that version can mirror the
original Store ASAR over the patch. If an update overwrites the patch, run:

```powershell
codexplusplus repair --force
```

Relink the tweak afterward if its live junction is missing.

## Remove

Remove `com.kpk.codex-unity-link` from the Unity project's `Packages/manifest.json`, then remove the live tweak link
under `%APPDATA%\codex-plusplus\tweaks`. The standalone source repository is separate and can be kept or deleted
independently.
