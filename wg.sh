CONFIG_FILE="/etc/wireguard/wg0.conf"
USER_DATA="/etc/wireguard/clients.json"
SERVER_PUBKEY=$(cat /etc/wireguard/publickey)
SERVER_ENDPOINT=$(curl -s myip.ipip.net |grep -o "[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}")
WG_INTERFACE="wg0"

# 初始化环境
init() {
    [ -f "$USER_DATA" ] || echo '{}' > "$USER_DATA"
    chmod 600 "$USER_DATA"
}

# 检查root权限
check_root() {
    [ "$(id -u)" -eq 0 ] || { echo "需要root权限"; exit 1; }
}

# 生成用户配置
generate_keys() {
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)
    echo "$private_key|$public_key"
}

# 分配可用IP
allocate_ip() {
    used_ips=$(jq -r '.[].ip' "$USER_DATA" 2>/dev/null)
    for i in {2..254}; do
        ip="10.0.0.$i"
        grep -q "$ip" <<< "$used_ips" || break
    done
    echo "$ip"
}

# 添加用户
add_user() {
    username="$1"
    [ -z "$username" ] && { echo "必须提供用户名"; exit 1; }
    
    # 检查用户是否存在
    existing=$(jq -r ".[\"$username\"]" "$USER_DATA")
    [ "$existing" != "null" ] && { echo "用户已存在"; exit 1; }

    # 生成密钥和IP
    keys=$(generate_keys)
    private_key=$(cut -d'|' -f1 <<< "$keys")
    public_key=$(cut -d'|' -f2 <<< "$keys")
    ip=$(allocate_ip)

    # 创建用户配置
    user_config="/etc/wireguard/clients/$username.conf"
    cat > "$user_config" <<EOF
[Interface]
PrivateKey = $private_key
Address = $ip/32
DNS = 8.8.8.8

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

    # 生成二维码
    qrencode -t ansiutf8 < "$user_config"

    # 更新用户数据
    jq --arg ip "$ip" \
       --arg pub "$public_key" \
       --arg priv "$private_key" \
       ".[\"$username\"] = { \
         \"public_key\": \$pub, \
         \"private_key\": \$priv, \
         \"ip\": \$ip, \
         \"enabled\": true, \
         \"traffic_limit\": 536870912000, \
         \"used_traffic\": 0, \
         \"last_transfer\": 0 \
       }" "$USER_DATA" > tmp.json && mv tmp.json "$USER_DATA"

    # 更新WireGuard配置
    update_wg_config
}

# 更新WireGuard配置
update_wg_config() {
    # 生成新的配置文件
    echo "[Interface]" > "$CONFIG_FILE.tmp"
    grep -A999 '^\[Interface\]' /etc/wireguard/wg0.conf | tail -n +2 | sed '/\[Peer\]/,$d' >> "$CONFIG_FILE.tmp"
    
    # 添加启用的用户
    jq -r 'to_entries[] | select(.value.enabled == true) | 
           "[Peer]\nPublicKey = \(.value.public_key)\nAllowedIPs = \(.value.ip)/32\n"' "$USER_DATA" >> "$CONFIG_FILE.tmp"
    
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    wg syncconf "$WG_INTERFACE" <(wg-quick strip "$WG_INTERFACE")
}

# 删除用户
remove_user() {
    username="$1"
    jq "del(.[\"$username\"])" "$USER_DATA" > tmp.json && mv tmp.json "$USER_DATA"
    rm -f "/etc/wireguard/clients/$username.conf"
    update_wg_config
}

# 用户状态管理
toggle_user() {
    username="$1"
    action="$2"
    jq ".[\"$username\"].enabled = $action" "$USER_DATA" > tmp.json && mv tmp.json "$USER_DATA"
    update_wg_config
}

# 流量统计与计费
update_traffic() {
    declare -A current_stats
    while read -r pub_key rx tx; do
        current_stats[$pub_key]=$((rx + tx))
    done < <(wg show "$WG_INTERFACE" dump | awk 'NR>1 {print $2,$6,$7}')

    # 更新用户数据
    tmp=$(mktemp)
    jq --argjson stats "$(declare -p current_stats | jq -c)" '
        . as $users |
        reduce ($stats | fromjson | to_entries[]) as $stat ($users;
            .[] |= (if .public_key == $stat.key 
                   then .last_transfer = ($stat.value | tonumber) |
                          .used_traffic += (if $stat.value > .last_transfer 
                                          then $stat.value - .last_transfer 
                                          else $stat.value end)
                   else . end))' "$USER_DATA" > "$tmp"
    mv "$tmp" "$USER_DATA"
}

# 自动禁用超限用户
auto_disable() {
    while read -r user; do
        username=$(jq -r '.key' <<< "$user")
        used=$(jq -r '.value.used_traffic' <<< "$user")
        limit=$(jq -r '.value.traffic_limit' <<< "$user")
        [ "$used" -ge "$limit" ] && toggle_user "$username" false
    done < <(jq -r 'to_entries[] | select(.value.enabled == true)' "$USER_DATA")
}

# 主程序流程
check_root
init

case "$1" in
    add)
        add_user "$2"
        ;;
    remove)
        remove_user "$2"
        ;;
    disable)
        toggle_user "$2" false
        ;;
    enable)
        toggle_user "$2" true
        ;;
    reset-traffic)
        jq ".[\"$2\"].used_traffic = 0" "$USER_DATA" > tmp.json && mv tmp.json "$USER_DATA"
        ;;
    list)
        jq -r 'to_entries[] | "\(.key): \(.value.ip) \(.value.enabled ? "Enabled" : "Disabled") \(.value.used_traffic/1024/1024)MB/\(.value.traffic_limit/1024/1024)MB"' "$USER_DATA"
        ;;
    auto)
        update_traffic
        auto_disable
        ;;
    *)
        echo "使用方法: $0 [add|remove|disable|enable|reset-traffic|list|auto] [username]"
        exit 1
        ;;
esac
