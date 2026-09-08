$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "TestHarness.ps1")
$scriptsRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $scriptsRoot "UnityLinkCommon.psm1") -Force
Import-Module (Join-Path $scriptsRoot "CodexPlusPlusMaintenance.psm1") -Force

$installerPath = Join-Path (Split-Path $scriptsRoot -Parent) "Install-CodexPlusPlus.ps1"
$tokens = $null
$parseErrors = $null
$installer = [System.Management.Automation.Language.Parser]::ParseFile(
    $installerPath, [ref] $tokens, [ref] $parseErrors)
Assert-Equal 0 @($parseErrors).Count

# 执行安装入口的路径读取和实参表达式，避开下载、源码替换及真实应用修改。
$recordedRootFunction = $installer.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq "Get-RecordedAppRoot"
    }, $true)
. ([scriptblock]::Create($recordedRootFunction.Extent.Text))
$mutationCall = $installer.Find({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -eq "Invoke-CodexMutationSafely"
    }, $true)
$targetParameter = @($mutationCall.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
            $_.ParameterName -eq "TargetAppRoots"
    })
Assert-Equal 1 $targetParameter.Count
$argumentIndex = $mutationCall.CommandElements.IndexOf($targetParameter[0]) + 1
$targetRootsExpression = [scriptblock]::Create($mutationCall.CommandElements[$argumentIndex].Extent.Text)

function Invoke-InstallerMutationTest
{
    param(
        [AllowNull()] [object] $State,
        [scriptblock] $ProcessQuery = { @() })

    # 与安装入口保持相同的非严格模式，避免继承测试框架的额外约束。
    Set-StrictMode -Off
    $previousAppRoot = Get-RecordedAppRoot -State $State
    $targetAppRoots = @(& $targetRootsExpression)
    return Invoke-CodexMutationSafely `
        -TargetAppRoots $targetAppRoots `
        -ProcessQuery $ProcessQuery `
        -Mutation { "installer invoked" }
}

foreach ($case in @(
        @{ Name = "missing state"; State = $null },
        @{ Name = "missing appRoot"; State = [pscustomobject] @{} },
        @{ Name = "empty appRoot"; State = [pscustomobject] @{ appRoot = "" } }))
{
    Test-Case "Codex install invokes native discovery with $($case.Name)" {
        $result = Invoke-InstallerMutationTest -State $case.State
        Assert-True $result.Invoked
        Assert-True $result.Succeeded
        Assert-Equal "installer invoked" $result.Output[0]
    }
}

Test-Case "Codex install preserves the running recorded app guard" {
    $result = Invoke-InstallerMutationTest -State ([pscustomobject] @{ appRoot = "C:\mirror\app" }) `
        -ProcessQuery {
            [pscustomobject] @{ ExecutablePath = "C:\mirror\app\Codex.exe" }
        }
    Assert-True (!$result.Invoked)
    Assert-Equal "DesktopAppRunning" $result.BlockReason
    Assert-Equal 0 $result.Output.Count
}

Test-Case "Codex install proceeds when the recorded app is stopped" {
    $result = Invoke-InstallerMutationTest -State ([pscustomobject] @{ appRoot = "C:\mirror\app" })
    Assert-True $result.Invoked
    Assert-True $result.Succeeded
    Assert-Equal "installer invoked" $result.Output[0]
}

Test-Case "Codex install blocks failed process discovery even without a recorded app" {
    $result = Invoke-InstallerMutationTest -State $null -ProcessQuery { throw "process query failed" }
    Assert-True (!$result.Invoked)
    Assert-Equal "ProcessQueryFailed" $result.BlockReason
    Assert-Equal 0 $result.Output.Count
}

Complete-Tests
