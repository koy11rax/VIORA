# Linux: актуальные локальные адреса при поиске процесса

База: sing-box **v1.14.4**, файл
[`route/process_cache.go`](https://github.com/SagerNet/sing-box/blob/v1.14.4/route/process_cache.go).
Лицензия upstream и этого изменённого файла: GPL-3.0-or-later, согласно лицензии
sing-box. Изменение VIORA от 29.10.2026 применяется **только при сборке Linux**;
официальный Windows binary этим overlay не изменяется.

Причина подтверждена в отдельной VM: после переподключений свежий `viora0` с
`172.29.255.1` отсутствовал в кэшированном InterfaceFinder. `isLocalSource`
молча пропускал kernel process lookup. При строгой защите и кэшированном DNS
приложений это делало неопределёнными владельцев TCP-соединений. Guard VIORA
правильно блокировал такие соединения, но вместе с ними и разрешённые программы.

Изменение оставляет cached/platform/loopback fast paths. Только после промаха
читаются текущие адреса ядра через `net.InterfaceAddrs`. Сравнивается **точный IP**,
а не принадлежность подсети. Ошибка чтения не разрешает неизвестный источник.
Это разрешает лишь попытку kernel socket-owner lookup: process path всё ещё
проверяется обычными правилами, а неизвестный процесс блокируется guard.
Маршруты, сертификаты, права и фильтры сети не ослабляются.

Перед сборкой нужно проверить SHA-256 оригинального файла. `go -overlay`
сопоставляет оригинальный абсолютный путь `route/process_cache.go` с этим
`process_cache.go`. Для проверки дополнительно сопоставляется новый виртуальный
`route/viora_process_cache_test.go` с `process_cache_test.go` из этого каталога.

```
go test -overlay overlay.json ./route -run '^TestViora' -count=1
```

Тесты не создают сокеты и не меняют сеть: адреса и ошибка чтения передаются
через private `isLocalSourceWith` seam. Production передаёт `net.InterfaceAddrs`.

| Файл | SHA-256 |
| --- | --- |
| Оригинал upstream | `7ebba50b44a1f8ee12430ee0ebd085c5c78cd751b15407746d282acf595c4263` |
| VIORA process_cache.go | `b418d8cbb9f19b1e02094421de778db61b3b9b13c6cbc95b0f803f0a324eeaa6` |
| process_cache_test.go | `f4f0458e2052d2f21a9d87c9c82459b8a4705ba1b7095599b85b4ebdbd8d5590` |
