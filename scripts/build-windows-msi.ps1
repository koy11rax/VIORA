param(
    [Parameter(Mandatory=$true)][string]$BundlePath,
    [string]$Version = '0.8.2',
    [string]$OutputName = 'Viora-Windows-0.8.2'
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $OutputName -notmatch '^[A-Za-z0-9_-]+[A-Za-z0-9_.-]*$') { throw 'Invalid version or output name' }
$vioraRoot = Split-Path $PSScriptRoot -Parent
$vioraBundle = (Resolve-Path -LiteralPath $BundlePath).Path
$vioraArtifacts = Join-Path $vioraRoot 'artifacts'
$vioraBuild = Join-Path $vioraArtifacts ($OutputName + '-installer')
$vioraMsi = Join-Path $vioraArtifacts ($OutputName + '.msi')
if ((Test-Path -LiteralPath $vioraBuild) -or (Test-Path -LiteralPath $vioraMsi)) { throw 'Installer already exists; choose another name' }
foreach ($entry in @('Viora.exe','flutter_windows.dll','viora_tunnel.exe','core\xray.exe','core\wintun.dll','data\icudtl.dat')) {
    if (!(Test-Path -LiteralPath (Join-Path $vioraBundle $entry))) { throw "Missing $entry" }
}
New-Item -ItemType Directory -Path $vioraBuild | Out-Null

# Windows Installer database and cabinet builder are part of Windows itself.
$vioraInstaller = New-Object -ComObject WindowsInstaller.Installer
$vioraDb = $vioraInstaller.OpenDatabase($vioraMsi, 3)
function Sql([string]$Statement) {
    $view = $vioraDb.OpenView($Statement)
    try { $view.Execute() | Out-Null } finally { $view.Close() | Out-Null }
}
function Q([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
function Insert([string]$Table, [string[]]$Columns, [object[]]$Values) {
    $names = ($Columns | ForEach-Object { '`' + $_ + '`' }) -join ','
    $items = ($Values | ForEach-Object { if ($null -eq $_) { 'NULL' } elseif ($_ -is [int]) { [string]$_ } else { Q ([string]$_) } }) -join ','
    Sql ('INSERT INTO `' + $Table + '` (' + $names + ') VALUES (' + $items + ')')
}
function StableGuid([string]$Name) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('dev.viora.windows/' + $Name.ToLowerInvariant())) } finally { $sha.Dispose() }
    return '{' + ([Guid]::new([byte[]]$bytes[0..15])).ToString().ToUpperInvariant() + '}'
}
Sql 'CREATE TABLE `Property` (`Property` CHAR(72) NOT NULL, `Value` CHAR(0) LOCALIZABLE PRIMARY KEY `Property`)'
Sql 'CREATE TABLE `CustomAction` (`Action` CHAR(72) NOT NULL, `Type` SHORT NOT NULL, `Source` CHAR(72), `Target` CHAR(255) PRIMARY KEY `Action`)'
Sql 'CREATE TABLE `Directory` (`Directory` CHAR(72) NOT NULL, `Directory_Parent` CHAR(72), `DefaultDir` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY `Directory`)'
Sql 'CREATE TABLE `Component` (`Component` CHAR(72) NOT NULL, `ComponentId` CHAR(38), `Directory_` CHAR(72) NOT NULL, `Attributes` SHORT NOT NULL, `Condition` CHAR(255), `KeyPath` CHAR(72) PRIMARY KEY `Component`)'
Sql 'CREATE TABLE `Feature` (`Feature` CHAR(38) NOT NULL, `Feature_Parent` CHAR(38), `Title` CHAR(64) LOCALIZABLE, `Description` CHAR(255) LOCALIZABLE, `Display` SHORT, `Level` SHORT NOT NULL, `Directory_` CHAR(72), `Attributes` SHORT NOT NULL PRIMARY KEY `Feature`)'
Sql 'CREATE TABLE `FeatureComponents` (`Feature_` CHAR(38) NOT NULL, `Component_` CHAR(72) NOT NULL PRIMARY KEY `Feature_`, `Component_`)'
Sql 'CREATE TABLE `File` (`File` CHAR(72) NOT NULL, `Component_` CHAR(72) NOT NULL, `FileName` CHAR(255) NOT NULL LOCALIZABLE, `FileSize` LONG NOT NULL, `Version` CHAR(72), `Language` CHAR(20), `Attributes` SHORT, `Sequence` LONG NOT NULL PRIMARY KEY `File`)'
Sql 'CREATE TABLE `Media` (`DiskId` SHORT NOT NULL, `LastSequence` LONG NOT NULL, `DiskPrompt` CHAR(64) LOCALIZABLE, `Cabinet` CHAR(255), `VolumeLabel` CHAR(32), `Source` CHAR(72) PRIMARY KEY `DiskId`)'
Sql 'CREATE TABLE `Shortcut` (`Shortcut` CHAR(72) NOT NULL, `Directory_` CHAR(72) NOT NULL, `Name` CHAR(128) NOT NULL LOCALIZABLE, `Component_` CHAR(72) NOT NULL, `Target` CHAR(255) NOT NULL, `Arguments` CHAR(255), `Description` CHAR(255) LOCALIZABLE, `Hotkey` SHORT, `Icon_` CHAR(72), `IconIndex` SHORT, `ShowCmd` SHORT, `WkDir` CHAR(72) PRIMARY KEY `Shortcut`)'
Sql 'CREATE TABLE `Icon` (`Name` CHAR(72) NOT NULL, `Data` OBJECT NOT NULL PRIMARY KEY `Name`)'
Sql 'CREATE TABLE `Upgrade` (`UpgradeCode` CHAR(38) NOT NULL, `VersionMin` CHAR(20), `VersionMax` CHAR(20), `Language` CHAR(255), `Attributes` LONG NOT NULL, `Remove` CHAR(255), `ActionProperty` CHAR(72) NOT NULL PRIMARY KEY `UpgradeCode`, `VersionMin`, `VersionMax`, `Language`, `Attributes`)'
Sql 'CREATE TABLE `LaunchCondition` (`Condition` CHAR(255) NOT NULL, `Description` CHAR(255) NOT NULL LOCALIZABLE PRIMARY KEY `Condition`)'
Sql 'CREATE TABLE `AppSearch` (`Property` CHAR(72) NOT NULL, `Signature_` CHAR(72) NOT NULL PRIMARY KEY `Property`, `Signature_`)'
Sql 'CREATE TABLE `Signature` (`Signature` CHAR(72) NOT NULL, `FileName` CHAR(255), `MinVersion` CHAR(20), `MaxVersion` CHAR(20), `MinSize` LONG, `MaxSize` LONG, `MinDate` LONG, `MaxDate` LONG, `Languages` CHAR(255) PRIMARY KEY `Signature`)'
Sql 'CREATE TABLE `RegLocator` (`Signature_` CHAR(72) NOT NULL, `Root` SHORT NOT NULL, `Key` CHAR(255) NOT NULL, `Name` CHAR(255), `Type` SHORT PRIMARY KEY `Signature_`)'
Sql 'CREATE TABLE `ServiceInstall` (`ServiceInstall` CHAR(72) NOT NULL, `Name` CHAR(255) NOT NULL, `DisplayName` CHAR(255) LOCALIZABLE, `ServiceType` LONG NOT NULL, `StartType` LONG NOT NULL, `ErrorControl` LONG NOT NULL, `LoadOrderGroup` CHAR(255), `Dependencies` CHAR(255), `StartName` CHAR(255), `Password` CHAR(255), `Arguments` CHAR(255), `Component_` CHAR(72) NOT NULL, `Description` CHAR(255) LOCALIZABLE PRIMARY KEY `ServiceInstall`)'
Sql 'CREATE TABLE `ServiceControl` (`ServiceControl` CHAR(72) NOT NULL, `Name` CHAR(255) NOT NULL, `Event` SHORT NOT NULL, `Arguments` CHAR(255), `Wait` SHORT, `Component_` CHAR(72) NOT NULL PRIMARY KEY `ServiceControl`)'
foreach ($table in @('InstallExecuteSequence','InstallUISequence')) { Sql ('CREATE TABLE `' + $table + '` (`Action` CHAR(72) NOT NULL, `Condition` CHAR(255), `Sequence` SHORT PRIMARY KEY `Action`)') }
$vioraUpgrade = '{B9D08CBD-5156-40AB-9C90-1CF122A96FCB}'
foreach ($pair in @(
    @('ProductCode',('{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}')),
    @('UpgradeCode',$vioraUpgrade), @('ProductName','VIORA'), @('ProductVersion',$Version),
    @('ProductLanguage','1049'), @('Manufacturer','Viora'), @('ALLUSERS','1'),
    @('INSTALLLEVEL','1'), @('ARPNOMODIFY','1'), @('ARPURLINFOABOUT','https://vpnfn2345.duckdns.org'),
    @('ARPPRODUCTICON','VioraIcon'), @('SecureCustomProperties','OLDPRODUCTS;NEWERPRODUCTS;INSTALLDIR'),
    @('MSIRESTARTMANAGERCONTROL','Disable'), @('REBOOT','ReallySuppress')
)) { Insert Property @('Property','Value') $pair }
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('TARGETDIR',$null,'SourceDir')
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('ProgramFiles64Folder','TARGETDIR','.')
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('INSTALLDIR','ProgramFiles64Folder','Viora')
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('ENGINEPARENT','ProgramFiles64Folder','Viora')
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('ENGINEDIR','ENGINEPARENT','Engine')
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('ENGINECORE','ENGINEDIR','core')
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('ProgramMenuFolder','TARGETDIR','.')
Insert Directory @('Directory','Directory_Parent','DefaultDir') @('DesktopFolder','TARGETDIR','.')
Insert Feature @('Feature','Feature_Parent','Title','Description','Display','Level','Directory_','Attributes') @('Viora',$null,'VIORA','Viora VPN',1,1,'INSTALLDIR',0)
Insert AppSearch @('Property','Signature_') @('CURRENTBUILD','WindowsBuild')
Insert RegLocator @('Signature_','Root','Key','Name','Type') @('WindowsBuild',2,'SOFTWARE\Microsoft\Windows NT\CurrentVersion','CurrentBuildNumber',18)
Insert LaunchCondition @('Condition','Description') @('Installed OR (VersionNT64 AND CURRENTBUILD >= 10240)','Viora requires 64-bit Windows 10 or Windows 11.')
Insert LaunchCondition @('Condition','Description') @('Installed OR NOT NEWERPRODUCTS','This or a newer Viora version is already installed.')
Insert Upgrade @('UpgradeCode','VersionMin','VersionMax','Language','Attributes','Remove','ActionProperty') @($vioraUpgrade,'0.0.0',$Version,$null,257,$null,'OLDPRODUCTS')
Insert Upgrade @('UpgradeCode','VersionMin','VersionMax','Language','Attributes','Remove','ActionProperty') @($vioraUpgrade,$Version,$null,$null,258,$null,'NEWERPRODUCTS')
$vioraDirs = @{ '' = 'INSTALLDIR' }
$vioraDirCount = 0
function DirectoryId([string]$Relative) {
    if ($vioraDirs.ContainsKey($Relative)) { return $vioraDirs[$Relative] }
    $parent = Split-Path $Relative -Parent
    if (!$parent) { $parent = '' }
    $parentId = DirectoryId $parent
    $script:vioraDirCount++
    $id = 'D' + $script:vioraDirCount.ToString('D5')
    Insert Directory @('Directory','Directory_Parent','DefaultDir') @($id,$parentId,($id + '|' + (Split-Path $Relative -Leaf)))
    $vioraDirs[$Relative] = $id
    return $id
}
$vioraDdf = [Collections.Generic.List[string]]::new()
$vioraDdf.Add('.OPTION EXPLICIT')
foreach ($line in @('.Set Cabinet=on','.Set Compress=on','.Set CompressionType=LZX','.Set CompressionMemory=21','.Set MaxDiskSize=0','.Set MaxCabinetSize=0','.Set FolderSizeThreshold=200000000','.Set CabinetNameTemplate=payload.cab',('.Set DiskDirectoryTemplate="' + $vioraBuild + '"'))) { $vioraDdf.Add($line) }
$vioraSequence = 0
$vioraMainComponent = ''
$vioraServiceComponent = ''
$vioraFirewallFile = ''
foreach ($file in (Get-ChildItem -LiteralPath $vioraBundle -Recurse -File | Sort-Object FullName)) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Bundle must not contain reparse points' }
    $relative = [IO.Path]::GetRelativePath($vioraBundle,$file.FullName)
    $relativeDir = Split-Path $relative -Parent
    if (!$relativeDir) { $relativeDir = '' }
    $isEngine = $relative -in @('viora_tunnel.exe','viora_firewall.exe') -or $relativeDir -eq 'core'
    $directory = if ($relative -in @('viora_tunnel.exe','viora_firewall.exe')) { 'ENGINEDIR' } elseif ($relativeDir -eq 'core') { 'ENGINECORE' } else { DirectoryId $relativeDir }
    $vioraSequence++
    $key = 'F' + $vioraSequence.ToString('D5')
    $component = 'C' + $vioraSequence.ToString('D5')
    $identity = if ($isEngine) { 'Engine/' + $relative } else { $relative }
    Insert Component @('Component','ComponentId','Directory_','Attributes','Condition','KeyPath') @($component,(StableGuid $identity),$directory,256,$null,$key)
    Insert FeatureComponents @('Feature_','Component_') @('Viora',$component)
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($file.FullName)
    $fileVersion = if ($versionInfo.FileMajorPart -gt 0) { '{0}.{1}.{2}.{3}' -f $versionInfo.FileMajorPart,$versionInfo.FileMinorPart,$versionInfo.FileBuildPart,$versionInfo.FilePrivatePart } else { $null }
    Insert File @('File','Component_','FileName','FileSize','Version','Language','Attributes','Sequence') @($key,$component,($key + '|' + $file.Name),[int]$file.Length,$fileVersion,$null,16384,$vioraSequence)
    $vioraDdf.Add('"' + $file.FullName + '" ' + $key)
    if ($relative -eq 'viora_tunnel.exe') { $vioraServiceComponent = $component }
    if ($relative -eq 'viora_firewall.exe') { $vioraFirewallFile = $key }
    if ($relative -eq 'Viora.exe') { $vioraMainComponent = $component }
}
if (!$vioraServiceComponent) { throw 'VPN service component missing' }
if (!$vioraFirewallFile) { throw 'Persistent firewall component missing' }
# Deferred SYSTEM action, before removing binaries; major upgrades preserve the
# policy. A failure aborts uninstall rather than leaving an unrecoverable lock.
Insert CustomAction @('Action','Type','Source','Target') @('RemoveVioraProtection',3090,$vioraFirewallFile,'disable')
Insert InstallExecuteSequence @('Action','Condition','Sequence') @('RemoveVioraProtection','REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE',1950)
Insert ServiceInstall @('ServiceInstall','Name','DisplayName','ServiceType','StartType','ErrorControl','LoadOrderGroup','Dependencies','StartName','Password','Arguments','Component_','Description') @('VioraTunnel','VioraTunnel','VIORA VPN',16,2,32769,$null,$null,$null,$null,'--service',$vioraServiceComponent,'VIORA VPN tunnel service')
Insert ServiceControl @('ServiceControl','Name','Event','Arguments','Wait','Component_') @('VioraTunnel','VioraTunnel',163,$null,1,$vioraServiceComponent)
Insert Media @('DiskId','LastSequence','DiskPrompt','Cabinet','VolumeLabel','Source') @(1,$vioraSequence,$null,'#payload.cab',$null,$null)
foreach ($directory in @('ProgramMenuFolder','DesktopFolder')) {
    Insert Shortcut @('Shortcut','Directory_','Name','Component_','Target','Arguments','Description','Hotkey','Icon_','IconIndex','ShowCmd','WkDir') @($directory,$directory,'VIORA',$vioraMainComponent,'[INSTALLDIR]Viora.exe',$null,'Viora VPN',$null,'VioraIcon',0,1,'INSTALLDIR')
}
$view = $vioraDb.OpenView('INSERT INTO `Icon` (`Name`,`Data`) VALUES (?,?)')
$record = $vioraInstaller.CreateRecord(2)
$record.StringData(1) = 'VioraIcon'
$record.SetStream(2,(Join-Path $vioraRoot 'apps\client\windows\runner\resources\app_icon.ico'))
$view.Execute($record); $view.Close()
foreach ($entry in @(
    @('FindRelatedProducts',25),@('AppSearch',50),@('LaunchConditions',100),@('ValidateProductID',700),
 @('CostInitialize',800),@('FileCost',900),@('CostFinalize',1000),@('MigrateFeatureStates',1200),
 @('InstallValidate',1400),@('InstallInitialize',1500),@('RemoveExistingProducts',1550),
 @('ProcessComponents',1600),@('UnpublishFeatures',1800),@('StopServices',1900),@('DeleteServices',2000),@('RemoveShortcuts',3200),
 @('RemoveFiles',3500),@('RemoveFolders',3600),@('CreateFolders',3700),@('InstallFiles',4000),
 @('CreateShortcuts',4500),@('InstallServices',5800),@('StartServices',5900),@('RegisterUser',6000),@('RegisterProduct',6100),
 @('PublishFeatures',6300),@('PublishProduct',6400),@('InstallFinalize',6600)
)) { Insert InstallExecuteSequence @('Action','Condition','Sequence') @($entry[0],$null,[int]$entry[1]) }
foreach ($entry in @(@('FindRelatedProducts',25),@('AppSearch',50),@('LaunchConditions',100),@('CostInitialize',800),@('FileCost',900),@('CostFinalize',1000),@('ExecuteAction',1300))) {
    Insert InstallUISequence @('Action','Condition','Sequence') @($entry[0],$null,[int]$entry[1])
}
$vioraDdfPath = Join-Path $vioraBuild 'payload.ddf'
$vioraDdf | Set-Content -LiteralPath $vioraDdfPath -Encoding ascii
& "$env:SystemRoot\System32\makecab.exe" /F $vioraDdfPath /V1 *> (Join-Path $vioraBuild 'makecab.log')
if ($LASTEXITCODE -ne 0) { throw 'Cabinet build failed' }
$view = $vioraDb.OpenView('INSERT INTO `_Streams` (`Name`,`Data`) VALUES (?,?)')
$record = $vioraInstaller.CreateRecord(2)
$record.StringData(1) = 'payload.cab'
$record.SetStream(2,(Join-Path $vioraBuild 'payload.cab'))
$view.Execute($record); $view.Close()
$summary = $vioraDb.SummaryInformation(20)
$summary.Property(1) = 1251
$summary.Property(2) = 'VIORA installation'
$summary.Property(3) = 'Viora VPN'
$summary.Property(4) = 'Viora'
$summary.Property(7) = 'x64;1049'
$summary.Property(9) = '{' + [Guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$summary.Property(14) = 500
$summary.Property(15) = 2
$summary.Persist()
$vioraDb.Commit()
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) | Out-Null
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($vioraDb) | Out-Null
[Runtime.InteropServices.Marshal]::FinalReleaseComObject($vioraInstaller) | Out-Null
Get-Item -LiteralPath $vioraMsi | Select-Object FullName,Length
