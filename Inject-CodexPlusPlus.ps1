[CmdletBinding()]
param(
    [switch] $CheckOnly)

$ErrorActionPreference = "Stop"

$scriptsRoot = Join-Path $PSScriptRoot "scripts"
Import-Module (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Force
Import-Module (Join-Path $scriptsRoot "CodexTweakLink.psm1") -Force

try
{
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $PSScriptRoot
    Assert-UnityLinkComponentInitialized -Layout $layout -Component CodexTweak
    if (!$env:APPDATA) { throw "APPDATA is not available." }

    $linkPath = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
    $linkState = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $layout.TweakRoot
    $status = switch ($linkState.Status)
    {
        "Current" { "Current" }
        "Unsafe" { "Blocked" }
        default { "LinkRequired" }
    }

    Write-Host "Status: $status"
    Write-Host "Tweak source: $($layout.TweakRoot)"
    Write-Host "Tweak link: $linkPath"
    if ($linkState.Target) { Write-Host "Current target: $($linkState.Target)" }

    if ($status -eq "Blocked")
    {
        [Console]::Error.WriteLine(
            "Blocked [UnsafeLink]: the live tweak path is a real directory or unsupported reparse point.")
        exit 2
    }
    if ($CheckOnly) { exit 0 }

    $changed = Set-TweakJunction -LinkPath $linkPath -ExpectedTarget $layout.TweakRoot
    $verified = Get-TweakLinkState -LinkPath $linkPath -ExpectedTarget $layout.TweakRoot
    if ($verified.Status -ne "Current")
    {
        throw "Tweak junction verification failed: $($verified.Status)"
    }

    if ($changed)
    {
        Write-Host "Created the Unity Links tweak junction. Restart Codex to load it."
    }
    else
    {
        Write-Host "The Unity Links tweak junction is already current."
    }
}
catch
{
    Write-Error $_
    exit 1
}
