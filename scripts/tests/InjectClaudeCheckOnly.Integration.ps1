$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$entryPoint = Join-Path $repositoryRoot "Inject-ClaudePlusPlus.ps1"
$scriptsRoot = Join-Path $repositoryRoot "scripts"
$pwshPath = (Get-Process -Id $PID).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) (
    "unity-links-claude-inject-" + [guid]::NewGuid().ToString("N"))
$originalAppData = $env:APPDATA
$originalPath = $env:PATH

try
{
    $env:APPDATA = Join-Path $root "AppData/Roaming"
    $env:PATH = ""
    $liveLink = Join-Path $env:APPDATA "claude-plusplus/tweaks/com.kpk.unity-asset-links"
    Import-Module (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Force
    Import-Module (Join-Path $scriptsRoot "CodexTweakLink.psm1") -Force
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $repositoryRoot

    $checkOutput = & $pwshPath -NoProfile -File $entryPoint -CheckOnly 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Inject-ClaudePlusPlus.ps1 -CheckOnly exited with $LASTEXITCODE`: $checkOutput"
    }
    if (($checkOutput -join [Environment]::NewLine) -notmatch "Status: LinkRequired")
    {
        throw "Claude inject check did not report LinkRequired: $checkOutput"
    }
    if (Test-Path -LiteralPath $liveLink)
    {
        throw "Claude inject -CheckOnly created the live tweak link."
    }

    $applyOutput = & $pwshPath -NoProfile -File $entryPoint 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Inject-ClaudePlusPlus.ps1 exited with $LASTEXITCODE`: $applyOutput"
    }
    $linkState = Get-TweakLinkState -LinkPath $liveLink -ExpectedTarget $layout.ClaudeTweakRoot
    if ($linkState.Status -ne "Current")
    {
        throw "Claude inject did not create the expected junction: $($linkState.Status)"
    }

    $repeatOutput = & $pwshPath -NoProfile -File $entryPoint 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Repeated Inject-ClaudePlusPlus.ps1 exited with $LASTEXITCODE`: $repeatOutput"
    }
    if (($repeatOutput -join [Environment]::NewLine) -notmatch "already current")
    {
        throw "Repeated Claude inject did not report an idempotent result: $repeatOutput"
    }
}
finally
{
    $env:APPDATA = $originalAppData
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host "PASS Inject-ClaudePlusPlus.ps1 manages only the Claude tweak junction"
