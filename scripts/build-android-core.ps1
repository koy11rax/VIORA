param(
    [string]$GoBin = "$env:USERPROFILE\.cache\viora-tools\go-toolchain\golang.org\toolchain@v0.0.1-go1.27.2.windows-amd64\bin",
    [string]$MobileBin = "$env:USERPROFILE\.cache\viora-tools\android-go-bin",
    [string]$JavaHome = 'D:\Android Studio\jbr',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$GoProxy = 'https://proxy.golang.org,direct',
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$OutputPath) { $OutputPath = "$repo\artifacts\libv2ray-source-candidate.aar" }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path (Split-Path $OutputPath -Parent) -Force | Out-Null
$names = @('PATH','GOTOOLCHAIN','GOBIN','GOPROXY','JAVA_HOME','ANDROID_HOME','ANDROID_NDK_HOME')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location "$repo\third_party\androidlibxraylite"
try {
    $env:PATH = "$JavaHome\bin;$GoBin;$MobileBin;" + $env:PATH
    $env:GOTOOLCHAIN = 'local'
    $env:GOBIN = $MobileBin
    $env:GOPROXY = $GoProxy
    $env:JAVA_HOME = $JavaHome
    $env:ANDROID_HOME = $AndroidSdk
    $env:ANDROID_NDK_HOME = "$AndroidSdk\ndk\27.0.12077973"
    if ((& go version) -notmatch 'go1\.27\.2 ') { throw 'The pinned Go 1.27.2 toolchain is required.' }
    $mobileVersion = 'v0.0.0-20260908204917-8b95e45f8d3e'
    foreach ($command in @('gomobile','gobind')) {
        & go install "golang.org/x/mobile/cmd/$command@$mobileVersion"
        if ($LASTEXITCODE -ne 0) { throw "Failed to install $command." }
    }
    & gomobile init
    if ($LASTEXITCODE -ne 0) { throw 'gomobile initialization failed.' }
    & gomobile bind '-target=android/arm64,android/arm,android/amd64' -androidapi 26 -trimpath '-ldflags=-s -w -buildid= -checklinkname=0' -o $OutputPath .
    if ($LASTEXITCODE -ne 0) { throw 'Android core source build failed.' }
    Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
} finally {
    Pop-Location
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
