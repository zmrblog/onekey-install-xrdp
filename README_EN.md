# Remote Desktop One-Click Install Script

English | [中文](README.md)

## Overview

A Bash script for one-click deployment of XRDP/VNC remote desktop environments, supporting both interactive menu and command-line modes. Automates the entire process including system pre-scan, desktop environment installation, Chinese locale configuration, and user management.

## Supported Systems

| System | Versions |
|--------|----------|
| Debian | 10, 11, 12, 13 |
| Ubuntu | 20.04, 22.04, 24.04 |

Architecture support: x86_64, aarch64

## Features

- **Pre-scan** — Automatically checks disk space, memory, network, port availability, and apt status before installation
- **Modular installation** — Choose components on demand; supports XFCE4/LXQt/MATE desktops
- **Chinese locale** — Auto-configures zh_CN.UTF-8 locale, Chinese fonts, and input method
- **Auto port conflict resolution** — Automatically finds an available port if 3389 is occupied
- **User management** — Add/delete/change password; supports random password generation and sudo mode selection
- **Firewall configuration** — UFW auto open/close for remote desktop ports
- **Swap management** — Create/delete swap files with custom size
- **Diagnostics** — One-click view of service status, port listening, and resource usage
- **Modular uninstall** — Uninstall individual components or remove everything at once
- **Container compatible** — Auto-detects Docker/LXC environments and skips inapplicable steps
- **Concurrency protection** — Lock file mechanism prevents duplicate script execution
- **State tracking** — JSON state file records installed components; supports resume after interruption

## Available Components

| Component | Description |
|-----------|-------------|
| Desktop | XFCE4 (recommended) / LXQt / MATE |
| XRDP | Remote Desktop Protocol (default port 3389) |
| VNC | TigerVNC server (ports 5901+) |
| Wine | Windows compatibility layer (minimal/full) |
| Bottles | Wine GUI manager (Flatpak) |
| Fcitx5 | Chinese input method (full GTK/Qt support) |

## Quick Start

```bash
# Download the script
wget https://raw.githubusercontent.com/zmrblog/onekey-install-xrdp/main/install.sh

# Interactive mode (launches menu directly)
sudo bash install.sh

# Install all components
sudo bash install.sh install --all

# Install desktop + XRDP only
sudo bash install.sh install

# Install specific components
sudo bash install.sh install --desktop=xfce4 --vnc --wine=full --input-method
```

## Usage

### Interactive Menu

Run `sudo bash install.sh` directly to enter the interactive menu:

```
==========================================
    Remote Desktop Manager v2.0.0
==========================================

  1) Install Remote Desktop (guided component selection)
  2) User Management (add/delete/change password/list)
  3) Service Control (start/stop/restart/status)
  4) Firewall Configuration (open/close ports)
  5) Adjust Resolution/Port/Swap
  6) System Diagnostics
  7) Modular Uninstall
  8) View Operation Logs
  0) Exit
```

### Command Line

```bash
# Installation
sudo bash install.sh install [options]
  --all               Install all components
  --xrdp              Install XRDP
  --no-xrdp           Skip XRDP installation
  --vnc               Install VNC
  --wine=minimal      Install Wine core
  --wine=full         Install Wine full
  --bottles           Install Bottles
  --desktop=xfce4     Select desktop (xfce4/lxqt/mate)
  --input-method      Install Chinese input method
  --desktop-only      Install desktop environment only

# User management
sudo bash install.sh user add [username]       # Add user
sudo bash install.sh user del <username>       # Delete user
sudo bash install.sh user passwd <username>    # Change password
sudo bash install.sh user list                 # List users

# Service control
sudo bash install.sh service xrdp restart

# Firewall
sudo bash install.sh firewall open|close

# Resolution/Port/Swap
sudo bash install.sh resolution 1920 1080 24
sudo bash install.sh port 3390
sudo bash install.sh swap

# Diagnostics
sudo bash install.sh status

# Uninstall
sudo bash install.sh uninstall <component>
  Components: xrdp, vnc, desktop, wine, input_method, bottles, all
```

## Connecting

After installation, use Windows Remote Desktop Connection (mstsc.exe):

1. Open "Remote Desktop Connection"
2. Enter the server IP address (default port 3389)
3. Enter the username and password you created

For VNC, connect to `ServerIP:5901`.

## File Paths

| File | Path |
|------|------|
| State file | `/var/lib/rdp-setup/state.json` |
| Install log | `/var/log/rdp-setup/setup.log` |
| XRDP config | `/etc/xrdp/xrdp.ini` |
| Session startup script | `/etc/xrdp/startwm.sh` |
| VNC launch wrapper | `/usr/local/bin/vnc-user-run` |
| Wine launch wrapper | `/usr/local/bin/swine` |
| Bottles launch wrapper | `/usr/local/bin/bottles` |
| Input method env vars | `/etc/X11/Xsession.d/95fcitx5` |

## System Requirements

- Bash 4.0+
- Root privileges
- At least 3 GB disk space (5 GB+ recommended)
- At least 512 MB memory (1 GB+ recommended)
- Network connection (for package downloads)

## FAQ

**Q: Black screen after connecting?**
A: The script automatically fixes the `startwm.sh` configuration (comments out the default Xsession execution and appends the desktop launch command). If the issue persists, check that `/etc/xrdp/startwm.sh` ends with the correct `startxfce4` command.

**Q: Port 3389 is already in use?**
A: The pre-scan detects this automatically and switches to an available port during installation. You can also change it manually: `sudo bash install.sh port 3390`

**Q: Chinese characters display incorrectly?**
A: Reboot the system after installation to fully apply the locale configuration.

**Q: How to use in a container?**
A: The script auto-detects container environments and skips inapplicable steps such as display manager startup.

## License

MIT License
