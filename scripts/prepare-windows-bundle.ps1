param(
    [Parameter(Mandatory=$true)][string]$BundlePath,
    [string]$OutputName = 'Viora-Windows-1.0.0'
)
$ErrorActionPreference = 'Stop'
$vioraRoot = Split-Path $PSScriptRoot -Parent
$vioraBundle = (Resolve-Path -LiteralPath $BundlePath).Path
$vioraOutput = Join-Path $vioraRoot ('artifacts\' + $OutputName)
if ($OutputName -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or (Test-Path -LiteralPath $vioraOutput)) { throw 'Invalid or existing output directory' }
foreach ($file in @('viora_client.exe','flutter_windows.dll','data')) {
    if (!(Test-Path -LiteralPath (Join-Path $vioraBundle $file))) { throw "Missing $file" }
}
New-Item -ItemType Directory -Path $vioraOutput | Out-Null
Copy-Item -LiteralPath (Join-Path $vioraBundle 'viora_client.exe') -Destination (Join-Path $vioraOutput 'Viora.exe')
Get-ChildItem -LiteralPath $vioraBundle -Filter '*.dll' -File | Copy-Item -Destination $vioraOutput
Copy-Item -LiteralPath (Join-Path $vioraBundle 'data') -Destination $vioraOutput -Recurse
Copy-Item -LiteralPath (Join-Path $vioraRoot 'artifacts\desktop-core\windows\viora_tunnel.exe') -Destination $vioraOutput
Copy-Item -LiteralPath (Join-Path $vioraRoot 'artifacts\desktop-core\windows\viora_firewall.exe') -Destination $vioraOutput
$vioraCore = Join-Path $vioraOutput 'core'
New-Item -ItemType Directory -Path $vioraCore | Out-Null
Copy-Item -LiteralPath (Join-Path $vioraRoot 'artifacts\desktop-core\windows\xray.exe') -Destination $vioraCore
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
@'
VIORA Windows 1.0.0

Запусти установщик Viora-Windows-1.0.0-Setup.exe. Он позволяет выбрать папку
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

По просьбе владельца при подготовке этой версии VPN не запускался,
проверки реального соединения не выполнялись. Подпись издателя для EXE/MSI
не настроена; Windows может показывать предупреждение SmartScreen.

Xray (MPL-2.0): https://github.com/XTLS/Xray-core/tree/701af60772cda123492f86e383e1fdba066614a9
Wintun 0.14.1: https://www.wintun.net/ (официальный подписанный драйвер)
'@ | Set-Content -LiteralPath (Join-Path $vioraOutput 'READ-ME.txt') -Encoding utf8
Get-Item -LiteralPath $vioraOutput
