<# Monitor Application Changes v1.0 by Isaac Good
Including notification options for Syncro RMM

Created because other scripts have various deficiencies:
    - They compare raw text files (objects are easier to manipulate however you want)
    - They check installer event logs (not all installers create event log entries)
    - They check WMI/CIM/Get-Package (which doesn't return user profile context apps)
    - They can't excludes apps or types of changes (noise causes alert fatigue)
    - They don't store all apps for comparison so if exclusions change it could lead to undesired reporting
    - They don't detect in process installations and wait to avoid inaccurate alerts

Potential Flaws:
    - If an application is updated whose DisplayName contains a date or version number not
    the same as present in DisplayVersion/MajorVersion/MinorVersion, the script may not identify
    it as Updated, so both Uninstalled and Installed versions are listed. Please be sure to
    report any cases of this you come across so the logic can be improved.

Future development ideas:
    - Add support for Windows Store Apps
    - List updated apps also when installed/uninstalled are found and updated is off (piggyback apps)
    - User/AllUser exclude/filtering?
    - 32/64bit indicator?
    - Test behavior in Terminal Server environment
    - Improve error handling
    - Sort by secondary column?

Changelog:
  1.0 / 2024-02-12 - Initial release
#>

if ($null -ne $env:SyncroModule) { Import-Module $env:SyncroModule -DisableNameChecking }

<# Exclusion notes:
- Exclusion list items are NOT case sensitive and will be wildcard matched on both sides (*exclusion*). Example:
    'Edge' would match 'Microsoft Edge' and 'Wedge Pro' so be as specific as possible.
- For exclusion lists, use array formatting. Examples:
    No exclusions: @('')  One exclusion: @('Microsoft Edge')  Multiple: @('Microsoft Edge','Dropbox')
#>

# Exclude entire categories of app changes
$ExcludeAllInstalls = $false
$ExcludeAllUninstalls = $false
$ExcludeAllUpdates = $true
# Exclude specific app publishers
$ExcludePublisherList = @('')
# Exclude specific apps from all change types
$ExcludeAllChangesList = @('')
# Exclude specific app installs
$ExcludeInstallsList = @('')
# Exclude specific app uninstalls
$ExcludeUninstallsList = @('')
# Exclude specific app updates
$ExcludeUpdatesList = @('')

<# Output format notes:
- Table format takes fewer lines and looks nicer, using HTML or text as appropriate for notification type.
- Alerts in Syncro display properly in table format, but emailed alerts have plain text spacing stripped
  so list will be more readable for those.
- List format can be more readable for emails if rich text isn't enabled in Syncro as plain text gets spacing stripped.
- If you want skinnier table output you can add '-Wrap' to the Format-Table command.
#>

# Title for notifications
$NotifyTitle = 'Application Changes' # change the category in comment below to match so Syncro will show it in Automated Remediation triggers, but leave it commented out!
# Rmm-Alert -Category 'Application Changes' -Body "$Output"
# Sort output (supports multiple properties): 'Change', 'Application', 'Publisher', 'Old Version', 'Version', 'User', 'Installed'
$NotifySortBy = 'Change'
# Choose properties and order to output: 'Change', 'Application', 'Publisher', 'Old Version', 'Version', 'User', 'Installed'
# If a property is empty for all output items, it will automatically be removed to keep output compact.
$NotifyProperties = [System.Collections.ArrayList]('Change', 'Application', 'Publisher', 'Old Version', 'Version', 'User', 'Installed')
# Send email to address
$NotifyEmail = $false
$NotifyEmailAddress = '' # leave blank for no email notifications
$NotifyEmailFormat = 'table' # 'table' or 'list'
# Create RMM alert (tables look good in Syncro but columns in emailed alerts wil be messy due to non-monospace font)
$NotifyAlert = $false
$NotifyAlertFormat = 'table' # 'table' or 'list'
# Create activity log item (in CSV format, unfortunately there's no way to even do line breaks in a log item so we end lines with a pipe)
$NotifyLog = $false
# Create ticket
$NotifyTicket = $false
$NotifyTicketFormat = 'table' # 'table' or 'list'
$NotifyTicketHidden = 'false' # 'true' creates a Private Note, 'false' creates a Public Note
$NotifyTicketDoNotEmail = 'true' # 'true' will not email customer, 'false' sends email

# Storage location
$Directory = 'c:\ProgramData\Monitor Application Changes' # Do not use a trailing \
$Filename = 'Installed Apps.txt'

# How many minutes to wait for active installers to complete
$TimeToWait = '7'

# Test mode will not overwrite the old application list so you'll always have output for testing
$TestMode = $false

function Get-InstalledApps {
    # Modified from Test-InstalledSoftware function from https://github.com/darimm/RMMFunctions
    $32BitPath = "SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    $64BitPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    # Empty array to store applications
    $Apps = @()
    # Retrieve globally installed applications
    $Apps += Get-ItemProperty "HKLM:\$32BitPath" | Where-Object { $null -ne $_.DisplayName }
    $Apps += Get-ItemProperty "HKLM:\$64BitPath" | Where-Object { $null -ne $_.DisplayName }
    # Retrieve user profile applications
    $AllProfiles = Get-CimInstance Win32_UserProfile |
        Select-Object LocalPath, SID, Loaded, Special |
            Where-Object { $_.SID -like "S-1-5-21-*" -or $_.SID -like "S-1-12-1-*" } # 5-21 regular users, 12-1 is AzureAD users
    $MountedProfiles = $AllProfiles | Where-Object { $_.Loaded -eq $true }
    $UnmountedProfiles = $AllProfiles | Where-Object { $_.Loaded -eq $false }
    $MountedProfiles | ForEach-Object {
        $Apps += Get-ItemProperty -Path "Registry::\HKEY_USERS\$($_.SID)\$32BitPath" | Where-Object { $null -ne $_.DisplayName }
        $Apps += Get-ItemProperty -Path "Registry::\HKEY_USERS\$($_.SID)\$64BitPath" | Where-Object { $null -ne $_.DisplayName }
    }
    $UnmountedProfiles | ForEach-Object {
        $Hive = "$($_.LocalPath)\NTUSER.DAT"
        if (Test-Path $Hive) {
            REG LOAD HKU\temp $Hive >$null
            $Apps += Get-ItemProperty -Path "Registry::\HKEY_USERS\temp\$32BitPath" | Where-Object { $null -ne $_.DisplayName }
            $Apps += Get-ItemProperty -Path "Registry::\HKEY_USERS\temp\$64BitPath" | Where-Object { $null -ne $_.DisplayName }
            # Run manual GC to allow hive to be unmounted
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            REG UNLOAD HKU\temp >$null
        }
    }
    return $Apps
}

# Check for active installers and wait if needed to help prevent false alerts
Write-Output "Waiting up to $TimeToWait minutes for active installers to complete..."
while ($(Get-Process msiexec -ErrorAction SilentlyContinue).count -gt 1 -or $(Get-Process '*setup*','*install*','choco','winget' -ErrorAction SilentlyContinue).count -ge 1 -and $minutes -lt $TimeToWait) {
    Start-Sleep 60
    $minutes = $minutes+1
}

# Grab installed apps
$InstalledApps = Get-InstalledApps

# Load old app list from disk
if (Test-Path "$Directory\$Filename") {
    $installedAppsOld = Get-Content "$Directory\$filename" | ConvertFrom-Json
} else {
    Write-Host "No application list found, nothing to compare.`n Saving list for next run and exiting..."
    # Check/create directory
    if (-not (Test-Path "$Directory")) {
        New-Item -ItemType Directory -Path "$Directory" | Out-Null
    }
    # Save old app list for next run
    $InstalledApps | ConvertTo-Json -Compress | Out-File "$Directory\$Filename"
    exit 0
}

# Update old app list for next run
if (-not $TestMode) { $InstalledApps | ConvertTo-Json -Compress | Out-File "$Directory\$Filename" }

# Determine the differences, sort and deduplicate (this generates the SideIndicator property)
$Comparison = Compare-Object -Property DisplayName, Publisher, DisplayVersion, VersionMajor, VersionMinor, InstallDate, InstallLocation -ReferenceObject $InstalledAppsOld -DifferenceObject $InstalledApps | Sort-Object -Property DisplayName | Get-Unique -AsString

# Reformat the differences into a new object
$Differences = foreach ($Difference in $Comparison) {
    $Application = $Difference.DisplayName
    # Try to strip version number from name so Updated apps don't show as Uninstalled and Installed
    if ($Application -and $Difference.DisplayVersion) {
        # Some apps list a version number in DisplayName shorter than the full one in DisplayVersion so we create that string to strip also
        if ($Difference.VersionMajor -and $Difference.VersionMinor) {
            [string]$VersionMajorMinor = '{0}.{1}' -f $Difference.VersionMajor, $Difference.VersionMinor
        }
        # Remove DisplayVersion, DisplayVersion without trailing .0 (VC++) and our VersionMajorMinor
        $Application = $Application -replace $Difference.DisplayVersion -replace ($Difference.DisplayVersion.TrimEnd('.0')) -replace $VersionMajorMinor
        # Remove Java update numbers (Java 8 Update 381 to Java 8 Update)
        $Application = $Application -replace 'Update [0-9]{1,3}'
        # Remove Microsoft .NET minor version numbers ('Microsoft .NET Runtime - 6.0.23 (x86)' to 'Microsoft .NET Runtime - 6.0 (x86)')
        $Application = $Application -replace '(\.[0-9]{1,})(?=\s\(x\d\d\)$)'
        # Remove leftover trailing ' v', '()', 'version ', '- ', spaces and double spaces for cleaner output
        $Application = $Application -replace ' v$' -replace '\(\)$' -replace 'version $' -replace '- $' -replace '\s+$' -replace '\s+', ' '
    }
    # If Publisher is empty (MS Edge Update, etc), fill with Application name instead, so exclusions more likely to still work
    if ($null -eq $Difference.Publisher) {
        $Publisher = $Application
    } else { $Publisher = $Difference.Publisher }
    # Convert InstallDate to a consistent and more readable format
    if ($Difference.InstallDate -match '[0-1][0-9]/[0-9]{2}/[0-9]{4}') {
        $Installed = ([Datetime]::ParseExact($Difference.InstallDate, 'MM/dd/yyyy', $null)).ToString('yyyy-MM-dd')
    } elseif ($Difference.InstallDate -match '[0-9]{2}/[0-1][0-9]/[0-9]{4}') {
        $Installed = ([Datetime]::ParseExact($Difference.InstallDate, 'dd/MM/yyyy', $null)).ToString('yyyy-MM-dd')
    } elseif ($Difference.InstallDate -match '[0-9]{4}[0-1][0-9]{6}') {
        $Installed = ([Datetime]::ParseExact($Difference.InstallDate, 'yyyyMMddHHmmss', $null)).ToString('yyyy-MM-dd')
    } elseif ($Difference.InstallDate -match '[0-9]{4}[0-1][0-9]{3}') {
        $Installed = ([Datetime]::ParseExact($Difference.InstallDate, 'yyyyMMdd', $null)).ToString('yyyy-MM-dd')
    } elseif ($Difference.InstallLocation) {
        # If no InstallDate, use the InstallLocation's LastWriteTime instead
        if (Test-Path $Difference.InstallLocation) {
            $Installed = ((Get-ItemProperty -Path $Difference.InstallLocation).LastWriteTime).ToString('yyyy-MM-dd')
        }
    }
    # Determine user that installed the app
    if ($Difference.InstallLocation -like '*\Users\*') {
        $Username = $Difference.InstallLocation.split("\")[2]
    } else { $Username = '' }
    [PSCustomObject] @{
        'Change'      = $Difference.SideIndicator
        'Application' = $Application
        'Publisher'   = $Publisher
        'Old Version' = '' # This will be filled in later when we determine Updates
        'Version'     = $Difference.DisplayVersion
        'User'        = $Username
        'Installed'   = $Installed
    }
}

# Exclude apps from all change types
if (($ExcludeAllChangesList | Measure-Object -Character).Characters -gt 0) {
    $ExcludeAllChangesListPiped = ($ExcludeAllChangesList | ForEach-Object { '.*' + [regex]::Escape($_) + '.*' }) -join '|'
    $Differences = $Differences | Where-Object { $_.Application -notmatch $ExcludeAllChangesListPiped }
}

# Exclude publishers
if (($ExcludePublisherList | Measure-Object -Character).Characters -gt 0) {
    $ExcludePublisherListPiped = ($ExcludePublisherList | ForEach-Object { '.*' + [regex]::Escape($_) + '.*' }) -join '|'
    $Differences = $Differences | Where-Object { $_.Publisher -notmatch $ExcludePublisherListPiped }
}

# Group the applications so we can extract the Updated items
$Differences = $Differences | Group-Object -Property Application

# Build the output array
$Output = @()

# Extract the Installed apps and label them
if (-not $ExcludeAllInstalls) {
    $Installed = ($Differences | Where-Object { $_.Count -eq 1 }).Group | Where-Object { $_.Change -eq "=>" }
    $Installed | ForEach-Object { $_.Change = 'Installed' }
    # Exclude Installed apps
    if (($ExcludeInstallsList | Measure-Object -Character).Characters -gt 0) {
        $ExcludeInstallsListPiped = ($ExcludeInstallsList | ForEach-Object { '.*' + [regex]::Escape($_) + '.*' }) -join '|'
        $Installed = $Installed | Where-Object { $_.Application -notmatch $ExcludeInstallsListPiped }
    }
    $Output += $Installed
}

# Extract the Uninstalled apps and label them
if (-not $ExcludeAllUninstalls) {
    $Uninstalled = ($Differences | Where-Object { $_.Count -eq 1 }).Group | Where-Object { $_.Change -eq "<=" }
    $Uninstalled | ForEach-Object { $_.Change = 'Uninstalled' }
    # Exclude Uninstalled apps
    if (($ExcludeUninstallsList | Measure-Object -Character).Characters -gt 0) {
        $ExcludeUninstallsListPiped = ($ExcludeUninstallsList | ForEach-Object { '.*' + [regex]::Escape($_) + '.*' }) -join '|'
        $Uninstalled = $Uninstalled | Where-Object { $_.Application -notmatch $ExcludeUninstallsListPiped }
    }
    $Output += $Uninstalled
}

# Extract the Updated apps and label them
if (-not $ExcludeAllUpdates) {
    # If an application has a count greater than 1, we assume it's an update and sort to remove duplicates
    $OldVersions = ($Differences | Where-Object { $_.Count -gt 1 }).Group | Where-Object { $_.Change -eq "<=" } | Sort-Object -Property Application -Unique
    $Updated = ($Differences | Where-Object { $_.Count -gt 1 }).Group | Where-Object { $_.Change -eq "=>" } | Sort-Object -Property Application -Unique
    $Updated | ForEach-Object { $_.Change = 'Updated' }
    # Add Old Version property to Updated items
    $Updated | ForEach-Object { $_.'Old Version' = $OldVersions | Where-Object Application -EQ $_.Application | Select-Object -ExpandProperty Version }
    # Exclude Updated apps
    if (($ExcludeUpdatesList | Measure-Object -Character).Characters -gt 0) {
        $ExcludeUpdatesListPiped = ($ExcludeUpdatesList | ForEach-Object { '.*' + [regex]::Escape($_) + '.*' }) -join '|'
        $Updated = $Updated | Where-Object { $_.Application -notmatch $ExcludeUpdatesListPiped }
    }
    $Output += $Updated
}

# Output and notify (convert to string so Syncro cmdlets will accept it)
if ($Output) {
    # Remove properties that are empty for all output items
    ($Output | Get-Member -MemberType NoteProperty).Name | ForEach-Object {
        if (($Output.$_ | Measure-Object -Character).Characters -eq 0) { $NotifyProperties.Remove($_) }
    }
    # Select desired properties and sort
    $Output = $Output | Select-Object $NotifyProperties | Sort-Object -Property $NotifySortBy
    # Output for script log
    $Output | Format-Table | Out-String
    # List format
    $OutputList = $Output | Format-List | Out-String
    # CSV format is used for Log items since they don't support line breaks or HTML, we remove quotes and add pipes to separate lines
    $OutputCSV = $Output | ConvertTo-Csv -NoTypeInformation | ForEach-Object { $_ + "|" -replace '"', '' }
    # Table Text format is used for Alerts since they don't support HTML but look fine in Syncro, but emailed alerts get spacing stripped so we replace with ALT-255
    $OutputTableText = ($Output | Format-Table | Out-String).Replace(' ', ' ')
    # Table HTML format works well for email and tickets (assuming rich-text is enabled)
    $OutputTableHTML = $Output | ConvertTo-Html -Fragment
    if ($NotifyAlert) {
        if ($NotifyAlertFormat -eq 'table') { Rmm-Alert -Category $NotifyTitle -Body "$OutputTableText" }
        if ($NotifyAlertFormat -eq 'list') { Rmm-Alert -Category $NotifyTitle -Body "$OutputList" }
    }
    if ($NotifyLog) {
        Log-Activity -Message $NotifyTitle -EventName "$OutputCSV"
    }
    if ($NotifyEmail) {
        if ($NotifyEmailFormat -eq 'table') { Send-Email -To $NotifyEmailAddress -Subject $NotifyTitle -Body "$OutputTableHTML" }
        if ($NotifyEmailFormat -eq 'list') { Send-Email -To $NotifyEmailAddress -Subject $NotifyTitle -Body "$OutputList" }
    }
    if ($NotifyTicket) {
        $TicketID = (Create-Syncro-Ticket -Subject $NotifyTitle -IssueType "Other" -Status "New").Ticket.ID
        if ($NotifyTicketFormat -eq 'table') { Create-Syncro-Ticket-Comment -TicketIdOrNumber $TicketID -Subject $NotifyTitle -Body "$OutputTableHTML" -Hidden "$NotifyTicketHidden" -DoNotEmail "$NotifyTicketDoNotEmail" }
        if ($NotifyTicketFormat -eq 'list') { Create-Syncro-Ticket-Comment -TicketIdOrNumber $TicketID -Subject $NotifyTitle -Body "$OutputList" -Hidden "$NotifyTicketHidden" -DoNotEmail "$NotifyTicketDoNotEmail" }
    }
} else {
    Write-Host "No application changes found"
}
