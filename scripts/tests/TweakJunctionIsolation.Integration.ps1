$ErrorActionPreference = "Stop"

function Invoke-TweakEntryPoint
{
    param(
        [Parameter(Mandatory)] [string] $EntryPoint,
        [string[]] $Arguments = @())

    $output = & $script:PwshPath -NoProfile -File $EntryPoint @Arguments 2>&1
    return [pscustomobject] @{
        ExitCode = $LASTEXITCODE
        Text = $output -join [Environment]::NewLine
    }
}

function Assert-BlockedFixture
{
    param(
        [Parameter(Mandatory)] [string] $EntryPoint,
        [Parameter(Mandatory)] [string] $FixtureName)

    $result = Invoke-TweakEntryPoint -EntryPoint $EntryPoint -Arguments @("-CheckOnly")
    if ($result.ExitCode -ne 2 -or $result.Text -notmatch "Status: Blocked")
    {
        throw "$FixtureName was not safely blocked by $EntryPoint`: $($result.Text)"
    }
}

$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$injectCodex = Join-Path $repositoryRoot "Inject-CodexPlusPlus.ps1"
$uninjectCodex = Join-Path $repositoryRoot "Uninject-CodexPlusPlus.ps1"
$injectClaude = Join-Path $repositoryRoot "Inject-ClaudePlusPlus.ps1"
$uninjectClaude = Join-Path $repositoryRoot "Uninject-ClaudePlusPlus.ps1"
$scriptsRoot = Join-Path $repositoryRoot "scripts"
$script:PwshPath = (Get-Process -Id $PID).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) (
    "unity-links-tweak-isolation-" + [guid]::NewGuid().ToString("N"))
$originalAppData = $env:APPDATA
$originalPath = $env:PATH

try
{
    $env:APPDATA = Join-Path $root "AppData/Roaming"
    $env:PATH = ""
    $codexLink = Join-Path $env:APPDATA "codex-plusplus/tweaks/com.kpk.unity-asset-links"
    $claudeLink = Join-Path $env:APPDATA "claude-plusplus/tweaks/com.kpk.unity-asset-links"
    Import-Module (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Force
    Import-Module (Join-Path $scriptsRoot "CodexTweakLink.psm1") -Force
    $layout = Get-UnityLinkRepositoryLayout -RepositoryRoot $repositoryRoot

    $claudeInjectResult = Invoke-TweakEntryPoint -EntryPoint $injectClaude
    if ($claudeInjectResult.ExitCode -ne 0) { throw $claudeInjectResult.Text }
    if (Test-Path -LiteralPath $codexLink) { throw "Claude inject changed the Codex tweak path." }

    $codexInjectResult = Invoke-TweakEntryPoint -EntryPoint $injectCodex
    if ($codexInjectResult.ExitCode -ne 0) { throw $codexInjectResult.Text }
    if ((Get-TweakLinkState $claudeLink $layout.ClaudeTweakRoot).Status -ne "Current")
    {
        throw "Codex inject changed the Claude tweak path."
    }
    if ((Get-TweakLinkState $codexLink $layout.TweakRoot).Status -ne "Current")
    {
        throw "Codex inject did not create its own tweak junction."
    }

    $claudeUninjectResult = Invoke-TweakEntryPoint -EntryPoint $uninjectClaude
    if ($claudeUninjectResult.ExitCode -ne 0) { throw $claudeUninjectResult.Text }
    if ((Get-TweakLinkState $codexLink $layout.TweakRoot).Status -ne "Current")
    {
        throw "Claude uninject changed the Codex tweak path."
    }

    $codexUninjectResult = Invoke-TweakEntryPoint -EntryPoint $uninjectCodex
    if ($codexUninjectResult.ExitCode -ne 0) { throw $codexUninjectResult.Text }

    New-Item -ItemType Directory -Path $claudeLink -Force | Out-Null
    $directorySentinel = Join-Path $claudeLink "keep.txt"
    [System.IO.File]::WriteAllText($directorySentinel, "keep")
    Assert-BlockedFixture -EntryPoint $injectClaude -FixtureName "Real directory"
    Assert-BlockedFixture -EntryPoint $uninjectClaude -FixtureName "Real directory"
    if (!(Test-Path -LiteralPath $directorySentinel -PathType Leaf))
    {
        throw "A blocked Claude operation changed the real directory fixture."
    }
    Remove-Item -LiteralPath $claudeLink -Recurse -Force

    $symbolicTarget = Join-Path $root "symbolic-target"
    New-Item -ItemType Directory -Path $symbolicTarget -Force | Out-Null
    $symbolicSentinel = Join-Path $symbolicTarget "keep.txt"
    [System.IO.File]::WriteAllText($symbolicSentinel, "keep")
    New-Item -ItemType SymbolicLink -Path $claudeLink -Target $symbolicTarget | Out-Null
    Assert-BlockedFixture -EntryPoint $injectClaude -FixtureName "Symbolic link"
    Assert-BlockedFixture -EntryPoint $uninjectClaude -FixtureName "Symbolic link"
    if ((Get-Item -LiteralPath $claudeLink -Force).LinkType -ne "SymbolicLink")
    {
        throw "A blocked Claude operation replaced the symbolic link fixture."
    }
    if (!(Test-Path -LiteralPath $symbolicSentinel -PathType Leaf))
    {
        throw "A blocked Claude operation changed the symbolic link target."
    }
}
finally
{
    $env:APPDATA = $originalAppData
    $env:PATH = $originalPath
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

Write-Host "PASS Codex and Claude junction operations remain isolated and reject unsafe paths"
