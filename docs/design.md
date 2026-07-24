# Codex++ Unity Asset Link Design

Date: 2026-07-24

## Objective

When a user normally clicks a local file link in a Codex Desktop reply, route existing files under a Unity project's
`Assets` directory through that project's running Unity Editor. Unity must open the asset with
`AssetDatabase.OpenAsset`, preserving normal Unity double-click behavior such as Prefab Mode, custom skill asset
editors, scene opening, and the configured external code editor.

The solution must detect Unity projects from link paths rather than hard-code `D:\workspace\sgproj`. It must remain
small, local-only, and independent from the Unity repository.

## Success Criteria

- A normal left-click on an existing file below `<project>/Assets` reaches the matching running Unity Editor.
- Unity calls `AssetDatabase.OpenAsset(asset, line, column)` on its main thread.
- Multiple open Unity projects route requests independently by canonical project root.
- If the matching Unity Editor is unavailable, Codex locates the file in Explorer and shows a short explanation.
- Links outside `Assets`, directory links, modified clicks, and links that cannot be resolved retain Codex's existing
  behavior wherever possible.
- The Codex++ tweak validates successfully and has no third-party runtime dependencies.
- The Unity receiver is Editor-only and does not enter player builds.

## Chosen Approach

Use a Codex++ tweak with `scope: "both"` and a local Unity Package Manager package connected by a per-project Windows
Named Pipe.

This was selected over localhost HTTP because it avoids port discovery, firewall behavior, and network exposure. It
was selected over a polled file queue because it provides immediate responses and has no stale command files.

## Source Layout

```text
<unity-links-repository>\
  README.md
  docs\
    design.md
  codex-tweak\
    manifest.json
    index.js
    test\
  unity-package\
    package.json
    Editor\
      KPK.CodexUnityLink.Editor.asmdef
      UnityAssetLinkReceiver.cs
```

The source directory is its own Git repository. The Unity project consumes `unity-package` through a local `file:`
dependency. The Codex++ live tweaks directory contains a development link to `codex-tweak`; it is not the source of
truth.

## Components

### Renderer Tweak

The renderer half installs one capture-phase click listener on `document` and removes it in `stop()`.

It considers only an unmodified primary-button click whose nearest element is a local file anchor. It parses the
anchor destination into a candidate absolute Windows path plus optional one-based line and column. Supported forms
include Windows absolute paths, slash-prefixed Windows paths emitted by Markdown renderers, and `file:` URLs. The
renderer intercepts the click only when the parsed path contains an `Assets` path segment; all other paths retain the
existing Codex behavior without an asynchronous round trip.

The renderer sends the candidate to the tweak's main half through namespaced Codex++ IPC. It prevents Codex's default
navigation only after the candidate is recognized as a local absolute file path. The main response determines whether
to show a transient success-independent error/fallback notification. Normal successful opens do not show a toast.

Modified clicks, non-file schemes, directories, and unrecognized destinations are ignored.

### Main Tweak

The main half performs all trusted filesystem and transport work:

1. Canonicalize the candidate and verify that it is an existing file.
2. Walk upward from the file directory to find a directory containing both `Assets` and
   `ProjectSettings/ProjectVersion.txt`.
3. Verify with relative-path semantics that the file is strictly below that project's `Assets` directory.
4. Convert the absolute file path to a forward-slash Unity asset path beginning with `Assets/`.
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
handler loads the object with `AssetDatabase.LoadAssetAtPath<UnityEngine.Object>` and calls the appropriate overload of
`AssetDatabase.OpenAsset` for the supplied line and column. This preserves existing `[OnOpenAsset]` handlers, including
Prefab and project-specific skill asset editors.

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
  "projectRoot": "D:\\workspace\\sgproj",
  "assetPath": "Assets/Example/Example.prefab",
  "line": 0,
  "column": 0
}
```

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
- Malformed or non-asset link: leave the link to Codex's existing behavior.
- Unity rejects or fails to open an asset: return a structured response, reveal the file, and show the response message.
- Domain reload during a request: the bounded timeout takes the same fallback path; the receiver returns after reload.
- Logging: failures and lifecycle events go to the Codex++ tweak log or Unity Console. Successful opens do not log by
  default.

## Security Boundaries

- The transport is local-only and has no TCP listener.
- The Pipe should be restricted to the current Windows user where the Unity runtime API supports it.
- Unity independently verifies protocol version, action, exact project root, and containment under its own `Assets`.
- The receiver exposes only `openAsset`; it cannot execute commands, scripts, menu items, or arbitrary methods.
- The request supplies a Unity-relative asset path. Unity reconstructs and validates the corresponding absolute path
  rather than trusting the sender's filesystem claim.
- Traversal segments are normalized before containment checks. The Unity receiver rejects any asset-path segment with
  the `ReparsePoint` attribute, preventing a junction or symbolic link from escaping the project root.

## Tweak Metadata

The tweak uses id `com.kpk.unity-asset-links`, version `0.1.0`, `minRuntime: "1.0.0"`, and `scope: "both"`. Its exact
permission list is `["ipc", "filesystem"]`; version 0.1.0 does not add a settings page. Codex++ 1.0.0 requires a
syntactically valid `githubRepo` even for a local development tweak, so the local-only manifest uses
`kpk-local/unity-asset-links`. A failed advisory release lookup must not affect loading or link handling.

## Verification

The implementation phase will use:

- Node's built-in test runner for destination parsing, line/column parsing, click eligibility, project-root detection,
  asset containment, and deterministic Pipe names.
- `codexplusplus validate-tweak` for manifest and entry validation.
- A direct protocol client check for success, timeout, malformed request, wrong-project, and outside-Assets responses.
- Unity refresh/compile and Console inspection after adding the local package to a project.
- Manual open checks for one Prefab, one project-specific skill asset, and one `.cs` file, confirming each reaches the
  normal Unity `AssetDatabase.OpenAsset` route.

Automated Unity test suites and battle regression tests are outside this task unless explicitly requested.

## Installation Model

Installation and maintenance consists of:

1. Use `Install-CodexPlusPlus.ps1` only when the compatible runtime is missing; otherwise preserve the installed
   version.
2. Use `Inject-CodexPlusPlus.ps1` to maintain the latest version-specific mirror and the exact `codex-tweak`
   junction below `%APPDATA%\codex-plusplus\tweaks`. The script also derives the real desktop executable from the
   Appx manifest and corrects Codex++ launchers when the package contains a separate `Codex.exe` bootstrapper.
3. Use `Install-UnityPackage.ps1` to add `com.kpk.codex-unity-link` through a portable relative `file:` dependency.
4. Let Unity compile the Editor-only package, then manually restart Codex if the maintenance script requests it.

The scripts derive their source paths from their own repository location and do not depend on a fixed checkout path.

## Explicit Non-Goals for Version 0.1.0

- Starting, installing, or selecting a Unity Editor version.
- Opening directories or files from `Packages`, `ProjectSettings`, or outside the Unity project.
- macOS or Linux support.
- HTTP transport, remote access, or an MCP server.
- Custom extension mappings, context menus, or a settings page.
- Direct modification of the Codex application ASAR beyond the installed Codex++ runtime.
- Copying the tweak or receiver source into `sgproj`.
