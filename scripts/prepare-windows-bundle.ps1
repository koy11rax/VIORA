param(
    [Parameter(Mandatory=$true)][string]$BundlePath,
    [string]$OutputName = 'Viora-Windows-1.0.0',
    [string]$Version = '1.0.0'
)
$ErrorActionPreference = 'Stop'
$vioraRoot = Split-Path $PSScriptRoot -Parent
$vioraBundle = (Resolve-Path -LiteralPath $BundlePath).Path
$vioraOutput = Join-Path $vioraRoot ('artifacts\' + $OutputName)
if ($Version -notmatch '^\d+\.\d+\.\d+$' -or $OutputName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or (Test-Path -LiteralPath $vioraOutput)) { throw 'Invalid version or existing output directory' }
foreach ($file in @('viora_client.exe','flutter_windows.dll','data')) {
    if (!(Test-Path -LiteralPath (Join-Path $vioraBundle $file))) { throw "Missing $file" }
}
$vioraFrontend = Join-Path $vioraRoot 'artifacts\desktop-core\windows\sing-box.exe'
$vioraFrontendHash = '8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9'
$vioraFrontendLicense = Join-Path $vioraRoot 'apps\client\assets\licenses\sing-box-GPL-3.0.txt'
if (!(Test-Path -LiteralPath $vioraFrontend -PathType Leaf) -or (Get-FileHash -LiteralPath $vioraFrontend).Hash.ToLowerInvariant() -ne $vioraFrontendHash) {
    throw 'Missing or modified official sing-box 1.14.4 frontend; rebuild the trusted Windows core bundle'
}
if (!(Test-Path -LiteralPath $vioraFrontendLicense -PathType Leaf)) { throw 'Missing sing-box GPL license notice' }
New-Item -ItemType Directory -Path $vioraOutput | Out-Null
Copy-Item -LiteralPath (Join-Path $vioraBundle 'viora_client.exe') -Destination (Join-Path $vioraOutput 'Viora.exe')
Get-ChildItem -LiteralPath $vioraBundle -Filter '*.dll' -File | Copy-Item -Destination $vioraOutput
Copy-Item -LiteralPath (Join-Path $vioraBundle 'data') -Destination $vioraOutput -Recurse
Copy-Item -LiteralPath (Join-Path $vioraRoot 'artifacts\desktop-core\windows\viora_tunnel.exe') -Destination $vioraOutput
Copy-Item -LiteralPath (Join-Path $vioraRoot 'artifacts\desktop-core\windows\viora_firewall.exe') -Destination $vioraOutput
$vioraCore = Join-Path $vioraOutput 'core'
New-Item -ItemType Directory -Path $vioraCore | Out-Null
Copy-Item -LiteralPath (Join-Path $vioraRoot 'artifacts\desktop-core\windows\xray.exe') -Destination $vioraCore
$vioraCopiedFrontend = Join-Path $vioraCore 'sing-box.exe'
Copy-Item -LiteralPath $vioraFrontend -Destination $vioraCopiedFrontend
if ((Get-FileHash -LiteralPath $vioraCopiedFrontend).Hash.ToLowerInvariant() -ne $vioraFrontendHash) { throw 'Frontend bundle copy integrity mismatch' }
Copy-Item -LiteralPath (Join-Path $vioraRoot 'toolchains\wintun\wintun\bin\amd64\wintun.dll') -Destination $vioraCore
# Redistributable application-local CRT avoids another installer or reboot.
$vioraCrt = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Redist\MSVC\14.51.36231\x64\Microsoft.VC145.CRT'
foreach ($name in @('msvcp140.dll','msvcp140_1.dll','msvcp140_2.dll','vcruntime140.dll','vcruntime140_1.dll','concrt140.dll')) {
    Copy-Item -LiteralPath (Join-Path $vioraCrt $name) -Destination $vioraOutput
}
$vioraLicenses = Join-Path $vioraOutput 'licenses'
New-Item -ItemType Directory -Path $vioraLicenses | Out-Null
Copy-Item -LiteralPath (Join-Path $vioraRoot 'toolchains\xray-main\Xray-core-701af60772cda123492f86e383e1fdba066614a9\LICENSE') -Destination (Join-Path $vioraLicenses 'Xray-MPL-2.0.txt')
Copy-Item -LiteralPath (Join-Path $vioraRoot 'toolchains\wintun\wintun\LICENSE.txt') -Destination (Join-Path $vioraLicenses 'Wintun-LICENSE.txt')
Copy-Item -LiteralPath $vioraFrontendLicense -Destination (Join-Path $vioraLicenses 'sing-box-GPL-3.0.txt')
$vioraFrontendSource=Join-Path $vioraRoot 'toolchains\sing-box\sing-box-v1.14.4-source.zip'
if ((Get-FileHash -LiteralPath $vioraFrontendSource).Hash.ToLowerInvariant() -ne '9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc') { throw 'Expected pinned sing-box source archive' }
Copy-Item -LiteralPath $vioraFrontendSource -Destination (Join-Path $vioraLicenses 'sing-box-1.14.4-source.zip')
Copy-Item -LiteralPath (Join-Path $vioraRoot 'third_party\sing-box\PROVENANCE.md') -Destination (Join-Path $vioraLicenses 'sing-box-PROVENANCE.md')
@"
VIORA Windows $Version

Запусти установщик ${OutputName}-Setup.exe. Он позволяет выбрать папку
приложения и один раз устанавливает защищённую службу VPN. При последующих
подключениях и смене серверов повторный запрос администратора не требуется.

Крестик сворачивает VIORA в трей. В меню значка доступны подключение,
отключение, выбор сервера, обновление подписки, пинг и настройки.
Полный выход выполняется через пункт «Выйти из VIORA» и останавливает VPN.
В трее доступны время, общий трафик и текущая скорость соединения.

В разделе «Приложения» выбери программы для VPN или прямого подключения.
Если программы нет в списке, добавь её EXE-файл. Выбор можно перенести через
буфер обмена. Для другого компьютера проверь пути исполняемых файлов.
DNS обрабатывается внутри VPN; при обычном режиме используется HTTPS.
IPv6 блокируется. Постоянную системную блокировку можно включить в настройках
защиты. Она сохраняется после выхода и перезагрузки; прямые исключения
блокируются. Выключи её в настройках, чтобы вернуть интернет без VPN.

Аккаунт Telegram, подписка, продление, устройства и административный кабинет
работают через тот же сервис, что и Android. Права администратора проверяет
сервер. Настройки и зашифрованные данные аккаунта сохраняются при обновлении.
Текущая привязка HWID не изменена.

Результаты проверок конкретной сборки смотри в примечаниях к выпуску.
Если устройство отвязано в боте, разреши существующий HWID и обнови подписку.
Подпись издателя для EXE/MSI
не настроена; Windows может показывать предупреждение SmartScreen.

Xray (MPL-2.0): https://github.com/XTLS/Xray-core/tree/701af60772cda123492f86e383e1fdba066614a9
sing-box 1.14.4 (GPL-3.0): https://github.com/SagerNet/sing-box/tree/v1.14.4
Исходники sing-box включены в исходный архив VIORA; это отдельный TUN-компонент.
Wintun 0.14.1: https://www.wintun.net/ (официальный подписанный драйвер)
sing-box 1.14.4 (GPL-3.0): https://github.com/SagerNet/sing-box/tree/v1.14.4
Исходники и лицензия sing-box приложены в папке licenses.
"@ | Set-Content -LiteralPath (Join-Path $vioraOutput 'READ-ME.txt') -Encoding utf8
Get-Item -LiteralPath $vioraOutput
