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

declare -a USER_LIST

check_root() {
    [ "$EUID" -ne 0 ] && echo "请使用root权限运行此脚本" && exit 1
}

list_users() {
    USER_LIST=()
    echo "当前用户列表："
    echo "================================================================"
    printf "%-4s %-15s %-20s %-15s %-10s\n" "ID" "用户名" "IP地址" "公钥片段" "PSK"
    echo "----------------------------------------------------------------"
    
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
            printf "%-4s %-15s %-20s %-15s %-10s\n" \
                   "$((count+1))" \
                   "$user" \
                   "$ip" \
                   "${pubkey:0:8}.." \
                   "${psk:-✗}"
            ((count++))
        fi
    done < "$CONFIG_FILE"
    echo "================================================================"
}

select_user() {
    list_users
    if [ ${#USER_LIST[@]} -eq 0 ]; then
        echo "没有可用的用户"
        return 1
    fi
    
    while true; do
        read -p "请输入要操作的用户编号 (0返回上级): " num
        [ "$num" -eq 0 ] 2>/dev/null && return 1
        [[ ! "$num" =~ ^[0-9]+$ ]] && echo "输入必须为数字!" && continue
        [ "$num" -lt 1 ] || [ "$num" -gt ${#USER_LIST[@]} ] && echo "编号超出范围!" && continue
        selected_user=${USER_LIST[$((num-1))]}
        break
    done
    echo "$selected_user"
}

view_config() {
    user=$(select_user)
    [ -z "$user" ] && return
    
    echo -e "\n用户 [$user] 的配置文件内容："
    echo "================================================================"
    cat "/etc/wireguard/${user}.conf"
    echo "================================================================"
    
    read -p "是否生成二维码？[y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] && qrencode -t ansiutf8 < "/etc/wireguard/${user}.conf"
}

show_menu() {
    clear
    echo "WireGuard 服务器管理脚本"
    echo "-----------------------------------------------"
    echo "1. 安装WireGuard服务器"
    echo "2. 添加VPN用户"
    echo "3. 删除VPN用户"
    echo "4. 查看用户配置"
    echo "5. 显示所有用户"
    echo "6. 卸载WireGuard"
    echo "7. 系统状态检查"
    echo "8. 退出"
    echo ""
}

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
                4) view_config ;;
                5) list_users ;;
                6) check_root; uninstall_wireguard ;;
                7) system_check ;;
                8) exit 0 ;;
                *) echo "无效选项";;
            esac
            read -p "按回车键继续..."
        done
        ;;
esac
