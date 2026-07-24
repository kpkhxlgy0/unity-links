[CmdletBinding()]
param(
    [switch] $CheckOnly)

$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "scripts/UnityLinkMaintenance.psm1"
Import-Module $modulePath -Force

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

try
{
    if (!$env:APPDATA) { throw "APPDATA is not available." }

    $statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
    $linkPath = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
    $expectedTweakPath = Join-Path $PSScriptRoot "codex-tweak"
    $codexState = Read-CodexPlusPlusState -Path $statePath
    $codexPlusPlus = Get-Command codexplusplus -ErrorAction SilentlyContinue
    $linkState = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $expectedTweakPath
    $uninject = Get-CodexUninjectState `
        -CodexState $codexState `
        -HasCommand ($null -ne $codexPlusPlus) `
        -LinkStatus $linkState.Status `
        -RunningExecutablePaths (Get-CodexExecutablePaths)

    Write-Host "Status: $($uninject.Status)"
    Write-Host "Reason: $($uninject.Reason)"
    Write-Host "Recorded app root: $($uninject.AppRoot)"
    Write-Host "Tweak link: $($linkState.Status)"

    if ($CheckOnly)
    {
        if ($uninject.Status -eq "Blocked") { exit 2 }
        exit 0
    }
    if ($uninject.Status -eq "Blocked")
    {
        [Console]::Error.WriteLine("Blocked: $($uninject.Reason)")
        exit 2
    }
    if ($uninject.Status -eq "NotInjected")
    {
        Write-Host "Codex++ is not injected and no tweak link remains."
        exit 0
    }
    if ($uninject.Status -eq "LinkOnly")
    {
        Remove-TweakLink -LinkPath $linkPath | Out-Null
        $verifiedLink = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $expectedTweakPath
        if ($verifiedLink.Status -ne "Missing")
        {
            throw "Tweak link verification failed after removal: $($verifiedLink.Status)"
        }
        Write-Host "Removed the residual Unity link tweak junction."
        exit 0
    }

    $arguments = Get-CodexUninstallArguments -AppRoot $uninject.AppRoot
    $output = & $codexPlusPlus.Source @arguments 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "codexplusplus uninstall failed:" + [Environment]::NewLine + ($output -join [Environment]::NewLine)
    }
    $output | ForEach-Object { Write-Host $_ }
    if (Test-Path -LiteralPath $statePath -PathType Leaf)
    {
        throw "codexplusplus uninstall returned success but state.json still exists; the tweak link was retained."
    }

    Remove-TweakLink -LinkPath $linkPath | Out-Null
    $verifiedLink = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $expectedTweakPath
    if ($verifiedLink.Status -ne "Missing")
    {
        throw "Tweak link verification failed after uninjection: $($verifiedLink.Status)"
    }
    Write-Host "Codex++ injection and the Unity link tweak junction were removed."
}
catch
{
    Write-Error $_
    exit 1
}
