# Сборка Android 1.1.1

Архив `Viora-1.1.1-source.zip` содержит соответствующие исходники выпуска:
Flutter-клиент, тесты, Android runner, Java-интеграцию, AndroidLibXrayLite и vendor.
В нём нет пользовательских профилей, ключей подписи, баз и готового AAR.
Рабочий бот и его базы не включены; общий серверный адаптер для сборки Android
не требуется. В архиве также сохранены overlay защиты сокетов и локальные
протокольные тесты. Публикация исходников не означает проверку удалённого VPN.

Требуются Flutter 3.35.5 / Dart 3.9.2, JDK 21, Android SDK 36,
NDK 27.0.12077973 и Go 1.27.3. Версии gomobile/gobind закреплены в
scripts/build-android-core.ps1. Дополнительные зависимости требуют сети;
сохраняй pubspec.lock, go.sum и проверку TLS.

На Windows передай реальные пути GoBin, MobileBin, JavaHome и AndroidSdk
скрипту build-android-core.ps1. Он создаёт artifacts/libv2ray-source-candidate.aar.
Затем fetch-android-core.ps1 сверяет закреплённый SHA-256 и копирует AAR в plugin.
Нативный движок нужно собрать до APK. Межмашинная побитовая воспроизводимость
не подтверждена: если намеренно меняешь исходники или инструменты, проверь
полученный AAR и обнови локальную контрольную сумму, не выдавая его за оригинал.
Происхождение: third_party/androidlibxraylite/VIORA-SOURCE.md и VIORA-CHANGES.md.
Скрипт создаёт временные копии Android bridge и закреплённого Xray, применяет
`patches/xray-android/system_dialer.go` через Go overlay и проверяет отказ
TCP/UDP при ошибке `VpnService.protect`. Общий кеш Go и исходные зависимости
не редактируются. Не удаляй overlay из архива соответствующих исходников.

В apps/client выполни flutter pub get, flutter analyze --no-pub и
flutter test --no-pub. Для тестового APK — flutter build apk --debug.
Пути SDK/Flutter в android/local.properties локальные и не публикуются.

Подписанный выпуск создаёт scripts/build-android-release.ps1 с внешним
SigningDirectory, JavaHome, AndroidSdk, VersionName 1.1.1 и VersionCode 41.
InitializeKey применяй только для новой независимой подписи. Не заменяй
существующий ключ: другая подпись не сможет обновить официальную установку.
Секреты подписи должны оставаться вне репозитория. APK поставляется отдельно.

Локальные протокольные проверки: `tests/android-protocols/run.py --go <go>
--dart <dart>`. Runner получает синтетические конфигурации из настоящих
VlessProfile/TunnelConfig и проверяет TCP/UDP через loopback, включая
Hysteria2/Salamander и отрицательные случаи TLS/авторизации. Он не создаёт
TUN и не меняет сеть компьютера. Java/Kotlin проверки запускаются задачами
`:app:testDebugUnitTest :flutter_v2ray_client:testDebugUnitTest`.

Для данного выпуска при недоступности официальных CDN использованы HTTPS-зеркала
Google Maven/Flutter и Go. Архив Go сверен с независимым официальным SHA-256.
Зеркало остаётся отдельной границей доверия; проверка TLS не отключалась.
