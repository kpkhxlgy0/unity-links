# Codex++ Unity Asset Link Design

Date: 2026-07-24
Updated: 2026-07-25

## Objective

When a user normally clicks a local file link in a Codex Desktop reply, route existing files under a Unity project's
`Assets`, `ProjectSettings`, or `Packages` directory through that project's running Unity Editor. `Assets` files use
`AssetDatabase.OpenAsset`, `ProjectSettings` files open the Project Settings window, and `Packages` files open the
Package Manager window.

The solution must detect Unity projects from link paths rather than hard-code a checkout location. It must remain
small, local-only, and independent from any particular Unity repository.

## Success Criteria

- A normal left-click on an existing file below `<project>/Assets`, `<project>/ProjectSettings`, or
  `<project>/Packages` reaches the matching running Unity Editor.
- Unity calls `AssetDatabase.OpenAsset(asset, line, column)` for `Assets` files on its main thread.
- Unity calls `SettingsService.OpenProjectSettings()` for `ProjectSettings` files. Version 0.1.0 does not maintain a
  filename-to-settings-page mapping.
- Unity opens Package Manager for `Packages` files. For `Packages/<package-id>/**`, it passes `<package-id>` as the
  package to select; root files such as `manifest.json` and `packages-lock.json` open the unfiltered window.
- Multiple open Unity projects route requests independently by canonical project root.
- If the matching Unity Editor is unavailable, Codex locates the file in Explorer and shows a short explanation.
- Links outside the three supported directories, directory links, modified clicks, and links that cannot be resolved
  retain Codex's existing behavior wherever possible.
- The Codex++ tweak validates successfully and has no third-party runtime dependencies.
- The Unity receiver is Editor-only and does not enter player builds.

## Chosen Approach

Use a Codex++ tweak with `scope: "both"` and a local Unity Package Manager package connected by a per-project Windows
Named Pipe.

This was selected over localhost HTTP because it avoids port discovery, firewall behavior, and network exposure. It
was selected over a polled file queue because it provides immediate responses and has no stale command files.

## Source Layout

```text
<unity-links-umbrella>\
  README.md
  docs\
    design.md
  codex-tweak\       Git submodule -> kpkhxlgy0/unity-links-codex
  unity-package\     Git submodule -> kpkhxlgy0/unity-links-unity
```

`kpkhxlgy0/unity-links-codex` is authoritative for the Codex++ tweak, manifest, store icon, unit tests, and component
release. `kpkhxlgy0/unity-links-unity` is authoritative for the Editor receiver, UPM metadata, and component release.
The umbrella repository owns the shared protocol description, Windows maintenance scripts, integration tests, and the
exact compatible pair through pinned Git submodule commits.
Both gitlinks use GitHub SSH URLs (`git@github.com:kpkhxlgy0/unity-links-codex.git` and
`git@github.com:kpkhxlgy0/unity-links-unity.git`) so maintainers use the same authenticated transport for fetch and
push.

The Unity project can consume `unity-package` through the umbrella's local `file:` path or directly from a tagged
component Git URL. The Codex++ live tweaks directory contains a development link to `codex-tweak`; it is not the source
of truth. Existing local paths remain stable after the split because the two component directory names do not change.

## Components

### Renderer Tweak

The renderer half installs one capture-phase click listener on `document` and removes it in `stop()`.

It considers only an unmodified primary-button click whose nearest element is a local file anchor. It parses the
anchor destination into a candidate absolute Windows path plus optional one-based line and column. Supported forms
include Windows absolute paths, slash-prefixed Windows paths emitted by Markdown renderers, and `file:` URLs. The
renderer intercepts the click only when the parsed path contains an `Assets`, `ProjectSettings`, or `Packages` path
segment; all other paths retain the existing Codex behavior without an asynchronous round trip.

The renderer sends the candidate to the tweak's main half through namespaced Codex++ IPC. It prevents Codex's default
navigation only after the candidate is recognized as a local absolute file path. The main response determines whether
to show a transient success-independent error/fallback notification. Normal successful opens do not show a toast.

Modified clicks, non-file schemes, directories, and unrecognized destinations are ignored.

### Main Tweak

The main half performs all trusted filesystem and transport work:

1. Canonicalize the candidate and verify that it is an existing file while retaining the original lexical path for
   reparse-point checks.
2. Walk upward independently from the original and canonical file paths to find directories containing both `Assets`
   and `ProjectSettings/ProjectVersion.txt`; require both roots to resolve to the same project.
3. Reject lexical traversal and reparse-point segments in the original accepted-root path, then verify with
   relative-path semantics that the canonical file is strictly below that project's `Assets`, `ProjectSettings`, or
   `Packages` directory.
4. Convert the absolute file path to a forward-slash Unity project path beginning with the accepted root name.
5. Derive the project Pipe name from a stable hash of the case-normalized canonical project root.
6. Send one request and wait for a bounded response.

The main half uses Node and Electron facilities already present in the Codex++ main process. It does not launch a
helper executable. On connection failure it calls Electron's file-reveal facility and returns a fallback result to
the renderer.

### Unity Editor Package

The package contains an Editor-only assembly and an automatically initialized receiver. On editor startup and after
domain reload it computes the same Pipe name from `Directory.GetParent(Application.dataPath)` and begins accepting
requests in a background task.

Transport callbacks never call Unity APIs directly. A valid request is queued to the Unity main thread. The main-thread
handler dispatches by the validated first path segment:

- `Assets`: load the object with `AssetDatabase.LoadAssetAtPath<UnityEngine.Object>` and call the appropriate overload
  of `AssetDatabase.OpenAsset` for the supplied line and column. This preserves existing `[OnOpenAsset]` handlers,
  including Prefab Mode, registered custom asset editors, scene opening, and the configured external code editor.
- `ProjectSettings`: call `SettingsService.OpenProjectSettings()` and ignore line and column because settings are
  edited through Unity's settings UI.
- `Packages`: call `UnityEditor.PackageManager.UI.Window.Open(packageToSelect)`, deriving `packageToSelect` only from
  the first directory below `Packages`; pass `null` for files directly below `Packages`.

The server cancels and disposes its listener before assembly reload and when Unity quits, then starts again after the
next domain load.

## Request Protocol

Each connection carries one UTF-8, newline-delimited JSON request and one response.

Request fields:

```json
{
  "version": 1,
  "requestId": "opaque-id",
  "action": "openAsset",
  "projectRoot": "D:\\Projects\\ExampleUnityProject",
  "assetPath": "Assets/Example/Example.prefab",
  "line": 0,
  "column": 0
}
```

The protocol retains the v1 `openAsset` action and `assetPath` field names for compatibility; `assetPath` now carries
any validated path below one of the three supported project roots.

Response fields:

```json
{
  "version": 1,
  "requestId": "opaque-id",
  "ok": true,
  "code": "opened",
  "message": ""
}
```

The initial response codes are `opened`, `invalidRequest`, `wrongProject`, `assetOutsideProject`, `assetMissing`, and
`openFailed`. Before transport, the main half can return `fileMissing`, `notUnityProject`, or `notAssetFile`. The tweak
produces `unityUnavailable` when it cannot connect within the timeout.

The request and response have conservative size limits. Unknown protocol versions, actions, or oversized messages are
rejected.

## Project Detection and Pipe Identity

Both sides canonicalize project roots by resolving full paths, trimming trailing separators, normalizing separators,
and applying Windows case-insensitive comparison. The Pipe identity is a versioned prefix plus a SHA-256 digest of the
normalized root, for example `kpk-codex-unity-link-v1-<digest>`.

The full project path is still included in the request. Unity compares it with its own root before opening anything,
so a digest collision or incorrectly routed request cannot cross projects.

## Error Handling

- Unity unavailable: use a short connection timeout (target 300 ms), reveal the existing file in Explorer, and show a
  transient Codex notification.
- File missing: do not send a request; show a concise notification. If a containing directory still exists, reveal it.
- Malformed or unsupported project link: leave the link to Codex's existing behavior.
- Unity rejects or fails to open a target: return a structured response, reveal the file, and show the response
  message.
- Domain reload during a request: the bounded timeout takes the same fallback path; the receiver returns after reload.
- Logging: failures and lifecycle events go to the Codex++ tweak log or Unity Console. Successful opens do not log by
  default.

## Security Boundaries

- The transport is local-only and has no TCP listener.
- The Pipe should be restricted to the current Windows user where the Unity runtime API supports it.
- Unity independently verifies protocol version, action, exact project root, and containment under its own `Assets`,
  `ProjectSettings`, or `Packages`.
- The receiver exposes only `openAsset`; it cannot execute commands, scripts, menu items, or arbitrary methods.
- The request supplies a Unity-relative asset path. Unity reconstructs and validates the corresponding absolute path
  rather than trusting the sender's filesystem claim.
- Empty and traversal segments are rejected before containment checks. The main process requires the lexical and
  canonical paths to identify the same project and checks the original path with `lstatSync`; the Unity receiver
  independently rejects any accepted-path segment with the `ReparsePoint` attribute. A junction or symbolic link
  therefore cannot be used as a Unity-link alias even when its target remains inside an accepted project root or points
  at another Unity project.

## Tweak Metadata

The original tweak uses id `com.kpk.unity-asset-links`, version `0.1.0`, `minRuntime: "1.0.0"`, and `scope: "both"`.
Its exact permission list is `["ipc", "filesystem"]`; version 0.1.0 does not add a settings page. Codex++ 1.0.0
requires a syntactically valid `githubRepo` even for a local development tweak, so version 0.1.0 uses
`kpkhxlgy0/unity-links`. Starting with the split `0.2.0` component, `githubRepo` is
`kpkhxlgy0/unity-links-codex`. A failed advisory release lookup must not affect loading or link handling.

## Verification

The implementation phase will use:

- Node's built-in test runner for destination parsing, line/column parsing, click eligibility, project-root detection,
  supported-file containment, and deterministic Pipe names.
- `codexplusplus validate-tweak` for manifest and entry validation.
- A direct protocol client check for success, timeout, malformed request, wrong-project, and unsupported-path
  responses.
- Unity refresh/compile and Console inspection after adding the local package to a project.
- Manual open checks for one Prefab, one registered custom asset, one `.cs` file, one Project Settings file, one root
  Packages file, and one package-owned file, confirming each reaches its designed Unity UI route.

Automated Unity test suites and battle regression tests are outside this task unless explicitly requested.

## Installation Model

Installation and maintenance consists of:

1. Use `Install-CodexPlusPlus.ps1` to install or preserve the compatible runtime, maintain the latest
   version-specific mirror, CMD shim, and Start Menu shortcut, and clean selected old mirrors. It never reads or
   modifies a tweak junction and never reloads tweaks.
2. After the first Install, use `Inject-CodexPlusPlus.ps1` to maintain only the exact `codex-tweak` junction below
   `%APPDATA%\codex-plusplus\tweaks`. Use `Uninject-CodexPlusPlus.ps1` to inspect or remove only that junction.
3. Use `Install-UnityPackage.ps1` once per Unity project to add `com.kpk.codex-unity-link` through a portable relative
   `file:` dependency. A repository inside the project is found by walking upward; an external repository requires
   `-UnityProject`.
4. Let Unity compile the Editor-only package, then manually restart Codex after Inject changes the junction.

The scripts derive their source paths from their own repository location and do not depend on a fixed checkout path.
Because both the tweak junction and Unity package dependency reference this repository, moving it requires rerunning
the injection script and the Unity installer for every affected project.

Unity Links and Unreal Links independently implement the same global-maintenance contract because they share one
per-user Codex++ mirror. Every global entry acquires
`Local\CodexPlusPlus.EditorLinks.Maintenance.v1`; a busy lock or failed `Win32_Process` query blocks writes with exit
code `2`. Process discovery is repeated immediately before an ASAR-changing Codex++ command. Current latest mirror
plus injection drift routes `repair --force --app` to `MirrorAppRoot`. A new, stale, missing, or incomplete latest
mirror routes rebuilding to `OfficialAppRoot`, and only after a reliable check proves that no Codex process is
running. Completeness requires the mirror root, `resources/app.asar`, and the manifest-derived desktop executable.
A failed mutation rereads `state.json`, `codexplusplus status`, and mirror completeness while the lock is still held;
the observed state is reported without assuming that the command exit code describes the final filesystem state. A
failed direct mirror repair never falls back to the official Appx in the same run. Launcher-only maintenance may
proceed while the current patched mirror runs when the initial process query succeeded. The watcher remains disabled.
Tweak junction injection is a separate command and its state never affects Install maintenance or blocking.

## Explicit Non-Goals for Version 0.1.0

- Starting, installing, or selecting a Unity Editor version.
- Opening directories, files from other project-root directories, or files outside the Unity project.
- macOS or Linux support.
- HTTP transport, remote access, or an MCP server.
- Custom extension mappings, context menus, or a settings page.
- Direct modification of the Codex application ASAR beyond the installed Codex++ runtime.
- Copying the tweak or receiver source into a particular host Unity project.
