<p align="right">
  <a href="README.md"><img src="https://cdn.jsdelivr.net/gh/hampusborgos/country-flags@main/svg/ru.svg" alt="RU" width="20" /> RU</a> |
  <a href="README.en.md"><img src="https://cdn.jsdelivr.net/gh/hampusborgos/country-flags@main/svg/us.svg" alt="EN" width="20" /> EN</a>
</p>

<a id="ru"></a>
# Reshala Tool 🚀 v2.x (Skynet + Widgets + Remnawave)

![Reshala logo](https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/assets/reshala-logo.jpg)

### WHAT IS THIS THING?

If you are tired of copy-pasting commands, digging through logs and guessing why the server is choking – meet **Reshala**.
It is a Bash TUI framework that turns your VPN / server farm into something you control from one place instead of babysitting each box.

Now with **SKYNET** fleet mode and **dashboard widgets**.

---

### 🎛 DASHBOARD

When you start the script you get a **control panel**, not a black hole:

* **Visuals:** CPU / RAM / Disk usage bars so you instantly see bottlenecks.
* **Honest math:** can run official Ookla speedtest and **estimate how many real users your node can handle**. In agent mode (SKYNET_MODE=1) CPU load is also calculated correctly (no more “stuck at 100%”).
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

#### [4] 💿 INSTALL REMNAWAVE PANEL (High-Load)

This entry opens the **Remnawave hub**:

- **[1] Panel only** – installs Remnawave panel on this server, registers superadmin, creates a base config-profile and can immediately enable **HTTPS (TLS, Let’s Encrypt)** for panel + subscription domains.
- **[2] Panel + Node** – installs panel and a first node on the same host:
  - asks for three domains (panel, subscription, selfsteal node);
  - validates DNS (with Cloudflare proxy checks; selfsteal must be DNS-only);
  - brings up Docker stack, drives the panel via HTTP API (superadmin, config-profile, node, host, squad);
  - can immediately enable **TLS for panel/subscription (ACME HTTP-01)**;
  - selfsteal domain gets a masking site and can run HTTP or HTTPS.
- **[3] Remnawave nodes** – module `remnawave_node.sh`:
  - installs a node **on this server** for an existing panel;
  - installs a node **on ONE remote server** via Skynet;
  - distributes nodes **to MULTIPLE fleet servers** via Skynet;
  - uses a **hidden Skynet plugin** for remote installs so users cannot call it directly from the generic fleet menu.
- **[4] Manage local Remnawave install** – interactive menu:
  - show Docker status;
  - restart the stack;
  - stream logs (`docker compose logs -f` with clean `CTRL+C` exit);
  - show INSTALL_INFO (domains, superadmin login/password, service vars).

#### [5] 🤖 INSTALL BEDALAGA BOT

Reserved for the Bedalaga bot installer. Currently marked as `Coming Soon` and only shows a warning.

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

Short version of standards lives in the Russian README under **«📏 СТАНДАРТЫ (КРАТКО ДЛЯ КОНТРИБЬЮТОРОВ)»**.

---

## 🥃 FINAL WORD

This tool was built so you spend time on business, not on endless server babysitting.

If you see a bug – report it. If you like a feature – use it.

**Good luck and stable profit.** 👊

### [💰 Small tip to support the author (for beer & nerves)](https://t.me/tribute/app?startapp=dxrn)
