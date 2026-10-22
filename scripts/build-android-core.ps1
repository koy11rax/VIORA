param(
    [string]$GoBin = "$env:USERPROFILE\.cache\viora-tools\go1.27.3\go\bin",
    [string]$MobileBin = "$env:USERPROFILE\.cache\viora-tools\android-go-bin",
    [string]$JavaHome = 'D:\Android Studio\jbr',
    [string]$AndroidSdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$GoProxy = 'https://proxy.golang.org,direct',
    [string]$OutputPath = '',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (!$OutputPath) { $OutputPath = "$repo\artifacts\libv2ray-source-candidate.aar" }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path (Split-Path $OutputPath -Parent) -Force | Out-Null
$names = @('PATH','GOTOOLCHAIN','GOBIN','GOPROXY','GOSUMDB','GOFLAGS','JAVA_HOME','ANDROID_HOME','ANDROID_NDK_HOME')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
Push-Location "$repo\third_party\androidlibxraylite"
try {
    $env:PATH = "$JavaHome\bin;$GoBin;$MobileBin;" + $env:PATH
    $env:GOTOOLCHAIN = 'local'
    $env:GOBIN = $MobileBin
    $env:GOPROXY = if ($Offline) { 'off' } else { $GoProxy }
    $env:GOSUMDB = if ($Offline) { 'off' } else { 'sum.golang.org' }
    # Runtime vendor omits gomobile's generator packages. Resolve the pinned
    # graph and recorded checksums, without editing go.mod during a build.
    $env:GOFLAGS = '-mod=readonly'
    $env:JAVA_HOME = $JavaHome
    $env:ANDROID_HOME = $AndroidSdk
    $env:ANDROID_NDK_HOME = "$AndroidSdk\ndk\27.0.12077973"
    if ((& go version) -notmatch 'go1\.27\.3 ') { throw 'The pinned Go 1.27.3 toolchain is required.' }
    $mobileVersion = 'v0.0.0-20260908204917-8b95e45f8d3e'
    foreach ($command in @('gomobile','gobind')) {
        $installed = Join-Path $MobileBin ($command + '.exe')
        if (Test-Path -LiteralPath $installed) {
            $metadata = (& go version -m $installed 2>&1) -join "`n"
            $modulePin = '(?m)^\s*mod\s+golang\.org/x/mobile\s+' + [Regex]::Escape($mobileVersion) + '\s'
            if ($LASTEXITCODE -eq 0 -and $metadata -match $modulePin) { continue }
        }
        if ($Offline) { throw "Offline build requires $command from the pinned x/mobile version $mobileVersion." }
        & go install "golang.org/x/mobile/cmd/$command@$mobileVersion"
        if ($LASTEXITCODE -ne 0) { throw "Failed to install $command." }
    }
    # `gomobile init` internally installs gobind@latest even after a pinned
    # installation. This project does not use its optional OpenAL preparation;
    # bind only requires the work directory and the pinned tools checked above.
    $goPaths = (& go env GOPATH) -split [IO.Path]::PathSeparator
    if ($LASTEXITCODE -ne 0 -or !$goPaths[0]) { throw 'Go workspace path is unavailable.' }
    New-Item -ItemType Directory -Path (Join-Path $goPaths[0] 'pkg/gomobile') -Force | Out-Null
    # gomobile currently hides a failed module-graph query and may then emit an
    # empty temporary go.mod. Surface cache/checksum errors before compilation.
    & go list -m all | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The pinned module graph is unavailable. Restore its verified cache before an offline build.' }
    & gomobile bind '-target=android/arm64,android/arm,android/amd64' -androidapi 26 -trimpath '-ldflags=-s -w -buildid= -checklinkname=0' -o $OutputPath .
    if ($LASTEXITCODE -ne 0) { throw 'Android core source build failed.' }
    Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256
} finally {
    Pop-Location
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
