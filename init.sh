#!/bin/bash

set -e

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then 
    log_error "请使用 root 权限运行此脚本"
    exit 1
fi

# 备份原有配置
backup_sysctl() {
    if [ -f /etc/sysctl.conf ]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%Y%m%d-%H%M%S)
        log "已备份 sysctl.conf"
    fi
}

# 配置内核参数
configure_kernel() {
    log "配置内核参数..."
    backup_sysctl
    
    # 检查是否已存在配置，避免重复添加
    grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || \
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    
    grep -q "net.core.default_qdisc" /etc/sysctl.conf || \
        echo "net.core.default_qdisc=cake" >> /etc/sysctl.conf
    
    grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf || \
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    
    # 应用配置
    sysctl -p /etc/sysctl.conf
    
    # 验证配置
    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        log "BBR 已启用"
    else
        log_error "BBR 启用失败，可能内核不支持"
    fi
}

# 安装必要软件
install_prerequisites() {
    log "更新软件包列表..."
    apt update -y || { log_error "apt update 失败"; exit 1; }
    
    log "安装必要软件包..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates \
        wget \
        curl \
        ipset \
        iptables \
        gnupg \
        nftables \
        sudo \
        lsb-release || { log_error "软件包安装失败"; exit 1; }
    
    log "必要软件包安装完成"
}

# 安装 Docker
install_docker() {
    log "准备安装 Docker..."
    
    # 检查 Docker 是否已安装
    if command -v docker &> /dev/null; then
        log "Docker 已安装，版本: $(docker --version)"
        read -p "是否要重新安装? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "跳过 Docker 安装"
            return 0
        fi
    fi
    
    # 下载 Docker 安装脚本
    if [ ! -f /tmp/get-docker.sh ]; then
        log "下载 Docker 安装脚本..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || \
            { log_error "下载 Docker 脚本失败"; exit 1; }
    fi
    
    # 执行安装（移除 --dry-run 实际安装）
    log "开始安装 Docker..."
    sh /tmp/get-docker.sh || { log_error "Docker 安装失败"; exit 1; }
    
    # 启动 Docker 服务
    systemctl enable docker
    systemctl start docker
    
    # 验证安装
    if docker --version &> /dev/null; then
        log "Docker 安装成功: $(docker --version)"
    else
        log_error "Docker 安装验证失败"
        exit 1
    fi
    
    # 清理安装脚本
    rm -f /tmp/get-docker.sh
}

# 主函数
main() {
    log "========== 开始系统配置 =========="
    
    configure_kernel
    install_prerequisites
    install_docker
    
    log "========== 配置完成 =========="
    log "系统信息:"
    log "  - IP 转发: $(sysctl -n net.ipv4.ip_forward)"
    log "  - TCP 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control)"
    log "  - Docker 版本: $(docker --version 2>/dev/null || echo '未安装')"
    log "========== ========== =========="
}

main
