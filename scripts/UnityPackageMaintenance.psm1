Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "UnityLinkCommon.psm1") -Scope Local

function Test-UnityProjectRoot
{
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $root = Resolve-NormalizedPath $Path
    return (Test-Path -LiteralPath (Join-Path $root "Assets") -PathType Container) -and
        (Test-Path -LiteralPath (Join-Path $root "Packages/manifest.json") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $root "ProjectSettings/ProjectVersion.txt") -PathType Leaf)
}

function Find-UnityProjectRoot
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StartPath,
        [scriptblock] $ProjectRootTest
    )

    if ($null -eq $ProjectRootTest)
    {
        $ProjectRootTest = { param($candidate) Test-UnityProjectRoot $candidate }
    }

    $current = Resolve-NormalizedPath $StartPath
    if (Test-Path -LiteralPath $current -PathType Leaf) { $current = Split-Path $current -Parent }

    while ($current)
    {
        if (& $ProjectRootTest $current) { return $current }

        $parent = Split-Path $current -Parent
        if (!$parent -or (Test-PathEqual $parent $current)) { break }
        $current = $parent
    }

    throw "No Unity project containing Assets, Packages/manifest.json, and " +
        "ProjectSettings/ProjectVersion.txt was found above '$StartPath'."
}

function Get-UnityPackageManifestValue
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UnityProjectRoot,
        [Parameter(Mandatory)] [string] $PackageRoot)

    $packagesRoot = Join-Path (Resolve-NormalizedPath $UnityProjectRoot) "Packages"
    $relative = [System.IO.Path]::GetRelativePath($packagesRoot, (Resolve-NormalizedPath $PackageRoot))
    return "file:$($relative.Replace('\', '/'))"
}

function Update-UnityManifestText
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Text,
        [Parameter(Mandatory)] [string] $DependencyValue)

    try
    {
        $document = $Text | ConvertFrom-Json -AsHashtable
    }
    catch
    {
        throw "Packages/manifest.json is not valid JSON: $($_.Exception.Message)"
    }

    if (!$document.ContainsKey("dependencies") -or
        $document.dependencies -isnot [System.Collections.IDictionary])
    {
        throw "Packages/manifest.json does not contain a dependencies object."
    }

    $key = "com.kpk.codex-unity-link"
    if ($document.dependencies.Contains($key) -and
        $document.dependencies[$key] -ceq $DependencyValue)
    {
        return [pscustomobject] @{
            Changed = $false
            Text = $Text
        }
    }

    $crlf = [string] ([char] 13) + [char] 10
    $lf = [string] [char] 10
    $newline = if ($Text.Contains($crlf)) {
        $crlf
    } elseif ($Text.Contains($lf)) {
        $lf
    } else {
        [Environment]::NewLine
    }

    $dependenciesPattern =
        '(?s)(?<open>"dependencies"\s*:\s*\{)(?<body>(?:[^{}"]|"(?:\\.|[^"\\])*")*)(?<close>\})'
    $dependenciesMatch = [regex]::Match($Text, $dependenciesPattern)
    if (!$dependenciesMatch.Success)
    {
        throw "Could not safely locate the dependencies object."
    }

    $body = $dependenciesMatch.Groups["body"].Value
    $propertyPattern =
        '(?m)(?<prefix>^[ \t]*"com\.kpk\.codex-unity-link"[ \t]*:[ \t]*)(?<value>"(?:\\.|[^"\\])*")(?<suffix>[ \t]*,?)'
    $jsonValue = ConvertTo-Json -InputObject $DependencyValue -Compress
    $propertyMatch = [regex]::Match($body, $propertyPattern)

    if ($propertyMatch.Success)
    {
        $updatedBody = $body.Substring(0, $propertyMatch.Index) +
            $propertyMatch.Groups["prefix"].Value +
            $jsonValue +
            $propertyMatch.Groups["suffix"].Value +
            $body.Substring($propertyMatch.Index + $propertyMatch.Length)
    }
    else
    {
        $existingIndent = [regex]::Match($body, '(?m)^(?<indent>[ \t]+)"')
        $objectPrefix = $Text.Substring(0, $dependenciesMatch.Groups["open"].Index)
        $objectIndentMatch = [regex]::Match($objectPrefix, '(?m)(?<indent>^[ \t]*)[^\r\n]*$')
        $objectIndent = $objectIndentMatch.Groups["indent"].Value
        $propertyIndent = if ($existingIndent.Success) {
            $existingIndent.Groups["indent"].Value
        } else {
            "$objectIndent  "
        }
        $jsonKey = ConvertTo-Json -InputObject $key -Compress
        $property = $propertyIndent + $jsonKey + ": " + $jsonValue
        $trimCharacters = [char[]] @([char] 13, [char] 10, [char] 32, [char] 9)
        $core = $body.TrimEnd($trimCharacters)
        $trailing = $body.Substring($core.Length)

        if ($core.Length -eq 0)
        {
            $updatedBody = $newline + $property + $newline + $objectIndent
        }
        else
        {
            $updatedBody = $core + "," + $newline + $property + $trailing
        }
    }

    $updatedText = $Text.Substring(0, $dependenciesMatch.Groups["body"].Index) +
        $updatedBody +
        $Text.Substring($dependenciesMatch.Groups["body"].Index + $body.Length)

    try
    {
        $updatedDocument = $updatedText | ConvertFrom-Json -AsHashtable
    }
    catch
    {
        throw "The proposed manifest edit was not valid JSON: $($_.Exception.Message)"
    }

    if ($updatedDocument.dependencies[$key] -cne $DependencyValue)
    {
        throw "The proposed manifest edit did not produce the expected dependency value."
    }

    return [pscustomobject] @{
        Changed = $true
        Text = $updatedText
    }
}

function Test-UnauthorizedAccessFailure
{
    param([Parameter(Mandatory)] [System.Exception] $Exception)

    $current = $Exception
    while ($null -ne $current)
    {
        if ($current -is [System.UnauthorizedAccessException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Set-UnityManifestTextSafely
{
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $Text,
        [scriptblock] $WriteAction,
        [scriptblock] $PostWriteTest)

    $path = Resolve-NormalizedPath $ManifestPath
    $attributes = [System.IO.File]::GetAttributes($path)
    if (($attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0)
    {
        throw "Packages/manifest.json is read-only. Make it writable through your version-control checkout " +
            "workflow, or clear the ReadOnly attribute if the file is unmanaged. Path: $path"
    }

    $originalBytes = [System.IO.File]::ReadAllBytes($path)
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    try
    {
        if ($null -eq $WriteAction)
        {
            [System.IO.File]::WriteAllText($path, $Text, $encoding)
        }
        else
        {
            & $WriteAction $path $Text $encoding
        }

        if ($null -ne $PostWriteTest -and !(& $PostWriteTest $path))
        {
            throw "Post-write dependency verification failed."
        }
    }
    catch
    {
        $writeException = $_.Exception
        try
        {
            $currentBytes = [System.IO.File]::ReadAllBytes($path)
            if ([Convert]::ToBase64String($currentBytes) -cne [Convert]::ToBase64String($originalBytes))
            {
                [System.IO.File]::WriteAllBytes($path, $originalBytes)
            }
        }
        catch
        {
            throw "Failed to update Packages/manifest.json and could not restore its original bytes. " +
                "Path: $path. Restore error: $($_.Exception.Message)"
        }

        if (Test-UnauthorizedAccessFailure -Exception $writeException)
        {
            throw "Access to Packages/manifest.json was denied by Windows permissions (ACL). " +
                "Grant the current user write access and try again. Path: $path"
        }
        throw "Failed to update Packages/manifest.json; its original bytes were restored. " +
            "Path: $path. Error: $($writeException.Message)"
    }
}

Export-ModuleMember -Function @(
    "Test-UnityProjectRoot",
    "Find-UnityProjectRoot",
    "Get-UnityPackageManifestValue",
    "Update-UnityManifestText",
    "Set-UnityManifestTextSafely")
