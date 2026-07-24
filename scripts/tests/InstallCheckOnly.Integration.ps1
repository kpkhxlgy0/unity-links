$ErrorActionPreference = "Stop"

function Get-OptionalFileHash
{
    param([string] $Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-LinkSnapshot
{
    param([string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return "Missing" }
    $linkType = $item.PSObject.Properties["LinkType"].Value
    $target = @($item.PSObject.Properties["Target"].Value) -join "|"
    return "$linkType|$target"
}

function Get-DirectoryMetadata
{
    param([string] $Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return "Missing" }
    $children = @(Get-ChildItem -LiteralPath $Path -Force | Sort-Object Name | ForEach-Object {
        "$($_.Name)|$($_.Attributes)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)"
    })
    return "$($item.Attributes)|$($item.CreationTimeUtc.Ticks)|$($item.LastWriteTimeUtc.Ticks)|$($children -join ';')"
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$entryPoint = Join-Path $repositoryRoot "Install-CodexPlusPlus.ps1"
$statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
$liveLink = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
$sourceRoot = Join-Path $env:USERPROFILE ".codex-plusplus/source"
$modulePath = Join-Path $repositoryRoot "scripts/UnityLinkMaintenance.psm1"
Import-Module $modulePath -Force
$package = Select-LatestCodexPackage -Packages @(Get-AppxPackage -Name OpenAI.Codex)
$appLayout = Get-CodexAppLayout -Package $package -LocalAppData $env:LOCALAPPDATA

$beforeState = Get-OptionalFileHash $statePath
$beforeLink = Get-LinkSnapshot $liveLink
$beforeSource = Get-DirectoryMetadata $sourceRoot
$beforeAsar = Get-OptionalFileHash $appLayout.MirrorAsar
$pwshPath = (Get-Process -Id $PID).Path

& $pwshPath -NoProfile -File $entryPoint -CheckOnly
$entryPointExitCode = $LASTEXITCODE

if ($entryPointExitCode -ne 0)
{
    throw "Install-CodexPlusPlus.ps1 -CheckOnly exited with $entryPointExitCode."
}
if ($beforeState -cne (Get-OptionalFileHash $statePath))
{
    throw "Codex++ state changed during -CheckOnly."
}
if ($beforeLink -cne (Get-LinkSnapshot $liveLink))
{
    throw "The live tweak link changed during -CheckOnly."
}
if ($beforeSource -cne (Get-DirectoryMetadata $sourceRoot))
{
    throw "The Codex++ source changed during -CheckOnly."
}
if ($beforeAsar -cne (Get-OptionalFileHash $appLayout.MirrorAsar))
{
    throw "The latest managed ASAR changed during -CheckOnly."
}

Write-Host "PASS Install-CodexPlusPlus.ps1 -CheckOnly is mutation-free"
