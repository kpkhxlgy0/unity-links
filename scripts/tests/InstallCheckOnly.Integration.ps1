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
$originalAppData = $env:APPDATA

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

$scenarioRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "unity-links-install-junctions-" + [guid]::NewGuid().ToString("N"))
$scenarioResults = @()
try
{
    foreach ($scenario in @("Missing", "WrongTarget", "Unsafe"))
    {
        $env:APPDATA = Join-Path $scenarioRoot $scenario
        $scenarioStatePath = Join-Path $env:APPDATA "codex-plusplus/state.json"
        $scenarioLinkPath = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
        New-Item -ItemType Directory -Path (Split-Path $scenarioStatePath -Parent) -Force | Out-Null
        if (Test-Path -LiteralPath $statePath -PathType Leaf)
        {
            Copy-Item -LiteralPath $statePath -Destination $scenarioStatePath
        }

        if ($scenario -eq "WrongTarget")
        {
            $wrongTarget = Join-Path $scenarioRoot "$scenario/old-codex-tweak"
            New-Item -ItemType Directory -Path $wrongTarget -Force | Out-Null
            New-Item -ItemType Junction -Path $scenarioLinkPath -Target $wrongTarget -Force | Out-Null
        }
        elseif ($scenario -eq "Unsafe")
        {
            New-Item -ItemType Directory -Path $scenarioLinkPath -Force | Out-Null
        }

        $linkBefore = Get-LinkSnapshot $scenarioLinkPath
        $output = & $pwshPath -NoProfile -File $entryPoint -CheckOnly 2>&1
        $exitCode = $LASTEXITCODE
        $text = $output -join [Environment]::NewLine
        if ($exitCode -notin @(0, 2))
        {
            throw "Install junction-independence check for $scenario exited with $exitCode`: $text"
        }
        if ($linkBefore -cne (Get-LinkSnapshot $scenarioLinkPath))
        {
            throw "Install -CheckOnly changed the $scenario junction fixture."
        }

        $statusLine = @($output | Where-Object { "$_" -match '^Status: ' }) -join "|"
        $blockedLine = @($output | Where-Object { "$_" -match '^Blocked \[' }) -join "|"
        $scenarioResults += [pscustomobject] @{
            Scenario = $scenario
            Signature = "$exitCode|$statusLine|$blockedLine"
            Text = $text
        }
    }
}
finally
{
    $env:APPDATA = $originalAppData
    if (Test-Path -LiteralPath $scenarioRoot)
    {
        Remove-Item -LiteralPath $scenarioRoot -Recurse -Force
    }
}

$expectedSignature = $scenarioResults[0].Signature
foreach ($result in $scenarioResults)
{
    if ($result.Signature -cne $expectedSignature)
    {
        throw "Install result depended on junction state $($result.Scenario): " +
            "$($result.Signature), expected $expectedSignature"
    }
    foreach ($forbidden in @("Tweak source:", "LinkRequired", "UnsafeLink", "live tweak path"))
    {
        if ($result.Text.Contains($forbidden))
        {
            throw "Install output for $($result.Scenario) still contains junction state: $forbidden"
        }
    }
}

Write-Host "PASS Install-CodexPlusPlus.ps1 -CheckOnly ignores junction state and does not mutate maintenance state"
