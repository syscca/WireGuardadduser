#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 配置文件路径
WG_CONF="/etc/wireguard/wg0.conf"
SERVER_PRIVATE_KEY="/etc/wireguard/privatekey"
SERVER_PUBLIC_KEY="/etc/wireguard/publickey"
CLIENT_DIR="/etc/wireguard/clients"

# 获取公网IP
get_public_ip() {
    PUBLIC_IP=$(curl -s myip.ipip.net | grep -o "[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}")
    echo "$PUBLIC_IP"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：必须使用root权限运行此脚本${NC}"
        exit 1
    fi
}

# 检查系统状态
check_status() {
    # 检查BBR
    echo -e "${YELLOW}=== BBR状态检查 ===${NC}"
    sysctl net.ipv4.tcp_congestion_control | grep -q "bbr" && \
        echo -e "${GREEN}BBR 已启用${NC}" || \
        echo -e "${RED}BBR 未启用${NC}"

    # 检查IP转发
    echo -e "\n${YELLOW}=== IP转发状态 ===${NC}"
    sysctl net.ipv4.ip_forward | grep -q "1" && \
        echo -e "${GREEN}IP转发 已启用${NC}" || \
        echo -e "${RED}IP转发 未启用${NC}"

    # 检查WireGuard状态
    echo -e "\n${YELLOW}=== WireGuard 服务状态 ===${NC}"
    if systemctl is-active --quiet wg-quick@wg0; then
        echo -e "${GREEN}WireGuard 正在运行${NC}"
        wg show
    else
        echo -e "${RED}WireGuard 未运行${NC}"
    fi
}

# 启用BBR和转发
enable_features() {
    # 启用BBR
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
        sysctl -p
    fi

    # 启用IP转发
    if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
        sysctl -p
    fi
}

# 安装WireGuard
install_wireguard() {
    check_root
    apt update && apt install -y wireguard qrencode
    
    mkdir -p "$CLIENT_DIR"
    umask 077
    
    # 生成服务器密钥
    wg genkey | tee "$SERVER_PRIVATE_KEY" | wg pubkey > "$SERVER_PUBLIC_KEY"
    
    # 创建配置文件
    cat > "$WG_CONF" <<EOF
[Interface]
PrivateKey = $(cat "$SERVER_PRIVATE_KEY")
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $(ip route get 8.8.8.8 | awk '/dev/ {print $5}') -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $(ip route get 8.8.8.8 | awk '/dev/ {print $5}') -j MASQUERADE
EOF

    enable_features
    systemctl enable --now wg-quick@wg0
}

# 卸载WireGuard
uninstall_wireguard() {
    check_root
    systemctl stop wg-quick@wg0
    systemctl disable wg-quick@wg0
    apt remove --purge -y wireguard
    rm -rf /etc/wireguard
    echo -e "${GREEN}WireGuard 已完全卸载${NC}"
}

# 添加用户
add_user() {
    check_root
    read -p "请输入客户端名称: " client_name
    client_dir="$CLIENT_DIR/$client_name"
    mkdir -p "$client_dir"

    # 生成密钥
    wg genkey | tee "$client_dir/privatekey" | wg pubkey > "$client_dir/publickey"
    wg genpsk > "$client_dir/presharedkey"

    # 获取下一个可用IP
    last_ip=$(grep Address "$WG_CONF" | awk '{print $3}' | cut -d/ -f1 | sort -t . -k 4 -n | tail -n1)
    next_ip=${last_ip%.*}.$(( ${last_ip##*.} + 1 ))

    # 更新服务器配置
    cat >> "$WG_CONF" <<EOF

[Peer]
PublicKey = $(cat "$client_dir/publickey")
PresharedKey = $(cat "$client_dir/presharedkey")
AllowedIPs = $next_ip/32
EOF

    # 生成客户端配置
    cat > "$client_dir/wg0-client.conf" <<EOF
[Interface]
PrivateKey = $(cat "$client_dir/privatekey")
Address = $next_ip/24
DNS = 8.8.8.8

[Peer]
PublicKey = $(cat "$SERVER_PUBLIC_KEY")
PresharedKey = $(cat "$client_dir/presharedkey")
EndPoint = $(get_public_ip):51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    systemctl restart wg-quick@wg0
    echo -e "\n${GREEN}客户端配置已创建：${NC}"
    qrencode -t ansiutf8 < "$client_dir/wg0-client.conf"
}

# 删除用户
delete_user() {
    check_root
    users=("$CLIENT_DIR"/*)
    if [ ${#users[@]} -eq 0 ]; then
        echo -e "${RED}没有可删除的用户${NC}"
        return
    fi

    echo -e "${YELLOW}请选择要删除的用户：${NC}"
    select user_dir in "${users[@]}"; do
        if [ -n "$user_dir" ]; then
            client_name=$(basename "$user_dir")
            public_key=$(cat "$user_dir/publickey")
            
            # 从服务器配置中删除
            sed -i "/PublicKey = $public_key/,+3d" "$WG_CONF"
            
            rm -rf "$user_dir"
            systemctl restart wg-quick@wg0
            echo -e "${GREEN}用户 $client_name 已删除${NC}"
            break
        else
            echo -e "${RED}无效选择${NC}"
        fi
    done
}

# 查看用户
list_users() {
    users=("$CLIENT_DIR"/*)
    if [ ${#users[@]} -eq 0 ]; then
        echo -e "${RED}没有可用用户${NC}"
        return
    fi

    echo -e "${YELLOW}已创建的用户列表：${NC}"
    i=1
    for user_dir in "${users[@]}"; do
        client_name=$(basename "$user_dir")
        ip=$(grep Address "$user_dir/wg0-client.conf" | awk '{print $3}')
        echo -e "${BLUE}$i. $client_name ($ip)${NC}"
        ((i++))
    done
}

# 主菜单
main_menu() {
    clear
    echo -e "${YELLOW}=== WireGuard 管理脚本 ===${NC}"
    echo "1. 安装 WireGuard"
    echo "2. 卸载 WireGuard"
    echo "3. 添加用户"
    echo "4. 删除用户"
    echo "5. 查看用户"
    echo "6. 系统状态检查"
    echo "7. 退出"
    read -p "请输入选项 [1-7]: " choice

    case $choice in
        1) install_wireguard ;;
        2) uninstall_wireguard ;;
        3) add_user ;;
        4) delete_user ;;
        5) list_users ;;
        6) check_status ;;
        7) exit 0 ;;
        *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
    esac

    read -p "按回车键返回主菜单..."
    main_menu
}

# 初始化检查
[ ! -d "$CLIENT_DIR" ] && mkdir -p "$CLIENT_DIR"
main_menu
