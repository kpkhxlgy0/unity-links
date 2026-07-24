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

Complete-Tests
