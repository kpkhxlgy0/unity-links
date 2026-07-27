[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $CleanupAllOldVersions)

$ErrorActionPreference = "Stop"

$codexPlusPlusVersion = [version] "1.0.0"
$codexPlusPlusCommit = "f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7"
$archiveUri = "https://codeload.github.com/b-nnett/codex-plusplus/zip/$codexPlusPlusCommit"
$modulePath = Join-Path $PSScriptRoot "scripts/UnityLinkMaintenance.psm1"
Import-Module $modulePath -Force

function Get-CommandVersion
{
    param(
        [Parameter(Mandatory)] [System.Management.Automation.CommandInfo] $CommandInfo,
        [string[]] $PrefixArguments = @())

    $output = & $CommandInfo.Source @PrefixArguments --version 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Version command failed for $($CommandInfo.Source): " + ($output -join [Environment]::NewLine)
    }
    $versionMatch = [regex]::Match(($output -join " "), "\d+\.\d+\.\d+")
    if (!$versionMatch.Success)
    {
        throw "Could not parse a version from $($CommandInfo.Source): $($output -join ' ')"
    }
    return [version] $versionMatch.Value
}

function Invoke-CheckedCommand
{
    param(
        [Parameter(Mandatory)] [string] $Executable,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $FailureMessage)

    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw $FailureMessage }
}

function Invoke-CodexPlusPlus
{
    param(
        [Parameter(Mandatory)] [System.Management.Automation.CommandInfo] $CommandInfo,
        [Parameter(Mandatory)] [string[]] $Arguments)

    $output = & $CommandInfo.Source @Arguments 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "codexplusplus $($Arguments[0]) failed:" + [Environment]::NewLine +
            ($output -join [Environment]::NewLine)
    }
    return $output
}

function Read-CodexPlusPlusState
{
    param([Parameter(Mandatory)] [string] $Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Get-LiveMaintenanceContext
{
    param(
        [Parameter(Mandatory)] [System.Management.Automation.CommandInfo] $CommandInfo,
        [Parameter(Mandatory)] [object] $AppLayout,
        [Parameter(Mandatory)] [string] $StatePath,
        [Parameter(Mandatory)] [string] $LinkPath,
        [Parameter(Mandatory)] [string] $ExpectedTweakPath,
        [Parameter(Mandatory)] [string] $ExpectedLaunchExecutable,
        [Parameter(Mandatory)] [string] $LauncherCommandPath,
        [Parameter(Mandatory)] [string] $StartMenuShortcutPath,
        [Parameter(Mandatory)] [object] $ProcessSnapshot)

    $codexState = Read-CodexPlusPlusState -Path $StatePath
    $statusText = ""
    if ($null -ne $codexState)
    {
        $statusText = (Invoke-CodexPlusPlus -CommandInfo $CommandInfo -Arguments @("status")) -join `
            [Environment]::NewLine
    }
    $linkState = Get-TweakLinkState -LinkPath $LinkPath -ExpectedTarget $ExpectedTweakPath
    $launcherState = Get-CodexLauncherState -ExpectedExecutable $ExpectedLaunchExecutable `
        -CommandPath $LauncherCommandPath -StartMenuShortcutPath $StartMenuShortcutPath
    $maintenanceState = Get-CodexMaintenanceState `
        -AppLayout $AppLayout `
        -CodexState $codexState `
        -StatusText $statusText `
        -LinkStatus $linkState.Status `
        -LauncherStatus $launcherState.Status `
        -RunningExecutablePaths @($ProcessSnapshot.ExecutablePaths) `
        -ProcessQuerySucceeded ([bool] $ProcessSnapshot.Succeeded) `
        -ProcessQueryFailureReason ([string] $ProcessSnapshot.FailureReason)

    return [pscustomobject] @{
        CodexState = $codexState
        LinkState = $linkState
        LauncherState = $launcherState
        ProcessSnapshot = $ProcessSnapshot
        RunningPaths = @($ProcessSnapshot.ExecutablePaths)
        MaintenanceState = $maintenanceState
    }
}

function Get-LiveCleanupPlan
{
    param(
        [Parameter(Mandatory)] [string] $ManagedStoreRoot,
        [Parameter(Mandatory)] [string] $CurrentAppRoot,
        [AllowEmptyString()] [string] $PreviousAppRoot,
        [switch] $AllOldVersions)

    $candidateRoots = if ($AllOldVersions -and (Test-Path -LiteralPath $ManagedStoreRoot -PathType Container)) {
        @(
            Get-ChildItem -LiteralPath $ManagedStoreRoot -Directory -Force |
                Where-Object { $_.Name -match '^OpenAI\.Codex_.+$' } |
                ForEach-Object { $_.FullName })
    } else {
        @()
    }
    return Get-CodexMirrorCleanupPlan `
        -ManagedStoreRoot $ManagedStoreRoot `
        -CurrentAppRoot $CurrentAppRoot `
        -PreviousAppRoot $PreviousAppRoot `
        -CandidatePackageRoots $candidateRoots `
        -CleanupAllOldVersions:$AllOldVersions
}

function Write-CleanupPlan
{
    param([Parameter(Mandatory)] [object] $Plan)

    Write-Host "Cleanup mode: $($Plan.Mode)"
    if (@($Plan.Targets).Count -eq 0)
    {
        Write-Host "Cleanup targets: none"
        return
    }
    foreach ($target in @($Plan.Targets)) { Write-Host "Cleanup target: $target" }
}

function Restore-PreviousSource
{
    param(
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $PreviousRoot,
        [Parameter(Mandatory)] [string] $WorkRoot)

    $rejectedRoot = Join-Path $WorkRoot "rejected-source"
    if (Test-Path -LiteralPath $SourceRoot)
    {
        Move-Item -LiteralPath $SourceRoot -Destination $rejectedRoot
    }
    if (Test-Path -LiteralPath $PreviousRoot)
    {
        Move-Item -LiteralPath $PreviousRoot -Destination $SourceRoot
    }
}

function Remove-VerifiedTree
{
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ExpectedPath)

    $resolved = Resolve-NormalizedPath $Path
    $expected = Resolve-NormalizedPath $ExpectedPath
    if (!(Test-PathEqual $resolved $expected)) { throw "Refusing to delete an unexpected path: $resolved" }
    if (Test-Path -LiteralPath $resolved)
    {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

$maintenanceLock = $null
$workRoot = $null
try
{
    $maintenanceLock = Enter-CodexMaintenanceLock -TimeoutMilliseconds 0
    if (!$maintenanceLock.Acquired)
    {
        [Console]::Error.WriteLine(
            "Blocked [MaintenanceBusy]: another Editor Links maintenance operation is running.")
        exit 2
    }
    if ($maintenanceLock.Abandoned)
    {
        Write-Host "Recovered an abandoned Editor Links maintenance lock." -ForegroundColor Yellow
    }

    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $PSScriptRoot
    Assert-UnityLinkComponentInitialized -Layout $layout -Component CodexTweak

    if (!$env:USERPROFILE) { throw "USERPROFILE is not available." }
    if (!$env:LOCALAPPDATA) { throw "LOCALAPPDATA is not available." }
    if (!$env:APPDATA) { throw "APPDATA is not available." }

    $sourceRoot = Resolve-NormalizedPath (Join-Path $env:USERPROFILE ".codex-plusplus/source")
    $expectedSourceRoot = Resolve-NormalizedPath (
        Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex-plusplus/source")
    if (!(Test-PathEqual $sourceRoot $expectedSourceRoot))
    {
        throw "Refusing to use an unexpected Codex++ source root: $sourceRoot"
    }

    $package = Select-LatestCodexPackage -Packages @(Get-AppxPackage -Name OpenAI.Codex)
    $appLayout = Get-CodexAppLayout -Package $package -LocalAppData $env:LOCALAPPDATA
    $launchLayout = Get-CodexPackageLaunchLayout -Package $package -AppLayout $appLayout
    if (!(Test-Path -LiteralPath $appLayout.OfficialAsar -PathType Leaf))
    {
        throw "Official Codex ASAR not found: $($appLayout.OfficialAsar)"
    }

    $statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
    $linkPath = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
    $launcherCommandPath = Join-Path $env:LOCALAPPDATA "Microsoft/WindowsApps/codex-plusplus-codex.cmd"
    $programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if (!$programsPath) { throw "The current user's Start Menu Programs folder is unavailable." }
    $startMenuShortcutPath = Join-Path $programsPath "Codex++.lnk"
    $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $desktopShortcutPath = if ($desktopPath) { Join-Path $desktopPath "Codex++.lnk" } else { $null }
    $managedStoreRoot = Join-Path $env:LOCALAPPDATA "codex-plusplus/store-apps"
    $preMaintenanceState = Read-CodexPlusPlusState -Path $statePath
    $previousAppRoot = if ($null -ne $preMaintenanceState -and
        $preMaintenanceState.PSObject.Properties.Name -contains "appRoot" -and
        $preMaintenanceState.appRoot) {
        [string] $preMaintenanceState.appRoot
    } else {
        ""
    }
    $cleanupPlan = Get-LiveCleanupPlan `
        -ManagedStoreRoot $managedStoreRoot `
        -CurrentAppRoot $appLayout.MirrorAppRoot `
        -PreviousAppRoot $previousAppRoot `
        -AllOldVersions:$CleanupAllOldVersions

    $installedVersion = $null
    $codexPlusPlusCommand = Get-Command codexplusplus -ErrorAction SilentlyContinue
    $versionBlockReason = $null
    if ($null -ne $codexPlusPlusCommand)
    {
        try
        {
            $installedVersion = Get-CommandVersion -CommandInfo $codexPlusPlusCommand
        }
        catch
        {
            $versionBlockReason = $_.Exception.Message
        }
    }

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue
    $nodeMajor = 0
    if ($null -ne $nodeCommand)
    {
        try
        {
            $nodeMajor = (Get-CommandVersion -CommandInfo $nodeCommand).Major
        }
        catch
        {
            $nodeMajor = 0
        }
    }
    $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
    $processSnapshot = Get-CodexProcessSnapshot
    $codexRunning = $processSnapshot.Succeeded -and @($processSnapshot.ExecutablePaths).Count -gt 0

    if (!$processSnapshot.Succeeded)
    {
        $installState = [pscustomobject] @{
            Status = "Blocked"
            Reason = [string] $processSnapshot.FailureReason
            BlockReason = "ProcessQueryFailed"
        }
    }
    elseif ($versionBlockReason)
    {
        $installState = [pscustomobject] @{
            Status = "Blocked"
            Reason = "An existing codexplusplus command has an unknown version. $versionBlockReason"
            BlockReason = "PrerequisiteFailed"
        }
    }
    else
    {
        $installState = Get-CodexPlusPlusInstallState `
            -InstalledVersion $installedVersion `
            -NodeMajor $nodeMajor `
            -HasNpm ($null -ne $npmCommand) `
            -TargetMirrorRunning $codexRunning
        $installBlockReason = if ($installState.Status -ne "Blocked") {
            ""
        } elseif ($codexRunning) {
            "MirrorRunning"
        } else {
            "PrerequisiteFailed"
        }
        $installState | Add-Member -NotePropertyName BlockReason -NotePropertyValue $installBlockReason
    }

    $context = $null
    if ($installState.Status -eq "Current")
    {
        $context = Get-LiveMaintenanceContext `
            -CommandInfo $codexPlusPlusCommand `
            -AppLayout $appLayout `
            -StatePath $statePath `
            -LinkPath $linkPath `
            -ExpectedTweakPath $layout.TweakRoot `
            -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
            -LauncherCommandPath $launcherCommandPath `
            -StartMenuShortcutPath $startMenuShortcutPath `
            -ProcessSnapshot $processSnapshot
    }
    $displayStatus = if ($null -ne $context) {
        $context.MaintenanceState.Status
    } else {
        $installState.Status
    }
    $displayReason = if ($null -ne $context) {
        "Compatible Codex++ is installed; routine maintenance state was evaluated."
    } else {
        $installState.Reason
    }

    Write-Host "Status: $displayStatus"
    Write-Host "Reason: $displayReason"
    Write-Host "Pinned Codex++: $codexPlusPlusVersion ($codexPlusPlusCommit)"
    Write-Host "Codex Appx: $($package.PackageFullName)"
    Write-Host "Official app: $($appLayout.OfficialAppRoot)"
    Write-Host "Managed mirror: $($appLayout.MirrorAppRoot)"
    Write-Host "Launch executable: $($launchLayout.MirrorExecutable)"
    Write-Host "Tweak source: $($layout.TweakRoot)"
    Write-Host "Source root: $sourceRoot"
    Write-CleanupPlan -Plan $cleanupPlan

    $blockReason = if ($installState.Status -eq "Blocked") {
        $installState.BlockReason
    } elseif ($null -ne $context -and $context.MaintenanceState.Status -eq "Blocked") {
        $context.MaintenanceState.BlockReason
    } else {
        ""
    }
    $blockDetail = if ($installState.Status -eq "Blocked") {
        $installState.Reason
    } elseif ($blockReason -eq "UnsafeLink") {
        "The live tweak path is a real directory and will not be replaced: $linkPath"
    } elseif ($null -ne $context) {
        $context.MaintenanceState.BlockDetail
    } else {
        ""
    }
    if ($CheckOnly)
    {
        if ($blockReason)
        {
            [Console]::Error.WriteLine("Blocked [$blockReason]: $blockDetail")
            exit 2
        }
        exit 0
    }
    if ($blockReason)
    {
        [Console]::Error.WriteLine("Blocked [$blockReason]: $blockDetail")
        exit 2
    }

    $injectionChanged = $false
    if ($installState.Status -eq "InstallRequired")
    {
        $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
            "unity-links-codexpp-" + [guid]::NewGuid().ToString("N"))
        $archivePath = Join-Path $workRoot "source.zip"
        $extractRoot = Join-Path $workRoot "extract"
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
        Invoke-WebRequest -Uri $archiveUri -OutFile $archivePath -UseBasicParsing
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
        $extracted = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
        if ($extracted.Count -ne 1)
        {
            throw "Expected exactly one Codex++ source root in the pinned archive."
        }
        $extractedSource = $extracted[0].FullName
        Test-CodexPlusPlusSourceLayout -SourceRoot $extractedSource | Out-Null

        Push-Location $extractedSource
        try
        {
            Invoke-CheckedCommand -Executable $npmCommand.Source `
                -Arguments @("ci", "--workspaces", "--include-workspace-root", "--ignore-scripts") `
                -FailureMessage "npm ci failed while building pinned Codex++."
            Invoke-CheckedCommand -Executable $npmCommand.Source -Arguments @("run", "build") `
                -FailureMessage "npm run build failed while building pinned Codex++."
        }
        finally
        {
            Pop-Location
        }

        $builtCli = Join-Path $extractedSource "packages/installer/dist/cli.js"
        if (!(Test-Path -LiteralPath $builtCli -PathType Leaf))
        {
            throw "Pinned Codex++ build did not produce: $builtCli"
        }

        $previousRoot = "$sourceRoot.previous"
        $swapState = Get-CodexPlusPlusSourceSwapState `
            -SourceExists (Test-Path -LiteralPath $sourceRoot) `
            -PreviousExists (Test-Path -LiteralPath $previousRoot)
        if ($swapState.Status -ne "Ready") { throw $swapState.Reason }

        New-Item -ItemType Directory -Path (Split-Path $sourceRoot -Parent) -Force | Out-Null
        if ($swapState.HasCurrentSource)
        {
            Move-Item -LiteralPath $sourceRoot -Destination $previousRoot
        }
        Move-Item -LiteralPath $extractedSource -Destination $sourceRoot

        $initialInstallSucceeded = $false
        try
        {
            $installedCli = Join-Path $sourceRoot "packages/installer/dist/cli.js"
            $directVersion = Get-CommandVersion -CommandInfo $nodeCommand -PrefixArguments @($installedCli)
            if ($directVersion -ne $codexPlusPlusVersion)
            {
                throw "Expected the built Codex++ CLI to report 1.0.0, found $directVersion."
            }

            $installArguments = @(
                $installedCli,
                "install",
                "--app",
                $appLayout.OfficialAppRoot,
                "--no-watcher")
            $mutationResult = Invoke-CodexMutationSafely `
                -Mutation {
                    Invoke-CheckedCommand `
                        -Executable $nodeCommand.Source `
                        -Arguments $installArguments `
                        -FailureMessage "Pinned Codex++ installer failed."
                } `
                -FailureObservation {
                    Get-CodexPostFailureObservation `
                        -StatePath $statePath `
                        -StatusQuery {
                            $statusOutput = & $nodeCommand.Source $installedCli status 2>&1
                            if ($LASTEXITCODE -ne 0)
                            {
                                throw "Pinned Codex++ status failed: " +
                                    ($statusOutput -join [Environment]::NewLine)
                            }
                            $statusOutput
                        } `
                        -AppLayout $appLayout `
                        -LaunchLayout $launchLayout
                }
            if (!$mutationResult.Invoked)
            {
                Restore-PreviousSource `
                    -SourceRoot $sourceRoot `
                    -PreviousRoot $previousRoot `
                    -WorkRoot $workRoot
                [Console]::Error.WriteLine(
                    "Blocked [$($mutationResult.BlockReason)]: $($mutationResult.FailureReason)")
                exit 2
            }
            if (!$mutationResult.Succeeded)
            {
                $observation = $mutationResult.FailureObservation |
                    ConvertTo-Json -Compress -Depth 4
                throw "$($mutationResult.ErrorMessage) Post-failure observation: $observation"
            }
            $mutationResult.Output | ForEach-Object { Write-Host $_ }
            $initialInstallSucceeded = $true
            $injectionChanged = $true
        }
        catch
        {
            if (!$initialInstallSucceeded)
            {
                Restore-PreviousSource `
                    -SourceRoot $sourceRoot `
                    -PreviousRoot $previousRoot `
                    -WorkRoot $workRoot
            }
            throw
        }

        $codexPlusPlusCommand = Get-Command codexplusplus -ErrorAction SilentlyContinue
        if ($null -eq $codexPlusPlusCommand)
        {
            throw "Pinned Codex++ installed but its command shim was not found."
        }
        $shimVersion = Get-CommandVersion -CommandInfo $codexPlusPlusCommand
        if ($shimVersion -ne $codexPlusPlusVersion)
        {
            throw "Expected the installed Codex++ command to report 1.0.0, found $shimVersion."
        }

        if (Test-Path -LiteralPath $previousRoot)
        {
            $expectedPreviousRoot = "$expectedSourceRoot.previous"
            Remove-VerifiedTree -Path $previousRoot -ExpectedPath $expectedPreviousRoot
        }
    }

    $processSnapshot = Get-CodexProcessSnapshot
    $context = Get-LiveMaintenanceContext `
        -CommandInfo $codexPlusPlusCommand `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $layout.TweakRoot `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -ProcessSnapshot $processSnapshot
    if ($context.MaintenanceState.Status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [$($context.MaintenanceState.BlockReason)]: $($context.MaintenanceState.BlockDetail)")
        exit 2
    }

    if ($context.MaintenanceState.InjectionRequired)
    {
        $repairPlan = Get-CodexRepairPlan `
            -AppLayout $appLayout `
            -CodexState $context.CodexState `
            -InjectionRequired $context.MaintenanceState.InjectionRequired `
            -MirrorComplete (Test-CodexMirrorComplete -AppLayout $appLayout -LaunchLayout $launchLayout)
        $repairArguments = @("repair", "--force", "--app", $repairPlan.TargetAppRoot)
        $mutationResult = Invoke-CodexMutationSafely `
            -Mutation {
                Invoke-CodexPlusPlus `
                    -CommandInfo $codexPlusPlusCommand `
                    -Arguments $repairArguments
            } `
            -FailureObservation {
                Get-CodexPostFailureObservation `
                    -StatePath $statePath `
                    -StatusQuery {
                        Invoke-CodexPlusPlus `
                            -CommandInfo $codexPlusPlusCommand `
                            -Arguments @("status")
                    } `
                    -AppLayout $appLayout `
                    -LaunchLayout $launchLayout
            }
        if (!$mutationResult.Invoked)
        {
            [Console]::Error.WriteLine(
                "Blocked [$($mutationResult.BlockReason)]: $($mutationResult.FailureReason)")
            exit 2
        }
        if (!$mutationResult.Succeeded)
        {
            $observation = $mutationResult.FailureObservation |
                ConvertTo-Json -Compress -Depth 4
            throw "$($mutationResult.ErrorMessage) Post-failure observation: $observation"
        }
        $mutationResult.Output | ForEach-Object { Write-Host $_ }
        $injectionChanged = $true
    }

    $processSnapshot = Get-CodexProcessSnapshot
    $context = Get-LiveMaintenanceContext `
        -CommandInfo $codexPlusPlusCommand `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $layout.TweakRoot `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -ProcessSnapshot $processSnapshot
    if ($context.MaintenanceState.Status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [$($context.MaintenanceState.BlockReason)]: $($context.MaintenanceState.BlockDetail)")
        exit 2
    }
    if ($context.MaintenanceState.InjectionRequired)
    {
        throw "Codex++ repair completed but the latest managed mirror is not current."
    }
    if ($context.LinkState.Status -eq "Unsafe")
    {
        throw "The live tweak path became unsafe during maintenance: $linkPath"
    }

    $launcherChanged = Set-CodexLauncherArtifacts `
        -ExpectedExecutable $launchLayout.MirrorExecutable `
        -CommandPath $launcherCommandPath `
        -StartMenuShortcutPath $startMenuShortcutPath
    if ($desktopShortcutPath)
    {
        $desktopShortcutRemoved = Remove-ManagedCodexDesktopShortcut `
            -DesktopShortcutPath $desktopShortcutPath `
            -ManagedStoreRoot $managedStoreRoot
        if ($desktopShortcutRemoved) { Write-Host "Removed the legacy managed desktop shortcut." }
    }
    $linkChanged = Set-TweakJunction -LinkPath $linkPath -ExpectedTarget $layout.TweakRoot

    $processSnapshot = Get-CodexProcessSnapshot
    $context = Get-LiveMaintenanceContext `
        -CommandInfo $codexPlusPlusCommand `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $layout.TweakRoot `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -ProcessSnapshot $processSnapshot
    if ($context.MaintenanceState.Status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [$($context.MaintenanceState.BlockReason)]: $($context.MaintenanceState.BlockDetail)")
        exit 2
    }
    if ($context.MaintenanceState.Status -ne "Current")
    {
        throw "Maintenance verification failed with status: $($context.MaintenanceState.Status)"
    }
    if (!(Test-CodexMirrorComplete -AppLayout $appLayout -LaunchLayout $launchLayout))
    {
        throw "The current managed mirror is incomplete after maintenance."
    }

    $removedTargets = @()
    if (@($cleanupPlan.Targets).Count -gt 0)
    {
        $cleanupSnapshot = Get-CodexProcessSnapshot
        try
        {
            $removedTargets = @(Remove-CodexMirrorCleanupTargets `
                -ManagedStoreRoot $managedStoreRoot `
                -CurrentAppRoot $appLayout.MirrorAppRoot `
                -Targets @($cleanupPlan.Targets) `
                -ProcessSnapshot $cleanupSnapshot)
        }
        catch
        {
            if ($_.Exception.Message -match '^Old-version cleanup blocked')
            {
                $cleanupBlockReason = if ($_.Exception.Message -match 'process discovery failed') {
                    "ProcessQueryFailed"
                } else {
                    "OldMirrorRunning"
                }
                [Console]::Error.WriteLine(
                    "Blocked [$cleanupBlockReason]: $($_.Exception.Message)")
                exit 2
            }
            throw
        }
    }
    foreach ($removedTarget in $removedTargets)
    {
        Write-Host "Removed old managed mirror: $removedTarget"
    }
    if (!(Test-CodexMirrorComplete -AppLayout $appLayout -LaunchLayout $launchLayout))
    {
        throw "The current managed mirror changed during old-version cleanup."
    }

    Write-Host "Codex++ installation, current mirror, launchers, and Unity Links tweak are current."
    $codexRunningOutsideMirror = @(
        $context.RunningPaths |
            Where-Object { !(Test-PathInside -Path $_ -Root $appLayout.MirrorAppRoot) }
    ).Count -gt 0
    if (($injectionChanged -or $launcherChanged -or $linkChanged) -and $codexRunningOutsideMirror)
    {
        Write-Host (
            "Codex is still running outside the managed mirror. Close Codex manually, then relaunch it " +
            "before validating link clicks.") -ForegroundColor Yellow
    }
}
catch
{
    Write-Error $_
    exit 1
}
finally
{
    try
    {
        if ($workRoot)
        {
            $expectedWorkRoot = Resolve-NormalizedPath $workRoot
            Remove-VerifiedTree -Path $workRoot -ExpectedPath $expectedWorkRoot
        }
    }
    finally
    {
        Exit-CodexMaintenanceLock -LockHandle $maintenanceLock
    }
}
