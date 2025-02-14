#!/bin/bash
# WireGuard智能管理脚本 v1.2

CONFIG_DIR="/etc/wireguard"
SERVER_CONFIG="wg0.conf"
USER_DATA_FILE="${CONFIG_DIR}/user_data"
LOG_FILE="/var/log/wg_manager.log"
TMP_UFILE="${CONFIG_DIR}/.user_data.tmp"
SERVER_PRIVATE_KEY="${CONFIG_DIR}/privatekey"
SERVER_PUBLIC_KEY="${CONFIG_DIR}/publickey"
PORT=51820

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[34m'
BOLD='\033[1m'
NC='\033[0m'

# 初始化日志
init_log() {
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

# 日志记录函数
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 状态检查函数
check_wg_status() {
    if systemctl is-active --quiet "wg-quick@${SERVER_CONFIG%.conf}"; then
        return 0
    else
        return 1
    fi
}

# 自动获取公网IP
get_public_ip() {
    PUBLIC_IP=$(curl -4 -s icanhazip.com)
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -vE '^(127|10|192|172)')
    echo "$PUBLIC_IP"
}

# 自动检测默认网卡
detect_interface() {
    INTERFACE=$(ip route | awk '/default via/{print $5}')
    echo "$INTERFACE"
}

# 生成用户配置
gen_user_config() {
    local username=$1
    local ip=$2
    wg genkey | tee "${CONFIG_DIR}/${username}_privatekey" | wg pubkey > "${CONFIG_DIR}/${username}_publickey"
    echo -e "[Interface]
PrivateKey = $(cat "${CONFIG_DIR}/${username}_privatekey")
Address = ${ip}/24
DNS = 8.8.8.8

[Peer]
PublicKey = $(cat "$SERVER_PUBLIC_KEY")
Endpoint = ${PUBLIC_IP}:${PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25" > "${CONFIG_DIR}/${username}.conf"
}

# 用户管理菜单
user_management_menu() {
    clear
    echo -e "${BOLD}WireGuard 用户管理系统${NC}"
    echo "1. 添加新用户"
    echo "2. 删除用户"
    echo "3. 查看用户配置"
    echo "4. 修改用户套餐"
    echo "5. 返回主菜单"
    read -p "请输入选项 [1-5]: " choice
    case $choice in
        1) add_user ;;
        2) delete_user ;;
        3) show_user_config ;;
        4) modify_package ;;
        5) main_menu ;;
        *) echo -e "${RED}无效选项！${NC}"; sleep 1; user_management_menu ;;
    esac
}

# 添加用户
add_user() {
    check_wg_status || { echo -e "${RED}错误：请先启动WireGuard服务！${NC}"; sleep 2; return; }
    read -p "请输入用户名: " username
    [[ -z "$username" ]] && { echo -e "${RED}用户名不能为空！${NC}"; return; }
    [[ -f "${CONFIG_DIR}/${username}.conf" ]] && { echo -e "${RED}用户已存在！${NC}"; return; }
    
    last_ip=$(grep "AllowedIPs" "$CONFIG_DIR/$SERVER_CONFIG" | awk -F '[./]' '{print $2}' | sort -t. -k4 -n | tail -1)
    new_ip=${last_ip:-2}
    ((new_ip++))
    user_ip="10.0.0.${new_ip}"
    
    read -p "请输入套餐流量(GB): " traffic_limit
    read -p "请输入套餐天数: " days_limit
    
    gen_user_config "$username" "$user_ip"
    wg set wg0 peer "$(cat "${CONFIG_DIR}/${username}_publickey")" allowed-ips "$user_ip/32"
    echo "$username|$(date +%s)|$((traffic_limit * 1024))|0|$days_limit" >> "$USER_DATA_FILE"
    
    echo -e "\n${GREEN}用户添加成功！${NC}"
    echo -e "配置文件路径: ${BLUE}${CONFIG_DIR}/${username}.conf${NC}"
    sleep 2
}

# 删除用户
delete_user() {
    users=()
    while IFS= read -r line; do
        users+=("$(echo "$line" | cut -d'|' -f1)")
    done < "$USER_DATA_FILE"
    
    select_user || return
    sed -i "/^${selected_user}|/d" "$USER_DATA_FILE"
    wg set wg0 peer "$(cat "${CONFIG_DIR}/${selected_user}_publickey")" remove
    rm -f "${CONFIG_DIR}/${selected_user}"_*key
    rm -f "${CONFIG_DIR}/${selected_user}.conf"
    echo -e "${GREEN}用户 ${selected_user} 已删除！${NC}"
    sleep 1
}

# 其他函数因篇幅限制省略，完整代码需包含：
# - 流量和有效期检查
# - 套餐修改功能
# - 服务管理功能
# - BBR和转发自动配置
# - 完整的错误处理

# 主菜单
main_menu() {
    clear
    echo -e "${BOLD}WireGuard 智能管理脚本${NC}"
    check_wg_status && echo -e "服务状态: ${GREEN}运行中${NC}" || echo -e "服务状态: ${RED}已停止${NC}"
    echo "1. 安装WireGuard"
    echo "2. 卸载WireGuard"
    echo "3. 用户管理"
    echo "4. 启动/重启服务"
    echo "5. 停止服务"
    echo "6. 退出"
    read -p "请输入选项 [1-6]: " choice
    case $choice in
        1) install_wireguard ;;
        2) uninstall_wireguard ;;
        3) user_management_menu ;;
        4) start_service ;;
        5) stop_service ;;
        6) exit 0 ;;
        *) echo -e "${RED}无效选项！${NC}"; sleep 1; main_menu ;;
    esac
}

# 初始化
init_log
check_root
[[ $1 == "-auto" ]] && auto_update_check || main_menu
