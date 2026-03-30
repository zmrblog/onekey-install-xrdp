#!/bin/bash

# =================================================================
# 脚本名称: 追梦人一键安装xfce4+xrdp
# 适用系统: Ubuntu / Debian
# 功能: 桌面环境 + 深度 Wine 修复 + 单项/全量管理 + 权限自动修复
# =================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LOG_FILE="/var/log/zmr_setup.log"

log() {
    local level=$1
    local msg=$2
    echo -e "$(date "+%Y-%m-%d %H:%M:%S") [$level] $msg" >> "${LOG_FILE}"
    case $level in
        "INFO") echo -e "${BLUE}[INFO] ${msg}${NC}" ;;
        "SUCCESS") echo -e "${GREEN}[OK] ${msg}${NC}" ;;
        "ERROR") echo -e "${RED}[ERROR] ${msg}${NC}" ;;
    esac
}

# --- 1. 用户管理模块 (增强确认) ---
create_user_logic() {
    local default_name="zmr$(date +%Y%m)"
    while true; do
        echo -e "\n${BLUE}--- 用户账户配置 ---${NC}"
        read -p "请输入远程登录用户名 (回车默认: $default_name): " input_name
        TARGET_USER=${input_name:-$default_name}
        read -p "确认用户名 [$TARGET_USER]？(y/n): " c_u
        [[ "$c_u" =~ ^[Yy]$ ]] && break
    done

    if id "$TARGET_USER" &>/dev/null; then
        log "INFO" "用户 $TARGET_USER 已存在。"
    else
        while true; do
            echo -e "密码设置: 1) 手动输入  2) 随机生成"
            read -p "选择: " p_m
            if [ "$p_m" == "2" ]; then
                USER_PASS=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 16)
                echo -e "${YELLOW}生成的随机密码: ${USER_PASS}${NC}"
            else
                read -s -p "请输入密码: " p1; echo ""
                read -s -p "确认密码: " p2; echo ""
                [ "$p1" != "$p2" ] && echo "密码不匹配！" && continue
                USER_PASS=$p1
            fi
            read -p "确定设置此密码并创建用户吗？(y/n): " c_p
            [[ "$c_p" =~ ^[Yy]$ ]] && break
        done
        useradd -m -s /bin/bash "$TARGET_USER"
        echo "${TARGET_USER}:${USER_PASS}" | chpasswd
        usermod -aG sudo "$TARGET_USER"
        log "SUCCESS" "用户 $TARGET_USER 创建成功。"
    fi
}

# --- 2. Wine 深度修复安装 (解决 X11 授权与 NTLM) ---
install_wine_pro() {
    log "INFO" "正在部署 Wine 兼容层及其修复补丁..."
    dpkg --add-architecture i386 && apt update
    # winbind 解决 NTLM, xauth 解决授权协议
    apt install -y wine wine64 wine32 winbind xauth libgl1-mesa-dri:i386 mesa-utils
    
    # 重新构建 swine 命令
    cat <<'EOF' > /usr/local/bin/swine
#!/bin/bash
# 解决 MoTTY X11 proxy: Unsupported authorisation protocol
if [ -f "$HOME/.Xauthority" ]; then
    export XAUTHORITY=$HOME/.Xauthority
fi

# 自动定位 DISPLAY
if [ -z "$DISPLAY" ]; then
    export DISPLAY=$(ls /tmp/.X11-unix/ | head -n 1 | sed 's/X/:/')
    [[ -z "$DISPLAY" ]] && export DISPLAY=:10.0
fi

# 强制驱动重定向
export LIBGL_ALWAYS_SOFTWARE=1
export WINE_NO_VIDMODE_EXTENSIONS=1

# 启动 Wine
wine start /Unix "$@"
EOF
    chmod +x /usr/local/bin/swine
    log "SUCCESS" "Wine 环境已就绪。请使用 'swine 软件名.exe' 运行。"
}

# --- 3. 分项/全量安装菜单 ---
install_menu() {
    while true; do
        clear
        echo -e "${BLUE}--- 追梦人软件安装菜单 ---${NC}"
        echo "1) 安装 Fcitx5 中文输入法"
        echo "2) 安装 Falkon 浏览器"
        echo "3) 安装 Wine 兼容环境 (含 Swine 修复)"
        echo "4) 返回主菜单"
        read -p "选择: " i_c
        case $i_c in
            1) apt install -y fcitx5 fcitx5-chinese-addons ; log "SUCCESS" "输入法已装" ;;
            2) apt install -y falkon ; log "SUCCESS" "浏览器已装" ;;
            3) install_wine_pro ;;
            4) break ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 4. 模块化卸载面板 ---
uninstall_menu() {
    while true; do
        clear
        echo -e "${RED}--- 追梦人卸载与清理面板 ---${NC}"
        echo "1) 卸载 输入法"
        echo "2) 卸载 浏览器"
        echo "3) 卸载 Wine 环境 (及修复脚本)"
        echo "4) 一键卸载所有扩展软件 (以上全部)"
        echo "5) 彻底卸载 XFCE4+XRDP 桌面"
        echo "6) 返回"
        read -p "选择: " u_c
        case $u_c in
            1) apt purge -y fcitx5* ; apt autoremove -y ;;
            2) apt purge -y falkon ; apt autoremove -y ;;
            3) apt purge -y wine* winbind ; rm -f /usr/local/bin/swine ; apt autoremove -y ;;
            4) 
                log "INFO" "执行全量清理..."
                apt purge -y fcitx5* falkon wine* winbind
                rm -f /usr/local/bin/swine ; apt autoremove -y 
                log "SUCCESS" "扩展软件已排空。" ;;
            5) apt purge -y xfce4* xrdp ; apt autoremove -y ;;
            6) break ;;
        esac
        read -p "按回车继续..."
    done
}

# --- 5. 主程序控制 ---
main() {
    if [ "$EUID" -ne 0 ]; then echo "请使用 root 运行"; exit 1; fi
    while true; do
        clear
        echo -e "${GREEN}======================================"
        echo -e "   追梦人一键安装xfce4+xrdp"
        echo -e "======================================${NC}"
        echo "1) 全自动部署 (桌面+用户+中文+Wine)"
        echo "2) 单项软件安装功能"
        echo "3) 模块化/一键全量卸载"
        echo "4) 系统维护 (端口/Swap/清理)"
        echo "5) 退出"
        read -p "选择操作: " choice
        case $choice in
            1) 
                apt update && apt upgrade -y
                create_user_logic
                log "INFO" "正在安装 XFCE4 桌面..."
                apt install -y xfce4 xfce4-goodies xrdp locales fonts-wqy-zenhei
                echo "startxfce4" > "/home/$TARGET_USER/.xsession"
                chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.xsession"
                locale-gen zh_CN.UTF-8
                install_wine_pro
                systemctl restart xrdp
                log "SUCCESS" "部署完成！请使用 $TARGET_USER 远程登录。"
                read -p "按回车返回..." ;;
            2) install_menu ;;
            3) uninstall_menu ;;
            4) 
                echo "1.改RDP端口 2.Swap管理 3.性能监控"
                read -p "选择: " m_c
                [ "$m_c" == "1" ] && read -p "新端口: " np && sed -i "s/port=.*/port=$np/g" /etc/xrdp/xrdp.ini && systemctl restart xrdp
                [ "$m_c" == "2" ] && read -p "G数: " sg && fallocate -l ${sg}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
                [ "$m_c" == "3" ] && top ;;
            5) exit 0 ;;
        esac
    done
}

main
