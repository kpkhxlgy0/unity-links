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

function Update-UnityManifestText
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $DependencyValue)

    try
    {
        $document = $Text | ConvertFrom-Json -AsHashtable
    }
    catch
    {
        throw "Packages/manifest.json is not valid JSON: $($_.Exception.Message)"
    }

    if (!$document.ContainsKey("dependencies") -or
        $document.dependencies -isnot [System.Collections.IDictionary])
    {
        throw "Packages/manifest.json does not contain a dependencies object."
    }

    $key = "com.kpk.codex-unity-link"
    if ($document.dependencies.Contains($key) -and
        $document.dependencies[$key] -ceq $DependencyValue)
    {
        return [pscustomobject] @{
            Changed = $false
            Text = $Text
        }
    }

    $crlf = [string] ([char] 13) + [char] 10
    $lf = [string] [char] 10
    $newline = if ($Text.Contains($crlf)) {
        $crlf
    } elseif ($Text.Contains($lf)) {
        $lf
    } else {
        [Environment]::NewLine
    }

    $dependenciesPattern =
        '(?s)(?<open>"dependencies"\s*:\s*\{)(?<body>(?:[^{}"]|"(?:\\.|[^"\\])*")*)(?<close>\})'
    $dependenciesMatch = [regex]::Match($Text, $dependenciesPattern)
    if (!$dependenciesMatch.Success)
    {
        throw "Could not safely locate the dependencies object."
    }

    $body = $dependenciesMatch.Groups["body"].Value
    $propertyPattern =
        '(?m)(?<prefix>^[ \t]*"com\.kpk\.codex-unity-link"[ \t]*:[ \t]*)(?<value>"(?:\\.|[^"\\])*")(?<suffix>[ \t]*,?)'
    $jsonValue = ConvertTo-Json -InputObject $DependencyValue -Compress
    $propertyMatch = [regex]::Match($body, $propertyPattern)

    if ($propertyMatch.Success)
    {
        $updatedBody = $body.Substring(0, $propertyMatch.Index) +
            $propertyMatch.Groups["prefix"].Value +
            $jsonValue +
            $propertyMatch.Groups["suffix"].Value +
            $body.Substring($propertyMatch.Index + $propertyMatch.Length)
    }
    else
    {
        $existingIndent = [regex]::Match($body, '(?m)^(?<indent>[ \t]+)"')
        $objectPrefix = $Text.Substring(0, $dependenciesMatch.Groups["open"].Index)
        $objectIndentMatch = [regex]::Match($objectPrefix, '(?m)(?<indent>^[ \t]*)[^\r\n]*$')
        $objectIndent = $objectIndentMatch.Groups["indent"].Value
        $propertyIndent = if ($existingIndent.Success) {
            $existingIndent.Groups["indent"].Value
        } else {
            "$objectIndent  "
        }
        $jsonKey = ConvertTo-Json -InputObject $key -Compress
        $property = $propertyIndent + $jsonKey + ": " + $jsonValue
        $trimCharacters = [char[]] @([char] 13, [char] 10, [char] 32, [char] 9)
        $core = $body.TrimEnd($trimCharacters)
        $trailing = $body.Substring($core.Length)

        if ($core.Length -eq 0)
        {
            $updatedBody = $newline + $property + $newline + $objectIndent
        }
        else
        {
            $updatedBody = $core + "," + $newline + $property + $trailing
        }
    }

    $updatedText = $Text.Substring(0, $dependenciesMatch.Groups["body"].Index) +
        $updatedBody +
        $Text.Substring($dependenciesMatch.Groups["body"].Index + $body.Length)

    try
    {
        $updatedDocument = $updatedText | ConvertFrom-Json -AsHashtable
    }
    catch
    {
        throw "The proposed manifest edit was not valid JSON: $($_.Exception.Message)"
    }

    if ($updatedDocument.dependencies[$key] -cne $DependencyValue)
    {
        throw "The proposed manifest edit did not produce the expected dependency value."
    }

    return [pscustomobject] @{
        Changed = $true
        Text = $updatedText
    }
}

function Select-LatestCodexPackage
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Packages)

    if ($Packages.Count -eq 0)
    {
        throw "OpenAI.Codex is not installed for the current user."
    }

    return $Packages |
        Sort-Object { [version] $_.Version } -Descending |
        Select-Object -First 1
}

function Get-CodexAppLayout
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Package,
        [Parameter(Mandatory)] [string] $LocalAppData)

    $officialAppRoot = Join-Path (Resolve-NormalizedPath $Package.InstallLocation) "app"
    $mirrorAppRoot = Join-Path (Resolve-NormalizedPath $LocalAppData) (
        "codex-plusplus/store-apps/$($Package.PackageFullName)/app")

    return [pscustomobject] @{
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
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Root)

    $candidate = Resolve-NormalizedPath $Path
    $normalizedRoot = Resolve-NormalizedPath $Root
    if (Test-PathEqual $candidate $normalizedRoot) { return $true }

    $rootWithSeparator = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CodexMaintenanceState
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $AppLayout,
        [AllowNull()] [object] $CodexState,
        [AllowEmptyString()] [string] $StatusText,
        [Parameter(Mandatory)]
        [ValidateSet("Current", "Missing", "WrongTarget", "Unsafe")]
        [string] $LinkStatus,
        [string[]] $RunningExecutablePaths = @())

    $stateMatches = $false
    if ($null -ne $CodexState -and
        $CodexState.PSObject.Properties.Name -contains "appRoot" -and
        $CodexState.appRoot)
    {
        $stateMatches = Test-PathEqual ([string] $CodexState.appRoot) $AppLayout.MirrorAppRoot
    }

    $hashMatches = $StatusText -match '(?i)matches patched'
    $injectionRequired = !$stateMatches -or !$hashMatches
    $targetMirrorRunning = @(
        $RunningExecutablePaths |
            Where-Object { $_ -and (Test-PathInside -Path $_ -Root $AppLayout.MirrorAppRoot) }
    ).Count -gt 0

    $status = if ($LinkStatus -eq "Unsafe") {
        "Blocked"
    } elseif ($injectionRequired -and $targetMirrorRunning) {
        "Blocked"
    } elseif ($injectionRequired) {
        "InjectionRequired"
    } elseif ($LinkStatus -ne "Current") {
        "LinkRequired"
    } else {
        "Current"
    }

    return [pscustomobject] @{
        Status = $status
        InjectionRequired = $injectionRequired
        LinkRequired = $LinkStatus -ne "Current"
        TargetMirrorRunning = $targetMirrorRunning
        UnsafeLink = $LinkStatus -eq "Unsafe"
    }
}

function Get-TweakLinkState
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LinkPath,
        [Parameter(Mandatory)] [string] $ExpectedTarget)

    $normalizedLink = Resolve-NormalizedPath $LinkPath
    $expected = Resolve-NormalizedPath $ExpectedTarget
    $item = Get-Item -LiteralPath $normalizedLink -Force -ErrorAction SilentlyContinue
    if ($null -eq $item)
    {
        return [pscustomobject] @{
            Status = "Missing"
            LinkPath = $normalizedLink
            Target = $null
        }
    }

    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    $linkTypeProperty = $item.PSObject.Properties["LinkType"]
    $targetProperty = $item.PSObject.Properties["Target"]
    if (!$isReparsePoint -or
        $null -eq $linkTypeProperty -or
        !$linkTypeProperty.Value -or
        $null -eq $targetProperty -or
        @($targetProperty.Value).Count -eq 0)
    {
        return [pscustomobject] @{
            Status = "Unsafe"
            LinkPath = $normalizedLink
            Target = $null
        }
    }

    $rawTarget = [string] @($targetProperty.Value)[0]
    $target = if ([System.IO.Path]::IsPathRooted($rawTarget)) {
        Resolve-NormalizedPath $rawTarget
    } else {
        Resolve-NormalizedPath $rawTarget (Split-Path $normalizedLink -Parent)
    }
    $status = if (Test-PathEqual $target $expected) { "Current" } else { "WrongTarget" }

    return [pscustomobject] @{
        Status = $status
        LinkPath = $normalizedLink
        Target = $target
    }
}

function Set-TweakJunction
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LinkPath,
        [Parameter(Mandatory)] [string] $ExpectedTarget)

    $target = Resolve-NormalizedPath $ExpectedTarget
    if (!(Test-Path -LiteralPath $target -PathType Container))
    {
        throw "Tweak source directory not found: $target"
    }
    if (!(Test-Path -LiteralPath (Join-Path $target "manifest.json") -PathType Leaf))
    {
        throw "Tweak manifest not found below: $target"
    }

    $state = Get-TweakLinkState -LinkPath $LinkPath -ExpectedTarget $target
    if ($state.Status -eq "Current") { return $false }
    if ($state.Status -eq "Unsafe")
    {
        throw "The live tweak path is a real directory and will not be replaced: $LinkPath"
    }

    $parent = Split-Path (Resolve-NormalizedPath $LinkPath) -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $previousTarget = $state.Target
    if ($state.Status -eq "WrongTarget")
    {
        Remove-Item -LiteralPath $state.LinkPath -Force
    }

    try
    {
        New-Item -ItemType Junction -Path $state.LinkPath -Target $target | Out-Null
    }
    catch
    {
        $linkAfterFailure = Get-Item -LiteralPath $state.LinkPath -Force -ErrorAction SilentlyContinue
        if ($previousTarget -and
            (Test-Path -LiteralPath $previousTarget -PathType Container) -and
            $null -eq $linkAfterFailure)
        {
            New-Item -ItemType Junction -Path $state.LinkPath -Target $previousTarget | Out-Null
        }
        throw
    }

    $verified = Get-TweakLinkState -LinkPath $state.LinkPath -ExpectedTarget $target
    if ($verified.Status -ne "Current")
    {
        throw "Tweak junction verification failed: $($verified.Status)"
    }
    return $true
}

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
        return [pscustomobject] @{
            Status = "Current"
            Reason = "Compatible Codex++ is already installed."
        }
    }
    if ($NodeMajor -lt 20)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "Node.js 20 or newer is required."
        }
    }
    if (!$HasNpm)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "npm is required."
        }
    }
    if ($TargetMirrorRunning)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "The target Codex++ mirror is running."
        }
    }
    return [pscustomobject] @{
        Status = "InstallRequired"
        Reason = "Codex++ is not installed or is older than 1.0.0."
    }
}

function Test-CodexPlusPlusSourceLayout
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SourceRoot)

    $root = Resolve-NormalizedPath $SourceRoot
    $requiredPaths = @(
        (Join-Path $root "package.json"),
        (Join-Path $root "package-lock.json"),
        (Join-Path $root "packages/installer/src/cli.ts"))
    foreach ($path in $requiredPaths)
    {
        if (!(Test-Path -LiteralPath $path -PathType Leaf))
        {
            throw "Codex++ source file is missing: $path"
        }
    }

    $package = Get-Content -Raw -LiteralPath (Join-Path $root "package.json") | ConvertFrom-Json
    if ([version] $package.version -ne [version] "1.0.0")
    {
        throw "Expected Codex++ source version 1.0.0, found $($package.version)."
    }
    return $true
}

function Get-CodexPlusPlusSourceSwapState
{
    [CmdletBinding()]
    param(
        [bool] $SourceExists,
        [bool] $PreviousExists)

    if ($PreviousExists)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            HasCurrentSource = $SourceExists
            Reason = "A retained .previous Codex++ source already exists."
        }
    }
    return [pscustomobject] @{
        Status = "Ready"
        HasCurrentSource = $SourceExists
        Reason = "Source swap can retain the current source safely."
    }
}

function Get-CodexUninjectState
{
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $CodexState,
        [bool] $HasCommand,
        [Parameter(Mandatory)]
        [ValidateSet("Current", "Missing", "WrongTarget", "Unsafe")]
        [string] $LinkStatus,
        [string[]] $RunningExecutablePaths = @())

    if ($LinkStatus -eq "Unsafe")
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "The live tweak path is a real directory."
            AppRoot = $null
        }
    }
    if ($null -eq $CodexState)
    {
        $status = if ($LinkStatus -eq "Missing") { "NotInjected" } else { "LinkOnly" }
        return [pscustomobject] @{
            Status = $status
            Reason = "No Codex++ injection state exists."
            AppRoot = $null
        }
    }
    if (!$HasCommand)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "The codexplusplus command is unavailable."
            AppRoot = $null
        }
    }
    if (!($CodexState.PSObject.Properties.Name -contains "appRoot") -or !$CodexState.appRoot)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "Codex++ state has no appRoot."
            AppRoot = $null
        }
    }

    $appRoot = Resolve-NormalizedPath ([string] $CodexState.appRoot)
    $running = @(
        $RunningExecutablePaths |
            Where-Object { $_ -and (Test-PathInside -Path $_ -Root $appRoot) }
    ).Count -gt 0
    if ($running)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "The injected Codex mirror is running."
            AppRoot = $appRoot
        }
    }
    return [pscustomobject] @{
        Status = "Ready"
        Reason = "Injection can be removed."
        AppRoot = $appRoot
    }
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
    $linkTypeProperty = $item.PSObject.Properties["LinkType"]
    if (!$isReparsePoint -or $null -eq $linkTypeProperty -or !$linkTypeProperty.Value)
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

Export-ModuleMember -Function @(
    "Resolve-NormalizedPath",
    "Test-PathEqual",
    "Get-UnityLinkRepositoryLayout",
    "Test-UnityProjectRoot",
    "Find-UnityProjectRoot",
    "Get-UnityPackageManifestValue",
    "Update-UnityManifestText",
    "Select-LatestCodexPackage",
    "Get-CodexAppLayout",
    "Test-PathInside",
    "Get-CodexMaintenanceState",
    "Get-TweakLinkState",
    "Set-TweakJunction",
    "Get-CodexPlusPlusInstallState",
    "Test-CodexPlusPlusSourceLayout",
    "Get-CodexPlusPlusSourceSwapState",
    "Get-CodexUninjectState",
    "Get-CodexUninstallArguments",
    "Remove-TweakLink")
