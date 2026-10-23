# Сборка Android 1.0.2

Архив Viora-Android-1.0.2-source.zip содержит соответствующие Android-исходники:
Flutter-клиент, тесты, Android runner, Java-интеграцию, AndroidLibXrayLite и vendor.
В нём нет пользовательских профилей, ключей подписи, баз и готового AAR.
Серверный адаптер и рабочий бот для сборки Android не требуются и в этот архив
не включены. Полный репозиторий доступен по тегу v1.0.2.

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

В apps/client выполни flutter pub get, flutter analyze --no-pub и
flutter test --no-pub. Для тестового APK — flutter build apk --debug.
Пути SDK/Flutter в android/local.properties локальные и не публикуются.

Подписанный выпуск создаёт scripts/build-android-release.ps1 с внешним
SigningDirectory, JavaHome, AndroidSdk, VersionName 1.0.2 и VersionCode 32.
InitializeKey применяй только для новой независимой подписи. Не заменяй
существующий ключ: другая подпись не сможет обновить официальную установку.
Секреты подписи должны оставаться вне репозитория. APK поставляется отдельно.

Для данного выпуска при недоступности официальных CDN использованы HTTPS-зеркала
Google Maven/Flutter и Go. Архив Go сверен с независимым официальным SHA-256.
Зеркало остаётся отдельной границей доверия; проверка TLS не отключалась.
