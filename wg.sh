view_user_config() {
    # 获取所有用户列表
    users=()
    while read -r line; do
        if [[ $line =~ \[Peer\] ]]; then
            unset pubkey
        elif [[ $line =~ PublicKey\ =\ (.+) ]]; then
            pubkey=${BASH_REMATCH[1]}
        elif [[ $line =~ AllowedIPs\ =\ (.+)/32 ]]; then
            user=$(find /etc/wireguard -name "*_publickey" -exec grep -l "$pubkey" {} \; | xargs basename | sed 's/_publickey//')
            users+=("$user")
        fi
    done < "$CONFIG_FILE"

    # 显示用户列表
    echo "现有用户："
    for i in "${!users[@]}"; do
        echo "$((i+1)). ${users[$i]}"
    done

    # 处理空列表
    if [ ${#users[@]} -eq 0 ]; then
        echo "错误：没有可用的用户"
        return 1
    fi

    # 用户选择
    read -p "请输入要查看的用户编号 [1-${#users[@]}]: " num
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt ${#users[@]} ]; then
        echo "无效的编号"
        return 1
    fi

    username="${users[$((num-1))]}"
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
