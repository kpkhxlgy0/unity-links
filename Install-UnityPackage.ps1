#Requires -Version 7.0

[CmdletBinding()]
param(
    [string] $UnityProject,
    [switch] $CheckOnly)

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"
$scriptsRoot = Join-Path $PSScriptRoot "scripts"
Import-Module (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Force
Import-Module (Join-Path $scriptsRoot "UnityPackageMaintenance.psm1") -Force

try
{
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $PSScriptRoot
    Assert-UnityLinkComponentInitialized -Layout $layout -Component UnityPackage
    if (!(Test-Path -LiteralPath $layout.PackageManifest -PathType Leaf))
    {
        throw "Unity package manifest not found: $($layout.PackageManifest)"
    }
    try
    {
        Get-Content -LiteralPath $layout.PackageManifest -Raw | ConvertFrom-Json | Out-Null
    }
    catch
    {
        throw "Unity package manifest is not valid JSON: $($layout.PackageManifest)"
    }

    $projectRoot = if ($UnityProject) {
        Resolve-NormalizedPath $UnityProject
    } else {
        Find-UnityProjectRoot -StartPath $PSScriptRoot
    }
    if (!(Test-UnityProjectRoot $projectRoot))
    {
        throw "Not a valid Unity project: $projectRoot"
    }

    $manifestPath = Join-Path $projectRoot "Packages/manifest.json"
    $expectedValue = Get-UnityPackageManifestValue -UnityProjectRoot $projectRoot -PackageRoot $layout.PackageRoot
    $originalBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $originalText = $encoding.GetString($originalBytes)
    $edit = Update-UnityManifestText -Text $originalText -DependencyValue $expectedValue
    $status = if ($edit.Changed) { "UpdateRequired" } else { "Current" }

    Write-Host "Status: $status"
    Write-Host "Unity project: $projectRoot"
    Write-Host "Expected dependency: $expectedValue"

    if ($CheckOnly -or !$edit.Changed) { exit 0 }

    $postWriteTest = {
        param($path)

        try
        {
            $verified = [System.IO.File]::ReadAllText($path, $encoding) | ConvertFrom-Json -AsHashtable
            return $verified.dependencies["com.kpk.codex-unity-link"] -ceq $expectedValue
        }
        catch
        {
            return $false
        }
    }.GetNewClosure()
    Set-UnityManifestTextSafely -ManifestPath $manifestPath -Text $edit.Text -PostWriteTest $postWriteTest

    Write-Host "Updated only com.kpk.codex-unity-link in $manifestPath"
    Write-Host "Unity will maintain Packages/packages-lock.json."
    exit 0
}
catch
{
    Write-Error $_
    exit 1
}
