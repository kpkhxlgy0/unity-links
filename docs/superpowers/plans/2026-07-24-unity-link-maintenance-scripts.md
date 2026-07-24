# Unity Link Maintenance Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add portable PowerShell entry points that install Codex++ 1.0.0, inject or remove its latest Codex Desktop
Appx patch, maintain the live Unity-link tweak junction, and maintain a Unity project's local package reference, then
move this standalone Git repository into `D:\workspace\sgproj\FilePackages\unity-links` without adding it to
Perforce.

**Architecture:** Dependency-free PowerShell 7 scripts delegate path, JSON, Appx-layout, install/uninject state, and
safe junction logic to `scripts/UnityLinkMaintenance.psm1`. Installation downloads and validates one immutable
official Codex++ 1.0.0 source revision; injection queries the latest Appx and calls Codex++ with an explicit app path;
uninjection uses Codex++'s backup-aware uninstall without purge. The Unity script finds a project from its own
location or an explicit path and performs a targeted, reversible edit of one manifest property. All risky decisions
are covered by pure-function or temporary-filesystem tests before live integration.

**Tech Stack:** PowerShell 7.6+, Windows Appx cmdlets, Codex++ 1.0.0+, NTFS junctions, JSON, Git, Unity 2022.3,
Unity MCP, Perforce MCP.

## Global Constraints

- Work in `D:\workspace\codex-tweaks\unity-links` through Task 7. Move it only in Task 8, after all implementation
  commits are complete and the worktree is clean.
- The final repository root is `D:\workspace\sgproj\FilePackages\unity-links`; preserve its nested `.git` directory
  and history.
- Resolve all repository-owned paths from `$PSScriptRoot`. Production code must not contain either the old or final
  absolute repository path.
- Target PowerShell 7; do not add Pester or helper executables. Only `Install-CodexPlusPlus.ps1` may access the
  network or install dependencies, and only for the pinned official v1.0.0 source revision.
- Never run `codexplusplus debug`. Inject/repair only with
  `codexplusplus repair --force --app <latest Appx InstallLocation>\app`.
- Never patch `WindowsApps` in place. Codex++ must create and patch its version-specific local mirror.
- Pin clean Codex++ installs to official commit `f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7` (tag `v1.0.0`). Do not
  downgrade an existing compatible version and never pipe a downloaded PowerShell script into the current process.
- Never stop, kill, restart, or launch Codex. If a restart is required, print a prominent manual instruction. Stop
  the overall task and wait for explicit user confirmation before the interactive close/relaunch boundary.
- Never replace a real directory at the live tweak path. Replace only an existing junction or symbolic link whose
  exact path is the expected tweak ID.
- Uninject with `codexplusplus uninstall --app <recorded mirror>` only. Never pass `--purge`; preserve the Codex++
  source/command, unrelated tweaks, this repository, and the Unity manifest.
- `Install-UnityPackage.ps1` owns only `com.kpk.codex-unity-link` in `Packages/manifest.json`; it never edits
  `Packages/packages-lock.json`.
- Keep the existing binary change to
  `Assets/Plugins/SkillTimeline/Editor/Data/SkillGraphData/1.asset`; do not revert or modify it.
- Preserve all unrelated edits in `Packages/manifest.json` and `Packages/packages-lock.json`, which are already open
  in Perforce changelist 3423589. Do not submit.
- `FilePackages/` is P4-ignored repository intent. Do not use `p4 add -I` or otherwise force-add the moved Git repo.
- Do not use Computer Use, close application windows, run Unity automated tests, or submit Perforce changes.
- Read `D:\workspace\sgproj\docs\agent-rules\verification.md` before the Unity integration step.

## Observable Success Conditions

- `pwsh -NoProfile -File scripts/tests/Run-Tests.ps1` passes without Pester or machine-specific fixtures.
- `Install-CodexPlusPlus.ps1 -CheckOnly` reports whether compatible Codex++ is already installed or a pinned install
  is required, without network or filesystem mutation.
- `Inject-CodexPlusPlus.ps1 -CheckOnly` reports exactly one of `Current`, `InjectionRequired`, `LinkRequired`, or
  `Blocked` and changes no files or links.
- `Uninject-CodexPlusPlus.ps1 -CheckOnly` reports `NotInjected`, `Ready`, `LinkOnly`, or `Blocked` and changes no files
  or links.
- A normal Codex maintenance run uses the latest installed `OpenAI.Codex` package, verifies the patched mirror, and
  leaves the live tweak junction pointing at the moved repository.
- A normal uninjection run refuses a running target, invokes official uninstall without purge, removes only the safe
  Unity-link junction, and preserves the Codex++ CLI/source plus Unity package reference.
- `Install-UnityPackage.ps1 -CheckOnly` is mutation-free; a normal run leaves exactly this dependency value:
  `file:../FilePackages/unity-links/unity-package`.
- Unity recompiles the local package with no real Console errors, existing Node tests still pass, and direct Pipe
  requests still open the Prefab, custom skill asset, and C# source.
- The old repository path is absent, the moved nested Git worktree is clean, and Perforce does not contain files
  below `FilePackages/unity-links`.
- The task pauses before anyone closes or relaunches Codex.

## Planned File Map

- Create `scripts/UnityLinkMaintenance.psm1`: shared pure functions plus guarded filesystem helpers.
- Create `scripts/tests/TestHarness.ps1`: tiny dependency-free assertion harness.
- Create `scripts/tests/Run-Tests.ps1`: isolated runner for every `*.Tests.ps1` file.
- Create `scripts/tests/UnityLinkMaintenance.Tests.ps1`: path, manifest, Appx, state, and junction tests.
- Create `Install-CodexPlusPlus.ps1`: pinned first-time Codex++ 1.0.0 source installation and initial injection.
- Create `Inject-CodexPlusPlus.ps1`: user-facing Codex++ detection/injection/link command.
- Create `Uninject-CodexPlusPlus.ps1`: safe, non-purge injection removal and Unity-link unlink command.
- Create `Install-UnityPackage.ps1`: user-facing Unity package detection/manifest command.
- Modify `README.md`: portable install, check, repair, migration, and manual-restart instructions.
- Modify during integration only: `D:\workspace\sgproj\Packages\manifest.json`.
- Review but do not hand-edit: `D:\workspace\sgproj\Packages\packages-lock.json`.

---

### Task 1: Dependency-Free Harness and Portable Repository/Unity Discovery

**Files:**

- Create: `scripts/tests/TestHarness.ps1`
- Create: `scripts/tests/Run-Tests.ps1`
- Create: `scripts/tests/UnityLinkMaintenance.Tests.ps1`
- Create: `scripts/UnityLinkMaintenance.psm1`

**Interfaces:**

- `Resolve-NormalizedPath([string] $Path, [string] $BasePath)` -> absolute path without a trailing separator.
- `Test-PathEqual([string] $Left, [string] $Right)` -> case-insensitive Windows path equality.
- `Get-UnityLinkRepositoryLayout([string] $RepositoryRoot)` -> tweak/package/manifest absolute paths.
- `Test-UnityProjectRoot([string] $Path)` -> all three Unity markers are present.
- `Find-UnityProjectRoot([string] $StartPath)` -> nearest ancestor Unity root or throws.
- `Get-UnityPackageManifestValue([string] $UnityProjectRoot, [string] $PackageRoot)` -> portable `file:` value.

- [ ] **Step 1: Create the test harness and runner**

Create `scripts/tests/TestHarness.ps1` with these concrete helpers:

```powershell
Set-StrictMode -Version Latest
$script:TestCount = 0
$script:FailureCount = 0

function Test-Case
{
    param([string] $Name, [scriptblock] $Body)

    $script:TestCount++
    try
    {
        & $Body
        Write-Host "PASS $Name"
    }
    catch
    {
        $script:FailureCount++
        Write-Host "FAIL $Name`n$($_.Exception.Message)" -ForegroundColor Red
    }
}

function Assert-True
{
    param([bool] $Condition, [string] $Message = "Expected condition to be true.")
    if (!$Condition) { throw $Message }
}

function Assert-Equal
{
    param($Expected, $Actual, [string] $Message = "")
    if ($Expected -ceq $Actual) { return }
    throw "Expected <$Expected>, actual <$Actual>. $Message"
}

function Assert-Throws
{
    param([scriptblock] $Body, [string] $Pattern)
    try { & $Body }
    catch
    {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "Exception did not match <$Pattern>: $($_.Exception.Message)"
    }
    throw "Expected an exception matching <$Pattern>."
}

function Complete-Tests
{
    Write-Host "$script:TestCount tests, $script:FailureCount failures"
    if ($script:FailureCount -gt 0) { exit 1 }
}
```

Create `scripts/tests/Run-Tests.ps1` so each suite gets a fresh process:

```powershell
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$pwshPath = (Get-Process -Id $PID).Path
$testFiles = Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.Tests.ps1" | Sort-Object Name
if ($testFiles.Count -eq 0) { throw "No test files were found." }

$failed = 0
foreach ($testFile in $testFiles)
{
    & $pwshPath -NoProfile -File $testFile.FullName
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
if ($failed -gt 0) { exit 1 }
```

- [ ] **Step 2: Write failing move-safe path and Unity-root tests**

Create `scripts/tests/UnityLinkMaintenance.Tests.ps1`, dot-source the harness, import the module, and add tests that
build a temporary tree shaped like `<Unity>/FilePackages/unity-links`:

```powershell
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "TestHarness.ps1")
$modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) "UnityLinkMaintenance.psm1"
Import-Module $modulePath -Force

Test-Case "repository layout follows its supplied root" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) "moved-unity-links"
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $root
    Assert-Equal (Join-Path $root "codex-tweak") $layout.TweakRoot
    Assert-Equal (Join-Path $root "unity-package") $layout.PackageRoot
}

Test-Case "finds Unity above nested FilePackages repository" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $repo = Join-Path $root "FilePackages/unity-links/scripts/tests"
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "Assets") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "Packages") | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "ProjectSettings") | Out-Null
        Set-Content -LiteralPath (Join-Path $root "Packages/manifest.json") -Value '{"dependencies":{}}'
        Set-Content -LiteralPath (Join-Path $root "ProjectSettings/ProjectVersion.txt") -Value "m_EditorVersion: 2022.3.23f1"
        Assert-Equal (Resolve-NormalizedPath $root) (Find-UnityProjectRoot -StartPath $repo)
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case "computes the final portable package value" {
    $project = "D:\workspace\sgproj"
    $package = "D:\workspace\sgproj\FilePackages\unity-links\unity-package"
    Assert-Equal "file:../FilePackages/unity-links/unity-package" `
        (Get-UnityPackageManifestValue -UnityProjectRoot $project -PackageRoot $package)
}

Test-Case "rejects a directory without every Unity marker" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        New-Item -ItemType Directory -Path (Join-Path $root "Assets") -Force | Out-Null
        Assert-Throws { Find-UnityProjectRoot -StartPath $root } "Unity project"
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Complete-Tests
```

- [ ] **Step 3: Run the suite and observe the missing module failure**

Run:

```powershell
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
```

Expected: FAIL because `UnityLinkMaintenance.psm1` and its exported functions do not exist.

- [ ] **Step 4: Implement the path and discovery functions**

Create `scripts/UnityLinkMaintenance.psm1` with strict mode, then implement the tested functions. Use
`[System.IO.Path]::GetRelativePath` from the Unity `Packages` directory, not from the project root:

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-NormalizedPath
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [string] $BasePath = (Get-Location).Path)

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $BasePath $Path }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -eq $root.Length) { return $fullPath }
    return $fullPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathEqual
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Left, [Parameter(Mandatory)] [string] $Right)
    return [string]::Equals(
        (Resolve-NormalizedPath $Left),
        (Resolve-NormalizedPath $Right),
        [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-UnityLinkRepositoryLayout
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepositoryRoot)

    $root = Resolve-NormalizedPath $RepositoryRoot
    return [pscustomobject]@{
        RepositoryRoot = $root
        TweakRoot = Join-Path $root "codex-tweak"
        TweakManifest = Join-Path $root "codex-tweak/manifest.json"
        PackageRoot = Join-Path $root "unity-package"
        PackageManifest = Join-Path $root "unity-package/package.json"
    }
}

function Test-UnityProjectRoot
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $root = Resolve-NormalizedPath $Path
    return (Test-Path -LiteralPath (Join-Path $root "Assets") -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $root "Packages/manifest.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $root "ProjectSettings/ProjectVersion.txt") -PathType Leaf)
}

function Find-UnityProjectRoot
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StartPath)

    $current = Resolve-NormalizedPath $StartPath
    if (Test-Path -LiteralPath $current -PathType Leaf) { $current = Split-Path $current -Parent }
    while ($current)
    {
        if (Test-UnityProjectRoot $current) { return $current }
        $parent = Split-Path $current -Parent
        if (!$parent -or (Test-PathEqual $parent $current)) { break }
        $current = $parent
    }
    throw "No Unity project containing Assets, Packages/manifest.json, and ProjectSettings/ProjectVersion.txt was found above '$StartPath'."
}

function Get-UnityPackageManifestValue
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UnityProjectRoot,
        [Parameter(Mandatory)] [string] $PackageRoot)

    $packagesRoot = Join-Path (Resolve-NormalizedPath $UnityProjectRoot) "Packages"
    $relative = [System.IO.Path]::GetRelativePath($packagesRoot, (Resolve-NormalizedPath $PackageRoot))
    return "file:$($relative.Replace('\', '/'))"
}
```

Export the six public functions with `Export-ModuleMember`.

- [ ] **Step 5: Run tests and commit Task 1**

Run the suite twice from different current directories to prove there is no current-directory dependency:

```powershell
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
Push-Location D:\workspace\sgproj
try { pwsh -NoProfile -File D:\workspace\codex-tweaks\unity-links\scripts\tests\Run-Tests.ps1 }
finally { Pop-Location }
git status --short
```

Expected: all four tests PASS both times. Commit only Task 1 files:

```powershell
git add scripts/UnityLinkMaintenance.psm1 scripts/tests
git commit -m "test: add maintenance path foundation"
```

---

### Task 2: Targeted Unity Manifest Editing and Installer Entry Point

**Files:**

- Modify: `scripts/UnityLinkMaintenance.psm1`
- Modify: `scripts/tests/UnityLinkMaintenance.Tests.ps1`
- Create: `Install-UnityPackage.ps1`

**Interfaces:**

- `Update-UnityManifestText([string] $Text, [string] $DependencyValue)` -> `{ Changed, Text }`.
- `Install-UnityPackage.ps1 [-UnityProject <path>] [-CheckOnly]` -> reports expected value and state.

- [ ] **Step 1: Add failing manifest preservation tests**

Before `Complete-Tests`, add cases for CRLF update, LF insertion, no-op, invalid JSON, and unrelated-property
preservation. Use exact string comparisons, not reparsed object comparisons:

```powershell
Test-Case "updates only the dependency value and preserves CRLF" {
    $before = "{`r`n  `"name`": `"keep`",`r`n  `"dependencies`": {`r`n    `"a`": `"1`",`r`n    `"com.kpk.codex-unity-link`": `"file:old`"`r`n  }`r`n}`r`n"
    $expected = $before.Replace('"file:old"', '"file:../FilePackages/unity-links/unity-package"')
    $result = Update-UnityManifestText -Text $before `
        -DependencyValue "file:../FilePackages/unity-links/unity-package"
    Assert-True $result.Changed
    Assert-Equal $expected $result.Text
}

Test-Case "inserts the dependency and preserves LF plus unrelated text" {
    $before = "{`n  `"name`": `"keep`",`n  `"dependencies`": {`n    `"a`": `"1`"`n  }`n}`n"
    $expected = "{`n  `"name`": `"keep`",`n  `"dependencies`": {`n    `"a`": `"1`",`n    `"com.kpk.codex-unity-link`": `"file:../pkg`"`n  }`n}`n"
    $result = Update-UnityManifestText -Text $before -DependencyValue "file:../pkg"
    Assert-True $result.Changed
    Assert-Equal $expected $result.Text
}

Test-Case "returns the original manifest for an exact no-op" {
    $before = "{`n  `"dependencies`": {`n    `"com.kpk.codex-unity-link`": `"file:../pkg`"`n  }`n}`n"
    $result = Update-UnityManifestText -Text $before -DependencyValue "file:../pkg"
    Assert-True (!$result.Changed)
    Assert-Equal $before $result.Text
}

Test-Case "rejects invalid JSON before editing" {
    Assert-Throws { Update-UnityManifestText -Text '{"dependencies":{' -DependencyValue "file:../pkg" } "valid JSON"
}
```

- [ ] **Step 2: Add a failing `-CheckOnly` filesystem test**

Create a temporary Unity project and invoke the not-yet-created root script. Hash `manifest.json` before and after:

```powershell
Test-Case "Unity CheckOnly does not mutate the manifest" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        New-Item -ItemType Directory -Path (Join-Path $root "Assets"), (Join-Path $root "Packages"), `
            (Join-Path $root "ProjectSettings") -Force | Out-Null
        $manifest = Join-Path $root "Packages/manifest.json"
        [System.IO.File]::WriteAllText($manifest, "{`r`n  `"dependencies`": {}`r`n}`r`n")
        [System.IO.File]::WriteAllText((Join-Path $root "ProjectSettings/ProjectVersion.txt"), "2022.3.23f1")
        $before = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
        $entryPoint = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) `
            "Install-UnityPackage.ps1"
        $pwshPath = (Get-Process -Id $PID).Path
        & $pwshPath -NoProfile -File $entryPoint -UnityProject $root -CheckOnly | Out-Null
        $entryPointExitCode = $LASTEXITCODE
        Assert-Equal 0 $entryPointExitCode
        Assert-Equal $before (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
```

Run the suite. Expected: FAIL because the editing function and entry point are missing.

- [ ] **Step 3: Implement targeted manifest editing**

Add `Update-UnityManifestText` to the module. The function must parse before editing, locate only the top-level
`dependencies` object, JSON-escape the new string with `ConvertTo-Json`, preserve the original newline sequence and
property indentation, parse the result, and return the original text on an exact no-op:

```powershell
function Update-UnityManifestText
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [string] $DependencyValue)

    try { $document = $Text | ConvertFrom-Json -AsHashtable }
    catch { throw "Packages/manifest.json is not valid JSON: $($_.Exception.Message)" }
    if (!$document.ContainsKey("dependencies") -or $document.dependencies -isnot [System.Collections.IDictionary])
    {
        throw "Packages/manifest.json does not contain a dependencies object."
    }

    $key = "com.kpk.codex-unity-link"
    if ($document.dependencies.Contains($key) -and $document.dependencies[$key] -ceq $DependencyValue)
    {
        return [pscustomobject]@{ Changed = $false; Text = $Text }
    }

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $dependenciesPattern = '(?s)(?<open>"dependencies"\s*:\s*\{)(?<body>(?:[^{}"]|"(?:\\.|[^"\\])*")*)(?<close>\})'
    $dependenciesMatch = [regex]::Match($Text, $dependenciesPattern)
    if (!$dependenciesMatch.Success) { throw "Could not safely locate the dependencies object." }

    $body = $dependenciesMatch.Groups["body"].Value
    $propertyPattern = '(?m)(?<prefix>^[ \t]*"com\.kpk\.codex-unity-link"[ \t]*:[ \t]*)(?<value>"(?:\\.|[^"\\])*")(?<suffix>[ \t]*,?)'
    $jsonValue = ConvertTo-Json -InputObject $DependencyValue -Compress
    $propertyMatch = [regex]::Match($body, $propertyPattern)
    if ($propertyMatch.Success)
    {
        $updatedBody = $body.Substring(0, $propertyMatch.Index) +
            $propertyMatch.Groups["prefix"].Value + $jsonValue + $propertyMatch.Groups["suffix"].Value +
            $body.Substring($propertyMatch.Index + $propertyMatch.Length)
    }
    else
    {
        $existingIndent = [regex]::Match($body, '(?m)^(?<indent>[ \t]+)"')
        $objectLine = $Text.Substring(0, $dependenciesMatch.Groups["open"].Index)
        $objectIndentMatch = [regex]::Match($objectLine, '(?m)(?<indent>^[ \t]*)[^\r\n]*$')
        $objectIndent = $objectIndentMatch.Groups["indent"].Value
        $propertyIndent = if ($existingIndent.Success) { $existingIndent.Groups["indent"].Value } else { "$objectIndent  " }
        $jsonKey = ConvertTo-Json -InputObject $key -Compress
        $property = "$propertyIndent$jsonKey`: $jsonValue"
        $core = $body.TrimEnd("`r", "`n", " ", "`t")
        $trailing = $body.Substring($core.Length)
        if ($core.Length -eq 0)
        {
            $updatedBody = "$newline$property$newline$objectIndent"
        }
        else
        {
            $updatedBody = "$core,$newline$property$trailing"
        }
    }

    $updatedText = $Text.Substring(0, $dependenciesMatch.Groups["body"].Index) + $updatedBody +
        $Text.Substring($dependenciesMatch.Groups["body"].Index + $body.Length)
    try { $updatedDocument = $updatedText | ConvertFrom-Json -AsHashtable }
    catch { throw "The proposed manifest edit was not valid JSON: $($_.Exception.Message)" }
    if ($updatedDocument.dependencies[$key] -cne $DependencyValue)
    {
        throw "The proposed manifest edit did not produce the expected dependency value."
    }
    return [pscustomobject]@{ Changed = $true; Text = $updatedText }
}
```

Export the new function. If the LF/CRLF tests reveal an insertion-boundary defect, fix the function, not the
fixtures, and add the failing shape as a regression test.

- [ ] **Step 4: Implement `Install-UnityPackage.ps1` with rollback**

Create the root script with `[CmdletBinding()]`, `-UnityProject`, and `-CheckOnly`. Resolve its own repository with
`$PSScriptRoot`, validate `unity-package/package.json`, resolve the explicit Unity root or call
`Find-UnityProjectRoot -StartPath $PSScriptRoot`, then compute and report the state:

```powershell
[CmdletBinding()]
param([string] $UnityProject, [switch] $CheckOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "scripts/UnityLinkMaintenance.psm1") -Force

try
{
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $PSScriptRoot
    if (!(Test-Path -LiteralPath $layout.PackageManifest -PathType Leaf))
    {
        throw "Unity package manifest not found: $($layout.PackageManifest)"
    }
    $projectRoot = if ($UnityProject) { Resolve-NormalizedPath $UnityProject } else {
        Find-UnityProjectRoot -StartPath $PSScriptRoot
    }
    if (!(Test-UnityProjectRoot $projectRoot)) { throw "Not a valid Unity project: $projectRoot" }

    $manifestPath = Join-Path $projectRoot "Packages/manifest.json"
    $expectedValue = Get-UnityPackageManifestValue -UnityProjectRoot $projectRoot -PackageRoot $layout.PackageRoot
    $originalBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $originalText = $encoding.GetString($originalBytes)
    $edit = Update-UnityManifestText -Text $originalText -DependencyValue $expectedValue
    $status = if ($edit.Changed) { "UpdateRequired" } else { "Current" }
    Write-Host "Status: $status"
    Write-Host "Unity project: $projectRoot"
    Write-Host "Expected dependency: $expectedValue"
    if ($CheckOnly -or !$edit.Changed) { exit 0 }

    try
    {
        [System.IO.File]::WriteAllText($manifestPath, $edit.Text, $encoding)
        $verified = [System.IO.File]::ReadAllText($manifestPath, $encoding) | ConvertFrom-Json -AsHashtable
        if ($verified.dependencies["com.kpk.codex-unity-link"] -cne $expectedValue)
        {
            throw "Post-write dependency verification failed."
        }
    }
    catch
    {
        [System.IO.File]::WriteAllBytes($manifestPath, $originalBytes)
        throw
    }
    Write-Host "Updated only com.kpk.codex-unity-link in $manifestPath"
    Write-Host "Unity will maintain Packages/packages-lock.json."
    exit 0
}
catch
{
    Write-Error $_
    exit 1
}
```

Before accepting this implementation, add a UTF-8 BOM fixture if the real manifest contains a BOM. Preserve it by
detecting the first three bytes and selecting `[System.Text.UTF8Encoding]::new($true)`; do not silently strip it.

- [ ] **Step 5: Run tests, inspect the real project in check-only mode, and commit**

Run:

```powershell
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -UnityProject D:\workspace\sgproj -CheckOnly
git diff --check
git status --short
```

Expected: tests PASS; the live check reports the dependency it would use from the old repository without changing
the manifest hash or `packages-lock.json`. Commit:

```powershell
git add Install-UnityPackage.ps1 scripts/UnityLinkMaintenance.psm1 scripts/tests/UnityLinkMaintenance.Tests.ps1
git commit -m "feat: maintain Unity package reference"
```

---

### Task 3: Appx Selection, Mirror Derivation, and Codex Maintenance Classification

**Files:**

- Modify: `scripts/UnityLinkMaintenance.psm1`
- Modify: `scripts/tests/UnityLinkMaintenance.Tests.ps1`

**Interfaces:**

- `Select-LatestCodexPackage([object[]] $Packages)` -> highest `[version]` package.
- `Get-CodexAppLayout([object] $Package, [string] $LocalAppData)` -> official/mirror/ASAR paths.
- `Test-PathInside([string] $Path, [string] $Root)` -> boundary-safe containment.
- `Get-CodexMaintenanceState([object] $AppLayout, [object] $CodexState, [string] $StatusText,
  [string] $LinkStatus, [string[]] $RunningExecutablePaths)` -> status plus injection/link/process booleans.

- [ ] **Step 1: Add failing Appx selection and layout tests**

Add fixtures with unordered versions and assert the latest package and exact version-specific mirror:

```powershell
Test-Case "selects the highest installed Codex Appx version" {
    $packages = @(
        [pscustomobject]@{ Version = "26.715.10079.0"; PackageFullName = "old"; InstallLocation = "C:\old" },
        [pscustomobject]@{ Version = "26.721.3996.0"; PackageFullName = "new"; InstallLocation = "C:\new" })
    Assert-Equal "new" (Select-LatestCodexPackage -Packages $packages).PackageFullName
}

Test-Case "derives official and version-specific mirror paths" {
    $package = [pscustomobject]@{
        Version = "26.721.3996.0"
        PackageFullName = "OpenAI.Codex_26.721.3996.0_x64__2p2nqsd0c76g0"
        InstallLocation = "C:\Program Files\WindowsApps\OpenAI.Codex_26.721.3996.0_x64__2p2nqsd0c76g0"
    }
    $layout = Get-CodexAppLayout -Package $package -LocalAppData "C:\Users\Test\AppData\Local"
    Assert-Equal (Join-Path $package.InstallLocation "app") $layout.OfficialAppRoot
    Assert-Equal "C:\Users\Test\AppData\Local\codex-plusplus\store-apps\$($package.PackageFullName)\app" `
        $layout.MirrorAppRoot
}
```

- [ ] **Step 2: Add failing state classification tests**

Cover all four public statuses. The stale state test must remain `Blocked` only when the executable lies inside the
exact target mirror, not when official Codex is running:

```powershell
Test-Case "classifies current injection and link" {
    $layout = [pscustomobject]@{ MirrorAppRoot = "C:\mirror\app" }
    $state = [pscustomobject]@{ appRoot = "C:\mirror\app" }
    $result = Get-CodexMaintenanceState -AppLayout $layout -CodexState $state `
        -StatusText "Current ASAR matches patched" -LinkStatus "Current" -RunningExecutablePaths @()
    Assert-Equal "Current" $result.Status
}

Test-Case "classifies stale recorded mirror as InjectionRequired" {
    $layout = [pscustomobject]@{ MirrorAppRoot = "C:\new\app" }
    $state = [pscustomobject]@{ appRoot = "C:\old\app" }
    $result = Get-CodexMaintenanceState -AppLayout $layout -CodexState $state `
        -StatusText "Current ASAR matches patched" -LinkStatus "Current" `
        -RunningExecutablePaths @("C:\Program Files\WindowsApps\OpenAI.Codex\app\Codex.exe")
    Assert-Equal "InjectionRequired" $result.Status
}

Test-Case "classifies a missing junction after current injection as LinkRequired" {
    $layout = [pscustomobject]@{ MirrorAppRoot = "C:\mirror\app" }
    $state = [pscustomobject]@{ appRoot = "C:\mirror\app" }
    $result = Get-CodexMaintenanceState -AppLayout $layout -CodexState $state `
        -StatusText "ASAR matches patched" -LinkStatus "Missing" -RunningExecutablePaths @()
    Assert-Equal "LinkRequired" $result.Status
}

Test-Case "blocks stale injection while the exact target mirror is running" {
    $layout = [pscustomobject]@{ MirrorAppRoot = "C:\new\app" }
    $state = [pscustomobject]@{ appRoot = "C:\old\app" }
    $result = Get-CodexMaintenanceState -AppLayout $layout -CodexState $state `
        -StatusText "ASAR differs" -LinkStatus "Current" `
        -RunningExecutablePaths @("C:\new\app\Codex.exe")
    Assert-Equal "Blocked" $result.Status
    Assert-True $result.TargetMirrorRunning
}

Test-Case "blocks an unsafe real directory at the tweak path" {
    $layout = [pscustomobject]@{ MirrorAppRoot = "C:\mirror\app" }
    $state = [pscustomobject]@{ appRoot = "C:\mirror\app" }
    $result = Get-CodexMaintenanceState -AppLayout $layout -CodexState $state `
        -StatusText "ASAR matches patched" -LinkStatus "Unsafe" -RunningExecutablePaths @()
    Assert-Equal "Blocked" $result.Status
}
```

Run the suite. Expected: FAIL on the missing Appx and state functions.

- [ ] **Step 3: Implement Appx selection and mirror layout**

Add these functions to the module and export them:

```powershell
function Select-LatestCodexPackage
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Packages)
    if ($Packages.Count -eq 0) { throw "OpenAI.Codex is not installed for the current user." }
    return $Packages | Sort-Object { [version] $_.Version } -Descending | Select-Object -First 1
}

function Get-CodexAppLayout
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $Package, [Parameter(Mandatory)] [string] $LocalAppData)

    $officialAppRoot = Join-Path (Resolve-NormalizedPath $Package.InstallLocation) "app"
    $mirrorAppRoot = Join-Path (Resolve-NormalizedPath $LocalAppData) `
        "codex-plusplus/store-apps/$($Package.PackageFullName)/app"
    return [pscustomobject]@{
        PackageFullName = [string] $Package.PackageFullName
        PackageVersion = [version] $Package.Version
        OfficialAppRoot = $officialAppRoot
        OfficialAsar = Join-Path $officialAppRoot "resources/app.asar"
        MirrorAppRoot = $mirrorAppRoot
        MirrorAsar = Join-Path $mirrorAppRoot "resources/app.asar"
    }
}

function Test-PathInside
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Root)

    $candidate = Resolve-NormalizedPath $Path
    $normalizedRoot = Resolve-NormalizedPath $Root
    if (Test-PathEqual $candidate $normalizedRoot) { return $true }
    return $candidate.StartsWith(
        "$normalizedRoot$([System.IO.Path]::DirectorySeparatorChar)",
        [System.StringComparison]::OrdinalIgnoreCase)
}
```

- [ ] **Step 4: Implement maintenance classification as a pure function**

Add and export this function. It must not query processes, files, or commands itself:

```powershell
function Get-CodexMaintenanceState
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $AppLayout,
        [AllowNull()] [object] $CodexState,
        [AllowEmptyString()] [string] $StatusText,
        [Parameter(Mandatory)] [ValidateSet("Current", "Missing", "WrongTarget", "Unsafe")] [string] $LinkStatus,
        [string[]] $RunningExecutablePaths = @())

    $stateMatches = $null -ne $CodexState -and
        $CodexState.PSObject.Properties.Name -contains "appRoot" -and
        (Test-PathEqual ([string] $CodexState.appRoot) $AppLayout.MirrorAppRoot)
    $hashMatches = $StatusText -match '(?i)matches patched'
    $injectionRequired = !$stateMatches -or !$hashMatches
    $targetMirrorRunning = @($RunningExecutablePaths | Where-Object {
        $_ -and (Test-PathInside -Path $_ -Root $AppLayout.MirrorAppRoot)
    }).Count -gt 0

    $status = if ($LinkStatus -eq "Unsafe") { "Blocked" }
        elseif ($injectionRequired -and $targetMirrorRunning) { "Blocked" }
        elseif ($injectionRequired) { "InjectionRequired" }
        elseif ($LinkStatus -ne "Current") { "LinkRequired" }
        else { "Current" }

    return [pscustomobject]@{
        Status = $status
        InjectionRequired = $injectionRequired
        LinkRequired = $LinkStatus -ne "Current"
        TargetMirrorRunning = $targetMirrorRunning
        UnsafeLink = $LinkStatus -eq "Unsafe"
    }
}
```

- [ ] **Step 5: Run tests and commit Task 3**

Run:

```powershell
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
git diff --check
git status --short
```

Expected: all path, manifest, Appx, and classification tests PASS. Commit:

```powershell
git add scripts/UnityLinkMaintenance.psm1 scripts/tests/UnityLinkMaintenance.Tests.ps1
git commit -m "feat: classify Codex maintenance state"
```

---

### Task 4: Safe Tweak Junction and Codex++ Injection Entry Point

**Files:**

- Modify: `scripts/UnityLinkMaintenance.psm1`
- Modify: `scripts/tests/UnityLinkMaintenance.Tests.ps1`
- Create: `Inject-CodexPlusPlus.ps1`

**Interfaces:**

- `Get-TweakLinkState([string] $LinkPath, [string] $ExpectedTarget)` -> Current/Missing/WrongTarget/Unsafe.
- `Set-TweakJunction([string] $LinkPath, [string] $ExpectedTarget)` -> creates or safely corrects one junction.
- `Inject-CodexPlusPlus.ps1 [-CheckOnly]` -> detects, optionally repairs, links, verifies, and prompts.

- [ ] **Step 1: Add failing real-filesystem junction safety tests**

Use a temporary parent on the same NTFS volume. Assert that an ordinary directory is classified `Unsafe` and remains
untouched; then create a wrong junction, correct it, and verify the target:

```powershell
Test-Case "refuses to replace a real tweak directory" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $link = Join-Path $root "live/com.kpk.unity-asset-links"
        $target = Join-Path $root "source/codex-tweak"
        New-Item -ItemType Directory -Path $link, $target -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $target "manifest.json"), '{}')
        $state = Get-TweakLinkState -LinkPath $link -ExpectedTarget $target
        Assert-Equal "Unsafe" $state.Status
        Assert-Throws { Set-TweakJunction -LinkPath $link -ExpectedTarget $target } "real directory"
        Assert-True (Test-Path -LiteralPath $link -PathType Container)
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case "corrects only a wrong junction target" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $link = Join-Path $root "live/com.kpk.unity-asset-links"
        $oldTarget = Join-Path $root "old/codex-tweak"
        $newTarget = Join-Path $root "new/codex-tweak"
        New-Item -ItemType Directory -Path (Split-Path $link -Parent), $oldTarget, $newTarget -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $newTarget "manifest.json"), '{}')
        New-Item -ItemType Junction -Path $link -Target $oldTarget | Out-Null
        Assert-Equal "WrongTarget" (Get-TweakLinkState $link $newTarget).Status
        Set-TweakJunction -LinkPath $link -ExpectedTarget $newTarget | Out-Null
        Assert-Equal "Current" (Get-TweakLinkState $link $newTarget).Status
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case "recognizes and repairs a junction whose old target disappeared" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $link = Join-Path $root "live/com.kpk.unity-asset-links"
        $oldTarget = Join-Path $root "old/codex-tweak"
        $newTarget = Join-Path $root "new/codex-tweak"
        New-Item -ItemType Directory -Path (Split-Path $link -Parent), $oldTarget, $newTarget -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $newTarget "manifest.json"), '{}')
        New-Item -ItemType Junction -Path $link -Target $oldTarget | Out-Null
        Remove-Item -LiteralPath $oldTarget -Recurse -Force
        Assert-Equal "WrongTarget" (Get-TweakLinkState $link $newTarget).Status
        Set-TweakJunction -LinkPath $link -ExpectedTarget $newTarget | Out-Null
        Assert-Equal "Current" (Get-TweakLinkState $link $newTarget).Status
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
```

- [ ] **Step 2: Implement safe link inspection and replacement**

Add and export these functions. Resolve relative link targets against the link parent. Use non-recursive
`Remove-Item` only after `Get-TweakLinkState` proves that the exact item is a reparse point:

```powershell
function Get-TweakLinkState
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LinkPath, [Parameter(Mandatory)] [string] $ExpectedTarget)

    $normalizedLink = Resolve-NormalizedPath $LinkPath
    $expected = Resolve-NormalizedPath $ExpectedTarget
    $item = Get-Item -LiteralPath $normalizedLink -Force -ErrorAction SilentlyContinue
    if ($null -eq $item)
    {
        return [pscustomobject]@{ Status = "Missing"; LinkPath = $normalizedLink; Target = $null }
    }
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (!$isReparsePoint -or !$item.LinkType)
    {
        return [pscustomobject]@{ Status = "Unsafe"; LinkPath = $normalizedLink; Target = $null }
    }
    $rawTarget = @($item.Target)[0]
    $target = if ([System.IO.Path]::IsPathRooted($rawTarget)) {
        Resolve-NormalizedPath $rawTarget
    } else {
        Resolve-NormalizedPath $rawTarget (Split-Path $normalizedLink -Parent)
    }
    $status = if (Test-PathEqual $target $expected) { "Current" } else { "WrongTarget" }
    return [pscustomobject]@{ Status = $status; LinkPath = $normalizedLink; Target = $target }
}

function Set-TweakJunction
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LinkPath, [Parameter(Mandatory)] [string] $ExpectedTarget)

    $target = Resolve-NormalizedPath $ExpectedTarget
    if (!(Test-Path -LiteralPath $target -PathType Container)) { throw "Tweak source directory not found: $target" }
    if (!(Test-Path -LiteralPath (Join-Path $target "manifest.json") -PathType Leaf))
    {
        throw "Tweak manifest not found below: $target"
    }
    $state = Get-TweakLinkState -LinkPath $LinkPath -ExpectedTarget $target
    if ($state.Status -eq "Current") { return $false }
    if ($state.Status -eq "Unsafe") { throw "The live tweak path is a real directory and will not be replaced: $LinkPath" }

    $parent = Split-Path (Resolve-NormalizedPath $LinkPath) -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $previousTarget = $state.Target
    if ($state.Status -eq "WrongTarget") { Remove-Item -LiteralPath $state.LinkPath -Force }
    try
    {
        New-Item -ItemType Junction -Path $state.LinkPath -Target $target | Out-Null
    }
    catch
    {
        $linkAfterFailure = Get-Item -LiteralPath $state.LinkPath -Force -ErrorAction SilentlyContinue
        if ($previousTarget -and (Test-Path -LiteralPath $previousTarget -PathType Container) -and
            $null -eq $linkAfterFailure)
        {
            New-Item -ItemType Junction -Path $state.LinkPath -Target $previousTarget | Out-Null
        }
        throw
    }
    $verified = Get-TweakLinkState -LinkPath $state.LinkPath -ExpectedTarget $target
    if ($verified.Status -ne "Current") { throw "Tweak junction verification failed: $($verified.Status)" }
    return $true
}
```

- [ ] **Step 3: Add the root script and test `-CheckOnly` with injected discovery data**

Keep production parameters limited to `-CheckOnly`. For dependency-free testing, put mutation ordering in a pure
helper `Get-CodexMaintenanceState`; test that helper as Task 3 does, then run the real script's `-CheckOnly` against
the current machine while snapshotting the link item and `state.json` hashes. Do not mock Appx globally.

Create `Inject-CodexPlusPlus.ps1` with local helpers:

```powershell
function Invoke-CodexPlusPlus
{
    param([System.Management.Automation.CommandInfo] $Command, [string[]] $Arguments)
    $output = & $Command.Source @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "codexplusplus $($Arguments[0]) failed:`n$output" }
    return $output.TrimEnd()
}

function Read-CodexPlusPlusState
{
    param([string] $StatePath)
    if (!(Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json }
    catch { throw "Codex++ state is invalid JSON: $StatePath" }
}

function Get-CodexExecutablePaths
{
    return @(Get-CimInstance Win32_Process -Filter "Name = 'Codex.exe'" -ErrorAction SilentlyContinue |
        Where-Object ExecutablePath | Select-Object -ExpandProperty ExecutablePath -Unique)
}
```

The main body must perform this exact sequence:

1. Resolve `$PSScriptRoot`, import the module, and validate `codex-tweak/manifest.json`.
2. Resolve `Get-Command codexplusplus`; parse `codexplusplus --version` with `\d+\.\d+\.\d+`; require
   `[version]1.0.0` or newer.
3. Select the latest `Get-AppxPackage -Name OpenAI.Codex` result and build its layout with `$env:LOCALAPPDATA`.
4. Require the official `resources/app.asar`; never write to it.
5. Use `%APPDATA%\codex-plusplus\state.json` and
   `%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links`.
6. Capture `codexplusplus status`, current link state, and running executable paths; classify once.
7. Print `Status: <value>`, the Appx package, official root, mirror root, and expected tweak target.
8. If `-CheckOnly`, exit without calling `repair`, `Set-TweakJunction`, or any write API. Return nonzero only for
   `Blocked` or a discovery error.
9. If `Blocked`, explain whether the cause is the running target mirror or unsafe real directory and exit nonzero.
10. If injection is required, call exactly:
    `Invoke-CodexPlusPlus $command @("repair", "--force", "--app", $appLayout.OfficialAppRoot)`.
11. Re-read state and status and require injection to be current before touching the link.
12. Call `Set-TweakJunction` if the link is missing or wrong; never call it for `Unsafe`.
13. Re-read state/status/link/process data and require final classification `Current`.
14. If a Codex executable is outside the patched mirror, or the link changed while any Codex process is running,
    print a yellow, prominent manual restart prompt. Never call `Stop-Process`, `Start-Process`, taskkill, or UI tools.

Use one local context reader so pre-check, post-repair, and final verification execute the same observations:

```powershell
function Get-LiveMaintenanceContext
{
    param(
        [System.Management.Automation.CommandInfo] $Command,
        [object] $AppLayout,
        [string] $StatePath,
        [string] $LiveLink,
        [string] $ExpectedTarget)

    $state = Read-CodexPlusPlusState $StatePath
    $statusText = Invoke-CodexPlusPlus $Command @("status")
    $link = Get-TweakLinkState -LinkPath $LiveLink -ExpectedTarget $ExpectedTarget
    $runningPaths = Get-CodexExecutablePaths
    $maintenance = Get-CodexMaintenanceState -AppLayout $AppLayout -CodexState $state `
        -StatusText $statusText -LinkStatus $link.Status -RunningExecutablePaths $runningPaths
    return [pscustomobject]@{
        State = $state
        StatusText = $statusText
        Link = $link
        RunningPaths = $runningPaths
        Maintenance = $maintenance
    }
}
```

After completing steps 1-7 above, use this exact mutation/verification order inside the entry point's `try` block:

```powershell
$context = Get-LiveMaintenanceContext $codexPlusPlus $appLayout $statePath $liveLink $repository.TweakRoot
Write-Host "Status: $($context.Maintenance.Status)"
if ($CheckOnly)
{
    if ($context.Maintenance.Status -eq "Blocked") { exit 2 }
    exit 0
}
if ($context.Maintenance.Status -eq "Blocked") { throw "Maintenance is blocked; no changes were made." }

if ($context.Maintenance.InjectionRequired)
{
    Invoke-CodexPlusPlus $codexPlusPlus @("repair", "--force", "--app", $appLayout.OfficialAppRoot) | Write-Host
}

$afterRepair = Get-LiveMaintenanceContext $codexPlusPlus $appLayout $statePath $liveLink $repository.TweakRoot
if ($afterRepair.Maintenance.InjectionRequired)
{
    throw "Codex++ still does not match the latest Appx mirror after repair."
}
$linkChanged = Set-TweakJunction -LinkPath $liveLink -ExpectedTarget $repository.TweakRoot
$final = Get-LiveMaintenanceContext $codexPlusPlus $appLayout $statePath $liveLink $repository.TweakRoot
if ($final.Maintenance.Status -ne "Current")
{
    throw "Final Codex++ maintenance verification failed: $($final.Maintenance.Status)"
}

$runningOutsideMirror = @($final.RunningPaths | Where-Object {
    !(Test-PathInside -Path $_ -Root $appLayout.MirrorAppRoot)
})
if ($runningOutsideMirror.Count -gt 0 -or ($linkChanged -and $final.RunningPaths.Count -gt 0))
{
    Write-Host "ACTION REQUIRED: close Codex manually, then launch the Codex++ shortcut." -ForegroundColor Yellow
    Write-Host "This script did not close or restart Codex." -ForegroundColor Yellow
}
```

Wrap this block in the same `try/catch` and explicit exit pattern used by the Unity entry point. The production script
must contain no `TODO`, `FIXME`, or incomplete query/re-read comments.

- [ ] **Step 4: Prove real `-CheckOnly` does not mutate state or link**

Before and after the check, record:

- SHA-256 of `%APPDATA%\codex-plusplus\state.json` if present.
- Link type and target of `%APPDATA%\codex-plusplus\tweaks\com.kpk.unity-asset-links`.
- SHA-256 of the current mirror `resources/app.asar` if present.

Run:

```powershell
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
```

Expected: it reports the latest Appx and likely `InjectionRequired` after the Codex update; all three snapshots are
identical. `Blocked` is acceptable only if the exact new mirror is running or the live tweak path is an unsafe real
directory. Do not run the mutating mode in this task.

- [ ] **Step 5: Run all tests, static safety scans, and commit Task 4**

Run:

```powershell
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
rg -n "Stop-Process|Start-Process|taskkill|codexplusplus debug|Remove-Item.*-Recurse" `
    Inject-CodexPlusPlus.ps1 scripts/UnityLinkMaintenance.psm1
rg -n "TODO|FIXME|Resolve and validate|Re-read" Inject-CodexPlusPlus.ps1 scripts
git diff --check
```

Expected: tests PASS; the first scan finds none of the forbidden calls; the incomplete-code scan finds nothing; only
the exact non-recursive link removal exists. Commit:

```powershell
git add Inject-CodexPlusPlus.ps1 scripts/UnityLinkMaintenance.psm1 scripts/tests/UnityLinkMaintenance.Tests.ps1
git commit -m "feat: maintain Codex++ injection and tweak link"
```

---

### Task 5: Pinned Codex++ 1.0.0 Installer

**Files:**

- Modify: `scripts/UnityLinkMaintenance.psm1`
- Modify: `scripts/tests/UnityLinkMaintenance.Tests.ps1`
- Create: `Install-CodexPlusPlus.ps1`

**Interfaces:**

- `Get-CodexPlusPlusInstallState([version] $InstalledVersion, [int] $NodeMajor, [bool] $HasNpm,
  [bool] $TargetMirrorRunning)` -> `Current`, `InstallRequired`, or `Blocked` with a reason.
- `Test-CodexPlusPlusSourceLayout([string] $SourceRoot)` -> validates version 1.0.0 and required build inputs.
- `Get-CodexPlusPlusSourceSwapState([bool] $SourceExists, [bool] $PreviousExists)` -> safe swap decision.
- `Install-CodexPlusPlus.ps1 [-CheckOnly]` -> pinned source bootstrap, initial injection, then tweak linking.

- [ ] **Step 1: Add failing install-state and source-layout tests**

Add tests for a missing CLI, compatible 1.0.0, a newer compatible CLI that must not be downgraded, missing Node/npm,
the target mirror running, a valid extracted source fixture, and a package version mismatch:

```powershell
Test-Case "requires pinned install when Codex++ is missing" {
    $state = Get-CodexPlusPlusInstallState -InstalledVersion $null -NodeMajor 22 -HasNpm $true `
        -TargetMirrorRunning $false
    Assert-Equal "InstallRequired" $state.Status
}

Test-Case "keeps an existing compatible Codex++ without downgrade" {
    $state = Get-CodexPlusPlusInstallState -InstalledVersion ([version] "1.1.0") -NodeMajor 22 -HasNpm $true `
        -TargetMirrorRunning $false
    Assert-Equal "Current" $state.Status
}

Test-Case "blocks installation without prerequisites" {
    Assert-Equal "Blocked" (Get-CodexPlusPlusInstallState -InstalledVersion $null -NodeMajor 18 -HasNpm $true `
        -TargetMirrorRunning $false).Status
    Assert-Equal "Blocked" (Get-CodexPlusPlusInstallState -InstalledVersion $null -NodeMajor 22 -HasNpm $false `
        -TargetMirrorRunning $false).Status
}

Test-Case "blocks first injection when its exact managed mirror is running" {
    $state = Get-CodexPlusPlusInstallState -InstalledVersion $null -NodeMajor 22 -HasNpm $true `
        -TargetMirrorRunning $true
    Assert-Equal "Blocked" $state.Status
}

Test-Case "validates only the pinned Codex++ source layout" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        New-Item -ItemType Directory -Path (Join-Path $root "packages/installer/src") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root "package.json"), '{"version":"1.0.0"}')
        [System.IO.File]::WriteAllText((Join-Path $root "package-lock.json"), '{}')
        [System.IO.File]::WriteAllText((Join-Path $root "packages/installer/src/cli.ts"), "export {};" )
        Assert-True (Test-CodexPlusPlusSourceLayout -SourceRoot $root)
        [System.IO.File]::WriteAllText((Join-Path $root "package.json"), '{"version":"1.0.1"}')
        Assert-Throws { Test-CodexPlusPlusSourceLayout -SourceRoot $root } "1.0.0"
    }
    finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

Test-Case "refuses to overwrite a retained previous source during swap" {
    Assert-Equal "Ready" (Get-CodexPlusPlusSourceSwapState -SourceExists $true -PreviousExists $false).Status
    Assert-Equal "Blocked" (Get-CodexPlusPlusSourceSwapState -SourceExists $true -PreviousExists $true).Status
}
```

- [ ] **Step 2: Implement and export the pure installer decisions**

Add functions with no network or process calls:

```powershell
function Get-CodexPlusPlusInstallState
{
    [CmdletBinding()]
    param(
        [AllowNull()] [version] $InstalledVersion,
        [int] $NodeMajor,
        [bool] $HasNpm,
        [bool] $TargetMirrorRunning)

    if ($null -ne $InstalledVersion -and $InstalledVersion -ge [version] "1.0.0")
    {
        return [pscustomobject]@{ Status = "Current"; Reason = "Compatible Codex++ is already installed." }
    }
    if ($NodeMajor -lt 20)
    {
        return [pscustomobject]@{ Status = "Blocked"; Reason = "Node.js 20 or newer is required." }
    }
    if (!$HasNpm)
    {
        return [pscustomobject]@{ Status = "Blocked"; Reason = "npm is required." }
    }
    if ($TargetMirrorRunning)
    {
        return [pscustomobject]@{ Status = "Blocked"; Reason = "The target Codex++ mirror is running." }
    }
    return [pscustomobject]@{ Status = "InstallRequired"; Reason = "Codex++ is not installed." }
}

function Test-CodexPlusPlusSourceLayout
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceRoot)

    $root = Resolve-NormalizedPath $SourceRoot
    $required = @(
        (Join-Path $root "package.json"),
        (Join-Path $root "package-lock.json"),
        (Join-Path $root "packages/installer/src/cli.ts"))
    foreach ($path in $required)
    {
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Codex++ source file is missing: $path" }
    }
    $package = Get-Content -LiteralPath (Join-Path $root "package.json") -Raw | ConvertFrom-Json
    if ([version] $package.version -ne [version] "1.0.0")
    {
        throw "Expected Codex++ source version 1.0.0, found $($package.version)."
    }
    return $true
}

function Get-CodexPlusPlusSourceSwapState
{
    [CmdletBinding()]
    param([bool] $SourceExists, [bool] $PreviousExists)

    if ($PreviousExists)
    {
        return [pscustomobject]@{
            Status = "Blocked"
            HasCurrentSource = $SourceExists
            Reason = "A retained .previous Codex++ source already exists."
        }
    }
    return [pscustomobject]@{
        Status = "Ready"
        HasCurrentSource = $SourceExists
        Reason = "Source swap can retain the current source safely."
    }
}
```

- [ ] **Step 3: Implement the installer discovery and mutation boundary**

Create `Install-CodexPlusPlus.ps1` with only `-CheckOnly`. Define constants inside the script:

```powershell
$codexPlusPlusVersion = [version] "1.0.0"
$codexPlusPlusCommit = "f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7"
$archiveUri = "https://codeload.github.com/b-nnett/codex-plusplus/zip/$codexPlusPlusCommit"
$sourceRoot = Join-Path $env:USERPROFILE ".codex-plusplus/source"
```

The script must first reuse Task 3's latest-Appx layout and process containment checks. Resolve Node/npm and parse an
existing `codexplusplus --version` if available. Then call `Get-CodexPlusPlusInstallState` and print its status,
reason, pinned version/commit, latest Appx, and expected source root.

If a `codexplusplus` command exists but its version output cannot be parsed, report `Blocked`; do not treat an
unknown command as missing and overwrite its source.

For `-CheckOnly`, exit before `Invoke-WebRequest`, temporary-directory creation, npm, source moves, CLI invocation, or
junction mutation. If compatible Codex++ is already installed, a normal run invokes
`Inject-CodexPlusPlus.ps1` and does not download or replace its source.

- [ ] **Step 4: Implement pinned download, validation, build, and transactional source swap**

For `InstallRequired`, use a newly generated directory below `[System.IO.Path]::GetTempPath()`. Download only
`$archiveUri`, expand it, require exactly one extracted root, and call `Test-CodexPlusPlusSourceLayout` before npm:

```powershell
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("unity-links-codexpp-" + [guid]::NewGuid().ToString("N"))
$archivePath = Join-Path $workRoot "source.zip"
$extractRoot = Join-Path $workRoot "extract"
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
Invoke-WebRequest -Uri $archiveUri -OutFile $archivePath -UseBasicParsing
Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
$extracted = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
if ($extracted.Count -ne 1) { throw "Expected exactly one Codex++ source root in the pinned archive." }
Test-CodexPlusPlusSourceLayout -SourceRoot $extracted[0].FullName | Out-Null
```

Run these exact commands inside the validated extracted root and check `$LASTEXITCODE` after each:

```powershell
& npm.cmd ci --workspaces --include-workspace-root --ignore-scripts
& npm.cmd run build
```

Require `packages/installer/dist/cli.js` after build. For the swap, require `$sourceRoot` equals the normalized
`%USERPROFILE%\.codex-plusplus\source` path, refuse a pre-existing `.previous` backup, move current source to
`$sourceRoot.previous`, and move the validated build into place. If the new CLI version check fails, move the new
tree back under the temporary root and restore `.previous`. Delete `.previous` recursively only after the new source
CLI and initial install both succeed, and only after revalidating that exact backup path.

Call `Get-CodexPlusPlusSourceSwapState` with the two actual path-existence results before the first move and require
`Ready`; do not duplicate or weaken its retained-backup decision in the entry point.

Always clean the exact generated `$workRoot` in `finally`; never use `$HOME`, a wildcard, or a computed broad parent
as a recursive deletion target.

- [ ] **Step 5: Perform initial injection and delegate final link verification**

Invoke the built CLI directly so first installation does not depend on a pre-existing shim:

```powershell
& $nodeCommand.Source (Join-Path $sourceRoot "packages/installer/dist/cli.js") install `
    --app $appLayout.OfficialAppRoot --no-watcher
if ($LASTEXITCODE -ne 0) { throw "Pinned Codex++ installer failed." }
```

Then require `codexplusplus --version` to report 1.0.0 and invoke the repository's
`Inject-CodexPlusPlus.ps1`. The injection script performs final state/status/junction verification. Do not duplicate
its link decision table in the installer.

If the initial CLI install succeeds but the final link verification fails, report the partial state and keep the
verified 1.0.0 source rather than rolling back to a command that may no longer match the installed runtime.

- [ ] **Step 6: Verify check-only safety and commit Task 5**

Snapshot the Codex++ state, source directory metadata, mirror ASAR, and tweak link; run:

```powershell
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
rg -n "Invoke-Expression|\biex\b|/main/|--purge|Stop-Process|Start-Process" Install-CodexPlusPlus.ps1
git diff --check
```

Expected: the already installed 1.0.0 is `Current`; no network or mutations occur; static scan is empty. Commit:

```powershell
git add Install-CodexPlusPlus.ps1 scripts/UnityLinkMaintenance.psm1 scripts/tests/UnityLinkMaintenance.Tests.ps1
git commit -m "feat: add pinned Codex++ installer"
```

---

### Task 6: Safe Non-Purge Codex++ Uninjection

**Files:**

- Modify: `scripts/UnityLinkMaintenance.psm1`
- Modify: `scripts/tests/UnityLinkMaintenance.Tests.ps1`
- Create: `Uninject-CodexPlusPlus.ps1`

**Interfaces:**

- `Get-CodexUninjectState([object] $CodexState, [bool] $HasCommand, [string] $LinkStatus,
  [string[]] $RunningExecutablePaths)` -> `NotInjected`, `Ready`, `LinkOnly`, or `Blocked`.
- `Get-CodexUninstallArguments([string] $AppRoot)` -> exact non-purge CLI arguments.
- `Remove-TweakLink([string] $LinkPath)` -> removes only a junction/symbolic link or throws.
- `Uninject-CodexPlusPlus.ps1 [-CheckOnly]` -> official non-purge uninstall followed by safe unlink.

- [ ] **Step 1: Add failing uninjection state and safe unlink tests**

Cover no state/no link, active state, link-only residue, target mirror running, unsafe real directory, and successful
removal of an exact test junction:

```powershell
Test-Case "classifies absent state and link as NotInjected" {
    $result = Get-CodexUninjectState -CodexState $null -HasCommand $false -LinkStatus "Missing" `
        -RunningExecutablePaths @()
    Assert-Equal "NotInjected" $result.Status
}

Test-Case "classifies recorded injection as Ready" {
    $state = [pscustomobject]@{ appRoot = "C:\mirror\app" }
    $result = Get-CodexUninjectState -CodexState $state -HasCommand $true -LinkStatus "Current" `
        -RunningExecutablePaths @()
    Assert-Equal "Ready" $result.Status
    Assert-Equal "C:\mirror\app" $result.AppRoot
}

Test-Case "classifies a safe residual junction as LinkOnly" {
    $result = Get-CodexUninjectState -CodexState $null -HasCommand $false -LinkStatus "WrongTarget" `
        -RunningExecutablePaths @()
    Assert-Equal "LinkOnly" $result.Status
}

Test-Case "blocks uninjection while the recorded mirror is running" {
    $state = [pscustomobject]@{ appRoot = "C:\mirror\app" }
    $result = Get-CodexUninjectState -CodexState $state -HasCommand $true -LinkStatus "Current" `
        -RunningExecutablePaths @("C:\mirror\app\Codex.exe")
    Assert-Equal "Blocked" $result.Status
}

Test-Case "blocks unsafe live tweak directories" {
    $result = Get-CodexUninjectState -CodexState $null -HasCommand $false -LinkStatus "Unsafe" `
        -RunningExecutablePaths @()
    Assert-Equal "Blocked" $result.Status
}

Test-Case "blocks recorded injection when the Codex++ command is unavailable" {
    $state = [pscustomobject]@{ appRoot = "C:\mirror\app" }
    $result = Get-CodexUninjectState -CodexState $state -HasCommand $false -LinkStatus "Current" `
        -RunningExecutablePaths @()
    Assert-Equal "Blocked" $result.Status
}

Test-Case "builds an explicit non-purge uninstall command" {
    $arguments = @(Get-CodexUninstallArguments -AppRoot "C:\mirror\app")
    Assert-Equal '["uninstall","--app","C:\\mirror\\app"]' `
        (ConvertTo-Json -InputObject $arguments -Compress)
    Assert-True ($arguments -notcontains "--purge")
}
```

Extend the Task 4 junction fixture to call `Remove-TweakLink`, assert the link becomes `Missing`, and add both an
ordinary-directory fixture that throws and remains present and a broken-junction fixture whose missing target does
not prevent safe unlinking.

- [ ] **Step 2: Implement pure uninjection classification and exact unlink**

Add and export:

```powershell
function Get-CodexUninjectState
{
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $CodexState,
        [bool] $HasCommand,
        [Parameter(Mandatory)] [ValidateSet("Current", "Missing", "WrongTarget", "Unsafe")] [string] $LinkStatus,
        [string[]] $RunningExecutablePaths = @())

    if ($LinkStatus -eq "Unsafe")
    {
        return [pscustomobject]@{ Status = "Blocked"; Reason = "The live tweak path is a real directory."; AppRoot = $null }
    }
    if ($null -eq $CodexState)
    {
        $status = if ($LinkStatus -eq "Missing") { "NotInjected" } else { "LinkOnly" }
        return [pscustomobject]@{ Status = $status; Reason = "No Codex++ injection state exists."; AppRoot = $null }
    }
    if (!$HasCommand)
    {
        return [pscustomobject]@{ Status = "Blocked"; Reason = "The codexplusplus command is unavailable."; AppRoot = $null }
    }
    if (!($CodexState.PSObject.Properties.Name -contains "appRoot") -or !$CodexState.appRoot)
    {
        return [pscustomobject]@{ Status = "Blocked"; Reason = "Codex++ state has no appRoot."; AppRoot = $null }
    }
    $appRoot = Resolve-NormalizedPath ([string] $CodexState.appRoot)
    $running = @($RunningExecutablePaths | Where-Object { $_ -and (Test-PathInside $_ $appRoot) }).Count -gt 0
    if ($running)
    {
        return [pscustomobject]@{ Status = "Blocked"; Reason = "The injected Codex mirror is running."; AppRoot = $appRoot }
    }
    return [pscustomobject]@{ Status = "Ready"; Reason = "Injection can be removed."; AppRoot = $appRoot }
}

function Get-CodexUninstallArguments
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $AppRoot)
    return [string[]] @("uninstall", "--app", (Resolve-NormalizedPath $AppRoot))
}

function Remove-TweakLink
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LinkPath)

    $path = Resolve-NormalizedPath $LinkPath
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $false }
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if (!$isReparsePoint -or !$item.LinkType)
    {
        throw "The live tweak path is a real directory and will not be removed: $path"
    }
    Remove-Item -LiteralPath $path -Force
    if ($null -ne (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue))
    {
        throw "The tweak link still exists after removal: $path"
    }
    return $true
}
```

- [ ] **Step 3: Implement `Uninject-CodexPlusPlus.ps1` with uninstall-before-unlink ordering**

Create a `-CheckOnly` entry point that resolves the command, state file, live link, and current Codex executable paths.
It must use the recorded `state.appRoot`, not the latest official Appx, because that is the exact managed patch being
removed. Print status, reason, recorded app root, and link state.

Normal-mode decision table:

1. `NotInjected`: return success without mutation.
2. `Blocked`: return nonzero with a manual-close or real-directory explanation.
3. `LinkOnly`: call only `Remove-TweakLink`, then verify `Missing`.
4. `Ready`: invoke official uninstall first, check its exit code, verify `state.json` is absent, then call
   `Remove-TweakLink` and verify `Missing`.

Build the only allowed CLI invocation through the tested helper:

```powershell
$arguments = Get-CodexUninstallArguments -AppRoot $uninject.AppRoot
$output = & $codexPlusPlus.Source @arguments 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "codexplusplus uninstall failed:`n$output" }
```

Never append `--purge`. Never remove `%USERPROFILE%\.codex-plusplus\source`, other entries below the tweaks
directory, the standalone repository, or the Unity package dependency. Do not delete the link if official uninstall
fails.

- [ ] **Step 4: Verify check-only and destructive-command boundaries**

Snapshot state, mirror, link, source, and `Packages/manifest.json`; run only check-only mode during implementation:

```powershell
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
rg -n -- "--purge|Stop-Process|Start-Process|taskkill|Remove-Item.*-Recurse" `
    Uninject-CodexPlusPlus.ps1 scripts/UnityLinkMaintenance.psm1
git diff --check
```

Expected: check-only reports `Ready` for the current injection and mutates nothing; static scan is empty. Do not run
normal uninjection during installation acceptance, because this task's live target is to remain injected.

- [ ] **Step 5: Commit Task 6**

```powershell
git add Uninject-CodexPlusPlus.ps1 scripts/UnityLinkMaintenance.psm1 `
    scripts/tests/UnityLinkMaintenance.Tests.ps1
git commit -m "feat: add safe Codex++ uninjection"
```

---

### Task 7: Documentation and Pre-Migration Verification

**Files:**

- Modify: `README.md`

- [ ] **Step 1: Rewrite operational documentation around the scripts**

Update README sections so they contain no fixed repository source path. Document:

- Run all four scripts from the cloned/moved repository root; they self-locate with `$PSScriptRoot`.
- `Install-CodexPlusPlus.ps1` installs the pinned official v1.0.0 source only when no compatible CLI exists, performs
  first injection, and never downgrades a newer compatible install.
- `Inject-CodexPlusPlus.ps1 -CheckOnly` detects only; normal mode may repair the latest version-specific mirror and
  correct the junction, but never installs or updates Codex++.
- `Uninject-CodexPlusPlus.ps1` uses non-purge official uninstall and removes only the safe Unity-link junction. It
  preserves Codex++ source/commands, unrelated tweaks, the repository, and Unity package reference.
- None of the Codex scripts patches WindowsApps or closes/restarts Codex.
- `Install-UnityPackage.ps1` finds a Unity ancestor automatically, while `-UnityProject` supports another project.
- The Unity script edits only `com.kpk.codex-unity-link` and leaves `packages-lock.json` to Unity.
- Installation, injection, and uninjection status meanings and recovery actions.
- Codex++ 1.0.0 caveat: never run `codexplusplus debug` without an explicit `--app`; the maintenance script does not
  use `debug` at all.
- Final repository placement below `FilePackages` is an example, not a hard-coded runtime dependency.
- Unity package removal remains separate from Codex++ uninjection; do not describe broad or recursive manual delete
  commands.

- [ ] **Step 2: Run fresh pre-migration checks**

Run:

```powershell
pwsh -NoProfile -File scripts/tests/Run-Tests.ps1
pwsh -NoProfile -File .\Install-UnityPackage.ps1 -UnityProject D:\workspace\sgproj -CheckOnly
pwsh -NoProfile -File .\Install-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Inject-CodexPlusPlus.ps1 -CheckOnly
pwsh -NoProfile -File .\Uninject-CodexPlusPlus.ps1 -CheckOnly
Push-Location codex-tweak
try { npm test }
finally { Pop-Location }
codexplusplus validate-tweak (Resolve-Path .\codex-tweak).Path
rg -n "D:\\workspace\\codex-tweaks\\unity-links|D:/workspace/codex-tweaks/unity-links" `
    --glob "!docs/superpowers/**" .
git diff --check
```

Expected: all PowerShell and Node tests PASS; validation succeeds; all four maintenance scripts are check-only; no
production file or README retains the old absolute location. The Codex status may legitimately say injection is
required until Task 8.

- [ ] **Step 3: Self-review design coverage and interface consistency**

Check every approved design requirement against implementation and tests:

- latest Appx selection and version-specific mirror;
- immutable v1.0.0 commit pin, source validation, no-downgrade behavior, and transactional source swap;
- explicit `repair --force --app`;
- all four states and `-CheckOnly` mutation safety;
- explicit non-purge `uninstall --app <recorded mirror>` and uninstall-before-unlink ordering;
- exact junction target and real-directory refusal;
- automatic/explicit Unity discovery;
- targeted, rollback-capable JSON edit with CRLF/LF preservation;
- no `packages-lock.json` write;
- no application termination or UI automation;
- `$PSScriptRoot` portability after move.

Run `Get-Command` on all four scripts to ensure only documented public parameters exist. Correct any discrepancy
with a test first.

- [ ] **Step 4: Commit docs and require a clean standalone worktree**

```powershell
git add README.md
git commit -m "docs: document maintenance scripts"
git status --short
git log -6 --oneline
```

Expected: worktree clean. Do not move a dirty repository.

---

### Task 8: Move the Repository and Perform Live Integration

**Files/state:**

- Move: `D:\workspace\codex-tweaks\unity-links` -> `D:\workspace\sgproj\FilePackages\unity-links`
- Modify: `D:\workspace\sgproj\Packages\manifest.json`
- Review Unity-generated: `D:\workspace\sgproj\Packages\packages-lock.json`
- Replace exact live junction target under `%APPDATA%\codex-plusplus\tweaks`
- Repair latest Codex++ mirror only if the script classifies it safe

- [ ] **Step 1: Audit Perforce and validate exact migration endpoints**

Use Perforce MCP to query changelist 3423589 and confirm the existing `Packages/manifest.json` and
`Packages/packages-lock.json` edits. Query the default changelist and preserve the opened binary skill asset. Do not
submit or revert anything.

From `D:\workspace\sgproj`, not from inside the source repository, resolve and print the exact source, destination,
and destination parent. Require all of these before moving:

```powershell
$sourceRepository = "D:\workspace\codex-tweaks\unity-links"
$destinationRepository = "D:\workspace\sgproj\FilePackages\unity-links"
$destinationParent = Split-Path $destinationRepository -Parent

if (!(Test-Path -LiteralPath (Join-Path $sourceRepository ".git") -PathType Container)) {
    throw "Source is not the expected standalone Git repository."
}
if (Test-Path -LiteralPath $destinationRepository) { throw "Destination already exists." }
if (!(Test-Path -LiteralPath $destinationParent -PathType Container)) { throw "Destination parent is missing." }
if ((Get-Location).Path.StartsWith($sourceRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Run the move from outside the source repository."
}
git -C $sourceRepository status --short
```

Require empty Git status and confirm `D:\workspace\sgproj\.p4ignore` contains `/FilePackages/` before proceeding.

- [ ] **Step 2: Move once, without delete/recreate or history copying**

Run from `D:\workspace\sgproj`:

```powershell
Move-Item -LiteralPath "D:\workspace\codex-tweaks\unity-links" `
    -Destination "D:\workspace\sgproj\FilePackages\unity-links"
```

Immediately verify:

```powershell
Test-Path -LiteralPath "D:\workspace\codex-tweaks\unity-links"
Test-Path -LiteralPath "D:\workspace\sgproj\FilePackages\unity-links\.git"
git -C D:\workspace\sgproj\FilePackages\unity-links status --short
git -C D:\workspace\sgproj\FilePackages\unity-links log -1 --oneline
```

Expected: old path `False`, new `.git` `True`, worktree clean, history head unchanged.

- [ ] **Step 3: Re-run tests from the moved location**

```powershell
$movedRepository = "D:\workspace\sgproj\FilePackages\unity-links"
pwsh -NoProfile -File (Join-Path $movedRepository "scripts/tests/Run-Tests.ps1")
pwsh -NoProfile -File (Join-Path $movedRepository "Install-UnityPackage.ps1") -CheckOnly
pwsh -NoProfile -File (Join-Path $movedRepository "Install-CodexPlusPlus.ps1") -CheckOnly
pwsh -NoProfile -File (Join-Path $movedRepository "Inject-CodexPlusPlus.ps1") -CheckOnly
pwsh -NoProfile -File (Join-Path $movedRepository "Uninject-CodexPlusPlus.ps1") -CheckOnly
```

Expected: tests still PASS; Unity expected value is exactly
`file:../FilePackages/unity-links/unity-package`; Codex check reports current live state without mutation.

- [ ] **Step 4: Verify install/uninject checks, then run injection without closing Codex**

The install check must report compatible Codex++ without downloading anything. The uninject check must report the
current state without removing it. Then run only the normal injection script:

```powershell
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\Inject-CodexPlusPlus.ps1
```

Accept only these outcomes:

- `Current`: no injection or link mutation was needed.
- Successful repair/link: final verification is `Current`, and the script prints the manual restart prompt if the
  official Codex is still running.
- `Blocked`: stop here. If the exact target mirror is running or the live path is a real directory, report the exact
  blocker and ask for direction. Do not close Codex and do not alter the unsafe directory.

After success, independently verify `state.json` points at the mirror derived from the latest Appx, `codexplusplus
status` contains `matches patched`, and the junction target is the moved `codex-tweak` directory.

- [ ] **Step 5: Update the Unity manifest through the separate script**

Run:

```powershell
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\Install-UnityPackage.ps1
pwsh -NoProfile -File D:\workspace\sgproj\FilePackages\unity-links\Install-UnityPackage.ps1 -CheckOnly
```

Expected: first run updates only `com.kpk.codex-unity-link`; second reports `Current`; the manifest value is exactly
`file:../FilePackages/unity-links/unity-package`. Do not hand-edit `packages-lock.json`.

- [ ] **Step 6: Refresh Unity and verify Console according to repository rules**

Read `D:\workspace\sgproj\docs\agent-rules\verification.md` completely. Use Unity MCP to select the exact
`D:/workspace/sgproj/Assets` Unity 2022.3.23f1 instance. Call `refresh_unity` with compile requested and wait for
ready, then call `read_console` for detailed errors and warnings.

Expected: the local package resolves from the moved path, `KPK.CodexUnityLink.Editor` compiles, and there are no real
project errors. Do not run EditMode or battle tests.

- [ ] **Step 7: Verify runtime behavior without relaunching Codex**

Run the existing non-UI tests and direct Pipe requests from the moved repository:

```powershell
Push-Location D:\workspace\sgproj\FilePackages\unity-links\codex-tweak
try { npm test }
finally { Pop-Location }
codexplusplus validate-tweak D:\workspace\sgproj\FilePackages\unity-links\codex-tweak
node D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\scripts\send-open.js `
    D:\workspace\sgproj\Assets\Light.prefab
node D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\scripts\send-open.js `
    D:\workspace\sgproj\Assets\Plugins\SkillTimeline\Editor\Data\SkillGraphData\1.asset
node D:\workspace\sgproj\FilePackages\unity-links\codex-tweak\scripts\send-open.js `
    D:\workspace\sgproj\Assets\GameEntry.cs:1:1
```

Expected: Node tests PASS; validation succeeds; each Pipe response has `"ok":true` and `"code":"opened"`. Re-read
the Unity Console afterward. Opening the existing skill asset may interact with its already-open binary change; do
not save, revert, or otherwise modify that asset during verification.

- [ ] **Step 8: Audit final Git, paths, manifest, and Perforce scope**

Verify:

```powershell
git -C D:\workspace\sgproj\FilePackages\unity-links status --short
rg -n "D:\\workspace\\codex-tweaks\\unity-links|D:/workspace/codex-tweaks/unity-links" `
    D:\workspace\sgproj\FilePackages\unity-links --glob "!docs/superpowers/**"
Test-Path -LiteralPath D:\workspace\codex-tweaks\unity-links
```

Expected: nested Git clean, no production references to the old location, old path absent. Through Perforce MCP,
review diffs for the two package files and confirm no `FilePackages/unity-links` files are opened. Preserve all
unrelated manifest/lock changes and the binary skill asset; do not submit.

- [ ] **Step 9: Stop at the manual Codex close/relaunch boundary**

Report all non-interactive results and explicitly tell the user that the next acceptance step requires manually
closing the currently running Codex and launching the `Codex++` shortcut. Wait for the user's confirmation. Do not
call any process-management or UI-automation command.

After the user returns in the relaunched Codex++ instance, provide clickable links for the same Prefab, skill asset,
and C# file and ask them to confirm Unity handled each one. This interactive click check is the final acceptance
step; it is not authorization to save or alter any opened Unity asset.
