Set-StrictMode -Version Latest

$script:TestCount = 0
$script:FailureCount = 0
$script:SkippedCount = 0

function Test-Case
{
    param([string] $Name, [scriptblock] $Body)

    $script:TestCount++
    try
    {
        & $Body
        Write-Host "PASS $Name"
    }
    catch
    {
        $script:FailureCount++
        Write-Host "FAIL $Name`n$($_.Exception.Message)" -ForegroundColor Red
    }
}

function Skip-TestCase
{
    param([string] $Name, [string] $Reason)

    $script:TestCount++
    $script:SkippedCount++
    Write-Host "SKIP $Name`n$Reason" -ForegroundColor Yellow
}

function Assert-True
{
    param([bool] $Condition, [string] $Message = "Expected condition to be true.")

    if (!$Condition) { throw $Message }
}

function Assert-Equal
{
    param($Expected, $Actual, [string] $Message = "")

    if ($Expected -ceq $Actual) { return }
    throw "Expected <$Expected>, actual <$Actual>. $Message"
}

function Assert-Throws
{
    param([scriptblock] $Body, [string] $Pattern)

    try
    {
        & $Body
    }
    catch
    {
        if ($_.Exception.Message -match $Pattern) { return }
        throw "Exception did not match <$Pattern>: $($_.Exception.Message)"
    }
    throw "Expected an exception matching <$Pattern>."
}

function Complete-Tests
{
    Write-Host "$script:TestCount tests, $script:FailureCount failures, $script:SkippedCount skipped"
    if ($script:FailureCount -gt 0) { exit 1 }
}
