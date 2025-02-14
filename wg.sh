#!/bin/bash
# WireGuard 服务器管理脚本增强版
# 支持Debian 12系统

CONFIG_FILE="/etc/wireguard/wg0.conf"
SERVER_IP="10.0.0.1/24"
SERVER_PORT="51820"
DNS_SERVERS="8.8.8.8"
SERVER_PUBKEY=""
SERVER_PRIVKEY=""
INTERFACE_NAME=$(ip route show default | awk '/default/ {print $5}' | head -n1)
[ -z "$INTERFACE_NAME" ] && INTERFACE_NAME="eth0"

# 用户列表缓存数组
declare -a USER_LIST

check_root() {
    [ "$EUID" -ne 0 ] && echo "请使用root权限运行此脚本" && exit 1
}

list_users() {
    USER_LIST=()
    echo "当前用户列表："
    echo "------------------------------------------------------------"
    printf "%-4s %-15s %-25s %-18s %-10s\n" "ID" "用户名" "公钥" "IP地址" "PSK状态"
    
    local count=0
    while read -r line; do
        if [[ $line =~ \[Peer\] ]]; then
            unset pubkey psk ip
        elif [[ $line =~ PublicKey\ =\ (.+) ]]; then
            pubkey=${BASH_REMATCH[1]}
        elif [[ $line =~ PresharedKey\ =\ (.+) ]]; then
            psk="✓"
        elif [[ $line =~ AllowedIPs\ =\ (.+)/32 ]]; then
            ip=${BASH_REMATCH[1]}
            user=$(find /etc/wireguard -name "*_publickey" -exec grep -l "$pubkey" {} \; | xargs basename | sed 's/_publickey//')
            USER_LIST[$count]="$user"
            printf "%-4s %-15s %-25s %-18s %-10s\n" \
                   "$((count+1))" \
                   "$user" \
                   "${pubkey:0:10}..." \
                   "$ip" \
                   "${psk:-✗}"
            ((count++))
        fi
    done < "$CONFIG_FILE"
    echo "------------------------------------------------------------"
}

view_user_config() {
    list_users
    if [ ${#USER_LIST[@]} -eq 0 ]; then
        echo "没有可用的用户"
        return
    fi
    
    read -p "请输入要查看的用户编号 [1-${#USER_LIST[@]}]: " num
    if [[ ! "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#USER_LIST[@]} ]; then
        echo "无效的编号!"
        return
    fi
    
    local user=${USER_LIST[$((num-1))]}
    echo "正在显示用户 [$user] 的配置："
    echo "------------------------------------------------------------"
    cat "/etc/wireguard/${user}.conf"
    echo "------------------------------------------------------------"
    read -p "是否显示二维码？[y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        qrencode -t ansiutf8 < "/etc/wireguard/${user}.conf"
    fi
}

show_menu() {
    clear
    echo "WireGuard 服务器管理脚本增强版"
    echo "-----------------------------------------------"
    echo "1. 安装WireGuard服务器"
    echo "2. 添加VPN用户"
    echo "3. 删除VPN用户"
    echo "4. 显示现有用户"
    echo "5. 查看用户配置"
    echo "6. 卸载WireGuard"
    echo "7. 系统状态检查"
    echo "8. 退出"
    echo ""
}

# 其他函数保持不变...

case "$1" in
    install)
        check_root
        install_wireguard
        ;;
    *)
        while true; do
            show_menu
            read -p "请输入选项 [1-8]: " choice
            case $choice in
                1) check_root; install_wireguard ;;
                2) check_root; add_user ;;
                3) check_root; remove_user ;;
                4) list_users ;;
                5) view_user_config ;;
                6) check_root; uninstall_wireguard ;;
                7) system_check ;;
                8) exit 0 ;;
                *) echo "无效选项";;
            esac
            read -p "按回车键继续..."
        done
        ;;
esac
