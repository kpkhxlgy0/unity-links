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

function Get-CodexExecutablePaths
{
    $processes = @(
        Get-CimInstance Win32_Process -Filter "Name = 'Codex.exe' OR Name = 'ChatGPT.exe'" `
            -ErrorAction SilentlyContinue)
    return @(Get-CodexExecutablePathsFromProcesses -Processes $processes)
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
        [Parameter(Mandatory)] [string[]] $ShortcutPaths)

    $codexState = Read-CodexPlusPlusState -Path $StatePath
    $statusText = ""
    if ($null -ne $codexState)
    {
        $statusText = (Invoke-CodexPlusPlus -CommandInfo $CommandInfo -Arguments @("status")) -join [Environment]::NewLine
    }
    $linkState = Get-TweakLinkState -LinkPath $LinkPath -ExpectedTarget $ExpectedTweakPath
    $launcherState = Get-CodexLauncherState -ExpectedExecutable $ExpectedLaunchExecutable `
        -CommandPath $LauncherCommandPath -ShortcutPaths $ShortcutPaths
    $runningPaths = Get-CodexExecutablePaths
    $maintenanceState = Get-CodexMaintenanceState `
        -AppLayout $AppLayout `
        -CodexState $codexState `
        -StatusText $statusText `
        -LinkStatus $linkState.Status `
        -LauncherStatus $launcherState.Status `
        -RunningExecutablePaths $runningPaths

    return [pscustomobject] @{
        CodexState = $codexState
        LinkState = $linkState
        LauncherState = $launcherState
        RunningPaths = $runningPaths
        MaintenanceState = $maintenanceState
    }
}

try
{
    if (!$env:APPDATA) { throw "APPDATA is not available." }
    if (!$env:LOCALAPPDATA) { throw "LOCALAPPDATA is not available." }
    if (!$env:USERPROFILE) { throw "USERPROFILE is not available." }

    $expectedTweakPath = Join-Path $PSScriptRoot "codex-tweak"
    $tweakManifestPath = Join-Path $expectedTweakPath "manifest.json"
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
    $shortcutPaths = @(
        (Join-Path $env:USERPROFILE "Desktop/Codex++.lnk"),
        (Join-Path $env:APPDATA "Microsoft/Windows/Start Menu/Programs/Codex++.lnk"))
    $context = Get-LiveMaintenanceContext `
        -CommandInfo $command `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $expectedTweakPath `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -ShortcutPaths $shortcutPaths

    Write-Host "Status: $($context.MaintenanceState.Status)"
    Write-Host "Codex++: $version"
    Write-Host "Codex Appx: $($package.PackageFullName)"
    Write-Host "Official app: $($appLayout.OfficialAppRoot)"
    Write-Host "Managed mirror: $($appLayout.MirrorAppRoot)"
    Write-Host "Launch executable: $($launchLayout.MirrorExecutable)"
    Write-Host "Tweak source: $expectedTweakPath"

    if ($CheckOnly)
    {
        if ($context.MaintenanceState.Status -eq "Blocked") { exit 2 }
        exit 0
    }

    if ($context.MaintenanceState.Status -eq "Blocked")
    {
        if ($context.MaintenanceState.UnsafeLink)
        {
            [Console]::Error.WriteLine("Blocked: the live tweak path is a real directory and will not be replaced: $linkPath")
        }
        else
        {
            [Console]::Error.WriteLine("Blocked: Codex is running from the target managed mirror. Close Codex and run this script again.")
        }
        exit 2
    }

    $injectionChanged = $false
    if ($context.MaintenanceState.InjectionRequired)
    {
        $repairArguments = @("repair", "--force", "--app", $appLayout.OfficialAppRoot)
        Invoke-CodexPlusPlus -CommandInfo $command -Arguments $repairArguments | ForEach-Object { Write-Host $_ }
        $injectionChanged = $true
    }

    $context = Get-LiveMaintenanceContext `
        -CommandInfo $command `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $expectedTweakPath `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -ShortcutPaths $shortcutPaths
    if ($context.MaintenanceState.InjectionRequired)
    {
        throw "Codex++ repair completed but the latest managed mirror is not current."
    }
    if ($context.LinkState.Status -eq "Unsafe")
    {
        throw "The live tweak path became unsafe during maintenance: $linkPath"
    }

    $launcherChanged = Set-CodexLauncherArtifacts -ExpectedExecutable $launchLayout.MirrorExecutable `
        -CommandPath $launcherCommandPath -ShortcutPaths $shortcutPaths
    $linkChanged = Set-TweakJunction -LinkPath $linkPath -ExpectedTarget $expectedTweakPath
    $context = Get-LiveMaintenanceContext `
        -CommandInfo $command `
        -AppLayout $appLayout `
        -StatePath $statePath `
        -LinkPath $linkPath `
        -ExpectedTweakPath $expectedTweakPath `
        -ExpectedLaunchExecutable $launchLayout.MirrorExecutable `
        -LauncherCommandPath $launcherCommandPath `
        -ShortcutPaths $shortcutPaths
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
