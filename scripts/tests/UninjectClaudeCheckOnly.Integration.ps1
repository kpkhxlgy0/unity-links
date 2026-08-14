$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$entryPoint = Join-Path $repositoryRoot "Uninject-ClaudePlusPlus.ps1"
$scriptsRoot = Join-Path $repositoryRoot "scripts"
$pwshPath = (Get-Process -Id $PID).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) (
    "unity-links-claude-uninject-" + [guid]::NewGuid().ToString("N"))
$originalAppData = $env:APPDATA
$originalPath = $env:PATH

try
{
    $env:APPDATA = Join-Path $root "AppData/Roaming"
    $env:PATH = ""
    $liveLink = Join-Path $env:APPDATA "claude-plusplus/tweaks/com.kpk.unity-asset-links"
    $sentinel = Join-Path $env:APPDATA "claude-plusplus/tweaks/keep.txt"
    Import-Module (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Force
    Import-Module (Join-Path $scriptsRoot "CodexTweakLink.psm1") -Force
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $repositoryRoot
    Set-TweakJunction -LinkPath $liveLink -ExpectedTarget $layout.ClaudeTweakRoot | Out-Null
    [System.IO.File]::WriteAllText($sentinel, "keep")

    $checkOutput = & $pwshPath -NoProfile -File $entryPoint -CheckOnly 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Uninject-ClaudePlusPlus.ps1 -CheckOnly exited with $LASTEXITCODE`: $checkOutput"
    }
    if (($checkOutput -join [Environment]::NewLine) -notmatch "Status: UninjectRequired")
    {
        throw "Claude uninject check did not report UninjectRequired: $checkOutput"
    }
    if (!(Test-Path -LiteralPath $liveLink))
    {
        throw "Claude uninject -CheckOnly removed the live tweak link."
    }

    $applyOutput = & $pwshPath -NoProfile -File $entryPoint 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw "Uninject-ClaudePlusPlus.ps1 exited with $LASTEXITCODE`: $applyOutput"
    }
    if (Test-Path -LiteralPath $liveLink)
    {
        throw "Claude uninject did not remove the live tweak junction."
    }
    if (!(Test-Path -LiteralPath $sentinel -PathType Leaf))
    {
        throw "Claude uninject removed an unrelated tweak sibling."
    }
    if (!(Test-Path -LiteralPath $layout.ClaudeTweakRoot -PathType Container))
    {
        throw "Claude uninject removed the tweak source directory."
    }
}
finally
{
    $env:APPDATA = $originalAppData
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host "PASS Uninject-ClaudePlusPlus.ps1 removes only the Claude tweak junction"
