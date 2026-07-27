[CmdletBinding()]
param(
    [switch] $CheckOnly)

$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "scripts/UnityLinkMaintenance.psm1"
Import-Module $modulePath -Force

try
{
    if (!$env:APPDATA) { throw "APPDATA is not available." }

    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $PSScriptRoot
    $linkPath = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
    $linkState = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $layout.TweakRoot
    $status = switch ($linkState.Status)
    {
        "Missing" { "NotInjected" }
        "Unsafe" { "Blocked" }
        default { "UninjectRequired" }
    }

    Write-Host "Status: $status"
    Write-Host "Tweak link: $linkPath"
    if ($linkState.Target) { Write-Host "Current target: $($linkState.Target)" }

    if ($status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [UnsafeLink]: the live tweak path is a real directory or unsupported reparse point.")
        exit 2
    }
    if ($CheckOnly -or $status -eq "NotInjected") { exit 0 }

    Remove-TweakLink -LinkPath $linkPath | Out-Null
    $verified = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $layout.TweakRoot
    if ($verified.Status -ne "Missing")
    {
        throw "Tweak junction still exists after removal: $($verified.Status)"
    }
    Write-Host "Removed the Unity Links tweak junction. Restart Codex to unload it."
}
catch
{
    Write-Error $_
    exit 1
}
