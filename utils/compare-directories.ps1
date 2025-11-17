#!/usr/bin/env pwsh

<#
.SYNOPSIS
    Three-pass file verification between a source and destination directory.

.DESCRIPTION
    Pass 1: Verify that each file in the source exists in the destination
            (by relative path).

    Pass 2: For files that exist, compare file sizes.

    Pass 3: For files with matching sizes, compare checksums.

    No files are modified; this is a read-only verification tool.

.PARAMETER SourcePath
    Root path of the source directory.

.PARAMETER DestinationPath
    Root path of the destination directory.

.PARAMETER HashAlgorithm
    Hash algorithm for checksum comparison. Defaults to SHA256.
    Must be supported by Get-FileHash (e.g., SHA256, SHA1, MD5, etc.).

.EXAMPLE
    .\compare-directories.ps1 -SourcePath "D:\Backup\Source" -DestinationPath "X:\Backup\Destination"

.EXAMPLE
    .\compare-directories.ps1 -SourcePath "/mnt/src" -DestinationPath "/mnt/dst" -HashAlgorithm SHA256

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7+
    Exit Codes: 0 OK | 1 validation error
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$DestinationPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('SHA256', 'SHA1', 'MD5', 'SHA384', 'SHA512')]
    [string]$HashAlgorithm = 'SHA256'
)

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Script metadata
$Script:ScriptVersion = "1.0.0"

function Confirm-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('y', 'n')]
        [string]$Default = 'n'
    )

    $promptSuffix = if ($Default -eq 'y') { '(Y/n)' } else { '(y/N)' }
    $fullPrompt = "$Message $promptSuffix"

    $response = Read-Host -Prompt $fullPrompt

    if ([string]::IsNullOrWhiteSpace($response)) {
        return ($Default -eq 'y')
    }

    return $response -match '^[Yy]$'
}

# Normalize paths
$SourceRoot      = (Resolve-Path -Path $SourcePath).ProviderPath
$DestinationRoot = (Resolve-Path -Path $DestinationPath).ProviderPath

Write-Host "Source:      $SourceRoot"
Write-Host "Destination: $DestinationRoot"
Write-Host ""

# Gather all source files (recursively)
Write-Host "Enumerating source files..."
try {
    $sourceFiles = Get-ChildItem -Path $SourceRoot -File -Recurse -Force -ErrorAction Stop
}
catch {
    Write-Error "Failed to enumerate source files: $($_.Exception.Message)"
    exit 1
}

if (-not $sourceFiles) {
    Write-Warning "No files found under source path '$SourceRoot'. Nothing to verify."
    exit 0
}

Write-Host ("Found {0} files in source." -f $sourceFiles.Count)
Write-Host ""

# Build initial result objects
$results = foreach ($src in $sourceFiles) {
    # Compute relative path using .NET Core API
    $relativePath = [System.IO.Path]::GetRelativePath($SourceRoot, $src.FullName)

    # Compute expected destination path for this file
    $destFullPath = Join-Path -Path $DestinationRoot -ChildPath $relativePath

    [PSCustomObject]@{
        RelativePath  = $relativePath
        SourceFull    = $src.FullName
        DestFull      = $destFullPath

        Exists        = $false       # Will be set in Pass 1
        SizeMatch     = $null        # Will be set in Pass 2
        HashMatch     = $null        # Will be set in Pass 3

        SourceSize    = $src.Length
        DestSize      = $null

        SourceHash    = $null
        DestHash      = $null
    }
}

########################################
# PASS 1: EXISTENCE CHECK
########################################

Write-Host "========== PASS 1: Existence Check =========="

$index = 0
$total = $results.Count

foreach ($item in $results) {
    $index++

    Write-Progress -Activity "Pass 1: Checking existence" `
                   -Status ("{0}/{1}: {2}" -f $index, $total, $item.RelativePath) `
                   -PercentComplete ([int](($index / $total) * 100))

    $item.Exists = Test-Path -LiteralPath $item.DestFull -PathType Leaf
}

Write-Progress -Activity "Pass 1: Checking existence" -Completed

$missingFiles = $results | Where-Object { -not $_.Exists }
$existingFiles = $results | Where-Object { $_.Exists }

Write-Host ""
Write-Host "Pass 1 complete."
Write-Host ("  Total files:   {0}" -f $results.Count)
Write-Host ("  Existing:      {0}" -f $existingFiles.Count)
Write-Host ("  Missing:       {0}" -f $missingFiles.Count)
Write-Host ""

if ($missingFiles.Count -gt 0) {
    Write-Host "Missing files:"
    $missingFiles | Select-Object -ExpandProperty RelativePath | ForEach-Object {
        Write-Host "  $_"
    }
    Write-Host ""
}

if (-not (Confirm-Step -Message "Proceed to Pass 2 (file size comparison) for existing files?")) {
    Write-Host "User chose not to proceed to Pass 2. Exiting."
    return
}

########################################
# PASS 2: SIZE COMPARISON
########################################

Write-Host ""
Write-Host "========== PASS 2: Size Comparison =========="

$filesToCheckSize = $results | Where-Object { $_.Exists }

if (-not $filesToCheckSize) {
    Write-Warning "No existing destination files to compare sizes. Nothing to do in Pass 2."
} else {
    $index = 0
    $total = $filesToCheckSize.Count

    foreach ($item in $filesToCheckSize) {
        $index++

        Write-Progress -Activity "Pass 2: Comparing sizes" `
                       -Status ("{0}/{1}: {2}" -f $index, $total, $item.RelativePath) `
                       -PercentComplete ([int](($index / $total) * 100))

        try {
            $destInfo = Get-Item -LiteralPath $item.DestFull -ErrorAction Stop
            $item.DestSize = $destInfo.Length
            $item.SizeMatch = ($item.SourceSize -eq $item.DestSize)
        }
        catch {
            # In case the file disappeared between Pass 1 and now
            $item.DestSize  = $null
            $item.SizeMatch = $false
            $item.Exists    = $false
        }
    }

    Write-Progress -Activity "Pass 2: Comparing sizes" -Completed

    $sizeMismatch = $results | Where-Object { $_.Exists -and $_.SizeMatch -eq $false }
    $sizeMatch    = $results | Where-Object { $_.Exists -and $_.SizeMatch -eq $true }

    Write-Host ""
    Write-Host "Pass 2 complete."
    Write-Host ("  Files checked:    {0}" -f $filesToCheckSize.Count)
    Write-Host ("  Size matches:     {0}" -f $sizeMatch.Count)
    Write-Host ("  Size mismatches:  {0}" -f $sizeMismatch.Count)
    Write-Host ""

    if ($sizeMismatch.Count -gt 0) {
        Write-Host "Sample size mismatches (up to 10):"
        $sizeMismatch |
            Select-Object -First 10 RelativePath, SourceSize, DestSize |
            ForEach-Object {
                Write-Host ("  {0} (source: {1} bytes, dest: {2} bytes)" -f $_.RelativePath, $_.SourceSize, $_.DestSize)
            }
        Write-Host ""
    }
}

if (-not (Confirm-Step -Message "Proceed to Pass 3 (checksum comparison) for files with matching sizes?")) {
    Write-Host "User chose not to proceed to Pass 3. Exiting."
    return
}

########################################
# PASS 3: CHECKSUM COMPARISON
########################################

Write-Host ""
Write-Host "========== PASS 3: Checksum Comparison =========="
Write-Host ("Hash algorithm: {0}" -f $HashAlgorithm)

# For performance and sanity, limit hash comparison to:
#   - Files that exist in destination
#   - AND have matching sizes (there is no point hashing different sizes)
$filesToHash = $results | Where-Object { $_.Exists -and $_.SizeMatch -eq $true }

if (-not $filesToHash) {
    Write-Warning "No files with matching sizes to hash-compare. Nothing to do in Pass 3."
} else {
    $index = 0
    $total = $filesToHash.Count

    foreach ($item in $filesToHash) {
        $index++

        Write-Progress -Activity "Pass 3: Comparing checksums" `
                       -Status ("{0}/{1}: {2}" -f $index, $total, $item.RelativePath) `
                       -PercentComplete ([int](($index / $total) * 100))

        try {
            $srcHash  = Get-FileHash -LiteralPath $item.SourceFull -Algorithm $HashAlgorithm -ErrorAction Stop
            $destHash = Get-FileHash -LiteralPath $item.DestFull   -Algorithm $HashAlgorithm -ErrorAction Stop

            $item.SourceHash = $srcHash.Hash
            $item.DestHash   = $destHash.Hash
            $item.HashMatch  = ($item.SourceHash -eq $item.DestHash)
        }
        catch {
            # If hashing fails for some reason, mark as mismatch
            $item.SourceHash = $null
            $item.DestHash   = $null
            $item.HashMatch  = $false
        }
    }

    Write-Progress -Activity "Pass 3: Comparing checksums" -Completed

    $hashMismatch = $filesToHash | Where-Object { $_.HashMatch -eq $false }
    $hashMatch    = $filesToHash | Where-Object { $_.HashMatch -eq $true }

    Write-Host ""
    Write-Host "Pass 3 complete."
    Write-Host ("  Files hashed:          {0}" -f $filesToHash.Count)
    Write-Host ("  Checksum matches:      {0}" -f $hashMatch.Count)
    Write-Host ("  Checksum mismatches:   {0}" -f $hashMismatch.Count)
    Write-Host ""

    if ($hashMismatch.Count -gt 0) {
        Write-Host "Sample checksum mismatches (up to 10):"
        $hashMismatch |
            Select-Object -First 10 RelativePath, SourceHash, DestHash |
            ForEach-Object {
                Write-Host ("  {0}" -f $_.RelativePath)
                Write-Host ("    Source: {0}" -f $_.SourceHash)
                Write-Host ("    Dest:   {0}" -f $_.DestHash)
            }
        Write-Host ""
    }
}

########################################
# FINAL SUMMARY
########################################

Write-Host "========== SUMMARY =========="
Write-Host ("Total source files:                {0}" -f $results.Count)
Write-Host ("Destination exists:                {0}" -f ($results | Where-Object { $_.Exists }).Count)
Write-Host ("Destination missing:               {0}" -f ($results | Where-Object { -not $_.Exists }).Count)
Write-Host ("Size mismatches (existing files):  {0}" -f ($results | Where-Object { $_.Exists -and $_.SizeMatch -eq $false }).Count)
Write-Host ("Hash mismatches (size-matched):    {0}" -f ($results | Where-Object { $_.HashMatch -eq $false -and $_.HashMatch -ne $null }).Count)
Write-Host ""

# You can uncomment the line below to return the full result objects to the pipeline
# $results

exit 0
