# Laedt alle Quelldateien von NetSetup (Reihenfolge aus build.psd1) und legt Stub-Funktionen
# fuer alle Server-Cmdlets an. Die Stubs werfen einen Fehler, wenn ein Test vergisst, sie zu mocken.
# Verwendung in Tests:  BeforeAll { . (Join-Path $PSScriptRoot 'TestHelper.ps1') }

$testRoot = Split-Path -Path $PSScriptRoot -Parent

# Stub-Definitionen: Name = Parameterliste. [switch] fuer Schalter.
$stubDefinitionen = [ordered]@{
    # CIM / System
    'Get-CimInstance'                      = 'ClassName', 'Namespace', 'Filter', 'ComputerName'
    'Get-Service'                          = 'Name', 'ComputerName'
    'Start-Service'                        = 'Name', '[switch]PassThru'
    'Stop-Service'                         = 'Name', '[switch]Force'
    'Restart-Service'                      = 'Name', '[switch]Force'
    'Set-Service'                          = 'Name', 'StartupType'
    'Get-SmbShare'                         = 'Name'
    'Restart-Computer'                     = '[switch]Force'
    'Rename-Computer'                      = 'NewName', '[switch]Force', '[switch]Restart'
    'Add-Computer'                         = 'DomainName', 'Credential', '[switch]Force', '[switch]Restart', 'NewName'
    'Get-Credential'                       = 'Message', 'UserName'
    # ServerManager
    'Get-WindowsFeature'                   = 'Name'
    'Install-WindowsFeature'               = 'Name', '[switch]IncludeManagementTools', '[switch]Restart'
    'Uninstall-WindowsFeature'             = 'Name', '[switch]IncludeManagementTools', '[switch]Restart', '[switch]Remove'
    # Netzwerk
    'Get-NetAdapter'                       = 'Name', 'InterfaceIndex', '[switch]Physical'
    'Get-NetIPAddress'                     = 'AddressFamily', 'InterfaceIndex', 'IPAddress', 'PrefixOrigin'
    'Get-NetIPInterface'                   = 'AddressFamily', 'InterfaceIndex'
    'Get-NetIPConfiguration'               = 'InterfaceIndex', '[switch]Detailed'
    'Get-NetRoute'                         = 'DestinationPrefix', 'InterfaceIndex', 'AddressFamily'
    'New-NetIPAddress'                     = 'InterfaceIndex', 'IPAddress', 'PrefixLength', 'DefaultGateway', 'AddressFamily'
    'Remove-NetIPAddress'                  = 'InterfaceIndex', 'IPAddress', 'AddressFamily', '[switch]Confirm'
    'Remove-NetRoute'                      = 'InterfaceIndex', 'DestinationPrefix', '[switch]Confirm'
    'Set-NetIPInterface'                   = 'InterfaceIndex', 'Dhcp', 'AddressFamily'
    'Get-DnsClientServerAddress'           = 'InterfaceIndex', 'AddressFamily'
    'Set-DnsClientServerAddress'           = 'InterfaceIndex', 'ServerAddresses', '[switch]ResetServerAddresses'
    'Resolve-DnsName'                      = 'Name', 'Type', 'Server', '[switch]DnsOnly', '[switch]QuickTimeout', '[switch]NoHostsFile'
    'Get-NetFirewallProfile'               = 'Name'
    'Get-NetFirewallRule'                  = 'Enabled', 'Direction', 'Action', 'AssociatedNetFirewallPortFilter', 'Group'
    'Get-NetFirewallPortFilter'            = 'Protocol', 'AssociatedNetFirewallRule'
    'New-NetFirewallRule'                  = 'DisplayName', 'Name', 'Direction', 'Protocol', 'LocalPort', 'Action', 'Group', 'Profile', 'Description'
    'Remove-NetFirewallRule'               = 'Name'
    # DNS-Server
    'Get-DnsServer'                        = 'ComputerName'
    'Get-DnsServerSetting'                 = '[switch]All'
    'Set-DnsServerSetting'                 = 'InputObject'
    'Get-DnsServerZone'                    = 'Name'
    'Add-DnsServerPrimaryZone'             = 'Name', 'NetworkId', 'ReplicationScope', 'ZoneFile', 'DynamicUpdate'
    'Set-DnsServerPrimaryZone'             = 'Name', 'DynamicUpdate', 'ReplicationScope'
    'Remove-DnsServerZone'                 = 'Name', '[switch]Force'
    'Add-DnsServerConditionalForwarderZone' = 'Name', 'MasterServers', 'ReplicationScope'
    'Get-DnsServerForwarder'               = 'ComputerName'
    'Set-DnsServerForwarder'               = 'IPAddress', '[switch]PassThru', 'UseRootHint'
    'Add-DnsServerForwarder'               = 'IPAddress'
    'Remove-DnsServerForwarder'            = 'IPAddress', '[switch]Force'
    'Get-DnsServerRootHint'                = 'ComputerName'
    'Get-DnsServerScavenging'              = 'ComputerName'
    'Set-DnsServerScavenging'              = 'ScavengingState', 'ScavengingInterval', 'NoRefreshInterval', 'RefreshInterval', '[switch]ApplyOnAllZones'
    'Start-DnsServerScavenging'            = '[switch]Force'
    'Get-DnsServerZoneAging'               = 'Name'
    'Set-DnsServerZoneAging'               = 'Name', 'Aging', 'NoRefreshInterval', 'RefreshInterval'
    'Get-DnsServerResourceRecord'          = 'ZoneName', 'Name', 'RRType', 'ZoneScope'
    'Add-DnsServerResourceRecordA'         = 'ZoneName', 'Name', 'IPv4Address', '[switch]CreatePtr', '[switch]AllowUpdateAny', 'TimeToLive', 'ZoneScope'
    'Add-DnsServerResourceRecordAAAA'      = 'ZoneName', 'Name', 'IPv6Address', '[switch]CreatePtr', 'TimeToLive'
    'Add-DnsServerResourceRecordCName'     = 'ZoneName', 'Name', 'HostNameAlias', 'TimeToLive'
    'Add-DnsServerResourceRecordMX'        = 'ZoneName', 'Name', 'MailExchange', 'Preference', 'TimeToLive'
    'Add-DnsServerResourceRecordPtr'       = 'ZoneName', 'Name', 'PtrDomainName', 'TimeToLive'
    'Add-DnsServerResourceRecord'          = 'ZoneName', 'Name', '[switch]Srv', '[switch]Txt', 'DomainName', 'Priority', 'Weight', 'Port', 'DescriptiveText', 'TimeToLive'
    'Remove-DnsServerResourceRecord'       = 'ZoneName', 'Name', 'RRType', 'RecordData', '[switch]Force', 'ZoneScope'
    'Set-DnsServerResourceRecord'          = 'ZoneName', 'OldInputObject', 'NewInputObject'
    'Export-DnsServerZone'                 = 'Name', 'FileName'
    'Invoke-DnsServerZoneSign'             = 'ZoneName', '[switch]SignWithDefault', '[switch]Force'
    'Invoke-DnsServerZoneUnsign'           = 'ZoneName', '[switch]Force'
    'Get-DnsServerZoneScope'               = 'ZoneName'
    'Add-DnsServerZoneScope'               = 'ZoneName', 'Name'
    'Remove-DnsServerZoneScope'            = 'ZoneName', 'Name', '[switch]Force'
    'Get-DnsServerClientSubnet'            = 'Name'
    'Add-DnsServerClientSubnet'            = 'Name', 'IPv4Subnet'
    'Remove-DnsServerClientSubnet'         = 'Name', '[switch]Force'
    'Get-DnsServerQueryResolutionPolicy'   = 'Name', 'ZoneName'
    'Add-DnsServerQueryResolutionPolicy'   = 'Name', 'Action', 'ClientSubnet', 'ZoneScope', 'ZoneName', 'Fqdn', 'ProcessingOrder', '[switch]Disable'
    'Remove-DnsServerQueryResolutionPolicy' = 'Name', 'ZoneName', '[switch]Force'
    'Set-DnsServerQueryResolutionPolicy'   = 'Name', 'ZoneName', 'State'
    'Get-DnsServerGlobalQueryBlockList'    = 'ComputerName'
    'Set-DnsServerGlobalQueryBlockList'    = 'List', 'Enable'
    # DHCP-Server
    'Get-DhcpServerSetting'                = 'ComputerName'
    'Set-DhcpServerSetting'                = 'ConflictDetectionAttempts'
    'Add-DhcpServerSecurityGroup'          = 'ComputerName'
    'Get-DhcpServerInDC'                   = 'ComputerName'
    'Add-DhcpServerInDC'                   = 'DnsName', 'IPAddress'
    'Remove-DhcpServerInDC'                = 'DnsName', 'IPAddress'
    'Get-DhcpServerv4Binding'              = 'ComputerName'
    'Set-DhcpServerv4Binding'              = 'InterfaceAlias', 'BindingState'
    'Get-DhcpServerv4Scope'                = 'ScopeId'
    'Add-DhcpServerv4Scope'                = 'Name', 'StartRange', 'EndRange', 'SubnetMask', 'LeaseDuration', 'State', 'Description'
    'Set-DhcpServerv4Scope'                = 'ScopeId', 'State', 'LeaseDuration', 'Name'
    'Remove-DhcpServerv4Scope'             = 'ScopeId', '[switch]Force'
    'Get-DhcpServerv4ScopeStatistics'      = 'ScopeId'
    'Get-DhcpServerv4ExclusionRange'       = 'ScopeId'
    'Add-DhcpServerv4ExclusionRange'       = 'ScopeId', 'StartRange', 'EndRange'
    'Remove-DhcpServerv4ExclusionRange'    = 'ScopeId', 'StartRange', 'EndRange'
    'Get-DhcpServerv4OptionValue'          = 'ScopeId', 'OptionId', '[switch]All', 'PolicyName'
    'Set-DhcpServerv4OptionValue'          = 'ScopeId', 'OptionId', 'Value', 'Router', 'DnsServer', 'DnsDomain', '[switch]Force', 'PolicyName'
    'Remove-DhcpServerv4OptionValue'       = 'ScopeId', 'OptionId', 'PolicyName'
    'Get-DhcpServerv4OptionDefinition'     = 'OptionId'
    'Add-DhcpServerv4OptionDefinition'     = 'OptionId', 'Name', 'Type', '[switch]MultiValued', 'Description'
    'Get-DhcpServerv4Reservation'          = 'ScopeId', 'IPAddress'
    'Add-DhcpServerv4Reservation'          = 'ScopeId', 'IPAddress', 'ClientId', 'Name', 'Description', 'Type'
    'Remove-DhcpServerv4Reservation'       = 'ScopeId', 'IPAddress', 'ClientId'
    'Get-DhcpServerv4Lease'                = 'ScopeId', 'IPAddress', '[switch]AllLeases'
    'Remove-DhcpServerv4Lease'             = 'ScopeId', 'IPAddress'
    'Get-DhcpServerv4Superscope'           = 'SuperscopeName'
    'Add-DhcpServerv4Superscope'           = 'SuperscopeName', 'ScopeId'
    'Remove-DhcpServerv4Superscope'        = 'SuperscopeName', '[switch]Force'
    'Get-DhcpServerv4Failover'             = 'Name', 'ScopeId'
    'Add-DhcpServerv4Failover'             = 'Name', 'PartnerServer', 'ScopeId', 'LoadBalancePercent', 'ServerRole', 'ReservePercent', 'SharedSecret', 'MaxClientLeadTime', 'AutoStateTransition', 'StateSwitchInterval', '[switch]Force'
    'Remove-DhcpServerv4Failover'          = 'Name', '[switch]Force'
    'Invoke-DhcpServerv4FailoverReplication' = 'Name', 'ScopeId', '[switch]Force'
    'Get-DhcpServerv4DnsSetting'           = 'ScopeId'
    'Set-DhcpServerv4DnsSetting'           = 'ScopeId', 'DynamicUpdates', 'DeleteDnsRROnLeaseExpiry', 'UpdateDnsRRForOlderClients', 'NameProtection', 'DisableDnsPtrRRUpdate'
    'Get-DhcpServerDnsCredential'          = 'ComputerName'
    'Set-DhcpServerDnsCredential'          = 'Credential'
    'Remove-DhcpServerDnsCredential'       = '[switch]Force'
    'Get-DhcpServerv4Policy'               = 'Name', 'ScopeId'
    'Get-DhcpServerv4Class'                = 'Name', 'Type'
    'Add-DhcpServerv4Policy'               = 'Name', 'ScopeId', 'Condition', 'VendorClass', 'UserClass', 'MacAddress', 'Enabled', 'Description', 'ProcessingOrder'
    'Set-DhcpServerv4Policy'               = 'Name', 'ScopeId', 'Enabled'
    'Remove-DhcpServerv4Policy'            = 'Name', 'ScopeId'
    'Get-DhcpServerv6Scope'                = 'Prefix'
    'Add-DhcpServerv6Scope'                = 'Prefix', 'Name', 'State', 'PreferredLifeTime', 'ValidLifeTime', 'Description'
    'Set-DhcpServerv6Scope'                = 'Prefix', 'State'
    'Remove-DhcpServerv6Scope'             = 'Prefix', '[switch]Force'
    'Get-DhcpServerv6ScopeStatistics'      = 'Prefix'
    'Backup-DhcpServer'                    = 'Path'
    'Restore-DhcpServer'                   = 'Path', '[switch]Force'
    'Export-DhcpServer'                    = 'File', '[switch]Leases', '[switch]Force', 'ScopeId'
    'Import-DhcpServer'                    = 'File', 'BackupPath', '[switch]Leases', '[switch]Force', '[switch]ScopeOverwrite', 'ScopeId', '[switch]ServerConfigOnly'
    # Active Directory
    'Get-ADDomain'                         = 'Identity', 'Server'
    'Get-ADForest'                         = 'Identity', 'Server'
    'Get-ADDomainController'               = 'Identity', 'Filter', '[switch]Discover', 'Service', 'DomainName'
    'Get-ADUser'                           = 'Identity', 'Filter', 'Properties'
    'New-ADUser'                           = 'Name', 'SamAccountName', 'AccountPassword', 'Enabled', 'PasswordNeverExpires', 'Description', 'Path', 'UserPrincipalName', 'CannotChangePassword'
    'Set-ADAccountPassword'                = 'Identity', 'NewPassword', '[switch]Reset'
    'Remove-ADUser'                        = 'Identity', '[switch]Confirm'
    'Get-ADGroupMember'                    = 'Identity'
    'Test-ADDSForestInstallation'          = 'DomainName', 'DomainNetbiosName', 'ForestMode', 'DomainMode', '[switch]InstallDns', 'SafeModeAdministratorPassword', '[switch]Force', '[switch]NoRebootOnCompletion'
    'Install-ADDSForest'                   = 'DomainName', 'DomainNetbiosName', 'ForestMode', 'DomainMode', '[switch]InstallDns', 'SafeModeAdministratorPassword', '[switch]Force', '[switch]NoRebootOnCompletion'
    'Test-ADDSDomainControllerInstallation' = 'DomainName', 'Credential', '[switch]InstallDns', 'SafeModeAdministratorPassword', '[switch]Force', '[switch]NoRebootOnCompletion', 'SiteName'
    'Install-ADDSDomainController'         = 'DomainName', 'Credential', '[switch]InstallDns', 'SafeModeAdministratorPassword', '[switch]Force', '[switch]NoRebootOnCompletion', 'SiteName'
    # Geplante Aufgaben
    'Get-ScheduledTask'                    = 'TaskName', 'TaskPath'
    'Register-ScheduledTask'               = 'TaskName', 'Action', 'Trigger', 'Principal', 'Settings', 'Description', '[switch]Force', 'TaskPath'
    'Unregister-ScheduledTask'             = 'TaskName', '[switch]Confirm', 'TaskPath'
    'New-ScheduledTaskAction'              = 'Execute', 'Argument', 'WorkingDirectory'
    'New-ScheduledTaskTrigger'             = '[switch]Daily', 'At'
    'New-ScheduledTaskPrincipal'           = 'UserId', 'RunLevel', 'LogonType'
    'New-ScheduledTaskSettingsSet'         = '[switch]StartWhenAvailable', 'ExecutionTimeLimit'
}

$stubText = New-Object System.Text.StringBuilder
foreach ($name in $stubDefinitionen.Keys) {
    $params = @($stubDefinitionen[$name] | Where-Object { $_ -ne 'InputObject' } | ForEach-Object {
            if ($_ -like '`[switch`]*') { '[switch]$' + $_.Substring(8) } else { '$' + $_ }
        })
    $params += '[Parameter(ValueFromPipeline = $true)][object]$InputObject'
    [void]$stubText.AppendLine(("function {0} {{ [CmdletBinding()] param({1}) throw 'Stub {0} wurde im Test nicht gemockt.' }}" -f $name, ($params -join ', ')))
}
. ([scriptblock]::Create($stubText.ToString()))

# Quelldateien laden
$projekt = Import-PowerShellDataFile -Path (Join-Path -Path $testRoot -ChildPath 'build.psd1')
foreach ($eintrag in $projekt.Dateien) {
    if ($eintrag -eq '@checks') {
        foreach ($c in (Get-ChildItem -Path (Join-Path -Path $testRoot -ChildPath 'src/checks') -Filter '*.ps1' | Sort-Object -Property Name)) {
            . $c.FullName
        }
    }
    else {
        . (Join-Path -Path $testRoot -ChildPath $eintrag)
    }
}

# Testumgebung: nie interaktiv auf echte Eingaben warten, Daten in ein Testverzeichnis.
$script:NS.Interaktiv = $true
$script:NS.Umgebung = [pscustomobject]@{ IstCore = $true; HatGridView = $false; Computername = 'TESTSRV'; IstAdmin = $true }
$script:NS.Config = Get-NetDefaultConfig
function Read-NetInput { param([string]$Prompt, [switch]$Geheim) throw "Read-NetInput im Test nicht gemockt: $Prompt" }
function Write-Host { param([Parameter(Position = 0)][object]$Object, [object]$ForegroundColor, [switch]$NoNewline) }
