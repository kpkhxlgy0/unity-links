$ErrorActionPreference = "Stop"

function Get-OptionalFileHash
{
    param([string] $Path)

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return "Missing" }
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

function Get-MaintenanceSnapshot
{
    param(
        [string] $StatePath,
        [string] $ManagedStoreRoot,
        [string] $LinkPath,
        [string] $CommandPath,
        [string] $StartMenuShortcutPath,
        [AllowNull()] [string] $DesktopShortcutPath)

    $mirrors = @(
        Get-ChildItem -LiteralPath $ManagedStoreRoot -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject] @{
                    Name = $_.Name
                    Attributes = [string] $_.Attributes
                    Asar = Get-OptionalFileHash (Join-Path $_.FullName "app/resources/app.asar")
                    Executable = Get-OptionalFileHash (Join-Path $_.FullName "app/ChatGPT.exe")
                }
            })
    return [pscustomobject] @{
        State = Get-OptionalFileHash $StatePath
        Mirrors = $mirrors
        Link = Get-LinkSnapshot $LinkPath
        Command = Get-OptionalFileHash $CommandPath
        StartMenu = Get-ShortcutTarget $StartMenuShortcutPath
        Desktop = if ($DesktopShortcutPath) { Get-ShortcutTarget $DesktopShortcutPath } else { "Unavailable" }
    } | ConvertTo-Json -Compress -Depth 5
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$entryPoint = Join-Path $repositoryRoot "Install-CodexPlusPlus.ps1"
$statePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
$managedStoreRoot = Join-Path $env:LOCALAPPDATA "codex-plusplus/store-apps"
$linkPath = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
$commandPath = Join-Path $env:LOCALAPPDATA "Microsoft/WindowsApps/codex-plusplus-codex.cmd"
$programsPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
if (!$programsPath) { throw "The current user's Start Menu Programs folder is unavailable." }
$startMenuShortcutPath = Join-Path $programsPath "Codex++.lnk"
$desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
$desktopShortcutPath = if ($desktopPath) { Join-Path $desktopPath "Codex++.lnk" } else { $null }
$pwshPath = (Get-Process -Id $PID).Path

foreach ($arguments in @(
        @("-CheckOnly"),
        @("-CheckOnly", "-CleanupAllOldVersions")))
{
    $before = Get-MaintenanceSnapshot `
        -StatePath $statePath `
        -ManagedStoreRoot $managedStoreRoot `
        -LinkPath $linkPath `
        -CommandPath $commandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -DesktopShortcutPath $desktopShortcutPath
    $output = & $pwshPath -NoProfile -File $entryPoint @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = $output -join [Environment]::NewLine
    $output | ForEach-Object { Write-Host $_ }
    if ($exitCode -notin @(0, 2))
    {
        throw "Install-CodexPlusPlus.ps1 $arguments exited with $exitCode."
    }
    foreach ($required in @("Codex Appx:", "Managed mirror:", "Cleanup mode:"))
    {
        if (!$text.Contains($required)) { throw "Install check output is missing '$required'." }
    }
    $expectedMode = if ($arguments -contains "-CleanupAllOldVersions") { "AllOld" } else { "Previous" }
    if (!$text.Contains("Cleanup mode: $expectedMode"))
    {
        throw "Install check did not report cleanup mode $expectedMode."
    }
    $after = Get-MaintenanceSnapshot `
        -StatePath $statePath `
        -ManagedStoreRoot $managedStoreRoot `
        -LinkPath $linkPath `
        -CommandPath $commandPath `
        -StartMenuShortcutPath $startMenuShortcutPath `
        -DesktopShortcutPath $desktopShortcutPath
    if ($before -cne $after)
    {
        throw "Install-CodexPlusPlus.ps1 $arguments changed maintenance state during -CheckOnly."
    }
}

Write-Host "PASS Install-CodexPlusPlus.ps1 -CheckOnly reports maintenance and cleanup without mutation"
