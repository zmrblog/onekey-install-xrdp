# Remote Desktop One-Click Install & Maintenance Script

A modular remote desktop installation and management script for Debian/Ubuntu systems, supporting flexible installation and maintenance of XRDP, VNC, desktop environments, Wine, Chinese input methods, browsers, and more.

## Supported Systems

- Debian 10 / 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04
- FnNAS (FnOS) —— automatic adaptation and protection

## Features

### 1. System Pre-Scan
Automatic detection before installation:
- Disk space, memory, apt health status
- Network connectivity, port occupancy (3389)
- Existing desktop environments, existing XRDP, existing browsers
- Display manager, FnNAS-specific issues

### 2. Modular Installation
Wizard-style component selection with free combination:

| Component | Description |
|-----------|-------------|
| **XFCE4 Desktop** | Lightweight desktop, recommended |
| **LXQt Desktop** | Ultra-lightweight desktop |
| **MATE Desktop** | Medium resource usage |
| **XRDP** | Windows Remote Desktop Protocol (RDP) |
| **VNC** | TigerVNC remote desktop |
| **Wine Minimal** | Core components only |
| **Wine Full** | Includes winetricks |
| **Fcitx5 Input Method** | Chinese input method support |
| **Bottles** | GUI Wine manager (Flatpak) |
| **Browser** | Firefox ESR / Chromium / Midori (smart recommendation based on memory) |

### 3. FnNAS Automatic Adaptation
- Detect and fix trim source avahi package conflicts
- Fix dpkg half-configured packages, clean up corrupted liveupdate
- Temporarily disable update-initramfs (automatically restored after installation)
- Deploy UFW port protection (prevent trim updates from resetting firewall rules)
- Deploy trim update watchdog (prevent automatic updates from causing system freezes)

### 4. Firewall Configuration
- Open/close remote desktop ports
- View firewall status and listening ports
- **Open/close custom ports** (supports single port or port range)

### 5. User Management
- Add/delete users, change passwords
- Random password generation, sudo privilege configuration
- Automatic injection of Chinese environment variables

### 6. Service Control
- XRDP / XRDP-Sesman service management
- Start / Stop / Restart / Status / Enable / Disable

### 7. System Configuration
- Adjust XRDP resolution (720p / 1080p / 2K / Custom)
- Modify XRDP listening port (automatically updates firewall)
- Swap management (Create / Delete / View)

### 8. Status Diagnostics
- System information, XRDP service status, port listening
- Installed components, resource usage, recent logs

### 9. Safe Uninstall
Supports component-by-component or one-click uninstallation of all components. Desktop environment uninstallation thoroughly cleans up residual packages and startup commands.

## Quick Start

```bash
# Download the script
wget https://raw.githubusercontent.com/zmrblog/onekey-install-xrdp/main/install.sh

# Run (interactive menu mode)
sudo bash install.sh

# Or one-click install all components
sudo bash install.sh install --all
```

## CLI Usage

```bash
sudo bash install.sh [command] [options]
```

### Install Command
```bash
sudo bash install.sh install [options]
```

| Option | Description |
|--------|-------------|
| `--all` | Install all components (including Bottles) |
| `--xrdp` | Install XRDP |
| `--no-xrdp` | Do not install XRDP |
| `--vnc` | Install VNC |
| `--wine=minimal` | Install Wine core |
| `--wine=full` | Install Wine full version |
| `--bottles` | Install Bottles |
| `--desktop=xfce4` | Select desktop: xfce4 / lxqt / mate |
| `--input-method` | Install Chinese input method |
| `--browser=firefox-esr` | Install browser |
| `--browser=chromium` | Install Chromium |
| `--browser=midori` | Install Midori |
| `--desktop-only` | Install desktop environment only |
| `--no-desktop` | Do not install desktop environment |

### Other Commands
```bash
sudo bash install.sh user add [username]      # Add user
sudo bash install.sh user del <username>      # Delete user
sudo bash install.sh user passwd <username>   # Change password
sudo bash install.sh user list                # List users

sudo bash install.sh service xrdp status      # Service status
sudo bash install.sh firewall open            # Open firewall
sudo bash install.sh firewall close           # Close firewall
sudo bash install.sh resolution 1920 1080     # Set resolution
sudo bash install.sh port 3389                # Change port
sudo bash install.sh status                   # System diagnostics

sudo bash install.sh uninstall <component>    # Uninstall component
# Components: xrdp, vnc, desktop, wine, input_method, bottles, browser, all
```

## Notes

1. **Must run with root privileges**: `sudo bash install.sh`
2. **Bash version requirement**: Bash 4.0 or higher required
3. **FnNAS users**: The script automatically detects and deploys system protection measures, no manual configuration needed after installation
4. **Port conflicts**: If port 3389 is occupied, the script automatically finds the next available port
5. **Desktop environment conflicts**: If another desktop is already installed, the script will prompt and allow coexistence or skip

## File Locations

| File/Directory | Description |
|----------------|-------------|
| `/var/lib/rdp-setup/state.json` | Installation state record |
| `/var/log/rdp-setup/setup.log` | Operation log |
| `/etc/xrdp/xrdp.ini` | XRDP configuration file |
| `/etc/xrdp/startwm.sh` | XRDP session startup script |
| `/usr/local/bin/ufw-protect.sh` | FnNAS UFW protection script |
| `/usr/local/bin/trim-update-guard.sh` | FnNAS update watchdog |

## License

MIT License
