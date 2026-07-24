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

Test-Case "maintainer checks stay project-neutral and avoid temporary Unity projects" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $projectName = "sg" + "proj"
    $legacyLayout = "File" + "Packages"
    $files = @(
        (Join-Path $repositoryRoot "codex-tweak/test/index.test.js"),
        (Join-Path $repositoryRoot "scripts/tests/UnityLinkMaintenance.Tests.ps1"),
        (Join-Path $repositoryRoot "scripts/tests/UninjectCheckOnly.Integration.ps1"),
        (Join-Path $repositoryRoot "docs/design.md"),
        (Join-Path $repositoryRoot "README.md"))

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

Test-Case "inject entry point uses Start Menu Known Folder without a desktop launcher requirement" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $injectText = Get-Content -LiteralPath (Join-Path $repositoryRoot "Inject-CodexPlusPlus.ps1") -Raw
    $legacyParameter = "Shortcut" + "Paths"
    $profileDesktop = '$env:USER' + 'PROFILE "Desktop'

    Assert-True ($injectText.Contains("[Environment+SpecialFolder]::Programs"))
    Assert-True (!$injectText.Contains($legacyParameter))
    Assert-True (!$injectText.Contains($profileDesktop))
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

Test-Case "README covers project-neutral first install and relocation" {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot "README.md") -Raw
    $legacyLayout = "File" + "Packages"
    $requiredText = @(
        "https://github.com/kpkhxlgy0/unity-links.git",
        "PowerShell 7",
        "Node.js 20",
        "npm",
        'New-Item -ItemType Directory -Path (Join-Path $unityProject "Tools")',
        "New-Item -ItemType Directory -Path D:\Tools",
        "-UnityProject",
        "开始菜单",
        "移动仓库",
        "等待 Unity 完成 package 编译")

    foreach ($text in $requiredText) { Assert-True ($readme.Contains($text)) "README is missing: $text" }
    Assert-True (!$readme.Contains($legacyLayout))
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

Test-Case "finds the real Unity project above the current repository" {
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

Test-Case "Unity CheckOnly does not mutate the manifest" {
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

Test-Case "Unity CheckOnly accepts an explicit real project path" {
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

Test-Case "classifies current injection and link" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\mirror\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\mirror\app" }
        StatusText = "Current ASAR matches patched"
        LinkStatus = "Current"
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
        LinkStatus = "Current"
        RunningExecutablePaths = @("C:\Program Files\WindowsApps\OpenAI.Codex\app\Codex.exe")
    }
    $result = Get-CodexMaintenanceState @parameters
    Assert-Equal "InjectionRequired" $result.Status
}

Test-Case "classifies a missing junction after current injection as LinkRequired" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\mirror\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\mirror\app" }
        StatusText = "ASAR matches patched"
        LinkStatus = "Missing"
        RunningExecutablePaths = @()
    }
    $result = Get-CodexMaintenanceState @parameters
    Assert-Equal "LinkRequired" $result.Status
}

Test-Case "blocks stale injection while the exact target mirror is running" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\new\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\old\app" }
        StatusText = "ASAR differs"
        LinkStatus = "Current"
        RunningExecutablePaths = @("C:\new\app\Codex.exe")
    }
    $result = Get-CodexMaintenanceState @parameters
    Assert-Equal "Blocked" $result.Status
    Assert-True $result.TargetMirrorRunning
}

Test-Case "blocks an unsafe real directory at the tweak path" {
    $parameters = @{
        AppLayout = [pscustomobject] @{ MirrorAppRoot = "C:\mirror\app" }
        CodexState = [pscustomobject] @{ appRoot = "C:\mirror\app" }
        StatusText = "ASAR matches patched"
        LinkStatus = "Unsafe"
        RunningExecutablePaths = @()
    }
    $result = Get-CodexMaintenanceState @parameters
    Assert-Equal "Blocked" $result.Status
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
        LinkStatus = "Current"
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

Complete-Tests
