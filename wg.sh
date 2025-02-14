#!/bin/bash
# WireGuard 服务器管理脚本
# 支持Debian 12系统

CONFIG_FILE="/etc/wireguard/wg0.conf"
SERVER_IP="10.0.0.1/24"
SERVER_PORT="51820"
DNS_SERVERS="8.8.8.8"
SERVER_PUBKEY=""
SERVER_PRIVKEY=""

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请使用root权限运行此脚本"
        exit 1
    fi
}

install_wireguard() {
    # 更新系统
    apt update && apt upgrade -y
    
    # 安装依赖
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
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
EOF

    # 启用IP转发
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p

    # 启动服务
    systemctl enable --now wg-quick@wg0
    systemctl status wg-quick@wg0
}

uninstall_wireguard() {
    systemctl stop wg-quick@wg0
    systemctl disable wg-quick@wg0
    
    apt remove --purge -y wireguard-tools
    
    rm -rf /etc/wireguard/
    
    # 恢复IP转发设置
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    sysctl -p
    
    echo "WireGuard 已完全卸载"
}

add_user() {
    read -p "请输入用户名: " username
    client_ip="10.0.0.$((2 + $(grep -c '^\[Peer\]' "$CONFIG_FILE" 2>/dev/null)))/32"
    
    # 生成客户端密钥
    umask 077
    wg genkey | tee "/etc/wireguard/${username}_privatekey" | wg pubkey > "/etc/wireguard/${username}_publickey"
    client_privkey=$(cat "/etc/wireguard/${username}_privatekey")
    client_pubkey=$(cat "/etc/wireguard/${username}_publickey")

    # 添加到服务器配置
    cat >> "$CONFIG_FILE" <<EOF

[Peer]
PublicKey = $client_pubkey
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
Endpoint = $(curl -4 ifconfig.co):$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # 重新加载配置
    wg syncconf wg0 <(wg-quick strip wg0)
    
    echo "用户 $username 添加成功"
    echo "配置文件路径: /etc/wireguard/${username}.conf"
    qrencode -t ansiutf8 < "/etc/wireguard/${username}.conf"
}

remove_user() {
    read -p "请输入要删除的用户名: " username
    
    if [ ! -f "/etc/wireguard/${username}_publickey" ]; then
        echo "用户不存在!"
        return 1
    fi

    client_pubkey=$(cat "/etc/wireguard/${username}_publickey")
    
    # 从服务器配置中删除
    sed -i "/PublicKey = $client_pubkey/,+2d" "$CONFIG_FILE"
    
    # 删除密钥文件
    rm -f "/etc/wireguard/${username}"_*
    
    # 重新加载配置
    wg syncconf wg0 <(wg-quick strip wg0)
    
    echo "用户 $username 已删除"
}

show_menu() {
    clear
    echo "WireGuard 服务器管理脚本"
    echo "-------------------------"
    echo "1. 安装WireGuard服务器"
    echo "2. 添加VPN用户"
    echo "3. 删除VPN用户"
    echo "4. 显示现有用户"
    echo "5. 卸载WireGuard"
    echo "6. 退出"
    echo ""
}

list_users() {
    echo "当前用户列表:"
    grep -oP '(?<=Peer] PublicKey = ).*' "$CONFIG_FILE" | while read pubkey; do
        user=$(grep -l "$pubkey" /etc/wireguard/*_publickey | cut -d/ -f4 | sed 's/_publickey//')
        ip=$(grep -A1 "$pubkey" "$CONFIG_FILE" | grep AllowedIPs | awk '{print $3}')
        echo "用户名: $user  公钥: ${pubkey:0:20}...  IP地址: $ip"
    done
}

case "$1" in
    install)
        check_root
        install_wireguard
        ;;
    *)
        while true; do
            show_menu
            read -p "请输入选项 [1-6]: " choice
            case $choice in
                1) check_root; install_wireguard ;;
                2) check_root; add_user ;;
                3) check_root; remove_user ;;
                4) list_users ;;
                5) check_root; uninstall_wireguard ;;
                6) exit 0 ;;
                *) echo "无效选项";;
            esac
            read -p "按回车键继续..."
        done
        ;;
esac
