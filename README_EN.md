# One-Key XRDP Remote Desktop Installer v2.0.0

One-click script to install and configure XRDP remote desktop on Debian/Ubuntu, with Feiniu NAS (fnOS) support.

## Features

- **Modular Installation** — Pick and choose desktop, remote protocol, and optional software
- **Feiniu NAS Support** — Auto-fix dpkg corruption, deploy watchdogs to prevent trim update crashes
- **Interactive & Non-interactive Modes** — Menu-driven or fully scripted via CLI arguments
- **Full Lifecycle Management** — Install, user management, service control, configuration, modular uninstall

## Supported Systems

| System | Versions |
|--------|----------|
| Debian | 10 / 11 / 12 / 13 |
| Ubuntu | 20.04 / 22.04 / 24.04 |
| Feiniu NAS | All versions |

Architecture: x86_64 / aarch64

## Quick Start

```bash
# Download
wget https://raw.githubusercontent.com/zmrblog/onekey-install-xrdp/main/install.sh

# Make executable
chmod +x install.sh

# Interactive install (recommended)
sudo ./install.sh

# Default install (XFCE4 + XRDP)
sudo ./install.sh install

# Custom components
sudo ./install.sh install --desktop=mate --wine=full --input-method
```

## Component Selection

| # | Component | Description |
|---|-----------|-------------|
| 1 | XFCE4 Desktop | Lightweight, recommended |
| 2 | LXQt Desktop | Ultra-lightweight |
| 3 | MATE Desktop | Moderate resource usage |
| 0 | Skip Desktop | Use existing desktop |
| 4 | XRDP Remote Desktop | Recommended |
| 5 | VNC Remote Desktop | Optional |
| 6 | Wine Minimal | Core only |
| 7 | Wine Full | With winetricks |
| 8 | Fcitx5 Chinese Input | Optional |
| 9 | Bottles | Graphical Wine manager |

In interactive mode, enter numbers separated by commas, e.g. `0,4,7,8`.

## Main Menu

```
  1) Install Remote Desktop (guided component selection)
  2) User Management (add/delete/password/list)
  3) Service Control (start/stop/restart/status)
  4) Firewall Configuration (open/close ports)
  5) Adjust Resolution/Port/Swap
  6) Status Diagnostics
  7) Modular Uninstall
  8) View Operation Log
  0) Exit
```

## CLI Arguments

### Top-level Commands

| Command | Description |
|---------|-------------|
| `install [options]` | Install remote desktop |
| `user add [username]` | Add user |
| `user del <username>` | Delete user |
| `user passwd <username>` | Change password |
| `user list` | List users |
| `service <service> <action>` | Service control |
| `firewall <open\|close>` | Firewall configuration |
| `resolution <width> <height> [depth]` | Adjust resolution |
| `port <port>` | Change XRDP port |
| `status` / `diag` | System diagnostics |
| `swap` | Swap management |
| `uninstall <component>` | Uninstall component |

### Install Options

| Option | Description |
|--------|-------------|
| `--all` | Install all components |
| `--xrdp` | Install XRDP |
| `--no-xrdp` | Skip XRDP |
| `--vnc` | Install VNC |
| `--wine=minimal` | Wine core only |
| `--wine=full` | Wine with winetricks |
| `--input-method` | Install Fcitx5 Chinese input |
| `--bottles` | Install Bottles |
| `--desktop=xfce4` | XFCE4 desktop |
| `--desktop=lxqt` | LXQt desktop |
| `--desktop=mate` | MATE desktop |
| `--desktop-only` | Desktop only (no XRDP) |
| `--no-desktop` | Skip desktop |

### Uninstallable Components

`xrdp` / `vnc` / `desktop` / `wine` / `input_method` / `bottles` / `all`

## Configuration

### Resolution

Presets: 720p / 1080p / 2K. Custom width, height, and color depth supported (default 24-bit, max 32-bit).

```bash
sudo ./install.sh resolution 1920 1080 24
```

### Port

Default: 3389. Automatically updates firewall rules and restarts service.

```bash
sudo ./install.sh port 3390
```

### Swap

Create, delete, or check swap status. Auto-persists via /etc/fstab.

## Feiniu NAS Specifics

### Pre-install Auto-fix

1. **Clean corrupted liveupdate dpkg metadata** — Does not affect binaries
2. **Fix half-configured dpkg packages** — Process triggers + reconfigure
3. **Temporarily disable update-initramfs** — Prevents crash during installation

### Trim Repository Avahi Conflict

The Feiniu trim repo's avahi package has incompatible versioning. The script auto-writes apt pin rules to downgrade to Debian standard versions.

### Post-install Watchdogs

| Script | Function | Frequency |
|--------|----------|-----------|
| `ufw-protect.sh` | Protect Web ports + 3389, prevent trim from resetting firewall | Every 5 min |
| `trim-update-guard.sh` | Monitor liveupdate process, prevent auto-update crashes | Every 1 min |

Manually allow updates: `rm /tmp/trim_update_guarded`

## Pre-scan Checks

| Check | Description |
|-------|-------------|
| apt status | No locks, dependencies OK |
| Disk space | Min 3 GB, recommended 5 GB+ |
| Memory | Min 512 MB, recommended 1 GB+ |
| Network | Internet access |
| Port 3389 | Availability |
| Existing desktop | Conflict detection |
| Existing XRDP | Version detection |
| Display manager | Compatibility |

Additional checks on Feiniu NAS: dpkg half-configured packages, liveupdate status, initramfs health.

## Other Features

- **Concurrency protection** — Atomic mkdir-based directory lock
- **Container adaptation** — Detects Docker/LXC, skips display manager startup
- **China mirrors** — Auto-switch to Aliyun/USTC/Tsinghua mirrors on apt failure
- **DNS pre-check** — Test DNS resolution, provide fix commands on failure
- **State engine** — JSON-based install state tracking with dpkg fallback detection
- **Safe uninstall** — Thorough cleanup of metapackages, autoremove, residual packages and configs

## Requirements

- Root privileges
- Bash 4.0+
- apt package manager
- Disk space >= 3 GB
- Memory >= 512 MB
- Internet connection

## Connecting

After installation, use Windows Remote Desktop Connection (mstsc):

```
Address: <server-ip>:3389
Username: root or created user
Password: corresponding password
```

## License

MIT License
