$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$entryPoint = Join-Path $repositoryRoot "Uninject-CodexPlusPlus.ps1"
$modulePath = Join-Path $repositoryRoot "scripts/UnityLinkMaintenance.psm1"
$pwshPath = (Get-Process -Id $PID).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) (
    "unity-links-uninject-" + [guid]::NewGuid().ToString("N"))
$originalAppData = $env:APPDATA
$originalPath = $env:PATH

try
{
    $env:APPDATA = Join-Path $root "AppData/Roaming"
    $env:PATH = ""
    $liveLink = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
    $sentinel = Join-Path $env:APPDATA "codex-plusplus/tweaks/keep.txt"
    Import-Module $modulePath -Force
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $repositoryRoot
    Set-TweakJunction -LinkPath $liveLink -ExpectedTarget $layout.TweakRoot | Out-Null
    [System.IO.File]::WriteAllText($sentinel, "keep")

    $checkOutput = & $pwshPath -NoProfile -File $entryPoint -CheckOnly 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Uninject-CodexPlusPlus.ps1 -CheckOnly exited with $LASTEXITCODE`: $checkOutput"
    }
    if (($checkOutput -join [Environment]::NewLine) -notmatch "Status: UninjectRequired")
    {
        throw "Uninject check did not report UninjectRequired: $checkOutput"
    }
    if (!(Test-Path -LiteralPath $liveLink))
    {
        throw "Uninject -CheckOnly removed the live tweak link."
    }

    $applyOutput = & $pwshPath -NoProfile -File $entryPoint 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Uninject-CodexPlusPlus.ps1 exited with $LASTEXITCODE`: $applyOutput"
    }
    if (Test-Path -LiteralPath $liveLink)
    {
        throw "Uninject did not remove the live tweak junction."
    }
    if (!(Test-Path -LiteralPath $sentinel -PathType Leaf))
    {
        throw "Uninject removed an unrelated tweak sibling."
    }
}
finally
{
    $env:APPDATA = $originalAppData
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host "PASS Uninject-CodexPlusPlus.ps1 removes only the tweak junction"
