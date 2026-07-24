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

Complete-Tests
