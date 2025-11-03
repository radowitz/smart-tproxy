#!/bin/bash

set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t clash-tproxy "$1"
}

# 等待网络就绪
wait_for_network() {
    local max_wait=60
    local count=0
    log "等待网络就绪..."
    while [ $count -lt $max_wait ]; do
        if ip route | grep -q default; then
            log "网络已就绪"
            return 0
        fi
        sleep 1
        ((count++))
    done
    log "错误: 网络超时未就绪"
    return 1
}

# 加载内核模块
load_modules() {
    log "加载必要的内核模块..."
    modprobe -q nf_tables 2>/dev/null || true
    modprobe -q nft_tproxy 2>/dev/null || true
    modprobe -q nf_tproxy_ipv4 2>/dev/null || true
    modprobe -q nft_socket 2>/dev/null || true
    modprobe -q ip_set 2>/dev/null || true
    modprobe -q ip_set_hash_net 2>/dev/null || true
}

# 加载 chnroute ipset（兼容格式）
load_chnroute() {
    local ipset_file="/root/smart-tproxy/chnroute.ipset"
    
    if [ ! -f "$ipset_file" ]; then
        log "警告: $ipset_file 不存在"
        return 1
    fi
    
    log "加载 chnroute ipset..."
    
    # 删除旧的 ipset
    ipset destroy chnroute 2>/dev/null || true
    
    # 尝试直接恢复
    if ipset restore -f "$ipset_file" 2>/dev/null; then
        log "chnroute ipset 加载成功 (直接恢复)"
        return 0
    fi
    
    # 如果失败，尝试逐行解析
    log "尝试手动解析 ipset 文件..."
    
    # 创建 ipset
    ipset create chnroute hash:net family inet hashsize 4096 maxelem 65536 2>/dev/null || true
    
    # 读取并添加 IP 段
    local count=0
    while IFS= read -r line; do
        # 跳过注释和空行
        [[ "$line" =~ ^#.*$ ]] && continue
        [[ -z "$line" ]] && continue
        
        # 提取 add 命令中的 IP
        if [[ "$line" =~ add[[:space:]]+chnroute[[:space:]]+([0-9./]+) ]]; then
            local ip="${BASH_REMATCH[1]}"
            ipset add chnroute "$ip" 2>/dev/null && ((count++))
        fi
    done < "$ipset_file"
    
    if [ $count -gt 0 ]; then
        log "chnroute ipset 加载成功: $count 条规则"
        return 0
    else
        log "错误: chnroute ipset 加载失败"
        return 1
    fi
}

# 验证 ipset 是否加载
verify_chnroute() {
    if ipset list chnroute &>/dev/null; then
        local count=$(ipset list chnroute | grep -c "^[0-9]" || echo 0)
        log "验证通过: chnroute 包含 $count 条规则"
        return 0
    else
        log "错误: chnroute ipset 不存在"
        return 1
    fi
}

# 配置路由策略
setup_routing() {
    log "配置路由策略..."
    
    # 清理旧规则
    ip rule del fwmark 1 table 100 2>/dev/null || true
    ip route flush table 100 2>/dev/null || true
    
    # 添加新规则
    ip rule add fwmark 1 table 100
    ip route add local 0.0.0.0/0 dev lo table 100
    
    log "路由策略配置完成"
}

# 配置 nftables
setup_nftables() {
    log "配置 nftables 规则..."
    
    # 获取网卡名称
    local eth_device=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$eth_device" ]; then
        eth_device="eth0"
    fi
    log "使用网卡: $eth_device"
    
    # 清理旧规则
    nft delete table inet clash 2>/dev/null || true
    
    # 创建 nftables 规则
    nft -f - << EOF
table inet clash {
    set chnroute {
        type ipv4_addr
        flags interval
        auto-merge
    }
    
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;
        
        # 跳过本地地址
        ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } return
        
        # 跳过国内 IP (如果 ipset 存在)
        ip daddr @chnroute return
        
        # TPROXY 重定向
        meta l4proto tcp tproxy to :7893 meta mark set 1 accept
        meta l4proto udp tproxy to :7893 meta mark set 1 accept
    }
    
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "$eth_device" masquerade
    }
}
EOF
    
    log "nftables 规则创建完成"
}

# 同步 ipset 到 nftables
sync_ipset_to_nftables() {
    if ! ipset list chnroute &>/dev/null; then
        log "警告: ipset chnroute 不存在，跳过同步"
        return 0
    fi
    
    log "同步 ipset 到 nftables..."
    
    # 清空 nftables set
    nft flush set inet clash chnroute 2>/dev/null || true
    
    # 批量添加 IP 到 nftables
    local temp_file=$(mktemp)
    ipset list chnroute | grep -E "^[0-9]" | awk '{print "add element inet clash chnroute { " $1 " }"}' > "$temp_file"
    
    if [ -s "$temp_file" ]; then
        nft -f "$temp_file"
        local count=$(wc -l < "$temp_file")
        log "已同步 $count 条 chnroute 规则到 nftables"
    fi
    
    rm -f "$temp_file"
}

# 主函数
main() {
    log "开始配置 Clash 透明代理 (nftables)"
    
    wait_for_network || exit 1
    load_modules
    
    # 加载并验证 chnroute
    local retry=0
    while [ $retry -lt 3 ]; do
        if load_chnroute && verify_chnroute; then
            break
        fi
        ((retry++))
        log "重试加载 chnroute ($retry/3)..."
        sleep 2
    done
    
    setup_routing
    setup_nftables
    sync_ipset_to_nftables
    
    log "Clash 透明代理配置完成"
}

main
