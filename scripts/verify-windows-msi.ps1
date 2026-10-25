param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][string]$BundlePath,
    [string]$InstallDirectory,
    [Parameter(DontShow=$true)][switch]$AdversarialCostingOnly
)
$ErrorActionPreference='Stop'
$msi=(Resolve-Path -LiteralPath $MsiPath).Path
$bundle=(Resolve-Path -LiteralPath $BundlePath).Path
$installer=New-Object -ComObject WindowsInstaller.Installer
$installer.UILevel=2
# CostInitialize is not a repeatable reset of an already-costed MSI session.
# Run the independent adversarial scenario in its own process/session instead.
if ($AdversarialCostingOnly) {
    $attackSession=$null
    try {
        $attackSession=$installer.OpenPackage($msi,1)
        $attack='C:\Users\Public\Viora-Untrusted-Engine\'
        $uiChoice='C:\Users\Public\Viora-Ui-Choice\'
        $attackSession.Property('INSTALLDIR')=$uiChoice
        foreach($id in @('ENGINEDIR','ENGINEPARENT','ENGINECORE','EngineDir','EngineParent','EngineCore')) { $attackSession.Property($id)=$attack }
        foreach($action in @('CostInitialize','FileCost','FixEngineParent','FixEngineDir','FixEngineCore','CostFinalize')) {
            if($attackSession.DoAction($action) -ne 1) { throw "Adversarial read-only costing failed: $action" }
        }
        if($attackSession.Property('EngineDir') -ne (Join-Path $env:ProgramFiles 'Viora\Engine\') -or $attackSession.Property('EngineCore') -ne (Join-Path $env:ProgramFiles 'Viora\Engine\core\') -or $attackSession.Property('INSTALLDIR') -ne $uiChoice) { throw 'Privileged MSI path override was accepted or UI choice changed' }
        'Verified independent adversarial path costing: privileged files fixed; application destination preserved.'
    } finally {
        if ($null -ne $attackSession) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($attackSession) | Out-Null }
        [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
    }
    return
}
$records=[Collections.Generic.List[object]]::new()
$session=$null
$db=$null
try {
$db=$installer.OpenDatabase($msi,0)
function Rows([string]$Query) {
    $view=$db.OpenView($Query)
    try {
        $view.Execute() | Out-Null
        while ($record=$view.Fetch()) { $records.Add($record); ,$record }
    } finally {
        try { $view.Close() | Out-Null } finally { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($view) | Out-Null }
    }
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
    $expectedFileVersion=[string]$installer.FileVersion($originals[$i].FullName,$false)
    if ($row.StringData(5) -ne $expectedFileVersion) { throw "File version metadata mismatch: $key" }
    if ((Get-FileHash -LiteralPath (Join-Path $stage $key)).Hash -ne (Get-FileHash -LiteralPath $originals[$i].FullName).Hash) { throw "Payload mismatch: $key" }
}
$restartManager=@(Rows 'SELECT * FROM `Property`' | Where-Object { $_.StringData(1) -eq 'MSIRESTARTMANAGERCONTROL' })
if ($restartManager.Count -ne 0) { throw 'Package must keep default Windows Restart Manager behavior' }
# Read-only standard actions: no installation, registry writes or elevation.
$session=$installer.OpenPackage($msi,1)
if ($InstallDirectory) { $session.Property('INSTALLDIR')=$InstallDirectory }
foreach ($action in @('FindRelatedProducts','AppSearch','LaunchConditions','CostInitialize','FileCost','FixEngineParent','FixEngineDir','FixEngineCore','CostFinalize')) {
    if ($session.DoAction($action) -ne 1) { throw "MSI standard action failed: $action" }
}
$expected=if ($InstallDirectory) { $InstallDirectory.TrimEnd('\')+'\' } else { Join-Path $env:ProgramFiles 'Viora\' }
if ($session.Property('INSTALLDIR') -ne $expected) { throw 'Unexpected install directory' }
if ($session.Property('EngineDir') -ne (Join-Path $env:ProgramFiles 'Viora\Engine\')) { throw 'Privileged component location must be fixed' }
foreach ($entry in @(
 @('FixEngineParent','EngineParent','[ProgramFiles64Folder]Viora\'),
 @('FixEngineDir','EngineDir','[ProgramFiles64Folder]Viora\Engine\'),
 @('FixEngineCore','EngineCore','[ProgramFiles64Folder]Viora\Engine\core\')
)) {
 $reset=@(Rows 'SELECT * FROM `CustomAction`' | Where-Object {$_.StringData(1) -eq $entry[0]})
 if($reset.Count -ne 1 -or $reset[0].IntegerData(2) -ne 51 -or $reset[0].StringData(3) -ne $entry[1] -or $reset[0].StringData(4) -ne $entry[2]) { throw 'Missing fixed privileged directory action' }
 foreach ($table in @('InstallUISequence','InstallExecuteSequence')) {
  $sequence=@(Rows ('SELECT * FROM `' + $table + '`') | Where-Object {$_.StringData(1) -eq $entry[0]})
  if($sequence.Count -ne 1 -or $sequence[0].IntegerData(3) -le 900 -or $sequence[0].IntegerData(3) -ge 1000) { throw 'Unsafe fixed-path action sequence' }
 }
}
# Adversarial read-only costing: legacy public properties and a private value
# set by a UI session must not redirect privileged files to a writable folder.
$powershell=(Get-Process -Id $PID).Path
& $powershell -NoProfile -NonInteractive -File $PSCommandPath -MsiPath $msi -BundlePath $bundle -AdversarialCostingOnly
if ($LASTEXITCODE -ne 0) { throw "Independent adversarial costing process failed: $LASTEXITCODE" }
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
if ($serviceComponent[0].StringData(3) -ne 'EngineDir') { throw 'Service must be in fixed protected Engine directory' }
$control=@(Rows 'SELECT * FROM `ServiceControl`')
if ($control.Count -ne 1 -or $control[0].StringData(2) -ne 'VioraTunnel' -or $control[0].IntegerData(3) -ne 162 -or $control[0].StringData(4) -or $control[0].IntegerData(5) -ne 1 -or $control[0].StringData(6) -ne $serviceRow.StringData(12)) { throw 'Service stop/delete/wait metadata must not use the standard start event' }
$executeActions=@{}
foreach ($entry in (Rows 'SELECT * FROM `InstallExecuteSequence`')) { $executeActions[$entry.StringData(1)]=$entry.IntegerData(3) }
foreach ($action in @('CostFinalize','InstallInitialize','InstallFiles','StopServices','DeleteServices','InstallServices','InstallFinalize')) { if (!$executeActions.ContainsKey($action)) { throw "Missing service action: $action" } }
if ($executeActions.ContainsKey('StartServices')) { throw 'Standard service startup must be replaced by the bounded helper action' }
$startAction=@(Rows 'SELECT * FROM `CustomAction`' | Where-Object { $_.StringData(1) -eq 'StartVioraService' })
if ($startAction.Count -ne 1 -or $startAction[0].IntegerData(2) -ne 3090 -or $startAction[0].StringData(3) -ne $serviceKey -or $startAction[0].StringData(4) -ne '--install-start') { throw 'Bounded service start must be a checked deferred SYSTEM action from the protected helper' }
$startSequence=@(Rows 'SELECT * FROM `InstallExecuteSequence`' | Where-Object { $_.StringData(1) -eq 'StartVioraService' })
$startCondition='NOT (REMOVE~="ALL") AND ($' + $serviceRow.StringData(12) + '=3)'
if ($startSequence.Count -ne 1 -or $startSequence[0].StringData(2) -ne $startCondition -or $startSequence[0].IntegerData(3) -ne 5900) { throw 'Unsafe bounded service start condition or sequence' }
if (@(Rows 'SELECT * FROM `InstallUISequence`' | Where-Object { $_.StringData(1) -eq 'StartVioraService' }).Count -ne 0) { throw 'Deferred service startup must only run in the execute sequence' }
if ($executeActions['InstallServices'] -le $executeActions['InstallFiles'] -or $executeActions['StartVioraService'] -le $executeActions['InstallServices'] -or $executeActions['StartVioraService'] -ge $executeActions['InstallFinalize'] -or $executeActions['StartVioraService'] -le $executeActions['InstallInitialize'] -or $executeActions['StartVioraService'] -le $executeActions['CostFinalize']) { throw 'Service actions ordered incorrectly' }
'Verified service startup metadata: bounded helper action, checked failure, stop/delete and automatic service registration. No service was started by verification.'
$firewall=@($files | Where-Object { $_.StringData(3).Split('|')[-1] -eq 'viora_firewall.exe' })
if ($firewall.Count -eq 1) {
 $action=@(Rows 'SELECT * FROM `CustomAction`' | Where-Object { $_.StringData(1) -eq 'RemoveVioraProtection' })
 if ($action.Count -ne 1 -or $action[0].IntegerData(2) -ne 3090 -or $action[0].StringData(3) -ne $firewall[0].StringData(1) -or $action[0].StringData(4) -ne 'disable') { throw 'Invalid firewall removal action' }
 $sequence=@(Rows 'SELECT * FROM `InstallExecuteSequence`' | Where-Object { $_.StringData(1) -eq 'RemoveVioraProtection' })
 if ($sequence[0].StringData(2) -ne 'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE' -or $sequence[0].IntegerData(3) -le $executeActions['StopServices'] -or $sequence[0].IntegerData(3) -ge $executeActions['RemoveFiles']) { throw 'Unsafe firewall removal sequence' }
 'Verified uninstall firewall recovery action and policy-preserving upgrade condition.'
}
} finally {
    foreach ($record in $records) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) | Out-Null }
    if ($null -ne $session) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($session) | Out-Null }
    if ($null -ne $db) { [Runtime.InteropServices.Marshal]::FinalReleaseComObject($db) | Out-Null }
    [Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) | Out-Null
}
