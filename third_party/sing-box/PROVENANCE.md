# sing-box для Windows VIORA

Используется самостоятельный официальный исполняемый файл sing-box 1.14.4
(стабильный выпуск `v1.14.4`), не файл из установленного Happ. Он запускается
защищённой службой с конфигурацией в stdin и управляет только Windows TUN.
Локальный SOCKS-транспорт предоставляется отдельным Xray.

- Выпуск: https://github.com/SagerNet/sing-box/releases/tag/v1.14.4
- Официальный архив: https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip
- SHA-256 архива, опубликованный в GitHub Release API:
  `99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df`.
- SHA-256 извлечённого `sing-box.exe`:
  `8f30682ee198855440d2a7fe070d5d3653793b2d01bb8c85eea88f93bbe7c8b9`.
- Исходники: https://codeload.github.com/SagerNet/sing-box/zip/refs/tags/v1.14.4
- SHA-256 сохранённого архива исходников:
  `9037718f85b67a004517c6a9190b98c68483de643f57c62eb6c889e01beae4bc`.
- Лицензия upstream: GNU GPL v3, полный текст сохранён в
  `apps/client/assets/licenses/sing-box-GPL-3.0.txt`.

Для сборки распакуйте Windows-архив в `toolchains/sing-box`, сохранив каталог
`sing-box-1.14.4-windows-amd64`. Сохраните архив исходников как
`toolchains/sing-box/sing-box-v1.14.4-source.zip`. Сборка и упаковка проверяют
закреплённые хеши. Движок не обновляется из приложения автоматически.

Документация схемы: https://sing-box.sagernet.org/configuration/inbound/tun/ ,
https://sing-box.sagernet.org/configuration/outbound/socks/ .
Проверка конфигурации выполняется только `check -c stdin`; она не считается
успешным тестом реального туннеля. Запуск `run -c stdin` выполняется только
при запросе пользователя на подключение VIORA.
