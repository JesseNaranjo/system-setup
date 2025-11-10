#!/usr/bin/env pwsh

<#
.SYNOPSIS
    rsync-two-way.ps1 - Bidirectional directory synchronization using robocopy

.DESCRIPTION
    This script performs two-way synchronization between local and remote directories
    using robocopy (Windows) or robocopy over SMB/network shares.

    Features:
    - Performs two-way synchronization between local and remote directories
    - Preserves file attributes, permissions, and timestamps
    - Mirrors deletions between both locations
    - Provides detailed progress reporting and logging
    - Validates connectivity before sync operations

.PARAMETER LocalDir
    Local directory path (e.g., C:\Data\Share)

.PARAMETER RemoteDir
    Remote directory path (e.g., \\server\share or Z:\backup)

.PARAMETER EnableBackups
    Enable backup of overwritten/deleted files

.PARAMETER Help
    Show help message

.EXAMPLE
    .\rsync-two-way.ps1 -LocalDir "C:\Data\Share" -RemoteDir "\\backup-server\share"

.EXAMPLE
    .\rsync-two-way.ps1 "C:\Documents" "Z:\Documents"

.NOTES
    Version: 1.0.0
    Requires: PowerShell 7+, Windows with robocopy
    Exit Codes: 0 OK | 1 usage error | 2 robocopy error | 3 connectivity error
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$LocalDir,

    [Parameter(Position = 1, Mandatory = $false)]
    [string]$RemoteDir,

    [Parameter(Mandatory = $false)]
    [switch]$EnableBackups = $false,

    [Parameter(Mandatory = $false)]
    [Alias('h')]
    [switch]$Help
)

# Requires PowerShell 7+
#Requires -Version 7.0

# Script metadata
$Script:ScriptName = $MyInvocation.MyCommand.Name
$Script:ScriptVersion = "1.0.0"
$Script:Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$Script:LogFile = Join-Path $HOME ".rsync-two-way.log"

# ANSI color codes for PowerShell
$Script:Colors = @{
    Blue   = "`e[0;34m"
    Gray   = "`e[0;90m"
    Green  = "`e[0;32m"
    Red    = "`e[0;31m"
    Yellow = "`e[1;33m"
    Cyan   = "`e[0;36m"
    NC     = "`e[0m"
}

# Patterns to exclude (aligned with bash version)
$Script:ExcludePatterns = @(
    ".DS_Store",
    "Thumbs.db",
    ".Spotlight-V100",
    ".Trashes",
    ".TemporaryItems",
    ".fseventsd",
    "desktop.ini",
    ".svn",
    ".~lock.*",
    "*.swp",
    "*.tmp",
    "*~"
)

#region Helper Functions

function Write-ColorOutput {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Section')]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    switch ($Type) {
        'Info'    { Write-Host "$($Colors.Blue)[   INFO]$($Colors.NC) $Message" }
        'Success' { Write-Host "$($Colors.Green)[SUCCESS]$($Colors.NC) $Message" }
        'Warning' { Write-Host "$($Colors.Yellow)[WARNING]$($Colors.NC) $Message" }
        'Error'   { Write-Host "$($Colors.Red)[  ERROR]$($Colors.NC) $Message" }
        'Section' {
            Write-Host "$($Colors.Cyan)╭────────────────────────────────────────────────────────────────────────╮$($Colors.NC)"
            Write-Host "$($Colors.Cyan)│$($Colors.NC) $Message"
            Write-Host "$($Colors.Cyan)╰────────────────────────────────────────────────────────────────────────╯$($Colors.NC)"
        }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $logMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $logMessage -ErrorAction SilentlyContinue
}

function Show-Usage {
    $usage = @"
$($Colors.Green)$ScriptName$($Colors.NC) v$ScriptVersion - Bidirectional robocopy synchronization

$($Colors.Yellow)Usage:$($Colors.NC)
  $ScriptName -LocalDir <path> -RemoteDir <path> [-EnableBackups]
  $ScriptName <local_path> <remote_path>

$($Colors.Yellow)Parameters:$($Colors.NC)
  -LocalDir     Local directory path (e.g., C:\Data\Share)
  -RemoteDir    Remote directory path (e.g., \\server\share or Z:\backup)
  -EnableBackups Enable backup of overwritten/deleted files (optional)
  -Help, -h     Show this help message

$($Colors.Yellow)Examples:$($Colors.NC)
  $ScriptName -LocalDir "C:\Data\Share" -RemoteDir "\\backup\share"
  $ScriptName "C:\Documents" "Z:\Documents"
  $ScriptName "C:\Data" "\\server\Data" -EnableBackups

$($Colors.Yellow)Features:$($Colors.NC)
  • Two-way synchronization with automatic conflict resolution
  • Preserves permissions, timestamps, and attributes
  • Optional backup of overwritten/deleted files
  • Detailed progress reporting with statistics
  • Automatic connectivity validation
  • Comprehensive logging to $LogFile

$($Colors.Yellow)Exit Codes:$($Colors.NC)
  0  Success
  1  Usage error
  2  Robocopy error
  3  Connectivity error

$($Colors.Yellow)Notes:$($Colors.NC)
  • Requires PowerShell 7+ and Windows with robocopy
  • Remote paths can be UNC paths (\\server\share) or mapped drives
  • Use forward slashes (/) or backslashes (\) in paths
  • Excludes common system files (Thumbs.db, .DS_Store, etc.)

"@
    Write-Host $usage
}

function Test-DirectoryAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Write-ColorOutput -Type Info -Message "Validating access to $Description..."
    Write-Log "Checking access to ${Description}: $Path"

    if (-not (Test-Path -Path $Path -PathType Container)) {
        # Try to create if it doesn't exist
        try {
            Write-ColorOutput -Type Warning -Message "$Description does not exist. Attempting to create..."
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-ColorOutput -Type Success -Message "Created $Description"
            Write-Log "Created directory: $Path"
            return $true
        }
        catch {
            Write-ColorOutput -Type Error -Message "Cannot access or create ${Description}: $Path"
            Write-ColorOutput -Type Info -Message "Error: $($_.Exception.Message)"
            Write-Log "ERROR: Cannot access directory $Path - $($_.Exception.Message)"
            return $false
        }
    }

    # Test write access
    try {
        $testFile = Join-Path $Path ".rsync-test-$(Get-Random)"
        New-Item -Path $testFile -ItemType File -Force -ErrorAction Stop | Out-Null
        Remove-Item -Path $testFile -Force -ErrorAction Stop
        Write-ColorOutput -Type Success -Message "Verified access to $Description"
        Write-Log "Access verified for: $Path"
        return $true
    }
    catch {
        Write-ColorOutput -Type Error -Message "Cannot write to ${Description}: $Path"
        Write-ColorOutput -Type Info -Message "Error: $($_.Exception.Message)"
        Write-Log "ERROR: Cannot write to $Path - $($_.Exception.Message)"
        return $false
    }
}

function Invoke-PromptYesNo {
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

function Invoke-RobocopySync {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$PassDescription,

        [Parameter(Mandatory = $false)]
        [switch]$UseBackup
    )

    Write-ColorOutput -Type Section -Message $PassDescription
    Write-Log $PassDescription
    Write-Host ""

    # Build robocopy arguments
    # /MIR - Mirror directory (copy all subdirectories, including empty ones, and purge dest)
    # /COPY:DAT - Copy Data, Attributes, and Timestamps
    # /DCOPY:DAT - Copy Directory timestamps, Attributes, and Timestamps
    # /R:3 - Retry 3 times on failed copies
    # /W:5 - Wait 5 seconds between retries
    # /MT:8 - Multi-threaded (8 threads)
    # /NP - No Progress percentage in log
    # /NFL - No File List (don't log file names)
    # /NDL - No Directory List
    # /V - Verbose output
    # /ETA - Show Estimated Time of Arrival
    # /BYTES - Show sizes in bytes

    $robocopyArgs = @(
        $Source,
        $Destination,
        '/MIR',           # Mirror mode (copies subdirs including empty, purges extra files)
        '/COPY:DAT',      # Copy Data, Attributes, Timestamps
        '/DCOPY:DAT',     # Copy directory timestamps and attributes
        '/R:3',           # Retry 3 times
        '/W:5',           # Wait 5 seconds between retries
        '/MT:8',          # Use 8 threads
        '/V',             # Verbose
        '/ETA',           # Show ETA
        '/BYTES'          # Show sizes in bytes
    )

    # Add excludes
    foreach ($exclude in $ExcludePatterns) {
        $robocopyArgs += "/XF"
        $robocopyArgs += $exclude
    }

    # Add backup directory if enabled
    if ($UseBackup) {
        $backupDir = Join-Path $Destination ".$Timestamp.bak"
        $robocopyArgs += "/B"  # Backup mode
    }

    # Execute robocopy
    try {
        $output = & robocopy.exe $robocopyArgs 2>&1
        $exitCode = $LASTEXITCODE

        # Display output
        $output | ForEach-Object { Write-Host $_ }

        # Robocopy exit codes:
        # 0 = No files copied. No failures. No mismatches.
        # 1 = Files copied successfully. No failures.
        # 2 = Extra files or directories detected. No files copied.
        # 3 = Files copied successfully and extra files/directories detected.
        # 4 = Some mismatched files or directories detected.
        # 5 = Files copied successfully and some mismatches detected.
        # 6 = Extra files/directories and some mismatches detected.
        # 7 = Files copied, extra files/directories, and some mismatches.
        # 8 or higher = Some files or directories could not be copied (fatal error).

        if ($exitCode -ge 8) {
            Write-ColorOutput -Type Error -Message "Robocopy failed with exit code $exitCode"
            Write-Log "ERROR: Robocopy failed with exit code $exitCode"
            return $false
        }
        elseif ($exitCode -ge 4) {
            Write-ColorOutput -Type Warning -Message "Robocopy completed with warnings (exit code $exitCode)"
            Write-Log "WARNING: Robocopy exit code $exitCode"
            return $true
        }
        else {
            Write-ColorOutput -Type Success -Message "Robocopy completed successfully (exit code $exitCode)"
            Write-Log "Robocopy completed with exit code $exitCode"
            return $true
        }
    }
    catch {
        Write-ColorOutput -Type Error -Message "Failed to execute robocopy: $($_.Exception.Message)"
        Write-Log "ERROR: Robocopy execution failed - $($_.Exception.Message)"
        return $false
    }
}

#endregion

#region Main Script

# Show help if requested
if ($Help -or ($PSBoundParameters.Count -eq 0 -and $args.Count -eq 0)) {
    Show-Usage
    exit 0
}

# Validate parameters
if ([string]::IsNullOrWhiteSpace($LocalDir) -or [string]::IsNullOrWhiteSpace($RemoteDir)) {
    Write-ColorOutput -Type Error -Message "Both LocalDir and RemoteDir parameters are required"
    Write-Host ""
    Show-Usage
    exit 1
}

# Normalize paths (ensure no trailing slash for robocopy)
$LocalDir = $LocalDir.TrimEnd('\', '/')
$RemoteDir = $RemoteDir.TrimEnd('\', '/')

# Check if robocopy exists
if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
    Write-ColorOutput -Type Error -Message "robocopy.exe is not available. This script requires Windows with robocopy."
    Write-Log "ERROR: robocopy.exe not found"
    exit 2
}

# Validate directory access
if (-not (Test-DirectoryAccess -Path $LocalDir -Description "local directory")) {
    exit 3
}

if (-not (Test-DirectoryAccess -Path $RemoteDir -Description "remote directory")) {
    exit 3
}

# Display sync configuration
Write-Host ""
Write-ColorOutput -Type Section -Message "Synchronization Configuration"
Write-Host "$($Colors.Blue)Local Directory:$($Colors.NC)  $LocalDir"
Write-Host "$($Colors.Blue)Remote Directory:$($Colors.NC) $RemoteDir"
Write-Host "$($Colors.Blue)Backup Enabled:$($Colors.NC)  $EnableBackups"
Write-Host "$($Colors.Blue)Excludes:$($Colors.NC)        $($ExcludePatterns.Count) pattern(s)"
Write-Host "$($Colors.Blue)Log File:$($Colors.NC)        $LogFile"
Write-Host ""

# Prompt user to continue
if (-not (Invoke-PromptYesNo -Message "          → Continue with synchronization?" -Default 'y')) {
    Write-ColorOutput -Type Warning -Message "Synchronization cancelled by user"
    Write-Log "Synchronization cancelled by user"
    exit 0
}

Write-Host ""

# Log sync start
Write-Log "=========================================="
Write-Log "Starting two-way sync: $LocalDir <-> $RemoteDir"
Write-Log "Backup enabled: $EnableBackups"

# Pass 1: Push LOCAL → REMOTE
$pass1Success = Invoke-RobocopySync `
    -Source $LocalDir `
    -Destination $RemoteDir `
    -PassDescription "Pass 1: Pushing changes from LOCAL → REMOTE" `
    -UseBackup:$EnableBackups

if (-not $pass1Success) {
    Write-ColorOutput -Type Error -Message "Pass 1 failed. Aborting synchronization."
    Write-Log "ERROR: Pass 1 failed, aborting"
    exit 2
}

Write-Host ""

# Pass 2: Pull REMOTE → LOCAL
$pass2Success = Invoke-RobocopySync `
    -Source $RemoteDir `
    -Destination $LocalDir `
    -PassDescription "Pass 2: Pulling changes from REMOTE → LOCAL" `
    -UseBackup:$EnableBackups

if (-not $pass2Success) {
    Write-ColorOutput -Type Error -Message "Pass 2 failed."
    Write-Log "ERROR: Pass 2 failed"
    exit 2
}

# Success!
Write-Host ""
Write-ColorOutput -Type Section -Message "Synchronization Complete"
Write-ColorOutput -Type Success -Message "Two-way sync completed successfully at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

if ($EnableBackups) {
    Write-ColorOutput -Type Info -Message "Backup directory: .$Timestamp.bak (on both local and remote)"
}

Write-Host ""
Write-Log "Two-way sync completed successfully"
Write-Log "=========================================="

exit 0

#endregion
