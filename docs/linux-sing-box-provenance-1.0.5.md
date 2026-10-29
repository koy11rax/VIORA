# sing-box в VIORA Linux 1.0.5

Используется отдельный Linux amd64 компонент **sing-box 1.14.4-viora.1**, собранный
VIORA из закреплённых исходников upstream v1.14.4 с опубликованным исправлением.
Это **не неизменённый официальный Linux binary**. Компонент создаёт системный
TUN; Xray предоставляет VLESS-транспорт через локальный SOCKS с временным паролем.
Исполняемый файл не берётся из Happ. Официальная Windows-сборка не изменяется.

- Официальный выпуск: https://github.com/SagerNet/sing-box/releases/tag/v1.14.4
- SHA-256 выпускаемого Linux `sing-box` (36 036 768 байт):
  `c555912d5dfe2a1dc541666bf4c404a13a7630a711898ceb1a7482e07b0b4032`.
- Архив исходников: https://codeload.github.com/SagerNet/sing-box/zip/refs/tags/v1.14.4
- SHA-256 исходников:
  `9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc`.

## Опубликованное изменение VIORA

Изменён один файл upstream: `route/process_cache.go`. После промаха кэшированного
списка интерфейсов Linux проверяет текущие локальные адреса через
`net.InterfaceAddrs`. Сравнивается точный IP. Ошибка чтения не разрешает
неизвестный источник. Это восстанавливает попытку kernel socket-owner lookup
после переподключений; выбор программ и guard неизвестного процесса сохраняются.
Сетевые маршруты, TLS и привилегии этим overlay не ослабляются.

Изменение внесено VIORA **29.10.2026**. Файлы overlay лицензируются как
GPL-3.0-or-later согласно upstream. Исходный файл не перезаписывается: сборщик
использует Go overlay и проверяет хеш оригинала до сборки.

| Вход сборки | SHA-256 |
| --- | --- |
| Оригинальный `route/process_cache.go` | `7ebba50b44a1f8ee12430ee0ebd085c5c78cd751b15407746d282acf595c4263` |
| Изменённый `process_cache.go` | `b418d8cbb9f19b1e02094421de778db61b3b9b13c6cbc95b0f803f0a324eeaa6` |
| `process_cache_test.go` | `f4f0458e2052d2f21a9d87c9c82459b8a4705ba1b7095599b85b4ebdbd8d5590` |

Хеши Go-файлов относятся к тексту с LF. Полный манифест входов, README,
сборщика и результата — `docs/linux-frontend-source-pins-1.0.5.json` в исходниках,
либо `licenses/sing-box-viora/SOURCE-PINS.json` установленного пакета.

## Повторная сборка

Нужен **Go 1.27.3**, `GOOS=linux`, `GOARCH=amd64`, `CGO_ENABLED=0`, без optional
build tags. В клиентском source ZIP сохранена нужная структура:

```sh
python3 scripts/build-linux-frontend.py --go /путь/к/go --test-binary
```

Сборщик проверяет базовый архив, его развёрнутые файлы, исходный файл и overlay,
сохраняет `go.mod`/`go.sum` в readonly-режиме с проверкой module checksums.
Результат — `artifacts/desktop-core/linux/sing-box`. Чистые regression tests
компилируются отдельно; их запуск на Linux:

```sh
./artifacts/desktop-core/linux/sing-box-local-source.test -test.run '^TestViora'
```

Эти тесты используют переданные адреса и не открывают сокеты. Сборка может
загружать зависимости Go, но не включает VPN и не меняет маршруты.

Лицензия upstream — GNU GPL v3 или более поздняя. Полный текст, неизменённое уведомление upstream
и точный архив исходников включаются в `/usr/lib/viora/licenses` каждого пакета:
`COPYING-sing-box-GPL-3.0.txt`, `sing-box-GPL-3.0.txt` и
`sing-box-1.14.4-source.zip`. Файл `sing-box-PROVENANCE.md` описывает происхождение.
В подпапке `sing-box-viora` находятся `process_cache.go`, `process_cache_test.go`,
`README.md`, `build-linux-frontend.py` и `SOURCE-PINS.json`.
Чтобы собрать только из файлов установленного пакета, скопируй builder в
`scripts/`, overlay/тест/README — в `patches/sing-box-desktop/`, а базовый архив —
в `toolchains/sing-box/sing-box-v1.14.4-source.zip` отдельного рабочего каталога.

Сборщик и упаковщик проверяют закреплённые хеши. Привилегированный помощник
проверяет файл перед запуском. Автоматическая замена движка из сети не добавлена.
Конфигурация с секретами передаётся через stdin, без сохранения на диск.

Режим `check -c stdin` проверяет схему конфигурации и не подтверждает передачу
трафика, маршруты, DNS или защиту от утечек. Результаты фактически выполненных
проверок должны приводиться отдельно в примечаниях к Linux-выпуску.
