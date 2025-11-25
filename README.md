<p align="right">[🇷🇺 RU](#ru) | [🇬🇧 EN](#en)</p>

<a name="ru"></a>

# Инструмент «Решала» 🚀 v2.0x (Skynet + Widgets)

![Лого Решалы](https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/assets/reshala-logo.jpg)

### ЧТО ЭТО ЗА ЗВЕРЬ?

Если ты устал ковыряться в консоли, копипастить команды из блокнота и гадать, почему сервер тупит — поздравляю, ты нашел «Решалу». Это швейцарский нож для твоего VPN/серверного хозяйства. Он делает за тебя всю грязную работу, пока ты пьёшь кофе.

Теперь с режимом **SKYNET** и **виджетами дашборда**. Ты больше не эникейщик, ты оператор системы.

---

### 🎛 ПРИБОРНАЯ ПАНЕЛЬ (DASHBOARD)

Как только ты запускаешь скрипт, ты видишь не скучный чёрный экран, а **пульт управления ядерным реактором**:
*   **Визуал:** Шкалы загрузки CPU, RAM и Диска. Сразу видно, где узкое место.
*   **Честная математика:** Скрипт может сделать замер скорости (официальный Ookla speedtest) и **посчитать, сколько реальных юзеров потянет твоя нода**. Без маркетинговой херни, с учётом железа и канала.
*   **Статус:** Версии ядра, виртуализация, пинг до мира, страна и состояние всех сервисов (Панель, Бот, Nginx).
*   **WIDGETS:** маленькие виджеты под панелью (курс BTC, состояние Docker, сетевой движ, «настроение сервера»), которые можно включать/выключать и кэшировать для минимальной нагрузки.

---

### 🌐 [0] SKYNET: УПРАВЛЕНИЕ ФЛОТОМ (NEW!)

**Главная фишка обновления.**
Больше не нужно заходить на каждый сервер отдельно.
*   **Единое окно:** Добавляешь IP всех своих серверов в базу ЦУПа.
*   **Телепортация:** Мгновенный вход на любой сервер. Скрипт сам прокинет ключи.
*   **Авто-захват:** Если на удаленном сервере нет скрипта — Skynet сам его туда поставит и запустит.
*   **Синхронизация:** Управляем всей сетью с одного экрана.

---

### 📂 РАЗБОР МЕНЮ: ЧТО ЖАТЬ?

#### [1] 🔧 СЕРВИСНОЕ МЕНЮ (Крутим гайки)
Тут лежит всё, что заставляет сервер летать.
*   **🚑 Лечение EOL / Обновление:** Оживляет старые Ubuntu, если зеркала шлют тебя нахер (404 Not Found).
*   **🚀 Форсаж (BBR + CAKE):** Кнопка «ТУРБО». Меняет алгоритмы TCP стека. Лагов меньше, скорость выше.
*   **🌐 Управление IPv6:** Кастрация или лечение лишнего протокола.
*   **⚡ Тест скорости до Москвы:** Используем официальный бинарник Ookla (не глючный python). Замеряем канал и выдаем вердикт по вместимости сервера.

#### [2] 📜 БЫСТРЫЕ ЛОГИ (Рентген)
Хватит писать `docker logs -f ...` вручную.
*   Жмёшь кнопку — видишь, чем дышит сам «Решала», Панель, Нода (Xray) или Бот (если они установлены).
*   Мгновенная диагностика проблем. Выход из просмотра — через `CTRL+C` (скрипт аккуратно возвращает в меню).

#### [3] 🐳 УПРАВЛЕНИЕ DOCKER (Мусорка + Инфо)
Докер любит жрать место, как не в себя.
*   Показывает самые жирные образы и состояние контейнеров.
*   Выносит мусор (кэш, старые контейнеры, висячие тома) одной кнопкой. Освобождает гигабайты.
*   Даёт удобное меню:
    * список контейнеров,
    * логи `docker logs -f` по имени,
    * старт/стоп/рестарт,
    * `docker inspect` и `docker stats --no-stream`,
    * управление сетями, томами и образами (с подтверждениями перед удалением).

#### [4] & [5] 💿 УСТАНОВКА БИЗНЕСА (ПОДГОТОВКА)
*   **Панель Remnawave:** развертывание High-Load панели одной командой (модуль в процессе доработки).
*   **Бот Bedalaga:** установка бота для продаж (модуль помечен как `Coming Soon`).

---

## 📥 УСТАНОВКА

Один раз. Навсегда. Копируй, вставляй, жми Enter.

### Стабильная ветка (Main):
```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/install.sh \
  && bash install.sh \
  && reshala
```
*Или, если ты уже под `root`'ом:*
```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/install.sh \
  && sudo bash install.sh \
  && sudo reshala
```

### Ветка разработчика (Dev) — тут тестовая версия 
⚠️ **ОПАСНО ДЛЯ ПРОДАКШЕНА**:
```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/dev/install.sh \
  && bash install.sh \
  && reshala
```
*Или, если ты уже под `root`'ом:*
```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/dev/install.sh \
  && sudo bash install.sh \
  && sudo reshala
```


---

## 🚀 КАК ЗАПУСТИТЬ?

Просто напиши в консоли:

```bash
sudo reshala
```
**На сервере, где произошла ошибка, удали следы неудачной установки:**

```bash
rm -f /usr/local/bin/reshala && rm -rf /opt/reshala && rm -f install.sh
```
*Если пишет "command not found" или ты на совсем голом Debian:*
```bash
apt update && apt install -y sudo && sudo reshala
```

---

## 🧩 ДЛЯ ТЕХ, КТО ХОЧЕТ ДОПИСЫВАТЬ КОД

Если ты лезешь в код, а не только жмёшь кнопки:

- Внимательно прочитай файл `WARP.md` — там описана архитектура, ожидания от модулей и **Project standards (do not break)**.
- Новые фичи лучше делать так:
  - новый модуль в `modules/` + вызов через `run_module` из основного меню;
  - новый виджет в `plugins/dashboard_widgets/` (выводит `Label : Value`, не спрашивает ввод);
  - новый плагин для Skynet в `plugins/skynet_commands/` (не интерактивный скрипт, который можно гонять на весь флот).
- Цвета, логика `run_cmd`, формат `FLEET_DATABASE_FILE`, структура `config/reshala.conf` и поведение `self_update` считать **священными** — меняем их только осознанно и синхронно с документацией.

## 📏 СТАНДАРТЫ (КРАТКО ДЛЯ КОНТРИБЬЮТОРОВ)

Это не полный закон, а выжимка. За детальной «библией» лезь в `WARP.md` → раздел **Project standards (do not break)**.

- **Цвета и оформление:**
  - Все цветовые константы и escape-последовательности живут только в `modules/common.sh` (переменные `C_*`).
  - Не лепи сырые `\033[...]` в модулях. Нужен новый цвет/стиль — добавь его в `common.sh`.
- **Сообщения пользователю:**
  - Для вывода используй алиасы `info`, `ok`, `warn`, `err` (они же `printf_*` из `common.sh`).
  - Не рисуй свои `[+]`, `[-]` и радуги через `echo` — всё должно проходить через общие хелперы.
- **Меню и шапки:**
  - Для шапок меню используй `menu_header "..."` вместо самодельных рамок из `printf`.
  - Под шапкой — 1–2 строки, которые объясняют, что делает меню и какие пункты опасные.
- **Архитектура и «священные» места:**
  - Вход только через `reshala.sh`; конфиг — `config/reshala.conf`; общие функции — `modules/common.sh`.
  - Формат `FLEET_DATABASE_FILE`, протокол обновления (`self_update`/`install.sh`), структура виджетов и плагинов считаем контрактом. Ломаешь — обновляй и код, и `WARP.md`, и доку.
- Если сомневаешься, как правильно — сначала перечитай `WARP.md`, потом уже пиши код.

## 🥃 ФИНАЛЬНОЕ СЛОВО

Хватит ныть и искать сложные пути. Этот инструмент написан кровью и потом, чтобы ты мог зарабатывать, а не админить.
Видишь баг? Пиши. Видишь фичу? Пользуйся.

**Удачи в бизнесе.** 👊

### [💰 Донатик на поддержку автору (на пиво и нервы)](https://t.me/tribute/app?startapp=dxrn)

---

<a name="en"></a>
# Reshala Tool 🚀 v2.44x (Skynet + Widgets)

![Reshala logo](https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/assets/reshala-logo.jpg)

### WHAT IS THIS THING?

If you are tired of copy-pasting commands, digging through logs and guessing why the server is choking – meet **Reshala**.
It is a Bash TUI framework that turns your VPN / server farm into something you control from one place instead of babysitting each box.

Now with **SKYNET** fleet mode and **dashboard widgets**.

---

### 🎛 DASHBOARD

When you start the script you get a **control panel**, not a black hole:

* **Visuals:** CPU / RAM / Disk usage bars so you instantly see bottlenecks.
* **Honest math:** can run an official Ookla speedtest and **estimate how many real users your node can handle**.
* **Status:** kernel version, virtualization, ping, country, panel/node/bot status.
* **WIDGETS:** small, toggleable widgets (BTC price, Docker state, network activity, "server mood"), rendered from `plugins/dashboard_widgets/*`.

---

### 🌐 [0] SKYNET: FLEET CONTROL

No more SSHing into each server by hand.

* **Single control plane:** keep a fleet DB of all your servers.
* **Teleport:** jump into any host, keys are managed for you.
* **Auto-capture:** if the remote host has no Reshala yet, Skynet can install and start it.
* **Sync:** manage the whole fleet from one screen.

Skynet plugins live in `plugins/skynet_commands/*.sh` (see `GUIDE_SKYNET_WIDGETS.md`).

---

### 📂 MENU OVERVIEW

#### [1] 🔧 SERVICE MENU (local maintenance)

Everything that keeps the box fast and healthy:

* **🚑 EOL rescue / upgrade:** fixes Ubuntu EOL mirrors (404) by switching to `old-releases.ubuntu.com`.
* **🚀 Network "Turbo" (BBR + CAKE):** applies a tuned TCP stack via `/etc/sysctl.d/99-reshala-boost.conf`.
* **🌐 IPv6 control:** enable/disable IPv6 cleanly via small sysctl snippets.
* **⚡ Moscow speedtest:** runs official Ookla CLI and stores results so the dashboard can show node capacity.

#### [2] 📜 QUICK LOGS

Stop typing `docker logs -f ...` by hand.

* One key – immediate view into Reshala, Panel, Node (Xray) and Bot logs (if present).
* Exit from tail/log viewers with `CTRL+C`, you are returned to the menu.

#### [3] 🐳 DOCKER MANAGEMENT

Docker loves to eat disk. This menu keeps it on a leash:

* Shows containers, images, volumes and networks.
* Lets you prune garbage with confirmations.
* Provides handy flows:
  * list containers,
  * stream logs,
  * start/stop/restart,
  * `docker inspect` and `docker stats --no-stream`,
  * manage networks, volumes and images.

#### [4] & [5] 💿 BUSINESS INSTALLERS (WIP)

* **Remnawave Panel:** high-load panel installer (module under active development).
* **Bedalaga Bot:** bot installer for sales (marked as `Coming Soon`).

---

## 📥 INSTALLATION

### Stable branch (main)

```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/install.sh \
  && bash install.sh \
  && reshala
```

If you are already `root` but want to keep using `sudo`:

```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/install.sh \
  && sudo bash install.sh \
  && sudo reshala
```

### Dev branch (dev) — **NOT for production**

```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/dev/install.sh \
  && bash install.sh \
  && reshala
```

Or, with sudo:

```bash
wget -O install.sh https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/dev/install.sh \
  && sudo bash install.sh \
  && sudo reshala
```

---

## 🚀 HOW TO RUN

On a server where Reshala is installed:

```bash
sudo reshala
```

If installation failed and you want to wipe traces:

```bash
rm -f /usr/local/bin/reshala && rm -rf /opt/reshala && rm -f install.sh
```

If `sudo` is missing on a very bare Debian:

```bash
apt update && apt install -y sudo && sudo reshala
```

---

## 🧩 FOR DEVELOPERS

If you want to extend the tool instead of just pressing buttons:

- Start with `WARP.md` – it describes the architecture and **Project standards (do not break)**.
- For writing new modules, read:
  - `GUIDE_MODULES.md` – how to structure `modules/*.sh`, integrate menus, use `run_module`, `menu_header`, `info/ok/warn/err`, config helpers and logging.
- For widgets and Skynet plugins, read:
  - `GUIDE_SKYNET_WIDGETS.md` – how to write safe dashboard widgets and fleet commands.
- Treat colors, `run_cmd` logic, `FLEET_DATABASE_FILE` format, `config/reshala.conf` layout and `self_update` behaviour as **contracts**. If you change them, update code and docs together.

Short version of standards lives in the Russian section under **«📏 СТАНДАРТЫ (КРАТКО ДЛЯ КОНТРИБЬЮТОРОВ)»**.

---

## 🥃 FINAL WORD

This tool was built so you spend time on business, not on endless server babysitting.

If you see a bug – report it. If you like a feature – use it.

**Good luck and stable profit.** 👊

### [💰 Small tip to support the author (for beer & nerves)](https://t.me/tribute/app?startapp=dxrn)
