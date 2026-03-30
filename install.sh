#!/bin/bash

# =================================================================
# 脚本名称: 追梦人一键安装xfce4+xrdp脚本
# 适用系统: Ubuntu / Debian
# 功能: 桌面环境部署 + Wine 深度兼容修复 + 系统监控 + 维护工具
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/setup_pro_v4.log"

# --- 基础工具函数 ---

log() {
    local level=$1
    local msg=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "${timestamp} [${level}] ${msg}" >> "${LOG_FILE}"
    case $level in
        "INFO") echo -e "${BLUE}[INFO] ${msg}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[OK] ${msg}${NC}" ;;
        "WARN") echo -e "${YELLOW}[WARN] ${msg}${NC}" ;;
        "ERROR") echo -e "${RED}[ERROR] ${msg}${NC}" ;;
    esac
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误: 请以 root 权限运行此脚本${NC}"
        exit 1
    fi
}

# --- 核心功能模块 ---

# 1. 用户管理 (支持自定义用户名逻辑)
create_user_logic() {
    local default_name="zmr$(date +%Y%m)"
    echo -e "\n${BLUE}--- 用户配置 ---${NC}"
    read -p "请输入要创建的用户名 (直接回车默认: $default_name): " input_name
    
    # 如果用户输入为空，则使用默认名
    TARGET_USER=${input_name:-$default_name}
    
    if id "$TARGET_USER" &>/dev/null; then
        log "WARN" "用户 $TARGET_USER 已存在，跳过创建。"
    else
        echo -e "密码设置方式:\n1) 自己设置密码 (默认)\n2) 随机生成强密码"
        read -p "选择 [1-2]: " pass_mode
        if [ "$pass_mode" == "2" ]; then
            USER_PASS=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 16)
            log "SUCCESS" "为 $TARGET_USER 生成随机密码: ${USER_PASS}"
            echo -e "${RED}请务必记录好此密码！${NC}"
        else
            read -s -p "请输入新用户密码: " USER_PASS
            echo ""
        fi
        
        useradd -m -s /bin/bash "$TARGET_USER"
        echo "${TARGET_USER}:${USER_PASS}" | chpasswd
        usermod -aG sudo "$TARGET_USER"
        log "SUCCESS" "用户 $TARGET_USER 创建成功。"
    fi
}

# 2. Wine 深度修复补丁 (解决 c0000135, X Error, 驱动错误)
fix_wine_environment() {
    log "INFO" "正在应用 Wine 远程桌面兼容性补丁..."
    
    # 启用32位架构
    dpkg --add-architecture i386 && apt update
    
    # 安装缺失的底层库: winbind(解决NTLM), mesa-dri(解决3D驱动), 32位图形库
    apt install -y winbind wine wine32 wine64 libgl1-mesa-dri:i386 libgl1-mesa-glx:i386 mesa-utils
    
    # 创建 'swine' (Software Wine) 封装命令
    # 强制开启软件渲染 (LIBGL_ALWAYS_SOFTWARE) 
    # 禁用引起远程桌面崩溃的 VidMode 扩展 (WINE_NO_VIDMODE_EXTENSIONS)
    cat <<EOF > /usr/local/bin/swine
#!/bin/bash
export LIBGL_ALWAYS_SOFTWARE=1
export WINE_NO_VIDMODE_EXTENSIONS=1
export DISPLAY=:10.0
wine "\$@"
EOF
    chmod +x /usr/local/bin/swine
    log "SUCCESS" "Wine 补丁已应用。请在桌面终端使用 'swine 你的程序.exe' 运行。"
}

# 3. 性能监控模块
sys_monitor() {
    while true; do
        clear
        echo -e "${BLUE}================ 实时监控 (按 q 退出) ================${NC}"
        local rdp_port=$(grep "port=" /etc/xrdp/xrdp.ini | head -1 | cut -d= -f2)
        echo -e "${YELLOW}[系统负载]:${NC} $(uptime | awk -F'load average:' '{print $2}')"
        echo -e "${YELLOW}[内存占用]:${NC}"
        free -h | grep -E "Mem|Swap"
        echo -e "${YELLOW}[RDP 端口]:${NC} ${rdp_port:-3389} | ${YELLOW}[连接数]:${NC} $(ss -ant | grep -c ":${rdp_port:-3389}")"
        echo -e "${BLUE}========================================================${NC}"
        read -t 3 -n 1 char
        [[ "$char" == "q" ]] && break
    done
}

# 4. 系统清理模块
system_cleanup() {
    log "INFO" "开始执行系统清理..."
    apt-get autoremove --purge -y
    apt-get autoclean -y
    [ -x "$(command -v journalctl)" ] && journalctl --vacuum-time=1d
    rm -rf /tmp/*
    log "SUCCESS" "清理任务执行完毕。"
}

# 5. Swap 管理模块
manage_swap() {
    read -p "请输入 Swap 大小 (GB，输入 0 则关闭): " sw_gb
    if [ "$sw_gb" == "0" ]; then
        swapoff -a && sed -i '/swapfile/d' /etc/fstab && log "WARN" "Swap 已禁用"
    elif [[ "$sw_gb" =~ ^[0-9]+$ ]]; then
        swapoff -a
        fallocate -l "${sw_gb}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((sw_gb * 1024))
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log "SUCCESS" "Swap 已配置为 ${sw_gb}GB"
    fi
}

# --- 主程序逻辑 ---

install_process() {
    log "INFO" "开始全自动安装流程..."
    # 1. 系统更新
    apt update && apt upgrade -y
    # 2. 用户创建
    create_user_logic
    # 3. 安装桌面环境
    apt install -y xfce4 xfce4-goodies xrdp
    echo "startxfce4" > "/home/$TARGET_USER/.xsession"
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.xsession"
    # 4. 修复 Wine
    fix_wine_environment
    # 5. 重启服务
    systemctl enable xrdp && systemctl restart xrdp
    log "SUCCESS" "安装部署全部完成！"
}

main_menu() {
    while true; do
        clear
        echo -e "${GREEN}================================================"
        echo -e "    追梦人一键安装xfce4+xrdp脚本"
        echo -e "================================================"
        echo -e "1) ${BLUE}执行全自动安装部署${NC}"
        echo -e "2) 用户管理 (新增/删除/改密)"
        echo -e "3) 修改 RDP 端口与防火墙"
        echo -e "4) Swap 虚拟内存管理"
        echo -e "5) ${YELLOW}系统实时性能监控${NC}"
        echo -e "6) ${GREEN}系统深度清理${NC}"
        echo -e "7) 修复并更新 Wine 环境"
        echo -e "8) 退出"
        echo -e "================================================"
        read -p "请选择操作 [1-8]: " choice

        case $choice in
            1) install_process ;;
            2) 
                read -p "1.新增 2.删除: " u_op
                if [ "$u_op" == "1" ]; then create_user_logic
                else read -p "用户名: " un; userdel -r "$un"; fi ;;
            3) 
                read -p "新端口: " np
                sed -i "s/port=.*/port=$np/g" /etc/xrdp/xrdp.ini
                systemctl restart xrdp && log "SUCCESS" "端口已改 $np" ;;
            4) manage_swap ;;
            5) sys_monitor ;;
            6) system_cleanup ;;
            7) fix_wine_environment ;;
            8) exit 0 ;;
            *) echo "无效输入" ; sleep 1 ;;
        esac
    done
}

# 脚本入口
check_root
touch "$LOG_FILE"
main_menu
