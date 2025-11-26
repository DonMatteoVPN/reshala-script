# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Commands & workflows

### Running locally from this checkout

- These scripts target Linux servers (primarily Debian/Ubuntu). Most operations must be run as `root` or via `sudo`.
- To run the tool directly from this checkout without installing globally, from the repo root on a Linux host:

```bash
sudo bash reshala.sh
```

- To exercise the bootstrap installer flow (downloads the latest code from GitHub based on `REPO_BRANCH` in `install.sh`, currently `dev`):

```bash
sudo bash install.sh
```

  This script downloads the selected branch archive to a temporary directory, unpacks it, and then runs:

```bash
bash reshala.sh install
```

  from that temporary checkout.

### After installation on a test server

The in-repo installer (`modules/self_update.sh`) installs the framework into `/opt/reshala` and symlinks the main entrypoint to `/usr/local/bin/reshala` (see `INSTALL_PATH` in `config/reshala.conf`).

- Normal entrypoint after installation:

```bash
sudo reshala
```

- Inside the TUI main menu:
  - `[u]` triggers a self-update using `run_module self_update run_update`.
  - `[d]` triggers uninstall using `run_module self_update uninstall_script`.

These flows are the primary way to verify that installation, update, and uninstall paths still work after changes.

### Tests and linting

- There are currently no automated tests or explicit linting scripts in this repo.
- To validate changes, run the tool on a non‑production Linux host and exercise the relevant menu paths (e.g., Skynet fleet management, service maintenance, diagnostics, widgets) through the TUI.

## Architecture overview

### Entry point and control flow

- `reshala.sh` is the main entrypoint and orchestration layer.
  - Resolves `SCRIPT_DIR` robustly (handles symlinks) to locate config, modules, and plugins relative to the script location.
  - Loads configuration from `config/reshala.conf` and shared utilities from `modules/common.sh`. Both are treated as fatal dependencies.
  - Exposes a generic `run_module <module_name> <function> [args...]` helper that:
    - Sources `modules/<module_name>.sh` on demand.
    - Invokes the requested function with any remaining arguments.
  - Implements `show_main_menu`, which:
    - Renders the dashboard by calling `run_module dashboard show`.
    - Shows the main menu options for Skynet, local maintenance, diagnostics/logs, Docker cleanup, panel/bot install placeholders, widget management, self‑update, and uninstall.
    - Dispatches menu selections to the appropriate module entrypoints.
  - `main()` performs startup duties:
    - Initializes logging via `init_logger` (from `modules/common.sh`).
    - Enforces root execution (`EUID == 0`).
    - Special‑cases the `install` argument to hand off to `modules/self_update.sh::install_script` and then ensure `sudo` is installed.
    - Starts a background update check (`run_module self_update check_for_updates &`) and then drops into `show_main_menu`.

### Configuration layer

- `config/reshala.conf` centralizes configuration and constants, many of them marked `readonly` and assumed global:
  - Logging, paths and persistence:
    - `LOGFILE` – primary log file (used by `log`).
    - `INSTALL_PATH` – symlink for the installed command (typically `/usr/local/bin/reshala`).
    - `FLEET_DATABASE_FILE` – file backing Skynet’s fleet database in the user’s home directory.
  - Update configuration:
    - `REPO_OWNER`, `REPO_NAME`, `REPO_BRANCH` – define which GitHub repo/branch to pull updates from.
    - `REPO_URL`, `SCRIPT_URL_RAW` – derived URLs used when checking/updating from GitHub.
  - Skynet defaults:
    - `SKYNET_MASTER_KEY_NAME`, `SKYNET_UNIQUE_KEY_PREFIX` – naming conventions for SSH keys.
    - `SKYNET_DEFAULT_USER`, `SKYNET_DEFAULT_PORT` – defaults used when adding new servers to the fleet.
    - `SKYNET_AUTO_SSH_SCAN` – controls whether Skynet auto-probes SSH status for all fleet hosts (`on`/`off`).
  - Dashboard and widgets:
    - `DASHBOARD_LABEL_WIDTH` – **minimum** label width for the dashboard; the actual width is auto-detected from real labels.
    - `DASHBOARD_CACHE_TTL` – base TTL for core metrics cache; multiplied by `DASHBOARD_LOAD_PROFILE` factor.
    - `DASHBOARD_WIDGET_CACHE_TTL` – base TTL for widget cache; also scaled by the load profile.
    - `DASHBOARD_LOAD_PROFILE` – `normal` / `light` / `ultra_light`, controls how aggressively the dashboard recomputes data.
  - Misc feature knobs:
    - `SPEEDTEST_DEFAULT_SERVER_ID` – default Ookla server for the Moscow speed test.
- New persistent settings should be wired through this config and manipulated via `set_config_var` / `get_config_var` (from `modules/common.sh`) instead of hard‑coding them inside modules.

### Shared utilities (`modules/common.sh`)

- Defines color constants and standard output helpers: `printf_info`, `printf_ok`, `printf_warning`, `printf_error`.
- Logging:
  - `init_logger` ensures the log file exists with permissive permissions.
  - `log` writes timestamped messages to `LOGFILE` via `run_cmd tee -a` so it works both as root and under `sudo`.
- Privilege handling:
  - `run_cmd` is the canonical way to execute system commands:
    - Runs the command directly if already root.
    - Uses `sudo` if available when not root.
    - Emits a clear error if neither condition is met.
- User input and config helpers:
  - `safe_read` wraps `read -e` with default values.
  - `wait_for_enter` standardizes "press Enter to continue" prompts.
  - `ask_yes_no`, `ask_non_empty`, `ask_number_in_range` implement unified "anti-fool" input validation for yes/no, required strings and numeric ranges.
  - `enable_graceful_ctrlc` / `disable_graceful_ctrlc` provide a standard way to trap `CTRL+C` in menus and return back instead of killing the whole script.
  - `ensure_package` installs missing CLI tools via `apt-get` or `yum` when possible.
  - `set_config_var` / `get_config_var` provide a simple key/value store on top of `config/reshala.conf` and are used by higher‑level modules (e.g., widget management).

Most other modules assume `SCRIPT_DIR`, `LOGFILE`, and these helpers are available; new modules should follow the same pattern (guard against direct execution and rely on `run_cmd`/`log` rather than calling `apt`, `sysctl`, etc. directly).

### Feature modules

Each feature module lives under `modules/` and is intended to be sourced and invoked through `run_module` from `reshala.sh`.

- `modules/dashboard.sh` – system dashboard / status panel.
  - Collects system and environment data (OS, kernel, uptime, virtualization, IP, geolocation, ping, hoster info, CPU model, CPU/RAM/disk load).
  - Renders the main dashboard view shown before the menu, using `DASHBOARD_LABEL_WIDTH` for alignment.
  - If `SKYNET_MODE=1` is set (remote session launched by Skynet), switches to a different header to signal remote control.
  - Integrates optional widgets from `plugins/dashboard_widgets`:
    - Reads `ENABLED_WIDGETS` from `config/reshala.conf` via `get_config_var`.
    - Executes each enabled, executable widget script and maps its `Label : Value` output into the dashboard under a dedicated `WIDGETS` section.

- `modules/local_care.sh` – local system maintenance.
  - Network tuning:
    - Detects current congestion control and qdisc via `_get_net_status`.
    - `_apply_bbr` writes a dedicated sysctl config enabling BBR/BBR2 and `fq`/`cake` and applies it via `sysctl -p`.
    - IPv6 management via `_get_ipv6_status_string` and `_toggle_ipv6`, which write/remove small sysctl snippets under `/etc/sysctl.d`.
  - System updates and EOL rescue:
    - `_run_system_update` drives a guided flow: connectivity check, `apt-get update`, and full upgrade.
    - On 404/EOL errors, offers to rewrite sources from standard Ubuntu mirrors to `old-releases.ubuntu.com`, with backups in `/var/backups/reshala_apt_YYYY-MM-DD`.
  - Speedtest integration:
    - `_run_speedtest` installs Ookla’s official `speedtest` client (using the vendor’s `packagecloud` script) if missing.
    - Runs a speed test (preferring `SPEEDTEST_DEFAULT_SERVER_ID`), parses JSON output with `jq`, and logs summarized results.
  - `show_maintenance_menu` is the public entrypoint used by the main menu (`[1]`), wiring the above pieces together.

- `modules/diagnostics.sh` – logs and Docker disk management.
  - `show_diagnostics_menu` (menu `[2]` in the main UI):
    - Provides quick access to the main `LOGFILE` via `view_logs_realtime` (defined elsewhere in the codebase).
    - Conditionally exposes options for panel/node/bot logs based on global state such as `SERVER_TYPE` and `BOT_DETECTED` (set by the state scanner module).
  - `_show_docker_cleanup_menu` (hooked to main menu option `[3]`):
    - Presents interactive options to inspect large Docker images and perform increasingly aggressive cleanup (`docker system prune`, `docker image prune -a`, `docker volume prune`).

- `modules/skynet.sh` – Skynet fleet management / remote control.
  - SSH key management:
    - `_ensure_master_key` manages a single “master” ed25519 key in `~/.ssh/${SKYNET_MASTER_KEY_NAME}`.
    - `_generate_unique_key` creates per‑server keys based on a sanitized server name with the `SKYNET_UNIQUE_KEY_PREFIX`.
    - `_deploy_key_to_host` uses `ssh`/`ssh-copy-id` to push public keys, automatically cleaning up stale host keys with `ssh-keygen -R` and handling first‑time password prompts.
  - Fleet database:
    - Fleet records are stored line‑by‑line in `FLEET_DATABASE_FILE` in the format:
      - `name|user|ip|port|ssh_key_path|sudo_password`.
    - `_sanitize_fleet_database` and `_update_fleet_record` handle cleanup and in‑place edits.
  - Remote command plugins:
    - `_run_fleet_command` lists executable scripts in `plugins/skynet_commands` and lets the operator run a chosen script on every server in the fleet.
    - For each server it copies the plugin to `/tmp/reshala_plugin.sh` on the target, executes it (with `sudo` if needed), and then removes it.
  - UI / control center:
    - `show_fleet_menu` backs main menu option `[0]` (when not already in `SKYNET_MODE`).
    - On entry, it:
      - Reads the fleet DB and concurrently probes all servers via `ssh` with short timeouts, tracking basic ON/OFF status in a temp dir.
      - Renders a tabular overview including connection status, SSH user/host/port, key type (master vs unique), and an indicator if a sudo password is stored.
    - Operator actions include:
      - Add/delete servers, wipe the entire fleet DB, edit the DB with `nano`, and manage keys.
      - Execute a Skynet command plugin on all servers.
      - Directly connect to a chosen server by its index; on connect, Skynet:
        - Ensures the remote “agent” is installed or updated by running the current installer via `SCRIPT_URL_RAW` and `INSTALL_PATH`.
        - Starts the remote `reshala` instance with `SKYNET_MODE=1` over SSH (wrapping with `sudo` and password piping when the remote user is non‑root).

- `modules/self_update.sh` – install, update, and uninstall.
  - `_perform_install_or_update` is the “online” path used for updates:
    - Downloads the branch archive from `REPO_URL`/`REPO_BRANCH`, unpacks it, replaces `/opt/reshala`, and refreshes the `INSTALL_PATH` symlink.
  - `install_script` is the bootstrapper‑facing “offline” install used when `install.sh` has already downloaded and unpacked the repo into a temp directory:
    - Copies files from `SCRIPT_DIR` into `/opt/reshala`.
    - Creates/refreshes the `/usr/local/bin/reshala` symlink.
    - Optionally appends an `alias reshala='sudo reshala'` into `/root/.bashrc`.
  - `uninstall_script` cleans up the symlink, `/opt/reshala`, and the root alias.
  - `check_for_updates` compares the local `VERSION` (from `reshala.sh`) against the latest version available in the remote `reshala.sh` on GitHub and sets `UPDATE_AVAILABLE`/`LATEST_VERSION` globals.
  - `run_update` wraps `_perform_install_or_update` for the update menu option and `exec`s the freshly installed binary on success.

- `modules/state_scanner.sh` – Remnawave environment detection.
  - `scan_remnawave_state` inspects running Docker containers to infer what role the host plays:
    - Sets global variables like `SERVER_TYPE`, `PANEL_VERSION`, `NODE_VERSION`, `BOT_DETECTED`, `BOT_VERSION`, and `WEB_SERVER`.
    - Looks for specific container name patterns (e.g., `remnawave-backend`, `remnanode`, `remnawave_bot`, `remnawave-nginx`) and parses versions out of logs or image labels.
  - Other modules (dashboard, diagnostics) rely on these globals to adjust available options and labels.

- `modules/widget_manager.sh` – dashboard widget toggling.
  - `show_widgets_menu` (main menu option `[w]`) discovers available widget scripts in `plugins/dashboard_widgets`.
  - Tracks enabled widgets via the `ENABLED_WIDGETS` key in `config/reshala.conf` using `get_config_var`/`set_config_var`.
  - Toggles widgets on/off per file name and persists the selection back to the config file.

### Plugin system

This repo is designed to be extended primarily through plugins rather than modifying core modules for every small feature.

- Dashboard widgets (`plugins/dashboard_widgets/*.sh`):
  - Each executable script is expected to print one or more lines in the form `Label: Value` (spacing around `:` is not important; manual alignment is not needed).
  - `modules/dashboard.sh` reads and renders these under the `WIDGETS` section when the widget’s filename is present in `ENABLED_WIDGETS`, auto-aligning labels to a common width.
  - Widgets share the same cache and load profile mechanism as the core dashboard (see `DASHBOARD_CACHE_TTL`, `DASHBOARD_WIDGET_CACHE_TTL`, `DASHBOARD_LOAD_PROFILE`).
  - Example: `plugins/dashboard_widgets/01_crypto_price.sh` fetches the BTC price from the CoinGecko API and outputs something like `Курс BTC: $XXXX / ₽YYYY`.

- Skynet commands (`plugins/skynet_commands/*.sh`):
  - Each executable script is copied to and run on every server in the fleet by `_run_fleet_command`.
  - Optional metadata at the top of the file:
    - `# TITLE: Человекочитаемое имя` – label shown in the Skynet "[c]" commands menu.
    - `# SKYNET_HIDDEN: true` – marks a system plugin that should not appear in the menu (used for internal Remnawave node installers, called programmatically with env vars).
  - Example plugins include:
    - `01_get_uptime.sh` – prints `uptime -p` on each server.
    - `02_update_system.sh` – runs `apt-get update && apt-get upgrade -y` on Debian‑based servers.

When adding new behavior, prefer creating a new module under `modules/` (invoked via `run_module`) or a new plugin script under the appropriate `plugins/` subdirectory, and wire any persistent config through `config/reshala.conf` using the existing helpers.

## Agent journal (recent changes & context)

This section is a running log for AI agents (e.g., WARP assistants) so they immediately understand the current shape of the project and where work last stopped.

### High-level purpose of the project

- "Решала" is a Bash-based TUI framework for managing single Linux servers and fleets of servers (Skynet):
  - Entry point: `reshala.sh`.
  - Targets Debian/Ubuntu servers, assumes root privileges.
  - Combines: system dashboard, maintenance tasks, Docker management, Remnawave panel/node detection, and Skynet remote control.

### Recent work on dashboard & widgets (late 2025)

**Goal:** make the main dashboard fast, informative, and extensible via widgets, without hanging the UI, and allow tuning load for tiny VPS and big hosts.

- Dashboard core (`modules/dashboard.sh`):
  - Uses a TTL-based cache for heavy system metrics, with base TTL `DASHBOARD_CACHE_TTL` (default ~25s) and separate widget TTL `DASHBOARD_WIDGET_CACHE_TTL` (default ~60s).
  - Introduced a dedicated widget cache directory `WIDGET_CACHE_DIR=/tmp/reshala_widgets_cache` with its own TTL; old cache files are refreshed in the background.
  - Added `DASHBOARD_LOAD_PROFILE` (`normal` / `light` / `ultra_light`):
    - The profile multiplies both TTLs (x1/x2/x4) so on LIGHT/ULTRA the dashboard recomputes data much less often.
  - Widget cache behaviour:
    - On render, dashboard **always** uses the latest cache file for each widget if it exists (so the UI never shows an empty line due to slow APIs).
    - If a cache file is older than the (profile-adjusted) widget TTL, a background job is spawned to rebuild it without blocking the UI.
    - If a widget has no cache yet, the dashboard displays a placeholder like `"<TITLE>: загрузка..."` and kicks off background generation.
  - Widget output rendering:
    - Every line passes through normalization: strip `\r`, skip empty lines, split on the first `:`, trim whitespace.
    - The **actual** label width is auto-detected from all enabled widgets (with `DASHBOARD_LABEL_WIDTH` as a floor), then the dashboard aligns everything to that width so `WIDGETS` visually matches `СИСТЕМА` / `ЖЕЛЕЗО` / `STATUS`.

- Widget scripts (all under `plugins/dashboard_widgets/`):
  - **01_crypto_price.sh** – «Курс биткоина (BTC)»:
    - Uses CoinGecko `simple/price` API with `curl` + `jq` and prints: `Курс BTC: $<цена_USD> / ₽<цена_RUB>`.
    - Robust to missing `curl`/`jq` or API failures (печатает человеко-понятную ошибку вместо падения).
  - **02_load_short.sh** – «Docker: мини-обзор»:
    - Counts total/running/restarting/exited containers and prints: `Docker: всего N, живых M, рестартится R, мёртвых E`.
  - **03_online_users.sh** – «Сетевой движ (TCP)»:
    - Counts active TCP connections in ESTABLISHED state using `ss` or `netstat`.
    - Prints: `TCP-сессии: <N> активных`.
  - **04_root_disk.sh** – «Настроение сервера»:
    - Mixes uptime and relative CPU load per core to produce a human description ("новенький", "пинает балду", "пыхтит изо всех сил", etc.).
    - Prints a single line: `Настроение сервера: <text> (аптайм: ..., load: .../cores)`.

- Widget manager (`modules/widget_manager.sh`):
  - Uses the shared `menu_header` helper (see below) to render a consistent header.
  - Adds explanations at the top of the menu about what the widget manager does.
  - Helper `_clear_widget_cache`:
    - Implements safe cache cleanup: `rm -rf /tmp/reshala_widgets_cache/*` wrapped with messaging.
  - Key `[c]` in the widget menu:
    - "🧹 Очистить кеш виджетов (обновить данные дашборда)".
    - Clears widget cache and informs the user that the dashboard will rebuild data on the next draw.

**Status:**
- Widget rendering, caching, alignment and load profiles are stable and non-blocking.
- If you see stale/malformed widget data, first check `/tmp/reshala_widgets_cache` and the corresponding `.sh` in `plugins/dashboard_widgets`.

### Recent work on Docker diagnostics module

**Goal:** make Docker management menus predictable, safe, and non-blocking.

- Container selection helpers in `modules/diagnostics.sh`:
  - `_docker_select_container`, `_docker_select_network`, `_docker_select_volume`, `_docker_select_image`:
    - All use a consistent pattern:
      - Query `docker` (`ps -a`, `network ls`, `volume ls`, `images`) and build an indexed list.
      - **Print the list to STDERR**, not STDOUT, so capturing via `$(...)` returns **only the selected name**, not the menu.
      - Prompt the user to "Выбери номер ..." and validate the selection.
      - Echo the chosen name to STDOUT for use in subsequent commands.
    - This fixed bugs where the variable contained both the menu and the name, leading to broken docker commands and weird prompts.

- Containers menu (`_show_docker_containers_menu`):
  - Options:
    - 1: Full `docker ps -a` listing.
    - 2: Stream logs of a selected container (`docker logs -f`).
    - 3: Start/stop/restart a selected container.
    - 4: Stop+remove a selected container (with confirmation).
    - 5: `docker inspect` for a selected container.
    - 6: `docker stats --no-stream` snapshot for a selected container.
    - 7: `docker exec -it` into a selected container (tries `bash`, falls back to `sh`).
  - Selection flows now **always** show a numbered list first and only then prompt for the container number.

- Docker images / networks / volumes menus:
  - Networks: `_show_docker_networks_menu` with list + inspect for a chosen network.
  - Volumes: `_show_docker_volumes_menu` with list + inspect + delete (with confirmation).
  - Images: `_show_docker_images_menu` with list, inspect, delete, and "run ad-hoc container" from an image.

- Non-blocking docker wrapper `_docker_safe`:
  - Implemented in `modules/diagnostics.sh`:
    - Wraps `docker` calls with `timeout 10 docker ...` when `timeout` is available, otherwise falls back to raw `docker`.
  - All **non-interactive** docker calls in menus (ps, ls, inspect, prune, rmi, etc.) now go through `_docker_safe`.
  - Interactive streams (`docker logs -f`, `docker exec -it`, `docker compose logs -f`) remain unwrapped so the user can stay attached until pressing Ctrl+C/`exit`.

**Status:**
- Menu flows no longer smear list output into variable values and are robust to slow or partially broken docker daemons.
- If a menu seems frozen, first verify whether the user is inside a long-running interactive command (logs, exec, speedtest, etc.) rather than the menu loop itself.

### Recent UX/structural helpers

- Shared header helper `menu_header` (in `modules/common.sh`):
  - Provides a single function to render a framed title block used in multiple menus.
  - Has been wired into:
    - `show_maintenance_menu` (local_care).
    - `show_docker_menu` (diagnostics).
    - `show_widgets_menu` (widget_manager).
  - Over time, other menus should migrate to this helper to keep the style uniform.

- Short log/print aliases:
  - `info`, `ok`, `warn`, `err` are thin wrappers over `printf_info`, `printf_ok`, etc.
  - Use these for new messaging instead of inventing new printing styles.

### Known rough edges / future work

#### Menu/header standardization checklist

- DONE:
  - `modules/local_care.sh::show_maintenance_menu` — uses `menu_header` + explanatory text.
  - `modules/diagnostics.sh::show_docker_menu` — uses `menu_header` + safety hints for destructive actions.
  - `modules/diagnostics.sh::show_diagnostics_menu` — uses `menu_header` + instructions for exiting log viewers.
  - `modules/widget_manager.sh::show_widgets_menu` — uses `menu_header`, explains purpose, adds `[c]` cache clear.
  - `modules/skynet.sh::show_fleet_menu` — uses `menu_header` + explanation of fleet DB actions.
  - `modules/skynet.sh::_show_keys_menu` — uses `menu_header` + warning about private keys.
- PARTIAL / SPECIAL CASES:
  - `modules/dashboard.sh::show` — рисует основную панель статуса (дашборд), а не простое меню; использует свой особый заголовок в стиле "ИНСТРУМЕНТ «РЕШАЛА»" и отдельный вариант для `SKYNET_MODE`. Пока оставлен как есть, чтобы не ломать визуальный бренд.
- TODO (when touching these areas):
  - Любые новые или ещё не тронутые меню в других модулях (например, будущие подменю в `self_update.sh` или дополнительных диагностических модулях) сразу делать через `menu_header` + 1–2 строки пояснения.

- Some menus still use inline `printf` blocks for headers instead of `menu_header`.
  - When touching any menu code, prefer switching to `menu_header "..."` and adding 1–2 explanatory lines under it (what this menu does, any dangers).

- Input handling:
  - New flows should use `safe_read`, `ask_yes_no`, `ask_non_empty`, `ask_number_in_range` and wrap menu loops with `enable_graceful_ctrlc` / `disable_graceful_ctrlc` so `CTRL+C` returns to the previous menu.
  - Some older code still relies on raw `read -r -p`; when touching those areas, migrate them to the unified helpers.

- Widgets:
  - All current widgets are intentionally lightweight, but adding more (e.g., top processes, firewall status, SSH bruteforce detector) should continue to respect the widget cache pattern and avoid heavy synchronous work.

If you are an AI agent picking up work on this repo, start by reading:
- `reshala.sh` (entrypoint + main menu routing).
- `modules/common.sh` (colors, helpers, menu_header, logging).
- `modules/dashboard.sh` + `plugins/dashboard_widgets/*` (current widget implementation).
- `modules/diagnostics.sh` (especially Docker sections) and `modules/local_care.sh` (maintenance flows).
- `GUIDE_MODULES.md` (this repo) for a step-by-step guide on creating and integrating new modules.

Then consult this Agent journal to understand the latest UX and behavior decisions before making changes.

### 2025-11-25 – README language switcher flags

- Updated `README.md` (RU) and `README.en.md` (EN) headers to use SVG flag icons from `cdn.jsdelivr.net/gh/hampusborgos/country-flags`.
- Both READMEs now show RU and EN flags in the top-right corner, each wrapped in an anchor:
  - RU flag links to `README.md`.
  - EN flag links to `README.en.md`.
- This ensures that on GitHub clicking a flag always switches language by opening the corresponding README instead of the raw image.

### 2025-11-25 – Plan: Remnawave panel/node modules and certificate strategy

- **Goal:** integrate Remnawave panel and nodes into Reshala as first-class modules, using Skynet for remote node installs and keeping full compatibility with the existing Remnawave installer logic.
- **Modules to create:**
  - `modules/remnawave_panel_node.sh` – installs panel + node on the current server (port of donor `installation()` / `install_remnawave()`): asks for panel/subscription/selfsteal domains, prepares `/opt/remnawave` (`.env`, `docker-compose.yml`, `nginx.conf`), generates/attaches certificates, registers superadmin, creates config profile + node + host via HTTP API, updates squads, starts docker and sets up a masking site.
  - `modules/remnawave_panel.sh` – installs only the panel on the current server (port of `installation_panel()`), including API-driven config profile/node/host bootstrap without a local node container.
  - `modules/remnawave_node.sh` – everything related to nodes: installing a node on the current server for an existing panel, and orchestrating **remote** node installs across the fleet via Skynet.
- **Skynet integration for nodes:**
  - A dedicated plugin `plugins/skynet_commands/10_install_remnawave_node.sh` will encapsulate the node-side logic from `installation_node()` (Docker + nginx + local certs/masking site).
  - `remnawave_node.sh` will:
    - On the panel server, work with Remnawave HTTP API (using `api-1.json` as reference) to create config profiles, nodes and hosts, and update squads for each selected node.
    - Use existing Skynet fleet DB to select one or multiple servers, then run the node installer plugin on them (no interactive prompts on the remote side beyond what is absolutely necessary).
- **Certificate strategy (panel + nodes):**
  - The donor script already supports two methods via certbot:
    - **Cloudflare API (DNS-01, wildcard)**.
    - **ACME HTTP-01 (один домен, без wildcard)**.
  - In the new Reshala modules, при установке **ноды** (локально или через Skynet) пользователь будет явно выбирать:
    - `[1]` «Нода будет использовать wildcard-сертификат панели (Cloudflare API)» – допустимо **только если** панель действительно настроена на Cloudflare API / wildcard.
    - `[2]` «Сгенерировать отдельный сертификат на этой ноде (ACME HTTP-01 или свой Cloudflare)».
  - Для варианта `[1]` (Cloudflare/wildcard):
    - На панели будет вестись список нод, которые используют **панельный wildcard** (отдельный файл в `${DIR_REMNAWAVE}` с `user@ip` и путями до cert’ов на ноде).
    - В `renew_hook` Let’s Encrypt на панели (который уже правит `nginx` в доноре) будет добавлен вызов маленького скрипта синхронизации: он через `scp/rsync` копирует обновлённый `fullchain.pem`/`privkey.pem` с панели на каждую ноду из списка и перезапускает nginx/контейнер на ноде.
    - На нодах храним только «принимающую» сторону (пути cert’ов и маленький helper-скрипт, который можно вызвать локально для принудительной ресинхронизации, но в обычном режиме всё пушит панель).
  - Для варианта `[2]` (отдельный сертификат на ноде):
    - На ноде разворачивается упрощённая логика донора: `handle_certificates` + `get_certificates` (Cloudflare или ACME HTTP-01), локальный `certbot renew` и `renew_hook`, который перезапускает nginx/контейнер ноды.
- **UX:** все новые меню и вопросы будут оформлены через `menu_header`, `safe_read`, `info/ok/warn/err`, без своих цветовых костылей. Выбор метода сертификата будет формулироваться с явной привязкой к Cloudflare API (wildcard), чтобы не вводить пользователя в заблуждение.

### 2025-11-26 – Remnawave panel/node implementation progress

- **Domain validation (ported from donor `check_domain`)**
  - Implemented `_remna_check_domain` in `remnawave_panel_node.sh` and wired it into the panel+node installer wizard for all three domains: panel, subscription, and selfsteal (with Cloudflare proxy allowed only for panel/subs, not for selfsteal).
  - Implemented `_remna_panel_check_domain` in `remnawave_panel.sh` and wired it into the panel-only installer (panel + subscription domains).
  - Implemented `_remna_node_check_domain` in `remnawave_node.sh` and wired it into the local node wizard for the selfsteal domain (Cloudflare proxy forbidden, with explicit user confirmation prompts on mismatches).
- **HTTP API layers for Remnawave**
  - `modules/remnawave_panel_node.sh`:
    - Added `_remna_api_request` + helpers for register, x25519 keygen, config-profile creation, node/host creation and squad update.
    - `_remna_api_request` always talks to the panel via a **base URL** (either `http://host:port` or `https://panel.domain`) and unconditionally sends `X-Forwarded-Proto: https`/`X-Forwarded-For`/`X-Remnawave-Client-Type` headers, mirroring the donor `make_api_request` behaviour so the backend is happy both when called directly and when it sits behind a reverse proxy.
    - The panel+node wizard now fully drives Remnawave via HTTP API: registers superadmin, generates x25519 keys, creates a config profile for the selfsteal domain, a node and host, and attaches the inbound to the default squad.
  - `modules/remnawave_panel.sh`:
    - Added a separate `_remna_panel_api_request` + `_remna_panel_api_register_superadmin`, `_remna_panel_api_generate_x25519`, `_remna_panel_api_create_config_profile`.
    - `_remna_panel_api_request` uses the same base-URL + proxy-header model as above, so future tooling can hit either the local backend (`http://127.0.0.1:3000`) or the public panel URL.
    - Panel-only wizard now registers a superadmin, generates x25519 keys, creates a base config profile (for future nodes) and starts the HTTP-only stack.
  - `modules/remnawave_node.sh`:
    - Added `_remna_node_api_request` and node-specific helpers for x25519 keygen, config-profile, node, host and squad update.
    - `_remna_node_api_request` also works from a base URL and always injects `X-Forwarded-Proto: https`, which fixes the "Reverse proxy and HTTPS are required" errors when hitting the backend directly from another host.
    - Added `_remna_node_api_check_node_domain` to ensure the panel does not already have a node with the same `address` before creating a new one.
- **HTTP-only environments (no TLS yet)**
  - Panel+node (`remnawave_panel_node.sh`):
    - `_remna_write_env_and_compose` now creates `/opt/remnawave/.env`, `docker-compose.yml` and `nginx.conf` for the combined panel+node setup, but in an HTTP-only mode (nginx listening on port 80 for panel/subscription/selfsteal, Reality inbound still pointing to `/dev/shm/nginx.sock`).
    - Installer wizard starts the compose stack, waits for `/api/auth/status`, then runs the full API bootstrap (superadmin, x25519, config-profile, node, host, squad update).
  - Panel-only (`remnawave_panel.sh`):
    - `_remna_panel_write_env_and_compose` mirrors the donor `installation_panel` structure but again HTTP-only: panel on 3000 behind nginx:80, subscription page on 3010 behind nginx:80.
    - Panel-only wizard now fully boots the stack, registers superadmin, and creates a base config-profile for future nodes.
- **Local node module – API and runtime**
  - API side in `modules/remnawave_node.sh`:
    - `_remna_node_install_local_wizard` now asks for `PANEL_API` (**URL или host:port**, пример: `https://panel.example.com` или `127.0.0.1:3000`), `PANEL_API_TOKEN`, `SELFSTEAL_DOMAIN`, `NODE_NAME`.
    - `_remna_node_check_panel_api` нормализует ввод в базовый URL (`http://host:3000` или `https://domain`) и делает пробный запрос к `/api/auth/status`, всегда подкидывая `X-Forwarded-Proto: https`/`X-Remnawave-Client-Type`, чтобы панель не ругалась на отсутствие reverse‑proxy.
    - `_remna_node_check_panel_api_with_token` поверх того же base URL дергает `/api/internal-squads` и валидирует токен (должен иметь права API и возвращать хотя бы один internal squad).
    - Сам визард валидирует selfsteal-домен (DNS/IP/Cloudflare) и проверяет уникальность в панели через `_remna_node_api_check_node_domain`.
    - Uses the panel HTTP API to: generate x25519, create a config-profile for the selfsteal domain, create node + host, and attach the inbound to the default squad.
  - Runtime side for a local node (`/opt/remnanode`):
    - `_remna_node_prepare_runtime_dir` ensures `/opt/remnanode` exists.
    - `_remna_node_write_runtime_compose_and_nginx` writes:
      - `/opt/remnanode/docker-compose.yml` with two services:
        - `remnanode` (Remnawave node container, `network_mode: host`, `NODE_PORT=2222`, `SECRET_KEY` placeholder).
        - `remnanode-nginx` (nginx in host network, mounting `nginx.conf`, `/var/www/html` and `/etc/letsencrypt`).
      - `/opt/remnanode/nginx.conf` with a simple HTTP-only server on port 80 for the selfsteal domain, serving `/var/www/html` and setting strict `X-Robots-Tag`.
    - If `/var/www/html/index.html` is missing, writes a minimal masking HTML page so the selfsteal domain exposes a benign static site.
  - Masking site autoupdate for local node (`remask.sh`):
    - `_remna_node_install_remask_tool` creates `/opt/remnanode/tools/remask.sh` – a standalone Bash script that pulls a random template from one of three public repos (simple-web-templates, sni-templates, nothing-sni) and refreshes `/var/www/html`.
    - The same helper also ensures a root cron entry `17 3 */14 * * /opt/remnanode/tools/remask.sh` is present, so the masking site is automatically rotated roughly every 14 days.
- **Node SECRET_KEY wiring (panel → node)**
  - Added `_remna_node_api_apply_public_key(domain_url, token, compose_path)` which:
    - Calls `GET http://<panel>/api/keygen` to retrieve `response.pubKey`.
    - Replaces the `SECRET_KEY="PUBLIC KEY FROM REMNAWAVE-PANEL"` placeholder in `/opt/remnanode/docker-compose.yml` with the real public key using `sed` via `run_cmd`.
  - Local node wizard now, after writing the runtime compose/nginx files, calls `_remna_node_api_apply_public_key` before starting `docker compose up -d` in `/opt/remnanode`.
  - Result: the local node is registered in the panel, has a masking HTTP site on `http://SELFSTEAL_DOMAIN`, and already runs with the correct `SECRET_KEY` from the panel.
- **Local node TLS (ACME HTTP-01, first pass)**
  - `modules/remnawave_node.sh` local wizard `_remna_node_install_local_wizard` now optionally issues a Let's Encrypt certificate for the selfsteal domain via `_remna_node_setup_tls_acme` (certbot `--standalone` HTTP-01 with `ensure_package certbot` on demand).
  - `_remna_node_write_runtime_compose_and_nginx` now mounts `/etc/letsencrypt` into the `remnanode-nginx` container, and `_remna_node_write_nginx_tls` rewrites `/opt/remnanode/nginx.conf` to serve an HTTP→HTTPS redirect and a 443 vhost pointing at `/etc/letsencrypt/live/SELFSTEAL_DOMAIN`.
  - `_remna_node_setup_tls_renew` теперь прописывает renew_hook в `/etc/letsencrypt/renewal/SELFSTEAL_DOMAIN.conf` (перезапуск `remnanode-nginx` через `docker compose`) и, если ещё нет, добавляет простой `cron` с `/usr/bin/certbot renew --quiet` раз в день в 05:00.
- **Skynet plugin for remote node install (HTTP/HTTPS, first pass)**
  - `plugins/skynet_commands/10_install_remnawave_node.sh` is now wired with a human-readable TITLE and can prepare `/opt/remnanode` (docker-compose + nginx + basic masking index.html) on a remote host via Skynet when `SELFSTEAL_DOMAIN` is provided.
  - The plugin honours optional `NODE_PORT`/`NODE_SECRET_KEY` and `CERT_MODE` variables for the `remnanode` container: `NODE_SECRET_KEY` is passed from the panel via `_remna_node_api_get_public_key` in `remnawave_node.sh`, and when `CERT_MODE=node_acme` it will also obtain a Let's Encrypt certificate on the remote host (ACME HTTP-01), rewrite nginx to HTTPS and set up certbot renew cron and renew_hook, plus remask autocron via `/opt/remnanode/tools/remask.sh`.
- **Skynet multi-node wizard (panel side)**
  - `_remna_node_install_skynet_many` in `remnawave_node.sh` now allows picking multiple servers from the Skynet fleet (comma-separated indices), asking per-server `SELFSTEAL_DOMAIN` and `NODE_NAME` while sharing panel API/token, node port and TLS mode.
  - For each selected server it creates a dedicated config-profile/node/host in the panel, attaches the inbound to the default internal squad, fetches `pubKey` via `_remna_node_api_get_public_key`, and then launches the `10_install_remnawave_node.sh` plugin on that host with `SELFSTEAL_DOMAIN`/`NODE_PORT`/`NODE_SECRET_KEY`/`CERT_MODE` wired in.

 ## Project standards (do not break)

These are core conventions and contracts for «Решала». When you change or extend the code, treat these as **constraints** – breaking them может поломать обновления, плагины или мышечную память пользователей.

### 1. Entry point, layout and config

- **Entry point:**
  - `reshala.sh` is the only supported entrypoint.
  - It must continue to support:
    - `sudo reshala` – normal interactive run.
    - `bash reshala.sh install` – local install mode used by `install.sh`.
- **Script layout:**
  - `SCRIPT_DIR` is the root for all relative paths; do not hardcode absolute paths to repo files.
  - Config lives in `config/reshala.conf`. New persistent knobs must go there and be accessed via `get_config_var` / `set_config_var`.
  - Shared logic lives in `modules/common.sh`. New cross-cutting helpers go here, not ad‑hoc in random modules.
- **Install location and symlink:**
  - `INSTALL_PATH` is defined in `config/reshala.conf` (default `/usr/local/bin/reshala`).
  - On install/update, `/opt/reshala` is the canonical home of the code; do **not** change this without also updating `install.sh`, `self_update.sh` and docs.

### 2. Privileges, OS support and external commands

- **Target OS:**
  - Only Linux, primarily Debian/Ubuntu. Do not silently add logic that breaks on these distros.
- **Root requirement:**
  - `reshala.sh::main` enforces `EUID == 0`. Do not remove this check; most modules assume root.
- **Command execution:**
  - Always use `run_cmd` for system-level actions (apt, sysctl, service management, file chmod/chown, etc.).
  - Do **not** call `sudo` directly inside modules – `run_cmd` encapsulates sudo vs root.
- **Speedtest / network tools:**
  - `local_care` uses Ookla `speedtest` and `curl`/`jq`. If you swap tools, keep JSON-based parsing and error handling.

### 3. Logging and error reporting

- **Logging contract:**
  - `LOGFILE` is defined in `config/reshala.conf`. Do not hardcode another main log path.
  - Use `log ...` for anything that should end up in the central log (installs, updates, errors, Skynet ops, speedtests, etc.).
- **User-facing messages:**
  - Use `info`, `ok`, `warn`, `err` (wrappers over `printf_info`/`printf_ok`/`printf_warning`/`printf_error`) for messages to the user.
  - Do not introduce new ad‑hoc color sequences or raw `\033[...]` for text styling. If you need a new style, add it to `modules/common.sh`.

### 4. Menu and UX style

- **Headers:**
  - Use `menu_header "…"` for menu headers instead of hand-written `printf` blocks with `╔/║/╚`.
  - Under the header, print 1–2 explanatory lines describing what the menu does and warn about destructive actions.
  - Exception: the main dashboard header in `modules/dashboard.sh::show` ("ИНСТРУМЕНТ «РЕШАЛА» …" and SKYNET banner) – keep its look & feel.
- **Navigation:**
  - `[b]` / `[B]` is the standard "Назад" key in submenus.
  - The main menu uses `q/Q` to exit; do not overload `q` in submenus for unrelated actions.
  - Long-running views (e.g., `tail -f`, `docker logs -f`, `docker compose logs -f`) must exit on `CTRL+C` and return cleanly to their parent menu.
- **Input helpers:**
  - Use `safe_read` instead of raw `read` where you want default values and readline editing.
  - For confirmations and numeric choices, prefer the shared helpers:
    - `ask_yes_no` for all yes/no questions.
    - `ask_non_empty` for required strings (domains, tokens, names).
    - `ask_number_in_range` for menu indices and numeric ranges.
  - Wrap non-main menus with `enable_graceful_ctrlc` / `disable_graceful_ctrlc` so `CTRL+C` cancels input and returns back instead of killing the whole script.

### 5. Widgets and plugin contracts

- **Dashboard widgets (`plugins/dashboard_widgets/*.sh`):**
  - Must be **non-interactive**: no `read`, no infinite loops, no `sleep` in the hot path.
  - Output format: one or more lines of the form `Label : Value`. The dashboard will split on the first `:` and align columns.
  - Heavy network or disk work should be done quickly or behind the widget cache:
    - Respect that `modules/dashboard.sh` will cache your output in `/tmp/reshala_widgets_cache/<widget>.cache` and may call you from a background job.
  - If your widget calls external APIs, handle timeouts and failures gracefully and output a human-readable error instead of crashing.
- **Skynet plugins (`plugins/skynet_commands/*.sh`):
  - Are executed remotely on many hosts. They must:
    - Be non-interactive (no `read` from stdin).
    - Exit with proper status codes (0 on success, non-zero on failure).
    - Avoid assumptions about the remote distro beyond "Linux with basic POSIX userland".

### 6. Skynet data model and behaviour

- **Fleet DB format (`$FLEET_DATABASE_FILE`):**
  - Lines are `name|user|ip|port|ssh_key_path|sudo_password`.
  - Do not change field order or separator (`|`) without a **clear migration path** and back-compat.
- **Key management:**
  - `SKYNET_MASTER_KEY_NAME` and `SKYNET_UNIQUE_KEY_PREFIX` govern SSH key naming – do not change them lightly; existing fleets depend on these values.
- **SSH auto-scan:**
  - `SKYNET_AUTO_SSH_SCAN` controls whether `show_fleet_menu` auto-probes all hosts and shows ON/OFF status (`on` by default, can be switched to `off` for huge fleets/low-power panels).
- **Hidden system plugins for Remnawave:**
  - Internal Skynet plugins used for Remnawave node install are marked with `# SKYNET_HIDDEN: true` and are not shown in the `[c]` commands menu.
  - These plugins are invoked programmatically from Remnawave modules and receive a **narrow set** of env-vars: `SELFSTEAL_DOMAIN`, `NODE_PORT`, `NODE_SECRET_KEY`, `CERT_MODE` (all strictly for panel/node interaction).
- **Remote agent:**
  - Skynet relies on being able to deploy and run the same `reshala.sh` on remote servers via `SCRIPT_URL_RAW`.
  - If you change the install/update protocol, update both local and remote sides (the bootstrap `install.sh`, `self_update.sh`, and the Skynet deployment logic) in sync.

### 7. Self-update and versioning

- **Version string:**
  - `readonly VERSION="vX.YZZ"` in `reshala.sh` is parsed by `self_update::check_for_updates` using a simple `grep 'readonly VERSION=' ... | cut -d'"' -f2`.
  - Do not change this pattern (no extra quotes, no comments on the same line, etc.).
- **Update flow:**
  - `check_for_updates` sets `UPDATE_AVAILABLE` and `LATEST_VERSION` and is called once before `show_main_menu`.
  - `run_update` must, on success, `exec "$INSTALL_PATH"` so the new code is immediately in use.
  - `install_script` is used by the bootstrapper (`install.sh`), and `_perform_install_or_update` is used by online updates. Keep both paths working.
- **Uninstall:**
  - `uninstall_script` must remove:
    - the symlink at `INSTALL_PATH`,
    - `/opt/reshala`,
    - `LOGFILE` and `FLEET_DATABASE_FILE` (if set),
    - the `alias reshala='sudo reshala'` line from `/root/.bashrc`.

### 8. Coding style and language

- **Shell style:**
  - Bash only (`#!/bin/bash`). Avoid introducing dependencies on zsh/fish-specific features.
  - Prefer `[[ ... ]]` over `[...]`, `$(...)` over backticks.
  - Keep functions `snake_case` with `_` separators (e.g., `_run_speedtest`, `show_docker_menu`).
- **Language and tone:**
  - User-facing text is currently in Russian с лёгким бандитским/сленговым тоном. New messages should match this style unless there is a strong reason not to.
  - Do not silently switch to English in the middle of Russian UI; if you add multi-language support, design it explicitly.

### 9. README «Стандарты»

- `README.md` содержит короткий раздел для контрибьюторов («СТАНДАРТЫ (КРАТКО ДЛЯ КОНТРИБЬЮТОРОВ)»).
- Любые изменения базовых контрактов (цвета, меню, формат БД, self-update, виджеты/плагины и т.п.) сначала фиксируем здесь, в этом списке, а затем обновляем выжимку в README, чтобы они не разъехались.

### 10. How to extend safely

When adding new functionality:

1. Decide **where** it belongs:
   - Core orchestration? → `reshala.sh` + `modules/common.sh`.
   - A new big feature? → new `modules/<feature>.sh` + `run_module` entry from the main menu.
   - A per-server action for Skynet? → `plugins/skynet_commands/NN_name.sh`.
   - A dashboard metric? → new `plugins/dashboard_widgets/NN_name.sh`.
2. Wire any persistent settings through `config/reshala.conf` via `set_config_var`/`get_config_var`.
3. Use `menu_header` and `info/ok/warn/err` for all new menus and messages.
4. Update this WARP Agent journal if you change UX, data formats, or cross-cutting behaviours (widgets, Skynet, self-update, etc.).
