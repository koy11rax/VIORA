param(
    [string]$SigningDirectory = "$env:USERPROFILE\.codex\signing\viora",
    [string]$JavaHome = 'D:\Android Studio\jbr',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$VersionName = '1.0.2',
    [int]$VersionCode = 32,
    [switch]$InitializeKey,
    [switch]$UseGoogleMirror
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$repo = Split-Path $PSScriptRoot -Parent
& "$PSScriptRoot\fetch-android-core.ps1"
$profilePath = Join-Path $SigningDirectory 'android-signing.json'
$keyPath = Join-Path $SigningDirectory 'android-release.jks'
$keytool = Join-Path $JavaHome 'bin\keytool.exe'
if (!(Test-Path -LiteralPath $keytool)) { throw 'JDK keytool was not found.' }
if ($InitializeKey) {
    if ((Test-Path -LiteralPath $profilePath) -or (Test-Path -LiteralPath $keyPath)) {
        throw 'Signing material already exists. It must never be replaced for an existing app.'
    }
    if ([IO.Path]::GetFullPath($SigningDirectory).StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Signing keys must be outside the repository.'
    }
    New-Item -ItemType Directory -Path $SigningDirectory -Force | Out-Null
    $random = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($random)
    $rng.Dispose()
    $password = [Convert]::ToBase64String($random)
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($password), $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    # Persist recovery material before key generation; never print the password.
    @{ keyPath = $keyPath; alias = 'viora'; passwordDpapi = [Convert]::ToBase64String($protected) } |
        ConvertTo-Json | Set-Content -LiteralPath $profilePath -Encoding UTF8
    $env:VIORA_ANDROID_STORE_PASSWORD = $password
    try {
        & $keytool -genkeypair -keystore $keyPath -storetype JKS -alias viora -keyalg RSA -keysize 3072 -sigalg SHA256withRSA -validity 10000 -dname 'CN=Viora Android Release' -storepass:env VIORA_ANDROID_STORE_PASSWORD -keypass:env VIORA_ANDROID_STORE_PASSWORD
        if ($LASTEXITCODE -ne 0) { throw 'Key generation failed; preserve the signing profile for recovery.' }
    } finally { Remove-Item Env:VIORA_ANDROID_STORE_PASSWORD -ErrorAction SilentlyContinue; $password = $null }
}
if (!(Test-Path -LiteralPath $profilePath)) { throw 'No signing profile. Initialize once with -InitializeKey.' }
$profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
if (!(Test-Path -LiteralPath $profile.keyPath)) { throw 'Signing key is missing. Restore it; do not generate a replacement.' }
$names = @('JAVA_HOME', 'VIORA_ANDROID_KEYSTORE', 'VIORA_ANDROID_KEY_ALIAS', 'VIORA_ANDROID_STORE_PASSWORD', 'VIORA_ANDROID_KEY_PASSWORD')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $secret = [Security.Cryptography.ProtectedData]::Unprotect(
        [Convert]::FromBase64String($profile.passwordDpapi), $null,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $env:JAVA_HOME = $JavaHome
    $env:VIORA_ANDROID_KEYSTORE = $profile.keyPath
    $env:VIORA_ANDROID_KEY_ALIAS = $profile.alias
    $env:VIORA_ANDROID_STORE_PASSWORD = [Text.Encoding]::UTF8.GetString($secret)
    $env:VIORA_ANDROID_KEY_PASSWORD = $env:VIORA_ANDROID_STORE_PASSWORD
    $argsList = @('-p', "$repo\apps\client\android", 'assembleRelease', '-Ptarget=lib/main.dart', "-PvioraVersionName=$VersionName", "-PvioraVersionCode=$VersionCode", '--console=plain', '--max-workers=4')
    if ($UseGoogleMirror) { $argsList += @('-I', "$repo\scripts\android-google-mirror.init.gradle") }
    & "$repo\apps\client\android\gradlew.bat" @argsList
    if ($LASTEXITCODE -ne 0) { throw 'Android release build failed.' }
    $apksigner = Get-ChildItem -LiteralPath "$AndroidSdk\build-tools" -Filter apksigner.bat -Recurse |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (!$apksigner) { throw 'Android SDK apksigner was not found.' }
    & $apksigner verify --verbose --print-certs "$repo\apps\client\build\app\outputs\apk\release\app-release.apk"
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
    $destination = "$repo\artifacts\Viora-Android-$VersionName-release.apk"
    Copy-Item -LiteralPath "$repo\apps\client\build\app\outputs\apk\release\app-release.apk" -Destination $destination
    & $keytool -exportcert -rfc -keystore $profile.keyPath -alias $profile.alias -storepass:env VIORA_ANDROID_STORE_PASSWORD -file "$SigningDirectory\android-release-public.pem"
    if ($LASTEXITCODE -ne 0) { throw 'Public certificate export failed.' }
    Write-Output "Signed APK: $destination"
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    if ($secret) { [Array]::Clear($secret, 0, $secret.Length) }
}
