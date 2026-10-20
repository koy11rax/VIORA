param([Parameter(Mandatory=$true)][string]$GoDirectory,
      [ValidateSet('windows','linux')][string[]]$Platforms = @('windows','linux'),
      [switch]$SkipTests)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$go=Join-Path (Resolve-Path -LiteralPath $GoDirectory).Path 'go.exe'
if ((& $go version) -notmatch 'go1\.27\.2 windows/amd64') { throw 'Use the verified Go 1.27.2 Windows amd64 toolchain' }
$commit='701af60772cda123492f86e383e1fdba066614a9'
$source=Join-Path $root "toolchains\xray-main\Xray-core-$commit"
if (!(Test-Path -LiteralPath $source)) { throw "Fetch the unmodified Xray source at $commit before building" }
$driver=Join-Path $root 'toolchains\wintun\wintun\bin\amd64\wintun.dll'
$driverHash='e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce'
if ((Get-FileHash -LiteralPath $driver).Hash.ToLowerInvariant() -ne $driverHash) { throw 'Expected official Wintun 0.14.1 amd64' }
$env:CGO_ENABLED='0'; $env:GOARCH='amd64'
$env:PATH=$GoDirectory+';'+$env:PATH
foreach ($platform in $Platforms) {
    $env:GOOS=$platform
    $output=Join-Path $root "artifacts\desktop-core\$platform"
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $suffix=if ($platform -eq 'windows') { '.exe' } else { '' }
    $core=Join-Path $output ('xray'+$suffix)
    Push-Location $source
    try { & $go build -trimpath -ldflags '-s -w' -o $core ./main; if ($LASTEXITCODE -ne 0) { throw 'Xray build failed' } } finally { Pop-Location }
    $coreHash=(Get-FileHash -LiteralPath $core).Hash.ToLowerInvariant()
    $flags="-s -w -X main.coreSHA=$coreHash"
    if ($platform -eq 'windows') {
      $firewall=Join-Path $output 'viora_firewall.exe'
      if (!(Test-Path -LiteralPath $firewall)) { throw 'Build desktop/windows/firewall with CMake and copy viora_firewall.exe into artifacts/desktop-core/windows first' }
      $firewallHash=(Get-FileHash -LiteralPath $firewall).Hash.ToLowerInvariant()
      $flags+=" -H windowsgui -X main.driverSHA=$driverHash -X main.firewallSHA=$firewallHash"
    }
    Push-Location (Join-Path $root 'desktop\tunnel')
    try { & $go build -trimpath -ldflags $flags -o (Join-Path $output ('viora_tunnel'+$suffix)) .; if ($LASTEXITCODE -ne 0) { throw 'Helper build failed' } } finally { Pop-Location }
}
if ($SkipTests) { Write-Output 'Native build completed; runtime tests were not run.'; return }
$env:GOOS='windows'
$env:VIORA_TEST_CORE=Join-Path $root 'artifacts\desktop-core\windows\xray.exe'
Push-Location (Join-Path $root 'desktop\tunnel')
try { & $go test ./...; if ($LASTEXITCODE -ne 0) { throw 'Helper tests failed' } } finally { Pop-Location }
