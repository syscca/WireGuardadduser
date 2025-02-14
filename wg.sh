#!/bin/bash
# WireGuard 服务器管理脚本
# 支持：Debian 12
# 功能：安装/卸载、用户管理、套餐计费、自动维护

CONFIG_FILE="/etc/wireguard/wg0.conf"
USER_DB="/etc/wireguard/wg_users.json"
LOG_FILE="/var/log/wg_manager.log"

# 初始化日志记录
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "请使用root权限运行此脚本"
        exit 1
    fi
}

# 自动获取公网IP
get_public_ip() {
    PUBLIC_IP=$(curl -4 -s ifconfig.me)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(hostname -I | awk '{print $1}')
    echo "$PUBLIC_IP"
}

# 自动检测默认网卡
get_default_interface() {
    DEFAULT_IFACE=$(ip route | awk '/default/ {print $5}' | head -n1)
    echo "$DEFAULT_IFACE"
}

# 系统优化配置
enable_sysctl() {
    SYSCTL_CONF="/etc/sysctl.conf"
    # 开启转发
    if ! grep -q "net.ipv4.ip_forward=1" "$SYSCTL_CONF"; then
        echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
    fi
    
    # 开启BBR
    if ! grep -q "net.core.default_qdisc=fq" "$SYSCTL_CONF"; then
        echo "net.core.default_qdisc=fq" >> "$SYSCTL_CONF"
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" "$SYSCTL_CONF"; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> "$SYSCTL_CONF"
    fi
    
    sysctl -p >/dev/null 2>&1
}

# 安装WireGuard
install_wireguard() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "WireGuard 已经安装"
        return
    fi

    apt update >/dev/null 2>&1
    apt install -y wireguard qrencode jq >/dev/null 2>&1

    # 生成服务器密钥
    umask 077
    wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey

    # 初始化用户数据库
    [ ! -f "$USER_DB" ] && echo "{}" > "$USER_DB"

    # 创建配置文件
    cat > "$CONFIG_FILE" <<EOF
[Interface]
Address = 10.10.0.1/24
SaveConfig = true
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $(get_default_interface) -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $(get_default_interface) -j MASQUERADE
ListenPort = 51820
PrivateKey = $(cat /etc/wireguard/privatekey)
EOF

    # 启用服务
    systemctl enable --now wg-quick@wg0 >/dev/null 2>&1
    enable_sysctl
    log "WireGuard 安装完成"
}

# 卸载WireGuard
uninstall_wireguard() {
    systemctl stop wg-quick@wg0 >/dev/null 2>&1
    apt remove --purge -y wireguard >/dev/null 2>&1
    rm -rf /etc/wireguard
    log "WireGuard 已卸载"
}

# 添加用户
add_user() {
    read -p "请输入用户名: " username
    read -p "选择套餐 (1)月付 2)年付: " plan

    # 生成密钥
    user_private=$(wg genkey)
    user_public=$(echo "$user_private" | wg pubkey)
    user_ip="10.10.0.$((2 + $(jq length "$USER_DB")))
    expire_days=$([ "$plan" == "2" ] && echo "365" || echo "30")

    # 更新用户数据库
    jq --arg user "$username" \
       --arg pub "$user_public" \
       --arg ip "$user_ip" \
       --arg expire "$(date -d "+${expire_days} days" +%Y-%m-%d)" \
       '. + { ($user): { "public_key": $pub, "ip": $ip, "expire": $expire } }' \
       "$USER_DB" > tmp.json && mv tmp.json "$USER_DB"

    # 更新WireGuard配置
    echo -e "\n[Peer]" >> "$CONFIG_FILE"
    echo "PublicKey = $user_public" >> "$CONFIG_FILE"
    echo "AllowedIPs = $user_ip/32" >> "$CONFIG_FILE"
    wg addconf wg0 <(wg-quick strip wg0)

    # 生成客户端配置
    cat > "/root/wg-client-$username.conf" <<EOF
[Interface]
PrivateKey = $user_private
Address = $user_ip/24
DNS = 8.8.8.8

[Peer]
PublicKey = $(cat /etc/wireguard/publickey)
Endpoint = $(get_public_ip):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    qrencode -t ansiutf8 < "/root/wg-client-$username.conf"
    log "用户 $username 已添加，有效期至: $(date -d "+${expire_days} days" +%Y-%m-%d)"
}

# 删除用户
del_user() {
    users=$(jq -r 'keys[]' "$USER_DB")
    select username in $users; do
        [ -z "$username" ] && exit
        
        public_key=$(jq -r ".$username.public_key" "$USER_DB")
        sed -i "/PublicKey = $public_key/,+2d" "$CONFIG_FILE"
        jq "del(.$username)" "$USER_DB" > tmp.json && mv tmp.json "$USER_DB"
        wg addconf wg0 <(wg-quick strip wg0)
        rm -f "/root/wg-client-$username.conf"
        log "用户 $username 已删除"
        break
    done
}

# 到期检查
check_expire() {
    today=$(date +%Y-%m-%d)
    expired_users=$(jq -r "to_entries[] | select(.value.expire < \"$today\") | .key" "$USER_DB")
    
    for user in $expired_users; do
        public_key=$(jq -r ".$user.public_key" "$USER_DB")
        sed -i "/PublicKey = $public_key/,+2d" "$CONFIG_FILE"
        jq "del(.$user)" "$USER_DB" > tmp.json && mv tmp.json "$USER_DB"
        log "用户 $user 已过期，自动删除"
    done
}

# 主菜单
main_menu() {
    check_root
    check_expire

    PS3='请选择操作: '
    options=("安装WireGuard" "卸载WireGuard" "添加用户" "删除用户" "退出")
    
    select opt in "${options[@]}"
    do
        case $opt in
            "安装WireGuard")
                install_wireguard
                ;;
            "卸载WireGuard")
                uninstall_wireguard
                ;;
            "添加用户")
                add_user
                ;;
            "删除用户")
                del_user
                ;;
            "退出")
                break
                ;;
            *) echo "无效选项";;
        esac
    done
}

# 每日自动维护
auto_maintain() {
    check_expire
    systemctl restart wg-quick@wg0
}

# 执行入口
case "$1" in
    "install")
        install_wireguard
        ;;
    "auto")
        auto_maintain
        ;;
    *)
        main_menu
        ;;
esac
