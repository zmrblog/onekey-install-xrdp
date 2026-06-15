#!/bin/bash
# =============================================================================
# 远程桌面一键安装维护脚本 v2.0
# 支持: Debian 10/11/12, Ubuntu 20.04/22.04/24.04
# 功能: 模块化安装 / 预扫描 / 中文环境 / 安全卸载 / CLI + 交互菜单
# =============================================================================

set -uo pipefail

# =============================================================================
# 0. 基础配置
# =============================================================================

SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="远程桌面管理脚本"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# 禁用 systemd 命令的自动颜色输出，避免在 xrdp/不支持 ANSI 的终端中出现乱码
export SYSTEMD_COLORS=false

# 路径常量
readonly STATE_DIR="/var/lib/rdp-setup"
readonly STATE_FILE="${STATE_DIR}/state.json"
readonly LOG_DIR="/var/log/rdp-setup"
readonly LOG_FILE="${LOG_DIR}/setup.log"
readonly LOCK_FILE="${STATE_DIR}/install.lock"

# 全局变量
declare -A STATE      # 状态关联数组
OS_ID=""              # 系统ID: ubuntu / debian
OS_VERSION_ID=""      # 版本号: 20.04 / 12
OS_CODENAME=""        # 代号: focal / bookworm
ARCH=""               # 架构: x86_64 / aarch64
INTERACTIVE=true      # 是否交互模式
DESKTOP_CHOICE="xfce4"  # 桌面选择: xfce4 / lxqt / mate
XRDP_PORT=3389          # XRDP 监听端口（如冲突则自动调整）
IS_FNOS=false           # 是否为飞牛 NAS 系统
LOCK_DIR=""             # 锁目录（由 acquire_lock 设置）

# =============================================================================
# 0.1 日志与输出工具
# =============================================================================

init_directories() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$STATE_DIR" 2>/dev/null || true
}

log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"

    case "$level" in
        INFO)    echo -e "${BLUE}[信息]${NC} $msg" ;;
        SUCCESS) echo -e "${GREEN}[成功]${NC} $msg" ;;
        WARN)    echo -e "${YELLOW}[警告]${NC} $msg" ;;
        ERROR)   echo -e "${RED}[错误]${NC} $msg" ;;
        *)       echo -e "[$level] $msg" ;;
    esac
}

info()    { log "INFO" "$@"; }
success() { log "SUCCESS" "$@"; }
warn()    { log "WARN" "$@"; }
error()   { log "ERROR" "$@"; }

# 输出分隔线
hr() {
    printf '%*s\n' "60" '' | tr ' ' '='
}

# 输入确认
confirm() {
    local prompt="${1:-是否继续?}"
    local default="${2:-y}"

    if [[ "$INTERACTIVE" != "true" ]]; then
        return 0
    fi

    if [[ "$default" == "y" ]]; then
        read -r -p "${prompt} [Y/n]: " answer
        [[ "$answer" =~ ^[Nn]$ ]] && return 1 || return 0
    else
        read -r -p "${prompt} [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] && return 0 || return 1
    fi
}

# 等待回车
pause() {
    if [[ "$INTERACTIVE" == "true" ]]; then
        read -r -p "按回车继续..."
    fi
}

# 安全执行命令
safe_exec() {
    local desc="$1"; shift
    local tmpfile
    tmpfile="$(mktemp)"
    info "正在执行: $desc"
    if "$@" &>"$tmpfile"; then
        success "$desc - 完成"
        rm -f "$tmpfile"
        return 0
    else
        error "$desc - 失败"
        # 显示最后 20 行错误输出，帮助定位问题
        if [[ -s "$tmpfile" ]]; then
            warn "--- 错误详情（最后20行）---"
            # 逐行通过 warn 输出，确保错误内容写入 LOG_FILE（不要直接 >&2，会绕过日志记录）
            tail -20 "$tmpfile" | while IFS= read -r line; do
                warn "$line"
            done
            warn "--- 错误详情结束 ---"
        fi
        rm -f "$tmpfile"
        return 1
    fi
}

# =============================================================================
# 0.2 OS 检测
# =============================================================================

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "无法检测操作系统: /etc/os-release 不存在"
        return 1
    fi

    # 读取 OS 信息（逐字段解析，避免 source 不可信文件的安全风险）
    OS_ID="$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '\"')"
    OS_VERSION_ID="$(grep -oP '^VERSION_ID=\K.*' /etc/os-release | tr -d '\"')"
    OS_CODENAME="$(grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release | tr -d '\"')"
    OS_CODENAME="${OS_CODENAME:-unknown}"
    ARCH="$(uname -m)"

    info "检测到系统: $OS_ID $OS_VERSION_ID ($OS_CODENAME) 架构: $ARCH"

    case "$OS_ID" in
        ubuntu|debian)
            ;;
        *)
            error "不支持的操作系统: $OS_ID"
            echo "本脚本仅支持 Debian 和 Ubuntu 系统。"
            return 1
            ;;
    esac

    # 检查版本范围
    case "$OS_ID" in
        ubuntu)
            case "$OS_VERSION_ID" in
                20.04|22.04|24.04) ;;
                *) warn "Ubuntu $OS_VERSION_ID 未经测试，可能出现兼容性问题";;
            esac
            ;;
        debian)
            case "$OS_VERSION_ID" in
                10|11|12|13) ;;
                10.*|11.*|12.*|13.*) warn "Debian $OS_VERSION_ID 未经测试，可能出现兼容性问题";;
                *) warn "Debian $OS_VERSION_ID 未经测试，可能出现兼容性问题";;
            esac
            ;;
    esac

    return 0
}

detect_arch() {
    case "$ARCH" in
        x86_64|aarch64) return 0 ;;
        *)
            warn "架构 $ARCH 可能缺少某些软件包支持"
            return 1
            ;;
    esac
}

# 检测 systemd 是否可用
has_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl &>/dev/null
}

# 检测容器环境
is_container() {
    [[ -f /.dockerenv ]] || grep -qE 'docker|lxc' /proc/1/cgroup 2>/dev/null
}

# =============================================================================
# 0.3 状态文件引擎
# =============================================================================

init_state() {
    mkdir -p "$STATE_DIR"
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'STATEEOF'
{
  "installer_version": "",
  "installed_at": "",
  "status": "empty",
  "components": {}
}
STATEEOF
        info "状态文件已初始化: $STATE_FILE"
    fi
}

read_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        init_state
        return 1
    fi

    if ! STATE_TEXT="$(cat "$STATE_FILE" 2>/dev/null)"; then
        warn "状态文件读取失败，将重新初始化"
        init_state
        return 1
    fi
    return 0
}

write_state() {
    local key="$1"; shift
    local value="$*"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%:z')"

    mkdir -p "$STATE_DIR"

    if command -v python3 &>/dev/null; then
        _STATE_KEY="$key" _STATE_VALUE="$value" _STATE_TS="$ts" _STATE_VER="$SCRIPT_VERSION" \
        python3 -c "
import json, os, sys
state_file = os.environ.get('STATE_FILE', '/var/lib/rdp-setup/state.json')
try:
    with open(state_file) as f:
        data = json.load(f)
except Exception:
    data = {'installer_version': '', 'installed_at': '', 'status': 'empty', 'components': {}, 'users_created': []}
k = os.environ['_STATE_KEY']
v = os.environ['_STATE_VALUE']
data[k] = v
data['installer_version'] = os.environ['_STATE_VER']
with open(state_file, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
" 2>/dev/null
    else
        sed -i "s|\"$key\": \".*\"|\"$key\": \"$value\"|" "$STATE_FILE" 2>/dev/null || true
    fi
}

mark_component_installed() {
    local component="$1"; shift
    local packages="$*"
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%:z')"

    if command -v python3 &>/dev/null; then
        _STATE_COMP="$component" _STATE_PKGS="$packages" _STATE_TS="$ts" _STATE_VER="$SCRIPT_VERSION" \
        python3 -c "
import json, os, sys
state_file = os.environ.get('STATE_FILE', '/var/lib/rdp-setup/state.json')
try:
    with open(state_file) as f:
        data = json.load(f)
except Exception:
    data = {'installer_version': '', 'installed_at': '', 'status': 'empty', 'components': {}, 'users_created': []}
comp = os.environ['_STATE_COMP']
pkgs = os.environ['_STATE_PKGS'].split()
data['components'][comp] = {'packages': pkgs, 'installed_at': os.environ['_STATE_TS']}
data['status'] = 'installed'
data['installer_version'] = os.environ['_STATE_VER']
with open(state_file, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"
    else
        warn "未检测到 python3，状态记录可能不完整"
    fi
}

mark_component_removed() {
    local component="$1"

    if command -v python3 &>/dev/null; then
        _STATE_COMP="$component" \
        python3 -c "
import json, os
state_file = os.environ.get('STATE_FILE', '/var/lib/rdp-setup/state.json')
try:
    with open(state_file) as f:
        data = json.load(f)
except Exception:
    # 状态文件不存在，跳过
    exit(0)
comp = os.environ['_STATE_COMP']
if comp == 'all':
    data['components'] = {}
    data['status'] = 'empty'
    data['installed_at'] = ''
else:
    data['components'].pop(comp, None)
    data['status'] = 'installed' if data['components'] else 'empty'
with open(state_file, 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
"
    fi
}

# 组件到 dpkg 包的映射（用于状态文件不存在时的回退检测）
_COMPONENT_DPKG_MAP="desktop:xfce4 xrdp:xrdp vnc:tigervnc-standalone-server wine:wine input_method:fcitx5"
# 组件到 flatpak 应用的映射（Bottles 等通过 Flatpak 安装的组件）
_COMPONENT_FLATPAK_MAP="bottles:com.usebottles.bottles"

_dpkg_component_check() {
    local component="$1"
    local pkg

    # 桌面组件：检查多种桌面环境
    if [[ "$component" == "desktop" ]]; then
        for de_pkg in xfce4 lxqt mate-desktop-environment; do
            if dpkg -l "$de_pkg" 2>/dev/null | grep -q '^ii'; then
                return 0
            fi
        done
        return 1
    fi

    pkg="$(echo "$_COMPONENT_DPKG_MAP" | tr ' ' '\n' | grep "^${component}:" | cut -d: -f2)"
    [[ -z "$pkg" ]] && return 1

    dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'
}

get_installed_components() {
    # 状态文件存在时以其为准，不回退到 dpkg（避免检测到其他脚本安装的组件）
    if [[ -f "$STATE_FILE" ]] && command -v python3 &>/dev/null; then
        local result
        result="$(_PY_STATE_FILE="$STATE_FILE" python3 -c "
import json, os
try:
    data = json.load(open(os.environ['_PY_STATE_FILE']))
    for k in data.get('components', {}):
        print(k)
except:
    pass
" 2>/dev/null)"
        echo "$result"
        return 0
    fi

    # 无状态文件时回退：通过 dpkg 检测系统实际安装的组件
    local desktop_detected=false
    local entry pkg
    for entry in $_COMPONENT_DPKG_MAP; do
        local comp="${entry%%:*}"
        local pkg="${entry#*:}"

        # 桌面组件：检查多种桌面环境
        if [[ "$comp" == "desktop" ]]; then
            if [[ "$desktop_detected" == "false" ]]; then
                for de_pkg in xfce4 lxqt mate-desktop-environment; do
                    if dpkg -l "$de_pkg" 2>/dev/null | grep -q '^ii'; then
                        echo "$comp"
                        desktop_detected=true
                        break
                    fi
                done
            fi
            continue
        fi

        if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
            echo "$comp"
        fi
    done

    # 回退：通过 flatpak 检测
    if command -v flatpak &>/dev/null; then
        for entry in $_COMPONENT_FLATPAK_MAP; do
            local comp="${entry%%:*}"
            local app="${entry#*:}"
            if flatpak list 2>/dev/null | grep -qi "$app"; then
                echo "$comp"
            fi
        done
    fi
}

# 检查特定组件是否已安装（状态文件 + dpkg + flatpak 回退）
is_component_installed() {
    local component="$1"

    # 状态文件存在时以其为准，不回退到 dpkg（避免检测到其他脚本安装的组件）
    if [[ -f "$STATE_FILE" ]] && command -v python3 &>/dev/null; then
        if _PY_STATE_FILE="$STATE_FILE" _PY_COMP="$component" python3 -c "
import json, os, sys
data = json.load(open(os.environ['_PY_STATE_FILE']))
if os.environ['_PY_COMP'] in data.get('components', {}):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
            return 0
        else
            # 状态文件存在但组件不在其中，视为未安装
            return 1
        fi
    fi

    # 无状态文件时回退：dpkg 检测
    if _dpkg_component_check "$component"; then
        return 0
    fi

    # 回退：flatpak 检测
    if command -v flatpak &>/dev/null; then
        local app
        app="$(echo "$_COMPONENT_FLATPAK_MAP" | tr ' ' '\n' | grep "^${component}:" | cut -d: -f2)"
        if [[ -n "$app" ]] && flatpak list 2>/dev/null | grep -qi "$app"; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# 0.4 锁文件管理（防止并发执行）
# =============================================================================

acquire_lock() {
    LOCK_DIR="${LOCK_FILE}.dir"
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local pid
        pid="$(cat "${LOCK_DIR}/pid" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error "脚本已在运行中 (PID: $pid)"
            return 1
        fi
        # 过期锁，清理后重试
        rm -rf "$LOCK_DIR"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            error "无法获取锁"
            return 1
        fi
    fi
    echo $$ > "${LOCK_DIR}/pid"
    trap 'rm -rf "${LOCK_FILE}.dir" 2>/dev/null' EXIT INT TERM
    return 0
}

# =============================================================================
# 0.5 前置检查（脚本启动时执行）
# =============================================================================

preflight_check() {
    init_directories

    # root 检查
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo -e "${RED}请使用 root 权限运行此脚本：sudo bash $0${NC}"
        exit 1
    fi

    # bash 版本检查
    if [[ "${BASH_VERSINFO[0]:-3}" -lt 4 ]]; then
        error "需要 Bash 4.0 或更高版本，当前: ${BASH_VERSION}"
        exit 1
    fi

    # OS 检测
    if ! detect_os; then
        exit 1
    fi

    # 架构检测
    detect_arch

    # 锁
    if ! acquire_lock; then
        exit 1
    fi

    # 状态文件
    init_state
}

# =============================================================================
# 1. 预扫描模块
# =============================================================================

# 全局扫描结果
declare -A SCAN_RESULT
SCAN_TOTAL=0
SCAN_PASS=0
SCAN_WARN=0
SCAN_FAIL=0

scan_record() {
    local name="$1"; local status="$2"; local detail="${3:-}"
    SCAN_RESULT["$name"]="$status"
    SCAN_TOTAL=$((SCAN_TOTAL + 1))

    case "$status" in
        pass) SCAN_PASS=$((SCAN_PASS + 1))
              echo -e "  ${GREEN}[通过]${NC} $name" ;;
        warn) SCAN_WARN=$((SCAN_WARN + 1))
              echo -e "  ${YELLOW}[警告]${NC} $name — $detail" ;;
        fail) SCAN_FAIL=$((SCAN_FAIL + 1))
              echo -e "  ${RED}[失败]${NC} $name — $detail" ;;
    esac
}

# 检查硬盘空间
scan_disk() {
    local avail
    avail="$(df -k / --output=avail 2>/dev/null | tail -1 | tr -d ' ')"
    if [[ -z "$avail" ]]; then
        avail="$(df -k / | awk 'NR==2 {print $4}')"
    fi

    if [[ "$avail" -gt 5242880 ]]; then       # > 5 GB
        scan_record "磁盘空间" pass
    elif [[ "$avail" -gt 3145728 ]]; then     # > 3 GB
        scan_record "磁盘空间" warn "可用空间 $(($avail / 1024)) MB，建议至少 5 GB"
    else
        scan_record "磁盘空间" fail "可用空间仅 $(($avail / 1024)) MB，需要至少 3 GB"
    fi
}

# 检查内存
scan_memory() {
    local mem_kb
    mem_kb="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')"
    if [[ -z "$mem_kb" ]]; then
        scan_record "内存" warn "无法读取内存信息"
    elif [[ "$mem_kb" -gt 1048576 ]]; then    # > 1 GB
        scan_record "内存" pass
    elif [[ "$mem_kb" -gt 524288 ]]; then      # > 512 MB
        scan_record "内存" warn "内存 $(($mem_kb / 1024)) MB，桌面环境可能较慢"
    else
        scan_record "内存" fail "内存仅 $(($mem_kb / 1024)) MB，不足以运行桌面环境"
    fi
}

# 检查 apt 健康状态
scan_apt() {
    # 检查是否有锁
    if command -v fuser &>/dev/null; then
        if fuser /var/lib/dpkg/lock-frontend &>/dev/null 2>&1; then
            scan_record "apt 状态" fail "dpkg 前端锁被占用，可能正在安装其他软件"
            return
        fi

        if fuser /var/lib/apt/lists/lock &>/dev/null 2>&1; then
            scan_record "apt 状态" fail "apt 列表锁被占用"
            return
        fi
    elif [[ -f /var/lib/dpkg/lock-frontend ]]; then
        scan_record "apt 状态" warn "无法确认 dpkg 锁状态（fuser 未安装），但锁文件存在"
    fi

    if ! apt-get check &>/dev/null; then
        scan_record "apt 状态" fail "依赖关系存在问题，请先运行 apt-get install -f"
        return
    fi

    scan_record "apt 状态" pass
}

# 检查已安装的桌面环境
scan_existing_desktop() {
    local desktops_found=()

    dpkg -l xfce4 2>/dev/null | grep -q '^ii' && desktops_found+=("XFCE4")
    dpkg -l lxqt 2>/dev/null | grep -q '^ii' && desktops_found+=("LXQt")
    dpkg -l gnome-shell 2>/dev/null | grep -q '^ii' && desktops_found+=("GNOME")
    dpkg -l plasma-desktop 2>/dev/null | grep -q '^ii' && desktops_found+=("KDE Plasma")
    dpkg -l lxde-core 2>/dev/null | grep -q '^ii' && desktops_found+=("LXDE")
    dpkg -l mate-desktop-environment 2>/dev/null | grep -q '^ii' && desktops_found+=("MATE")

    if [[ ${#desktops_found[@]} -eq 0 ]]; then
        scan_record "已有桌面环境" pass
    else
        local list
        list="$(IFS=', '; echo "${desktops_found[*]}")"
        scan_record "已有桌面环境" warn "检测到已安装: $list"
    fi
}

# 检查已有 XRDP
scan_existing_xrdp() {
    if dpkg -l xrdp 2>/dev/null | grep -q '^ii'; then
        local xrdp_ver
        xrdp_ver="$(dpkg -l xrdp 2>/dev/null | grep '^ii' | awk '{print $3}')"
        scan_record "已有 XRDP" warn "已安装版本 $xrdp_ver，将跳过或升级"
    else
        scan_record "已有 XRDP" pass
    fi
}

# 检查已有浏览器
scan_existing_browser() {
    local browsers_found=()

    if command -v firefox-esr &>/dev/null || command -v firefox &>/dev/null; then
        browsers_found+=("Firefox")
    fi
    if command -v chromium &>/dev/null || command -v chromium-browser &>/dev/null; then
        browsers_found+=("Chromium")
    fi
    if command -v midori &>/dev/null; then
        browsers_found+=("Midori")
    fi

    if [[ ${#browsers_found[@]} -eq 0 ]]; then
        scan_record "已有浏览器" pass
    else
        local list
        list="$(IFS=', '; echo "${browsers_found[*]}")"
        scan_record "已有浏览器" warn "检测到已安装: $list"
    fi
}

# 检查端口占用
scan_ports() {
    local port_3389
    if command -v ss &>/dev/null; then
        port_3389="$(ss -tlnp 2>/dev/null | grep ':3389 ' || true)"
    elif command -v netstat &>/dev/null; then
        port_3389="$(netstat -tlnp 2>/dev/null | grep ':3389 ' || true)"
    else
        port_3389=""
    fi

    if [[ -z "$port_3389" ]]; then
        scan_record "端口 3389" pass
    elif echo "$port_3389" | grep -q 'xrdp'; then
        scan_record "端口 3389" warn "已被 xrdp 占用（正常）"
    else
        local proc_name
        proc_name="$(echo "$port_3389" | awk '{print $NF}' | head -1)"
        # 寻找下一个可用端口
        local alt_port=3390
        while ss -tlnp 2>/dev/null | grep -q ":${alt_port} "; do
            alt_port=$((alt_port + 1))
        done
        XRDP_PORT="$alt_port"
        scan_record "端口 3389" warn "已被 $proc_name 占用，将使用端口 $XRDP_PORT"
    fi
}

# 检查现有显示管理器
scan_display_manager() {
    local dm_found=""
    for dm in lightdm gdm3 sddm lxdm xdm; do
        if dpkg -l "$dm" 2>/dev/null | grep -q '^ii'; then
            dm_found="$dm"
            break
        fi
    done

    if [[ -z "$dm_found" ]]; then
        scan_record "显示管理器" pass
    elif [[ "$dm_found" == "lightdm" ]]; then
        scan_record "显示管理器" pass
    else
        scan_record "显示管理器" warn "检测到 $dm_found，将安装 lightdm 替代（可能影响登录界面）"
    fi
}

# 检查网络连接
scan_network() {
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        scan_record "网络连接" pass
    else
        scan_record "网络连接" warn "无法连接外网，部分软件包可能下载失败"
    fi
}

# 检查 sudo 包
scan_sudo() {
    if command -v sudo &>/dev/null; then
        scan_record "sudo" pass
    else
        scan_record "sudo" warn "未安装 sudo，将自动安装"
    fi
}

# 主预扫描函数
run_prescan() {
    echo ""
    hr
    echo -e "${BOLD}系统预扫描报告${NC}"
    hr

    scan_apt
    scan_disk
    scan_memory
    scan_network
    scan_sudo
    scan_ports
    scan_existing_desktop
    scan_existing_xrdp
    scan_existing_browser
    scan_display_manager

    # 飞牛 NAS 额外扫描
    detect_fnos
    scan_fnos_issues

    hr
    echo -e "扫描结果: ${GREEN}通过 $SCAN_PASS${NC}  ${YELLOW}警告 $SCAN_WARN${NC}  ${RED}失败 $SCAN_FAIL${NC}"
    hr
    echo ""

    if [[ "$SCAN_FAIL" -gt 0 ]]; then
        error "存在 $SCAN_FAIL 项严重问题，无法继续安装。请解决后再试。"
        return 1
    fi

    if [[ "$SCAN_WARN" -gt 0 ]]; then
        warn "存在 $SCAN_WARN 项警告，建议确认后再继续。"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否继续安装?" "y"; then
                info "已取消安装"
                return 1
            fi
        else
            info "非交互模式，自动继续..."
        fi
    fi

    return 0
}

# =============================================================================
# 1.5 国内镜像源切换
# =============================================================================

generate_sources_list() {
    local mirror="$1"
    local codename="$2"
    local id="$3"

    if [[ "$id" == "ubuntu" ]]; then
        cat <<EOF
deb http://${mirror}/ubuntu/ ${codename} main restricted universe multiverse
deb http://${mirror}/ubuntu/ ${codename}-updates main restricted universe multiverse
deb http://${mirror}/ubuntu/ ${codename}-security main restricted universe multiverse
deb http://${mirror}/ubuntu/ ${codename}-backports main restricted universe multiverse
EOF
    else
        # debian
        cat <<EOF
deb http://${mirror}/debian/ ${codename} main contrib non-free non-free-firmware
deb http://${mirror}/debian-security/ ${codename}-security main contrib non-free non-free-firmware
deb http://${mirror}/debian/ ${codename}-updates main contrib non-free non-free-firmware
EOF
    fi
}

test_mirror() {
    local mirror="$1"
    local url
    if [[ "$OS_ID" == "ubuntu" ]]; then
        url="http://${mirror}/ubuntu/dists/${OS_CODENAME}/InRelease"
    else
        url="http://${mirror}/debian/dists/${OS_CODENAME}/InRelease"
    fi
    wget -q --timeout=5 --tries=1 "$url" -O /dev/null 2>/dev/null
}

switch_to_china_mirror() {
    warn "检测到 apt 源不可用或速度过慢，尝试切换到国内镜像..."

    local mirrors=(
        "mirrors.aliyun.com"
        "mirrors.ustc.edu.cn"
        "mirrors.tuna.tsinghua.edu.cn"
    )
    local best_mirror=""

    for mirror in "${mirrors[@]}"; do
        info "测试镜像: $mirror ..."
        if test_mirror "$mirror"; then
            best_mirror="$mirror"
            success "镜像 $mirror 可用"
            break
        fi
    done

    if [[ -z "$best_mirror" ]]; then
        error "所有国内镜像均不可用，请检查网络连接"
        return 1
    fi

    # 备份原 sources.list
    if [[ ! -f /etc/apt/sources.list.bak ]]; then
        cp /etc/apt/sources.list /etc/apt/sources.list.bak
        info "已备份原 sources.list 到 sources.list.bak"
    fi

    generate_sources_list "$best_mirror" "$OS_CODENAME" "$OS_ID" > /etc/apt/sources.list
    success "已切换至国内镜像: $best_mirror"

    # 清理并重新更新
    apt-get clean
    if ! apt-get update; then
        error "切换镜像后 apt update 仍失败"
        return 1
    fi
    success "apt update 成功"
    return 0
}

# =============================================================================
# 2. 安装模块
# =============================================================================

# --- 2.1 基础前提 ---

# DNS 预检：测试能否解析镜像域名（飞牛 NAS 常见网关 DNS 未开启转发）
check_dns() {
    getent hosts mirrors.aliyun.com &>/dev/null || \
    getent hosts deb.debian.org &>/dev/null || \
    getent hosts mirrors.ustc.edu.cn &>/dev/null
}

ensure_prerequisites() {
    info "检查基础依赖..."

    # DNS 预检：避免 DNS 解析失败导致 apt-get update 长时间卡死
    if ! check_dns; then
        error "DNS 解析失败，apt update 将无法工作"
        echo ""
        echo -e "${YELLOW}  常见原因：网关/路由器 DNS 未开启转发（飞牛 NAS 常见）${NC}"
        echo -e "${YELLOW}  临时修复（复制以下命令到终端执行）：${NC}"
        echo ""
        echo "    cp /etc/resolv.conf /etc/resolv.conf.bak"
        echo "    cat > /etc/resolv.conf << 'EOF'"
        echo "    nameserver 223.5.5.5"
        echo "    nameserver 8.8.8.8"
        echo "    nameserver 119.29.29.29"
        echo "    EOF"
        echo ""
        return 1
    fi

    # 确保 sudo 存在
    if ! command -v sudo &>/dev/null; then
        safe_exec "安装 sudo" apt-get install -y sudo || return 1
    fi

    # 确保必要工具
    local tools=(wget curl gpg)
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            apt-get install -y "$tool" 2>/dev/null || true
        fi
    done

    # 更新包列表（加 300s 超时，避免镜像不通时无限挂起）
    if ! safe_exec "更新软件包列表" timeout 300 apt-get update; then
        warn "apt update 失败，尝试切换国内镜像源..."
        if ! switch_to_china_mirror; then
            error "apt update 失败且无法切换至可用镜像，请检查网络连接"
            return 1
        fi
    fi

    return 0
}

# --- 2.1.5 trim 源 avahi 冲突处理（飞牛 NAS 常见） ---

# 检测 trim 源（飞牛 NAS 自带）造成的 libavahi 包污染
# 现象: libavahi-common3 装了 trim 修改版（带 +trim-1 后缀和 2: epoch）
#       与 debian 标准的 libavahi-glib1 版本号不匹配
# 影响: 任何依赖 libavahi-glib1 的包（gvfs-backends -> mate-desktop-environment-core 等）都装不上
check_trim_avahi_conflict() {
    local installed_ver
    installed_ver="$(dpkg-query -W -f='${Version}' libavahi-common3 2>/dev/null || true)"

    # 未安装或非 trim 版本，无需处理
    if [[ -z "$installed_ver" || "$installed_ver" != *"+trim"* ]]; then
        return 0
    fi

    warn "检测到 trim 源修改版 libavahi-common3 (${installed_ver})"
    warn "这会导致 libavahi-glib1 装不上，进而阻断 mate/xfce/lxqt 等桌面环境"
    warn "正在降级 trim 源的 avahi 包到 debian 标准版本..."

    # 用 apt pin 覆盖 trim 源（repo.fnnas.com）对 avahi 包的优先级
    local pin_file="/etc/apt/preferences.d/zz-trim-avahi-downgrade.pref"
    local pin_content
    pin_content="$(cat <<'EOF'
# 由 rdp-setup 脚本自动生成：覆盖飞牛 NAS trim 源对 avahi 包的优先级
# 原因: trim 源修改版（带 +trim-1 后缀）与 debian 标准的 libavahi-glib1 版本号不匹配
#       导致 mate/xfce/lxqt 等桌面环境无法安装
# 解决: 强制从 debian 官方源安装标准版
Package: libavahi-common3 libavahi-common-data libavahi-client3 libavahi-core7 libavahi-glib1 avahi-daemon avahi-utils
Pin: origin repo.fnnas.com
Pin-Priority: 100
EOF
)"
    if ! echo "$pin_content" > "$pin_file"; then
        warn "无法写入 $pin_file，请检查权限"
        return 1
    fi

    apt-get update -qq

    # 关键：必须指定具体版本号降级到 debian 标准版
    # 原因: trim 源的 avahi 包使用 2: epoch（带 +trim-1 后缀），apt 默认选择版本号"更高"的 trim 版
    #       仅用 --allow-downgrades 仍会选 trim 版，必须显式指定不带 epoch 的 debian 标准版
    # 动态从 apt 缓存中获取 debian 标准版版本号（不带 +trim 后缀的）
    local debian_ver
    debian_ver="$(apt-cache madison libavahi-common3 2>/dev/null | grep -v 'trim' | awk '{print $3}' | head -1)"
    if [[ -z "$debian_ver" ]]; then
        warn "无法从 apt 缓存中获取 debian 标准版 avahi 版本号，请检查 apt 源"
        return 1
    fi

    if ! safe_exec "降级 trim avahi 包到 debian 标准版 (${debian_ver})" \
        apt-get install -y --allow-downgrades \
            "libavahi-common3=${debian_ver}" \
            "libavahi-common-data=${debian_ver}" \
            "libavahi-client3=${debian_ver}" \
            "libavahi-core7=${debian_ver}" \
            "avahi-daemon=${debian_ver}" \
            "avahi-utils=${debian_ver}" \
            "libavahi-glib1=${debian_ver}"; then
        warn "avahi 降级失败，桌面环境可能仍无法安装"
        return 1
    fi

    success "trim avahi 包已降级到 debian 标准版 (${debian_ver})"
    return 0
}

# --- 2.1.6 飞牛 NAS 系统适配 ---

# 检测是否为飞牛 NAS 系统
detect_fnos() {
    # 飞牛 NAS 的特征：存在 /usr/trim 或 /opt/trim 目录，或 trim_main 服务
    if [[ -d /usr/trim ]] || [[ -d /opt/trim ]] || systemctl is-active --quiet trim_main 2>/dev/null; then
        IS_FNOS=true
        return 0
    fi
    IS_FNOS=false
    return 1
}

# 飞牛预扫描：检测 dpkg 半配置包、liveupdate 损坏、initramfs 风险
scan_fnos_issues() {
    if [[ "$IS_FNOS" != "true" ]]; then
        return 0
    fi

    info "检测到飞牛 NAS 系统，执行额外预扫描..."

    # 检查 dpkg 半配置包
    local half_configured
    half_configured="$(dpkg --audit 2>&1 | grep -c "尚未配置\|等待.*触发器\|缺少列表控制文件")" || true
    if [[ "$half_configured" -gt 0 ]]; then
        scan_record "飞牛 dpkg 状态" warn "存在 ${half_configured} 个半配置/待触发包，安装前将自动修复"
    else
        scan_record "飞牛 dpkg 状态" pass
    fi

    # 检查 liveupdate 包是否损坏
    if dpkg -l liveupdate 2>/dev/null | grep -q "^i[^i]"; then
        scan_record "飞牛 liveupdate 包" warn "liveupdate 包状态异常，安装前将自动清理"
    else
        scan_record "飞牛 liveupdate 包" pass
    fi

    # 检查 update-initramfs 是否正常
    if [[ -x /usr/sbin/update-initramfs ]]; then
        scan_record "飞牛 initramfs" pass
    else
        scan_record "飞牛 initramfs" warn "update-initramfs 异常，安装前将自动修复"
    fi
}

# 飞牛安装前修复：修复 dpkg 半配置包、清理 liveupdate、保护 initramfs
fnos_pre_install_fix() {
    if [[ "$IS_FNOS" != "true" ]]; then
        return 0
    fi

    info "飞牛 NAS 检测：执行安装前修复..."

    # 1. 清理 liveupdate 损坏的 dpkg 元数据
    if dpkg -l liveupdate 2>/dev/null | grep -q "^i[^i]"; then
        info "清理损坏的 liveupdate dpkg 元数据..."
        dpkg --remove --force-remove-reinstreq liveupdate &>/dev/null || true
        success "liveupdate 元数据已清理（/usr/trim/bin/liveupdate 二进制不受影响）"
    fi

    # 2. 修复 dpkg 半配置包
    local audit_count
    audit_count="$(dpkg --audit 2>&1 | grep -c "尚未配置\|等待.*触发器\|缺少列表控制文件")" || true
    if [[ "$audit_count" -gt 0 ]]; then
        info "修复 ${audit_count} 个半配置/待触发包..."

        # 先处理触发器
        dpkg --triggers-only --pending &>/dev/null || true

        # 执行配置修复（initramfs 保护由外层 do_install 负责，此处不再处理）
        dpkg --configure -a &>/dev/null || true
        apt-get install -f -y &>/dev/null || true

        # 验证修复结果
        local remaining
        remaining="$(dpkg --audit 2>&1 | grep -c "尚未配置\|等待.*触发器\|缺少列表控制文件")" || true
        if [[ "$remaining" -eq 0 ]]; then
            success "dpkg 半配置包已全部修复"
        else
            warn "仍有 ${remaining} 个包未修复，可能影响后续安装"
        fi
    fi
}

# 飞牛安装后保护：部署 ufw 端口保护和 trim 更新看门狗
fnos_post_install_protect() {
    if [[ "$IS_FNOS" != "true" ]]; then
        return 0
    fi

    info "飞牛 NAS 检测：部署系统保护..."

    # 1. 部署 ufw 端口保护（防止 trim 更新重置 ufw 规则）
    local ufw_protect="/usr/local/bin/ufw-protect.sh"
    if [[ ! -f "$ufw_protect" ]]; then
        cat > "$ufw_protect" << 'UFWEOF'
#!/bin/bash
# 保护飞牛 Web 端口在 ufw 中不被 trim 自动更新覆盖
# 由 rdp-setup 脚本自动部署

REQUIRED_PORTS=(80 443 19890 8000 3389)
MISSING=0

for port in "${REQUIRED_PORTS[@]}"; do
    if ! ufw status 2>/dev/null | grep -qE "^\s*${port}/tcp"; then
        echo "[$(date '+%F %T')] [ufw-protect] 缺失 ${port}/tcp，正在添加"
        ufw allow ${port}/tcp comment "fnos-web-auto" 2>&1
        MISSING=1
    fi
done

if [[ $MISSING -eq 1 ]]; then
    ufw reload
    logger "ufw-protect: 已补齐缺失的飞牛 Web 端口规则"
fi
UFWEOF
        chmod +x "$ufw_protect"
        success "已部署 ufw-protect.sh（含 3389 远程桌面端口）"
    else
        # 确保已有脚本包含 3389 端口
        if ! grep -q "3389" "$ufw_protect"; then
            sed -i 's/REQUIRED_PORTS=(\(.*\))/REQUIRED_PORTS=(\1 3389)/' "$ufw_protect"
            success "ufw-protect.sh 已添加 3389 端口保护"
        fi
    fi

    # 部署 ufw-protect cron（每 5 分钟）
    local ufw_cron="/etc/cron.d/ufw-protect"
    if [[ ! -f "$ufw_cron" ]]; then
        echo "*/5 * * * * root /usr/local/bin/ufw-protect.sh >> /var/log/ufw-protect.log 2>&1" > "$ufw_cron"
        success "已部署 ufw-protect 定时任务（每 5 分钟检查）"
    fi

    # 2. 部署 trim 更新看门狗
    local guard_script="/usr/local/bin/trim-update-guard.sh"
    if [[ ! -f "$guard_script" ]]; then
        cat > "$guard_script" << 'GUARDEOF'
#!/bin/bash
# /usr/local/bin/trim-update-guard.sh
# 监控 trim 自动更新行为，防止更新失败导致系统假死
# 由 rdp-setup 脚本自动部署

LOG="/var/log/trim-update-guard.log"
GUARD_FILE="/tmp/trim_update_guarded"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

# 1. 检查 liveupdate 进程（精确匹配路径，避免误匹配）
LIVEUPDATE_PID=$(pgrep -xf "/usr/trim/bin/liveupdate" 2>/dev/null | head -1)
if [ -n "$LIVEUPDATE_PID" ]; then
    log "[警告] liveupdate 进程运行中 PID=$LIVEUPDATE_PID"

    if [ -f "$GUARD_FILE" ]; then
        log "[阻止] 上次更新失败，禁止再次自动更新。停止 liveupdate"
        kill -9 "$LIVEUPDATE_PID" 2>/dev/null
    else
        log "[提示] 首次检测到 liveupdate 启动，记录 guard 文件"
        touch "$GUARD_FILE"
    fi
fi

# 2. 检查 trim 进程是否要关机（精确匹配路径）
SHUTDOWN_PID=$(pgrep -xf "/usr/trim/bin/system_shutdown.sh" 2>/dev/null | head -1)
if [ -n "$SHUTDOWN_PID" ]; then
    log "[警告] trim 正在执行自动关机 PID=$SHUTDOWN_PID"

    if [ ! -f "$GUARD_FILE" ]; then
        touch "$GUARD_FILE"
        log "[提示] 标记为首次更新，允许执行"
    else
        log "[阻止] 上次更新失败过，本次也阻止自动关机"
        kill -STOP "$SHUTDOWN_PID" 2>/dev/null
    fi
fi
GUARDEOF
        chmod +x "$guard_script"
        success "已部署 trim-update-guard.sh（防止 trim 更新导致假死）"
    fi

    # 部署看门狗 cron（每分钟）
    local guard_cron="/etc/cron.d/trim-update-guard"
    if [[ ! -f "$guard_cron" ]]; then
        echo "# 监控 trim 自动更新，每分钟检查一次" > "$guard_cron"
        echo "* * * * * root /usr/local/bin/trim-update-guard.sh" >> "$guard_cron"
        success "已部署 trim-update-guard 定时任务（每分钟检查）"
    fi
}

# --- 2.2 中文环境安装 ---

install_chinese_locale() {
    info "安装中文语言环境..."

    # 安装核心语言包（处理 Ubuntu/Debian 差异）
    case "$OS_ID" in
        ubuntu)
            apt-get install -y language-pack-zh-hans \
                language-pack-gnome-zh-hans \
                fonts-wqy-zenhei \
                fonts-wqy-microhei 2>/dev/null || true
            ;;
        debian)
            apt-get install -y locales \
                fonts-wqy-zenhei \
                fonts-wqy-microhei 2>/dev/null || true
            ;;
    esac

    # 启用并生成 zh_CN.UTF-8 locale
    if [[ -f /etc/locale.gen ]]; then
        sed -i '/^#.*zh_CN.UTF-8 UTF-8/s/^# //' /etc/locale.gen
        locale-gen zh_CN.UTF-8 2>/dev/null || {
            warn "locale-gen 失败，尝试手动生成..."
            localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 2>/dev/null || {
                warn "zh_CN.UTF-8 locale 生成失败，中文可能无法正常显示"
            }
        }
    fi

    # 设置系统默认语言
    update-locale LANG=zh_CN.UTF-8 \
        LANGUAGE=zh_CN:zh \
        LC_ALL=zh_CN.UTF-8 2>/dev/null || true

    # 注入 XRDP 启动环境变量（由 install_xrdp 调用 inject_xrdp_locale 完成，此处不再重复调用）

    mark_component_installed "locale" "locales language-pack-zh-hans fonts-wqy-zenhei fonts-wqy-microhei"
    success "中文语言环境配置完成"
}

# 注入 XRDP startwm.sh 的中文环境变量和桌面自动检测
inject_xrdp_locale() {
    local wm_script="/etc/xrdp/startwm.sh"

    if [[ ! -f "$wm_script" ]]; then
        return 0
    fi

    info "配置 XRDP startwm.sh（中文环境 + 桌面自动检测）..."

    # 直接重写 startwm.sh，使用自动检测逻辑
    cat > "$wm_script" << 'STARTWM'
#!/bin/sh
export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8

if test -r /etc/profile; then
    . /etc/profile
fi

if test -r ~/.profile; then
    . ~/.profile
fi

# 自动检测已安装的桌面环境（优先级：MATE > XFCE4 > LXQt）
if command -v mate-session >/dev/null 2>&1; then
    exec mate-session
elif command -v startxfce4 >/dev/null 2>&1; then
    exec startxfce4
elif command -v startlxqt >/dev/null 2>&1; then
    exec startlxqt
elif test -x /etc/X11/Xsession; then
    exec /etc/X11/Xsession
fi
STARTWM
    chmod +x "$wm_script"

    success "XRDP startwm.sh 已配置（自动检测桌面环境）"
}

# --- 2.3 桌面环境安装 ---

install_desktop() {
    local desktop="${1:-$DESKTOP_CHOICE}"

    if is_component_installed "desktop"; then
        warn "桌面环境已安装"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否重新安装?" "n"; then
                info "跳过桌面环境安装"
                return 0
            fi
        fi
    fi

    # 检测系统上是否已有对应桌面环境（可能由其他脚本安装）
    local existing_de=""
    case "$desktop" in
        lxqt)  dpkg -l lxqt 2>/dev/null | grep -q '^ii' && existing_de="LXQt" ;;
        mate)  dpkg -l mate-desktop-environment 2>/dev/null | grep -q '^ii' && existing_de="MATE" ;;
        *)     dpkg -l xfce4 2>/dev/null | grep -q '^ii' && existing_de="XFCE4" ;;
    esac

    if [[ -n "$existing_de" ]]; then
        info "检测到系统已安装 ${existing_de} 桌面环境"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否跳过安装，直接纳入本脚本管理?" "y"; then
                info "将重新安装/修复桌面环境"
            else
                # 纳入状态管理，确保显示管理器也已安装
                local dm_pkg=""
                case "$desktop" in
                    lxqt) dm_pkg="sddm" ;;
                    *)    dm_pkg="lightdm" ;;
                esac
                if ! dpkg -l "$dm_pkg" 2>/dev/null | grep -q '^ii'; then
                    info "安装显示管理器 $dm_pkg ..."
                    apt-get install -y "$dm_pkg" 2>/dev/null || true
                fi
                DESKTOP_CHOICE="$desktop"
                mark_component_installed "desktop" "${existing_de}"
                success "${existing_de} 已纳入本脚本管理"
                return 0
            fi
        else
            # 非交互模式：已有桌面直接纳入管理
            DESKTOP_CHOICE="$desktop"
            mark_component_installed "desktop" "${existing_de}"
            success "${existing_de} 已纳入本脚本管理（跳过安装）"
            return 0
        fi
    fi

    # 检测系统上是否已有其他桌面环境（用户选了不同类型）
    local other_de=""
    dpkg -l xfce4 2>/dev/null | grep -q '^ii' && other_de="XFCE4"
    [[ -z "$other_de" ]] && dpkg -l lxqt 2>/dev/null | grep -q '^ii' && other_de="LXQt"
    [[ -z "$other_de" ]] && dpkg -l mate-desktop-environment 2>/dev/null | grep -q '^ii' && other_de="MATE"
    [[ -z "$other_de" ]] && dpkg -l gnome-shell 2>/dev/null | grep -q '^ii' && other_de="GNOME"
    [[ -z "$other_de" ]] && dpkg -l plasma-desktop 2>/dev/null | grep -q '^ii' && other_de="KDE Plasma"

    if [[ -n "$other_de" && "$INTERACTIVE" == "true" ]]; then
        warn "系统已安装 ${other_de}，但您选择了安装 ${desktop^^}"
        warn "多个桌面环境共存可能导致冲突"
        if ! confirm "是否继续安装 ${desktop^^}?" "n"; then
            info "已取消安装，${other_de} 将继续使用"
            return 1
        fi
    fi

    info "安装 ${desktop} 桌面环境..."

    local pkgs=()
    local dm_pkg=""

    case "$desktop" in
        lxqt)
            pkgs=(lxqt sddm xorg dbus-x11)
            dm_pkg="sddm"
            ;;
        mate)
            pkgs=(mate-desktop-environment mate-desktop-environment-extras lightdm xorg dbus-x11)
            dm_pkg="lightdm"
            ;;
        *)
            # 默认 XFCE4
            case "$OS_ID" in
                ubuntu)
                    case "$OS_VERSION_ID" in
                        20.04)
                            pkgs=(xubuntu-desktop xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xorg dbus-x11)
                            ;;
                        *)
                            pkgs=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xorg dbus-x11)
                            ;;
                    esac
                    dm_pkg="lightdm"
                    ;;
                debian)
                    case "$OS_VERSION_ID" in
                        10|11)
                            pkgs=(xfce4 xfce4-goodies lightdm xorg dbus-x11)
                            ;;
                        *)
                            pkgs=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter xorg dbus-x11)
                            ;;
                    esac
                    dm_pkg="lightdm"
                    ;;
            esac
            ;;
    esac

    safe_exec "安装 ${desktop} 桌面环境包" apt-get install -y "${pkgs[@]}" || return 1

    # 容器环境特殊处理
    if is_container; then
        info "检测到容器环境，跳过显示管理器启动"
    fi

    DESKTOP_CHOICE="$desktop"
    mark_component_installed "desktop" "${pkgs[*]}"
    success "${desktop} 桌面环境安装完成"
    return 0
}

# --- 2.4 XRDP 安装 ---

install_xrdp() {
    if is_component_installed "xrdp"; then
        warn "XRDP 已安装"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否重新配置?" "n"; then
                info "跳过 XRDP 安装"
                return 0
            fi
        fi
    fi

    # 检测系统上是否已有 XRDP（可能由其他脚本安装）
    if dpkg -l xrdp 2>/dev/null | grep -q '^ii'; then
        info "检测到系统已安装 XRDP"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否跳过安装，直接纳入本脚本管理?" "y"; then
                info "将重新安装/修复 XRDP"
            else
                configure_xrdp_ini
                inject_xrdp_locale "$DESKTOP_CHOICE"
                fix_startwm
                mark_component_installed "xrdp" "xrdp xorgxrdp"
                success "XRDP 已纳入本脚本管理"
                return 0
            fi
        else
            configure_xrdp_ini
            inject_xrdp_locale "$DESKTOP_CHOICE"
            fix_startwm
            mark_component_installed "xrdp" "xrdp xorgxrdp"
            success "XRDP 已纳入本脚本管理（跳过安装）"
            return 0
        fi
    fi

    info "安装 XRDP 远程桌面服务..."

    local pkgs=(xrdp xorgxrdp)

    # Ubuntu 24.04 可能需要 universe 源
    case "$OS_ID" in
        ubuntu)
            if [[ "$OS_VERSION_ID" == "24.04" ]]; then
                if ! apt-get install -y xrdp 2>/dev/null; then
                    warn "标准源 xrdp 安装失败，尝试从 universe 安装"
                    apt-get install -y software-properties-common 2>/dev/null || true
                    add-apt-repository -y universe 2>/dev/null || true
                    apt-get update -qq
                fi
            fi
            ;;
    esac

    safe_exec "安装 XRDP" apt-get install -y "${pkgs[@]}" || return 1

    # 配置 xrdp.ini
    configure_xrdp_ini

    # 确保有 dbus-x11
    apt-get install -y dbus-x11 2>/dev/null || true

    # 注入中文环境变量（需要桌面已安装）
    inject_xrdp_locale "$DESKTOP_CHOICE"

    # 启动服务
    start_xrdp_service

    mark_component_installed "xrdp" "${pkgs[*]}"
    success "XRDP 安装完成"
    return 0
}

configure_xrdp_ini() {
    local ini="/etc/xrdp/xrdp.ini"
    if [[ ! -f "$ini" ]]; then
        warn "xrdp.ini 不存在: $ini"
        return 1
    fi

    info "配置 xrdp.ini..."

    # 备份原始配置
    if [[ ! -f "${ini}.orig" ]]; then
        cp "$ini" "${ini}.orig"
    fi

    # 设置最大色彩深度
    sed -i 's/^max_bpp=.*/max_bpp=32/' "$ini"
    sed -i 's/^xserverbpp=.*/xserverbpp=24/' "$ini"

    # 设置加密（可选）
    sed -i 's/^security_layer=.*/security_layer=negotiate/' "$ini"

    # 端口冲突自动调整
    local current_port
    current_port="$(grep -oP '^port=\K\d+' "$ini" 2>/dev/null || echo "3389")"
    if [[ "$XRDP_PORT" != "$current_port" ]]; then
        info "端口冲突，将 $current_port 修改为 $XRDP_PORT"
        sed -i "s/^port=.*/port=${XRDP_PORT}/" "$ini"
    fi
    info "XRDP 端口: $XRDP_PORT"
}

start_xrdp_service() {
    info "启动 XRDP 服务..."

    if has_systemd; then
        systemctl enable xrdp 2>/dev/null || true
        systemctl restart xrdp 2>/dev/null || {
            error "XRDP 服务启动失败"
            systemctl status xrdp --no-pager 2>/dev/null || true
            return 1
        }
    else
        service xrdp restart 2>/dev/null || {
            warn "无法启动 xrdp 服务（可能处于容器环境）"
        }
    fi

    # 验证
    sleep 2
    if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${XRDP_PORT}"; then
        success "XRDP 服务已启动，监听端口 $XRDP_PORT"
    fi
}

# --- 2.5 VNC 可选模块 ---

install_vnc() {
    if is_component_installed "vnc"; then
        warn "VNC 已安装"
        return 0
    fi

    info "安装 TigerVNC 服务..."

    safe_exec "安装 TigerVNC" apt-get install -y tigervnc-standalone-server tigervnc-common || return 1

    # 创建 VNC 用户启动包装脚本（自动分配 display 编号）
    cat > /usr/local/bin/vnc-user-run << 'VNCWRAP'
#!/bin/bash
# VNC per-user wrapper: finds free display, starts vncserver
set -e
user="${1:?Usage: $0 <username>}"
geometry="${2:-1280x720}"
depth="${3:-24}"

# Find free VNC display (ports 5901+ map to :1+)
display=""
for d in $(seq 1 99); do
    port=$((5900 + d))
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        display="$d"
        break
    fi
done
[[ -z "$display" ]] && { echo "No free VNC display found" >&2; exit 1; }

# Clean stale X lock files
rm -f "/tmp/.X${display}-lock" "/tmp/.X11-unix/X${display}" 2>/dev/null || true

# Kill any stale vncserver for this user
su - "$user" -c "vncserver -kill :*" 2>/dev/null || true
sleep 1

# Start vncserver (forks, PID tracked by systemd)
exec su - "$user" -c "vncserver :${display} -geometry ${geometry} -depth ${depth} -localhost no"
VNCWRAP
    chmod 755 /usr/local/bin/vnc-user-run

    # 创建 systemd 服务模板 (%i = 用户名)
    if has_systemd; then
        cat > /etc/systemd/system/vncserver@.service << 'EOF'
[Unit]
Description=TigerVNC server for user %i
After=syslog.target network.target

[Service]
Type=forking
User=%i
PAMName=login
ExecStart=/usr/local/bin/vnc-user-run %i
ExecStop=/bin/sh -c 'su - %i -c "vncserver -kill :*" 2>/dev/null || true'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        info "VNC systemd 服务模板已创建"
    fi

    mark_component_installed "vnc" "tigervnc-standalone-server tigervnc-common"
    success "TigerVNC 安装完成"
    info "使用方式: systemctl start vncserver@<用户名>"
    return 0
}

# --- 2.6 Wine 可选模块 ---

install_wine() {
    local wine_type="${1:-minimal}"

    if is_component_installed "wine"; then
        warn "Wine 已安装"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否重新安装?" "n"; then
                return 0
            fi
        fi
    fi

    info "安装 Wine 兼容环境..."

    case "$wine_type" in
        full)
            install_wine_full
            ;;
        minimal)
            install_wine_minimal
            ;;
        *)
            error "未知 Wine 安装类型: $wine_type"
            return 1
            ;;
    esac
}

install_wine_minimal() {
    dpkg --add-architecture i386 2>/dev/null || true
    apt-get update -qq

    local pkgs=(wine wine64 libwine)
    safe_exec "安装 Wine 核心" apt-get install -y "${pkgs[@]}" || return 1

    create_swine_wrapper
    mark_component_installed "wine" "${pkgs[*]}"
    success "Wine 核心安装完成"
    return 0
}

install_wine_full() {
    dpkg --add-architecture i386 2>/dev/null || true
    apt-get update -qq

    local pkgs=(wine wine64 wine32 winbind xauth libgl1-mesa-dri:i386 mesa-utils winetricks)
    safe_exec "安装 Wine 完整版" apt-get install -y "${pkgs[@]}" || return 1

    create_swine_wrapper
    mark_component_installed "wine" "${pkgs[*]}"
    success "Wine 完整版安装完成"
    return 0
}

create_swine_wrapper() {
    cat > /usr/local/bin/swine << 'SWINEEOF'
#!/bin/bash
# Wine 远程桌面包装器（吸收自原脚本）
[ -f "$HOME/.Xauthority" ] && export XAUTHORITY="$HOME/.Xauthority"
[ -z "$DISPLAY" ] && export DISPLAY=":$(ls /tmp/.X11-unix/ 2>/dev/null | head -n1 | sed 's/X//')"
export LIBGL_ALWAYS_SOFTWARE=1
wine start /Unix "$@"
SWINEEOF
    chmod +x /usr/local/bin/swine
    info "Wine 包装器已创建: /usr/local/bin/swine"
}

# --- 2.7 Bottles 可选模块（Flatpak 版） ---

install_bottles() {
    if is_component_installed "bottles"; then
        warn "Bottles 已安装"
        return 0
    fi

    info "安装 Bottles（Flatpak 版）..."

    # 1. 安装 Flatpak（如未安装）
    if ! command -v flatpak &>/dev/null; then
        safe_exec "安装 Flatpak" apt-get install -y flatpak || return 1
    fi

    # 2. 添加 Flathub 源
    if ! flatpak remote-list 2>/dev/null | grep -qi flathub; then
        safe_exec "添加 Flathub 远程源" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || return 1
    fi

    # 3. 安装 Bottles
    if ! safe_exec "安装 Bottles（首次下载较大）" flatpak install -y flathub com.usebottles.bottles; then
        error "Bottles 安装失败"
        return 1
    fi

    # 4. 创建启动快捷方式（用于远程桌面环境）
    if [[ ! -f /usr/local/bin/bottles ]]; then
        cat > /usr/local/bin/bottles << 'BOTTLESEOF'
#!/bin/bash
# Bottles 远程桌面启动包装器
[ -f "$HOME/.Xauthority" ] && export XAUTHORITY="$HOME/.Xauthority"
[ -z "$DISPLAY" ] && export DISPLAY=":$(ls /tmp/.X11-unix/ 2>/dev/null | head -n1 | sed 's/X//')"
exec flatpak run com.usebottles.bottles "$@"
BOTTLESEOF
        chmod +x /usr/local/bin/bottles
    fi

    mark_component_installed "bottles" "flatpak com.usebottles.bottles"
    success "Bottles 安装完成！"
    info "命令行启动: bottles"
    info "桌面环境启动: 应用菜单中找到 Bottles"
    return 0
}

# --- 2.8 输入法安装 ---

install_input_method() {
    if is_component_installed "input_method"; then
        warn "输入法已安装"
        return 0
    fi

    if ! is_component_installed "desktop"; then
        warn "未检测到桌面环境，输入法在 XRDP 会话中可能无法正常工作，继续安装但请注意。"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否继续?" "n"; then
                info "已跳过输入法安装"
                return 1
            fi
        fi
    fi

    info "安装 Fcitx5 中文输入法..."

    local pkgs=(fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk2 fcitx5-frontend-qt5)
    safe_exec "安装 Fcitx5" apt-get install -y "${pkgs[@]}" || return 1

    # 设置环境变量（全局）
    cat > /etc/X11/Xsession.d/95fcitx5 << 'EOF'
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
EOF
    chmod +x /etc/X11/Xsession.d/95fcitx5

    mark_component_installed "input_method" "${pkgs[*]}"
    success "Fcitx5 中文输入法安装完成"
    return 0
}

# --- 2.8.1 浏览器安装 ---

detect_browser_recommendation() {
    local total_mem_kb
    total_mem_kb="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 0)"
    local total_mem_mb=$((total_mem_kb / 1024))

    echo ""
    echo -e "${CYAN}[服务器配置扫描]${NC}"
    echo "  内存: ${total_mem_mb}MB"
    echo ""
    echo -e "${CYAN}[浏览器推荐]${NC}"

    if [[ "$total_mem_mb" -le 2048 ]]; then
        echo -e "  ${GREEN}★ Midori${NC}（极轻量，WebKit 内核）"
        echo -e "  ${GREEN}  Firefox ESR${NC}（稳定版，内存占用适中）"
        echo -e "  ${YELLOW}  Chromium${NC}（资源占用较高，不推荐）"
    elif [[ "$total_mem_mb" -le 4096 ]]; then
        echo -e "  ${GREEN}★ Firefox ESR${NC}（推荐，稳定且兼容性好）"
        echo -e "  ${GREEN}  Midori${NC}（轻量备选）"
        echo -e "  ${YELLOW}  Chromium${NC}（资源占用较高，可选）"
    else
        echo -e "  ${GREEN}★ Firefox ESR${NC}（推荐）"
        echo -e "  ${GREEN}  Chromium${NC}（性能好，兼容性强）"
        echo -e "  ${GREEN}  Midori${NC}（轻量备选）"
    fi
    echo ""
}

install_browser_firefox_esr() {
    if command -v firefox-esr &>/dev/null || command -v firefox &>/dev/null; then
        warn "Firefox 已安装"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否重新安装?" "n"; then
                return 0
            fi
        fi
    fi

    info "安装 Firefox ESR..."
    apt-get update -qq
    safe_exec "安装 Firefox ESR" apt-get install -y firefox-esr || return 1

    # 创建桌面快捷方式
    if [[ ! -f /usr/share/applications/firefox-esr.desktop ]]; then
        cat > /usr/share/applications/firefox-esr.desktop << 'EOF'
[Desktop Entry]
Name=Firefox ESR
Comment=Browse the World Wide Web
Exec=/usr/bin/firefox-esr %u
Icon=firefox-esr
Terminal=false
Type=Application
Categories=Network;WebBrowser;
EOF
    fi

    mark_component_installed "browser_firefox_esr" "firefox-esr"
    success "Firefox ESR 安装完成"
    return 0
}

install_browser_chromium() {
    if command -v chromium &>/dev/null || command -v chromium-browser &>/dev/null; then
        warn "Chromium 已安装"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否重新安装?" "n"; then
                return 0
            fi
        fi
    fi

    info "安装 Chromium..."
    apt-get update -qq

    # Debian/Ubuntu 包名差异处理
    local pkg_name="chromium"
    if [[ "$OS_ID" == "ubuntu" ]]; then
        # Ubuntu 22.04+ 的 chromium-browser 是 snap 过渡包，尝试直接安装 chromium
        if apt-cache show chromium 2>/dev/null | grep -q "^Package: chromium$"; then
            pkg_name="chromium"
        else
            pkg_name="chromium-browser"
        fi
    fi

    safe_exec "安装 Chromium" apt-get install -y "$pkg_name" || return 1

    mark_component_installed "browser_chromium" "$pkg_name"
    success "Chromium 安装完成"
    return 0
}

install_browser_midori() {
    if command -v midori &>/dev/null; then
        warn "Midori 已安装"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否重新安装?" "n"; then
                return 0
            fi
        fi
    fi

    info "安装 Midori..."
    apt-get update -qq
    safe_exec "安装 Midori" apt-get install -y midori || return 1

    mark_component_installed "browser_midori" "midori"
    success "Midori 安装完成"
    return 0
}

install_browser() {
    local browser_type="${1:-}"

    # 如果没有指定类型，进入交互选择
    if [[ -z "$browser_type" && "$INTERACTIVE" == "true" ]]; then
        detect_browser_recommendation

        while true; do
            echo ""
            echo -e "${BOLD}  请选择要安装的浏览器:${NC}"
            echo ""
            echo "    1) Firefox ESR（稳定版，推荐）"
            echo "    2) Chromium（性能好，资源占用较高）"
            echo "    3) Midori（极轻量，WebKit 内核）"
            echo "    0) 返回上一级"
            echo ""
            read -r -p "  选择 [1]: " browser_choice
            browser_choice="${browser_choice:-1}"

            case "$browser_choice" in
                0) return 0 ;;
                2) install_browser_chromium; return $? ;;
                3) install_browser_midori; return $? ;;
                *) install_browser_firefox_esr; return $? ;;
            esac
        done
    fi

    # 直接安装指定类型
    case "$browser_type" in
        firefox|firefox-esr|esr)
            install_browser_firefox_esr
            ;;
        chromium|chrome)
            install_browser_chromium
            ;;
        midori|light)
            install_browser_midori
            ;;
        *)
            error "未知浏览器类型: $browser_type"
            echo "支持的类型: firefox-esr, chromium, midori"
            return 1
            ;;
    esac
}

# --- 2.9 防火墙配置 ---

configure_firewall() {
    local action="${1:-open}"

    if ! command -v ufw &>/dev/null; then
        info "UFW 未安装，正在安装..."
        apt-get install -y ufw 2>/dev/null || {
            warn "UFW 安装失败，请手动配置防火墙"
            return 1
        }
    fi

    local port
    port="$(grep -oP '^port=\K\d+' /etc/xrdp/xrdp.ini 2>/dev/null || echo "3389")"

    case "$action" in
        open)
            ufw allow "$port"/tcp 2>/dev/null || true
            ufw allow 5900:5910/tcp 2>/dev/null || true # VNC 端口范围
            if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
                info "启用 UFW 防火墙..."
                ufw --force enable 2>/dev/null || true
            fi
            ufw reload 2>/dev/null || true
            success "防火墙已配置: 开放端口 $port (XRDP), 5900-5910 (VNC)"
            ;;
        close)
            ufw delete allow "$port"/tcp 2>/dev/null || true
            ufw delete allow 5900:5910/tcp 2>/dev/null || true
            success "防火墙已配置: 关闭远程桌面端口"
            ;;
    esac
}

show_firewall_status() {
    echo ""
    echo -e "${BOLD}防火墙状态和开放端口${NC}"
    echo ""

    if ! command -v ufw &>/dev/null; then
        echo -e "${YELLOW}UFW 防火墙未安装${NC}"
        echo ""
    else
        echo -e "${CYAN}[UFW 防火墙状态]${NC}"
        local status
        # 去除 ANSI 转义码，避免输出乱码
        status="$(ufw status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
        if [[ "$status" =~ "Status: active" ]]; then
            echo -e "  状态: ${GREEN}已启用${NC}"
        elif [[ "$status" =~ "Status: inactive" ]]; then
            echo -e "  状态: ${RED}已禁用${NC}"
        else
            echo -e "  状态: ${YELLOW}未知${NC}"
        fi
        echo ""

        echo -e "${CYAN}[UFW 规则列表]${NC}"
        # 显示原始 ufw 状态，去除状态行和 ANSI 颜色代码
        ufw status verbose 2>/dev/null | grep -v "^Status:" | grep -v "^$" | sed 's/\x1b\[[0-9;]*m//g' | while read -r rule; do
            echo "  $rule"
        done
    fi

    echo ""
    echo -e "${CYAN}[监听端口]${NC}"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -v '127.0.0.1' | grep -v '::1' | sed 's/\x1b\[[0-9;]*m//g' | awk '{print "  " $5 " - " $7}'
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -v '127.0.0.1' | grep -v '::1' | sed 's/\x1b\[[0-9;]*m//g' | awk '{print "  " $4 " - " $7}'
    else
        echo "  无法获取监听端口信息"
    fi

    echo ""
    echo -e "${CYAN}[远程桌面相关端口]${NC}"
    local xrdp_port
    xrdp_port="$(grep -oP '^port=\K\d+' /etc/xrdp/xrdp.ini 2>/dev/null || echo "3389")"
    
    echo -n "  XRDP 端口 ($xrdp_port): "
    if ss -tlnp 2>/dev/null | grep -q ":$xrdp_port"; then
        echo -e "${GREEN}已监听${NC}"
    else
        echo -e "${RED}未监听${NC}"
    fi

    echo -n "  VNC 端口 (5900-5910): "
    if ss -tlnp 2>/dev/null | grep -q ":590"; then
        echo -e "${GREEN}已监听${NC}"
    else
        echo -e "${YELLOW}未监听或部分监听${NC}"
    fi
}

# --- 2.10 一键安装入口 ---

install_all() {

    echo ""
    hr
    echo -e "${BOLD}开始安装远程桌面...${NC}"
    hr
    echo ""

    # 1. 预扫描
    if ! run_prescan; then
        return 1
    fi

    # 2. 确保基础前提
    if ! ensure_prerequisites; then
        return 1
    fi

    # 2.5 检测并处理 trim 源造成的 avahi 冲突（飞牛 NAS 常见，不处理则桌面环境装不上）
    # 此项不影响 XRDP/VNC/Wine 等非桌面组件，但放在此处在所有安装之前更安全
    check_trim_avahi_conflict || warn "trim avahi 冲突处理失败，继续尝试安装..."

    # 2.6 飞牛 NAS 安装前修复（dpkg 半配置包、liveupdate 清理）
    fnos_pre_install_fix

    # 2.7 飞牛 NAS 临时禁用 update-initramfs（安装全过程中保护，安装后恢复）
    local _initramfs_backed_up=false
    if [[ "$IS_FNOS" == "true" ]] && [[ -x /usr/sbin/update-initramfs ]] && ! head -2 /usr/sbin/update-initramfs | grep -q "rdp-setup"; then
        cp /usr/sbin/update-initramfs /usr/sbin/update-initramfs.rdp-backup
        cat > /usr/sbin/update-initramfs << 'INITEOF'
#!/bin/bash
# [rdp-setup 临时禁用] 飞牛 NAS 的 initramfs 更新可能导致 dpkg 崩溃
# 安装完成后会自动恢复
echo "[rdp-setup] update-initramfs 已临时跳过" >&2
exit 0
INITEOF
        chmod +x /usr/sbin/update-initramfs
        _initramfs_backed_up=true
        info "已临时禁用 update-initramfs（安装完成后自动恢复）"
    fi

    # 3. 解析组件选择
    local do_desktop=true
    local do_xrdp=true
    local do_vnc=false
    local do_wine=""
    local do_input_method=false
    local do_bottles=false
    local do_browser=""

    # 解析 CLI 参数或交互选择
    if [[ $# -gt 0 ]]; then
        for arg in "$@"; do
            case "$arg" in
                --xrdp)          do_xrdp=true ;;
                --no-xrdp)       do_xrdp=false ;;
                --vnc)           do_vnc=true ;;
                --wine=minimal)  do_wine="minimal" ;;
                --wine=full)     do_wine="full" ;;
                --wine=*)        do_wine="full" ;;
                --input-method)  do_input_method=true ;;
                --bottles)       do_bottles=true ;;
                --browser=firefox-esr) do_browser="firefox-esr" ;;
                --browser=chromium)    do_browser="chromium" ;;
                --browser=midori)      do_browser="midori" ;;
                --desktop=xfce4) DESKTOP_CHOICE="xfce4" ;;
                --desktop=lxqt)  DESKTOP_CHOICE="lxqt" ;;
                --desktop=mate)  DESKTOP_CHOICE="mate" ;;
                --all)           do_vnc=true; do_wine="full"; do_input_method=true; do_bottles=true ;;
                --desktop-only)  do_xrdp=false ;;
                --no-desktop)    do_desktop=false ;;
            esac
        done
    elif [[ "$INTERACTIVE" == "true" ]]; then
        # 模块化组件选择菜单
        local has_desktop=false
        [[ "${SCAN_RESULT[已有桌面环境]}" == warn* ]] && has_desktop=true

        while true; do
            echo ""
            echo -e "${BOLD}  请选择要安装的组件（输入编号，多个用逗号分隔）:${NC}"
            echo ""
            echo -e "  ${PURPLE}── 桌面环境 ──${NC}"
            echo -e "  ${GREEN}1)${NC} XFCE4 桌面（轻量，推荐）"
            echo -e "  ${GREEN}2)${NC} LXQt 桌面（极轻量）"
            echo -e "  ${GREEN}3)${NC} MATE 桌面（中等资源占用）"
            if [[ "$has_desktop" == "true" ]]; then
                echo -e "  ${GREEN}0)${NC} 跳过桌面（使用已有桌面）${YELLOW}[推荐]${NC}"
            else
                echo -e "  ${GREEN}0)${NC} 跳过桌面（${RED}风险：XRDP 将黑屏${NC}）"
            fi
            echo ""
            echo -e "  ${PURPLE}── 远程协议 ──${NC}"
            echo -e "  ${GREEN}4)${NC} XRDP 远程桌面 ${CYAN}[推荐]${NC}"
            echo -e "  ${GREEN}5)${NC} VNC 远程桌面"
            echo ""
            echo -e "  ${PURPLE}── 可选软件 ──${NC}"
            echo -e "  ${GREEN}6)${NC} Wine 精简版（仅核心）"
            echo -e "  ${GREEN}7)${NC} Wine 完整版（含 winetricks）"
            echo -e "  ${GREEN}8)${NC} Fcitx5 中文输入法"
            echo -e "  ${GREEN}9)${NC} Bottles（图形化 Wine 管理）"
            echo -e "  ${GREEN}10)${NC} 浏览器（安装后选择类型）"
            echo ""

            local default_hint="1,4"
            [[ "$has_desktop" == "true" ]] && default_hint="0,4"
            read -r -p "  选择 [默认: ${default_hint}]: " install_str
            install_str="${install_str:-$default_hint}"

            # 解析选择
            do_desktop=false
            do_xrdp=false
            do_vnc=false
            do_wine=""
            do_input_method=false
            do_bottles=false
            do_browser=""

            IFS=',' read -ra install_arr <<< "$install_str"
            for s in "${install_arr[@]}"; do
                case "$(echo "$s" | tr -d ' ')" in
                    0) do_desktop=false ;;
                    1) do_desktop=true; DESKTOP_CHOICE="xfce4" ;;
                    2) do_desktop=true; DESKTOP_CHOICE="lxqt" ;;
                    3) do_desktop=true; DESKTOP_CHOICE="mate" ;;
                    4) do_xrdp=true ;;
                    5) do_vnc=true ;;
                    6) do_wine="minimal" ;;
                    7) do_wine="full" ;;
                    8) do_input_method=true ;;
                    9) do_bottles=true ;;
                    10) do_browser="select" ;;
                    *) warn "忽略无效编号: $s" ;;
                esac
            done

            # 校验
            if [[ "$do_xrdp" != "true" && "$do_vnc" != "true" && "$do_desktop" != "true" && -z "$do_wine" && "$do_input_method" != "true" && "$do_bottles" != "true" && -z "$do_browser" ]]; then
                warn "至少需要选择一个组件"
                continue
            fi
            # 仅当用户选了远程协议但没选桌面，且系统也没有桌面时警告
            if [[ "$do_desktop" != "true" && "$has_desktop" != "true" ]] && [[ "$do_xrdp" == "true" || "$do_vnc" == "true" ]]; then
                warn "未选择桌面环境且系统无桌面，XRDP 连接后将黑屏！"
                if ! confirm "确定继续?" "n"; then
                    continue
                fi
            fi
            break
        done
    fi

    # 记录开始安装
    write_state "installed_at" "$(date '+%Y-%m-%dT%H:%M:%S%:z')"
    write_state "status" "installing"

    # 4. 按顺序执行安装
    local failed=false

    # 安装 sudo （Debian 预扫描中已提示）
    if ! command -v sudo &>/dev/null; then
        apt-get install -y sudo || true
    fi

    # 桌面环境
    if [[ "$do_desktop" == "true" ]]; then
        if ! install_desktop "$DESKTOP_CHOICE"; then
            error "桌面环境安装失败"
            failed=true
        fi
    fi

    # XRDP
    if [[ "$do_xrdp" == "true" && "$failed" != "true" ]]; then
        if ! install_xrdp; then
            error "XRDP 安装失败"
            failed=true
        fi
    fi

    # 中文环境（依赖桌面 + XRDP，放在 XRDP 之后确保 startwm.sh 注入生效）
    if ! is_component_installed "locale"; then
        if [[ "$failed" != "true" ]]; then
            install_chinese_locale
        fi
    fi

    # VNC
    if [[ "$do_vnc" == "true" && "$failed" != "true" ]]; then
        install_vnc || warn "VNC 安装失败，但不影响整体"
    fi

    # Wine
    if [[ -n "$do_wine" && "$failed" != "true" ]]; then
        install_wine "$do_wine" || warn "Wine 安装失败，但不影响整体"
    fi

    # 输入法
    if [[ "$do_input_method" == "true" && "$failed" != "true" ]]; then
        install_input_method || warn "输入法安装失败，但不影响整体"
    fi

    # Bottles
    if [[ "$do_bottles" == "true" && "$failed" != "true" ]]; then
        install_bottles || warn "Bottles 安装失败，但不影响整体"
    fi

    # 浏览器
    if [[ -n "$do_browser" && "$failed" != "true" ]]; then
        if [[ "$do_browser" == "select" && "$INTERACTIVE" == "true" ]]; then
            install_browser || warn "浏览器安装失败，但不影响整体"
        elif [[ "$do_browser" != "select" ]]; then
            install_browser "$do_browser" || warn "浏览器安装失败，但不影响整体"
        fi
    fi

    # 5. 防火墙
    if [[ "$do_xrdp" == "true" ]] || [[ "$do_vnc" == "true" ]]; then
        configure_firewall open
    fi

    echo ""
    hr

    if [[ "$failed" == "true" ]]; then
        # 安装失败时也恢复 initramfs
        if [[ "$_initramfs_backed_up" == "true" ]] && [[ -f /usr/sbin/update-initramfs.rdp-backup ]]; then
            cp /usr/sbin/update-initramfs.rdp-backup /usr/sbin/update-initramfs
            rm -f /usr/sbin/update-initramfs.rdp-backup
            info "update-initramfs 已恢复（安装失败退出）"
        fi
        write_state "status" "partial_failed"
        error "安装过程中出现错误，部分组件可能未正确安装"
        echo "请查看日志: $LOG_FILE"
        return 1
    fi

    write_state "status" "installed"
    success "远程桌面安装完成！"
    echo ""

    # 飞牛 NAS 恢复 update-initramfs（安装全过程中禁用，现在恢复）
    if [[ "$_initramfs_backed_up" == "true" ]] && [[ -f /usr/sbin/update-initramfs.rdp-backup ]]; then
        cp /usr/sbin/update-initramfs.rdp-backup /usr/sbin/update-initramfs
        rm -f /usr/sbin/update-initramfs.rdp-backup
        success "update-initramfs 已恢复"
    fi

    # 验证安装的桌面环境
    info "验证安装的桌面环境..."
    local detected_desktop=""
    if command -v startxfce4 >/dev/null 2>&1; then
        detected_desktop="XFCE4"
    elif command -v mate-session >/dev/null 2>&1; then
        detected_desktop="MATE"
    elif command -v startlxqt >/dev/null 2>&1; then
        detected_desktop="LXQt"
    fi

    if [[ -n "$detected_desktop" ]]; then
        success "已检测到桌面环境: $detected_desktop"
    else
        warn "未检测到任何桌面环境！XRDP 连接后可能只有终端界面"
    fi

    # 验证 startwm.sh 配置
    if [[ -f /etc/xrdp/startwm.sh ]]; then
        local wm_cmd
        wm_cmd="$(grep -E '^exec (startxfce4|mate-session|startlxqt)' /etc/xrdp/startwm.sh | head -1 | awk '{print $2}')"
        if [[ -n "$wm_cmd" ]]; then
            info "XRDP 将启动: $wm_cmd"
        else
            warn "startwm.sh 中未配置桌面启动命令"
        fi
    fi

    # 飞牛 NAS 安装后保护（ufw 端口保护 + trim 更新看门狗）
    fnos_post_install_protect

    info "连接方式: 使用 Windows 远程桌面连接到 $(hostname -I 2>/dev/null | awk '{print $1}' || echo '服务器IP'):${XRDP_PORT}"
    echo "如需完整中文支持，建议重启系统。"

    # 飞牛 NAS 特定提示
    if [[ "$IS_FNOS" == "true" ]]; then
        echo ""
        echo -e "${YELLOW}飞牛 NAS 注意事项:${NC}"
        echo "  - 已自动部署 ufw 端口保护（防止 trim 更新重置防火墙规则）"
        echo "  - 已自动部署 trim 更新看门狗（防止 trim 自动更新导致系统假死）"
        echo "  - 如需手动允许 trim 更新，删除 /tmp/trim_update_guarded 后重启"
        echo "  - 日志位置: /var/log/trim-update-guard.log /var/log/ufw-protect.log"
    fi
    pause
    return 0
}

# =============================================================================
# 3. 维护模块
# =============================================================================

# --- 3.1 用户管理 ---

user_add() {
    local target_user="${1:-}"

    if [[ -z "$target_user" ]]; then
        if [[ "$INTERACTIVE" == "true" ]]; then
            local default_name="rdp$(date +%Y%m)"
            read -r -p "请输入用户名 (默认: $default_name): " target_user
            target_user="${target_user:-$default_name}"
        else
            error "用户名不能为空"
            return 1
        fi
    fi

    # 检查用户是否已存在
    local reset_mode=false
    if id "$target_user" &>/dev/null; then
        warn "用户 $target_user 已存在"
        if [[ "$INTERACTIVE" == "true" ]]; then
            if ! confirm "是否重置该用户?" "n"; then
                return 1
            fi
            reset_mode=true
        else
            return 1
        fi
    fi

    # 设置密码
    local user_pass=""
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo "密码设置:"
        echo "  1) 手动输入"
        echo "  2) 随机生成 [默认]"
        read -r -p "选择 [2]: " pw_choice
        pw_choice="${pw_choice:-2}"

        case "$pw_choice" in
            1)
                read -r -s -p "请输入密码: " user_pass
                echo ""
                if [[ -z "$user_pass" ]]; then
                    error "密码不能为空"
                    return 1
                fi
                ;;
            *)
                user_pass="$(< /dev/urandom tr -dc 'A-Za-z0-9!@#$%' 2>/dev/null | head -c 16)"
                echo -e "${YELLOW}生成的随机密码: ${user_pass}${NC}"
                ;;
        esac
    else
        user_pass="$(< /dev/urandom tr -dc 'A-Za-z0-9!@#$%' 2>/dev/null | head -c 16)"
        echo "生成的随机密码: $user_pass"
    fi

    # 创建用户
    if [[ "$reset_mode" == "true" ]]; then
        info "重置用户 $target_user ..."
    else
        useradd -m -s /bin/bash "$target_user" 2>/dev/null || {
            error "创建用户 $target_user 失败"
            return 1
        }
    fi

    echo "${target_user}:${user_pass}" | chpasswd

    # 添加 sudo 权限
    usermod -aG sudo "$target_user" 2>/dev/null || usermod -aG wheel "$target_user" 2>/dev/null || true

    # sudo 模式选择（交互模式下询问）
    local sudo_nopasswd=false
    if [[ "$INTERACTIVE" == "true" ]]; then
        echo ""
        echo "sudo 权限模式:"
        echo "  1) 免密码 (NOPASSWD，方便但安全性较低)"
        echo "  2) 需要密码 (推荐)"
        read -r -p "选择 [2]: " sudo_choice
        [[ "$sudo_choice" == "1" ]] && sudo_nopasswd=true
    fi

    if [[ "$sudo_nopasswd" == "true" ]]; then
        echo "$target_user ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$target_user"
    else
        echo "$target_user ALL=(ALL) ALL" > "/etc/sudoers.d/$target_user"
    fi
    chmod 440 "/etc/sudoers.d/$target_user"

    # 用户中文环境配置（先清理旧行避免重置时重复追加）
    sed -i '/^export LANG=zh_CN\.UTF-8/d; /^export LANGUAGE=zh_CN:zh/d; /^export LC_ALL=zh_CN\.UTF-8/d' \
        "/home/$target_user/.bashrc" 2>/dev/null || true
    {
        echo "export LANG=zh_CN.UTF-8"
        echo "export LANGUAGE=zh_CN:zh"
        echo "export LC_ALL=zh_CN.UTF-8"
    } >> "/home/$target_user/.bashrc"

    # 创建 .xsession 文件
    local xs_cmd
    case "$DESKTOP_CHOICE" in
        lxqt) xs_cmd="startlxqt" ;;
        mate) xs_cmd="mate-session" ;;
        *)    xs_cmd="startxfce4" ;;
    esac
    echo "$xs_cmd" > "/home/$target_user/.xsession"
    chown "$target_user:$target_user" "/home/$target_user/.xsession"

    # 记录到状态文件（追加到 users_created 数组）
    if command -v python3 &>/dev/null; then
        _PY_STATE_FILE="$STATE_FILE" _PY_TARGET_USER="$target_user" python3 -c "
import json, os
data = json.load(open(os.environ['_PY_STATE_FILE']))
users = data.get('users_created', [])
user = os.environ['_PY_TARGET_USER']
if user not in users:
    users.append(user)
data['users_created'] = users
json.dump(data, open(os.environ['_PY_STATE_FILE'], 'w'), indent=2, ensure_ascii=False)
" 2>/dev/null
    fi

    success "用户 $target_user 创建成功，已配置 sudo 权限和中文环境"
}

user_delete() {
    local target_user="${1:-}"

    if [[ -z "$target_user" ]]; then
        if [[ "$INTERACTIVE" == "true" ]]; then
            read -r -p "输入要删除的用户名: " target_user
        else
            error "用户名不能为空"
            return 1
        fi
    fi

    if [[ "$target_user" == "root" ]]; then
        error "不能删除 root 用户"
        return 1
    fi

    if ! id "$target_user" &>/dev/null; then
        error "用户 $target_user 不存在"
        return 1
    fi

    if ! confirm "确认删除用户 $target_user 及其主目录?" "n"; then
        info "已取消"
        return 1
    fi

    # 杀掉该用户的进程
    pkill -u "$target_user" 2>/dev/null || true
    sleep 1

    # 删除用户
    userdel -r "$target_user" 2>/dev/null || {
        error "删除用户 $target_user 失败，可能仍有进程持有文件"
        return 1
    }

    # 清理 sudoers
    rm -f "/etc/sudoers.d/$target_user"

    # 从状态文件中移除
    if command -v python3 &>/dev/null; then
        _PY_STATE_FILE="$STATE_FILE" _PY_TARGET_USER="$target_user" python3 -c "
import json, os
data = json.load(open(os.environ['_PY_STATE_FILE']))
users = data.get('users_created', [])
user = os.environ['_PY_TARGET_USER']
if user in users:
    users.remove(user)
data['users_created'] = users
json.dump(data, open(os.environ['_PY_STATE_FILE'], 'w'), indent=2, ensure_ascii=False)
" 2>/dev/null
    fi

    success "用户 $target_user 已彻底删除"
}

user_change_password() {
    local target_user="${1:-}"

    if [[ -z "$target_user" ]]; then
        read -r -p "用户名: " target_user
    fi

    if ! id "$target_user" &>/dev/null; then
        error "用户 $target_user 不存在"
        return 1
    fi

    local new_pass
    read -r -s -p "新密码: " new_pass
    echo ""
    echo "$target_user:$new_pass" | chpasswd
    success "密码已更新"
}

user_list() {
    echo -e "${BOLD}当前可登录用户列表:${NC}"
    echo ""
    awk -F: '($3 >= 1000 && $7 !~ /(nologin|false)/) { printf "  %-20s UID: %s\n", $1, $3 }' /etc/passwd
    echo ""
}

user_management() {
    while true; do
        echo ""
        hr
        echo -e "${BOLD}用户管理${NC}"
        hr
        echo "  1) 新增用户"
        echo "  2) 删除用户"
        echo "  3) 修改密码"
        echo "  4) 查看用户列表"
        echo "  5) 返回"
        echo ""
        read -r -p "选择: " choice

        case "$choice" in
            1) user_add; pause ;;
            2) user_delete; pause ;;
            3) user_change_password; pause ;;
            4) user_list; pause ;;
            5) return 0 ;;
            *) echo "无效选择" ;;
        esac
    done
}

# --- 3.2 服务控制 ---

service_control() {
    local service_name="${1:-}"
    local action="${2:-}"

    if [[ -z "$service_name" || -z "$action" ]]; then
        echo -e "${BOLD}服务控制${NC}"
        echo ""
        echo "可选服务: xrdp, xrdp-sesman"
        echo "可选操作: start, stop, restart, status, enable, disable"
        echo ""
        return 1
    fi

    case "$action" in
        start|stop|restart|enable|disable)
            if has_systemd; then
                systemctl "$action" "$service_name" 2>/dev/null && \
                    success "$service_name $action 完成" || \
                    error "$service_name $action 失败"
            else
                service "$service_name" "$action" 2>/dev/null && \
                    success "$service_name $action 完成" || \
                    error "$service_name $action 失败"
            fi
            ;;
        status)
            echo ""
            if has_systemd; then
                systemctl status "$service_name" --no-pager 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || \
                    error "无法获取 $service_name 状态"
            else
                service "$service_name" status 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || \
                    error "无法获取 $service_name 状态"
            fi
            echo ""
            ;;
        *)
            error "无效操作: $action"
            return 1
            ;;
    esac
}

# --- 3.3 分辨率调整 ---

set_resolution() {
    local width="${1:-1280}"
    local height="${2:-720}"
    local depth="${3:-24}"

    local ini="/etc/xrdp/xrdp.ini"

    if [[ ! -f "$ini" ]]; then
        error "xrdp.ini 不存在"
        return 1
    fi

    # 修改 xrdp.ini
    sed -i "s/^max_bpp=.*/max_bpp=$depth/" "$ini"
    sed -i "s/^xserverbpp=.*/xserverbpp=$depth/" "$ini"

    info "分辨率已设置为 ${width}x${height}，色彩深度 $depth 位"
    info "注意: 实际分辨率由客户端连接时指定"

    # 重启服务使配置生效
    if has_systemd; then
        systemctl restart xrdp 2>/dev/null
    fi

    return 0
}

# --- 3.4 端口修改 ---

set_port() {
    local new_port="${1:-}"

    if [[ -z "$new_port" ]]; then
        read -r -p "请输入新端口号 (1-65535): " new_port
    fi

    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ "$new_port" -lt 1 ]] || [[ "$new_port" -gt 65535 ]]; then
        error "无效端口号: $new_port"
        return 1
    fi

    local ini="/etc/xrdp/xrdp.ini"
    if [[ ! -f "$ini" ]]; then
        error "xrdp.ini 不存在"
        return 1
    fi

    local old_port
    old_port="$(grep -oP '^port=\K\d+' "$ini" 2>/dev/null || echo "3389")"

    sed -i "s/^port=$old_port/port=$new_port/" "$ini"

    # 更新防火墙
    if command -v ufw &>/dev/null; then
        ufw delete allow "$old_port"/tcp 2>/dev/null || true
        ufw allow "$new_port"/tcp 2>/dev/null || true
    fi

    # 重启
    if has_systemd; then
        systemctl restart xrdp
    fi

    success "端口已从 $old_port 修改为 $new_port"
}

# --- 3.5 Swap 管理 ---

swap_manage() {
    echo -e "${BOLD}Swap 管理${NC}"
    echo ""
    echo "  1) 创建 Swap（自定义大小）"
    echo "  2) 删除 Swap 文件"
    echo "  3) 查看 Swap 状态"
    echo "  4) 返回"
    read -r -p "选择: " choice

    case "$choice" in
        1)
            local swap_size
            read -r -p "Swap 大小 (GB, 默认 2): " swap_size
            swap_size="${swap_size:-2}"
            if ! [[ "$swap_size" =~ ^[0-9]+$ ]] || [[ "$swap_size" -lt 1 ]]; then
                error "无效大小，请输入正整数 (GB)"
                return 1
            fi

            if swapon --show 2>/dev/null | grep -q swapfile; then
                warn "Swap 文件已存在"
                if [[ "$INTERACTIVE" == "true" ]]; then
                    if ! confirm "是否先删除旧 Swap 并重建?" "n"; then
                        return 0
                    fi
                    swapoff /swapfile 2>/dev/null
                    rm -f /swapfile
                    sed -i '/swapfile/d' /etc/fstab
                else
                    return 0
                fi
            fi

            info "创建 ${swap_size}GB Swap 文件..."
            if command -v fallocate &>/dev/null; then
                fallocate -l "${swap_size}G" /swapfile 2>/dev/null || \
                    dd if=/dev/zero of=/swapfile bs=1M count=$((swap_size * 1024))
            else
                dd if=/dev/zero of=/swapfile bs=1M count=$((swap_size * 1024))
            fi
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            success "${swap_size}GB Swap 创建完成"
            ;;
        2)
            if ! swapon --show 2>/dev/null | grep -q swapfile; then
                warn "未找到 /swapfile，无需删除"
                return 0
            fi
            if [[ "$INTERACTIVE" == "true" ]]; then
                if ! confirm "确定删除 /swapfile?" "n"; then
                    return 0
                fi
            fi
            info "正在删除 Swap 文件..."
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
            sed -i '/swapfile/d' /etc/fstab
            success "Swap 文件已删除"
            ;;
        3)
            echo ""
            swapon --show 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' || echo "当前无 Swap"
            free -h 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
            ;;
        4) return 0 ;;
    esac
    pause
}

# --- 3.6 状态诊断 ---

run_diagnostic() {
    echo ""
    hr
    echo -e "${BOLD}系统诊断报告${NC}"
    hr
    echo ""

    # 基本信息
    echo -e "${CYAN}[系统信息]${NC}"
    echo "  OS: $OS_ID $OS_VERSION_ID ($OS_CODENAME)"
    echo "  架构: $ARCH"
    echo "  容器: $(is_container && echo '是' || echo '否')"
    echo ""

    # XRDP 服务状态
    echo -e "${CYAN}[XRDP 服务]${NC}"
    if dpkg -l xrdp 2>/dev/null | grep -q '^ii'; then
        local xrdp_ver
        xrdp_ver="$(dpkg -l xrdp 2>/dev/null | grep '^ii' | awk '{print $3}')"
        echo "  版本: $xrdp_ver"

        if has_systemd; then
            systemctl is-active xrdp 2>/dev/null && echo -e "  状态: ${GREEN}运行中${NC}" || echo -e "  状态: ${RED}已停止${NC}"
        else
            service xrdp status 2>/dev/null | head -2 | sed 's/\x1b\[[0-9;]*m//g'
        fi
    else
        echo -e "  ${RED}未安装${NC}"
    fi
    echo ""

    # 端口监听
    echo -e "${CYAN}[端口监听]${NC}"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E ':3389|:590.' | while read -r line; do
            echo "  $line"
        done
    fi
    if command -v ss &>/dev/null && ! ss -tlnp 2>/dev/null | grep -qE ':3389|:590.'; then
        echo "  未检测到远程桌面端口监听"
    fi
    echo ""

    # 已安装组件
    echo -e "${CYAN}[已安装组件]${NC}"
    local components
    components="$(get_installed_components)"
    if [[ -n "$components" ]]; then
        echo "$components" | while read -r comp; do
            echo "  - $comp"
        done
    else
        echo "  无"
    fi
    echo ""

    # 内存
    echo -e "${CYAN}[资源]${NC}"
    free -h 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Mem|Swap' | while read -r line; do
        echo "  $line"
    done
    echo ""

    # 磁盘
    df -h / 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk 'NR==2 { printf "  磁盘: %s/%s (已用 %s)\n", $3, $2, $5 }'
    echo ""

    # 日志摘要
    echo -e "${CYAN}[最近日志]${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 10 "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g' | while read -r line; do
            echo "  $line"
        done
    fi
    echo ""
}

# =============================================================================
# 4. 卸载模块
# =============================================================================

uninstall_component() {
    local component="$1"

    if [[ "$component" == "all" ]]; then
        echo ""
        echo -e "${RED}警告: 即将卸载所有远程桌面组件！${NC}"
        echo "包括: 桌面环境、XRDP、VNC、Wine、输入法、Bottles、浏览器"
        echo ""
        if ! confirm "确认卸载全部?" "n"; then
            info "已取消"
            return 1
        fi

        for comp in bottles browser wine input_method vnc xrdp locale desktop; do
            _uninstall_single "$comp"
        done

        # 保留状态文件（记录卸载状态），避免 dpkg 回退检测到其他脚本安装的组件
        success "所有组件已卸载"
        return 0
    fi

    _uninstall_single "$component"
}

# 彻底清理指定桌面家族的包和残留配置
purge_desktop_family() {
    local family_name="$1"
    local pattern="$2"

    info "正在清理 ${family_name} 相关包..."

    # 1. 卸载 metapackage（标记依赖为可自动移除）
    apt-get purge -y ${3:-} 2>/dev/null || true

    # 2. 清理已标记为自动安装且不再需要的包
    apt-get autoremove --purge -y 2>/dev/null || true

    # 3. 查找并卸载仍残留的该家族包（可能被标记为手动安装）
    local residual
    residual="$(dpkg -l 2>/dev/null | grep '^ii' | awk '{print $2}' | grep -E "$pattern" || true)"
    if [[ -n "$residual" ]]; then
        warn "发现残留的 ${family_name} 包，继续清理..."
        # 先标记为自动安装，然后通过 autoremove 清理（更干净）
        echo "$residual" | xargs -r apt-mark auto 2>/dev/null || true
        apt-get autoremove --purge -y 2>/dev/null || true
        # 如果还有残留，直接 purge
        residual="$(dpkg -l 2>/dev/null | grep '^ii' | awk '{print $2}' | grep -E "$pattern" || true)"
        if [[ -n "$residual" ]]; then
            echo "$residual" | xargs -r apt-get purge -y 2>/dev/null || true
        fi
    fi
}

_uninstall_single() {
    local component="$1"

    # 桌面环境特殊处理：检测系统上是否实际有桌面包
    if [[ "$component" == "desktop" ]]; then
        local has_desktop=false
        # 逐个包检查，避免单个未知包导致 dpkg 整体失败（pipefail 下会误判为未安装）
        for de_pkg in xfce4 lxqt mate-desktop-environment gnome-shell plasma-desktop lxde-core; do
            if dpkg -l "$de_pkg" 2>/dev/null | grep -q '^ii'; then
                has_desktop=true
                break
            fi
        done

        if [[ "$has_desktop" == "false" ]] && ! is_component_installed "desktop"; then
            info "组件 desktop 未安装，跳过"
            return 0
        fi
    elif ! is_component_installed "$component"; then
        info "组件 $component 未安装，跳过"
        return 0
    fi

    echo ""
    warn "正在卸载: $component"

    case "$component" in
        desktop)
            # 彻底清理所有桌面环境类型（包括其他脚本安装的）
            purge_desktop_family "XFCE4" "^xfce4|^xubuntu|^thunar|^xfwm4|^xfdesktop4|^tumbler|^mousepad|^ristretto|^parole|^exo-|^garcon|^libxfce4" "xfce4 xfce4-goodies xubuntu-desktop"
            purge_desktop_family "LXQt" "^lxqt|^sddm" "lxqt lxqt-core"
            purge_desktop_family "MATE" "^mate-|^caja|^marco|^pluma|^atril|^engrampa|^eom|^mate-session" "mate-desktop-environment mate-desktop-environment-extras"
            purge_desktop_family "GNOME" "^gnome-|^nautilus|^mutter|^shell" "gnome-shell"
            purge_desktop_family "KDE" "^plasma-|^kde-|^kwin|^dolphin|^konsole" "plasma-desktop"
            purge_desktop_family "LXDE" "^lxde-|^openbox|^pcmanfm" "lxde-core"

            # 清理显示管理器（如果没有其他桌面了）
            if ! dpkg -l gnome-shell plasma-desktop lxde-core xfce4 lxqt mate-desktop-environment 2>/dev/null | grep -q '^ii'; then
                apt-get purge -y lightdm lightdm-gtk-greeter sddm 2>/dev/null || true
            fi

            # 清理残留的系统级配置目录
            rm -rf /etc/xdg/xfce4 /etc/xdg/menus/xfce* /usr/share/xfce4 2>/dev/null || true
            rm -rf /etc/xdg/lxqt /usr/share/lxqt 2>/dev/null || true
            rm -rf /etc/xdg/mate /usr/share/mate 2>/dev/null || true

            # 强制清理可能残留的 session 命令
            info "强制清理残留的桌面启动命令..."
            rm -f /usr/bin/mate-session /usr/bin/startxfce4 /usr/bin/startlxqt 2>/dev/null || true

            # 验证清理结果
            local remaining_sessions=""
            for cmd in mate-session startxfce4 startlxqt; do
                if command -v "$cmd" >/dev/null 2>&1; then
                    remaining_sessions="$remaining_sessions $cmd"
                fi
            done

            if [[ -n "$remaining_sessions" ]]; then
                warn "仍有残留的桌面启动命令:$remaining_sessions，尝试进一步清理..."
                # 通过 dpkg 查找这些命令属于哪个包，然后卸载
                for cmd in $remaining_sessions; do
                    local pkg
                    pkg="$(dpkg -S "$(command -v "$cmd")" 2>/dev/null | awk -F: '{print $1}')"
                    if [[ -n "$pkg" ]]; then
                        info "卸载 $cmd 所属的包: $pkg"
                        apt-get purge -y "$pkg" 2>/dev/null || true
                    fi
                done
                # 最后再清理一次依赖
                apt-get autoremove --purge -y 2>/dev/null || true
            fi

            info "桌面环境已彻底卸载（用户家目录下的个人配置已保留）"
            ;;

        xrdp)
            apt-get purge -y xrdp xorgxrdp 2>/dev/null || true
            # 不清理 /etc/xrdp 残余目录，保留用户数据
            info "XRDP 已卸载"
            ;;

        vnc)
            apt-get purge -y tigervnc-standalone-server tigervnc-common 2>/dev/null || true
            rm -f /etc/systemd/system/vncserver@.service
            if has_systemd; then
                systemctl daemon-reload
            fi
            info "VNC 已卸载"
            ;;

        wine)
            apt-get purge -y wine wine64 wine32 winbind winetricks 2>/dev/null || true
            rm -f /usr/local/bin/swine
            # 不移除用户的 ~/.wine 目录
            info "Wine 已卸载（用户数据保留在 ~/.wine 中）"
            ;;

        input_method)
            apt-get purge -y fcitx5 fcitx5-chinese-addons 2>/dev/null || true
            rm -f /etc/X11/Xsession.d/95fcitx5
            info "输入法已卸载"
            ;;

        bottles)
            if command -v flatpak &>/dev/null; then
                info "正在卸载 Bottles (Flatpak)..."
                flatpak uninstall -y com.usebottles.bottles 2>/dev/null || true
                flatpak uninstall --unused -y 2>/dev/null || true
            fi
            rm -f /usr/local/bin/bottles
            info "Bottles 已卸载"
            ;;

        locale)
            # 不移除 locale 数据，因为它可能被其他应用使用
            warn "locale 数据未移除（系统级组件，可能被其他应用依赖）"
            ;;

        browser)
            apt-get purge -y firefox-esr chromium chromium-browser midori 2>/dev/null || true
            rm -f /usr/share/applications/firefox-esr.desktop
            info "浏览器已卸载"
            ;;

        *)
            warn "未知组件: $component"
            return 1
            ;;
    esac

    # 清理孤立依赖
    apt-get autoremove --purge -y 2>/dev/null || true

    mark_component_removed "$component"
    success "组件 $component 已卸载"
}

uninstall_menu() {
    while true; do
        echo ""
        hr
        echo -e "${BOLD}模块化卸载${NC}"
        hr
        echo "  1) 卸载 Wine"
        echo "  2) 卸载输入法"
        echo "  3) 卸载 VNC"
        echo "  4) 卸载 XRDP"
        echo "  5) 卸载桌面环境"
        echo "  6) 卸载 Bottles"
        echo "  7) 卸载浏览器"
        echo "  8) 一键卸载全部"
        echo "  9) 返回"
        echo ""

        local components
        components="$(get_installed_components 2>/dev/null)"
        if [[ -n "$components" ]]; then
            echo -e "${YELLOW}当前已安装: $(echo "$components" | tr '\n' ' ')${NC}"
        else
            echo -e "${YELLOW}当前未安装任何组件${NC}"
        fi
        echo ""

        read -r -p "选择: " choice

        case "$choice" in
            1) uninstall_component "wine"; pause ;;
            2) uninstall_component "input_method"; pause ;;
            3) uninstall_component "vnc"; pause ;;
            4) uninstall_component "xrdp"; pause ;;
            5) uninstall_component "desktop"; pause ;;
            6) uninstall_component "bottles"; pause ;;
            7) uninstall_component "browser"; pause ;;
            8) uninstall_component "all"; pause ;;
            9) return 0 ;;
            *) echo "无效选择" ;;
        esac
    done
}

# =============================================================================
# 5. 入口层
# =============================================================================

# 交互主菜单
show_main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo ""
        echo -e "${GREEN}==========================================${NC}"
        echo -e "${GREEN}    远程桌面管理脚本 v${SCRIPT_VERSION}${NC}"
        echo -e "${GREEN}==========================================${NC}"
        echo ""
        echo "  1) 安装远程桌面（向导式选择组件）"
        echo "  2) 用户管理（新增/删除/改密码/列表）"
        echo "  3) 服务控制（启动/停止/重启/状态）"
        echo "  4) 防火墙配置（开放/关闭端口）"
        echo "  5) 调整分辨率/端口/Swap"
        echo "  6) 状态诊断"
        echo "  7) 模块化卸载"
        echo "  8) 查看操作日志"
        echo "  9) 安装浏览器"
        echo "  0) 退出"
        echo ""
        read -r -p "选择操作: " choice

        case "$choice" in
            1) install_all ;;
            2) user_management ;;
            3)
                while true; do
                    echo ""
                    echo "  选择服务:"
                    echo "    1) XRDP 服务"
                    echo "    2) XRDP Sesman 服务"
                    echo "    0) 返回上一级"
                    read -r -p "选择 [1]: " svc_choice
                    svc_choice="${svc_choice:-1}"
                    
                    if [[ "$svc_choice" == "0" ]]; then
                        break
                    fi
                    
                    local svc_name=""
                    case "$svc_choice" in
                        2) svc_name="xrdp-sesman" ;;
                        *) svc_name="xrdp" ;;
                    esac
                    
                    while true; do
                        echo ""
                        echo "  选择操作:"
                        echo "    1) 启动  2) 停止  3) 重启  4) 查看状态  5) 开机自启  6) 禁用自启"
                        echo "    0) 返回上一级"
                        read -r -p "选择 [3]: " act_choice
                        act_choice="${act_choice:-3}"
                        
                        if [[ "$act_choice" == "0" ]]; then
                            break
                        fi
                        
                        local act_name=""
                        case "$act_choice" in
                            1) act_name="start" ;;
                            2) act_name="stop" ;;
                            3) act_name="restart" ;;
                            4) act_name="status" ;;
                            5) act_name="enable" ;;
                            6) act_name="disable" ;;
                            *) act_name="restart" ;;
                        esac
                        service_control "$svc_name" "$act_name"
                        pause
                    done
                done
                pause
                ;;
            4)
                while true; do
                    echo ""
                    echo "  防火墙配置:"
                    echo "    1) 开放远程桌面端口（允许外部连接）"
                    echo "    2) 关闭远程桌面端口（禁止外部连接）"
                    echo "    3) 查看防火墙状态和开放端口"
                    echo "    0) 返回上一级"
                    read -r -p "选择 [1]: " fw_choice
                    
                    if [[ "$fw_choice" == "0" ]]; then
                        break
                    fi
                    
                    case "$fw_choice" in
                        2) configure_firewall "close"; pause ;;
                        3) show_firewall_status; pause ;;
                        *) configure_firewall "open"; pause ;;
                    esac
                done
                pause
                ;;
            5)
                while true; do
                    echo ""
                    echo "  系统配置:"
                    echo "    1) 调整分辨率  2) 修改端口  3) Swap 管理"
                    echo "    0) 返回上一级"
                    read -r -p "选择: " sub
                    
                    if [[ "$sub" == "0" ]]; then
                        break
                    fi
                    
                    case "$sub" in
                        1)
                            while true; do
                                echo ""
                                echo "  常用分辨率:"
                                echo "    1) 1280x720  (720p)"
                                echo "    2) 1920x1080 (1080p)"
                                echo "    3) 2560x1440 (2K)"
                                echo "    4) 自定义"
                                echo "    0) 返回上一级"
                                read -r -p "选择 [2]: " res_choice
                                res_choice="${res_choice:-2}"
                                
                                if [[ "$res_choice" == "0" ]]; then
                                    break
                                fi
                                
                                case "$res_choice" in
                                    1) set_resolution 1280 720 24 ;;
                                    2) set_resolution 1920 1080 24 ;;
                                    3) set_resolution 2560 1440 24 ;;
                                    4)
                                        read -r -p "宽度 (如 1920): " w
                                        read -r -p "高度 (如 1080): " h
                                        set_resolution "${w:-1920}" "${h:-1080}" 24
                                        ;;
                                    *) set_resolution 1920 1080 24 ;;
                                esac
                                pause
                            done
                            ;;
                        2) set_port; pause ;;
                        3) swap_manage; pause ;;
                        *) echo "无效选择"; pause ;;
                    esac
                done
                pause
                ;;
            6) run_diagnostic; pause ;;
            7) uninstall_menu ;;
            8)
                if [[ -f "$LOG_FILE" ]]; then
                    echo -e "${BOLD}最近 30 条操作日志:${NC}"
                    echo ""
                    tail -n 30 "$LOG_FILE" | sed 's/\x1b\[[0-9;]*m//g'
                else
                    echo "日志文件不存在"
                fi
                echo ""
                pause
                ;;
            9) install_browser; pause ;;
            0) echo "再见"; exit 0 ;;
            *) echo "无效选择"; pause ;;
        esac
    done
}

# CLI 参数解析
parse_cli_args() {
    local cmd="${1:-}"; shift || true

    case "$cmd" in
        install)
            install_all "$@"
            ;;

        user)
            local action="${1:-}"; shift || true
            case "$action" in
                add)     user_add "$@" ;;
                del)     user_delete "$@" ;;
                passwd)  user_change_password "$@" ;;
                list)    user_list ;;
                *)       echo "用法: $0 user <add|del|passwd|list> [参数]" ;;
            esac
            ;;

        service)
            service_control "${1:-}" "${2:-}"
            ;;

        firewall)
            configure_firewall "${1:-open}"
            ;;

        resolution)
            set_resolution "${1:-1280}" "${2:-720}" "${3:-24}"
            ;;

        port)
            set_port "${1:-}"
            ;;

        status|diag)
            run_diagnostic
            ;;

        uninstall)
            local component="${1:-}"
            if [[ -z "$component" ]]; then
                echo "用法: $0 uninstall <xrdp|vnc|desktop|wine|input_method|bottles|all>"
                return 1
            fi
            uninstall_component "$component"
            ;;

        browser)
            install_browser "${1:-}"
            ;;

        swap)
            swap_manage
            ;;

        --help|help|-h)
            show_help
            ;;

        --version|-v)
            echo "远程桌面管理脚本 v$SCRIPT_VERSION"
            ;;

        menu|"")
            show_main_menu
            ;;

        *)
            echo "未知命令: $cmd"
            echo ""
            show_help
            return 1
            ;;
    esac
}

show_help() {
    cat << 'HELPEOF'
===========================================
  远程桌面管理脚本 v2.0 使用说明
===========================================

用法: sudo bash install.sh [命令] [参数]

命令:

  install [选项]          安装远程桌面
    选项:
      --all               安装全部组件（含 Bottles）
      --xrdp              安装 XRDP
      --no-xrdp           不安装 XRDP
      --vnc               安装 VNC
      --wine=minimal      安装 Wine 核心
      --wine=full         安装 Wine 完整版
      --bottles           安装 Bottles（Wine GUI 管理器）
      --desktop=xfce4     选择桌面: xfce4 / lxqt / mate
      --input-method      安装中文输入法
      --browser=firefox-esr  安装浏览器 (firefox-esr / chromium / midori)
      --desktop-only      仅安装桌面环境

  user add [用户名]       添加用户
  user del <用户名>       删除用户
  user passwd <用户名>    修改密码
  user list               列出用户

  service <服务> <操作>   服务控制 (start/stop/restart/status)

  firewall <open|close>   防火墙配置

  resolution <宽> <高> [色彩深度]
  port <端口号>           修改 XRDP 端口

  status                  系统诊断

  uninstall <组件>        卸载组件
    组件: xrdp, vnc, desktop, wine, input_method, bottles, browser, all

  menu                    进入交互菜单（默认）
  --help                  显示帮助
  --version               显示版本

HELPEOF
}

# =============================================================================
# 6. 主入口
# =============================================================================

main() {
    # 前置检查
    preflight_check

    # 确定交互/非交互模式
    if [[ $# -eq 0 ]]; then
        INTERACTIVE=true
        show_main_menu
    else
        INTERACTIVE=false
        parse_cli_args "$@"
    fi
}

# 启动
main "$@"