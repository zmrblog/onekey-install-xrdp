#!/bin/bash

# =================================================================
# 脚本名称: 追梦人一键安装xfce4+xrdp v5.0
# 适用系统: Ubuntu / Debian
# 功能: 桌面环境 + 深度 Wine 修复 + 用户 CRUD 管理 + 完美中文支持
# =================================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
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
        "WARN") echo -e "${YELLOW}[WARN] ${msg}${NC}" ;;
    esac
}

# --- 核心修复：彻底解决中文失效与本地化警告 ---
fix_xrdp_global_config() {
    log "INFO" "正在修复底层中文语言环境..."
    # 1. 确保安装了核心语言包
    apt install -y language-pack-zh-hans language-pack-gnome-zh-hans locales fonts-wqy-zenhei >/dev/null 2>&1
    
    # 2. 强制重新生成并设置默认语言
    sed -i '/zh_CN.UTF-8 UTF-8/s/^# //g' /etc/locale.gen
    locale-gen zh_CN.UTF-8
    update-locale LANG=zh_CN.UTF-8 LANGUAGE=zh_CN:zh LC_ALL=zh_CN.UTF-8
    
    # 3. 注入全局 XRDP 启动环境 (关键修复)
    local wm_script="/etc/xrdp/startwm.sh"
    if [ -f "$wm_script" ]; then
        # 清理旧的重复配置
        sed -i '/export LANG=/d; /export LANGUAGE=/d; /export LC_ALL=/d' "$wm_script"
        # 写入新的环境变量
        sed -i '2i export LANG=zh_CN.UTF-8\nexport LANGUAGE=zh_CN:zh\nexport LC_ALL=zh_CN.UTF-8' "$wm_script"
        
        # 修复黑屏
        sed -i 's/^test -x \/etc\/X11\/Xsession/#test -x \/etc\/X11\/Xsession/' "$wm_script"
        sed -i 's/^exec \/bin\/sh \/etc\/X11\/Xsession/#exec \/bin\/sh \/etc\/X11\/Xsession/' "$wm_script"
        ! grep -q "startxfce4" "$wm_script" && echo "startxfce4" >> "$wm_script"
    fi
    apt install -y dbus-x11 >/dev/null 2>&1
}

# --- 用户管理模块 (修复删除不生效与 Sudo 权限) ---
create_user_logic() {
    local default_name="zmr$(date +%Y%m)"
    echo -e "\n${BLUE}--- 用户账户配置 ---${NC}"
    read -p "请输入远程登录用户名 (回车默认: $default_name): " input_name
    TARGET_USER=${input_name:-$default_name}

    if id "$TARGET_USER" &>/dev/null; then
        log "INFO" "用户 $TARGET_USER 已存在。"
    else
        echo -e "密码设置: 1) 手动输入  2) 随机生成"
        read -p "选择: " p_m
        if [ "$p_m" == "1" ]; then
            read -s -p "请输入密码: " USER_PASS; echo ""
        else
            USER_PASS=$(< /dev/urandom tr -dc 'A-Za-z0-9' | head -c 16)
            echo -e "${YELLOW}生成的随机密码: ${USER_PASS}${NC}"
        fi
        
        useradd -m -s /bin/bash "$TARGET_USER"
        echo "${TARGET_USER}:${USER_PASS}" | chpasswd
        usermod -aG sudo "$TARGET_USER"
        
        # 写入 sudoers.d 权限
        echo "$TARGET_USER ALL=(ALL) ALL" > "/etc/sudoers.d/$TARGET_USER"
        chmod 440 "/etc/sudoers.d/$TARGET_USER"
        
        # 用户独享中文配置 (修复 bash 警告)
        {
            echo "export LANG=zh_CN.UTF-8"
            echo "export LANGUAGE=zh_CN:zh"
            echo "export LC_ALL=zh_CN.UTF-8"
        } >> "/home/$TARGET_USER/.bashrc"
        
        echo "startxfce4" > "/home/$TARGET_USER/.xsession"
        chown "$TARGET_USER:$TARGET_USER" "/home/$TARGET_USER/.xsession"
        
        log "SUCCESS" "用户 $TARGET_USER 创建成功，Sudo 及中文环境已就绪。"
    fi
}

user_management_menu() {
    while true; do
        clear
        echo -e "${PURPLE}--- 用户管理中心 ---${NC}"
        echo "1) 新增用户"
        echo "2) 强制删除用户"
        echo "3) 修改用户密码"
        echo "4) 查看当前远程用户列表"
        echo "5) 返回主菜单"
        read -p "选择操作: " u_choice
        case $u_choice in
            1) create_user_logic ;;
            2) 
                read -p "输入要删除的用户名: " d_user
                if [[ "$d_user" != "root" && -n "$d_user" ]]; then
                    # 强杀该用户的所有进程，否则 userdel 会失败
                    pkill -u "$d_user" >/dev/null 2>&1
                    sleep 1
                    userdel -r "$d_user" >/dev/null 2>&1
                    rm -f "/etc/sudoers.d/$d_user"
                    log "SUCCESS" "用户 $d_user 及其残留权限已彻底删除。"
                fi ;;
            3)
                read -p "用户名: " m_user
                read -s -p "新密码: " m_pass; echo ""
                echo "$m_user:$m_pass" | chpasswd
                log "SUCCESS" "密码已更新" ;;
            4)
                echo -e "${BLUE}当前可登录用户列表:${NC}"
                awk -F: '$3 >= 1000 {print $1}' /etc/passwd | grep -v "nobody"
                read -p "按回车继续..." ;;
            5) break ;;
        esac
        read -p "操作完成，按回车继续..."
    done
}

# --- 软件安装菜单 (保留原有) ---
install_wine_pro() {
    log "INFO" "部署 Wine..."
    dpkg --add-architecture i386 && apt update
    apt install -y wine wine64 wine32 winbind xauth libgl1-mesa-dri:i386 mesa-utils
    cat <<'EOF' > /usr/local/bin/swine
#!/bin/bash
[ -f "$HOME/.Xauthority" ] && export XAUTHORITY=$HOME/.Xauthority
[ -z "$DISPLAY" ] && export DISPLAY=$(ls /tmp/.X11-unix/ | head -n 1 | sed 's/X/:/')
export LIBGL_ALWAYS_SOFTWARE=1
wine start /Unix "$@"
EOF
    chmod +x /usr/local/bin/swine
    log "SUCCESS" "Wine 部署成功。"
}

install_menu() {
    while true; do
        clear
        echo "1) 安装 Fcitx5 中文输入法"
        echo "2) 安装 Falkon 浏览器"
        echo "3) 安装 Wine 兼容环境"
        echo "4) 返回"
        read -p "选择: " i_c
        case $i_c in
            1) apt install -y fcitx5 fcitx5-chinese-addons ;;
            2) apt install -y falkon ;;
            3) install_wine_pro ;;
            4) break ;;
        esac
        read -p "继续..."
    done
}

# --- 卸载菜单 (保留原有) ---
uninstall_menu() {
    while true; do
        clear
        echo "1) 仅卸载 Wine"
        echo "2) 仅卸载 输入法"
        echo "3) 卸载全量桌面组件"
        echo "4) 返回"
        read -p "选择: " u_choice
        case $u_choice in
            1) apt purge -y wine* ; rm -f /usr/local/bin/swine ; apt autoremove -y ;;
            2) apt purge -y fcitx5* ; apt autoremove -y ;;
            3) apt purge -y xfce4* xrdp ; apt autoremove -y ;;
            4) break ;;
        esac
    done
}

# --- 主程序控制 ---
main() {
    if [ "$EUID" -ne 0 ]; then echo "请使用 root 运行"; exit 1; fi
    
    while true; do
        clear
        echo -e "${GREEN}======================================"
        echo -e "   追梦人一键安装xfce4+xrdp v5.0"
        echo -e "======================================${NC}"
        echo "1) 全自动部署"
        echo "2) 单项软件安装功能"
        echo "3) 用户增删改查管理"
        echo "4) 系统维护与操作日志"
        echo "5) 模块化卸载"
        echo "6) 退出"
        read -p "选择操作: " choice
        case $choice in
            1) 
                apt update && apt upgrade -y
                create_user_logic
                log "INFO" "正在部署 XFCE4..."
                apt install -y xfce4 xfce4-goodies xrdp locales fonts-wqy-zenhei
                fix_xrdp_global_config
                systemctl restart xrdp
                log "SUCCESS" "部署完成。如仍非中文，请重启系统。"
                read -p "回车继续..." ;;
            2) install_menu ;;
            3) user_management_menu ;;
            4) 
                echo "1.查看日志 2.修改端口 3.Swap管理"
                read -p "选择: " m_c
                [ "$m_c" == "1" ] && tail -n 20 "$LOG_FILE" && read -p "..."
                [ "$m_c" == "2" ] && read -p "端口: " np && sed -i "s/port=.*/port=$np/g" /etc/xrdp/xrdp.ini && systemctl restart xrdp
                [ "$m_c" == "3" ] && fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile ;;
            5) uninstall_menu ;;
            6) exit 0 ;;
        esac
    done
}

main
