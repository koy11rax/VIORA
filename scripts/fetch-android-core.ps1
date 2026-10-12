$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$destination = "$repo\third_party\flutter_v2ray_client\android\libs\libv2ray.aar"
$expectedAar = '87d921a767b604f1102295f7867cb0960ddd16f4a9d5cc084f1503fb74fc63d8'
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
