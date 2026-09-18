$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $repositoryRoot "scripts/CodexPlusPlusMaintenance.psm1") -Force
foreach ($name in @("UnityLinkCommon.psm1", "CodexPlusPlusCommon.psm1", "UnrealLinkCommon.psm1"))
{
    $common = Join-Path $repositoryRoot "scripts/$name"
    if (Test-Path -LiteralPath $common) { Import-Module $common -Force }
}

function Assert-LauncherTest
{
    param([bool] $Condition, [string] $Message)
    if (!$Condition) { throw $Message }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("codex-launcher-consumer-" + [guid]::NewGuid().ToString("N"))
try
{
    $launchExecutable = Join-Path $root "codex-plusplus/store-apps/OpenAI.Codex_test/app/ChatGPT.exe"
    $launcherScriptPath = Join-Path $root "user data %test%/bin/launch-packaged-chatgpt.ps1"
    $launcherCommandPath = Join-Path $root "WindowsApps/codex-plusplus-codex.cmd"
    $startMenuShortcutPath = Join-Path $root "Start Menu/Codex++.lnk"
    foreach ($path in @($launchExecutable, $launcherScriptPath, $launcherCommandPath, $startMenuShortcutPath))
    {
        [IO.Directory]::CreateDirectory((Split-Path $path -Parent)) | Out-Null
    }
    [IO.File]::WriteAllText($launchExecutable, "fixture executable")
    [IO.File]::WriteAllText($launcherScriptPath, "throw 'Fixture must never be executed'")
    $powerShellPath = Join-Path $env:SystemRoot "System32/WindowsPowerShell/v1.0/powershell.exe"
    $arguments = @("-NoLogo", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass", "-File", $launcherScriptPath)
    $command = "@echo off`r`n" + ((@($powerShellPath) + $arguments | ForEach-Object {
                '"' + $_.Replace('%', '%%') + '"'
            }) -join ' ') + " %*`r`n"
    [IO.File]::WriteAllText($launcherCommandPath, $command)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startMenuShortcutPath)
    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $shortcut.Save()

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $repositoryRoot "Install-CodexPlusPlus.ps1"), [ref] $tokens, [ref] $errors)
    Assert-LauncherTest ($errors.Count -eq 0) "Installer has parse errors."
    $call = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -eq "Set-CodexLauncherArtifacts"
        }, $true)
    Assert-LauncherTest ($null -ne $call) "Installer launcher verification call is missing."
    $assignment = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$launcherScriptPath'
        }, $true)
    Assert-LauncherTest ($null -ne $assignment) "Installer does not select a package-aware launcher."
    $statePath = Join-Path (Split-Path (Split-Path $launcherScriptPath -Parent) -Parent) "state.json"
    $managedStoreRoot = Join-Path $root "codex-plusplus/store-apps"
    $currentAppRoot = Split-Path $launchExecutable -Parent
    $selectLauncher = [scriptblock]::Create($assignment.Extent.Text + "`n" + '$launcherScriptPath')
    Assert-LauncherTest ((& $selectLauncher) -eq $launcherScriptPath) "Store launcher must follow the state directory."
    $currentAppRoot = Join-Path $root "standalone/app"
    Assert-LauncherTest ($null -eq (& $selectLauncher)) "Standalone installs must retain their existing launch path."
    $paths = @($launcherScriptPath, $launcherCommandPath, $startMenuShortcutPath)
    $before = @(Get-FileHash -LiteralPath $paths | ForEach-Object Hash)
    # 执行入口脚本的真实调用，模拟首次安装及重复安装后的校验。
    1..2 | ForEach-Object { & ([scriptblock]::Create($call.Extent.Text)) | Out-Null }
    $after = @(Get-FileHash -LiteralPath $paths | ForEach-Object Hash)
    Assert-LauncherTest (($before -join ',') -ceq ($after -join ',')) "Installer overwrote package-aware launchers."

    $parameters = @{
        ExpectedExecutable = $launchExecutable
        LauncherPath = $launcherScriptPath
        CommandPath = $launcherCommandPath
        StartMenuShortcutPath = $startMenuShortcutPath
    }
    Assert-LauncherTest ((Get-CodexLauncherState @parameters).Status -eq "Current") "Valid launcher was rejected."
    foreach ($case in @("direct-exe", "wrong-target", "wrong-arguments", "missing-command", "missing-shortcut", "missing-script"))
    {
        switch ($case)
        {
            "direct-exe" { [IO.File]::WriteAllText($launcherCommandPath, "@echo off`r`nstart `"`" `"$launchExecutable`" %*`r`n") }
            "wrong-target" { $shortcut.TargetPath = $launchExecutable; $shortcut.Save() }
            "wrong-arguments" { $shortcut.Arguments = ""; $shortcut.Save() }
            "missing-command" { Remove-Item -LiteralPath $launcherCommandPath }
            "missing-shortcut" { Remove-Item -LiteralPath $startMenuShortcutPath }
            "missing-script" { Remove-Item -LiteralPath $launcherScriptPath }
        }
        $state = Get-CodexLauncherState @parameters
        Assert-LauncherTest ($state.Status -eq "Required") "Invalid launcher was accepted: $case"
        $existing = @($paths | Where-Object { Test-Path -LiteralPath $_ })
        $beforeFailure = @(Get-FileHash -LiteralPath $existing | ForEach-Object Hash)
        $failure = $null
        try { Set-CodexLauncherArtifacts @parameters | Out-Null }
        catch { $failure = $_.Exception.Message }
        Assert-LauncherTest ($failure -match 'codexplusplus repair') "Missing repair guidance: $case"
        $afterFailure = @(Get-FileHash -LiteralPath $existing | ForEach-Object Hash)
        Assert-LauncherTest (($beforeFailure -join ',') -ceq ($afterFailure -join ',')) "Failure rewrote launchers: $case"
        Assert-LauncherTest ((@($paths | Where-Object { Test-Path -LiteralPath $_ }).Count) -eq $existing.Count) `
            "Failure created a missing launcher: $case"
        [IO.File]::WriteAllText($launcherCommandPath, $command)
        $shortcut.TargetPath = $powerShellPath
        $shortcut.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $shortcut.Save()
    }
    $versionParameters = @{ InstalledVersion = [version] "1.0.3"; NodeMajor = 22; HasNpm = $true }
    if ((Get-Command Get-CodexPlusPlusInstallState).Parameters.ContainsKey("CommandPresent"))
    {
        $versionParameters.CommandPresent = $true
    }
    Assert-LauncherTest ((Get-CodexPlusPlusInstallState @versionParameters).Status -eq "InstallRequired") `
        "The old 1.0.3 installer must be upgraded."
    Write-Host "PASS Store/standalone selection, launcher preservation, repeat install, six failure cases and version floor"
}
finally
{
    $resolved = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe fixture cleanup path" }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
