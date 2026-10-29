param([Parameter(Mandatory=$true)][string]$GoDirectory,
      [ValidateSet('windows','linux')][string[]]$Platforms = @('windows','linux'),
      [switch]$SkipTests)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$go=Join-Path (Resolve-Path -LiteralPath $GoDirectory).Path 'go.exe'
if ((& $go version) -notmatch 'go1\.27\.3 windows/amd64') { throw 'Use the verified Go 1.27.3 Windows amd64 toolchain' }
$commit='701af60772cda123492f86e383e1fdba066614a9'
$source=Join-Path $root "toolchains\xray-main\Xray-core-$commit"
if (!(Test-Path -LiteralPath $source)) { throw "Fetch the unmodified Xray source at $commit before building" }
$upstreamWebsocket=Join-Path $source 'transport\internet\websocket\dialer.go'
$upstreamWebsocketHash='247b1512b2c868f7766a7f40dca88ab69ce248ddc5a58bd9ae57d06deaa01c56'
if ((Get-FileHash -LiteralPath $upstreamWebsocket).Hash.ToLowerInvariant() -ne $upstreamWebsocketHash) {
    throw 'Pinned Xray WebSocket source differs; inspect the base revision before applying the desktop overlay'
}
$patchedWebsocket=Join-Path $root 'patches\xray-desktop\websocket_dialer.go'
if (!(Test-Path -LiteralPath $patchedWebsocket -PathType Leaf)) { throw 'Missing tracked desktop WebSocket overlay' }
$upstreamSniff=Join-Path $source 'common\protocol\tls\sniff.go'
$upstreamSniffHash='75f4b79a0f98dda3a615ab1b34f202458a3ad68d76cd232c64f5b6cd8640426c'
if ((Get-FileHash -LiteralPath $upstreamSniff).Hash.ToLowerInvariant() -ne $upstreamSniffHash) {
    throw 'Pinned TLS sniffer source differs; inspect the base revision before applying the desktop overlay'
}
$patchedSniff=Join-Path $root 'patches\xray-desktop\tls_sniff.go'
if (!(Test-Path -LiteralPath $patchedSniff -PathType Leaf)) { throw 'Missing tracked desktop TLS sniffer overlay' }
$driver=Join-Path $root 'toolchains\wintun\wintun\bin\amd64\wintun.dll'
$driverHash='e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce'
if ($Platforms -contains 'windows') {
    if (!(Test-Path -LiteralPath $driver -PathType Leaf) -or (Get-FileHash -LiteralPath $driver).Hash.ToLowerInvariant() -ne $driverHash) {
        throw 'Expected official Wintun 0.14.1 amd64'
    }
}
$frontends=@{
    windows=@{Source='toolchains\sing-box\sing-box-1.14.4-windows-amd64\sing-box.exe'; Hash='8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9'; Name='sing-box.exe'}
    linux=@{Source='artifacts\desktop-core\linux\sing-box'; Hash='c555912d5dfe2a1dc541666bf4c404a13a7630a711898ceb1a7482e07b0b4032'; Name='sing-box'}
}
foreach ($platform in $Platforms) {
    $frontendSource=Join-Path $root $frontends[$platform].Source
    if (!(Test-Path -LiteralPath $frontendSource -PathType Leaf) -or (Get-FileHash -LiteralPath $frontendSource).Hash.ToLowerInvariant() -ne $frontends[$platform].Hash) {
        throw "Expected the pinned sing-box $platform amd64 frontend; build the Linux frontend with scripts/build-linux-frontend.py first"
    }
}
$env:CGO_ENABLED='0'; $env:GOARCH='amd64'
$env:PATH=$GoDirectory+';'+$env:PATH
$overlay=New-TemporaryFile
try {
    $mapping=@{Replace=@{$upstreamWebsocket=$patchedWebsocket; $upstreamSniff=$patchedSniff}} | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($overlay.FullName,$mapping,[System.Text.UTF8Encoding]::new($false))
    if (!$SkipTests) {
        $env:GOOS='windows'
        Push-Location (Join-Path $root 'tests\xray-websocket')
        try {
            & $go test -mod=readonly -overlay $overlay.FullName -count=1 -run '^TestPinned' ./...
            if ($LASTEXITCODE -ne 0) { throw 'Desktop WebSocket overlay regressions failed' }
        } finally { Pop-Location }
    }
    foreach ($platform in $Platforms) {
        $env:GOOS=$platform
        $output=Join-Path $root "artifacts\desktop-core\$platform"
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $frontendSource=Join-Path $root $frontends[$platform].Source
        $frontendHash=$frontends[$platform].Hash
        $frontend=Join-Path $output $frontends[$platform].Name
        if (!(Test-Path -LiteralPath $frontend) -or (Get-FileHash -LiteralPath $frontend).Hash.ToLowerInvariant() -ne $frontendHash) {
            Copy-Item -LiteralPath $frontendSource -Destination $frontend
        }
        if ((Get-FileHash -LiteralPath $frontend).Hash.ToLowerInvariant() -ne $frontendHash) { throw 'Frontend copy integrity mismatch' }
        $suffix=if ($platform -eq 'windows') { '.exe' } else { '' }
        $core=Join-Path $output ('xray'+$suffix)
        Push-Location $source
        try { & $go build -mod=readonly -buildvcs=false -overlay $overlay.FullName -trimpath -ldflags '-s -w' -o $core ./main; if ($LASTEXITCODE -ne 0) { throw 'Xray build failed' } } finally { Pop-Location }
        $coreHash=(Get-FileHash -LiteralPath $core).Hash.ToLowerInvariant()
        $flags="-s -w -X main.coreSHA=$coreHash -X main.frontendSHA=$frontendHash"
        if ($platform -eq 'windows') {
          $firewall=Join-Path $output 'viora_firewall.exe'
          if (!(Test-Path -LiteralPath $firewall)) { throw 'Build desktop/windows/firewall with CMake and copy viora_firewall.exe into artifacts/desktop-core/windows first' }
          $firewallHash=(Get-FileHash -LiteralPath $firewall).Hash.ToLowerInvariant()
          $flags+=" -H windowsgui -X main.driverSHA=$driverHash -X main.firewallSHA=$firewallHash"
        }
        Push-Location (Join-Path $root 'desktop\tunnel')
        try { & $go build -mod=readonly -buildvcs=false -trimpath -ldflags $flags -o (Join-Path $output ('viora_tunnel'+$suffix)) .; if ($LASTEXITCODE -ne 0) { throw 'Helper build failed' } } finally { Pop-Location }
    }
    if ($SkipTests) { Write-Output 'Native build completed; runtime tests were not run.'; return }
    $env:GOOS='windows'
    $env:VIORA_TEST_CORE=Join-Path $root 'artifacts\desktop-core\windows\xray.exe'
    Push-Location (Join-Path $root 'desktop\tunnel')
    try { & $go test ./...; if ($LASTEXITCODE -ne 0) { throw 'Helper tests failed' } } finally { Pop-Location }
} finally {
    Remove-Item -LiteralPath $overlay.FullName -Force
}
