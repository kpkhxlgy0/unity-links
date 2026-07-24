Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"

function Resolve-NormalizedPath
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $BasePath = (Get-Location).Path)

    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $BasePath $Path }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -eq $root.Length) { return $fullPath }

    return $fullPath.TrimEnd([char[]] @(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar))
}

function Test-PathEqual
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Left,
        [Parameter(Mandatory)] [string] $Right)

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
    return [pscustomobject] @{
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

    throw "No Unity project containing Assets, Packages/manifest.json, and " +
        "ProjectSettings/ProjectVersion.txt was found above '$StartPath'."
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

Export-ModuleMember -Function @(
    "Resolve-NormalizedPath",
    "Test-PathEqual",
    "Get-UnityLinkRepositoryLayout",
    "Test-UnityProjectRoot",
    "Find-UnityProjectRoot",
    "Get-UnityPackageManifestValue")
