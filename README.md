# 远程桌面一键安装维护脚本

[English](README_EN.md) | 中文

## 简介

一键部署 XRDP/VNC 远程桌面环境的 Bash 脚本，支持交互式菜单和命令行两种模式。自动完成系统预扫描、桌面环境安装、中文环境配置、用户管理等全流程操作。

## 支持系统

| 系统 | 版本 |
|------|------|
| Debian | 10, 11, 12, 13 |
| Ubuntu | 20.04, 22.04, 24.04 |

架构支持：x86_64、aarch64

## 功能特性

- **预扫描** — 安装前自动检测磁盘空间、内存、网络、端口占用、apt 状态等
- **模块化安装** — 按需选择组件，支持 XFCE4/LXQt/MATE 三种桌面
- **中文环境** — 自动配置 zh_CN.UTF-8 locale、中文字体、输入法
- **端口冲突自动处理** — 3389 被占用时自动寻找可用端口
- **用户管理** — 新增/删除/改密码，支持随机密码生成和 sudo 模式选择
- **防火墙配置** — UFW 自动开放/关闭远程桌面端口
- **Swap 管理** — 自定义大小创建/删除 Swap 文件
- **状态诊断** — 一键查看服务状态、端口监听、资源占用
- **模块化卸载** — 按组件单独卸载或一键全部卸载
- **容器兼容** — 自动检测 Docker/LXC 环境，跳过不适用步骤
- **并发保护** — 锁文件机制防止脚本重复执行
- **状态追踪** — JSON 状态文件记录已安装组件，支持断点续装

## 可安装组件

| 组件 | 说明 |
|------|------|
| 桌面环境 | XFCE4（推荐）/ LXQt / MATE |
| XRDP | 远程桌面协议（默认端口 3389） |
| VNC | TigerVNC 服务（端口 5901+） |
| Wine | Windows 兼容环境（核心版/完整版） |
| Bottles | Wine 图形化管理器（Flatpak） |
| Fcitx5 | 中文输入法（GTK/Qt 全支持） |

## 快速开始

```bash
# 下载脚本
wget https://raw.githubusercontent.com/zmrblog/onekey-install-xrdp/main/install.sh

# 交互模式（直接运行，进入菜单）
sudo bash install.sh

# 一键安装全部组件
sudo bash install.sh install --all

# 仅安装桌面 + XRDP
sudo bash install.sh install

# 安装指定组件
sudo bash install.sh install --desktop=xfce4 --vnc --wine=full --input-method
```

## 使用方式

### 交互菜单

直接运行 `sudo bash install.sh` 进入交互菜单：

```
==========================================
    远程桌面管理脚本 v2.0.0
==========================================

  1) 安装远程桌面（向导式选择组件）
  2) 用户管理（新增/删除/改密码/列表）
  3) 服务控制（启动/停止/重启/状态）
  4) 防火墙配置（开放/关闭端口）
  5) 调整分辨率/端口/Swap
  6) 状态诊断
  7) 模块化卸载
  8) 查看操作日志
  0) 退出
```

### 命令行

```bash
# 安装
sudo bash install.sh install [选项]
  --all               安装全部组件
  --xrdp              安装 XRDP
  --no-xrdp           不安装 XRDP
  --vnc               安装 VNC
  --wine=minimal      安装 Wine 核心
  --wine=full         安装 Wine 完整版
  --bottles           安装 Bottles
  --desktop=xfce4     选择桌面 (xfce4/lxqt/mate)
  --input-method      安装中文输入法
  --desktop-only      仅安装桌面环境

# 用户管理
sudo bash install.sh user add [用户名]       # 添加用户
sudo bash install.sh user del <用户名>       # 删除用户
sudo bash install.sh user passwd <用户名>    # 修改密码
sudo bash install.sh user list               # 列出用户

# 服务控制
sudo bash install.sh service xrdp restart

# 防火墙
sudo bash install.sh firewall open|close

# 分辨率/端口/Swap
sudo bash install.sh resolution 1920 1080 24
sudo bash install.sh port 3390
sudo bash install.sh swap

# 诊断
sudo bash install.sh status

# 卸载
sudo bash install.sh uninstall <组件>
  组件: xrdp, vnc, desktop, wine, input_method, bottles, all
```

## 连接方式

安装完成后，使用 Windows 远程桌面连接（mstsc.exe）：

1. 打开"远程桌面连接"
2. 输入服务器 IP 地址（默认端口 3389）
3. 输入创建的用户名和密码

如使用 VNC，连接地址为 `服务器IP:5901`。

## 文件路径

| 文件 | 路径 |
|------|------|
| 状态文件 | `/var/lib/rdp-setup/state.json` |
| 安装日志 | `/var/log/rdp-setup/setup.log` |
| XRDP 配置 | `/etc/xrdp/xrdp.ini` |
| 会话启动脚本 | `/etc/xrdp/startwm.sh` |
| VNC 启动包装器 | `/usr/local/bin/vnc-user-run` |
| Wine 启动包装器 | `/usr/local/bin/swine` |
| Bottles 启动包装器 | `/usr/local/bin/bottles` |
| 输入法环境变量 | `/etc/X11/Xsession.d/95fcitx5` |

## 系统要求

- Bash 4.0+
- Root 权限
- 至少 3 GB 磁盘空间（推荐 5 GB+）
- 至少 512 MB 内存（推荐 1 GB+）
- 网络连接（用于下载软件包）

## 常见问题

**Q: 连接后黑屏？**
A: 脚本已自动修复 `startwm.sh` 配置（注释掉默认 Xsession 执行，追加桌面启动命令）。如仍黑屏，检查 `/etc/xrdp/startwm.sh` 末尾是否有正确的 `startxfce4` 命令。

**Q: 端口 3389 被占用？**
A: 预扫描会自动检测，安装时自动切换到可用端口。也可手动修改：`sudo bash install.sh port 3390`

**Q: 中文显示乱码？**
A: 安装完成后重启系统以使 locale 配置完全生效。

**Q: 如何在容器中使用？**
A: 脚本自动检测容器环境，跳过显示管理器启动等不适用步骤。

## 许可证

MIT License
