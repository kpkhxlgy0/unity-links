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
        Set-Content -LiteralPath (Join-Path $root "ProjectSettings/ProjectVersion.txt") `
            -Value "m_EditorVersion: 2022.3.23f1"
        Assert-Equal (Resolve-NormalizedPath $root) (Find-UnityProjectRoot -StartPath $repo)
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
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
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
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
    $expected = $before.Replace('"file:old"', '"file:../FilePackages/unity-links/unity-package"')
    $result = Update-UnityManifestText -Text $before -DependencyValue "file:../FilePackages/unity-links/unity-package"
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

Test-Case "Unity CheckOnly does not mutate the manifest" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $directories = @(
            (Join-Path $root "Assets"),
            (Join-Path $root "Packages"),
            (Join-Path $root "ProjectSettings"))
        New-Item -ItemType Directory -Path $directories -Force | Out-Null
        $manifest = Join-Path $root "Packages/manifest.json"
        $crlf = [string] ([char] 13) + [char] 10
        [System.IO.File]::WriteAllText($manifest, '{' + $crlf + '  "dependencies": {}' + $crlf + '}' + $crlf)
        [System.IO.File]::WriteAllText(
            (Join-Path $root "ProjectSettings/ProjectVersion.txt"),
            "m_EditorVersion: 2022.3.23f1")
        $before = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
        $entryPoint = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "Install-UnityPackage.ps1"
        $pwshPath = (Get-Process -Id $PID).Path
        & $pwshPath -NoProfile -File $entryPoint -UnityProject $root -CheckOnly | Out-Null
        $entryPointExitCode = $LASTEXITCODE
        Assert-Equal 0 $entryPointExitCode
        Assert-Equal $before (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

Test-Case "Unity installer updates only the manifest dependency" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $directories = @(
            (Join-Path $root "Assets"),
            (Join-Path $root "Packages"),
            (Join-Path $root "ProjectSettings"))
        New-Item -ItemType Directory -Path $directories -Force | Out-Null
        $lf = [string] [char] 10
        $manifest = Join-Path $root "Packages/manifest.json"
        $lock = Join-Path $root "Packages/packages-lock.json"
        $manifestText = '{' + $lf +
            '  "name": "keep",' + $lf +
            '  "dependencies": {' + $lf +
            '    "a": "1"' + $lf +
            '  }' + $lf +
            '}' + $lf
        [System.IO.File]::WriteAllText($manifest, $manifestText)
        [System.IO.File]::WriteAllText($lock, '{"sentinel":true}')
        [System.IO.File]::WriteAllText(
            (Join-Path $root "ProjectSettings/ProjectVersion.txt"),
            "m_EditorVersion: 2022.3.23f1")
        $lockHash = (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash
        $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $entryPoint = Join-Path $repositoryRoot "Install-UnityPackage.ps1"
        $packageRoot = Join-Path $repositoryRoot "unity-package"
        $expectedValue = Get-UnityPackageManifestValue -UnityProjectRoot $root -PackageRoot $packageRoot
        $pwshPath = (Get-Process -Id $PID).Path

        & $pwshPath -NoProfile -File $entryPoint -UnityProject $root | Out-Null
        $entryPointExitCode = $LASTEXITCODE

        Assert-Equal 0 $entryPointExitCode
        $updated = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal "keep" $updated.name
        Assert-Equal "1" $updated.dependencies.a
        Assert-Equal $expectedValue $updated.dependencies["com.kpk.codex-unity-link"]
        Assert-Equal $lockHash (Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash
    }
    finally
    {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
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

Test-Case "writes Codex++ launchers for the manifest-declared executable" {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))
    try
    {
        $executable = Join-Path $root "mirror/app/ChatGPT.exe"
        $commandPath = Join-Path $root "WindowsApps/codex-plusplus-codex.cmd"
        $shortcutPaths = @(
            (Join-Path $root "Desktop/Codex++.lnk"),
            (Join-Path $root "Start Menu/Codex++.lnk"))
        New-Item -ItemType Directory -Path (Split-Path $executable -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($executable, "desktop")

        Assert-True (Set-CodexLauncherArtifacts -ExpectedExecutable $executable -CommandPath $commandPath `
            -ShortcutPaths $shortcutPaths)
        Assert-Equal "Current" (Get-CodexLauncherState -ExpectedExecutable $executable `
            -CommandPath $commandPath -ShortcutPaths $shortcutPaths).Status
        Assert-True (!(Set-CodexLauncherArtifacts -ExpectedExecutable $executable -CommandPath $commandPath `
            -ShortcutPaths $shortcutPaths))
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
