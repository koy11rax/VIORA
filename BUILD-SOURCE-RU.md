# Сборка VIORA Desktop 0.8.2

Исходники относятся к Windows и Linux. Серверная часть, аккаунты пользователей,
подписки, базы, SSH-ключи, ключи подписи и локальные настройки SDK не включены.
Android APK 0.7.4 остаётся отдельным неизменённым выпуском.

## Инструменты

Flutter 3.35.5 / Dart 3.9.2, Go 1.27.2; Windows — Visual Studio с C++ и Windows SDK;
Linux — clang, cmake, ninja, pkg-config, GTK 3, libsecret и
libayatana-appindicator3 development packages. Linux-сборка выполнена на Ubuntu 22.04.

Закреплённый Xray: 701af60772cda123492f86e383e1fdba066614a9, MPL-2.0.
Архив исходников находится в toolchains/xray-main/source.zip; распакуй его в
toolchains/xray-main, сохранив исходное имя каталога Xray-core-<commit>.
Официальный Wintun 0.14.1 поставляется отдельным архивом с лицензией:
распакуй toolchains/wintun-0.14.1.zip в toolchains/wintun.

## Windows

1. В apps/client выполни flutter pub get, flutter analyze --no-pub.
2. Собери ядро/помощник скриптом scripts/build-desktop-core.ps1 с параметрами
   GoDirectory, Platforms windows. Параметр SkipTests отключает проверки запуска
   движка. Для официального Go proxy при необходимости используй настроенный
   GOPROXY; проверка go.sum должна оставаться включённой.
3. Собери Flutter windows --release --build-name 0.8.2 --build-number 27.
   Flutter 3.35.5 не выбирает Visual Studio 18 2026 автоматически. На таком хосте
   после генерации Flutter-метаданных используй CMake с генератором
   Visual Studio 18 2026 и параметром FLUTTER_TARGET_PLATFORM=windows-x64.
   Задай отдельный CMAKE_INSTALL_PREFIX для комплекта. Перед target INSTALL
   создай apps/client/build/native_assets/windows, если он отсутствует.
4. scripts/prepare-windows-bundle.ps1 формирует комплект, затем
   scripts/build-windows-msi.ps1 создаёт MSI. Передай версию 0.8.2 и уникальное
   имя выходного комплекта. Пути локального CRT в скрипте требуют адаптации
   под установленный Visual Studio.
5. desktop/windows/setup/CMakeLists.txt создаёт EXE из MSI. Параметры:
   VIORA_MSI, VIORA_ICON и VIORA_VERSION=0.8.2. EXE/MSI не подписаны издателем.
   scripts/verify-windows-msi.ps1 проверяет содержимое без установки и VPN.

## Linux

1. Собери native core/helper с Platforms linux на Windows либо эквивалентными
   Go-командами. Хеш ядра передаётся помощнику через main.coreSHA; root-owned
   помощник проверяет бинарник перед запуском.
2. scripts/build-linux.sh собирает UI и `.deb`. Передай VIORA_VERSION=0.8.2;
   VIORA_SKIP_TESTS=1 отключает тесты. Сам скрипт сборки не подключает VPN.
3. Пакет устанавливается пользователем через apt install ./<пакет>.deb.
   Во время этой разработки установка на основной машине не выполнялась.

### Fedora RPM и Arch pacman

`scripts/package-linux-variants.sh` принимает проверенный DEB как источник
того же бинарного Linux-комплекта и формирует native RPM и пакет pacman.
Нужны dpkg-deb, rpmbuild, makepkg, fakeroot, bsdtar и zstd. Сборку пакетов
выполняй обычным пользователем. Скрипт проверяет SHA-256 исходного DEB,
не устанавливает VIORA, не запускает интерфейс или VPN и не изменяет сеть.

RPM использует `desktop/linux/viora.spec.in`, Arch — `desktop/linux/PKGBUILD.in`.
Отключено изменение бинарников/strip: иначе нарушится хеш ядра, встроенный
в привилегированный помощник. Готовый рецепт Arch включает точный бинарный
архив и SHA-256; тот же архив Source0 подходит к предоставленному RPM spec.
После упаковки `scripts/verify-linux-variants.py` сравнивает каждый файл
и его режим доступа, проверяет владельцев root:root, метаданные и отсутствие
установочных скриптов. Приложение при этом не запускается.

Пакеты подготовлены на Ubuntu 22.04: RPM 4.17.0, makepkg/pacman 6.0.0
(собран из https://sources.archlinux.org/other/pacman/ с проверкой официального
SHA-256). Это упаковка общего Linux-бинарника, а не отдельная компиляция
в Fedora/Arch. Проверка реальной работы в этих дистрибутивах ещё не проведена.

Доступ к серверам и рабочее соединение не проверены по поручению владельца.
Не выдавай факт сборки за проверку маршрутов, утечек или защиты при обрыве.

## Компонент Windows WFP

Перед Go-сборкой скомпилируй desktop/windows/firewall через CMake (Visual Studio x64, Release). Скопируй viora_firewall.exe в artifacts/desktop-core/windows. Скрипт Go встраивает SHA-256 этого файла в привилегированную службу. Компонент связан со статическим CRT и Windows SDK; сборка не активирует фильтры. Не запускай enable/disable/status на рабочей системе при проверке сборки.

Linux-пакеты добавляют nftables, ранний systemd unit, зависимости NetworkManager/networkd и снятие только правил VIORA при полном удалении. Обновление не снимает защиту. Первое включение возможно только по действию пользователя в настройках.

Справка: https://learn.microsoft.com/en-us/windows/win32/fwp/object-management , https://learn.microsoft.com/en-us/windows/win32/fwp/permitting-and-blocking-applications-and-users , https://wiki.nftables.org/wiki-nftables/index.php/Quick_reference-nftables_in_10_minutes .
