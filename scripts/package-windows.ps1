param([Parameter(Mandatory=$true)][string]$BundlePath,
      [string]$Name = 'Viora-Windows-0.4.2')
$ErrorActionPreference = 'Stop'
if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$' -or $Name.Contains('..')) { throw 'Invalid package name' }
$vioraRoot = Split-Path -Parent $PSScriptRoot
$vioraBundle = (Resolve-Path -LiteralPath $BundlePath).Path
foreach ($entry in @('viora_client.exe', 'flutter_windows.dll', 'data')) {
    if (-not (Test-Path -LiteralPath (Join-Path $vioraBundle $entry))) { throw "Missing bundle entry: $entry" }
}
$vioraArtifacts = Join-Path $vioraRoot 'artifacts'
New-Item -ItemType Directory -Path $vioraArtifacts -Force | Out-Null
$vioraOutput = Join-Path $vioraArtifacts $Name
if ((Test-Path -LiteralPath $vioraOutput) -or (Test-Path -LiteralPath "$vioraOutput.zip")) {
    throw 'Package already exists; choose another name to preserve the previous build'
}
New-Item -ItemType Directory -Path $vioraOutput | Out-Null
Copy-Item -LiteralPath (Join-Path $vioraBundle 'viora_client.exe') -Destination (Join-Path $vioraOutput 'Viora.exe')
Get-ChildItem -LiteralPath $vioraBundle -Filter '*.dll' -File | Copy-Item -Destination $vioraOutput
Copy-Item -LiteralPath (Join-Path $vioraBundle 'data') -Destination $vioraOutput -Recurse
if (Test-Path -LiteralPath (Join-Path $vioraBundle 'native_assets.json')) {
    Copy-Item -LiteralPath (Join-Path $vioraBundle 'native_assets.json') -Destination $vioraOutput
}
@'
Viora — Windows development preview

Extract the entire ZIP and run Viora.exe from this directory.
Keep flutter_windows.dll and the data directory next to the executable.
This package requires the Microsoft Visual C++ x64 runtime.

Telegram account login, subscription renewal, devices and server-authorized
owner operations use the same account API as Android. These are real operations.
Session and server credentials are encrypted for the current Windows user.
The native Windows VPN tunnel is not integrated in this version.
Importing or testing ping does not establish a VPN connection.
Preferences are retained in %LOCALAPPDATA%/viora/preferences.json.
'@ | Set-Content -LiteralPath (Join-Path $vioraOutput 'READ-ME.txt') -Encoding utf8
Compress-Archive -LiteralPath $vioraOutput -DestinationPath "$vioraOutput.zip"
Get-Item -LiteralPath "$vioraOutput.zip" | Select-Object FullName,Length
