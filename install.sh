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
    info "正在执行: $desc"
    if "$@"; then
        success "$desc - 完成"
        return 0
    else
        error "$desc - 失败"
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
    local lock_dir="${LOCK_FILE}.dir"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        local pid
        pid="$(cat "${lock_dir}/pid" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            error "脚本已在运行中 (PID: $pid)"
            return 1
        fi
        # 过期锁，清理后重试
        rm -rf "$lock_dir"
        if ! mkdir "$lock_dir" 2>/dev/null; then
            error "无法获取锁"
            return 1
        fi
    fi
    echo $$ > "${lock_dir}/pid"
    trap 'rm -rf "$lock_dir"' EXIT INT TERM
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
    scan_display_manager

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
            if ! confirm "是否继续安装?" "n"; then
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
# 2. 安装模块
# =============================================================================

# --- 2.1 基础前提 ---

ensure_prerequisites() {
    info "检查基础依赖..."

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

    # 更新包列表
    if ! safe_exec "更新软件包列表" apt-get update; then
        error "apt update 失败，请检查网络和软件源配置"
        return 1
    fi

    return 0
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

# 注入 XRDP startwm.sh 的中文环境变量
inject_xrdp_locale() {
    local desktop="${1:-$DESKTOP_CHOICE}"
    local wm_script="/etc/xrdp/startwm.sh"

    if [[ ! -f "$wm_script" ]]; then
        return 0
    fi

    info "注入 XRDP 中文环境变量（桌面: $desktop）..."

    # 清理旧的重复配置
    sed -i '/^export LANG=/d; /^export LANGUAGE=/d; /^export LC_ALL=/d' "$wm_script"
    # 清理旧的 session 启动命令（startxfce4/startlxqt/mate-session）
    sed -i '/^startxfce4$/d; /^startlxqt$/d; /^mate-session$/d' "$wm_script"

    # 在第1行后插入环境变量（写入临时文件确保兼容性）
    {
        head -n 1 "$wm_script"
        echo 'export LANG=zh_CN.UTF-8'
        echo 'export LANGUAGE=zh_CN:zh'
        echo 'export LC_ALL=zh_CN.UTF-8'
        tail -n +2 "$wm_script"
    } > "${wm_script}.tmp" && mv "${wm_script}.tmp" "$wm_script"

    # 修复黑屏问题（注释掉默认的 Xsession 执行）
    sed -i 's/^test -x \/etc\/X11\/Xsession/#test -x \/etc\/X11\/Xsession/' "$wm_script"
    sed -i 's/^exec \/bin\/sh \/etc\/X11\/Xsession/#exec \/bin\/sh \/etc\/X11\/Xsession/' "$wm_script"

    # 追加对应桌面的启动命令
    local session_cmd
    case "$desktop" in
        lxqt)    session_cmd="startlxqt" ;;
        mate)    session_cmd="mate-session" ;;
        *)       session_cmd="startxfce4" ;;
    esac
    echo "$session_cmd" >> "$wm_script"

    success "XRDP 中文环境变量已注入，启动桌面: $session_cmd"
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

    # 3. 解析组件选择
    local do_desktop=true
    local do_xrdp=true
    local do_vnc=false
    local do_wine=""
    local do_input_method=false
    local do_bottles=false

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
                --desktop=xfce4) DESKTOP_CHOICE="xfce4" ;;
                --desktop=lxqt)  DESKTOP_CHOICE="lxqt" ;;
                --desktop=mate)  DESKTOP_CHOICE="mate" ;;
                --all)           do_vnc=true; do_wine="full"; do_input_method=true; do_bottles=true ;;
                --desktop-only)  do_xrdp=false ;;
            esac
        done
    elif [[ "$INTERACTIVE" == "true" ]]; then
        echo -e "${BOLD}请选择要安装的组件:${NC}"
        echo ""

        # 桌面环境选择
        echo -e "  桌面环境:"
        echo -e "    ${GREEN}1)${NC} XFCE4（轻量，推荐） ${GREEN}[默认]${NC}"
        echo -e "    ${GREEN}2)${NC} LXQt（极轻量）"
        echo -e "    ${GREEN}3)${NC} MATE（中等资源占用）"
        echo ""
        read -r -p "选择桌面 [1-3，默认 1]: " de_choice
        case "$de_choice" in
            2) DESKTOP_CHOICE="lxqt" ;;
            3) DESKTOP_CHOICE="mate" ;;
            *) DESKTOP_CHOICE="xfce4" ;;
        esac

        echo ""
        echo -e "  选中桌面: ${CYAN}$DESKTOP_CHOICE${NC}"
        echo ""

        # 远程协议
        echo -e "  ${GREEN}4)${NC} XRDP 远程桌面              [推荐]"
        echo -e "  ${GREEN}5)${NC} VNC 远程桌面                [可选]"

        # 可选软件
        echo -e "  ${GREEN}6)${NC} Wine 兼容环境               [可选]"
        echo -e "  ${GREEN}7)${NC} Fcitx5 中文输入法           [可选]"
        echo -e "  ${GREEN}8)${NC} Bottles (图形化 Wine 管理)  [可选]"
        echo ""

        read -r -p "输入要跳过的组件编号（如: 5,6,7），直接回车安装全部: " skip_str

        if [[ -n "$skip_str" ]]; then
            IFS=',' read -ra skip_arr <<< "$skip_str"
            for s in "${skip_arr[@]}"; do
                case "$(echo "$s" | tr -d ' ')" in
                    4) do_xrdp=false ;;
                    5) do_vnc=false ;;
                    6) do_wine="" ;;
                    7) do_input_method=false ;;
                    8) do_bottles=false ;;
                esac
            done
        else
            do_vnc=true
            do_wine="full"
            do_input_method=true
            do_bottles=true
        fi
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

    # 5. 防火墙
    if [[ "$do_xrdp" == "true" ]] || [[ "$do_vnc" == "true" ]]; then
        configure_firewall open
    fi

    echo ""
    hr

    if [[ "$failed" == "true" ]]; then
        write_state "status" "partial_failed"
        error "安装过程中出现错误，部分组件可能未正确安装"
        echo "请查看日志: $LOG_FILE"
        return 1
    fi

    write_state "status" "installed"
    success "远程桌面安装完成！"
    echo ""
    info "连接方式: 使用 Windows 远程桌面连接到 $(hostname -I 2>/dev/null | awk '{print $1}' || echo '服务器IP'):${XRDP_PORT}"
    echo "如需完整中文支持，建议重启系统。"
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
        echo "  2) 随机生成"
        read -r -p "选择: " pw_choice

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
        start|stop|restart|status|enable|disable)
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
            swapon --show 2>/dev/null || echo "当前无 Swap"
            free -h
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
            systemctl is-active xrdp 2>/dev/null && echo "  状态: ${GREEN}运行中${NC}" || echo "  状态: ${RED}已停止${NC}"
        else
            service xrdp status 2>/dev/null | head -2
        fi
    else
        echo "  ${RED}未安装${NC}"
    fi
    echo ""

    # 端口监听
    echo -e "${CYAN}[端口监听]${NC}"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -E ':3389|:590.' | while read -r line; do
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
    free -h | grep -E 'Mem|Swap' | while read -r line; do
        echo "  $line"
    done
    echo ""

    # 磁盘
    df -h / | awk 'NR==2 { printf "  磁盘: %s/%s (已用 %s)\n", $3, $2, $5 }'
    echo ""

    # 日志摘要
    echo -e "${CYAN}[最近日志]${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 10 "$LOG_FILE" | while read -r line; do
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
        echo "包括: 桌面环境、XRDP、VNC、Wine、输入法、Bottles"
        echo ""
        if ! confirm "确认卸载全部?" "n"; then
            info "已取消"
            return 1
        fi

        for comp in bottles wine input_method vnc xrdp locale desktop; do
            _uninstall_single "$comp"
        done

        # 保留状态文件（记录卸载状态），避免 dpkg 回退检测到其他脚本安装的组件
        success "所有组件已卸载"
        return 0
    fi

    _uninstall_single "$component"
}

_uninstall_single() {
    local component="$1"

    if ! is_component_installed "$component"; then
        info "组件 $component 未安装，跳过"
        return 0
    fi

    echo ""
    warn "正在卸载: $component"

    case "$component" in
        desktop)
            # 精确移除已安装的桌面组件，不影响其他桌面
            apt-get purge -y xfce4 xfce4-goodies xubuntu-desktop 2>/dev/null || true
            apt-get purge -y lxqt lxqt-core 2>/dev/null || true
            apt-get purge -y mate-desktop-environment mate-desktop-environment-extras 2>/dev/null || true
            # 不移除 lightdm/sddm 如果有其他桌面可能在用
            if ! dpkg -l gnome-shell plasma-desktop lxde-core 2>/dev/null | grep -q '^ii'; then
                apt-get purge -y lightdm lightdm-gtk-greeter sddm 2>/dev/null || true
            fi
            info "桌面环境已卸载（display manager 保留以防其他桌面依赖）"
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
        echo "  7) 一键卸载全部"
        echo "  8) 返回"
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
            7) uninstall_component "all"; pause ;;
            8) return 0 ;;
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
        echo "  0) 退出"
        echo ""
        read -r -p "选择操作: " choice

        case "$choice" in
            1) install_all ;;
            2) user_management ;;
            3)
                echo "可选服务: xrdp, xrdp-sesman"
                read -r -p "输入 服务 操作 (如: xrdp restart): " svc act
                service_control "$svc" "$act"
                pause
                ;;
            4)
                read -r -p "操作 (open/close): " fw_act
                configure_firewall "$fw_act"
                pause
                ;;
            5)
                echo "  1) 调整分辨率  2) 修改端口  3) Swap 管理"
                read -r -p "选择: " sub
                case "$sub" in
                    1)
                        read -r -p "宽 高 色彩深度 (如: 1920 1080 24): " w h d
                        set_resolution "${w:-1280}" "${h:-720}" "${d:-24}"
                        ;;
                    2) set_port ;;
                    3) swap_manage ;;
                esac
                pause
                ;;
            6) run_diagnostic; pause ;;
            7) uninstall_menu ;;
            8)
                if [[ -f "$LOG_FILE" ]]; then
                    echo -e "${BOLD}最近 30 条操作日志:${NC}"
                    echo ""
                    tail -n 30 "$LOG_FILE"
                else
                    echo "日志文件不存在"
                fi
                echo ""
                pause
                ;;
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
    组件: xrdp, vnc, desktop, wine, input_method, bottles, all

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