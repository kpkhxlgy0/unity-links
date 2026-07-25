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
    param(
        [Parameter(Mandatory)] [string] $StartPath,
        [scriptblock] $ProjectRootTest
    )

    if ($null -eq $ProjectRootTest)
    {
        $ProjectRootTest = { param($candidate) Test-UnityProjectRoot $candidate }
    }

    $current = Resolve-NormalizedPath $StartPath
    if (Test-Path -LiteralPath $current -PathType Leaf) { $current = Split-Path $current -Parent }

    while ($current)
    {
        if (& $ProjectRootTest $current) { return $current }

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

function Test-UnauthorizedAccessFailure
{
    param([Parameter(Mandatory)] [System.Exception] $Exception)

    $current = $Exception
    while ($null -ne $current)
    {
        if ($current -is [System.UnauthorizedAccessException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Set-UnityManifestTextSafely
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $Text,
        [scriptblock] $WriteAction,
        [scriptblock] $PostWriteTest)

    $path = Resolve-NormalizedPath $ManifestPath
    $attributes = [System.IO.File]::GetAttributes($path)
    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0)
    {
        throw "Packages/manifest.json is read-only. Make it writable through your version-control checkout " +
            "workflow, or clear the ReadOnly attribute if the file is unmanaged. Path: $path"
    }

    $originalBytes = [System.IO.File]::ReadAllBytes($path)
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try
    {
        if ($null -eq $WriteAction)
        {
            [System.IO.File]::WriteAllText($path, $Text, $encoding)
        }
        else
        {
            & $WriteAction $path $Text $encoding
        }

        if ($null -ne $PostWriteTest -and !(& $PostWriteTest $path))
        {
            throw "Post-write dependency verification failed."
        }
    }
    catch
    {
        $writeException = $_.Exception
        try
        {
            $currentBytes = [System.IO.File]::ReadAllBytes($path)
            if ([Convert]::ToBase64String($currentBytes) -cne [Convert]::ToBase64String($originalBytes))
            {
                [System.IO.File]::WriteAllBytes($path, $originalBytes)
            }
        }
        catch
        {
            throw "Failed to update Packages/manifest.json and could not restore its original bytes. " +
                "Path: $path. Restore error: $($_.Exception.Message)"
        }

        if (Test-UnauthorizedAccessFailure -Exception $writeException)
        {
            throw "Access to Packages/manifest.json was denied by Windows permissions (ACL). " +
                "Grant the current user write access and try again. Path: $path"
        }
        throw "Failed to update Packages/manifest.json; its original bytes were restored. " +
            "Path: $path. Error: $($writeException.Message)"
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

function Get-CodexPackageLaunchLayout
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Package,
        [Parameter(Mandatory)] [object] $AppLayout)

    $packageRoot = Resolve-NormalizedPath ([string] $Package.InstallLocation)
    $manifestPath = Join-Path $packageRoot "AppxManifest.xml"
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf))
    {
        throw "Codex Appx manifest not found: $manifestPath"
    }

    [xml] $manifest = Get-Content -Raw -LiteralPath $manifestPath
    $applications = @($manifest.SelectNodes("//*[local-name()='Application' and @Executable]"))
    if ($applications.Count -eq 0)
    {
        throw "Codex Appx manifest has no application executable: $manifestPath"
    }
    $application = @($applications | Where-Object { $_.GetAttribute("Id") -eq "App" })[0]
    if ($null -eq $application) { $application = $applications[0] }

    $relativeToPackage = $application.GetAttribute("Executable").Replace(
        '/', [System.IO.Path]::DirectorySeparatorChar)
    $officialExecutable = Resolve-NormalizedPath $relativeToPackage $packageRoot
    if (!(Test-PathInside -Path $officialExecutable -Root $AppLayout.OfficialAppRoot))
    {
        throw "Codex Appx executable is outside the official app root: $officialExecutable"
    }
    if (!(Test-Path -LiteralPath $officialExecutable -PathType Leaf))
    {
        throw "Codex Appx executable not found: $officialExecutable"
    }

    $relativeToApp = [System.IO.Path]::GetRelativePath($AppLayout.OfficialAppRoot, $officialExecutable)
    return [pscustomobject] @{
        OfficialExecutable = $officialExecutable
        MirrorExecutable = Resolve-NormalizedPath $relativeToApp $AppLayout.MirrorAppRoot
        RelativeExecutable = $relativeToApp
    }
}

function Get-CodexExecutablePathsFromProcesses
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $Processes)

    return @(
        $Processes |
            Where-Object { $_.Name -in @("Codex.exe", "ChatGPT.exe") -and $_.ExecutablePath } |
            ForEach-Object { [string] $_.ExecutablePath } |
            Select-Object -Unique
    )
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
        [ValidateSet("Current", "Required")]
        [string] $LauncherStatus = "Current",
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
    } elseif ($LauncherStatus -ne "Current") {
        "LauncherRequired"
    } elseif ($LinkStatus -ne "Current") {
        "LinkRequired"
    } else {
        "Current"
    }

    return [pscustomobject] @{
        Status = $status
        InjectionRequired = $injectionRequired
        LauncherRequired = $LauncherStatus -ne "Current"
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

function Get-CodexLauncherCommandText
{
    param([Parameter(Mandatory)] [string] $ExpectedExecutable)

    return "@echo off`r`nstart `"`" `"$ExpectedExecutable`" %*`r`n"
}

function Get-CodexLauncherState
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExpectedExecutable,
        [Parameter(Mandatory)] [string] $CommandPath,
        [Parameter(Mandatory)] [string] $StartMenuShortcutPath)

    $expected = Resolve-NormalizedPath $ExpectedExecutable
    $mismatches = [System.Collections.Generic.List[string]]::new()
    $expectedCommand = Get-CodexLauncherCommandText -ExpectedExecutable $expected
    if (!(Test-Path -LiteralPath $CommandPath -PathType Leaf) -or
        (Get-Content -Raw -LiteralPath $CommandPath) -cne $expectedCommand)
    {
        $mismatches.Add((Resolve-NormalizedPath $CommandPath))
    }

    $normalizedShortcut = Resolve-NormalizedPath $StartMenuShortcutPath
    if (!(Test-Path -LiteralPath $normalizedShortcut -PathType Leaf))
    {
        $mismatches.Add($normalizedShortcut)
    }
    else
    {
        $shell = New-Object -ComObject WScript.Shell
        $target = $shell.CreateShortcut($normalizedShortcut).TargetPath
        if (!$target -or !(Test-PathEqual $target $expected))
        {
            $mismatches.Add($normalizedShortcut)
        }
    }

    return [pscustomobject] @{
        Status = if ($mismatches.Count -eq 0) { "Current" } else { "Required" }
        ExpectedExecutable = $expected
        Mismatches = $mismatches.ToArray()
    }
}

function Set-CodexLauncherArtifacts
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ExpectedExecutable,
        [Parameter(Mandatory)] [string] $CommandPath,
        [Parameter(Mandatory)] [string] $StartMenuShortcutPath)

    $expected = Resolve-NormalizedPath $ExpectedExecutable
    if (!(Test-Path -LiteralPath $expected -PathType Leaf))
    {
        throw "Codex launch executable not found: $expected"
    }
    $state = Get-CodexLauncherState -ExpectedExecutable $expected -CommandPath $CommandPath `
        -StartMenuShortcutPath $StartMenuShortcutPath
    if ($state.Status -eq "Current") { return $false }

    $commandParent = Split-Path (Resolve-NormalizedPath $CommandPath) -Parent
    New-Item -ItemType Directory -Path $commandParent -Force | Out-Null
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText(
        (Resolve-NormalizedPath $CommandPath),
        (Get-CodexLauncherCommandText -ExpectedExecutable $expected),
        $encoding)

    $shell = New-Object -ComObject WScript.Shell
    $normalizedShortcut = Resolve-NormalizedPath $StartMenuShortcutPath
    New-Item -ItemType Directory -Path (Split-Path $normalizedShortcut -Parent) -Force | Out-Null
    $shortcut = $shell.CreateShortcut($normalizedShortcut)
    $shortcut.TargetPath = $expected
    $shortcut.WorkingDirectory = Split-Path $expected -Parent
    $shortcut.IconLocation = "$expected,0"
    $shortcut.Save()

    $verified = Get-CodexLauncherState -ExpectedExecutable $expected -CommandPath $CommandPath `
        -StartMenuShortcutPath $StartMenuShortcutPath
    if ($verified.Status -ne "Current")
    {
        throw "Codex++ launcher verification failed: $($verified.Mismatches -join ', ')"
    }
    return $true
}

function Remove-ManagedCodexDesktopShortcut
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $DesktopShortcutPath,
        [Parameter(Mandatory)] [string] $ManagedStoreRoot)

    $shortcutPath = Resolve-NormalizedPath $DesktopShortcutPath
    if ([System.IO.Path]::GetExtension($shortcutPath) -ine ".lnk")
    {
        throw "Expected a .lnk desktop shortcut path: $shortcutPath"
    }
    if (!(Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { return $false }

    try
    {
        $shell = New-Object -ComObject WScript.Shell
        $target = [string] $shell.CreateShortcut($shortcutPath).TargetPath
    }
    catch
    {
        Write-Warning "Could not inspect the legacy Codex++ desktop shortcut; it was preserved: $shortcutPath"
        return $false
    }

    if (!$target -or !(Test-PathInside -Path $target -Root $ManagedStoreRoot))
    {
        Write-Warning "The Codex++ desktop shortcut is not managed by this installation and was preserved: $shortcutPath"
        return $false
    }

    Remove-Item -LiteralPath $shortcutPath -Force
    if (Test-Path -LiteralPath $shortcutPath)
    {
        throw "The managed Codex++ desktop shortcut still exists after removal: $shortcutPath"
    }
    return $true
}

Export-ModuleMember -Function @(
    "Resolve-NormalizedPath",
    "Test-PathEqual",
    "Get-UnityLinkRepositoryLayout",
    "Assert-UnityLinkComponentInitialized",
    "Test-UnityProjectRoot",
    "Find-UnityProjectRoot",
    "Get-UnityPackageManifestValue",
    "Update-UnityManifestText",
    "Set-UnityManifestTextSafely",
    "Select-LatestCodexPackage",
    "Get-CodexAppLayout",
    "Get-CodexPackageLaunchLayout",
    "Get-CodexExecutablePathsFromProcesses",
    "Test-PathInside",
    "Get-CodexMaintenanceState",
    "Get-TweakLinkState",
    "Set-TweakJunction",
    "Get-CodexPlusPlusInstallState",
    "Test-CodexPlusPlusSourceLayout",
    "Get-CodexPlusPlusSourceSwapState",
    "Get-CodexUninjectState",
    "Get-CodexUninstallArguments",
    "Remove-TweakLink",
    "Get-CodexLauncherState",
    "Set-CodexLauncherArtifacts",
    "Remove-ManagedCodexDesktopShortcut")
