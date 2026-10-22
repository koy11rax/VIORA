$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$destination = "$repo\third_party\flutter_v2ray_client\android\libs\libv2ray.aar"
$expectedAar = '92bb2f7dc8129b02c3f2de947e97395474a5ccc057a9aaec5edf37f8f35677cc'
if (Test-Path -LiteralPath $destination) {
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedAar) { throw 'Android core hash mismatch.' }
    Write-Output 'Pinned source-built Android core verified.'
    return
}
$candidate = "$repo\artifacts\libv2ray-source-candidate.aar"
if (!(Test-Path -LiteralPath $candidate)) { throw 'Build the Android core from source with scripts/build-android-core.ps1 first.' }
if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedAar) { throw 'Source-built Android core hash mismatch. Review toolchain/source before changing the pin.' }
New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
Copy-Item -LiteralPath $candidate -Destination $destination
Write-Output 'Pinned source-built Android core prepared.'
