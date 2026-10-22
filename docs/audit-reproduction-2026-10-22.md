# Повтор проверок VIORA

Все команды запускаются на проверяемых исходниках, без рабочего бота и без подключения VPN. SDK: Flutter 3.35.5 / Dart 3.9.2, Go 1.27.2, Python 3.12; Windows C++ — VS 2026 с Windows SDK. На CI Ubuntu/Windows тесты запускаются отдельно; факт удалённого запуска CI данным файлом не подтверждается.

```powershell
# Из корня репозитория. Предпочтительно отдельный Python venv.
python -m pip install -r requirements-test.txt
python -m unittest discover -s tests -v

Set-Location apps/client
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
# Отдельные тестовые снимки, без настоящих native соединений:
flutter test --no-pub test/capture_updated_interface_test.dart --dart-define=VIORA_CAPTURE_UPDATED=true

Set-Location ../../desktop/tunnel
go test -json -count=1 ./...
go vet ./...
# На Windows это только cross-compile, не выполнение Linux tests:
$env:GOOS='linux'
go test -c -o ../../artifacts/linux-tunnel-tests .
go build -o ../../artifacts/viora_tunnel-linux .
Remove-Item Env:GOOS

Set-Location ../../third_party/androidlibxraylite
go test -mod=vendor -count=1 -timeout=60s -v .

Set-Location ../../desktop/windows/firewall
cmake -S . -B ../../../artifacts/firewall-audit -G 'Visual Studio 18 2026' -A x64
cmake --build ../../../artifacts/firewall-audit --config Release
ctest --test-dir ../../../artifacts/firewall-audit -C Release --output-on-failure
```

Не запускайте viora_firewall enable/disable/status для проверки сборки. CTest работает только с фильтрами в памяти. Тест установленной службы пропускается по умолчанию, собственные тестовые каналы IPC не являются рабочим VPN.

Для Windows Flutter 3.35.5 может выбрать несуществующий VS2019. После генерации конфигурации сборкой Flutter применён существующий документированный путь:

```powershell
# Из apps/client:
cmake -S windows -B build/windows/vs2026 -G 'Visual Studio 18 2026' -A x64 -DFLUTTER_TARGET_PLATFORM=windows-x64
cmake --build build/windows/vs2026 --config Release --target INSTALL
```

INSTALL здесь — CMake-копирование в локальную build-папку, не установка службы Windows. Одного EXE недостаточно: нужны data, DLL, helper и штатный установщик. При запуске с сохранёнными настройками возможен autoconnect, поэтому реальный старт приложения требует отдельной безопасной среды.

Android core: `scripts/build-android-core.ps1 -Offline` использует подготовленные закреплённые Go-модули и инструменты. Без полного кеша флаг Offline завершается ошибкой. Сетевая подготовка разрешает только версии из go.mod/go.sum; нельзя подменять проверки TLS или контрольные суммы для обхода ошибок кеша. После пересборки сначала проверяют источник, ABI/Java API, SHA-256 и pin `scripts/fetch-android-core.ps1`, затем собирают APK. Старый AAR сохранён отдельно для восстановления.

В аудите `flutter build apk --debug --no-pub` собирает проверочный APK без ключа выпуска. Он не был установлен на телефон. Сборка не заменяет проверку живого туннеля/утечек и не является новым подписанным публичным релизом.

Проверки до/после изменения реальной сети требуют выделенной VM/телефона и тестового сервера: сохранить исходные routes/DNS, сверить IPv4/IPv6/public IP и DNS до, во время, после; проверить crash, reconnect, reboot и смену интерфейса, затем восстановить исходные настройки. Эти шаги в текущем аудите не выполнялись и не могут считаться пройденными по результату unit tests.
