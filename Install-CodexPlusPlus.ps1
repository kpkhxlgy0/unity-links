[CmdletBinding()]
param(
    [switch] $CheckOnly)

$ErrorActionPreference = "Stop"

$codexPlusPlusVersion = [version] "1.0.0"
$codexPlusPlusCommit = "f98e7e9d1fa068dde9e0dddfb43b128acb4e2fd7"
$archiveUri = "https://codeload.github.com/b-nnett/codex-plusplus/zip/$codexPlusPlusCommit"
$modulePath = Join-Path $PSScriptRoot "scripts/UnityLinkMaintenance.psm1"
$injectScript = Join-Path $PSScriptRoot "Inject-CodexPlusPlus.ps1"
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
        Write-Host "Recovered an abandoned Editor Links maintenance lock." `
            -ForegroundColor Yellow
    }

    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $PSScriptRoot
    Assert-UnityLinkComponentInitialized -Layout $layout -Component CodexTweak

    if (!$env:USERPROFILE) { throw "USERPROFILE is not available." }
    if (!$env:LOCALAPPDATA) { throw "LOCALAPPDATA is not available." }
    if (!$env:APPDATA) { throw "APPDATA is not available." }

    $sourceRoot = Resolve-NormalizedPath (Join-Path $env:USERPROFILE ".codex-plusplus/source")
    $expectedSourceRoot = Resolve-NormalizedPath (Join-Path ([Environment]::GetFolderPath("UserProfile")) ".codex-plusplus/source")
    if (!(Test-PathEqual $sourceRoot $expectedSourceRoot))
    {
        throw "Refusing to use an unexpected Codex++ source root: $sourceRoot"
    }

    $package = Select-LatestCodexPackage -Packages @(Get-AppxPackage -Name OpenAI.Codex)
    $appLayout = Get-CodexAppLayout -Package $package -LocalAppData $env:LOCALAPPDATA
    $launchLayout = Get-CodexPackageLaunchLayout -Package $package -AppLayout $appLayout
    $statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
    if (!(Test-Path -LiteralPath $appLayout.OfficialAsar -PathType Leaf))
    {
        throw "Official Codex ASAR not found: $($appLayout.OfficialAsar)"
    }

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
    $codexRunning = @($processSnapshot.ExecutablePaths).Count -gt 0

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
        $installState | Add-Member `
            -NotePropertyName BlockReason `
            -NotePropertyValue $installBlockReason
    }

    Write-Host "Status: $($installState.Status)"
    Write-Host "Reason: $($installState.Reason)"
    if ($installState.BlockReason)
    {
        Write-Host "Block reason: $($installState.BlockReason)"
    }
    Write-Host "Pinned Codex++: $codexPlusPlusVersion ($codexPlusPlusCommit)"
    Write-Host "Codex Appx: $($package.PackageFullName)"
    Write-Host "Source root: $sourceRoot"

    if ($CheckOnly)
    {
        if ($installState.Status -eq "Blocked")
        {
            [Console]::Error.WriteLine(
                "Blocked [$($installState.BlockReason)]: $($installState.Reason)")
            exit 2
        }
        exit 0
    }
    if ($installState.Status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [$($installState.BlockReason)]: $($installState.Reason)")
        exit 2
    }
    if ($installState.Status -eq "Current")
    {
        Exit-CodexMaintenanceLock -LockHandle $maintenanceLock
        $maintenanceLock = $null
        $pwshPath = (Get-Process -Id $PID).Path
        & $pwshPath -NoProfile -File $injectScript
        if ($LASTEXITCODE -eq 2) { exit 2 }
        if ($LASTEXITCODE -ne 0) { throw "Inject-CodexPlusPlus.ps1 exited with $LASTEXITCODE." }
        exit 0
    }

    $workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("unity-links-codexpp-" + [guid]::NewGuid().ToString("N"))
    $archivePath = Join-Path $workRoot "source.zip"
    $extractRoot = Join-Path $workRoot "extract"
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Invoke-WebRequest -Uri $archiveUri -OutFile $archivePath -UseBasicParsing
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
    $extracted = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
    if ($extracted.Count -ne 1) { throw "Expected exactly one Codex++ source root in the pinned archive." }
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
        $initialInstallSucceeded = $true
    }
    catch
    {
        if (!$initialInstallSucceeded)
        {
            Restore-PreviousSource -SourceRoot $sourceRoot -PreviousRoot $previousRoot -WorkRoot $workRoot
        }
        throw
    }

    $installedCommand = Get-Command codexplusplus -ErrorAction SilentlyContinue
    if ($null -eq $installedCommand) { throw "Pinned Codex++ installed but its command shim was not found." }
    $shimVersion = Get-CommandVersion -CommandInfo $installedCommand
    if ($shimVersion -ne $codexPlusPlusVersion)
    {
        throw "Expected the installed Codex++ command to report 1.0.0, found $shimVersion."
    }

    if (Test-Path -LiteralPath $previousRoot)
    {
        $expectedPreviousRoot = "$expectedSourceRoot.previous"
        Remove-VerifiedTree -Path $previousRoot -ExpectedPath $expectedPreviousRoot
    }

    Exit-CodexMaintenanceLock -LockHandle $maintenanceLock
    $maintenanceLock = $null
    $pwshPath = (Get-Process -Id $PID).Path
    & $pwshPath -NoProfile -File $injectScript
    if ($LASTEXITCODE -eq 2) { exit 2 }
    if ($LASTEXITCODE -ne 0)
    {
        throw "Codex++ 1.0.0 was installed, but Inject-CodexPlusPlus.ps1 exited with $LASTEXITCODE."
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
