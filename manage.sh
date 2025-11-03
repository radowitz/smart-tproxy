#!/bin/bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 项目路径
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

# 检查是否为 root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# 显示菜单
show_menu() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}       Smart-TPROXY 透明代理管理脚本${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo -e "${GREEN}1.${NC}  完整安装 (首次安装全部组件)"
    echo -e "${GREEN}2.${NC}  启动所有服务"
    echo -e "${GREEN}3.${NC}  停止所有服务"
    echo -e "${GREEN}4.${NC}  重启所有服务"
    echo ""
    echo -e "${GREEN}5.${NC}  重启 Meta (Clash)"
    echo -e "${GREEN}6.${NC}  重启 SmartDNS"
    echo ""
    echo -e "${GREEN}7.${NC}  手动更新 chnroute"
    echo -e "${GREEN}8.${NC}  手动更新全部规则文件"
    echo ""
    echo -e "${GREEN}9.${NC}  查看服务状态"
    echo -e "${GREEN}10.${NC} 查看服务日志"
    echo ""
    echo -e "${GREEN}11.${NC} 设置定时更新规则"
    echo -e "${GREEN}12.${NC} 取消定时更新规则"
    echo ""
    echo -e "${GREEN}13.${NC} 卸载全部服务"
    echo ""
    echo -e "${GREEN}0.${NC}  退出"
    echo -e "${BLUE}================================================${NC}"
    echo ""
}

# 1. 完整安装
full_install() {
    log "开始完整安装..."
    echo ""

    # 运行 init.sh
    log_info "步骤 1/5: 配置系统环境和安装依赖..."
    if [ -f "./init.sh" ]; then
        chmod +x ./init.sh
        ./init.sh
    else
        log_error "找不到 init.sh 文件"
        return 1
    fi

    echo ""
    log_info "步骤 2/5: 下载规则文件..."
    if [ -f "./update-all-rules.sh" ]; then
        # 确保文件格式正确
        sed -i 's/\r$//' ./update-all-rules.sh 2>/dev/null || true
        chmod +x ./update-all-rules.sh
        ./update-all-rules.sh || log_warning "规则文件下载可能未完全成功，请稍后重试"
    fi

    echo ""
    log_info "步骤 3/5: 配置 systemd 服务..."
    setup_systemd_services

    echo ""
    log_info "步骤 4/5: 启动 Docker 容器..."
    docker compose up -d

    echo ""
    log_info "步骤 5/5: 停止所有服务（等待配置）..."
    sleep 3
    stop_all_services

    echo ""
    log "${GREEN}================================================${NC}"
    log "${GREEN}安装完成！${NC}"
    log "${GREEN}================================================${NC}"
    echo ""
    log_warning "重要提示："
    log_warning "1. 请修改配置文件："
    log_warning "   - ${SCRIPT_DIR}/smartdns/smartdns.conf"
    log_warning "     修改 SOCKS5 代理服务器和海外 DNS（NextDNS+AdGuard DNS）配置"
    log_warning ""
    log_warning "   - ${SCRIPT_DIR}/meta/config.yaml"
    log_warning "     修改订阅链接，如需关闭境外 QUIC 请取消注释相关规则"
    echo ""
    log_warning "2. 配置完成后，使用选项 2 启动所有服务"
    echo ""

    read -p "按任意键继续..." -n 1 -r
}

# 设置 systemd 服务
setup_systemd_services() {
    log "配置 systemd 服务..."

    # 1. clash-tproxy 服务（双重运行版本）
    cat > /etc/systemd/system/clash-tproxy.service << EOF
[Unit]
Description=Clash Transparent Proxy with iptables (Double Run)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
# 第一次运行（可能失败，不退出）
ExecStart=-${SCRIPT_DIR}/tproxy-iptables.sh
# 等待 60 秒
ExecStart=/bin/sleep 60
# 第二次运行（确保成功）
ExecStart=${SCRIPT_DIR}/tproxy-iptables.sh
ExecStop=${SCRIPT_DIR}/cleanup-iptables.sh
StandardOutput=journal
StandardError=journal
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF

    # 2. update-all-rules 服务
    cat > /etc/systemd/system/update-all-rules.service << EOF
[Unit]
Description=Update all rules (chnroute ipset) from remote source
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/update-all-rules.sh
StandardOutput=journal
StandardError=journal
EOF

    # 3. update-all-rules 定时器
    cat > /etc/systemd/system/update-all-rules.timer << EOF
[Unit]
Description=Update all rules daily

[Timer]
# 每天凌晨 3 点执行
OnCalendar=daily
OnCalendar=03:00
# 开机后 5 分钟执行一次
OnBootSec=5min
# 如果错过执行时间，立即执行
Persistent=true
# 随机延迟 0-30 分钟，避免集中访问
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
EOF

    # 4. 内核模块自动加载
    cat > /etc/modules-load.d/clash-tproxy.conf << EOF
xt_TPROXY
xt_socket
xt_mark
ip_set
ip_set_hash_net
EOF

    # 5. 日志轮转配置
    cat > /etc/logrotate.d/update-all-rules << EOF
/var/log/rules-update.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF

    # 赋予执行权限
    chmod +x "${SCRIPT_DIR}/tproxy-iptables.sh" 2>/dev/null || true
    chmod +x "${SCRIPT_DIR}/cleanup-iptables.sh" 2>/dev/null || true
    chmod +x "${SCRIPT_DIR}/update-all-rules.sh" 2>/dev/null || true

    # 重载 systemd
    systemctl daemon-reload

    # 只启用 clash-tproxy 服务，不自动启用定时器
    systemctl enable clash-tproxy.service

    log "systemd 服务配置完成（定时更新未启用，可通过菜单选项 11 启用）"
}

# 2. 启动所有服务
start_all_services() {
    log "启动所有服务..."

    # 启动 Docker 容器
    log_info "启动 Docker 容器..."
    docker compose up -d
    sleep 3

    # 启动 clash-tproxy 服务
    log_info "启动透明代理服务..."
    systemctl start clash-tproxy.service

    # 检查定时器是否已启用，如果启用则启动
    if systemctl is-enabled update-all-rules.timer &>/dev/null; then
        log_info "启动定时更新定时器..."
        systemctl start update-all-rules.timer
    fi

    log "${GREEN}所有服务已启动${NC}"
    sleep 2

    # 显示状态
    show_status

    read -p "按任意键继续..." -n 1 -r
}

# 3. 停止所有服务
stop_all_services() {
    log "停止所有服务..."

    # 停止 clash-tproxy 服务
    log_info "停止透明代理服务..."
    systemctl stop clash-tproxy.service 2>/dev/null || true

    # 停止定时器
    systemctl stop update-all-rules.timer 2>/dev/null || true

    # 停止 Docker 容器
    log_info "停止 Docker 容器..."
    docker compose down

    log "${GREEN}所有服务已停止${NC}"
    sleep 2
    read -p "按任意键继续..." -n 1 -r
}

# 4. 重启所有服务
restart_all_services() {
    log "重启所有服务..."
    stop_all_services
    sleep 2
    start_all_services
}

# 5. 重启 Meta
restart_meta() {
    log "重启 Clash Meta..."
    docker compose restart meta
    log "${GREEN}Clash Meta 已重启${NC}"
    sleep 2
    read -p "按任意键继续..." -n 1 -r
}

# 6. 重启 SmartDNS
restart_smartdns() {
    log "重启 SmartDNS..."
    docker compose restart smartdns
    log "${GREEN}SmartDNS 已重启${NC}"
    sleep 2
    read -p "按任意键继续..." -n 1 -r
}

# 7. 手动更新 chnroute
update_chnroute() {
    log "更新 chnroute..."

    # 使用 update-all-rules.sh 但只处理 chnroute
    local ipset_file="${SCRIPT_DIR}/chnroute.ipset"
    local url="https://hk.gh-proxy.com/https://raw.githubusercontent.com/soffchen/GeoIP2-CN/release/chnroute.ipset"

    log_info "下载 chnroute.ipset..."
    if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "${ipset_file}.tmp"; then
        if [ -s "${ipset_file}.tmp" ]; then
            # 备份旧文件
            if [ -f "$ipset_file" ]; then
                cp "$ipset_file" "${ipset_file}.bak.$(date +%Y%m%d-%H%M%S)"
            fi

            mv "${ipset_file}.tmp" "$ipset_file"
            log "${GREEN}chnroute.ipset 下载成功${NC}"

            # 重新加载 ipset
            log_info "重新加载 ipset..."
            ipset destroy chnroute -exist 2>/dev/null || true
            ipset destroy chnroute 2>/dev/null || true
            sleep 0.2

            if ipset restore -exist -f "$ipset_file" 2>/dev/null; then
                local count=$(ipset list chnroute 2>/dev/null | grep -c "^[0-9]" || echo 0)
                log "${GREEN}ipset 加载成功: $count 条规则${NC}"

                # 同步到 nftables
                if nft list table inet clash &>/dev/null; then
                    log_info "同步到 nftables..."
                    nft flush set inet clash chnroute 2>/dev/null || true

                    local temp_file=$(mktemp)
                    ipset list chnroute | grep -E "^[0-9]" | \
                        awk '{print "add element inet clash chnroute { " $1 " }"}' > "$temp_file"

                    if [ -s "$temp_file" ]; then
                        nft -f "$temp_file" 2>/dev/null
                        log "${GREEN}nftables 同步成功${NC}"
                    fi
                    rm -f "$temp_file"
                fi
            else
                log_error "ipset 加载失败"
            fi
        else
            log_error "下载的文件为空"
            rm -f "${ipset_file}.tmp"
        fi
    else
        log_error "下载失败"
        rm -f "${ipset_file}.tmp"
    fi

    sleep 2
    read -p "按任意键继续..." -n 1 -r
}

# 8. 手动更新全部规则
update_all_rules() {
    log "更新全部规则文件..."

    if [ -f "./update-all-rules.sh" ]; then
        # 确保文件格式正确
        sed -i 's/\r$//' ./update-all-rules.sh 2>/dev/null || true
        chmod +x ./update-all-rules.sh

        # 执行更新脚本
        if ./update-all-rules.sh; then
            log "${GREEN}规则文件更新完成${NC}"
        else
            log_error "规则文件更新失败，请检查日志"
            echo ""
            echo "查看详细日志："
            echo "  tail -50 /var/log/rules-update.log"
        fi
    else
        log_error "找不到 update-all-rules.sh 文件"
    fi

    sleep 2
    read -p "按任意键继续..." -n 1 -r
}

# 9. 查看服务状态
show_status() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}              服务状态${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""

    # Docker 容器状态
    log_info "Docker 容器状态："
    docker compose ps
    echo ""

    # clash-tproxy 服务状态
    log_info "透明代理服务状态："
    systemctl status clash-tproxy.service --no-pager -l || true
    echo ""

    # 定时器状态
    log_info "规则更新定时器状态："
    systemctl status update-all-rules.timer --no-pager -l || true
    echo ""

    # 下次更新时间
    log_info "下次规则更新时间："
    systemctl list-timers update-all-rules.timer --no-pager || true
    echo ""

    # ipset 状态
    log_info "chnroute ipset 状态："
    if ipset list chnroute &>/dev/null; then
        local count=$(ipset list chnroute | grep -c "^[0-9]" || echo 0)
        echo -e "${GREEN}已加载: $count 条规则${NC}"
    else
        echo -e "${RED}未加载${NC}"
    fi
    echo ""

    # iptables 状态
    log_info "iptables 规则状态："
    if iptables -t mangle -L clash -n &>/dev/null; then
        local count=$(iptables -t mangle -L clash -n | grep -c "TPROXY" || echo 0)
        echo -e "${GREEN}已配置 (TPROXY 规则: $count)${NC}"
        echo "路由规则："
        ip rule show | grep "fwmark 1" || echo "未配置"
    else
        echo -e "${RED}未配置${NC}"
    fi
    echo ""

    read -p "按任意键继续..." -n 1 -r
}

# 10. 查看服务日志
show_logs() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}              服务日志${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""
    echo -e "${GREEN}1.${NC} clash-tproxy 服务日志"
    echo -e "${GREEN}2.${NC} update-all-rules 服务日志"
    echo -e "${GREEN}3.${NC} Docker Meta 日志"
    echo -e "${GREEN}4.${NC} Docker SmartDNS 日志"
    echo -e "${GREEN}5.${NC} 规则更新日志文件"
    echo -e "${GREEN}0.${NC} 返回主菜单"
    echo ""

    read -p "请选择 [0-5]: " log_choice

    case $log_choice in
        1)
            journalctl -u clash-tproxy.service -f
            ;;
        2)
            journalctl -u update-all-rules.service -f
            ;;
        3)
            docker compose logs -f meta
            ;;
        4)
            docker compose logs -f smartdns
            ;;
        5)
            if [ -f /var/log/rules-update.log ]; then
                tail -f /var/log/rules-update.log
            else
                log_error "日志文件不存在"
                sleep 2
            fi
            ;;
        0)
            return
            ;;
        *)
            log_error "无效的选择"
            sleep 2
            ;;
    esac
}

# 11. 设置定时更新规则
setup_auto_update() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}          设置定时更新规则${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""

    # 检查服务文件是否存在
    if [ ! -f /etc/systemd/system/update-all-rules.timer ]; then
        log_error "定时器服务文件不存在"
        log_info "请先运行完整安装（选项 1）"
        sleep 3
        return
    fi

    # 检查是否已启用
    if systemctl is-enabled update-all-rules.timer &>/dev/null; then
        log_warning "定时更新规则已经启用"
        echo ""
        log_info "当前定时器状态："
        systemctl status update-all-rules.timer --no-pager || true
        echo ""
        log_info "下次更新时间："
        systemctl list-timers update-all-rules.timer --no-pager || true
        echo ""
        read -p "按任意键继续..." -n 1 -r
        return
    fi

    log "启用定时更新规则..."

    # 启用并启动定时器
    systemctl enable update-all-rules.timer
    systemctl start update-all-rules.timer

    log "${GREEN}定时更新规则已启用${NC}"
    echo ""
    log_info "定时器配置："
    log_info "  - 每天凌晨 3 点执行"
    log_info "  - 开机后 5 分钟执行一次"
    log_info "  - 随机延迟 0-30 分钟"
    echo ""
    log_info "下次更新时间："
    systemctl list-timers update-all-rules.timer --no-pager || true
    echo ""

    read -p "按任意键继续..." -n 1 -r
}

# 12. 取消定时更新规则
disable_auto_update() {
    clear
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}          取消定时更新规则${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""

    # 检查是否已启用
    if ! systemctl is-enabled update-all-rules.timer &>/dev/null; then
        log_warning "定时更新规则未启用，无需取消"
        sleep 2
        return
    fi

    log "取消定时更新规则..."

    # 停止并禁用定时器
    systemctl stop update-all-rules.timer
    systemctl disable update-all-rules.timer

    log "${GREEN}定时更新规则已取消${NC}"
    log_info "注意：您仍可以通过选项 8 手动更新规则"
    echo ""

    read -p "按任意键继续..." -n 1 -r
}

# 13. 卸载全部服务
uninstall_all() {
    clear
    echo -e "${RED}================================================${NC}"
    echo -e "${RED}              警告：卸载服务${NC}"
    echo -e "${RED}================================================${NC}"
    echo ""
    log_warning "此操作将："
    log_warning "1. 停止并删除所有 Docker 容器"
    log_warning "2. 停止并禁用 systemd 服务"
    log_warning "3. 删除 systemd 服务文件"
    log_warning "4. 清理 nftables 规则和 ipset"
    log_warning "5. 删除内核模块配置"
    echo ""
    log_warning "注意：不会删除项目文件和配置文件"
    echo ""

    read -p "确认卸载？(输入 YES 确认): " confirm

    if [ "$confirm" != "YES" ]; then
        log "已取消卸载"
        sleep 2
        return
    fi

    log "开始卸载..."

    # 停止服务
    log_info "停止服务..."
    systemctl stop clash-tproxy.service 2>/dev/null || true
    systemctl stop update-all-rules.timer 2>/dev/null || true
    systemctl stop update-all-rules.service 2>/dev/null || true

    # 禁用服务
    log_info "禁用服务..."
    systemctl disable clash-tproxy.service 2>/dev/null || true
    systemctl disable update-all-rules.timer 2>/dev/null || true

    # 删除 systemd 服务文件
    log_info "删除 systemd 服务文件..."
    rm -f /etc/systemd/system/clash-tproxy.service
    rm -f /etc/systemd/system/update-all-rules.service
    rm -f /etc/systemd/system/update-all-rules.timer
    rm -f /etc/modules-load.d/clash-tproxy.conf
    rm -f /etc/logrotate.d/update-all-rules

    # 重载 systemd
    systemctl daemon-reload

    # 停止 Docker 容器
    log_info "停止并删除 Docker 容器..."
    docker compose down 2>/dev/null || true

    # 清理 iptables 和 ipset
    log_info "清理网络规则..."
    if [ -f "./cleanup-iptables.sh" ]; then
        ./cleanup-iptables.sh
    else
        eth_device=$(ip route | grep default | awk '{print $5}' | head -n1)
        iptables -t mangle -D PREROUTING -j clash 2>/dev/null || true
        iptables -t mangle -F clash 2>/dev/null || true
        iptables -t mangle -X clash 2>/dev/null || true
        iptables -t nat -D POSTROUTING -o $eth_device -j MASQUERADE 2>/dev/null || true
        ip rule del fwmark 1 table 100 2>/dev/null || true
        ip route flush table 100 2>/dev/null || true
        ipset destroy chnroute 2>/dev/null || true
    fi

    log "${GREEN}卸载完成！${NC}"
    log_info "项目文件和配置文件保留在: ${SCRIPT_DIR}"
    echo ""

    read -p "按任意键继续..." -n 1 -r
}

# 主循环
main() {
    check_root

    while true; do
        show_menu
        read -p "请选择操作 [0-13]: " choice
        echo ""

        case $choice in
            1)
                full_install
                ;;
            2)
                start_all_services
                ;;
            3)
                stop_all_services
                ;;
            4)
                restart_all_services
                ;;
            5)
                restart_meta
                ;;
            6)
                restart_smartdns
                ;;
            7)
                update_chnroute
                ;;
            8)
                update_all_rules
                ;;
            9)
                show_status
                ;;
            10)
                show_logs
                ;;
            11)
                setup_auto_update
                ;;
            12)
                disable_auto_update
                ;;
            13)
                uninstall_all
                ;;
            0)
                log "退出管理脚本"
                exit 0
                ;;
            *)
                log_error "无效的选择，请重新输入"
                sleep 2
                ;;
        esac
    done
}

main
