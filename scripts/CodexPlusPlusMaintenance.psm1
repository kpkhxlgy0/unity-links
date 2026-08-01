Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"

$script:CodexMaintenanceMutexName =
    "Local\CodexPlusPlus.EditorLinks.Maintenance.v1"

Import-Module (Join-Path $PSScriptRoot "UnityLinkCommon.psm1") -Scope Local

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
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Processes)

    return @(
        $Processes |
            Where-Object { $_.Name -in @("Codex.exe", "ChatGPT.exe") -and $_.ExecutablePath } |
            ForEach-Object { [string] $_.ExecutablePath } |
            Select-Object -Unique
    )
}

function Get-CodexProcessSnapshot
{
    [CmdletBinding()]
    param(
        [scriptblock] $ProcessQuery = {
            @(
                Get-CimInstance `
                    Win32_Process `
                    -Filter "Name = 'Codex.exe' OR Name = 'ChatGPT.exe'" `
                    -ErrorAction Stop)
        })

    try
    {
        $processes = @(& $ProcessQuery)
        $targetProcesses = @(
            $processes |
                Where-Object { $_.Name -in @("Codex.exe", "ChatGPT.exe") })
        $missingPath = @(
            $targetProcesses |
                Where-Object { !$_.ExecutablePath })
        if ($missingPath.Count -gt 0)
        {
            throw "ExecutablePath is unavailable for a running Codex process."
        }

        $paths = @(
            Get-CodexExecutablePathsFromProcesses -Processes $targetProcesses |
                ForEach-Object { Resolve-NormalizedPath ([string] $_) } |
                Select-Object -Unique)
        return [pscustomobject] @{
            Succeeded = $true
            ExecutablePaths = $paths
            FailureReason = ""
        }
    }
    catch
    {
        return [pscustomobject] @{
            Succeeded = $false
            ExecutablePaths = @()
            FailureReason = $_.Exception.Message
        }
    }
}

function Get-CodexMutationGuard
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object] $ProcessSnapshot)

    if (!$ProcessSnapshot.Succeeded)
    {
        return [pscustomobject] @{
            Allowed = $false
            BlockReason = "ProcessQueryFailed"
            FailureReason = [string] $ProcessSnapshot.FailureReason
        }
    }
    if (@($ProcessSnapshot.ExecutablePaths).Count -gt 0)
    {
        return [pscustomobject] @{
            Allowed = $false
            BlockReason = "MirrorRunning"
            FailureReason = "Codex is running and global maintenance requires it to be closed."
        }
    }
    return [pscustomobject] @{
        Allowed = $true
        BlockReason = ""
        FailureReason = ""
    }
}

function Test-CodexMirrorComplete
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $AppLayout,
        [Parameter(Mandatory)] [object] $LaunchLayout)

    $appProperties = @($AppLayout.PSObject.Properties.Name)
    $launchProperties = @($LaunchLayout.PSObject.Properties.Name)
    if ($appProperties -notcontains "MirrorAppRoot" -or
        $appProperties -notcontains "MirrorAsar" -or
        $launchProperties -notcontains "MirrorExecutable" -or
        !$AppLayout.MirrorAppRoot -or
        !$AppLayout.MirrorAsar -or
        !$LaunchLayout.MirrorExecutable)
    {
        return $false
    }

    return (
        (Test-Path -LiteralPath $AppLayout.MirrorAppRoot -PathType Container) -and
        (Test-Path -LiteralPath $AppLayout.MirrorAsar -PathType Leaf) -and
        (Test-Path -LiteralPath $LaunchLayout.MirrorExecutable -PathType Leaf))
}

function Invoke-CodexMutationSafely
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Mutation,
        [scriptblock] $FailureObservation = { $null },
        [AllowNull()] [scriptblock] $ProcessQuery = $null)

    $snapshot = if ($null -eq $ProcessQuery) {
        Get-CodexProcessSnapshot
    } else {
        Get-CodexProcessSnapshot -ProcessQuery $ProcessQuery
    }
    $guard = Get-CodexMutationGuard -ProcessSnapshot $snapshot
    if (!$guard.Allowed)
    {
        return [pscustomobject] @{
            Invoked = $false
            Succeeded = $false
            BlockReason = $guard.BlockReason
            FailureReason = $guard.FailureReason
            ErrorMessage = ""
            FailureObservation = $null
            Output = @()
        }
    }

    try
    {
        $output = @(& $Mutation)
        return [pscustomobject] @{
            Invoked = $true
            Succeeded = $true
            BlockReason = ""
            FailureReason = ""
            ErrorMessage = ""
            FailureObservation = $null
            Output = $output
        }
    }
    catch
    {
        $errorMessage = $_.Exception.Message
        try
        {
            $observation = & $FailureObservation
        }
        catch
        {
            $observation = [pscustomobject] @{
                ObservationFailed = $true
                FailureReason = $_.Exception.Message
            }
        }
        return [pscustomobject] @{
            Invoked = $true
            Succeeded = $false
            BlockReason = ""
            FailureReason = ""
            ErrorMessage = $errorMessage
            FailureObservation = $observation
            Output = @()
        }
    }
}

function Get-CodexPostFailureObservation
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [scriptblock] $StatusQuery,
        [AllowNull()] [object] $AppLayout = $null,
        [AllowNull()] [object] $LaunchLayout = $null)

    $failures = [System.Collections.Generic.List[string]]::new()
    $stateStatus = "Missing"
    $recordedAppRoot = ""
    if (Test-Path -LiteralPath $StatePath -PathType Leaf)
    {
        try
        {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            $stateStatus = "Present"
            if ($state.PSObject.Properties.Name -contains "appRoot" -and
                $state.appRoot)
            {
                $recordedAppRoot = [string] $state.appRoot
            }
        }
        catch
        {
            $stateStatus = "Unreadable"
            $failures.Add("state.json: $($_.Exception.Message)")
        }
    }

    $statusSucceeded = $false
    $statusText = ""
    try
    {
        $statusText = @(& $StatusQuery) -join [Environment]::NewLine
        $statusSucceeded = $true
    }
    catch
    {
        $failures.Add("codexplusplus status: $($_.Exception.Message)")
    }

    $mirrorComplete = $null
    if ($null -ne $AppLayout -and $null -ne $LaunchLayout)
    {
        $mirrorComplete = Test-CodexMirrorComplete `
            -AppLayout $AppLayout `
            -LaunchLayout $LaunchLayout
    }
    return [pscustomobject] @{
        StateStatus = $stateStatus
        RecordedAppRoot = $recordedAppRoot
        StatusSucceeded = $statusSucceeded
        StatusText = $statusText
        MirrorComplete = $mirrorComplete
        FailureReason = $failures -join "; "
    }
}

function Enter-CodexMaintenanceLock
{
    [CmdletBinding()]
    param([ValidateRange(0, 60000)] [int] $TimeoutMilliseconds = 0)

    $mutex = [System.Threading.Mutex]::new(
        $false,
        $script:CodexMaintenanceMutexName)
    $acquired = $false
    $abandoned = $false
    try
    {
        try
        {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [System.Threading.AbandonedMutexException]
        {
            $acquired = $true
            $abandoned = $true
        }
        if (!$acquired)
        {
            $mutex.Dispose()
            $mutex = $null
        }
        return [pscustomobject] @{
            Acquired = $acquired
            Abandoned = $abandoned
            BlockReason = if ($acquired) { "" } else { "MaintenanceBusy" }
            Mutex = $mutex
        }
    }
    catch
    {
        if ($null -ne $mutex) { $mutex.Dispose() }
        throw
    }
}

function Exit-CodexMaintenanceLock
{
    [CmdletBinding()]
    param([AllowNull()] [object] $LockHandle)

    if ($null -eq $LockHandle -or
        !$LockHandle.Acquired -or
        $null -eq $LockHandle.Mutex)
    {
        return
    }
    try
    {
        $LockHandle.Mutex.ReleaseMutex()
    }
    finally
    {
        $LockHandle.Mutex.Dispose()
    }
}

function Get-CodexRepairPlan
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $AppLayout,
        [AllowNull()] [object] $CodexState,
        [bool] $InjectionRequired,
        [bool] $MirrorComplete)

    if (!$InjectionRequired)
    {
        return [pscustomobject] @{
            Action = "None"
            TargetAppRoot = ""
            RequiresNoCodexProcesses = $false
        }
    }

    $stateMatchesMirror = $null -ne $CodexState -and
        $CodexState.PSObject.Properties.Name -contains "appRoot" -and
        $CodexState.appRoot -and
        (Test-PathEqual ([string] $CodexState.appRoot) $AppLayout.MirrorAppRoot)
    if ($stateMatchesMirror -and $MirrorComplete)
    {
        return [pscustomobject] @{
            Action = "RepairMirror"
            TargetAppRoot = [string] $AppLayout.MirrorAppRoot
            RequiresNoCodexProcesses = $true
        }
    }

    return [pscustomobject] @{
        Action = "RebuildFromOfficial"
        TargetAppRoot = [string] $AppLayout.OfficialAppRoot
        RequiresNoCodexProcesses = $true
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

function Resolve-CodexManagedPackagePath
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManagedStoreRoot,
        [Parameter(Mandatory)] [string] $CandidatePath,
        [switch] $AppRoot)

    $storeRoot = Resolve-NormalizedPath $ManagedStoreRoot
    $candidate = Resolve-NormalizedPath $CandidatePath
    $packageRoot = if ($AppRoot) {
        if ((Split-Path $candidate -Leaf) -ne "app")
        {
            throw "Managed mirror app root must end in app: $candidate"
        }
        Split-Path $candidate -Parent
    } else {
        $candidate
    }
    if (!(Test-PathEqual (Split-Path $packageRoot -Parent) $storeRoot))
    {
        throw "Managed mirror package must be an immediate child of $storeRoot`: $packageRoot"
    }
    if ((Split-Path $packageRoot -Leaf) -notmatch '^OpenAI\.Codex_.+$')
    {
        throw "Unrecognized managed Codex package: $packageRoot"
    }
    return $packageRoot
}

function Get-CodexMirrorCleanupPlan
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManagedStoreRoot,
        [Parameter(Mandatory)] [string] $CurrentAppRoot,
        [AllowEmptyString()] [string] $PreviousAppRoot = "",
        [string[]] $CandidatePackageRoots = @(),
        [switch] $CleanupAllOldVersions)

    $currentPackage = Resolve-CodexManagedPackagePath `
        -ManagedStoreRoot $ManagedStoreRoot `
        -CandidatePath $CurrentAppRoot `
        -AppRoot
    $candidates = if ($CleanupAllOldVersions) {
        @($CandidatePackageRoots)
    } elseif ($PreviousAppRoot) {
        @(Resolve-CodexManagedPackagePath `
            -ManagedStoreRoot $ManagedStoreRoot `
            -CandidatePath $PreviousAppRoot `
            -AppRoot)
    } else {
        @()
    }
    $targets = @(
        $candidates |
            ForEach-Object {
                $packageRoot = Resolve-CodexManagedPackagePath `
                    -ManagedStoreRoot $ManagedStoreRoot `
                    -CandidatePath $_
                if (!(Test-PathEqual $packageRoot $currentPackage)) { $packageRoot }
            } |
            Sort-Object -Unique)

    return [pscustomobject] @{
        Mode = if ($CleanupAllOldVersions) { "AllOld" } else { "Previous" }
        CurrentPackageRoot = $currentPackage
        Targets = $targets
    }
}

function Remove-CodexMirrorCleanupTargets
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManagedStoreRoot,
        [Parameter(Mandatory)] [string] $CurrentAppRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Targets,
        [Parameter(Mandatory)] [object] $ProcessSnapshot)

    if (!$ProcessSnapshot.Succeeded)
    {
        throw "Old-version cleanup blocked because process discovery failed: $($ProcessSnapshot.FailureReason)"
    }

    $currentPackage = Resolve-CodexManagedPackagePath `
        -ManagedStoreRoot $ManagedStoreRoot `
        -CandidatePath $CurrentAppRoot `
        -AppRoot
    $validated = @(
        $Targets |
            ForEach-Object {
                $target = Resolve-CodexManagedPackagePath `
                    -ManagedStoreRoot $ManagedStoreRoot `
                    -CandidatePath $_
                if (Test-PathEqual $target $currentPackage)
                {
                    throw "Refusing to delete the current managed Codex package: $target"
                }
                $running = @(
                    $ProcessSnapshot.ExecutablePaths |
                        Where-Object { $_ -and (Test-PathInside -Path $_ -Root $target) })
                if ($running.Count -gt 0)
                {
                    throw "Old-version cleanup blocked because target is running: $target"
                }

                $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                if ($null -ne $item)
                {
                    if (!$item.PSIsContainer)
                    {
                        throw "Cleanup target is not a directory: $target"
                    }
                    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                    {
                        throw "Cleanup target is a reparse point and will not be removed: $target"
                    }
                }
                $target
            } |
            Sort-Object -Unique)

    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($target in $validated)
    {
        if (!(Test-Path -LiteralPath $target)) { continue }

        Remove-Item -LiteralPath $target -Recurse -Force
        if (Test-Path -LiteralPath $target)
        {
            throw "Cleanup target still exists after removal: $target"
        }
        $removed.Add($target)
    }
    return @($removed)
}

function Get-CodexMaintenanceState
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $AppLayout,
        [AllowNull()] [object] $CodexState,
        [AllowEmptyString()] [string] $StatusText,
        [ValidateSet("Current", "Required")]
        [string] $LauncherStatus = "Current",
        [string[]] $RunningExecutablePaths = @(),
        [bool] $ProcessQuerySucceeded = $true,
        [AllowEmptyString()] [string] $ProcessQueryFailureReason = "")

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

    $status = if (!$ProcessQuerySucceeded) {
        "Blocked"
    } elseif ($injectionRequired -and $targetMirrorRunning) {
        "Blocked"
    } elseif ($injectionRequired) {
        "InjectionRequired"
    } elseif ($LauncherStatus -ne "Current") {
        "LauncherRequired"
    } else {
        "Current"
    }
    $blockReason = if (!$ProcessQuerySucceeded) {
        "ProcessQueryFailed"
    } elseif ($injectionRequired -and $targetMirrorRunning) {
        "MirrorRunning"
    } else {
        ""
    }
    $blockDetail = if ($blockReason -eq "ProcessQueryFailed") {
        $ProcessQueryFailureReason
    } elseif ($blockReason -eq "MirrorRunning") {
        "Codex is running from the target managed mirror."
    } else {
        ""
    }

    return [pscustomobject] @{
        Status = $status
        BlockReason = $blockReason
        BlockDetail = $blockDetail
        InjectionRequired = $injectionRequired
        LauncherRequired = $LauncherStatus -ne "Current"
        TargetMirrorRunning = $targetMirrorRunning
    }
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
        [string[]] $RunningExecutablePaths = @(),
        [bool] $ProcessQuerySucceeded = $true,
        [AllowEmptyString()] [string] $ProcessQueryFailureReason = "")

    if ($LinkStatus -eq "Unsafe")
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "The live tweak path is a real directory."
            AppRoot = $null
            BlockReason = "UnsafeLink"
            BlockDetail = "The live tweak path is a real directory."
        }
    }
    if (!$ProcessQuerySucceeded)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "Codex process discovery failed."
            AppRoot = $null
            BlockReason = "ProcessQueryFailed"
            BlockDetail = $ProcessQueryFailureReason
        }
    }
    if ($null -eq $CodexState)
    {
        $status = if ($LinkStatus -eq "Missing") { "NotInjected" } else { "LinkOnly" }
        return [pscustomobject] @{
            Status = $status
            Reason = "No Codex++ injection state exists."
            AppRoot = $null
            BlockReason = ""
            BlockDetail = ""
        }
    }
    if (!$HasCommand)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "The codexplusplus command is unavailable."
            AppRoot = $null
            BlockReason = "PrerequisiteFailed"
            BlockDetail = "The codexplusplus command is unavailable."
        }
    }
    if (!($CodexState.PSObject.Properties.Name -contains "appRoot") -or !$CodexState.appRoot)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            Reason = "Codex++ state has no appRoot."
            AppRoot = $null
            BlockReason = "InvalidState"
            BlockDetail = "Codex++ state has no appRoot."
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
            BlockReason = "MirrorRunning"
            BlockDetail = "The injected Codex mirror is running."
        }
    }
    return [pscustomobject] @{
        Status = "Ready"
        Reason = "Injection can be removed."
        AppRoot = $appRoot
        BlockReason = ""
        BlockDetail = ""
    }
}

function Get-CodexUninstallArguments
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $AppRoot)

    return [string[]] @("uninstall", "--app", (Resolve-NormalizedPath $AppRoot))
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
    "Select-LatestCodexPackage",
    "Get-CodexAppLayout",
    "Get-CodexPackageLaunchLayout",
    "Get-CodexExecutablePathsFromProcesses",
    "Get-CodexProcessSnapshot",
    "Get-CodexMutationGuard",
    "Test-CodexMirrorComplete",
    "Invoke-CodexMutationSafely",
    "Get-CodexPostFailureObservation",
    "Enter-CodexMaintenanceLock",
    "Exit-CodexMaintenanceLock",
    "Get-CodexRepairPlan",
    "Test-PathInside",
    "Get-CodexMirrorCleanupPlan",
    "Remove-CodexMirrorCleanupTargets",
    "Get-CodexMaintenanceState",
    "Get-CodexPlusPlusInstallState",
    "Test-CodexPlusPlusSourceLayout",
    "Get-CodexPlusPlusSourceSwapState",
    "Get-CodexUninjectState",
    "Get-CodexUninstallArguments",
    "Get-CodexLauncherState",
    "Set-CodexLauncherArtifacts",
    "Remove-ManagedCodexDesktopShortcut")
