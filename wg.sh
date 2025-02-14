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

check_root() {
    [ "$EUID" -ne 0 ] && echo "请使用root权限运行此脚本" && exit 1
}

check_forwarding() {
    [ "$(sysctl -n net.ipv4.ip_forward)" -eq 0 ] && return 1
    return 0
}

check_bbr() {
    sysctl net.ipv4.tcp_congestion_control | grep -q bbr
    return $?
}

enable_bbr() {
    grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}

install_wireguard() {
    apt update && apt upgrade -y
    apt install -y wireguard-tools resolvconf qrencode

    # 生成服务器密钥
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    SERVER_PRIVKEY=$(cat /etc/wireguard/privatekey)
    SERVER_PUBKEY=$(cat /etc/wireguard/publickey)

    # 创建配置文件
    cat > "$CONFIG_FILE" <<EOF
[Interface]
Address = $SERVER_IP
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIVKEY
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE_NAME -j MASQUERADE
EOF

    # 启用IP转发
    if ! check_forwarding; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        sysctl -p
    fi

    # 启用BBR
    if ! check_bbr; then
        enable_bbr
        echo "已启用BBR加速"
    fi

    systemctl enable --now wg-quick@wg0
    systemctl status wg-quick@wg0 --no-pager
}

uninstall_wireguard() {
    systemctl stop wg-quick@wg0
    systemctl disable wg-quick@wg0
    apt remove --purge -y wireguard-tools
    rm -rf /etc/wireguard/
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    sysctl -p
    echo "WireGuard 已完全卸载"
}

add_user() {
    read -p "请输入用户名: " username
    client_ip="10.0.0.$((2 + $(grep -c '^\[Peer\]' "$CONFIG_FILE" 2>/dev/null)))/32"
    
    # 生成客户端密钥和PSK
    umask 077
    wg genkey | tee "/etc/wireguard/${username}_privatekey" | wg pubkey > "/etc/wireguard/${username}_publickey"
    wg genpsk > "/etc/wireguard/${username}.psk"
    client_privkey=$(cat "/etc/wireguard/${username}_privatekey")
    client_pubkey=$(cat "/etc/wireguard/${username}_publickey")
    client_psk=$(cat "/etc/wireguard/${username}.psk")

    # 添加到服务器配置
    cat >> "$CONFIG_FILE" <<EOF

[Peer]
PublicKey = $client_pubkey
PresharedKey = $client_psk
AllowedIPs = $client_ip
EOF

    # 生成客户端配置
    cat > "/etc/wireguard/${username}.conf" <<EOF
[Interface]
PrivateKey = $client_privkey
Address = $client_ip
DNS = $DNS_SERVERS

[Peer]
PublicKey = $SERVER_PUBKEY
PresharedKey = $client_psk
Endpoint = $(curl -4 ifconfig.co):$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    wg syncconf wg0 <(wg-quick strip wg0)
    echo "用户 $username 添加成功"
    qrencode -t ansiutf8 < "/etc/wireguard/${username}.conf"
}

remove_user() {
    read -p "请输入要删除的用户名: " username
    
    if [ ! -f "/etc/wireguard/${username}_publickey" ]; then
        echo "用户不存在!"
        return 1
    fi

    client_pubkey=$(cat "/etc/wireguard/${username}_publickey")
    sed -i "/PublicKey = $client_pubkey/,+3d" "$CONFIG_FILE"
    rm -f "/etc/wireguard/${username}"*
    wg syncconf wg0 <(wg-quick strip wg0)
    echo "用户 $username 已删除"
}

list_users() {
    echo "当前用户列表："
    echo "------------------------------------------------------------"
    printf "%-15s %-25s %-18s %-10s\n" "用户名" "公钥" "IP地址" "PSK状态"
    
    while read -r line; do
        if [[ $line =~ \[Peer\] ]]; then
            unset pubkey psk ip
        elif [[ $line =~ PublicKey\ =\ (.+) ]]; then
            pubkey=${BASH_REMATCH[1]}
        elif [[ $line =~ PresharedKey\ =\ (.+) ]]; then
            psk="已启用"
        elif [[ $line =~ AllowedIPs\ =\ (.+)/32 ]]; then
            ip=${BASH_REMATCH[1]}
            user=$(find /etc/wireguard -name "*_publickey" -exec grep -l "$pubkey" {} \; | xargs basename | sed 's/_publickey//')
            [ -z "$psk" ] && psk="未启用"
            printf "%-15s %-25s %-18s %-10s\n" "$user" "${pubkey:0:20}..." "$ip" "$psk"
        fi
    done < "$CONFIG_FILE"
    echo "------------------------------------------------------------"
}

view_user_config() {
    read -p "请输入要查看配置的用户名: " username
    config_file="/etc/wireguard/${username}.conf"
    
    if [ ! -f "$config_file" ]; then
        echo "错误：用户 $username 的配置文件不存在"
        return 1
    fi
    
    echo "-----------------------------------------------"
    echo "用户 $username 的配置文件内容："
    cat "$config_file"
    echo "-----------------------------------------------"
    qrencode -t ansiutf8 < "$config_file"
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

system_check() {
    echo "系统状态检查："
    echo "-----------------------------------------------"
    check_forwarding && echo "IP转发状态: 已启用" || echo "IP转发状态: 未启用"
    check_bbr && echo "BBR加速状态: 已启用" || echo "BBR加速状态: 未启用"
    
    if systemctl is-active --quiet wg-quick@wg0; then
        echo -e "WireGuard服务状态: 运行中\n当前连接状态："
        wg show wg0 | awk '
            BEGIN {print "客户端ID          最近握手              传输数据"}
            /peer:/ {peer=substr($2,0,20)}
            /latest handshake:/ {handshake=$3" "$4}
            /transfer:/ {printf "%-18s %-20s %s %s\n", peer, handshake, $2, $3}'
    else
        echo "WireGuard服务状态: 未运行"
    fi
    echo "-----------------------------------------------"
}

case "$1" in
    install)
        check_root
        install_wireguard
        ;;
    *)
        while true; do
            show_menu
            read -p "请输入选项 [1-7]: " choice
            case $choice in
                1) check_root; install_wireguard ;;
                2) check_root; add_user ;;
                3) check_root; remove_user ;;
                4) list_users ;;
                5) check_root; view_user_config ;;
                6) check_root; uninstall_wireguard ;;
                7) system_check ;;
                8) exit 0 ;;
                *) echo "无效选项";;
            esac
            read -p "按回车键继续..."
        done
        ;;
esac
