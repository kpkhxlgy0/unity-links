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

function Assert-UnityLinkComponentInitialized
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Layout,
        [Parameter(Mandatory)]
        [ValidateSet("CodexTweak", "UnityPackage")]
        [string] $Component)

    $manifest = if ($Component -eq "CodexTweak") {
        $Layout.TweakManifest
    } else {
        $Layout.PackageManifest
    }
    if (Test-Path -LiteralPath $manifest -PathType Leaf) { return }

    $command = "git -C `"$($Layout.RepositoryRoot)`" submodule update --init --recursive"
    throw "$Component is not initialized. Run: $command"
}

Export-ModuleMember -Function @(
    "Resolve-NormalizedPath",
    "Test-PathEqual",
    "Get-UnityLinkRepositoryLayout",
    "Assert-UnityLinkComponentInitialized")
