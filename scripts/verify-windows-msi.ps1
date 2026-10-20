param([Parameter(Mandatory=$true)][string]$MsiPath,[Parameter(Mandatory=$true)][string]$BundlePath,[string]$InstallDirectory)
$ErrorActionPreference='Stop'
$msi=(Resolve-Path -LiteralPath $MsiPath).Path
$bundle=(Resolve-Path -LiteralPath $BundlePath).Path
$installer=New-Object -ComObject WindowsInstaller.Installer
$installer.UILevel=2
$db=$installer.OpenDatabase($msi,0)
function Rows([string]$Query) {
    $view=$db.OpenView($Query)
    try {
        $view.Execute() | Out-Null
        while ($record=$view.Fetch()) { ,$record }
    } finally { $view.Close() | Out-Null }
}
$directories=@{}
foreach ($row in (Rows 'SELECT * FROM `Directory`')) { $directories[$row.StringData(1)]=$row.StringData(2) }
foreach ($id in $directories.Keys) {
    $seen=@{}; $node=$id
    while ($node) {
        if (!$directories.ContainsKey($node) -or $seen.ContainsKey($node)) { throw "Invalid directory tree: $id" }
        $seen[$node]=$true; $node=$directories[$node]
    }
}
$components=@{}
foreach ($row in (Rows 'SELECT * FROM `Component`')) {
    if (!$directories.ContainsKey($row.StringData(3))) { throw 'Unknown component directory' }
    $components[$row.StringData(1)]=$row.StringData(6)
}
$files=@(Rows 'SELECT * FROM `File` ORDER BY `Sequence`')
$originals=@(Get-ChildItem -LiteralPath $bundle -File -Recurse | Sort-Object FullName)
if ($files.Count -ne $originals.Count) { throw 'File count differs' }
$stage=Join-Path ([IO.Path]::GetTempPath()) ('Viora-Msi-Verify-'+[Guid]::NewGuid())
New-Item -ItemType Directory -Path $stage | Out-Null
$stream=@(Rows 'SELECT `Data` FROM `_Streams` WHERE `Name` = ''payload.cab''')[0]
$cab=Join-Path $stage 'payload.cab'
$output=[IO.File]::OpenWrite($cab)
try {
    do {
        $chunk=$stream.ReadStream(1,65536,1)
        if ($chunk) { $bytes=[Text.Encoding]::GetEncoding(28591).GetBytes($chunk); $output.Write($bytes,0,$bytes.Length) }
    } while ($chunk.Length -eq 65536)
} finally { $output.Dispose() }
& "$env:SystemRoot\System32\expand.exe" $cab '-F:*' $stage | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cabinet extraction failed' }
for ($i=0;$i -lt $files.Count;$i++) {
    $row=$files[$i]; $key=$row.StringData(1)
    if ($components[$row.StringData(2)] -ne $key) { throw 'Invalid component keypath' }
    if ($row.StringData(3).Split('|')[-1] -ne $originals[$i].Name) { throw 'Unexpected file name' }
    if ((Get-FileHash -LiteralPath (Join-Path $stage $key)).Hash -ne (Get-FileHash -LiteralPath $originals[$i].FullName).Hash) { throw "Payload mismatch: $key" }
}
# Read-only standard actions: no installation, registry writes or elevation.
$session=$installer.OpenPackage($msi,1)
if ($InstallDirectory) { $session.Property('INSTALLDIR')=$InstallDirectory }
foreach ($action in @('FindRelatedProducts','AppSearch','LaunchConditions','CostInitialize','FileCost','CostFinalize')) {
    if ($session.DoAction($action) -ne 1) { throw "MSI standard action failed: $action" }
}
$expected=if ($InstallDirectory) { $InstallDirectory.TrimEnd('\')+'\' } else { Join-Path $env:ProgramFiles 'Viora\' }
if ($session.Property('INSTALLDIR') -ne $expected) { throw 'Unexpected install directory' }
if ($session.Property('ENGINEDIR') -ne (Join-Path $env:ProgramFiles 'Viora\Engine\')) { throw 'Privileged component location must be fixed' }
foreach ($row in (Rows 'SELECT * FROM `Shortcut`')) { if ($row.StringData(5) -ne '[INSTALLDIR]Viora.exe') { throw 'Shortcut must target the real executable' } }
"Verified $($files.Count) payload hashes, directory tree, keypaths, OS requirements and install directory."
"Extracted verification payload retained at $stage"

$serviceRows=@(Rows 'SELECT * FROM `ServiceInstall`')
if ($serviceRows.Count -ne 1) { throw 'Expected exactly one VPN service' }
$serviceRow=$serviceRows[0]
if ($serviceRow.StringData(2) -ne 'VioraTunnel' -or $serviceRow.IntegerData(4) -ne 16 -or $serviceRow.IntegerData(5) -ne 2 -or $serviceRow.StringData(11) -ne '--service' -or $serviceRow.StringData(9)) { throw 'Unexpected service configuration' }
$serviceKey=$components[$serviceRow.StringData(12)]
$serviceFile=@($files | Where-Object { $_.StringData(1) -eq $serviceKey })
if ($serviceFile.Count -ne 1 -or $serviceFile[0].StringData(3).Split('|')[-1] -ne 'viora_tunnel.exe') { throw 'Service must use protected VPN helper' }
$serviceComponent=@(Rows 'SELECT * FROM `Component`' | Where-Object { $_.StringData(1) -eq $serviceRow.StringData(12) })
if ($serviceComponent[0].StringData(3) -ne 'ENGINEDIR') { throw 'Service must be in fixed protected Engine directory' }
$control=@(Rows 'SELECT * FROM `ServiceControl`')
if ($control.Count -ne 1 -or $control[0].IntegerData(3) -ne 163 -or $control[0].IntegerData(5) -ne 1) { throw 'Service stop/start/uninstall actions missing' }
$executeActions=@{}
foreach ($entry in (Rows 'SELECT * FROM `InstallExecuteSequence`')) { $executeActions[$entry.StringData(1)]=$entry.IntegerData(3) }
foreach ($action in @('StopServices','DeleteServices','InstallServices','StartServices')) { if (!$executeActions.ContainsKey($action)) { throw "Missing service action: $action" } }
if ($executeActions['InstallServices'] -le $executeActions['InstallFiles'] -or $executeActions['StartServices'] -le $executeActions['InstallServices']) { throw 'Service actions ordered incorrectly' }
'Verified protected automatic VPN service installation, startup, stop and removal.'
$firewall=@($files | Where-Object { $_.StringData(3).Split('|')[-1] -eq 'viora_firewall.exe' })
if ($firewall.Count -eq 1) {
 $action=@(Rows 'SELECT * FROM `CustomAction`' | Where-Object { $_.StringData(1) -eq 'RemoveVioraProtection' })
 if ($action.Count -ne 1 -or $action[0].IntegerData(2) -ne 3090 -or $action[0].StringData(3) -ne $firewall[0].StringData(1) -or $action[0].StringData(4) -ne 'disable') { throw 'Invalid firewall removal action' }
 $sequence=@(Rows 'SELECT * FROM `InstallExecuteSequence`' | Where-Object { $_.StringData(1) -eq 'RemoveVioraProtection' })
 if ($sequence[0].StringData(2) -ne 'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE' -or $sequence[0].IntegerData(3) -le $executeActions['StopServices'] -or $sequence[0].IntegerData(3) -ge $executeActions['RemoveFiles']) { throw 'Unsafe firewall removal sequence' }
 'Verified firewall recovery on full uninstall and policy preservation on upgrade.'
}
