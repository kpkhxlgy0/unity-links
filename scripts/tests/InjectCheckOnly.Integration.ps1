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

function Get-ShortcutTarget
{
    param([string] $Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return "Missing" }
    $shell = New-Object -ComObject WScript.Shell
    return $shell.CreateShortcut($Path).TargetPath
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$entryPoint = Join-Path $repositoryRoot "Inject-CodexPlusPlus.ps1"
$statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
$liveLink = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
$modulePath = Join-Path $repositoryRoot "scripts/UnityLinkMaintenance.psm1"
Import-Module $modulePath -Force
$package = Select-LatestCodexPackage -Packages @(Get-AppxPackage -Name OpenAI.Codex)
$appLayout = Get-CodexAppLayout -Package $package -LocalAppData $env:LOCALAPPDATA

$beforeState = Get-OptionalFileHash $statePath
$beforeLink = Get-LinkSnapshot $liveLink
$beforeAsar = Get-OptionalFileHash $appLayout.MirrorAsar
$commandPath = Join-Path $env:LOCALAPPDATA "Microsoft/WindowsApps/codex-plusplus-codex.cmd"
$programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
if (!$programsPath) { throw "The current user's Start Menu Programs folder is unavailable." }
$startMenuShortcutPath = Join-Path $programsPath "Codex++.lnk"
$desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
$desktopShortcutPath = if ($desktopPath) { Join-Path $desktopPath "Codex++.lnk" } else { $null }
$beforeCommand = Get-OptionalFileHash $commandPath
$beforeStartMenuTarget = Get-ShortcutTarget $startMenuShortcutPath
$beforeDesktopTarget = if ($desktopShortcutPath) { Get-ShortcutTarget $desktopShortcutPath } else { "Unavailable" }
$launchLayout = Get-CodexPackageLaunchLayout -Package $package -AppLayout $appLayout
$beforeLauncherState = Get-CodexLauncherState -ExpectedExecutable $launchLayout.MirrorExecutable `
    -CommandPath $commandPath -StartMenuShortcutPath $startMenuShortcutPath
$pwshPath = (Get-Process -Id $PID).Path

$output = & $pwshPath -NoProfile -File $entryPoint -CheckOnly 2>&1
$entryPointExitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Host $_ }

if ($entryPointExitCode -ne 0)
{
    throw "Inject-CodexPlusPlus.ps1 -CheckOnly exited with $entryPointExitCode."
}
if ($beforeLauncherState.Status -eq "Required" -and
    ($output -join [Environment]::NewLine) -notmatch "Status: LauncherRequired")
{
    throw "Inject-CodexPlusPlus.ps1 did not detect the stale Codex++ launcher."
}
if ($beforeState -cne (Get-OptionalFileHash $statePath))
{
    throw "Codex++ state changed during -CheckOnly."
}
if ($beforeLink -cne (Get-LinkSnapshot $liveLink))
{
    throw "The live tweak link changed during -CheckOnly."
}
if ($beforeAsar -cne (Get-OptionalFileHash $appLayout.MirrorAsar))
{
    throw "The latest managed ASAR changed during -CheckOnly."
}
if ($beforeCommand -cne (Get-OptionalFileHash $commandPath))
{
    throw "The Codex++ command launcher changed during -CheckOnly."
}
if ($beforeStartMenuTarget -cne (Get-ShortcutTarget $startMenuShortcutPath))
{
    throw "The Codex++ Start Menu shortcut changed during -CheckOnly."
}
if ($desktopShortcutPath -and $beforeDesktopTarget -cne (Get-ShortcutTarget $desktopShortcutPath))
{
    throw "The legacy Codex++ desktop shortcut changed during -CheckOnly."
}

Write-Host "PASS Inject-CodexPlusPlus.ps1 -CheckOnly is mutation-free"
