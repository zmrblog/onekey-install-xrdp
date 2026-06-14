# 远程桌面一键安装脚本 v2.0.0

一键在 Debian/Ubuntu 系统上安装和配置 XRDP 远程桌面环境，支持飞牛 NAS (fnOS) 适配。

## 功能特性

- **模块化安装** — 自由选择桌面环境、远程协议、可选软件
- **飞牛 NAS 适配** — 自动修复 dpkg 损坏、部署看门狗防止 trim 更新导致系统假死
- **交互/非交互双模式** — 无参数进入菜单，带参数自动执行
- **完整生命周期管理** — 安装、用户管理、服务控制、配置调整、模块化卸载

## 支持系统

| 系统 | 版本 |
|------|------|
| Debian | 10 / 11 / 12 / 13 |
| Ubuntu | 20.04 / 22.04 / 24.04 |
| 飞牛 NAS | 全版本 |

架构：x86_64 / aarch64

## 快速开始

```bash
# 下载脚本
wget https://raw.githubusercontent.com/zmrblog/onekey-install-xrdp/main/install.sh

# 赋予执行权限
chmod +x install.sh

# 交互式安装（推荐）
sudo ./install.sh

# 一键默认安装（XFCE4 + XRDP）
sudo ./install.sh install

# 指定组件安装
sudo ./install.sh install --desktop=mate --wine=full --input-method
```

## 安装组件一览

| 编号 | 组件 | 说明 |
|------|------|------|
| 1 | XFCE4 桌面 | 轻量，推荐 |
| 2 | LXQt 桌面 | 极轻量 |
| 3 | MATE 桌面 | 中等资源占用 |
| 0 | 跳过桌面 | 使用已有桌面 |
| 4 | XRDP 远程桌面 | 推荐 |
| 5 | VNC 远程桌面 | 可选 |
| 6 | Wine 精简版 | 仅核心 |
| 7 | Wine 完整版 | 含 winetricks |
| 8 | Fcitx5 中文输入法 | 可选 |
| 9 | Bottles | 图形化 Wine 管理 |

交互式安装时直接输入编号，如 `0,4,7,8`。

## 主菜单

```
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

## CLI 命令行参数

### 顶级命令

| 命令 | 说明 |
|------|------|
| `install [选项]` | 安装远程桌面 |
| `user add [用户名]` | 添加用户 |
| `user del <用户名>` | 删除用户 |
| `user passwd <用户名>` | 修改密码 |
| `user list` | 列出用户 |
| `service <服务> <操作>` | 服务控制 |
| `firewall <open\|close>` | 防火墙配置 |
| `resolution <宽> <高> [色彩深度]` | 调整分辨率 |
| `port <端口号>` | 修改 XRDP 端口 |
| `status` / `diag` | 系统诊断 |
| `swap` | Swap 管理 |
| `uninstall <组件>` | 卸载组件 |

### install 子选项

| 选项 | 说明 |
|------|------|
| `--all` | 安装全部组件 |
| `--xrdp` | 安装 XRDP |
| `--no-xrdp` | 不安装 XRDP |
| `--vnc` | 安装 VNC |
| `--wine=minimal` | Wine 精简版 |
| `--wine=full` | Wine 完整版 |
| `--input-method` | 安装 Fcitx5 中文输入法 |
| `--bottles` | 安装 Bottles |
| `--desktop=xfce4` | XFCE4 桌面 |
| `--desktop=lxqt` | LXQt 桌面 |
| `--desktop=mate` | MATE 桌面 |
| `--desktop-only` | 仅安装桌面 |
| `--no-desktop` | 不安装桌面 |

### uninstall 可卸载组件

`xrdp` / `vnc` / `desktop` / `wine` / `input_method` / `bottles` / `all`

## 配置选项

### 分辨率

预设：720p / 1080p / 2K，支持自定义宽高和色彩深度（默认 24 位，最大 32 位）。

```bash
sudo ./install.sh resolution 1920 1080 24
```

### 端口

默认 3389，修改后自动更新防火墙规则并重启服务。

```bash
sudo ./install.sh port 3390
```

### Swap

支持创建、删除、查看状态，自动写入 /etc/fstab 持久化。

## 飞牛 NAS 专属功能

### 安装前自动修复

1. **清理 liveupdate 损坏的 dpkg 元数据** — 不影响二进制文件
2. **修复 dpkg 半配置包** — 处理触发器 + 重新配置
3. **临时禁用 update-initramfs** — 防止安装过程中 initramfs 更新崩溃

### trim 源 avahi 冲突处理

飞牛 trim 源的 avahi 包版本号与 Debian 标准版不兼容，脚本自动写入 apt pin 降低优先级并强制降级。

### 安装后看门狗

| 脚本 | 功能 | 检查频率 |
|------|------|---------|
| `ufw-protect.sh` | 保护 Web 端口和 3389，防止 trim 更新重置防火墙 | 每 5 分钟 |
| `trim-update-guard.sh` | 监控 liveupdate 进程，防止自动更新导致系统假死 | 每 1 分钟 |

手动允许更新：`rm /tmp/trim_update_guarded`

## 预扫描

安装前自动检查系统环境：

| 检查项 | 说明 |
|--------|------|
| apt 状态 | 无锁、依赖正常 |
| 磁盘空间 | 最低 3 GB，建议 5 GB+ |
| 内存 | 最低 512 MB，建议 1 GB+ |
| 网络连接 | 可访问外网 |
| 端口 3389 | 是否被占用 |
| 已有桌面环境 | 检测冲突 |
| 已有 XRDP | 检测版本 |
| 显示管理器 | 兼容性检查 |

飞牛系统额外检查：dpkg 半配置包、liveupdate 包状态、initramfs 可用性。

## 其他特性

- **并发保护** — 基于 mkdir 原子操作的目录锁
- **容器适配** — 检测 Docker/LXC，跳过显示管理器启动
- **国内镜像源** — apt 失败时自动切换阿里云/中科大/清华源
- **DNS 预检** — 检测 DNS 解析能力，失败时提供修复命令
- **状态文件引擎** — JSON 记录安装状态，支持组件检测回退
- **安全卸载** — 彻底清理 metapackage、autoremove、残留包和配置

## 前置要求

- Root 权限
- Bash 4.0+
- apt 包管理器
- 磁盘空间 >= 3 GB
- 内存 >= 512 MB
- 网络连接

## 连接方式

安装完成后，使用 Windows 远程桌面连接 (mstsc)：

```
地址: <服务器IP>:3389
账号: root 或创建的用户
密码: 对应密码
```

## 许可证

MIT License
