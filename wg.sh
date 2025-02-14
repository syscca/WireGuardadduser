#!/bin/bash
# WireGuard 服务器用户管理脚本
# 功能：
# 1. 安装 WireGuard（自动获取外网 IP 与默认网卡）
# 2. 卸载 WireGuard
# 3. 添加用户（支持包月套餐和流量限制，并自动生成 presharedkey）
# 4. 清空用户已使用流量
# 5. 重置用户套餐和流量限制（并清零已用流量）
# 6. 删除用户
# 7. 暂停用户（iptables 阻断流量）
# 8. 启用用户（解除阻断）
# 9. 查看用户配置
# 10. 系统状态检查（自动判断 BBR 与 IP 转发是否开启）
#
# 请以 root 用户运行此脚本

# 检查是否为 root 用户
if [[ $EUID -ne 0 ]]; then
    echo "请以 root 用户运行此脚本。"
    exit 1
fi

# 自动检测外网 IP（通过 ifconfig.me/ipinfo.io）
get_external_ip() {
    external_ip=$(curl -s https://ifconfig.me || curl -s https://ipinfo.io/ip)
    echo "$external_ip"
}

# 自动检测默认网卡
get_default_interface() {
    interface=$(ip route | grep '^default' | awk '{print $5}' | head -n 1)
    echo "$interface"
}

WG_CONFIG="/etc/wireguard/wg0.conf"
USER_DB="/etc/wireguard/users.db"
IP_BASE="10.0.0"
SERVER_IP="${IP_BASE}.1"
CLIENT_IP_START=2  # 客户端起始 IP 最后数字

# 初始化用户数据库文件
if [ ! -f "$USER_DB" ]; then
    touch "$USER_DB"
fi

# 安装 WireGuard
install_wireguard() {
    echo "正在自动获取外网 IP 与默认网卡..."
    ext_ip=$(get_external_ip)
    iface=$(get_default_interface)
    echo "检测到外网 IP：$ext_ip"
    echo "检测到默认网卡：$iface"

    echo "正在安装 WireGuard..."
    if [ -f /etc/debian_version ]; then
        apt update && apt install -y wireguard iptables curl
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release && yum install -y wireguard-tools iptables curl
    else
        echo "不支持的系统类型，请手动安装 WireGuard。"
        return 1
    fi

    # 若配置文件不存在，则创建基本配置文件
    if [ ! -f "$WG_CONFIG" ]; then
        read -p "请输入服务器私钥 (可使用 'wg genkey' 生成): " server_private_key
        cat > "$WG_CONFIG" <<EOF
[Interface]
Address = ${SERVER_IP}/24
ListenPort = 51820
PrivateKey = $server_private_key
# 自动检测的外网 IP: $ext_ip
# 默认网卡: $iface
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $iface -j MASQUERADE

# 以下为各个用户的配置
EOF
        echo "创建配置文件：$WG_CONFIG"
    fi
    echo "WireGuard 安装完成。"
}

# 卸载 WireGuard
uninstall_wireguard() {
    echo "正在卸载 WireGuard..."
    if [ -f /etc/debian_version ]; then
        apt remove -y wireguard iptables curl
    elif [ -f /etc/redhat-release ]; then
        yum remove -y wireguard-tools iptables curl
    fi
    rm -f "$WG_CONFIG" "$USER_DB"
    echo "WireGuard 已卸载并清理相关文件。"
}

# 获取下一个可用的客户端 IP
get_next_client_ip() {
    used_ips=$(awk -F',' '{print $2}' "$USER_DB")
    last_octet=$CLIENT_IP_START
    while true; do
        ip="${IP_BASE}.${last_octet}"
        if ! echo "$used_ips" | grep -qw "$ip"; then
            echo "$ip"
            return
        fi
        last_octet=$((last_octet+1))
    done
}

# 添加用户（生成密钥、设置套餐和流量限制，并更新配置文件）
add_user() {
    read -p "请输入用户名: " username
    if grep -q "^$username," "$USER_DB"; then
        echo "用户已存在。"
        return
    fi

    read -p "请输入套餐有效天数 (例如 30): " package_days
    read -p "请输入流量限制（单位 MB）: " traffic_limit

    client_ip=$(get_next_client_ip)
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    psk=$(wg genpsk)

    # 将用户信息保存到数据库：用户名,IP,套餐天数,流量限制,已用流量,状态,client_private,client_public,psk
    echo "$username,$client_ip,$package_days,$traffic_limit,0,active,$private_key,$public_key,$psk" >> "$USER_DB"

    # 将用户作为 Peer 添加到 WireGuard 配置文件
    cat >> "$WG_CONFIG" <<EOF

[Peer]
# 用户: $username
PublicKey = $public_key
PresharedKey = $psk
AllowedIPs = ${client_ip}/32
EOF

    # 应用新配置（可根据实际情况调整重载方式）
    wg syncconf wg0 <(wg-quick strip wg0)
    echo "用户 $username 添加成功，分配 IP：$client_ip"
}

# 清空用户已使用流量（重置为 0）
clear_user_traffic() {
    read -p "请输入要清空流量的用户名: " username
    if ! grep -q "^$username," "$USER_DB"; then
        echo "用户不存在。"
        return
    fi
    awk -F',' -v user="$username" 'BEGIN{OFS=","} {
        if($1==user) { $5=0 }
        print $0
    }' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    echo "用户 $username 的已用流量已清零。"
}

# 重新设置用户套餐和流量限制（并清零已用流量）
reset_user_package() {
    read -p "请输入要重置套餐的用户名: " username
    if ! grep -q "^$username," "$USER_DB"; then
        echo "用户不存在。"
        return
    fi
    read -p "请输入新的套餐有效天数: " package_days
    read -p "请输入新的流量限制（单位 MB）: " traffic_limit

    awk -F',' -v user="$username" -v days="$package_days" -v limit="$traffic_limit" 'BEGIN{OFS=","} {
        if($1==user) { $3=days; $4=limit; $5=0 }
        print $0
    }' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    echo "用户 $username 的套餐和流量限制已更新。"
}

# 删除用户（同时从数据库和 WireGuard 配置中删除对应记录）
delete_user() {
    read -p "请输入要删除的用户名: " username
    if ! grep -q "^$username," "$USER_DB"; then
        echo "用户不存在。"
        return
    fi
    grep -v "^$username," "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    # 根据注释标识删除对应 Peer 配置（本例删除注释及其下 3 行，可根据实际情况调整）
    sed -i "/# 用户: $username/,+3d" "$WG_CONFIG"
    wg syncconf wg0 <(wg-quick strip wg0)
    echo "用户 $username 已删除。"
}

# 暂停用户（添加 iptables 规则阻断其流量，并更新状态为 paused）
pause_user() {
    read -p "请输入要暂停的用户名: " username
    user_line=$(grep "^$username," "$USER_DB")
    if [ -z "$user_line" ]; then
        echo "用户不存在。"
        return
    fi
    client_ip=$(echo "$user_line" | awk -F',' '{print $2}')
    iptables -I FORWARD -s "$client_ip" -j DROP
    awk -F',' -v user="$username" 'BEGIN{OFS=","} {
        if($1==user) { $6="paused" }
        print $0
    }' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    echo "用户 $username 已暂停。"
}

# 启用用户（删除 iptables 阻断规则，并更新状态为 active）
enable_user() {
    read -p "请输入要启用的用户名: " username
    user_line=$(grep "^$username," "$USER_DB")
    if [ -z "$user_line" ]; then
        echo "用户不存在。"
        return
    fi
    client_ip=$(echo "$user_line" | awk -F',' '{print $2}')
    iptables -D FORWARD -s "$client_ip" -j DROP
    awk -F',' -v user="$username" 'BEGIN{OFS=","} {
        if($1==user) { $6="active" }
        print $0
    }' "$USER_DB" > "${USER_DB}.tmp" && mv "${USER_DB}.tmp" "$USER_DB"
    echo "用户 $username 已启用。"
}

# 查看用户配置
view_user_config() {
    read -p "请输入要查看配置的用户名: " username
    user_line=$(grep "^$username," "$USER_DB")
    if [ -z "$user_line" ]; then
        echo "用户不存在。"
        return
    fi
    IFS=',' read -r name ip days limit used status client_private client_public psk <<< "$user_line"
    cat <<EOF
用户名：$name
IP 地址：$ip
套餐有效天数：$days
流量限制：${limit}MB
已使用流量：${used}MB
状态：$status
PublicKey：$client_public
PresharedKey：$psk
EOF
}

# 系统状态检查：检测 BBR 是否开启以及 IP 转发状态
system_status_check() {
    echo "系统状态检查："
    tcp_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    if [ "$tcp_cc" = "bbr" ]; then
        echo "BBR 已开启。"
    else
        echo "BBR 未开启。当前拥塞控制算法：$tcp_cc"
    fi
    ip_forward=$(sysctl -n net.ipv4.ip_forward)
    if [ "$ip_forward" -eq 1 ]; then
        echo "IP 转发已开启。"
    else
        echo "IP 转发未开启。"
    fi
}

# 显示主菜单（序号选择操作）
show_menu() {
    echo "======================"
    echo "WireGuard 服务器管理菜单"
    echo "1. 安装 WireGuard"
    echo "2. 卸载 WireGuard"
    echo "3. 添加用户"
    echo "4. 清空用户已使用流量"
    echo "5. 重置用户套餐和流量限制"
    echo "6. 删除用户"
    echo "7. 暂停用户"
    echo "8. 启用用户"
    echo "9. 查看用户配置"
    echo "10. 系统状态检查"
    echo "0. 退出"
    echo "======================"
}

# 主循环，根据用户输入调用相应函数
while true; do
    show_menu
    read -p "请输入操作序号: " choice
    case $choice in
        1) install_wireguard ;;
        2) uninstall_wireguard ;;
        3) add_user ;;
        4) clear_user_traffic ;;
        5) reset_user_package ;;
        6) delete_user ;;
        7) pause_user ;;
        8) enable_user ;;
        9) view_user_config ;;
        10) system_status_check ;;
        0) echo "退出管理脚本。"; exit 0 ;;
        *) echo "无效的选择，请重试。" ;;
    esac
    echo ""
    read -p "按 Enter 键继续..." dummy
done
