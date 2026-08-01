$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TestHarness.ps1")

Test-Case "focused maintenance modules import independently and isolate domain APIs" {
    $scriptsRoot = Split-Path $PSScriptRoot -Parent
    $modulePaths = [ordered] @{
        UnityLinkCommon = Join-Path $scriptsRoot "UnityLinkCommon.psm1"
        UnityPackageMaintenance = Join-Path $scriptsRoot "UnityPackageMaintenance.psm1"
        CodexTweakLink = Join-Path $scriptsRoot "CodexTweakLink.psm1"
        CodexPlusPlusMaintenance = Join-Path $scriptsRoot "CodexPlusPlusMaintenance.psm1"
    }

    foreach ($modulePath in $modulePaths.Values)
    {
        Assert-True (Test-Path -LiteralPath $modulePath -PathType Leaf) "Focused module is missing: $modulePath"
    }

    $modules = @{}
    foreach ($entry in $modulePaths.GetEnumerator())
    {
        $modules[$entry.Key] = Import-Module $entry.Value -Force -PassThru
    }

    Assert-True $modules.UnityLinkCommon.ExportedFunctions.ContainsKey("Get-UnityLinkRepositoryLayout")
    Assert-True (!$modules.UnityLinkCommon.ExportedFunctions.ContainsKey("Update-UnityManifestText"))
    Assert-True (!$modules.UnityLinkCommon.ExportedFunctions.ContainsKey("Get-TweakLinkState"))
    Assert-True (!$modules.UnityLinkCommon.ExportedFunctions.ContainsKey("Get-CodexMaintenanceState"))

    Assert-True $modules.UnityPackageMaintenance.ExportedFunctions.ContainsKey("Update-UnityManifestText")
    Assert-True (!$modules.UnityPackageMaintenance.ExportedFunctions.ContainsKey("Get-TweakLinkState"))
    Assert-True (!$modules.UnityPackageMaintenance.ExportedFunctions.ContainsKey("Get-CodexMaintenanceState"))

    Assert-True $modules.CodexTweakLink.ExportedFunctions.ContainsKey("Get-TweakLinkState")
    Assert-True (!$modules.CodexTweakLink.ExportedFunctions.ContainsKey("Update-UnityManifestText"))
    Assert-True (!$modules.CodexTweakLink.ExportedFunctions.ContainsKey("Get-CodexMaintenanceState"))

    Assert-True $modules.CodexPlusPlusMaintenance.ExportedFunctions.ContainsKey("Get-CodexMaintenanceState")
    Assert-True (!$modules.CodexPlusPlusMaintenance.ExportedFunctions.ContainsKey("Update-UnityManifestText"))
    Assert-True (!$modules.CodexPlusPlusMaintenance.ExportedFunctions.ContainsKey("Get-TweakLinkState"))

    $layout = UnityLinkCommon\Get-UnityLinkRepositoryLayout -RepositoryRoot "D:\Tools\unity-links"
    Assert-Equal "D:\Tools\unity-links\unity-package" $layout.PackageRoot

    $dependency = UnityPackageMaintenance\Get-UnityPackageManifestValue `
        -UnityProjectRoot "D:\Projects\Example" `
        -PackageRoot "D:\Projects\Example\Tools\unity-links\unity-package"
    Assert-Equal "file:../Tools/unity-links/unity-package" $dependency

    $missingLink = CodexTweakLink\Get-TweakLinkState `
        -LinkPath (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString("N"))) `
        -ExpectedTarget "D:\Tools\unity-links\codex-tweak"
    Assert-Equal "Missing" $missingLink.Status

    $latestPackage = CodexPlusPlusMaintenance\Select-LatestCodexPackage -Packages @(
        [pscustomobject] @{ Version = "1.2.0"; Name = "older" },
        [pscustomobject] @{ Version = "1.10.0"; Name = "newer" })
    Assert-Equal "newer" $latestPackage.Name
}

Test-Case "Codex++ maintenance loads with only its common dependency" {
    $scriptsRoot = Split-Path $PSScriptRoot -Parent
    $isolatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
        "unity-links-modules-" + [guid]::NewGuid().ToString("N"))
    try
    {
        New-Item -ItemType Directory -Path $isolatedRoot -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Destination $isolatedRoot
        Copy-Item -LiteralPath (Join-Path $scriptsRoot "CodexPlusPlusMaintenance.psm1") -Destination $isolatedRoot

        $module = Import-Module (Join-Path $isolatedRoot "CodexPlusPlusMaintenance.psm1") -Force -PassThru
        Assert-True $module.ExportedFunctions.ContainsKey("Get-CodexMaintenanceState")

        $selected = CodexPlusPlusMaintenance\Select-LatestCodexPackage -Packages @(
            [pscustomobject] @{ Version = "2.0.0"; Name = "isolated" })
        Assert-Equal "isolated" $selected.Name
    }
    finally
    {
        Remove-Module CodexPlusPlusMaintenance -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $isolatedRoot)
        {
            Remove-Item -LiteralPath $isolatedRoot -Recurse -Force
        }
    }
}

Complete-Tests
