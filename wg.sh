#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 配置文件路径
WG_CONFIG="/etc/wireguard/wg0.conf"
CLIENT_DIR="/root/wg-clients"

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误：必须使用root权限运行本脚本！${NC}"
        exit 1
    fi
}

# 获取默认网卡
get_default_interface() {
    ip route show default | awk '/default/ {print $5}' | head -n1
}

# 获取公网IP
get_public_ip() {
    curl -4 -s ip.sb
}

# 检查BBR状态
check_bbr() {
    sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"
    if [ $? -eq 0 ]; then
        echo -e "BBR状态: ${GREEN}已启用${NC}"
    else
        echo -e "BBR状态: ${RED}未启用${NC}"
    fi
}

# 检查IP转发状态
check_forwarding() {
    if [ $(sysctl -n net.ipv4.ip_forward) -eq 1 ]; then
        echo -e "IP转发: ${GREEN}已启用${NC}"
    else
        echo -e "IP转发: ${RED}未启用${NC}"
    fi
}

# 系统状态检查
system_status() {
    echo -e "\n${BLUE}====== 系统状态检查 ======${NC}"
    check_bbr
    check_forwarding
    echo -e "默认网卡: ${GREEN}$(get_default_interface)${NC}"
    echo -e "公网IP: ${GREEN}$(get_public_ip)${NC}"
    
    if systemctl is-active --quiet wg-quick@wg0; then
        echo -e "WireGuard状态: ${GREEN}运行中${NC}"
        wg show
    else
        echo -e "WireGuard状态: ${RED}未运行${NC}"
    fi
}

# 安装WireGuard
install_wireguard() {
    echo -e "${BLUE}正在安装WireGuard...${NC}"
    apt update && apt install -y wireguard resolvconf linux-headers-$(uname -r)
    
    echo -e "${BLUE}配置内核参数...${NC}"
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p
    
    echo -e "${BLUE}生成密钥对...${NC}"
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
    
    local private_key=$(cat /etc/wireguard/privatekey)
    local public_ip=$(get_public_ip)
    local interface=$(get_default_interface)
    
    echo -e "${BLUE}创建配置文件...${NC}"
    cat > $WG_CONFIG <<EOF
[Interface]
PrivateKey = $private_key
Address = 10.0.0.1/24
ListenPort = 51820
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $interface -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $interface -j MASQUERADE
EOF

    systemctl enable --now wg-quick@wg0
    echo -e "${GREEN}WireGuard安装完成！${NC}"
}

# 卸载WireGuard
uninstall_wireguard() {
    echo -e "${RED}正在卸载WireGuard...${NC}"
    systemctl stop wg-quick@wg0
    systemctl disable wg-quick@wg0
    apt remove --purge -y wireguard
    rm -rf /etc/wireguard/
    rm -rf $CLIENT_DIR
    echo -e "${GREEN}WireGuard已卸载！${NC}"
}

# 添加用户
add_user() {
    [ ! -d "$CLIENT_DIR" ] && mkdir -p $CLIENT_DIR
    
    read -p "请输入用户名: " username
    client_ip="10.0.0.$((2 + $(grep -c '^\[Peer\]' $WG_CONFIG)))"
    
    echo -e "${BLUE}生成客户端密钥...${NC}"
    wg genkey | tee $CLIENT_DIR/$username.privatekey | wg pubkey > $CLIENT_DIR/$username.publickey
    
    local client_private=$(cat $CLIENT_DIR/$username.privatekey)
    local client_public=$(cat $CLIENT_DIR/$username.publickey)
    local server_public=$(cat /etc/wireguard/publickey)
    local public_ip=$(get_public_ip)
    
    echo -e "${BLUE}更新服务器配置...${NC}"
    cat >> $WG_CONFIG <<EOF

[Peer]
PublicKey = $client_public
AllowedIPs = $client_ip/32
EOF

    echo -e "${BLUE}生成客户端配置文件...${NC}"
    cat > $CLIENT_DIR/$username.conf <<EOF
[Interface]
PrivateKey = $client_private
Address = $client_ip/24
DNS = 8.8.8.8

[Peer]
PublicKey = $server_public
Endpoint = $public_ip:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    systemctl restart wg-quick@wg0
    echo -e "${GREEN}用户 $username 添加成功！客户端配置：$CLIENT_DIR/$username.conf${NC}"
}

# 删除用户
delete_user() {
    peers=()
    while read -r line; do
        if [[ $line == "[Peer]" ]]; then
            read -r comment
            read -r public_key
            read -r allowed_ips
            peers+=("$comment:$public_key:$allowed_ips")
        fi
    done < $WG_CONFIG

    echo -e "\n${BLUE}请选择要删除的用户：${NC}"
    select peer in "${peers[@]}" "退出"; do
        if [ "$peer" = "退出" ]; then
            return
        elif [ -n "$peer" ]; then
            index=$((REPLY-1))
            sed -i "/\[Peer\]/,+3d" $WG_CONFIG
            echo -e "${GREEN}用户已删除！${NC}"
            systemctl restart wg-quick@wg0
            break
        else
            echo -e "${RED}无效选择！${NC}"
        fi
    done
}

# 显示用户列表
list_users() {
    echo -e "\n${BLUE}当前用户列表：${NC}"
    grep -A3 '^\[Peer\]' $WG_CONFIG | awk '
        /\[Peer\]/ {print "用户 " ++i}
        /PublicKey/ {print "公钥: "$3}
        /AllowedIPs/ {print "IP地址: "$3 "\n"}
    '
}

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}====== WireGuard 管理脚本 ======${NC}"
    echo -e "1. 安装 WireGuard"
    echo -e "2. 卸载 WireGuard"
    echo -e "3. 添加用户"
    echo -e "4. 删除用户"
    echo -e "5. 查看用户"
    echo -e "6. 系统状态检查"
    echo -e "0. 退出"
}

# 主程序
check_root
while true; do
    show_menu
    read -p "请输入选项 [0-6]: " option
    case $option in
        1) install_wireguard ;;
        2) uninstall_wireguard ;;
        3) add_user ;;
        4) delete_user ;;
        5) list_users ;;
        6) system_status ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项！${NC}" ;;
    esac
    read -p "按回车键继续..."
done
