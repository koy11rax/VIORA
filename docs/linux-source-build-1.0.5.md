# Сборка VIORA Linux 1.0.5 (35)

Основа — общий клиент Windows 1.0.5, Flutter 3.35.5 / Dart 3.9.2.
Linux использует собственные polkit, iproute2, systemd-resolved и nftables.
Профили, аккаунты, существующий HWID и настройки не мигрируют на новый формат.

## Компоненты

- Go 1.27.3, `CGO_ENABLED=0`, Linux amd64.
- Xray: commit `701af60772cda123492f86e383e1fdba066614a9` и два проверяемых
  overlay из `patches/xray-desktop`. Пакеты и Go-модули закреплены.
- Отдельный sing-box 1.14.4-viora.1 Linux amd64, собранный из закреплённых
  исходников upstream с точечной поправкой определения локальных адресов.
  Его происхождение и хеши:
  [provenance](linux-sing-box-provenance-1.0.5.md).
- `main.coreSHA` и `main.frontendSHA` встраиваются при сборке помощника.
  Хеши не поступают из интерфейса. Windows Wintun и firewall EXE не нужны.

Скрипт `scripts/build-desktop-core.ps1 -GoDirectory <каталог Go bin>
-Platforms linux -SkipTests` выполняет перекрёстную сборку на Windows.
До запуска распакуйте закреплённый Xray source.zip в `toolchains/`, как указано
в [общей инструкции](desktop-source-build-1.0.0.md). Подготовьте точный архив
sing-box из provenance и выполните:

```sh
python scripts/build-linux-frontend.py --go <путь-к-Go-1.27.3> --test-binary
```

Этот скрипт проверяет весь распакованный source, базовый файл и overlay,
затем собирает Linux TUN-компонент без optional tags и компилирует регрессии.
Нужные функции system TUN, SOCKS, UDP/HTTPS DNS и sniff входят в default build.
Тестовый бинарник запускается на Linux с `-test.run '^TestViora'`.
`-SkipTests` в PowerShell-сборщике означает только сборку, без выполнения тестов.
Сборка использует `-trimpath -buildvcs=false` и `-mod=readonly`: локальный путь
и случайное состояние Git не подмешиваются в бинарник. Go toolchain и исходники
должны оставаться теми же; побайтовая воспроизводимость Flutter не заявляется.

## UI и установочные пакеты

На Linux нужны clang, cmake, ninja-build, pkg-config, GTK 3, libsecret,
liblzma и libayatana-appindicator development packages. Установите Flutter
3.35.5 и добавьте `flutter/bin` в PATH. Команды выполняются обычным пользователем:

```sh
export VIORA_VERSION=1.0.5 VIORA_BUILD_NUMBER=35
bash scripts/build-linux.sh
bash scripts/package-linux-variants.sh
python3 scripts/verify-linux-variants.py
python3 scripts/test-linux-package-preflight.py
```

Сборщик ожидает `artifacts/desktop-core/linux/{xray,sing-box,viora_tunnel}`
и точный `toolchains/sing-box/sing-box-v1.14.4-source.zip`. Файлы не должны
быть символическими ссылками. Существующий выходной каталог вызывает отказ; для повторной
сборки используйте отдельную чистую копию исходников и каталог артефактов.

Для RPM и pacman дополнительно требуются rpmbuild, makepkg, pacman,
fakeroot, bsdtar и zstd. Упаковщик не разрешает зависимости на Ubuntu от имени
Fedora/Arch. Менеджер пакетов целевой системы устанавливает их при установке.
Strip и изменение ELF отключены, чтобы не нарушить встроенные хеши.

В текущем выпуске один Linux x86_64 комплект собирается на Ubuntu 22.04,
затем одинаковые байты упаковываются в DEB/RPM/pacman. Это не отдельные
компиляции или проверки запуска в трёх дистрибутивах.

## Проверки

В `desktop/tunnel` выполняются `go test ./...` и `go vet ./...`.
Для проверок схем без запуска VPN задайте `VIORA_TEST_CORE` и
`VIORA_TEST_FRONTEND` абсолютными путями к Linux Xray и sing-box.
Для компиляции тестов на Windows: `GOOS=linux GOARCH=amd64 CGO_ENABLED=0
go test -c`; полученный файл запускается только в Linux.

Реальные проверки маршрутов, DNS, разделения приложений и аварийного завершения
описаны в [изолированном fixture](../tests/linux-bridge/README.md).
Этот тест предназначен только для отдельной одноразовой виртуальной машины:
он меняет сеть и временное доверие к своему локальному CA внутри гостя.
Он отказывается запускаться без явных ограничителей. На рабочей системе
не запускайте его. Успех fixture не заменяет проверку удалённого сервера,
смены Wi-Fi/Ethernet, suspend/resume или фактического окружения Fedora/Arch.

В составе всех пакетов есть полный GPL, уведомление и исходники sing-box.
Исходники VIORA поставляются отдельно как `Viora-Linux-1.0.5-source.zip`.
Секреты, личные профили, данные пользователей и ключи подписи туда не входят.
