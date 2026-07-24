[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$pwshPath = (Get-Process -Id $PID).Path
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.Tests.ps1" | Sort-Object Name)
if ($testFiles.Count -eq 0) { throw "No test files were found." }

$failed = 0
foreach ($testFile in $testFiles)
{
    & $pwshPath -NoProfile -File $testFile.FullName
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
if ($failed -gt 0) { exit 1 }
