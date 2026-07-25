[CmdletBinding()]
param(
    [switch] $CheckOnly)

$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "scripts/UnityLinkMaintenance.psm1"
Import-Module $modulePath -Force

function Invoke-CodexPlusPlus
{
    param(
        [Parameter(Mandatory)] [System.Management.Automation.CommandInfo] $CommandInfo,
        [Parameter(Mandatory)] [string[]] $Arguments)

    $output = & $CommandInfo.Source @Arguments 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "codexplusplus $($Arguments[0]) failed:" + [Environment]::NewLine + ($output -join [Environment]::NewLine)
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
        $statusText = (Invoke-CodexPlusPlus -CommandInfo $CommandInfo -Arguments @("status")) -join [Environment]::NewLine
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

$maintenanceLock = $null
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
        Write-Host "Recovered an abandoned Editor Links maintenance lock." `
            -ForegroundColor Yellow
    }

    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $PSScriptRoot
    Assert-UnityLinkComponentInitialized -Layout $layout -Component CodexTweak

    if (!$env:APPDATA) { throw "APPDATA is not available." }
    if (!$env:LOCALAPPDATA) { throw "LOCALAPPDATA is not available." }

    $expectedTweakPath = $layout.TweakRoot
    $tweakManifestPath = $layout.TweakManifest
    if (!(Test-Path -LiteralPath $tweakManifestPath -PathType Leaf))
    {
        throw "Tweak manifest not found: $tweakManifestPath"
    }
    Get-Content -Raw -LiteralPath $tweakManifestPath | ConvertFrom-Json | Out-Null

    $command = Get-Command codexplusplus -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw "codexplusplus is not installed or is not on PATH." }
    $versionText = (Invoke-CodexPlusPlus -CommandInfo $command -Arguments @("--version")) -join " "
    $versionMatch = [regex]::Match($versionText, "\d+\.\d+\.\d+")
    if (!$versionMatch.Success) { throw "Could not parse the Codex++ version from: $versionText" }
    $version = [version] $versionMatch.Value
    if ($version -lt [version] "1.0.0") { throw "Codex++ 1.0.0 or newer is required; found $version." }

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
    $processSnapshot = Get-CodexProcessSnapshot
    $context = Get-LiveMaintenanceContext `
        -CommandInfo $command `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $expectedTweakPath `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -ProcessSnapshot $processSnapshot

    Write-Host "Status: $($context.MaintenanceState.Status)"
    Write-Host "Codex++: $version"
    Write-Host "Codex Appx: $($package.PackageFullName)"
    Write-Host "Official app: $($appLayout.OfficialAppRoot)"
    Write-Host "Managed mirror: $($appLayout.MirrorAppRoot)"
    Write-Host "Launch executable: $($launchLayout.MirrorExecutable)"
    Write-Host "Tweak source: $expectedTweakPath"

    if ($CheckOnly)
    {
        if ($context.MaintenanceState.Status -eq "Blocked")
        {
            $blockDetail = if ($context.MaintenanceState.UnsafeLink) {
                "The live tweak path is a real directory and will not be replaced: $linkPath"
            } else {
                $context.MaintenanceState.BlockDetail
            }
            [Console]::Error.WriteLine(
                "Blocked [$($context.MaintenanceState.BlockReason)]: $blockDetail")
            exit 2
        }
        exit 0
    }

    if ($context.MaintenanceState.Status -eq "Blocked")
    {
        $blockDetail = if ($context.MaintenanceState.UnsafeLink) {
            "The live tweak path is a real directory and will not be replaced: $linkPath"
        } else {
            $context.MaintenanceState.BlockDetail
        }
        [Console]::Error.WriteLine(
            "Blocked [$($context.MaintenanceState.BlockReason)]: $blockDetail")
        exit 2
    }

    $injectionChanged = $false
    if ($context.MaintenanceState.InjectionRequired)
    {
        $repairPlan = Get-CodexRepairPlan `
            -AppLayout $appLayout `
            -CodexState $context.CodexState `
            -InjectionRequired $context.MaintenanceState.InjectionRequired `
            -MirrorComplete (Test-CodexMirrorComplete `
                -AppLayout $appLayout `
                -LaunchLayout $launchLayout)
        $repairArguments = @(
            "repair",
            "--force",
            "--app",
            $repairPlan.TargetAppRoot)
        $mutationResult = Invoke-CodexMutationSafely `
            -Mutation {
                Invoke-CodexPlusPlus `
                    -CommandInfo $command `
                    -Arguments $repairArguments
            } `
            -FailureObservation {
                Get-CodexPostFailureObservation `
                    -StatePath $statePath `
                    -StatusQuery {
                        Invoke-CodexPlusPlus `
                            -CommandInfo $command `
                            -Arguments @("status")
                    } `
                    -AppLayout $appLayout `
                    -LaunchLayout $launchLayout
            }
        if (!$mutationResult.Invoked)
        {
            [Console]::Error.WriteLine(
                "Blocked [$($mutationResult.BlockReason)]: " +
                $mutationResult.FailureReason)
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
        -CommandInfo $command `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $expectedTweakPath `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -ProcessSnapshot $processSnapshot
    if ($context.MaintenanceState.Status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [$($context.MaintenanceState.BlockReason)]: " +
            $context.MaintenanceState.BlockDetail)
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

    $launcherChanged = Set-CodexLauncherArtifacts -ExpectedExecutable $launchLayout.MirrorExecutable `
        -CommandPath $launcherCommandPath -StartMenuShortcutPath $startMenuShortcutPath
    if ($desktopShortcutPath)
    {
        $desktopShortcutRemoved = Remove-ManagedCodexDesktopShortcut `
            -DesktopShortcutPath $desktopShortcutPath `
            -ManagedStoreRoot $managedStoreRoot
        if ($desktopShortcutRemoved) { Write-Host "Removed the legacy managed desktop shortcut." }
    }
    $linkChanged = Set-TweakJunction -LinkPath $linkPath -ExpectedTarget $expectedTweakPath
    $processSnapshot = Get-CodexProcessSnapshot
    $context = Get-LiveMaintenanceContext `
        -CommandInfo $command `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $expectedTweakPath `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -ProcessSnapshot $processSnapshot
    if ($context.MaintenanceState.Status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [$($context.MaintenanceState.BlockReason)]: " +
            $context.MaintenanceState.BlockDetail)
        exit 2
    }
    if ($context.MaintenanceState.Status -ne "Current")
    {
        throw "Maintenance verification failed with status: $($context.MaintenanceState.Status)"
    }

    Write-Host "Codex++ injection, launchers, and Unity link tweak are current."
    $codexRunningOutsideMirror = @(
        $context.RunningPaths | Where-Object { !(Test-PathInside -Path $_ -Root $appLayout.MirrorAppRoot) }
    ).Count -gt 0
    if (($injectionChanged -or $launcherChanged -or $linkChanged) -and $codexRunningOutsideMirror)
    {
        Write-Host "Codex is still running outside the managed mirror. Close Codex manually, then relaunch it before validating link clicks." -ForegroundColor Yellow
    }
}
catch
{
    Write-Error $_
    exit 1
}
finally
{
    Exit-CodexMaintenanceLock -LockHandle $maintenanceLock
}
