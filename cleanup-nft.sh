#!/bin/bash

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t clash-tproxy "$1"
}

log "清理 nftables 规则..."
nft delete table inet clash 2>/dev/null || true

log "清理路由规则..."
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route flush table 100 2>/dev/null || true

log "清理 ipset..."
ipset destroy chnroute 2>/dev/null || true

log "清理完成"
