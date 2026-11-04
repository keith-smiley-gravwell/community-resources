#Requires -Version 5

<#
.SYNOPSIS
    Silent helper script to install, upgrade, or modify the config for a Gravwell Ingester via GPO or automated software deployement framework
.PARAMETER Action
    Sets the action the script will take
    Possible values include: config_change, install, update
.PARAMETER Ingester
    Sets the ingester the script will perform the action on
    Possible values include: gravwell-win-events, gravwell-file-follow
.PARAMETER ConfigPath
    (Optional) Sets the path for the config when the action is "config_change"
    Value should be the absolute path to the new config
.INPUTS
    Required: Action, Ingester; Optional: ConfigPath
.OUTPUTS
    Downloaded .MSIs and log file stored in ${env:SYSTEMDRIVE}\Windows\Temp\
.NOTES
    Version:        1.0
    Author:         Keith Smiley(Gravwell Inc.)
    Creation Date:  3/19/2025
    Purpose/Change: Assist with Gravwell Ingesters on Windows
    Compatibility:  Windows PowerShell 5.1 and PowerShell 7+ on Windows
.EXAMPLE
    ./gravwell_ingester_helper.ps1 install gravwell-win-events
    To download and install the latest gravwell_win_events_X.msi
.EXAMPLE
    ./gravwell_ingester_helper.ps1 update gravwell-file-follow
    To download and update to the latest GravwellFileFollower Service
.EXAMPLE
    ./gravwell_ingester_helper.ps1 config_change gravwell-file-follow 
    To update the config for the existing GravwellFileFollower Service
#>

# Name parameters
param(
    [Parameter(
        Mandatory,
        Position = 0
    )]
    [ValidateSet('config_change', 'install', 'update')]
    [string]$Action,
    [Parameter(
        Mandatory,
        Position = 1
    )]
    [ValidateSet('gravwell-file-follow', 'gravwell-win-events')]
    [string]$Ingester,
    [Parameter(
        Position = 2
    )]
    [string]$ConfigPath,
    [Parameter(
        Position = 3
    )]
    [switch]$Quiet
)

# Static variables
$TempPath   = "${env:SYSTEMDRIVE}\Windows\Temp"
if ($Quiet) {
    $LogName = "gravwell_ingester_helper.log" 
    $LogFile = Join-Path -Path $TempPath -ChildPath $LogName
}

# Logging function
function logging($Message) {
    if ($Quiet) {
        Add-Content -Path $LogFile -Value $Message
    }
    else {
        Write-Host $Message
    }
}

# PowerShell 7 also runs on Linux/macOS; this script manages Windows services and MSIs only
if ($PSVersionTable.PSEdition -eq "Core" -and !$IsWindows) {
    logging("$(Get-Date) - ERROR - This script only supports Windows")
    exit 1
}

# The Windows PowerShell 5.1 progress bar slows Invoke-WebRequest downloads considerably
$ProgressPreference = "SilentlyContinue"

# Verify proper parameter values
if ($Action -eq "config_change" -and !$ConfigPath) {
    logging("$(Get-Date) - ERROR - Must set ConfigPath when Action = config_change")
    exit 1
}
elseif ($Action -eq "config_change" -and $ConfigPath -and ((Test-Path -Path $ConfigPath) -eq $false)) {
    logging("$(Get-Date) - ERROR - $ConfigPath test failed...cannot perform config_change")
    exit 1
}

# Windows PowerShell 5.1 may not offer TLS 1.2 by default (PowerShell 7 ignores this setting)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Pull Ingester Info
logging("$(Get-Date) - INFO - Pulling Ingester Info from https://update.gravwell.io")
Try {
    $IngesterInfo = (((Invoke-WebRequest -UseBasicParsing -Uri https://update.gravwell.io/versions/available).Content) | ConvertFrom-Json).LatestPackages | Where-Object {$_.Platform -eq "windows"}
}
Catch {
    logging("$(Get-Date) - ERROR - $_")
    exit 1
}

# Set dependent variables
switch ($Ingester) {
    'gravwell-file-follow' {
        $ServiceName   = "GravwellFileFollower Service"
        $ExeLocation   = "C:\Program Files\gravwell\filefollow\winfilefollow.exe"
        $ConfPath      = "C:\ProgramData\gravwell\filefollow\file_follow.cfg"
        $BackupPath    = "$ConfPath.BAK"
    }
    'gravwell-win-events' {
        $ServiceName   = "GravwellEvents Service"
        $ExeLocation   = "C:\Program Files\gravwell\eventlog\winevents.exe"
        $ConfPath      = "C:\ProgramData\gravwell\eventlog\config.cfg"
        $BackupPath    = "$ConfPath.BAK"
    }
}

$Package = $IngesterInfo | Where-Object {$_.Component -eq "$Ingester"} | Select-Object -First 1
if (!$Package -and $Action -ne "config_change") {
    logging("$(Get-Date) - ERROR - No windows package for $Ingester found at https://update.gravwell.io")
    exit 1
}
$URL           = $Package.Path
$LatestVersion = $Package.Version
if ($URL) {
    # Parse as a URI rather than a filesystem path so the result is the same on every PowerShell version
    $Filename     = [System.IO.Path]::GetFileName(([uri]$URL).AbsolutePath)
    $DownloadPath = Join-Path -Path $TempPath -ChildPath $Filename
}

# Super cool ASCII art banner
$ASCII = "
  ________                                  .__  .__   
 /  _____/___________ ___  ____  _  __ ____ |  | |  |  
/   \  __\_  __ \__  \\  \/ /\ \/ \/ // __ \|  | |  |  
\    \_\  \  | \// __ \\   /  \     /\  ___/|  |_|  |__
 \______  /__|  (____  /\_/    \/\_/  \___  /____/____/ $Action latest $Ingester
        \/           \/                   \/           
"

# Display super cool ASCII art banner
if (!($Quiet)) { 
    $ASCII
}

function download_latest {
    # Announce download
    logging("$(Get-Date) - INFO - Downloading latest $Ingester")

    # Run safety check
    if ((Test-Path -Path $DownloadPath) -eq $true) {
        logging("$(Get-Date) - WARN - File already exists at $DownloadPath...moving on")
        return
    }

    # Download latest ingester .msi to a temporary name so a failed download never leaves a partial .msi behind
    $PartialPath = "$DownloadPath.part"
    Try {
        Invoke-WebRequest -UseBasicParsing -Uri $URL -OutFile $PartialPath
        Move-Item -Force $PartialPath $DownloadPath
    }
    Catch {
        logging("$(Get-Date) - ERROR - $_")
        Remove-Item -Force -ErrorAction SilentlyContinue $PartialPath
        exit 1
    }

    if ((Test-Path -Path $DownloadPath) -eq $true) {
        logging("$(Get-Date) - INFO - Latest $Ingester.msi downloaded")
    }
    else {
        logging("$(Get-Date) - ERROR - Could not find $DownloadPath")
        exit 1
    }
}

function backup_config {
    # Announce config backup
    logging("$(Get-Date) - INFO - Backing up $ConfPath to $BackupPath")

    # Backup current config
    Try{
        Copy-Item -Force -ErrorAction Stop $ConfPath $BackupPath
    }
    Catch {
        logging("$(Get-Date) - ERROR - $_")
        exit 1
    }

    if ((Test-Path -Path $BackupPath) -eq $true) {
        logging("$(Get-Date) - INFO - Config successfully backed up")
    }
    else {
        logging("$(Get-Date) - ERROR - Config $BackupPath not found...Check user permissions for $ConfPath")
        exit 1
    }
}

function run_msi {
    # Run the .msi and wait for it to finish; 3010 means success with a reboot required
    Try {
        $Msi = Start-Process -FilePath "C:\Windows\system32\msiexec.exe" -ArgumentList "/i", "`"$DownloadPath`"", "/quiet" -Wait -PassThru
    }
    Catch {
        logging("$(Get-Date) - ERROR - $_")
        exit 1
    }

    if ($Msi.ExitCode -eq 3010) {
        logging("$(Get-Date) - WARN - $Ingester.msi requires a reboot to complete")
    }
    elseif ($Msi.ExitCode -ne 0) {
        logging("$(Get-Date) - ERROR - msiexec failed for $DownloadPath with exit code $($Msi.ExitCode)")
        exit 1
    }
}

function get_exe_version {
    # Read the capture group directly; MatchInfo string formatting differs between PowerShell versions
    $Match = & $ExeLocation -version | Select-String "Version:\t([0-9]+\.[0-9]+\.[0-9]+)" | Select-Object -First 1
    if ($Match) {
        $Match.Matches[0].Groups[1].Value
    }
}

function install_latest {
    # Run safety check
    if ((Test-Path -Path $ExeLocation) -eq $true) {
        logging("$(Get-Date) - ERROR - $Ingester exe already exists...you may want Action = update")
        exit 1
    }

    # Announce install
    logging("$(Get-Date) - INFO - Installing latest $Ingester")

    # Download latest
    download_latest

    # Install latest ingester .msi
    run_msi

    if ((Get-Service -ErrorAction SilentlyContinue $ServiceName) -and ((Test-Path -Path $ExeLocation) -eq $true)) {
        logging("$(Get-Date) - INFO - Latest $Ingester.msi successfully installed")
    }
    else {
        logging("$(Get-Date) - ERROR - $Ingester install may have not completed successfully - Check $ServiceName")
        exit 1
    }
}

function update_to_latest {
    # Run safety check
    if ((Test-Path -Path $ExeLocation) -eq $true) {
        $CurrentVersion = get_exe_version
    }
    else {
        logging("$(Get-Date) - ERROR - $Ingester exe not found...you may want Action = install")
        exit 1
    }

    if (!$CurrentVersion) {
        logging("$(Get-Date) - WARN - Could not determine current $Ingester version...updating anyway")
    }
    elseif ($CurrentVersion -eq $LatestVersion) {
        logging("$(Get-Date) - INFO - $Ingester exe is already on the latest version: $LatestVersion")
        exit 0
    }
    else {
        logging("$(Get-Date) - INFO - $Ingester update available: $CurrentVersion -> $LatestVersion")
    }

    # Download latest
    download_latest

    # Backup current config
    backup_config

    # Announce update to latest
    logging("$(Get-Date) - INFO - Updating $Ingester from $CurrentVersion to $LatestVersion")

    # Update to latest ingester .msi
    run_msi

    if ((Test-Path -Path $ExeLocation) -eq $false) {
        logging("$(Get-Date) - ERROR - $Ingester exe not found after update")
        exit 1
    }

    $CheckVersion = get_exe_version
    $Service = Get-Service -ErrorAction SilentlyContinue $ServiceName
    if (!$Service -or $Service.Status -ne "Running") {
        logging("$(Get-Date) - ERROR - $ServiceName is not running after update...last status was $($Service.Status)")
        exit 1
    }
    elseif ($CheckVersion -ne $LatestVersion) {
        logging("$(Get-Date) - ERROR - $Ingester exe is reporting as $CheckVersion")
        exit 1
    }
    else {
        logging("$(Get-Date) - INFO - Latest $Ingester.msi successfully installed")
    }
}

function config_change_func {
    # Run safety checks
    if ((Test-Path -Path $ExeLocation) -eq $false) {
        logging("$(Get-Date) - ERROR - $Ingester exe not found...cannot perform config_change")
        exit 1
    }

    if ((Get-FileHash $ConfigPath).Hash -eq (Get-FileHash $ConfPath).Hash) {
        logging("$(Get-Date) - WARN - $ConfigPath and $ConfPath are same file...exiting")
        exit 0
    }

    # Backup current config
    backup_config

    # Announce config_change
    logging("$(Get-Date) - INFO - Starting config change for $Ingester")

    # Perform config_change
    Try {
        Copy-Item -Force -ErrorAction Stop $ConfigPath $ConfPath
        logging("$(Get-Date) - INFO - Restarting $ServiceName")
        Restart-Service -ErrorAction Stop $ServiceName
        (Get-Service $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(20))
    }
    Catch {
        $Status1 = (Get-Service -ErrorAction SilentlyContinue $ServiceName).Status
        logging("$(Get-Date) - ERROR - $_...last status was $Status1...check $ServiceName")
        exit 1
    }

    logging("$(Get-Date) - INFO - $ServiceName back up")
}

#
## Main
#

switch ($Action) {
    config_change {
        config_change_func
    }
    install {
        install_latest
    }
    update {
        update_to_latest
    }
}