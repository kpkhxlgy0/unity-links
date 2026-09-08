$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TestHarness.ps1")
$scriptsRoot = Split-Path $PSScriptRoot -Parent
$repositoryRoot = Split-Path $scriptsRoot -Parent
Import-Module (Join-Path $scriptsRoot "CodexPlusPlusMaintenance.psm1") -Force

$tokens = $null
$parseErrors = $null
$installer = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repositoryRoot "Install-CodexPlusPlus.ps1"), [ref] $tokens, [ref] $parseErrors)
Assert-Equal 0 @($parseErrors).Count

function Get-InstallerCommand
{
    param([string] $Name)

    $command = $installer.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq $Name
        }, $true)
    return [scriptblock]::Create($command.Extent.Text)
}

Test-Case "install state honors the requested version instead of the module default" {
    $state = Get-CodexPlusPlusInstallState -InstalledVersion ([version] "1.0.2") -NodeMajor 22 `
        -HasNpm $true -RequiredVersion ([version] "1.0.3")
    Assert-Equal "InstallRequired" $state.Status
    Assert-True ($state.Reason -match '1\.0\.3')
}

foreach ($version in @("1.0.3", "1.1.0"))
{
    Test-Case "install state accepts $version for requested 1.0.3" {
        $state = Get-CodexPlusPlusInstallState -InstalledVersion ([version] $version) -NodeMajor 22 `
            -HasNpm $true -RequiredVersion ([version] "1.0.3")
        Assert-Equal "Current" $state.Status
    }
}

Test-Case "install state supports another requested version and preserves prerequisites" {
    $state = Get-CodexPlusPlusInstallState -InstalledVersion ([version] "1.0.3") -NodeMajor 22 `
        -HasNpm $true -RequiredVersion ([version] "1.2.0")
    Assert-Equal "InstallRequired" $state.Status
    Assert-True ($state.Reason -match '1\.2\.0')
    $blocked = Get-CodexPlusPlusInstallState -InstalledVersion ([version] "1.0.2") -NodeMajor 18 `
        -HasNpm $true -RequiredVersion ([version] "1.0.3")
    Assert-Equal "Blocked" $blocked.Status
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-version-test-" + [guid]::NewGuid().ToString("N"))
try
{
    $sourceRoot = $fixtureRoot
    $cliDirectory = Join-Path $sourceRoot "packages/installer/src"
    [IO.Directory]::CreateDirectory($cliDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $cliDirectory "cli.ts"), "")
    [IO.File]::WriteAllText((Join-Path $sourceRoot "package-lock.json"), "{}")
    [IO.File]::WriteAllText((Join-Path $sourceRoot "package.json"), '{"version":"1.0.3"}')

    Test-Case "source layout accepts the requested source version" {
        Assert-True (Test-CodexPlusPlusSourceLayout -SourceRoot $sourceRoot -ExpectedVersion ([version] "1.0.3"))
    }

    Test-Case "source layout rejects a mismatch against the requested version" {
        Assert-Throws {
            Test-CodexPlusPlusSourceLayout -SourceRoot $sourceRoot -ExpectedVersion ([version] "1.2.0")
        } 'Expected Codex\+\+ source version 1\.2\.0, found 1\.0\.3'
    }

    # 执行安装脚本中的真实调用，验证入口把目标版本传给模块；不运行下载或安装。
    Test-Case "installer forwards its target to install state detection" {
        $codexPlusPlusVersion = [version] "1.0.3"
        $installedVersion = [version] "1.0.2"
        $nodeMajor = 22
        $npmCommand = [pscustomobject] @{}
        $codexPlusPlusCommand = [pscustomobject] @{}
        $codexRunning = $false
        $state = & (Get-InstallerCommand -Name "Get-CodexPlusPlusInstallState")
        Assert-Equal "InstallRequired" $state.Status
        Assert-True ($state.Reason -match '1\.0\.3')
    }

    Test-Case "installer forwards its target to source layout validation" {
        $codexPlusPlusVersion = [version] "1.0.3"
        $extractedSource = $sourceRoot
        Assert-True (& (Get-InstallerCommand -Name "Test-CodexPlusPlusSourceLayout"))
    }

    Test-Case "source validation preserves literal version matching" {
        [IO.File]::WriteAllText((Join-Path $sourceRoot "package.json"), '{"version":"01.00.003"}')
        Assert-Throws {
            Test-CodexPlusPlusSourceLayout -SourceRoot $sourceRoot -ExpectedVersion ([version] "1.0.3")
        } 'Expected Codex\+\+ source version 1\.0\.3'
    }
}
finally
{
    $resolvedRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (!$resolvedRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase))
    {
        throw "Refusing to remove a fixture outside the temporary directory: $resolvedRoot"
    }
    if (Test-Path -LiteralPath $resolvedRoot)
    {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}

Complete-Tests

