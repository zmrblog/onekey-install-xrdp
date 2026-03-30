#!/bin/bash

# =================================================================
# 脚本名称: setup_final_v6.sh
# 适用系统: Ubuntu / Debian
# 功能: 桌面部署 + 交互增强 + 分项/全量安装卸载 + 性能监控
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/setup_pro_v6.log"

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
        echo -e "${RED}错误: 请以 root 权限运行此脚本${NC}"
        exit 1
    fi
}

# --- 2. 增强型用户创建模块 ---

create_user_logic() {
    local default_name="zmr$(date +%Y%m)"
    while true; do
        echo -e "\n${BLUE}--- 远程用户配置 ---${NC}"
        read -p "请输入用户名 (直接回车默认: $default_name): " input_name
        TARGET_USER=${input_name:-$default_name}
        
        read -p "确认使用用户名 [$TARGET_USER] 吗？(y/n): " confirm_user
        [[ "$confirm_user" =~ ^[Yy]$ ]] && break
    done

    if id "$TARGET_USER" &>/dev/null; then
        log "WARN" "用户 $TARGET_USER 已存在。"
    else
        while true; do
            echo -e "密码设置方式: 1) 手动输入  2) 随机生成"
            read -p "选择 [1-2]: " pass_mode
            if [ "$pass_mode" == "2" ]; then
                USER_PASS=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 16)
                echo -e "${YELLOW}生成的随机密码为: ${USER_PASS}${NC}"
            else
                read -s -p "请输入新用户密码: " pass1
                echo -e "\n"
                read -s -p "请再次输入密码以确认: " pass2
                echo -e "\n"
                if [ "$pass1" != "$pass2" ]; then
                    echo -e "${RED}两次密码输入不一致，请重试！${NC}"
                    continue
                fi
                USER_PASS=$pass1
            fi
            
            read -p "确认设置此密码吗？(y/n): " confirm_pass
            [[ "$confirm_pass" =~ ^[Yy]$ ]] && break
        done

        useradd -m -s /bin/bash "$TARGET_USER"
        echo "${TARGET_USER}:${USER_PASS}" | chpasswd
        usermod -aG sudo "$TARGET_USER"
        log "SUCCESS" "用户 $TARGET_USER 创建成功并已加入 sudo 组。"
    fi
}

# --- 3. 模块化安装函数库 ---

install_fcitx5() {
    log "INFO" "正在安装 Fcitx5 输入法..."
    apt install -y fcitx5 fcitx5-chinese-addons
    if ! grep -q "GTK_IM_MODULE" /etc/environment; then
        cat <<EOF >> /etc/environment
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
EOF
    fi
    log "SUCCESS" "Fcitx5 安装完毕。"
}

install_falkon() {
    log "INFO" "正在安装 Falkon 浏览器..."
    apt install -y falkon
    log "SUCCESS" "Falkon 安装完毕。"
}

install_wine_pro() {
    log "INFO" "正在深度部署 Wine 环境 (含 32位支持与 RDP 修复)..."
    dpkg --add-architecture i386 && apt update
    # 强制安装核心包，确保 wine 命令可用
    apt install -y wine wine64 wine32 winbind libgl1-mesa-dri:i386 libgl1-mesa-glx:i386 mesa-utils
    
    # 重新创建 swine 指令
    cat <<EOF > /usr/local/bin/swine
#!/bin/bash
export LIBGL_ALWAYS_SOFTWARE=1
export WINE_NO_VIDMODE_EXTENSIONS=1
wine "\$@"
EOF
    chmod +x /usr/local/bin/swine
    log "SUCCESS" "Wine 部署成功。请使用 'swine 程序名.exe' 运行。"
}

# --- 4. 菜单逻辑控制 ---

# 分软件安装菜单
menu_individual_install() {
    while true; do
        clear
        echo -e "${BLUE}================ 单项软件安装 ================ ${NC}"
        echo "1) 安装 Fcitx5 中文输入法"
        echo "2) 安装 Falkon 浏览器"
        echo "3) 安装 Wine 兼容层 (含 Swine 修复)"
        echo "4) 返回主菜单"
        echo -e "=============================================="
        read -p "请选择 [1-4]: " i_choice
        case $i_choice in
            1) install_fcitx5 ; sleep 2 ;;
            2) install_falkon ; sleep 2 ;;
            3) install_wine_pro ; sleep 2 ;;
            4) break ;;
        esac
    done
}

# 分软件卸载菜单
menu_individual_uninstall() {
    while true; do
        clear
        echo -e "${RED}================ 软件卸载与清理 ================ ${NC}"
        echo "1) 卸载 Fcitx5 输入法"
        echo "2) 卸载 Falkon 浏览器"
        echo "3) 卸载 Wine 环境"
        echo "4) [危险] 一键卸载所有扩展软件 (以上全部)"
        echo "5) 卸载 XFCE4 桌面与 XRDP"
        echo "6) 返回主菜单"
        echo -e "================================================"
        read -p "请选择 [1-6]: " u_choice
        case $u_choice in
            1) apt purge -y fcitx5* ; sed -i '/fcitx/d' /etc/environment ; apt autoremove -y ; log "SUCCESS" "已移除" ; sleep 2 ;;
            2) apt purge -y falkon ; apt autoremove -y ; log "SUCCESS" "已移除" ; sleep 2 ;;
            3) apt purge -y wine* winbind ; rm -f /usr/local/bin/swine ; apt autoremove -y ; log "SUCCESS" "已移除" ; sleep 2 ;;
            4) 
                read -p "确定要删除所有可选软件吗？(y/n): " c_all
                if [[ "$c_all" =~ ^[Yy]$ ]]; then
                    apt purge -y fcitx5* falkon wine* winbind
                    sed -i '/fcitx/d' /etc/environment
                    rm -f /usr/local/bin/swine
                    apt autoremove -y
                    log "SUCCESS" "所有扩展软件已清理。"
                fi
                sleep 2 ;;
            5) 
                read -p "确定卸载桌面吗？这会导致远程断开！(y/n): " c_desk
                if [[ "$c_desk" =~ ^[Yy]$ ]]; then
                    apt purge -y xfce4* xrdp ; apt autoremove -y
                    log "SUCCESS" "桌面已移除。"
                fi
                sleep 2 ;;
            6) break ;;
        esac
    done
}

# --- 5. 主程序逻辑 ---

install_process() {
    log "INFO" "开始全自动安装部署..."
    apt update && apt upgrade -y
    create_user_logic
    
    log "INFO" "安装 XFCE4 与 XRDP..."
    apt install -y xfce4 xfce4-goodies xrdp
    echo "startxfce4" > "/home/$TARGET_USER/.xsession"
    chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.xsession"
    
    # 默认安装中文环境
    apt install -y locales fonts-wqy-zenhei
    locale-gen zh_CN.UTF-8
    
    echo -e "\n${YELLOW}--- 扩展软件可选安装 ---${NC}"
    read -p "是否安装输入法？(y/n): " c1
    [[ "$c1" =~ ^[Yy]$ ]] && install_fcitx5
    read -p "是否安装浏览器？(y/n): " c2
    [[ "$c2" =~ ^[Yy]$ ]] && install_falkon
    read -p "是否安装 Wine 兼容层？(y/n): " c3
    [[ "$c3" =~ ^[Yy]$ ]] && install_wine_pro
    
    systemctl restart xrdp
    log "SUCCESS" "全自动部署完成！"
    sleep 3
}

main_menu() {
    while true; do
        clear
        echo -e "${GREEN}===================================================="
        echo -e "  Ubuntu/Debian 桌面部署与维护脚本 V6"
        echo -e "====================================================${NC}"
        echo -e "1) ${BLUE}执行全自动安装部署${NC}"
        echo -e "2) ${BLUE}单项软件安装子菜单${NC} (输入法/浏览器/Wine)"
        echo -e "3) ${RED}软件卸载清理子菜单${NC} (含一键全删)"
        echo -e "4) 用户管理 (新增/删除/改密)"
        echo -e "5) 修改 RDP 远程端口"
        echo -e "6) Swap 虚拟内存管理"
        echo -e "7) 系统实时性能监控"
        echo -e "8) 退出"
        echo -e "===================================================="
        read -p "请选择操作 [1-8]: " choice

        case $choice in
            1) install_process ;;
            2) menu_individual_install ;;
            3) menu_individual_uninstall ;;
            4) 
                read -p "1.新增 2.删除 3.改密 : " u_op
                if [ "$u_op" == "1" ]; then create_user_logic
                elif [ "$u_op" == "2" ]; then read -p "名: " un; userdel -r "$un"
                elif [ "$u_op" == "3" ]; then read -p "名: " un; passwd "$un"; fi ;;
            5) read -p "新端口: " np; sed -i "s/port=.*/port=$np/g" /etc/xrdp/xrdp.ini; systemctl restart xrdp ;;
            6) 
                read -p "Swap大小(GB, 0关闭): " sw_gb
                if [ "$sw_gb" == "0" ]; then swapoff -a; sed -i '/swapfile/d' /etc/fstab
                else fallocate -l "${sw_gb}G" /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile; fi ;;
            7) 
                while true; do
                    clear; echo "监控中 (按q退出)..."
                    uptime; free -h; ss -ant | grep -c ":3389"
                    read -t 3 -n 1 char; [[ "$char" == "q" ]] && break
                done ;;
            8) exit 0 ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

check_root
touch "$LOG_FILE"
main_menu
