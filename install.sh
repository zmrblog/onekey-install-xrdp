#!/bin/bash

# =================================================================
# 脚本名称: 追梦人一键安装xfce4+xrdp脚本
# 适用系统: Ubuntu / Debian
# 功能: 桌面部署 + 可选安装(输入法/浏览器/Wine) + 模块化卸载 + 综合监控
# =================================================================

# 颜色定义 (严禁使用中文变量名，防止 bash 解析报错)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/setup_pro_v5.log"

# --- 1. 基础工具函数 ---

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
        echo -e "${RED}错误: 请以 root 权限运行此脚本 (sudo ./script.sh)${NC}"
        exit 1
    fi
}

# --- 2. 核心安装与配置模块 ---

create_user_logic() {
    local default_name="zmr$(date +%Y%m)"
    echo -e "\n${BLUE}--- 用户配置 ---${NC}"
    read -p "请输入要创建的远程用户名 (直接回车默认: $default_name): " input_name
    
    TARGET_USER=${input_name:-$default_name}
    
    if id "$TARGET_USER" &>/dev/null; then
        log "WARN" "用户 $TARGET_USER 已存在，跳过创建。"
    else
        echo -e "密码设置方式:\n1) 手动输入 (默认)\n2) 随机生成强密码"
        read -p "选择 [1-2]: " pass_mode
        if [ "$pass_mode" == "2" ]; then
            USER_PASS=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 16)
            log "SUCCESS" "为 $TARGET_USER 生成随机密码: ${USER_PASS}"
            echo -e "${RED}请务必记录好此密码！${NC}"
            sleep 3
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

setup_chinese_env() {
    log "INFO" "配置中文语言环境与字体..."
    apt install -y locales fonts-wqy-zenhei
    sed -i 's/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen zh_CN.UTF-8
    update-locale LANG=zh_CN.UTF-8
    log "SUCCESS" "中文环境配置完毕。"
}

install_optional_apps() {
    echo -e "\n${BLUE}--- 可选软件安装 ---${NC}"
    
    read -p "是否安装 Fcitx5 轻量中文输入法？(y/n): " ime_choice
    if [[ "$ime_choice" =~ ^[Yy]$ ]]; then
        log "INFO" "正在安装 Fcitx5..."
        apt install -y fcitx5 fcitx5-chinese-addons
        # 写入全局环境变量
        if ! grep -q "GTK_IM_MODULE=fcitx" /etc/environment; then
            cat <<EOF >> /etc/environment
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
        fi
        log "SUCCESS" "Fcitx5 安装完成。"
    fi

    read -p "是否安装 Falkon 浏览器？(y/n): " falkon_choice
    if [[ "$falkon_choice" =~ ^[Yy]$ ]]; then
        log "INFO" "正在安装 Falkon..."
        apt install -y falkon
        log "SUCCESS" "Falkon 安装完成。"
    fi

    read -p "是否安装 Wine 兼容层 (含远程桌面深度修复)？(y/n): " wine_choice
    if [[ "$wine_choice" =~ ^[Yy]$ ]]; then
        log "INFO" "正在应用 Wine 环境与 XRDP 兼容补丁..."
        dpkg --add-architecture i386 && apt update
        apt install -y winbind wine wine32 wine64 libgl1-mesa-dri:i386 libgl1-mesa-glx:i386 mesa-utils
        
        # 写入专门针对 RDP 优化的 swine 命令
        cat <<EOF > /usr/local/bin/swine
#!/bin/bash
export LIBGL_ALWAYS_SOFTWARE=1
export WINE_NO_VIDMODE_EXTENSIONS=1
export DISPLAY=:10.0
wine "\$@"
EOF
        chmod +x /usr/local/bin/swine
        log "SUCCESS" "Wine 部署完成。请使用 'swine 你的程序.exe' 来运行。"
    fi
}

install_process() {
    log "INFO" "开始全自动安装流程..."
    apt update && apt upgrade -y
    
    create_user_logic
    
    log "INFO" "安装 XFCE4 与 XRDP..."
    DEBIAN_FRONTEND=noninteractive apt install -y xfce4 xfce4-goodies xrdp
    echo "startxfce4" > "/home/$TARGET_USER/.xsession"
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.xsession"
    
    setup_chinese_env
    install_optional_apps
    
    systemctl enable xrdp && systemctl restart xrdp
    log "SUCCESS" "核心部署完毕！(建议使用 sudo reboot 重启以使中文与输入法生效)"
    sleep 3
}

# --- 3. 卸载与清理模块 ---

uninstall_components() {
    while true; do
        clear
        echo -e "${BLUE}================ 软件单独卸载面板 ================ ${NC}"
        echo "1) 卸载 Fcitx5 中文输入法"
        echo "2) 卸载 Falkon 浏览器"
        echo "3) 卸载 Wine 环境及兼容补丁"
        echo "4) 卸载 XFCE4 桌面与 XRDP 服务"
        echo "5) 返回主菜单"
        echo -e "=================================================="
        read -p "请选择要卸载的组件 [1-5]: " un_choice
        
        case $un_choice in
            1) 
                log "INFO" "正在卸载 Fcitx5..."
                apt-get purge -y fcitx5 fcitx5-chinese-addons
                sed -i '/fcitx/d' /etc/environment
                apt-get autoremove -y
                log "SUCCESS" "输入法已完全卸载。"
                sleep 2 ;;
            2)
                log "INFO" "正在卸载 Falkon..."
                apt-get purge -y falkon
                apt-get autoremove -y
                log "SUCCESS" "浏览器已完全卸载。"
                sleep 2 ;;
            3)
                log "INFO" "正在卸载 Wine 及相关图形库..."
                apt-get purge -y wine wine32 wine64 winbind libgl1-mesa-dri:i386 libgl1-mesa-glx:i386
                rm -f /usr/local/bin/swine
                apt-get autoremove -y
                log "SUCCESS" "Wine 环境已清理。"
                sleep 2 ;;
            4)
                log "WARN" "即将卸载桌面环境，这会中断当前的 RDP 连接！"
                read -p "确认卸载吗？(y/n): " confirm_desk
                if [[ "$confirm_desk" =~ ^[Yy]$ ]]; then
                    systemctl stop xrdp
                    apt-get purge -y xfce4 xfce4-goodies xrdp
                    apt-get autoremove -y
                    log "SUCCESS" "桌面与远程服务已卸载。"
                    sleep 2
                fi ;;
            5) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

# --- 4. 日常维护与监控模块 ---

sys_monitor() {
    while true; do
        clear
        echo -e "${BLUE}================ 实时性能监控 (按 q 退出) ================${NC}"
        local rdp_port=$(grep "port=" /etc/xrdp/xrdp.ini | head -1 | cut -d= -f2)
        echo -e "${YELLOW}[系统负载]:${NC} $(uptime | awk -F'load average:' '{print $2}')"
        echo -e "${YELLOW}[内存占用]:${NC}"
        free -h | grep -E "Mem|Swap"
        echo -e "${YELLOW}[RDP 端口]:${NC} ${rdp_port:-3389} | ${YELLOW}[活跃连接数]:${NC} $(ss -ant | grep -c ":${rdp_port:-3389}")"
        echo -e "${BLUE}========================================================${NC}"
        read -t 3 -n 1 char
        [[ "$char" == "q" ]] && break
    done
}

system_cleanup() {
    log "INFO" "开始执行系统级垃圾清理..."
    apt-get autoremove --purge -y
    apt-get autoclean -y
    [ -x "$(command -v journalctl)" ] && journalctl --vacuum-time=1d
    rm -rf /tmp/* /var/tmp/*
    log "SUCCESS" "垃圾清理完毕，释放了磁盘空间。"
    sleep 2
}

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
    sleep 2
}

# --- 主程序入口 ---

main_menu() {
    while true; do
        clear
        echo -e "${GREEN}===================================================="
        echo -e "  追梦人一键安装xfce4+xrdp脚本"
        echo -e "====================================================${NC}"
        echo -e "1) ${BLUE}执行初次安装部署${NC} (含中文/可选软件)"
        echo -e "2) 用户管理 (新增/删除/改密)"
        echo -e "3) 修改 RDP 远程端口"
        echo -e "4) Swap 虚拟内存管理"
        echo -e "5) ${YELLOW}系统实时性能监控${NC}"
        echo -e "6) ${RED}组件分项卸载面板${NC} (卸载输入法/浏览器/Wine等)"
        echo -e "7) 系统深度垃圾清理"
        echo -e "8) 退出"
        echo -e "===================================================="
        read -p "请选择操作 [1-8]: " choice

        case $choice in
            1) install_process ;;
            2) 
                read -p "1.新增 2.删除 3.改密 : " u_op
                if [ "$u_op" == "1" ]; then create_user_logic
                elif [ "$u_op" == "2" ]; then read -p "用户名: " un; userdel -r "$un" && log "SUCCESS" "已删除"
                elif [ "$u_op" == "3" ]; then read -p "用户名: " un; passwd "$un"; fi 
                sleep 2 ;;
            3) 
                read -p "请输入新端口号: " np
                if [[ "$np" =~ ^[0-9]+$ ]]; then
                    sed -i "s/port=.*/port=$np/g" /etc/xrdp/xrdp.ini
                    systemctl restart xrdp && log "SUCCESS" "RDP 端口已改为 $np"
                fi 
                sleep 2 ;;
            4) manage_swap ;;
            5) sys_monitor ;;
            6) uninstall_components ;;
            7) system_cleanup ;;
            8) exit 0 ;;
            *) echo "无效输入" ; sleep 1 ;;
        esac
    done
}

# 运行前置检查与环境准备
check_root
touch "$LOG_FILE"
main_menu
