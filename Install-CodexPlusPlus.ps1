#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch] $CheckOnly,
    [switch] $CleanupAllOldVersions)

$ErrorActionPreference = "Stop"

$codexPlusPlusVersion = [version] "1.0.0"
$codexPlusPlusCommit = "f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7"
$archiveUri = "https://codeload.github.com/b-nnett/codex-plusplus/zip/$codexPlusPlusCommit"
$scriptsRoot = Join-Path $PSScriptRoot "scripts"
Import-Module (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Force
Import-Module (Join-Path $scriptsRoot "CodexPlusPlusMaintenance.psm1") -Force

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

function Get-RecordedAppRoot
{
    param([AllowNull()] [object] $State)

    if ($null -eq $State -or
        $State.PSObject.Properties.Name -notcontains "appRoot" -or
        !$State.appRoot)
    {
        return ""
    }
    return Resolve-NormalizedPath ([string] $State.appRoot)
}

function Test-ManagedAppRoot
{
    param(
        [AllowEmptyString()] [string] $AppRoot,
        [Parameter(Mandatory)] [string] $ManagedStoreRoot)

    return $AppRoot -and (Test-PathInside -Path $AppRoot -Root $ManagedStoreRoot)
}

function Get-LiveCleanupPlan
{
    param(
        [Parameter(Mandatory)] [string] $ManagedStoreRoot,
        [AllowEmptyString()] [string] $CurrentAppRoot,
        [AllowEmptyString()] [string] $PreviousAppRoot,
        [switch] $AllOldVersions)

    $mode = if ($AllOldVersions) { "AllOld" } else { "Previous" }
    if (!(Test-ManagedAppRoot -AppRoot $CurrentAppRoot -ManagedStoreRoot $ManagedStoreRoot))
    {
        return [pscustomobject] @{ Mode = $mode; CurrentPackageRoot = ""; Targets = @() }
    }

    $managedPrevious = if (Test-ManagedAppRoot -AppRoot $PreviousAppRoot -ManagedStoreRoot $ManagedStoreRoot) {
        $PreviousAppRoot
    } else {
        ""
    }
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
        -PreviousAppRoot $managedPrevious `
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

function Get-MaintenancePreview
{
    param(
        [AllowNull()] [System.Management.Automation.CommandInfo] $CommandInfo,
        [AllowNull()] [object] $State,
        [Parameter(Mandatory)] [object] $ProcessSnapshot)

    $appRoot = Get-RecordedAppRoot -State $State
    if (!$appRoot -or $null -eq $CommandInfo)
    {
        return [pscustomobject] @{
            Status = "Deferred"
            BlockReason = ""
            BlockDetail = ""
            StatusText = ""
        }
    }
    if (!$ProcessSnapshot.Succeeded)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            BlockReason = "ProcessQueryFailed"
            BlockDetail = [string] $ProcessSnapshot.FailureReason
            StatusText = ""
        }
    }

    $statusText = (Invoke-CodexPlusPlus -CommandInfo $CommandInfo -Arguments @("status")) -join `
        [Environment]::NewLine
    $patchCurrent = $statusText -match '(?i)matches patched'
    $targetRunning = @(
        $ProcessSnapshot.ExecutablePaths |
            Where-Object { $_ -and (Test-PathInside -Path $_ -Root $appRoot) }).Count -gt 0
    if (!$patchCurrent -and $targetRunning)
    {
        return [pscustomobject] @{
            Status = "Blocked"
            BlockReason = "CodexRunning"
            BlockDetail = "Codex is running from the recorded Codex++ app root."
            StatusText = $statusText
        }
    }
    return [pscustomobject] @{
        Status = if ($patchCurrent) { "Current" } else { "MaintenanceRequired" }
        BlockReason = ""
        BlockDetail = ""
        StatusText = $statusText
    }
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
            "Blocked [MaintenanceBusy]: another Codex++ maintenance operation is running.")
        exit 2
    }
    if ($maintenanceLock.Abandoned)
    {
        Write-Host "Recovered an abandoned Codex++ maintenance lock." -ForegroundColor Yellow
    }

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

    $statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
    $managedStoreRoot = Join-Path $env:LOCALAPPDATA "codex-plusplus/store-apps"
    $preMaintenanceState = Read-CodexPlusPlusState -Path $statePath
    $previousAppRoot = Get-RecordedAppRoot -State $preMaintenanceState

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
    $codexRunning = $processSnapshot.Succeeded -and $previousAppRoot -and @(
        $processSnapshot.ExecutablePaths |
            Where-Object { $_ -and (Test-PathInside -Path $_ -Root $previousAppRoot) }
    ).Count -gt 0

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
            "DesktopAppRunning"
        } else {
            "PrerequisiteFailed"
        }
        $installState | Add-Member -NotePropertyName BlockReason -NotePropertyValue $installBlockReason
    }

    $maintenancePreview = if ($installState.Status -eq "Current") {
        Get-MaintenancePreview `
            -CommandInfo $codexPlusPlusCommand `
            -State $preMaintenanceState `
            -ProcessSnapshot $processSnapshot
    } else {
        $null
    }
    $cleanupPreview = Get-LiveCleanupPlan `
        -ManagedStoreRoot $managedStoreRoot `
        -CurrentAppRoot $previousAppRoot `
        -PreviousAppRoot $previousAppRoot `
        -AllOldVersions:$CleanupAllOldVersions
    $displayAppRoot = if ($previousAppRoot) { $previousAppRoot } else { "Auto-detected by Codex++ during install" }
    $displayMirror = if (Test-ManagedAppRoot -AppRoot $previousAppRoot -ManagedStoreRoot $managedStoreRoot) {
        $previousAppRoot
    } else {
        "Not applicable"
    }

    Write-Host "Status: $($installState.Status)"
    Write-Host "Reason: $($installState.Reason)"
    Write-Host "Pinned Codex++: $codexPlusPlusVersion ($codexPlusPlusCommit)"
    Write-Host "Codex app: $displayAppRoot"
    Write-Host "Managed mirror: $displayMirror"
    Write-Host "Maintenance status: $(if ($null -eq $maintenancePreview) { 'Deferred' } else { $maintenancePreview.Status })"
    Write-Host "Source root: $sourceRoot"
    Write-CleanupPlan -Plan $cleanupPreview

    $blockReason = if ($installState.Status -eq "Blocked") {
        $installState.BlockReason
    } elseif ($null -ne $maintenancePreview -and $maintenancePreview.Status -eq "Blocked") {
        $maintenancePreview.BlockReason
    } else {
        ""
    }
    $blockDetail = if ($installState.Status -eq "Blocked") {
        $installState.Reason
    } elseif ($null -ne $maintenancePreview) {
        $maintenancePreview.BlockDetail
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

    $installedCli = $null
    $previousRoot = "$sourceRoot.previous"
    $sourceSwapPending = $false
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
        $sourceSwapPending = $true
        $installedCli = Join-Path $sourceRoot "packages/installer/dist/cli.js"
        $directVersion = Get-CommandVersion -CommandInfo $nodeCommand -PrefixArguments @($installedCli)
        if ($directVersion -ne $codexPlusPlusVersion)
        {
            throw "Expected the built Codex++ CLI to report 1.0.0, found $directVersion."
        }
    }

    $nativeArguments = @(Get-CodexPlusPlusInstallArguments)
    $mutationResult = Invoke-CodexMutationSafely `
        -TargetAppRoots @($previousAppRoot) `
        -Mutation {
            if ($installedCli)
            {
                Invoke-CheckedCommand `
                    -Executable $nodeCommand.Source `
                    -Arguments (@($installedCli) + $nativeArguments) `
                    -FailureMessage "Pinned Codex++ installer failed."
            }
            else
            {
                Invoke-CodexPlusPlus `
                    -CommandInfo $codexPlusPlusCommand `
                    -Arguments $nativeArguments
            }
        } `
        -FailureObservation {
            $observedState = Read-CodexPlusPlusState -Path $statePath
            [pscustomobject] @{
                RecordedAppRoot = Get-RecordedAppRoot -State $observedState
                StatePresent = $null -ne $observedState
            }
        }
    if (!$mutationResult.Invoked)
    {
        if ($sourceSwapPending)
        {
            Restore-PreviousSource -SourceRoot $sourceRoot -PreviousRoot $previousRoot -WorkRoot $workRoot
        }
        [Console]::Error.WriteLine(
            "Blocked [$($mutationResult.BlockReason)]: $($mutationResult.FailureReason)")
        exit 2
    }
    if (!$mutationResult.Succeeded)
    {
        if ($sourceSwapPending)
        {
            Restore-PreviousSource -SourceRoot $sourceRoot -PreviousRoot $previousRoot -WorkRoot $workRoot
        }
        $observation = $mutationResult.FailureObservation | ConvertTo-Json -Compress -Depth 4
        throw "$($mutationResult.ErrorMessage) Post-failure observation: $observation"
    }
    $mutationResult.Output | ForEach-Object { Write-Host $_ }

    if ($installedCli)
    {
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
    }

    $postMaintenanceState = Read-CodexPlusPlusState -Path $statePath
    $currentAppRoot = Get-RecordedAppRoot -State $postMaintenanceState
    if (!$currentAppRoot) { throw "Codex++ install completed without recording an app root." }
    $currentAsar = Join-Path $currentAppRoot "resources/app.asar"
    if (!(Test-Path -LiteralPath $currentAsar -PathType Leaf))
    {
        throw "Codex++ recorded app ASAR was not found: $currentAsar"
    }
    $statusText = (Invoke-CodexPlusPlus -CommandInfo $codexPlusPlusCommand -Arguments @("status")) -join `
        [Environment]::NewLine
    if ($statusText -notmatch '(?i)matches patched')
    {
        throw "Codex++ installation completed but status does not report the patched app as current."
    }

    $launchExecutable = Get-CodexDesktopExecutable -AppRoot $currentAppRoot
    $launcherCommandPath = Join-Path $env:LOCALAPPDATA "Microsoft/WindowsApps/codex-plusplus-codex.cmd"
    $programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if (!$programsPath) { throw "The current user's Start Menu Programs folder is unavailable." }
    $startMenuShortcutPath = Join-Path $programsPath "Codex++.lnk"
    if (Set-CodexLauncherArtifacts `
            -ExpectedExecutable $launchExecutable `
            -CommandPath $launcherCommandPath `
            -StartMenuShortcutPath $startMenuShortcutPath)
    {
        Write-Host "Updated Codex++ launchers to use: $launchExecutable"
    }

    $cleanupPlan = Get-LiveCleanupPlan `
        -ManagedStoreRoot $managedStoreRoot `
        -CurrentAppRoot $currentAppRoot `
        -PreviousAppRoot $previousAppRoot `
        -AllOldVersions:$CleanupAllOldVersions
    $removedTargets = @()
    if (@($cleanupPlan.Targets).Count -gt 0)
    {
        $cleanupSnapshot = Get-CodexProcessSnapshot
        try
        {
            $removedTargets = @(Remove-CodexMirrorCleanupTargets `
                -ManagedStoreRoot $managedStoreRoot `
                -CurrentAppRoot $currentAppRoot `
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
                [Console]::Error.WriteLine("Blocked [$cleanupBlockReason]: $($_.Exception.Message)")
                exit 2
            }
            throw
        }
    }
    foreach ($removedTarget in $removedTargets)
    {
        Write-Host "Removed old managed mirror: $removedTarget"
    }

    if (Test-ManagedAppRoot -AppRoot $currentAppRoot -ManagedStoreRoot $managedStoreRoot)
    {
        $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
        if ($desktopPath)
        {
            $desktopShortcutPath = Join-Path $desktopPath "Codex++.lnk"
            if (Remove-ManagedCodexDesktopShortcut `
                    -DesktopShortcutPath $desktopShortcutPath `
                    -ManagedStoreRoot $managedStoreRoot)
            {
                Write-Host "Removed the legacy managed desktop shortcut."
            }
        }
    }

    if ($sourceSwapPending -and (Test-Path -LiteralPath $previousRoot))
    {
        $expectedPreviousRoot = "$expectedSourceRoot.previous"
        Remove-VerifiedTree -Path $previousRoot -ExpectedPath $expectedPreviousRoot
    }

    Write-Host "Codex++ installation and routine maintenance are current."
    Write-Host "Codex app: $currentAppRoot"
    Write-Host "Launch executable: $launchExecutable"
    Write-Host "Discovery: Codex++ locateCodex (native install without --app)"
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
