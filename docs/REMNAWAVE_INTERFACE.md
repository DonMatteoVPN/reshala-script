# Remnawave: публичный интерфейс Решалы

Этот файл описывает **официальный интерфейс** работы с Remnawave внутри Решалы:

- какие модули существуют,
- какие функции считаются точками входа (для меню/скриптов),
- как устроено меню и в каком порядке они вызываются.

Всё остальное (`_remna_*`) — внутренние хелперы.

---

## 1. Точка входа из главного меню

Главное меню (`reshala.sh`):

- Пункт `[4]`:

  ```bash
  4) run_module remnawave_menu show_remnawave_centre_menu
  ```

Это запускает центральное Remnawave‑меню.

---

## 2. Центральное меню Remnawave

Модуль: `modules/remnawave_menu.sh`

Точка входа:

- `show_remnawave_centre_menu`

Пункты меню и делегирование:

1. **Установка компонентов Remnawave**  
   → `run_module remnawave_install show_remnawave_install_menu`

2. **Переустановить панель/ноду**  
   → `run_module remnawave_reinstall show_remnawave_reinstall_menu`

3. **Управление панелью/нодой**  
   → `run_module remnawave_manage show_remnawave_manage_menu`

4. **Установить случайный шаблон для selfsteal‑ноды**  
   → `run_module remnawave_templates show_remnawave_templates_menu`

5. **Кастомные подписки от Legiz**  
   → `run_module remnawave_legiz show_remnawave_legiz_menu`

6. **Управление сертификатами Remnawave**  
   → `run_module remnawave_certs show_remnawave_certs_menu`

---

## 3. Установка компонентов

Модуль: `modules/remnawave_install.sh`

Точка входа:

- `show_remnawave_install_menu`

Пункты меню:

1. **Панель + нода на один сервер**  
   → `run_module remnawave_panel_node _remna_install_panel_and_node_wizard`

2. **Только панель**  
   → `run_module remnawave_panel _remna_panel_install_wizard`

3. **Добавить НОДУ в уже существующую панель**  
   → `run_module remnawave_node _remna_node_add_to_panel_wizard`

4. **Только нода (локально под уже подготовленную панель)**  
   → `run_module remnawave_node _remna_node_install_local_wizard`

---

## 4. Переустановка

Модуль: `modules/remnawave_reinstall.sh`

Точка входа:

- `show_remnawave_reinstall_menu`

Пункты меню:

1. **Переустановить ПАНЕЛЬ и НОДУ на один сервер**  
   - Останавливает стек в `/opt/remnawave` (`docker compose down`).  
   - По желанию чистит `/opt/remnawave`.  
   - Затем: `run_module remnawave_panel_node _remna_install_panel_and_node_wizard`.

2. **Переустановить ТОЛЬКО ПАНЕЛЬ**  
   - Работает только с `/opt/remnawave`.  
   - Останавливает стек панели, опционально чистит каталог.  
   - Затем: `run_module remnawave_panel _remna_panel_install_wizard`.

3. **Переустановить ТОЛЬКО ЛОКАЛЬНУЮ НОДУ**  
   - Работает только с `/opt/remnanode`.  
   - Останавливает стек локальной ноды, опционально чистит каталог.  
   - Затем: `run_module remnawave_node _remna_node_install_local_wizard`.

---

## 5. Управление панелью и нодой

Модуль: `modules/remnawave_manage.sh`

Точка входа:

- `show_remnawave_manage_menu`

Пункты меню:

1. **Запустить панель/ноду**  
   - Выбор: панель (`/opt/remnawave`) или локальная нода (`/opt/remnanode`).  
   - `docker compose up -d` в выбранной директории.

2. **Остановить панель/ноду**  
   - `docker compose down` в выбранной директории.

3. **Обновить панель/ноду**  
   - `docker compose pull && docker compose up -d` в выбранной директории.

4. **Смотреть логи**  
   - Панель: `view_docker_logs /opt/remnawave/docker-compose.yml`.  
   - Нода: `view_docker_logs /opt/remnanode/docker-compose.yml`.

5. **Remnawave CLI (панель)**  
   - Shell внутри контейнера `remnawave`:  
     `cd /opt/remnawave && docker exec -it remnawave sh`.

6. **Подсказка по доступу через порт 8443**  
   - Скрипт сам ничего не пробрасывает, только даёт пример SSH‑туннеля:  
     `ssh -L 8443:127.0.0.1:3000 user@REMOTE_SERVER`.

---

## 6. Шаблоны маскировки

Модуль: `modules/remnawave_templates.sh`

Точка входа:

- `show_remnawave_templates_menu`

Пункты меню:

1. `Simple web templates (минималистичные сайты)`  
2. `SNI templates (набор масок под SNI)`  
3. `Nothing Sni templates (рандомные одиночные HTML)`

Для каждого пункта:

- Проверяется наличие `/opt/remnanode/tools/remask.sh`.
- Если скрипт есть, запускается:

  ```bash
  REMASK_SOURCE=simple|sni|nothing /opt/remnanode/tools/remask.sh
  ```

Маскировочный сайт обновляется в `/var/www/html`.

---

## 7. Legiz: кастомные подписки

Модуль: `modules/remnawave_legiz.sh`

Точка входа:

- `show_remnawave_legiz_menu`

Пункты меню:

1. **META_TITLE / META_DESCRIPTION страницы подписки**  
   - Читает текущие `META_TITLE` и `META_DESCRIPTION` из `/opt/remnawave/docker-compose.yml` (секция `remnawave-subscription-page`).  
   - Предлагает ввести новые значения.  
   - Обновляет compose и перезапускает:  
     `docker compose up -d remnawave-subscription-page remnawave-nginx`.

2. **Шаблоны страницы подписки от Legiz**  
   Запускает мастер `_remna_legiz_manage_sub_page_upload` и позволяет:
   - выбрать тип страницы:
     - простой `app-config` (simple custom app list: Clash/Sing),
     - multiapp‑вариант,
     - HWID‑вариант,
     - Orion‑страницу,
     - Material‑страницу,
     - Marzbanify‑страницу;
   - по желанию подключить отдельный `app-config.json` для выбранного шаблона;
   - при необходимости добавить блок брендирования (`.config.branding`) в `app-config.json`;
   - пересобрать volumes сервиса `remnawave-subscription-page` так, чтобы монтировать `index.html` и/или `app-config.json` внутрь контейнера;
   - перезапустить `remnawave-subscription-page` после изменения.

3. **Кастомный список приложений и брендирование (app-config.json)**  
   Запускает `_remna_legiz_manage_custom_app_list` и даёт:
   - отредактировать блок брендирования (название, логотип, ссылка поддержки) в `app-config.json`;
   - удалить выбранное приложение из списка для конкретной платформы;
   - после изменения конфигурации перезапускает `remnawave-subscription-page`.

---

## 8. Управление сертификатами

Модуль: `modules/remnawave_certs.sh`

Точка входа:

- `show_remnawave_certs_menu`

Пункты меню:

1. **Проверить домен (DNS/IP + Cloudflare)**  
   → `remna_check_domain`.

2. **Проверить наличие сертификата**  
   → `remna_check_certificates`.

3. **Посмотреть срок действия сертификата**  
   → `remna_check_cert_expiry` для указанного `fullchain.pem`.

Этот модуль так же используется **изнутри** установочных мастеров через функции:

- `remna_check_domain` для панелей/нод,
- `remna_handle_certificates` для выпуска сертификатов (Cloudflare DNS-01 / ACME HTTP-01),
- `remna_fix_letsencrypt_structure` для renew_hook и структуры `/etc/letsencrypt`.

---

## 9. Установочные мастера (внутренние, но публично вызываемые через меню)

Эти функции не вызываются напрямую пользователем, но являются основными потоками установки, на которые ссылаются меню.

### 9.1 Панель + нода на один сервер

Модуль: `modules/remnawave_panel_node.sh`

- `_remna_install_panel_and_node_wizard`

### 9.2 Только панель

Модуль: `modules/remnawave_panel.sh`

- `_remna_panel_install_wizard`

### 9.3 Только нода (локально)

Модуль: `modules/remnawave_node.sh`

- `_remna_node_install_local_wizard`

### 9.4 Добавить ноду в существующую панель

Модуль: `modules/remnawave_node.sh`

- `_remna_node_add_to_panel_wizard`

### 9.5 Нода через Skynet

Модуль: `modules/remnawave_node.sh`

- `_remna_node_install_skynet_one` — одна нода на выбранный сервер флота.
- `_remna_node_install_skynet_many` — массовая раздача нод на несколько серверов флота.

### 9.6 Привязка inbound к внутренним сквадам

Чтобы поведение соответствовало донору и при этом было управляемым, используется общий хелпер:

- `_remna_node_bind_inbound_with_choice(base_url, token, inbound_uuid)`  
  - Показывает оператору выбор:
    - «аккуратный» режим — привязать inbound только к одному внутреннему скваду по умолчанию;
    - «расширенный» режим — привязать inbound сразу ко всем внутренним сквадам панели.
  - В режиме «все сквады» под капотом вызывает `_remna_node_api_add_inbound_to_all_squads` (аналог донорского `add_node_to_panel`).  
  - В режиме «один сквад» использует `_remna_node_api_get_default_squad_uuid` + `_remna_node_api_add_inbound_to_squad`.

Этот хелпер вызывается из мастеров:

- `_remna_node_add_to_panel_wizard` (добавить ноду только в панель),
- `_remna_node_install_local_wizard` (локальная нода на этот сервер),
- `_remna_node_install_skynet_one` (одна нода через Skynet).

В массовом сценарии `_remna_node_install_skynet_many` режим выбирается один раз в начале (для всех нод),
после чего для каждого сервера вызывается либо `_remna_node_api_add_inbound_to_all_squads`, либо `_remna_node_api_add_inbound_to_squad`.

---

## 10. Правила развития Remnawave‑модулей

1. **Новые функции меню** добавляем только в перечисленные выше публичные модули и подвязываем их через `run_module`.
2. **Проверка доменов и работа с сертификатами**:
   - только через `modules/remnawave_certs.sh` (`remna_*` функции);
   - не дублировать локальные `check_domain`/`acme` в других скриптах.
3. **HTTP API Remnawave** вызывается через специализированные `_remna_*_api_*` хелперы в:
   - `remnawave_panel_node.sh`,
   - `remnawave_panel.sh`,
   - `remnawave_node.sh`.
4. Все новые сценарии установки/переустановки/управления должны быть реализованы как
   отдельные функции в существующих модулях и вызываться только через меню, описанные выше.
