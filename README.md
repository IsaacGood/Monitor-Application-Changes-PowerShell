# Monitor Application Changes by Isaac Good
Includes notification options for Syncro RMM and easily adaptable to others.

### Created because other scripts have various deficiencies:
- They compare raw text files (objects are easier to manipulate however you want)
- They check installer event logs (not all installers create event log entries)
- They check WMI/CIM/Get-Package (which doesn't return user profile context apps)
- They can't excludes apps or types of changes (noise causes alert fatigue)
- They don't store all apps for comparison so if exclusions change it could lead to undesired reporting
- They don't detect in process installations and wait to avoid inaccurate alerts

### Flaws:
- If an application is updated whose DisplayName contains a date or version number not
    the same as present in DisplayVersion/MajorVersion/MinorVersion, the script may not identify
    it as Updated, so both Uninstalled and Installed versions are listed. Please be sure to
    report any cases of this you come across so the logic can be improved.

### Future development ideas:
- Add support for Windows Store Apps
- List updated apps also when installed/uninstalled are found and updated is off (piggyback apps)
- User/AllUser exclude/filtering?
- 32/64bit indicator?
- Test behavior in Terminal Server environment
- Improve error handling
- Improve table output? (border/text alignment)

# Changelog
    1.1 / 2024-02-13
        Added - Computer name in email notification subject & body
        Added - $OutputListHTML for better looking list emails
        Changed - $OutputList to $OutputListText for naming consistency and cleaned up formatting section and documentation
        Fixed - Preserve $OutputListText spaces by replacing with ALT-255
        Fixed - $OutputTableHTML looks bad in tickets (I'm sure it used to work?), switched to use $OutputTableText instead
        Fixed - Ticket created but fails adding comment
    1.0 / 2024-02-12 - Initial release
