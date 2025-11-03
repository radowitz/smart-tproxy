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
    modprobe -q xt_TPROXY 2>/dev/null || true
    modprobe -q xt_socket 2>/dev/null || true
    modprobe -q xt_mark 2>/dev/null || true
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

    # 彻底销毁旧的 ipset（强制销毁，忽略错误）
    ipset destroy chnroute -exist 2>/dev/null || true
    ipset destroy chnroute 2>/dev/null || true

    # 等待一下确保完全销毁
    sleep 0.2

    # 加载新的 ipset
    if ipset restore -exist -f "$ipset_file" 2>/dev/null; then
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

# 配置 iptables TPROXY 规则
setup_iptables() {
    log "配置 iptables TPROXY 规则..."

    # 获取网卡名称
    local eth_device=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [ -z "$eth_device" ]; then
        eth_device="eth0"
    fi
    log "使用网卡: $eth_device"

    # 清理旧规则
    iptables -t mangle -D PREROUTING -j clash 2>/dev/null || true
    iptables -t mangle -F clash 2>/dev/null || true
    iptables -t mangle -X clash 2>/dev/null || true
    iptables -t nat -D POSTROUTING -o $eth_device -j MASQUERADE 2>/dev/null || true

    # 创建 clash 链
    iptables -t mangle -N clash

    # 添加保留地址规则
    iptables -t mangle -A clash -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A clash -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A clash -d 100.64.0.0/10 -j RETURN
    iptables -t mangle -A clash -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A clash -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A clash -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A clash -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A clash -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A clash -d 240.0.0.0/4 -j RETURN

    # 添加 chnroute 规则
    iptables -t mangle -A clash -m set --match-set chnroute dst -j RETURN

    # 添加 TPROXY 规则
    iptables -t mangle -A clash -p udp -j TPROXY --on-port 7893 --tproxy-mark 1
    iptables -t mangle -A clash -p tcp -j TPROXY --on-port 7893 --tproxy-mark 1

    # 应用到 PREROUTING 链
    iptables -t mangle -A PREROUTING -j clash

    # 添加 NAT 规则
    iptables -t nat -A POSTROUTING -o $eth_device -j MASQUERADE

    log "iptables TPROXY 规则配置完成"
}

# 主函数
main() {
    log "开始配置 Clash 透明代理 (iptables)"

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
    setup_iptables

    log "Clash 透明代理配置完成 (iptables)"
}

main
