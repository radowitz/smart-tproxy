#!/bin/bash

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t clash-tproxy "$1"
}

log "清理 iptables 规则..."

# 获取网卡名称
eth_device=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$eth_device" ]; then
    eth_device="eth0"
fi

# 清理 mangle 表
iptables -t mangle -D PREROUTING -j clash 2>/dev/null || true
iptables -t mangle -F clash 2>/dev/null || true
iptables -t mangle -X clash 2>/dev/null || true

# 清理 NAT 规则
iptables -t nat -D POSTROUTING -o $eth_device -j MASQUERADE 2>/dev/null || true

log "清理路由规则..."
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

log "清理 ipset..."
ipset destroy chnroute 2>/dev/null || true

log "清理完成 (iptables)"
