param(
    [Parameter(Mandatory)][string]$Destination,
    [string]$SigningDirectory = "$env:USERPROFILE\.codex\signing\viora",
    [string]$JavaHome = 'D:\Android Studio\jbr'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
if (Test-Path -LiteralPath $Destination) { throw 'Backup destination already exists.' }
$repo = Split-Path $PSScriptRoot -Parent
if ([IO.Path]::GetFullPath($Destination).StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Private signing backups must be outside the repository.'
}
$profile = Get-Content -LiteralPath "$SigningDirectory\android-signing.json" -Raw | ConvertFrom-Json
$backupPassword = Read-Host 'Choose a strong password for the portable key backup' -AsSecureString
$confirmation = Read-Host 'Repeat backup password' -AsSecureString
$first = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($backupPassword)
$second = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($confirmation)
$previousSource = $env:VIORA_BACKUP_SOURCE_PASSWORD
$previousDestination = $env:VIORA_BACKUP_DESTINATION_PASSWORD
try {
    $env:VIORA_BACKUP_DESTINATION_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($first)
    if ($env:VIORA_BACKUP_DESTINATION_PASSWORD.Length -lt 16 -or
        $env:VIORA_BACKUP_DESTINATION_PASSWORD -cne [Runtime.InteropServices.Marshal]::PtrToStringBSTR($second)) {
        throw 'Passwords must match and contain at least 16 characters.'
    }
    $secret = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($profile.passwordDpapi), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $env:VIORA_BACKUP_SOURCE_PASSWORD = [Text.Encoding]::UTF8.GetString($secret)
    & "$JavaHome\bin\keytool.exe" -importkeystore -srckeystore $profile.keyPath -srcalias $profile.alias -srcstorepass:env VIORA_BACKUP_SOURCE_PASSWORD -srckeypass:env VIORA_BACKUP_SOURCE_PASSWORD -destkeystore $Destination -deststoretype JKS -destalias $profile.alias -deststorepass:env VIORA_BACKUP_DESTINATION_PASSWORD -destkeypass:env VIORA_BACKUP_DESTINATION_PASSWORD -noprompt
    if ($LASTEXITCODE -ne 0) { throw 'Backup export failed.' }
    Write-Output 'Portable encrypted signing backup created. Keep the password separately.'
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($first)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($second)
    $env:VIORA_BACKUP_SOURCE_PASSWORD = $previousSource
    $env:VIORA_BACKUP_DESTINATION_PASSWORD = $previousDestination
    if ($secret) { [Array]::Clear($secret, 0, $secret.Length) }
}
