<p align="right">
  <a href="README.md"><img src="https://cdn.jsdelivr.net/gh/hampusborgos/country-flags@main/svg/ru.svg" alt="RU" width="20" /> RU</a> |
  <a href="README.en.md"><img src="https://cdn.jsdelivr.net/gh/hampusborgos/country-flags@main/svg/us.svg" alt="EN" width="20" /> EN</a>
</p>

<a id="ru"></a>
# Reshala Tool 🚀 v2.x (Skynet + Widgets + Remnawave)

![Reshala logo](https://raw.githubusercontent.com/DonMatteoVPN/reshala-script/main/assets/reshala-logo.jpg)

### WHAT IS THIS TOOL?

Reshala is a simple console control panel that helps you keep your servers and fleet under control instead of fighting them one by one.

It:
- prepares a server “from zero to ready” (cleans junk, fixes the system, tunes basic network settings);
- shows a clear dashboard with CPU/RAM/disk and channel usage;
- has a **Skynet** mode to control many servers from a single screen;
- installs and maintains the **Remnawave panel and its nodes** on one or many servers;
- supports lightweight widgets and plugins so you can add your own tricks.

---

### 🎛 DASHBOARD

When you start the script you get a **control panel**, not a black hole:

* **Visuals:** CPU / RAM / Disk usage bars so you instantly see bottlenecks.
* **Honest math:** can run official Ookla speedtest and **estimate how many real users your node can handle**. In agent mode (SKYNET_MODE=1) CPU load is also calculated correctly.
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

Everything that keeps the server stable and responsive:

* **🚑 System fix / update:** helps revive older Ubuntu versions and gently repairs package issues.
* **🚀 Network boost:** applies a ready-made set of network tweaks for smoother pings and better throughput.
* **🌐 Extra network protocol control:** lets you safely turn an extra IP protocol on or off if it only causes trouble.
* **⚡ Channel check to Moscow:** measures real bandwidth and roughly estimates how many users this server can handle.

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

#### [4] 💿 REMNAWAVE: INSTALL & CONTROL

This section groups all Remnawave workflows in one place.

- **[1] Panel only** – installs the Remnawave panel on this server, creates an admin account and can immediately enable secure https access.
- **[2] Panel + node** – installs the panel and the first node on the same host: you enter three domains, Reshala checks they point to the right place, starts all services and prepares comfortable access to the panel and subscription page.
- **[3] Remnawave nodes** – a dedicated wizard for nodes:
  - a node **on this server** for an existing panel;
  - a node **on ONE remote server** in the fleet via Skynet;
  - nodes **on SEVERAL servers at once** in one go.
  In every scenario you can choose how to attach the node to the panel’s internal squads: only to one “main” squad or to all of them at once.
- **[4] Manage local Remnawave install** – a simple menu to:
  - see service status;
  - restart everything with one action;
  - watch logs (with clean `CTRL+C` return);
  - remind key data: domains, admin login/password and service info.

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

## 🧩 IF YOU WANT TO HACK ON THE CODE

This README is focused on users. If you are a developer and want to extend Reshala,
check the docs in the `docs/` folder:

- `WARP.md` – overall architecture and project standards;
- `GUIDE_MODULES.md` – how to write new menu modules properly;
- `GUIDE_SKYNET_WIDGETS.md` – how to build your own widgets and Skynet commands;
- `REMNAWAVE_INTERFACE.md` – how the Remnawave integration is wired inside the script.

A short reminder of standards lives in the Russian README under
**«📏 СТАНДАРТЫ (КРАТКО ДЛЯ КОНТРИБЬЮТОРОВ)»**.

---

## 🥃 FINAL WORD

This tool was built so you spend time on business, not on endless server babysitting.

If you see a bug – report it. If you like a feature – use it.

**Good luck and stable profit.** 👊

### [💰 Small tip to support the author (for beer & nerves)](https://t.me/tribute/app?startapp=dxrn)
