$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TestHarness.ps1")
$scriptsRoot = Split-Path $PSScriptRoot -Parent
foreach ($moduleName in @(
        "UnityLinkCommon.psm1",
        "UnityPackageMaintenance.psm1",
        "CodexTweakLink.psm1",
        "CodexPlusPlusMaintenance.psm1"))
{
    Import-Module (Join-Path $scriptsRoot $moduleName) -Force
}

function Unity-Project-TestCase
{
    param([string] $Name, [scriptblock] $Body)

    if ($env:UNITY_LINKS_SKIP_UNITY_PROJECT_TESTS -eq "1")
    {
        Skip-TestCase -Name $Name -Reason "Requires unity-links to be located inside a real Unity project."
        return
    }
    Test-Case -Name $Name -Body $Body
}

Test-Case "repository layout follows its supplied root" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) "moved-unity-links"
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $root
    Assert-Equal (Join-Path $root "codex-tweak") $layout.TweakRoot
    Assert-Equal (Join-Path $root "unity-package") $layout.PackageRoot
}

Test-Case "accepts initialized component manifests" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        New-Item -ItemType Directory -Path (Join-Path $root "codex-tweak"),
            (Join-Path $root "unity-package") -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root "codex-tweak/manifest.json"), "{}")
        [System.IO.File]::WriteAllText((Join-Path $root "unity-package/package.json"), "{}")
        $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $root
        Assert-UnityLinkComponentInitialized -Layout $layout -Component CodexTweak
        Assert-UnityLinkComponentInitialized -Layout $layout -Component UnityPackage
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "reports the exact command for an uninitialized component" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $root
        $commandPattern = [regex]::Escape(
            "git -C `"$root`" submodule update --init --recursive")
        Assert-Throws {
            Assert-UnityLinkComponentInitialized -Layout $layout -Component CodexTweak
        } $commandPattern
        Assert-Throws {
            Assert-UnityLinkComponentInitialized -Layout $layout -Component UnityPackage
        } $commandPattern
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "Unity receiver dispatches AnimationClip assets without changing generic fallbacks" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $receiverPath = Join-Path $repositoryRoot "unity-package/Editor/UnityAssetLinkReceiver.cs"
    $receiver = Get-Content -LiteralPath $receiverPath -Raw

    Assert-True ($receiver.Contains("opened = OpenAsset(asset, request.line, request.column)"))
    Assert-True ($receiver.Contains("if (asset is AnimationClip clip)"))
    Assert-True ($receiver.Contains("if (line <= 0) return AssetDatabase.OpenAsset(asset)"))
    Assert-True ($receiver.Contains("if (column <= 0) return AssetDatabase.OpenAsset(asset, line)"))
    Assert-True ($receiver.Contains("return AssetDatabase.OpenAsset(asset, line, column)"))
    Assert-True ($receiver.Contains("Selection.activeObject = clip"))
    Assert-True ($receiver.Contains("EditorGUIUtility.PingObject(clip)"))
    Assert-True ($receiver.Contains("window.animationClip = clip"))
    Assert-True ($receiver.Contains("return window.animationClip == clip"))
}

Test-Case "maintainer checks stay project-neutral and avoid temporary Unity projects" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $projectName = "sg" + "proj"
    $legacyLayout = "File" + "Packages"
    $files = @(
        (Join-Path $repositoryRoot "codex-tweak/test/index.test.js"),
        (Join-Path $repositoryRoot "scripts/tests/UnityLinkMaintenance.Tests.ps1"),
        (Join-Path $repositoryRoot ".github/workflows/release.yml"),
        (Join-Path $repositoryRoot "scripts/release/validate-release.mjs"),
        (Join-Path $repositoryRoot "scripts/release/validate-release.test.mjs"),
        (Join-Path $repositoryRoot "scripts/tests/UninjectCheckOnly.Integration.ps1"),
        (Join-Path $repositoryRoot "docs/design.md"),
        (Join-Path $repositoryRoot "README.md"),
        (Join-Path $repositoryRoot "README.zh-CN.md"))

    foreach ($file in $files)
    {
        $text = Get-Content -LiteralPath $file -Raw
        Assert-True (!$text.Contains($projectName)) "Project-specific name found in $file."
        Assert-True (!$text.Contains($legacyLayout)) "Legacy repository layout found in $file."
    }

    $nodeTest = Get-Content -LiteralPath $files[0] -Raw
    Assert-True (!$nodeTest.Contains("mkdtemp" + "Sync")) "Node tests must use an in-memory filesystem."

    $powerShellTest = Get-Content -LiteralPath $files[1] -Raw
    $temporaryAssetsMarker = 'Join-Path $root "' + 'Assets"'
    Assert-True (!$powerShellTest.Contains($temporaryAssetsMarker)) `
        "PowerShell tests must not assemble a temporary Unity project."
}

Test-Case "Unity installer delegates transactional writes without version-control probing" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $installerText = Get-Content -LiteralPath (Join-Path $repositoryRoot "Install-UnityPackage.ps1") -Raw
    $directTextWrite = "[System.IO.File]::WriteAll" + "Text(`$manifestPath"
    $directByteWrite = "[System.IO.File]::WriteAll" + "Bytes(`$manifestPath"
    $perforceName = "Per" + "force"
    $p4Command = "p" + "4 "

    Assert-True ($installerText.Contains("Set-UnityManifestTextSafely"))
    Assert-True (!$installerText.Contains($directTextWrite))
    Assert-True (!$installerText.Contains($directByteWrite))
    Assert-True (!$installerText.Contains($perforceName))
    Assert-True (!$installerText.Contains($p4Command))
}

Test-Case "bilingual READMEs cover project-neutral first install and relocation" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $englishReadme = Get-Content -LiteralPath (Join-Path $repositoryRoot "README.md") -Raw
    $chineseReadme = Get-Content -LiteralPath (Join-Path $repositoryRoot "README.zh-CN.md") -Raw
    $legacyLayout = "File" + "Packages"
    $sharedText = @(
        "https://github.com/kpkhxlgy0/unity-links.git",
        "PowerShell 7",
        "Node.js 20",
        "npm",
        'New-Item -ItemType Directory -Path (Join-Path $unityProject "Tools")',
        "New-Item -ItemType Directory -Path D:\Tools",
        "-UnityProject")
    $requiredEnglishText = @(
        "[简体中文](README.zh-CN.md)",
        "Start menu",
        "Moving the Repository",
        "wait for package compilation to finish")
    $requiredChineseText = @(
        "[English](README.md)",
        "开始菜单",
        "移动仓库",
        "等待 Unity 完成 package 编译")

    foreach ($text in $sharedText)
    {
        Assert-True ($englishReadme.Contains($text)) "English README is missing: $text"
        Assert-True ($chineseReadme.Contains($text)) "Chinese README is missing: $text"
    }
    foreach ($text in $requiredEnglishText) { Assert-True ($englishReadme.Contains($text)) "English README is missing: $text" }
    foreach ($text in $requiredChineseText) { Assert-True ($chineseReadme.Contains($text)) "Chinese README is missing: $text" }
    Assert-True (!$englishReadme.Contains($legacyLayout))
    Assert-True (!$chineseReadme.Contains($legacyLayout))
}

Test-Case "MIT license and bilingual release documentation are complete" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $license = Get-Content -LiteralPath (Join-Path $repositoryRoot "LICENSE") -Raw
    $tweakManifest = Get-Content -LiteralPath (Join-Path $repositoryRoot "codex-tweak/manifest.json") -Raw |
        ConvertFrom-Json
    $tweakPackage = Get-Content -LiteralPath (Join-Path $repositoryRoot "codex-tweak/package.json") -Raw |
        ConvertFrom-Json
    $unityPackage = Get-Content -LiteralPath (Join-Path $repositoryRoot "unity-package/package.json") -Raw |
        ConvertFrom-Json
    $englishReadme = Get-Content -LiteralPath (Join-Path $repositoryRoot "README.md") -Raw
    $chineseReadme = Get-Content -LiteralPath (Join-Path $repositoryRoot "README.zh-CN.md") -Raw

    Assert-True ($license.Contains("MIT License"))
    Assert-True ($license.Contains("Copyright (c) 2026 KPK"))
    Assert-Equal "MIT" $tweakPackage.license
    Assert-Equal "MIT" $unityPackage.license
    Assert-Equal "kpkhxlgy0/unity-links-codex" $tweakManifest.githubRepo
    Assert-Equal "0.2.2" $tweakManifest.version
    Assert-Equal "0.2.2" $tweakPackage.version
    Assert-Equal "0.2.3" $unityPackage.version
    Assert-Equal "https://github.com/kpkhxlgy0/unity-links-unity/blob/master/LICENSE" `
        $unityPackage.licensesUrl

    $requiredEnglish = @("## Release Process", "Actions", "Draft Release", "## License", "[MIT License](LICENSE)")
    $requiredChinese = @("## 发布流程", "Actions", "Draft Release", "## 开源协议", "[MIT License](LICENSE)")
    foreach ($text in $requiredEnglish)
    {
        Assert-True ($englishReadme.Contains($text)) "English README is missing: $text"
    }
    foreach ($text in $requiredChinese)
    {
        Assert-True ($chineseReadme.Contains($text)) "Chinese README is missing: $text"
    }
}

Test-Case "pins both component repositories with SSH submodule URLs" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $gitmodules = Get-Content -LiteralPath (Join-Path $repositoryRoot ".gitmodules") -Raw
    $required = @(
        '[submodule "codex-tweak"]',
        "path = codex-tweak",
        "url = git@github.com:kpkhxlgy0/unity-links-codex.git",
        '[submodule "unity-package"]',
        "path = unity-package",
        "url = git@github.com:kpkhxlgy0/unity-links-unity.git")
    foreach ($text in $required)
    {
        Assert-True ($gitmodules.Contains($text)) ".gitmodules is missing: $text"
    }
}

Test-Case "release workflow is manual guarded and draft-only" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $workflow = Get-Content -LiteralPath (Join-Path $repositoryRoot ".github/workflows/release.yml") -Raw
    $required = @(
        "workflow_dispatch:",
        "contents: write",
        "windows-latest",
        "actions/checkout@v6",
        "submodules: recursive",
        "actions/setup-node@v6",
        'node-version: "24"',
        "package-manager-cache: false",
        'UNITY_LINKS_SKIP_UNITY_PROJECT_TESTS: "1"',
        "refs/heads/master",
        "scripts/release/validate-release.mjs",
        "scripts/tests/Run-Tests.ps1",
        "codex-tweak/test/index.test.js",
        'foreach ($component in @("codex-tweak", "unity-package"))',
        'git -C $component fetch --tags origin',
        "scripts/release/validate-release.test.mjs",
        "f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7",
        "npm run build --workspace codex-plusplus",
        "gh release create",
        "--verify-tag",
        "--draft",
        "--generate-notes")
    foreach ($text in $required)
    {
        Assert-True ($workflow.Contains($text)) "Release workflow is missing: $text"
    }
    Assert-True (!$workflow.Contains("--draft=false"))
    Assert-True (!$workflow.Contains("actions/checkout@v4"))
    Assert-True (!$workflow.Contains("actions/setup-node@v4"))
    Assert-True (!$workflow.Contains("git fetch --force"))
    Assert-True (!$workflow.Contains("pull_request:"))
    Assert-True (!$workflow.Contains("--json tagName,url"))
}

Test-Case "test harness reports intentionally skipped Unity project integration" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $harness = Get-Content -LiteralPath (Join-Path $repositoryRoot "scripts/tests/TestHarness.ps1") -Raw
    $maintenanceTests = Get-Content `
        -LiteralPath (Join-Path $repositoryRoot "scripts/tests/UnityLinkMaintenance.Tests.ps1") -Raw

    Assert-True ($harness.Contains("function Skip-TestCase"))
    Assert-True ($harness.Contains('$script:SkippedCount'))
    Assert-True ($maintenanceTests.Contains("function Unity-Project-TestCase"))
    Assert-True ($maintenanceTests.Contains("UNITY_LINKS_SKIP_UNITY_PROJECT_TESTS"))
}

Test-Case "finds the nearest matching ancestor without filesystem fixtures" {
    $expected = "D:\Samples\ExampleUnityProject"
    $actual = Find-UnityProjectRoot `
        -StartPath "$expected\Tools\unity-links\scripts\tests" `
        -ProjectRootTest {
            param($candidate)
            return Test-PathEqual $candidate $expected
        }

    Assert-Equal $expected $actual
}

Unity-Project-TestCase "finds the real Unity project above the current repository" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $projectRoot = Find-UnityProjectRoot -StartPath $repositoryRoot

    Assert-True (Test-UnityProjectRoot $projectRoot)
    Assert-True ((Resolve-NormalizedPath $repositoryRoot).StartsWith(
            (Resolve-NormalizedPath $projectRoot),
            [System.StringComparison]::OrdinalIgnoreCase))
}

Test-Case "computes the final portable package value" {
    $project = "D:\Projects\ExampleUnityProject"
    $package = "D:\Projects\ExampleUnityProject\Tools\unity-links\unity-package"
    Assert-Equal "file:../Tools/unity-links/unity-package" `
        (Get-UnityPackageManifestValue -UnityProjectRoot $project -PackageRoot $package)
}

Test-Case "rejects a directory without every Unity marker" {
    Assert-Throws {
        Find-UnityProjectRoot `
            -StartPath "D:\Samples\NotAUnityProject\Tools\unity-links" `
            -ProjectRootTest { return $false }
    } "Unity project"
}

Test-Case "updates only the dependency value and preserves CRLF" {
    $crlf = [string] ([char] 13) + [char] 10
    $before = '{' + $crlf +
        '  "name": "keep",' + $crlf +
        '  "dependencies": {' + $crlf +
        '    "a": "1",' + $crlf +
        '    "com.kpk.codex-unity-link": "file:old"' + $crlf +
        '  }' + $crlf +
        '}' + $crlf
    $expected = $before.Replace('"file:old"', '"file:../Tools/unity-links/unity-package"')
    $result = Update-UnityManifestText -Text $before -DependencyValue "file:../Tools/unity-links/unity-package"
    Assert-True $result.Changed
    Assert-Equal $expected $result.Text
}

Test-Case "inserts the dependency and preserves LF plus unrelated text" {
    $lf = [string] [char] 10
    $before = '{' + $lf +
        '  "name": "keep",' + $lf +
        '  "dependencies": {' + $lf +
        '    "a": "1"' + $lf +
        '  }' + $lf +
        '}' + $lf
    $expected = '{' + $lf +
        '  "name": "keep",' + $lf +
        '  "dependencies": {' + $lf +
        '    "a": "1",' + $lf +
        '    "com.kpk.codex-unity-link": "file:../pkg"' + $lf +
        '  }' + $lf +
        '}' + $lf
    $result = Update-UnityManifestText -Text $before -DependencyValue "file:../pkg"
    Assert-True $result.Changed
    Assert-Equal $expected $result.Text
}

Test-Case "returns the original manifest for an exact no-op" {
    $lf = [string] [char] 10
    $before = '{' + $lf +
        '  "dependencies": {' + $lf +
        '    "com.kpk.codex-unity-link": "file:../pkg"' + $lf +
        '  }' + $lf +
        '}' + $lf
    $result = Update-UnityManifestText -Text $before -DependencyValue "file:../pkg"
    Assert-True (!$result.Changed)
    Assert-Equal $before $result.Text
}

Test-Case "rejects invalid JSON before editing" {
    Assert-Throws {
        Update-UnityManifestText -Text '{"dependencies":{' -DependencyValue "file:../pkg"
    } "valid JSON"
}

Test-Case "reports a version-control-neutral ReadOnly manifest error without changing the file" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    $manifest = Join-Path $root "manifest.json"
    try
    {
        New-Item -ItemType Directory -Path $root | Out-Null
        $originalBytes = [System.Text.Encoding]::UTF8.GetBytes("original manifest")
        [System.IO.File]::WriteAllBytes($manifest, $originalBytes)
        [System.IO.File]::SetAttributes($manifest, [System.IO.FileAttributes]::ReadOnly)

        Assert-Throws {
            Set-UnityManifestTextSafely -ManifestPath $manifest -Text "updated manifest"
        } "read-only.*version-control checkout workflow.*clear the ReadOnly attribute"
        Assert-Equal ([Convert]::ToBase64String($originalBytes)) `
            ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifest)))
        Assert-True (([System.IO.File]::GetAttributes($manifest) -band [System.IO.FileAttributes]::ReadOnly) -ne 0)
    }
    finally
    {
        if (Test-Path -LiteralPath $manifest)
        {
            [System.IO.File]::SetAttributes($manifest, [System.IO.FileAttributes]::Normal)
        }
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Test-Case "reports ACL denial separately and restores original manifest bytes" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    $manifest = Join-Path $root "manifest.json"
    try
    {
        New-Item -ItemType Directory -Path $root | Out-Null
        $originalBytes = [System.Text.Encoding]::UTF8.GetBytes("original manifest")
        [System.IO.File]::WriteAllBytes($manifest, $originalBytes)
        $deniedWrite = {
            param($path, $text, $encoding)
            [System.IO.File]::WriteAllText($path, "partial", $encoding)
            throw [System.UnauthorizedAccessException]::new("Access denied by test.")
        }

        Assert-Throws {
            Set-UnityManifestTextSafely -ManifestPath $manifest -Text "updated manifest" `
                -WriteAction $deniedWrite
        } "permissions \(ACL\)"
        Assert-Equal ([Convert]::ToBase64String($originalBytes)) `
            ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifest)))
    }
    finally
    {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}

Unity-Project-TestCase "Unity CheckOnly does not mutate the manifest" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $projectRoot = Find-UnityProjectRoot -StartPath $repositoryRoot
    $manifest = Join-Path $projectRoot "Packages/manifest.json"
    $before = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    $entryPoint = Join-Path $repositoryRoot "Install-UnityPackage.ps1"
    $pwshPath = (Get-Process -Id $PID).Path

    & $pwshPath -NoProfile -File $entryPoint -CheckOnly | Out-Null
    $entryPointExitCode = $LASTEXITCODE

    Assert-Equal 0 $entryPointExitCode
    Assert-Equal $before (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
}

Unity-Project-TestCase "Unity CheckOnly accepts an explicit real project path" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $projectRoot = Find-UnityProjectRoot -StartPath $repositoryRoot
    $manifest = Join-Path $projectRoot "Packages/manifest.json"
    $before = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    $entryPoint = Join-Path $repositoryRoot "Install-UnityPackage.ps1"
    $pwshPath = (Get-Process -Id $PID).Path

    & $pwshPath -NoProfile -File $entryPoint -UnityProject $projectRoot -CheckOnly | Out-Null
    $entryPointExitCode = $LASTEXITCODE

    Assert-Equal 0 $entryPointExitCode
    Assert-Equal $before (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
}

Test-Case "selects the highest installed Codex Appx version" {
    $packages = @(
        [pscustomobject] @{
            Version = "26.715.10079.0"
            PackageFullName = "old"
            InstallLocation = "C:\old"
        },
        [pscustomobject] @{
            Version = "26.721.3996.0"
            PackageFullName = "new"
            InstallLocation = "C:\new"
        })
    Assert-Equal "new" (Select-LatestCodexPackage -Packages $packages).PackageFullName
}

Test-Case "derives official and version-specific mirror paths" {
    $package = [pscustomobject] @{
        Version = "26.721.3996.0"
        PackageFullName = "OpenAI.Codex_26.721.3996.0_x64__2p2nqsd0c76g0"
        InstallLocation = "C:\Program Files\WindowsApps\OpenAI.Codex_26.721.3996.0_x64__2p2nqsd0c76g0"
    }
    $layout = Get-CodexAppLayout -Package $package -LocalAppData "C:\Users\Test\AppData\Local"
    Assert-Equal (Join-Path $package.InstallLocation "app") $layout.OfficialAppRoot
    Assert-Equal (
        "C:\Users\Test\AppData\Local\codex-plusplus\store-apps\$($package.PackageFullName)\app"
    ) $layout.MirrorAppRoot
}

Test-Case "default cleanup selects only the previously recorded managed mirror" {
    $store = "C:\Local\codex-plusplus\store-apps"
    $current = "$store\OpenAI.Codex_2_x64__publisher\app"
    $previous = "$store\OpenAI.Codex_1_x64__publisher\app"

    $plan = Get-CodexMirrorCleanupPlan `
        -ManagedStoreRoot $store `
        -CurrentAppRoot $current `
        -PreviousAppRoot $previous

    Assert-Equal "Previous" $plan.Mode
    Assert-Equal "$store\OpenAI.Codex_2_x64__publisher" $plan.CurrentPackageRoot
    Assert-Equal 1 @($plan.Targets).Count
    Assert-Equal "$store\OpenAI.Codex_1_x64__publisher" @($plan.Targets)[0]
}

Test-Case "default cleanup keeps the current recorded mirror" {
    $store = "C:\Local\codex-plusplus\store-apps"
    $current = "$store\OpenAI.Codex_2_x64__publisher\app"

    $plan = Get-CodexMirrorCleanupPlan `
        -ManagedStoreRoot $store `
        -CurrentAppRoot $current `
        -PreviousAppRoot $current

    Assert-Equal "Previous" $plan.Mode
    Assert-Equal 0 @($plan.Targets).Count
}

Test-Case "all-old cleanup selects recognized siblings except the current mirror" {
    $store = "C:\Local\codex-plusplus\store-apps"
    $current = "$store\OpenAI.Codex_2_x64__publisher\app"

    $plan = Get-CodexMirrorCleanupPlan `
        -ManagedStoreRoot $store `
        -CurrentAppRoot $current `
        -CandidatePackageRoots @(
            "$store\OpenAI.Codex_0_x64__publisher",
            "$store\OpenAI.Codex_1_x64__publisher",
            "$store\OpenAI.Codex_2_x64__publisher") `
        -CleanupAllOldVersions

    Assert-Equal "AllOld" $plan.Mode
    Assert-Equal 2 @($plan.Targets).Count
    Assert-True (@($plan.Targets) -contains "$store\OpenAI.Codex_0_x64__publisher")
    Assert-True (@($plan.Targets) -contains "$store\OpenAI.Codex_1_x64__publisher")
    Assert-True (@($plan.Targets) -notcontains "$store\OpenAI.Codex_2_x64__publisher")
}

Test-Case "cleanup planning rejects unmanaged or ambiguous paths" {
    $store = "C:\Local\codex-plusplus\store-apps"
    $current = "$store\OpenAI.Codex_2_x64__publisher\app"

    Assert-Throws {
        Get-CodexMirrorCleanupPlan `
            -ManagedStoreRoot $store `
            -CurrentAppRoot $current `
            -PreviousAppRoot "C:\Other\OpenAI.Codex_1_x64__publisher\app"
    } "immediate child"
    Assert-Throws {
        Get-CodexMirrorCleanupPlan `
            -ManagedStoreRoot $store `
            -CurrentAppRoot $current `
            -CandidatePackageRoots "$store\nested\OpenAI.Codex_1_x64__publisher" `
            -CleanupAllOldVersions
    } "immediate child"
    Assert-Throws {
        Get-CodexMirrorCleanupPlan `
            -ManagedStoreRoot $store `
            -CurrentAppRoot $current `
            -CandidatePackageRoots "$store\unrelated" `
            -CleanupAllOldVersions
    } "Unrecognized"
}

Test-Case "cleanup deletion blocks a running old mirror" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        "codex-cleanup-running-" + [guid]::NewGuid().ToString("N"))
    try
    {
        $store = Join-Path $root "store-apps"
        $currentApp = Join-Path $store "OpenAI.Codex_2_x64__publisher/app"
        $oldPackage = Join-Path $store "OpenAI.Codex_1_x64__publisher"
        $oldExecutable = Join-Path $oldPackage "app/ChatGPT.exe"
        New-Item -ItemType Directory -Path $currentApp, (Split-Path $oldExecutable -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($oldExecutable, "running")
        $snapshot = [pscustomobject] @{
            Succeeded = $true
            ExecutablePaths = @($oldExecutable)
            FailureReason = ""
        }

        Assert-Throws {
            Remove-CodexMirrorCleanupTargets `
                -ManagedStoreRoot $store `
                -CurrentAppRoot $currentApp `
                -Targets @($oldPackage) `
                -ProcessSnapshot $snapshot
        } "running"
        Assert-True (Test-Path -LiteralPath $oldPackage -PathType Container)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "cleanup deletion fails closed when process discovery fails" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        "codex-cleanup-process-query-" + [guid]::NewGuid().ToString("N"))
    try
    {
        $store = Join-Path $root "store-apps"
        $currentApp = Join-Path $store "OpenAI.Codex_2_x64__publisher/app"
        $oldPackage = Join-Path $store "OpenAI.Codex_1_x64__publisher"
        New-Item -ItemType Directory -Path $currentApp, $oldPackage -Force | Out-Null
        $snapshot = [pscustomobject] @{
            Succeeded = $false
            ExecutablePaths = @()
            FailureReason = "CIM unavailable"
        }

        Assert-Throws {
            Remove-CodexMirrorCleanupTargets `
                -ManagedStoreRoot $store `
                -CurrentAppRoot $currentApp `
                -Targets @($oldPackage) `
                -ProcessSnapshot $snapshot
        } "process discovery failed.*CIM unavailable"
        Assert-True (Test-Path -LiteralPath $oldPackage -PathType Container)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "cleanup deletion removes only validated old mirrors" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        "codex-cleanup-success-" + [guid]::NewGuid().ToString("N"))
    try
    {
        $store = Join-Path $root "store-apps"
        $currentPackage = Join-Path $store "OpenAI.Codex_2_x64__publisher"
        $currentApp = Join-Path $currentPackage "app"
        $oldPackage = Join-Path $store "OpenAI.Codex_1_x64__publisher"
        $unrelated = Join-Path $store "unrelated"
        New-Item -ItemType Directory -Path $currentApp, $oldPackage, $unrelated -Force | Out-Null
        $snapshot = [pscustomobject] @{
            Succeeded = $true
            ExecutablePaths = @((Join-Path $currentApp "ChatGPT.exe"))
            FailureReason = ""
        }

        $removed = @(Remove-CodexMirrorCleanupTargets `
            -ManagedStoreRoot $store `
            -CurrentAppRoot $currentApp `
            -Targets @($oldPackage) `
            -ProcessSnapshot $snapshot)

        Assert-Equal 1 $removed.Count
        Assert-Equal (Resolve-NormalizedPath $oldPackage) $removed[0]
        Assert-True (!(Test-Path -LiteralPath $oldPackage))
        Assert-True (Test-Path -LiteralPath $currentPackage -PathType Container)
        Assert-True (Test-Path -LiteralPath $unrelated -PathType Container)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "cleanup deletion refuses the current managed mirror" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        "codex-cleanup-current-" + [guid]::NewGuid().ToString("N"))
    try
    {
        $store = Join-Path $root "store-apps"
        $currentPackage = Join-Path $store "OpenAI.Codex_2_x64__publisher"
        $currentApp = Join-Path $currentPackage "app"
        New-Item -ItemType Directory -Path $currentApp -Force | Out-Null
        $snapshot = [pscustomobject] @{
            Succeeded = $true
            ExecutablePaths = @()
            FailureReason = ""
        }

        Assert-Throws {
            Remove-CodexMirrorCleanupTargets `
                -ManagedStoreRoot $store `
                -CurrentAppRoot $currentApp `
                -Targets @($currentPackage) `
                -ProcessSnapshot $snapshot
        } "current managed Codex package"
        Assert-True (Test-Path -LiteralPath $currentPackage -PathType Container)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "classifies current mirror and launcher" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\mirror\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\mirror\app" }
        StatusText = "Current ASAR matches patched"
        RunningExecutablePaths = @()
    }
    $result = Get-CodexMaintenanceState @parameters
    Assert-Equal "Current" $result.Status
}

Test-Case "classifies stale recorded mirror as InjectionRequired" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\new\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\old\app" }
        StatusText = "Current ASAR matches patched"
        RunningExecutablePaths = @("C:\Program Files\WindowsApps\OpenAI.Codex\app\Codex.exe")
    }
    $result = Get-CodexMaintenanceState @parameters
    Assert-Equal "InjectionRequired" $result.Status
}

Test-Case "blocks stale injection while the exact target mirror is running" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\new\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\old\app" }
        StatusText = "ASAR differs"
        RunningExecutablePaths = @("C:\new\app\Codex.exe")
    }
    $result = Get-CodexMaintenanceState @parameters
    Assert-Equal "Blocked" $result.Status
    Assert-True $result.TargetMirrorRunning
}

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
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
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
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
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
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

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
    $oldNode = Get-CodexPlusPlusInstallState -InstalledVersion $null -NodeMajor 18 -HasNpm $true `
        -TargetMirrorRunning $false
    $missingNpm = Get-CodexPlusPlusInstallState -InstalledVersion $null -NodeMajor 22 -HasNpm $false `
        -TargetMirrorRunning $false
    Assert-Equal "Blocked" $oldNode.Status
    Assert-Equal "Blocked" $missingNpm.Status
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
        [System.IO.File]::WriteAllText((Join-Path $root "packages/installer/src/cli.ts"), "export {};")
        Assert-True (Test-CodexPlusPlusSourceLayout -SourceRoot $root)
        [System.IO.File]::WriteAllText((Join-Path $root "package.json"), '{"version":"1.0.1"}')
        Assert-Throws { Test-CodexPlusPlusSourceLayout -SourceRoot $root } "1.0.0"
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "refuses to overwrite a retained previous source during swap" {
    Assert-Equal "Ready" (Get-CodexPlusPlusSourceSwapState -SourceExists $true -PreviousExists $false).Status
    Assert-Equal "Blocked" (Get-CodexPlusPlusSourceSwapState -SourceExists $true -PreviousExists $true).Status
}

Test-Case "classifies absent state and link as NotInjected" {
    $result = Get-CodexUninjectState -CodexState $null -HasCommand $false -LinkStatus "Missing" `
        -RunningExecutablePaths @()
    Assert-Equal "NotInjected" $result.Status
}

Test-Case "classifies recorded injection as Ready" {
    $state = [pscustomobject] @{ appRoot = "C:\mirror\app" }
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
    $state = [pscustomobject] @{ appRoot = "C:\mirror\app" }
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
    $state = [pscustomobject] @{ appRoot = "C:\mirror\app" }
    $result = Get-CodexUninjectState -CodexState $state -HasCommand $false -LinkStatus "Current" `
        -RunningExecutablePaths @()
    Assert-Equal "Blocked" $result.Status
}

Test-Case "builds an explicit non-purge uninstall command" {
    $arguments = @(Get-CodexUninstallArguments -AppRoot "C:\mirror\app")
    Assert-Equal '["uninstall","--app","C:\\mirror\\app"]' (ConvertTo-Json -InputObject $arguments -Compress)
    Assert-True ($arguments -notcontains "--purge")
}

Test-Case "removes an exact tweak junction" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $target = Join-Path $root "target"
        $link = Join-Path $root "link"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Assert-True (Remove-TweakLink -LinkPath $link)
        Assert-True ($null -eq (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue))
        Assert-True (Test-Path -LiteralPath $target -PathType Container)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "refuses to remove an ordinary tweak directory" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Assert-Throws { Remove-TweakLink -LinkPath $root } "real directory"
        Assert-True (Test-Path -LiteralPath $root -PathType Container)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "removes a broken tweak junction without touching its old target" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $target = Join-Path $root "target"
        $link = Join-Path $root "link"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        Remove-Item -LiteralPath $target -Recurse -Force
        Assert-True (Remove-TweakLink -LinkPath $link)
        Assert-True ($null -eq (Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue))
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "uses the Appx manifest executable instead of the Codex-named launcher" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $packageRoot = Join-Path $root "WindowsApps/OpenAI.Codex_test"
        $officialApp = Join-Path $packageRoot "app"
        $localAppData = Join-Path $root "LocalAppData"
        New-Item -ItemType Directory -Path $officialApp -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $officialApp "Codex.exe"), "launcher")
        [System.IO.File]::WriteAllText((Join-Path $officialApp "ChatGPT.exe"), "desktop")
        [System.IO.File]::WriteAllText(
            (Join-Path $packageRoot "AppxManifest.xml"),
            '<Package><Applications><Application Id="App" Executable="app/ChatGPT.exe" /></Applications></Package>')
        $package = [pscustomobject] @{
            InstallLocation = $packageRoot
            PackageFullName = "OpenAI.Codex_test"
            Version = "26.721.3996.0"
        }
        $appLayout = Get-CodexAppLayout -Package $package -LocalAppData $localAppData
        New-Item -ItemType Directory -Path $appLayout.MirrorAppRoot -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $appLayout.MirrorAppRoot "ChatGPT.exe"), "desktop")

        $launch = Get-CodexPackageLaunchLayout -Package $package -AppLayout $appLayout

        Assert-Equal (Join-Path $officialApp "ChatGPT.exe") $launch.OfficialExecutable
        Assert-Equal (Join-Path $appLayout.MirrorAppRoot "ChatGPT.exe") $launch.MirrorExecutable
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "classifies a stale Codex++ launcher as LauncherRequired" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\mirror\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\mirror\app" }
        StatusText = "ASAR matches patched"
        LauncherStatus = "Required"
        RunningExecutablePaths = @()
    }
    Assert-Equal "LauncherRequired" (Get-CodexMaintenanceState @parameters).Status
}

Test-Case "writes CMD and Start Menu launchers without requiring a desktop shortcut" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $executable = Join-Path $root "mirror/app/ChatGPT.exe"
        $commandPath = Join-Path $root "WindowsApps/codex-plusplus-codex.cmd"
        $desktopShortcutPath = Join-Path $root "Desktop/Codex++.lnk"
        $startMenuShortcutPath = Join-Path $root "Start Menu/Codex++.lnk"
        New-Item -ItemType Directory -Path (Split-Path $executable -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($executable, "desktop")

        Assert-True (Set-CodexLauncherArtifacts -ExpectedExecutable $executable -CommandPath $commandPath `
            -StartMenuShortcutPath $startMenuShortcutPath)
        Assert-Equal "Current" (Get-CodexLauncherState -ExpectedExecutable $executable `
            -CommandPath $commandPath -StartMenuShortcutPath $startMenuShortcutPath).Status
        Assert-True (!(Test-Path -LiteralPath $desktopShortcutPath))
        Assert-True (!(Set-CodexLauncherArtifacts -ExpectedExecutable $executable -CommandPath $commandPath `
            -StartMenuShortcutPath $startMenuShortcutPath))
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "requires launcher repair when the Start Menu shortcut is missing" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $executable = Join-Path $root "mirror/app/ChatGPT.exe"
        $commandPath = Join-Path $root "WindowsApps/codex-plusplus-codex.cmd"
        $startMenuShortcutPath = Join-Path $root "Start Menu/Codex++.lnk"
        New-Item -ItemType Directory -Path (Split-Path $executable -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($executable, "desktop")
        Set-CodexLauncherArtifacts -ExpectedExecutable $executable -CommandPath $commandPath `
            -StartMenuShortcutPath $startMenuShortcutPath | Out-Null
        Remove-Item -LiteralPath $startMenuShortcutPath -Force

        $state = Get-CodexLauncherState -ExpectedExecutable $executable -CommandPath $commandPath `
            -StartMenuShortcutPath $startMenuShortcutPath

        Assert-Equal "Required" $state.Status
        Assert-True ($state.Mismatches -contains (Resolve-NormalizedPath $startMenuShortcutPath))
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "removes a legacy desktop shortcut targeting the managed mirror store" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $managedStoreRoot = Join-Path $root "codex-plusplus/store-apps"
        $executable = Join-Path $managedStoreRoot "OpenAI.Codex_test/app/ChatGPT.exe"
        $desktopShortcutPath = Join-Path $root "Desktop/Codex++.lnk"
        New-Item -ItemType Directory -Path (Split-Path $executable -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $desktopShortcutPath -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($executable, "desktop")
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($desktopShortcutPath)
        $shortcut.TargetPath = $executable
        $shortcut.Save()

        Assert-True (Remove-ManagedCodexDesktopShortcut -DesktopShortcutPath $desktopShortcutPath `
            -ManagedStoreRoot $managedStoreRoot)
        Assert-True (!(Test-Path -LiteralPath $desktopShortcutPath))
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "preserves an unrelated desktop shortcut with the same name" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $managedStoreRoot = Join-Path $root "codex-plusplus/store-apps"
        $executable = Join-Path $root "OtherApp/ChatGPT.exe"
        $desktopShortcutPath = Join-Path $root "Desktop/Codex++.lnk"
        New-Item -ItemType Directory -Path (Split-Path $executable -Parent) -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $desktopShortcutPath -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($executable, "desktop")
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($desktopShortcutPath)
        $shortcut.TargetPath = $executable
        $shortcut.Save()

        Assert-True (!(Remove-ManagedCodexDesktopShortcut -DesktopShortcutPath $desktopShortcutPath `
                    -ManagedStoreRoot $managedStoreRoot -WarningAction SilentlyContinue))
        Assert-True (Test-Path -LiteralPath $desktopShortcutPath -PathType Leaf)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "recognizes the new ChatGPT desktop executable name" {
    $processes = @(
        [pscustomobject] @{ Name = "ChatGPT.exe"; ExecutablePath = "C:\mirror\app\ChatGPT.exe" },
        [pscustomobject] @{ Name = "codex.exe"; ExecutablePath = "C:\mirror\app\resources\codex.exe" },
        [pscustomobject] @{ Name = "pwsh.exe"; ExecutablePath = "C:\Program Files\PowerShell\7\pwsh.exe" })
    $paths = @(Get-CodexExecutablePathsFromProcesses -Processes $processes)
    Assert-Equal 2 $paths.Count
    Assert-True ($paths -contains "C:\mirror\app\ChatGPT.exe")
    Assert-True ($paths -contains "C:\mirror\app\resources\codex.exe")
}

Test-Case "returns no executable paths when the process query is empty" {
    $paths = @(Get-CodexExecutablePathsFromProcesses -Processes @())
    Assert-Equal 0 $paths.Count
}

Test-Case "process snapshot distinguishes an empty successful query" {
    $snapshot = Get-CodexProcessSnapshot -ProcessQuery { @() }
    Assert-True $snapshot.Succeeded
    Assert-Equal 0 @($snapshot.ExecutablePaths).Count
    Assert-Equal "" $snapshot.FailureReason
}

Test-Case "process snapshot fails closed when CIM throws" {
    $snapshot = Get-CodexProcessSnapshot -ProcessQuery {
        throw "CIM unavailable"
    }
    Assert-True (!$snapshot.Succeeded)
    Assert-Equal 0 @($snapshot.ExecutablePaths).Count
    Assert-True ($snapshot.FailureReason -match "CIM unavailable")
}

Test-Case "process snapshot fails closed when a target path is unreadable" {
    $snapshot = Get-CodexProcessSnapshot -ProcessQuery {
        @([pscustomobject] @{ Name = "ChatGPT.exe"; ExecutablePath = $null })
    }
    Assert-True (!$snapshot.Succeeded)
    Assert-True ($snapshot.FailureReason -match "ExecutablePath")
}

Test-Case "mutation guard blocks an unknown process state" {
    $guard = Get-CodexMutationGuard -ProcessSnapshot ([pscustomobject] @{
        Succeeded = $false
        ExecutablePaths = @()
        FailureReason = "CIM unavailable"
    })
    Assert-True (!$guard.Allowed)
    Assert-Equal "ProcessQueryFailed" $guard.BlockReason
}

Test-Case "mutation guard blocks any running Codex process" {
    $guard = Get-CodexMutationGuard -ProcessSnapshot ([pscustomobject] @{
        Succeeded = $true
        ExecutablePaths = @("C:\mirror\app\ChatGPT.exe")
        FailureReason = ""
    })
    Assert-True (!$guard.Allowed)
    Assert-Equal "MirrorRunning" $guard.BlockReason
}

Test-Case "maintenance mutex blocks a second process and recovers abandonment" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        "codexpp-mutex-test-" + [guid]::NewGuid().ToString("N"))
    $holderScript = Join-Path $root "hold-lock.ps1"
    $readyPath = Join-Path $root "ready"
    New-Item -ItemType Directory -Path $root | Out-Null
    [System.IO.File]::WriteAllText($holderScript, @'
param([Parameter(Mandatory)] [string] $ReadyPath)
$mutex = [System.Threading.Mutex]::new(
    $false,
    "Local\CodexPlusPlus.EditorLinks.Maintenance.v1")
$null = $mutex.WaitOne()
[System.IO.File]::WriteAllText($ReadyPath, "ready")
Start-Sleep -Seconds 60
'@)
    $holder = Start-Process `
        -FilePath (Get-Command pwsh).Source `
        -ArgumentList @("-NoProfile", "-File", $holderScript, $readyPath) `
        -WindowStyle Hidden `
        -PassThru
    try
    {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (!(Test-Path -LiteralPath $readyPath) -and
            [DateTime]::UtcNow -lt $deadline)
        {
            Start-Sleep -Milliseconds 50
        }
        Assert-True (Test-Path -LiteralPath $readyPath) "Lock holder did not start."

        $second = Enter-CodexMaintenanceLock -TimeoutMilliseconds 0
        try
        {
            Assert-True (!$second.Acquired)
            Assert-Equal "MaintenanceBusy" $second.BlockReason
        }
        finally
        {
            Exit-CodexMaintenanceLock -LockHandle $second
        }

        Stop-Process -Id $holder.Id -Force
        $holder.WaitForExit()
        $released = Enter-CodexMaintenanceLock -TimeoutMilliseconds 1000
        try
        {
            Assert-True $released.Acquired "The mutex was not released after the holder process exited."
        }
        finally
        {
            Exit-CodexMaintenanceLock -LockHandle $released
        }

        if ($null -eq ("CodexMaintenanceMutexAbandoner" -as [type]))
        {
            Add-Type -TypeDefinition @'
using System.Threading;

public static class CodexMaintenanceMutexAbandoner
{
    public static void Abandon(string name)
    {
        using var ready = new ManualResetEventSlim(false);
        var thread = new Thread(() =>
        {
            var mutex = new Mutex(false, name);
            mutex.WaitOne();
            ready.Set();
        });
        thread.Start();
        ready.Wait();
        thread.Join();
    }
}
'@
        }
        [CodexMaintenanceMutexAbandoner]::Abandon(
            "Local\CodexPlusPlus.EditorLinks.Maintenance.v1")
        $recovered = Enter-CodexMaintenanceLock -TimeoutMilliseconds 1000
        try
        {
            Assert-True $recovered.Acquired "The abandoned mutex was not acquired."
            Assert-True $recovered.Abandoned "The abandoned mutex was acquired without the diagnostic flag."
        }
        finally
        {
            Exit-CodexMaintenanceLock -LockHandle $recovered
        }
    }
    finally
    {
        if (!$holder.HasExited) { Stop-Process -Id $holder.Id -Force }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "same mirror drift repairs the managed mirror directly" {
    $plan = Get-CodexRepairPlan `
        -AppLayout ([pscustomobject] @{
            OfficialAppRoot = "C:\WindowsApps\Codex\app"
            MirrorAppRoot = "C:\Local\codex-plusplus\store-apps\Codex\app"
        }) `
        -CodexState ([pscustomobject] @{
            appRoot = "C:\Local\codex-plusplus\store-apps\Codex\app"
        }) `
        -InjectionRequired $true `
        -MirrorComplete $true
    Assert-Equal "RepairMirror" $plan.Action
    Assert-Equal "C:\Local\codex-plusplus\store-apps\Codex\app" $plan.TargetAppRoot
    Assert-True $plan.RequiresNoCodexProcesses
}

Test-Case "stale recorded mirror rebuilds from the official Appx" {
    $plan = Get-CodexRepairPlan `
        -AppLayout ([pscustomobject] @{
            OfficialAppRoot = "C:\WindowsApps\CodexNew\app"
            MirrorAppRoot = "C:\Local\codex-plusplus\store-apps\CodexNew\app"
        }) `
        -CodexState ([pscustomobject] @{
            appRoot = "C:\Local\codex-plusplus\store-apps\CodexOld\app"
        }) `
        -InjectionRequired $true `
        -MirrorComplete $false
    Assert-Equal "RebuildFromOfficial" $plan.Action
    Assert-Equal "C:\WindowsApps\CodexNew\app" $plan.TargetAppRoot
}

Test-Case "current injection produces no repair command" {
    $plan = Get-CodexRepairPlan `
        -AppLayout ([pscustomobject] @{
            OfficialAppRoot = "C:\WindowsApps\Codex\app"
            MirrorAppRoot = "C:\Local\codex-plusplus\store-apps\Codex\app"
        }) `
        -CodexState ([pscustomobject] @{
            appRoot = "C:\Local\codex-plusplus\store-apps\Codex\app"
        }) `
        -InjectionRequired $false `
        -MirrorComplete $true
    Assert-Equal "None" $plan.Action
    Assert-Equal "" $plan.TargetAppRoot
}

Test-Case "maintenance state blocks a failed process query" {
    $result = Get-CodexMaintenanceState `
        -AppLayout ([pscustomobject] @{ MirrorAppRoot = "C:\mirror\app" }) `
        -CodexState ([pscustomobject] @{ appRoot = "C:\mirror\app" }) `
        -StatusText "current asar: abc (matches patched)" `
        -ProcessQuerySucceeded $false `
        -ProcessQueryFailureReason "CIM unavailable"
    Assert-Equal "Blocked" $result.Status
    Assert-Equal "ProcessQueryFailed" $result.BlockReason
    Assert-True ($result.BlockDetail -match "CIM unavailable")
}

Test-Case "maintenance state remains current while the patched mirror runs" {
    $result = Get-CodexMaintenanceState `
        -AppLayout ([pscustomobject] @{ MirrorAppRoot = "C:\mirror\app" }) `
        -CodexState ([pscustomobject] @{ appRoot = "C:\mirror\app" }) `
        -StatusText "current asar: abc (matches patched)" `
        -RunningExecutablePaths @("C:\mirror\app\ChatGPT.exe") `
        -ProcessQuerySucceeded $true
    Assert-Equal "Current" $result.Status
    Assert-Equal "" $result.BlockReason
}

Test-Case "uninject state blocks a failed process query" {
    $result = Get-CodexUninjectState `
        -CodexState $null `
        -HasCommand $false `
        -LinkStatus "Current" `
        -ProcessQuerySucceeded $false `
        -ProcessQueryFailureReason "CIM unavailable"
    Assert-Equal "Blocked" $result.Status
    Assert-Equal "ProcessQueryFailed" $result.BlockReason
    Assert-True ($result.BlockDetail -match "CIM unavailable")
}

Test-Case "uninject state permits verified link cleanup after an empty successful query" {
    $result = Get-CodexUninjectState `
        -CodexState $null `
        -HasCommand $false `
        -LinkStatus "Current" `
        -ProcessQuerySucceeded $true
    Assert-Equal "LinkOnly" $result.Status
    Assert-Equal "" $result.BlockReason
}

Test-Case "mirror completeness requires the ASAR and launch executable" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        "codex-mirror-layout-" + [guid]::NewGuid().ToString("N"))
    try
    {
        $appRoot = Join-Path $root "app"
        $asar = Join-Path $appRoot "resources/app.asar"
        $executable = Join-Path $appRoot "ChatGPT.exe"
        New-Item -ItemType Directory -Path (Split-Path $asar -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($asar, "asar")
        $appLayout = [pscustomobject] @{
            MirrorAppRoot = $appRoot
            MirrorAsar = $asar
        }
        $launchLayout = [pscustomobject] @{
            MirrorExecutable = $executable
        }

        Assert-True (!(Test-CodexMirrorComplete `
            -AppLayout $appLayout `
            -LaunchLayout $launchLayout))
        [System.IO.File]::WriteAllText($executable, "exe")
        Assert-True (Test-CodexMirrorComplete `
            -AppLayout $appLayout `
            -LaunchLayout $launchLayout)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "guarded mutation does not invoke writes when the recheck blocks" {
    $calls = [pscustomobject] @{ Mutation = 0; Observation = 0 }
    $result = Invoke-CodexMutationSafely `
        -ProcessQuery {
            @([pscustomobject] @{
                Name = "ChatGPT.exe"
                ExecutablePath = "C:\mirror\app\ChatGPT.exe"
            })
        } `
        -Mutation { $calls.Mutation++ } `
        -FailureObservation { $calls.Observation++ }
    Assert-True (!$result.Invoked)
    Assert-Equal "MirrorRunning" $result.BlockReason
    Assert-Equal 0 $calls.Mutation
    Assert-Equal 0 $calls.Observation
}

Test-Case "guarded mutation rereads state after command failure" {
    $calls = [pscustomobject] @{ Mutation = 0; Observation = 0 }
    $result = Invoke-CodexMutationSafely `
        -ProcessQuery { @() } `
        -Mutation {
            $calls.Mutation++
            throw "partial mutation"
        } `
        -FailureObservation {
            $calls.Observation++
            [pscustomobject] @{ StateStatus = "Present" }
        }
    Assert-True $result.Invoked
    Assert-True (!$result.Succeeded)
    Assert-True ($result.ErrorMessage -match "partial mutation")
    Assert-Equal 1 $calls.Mutation
    Assert-Equal 1 $calls.Observation
    Assert-Equal "Present" $result.FailureObservation.StateStatus
}

Test-Case "post-failure observation rereads state status and mirror layout" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) (
        "codex-failure-observation-" + [guid]::NewGuid().ToString("N"))
    try
    {
        $statePath = Join-Path $root "state.json"
        $appRoot = Join-Path $root "app"
        $asar = Join-Path $appRoot "resources/app.asar"
        $executable = Join-Path $appRoot "ChatGPT.exe"
        New-Item -ItemType Directory -Path (Split-Path $asar -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($statePath, '{"appRoot":"C:\\mirror\\app"}')
        [System.IO.File]::WriteAllText($asar, "asar")
        [System.IO.File]::WriteAllText($executable, "exe")

        $observation = Get-CodexPostFailureObservation `
            -StatePath $statePath `
            -StatusQuery { "current asar: drift" } `
            -AppLayout ([pscustomobject] @{
                MirrorAppRoot = $appRoot
                MirrorAsar = $asar
            }) `
            -LaunchLayout ([pscustomobject] @{
                MirrorExecutable = $executable
            })
        Assert-Equal "Present" $observation.StateStatus
        Assert-Equal "C:\mirror\app" $observation.RecordedAppRoot
        Assert-True $observation.StatusSucceeded
        Assert-True ($observation.StatusText -match "drift")
        Assert-True $observation.MirrorComplete
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Complete-Tests
