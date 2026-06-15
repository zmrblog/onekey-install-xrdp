# 远程桌面一键安装维护脚本

一个用于 Debian/Ubuntu 系统的模块化远程桌面安装与管理脚本，支持 XRDP、VNC、桌面环境、Wine、中文输入法、浏览器等组件的灵活安装与维护。

## 支持系统

- Debian 10 / 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04
- 飞牛 NAS (FnOS) —— 自动适配与保护

## 功能特性

### 1. 系统预扫描
安装前自动检测：
- 磁盘空间、内存、apt 健康状态
- 网络连接、端口占用（3389）
- 已有桌面环境、已有 XRDP、已有浏览器
- 显示管理器、飞牛 NAS 特定问题

### 2. 模块化安装
向导式组件选择，支持自由组合：

| 组件 | 说明 |
|------|------|
| **XFCE4 桌面** | 轻量桌面，推荐 |
| **LXQt 桌面** | 极轻量桌面 |
| **MATE 桌面** | 中等资源占用 |
| **XRDP** | Windows 远程桌面协议（RDP） |
| **VNC** | TigerVNC 远程桌面 |
| **Wine 精简版** | 仅核心组件 |
| **Wine 完整版** | 含 winetricks |
| **Fcitx5 输入法** | 中文输入法支持 |
| **Bottles** | 图形化 Wine 管理器（Flatpak） |
| **浏览器** | Firefox ESR / Chromium / Midori（根据内存智能推荐） |

### 3. 飞牛 NAS 自动适配
- 检测并修复 trim 源 avahi 包冲突
- 修复 dpkg 半配置包、清理损坏的 liveupdate
- 临时禁用 update-initramfs（安装后自动恢复）
- 部署 UFW 端口保护（防止 trim 更新重置防火墙）
- 部署 trim 更新看门狗（防止自动更新导致系统假死）

### 4. 防火墙配置
- 开放/关闭远程桌面端口
- 查看防火墙状态和监听端口
- **开放/关闭自定义端口**（支持单个端口或端口区间）

### 5. 用户管理
- 新增/删除用户、修改密码
- 随机密码生成、sudo 权限配置
- 中文环境变量自动注入

### 6. 服务控制
- XRDP / XRDP-Sesman 服务管理
- 启动 / 停止 / 重启 / 状态 / 启用 / 禁用

### 7. 系统配置
- 调整 XRDP 分辨率（720p / 1080p / 2K / 自定义）
- 修改 XRDP 监听端口（自动更新防火墙）
- Swap 管理（创建/删除/查看）

### 8. 状态诊断
- 系统信息、XRDP 服务状态、端口监听
- 已安装组件、资源使用、最近日志

### 9. 安全卸载
支持逐个或一键卸载所有组件，桌面环境卸载会彻底清理残留包和启动命令。

## 快速开始

```bash
# 下载脚本
wget https://raw.githubusercontent.com/zmrblog/onekey-install-xrdp/main/install.sh

# 运行（交互菜单模式）
sudo bash install.sh

# 或一键安装全部组件
sudo bash install.sh install --all
```

## CLI 用法

```bash
sudo bash install.sh [命令] [选项]
```

### 安装命令
```bash
sudo bash install.sh install [选项]
```

| 选项 | 说明 |
|------|------|
| `--all` | 安装全部组件（含 Bottles） |
| `--xrdp` | 安装 XRDP |
| `--no-xrdp` | 不安装 XRDP |
| `--vnc` | 安装 VNC |
| `--wine=minimal` | 安装 Wine 核心 |
| `--wine=full` | 安装 Wine 完整版 |
| `--bottles` | 安装 Bottles |
| `--desktop=xfce4` | 选择桌面环境：xfce4 / lxqt / mate |
| `--input-method` | 安装中文输入法 |
| `--browser=firefox-esr` | 安装浏览器 |
| `--browser=chromium` | 安装 Chromium |
| `--browser=midori` | 安装 Midori |
| `--desktop-only` | 仅安装桌面环境 |
| `--no-desktop` | 不安装桌面环境 |

### 其他命令
```bash
sudo bash install.sh user add [用户名]      # 添加用户
sudo bash install.sh user del <用户名>      # 删除用户
sudo bash install.sh user passwd <用户名>   # 修改密码
sudo bash install.sh user list              # 列出用户

sudo bash install.sh service xrdp status    # 服务状态
sudo bash install.sh firewall open          # 开放防火墙
sudo bash install.sh firewall close         # 关闭防火墙
sudo bash install.sh resolution 1920 1080   # 设置分辨率
sudo bash install.sh port 3389              # 修改端口
sudo bash install.sh status                 # 系统诊断

sudo bash install.sh uninstall <组件>       # 卸载组件
# 组件: xrdp, vnc, desktop, wine, input_method, bottles, browser, all
```

## 注意事项

1. **必须使用 root 权限运行**：`sudo bash install.sh`
2. **Bash 版本要求**：需要 Bash 4.0 或更高版本
3. **飞牛 NAS 用户**：脚本会自动检测并部署系统保护措施，安装完成后无需手动配置
4. **端口冲突**：如果 3389 端口被占用，脚本会自动寻找下一个可用端口
5. **桌面环境冲突**：如果系统已安装其他桌面，脚本会提示并允许共存或跳过

## 文件位置

| 文件/目录 | 说明 |
|-----------|------|
| `/var/lib/rdp-setup/state.json` | 安装状态记录 |
| `/var/log/rdp-setup/setup.log` | 操作日志 |
| `/etc/xrdp/xrdp.ini` | XRDP 配置文件 |
| `/etc/xrdp/startwm.sh` | XRDP 会话启动脚本 |
| `/usr/local/bin/ufw-protect.sh` | 飞牛 UFW 保护脚本 |
| `/usr/local/bin/trim-update-guard.sh` | 飞牛更新看门狗 |

## 开源协议

MIT License
