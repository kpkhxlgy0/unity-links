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
$entryPoint = Join-Path $repositoryRoot "Uninject-CodexPlusPlus.ps1"
$statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
$liveLink = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
$sourceRoot = Join-Path $env:USERPROFILE ".codex-plusplus/source"
$unityManifest = "D:\workspace\sgproj\Packages\manifest.json"
$state = if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
} else {
    $null
}
$recordedAsar = if ($null -ne $state -and $state.appRoot) {
    Join-Path ([string] $state.appRoot) "resources/app.asar"
} else {
    $null
}

$beforeState = Get-OptionalFileHash $statePath
$beforeLink = Get-LinkSnapshot $liveLink
$beforeSource = Get-DirectoryMetadata $sourceRoot
$beforeAsar = Get-OptionalFileHash $recordedAsar
$beforeManifest = Get-OptionalFileHash $unityManifest
$pwshPath = (Get-Process -Id $PID).Path

& $pwshPath -NoProfile -File $entryPoint -CheckOnly
$entryPointExitCode = $LASTEXITCODE

if ($entryPointExitCode -ne 0)
{
    throw "Uninject-CodexPlusPlus.ps1 -CheckOnly exited with $entryPointExitCode."
}
if ($beforeState -cne (Get-OptionalFileHash $statePath)) { throw "Codex++ state changed during -CheckOnly." }
if ($beforeLink -cne (Get-LinkSnapshot $liveLink)) { throw "The live tweak link changed during -CheckOnly." }
if ($beforeSource -cne (Get-DirectoryMetadata $sourceRoot)) { throw "The Codex++ source changed during -CheckOnly." }
if ($beforeAsar -cne (Get-OptionalFileHash $recordedAsar)) { throw "The recorded mirror ASAR changed during -CheckOnly." }
if ($beforeManifest -cne (Get-OptionalFileHash $unityManifest)) { throw "The Unity manifest changed during -CheckOnly." }

Write-Host "PASS Uninject-CodexPlusPlus.ps1 -CheckOnly is mutation-free"
