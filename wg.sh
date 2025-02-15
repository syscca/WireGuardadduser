#!/bin/bash

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo "错误：此脚本必须以 root 权限运行。"
    exit 1
fi

CONFIG_FILE="/etc/wireguard/wg0.conf"
CLIENT_DIR="/etc/wireguard/clients"
SERVER_IP_RANGE="10.10.0.1/24"

# 获取公网 IP
get_public_ip() {
    PUBLIC_IP=$(curl -s myip.ipip.net | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
    if [ -z "$PUBLIC_IP" ]; then
        echo "无法自动获取公网 IP，请手动输入"
        read -p "请输入服务器公网 IP: " PUBLIC_IP
    fi
    echo "$PUBLIC_IP"
}

# 检查 BBR
check_bbr() {
    if sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "✅ BBR 已启用"
    else
        echo "❌ BBR 未启用"
    fi
}

# 检查转发
check_forward() {
    if [ "$(sysctl -n net.ipv4.ip_forward)" -eq 1 ]; then
        echo "✅ IP 转发已启用"
    else
        echo "❌ IP 转发未启用"
    fi
}

# 安装 WireGuard
install_wg() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "WireGuard 已经安装！"
        return 1
    fi

    echo "正在安装 WireGuard..."
    apt update
    apt install -y wireguard wireguard-tools resolvconf qrencode
    
    # 修复：强制创建目录并设置权限
    mkdir -p /etc/wireguard
    chmod 700 /etc/wireguard

    # 生成密钥
    echo "正在生成密钥..."
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey

    # 创建配置文件
    echo "正在创建配置文件..."
    PRIVATE_KEY=$(cat /etc/wireguard/privatekey)
    PUBLIC_IP=$(get_public_ip)
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

    cat > "$CONFIG_FILE" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = $SERVER_IP_RANGE
ListenPort = 51820
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE
EOF

    # 启用转发和 BBR
    echo "启用系统参数..."
    sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
    echo "✅ WireGuard 安装完成"
}

# 卸载 WireGuard
uninstall_wg() {
    systemctl stop wg-quick@wg0
    systemctl disable wg-quick@wg0
    apt remove -y wireguard
    rm -rf /etc/wireguard/*
    echo "✅ WireGuard 已卸载"
}

# 添加用户
add_user() {
    [ ! -f "$CONFIG_FILE" ] && echo "请先安装 WireGuard！" && return 1

    # 获取下一个可用 IP
    LAST_IP=$(grep AllowedIPs "$CONFIG_FILE" | awk '{print $3}' | cut -d'/' -f1 | sort -t . -k 4 -n | tail -n1)
    CLIENT_IP=${LAST_IP:-10.10.0.2}
    NEXT_IP=$(echo $CLIENT_IP | awk -F. '{printf "%d.%d.%d.%d", $1,$2,$3,$4+1}')

    # 生成密钥
    CLIENT_PRIVATE=$(wg genkey)
    CLIENT_PUBLIC=$(echo "$CLIENT_PRIVATE" | wg pubkey)
    CLIENT_PSK=$(wg genpsk)

    # 添加到服务器配置
    cat >> "$CONFIG_FILE" <<EOF

[Peer]
PublicKey = $CLIENT_PUBLIC
AllowedIPs = $NEXT_IP/32
PresharedKey = $CLIENT_PSK
EOF

    # 创建客户端配置
    mkdir -p "$CLIENT_DIR"
    SERVER_PUBLIC=$(cat /etc/wireguard/publickey)
    PUBLIC_IP=$(get_public_ip)

    cat > "${CLIENT_DIR}/client_$NEXT_IP.conf" <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = $NEXT_IP/32
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $PUBLIC_IP:51820
AllowedIPs = 0.0.0.0/0
PresharedKey = $CLIENT_PSK
PersistentKeepalive = 25
EOF
    # 显示二维码（ASCII格式）
    echo -e "\n════════ 客户端二维码 ════════"
    qrencode -t ansiutf8 < "${CLIENT_DIR}/client_$NEXT_IP.conf"
    echo -e "══════════════════════════════\n"

    wg syncconf wg0 <(wg-quick strip wg0)
    echo "✅ 用户添加成功"
    echo "客户端配置文件: ${CLIENT_DIR}/client_$NEXT_IP.conf"
}

# 删除用户
del_user() {
    [ ! -f "$CONFIG_FILE" ] && echo "请先安装 WireGuard！" && return 1

    PEERS=($(grep -A4 '\[Peer\]' "$CONFIG_FILE" | grep AllowedIPs | awk '{print $3}'))
    [ ${#PEERS[@]} -eq 0 ] && echo "没有可删除的用户！" && return

    echo "请选择要删除的用户："
    for i in "${!PEERS[@]}"; do
        echo "$((i+1)). ${PEERS[$i]}"
    done

    read -p "请输入编号: " NUM
    [ -z "$NUM" ] && return
    SELECTED="${PEERS[$((NUM-1))]}"

    # 删除配置
    awk -v ip="${SELECTED/\//\\/}" '
    BEGIN {RS=""; FS="\n"}
    {
        if ($0 !~ "AllowedIPs.*"ip) {
            print $0
        }
    }' "$CONFIG_FILE" > /tmp/wg0.tmp && mv /tmp/wg0.tmp "$CONFIG_FILE"

    # 删除客户端文件
    CLIENT_IP=$(echo "$SELECTED" | cut -d'/' -f1)
    rm -f "${CLIENT_DIR}/client_$CLIENT_IP.conf"

    wg syncconf wg0 <(wg-quick strip wg0)
    echo "✅ 用户已删除"
}

# 查看配置
list_config() {
    [ ! -d "$CLIENT_DIR" ] && echo "没有客户端配置！" && return

    FILES=($(ls ${CLIENT_DIR}/*.conf 2>/dev/null))
    [ ${#FILES[@]} -eq 0 ] && echo "没有客户端配置！" && return

    echo "请选择要查看的配置："
    for i in "${!FILES[@]}"; do
        echo "$((i+1)). $(basename ${FILES[$i]})"
    done

    read -p "请输入编号: " NUM
    [ -z "$NUM" ] && return
    SELECTED_FILE="${FILES[$((NUM-1))]}"
    
    clear
    echo "════════ 配置文件内容 ════════"
    cat "$SELECTED_FILE"
    
    echo -e "\n════════ 客户端二维码 ════════"
    qrencode -t ansiutf8 < "$SELECTED_FILE"
    echo -e "══════════════════════════════"
}

# 系统状态
system_status() {
    echo "------ 系统状态 ------"
    check_bbr
    check_forward
    echo ""
    echo "------ WireGuard 状态 ------"
    systemctl status wg-quick@wg0 --no-pager
    echo ""
    echo "------ 当前用户数 ------"
    grep -c '\[Peer\]' "$CONFIG_FILE"
}

# 菜单
menu() {
    while true; do
        clear
        echo "================================="
        echo " WireGuard 管理脚本 (Debian 12) "
        echo "================================="
        echo "1. 安装 WireGuard"
        echo "2. 卸载 WireGuard"
        echo "3. 添加用户"
        echo "4. 删除用户"
        echo "5. 查看配置"
        echo "6. 系统状态"
        echo "7. 退出"
        echo "================================="
        read -p "请输入选项 [1-7]: " OPT

        case $OPT in
            1) install_wg ;;
            2) uninstall_wg ;;
            3) add_user ;;
            4) del_user ;;
            5) list_config ;;
            6) system_status ;;
            7) exit 0 ;;
            *) echo "无效选项！"; sleep 1 ;;
        esac
        read -p "按回车键继续..."
    done
}

# 启动菜单
menu
