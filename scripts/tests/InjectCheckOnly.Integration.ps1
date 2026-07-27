$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$entryPoint = Join-Path $repositoryRoot "Inject-CodexPlusPlus.ps1"
$modulePath = Join-Path $repositoryRoot "scripts/UnityLinkMaintenance.psm1"
$pwshPath = (Get-Process -Id $PID).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) (
    "unity-links-inject-" + [guid]::NewGuid().ToString("N"))
$originalAppData = $env:APPDATA
$originalPath = $env:PATH

try
{
    $env:APPDATA = Join-Path $root "AppData/Roaming"
    $env:PATH = ""
    $liveLink = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
    Import-Module $modulePath -Force
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $repositoryRoot

    $checkOutput = & $pwshPath -NoProfile -File $entryPoint -CheckOnly 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Inject-CodexPlusPlus.ps1 -CheckOnly exited with $LASTEXITCODE`: $checkOutput"
    }
    if (($checkOutput -join [Environment]::NewLine) -notmatch "Status: LinkRequired")
    {
        throw "Inject check did not report LinkRequired: $checkOutput"
    }
    if (Test-Path -LiteralPath $liveLink)
    {
        throw "Inject -CheckOnly created the live tweak link."
    }

    $applyOutput = & $pwshPath -NoProfile -File $entryPoint 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Inject-CodexPlusPlus.ps1 exited with $LASTEXITCODE`: $applyOutput"
    }
    $linkState = Get-TweakLinkState -LinkPath $liveLink -ExpectedTarget $layout.TweakRoot
    if ($linkState.Status -ne "Current")
    {
        throw "Inject did not create the expected junction: $($linkState.Status)"
    }
}
finally
{
    $env:APPDATA = $originalAppData
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host "PASS Inject-CodexPlusPlus.ps1 manages only the tweak junction"
