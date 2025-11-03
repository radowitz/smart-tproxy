#!/bin/bash

# 带完整等待和检查的 TPROXY 启动脚本

set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    logger -t clash-tproxy "$1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
    logger -t clash-tproxy "ERROR: $1"
}

# 等待网络就绪（最多等待 120 秒）
wait_for_network() {
    local max_wait=120
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
    log_error "网络超时未就绪"
    return 1
}

# 等待 Docker 服务就绪（最多等待 60 秒）
wait_for_docker_service() {
    local max_wait=60
    local count=0
    log "等待 Docker 服务启动..."

    while [ $count -lt $max_wait ]; do
        if systemctl is-active docker.service &>/dev/null; then
            log "Docker 服务已启动"
            sleep 3  # 额外等待确保完全就绪
            return 0
        fi
        sleep 1
        ((count++))
    done

    log_error "Docker 服务启动超时"
    return 1
}

# 等待 Clash Meta 容器启动并监听端口（最多等待 60 秒）
wait_for_clash_ready() {
    local max_wait=60
    local count=0
    log "等待 Clash Meta 容器启动..."

    while [ $count -lt $max_wait ]; do
        # 检查容器是否运行
        if docker ps --filter "name=clash-meta" --format "{{.Names}}" 2>/dev/null | grep -q "clash-meta"; then
            log "Clash Meta 容器已运行"

            # 检查端口是否监听
            if ss -tlnp | grep -q ":7893"; then
                log "Clash Meta 端口 7893 已监听"
                sleep 2  # 额外等待确保完全就绪
                return 0
            else
                log "等待端口 7893 监听..."
            fi
        fi
        sleep 1
        ((count++))
    done

    log_error "Clash Meta 容器或端口启动超时"
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
    log "内核模块加载完成"
}

# 清理 nftables 规则
cleanup_nftables() {
    log "清理 nftables 规则（避免与 iptables 冲突）..."

    if command -v nft &>/dev/null; then
        local has_nft_rules=$(nft list ruleset 2>/dev/null | wc -l)

        if [ "$has_nft_rules" -gt 0 ]; then
            log "检测到 nftables 规则，清空以使用 iptables..."
            nft flush ruleset 2>/dev/null || true
            log "nftables 规则已清空"
        else
            log "没有 nftables 规则冲突"
        fi
    fi
}

# 加载 chnroute ipset
load_chnroute() {
    local ipset_file="/root/smart-tproxy/chnroute.ipset"

    if [ ! -f "$ipset_file" ]; then
        log_error "$ipset_file 不存在"
        return 1
    fi

    log "加载 chnroute ipset..."

    # 销毁旧的 ipset
    ipset destroy chnroute -exist 2>/dev/null || true
    ipset destroy chnroute 2>/dev/null || true
    sleep 0.2

    # 加载新的 ipset
    if ipset restore -exist -f "$ipset_file" 2>/dev/null; then
        local count=$(ipset list chnroute 2>/dev/null | grep -c "^[0-9]" || echo 0)
        log "chnroute ipset 加载成功: $count 条规则"
        return 0
    fi

    log_error "chnroute ipset 加载失败"
    return 1
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
    log "========== 开始配置 Clash 透明代理 (iptables) =========="

    # 1. 等待网络就绪
    if ! wait_for_network; then
        log_error "网络未就绪，退出"
        exit 1
    fi

    # 2. 等待 Docker 服务
    if ! wait_for_docker_service; then
        log_error "Docker 服务未就绪，退出"
        exit 1
    fi

    # 3. 等待 Clash Meta 容器和端口
    if ! wait_for_clash_ready; then
        log_error "Clash Meta 未就绪，退出"
        exit 1
    fi

    # 4. 清理 nftables 规则
    cleanup_nftables

    # 5. 加载内核模块
    load_modules

    # 6. 加载 chnroute
    local retry=0
    while [ $retry -lt 3 ]; do
        if load_chnroute; then
            break
        fi
        ((retry++))
        log "重试加载 chnroute ($retry/3)..."
        sleep 2
    done

    if ! ipset list chnroute &>/dev/null; then
        log_error "chnroute 加载失败，退出"
        exit 1
    fi

    # 7. 配置路由
    setup_routing

    # 8. 配置 iptables
    setup_iptables

    log "========== Clash 透明代理配置完成 (iptables) =========="
    log "提示: 使用 'iptables -t mangle -L clash -n' 查看规则"
}

main
